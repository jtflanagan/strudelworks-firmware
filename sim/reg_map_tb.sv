`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// reg_map_tb - the whole register path, from a host message to a reply on the
// wire: ft601_msg_rx -> reg_bridge -> wb_regfile -> reply_stream -> msg_arb.
//
// The parts are individually simple and the interesting failures are all in the
// seams, so this drives the real modules end to end rather than any of them in
// isolation.  Two properties are worth more than the rest:
//
//   * a read comes back with the right value AND the address it answered, so a
//     host can match replies to requests
//   * a reply NEVER lands inside another message.  The link has no sync word and
//     deliberately cannot resynchronise, so an interleaved word is not a glitch
//     the parser recovers from - it is a stream that stays plausible and wrong
//     from that point on.  That is the one this file exists for.
//////////////////////////////////////////////////////////////////////////////////

module reg_map_tb;

    localparam integer BUILD_DATE = 20260823;
    localparam integer BUILD_TIME = 143900;

    localparam [7:0] T_REG_READ  = 8'h14;
    localparam [7:0] T_REG_WRITE = 8'h15;
    localparam [7:0] T_REG_VALUE = 8'h16;
    localparam [7:0] T_BUS_EVENTS = 8'h12;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    integer errors = 0;
    reg [7:0] latches_before;

    // ---- host -> card: a little FIFO the parser reads from --------------------
    reg  [31:0] rx_mem [0:255];
    integer     rx_wr = 0, rx_rd = 0;
    wire        rx_empty = (rx_rd >= rx_wr);
    wire [31:0] rx_dout  = rx_empty ? 32'd0 : rx_mem[rx_rd];
    wire        rx_rd_en;
    always @(posedge clk) if (rx_rd_en && !rx_empty) rx_rd <= rx_rd + 1;

    task push_word(input [31:0] w);
        begin rx_mem[rx_wr] = w; rx_wr = rx_wr + 1; end
    endtask

    // One clean RES' assertion and release, the way the motherboard does it:
    // held long enough that anything happening inside it is invisible.
    task pulse_reset_line;
        begin
            apple_res_sync = 1'b0;
            repeat (8) @(posedge clk);
            apple_res_sync = 1'b1;
            repeat (8) @(posedge clk);
        end
    endtask

    function [31:0] hdr(input [7:0] t, input [7:0] len, input [15:0] free);
        hdr = {free, t, len};
    endfunction

    // ---- DUTs ---------------------------------------------------------------
    wire        msg_valid, pay_valid, frame_error;
    wire [7:0]  msg_type, msg_len;
    wire [15:0] msg_free;
    wire [31:0] pay_data;

    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .frame_error (frame_error)
    );

    wire        wb_cyc, wb_stb, wb_we, wb_ack, wb_stall;
    wire [31:0] wb_adr, wb_dat_w, wb_dat_r;
    wire [3:0]  wb_sel;
    wire [31:0] rsp_addr, rsp_data;
    wire        rsp_valid, rsp_take;

    reg_bridge u_bridge (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we),
        .wb_adr (wb_adr), .wb_dat_w (wb_dat_w), .wb_sel (wb_sel),
        .wb_ack (wb_ack), .wb_stall (wb_stall), .wb_dat_r (wb_dat_r),
        .rsp_addr (rsp_addr), .rsp_data (rsp_data),
        .rsp_valid (rsp_valid), .rsp_take (rsp_take)
    );

    // CAN_MASTER is 1 here so the latch can be exercised.  The snoop top builds
    // it with 0; case 8 below covers that side too, with a second instance.
    reg  apple_res_sync = 1'b1;      // active low, idle high
    wire cpu_source_active;
    wire [2:0] mb_slot_active;
    // The boot hold's side of BOOT_HOLD: the tb plays the hold itself.
    wire boot_arm, boot_release;
    // The buttons' side of BUTTONS: the tb plays pb_inject.
    wire [5:0] pb_override;
    reg  [2:0] pb_hw = 3'd0;
    reg  boot_held = 1'b0;
    reg  hold_runtime = 1'b0;
    integer release_pulses = 0;
    always @(posedge clk) if (boot_release) release_pulses = release_pulses + 1;
    // The runtime menu's side of MENU_HOLD.
    wire       menu_en, menu_trigger;
    wire [6:0] menu_hotkey;
    integer trigger_pulses = 0;
    always @(posedge clk) if (menu_trigger) trigger_pulses = trigger_pulses + 1;

    // The hard disk's side of HD_SLOT: the tb plays the disk.
    wire [2:0] hd_slot_active;
    wire       res_drive;
    reg        hd_rom_loaded = 1'b0, hd_busy = 1'b0;
    reg  [7:0] hd_execs = 8'd0;
    // The floppy's side of FD_SLOT, FD_DRIVE1/2 and FD_STAT: the tb plays
    // the controller.
    wire [2:0]  fd_slot_active;
    wire [1:0]  fd_inserted, fd_wp, fd_flush;
    wire [25:0] fd_nibbles;
    wire [11:0] fd_tracks;
    wire        fd_late_clr, fd_fill_clr;
    reg         fd_rom_loaded = 1'b0;
    reg  [7:0]  fd_seeks = 8'd0, fd_late = 8'd0;
    reg  [1:0]  fd_stale = 2'd0, fd_dirty = 2'd0;
    reg  [13:0] fd_phase = 14'd0;
    reg  [3:0]  fd_ctl = 4'd0;
    reg  [15:0] fd_fill_max = 16'd0;
    integer     fd_flush_pulses = 0, fd_late_clrs = 0, fd_fill_clrs = 0;
    always @(posedge clk) begin
        if (fd_flush[0]) fd_flush_pulses = fd_flush_pulses + 1;
        if (fd_flush[1]) fd_flush_pulses = fd_flush_pulses + 1;
        if (fd_late_clr) fd_late_clrs = fd_late_clrs + 1;
        if (fd_fill_clr) fd_fill_clrs = fd_fill_clrs + 1;
    end
    // Keyboard injection's side of KBD_INJECT and KBD_CTRL: the tb plays
    // kbd_inject.  The flags are {touched, seen, strobe}, the counts
    // {replaced, flushed, taken, pressed}.
    wire       kbd_press, kbd_drop, kbd_lock, kbd_notify;
    wire [6:0] kbd_press_key;
    reg  [2:0]  kbd_flags  = 3'd0;
    reg  [31:0] kbd_counts = 32'd0;
    reg  [6:0]  kbd_resolved_key = 7'd0;
    reg         kbd_changed = 1'b0;
    // The VBL lock's side of VBL_CTRL/STAT/POS: the tb plays vbl_lock.
    wire        vbl_start, vbl_probe, vbl_notify;
    wire [15:0] vbl_probe_addr;
    reg  [3:0]  vbl_state = 4'd0, vbl_err = 4'd0;
    reg         vbl_locked = 1'b0, vbl_pal = 1'b0, vbl_busy = 1'b0;
    reg  [31:0] vbl_stat = 32'd0, vbl_pos = 32'd0;
    integer     start_pulses = 0, probe_pulses = 0;
    always @(posedge clk) begin
        if (vbl_start) start_pulses = start_pulses + 1;
        if (vbl_probe) probe_pulses = probe_pulses + 1;
    end
    integer    press_pulses = 0, drop_pulses = 0;
    reg  [6:0] last_pressed = 7'd0;
    always @(posedge clk) begin
        if (kbd_press) begin press_pulses = press_pulses + 1; last_pressed = kbd_press_key; end
        if (kbd_drop)  drop_pulses = drop_pulses + 1;
    end

    wire [2:0] mem_serve;
    wire       mem_cnt_clr, mem_inval;
    integer    mem_cnt_clrs = 0, mem_invals = 0;
    always @(posedge clk) begin
        if (mem_cnt_clr) mem_cnt_clrs = mem_cnt_clrs + 1;
        if (mem_inval)   mem_invals = mem_invals + 1;
    end

    wb_regfile #(.BUILD_DATE (BUILD_DATE), .BUILD_TIME (BUILD_TIME),
                 .CAN_MASTER (1'b1)) u_regs (
        .clk (clk), .rst (rst),
        .apple_res_sync (apple_res_sync), .cpu_source_active (cpu_source_active),
        .mb_slot_active (mb_slot_active),
        .boot_arm (boot_arm), .boot_release (boot_release), .boot_held (boot_held),
        .hold_runtime (hold_runtime),
        .menu_en (menu_en), .menu_hotkey (menu_hotkey),
        .menu_trigger (menu_trigger),
        .pb_override (pb_override), .pb_hw (pb_hw),
        .hd_slot_active (hd_slot_active), .hd_rom_loaded (hd_rom_loaded),
        .hd_busy (hd_busy), .hd_execs (hd_execs), .res_drive (res_drive),
        .fd_slot_active (fd_slot_active), .fd_rom_loaded (fd_rom_loaded),
        .fd_seeks (fd_seeks), .fd_inserted (fd_inserted), .fd_wp (fd_wp),
        .fd_nibbles (fd_nibbles), .fd_tracks (fd_tracks), .fd_flush (fd_flush),
        .fd_stale (fd_stale), .fd_dirty (fd_dirty), .fd_phase (fd_phase),
        .fd_ctl (fd_ctl), .fd_late (fd_late), .fd_fill_max (fd_fill_max),
        .fd_late_clr (fd_late_clr), .fd_fill_clr (fd_fill_clr),
        .kbd_press (kbd_press), .kbd_press_key (kbd_press_key), .kbd_drop (kbd_drop),
        .kbd_lock (kbd_lock), .kbd_notify (kbd_notify),
        .kbd_flags (kbd_flags), .kbd_counts (kbd_counts),
        .vbl_start (vbl_start), .vbl_probe (vbl_probe), .vbl_notify (vbl_notify),
        .vbl_probe_addr (vbl_probe_addr),
        .vbl_state (vbl_state), .vbl_locked (vbl_locked), .vbl_pal (vbl_pal),
        .vbl_busy (vbl_busy), .vbl_err (vbl_err),
        .vbl_stat (vbl_stat), .vbl_pos (vbl_pos),
        .mem_serve (mem_serve), .mem_cnt_clr (mem_cnt_clr), .mem_inval (mem_inval),
        .mem_sw (12'hA5C), .mem_image_ready (1'b1),
        .mem_invalidating (1'b0), .mem_rom_loaded (1'b1),
        .mem_late_fills (8'd0), .mem_fifo_drops (8'd0),
        .mem_hits (32'h0000_1111), .mem_misses (32'h0000_0022),
        .mem_mismatch (32'h0000_0003), .mem_served (32'h0000_0444),
        .mem_last (32'h1234_5C3A),
        .mem_log_sel (), .mem_log_rd (64'hDEAD_BEEF_1234_5678),
        .mem_log_count (12'd7), .mem_log_overflow (1'b1), .mem_stk_rd (32'hCAFE_F00D),
        .mem_watch_en (), .mem_watch_addr (),
        .ring_status (32'h0200_1234),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we),
        .wb_adr (wb_adr), .wb_dat_w (wb_dat_w), .wb_sel (wb_sel),
        .wb_ack (wb_ack), .wb_stall (wb_stall), .wb_dat_r (wb_dat_r)
    );

    // ---- card -> host: capture whatever msg_arb emits -----------------------
    // The capture's port, played by the tb: a word offered on a level and held
    // until taken, which is the shape bus_event_capture now has.
    reg  [31:0] src_data  = 32'd0;
    reg         src_valid = 1'b0;
    wire        src_take;
    reg         src_took  = 1'b0;
    always @(posedge clk) src_took <= src_valid && src_take;

    // Offer one word and return once it has been taken - one cycle when the
    // arbiter is ours, longer when it is someone else's.
    task offer(input [31:0] w);
        begin
            src_data  = w;
            src_valid = 1'b1;
            @(negedge clk);
            while (!src_took) @(negedge clk);
            src_valid = 1'b0;
        end
    endtask

    wire [31:0] tx_data;
    wire        out_valid;
    reg         tx_full = 1'b0;
    wire        tx_push = out_valid && !tx_full;
    // A notice, offered the way card_link offers one: held until taken.
    reg  [31:0] note_word  = 32'd0;
    reg         note_valid = 1'b0;
    wire        note_take;
    integer     note_takes = 0;
    always @(posedge clk) if (note_take) begin
        note_valid = 1'b0;
        note_takes = note_takes + 1;
    end

    // An application message, offered the way hd_card offers one: a word at
    // a time, the next presented the cycle after a take.
    reg  [31:0] aux_mem [0:15];
    integer     aux_n = 0;        // words in the message, header included
    integer     aux_i = 0;        // the one being offered
    wire        aux_valid = (aux_i < aux_n);
    wire [31:0] aux_word  = aux_valid ? aux_mem[aux_i] : 32'd0;
    wire        aux_take;
    integer     aux_takes = 0;
    always @(posedge clk) if (aux_take) begin
        aux_i = aux_i + 1;
        aux_takes = aux_takes + 1;
    end

    // The KBD_EVENT notice, the real module: fed by the tb's kbd_changed
    // pulse and the register's notify, its words onto the bus like the rest.
    wire [31:0] kn_word;
    wire        kn_valid, kn_take;
    integer     kn_takes = 0;
    always @(posedge clk) if (kn_take) kn_takes = kn_takes + 1;

    kbd_notice u_kn (
        .clk (clk), .rst (rst),
        .changed (kbd_changed), .notify (kbd_notify),
        .flags ({kbd_lock, kbd_flags}), .resolved_key (kbd_resolved_key),
        .counts (kbd_counts),
        .word (kn_word), .valid (kn_valid), .take (kn_take)
    );

    // The masters in card_link's order: reply, the CPU_HOLD notice, the
    // KBD_EVENT notice, application, capture - each a stream through
    // msg_master onto the bus; the tb plays the slave.
    wire [4:0]   ma_valid, ma_take;
    wire [159:0] ma_word;

    reply_stream u_reply (
        .clk (clk), .rst (rst),
        .rsp_addr (rsp_addr), .rsp_data (rsp_data),
        .rsp_valid (rsp_valid), .rsp_take (rsp_take),
        .word (ma_word[31:0]), .valid (ma_valid[0]), .take (ma_take[0])
    );
    assign ma_word[63:32]   = note_word;  assign ma_valid[1] = note_valid; assign note_take = ma_take[1];
    assign ma_word[95:64]   = kn_word;    assign ma_valid[2] = kn_valid;   assign kn_take   = ma_take[2];
    assign ma_word[127:96]  = aux_word;   assign ma_valid[3] = aux_valid;  assign aux_take  = ma_take[3];
    assign ma_word[159:128] = src_data;   assign ma_valid[4] = src_valid;  assign src_take  = ma_take[4];

    wire [4:0]   mb_cyc, mb_stb, mb_we, mb_stall, mb_ack;
    wire [159:0] mb_adr, mb_dat;
    wire [19:0]  mb_sel;
    wire         sb_cyc, sb_stb, sb_we;
    wire [31:0]  sb_adr, sb_dat;
    wire [3:0]   sb_sel;
    reg          sb_ack = 1'b0;

    genvar gm;
    generate for (gm = 0; gm < 5; gm = gm + 1) begin : g_m
        msg_master u_m (
            .clk (clk), .rst (rst),
            .word (ma_word[gm*32 +: 32]), .valid (ma_valid[gm]), .take (ma_take[gm]),
            .cyc (mb_cyc[gm]), .stb (mb_stb[gm]), .we (mb_we[gm]),
            .adr (mb_adr[gm*32 +: 32]), .dat (mb_dat[gm*32 +: 32]), .sel (mb_sel[gm*4 +: 4]),
            .stall (mb_stall[gm]), .ack (mb_ack[gm])
        );
    end endgenerate

    msg_arb #(.N (5)) u_arb (
        .clk (clk), .rst (rst),
        .m_cyc (mb_cyc), .m_stb (mb_stb), .m_we (mb_we), .m_adr (mb_adr),
        .m_dat (mb_dat), .m_sel (mb_sel), .m_stall (mb_stall), .m_ack (mb_ack),
        .s_cyc (sb_cyc), .s_stb (sb_stb), .s_we (sb_we), .s_adr (sb_adr),
        .s_dat (sb_dat), .s_sel (sb_sel), .s_stall (tx_full), .s_ack (sb_ack)
    );
    assign tx_data   = sb_dat;
    assign out_valid = sb_cyc && sb_stb;
    always @(posedge clk) sb_ack <= !rst && sb_cyc && sb_stb && !tx_full;

    reg [31:0] out_mem [0:255];
    integer    out_n = 0;
    always @(posedge clk) if (tx_push && !tx_full) begin
        out_mem[out_n] = tx_data;
        out_n = out_n + 1;
    end

    // ---- helpers ------------------------------------------------------------
    task expect_word(input integer idx, input [31:0] want, input [255:0] what);
        begin
            if (out_mem[idx] !== want) begin
                $display("FAIL: %0s: word %0d = %08x, expected %08x",
                         what, idx, out_mem[idx], want);
                errors = errors + 1;
            end
        end
    endtask

    task do_read(input [31:0] addr);
        begin
            push_word(hdr(T_REG_READ, 8'd1, 16'd0));
            push_word(addr);
            repeat (60) @(posedge clk);
        end
    endtask

    task do_write(input [31:0] addr, input [31:0] data);
        begin
            push_word(hdr(T_REG_WRITE, 8'd2, 16'd0));
            push_word(addr);
            push_word(data);
            repeat (60) @(posedge clk);
        end
    endtask

    integer base;
    integer i;
    integer hdr_at;

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        @(negedge clk);

        $display("reg_map_tb: control registers over Wishbone\n");

        // --- case 1 / read BUILD_DATE ----------------------------------------
        base = out_n;
        do_read(32'h8000_0000);
        if (out_n - base != 3) begin
            $display("FAIL: read reply was %0d word(s), expected 3", out_n - base);
            errors = errors + 1;
        end else begin
            expect_word(base + 0, hdr(T_REG_VALUE, 8'd2, 16'd0), "BUILD_DATE header");
            expect_word(base + 1, 32'h8000_0000, "BUILD_DATE address echo");
            expect_word(base + 2, BUILD_DATE,    "BUILD_DATE value");
            $display("  ok: read 0x80000000 -> %0d", out_mem[base + 2]);
        end

        // --- case 2 / read BUILD_TIME ----------------------------------------
        base = out_n;
        do_read(32'h8000_0004);
        expect_word(base + 1, 32'h8000_0004, "BUILD_TIME address echo");
        expect_word(base + 2, BUILD_TIME,    "BUILD_TIME value");
        $display("  ok: read 0x80000004 -> %0d", out_mem[base + 2]);

        // --- case 3 / a hole in the map --------------------------------------
        // Reads zero and still replies.  A slave that withheld ack here would
        // hang the bridge and the host would see a dead link, not a bad address.
        base = out_n;
        do_read(32'h8000_0040);
        expect_word(base + 2, 32'd0, "unimplemented register reads zero");
        $display("  ok: unimplemented address replies with zero");

        // --- case 4 / outside the register region ----------------------------
        // 0x0000_0000 is DDR3 space, not ours; it must not alias onto register 0.
        base = out_n;
        do_read(32'h0000_0000);
        expect_word(base + 2, 32'd0, "DDR3 space does not alias register 0");
        $display("  ok: address outside the region does not alias BUILD_DATE");

        // --- case 5 / write to a read-only register --------------------------
        // Accepted, discarded, and the reply carries what the register still
        // holds - which is how the host tells the difference without a status.
        base = out_n;
        do_write(32'h8000_0000, 32'hDEAD_BEEF);
        expect_word(base + 1, 32'h8000_0000, "write reply address echo");
        expect_word(base + 2, BUILD_DATE,    "read-only register unchanged by write");
        $display("  ok: write to a read-only register leaves it alone and says so");

        // --- case 5b / RING_STATUS reads back what tx_ring reports -----------
        base = out_n;
        do_read(32'h8000_0024);
        if (out_mem[base+2] !== 32'h0200_1234) begin
            $display("FAIL: RING_STATUS read %08x, expected 02001234", out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: RING_STATUS reads back tx_ring's word");

        // --- case 6 / a reply must not land inside another message -----------
        // The one this file exists for.  A BUS_EVENTS message is streamed while
        // a register read is issued mid-payload; the message must come out whole.
        base = out_n;
        @(negedge clk);
        offer(hdr(T_BUS_EVENTS, 8'd4, 16'd0));
        offer(32'h1111_1111);
        // Request arrives with the payload half emitted.
        push_word(hdr(T_REG_READ, 8'd1, 16'd0));
        push_word(32'h8000_0004);
        offer(32'h2222_2222);
        offer(32'h3333_3333);
        offer(32'h4444_4444);
        repeat (80) @(posedge clk);

        // The five source words must appear consecutively and in order.
        hdr_at = -1;
        for (i = base; i < out_n - 4; i = i + 1) begin
            if (out_mem[i] === hdr(T_BUS_EVENTS, 8'd4, 16'd0)) hdr_at = i;
        end
        if (hdr_at < 0) begin
            $display("FAIL: the BUS_EVENTS message never came out");
            errors = errors + 1;
        end else begin
            expect_word(hdr_at + 1, 32'h1111_1111, "event word 1 follows its header");
            expect_word(hdr_at + 2, 32'h2222_2222, "event word 2");
            expect_word(hdr_at + 3, 32'h3333_3333, "event word 3");
            expect_word(hdr_at + 4, 32'h4444_4444, "event word 4");
            $display("  ok: BUS_EVENTS stayed intact with a reply pending mid-payload");
        end
        // And the reply still arrived, outside it.
        if (out_n - base < 8) begin
            $display("FAIL: the reply was lost, only %0d word(s) out", out_n - base);
            errors = errors + 1;
        end else begin
            $display("  ok: the reply arrived too, %0d word(s) total", out_n - base);
        end

        // --- case 8 / CPU_SOURCE latches on the RES' assertion ---------------
        //
        // The property, not the plumbing: writing the register must NOT hand
        // over the bus.  Only a reset may, and exactly once per assertion
        // however long it is held or however much the line bounces.
        pulse_reset_line;      // start from a known latch count
        if (cpu_source_active !== 1'b0) begin
            $display("FAIL: mastering after a reset with desired=0");
            errors = errors + 1;
        end else $display("  ok: desired=0 latches to not-mastering");

        // Ask for the soft core.  Nothing may happen yet.
        push_word(hdr(T_REG_WRITE, 8'd2, 16'd0));
        push_word(32'h8000_0008);
        push_word(32'h0000_0001);
        repeat (40) @(posedge clk);
        if (cpu_source_active !== 1'b0) begin
            $display("FAIL: the WRITE handed over the bus - it must take a reset");
            errors = errors + 1;
        end else $display("  ok: writing desired=1 does not hand over on its own");

        // Now reset.  This is the moment it may change, and it must.
        pulse_reset_line;
        if (cpu_source_active !== 1'b1) begin
            $display("FAIL: RES' asserted but the soft core did not take the bus");
            errors = errors + 1;
        end else $display("  ok: the reset assertion is what hands over");

        // Read it back and check every field.
        base = out_n;
        push_word(hdr(T_REG_READ, 8'd1, 16'd0));
        push_word(32'h8000_0008);
        repeat (60) @(posedge clk);
        if (out_n - base < 3) begin
            $display("FAIL: no CPU_SOURCE reply");
            errors = errors + 1;
        end else begin
            if (out_mem[base+2][0] !== 1'b1) begin
                $display("FAIL: desired did not read back");  errors = errors + 1;
            end else if (out_mem[base+2][8] !== 1'b1) begin
                $display("FAIL: active did not read back");   errors = errors + 1;
            end else if (out_mem[base+2][16] !== 1'b1) begin
                $display("FAIL: capable should be 1 here");   errors = errors + 1;
            end else if (out_mem[base+2][31:24] === 8'd0) begin
                $display("FAIL: the latch count never moved"); errors = errors + 1;
            end else begin
                $display("  ok: readback desired=1 active=1 capable=1 latches=%0d",
                         out_mem[base+2][31:24]);
            end
        end

        // A bouncing RES' must latch once per assertion, not once per glitch
        // within one.  Held low, further activity changes nothing.
        latches_before = out_mem[base+2][31:24];
        apple_res_sync = 1'b0;
        repeat (4) @(posedge clk);
        repeat (4) @(posedge clk);          // still low: no second edge
        apple_res_sync = 1'b1;
        repeat (8) @(posedge clk);
        base = out_n;
        push_word(hdr(T_REG_READ, 8'd1, 16'd0));
        push_word(32'h8000_0008);
        repeat (60) @(posedge clk);
        if (out_mem[base+2][31:24] !== (latches_before + 8'd1)) begin
            $display("FAIL: a held-low RES' latched %0d times, expected 1",
                     out_mem[base+2][31:24] - latches_before);
            errors = errors + 1;
        end else $display("  ok: one latch per assertion, not per cycle held");

        // --- case 9 / MB_SLOT follows the same latched contract --------------
        // Same shape as CPU_SOURCE, checked more briefly: the write is an
        // intention, the reset acts on it, and the readback carries both.
        if (mb_slot_active !== 3'd0) begin
            $display("FAIL: the Mockingboard is enabled before anyone asked");
            errors = errors + 1;
        end else $display("  ok: MB_SLOT starts disabled");

        push_word(hdr(T_REG_WRITE, 8'd2, 16'd0));
        push_word(32'h8000_000C);
        push_word(32'h0000_0004);          // slot 4, the Mockingboard's home
        repeat (40) @(posedge clk);
        if (mb_slot_active !== 3'd0) begin
            $display("FAIL: the WRITE enabled the Mockingboard - it must take a reset");
            errors = errors + 1;
        end else $display("  ok: writing MB_SLOT does not enable on its own");

        pulse_reset_line;
        if (mb_slot_active !== 3'd4) begin
            $display("FAIL: RES' asserted but MB_SLOT did not latch to 4");
            errors = errors + 1;
        end else $display("  ok: the reset assertion latches the slot");

        base = out_n;
        push_word(hdr(T_REG_READ, 8'd1, 16'd0));
        push_word(32'h8000_000C);
        repeat (60) @(posedge clk);
        if (out_n - base < 3) begin
            $display("FAIL: no MB_SLOT reply");
            errors = errors + 1;
        end else if (out_mem[base+2][2:0] !== 3'd4 ||
                     out_mem[base+2][10:8] !== 3'd4) begin
            $display("FAIL: MB_SLOT readback %08x, expected desired=4 active=4",
                     out_mem[base+2]);
            errors = errors + 1;
        end else begin
            $display("  ok: readback desired=%0d active=%0d",
                     out_mem[base+2][2:0], out_mem[base+2][10:8]);
        end

        // --- case 10 / BOOT_HOLD: arm is a level, release is a pulse ---------
        // Not reset-latched, unlike its neighbours: arm is "stop at the next
        // boot", and a reset is what it is waiting for, not what applies it.
        if (boot_arm !== 1'b0) begin
            $display("FAIL: the boot hold is armed before anyone asked");
            errors = errors + 1;
        end else $display("  ok: BOOT_HOLD starts unarmed");

        do_write(32'h8000_0010, 32'h0000_0001);           // arm
        if (boot_arm !== 1'b1) begin
            $display("FAIL: writing arm=1 did not arm");
            errors = errors + 1;
        end else $display("  ok: writing arm=1 arms, with no reset needed");
        if (release_pulses !== 0) begin
            $display("FAIL: arming released something");
            errors = errors + 1;
        end

        // The hold engages: held reads back and the count moves.
        boot_held = 1'b1;
        base = out_n;
        do_read(32'h8000_0010);
        if (out_mem[base+2][0] !== 1'b1 || out_mem[base+2][8] !== 1'b1 ||
            out_mem[base+2][16] !== 1'b0 || out_mem[base+2][31:24] !== 8'd1) begin
            $display("FAIL: BOOT_HOLD readback %08x, expected arm=1 held=1 release=0 holds=1",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: readback arm=1 held=1 holds=1 while held");

        // Release keeps arm as written alongside it, and pulses exactly once
        // however long the message took: the hold consumes a pulse, not a
        // level, so a level would release every boot from here on.
        do_write(32'h8000_0010, 32'h0001_0001);           // release, stay armed
        if (release_pulses !== 1) begin
            $display("FAIL: release pulsed %0d time(s), expected exactly 1", release_pulses);
            errors = errors + 1;
        end else if (boot_arm !== 1'b1) begin
            $display("FAIL: the release write disarmed when told to stay armed");
            errors = errors + 1;
        end else $display("  ok: release is one pulse, and arm stays as written");

        boot_held = 1'b0;
        do_write(32'h8000_0010, 32'h0001_0000);           // release AND disarm
        if (boot_arm !== 1'b0 || release_pulses !== 2) begin
            $display("FAIL: release-and-disarm: arm=%0d pulses=%0d", boot_arm, release_pulses);
            errors = errors + 1;
        end else $display("  ok: one write can release and disarm together");

        base = out_n;
        do_read(32'h8000_0010);
        if (out_mem[base+2][16] !== 1'b0 || out_mem[base+2][8] !== 1'b0 ||
            out_mem[base+2][31:24] !== 8'd1) begin
            $display("FAIL: after release BOOT_HOLD reads %08x", out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: release reads back as 0; holds still counts the one");

        // --- case 11 / a notice, like a reply, never lands inside a message --
        // The CPU_HOLD notice is one header-only word injected through the
        // same slot a reply uses, so it has the same obligation.
        base = out_n;
        note_word = {14'd0, 1'b1, 1'b1, 8'h17, 8'd0};      // held, by the runtime door
        @(negedge clk);
        offer(hdr(T_BUS_EVENTS, 8'd3, 16'd0));
        note_valid = 1'b1;                                // arrives mid-payload
        offer(32'hAAAA_0001);
        offer(32'hAAAA_0002);
        offer(32'hAAAA_0003);
        repeat (40) @(posedge clk);

        hdr_at = -1;
        for (i = base; i < out_n - 3; i = i + 1) begin
            if (out_mem[i] === hdr(T_BUS_EVENTS, 8'd3, 16'd0)) hdr_at = i;
        end
        if (hdr_at < 0) begin
            $display("FAIL: the BUS_EVENTS message never came out (notice case)");
            errors = errors + 1;
        end else begin
            expect_word(hdr_at + 1, 32'hAAAA_0001, "event word 1 with a notice pending");
            expect_word(hdr_at + 2, 32'hAAAA_0002, "event word 2 with a notice pending");
            expect_word(hdr_at + 3, 32'hAAAA_0003, "event word 3 with a notice pending");
            if (out_mem[hdr_at + 4] !== {14'd0, 1'b1, 1'b1, 8'h17, 8'd0}) begin
                $display("FAIL: the notice did not follow the message: word %0d = %08x",
                         hdr_at + 4, out_mem[hdr_at + 4]);
                errors = errors + 1;
            end else if (note_takes !== 1) begin
                $display("FAIL: the notice was taken %0d time(s)", note_takes);
                errors = errors + 1;
            end else
                $display("  ok: CPU_HOLD notice waited for the boundary, went out once");
        end

        // --- case 12 / HD_SLOT: latched like MB_SLOT, and never the same slot -
        if (hd_slot_active !== 3'd0) begin
            $display("FAIL: the hard disk is enabled before anyone asked");
            errors = errors + 1;
        end else $display("  ok: HD_SLOT starts disabled");

        // The Mockingboard is latched as slot 4 from case 9.  Ask for the
        // same slot: the write is accepted, the reset refuses to latch it.
        do_write(32'h8000_0014, 32'h0000_0004);
        pulse_reset_line;
        base = out_n;
        do_read(32'h8000_0014);
        if (out_mem[base+2][2:0] !== 3'd4 || out_mem[base+2][10:8] !== 3'd0 ||
            hd_slot_active !== 3'd0) begin
            $display("FAIL: HD_SLOT=4 with MB_SLOT=4 read back %08x, expected desired=4 active=0",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: the disk yields the Mockingboard's slot - active stays 0");

        // A slot of its own: the write alone does nothing, the reset latches.
        do_write(32'h8000_0014, 32'h0000_0007);
        if (hd_slot_active !== 3'd0) begin
            $display("FAIL: the WRITE enabled the disk - it must take a reset");
            errors = errors + 1;
        end else $display("  ok: writing HD_SLOT does not enable on its own");
        pulse_reset_line;
        hd_rom_loaded = 1'b1; hd_busy = 1'b1; hd_execs = 8'd9;
        base = out_n;
        do_read(32'h8000_0014);
        if (hd_slot_active !== 3'd7 ||
            out_mem[base+2][2:0] !== 3'd7 || out_mem[base+2][10:8] !== 3'd7 ||
            out_mem[base+2][16] !== 1'b1 || out_mem[base+2][17] !== 1'b1 ||
            out_mem[base+2][31:24] !== 8'd9) begin
            $display("FAIL: HD_SLOT readback %08x, expected desired=7 active=7 rom=1 busy=1 execs=9",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: readback desired=7 active=7 rom=1 busy=1 execs=9");
        hd_busy = 1'b0;

        // --- case 12b / FD_SLOT, FD_DRIVE1/2, FD_STAT --------------------------
        // The floppy's slot latches like the disk's and yields to BOTH the
        // others; what is in a drive is live, not latched.
        if (fd_slot_active !== 3'd0) begin
            $display("FAIL: the floppy is enabled before anyone asked");
            errors = errors + 1;
        end else $display("  ok: FD_SLOT starts disabled");
        do_write(32'h8000_003C, 32'h0000_0007);       // the disk's slot
        pulse_reset_line;
        if (fd_slot_active !== 3'd0) begin
            $display("FAIL: the floppy took the hard disk's slot");
            errors = errors + 1;
        end else $display("  ok: the floppy yields the hard disk's slot");
        do_write(32'h8000_003C, 32'h0000_0004);       // the Mockingboard's
        pulse_reset_line;
        if (fd_slot_active !== 3'd0) begin
            $display("FAIL: the floppy took the Mockingboard's slot");
            errors = errors + 1;
        end else $display("  ok: ...and the Mockingboard's");
        do_write(32'h8000_003C, 32'h0000_0006);
        if (fd_slot_active !== 3'd0) begin
            $display("FAIL: the WRITE enabled the floppy - it must take a reset");
            errors = errors + 1;
        end
        pulse_reset_line;
        fd_rom_loaded = 1'b1; fd_seeks = 8'd21;
        base = out_n;
        do_read(32'h8000_003C);
        if (fd_slot_active !== 3'd6 ||
            out_mem[base+2][2:0] !== 3'd6 || out_mem[base+2][10:8] !== 3'd6 ||
            out_mem[base+2][16] !== 1'b1 || out_mem[base+2][31:24] !== 8'd21) begin
            $display("FAIL: FD_SLOT readback %08x, expected desired=6 active=6 rom=1 seeks=21",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: FD_SLOT=6 latches at the reset; rom and seeks read back");

        // A disk in drive 1, live: no reset needed.
        do_write(32'h8000_0040, {7'd0, 1'b0, 1'b0, 1'b1, 6'd35, 13'd6384, 1'b0, 1'b1, 1'b1});
        if (fd_inserted !== 2'b01 || fd_wp !== 2'b01 || fd_nibbles[12:0] !== 13'd6384 ||
            fd_tracks[5:0] !== 6'd35 || fd_flush_pulses !== 1) begin
            $display("FAIL: FD_DRIVE1 did not land live: ins=%b wp=%b nib=%0d trk=%0d flush=%0d",
                     fd_inserted, fd_wp, fd_nibbles[12:0], fd_tracks[5:0], fd_flush_pulses);
            errors = errors + 1;
        end else $display("  ok: FD_DRIVE1 lands without a reset, flush is one pulse");
        fd_stale = 2'b01; fd_dirty = 2'b00; fd_phase[6:0] = 7'd33;
        base = out_n;
        do_read(32'h8000_0040);
        if (out_mem[base+2] !== {7'd33, 1'b0, 1'b1, 1'b0, 6'd35, 13'd6384, 1'b0, 1'b1, 1'b1}) begin
            $display("FAIL: FD_DRIVE1 readback %08x", out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: FD_DRIVE1 reads back with stale and the head's phase; flush reads 0");
        if (fd_inserted[1] !== 1'b0 || fd_nibbles[25:13] !== 13'd0) begin
            $display("FAIL: writing drive 1 touched drive 2");
            errors = errors + 1;
        end else $display("  ok: drive 2 untouched");
        do_write(32'h8000_0044, {10'd0, 6'd40, 13'd6656, 1'b0, 1'b0, 1'b1});
        if (fd_inserted !== 2'b11 || fd_nibbles[25:13] !== 13'd6656 || fd_tracks[11:6] !== 6'd40) begin
            $display("FAIL: FD_DRIVE2 did not land");
            errors = errors + 1;
        end else $display("  ok: FD_DRIVE2 is its own drive");

        // FD_STAT: the switches and the two measurements, cleared by W1.
        fd_ctl = 4'b1011; fd_late = 8'd3; fd_fill_max = 16'd1234;
        base = out_n;
        do_read(32'h8000_0048);
        if (out_mem[base+2] !== {16'd1234, 8'd3, 4'd0, 4'b1011}) begin
            $display("FAIL: FD_STAT readback %08x", out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: FD_STAT reads fill_max, late and the switches");
        do_write(32'h8000_0048, 32'h0000_0003);
        if (fd_late_clrs !== 1 || fd_fill_clrs !== 1) begin
            $display("FAIL: FD_STAT W1 bits pulsed %0d/%0d times", fd_late_clrs, fd_fill_clrs);
            errors = errors + 1;
        end else $display("  ok: FD_STAT's two W1 bits are one pulse each");

        // --- case 13 / an application message, whole, and never inside another
        // The hard disk's HD_DATA takes msg_arb's application port: a header and
        // then its payload, streamed a word at a time.  Same obligation as a
        // reply - it waits for the boundary and comes out intact - and one of
        // its own: a source that offers the next word a cycle late must not
        // have a capture word slipped into the gap.
        base = out_n;
        aux_mem[0] = {16'h0200, 8'h1B, 8'd3};    // HD_DATA, 3 payload words
        aux_mem[1] = 32'hD000_0001;
        aux_mem[2] = 32'hD000_0002;
        aux_mem[3] = 32'hD000_0003;
        aux_i = 0;
        @(negedge clk);
        offer(hdr(T_BUS_EVENTS, 8'd3, 16'd0));
        aux_n = 4;                                  // arrives mid-payload
        offer(32'hBBBB_0001);
        offer(32'hBBBB_0002);
        offer(32'hBBBB_0003);
        // And more capture traffic right behind, to try to interleave.  Offered
        // the way bus_event_capture offers it: held until taken, which is not
        // until the arbiter has let the pending HD_DATA through whole.
        repeat (2) @(negedge clk);
        offer(hdr(T_BUS_EVENTS, 8'd2, 16'd0));
        offer(32'hCCCC_0001);
        offer(32'hCCCC_0002);
        repeat (40) @(posedge clk);

        hdr_at = -1;
        for (i = base; i < out_n - 3; i = i + 1) begin
            if (out_mem[i] === hdr(T_BUS_EVENTS, 8'd3, 16'd0)) hdr_at = i;
        end
        if (hdr_at < 0) begin
            $display("FAIL: the BUS_EVENTS message never came out (aux case)");
            errors = errors + 1;
        end else begin
            expect_word(hdr_at + 1, 32'hBBBB_0001, "event word 1 with HD_DATA pending");
            expect_word(hdr_at + 2, 32'hBBBB_0002, "event word 2 with HD_DATA pending");
            expect_word(hdr_at + 3, 32'hBBBB_0003, "event word 3 with HD_DATA pending");
            expect_word(hdr_at + 4, aux_mem[0],    "HD_DATA header follows the message");
            expect_word(hdr_at + 5, aux_mem[1],    "HD_DATA word 1");
            expect_word(hdr_at + 6, aux_mem[2],    "HD_DATA word 2");
            expect_word(hdr_at + 7, aux_mem[3],    "HD_DATA word 3");
            expect_word(hdr_at + 8, hdr(T_BUS_EVENTS, 8'd2, 16'd0),
                        "the next capture message follows HD_DATA whole");
            expect_word(hdr_at + 9, 32'hCCCC_0001, "and its payload");
            if (aux_takes !== 4) begin
                $display("FAIL: HD_DATA words taken %0d times, expected 4", aux_takes);
                errors = errors + 1;
            end else
                $display("  ok: HD_DATA waited for the boundary, went out whole, once");
        end

        // --- case 14 / a boot-hold RELEASE re-latches MB_SLOT and HD_SLOT ----
        // The menu writes the slots during a hold and then releases; the
        // release must copy `desired` into `active` with no reset, or the
        // choice would not reach the boot it lets go.  See docs/BOOT_MENU.md.
        // Fresh desired values, different from what the resets above latched.
        do_write(32'h8000_000C, 32'h0000_0005);           // MB desired = 5
        do_write(32'h8000_0014, 32'h0000_0006);           // HD desired = 6
        if (mb_slot_active !== 3'd4 || hd_slot_active !== 3'd7) begin
            $display("FAIL: writing the slots latched them without a reset: mb=%0d hd=%0d",
                     mb_slot_active, hd_slot_active);
            errors = errors + 1;
        end else $display("  ok: writing MB/HD desired during a hold changes nothing yet");

        do_write(32'h8000_0010, 32'h0001_0001);           // release, stay armed
        if (mb_slot_active !== 3'd5) begin
            $display("FAIL: the release did not re-latch MB_SLOT: active=%0d, expected 5",
                     mb_slot_active);
            errors = errors + 1;
        end else if (hd_slot_active !== 3'd6) begin
            $display("FAIL: the release did not re-latch HD_SLOT: active=%0d, expected 6",
                     hd_slot_active);
            errors = errors + 1;
        end else $display("  ok: the release re-latches both slots from desired, no reset");

        // The clash rule still holds at the release point: the disk yields.
        do_write(32'h8000_0014, 32'h0000_0005);           // HD desired = 5 = MB's
        do_write(32'h8000_0010, 32'h0001_0001);           // release again
        if (hd_slot_active !== 3'd0) begin
            $display("FAIL: HD did not yield MB's slot at the release: active=%0d", hd_slot_active);
            errors = errors + 1;
        end else $display("  ok: the disk still yields the Mockingboard's slot at a release");

        // --- case 15 / RESET: a write pulses RES' low ------------------------
        // The programmatic Ctrl-Reset.  A short custom duration so the tb does
        // not spin: 1 unit = 256 cycles.
        if (res_drive !== 1'b0) begin
            $display("FAIL: RES' driven before anyone asked"); errors = errors + 1;
        end else $display("  ok: RES' idle until asked");

        // 0x0004_0001: cycles field = 4 (1024 cycles), bit 0 = pulse.  Long
        // enough that the pulse is still asserting after do_write's 60-cycle
        // settle, so it can be observed as a level here.
        do_write(32'h8000_0018, 32'h0004_0001);
        if (res_drive !== 1'b1) begin
            $display("FAIL: the write did not start a RES' pulse"); errors = errors + 1;
        end else $display("  ok: writing RESET drives RES' low");

        // It releases on its own after ~1024 cycles.
        for (i = 0; i < 2000 && res_drive !== 1'b0; i = i + 1) @(posedge clk);
        if (res_drive !== 1'b0) begin
            $display("FAIL: RES' pulse never released"); errors = errors + 1;
        end else if (i < 800) begin
            $display("FAIL: RES' pulse was too short (%0d cycles)", i); errors = errors + 1;
        end else $display("  ok: the pulse released itself after ~1024 cycles");

        // The count reads back.
        base = out_n;
        push_word(hdr(T_REG_READ, 8'd1, 16'd0));
        push_word(32'h8000_0018);
        repeat (60) @(posedge clk);
        if (out_mem[base+2][31:24] !== 8'd1) begin
            $display("FAIL: RESET pulse count read back %0d, expected 1", out_mem[base+2][31:24]);
            errors = errors + 1;
        end else $display("  ok: the pulse count reads back");

        // --- case 16 / KBD_INJECT: press and drop are pulses, the rest reads -
        // The host's keypress.  Press carries the key and pulses once per
        // write; drop pulses once per write; both read back as zero, because
        // they are actions.  strobe and taken are the mechanism's, read back.
        if (press_pulses !== 0 || drop_pulses !== 0) begin
            $display("FAIL: KBD_INJECT pulsed before anyone wrote it"); errors = errors + 1;
        end
        do_write(32'h8000_001C, 32'h0000_00C1);           // press 'A' ($41 | press)
        if (press_pulses !== 1 || last_pressed !== 7'h41) begin
            $display("FAIL: press: %0d pulse(s), key $%02x - expected one pulse of $41",
                     press_pulses, last_pressed);
            errors = errors + 1;
        end else if (drop_pulses !== 0) begin
            $display("FAIL: a press also dropped"); errors = errors + 1;
        end else $display("  ok: writing key|press pulses press once, carrying the key");

        // The mechanism says a key is waiting, seen, and three have been
        // pressed; the register says so, and the write-only bits read as
        // zero.  The counts word is {replaced, flushed, taken, pressed}.
        kbd_flags = 3'b011; kbd_counts = 32'h0403_0203;
        base = out_n;
        do_read(32'h8000_001C);
        if (out_mem[base+2] !== 32'h0303_0000) begin
            $display("FAIL: KBD_INJECT readback %08x, expected pressed=3 seen=1 strobe=1, key/press/drop 0",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: readback pressed=3 seen=1 strobe=1; key, press and drop read as 0");

        do_write(32'h8000_001C, 32'h0000_0100);           // drop
        if (drop_pulses !== 1 || press_pulses !== 1) begin
            $display("FAIL: drop: drop=%0d press=%0d pulses, expected 1 and 1", drop_pulses, press_pulses);
            errors = errors + 1;
        end else $display("  ok: writing drop pulses drop once, and does not press");

        // A write of the key without press is nothing.
        do_write(32'h8000_001C, 32'h0000_0042);
        if (press_pulses !== 1 || drop_pulses !== 1) begin
            $display("FAIL: a write without press or drop pulsed something"); errors = errors + 1;
        end else $display("  ok: a key written without press is not a press");
        kbd_flags = 3'd0; kbd_counts = 32'd0;

        // --- case 17 / BUTTONS: a level, held as written, hw read back -------
        if (pb_override !== 6'd0) begin
            $display("FAIL: BUTTONS not all hardware at reset"); errors = errors + 1;
        end else $display("  ok: BUTTONS starts with every button on hardware");
        do_write(32'h8000_0020, 32'h0000_0026);           // PB2 down, PB1 up, PB0 down
        if (pb_override !== 6'h26) begin
            $display("FAIL: BUTTONS write did not land: %02x", pb_override); errors = errors + 1;
        end else $display("  ok: writing BUTTONS sets the three fields");
        pulse_reset_line;
        if (pb_override !== 6'h26) begin
            $display("FAIL: a RES' cleared BUTTONS - Open-Apple-Ctrl-Reset would be impossible");
            errors = errors + 1;
        end else $display("  ok: a RES' leaves the buttons as the host set them");
        pb_hw = 3'b101;
        base = out_n;
        do_read(32'h8000_0020);
        if (out_mem[base+2] !== 32'h0005_0026) begin
            $display("FAIL: BUTTONS readback %08x, expected hw=101 over 0x26", out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: readback carries the hardware's levels in [18:16]");
        do_write(32'h8000_0020, 32'h0000_0000);
        if (pb_override !== 6'd0) begin
            $display("FAIL: BUTTONS did not clear"); errors = errors + 1;
        end else $display("  ok: and back to hardware");
        pb_hw = 3'd0;

        // --- case 18 / KBD_CTRL: lock and notify are levels, the counts read back
        if (kbd_lock !== 1'b0 || kbd_notify !== 1'b0) begin
            $display("FAIL: KBD_CTRL not clear at reset"); errors = errors + 1;
        end else $display("  ok: KBD_CTRL starts unlocked, notify off");
        do_write(32'h8000_0028, 32'h0000_0003);           // lock, notify
        if (kbd_lock !== 1'b1 || kbd_notify !== 1'b1) begin
            $display("FAIL: KBD_CTRL write did not land: lock=%0d notify=%0d", kbd_lock, kbd_notify);
            errors = errors + 1;
        end else $display("  ok: writing KBD_CTRL sets lock and notify");
        pulse_reset_line;
        if (kbd_lock !== 1'b1 || kbd_notify !== 1'b1) begin
            $display("FAIL: a RES' cleared KBD_CTRL - a test that resets the machine would lose its lock");
            errors = errors + 1;
        end else $display("  ok: a RES' leaves the lock and notify as the host set them");
        kbd_flags = 3'b100; kbd_counts = 32'h0403_0203;   // touched; replaced 4 flushed 3 taken 2 pressed 3
        base = out_n;
        do_read(32'h8000_0028);
        if (out_mem[base+2] !== 32'h0403_0283) begin
            $display("FAIL: KBD_CTRL readback %08x, expected replaced=4 flushed=3 taken=2 touched lock notify",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: readback carries replaced, flushed, taken, touched over the two levels");
        kbd_flags = 3'd0; kbd_counts = 32'd0;
        do_write(32'h8000_0028, 32'h0000_0002);           // notify only, for the next case
        if (kbd_lock !== 1'b0 || kbd_notify !== 1'b1) begin
            $display("FAIL: KBD_CTRL did not clear the lock alone"); errors = errors + 1;
        end else $display("  ok: and the lock clears on its own");

        // --- case 19 / the KBD_EVENT notice: two words, whole, a level ------
        // Raised mid-message, it waits for the boundary like the others; the
        // counts move again while it waits, and the words that go out carry
        // the newer value - one notice, the truth at the moment it went.
        kbd_counts = 32'h0000_0101; kbd_resolved_key = 7'h42; kbd_flags = 3'b000;
        base = out_n;
        @(negedge clk);
        offer(hdr(T_BUS_EVENTS, 8'd3, 16'd0));
        @(negedge clk); kbd_changed = 1'b1;
        @(negedge clk); kbd_changed = 1'b0;               // arrives mid-payload
        kbd_counts = 32'h0000_0201;                       // ...and moves again while waiting
        offer(32'hBBBB_0001);
        offer(32'hBBBB_0002);
        offer(32'hBBBB_0003);
        repeat (40) @(posedge clk);

        hdr_at = -1;
        for (i = base; i < out_n - 5; i = i + 1) begin
            if (out_mem[i] === hdr(T_BUS_EVENTS, 8'd3, 16'd0)) hdr_at = i;
        end
        if (hdr_at < 0) begin
            $display("FAIL: the BUS_EVENTS message never came out (kbd notice case)");
            errors = errors + 1;
        end else begin
            expect_word(hdr_at + 1, 32'hBBBB_0001, "event word 1 with a kbd notice pending");
            expect_word(hdr_at + 2, 32'hBBBB_0002, "event word 2 with a kbd notice pending");
            expect_word(hdr_at + 3, 32'hBBBB_0003, "event word 3 with a kbd notice pending");
            expect_word(hdr_at + 4, 32'h4200_1C01, "the KBD_EVENT header: key $42, no flags, len 1");
            expect_word(hdr_at + 5, 32'h0000_0201, "the KBD_EVENT payload: the counts as they are now");
            if (kn_takes !== 2) begin
                $display("FAIL: the kbd notice was taken %0d word(s), expected 2", kn_takes);
                errors = errors + 1;
            end else
                $display("  ok: KBD_EVENT waited for the boundary, went out once, two words, the newer counts");
        end

        // With notify off, a change says nothing.
        do_write(32'h8000_0028, 32'h0000_0000);
        @(negedge clk); kbd_changed = 1'b1;
        @(negedge clk); kbd_changed = 1'b0;
        repeat (40) @(posedge clk);
        if (kn_takes !== 2) begin
            $display("FAIL: a change with notify off sent a notice"); errors = errors + 1;
        end else $display("  ok: with notify off a change sends nothing - silent until asked");

        // --- case 20 / MENU_HOLD: levels, a pulse, and no re-latch on its release
        // The runtime menu's door.  See docs/RUNTIME_MENU.md.
        base = out_n;
        do_read(32'h8000_002C);
        if (out_mem[base+2] !== 32'h0000_003C) begin
            $display("FAIL: MENU_HOLD reads %08x at reset, expected enable=0 hotkey=$1E",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: MENU_HOLD starts shut, hotkey $1E (Ctrl-6)");
        if (menu_en !== 1'b0 || trigger_pulses !== 0) begin
            $display("FAIL: the runtime door is open, or knocked on, before anyone asked");
            errors = errors + 1;
        end
        do_write(32'h8000_002C, 32'h0010_0137);           // trigger, hotkey=$1B, enable; bits 23:16 nothing
        if (menu_en !== 1'b1 || menu_hotkey !== 7'h1B) begin
            $display("FAIL: MENU_HOLD write did not land: en=%0d hotkey=%02x",
                     menu_en, menu_hotkey);
            errors = errors + 1;
        end else if (trigger_pulses !== 1) begin
            $display("FAIL: trigger pulsed %0d time(s), expected exactly 1", trigger_pulses);
            errors = errors + 1;
        end else $display("  ok: enable and hotkey are levels; trigger is one pulse");
        base = out_n;
        do_read(32'h8000_002C);
        if (out_mem[base+2] !== 32'h0000_0037) begin
            $display("FAIL: MENU_HOLD reads %08x, expected hotkey=$1B enable=1, trigger 0, nothing else",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: trigger reads back as 0; the rest as written");

        // A runtime hold engages: BOOT_HOLD says held AND runtime, `menus`
        // counts it, and a release re-latches NOTHING - the program it
        // resumes has already decided about its slots.
        hold_runtime = 1'b1;
        boot_held = 1'b1;
        repeat (2) @(posedge clk);
        base = out_n;
        do_read(32'h8000_0010);
        if (out_mem[base+2][8] !== 1'b1 || out_mem[base+2][9] !== 1'b1) begin
            $display("FAIL: BOOT_HOLD reads %08x during a runtime hold, expected held=1 runtime=1",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: BOOT_HOLD reads held=1 runtime=1 during a runtime hold");
        base = out_n;
        do_read(32'h8000_002C);
        if (out_mem[base+2][31:24] !== 8'd1) begin
            $display("FAIL: MENU_HOLD menus=%0d after one runtime hold", out_mem[base+2][31:24]);
            errors = errors + 1;
        end else $display("  ok: menus counts the runtime hold");
        do_write(32'h8000_000C, 32'h0000_0002);           // MB desired = 2, mid-run
        do_write(32'h8000_0010, 32'h0001_0001);           // release the runtime hold
        if (mb_slot_active === 3'd2) begin
            $display("FAIL: a runtime release re-latched MB_SLOT under a running program");
            errors = errors + 1;
        end else $display("  ok: a runtime release re-latches nothing (MB active still %0d)", mb_slot_active);
        boot_held = 1'b0; hold_runtime = 1'b0;
        repeat (2) @(posedge clk);
        // ...where a BOOT release does.
        boot_held = 1'b1;
        repeat (2) @(posedge clk);
        do_write(32'h8000_0010, 32'h0001_0001);
        if (mb_slot_active !== 3'd2) begin
            $display("FAIL: the boot release after it did not re-latch MB_SLOT: active=%0d", mb_slot_active);
            errors = errors + 1;
        end else $display("  ok: and the next boot release does");
        boot_held = 1'b0;
        do_write(32'h8000_002C, 32'h0000_0000);           // shut again

        // --- case 21 / VBL_CTRL, VBL_STAT, VBL_POS -----------------------------
        // The scanner lock's registers (docs/VBL.md): start and probe are
        // pulses, notify and probe_addr levels, the rest the detector's.
        base = out_n;
        do_read(32'h8000_0030);
        if (out_mem[base+2] !== 32'hC019_0000) begin
            $display("FAIL: VBL_CTRL reads %08x at reset, expected probe_addr=$C019 and nothing else",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: VBL_CTRL starts with probe_addr $C019, notify off");
        do_write(32'h8000_0030, 32'hC054_0005);          // start + notify, probe_addr $C054
        if (start_pulses !== 1 || probe_pulses !== 0) begin
            $display("FAIL: start pulsed %0d time(s), probe %0d; expected 1 and 0", start_pulses, probe_pulses);
            errors = errors + 1;
        end else if (vbl_notify !== 1'b1 || vbl_probe_addr !== 16'hC054) begin
            $display("FAIL: VBL_CTRL write did not land: notify=%0d probe_addr=%04x", vbl_notify, vbl_probe_addr);
            errors = errors + 1;
        end else $display("  ok: start is one pulse; notify and probe_addr are levels");
        vbl_state = 4'd5; vbl_locked = 1'b1; vbl_pal = 1'b1; vbl_busy = 1'b1; vbl_err = 4'd0;
        vbl_stat = 32'h0003_0007; vbl_pos = 32'h0201_4231;
        repeat (2) @(posedge clk);
        base = out_n;
        do_read(32'h8000_0030);
        if (out_mem[base+2] !== 32'hC054_0754) begin
            $display("FAIL: VBL_CTRL reads %08x, expected probe_addr=$C054 busy pal locked state=5 notify",
                     out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: VBL_CTRL reads the detector's state; start reads back as 0");
        base = out_n;
        do_read(32'h8000_0034);
        if (out_mem[base+2] !== 32'h0003_0007) begin
            $display("FAIL: VBL_STAT reads %08x", out_mem[base+2]); errors = errors + 1;
        end
        base = out_n;
        do_read(32'h8000_0038);
        if (out_mem[base+2] !== 32'h0201_4231) begin
            $display("FAIL: VBL_POS reads %08x", out_mem[base+2]); errors = errors + 1;
        end else $display("  ok: VBL_STAT and VBL_POS read what the detector says");
        do_write(32'h8000_0030, 32'hC019_0006);          // probe + notify
        if (probe_pulses !== 1 || start_pulses !== 1) begin
            $display("FAIL: probe pulsed %0d time(s), start %0d; expected 1 and 1", probe_pulses, start_pulses);
            errors = errors + 1;
        end else $display("  ok: probe is one pulse too");
        do_write(32'h8000_0030, 32'hC019_0000);          // notify off
        if (vbl_notify !== 1'b0) begin
            $display("FAIL: notify did not clear"); errors = errors + 1;
        end
        vbl_state = 4'd0; vbl_locked = 1'b0; vbl_pal = 1'b0; vbl_busy = 1'b0;
        vbl_stat = 32'd0; vbl_pos = 32'd0;

        // --- case 7 / the parser never lost sync -----------------------------
        if (frame_error !== 1'b0) begin
            $display("FAIL: frame_error asserted - a type is missing from hdr_known");
            errors = errors + 1;
        end else begin
            $display("  ok: no frame error; REG_READ and REG_WRITE are known types");
        end

        $display("");
        // ---- MEM_CTRL / MEM_STAT and the counters -----------------------------
        base = out_n;
        do_read(32'h8000_004C);
        if (out_mem[base+2] !== 32'h0900_0000) begin
            $display("FAIL: MEM_CTRL reads %08x, expected sets=9 and no serve bits", out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: MEM_CTRL reads log2(sets) and every serve bit clear");
        do_write(32'h8000_004C, 32'h0000_0305);           // serve ram+rom, both W1s
        base = out_n;
        do_read(32'h8000_004C);
        if (out_mem[base+2] !== 32'h0900_0005 || mem_serve !== 3'b101) begin
            $display("FAIL: MEM_CTRL after write reads %08x, serve %b", out_mem[base+2], mem_serve);
            errors = errors + 1;
        end else if (mem_cnt_clrs != 1 || mem_invals != 1) begin
            $display("FAIL: W1 pulses %0d/%0d, expected one each", mem_cnt_clrs, mem_invals);
            errors = errors + 1;
        end else $display("  ok: MEM_CTRL's serve bits are levels and its W1 bits pulse once");
        do_write(32'h8000_004C, 32'h0000_0000);
        if (mem_cnt_clrs != 1 || mem_serve !== 3'b000) begin
            $display("FAIL: a write with the W1 bits clear pulsed, or serve stuck"); errors = errors + 1;
        end
        base = out_n;
        do_read(32'h8000_0050);
        if (out_mem[base+2] !== 32'h0000_9A5C) begin
            $display("FAIL: MEM_STAT reads %08x, expected rom_loaded image_ready and the switches", out_mem[base+2]);
            errors = errors + 1;
        end else $display("  ok: MEM_STAT reads the shadow's switches and the image's state");
        base = out_n;
        do_read(32'h8000_0054);
        do_read(32'h8000_0058);
        do_read(32'h8000_005C);
        do_read(32'h8000_0060);
        do_read(32'h8000_0064);
        if (out_mem[base+2] !== 32'h0000_1111 || out_mem[base+5] !== 32'h0000_0022 ||
            out_mem[base+8] !== 32'h0000_0003 || out_mem[base+11] !== 32'h0000_0444 ||
            out_mem[base+14] !== 32'h1234_5C3A) begin
            $display("FAIL: MEM counters read %08x %08x %08x %08x %08x", out_mem[base+2],
                     out_mem[base+5], out_mem[base+8], out_mem[base+11], out_mem[base+14]);
            errors = errors + 1;
        end else $display("  ok: MEM_HITS, MISSES, MISMATCH, SERVED and LAST read straight through");

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
