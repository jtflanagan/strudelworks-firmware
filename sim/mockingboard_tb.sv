`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mockingboard_tb - the Mockingboard behind the real driver, on an Apple-shaped
// phi0.
//
// This drives apple_bus_write and mockingboard TOGETHER, because the seam
// between them is where the design can be wrong in ways neither module can see
// alone: the claim has to be registered before the emit window opens, the VIA
// strobe has to land after the byte has been sampled, and the byte the CPU
// reads back has to be the one that went out the pins - the tb models that
// round trip the way the board wires it, data_sync following the driven bus.
//
// The checks are the ways a Mockingboard is known to be probed and used:
//
//   * software FINDS the card by reading a VIA register back ($Cn00-$CnFF),
//     and by watching T1 count down - so reads must return VIA state, and the
//     timers must count phi0 cycles
//   * every music player lives on the T1 interrupt, so IER/T1 must raise IRQ
//     at the programmed period and reading T1C-L must clear it
//   * the IIe boots with INTCXROM set; a card that answered $C4xx then would
//     fight the motherboard ROM.  The soft-switch gate is load-bearing.
//////////////////////////////////////////////////////////////////////////////////

module mockingboard_tb;

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
    localparam integer PHI0_LOW  = 49;
    localparam integer PHI0_HIGH = 49;
    reg phi0 = 0;
    integer phase_ctr = 0;
    always @(posedge clk) begin
        phase_ctr <= phase_ctr + 1;
        if (!phi0 && phase_ctr == PHI0_LOW - 1)  begin phi0 <= 1; phase_ctr <= 0; end
        if ( phi0 && phase_ctr == PHI0_HIGH - 1) begin phi0 <= 0; phase_ctr <= 0; end
    end

    // ---- the scripted CPU ---------------------------------------------------
    // One op at a time: bus_op() presents it and returns when the driver has
    // finished the bus cycle that carried it (cyc_en), exactly the lockstep
    // the real core runs in.
    reg  [15:0] cpu_addr = 16'h0000;
    reg         cpu_rw   = 1'b1;
    reg  [7:0]  cpu_dout = 8'h00;
    wire        cyc_en;
    wire [7:0]  cpu_din;

    task bus_op(input [15:0] addr, input rw, input [7:0] dout);
        begin
            cpu_addr = addr; cpu_rw = rw; cpu_dout = dout;
            @(posedge cyc_en);
            @(posedge clk);
        end
    endtask

    task bus_write(input [15:0] addr, input [7:0] data);
        bus_op(addr, 1'b0, data);
    endtask

    // A read whose result is checked by the caller via cpu_din.
    task bus_read(input [15:0] addr);
        bus_op(addr, 1'b1, 8'h00);
    endtask

    // ---- DUTs, and the board's own wiring between them ----------------------
    reg         master_active = 1'b0;
    reg         res_sync = 1'b1;        // active low, idle high
    reg  [2:0]  slot_assign = 3'd0;
    reg         phasor = 1'b0;

    wire [15:0] op_addr;
    wire        op_rw;
    wire [7:0]  op_wdata;
    wire        op_present, op_commit;
    wire        rd_claim;
    wire [7:0]  rd_data;
    wire        mb_irq;

    wire [15:0] addr_drive;
    wire        rw_drive;
    wire [7:0]  data_drive;
    wire        addr_rw_oe, data_oe, dma_assert, drv_sync, driving;

    // The round trip: what the FPGA drives is what the reader's synchroniser
    // hands back, and when nothing drives, the floating bus shows garbage.
    // 8'hEE rather than 0 so "read the float" cannot pass a zero-check by luck.
    wire [7:0] data_sync = data_oe ? data_drive : 8'hEE;

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) u_write (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0), .data_sync (data_sync),
        .master_active (master_active), .park_kbd (1'b0),
        // Without the sequencer: the bus owns every cycle, the core is always on offer.
        .bus_owns (1'b1), .core_valid (1'b1),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (1'b0), .drv_sync (drv_sync),
        .cyc_en (cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (rd_claim), .slot_rd_data (rd_data),
        .din_sub_en (1'b0), .din_sub_data (8'h00),
        .ovr_en (1'b0), .ovr_addr (16'h0000), .ovr_rw (1'b1), .ovr_wdata (8'h00), .op_ovr (), .nxt_addr (), .divert (1'b0), .op_divert (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // The speech chips' sample clock shortened to one sample per bus cycle
    // (sim/ssi263_tb.sv has the real rate): phoneme $28 (880 samples) at
    // DUR 3 completes in 220 cycles here, 10176 on the machine.
    mockingboard #(.SSI_TICK_NUM (1), .SSI_TICK_DEN (1)) u_mb (
        .clk (clk), .rst (rst),
        .res_sync (res_sync),
        .master_active (master_active),
        .slot_assign (slot_assign), .phasor (phasor),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        // Without the sequencer: every cycle carries an op, no fast ops.
        .op_dummy (1'b0), .fast_tick (1'b0),
        .rd_claim (rd_claim), .rd_data (rd_data),
        .irq (mb_irq)
    );

    // ---- observers ----------------------------------------------------------
    // The invariant that keeps the machine alive: the data bus is driven on a
    // read ONLY when the Mockingboard claimed that read.  A single violation
    // anywhere in the run is bus contention on hardware.
    integer read_drive_unclaimed = 0;
    always @(posedge clk) if (!rst) begin
        if (data_oe && rw_drive && !rd_claim)
            read_drive_unclaimed = read_drive_unclaimed + 1;
    end

    // Count bus cycles, for the T1 period check.
    integer bus_cycles = 0;
    always @(posedge clk) if (cyc_en) bus_cycles = bus_cycles + 1;

    // VIA register offsets, as the 6502 sees them in slot 4.
    localparam [15:0] VIA0 = 16'hC400;
    localparam [15:0] VIA1 = 16'hC480;
    localparam [15:0] ORB  = 16'h0000;
    localparam [15:0] ORA  = 16'h0001;
    localparam [15:0] DDRB = 16'h0002;
    localparam [15:0] DDRA = 16'h0003;
    localparam [15:0] T1CL = 16'h0004;
    localparam [15:0] T1CH = 16'h0005;
    localparam [15:0] IFR  = 16'h000D;
    localparam [15:0] IER  = 16'h000E;

    integer irq_at = -1;
    integer t1_start = 0;

    initial begin
        $display("mockingboard_tb: two VIAs answering for slot 4\n");
        repeat (8) @(posedge clk);
        rst = 0;

        // Take the bus with the card disabled, and park a while.
        @(negedge clk); master_active = 1'b1;
        repeat (3) @(posedge cyc_en);

        // --- case 1 / disabled means invisible -------------------------------
        bus_read(VIA0 | ORA);
        if (cpu_din !== 8'hEE)
            fail("a disabled Mockingboard answered a read");
        else
            $display("  ok: slot 0 - $C401 reads the floating bus");

        // --- enable, slot 4 --------------------------------------------------
        // On hardware this latches through wb_regfile at a RES' assertion;
        // here the latch is upstream of the module under test, so set it
        // directly and reset the machine around it as the real flow would.
        res_sync = 1'b0;
        slot_assign = 3'd4;
        repeat (200) @(posedge clk);
        res_sync = 1'b1;
        repeat (2) @(posedge cyc_en);

        // --- case 2 / write a VIA register, read it back ---------------------
        bus_write(VIA0 | DDRA, 8'hFF);
        bus_write(VIA0 | ORA,  8'h5A);
        bus_read (VIA0 | DDRA);
        if (cpu_din !== 8'hFF) fail("DDRA did not read back");
        else                   $display("  ok: VIA 0 DDRA written and read back");
        bus_read (VIA0 | ORA);
        if (cpu_din !== 8'h5A) fail("ORA did not read back");
        else                   $display("  ok: VIA 0 ORA carries the AY data byte");

        // --- case 3 / the second VIA is its own chip -------------------------
        bus_write(VIA1 | DDRB, 8'h07);
        bus_read (VIA1 | DDRB);
        if (cpu_din !== 8'h07) fail("VIA 1 DDRB did not read back");
        else                   $display("  ok: VIA 1 at $C480 is separate state");
        bus_read (VIA0 | DDRB);
        if (cpu_din !== 8'h00) fail("VIA 0 DDRB changed when VIA 1 was written");
        else                   $display("  ok: and writing it left VIA 0 alone");

        // --- case 4 / INTCXROM takes the page away ---------------------------
        // A write to $C007 maps $C1-$CF to motherboard ROM; the card must go
        // silent or it is driving against that ROM's own output buffer.
        bus_write(16'hC007, 8'h00);
        bus_read (VIA0 | ORA);
        if (cpu_din !== 8'hEE)
            fail("the card answered $C4xx with INTCXROM set");
        else
            $display("  ok: INTCXROM set - $C4xx is the ROM's, card silent");
        bus_write(16'hC006, 8'h00);
        bus_read (VIA0 | ORA);
        if (cpu_din !== 8'h5A)
            fail("the card did not come back when INTCXROM cleared");
        else
            $display("  ok: INTCXROM clear - the card answers again");

        // --- case 5 / only its own page --------------------------------------
        bus_read(16'hC500);
        if (cpu_din !== 8'hEE) fail("slot 4 card answered a slot 5 address");
        else                   $display("  ok: $C5xx is somebody else's slot");

        // --- case 6 / T1 counts phi0 cycles and interrupts -------------------
        // The music-player idiom: enable the T1 interrupt, load the period,
        // and the IRQ must arrive one period later - counted in BUS cycles,
        // because that is the clock the player's arithmetic assumes.
        bus_write(VIA0 | IER,  8'hC0);      // set: enable T1
        bus_write(VIA0 | T1CL, 8'd100);     // latch lo
        t1_start = bus_cycles;
        bus_write(VIA0 | T1CH, 8'd0);       // load: 100, and the count begins
        irq_at = -1;
        while (irq_at < 0 && (bus_cycles - t1_start) < 200) begin
            bus_read(16'h1234);             // the player is off doing work
            if (mb_irq) irq_at = bus_cycles - t1_start;
        end
        if (irq_at < 0)
            fail("T1 never interrupted");
        else if (irq_at < 100 || irq_at > 110)
            fail("T1 period is not counting bus cycles");
        else
            $display("  ok: T1=100 raised IRQ after %0d bus cycles", irq_at);

        // Reading T1C-L is how the handler acknowledges.
        bus_read(VIA0 | T1CL);
        bus_read(16'h1234);
        bus_read(16'h1234);
        if (mb_irq !== 1'b0)
            fail("reading T1C-L did not clear the interrupt");
        else
            $display("  ok: reading T1C-L clears it");

        // And IFR said why, while it was pending: start another one-shot -
        // ACR is 0, so T1 does not free-run and has to be rearmed by writing
        // T1C-H, exactly as a player's IRQ handler does - and read IFR inside
        // the window.
        bus_write(VIA0 | T1CH, 8'd0);
        t1_start = bus_cycles;
        while (!mb_irq && (bus_cycles - t1_start) < 200) bus_read(16'h1234);
        bus_read(VIA0 | IFR);
        if (cpu_din[7] !== 1'b1 || cpu_din[6] !== 1'b1)
            fail("IFR does not show the T1 interrupt");
        else
            $display("  ok: IFR reads %02x - IRQ up, T1 the cause", cpu_din);
        bus_read(VIA0 | T1CL);              // tidy: acknowledge

        // --- case 7 / the machine's reset resets the card --------------------
        res_sync = 1'b0;
        repeat (300) @(posedge clk);
        res_sync = 1'b1;
        repeat (2) @(posedge cyc_en);
        bus_read(VIA0 | DDRA);
        if (cpu_din !== 8'h00) fail("RES' did not clear the VIA");
        else                   $display("  ok: RES' clears the VIAs, as the slot pin would");
        if (mb_irq !== 1'b0)   fail("IRQ survived a reset");
        else                   $display("  ok: and no interrupt survives it");

        // --- case 7a / T1's flag is visible N+2 cycles after the T1C-H write -
        // mb-audit test 6522:F, cycle for cycle: write T1C-H at cycle W, and a
        // read of IFR on cycle W+N+2 sees the flag, on cycle W+N+1 not yet.
        // Each bus_op here is one bus cycle.
        bus_write(VIA0 | IER,  8'h7F);      // clear: no interrupt lines, IFR still shows T1
        bus_write(VIA0 | T1CL, 8'h0F);
        bus_write(VIA0 | T1CH, 8'h00);      // W: T1 = $000F
        repeat (15) bus_read(16'h1234);     // W+1 .. W+15
        bus_read(VIA0 | IFR);               // W+16 = W+N+1
        if (cpu_din[6] !== 1'b0) fail("T1 flag visible a cycle early (W+N+1)");
        else                     $display("  ok: T1=$0F - IFR clear on cycle W+N+1");
        bus_write(VIA0 | T1CL, 8'h0F);
        bus_write(VIA0 | T1CH, 8'h00);      // W (also clears the flag)
        repeat (16) bus_read(16'h1234);     // W+1 .. W+16
        bus_read(VIA0 | IFR);               // W+17 = W+N+2
        if (cpu_din[6] !== 1'b1) fail("T1 flag not visible on cycle W+N+2");
        else                     $display("  ok: T1=$0F - IFR shows T1 on cycle W+N+2 (the datasheet's N+2)");
        bus_read(VIA0 | T1CL);              // acknowledge

        // --- case 7a' / an IFR clear on the underflow's own cycle loses -------
        // mb-audit test 6522:14 subtest 2: T2 loaded so that its $0000 ->
        // $FFFF tick is the cycle of a write clearing IFR's T2 bit; the flag
        // must survive (the set wins).  A cycle later the clear wins.
        bus_write(VIA0 | 16'h0008, 8'h0F);  // T2C-L
        bus_write(VIA0 | 16'h0009, 8'h00);  // W: T2 = $000F
        repeat (15) bus_read(16'h1234);     // W+1 .. W+15: T2 reaches 0 at the end of W+15
        bus_write(VIA0 | IFR, 8'h20);       // W+16: the tick takes T2 to $FFFF AND the clear lands
        bus_read (VIA0 | IFR);
        if (cpu_din[5] !== 1'b1) fail("an IFR clear on the underflow cycle lost the T2 flag");
        else                     $display("  ok: IFR clear on T2's underflow cycle - the set wins");
        bus_write(VIA0 | IFR, 8'h20);       // and an ordinary clear clears
        bus_read (VIA0 | IFR);
        if (cpu_din[5] !== 1'b0) fail("IFR clear of T2 did not clear");
        else                     $display("  ok: a clear a cycle later clears it");

        // --- case 7b / the AY registers read back through port A ------------
        // mb-audit's chip detection: DDRA out, LATCH a register, WRITE it;
        // DDRA in, READ - the value comes back on port A.  An undriven port A
        // reads high.  Register widths hold.
        bus_write(VIA0 | DDRB, 8'h07);
        bus_write(VIA0 | DDRA, 8'hFF);
        bus_write(VIA0 | ORB,  8'h04);      // inactive, RESET' high
        bus_write(VIA0 | ORA,  8'h00);      // AFINE
        bus_write(VIA0 | ORB,  8'h07);      // latch
        bus_write(VIA0 | ORB,  8'h04);
        bus_write(VIA0 | ORA,  8'hAA);
        bus_write(VIA0 | ORB,  8'h06);      // write
        bus_write(VIA0 | ORB,  8'h04);
        bus_write(VIA0 | DDRA, 8'h00);      // port A in
        bus_write(VIA0 | ORB,  8'h05);      // read
        bus_read (VIA0 | ORA);
        if (cpu_din !== 8'hAA) fail("AY AFINE did not read back through port A");
        else                   $display("  ok: AY register $AA reads back on port A during PSG READ");
        bus_write(VIA0 | ORB,  8'h04);
        bus_read (VIA0 | ORA);
        if (cpu_din !== 8'hFF) fail("an undriven port A did not read high");
        else                   $display("  ok: inactive - port A floats high ($FF)");
        bus_write(VIA0 | DDRA, 8'hFF);      // reg 1 (ACOARSE, 4 bits) = $1F -> $0F
        bus_write(VIA0 | ORA,  8'h01);
        bus_write(VIA0 | ORB,  8'h07);
        bus_write(VIA0 | ORB,  8'h04);
        bus_write(VIA0 | ORA,  8'h1F);
        bus_write(VIA0 | ORB,  8'h06);
        bus_write(VIA0 | ORB,  8'h04);
        bus_write(VIA0 | DDRA, 8'h00);
        bus_write(VIA0 | ORB,  8'h05);
        bus_read (VIA0 | ORA);
        if (cpu_din !== 8'h0F) fail("a 4-bit AY register did not mask");
        else                   $display("  ok: a 4-bit register reads back masked ($1F -> $0F, so not a YM2149)");
        bus_write(VIA0 | ORB,  8'h04);
        bus_write(VIA0 | DDRA, 8'hFF);
        bus_write(VIA0 | ORA,  8'h0E);      // PORTA: absent on an 8913
        bus_write(VIA0 | ORB,  8'h07);
        bus_write(VIA0 | ORB,  8'h04);
        bus_write(VIA0 | ORA,  8'h55);
        bus_write(VIA0 | ORB,  8'h06);
        bus_write(VIA0 | ORB,  8'h04);
        bus_write(VIA0 | DDRA, 8'h00);
        bus_write(VIA0 | ORB,  8'h05);
        bus_read (VIA0 | ORA);
        if (cpu_din === 8'h55) fail("an 8913 answered the I/O port register");
        else                   $display("  ok: register 14 does not hold $55 (an 8913, not an 8910)");
        bus_write(VIA0 | ORB,  8'h00);      // RESET' low: the shadow clears
        bus_write(VIA0 | ORB,  8'h04);
        bus_write(VIA0 | ORB,  8'h05);      // read with nothing latched: undriven
        bus_read (VIA0 | ORA);
        if (cpu_din !== 8'hFF) fail("a reset AY still drove port A");
        else                   $display("  ok: RESET' clears the chip; a read with no latch floats");
        bus_write(VIA0 | ORB,  8'h04);

        // --- case 8 / a Mockingboard has no mode register --------------------
        // The Phasor's DEVICE SELECT' range does nothing to a Mockingboard:
        // not claimed, and the VIA decode stays A7's.
        bus_read(16'hC0C5);
        if (cpu_din !== 8'hEE) fail("a Mockingboard answered $C0C5");
        else                   $display("  ok: $C0C5 floats past a Mockingboard");
        bus_write(VIA0 | DDRA, 8'h5A);
        bus_read (16'hC413);                // A4 set: still VIA 0 to a Mockingboard
        if (cpu_din !== 8'h5A) fail("A4 changed a Mockingboard's decode");
        else                   $display("  ok: and A4 is undecoded, $C413 is VIA 0");

        // --- become a Phasor: latched with the slot, around a reset ---------
        $display("\nas a Phasor in slot 4\n");
        res_sync = 1'b0;
        phasor = 1'b1;
        repeat (200) @(posedge clk);
        res_sync = 1'b1;
        repeat (2) @(posedge cyc_en);

        // --- case 9 / a Phasor wakes up as a Mockingboard --------------------
        bus_write(VIA0 | DDRA, 8'h0F);
        bus_write(VIA1 | DDRA, 8'hF0);
        bus_read (16'hC413);
        if (cpu_din !== 8'h0F) fail("Phasor in Mockingboard mode: $C413 is not VIA 0");
        else                   $display("  ok: mode 0 after RES' - $C413 reads VIA 0");
        bus_read (VIA1 | DDRA);
        if (cpu_din !== 8'hF0) fail("Phasor in Mockingboard mode: $C483 is not VIA 1");
        else                   $display("  ok: and $C483 reads VIA 1");

        // --- case 10 / $C0C5 selects Phasor mode -----------------------------
        // The access itself is not claimed (nothing on a Phasor drives the
        // bus at DEVICE SELECT'), and afterwards A4/A7 select the VIAs.
        bus_read(16'hC0C5);
        if (cpu_din !== 8'hEE) fail("the mode access was claimed");
        else                   $display("  ok: $C0C5 itself floats");
        bus_read(VIA0 | DDRA);              // $C403: neither VIA in native mode
        if (cpu_din !== 8'hEE) fail("native mode: $C403 selected a VIA");
        else                   $display("  ok: native mode - $C403 selects no VIA, floats");
        bus_read(16'hC413);
        if (cpu_din !== 8'h0F) fail("native mode: A4 did not select VIA 0");
        else                   $display("  ok: A4 selects VIA 0");
        bus_read(16'hC483);
        if (cpu_din !== 8'hF0) fail("native mode: A7 did not select VIA 1");
        else                   $display("  ok: A7 selects VIA 1");
        bus_read(16'hC493);
        if (cpu_din !== 8'hFF) fail("native mode: a read of both is not their OR");
        else                   $display("  ok: A4+A7 reads the OR of both, $FF");
        bus_write(16'hC493, 8'h33);         // lands in BOTH
        bus_read (16'hC413);
        if (cpu_din !== 8'h33) fail("native mode: a write to both missed VIA 0");
        else                   $display("  ok: a write to A4+A7 lands in VIA 0");
        bus_read (16'hC483);
        if (cpu_din !== 8'h33) fail("native mode: a write to both missed VIA 1");
        else                   $display("  ok: ...and in VIA 1");
        bus_read (16'hC443);                // the speech chip's offset: no VIA, the chip's D7
        if (cpu_din !== 8'h00) fail("native mode: $C443 (SSI-263) selected a VIA");
        else                   $display("  ok: the SSI-263's $C44x selects no VIA - the chip's D7, clear");

        // --- case 10a / the second AY reads back in native mode --------------
        // VIA 0 at $C41x, DDRB $1F; PB4/PB3 select: the second AY alone is
        // $10|func.  Its AFINE is its own; the first's is untouched.
        bus_write(16'hC412, 8'h1F);         // DDRB
        bus_write(16'hC413, 8'hFF);         // DDRA out
        bus_write(16'hC410, 8'h1C);         // inactive, neither selected, RESET' high
        bus_write(16'hC411, 8'h00);         // AFINE
        bus_write(16'hC410, 8'h17);         // latch, second AY
        bus_write(16'hC410, 8'h1C);
        bus_write(16'hC411, 8'h69);
        bus_write(16'hC410, 8'h16);         // write, second AY
        bus_write(16'hC410, 8'h1C);
        bus_write(16'hC413, 8'h00);         // DDRA in
        bus_write(16'hC410, 8'h15);         // read, second AY
        bus_read (16'hC411);
        if (cpu_din !== 8'h69) fail("the second AY did not read back");
        else                   $display("  ok: native mode - the second AY's register reads back ($69)");
        bus_write(16'hC410, 8'h1C);
        bus_write(16'hC413, 8'hFF);
        bus_write(16'hC411, 8'h00);
        bus_write(16'hC410, 8'h0F);         // latch, first AY (deselects the second)
        bus_write(16'hC410, 8'h1C);
        bus_write(16'hC413, 8'h00);
        bus_write(16'hC410, 8'h0D);         // read, first AY
        bus_read (16'hC411);
        if (cpu_din !== 8'h00) fail("the first AY's AFINE was disturbed by the second's write");
        else                   $display("  ok: the first AY's AFINE is still $00 - separate chips");
        bus_write(16'hC410, 8'h1C);
        bus_write(16'hC413, 8'hFF);

        // --- case 11 / $C0C2 on top: Echo+ mode ------------------------------
        // Bits OR in: 5 | 2 = 7.  VIA 1 answers at every offset.
        bus_write(16'hC413, 8'h0F);         // VIA 0 back to $0F, VIA 1 stays $33
        bus_read (16'hC0C2);
        bus_read (VIA0 | DDRA);
        if (cpu_din !== 8'h33) fail("Echo+ mode: $C403 is not VIA 1");
        else                   $display("  ok: Echo+ - $C403 reads VIA 1");
        bus_read (16'hC413);
        if (cpu_din !== 8'h33) fail("Echo+ mode: $C413 is not VIA 1");
        else                   $display("  ok: ...and so does $C413");

        // --- case 12 / A3 clears the mode ------------------------------------
        bus_read (16'hC0C8);
        bus_read (VIA0 | DDRA);
        if (cpu_din !== 8'h0F) fail("$C0C8 did not return to Mockingboard mode");
        else                   $display("  ok: $C0C8 - Mockingboard mode again");

        // --- case 13 / the bits accumulate: $C0C1 then $C0C4 -----------------
        bus_read (16'hC0C1);                // mode 1: undefined, nothing answers
        bus_read (VIA0 | DDRA);
        if (cpu_din !== 8'hEE) fail("an undefined mode answered");
        else                   $display("  ok: mode 1 is undefined - nothing answers");
        bus_write(16'hC0C4, 8'h00);         // a WRITE sets it too: 1 | 4 = 5
        bus_read (16'hC413);
        if (cpu_din !== 8'h0F) fail("$C0C1 then $C0C4 did not reach Phasor mode");
        else                   $display("  ok: $C0C1 then $C0C4 (a write) - Phasor mode");

        // --- case 14 / RES' clears the mode with the VIAs --------------------
        res_sync = 1'b0;
        repeat (300) @(posedge clk);
        res_sync = 1'b1;
        repeat (2) @(posedge cyc_en);
        bus_read (VIA0 | DDRA);
        if (cpu_din !== 8'h00) fail("RES' did not return the Phasor to Mockingboard mode");
        else                   $display("  ok: RES' - Mockingboard mode, $C403 reads VIA 0 (reset)");

        // --- case 15 / the timer latches survive RES', the controls do not ---
        // mb-audit's after-reset test: T1L written before a reset reads back
        // after it; ACR, PCR, DDRs, IER, IFR are cleared.
        bus_write(VIA0 | T1CL, 8'h34);
        bus_write(VIA0 | T1CH, 8'h02);      // T1C = T1L = $0234
        bus_write(VIA0 | 16'h000B, 8'h40);  // ACR free-running
        bus_write(VIA0 | IER,  8'hC0);      // T1 interrupt enabled
        bus_read (16'h1234);                // park on a read: the scripted CPU repeats its last op
        res_sync = 1'b0;
        repeat (300) @(posedge clk);
        res_sync = 1'b1;
        repeat (2) @(posedge cyc_en);
        bus_read (VIA0 | 16'h0006);         // T1L-L
        if (cpu_din !== 8'h34) fail("T1 latch low did not survive RES'");
        else                   $display("  ok: T1L-L = $34 survives RES'");
        bus_read (VIA0 | 16'h0007);         // T1L-H
        if (cpu_din !== 8'h02) fail("T1 latch high did not survive RES'");
        else                   $display("  ok: T1L-H = $02 survives RES'");
        bus_read (VIA0 | 16'h000B);
        if (cpu_din !== 8'h00) fail("ACR survived RES'");
        else                   $display("  ok: ACR cleared by RES'");
        bus_read (VIA0 | IER);
        if (cpu_din !== 8'h80) begin $display("  IER read %02x", cpu_din); fail("IER survived RES'"); end
        else                   $display("  ok: IER reads $80 after RES' - nothing enabled");
        bus_read (VIA0 | IFR);
        if (cpu_din[7:5] !== 3'b000) fail("an interrupt flag survived RES'");
        else                   $display("  ok: IFR clear after RES'");
        bus_read (VIA0 | ORB);              // DDRB clear: every pin an input, floating high
        if (cpu_din !== 8'hFF) fail("IRB with DDRB clear did not read $FF");
        else                   $display("  ok: IRB reads $FF with DDRB clear - inputs float high (GH#1260)");
        bus_read (VIA0 | ORA);
        if (cpu_din !== 8'hFF) fail("IRA with DDRA clear did not read $FF");
        else                   $display("  ok: IRA reads $FF with DDRA clear");

        // --- the speech chips ------------------------------------------------
        // A Phasor in Mockingboard mode after the RES' above.  mb-audit's
        // KickSSI263 on the PRIMARY chip ($C44x; its A/!R is VIA 1's CA1):
        // PCR $0C on VIA 1, IFR cleared, CA1's interrupt enabled, then CTL
        // high, DUR 3 with phoneme $28, CTL low.  In this mode the $C44x
        // writes also land in VIA 0 (A7 clear, A4-A6 undecoded), as on
        // the real card - harmless here.
        $display("\nthe speech chips\n");
        bus_write(VIA1 | 16'h000C, 8'h0C);  // PCR: CA1 negative edge
        bus_write(VIA1 | IFR,  8'h02);      // clear CA1's flag
        bus_write(VIA1 | IER,  8'h82);      // enable CA1's interrupt
        bus_write(16'hC443, 8'h80);         // CTL high
        bus_write(16'hC440, 8'hE8);         // DUR 3, phoneme $28
        t1_start = bus_cycles;
        bus_write(16'hC443, 8'h00);         // CTL low: it plays
        bus_read (VIA1 | IFR);
        if (cpu_din[1] !== 1'b0) fail("CA1 flag set before the phoneme completed");
        else                     $display("  ok: primary chip kicked - VIA 1 IFR CA1 clear");
        irq_at = -1;
        while (irq_at < 0 && (bus_cycles - t1_start) < 400) begin
            bus_read(16'h1234);
            if (mb_irq) irq_at = bus_cycles - t1_start;
        end
        if (irq_at < 0)                       fail("no speech interrupt through CA1");
        else if (irq_at < 215 || irq_at > 235) begin
            $display("  IRQ after %0d cycles", irq_at);
            fail("speech interrupt at the wrong time");
        end else $display("  ok: phoneme complete - IRQ through VIA 1's CA1 after %0d cycles (220 samples)", irq_at);
        bus_read(VIA1 | IFR);
        if (cpu_din[7] !== 1'b1 || cpu_din[1] !== 1'b1) fail("IFR does not show CA1");
        else                                            $display("  ok: IFR reads %02x - CA1 the cause", cpu_din);
        // The VIA's flag is the CPU's to clear; the chip's request is
        // cleared by a write to register 0, 1 or 2.
        bus_write(VIA1 | IFR, 8'h02);
        bus_read (16'h1234);
        if (mb_irq !== 1'b0) fail("IFR write did not clear the speech interrupt");
        else                 $display("  ok: writing IFR clears it");
        bus_write(16'hC441, 8'h00);         // reg 1: A/!R released
        // ...and the phoneme repeats after its leadout (88), so the flag
        // comes back: 88 + 220 cycles after the first completion.
        irq_at = -1;
        while (irq_at < 0 && (bus_cycles - t1_start) < 700) begin
            bus_read(16'h1234);
            if (mb_irq) irq_at = bus_cycles - t1_start;
        end
        if (irq_at < 0)                       fail("the phoneme did not repeat");
        else if (irq_at < 520 || irq_at > 545) begin
            $display("  second IRQ after %0d cycles", irq_at);
            fail("the repeat came at the wrong time");
        end else $display("  ok: the phoneme repeats - IRQ again %0d cycles after the kick (220 + 88 + 220)", irq_at);
        bus_write(VIA1 | IFR, 8'h02);
        // DisableSSI263: CTL high, DR1:0 = 00, CTL low - no more interrupts.
        bus_write(16'hC443, 8'h80);
        bus_write(16'hC440, 8'h00);
        bus_write(16'hC443, 8'h00);
        bus_read (16'h1234);
        if (mb_irq !== 1'b0) fail("interrupt survived the disable");
        else                 $display("  ok: DisableSSI263 - quiet");

        // --- the secondary chip is VIA 0's ----------------------------------
        bus_write(VIA0 | 16'h000C, 8'h0C);
        bus_write(VIA0 | IFR,  8'h02);
        bus_write(VIA0 | IER,  8'h82);
        bus_write(16'hC423, 8'h80);
        bus_write(16'hC420, 8'hE8);
        t1_start = bus_cycles;
        bus_write(16'hC423, 8'h00);
        irq_at = -1;
        while (irq_at < 0 && (bus_cycles - t1_start) < 400) begin
            bus_read(16'h1234);
            if (mb_irq) irq_at = bus_cycles - t1_start;
        end
        bus_read(VIA0 | IFR);
        if (irq_at < 0 || cpu_din[1] !== 1'b1) fail("the secondary chip did not interrupt through VIA 0");
        else                                   $display("  ok: secondary chip ($C42x) - IRQ through VIA 0's CA1 after %0d cycles", irq_at);
        bus_write(VIA0 | IFR, 8'h02);
        bus_write(16'hC423, 8'h80);         // power it down
        bus_write(16'hC420, 8'h00);
        bus_write(16'hC423, 8'h00);
        bus_write(VIA0 | IER,  8'h02);      // and disable CA1 on VIA 0
        bus_write(VIA1 | IER,  8'h02);      // and VIA 1

        // --- native mode: D7 readable, A/!R straight to the CPU ------------
        // mb-audit T263_2: kick with phoneme 0 at DUR 3 (664 samples),
        // read D7 at $C440 - clear, then set - and the IRQ arrives with
        // no VIA involved (IER has CA1 off).
        bus_read (16'hC0C5);
        bus_write(16'hC443, 8'h80);
        bus_write(16'hC440, 8'hE8);
        t1_start = bus_cycles;
        bus_write(16'hC443, 8'h00);
        bus_read (16'hC440);
        if (cpu_din !== 8'h00) begin $display("  read %02x", cpu_din); fail("native mode: $C440 did not read D7 clear"); end
        else                   $display("  ok: native mode - $C440 reads $00, D7 clear (claimed, the rest low)");
        irq_at = -1;
        while (irq_at < 0 && (bus_cycles - t1_start) < 400) begin
            bus_read(16'h1234);
            if (mb_irq) irq_at = bus_cycles - t1_start;
        end
        if (irq_at < 0 || irq_at < 215 || irq_at > 235) begin
            $display("  IRQ after %0d cycles", irq_at);
            fail("native mode: no direct interrupt at completion");
        end else $display("  ok: native mode - the chip's A/!R interrupts the CPU directly after %0d cycles", irq_at);
        bus_read (16'hC443);                // any register offset reads D7
        if (cpu_din !== 8'h80) fail("native mode: D7 not readable at $C443");
        else                   $display("  ok: $C443 reads $80 - D7 set");
        bus_read (VIA1 | IFR);
        if (cpu_din[1] !== 1'b0) fail("native mode: CA1 flag set - A/!R should not reach the VIA");
        else                     $display("  ok: VIA 1's CA1 flag stays clear in native mode");
        bus_read (16'hC420);                // the secondary: powered down, D7 clear
        if (cpu_din !== 8'h00) fail("native mode: the secondary chip's D7 read set");
        else                   $display("  ok: $C420 reads the secondary chip's D7, clear");
        bus_write(16'hC444, 8'h55);         // reg 4: no effect on D7
        bus_read (16'hC440);
        if (cpu_din !== 8'h80) fail("a filter write cleared D7");
        else                   $display("  ok: a write to reg 4 leaves D7 and the interrupt");
        bus_write(16'hC442, 8'h00);         // reg 2: clears
        bus_read (16'hC440);
        if (cpu_din !== 8'h00 || mb_irq !== 1'b0) fail("a write to reg 2 did not clear D7/IRQ");
        else                                      $display("  ok: a write to reg 2 clears D7 and the interrupt");

        // --- the mode change carries the request -----------------------------
        // mb-audit T263_8: complete in native mode, then switch to
        // Mockingboard mode with D7 up - the flag appears in VIA 1's IFR;
        // Echo+ takes it nowhere.
        irq_at = -1;
        t1_start = bus_cycles;
        while (irq_at < 0 && (bus_cycles - t1_start) < 700) begin
            bus_read(16'h1234);
            if (mb_irq) irq_at = bus_cycles - t1_start;
        end
        if (irq_at < 0) fail("no repeat in native mode");
        bus_read (16'hC0C8);                // Mockingboard mode
        bus_read (16'h1234);
        bus_read (VIA1 | IFR);
        if (cpu_din[1] !== 1'b1) fail("entering Mockingboard mode with D7 up did not set CA1's flag");
        else                     $display("  ok: back to Mockingboard mode with a request up - VIA 1's CA1 flag set");
        bus_write(VIA1 | IFR, 8'h02);
        bus_read (16'hC0C7);                // Echo+
        bus_read (16'h1234);
        bus_read (VIA1 | IFR);
        if (cpu_din[1] !== 1'b0 || mb_irq !== 1'b0) fail("Echo+ mode routed the request somewhere");
        else                                        $display("  ok: Echo+ - the request goes nowhere");
        bus_write(16'hC441, 8'h00);         // Echo+: this write does NOT reach the chip
        bus_read (16'hC0C8);
        bus_read (16'hC0C5);                // native: D7 still up
        bus_read (16'hC440);
        if (cpu_din !== 8'h80) fail("an Echo+ write reached the speech chip");
        else                   $display("  ok: a write in Echo+ mode did not reach the chip - D7 still set");
        bus_write(16'hC441, 8'h00);
        bus_write(16'hC443, 8'h80);         // power down
        bus_read (16'hC0C8);

        // --- RES' powers the chips down --------------------------------------
        bus_write(16'hC443, 8'h80);
        bus_write(16'hC440, 8'hE8);
        bus_write(16'hC443, 8'h00);         // playing
        res_sync = 1'b0;
        repeat (300) @(posedge clk);
        res_sync = 1'b1;
        repeat (2) @(posedge cyc_en);
        t1_start = bus_cycles;
        irq_at = -1;
        bus_read (16'hC0C5);
        while (irq_at < 0 && (bus_cycles - t1_start) < 300) begin
            bus_read(16'h1234);
            if (mb_irq) irq_at = bus_cycles - t1_start;
        end
        bus_read (16'hC440);
        if (irq_at >= 0 || cpu_din !== 8'h00) fail("a speech chip played on through RES'");
        else                                  $display("  ok: RES' - the chip is powered down, nothing completes");
        bus_read (16'hC0C8);

        // --- the standing invariant ------------------------------------------
        if (read_drive_unclaimed != 0)
            fail("the data bus was driven on a read the card had not claimed");
        else
            $display("  ok: no read was ever driven unclaimed, over the whole run");

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
