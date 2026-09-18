// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// telem_map.vh - what a telemetry sample reads, in order (docs/TELEMETRY.md).
// Included inside rtl/telem_tx.sv.
//
// ONE ENTRY PER LINE, `index: {sel, offset} // NAME`.  The host mirrors this
// list (../strudelworks-host/src/telemetry_map.hpp) and tools/check_telem_map.py
// there compares the two line by line; TELEM_LAYOUT goes out in every
// message's header, and a host that does not know the number does not guess.
// CHANGE THE LIST, CHANGE THE NUMBER.
//
// An entry is a register (offset, sel unused) or - offset 0x0134, DBG_VAL - a
// word of the debug space, read with `sel` as the selector: [7:6] 1 the bank
// census, 2 the data front's bank table, else [5:4] 0 the instruction front,
// 1 the data front, 2 the page cache, 3 the top (its snapshot words and the
// clock histogram), [3:0] the item (rtl/master_top.sv's mux).
//
// Layout 2 (2026-09-17): layout 1's 85 registers, the six WIDE totals, the
// debug space's 80 items between the registers' two halves, the accelerator's
// registers last.  Left out: FB_PEEK, NSC_TIME / NSC_DATE, DBG_SEL / DBG_VAL as
// the host has them, TELEM_CTRL, the IIgs battery RAM (64 static words).
//
// The offsets are literal because the R_* names are private to
// rtl/wb_regfile.sv; sim/telem_tb.sv reads every one back against a constant
// of its own, which is what catches a slip here.

localparam [7:0]   TELEM_LAYOUT = 8'd2;
localparam integer TELEM_N      = 171;
localparam [15:0]  TELEM_DBG_OFF = 16'h0134;

function automatic [23:0] telem_ent(input [7:0] i);
    case (i)
        8'd0: telem_ent = {8'h00, 16'h0000}; // BUILD_DATE
        8'd1: telem_ent = {8'h00, 16'h0004}; // BUILD_TIME
        8'd2: telem_ent = {8'h00, 16'h0008}; // CPU_SOURCE
        8'd3: telem_ent = {8'h00, 16'h000C}; // MB_SLOT
        8'd4: telem_ent = {8'h00, 16'h0010}; // BOOT_HOLD
        8'd5: telem_ent = {8'h00, 16'h0014}; // HD_SLOT
        8'd6: telem_ent = {8'h00, 16'h0018}; // RESET
        8'd7: telem_ent = {8'h00, 16'h0158}; // START
        8'd8: telem_ent = {8'h00, 16'h001C}; // KBD_INJECT
        8'd9: telem_ent = {8'h00, 16'h0020}; // BUTTONS
        8'd10: telem_ent = {8'h00, 16'h0028}; // KBD_CTRL
        8'd11: telem_ent = {8'h00, 16'h002C}; // MENU_HOLD
        8'd12: telem_ent = {8'h00, 16'h0024}; // RING_STATUS
        8'd13: telem_ent = {8'h00, 16'h00EC}; // LINK_STAT
        8'd14: telem_ent = {8'h00, 16'h0030}; // VBL_CTRL
        8'd15: telem_ent = {8'h00, 16'h0034}; // VBL_STAT
        8'd16: telem_ent = {8'h00, 16'h0038}; // VBL_POS
        8'd17: telem_ent = {8'h00, 16'h003C}; // FD_SLOT
        8'd18: telem_ent = {8'h00, 16'h0040}; // FD_DRIVE1
        8'd19: telem_ent = {8'h00, 16'h0044}; // FD_DRIVE2
        8'd20: telem_ent = {8'h00, 16'h0048}; // FD_STAT
        8'd21: telem_ent = {8'h00, 16'h0138}; // FD35_DRIVE
        8'd22: telem_ent = {8'h00, 16'h013C}; // FD35_STAT
        8'd23: telem_ent = {8'h00, 16'h0164}; // FD35_WSTAT
        8'd24: telem_ent = {8'h00, 16'h004C}; // MEM_CTRL
        8'd25: telem_ent = {8'h00, 16'h0050}; // MEM_STAT
        8'd26: telem_ent = {8'h00, 16'h0054}; // MEM_HITS
        8'd27: telem_ent = {8'h00, 16'h0058}; // MEM_MISSES
        8'd28: telem_ent = {8'h00, 16'h005C}; // MEM_MISMATCH
        8'd29: telem_ent = {8'h00, 16'h0060}; // MEM_SERVED
        8'd30: telem_ent = {8'h00, 16'h0064}; // MEM_LAST
        8'd31: telem_ent = {8'h00, 16'h0068}; // MEM_DIVERTED
        8'd32: telem_ent = {8'h00, 16'h0114}; // MEM_FILLS
        8'd33: telem_ent = {8'h00, 16'h0118}; // MEM_FLUSHES
        8'd34: telem_ent = {8'h00, 16'h011C}; // MEM_DECLINES
        8'd35: telem_ent = {8'h00, 16'h0120}; // MEM_ROM
        8'd36: telem_ent = {8'h00, 16'h015C}; // ROM_SUM
        8'd37: telem_ent = {8'h00, 16'h006C}; // VIDHD_SLOT
        8'd38: telem_ent = {8'h00, 16'h00D0}; // MOUSE_SLOT
        8'd39: telem_ent = {8'h00, 16'h00D4}; // MOUSE_STAT
        8'd40: telem_ent = {8'h00, 16'h00E4}; // U2_SLOT
        8'd41: telem_ent = {8'h00, 16'h00E8}; // U2_STAT
        8'd42: telem_ent = {8'h00, 16'h00FC}; // PRINTER_SLOT
        8'd43: telem_ent = {8'h00, 16'h00D8}; // NSC_CTRL
        8'd44: telem_ent = {8'h00, 16'h0160}; // PANEL_STAT
        8'd45: telem_ent = {8'h00, 16'h0070}; // FB_CTRL
        8'd46: telem_ent = {8'h00, 16'h0074}; // FB_COMPARED
        8'd47: telem_ent = {8'h00, 16'h0078}; // FB_MISMATCH
        8'd48: telem_ent = {8'h00, 16'h007C}; // FB_LAST
        8'd49: telem_ent = {8'h00, 16'h0080}; // FB_LAST2
        8'd50: telem_ent = {8'h00, 16'h0084}; // FB_OTHER
        8'd51: telem_ent = {8'h00, 16'h00C8}; // GAME_STAT
        8'd52: telem_ent = {8'h00, 16'h00CC}; // GAME_STAT2
        8'd53: telem_ent = {8'h00, 16'h00F0}; // AUDIO_CTRL
        8'd54: telem_ent = {8'h00, 16'h00F4}; // AUDIO_RATE
        8'd55: telem_ent = {8'h00, 16'h00F8}; // AUDIO_STAT
        8'd56: telem_ent = {8'h00, 16'h0124}; // GS_ADB
        8'd57: telem_ent = {8'h00, 16'h0154}; // GS_CLOCK
        8'd58: telem_ent = {8'h00, 16'h0140}; // DDR3_DBG1
        8'd59: telem_ent = {8'h00, 16'h0144}; // DDR3_DBG2
        8'd60: telem_ent = {8'h00, 16'h0148}; // DDR3_DBG3
        8'd61: telem_ent = {8'h00, 16'h014C}; // DDR3_EYE0
        8'd62: telem_ent = {8'h00, 16'h0150}; // DDR3_EYE1
        8'd63: telem_ent = {8'h00, 16'h016C}; // WIDE_U2_CMDS
        8'd64: telem_ent = {8'h00, 16'h0170}; // WIDE_U2_RX
        8'd65: telem_ent = {8'h00, 16'h0174}; // WIDE_PRN_WRITES
        8'd66: telem_ent = {8'h00, 16'h0178}; // WIDE_HD_EXECS
        8'd67: telem_ent = {8'h00, 16'h017C}; // WIDE_PANEL_DMAS
        8'd68: telem_ent = {8'h00, 16'h0180}; // WIDE_AUDIO_SENT
        8'd69: telem_ent = {8'h30, 16'h0134}; // TOP_STATE
        8'd70: telem_ent = {8'h31, 16'h0134}; // TOP_PC
        8'd71: telem_ent = {8'h32, 16'h0134}; // TOP_ADDR_DOUT
        8'd72: telem_ent = {8'h33, 16'h0134}; // TOP_DBR_DQ
        8'd73: telem_ent = {8'h34, 16'h0134}; // TOP_PRED_DIN
        8'd74: telem_ent = {8'h35, 16'h0134}; // H_RETIRE
        8'd75: telem_ent = {8'h36, 16'h0134}; // H_HELD
        8'd76: telem_ent = {8'h37, 16'h0134}; // H_SETTLE
        8'd77: telem_ent = {8'h38, 16'h0134}; // H_IFILL
        8'd78: telem_ent = {8'h39, 16'h0134}; // H_DFILL
        8'd79: telem_ent = {8'h3A, 16'h0134}; // H_SEQ_FAST
        8'd80: telem_ent = {8'h3B, 16'h0134}; // H_SEQ_BUS
        8'd81: telem_ent = {8'h3C, 16'h0134}; // H_SEQ_NULL
        8'd82: telem_ent = {8'h3D, 16'h0134}; // H_DEC_I
        8'd83: telem_ent = {8'h3E, 16'h0134}; // H_DEC_D
        8'd84: telem_ent = {8'h3F, 16'h0134}; // H_CLOCKS
        8'd85: telem_ent = {8'h00, 16'h0134}; // IL_SLOW_I
        8'd86: telem_ent = {8'h01, 16'h0134}; // IL_CAM_FILLS
        8'd87: telem_ent = {8'h02, 16'h0134}; // IL_SCAN_FILLS
        8'd88: telem_ent = {8'h03, 16'h0134}; // IL_PROMOTES
        8'd89: telem_ent = {8'h04, 16'h0134}; // IL_CAM_SERVES
        8'd90: telem_ent = {8'h05, 16'h0134}; // IL_TGT_SERVES
        8'd91: telem_ent = {8'h06, 16'h0134}; // IL_ACKS
        8'd92: telem_ent = {8'h07, 16'h0134}; // IL_DECL
        8'd93: telem_ent = {8'h08, 16'h0134}; // IL_INST
        8'd94: telem_ent = {8'h09, 16'h0134}; // IL_RESTART
        8'd95: telem_ent = {8'h0A, 16'h0134}; // IL_BLK_OK
        8'd96: telem_ent = {8'h0B, 16'h0134}; // IL_BLK_ROOM
        8'd97: telem_ent = {8'h0C, 16'h0134}; // IL_BLK_KILL
        8'd98: telem_ent = {8'h0D, 16'h0134}; // IL_UNSERV
        8'd99: telem_ent = {8'h0E, 16'h0134}; // IL_STATE
        8'd100: telem_ent = {8'h0F, 16'h0134}; // IL_REVAL_DROP
        8'd101: telem_ent = {8'h10, 16'h0134}; // DL_SERVES
        8'd102: telem_ent = {8'h11, 16'h0134}; // DL_CLAIMS
        8'd103: telem_ent = {8'h12, 16'h0134}; // DL_SPLICES
        8'd104: telem_ent = {8'h13, 16'h0134}; // DL_CAM_SERVES
        8'd105: telem_ent = {8'h14, 16'h0134}; // DL_NULLS
        8'd106: telem_ent = {8'h15, 16'h0134}; // DL_POSTS
        8'd107: telem_ent = {8'h16, 16'h0134}; // DL_POST_WAITS
        8'd108: telem_ent = {8'h17, 16'h0134}; // DL_REV_SERVES
        8'd109: telem_ent = {8'h18, 16'h0134}; // DL_OPROW
        8'd110: telem_ent = {8'h19, 16'h0134}; // DL_DECL
        8'd111: telem_ent = {8'h1A, 16'h0134}; // DL_BLK_OK
        8'd112: telem_ent = {8'h1B, 16'h0134}; // DL_BLK_ROOM
        8'd113: telem_ent = {8'h1C, 16'h0134}; // DL_LR_SERVES
        8'd114: telem_ent = {8'h1D, 16'h0134}; // DL_STATE
        8'd115: telem_ent = {8'h1E, 16'h0134}; // DL_REVAL_DROP
        8'd116: telem_ent = {8'h1F, 16'h0134}; // DL_REVAL_REVIVE
        8'd117: telem_ent = {8'h20, 16'h0134}; // PC_IL_I
        8'd118: telem_ent = {8'h21, 16'h0134}; // PC_IL_D
        8'd119: telem_ent = {8'h22, 16'h0134}; // PC_DECLINE
        8'd120: telem_ent = {8'h23, 16'h0134}; // PC_IV_BLOCK
        8'd121: telem_ent = {8'h24, 16'h0134}; // PC_HIT_UC
        8'd122: telem_ent = {8'h25, 16'h0134}; // PC_LAND_CLASH
        8'd123: telem_ent = {8'h26, 16'h0134}; // PC_PPN_CLASH
        8'd124: telem_ent = {8'h27, 16'h0134}; // PC_STATE
        8'd125: telem_ent = {8'h28, 16'h0134}; // PC_HITS
        8'd126: telem_ent = {8'h29, 16'h0134}; // PC_MISSES
        8'd127: telem_ent = {8'h2A, 16'h0134}; // PC_MEM_FILLS
        8'd128: telem_ent = {8'h2B, 16'h0134}; // PC_MEM_FLUSHES
        8'd129: telem_ent = {8'h2C, 16'h0134}; // PC_POSTED
        8'd130: telem_ent = {8'h2D, 16'h0134}; // PC_POSTED_MISS
        8'd131: telem_ent = {8'h40, 16'h0134}; // BC_DATA
        8'd132: telem_ent = {8'h41, 16'h0134}; // BC_MRD
        8'd133: telem_ent = {8'h42, 16'h0134}; // BC_MWR
        8'd134: telem_ent = {8'h43, 16'h0134}; // BC_IO
        8'd135: telem_ent = {8'h44, 16'h0134}; // BC_P0
        8'd136: telem_ent = {8'h45, 16'h0134}; // BC_P1
        8'd137: telem_ent = {8'h46, 16'h0134}; // BC_P23
        8'd138: telem_ent = {8'h47, 16'h0134}; // BC_MISS
        8'd139: telem_ent = {8'h48, 16'h0134}; // BC_TAB
        8'd140: telem_ent = {8'h49, 16'h0134}; // BC_TV
        8'd141: telem_ent = {8'h80, 16'h0134}; // OB_CAND
        8'd142: telem_ent = {8'h81, 16'h0134}; // OB_KNOWN
        8'd143: telem_ent = {8'h82, 16'h0134}; // OB_SERVES
        8'd144: telem_ent = {8'h83, 16'h0134}; // OB_ANY
        8'd145: telem_ent = {8'h84, 16'h0134}; // OB_LOADS
        8'd146: telem_ent = {8'h85, 16'h0134}; // OB_STATE
        8'd147: telem_ent = {8'h86, 16'h0134}; // OB_POST_HI
        8'd148: telem_ent = {8'h87, 16'h0134}; // OB_IO_SERVES
        8'd149: telem_ent = {8'h00, 16'h008C}; // ACCEL_CTRL
        8'd150: telem_ent = {8'h00, 16'h0090}; // ACCEL_STAT
        8'd151: telem_ent = {8'h00, 16'h0100}; // ACCEL_MAPS
        8'd152: telem_ent = {8'h00, 16'h0104}; // ACCEL_IDROP
        8'd153: telem_ent = {8'h00, 16'h0108}; // ACCEL_IREVIVE
        8'd154: telem_ent = {8'h00, 16'h010C}; // ACCEL_DDROP
        8'd155: telem_ent = {8'h00, 16'h0110}; // ACCEL_DREVIVE
        8'd156: telem_ent = {8'h00, 16'h0098}; // ACCEL_BUS
        8'd157: telem_ent = {8'h00, 16'h009C}; // ACCEL_CYCLES
        8'd158: telem_ent = {8'h00, 16'h00A0}; // ACCEL_WAIT
        8'd159: telem_ent = {8'h00, 16'h00A4}; // ACCEL_TURBO
        8'd160: telem_ent = {8'h00, 16'h00A8}; // ACCEL_DLINE
        8'd161: telem_ent = {8'h00, 16'h0094}; // ACCEL_FAST
        8'd162: telem_ent = {8'h00, 16'h00AC}; // ACCEL_FAST_I
        8'd163: telem_ent = {8'h00, 16'h00B0}; // ACCEL_FAST_DRAM
        8'd164: telem_ent = {8'h00, 16'h00B4}; // ACCEL_FAST_DLC
        8'd165: telem_ent = {8'h00, 16'h00B8}; // ACCEL_FAST_DROM
        8'd166: telem_ent = {8'h00, 16'h00BC}; // ACCEL_FAST_DCX
        8'd167: telem_ent = {8'h00, 16'h00C0}; // ACCEL_FAST_WR
        8'd168: telem_ent = {8'h00, 16'h00C4}; // ACCEL_FAST_KBD
        8'd169: telem_ent = {8'h00, 16'h0128}; // ACCEL_CORE_CYC
        8'd170: telem_ent = {8'h00, 16'h012C}; // ACCEL_BUS_CYC
        default: telem_ent = 24'h000000;
    endcase
endfunction
