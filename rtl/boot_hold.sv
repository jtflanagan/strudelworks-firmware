`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// boot_hold - stop the soft core at an instruction boundary, and read the
// keyboard for the host until it says to go.
//
// The menus live on the host: it draws on the HDMI panel and decides what to
// do.  What it needs from the card is small and exact - hold the machine at a
// boundary where every register is defined, let the host see keys, and let go
// on command.  There are two doors into that hold, and one way out:
//
//   * THE BOOT DOOR (docs/BOOT_MENU.md): armed, the hold engages at the
//     first opcode fetch after a reset, before the machine has run a byte.
//   * THE RUNTIME DOOR (docs/RUNTIME_MENU.md): a key the machine never sees
//     (rtl/kbd_inject.sv eats it and pulses hotkey_hit), or a write to the
//     MENU_HOLD register, and the hold engages at the NEXT opcode fetch of a
//     running program.  Released, the program continues from that fetch as
//     if nothing had happened - the one thing it lost is the key.
//
// WHERE THE HOLD IS.  An opcode fetch: the core's live outputs show sync=1,
// and the cycle that would present that fetch is taken instead.  It is an
// instruction boundary with every register defined, the same boundary the
// core takes interrupts on.  The boot door recognises the post-reset fetch as
// "the core's outputs are a SYNC and no SYNC has been put on the bus since
// the core was reset" - `first_fetch` below - which is exactly that fetch and
// nothing else, because a core that has fetched once has had a SYNC
// presented.  The runtime door takes any SYNC, once asked.
//
// HOW THE CORE IS PAUSED.  It is not: the core only changes state on cyc_en
// (see cpu65c02.sv), so apple_bus_write simply withholds cyc_en for every
// cycle it presents on this module's behalf, and the core sits at the fetch
// with its outputs unchanged.  On release the next cycle presents that fetch,
// the opcode comes out of the machine's own memory, and the program proceeds
// as if nothing had happened.  The bus timing never changes; only the source
// of the presented op does.
//
// WHAT GOES ON THE BUS WHILE HELD.  Reads of the keyboard, so the host sees
// every keypress in the capture stream it already receives.  NOT a blind
// alternation of $C000 and $C010: the strobe is set asynchronously by the
// keyboard encoder, so a key landing in the microsecond between a $C000 read
// and the $C010 that follows it has its strobe cleared before any $C000 read
// sees it - the ASCII is still there, bit 7 is not, and the host cannot tell
// it from an old key.  With one $C010 for every $C000 that window is one
// cycle in two, a coin flip per key.
//
// So this does what the ROM's own RDKEY does: read $C000 continuously, and
// read $C010 once, only after a $C000 read that came back with bit 7 set.
// No key can be lost, and each press produces exactly ONE $C000 event with
// bit 7 set - the strobe is cleared a microsecond later and only a new press
// sets it again.  The host's key decoder is therefore one line.
//
// THE $C010 READ'S OWN DATA IS IGNORED.  On a IIe reading $C010 returns the
// any-key-down flag in bit 7, which is not a keypress; the generator returns
// to IDLE unconditionally after it.
//
// THE KEY THAT OPENED THE RUNTIME DOOR IS CLEARED FIRST.  kbd_inject handed
// the program a blank in its place, so its strobe is still set in the IOU
// when the hold engages a few cycles later.  Left there, the hold's first
// $C000 read would return it as the menu's first key - and the host, which
// treats that key as "leave the menu", would leave at once.  So a hold the
// hotkey opened presents ONE $C010 before its first $C000 read.  A hold the
// register opened has no such key and starts reading straight away.
//
// NO SCAN.  A program that never reads the keyboard can never hand
// kbd_inject the hotkey, and the first cut of this module read $C000 on its
// own account every millisecond to find it anyway - one bus cycle stolen at
// a fetch.  That is gone, by decision: a stolen cycle drifts the core
// against the video beam, and a real floppy's critical loops are counted to
// the cycle.  Until there is something that understands the Apple's
// realtime obligations, the machine's timing is not to be touched for a
// menu, and a program that does not read the keyboard cannot be paused by
// the key - the register's knock (or a reset) is what is left.
//
// RELEASE takes effect at the end of a data phase, never in the middle of one,
// and only on a read that was ISSUED AFTER the request arrived: after such a
// $C000 read that showed no key, or after the $C010 that cleared the one it
// showed.  The qualification matters.  The request lands at an arbitrary
// point in a cycle whose $C000 was sampled microseconds earlier, and a key
// pressed in between would have been invisible to that read and left with
// its strobe set for the program - the testbench presses one exactly there.
// A read issued after the request cannot miss it.  A key pressed after the
// request belongs to the program, as it would on any machine.
//
// THE HARD DISK COMES FIRST.  rtl/hd_card.sv moves blocks by override cycles
// of its own, and a runtime hold can engage with a transfer outstanding, or
// one can arrive while the machine is held (the host answers a command that
// was in flight).  The driver takes the disk's op over this module's when
// both offer one (master_top's mux), and this module acts only on cycles
// that were its own - recognised the way hd_card recognises its own: the
// presented op is an override read of the address this module was offering.
// A cycle the disk took neither reads a key nor releases the hold; the core
// does not move either way, and the two simply interleave.
//
// RESET WHILE HELD.  RES' bounces - it is a switch with nothing debouncing it
// (see docs/BUS_MASTER.md) - and the core is reset by the level, so a bounce
// after the hold engaged resets the core, drops this hold with it, and the
// boot hold re-engages at the next vector fetch.  The host sees held go 1,
// 0, 1 and must treat every 1 as "start the menu again".  Nothing here
// debounces; that would be guessing at a timing the motherboard does not
// promise.  A reset is also how the runtime menu's "reset" item leaves: the
// host pulses RES' with the machine held, the hold drops, and the boot hold
// - if armed - takes over at the vector.
//////////////////////////////////////////////////////////////////////////////////
module boot_hold (
    input  wire        clk,
    // The CORE's reset: the card's reset OR RES' asserted.  Everything here
    // follows the core, so this is the only reset it has.
    input  wire        cpu_rst,

    // 1 while the card owns the bus.  A hold is meaningless otherwise - and
    // dangerous: it would wait forever for a fetch the native CPU makes.
    input  wire        master_active,

    // From the BOOT_HOLD register.  `arm` is a level: hold at the next
    // post-reset fetch.  `release_req` is a pulse: let the held core go -
    // whichever door it came in by.
    //
    // A COLD BOOT is not this module's business any more.  It once DMA-wrote
    // the //e's power-up bytes before releasing; now the host holds
    // Open-Apple down across the release through rtl/pb_inject.sv, and the
    // machine's own reset handler takes its own cold path.
    input  wire        arm,
    input  wire        release_req,

    // From the MENU_HOLD register: the host's own way in (`menu_trigger`,
    // a pulse).  And from kbd_inject: the hotkey was read and eaten
    // (`hotkey_hit`, a pulse).  Whether the hotkey is looked for at all is
    // kbd_inject's business (MENU_HOLD's enable goes there).
    input  wire        menu_trigger,
    input  wire        hotkey_hit,

    // The core's live SYNC.
    input  wire        cpu_sync,
    // A SYNC the instruction front retired without a stream event
    // (rtl/iline.sv): it still counts for seen_sync, or an arm given after
    // it would take the boot door at a random fetch.  Tie low without the
    // front.
    input  wire        turbo_sync,

    // From apple_bus_write.  op_present pulses once a cycle's op has been
    // latched, op_commit once its data phase is done; op_sync and op_ovr say
    // what that op was - the core's own SYNC, or an override - and op_addr /
    // op_rw which override, since the disk presents them too.  din is the
    // byte the bus returned, valid at op_commit.
    input  wire        op_present,
    input  wire        op_commit,
    input  wire        op_sync,
    input  wire        op_ovr,
    input  wire [15:0] op_addr,
    input  wire        op_rw,
    input  wire [7:0]  din,

    // To apple_bus_write: present ovr_addr instead of the core's op, and
    // withhold the core's cyc_en for that cycle.  Always a read.
    output wire        ovr_en,
    output wire [15:0] ovr_addr,

    // The core is held, and which door it came in by.  Read back through
    // the registers, and every edge of `held` is a CPU_HOLD notice to the
    // host, carrying `runtime` with it.  `runtime` changes on the same edge
    // as `held`, so the notice never says one without the other.
    output wire        held,
    output wire        runtime
);

    localparam [15:0] KBD      = 16'hC000;   // keyboard data, bit 7 = strobe
    localparam [15:0] KBDSTRB  = 16'hC010;   // any access clears the strobe

    // ---- has the core fetched since reset? ----------------------------------
    // Set when a SYNC of the core's own is presented on the bus.  An override
    // op is never a SYNC, so holding does not set it - which is what keeps
    // first_fetch true for as long as the boot hold lasts.
    logic seen_sync;

    // The core's live outputs are the post-reset opcode fetch.
    wire first_fetch = cpu_sync && !seen_sync;

    // ---- the hold -----------------------------------------------------------
    typedef enum logic [1:0] {
        S_WAIT,     // the core has not reached its vector since reset
        S_HELD,     // the core is at a fetch and we own the bus cycles
        S_DONE      // the boot door is shut until the next reset; the runtime
                    // door opens and closes from here
    } state_t;

    state_t st;
    logic   runtime_q;      // the hold in progress came in by the runtime door

    // The runtime door's knock, waiting for the next fetch; and whether the
    // hotkey knocked (its strobe must be cleared) or the register did.
    logic menu_pend;
    logic pend_hot;

    // The decisions the driver samples at its present tap.  `engage` is what
    // takes the very first cycle, before the state has caught up: the driver
    // presents this module's op instead of the fetch, and the state moves on
    // op_present - from what the driver says it did, not from what this
    // module hoped it would do.  The boot door has priority at the one fetch
    // where both could apply.
    wire engage_boot = (st == S_WAIT) && arm && master_active && first_fetch;
    wire engage_rt   = (st != S_HELD) && menu_pend && master_active && cpu_sync && !engage_boot;
    wire engage      = engage_boot || engage_rt;

    assign ovr_en  = engage || (st == S_HELD);
    assign held    = (st == S_HELD);
    assign runtime = runtime_q;

    // ---- the keyboard reader ------------------------------------------------
    // IDLE presents $C000; a byte back with bit 7 set moves to CLEAR, which
    // presents $C010 once and returns.  A hold the hotkey opened begins in
    // CLEAR, for the reason in the header.
    logic clearing;
    assign ovr_addr = (clearing || (engage_rt && pend_hot)) ? KBDSTRB : KBD;

    // The presented op is ours: an override read of what we were offering.
    // The disk's DMA is the other override, and never a read of $C00x.
    wire mine = op_present && op_ovr && op_rw && (op_addr == ovr_addr);
    // ...and the op in flight, for the data phase.
    logic cur_mine;

    // A release the host asked for, waiting for a safe cycle end - and the
    // record, made at op_present, that the cycle in flight was issued with
    // the request already known.  Only such a cycle may end the hold.
    logic release_pend;
    logic rel_seen;

    always_ff @(posedge clk) begin
        if (cpu_rst) begin
            seen_sync    <= 1'b0;
            st           <= S_WAIT;
            runtime_q    <= 1'b0;
            menu_pend    <= 1'b0;
            pend_hot     <= 1'b0;
            clearing     <= 1'b0;
            release_pend <= 1'b0;
            rel_seen     <= 1'b0;
            cur_mine     <= 1'b0;
        end else begin
            if ((op_present && op_sync) || turbo_sync) seen_sync <= 1'b1;
            if (op_present)            cur_mine  <= mine;
            if (mine)                  rel_seen  <= release_pend;

            // A knock on the runtime door is remembered until a fetch comes;
            // a knock while held is nothing - the hotkey cannot arrive then
            // (kbd_inject passes it through while held), and a register
            // trigger on a held machine has nothing to do.
            if ((menu_trigger || hotkey_hit) && st != S_HELD) begin
                menu_pend <= 1'b1;
                pend_hot  <= hotkey_hit;
            end

            // Only a HELD core can be released.  A release with nothing held
            // is dropped, so a host that sends one late - after a bounce
            // re-reset the core, say - does not queue a release for a hold
            // it has not yet been told about.
            if (release_req && st == S_HELD) release_pend <= 1'b1;

            case (st)
                S_WAIT, S_DONE: begin
                    // The driver presented one of ours: the hold is on.
                    // Qualified on `engage` and on the op being ours,
                    // because this module is not the only source of
                    // overrides - rtl/hd_card.sv's DMA is the other, and an
                    // op that was the disk's must not be taken for the hold
                    // engaging.  `engage` is still true at op_present:
                    // nothing it depends on has moved yet.
                    if (mine && engage) begin
                        st        <= S_HELD;
                        runtime_q <= engage_rt;
                        menu_pend <= 1'b0;
                        // The hotkey's strobe: the op just presented is the
                        // $C010 that clears it; return to reading after it.
                        clearing  <= engage_rt && pend_hot;
                    end
                end

                S_HELD: begin
                    if (op_commit && cur_mine) begin
                        if (!clearing) begin
                            if (din[7]) begin
                                clearing <= 1'b1;        // a key: clear its strobe next
                            end else if (release_pend && rel_seen) begin
                                st           <= S_DONE;  // safe to go
                                runtime_q    <= 1'b0;
                                release_pend <= 1'b0;
                            end
                        end else begin
                            clearing <= 1'b0;            // strobe cleared; back to reading
                            if (release_pend && rel_seen) begin
                                st           <= S_DONE;
                                runtime_q    <= 1'b0;
                                release_pend <= 1'b0;
                            end
                        end
                    end
                end

                default: ;
            endcase
        end
    end

endmodule
