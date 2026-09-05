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
    // log2 of the page cache's pages (256 x 256 bytes), for MEM_CTRL's
    // readback.  Was log2 of the 4-way cache's sets before the page cache.
    parameter integer MEM_SETS_LOG2 = 8,
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
    // ...and which door the hold in progress came in by (rtl/boot_hold.sv):
    // 1 for the runtime menu's, 0 for the boot's.  Read back beside `held`,
    // and it decides whether a release re-latches the slots.
    input  wire            hold_runtime,

    // The runtime menu's door (rtl/boot_hold.sv, docs/RUNTIME_MENU.md):
    // watch for the hotkey, which key, and the host's own knock - a
    // one-cycle pulse per write of the trigger bit.  A watching top leaves
    // them unconnected.
    output logic           menu_en,
    output logic [6:0]     menu_hotkey,
    output logic           menu_trigger,

    // The hard disk (rtl/hd_card.sv).  The slot is latched at RES' like the
    // Mockingboard's; the rest is status coming back for the readback.  A
    // watching top ties the inputs to 0 and leaves the output unconnected.
    output wire [2:0]      hd_slot_active,
    input  wire            hd_rom_loaded,
    input  wire            hd_busy,
    input  wire [7:0]      hd_execs,

    // The floppy (rtl/floppy_card.sv, docs/FLOPPY.md).  The slot latches
    // like the disk's; what is IN each drive is live, because the runtime
    // menu changes a disk under a running program; the rest is the
    // controller's state coming back for the readback.  A watching top ties
    // the inputs to 0 and leaves the outputs unconnected.
    output wire [2:0]      fd_slot_active,
    input  wire            fd_rom_loaded,
    input  wire [7:0]      fd_seeks,
    output logic [1:0]     fd_inserted,
    output logic [1:0]     fd_wp,
    output logic [25:0]    fd_nibbles,      // [12:0] drive 1, [25:13] drive 2
    output logic [11:0]    fd_tracks,       // [5:0] drive 1, [11:6] drive 2
    output logic [1:0]     fd_flush,        // pulses
    input  wire [1:0]      fd_stale,
    input  wire [1:0]      fd_dirty,
    input  wire [13:0]     fd_phase,        // [6:0] drive 1, [13:7] drive 2
    input  wire [3:0]      fd_ctl,          // {q7, q6, drive_sel, motor}
    input  wire [7:0]      fd_late,
    input  wire [15:0]     fd_fill_max,
    output logic           fd_late_clr,     // pulses
    output logic           fd_fill_clr,

    // The VidHD (rtl/vidhd_card.sv, docs/VIDHD.md): its slot latched like
    // the floppy's, and whether its ROM has landed, for the readback.  A
    // watching top ties the input to 0 and leaves the output unconnected.
    output wire [2:0]      vidhd_slot_active,
    input  wire            vidhd_rom_loaded,
    // The mouse (rtl/mouse_card.sv, docs/MOUSE.md): its slot latched like
    // the VidHD's, yielding to all four of the others; MOUSE_STAT reads
    // the card's position and the rest for diagnosis.
    output wire [2:0]      mouse_slot_active,
    input  wire            mouse_rom_loaded,
    input  wire            mouse_irq,
    input  wire [3:0]      mouse_mode,
    input  wire [1:0]      mouse_buttons,
    input  wire [7:0]      mouse_moves,
    input  wire [15:0]     mouse_x,
    input  wire [15:0]     mouse_y,

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

    // The VBL lock (rtl/vbl_lock.sv, docs/VBL.md): start and probe are
    // one-cycle pulses per write of their bits, notify and probe_addr
    // levels; the rest is the detector's state coming back for the
    // readback.  A watching top ties the inputs to 0.
    output logic           vbl_start,
    output logic           vbl_probe,
    output logic           vbl_notify,
    output logic [15:0]    vbl_probe_addr,
    input  wire [3:0]      vbl_state,
    input  wire            vbl_locked,
    input  wire            vbl_pal,
    input  wire            vbl_busy,
    input  wire [3:0]      vbl_err,
    input  wire [31:0]     vbl_stat,
    input  wire [31:0]     vbl_pos,

    // The memory image and its page cache (rtl/page_cache.sv, rtl/page_client.sv,
    // docs/MEMORY.md): MEM_CTRL's serve bits out as levels and its W1 bits as
    // pulses; the shadow's switches, the counters and the state back for the
    // readback.  A watching top ties the inputs to 0 and leaves the outputs
    // unconnected.
    output logic           mem_serve,       // all-or-nothing serve enable
    output logic           mem_cnt_clr,     // pulses
    output logic           mem_inval,
    input  wire [11:0]     mem_sw,
    input  wire [7:0]      mem_rw_bank,     // the RamWorks bank register
    input  wire            mem_image_ready,
    input  wire            mem_invalidating,
    input  wire            mem_rom_loaded,
    input  wire [7:0]      mem_late_fills,
    input  wire [7:0]      mem_fifo_drops,
    input  wire [31:0]     mem_hits,
    input  wire [31:0]     mem_misses,
    input  wire [31:0]     mem_mismatch,
    input  wire [31:0]     mem_served,
    input  wire [31:0]     mem_last,
    input  wire [31:0]     mem_diverted,
    input  wire            mem_intc8rom,    // the MMU shadow's INTC8ROM latch

    // The accelerated core (rtl/accel_seq.sv, docs/ACCELERATION.md):
    // ACCEL_CTRL's levels and its pulse out, the sequencer's status and
    // counters back.  A watching top ties the inputs to 0 and leaves the
    // outputs unconnected.
    output logic [1:0]     accel_mode,
    output logic           accel_swint_dis, // [28]: no internalized keyboard, dummies at $0000
    output logic           accel_game_dis,  // [27]: no internalized game port, dummies at $C000 only
    // The game port's samples, for GAME_STAT (rtl/game_port.sv).
    input  wire [2:0]      game_pb,
    input  wire            game_pb_ok,
    input  wire            game_pdl_ok,
    input  wire [11:0]     game_pdl0,
    input  wire [11:0]     game_pdl1,
    input  wire [11:0]     game_pdl2,
    input  wire [11:0]     game_pdl3,
    input  wire [7:0]      game_meas,
    output logic [15:0]    accel_target,
    output logic           accel_cnt_clr,   // pulses
    input  wire [31:0]     accel_stat,
    input  wire [31:0]     accel_fast,
    input  wire [31:0]     accel_bus,
    input  wire [31:0]     accel_cycles,
    input  wire [31:0]     accel_wait,
    input  wire [31:0]     accel_turbo,   // the front's one-clock ops (rtl/iline.sv)
    input  wire [31:0]     accel_dline,   // the data front's one-clock ops, reads and writes (rtl/dline.sv)
    input  wire            accel_cen_v,   // the census (rtl/fast_census.sv, below): a retired dispatcher op...
    input  wire [2:0]      accel_cen_sel, // ...and its bucket

    // The floating-bus simulator (rtl/fb_sim.sv, docs/FLOATING_BUS.md):
    // FB_CTRL's serve level and its clear pulse, FB_PEEK's address; the mode
    // bits, the counters and the peeked byte back.  A watching top ties the
    // inputs to 0 and leaves the outputs unconnected.
    output logic           fb_serve,
    output logic           fb_cnt_clr,      // pulses
    output logic [14:0]    fb_peek_addr,
    input  wire [6:0]      fb_mode,
    input  wire [31:0]     fb_compared,
    input  wire [31:0]     fb_mismatch,
    input  wire [31:0]     fb_last,
    input  wire [31:0]     fb_last2,
    input  wire [31:0]     fb_other,
    input  wire [7:0]      fb_peek_data,

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
    localparam [13:0] R_MENU_HOLD  = 'd11;  // 0x8000_002C, RW bits 7:0, W1 bit 8
    localparam [13:0] R_VBL_CTRL   = 'd12;  // 0x8000_0030, W1 bits 1:0, RW bit 2, RW bits 31:16
    localparam [13:0] R_VBL_STAT   = 'd13;  // 0x8000_0034, RO
    localparam [13:0] R_VBL_POS    = 'd14;  // 0x8000_0038, RO
    localparam [13:0] R_FD_SLOT    = 'd15;  // 0x8000_003C, RW in bits 2:0
    localparam [13:0] R_FD_DRIVE1  = 'd16;  // 0x8000_0040, RW bits 21:0, W1 bit 22
    localparam [13:0] R_FD_DRIVE2  = 'd17;  // 0x8000_0044, the same
    localparam [13:0] R_FD_STAT    = 'd18;  // 0x8000_0048, W1 bits 1:0
    localparam [13:0] R_MEM_CTRL   = 'd19;  // 0x8000_004C, RW bits 2:0, W1 bits 9:8
    localparam [13:0] R_MEM_STAT   = 'd20;  // 0x8000_0050, RO
    localparam [13:0] R_MEM_HITS   = 'd21;  // 0x8000_0054, RO
    localparam [13:0] R_MEM_MISSES = 'd22;  // 0x8000_0058, RO
    localparam [13:0] R_MEM_MISMATCH = 'd23; // 0x8000_005C, RO
    localparam [13:0] R_MEM_SERVED = 'd24;  // 0x8000_0060, RO
    localparam [13:0] R_MEM_LAST   = 'd25;  // 0x8000_0064, RO
    localparam [13:0] R_MEM_DIVERTED = 'd26; // 0x8000_0068, RO
    localparam [13:0] R_VIDHD_SLOT = 'd27;  // 0x8000_006C, RW in bits 2:0
    localparam [13:0] R_FB_CTRL    = 'd28;  // 0x8000_0070, RW bit 0, W1 bit 8
    localparam [13:0] R_FB_COMPARED = 'd29; // 0x8000_0074, RO
    localparam [13:0] R_FB_MISMATCH = 'd30; // 0x8000_0078, RO
    localparam [13:0] R_FB_LAST    = 'd31;  // 0x8000_007C, RO
    localparam [13:0] R_FB_LAST2   = 'd32;  // 0x8000_0080, RO
    localparam [13:0] R_FB_OTHER   = 'd33;  // 0x8000_0084, RO
    localparam [13:0] R_FB_PEEK    = 'd34;  // 0x8000_0088, RW bits 14:0
    localparam [13:0] R_ACCEL_CTRL = 'd35;  // 0x8000_008C, RW bits 1:0, 23:8, 24; W1 bit 31
    localparam [13:0] R_ACCEL_STAT = 'd36;  // 0x8000_0090, RO
    localparam [13:0] R_ACCEL_FAST = 'd37;  // 0x8000_0094, RO
    localparam [13:0] R_ACCEL_BUS  = 'd38;  // 0x8000_0098, RO
    localparam [13:0] R_ACCEL_CYCLES = 'd39; // 0x8000_009C, RO
    localparam [13:0] R_ACCEL_WAIT = 'd40;  // 0x8000_00A0, RO
    localparam [13:0] R_ACCEL_TURBO = 'd41; // 0x8000_00A4, RO
    localparam [13:0] R_ACCEL_DLINE = 'd42; // 0x8000_00A8, RO
    localparam [13:0] R_ACCEL_FAST_I = 'd43; // 0x8000_00AC, RO
    localparam [13:0] R_ACCEL_FAST_DRAM = 'd44; // 0x8000_00B0, RO
    localparam [13:0] R_ACCEL_FAST_DLC = 'd45; // 0x8000_00B4, RO
    localparam [13:0] R_ACCEL_FAST_DROM = 'd46; // 0x8000_00B8, RO
    localparam [13:0] R_ACCEL_FAST_DCX = 'd47; // 0x8000_00BC, RO
    localparam [13:0] R_ACCEL_FAST_WR = 'd48; // 0x8000_00C0, RO
    localparam [13:0] R_ACCEL_FAST_KBD = 'd49; // 0x8000_00C4, RO
    localparam [13:0] R_GAME_STAT      = 'd50; // 0x8000_00C8, RO
    localparam [13:0] R_GAME_STAT2     = 'd51; // 0x8000_00CC, RO
    localparam [13:0] R_MOUSE_SLOT     = 'd52; // 0x8000_00D0, RW in bits 2:0
    localparam [13:0] R_MOUSE_STAT     = 'd53; // 0x8000_00D4, RO

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
    //   [9]      runtime   RO   ...by the runtime menu's door, not the boot's
    //   [16]     release   W1   let a held core go, whichever door; reads as 0
    //   [31:24]  holds     RO   times the hold has engaged, either door, wrapping
    //
    // NOT reset-latched, unlike its neighbours, and deliberately: `arm` is the
    // standing intention "stop at the next boot", which is exactly what a
    // level that persists across resets expresses.  The hold itself engages
    // at a point the core defines - the first opcode fetch after reset - and
    // rtl/boot_hold.sv is where that is recognised; this register only carries
    // the host's wishes in and the state back out.  See docs/BOOT_MENU.md.
    // The same hold has a second door, MENU_HOLD below, and the same release
    // lets go of either; `runtime` says which is in progress, for a host
    // that attached to a hold it did not see engage.
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

    wire [31:0] boot_hold_rd = {boot_holds, 14'd0, hold_runtime, boot_held, 7'd0, boot_arm_q};

    // ---- MENU_HOLD ----------------------------------------------------------
    //
    //   [0]      enable    RW   watch for the hotkey on the program's reads
    //   [7:1]    hotkey    RW   the key that opens the menu; $1E (Ctrl-6 on a
    //                           IIe) at the card's reset
    //   [8]      trigger   W1   open the menu now, as the hotkey would; reads
    //                           as 0
    //   [31:24]  menus     RO   times the runtime door has opened, wrapping
    //
    // The runtime menu's door into the hold BOOT_HOLD arms for a boot (see
    // docs/RUNTIME_MENU.md).  The key is eaten on the card - the program
    // never sees it - and the hold engages at the program's next opcode
    // fetch; BOOT_HOLD's release lets it go, and the program continues from
    // that fetch.  `enable` is a level like `arm`, and the same reasoning
    // applies: the host's standing wish, and a RES' does not change it.  It
    // is the card's reset - the watchdog's included - that clears it, so a
    // host that has gone leaves no door open that nobody would answer.
    // `trigger` is the host's own knock: the control socket's `menu`, a
    // scripted test, a run with the Apple's keyboard locked.  Not gated by
    // CAN_MASTER: the pulse simply goes nowhere in a watching build.
    logic [7:0] menu_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            menu_en      <= 1'b0;
            menu_hotkey  <= 7'h1E;
            menu_trigger <= 1'b0;
            menu_count   <= 8'd0;
        end else begin
            if (boot_held && !boot_held_prev && hold_runtime) menu_count <= menu_count + 8'd1;
            menu_trigger <= wr_menu_hold && wb_dat_w[8];
            if (wr_menu_hold) begin
                menu_en     <= wb_dat_w[0];
                menu_hotkey <= wb_dat_w[7:1];
            end
        end
    end

    wire [31:0] menu_hold_rd = {menu_count, 16'd0, menu_hotkey, menu_en};

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

    // ---- FD_SLOT ------------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the floppy controller answers as;
    //                           0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [16]     rom       RO   the 256-byte boot ROM has been loaded (FD_ROM)
    //   [31:24]  seeks     RO   head movements the host was asked to fill,
    //                           wrapping
    //
    // HD_SLOT's contract, and the clash rule is now three-way: the floppy is
    // the newest of the three and yields to both the others, latching 0 when
    // either has the same slot asked for.  See docs/FLOPPY.md.
    logic [2:0] fd_slot_desired;
    logic [2:0] fd_slot_active_q;

    assign fd_slot_active = fd_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            fd_slot_desired  <= 3'd0;     // no floppy until asked for
            fd_slot_active_q <= 3'd0;
        end else begin
            if (res_assert || boot_relatch) begin
                fd_slot_active_q <= (CAN_MASTER && fd_slot_desired != mb_slot_desired &&
                                     fd_slot_desired != hd_slot_desired)
                                    ? fd_slot_desired : 3'd0;
            end
            if (wr_fd_slot) fd_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] fd_slot_rd = {fd_seeks, 7'd0, fd_rom_loaded,
                              5'd0, fd_slot_active_q, 5'd0, fd_slot_desired};

    // ---- VIDHD_SLOT ---------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the VidHD answers as; 0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [16]     rom       RO   the 256-byte slot ROM has been loaded
    //                           (VIDHD_ROM)
    //
    // FD_SLOT's contract, and the clash rule is four-way now: the VidHD is
    // the newest and yields to all three of the others, latching 0 when any
    // has the same slot asked for.  See docs/VIDHD.md.
    logic [2:0] vidhd_slot_desired;
    logic [2:0] vidhd_slot_active_q;

    assign vidhd_slot_active = vidhd_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            vidhd_slot_desired  <= 3'd0;   // no VidHD until asked for
            vidhd_slot_active_q <= 3'd0;
        end else begin
            if (res_assert || boot_relatch) begin
                vidhd_slot_active_q <= (CAN_MASTER &&
                                        vidhd_slot_desired != mb_slot_desired &&
                                        vidhd_slot_desired != hd_slot_desired &&
                                        vidhd_slot_desired != fd_slot_desired)
                                       ? vidhd_slot_desired : 3'd0;
            end
            if (wr_vidhd_slot) vidhd_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] vidhd_slot_rd = {8'd0, 7'd0, vidhd_rom_loaded,
                                 5'd0, vidhd_slot_active_q, 5'd0, vidhd_slot_desired};

    // ---- MOUSE_SLOT ---------------------------------------------------------
    //
    //   [2:0]    desired   RW   which slot the mouse card answers as; 0 = off
    //   [10:8]   active    RO   what was latched at the last RES' assertion
    //   [16]     rom       RO   the 2 KB firmware ROM has been loaded (MOUSE_ROM)
    //   [17]     irq       RO   the card's interrupt line is asserted
    //   [19:18]  buttons   RO   the buttons as the host holds them
    //   [23:20]  mode      RO   the mode byte SETMOUSE left
    //   [31:24]  moves     RO   MOUSE_MOVE messages applied, wrapping
    //
    // VIDHD_SLOT's contract, the clash rule five-way: the mouse is the newest
    // and yields to all four of the others.  See docs/MOUSE.md.
    logic [2:0] mouse_slot_desired;
    logic [2:0] mouse_slot_active_q;

    assign mouse_slot_active = mouse_slot_active_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            mouse_slot_desired  <= 3'd0;   // no mouse until asked for
            mouse_slot_active_q <= 3'd0;
        end else begin
            if (res_assert || boot_relatch) begin
                mouse_slot_active_q <= (CAN_MASTER &&
                                        mouse_slot_desired != mb_slot_desired &&
                                        mouse_slot_desired != hd_slot_desired &&
                                        mouse_slot_desired != fd_slot_desired &&
                                        mouse_slot_desired != vidhd_slot_desired)
                                       ? mouse_slot_desired : 3'd0;
            end
            if (wr_mouse_slot) mouse_slot_desired <= wb_dat_w[2:0];
        end
    end

    wire [31:0] mouse_slot_rd = {mouse_moves, mouse_mode, mouse_buttons, mouse_irq, mouse_rom_loaded,
                                 5'd0, mouse_slot_active_q, 5'd0, mouse_slot_desired};
    // MOUSE_STAT: {y[15:0], x[15:0]}, the position as the card holds it.
    wire [31:0] mouse_stat_rd = {mouse_y, mouse_x};

    // ---- FD_DRIVE1 / FD_DRIVE2 ----------------------------------------------
    //
    //   [0]      inserted  RW   a disk is in the drive
    //   [1]      wp        RW   ...and it is write-protected
    //   [15:3]   nibbles   RW   nibbles per track: 6384 for a sector image,
    //                           6656 for a .nib
    //   [21:16]  tracks    RW   tracks in the image, 35 or 40
    //   [22]     flush     W1   send the buffer to the host now if it was
    //                           written; reads as 0
    //   [23]     stale     RO   the buffer is not the track under the head yet
    //   [24]     dirty     RO   the buffer has been written to
    //   [31:25]  phase     RO   where the head is, in half tracks
    //
    // NOT reset-latched, on purpose: a disk goes in and out of a running
    // machine, and the runtime menu is where that happens.  An insertion is
    // the 0 -> 1 edge of `inserted`; to change the disk, eject first.  The
    // card's reset clears the drives, as it does the keyboard; a RES' does
    // not, as it does not on a real drive.
    always_ff @(posedge clk) begin
        if (rst) begin
            fd_inserted <= 2'd0;
            fd_wp       <= 2'd0;
            fd_nibbles  <= 26'd0;
            fd_tracks   <= 12'd0;
            fd_flush    <= 2'd0;
        end else begin
            fd_flush <= {wr_fd_drive2 && wb_dat_w[22], wr_fd_drive1 && wb_dat_w[22]};
            if (wr_fd_drive1) begin
                fd_inserted[0]    <= wb_dat_w[0];
                fd_wp[0]          <= wb_dat_w[1];
                fd_nibbles[12:0]  <= wb_dat_w[15:3];
                fd_tracks[5:0]    <= wb_dat_w[21:16];
            end
            if (wr_fd_drive2) begin
                fd_inserted[1]    <= wb_dat_w[0];
                fd_wp[1]          <= wb_dat_w[1];
                fd_nibbles[25:13] <= wb_dat_w[15:3];
                fd_tracks[11:6]   <= wb_dat_w[21:16];
            end
        end
    end

    wire [31:0] fd_drive1_rd = {fd_phase[6:0], fd_dirty[0], fd_stale[0], 1'b0,
                                fd_tracks[5:0], fd_nibbles[12:0], 1'b0, fd_wp[0], fd_inserted[0]};
    wire [31:0] fd_drive2_rd = {fd_phase[13:7], fd_dirty[1], fd_stale[1], 1'b0,
                                fd_tracks[11:6], fd_nibbles[25:13], 1'b0, fd_wp[1], fd_inserted[1]};

    // ---- FD_STAT ------------------------------------------------------------
    //
    //   [0]      motor     RO   the motor switch is on
    //   [1]      drive     RO   which drive is selected, 0 or 1
    //   [2]      q6        RO   the sequencer's load/shift switch
    //   [3]      q7        RO   ...and its read/write switch
    //   [15:8]   late      RO   fills that landed after the machine had read;
    //                           W1 bit 0 clears it
    //   [31:16]  fill_max  RO   the longest fill, head movement to seventh
    //                           chunk, in bus cycles; W1 bit 1 clears it
    //
    // The two numbers docs/FLOPPY.md's latency budget is checked against.
    always_ff @(posedge clk) begin
        if (rst) begin
            fd_late_clr <= 1'b0;
            fd_fill_clr <= 1'b0;
        end else begin
            fd_late_clr <= wr_fd_stat && wb_dat_w[0];
            fd_fill_clr <= wr_fd_stat && wb_dat_w[1];
        end
    end

    wire [31:0] fd_stat_rd = {fd_fill_max, fd_late, 4'd0, fd_ctl};

    // ---- MEM_CTRL -----------------------------------------------------------
    //
    //   [0]      serve      RW   all-or-nothing: answer every RAM, LC and ROM
    //                               read from the image, or none of them
    //   [8]      cnt_clr    W1   clear the counters
    //   [9]      inval      W1   invalidate every cache line
    //   [23:16]  bank       RO   the RamWorks bank register, as the shadow
    //                           holds it (rtl/apple_mmu.sv); 0 after RES'
    //   [27:24]  sets       RO   log2 of the cache's sets
    //
    // A level, card-reset only and never latched on RES': serving can be
    // flipped under a running machine, because with it clear the core takes
    // the bus's byte exactly as it did before the cache existed, and with it
    // set the cache is already tracking every write.  There is no partial
    // mode - mirroring some classes but not others has no use.  Nothing here
    // clears the image: it persists like the machine's RAM.
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_serve   <= 1'b0;
            mem_cnt_clr <= 1'b0;
            mem_inval   <= 1'b0;
        end else begin
            if (wr_mem_ctrl) mem_serve <= wb_dat_w[0];
            mem_cnt_clr <= wr_mem_ctrl && wb_dat_w[8];
            mem_inval   <= wr_mem_ctrl && wb_dat_w[9];
        end
    end

    wire [31:0] mem_ctrl_rd = {4'd0, 4'(MEM_SETS_LOG2), mem_rw_bank, 15'd0, mem_serve};

    // ---- MEM_STAT -----------------------------------------------------------
    //
    //   [11:0]   switches   RO   the MMU shadow: {prewrite, wren, lc_ramrd,
    //                           bank2, slotc3rom, intcxrom, hires, page2,
    //                           altzp, ramwrt, ramrd, store80}
    //   [12]     image_ready RO  the DDR3 is calibrated
    //   [13]     intc8rom   RO   the shadow's INTC8ROM latch (the CX class)
    //   [14]     invalidating RO
    //   [15]     rom_loaded RO   every MEM_ROM chunk has landed
    //   [23:16]  late_fills RO   fills that landed after their cycle: must be 0
    //   [31:24]  fifo_drops RO   requests the DDR3 client could not take: must be 0
    wire [31:0] mem_stat_rd = {mem_fifo_drops, mem_late_fills, mem_rom_loaded,
                               mem_invalidating, mem_intc8rom, mem_image_ready, mem_sw};

    // ---- ACCEL_CTRL ---------------------------------------------------------
    // (ACCEL_STAT, read straight through from the sequencer: [0] accelerating,
    // [1] held by the governor, [3] bus_owns, [7:4] state, [15:8] merge
    // overflows, [23:16] retries, [24] the reset sequence still on the bus.)
    //
    //   [1:0]    mode       RW   0 off - the core locked to the bus, the old
    //                           machine to the clock; 1 reads served on the
    //                           card, every write on the bus; 2 reads and
    //                           writes on the card
    //   [23:8]   target     RW   ops per bus cycle, 8.8 fixed point; 0 = as
    //                           fast as the card can
    //   [31]     cnt_clr    W1   clear the ACCEL_* counters
    //
    // Levels, like MEM_CTRL's: safe under a running machine, with the one
    // rule docs/ACCELERATION.md states - leaving mode 2 for a state where
    // the core reads the machine's RAM (mode 0, serving off) executes the
    // stale memory the machine holds; the host enforces it.
    always_ff @(posedge clk) begin
        if (rst) begin
            accel_mode    <= 2'd0;
            accel_target  <= 16'd0;
            accel_cnt_clr <= 1'b0;
            accel_swint_dis <= 1'b0;
            accel_game_dis  <= 1'b0;
        end else begin
            if (wr_accel_ctrl) begin
                accel_mode    <= wb_dat_w[1:0];
                accel_target  <= wb_dat_w[23:8];
                accel_swint_dis <= wb_dat_w[28];
                accel_game_dis  <= wb_dat_w[27];
            end
            accel_cnt_clr <= wr_accel_ctrl && wb_dat_w[31];
        end
    end

    //   [28]     swint_dis  RW   1 = the keyboard is not internalized and the
    //                           dummy parks at $0000: every $C00x read rides
    //                           the bus, as before the closed regime
    //   [27]     game_dis   RW   1 = the game port is not internalized: the
    //                           dummies stay at $C000 and every $C06x/$C07x
    //                           access rides the bus (rtl/game_port.sv)
    // The fast-op census counts here, beside the registers it is read through.
    wire [31:0] accel_fast_i, accel_fast_dram, accel_fast_dlc, accel_fast_drom,
                accel_fast_dcx, accel_fast_wr, accel_fast_kbd;
    fast_census u_census (
        .clk (clk), .rst (rst), .clr (accel_cnt_clr),
        .v (accel_cen_v), .sel (accel_cen_sel),
        .fast_i (accel_fast_i), .fast_dram (accel_fast_dram), .fast_dlc (accel_fast_dlc),
        .fast_drom (accel_fast_drom), .fast_dcx (accel_fast_dcx), .fast_wr (accel_fast_wr),
        .fast_kbd (accel_fast_kbd)
    );
    wire [31:0] accel_ctrl_rd = {3'd0, accel_swint_dis, accel_game_dis, 3'd0, accel_target, 6'd0, accel_mode};

    // ---- GAME_STAT ----------------------------------------------------------
    // The game port as the dummy loop last sampled it (rtl/game_port.sv):
    //   GAME_STAT   [2:0] the buttons' levels PB0..PB2; [3] pb_ok; [4] pdl_ok;
    //               [19:8] paddle 0's sample, bus cycles; [31:20] paddle 1's
    //   GAME_STAT2  [11:0] paddle 2's; [23:12] paddle 3's; [31:24] measurements, wrapping
    wire [31:0] game_stat_rd  = {game_pdl1, game_pdl0, 3'd0, game_pdl_ok, game_pb_ok, game_pb};
    wire [31:0] game_stat2_rd = {game_meas, game_pdl3, game_pdl2};

    // ---- FB_CTRL ------------------------------------------------------------
    //
    //   [0]      serve      RW   answer every floating-bus read the core makes
    //                            with the simulator's byte instead of the bus's
    //   [8]      cnt_clr    W1   clear the counters
    //   [16]     locked     RO   the scanner counter is set (VBL_CTRL's)
    //   [17]     text       RO   the video switches as the MMU shadow holds
    //   [18]     mixed      RO   them - what the prediction is built from
    //   [19]     hires      RO
    //   [20]     page2      RO   PAGE2 as displayed: PAGE2 && !80STORE
    //   [21]     col80      RO
    //   [22]     store80    RO
    //
    // A level, like MEM_CTRL's serve: safe under a running machine, because
    // the monitor was already comparing every floating read, and card-reset
    // only.  The simulator itself needs no enabling - the side copy follows
    // every write and the monitor runs from the lock on.  FB_COMPARED,
    // FB_MISMATCH, FB_LAST, FB_LAST2 and FB_OTHER read straight through from
    // rtl/fb_sim.sv; FB_PEEK's address is a level and its data the copy's
    // byte there.  docs/FLOATING_BUS.md.
    always_ff @(posedge clk) begin
        if (rst) begin
            fb_serve     <= 1'b0;
            fb_cnt_clr   <= 1'b0;
            fb_peek_addr <= 15'd0;
        end else begin
            if (wr_fb_ctrl) fb_serve <= wb_dat_w[0];
            fb_cnt_clr <= wr_fb_ctrl && wb_dat_w[8];
            if (wr_fb_peek) fb_peek_addr <= wb_dat_w[14:0];
        end
    end

    wire [31:0] fb_ctrl_rd = {9'd0, fb_mode, 15'd0, fb_serve};

    // ---- FB_PEEK ------------------------------------------------------------
    //
    //   [14:0]   addr       RW   [14] 0 = the text copy, [10:0] from $0400;
    //                            1 = the hi-res copy, [13:0] from $2000
    //   [23:16]  data       RO   the copy's byte there
    wire [31:0] fb_peek_rd = {8'd0, fb_peek_data, 1'b0, fb_peek_addr};

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

    // ---- VBL_CTRL / VBL_STAT / VBL_POS ------------------------------------
    //
    //   VBL_CTRL
    //   [0]      start      W1   run the detection: needs the boot hold; reads 0
    //   [1]      probe      W1   read probe_addr every cycle for one frame;
    //                            needs the lock and the boot hold; reads 0
    //   [2]      notify     RW   mark the frame origin in the capture stream
    //   [7:4]    state      RO   the detector's state (rtl/vbl_lock.sv)
    //   [8]      locked     RO   the counter is set
    //   [9]      pal        RO   312 lines, not 262
    //   [10]     busy       RO   a detection or a probe is running
    //   [15:12]  err        RO   the last run's result; 0 is success
    //   [31:16]  probe_addr RW   what a probe reads; $C019 (the //e's VBL')
    //                            at the card's reset
    //   VBL_STAT [15:0] mismatches in the last verify pass, [31:16] the slip
    //   VBL_POS  [14:0] the cycle within the frame, [23:16] frames, [31:24] locks
    //
    // The counter is the card's, not the machine's: RES' does not reset the
    // scanner and so does not reset this.  `notify` is the host asking to be
    // told - the silent-until-asked rule - and clears with the card, the
    // watchdog's included, like KBD_CTRL's.  See docs/VBL.md.
    always_ff @(posedge clk) begin
        if (rst) begin
            vbl_start      <= 1'b0;
            vbl_probe      <= 1'b0;
            vbl_notify     <= 1'b0;
            vbl_probe_addr <= 16'hC019;
        end else begin
            vbl_start <= wr_vbl_ctrl && wb_dat_w[0];
            vbl_probe <= wr_vbl_ctrl && wb_dat_w[1];
            if (wr_vbl_ctrl) begin
                vbl_notify     <= wb_dat_w[2];
                vbl_probe_addr <= wb_dat_w[31:16];
            end
        end
    end

    wire [31:0] vbl_ctrl_rd = {vbl_probe_addr, vbl_err, 1'b0, vbl_busy, vbl_pal, vbl_locked,
                               vbl_state, 1'b0, vbl_notify, 2'b00};

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
                        R_MENU_HOLD:  wb_dat_r <= menu_hold_rd;
                        R_VBL_CTRL:   wb_dat_r <= vbl_ctrl_rd;
                        R_VBL_STAT:   wb_dat_r <= vbl_stat;
                        R_VBL_POS:    wb_dat_r <= vbl_pos;
                        R_FD_SLOT:    wb_dat_r <= fd_slot_rd;
                        R_FD_DRIVE1:  wb_dat_r <= fd_drive1_rd;
                        R_FD_DRIVE2:  wb_dat_r <= fd_drive2_rd;
                        R_FD_STAT:    wb_dat_r <= fd_stat_rd;
                        R_MEM_CTRL:   wb_dat_r <= mem_ctrl_rd;
                        R_MEM_STAT:   wb_dat_r <= mem_stat_rd;
                        R_MEM_HITS:   wb_dat_r <= mem_hits;
                        R_MEM_MISSES: wb_dat_r <= mem_misses;
                        R_MEM_MISMATCH: wb_dat_r <= mem_mismatch;
                        R_MEM_SERVED: wb_dat_r <= mem_served;
                        R_MEM_LAST:   wb_dat_r <= mem_last;
                        R_MEM_DIVERTED: wb_dat_r <= mem_diverted;
                        R_VIDHD_SLOT: wb_dat_r <= vidhd_slot_rd;
                        R_MOUSE_SLOT: wb_dat_r <= mouse_slot_rd;
                        R_MOUSE_STAT: wb_dat_r <= mouse_stat_rd;
                        R_FB_CTRL:    wb_dat_r <= fb_ctrl_rd;
                        R_FB_COMPARED: wb_dat_r <= fb_compared;
                        R_FB_MISMATCH: wb_dat_r <= fb_mismatch;
                        R_FB_LAST:    wb_dat_r <= fb_last;
                        R_FB_LAST2:   wb_dat_r <= fb_last2;
                        R_FB_OTHER:   wb_dat_r <= fb_other;
                        R_FB_PEEK:    wb_dat_r <= fb_peek_rd;
                        R_ACCEL_CTRL: wb_dat_r <= accel_ctrl_rd;
                        R_ACCEL_STAT: wb_dat_r <= accel_stat;
                        R_ACCEL_FAST: wb_dat_r <= accel_fast;
                        R_ACCEL_BUS:  wb_dat_r <= accel_bus;
                        R_ACCEL_CYCLES: wb_dat_r <= accel_cycles;
                        R_ACCEL_WAIT: wb_dat_r <= accel_wait;
                        R_ACCEL_TURBO: wb_dat_r <= accel_turbo;
                        R_ACCEL_DLINE: wb_dat_r <= accel_dline;
                        R_ACCEL_FAST_I: wb_dat_r <= accel_fast_i;
                        R_ACCEL_FAST_DRAM: wb_dat_r <= accel_fast_dram;
                        R_ACCEL_FAST_DLC: wb_dat_r <= accel_fast_dlc;
                        R_ACCEL_FAST_DROM: wb_dat_r <= accel_fast_drom;
                        R_ACCEL_FAST_DCX: wb_dat_r <= accel_fast_dcx;
                        R_ACCEL_FAST_WR: wb_dat_r <= accel_fast_wr;
                        R_ACCEL_FAST_KBD: wb_dat_r <= accel_fast_kbd;
                        R_GAME_STAT:      wb_dat_r <= game_stat_rd;
                        R_GAME_STAT2:     wb_dat_r <= game_stat2_rd;
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
    wire wr_menu_hold  = access && !wb_ack && in_region && wb_we &&
                         (word == R_MENU_HOLD);
    wire wr_vbl_ctrl   = access && !wb_ack && in_region && wb_we &&
                         (word == R_VBL_CTRL);
    wire wr_fd_slot    = access && !wb_ack && in_region && wb_we &&
                         (word == R_FD_SLOT);
    wire wr_fd_drive1  = access && !wb_ack && in_region && wb_we &&
                         (word == R_FD_DRIVE1);
    wire wr_fd_drive2  = access && !wb_ack && in_region && wb_we &&
                         (word == R_FD_DRIVE2);
    wire wr_fd_stat    = access && !wb_ack && in_region && wb_we &&
                         (word == R_FD_STAT);
    wire wr_mem_ctrl   = access && !wb_ack && in_region && wb_we &&
                         (word == R_MEM_CTRL);
    wire wr_vidhd_slot = access && !wb_ack && in_region && wb_we &&
                         (word == R_VIDHD_SLOT);
    wire wr_mouse_slot = access && !wb_ack && in_region && wb_we &&
                         (word == R_MOUSE_SLOT);
    wire wr_fb_ctrl    = access && !wb_ack && in_region && wb_we &&
                         (word == R_FB_CTRL);
    wire wr_fb_peek    = access && !wb_ack && in_region && wb_we &&
                         (word == R_FB_PEEK);
    wire wr_accel_ctrl = access && !wb_ack && in_region && wb_we &&
                         (word == R_ACCEL_CTRL);

    // A boot-hold RELEASE re-latches MB_SLOT, HD_SLOT, FD_SLOT and VIDHD_SLOT above, so the menu's
    // choices reach the boot it releases into.  Same qualification as the
    // release pulse itself; CPU_SOURCE deliberately does NOT re-latch here -
    // switching the driving CPU mid-hold is the one changeover BOOT_MENU.md
    // keeps to a reset.  A release from the RUNTIME hold re-latches nothing:
    // the program it resumes has already decided about its slots, and a card
    // that moved under it would be the mid-run changeover this file exists
    // to prevent.
    wire boot_relatch  = wr_boot_hold && wb_dat_w[16] && !hold_runtime;

    // wb_adr[1:0] are byte lanes within a word and are deliberately not decoded.
    wire _unused_ok = &{1'b0, wb_dat_w[31:1], wb_sel, wb_adr[1:0], 1'b0};

endmodule
