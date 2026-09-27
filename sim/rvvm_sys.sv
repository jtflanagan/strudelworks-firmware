`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// rvvm_sys - the harness's machine (sim/rvvm_run_main.cpp): the card's 65816
// and the RISC-V engine, the engine's window decoded at $EF:FE00-$EF:FEFF.
// The C++ harness still answers every other access from its flat memory; for
// a window access it takes win_rdata and holds the cycle (cyc_en low) while
// win_stall stands.  A 65816 write anywhere else cancels the engine's
// speculation - memory may have changed under it (REQ_RVVM "Speculation").
//////////////////////////////////////////////////////////////////////////////////
module rvvm_sys #(
    parameter UCODE_FILE  = "cpu65816_ucode.hex",
    parameter UCODE0_FILE = "cpu65816_ucode0.hex",
    parameter USEQ0_FILE  = "cpu65816_useq0.hex",
    // MEM = 0: every access the engine makes is served by the 65816 (the default,
    // the guests' bench: the 65816's 16 MB).  MEM = 1 (sim/run_rv_app.sh): the
    // engine's own memory side (rv_mem) on the card's map, its L2 face brought
    // out to the harness's model (sim/l2_model.h), AW = 25: the whole 32 MB.
    parameter integer MEM = 0,
    parameter integer AW  = 24
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         cyc_en,
    input  wire         irq_n,
    input  wire         nmi_n,
    input  wire  [7:0]  i_din,
    input  wire  [7:0]  d_din,
    output wire  [23:0] addr,
    output wire         rw,
    output wire  [7:0]  dout,
    output wire         sync,
    output wire         vda,
    output wire         vpa,
    output wire         halted,
    output wire         win_sel,
    output wire  [7:0]  win_rdata,
    output wire         win_stall,
    output wire         retired,
    input  wire         inval,          // a write the 65816 did not make (a DMA's): the engine's rows go
    // the L2 face (MEM = 1; idle otherwise)
    output wire             il_req,
    output wire  [AW-9:0]   il_ppn,
    output wire  [3:0]      il_line,
    output wire             il_fill,
    input  wire             il_ack,
    input  wire             il_done,
    input  wire             il_ok,
    input  wire  [127:0]    il_row,
    input  wire  [3:0]      il_set,
    input  wire  [2:0]      il_way,
    output wire             dr_req,
    output wire  [3:0]      dr_set,
    output wire  [2:0]      dr_way,
    output wire  [3:0]      dr_line,
    input  wire             dr_ack,
    input  wire             dr_done,
    input  wire  [127:0]    dr_row,
    input  wire             op_place_v,
    input  wire  [AW-9:0]   op_place_ppn,
    input  wire             evict_v,
    input  wire  [3:0]      evict_set,
    input  wire  [2:0]      evict_way,
    output wire             pw_req,
    output wire  [AW-3:0]   pw_addr,
    output wire  [3:0]      pw_be,
    output wire  [31:0]     pw_data,
    input  wire             pw_ack,
    output wire             ref_v,
    output wire             ref_on,
    output wire  [3:0]      ref_set,
    output wire  [2:0]      ref_way,
    output wire             rec_v,
    output wire  [63:0]     rec,
    input  wire             rec_take
);
    cpu65816 #(.UCODE_FILE (UCODE_FILE), .UCODE0_FILE (UCODE0_FILE), .USEQ0_FILE (USEQ0_FILE)) u_cpu (
        .clk (clk), .rst (rst), .cyc_en (cyc_en),
        .addr (addr), .rw (rw), .dout (dout), .i_din (i_din), .d_din (d_din), .i_tgt (8'd0), .i_tgt_sel (1'b0),
        .irq_n (irq_n), .nmi_n (nmi_n), .sync (sync), .vda (vda), .vpa (vpa),
        .vpb (), .emu (), .halted (halted), .cyc_is_i (), .pc_addr (), .pc_d (),
        .d_pred (), .d_pred_v (), .d_pred_rw (), .d_pred_bcls (), .d_pred_vpb (),
        .d_pred_arms (), .p_flags (p_flags), .dbr_o (), .bank_wr ()
    );

    wire [7:0] p_flags;
    assign win_sel = vda && addr[23:8] == 16'hEFFE;
    rv_engine #(.MEM (MEM), .DIRECT_WRITES (MEM), .SIDX (4), .LEV (3), .AW (AW)) u_eng (
        .clk (clk), .rst (rst),
        // one live bus: both faces
        .pre_sel (win_sel), .pre_rw (rw), .pre_off (addr[7:0]),
        .srv_sel (win_sel), .srv_rw (rw), .srv_off (addr[7:0]), .srv_wdata (dout),
        .srv_act (cyc_en), .win_rdata (win_rdata), .win_stall (win_stall),
        .cancel (vda && !rw && cyc_en && !win_sel), .wsn_a (addr),
        .inval (inval),
        .retired (retired),
        // RUN yields to an interrupt the 65816 would take; no governor here
        .irq_yield (!irq_n && !p_flags[2]), .gov_ok (1'b1), .gov_pay (),
        .il_req (il_req), .il_ppn (il_ppn), .il_line (il_line), .il_fill (il_fill), .il_ack (il_ack), .il_done (il_done), .il_ok (il_ok),
        .il_row (il_row), .il_set (il_set), .il_way (il_way),
        .dr_req (dr_req), .dr_set (dr_set), .dr_way (dr_way), .dr_line (dr_line), .dr_ack (dr_ack), .dr_done (dr_done), .dr_row (dr_row),
        .op_place_v (op_place_v), .op_place_ppn (op_place_ppn), .evict_v (evict_v), .evict_set (evict_set), .evict_way (evict_way),
        .pw_req (pw_req), .pw_addr (pw_addr), .pw_be (pw_be), .pw_data (pw_data), .pw_ack (pw_ack),
        .ref_v (ref_v), .ref_on (ref_on), .ref_set (ref_set), .ref_way (ref_way), .rec_v (rec_v), .rec (rec), .rec_take (rec_take)
    );
endmodule
