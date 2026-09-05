# Keyboard injection: the keyboard the soft core reads, with the host on it

Status: **✅ on hardware, 2026-08-28.** Rebuilt that day with formal
semantics - the first cut (2026-08-26) was a latch bolted beside the real
keyboard with the host polling a strobe bit - and then run on a IIe from a
fresh copy of the 800K ProDOS master by `tools/kbd_test.sh` (strudelworks-
host): an injected Return continues the boot menu; `PRINT 6*7` typed at the
prompt prints 42, a 42-key program typed and run prints its output, every key
`taken` at 0.8 ms a key; a key pressed 50 ms into a machine-language delay
loop that never reads it is `flushed` by the loop's `BIT $C010`; a key
pressed into a BASIC `FOR` loop (Applesoft's Ctrl-C check reads it, nothing
strobes it) waits on the keyboard and is taken when the loop ends, and one
pressed into the same loop before a RES′ is dropped by the reset, the menu
engaging after it; BASIC typed under the lock arrives, keys pressed at the Apple under it
do not - `touched` went to 1 with one notice, the screen stayed as it was,
and the last of them (a Return) showed through the moment the lock lifted,
exactly as the lock section below says. `replaced` stayed at zero
throughout, as a one-in-flight host must keep it. The trace of the first run shows the injected Return as one
`$C000` read carrying `$8D`, one `$C010`, then `$C000` reading `$0D` - the
latch after its strobe. The buttons (below) are unchanged from the first cut
and ran on 2026-08-26.

Two things the bring-up taught, both in the test's comments: the //e's
`VIDWAIT` (`$FB78`) reads `$C000` on every carriage return it prints,
looking for Ctrl-S, so a key that lands within a millisecond or two of a
Return is *seen* by the firmware itself - which is why the flushed case
presses its key 50 ms in, and why "taken" is the honest count for a key
typed straight after a line; and the card answers one register request at a
time, so the host's reset pulse (and its button and lock writes) now wait
for the typist's press or drop to be acknowledged, where before the fast
typist could get the pulse dropped on the card.

The boot menu runs keys one way: the card reads `$C000` on the host's behalf
while the soft core is held, and every keypress reaches the host as a
captured bus event. This is the mirror. The host presses a key, and the next
`$C000` read the machine makes returns it, bit 7 set, exactly as the keyboard
encoder would have handed it over - so a script over SSH can continue the
boot menu, drive a launcher, or type at a prompt with nobody at the Apple.

- **The card carries the keyboard's own semantic** (`rtl/kbd_inject.sv`):
  the latch, the strobe, the rules for what clears it, the lock, and the
  counts that say what became of each press. It does not know what a
  string is.
- **The card says when a press is resolved** (`rtl/kbd_notice.sv`): the
  KBD_EVENT notice, two words, sent unasked once the host has asked for it.
- **The host carries the typist** (strudelworks-host `src/key_typist.cpp`):
  press a key, wait for the notice that resolves it, press the next - and
  the character conventions, the control socket the keys arrive on, and the
  commands beside them.

## A substitution, not a claim

The card's existing way of answering a read - `slot_rd_claim` in
`rtl/apple_bus_write.sv` - **drives the data pins**, which is safe only for
an address the motherboard maps to an empty slot: a range nothing else
drives, which is what makes the floating bus float. `$C000` is not one. The
IIe's IOU, or the ][+'s keyboard latch, drives the bus on every `$C00x`
read, and a card that drove it too would be fighting the machine.

So nothing here reaches the pins. The keyboard the core reads is a **din
substitution**: the byte the core latches at `T_DIN`, and the byte the
capture records for that cycle, are this module's answer, while the wire
still carries whatever the real keyboard says. That is the SYNC
substitution's precedent (`apple_bus_read`'s `sync_override`,
BUS_MASTER.md) - *logically exact, electrically absent*. And it is clean for
a reason worth stating: the driver samples `din` and the reader samples its
event on the **same fabric clock** - `T_DIN = 44` in `apple_bus_write` and
`DATA_TAP = 44` in `apple_bus_read`, both after phi0 rising - so one
combinational decision on the presented op lands identically in the CPU and
in the trace. The host's shadow of the machine sees what the machine saw.
`sim/kbd_inject_tb.sv` instantiates the real reader, pins and synchronisers
and all, and checks that agreement on every cycle, because it is the
property the mechanism rests on.

## The model: the IOU's latch and strobe, with two sources

The keyboard the machine reads is one byte - the last key, with the strobe
in bit 7 - and `kbd_inject` holds that byte for the soft core:

- **`last_read`** is the key the machine saw last, real or injected. A
  `$C00x` read that finds no strobe anywhere returns `{0, last_read}`, which
  is what the IOU returns after a `$C010`: the key is still in the latch,
  the strobe is gone. It survives a reset, as the IOU's latch does.
- **A real keypress** - the bus's byte with bit 7 set on a `$C00x` read - is
  handed to the core as it is and becomes `last_read`.
- **An injected key** is one latch (`key`) and one strobe - AppleWin's
  `keycode` and `keywaiting` (`source/Keyboard.cpp`; `KeybReadData` returns
  `keycode | (keywaiting ? 0x80 : 0)`). While its strobe is set every
  `$C00x` read returns `{1, key}`, and it becomes `last_read`. A press
  replaces whatever is in the latch, consumed or not: **the newest key
  wins**, as it does when two physical keys land before a `$C010`. There is
  no queue on the card. Typing a string at the machine's pace is the host's
  job, which is also how AppleWin's own injection works: its clipboard
  paste (`ClipboardReadOrPeek`) hands the program `0x80 | char` on `$C000`
  and advances one character per strobe clear.
- **Both ready at once, the injected key wins.** The real one is not lost:
  its strobe is the motherboard's, still set, and shows through the moment
  the injected one is cleared - unless the `$C010` that clears the injected
  key clears it too, which is simply what that access means.
- **Cleared** by any access to `$C010`, or a **write** to `$C011-$C01F`. That
  is the IIe's rule as AppleWin models it (`Memory.cpp`, `IORead_C01x` /
  `IOWrite_C01x`): a `$C011-$C01F` *read* returns a soft switch's state over
  the key and leaves the strobe alone. A ][+ clears on any `$C01x` read as
  well; the IIe rule is the safe one to share, because the failure the other
  way - a program polling `$C019` for VBL eating an injected key - is the
  one that loses keys.
- **Untouched**: writes to `$C00x` (soft switches; the data is the core's),
  and reads of `$C011-$C01F` (a switch in bit 7, the machine's own). Only
  `$C00x` reads change - and `$C010` reads under the lock, below.
- **Dropped** by a reset - a press meant for the program that was running is
  not owed to the one the reset starts - and by the register's `drop`.
- **A wire** with the native 6502 driving: there is no din of ours, and the
  capture must not lie.

**One real key is the card's**: the hotkey that opens the runtime menu
(RUNTIME_MENU.md). A `$C00x` read that would have returned it returns
`{0, last_read}` instead and tells the hold; the program never sees it, the
capture never records it, `last_read` does not learn it. Only the program's
own reads find it - the card reads nothing on its own account, because a
stolen cycle is the machine's timing spent (that document says why).

## Every press is resolved exactly once

A press leaves the latch by one of four routes, and the card counts three
of them:

| resolution | meaning |
|---|---|
| `taken` | a `$C010` cleared it after at least one `$C00x` read returned it: a program got the key |
| `flushed` | a `$C010` cleared it and nothing had read it: a program cleared the strobe without looking - the Esc pressed as a game launches, eaten by its first `$C010`. Gone, unseen |
| `replaced` | a second press landed on it first. Only a host that presses without waiting sees this |
| *dropped* | the register's `drop`, or a RES′. Not counted: it is `pressed − strobe − taken − flushed − replaced` |

`seen` is the flag underneath `taken` versus `flushed`: set when a `$C00x`
read returns the waiting key, cleared by the next press.

**The host presses one key and waits for its resolution before the next.**
That is the whole discipline, and it is what makes the accounting simple:
there is never more than one press in flight, so there is never more than
one resolution owed, and "resolved" is a number - `pressed − strobe`. The
reply to a press shows the register *before* the write (`reg_bridge` samples
the readback on the same edge the write lands), so the press's own number
is the `pressed` it reads back plus one, and the press is done when
`pressed − strobe` reaches it. The typist never has to match a key to an
event; it counts.

## The notice

`rtl/kbd_notice.sv` sends **KBD_EVENT** (type `0x1C`) on every resolution,
and when the lock sees a real key - once the host has asked for it by
setting KBD_CTRL's `notify`, which is the silent-until-asked rule
(PROTOCOL.md) applied: a host that has not asked is not listening, and a
notice queued for it would be the first word its successor reads.

```
header   {free, 0x1C, len=1}   free[0] strobe  [1] seen  [2] touched  [3] lock
                               free[15:8] the key of the press resolved last
payload  {replaced, flushed, taken, pressed}
```

**A level, not a pulse** - the CPU_HOLD notice's rule, kept for the same
reason. The words carry the state as it is when each goes out, not as it was
when the change fired, and one pending flag is the whole queue: a change
while a notice waits is folded into it, and a change while it is being sent
raises another after it. So the host always ends with the truth, and the
card never holds more than one notice - which is all it needs to, because a
host that presses one key at a time gets one resolution at a time. A host
that presses without waiting can see two presses resolved by one notice;
the counts still add up, and the attribution is forced: press *k* cannot be
taken after *k+1* landed, and *k+1* cannot be replaced without a *k+2* the
host never sent. `sim/reg_map_tb.sv` case 19 has the notice raised inside
another message, the counts moving again while it waits, and one two-word
notice coming out after the boundary with the newer counts.

It goes through the message bus as its own master, below the CPU_HOLD
notice and above the application messages and the capture, so it never
lands inside another message and is never starved by the stream.

## The lock

`KBD_CTRL.lock` suppresses the machine's own keyboard: a real keypress
neither reaches the core nor updates `last_read`, and the any-key-down flag
a IIe returns in bit 7 of a `$C010` read is masked too (`{0, last_read}` -
the same latch, the same clock). The core sees the injected keys and nothing
else, which is what a scripted test wants: a stray key at the Apple cannot
steer it. And because the capture records the substituted byte, **the trace
goes blind to the physical keyboard too** - the CPU and the trace agree, as
they must. `touched` is the witness: a real key arriving while locked sets
it, sticky until the lock is next engaged, and raises the notice once. A
test reads it at the end as "somebody touched the machine during the run."

What the lock cannot do is clear the motherboard's own strobe - that takes a
bus access, which is the machine's. A real key pressed while locked stays
pending there. In practice it is cleared by the next `$C010` the machine
makes, which every injected key it takes provides; only a real key pressed
after the last injected one was taken lingers, and shows through when the
lock lifts. The testbench has both: the pending `R` swept away by the
`$C010` that took the injected `L`, and a later `S` reading through the
moment the lock clears.

The lock, like the buttons, **survives a RES′** - a test that resets the
machine wants it kept - and is cleared by the card's reset, the watchdog's
included, so a host that has gone leaves no keyboard locked behind it. It is
the keyboard only: a test that wants the buttons quiet too sets them `up`.
While locked, the boot menu cannot be driven from the Apple - its reader is
substituted like everything else - and the host's `key return` or `continue`
is the way through it. Nor is the runtime menu's hotkey looked for under
the lock: it is a `touched` like any other key, and the host's `menu` knocks
through the register instead.

## The registers

**`KBD_INJECT`, `0x8000_001C`** in `rtl/wb_regfile.sv`:

```
[6:0]    key      W    the key, taken when press is set
[7]      press    W1   put key on the keyboard, strobe set, replacing an
                       unconsumed one; reads as 0
[8]      drop     W1   clear the strobe without a $C010; reads as 0
[16]     strobe   RO   a key is waiting that the machine has not taken
[17]     seen     RO   ...and a $C00x read has returned it
[31:24]  pressed  RO   presses, wrapping
```

**`KBD_CTRL`, `0x8000_0028`**:

```
[0]      lock     RW   suppress the machine's own keyboard
[1]      notify   RW   send KBD_EVENT on every resolution
[7]      touched  RO   a real key arrived while locked; cleared when lock is
                       next set
[15:8]   taken    RO   resolved: read, then strobed
[23:16]  flushed  RO   resolved: strobed unread
[31:24]  replaced RO   resolved: pressed over
```

Two registers, not one, because a KBD_INJECT write *is* a press: sticky
levels in the same word would make every press carry the lock's state, or
cost a set/clear pair each. Registers, not message types: a `REG_WRITE`
needs no change to `ft601_msg_rx`'s whitelist, and every write is answered.
**The reply to a press is its acknowledgement, not its state** - it shows
the register before the press, which is exactly what the typist wants (see
above). Neither is reset-latched: a key is for the program running now.

## The host

The card holds one key, so a string is typed the way a person types it. The
**ingest thread**, which alone owns the transport, runs `KeyTypist`
(`src/key_typist.cpp`) beside the boot menu's apply: press (`REG_WRITE
key|press`), take the ack's `pressed` as the press's number, then wait for
the KBD_EVENT whose `pressed − strobe` reaches it, and press the next in
that same step. No polling: the first cut read the register every half a
millisecond while typing, two thousand round trips a second for nothing.
The register path is one request outstanding at a time, so the typist
defers entirely while the menu's apply or a reset pulse is in flight.

**A key waits for the machine, however long.** A press nobody has taken is
a key on the keyboard - the latch holds it as it holds a person's - and the
program that is not looking now (DOS reading a track, a BASIC loop) will
look later; the typist waits for the notice that says so, and no timer
decides otherwise. Only the machine resolves a key: taken, flushed by its
own `BIT $C010`, or dropped by a RES′. So `LOAD X` and `RUN` typed back to
back both arrive, whatever the load took (the first cut dropped a key after
a second, and lost the R of `RUN` behind a two-second load - 2026-08-28);
what bounds a script is its own `wait MS`. The two timers left are not about
the machine: a register ack that never comes is a link fault and that key is
abandoned; and gateware that sends no notice at all - `notify` refused in
the KBD_CTRL readback, or older than this - gives the host no way to see a
resolution, so for such a card only a key nobody takes is **dropped, then
the next pressed** - never pressed over, which would be two in flight - and
a drop it never acknowledges is abandoned after a short grace.

At start the host sets `notify`; at exit it drops any key in flight and
clears KBD_CTRL, so the next host - or the machine's own user - inherits
nothing. **The Apple's "A" is not ASCII's**: `src/apple_keys.cpp` holds the
character rules, taken from AppleWin's `KeybQueueKeypress` (`CR LF` is one
Return, bit-7 bytes pass verbatim, a IIe uppercases under caps lock, a ][+
refuses `` ` { | } ~ `` and Delete), unchanged from the first cut.

**The keys arrive on the control socket** (`src/control_socket.cpp`,
`--control PATH`, default `swhost.sock`) - the one command channel into a
running `swhost`. Text lines in, one reply line per command: `type TEXT`,
`key NAME`, `reset`, `continue`, `status`, `screen`, `pause MS`, and now:

- `lock on|off` - the lock above. `status` reports `lock=` and `touched=`.
- `wait [MS]` - block until the typist is idle: everything typed has been
  resolved. `ok idle pressed=N taken=T flushed=F replaced=R dropped=D` on
  success, `err timeout ...` after MS (default 5000). This is the sync
  point a script needs between `type` and `screen`.

`tools/swctl` is the client, and `tools/pi.sh type|key|reset|continue|ctl`
runs it on the Pi from here.

## The buttons

Open-Apple, Closed-Apple and the third button are the game port's PB0-PB2,
read at `$C061`-`$C063` in bit 7 - and a button is a **level**: the machine
reads it now, with no latch and no strobe, so there is nothing on the card
the machine could consume. `rtl/pb_inject.sv` holds one word per button
from the host - **hardware, up, or down** - and on a read of that button's
address merges it into bit 7 over the bus's own low seven bits. Hardware is
a wire: the joystick's buttons and the Apple keys are what they always were.
Down then hardware is a press; the host makes the edges.

The same substitution as the keyboard's, on the same tap, and for the same
reason: the motherboard drives `$C06x`. `sub_data` is a function of
`data_sync` here, which both consumers sample on that tap, so the CPU and
the trace still agree; a write that lands mid-cycle decides only whether
*this* read sees the old level or the new, and no read is ever torn.

**Not dropped by a reset**, unlike the key, and deliberately: the //e's
reset handler reads Open-Apple *after* RES′ releases - Open-Apple-Ctrl-Reset
is a cold boot, both Apples the self-test - so an override a reset cleared
could never do the one thing Open-Apple is for. That is exactly how the
boot menu cold-boots (BOOT_MENU.md): the host holds Open-Apple down across
the release and the machine takes its own cold path.

**In the closed regime** the buttons are sampled by the driver's dummy
cycles and a program's `$C061`-`$C063` reads are served on the card from
the sample, the override applied there too (CXXX.md "The game port");
the substitution below is the bus's case, and a dummy is a sample it
never lands on.

**`BUTTONS`, `0x8000_0020`** in `rtl/wb_regfile.sv`:

```
[1:0]    pb0   RW   Open-Apple:    00 hardware, 01 up, 10 down
[3:2]    pb1   RW   Closed-Apple:  the same
[5:4]    pb2   RW   PB2 ($C063):   the same
[18:16]  hw    RO   bit 7 as the bus said it, the last read of each
```

`hw` is the diagnostic: the physical level the host is overriding. `up`
earns its place beside `down` - it masks a joystick with a stuck button.
On the host: `button open|closed|pb2 down|up|hardware` on the control
socket, `status` reports all three, and everything goes back to hardware
at exit.

## What is deliberately not there

- **A queue on the card.** The keyboard has none; a queue would be a second
  semantic for programs to meet, and the host paces better than the card
  could.
- **A queue of notices.** One press in flight means one resolution owed;
  the notice is a level, so a second change folds into the one pending. A
  FIFO here would be buffering for a host that breaks the one-in-flight
  rule, and the answer to that is not more buffering on the card.
- **A press notice.** The ack of the write is that.
- **Polling on the host.** The notice replaced it.
- **Auto-repeat.** A held key is a stream of presses from the host, if it
  wants one.
- **An auto-release for a button.** A button is a level; a tap is two
  writes from the host, which is the only party that knows how long.
- **Clearing the motherboard's strobe under the lock.** It takes a bus
  access; the machine's next `$C010` does it, and `touched` records that
  there was something to clear.
- **The paddles and `PTRIG`.** Timers, a different problem.
- **A scancode keymap.** `apple_keys` starts from characters; a USB keyboard
  on the Pi will have to produce characters first, then feed the same rules.
- **A ][+ strobe rule on the card.** See above: the IIe rule loses nothing
  on a ][+ except the rare case of a program clearing the strobe by reading
  `$C011-$C01F`, which then leaves an injected key visible at `$C000` until
  its next `$C010`.

## Running it

`tools/kbd_test.sh [--touch]` in strudelworks-host, with the Pi up, the card
loaded and the Apple on: it restores `po_kbd.po` from `po_master.po`, boots
it through the menu and provokes every resolution, checking the counts
after each step against `status`. `--touch` adds the one step that needs a
person: a key pressed at the Apple under the lock, which must not reach the
prompt and must set `touched`. Total Replay is not a good vehicle for this -
it reads and flushes the keyboard on its own schedule - which is why the
test types BASIC at a ProDOS prompt and reads the screen back.

## The keyboard in the dummies (2026-09-02)

Under acceleration in the closed regime the driver's parked dummy cycles
read `$C000` instead of `$0000`, every one a sample of the real IOU into a
latch here, and the program's own `$C00x` reads are served from that latch
on the card instead of riding a bus cycle - through the same decision a bus
read gets, so injection, the lock and the hotkey behave exactly as before;
only where the real sample comes from changed.  Details, the lever and the
measurements: docs/ACCELERATION.md, "The keyboard in the dummies".
