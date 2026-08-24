`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// boot_hold - stop the soft core at its reset vector, and read the keyboard
// for the host until it says to go.
//
// The boot menu lives on the host: it draws on the HDMI panel and decides what
// to do.  What it needs from the card is small and exact - hold the machine at
// the one moment where nothing has happened yet, let the host see keys, and
// let go on command.  See docs/BOOT_MENU.md.
//
// WHERE THE HOLD IS.  The core comes out of reset running its seven-cycle
// sequence - two dummy reads, three stack reads, $FFFC, $FFFD - and the cycle
// after the vector's high byte is the opcode fetch AT the vector: the core's
// live outputs show sync=1 and addr=vector, and it has not consumed a single
// byte of the program.  That is the hold point: an instruction boundary with
// every register defined, the same boundary the core takes interrupts on.  It
// is recognised as "the core's outputs are a SYNC and no SYNC has been put on
// the bus since the core was reset" - `first_fetch` below - which is exactly
// the post-reset fetch and nothing else, because a core that has fetched once
// has had a SYNC presented.
//
// HOW THE CORE IS PAUSED.  It is not: the core only changes state on cyc_en
// (see cpu65c02.sv), so apple_bus_write simply withholds cyc_en for every
// cycle it presents on this module's behalf, and the core sits at the fetch
// with its outputs unchanged.  On release the next cycle presents that fetch,
// the opcode comes out of the machine's own ROM, and the boot proceeds as if
// nothing had happened.  The bus timing never changes; only the source of the
// presented op does.
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
// RELEASE takes effect at the end of a data phase, never in the middle of one,
// and only on a read that was ISSUED AFTER the request arrived: after such a
// $C000 read that showed no key, or after the $C010 that cleared the one it
// showed.  The qualification matters.  The request lands at an arbitrary
// point in a cycle whose $C000 was sampled microseconds earlier, and a key
// pressed in between would have been invisible to that read and left with
// its strobe set for the ROM - the testbench presses one exactly there.  A
// read issued after the request cannot miss it.  A key pressed after the
// request belongs to the boot, as it would on any machine.
//
// RESET WHILE HELD.  RES' bounces - it is a switch with nothing debouncing it
// (see docs/BUS_MASTER.md) - and the core is reset by the level, so a bounce
// after the hold engaged resets the core, drops this hold with it, and the
// hold re-engages at the next vector fetch.  The host sees held go 1, 0, 1
// and must treat every 1 as "start the menu again".  Nothing here debounces;
// that would be guessing at a timing the motherboard does not promise.
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
    // post-reset fetch.  `release_req` is a pulse: let the held core go.
    input  wire        arm,
    input  wire        release_req,

    // The core's live SYNC.
    input  wire        cpu_sync,

    // From apple_bus_write.  op_present pulses once a cycle's op has been
    // latched, op_commit once its data phase is done; op_sync and op_ovr say
    // what that op was - the core's own SYNC, or one of ours.  din is the
    // byte the bus returned, valid at op_commit.
    input  wire        op_present,
    input  wire        op_commit,
    input  wire        op_sync,
    input  wire        op_ovr,
    input  wire [7:0]  din,

    // To apple_bus_write: present ovr_addr as a READ instead of the core's op,
    // and withhold the core's cyc_en for that cycle.
    output wire        ovr_en,
    output wire [15:0] ovr_addr,

    // The core is held.  Read back through the register, and every edge is a
    // CPU_HOLD notice to the host.
    output wire        held
);

    localparam [15:0] KBD      = 16'hC000;   // keyboard data, bit 7 = strobe
    localparam [15:0] KBDSTRB  = 16'hC010;   // any access clears the strobe

    // ---- has the core fetched since reset? ----------------------------------
    // Set when a SYNC of the core's own is presented on the bus.  An override
    // op is never a SYNC, so holding does not set it - which is what keeps
    // first_fetch true for as long as the hold lasts.
    logic seen_sync;

    // The core's live outputs are the post-reset opcode fetch.
    wire first_fetch = cpu_sync && !seen_sync;

    // ---- the hold -----------------------------------------------------------
    typedef enum logic [1:0] {
        S_WAIT,     // armed or not, the core has not reached its vector
        S_HELD,     // the core is at its vector and we own the bus cycles
        S_DONE      // released; nothing more until the next reset
    } state_t;

    state_t st;

    // The decision the driver samples at its present tap.  `engage` is what
    // takes the very first cycle, before the state has caught up: the driver
    // presents this module's op instead of the fetch, and the state moves on
    // op_present - from what the driver says it did, not from what this
    // module hoped it would do.
    wire engage = (st == S_WAIT) && arm && master_active && first_fetch;

    assign ovr_en = engage || (st == S_HELD);
    assign held   = (st == S_HELD);

    // ---- the keyboard reader ------------------------------------------------
    // IDLE presents $C000; a byte back with bit 7 set moves to CLEAR, which
    // presents $C010 once and returns.
    logic clearing;
    assign ovr_addr = clearing ? KBDSTRB : KBD;

    // A release the host asked for, waiting for a safe cycle end - and the
    // record, made at op_present, that the cycle in flight was issued with
    // the request already known.  Only such a cycle may end the hold.
    logic release_pend;
    logic rel_seen;

    always_ff @(posedge clk) begin
        if (cpu_rst) begin
            seen_sync    <= 1'b0;
            st           <= S_WAIT;
            clearing     <= 1'b0;
            release_pend <= 1'b0;
            rel_seen     <= 1'b0;
        end else begin
            if (op_present && op_sync) seen_sync <= 1'b1;
            if (op_present)            rel_seen  <= release_pend;

            // Only a HELD core can be released.  A release with nothing held
            // is dropped, so a host that sends one late - after a bounce
            // re-reset the core, say - does not queue a release for a hold
            // it has not yet been told about.
            if (release_req && st == S_HELD) release_pend <= 1'b1;

            case (st)
                S_WAIT: begin
                    // The driver presented one of ours: the hold is on.
                    if (op_present && op_ovr) st <= S_HELD;
                end

                S_HELD: begin
                    if (op_commit) begin
                        if (!clearing) begin
                            if (din[7]) begin
                                clearing <= 1'b1;        // a key: clear its strobe next
                            end else if (release_pend && rel_seen) begin
                                st           <= S_DONE;  // no key waiting: safe to go
                                release_pend <= 1'b0;
                            end
                        end else begin
                            clearing <= 1'b0;            // strobe cleared; back to reading
                            if (release_pend && rel_seen) begin
                                st           <= S_DONE;
                                release_pend <= 1'b0;
                            end
                        end
                    end
                end

                default: ;                               // S_DONE: until the next reset
            endcase
        end
    end

endmodule
