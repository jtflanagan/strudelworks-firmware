`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// boot_hold_tb - the soft core stopped at its reset vector, the keyboard read
// on its behalf, and the boot let go on command.
//
// The real core, the real driver and the hold, wired as master_top wires them,
// against an Apple-shaped phi0 and a bus model with a ROM at the vector and a
// keyboard at $C000/$C010.  No microcode knowledge: only what the bus carries
// and what the core does afterwards, which is the interface that has to be
// right.
//
// THE PROPERTIES, each a way this is or could be wrong:
//
//   * unarmed, it is a wire: seven reset cycles then the fetch at the vector,
//     and the program runs.
//   * armed, the cycle that would have been the fetch is a $C000 read, and the
//     core's own outputs still show the fetch - it has consumed nothing.
//   * a key pressed at ANY point in the bus cycle is seen exactly once, as one
//     $C000 read with bit 7 set, followed by exactly one $C010.  The offsets
//     below straddle the sample point deliberately: a blind $C000/$C010
//     alternation loses the ones that land just after it.
//   * the $C010 read's own bit 7 (any-key-down on a IIe) is NOT a key.
//   * released, the very next cycle is the fetch at the vector, and the
//     program runs as if nothing had happened.
//   * released with a key pending, the strobe is cleared BEFORE the fetch.
//   * a RES' bounce while held drops the hold and it re-engages at the next
//     vector fetch.
//   * arming a running machine holds nothing until the next reset.
//
// And the runtime door (docs/RUNTIME_MENU.md), from case 9 on:
//
//   * the hotkey (kbd_inject's pulse, played here) holds a RUNNING program
//     at its next opcode fetch, the first cycle a $C010 - the key's strobe
//     cleared before any read could show it - then $C000 reads; the core
//     does not move; released, the very next cycle is the fetch the core
//     was at, and the program goes on from there without a beat lost.
//   * the register's trigger does the same, starting with $C000: no key.
//   * a RES' while runtime-held drops it and the BOOT hold takes the vector.
//   * the disk's override comes first: its cycles interleave with the
//     hold's, the hold neither reads a key nor releases on one of them, and
//     a runtime hold asked for while the disk is moving waits for it.
//   * a knock while the boot menu is showing is nothing.
//////////////////////////////////////////////////////////////////////////////////

module boot_hold_tb #(parameter UCODE = "cpu65c02_ucode.hex");

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
    reg  res_n = 1'b1;                          // RES', active low
    wire cpu_rst = rst || !res_n;               // as master_top wires it
    reg  master_active = 1'b1;

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

    integer core_steps = 0;                     // cyc_en pulses the core saw
    always @(posedge clk) if (cpu_cyc_en) core_steps = core_steps + 1;

    // ---- the driver -------------------------------------------------------
    reg  [7:0]  data_sync = 8'h00;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, driving, drv_sync;
    wire [7:0]  data_drive;
    wire [15:0] op_addr;
    wire        op_rw, op_present, op_commit, op_ovr;
    wire [7:0]  op_wdata;
    wire        hold_ovr_en;
    wire [15:0] hold_ovr_addr;
    // A stand-in for the disk's override, and master_top's mux: the disk
    // first.
    reg         hd_ovr_en = 1'b0;
    reg  [15:0] hd_ovr_addr = 16'h0200;
    wire        ovr_en   = hold_ovr_en | hd_ovr_en;
    wire [15:0] ovr_addr = hd_ovr_en ? hd_ovr_addr : hold_ovr_addr;

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) u_write (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0), .data_sync (data_sync),
        .master_active (master_active),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .drv_sync (drv_sync),
        .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (1'b0), .slot_rd_data (8'h00),
        .din_sub_en (1'b0), .din_sub_data (8'h00),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (1'b1), .ovr_wdata (8'h00), .op_ovr (op_ovr), .nxt_addr (), .divert (1'b0), .op_divert (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- the hold ---------------------------------------------------------
    reg  arm = 1'b0;
    reg  release_req = 1'b0;
    reg  menu_trigger = 1'b0, hotkey_hit = 1'b0;
    wire held, runtime;

    boot_hold dut (
        .clk (clk), .cpu_rst (cpu_rst),
        .master_active (master_active),
        .arm (arm), .release_req (release_req),
        .menu_trigger (menu_trigger), .hotkey_hit (hotkey_hit),
        .cpu_sync (cpu_sync),
        .op_present (op_present), .op_commit (op_commit),
        .op_sync (drv_sync), .op_ovr (op_ovr),
        .op_addr (op_addr), .op_rw (op_rw), .din (cpu_din),
        .ovr_en (hold_ovr_en), .ovr_addr (hold_ovr_addr),
        .held (held), .runtime (runtime)
    );

    // kbd_inject's part, played here: the hotkey on the bus at a committed
    // $C000 read of the program's while not held is eaten, and the hold is
    // told.  The bus model still returns it (the tb reads
    // the raw byte), which is fine: what the hold does with din[7] while
    // not held is nothing.
    localparam [6:0] HOTKEY = 7'h1E;
    reg  hotkey_en = 1'b0;
    integer hits = 0;
    always @(posedge clk) begin
        hotkey_hit <= 1'b0;
        if (op_commit && op_rw && op_addr == 16'hC000 && !held && hotkey_en &&
            cpu_din[7] && cpu_din[6:0] == HOTKEY) begin
            hotkey_hit <= 1'b1;
            hits = hits + 1;
        end
    end

    integer held_edges = 0;
    reg     held_prev = 1'b0;
    always @(posedge clk) begin
        if (held !== held_prev) held_edges = held_edges + 1;
        held_prev = held;
    end

    // ---- the machine: ROM, RAM and a keyboard -------------------------------
    // The bus answers a read, or takes a write, well inside phi0-high and
    // before the driver's own sample tap.
    localparam integer BUS_AT = 70;
    localparam [15:0] VECTOR = 16'hF000;
    localparam [15:0] MARK   = 16'h0300;

    reg [7:0] mem [0:65535];
    reg [6:0] kbd_key    = 7'h00;
    reg       kbd_strobe = 1'b0;
    integer   c010_reads = 0;

    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        if (rw_drive) begin
            case (addr_drive)
                16'hC000: data_sync <= {kbd_strobe, kbd_key};
                // Any access clears the strobe.  The byte returned carries
                // bit 7 SET - the IIe's any-key-down flag - which the reader
                // must not mistake for a key.
                16'hC010: begin data_sync <= 8'h80; kbd_strobe <= 1'b0;
                                c010_reads = c010_reads + 1; end
                default:  data_sync <= mem[addr_drive];
            endcase
        end else if (data_oe) begin
            mem[addr_drive] <= data_drive;
            data_sync <= data_drive;
        end
    end

    // ---- the op log -------------------------------------------------------
    // Every presented op, in order, with the byte its data phase returned.
    reg [15:0] log_addr [0:4095];
    reg        log_sync [0:4095];
    reg        log_ovr  [0:4095];
    reg [7:0]  log_din  [0:4095];
    integer    nops = 0;
    integer    ncommit = 0;
    always @(posedge clk) begin
        if (op_present) begin
            log_addr[nops] = op_addr;
            log_sync[nops] = drv_sync;
            log_ovr[nops]  = op_ovr;
            log_din[nops]  = 8'hxx;
            nops = nops + 1;
        end
        if (op_commit) begin
            log_din[ncommit] = cpu_din;
            ncommit = ncommit + 1;
        end
    end

    // Invariants, checked on every op: an override is a read, never a SYNC,
    // and never presented when nothing is held or engaging.
    integer bad_ovr = 0;
    always @(posedge clk) if (op_present && op_ovr) begin
        if (op_rw !== 1'b1 || drv_sync !== 1'b0) bad_ovr = bad_ovr + 1;
    end

    // ---- helpers ------------------------------------------------------------
    task cycles(input integer n);
        begin repeat (n * CYCLE) @(posedge clk); end
    endtask

    // Wait for a given offset into a bus cycle, then act on the negedge.
    task at_offset(input integer off);
        begin
            @(posedge clk);
            while (since_fall != off) @(posedge clk);
            @(negedge clk);
        end
    endtask

    // Assert RES' at a cycle's falling edge and release it at one, the log
    // restarted at the release so the reset sequence is at index 0.
    task machine_reset(input integer hold_cycles);
        begin
            at_offset(0);
            res_n = 1'b0;
            cycles(hold_cycles);
            at_offset(0);
            nops = 0; ncommit = 0;
            res_n = 1'b1;
        end
    endtask

    task press(input [6:0] key, input integer off);
        begin
            at_offset(off);
            kbd_key    = key;
            kbd_strobe = 1'b1;
        end
    endtask

    task pulse_release;
        begin
            @(negedge clk); release_req = 1'b1;
            @(negedge clk); release_req = 1'b0;
        end
    endtask

    task pulse_trigger;
        begin
            @(negedge clk); menu_trigger = 1'b1;
            @(negedge clk); menu_trigger = 1'b0;
        end
    endtask

    // The index of the first override op at or after `from`, or -1.
    function integer first_ovr(input integer from);
        integer i;
        begin
            first_ovr = -1;
            for (i = from; i < nops; i = i + 1)
                if (first_ovr < 0 && log_ovr[i]) first_ovr = i;
        end
    endfunction

    // Override ops in [from, to).
    function integer count_ovr(input integer from, input integer to);
        integer i;
        begin
            count_ovr = 0;
            for (i = from; i < to && i < nops; i = i + 1)
                if (log_ovr[i]) count_ovr = count_ovr + 1;
        end
    endfunction

    // The address the core will fetch next: what it shows while held.
    reg [15:0] held_at;
    integer    ovr_at, j, hd_seen;

    // The first SYNC in the log, or -1.
    function integer first_sync(input integer from);
        integer i;
        begin
            first_sync = -1;
            for (i = from; i < nops; i = i + 1)
                if (first_sync < 0 && log_sync[i]) first_sync = i;
        end
    endfunction

    integer i, k, idx, keys_seen, clears_seen, consecutive, mark;
    integer steps_before;
    reg [6:0] keys [0:7];
    integer   offs [0:7];

    initial begin
        $display("boot_hold_tb: the soft core held at its reset vector\n");

        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEA;   // NOP background
        // The program at the vector: mark, then spin.
        //   F000  LDA #$42       A9 42
        //   F002  STA $0300      8D 00 03
        //   F005  JMP $F005      4C 05 F0
        mem[16'hF000] = 8'hA9; mem[16'hF001] = 8'h42;
        mem[16'hF002] = 8'h8D; mem[16'hF003] = 8'h00; mem[16'hF004] = 8'h03;
        mem[16'hF005] = 8'h4C; mem[16'hF006] = 8'h05; mem[16'hF007] = 8'hF0;
        mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'hF0;
        mem[MARK] = 8'h00;

        repeat (8) @(posedge clk);
        rst = 0;
        cycles(3);

        // --- case 1 / unarmed: seven reset cycles, the fetch, the program ----
        machine_reset(4);
        cycles(30);
        idx = first_sync(0);
        if (idx != 7)
            fail("unarmed: the first opcode fetch is not the 8th cycle after reset");
        else if (log_addr[idx] !== VECTOR)
            fail("unarmed: the first fetch is not at the vector");
        else if (log_addr[idx-2] !== 16'hFFFC || log_addr[idx-1] !== 16'hFFFD)
            fail("unarmed: the vector was not read in the two cycles before the fetch");
        else
            $display("  ok: unarmed - two dummy, three stack, $FFFC, $FFFD, then the fetch at $%04x", VECTOR);
        if (held !== 1'b0) fail("unarmed: held");
        if (mem[MARK] !== 8'h42) fail("unarmed: the program did not run");
        else $display("  ok: unarmed - the program ran and left its mark");
        for (i = 0; i < nops; i = i + 1) if (log_ovr[i]) fail("unarmed: an override op was presented");

        // --- case 2 / armed: the fetch cycle becomes a $C000 read -----------
        mem[MARK] = 8'h00;
        arm = 1'b1;
        machine_reset(4);
        cycles(30);
        if (held !== 1'b1) fail("armed: not held after reset");
        else $display("  ok: armed - held after the reset sequence");
        idx = 7;
        if (log_addr[idx-2] !== 16'hFFFC || log_addr[idx-1] !== 16'hFFFD)
            fail("armed: the reset sequence changed");
        if (log_ovr[idx] !== 1'b1 || log_addr[idx] !== 16'hC000 || log_sync[idx] !== 1'b0)
            fail("armed: the cycle after $FFFD is not a $C000 read of ours");
        else
            $display("  ok: armed - the cycle that would have fetched reads $C000 instead");
        if (cpu_sync !== 1'b1 || cpu_addr !== VECTOR)
            fail("armed: the core is not sitting at its fetch");
        else
            $display("  ok: the core's own outputs still show the fetch at $%04x - nothing consumed", cpu_addr);
        if (first_sync(0) >= 0) fail("armed: a SYNC was presented while held");
        if (mem[MARK] !== 8'h00) fail("armed: the program ran anyway");
        steps_before = core_steps;
        for (i = idx; i < nops; i = i + 1) begin
            if (!log_ovr[i] || log_addr[i] !== 16'hC000) fail("armed: a held cycle was not a $C000 read");
        end
        for (i = idx; i < ncommit; i = i + 1) begin
            if (log_din[i][7] !== 1'b0) fail("armed: a key was seen with none pressed");
        end
        $display("  ok: every held cycle so far is a $C000 read, none showing a key");

        // --- case 3 / keys at every phase of the cycle ------------------------
        // Offsets straddle the bus's sample point (BUS_AT): the ones just
        // after it are the presses a blind alternation loses.
        keys[0] = 7'h41; offs[0] = 5;
        keys[1] = 7'h42; offs[1] = 30;
        keys[2] = 7'h43; offs[2] = BUS_AT - 1;
        keys[3] = 7'h44; offs[3] = BUS_AT + 1;
        keys[4] = 7'h45; offs[4] = BUS_AT + 2;
        keys[5] = 7'h46; offs[5] = 90;
        keys[6] = 7'h47; offs[6] = CYCLE - 1;
        keys[7] = 7'h0D; offs[7] = 50;
        mark = ncommit;
        for (k = 0; k < 8; k = k + 1) begin
            press(keys[k], offs[k]);
            cycles(5);
        end
        cycles(2);
        keys_seen = 0; clears_seen = 0; consecutive = 0;
        for (i = mark; i < ncommit; i = i + 1) begin
            if (log_addr[i] == 16'hC000 && log_din[i][7]) begin
                keys_seen = keys_seen + 1;
                if (log_din[i][6:0] !== keys[keys_seen-1])
                    fail("keys: a key event carried the wrong code");
                if (i + 1 >= ncommit || log_addr[i+1] !== 16'hC010)
                    fail("keys: a key event was not followed by exactly one $C010");
            end
            if (log_addr[i] == 16'hC010) begin
                clears_seen = clears_seen + 1;
                if (i == mark || log_addr[i-1] !== 16'hC000 || !log_din[i-1][7])
                    fail("keys: a $C010 read was not preceded by a key event");
                if (i + 1 < ncommit && log_addr[i+1] == 16'hC010) consecutive = consecutive + 1;
            end
        end
        if (keys_seen != 8) begin
            $display("FAIL: keys: %0d of 8 presses seen", keys_seen); errors = errors + 1;
        end else
            $display("  ok: 8 presses at 8 offsets, 8 key events, each seen exactly once");
        if (clears_seen != 8) begin
            $display("FAIL: keys: %0d strobe clears for 8 presses", clears_seen); errors = errors + 1;
        end else
            $display("  ok: one $C010 per key, immediately after it");
        if (consecutive != 0)
            fail("keys: $C010's own bit 7 (any-key-down) was taken for a key");
        else
            $display("  ok: the any-key-down bit on the $C010 read is not a key");
        if (core_steps != steps_before) fail("keys: the core advanced while held");
        else $display("  ok: the core did not advance once in %0d held cycles", ncommit - 7);
        if (held !== 1'b1) fail("keys: the hold dropped");

        // --- case 4 / release: the next cycle is the fetch, and it boots -----
        mark = nops;
        pulse_release;
        cycles(40);
        if (held !== 1'b0) fail("release: still held");
        idx = first_sync(mark);
        if (idx < 0) fail("release: the core never fetched");
        else if (log_addr[idx] !== VECTOR) fail("release: the first fetch is not at the vector");
        else if (log_ovr[idx-1] !== 1'b1) fail("release: something other than ours preceded the fetch");
        else $display("  ok: released - the cycle after the last $C000 read is the fetch at $%04x", VECTOR);
        for (i = idx; i < nops; i = i + 1) if (log_ovr[i]) fail("release: an override after the fetch");
        if (mem[MARK] !== 8'h42) fail("release: the program did not run after release");
        else $display("  ok: the boot went on - the program ran and left its mark");

        // --- case 5 / release with a key pending: cleared BEFORE the fetch ---
        mem[MARK] = 8'h00;
        machine_reset(4);
        cycles(12);
        if (held !== 1'b1) fail("pending: not held");
        mark = nops;
        // The key lands just after the bus answered this cycle's $C000, and
        // the release arrives in the same breath: the $C000 in flight showed
        // no key, so a release that acted on it alone would leave the strobe
        // set for the ROM.
        press(7'h0D, BUS_AT + 1);
        pulse_release;
        cycles(40);
        idx = first_sync(mark);
        if (idx < 0) fail("pending: never fetched");
        else if (log_addr[idx] !== VECTOR) fail("pending: fetch not at the vector");
        else if (log_addr[idx-1] !== 16'hC010) fail("pending: the fetch was not preceded by the strobe clear");
        else if (log_addr[idx-2] !== 16'hC000 || !log_din[idx-2][7]) fail("pending: the clear was not for a seen key");
        else $display("  ok: release with a key pending - key seen, strobe cleared, THEN the fetch");
        if (kbd_strobe !== 1'b0) fail("pending: the strobe was left set for the ROM");
        if (mem[MARK] !== 8'h42) fail("pending: the program did not run");

        // --- case 6 / a RES' bounce while held --------------------------------
        machine_reset(4);
        cycles(12);
        if (held !== 1'b1) fail("bounce: not held before the bounce");
        held_edges = 0;
        at_offset(0); res_n = 1'b0;             // the switch bounces
        cycles(2);
        if (held !== 1'b0) fail("bounce: still held with RES' asserted");
        at_offset(0); nops = 0; ncommit = 0; res_n = 1'b1;
        cycles(12);
        if (held !== 1'b1) fail("bounce: did not re-engage after the bounce");
        else if (held_edges != 2) fail("bounce: expected held to go 0 then 1, once each");
        else if (log_ovr[7] !== 1'b1 || log_addr[6] !== 16'hFFFD)
            fail("bounce: the second hold is not at the vector fetch");
        else $display("  ok: a RES' bounce while held drops the hold and it re-engages at the vector");
        pulse_release;
        cycles(30);
        if (held !== 1'b0) fail("bounce: release after the bounce failed");

        // --- case 7 / arming a running machine holds nothing until reset ----
        arm = 1'b0;
        cycles(2);
        arm = 1'b1;
        steps_before = core_steps;
        cycles(30);
        if (held !== 1'b0) fail("late arm: held a running machine");
        else if (core_steps == steps_before) fail("late arm: the running core stopped");
        else $display("  ok: arming mid-run holds nothing - it waits for the next reset");
        machine_reset(4);
        cycles(12);
        if (held !== 1'b1) fail("late arm: not held at the reset that followed");
        else $display("  ok: and holds at the reset that follows");

        // --- case 8 / disarmed, the next boot goes straight through ----------
        arm = 1'b0;
        pulse_release;
        cycles(20);
        mem[MARK] = 8'h00;
        machine_reset(4);
        cycles(30);
        if (held !== 1'b0) fail("disarmed: held");
        else if (mem[MARK] !== 8'h42) fail("disarmed: the program did not run");
        else $display("  ok: disarmed - the next reset boots straight through");

        // ====================================================================
        // The runtime door.  The program from here on is a counting loop:
        //   F000  LDA #$42 / STA $0300       as before
        //   F005  INC $0301      EE 01 03    6 cycles
        //   F008  JMP $F005      4C 05 F0    3 cycles
        // so a fetch is at $F005 or $F008, and $0301 says the loop is
        // running.  Nothing in it reads the keyboard.
        mem[16'hF005] = 8'hEE; mem[16'hF006] = 8'h01; mem[16'hF007] = 8'h03;
        mem[16'hF008] = 8'h4C; mem[16'hF009] = 8'h05; mem[16'hF00A] = 8'hF0;
        mem[16'h0301] = 8'h00;
        arm = 1'b0;
        $display("");

        // --- case 9 / the hotkey holds a running program at its next fetch --
        machine_reset(4);
        cycles(40);
        if (held !== 1'b0 || mem[16'h0301] == 8'h00) fail("hotkey: the program is not running unheld");
        hotkey_en = 1'b1;
        // The program never reads $C000, so the pulse is the tb's, at an
        // arbitrary point: the key's strobe is set as kbd_inject would have
        // left it.
        mark = nops;
        at_offset(20);
        kbd_key = HOTKEY; kbd_strobe = 1'b1;
        @(negedge clk); hotkey_hit = 1'b1;
        @(negedge clk); hotkey_hit = 1'b0;
        cycles(12);
        if (held !== 1'b1) fail("hotkey: not held");
        else if (runtime !== 1'b1) fail("hotkey: held, but not by the runtime door");
        else $display("  ok: hotkey - a running program is held, runtime=1");
        ovr_at = first_ovr(mark);
        if (ovr_at < 0) fail("hotkey: no override op after the trigger");
        else begin
            // Every op before the hold's first was the core's, and the last
            // of them was NOT a SYNC: the hold took the fetch's cycle.
            for (i = mark; i < ovr_at; i = i + 1)
                if (log_ovr[i]) fail("hotkey: an override before the hold engaged");
            if (log_addr[ovr_at] !== 16'hC010)
                fail("hotkey: the first held cycle is not the $C010 that clears the key");
            else if (log_addr[ovr_at+1] !== 16'hC000)
                fail("hotkey: the $C010 was not followed by a $C000 read");
            else $display("  ok: the first held cycle is one $C010 - the hotkey's strobe cleared before any read");
            if (kbd_strobe !== 1'b0) fail("hotkey: the strobe was left set");
            for (i = ovr_at + 1; i < ncommit; i = i + 1)
                if (log_addr[i] == 16'hC000 && log_din[i][7]) fail("hotkey: the hotkey showed as a key while held");
            if (ovr_at - mark > 12) fail("hotkey: the hold took more than one instruction to engage");
        end
        if (cpu_sync !== 1'b1 || (cpu_addr !== 16'hF005 && cpu_addr !== 16'hF008))
            fail("hotkey: the core is not sitting at a fetch of the loop");
        else $display("  ok: the core's outputs show the fetch at $%04x - an instruction boundary", cpu_addr);
        held_at = cpu_addr;
        steps_before = core_steps;
        k = mem[16'h0301];
        cycles(50);
        if (core_steps != steps_before) fail("hotkey: the core advanced while held");
        if (mem[16'h0301] !== k[7:0]) fail("hotkey: the program ran while held");
        else $display("  ok: the core did not advance and the loop did not count while held");
        if (hits != 0) fail("hotkey: the tb's kbd_inject saw a read of the key - this program reads no keyboard");

        // Keys reach the host while held, as in the boot hold.
        mark = ncommit;
        press(7'h41, 30);
        cycles(4);
        keys_seen = 0;
        for (i = mark; i < ncommit; i = i + 1)
            if (log_addr[i] == 16'hC000 && log_din[i][7]) begin
                keys_seen = keys_seen + 1;
                if (log_din[i][6:0] !== 7'h41) fail("hotkey: wrong key while held");
                if (log_addr[i+1] !== 16'hC010) fail("hotkey: a key while held was not followed by $C010");
            end
        if (keys_seen != 1) fail("hotkey: a key pressed while runtime-held was not seen exactly once");
        else $display("  ok: a key pressed while held is one $C000 event, then one $C010");

        // --- case 10 / release: the program continues from that fetch ------
        mark = nops;
        pulse_release;
        cycles(40);
        if (held !== 1'b0 || runtime !== 1'b0) fail("resume: still held, or runtime still set");
        idx = first_sync(mark);
        if (idx < 0) fail("resume: the core never fetched");
        else if (log_addr[idx] !== held_at) fail("resume: the first fetch is not where the core was held");
        else if (log_ovr[idx-1] !== 1'b1) fail("resume: something other than the hold's read preceded the fetch");
        else if (count_ovr(idx, nops) != 0) fail("resume: an override after the fetch");
        else $display("  ok: released - the next cycle is the fetch at $%04x the core was held at", held_at);
        // ...and the loop's fetches alternate as they would have: INC then
        // JMP, 6 and 3 cycles, no instruction lost or doubled.
        j = idx;
        for (i = idx + 1; i < nops; i = i + 1) begin
            if (log_sync[i]) begin
                if (log_addr[j] == 16'hF005 && (i - j != 6 || log_addr[i] !== 16'hF008))
                    fail("resume: the INC was not followed by the JMP six cycles on");
                if (log_addr[j] == 16'hF008 && (i - j != 3 || log_addr[i] !== 16'hF005))
                    fail("resume: the JMP was not followed by the INC three cycles on");
                j = i;
            end
        end
        if (mem[16'h0301] == k[7:0]) fail("resume: the loop did not go on counting");
        else $display("  ok: the loop went on - INC, JMP, INC - with no beat lost");

        // --- case 11 / the register's trigger: no key, no $C010 -----------
        mark = nops;
        pulse_trigger;
        cycles(12);
        if (held !== 1'b1 || runtime !== 1'b1) fail("trigger: not runtime-held");
        ovr_at = first_ovr(mark);
        if (ovr_at < 0 || log_addr[ovr_at] !== 16'hC000)
            fail("trigger: the first held cycle is not a $C000 read");
        else $display("  ok: the register's knock holds too, and starts reading straight away");
        pulse_release;
        cycles(20);
        if (held !== 1'b0) fail("trigger: not released");

        // --- case 12 / no scan: a program that never reads the keyboard is
        // never paused by the key.  By decision (docs/RUNTIME_MENU.md): the
        // machine's timing is not the menu's to spend.
        mark = nops;
        steps_before = core_steps;
        at_offset(10);
        kbd_key = HOTKEY; kbd_strobe = 1'b1;
        cycles(700);
        if (held !== 1'b0) fail("no scan: held with nobody reading the keyboard");
        else if (count_ovr(mark, nops) != 0) fail("no scan: an override op with nobody asking");
        else if (core_steps - steps_before < 700) fail("no scan: the core lost a cycle");
        else $display("  ok: no scan - the key waits unread, the core lost not one cycle in 700");
        kbd_strobe = 1'b0;
        // ...and the register's knock is what is left.
        pulse_trigger;
        cycles(12);
        if (held !== 1'b1 || runtime !== 1'b1) fail("no scan: the register's knock did not hold");
        else $display("  ok: the register's knock still does");
        mark = nops;
        cycles(300);
        for (i = mark; i < nops; i = i + 1)
            if (!log_ovr[i] || (log_addr[i] !== 16'hC000 && log_addr[i] !== 16'hC010))
                fail("held: something other than a keyboard read while held");

        // --- case 13 / a RES' while runtime-held: the boot hold takes over --
        arm = 1'b1;
        machine_reset(4);
        cycles(12);
        if (held !== 1'b1) fail("reset: not held after the reset");
        else if (runtime !== 1'b0) fail("reset: held, but runtime is still set - the boot hold should own this");
        else if (log_ovr[7] !== 1'b1 || log_addr[6] !== 16'hFFFD) fail("reset: not held at the vector fetch");
        else $display("  ok: a RES' while runtime-held drops it, and the boot hold engages at the vector");
        // A knock while the boot menu is showing is nothing.
        pulse_trigger;
        cycles(10);
        if (runtime !== 1'b0 || held !== 1'b1) fail("reset: a knock during the boot hold changed it");
        else $display("  ok: a knock while the boot menu is showing is nothing");
        pulse_release;
        cycles(30);
        if (held !== 1'b0) fail("reset: the boot hold did not release");
        arm = 1'b0;

        // --- case 14 / the disk's override comes first ----------------------
        // Held at runtime, the disk moves bytes: its ops go out, the hold's
        // wait, the core stays put, and a release asked for during the
        // transfer lands on the hold's own read after it.
        pulse_trigger;
        cycles(12);
        if (held !== 1'b1 || runtime !== 1'b1) fail("disk: not runtime-held");
        held_at = cpu_addr;
        steps_before = core_steps;
        mark = nops;
        at_offset(0);
        hd_ovr_en = 1'b1;
        cycles(4);
        pulse_release;                          // arrives mid-transfer
        cycles(4);
        at_offset(0);
        hd_ovr_en = 1'b0;
        cycles(30);
        hd_seen = 0;
        for (i = mark; i < nops; i = i + 1)
            if (log_ovr[i] && log_addr[i] == 16'h0200) hd_seen = hd_seen + 1;
        if (hd_seen < 6) begin
            $display("FAIL: disk: %0d of the disk's ops went out over the hold", hd_seen); errors = errors + 1;
        end else $display("  ok: the disk's %0d override cycles went out with the machine held", hd_seen);
        idx = first_sync(mark);
        if (idx < 0) fail("disk: never released");
        else if (log_addr[idx] !== held_at) fail("disk: resumed somewhere else");
        else begin
            // The release waited for the disk: the fetch is preceded by a
            // read of the HOLD's, after the last disk op.
            j = -1;
            for (i = mark; i < idx; i = i + 1) if (log_addr[i] == 16'h0200) j = i;
            if (log_addr[idx-1] !== 16'hC000 || idx - 1 <= j)
                fail("disk: the release did not wait for a read of the hold's own after the transfer");
            else $display("  ok: the release landed on the hold's own read, after the transfer, and the program resumed");
        end
        for (i = mark; i < idx; i = i + 1) if (log_sync[i]) fail("disk: the core moved during the transfer");

        // A runtime hold asked for while the disk is moving waits for it.
        mark = nops;
        at_offset(0);
        hd_ovr_en = 1'b1;
        cycles(3);
        pulse_trigger;
        cycles(6);
        if (held !== 1'b0) fail("disk: the hold engaged over the disk's transfer");
        at_offset(0);
        hd_ovr_en = 1'b0;
        cycles(12);
        if (held !== 1'b1 || runtime !== 1'b1) fail("disk: the hold did not engage once the disk was done");
        else begin
            ovr_at = -1;
            for (i = mark; i < nops; i = i + 1)
                if (ovr_at < 0 && log_ovr[i] && log_addr[i] == 16'hC000) ovr_at = i;
            j = -1;
            for (i = mark; i < nops; i = i + 1) if (log_addr[i] == 16'h0200) j = i;
            if (ovr_at < j) fail("disk: the hold's first read came before the disk's last op");
            else $display("  ok: a knock during a transfer waits: the hold's first read follows the disk's last op");
        end
        pulse_release;
        cycles(20);
        if (held !== 1'b0) fail("disk: not released at the end");

        if (bad_ovr != 0) fail("an override op was presented as a write or a SYNC");
        else $display("  ok: every override op was a read and never a SYNC");

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
