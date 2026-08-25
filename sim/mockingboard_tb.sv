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
        .master_active (master_active),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (1'b0), .drv_sync (drv_sync),
        .cyc_en (cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (rd_claim), .slot_rd_data (rd_data),
        .ovr_en (1'b0), .ovr_addr (16'h0000), .ovr_rw (1'b1), .ovr_wdata (8'h00), .op_ovr (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    mockingboard u_mb (
        .clk (clk), .rst (rst),
        .res_sync (res_sync),
        .master_active (master_active),
        .slot_assign (slot_assign),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
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
