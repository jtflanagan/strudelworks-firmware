`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// wb_regfile - the card's control registers, as a Wishbone B4 slave.
//
// WHY A SECOND WISHBONE AND NOT THE DDR3 ONE.  The DDR3 bus is 128 bits wide and
// its address is a BURST INDEX, not a byte address - one Wishbone word is one
// DDR3 burst (see docs/DDR3_USAGE.md).  That shape is right for bulk memory and
// wrong for control registers, which want 32 bits and a byte address.  So this
// is a separate 32-bit Wishbone instance rather than a decode off the DDR3 bus:
// same protocol, different geometry, and neither distorts the other.
//
// They stay independently addressable because they are in disjoint regions of
// the host-visible 32-bit address space:
//
//   0x0000_0000 .. 0x0FFF_FFFF   DDR3    (2^24 bursts x 16 bytes = 256 MB)
//   0x8000_0000 .. 0x8000_FFFF   registers
//
// so one address bit tells them apart and neither has to know the other exists.
//
// Registers are 32 bits, word aligned.  A read of an unimplemented address
// returns zero and acks; a write to a read-only or unimplemented address is
// accepted and discarded.  Neither errs, deliberately: the host discovers what
// exists by reading it, and an ERR on this bus would have to be plumbed all the
// way back through the message layer to say something the value already says.
//
// TIMING: single-cycle ack, never stalls.  A register file that made the host
// wait would be measuring nothing but itself.
//////////////////////////////////////////////////////////////////////////////////
module wb_regfile #(
    // Stamped by build/build.sh through build.tcl's -generic.  Zero means the
    // bitstream was built without a stamp - an interactive GUI build - and the
    // host is expected to say "unstamped" rather than render it as a date.
    parameter integer BUILD_DATE = 0,   // YYYYMMDD
    parameter integer BUILD_TIME = 0,   // HHMMSS

    // Top half of the byte address that selects this block.  The full 32-bit
    // address arrives here and the region is decoded HERE rather than upstream,
    // so that an access outside it still acks: a decode that simply withheld
    // ack would hang the bridge waiting for a reply that is never coming, and
    // the host would see a dead link rather than a bad address.
    parameter [15:0] REGION = 16'h8000,

    // 1 only in a bitstream whose top can actually assert DMA' and drive the
    // Apple bus.  The register below exists in EVERY build so the host reads it
    // the same way everywhere; this is how the host tells a snooper from a
    // master, and it is what stops a snoop build ever latching itself into
    // "the soft CPU is driving" when nothing in it can drive.
    parameter bit CAN_MASTER = 1'b0
) (
    input  wire            clk,
    input  wire            rst,

    // Synchronised RES', ACTIVE LOW, from apple_bus_read.
    input  wire            apple_res_sync,

    // Which CPU owns the bus.  A master top drives DMA' and the address/data
    // enables from this; see docs/BUS_MASTER.md.
    output wire            cpu_source_active,

    // Which slot the on-card Mockingboard answers as; 0 keeps it out of the
    // machine entirely.  Latched the same way CPU_SOURCE is - see below.
    output wire [2:0]      mb_slot_active,

    // The boot hold (rtl/boot_hold.sv).  arm is a level the host sets;
    // release is a one-cycle pulse per write of the release bit; held comes
    // back from the hold itself, for the readback.  A watching top ties held
    // to 0 and leaves the rest unconnected.
    output wire            boot_arm,
    output logic           boot_release,
    input  wire            boot_held,

    // The hard disk (rtl/hd_card.sv).  The slot is latched at RES' like the
    // Mockingboard's; the rest is status coming back for the readback.  A
    // watching top ties the inputs to 0 and leaves the output unconnected.
    output wire [2:0]      hd_slot_active,
    input  wire            hd_rom_loaded,
    input  wire            hd_busy,
    input  wire [7:0]      hd_execs,

    // Keyboard injection (rtl/kbd_inject.sv).  press and drop are one-cycle
    // pulses per write of their bits, press_key the key that write carried;
    // lock and notify are levels the host holds.  The flags and the counts
    // come back for the readback: kbd_flags is {touched, seen, strobe},
    // kbd_counts is {replaced, flushed, taken, pressed} - the notice's
    // payload word, and the two registers slice it.  A watching top ties
    // the inputs to 0 and leaves the outputs unconnected.
    output logic           kbd_press,
    output logic [6:0]     kbd_press_key,
    output logic           kbd_drop,
    output logic           kbd_lock,
    output logic           kbd_notify,
    input  wire [2:0]      kbd_flags,
    input  wire [31:0]     kbd_counts,

    // The pushbuttons (rtl/pb_inject.sv): the host's word per button out,
    // the hardware's level back for the readback.
    output logic [5:0]     pb_override,
    input  wire [2:0]      pb_hw,

    // Programmatic Ctrl-Reset.  Held low while pulsing; the master top turns
    // this into an open-drain drive of the Apple's RES' line, exactly as it
    // drives DMA'.  A snoop build ties CAN_MASTER low, so this never asserts
    // and its pin stays an input.  See docs/BUS_MASTER.md.
    output wire            res_drive,

    // Wishbone B4 classic, 32-bit.
    // RING_STATUS, straight from tx_ring: the DDR3 ring's occupancy in
    // lines, whether it is full, and whether the DDR3 has calibrated at all.
    input  wire [31:0]     ring_status,
    input  wire            wb_cyc,
    input  wire            wb_stb,
    input  wire            wb_we,
    input  wire [31:0]     wb_adr,     // full byte address
    input  wire [31:0]     wb_dat_w,
    input  wire [3:0]      wb_sel,
    output logic           wb_ack,
    output wire            wb_stall,
    output logic [31:0]    wb_dat_r
);

    // Word index within the region: the low two bits are byte lanes and are not
    // decoded, so a misaligned address reads the word containing it rather than
    // erring - the same forgiving treatment as an unknown address.
    wire        in_region = (wb_adr[31:16] == REGION);
    wire [13:0] word      = wb_adr[15:2];

    // ---- the map ------------------------------------------------------------
    // Adding a register is one localparam and one case arm.  Keep the numbering
    // dense and never reuse a retired number: a host built against an older map
    // reading a recycled address gets a plausible wrong answer, which is worse
    // than the zero it would get from a hole.
    localparam [13:0] R_BUILD_DATE = 'd0;   // 0x8000_0000, RO
    localparam [13:0] R_BUILD_TIME = 'd1;   // 0x8000_0004, RO
    localparam [13:0] R_CPU_SOURCE = 'd2;   // 0x8000_0008, RW in bit 0
    localparam [13:0] R_MB_SLOT    = 'd3;   // 0x8000_000C, RW in bits 2:0
    localparam [13:0] R_BOOT_HOLD  = 'd4;   // 0x8000_0010, RW bit 0, W1 bit 16
    localparam [13:0] R_HD_SLOT    = 'd5;   // 0x8000_0014, RW in bits 2:0
    localparam [13:0] R_RESET      = 'd6;   // 0x8000_0018, W1 bit 0 pulses RES'
    localparam [13:0] R_KBD_INJECT = 'd7;   // 0x8000_001C, W bits 6:0, W1 bits 7-8
    localparam [13:0] R_BUTTONS    = 'd8;   // 0x8000_0020, RW bits 5:0
    localparam [13:0] R_RING_STATUS = 'd9;  // 0x8000_0024, RO
    localparam [13:0] R_KBD_CTRL   = 'd10;  // 0x8000_0028, RW bits 1:0

    // ---- CPU_SOURCE ---------------------------------------------------------
    //
    //   [0]      desired   RW   0 = the native 6502 (default), 1 = the soft core
    //   [8]      active    RO   what was latched at the last RES' assertion
    //   [16]     capable   RO   this bitstream can actually master the bus
    //   [31:24]  latches   RO   RES' assertions seen, wrapping
    //
    // WHY IT LATCHES ON RES' AND NOT ON THE WRITE.  Handing the bus over is a
    // transition with no good moment in the middle of a running machine: the
    // real CPU is mid-instruction, the soft core is not where the real one was,
    // and whatever mess the DMA' transition makes lands in software's lap.
    //
    // A reset has no such lap to land in.  The Apple's own RESET is held for a
    // long time by the motherboard - far longer than the changeover - and
    // everything after it starts from the vector, so a switch made anywhere
    // inside that window is invisible by construction.  So the write only ever
    // sets an INTENTION, and the next reset is what acts on it.
    //
    // The falling edge is the assertion, RES' being active low.  Latching on
    // the edge rather than on the level keeps it to exactly one changeover per
    // reset however long the reset is held, and however much the line bounces -
    // which it does, being a switch with nothing debouncing it (see DERISK).
    //
    // `latches` is what lets the host tell whether its write has taken effect
    // yet: write desired, read back, and if the count has not moved then no
    // reset has happened and `active` is still the old answer.  Without it the
    // host cannot distinguish "not reset yet" from "reset and ignored".
    logic       cpu_src_desired;
    logic       cpu_src_active;
    logic [7:0] cpu_src_latches;
    logic       res_prev;

    // Falling edge of an active-low line is the assertion.
    wire res_assert = res_prev && !apple_res_sync;

    assign cpu_source_active = cpu_src_active;

    always_ff @(posedge clk) begin
        if (rst) begin
            cpu_src_desired <= 1'b0;      // the native CPU keeps the bus
            cpu_src_active  <= 1'b0;
            cpu_src_latches <= 8'd0;
            res_prev        <= 1'b1;      // idle high: no phantom assert at rst
        end else begin
            res_prev <= apple_res_sync;
            if (res_assert) begin
                // Forced to 0 when this bitstream cannot drive.  The readback
                // then tells the truth - desired reads back as written, active
                // stays 0, and `capable` says why - rather than a snoop build
                // reporting itself as the machine's CPU.
                cpu_src_active  <= CAN_MASTER ? cpu_src_desired : 1'b0;
                cpu_src_latches <= cpu_src_latches + 8'd1;
            end
            if (wr_cpu_source) cpu_src_desired <= wb_dat_w[0];
        end
    end

    wire [31:0] cpu_source_rd = {cpu_src_latches, 7'd0, CAN_MASTER,
                                 7'd0, cpu_src_active, 7'd0, cpu_src_desired};

    // ---- MB_SLOT ------------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the Mockingboard answers as; 0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //
    // The same reset-latched contract as CPU_SOURCE, for the same reason
    // scaled down: the slot scan happens at boot, and a card that appears (or
    // moves) in the middle of a running machine is a card the software has
    // already decided about.  A reset is when the decision is re-made, so a
    // reset is when the answer changes.  Gated by CAN_MASTER because the
    // Mockingboard can only put a byte on the bus from a mastering build; in
    // a snoop build `desired` reads back as written and `active` stays 0,
    // which is the register telling the truth rather than erring.
    logic [2:0] mb_slot_desired;
    logic [2:0] mb_slot_active_q;

    assign mb_slot_active = mb_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            mb_slot_desired <= 3'd0;      // no Mockingboard until asked for
            mb_slot_active_q <= 3'd0;
        end else begin
            // A reset assertion is the ordinary latch point; a boot-hold
            // RELEASE is the second one, so that a menu shown during a hold
            // can enable or move the Mockingboard for the very boot it is
            // about to let go.  See BOOT_HOLD's boot_relatch below and
            // docs/BOOT_MENU.md.  The write only ever sets `desired`; both
            // edges copy it into `active`.
            if (res_assert || boot_relatch) begin
                mb_slot_active_q <= CAN_MASTER ? mb_slot_desired : 3'd0;
            end
            if (wr_mb_slot) mb_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] mb_slot_rd = {21'd0, mb_slot_active_q, 5'd0, mb_slot_desired};

    // ---- BOOT_HOLD ----------------------------------------------------------
    //
    //   [0]      arm       RW   hold the soft core at its reset vector, at the
    //                           next reset and every one after, until cleared
    //   [8]      held      RO   the core is held now
    //   [16]     release   W1   let a held core go; reads as 0
    //   [31:24]  holds     RO   times the hold has engaged, wrapping
    //
    // NOT reset-latched, unlike its neighbours, and deliberately: `arm` is the
    // standing intention "stop at the next boot", which is exactly what a
    // level that persists across resets expresses.  The hold itself engages
    // at a point the core defines - the first opcode fetch after reset - and
    // rtl/boot_hold.sv is where that is recognised; this register only carries
    // the host's wishes in and the state back out.  See docs/BOOT_MENU.md.
    //
    // `holds` is the counterpart of CPU_SOURCE's `latches`: it lets a host
    // that missed a CPU_HOLD notice - or attached after it - tell a hold that
    // happened from one that did not.  The release bit reads as zero because
    // it is an action, not a state; the state it acts on is `held`.
    logic       boot_arm_q;
    logic [7:0] boot_holds;
    logic       boot_held_prev;

    assign boot_arm = boot_arm_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            boot_arm_q     <= 1'b0;       // boot straight through until asked
            boot_holds     <= 8'd0;
            boot_held_prev <= 1'b0;
            boot_release   <= 1'b0;
        end else begin
            boot_held_prev <= boot_held;
            if (boot_held && !boot_held_prev) boot_holds <= boot_holds + 8'd1;
            if (wr_boot_hold) boot_arm_q <= wb_dat_w[0];
            // One pulse per write that set the bit, however long the host's
            // message took to arrive.  The hold consumes it at a cycle end.
            boot_release <= wr_boot_hold && wb_dat_w[16];
        end
    end

    wire [31:0] boot_hold_rd = {boot_holds, 15'd0, boot_held, 7'd0, boot_arm_q};

    // ---- HD_SLOT ------------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the hard disk answers as; 0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [16]     rom       RO   the 256-byte slot ROM has been loaded (HD_ROM)
    //   [17]     busy      RO   a command is outstanding: the port reads busy
    //   [31:24]  execs     RO   EXECUTE reads taken, wrapping
    //
    // MB_SLOT's contract again, and one more rule: the two slots may not
    // coincide.  Both peripherals claim read cycles in their slot's ranges,
    // and two claimants for one cycle would both drive the bus.  The disk
    // yields - it is the newer of the two - and `active` says so, latching 0
    // when the Mockingboard has the same slot asked for.  The host checks
    // the readback rather than assuming.  See docs/HARDDISK.md.
    logic [2:0] hd_slot_desired;
    logic [2:0] hd_slot_active_q;

    assign hd_slot_active = hd_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            hd_slot_desired  <= 3'd0;     // no hard disk until asked for
            hd_slot_active_q <= 3'd0;
        end else begin
            // Same two latch points as MB_SLOT, and the same clash rule at
            // each: the disk yields the Mockingboard's slot.  See BOOT_MENU.md.
            if (res_assert || boot_relatch) begin
                hd_slot_active_q <= (CAN_MASTER && hd_slot_desired != mb_slot_desired)
                                    ? hd_slot_desired : 3'd0;
            end
            if (wr_hd_slot) hd_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] hd_slot_rd = {hd_execs, 6'd0, hd_busy, hd_rom_loaded,
                              5'd0, hd_slot_active_q, 5'd0, hd_slot_desired};

    // ---- RESET --------------------------------------------------------------
    //
    //   [0]      pulse     W1   assert the Apple's RES' low for a while
    //   [31:16]  cycles    W    duration in 256-cycle units; 0 = the default
    //   [0]      pulsing   RO   the pulse is asserting now
    //   [31:24]  pulses    RO   pulses issued, wrapping
    //
    // A physical Ctrl-Reset pulls the bus RES' line - a wired-OR, open-drain
    // line - low for as long as the key is held.  This does the same from the
    // host: the master top drives the line low while `res_drive` is high and
    // releases it to Hi-Z otherwise.  Everything a real reset does then
    // follows, because the reader samples our own driven low back as
    // `apple_res_sync` - the soft core resets, and CPU_SOURCE / MB_SLOT /
    // HD_SLOT re-latch on the assertion, same as any reset.
    //
    // The counter lives in this always-on clock domain, NOT the one RES'
    // resets, so the pulse it is generating cannot cut itself short.  Only a
    // CAN_MASTER build may drive; a snooper's pin is an input.
    //
    // ~20 us default (2000 cycles at 100 MHz): far longer than the soft core's
    // seven-cycle reset needs, and short enough to be imperceptible.  A caller
    // that wants the machine visibly held passes a bigger count.
    localparam integer RES_DEFAULT = 2000;
    logic [23:0] res_cnt;
    logic [7:0]  res_pulses;
    wire  res_pulsing = (res_cnt != 24'd0);
    assign res_drive = CAN_MASTER && res_pulsing;

    always_ff @(posedge clk) begin
        if (rst) begin
            res_cnt    <= 24'd0;
            res_pulses <= 8'd0;
        end else if (wr_reset && wb_dat_w[0] && !res_pulsing) begin
            res_cnt    <= (wb_dat_w[31:16] != 16'd0) ? {wb_dat_w[31:16], 8'd0}
                                                     : RES_DEFAULT[23:0];
            res_pulses <= res_pulses + 8'd1;
        end else if (res_pulsing) begin
            res_cnt <= res_cnt - 24'd1;
        end
    end

    wire [31:0] reset_rd = {res_pulses, 23'd0, res_pulsing};

    // ---- KBD_INJECT ---------------------------------------------------------
    //
    //   [6:0]    key       W    the key, taken when press is set
    //   [7]      press     W1   put key on the keyboard, strobe set, replacing
    //                           an unconsumed one; reads as 0
    //   [8]      drop      W1   clear the strobe without a $C010; reads as 0
    //   [16]     strobe    RO   a key is waiting that the machine has not taken
    //   [17]     seen      RO   ...and a $C00x read has returned it
    //   [31:24]  pressed   RO   presses, wrapping
    //
    // The machine's keyboard has one latch and one strobe, and so does this:
    // a press is a keypress, it always lands, and the newest wins.  Typing a
    // string at the machine's pace is the host's job - press, wait for the
    // press to be resolved, press the next - and KBD_CTRL and the KBD_EVENT
    // notice are how it learns that.  The reply to the press itself is the
    // acknowledgement that it arrived, showing the state BEFORE it: the
    // press's own number is the `pressed` it reads plus one, and `strobe`
    // says whether it landed on a key still waiting.  Nothing here is
    // reset-latched: a key is for the program running now, and
    // rtl/kbd_inject.sv drops it if a reset comes first.  Not gated by
    // CAN_MASTER - the pulses simply go nowhere in a watching build, and the
    // readback there says strobe=0, which is the truth.
    always_ff @(posedge clk) begin
        if (rst) begin
            kbd_press     <= 1'b0;
            kbd_press_key <= 7'd0;
            kbd_drop      <= 1'b0;
        end else begin
            kbd_press     <= wr_kbd_inject && wb_dat_w[7];
            kbd_drop      <= wr_kbd_inject && wb_dat_w[8];
            if (wr_kbd_inject) kbd_press_key <= wb_dat_w[6:0];
        end
    end

    wire [31:0] kbd_inject_rd = {kbd_counts[7:0], 6'd0, kbd_flags[1:0], 16'd0};

    // ---- KBD_CTRL -----------------------------------------------------------
    //
    //   [0]      lock      RW   suppress the machine's own keyboard: the core
    //                           reads the injected keys and nothing else
    //   [1]      notify    RW   send a KBD_EVENT notice on every resolution
    //   [7]      touched   RO   a real key arrived while locked; cleared when
    //                           lock is next set
    //   [15:8]   taken     RO   presses resolved: read, then strobed
    //   [23:16]  flushed   RO   presses resolved: strobed unread
    //   [31:24]  replaced  RO   presses resolved: pressed over
    //
    // A press is resolved by exactly one of taken, flushed, replaced, or a
    // drop (the register's, or a RES'), which is not counted: it is
    // pressed - strobe - the three above.  The host that presses one key and
    // waits reads "resolved" as pressed - strobe, and its press is done when
    // that reaches the number the ack gave it.  `notify` is the host asking
    // to be told unasked - the silent-until-asked rule, docs/PROTOCOL.md -
    // and the notice carries the same words these two registers do.
    //
    // Both levels are the host's standing intention and survive a RES', as
    // BUTTONS does: a test that resets the machine wants its lock kept.
    // The card's reset - the watchdog's included - clears them, so a host
    // that has gone leaves no keyboard locked behind it.
    always_ff @(posedge clk) begin
        if (rst) begin
            kbd_lock   <= 1'b0;
            kbd_notify <= 1'b0;
        end else if (wr_kbd_ctrl) begin
            kbd_lock   <= wb_dat_w[0];
            kbd_notify <= wb_dat_w[1];
        end
    end

    wire [31:0] kbd_ctrl_rd = {kbd_counts[31:8], kbd_flags[2], 5'd0,
                               kbd_notify, kbd_lock};

    // ---- BUTTONS ------------------------------------------------------------
    //
    //   [1:0]    pb0       RW   Open-Apple:    00 hardware, 01 up, 10 down
    //   [3:2]    pb1       RW   Closed-Apple:  the same
    //   [5:4]    pb2       RW   PB2 ($C063):   the same
    //   [18:16]  hw        RO   bit 7 as the bus said it, last read of each
    //
    // A level the host holds, not an event: the machine reads a button now,
    // so there is nothing to consume.  Down then hardware is a press.  Not
    // reset-latched, and NOT dropped by RES' (rtl/pb_inject.sv says why:
    // Open-Apple-Ctrl-Reset is what Open-Apple is for).  11 is read as
    // down; the host never writes it.
    always_ff @(posedge clk) begin
        if (rst) begin
            pb_override <= 6'd0;          // hardware, all three
        end else if (wr_buttons) begin
            pb_override <= wb_dat_w[5:0];
        end
    end

    wire [31:0] buttons_rd = {13'd0, pb_hw, 10'd0, pb_override};

    assign wb_stall = 1'b0;

    wire access = wb_cyc && wb_stb;

    always_ff @(posedge clk) begin
        if (rst) begin
            wb_ack   <= 1'b0;
            wb_dat_r <= 32'd0;
        end else begin
            // One ack per strobe, and only ever one cycle wide.
            wb_ack <= access && !wb_ack;

            if (access && !wb_ack) begin
                if (!in_region) begin
                    wb_dat_r <= 32'd0;
                end else begin
                    case (word)
                        R_BUILD_DATE: wb_dat_r <= BUILD_DATE[31:0];
                        R_BUILD_TIME: wb_dat_r <= BUILD_TIME[31:0];
                        R_CPU_SOURCE: wb_dat_r <= cpu_source_rd;
                        R_MB_SLOT:    wb_dat_r <= mb_slot_rd;
                        R_BOOT_HOLD:  wb_dat_r <= boot_hold_rd;
                        R_HD_SLOT:    wb_dat_r <= hd_slot_rd;
                        R_RESET:      wb_dat_r <= reset_rd;
                        R_KBD_INJECT: wb_dat_r <= kbd_inject_rd;
                        R_BUTTONS:    wb_dat_r <= buttons_rd;
                        R_RING_STATUS: wb_dat_r <= ring_status;
                        R_KBD_CTRL:   wb_dat_r <= kbd_ctrl_rd;
                        default:      wb_dat_r <= 32'd0;
                    endcase
                end
            end
        end
    end

    // Writes.  One strobe per access, on the same edge the read uses, so a
    // write and its ack are the same single cycle a read is.  A write to a
    // read-only or unimplemented address lands nowhere and still acks, which is
    // the same forgiveness the read side gives an unknown address.
    //
    // wb_sel is not honoured: this file is whole-words-only by construction
    // (reg_bridge ties it to 4'hF), and a byte-enabled control register would
    // be a lie about what the host can express.
    wire wr_cpu_source = access && !wb_ack && in_region && wb_we &&
                         (word == R_CPU_SOURCE);
    wire wr_mb_slot    = access && !wb_ack && in_region && wb_we &&
                         (word == R_MB_SLOT);
    wire wr_boot_hold  = access && !wb_ack && in_region && wb_we &&
                         (word == R_BOOT_HOLD);
    wire wr_hd_slot    = access && !wb_ack && in_region && wb_we &&
                         (word == R_HD_SLOT);
    wire wr_reset      = access && !wb_ack && in_region && wb_we &&
                         (word == R_RESET);
    wire wr_kbd_inject = access && !wb_ack && in_region && wb_we &&
                         (word == R_KBD_INJECT);
    wire wr_buttons    = access && !wb_ack && in_region && wb_we &&
                         (word == R_BUTTONS);
    wire wr_kbd_ctrl   = access && !wb_ack && in_region && wb_we &&
                         (word == R_KBD_CTRL);

    // A boot-hold RELEASE re-latches MB_SLOT and HD_SLOT above, so the menu's
    // choices reach the boot it releases into.  Same qualification as the
    // release pulse itself; CPU_SOURCE deliberately does NOT re-latch here -
    // switching the driving CPU mid-hold is the one changeover BOOT_MENU.md
    // keeps to a reset.
    wire boot_relatch  = wr_boot_hold && wb_dat_w[16];

    // wb_adr[1:0] are byte lanes within a word and are deliberately not decoded.
    wire _unused_ok = &{1'b0, wb_dat_w[31:1], wb_sel, wb_adr[1:0], 1'b0};

endmodule
