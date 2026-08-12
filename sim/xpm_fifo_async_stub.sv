`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// xpm_fifo_async_stub - port/parameter shell so Verilator can lint ft601_fifo.
//
// LINT ONLY.  This is NOT a FIFO model and must never be used in a simulation
// that expects data to come out the other end - it has no storage at all.  Its
// entire job is to let `verilator --lint-only` elaborate ft601_fifo so the state
// machine, the width arithmetic and the flow-control expressions get checked
// before a ten-minute Vivado run does it for us.  Vivado uses the real XPM from
// its own library and never sees this file; only sim/lint.sh does.
//
// The port list and parameter names track Xilinx UG953's xpm_fifo_async.  If
// ft601_fifo starts using a port that is missing here, lint fails loudly, which
// is the correct outcome - add it rather than working around it.
//////////////////////////////////////////////////////////////////////////////////

module xpm_fifo_async #(
    parameter FIFO_MEMORY_TYPE  = "block",
    parameter integer FIFO_WRITE_DEPTH  = 2048,
    parameter integer WRITE_DATA_WIDTH  = 32,
    parameter integer READ_DATA_WIDTH   = 32,
    parameter READ_MODE         = "std",
    parameter integer FIFO_READ_LATENCY = 1,
    parameter USE_ADV_FEATURES  = "0707",
    parameter integer CDC_SYNC_STAGES   = 2,
    parameter integer RELATED_CLOCKS    = 0,
    parameter ECC_MODE          = "no_ecc",
    parameter integer WAKEUP_TIME       = 0,
    parameter integer WR_DATA_COUNT_WIDTH = $clog2(FIFO_WRITE_DEPTH) + 1,
    parameter integer RD_DATA_COUNT_WIDTH = $clog2(FIFO_WRITE_DEPTH) + 1
) (
    input  wire                            rst,
    input  wire                            sleep,
    input  wire                            injectdbiterr,
    input  wire                            injectsbiterr,

    input  wire                            wr_clk,
    input  wire                            wr_en,
    input  wire [WRITE_DATA_WIDTH-1:0]     din,
    output wire                            full,
    output wire                            almost_full,
    output wire                            prog_full,
    output wire                            wr_ack,
    output wire                            overflow,
    output wire                            wr_rst_busy,
    output wire [WR_DATA_COUNT_WIDTH-1:0]  wr_data_count,

    input  wire                            rd_clk,
    input  wire                            rd_en,
    output wire [READ_DATA_WIDTH-1:0]      dout,
    output wire                            empty,
    output wire                            almost_empty,
    output wire                            prog_empty,
    output wire                            data_valid,
    output wire                            underflow,
    output wire                            rd_rst_busy,
    output wire [RD_DATA_COUNT_WIDTH-1:0]  rd_data_count,

    output wire                            sbiterr,
    output wire                            dbiterr
);

    // Deliberately inert.  Consume every input so Verilator does not report the
    // stub's own ports as unused, and drive every output to a constant.
    wire _unused = &{1'b0, rst, sleep, injectdbiterr, injectsbiterr,
                     wr_clk, wr_en, din, rd_clk, rd_en, 1'b0};

    assign full          = 1'b0;
    assign almost_full   = 1'b0;
    assign prog_full     = 1'b0;
    assign wr_ack        = 1'b0;
    assign overflow      = 1'b0;
    assign wr_rst_busy   = 1'b0;
    assign wr_data_count = '0;

    assign dout          = '0;
    assign empty         = 1'b1;
    assign almost_empty  = 1'b1;
    assign prog_empty    = 1'b1;
    assign data_valid    = 1'b0;
    assign underflow     = 1'b0;
    assign rd_rst_busy   = 1'b0;
    assign rd_data_count = '0;

    assign sbiterr       = 1'b0;
    assign dbiterr       = 1'b0;

endmodule
