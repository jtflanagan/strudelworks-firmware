`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// hd_card_tb - the hard disk's slot on the card that is the CPU, with the tb
// playing the host at the other end of the messages.
//
// The real core, the real driver, the real message receiver and arbiter, and
// hd_card between them, against an Apple-shaped phi0 and a bus model with RAM
// everywhere and the program at the vector.  The program is what the slot
// ROM does to this card, boiled down: read the ROM, poke a command, read
// EXECUTE, spin on busy, read the size and the status, and do it again - and
// once, as the ROM's bootstrap does, issue a second command without waiting
// for the first.
//
// THE PROPERTIES, each a way this is or could be wrong:
//
//   * nothing is claimed until the host has loaded the ROM.
//   * a read of $Cn00 returns the ROM the host sent; with INTCXROM set it
//     returns the floating bus, and clearing the switch brings it back.
//   * an armed read of $C0n0 is an EXECUTE and answers busy; the core keeps
//     RUNNING, and every poll answers busy until the host has answered.
//   * two commands issued back to back are two commands: the first HD_DONE
//     leaves the port busy, the second releases it with ITS status.
//   * an HD_DONE carrying 512 bytes pauses the core and puts exactly those
//     bytes at exactly that address, one write per bus cycle, before the port
//     stops reading busy - and the size it carries reads back at $C0n9/$C0nA.
//   * an HD_FETCH reads exactly the bytes it names out of memory, one read
//     per bus cycle and none of them claimed, and they arrive at the host as
//     one HD_DATA that never lands inside a capture message.
//   * a read of $C0n0 with nothing armed is a poll, not a command.
//   * a host that never answers gets a timeout: the port reads "no device
//     connected" and the machine goes on.
//   * a RES' while busy drops it, and the machine boots.
//   * a late HD_DONE - after the command it answered has timed out -
//     changes nothing.
//////////////////////////////////////////////////////////////////////////////////

module hd_card_tb #(parameter UCODE = "cpu65c02_ucode.hex");

    localparam integer T_PRESENT = 2;
    localparam integer T_EMIT    = 2;
    localparam integer T_DIN     = 44;
    localparam integer T_CYCEN   = 45;

    // Short, so the timeout case is a few hundred bus cycles, not two seconds.
    localparam integer STALL_TIMEOUT = 30_000;

    localparam [7:0] T_HD_ROM   = 8'h18;
    localparam [7:0] T_HD_DONE  = 8'h19;
    localparam [7:0] T_HD_FETCH = 8'h1A;
    localparam [7:0] T_HD_DATA  = 8'h1B;
    localparam [7:0] T_BUS_EVENTS = 8'h12;

    localparam [15:0] EXEC  = 16'hC0F0;     // slot 7's EXECUTE port
    localparam [15:0] SLOTROM = 16'hC700;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;               // 100 MHz

    integer errors = 0;
    task fail(input [8*96-1:0] why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask

    // ---- phi0, as the machine makes it --------------------------------------
    localparam integer PHI0_LOW  = 49;
    localparam integer PHI0_HIGH = 49;
    localparam integer CYCLE     = PHI0_LOW + PHI0_HIGH;
    reg phi0 = 0;
    integer phase_ctr = 0;
    always @(posedge clk) begin
        phase_ctr <= phase_ctr + 1;
        if (!phi0 && phase_ctr == PHI0_LOW - 1)  begin phi0 <= 1; phase_ctr <= 0; end
        if ( phi0 && phase_ctr == PHI0_HIGH - 1) begin phi0 <= 0; phase_ctr <= 0; end
    end

    reg     prev_phi0 = 0;
    wire    fall = !phi0 && prev_phi0;
    integer since_fall = 0;
    always @(posedge clk) begin
        prev_phi0 <= phi0;
        if (fall) since_fall <= 0;
        else      since_fall <= since_fall + 1;
    end

    // ---- the machine's reset line, and the card's ---------------------------
    reg  res_n = 1'b1;
    wire cpu_rst = rst || !res_n;
    reg  master_active = 1'b1;

    // ---- the core -----------------------------------------------------------
    wire [15:0] cpu_addr;
    wire        cpu_rw, cpu_sync, cpu_cyc_en;
    wire [7:0]  cpu_dout, cpu_din;

    cpu65c02 #(.UCODE_FILE (UCODE)) u_cpu (
        .clk (clk), .rst (cpu_rst), .cyc_en (cpu_cyc_en),
        .addr (cpu_addr), .rw (cpu_rw), .dout (cpu_dout), .din (cpu_din),
        .irq_n (1'b1), .nmi_n (1'b1),
        .sync (cpu_sync), .halted ()
    );

    integer core_steps = 0;
    always @(posedge clk) if (cpu_cyc_en) core_steps = core_steps + 1;

    // ---- the driver ---------------------------------------------------------
    reg  [7:0]  data_sync = 8'h00;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, driving, drv_sync;
    wire [7:0]  data_drive;
    wire [15:0] op_addr;
    wire        op_rw, op_present, op_commit, op_ovr;
    wire [7:0]  op_wdata;
    wire        ovr_en, ovr_rw;
    wire [15:0] ovr_addr;
    wire [7:0]  ovr_wdata;
    wire        rd_claim;
    wire [7:0]  rd_data;

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) u_write (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0), .data_sync (data_sync),
        .master_active (master_active),
        // Without the sequencer: the bus owns every cycle, the core is always on offer.
        .bus_owns (1'b1), .core_valid (1'b1),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .drv_sync (drv_sync),
        .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (rd_claim), .slot_rd_data (rd_data),
        .din_sub_en (1'b0), .din_sub_data (8'h00),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (ovr_rw),
        .ovr_wdata (ovr_wdata), .op_ovr (op_ovr), .nxt_addr (), .divert (1'b0), .op_divert (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- host -> card: a little FIFO the parser reads from ------------------
    reg  [31:0] rx_mem [0:1023];
    integer     rx_wr = 0, rx_rd = 0;
    wire        rx_empty = (rx_rd >= rx_wr);
    wire [31:0] rx_dout  = rx_empty ? 32'd0 : rx_mem[rx_rd];
    wire        rx_rd_en;
    always @(posedge clk) if (rx_rd_en && !rx_empty) rx_rd <= rx_rd + 1;

    task push_word(input [31:0] w);
        begin rx_mem[rx_wr] = w; rx_wr = rx_wr + 1; end
    endtask

    function [31:0] hdr(input [7:0] t, input [7:0] len, input [15:0] free);
        hdr = {free, t, len};
    endfunction

    wire        msg_valid, pay_valid, unknown_valid;
    wire [7:0]  unknown_type, unknown_len;
    integer     unknowns = 0;
    always @(posedge clk) if (unknown_valid) unknowns = unknowns + 1;
    wire [7:0]  msg_type, msg_len;
    wire [15:0] msg_free;
    wire [31:0] pay_data;

    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .unknown_valid (unknown_valid), .unknown_type (unknown_type), .unknown_len (unknown_len)
    );

    // ---- the disk -----------------------------------------------------------
    wire [31:0] tx_word;
    wire        tx_valid, tx_take;
    wire        rom_loaded, busy;
    wire [7:0]  execs;

    // ---- the drain's world, stubbed and logged ------------------------------
    // Identity translation into the main bank; a page marked in t2_block
    // classifies as not-landing (the write-protected LC's shape).  Every
    // consumer logs its handshakes with a global stamp so per-line ordering
    // (write, then invalidate, then snoop) is checkable.
    reg          fast_dma = 1'b0;
    reg          ev_en = 1'b0;
    reg          map_pulse = 1'b0;
    reg  [255:0] t2_block = 256'd0;
    wire [7:0]   t2_page;
    wire         t2_w_ok    = !t2_block[t2_page];
    wire [16:0]  t2_w_ppage = {9'd0, t2_page};

    wire         dq_valid, inv_en, sn_en, fb2_we, ev_valid;
    wire [19:0]  dq_line;
    wire [15:0]  dq_be, fb2_addr;
    wire [127:0] dq_data;
    wire [23:0]  inv_pa, sn_pa;
    wire [7:0]   fb2_data;
    wire [31:0]  ev_word;

    integer      stamp = 0;
    always @(posedge clk) stamp = stamp + 1;

    // fb2 stalls one clock in five; the event port drains one word in three,
    // the merge's own pace.
    reg  [2:0]   fb2_ctr = 3'd0, ev_ctr = 3'd0;
    always @(posedge clk) begin
        fb2_ctr <= (fb2_ctr == 3'd4) ? 3'd0 : fb2_ctr + 3'd1;
        ev_ctr  <= (ev_ctr == 3'd2) ? 3'd0 : ev_ctr + 3'd1;
    end
    wire fb2_ready = (fb2_ctr != 3'd4);
    wire ev_take   = ev_valid && (ev_ctr == 3'd0);
    wire sn_take   = sn_en;
    wire inv_rdy   = 1'b1;
    wire dq_ready  = 1'b1;

    reg [19:0]  dql_line [0:63];
    reg [15:0]  dql_be   [0:63];
    reg [127:0] dql_data [0:63];
    integer     dql_at   [0:63];
    integer ndq = 0;
    reg [23:0] invl [0:63];  integer invl_at [0:63];  integer ninv = 0;
    reg [23:0] snl  [0:63];  integer snl_at  [0:63];  integer nsn  = 0;
    reg [15:0] fbl_addr [0:1023]; reg [7:0] fbl_data [0:1023]; integer nfb = 0;
    reg [31:0] evl [0:1023]; integer nev = 0;

    always @(posedge clk) begin
        if (dq_valid && dq_ready) begin
            dql_line[ndq] = dq_line; dql_be[ndq] = dq_be;
            dql_data[ndq] = dq_data; dql_at[ndq] = stamp; ndq = ndq + 1;
        end
        if (inv_en && inv_rdy) begin
            invl[ninv] = inv_pa; invl_at[ninv] = stamp; ninv = ninv + 1;
        end
        if (sn_en && sn_take) begin
            snl[nsn] = sn_pa; snl_at[nsn] = stamp; nsn = nsn + 1;
        end
        if (fb2_we && fb2_ready) begin
            fbl_addr[nfb] = fb2_addr; fbl_data[nfb] = fb2_data; nfb = nfb + 1;
        end
        if (ev_take) begin
            evl[nev] = ev_word; nev = nev + 1;
        end
    end

    hd_card #(.STALL_TIMEOUT (STALL_TIMEOUT)) dut (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .res_sync (res_n),
        .master_active (master_active), .slot_assign (3'd7),
        .op_addr (op_addr), .op_rw (op_rw), .op_present (op_present),
        .op_commit (op_commit), .op_ovr (op_ovr), .din (cpu_din),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (ovr_rw),
        .ovr_wdata (ovr_wdata),
        .rd_claim (rd_claim), .rd_data (rd_data),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .tx_word (tx_word), .tx_valid (tx_valid), .tx_take (tx_take),
        .fast_dma (fast_dma), .map_changed (map_pulse), .ev_enabled (ev_en),
        .dq_valid (dq_valid), .dq_line (dq_line), .dq_be (dq_be),
        .dq_data (dq_data), .dq_ready (dq_ready),
        .inv_line_en (inv_en), .inv_line_pa (inv_pa), .inv_line_rdy (inv_rdy),
        .snoop2_en (sn_en), .snoop2_pa (sn_pa), .snoop2_take (sn_take),
        .t2_page (t2_page), .t2_w_ok (t2_w_ok), .t2_w_ppage (t2_w_ppage),
        .fb2_we (fb2_we), .fb2_addr (fb2_addr), .fb2_data (fb2_data),
        .fb2_ready (fb2_ready),
        .dma_ev_word (ev_word), .dma_ev_valid (ev_valid), .dma_ev_take (ev_take),
        .rom_loaded (rom_loaded), .busy (busy), .execs (execs)
    );

    // ---- card -> host: through the real arbiter -----------------------------
    // The capture's port, played by the tb: a word offered on a level and
    // held until taken.
    reg  [31:0] src_data  = 32'd0;
    reg         src_valid = 1'b0;
    wire        src_take;
    reg         src_took  = 1'b0;
    always @(posedge clk) src_took <= src_valid && src_take;

    task offer(input [31:0] w);
        begin
            src_data  = w;
            src_valid = 1'b1;
            @(negedge clk);
            while (!src_took) @(negedge clk);
            src_valid = 1'b0;
        end
    endtask

    wire [31:0] tx_data;
    wire        tx_push;

    // The disk's master above the capture's, as in card_link; the tb plays
    // the slave and never stalls.
    wire [1:0]  mb_cyc, mb_stb, mb_we, mb_stall, mb_ack;
    wire [63:0] mb_adr, mb_dat;
    wire [7:0]  mb_sel;
    wire        sb_cyc, sb_stb, sb_we;
    wire [31:0] sb_adr, sb_dat;
    wire [3:0]  sb_sel;
    reg         sb_ack = 1'b0;

    msg_master u_m_hd (
        .clk (clk), .rst (rst), .word (tx_word), .valid (tx_valid), .take (tx_take),
        .cyc (mb_cyc[0]), .stb (mb_stb[0]), .we (mb_we[0]), .adr (mb_adr[31:0]),
        .dat (mb_dat[31:0]), .sel (mb_sel[3:0]), .stall (mb_stall[0]), .ack (mb_ack[0])
    );
    msg_master u_m_cap (
        .clk (clk), .rst (rst), .word (src_data), .valid (src_valid), .take (src_take),
        .cyc (mb_cyc[1]), .stb (mb_stb[1]), .we (mb_we[1]), .adr (mb_adr[63:32]),
        .dat (mb_dat[63:32]), .sel (mb_sel[7:4]), .stall (mb_stall[1]), .ack (mb_ack[1])
    );
    msg_arb #(.N (2)) u_arb (
        .clk (clk), .rst (rst),
        .m_cyc (mb_cyc), .m_stb (mb_stb), .m_we (mb_we), .m_adr (mb_adr),
        .m_dat (mb_dat), .m_sel (mb_sel), .m_stall (mb_stall), .m_ack (mb_ack),
        .s_cyc (sb_cyc), .s_stb (sb_stb), .s_we (sb_we), .s_adr (sb_adr),
        .s_dat (sb_dat), .s_sel (sb_sel), .s_stall (1'b0), .s_ack (sb_ack)
    );
    assign tx_data = sb_dat;
    assign tx_push = sb_cyc && sb_stb;
    always @(posedge clk) sb_ack <= !rst && sb_cyc && sb_stb;

    reg [31:0] out_mem [0:1023];
    integer    out_n = 0;
    always @(posedge clk) if (tx_push) begin
        out_mem[out_n] = tx_data;
        out_n = out_n + 1;
    end

    // ---- the machine: RAM everywhere, and the floating bus ------------------
    // The bus answers a read, or takes a write, well inside phi0-high and
    // before the driver's own sample tap.  A read the card claims returns
    // what the card drives; an unclaimed read of an empty slot's space is
    // the floating bus, modelled here as whatever mem holds ($EE there).
    localparam integer BUS_AT = 70;
    localparam [15:0] VECTOR = 16'hF000;

    reg [7:0] mem [0:65535];

    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        if (rw_drive) begin
            data_sync <= data_oe ? data_drive : mem[addr_drive];
        end else if (data_oe) begin
            mem[addr_drive] <= data_drive;
            data_sync <= data_drive;
        end
    end

    // ---- the op log ---------------------------------------------------------
    reg [15:0] log_addr [0:65535];
    reg        log_rw   [0:65535];
    reg        log_ovr  [0:65535];
    reg        log_sync [0:65535];
    reg [7:0]  log_din  [0:65535];
    integer    nops = 0, ncommit = 0;
    always @(posedge clk) begin
        if (op_present) begin
            log_addr[nops] = op_addr;
            log_rw[nops]   = op_rw;
            log_ovr[nops]  = op_ovr;
            log_sync[nops] = drv_sync;
            log_din[nops]  = 8'hxx;
            nops = nops + 1;
        end
        if (op_commit) begin
            log_din[ncommit] = cpu_din;
            ncommit = ncommit + 1;
        end
    end

    // Busy periods, counted as they begin.
    integer busies = 0;
    reg     busy_prev = 1'b0;
    always @(posedge clk) begin
        if (busy && !busy_prev) busies = busies + 1;
        busy_prev = busy;
    end

    // ---- helpers ------------------------------------------------------------
    task cycles(input integer n);
        begin repeat (n * CYCLE) @(posedge clk); end
    endtask

    task at_offset(input integer off);
        begin
            @(posedge clk);
            while (since_fall != off) @(posedge clk);
            @(negedge clk);
        end
    endtask

    task machine_reset(input integer hold_cycles);
        begin
            at_offset(0);
            res_n = 1'b0;
            cycles(hold_cycles);
            at_offset(0);
            nops = 0; ncommit = 0;
            res_n = 1'b1;
        end
    endtask

    // Wait for the core to finish a store to `where`, by watching mem.
    task wait_store(input [15:0] where, input integer max_cycles);
        integer n;
        begin
            n = 0;
            while (mem[where] === 8'hxx && n < max_cycles) begin
                cycles(1); n = n + 1;
            end
            if (mem[where] === 8'hxx) begin
                $display("FAIL: the program never stored to $%04x", where);
                errors = errors + 1;
            end
        end
    endtask

    function [7:0] pat_a(input integer i);   // the block the host sends
        pat_a = (i * 7 + 3) & 8'hFF;
    endfunction
    function [7:0] pat_b(input integer i);   // the block the host fetches
        pat_b = (i ^ 8'h5A) & 8'hFF;
    endfunction
    function [7:0] rom_at(input integer i);
        rom_at = (i == 0) ? 8'hA9 : (8'hC0 + i[7:0]);
    endfunction

    integer i, k, idx, first, n_w, n_r, n_busy, n_claimed, mark, steps_before;
    integer hdr_at, ev_at;
    integer j, nlines, ebytes, gbytes, nfb0, novr;
    reg [7:0]  got  [0:65535];      // bytes as the dq writes deliver them
    reg [7:0]  gev  [0:65535];      // bytes as the event words deliver them
    reg [15:0] eaddr;
    reg [15:0] ebe;

    initial begin
        $display("hd_card_tb: the hard disk's slot, busy, and the DMA\n");

        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEA;      // NOP background
        for (i = 16'hC000; i < 16'hD000; i = i + 1) mem[i] = 8'hEE;   // the float
        for (i = 16'h0300; i < 16'h0310; i = i + 1) mem[i] = 8'hxx;   // the marks
        for (i = 0; i < 512; i = i + 1) mem[16'h4000 + i] = pat_b(i);

        // The program.  X = $70 selects slot 7's $C0Fx.
        //   F000  LDX #$70
        //   F002  LDA $C700 / STA $0300           ; the slot ROM
        //   F008  LDA #$00 / STA $C089,X          ; a byte into the BLK FIFO: armed
        //   F00D  LDA $C080,X / STA $0301         ; EXECUTE #1, NO poll - the bootstrap's way
        //   F013  LDA #$01 / STA $C089,X          ; armed again, #1 still busy
        //   F018  LDA $C080,X / BMI F018          ; EXECUTE #2, then polls
        //   F01D  STA $0302                       ; #2's status
        //   F020  LDA $C089,X / STA $0303         ; size lo
        //   F026  LDA $C08A,X / STA $0304         ; size hi
        //   F02C  LDA $C081,X / STA $0305         ; the status port
        //   F032  LDA #$02 / STA $C08A,X          ; the SP FIFO arms too
        //   F037  LDA $C080,X / BMI F037          ; EXECUTE #3: a fetch
        //   F03C  STA $0306
        //   F03F  STA $C082,X                     ; the command register arms
        //   F042  LDA $C080,X / BMI F042          ; EXECUTE #4: never answered
        //   F047  STA $0307
        //   F04A  LDA $C080,X / STA $0308         ; nothing armed: a poll
        //   F050  STA $C007 / LDA $C700 / STA $0309   ; INTCXROM on
        //   F059  STA $C006 / LDA $C700 / STA $030A   ; off again
        //   F062  STA $C082,X                     ; armed
        //   F065  LDA $C080,X / BMI F065          ; EXECUTE #5: reset while busy
        //   F06A  STA $030B
        //   F06D  JMP $F06D
        mem[16'hF000] = 8'hA2; mem[16'hF001] = 8'h70;
        mem[16'hF002] = 8'hAD; mem[16'hF003] = 8'h00; mem[16'hF004] = 8'hC7;
        mem[16'hF005] = 8'h8D; mem[16'hF006] = 8'h00; mem[16'hF007] = 8'h03;
        mem[16'hF008] = 8'hA9; mem[16'hF009] = 8'h00;
        mem[16'hF00A] = 8'h9D; mem[16'hF00B] = 8'h89; mem[16'hF00C] = 8'hC0;
        mem[16'hF00D] = 8'hBD; mem[16'hF00E] = 8'h80; mem[16'hF00F] = 8'hC0;
        mem[16'hF010] = 8'h8D; mem[16'hF011] = 8'h01; mem[16'hF012] = 8'h03;
        mem[16'hF013] = 8'hA9; mem[16'hF014] = 8'h01;
        mem[16'hF015] = 8'h9D; mem[16'hF016] = 8'h89; mem[16'hF017] = 8'hC0;
        mem[16'hF018] = 8'hBD; mem[16'hF019] = 8'h80; mem[16'hF01A] = 8'hC0;
        mem[16'hF01B] = 8'h30; mem[16'hF01C] = 8'hFB;
        mem[16'hF01D] = 8'h8D; mem[16'hF01E] = 8'h02; mem[16'hF01F] = 8'h03;
        mem[16'hF020] = 8'hBD; mem[16'hF021] = 8'h89; mem[16'hF022] = 8'hC0;
        mem[16'hF023] = 8'h8D; mem[16'hF024] = 8'h03; mem[16'hF025] = 8'h03;
        mem[16'hF026] = 8'hBD; mem[16'hF027] = 8'h8A; mem[16'hF028] = 8'hC0;
        mem[16'hF029] = 8'h8D; mem[16'hF02A] = 8'h04; mem[16'hF02B] = 8'h03;
        mem[16'hF02C] = 8'hBD; mem[16'hF02D] = 8'h81; mem[16'hF02E] = 8'hC0;
        mem[16'hF02F] = 8'h8D; mem[16'hF030] = 8'h05; mem[16'hF031] = 8'h03;
        mem[16'hF032] = 8'hA9; mem[16'hF033] = 8'h02;
        mem[16'hF034] = 8'h9D; mem[16'hF035] = 8'h8A; mem[16'hF036] = 8'hC0;
        mem[16'hF037] = 8'hBD; mem[16'hF038] = 8'h80; mem[16'hF039] = 8'hC0;
        mem[16'hF03A] = 8'h30; mem[16'hF03B] = 8'hFB;
        mem[16'hF03C] = 8'h8D; mem[16'hF03D] = 8'h06; mem[16'hF03E] = 8'h03;
        mem[16'hF03F] = 8'h9D; mem[16'hF040] = 8'h82; mem[16'hF041] = 8'hC0;
        mem[16'hF042] = 8'hBD; mem[16'hF043] = 8'h80; mem[16'hF044] = 8'hC0;
        mem[16'hF045] = 8'h30; mem[16'hF046] = 8'hFB;
        mem[16'hF047] = 8'h8D; mem[16'hF048] = 8'h07; mem[16'hF049] = 8'h03;
        mem[16'hF04A] = 8'hBD; mem[16'hF04B] = 8'h80; mem[16'hF04C] = 8'hC0;
        mem[16'hF04D] = 8'h8D; mem[16'hF04E] = 8'h08; mem[16'hF04F] = 8'h03;
        mem[16'hF050] = 8'h8D; mem[16'hF051] = 8'h07; mem[16'hF052] = 8'hC0;
        mem[16'hF053] = 8'hAD; mem[16'hF054] = 8'h00; mem[16'hF055] = 8'hC7;
        mem[16'hF056] = 8'h8D; mem[16'hF057] = 8'h09; mem[16'hF058] = 8'h03;
        mem[16'hF059] = 8'h8D; mem[16'hF05A] = 8'h06; mem[16'hF05B] = 8'hC0;
        mem[16'hF05C] = 8'hAD; mem[16'hF05D] = 8'h00; mem[16'hF05E] = 8'hC7;
        mem[16'hF05F] = 8'h8D; mem[16'hF060] = 8'h0A; mem[16'hF061] = 8'h03;
        mem[16'hF062] = 8'h9D; mem[16'hF063] = 8'h82; mem[16'hF064] = 8'hC0;
        mem[16'hF065] = 8'hBD; mem[16'hF066] = 8'h80; mem[16'hF067] = 8'hC0;
        mem[16'hF068] = 8'h30; mem[16'hF069] = 8'hFB;
        mem[16'hF06A] = 8'h8D; mem[16'hF06B] = 8'h0B; mem[16'hF06C] = 8'h03;
        mem[16'hF06D] = 8'h4C; mem[16'hF06E] = 8'h6D; mem[16'hF06F] = 8'hF0;
        mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'hF0;

        res_n = 1'b0;                       // the machine waits for the ROM
        repeat (8) @(posedge clk);
        rst = 0;
        cycles(3);

        // --- case 1 / nothing is claimed until the ROM is loaded ------------
        if (rom_loaded !== 1'b0) fail("rom_loaded before any ROM was sent");
        if (dut.enabled !== 1'b0) fail("enabled before the ROM was loaded");
        else $display("  ok: no ROM, no slot - nothing is claimed");

        // A short ROM message is not a ROM.
        push_word(hdr(T_HD_ROM, 8'd2, 16'd0));
        push_word(32'h11111111); push_word(32'h22222222);
        repeat (40) @(posedge clk);
        if (rom_loaded !== 1'b0) fail("a 2-word ROM message counted as the ROM");
        else $display("  ok: a ROM message that is not 64 words is ignored");

        push_word(hdr(T_HD_ROM, 8'd64, 16'd0));
        for (i = 0; i < 64; i = i + 1)
            push_word({rom_at(4*i+3), rom_at(4*i+2), rom_at(4*i+1), rom_at(4*i)});
        repeat (200) @(posedge clk);
        if (rom_loaded !== 1'b1) fail("the ROM did not load");
        else if (dut.enabled !== 1'b1) fail("loaded, but not enabled");
        else $display("  ok: 64 words of HD_ROM loaded, the slot is live");

        // --- case 2 / boot: the ROM reads back, then EXECUTE answers busy ----
        machine_reset(4);
        wait_store(16'h0300, 100);
        if (mem[16'h0300] !== rom_at(0)) begin
            $display("FAIL: $C700 read $%02x, expected the ROM's $%02x", mem[16'h0300], rom_at(0));
            errors = errors + 1;
        end else $display("  ok: $C700 returns the ROM the host loaded");

        // EXECUTE #1, the bootstrap's way: no poll, and the program goes on.
        wait_store(16'h0301, 100);
        if (mem[16'h0301] !== 8'h80) begin
            $display("FAIL: EXECUTE #1 returned $%02x, expected $80 (busy)", mem[16'h0301]);
            errors = errors + 1;
        end else $display("  ok: the EXECUTE read answers $80, busy, at once");
        if (busy !== 1'b1) fail("not busy after an EXECUTE");
        if (execs !== 8'd1 && execs !== 8'd2) fail("execs did not count the EXECUTE");

        // The program is spinning on #2 now: the core RUNS while busy.
        wait (execs == 2);
        cycles(2);
        steps_before = core_steps;
        mark = nops;
        cycles(20);
        if (core_steps == steps_before) fail("the core did not run while busy");
        else $display("  ok: two EXECUTEs outstanding, and the core keeps running - %0d cycles in 20",
                      core_steps - steps_before);
        n_busy = 0; n_claimed = 0;
        for (i = mark; i < ncommit; i = i + 1) begin
            if (log_ovr[i]) fail("an override while the core should be running");
            if (log_addr[i] == EXEC && log_rw[i]) begin
                n_claimed = n_claimed + 1;
                if (log_din[i] === 8'h80) n_busy = n_busy + 1;
            end
        end
        if (n_claimed == 0 || n_busy != n_claimed) fail("a poll did not return $80");
        else $display("  ok: %0d polls of $C0F0, each answered $80 (busy)", n_claimed);
        if (dut.outstanding !== 2'd2) fail("outstanding is not 2");

        // --- case 3 / HD_DONE #1 answers the first, and the port stays busy --
        push_word(hdr(T_HD_DONE, 8'd0, 16'h0000));           // status $00, no bytes
        cycles(20);
        if (busy !== 1'b1 || dut.outstanding !== 2'd1) fail("the first answer released the port");
        else $display("  ok: the first HD_DONE answers the first EXECUTE - the port stays busy for the second");
        if (mem[16'h0302] !== 8'hxx) fail("the poll loop exited on the first answer");

        // --- case 4 / HD_DONE #2 with a block: DMA in, then the status ----------
        mark = nops;
        steps_before = core_steps;
        push_word(hdr(T_HD_DONE, 8'd130, 16'h0000));         // status $00
        push_word({16'd512, 16'h2000});                        // 512 bytes to $2000
        push_word({16'd0, 16'h1234});                          // size $1234
        for (i = 0; i < 128; i = i + 1)
            push_word({pat_a(4*i+3), pat_a(4*i+2), pat_a(4*i+1), pat_a(4*i)});
        wait_store(16'h0302, 700);
        if (mem[16'h0302] !== 8'h00) begin
            $display("FAIL: EXECUTE #2 returned $%02x, expected $00", mem[16'h0302]);
            errors = errors + 1;
        end else $display("  ok: the poll loop exits with the second command's status $00");
        if (busy !== 1'b0) fail("still busy after the answer");

        // The writes: exactly 512, sequential, all override, contiguous - the
        // core paused for exactly them.
        n_w = 0; first = -1; idx = -1;
        for (i = mark; i < nops; i = i + 1) begin
            if (log_ovr[i] && !log_rw[i]) begin
                if (first < 0) first = i;
                if (log_addr[i] !== 16'h2000 + n_w[15:0])
                    fail("a DMA write was out of sequence");
                if (i != first + n_w) fail("the core's cycles interleaved with the DMA");
                n_w = n_w + 1;
            end
            if (!log_ovr[i] && log_addr[i] == EXEC && log_din[i] === 8'h00 && idx < 0) idx = i;
        end
        if (n_w != 512) begin
            $display("FAIL: %0d DMA writes, expected 512", n_w); errors = errors + 1;
        end else $display("  ok: 512 DMA writes, $2000..$21FF in order, one per bus cycle, contiguous");
        if (idx < 0) fail("no poll ever read the status");
        else if (idx < first + 512) fail("the status was read before the DMA finished");
        else $display("  ok: the port read busy until the last byte was in memory");
        k = 0;
        for (i = 0; i < 512; i = i + 1) if (mem[16'h2000 + i] !== pat_a(i)) k = k + 1;
        if (k != 0) begin
            $display("FAIL: %0d of 512 bytes wrong at $2000", k); errors = errors + 1;
        end else $display("  ok: all 512 bytes landed in memory as sent");

        // The size and status ports.
        wait_store(16'h0305, 100);
        if (mem[16'h0303] !== 8'h34 || mem[16'h0304] !== 8'h12) begin
            $display("FAIL: size read back $%02x%02x, expected $1234", mem[16'h0304], mem[16'h0303]);
            errors = errors + 1;
        end else $display("  ok: $C0F9/$C0FA read back the size from HD_DONE");
        if (mem[16'h0305] !== 8'h00) fail("$C0F1 did not read back the last status");
        else $display("  ok: $C0F1 reads back the status");

        // --- case 5 / HD_FETCH: DMA out, HD_DATA to the host, then HD_DONE ---
        wait (execs == 3);
        cycles(3);
        mark = nops;
        out_n = 0;
        push_word(hdr(T_HD_FETCH, 8'd1, 16'd0));
        push_word({16'd512, 16'h4000});
        // Capture traffic while the block is being sent, to try to interleave.
        wait (tx_valid);
        @(negedge clk);
        offer(hdr(T_BUS_EVENTS, 8'd2, 16'd0));
        offer(32'hEEEE_0001);
        offer(32'hEEEE_0002);
        wait (!tx_valid);
        repeat (20) @(posedge clk);
        if (busy !== 1'b1) fail("busy dropped with the fetch - HD_DONE is still owed");
        n_r = 0; n_w = 0;
        for (i = mark; i < nops; i = i + 1) begin
            if (log_ovr[i] && !log_rw[i]) n_w = n_w + 1;
            if (log_ovr[i] && log_rw[i]) begin
                if (log_addr[i] !== 16'h4000 + n_r[15:0]) fail("a DMA read was out of sequence");
                n_r = n_r + 1;
            end
        end
        if (n_r != 512) begin
            $display("FAIL: %0d DMA reads, expected 512", n_r); errors = errors + 1;
        end else $display("  ok: 512 DMA reads, $4000..$41FF in order");
        if (n_w != 0) fail("a fetch wrote to memory");
        hdr_at = -1; ev_at = -1;
        for (i = 0; i < out_n; i = i + 1) begin
            if (out_mem[i] === {16'd512, T_HD_DATA, 8'd128} && hdr_at < 0) hdr_at = i;
            if (out_mem[i] === hdr(T_BUS_EVENTS, 8'd2, 16'd0)) ev_at = i;
        end
        if (hdr_at < 0) fail("no HD_DATA header on the wire");
        else begin
            k = 0;
            for (i = 0; i < 128; i = i + 1)
                if (out_mem[hdr_at + 1 + i] !== {pat_b(4*i+3), pat_b(4*i+2), pat_b(4*i+1), pat_b(4*i)})
                    k = k + 1;
            if (k != 0) begin
                $display("FAIL: %0d of 128 HD_DATA words wrong", k); errors = errors + 1;
            end else $display("  ok: HD_DATA carries the 512 bytes read, in order");
        end
        if (ev_at < 0) fail("the capture message was lost");
        else if (ev_at > hdr_at && ev_at < hdr_at + 129) fail("the capture message landed inside HD_DATA");
        else if (out_mem[ev_at+1] !== 32'hEEEE_0001 || out_mem[ev_at+2] !== 32'hEEEE_0002)
            fail("HD_DATA landed inside the capture message");
        else $display("  ok: HD_DATA and the capture message each came out whole");

        push_word(hdr(T_HD_DONE, 8'd0, 16'h0001));            // status $01, no bytes
        wait_store(16'h0306, 200);
        if (mem[16'h0306] !== 8'h01) begin
            $display("FAIL: EXECUTE #3 returned $%02x, expected $01", mem[16'h0306]);
            errors = errors + 1;
        end else $display("  ok: a header-only HD_DONE releases the port with its status");

        // --- case 6 / no answer: the timeout completes with no-device -------
        wait (execs == 4);
        wait_store(16'h0307, STALL_TIMEOUT / CYCLE + 100);
        if (mem[16'h0307] !== 8'h51) begin
            $display("FAIL: the timeout returned $%02x, expected $51", mem[16'h0307]);
            errors = errors + 1;
        end else $display("  ok: an unanswered command times out with $51 (no device connected)");

        // --- case 7 / an unarmed read is a poll ---------------------------------
        wait_store(16'h0308, 100);
        if (mem[16'h0308] !== 8'h51) fail("the unarmed read did not return the last status");
        else if (execs !== 8'd4) fail("the unarmed read executed something");
        else $display("  ok: a $C0F0 read with nothing armed is a poll, not a command");

        // A late answer to the timed-out command must change nothing.
        push_word(hdr(T_HD_DONE, 8'd2, 16'h0000));
        push_word({16'd0, 16'h0000});
        push_word({16'd0, 16'hBEEF});
        repeat (60) @(posedge clk);
        if (dut.status !== 8'h51 || dut.size !== 16'h1234)
            fail("a late HD_DONE changed the status or size latch");
        else $display("  ok: a late HD_DONE is ignored");

        // --- case 8 / the ROM follows INTCXROM -------------------------------
        wait_store(16'h030A, 200);
        if (mem[16'h0309] !== 8'hEE) begin
            $display("FAIL: with INTCXROM set $C700 read $%02x, expected the float", mem[16'h0309]);
            errors = errors + 1;
        end else $display("  ok: INTCXROM set - $C700 is not claimed");
        if (mem[16'h030A] !== rom_at(0)) fail("INTCXROM cleared, but the ROM did not come back");
        else $display("  ok: INTCXROM cleared - the ROM is back");

        // --- case 9 / a reset while busy drops it, and the machine boots -------
        wait (execs == 5);
        cycles(5);
        if (busy !== 1'b1) fail("not busy at EXECUTE #5");
        for (i = 16'h0300; i < 16'h0310; i = i + 1) mem[i] = 8'hxx;
        machine_reset(4);
        if (busy !== 1'b0) fail("reset did not drop busy");
        else $display("  ok: RES' drops what was outstanding");
        wait_store(16'h0300, 100);
        if (mem[16'h0300] !== rom_at(0)) fail("after the reset the ROM did not read back");
        else $display("  ok: after the reset the machine runs from the vector and finds the ROM");
        wait (execs == 7);
        cycles(2);
        push_word(hdr(T_HD_DONE, 8'd0, 16'h0000));
        push_word(hdr(T_HD_DONE, 8'd0, 16'h0000));
        wait_store(16'h0302, 200);
        if (mem[16'h0302] !== 8'h00) fail("the commands after the reset did not complete");
        else $display("  ok: and executes, and completes, as before");

        // --- case 10 / the line drain: the fast regime -----------------------
        // The machine reruns its program; the drain answers EXECUTE #2 with
        // 300 bytes at the unaligned $20F5 - a partial head line, eighteen
        // full lines, a partial tail, two page crossings - while the core
        // keeps running.  Checked: no override cycle, every byte in the
        // right lane of the right line, write -> invalidate -> snoop per
        // line in order, every byte trickled into the shadow, and the seven
        // stream words of every line exact.
        for (i = 16'h0300; i < 16'h0310; i = i + 1) mem[i] = 8'hxx;
        first = execs;
        machine_reset(4);
        wait (execs == first + 1);
        cycles(2);
        push_word(hdr(T_HD_DONE, 8'd0, 16'h0000));       // answer #1, no bytes
        wait (execs == first + 2);
        cycles(3);
        fast_dma = 1'b1; ev_en = 1'b1;
        ndq = 0; ninv = 0; nsn = 0; nfb = 0; nev = 0;
        mark = nops;
        push_word(hdr(T_HD_DONE, 8'd130, 16'h0000));
        push_word({16'd300, 16'h20F5});
        push_word({16'd0, 16'h1234});
        for (i = 0; i < 128; i = i + 1)
            push_word({pat_a(4*i+3), pat_a(4*i+2), pat_a(4*i+1), pat_a(4*i)});
        wait_store(16'h0302, 700);
        if (mem[16'h0302] !== 8'h00) fail("drain: the poll did not exit with status $00");
        else $display("  ok: the drain answered EXECUTE #2 - status $00, busy released");
        if (busy !== 1'b0) fail("drain: still busy after the last line");
        k = 0;
        for (i = mark; i < nops; i = i + 1) if (log_ovr[i]) k = k + 1;
        if (k != 0) begin
            $display("FAIL: %0d override cycles in the fast regime", k); errors = errors + 1;
        end else $display("  ok: no override cycle - the core ran through the drain");
        for (i = 0; i < 65536; i = i + 1) begin got[i] = 8'hxx; gev[i] = 8'hxx; end
        for (i = 0; i < ndq; i = i + 1) begin
            if (dql_line[i][19:12] != 8'd0) fail("drain: a line outside main memory");
            for (k = 0; k < 16; k = k + 1)
                if (dql_be[i][k]) got[{dql_line[i][11:0], k[3:0]}] = dql_data[i][8*k +: 8];
        end
        ebytes = 0;
        for (i = 0; i < 300; i = i + 1)
            if (got[16'h20F5 + i[15:0]] !== pat_a(i)) ebytes = ebytes + 1;
        if (ebytes != 0) begin
            $display("FAIL: %0d of 300 drained bytes wrong or missing", ebytes); errors = errors + 1;
        end else $display("  ok: 300 bytes at $20F5, every one in the right lane of the right line");
        if (ndq != 20) begin
            $display("FAIL: %0d line writes, expected 20", ndq); errors = errors + 1;
        end else $display("  ok: 20 line writes - a trimmed head, eighteen whole, a trimmed tail");
        if (ninv != ndq || nsn != ndq) fail("drain: invalidate/snoop counts differ from the writes");
        k = 0;
        for (i = 0; i < ndq; i = i + 1) begin
            if (invl[i][23:4] !== dql_line[i]) k = k + 1;
            if (snl[i][23:4]  !== dql_line[i]) k = k + 1;
            if (!(dql_at[i] < invl_at[i] && invl_at[i] < snl_at[i])) k = k + 1;
        end
        if (k != 0) begin
            $display("FAIL: %0d per-line order/address violations", k); errors = errors + 1;
        end else $display("  ok: write -> invalidate -> snoop, per line, same address, in order");
        if (nfb != 300) begin
            $display("FAIL: %0d shadow bytes, expected 300", nfb); errors = errors + 1;
        end else if (fbl_addr[0] !== 16'h20F5 || fbl_data[0] !== pat_a(0) ||
                     fbl_addr[299] !== 16'h2220 || fbl_data[299] !== pat_a(299))
            fail("drain: shadow bytes wrong at the edges");
        else $display("  ok: all 300 bytes trickled into the hi-res shadow in order");
        if (nev != 140) begin
            $display("FAIL: %0d stream words, expected 140", nev); errors = errors + 1;
        end else begin
            k = 0;
            for (i = 0; i < 20; i = i + 1) begin
                for (idx = 0; idx < 7; idx = idx + 1)
                    if (evl[7*i+idx][31:24] !== {4'hB, idx[3:0]}) k = k + 1;
                eaddr = evl[7*i][23:8];
                ebe   = {evl[7*i][7:0], evl[7*i+1][23:16]};
                if (ebe !== dql_be[i] || eaddr[15:4] !== dql_line[i][11:0]) k = k + 1;
                gev[eaddr+15] = evl[7*i+1][15:8];  gev[eaddr+14] = evl[7*i+1][7:0];
                gev[eaddr+13] = evl[7*i+2][23:16]; gev[eaddr+12] = evl[7*i+2][15:8];
                gev[eaddr+11] = evl[7*i+2][7:0];
                gev[eaddr+10] = evl[7*i+3][23:16]; gev[eaddr+9] = evl[7*i+3][15:8];
                gev[eaddr+8]  = evl[7*i+3][7:0];
                gev[eaddr+7]  = evl[7*i+4][23:16]; gev[eaddr+6] = evl[7*i+4][15:8];
                gev[eaddr+5]  = evl[7*i+4][7:0];
                gev[eaddr+4]  = evl[7*i+5][23:16]; gev[eaddr+3] = evl[7*i+5][15:8];
                gev[eaddr+2]  = evl[7*i+5][7:0];
                gev[eaddr+1]  = evl[7*i+6][23:16]; gev[eaddr+0] = evl[7*i+6][15:8];
            end
            for (i = 0; i < 300; i = i + 1)
                if (gev[16'h20F5 + i[15:0]] !== pat_a(i)) k = k + 1;
            if (k != 0) begin
                $display("FAIL: %0d stream-word decode errors", k); errors = errors + 1;
            end else $display("  ok: 20 groups of 7 words - tags, sequences, BE, address and every byte exact");
        end

        // --- case 10b / a page that does not land, capture off ---------------
        // EXECUTE #3 answered by a drain into $21F0 x 48 with page $22
        // marked not-landing: one line written, two skipped whole, no
        // events, busy still released.
        wait (execs == first + 3);
        cycles(3);
        t2_block[8'h22] = 1'b1; ev_en = 1'b0;
        ndq = 0; ninv = 0; nsn = 0; nev = 0; nfb = 0;
        push_word(hdr(T_HD_DONE, 8'd14, 16'h0000));
        push_word({16'd48, 16'h21F0});
        push_word({16'd0, 16'h1234});
        for (i = 0; i < 12; i = i + 1)
            push_word({pat_b(4*i+3), pat_b(4*i+2), pat_b(4*i+1), pat_b(4*i)});
        wait_store(16'h0306, 700);
        if (busy !== 1'b0) fail("drain 10b: still busy");
        if (ndq != 1 || ninv != 1 || nsn != 1) begin
            $display("FAIL: 10b wrote %0d lines (inv %0d, snoop %0d), expected 1", ndq, ninv, nsn);
            errors = errors + 1;
        end else if (dql_be[0] !== 16'hFFFF || dql_line[0] !== {8'd0, 12'h21F}) fail("10b: the one line is wrong");
        else $display("  ok: a not-landing page is skipped whole; the landing line went alone");
        if (nev != 0) fail("10b: stream words with the capture off");
        else $display("  ok: capture off - no stream words, and the drain still ran");
        t2_block[8'h22] = 1'b0;

        // --- case 10c / RES' mid-drain ---------------------------------------
        wait (execs == first + 5);
        cycles(3);
        ev_en = 1'b1;
        ndq = 0;
        push_word(hdr(T_HD_DONE, 8'd130, 16'h0000));
        push_word({16'd512, 16'h6000});
        push_word({16'd0, 16'h1234});
        for (i = 0; i < 128; i = i + 1)
            push_word({pat_a(4*i+3), pat_a(4*i+2), pat_a(4*i+1), pat_a(4*i)});
        wait (ndq >= 3);
        for (i = 16'h0300; i < 16'h0310; i = i + 1) mem[i] = 8'hxx;
        machine_reset(4);
        if (busy !== 1'b0) fail("drain 10c: RES' did not drop the command");
        else $display("  ok: RES' mid-drain drops it - a part-drained block is stale bytes, nothing hangs");
        wait (execs == first + 6);
        cycles(2);
        push_word(hdr(T_HD_DONE, 8'd0, 16'h0000));
        wait (execs == first + 7);
        cycles(2);
        push_word(hdr(T_HD_DONE, 8'd0, 16'h0000));
        wait_store(16'h0302, 400);
        if (mem[16'h0302] !== 8'h00) fail("drain 10c: the port did not work after the reset");
        else $display("  ok: and the port executes and completes as before");

        if (unknowns != 0) fail("the receiver reported an unknown type - a disk type is missing from its list");
        else $display("  ok: HD_ROM, HD_DONE and HD_FETCH are known types");

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: timed out");
        $finish;
    end

endmodule
