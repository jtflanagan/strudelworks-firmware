`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mmu_xlate_tb - the region table against the classifier it replaced.
//
// rtl/apple_mmu.sv used to decode every question from the address and the live
// switches (a function called classify()).  It now looks the answer up in two
// registered ten-entry REGION TABLES and translates through xlate()
// (docs/PAGE_CACHE.md).  That is meant to be the same map, so this bench holds
// the old function - copied here verbatim, reading the DUT's own sw_state so
// the two cannot drift through a mistyped switch - beside the new ports and
// sweeps EVERY reachable map:
//
//   rom_ok x 2  .  the language card's 8 states  .  the nine other switch bits
//   .  two RamWorks banks  =  16384 maps, each swept over all 256 pages and
//   the four byte-level addresses that matter, read and write.
//
// It checks four things per point: the CLASS and the write-lands-in-the-image
// bit against the old function; and, against an independently written model of
// the decided physical space, the PPN, the FS bit ("front-servable", which
// carries iline's page-$C3 rule) and the fold.  The PPN is checked only where
// it means anything - a class the card answers.
//
// Under Verilator: sim/run_mmu_xlate_tb.sh.
//////////////////////////////////////////////////////////////////////////////////
module mmu_xlate_tb;

    logic clk = 0, rst = 1, res_sync = 0;
    always #5 clk = ~clk;

    logic [15:0] op_addr = 16'd0;
    logic        op_rw = 1'b1;
    logic [7:0]  op_wdata = 8'd0;
    logic        op_present = 1'b0, op_commit = 1'b0;
    logic        rom_ok = 1'b1;

    logic [15:0] q_addr = 16'd0, p_addr = 16'd0, d_addr = 16'd0;
    logic        q_rw = 1'b1, d_rw = 1'b1;

    wire [1:0]  cl_cls; wire cl_aux; wire [7:0] cl_bank; wire [15:0] cl_off;
    wire        cl_valid, cl_rw, cl_wr_image, cl_posted;
    wire [7:0]  cl_wdata;
    wire [15:0] cl_ppn, pf_off, pf_ppn;
    wire [11:0] sw_state;
    wire [2:0]  vid_sw;
    wire [7:0]  rw_bank, rwb_p1, swi_stat_byte;
    wire        intc8rom, q_divert, q_swi, q_swi_quiet, q_slot, q_nsc, pw_take;
    wire [1:0]  q_cls, p_cls, d_cls;
    wire        p_aux, d_aux, p_fold, p_fs, d_fold;
    wire [15:0] p_off, d_off, p_ppn, d_ppn;
    wire [3:0]  p_reg, d_reg;
    wire        map_changed, map_settling;
    wire [69:0] rt_rd_flat;

    apple_mmu dut (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit), .rom_ok (rom_ok),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux), .cl_bank (cl_bank),
        .cl_off (cl_off), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image),
        .cl_posted (cl_posted), .cl_wdata (cl_wdata),
        .pw_valid (1'b0), .pw_aux (1'b0), .pw_bank (8'd0), .pw_off (16'd0),
        .pw_data (8'd0), .pw_ready (1'b1), .pw_take (pw_take),
        .intc8rom (intc8rom), .pf_off (pf_off), .cl_ppn (cl_ppn), .pf_ppn (pf_ppn),
        .sw_state (sw_state), .vid_sw (vid_sw), .rw_bank (rw_bank),
        .q_addr (q_addr), .q_divert (q_divert), .q_rw (q_rw), .q_cls (q_cls),
        .swi_on (1'b0), .swi_kbd_ok (1'b0), .swi_fb_ok (1'b0), .swi_vbl_ok (1'b0),
        .swi_vbl_bar (1'b0), .swi_kbd_low (7'd0), .swi_pb_ok (1'b0), .swi_pdl_ok (1'b0),
        .swi_hd_slot (3'd0), .swi_fd_slot (3'd0), .swi_mb_slot (3'd0),
        .swi_mouse_slot (3'd0), .swi_u2_slot (3'd0), .swi_prn_slot (3'd0),
        .q_swi (q_swi), .q_swi_quiet (q_swi_quiet), .q_slot (q_slot),
        .swi_stat_byte (swi_stat_byte), .q_nsc (q_nsc),
        .p_addr (p_addr), .p_cls (p_cls), .p_aux (p_aux), .p_off (p_off),
        .p_ppn (p_ppn), .p_reg (p_reg), .p_fold (p_fold), .p_fs (p_fs),
        .d_addr (d_addr), .d_rw (d_rw), .d_cls (d_cls), .d_aux (d_aux),
        .d_off (d_off), .d_ppn (d_ppn), .d_reg (d_reg), .d_fold (d_fold),
        .map_changed (map_changed), .map_settling (map_settling),
        .rt_rd_flat (rt_rd_flat), .rwb_p1 (rwb_p1)
    );

    // The switches, read back out of the DUT: sw_state is the switch
    // REGISTERS, not the table, so the reference below is independent of what
    // is under test.
    wire store80   = sw_state[0];
    wire ramrd     = sw_state[1];
    wire ramwrt    = sw_state[2];
    wire altzp     = sw_state[3];
    wire page2     = sw_state[4];
    wire hires     = sw_state[5];
    wire intcxrom  = sw_state[6];
    wire slotc3rom = sw_state[7];
    wire lc_bank2  = sw_state[8];
    wire lc_ramrd  = sw_state[9];
    wire lc_wren   = sw_state[10];

    localparam [1:0] CLS_BUS = 2'd0, CLS_RAM = 2'd1, CLS_LC = 2'd2, CLS_ROM = 2'd3;

    // ---- the OLD classifier, verbatim ------------------------------------------
    function automatic [2:0] classify_old(input [15:0] a, input rw);
        logic [1:0] c;
        logic       wr;
        logic [3:0] page;
        logic       in_io_f, in_hi_f, int_cx, int_c8;
        begin
            in_io_f = (a[15:12] == 4'hC);
            in_hi_f = (a[15:12] >= 4'hD);
            page    = a[11:8];
            int_cx  = intcxrom || (page == 4'd3 && !slotc3rom);
            int_c8  = intcxrom || intc8rom;
            c = CLS_BUS; wr = 1'b0;
            if (in_io_f) begin
                if (rw && rom_ok && page != 4'd0 && a != 16'hCFFF &&
                    (page[3] ? int_c8 : int_cx)) c = CLS_ROM;
            end else if (in_hi_f) begin
                if (rw) begin
                    c = lc_ramrd ? CLS_LC : (rom_ok ? CLS_ROM : CLS_BUS);
                end else begin
                    c  = lc_wren ? CLS_LC : CLS_ROM;
                    wr = lc_wren;
                end
            end else begin
                c  = CLS_RAM;
                wr = !rw;
            end
            classify_old = {c, wr};
        end
    endfunction

    // ---- the physical space, written from the decision, not from the RTL --------
    function automatic [15:0] ppn_exp(input [15:0] a, input rw);
        logic [7:0] bank, page;
        logic       aux, ram_side;
        begin
            page = a[15:8];
            if (a[15:12] == 4'hC) begin
                bank = 8'hFF;                        // an internal ROM page
            end else if (a[15:12] >= 4'hD) begin
                if (rw ? lc_ramrd : lc_wren) begin   // the language card's RAM
                    bank = altzp ? rwb_p1 : 8'd0;
                    if (a[15:12] == 4'hD && !lc_bank2) page = {4'hC, a[11:8]};
                end else bank = 8'hFF;               // the ROM over it
            end else begin
                ram_side = rw ? ramrd : ramwrt;
                aux = (a[15:9]  == 7'd0)       ? altzp :
                      (a[15:10] == 6'b000001)  ? (store80 ? page2 : ram_side) :
                      (a[15:13] == 3'b001)     ? ((store80 && hires) ? page2 : ram_side) :
                                                 ram_side;
                bank = aux ? rwb_p1 : 8'd0;
            end
            ppn_exp = {bank, page};
        end
    endfunction

    function automatic fold_exp(input [15:0] a, input rw);
        fold_exp = (a[15:12] == 4'hD) && !lc_bank2 && (rw ? lc_ramrd : lc_wren);
    endfunction

    // fs: the card can answer this from a front.  Every class but BUS, less
    // page $C3 while INTC8ROM is clear (that access must set the latch on the
    // sequencer) and $CFFF, which is the latch's clear strobe.
    function automatic fs_exp(input [15:0] a, input rw);
        logic [1:0] c;
        begin
            c = classify_old(a, rw) >> 1;
            fs_exp = (c != CLS_BUS) && (a != 16'hCFFF) &&
                     !((a[15:8] == 8'hC3) && !intc8rom);
        end
    endfunction

    function automatic [3:0] reg_exp(input [15:0] a);
        logic [7:0] pg;
        begin
            pg = a[15:8];
            if (pg[7:4] < 4'hC) begin
                if      (pg[7:1] == 7'd0)      reg_exp = 4'd0;   // R_ZP
                else if (pg[7:2] == 6'b000001) reg_exp = 4'd1;   // R_TXT
                else if (pg[7:5] == 3'b001)    reg_exp = 4'd2;   // R_HGR
                else                           reg_exp = 4'd3;   // R_RAM
            end else if (pg[7:4] == 4'hC) begin
                if      (pg[3])                reg_exp = 4'd7;   // R_C8
                else if (pg[3:0] == 4'd0)      reg_exp = 4'd4;   // R_IO
                else if (pg[3:0] == 4'd3)      reg_exp = 4'd6;   // R_C3
                else                           reg_exp = 4'd5;   // R_CXL
            end else if (pg[7:4] == 4'hD)      reg_exp = 4'd8;   // R_LCD
            else                               reg_exp = 4'd9;   // R_LCE
        end
    endfunction

    // ---- driving the machine ---------------------------------------------------
    integer errs = 0, checks = 0;

    task automatic op(input [15:0] a, input rw, input [7:0] wd);
        begin
            @(negedge clk);
            op_addr <= a; op_rw <= rw; op_wdata <= wd; op_present <= 1'b1;
            @(negedge clk); op_present <= 1'b0;
            @(negedge clk); op_commit <= 1'b1;
            @(negedge clk); op_commit <= 1'b0;
            @(negedge clk);
        end
    endtask

    // The four (bank2, lc_ramrd) pairs, by a WRITE with A0 set: it leaves the
    // write enable and the pre-write state alone.
    task automatic set_lc(input [2:0] st);   // {wren, bank2, ramrd}
        begin
            if (st[2]) begin op(16'hC08B, 1'b1, 8'd0); op(16'hC08B, 1'b1, 8'd0); end
            else            op(16'hC088, 1'b1, 8'd0);
            op({12'hC08, ~st[1], 1'b0, st[0], 1'b1}, 1'b0, 8'd0);
        end
    endtask

    task automatic check_point(input [15:0] a);
        logic [2:0] eo;
        begin
            // reads through p_*, writes through d_*
            p_addr = a; d_addr = a; d_rw = 1'b0; q_addr = a; q_rw = 1'b1;
            #1;
            eo = classify_old(a, 1'b1);
            checks = checks + 4;
            if (p_cls !== eo[2:1]) begin
                errs = errs + 1;
                if (errs < 20) $display("  RD CLS  a=%04x sw=%03x i8=%b rom=%b bk=%0d: got %0d want %0d",
                                        a, sw_state, intc8rom, rom_ok, rw_bank, p_cls, eo[2:1]);
            end
            if (q_cls !== eo[2:1]) begin
                errs = errs + 1;
                if (errs < 20) $display("  RD QCLS a=%04x: got %0d want %0d", a, q_cls, eo[2:1]);
            end
            if (p_fs !== fs_exp(a, 1'b1)) begin
                errs = errs + 1;
                if (errs < 20) $display("  RD FS   a=%04x sw=%03x i8=%b rom=%b: got %b want %b",
                                        a, sw_state, intc8rom, rom_ok, p_fs, fs_exp(a, 1'b1));
            end
            if (p_reg !== reg_exp(a) || p_fold !== fold_exp(a, 1'b1)) begin
                errs = errs + 1;
                if (errs < 20) $display("  RD ID   a=%04x: reg %0d/%0d fold %b/%b",
                                        a, p_reg, reg_exp(a), p_fold, fold_exp(a, 1'b1));
            end
            if (eo[2:1] != CLS_BUS) begin
                checks = checks + 1;
                if (p_ppn !== ppn_exp(a, 1'b1)) begin
                    errs = errs + 1;
                    if (errs < 20) $display("  RD PPN  a=%04x sw=%03x bk=%0d: got %04x want %04x",
                                            a, sw_state, rw_bank, p_ppn, ppn_exp(a, 1'b1));
                end
            end
            // the write side, through d_* and q_*
            eo = classify_old(a, 1'b0);
            q_rw = 1'b0; #1;
            checks = checks + 3;
            if (d_cls !== eo[2:1] || q_cls !== eo[2:1]) begin
                errs = errs + 1;
                if (errs < 20) $display("  WR CLS  a=%04x sw=%03x: got %0d/%0d want %0d",
                                        a, sw_state, d_cls, q_cls, eo[2:1]);
            end
            if (d_reg !== reg_exp(a) || d_fold !== fold_exp(a, 1'b0)) begin
                errs = errs + 1;
                if (errs < 20) $display("  WR ID   a=%04x: reg %0d/%0d fold %b/%b",
                                        a, d_reg, reg_exp(a), d_fold, fold_exp(a, 1'b0));
            end
            if (eo[2:1] != CLS_BUS) begin
                if (d_ppn !== ppn_exp(a, 1'b0)) begin
                    errs = errs + 1;
                    if (errs < 20) $display("  WR PPN  a=%04x sw=%03x bk=%0d: got %04x want %04x",
                                            a, sw_state, rw_bank, d_ppn, ppn_exp(a, 1'b0));
                end
            end else checks = checks - 1;
        end
    endtask

    integer ro, lcs, sw, bk, i;
    integer maps = 0;
    integer n_bk = 2, n_ro = 2, n_lc = 8, n_sw = 512;
    logic [15:0] pts [0:259];

    initial begin
        for (i = 0; i < 256; i = i + 1) pts[i] = {i[7:0], 8'h00};
        pts[256] = 16'hCFFF;   // the latch's clear strobe, BUS in every state
        pts[257] = 16'hCFF0;   // its line: the table's entry, not the override
        pts[258] = 16'hC3FF;
        pts[259] = 16'hD001;

        if ($test$plusargs("quick")) begin n_sw = 8; end   // 256 maps, seconds
        repeat (4) @(negedge clk);
        rst = 0; res_sync = 1;
        repeat (4) @(negedge clk);

        for (bk = 0; bk < n_bk; bk = bk + 1) begin
          for (ro = 0; ro < n_ro; ro = ro + 1) begin
            rom_ok = ro[0];
            for (lcs = 0; lcs < n_lc; lcs = lcs + 1) begin
              for (sw = 0; sw < n_sw; sw = sw + 1) begin
                // The RamWorks bank first: its register is a $C073 write.
                op(16'hC073, 1'b0, bk[0] ? 8'd253 : 8'd0);
                // INTC8ROM: clear it, then set it if wanted (needs SLOTC3ROM
                // clear and an access to $C3xx), before SLOTC3ROM's own value.
                op(16'hCFFF, 1'b1, 8'd0);
                if (sw[8]) begin
                    op(16'hC00A, 1'b0, 8'd0);
                    op(16'hC300, 1'b1, 8'd0);
                end
                op({12'hC00, 3'd0, sw[0]}, 1'b0, 8'd0);   // 80STORE
                op({12'hC00, 3'd1, sw[1]}, 1'b0, 8'd0);   // RAMRD
                op({12'hC00, 3'd2, sw[2]}, 1'b0, 8'd0);   // RAMWRT
                op({12'hC00, 3'd4, sw[3]}, 1'b0, 8'd0);   // ALTZP
                op({12'hC00, 3'd3, sw[4]}, 1'b0, 8'd0);   // INTCXROM
                op({12'hC00, 3'd5, sw[5]}, 1'b0, 8'd0);   // SLOTC3ROM
                op({12'hC05, 3'd2, sw[6]}, 1'b0, 8'd0);   // PAGE2
                op({12'hC05, 3'd3, sw[7]}, 1'b0, 8'd0);   // HIRES
                set_lc(lcs[2:0]);
                repeat (3) @(negedge clk);
                maps = maps + 1;
                for (i = 0; i < 260; i = i + 1) check_point(pts[i]);
                if (errs > 40) begin
                    $display("FAIL: too many mismatches"); $finish;
                end
              end
            end
          end
        end

        $display("maps swept %0d, %0d checks, %0d mismatches", maps, checks, errs);
        if (errs == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

endmodule
