`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// kbd_inject_tb - the keyboard the soft core reads, with the host on it.
//
// The real core, the real driver, the real READER and the hold, wired as
// master_top wires them, against an Apple-shaped phi0 and a bus model with a
// ROM, a keyboard at $C000/$C01x and the IIe's soft-switch reads.  The reader
// is here, pins and synchronisers and all, because the property that makes
// this mechanism sound is that the byte the core latched and the byte the
// capture recorded are the same byte, and only the real reader can say so.
//
// THE PROPERTIES, each a way this is or could be wrong:
//
//   * idle, a real key is seen once, bit for bit, $C010 clears it, and the
//     counts do not move.
//   * a pressed key is what the next $C00x read returns, bit 7 set, and what
//     every read after it returns until a $C010 access - then never again:
//     the reads after that return the key with bit 7 clear, the IOU's
//     latch after its strobe.
//   * a $C010 access clears; a write to $C015 clears; a read of $C019 does
//     not, and returns the machine's byte; a write to $C000 does nothing.
//   * din and the captured event agree on every cycle, injected or not.
//   * every press is resolved exactly once, and the counts say how: taken
//     when read then strobed, flushed when strobed unread, replaced by a
//     second press, dropped by `drop` or a RES' - and `changed` pulses once
//     per resolution, with the key that was resolved.
//   * a press over a real key waiting wins, and a real key pressed after the
//     injected one was consumed reads normally.
//   * keys pressed one per consumption go through RDKEY-shaped code in
//     order, exactly once each - at every offset across the bus cycle, and
//     never torn.
//   * held by the boot hold, an injected $0D is one $C000 event with bit 7
//     set, followed by exactly one $C010.
//   * locked, a real key never reaches the program and `touched` says it
//     came; an injected key does; any-key-down is masked; the real key
//     shows through when the lock lifts; a fresh lock clears `touched`.
//   * with master_active low nothing is substituted.
//   * the hotkey (docs/RUNTIME_MENU.md): read by the program, it is eaten -
//     the program gets the latch with no strobe, the capture records the
//     same, last_read does not learn it, hotkey_hit pulses once and the
//     hold engages with one $C010 first; not looked for when the door is
//     shut, nor under the lock; an injected key ahead of it wins; a
//     program that never reads the keyboard is never paused by it (no
//     scan, by decision); while held it passes through to the host like
//     any key.
//
// The buttons (rtl/pb_inject.sv) ride along, on the same substitution.
//////////////////////////////////////////////////////////////////////////////////
module kbd_inject_tb;

    parameter UCODE = "cpu65c02_ucode.hex";

    localparam integer T_PRESENT = 2;
    localparam integer T_EMIT    = 2;
    localparam integer T_DIN     = 44;
    localparam integer T_CYCEN   = 45;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;               // 100 MHz

    integer errors = 0;
    task fail(input [8*96-1:0] why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask

    // ---- phi0, as the machine makes it --------------------------------------
    localparam integer PHI0_LOW  = 49;
    localparam integer PHI0_HIGH = 49;
    localparam integer CYCLE     = PHI0_LOW + PHI0_HIGH;
    reg phi0 = 0;
    integer phase_ctr = 0;
    always @(posedge clk) begin
        phase_ctr <= phase_ctr + 1;
        if (!phi0 && phase_ctr == PHI0_LOW - 1)  begin phi0 <= 1; phase_ctr <= 0; end
        if ( phi0 && phase_ctr == PHI0_HIGH - 1) begin phi0 <= 0; phase_ctr <= 0; end
    end

    reg     prev_phi0 = 0;
    wire    fall = !phi0 && prev_phi0;
    integer since_fall = 0;
    always @(posedge clk) begin
        prev_phi0 <= phi0;
        if (fall) since_fall <= 0;
        else      since_fall <= since_fall + 1;
    end

    // ---- the machine's reset line, and the card's ---------------------------
    reg  res_n = 1'b1;                          // RES', active low, at the pin
    reg  master_active = 1'b1;

    // ---- the pins -----------------------------------------------------------
    // What the reader sees: the card's drive when it drives, the bus model's
    // byte otherwise.
    reg  [7:0]  bus_data = 8'h00;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, driving, drv_sync;
    wire [7:0]  data_drive;
    wire [7:0]  apple_data_pin = data_oe    ? data_drive : bus_data;
    wire [15:0] apple_addr_pin = addr_rw_oe ? addr_drive : 16'h0000;
    wire        apple_rw_pin   = addr_rw_oe ? rw_drive   : 1'b1;

    // ---- the reader, exactly as master_top has it ---------------------------
    wire [31:0] ev_data;
    wire        ev_valid, res_sync, phi0_s;
    wire [7:0]  data_s;
    wire        sub_en;
    wire [7:0]  sub_data;

    apple_bus_read u_read (
        .clk (clk), .rst (rst), .enable (1'b1),
        .apple_data_pin (apple_data_pin), .apple_addr_pin (apple_addr_pin),
        .apple_rw_pin (apple_rw_pin), .apple_phi0_pin (phi0),
        .apple_m2sel_pin (1'b0), .apple_m2b0_pin (1'b0), .apple_inh_pin (1'b1),
        .apple_res_pin (res_n), .apple_irq_pin (1'b1), .apple_rdy_pin (1'b1),
        .apple_dma_pin (!dma_assert),
        .ev_data (ev_data), .ev_valid (ev_valid),
        .sync_override (drv_sync), .sync_override_en (1'b1),
        .data_override (sub_data), .data_override_en (sub_en),
        .rw_override_en (1'b0), .wdata_override (8'h00), .vbl_level (1'b0),
        .res_sync (res_sync), .irq_sync (), .phi0_sync (phi0_s),
        .data_sync (data_s), .phi0_active ()
    );

    wire cpu_rst = rst || !res_sync;            // as master_top wires it

    // ---- the core ---------------------------------------------------------
    wire [15:0] cpu_addr;
    wire        cpu_rw, cpu_sync, cpu_cyc_en;
    wire [7:0]  cpu_dout, cpu_din;

    cpu65c02 #(.UCODE_FILE (UCODE)) u_cpu (
        .clk (clk), .rst (cpu_rst), .cyc_en (cpu_cyc_en),
        .addr (cpu_addr), .rw (cpu_rw), .dout (cpu_dout), .i_din (cpu_din), .d_din (cpu_din),
        .irq_n (1'b1), .nmi_n (1'b1),
        .sync (cpu_sync), .halted ()
    );

    // ---- the driver -------------------------------------------------------
    wire [15:0] op_addr;
    wire        op_rw, op_present, op_commit, op_ovr;
    wire [7:0]  op_wdata;
    wire        ovr_en, ovr_rw;
    wire [15:0] ovr_addr;
    wire [7:0]  ovr_wdata;

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) u_write (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0_s), .data_sync (data_s),
        .master_active (master_active), .park_kbd (1'b0), .park_addr (16'hC000),
        // Without the sequencer: the bus owns every cycle, the core is always on offer.
        .bus_owns (1'b1), .core_valid (1'b1),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .drv_sync (drv_sync),
        .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (1'b0), .slot_rd_data (8'h00),
        .din_sub_en (sub_en), .din_sub_data (sub_data),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (ovr_rw),
        .ovr_wdata (ovr_wdata), .op_ovr (op_ovr), .nxt_addr (), .divert (1'b0), .op_divert (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- the hold, so an injected key can continue the menu -----------------
    // ...and the runtime door, which this module opens with the hotkey.
    reg  arm = 1'b0, release_req = 1'b0;
    reg  menu_en = 1'b0;
    wire held, runtime, hotkey_hit;
    localparam [6:0] HOTKEY = 7'h1E;            // Ctrl-6 on a IIe

    boot_hold u_hold (
        .clk (clk), .cpu_rst (cpu_rst),
        .master_active (master_active),
        .arm (arm), .release_req (release_req),
        .menu_trigger (1'b0), .hotkey_hit (hotkey_hit),
        .turbo_sync (1'b0), .cpu_sync (cpu_sync),
        .op_present (op_present), .op_commit (op_commit),
        .op_sync (drv_sync), .op_ovr (op_ovr),
        .op_addr (op_addr), .op_rw (op_rw), .din (cpu_din),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr),
        .held (held), .runtime (runtime)
    );

    integer hits = 0;                           // hotkey_hit pulses, ever
    always @(posedge clk) if (hotkey_hit) hits = hits + 1;
    assign ovr_rw = 1'b1;
    assign ovr_wdata = 8'h00;

    // ---- the DUTs: the keyboard, and the buttons beside it ------------------
    reg        press = 1'b0, drop = 1'b0, lock = 1'b0;
    reg  [6:0] press_key = 7'h00;
    wire       strobe, seen, touched, changed;
    wire [7:0] pressed, taken, flushed, replaced;
    wire [6:0] resolved_key;
    wire       kbd_sub_en, pb_sub_en;
    wire [7:0] kbd_sub_data, pb_sub_data;
    reg  [5:0] pb_sel = 6'd0;
    wire [2:0] pb_hw;

    kbd_inject dut (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst),
        .master_active (master_active), .park_kbd (1'b0), .op_dummy (1'b0), .int_rd (1'b0), .int_ok (), .int_byte (), .int_low (),
        .press (press), .press_key (press_key), .drop (drop), .lock (lock),
        .hotkey_en (menu_en), .hotkey (HOTKEY), .held (held),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .data_sync (data_s),
        .sub_en (kbd_sub_en), .sub_data (kbd_sub_data),
        .strobe (strobe), .seen (seen), .touched (touched),
        .pressed (pressed), .taken (taken), .flushed (flushed), .replaced (replaced),
        .resolved_key (resolved_key), .changed (changed),
        .hotkey_hit (hotkey_hit)
    );

    pb_inject dut_pb (
        .clk (clk), .rst (rst),
        .master_active (master_active),
        .sel (pb_sel),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit), .op_dummy (1'b0),
        .data_sync (data_s),
        .sub_en (pb_sub_en), .sub_data (pb_sub_data),
        .hw_level (pb_hw)
    );

    // As master_top merges them.
    assign sub_en   = kbd_sub_en | pb_sub_en;
    assign sub_data = kbd_sub_en ? kbd_sub_data : pb_sub_data;

    integer kbd_subs = 0, pb_subs = 0;         // clocks with each sub_en high
    integer changes  = 0;                       // changed pulses, ever
    integer touches  = 0;                       // rising edges of touched
    reg       touched_q = 1'b0;
    reg [6:0] last_resolved = 7'd0;             // resolved_key at the last pulse
    always @(posedge clk) begin
        if (kbd_sub_en) kbd_subs = kbd_subs + 1;
        if (pb_sub_en)  pb_subs  = pb_subs + 1;
        if (changed) begin changes = changes + 1; last_resolved = resolved_key; end
        if (touched && !touched_q) touches = touches + 1;
        touched_q = touched;
    end

    // Presses resolved by a drop or a RES': not counted on the card, derived
    // the way the host derives it.
    function [7:0] dropped;
        input dummy;
        begin dropped = pressed - {7'd0, strobe} - taken - flushed - replaced; end
    endfunction

    // ---- the machine: ROM, RAM, a keyboard and the IIe's $C01x ---------------
    localparam integer BUS_AT = 70;
    localparam [15:0] KEYS   = 16'h0300;        // where the RDKEY program stores keys

    reg [7:0] mem [0:65535];
    reg [6:0] kbd_key    = 7'h00;               // the machine's own keyboard
    reg       kbd_strobe = 1'b0;
    reg [2:0] btn_hw     = 3'b000;              // the game port's PB0-PB2, as wired

    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        if (rw_drive) begin
            if (addr_drive[15:4] == 12'hC00)
                bus_data <= {kbd_strobe, kbd_key};
            else if (addr_drive == 16'hC010) begin
                // Any-key-down in bit 7 - a key is down whenever one is
                // waiting, here - the key beneath; the strobe clears.
                bus_data   <= {kbd_strobe, kbd_key};
                kbd_strobe <= 1'b0;
            end else if (addr_drive[15:4] == 12'hC01)
                // A soft switch in bit 7 (0 here), the key beneath; NOT a
                // strobe clear on a IIe.
                bus_data <= {1'b0, kbd_key};
            else if (addr_drive[15:4] == 12'hC06)
                // The game port: PB0-PB2 at $C061-$C063 in bit 7, and a low
                // byte of floating-bus noise the substitution must leave.
                bus_data <= {(addr_drive[3:0] >= 4'd1 && addr_drive[3:0] <= 4'd3)
                                 ? btn_hw[addr_drive[1:0] - 2'd1] : 1'b0, 7'h2A};
            else
                bus_data <= mem[addr_drive];
        end else if (data_oe) begin
            if (addr_drive[15:4] == 12'hC01) kbd_strobe <= 1'b0;   // a $C01x write clears
            else if (addr_drive[15:4] != 12'hC00) mem[addr_drive] <= data_drive;
        end
    end

    // ---- the op log, and the capture log beside it --------------------------
    reg [15:0] log_addr [0:8191];
    reg        log_rw   [0:8191];
    reg        log_ovr  [0:8191];
    reg        log_sync [0:8191];
    reg [7:0]  log_din  [0:8191];
    reg [15:0] cap_addr [0:8191];
    reg [7:0]  cap_data [0:8191];
    integer    nops = 0, ncommit = 0, ncap = 0;
    always @(posedge clk) begin
        if (op_present) begin
            log_addr[nops] = op_addr;
            log_rw[nops]   = op_rw;
            log_sync[nops] = drv_sync;
            log_ovr[nops]  = op_ovr;
            log_din[nops]  = 8'hxx;
            nops = nops + 1;
        end
        if (op_commit) begin
            log_din[ncommit] = cpu_din;
            ncommit = ncommit + 1;
        end
        if (ev_valid) begin
            cap_addr[ncap] = ev_data[15:0];
            cap_data[ncap] = ev_data[27:20];
            ncap = ncap + 1;
        end
    end

    // ---- helpers ------------------------------------------------------------
    task cycles(input integer n);
        begin repeat (n * CYCLE) @(posedge clk); end
    endtask

    task at_offset(input integer off);
        begin
            @(posedge clk);
            while (since_fall != off) @(posedge clk);
            @(negedge clk);
        end
    endtask

    // Reset the machine into the program at `vector`, the logs restarted at
    // the release.  ev_valid and op_commit fall on adjacent clocks late in a
    // cycle, so zeroing all three counters at a cycle's start keeps the
    // capture log aligned with the op log.
    task machine_reset(input [15:0] vector);
        begin
            mem[16'hFFFC] = vector[7:0];
            mem[16'hFFFD] = vector[15:8];
            at_offset(0);
            res_n = 1'b0;
            cycles(4);
            at_offset(0);
            nops = 0; ncommit = 0; ncap = 0;
            res_n = 1'b1;
        end
    endtask

    // The host presses a key: one clock on the register's press pulse.
    task host_press(input [6:0] key);
        begin
            @(negedge clk); press_key = key; press = 1'b1;
            @(negedge clk); press = 1'b0;
        end
    endtask

    task host_drop;
        begin
            @(negedge clk); drop = 1'b1;
            @(negedge clk); drop = 1'b0;
        end
    endtask

    // Someone at the Apple presses a key, at an offset into the bus cycle.
    task real_press(input [6:0] key, input integer off);
        begin
            at_offset(off);
            kbd_key    = key;
            kbd_strobe = 1'b1;
        end
    endtask

    // Wait for the machine to consume the pressed key, or give up.
    task wait_consumed(input [8*48-1:0] what);
        integer n;
        begin
            n = 0;
            while (strobe && n < 200 * CYCLE) begin @(posedge clk); n = n + 1; end
            if (strobe) begin
                $display("FAIL: %0s: the key was never consumed", what);
                errors = errors + 1;
            end
        end
    endtask

    task pulse_release;
        begin
            @(negedge clk); release_req = 1'b1;
            @(negedge clk); release_req = 1'b0;
        end
    endtask

    // The op log and the capture log say the same thing, entry for entry.
    task check_agree(input integer from, input [8*48-1:0] what);
        integer i, bad;
        begin
            bad = 0;
            if (ncap != ncommit) begin
                $display("FAIL: %0s: %0d captured events against %0d committed ops", what, ncap, ncommit);
                errors = errors + 1;
            end
            for (i = from; i < ncommit && i < ncap; i = i + 1) begin
                if (cap_addr[i] !== log_addr[i]) bad = bad + 1;
                else if (cap_data[i] !== log_din[i]) bad = bad + 1;
            end
            if (bad != 0) begin
                $display("FAIL: %0s: %0d cycles where the capture and din disagree", what, bad);
                errors = errors + 1;
            end
        end
    endtask

    // The counts, all at once.
    task check_counts(input [7:0] p, input [7:0] t, input [7:0] f, input [7:0] r,
                      input [7:0] d, input [8*48-1:0] what);
        begin
            if (pressed !== p || taken !== t || flushed !== f || replaced !== r ||
                dropped(1'b0) !== d) begin
                $display("FAIL: %0s: counts pressed=%0d taken=%0d flushed=%0d replaced=%0d dropped=%0d, expected %0d %0d %0d %0d %0d",
                         what, pressed, taken, flushed, replaced, dropped(1'b0), p, t, f, r, d);
                errors = errors + 1;
            end
        end
    endtask

    // Count $C00x reads since `from` whose byte had bit 7 set.
    function integer key_reads(input integer from);
        integer i;
        begin
            key_reads = 0;
            for (i = from; i < ncommit; i = i + 1)
                if (log_rw[i] && log_addr[i][15:4] == 12'hC00 && log_din[i][7])
                    key_reads = key_reads + 1;
        end
    endfunction

    // The index of the n-th (from 0) $C00x read since `from`, or -1.
    function integer nth_kbd_read(input integer from, input integer n);
        integer i, seen_n;
        begin
            nth_kbd_read = -1; seen_n = 0;
            for (i = from; i < ncommit; i = i + 1)
                if (log_rw[i] && log_addr[i][15:4] == 12'hC00) begin
                    if (seen_n == n && nth_kbd_read < 0) nth_kbd_read = i;
                    seen_n = seen_n + 1;
                end
        end
    endfunction

    // The index of the first read of `addr` since `from`, or -1.
    function integer first_read_of(input integer from, input [15:0] addr);
        integer i;
        begin
            first_read_of = -1;
            for (i = from; i < ncommit; i = i + 1)
                if (first_read_of < 0 && log_rw[i] && log_addr[i] == addr) first_read_of = i;
        end
    endfunction

    // ---- the programs -------------------------------------------------------
    localparam [15:0] P_RDKEY = 16'hF000;   // store every key, RDKEY-shaped
    localparam [15:0] P_RULES = 16'hF100;   // the strobe-clear rules, one by one
    localparam [15:0] P_LATE  = 16'hF200;   // a long delay, then one read
    localparam [15:0] P_SPIN  = 16'hF300;   // never reads the keyboard
    localparam [15:0] P_PB    = 16'hF400;   // the buttons, and their neighbours
    localparam [15:0] P_FLUSH = 16'hF500;   // a long delay, then $C010 unread
    localparam [15:0] P_AKD   = 16'hF600;   // read $C010, then $C000, once each

    integer i, k, idx, mark, mark_cap, n, subs_before, changes_before;
    reg [7:0] tk;
    reg [6:0] keys [0:7];
    integer   offs [0:7];

    initial begin
        $display("kbd_inject_tb: the keyboard the soft core reads, with the host on it\n");

        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEA;   // NOP background
        // P_RDKEY:
        //   F000  LDX #$00        A2 00
        //   F002  LDA $C000       AD 00 C0
        //   F005  BPL $F002       10 FB
        //   F007  STA $0300,X     9D 00 03
        //   F00A  BIT $C010       2C 10 C0
        //   F00D  INX             E8
        //   F00E  JMP $F002       4C 02 F0
        mem[16'hF000] = 8'hA2; mem[16'hF001] = 8'h00;
        mem[16'hF002] = 8'hAD; mem[16'hF003] = 8'h00; mem[16'hF004] = 8'hC0;
        mem[16'hF005] = 8'h10; mem[16'hF006] = 8'hFB;
        mem[16'hF007] = 8'h9D; mem[16'hF008] = 8'h00; mem[16'hF009] = 8'h03;
        mem[16'hF00A] = 8'h2C; mem[16'hF00B] = 8'h10; mem[16'hF00C] = 8'hC0;
        mem[16'hF00D] = 8'hE8;
        mem[16'hF00E] = 8'h4C; mem[16'hF00F] = 8'h02; mem[16'hF010] = 8'hF0;
        // P_RULES:
        //   F100  LDA $C000       r0: the key
        //   F103  LDA $C000       r1: still the key
        //   F106  LDA $C019       VBL - must not clear
        //   F109  LDA $C000       r2: still the key
        //   F10C  STA $C015       a $C01x write clears
        //   F10F  LDA $C000       r3: the key, strobe gone
        //   F112  STA $C000       80STOREOFF: nothing
        //   F115  LDA $C000       r4: the same
        //   F118  JMP $F118
        mem[16'hF100] = 8'hAD; mem[16'hF101] = 8'h00; mem[16'hF102] = 8'hC0;
        mem[16'hF103] = 8'hAD; mem[16'hF104] = 8'h00; mem[16'hF105] = 8'hC0;
        mem[16'hF106] = 8'hAD; mem[16'hF107] = 8'h19; mem[16'hF108] = 8'hC0;
        mem[16'hF109] = 8'hAD; mem[16'hF10A] = 8'h00; mem[16'hF10B] = 8'hC0;
        mem[16'hF10C] = 8'h8D; mem[16'hF10D] = 8'h15; mem[16'hF10E] = 8'hC0;
        mem[16'hF10F] = 8'hAD; mem[16'hF110] = 8'h00; mem[16'hF111] = 8'hC0;
        mem[16'hF112] = 8'h8D; mem[16'hF113] = 8'h00; mem[16'hF114] = 8'hC0;
        mem[16'hF115] = 8'hAD; mem[16'hF116] = 8'h00; mem[16'hF117] = 8'hC0;
        mem[16'hF118] = 8'h4C; mem[16'hF119] = 8'h18; mem[16'hF11A] = 8'hF1;
        // P_LATE:
        //   F200  LDX #$00        A2 00
        //   F202  DEX             CA
        //   F203  BNE $F202       D0 FD        ~1280 cycles
        //   F205  LDA $C000       AD 00 C0
        //   F208  STA $0300       8D 00 03
        //   F20B  BIT $C010       2C 10 C0
        //   F20E  JMP $F20E       4C 0E F2
        mem[16'hF200] = 8'hA2; mem[16'hF201] = 8'h00;
        mem[16'hF202] = 8'hCA;
        mem[16'hF203] = 8'hD0; mem[16'hF204] = 8'hFD;
        mem[16'hF205] = 8'hAD; mem[16'hF206] = 8'h00; mem[16'hF207] = 8'hC0;
        mem[16'hF208] = 8'h8D; mem[16'hF209] = 8'h00; mem[16'hF20A] = 8'h03;
        mem[16'hF20B] = 8'h2C; mem[16'hF20C] = 8'h10; mem[16'hF20D] = 8'hC0;
        mem[16'hF20E] = 8'h4C; mem[16'hF20F] = 8'h0E; mem[16'hF210] = 8'hF2;
        // P_SPIN:  F300  JMP $F300
        mem[16'hF300] = 8'h4C; mem[16'hF301] = 8'h00; mem[16'hF302] = 8'hF3;
        // P_PB: read $C061 $C062 $C063 $C060 $C064 into $0300.., then spin
        begin : pbprog
            integer a, r;
            reg [7:0] addrs [0:4];
            addrs[0] = 8'h61; addrs[1] = 8'h62; addrs[2] = 8'h63; addrs[3] = 8'h60; addrs[4] = 8'h64;
            a = 16'hF400;
            for (r = 0; r < 5; r = r + 1) begin
                mem[a] = 8'hAD; mem[a+1] = addrs[r]; mem[a+2] = 8'hC0;       // LDA $C0xx
                mem[a+3] = 8'h8D; mem[a+4] = r[7:0]; mem[a+5] = 8'h03;       // STA $030r
                a = a + 6;
            end
            mem[a] = 8'h4C; mem[a+1] = a[7:0]; mem[a+2] = a[15:8];           // JMP *
        end
        // P_FLUSH: the delay, then a $C010 with no $C000 before it - a game
        // clearing the buffer as it starts.
        //   F500  LDX #$00 / DEX / BNE      as P_LATE
        //   F505  BIT $C010       2C 10 C0
        //   F508  JMP $F508
        mem[16'hF500] = 8'hA2; mem[16'hF501] = 8'h00;
        mem[16'hF502] = 8'hCA;
        mem[16'hF503] = 8'hD0; mem[16'hF504] = 8'hFD;
        mem[16'hF505] = 8'h2C; mem[16'hF506] = 8'h10; mem[16'hF507] = 8'hC0;
        mem[16'hF508] = 8'h4C; mem[16'hF509] = 8'h08; mem[16'hF50A] = 8'hF5;
        // P_AKD: any-key-down, then the keyboard, stored.
        //   F600  LDA $C010 / STA $0300
        //   F606  LDA $C000 / STA $0301
        //   F60C  JMP $F60C
        mem[16'hF600] = 8'hAD; mem[16'hF601] = 8'h10; mem[16'hF602] = 8'hC0;
        mem[16'hF603] = 8'h8D; mem[16'hF604] = 8'h00; mem[16'hF605] = 8'h03;
        mem[16'hF606] = 8'hAD; mem[16'hF607] = 8'h00; mem[16'hF608] = 8'hC0;
        mem[16'hF609] = 8'h8D; mem[16'hF60A] = 8'h01; mem[16'hF60B] = 8'h03;
        mem[16'hF60C] = 8'h4C; mem[16'hF60D] = 8'h0C; mem[16'hF60E] = 8'hF6;
        for (i = 0; i < 16; i = i + 1) mem[KEYS + i] = 8'h00;

        repeat (8) @(posedge clk);
        rst = 0;
        cycles(3);

        // --- case 1 / idle, a real key: through unchanged --------------------
        machine_reset(P_RDKEY);
        cycles(12);
        mark = ncommit;
        real_press(7'h41, 30);
        cycles(20);
        if (mem[KEYS] !== 8'hC1) fail("wire: the real key did not reach the program as $C1");
        else $display("  ok: idle, a real 'A' reads as $C1 and is stored by the program");
        if (kbd_strobe !== 1'b0) fail("wire: the program's $C010 did not clear the real strobe");
        if (key_reads(mark) != 1) fail("wire: the real key was seen other than exactly once");
        check_counts(0, 0, 0, 0, 0, "wire");
        if (strobe !== 1'b0 || changes != 0) fail("wire: strobe or changed moved with nothing pressed");
        else $display("  ok: nothing pressed, nothing counted");
        check_agree(0, "wire");

        // --- case 2 / a press: the next $C000 read returns it ----------------
        mark = ncommit;
        host_press(7'h42);
        if (strobe !== 1'b1 || seen !== 1'b0) fail("press: strobe not set, or seen set, by the press");
        wait_consumed("press");
        cycles(3);
        if (mem[KEYS+1] !== 8'hC2) fail("press: the program did not store $C2");
        else $display("  ok: the host's 'B' reads as $C2, bit 7 set, and the program stored it");
        check_counts(1, 1, 0, 0, 0, "press");
        if (changes != 1 || last_resolved !== 7'h42) fail("press: one taken did not pulse changed once with the key");
        else $display("  ok: pressed 1, taken 1, changed once carrying 'B'");
        if (key_reads(mark) != 1) fail("press: the key was seen other than exactly once");
        else $display("  ok: seen exactly once - the $C010 that followed cleared it");
        if (kbd_strobe !== 1'b0 || kbd_key !== 7'h41) fail("press: the machine's own keyboard was disturbed");
        else $display("  ok: the machine's own keyboard latch is untouched");
        check_agree(mark, "press");

        // --- case 3 / a string, one key per consumption ----------------------
        mark = ncommit;
        host_press(7'h48); wait_consumed("string H");
        host_press(7'h49); wait_consumed("string I");
        host_press(7'h0D); wait_consumed("string CR");
        cycles(3);
        if (mem[KEYS+2] !== 8'hC8 || mem[KEYS+3] !== 8'hC9 || mem[KEYS+4] !== 8'h8D)
            fail("string: HI<CR> did not arrive as $C8 $C9 $8D");
        else $display("  ok: 'HI' and Return typed one per consumption arrive in order as $C8 $C9 $8D");
        if (key_reads(mark) != 3) fail("string: a key was seen other than exactly once");
        check_counts(4, 4, 0, 0, 0, "string");
        if (changes != 4) fail("string: changed did not pulse once per key");
        check_agree(mark, "string");

        // --- case 4 / a press at every offset across the bus cycle -----------
        keys[0] = 7'h30; offs[0] = 5;
        keys[1] = 7'h31; offs[1] = 30;
        keys[2] = 7'h32; offs[2] = BUS_AT - 1;
        keys[3] = 7'h33; offs[3] = BUS_AT + 1;
        keys[4] = 7'h34; offs[4] = BUS_AT + 2;
        keys[5] = 7'h35; offs[5] = 90;
        keys[6] = 7'h36; offs[6] = CYCLE - 1;
        keys[7] = 7'h37; offs[7] = 96;          // the sample tap itself
        mark = ncommit;
        for (k = 0; k < 8; k = k + 1) begin
            at_offset(offs[k]);
            press_key = keys[k]; press = 1'b1;
            @(negedge clk); press = 1'b0;
            wait_consumed("offsets");
        end
        cycles(3);
        n = 0;
        for (k = 0; k < 8; k = k + 1)
            if (mem[KEYS+5+k] !== {1'b1, keys[k]}) n = n + 1;
        if (n != 0) begin
            $display("FAIL: offsets: %0d of 8 keys stored wrong", n); errors = errors + 1;
        end else $display("  ok: 8 presses at 8 offsets across the cycle, each stored whole and in order");
        if (key_reads(mark) != 8) fail("offsets: a key was seen other than exactly once");
        else $display("  ok: each seen exactly once - never torn, never doubled");
        for (i = mark; i < ncommit; i = i + 1)
            if (log_rw[i] && log_addr[i][15:4] == 12'hC00 && log_din[i][7]) begin
                n = 0;
                for (k = 0; k < 8; k = k + 1) if (log_din[i][6:0] == keys[k]) n = 1;
                if (!n) fail("offsets: a key read carried a byte that was never pressed");
            end
        check_counts(12, 12, 0, 0, 0, "offsets");
        check_agree(mark, "offsets");

        // --- case 5 / a real key after the injected ones reads normally ------
        mark = ncommit;
        real_press(7'h52, 40);
        cycles(20);
        if (mem[KEYS+13] !== 8'hD2) fail("after: a real 'R' after the injected keys did not read as $D2");
        else $display("  ok: a real 'R' afterwards reads as $D2 - the keyboard is the machine's again");
        check_counts(12, 12, 0, 0, 0, "after");
        check_agree(mark, "after");

        // --- case 6 / the strobe-clear rules, one read at a time -------------
        machine_reset(P_RULES);
        cycles(1);                              // RES' reaches the core through the synchroniser
        host_press(7'h4B);                      // 'K', before the first read
        cycles(40);
        idx = nth_kbd_read(0, 0);
        if (idx < 0 || log_din[idx] !== 8'hCB) fail("rules: r0 did not return the key");
        idx = nth_kbd_read(0, 1);
        if (idx < 0 || log_din[idx] !== 8'hCB) fail("rules: r1 - the key did not persist to a second read");
        else $display("  ok: the key persists across reads until the strobe is cleared");
        idx = first_read_of(0, 16'hC019);
        if (idx < 0) fail("rules: no $C019 read");
        else if (log_din[idx] !== {1'b0, kbd_key}) fail("rules: the $C019 read's data was touched");
        else $display("  ok: a $C019 read returns the machine's byte, untouched");
        idx = nth_kbd_read(0, 2);
        if (idx < 0 || log_din[idx] !== 8'hCB) fail("rules: r2 - a $C019 read cleared the strobe");
        else $display("  ok: and does not clear the strobe - r2 still returns the key");
        idx = nth_kbd_read(0, 3);
        if (idx < 0 || log_din[idx] !== 8'h4B) fail("rules: r3 - after a $C015 write the byte is not the key with bit 7 clear");
        else $display("  ok: a write to $C015 clears it - r3 reads $4B, the latch after its strobe");
        idx = nth_kbd_read(0, 4);
        if (idx < 0 || log_din[idx] !== 8'h4B) fail("rules: r4 - a $C000 write changed something");
        else $display("  ok: a write to $C000 (80STOREOFF) does nothing");
        check_counts(13, 13, 0, 0, 0, "rules");
        if (strobe !== 1'b0) fail("rules: strobe still set");
        check_agree(0, "rules");

        // --- case 7 / a second press replaces an unconsumed first ------------
        mem[KEYS] = 8'h00;
        machine_reset(P_LATE);
        cycles(3);  host_press(7'h41);          // 'A', during the delay loop
        cycles(3);  host_press(7'h42);          // 'B', before anything read 'A'
        repeat (3) @(posedge clk);              // changed is registered, counted a clock later
        if (last_resolved !== 7'h41 || changes != 14) fail("replace: the replaced 'A' was not resolved at the press");
        cycles(1400);
        if (mem[KEYS] !== 8'hC2) fail("replace: the program did not get the newer key");
        else $display("  ok: a second press before the first is consumed replaces it - the program got 'B'");
        for (i = 0; i < ncommit; i = i + 1)
            if (log_rw[i] && log_addr[i][15:4] == 12'hC00 && log_din[i] == 8'hC1)
                fail("replace: the replaced key was seen");
        check_counts(15, 14, 0, 1, 0, "replace");
        if (changes != 15 || last_resolved !== 7'h42) fail("replace: two resolutions did not make two changes");
        else $display("  ok: 'A' resolved as replaced at the press, 'B' as taken - two presses, two resolutions");
        check_agree(0, "replace");

        // --- case 8 / a press over a real key waiting: injected wins ---------
        mem[KEYS] = 8'h00;
        machine_reset(P_LATE);
        real_press(7'h52, 20);                  // 'R' at the Apple, during the delay
        cycles(3);  host_press(7'h49);          // 'I' from the host, over it
        cycles(1400);
        if (mem[KEYS] !== 8'hC9) fail("over: the program did not get the host's key");
        else $display("  ok: a press over a waiting real key wins - the program got 'I'");
        if (kbd_strobe !== 1'b0) fail("over: the program's $C010 did not clear the real strobe too");
        else $display("  ok: the one $C010 cleared the machine's strobe as well");
        check_counts(16, 15, 0, 1, 0, "over");
        check_agree(0, "over");

        // --- case 9 / held by the boot hold: Return continues the menu -------
        arm = 1'b1;
        machine_reset(P_RDKEY);
        cycles(12);
        if (held !== 1'b1) fail("hold: not held");
        mark = ncommit;
        host_press(7'h0D);
        wait_consumed("hold");
        cycles(3);
        n = 0;
        for (i = mark; i < ncommit; i = i + 1)
            if (log_ovr[i] && log_addr[i] == 16'hC000 && log_din[i][7]) begin
                n = n + 1;
                if (log_din[i] !== 8'h8D) fail("hold: the key event carried the wrong code");
                if (i + 1 >= ncommit || log_addr[i+1] !== 16'hC010) fail("hold: the key event was not followed by one $C010");
                else if (i + 2 < ncommit && log_addr[i+2] == 16'hC010) fail("hold: two $C010s");
            end
        if (n != 1) begin
            $display("FAIL: hold: %0d key events for one injected Return", n); errors = errors + 1;
        end else $display("  ok: held, an injected Return is one $C000 event carrying $8D, then one $C010");
        check_counts(17, 16, 0, 1, 0, "hold");
        check_agree(mark, "hold");
        arm = 1'b0;
        pulse_release;
        cycles(20);
        if (held !== 1'b0) fail("hold: not released");

        // --- case 10 / a RES' drops the key -----------------------------------
        machine_reset(P_SPIN);
        cycles(12);
        host_press(7'h5A);
        cycles(5);
        if (strobe !== 1'b1) fail("reset: the key is not waiting");
        changes_before = changes;
        mem[KEYS] = 8'h00;
        machine_reset(P_RDKEY);
        if (strobe !== 1'b0) fail("reset: the strobe survived the reset");
        cycles(30);
        if (key_reads(0) != 0 || mem[KEYS] !== 8'h00) fail("reset: the dropped key was read after the reset");
        else $display("  ok: a RES' drops a waiting key - the program after the reset never sees it");
        check_counts(18, 16, 0, 1, 1, "reset");
        if (changes != changes_before + 1 || last_resolved !== 7'h5A)
            fail("reset: the drop was not one resolution carrying 'Z'");
        else $display("  ok: resolved as dropped - pressed - strobe - the rest - and changed once");
        check_agree(0, "reset");

        // --- case 11 / drop --------------------------------------------------
        machine_reset(P_SPIN);
        cycles(12);
        host_press(7'h59);
        cycles(2);
        changes_before = changes;
        host_drop;
        repeat (3) @(posedge clk);
        if (strobe !== 1'b0) fail("drop: the strobe survived drop");
        else $display("  ok: drop clears a waiting key");
        if (changes != changes_before + 1 || last_resolved !== 7'h59) fail("drop: not one resolution carrying 'Y'");
        machine_reset(P_RDKEY);
        cycles(30);
        if (key_reads(0) != 0) fail("drop: the dropped key was read");
        check_counts(19, 16, 0, 1, 2, "drop");
        check_agree(0, "drop");

        // --- case 12 / master_active low: a wire ----------------------------
        machine_reset(P_RDKEY);
        cycles(12);
        master_active = 1'b0;
        cycles(2);
        subs_before = kbd_subs;
        host_press(7'h58);
        cycles(10);
        if (kbd_subs != subs_before) fail("inactive: the substitution asserted with the native CPU driving");
        else $display("  ok: with master_active low nothing is substituted");
        if (strobe !== 1'b1) fail("inactive: the key did not wait");
        host_drop;
        master_active = 1'b1;
        check_counts(20, 16, 0, 1, 3, "inactive");

        // --- case 13 / the buttons on hardware: a wire, and the levels read back
        btn_hw = 3'b101;                        // PB0 and PB2 down at the game port
        subs_before = pb_subs;
        machine_reset(P_PB);
        cycles(40);
        if (mem[KEYS] !== 8'hAA || mem[KEYS+1] !== 8'h2A || mem[KEYS+2] !== 8'hAA)
            fail("buttons hw: $C061-$C063 did not read the game port's levels");
        else $display("  ok: on hardware, $C061-$C063 read the game port's own levels over the bus's low bits");
        if (pb_subs != subs_before) fail("buttons hw: the substitution asserted with every button on hardware");
        if (pb_hw !== 3'b101) fail("buttons hw: the readback of the hardware levels is wrong");
        else $display("  ok: the register's hw field reads back what the bus said");
        check_agree(0, "buttons hw");

        // --- case 14 / down and up, per button, over the bus's low bits -----
        btn_hw = 3'b010;                        // only PB1 down at the game port
        pb_sel = 6'b00_01_10;                   // PB0 down, PB1 up, PB2 hardware
        machine_reset(P_PB);
        cycles(60);                             // five reads and five stores after the reset sequence
        if (mem[KEYS] !== 8'hAA) fail("buttons: PB0 down did not read as bit 7 set");
        else if (mem[KEYS+1] !== 8'h2A) fail("buttons: PB1 up did not mask the pressed hardware button");
        else if (mem[KEYS+2] !== 8'h2A) fail("buttons: PB2 on hardware did not read the bus");
        else $display("  ok: PB0 down reads $AA, PB1 up reads $2A over a pressed button, PB2 is the bus's");
        if (mem[KEYS+3] !== 8'h2A || mem[KEYS+4] !== 8'h2A) fail("buttons: $C060 or $C064 was touched");
        else $display("  ok: $C060 and $C064 are untouched");
        if (pb_hw !== 3'b010) fail("buttons: the hw readback does not still say what the bus said");
        else $display("  ok: the hw readback still reports the hardware under the override");
        check_agree(0, "buttons");

        // --- case 15 / the override survives a RES' ---------------------------
        // Open-Apple-Ctrl-Reset is what Open-Apple is for: the reset handler
        // reads it AFTER the reset, so the level must still be there.
        pb_sel = 6'b00_00_10;                   // Open-Apple down
        btn_hw = 3'b000;
        machine_reset(P_PB);
        cycles(40);
        if (mem[KEYS] !== 8'hAA) fail("buttons reset: Open-Apple was not down after the reset");
        else $display("  ok: Open-Apple held down reads down after a RES' - the reset handler would see it");
        if (mem[KEYS+1] !== 8'h2A) fail("buttons reset: Closed-Apple changed");
        check_agree(0, "buttons reset");

        // --- case 16 / master_active low: the buttons are a wire too ---------
        master_active = 1'b0;
        subs_before = pb_subs;
        machine_reset(P_PB);
        cycles(40);
        if (pb_subs != subs_before) fail("buttons inactive: substituted with the native CPU driving");
        else $display("  ok: with master_active low the buttons are a wire too");
        master_active = 1'b1;
        pb_sel = 6'd0;

        // --- case 17 / flushed: a $C010 with nothing having read the key ----
        machine_reset(P_FLUSH);
        cycles(3);  host_press(7'h46);          // 'F', during the delay loop
        cycles(3);
        if (seen !== 1'b0) fail("flush: seen set before any read");
        changes_before = changes;
        cycles(1400);                           // the delay loop, then the $C010
        if (strobe !== 1'b0) fail("flush: the $C010 did not clear the strobe");
        if (key_reads(0) != 0) fail("flush: the key was read");
        check_counts(21, 16, 1, 1, 3, "flush");
        if (changes != changes_before + 1 || last_resolved !== 7'h46) fail("flush: not one resolution carrying 'F'");
        else $display("  ok: a $C010 with no read before it resolves the key as flushed, not taken");
        check_agree(0, "flush");

        // --- case 18 / the latch after a real key: bit 7 clear, the key beneath
        machine_reset(P_RULES);
        cycles(1);
        real_press(7'h4D, 30);                  // a real 'M', before the first read
        cycles(40);
        idx = nth_kbd_read(0, 0);
        if (idx < 0 || log_din[idx] !== 8'hCD) fail("latch: r0 did not return the real key");
        idx = nth_kbd_read(0, 3);
        if (idx < 0 || log_din[idx] !== 8'h4D) fail("latch: r3 after the clear is not $4D");
        else $display("  ok: a real key, once cleared, still reads as the key with bit 7 clear");
        check_counts(21, 16, 1, 1, 3, "latch");
        check_agree(0, "latch");

        // --- case 19 / the lock: the machine's keyboard is not the program's -
        lock = 1'b1;
        cycles(1);
        if (touched !== 1'b0) fail("lock: touched set with nothing suppressed");
        mem[KEYS] = 8'h00; mem[KEYS+1] = 8'h00;
        machine_reset(P_RDKEY);
        cycles(12);
        changes_before = changes;
        real_press(7'h52, 30);                  // 'R' at the Apple
        cycles(30);
        if (mem[KEYS] !== 8'h00 || key_reads(0) != 0) fail("lock: the real key reached the program");
        else $display("  ok: locked, a real 'R' never reaches the program - RDKEY keeps waiting");
        if (touched !== 1'b1 || changes != changes_before + 1) fail("lock: touched not set, once, by the suppressed key");
        else $display("  ok: touched says it came, and changed pulsed once");
        if (kbd_strobe !== 1'b1) fail("lock: the machine's own strobe did not stay pending");
        mark = ncommit;
        host_press(7'h4C);                      // 'L' from the host, under the lock
        wait_consumed("lock");
        cycles(3);
        if (mem[KEYS] !== 8'hCC) fail("lock: the injected key did not reach the program");
        else $display("  ok: an injected 'L' does reach it, as $CC");
        if (kbd_strobe !== 1'b0) fail("lock: the $C010 that took 'L' did not clear the pending real strobe");
        else $display("  ok: and the $C010 that took it cleared the pending real key too");
        check_counts(22, 17, 1, 1, 3, "lock");
        changes_before = changes;
        real_press(7'h53, 30);                  // 'S' at the Apple, still locked
        cycles(20);
        if (mem[KEYS+1] !== 8'h00) fail("lock: a second real key reached the program");
        if (changes != changes_before) fail("lock: touched pulsed changed twice");
        else $display("  ok: a second real key is suppressed silently - touched is sticky");
        lock = 1'b0;
        cycles(20);
        if (mem[KEYS+1] !== 8'hD3) fail("unlock: the pending real key did not show through");
        else $display("  ok: the lock lifted, the pending 'S' reads as $D3");
        if (touched !== 1'b1) fail("unlock: touched cleared by the unlock");
        check_agree(0, "lock");

        // --- case 20 / locked, any-key-down is masked; a fresh lock clears touched
        lock = 1'b1;
        cycles(1);
        if (touched !== 1'b0) fail("relock: a fresh lock did not clear touched");
        else $display("  ok: a fresh lock clears touched");
        mem[KEYS] = 8'h00; mem[KEYS+1] = 8'h00;
        machine_reset(P_AKD);
        real_press(7'h54, 30);                  // 'T' down at the Apple
        cycles(40);
        if (mem[KEYS] !== 8'h53) fail("akd: a locked $C010 read did not return {0, last key}");
        else $display("  ok: locked, a $C010 read returns bit 7 clear with the last key beneath - no any-key-down");
        if (mem[KEYS+1] !== 8'h53) fail("akd: the $C000 read after it leaked the real key");
        else $display("  ok: the $C000 read after it is the latch, not the real 'T'");
        check_agree(0, "akd");
        lock = 1'b0;
        kbd_strobe = 1'b0;

        // --- case 21 / every resolution, and every touch, pulsed changed once
        if (changes != taken + flushed + replaced + dropped(1'b0) + touches)
            fail("changed: pulses do not equal resolutions plus touches");
        else $display("  ok: changed pulsed once per resolution and once per touch, %0d in all", changes);


        // ====================================================================
        // The hotkey: the one real key that is the card's.
        $display("");
        begin : hotkey_cases
            integer hits0, p0, t0, f0, r0, d0, ovr_at, c010_at;
            p0 = pressed; t0 = taken; f0 = flushed; r0 = replaced; d0 = dropped(1'b0);

            // --- case 22 / read by the program: eaten, and the hold engages --
            menu_en = 1'b1;
            mem[KEYS] = 8'h00;
            machine_reset(P_RDKEY);
            cycles(12);
            mark = ncommit;
            hits0 = hits;
            real_press(HOTKEY, 30);
            cycles(20);
            if (held !== 1'b1 || runtime !== 1'b1) fail("hotkey: the program's read did not open the hold");
            else if (hits != hits0 + 1) fail("hotkey: hotkey_hit did not pulse exactly once");
            else $display("  ok: the program read the hotkey, hotkey_hit pulsed once, and the machine is held (runtime)");
            if (mem[KEYS] !== 8'h00) fail("hotkey: the program stored the hotkey");
            if (key_reads(mark) != 0) fail("hotkey: a $C00x read returned the hotkey with bit 7 set");
            else $display("  ok: no read - the program's or the hold's - ever returned it: the program saw the latch, no strobe");
            ovr_at = -1;
            for (i = mark; i < ncommit; i = i + 1)
                if (ovr_at < 0 && log_ovr[i]) ovr_at = i;
            if (ovr_at < 0 || log_addr[ovr_at] !== 16'hC010) fail("hotkey: the hold's first cycle is not the $C010");
            else if (kbd_strobe !== 1'b0) fail("hotkey: the strobe was left set");
            else $display("  ok: the hold's first cycle cleared the hotkey's strobe");
            check_counts(p0, t0, f0, r0, d0, "hotkey");
            check_agree(mark, "hotkey");
            // A real key while held reaches the host - and is last_read now.
            mark = ncommit;
            real_press(7'h41, 30);
            cycles(4);
            if (key_reads(mark) != 1) fail("hotkey: a key pressed while held was not seen once");
            check_agree(mark, "hotkey/held key");
            // Released, the program goes on: the next key is stored.
            pulse_release;
            cycles(10);
            if (held !== 1'b0) fail("hotkey: not released");
            real_press(7'h42, 30);
            cycles(20);
            if (mem[KEYS] !== 8'hC2) fail("hotkey: after the release the program did not take the next key");
            else $display("  ok: released, the program went on and took the next key");
            check_counts(p0, t0, f0, r0, d0, "hotkey/after");

            // --- case 23 / the door shut: an ordinary key ---------------------
            menu_en = 1'b0;
            mem[KEYS] = 8'h00;
            machine_reset(P_RDKEY);
            cycles(12);
            hits0 = hits;
            real_press(HOTKEY, 30);
            cycles(20);
            if (held !== 1'b0) fail("shut: the hotkey held with the door shut");
            else if (mem[KEYS] !== 8'h9E) fail("shut: the program did not get the key as an ordinary key");
            else if (hits != hits0) fail("shut: hotkey_hit pulsed with the door shut");
            else $display("  ok: with the door shut, Ctrl-6 is a key like any other");

            // --- case 24 / under the lock: not looked for -------------------
            menu_en = 1'b1;
            mem[KEYS] = 8'h00;
            machine_reset(P_RDKEY);
            cycles(12);
            @(negedge clk); lock = 1'b1;
            cycles(2);
            hits0 = hits;
            real_press(HOTKEY, 30);
            cycles(20);
            if (held !== 1'b0 || hits != hits0) fail("lock: the hotkey opened the hold under the lock");
            else if (touched !== 1'b1) fail("lock: the hotkey under the lock did not count as a touch");
            else if (mem[KEYS] !== 8'h00) fail("lock: the program got the key under the lock");
            else $display("  ok: under the lock the hotkey is just a touch - the host has the register to knock with");
            @(negedge clk); kbd_strobe = 1'b0; lock = 1'b0;     // the key taken away before the lock lifts
            cycles(4);

            // --- case 25 / an injected key ahead of it wins -------------------
            // P_LATE reads once, late: both keys are waiting by then.  The
            // injected key is what the read returns; the $C010 that takes it
            // clears the motherboard's strobe too, and the hotkey is gone
            // with it - what that access means.
            mem[KEYS] = 8'h00;
            machine_reset(P_LATE);
            cycles(12);
            hits0 = hits;
            host_press(7'h51);
            real_press(HOTKEY, 30);
            cycles(1400);                                   // P_LATE's delay, then its one read
            if (strobe !== 1'b0) fail("ahead: the injected key was never consumed");
            if (mem[KEYS] !== 8'hD1) fail("ahead: the program did not get the injected key");
            else if (held !== 1'b0 || hits != hits0) fail("ahead: the hotkey behind an injected key opened the hold");
            else $display("  ok: an injected key ahead of the hotkey is what the program gets; the hotkey went with the $C010");
            check_counts(p0 + 1, t0 + 1, f0, r0, d0, "ahead");
            check_agree(0, "ahead");

            // --- case 26 / no scan: a program that never reads is never paused
            machine_reset(P_SPIN);
            cycles(12);
            mark = ncommit;
            hits0 = hits;
            real_press(HOTKEY, 30);
            cycles(300);
            if (held !== 1'b0 || hits != hits0) fail("no scan: the hotkey held a program that never reads");
            else if (kbd_subs != 0 && ncommit > mark && key_reads(mark) != 0) fail("no scan: a read showed it");
            else $display("  ok: a program that never reads the keyboard is never paused by the key - no scan");
            n = 0;
            for (i = mark; i < ncommit; i = i + 1) if (log_ovr[i]) n = n + 1;
            if (n != 0) fail("no scan: an override op went out");
            check_agree(mark, "no scan");
            @(negedge clk); kbd_strobe = 1'b0;
            // The register's knock is the way in; from there case 27.
            machine_reset(P_SPIN);
            cycles(12);
            @(negedge clk); u_hold.menu_pend = 1'b1;   // as MENU_HOLD's trigger would
            cycles(12);
            if (held !== 1'b1 || runtime !== 1'b1) fail("no scan: the knock did not hold");
            check_counts(p0 + 1, t0 + 1, f0, r0, d0, "no scan");

            // --- case 27 / while held, the hotkey passes through ------------
            mark = ncommit;
            hits0 = hits;
            real_press(HOTKEY, 30);
            cycles(4);
            if (key_reads(mark) != 1) fail("held: the hotkey pressed while held was not one key event");
            else if (hits != hits0) fail("held: the hotkey pressed while held was eaten");
            else $display("  ok: while held the hotkey reaches the host like any key - the host may make it 'leave'");
            check_agree(mark, "held/hotkey");
            pulse_release;
            cycles(20);
            if (held !== 1'b0) fail("held: not released");
            menu_en = 1'b0;
        end

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
