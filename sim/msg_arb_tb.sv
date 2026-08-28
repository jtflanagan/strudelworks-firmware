`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// msg_arb_tb - random Wishbone bursts through the message bus, checked word
// for word.
//
// N masters, driven raw by the testbench - not through msg_master, so the
// arbiter is tested on the bus contract alone.  Each holds CYC across a
// message of random length, presents STB with random gaps inside it, and
// drops CYC only after its last ack; the slave stalls at random and acks a
// beat the cycle after taking it.  The checker parses the slave's stream by
// its headers, the way the host does, and asserts:
//
//   - every message comes out whole and in its master's order, word-exact,
//     and no word of one master ever appears inside another's message;
//   - at every message start, no lower-numbered master had CYC asserted
//     (fixed priority, honoured);
//   - a master is never stalled-through - a beat accepted was its own;
//   - every master gets exactly one ack per beat it issued, and none
//     while it is not on the bus;
//   - CYC to the slave drops for at least a cycle between two bursts.
//
// The master's identity rides in the type byte and the message and word
// indices in the payload, so a wrong word says which master, which message
// and which position it came from.
//////////////////////////////////////////////////////////////////////////////////
module msg_arb_tb;

    localparam integer N     = 4;
    localparam integer MSGS  = 80;
    localparam integer W     = 32768;
    localparam [7:0]   TBASE = 8'h20;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    integer errors = 0;

    // ---- the masters' queues -------------------------------------------------
    reg [31:0] q [0:N*W-1];
    integer    qn [0:N-1];       // words queued
    integer    qi [0:N-1];       // next to issue
    integer    qe [0:N-1];       // next expected out
    integer    qm [0:N-1];       // words left in the message being issued (incl. none)
    integer    acks [0:N-1];     // acks received
    integer    issued [0:N-1];   // beats accepted
    integer    pending [0:N-1];  // accepted, not yet acked
    integer    started [0:N-1];  // a header issued in this CYC

    task gen_source(input integer s);
        integer m, k, len, n, t;
        begin
            n = 0;
            for (m = 0; m < MSGS; m = m + 1) begin
                case ($urandom % 4)
                    0:       len = $urandom % 256;
                    1:       len = 0;
                    default: len = $urandom % 8;
                endcase
                t = TBASE + s;
                q[s*W + n] = {m[15:0], t[7:0], len[7:0]};
                n = n + 1;
                for (k = 0; k < len; k = k + 1) begin
                    q[s*W + n] = {s[3:0], m[11:0], k[15:0]};
                    n = n + 1;
                end
            end
            qn[s] = n; qi[s] = 0; qe[s] = 0; qm[s] = 0;
            acks[s] = 0; issued[s] = 0; pending[s] = 0;
        end
    endtask

    // ---- the masters, raw -------------------------------------------------------
    reg  [N-1:0]    m_cyc = '0;
    reg  [N-1:0]    m_stb = '0;
    wire [N-1:0]    m_we  = '1;
    wire [N*32-1:0] m_adr = '0;
    reg  [N*32-1:0] m_dat = '0;
    wire [N*4-1:0]  m_sel = '1;
    wire [N-1:0]    m_stall, m_ack;

    // ---- the slave, played by the tb ----------------------------------------------
    wire        s_cyc, s_stb, s_we;
    wire [31:0] s_adr, s_dat;
    wire [3:0]  s_sel;
    reg         s_stall = 1'b0;
    reg         s_ack   = 1'b0;

    msg_arb #(.N (N)) dut (
        .clk (clk), .rst (rst),
        .m_cyc (m_cyc), .m_stb (m_stb), .m_we (m_we), .m_adr (m_adr),
        .m_dat (m_dat), .m_sel (m_sel), .m_stall (m_stall), .m_ack (m_ack),
        .s_cyc (s_cyc), .s_stb (s_stb), .s_we (s_we), .s_adr (s_adr),
        .s_dat (s_dat), .s_sel (s_sel), .s_stall (s_stall), .s_ack (s_ack)
    );

    wire s_accept = s_cyc && s_stb && !s_stall;

    // ---- the checker ---------------------------------------------------------------
    integer left = 0, cur = -1, out_n = 0, starts = 0, s, j;
    integer s_cyc_was = 0, bubbles = 0, low_since_hdr = 1, prev_master = -1, dbg = 0;

    always @(posedge clk) begin
        s_ack <= !rst && s_accept;
        if (!rst) begin
            // CYC drops between bursts.
            if (s_cyc && !s_cyc_was) bubbles = bubbles + 1;
            if (!s_cyc) low_since_hdr = 1;
            s_cyc_was = s_cyc;

            // Priority is decided at the GRANT - the cycle the bus goes from
            // idle to held - not at the header beat: a lower master raising
            // CYC after the grant waits, which is the bus contract.
            if (dut.granted && !dut.held) begin
                for (j = 0; j < dut.sel; j = j + 1) if (m_cyc[j]) begin
                    $display("FAIL: master %0d granted while master %0d had CYC up", dut.sel, j);
                    errors = errors + 1;
                end
            end

            if (s_accept) begin
                if (left == 0) begin
                    cur = s_dat[15:8] - TBASE;
                    starts = starts + 1;
                    low_since_hdr = 0;
                    prev_master = cur;
                    if (cur < 0 || cur >= N) begin
                        $display("FAIL: word %0d = %08x is not a header of any master", out_n, s_dat);
                        errors = errors + 1; cur = 0;
                    end
                    left = s_dat[7:0];
                end else left = left - 1;
                if (s_dat !== q[cur*W + qe[cur]]) begin
                    if (errors < 10)
                        $display("FAIL: out word %0d = %08x, expected %08x (master %0d, index %0d)",
                                 out_n, s_dat, q[cur*W + qe[cur]], cur, qe[cur]);
                    errors = errors + 1;
                end
                qe[cur] = qe[cur] + 1;
                out_n = out_n + 1;
            end

            // Each master: its accepted beats, and its acks.
            for (s = 0; s < N; s = s + 1) begin
                if (m_cyc[s] && m_stb[s] && !m_stall[s]) begin
                    issued[s] = issued[s] + 1;
                    pending[s] = pending[s] + 1;
                    qi[s] = qi[s] + 1;
                    if (qm[s] == 0) begin
                        qm[s] = q[s*W + qi[s] - 1][7:0];   // header: payload owed
                        started[s] = 1;                    // one message per CYC
                    end else qm[s] = qm[s] - 1;
                end
                if (!m_cyc[s]) started[s] = 0;
                if (m_ack[s]) begin
                    acks[s] = acks[s] + 1;
                    pending[s] = pending[s] - 1;
                    if (!m_cyc[s]) begin
                        $display("FAIL: master %0d acked while off the bus", s);
                        errors = errors + 1;
                    end
                end
            end
        end
    end

    // Drive the masters at negedge from what the posedge established.
    reg [N-1:0] gate = '0;
    always @(negedge clk) if (!rst) begin
        for (s = 0; s < N; s = s + 1) begin
            gate[s] = ($urandom % 4) != 0;
            if (!m_cyc[s]) begin
                // Start a message when there is one and the coin says so.
                if (qi[s] < qn[s] && gate[s]) begin
                    m_cyc[s] = 1'b1;
                end
                m_stb[s] = 1'b0;
            end else begin
                // In a burst: more words to issue?  The message ends when the
                // header's payload is delivered; qm tracks it.
                if (qi[s] < qn[s] && (qm[s] != 0 || is_hdr_next(s))) begin
                    m_stb[s] = gate[s];
                end else begin
                    m_stb[s] = 1'b0;
                    if (pending[s] == 0) m_cyc[s] = 1'b0;
                end
            end
            m_dat[s*32 +: 32] = (qi[s] < qn[s]) ? q[s*W + qi[s]] : 32'hDEAD_BEEF;
        end
        s_stall = ($urandom % 4) == 0;
    end

    // The next word is a header only if the current message is complete AND
    // this burst has not yet started one: a burst carries exactly one message.
    function is_hdr_next(input integer s);
        is_hdr_next = (qm[s] == 0) && (started[s] == 0);
    endfunction
    // started[s]: a header has been issued in this CYC - kept in the same
    // block as qm, in order, so the two cannot disagree at an edge.

    // ---- stimulus ----------------------------------------------------------------
    integer total = 0, cycles = 0, done;
    initial begin
        $display("msg_arb_tb: N=%0d Wishbone masters, %0d messages each", N, MSGS);
        for (s = 0; s < N; s = s + 1) begin gen_source(s); started[s] = 0; total = total + qn[s]; end
        $display("  %0d words queued in all", total);
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0;

        done = 0;
        while (!done && cycles < 60 * total) begin
            @(posedge clk); cycles = cycles + 1;
            done = 1;
            for (s = 0; s < N; s = s + 1) if (qi[s] < qn[s] || m_cyc[s]) done = 0;
        end
        repeat (10) @(posedge clk);

        if (!done) begin $display("FAIL: masters did not drain in %0d cycles", cycles); errors = errors + 1; end
        if (out_n !== total) begin
            $display("FAIL: %0d words out, %0d offered", out_n, total); errors = errors + 1;
        end else $display("  ok: every word issued came out, %0d in %0d cycles", out_n, cycles);
        for (s = 0; s < N; s = s + 1) begin
            if (qe[s] !== qn[s]) begin $display("FAIL: master %0d: %0d of %0d words delivered", s, qe[s], qn[s]); errors = errors + 1; end
            if (acks[s] !== issued[s] || issued[s] !== qn[s]) begin
                $display("FAIL: master %0d: %0d issued, %0d acked, %0d queued", s, issued[s], acks[s], qn[s]); errors = errors + 1;
            end
        end
        if (left !== 0) begin $display("FAIL: stream ended mid-message"); errors = errors + 1; end
        if (starts !== N * MSGS) begin
            $display("FAIL: %0d messages seen, %0d sent", starts, N * MSGS); errors = errors + 1;
        end else $display("  ok: %0d messages, each whole, in each master's order, priority honoured", starts);
        if (bubbles !== N * MSGS) begin
            $display("FAIL: %0d CYC rises at the slave for %0d bursts - bursts ran together", bubbles, N * MSGS);
            errors = errors + 1;
        end else $display("  ok: every burst reached the slave under its own CYC");
        if (s_cyc) begin $display("FAIL: s_cyc high with every master idle"); errors = errors + 1; end

        if (errors == 0) $display("PASS"); else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
