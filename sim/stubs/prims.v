// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// EMPTY SHELLS, FOR THE LINTER ONLY.  master_top instantiates Xilinx
// primitives, an XPM macro and UberDDR3's top, none of which Verilator can
// resolve - which is why sim/lint.sh used to leave the top level to Vivado
// and a fifteen-minute elaboration.  These give it the port names and
// nothing else, so the linter can walk the whole design and say what a
// mistyped connection or a wire with no driver is, in a second.
//
// NOTHING SIMULATES WITH THESE: no clock comes out of the MMCM, no word out
// of the FIFO.  They exist so that -lint-only has a module to bind to, and
// they are never in a synthesis source list (build/build.tcl names the real
// ones).  If a port here disagrees with the real primitive, Vivado still
// says so; this only ever loses a lint, never gains a build.
`timescale 1ns / 1ps

// An empty shell drives none of its outputs, which is the whole idea.
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

module IBUF (output wire O, input wire I);
endmodule

module BUFG (output wire O, input wire I);
endmodule

// The golden image's two configuration primitives (rtl/golden/golden_top.sv).
module ICAPE2 #(
    parameter DEVICE_ID = 32'h03651093,
    parameter ICAP_WIDTH = "X32",
    parameter SIM_CFG_FILE_NAME = "NONE"
) (
    output wire [31:0] O,
    input  wire        CLK,
    input  wire        CSIB,
    input  wire [31:0] I,
    input  wire        RDWRB
);
endmodule

module STARTUPE2 #(
    parameter PROG_USR = "FALSE",
    parameter real SIM_CCLK_FREQ = 0.0
) (
    output wire CFGCLK,
    output wire CFGMCLK,
    output wire EOS,
    output wire PREQ,
    input  wire CLK,
    input  wire GSR,
    input  wire GTS,
    input  wire KEYCLEARB,
    input  wire PACK,
    input  wire USRCCLKO,
    input  wire USRCCLKTS,
    input  wire USRDONEO,
    input  wire USRDONETS
);
endmodule

module MMCME2_ADV #(
    parameter BANDWIDTH = "OPTIMIZED",
    parameter COMPENSATION = "ZHOLD",
    parameter real CLKIN1_PERIOD = 10.0,
    parameter real CLKIN2_PERIOD = 10.0,
    parameter integer DIVCLK_DIVIDE = 1,
    parameter real CLKFBOUT_MULT_F = 5.0,
    parameter real CLKFBOUT_PHASE = 0.0,
    parameter CLKFBOUT_USE_FINE_PS = "FALSE",
    parameter real CLKOUT0_DIVIDE_F = 1.0,
    parameter real CLKOUT0_PHASE = 0.0,
    parameter real CLKOUT0_DUTY_CYCLE = 0.5,
    parameter CLKOUT0_USE_FINE_PS = "FALSE",
    parameter integer CLKOUT1_DIVIDE = 1,
    parameter real CLKOUT1_PHASE = 0.0,
    parameter real CLKOUT1_DUTY_CYCLE = 0.5,
    parameter CLKOUT1_USE_FINE_PS = "FALSE",
    parameter integer CLKOUT2_DIVIDE = 1,
    parameter real CLKOUT2_PHASE = 0.0,
    parameter real CLKOUT2_DUTY_CYCLE = 0.5,
    parameter CLKOUT2_USE_FINE_PS = "FALSE",
    parameter integer CLKOUT3_DIVIDE = 1,
    parameter real CLKOUT3_PHASE = 0.0,
    parameter real CLKOUT3_DUTY_CYCLE = 0.5,
    parameter CLKOUT3_USE_FINE_PS = "FALSE",
    parameter integer CLKOUT4_DIVIDE = 1,
    parameter real CLKOUT4_PHASE = 0.0,
    parameter real CLKOUT4_DUTY_CYCLE = 0.5,
    parameter CLKOUT4_USE_FINE_PS = "FALSE",
    parameter CLKOUT4_CASCADE = "FALSE",
    parameter STARTUP_WAIT = "FALSE"
) (
    input  wire CLKIN1, CLKIN2, CLKINSEL, CLKFBIN, PWRDWN, RST,
    input  wire [6:0] DADDR,
    input  wire DCLK, DEN, DWE,
    input  wire [15:0] DI,
    output wire [15:0] DO,
    output wire DRDY,
    input  wire PSCLK, PSEN, PSINCDEC,
    output wire PSDONE,
    output wire CLKFBOUT, CLKFBOUTB, CLKFBSTOPPED, CLKINSTOPPED,
    output wire CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B,
    output wire CLKOUT2, CLKOUT2B, CLKOUT3, CLKOUT3B,
    output wire CLKOUT4, CLKOUT5, CLKOUT6, LOCKED
);
endmodule

module MMCME2_BASE #(
    parameter BANDWIDTH = "OPTIMIZED",
    parameter real CLKIN1_PERIOD = 10.0,
    parameter integer DIVCLK_DIVIDE = 1,
    parameter real CLKFBOUT_MULT_F = 5.0,
    parameter real CLKFBOUT_PHASE = 0.0,
    parameter real CLKOUT0_DIVIDE_F = 1.0,
    parameter real CLKOUT0_PHASE = 0.0,
    parameter real CLKOUT0_DUTY_CYCLE = 0.5,
    parameter integer CLKOUT1_DIVIDE = 1,
    parameter real CLKOUT1_PHASE = 0.0,
    parameter real CLKOUT1_DUTY_CYCLE = 0.5,
    parameter integer CLKOUT2_DIVIDE = 1,
    parameter real CLKOUT2_PHASE = 0.0,
    parameter real CLKOUT2_DUTY_CYCLE = 0.5,
    parameter integer CLKOUT3_DIVIDE = 1,
    parameter real CLKOUT3_PHASE = 0.0,
    parameter real CLKOUT3_DUTY_CYCLE = 0.5,
    parameter STARTUP_WAIT = "FALSE"
) (
    input  wire CLKIN1, CLKFBIN, PWRDWN, RST,
    output wire CLKFBOUT, CLKFBOUTB,
    output wire CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B,
    output wire CLKOUT2, CLKOUT2B, CLKOUT3, CLKOUT3B,
    output wire CLKOUT4, CLKOUT5, CLKOUT6, LOCKED
);
endmodule

module xpm_fifo_async #(
    parameter FIFO_MEMORY_TYPE = "block",
    parameter integer FIFO_WRITE_DEPTH = 2048,
    parameter integer WRITE_DATA_WIDTH = 32,
    parameter integer READ_DATA_WIDTH = 32,
    parameter READ_MODE = "fwft",
    parameter integer FIFO_READ_LATENCY = 0,
    parameter USE_ADV_FEATURES = "0000",
    parameter integer CDC_SYNC_STAGES = 2,
    parameter integer RELATED_CLOCKS = 0,
    parameter ECC_MODE = "no_ecc",
    parameter integer WAKEUP_TIME = 0
) (
    input  wire rst, wr_clk, wr_en, rd_clk, rd_en, sleep,
    input  wire injectdbiterr, injectsbiterr,
    input  wire [WRITE_DATA_WIDTH-1:0] din,
    output wire [READ_DATA_WIDTH-1:0]  dout,
    output wire full, empty, almost_empty, almost_full, data_valid,
    output wire dbiterr, overflow, prog_empty, prog_full,
    output wire [$clog2(FIFO_WRITE_DEPTH):0] rd_data_count, wr_data_count,
    output wire rd_rst_busy, sbiterr, underflow, wr_ack, wr_rst_busy
);
endmodule

// UberDDR3's top, by its port names.  The real one is fetched into
// third_party/ and is what Vivado builds; linting it here would drown this
// design's warnings in upstream's, which sim/lint.sh already declines to do.
module ddr3_top #(
    parameter EYE_SWEEP = 1, parameter EYE_CENTER = 1,   // the fork's read-eye sweep (rtl/common/ddr3_wrapper.sv passes them)
    parameter integer CONTROLLER_CLK_PERIOD = 10000,
    parameter integer DDR3_CLK_PERIOD = 2500,
    parameter integer ROW_BITS = 14,
    parameter integer COL_BITS = 10,
    parameter integer BA_BITS = 3,
    parameter integer BYTE_LANES = 2,
    parameter integer AUX_WIDTH = 4,
    parameter integer WB2_ADDR_BITS = 7,
    parameter integer WB2_DATA_BITS = 32,
    parameter integer DUAL_RANK_DIMM = 0,
    parameter integer CK_OSERDES = 1,
    parameter integer CK_PHASE_SHIFT = 0,
    parameter integer CK_PS_STEPS_PER_CK = 168,
    parameter integer SPEED_BIN = 0,
    parameter integer SDRAM_CAPACITY = 0,
    parameter integer MICRON_SIM = 0,
    parameter integer ODELAY_SUPPORTED = 0,
    parameter integer SECOND_WISHBONE = 0,
    parameter integer DLL_OFF = 0,
    parameter integer WB_ERROR = 0,
    parameter integer BIST_MODE = 0,
    parameter integer ECC_ENABLE = 0,
    parameter integer SELF_REFRESH = 0
) (
    input  wire i_controller_clk, i_ddr3_clk, i_ref_clk, i_ddr3_clk_90, i_rst_n,
    input  wire i_ddr3_clk_ck, i_ck_ps_done,
    output wire o_ck_ps_en, o_ck_ps_incdec,
    input  wire i_wb_cyc, i_wb_stb, i_wb_we,
    input  wire [ROW_BITS+COL_BITS+BA_BITS-1:0] i_wb_addr,
    input  wire [BYTE_LANES*64-1:0] i_wb_data,
    input  wire [BYTE_LANES*8-1:0]  i_wb_sel,
    input  wire [AUX_WIDTH-1:0]     i_aux,
    output wire o_wb_stall, o_wb_ack, o_wb_err,
    output wire [BYTE_LANES*64-1:0] o_wb_data,
    output wire [AUX_WIDTH-1:0]     o_aux,
    input  wire i_wb2_cyc, i_wb2_stb, i_wb2_we,
    input  wire [WB2_ADDR_BITS-1:0] i_wb2_addr,
    input  wire [WB2_DATA_BITS-1:0] i_wb2_data,
    input  wire [WB2_DATA_BITS/8-1:0] i_wb2_sel,
    output wire o_wb2_stall, o_wb2_ack,
    output wire [WB2_DATA_BITS-1:0] o_wb2_data,
    output wire [0:0] o_ddr3_clk_p, o_ddr3_clk_n, o_ddr3_cke, o_ddr3_cs_n, o_ddr3_odt,
    output wire o_ddr3_reset_n, o_ddr3_ras_n, o_ddr3_cas_n, o_ddr3_we_n,
    output wire [ROW_BITS-1:0] o_ddr3_addr,
    output wire [BA_BITS-1:0]  o_ddr3_ba_addr,
    inout  wire [BYTE_LANES*8-1:0] io_ddr3_dq,
    inout  wire [BYTE_LANES-1:0]   io_ddr3_dqs, io_ddr3_dqs_n,
    output wire [BYTE_LANES-1:0]   o_ddr3_dm,
    output wire o_calib_complete,
    output wire [31:0] o_debug1,
    output wire [31:0] o_debug2,
    output wire [31:0] o_debug3,
    output wire [31:0] o_debug4,
    output wire [32*BYTE_LANES-1:0] o_calib_eye,
    input  wire i_user_self_refresh,
    output wire uart_tx
);
endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
