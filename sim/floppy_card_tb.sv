`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// floppy_card_tb - the Disk II's slot behind the real driver, with the tb
// playing both the program and the host.
//
// A scripted CPU (mockingboard_tb's) presents one op per bus cycle through
// the real apple_bus_write, so every access lands on an exact cycle - which
// is the whole point of a floppy: its loops are counted to the cycle.  The
// real ft601_msg_rx feeds the card the host's ROM and track chunks, and the
// real msg_master/msg_arb carry its FD_SEEK and FD_DIRTY messages out, where
// the tb parses them as the host would.
//
// THE PROPERTIES, each a way this is or could be wrong:
//
//   * nothing is claimed until the host has loaded the ROM; $Cn00 follows
//     INTCXROM; odd $C0nx addresses are the floating bus, even ones the
//     register.
//   * a disk inserted is one FD_SEEK for the track under the head; a chunk
//     with a stale seq is dropped; the seventh chunk clears STALE.
//   * a read taken before_cyc the fill lands counts as `late`, and fill_max
//     records the fill.
//   * a nibble every 32 cycles, exactly: the seven-cycle poll loop reads
//     every nibble of the track once, in order, and a register read every
//     cycle sees each nibble held for eight cycles and the next shifting in
//     for twenty-four.
//   * the head moves ten cycles after the magnet, toward an energised
//     adjacent magnet, not at all when both adjacent magnets are on; a
//     track change is one FD_SEEK, and the register serves no address field
//     of the old track meanwhile.
//   * the second drive is its own head through the ONE shared buffer:
//     selecting it empty asks for nothing, inserting a disk fetches its
//     track, and switching back flushes-and-refetches - both drives' tracks
//     survive the round trip.
//   * motor off coasts, then holds the register; $C0nD/$C0nE sense
//     write-protect.
//   * a sector written at the machine's own pace - self-sync bytes at 40
//     cycles, data at 32 - comes back to the host contiguous, $FF in the
//     skipped slots, as seven FD_DIRTY chunks before the FD_SEEK that leaves
//     the track.
//   * RES' clears the switches and nothing else.
//   * the register is never driven for a read the card did not claim, and
//     the card never raises an override.
//////////////////////////////////////////////////////////////////////////////////

module floppy_card_tb;

    localparam integer T_PRESENT = 2;
    localparam integer T_EMIT    = 2;
    localparam integer T_DIN     = 44;
    localparam integer T_CYCEN   = 45;

    // Short, so a spin-down is thousands of cycles, not a million.
    localparam integer SPIN_TICKS   = 3000;
    localparam integer STABLE_TICKS = 64;

    localparam [7:0] T_FD_ROM   = 8'h1E;
    localparam [7:0] T_FD_TRACK = 8'h1F;
    localparam [7:0] T_FD_SEEK  = 8'h20;
    localparam [7:0] T_FD_DIRTY = 8'h21;
    localparam [7:0] T_BUS_EVENTS = 8'h12;

    // Slot 6.
    localparam [15:0] IO      = 16'hC0E0;
    localparam [15:0] SLOTROM = 16'hC600;
    localparam [15:0] PH0OFF = IO + 0, PH0ON = IO + 1, PH1OFF = IO + 2, PH1ON = IO + 3;
    localparam [15:0] PH2OFF = IO + 4, PH2ON = IO + 5, PH3OFF = IO + 6, PH3ON = IO + 7;
    localparam [15:0] MOTOROFF = IO + 8, MOTORON = IO + 9;
    localparam [15:0] DRIVE1 = IO + 10, DRIVE2 = IO + 11;
    localparam [15:0] Q6L = IO + 12, Q6H = IO + 13, Q7L = IO + 14, Q7H = IO + 15;
    localparam [15:0] ELSEWHERE = 16'h1234;

    localparam integer NIB_DSK = 6384;
    localparam integer TRACK_WORDS = 1664;
    localparam integer CHUNK_WORDS = 252;

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

    // ---- the scripted CPU ---------------------------------------------------
    reg  [15:0] cpu_addr = 16'h0000;
    reg         cpu_rw   = 1'b1;
    reg  [7:0]  cpu_dout = 8'h00;
    wire        cyc_en;
    wire [7:0]  cpu_din;

    integer bus_cycles = 0;
    always @(posedge clk) if (cyc_en) bus_cycles = bus_cycles + 1;

    task bus_op(input [15:0] addr, input rw, input [7:0] dout);
        begin
            cpu_addr = addr; cpu_rw = rw; cpu_dout = dout;
            @(posedge cyc_en);
            @(posedge clk);
        end
    endtask
    task bus_write(input [15:0] addr, input [7:0] data);
        bus_op(addr, 1'b0, data);
    endtask
    task bus_read(input [15:0] addr);
        bus_op(addr, 1'b1, 8'h00);
    endtask
    task idle(input integer n);
        begin repeat (n) bus_read(ELSEWHERE); end
    endtask

    // ---- the DUT and the board's wiring -------------------------------------
    reg         master_active = 1'b1;
    reg         res_n = 1'b1;           // active low, idle high
    wire        cpu_rst = rst || !res_n;

    wire [15:0] op_addr;
    wire        op_rw, op_present, op_commit, op_ovr;
    wire [7:0]  op_wdata;
    wire        rd_claim;
    wire [7:0]  rd_data;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, drv_sync, driving;
    wire [7:0]  data_drive;

    // The round trip: the float is $EE, so a read of it cannot pass by luck.
    wire [7:0] data_sync = data_oe ? data_drive : 8'hEE;

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) u_write (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0), .data_sync (data_sync),
        .master_active (master_active), .park_kbd (1'b0),
        // Without the sequencer: the bus owns every cycle, the core is always on offer.
        .bus_owns (1'b1), .core_valid (1'b1),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (1'b0), .drv_sync (drv_sync),
        .cyc_en (cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (rd_claim), .slot_rd_data (rd_data),
        .din_sub_en (1'b0), .din_sub_data (8'h00),
        .ovr_en (1'b0), .ovr_addr (16'h0000), .ovr_rw (1'b1), .ovr_wdata (8'h00),
        .op_ovr (op_ovr), .nxt_addr (), .divert (1'b0), .op_divert (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- host -> card: a FIFO the real parser reads -------------------------
    // The simulator does not reliably re-evaluate a combinational read of a
    // memory a task just wrote (sim/boot_tb.sv learned it first), so the
    // head loads through a clocked stage: FWFT with a one-clock refill, the
    // receiver simply seeing empty between words.
    reg  [31:0] rx_mem [0:32767];
    integer     rx_wr = 0, rx_rd = 0;
    reg  [31:0] rx_head = 32'd0;
    reg         rx_head_v = 1'b0;
    wire [31:0] rx_dout  = rx_head;
    wire        rx_empty = !rx_head_v;
    wire        rx_rd_en;
    always @(posedge clk) begin
        if (rst) begin
            rx_head_v <= 1'b0;
        end else if ((rx_rd_en && rx_head_v) || !rx_head_v) begin
            if (rx_rd < rx_wr) begin
                rx_head <= rx_mem[rx_rd % 32768];
                rx_head_v <= 1'b1;
                rx_rd <= rx_rd + 1;
            end else rx_head_v <= 1'b0;
        end
    end

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

    // ---- the floppy ---------------------------------------------------------
    // One whole variable per drive and field, concatenated into the ports:
    // The simulator does not propagate a part-select written from the initial
    // block into a continuous assignment the DUT reads (the control run
    // showed the card seeing tracks = 0 after `drv_tracks[5:0] = 35`).
    reg         ins0 = 1'b0, ins1 = 1'b0, wp0 = 1'b0, wp1 = 1'b0, fl0 = 1'b0, fl1 = 1'b0;
    reg  [7:0]  cell0 = 8'd0, cell1 = 8'd0;   // the bit cell, eighths of a cycle
    reg  [5:0]  trk0 = 6'd0, trk1 = 6'd0;
    wire [1:0]  drv_inserted = {ins1, ins0}, drv_wp = {wp1, wp0}, drv_flush = {fl1, fl0};
    wire [25:0] drv_cell     = {5'd0, cell1, 5'd0, cell0};
    wire [11:0] drv_tracks   = {trk1, trk0};
    reg         late_clr = 1'b0, fill_clr = 1'b0;
    reg  [2:0]  slot_assign = 3'd6;
    wire [31:0] tx_word;
    wire        tx_valid, tx_take;
    wire        rom_loaded, motor, drive_sel, q6, q7;
    wire [1:0]  stale, dirty;
    wire [13:0] phase;
    wire [7:0]  seeks, late;
    wire [15:0] fill_max;

    floppy_card #(.SPIN_TICKS (SPIN_TICKS), .STABLE_TICKS (STABLE_TICKS)) dut (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .res_sync (res_n),
        .master_active (master_active), .slot_assign (slot_assign),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit), .op_ovr (op_ovr),
        .op_dummy (1'b0), .fast_tick (1'b0),
        .rd_claim (rd_claim), .rd_data (rd_data),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .tx_word (tx_word), .tx_valid (tx_valid), .tx_take (tx_take),
        .drv_inserted (drv_inserted), .drv_wp (drv_wp),
        .drv_cell (drv_cell), .drv_tracks (drv_tracks), .drv_flush (drv_flush),
        .late_clr (late_clr), .fill_clr (fill_clr),
        .rom_loaded (rom_loaded), .stale_o (stale), .dirty_o (dirty),
        .phase_o (phase), .motor_o (motor), .drive_sel_o (drive_sel),
        .q6_o (q6), .q7_o (q7), .seeks (seeks), .late (late), .fill_max (fill_max), .stall_o ()
    );

    // ---- card -> host: through the real arbiter, parsed as the host would ---
    // The floppy's master above a capture the tb plays, as in card_link.
    reg  [31:0] src_data  = 32'd0;
    reg         src_valid = 1'b0;
    wire        src_take;
    reg         src_took  = 1'b0;
    always @(posedge clk) src_took <= src_valid && src_take;
    task offer(input [31:0] w);
        begin
            src_data = w; src_valid = 1'b1;
            @(negedge clk);
            while (!src_took) @(negedge clk);
            src_valid = 1'b0;
        end
    endtask

    wire [1:0]  mb_cyc, mb_stb, mb_we, mb_stall, mb_ack;
    wire [63:0] mb_adr, mb_dat;
    wire [7:0]  mb_sel;
    wire        sb_cyc, sb_stb, sb_we;
    wire [31:0] sb_adr, sb_dat;
    wire [3:0]  sb_sel;
    reg         sb_ack = 1'b0;

    msg_master u_m_fd (
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
    wire tx_push = sb_cyc && sb_stb;
    always @(posedge clk) sb_ack <= !rst && sb_cyc && sb_stb;

    // Every word out, and the messages parsed out of them by length.
    reg [31:0] out_mem [0:65535];
    integer    out_n = 0;
    integer    nmsg = 0;
    integer    msg_at  [0:4095];
    reg [7:0]  msg_typ [0:4095];
    integer    parse_left = 0;
    always @(posedge clk) if (tx_push) begin
        out_mem[out_n] = sb_dat;
        if (parse_left == 0) begin
            msg_at[nmsg]  = out_n;
            msg_typ[nmsg] = sb_dat[15:8];
            parse_left    = sb_dat[7:0];
            nmsg = nmsg + 1;
        end else begin
            parse_left = parse_left - 1;
        end
        out_n = out_n + 1;
    end

    // ---- observers ----------------------------------------------------------
    integer read_drive_unclaimed = 0;
    always @(posedge clk) if (!rst) begin
        if (data_oe && rw_drive && !rd_claim)
            read_drive_unclaimed = read_drive_unclaimed + 1;
    end
    integer overrides = 0;
    always @(posedge clk) if (op_present && op_ovr) overrides = overrides + 1;
    // A bit of the card's buffer as it stands, straight from the banks.
    function up_bit_live(input integer i);
        integer b;
        begin
            b = (i / 8) % 6656;
            case (b % 4)
                0: up_bit_live = dut.g_bank[0].u_bank.mem[b / 4][7 - (i % 8)];
                1: up_bit_live = dut.g_bank[1].u_bank.mem[b / 4][7 - (i % 8)];
                2: up_bit_live = dut.g_bank[2].u_bank.mem[b / 4][7 - (i % 8)];
                default: up_bit_live = dut.g_bank[3].u_bank.mem[b / 4][7 - (i % 8)];
            endcase
        end
    endfunction
    // The bit position the first write of a burst landed on: -1 until one does.
    integer first_w = -1;
    always @(posedge clk) if (dut.w_go && first_w < 0) first_w = dut.wpend_pos;
    // Every bit that lands in the buffer, and a byte of the buffer as it stands.
    integer wgos = 0;
    always @(posedge clk) if (dut.w_go) wgos = wgos + 1;
    reg [7:0] snap [0:6655];
    function [7:0] buf_byte(input integer b);
        case (b % 4)
            0: buf_byte = dut.g_bank[0].u_bank.mem[b / 4];
            1: buf_byte = dut.g_bank[1].u_bank.mem[b / 4];
            2: buf_byte = dut.g_bank[2].u_bank.mem[b / 4];
            default: buf_byte = dut.g_bank[3].u_bank.mem[b / 4];
        endcase
    endfunction

    // ---- the host's image ---------------------------------------------------
    // Nibble i of track t: one of the 64 legal 6&2 nibbles - the disk
    // alphabet has no more than two zeros in a row, because the MC3470
    // turns the fourth zero into noise, and this engine does too - and
    // neighbours never equal (11 is odd, so the index moves every slot).
    function [7:0] n62(input integer k);
        case (k & 63)
            0: n62 = 8'h96;  1: n62 = 8'h97;  2: n62 = 8'h9A;  3: n62 = 8'h9B;  4: n62 = 8'h9D;  5: n62 = 8'h9E;  6: n62 = 8'h9F;  7: n62 = 8'hA6;
            8: n62 = 8'hA7;  9: n62 = 8'hAB; 10: n62 = 8'hAC; 11: n62 = 8'hAD; 12: n62 = 8'hAE; 13: n62 = 8'hAF; 14: n62 = 8'hB2; 15: n62 = 8'hB3;
           16: n62 = 8'hB4; 17: n62 = 8'hB5; 18: n62 = 8'hB6; 19: n62 = 8'hB7; 20: n62 = 8'hB9; 21: n62 = 8'hBA; 22: n62 = 8'hBB; 23: n62 = 8'hBC;
           24: n62 = 8'hBD; 25: n62 = 8'hBE; 26: n62 = 8'hBF; 27: n62 = 8'hCB; 28: n62 = 8'hCD; 29: n62 = 8'hCE; 30: n62 = 8'hCF; 31: n62 = 8'hD3;
           32: n62 = 8'hD6; 33: n62 = 8'hD7; 34: n62 = 8'hD9; 35: n62 = 8'hDA; 36: n62 = 8'hDB; 37: n62 = 8'hDC; 38: n62 = 8'hDD; 39: n62 = 8'hDE;
           40: n62 = 8'hDF; 41: n62 = 8'hE5; 42: n62 = 8'hE6; 43: n62 = 8'hE7; 44: n62 = 8'hE9; 45: n62 = 8'hEA; 46: n62 = 8'hEB; 47: n62 = 8'hEC;
           48: n62 = 8'hED; 49: n62 = 8'hEE; 50: n62 = 8'hEF; 51: n62 = 8'hF2; 52: n62 = 8'hF3; 53: n62 = 8'hF4; 54: n62 = 8'hF5; 55: n62 = 8'hF6;
           56: n62 = 8'hF7; 57: n62 = 8'hF9; 58: n62 = 8'hFA; 59: n62 = 8'hFB; 60: n62 = 8'hFC; 61: n62 = 8'hFD; 62: n62 = 8'hFE; default: n62 = 8'hFF;
        endcase
    endfunction
    function [7:0] nib(input integer t, input integer i);
        nib = n62(t * 37 + i * 11 + 5);
    endfunction
    function [7:0] rom_at(input integer i);
        rom_at = (i == 0) ? 8'hA2 : (8'h20 + i[7:0]);
    endfunction

    // The host's image of one track, as bits: byte i holds bits 8i..8i+7,
    // high bit first.  send_track fills it from nib(); a case may build it
    // by hand and use send_bits.
    reg [7:0] host_img [0:6655];
    function bit_of(input integer i);
        bit_of = host_img[i / 8][7 - (i % 8)];
    endfunction
    task set_bit(input integer i, input v);
        host_img[i / 8][7 - (i % 8)] = v;
    endtask

    // The host's answer: seven chunks of host_img, each {seq, chunk, qtr,
    // drive} then {bits} then 252 words (152 in the last).
    task send_bits(input integer drive, input integer qtr, input [7:0] seq, input integer bits);
        integer c, w, n, i;
        begin
            for (c = 0; c < 7; c = c + 1) begin
                n = (c == 6) ? (TRACK_WORDS - 6 * CHUNK_WORDS) : CHUNK_WORDS;
                push_word(hdr(T_FD_TRACK, n[7:0] + 8'd2, 16'd0));
                push_word({seq, c[7:0], qtr[7:0], drive[7:0]});
                push_word({16'd0, bits[15:0]});
                for (w = 0; w < n; w = w + 1) begin
                    i = 4 * (c * CHUNK_WORDS + w);
                    push_word({host_img[i+3], host_img[i+2], host_img[i+1], host_img[i]});
                end
            end
        end
    endtask
    // A sector image's track as the host would send it: 6384 nibbles, and
    // every 32nd group of four is a self-sync gap - $FF with two zero bits
    // after it, ten bits, the way a real track's gaps are - so the LSS can
    // realign wherever a fill lands under it.  Slot j of `track` is
    // expected(track, j); a gap slot reads as $FF.
    function is_gap(input integer j);
        is_gap = ((j % 32) < 4);
    endfunction
    function [7:0] expected(input integer track, input integer j);
        expected = is_gap(j) ? 8'hFF : nib(track, j);
    endfunction
    integer sent_bits = 0;
    task send_track(input integer drive, input integer track, input [7:0] seq);
        integer i, j, k;
        reg [7:0] v;
        begin
            for (i = 0; i < 6656; i = i + 1) host_img[i] = 8'hFF;
            k = 0;
            for (j = 0; j < NIB_DSK; j = j + 1) begin
                v = expected(track, j);
                for (i = 0; i < 8; i = i + 1) set_bit(k + i, v[7 - i]);
                k = k + 8;
                if (is_gap(j)) begin set_bit(k, 1'b0); set_bit(k + 1, 1'b0); k = k + 2; end
            end
            sent_bits = k;
            send_bits(drive, 4 * track, seq, k);
        end
    endtask
    // The words the card sends: FD_SEEK's {seq, 0, qtr, phase, drive} and
    // FD_DIRTY's {seq, 0, chunk, qtr, 0, drive}.
    function [31:0] seekw(input [7:0] seq, input integer qtr, input integer ph, input integer drive);
        seekw = {seq, 8'd0, qtr[7:0], ph[6:0], drive[0]};
    endfunction
    function [31:0] dirtyw(input [7:0] seq, input integer chunk, input integer qtr, input integer drive);
        dirtyw = {seq, 5'd0, chunk[2:0], qtr[7:0], 7'd0, drive[0]};
    endfunction

    // Wait for the next message of a type from a watermark; return its index.
    task wait_msg(input [7:0] t, input integer from, output integer found, input integer max_cycles);
        integer n, k;
        begin
            found = -1; n = 0;
            while (found < 0 && n < max_cycles) begin
                for (k = from; k < nmsg; k = k + 1)
                    if (found < 0 && msg_typ[k] == t) found = k;
                if (found < 0) begin bus_read(ELSEWHERE); n = n + 1; end
            end
        end
    endtask

    // An FD_DIRTY upload reassembled from the messages after a watermark.
    reg [7:0] up_img [0:6655];
    integer   up_bits;
    function up_bit(input integer i);
        up_bit = up_img[(i / 8) % 6656][7 - (i % 8)];
    endfunction
    task gather_upload(input integer from, output integer chunks_seen, output integer first_at);
        integer k, c, w, n, i, base;
        reg [31:0] wd;
        begin
            chunks_seen = 0; first_at = -1;
            for (k = from; k < nmsg; k = k + 1) begin
                if (msg_typ[k] == T_FD_DIRTY) begin
                    if (first_at < 0) first_at = k;
                    base = msg_at[k];
                    c = out_mem[base + 1][18:16];
                    n = out_mem[base][7:0] - 2;
                    up_bits = out_mem[base + 2][15:0];
                    for (w = 0; w < n; w = w + 1) begin
                        wd = out_mem[base + 3 + w];
                        i = 4 * (c * CHUNK_WORDS + w);
                        up_img[i]   = wd[7:0];
                        up_img[i+1] = wd[15:8];
                        up_img[i+2] = wd[23:16];
                        up_img[i+3] = wd[31:24];
                    end
                    chunks_seen = chunks_seen + 1;
                end
            end
        end
    endtask

    // The RWTS's loop: LDA $C0EC,X / BPL, seven cycles around.  Reads n
    // nibbles, first-seen, into seq_mem, with the cycle each was seen.
    reg [7:0] seq_mem [0:255];
    integer   seq_cyc [0:255];
    integer   polled = 0;
    task poll_nibbles(input integer n);
        integer got, max;
        reg [7:0] last;
        begin
            got = 0; last = 8'h00; max = 0; polled = n;
            while (got < n && max < n * 64) begin
                bus_read(Q6L);
                if (cpu_din[7] && cpu_din != last) begin
                    seq_mem[got] = cpu_din;
                    seq_cyc[got] = bus_cycles;
                    last = cpu_din;
                    got = got + 1;
                end
                // The register shows the next nibble shifting in, high bit
                // clear, between two complete ones: so two equal nibbles in
                // a row (a sync gap's $FFs) are told apart, as the RWTS
                // tells them apart.
                if (!cpu_din[7]) last = 8'h00;
                idle(6);
                max = max + 1;
            end
            if (got < n) fail("the poll loop starved: not enough nibbles");
        end
    endtask

    // Is seq_mem[0..n) a run of consecutive nibbles of `track`?  Returns the
    // start slot, or -1.
    // Is there a run of n consecutive slots of `track` anywhere in the
    // polled nibbles (run_at says where in seq_mem)?  Returns the track
    // slot the run starts at, or -1.  The LSS may need a gap or two to
    // align after a fill lands under a turning head, so the run need not
    // begin at the first nibble read.
    integer run_at = 0;
    function integer run_start(input integer track, input integer n, input integer nibbles);
        integer p, i, a, ok;
        begin
            run_start = -1;
            for (a = 0; a + n <= polled && run_start < 0; a = a + 1)
                for (p = 0; p < nibbles && run_start < 0; p = p + 1) begin
                    if (seq_mem[a] == expected(track, p) && seq_mem[a + 1] == expected(track, (p + 1) % nibbles)) begin
                        ok = 1;
                        for (i = 0; i < n; i = i + 1)
                            if (seq_mem[a + i] !== expected(track, (p + i) % nibbles)) ok = 0;
                        if (ok) begin run_start = p; run_at = a; end
                    end
                end
        end
    endfunction

    // One 32-cycle step of a write burst: load the byte, shift it out.
    task write_nibble(input [7:0] b, input integer spacing);
        begin
            bus_write(Q6H, b);            // STA $C08D,X: the LD
            bus_read(Q6L);                // ORA $C08C,X: the shift
            idle(spacing - 2);
        end
    endtask

    integer i, k, m, at, at2, start, seq_val, seen, held, low, n_up, first_up, first_seek;
    integer t0, t1, cyc0, cyc1, before_cyc;
    reg [7:0] v, first_data;
    reg [7:0] old_late;

    initial begin
        $display("floppy_card_tb: a Disk II in slot 6, the host at the other end - bit tracks\n");
        repeat (8) @(posedge clk);
        rst = 0;
        repeat (3) @(posedge cyc_en);

        // --- case 1 / nothing until the ROM ----------------------------------
        bus_read(SLOTROM);
        if (cpu_din !== 8'hEE) fail("$C600 answered before_cyc a ROM was loaded");
        bus_read(Q6L);
        if (cpu_din !== 8'hEE) fail("$C0EC answered before_cyc a ROM was loaded");
        else $display("  ok: no ROM - nothing is claimed");

        push_word(hdr(T_FD_ROM, 8'd64, 16'd0));
        for (i = 0; i < 64; i = i + 1)
            push_word({rom_at(4*i+3), rom_at(4*i+2), rom_at(4*i+1), rom_at(4*i)});
        idle(4);
        if (rom_loaded !== 1'b1) fail("the ROM did not load");
        bus_read(SLOTROM);
        if (cpu_din !== rom_at(0)) fail("$C600 does not read the ROM");
        bus_read(SLOTROM + 16'h37);
        if (cpu_din !== rom_at(16'h37)) fail("$C637 does not read the ROM");
        else $display("  ok: FD_ROM loaded, $C6xx reads it");

        bus_write(16'hC007, 8'h00);         // INTCXROM on
        bus_read(SLOTROM);
        if (cpu_din !== 8'hEE) fail("the ROM answered with INTCXROM set");
        bus_write(16'hC006, 8'h00);
        bus_read(SLOTROM);
        if (cpu_din !== rom_at(0)) fail("the ROM did not come back");
        else $display("  ok: the ROM follows INTCXROM");

        bus_read(PH0ON);                    // odd: the float (and phase 0 on)
        if (cpu_din !== 8'hEE) fail("an odd $C0Ex address was claimed");
        bus_read(PH0OFF);                   // ...off again, before the head is used
        bus_read(Q6L);                      // even: the register
        if (cpu_din === 8'hEE) fail("an even $C0Ex address was not claimed");
        else $display("  ok: odd addresses float, even ones read the register");

        // --- case 2 / a disk in drive 1 is one FD_SEEK -------------------------
        cell0 = 8'd32;
        trk0  = 6'd35;
        ins0  = 1'b1;
        wait_msg(T_FD_SEEK, 0, at, 50);
        if (at < 0) fail("no FD_SEEK for the inserted disk");
        else begin
            if (out_mem[msg_at[at]] !== hdr(T_FD_SEEK, 8'd1, 16'd0)) fail("FD_SEEK header");
            if (out_mem[msg_at[at]+1] !== seekw(8'd1, 0, 0, 0))
                fail("FD_SEEK should say drive 0, qtr 0, phase 0, seq 1");
            else $display("  ok: inserting a disk sends FD_SEEK {drive 0, qtr 0, seq 1}");
        end
        if (stale[0] !== 1'b1) fail("not stale before_cyc the fill");
        if (seeks !== 8'd1) fail("seeks != 1");

        // The program starts the drive and reads before_cyc the host has answered.
        bus_read(MOTORON); bus_read(DRIVE1); bus_read(Q7L); bus_read(Q6L);
        idle(STABLE_TICKS + 40);
        bus_read(Q6L);
        if (dut.usable !== 1'b0) fail("usable while stale");

        // A chunk with a stale seq changes nothing.
        push_word(hdr(T_FD_TRACK, 8'd253, 16'd0));
        push_word({8'd7, 8'd0, 8'd0, 8'd0});   // seq 7: nobody asked for it
        for (i = 0; i < 252; i = i + 1) push_word(32'hDEADBEEF);
        idle(6);
        if (dut.chunks_r !== 7'd0) fail("a chunk with the wrong seq was accepted");
        else $display("  ok: a chunk answering a seek nobody made is dropped");

        // Now the real answer, late.
        before_cyc = bus_cycles;
        send_track(0, 0, 8'd1);
        idle(40);
        if (stale[0] !== 1'b0) fail("the seventh chunk did not clear stale");
        else $display("  ok: seven FD_TRACK chunks fill the buffer and clear stale");
        if (late !== 8'd1) fail("the read before_cyc the fill was not counted late");
        else $display("  ok: the read taken before the fill counted as late (late=1)");
        if (fill_max == 16'd0) fail("fill_max did not record the fill");
        else $display("  ok: fill_max = %0d cycles", fill_max);
        late_clr = 1'b1; @(posedge clk); @(posedge clk); late_clr = 1'b0;
        idle(1);
        if (late !== 8'd0) fail("late did not clear");

        // --- case 3 / the RWTS's loop reads every nibble once, in order ---------
        idle(40);
        poll_nibbles(96);
        start = run_start(0, 48, NIB_DSK);
        if (start < 0) begin
            fail("the poll loop did not read consecutive nibbles of track 0");
            $display("        got %02x %02x %02x %02x ...", seq_mem[0], seq_mem[1], seq_mem[2], seq_mem[3]);
        end else $display("  ok: 48 consecutive nibbles from slot %0d (aligned by read %0d), none skipped or repeated", start, run_at);
        // 47 gaps of 32 cycles - 40 for a 10-bit sync slot - seen on a
        // 7-cycle grid.
        cyc0 = seq_cyc[run_at + 47] - seq_cyc[run_at];
        cyc1 = 0;
        for (i = 0; i < 47; i = i + 1) cyc1 = cyc1 + (is_gap((start + i) % NIB_DSK) ? 40 : 32);
        if (cyc0 < cyc1 - 7 || cyc0 > cyc1 + 7) begin
            $display("FAIL: 47 nibbles took %0d cycles, expected ~%0d", cyc0, cyc1);
            errors = errors + 1;
        end else $display("  ok: 47 nibbles in %0d cycles - 32 per nibble, 40 per 10-bit sync", cyc0);

        // --- case 4 / read every cycle: held eight, shifting twenty-four --------
        // Find a window: the first cycle a new valid nibble appears.
        // Wait for a partial first, so the count starts at a nibble's
        // first cycle and never on one already showing.
        v = 8'h00; held = 0; low = 0; seen = -1;
        for (i = 0; i < 300 && seen < 2; i = i + 1) begin
            bus_read(Q6L);
            if (seen == -1) begin
                if (!cpu_din[7]) seen = 0;
            end else if (seen == 0) begin
                if (cpu_din[7] && cpu_din != v) begin seen = 1; v = cpu_din; held = 1; end
                else if (cpu_din[7]) v = cpu_din;
            end else if (seen == 1) begin
                if (cpu_din == v) held = held + 1;
                else if (!cpu_din[7]) low = low + 1;
                else seen = 2;          // the next nibble: window done
            end
        end
        if (held != 8) begin
            $display("FAIL: a nibble read every cycle was held for %0d cycles, expected 8", held);
            errors = errors + 1;
        end else $display("  ok: a nibble is held for 8 cycles when read every cycle");
        if (low != 24) begin
            $display("FAIL: the next nibble shifted in over %0d cycles, expected 24", low);
            errors = errors + 1;
        end else $display("  ok: then the next one shifts in, high bit clear, for 24");

        // --- case 5 / the head ---------------------------------------------------
        // Phase 1 on: the cog at 0 sees magnet 1 up, and moves ten cycles later.
        m = nmsg;
        bus_read(PH1ON);
        idle(6);
        if (phase[6:0] !== 7'd0) fail("the head moved before_cyc ten cycles");
        idle(8);
        if (phase[6:0] !== 7'd1) fail("phase 1 on did not step to phase 1");
        else $display("  ok: a magnet moves the head ten cycles later");
        // A half-track position is a quarter-track position of its own
        // (qtr 2): the host decides what lies there.
        wait_msg(T_FD_SEEK, m, at, 50);
        if (at < 0) fail("no FD_SEEK for the half-track position");
        else if (out_mem[msg_at[at]+1] !== seekw(8'd2, 2, 1, 0))
            fail("FD_SEEK should say drive 0, qtr 2, phase 1, seq 2");
        else $display("  ok: the half-track position is FD_SEEK {qtr 2, phase 1, seq 2}");
        // Phase 2 on, phase 1 off: track 1 (qtr 4).
        m = nmsg;
        bus_read(PH2ON);
        bus_read(PH1OFF);
        idle(14);
        if (phase[6:0] !== 7'd2) fail("did not reach phase 2");
        wait_msg(T_FD_SEEK, m, at, 50);
        if (at < 0) fail("no FD_SEEK for track 1");
        else if (out_mem[msg_at[at]+1] !== seekw(8'd3, 4, 2, 0))
            fail("FD_SEEK should say drive 0, qtr 4, phase 2, seq 3");
        else $display("  ok: crossing into track 1 is FD_SEEK {qtr 4, phase 2, seq 3}");
        if (stale[0] !== 1'b1) fail("not stale after the step");
        if (dut.usable !== 1'b0) fail("usable while stale after the step");
        else $display("  ok: the register serves no old track while stale");
        // Both adjacent magnets on: no move.  Cog at 2: magnets 3 and 1.
        bus_read(PH3ON); bus_read(PH1ON);
        idle(14);
        if (phase[6:0] !== 7'd2) fail("the head moved with both adjacent magnets on");
        else $display("  ok: both adjacent magnets on - the head stays");
        bus_read(PH1OFF); bus_read(PH3OFF); bus_read(PH2OFF);
        idle(14);
        send_track(0, 1, 8'd3);
        idle(40);
        if (stale[0] !== 1'b0) fail("track 1 did not fill");
        poll_nibbles(96);
        if (run_start(1, 16, NIB_DSK) < 0) fail("track 1's nibbles did not read back");
        else $display("  ok: track 1 reads back after its fill");

        // --- case 6 / the second drive, through the one shared buffer -------------
        m = nmsg;
        bus_read(DRIVE2);
        idle(4);
        if (dut.usable !== 1'b0) fail("drive 2, empty, is usable");
        idle(20);
        if (nmsg != m) fail("an empty drive 2 asked the host for a track");
        else $display("  ok: selecting an empty drive 2 takes the buffer but asks for nothing");
        cell1 = 8'd32;
        trk1  = 6'd35;
        ins1  = 1'b1;
        wait_msg(T_FD_SEEK, m, at, 50);
        if (at < 0) fail("no FD_SEEK for drive 2");
        else if (out_mem[msg_at[at]+1] !== seekw(8'd4, 0, 0, 1))
            fail("FD_SEEK should say drive 1, qtr 0, seq 4");
        else $display("  ok: a disk in drive 2 is FD_SEEK {drive 1, qtr 0, seq 4}");
        send_track(1, 0, 8'd4);
        idle(STABLE_TICKS + 60);
        poll_nibbles(96);
        if (run_start(0, 16, NIB_DSK) < 0) fail("drive 2's track 0 did not read back");
        else $display("  ok: drive 2 reads its own track 0");
        // Switching back: the buffer is one, so drive 1's track is fetched
        // again - flush first if it were dirty (it is not), then the seek.
        m = nmsg;
        bus_read(DRIVE1);
        wait_msg(T_FD_SEEK, m, at2, 400);
        if (at2 < 0) fail("no FD_SEEK when the select came back to drive 1");
        else if (out_mem[msg_at[at2]+1] !== seekw(8'd5, 4, 2, 0))
            fail("FD_SEEK should say drive 0, qtr 4, seq 5");
        else $display("  ok: back to drive 1 - the shared buffer asks for its track 1 again");
        if (dut.usable !== 1'b0) fail("usable while the refetch is owed");
        send_track(0, 1, 8'd5);
        idle(STABLE_TICKS + 60);
        poll_nibbles(96);
        if (run_start(1, 16, NIB_DSK) < 0) fail("drive 1's track 1 did not come back");
        else $display("  ok: ...and its track 1 reads back after the refetch");

        // --- case 7 / motor off: coast, then hold ---------------------------------
        bus_read(MOTOROFF);
        idle(SPIN_TICKS / 2);
        poll_nibbles(24);
        if (run_start(1, 8, NIB_DSK) < 0) fail("the disk stopped reading while coasting");
        else $display("  ok: coasting after motor off, the disk still reads");
        idle(SPIN_TICKS);
        bus_read(Q6L); v = cpu_din;
        idle(70);
        bus_read(Q6L);
        if (cpu_din !== v) fail("the register changed with the drive stopped");
        else $display("  ok: stopped, the register holds ($%02x)", v);
        bus_read(MOTORON);
        idle(STABLE_TICKS + 40);

        // --- case 8 / write-protect sense ----------------------------------------
        wp0 = 1'b1;
        bus_read(Q6H); bus_read(Q7L);
        if (cpu_din !== 8'hFF) fail("$C0ED/$C0EE did not read write-protected");
        wp0 = 1'b0;
        bus_read(Q6H); bus_read(Q7L);
        if (cpu_din !== 8'h00) fail("$C0ED/$C0EE did not read writable");
        else $display("  ok: $C0ED then $C0EE senses write-protect");
        bus_read(Q6L);

        // --- case 9 / a sector written at the machine's pace ---------------------
        // DOS's way in: LDA $C08D,X / LDA $C08E,X / LDA #$FF / STA $C08F,X /
        // ORA $C08C,X - then five self-sync $FF at 40 cycles, then data at 32.
        // Every byte goes out a bit a cell: a 40-cycle $FF is eight ones and
        // two zeros, a 32-cycle byte its eight bits, back to back.
        idle(40);
        first_w = -1;
        bus_read(Q6H); bus_read(Q7L);
        bus_write(Q7H, 8'hFF);              // write mode, and the LD of $FF
        bus_read(Q6L);                      // the shift state: bits go out
        idle(38);
        for (i = 0; i < 4; i = i + 1) write_nibble(8'hFF, 40);
        for (i = 0; i < 15; i = i + 1) write_nibble(8'hD5 + i[7:0], 32);
        bus_read(Q7L);                      // read mode
        t0 = first_w;
        t1 = dut.bpos[0];
        if (dirty[0] !== 1'b1) fail("the write did not mark the buffer dirty");
        else $display("  ok: the write marked the buffer dirty (bits %0d..%0d)", t0, t1);
        // Leave the track: two half steps to track 2.  The upload goes out
        // at the first step, before its seek.
        m = nmsg;
        bus_read(PH3ON); bus_read(PH2OFF);
        idle(14);
        wait_msg(T_FD_SEEK, m, first_seek, 400);
        if (first_seek < 0) fail("no FD_SEEK for the half step toward track 2");
        else if (out_mem[msg_at[first_seek]+1] !== seekw(8'd6, 6, 3, 0))
            fail("FD_SEEK should say drive 0, qtr 6, phase 3, seq 6");
        gather_upload(m, n_up, first_up);
        if (n_up != 7) begin
            $display("FAIL: %0d FD_DIRTY chunks, expected 7", n_up); errors = errors + 1;
        end else if (first_up > first_seek) fail("the upload came after the seek");
        else $display("  ok: seven FD_DIRTY chunks went out, before the FD_SEEK");
        if (out_mem[msg_at[first_up]+1] !== dirtyw(8'd5, 0, 4, 0))
            fail("FD_DIRTY should say drive 0, qtr 4, seq 5");
        if (up_bits != sent_bits) begin
            $display("FAIL: the upload says %0d bits, expected %0d", up_bits, sent_bits); errors = errors + 1;
        end else $display("  ok: the upload carries the track's bit count");
        // The written run, from the bit the first $FF landed on: five times
        // eight ones and two zeros, then the fifteen data bytes' bits.
        k = 0;
        for (i = 0; i < 5; i = i + 1) begin
            for (m = 0; m < 8; m = m + 1) if (up_bit(t0 + 10 * i + m) !== 1'b1) k = k + 1;
            for (m = 8; m < 10; m = m + 1) if (up_bit(t0 + 10 * i + m) !== 1'b0) k = k + 1;
        end
        if (k != 0) begin
            $display("FAIL: %0d of the fifty sync bits are wrong (five 10-bit $FF)", k); errors = errors + 1;
        end else $display("  ok: five 40-cycle sync bytes wrote eight ones and two zeros each");
        k = 0;
        for (i = 0; i < 15; i = i + 1) begin
            v = 8'hD5 + i[7:0];
            for (m = 0; m < 8; m = m + 1) if (up_bit(t0 + 50 + 8 * i + m) !== v[7 - m]) k = k + 1;
        end
        if (k != 0) begin
            $display("FAIL: %0d bits of the 15 data bytes are wrong or misplaced", k);
            errors = errors + 1;
        end else $display("  ok: the fifteen data bytes follow, bit for bit, contiguous");
        // The rest of the track is the host's, untouched: every byte no bit
        // of the write touched.
        k = 0;
        for (i = 0; i < 6656; i = i + 1)
            if ((8 * i + 8 <= t0) || (8 * i >= t0 + 170))
                if (up_img[i] !== host_img[i]) k = k + 1;
        if (k != 0) begin
            $display("FAIL: %0d bytes outside the write differ from the fill", k); errors = errors + 1;
        end else $display("  ok: everything outside the write is the track as filled");
        if (dirty[0] !== 1'b0) fail("dirty did not clear after the upload");
        // The second half step: track 2 (qtr 8), and its fill.
        m = nmsg;
        bus_read(PH0ON); bus_read(PH3OFF);
        idle(14);
        bus_read(PH0OFF);
        wait_msg(T_FD_SEEK, m, at, 400);
        if (at < 0) fail("no FD_SEEK for track 2");
        else if (out_mem[msg_at[at]+1] !== seekw(8'd7, 8, 4, 0))
            fail("FD_SEEK should say drive 0, qtr 8, phase 4, seq 7");
        send_track(0, 2, 8'd7);
        idle(40);

        // --- case 9b / a dirty track survives a drive switch -----------------------
        // One byte written on track 2, then the select moves to drive 2: the
        // flush must carry the byte out before drive 2's seek, exactly as a
        // head movement would have.
        idle(40);
        first_w = -1;
        bus_read(Q6H); bus_read(Q7L);
        bus_write(Q7H, 8'hDE);              // write mode, and the LD
        bus_read(Q6L);                      // the shift state
        idle(30);                           // eight cells: the byte is out
        bus_read(Q7L);                      // read mode
        t0 = first_w;
        if (dirty[0] !== 1'b1) fail("the one-byte write did not mark dirty");
        m = nmsg;
        bus_read(DRIVE2);
        wait_msg(T_FD_SEEK, m, at, 400);
        if (at < 0) fail("no FD_SEEK for drive 2 after the switch");
        else if (out_mem[msg_at[at]+1] !== seekw(8'd8, 0, 0, 1))
            fail("FD_SEEK should say drive 1, qtr 0, seq 8");
        gather_upload(m, n_up, first_up);
        if (n_up != 7) begin
            $display("FAIL: %0d FD_DIRTY chunks on the switch, expected 7", n_up); errors = errors + 1;
        end else if (first_up > at) fail("the switch's upload came after the seek");
        else if (out_mem[msg_at[first_up]+1] !== dirtyw(8'd7, 0, 8, 0))
            fail("the switch's FD_DIRTY should say drive 0, qtr 8, seq 7");
        else $display("  ok: switching drives flushed the dirty track first, seven chunks before the seek");
        k = 0;
        v = 8'hDE;
        for (m = 0; m < 8; m = m + 1) if (up_bit(t0 + m) !== v[7 - m]) k = k + 1;
        if (k != 0) begin
            $display("FAIL: %0d bits of the one written byte are wrong", k); errors = errors + 1;
        end
        k = 0;
        for (i = 0; i < 6656; i = i + 1)
            if ((8 * i + 8 <= t0) || (8 * i >= t0 + 9))
                if (up_img[i] !== host_img[i]) k = k + 1;
        if (k != 0) begin
            $display("FAIL: %0d bytes of the switched-away track differ", k); errors = errors + 1;
        end else $display("  ok: the flushed track carries the write, everything else as filled");
        send_track(1, 0, 8'd8);
        idle(40);
        m = nmsg;
        bus_read(DRIVE1);
        wait_msg(T_FD_SEEK, m, at2, 400);
        if (at2 < 0) fail("no FD_SEEK back to drive 1");
        else if (out_mem[msg_at[at2]+1] !== seekw(8'd9, 8, 4, 0))
            fail("FD_SEEK back should say drive 0, qtr 8, seq 9");
        else $display("  ok: back on drive 1, track 2 is asked for again");
        send_track(0, 2, 8'd9);
        idle(STABLE_TICKS + 60);

        // --- case 10 / RES' clears the switches, nothing else ---------------------
        res_n = 1'b0;
        repeat (300) @(posedge clk);
        res_n = 1'b1;
        repeat (2) @(posedge cyc_en);
        if (motor !== 1'b0 || drive_sel !== 1'b0 || q6 !== 1'b0 || q7 !== 1'b0)
            fail("RES' did not clear the switches");
        else $display("  ok: RES' clears motor, drive, Q6, Q7");
        if (phase[6:0] !== 7'd4) fail("RES' moved the head");
        if (stale[0] !== 1'b0) fail("RES' lost the track");
        else $display("  ok: and leaves the head and the buffer alone");

        // --- case 10b / a write burst on every cell phase ------------------------
        // A cell is four cycles and a load is one; whichever of the four
        // phases the burst starts on, a cell boundary that lands inside a
        // load must still write the loaded byte's bit, so eight bytes at
        // 32 cycles come out as 64 contiguous bits, on all four phases.
        bus_read(MOTORON);
        idle(STABLE_TICKS + 40);
        for (m = 0; m < 4; m = m + 1) begin
            idle(9 + m);
            first_w = -1;
            bus_read(Q6H); bus_read(Q7L);
            bus_write(Q7H, 8'hD5);
            bus_read(Q6L);
            idle(30);
            for (i = 1; i < 8; i = i + 1) write_nibble(8'hD5 + i[7:0], 32);
            bus_read(Q7L);
            t0 = first_w;
            k = 0;
            for (i = 0; i < 8; i = i + 1) begin
                v = 8'hD5 + i[7:0];
                for (at2 = 0; at2 < 8; at2 = at2 + 1)
                    if (dut.win_v[0] === 1'b0 && dut.win_v[1] === 1'b0) k = k + 1000;
                    else if (up_bit_live(t0 + 8 * i + at2) !== v[7 - at2]) k = k + 1;
            end
            if (k != 0) begin
                $display("FAIL: phase %0d: %0d of the burst's 64 bits are wrong (a cell in a load window lost)", m, k);
                errors = errors + 1;
            end else $display("  ok: phase %0d - eight bytes at 32 cycles are 64 contiguous bits on the track", m);
        end

        // --- case 10c / a protected disk's track is never touched ---------------
        // The tab set: a whole write burst lands nothing, and the card's copy
        // of the track is byte for byte what it was.  Then the tab set in the
        // middle of a writable burst: nothing lands from that clock on, the
        // bit already in flight included.
        wp0 = 1'b1;
        idle(4);
        for (i = 0; i < 6656; i = i + 1) snap[i] = buf_byte(i);
        at = wgos;
        bus_read(Q6H); bus_read(Q7L);
        bus_write(Q7H, 8'hA5);
        bus_read(Q6L);
        idle(30);
        for (i = 0; i < 8; i = i + 1) write_nibble(8'h5A + i[7:0], 32);
        bus_read(Q7L);
        idle(8);
        k = 0;
        for (i = 0; i < 6656; i = i + 1) if (buf_byte(i) !== snap[i]) k = k + 1;
        if (wgos != at || k != 0) begin
            $display("FAIL: a protected disk took %0d bits, %0d bytes of the card's track changed", wgos - at, k);
            errors = errors + 1;
        end else $display("  ok: write-protected - a whole burst lands nothing, the card's track untouched");
        wp0 = 1'b0;
        idle(4);
        at = wgos;
        bus_read(Q6H); bus_read(Q7L);
        bus_write(Q7H, 8'hC3);
        bus_read(Q6L);
        idle(20);
        if (wgos == at) fail("the writable burst before the tab wrote nothing");
        wp0 = 1'b1;
        at2 = wgos;
        idle(40);
        bus_read(Q7L);
        idle(8);
        if (wgos != at2) begin
            $display("FAIL: %0d bits landed after the tab was set mid-burst", wgos - at2); errors = errors + 1;
        end else $display("  ok: the tab set mid-burst - nothing lands from that clock on");
        wp0 = 1'b0;
        idle(4);

        // --- case 11 / a quarter track: two adjacent magnets together ------------
        // RES' cleared the motor: back on, or the drive stops mid-case.
        bus_read(MOTORON);
        idle(4);
        // Cog at 4 (phase 4).  Magnets 0 and 1 on together pull a quarter
        // track up (qtr 9); releasing 1 leaves magnet 0 alone, the cog's own:
        // no pull, and the head is back on its phase (qtr 8).
        m = nmsg;
        bus_read(PH0ON); bus_read(PH1ON);
        idle(14);
        if (phase[6:0] !== 7'd4) fail("a magnet pair moved the phase");
        wait_msg(T_FD_SEEK, m, at, 50);
        if (at < 0) fail("no FD_SEEK for the quarter track");
        else if (out_mem[msg_at[at]+1] !== seekw(8'd10, 9, 4, 0))
            fail("FD_SEEK should say drive 0, qtr 9, phase 4, seq 10");
        else $display("  ok: two adjacent magnets on together - FD_SEEK {qtr 9, phase 4}: a quarter track");
        m = nmsg;
        bus_read(PH1OFF);
        idle(14);
        wait_msg(T_FD_SEEK, m, at, 50);
        if (at < 0) fail("no FD_SEEK back from the quarter track");
        else if (out_mem[msg_at[at]+1] !== seekw(8'd11, 8, 4, 0))
            fail("FD_SEEK should say drive 0, qtr 8, phase 4, seq 11");
        else $display("  ok: the pair released - back on qtr 8");
        bus_read(PH0OFF);
        idle(14);
        // The host's track for qtr 8 this time: a real sync gap - ten 10-bit
        // $FF - then D5 AA 96, then the nibble pattern.  The LSS must absorb
        // the two zero bits after each $FF (the hold extends while the
        // register is empty) and the poll loop must then read the field.
        for (i = 0; i < 6656 * 8; i = i + 1) set_bit(i, nib(3, (i / 8) % NIB_DSK) >> (7 - (i % 8)));
        for (at2 = 0; at2 < 8 * NIB_DSK; at2 = at2 + 1024 * 8) begin
            k = at2;
            for (i = 0; i < 10; i = i + 1) begin
                for (m = 0; m < 8; m = m + 1) set_bit(k + m, 1'b1);
                set_bit(k + 8, 1'b0); set_bit(k + 9, 1'b0);
                k = k + 10;
            end
            v = 8'hD5; for (m = 0; m < 8; m = m + 1) set_bit(k + m, v[7 - m]); k = k + 8;
            v = 8'hAA; for (m = 0; m < 8; m = m + 1) set_bit(k + m, v[7 - m]); k = k + 8;
            v = 8'h96; for (m = 0; m < 8; m = m + 1) set_bit(k + m, v[7 - m]); k = k + 8;
        end
        send_bits(0, 8, 8'd11, 8 * NIB_DSK);
        idle(40);
        if (stale[0] !== 1'b0) fail("the sync-gap track did not fill");
        // The pattern sits every 1024 nibbles: poll from wherever the head
        // is until D5 AA 96 shows, at most about two of those stretches.
        seen = 0; k = 0; v = 8'h00;
        while (seen < 3 && k < 10000) begin
            bus_read(Q6L);
            if (cpu_din[7] && cpu_din != v) begin
                v = cpu_din;
                if (seen == 0 && v == 8'hD5) seen = 1;
                else if (seen == 1 && v == 8'hAA) seen = 2;
                else if (seen == 2 && v == 8'h96) seen = 3;
                else if (seen == 1 || seen == 2) seen = 0;
            end
            idle(6);
            k = k + 1;
        end
        if (seen != 3) fail("D5 AA 96 never read back after the 10-bit sync gap");
        else $display("  ok: ten 10-bit sync $FF then D5 AA 96 - the LSS resynced through the gap");

        // --- the standing invariants ---------------------------------------------
        if (read_drive_unclaimed != 0) fail("the data bus was driven on a read the card had not claimed");
        else $display("  ok: no read was ever driven unclaimed");
        if (overrides != 0) fail("the floppy took a cycle from the machine");
        else $display("  ok: no override, ever");
        if (unknowns != 0) fail("the receiver reported an unknown type - a floppy type is missing from its list");
        else $display("  ok: FD_ROM and FD_TRACK are known types");

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("FAIL: timed out");
        $finish;
    end

endmodule
