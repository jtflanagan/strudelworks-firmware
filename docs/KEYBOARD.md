# Keyboard injection: a key from the host, on the keyboard the soft core reads

Status: **✅ works on hardware.** Master build of 2026-08-26 21:15, on a
IIe: an injected Return continued the boot menu into Total Replay, `type
CHOP` walked its browser to "Lamb Chops!", and the trace shows each key as
one `$C000` read carrying `$8D`/`$C1` and one `$C010` - the hold's own at
+1, the launcher's RDKEY at +43. An Esc pressed as a game launched was
flushed by that game's first `$C010`, unseen, as a physical one would be.
The buttons (below) ran the same day: at the Applesoft prompt `PEEK(49249)`
read 32, then 162 with Open-Apple held down from the host, then 32 again,
and the boot menu's cold boot now rides on them - the trace shows the
reset handler's one `$C061` read, 2.0 ms after the release, with bit 7 set.

The boot menu runs keys one way: the card reads `$C000` on the host's behalf
while the soft core is held, and every keypress reaches the host as a
captured bus event. This is the mirror. The host presses a key, and the next
`$C000` read the machine makes returns it, bit 7 set, exactly as the keyboard
encoder would have handed it over - so a script over SSH can continue the
boot menu, drive a launcher, or type at a prompt with nobody at the Apple.

- **The card carries the keyboard's own semantic** (`rtl/kbd_inject.sv`):
  one key latch, one strobe, and the rules for what clears it. It does not
  know what a string is.
- **The host carries the typist** (strudelworks-host `src/key_typist.cpp`):
  press a key, watch the strobe clear, press the next - and the character
  conventions, the control socket the keys arrive on, and the commands
  beside them.

## A substitution, not a claim

The card's existing way of answering a read - `slot_rd_claim` in
`rtl/apple_bus_write.sv` - **drives the data pins**, which is safe only for
an address the motherboard maps to an empty slot: a range nothing else
drives, which is what makes the floating bus float. `$C000` is not one. The
IIe's IOU, or the ][+'s keyboard latch, drives the bus on every `$C00x`
read, and a card that drove it too would be fighting the machine.

So nothing here reaches the pins. An injected key is a **din substitution**:
the byte the core latches at `T_DIN`, and the byte the capture records for
that cycle, become the host's key, while the wire still carries whatever the
real keyboard says. That is the SYNC substitution's precedent
(`apple_bus_read`'s `sync_override`, BUS_MASTER.md) - *logically exact,
electrically absent*. And it is clean for a reason worth stating: the
driver samples `din` and the reader samples its event on the **same fabric
clock** - `T_DIN = 44` in `apple_bus_write` and `DATA_TAP = 44` in
`apple_bus_read`, both after phi0 rising - so one combinational decision on
the presented op lands identically in the CPU and in the trace. The host's
shadow of the machine sees what the machine saw. `sim/kbd_inject_tb.sv`
instantiates the real reader, pins and synchronisers and all, and checks
that agreement on every cycle, because it is the property the mechanism
rests on.

## The machine's own semantic, and nothing more

One key latch (`key[6:0]`) and one strobe - AppleWin's `keycode` and
`keywaiting` (`source/Keyboard.cpp`; `KeybReadData` returns
`keycode | (keywaiting ? 0x80 : 0)`). A press replaces whatever is in the
latch and sets the strobe, consumed or not: **the newest key wins**, as it
does when two physical keys land before a `$C010`. There is no queue on the
card. Typing a string at the machine's pace is the host's job, which is also
how AppleWin's own injection works: its clipboard paste
(`ClipboardReadOrPeek`) hands the program `0x80 | char` on `$C000` and
advances one character per strobe clear.

- **Substituted**: a read of `$C000-$C00F` while the strobe is set returns
  `{1, key}` - on every such read until the strobe is cleared, a real key's
  lifetime exactly. With the strobe clear nothing is substituted, and the
  machine's own keyboard is what it reads. The core's own reads and the boot
  hold's override reads alike: an injected `$0D` continues the menu.
- **Cleared** by any access to `$C010`, or a **write** to `$C011-$C01F`. That
  is the IIe's rule as AppleWin models it (`Memory.cpp`, `IORead_C01x` /
  `IOWrite_C01x`): a `$C011-$C01F` *read* returns a soft switch's state over
  the key and leaves the strobe alone. A ][+ clears on any `$C01x` read as
  well; the IIe rule is the safe one to share, because the failure the other
  way - a program polling `$C019` for VBL eating an injected key - is the
  one that loses keys. That same access clears the machine's own strobe too,
  which is simply what the access means.
- **Untouched**: writes to `$C00x` (soft switches; the data is the core's),
  and the data of `$C010-$C01F` reads (any-key-down and the switches, the
  machine's own). Only `$C00x` reads change.
- **Dropped** by a reset - a press meant for the program that was running is
  not owed to the one the reset starts - and by the register's `drop`.
- **A wire** with the native 6502 driving: there is no din of ours, and the
  capture must not lie.

## The register

**`KBD_INJECT`, `0x8000_001C`** in `rtl/wb_regfile.sv`:

```
[6:0]    key     W    the key, taken when press is set
[7]      press   W1   put key on the keyboard, strobe set, replacing an
                      unconsumed one; reads as 0
[8]      drop    W1   clear the strobe without a $C010; reads as 0
[16]     strobe  RO   a key is waiting that the machine has not taken
[31:24]  taken   RO   strobes the machine consumed, wrapping
```

A register, not a message type: a `REG_WRITE` needs no change to
`ft601_msg_rx`'s whitelist (where an unknown type drops the link), and every
write is answered. **The reply to a press is its acknowledgement, not its
state**: `reg_bridge` samples the readback on the same edge the write lands,
so the reply shows the strobe as it was before the press (true of
`BOOT_HOLD.arm` too). The state is in the read after it, which is what the
host's typist polls. Not reset-latched, unlike its neighbours: a key is for
the program running now.

## The host

The card holds one key, so a string is typed the way a person types it. The
**ingest thread**, which alone owns the transport, runs `KeyTypist`
(`src/key_typist.cpp`) beside the boot menu's apply: press
(`REG_WRITE key|press`), wait for the ack, then `REG_READ` every half a
millisecond until `strobe` reads clear, and press the next in that same
step. The register path is one request outstanding at a time, so it defers
entirely while the menu's apply or a reset pulse is in flight. A key the
machine has not taken after a second is counted and given up on - the next
is pressed over it, which is the card's semantic and what a person would do
with a program that is not listening. At exit, `drop`.

**The Apple's "A" is not ASCII's.** The keyboard hands the program `$C1`,
bit 7 being the strobe; the card's `{1, key[6:0]}` is that byte, and what
the host must get right is the seven bits underneath and which ones a
given machine could produce at all. `src/apple_keys.cpp` holds those rules,
taken from AppleWin's `KeybQueueKeypress`: `CR LF` and a lone `LF` are one
Return; a byte with bit 7 set is already the machine's and passes verbatim
(`\x8a` is a real down arrow); a IIe types everything in `$00-$7F` with
`a-z` uppercased under caps lock (on by default, as AppleWin's is); a ][+ has
no lowercase and refuses `` ` { | } ~ `` and Delete. Refusals are counted and
reported.

**The keys arrive on the control socket** (`src/control_socket.cpp`, `--control
PATH`, default `swhost.sock` in the working directory) - the one command
channel into a running `swhost`, of which typing is the first customer. The
two signals that used to reboot the machine and continue the boot menu are
commands on it now, because a signal carries no argument and everything the
host might be told to forward to the card wants one. Text lines in, one
reply line per command: `type TEXT` (C escapes, `\xHH` for the Apple's own
bytes), `key NAME`, `reset`, `continue`, `status`; replies `ok`, `ok WORDS`
or `err REASON`. `tools/swctl` is the client, and `tools/pi.sh type|key|
reset|continue|ctl` runs it on the Pi from here.

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
boot menu cold-boots now (BOOT_MENU.md): the host holds Open-Apple down
across the release and the machine takes its own cold path, where the hold
once DMA-wrote the power-up bytes.

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
- **A `$C010` any-key-down for an injected key.** Bit 7 of a `$C010` read
  is the machine's own. Games that poll it see the physical keyboard.
- **Auto-repeat.** A held key is a stream of presses from the host, if it
  wants one.
- **An auto-release for a button.** A button is a level; a tap is two
  writes from the host, which is the only party that knows how long.
- **The paddles and `PTRIG`.** Timers, a different problem.
- **A scancode keymap.** `apple_keys` starts from characters; a USB keyboard
  on the Pi will have to produce characters first, then feed the same rules.
- **A ][+ strobe rule on the card.** See above: the IIe rule loses nothing
  on a ][+ except the rare case of a program clearing the strobe by reading
  `$C011-$C01F`, which then leaves an injected key visible at `$C000` until
  its next `$C010`.

## Verifying it

```
sim/run_kbd_inject_tb.sh     # card: the real core, driver, READER and hold; every property below
sim/run_reg_map_tb.sh        # card: the register's pulses and readback (case 16)
sim/run_boot_hold_tb.sh      # card: the hold, unchanged with the inputs idle
sim/lint.sh
```

`kbd_inject_tb` puts the real reader in the loop, pins and synchronisers and
all, and checks: idle, it is a wire and a real key is seen once; a pressed
key is what the next `$C00x` read returns and every read after it until a
`$C010`, then never again; a `$C010` write clears, a `$C015` write clears, a
`$C019` read does not and returns the machine's byte; a `$C000` write does
nothing; `din` and the captured event agree on every cycle; a second press
replaces an unconsumed first and `taken` counts one; a press over a waiting
real key replaces it and the one `$C010` clears both strobes; keys pressed
one per consumption go through RDKEY-shaped code in order, at eight offsets
across the bus cycle, never torn; held, an injected Return is one `$C000`
event carrying `$8D` then one `$C010`; a RES′ drops it, `drop` drops it, and
with `master_active` low nothing is substituted.

`kbd_inject_tb` also carries the buttons: on hardware, `$C061-$C063` read
the game port's levels and the substitution never asserts; PB0 down reads
`$AA` and PB1 up reads `$2A` over a pressed hardware button, each over the
bus's own low bits, with `$C060`/`$C064` untouched and the `hw` readback
still telling the truth; Open-Apple held down is still down after a RES′;
`master_active` low substitutes nothing.

In strudelworks-host, `kbd_test`: the character rules against AppleWin's,
the escapes and the named keys, the control commands and their replies, the
register's layout, the typist pressing one key per consumption and giving up
on one nobody takes, the mock card taking a press and showing the machine
consume it in the captured stream, and the socket end to end.

## Bring-up, when it happens

```
swhost --real --cpu soft --boot-menu --hdv TotalReplay.hdv
tools/pi.sh key return        # continues the menu: TR boots
tools/pi.sh type A            # the browser jumps to A
tools/pi.sh reset             # what pkill -USR1 did
```

Then `tools/pi.sh trace out.swbt --reset` one run and look for the `$C000` read carrying `$8D` followed
by the `$C010`; `tools/pi.sh ctl status` (and the exit line) reports pressed
against taken, so a gap between them is a key the machine never consumed.
Then a ProDOS boot and `type 'CATALOG\n'` at the prompt, which exercises
RDKEY's real shape and the `$C1`-not-`$41` convention end to end.
