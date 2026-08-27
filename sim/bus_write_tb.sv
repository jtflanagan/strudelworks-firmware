`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// bus_write_tb - apple_bus_write against a phi0 that looks like an Apple's.
//
// The checks here are chosen from the ways this is known to go wrong, not from
// the module's structure.  Two of them are aty's bugs, written down as
// assertions so we cannot repeat them:
//
//   * the presented address changes EXACTLY ONCE per bus cycle, at T_PRESENT.
//     A flip anywhere else is the doubled-$C0xx-write failure - the address
//     moving at a point unanchored to the cycle that samples it.
//   * it is stable well before the reader's own snap tap.  We snoop the bus we
//     drive, so a late present is snooped back as the previous value: aty's
//     $C007 write that was seen as the parked $0000, so the soft switch never
//     flipped and the machine booted to BASIC.
//
// The rest are the contract: nothing driven unless mastering, data driven only
// on writes and only inside the emit window, and one cyc_en per phi0 cycle.
//////////////////////////////////////////////////////////////////////////////////

module bus_write_tb;

    // Matches apple_bus_read's taps: index N pulses N+1 cycles after the edge.
    localparam integer READER_ADDR_TAP = 19;

    localparam integer T_PRESENT = 2;
    localparam integer T_EMIT    = 2;
    localparam integer T_DIN     = 44;
    localparam integer T_CYCEN   = 45;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;               // 100 MHz

    integer errors = 0;
    task fail(input [8*80-1:0] why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask

    // ---- a phi0 that looks like the machine's -------------------------------
    // 98 fabric cycles, ~1.0204 MHz.  Low first, so the first edge the DUT sees
    // is a rise, exactly as it would be joining a running bus at an arbitrary
    // moment.
    localparam integer PHI0_LOW  = 49;
    localparam integer PHI0_HIGH = 49;
    reg phi0 = 0;
    integer phase_ctr = 0;
    always @(posedge clk) begin
        phase_ctr <= phase_ctr + 1;
        if (!phi0 && phase_ctr == PHI0_LOW - 1)  begin phi0 <= 1; phase_ctr <= 0; end
        if ( phi0 && phase_ctr == PHI0_HIGH - 1) begin phi0 <= 0; phase_ctr <= 0; end
    end

    // ---- a stand-in for the core --------------------------------------------
    // Its outputs move the instant cyc_en fires, which is the whole hazard: a
    // driver that followed them live would flip mid-cycle.
    reg  [15:0] cpu_addr = 16'h1234;
    reg         cpu_rw   = 1'b1;
    reg  [7:0]  cpu_dout = 8'h00;
    wire        cyc_en;
    always @(posedge clk) if (cyc_en) begin
        cpu_sync <= ~cpu_sync;
        cpu_addr <= cpu_addr + 16'd1;
        cpu_rw   <= ~cpu_rw;                       // alternate read/write
        cpu_dout <= cpu_dout + 8'd17;
    end

    // A stand-in for the core's SYNC: high on the first cycle of each of its
    // "instructions", so the tb can check it is held across the bus cycle.
    reg        cpu_sync = 1'b1;
    wire       drv_sync;
    reg  [7:0] data_sync = 8'hA5;
    reg        master_active = 1'b0;

    wire [15:0] addr_drive;
    wire        rw_drive;
    wire [7:0]  data_drive;
    wire        addr_rw_oe, data_oe, dma_assert, driving;
    wire [7:0]  cpu_din;

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) dut (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0), .data_sync (data_sync),
        .master_active (master_active),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .drv_sync (drv_sync),
        .cyc_en (cyc_en), .cpu_din (cpu_din),
        // No peripheral in this tb: the claim is tied low, which is also the
        // proof that an idle claim changes nothing the checks below assert.
        .op_addr (), .op_rw (), .op_wdata (), .op_present (), .op_commit (),
        .slot_rd_claim (1'b0), .slot_rd_data (8'h00),
        .din_sub_en (1'b0), .din_sub_data (8'h00),
        // No boot hold either: the override is idle, which is what every
        // cycle looks like once a machine has booted.
        .ovr_en (1'b0), .ovr_addr (16'h0000), .ovr_rw (1'b1), .ovr_wdata (8'h00), .op_ovr (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- observers ----------------------------------------------------------
    reg         prev_phi0 = 0;
    wire        fall = !phi0 &&  prev_phi0;
    integer     since_fall = 0;         // fabric cycles since the last falling edge
    always @(posedge clk) begin
        prev_phi0 <= phi0;
        if (fall) since_fall <= 0;
        else      since_fall <= since_fall + 1;
    end

    reg [15:0] last_addr = 16'hFFFF;
    integer    changes_this_cycle = 0;
    integer    change_at = -1;
    integer    cycles_seen = 0;
    integer    cycen_this_cycle = 0;
    integer    first_change_at = -1;
    integer    worst_change_at = -1;
    integer    bad_change = 0;
    integer    bad_cycen = 0;
    integer    data_oe_on_read = 0;
    integer    data_oe_mid_addr = 0;
    integer    data_oe_in_window = 0;
    integer    write_cycles_sampled = 0;
    integer    early_sampled = 0;
    reg        last_sync = 1'bx;
    integer    sync_changes = 0;
    integer    sync_change_at = -1;
    integer    bad_sync = 0;
    integer    early_driven = 0;

    always @(posedge clk) if (!rst && master_active) begin
        // Count address changes within a bus cycle, and where they happened.
        if (addr_drive !== last_addr) begin
            changes_this_cycle = changes_this_cycle + 1;
            change_at = since_fall;
            // Not the first bus cycle: taking the bus mid-cycle moves the
            // address off its parked value at whatever moment that happened,
            // which is the takeover and not the steady state under test.
            if (cycles_seen > 1) begin
                if (since_fall > worst_change_at) worst_change_at = since_fall;
                if (first_change_at < 0 || since_fall < first_change_at)
                    first_change_at = since_fall;
            end
            last_addr = addr_drive;
        end
        if (cyc_en) cycen_this_cycle = cycen_this_cycle + 1;
        if (drv_sync !== last_sync) begin
            sync_changes = sync_changes + 1;
            if (cycles_seen > 1) sync_change_at = since_fall;
            last_sync = drv_sync;
        end

        // The data bus is ours only on a write, only inside the window.  Two
        // sample points rather than a range: one deep in the address phase,
        // where it must be RELEASED, and one deep in the emit window, where on
        // a write it must be DRIVEN.  (It is deliberately still driven for a
        // few cycles after the falling edge - that is the hold time, not a
        // leak, and asserting otherwise would be testing a promise the
        // contract does not make.)
        if (data_oe && rw_drive) data_oe_on_read = data_oe_on_read + 1;
        if (since_fall == 30 && data_oe) data_oe_mid_addr = data_oe_mid_addr + 1;
        // And the window must OPEN early in the CPU's own half, not late in it:
        // rise is at cycle 49, so this is 6 cycles into phi0-high.
        if (since_fall == 55 && !rw_drive) begin
            early_sampled = early_sampled + 1;
            if (data_oe) early_driven = early_driven + 1;
        end
        if (since_fall == 80 && !rw_drive) begin
            write_cycles_sampled = write_cycles_sampled + 1;
            if (data_oe) data_oe_in_window = data_oe_in_window + 1;
        end

        if (fall) begin
            // Judge the cycle that just ended.
            if (cycles_seen > 1) begin
                if (sync_changes > 1) bad_sync = bad_sync + 1;
                if (changes_this_cycle > 1) bad_change = bad_change + 1;
                if (cycen_this_cycle != 1)  bad_cycen  = bad_cycen + 1;
            end
            cycles_seen = cycles_seen + 1;
            changes_this_cycle = 0;
            cycen_this_cycle = 0;
            sync_changes = 0;
        end
    end

    integer i;
    initial begin
        $display("bus_write_tb: driving the Apple bus");
        $display("");
        repeat (8) @(posedge clk);
        rst = 0;
        repeat (300) @(posedge clk);

        // --- case 1 / nothing is driven while the native CPU has the bus -----
        if (addr_rw_oe !== 1'b0 || data_oe !== 1'b0 || dma_assert !== 1'b0)
            fail("something was driven with master_active low");
        else
            $display("  ok: not mastering - address, data and DMA' all released");

        // --- take the bus ---------------------------------------------------
        @(negedge clk); master_active = 1'b1;
        repeat (30 * 98) @(posedge clk);      // ~30 bus cycles

        // --- case 2 / DMA' and the address bus are held, not pulsed ----------
        if (dma_assert !== 1'b1)  fail("DMA' released while mastering");
        else $display("  ok: DMA' is a level, held for the whole session");
        if (addr_rw_oe !== 1'b1)  fail("the address bus was released mid-session");
        else $display("  ok: address and R/W driven continuously, never released");

        // --- case 3 / one stable address per bus cycle -----------------------
        if (bad_change != 0)
            fail("the presented address changed more than once inside a bus cycle");
        else
            $display("  ok: exactly one address change per cycle, over %0d cycles",
                     cycles_seen);

        // --- case 4 / at the SAME point every cycle, early enough to snoop ---
        // The property is anchoring, not a particular index: every change must
        // land at one fixed offset from the falling edge, and that offset must
        // leave the driven address time to get out to the pin and back through
        // the reader's synchroniser before the reader samples it.
        if (worst_change_at < 0)
            fail("the address never changed at all - the core is not being read");
        else if (first_change_at != worst_change_at)
            fail("the address moved at different points in different cycles - unanchored");
        else if (worst_change_at + 4 >= READER_ADDR_TAP + 1)
            fail("the present is too late to be snooped back reliably");
        else
            $display("  ok: every change at cycle %0d after phi0 falling; reader samples at %0d, so %0d cycles of round-trip margin",
                     worst_change_at, READER_ADDR_TAP + 1,
                     READER_ADDR_TAP + 1 - worst_change_at);

        // --- case 4b / the reconstructed SYNC is held like the address -------
        // It is recorded in the trace at the reader's address tap, so it has to
        // be as stable across the cycle as everything else the trace records.
        if (bad_sync != 0)
            fail("the driven SYNC moved more than once inside a bus cycle");
        else if (sync_change_at != worst_change_at)
            fail("the driven SYNC does not move with the address");
        else
            $display("  ok: driven SYNC latched with the op, one value per cycle");

        // --- case 5 / one cyc_en per bus cycle -------------------------------
        if (bad_cycen != 0)
            fail("a bus cycle carried something other than exactly one cyc_en");
        else
            $display("  ok: exactly one cyc_en per phi0 cycle - the core is locked to the bus");

        // --- case 6 / the data bus, only on writes and only in the window ----
        if (data_oe_on_read != 0)
            fail("the data bus was driven during a READ - the machine drives that");
        else
            $display("  ok: data driven only on writes");
        if (data_oe_mid_addr != 0)
            fail("the data bus was still driven through the address phase");
        else
            $display("  ok: data released for the address phase");
        if (early_sampled == 0)
            fail("no early sample point hit");
        else if (early_driven != early_sampled)
            fail("data was not yet driven early in the CPU's half of the cycle");
        else
            $display("  ok: data up from early in phi0-high on all %0d write cycles",
                     early_sampled);
        if (write_cycles_sampled == 0)
            fail("no write cycles were sampled - the stimulus is not exercising writes");
        else if (data_oe_in_window != write_cycles_sampled)
            fail("a write cycle did not drive data inside the emit window");
        else
            $display("  ok: data driven inside the emit window on all %0d write cycles sampled",
                     write_cycles_sampled);

        // --- case 7 / din is what was on the bus -----------------------------
        data_sync = 8'h5C;
        repeat (3 * 98) @(posedge clk);
        if (cpu_din !== 8'h5C)
            fail("din did not follow the bus");
        else
            $display("  ok: din is latched from the bus and stable at cyc_en");

        // --- case 8 / giving the bus back is immediate and total -------------
        @(negedge clk); master_active = 1'b0;
        repeat (2 * 98) @(posedge clk);
        if (addr_rw_oe !== 1'b0 || data_oe !== 1'b0 || dma_assert !== 1'b0)
            fail("still driving after master_active dropped");
        else
            $display("  ok: releasing master_active releases every pin at once");
        if (driving !== 1'b0)
            fail("still claims to be driving");
        else
            $display("  ok: and stops claiming to drive");

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
