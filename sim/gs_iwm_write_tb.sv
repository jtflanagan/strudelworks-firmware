`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_iwm_write_tb - the IIgs IWM's 5.25" WRITES, with the tb playing both the
// program and the host.
//
// One op per clock, each a tick of the core's time - which is the drive's
// only clock - so every access lands on an exact cycle, as a DOS write loop
// counts them.  The tb answers FD_SEEK with the host's seven FD_TRACK chunks
// and reassembles FD_DIRTY uploads as the host's floppy service would
// (src/fd_service.cpp on_dirty), including the seq it insists on.
//
// THE PROPERTIES, each a way this is or could be wrong (docs/IWM35.md):
//
//   * $C0ED then $C0EE senses the disk's write protect in bit 7: writable,
//     protected, and an empty drive protected.
//   * a sector written at the machine's own pace - self-sync $FF at 40
//     cycles, data at 32, the byte loaded by STA $C0ED/$C0EF - lands in
//     consecutive slots, a slow byte's extra zero bits taking no slot, and
//     reads back through the register on the next revolution.
//   * leaving a written track sends it home first: seven FD_DIRTY chunks
//     carrying the seq that filled it, before the FD_SEEK for the next track;
//     everything outside the write is the track as the host sent it.
//   * a write-protected disk takes nothing and sends nothing home.
//   * the motor stopping and the host's flush each send the track home
//     without a refetch - the buffer stays the track's.
//   * a flush while an upload is going out sends the track again after it,
//     with what was written meanwhile.
//   * an ejected disk sends its written track home.
//   * DOS 3.3's own spacing (syncs at 40, 36 to $D5, 32, 32, 36 to the data,
//     32 after) lands sync, prologue and data in a row at every one of the
//     32 phases a burst can start at - no $FF between the prologue and the
//     data, which the first write build put there on the card.
//
// THE WAITS COUNT MESSAGES AS THEY ARRIVE (ndirty, nseek, kept by the capture
// block) and never call a function in a loop condition: under Verilator's
// timing a loop `while (count_msg(...) < n)` inside a waiting task left early
// (static tasks) or never ran (automatic ones).  A watchdog ends a run that
// stalls, so a stall still prints.
//////////////////////////////////////////////////////////////////////////////////
module gs_iwm_write_tb;
    localparam integer NIB   = 6384;
    localparam integer CHUNK = 252;
    localparam [7:0] T_FD_TRACK = 8'h1F, T_FD_SEEK = 8'h20, T_FD_DIRTY = 8'h21;
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
    reg  [1:0]  d5_inserted = 2'b00, d5_wp = 2'b00, d5_flush = 2'b00;
    wire [1:0]  d5_stale, d5_dirty;
    wire [13:0] d5_phase;
    wire        stall;

    gs_iwm #(.MOTOR_OFF_TICKS (300)) dut (
        .clk (clk), .rst (rst), .res_sync (1'b1),
        .op_lo (op_lo), .op_rw (op_rw), .op_wdata (op_wdata), .act (act),
        .rd_byte (rd_byte),
        .apple35_sel (1'b0), .c031_ctrl (1'b0),
        .tick (tick),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .tx_word (tx_word), .tx_valid (tx_valid), .tx_take (tx_take),
        .drv_inserted (1'b0), .drv_wp (1'b1),
        .late_clr (1'b0), .fill_clr (1'b0),
        .d5_inserted (d5_inserted), .d5_wp (d5_wp),
        .d5_nibbles ({13'd6384, 13'd6384}), .d5_tracks ({6'd35, 6'd35}),
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

    // A run that stalls still ends, and says so.
    initial begin
        #50_000_000;
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

    // One 32- or 40-cycle step of a write burst: load the byte, shift.
    task write_nibble(input [7:0] b, input integer spacing);
        begin
            op(Q6H, 1'b0, b);           // STA $C0ED: the load is the write
            op(Q6L, 1'b1, 8'd0);        // ORA $C0EC: the shift
            idle(spacing - 2);
        end
    endtask

    // One byte written: into write mode, the load, back to read mode.
    // Returns the slot it landed in.
    task write_one(input [7:0] b, output integer slot);
        begin
            op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
            op(Q7H, 1'b0, b);
            slot = dut.wr_last;
            op(Q6L, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        end
    endtask

    // A pulse of the host's flush for drive 1, a clock wide.
    task flush1;
        begin
            @(negedge clk); d5_flush = 2'b01;
            @(negedge clk); d5_flush = 2'b00;
            @(posedge clk); #1;
        end
    endtask

    // ---- the host ----------------------------------------------------------------
    function [7:0] nib(input integer t, input integer p);
        nib = 8'h80 | 8'((p * 13 + t * 31) & 8'h7F);
    endfunction

    task send_track(input integer drv, input integer trk, input [7:0] sq);
        integer sc, sn, sk, sb;
        begin
            for (sc = 0; sc < 7; sc = sc + 1) begin
                sn = (sc < 6) ? CHUNK : 152;
                @(negedge clk);
                msg_valid = 1'b1; msg_type = T_FD_TRACK; msg_len = 8'(sn + 1);
                @(negedge clk);
                msg_valid = 1'b0; pay_valid = 1'b1;
                pay_data = {sq, 8'(sc), 2'd0, 6'(trk), 7'd0, 1'(drv)};
                for (sk = 0; sk < sn; sk = sk + 1) begin
                    @(negedge clk);
                    sb = 4 * (sc * CHUNK + sk);
                    pay_data = {nib(trk, sb + 3), nib(trk, sb + 2), nib(trk, sb + 1), nib(trk, sb)};
                end
                @(negedge clk);
                pay_valid = 1'b0;
            end
            @(posedge clk); #1;
        end
    endtask

    // Everything the card sends, split into messages by their lengths, with
    // running counts of the two kinds the tests wait on.
    reg [31:0] out_mem [0:131071];
    integer    msg_at  [0:4095];
    reg [7:0]  msg_typ [0:4095];
    integer    nout = 0, nmsg = 0, left = 0, ndirty = 0, nseek = 0;
    always @(posedge clk) if (!rst && tx_valid && tx_take) begin
        out_mem[nout] = tx_word;
        if (left == 0) begin
            msg_at[nmsg]  = nout;
            msg_typ[nmsg] = tx_word[15:8];
            nmsg = nmsg + 1;
            left = tx_word[7:0];
            if (tx_word[15:8] == T_FD_DIRTY) ndirty = ndirty + 1;
            if (tx_word[15:8] == T_FD_SEEK)  nseek  = nseek + 1;
        end else begin
            left = left - 1;
        end
        nout = nout + 1;
    end

    // A message found only once all its words are in: its header can land a
    // clock before its first word.
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

    // Wait until `want_n` more FD_DIRTY chunks than `mark` have arrived, whole.
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
    // watermark; checks each chunk's length and first word as it goes.
    reg [7:0]  up_img [0:6655];
    reg [31:0] up_w0;
    integer    bad_chunk;
    task gather_upload(input integer from, input integer skip, output integer seen, output integer first_at);
        integer gk, gc, gw, gn, gi, gbase, gs;
        reg [31:0] wd;
        begin
            seen = 0; first_at = -1; gs = 0; bad_chunk = 0;
            for (gk = from; gk < nmsg; gk = gk + 1) begin
                if (msg_typ[gk] == T_FD_DIRTY) begin
                    if (gs >= skip && seen < 7) begin
                        gbase = msg_at[gk];
                        if (first_at < 0) begin first_at = gk; up_w0 = out_mem[gbase + 1]; end
                        gc = out_mem[gbase + 1][18:16];
                        gn = out_mem[gbase][7:0] - 1;
                        if (gc != seen || gn != ((gc < 6) ? CHUNK : 152) ||
                            out_mem[gbase + 1][31:24] != up_w0[31:24] ||
                            out_mem[gbase + 1][15:0] != up_w0[15:0])
                            bad_chunk = bad_chunk + 1;
                        for (gw = 0; gw < gn; gw = gw + 1) begin
                            wd = out_mem[gbase + 2 + gw];
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

    integer i, k, m, d0, s0, at, first_seek, n_up, first_up, t0, t1, t2, t3, t4, t5, polls, found;
    reg [119:0] hist, want15;
    reg [7:0]   v8;

    initial begin
        $display("gs_iwm_write_tb: the IWM's 5.25\" drive written, the host at the other end\n");
        for (i = 0; i < 15; i = i + 1) want15[8*(14 - i) +: 8] = 8'hD5 + i[7:0];
        repeat (4) @(posedge clk); #1;
        rst = 1'b0;
        wait_clk(2);

        // --- the disk in, the motor on, track 0 filled -------------------------------
        m = nmsg;
        d5_inserted = 2'b01;
        op(MOTORON, 1'b1, 8'd0);
        wait_msg(T_FD_SEEK, m, at, 200);
        if (at < 0) fail("no FD_SEEK for the inserted disk");
        else if (out_mem[msg_at[at] + 1] !== {8'd1, 8'd0, 8'd0, 8'd0})
            fail("FD_SEEK should say seq 1, track 0, drive 1");
        send_track(0, 0, 8'd1);
        if (d5_stale[0] !== 1'b0) fail("track 0 did not fill");
        else $display("  ok: one FD_SEEK for the inserted disk, track 0 filled");

        // --- write-protect sense --------------------------------------------------------
        k = errors;
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        if (din[7] !== 1'b0) fail("a writable disk sensed protected");
        d5_wp[0] = 1'b1;
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        if (din[7] !== 1'b1) fail("a protected disk sensed writable");
        d5_wp[0] = 1'b0;
        op(DRV2, 1'b1, 8'd0);
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        if (din[7] !== 1'b1) fail("an empty drive sensed writable");
        op(DRV1, 1'b1, 8'd0);
        // Under ENABLE2 (phases 1 and 3) bit 7 is the SmartPort bus's ACK, not
        // the drive: 1, even with a writable disk in (KEGS read_iwm).  The
        // ROM's slot-5 probe polls it; a 0 there hangs the boot.
        op(PH1ON, 1'b1, 8'd0); op(PH3ON, 1'b1, 8'd0);
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        if (din[7] !== 1'b1) fail("a writable disk read 0 under ENABLE2 - a SmartPort ACK");
        op(PH3OFF, 1'b1, 8'd0); op(PH1OFF, 1'b1, 8'd0);
        idle(20);
        if (d5_phase[6:0] !== 7'd0) fail("the ENABLE2 probe moved the head");
        op(Q6L, 1'b1, 8'd0);
        if (errors == k) $display("  ok: $C0ED then $C0EE senses writable, protected, an empty drive protected, and 1 under ENABLE2");

        // --- a sector written at the machine's pace ------------------------------------
        // DOS's way in: LDA $C0ED / LDA $C0EE / LDA #$FF / STA $C0EF / ORA $C0EC -
        // then four more self-sync $FF at 40 cycles, then data at 32.
        idle(40);
        op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
        op(Q7H, 1'b0, 8'hFF);
        op(Q6L, 1'b1, 8'd0);
        t0 = dut.wr_last;
        idle(38);
        for (i = 0; i < 4; i = i + 1) write_nibble(8'hFF, 40);
        for (i = 0; i < 15; i = i + 1) write_nibble(8'hD5 + i[7:0], 32);
        op(Q7L, 1'b1, 8'd0);
        if (d5_dirty[0] !== 1'b1) fail("the write did not mark the buffer dirty");
        else if (dut.wr525 != 20) begin
            $display("FAIL: %0d stores, expected 20", dut.wr525); errors = errors + 1;
        end else $display("  ok: twenty stores from slot %0d, the buffer dirty", t0);

        // ...read back through the register on the next revolution: the poll
        // loop, a read every eight cycles, sees the fifteen bytes in order.
        hist = 120'd0; found = 0; polls = 0;
        while (found == 0 && polls < 30000) begin
            op(Q6L, 1'b1, 8'd0);
            if (din[7]) begin
                hist = {hist[111:0], din};
                if (hist == want15) found = 1;
            end
            idle(7);
            polls = polls + 1;
        end
        if (found == 0) fail("the written bytes did not read back through the register");
        else $display("  ok: the fifteen data bytes read back in order, %0d polls in", polls);

        // --- leaving the track sends it home first ---------------------------------------
        m = nmsg;
        op(PH1ON, 1'b1, 8'd0); idle(14);                          // half-track 1
        op(PH2ON, 1'b1, 8'd0); op(PH1OFF, 1'b1, 8'd0); idle(14);  // half-track 2: track 1
        op(PH2OFF, 1'b1, 8'd0);
        wait_msg(T_FD_SEEK, m, first_seek, 5000);
        if (first_seek < 0) fail("no FD_SEEK for track 1");
        else if (out_mem[msg_at[first_seek] + 1] !== {8'd2, 8'd0, 8'd1, 8'd0})
            fail("FD_SEEK should say seq 2, track 1, drive 1");
        gather_upload(m, 0, n_up, first_up);
        if (n_up != 7) begin
            $display("FAIL: %0d FD_DIRTY chunks, expected 7", n_up); errors = errors + 1;
        end else if (first_up > first_seek) fail("the upload came after the seek");
        else if (bad_chunk != 0) fail("an FD_DIRTY chunk had the wrong length, number, seq or track");
        else if (up_w0 !== {8'd1, 8'd0, 8'd0, 8'd0}) fail("FD_DIRTY should say seq 1 (the fill's), track 0, drive 1");
        else $display("  ok: seven FD_DIRTY chunks with the filling seek's seq, before the FD_SEEK");
        // Contiguous: the five sync bytes take five slots and the data follows
        // at once - a slow byte's extra zero bits take no slot.
        first_up = -1;
        for (i = 0; i < 10; i = i + 1)
            if (first_up < 0 && up_img[(t0 + i) % NIB] == 8'hD5) first_up = i;
        if (first_up != 5) begin
            $display("FAIL: the data starts %0d slots after the burst, expected 5", first_up);
            errors = errors + 1;
        end else begin
            k = 0;
            for (i = 0; i < first_up; i = i + 1) if (up_img[(t0 + i) % NIB] !== 8'hFF) k = k + 1;
            for (i = 0; i < 15; i = i + 1)
                if (up_img[(t0 + first_up + i) % NIB] !== 8'hD5 + i[7:0]) k = k + 1;
            if (k != 0) begin
                $display("FAIL: %0d bytes of the written run are wrong", k); errors = errors + 1;
            end else $display("  ok: five sync bytes fill %0d slots with $FF, the fifteen data bytes follow", first_up);
            k = 0;
            for (i = 0; i < NIB; i = i + 1)
                if (((i - t0 + NIB) % NIB) >= first_up + 15)
                    if (up_img[i] !== nib(0, i)) k = k + 1;
            if (k != 0) begin
                $display("FAIL: %0d bytes outside the write differ from the fill", k); errors = errors + 1;
            end else $display("  ok: everything outside the write is the track as filled");
        end
        if (d5_dirty[0] !== 1'b0) fail("dirty did not clear after the upload");
        send_track(0, 1, 8'd2);

        // --- a write-protected disk takes nothing -----------------------------------------
        d5_wp[0] = 1'b1;
        k = dut.wr525;
        write_one(8'hAA, t1);
        if (dut.wr525 != k || d5_dirty[0] !== 1'b0) fail("a protected disk took a write");
        m = nmsg; d0 = ndirty;
        op(PH3ON, 1'b1, 8'd0); idle(14);                          // half-track 3
        op(PH0ON, 1'b1, 8'd0); op(PH3OFF, 1'b1, 8'd0); idle(14);  // half-track 4: track 2
        op(PH0OFF, 1'b1, 8'd0);
        wait_msg(T_FD_SEEK, m, first_seek, 5000);
        if (first_seek < 0 || out_mem[msg_at[first_seek] + 1] !== {8'd3, 8'd0, 8'd2, 8'd0})
            fail("no FD_SEEK {seq 3, track 2} after the protected write");
        else if (ndirty != d0) fail("a protected disk sent a track home");
        else $display("  ok: a protected disk took no write and sent nothing home");
        d5_wp[0] = 1'b0;
        send_track(0, 2, 8'd3);

        // --- the motor stopping sends it home, and the buffer stays ---------------------
        write_one(8'hDE, t1);
        m = nmsg; d0 = ndirty; s0 = nseek;
        op(MOTOROFF, 1'b1, 8'd0);
        idle(320);
        wait_chunks(d0, 7, 5000);
        gather_upload(m, 0, n_up, first_up);
        if (n_up != 7 || bad_chunk != 0 || up_w0 !== {8'd3, 8'd0, 8'd2, 8'd0})
            fail("the motor stopping did not send seven chunks of track 2, seq 3");
        else if (up_img[t1] !== 8'hDE) fail("the motor's upload does not carry the write");
        else if (nseek != s0 || d5_stale[0] !== 1'b0) fail("the motor stopping refetched the track");
        else $display("  ok: the motor stopping sent track 2 home with the write, no refetch");
        op(MOTORON, 1'b1, 8'd0);
        idle(40);

        // --- the host's flush ------------------------------------------------------------------
        write_one(8'hE7, t2);
        m = nmsg; d0 = ndirty; s0 = nseek;
        flush1;
        wait_chunks(d0, 7, 5000);
        gather_upload(m, 0, n_up, first_up);
        if (n_up != 7 || bad_chunk != 0) fail("the host's flush did not send seven chunks");
        else if (up_img[t1] !== 8'hDE || up_img[t2] !== 8'hE7) fail("the flush's upload lost a write");
        else if (nseek != s0 || d5_stale[0] !== 1'b0) fail("the flush refetched the track");
        else $display("  ok: the host's flush sent track 2 home with both writes, no refetch");

        // --- a flush while an upload is going out -------------------------------------
        write_one(8'hB1, t3);
        m = nmsg; d0 = ndirty;
        flush1;
        k = nout; polls = 0;
        while (nout < k + 400 && polls < 5000) begin wait_clk(1); polls = polls + 1; end   // into the second chunk
        if (nout < k + 400) fail("the first flush's upload did not start");
        idle(96);                                              // three slots on: its own slot
        write_one(8'hB2, t4);
        if (t4 == t3) fail("the two writes landed in one slot - the test proves nothing");
        flush1;
        wait_chunks(d0, 14, 10000);
        if (ndirty - d0 != 14) begin
            $display("FAIL: %0d chunks for two flushes, expected 14", ndirty - d0);
            errors = errors + 1;
        end else begin
            gather_upload(m, 7, n_up, first_up);
            if (n_up != 7 || bad_chunk != 0) fail("the second upload is not seven good chunks");
            else if (up_img[t3] !== 8'hB1 || up_img[t4] !== 8'hB2)
                fail("the second upload does not carry both writes");
            else $display("  ok: a flush during an upload sent the track again, with the later write");
        end

        // --- an eject sends it home ----------------------------------------------------------
        write_one(8'hC3, t5);
        m = nmsg; d0 = ndirty;
        d5_inserted = 2'b00;
        wait_clk(2);
        wait_chunks(d0, 7, 5000);
        gather_upload(m, 0, n_up, first_up);
        if (n_up != 7 || bad_chunk != 0) fail("the eject did not send seven chunks");
        else if (up_img[t5] !== 8'hC3) fail("the eject's upload does not carry the write");
        else $display("  ok: the eject sent the written track home");

        // --- DOS 3.3's own spacing, at every phase ----------------------------------
        // RWTS WRITE16 writes its sync bytes 40 cycles apart, then 36 to $D5,
        // 32 to $AA and $AD, 36 to the first data nibble, and 32 after.  A
        // 36-cycle step is a nine-bit cell: whatever slot boundary it crosses,
        // the prologue and the data must be in consecutive slots, never an
        // $FF between them (the first write build put one there on the card).
        m = nmsg;
        d5_inserted = 2'b01;
        wait_msg(T_FD_SEEK, m, at, 2000);
        if (at < 0) fail("no FD_SEEK after the re-insert");
        else send_track(0, 2, out_mem[msg_at[at] + 1][31:24]);
        found = 0;
        for (k = 0; k < 32; k = k + 1) begin
            idle(200 + k);
            op(Q6H, 1'b1, 8'd0); op(Q7L, 1'b1, 8'd0);
            op(Q7H, 1'b0, 8'hFF);                     // STA $C08F,X: the first sync
            t0 = dut.wr_last;
            op(Q6L, 1'b1, 8'd0);
            idle(38);
            for (i = 0; i < 4; i = i + 1) write_nibble(8'hFF, (i == 3) ? 36 : 40);
            write_nibble(8'hD5, 32);
            write_nibble(8'hAA, 32);
            write_nibble(8'hAD, 36);
            for (i = 0; i < 12; i = i + 1) write_nibble(8'h96 + i[7:0], 32);
            op(Q7L, 1'b1, 8'd0);                      // read mode: the burst ends
            n_up = 0;
            for (i = 0; i < 20; i = i + 1) begin
                t1 = (t0 + i) % NIB;
                v8 = dut.tbuf0[t1 >> 2][8*(t1 & 3) +: 8];
                if (v8 !== ((i < 5) ? 8'hFF : (i == 5) ? 8'hD5 : (i == 6) ? 8'hAA :
                            (i == 7) ? 8'hAD : 8'h96 + 8'(i - 8)))
                    n_up = n_up + 1;
            end
            if (n_up != 0) begin
                $display("FAIL: phase %0d: %0d of the 20 slots from %0d are not sync, prologue, data in a row", k, n_up, t0);
                errors = errors + 1;
                found = found + 1;
            end
        end
        if (found == 0) $display("  ok: DOS 3.3's 40/36/32 spacing lands sync, prologue and data in a row at all 32 phases");

        $display("\n%0d stores, %0d uploads", dut.wr525, dut.up525);
        if (errors == 0) $display("PASS");
        else $display("FAILED: %0d", errors);
        $finish;
    end
endmodule
