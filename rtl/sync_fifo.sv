`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// sync_fifo - single-clock FIFO, first-word-fall-through, with an occupancy count.
//
// Inferred rather than an XPM instance, for the same reason clk_gen instantiates
// MMCME2_BASE directly: a module built from plain RTL lints under Verilator and
// simulates under iverilog with no Xilinx libraries and no stubs.  The clock-
// domain crossings still use xpm_fifo_async, where the primitive is doing
// something a behavioural model would not.
//
// FWFT: dout is valid whenever !empty, and rd_en consumes it.  Implemented as a
// synchronous-read memory plus a one-deep output register, prefetched whenever
// the register is free and the memory is not empty.
//
// `count` includes the word sitting in the output register, so it is the number
// of items a consumer can still take - which is what the framer needs to decide
// whether it can commit to a whole frame.
//////////////////////////////////////////////////////////////////////////////////

module sync_fifo #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 2048          // must be a power of two
) (
    input  wire              clk,
    input  wire              rst,

    input  wire [WIDTH-1:0]  din,
    input  wire              wr_en,
    output wire              full,

    output wire [WIDTH-1:0]  dout,
    input  wire              rd_en,
    output wire              empty,

    output logic [$clog2(DEPTH+1)-1:0] count
);

    localparam integer AW = $clog2(DEPTH);
    localparam integer CW = $clog2(DEPTH + 1);

    (* ram_style = "block" *) logic [WIDTH-1:0] mem [DEPTH];

    logic [AW-1:0]   wr_ptr = '0;
    logic [AW-1:0]   rd_ptr = '0;

    logic [WIDTH-1:0] out_data = '0;
    logic             out_valid = 1'b0;

    // Words sitting in the memory, i.e. not counting the output register.
    logic [AW:0] mem_count = '0;

    wire do_write = wr_en && !full;
    wire do_read  = rd_en && out_valid;

    // Refill the output register whenever it is free - either empty, or being
    // consumed this cycle - and the memory has something to give.
    wire do_fetch = (mem_count != 0) && (!out_valid || do_read);

    assign dout  = out_data;
    assign empty = !out_valid;
    assign full  = (count == DEPTH[CW-1:0]);

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr    <= '0;
            rd_ptr    <= '0;
            out_valid <= 1'b0;
            mem_count <= '0;
            count     <= '0;
        end else begin
            if (do_write) begin
                mem[wr_ptr] <= din;
                wr_ptr      <= wr_ptr + 1'b1;
            end

            if (do_fetch) begin
                out_data  <= mem[rd_ptr];
                rd_ptr    <= rd_ptr + 1'b1;
                out_valid <= 1'b1;
            end else if (do_read) begin
                out_valid <= 1'b0;
            end

            // Memory occupancy moves on writes and fetches; the visible count
            // moves on writes and reads.
            mem_count <= mem_count + {{AW{1'b0}}, do_write} - {{AW{1'b0}}, do_fetch};
            count     <= count     + {{CW-1{1'b0}}, do_write} - {{CW-1{1'b0}}, do_read};
        end
    end

endmodule
