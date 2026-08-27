`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// kbd_inject_tb - a key from the host, read by the soft core as the keyboard.
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
//   * idle, it is a wire: a real key is seen once, bit for bit, $C010 clears
//     it, and the substitution never asserts.
//   * a pressed key is what the next $C00x read returns, bit 7 set, and what
//     every read after it returns until a $C010 access - then never again,
//     and the machine's own byte is what reads after that.
//   * a $C010 access clears; a write to $C015 clears; a read of $C019 does
//     not, and returns the machine's byte; a write to $C000 does nothing.
//   * din and the captured event agree on every cycle, injected or not.
//   * a second press before the first is consumed replaces it: the machine
//     sees the newer key, once, and `taken` counts one.
//   * a press over a real key waiting replaces that too, and a real key
//     pressed after the injected one was consumed reads normally.
//   * keys pressed one per consumption go through RDKEY-shaped code in
//     order, exactly once each - at every offset across the bus cycle, and
//     never torn.
//   * held by the boot hold, an injected $0D is one $C000 event with bit 7
//     set, followed by exactly one $C010.
//   * a RES' drops it; `drop` drops it; with master_active low nothing is
//     substituted.
//////////////////////////////////////////////////////////////////////////////////

module kbd_inject_tb #(parameter UCODE = "cpu65c02_ucode.hex");

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
        .addr (cpu_addr), .rw (cpu_rw), .dout (cpu_dout), .din (cpu_din),
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
        .master_active (master_active),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .drv_sync (drv_sync),
        .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (1'b0), .slot_rd_data (8'h00),
        .din_sub_en (sub_en), .din_sub_data (sub_data),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (ovr_rw),
        .ovr_wdata (ovr_wdata), .op_ovr (op_ovr),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- the hold, so an injected key can continue the menu -----------------
    reg  arm = 1'b0, release_req = 1'b0;
    wire held;

    boot_hold u_hold (
        .clk (clk), .cpu_rst (cpu_rst),
        .master_active (master_active),
        .arm (arm), .release_req (release_req),
        .cpu_sync (cpu_sync),
        .op_present (op_present), .op_commit (op_commit),
        .op_sync (drv_sync), .op_ovr (op_ovr), .din (cpu_din),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr),
        .held (held)
    );
    assign ovr_rw = 1'b1;
    assign ovr_wdata = 8'h00;

    // ---- the DUTs: the keyboard, and the buttons beside it ------------------
    reg        press = 1'b0, drop = 1'b0;
    reg  [6:0] press_key = 7'h00;
    wire       strobe;
    wire [7:0] taken;
    wire       kbd_sub_en, pb_sub_en;
    wire [7:0] kbd_sub_data, pb_sub_data;
    reg  [5:0] pb_sel = 6'd0;
    wire [2:0] pb_hw;

    kbd_inject dut (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst),
        .master_active (master_active),
        .press (press), .press_key (press_key), .drop (drop),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .sub_en (kbd_sub_en), .sub_data (kbd_sub_data),
        .strobe (strobe), .taken (taken)
    );

    pb_inject dut_pb (
        .clk (clk), .rst (rst),
        .master_active (master_active),
        .sel (pb_sel),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .data_sync (data_s),
        .sub_en (pb_sub_en), .sub_data (pb_sub_data),
        .hw_level (pb_hw)
    );

    // As master_top merges them.
    assign sub_en   = kbd_sub_en | pb_sub_en;
    assign sub_data = kbd_sub_en ? kbd_sub_data : pb_sub_data;

    integer sub_clocks = 0;                     // clocks with sub_en high
    always @(posedge clk) if (sub_en) sub_clocks = sub_clocks + 1;

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
                // Any-key-down in bit 7, the key beneath; the strobe clears.
                bus_data   <= {1'b1, kbd_key};
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
        integer i, seen;
        begin
            nth_kbd_read = -1; seen = 0;
            for (i = from; i < ncommit; i = i + 1)
                if (log_rw[i] && log_addr[i][15:4] == 12'hC00) begin
                    if (seen == n && nth_kbd_read < 0) nth_kbd_read = i;
                    seen = seen + 1;
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

    integer i, k, idx, mark, mark_cap, n, subs_before;
    reg [7:0] tk;
    reg [6:0] keys [0:7];
    integer   offs [0:7];

    initial begin
        $display("kbd_inject_tb: a key from the host, on the keyboard the soft core reads\n");

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
        //   F10F  LDA $C000       r3: the machine's byte
        //   F112  STA $C000       80STOREOFF: nothing
        //   F115  LDA $C000       r4: the machine's byte
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
        for (i = 0; i < 16; i = i + 1) mem[KEYS + i] = 8'h00;

        repeat (8) @(posedge clk);
        rst = 0;
        cycles(3);

        // --- case 1 / idle, a real key: a wire -------------------------------
        machine_reset(P_RDKEY);
        cycles(12);
        mark = ncommit;
        real_press(7'h41, 30);
        cycles(20);
        if (mem[KEYS] !== 8'hC1) fail("wire: the real key did not reach the program as $C1");
        else $display("  ok: idle, a real 'A' reads as $C1 and is stored by the program");
        if (kbd_strobe !== 1'b0) fail("wire: the program's $C010 did not clear the real strobe");
        if (key_reads(mark) != 1) fail("wire: the real key was seen other than exactly once");
        if (sub_clocks != 0) fail("wire: the substitution asserted with nothing pressed");
        else $display("  ok: the substitution never asserted");
        if (taken !== 8'd0 || strobe !== 1'b0) fail("wire: taken or strobe moved with nothing pressed");
        check_agree(0, "wire");

        // --- case 2 / a press: the next $C000 read returns it ----------------
        mark = ncommit;
        host_press(7'h42);
        if (strobe !== 1'b1) fail("press: strobe not set by the press");
        wait_consumed("press");
        cycles(3);
        if (mem[KEYS+1] !== 8'hC2) fail("press: the program did not store $C2");
        else $display("  ok: the host's 'B' reads as $C2, bit 7 set, and the program stored it");
        if (taken !== 8'd1) fail("press: taken is not 1");
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
        if (taken !== 8'd4) fail("string: taken is not 4");
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
        if (taken !== 8'd12) fail("offsets: taken is not 12");
        check_agree(mark, "offsets");

        // --- case 5 / a real key after the injected ones reads normally ------
        mark = ncommit;
        real_press(7'h52, 40);
        cycles(20);
        if (mem[KEYS+13] !== 8'hD2) fail("after: a real 'R' after the injected keys did not read as $D2");
        else $display("  ok: a real 'R' afterwards reads as $D2 - the keyboard is the machine's again");
        if (taken !== 8'd12) fail("after: a real key counted as taken");
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
        if (idx < 0 || log_din[idx][7] !== 1'b0) fail("rules: r3 - a $C015 write did not clear the strobe");
        else if (log_din[idx] !== {1'b0, kbd_key}) fail("rules: r3 - after the clear the byte is not the machine's");
        else $display("  ok: a write to $C015 clears it - r3 reads the machine's own byte");
        idx = nth_kbd_read(0, 4);
        if (idx < 0 || log_din[idx][7] !== 1'b0) fail("rules: r4 - a $C000 write changed something");
        else $display("  ok: a write to $C000 (80STOREOFF) does nothing");
        if (taken !== 8'd13) fail("rules: taken is not 13");
        if (strobe !== 1'b0) fail("rules: strobe still set");
        check_agree(0, "rules");

        // --- case 7 / a second press replaces an unconsumed first ------------
        mem[KEYS] = 8'h00;
        machine_reset(P_LATE);
        cycles(3);  host_press(7'h41);          // 'A', during the delay loop
        cycles(3);  host_press(7'h42);          // 'B', before anything read 'A'
        cycles(1400);
        if (mem[KEYS] !== 8'hC2) fail("replace: the program did not get the newer key");
        else $display("  ok: a second press before the first is consumed replaces it - the program got 'B'");
        for (i = 0; i < ncommit; i = i + 1)
            if (log_rw[i] && log_addr[i][15:4] == 12'hC00 && log_din[i] == 8'hC1)
                fail("replace: the replaced key was seen");
        if (taken !== 8'd14) fail("replace: taken is not 14 - one key, one consumption");
        else $display("  ok: taken counts one");
        check_agree(0, "replace");

        // --- case 8 / a press over a real key waiting: newest wins -----------
        mem[KEYS] = 8'h00;
        machine_reset(P_LATE);
        real_press(7'h52, 20);                  // 'R' at the Apple, during the delay
        cycles(3);  host_press(7'h49);          // 'I' from the host, over it
        cycles(1400);
        if (mem[KEYS] !== 8'hC9) fail("over: the program did not get the host's key");
        else $display("  ok: a press over a waiting real key replaces it - the program got 'I'");
        if (kbd_strobe !== 1'b0) fail("over: the program's $C010 did not clear the real strobe too");
        else $display("  ok: the one $C010 cleared the machine's strobe as well");
        if (taken !== 8'd15) fail("over: taken is not 15");
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
        if (taken !== 8'd16) fail("hold: taken is not 16");
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
        mem[KEYS] = 8'h00;
        machine_reset(P_RDKEY);
        if (strobe !== 1'b0) fail("reset: the strobe survived the reset");
        cycles(30);
        if (key_reads(0) != 0 || mem[KEYS] !== 8'h00) fail("reset: the dropped key was read after the reset");
        else $display("  ok: a RES' drops a waiting key - the program after the reset never sees it");
        if (taken !== 8'd16) fail("reset: a dropped key counted as taken");
        check_agree(0, "reset");

        // --- case 11 / drop --------------------------------------------------
        machine_reset(P_SPIN);
        cycles(12);
        host_press(7'h59);
        cycles(2);
        host_drop;
        if (strobe !== 1'b0) fail("drop: the strobe survived drop");
        else $display("  ok: drop clears a waiting key");
        machine_reset(P_RDKEY);
        cycles(30);
        if (key_reads(0) != 0) fail("drop: the dropped key was read");
        if (taken !== 8'd16) fail("drop: a dropped key counted as taken");
        check_agree(0, "drop");

        // --- case 12 / master_active low: a wire ----------------------------
        machine_reset(P_RDKEY);
        cycles(12);
        master_active = 1'b0;
        cycles(2);
        subs_before = sub_clocks;
        host_press(7'h58);
        cycles(10);
        if (sub_clocks != subs_before) fail("inactive: the substitution asserted with the native CPU driving");
        else $display("  ok: with master_active low nothing is substituted");
        if (strobe !== 1'b1) fail("inactive: the key did not wait");
        host_drop;
        master_active = 1'b1;

        // --- case 13 / the buttons on hardware: a wire, and the levels read back
        btn_hw = 3'b101;                        // PB0 and PB2 down at the game port
        subs_before = sub_clocks;
        machine_reset(P_PB);
        cycles(40);
        if (mem[KEYS] !== 8'hAA || mem[KEYS+1] !== 8'h2A || mem[KEYS+2] !== 8'hAA)
            fail("buttons hw: $C061-$C063 did not read the game port's levels");
        else $display("  ok: on hardware, $C061-$C063 read the game port's own levels over the bus's low bits");
        if (sub_clocks != subs_before) fail("buttons hw: the substitution asserted with every button on hardware");
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

        // --- case 16 / master_active low: a wire --------------------------------
        master_active = 1'b0;
        subs_before = sub_clocks;
        machine_reset(P_PB);
        cycles(40);
        if (sub_clocks != subs_before) fail("buttons inactive: substituted with the native CPU driving");
        else $display("  ok: with master_active low the buttons are a wire too");
        master_active = 1'b1;
        pb_sel = 6'd0;

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
