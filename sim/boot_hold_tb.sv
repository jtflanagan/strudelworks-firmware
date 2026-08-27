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
    wire        ovr_en;
    wire [15:0] ovr_addr;

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
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (1'b1), .ovr_wdata (8'h00), .op_ovr (op_ovr),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- the hold ---------------------------------------------------------
    reg  arm = 1'b0;
    reg  release_req = 1'b0;
    wire held;

    boot_hold dut (
        .clk (clk), .cpu_rst (cpu_rst),
        .master_active (master_active),
        .arm (arm), .release_req (release_req),
        .cpu_sync (cpu_sync),
        .op_present (op_present), .op_commit (op_commit),
        .op_sync (drv_sync), .op_ovr (op_ovr), .din (cpu_din),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr),
        .held (held)
    );

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

        if (bad_ovr != 0) fail("an override op was presented as a write or a SYNC");
        else $display("  ok: every override op was a read and never a SYNC");

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
