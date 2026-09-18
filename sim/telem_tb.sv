`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// telem_tb - the telemetry sender, end to end (docs/TELEMETRY.md):
//
//   ft601_msg_rx -> reg_bridge -+
//                               +-> reg_front -> wb_regfile
//                  telem_tx ----+
//   reply_stream, telem_tx, a capture played by the bench -> msg_master x3 -> msg_arb
//
// The real modules, a bouncing RES' line, a second shortened to TICK clocks.
// What it holds the sender to:
//
//   1  silent until asked
//   2  the framing, and every word of a sample against a bridge read of the
//      same offset - which is what catches a slip in rtl/telem_map.vh
//   3  ONE INSTANT: three sources driven from one free-running counter read
//      the same number in every sample
//   4  a release through a bounce is ONE epoch; its sample is seq 0, comes
//      within a few dozen clocks, and the samples after it are a second apart
//      from IT
//   5  the host's bridge goes on working across sweeps: every reply right,
//      a write that waited out a sweep lands once
//   6  a telemetry message never lands inside another, nor another inside it;
//      no message is ever torn (rtl/tx_ring.sv's own expression)
//   7  a stalled link: whole samples skipped, `drops` and the gap in `seq`
//      agree
//   8  a release that finds a message still going out: the old one finishes,
//      the baseline follows, flagged late
//   9  `enable` dropped in the middle of a message: the message still ends
//////////////////////////////////////////////////////////////////////////////////
module telem_tb;

    localparam integer TICK  = 20000;        // a "second"
    localparam integer USC   = 100;          // a microsecond
    localparam integer US_PER_TICK = TICK / USC;

    localparam [7:0] T_REG_READ  = 8'h14;
    localparam [7:0] T_REG_WRITE = 8'h15;
    localparam [7:0] T_REG_VALUE = 8'h16;
    localparam [7:0] T_BUS_EVENTS = 8'h12;
    localparam [7:0] T_TELEMETRY = 8'h39;

    `include "telem_map.vh"
    localparam integer LEN = 3 + TELEM_N;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    integer errors = 0;
    integer now = 0;
    always @(posedge clk) now <= now + 1;

    // ---- host -> card --------------------------------------------------------
    reg  [31:0] rx_mem [0:65535];
    integer     rx_wr = 0, rx_rd = 0;
    // The FIFO's face is REGISTERED on the falling edge.  A continuous read of
    // an array a task writes was seen stale under Verilator 5.020 (the first
    // word of the first message read as zero with the array already holding it).
    reg         rx_empty = 1'b1;
    reg  [31:0] rx_dout  = 32'd0;
    wire        rx_rd_en;
    always @(posedge clk) if (rx_rd_en && !rx_empty) rx_rd <= rx_rd + 1;
    always @(negedge clk) begin
        rx_empty <= !(rx_rd < rx_wr);
        rx_dout  <= (rx_rd < rx_wr) ? rx_mem[rx_rd[15:0]] : 32'd0;
    end

    // EVERY STIMULUS CHANGES ON THE FALLING EDGE.  Changed on the rising one it
    // races the flops that sample it in the same timestep, and which wins is
    // the simulator's business: Verilator dropped this bench's first message.
    task push_word(input [31:0] w);
        begin rx_mem[rx_wr[15:0]] = w; rx_wr = rx_wr + 1; end
    endtask
    function [31:0] hdr(input [7:0] t, input [7:0] len, input [15:0] free);
        hdr = {free, t, len};
    endfunction

    wire        msg_valid, pay_valid, unknown_valid;
    wire [7:0]  unknown_type, unknown_len, msg_type, msg_len;
    wire [15:0] msg_free;
    wire [31:0] pay_data;
    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .unknown_valid (unknown_valid), .unknown_type (unknown_type), .unknown_len (unknown_len)
    );

    // ---- the bridge, the front, the register file, the sender -----------------
    wire        b_cyc, b_stb, b_we, b_ack, b_stall;
    wire [31:0] b_adr, b_dat_w, wb_dat_r;
    wire [3:0]  b_sel;
    wire [31:0] rsp_addr, rsp_data;
    wire        rsp_valid, rsp_take;
    reg_bridge u_bridge (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .wb_cyc (b_cyc), .wb_stb (b_stb), .wb_we (b_we),
        .wb_adr (b_adr), .wb_dat_w (b_dat_w), .wb_sel (b_sel),
        .wb_ack (b_ack), .wb_stall (b_stall), .wb_dat_r (wb_dat_r),
        .rsp_addr (rsp_addr), .rsp_data (rsp_data),
        .rsp_valid (rsp_valid), .rsp_take (rsp_take)
    );

    wire        t_req, t_gnt, t_stb, t_ack, snap_hold;
    wire [15:0] t_off;
    wire        s_cyc, s_stb, s_we, s_ack;
    wire [31:0] s_adr;
    reg_front u_front (
        .clk (clk), .rst (rst),
        .b_cyc (b_cyc), .b_stb (b_stb), .b_we (b_we), .b_adr (b_adr),
        .b_ack (b_ack), .b_stall (b_stall),
        .t_req (t_req), .t_gnt (t_gnt), .t_stb (t_stb), .t_off (t_off), .t_ack (t_ack),
        .s_cyc (s_cyc), .s_stb (s_stb), .s_we (s_we), .s_adr (s_adr), .s_ack (s_ack)
    );

    // The register file never sees two strobes for one access.
    integer wr_strobes = 0;
    always @(posedge clk) if (s_cyc && s_stb && s_we) wr_strobes <= wr_strobes + 1;

    reg         apple_res_sync = 1'b0;       // the card's reset holds the machine
    reg  [31:0] free_cnt = 32'd0;            // three registers' worth of one counter
    always @(posedge clk) free_cnt <= free_cnt + 32'd1;
    wire        telem_on, apple_res_q;
    wire [23:0] telem_stat;
    // THE DEBUG SPACE, modelled: f(sel) registered once, as rtl/master_top.sv
    // registers dbg_val_q behind its muxes.  The host's selector is the
    // register file's; what the model sees is the sender's output.
    wire [7:0]  dbg_sel_host, dbg_sel_eff;
    reg  [31:0] dbg_model = 32'd0;
    function [31:0] dbg_f(input [7:0] sel);
        dbg_f = 32'hD0B0_0000 | ({24'd0, sel} << 8) | {24'd0, ~sel};
    endfunction
    always @(posedge clk) dbg_model <= dbg_f(dbg_sel_eff);
    wire [5:0]  pb_override;

    /* verilator lint_off PINMISSING */
    wb_regfile #(.BUILD_DATE (20260917), .BUILD_TIME (123456), .CAN_MASTER (1'b1)) u_regs (
        .clk (clk), .rst (rst),
        .apple_res_sync (apple_res_sync),
        .boot_held (1'b0), .hold_runtime (1'b0), .pb_hw (3'b101), .pb_override (pb_override),
        .hd_rom_loaded (1'b1), .hd_busy (1'b0), .hd_execs (8'h11),
        .fd_rom_loaded (1'b1), .fd_seeks (8'h12), .fd_stale (2'd1), .fd_dirty (2'd2),
        .fd_phase (14'h1234), .fd_ctl (4'h9), .fd_late (8'h13), .fd_fill_max (16'h1415),
        .fd35_stale (1'b1), .fd35_track (7'h2A), .fd35_side (1'b1), .fd35_motor35 (1'b1),
        .fd35_motor (1'b0), .fd35_ctl (8'h16), .fd35_seeks (8'h17), .fd35_late (8'h18),
        .fd35_wstat (32'h191A_1B1C), .fd35_fill_max (16'h1D1E),
        .vidhd_rom_loaded (1'b1),
        .mouse_rom_loaded (1'b1), .mouse_irq (1'b0), .mouse_mode (4'h5), .mouse_buttons (2'd1),
        .mouse_moves (8'h1F), .mouse_x (16'h2021), .mouse_y (16'h2223),
        .u2_sock_open (4'b0011), .u2_cmd_dropped (1'b0), .u2_cmds (8'h24), .u2_rx_chunks (8'h25),
        .u2_s0_rsr (16'h2627), .u2_s0_fsr (16'h2829),
        .printer_rom_loaded (1'b1), .printer_writes (8'h2A),
        .nsc_time_loaded (1'b1), .nsc_ring_en (1'b0), .nsc_wr_en (1'b1),
        .nsc_cmp_idx (6'd5), .nsc_ring_idx (6'd9), .nsc_unlocks (8'h2B), .nsc_now (64'd0),
        .kbd_flags (3'b010), .kbd_counts (32'h2C2D_2E2F),
        .vbl_state (4'h3), .vbl_locked (1'b1), .vbl_pal (1'b0), .vbl_busy (1'b0), .vbl_err (4'h0),
        .vbl_stat (32'h3031_3233), .vbl_pos (32'h3435_3637),
        .mem_sw (12'hA5C), .mem_rw_bank (8'h07), .mem_image_ready (1'b1), .mem_invalidating (1'b0),
        .mem_rom_loaded (1'b1), .mem_late_fills (8'd0), .mem_fifo_drops (8'd0),
        .mem_fills (32'h3839_3A3B), .mem_flushes (32'h3C3D_3E3F), .mem_declines (32'h4041_4243),
        .mem_rom_busy (1'b0), .mem_rom_sum (32'h4445_4647), .mem_rom_over (8'h48),
        .mem_rom_xland (8'h49), .gs_adb_stat (32'h4A4B_4C4D), .gs_clock_stat (32'h4E4F_5051),
        .panel_dmas (4'h5), .panel_drops (4'h2),
        // ONE counter behind three registers: MEM_HITS, ACCEL_CORE_CYC, ACCEL_BUS_CYC.
        .cnt_core_cyc (free_cnt), .cnt_bus_cyc (free_cnt), .mem_hits (free_cnt),
        .dbg_val (dbg_model), .dbg_sel (dbg_sel_host), .mem_shd_drops (8'h56),
        .mem_misses (32'h5758_595A), .mem_mismatch (32'h5B5C_5D5E), .mem_served (32'h5F60_6162),
        .mem_last (32'h6364_6566), .mem_diverted (32'h6768_696A), .mem_intc8rom (1'b1),
        .game_pb (3'b010), .game_pb_ok (1'b1), .game_pdl_ok (1'b1), .game_pdl0 (12'h6B6),
        .game_pdl1 (12'h6C6), .game_pdl2 (12'h6D6), .game_pdl3 (12'h6E6), .game_meas (8'h6F),
        .accel_stat (32'h7071_7273), .accel_fast (32'h7475_7677), .accel_bus (32'h7879_7A7B),
        .accel_cycles (32'h7C7D_7E7F), .accel_wait (32'h8081_8283), .accel_turbo (32'h8485_8687),
        .accel_dline (32'h8889_8A8B), .accel_maps (32'h8C8D_8E8F), .accel_ddrop (32'h9091_9293),
        .accel_drevive (32'h9495_9697), .accel_idrop (32'h9899_9A9B), .accel_irevive (32'h9C9D_9E9F),
        .accel_cen_v (1'b0), .accel_cen_sel (3'd0),
        .fb_mode (7'b1010101), .fb_compared (32'hA0A1_A2A3), .fb_mismatch (32'hA4A5_A6A7),
        .fb_last (32'hA8A9_AAAB), .fb_last2 (32'hACAD_AEAF), .fb_other (32'hB0B1_B2B3),
        .fb_peek_data (8'hB4),
        .ring_status (32'hB5B6_B7B8), .link_stat (32'hB9BA_BBBC),
        .ddr3_dbg1 (32'hBDBE_BFC0), .ddr3_dbg2 (32'hC1C2_C3C4), .ddr3_dbg3 (32'hC5C6_C7C8),
        .ddr3_eye0 (32'hC9CA_CBCC), .ddr3_eye1 (32'hCDCE_CFD0), .audio_stat (32'hD1D2_D3D4),
        .snap_hold (snap_hold), .telem_on (telem_on), .telem_stat (telem_stat),
        .apple_res_q (apple_res_q),
        .wb_cyc (s_cyc), .wb_stb (s_stb), .wb_we (s_we), .wb_adr (s_adr),
        .wb_dat_w (b_dat_w), .wb_sel (4'hF), .wb_ack (s_ack), .wb_stall (), .wb_dat_r (wb_dat_r)
    );
    /* verilator lint_on PINMISSING */

    wire [31:0] tm_word;
    wire        tm_valid, tm_take;
    telem_tx #(.TICK_CYCLES (TICK), .US_CYCLES (USC), .DEBOUNCE (16), .MASK_LOG2 (8)) u_telem (
        .clk (clk), .rst (rst), .enable (telem_on), .apple_res_q (apple_res_q),
        .dbg_sel_host (dbg_sel_host), .dbg_sel (dbg_sel_eff),
        .t_req (t_req), .t_gnt (t_gnt), .t_stb (t_stb), .t_off (t_off), .t_ack (t_ack),
        .t_dat (wb_dat_r), .snap_hold (snap_hold),
        .word (tm_word), .valid (tm_valid), .take (tm_take),
        .stat (telem_stat)
    );

    // ---- the message bus: the reply, the sender, a capture played here ----------
    reg  [31:0] cap_mem [0:63];
    integer     cap_n = 0, cap_i = 0;
    wire        cap_valid = (cap_i < cap_n);
    wire [31:0] cap_word  = cap_valid ? cap_mem[cap_i] : 32'd0;
    wire        cap_take;
    reg         cap_run = 1'b0;
    // A BUS_EVENTS message of 2..41 words whenever the last one has gone.
    integer ci, cn;
    always @(posedge clk) begin
        if (cap_take) begin
            cap_i <= cap_i + 1;
        end else if (cap_run && !cap_valid) begin
            cn = 2 + ($urandom % 40);
            cap_mem[0] = hdr(T_BUS_EVENTS, 8'(cn - 1), 16'd0);
            for (ci = 1; ci < cn; ci = ci + 1) cap_mem[ci] = 32'hC0DE_0000 + ci;
            cap_n <= cn;
            cap_i <= 0;
        end
    end

    wire [2:0]  ma_valid, ma_take;
    wire [95:0] ma_word;
    reply_stream u_reply (
        .clk (clk), .rst (rst),
        .rsp_addr (rsp_addr), .rsp_data (rsp_data),
        .rsp_valid (rsp_valid), .rsp_take (rsp_take),
        .word (ma_word[31:0]), .valid (ma_valid[0]), .take (ma_take[0])
    );
    assign ma_word[63:32] = tm_word;  assign ma_valid[1] = tm_valid;  assign tm_take  = ma_take[1];
    assign ma_word[95:64] = cap_word; assign ma_valid[2] = cap_valid; assign cap_take = ma_take[2];

    wire [2:0]  mb_cyc, mb_stb, mb_we, mb_stall, mb_ack;
    wire [95:0] mb_adr, mb_dat;
    wire [11:0] mb_sel;
    wire        sb_cyc, sb_stb, sb_we;
    wire [31:0] sb_adr, sb_dat;
    wire [3:0]  sb_sel;
    reg         sb_ack = 1'b0;
    reg         tx_full = 1'b0;

    genvar gm;
    generate for (gm = 0; gm < 3; gm = gm + 1) begin : g_m
        msg_master u_m (
            .clk (clk), .rst (rst),
            .word (ma_word[gm*32 +: 32]), .valid (ma_valid[gm]), .take (ma_take[gm]),
            .cyc (mb_cyc[gm]), .stb (mb_stb[gm]), .we (mb_we[gm]),
            .adr (mb_adr[gm*32 +: 32]), .dat (mb_dat[gm*32 +: 32]), .sel (mb_sel[gm*4 +: 4]),
            .stall (mb_stall[gm]), .ack (mb_ack[gm])
        );
    end endgenerate

    msg_arb #(.N (3)) u_arb (
        .clk (clk), .rst (rst),
        .m_cyc (mb_cyc), .m_stb (mb_stb), .m_we (mb_we), .m_adr (mb_adr),
        .m_dat (mb_dat), .m_sel (mb_sel), .m_stall (mb_stall), .m_ack (mb_ack),
        .s_cyc (sb_cyc), .s_stb (sb_stb), .s_we (sb_we), .s_adr (sb_adr),
        .s_dat (sb_dat), .s_sel (sb_sel), .s_stall (tx_full), .s_ack (sb_ack)
    );
    always @(posedge clk) sb_ack <= !rst && sb_cyc && sb_stb && !tx_full;
    wire out_push = sb_cyc && sb_stb && !tx_full;

    // ---- the stream's checker: every message whole, in one piece ----------------
    // The parser a host would run, plus tx_ring's own rule: CYC never drops with
    // payload owed.
    integer      owed = 0;               // payload words still to come
    reg  [7:0]   cur_type = 8'd0;
    integer      cur_i = 0;
    integer      n_reply = 0, n_cap = 0, n_telem = 0, torn = 0;
    reg  [31:0]  last_reply_addr = 32'd0, last_reply_data = 32'd0;
    // the last sample, and what is kept of the ones before it
    reg  [31:0]  smp [0:255];
    reg  [15:0]  smp_free = 16'd0;
    reg  [31:0]  t_w0 [0:255], t_seq [0:255], t_us [0:255];
    reg  [7:0]   t_drops [0:255];
    integer      t_at [0:255];           // the clock its header went out

    always @(posedge clk) begin
        if (!sb_cyc && owed != 0) torn = torn + 1;
        if (out_push) begin
            if (owed == 0) begin
                cur_type = sb_dat[15:8];
                owed     = sb_dat[7:0];
                cur_i    = 0;
                case (cur_type)
                    T_REG_VALUE:  if (owed != 2) begin
                        $display("FAIL: a reply of len %0d", owed); errors = errors + 1; end
                    T_BUS_EVENTS: ;
                    T_TELEMETRY: begin
                        smp_free = sb_dat[31:16];
                        t_at[n_telem] = now;
                        if (owed != LEN || sb_dat[23:16] != TELEM_LAYOUT) begin
                            $display("FAIL: telemetry header %08x (len %0d, layout %0d expected)",
                                     sb_dat, LEN, TELEM_LAYOUT);
                            errors = errors + 1;
                        end
                    end
                    default: begin
                        $display("FAIL: the stream carries a header %08x nobody sent", sb_dat);
                        errors = errors + 1;
                    end
                endcase
            end else begin
                case (cur_type)
                    T_REG_VALUE:  if (cur_i == 0) last_reply_addr = sb_dat; else last_reply_data = sb_dat;
                    T_BUS_EVENTS: if (sb_dat !== 32'hC0DE_0000 + cur_i + 1) begin
                        $display("FAIL: capture word %0d = %08x: something landed inside it", cur_i, sb_dat);
                        errors = errors + 1;
                    end
                    T_TELEMETRY:  smp[cur_i] = sb_dat;
                    default: ;
                endcase
                cur_i = cur_i + 1;
                owed  = owed - 1;
                if (owed == 0) begin
                    case (cur_type)
                        T_REG_VALUE:  n_reply = n_reply + 1;
                        T_BUS_EVENTS: n_cap = n_cap + 1;
                        T_TELEMETRY: begin
                            t_w0[n_telem]    = smp[0];
                            t_seq[n_telem]   = smp[1];
                            t_us[n_telem]    = smp[2];
                            t_drops[n_telem] = smp_free[15:8];
                            if (smp[0][15:0] !== 16'd0) begin
                                $display("FAIL: sample %0d w0 = %08x", n_telem, smp[0]);
                                errors = errors + 1;
                            end
                            n_telem = n_telem + 1;
                        end
                        default: ;
                    endcase
                end
            end
        end
    end

    // ---- helpers -----------------------------------------------------------------
    task check(input cond, input [1023:0] what);
        begin
            if (!cond) begin $display("FAIL: %0s", what); errors = errors + 1; end
            else       $display("  ok: %0s", what);
        end
    endtask

    integer want_reply;
    task do_read(input [31:0] addr);
        begin
            @(negedge clk);
            want_reply = n_reply + 1;
            push_word(hdr(T_REG_READ, 8'd1, 16'd0));
            push_word(addr);
            while (n_reply < want_reply) @(posedge clk);
        end
    endtask
    task do_write(input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            want_reply = n_reply + 1;
            push_word(hdr(T_REG_WRITE, 8'd2, 16'd0));
            push_word(addr);
            push_word(data);
            while (n_reply < want_reply) @(posedge clk);
        end
    endtask
    task wait_telem(input integer n);
        begin while (n_telem < n) @(posedge clk); end
    endtask

    // RES' the way the line does it: down clean, up through a bounce.
    integer bi;
    task res_pulse;
        begin
            @(negedge clk);
            apple_res_sync = 1'b0;
            repeat (60) @(negedge clk);
            for (bi = 0; bi < 12; bi = bi + 1) begin
                apple_res_sync = 1'b1; repeat (1 + ($urandom % 5)) @(negedge clk);
                apple_res_sync = 1'b0; repeat (1 + ($urandom % 5)) @(negedge clk);
            end
            apple_res_sync = 1'b1;
        end
    endtask

    integer i, k, base_n, base_at, mism, n0, d0, s0, gap, hammer_bad, ws0, n_dbg;
    reg [23:0] ent_i;
    reg [31:0] keep [0:255];
    reg [7:0]  ep;

    initial begin
        $display("telem_tb: the telemetry sender");
        repeat (8) @(negedge clk);
        rst = 0;

        // 1 ---- silent until asked
        repeat (3 * TICK) @(posedge clk);
        check(n_telem == 0, "silent until asked: three seconds, no message");

        // 2 ---- the framing and the map, the machine still held
        do_write(32'h8000_0168, 32'h0000_0001);
        check(telem_on, "TELEM_CTRL[0] is the enable");
        wait_telem(2);
        check(t_w0[1][16] == 1'b1, "a sample taken with RES' low says so (flags[0])");
        check(t_seq[1] == t_seq[0] + 1 && t_us[1] - t_us[0] == US_PER_TICK,
              "two samples: seq + 1, and exactly one second apart");
        for (i = 0; i < LEN; i = i + 1) keep[i] = smp[i];
        mism = 0;
        n_dbg = 0;
        for (i = 0; i < TELEM_N; i = i + 1) begin
            ent_i = telem_ent(i[7:0]);
            if (ent_i[15:0] == TELEM_DBG_OFF) begin
                // a debug item: what the model says for the entry's selector
                n_dbg = n_dbg + 1;
                if (keep[3 + i] !== dbg_f(ent_i[23:16])) begin
                    $display("FAIL: map entry %0d (debug item sel %02x): the sample says %08x, the item is %08x",
                             i, ent_i[23:16], keep[3 + i], dbg_f(ent_i[23:16]));
                    mism = mism + 1;
                end
            end else begin
                do_read({16'h8000, ent_i[15:0]});
                // the three words behind the free counter move between a sample and a read
                if (i != 26 && i != 169 && i != 170 && last_reply_data !== keep[3 + i]) begin
                    $display("FAIL: map entry %0d (offset %04x): the sample says %08x, a read %08x",
                             i, ent_i[15:0], keep[3 + i], last_reply_data);
                    mism = mism + 1;
                end
            end
        end
        check(mism == 0 && n_dbg == 80,
              "every word of a sample is what a bridge read of its offset returns, every debug item its selector's word");
        check(keep[3 + 0] == 32'd20260917 && keep[3 + 29] == 32'h5F60_6162 &&
              keep[3 + 161] == 32'h7475_7677 && keep[3 + 62] == 32'hCDCE_CFD0 &&
              keep[3 + 84] == dbg_f(8'h3F),
              "BUILD_DATE, MEM_SERVED, ACCEL_FAST, DDR3_EYE1 and H_CLOCKS are where the map says");
        for (i = 0; i < TELEM_N; i = i + 1)
            for (k = i + 1; k < TELEM_N; k = k + 1)
                if (telem_ent(i[7:0]) == telem_ent(k[7:0])) begin
                    $display("FAIL: map entries %0d and %0d are the same", i, k);
                    errors = errors + 1;
                end
        // the host's own pair, across a sweep: DBG_SEL = X reads f(X), every time
        do_write(32'h8000_0130, 32'h0000_002B);
        mism = 0;
        for (i = 0; i < 6; i = i + 1) begin
            repeat (TICK / 5) @(posedge clk);
            do_read(32'h8000_0134);
            if (last_reply_data !== dbg_f(8'h2B)) mism = mism + 1;
        end
        check(mism == 0, "the host's DBG_SEL/DBG_VAL pair reads its own selection across sweeps");

        // 3 ---- one instant
        check(keep[3 + 26] == keep[3 + 169] && keep[3 + 169] == keep[3 + 170] && keep[3 + 170] != 0,
              "three registers behind one counter read ONE number: the sweep is one instant");

        // 4 ---- the release
        n0 = n_telem;
        ep = t_w0[n0 - 1][31:24];
        res_pulse;
        base_at = now;
        wait_telem(n0 + 1);
        // (a tick's sample may have been in flight; the baseline is the first seq 0)
        base_n = n_telem - 1;
        if (t_seq[base_n] != 0) begin wait_telem(n0 + 2); base_n = n_telem - 1; end
        check(t_seq[base_n] == 0 && t_w0[base_n][31:24] == ep + 8'd1,
              "a release through a bounce: seq 0, and ONE epoch on");
        check(t_w0[base_n][16] == 1'b0, "...taken with RES' high");
        // The stamp is taken as the sweep starts, within a few dozen clocks of
        // the line settling; the header goes out when the sweep is in: about
        // three clocks a register and six a debug item (layout 2: ~750).
        check(t_at[base_n] - base_at < 3 * TELEM_N + 6 * 80 + 300,
              "...its header out within a sweep's length of the line settling");
        wait_telem(base_n + 4);
        mism = 0;
        for (i = base_n + 1; i <= base_n + 3; i = i + 1) begin
            if (t_w0[i][31:24] != ep + 8'd1 || t_seq[i] != i - base_n) mism = mism + 1;
            if (i > base_n + 1 && t_us[i] - t_us[i - 1] != US_PER_TICK) mism = mism + 1;
        end
        check(mism == 0, "...and the samples after it count seconds from it, in that epoch");
        check((t_us[base_n + 1] - t_us[base_n]) >= US_PER_TICK - 1 &&
              (t_us[base_n + 1] - t_us[base_n]) <= US_PER_TICK + 1,
              "the first second is measured from the release");

        // 5 + 6 ---- the bridge and the capture, across sweeps
        cap_run = 1'b1;
        n0 = n_telem;
        ws0 = wr_strobes;
        hammer_bad = 0;
        k = 0;
        while (n_telem < n0 + 4) begin
            repeat ($urandom % 900) @(posedge clk);
            if (k[0]) begin
                do_read(32'h8000_0060);
                if (last_reply_addr !== 32'h8000_0060 || last_reply_data !== 32'h5F60_6162)
                    hammer_bad = hammer_bad + 1;
            end else begin
                do_write(32'h8000_0020, {26'd0, k[6:1]});
                do_read(32'h8000_0020);
                if (last_reply_data[5:0] !== k[6:1] || pb_override !== k[6:1])
                    hammer_bad = hammer_bad + 1;
            end
            k = k + 1;
        end
        check(hammer_bad == 0 && k > 20, "the bridge across four sweeps: every reply right");
        check(wr_strobes - ws0 == (k + 1) / 2, "...and every write reached the register file once");
        // a write timed INTO a sweep
        while (!snap_hold) @(posedge clk);
        ws0 = wr_strobes;
        do_write(32'h8000_0020, 32'h0000_002A);
        check(pb_override == 6'h2A && wr_strobes - ws0 == 1,
              "a write that arrived during a sweep waited it out and landed once");
        repeat (2 * TICK) @(posedge clk);
        cap_run = 1'b0;
        repeat (400) @(posedge clk);
        check(n_cap > 50 && torn == 0,
              "telemetry between capture messages: nothing landed inside anything, nothing torn");

        // 7 ---- a stalled link
        n0 = n_telem;
        @(negedge clk); tx_full = 1'b1;
        repeat (4 * TICK + TICK / 2) @(posedge clk);
        @(negedge clk); tx_full = 1'b0;
        wait_telem(n0 + 2);
        // the first to arrive was swept before the stall bit; the one after it carries the drops
        gap = t_seq[n0 + 1] - t_seq[n0] - 1;
        check(gap >= 2 && (8'(t_drops[n0 + 1] - t_drops[n0])) == 8'(gap),
              "a stalled link: whole samples skipped, and `drops` is the gap in `seq`");
        check(torn == 0, "...and the message that waited went out whole");

        // 8 ---- a release with a message still going out
        n0 = n_telem;
        ep = t_w0[n0 - 1][31:24];
        @(negedge clk); tx_full = 1'b1;
        repeat (TICK + 200) @(posedge clk);          // a tick's sample is now waiting
        res_pulse;
        repeat (600) @(posedge clk);
        @(negedge clk); tx_full = 1'b0;
        wait_telem(n0 + 2);
        check(t_w0[n0][31:24] == ep && t_seq[n0] != 0,
              "a release that found a message waiting: the old epoch's sample still goes first");
        check(t_w0[n0 + 1][31:24] == ep + 8'd1 && t_seq[n0 + 1] == 0 && t_w0[n0 + 1][17] == 1'b1,
              "...and the baseline follows it, flagged late");

        // 9 ---- enable dropped in the middle of a message
        n0 = n_telem;
        while (!(sb_cyc && cur_type == T_TELEMETRY && owed > 40 && owed < 120)) @(posedge clk);
        @(negedge clk); tx_full = 1'b1;
        push_word(hdr(T_REG_WRITE, 8'd2, 16'd0));
        push_word(32'h8000_0168);
        push_word(32'h0000_0000);
        repeat (200) @(posedge clk);
        check(!telem_on, "TELEM_CTRL cleared while a message is half out");
        @(negedge clk); tx_full = 1'b0;
        wait_telem(n0 + 1);
        repeat (3 * TICK) @(posedge clk);
        check(n_telem == n0 + 1 && torn == 0 && owed == 0,
              "...the message ended whole, and nothing followed it");
        do_read(32'h8000_0168);
        check(last_reply_data[0] == 1'b0 && last_reply_data[15:8] == t_w0[n0][31:24] &&
              last_reply_data[31:24] == 8'(n_telem),
              "TELEM_CTRL reads back the epoch and the count sent");

        if (unknown_valid) errors = errors + 1;
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // A bench that hangs says so.
    initial begin
        repeat (60 * TICK) @(posedge clk);
        $display("FAIL: timeout at clock %0d (n_telem %0d, n_reply %0d)", now, n_telem, n_reply);
        $display("      rx %0d/%0d (mem0 %08x), write strobes %0d, telem_on %0d, bridge state %0d, front state %0d, owed %0d, rsp_valid %0d",
                 rx_rd, rx_wr, rx_mem[0], wr_strobes, telem_on, u_bridge.state, u_front.state, owed, rsp_valid);
        $finish;
    end

endmodule
