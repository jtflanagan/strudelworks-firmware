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
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .drv_sync (drv_sync),
        .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (rd_claim), .slot_rd_data (rd_data),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (ovr_rw),
        .ovr_wdata (ovr_wdata), .op_ovr (op_ovr),
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

    wire        msg_valid, pay_valid, frame_error;
    wire [7:0]  msg_type, msg_len;
    wire [15:0] msg_free;
    wire [31:0] pay_data;

    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .frame_error (frame_error)
    );

    // ---- the disk -----------------------------------------------------------
    wire [31:0] tx_word;
    wire        tx_valid, tx_take;
    wire        rom_loaded, busy;
    wire [7:0]  execs;

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
        .rom_loaded (rom_loaded), .busy (busy), .execs (execs)
    );

    // ---- card -> host: through the real arbiter -----------------------------
    reg  [31:0] src_data = 32'd0;
    reg         src_push = 1'b0;
    wire        src_full;
    wire [31:0] tx_data;
    wire        tx_push;

    tx_arb u_arb (
        .clk (clk), .rst (rst),
        .src_data (src_data), .src_push (src_push), .src_full (src_full),
        .rsp_addr (32'd0), .rsp_data (32'd0), .rsp_valid (1'b0), .rsp_take (),
        .note_word (32'd0), .note_valid (1'b0), .note_take (),
        .aux_word (tx_word), .aux_valid (tx_valid), .aux_take (tx_take),
        .tx_data (tx_data), .tx_push (tx_push), .tx_full (1'b0)
    );

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
        src_data = hdr(T_BUS_EVENTS, 8'd2, 16'd0); src_push = 1'b1;
        @(negedge clk); src_data = 32'hEEEE_0001;
        @(negedge clk); src_data = 32'hEEEE_0002;
        @(negedge clk); src_push = 1'b0;
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

        if (frame_error !== 1'b0) fail("the receiver lost framing - a type is missing from hdr_known");
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
