// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// no_slot_clock - a Dallas DS1216 "No-Slot Clock" under the IIe's CD ROM, with
// the host's clock behind it.  docs/NSC.md.
//
// The real part sits between the ROM and its socket and watches the ROM's
// chip enable, A0, A2 and R/W.  A program talks to it through ordinary reads
// of the ROM: a read with A2 high resets the comparison; 64 accesses with A2
// low clock the bit on A0 into a 64-bit comparison register; when those 64
// bits are the key $5CA33AC55CA33AC5 (LSB first) the clock register is
// filled with the time and the next 64 reads with A2 high return it, one bit
// a read on D0, LSB first - centiseconds, seconds, minutes, hours, day of
// week, date, month, year, a packed-BCD byte each.  64 accesses with A2 low
// during that window would SET the clock; here they are counted and ignored
// - the time is the host's, which is the Pi's, which is NTP's, and a program
// that sets it changes nothing (the user's rule).  AppleWin's
// NoSlotClock.cpp (the project's reference) is the model followed, rule for
// rule; the one departure is where the clock listens (below).
//
// WHERE IT LISTENS.  Any access, read or write, whose address is in the
// internal ROM's $C3 page while that page is the internal ROM's (INTCXROM
// set, or SLOTC3ROM clear) or in its $C8 page while the internal ROM is
// there (INTCXROM or INTC8ROM) - the two pages AppleWin models, but taken
// from rtl/apple_mmu.sv's own map (q_nsc), so the $C8 case includes the
// INTC8ROM latch AppleWin's test leaves out: with it set the internal ROM
// IS at $C800, and a real part under the CD ROM sees the access.  A fetch
// is not an access: AppleWin runs fetches past its I/O handlers, and the
// 80-column firmware lives in this very page.
//
// WHERE IT ACTS.  Nowhere on the bus.  In mode 0 the motherboard's ROM
// answers the read on the bus exactly as before; the card only substitutes
// D0 of what the SOFT CORE receives (master_top's cpu_din), which a real
// part does by hiding the ROM for the read.  Under acceleration the read is
// a fast op served from the card's ROM image, and the same substitution
// applies to that byte.  Either way the state machine steps once per access
// at the op's commit on the unified stream - the driver's commit for a bus
// op, the sequencer's tick for a fast op.
//
// ACROSS CLOCKS.  The substitute (sub/bit) is a pair of flops: the address
// the core has up is stable from the clock after it moved until it moves
// again, so a one-clock-late verdict is never seen - the core takes a byte
// no sooner than three clocks after it presented (accel_seq settled +
// dispatch + the cache's serve; a bus cycle is ten) - and the state moves at
// the commit, two clocks before the next op's earliest byte.  bit is the
// ring's current bit, registered, so the 64:1 mux is behind a flop and
// the din path gains one LUT on D0 alone.
//
// THE TIME.  NSC_TIME messages (type 0x27, two words: the register's low
// half then its high) land in now_q, taken whole at the second word so an
// unlock never sees half an update.  The host sends one every centisecond;
// the card keeps no time of its own.  Until the first message the clock
// never unlocks - a driver finds no clock rather than year 00 - and the
// lever (enable, NSC_CTRL[0]) has the same effect and resets the comparison.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module no_slot_clock #(
    parameter [7:0] T_NSC_TIME = 8'h27
) (
    input  wire        clk,
    input  wire        rst,

    // The lever: NSC_CTRL[0].  Off, no access is seen and nothing is served.
    input  wire        enable,

    // The live question, for the substitute: is the core's address one the
    // clock listens at (apple_mmu q_nsc, on nxt_addr), the op's rw, its A2,
    // and whether an override (a hold's or the disk's cycle) owns the
    // address instead of the core.
    input  wire        q_nsc,
    input  wire        q_rw,
    input  wire        q_a2,
    input  wire        ovr_en,

    // The unified op stream (accel_seq u_*): the op's present, to capture
    // whether it is the clock's, and the commit that steps the state.
    input  wire        u_present,
    input  wire        u_ovr,
    input  wire [2:0]  u_addr_lo,
    input  wire        commit,

    // Host -> card messages, as rtl/ft601_msg_rx.sv presents them.
    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    input  wire [7:0]  msg_len,
    input  wire [31:0] pay_data,
    input  wire        pay_valid,

    // The substitute: D0 of the core's byte is `sub_bit` while `sub`.
    output logic       sub,
    output logic       sub_bit,

    // For NSC_CTRL's readback (rtl/wb_regfile.sv) and the two time words.
    output wire        time_loaded,
    output wire        ring_en_o,
    output wire        wr_en_o,
    output wire [5:0]  cmp_idx_o,
    output wire [5:0]  ring_idx_o,
    output wire [7:0]  unlocks_o,
    output wire [63:0] now_o
);

    // Nick Westgate's kClockInitSequence, compared LSB first.
    localparam [63:0] KEY = 64'h5CA33AC55CA33AC5;

    // ---- the host's time ----------------------------------------------------
    logic [63:0] now_q;
    logic [31:0] now_lo;
    logic        loaded;
    logic [7:0]  rx_type, rx_left, rx_idx;
    wire rx_hdr  = msg_valid;
    wire rx_word = pay_valid && (rx_left != 8'd0);
    wire hdr_time  = rx_hdr && (msg_type == T_NSC_TIME);
    wire word_time = rx_word && (rx_type == T_NSC_TIME);
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_type <= 8'd0; rx_left <= 8'd0; rx_idx <= 8'd0;
            now_q   <= 64'd0; now_lo <= 32'd0; loaded <= 1'b0;
        end else begin
            if (rx_hdr) begin
                rx_type <= (hdr_time && msg_len == 8'd2) ? msg_type : 8'd0;
                rx_left <= msg_len;
                rx_idx  <= 8'd0;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;
                if (word_time) begin
                    if (rx_idx == 8'd0) now_lo <= pay_data;
                    else begin
                        now_q  <= {pay_data, now_lo};
                        loaded <= 1'b1;
                    end
                end
            end
        end
    end
    assign time_loaded = loaded;
    assign now_o       = now_q;

    // ---- the part ------------------------------------------------------------
    // AppleWin's CNoSlotClock: m_bClockRegisterEnabled (ring_en),
    // m_bWriteEnabled (wr_en), the comparison register's mask (cmp_idx) and
    // the clock register with its mask (ring, ring_idx).
    logic        ring_en, wr_en;
    logic [5:0]  cmp_idx, ring_idx;
    logic [63:0] ring;
    logic [7:0]  unlocks;
    logic        elig_u;             // the op on the stream is the clock's

    wire on = enable && loaded;

    // The op's eligibility, captured at its present: the live map's answer
    // for the address the core has up, which is this op's (header).
    always_ff @(posedge clk) begin
        if (rst || !on)        elig_u <= 1'b0;
        else if (u_present)    elig_u <= q_nsc && !u_ovr && !ovr_en;
    end

    wire step = commit && elig_u && on;
    wire a2   = u_addr_lo[2];
    wire a0   = u_addr_lo[0];

    always_ff @(posedge clk) begin
        if (rst || !on) begin
            // The part's power-on: comparison reset, writes enabled, no
            // clock register up (Reset() - a power cycle, not RES').
            ring_en  <= 1'b0;
            wr_en    <= 1'b1;
            cmp_idx  <= 6'd0;
            ring_idx <= 6'd0;
            ring     <= 64'd0;
            unlocks  <= 8'd0;
        end else if (step) begin
            if (!ring_en) begin
                if (a2) begin
                    // ClockRead while not enabled: the comparison starts
                    // over and writes are enabled again.
                    cmp_idx <= 6'd0;
                    wr_en   <= 1'b1;
                end else if (wr_en) begin
                    // ClockWrite: one more bit of the key on A0.
                    if (KEY[cmp_idx] == a0) begin
                        if (cmp_idx == 6'd63) begin
                            ring_en  <= 1'b1;
                            ring     <= now_q;      // PopulateClockRegister
                            ring_idx <= 6'd0;
                            cmp_idx  <= 6'd0;
                            unlocks  <= unlocks + 8'd1;
                        end else begin
                            cmp_idx <= cmp_idx + 6'd1;
                        end
                    end else begin
                        // A mismatch ignores further writes until a read
                        // with A2 resets the comparison.
                        wr_en <= 1'b0;
                    end
                end
            end else begin
                // Enabled: a read with A2 gave out ring[ring_idx]; a write
                // (A2 low) would set the clock and is simulated as
                // AppleWin does - counted, the register read-only.  Either
                // way the mask advances; the wrap ends the window.
                if (ring_idx == 6'd63) begin
                    ring_en  <= 1'b0;
                    ring_idx <= 6'd0;
                end else begin
                    ring_idx <= ring_idx + 6'd1;
                end
            end
        end
    end

    // ---- the substitute -------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            sub <= 1'b0;
            sub_bit <= 1'b0;
        end else begin
            sub <= on && ring_en && q_nsc && q_rw && q_a2 && !ovr_en;
            sub_bit <= ring[ring_idx];
        end
    end

    assign ring_en_o  = ring_en;
    assign wr_en_o    = wr_en;
    assign cmp_idx_o  = cmp_idx;
    assign ring_idx_o = ring_idx;
    assign unlocks_o  = unlocks;

endmodule

`default_nettype wire
