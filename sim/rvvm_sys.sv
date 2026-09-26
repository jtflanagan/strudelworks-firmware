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
    parameter USEQ0_FILE  = "cpu65816_useq0.hex"
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
    output wire         retired
);
    cpu65816 #(.UCODE_FILE (UCODE_FILE), .UCODE0_FILE (UCODE0_FILE), .USEQ0_FILE (USEQ0_FILE)) u_cpu (
        .clk (clk), .rst (rst), .cyc_en (cyc_en),
        .addr (addr), .rw (rw), .dout (dout), .i_din (i_din), .d_din (d_din),
        .irq_n (irq_n), .nmi_n (nmi_n), .sync (sync), .vda (vda), .vpa (vpa),
        .vpb (), .emu (), .halted (halted), .cyc_is_i (), .pc_addr (), .pc_d (),
        .d_pred (), .d_pred_v (), .d_pred_rw (), .d_pred_bcls (), .d_pred_vpb (),
        .d_pred_arms (), .p_flags (p_flags), .dbr_o (), .bank_wr ()
    );

    wire [7:0] p_flags;
    assign win_sel = vda && addr[23:8] == 16'hEFFE;
    rv_engine u_eng (
        .clk (clk), .rst (rst),
        // one live bus: both faces
        .pre_sel (win_sel), .pre_rw (rw), .pre_off (addr[7:0]),
        .srv_sel (win_sel), .srv_rw (rw), .srv_off (addr[7:0]), .srv_wdata (dout),
        .srv_act (cyc_en), .win_rdata (win_rdata), .win_stall (win_stall),
        .cancel (vda && !rw && cyc_en && !win_sel), .wsn_a (addr),
        .inval (1'b0),
        .retired (retired),
        // RUN yields to an interrupt the 65816 would take; no governor here
        .irq_yield (!irq_n && !p_flags[2]), .gov_ok (1'b1), .gov_pay (),
        // MEM = 0 (the default): the VM is the memory side; the L2 ports idle
        .il_req (), .il_ppn (), .il_line (), .il_fill (), .il_ack (1'b0), .il_done (1'b0), .il_ok (1'b0),
        .il_row (128'd0), .il_set (4'd0), .il_way (3'd0),
        .dr_req (), .dr_set (), .dr_way (), .dr_line (), .dr_ack (1'b0), .dr_done (1'b0), .dr_row (128'd0),
        .op_place_v (1'b0), .op_place_ppn (16'd0), .evict_v (1'b0), .evict_set (4'd0), .evict_way (3'd0),
        .pw_req (), .pw_addr (), .pw_be (), .pw_data (), .pw_ack (1'b0),
        .ref_v (), .ref_on (), .ref_set (), .ref_way (), .rec_v (), .rec (), .rec_take (1'b1)
    );
endmodule
