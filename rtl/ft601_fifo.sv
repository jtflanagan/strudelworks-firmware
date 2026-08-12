`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft601_fifo - FT601 synchronous-245 FIFO master.
//
// Ported from AppleTini v5's ft601_test project (verilog/ft601_test/.../
// ft600_fifo.sv, June 2025), NOT from the older v5_1_3 copy of the same filename
// (February 2025).  The two are not interchangeable: the v5_1_3 one clocks
// everything on a single ft_clk edge, which does not meet the FT601's setup
// requirement on inbound signals.  The ft601_test rewrite splits the domains
// across two MMCM phases, and that is the version worth carrying forward.  See
// ft_clk_gen.v for why.
//
// Two changes from the v5 source, both forced by this project's no-.xci rule:
//
//   fifo_ft600 (Fifo Generator XCI)  ->  xpm_fifo_async
//   clk_wiz_0                        ->  ft_clk_gen.v / MMCME2_BASE
//
// The XPM FIFO is configured to match what the XCI was: independent clocks,
// block RAM, first-word-fall-through, 32 bits wide, 1024 deep.  FWFT matters -
// the state machine reads tx_dout combinationally and pops afterwards, which is
// only correct if the head word is already presented.
//
// One behavioural fix over the v5 source: xpm_fifo_async raises wr_rst_busy /
// rd_rst_busy for several cycles after reset, during which writes and reads are
// ignored.  The v5 code leaves those pins unconnected, so a word pushed in that
// window is silently dropped.  Here they fold into the full/empty flags, so a
// producer that respects backpressure cannot lose data across a reset.
//
// The chip is programmed for FIFOMode=0 (FT245 synchronous) and ChannelConfig=2
// (1 channel), confirmed on hardware via tools/ft601/ft601_probe config.  That
// is what this module assumes: one bidirectional 32-bit pipe, all four byte
// enables asserted on write.
//////////////////////////////////////////////////////////////////////////////////

module ft601_fifo (
    // user domain
    input  logic        clk,
    input  logic        rst,          // active high

    // FT601 clock, both phases (see ft_clk_gen.v)
    input  logic        ft_clk_pos,
    input  logic        ft_clk_neg,

    // FT601 pins
    inout  wire  [31:0] ft_data,
    inout  wire  [3:0]  ft_be,
    input  logic        ft_rxf,       // active low: data available to read
    input  logic        ft_txe,       // active low: space available to write
    output logic        ft_rd,        // active low
    output logic        ft_wr,        // active low
    output logic        ft_oe,        // active low

    // Reset for the CHIP, deliberately a separate input from `rst` above.
    //
    // It must not be derived from anything that depends on ft_clk - including
    // the ft_clk MMCM's locked flag - because the FT601 only drives ft_clk once
    // it is out of reset.  Gating its reset on that lock deadlocks: no clock, so
    // no lock, so no release, so no clock.  The chip then disappears from USB
    // entirely and the only way back is to reprogram or power cycle.
    input  logic        ft_chip_rst_n,
    output logic        ft_reset,     // active low, to the FT601
    output logic        ft_wakeup,

    // user side: din is FPGA -> host, dout is host -> FPGA
    input  logic [31:0] ui_din,
    input  logic        ui_din_en,
    output logic        ui_din_full,
    output logic [31:0] ui_dout,
    input  logic        ui_dout_en,
    output logic        ui_dout_empty,

    // High while ANY of the four FIFO reset-busy flags is set.  Bring this out
    // to an LED or a status register and leave it there: if it is still high
    // once the clocks are locked, the FIFOs never completed their reset and the
    // link is wedged in a way that otherwise looks exactly like a healthy but
    // silent design.  Cost of not having it, measured: three rounds of guessing
    // at internal state from the outside.
    output logic        fifo_rst_busy,

    // Diagnostic snapshot, resynchronised to `clk`.  Bit assignments are decoded
    // by build/ft601_status.sh - keep the two in step.
    //
    //   [2:0]  FSM state (0 IDLE, 1 TX, 2 RX, 3 TURNAROUND)
    //   [3]    tx_wr_rst_busy      [4]  tx_rd_rst_busy
    //   [5]    rx_wr_rst_busy      [6]  rx_rd_rst_busy
    //   [7]    ft_txe (pin, low = FT601 has space)
    //   [8]    ft_rxf (pin, low = FT601 has data for us)
    //   [9]    tx_empty_raw        [10] tx_full_raw
    //   [11]   rx_empty_raw        [12] rx_full_raw
    //   [13]   ui_din_full
    //
    // Bits are individually synchronised, so the bus can tear across a sample.
    // That is fine for a status display and is NOT safe to make control decisions
    // from - nothing in the design reads it.
    output logic [15:0] dbg
);

    // ---- FPGA -> host -----------------------------------------------------
    // Written in the user domain, read out on the negedge phase because the
    // data it carries is launched toward the FT601.
    logic [31:0] tx_dout;
    logic        tx_dout_en;
    logic        tx_empty_raw, tx_almost_empty_raw;
    logic        tx_full_raw;
    logic        tx_wr_rst_busy, tx_rd_rst_busy;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE   ("block"),
        .FIFO_WRITE_DEPTH   (1024),
        .WRITE_DATA_WIDTH   (32),
        .READ_DATA_WIDTH    (32),
        .READ_MODE          ("fwft"),
        .FIFO_READ_LATENCY  (0),
        .USE_ADV_FEATURES   ("0808"),   // almost_full + almost_empty only
        .CDC_SYNC_STAGES    (2),
        .RELATED_CLOCKS     (0),
        .ECC_MODE           ("no_ecc"),
        .WAKEUP_TIME        (0)
    ) tx_fifo (
        .rst            (rst),
        .wr_clk         (clk),
        .wr_en          (ui_din_en),
        .din            (ui_din),
        .full           (tx_full_raw),
        .almost_full    (),
        .wr_rst_busy    (tx_wr_rst_busy),
        .rd_clk         (ft_clk_neg),
        .rd_en          (tx_dout_en),
        .dout           (tx_dout),
        .empty          (tx_empty_raw),
        .almost_empty   (tx_almost_empty_raw),
        .rd_rst_busy    (tx_rd_rst_busy),
        .sleep          (1'b0),
        .injectdbiterr  (1'b0),
        .injectsbiterr  (1'b0),
        .data_valid     (),
        .dbiterr        (),
        .overflow       (),
        .prog_empty     (),
        .prog_full      (),
        .rd_data_count  (),
        .sbiterr        (),
        .underflow      (),
        .wr_ack         (),
        .wr_data_count  ()
    );

    // ---- host -> FPGA -----------------------------------------------------
    // Written on the posedge phase, because that is when data from the FT601
    // is valid; read out in the user domain.
    logic [31:0] rx_din;
    logic        rx_din_en;
    logic        rx_full_raw, rx_almost_full_raw;
    logic        rx_empty_raw;
    logic        rx_wr_rst_busy, rx_rd_rst_busy;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE   ("block"),
        .FIFO_WRITE_DEPTH   (1024),
        .WRITE_DATA_WIDTH   (32),
        .READ_DATA_WIDTH    (32),
        .READ_MODE          ("fwft"),
        .FIFO_READ_LATENCY  (0),
        .USE_ADV_FEATURES   ("0808"),
        .CDC_SYNC_STAGES    (2),
        .RELATED_CLOCKS     (0),
        .ECC_MODE           ("no_ecc"),
        .WAKEUP_TIME        (0)
    ) rx_fifo (
        .rst            (rst),
        .wr_clk         (ft_clk_pos),
        .wr_en          (rx_din_en),
        .din            (rx_din),
        .full           (rx_full_raw),
        .almost_full    (rx_almost_full_raw),
        .wr_rst_busy    (rx_wr_rst_busy),
        .rd_clk         (clk),
        .rd_en          (ui_dout_en),
        .dout           (ui_dout),
        .empty          (rx_empty_raw),
        .almost_empty   (),
        .rd_rst_busy    (rx_rd_rst_busy),
        .sleep          (1'b0),
        .injectdbiterr  (1'b0),
        .injectsbiterr  (1'b0),
        .data_valid     (),
        .dbiterr        (),
        .overflow       (),
        .prog_empty     (),
        .prog_full      (),
        .rd_data_count  (),
        .sbiterr        (),
        .underflow      (),
        .wr_ack         (),
        .wr_data_count  ()
    );

    // Fold the reset-busy flags into the flow control, so nothing is accepted
    // or believed while the FIFOs are still coming out of reset.
    logic tx_empty, tx_almost_empty, rx_full, rx_almost_full;
    assign ui_din_full     = tx_full_raw        | tx_wr_rst_busy;
    assign tx_empty        = tx_empty_raw       | tx_rd_rst_busy;
    assign tx_almost_empty = tx_almost_empty_raw| tx_rd_rst_busy;
    assign ui_dout_empty   = rx_empty_raw       | rx_rd_rst_busy;
    assign rx_full         = rx_full_raw        | rx_wr_rst_busy;
    assign rx_almost_full  = rx_almost_full_raw | rx_wr_rst_busy;

    assign fifo_rst_busy = tx_wr_rst_busy | tx_rd_rst_busy
                         | rx_wr_rst_busy | rx_rd_rst_busy;

    // Two-flop resynchronisation of the diagnostic bus into `clk`.  Several of
    // these live in the ft_clk domains, so this crossing is required even though
    // nothing downstream acts on the result.
    logic [15:0] dbg_raw, dbg_meta;
    always_comb begin
        dbg_raw          = 16'd0;
        dbg_raw[2:0]     = ft_state_q;
        dbg_raw[3]       = tx_wr_rst_busy;
        dbg_raw[4]       = tx_rd_rst_busy;
        dbg_raw[5]       = rx_wr_rst_busy;
        dbg_raw[6]       = rx_rd_rst_busy;
        dbg_raw[7]       = txe_q;
        dbg_raw[8]       = rxf_q;
        dbg_raw[9]       = tx_empty_raw;
        dbg_raw[10]      = tx_full_raw;
        dbg_raw[11]      = rx_empty_raw;
        dbg_raw[12]      = rx_full_raw;
        dbg_raw[13]      = ui_din_full;
    end

    always_ff @(posedge clk) begin
        dbg_meta <= dbg_raw;
        dbg      <= dbg_meta;
    end

    // ---- bus master -------------------------------------------------------
    // INPUT REGISTERS AT THE PINS.  ft_txe / ft_rxf are captured by flops that
    // constr/ft601.xdc packs into the IOBs, and the FSM only ever looks at the
    // registered copies.
    //
    // This is the fix for the defect that made this link a coin flip.  Reading
    // the raw pins combinationally put the chip's clock-to-out, the board delay,
    // the whole state machine and a FIFO read-enable into a single half cycle -
    // measured at -5.216 ns of setup slack once the interface was finally
    // constrained, on 50 endpoints.  Placement decided whether it worked, so
    // unrelated edits flipped the link between byte-perfect and duplicating
    // every word, at identical throughput.
    //
    // Registering at the pin absorbs the external delay into an IOB flop's
    // setup - which it has enormous margin for - and leaves only short internal
    // paths behind it.  v5_1_3, the committed "working register interface"
    // version, registers this signal too; the untracked ft601_test project this
    // was ported from does not, and that regression came along for the ride.
    logic txe_q, rxf_q;
    always_ff @(posedge ft_clk_pos) begin
        txe_q <= ft_txe;
        rxf_q <= ft_rxf;
    end

    typedef enum logic [2:0] {IDLE, TX, RX, TURNAROUND} ft601sm;

    ft601sm ft_state_d, ft_state_q = IDLE;

    logic tx_enabled_d, tx_enabled_q = 1'b0;
    logic rx_enabled_d, rx_enabled_q = 1'b0;
    logic oe_enabled_d, oe_enabled_q = 1'b0;

    // POP WHAT WAS ACKNOWLEDGED, never what was merely offered.
    //
    // The FT601 samples the bus on its rising edge only when both WR# and TXE#
    // are low there.  tx_enabled_q says we were driving across that edge, and
    // txe_q is TXE# captured AT it - so together they are an exact record of
    // whether the word was taken, available half a cycle before the FIFO's read
    // clock needs it.
    //
    // The old code decided speculatively, in the same instant, from a pin that
    // had not finished arriving.  Getting that wrong in one direction duplicates
    // a word and in the other drops one, which is precisely the corruption seen.
    assign tx_dout_en = tx_enabled_q & ~txe_q;
    assign rx_din_en  = rx_enabled_q & ~rxf_q;
    assign rx_din     = ft_data;

    always_comb begin
        ft_state_d   = ft_state_q;
        tx_enabled_d = tx_enabled_q;
        rx_enabled_d = rx_enabled_q;
        oe_enabled_d = oe_enabled_q;

        ft_wr     = ~tx_enabled_q;
        ft_rd     = ~rx_enabled_q;
        ft_oe     = ~oe_enabled_q;
        ft_wakeup = 1'b1;

        case (ft_state_q)
            IDLE: begin
                if (!tx_empty && !txe_q) begin
                    tx_enabled_d = 1'b1;
                    ft_state_d   = TX;
                end else if (!rxf_q && !rx_full) begin
                    // Turn the bus around first: OE# one cycle before RD#.
                    oe_enabled_d = 1'b1;
                    ft_state_d   = RX;
                end
            end

            TX: begin
                // Stop on TXE#, or BEFORE the FIFO runs dry.  Leaving on
                // almost_empty rather than empty matters: with first-word
                // fall-through, an empty FIFO still presents its last word, and
                // the chip would sample that stale value as a duplicate.  One
                // word of margin means we always stop with real data on the bus.
                //
                // Driving one cycle longer than necessary is harmless - the chip
                // ignores the bus while TXE# is high, and tx_dout_en above will
                // not pop anything it did not take.
                if (txe_q || tx_almost_empty) begin
                    tx_enabled_d = 1'b0;
                    ft_state_d   = TURNAROUND;
                end else begin
                    tx_enabled_d = 1'b1;
                end
            end

            RX: begin
                if (rxf_q || rx_almost_full) begin
                    oe_enabled_d = 1'b0;
                    rx_enabled_d = 1'b0;
                    ft_state_d   = TURNAROUND;
                end else begin
                    oe_enabled_d = 1'b1;
                    rx_enabled_d = 1'b1;
                end
            end

            TURNAROUND: begin
                tx_enabled_d = 1'b0;
                rx_enabled_d = 1'b0;
                oe_enabled_d = 1'b0;
                ft_state_d   = IDLE;
            end

            default: ft_state_d = IDLE;
        endcase
    end

    always_ff @(posedge ft_clk_pos) begin
        if (rst) ft_state_q <= IDLE;
        else     ft_state_q <= ft_state_d;
    end

    always_ff @(posedge ft_clk_neg) begin
        if (rst) begin
            tx_enabled_q <= 1'b0;
            rx_enabled_q <= 1'b0;
            oe_enabled_q <= 1'b0;
        end else begin
            tx_enabled_q <= tx_enabled_d;
            rx_enabled_q <= rx_enabled_d;
            oe_enabled_q <= oe_enabled_d;
        end
    end

    // Drive the bus only while writing.  `inout wire` rather than v5's `inout
    // logic`: a net driven by a continuous assignment has to be a net type.
    assign ft_data = ft_wr ? 32'hzzzz_zzzz : tx_dout;
    assign ft_be   = ft_wr ? 4'hz          : 4'hf;

    // Straight through from the top level - see the port comment.
    assign ft_reset = ft_chip_rst_n;

endmodule
