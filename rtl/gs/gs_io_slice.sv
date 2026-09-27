`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_io_slice - rtl/gs/gs_io.sv behind a REGISTER SLICE: one register on every
// signal that crosses its boundary, so every wire between it and the rest of
// the card runs flop to flop and the placer may put the chipset (the ADB
// micro, the IWM, the DOC, the clock) anywhere a clock's worth of wire reaches -
// out of the region the 65816, its L1s, the L2 and the RISC-V engine need
// (the user, 2026-09-27: the slow devices, where latency costs nothing).
//
// WHAT CHANGES, AND WHAT DOES NOT.  gs_io sees exactly the input sequence it
// saw before, one clock later - every input is delayed alike - so everything
// it computes, and the order of it, is unchanged; the card sees its outputs
// two clocks later than before.  The top makes up for the two clocks where
// they matter (rtl/gs/gs_top.sv, rtl/gs/accel_seq.sv SLOW_LAT):
//   * the CLAIM is decoded in the top from the live address (gs_iopage.vh's
//     gs_io_mine, the same function gs_io uses) - gs_io's own claim and
//     u_claim are not brought out;
//   * a read of gs_io waits for its byte to come back through the slice, and
//     after any gs_io op the dispatcher holds until the op's effects - a
//     stall, the fast-read vector, the keyboard byte - are through it too;
//   * the data front's fast reads (io_quiet) stand off the same two clocks
//     longer after an internalized op.
// NOT SLICED: clk, rst, and the 3.5" drive's seek-notice handshake to the link
// (fd35_word / fd35_valid / fd35_take: a valid held until taken, which two
// registers would make the link take twice - the link sits beside the IWM).
//
// Written from gs_io's port list; a port added to gs_io must be added here -
// sim/lint.sh names the unconnected pin (PINMISSING) if it is not.
//////////////////////////////////////////////////////////////////////////////////
module gs_io_slice #(
    parameter adb_keymap = "adb_keymap.hex"
) (
    input  wire  clk,
    input  wire  rst,
    input  wire  res_sync,
    input  wire  [7:0] u_bank,
    input  wire  [15:0] u_addr,
    input  wire  u_rw,
    input  wire  [7:0] u_wdata,
    input  wire  u_commit,
    input  wire  [7:0] gs_shadow,
    input  wire  [7:0] gs_cyareg,
    input  wire  [7:0] gs_sltrom,
    input  wire  [7:0] gs_state,
    input  wire  [7:0] stat_byte,
    input  wire  [15:0] stat_bits,
    input  wire  [6:0] kbd_low,
    input  wire  vbl,
    input  wire  [8:0] scan_v,
    input  wire  [6:0] scan_h,
    input  wire  mw_stb,
    input  wire  [7:0] mw_bank,
    input  wire  [15:0] mw_addr,
    input  wire  [7:0] mw_byte,
    input  wire  [31:0] seed_time,
    output logic [3:0] border,
    output logic [7:0] rd_byte,
    output logic [247:0] fr_vec,
    input  wire  loc_valid,
    input  wire  [6:0] loc_code,
    input  wire  loc_up,
    input  wire  [7:0] loc_mods,
    input  wire  [7:0] live_mods,
    input  wire  [5:0] pb_sel,
    input  wire  msg_valid,
    input  wire  [7:0] msg_type,
    input  wire  [15:0] msg_free,
    input  wire  [7:0] msg_len,
    input  wire  [31:0] pay_data,
    input  wire  pay_valid,
    output logic bram_ok,
    input  wire  [5:0] clk_dbg_idx,
    output logic [31:0] clk_dbg_word,
    output logic [31:0] clk_stat,
    input  wire  frame_tick,
    input  wire  wall_tick,
    input  wire  c000_ext,
    output logic [7:0] c000_byte,
    output logic signed [20:0] doc_l,
    output logic signed [20:0] doc_r,
    output logic irq,
    output logic [31:0] adb_stat,
    input  wire  core_tick,
    output wire  [31:0] fd35_word,
    output wire  fd35_valid,
    input  wire  fd35_take,
    input  wire  fd35_inserted,
    input  wire  fd35_wp,
    input  wire  fd35_late_clr,
    input  wire  fd35_fill_clr,
    output logic fd35_stale,
    output logic [6:0] fd35_track,
    output logic fd35_side,
    output logic fd35_motor35,
    output logic fd35_motor,
    output logic [7:0] fd35_ctl,
    output logic [7:0] fd35_seeks,
    output logic [7:0] fd35_late,
    output logic [31:0] fd35_wstat,
    output logic [15:0] fd35_fill_max,
    output logic fd35_stall,
    input  wire  [1:0] fd525_inserted,
    input  wire  [1:0] fd525_wp,
    input  wire  [25:0] fd525_cell,
    input  wire  [11:0] fd525_tracks,
    input  wire  [1:0] fd525_flush,
    output logic [1:0] fd525_stale,
    output logic [1:0] fd525_dirty,
    output logic [13:0] fd525_phase
);
    logic res_sync_s;
    logic [7:0] u_bank_s;
    logic [15:0] u_addr_s;
    logic u_rw_s;
    logic [7:0] u_wdata_s;
    logic u_commit_s;
    logic [7:0] gs_shadow_s;
    logic [7:0] gs_cyareg_s;
    logic [7:0] gs_sltrom_s;
    logic [7:0] gs_state_s;
    logic [7:0] stat_byte_s;
    logic [15:0] stat_bits_s;
    logic [6:0] kbd_low_s;
    logic vbl_s;
    logic [8:0] scan_v_s;
    logic [6:0] scan_h_s;
    logic mw_stb_s;
    logic [7:0] mw_bank_s;
    logic [15:0] mw_addr_s;
    logic [7:0] mw_byte_s;
    logic [31:0] seed_time_s;
    wire  [3:0] border_s;
    wire  [7:0] rd_byte_s;
    wire  [247:0] fr_vec_s;
    logic loc_valid_s;
    logic [6:0] loc_code_s;
    logic loc_up_s;
    logic [7:0] loc_mods_s;
    logic [7:0] live_mods_s;
    logic [5:0] pb_sel_s;
    logic msg_valid_s;
    logic [7:0] msg_type_s;
    logic [15:0] msg_free_s;
    logic [7:0] msg_len_s;
    logic [31:0] pay_data_s;
    logic pay_valid_s;
    wire  bram_ok_s;
    logic [5:0] clk_dbg_idx_s;
    wire  [31:0] clk_dbg_word_s;
    wire  [31:0] clk_stat_s;
    logic frame_tick_s;
    logic wall_tick_s;
    logic c000_ext_s;
    wire  [7:0] c000_byte_s;
    wire  signed [20:0] doc_l_s;
    wire  signed [20:0] doc_r_s;
    wire  irq_s;
    wire  [31:0] adb_stat_s;
    logic core_tick_s;
    logic fd35_inserted_s;
    logic fd35_wp_s;
    logic fd35_late_clr_s;
    logic fd35_fill_clr_s;
    wire  fd35_stale_s;
    wire  [6:0] fd35_track_s;
    wire  fd35_side_s;
    wire  fd35_motor35_s;
    wire  fd35_motor_s;
    wire  [7:0] fd35_ctl_s;
    wire  [7:0] fd35_seeks_s;
    wire  [7:0] fd35_late_s;
    wire  [31:0] fd35_wstat_s;
    wire  [15:0] fd35_fill_max_s;
    wire  fd35_stall_s;
    logic [1:0] fd525_inserted_s;
    logic [1:0] fd525_wp_s;
    logic [25:0] fd525_cell_s;
    logic [11:0] fd525_tracks_s;
    logic [1:0] fd525_flush_s;
    wire  [1:0] fd525_stale_s;
    wire  [1:0] fd525_dirty_s;
    wire  [13:0] fd525_phase_s;
    always_ff @(posedge clk) begin
        res_sync_s <= res_sync;
        u_bank_s <= u_bank;
        u_addr_s <= u_addr;
        u_rw_s <= u_rw;
        u_wdata_s <= u_wdata;
        u_commit_s <= u_commit;
        gs_shadow_s <= gs_shadow;
        gs_cyareg_s <= gs_cyareg;
        gs_sltrom_s <= gs_sltrom;
        gs_state_s <= gs_state;
        stat_byte_s <= stat_byte;
        stat_bits_s <= stat_bits;
        kbd_low_s <= kbd_low;
        vbl_s <= vbl;
        scan_v_s <= scan_v;
        scan_h_s <= scan_h;
        mw_stb_s <= mw_stb;
        mw_bank_s <= mw_bank;
        mw_addr_s <= mw_addr;
        mw_byte_s <= mw_byte;
        seed_time_s <= seed_time;
        border <= border_s;
        rd_byte <= rd_byte_s;
        fr_vec <= fr_vec_s;
        loc_valid_s <= loc_valid;
        loc_code_s <= loc_code;
        loc_up_s <= loc_up;
        loc_mods_s <= loc_mods;
        live_mods_s <= live_mods;
        pb_sel_s <= pb_sel;
        msg_valid_s <= msg_valid;
        msg_type_s <= msg_type;
        msg_free_s <= msg_free;
        msg_len_s <= msg_len;
        pay_data_s <= pay_data;
        pay_valid_s <= pay_valid;
        bram_ok <= bram_ok_s;
        clk_dbg_idx_s <= clk_dbg_idx;
        clk_dbg_word <= clk_dbg_word_s;
        clk_stat <= clk_stat_s;
        frame_tick_s <= frame_tick;
        wall_tick_s <= wall_tick;
        c000_ext_s <= c000_ext;
        c000_byte <= c000_byte_s;
        doc_l <= doc_l_s;
        doc_r <= doc_r_s;
        irq <= irq_s;
        adb_stat <= adb_stat_s;
        core_tick_s <= core_tick;
        fd35_inserted_s <= fd35_inserted;
        fd35_wp_s <= fd35_wp;
        fd35_late_clr_s <= fd35_late_clr;
        fd35_fill_clr_s <= fd35_fill_clr;
        fd35_stale <= fd35_stale_s;
        fd35_track <= fd35_track_s;
        fd35_side <= fd35_side_s;
        fd35_motor35 <= fd35_motor35_s;
        fd35_motor <= fd35_motor_s;
        fd35_ctl <= fd35_ctl_s;
        fd35_seeks <= fd35_seeks_s;
        fd35_late <= fd35_late_s;
        fd35_wstat <= fd35_wstat_s;
        fd35_fill_max <= fd35_fill_max_s;
        fd35_stall <= fd35_stall_s;
        fd525_inserted_s <= fd525_inserted;
        fd525_wp_s <= fd525_wp;
        fd525_cell_s <= fd525_cell;
        fd525_tracks_s <= fd525_tracks;
        fd525_flush_s <= fd525_flush;
        fd525_stale <= fd525_stale_s;
        fd525_dirty <= fd525_dirty_s;
        fd525_phase <= fd525_phase_s;
    end

    gs_io #(.adb_keymap (adb_keymap)) u_chip (
        .clk            (clk),
        .rst            (rst),
        .res_sync       (res_sync_s),
        .u_bank         (u_bank_s),
        .u_addr         (u_addr_s),
        .u_rw           (u_rw_s),
        .u_wdata        (u_wdata_s),
        .u_commit       (u_commit_s),
        .gs_shadow      (gs_shadow_s),
        .gs_cyareg      (gs_cyareg_s),
        .gs_sltrom      (gs_sltrom_s),
        .gs_state       (gs_state_s),
        .stat_byte      (stat_byte_s),
        .stat_bits      (stat_bits_s),
        .kbd_low        (kbd_low_s),
        .vbl            (vbl_s),
        .scan_v         (scan_v_s),
        .scan_h         (scan_h_s),
        .mw_stb         (mw_stb_s),
        .mw_bank        (mw_bank_s),
        .mw_addr        (mw_addr_s),
        .mw_byte        (mw_byte_s),
        .seed_time      (seed_time_s),
        .border         (border_s),
        .rd_byte        (rd_byte_s),
        .fr_vec         (fr_vec_s),
        .loc_valid      (loc_valid_s),
        .loc_code       (loc_code_s),
        .loc_up         (loc_up_s),
        .loc_mods       (loc_mods_s),
        .live_mods      (live_mods_s),
        .pb_sel         (pb_sel_s),
        .msg_valid      (msg_valid_s),
        .msg_type       (msg_type_s),
        .msg_free       (msg_free_s),
        .msg_len        (msg_len_s),
        .pay_data       (pay_data_s),
        .pay_valid      (pay_valid_s),
        .bram_ok        (bram_ok_s),
        .clk_dbg_idx    (clk_dbg_idx_s),
        .clk_dbg_word   (clk_dbg_word_s),
        .clk_stat       (clk_stat_s),
        .frame_tick     (frame_tick_s),
        .wall_tick      (wall_tick_s),
        .c000_ext       (c000_ext_s),
        .c000_byte      (c000_byte_s),
        .doc_l          (doc_l_s),
        .doc_r          (doc_r_s),
        .irq            (irq_s),
        .adb_stat       (adb_stat_s),
        .core_tick      (core_tick_s),
        .fd35_word      (fd35_word),
        .fd35_valid     (fd35_valid),
        .fd35_take      (fd35_take),
        .fd35_inserted  (fd35_inserted_s),
        .fd35_wp        (fd35_wp_s),
        .fd35_late_clr  (fd35_late_clr_s),
        .fd35_fill_clr  (fd35_fill_clr_s),
        .fd35_stale     (fd35_stale_s),
        .fd35_track     (fd35_track_s),
        .fd35_side      (fd35_side_s),
        .fd35_motor35   (fd35_motor35_s),
        .fd35_motor     (fd35_motor_s),
        .fd35_ctl       (fd35_ctl_s),
        .fd35_seeks     (fd35_seeks_s),
        .fd35_late      (fd35_late_s),
        .fd35_wstat     (fd35_wstat_s),
        .fd35_fill_max  (fd35_fill_max_s),
        .fd35_stall     (fd35_stall_s),
        .fd525_inserted (fd525_inserted_s),
        .fd525_wp       (fd525_wp_s),
        .fd525_cell     (fd525_cell_s),
        .fd525_tracks   (fd525_tracks_s),
        .fd525_flush    (fd525_flush_s),
        .fd525_stale    (fd525_stale_s),
        .fd525_dirty    (fd525_dirty_s),
        .fd525_phase    (fd525_phase_s),
        .q_addr         (24'd0),
        .q_rw           (1'b1),
        .claim          (unused_claim),
        .u_claim        (unused_uclaim)
    );
    wire unused_claim, unused_uclaim;
    wire unused = &{1'b0, unused_claim, unused_uclaim};
endmodule
