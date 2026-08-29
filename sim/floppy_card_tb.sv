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
//   * the second drive is its own head and its own buffer; switching back
//     asks the host for nothing.
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
        .master_active (master_active),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (1'b0), .drv_sync (drv_sync),
        .cyc_en (cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (rd_claim), .slot_rd_data (rd_data),
        .din_sub_en (1'b0), .din_sub_data (8'h00),
        .ovr_en (1'b0), .ovr_addr (16'h0000), .ovr_rw (1'b1), .ovr_wdata (8'h00),
        .op_ovr (op_ovr),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- host -> card: a FIFO the real parser reads -------------------------
    reg  [31:0] rx_mem [0:32767];
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

    // ---- the floppy ---------------------------------------------------------
    reg  [1:0]  drv_inserted = 2'b00, drv_wp = 2'b00, drv_flush = 2'b00;
    reg  [25:0] drv_nibbles = 26'd0;
    reg  [11:0] drv_tracks  = 12'd0;
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
        .rd_claim (rd_claim), .rd_data (rd_data),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .tx_word (tx_word), .tx_valid (tx_valid), .tx_take (tx_take),
        .drv_inserted (drv_inserted), .drv_wp (drv_wp),
        .drv_nibbles (drv_nibbles), .drv_tracks (drv_tracks), .drv_flush (drv_flush),
        .late_clr (late_clr), .fill_clr (fill_clr),
        .rom_loaded (rom_loaded), .stale_o (stale), .dirty_o (dirty),
        .phase_o (phase), .motor_o (motor), .drive_sel_o (drive_sel),
        .q6_o (q6), .q7_o (q7), .seeks (seeks), .late (late), .fill_max (fill_max)
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

    // ---- the host's image ---------------------------------------------------
    // Nibble i of track t: high bit set, neighbours never equal.
    function [7:0] nib(input integer t, input integer i);
        nib = 8'h80 | ((t * 37 + i * 11 + 5) & 8'h7F);
    endfunction
    function [7:0] rom_at(input integer i);
        rom_at = (i == 0) ? 8'hA2 : (8'h20 + i[7:0]);
    endfunction

    // The host's answer: seven chunks of the track.
    task send_track(input integer drive, input integer track, input [7:0] seq);
        integer c, w, n, i;
        begin
            for (c = 0; c < 7; c = c + 1) begin
                n = (c == 6) ? (TRACK_WORDS - 6 * CHUNK_WORDS) : CHUNK_WORDS;
                push_word(hdr(T_FD_TRACK, n[7:0] + 8'd1, 16'd0));
                push_word({seq, c[7:0], track[7:0], drive[7:0]});
                for (w = 0; w < n; w = w + 1) begin
                    i = 4 * (c * CHUNK_WORDS + w);
                    push_word({nib(track, i+3), nib(track, i+2), nib(track, i+1), nib(track, i)});
                end
            end
        end
    endtask

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
                    n = out_mem[base][7:0] - 1;
                    for (w = 0; w < n; w = w + 1) begin
                        wd = out_mem[base + 2 + w];
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
    task poll_nibbles(input integer n);
        integer got, max;
        reg [7:0] last;
        begin
            got = 0; last = 8'h00; max = 0;
            while (got < n && max < n * 64) begin
                bus_read(Q6L);
                if (cpu_din[7] && cpu_din != last) begin
                    seq_mem[got] = cpu_din;
                    seq_cyc[got] = bus_cycles;
                    last = cpu_din;
                    got = got + 1;
                end
                idle(6);
                max = max + 1;
            end
            if (got < n) fail("the poll loop starved: not enough nibbles");
        end
    endtask

    // Is seq_mem[0..n) a run of consecutive nibbles of `track`?  Returns the
    // start slot, or -1.
    function integer run_start(input integer track, input integer n, input integer nibbles);
        integer p, i, ok;
        begin
            run_start = -1;
            for (p = 0; p < nibbles && run_start < 0; p = p + 1) begin
                if (seq_mem[0] == nib(track, p) && seq_mem[1] == nib(track, (p + 1) % nibbles)) begin
                    ok = 1;
                    for (i = 0; i < n; i = i + 1)
                        if (seq_mem[i] !== nib(track, (p + i) % nibbles)) ok = 0;
                    if (ok) run_start = p;
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
        $display("floppy_card_tb: a Disk II in slot 6, the host at the other end\n");
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
        drv_nibbles[12:0] = NIB_DSK[12:0];
        drv_tracks[5:0]   = 6'd35;
        drv_inserted[0]   = 1'b1;
        wait_msg(T_FD_SEEK, 0, at, 50);
        if (at < 0) fail("no FD_SEEK for the inserted disk");
        else begin
            if (out_mem[msg_at[at]] !== hdr(T_FD_SEEK, 8'd1, 16'd0)) fail("FD_SEEK header");
            if (out_mem[msg_at[at]+1] !== {8'd1, 8'd0, 8'd0, 8'd0})
                fail("FD_SEEK should say drive 0, track 0, seq 1");
            else $display("  ok: inserting a disk sends FD_SEEK {drive 0, track 0, seq 1}");
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
        if (dut.chunks[0] !== 7'd0) fail("a chunk with the wrong seq was accepted");
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
        poll_nibbles(64);
        start = run_start(0, 64, NIB_DSK);
        if (start < 0) begin
            fail("the poll loop did not read consecutive nibbles of track 0");
            $display("        got %02x %02x %02x %02x ...", seq_mem[0], seq_mem[1], seq_mem[2], seq_mem[3]);
        end else $display("  ok: 64 nibbles, consecutive from slot %0d, none skipped or repeated", start);
        // 63 gaps of 32 cycles, seen on a 7-cycle grid.
        cyc0 = seq_cyc[63] - seq_cyc[0];
        if (cyc0 < 63 * 32 - 7 || cyc0 > 63 * 32 + 7) begin
            $display("FAIL: 63 nibbles took %0d cycles, expected ~%0d", cyc0, 63 * 32);
            errors = errors + 1;
        end else $display("  ok: 63 nibbles in %0d cycles - 32 per nibble", cyc0);

        // --- case 4 / read every cycle: held eight, shifting twenty-four --------
        // Find a window: the first cycle a new valid nibble appears.
        v = 8'h00; held = 0; low = 0; seen = 0;
        for (i = 0; i < 200 && seen < 2; i = i + 1) begin
            bus_read(Q6L);
            if (seen == 0) begin
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
        bus_read(PH1ON);
        idle(6);
        if (phase[6:0] !== 7'd0) fail("the head moved before_cyc ten cycles");
        idle(8);
        if (phase[6:0] !== 7'd1) fail("phase 1 on did not step to phase 1");
        else $display("  ok: a magnet moves the head ten cycles later");
        if (seeks !== 8'd1) fail("a half-track step asked for a track");
        // Phase 2 on, phase 1 off: track 1.
        m = nmsg;
        bus_read(PH2ON);
        bus_read(PH1OFF);
        idle(14);
        if (phase[6:0] !== 7'd2) fail("did not reach phase 2");
        wait_msg(T_FD_SEEK, m, at, 50);
        if (at < 0) fail("no FD_SEEK for track 1");
        else if (out_mem[msg_at[at]+1] !== {8'd2, 8'd0, 8'd1, 8'd0})
            fail("FD_SEEK should say drive 0, track 1, seq 2");
        else $display("  ok: crossing into track 1 is one FD_SEEK {0, 1, seq 2}");
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
        send_track(0, 1, 8'd2);
        idle(40);
        if (stale[0] !== 1'b0) fail("track 1 did not fill");
        poll_nibbles(16);
        if (run_start(1, 16, NIB_DSK) < 0) fail("track 1's nibbles did not read back");
        else $display("  ok: track 1 reads back after its fill");

        // --- case 6 / the second drive -------------------------------------------
        m = nmsg;
        bus_read(DRIVE2);
        idle(4);
        if (dut.usable !== 1'b0) fail("drive 2, empty, is usable");
        idle(20);
        if (nmsg != m) fail("an empty drive 2 asked the host for a track");
        else $display("  ok: selecting an empty drive 2 asks for nothing");
        drv_nibbles[25:13] = NIB_DSK[12:0];
        drv_tracks[11:6]   = 6'd35;
        drv_inserted[1]    = 1'b1;
        wait_msg(T_FD_SEEK, m, at, 50);
        if (at < 0) fail("no FD_SEEK for drive 2");
        else if (out_mem[msg_at[at]+1] !== {8'd1, 8'd0, 8'd0, 8'd1})
            fail("FD_SEEK should say drive 1, track 0, seq 1");
        else $display("  ok: a disk in drive 2 is FD_SEEK {1, 0, seq 1}");
        send_track(1, 0, 8'd1);
        idle(STABLE_TICKS + 60);
        poll_nibbles(16);
        if (run_start(0, 16, NIB_DSK) < 0) fail("drive 2's track 0 did not read back");
        else $display("  ok: drive 2 reads its own track 0");
        m = nmsg;
        bus_read(DRIVE1);
        idle(STABLE_TICKS + 60);
        if (nmsg != m) fail("switching back to drive 1 asked the host again");
        poll_nibbles(16);
        if (run_start(1, 16, NIB_DSK) < 0) fail("drive 1's track 1 was lost");
        else $display("  ok: back to drive 1 - its track 1 is still there, no new seek");

        // --- case 7 / motor off: coast, then hold ---------------------------------
        bus_read(MOTOROFF);
        idle(SPIN_TICKS / 2);
        poll_nibbles(8);
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
        drv_wp[0] = 1'b1;
        bus_read(Q6H); bus_read(Q7L);
        if (cpu_din !== 8'hFF) fail("$C0ED/$C0EE did not read write-protected");
        drv_wp[0] = 1'b0;
        bus_read(Q6H); bus_read(Q7L);
        if (cpu_din !== 8'h00) fail("$C0ED/$C0EE did not read writable");
        else $display("  ok: $C0ED then $C0EE senses write-protect");
        bus_read(Q6L);

        // --- case 9 / a sector written at the machine's pace ---------------------
        // DOS's way in: LDA $C08D,X / LDA $C08E,X / LDA #$FF / STA $C08F,X /
        // ORA $C08C,X - then five self-sync $FF at 40 cycles, then data at 32.
        idle(40);
        bus_read(Q6H); bus_read(Q7L);
        bus_write(Q7H, 8'hFF);              // write mode, and the LD of $FF
        bus_read(Q6L);                      // the shift
        t0 = dut.wr_last;                   // the slot that first byte landed in
        idle(38);
        for (i = 0; i < 4; i = i + 1) write_nibble(8'hFF, 40);
        for (i = 0; i < 15; i = i + 1) write_nibble(8'hD5 + i[7:0], 32);
        bus_read(Q7L);                      // read mode
        t1 = dut.pos[0];
        if (dirty[0] !== 1'b1) fail("the write did not mark the buffer dirty");
        else $display("  ok: the write marked the buffer dirty (slots %0d..%0d)", t0, t1);
        // Leave the track: track 2.  Uploads first, then the seek.
        m = nmsg;
        bus_read(PH3ON); bus_read(PH2OFF);
        idle(14);
        bus_read(PH0ON); bus_read(PH3OFF);
        idle(14);
        bus_read(PH0OFF);
        wait_msg(T_FD_SEEK, m, first_seek, 400);
        if (first_seek < 0) fail("no FD_SEEK for track 2");
        else if (out_mem[msg_at[first_seek]+1] !== {8'd3, 8'd0, 8'd2, 8'd0})
            fail("FD_SEEK should say drive 0, track 2, seq 3");
        gather_upload(m, n_up, first_up);
        if (n_up != 7) begin
            $display("FAIL: %0d FD_DIRTY chunks, expected 7", n_up); errors = errors + 1;
        end else if (first_up > first_seek) fail("the upload came after the seek");
        else $display("  ok: seven FD_DIRTY chunks went out, before the FD_SEEK");
        if (out_mem[msg_at[first_up]+1] !== {8'd2, 8'd0, 8'd1, 8'd0})
            fail("FD_DIRTY should say drive 0, track 1, seq 2");
        // The written run: $FF from t0 - five 40-cycle sync bytes and the
        // slot they skip, six or seven slots by where in a slot the burst
        // began - then the fifteen data bytes, contiguous.
        first_up = -1;
        for (i = 0; i < 10; i = i + 1)
            if (first_up < 0 && up_img[(t0 + i) % NIB_DSK] == 8'hD5) first_up = i;
        if (first_up < 6 || first_up > 7) begin
            $display("FAIL: the data starts %0d slots after the burst, expected 6 or 7", first_up);
            errors = errors + 1;
        end
        k = 0;
        for (i = 0; i < first_up; i = i + 1) if (up_img[(t0 + i) % NIB_DSK] !== 8'hFF) k = k + 1;
        if (k != 0) begin
            $display("FAIL: %0d of the %0d sync slots are not $FF", k, first_up); errors = errors + 1;
        end else $display("  ok: five 40-cycle sync bytes fill %0d slots with $FF, the skipped one included", first_up);
        k = 0;
        for (i = 0; i < 15; i = i + 1)
            if (up_img[(t0 + first_up + i) % NIB_DSK] !== 8'hD5 + i[7:0]) k = k + 1;
        if (k != 0) begin
            $display("FAIL: %0d of the 15 data bytes are wrong or misplaced", k);
            errors = errors + 1;
        end else $display("  ok: the fifteen data bytes follow, contiguous");
        // The rest of the track is the host's, untouched.
        k = 0;
        for (i = 0; i < NIB_DSK; i = i + 1)
            if (i < t0 || i >= t0 + first_up + 15)
                if (up_img[i] !== nib(1, i)) k = k + 1;
        if (k != 0) begin
            $display("FAIL: %0d bytes outside the write differ from the fill", k); errors = errors + 1;
        end else $display("  ok: everything outside the write is the track as filled");
        if (dirty[0] !== 1'b0) fail("dirty did not clear after the upload");
        send_track(0, 2, 8'd3);
        idle(40);

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

        // --- the standing invariants ---------------------------------------------
        if (read_drive_unclaimed != 0) fail("the data bus was driven on a read the card had not claimed");
        else $display("  ok: no read was ever driven unclaimed");
        if (overrides != 0) fail("the floppy took a cycle from the machine");
        else $display("  ok: no override, ever");
        if (frame_error !== 1'b0) fail("the receiver lost framing - a type is missing from hdr_known");
        else $display("  ok: FD_ROM and FD_TRACK are known types");

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL: timed out");
        $finish;
    end

endmodule
