`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// tx_ring_tb - the ring and its arbiter against a Wishbone memory that
// behaves like the DDR3 controller does, but small and fast.
//
// The memory model is pipelined, stalls at random, acks in order after a
// latency, echoes the aux tag, and - the part that matters - APPLIES A WRITE
// ONLY WHEN IT ACKS IT.  So a read issued after a write was accepted but before
// it was acked returns the old line, and the ring's "read only what has been
// acked" rule is the thing under test rather than an assumption.  It also
// checks the two things the real controller is unforgiving about: every write
// is a whole line, and cyc never drops with an ack outstanding.
//
// The ring is built small - 1024 lines - so the pointers wrap many times, and
// the batches, staging and receive depths are shrunk to match.
//
// A random stream of messages goes in with random gaps, comes out through a
// random back pressure, and is checked word for word against what went in,
// with the IDLE padding stripped where - and only where - a message boundary
// allows it.  Then the sink stops until the ring is full and the source is
// stalled, and everything drains in order once it resumes.  Then a reset
// lands mid-stream, and the stream that follows it starts clean.
//////////////////////////////////////////////////////////////////////////////////
module tx_ring_tb;

    localparam integer ADDR_BITS   = 13;          // 1024-line ring
    localparam integer LINES       = 1 << (ADDR_BITS - 3);
    localparam integer BATCH       = 16;
    localparam integer FLUSH_TICKS = 20;
    localparam integer STAGE_DEPTH = 64;
    localparam integer RECV_DEPTH  = 64;
    localparam integer MEM_LAT     = 9;           // accept to ack
    localparam integer DRAIN_TICKS = 300;         // the real one is 100 ms; short here
    localparam integer N_WORDS     = 24000;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    integer errors = 0;

    // ---- the stream, generated up front -----------------------------------
    // Message m: header {m[15:0], 8'h20 + m % 7, len}, payload word k = {1, m, k}.
    // Nothing in it is ever 0x00000000, which is what makes padding
    // recognisable.
    reg [31:0] stream [0:N_WORDS+300];
    reg        is_hdr [0:N_WORDS+300];
    integer    total = 0;

    task gen_stream;
        integer m, k, len, t;
        begin
            m = 0;
            while (total < N_WORDS) begin
                case ($urandom % 5)
                    0:       len = $urandom % 256;
                    1:       len = 255;
                    2:       len = 0;
                    default: len = $urandom % 8;
                endcase
                t = 32 + (m % 7);
                stream[total] = {m[15:0], t[7:0], len[7:0]};
                is_hdr[total] = 1'b1;
                total = total + 1;
                for (k = 0; k < len; k = k + 1) begin
                    stream[total] = {4'h1, m[15:0], k[11:0]};
                    is_hdr[total] = 1'b0;
                    total = total + 1;
                end
                m = m + 1;
            end
        end
    endtask

    // ---- the source -------------------------------------------------------
    integer     si   = 0;          // next word to offer
    integer     stop = 0;          // the tb holding the source off
    reg         gate = 1'b0;       // random gap, changed at negedge
    wire        in_valid = (si < total) && gate && !stop;
    wire [31:0] in_word  = in_valid ? stream[si] : 32'hDEAD_BEEF;
    wire        in_take;

    // The source is a master on the bus through msg_master; here it is the
    // only one, so the arbiter is not needed and the master drives the ring's
    // slave port directly.  `tear` cuts CYC for the guard test at the end.
    reg         tear = 1'b0;
    wire        m_cyc, m_stb, m_we, m_stall, m_ack;
    wire [31:0] m_adr, m_dat;
    wire [3:0]  m_sel;
    msg_master u_m (
        .clk (clk), .rst (rst), .word (in_word), .valid (in_valid), .take (in_take),
        .cyc (m_cyc), .stb (m_stb), .we (m_we), .adr (m_adr), .dat (m_dat), .sel (m_sel),
        .stall (m_stall), .ack (m_ack)
    );

    // ---- the sink ---------------------------------------------------------
    reg         out_take = 1'b0;
    wire [31:0] out_word;
    wire        out_valid;

    // ---- the DUT: ring + arbiter -------------------------------------------
    reg  calib_complete = 1'b0;
    reg  engage         = 1'b0;
    wire [31:0] status;

    wire [1:0]   c_req, c_gnt, c_cyc, c_stb, c_stall, c_ack;
    wire [1:0]   c_we = 2'b10;
    wire [2*ADDR_BITS-1:0] c_addr;
    wire [255:0] c_data;
    wire [127:0] c_rdata;

    wire                 wb_cyc, wb_stb, wb_we, wb_ack;
    reg                  wb_stall = 1'b0;
    wire [ADDR_BITS-1:0] wb_addr;
    wire [127:0]         wb_data;
    wire [15:0]          wb_sel;
    wire [3:0]           wb_aux;
    reg  [127:0]         wb_rdata = '0;
    reg  [3:0]           wb_rdata_aux = '0;

    wb_arb #(.N (2), .ADDR_BITS (ADDR_BITS)) u_arb (
        .clk (clk), .rst (rst), .rot_ok (1'b1),
        .c_req (c_req), .c_gnt (c_gnt), .c_cyc (c_cyc), .c_stb (c_stb),
        .c_we (c_we), .c_addr (c_addr), .c_data (c_data),
        .c_sel ({16'hFFFF, 16'hFFFF}),
        .c_stall (c_stall), .c_ack (c_ack), .c_rdata (c_rdata),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we),
        .wb_addr (wb_addr), .wb_data (wb_data), .wb_sel (wb_sel),
        .wb_aux (wb_aux), .wb_stall (wb_stall), .wb_ack (wb_ack),
        .wb_rdata (wb_rdata), .wb_rdata_aux (wb_rdata_aux)
    );
    assign c_data[127:0] = 128'd0;

    tx_ring #(
        .ADDR_BITS (ADDR_BITS), .BATCH (BATCH), .FLUSH_TICKS (FLUSH_TICKS),
        .STAGE_DEPTH (STAGE_DEPTH), .RECV_DEPTH (RECV_DEPTH),
        .DRAIN_TICKS (DRAIN_TICKS)
    ) dut (
        .clk (clk), .rst (rst), .calib_complete (calib_complete), .engage (engage),
        .s_cyc (m_cyc && !tear), .s_stb (m_stb && !tear), .s_we (m_we), .s_adr (m_adr),
        .s_dat (m_dat), .s_sel (m_sel), .s_stall (m_stall), .s_ack (m_ack),
        .out_word (out_word), .out_valid (out_valid), .out_take (out_take),
        .rd_req (c_req[0]), .rd_gnt (c_gnt[0]), .rd_cyc (c_cyc[0]),
        .rd_stb (c_stb[0]), .rd_addr (c_addr[ADDR_BITS-1:0]),
        .rd_stall (c_stall[0]), .rd_ack (c_ack[0]), .rd_data (c_rdata),
        .wr_req (c_req[1]), .wr_gnt (c_gnt[1]), .wr_cyc (c_cyc[1]),
        .wr_stb (c_stb[1]), .wr_addr (c_addr[2*ADDR_BITS-1:ADDR_BITS]),
        .wr_data (c_data[255:128]),
        .wr_stall (c_stall[1]), .wr_ack (c_ack[1]),
        .status (status)
    );

    // ---- the memory model ---------------------------------------------------
    reg [127:0] mem [0:LINES*8-1];      // the whole 13-bit space, banks and all

    // In-order ack queue.  Each accepted request lands at the tail with the
    // time it may ack; the head acks when its time comes, one per cycle.
    localparam integer QD = 64;
    reg                 q_we   [0:QD-1];
    reg [ADDR_BITS-1:0] q_addr [0:QD-1];
    reg [127:0]         q_data [0:QD-1];
    reg [3:0]           q_aux  [0:QD-1];
    integer             q_due  [0:QD-1];
    integer q_head = 0, q_tail = 0, now = 0;
    integer pending = 0;

    wire accept = wb_cyc && wb_stb && !wb_stall;
    reg  ack_r = 1'b0;
    assign wb_ack = ack_r;

    integer writes = 0, reads = 0;
    reg     swallow = 1'b0;      // drop the acks on the floor, see below
    integer swallowed = 0;

    always @(posedge clk) begin
        now = now + 1;
        // Everything the controller would refuse.
        if (accept && wb_we && wb_sel !== 16'hFFFF) begin
            $display("FAIL: partial write, sel=%04x at %0d", wb_sel, now);
            errors = errors + 1;
        end
        if (!wb_cyc && pending != 0) begin
            $display("FAIL: cyc dropped with %0d ack(s) outstanding at %0d", pending, now);
            errors = errors + 1;
        end
        if (accept) begin
            q_we[q_tail]   = wb_we;
            q_addr[q_tail] = wb_addr;
            q_data[q_tail] = wb_data;
            q_aux[q_tail]  = wb_aux;
            q_due[q_tail]  = now + MEM_LAT;
            q_tail = (q_tail + 1) % QD;
            pending = pending + 1;
        end
        // Ack the head when due.  A write lands in memory HERE, not at
        // accept, so a read that overtakes an unacked write sees stale data.
        ack_r <= 1'b0;
        if (pending != 0 && q_due[q_head] <= now) begin
            if (q_we[q_head]) begin
                mem[q_addr[q_head]] = q_data[q_head];
                wb_rdata <= 128'hBAD0_BAD0_BAD0_BAD0_BAD0_BAD0_BAD0_BAD0;
                writes = writes + 1;
            end else begin
                wb_rdata <= mem[q_addr[q_head]];
                reads = reads + 1;
            end
            wb_rdata_aux <= q_aux[q_head];
            // A LOST ack: the request is consumed - the write lands, CYC is
            // honestly no longer owed anything - and the ack simply never
            // comes.  That is the shape of the wedge the drain's timeout is
            // there for (docs/CLEAN_START.md CS5).
            if (swallow) swallowed = swallowed + 1;
            else         ack_r <= 1'b1;
            q_head = (q_head + 1) % QD;
            pending = pending - 1;
        end
    end

    // ---- the engage's terms, counted while it waits ------------------------
    integer n_wait = 0, n_nocyc = 0, n_dc0 = 0, n_ab = 0, n_both = 0, n_all = 0;
    always @(posedge clk) if (!rst && engage && calib_complete && !dut.engaged) begin
        n_wait = n_wait + 1;
        if (!dut.s_cyc)              n_nocyc = n_nocyc + 1;
        if (dut.direct_count == 0)   n_dc0   = n_dc0 + 1;
        if (dut.at_boundary)         n_ab    = n_ab + 1;
        if (!dut.s_cyc && dut.at_boundary) n_both = n_both + 1;
        if (dut.engage_ok)           n_all   = n_all + 1;
    end

    // ---- the checker --------------------------------------------------------
    integer check_en = 1;
    integer ei    = 0;       // next word expected out
    integer left  = 0;       // payload owed by the current message on the way out
    integer out_n = 0, pads = 0;
    integer in_takes = 0;

    always @(posedge clk) begin
        if (in_valid && in_take) in_takes = in_takes + 1;
        if (!rst && check_en && out_valid && out_take) begin
            out_n = out_n + 1;
            if (out_word == 32'h0000_0000) begin
                // Padding.  Legal only at a boundary.
                pads = pads + 1;
                if (left != 0) begin
                    $display("FAIL: padding inside a message, word %0d, %0d owed", out_n, left);
                    errors = errors + 1;
                end
            end else begin
                if (out_word !== stream[ei]) begin
                    if (errors < 10)
                        $display("FAIL: out word %0d = %08x, expected stream[%0d] = %08x",
                                 out_n, out_word, ei, stream[ei]);
                    errors = errors + 1;
                end
                if (left == 0) left = out_word[7:0];
                else           left = left - 1;
                ei = ei + 1;
            end
        end
    end

    // ---- the source's take ---------------------------------------------------
    always @(posedge clk) if (in_valid && in_take) si <= si + 1;

    // ---- stimulus ------------------------------------------------------------
    integer cycles = 0, stalled_cycles = 0, phase_start;
    integer bidx;

    task run_cycles(input integer n, input integer take_pct, input integer gap_pct);
        integer c;
        begin
            for (c = 0; c < n; c = c + 1) begin
                @(negedge clk);
                cycles   = cycles + 1;
                gate     = ($urandom % 100) < gap_pct;
                out_take = ($urandom % 100) < take_pct;
                wb_stall = ($urandom % 100) < 15;
            end
        end
    endtask

    // Hold the source - at a message boundary, since a source that stops
    // mid-message stalls the stream by design (PROTOCOL.md case 8) - and
    // wait until everything it offered has come out.
    task drain;
        integer c, quiet;
        begin
            while (!is_hdr[si]) begin
                @(negedge clk);
                gate = 1'b1; out_take = 1'b1; wb_stall = ($urandom % 100) < 15;
            end
            stop = 1;
            c = 0; quiet = 0;
            while (quiet < 100 && c < 200000) begin
                @(negedge clk);
                out_take = 1'b1; wb_stall = ($urandom % 100) < 15;
                c = c + 1;
                if (ei == si && !out_valid && status[21:0] == 0) quiet = quiet + 1;
                else                                              quiet = 0;
            end
            stop = 0;
        end
    endtask

    // A deadlock shows as the source stuck; say where everything is and stop.
    initial begin
        #30_000_000;   // the boot-lane phases added a tenth to the run (2026-09-18)
        $display("TIMEOUT: si=%0d ei=%0d out_n=%0d status=%08x in_valid=%b in_take=%b calib=%b",
                 si, ei, out_n, status, in_valid, in_take, calib_complete);
        $display("  req=%b gnt=%b cyc=%b stb=%b stall=%b pending=%0d held=%b holder=%0d",
                 c_req, c_gnt, c_cyc, c_stb, c_stall, pending, u_arb.held, u_arb.holder);
        $display("  wr: busy=%b todo=%0d out=%0d asked=%b pause=%b stage_count=%0d wc=%0d padding=%b left=%0d flush=%0d",
                 dut.wr_busy, dut.wr_todo, dut.wr_out, dut.wr_asked, dut.wr_pause,
                 dut.stage_count, dut.wc, dut.padding, dut.left, dut.flush);
        $display("  rd: busy=%b todo=%0d out=%0d pause=%b recv_count=%0d readable=%0d room=%0d wptr=%0d committed=%0d rptr=%0d",
                 dut.rd_busy, dut.rd_todo, dut.rd_out, dut.rd_pause, dut.recv_count,
                 dut.readable, dut.room, dut.wptr, dut.committed, dut.rptr);
        $display("FAIL: timeout");
        $finish;
    end

    initial begin
        $display("tx_ring_tb: %0d-line ring, batch %0d", LINES, BATCH);
        gen_stream;
        $display("  %0d words in %0d-word stream", total, N_WORDS);
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0;

        // --- phase 0: the boot lane (docs/REQ_65C02.md 1.10) ----------------
        // Uncalibrated and not engaged: words flow, word-exact, through the
        // direct FIFO, and the DDR3 port is never asked for.
        phase_start = si;
        while (si < phase_start + 400) run_cycles(100, 70, 60);
        drain;
        if (in_takes == 0 || out_n == 0) begin
            $display("FAIL: the boot lane carried nothing before calibration (in %0d out %0d)", in_takes, out_n);
            errors = errors + 1;
        end else if (writes != 0 || reads != 0) begin
            $display("FAIL: the DDR3 was touched before calibration (%0d writes, %0d reads)", writes, reads);
            errors = errors + 1;
        end else if (ei != si) begin
            $display("FAIL: boot lane: expected index %0d, source at %0d", ei, si);
            errors = errors + 1;
        end else if (status[23] !== 1'b0) begin
            $display("FAIL: RING_STATUS says engaged before anyone asked");
            errors = errors + 1;
        end else $display("  ok: the boot lane carried %0d words word-exact with the DDR3 uncalibrated and untouched", si - phase_start);

        // Engaged asked for before calibration: the lane stays, the ask waits.
        @(negedge clk); engage = 1'b1;
        phase_start = si;
        while (si < phase_start + 200) run_cycles(100, 70, 60);
        drain;
        if (dut.engaged !== 1'b0 || writes != 0) begin
            $display("FAIL: engaged without calibration (engaged=%b writes=%0d)", dut.engaged, writes);
            errors = errors + 1;
        end else $display("  ok: an engage asked before calibration waits on the lane");

        // Calibrated: the engage takes effect at the first quiet boundary,
        // the order holds across the switch, the status says so, and the
        // traffic after it rides the DDR3.
        @(negedge clk); calib_complete = 1'b1;
        phase_start = si;
        while (si < phase_start + 200) run_cycles(100, 70, 60);
        $display("  engage waited %0d cycles: cyc low %0d, lane empty %0d, boundary %0d, low+boundary %0d, all terms %0d",
                 n_wait, n_nocyc, n_dc0, n_ab, n_both, n_all);
        drain;
        if (dut.engaged !== 1'b1 || status[23] !== 1'b1) begin
            $display("FAIL: not engaged after calibration (engaged=%b status=%08x)", dut.engaged, status);
            errors = errors + 1;
        end
        phase_start = si;
        while (si < phase_start + 400) run_cycles(100, 70, 60);
        drain;
        if (writes == 0) begin
            $display("FAIL: engaged but nothing reached the DDR3 (engaged=%b direct_count=%0d stage_count=%0d wc=%0d wptr=%0d rptr=%0d wr_req=%b out_n=%0d)",
                     dut.engaged, dut.direct_count, dut.stage_count, dut.wc, dut.wptr, dut.rptr, dut.wr_req, out_n);
            errors = errors + 1;
        end else if (ei != si) begin
            $display("FAIL: across the engage expected index %0d, source at %0d", ei, si);
            errors = errors + 1;
        end else $display("  ok: engaged at a boundary, %0d words word-exact across the switch, %0d lines written", si - phase_start, writes);

        // --- phase 1: random everything, through several wraps ---------------
        phase_start = si;
        while (si < 9000) run_cycles(100, 70, 60);
        drain;
        $display("  phase 1: %0d words in, %0d out, %0d padding, %0d writes, %0d reads",
                 si - phase_start, out_n, pads, writes, reads);
        if (ei != si) begin
            $display("FAIL: after phase 1 expected index %0d, source at %0d", ei, si);
            errors = errors + 1;
        end else $display("  ok: phase 1 word-exact through %0d lines of ring", writes);

        // --- phase 1b: sparse traffic, so message tails wait out the flush ----
        // and get padded.  Padding is what a quiet link produces, and the
        // checker only allows it at a boundary.
        phase_start = si;
        while (si < phase_start + 600) run_cycles(100, 90, 4);
        drain;
        if (pads == 0) begin
            $display("FAIL: sparse traffic produced no padding at all");
            errors = errors + 1;
        end else if (ei != si) begin
            $display("FAIL: after the sparse phase expected index %0d, source at %0d", ei, si);
            errors = errors + 1;
        end else $display("  ok: sparse phase word-exact, %0d padding words, all at boundaries", pads);

        // --- phase 2: the sink stops; the ring fills; the source stalls -------
        phase_start = si;
        begin : fill
            integer c;
            c = 0;
            while (!status[24] && c < 100000) begin
                run_cycles(50, 0, 100);
                c = c + 50;
            end
        end
        // Now hold.  The ring is full but the staging FIFO behind it still has
        // room for a few hundred words, so the source stalls a little after
        // the ring does; once it has, it must stay stalled.
        stalled_cycles = 0;
        begin : hold
            integer c;
            for (c = 0; c < 4000; c = c + 1) begin
                @(negedge clk);
                gate = 1'b1; out_take = 1'b0; wb_stall = 1'b0;
                if (c >= 2000 && !in_take) stalled_cycles = stalled_cycles + 1;
            end
        end
        if (!status[24]) begin
            $display("FAIL: ring not reported full with the sink stopped (status %08x)", status);
            errors = errors + 1;
        end else $display("  ok: ring reports full, %0d lines", status[21:0]);
        if (stalled_cycles < 2000) begin
            $display("FAIL: source not held off a full ring (%0d of 2000 cycles)", stalled_cycles);
            errors = errors + 1;
        end else $display("  ok: source held off the full ring");
        drain;
        if (ei != si) begin
            $display("FAIL: after the stall expected index %0d, source at %0d", ei, si);
            errors = errors + 1;
        end else $display("  ok: everything drained in order after the stall, %0d words", out_n);
        if (status[21:0] != 0 || status[24]) begin
            $display("FAIL: ring not empty after drain (status %08x)", status);
            errors = errors + 1;
        end

        // --- phase 3: a reset mid-stream ---------------------------------------
        phase_start = si;
        run_cycles(400, 50, 80);
        @(negedge clk); stop = 1; rst = 1;
        // The next message boundary at or after wherever the source got to.
        bidx = si;
        while (!is_hdr[bidx]) bidx = bidx + 1;
        repeat (120) @(negedge clk);
        // Through the reset the memory saw cyc held for its acks (checked
        // above, every cycle).  Now restart the source at a boundary and the
        // checker with it.
        si   = bidx;
        ei   = bidx;
        left = 0;
        @(negedge clk); rst = 0; stop = 0;
        run_cycles(1500, 60, 60);
        drain;
        if (ei != si) begin
            $display("FAIL: after the reset expected index %0d, source at %0d", ei, si);
            errors = errors + 1;
        end else $display("  ok: the stream after the reset started clean, %0d words", si - bidx);

        // --- phase 3b: a reset too short to outlast the acks in flight --------
        // Three cycles, landing mid-batch: the side that was issuing must keep
        // draining after the reset has let go, count none of the late acks,
        // and start clean.  Without the drain a late write ack would put
        // `committed` past a zeroed `wptr` and the reader would read a line
        // nobody wrote.
        run_cycles(300, 50, 90);
        @(negedge clk);
        while (!(c_stb != 0 && pending != 0)) begin
            @(negedge clk);
            // wb_stall too: left at 1 by whatever ran last, the memory model
            // accepts nothing and this waits for a request in flight forever.
            gate = 1'b1; out_take = ($urandom % 100) < 50;
            wb_stall = ($urandom % 100) < 15;
        end
        stop = 1; rst = 1;
        bidx = si;
        while (!is_hdr[bidx]) bidx = bidx + 1;
        repeat (3) @(negedge clk);
        si   = bidx;
        ei   = bidx;
        left = 0;
        rst = 0; stop = 0;
        if (!dut.drain) begin
            $display("FAIL: no side draining after a reset with %0d ack(s) in flight", pending);
            errors = errors + 1;
        end
        run_cycles(1500, 60, 60);
        drain;
        if (ei != si) begin
            $display("FAIL: after the short reset expected index %0d, source at %0d", ei, si);
            errors = errors + 1;
        end else $display("  ok: a 3-cycle reset mid-batch drained and the stream after it is clean, %0d words", si - bidx);

        // --- phase 3c: an ack that never comes ---------------------------------
        // The drain used to wait for one forever.  A reset that never finished
        // draining left the ring stopped - and every register reply behind it -
        // until the FPGA was configured again, which is exactly the wedge the
        // card is not allowed to have (docs/CLEAN_START.md CS5).  Here the
        // memory model eats a batch's requests and answers none of them: the
        // drain must give up, zero what it was owed, count the timeout, and
        // let the next stream through clean.
        run_cycles(300, 50, 90);
        @(negedge clk);
        while (!(c_stb != 0 && pending != 0)) begin
            @(negedge clk);
            // wb_stall too: left at 1 by whatever ran last, the memory model
            // accepts nothing and this waits for a request in flight forever.
            gate = 1'b1; out_take = ($urandom % 100) < 50;
            wb_stall = ($urandom % 100) < 15;
        end
        swallow = 1'b1;
        stop = 1; rst = 1;
        bidx = si;
        while (!is_hdr[bidx]) bidx = bidx + 1;
        repeat (MEM_LAT * 4) @(negedge clk);     // the model eats them all
        if (swallowed == 0) begin
            $display("FAIL: no ack was actually lost - the case tests nothing");
            errors = errors + 1;
        end
        if (!dut.drain) begin
            $display("FAIL: not draining with %0d lost ack(s) owed", swallowed);
            errors = errors + 1;
        end
        repeat (DRAIN_TICKS + 200) @(negedge clk);
        if (dut.drain) begin
            $display("FAIL: the drain never gave up on a lost ack");
            errors = errors + 1;
        end else $display("  ok: the drain gave up on %0d lost ack(s) after its timeout", swallowed);
        if (dut.wr_out != 0 || dut.rd_out != 0) begin
            $display("FAIL: outstanding counts left at wr=%0d rd=%0d", dut.wr_out, dut.rd_out);
            errors = errors + 1;
        end else $display("  ok: the outstanding counts were zeroed with it");
        if (status[30:27] == 0) begin
            $display("FAIL: the drain timeout is not in the status word (%08x)", status);
            errors = errors + 1;
        end else $display("  ok: %0d drain timeout(s) counted in the status word", status[30:27]);
        swallow = 1'b0;
        si   = bidx;
        ei   = bidx;
        left = 0;
        @(negedge clk); rst = 0; stop = 0;
        run_cycles(1500, 60, 60);
        drain;
        if (ei != si) begin
            $display("FAIL: after the lost ack expected index %0d, source at %0d", ei, si);
            errors = errors + 1;
        end else $display("  ok: the ring came back from a lost ack, %0d words", si - bidx);

        // --- the rest ------------------------------------------------------------
        while (si < total) run_cycles(200, 80, 90);
        drain;
        if (ei != total) begin
            $display("FAIL: %0d of %0d words delivered", ei, total);
            errors = errors + 1;
        end else $display("  ok: the whole stream, %0d words, %0d padding words, %0d lines written",
                          total, pads, writes);
        if (pending != 0) begin
            $display("FAIL: %0d acks outstanding at the end", pending);
            errors = errors + 1;
        end
        if (status[26]) begin
            $display("FAIL: torn flagged with no message torn");
            errors = errors + 1;
        end else $display("  ok: no message torn, none flagged");

        // --- the guard: a master that drops CYC mid-message ---------------------
        // One more message, four words, and CYC cut after two of them.  The
        // stream is wrong from here and the checker is off; the point is the
        // flag.
        check_en = 0;
        stream[total]     = {16'h0FFF, 8'h2A, 8'd3};
        stream[total + 1] = 32'h1FFF_0001;
        stream[total + 2] = 32'h1FFF_0002;
        stream[total + 3] = 32'h1FFF_0003;
        is_hdr[total] = 1'b1; is_hdr[total+1] = 1'b0; is_hdr[total+2] = 1'b0; is_hdr[total+3] = 1'b0;
        total = total + 4;
        gate = 1'b1; out_take = 1'b1; wb_stall = 1'b0;
        while (si < total - 2) @(negedge clk);
        @(negedge clk); tear = 1'b1;
        repeat (2) @(negedge clk);
        tear = 1'b0;
        repeat (50) @(negedge clk);
        if (!status[26]) begin
            $display("FAIL: CYC dropped with payload owed and the guard did not flag it (status %08x)", status);
            errors = errors + 1;
        end else $display("  ok: a CYC dropped mid-message is flagged torn");

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
