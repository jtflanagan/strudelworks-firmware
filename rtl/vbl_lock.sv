`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// vbl_lock - find the Apple's video scanner on the floating bus, and follow it
// from then on.
//
// WHAT THIS IS FOR.  Everything that wants to know where the beam is - the
// host framing its picture on the machine's frames, an interrupt at vertical
// blanking for a machine that has none, a beam-racing diagnostic - wants one
// number: which cycle of which line the scanner is on, now, to the cycle.
// The //e's $C019 says only "blanking or not", the ][ and ][+ say nothing,
// and each later machine says it differently.  The FLOATING BUS is the same
// on all of them: while phi0 is low the scanner reads a byte of display
// memory, and a read of an address nothing drives - a video soft switch -
// returns that byte, still on the bus.  Software has found the beam that way
// since 1982 ("vapor lock"), reading once every seven cycles or so and
// narrowing in over several frames.  This card is the machine's CPU
// (docs/BUS_MASTER.md) and can read the floating bus on EVERY cycle, so it
// gets the scanner's whole frame back as a byte stream and finds the origin
// on the first pass through it.  docs/VBL.md is the design.
//
// WHEN.  During the boot hold only (docs/BOOT_MENU.md): the machine is parked
// at its reset vector about to cold boot, its ROM about to clear the text
// page this writes.  A running program's memory is not the card's to write,
// so a start from the runtime hold is refused.  And nothing here ever costs
// a running machine a cycle: once the counter is set it only listens.
//
// THE SEQUENCE, all by override cycles (rtl/apple_bus_write.sv):
//
//   SWITCH   seven soft-switch accesses: 40-column text, page 1, main memory
//   FILL     960 writes: row r of the text page becomes $C1+r, 'A' to 'X';
//            the eight screen holes in each stride are not touched
//   ACQ      read $C054 every cycle.  32 x 'H' then a 'Q' is the last
//            blanking line's tail meeting line 0's head - unique in the frame
//            - and the 129 bytes after it are checked against the scanner
//            model started at line 0, cycle 0, holes excepted
//   PERIOD   keep reading and counting.  Lines 0 and 1 again at cycle 17030
//            means 262 lines (NTSC); at 20280, 312 (PAL).  Then the counter
//            is SET.
//   VERIFY   one whole frame against the model, counting mismatches on every
//            non-hole cycle: the number that says how well the model fits
//            this machine.  The lock does not depend on it.
//
// THE MODEL is Sather's (Understanding the Apple II, ch. 5) as AppleWin's
// VideoGetScannerAddress writes it: the address is a function of a
// horizontal state H and a vertical state V, and bits A3-A6 are a SUM of
// bits from both, which is what makes blanking cycles read another row's
// tail.  scan_addr below is that formula; sim/vbl_lock_tb.sv derives the
// same addresses from the counters themselves, independently.
//
// THE COUNTER ticks on every phi0 cycle - `tick` is the reader's data
// sample, whether or not anyone is capturing or mastering - and is in the
// card's reset domain, not the machine's: the scanner has been free-running
// since power-on and RES' does not touch it, so neither does it touch this.
// A second detection on a locked counter reports the SLIP between the old
// count and the new lock; zero is the expectation.
//
// THE ORIGIN is line 0, cycle 0: the first blanking cycle of the first
// displayed line.  `mark` is raised with the tick of that cycle - while the
// host has asked (`notify`) - and rtl/bus_event_capture.sv cuts its message
// there, so the VBL_MARK notice sits in the stream exactly between the last
// event of one frame and the first of the next.
//
// THE PROBE reads any address for exactly one frame, for the host: with the
// marks on, every byte of the run has a line and a cycle.  $C019 on a //e
// is the machine's own VBL' in bit 7, and where it falls against this
// module's origin is the measurement that checks the model against
// something it was not derived from.
//////////////////////////////////////////////////////////////////////////////////
module vbl_lock #(
    // Bus cycles the acquisition may search before giving up: two PAL frames
    // and change.  A testbench does not need to shorten it.
    parameter integer ACQ_TIMEOUT = 41_000,
    // Row r of the text page is filled with ROW_BASE + r.  $C1 puts 'A' on
    // row 0 and 'X' on row 23, so a monitor on the Apple shows the fill.
    parameter [7:0]   ROW_BASE    = 8'hC1
) (
    input  wire        clk,
    // The CARD's reset.  Not the core's: the lock outlives a Ctrl-Reset.
    input  wire        rst,

    // 1 while the soft core owns the bus.  Nothing here can run otherwise.
    input  wire        master_active,
    // The hold, and which door (rtl/boot_hold.sv).  Only the boot door
    // qualifies; a hold that drops mid-run aborts the run.
    input  wire        held,
    input  wire        runtime,

    // One pulse per phi0 cycle at the data sample (apple_bus_read's
    // data_tick), whether or not mastering.  The counter's clock.
    input  wire        tick,

    // The presented op, from apple_bus_write: op_present announces it,
    // op_ovr says it was an override; din is the byte the bus returned,
    // valid at tick while mastering.
    input  wire        op_present,
    input  wire        op_ovr,
    input  wire [15:0] op_addr,
    input  wire        op_rw,
    input  wire [7:0]  din,

    // From VBL_CTRL: start and probe are pulses, notify a level, probe_addr
    // the address a probe reads.
    input  wire        start,
    input  wire        probe,
    input  wire [15:0] probe_addr,
    input  wire        notify,

    // To apple_bus_write, through master_top's mux: above the hold's
    // keyboard reads, below the disk's DMA.
    output wire        ovr_en,
    output logic [15:0] ovr_addr,
    output logic       ovr_rw,
    output logic [7:0] ovr_wdata,

    // With tick: the cycle whose event goes out on this clock is line 0,
    // cycle 0.  For the capture's cut.  mark_free rides in the notice.
    output wire        mark,
    output wire [15:0] mark_free,

    // For the registers.
    output wire [3:0]  state,
    output logic       locked,
    output logic       pal,
    output wire        busy,
    output logic [3:0] err,
    output logic [15:0] mismatches,
    output logic [15:0] slip,
    output wire [14:0] pos,
    output logic [7:0] frames,
    output logic [7:0] locks
);

    // ---- the scanner model ------------------------------------------------
    // Text mode, 40 columns, page 1.  `line` is 0..lines-1, `hc` 0..64 with
    // 0..24 the horizontal blanking; `lines` is 262 or 312.  The V state is
    // $100 + line until the vertical preset at line 256 takes it to $FA
    // (NTSC) or $C8 (PAL); the H state is $00 for the first blanking cycle,
    // $40-$57 for the rest, $58-$7F for the forty displayed - and AppleWin
    // keeps only its low six bits, which is all the address uses, so from
    // the second cycle of a line on the state is simply hc - 1.
    //
    // The testbench's counters caught the first cut of this reading $18 as
    // eighteen: the displayed columns were six states early, the
    // acquisition still passed - the shifted cycles fell on holes and on
    // bytes of the same letter - and only the verify frame said so.
    function automatic [15:0] scan_addr(input [8:0] line, input [6:0] hc, input [8:0] lines);
        logic [8:0] vs;
        logic [5:0] h6;
        logic [4:0] sum;
        begin
            vs = (line < 9'd256) ? (line | 9'h100) : (line + 9'd256 - lines);
            h6 = (hc == 7'd0) ? 6'd0 : 6'(hc - 7'd1);
            // A3-A6: H5 H4 H3 + V4 V3 V4 V3 + 1101, kept to four bits.
            sum = {2'b00, h6[5:3]} + {1'b0, vs[7:6], 2'b00} + {3'b000, vs[7:6]} + 5'd13;
            scan_addr = {6'b000001, vs[5:3], sum[3:0], h6[2:0]};
        end
    endfunction

    // What the fill put at a text-page address: the row's byte.  Rows are
    // 8*group + stride, the group by where in the 128-byte stride the
    // address falls.
    function automatic [7:0] pat(input [15:0] a);
        logic [1:0] g;
        begin
            g   = (a[6:0] < 7'h28) ? 2'd0 : (a[6:0] < 7'h50) ? 2'd1 : 2'd2;
            pat = ROW_BASE + {3'b000, g, a[9:7]};
        end
    endfunction

    // The screen holes: eight bytes at the top of every stride, not ours.
    function automatic hole(input [15:0] a);
        hole = (a[6:0] >= 7'h78);
    endfunction

    localparam [7:0]  ROW7   = ROW_BASE + 8'd7;    // 'H'
    localparam [7:0]  ROW16  = ROW_BASE + 8'd16;   // 'Q'
    localparam [15:0] PROBE  = 16'hC054;           // PAGE2 off: what we want anyway
    localparam [8:0]  NTSC_LINES = 9'd262;
    localparam [8:0]  PAL_LINES  = 9'd312;
    localparam [14:0] NTSC_CYC   = 15'd17030;
    localparam [14:0] PAL_CYC    = 15'd20280;

    // ---- state -----------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE   = 4'd0,
        S_SWITCH = 4'd1,
        S_FILL   = 4'd2,
        S_ACQ    = 4'd3,
        S_PERIOD = 4'd4,
        S_VERIFY = 4'd5,
        S_PROBE  = 4'd7
    } state_t;

    state_t st;
    assign state  = st;
    assign busy   = (st != S_IDLE);
    assign ovr_en = (st != S_IDLE);

    wire eligible = master_active && held && !runtime;

    // ---- the live counter ---------------------------------------------------
    logic [8:0]  v;         // line
    logic [6:0]  h;         // cycle within it
    logic [14:0] fc;        // cycle within the frame
    logic [8:0]  lines;
    wire  [14:0] period = pal ? PAL_CYC : NTSC_CYC;

    wire at_end   = (h == 7'd64) && (v == lines - 9'd1);
    wire [14:0] fc_next = at_end ? 15'd0 : fc + 15'd1;

    assign pos       = fc;
    assign mark      = tick && locked && notify && (v == 9'd0) && (h == 7'd0);
    assign mark_free = {frames, 7'd0, pal};

    // ---- the op in flight ----------------------------------------------------
    logic [2:0]  seq;       // which switch
    logic [9:0]  fa;        // fill offset into the page
    logic [15:0] paddr;     // the probe's address, latched at its start
    logic [14:0] pcnt;      // probe reads presented

    always_comb begin
        ovr_rw    = 1'b1;
        ovr_addr  = PROBE;
        ovr_wdata = 8'd0;
        case (st)
            S_SWITCH: begin
                case (seq)
                    3'd0: begin ovr_rw = 1'b0; ovr_addr = 16'hC000; end   // 80STORE off
                    3'd1: begin ovr_rw = 1'b0; ovr_addr = 16'hC004; end   // RAMWRT off
                    3'd2: begin ovr_rw = 1'b0; ovr_addr = 16'hC00C; end   // 80COL off
                    3'd3: ovr_addr = 16'hC051;                            // TEXT on
                    3'd4: ovr_addr = 16'hC052;                            // MIXED off
                    3'd5: ovr_addr = 16'hC054;                            // PAGE2 off
                    default: ovr_addr = 16'hC056;                         // HIRES off
                endcase
            end
            S_FILL: begin
                ovr_rw    = 1'b0;
                ovr_addr  = {6'b000001, fa};
                ovr_wdata = pat({6'b000001, fa});
            end
            S_PROBE: ovr_addr = paddr;
            default: ;
        endcase
    end

    // The driver latched what we were offering: the op is ours.
    wire mine = op_present && op_ovr && (op_addr == ovr_addr) && (op_rw == ovr_rw);
    // ...and it was a probe read, whose byte at tick is for the matcher.
    wire probing = (st == S_ACQ) || (st == S_PERIOD) || (st == S_VERIFY);
    logic cur_probe;

    // ---- acquisition ---------------------------------------------------------
    logic [5:0]  r7;        // consecutive 'H's, saturating
    logic        cand;      // a candidate origin is being checked
    logic [8:0]  cl;        // the candidate's line, counting past 262 and 312
    logic [6:0]  ch;
    logic        ntsc_failed;
    logic [15:0] acq_cnt;
    logic [14:0] vcnt;      // verify cycles done

    // The byte the model expects for the candidate's position: in PERIOD the
    // line is taken from the hypothesis's origin.
    wire [8:0]  c_base = (st == S_PERIOD) ? ((cl >= PAL_LINES) ? PAL_LINES : NTSC_LINES) : 9'd0;
    wire [8:0]  c_line = cl - c_base;
    wire [15:0] c_addr = scan_addr(c_line, ch, NTSC_LINES);   // lines only matter past 255
    wire [7:0]  c_exp  = pat(c_addr);
    wire        c_hole = hole(c_addr);
    wire        c_ok   = cur_probe && (c_hole || (din == c_exp));
    // A period window is open: two lines from the hypothesised origin.
    wire in_ntsc = (st == S_PERIOD) && !ntsc_failed && (cl >= NTSC_LINES) && (cl < NTSC_LINES + 9'd2);
    wire in_pal  = (st == S_PERIOD) && (cl >= PAL_LINES) && (cl < PAL_LINES + 9'd2);
    wire win_end = (c_line == 9'd1) && (ch == 7'd64);

    // ...and for the live counter, in VERIFY.
    wire [15:0] l_addr = scan_addr(v, h, lines);
    wire        l_ok   = cur_probe && (hole(l_addr) || (din == pat(l_addr)));

    always_ff @(posedge clk) begin
        if (rst) begin
            st          <= S_IDLE;
            locked      <= 1'b0;
            pal         <= 1'b0;
            err         <= 4'd0;
            mismatches  <= 16'd0;
            slip        <= 16'd0;
            frames      <= 8'd0;
            locks       <= 8'd0;
            v           <= 9'd0;
            h           <= 7'd0;
            fc          <= 15'd0;
            lines       <= NTSC_LINES;
            seq         <= 3'd0;
            fa          <= 10'd0;
            paddr       <= 16'd0;
            pcnt        <= 15'd0;
            cur_probe   <= 1'b0;
            r7          <= 6'd0;
            cand        <= 1'b0;
            cl          <= 9'd0;
            ch          <= 7'd0;
            ntsc_failed <= 1'b0;
            acq_cnt     <= 16'd0;
            vcnt        <= 15'd0;
        end else begin
            if (op_present) cur_probe <= mine && probing;

            // The counter, first: every later assignment to it wins.
            if (tick && locked) begin
                if (h == 7'd64) begin
                    h <= 7'd0;
                    if (v == lines - 9'd1) begin
                        v      <= 9'd0;
                        frames <= frames + 8'd1;
                    end else begin
                        v <= v + 9'd1;
                    end
                end else begin
                    h <= h + 7'd1;
                end
                fc <= fc_next;
            end

            if (busy && !eligible) begin
                // The hold dropped - a reset bounce, or the host let go -
                // or the bus went back to the native CPU.  Whatever was
                // running is over; the lock, if any, stands.
                st  <= S_IDLE;
                err <= 4'd4;
            end else begin
                case (st)
                    S_IDLE: begin
                        if (start) begin
                            if (eligible) begin
                                st  <= S_SWITCH;
                                seq <= 3'd0;
                                err <= 4'd0;
                            end else begin
                                err <= 4'd1;
                            end
                        end else if (probe) begin
                            if (eligible && locked) begin
                                st    <= S_PROBE;
                                paddr <= probe_addr;
                                pcnt  <= 15'd0;
                                err   <= 4'd0;
                            end else begin
                                err <= 4'd5;
                            end
                        end
                    end

                    S_SWITCH: begin
                        if (mine) begin
                            seq <= seq + 3'd1;
                            if (seq == 3'd6) begin
                                st <= S_FILL;
                                fa <= 10'd0;
                            end
                        end
                    end

                    S_FILL: begin
                        if (mine) begin
                            // Over the holes: $x77 steps to $x80.
                            fa <= (fa[6:0] == 7'h77) ? fa + 10'd9 : fa + 10'd1;
                            if (fa == 10'h3F7) begin
                                st      <= S_ACQ;
                                r7      <= 6'd0;
                                cand    <= 1'b0;
                                acq_cnt <= 16'd0;
                            end
                        end
                    end

                    S_ACQ: begin
                        if (tick) begin
                            acq_cnt <= acq_cnt + 16'd1;
                            if (acq_cnt == ACQ_TIMEOUT[15:0]) begin
                                st  <= S_IDLE;
                                err <= 4'd2;
                            end else if (!cur_probe) begin
                                // Not our byte: whatever run there was is broken.
                                r7   <= 6'd0;
                                cand <= 1'b0;
                            end else if (!cand) begin
                                if ((din == ROW16) && (r7 >= 6'd32)) begin
                                    // This byte is line 0, cycle 0; the next is (0, 1).
                                    cand <= 1'b1;
                                    cl   <= 9'd0;
                                    ch   <= 7'd1;
                                    r7   <= 6'd0;
                                end else if (din == ROW7) begin
                                    if (r7 != 6'd63) r7 <= r7 + 6'd1;
                                end else begin
                                    r7 <= 6'd0;
                                end
                            end else begin
                                if (!c_ok) begin
                                    cand <= 1'b0;
                                    r7   <= (din == ROW7) ? 6'd1 : 6'd0;
                                end else begin
                                    if (ch == 7'd64) begin ch <= 7'd0; cl <= cl + 9'd1; end
                                    else                   ch <= ch + 7'd1;
                                    if (win_end) begin
                                        st          <= S_PERIOD;
                                        ntsc_failed <= 1'b0;
                                    end
                                end
                            end
                        end
                    end

                    S_PERIOD: begin
                        if (tick) begin
                            if (ch == 7'd64) begin ch <= 7'd0; cl <= cl + 9'd1; end
                            else                   ch <= ch + 7'd1;
                            if (in_ntsc && !c_ok) begin
                                ntsc_failed <= 1'b1;
                            end else if (in_pal && !c_ok) begin
                                st  <= S_IDLE;
                                err <= 4'd3;
                            end else if ((in_ntsc || in_pal) && win_end) begin
                                // Lines 0 and 1 again, one period on: the
                                // next cycle is line 2, cycle 0 of a frame
                                // whose length is now known.
                                slip       <= locked ? (16'(fc_next) - 16'd130) : 16'd0;
                                v          <= 9'd2;
                                h          <= 7'd0;
                                fc         <= 15'd130;
                                lines      <= in_pal ? PAL_LINES : NTSC_LINES;
                                pal        <= in_pal;
                                locked     <= 1'b1;
                                locks      <= locks + 8'd1;
                                mismatches <= 16'd0;
                                vcnt       <= 15'd0;
                                st         <= S_VERIFY;
                            end else if (cl == PAL_LINES + 9'd2) begin
                                st  <= S_IDLE;
                                err <= 4'd3;
                            end
                        end
                    end

                    S_VERIFY: begin
                        if (tick) begin
                            if (!l_ok && mismatches != 16'hFFFF) mismatches <= mismatches + 16'd1;
                            vcnt <= vcnt + 15'd1;
                            if (vcnt == period - 15'd1) st <= S_IDLE;
                        end
                    end

                    S_PROBE: begin
                        if (mine) begin
                            pcnt <= pcnt + 15'd1;
                            if (pcnt == period - 15'd1) st <= S_IDLE;
                        end
                    end

                    default: st <= S_IDLE;
                endcase
            end
        end
    end

endmodule
