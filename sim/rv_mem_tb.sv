`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// rv_mem_tb - the RISC-V engine's core and its memory side, for
// sim/rv_mem_main.cpp: the core's control face (the VM's) and rv_mem's L2 face
// (the bench's model of page_cam) brought out.
//////////////////////////////////////////////////////////////////////////////////
module rv_mem_tb #(
    parameter integer DROWS = 512,      // rv_mem's data row cache (run_rv_mem.sh: DROWS=N)
    parameter integer TN = 4            // rv_mem's page table entries (run_rv_mem.sh: TN=N)
) (
    input  wire         clk,
    input  wire         rst,
    // the VM's face
    input  wire         step,
    input  wire         cancel,
    input  wire  [23:0] wsn_a,          // cancel's write: where
    input  wire         inval,
    input  wire         resume,
    input  wire  [31:0] resume_val,
    input  wire         run,
    input  wire         hold,
    output wire         paid,
    output wire         busy,
    output wire         retired,
    output wire  [7:0]  result,
    output wire  [31:0] ev_addr,
    output wire  [31:0] ev_data,
    output wire  [31:0] ev_iw,
    input  wire  [4:0]  rsel,
    output wire  [31:0] rval,
    input  wire         w_en,
    input  wire  [4:0]  w_sel,
    input  wire  [31:0] w_val,
    input  wire         pc_we,
    input  wire  [31:0] pc_wval,
    output wire  [31:0] pc,
    input  wire  [7:0]  dlo,
    input  wire  [7:0]  dhi,
    // the L2's face
    output wire         il_req,
    output wire  [15:0] il_ppn,
    output wire  [3:0]  il_line,
    output wire         il_fill,
    input  wire         il_ack,
    input  wire         il_done,
    input  wire         il_ok,
    input  wire  [127:0] il_row,
    input  wire  [3:0]  il_set,
    input  wire  [2:0]  il_way,
    output wire         dr_req,
    output wire  [3:0]  dr_set,
    output wire  [2:0]  dr_way,
    output wire  [3:0]  dr_line,
    input  wire         dr_ack,
    input  wire         dr_done,
    input  wire  [127:0] dr_row,
    input  wire         op_place_v,
    input  wire  [15:0] op_place_ppn,
    output wire         pw_req,
    output wire  [21:0] pw_addr,
    output wire  [3:0]  pw_be,
    output wire  [31:0] pw_data,
    input  wire         pw_ack,
    input  wire         evict_v,
    input  wire  [3:0]  evict_set,
    input  wire  [2:0]  evict_way,
    output wire         ref_v,
    output wire         ref_on,
    output wire  [3:0]  ref_set,
    output wire  [2:0]  ref_way,
    output wire         rec_v,
    output wire  [63:0] rec,
    input  wire         rec_take,
    output wire         wr_busy
);
    wire        req_spec, f_req, f_valid, f_delegate, f_abort, d_req, d_we, d_valid, d_delegate, d_abort;
    wire [21:0] f_addr, d_addr;
    wire [3:0]  d_be;
    wire [31:0] f_data, d_wdata, d_rdata, pk_word;
    wire [21:0] pk_addr, d_pre, f_pre;
    wire        pk_use;
    wire        pk_hit;

    rv_pipe u_core (
        .clk (clk), .rst (rst),
        .step (step), .cancel (cancel), .resume (resume), .resume_val (resume_val),
        .run (run), .hold (hold), .paid (paid),
        .busy (busy), .retired (retired), .result (result),
        .ev_addr (ev_addr), .ev_data (ev_data), .ev_iw (ev_iw),
        .rsel (rsel), .rval (rval), .w_en (w_en), .w_sel (w_sel), .w_val (w_val),
        .pc_we (pc_we), .pc_wval (pc_wval), .pc (pc),
        .f_req (f_req), .f_addr (f_addr), .f_pre (f_pre), .req_spec (req_spec),
        .f_valid (f_valid), .f_delegate (f_delegate), .f_abort (f_abort), .f_data (f_data),
        .pk_addr (pk_addr), .pk_use (pk_use), .pk_hit (pk_hit), .pk_word (pk_word),
        .d_req (d_req), .d_we (d_we), .d_addr (d_addr), .d_pre (d_pre), .d_be (d_be), .d_wdata (d_wdata),
        .d_valid (d_valid), .d_delegate (d_delegate), .d_abort (d_abort), .d_rdata (d_rdata)
    );

    // the snoop and the invalidations a clock late, as rv_engine registers them
    logic        wsn_v_q = 1'b0, inval_q = 1'b0;
    logic [23:0] wsn_a_q = 24'd0;
    always_ff @(posedge clk) begin wsn_v_q <= !rst && cancel; inval_q <= !rst && inval; wsn_a_q <= wsn_a; end
    rv_mem #(.DROWS (DROWS), .TN (TN)) u_mem (
        .clk (clk), .rst (rst), .dlo (dlo), .dhi (dhi), .wsn_v (wsn_v_q), .wsn_a (wsn_a_q), .inval (inval_q),
        .req_spec (req_spec),
        .f_req (f_req), .f_addr (f_addr), .f_pre (f_pre), .f_valid (f_valid), .f_delegate (f_delegate), .f_abort (f_abort), .f_data (f_data),
            .pk_addr (pk_addr), .pk_use (pk_use), .pk_hit (pk_hit), .pk_word (pk_word),
        .d_req (d_req), .d_we (d_we), .d_addr (d_addr), .d_pre (d_pre), .d_be (d_be), .d_wdata (d_wdata),
        .d_valid (d_valid), .d_delegate (d_delegate), .d_abort (d_abort), .d_rdata (d_rdata),
        .il_req (il_req), .il_ppn (il_ppn), .il_line (il_line), .il_fill (il_fill), .il_ack (il_ack), .il_done (il_done),
        .il_ok (il_ok), .il_row (il_row), .il_set (il_set), .il_way (il_way),
        .dr_req (dr_req), .dr_set (dr_set), .dr_way (dr_way), .dr_line (dr_line),
        .dr_ack (dr_ack), .dr_done (dr_done), .dr_row (dr_row),
        .op_place_v (op_place_v), .op_place_ppn (op_place_ppn),
        .pw_req (pw_req), .pw_addr (pw_addr), .pw_be (pw_be), .pw_data (pw_data), .pw_ack (pw_ack),
        .evict_v (evict_v), .evict_set (evict_set), .evict_way (evict_way),
        .ref_v (ref_v), .ref_on (ref_on), .ref_set (ref_set), .ref_way (ref_way),
        .rec_v (rec_v), .rec (rec), .rec_take (rec_take), .wr_busy (wr_busy)
    );
endmodule
