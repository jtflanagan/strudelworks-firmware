`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// tlb_check_top - class_tlb run beside the MMU it caches, disagreement counted.
//
// The op stream drives the real apple_mmu exactly as apple_bus_write would,
// and a class_tlb rides along: looked up combinationally on every presented
// op, refilled from the MMU's t_* page views on a miss, flushed on
// map_changed.  On every op whose page was already cached, the entry's answer
// is compared against cl_* - the op-path classification that
// sim/run_mmu_trace.sh has already proven against a real machine, byte for
// byte.  So a mismatch here means one of exactly three bugs: a page that is
// not uniform after all, a t_* view that disagrees with the classifier it
// restates, or a map change map_changed failed to catch - the stale entry
// answers, cl_* has moved on, and the difference is counted.
//
// Driven by sim/tlb_trace_main.cpp over captured traces; the comparison
// itself lives here so the harness stays a pump.
//////////////////////////////////////////////////////////////////////////////////
module tlb_check_top (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,

    input  wire [15:0] op_addr,
    input  wire        op_rw,
    input  wire [7:0]  op_wdata,
    input  wire        op_present,
    input  wire        op_commit,
    input  wire        rom_ok,

    output logic [31:0] n_lookups,   // sampled TLB lookups (one per op)
    output logic [31:0] n_hits,      // ...that found a valid entry
    output logic [31:0] n_installs,  // refills after a miss
    output logic [31:0] n_flushes,   // map_changed pulses
    output logic [31:0] n_mismatch   // entry vs cl_* disagreements: must be 0
);

    localparam [1:0] CLS_BUS = 2'd0;
    localparam [1:0] CLS_RAM = 2'd1;
    localparam [1:0] CLS_LC  = 2'd2;
    localparam [1:0] CLS_ROM = 2'd3;

    // ---- the MMU, exactly as the op path drives it --------------------------
    wire        cl_valid, cl_rw, cl_wr_image;
    wire [1:0]  cl_cls;
    wire [23:0] cl_pa;
    wire [13:0] cl_rom_addr;
    wire        map_changed;
    wire        t_r_ok, t_w_ok;
    wire [16:0] t_r_ppage, t_w_ppage;
    logic [7:0] s_page;

    apple_mmu u_mmu (
        .clk         (clk),
        .rst         (rst),
        .res_sync    (res_sync),
        .op_addr     (op_addr),
        .op_rw       (op_rw),
        .op_wdata    (op_wdata),
        .op_present  (op_present),
        .op_commit   (op_commit),
        .rom_ok      (rom_ok),
        .cl_valid    (cl_valid),
        .cl_cls      (cl_cls),
        .cl_pa       (cl_pa),
        .cl_rom_addr (cl_rom_addr),
        .cl_rw       (cl_rw),
        .cl_wr_image (cl_wr_image),
        .intc8rom    (),
        .sw_state    (),
        .vid_sw      (),
        .rw_bank     (),
        .q_addr      (16'd0),
        .q_divert    (),
        .q_rw        (1'b1),
        .q_cls       (),
        .t_page      (s_page),      // the missed page, asked one clock later
        .t_r_ok      (t_r_ok),
        .t_r_ppage   (t_r_ppage),
        .t_w_ok      (t_w_ok),
        .t_w_ppage   (t_w_ppage),
        .map_changed (map_changed)
    );

    // ---- the TLB under test -------------------------------------------------
    wire        l_hit, l_r_ok, l_w_ok;
    wire [16:0] l_r_ppage, l_w_ppage;
    logic       s_hit, s_r_ok, s_w_ok;
    logic [16:0] s_r_ppage, s_w_ppage;

    // A miss installs at cl_valid: t_* is combinational on the switches as
    // they stand then, which are the switches the op was classified under -
    // op_commit, where they move, has not happened yet.  A flush racing the
    // install wins inside class_tlb, and the next touch of the page refills.
    wire install = cl_valid && !s_hit;

    class_tlb u_tlb (
        .clk       (clk),
        .rst       (rst),
        .flush     (map_changed),
        .l_addr    (op_addr),
        .l_hit     (l_hit),
        .l_r_ok    (l_r_ok),
        .l_r_ppage (l_r_ppage),
        .l_w_ok    (l_w_ok),
        .l_w_ppage (l_w_ppage),
        .w_en      (install),
        .w_page    (s_page),
        .w_r_ok    (t_r_ok),
        .w_r_ppage (t_r_ppage),
        .w_w_ok    (t_w_ok),
        .w_w_ppage (t_w_ppage)
    );

    // The lookup is sampled at the present edge - the same edge that latches
    // cl_*, so entry and classification describe the same map even when this
    // very op goes on to change it.
    always_ff @(posedge clk) begin
        if (op_present) begin
            s_hit     <= l_hit;
            s_page    <= op_addr[15:8];
            s_r_ok    <= l_r_ok;
            s_r_ppage <= l_r_ppage;
            s_w_ok    <= l_w_ok;
            s_w_ppage <= l_w_ppage;
        end
    end

    // ---- the comparison, at cl_valid ----------------------------------------
    // What a valid entry must have said, given what the proven op path says.
    logic bad;
    always_comb begin
        bad = 1'b0;
        if (cl_rw) begin
            // r_ok restates "not BUS", minus the two INTC8ROM pages.
            if (s_r_ok != ((cl_cls != CLS_BUS) &&
                           s_page != 8'hC3 && s_page != 8'hCF)) bad = 1'b1;
            else if (s_r_ok) begin
                if (s_r_ppage[16])
                    bad = (cl_cls != CLS_ROM) ||
                          (s_r_ppage[5:0] != cl_rom_addr[13:8]);
                else
                    bad = (cl_cls != CLS_RAM && cl_cls != CLS_LC) ||
                          (s_r_ppage[15:0] != cl_pa[23:8]);
            end
        end else begin
            if (s_w_ok != cl_wr_image) bad = 1'b1;
            else if (s_w_ok)
                bad = s_w_ppage[16] ||
                      (cl_cls != CLS_RAM && cl_cls != CLS_LC) ||
                      (s_w_ppage[15:0] != cl_pa[23:8]);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            n_lookups <= '0; n_hits <= '0; n_installs <= '0;
            n_flushes <= '0; n_mismatch <= '0;
        end else begin
            if (op_present)  n_lookups <= n_lookups + 1;
            if (op_present && l_hit) n_hits <= n_hits + 1;
            if (install)     n_installs <= n_installs + 1;
            if (map_changed) n_flushes <= n_flushes + 1;
            if (cl_valid && s_hit && bad) begin
                n_mismatch <= n_mismatch + 1;
                if (n_mismatch < 10)
                    $display("TLB MISMATCH: page %02x rw=%b cls=%0d pa=%06x rom=%04x  entry r_ok=%b r_pp=%05x w_ok=%b w_pp=%05x",
                             s_page, cl_rw, cl_cls, cl_pa, cl_rom_addr,
                             s_r_ok, s_r_ppage, s_w_ok, s_w_ppage);
            end
        end
    end

endmodule
