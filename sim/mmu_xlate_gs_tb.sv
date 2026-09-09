`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mmu_xlate_gs_tb - the IIgs map against a model taken from the reference.
//
// rtl/apple_mmu.sv at GS = 1 answers for a 24-bit space: four bank classes, the
// $00/$01 and $E0/$E1 pairs where the IIe's switches still live, SHADOW's write
// duplication, and the I/O-and-language-card inhibit.  None of that is checked
// by sim/mmu_xlate_tb.sv, which sweeps the IIe map and proves only that the IIe
// is unmoved.
//
// THE MODEL BELOW IS WRITTEN FROM KEGS, NOT FROM THE RTL, and that is the whole
// point of it.  Every rule here was read out of kegs.1.38/src/moremem.c -
// fixup_bank0_0400_0800, fixup_shadow_txt1/txt2/hires1/hires2/shr and
// fixup_shadow_iolc - and transcribed as its own expression of the map.  Two
// independent statements of one spec disagree where either is wrong; a model
// derived from the thing it checks agrees with a bug.  It has already earned
// this: writing it found the I/O-inhibit windows implemented the wrong way
// round (see below), and the auxiliary side taken from a RamWorks-mapped bank
// number that only reads correctly while that register is zero.
//
// WHAT THE REFERENCE SAYS, in the two places it is surprising:
//
//   THE SHADOW DESTINATION FOLLOWS WHERE THE WRITE LANDS, not which bank the
//   CPU named.  fixup_shadow_shr settles it: bank $00's $6000-$9FFF takes the
//   $E1 destination only when RAMWRT sent the write to auxiliary memory, and
//   takes no shadow at all when it landed in main - main's $6000-$9FFF is not
//   Super Hi-Res.  So each region has a main answer and an aux answer.
//
//   THE I/O INHIBIT ($C035 bit 6) IS NOT IDENTITY RAM.  It SWAPS the windows:
//   CPU $C000-$CFFF reads the image's $D000 (language card bank 2) and CPU
//   $D000-$DFFF reads the image's $C000 (bank 1, where the fold has always put
//   it), so both $D000 images are visible at once - which is what the mode is
//   for.  $E000-$FFFF is itself.  It applies to banks $00/$01 only, and ALTZP
//   still steers the upper two windows but not $C000-$CFFF.
//
// Under Verilator: sim/run_mmu_xlate_gs_tb.sh.  +quick sweeps a sample.
//////////////////////////////////////////////////////////////////////////////////
module mmu_xlate_gs_tb;

    logic clk = 0, rst = 1, res_sync = 0;
    always #5 clk = ~clk;

    // The op path is only ever used here to move switches, which live in
    // bank $00's I/O page; the map itself is swept through the query ports.
    logic [7:0]  op_bank = 8'd0;
    logic [15:0] op_addr = 16'd0;
    logic        op_rw = 1'b1;
    logic [7:0]  op_wdata = 8'd0;
    logic        op_present = 1'b0, op_commit = 1'b0;
    logic        rom_ok = 1'b1;

    logic [23:0] q_addr = 24'd0, p_addr = 24'd0, d_addr = 24'd0;
    logic        q_rw = 1'b1, d_rw = 1'b1;

    wire [1:0]  cl_cls; wire cl_aux; wire [7:0] cl_bank; wire [15:0] cl_off;
    wire        cl_valid, cl_rw, cl_wr_image, cl_posted, cl_sh;
    wire [7:0]  shd_drops;
    wire [7:0]  cl_wdata;
    wire [15:0] cl_ppn, pf_off, pf_ppn;
    wire [11:0] sw_state;
    wire [2:0]  vid_sw;
    wire [7:0]  rw_bank, rwb_p1, swi_stat_byte;
    wire        intc8rom, q_divert, q_swi, q_swi_quiet, q_slot, q_nsc, pw_take;
    wire [1:0]  q_cls, p_cls, d_cls;
    wire        p_aux, d_aux, p_fold, p_fs, d_fold, d_sh;
    wire [15:0] p_off, d_off, p_ppn, d_ppn;
    wire [3:0]  p_reg, d_reg;
    wire        map_changed, map_settling;
    wire [103:0] rt_rd_flat;

    apple_mmu #(.GS (1'b1)) dut (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_bank (op_bank), .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit), .rom_ok (rom_ok),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux), .cl_bank (cl_bank),
        .cl_off (cl_off), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image),
        .cl_posted (cl_posted), .cl_sh (cl_sh), .shd_drops (shd_drops),
        .cl_wdata (cl_wdata),
        .pw_valid (1'b0), .pw_ppn (16'd0), .pw_off (8'd0),
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
        .d_sh (d_sh),
        .map_changed (map_changed), .map_settling (map_settling),
        .rt_rd_flat (rt_rd_flat), .rwb_p1 (rwb_p1)
    );

    localparam [1:0] CLS_BUS = 2'd0, CLS_RAM = 2'd1, CLS_LC = 2'd2, CLS_ROM = 2'd3;

    // ---- the switches, read back from the DUT so a mistyped strobe cannot
    // ---- make the model agree with the RTL by accident ------------------------
    wire store80 = sw_state[0], ramrd = sw_state[1], ramwrt = sw_state[2];
    wire altzp   = sw_state[3], page2 = sw_state[4], hires  = sw_state[5];
    wire intcxrom = sw_state[6], slotc3rom = sw_state[7];
    wire lc_bank2 = sw_state[8], lc_ramrd = sw_state[9], lc_wren = sw_state[10];

    // SHADOW is the bench's own: it is driven by writes to $C035 and nothing
    // reads it back, so the model keeps the value it wrote.
    logic [6:0] shadow = 7'd0;
    // $C02D, likewise the bench's own.  Bit n SET gives slot n's page to the
    // slot; CLEAR gives it to the internal ROM (KEGS fixup_intcx), which is
    // the opposite sense to what the name suggests and is why a IIgs comes up
    // with every slot page internal.  Bit 3 is SLOTC3ROM, one register with
    // the $C00A/B strobe.
    logic [7:0] sltrom = 8'd0;

    // ---- the model -------------------------------------------------------------
    // Regions, named as the RTL names them so a disagreement is legible.
    localparam int R_ZP=0, R_TXT=1, R_HGR=2, R_RAM=3, R_IO=4, R_CXL=5,
                   R_C3=6, R_C8=7, R_LCD=8, R_LCE=9, R_TXT2=10, R_HGR2=11, R_SHR=12;

    function automatic int m_region(input [7:0] pg);
        if (pg < 8'hC0) begin
            if      (pg <= 8'h01)                 m_region = R_ZP;
            else if (pg >= 8'h04 && pg <= 8'h07)  m_region = R_TXT;
            else if (pg >= 8'h08 && pg <= 8'h0B)  m_region = R_TXT2;
            else if (pg >= 8'h20 && pg <= 8'h3F)  m_region = R_HGR;
            else if (pg >= 8'h40 && pg <= 8'h5F)  m_region = R_HGR2;
            else if (pg >= 8'h60 && pg <= 8'h9F)  m_region = R_SHR;
            else                                  m_region = R_RAM;
        end else if (pg <= 8'hCF) begin
            if      (pg >= 8'hC8)                 m_region = R_C8;
            else if (pg == 8'hC0)                 m_region = R_IO;
            else if (pg == 8'hC3)                 m_region = R_C3;
            else                                  m_region = R_CXL;
        end else if (pg <= 8'hDF)                 m_region = R_LCD;
        else                                      m_region = R_LCE;
    endfunction

    // Is a write to this region, landing on this side, duplicated into the
    // Mega II bank?  Straight from the fixups named in the header.
    function automatic m_sh(input int r, input side);
        case (r)
            R_TXT:  m_sh = !shadow[0];
            R_TXT2: m_sh = !shadow[5];
            R_HGR:  m_sh = side ? ((!shadow[1] && !shadow[4]) || !shadow[3]) : !shadow[1];
            R_HGR2: m_sh = side ? ((!shadow[2] && !shadow[4]) || !shadow[3]) : !shadow[2];
            R_SHR:  m_sh = side ? !shadow[3] : 1'b0;
            default: m_sh = 1'b0;
        endcase
    endfunction

    // Which side does an access in the EVEN bank of a pair land on?
    function automatic m_side(input int r, input rw);
        case (r)
            R_ZP:   m_side = altzp;
            R_TXT:  m_side = store80 ? page2 : (rw ? ramrd : ramwrt);
            R_HGR:  m_side = (store80 && hires) ? page2 : (rw ? ramrd : ramwrt);
            R_LCD, R_LCE: m_side = altzp;
            default: m_side = rw ? ramrd : ramwrt;
        endcase
    endfunction

    // The whole answer: {sh, cls[1:0], wr, fs, ppn[15:0], fold}.
    localparam int M_W = 22;
    function automatic [M_W-1:0] m_xlate(input [7:0] bk, input [15:0] a, input rw);
        int          r;
        logic [7:0]  pg, bank;
        logic [1:0]  cls;
        logic        wr, fs, fold, sh, side, pair, isrom, isvoid, mega, odd;
        begin
            pg = a[15:8];
            r  = m_region(pg);
            pair   = (bk == 8'h00) || (bk == 8'h01) || (bk == 8'hE0) || (bk == 8'hE1);
            isrom  = (bk >= 8'hFC);
            isvoid = !pair && !isrom && (bk >= 8'd128);
            mega   = bk[7];      // $E0/$E1 of the pair
            odd    = bk[0];
            sh = 1'b0; fold = 1'b0; bank = bk; pg = a[15:8];

            if (!pair) begin
                if (isrom)       begin cls = CLS_ROM; wr = 1'b0;  fs = 1'b1; bank = bk;      end
                else if (isvoid) begin cls = CLS_RAM; wr = 1'b0;  fs = 1'b1; bank = 8'hFB;   end
                else             begin cls = CLS_RAM; wr = !rw;   fs = 1'b1; bank = bk;      end
            end else if (shadow[6] && !mega && r >= R_IO && r <= R_LCE) begin
                // The I/O and language-card inhibit, banks $00/$01 only.
                cls = CLS_RAM; wr = !rw; fs = 1'b1;
                if (r <= R_C8) begin                 // $C000-$CFFF -> the image's $D000
                    pg = {4'hD, a[11:8]}; fold = 1'b1; bank = {7'd0, odd};
                end else if (r == R_LCD) begin       // $D000-$DFFF -> the image's $C000
                    pg = {4'hC, a[11:8]}; fold = 1'b1; bank = {7'd0, odd | (!odd && altzp)};
                end else begin                       // $E000-$FFFF is itself
                    bank = {7'd0, odd | (!odd && altzp)};
                end
            end else if (r == R_IO) begin
                if (rw && a[15:4] == 12'hC07) begin  // $C071-$C07F reads the ROM
                    cls = CLS_ROM; wr = 1'b0; fs = 1'b1; bank = 8'hFF;
                end else begin
                    cls = CLS_BUS; wr = 1'b0; fs = 1'b0;
                end
            end else if (r == R_CXL || r == R_C3 || r == R_C8) begin
                logic internal;
                // $C1-$C7 go by the slot's own bit; $C8-$CF by the expansion
                // latch, which has no per-slot bit.
                internal = (r == R_C8) ? (rom_ok && (intcxrom || intc8rom))
                                       : (rom_ok && (intcxrom || !sltrom[a[10:8]]));
                if (a == 16'hCFFF) internal = 1'b0;
                if (!rw)           internal = 1'b0;   // a $Cxxx write is the bus's
                if (internal) begin
                    cls = CLS_ROM; wr = 1'b0; fs = (r == R_C3) ? intc8rom : 1'b1;
                    bank = 8'hFF;
                end else begin
                    cls = CLS_BUS; wr = 1'b0; fs = 1'b0;
                end
            end else if (r == R_LCD || r == R_LCE) begin
                side = odd ? 1'b1 : m_side(r, rw);
                if (rw) begin
                    cls = lc_ramrd ? CLS_LC : (rom_ok ? CLS_ROM : CLS_BUS);
                    wr  = 1'b0;
                    fs  = (cls != CLS_BUS);
                    if (lc_ramrd) begin
                        bank = {7'(bk[7:1]), side};
                        if (r == R_LCD && !lc_bank2) begin pg = {4'hC, a[11:8]}; fold = 1'b1; end
                    end else bank = 8'hFF;
                end else begin
                    cls = lc_wren ? CLS_LC : CLS_ROM;
                    wr  = lc_wren;
                    fs  = 1'b1;
                    if (lc_wren) begin
                        bank = {7'(bk[7:1]), side};
                        if (r == R_LCD && !lc_bank2) begin pg = {4'hC, a[11:8]}; fold = 1'b1; end
                    end else bank = 8'hFF;
                end
            end else begin
                // Plain RAM in a pair bank: the switches steer the even bank,
                // the odd bank is itself, and a write may duplicate.
                side = odd ? 1'b1 : m_side(r, rw);
                cls  = CLS_RAM; wr = !rw; fs = 1'b1;
                bank = {7'(bk[7:1]), side};
                if (!rw && !mega) sh = m_sh(r, side);
            end
            m_xlate = {sh, cls, wr, fs, bank, pg, fold};
        end
    endfunction

    function automatic       mx_sh  (input [M_W-1:0] x); mx_sh   = x[21];    endfunction
    function automatic [1:0] mx_cls (input [M_W-1:0] x); mx_cls  = x[20:19]; endfunction
    function automatic       mx_wr  (input [M_W-1:0] x); mx_wr   = x[18];    endfunction
    function automatic       mx_fs  (input [M_W-1:0] x); mx_fs   = x[17];    endfunction
    function automatic [15:0] mx_ppn(input [M_W-1:0] x); mx_ppn  = x[16:1];  endfunction
    function automatic       mx_fold(input [M_W-1:0] x); mx_fold = x[0];     endfunction

    // ---- what came out of the classified path ---------------------------------
    // Every landing in the image, in order: the op's, then the shadow's
    // duplicate on the clock after it.
    logic [15:0] land_ppn [0:15];
    logic [7:0]  land_off [0:15], land_dat [0:15];
    logic        land_pst [0:15];
    integer      land_n = 0;
    always @(posedge clk) if (!rst && cl_valid && cl_wr_image && land_n < 16) begin
        land_ppn[land_n] = cl_ppn;
        land_off[land_n] = cl_off[7:0];
        land_dat[land_n] = cl_wdata;
        land_pst[land_n] = cl_posted;
        land_n = land_n + 1;
    end

    // ---- driving --------------------------------------------------------------
    integer errs = 0; longint checks = 0;

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

    task automatic set_shadow(input [6:0] v);
        begin shadow = v; op(16'hC035, 1'b0, {1'b0, v}); end
    endtask

    task automatic set_sltrom(input [7:0] v);
        begin sltrom = v; op(16'hC02D, 1'b0, v); end
    endtask

    task automatic set_lc(input [2:0] st);   // {wren, bank2, ramrd}
        begin
            if (st[2]) begin op(16'hC08B, 1'b1, 8'd0); op(16'hC08B, 1'b1, 8'd0); end
            else            op(16'hC088, 1'b1, 8'd0);
            op({12'hC08, ~st[1], 1'b0, st[0], 1'b1}, 1'b0, 8'd0);
        end
    endtask

    // The seven IIe switches this map cares about, by their strobes.
    task automatic set_sw(input [6:0] v);    // {slotc3,intcx,hires,page2,altzp,ramwrt,ramrd,store80} minus one
        begin
            op({12'hC00, 3'd0, v[0]}, 1'b0, 8'd0);   // store80
            op({12'hC00, 3'd1, v[1]}, 1'b0, 8'd0);   // ramrd
            op({12'hC00, 3'd2, v[2]}, 1'b0, 8'd0);   // ramwrt
            op({12'hC00, 3'd4, v[3]}, 1'b0, 8'd0);   // altzp
            op({12'hC05, 3'd2, v[4]}, 1'b0, 8'd0);   // page2
            op({12'hC05, 3'd3, v[5]}, 1'b0, 8'd0);   // hires
            op({12'hC00, 3'd3, v[6]}, 1'b0, 8'd0);   // intcxrom
        end
    endtask

    task automatic check_point(input [7:0] bk, input [15:0] a);
        logic [M_W-1:0] mr, mw;
        begin
            p_addr = {bk, a}; d_addr = {bk, a}; d_rw = 1'b0;
            q_addr = {bk, a}; q_rw = 1'b1;
            #1;
            mr = m_xlate(bk, a, 1'b1);
            mw = m_xlate(bk, a, 1'b0);
            checks = checks + 6;
            if (p_cls !== mx_cls(mr)) begin
                errs = errs + 1;
                if (errs < 25) $display("  RD CLS  %02x/%04x sw=%03x sh=%02x: got %0d want %0d",
                                        bk, a, sw_state, shadow, p_cls, mx_cls(mr));
            end
            if (p_fs !== mx_fs(mr)) begin
                errs = errs + 1;
                if (errs < 25) $display("  RD FS   %02x/%04x sw=%03x sh=%02x: got %b want %b",
                                        bk, a, sw_state, shadow, p_fs, mx_fs(mr));
            end
            if (mx_cls(mr) != CLS_BUS && (p_ppn !== mx_ppn(mr) || p_fold !== mx_fold(mr))) begin
                errs = errs + 1;
                if (errs < 25) $display("  RD PPN  %02x/%04x sw=%03x sh=%02x: got %04x/%b want %04x/%b",
                                        bk, a, sw_state, shadow, p_ppn, p_fold, mx_ppn(mr), mx_fold(mr));
            end
            if (d_cls !== mx_cls(mw)) begin
                errs = errs + 1;
                if (errs < 25) $display("  WR CLS  %02x/%04x sw=%03x sh=%02x: got %0d want %0d",
                                        bk, a, sw_state, shadow, d_cls, mx_cls(mw));
            end
            if (mx_cls(mw) != CLS_BUS && (d_ppn !== mx_ppn(mw) || d_fold !== mx_fold(mw))) begin
                errs = errs + 1;
                if (errs < 25) $display("  WR PPN  %02x/%04x sw=%03x sh=%02x: got %04x/%b want %04x/%b",
                                        bk, a, sw_state, shadow, d_ppn, d_fold, mx_ppn(mw), mx_fold(mw));
            end
            if (d_sh !== mx_sh(mw)) begin
                errs = errs + 1;
                if (errs < 25) $display("  WR SH   %02x/%04x sw=%03x sh=%02x: got %b want %b",
                                        bk, a, sw_state, shadow, d_sh, mx_sh(mw));
            end
        end
    endtask

    // The banks worth sweeping: both pairs, the RAM either side of the
    // populated edge, the void, and the ROM's first and last.
    localparam int NBK = 12;
    logic [7:0] banks [0:NBK-1];
    initial begin
        banks[0]=8'h00; banks[1]=8'h01; banks[2]=8'h02; banks[3]=8'h10;
        banks[4]=8'h7F; banks[5]=8'h80; banks[6]=8'hC0; banks[7]=8'hE0;
        banks[8]=8'hE1; banks[9]=8'hFB; banks[10]=8'hFC; banks[11]=8'hFF;
        sl_v[0]=8'h00; sl_v[1]=8'hFF; sl_v[2]=8'h52;
    end

    integer bi, pi_, si, li, sh_i, maps;
    logic [7:0] sl_v [0:2];
    logic quick;

    initial begin
        quick = $test$plusargs("quick");
        repeat (3) @(negedge clk);
        rst = 0; res_sync = 1;
        repeat (3) @(negedge clk);
        maps = 0;

        // Phase 1: SHADOW exhaustively, over the LC states and a few switch
        // sets, on every bank and page.  This is the phase that checks the
        // duplication rules and the I/O inhibit.
        for (sh_i = 0; sh_i < 128; sh_i = sh_i + (quick ? 43 : 1)) begin
            set_shadow(sh_i[6:0]);
            for (li = 0; li < 8; li = li + (quick ? 5 : 2)) begin
                set_lc(li[2:0]);
                for (si = 0; si < 128; si = si + (quick ? 61 : 19)) begin
                    set_sw(si[6:0]);
                    // The slot register, a few values: all internal, all the
                    // slots', and a mixture.  Written AFTER set_sw, which
                    // strobes SLOTC3ROM - bit 3 of this same register - so
                    // the bench's copy is the one the DUT ends up with.
                    set_sltrom(sl_v[si % 3]);
                    maps = maps + 1;
                    for (bi = 0; bi < NBK; bi = bi + 1)
                        for (pi_ = 0; pi_ < 256; pi_ = pi_ + 1)
                            check_point(banks[bi], {pi_[7:0], 8'h34});
                    // the byte-level ones
                    for (bi = 0; bi < NBK; bi = bi + 1) begin
                        check_point(banks[bi], 16'hCFFF);
                        check_point(banks[bi], 16'hC071);
                        check_point(banks[bi], 16'hC07F);
                        check_point(banks[bi], 16'hC070);
                    end
                end
            end
            if (errs > 200) begin
                $display("FAIL: too many mismatches");
                $display("maps %0d, %0d checks, %0d mismatches", maps, checks, errs);
                $finish;
            end
        end

        // ---- the shadow's second landing ------------------------------------
        // The sweep above checks that the map SAYS a write is shadowed.  This
        // checks that the duplicate is actually emitted, at the right page of
        // the right Mega II bank, carrying the right byte - and that the two
        // land in that order, the original first.
        run_dup;

        $display("maps swept %0d, %0d checks, %0d mismatches", maps, checks, errs);
        if (errs == 0) $display("PASS");
        else           $display("FAIL");
        $finish;
    end

    // A write at `a` with `d`, with the landings recorded.
    task automatic dup_case(input [15:0] a, input [7:0] d, input [15:0] want0,
                            input [15:0] want1, input string what);
        begin
            land_n = 0;
            op(a, 1'b0, d);
            repeat (3) @(negedge clk);
            checks = checks + 1;
            if (want1 == 16'hFFFF) begin
                // not shadowed: exactly one landing
                if (land_n != 1 || land_ppn[0] !== want0) begin
                    errs = errs + 1;
                    $display("  DUP %0s: expected one landing at %04x, got %0d (first %04x)",
                             what, want0, land_n, land_ppn[0]);
                end else $display("  ok: %0s - one landing at %04x, no duplicate", what, want0);
            end else begin
                if (land_n != 2) begin
                    errs = errs + 1;
                    $display("  DUP %0s: expected two landings, got %0d", what, land_n);
                end else if (land_ppn[0] !== want0 || land_ppn[1] !== want1) begin
                    errs = errs + 1;
                    $display("  DUP %0s: landed %04x then %04x, wanted %04x then %04x",
                             what, land_ppn[0], land_ppn[1], want0, want1);
                end else if (land_dat[0] !== d || land_dat[1] !== d) begin
                    errs = errs + 1;
                    $display("  DUP %0s: bytes %02x/%02x, wanted %02x both",
                             what, land_dat[0], land_dat[1], d);
                end else if (land_off[0] !== a[7:0] || land_off[1] !== a[7:0]) begin
                    errs = errs + 1;
                    $display("  DUP %0s: offsets %02x/%02x, wanted %02x",
                             what, land_off[0], land_off[1], a[7:0]);
                end else if (land_pst[1] !== 1'b1) begin
                    errs = errs + 1;
                    $display("  DUP %0s: the duplicate is not marked posted", what);
                end else
                    $display("  ok: %0s - %04x then %04x, byte %02x, in that order",
                             what, want0, want1, d);
            end
        end
    endtask

    task automatic run_dup;
        begin
            $display("the shadow's second landing:");
            set_sw(7'd0);            // every switch off: writes land in main
            set_shadow(7'd0);        // nothing inhibited: everything shadows
            dup_case(16'h0455, 8'hA5, 16'h0004, 16'hE004, "text 1, main -> $E0");
            dup_case(16'h2077, 8'h5A, 16'h0020, 16'hE020, "hires 1, main -> $E0");
            dup_case(16'h6001, 8'h11, 16'h0060, 16'hFFFF, "SHR in main is not shadowed");
            dup_case(16'h9001, 8'h12, 16'h0090, 16'hFFFF, "...nor the rest of it");
            // RAMWRT sends the write to auxiliary memory, and the duplicate
            // follows it there: $E1, not $E0.
            set_sw(7'b0000100);      // ramwrt
            dup_case(16'h0455, 8'hB6, 16'h0104, 16'hE104, "text 1, aux -> $E1");
            dup_case(16'h6001, 8'h13, 16'h0160, 16'hE160, "SHR in aux IS shadowed");
            // The inhibits, one at a time.
            set_shadow(7'b0000001);  // text 1 inhibited
            dup_case(16'h0455, 8'hC7, 16'h0104, 16'hFFFF, "text 1 inhibited");
            set_shadow(7'b0001000);  // SHR inhibited
            dup_case(16'h6001, 8'h14, 16'h0160, 16'hFFFF, "SHR inhibited");
            // Hires in aux has two routes: its own bit and Super Hi-Res.
            set_shadow(7'b0000010);  // hires 1 inhibited, SHR not
            dup_case(16'h2077, 8'h15, 16'h0120, 16'hE120, "hires 1 inhibited but SHR is not");
            set_shadow(7'b0001010);  // both inhibited
            dup_case(16'h2077, 8'h16, 16'h0120, 16'hFFFF, "hires 1 and SHR both inhibited");
            set_shadow(7'b0010000);  // the aux-hires veto alone
            dup_case(16'h2077, 8'h17, 16'h0120, 16'hE120, "the aux veto alone leaves SHR's route");
            set_shadow(7'b0011010);  // aux veto + hires1 + SHR
            dup_case(16'h2077, 8'h18, 16'h0120, 16'hFFFF, "aux veto with both routes shut");
            checks = checks + 1;
            if (shd_drops !== 8'd0) begin
                errs = errs + 1;
                $display("  DUP: %0d duplicate(s) dropped - one deep was not enough", shd_drops);
            end else $display("  ok: no duplicate was ever dropped");
        end
    endtask

    initial begin
        #900_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
