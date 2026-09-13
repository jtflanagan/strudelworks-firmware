`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_io_claim_tb - WHERE the IIgs chipset answers (docs/LONG_DATA.md rung 3).
//
// THE RULE, FROM KEGS (moremem.c fixup_shadow_iolc), not from the RTL: $C0xx is
// the chipset's in banks $E0/$E1 always, and in $00/$01 only while SHADOW
// ($C035) bit 6 is clear.  With it set the fast pair's $C000-$FFFF is RAM.
// Every other bank's $C0xx is RAM.
//
// What is checked, without restating rtl/gs_io.sv's own list of registers:
//   1. the claim is ZERO for every $C0xx address in every bank where the rule
//      says there is no I/O (the bug this rung fixed: gs_io claimed $00/$01
//      under the inhibit), and nothing outside $C0xx is ever claimed;
//   2. wherever the rule says there IS I/O, all of $00/$01/$E0/$E1 claim
//      exactly what $E1 claims - one register, four names;
//   3. the SIDE EFFECT follows the claim: with a VBL interrupt pending, a
//      $00/C047 read under the inhibit clears nothing, and the same read with
//      the inhibit off - or from $E1 with it on - clears it.
// Under Verilator: sim/run_gs_io_claim_tb.sh.
//////////////////////////////////////////////////////////////////////////////////
module gs_io_claim_tb #(parameter ADB_KEYMAP = "adb_keymap.hex");

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [23:0] q_addr = 24'd0;
    logic        q_rw = 1'b1;
    logic [7:0]  u_bank = 8'd0, u_wdata = 8'd0;
    logic [15:0] u_addr = 16'd0;
    logic        u_rw = 1'b1, u_commit = 1'b0;
    logic [7:0]  shadow = 8'd0;
    logic        frame_tick = 1'b0;
    wire         claim, u_claim, irq;
    wire [7:0]   rd_byte;

    gs_io #(.adb_keymap (ADB_KEYMAP)) dut (
        .clk (clk), .rst (rst), .res_sync (1'b1),
        .q_addr (q_addr), .q_rw (q_rw), .claim (claim),
        .u_bank (u_bank), .u_addr (u_addr), .u_rw (u_rw), .u_wdata (u_wdata),
        .u_commit (u_commit),
        .gs_shadow (shadow), .gs_cyareg (8'd0), .gs_sltrom (8'd0), .gs_state (8'd0),
        .stat_byte (8'd0), .stat_bits (16'd0), .kbd_low (7'd0),
        .vbl (1'b0), .scan_v (9'd0), .scan_h (7'd0),
        .mw_stb (1'b0), .mw_bank (8'd0), .mw_addr (16'd0), .mw_byte (8'd0),
        .seed_time (32'd0), .border (),
        .u_claim (u_claim), .rd_byte (rd_byte), .fr_vec (),
        .loc_valid (1'b0), .loc_code (7'd0), .loc_up (1'b0), .loc_mods (8'd0),
        .live_mods (8'd0), .pb_sel (6'd0),
        .msg_valid (1'b0), .msg_type (8'd0), .msg_free (16'd0), .msg_len (8'd0),
        .pay_data (32'd0), .pay_valid (1'b0), .bram_ok (),
        .frame_tick (frame_tick), .wall_tick (1'b0),
        .c000_ext (1'b0), .c000_byte (),
        .doc_l (), .doc_r (), .irq (irq), .adb_stat (),
        .core_tick (1'b0), .fd35_word (), .fd35_valid (), .fd35_take (1'b0),
        .fd35_inserted (1'b0), .fd35_wp (1'b0), .fd35_late_clr (1'b0), .fd35_fill_clr (1'b0),
        .fd35_stale (), .fd35_track (), .fd35_side (), .fd35_motor35 (), .fd35_motor (),
        .fd35_ctl (), .fd35_seeks (), .fd35_late (), .fd35_fill_max (), .fd35_stall ()
    );

    integer errs = 0, checks = 0;

    // THE REFERENCE'S RULE, written out here on its own.
    function automatic io_here(input [7:0] bk, input [7:0] sh);
        io_here = (bk == 8'hE0) || (bk == 8'hE1) ||
                  (((bk == 8'h00) || (bk == 8'h01)) && ((sh & 8'h40) == 8'h00));
    endfunction

    task automatic query(input [7:0] bk, input [15:0] a, output bit c);
        begin
            q_addr = {bk, a}; #1; c = claim;
        end
    endtask

    // One op, retired with the synthetic commit, as accel_seq retires it.
    task automatic op(input [7:0] bk, input [15:0] a, input rw, input [7:0] wd);
        begin
            @(negedge clk);
            u_bank = bk; u_addr = a; u_rw = rw; u_wdata = wd;
            @(negedge clk); u_commit = 1'b1;
            @(negedge clk); u_commit = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic vbl_pending;
        begin
            @(negedge clk); frame_tick = 1'b1;
            @(negedge clk); frame_tick = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic expect_pvbl(input bit want, input string what);
        begin
            checks = checks + 1;
            if (dut.u_intc.p_vbl !== want) begin
                errs = errs + 1;
                $display("FAIL %0s: p_vbl %b, want %b", what, dut.u_intc.p_vbl, want);
            end else $display("ok: %0s", what);
        end
    endtask

    localparam int NBK = 9;
    logic [7:0] banks [NBK] = '{8'h00, 8'h01, 8'h02, 8'h7F, 8'hE0, 8'hE1, 8'hE2, 8'hFC, 8'hFF};

    initial begin : run
        integer si, bi, lo, n_e1;
        bit c, ce1;
        logic [7:0] sh;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ---- 1 and 2: the claim over banks x $C0xx x SHADOW ----
        for (si = 0; si < 4; si = si + 1) begin
            sh = (si == 0) ? 8'h00 : (si == 1) ? 8'h40 : (si == 2) ? 8'h3F : 8'h7F;
            shadow = sh;
            n_e1 = 0;
            for (lo = 0; lo < 256; lo = lo + 1) begin
                query(8'hE1, {8'hC0, lo[7:0]}, ce1);
                if (ce1) n_e1 = n_e1 + 1;
                for (bi = 0; bi < NBK; bi = bi + 1) begin
                    query(banks[bi], {8'hC0, lo[7:0]}, c);
                    checks = checks + 1;
                    if (io_here(banks[bi], sh) ? (c !== ce1) : (c !== 1'b0)) begin
                        errs = errs + 1;
                        if (errs < 20) $display("FAIL claim %02x/C0%02x shadow %02x: %b (E1 claims %b, I/O here %b)",
                                                banks[bi], lo[7:0], sh, c, ce1, io_here(banks[bi], sh));
                    end
                    // ...and never outside the I/O page.
                    query(banks[bi], {8'hC1, lo[7:0]}, c);
                    checks = checks + 1;
                    if (c !== 1'b0) begin
                        errs = errs + 1;
                        if (errs < 20) $display("FAIL claim %02x/C1%02x: claimed", banks[bi], lo[7:0]);
                    end
                end
            end
            if (n_e1 == 0) begin
                errs = errs + 1; $display("FAIL: $E1 claims nothing at shadow %02x - the sweep proves nothing", sh);
            end else $display("ok: claims over 9 banks x $C0xx at shadow %02x ($E1 answers %0d addresses)", sh, n_e1);
        end

        // ---- 3: the side effect follows the claim ----
        shadow = 8'h00;
        op(8'hE1, 16'hC041, 1'b0, 8'hFF);     // every Mega II interrupt enabled
        vbl_pending();
        expect_pvbl(1'b1, "a frame raises the VBL interrupt");

        shadow = 8'h40;
        op(8'h00, 16'hC047, 1'b1, 8'h00);
        expect_pvbl(1'b1, "$00/C047 read under SHADOW bit 6 is RAM: the interrupt stays");
        op(8'h01, 16'hC047, 1'b0, 8'h00);
        expect_pvbl(1'b1, "$01/C047 write under SHADOW bit 6 is RAM: the interrupt stays");
        checks = checks + 1;
        q_addr = 24'h00C047; #1;
        if (claim !== 1'b0) begin errs = errs + 1; $display("FAIL: $00/C047 claimed under SHADOW bit 6"); end

        op(8'hE1, 16'hC047, 1'b1, 8'h00);
        expect_pvbl(1'b0, "$E1/C047 read under SHADOW bit 6 is the chipset's: cleared");

        vbl_pending();
        expect_pvbl(1'b1, "a frame raises it again");
        shadow = 8'h00;
        op(8'h00, 16'hC047, 1'b1, 8'h00);
        expect_pvbl(1'b0, "$00/C047 read with SHADOW bit 6 clear is the chipset's: cleared");

        $display("%0d checks, %0d errors", checks, errs);
        if (errs == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
