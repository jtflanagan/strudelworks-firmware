`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_iwm_write_tb - the IIgs IWM's 5.25" drives as BIT STREAMS, read and
// written, with the tb playing both the program and the host.
//
// One op per clock, each a tick of the core's time - which is the drive's
// only clock - so every access lands on an exact cycle, as a DOS loop counts
// them.  The tb answers FD_SEEK {seq, 0, qtr, phase, drive} with the host's
// seven FD_TRACK chunks {seq, chunk, qtr, drive}, {bits}, words, and
// reassembles FD_DIRTY uploads as the host's floppy service does
// (src/fd_service.cpp on_dirty).  Its tracks are the host's shape: 6&2
// nibbles, with self-sync gaps whose $FF is ten bits.
//
// THE PROPERTIES (docs/IWM35.md, docs/FLOPPY.md):
//
//   * a disk in, the motor on: one FD_SEEK {seq 1, qtr 0, phase 0}.
//   * two adjacent magnets on together hold a quarter track: FD_SEEK qtr 1;
//     the pair released, back to qtr 0.
//   * $C0ED then $C0EE senses write protect in bit 7: writable, protected, an
//     empty drive protected, and 1 under ENABLE2 (the SmartPort ACK).
//   * the RWTS's poll loop reads consecutive nibbles through the sync gaps.
//   * a sector written at the machine's own pace - five 40-cycle syncs, data
//     at 32 - is its bits on the track, contiguous from the first, and reads
//     back through the register on the next revolution.
//   * leaving a written track sends it home first: seven FD_DIRTY chunks with
//     the fill's seq and the track's bit count, before the next FD_SEEK;
//     everything outside the write is the track as the host sent it.
//   * a write-protected disk takes no bit - the card's copy byte for byte what
//     it was - and sends nothing home; the tab set mid-burst stops landings.
//   * the motor stopping and the host's flush each send the track home with
//     no refetch; a flush while an upload is going out sends it again with
//     the later write; an ejected disk sends its written track home.
//   * a burst lands 64 contiguous bits on every one of the four cell phases.
//
// THE WAITS COUNT MESSAGES AS THEY ARRIVE (ndirty, nseek, kept by the capture
// block) and never call a function in a loop condition: under the timing
// scheduler a loop `while (count_msg(...) < n)` inside a waiting task left
// early (static tasks) or never ran (automatic ones).  A watchdog ends a run
// that stalls.
//////////////////////////////////////////////////////////////////////////////////
module gs_iwm_write_tb;
    localparam integer NIB   = 6384;
    localparam integer CHUNK = 252;
    localparam [7:0] T_FD_TRACK = 8'h1F, T_FD_SEEK = 8'h20, T_FD_DIRTY = 8'h21;
    localparam [7:0] T_FD35_TRACK = 8'h31, T_FD35_SEEK = 8'h32, T_FD35_DIRTY = 8'h37;
    // A zone-0 3.5" track: twelve sectors a side (fd35_nibble.hpp).
    localparam integer NIB35    = 9694;
    localparam integer WORDS35  = (NIB35 + 3) / 4;          // 2424
    localparam integer CHUNKS35 = (WORDS35 + CHUNK - 1) / CHUNK;   // 10
    localparam [7:0] PH0OFF = 8'hE0, PH0ON = 8'hE1, PH1OFF = 8'hE2, PH1ON = 8'hE3,
                     PH2OFF = 8'hE4, PH2ON = 8'hE5, PH3OFF = 8'hE6, PH3ON = 8'hE7,
                     MOTOROFF = 8'hE8, MOTORON = 8'hE9, DRV1 = 8'hEA, DRV2 = 8'hEB,
                     Q6L = 8'hEC, Q6H = 8'hED, Q7L = 8'hEE, Q7H = 8'hEF;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    reg  [7:0]  op_lo = 8'd0;
    reg         op_rw = 1'b1;
    reg  [7:0]  op_wdata = 8'd0;
    reg         act = 1'b0;
    reg         tick = 1'b0;
    wire [7:0]  rd_byte;
    reg         msg_valid = 1'b0;
    reg  [7:0]  msg_type = 8'd0, msg_len = 8'd0;
    reg  [31:0] pay_data = 32'd0;
    reg         pay_valid = 1'b0;
    wire [31:0] tx_word;
    wire        tx_valid;
    reg         tx_take = 1'b1;
    // Whole variables per drive, concatenated into the ports: a part-select
    // written from the initial block does not reach a port reliably.
    reg         ins0 = 1'b0, ins1 = 1'b0, wp0 = 1'b0, wp1 = 1'b0, fl0 = 1'b0, fl1 = 1'b0;
    // The 3.5" drive: its own select, disk and tab, so its writes can be
    // walked here beside the 5.25" drives' (docs/IWM35.md, "The 3.5" drive
    // writes").
    reg         sel35 = 1'b0, ins35 = 1'b0, wp35 = 1'b1;
    wire [1:0]  d5_inserted = {ins1, ins0}, d5_wp = {wp1, wp0}, d5_flush = {fl1, fl0};
    wire [1:0]  d5_stale, d5_dirty;
    wire [13:0] d5_phase;
    wire        stall;

    gs_iwm #(.MOTOR_OFF_TICKS (300)) dut (
        .clk (clk), .rst (rst), .res_sync (1'b1),
        .op_lo (op_lo), .op_rw (op_rw), .op_wdata (op_wdata), .act (act),
        .rd_byte (rd_byte),
        .apple35_sel (sel35), .c031_ctrl (1'b0),
        .tick (tick),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .tx_word (tx_word), .tx_valid (tx_valid), .tx_take (tx_take),
        .drv_inserted (ins35), .drv_wp (wp35),
        .late_clr (1'b0), .fill_clr (1'b0),
        .d5_inserted (d5_inserted), .d5_wp (d5_wp),
        .d5_cell ({13'd32, 13'd32}), .d5_tracks ({6'd35, 6'd35}),
        .d5_flush (d5_flush),
        .stale_o (), .track_o (), .side_o (), .motor35_o (), .motor_o (), .ctl_o (),
        .seeks (), .late (), .fill_max (),
        .d5_stale_o (d5_stale), .d5_dirty_o (d5_dirty), .d5_phase_o (d5_phase),
        .stall_o (stall),
        .cnt_mode_wr ()
    );

    integer errors = 0;
    task fail(input [8*96-1:0] why);
        begin
            $display("FAIL: %0s", why);
            errors = errors + 1;
        end
    endtask

    initial begin
        #400_000_000;
        $display("FAIL: the bench never finished (watchdog)");
        $display("FAILED: timeout");
        $finish;
    end

    // ---- the program: one op a clock, a tick each ---------------------------------
    reg [7:0] din;
    task op(input [7:0] lo, input rw, input [7:0] wd);
        begin
            op_lo = lo; op_rw = rw; op_wdata = wd; act = 1'b1; tick = 1'b1;
            #2 din = rd_byte;
            @(posedge clk); #1;
            act = 1'b0; tick = 1'b0;
        end
    endtask
    task idle(input integer n_idle);
        integer ii;
        begin
            for (ii = 0; ii < n_idle; ii = ii + 1) begin
                tick = 1'b1;
                @(posedge clk); #1;
                tick = 1'b0;
            end
        end
    endtask
    // Clocks with no op and no tick: the link's time, not the machine's.
    task wait_clk(input integer n_wait);
        integer wi;
        begin
            for (wi = 0; wi < n_wait; wi = wi + 1) begin @(posedge clk); #1; end
        end
    endtask

    // Every BYTE that lands in the 3.5" buffer, and where the first one went.
    integer w35s = 0, first_w35 = -1;
    integer w35_at [0:63];
    reg [7:0] w35_of [0:63];
    always @(posedge clk) if (!rst && dut.w35_go) begin
        if (w35s < 64) begin w35_at[w35s] = dut.w35_pos; w35_of[w35s] = dut.w35_byte; end
        w35s = w35s + 1;
        if (first_w35 < 0) first_w35 = dut.w35_pos;
    end
    // One 3.5" write: the load, then ONE SLOT's worth of ticks.  A 3.5"
    // nibble is P35/5 = 44.8 ticks, so 45 turns the platter exactly one slot
    // per write; write slower and a slot goes by untouched, which is what a
    // real drive does too (the IWM does not buffer) - the bench's first cut
    // used 62 and dropped every third slot.
    task write35(input [7:0] b);
        begin
            op(Q6H, 1'b0, b);           // STA $C0ED with Q7 already high
            op(Q6L, 1'b1, 8'd0);
            idle(43);                   // + the two ops above = 45 ticks
        end
    endtask

    // Every bit that lands in the buffer, and the first position of a burst.
    integer wgos = 0, first_w = -1;
    always @(posedge clk) if (!rst && dut.w_go) begin
        wgos = wgos + 1;
        if (first_w < 0) first_w = dut.wpend_pos;
    end

    // One step of a write burst: load the byte, shift, the rest of the spacing.
    task write_nibble(input [7:0] b, input integer spacing);
        begin
            op(Q6H, 1'b0, b);           // STA $C0ED: the load
            op(Q6L, 1'b1, 8'd0);        // ORA $C0EC
            idle(spacing - 2);
        end
    endtask
    // One byte: into write mode, the load, eight cells, back to read mode.
    // Returns the bit its first cell landed on (or -1).
    task write_one(input [7:0] b, output integer at_bit);
        begin
            op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
            first_w = -1;
            op(Q7H, 1'b0, b);
            op(Q6L, 1'b1, 8'd0);
            idle(30);
            op(Q7L, 1'b1, 8'd0);
            at_bit = first_w;
        end
    endtask
    task flush1;
        begin
            @(negedge clk); fl0 = 1'b1;
            @(negedge clk); fl0 = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // ---- the host's tracks ----------------------------------------------------------
    // Nibble j of track t: one of the 64 legal 6&2 nibbles (no four zeros in a
    // row - the MC3470's noise rule), neighbours never equal; every 32nd group
    // of four slots is a self-sync gap, $FF written as ten bits.
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
    function is_gap(input integer j);
        is_gap = ((j % 32) < 4);
    endfunction
    function [7:0] expected(input integer t, input integer j);
        expected = is_gap(j) ? 8'hFF : n62(t * 37 + j * 11 + 5);
    endfunction

    reg [7:0] host_img [0:6655];
    task set_bit(input integer i, input v);
        begin
            if (v) host_img[i / 8] = host_img[i / 8] |  (8'h80 >> (i % 8));
            else   host_img[i / 8] = host_img[i / 8] & ~(8'h80 >> (i % 8));
        end
    endtask
    integer sent_bits = 0;
    task build_track(input integer t);
        integer bi, bj, bk;
        reg [7:0] bv;
        begin
            for (bi = 0; bi < 6656; bi = bi + 1) host_img[bi] = 8'h00;
            bk = 0;
            for (bj = 0; bj < NIB; bj = bj + 1) begin
                bv = expected(t, bj);
                for (bi = 0; bi < 8; bi = bi + 1) set_bit(bk + bi, bv[7 - bi]);
                bk = bk + 8;
                if (is_gap(bj)) bk = bk + 2;      // the two zero bits
            end
            sent_bits = bk;
        end
    endtask

    // The host's answer: seven chunks of host_img.
    task send_bits(input integer drv, input integer qtr, input [7:0] sq, input integer nbits);
        integer sc, sn, sk, sb;
        begin
            for (sc = 0; sc < 7; sc = sc + 1) begin
                sn = (sc < 6) ? CHUNK : 152;
                @(negedge clk);
                msg_valid = 1'b1; msg_type = T_FD_TRACK; msg_len = 8'(sn + 2);
                @(negedge clk);
                msg_valid = 1'b0; pay_valid = 1'b1;
                pay_data = {sq, 8'(sc), 8'(qtr), 7'd0, 1'(drv)};
                @(negedge clk);
                pay_data = {16'd0, 16'(nbits)};
                for (sk = 0; sk < sn; sk = sk + 1) begin
                    @(negedge clk);
                    sb = 4 * (sc * CHUNK + sk);
                    pay_data = {host_img[sb + 3], host_img[sb + 2], host_img[sb + 1], host_img[sb]};
                end
                @(negedge clk);
                pay_valid = 1'b0;
            end
            @(posedge clk); #1;
        end
    endtask
    task send_track(input integer drv, input integer trk, input integer qtr, input [7:0] sq);
        begin
            build_track(trk);
            send_bits(drv, qtr, sq, sent_bits);
        end
    endtask

    // The 3.5" host image: a nibble per slot, whatever pattern - the card
    // does not decode it, and the bench only has to see its OWN bytes come
    // back changed where it wrote and unchanged everywhere else.
    reg [7:0] img35 [0:NIB35-1];
    task build35;
        integer bi;
        begin
            for (bi = 0; bi < NIB35; bi = bi + 1) img35[bi] = 8'((bi * 7 + 11) & 8'hFF) | 8'h80;
        end
    endtask
    task send35(input integer qtr, input [7:0] sq);
        integer sc, sn, sk, sb;
        begin
            for (sc = 0; sc < CHUNKS35; sc = sc + 1) begin
                sn = (sc < CHUNKS35 - 1) ? CHUNK : (WORDS35 - (CHUNKS35 - 1) * CHUNK);
                @(negedge clk);
                msg_valid = 1'b1; msg_type = T_FD35_TRACK; msg_len = 8'(sn + 2);
                @(negedge clk);
                msg_valid = 1'b0; pay_valid = 1'b1;
                pay_data = {sq, 8'(sc), 8'(qtr), 8'd0};
                @(negedge clk);
                pay_data = {8'(CHUNKS35), 8'd0, 16'(NIB35)};
                for (sk = 0; sk < sn; sk = sk + 1) begin
                    @(negedge clk);
                    sb = 4 * (sc * CHUNK + sk);
                    pay_data = {(sb + 3 < NIB35) ? img35[sb + 3] : 8'd0,
                                (sb + 2 < NIB35) ? img35[sb + 2] : 8'd0,
                                (sb + 1 < NIB35) ? img35[sb + 1] : 8'd0,
                                img35[sb]};
                end
                @(negedge clk);
                pay_valid = 1'b0;
            end
            @(posedge clk); #1;
        end
    endtask

    function [31:0] seekw(input [7:0] sq, input integer qtr, input integer ph, input integer drv);
        seekw = {sq, 8'd0, 8'(qtr), 7'(ph), 1'(drv)};
    endfunction

    // ---- everything the card sends ------------------------------------------------
    reg [31:0] out_mem [0:131071];
    integer    msg_at  [0:4095];
    reg [7:0]  msg_typ [0:4095];
    integer    nout = 0, nmsg = 0, left = 0, ndirty = 0, nseek = 0, ndirty35 = 0;
    always @(posedge clk) if (!rst && tx_valid && tx_take) begin
        out_mem[nout] = tx_word;
        if (left == 0) begin
            msg_at[nmsg]  = nout;
            msg_typ[nmsg] = tx_word[15:8];
            nmsg = nmsg + 1;
            left = tx_word[7:0];
            if (tx_word[15:8] == T_FD_DIRTY) ndirty = ndirty + 1;
            if (tx_word[15:8] == T_FD_SEEK)  nseek  = nseek + 1;
            if (tx_word[15:8] == T_FD35_DIRTY) ndirty35 = ndirty35 + 1;
        end else begin
            left = left - 1;
        end
        nout = nout + 1;
    end

    task wait_msg(input [7:0] t, input integer from, output integer found, input integer max_clk);
        integer wn, wk;
        begin
            found = -1; wn = 0;
            while (found < 0 && wn < max_clk) begin
                for (wk = from; wk < nmsg; wk = wk + 1)
                    if (found < 0 && msg_typ[wk] == t && (wk < nmsg - 1 || left == 0)) found = wk;
                if (found < 0) begin wait_clk(1); wn = wn + 1; end
            end
        end
    endtask
    task wait_chunks(input integer mark, input integer want_n, input integer max_clk);
        integer wc;
        begin
            wc = 0;
            while ((ndirty < mark + want_n || left != 0) && wc < max_clk) begin
                wait_clk(1);
                wc = wc + 1;
            end
        end
    endtask

    // An FD_DIRTY upload reassembled, skipping the first `skip` chunks after a
    // watermark; checks each chunk's length, number, seq, position and bits.
    reg [7:0]  up_img [0:6655];
    reg [31:0] up_w0;
    integer    up_bits, bad_chunk;
    task gather_upload(input integer from, input integer skip, output integer seen, output integer first_at);
        integer gk, gc, gw, gn, gi, gbase, gs;
        reg [31:0] wd;
        begin
            seen = 0; first_at = -1; gs = 0; bad_chunk = 0;
            for (gk = from; gk < nmsg; gk = gk + 1) begin
                if (msg_typ[gk] == T_FD_DIRTY) begin
                    if (gs >= skip && seen < 7) begin
                        gbase = msg_at[gk];
                        if (first_at < 0) begin
                            first_at = gk; up_w0 = out_mem[gbase + 1]; up_bits = out_mem[gbase + 2][15:0];
                        end
                        gc = out_mem[gbase + 1][18:16];
                        gn = out_mem[gbase][7:0] - 2;
                        if (gc != seen || gn != ((gc < 6) ? CHUNK : 152) ||
                            out_mem[gbase + 1][31:24] != up_w0[31:24] ||
                            out_mem[gbase + 1][15:0] != up_w0[15:0] ||
                            out_mem[gbase + 2][15:0] != 16'(up_bits))
                            bad_chunk = bad_chunk + 1;
                        for (gw = 0; gw < gn; gw = gw + 1) begin
                            wd = out_mem[gbase + 3 + gw];
                            gi = 4 * (gc * CHUNK + gw);
                            up_img[gi]   = wd[7:0];
                            up_img[gi+1] = wd[15:8];
                            up_img[gi+2] = wd[23:16];
                            up_img[gi+3] = wd[31:24];
                        end
                        seen = seen + 1;
                    end
                    gs = gs + 1;
                end
            end
        end
    endtask
    function up_bit(input integer i);
        up_bit = up_img[(i / 8) % 6656][7 - (i % 8)];
    endfunction
    // A byte of the card's buffer as it stands (words 0-1023 in tile 0, then 1).
    function [7:0] buf_byte(input integer b);
        integer w;
        begin
            w = b / 4;
            if (w < 1024) buf_byte = dut.tbuf0[w][8 * (b % 4) +: 8];
            else          buf_byte = dut.tbuf1[w - 1024][8 * (b % 4) +: 8];
        end
    endfunction
    function buf_bit(input integer i);
        reg [7:0] bb;
        begin
            bb = buf_byte(i / 8);
            buf_bit = bb[7 - (i % 8)];
        end
    endfunction
    reg [7:0] snap [0:6655];

    // The RWTS's poll: a read every seven cycles, a new nibble when the high
    // bit is set and it differs from the last - a partial in between marks a
    // new one, so two equal nibbles in a row are told apart.
    reg [7:0] seq_mem [0:255];
    integer   polled = 0;
    task poll_nibbles(input integer n);
        integer got, mx;
        reg [7:0] last;
        begin
            got = 0; last = 8'h00; mx = 0; polled = n;
            while (got < n && mx < n * 64) begin
                op(Q6L, 1'b1, 8'd0);
                if (din[7] && din != last) begin
                    seq_mem[got] = din; last = din; got = got + 1;
                end
                if (!din[7]) last = 8'h00;
                idle(6);
                mx = mx + 1;
            end
            if (got < n) fail("the poll loop starved");
        end
    endtask
    function integer run_start(input integer t, input integer n);
        integer p, ri, a, ok;
        begin
            run_start = -1;
            for (a = 0; a + n <= polled && run_start < 0; a = a + 1)
                for (p = 0; p < NIB && run_start < 0; p = p + 1)
                    if (seq_mem[a] == expected(t, p) && seq_mem[a + 1] == expected(t, (p + 1) % NIB)) begin
                        ok = 1;
                        for (ri = 0; ri < n; ri = ri + 1)
                            if (seq_mem[a + ri] !== expected(t, (p + ri) % NIB)) ok = 0;
                        if (ok) run_start = p;
                    end
        end
    endfunction

    integer i, k, m, d0, s0, at, at2, first_seek, n_up, first_up, t0, t1, t2, t3, t4, t5, polls, found, sq;
    reg [119:0] hist, want15;
    reg [7:0]   v8;
    reg [7:0]   data15 [0:14];

    initial begin
        $display("gs_iwm_write_tb: the IWM's 5.25\" drive as a bit stream, read and written, the host at the other end\n");
        for (i = 0; i < 15; i = i + 1) begin
            data15[i] = n62(i * 5 + 3);
            want15[8*(14 - i) +: 8] = data15[i];
        end
        repeat (4) @(posedge clk); #1;
        rst = 1'b0;
        wait_clk(2);

        // --- the disk in, the motor on, track 0 filled -------------------------------
        m = nmsg;
        ins0 = 1'b1;
        op(MOTORON, 1'b1, 8'd0);
        wait_msg(T_FD_SEEK, m, at, 200);
        if (at < 0) fail("no FD_SEEK for the inserted disk");
        else if (out_mem[msg_at[at] + 1] !== seekw(8'd1, 0, 0, 0))
            fail("FD_SEEK should say seq 1, qtr 0, phase 0, drive 1");
        send_track(0, 0, 0, 8'd1);
        if (d5_stale[0] !== 1'b0) fail("track 0 did not fill");
        else $display("  ok: one FD_SEEK {seq 1, qtr 0, phase 0} for the inserted disk, track 0 filled");

        // --- a quarter track: two adjacent magnets on together -----------------------
        m = nmsg;
        op(PH0ON, 1'b1, 8'd0); op(PH1ON, 1'b1, 8'd0);
        idle(14);
        wait_msg(T_FD_SEEK, m, at, 200);
        if (at < 0) fail("no FD_SEEK for the quarter track");
        else if (out_mem[msg_at[at] + 1] !== seekw(8'd2, 1, 0, 0))
            fail("FD_SEEK should say seq 2, qtr 1, phase 0");
        m = nmsg;
        op(PH1OFF, 1'b1, 8'd0);
        idle(14);
        wait_msg(T_FD_SEEK, m, at, 200);
        if (at < 0) fail("no FD_SEEK back from the quarter track");
        else if (out_mem[msg_at[at] + 1] !== seekw(8'd3, 0, 0, 0))
            fail("FD_SEEK should say seq 3, qtr 0, phase 0");
        else $display("  ok: a magnet pair holds a quarter track (qtr 1); released, qtr 0 again");
        op(PH0OFF, 1'b1, 8'd0);
        idle(14);
        send_track(0, 0, 0, 8'd3);

        // --- write-protect sense --------------------------------------------------------
        k = errors;
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        if (din[7] !== 1'b0) fail("a writable disk sensed protected");
        wp0 = 1'b1;
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        if (din[7] !== 1'b1) fail("a protected disk sensed writable");
        wp0 = 1'b0;
        op(DRV2, 1'b1, 8'd0);
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        if (din[7] !== 1'b1) fail("an empty drive sensed writable");
        op(DRV1, 1'b1, 8'd0);
        op(PH1ON, 1'b1, 8'd0); op(PH3ON, 1'b1, 8'd0);
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        if (din[7] !== 1'b1) fail("a writable disk read 0 under ENABLE2 - a SmartPort ACK");
        op(PH3OFF, 1'b1, 8'd0); op(PH1OFF, 1'b1, 8'd0);
        idle(20);
        if (d5_phase[6:0] !== 7'd0) fail("the ENABLE2 probe moved the head");
        op(Q6L, 1'b1, 8'd0);
        if (errors == k) $display("  ok: $C0ED then $C0EE senses writable, protected, an empty drive protected, and 1 under ENABLE2");
        // The drive select refetched track 0 (seq 4, 5): answer the last.
        m = nmsg;
        idle(40);
        if (d5_stale[0] !== 1'b0) begin
            sq = dut.seq;
            send_track(0, 0, 0, 8'(sq));
        end
        if (d5_stale[0] !== 1'b0) fail("track 0 did not come back after the drive select");

        // --- the poll loop reads the track through its sync gaps ------------------------
        idle(40);
        poll_nibbles(96);
        k = run_start(0, 48);
        if (k < 0) fail("the poll loop did not read 48 consecutive nibbles of track 0");
        else $display("  ok: 48 consecutive nibbles from slot %0d, through the ten-bit sync gaps", k);

        // --- a sector written at the machine's pace ------------------------------------
        idle(40);
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        first_w = -1;
        op(Q7H, 1'b0, 8'hFF);
        op(Q6L, 1'b1, 8'd0);
        idle(38);
        for (i = 0; i < 4; i = i + 1) write_nibble(8'hFF, 40);
        for (i = 0; i < 15; i = i + 1) write_nibble(data15[i], 32);
        op(Q7L, 1'b1, 8'd0);
        t0 = first_w;
        if (d5_dirty[0] !== 1'b1) fail("the write did not mark the buffer dirty");
        else $display("  ok: the burst landed %0d bits from bit %0d, the buffer dirty", wgos, t0);

        // ...read back through the register on the next revolution.
        hist = 120'd0; found = 0; polls = 0; v8 = 8'h00;
        while (found == 0 && polls < 40000) begin
            op(Q6L, 1'b1, 8'd0);
            if (din[7] && din != v8) begin
                hist = {hist[111:0], din};
                v8 = din;
                if (hist == want15) found = 1;
            end
            if (!din[7]) v8 = 8'h00;      // a partial between: the next is a new nibble
            idle(6);
            polls = polls + 1;
        end
        if (found == 0) fail("the written bytes did not read back through the register");
        else $display("  ok: the fifteen data bytes read back in order, %0d polls in", polls);

        // --- leaving the track sends it home first ---------------------------------------
        m = nmsg;
        op(PH1ON, 1'b1, 8'd0); idle(14);
        wait_msg(T_FD_SEEK, m, first_seek, 5000);
        sq = dut.seq;
        if (first_seek < 0) fail("no FD_SEEK for the half step");
        else if (out_mem[msg_at[first_seek] + 1] !== seekw(8'(sq), 2, 1, 0))
            fail("the half step's FD_SEEK should say qtr 2, phase 1");
        gather_upload(m, 0, n_up, first_up);
        if (n_up != 7) begin
            $display("FAIL: %0d FD_DIRTY chunks, expected 7", n_up); errors = errors + 1;
        end else if (first_up > first_seek) fail("the upload came after the seek");
        else if (bad_chunk != 0) fail("an FD_DIRTY chunk had the wrong length, number, seq, position or bits");
        else if (up_w0[31:24] != 8'(sq - 1) || up_w0[15:8] != 8'd0 || up_w0[0] != 1'b0)
            fail("FD_DIRTY should carry the fill's seq, qtr 0, drive 1");
        else if (up_bits != sent_bits) begin
            $display("FAIL: the upload says %0d bits, expected %0d", up_bits, sent_bits); errors = errors + 1;
        end else $display("  ok: seven FD_DIRTY chunks with the fill's seq and the track's bits, before the FD_SEEK");
        k = 0;
        for (i = 0; i < 5; i = i + 1) begin
            for (m = 0; m < 8; m = m + 1) if (up_bit(t0 + 10 * i + m) !== 1'b1) k = k + 1;
            for (m = 8; m < 10; m = m + 1) if (up_bit(t0 + 10 * i + m) !== 1'b0) k = k + 1;
        end
        for (i = 0; i < 15; i = i + 1)
            for (m = 0; m < 8; m = m + 1) if (up_bit(t0 + 50 + 8 * i + m) !== data15[i][7 - m]) k = k + 1;
        if (k != 0) begin
            $display("FAIL: %0d bits of the written run are wrong", k); errors = errors + 1;
        end else $display("  ok: five ten-bit syncs and fifteen data bytes, bit for bit, contiguous");
        k = 0;
        for (i = 0; i < 6656; i = i + 1)
            if ((8 * i + 8 <= t0) || (8 * i >= t0 + 170))
                if (up_img[i] !== host_img[i]) k = k + 1;
        if (k != 0) begin
            $display("FAIL: %0d bytes outside the write differ from the fill", k); errors = errors + 1;
        end else $display("  ok: everything outside the write is the track as filled");
        if (d5_dirty[0] !== 1'b0) fail("dirty did not clear after the upload");
        m = nmsg;
        op(PH2ON, 1'b1, 8'd0); op(PH1OFF, 1'b1, 8'd0); idle(14);
        op(PH2OFF, 1'b1, 8'd0);
        wait_msg(T_FD_SEEK, m, at, 5000);
        sq = dut.seq;
        if (at < 0 || out_mem[msg_at[at] + 1] !== seekw(8'(sq), 4, 2, 0))
            fail("no FD_SEEK {qtr 4, phase 2} for track 1");
        send_track(0, 1, 4, 8'(sq));

        // --- a write-protected disk takes nothing -----------------------------------------
        wp0 = 1'b1;
        idle(4);
        for (i = 0; i < 6656; i = i + 1) snap[i] = buf_byte(i);
        at = wgos;
        write_one(8'hB5, t1);
        k = 0;
        for (i = 0; i < 6656; i = i + 1) if (buf_byte(i) !== snap[i]) k = k + 1;
        if (wgos != at || k != 0 || d5_dirty[0] !== 1'b0) begin
            $display("FAIL: a protected disk took %0d bits, %0d bytes of the card's track changed", wgos - at, k);
            errors = errors + 1;
        end
        m = nmsg; d0 = ndirty;
        op(PH3ON, 1'b1, 8'd0); idle(14);
        op(PH0ON, 1'b1, 8'd0); op(PH3OFF, 1'b1, 8'd0); idle(14);
        op(PH0OFF, 1'b1, 8'd0);
        wait_msg(T_FD_SEEK, m, first_seek, 5000);
        idle(20);
        sq = dut.seq;
        if (first_seek < 0) fail("no FD_SEEK after the protected write");
        else if (ndirty != d0) fail("a protected disk sent a track home");
        else if (errors == 0) $display("  ok: a protected disk took no bit, the card's track untouched, nothing sent home");
        wp0 = 1'b0;
        send_track(0, 2, 8, 8'(sq));

        // --- the tab set mid-burst stops landings ---------------------------------------
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        at = wgos;
        op(Q7H, 1'b0, 8'hC3);
        op(Q6L, 1'b1, 8'd0);
        idle(20);
        if (wgos == at) fail("the writable burst before the tab wrote nothing");
        wp0 = 1'b1;
        at2 = wgos;
        idle(40);
        op(Q7L, 1'b1, 8'd0);
        idle(8);
        if (wgos != at2) begin
            $display("FAIL: %0d bits landed after the tab was set mid-burst", wgos - at2); errors = errors + 1;
        end else $display("  ok: the tab set mid-burst - nothing lands from that clock on");
        wp0 = 1'b0;
        idle(4);

        // --- the motor stopping sends it home, and the buffer stays ---------------------
        write_one(8'hDE, t1);
        m = nmsg; d0 = ndirty; s0 = nseek;
        op(MOTOROFF, 1'b1, 8'd0);
        idle(320);
        wait_chunks(d0, 7, 5000);
        gather_upload(m, 0, n_up, first_up);
        k = 0;
        for (i = 0; i < 8; i = i + 1) if (up_bit(t1 + i) !== ((8'hDE >> (7 - i)) & 1)) k = k + 1;
        if (n_up != 7 || bad_chunk != 0 || up_w0[15:8] != 8'd8)
            fail("the motor stopping did not send seven chunks of qtr 8");
        else if (t1 < 0 || k != 0) fail("the motor's upload does not carry the write");
        else if (nseek != s0 || d5_stale[0] !== 1'b0) fail("the motor stopping refetched the track");
        else $display("  ok: the motor stopping sent the track home with the write, no refetch");
        op(MOTORON, 1'b1, 8'd0);
        idle(40);

        // --- the host's flush ------------------------------------------------------------------
        write_one(8'hE7, t2);
        m = nmsg; d0 = ndirty; s0 = nseek;
        flush1;
        wait_chunks(d0, 7, 5000);
        gather_upload(m, 0, n_up, first_up);
        k = 0;
        for (i = 0; i < 8; i = i + 1) begin
            if (up_bit(t1 + i) !== ((8'hDE >> (7 - i)) & 1)) k = k + 1;
            if (up_bit(t2 + i) !== ((8'hE7 >> (7 - i)) & 1)) k = k + 1;
        end
        if (n_up != 7 || bad_chunk != 0) fail("the host's flush did not send seven chunks");
        else if (t2 < 0 || k != 0) fail("the flush's upload lost a write");
        else if (nseek != s0 || d5_stale[0] !== 1'b0) fail("the flush refetched the track");
        else $display("  ok: the host's flush sent the track home with both writes, no refetch");

        // --- a flush while an upload is going out -------------------------------------
        write_one(8'hB6, t3);
        m = nmsg; d0 = ndirty;
        flush1;
        k = nout; polls = 0;
        while (nout < k + 400 && polls < 5000) begin wait_clk(1); polls = polls + 1; end
        if (nout < k + 400) fail("the first flush's upload did not start");
        idle(96);
        write_one(8'hB7, t4);
        flush1;
        wait_chunks(d0, 14, 10000);
        if (ndirty - d0 != 14) begin
            $display("FAIL: %0d chunks for two flushes, expected 14", ndirty - d0); errors = errors + 1;
        end else begin
            gather_upload(m, 7, n_up, first_up);
            k = 0;
            for (i = 0; i < 8; i = i + 1) begin
                if (up_bit(t3 + i) !== ((8'hB6 >> (7 - i)) & 1)) k = k + 1;
                if (up_bit(t4 + i) !== ((8'hB7 >> (7 - i)) & 1)) k = k + 1;
            end
            if (n_up != 7 || bad_chunk != 0) fail("the second upload is not seven good chunks");
            else if (k != 0) fail("the second upload does not carry both writes");
            else $display("  ok: a flush during an upload sent the track again, with the later write");
        end

        // --- an eject sends it home ----------------------------------------------------------
        write_one(8'hBA, t5);
        m = nmsg; d0 = ndirty;
        ins0 = 1'b0;
        wait_clk(2);
        wait_chunks(d0, 7, 5000);
        gather_upload(m, 0, n_up, first_up);
        k = 0;
        for (i = 0; i < 8; i = i + 1) if (up_bit(t5 + i) !== ((8'hBA >> (7 - i)) & 1)) k = k + 1;
        if (n_up != 7 || bad_chunk != 0) fail("the eject did not send seven chunks");
        else if (k != 0) fail("the eject's upload does not carry the write");
        else $display("  ok: the eject sent the written track home");

        // --- a burst on every cell phase -----------------------------------------------
        m = nmsg;
        ins0 = 1'b1;
        wait_msg(T_FD_SEEK, m, at, 2000);
        if (at < 0) fail("no FD_SEEK after the re-insert");
        else send_track(0, 2, 8, out_mem[msg_at[at] + 1][31:24]);
        found = 0;
        for (k = 0; k < 4; k = k + 1) begin
            idle(9 + k);
            op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
            first_w = -1;
            op(Q7H, 1'b0, data15[0]);
            op(Q6L, 1'b1, 8'd0);
            idle(30);
            for (i = 1; i < 8; i = i + 1) write_nibble(data15[i], 32);
            op(Q7L, 1'b1, 8'd0);
            idle(8);
            n_up = 0;
            for (i = 0; i < 8; i = i + 1)
                for (m = 0; m < 8; m = m + 1)
                    if (buf_bit(first_w + 8 * i + m) !== data15[i][7 - m]) n_up = n_up + 1;
            if (first_w < 0 || n_up != 0) begin
                $display("FAIL: phase %0d: %0d of the burst's 64 bits wrong", k, n_up);
                errors = errors + 1; found = found + 1;
            end
        end
        if (found == 0) $display("  ok: eight bytes at 32 cycles are 64 contiguous bits on all four cell phases");

        // ==== the 3.5" drive writes ==========================================
        // Its platter is nibbles, so a write is a BYTE in the slot under the
        // head, and the track goes home as T_FD35_DIRTY - the fill's shape in
        // the other direction.
        begin : d35
            integer b35, want_at, bad35, ch, hdr, words_seen, n_ch, exp_len;
            reg [7:0] got35 [0:NIB35-1];
            build35;
            // The 5.25" side goes quiet: motor off, then the 3.5" selected.
            op(MOTOROFF, 1'b1, 8'd0);
            idle(400);
            m = nmsg;
            @(negedge clk); sel35 = 1'b1; ins35 = 1'b1; wp35 = 1'b0;
            @(negedge clk);
            op(MOTORON, 1'b1, 8'd0);
            idle(40);
            wait_msg(T_FD35_SEEK, m, at, 4000);
            if (at < 0) fail("no FD35_SEEK for the 3.5\" disk");
            else begin
                sq = out_mem[msg_at[at] + 1][31:24];
                send35(0, 8'(sq));
                idle(20);
                if (dut.stale !== 1'b0) fail("the 3.5\" track did not fill");
                else $display("  ok: the 3.5\" drive asks for its track and the fill lands");

                // --- a protected disk takes nothing ---------------------------
                k = errors;
                @(negedge clk); wp35 = 1'b1; @(negedge clk);
                op(Q6H, 1'b1, 8'd0); op(Q7H, 1'b1, 8'd0);
                w35s = 0;
                write35(8'hA5);
                if (w35s != 0) fail("a protected 3.5\" disk took a write");
                op(Q7L, 1'b1, 8'd0);
                @(negedge clk); wp35 = 1'b0; @(negedge clk);
                if (errors == k) $display("  ok: a write-protected 3.5\" disk takes nothing");

                // --- eight bytes land where the head is -----------------------
                k = errors;
                op(Q6H, 1'b1, 8'd0); op(Q7H, 1'b1, 8'd0);
                w35s = 0; first_w35 = -1;
                for (i = 0; i < 8; i = i + 1) write35(data15[i]);
                op(Q7L, 1'b1, 8'd0);
                if (first_w35 < 0) fail("no 3.5\" byte landed at all");
                else if (w35s != 8) fail("not eight 3.5\" bytes landed");
                else begin
                    // Eight DISTINCT slots, one after another as the platter
                    // turns - "eight landed" alone would also be true of
                    // eight writes into the same slot, which is a different
                    // (and wrong) drive.
                    bad35 = 0;
                    for (i = 0; i < 8; i = i + 1)
                        if (w35_at[i] !== ((first_w35 + i) % NIB35)) bad35 = bad35 + 1;
                    if (bad35 != 0) begin
                        $display("FAIL: %0d of the eight bytes did not land in consecutive slots", bad35);
                        for (i = 0; i < 8; i = i + 1) $display("      %0d -> slot %0d", i, w35_at[i]);
                        errors = errors + 1;
                    end
                end
                if (errors == k) $display("  ok: eight bytes land in eight slots under the head, one per slot");

                // --- the written track goes home ------------------------------
                // The motor stopping ends the buffer's claim.
                m = nmsg; ndirty35 = 0;
                op(MOTOROFF, 1'b1, 8'd0);
                idle(600);
                n_ch = 0;
                // `left != 0` too: ndirty35 counts HEADERS, so the tenth is
                // there long before its words are, and reading the buffer
                // then finds zeroes that were never sent.
                while ((ndirty35 < CHUNKS35 || left != 0) && n_ch < 200000) begin
                    wait_clk(1); n_ch = n_ch + 1;
                end
                if (ndirty35 != CHUNKS35) begin
                    $display("FAIL: %0d FD35_DIRTY chunks, expected %0d", ndirty35, CHUNKS35);
                    errors = errors + 1;
                end else begin
                    // Every chunk's header, then its words into got35.
                    bad35 = 0; words_seen = 0;
                    ch = 0;
                    for (k = m; k < nmsg; k = k + 1) begin
                        if (msg_typ[k] == T_FD35_DIRTY) begin
                            hdr = msg_at[k];
                            exp_len = (ch < CHUNKS35 - 1) ? CHUNK : (WORDS35 - (CHUNKS35 - 1) * CHUNK);
                            if (out_mem[hdr][7:0] !== 8'(exp_len + 2)) begin
                                $display("    chunk %0d len %0d, want %0d", ch, out_mem[hdr][7:0], exp_len + 2);
                                bad35 = bad35 + 1;
                            end
                            if (out_mem[hdr + 1] !== {8'(sq), 8'(ch), 8'd0, 8'd0}) begin
                                $display("    chunk %0d w0 %08x, want %08x", ch, out_mem[hdr + 1],
                                         {8'(sq), 8'(ch), 8'd0, 8'd0});
                                bad35 = bad35 + 1;
                            end
                            if (out_mem[hdr + 2] !== {8'(CHUNKS35), 8'd0, 16'(NIB35)}) begin
                                $display("    chunk %0d w1 %08x, want %08x", ch, out_mem[hdr + 2],
                                         {8'(CHUNKS35), 8'd0, 16'(NIB35)});
                                bad35 = bad35 + 1;
                            end
                            for (i = 0; i < exp_len; i = i + 1) begin
                                b35 = 4 * (ch * CHUNK + i);
                                if (b35 + 0 < NIB35) got35[b35 + 0] = out_mem[hdr + 3 + i][7:0];
                                if (b35 + 1 < NIB35) got35[b35 + 1] = out_mem[hdr + 3 + i][15:8];
                                if (b35 + 2 < NIB35) got35[b35 + 2] = out_mem[hdr + 3 + i][23:16];
                                if (b35 + 3 < NIB35) got35[b35 + 3] = out_mem[hdr + 3 + i][31:24];
                                words_seen = words_seen + 1;
                            end
                            ch = ch + 1;
                        end
                    end
                    if (bad35 != 0) begin
                        $display("FAIL: %0d wrong fields in the FD35_DIRTY headers", bad35);
                        errors = errors + 1;
                    end else if (words_seen != WORDS35) begin
                        $display("FAIL: the upload carried %0d words, expected %0d", words_seen, WORDS35);
                        errors = errors + 1;
                    end else begin
                        // The eight bytes we wrote, and NOTHING else, differ
                        // from the track the host sent down.
                        // What the card says it landed, where it says it
                        // landed it - and nothing else touched.  Checked
                        // against the RECORD of the writes rather than an
                        // assumption about where the head would be, so the
                        // property is "the upload carries exactly what was
                        // written" and not "the head moved as I guessed".
                        bad35 = 0;
                        for (i = 0; i < NIB35; i = i + 1) begin
                            want_at = -1;
                            for (k = 0; k < w35s; k = k + 1)
                                if (i == w35_at[k]) want_at = k;
                            if (want_at >= 0) begin
                                if (got35[i] !== w35_of[want_at]) bad35 = bad35 + 1;
                            end else if (got35[i] !== img35[i]) bad35 = bad35 + 1;
                        end
                        $display("    (wrote %0d slots from %0d)", w35s, first_w35);
                        if (bad35 != 0) begin
                            $display("FAIL: %0d nibbles of the returned 3.5\" track are wrong", bad35);
                            errors = errors + 1;
                        end else begin
                            $display("  ok: %0d chunks carry the track back, the eight written slots changed and %0d others not",
                                     CHUNKS35, NIB35 - 8);
                        end
                    end
                end
            end
        end

        $display("\n%0d bits written, %0d bytes loaded, %0d uploads", dut.wr525, dut.ld525, dut.up525);
        if (errors == 0) $display("PASS");
        else $display("FAILED: %0d", errors);
        $finish;
    end
endmodule
