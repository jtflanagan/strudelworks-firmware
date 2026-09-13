`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ddr3_wrapper - UberDDR3 behind the pin names the constraint file uses.
//
// This is the direct counterpart of v5's mig_wrapper.sv.  Two jobs:
//
//   1. Rename.  constr/<board>/ddr3.xdc is a pin-for-pin transcription of the MIG
//      constraint set that is known to work on this board, so it uses MIG's port
//      names.  UberDDR3 uses its own (o_/io_ prefixes, ddr3_clk_* instead of
//      ddr3_ck_*, ba_addr instead of ba).  Renaming here, once, keeps the
//      constraint file a verbatim transcription that tools/gen_ddr3_xdc.py can
//      re-verify against ref/mig_7series_0.generated.xdc.
//
//   2. Pin the configuration to the board's actual DDR3 part, with the
//      reasoning recorded next to each parameter.
//
// Part: MT41K128M16JT-125 (Micron, 2 Gb, x16, DDR3L 1.35 V, -125 = DDR3-1600
// speed bin) - the same device on the Au V2 and the Pt V2, so one configuration
// serves both; only the pins differ (constr/<board>/ddr3.xdc).  From
// ref/mig_a.prj and ref/mig_pt_v2.prj alike: RowAddress 14, ColAddress 10,
// BankAddress 3, DataWidth 16, MemoryVoltage 1.35 V.
//
// Wishbone geometry that falls out of this (all fixed by UberDDR3 being 4:1):
//   wb_addr_bits = 14 + 10 + 3 - log2(8) = 24     (one address per 8-word burst)
//   wb_data_bits = 8 bits * 2 lanes * 4 * 2 = 128
//   wb_sel_bits  = 16
// i_wb_addr is {row, bank, col[9:3]}.
//////////////////////////////////////////////////////////////////////////////////

module ddr3_wrapper #(
    // Must match rtl/clk_gen.v.  100 MHz controller / 400 MHz DDR3 = DDR3-800.
    parameter CONTROLLER_CLK_PERIOD = 10_000,  // ps
    parameter DDR3_CLK_PERIOD       =  2_500,  // ps

    // SPEED_BIN selects the tRCD/tRP/tRAS triple UberDDR3 uses.  The -125 part is
    // a DDR3-1600 (11-11-11) device, which is bin 3 -> tRCD = tRP = 13.75 ns.
    // That agrees with ref/mig_a.prj's <TimingParameters trcd="13.75" trp="13.75"
    // tras="35">, so bin 3 reproduces the MIG timing exactly.  Note we then clock
    // it at DDR3-800, i.e. well inside its rating.
    parameter SPEED_BIN = 3,

    // 2 Gb device -> SDRAM_CAPACITY 3, which is what sets tRFC = 160 ns.  Again
    // matches ref/mig_a.prj (trfc="160").  Getting this wrong is silent: too
    // small and refresh violates tRFC, too large and every refresh costs more
    // dead time than it needs to.
    parameter SDRAM_CAPACITY = 3,

    // Bank 15 is an HR bank on both boards - Artix-7 has no HP banks in any
    // package, ftg256 (Au V2) or fgg484 (Pt V2) - and ODELAYE2 exists only in
    // HP banks (UG471).  So no output delay line, and the PHY needs the
    // 90-degree DDR3 clock instead.
    parameter ODELAY_SUPPORTED = 0,

    // BIST_MODE 1 = walk the whole address space once at the end of calibration.
    // Costs seconds at boot; keep it on until the board is trusted, then move to
    // 0 so the Apple II is not held in reset waiting for a memory test.
    parameter BIST_MODE = 1,

    // 0 = self-refresh is driven by i_user_self_refresh, never entered on its own.
    // Deliberate: this design wants refresh under its control, not on a timer.
    // See docs/DERISK.md - this is NOT the same as controlling AUTO-refresh.
    parameter SELF_REFRESH = 0,

    // 1 = honour refresh_ok and pull auto-refresh into windows the bus logic
    // declares free.  This is the milestone-2 patch (patches/0001-refresh-gate.patch),
    // not upstream UberDDR3.  It only ever moves a refresh EARLIER, so refresh
    // can never be starved and retention is safe even if refresh_ok never
    // asserts.  See docs/DERISK.md.
    //
    // OFF (the user's, 2026-09-12): the controller refreshes on its own tREFI
    // timer, as upstream does.  Removed as a candidate cause of the IIgs
    // bitstreams that met timing and never calibrated (docs/IWM35.md "On
    // hardware"); refresh_ok is still wired and ignored.  The three benches
    // that set the gate to 1 explicitly still test the patch.
    parameter REFRESH_GATE = 0,

    parameter AUX_WIDTH = 4
) (
    input  wire clk_ctrl,
    input  wire clk_ddr3,
    input  wire clk_ddr3_90,
    input  wire clk_ref,
    input  wire rst_n,          // synchronous, active low

    // Wishbone (pipelined)
    input  wire         wb_cyc,
    input  wire         wb_stb,
    input  wire         wb_we,
    input  wire [23:0]  wb_addr,
    input  wire [127:0] wb_data,
    input  wire [15:0]  wb_sel,
    input  wire [AUX_WIDTH-1:0] wb_aux,
    output wire         wb_stall,
    output wire         wb_ack,
    output wire [127:0] wb_rdata,
    output wire [AUX_WIDTH-1:0] wb_rdata_aux,

    // Status
    output wire calib_complete,
    output wire [31:0] ddr3_debug,

    // Request the DDR3 be put into self-refresh (see SELF_REFRESH above).
    input  wire user_self_refresh,

    // High when the upcoming bus cycle will be served without touching DDR3, so
    // a refresh may be taken now.  Advisory: the tREFI deadline still fires by
    // itself, so tying this low is safe and reproduces upstream behaviour.
    input  wire refresh_ok,

    // DDR3 device pins - names match constr/<board>/ddr3.xdc, which matches MIG's.
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    // [0:0], matching both MIG's naming in constr/<board>/ddr3.xdc and UberDDR3's
    // [DUAL_RANK_DIMM:0] ports - see the note in au_top.sv.
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [1:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_p,
    inout  wire [1:0]  ddr3_dqs_n
);

    ddr3_top #(
        .CONTROLLER_CLK_PERIOD (CONTROLLER_CLK_PERIOD),
        .DDR3_CLK_PERIOD       (DDR3_CLK_PERIOD),
        .ROW_BITS              (14),
        .COL_BITS              (10),
        .BA_BITS               (3),
        .BYTE_LANES            (2),      // x16 device = 2 byte lanes
        .AUX_WIDTH             (AUX_WIDTH),
        .WB2_ADDR_BITS         (7),
        .WB2_DATA_BITS         (32),
        .DUAL_RANK_DIMM        (0),
        .SPEED_BIN             (SPEED_BIN),
        .SDRAM_CAPACITY        (SDRAM_CAPACITY),
        .MICRON_SIM            (0),
        .ODELAY_SUPPORTED      (ODELAY_SUPPORTED),
        .SECOND_WISHBONE       (0),
        .DLL_OFF               (0),
        .WB_ERROR              (0),
        .BIST_MODE             (BIST_MODE),
        .ECC_ENABLE            (0),
        .SELF_REFRESH          (SELF_REFRESH),
        .REFRESH_GATE          (REFRESH_GATE)
    ) u_ddr3 (
        .i_controller_clk (clk_ctrl),
        .i_ddr3_clk       (clk_ddr3),
        .i_ref_clk        (clk_ref),
        .i_ddr3_clk_90    (clk_ddr3_90),
        .i_rst_n          (rst_n),

        .i_wb_cyc         (wb_cyc),
        .i_wb_stb         (wb_stb),
        .i_wb_we          (wb_we),
        .i_wb_addr        (wb_addr),
        .i_wb_data        (wb_data),
        .i_wb_sel         (wb_sel),
        .i_aux            (wb_aux),
        .o_wb_stall       (wb_stall),
        .o_wb_ack         (wb_ack),
        .o_wb_err         (),
        .o_wb_data        (wb_rdata),
        .o_aux            (wb_rdata_aux),

        // SECOND_WISHBONE = 0, so this port group is unused.
        .i_wb2_cyc        (1'b0),
        .i_wb2_stb        (1'b0),
        .i_wb2_we         (1'b0),
        .i_wb2_addr       (7'b0),
        .i_wb2_data       (32'b0),
        .i_wb2_sel        (4'b0),
        .o_wb2_stall      (),
        .o_wb2_ack        (),
        .o_wb2_data       (),

        .o_ddr3_clk_p     (ddr3_ck_p),
        .o_ddr3_clk_n     (ddr3_ck_n),
        .o_ddr3_reset_n   (ddr3_reset_n),
        .o_ddr3_cke       (ddr3_cke),
        .o_ddr3_cs_n      (ddr3_cs_n),
        .o_ddr3_ras_n     (ddr3_ras_n),
        .o_ddr3_cas_n     (ddr3_cas_n),
        .o_ddr3_we_n      (ddr3_we_n),
        .o_ddr3_addr      (ddr3_addr),
        .o_ddr3_ba_addr   (ddr3_ba),
        .io_ddr3_dq       (ddr3_dq),
        .io_ddr3_dqs      (ddr3_dqs_p),
        .io_ddr3_dqs_n    (ddr3_dqs_n),
        .o_ddr3_dm        (ddr3_dm),
        .o_ddr3_odt       (ddr3_odt),

        .o_calib_complete (calib_complete),
        .o_debug1         (ddr3_debug),

        .i_user_self_refresh (user_self_refresh),
        .i_refresh_ok        (refresh_ok),
        .uart_tx          ()
    );

endmodule
