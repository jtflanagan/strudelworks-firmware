# Sound on the card: the AYs and the speaker as gateware, samples to the host

Status: **ON HARDWARE 2026-09-06**, COMMITTED (fw 96d227b / host b082bb6,
SRAM).  Bit at WNS +0.008 / WHS +0.062 (2026-09-06 12:46, SRAM), the
first DSP48 in the design, LUTs 43 %.  `sim/run_audio_vl.sh` PASS (the NCO,
the speaker's box average, a 996 Hz tone at 50 periods in core time / 199
with the core at 4x / 50 in real time, the framing, the drops); the
Verilator battery unchanged; host `card_audio_test` 29/29, `mb_test` 47/47
on the Pi.  On the Pt: AUDIO_CTRL answers, 1378 messages a second with no
gaps and no card drops; the servo settles to a 1335-frame mean against the
1323 target within ±20 ppm in a minute; Ctrl-G's beep and an AY tone set
by POKEs (peak 10924, the bench's number) read on the status line
(`sndspk=`, `sndmb=`).  **The point of it:** at the AppleSoft prompt with
the governor off (63 M cycles/s) `sw-decode` went from ~90 % of its core
to 25 %, and the sound path is gone from its profile.  The host half is
strudelworks-host `src/card_audio.cpp`.

## Why

The host synthesised every sound: four AY-3-8913s (`src/mb_audio.cpp`), two
SSI-263s (`src/ssi263.cpp`) and the speaker (`src/apple_audio.cpp`), all
stepped per Apple cycle inside the decode thread.  That is ~15 CPU cycles an
Apple cycle - cheap - but the accelerated core runs ~72 M cycles a second at
an idle AppleSoft prompt (keyboard polls served on the card), and perf on the
Pi put 62 % of `sw-decode` in the sound path, the core near 100 % and the
fan up.  Moving that work to another core keeps the heat; moving it to the
card removes it.  The user's decision, 2026-09-06: the AYs and the speaker
become gateware, the card decimates to the play rate and exports only that
rate, the SSI-263 stays on the host as a sample player, and the host absorbs
delivery-rate drift without audible drops.  The Pt has the room (LUTs 41 %,
BRAM 46 %, 0 of 240 DSP48s used before this).

## The shape

```
 core ops ──┐                       ┌──────────── mockingboard ────────────┐
 bus cycles ┴─ $C03x ─► speaker FF  │ VIA0 ─ ay_pair ─ YM2149 x2 ─┐        │
                          │         │ VIA1 ─ ay_pair ─ YM2149 x2 ─┤ ay_out │
 phi0 (real time) ───┐    │         │            ▲ ay_ce           │ [3:0]  │
 core tick ──────────┴► ay clock    └────────────┴──────────────────┼───────┘
                                                                    ▼
                 audio_sampler: NCO 44.1 kHz ─ box-average accumulators ─ DSP48 ─ 3 words/sample
                                                                    ▼
                 audio_tx: FIFO ─ 32 samples/message ─ msg_master port 7 ─ tx_ring ─ FT601
                                                                    ▼
      host: ingest thread ─ jitter buffer ─ audio thread: pan/level, speaker filter,
            SSI-263 (real time), chime ─ ALSA;  depth error ─► AUDIO_RATE trim (ppm)
```

## The chips

`rtl/ay_pair.sv` already held two YM2149 cores (a2fpga's) per VIA, `CE`
tied low and the CHANNEL outputs open, so that the register file answered
a PSG READ and the generators pruned away.  Now they run:

- **`ay_ce`**, the PSG clock enable, comes from `mockingboard` and is one of
  two things by AUDIO_CTRL bit 1: the **core's clock** (`via_slow_clock`,
  one per op the core completes - the VIA timers' time base, machine time)
  or **real time** (`bus_tick`, one per phi0 cycle of the real bus, whatever
  the core is doing).  In Phasor native mode the AY clock is doubled, as the
  host doubled it (`div_` 4 instead of 8): a second CE pulse follows each
  tick.  Under turbo the core-time CE saturates at one per clock; the sound
  of a 70x machine is not music in either time base, see "Decimation".
- **`SEL=0`** (the /8 prescaler, so a tone flips every 8 * period clocks,
  the datasheet's 16 * period a full wave) and **`MODE=1`**, the AY half of
  the core's volume table - **replaced with AppleWin's levels** (`kDac` in
  `src/mb_audio.cpp`, 0..10000 scaled to 0..255), the ones the user tuned
  by ear on the host.  A chip's three channels are summed on the card
  (`ay_out[c]`, 10 bits); panning is the host's, per chip, as AppleWin does.
- The chips still answer reads exactly as before; nothing on the bus side
  moved.

## The speaker

There was no speaker flip-flop on the card: $C03x accesses were
internalized (`rtl/apple_mmu.sv`, `qi_c03x`), always kept in the stream,
and the host toggled its own bit.  `rtl/speaker.sv` is the flip-flop: it
toggles on every $C030-$C03F access that carried an op - a bus cycle that
was not a dummy (`real_valid && !real_dummy`) or a fast op
(`fast_valid`), the same words the host toggled on - and is held low while
RES' is asserted (the host's `in_reset_` rule).  The stream words are
unchanged: the host still counts toggles and re-arms nothing.

## Decimation: the box average in real time

The sample clock is a 32-bit NCO on the 100 MHz clock, increment
AUDIO_RATE (default 1 894 081 = 44 100 Hz), so the window is 2267.57 clocks
and the host can trim it by parts per million.  Over each window
`rtl/audio_sampler.sv` accumulates **every clock**: the speaker bit (a
12-bit count of clocks high) and each chip's `ay_out` (10 bits into 22).
At the window's end the five accumulators are latched, cleared, and walked
one a clock through a single pipelined multiplier - the first DSP48 in the
design - by a constant that maps full scale (speaker high all window; a
chip's three channels at 15 all window) to 32767: `sample = acc * K >> 22`,
K = 118 378 for the speaker (its count shifted up 9 bits first) and 79 225
for a chip.  The window's length
varies by one clock with the NCO's phase; the 0.04 % of amplitude that
costs is below anything audible, so K is a constant and there is no divide.

That is the whole decimation, and it is the physically honest one: at 1x
it is exactly the host's speaker (a box average of the high cycles over
23.14 Apple cycles, then the host's triangle and DC blocker) and a
band-limited AY; under acceleration the chips run in whatever time base
AUDIO_CTRL chose and the window samples what a cone or an amplifier would
see of it - in core time an octave up at 2x and fading to a DC that the
host's blocker removes at high ratios (an Apple whose crystal runs faster),
in real time the right pitch at the VIA timers' tempo (an accelerator
card).  Neither is the shelved "time compression" (`shelved/AUDIO_PACING.md`
on the host) nor the old ring's chunk-dropping; the user picks the time
base by ear and it is a register bit.

## Oversampling, on the host's request (2026-09-07)

AUDIO_RATE is the host's to set, and the accumulators have the headroom for
a window a quarter as long (a speaker count of 567, the 12-bit counter; a
chip's 434 k in 22 bits), so the host asks for 4 x 44.1 kHz and scales the
quarter-size samples back up (the constants map the nominal window to full
scale).  The reason: a speaker PWM player's carrier sits in the tens of
kHz, and one 44.1 kHz box folds it under 22 kHz as a whine - Nox
Archaist's splash, heard on the day the speaker moved to the card.  The
host's `CardAudio` runs a 127-tap windowed-sinc low-pass (14 kHz, -74 dB
stopband) across the five channels and takes every fourth sample into the
mixer (`audio_oversample`, `audio_lowpass` in swhost.conf; 1 is the plain
box).  Nothing here changed: four times the messages, 5.5 k a second.

## The message

`rtl/audio_tx.sv` queues three words a sample:

```
  w0  {ay0[15:0], spk[15:0]}
  w1  {ay2[15:0], ay1[15:0]}
  w2  {seq[15:0], ay3[15:0]}     seq: a running sample count, mod 2^16
```

and sends **AUDIO_FRAMES `0x2C`** = `{free = {drops[7:0], n[7:0]}, 0x2C,
len = 3n}` with n = 32 samples (96 words, 0.73 ms of sound) whenever 32
are queued.  The FIFO holds 128 samples; a sample that arrives with no
room is dropped whole and `drops` counts it (mod 256, also in AUDIO_STAT).
The sequence number lets the host see a gap and insert that many frames of
silence instead of losing time.  The source is message-bus port 7, above
the capture: it is continuous but bounded by the wall clock (1378
messages a second of 97 words), which is the arbiter's rule for anything
above the capture (`rtl/msg_arb.sv`).  A burst delays a reply by at most
97 cycles.

## Registers

| address | name | |
|---|---|---|
| `0x8000_00F0` | AUDIO_CTRL | `[0]` stream on, `[1]` AY clock: 0 core time, 1 real time; readback adds `[16]` stream active |
| `0x8000_00F4` | AUDIO_RATE | the NCO increment, `rate_hz * 2^32 / 100e6`; default 1 894 081 |
| `0x8000_00F8` | AUDIO_STAT | `[15:0]` samples sent (mod 2^16), `[23:16]` drops, `[24]` FIFO full now |

The stream is off until the host turns it on (the silent-until-asked
rule), and off again at the host's shutdown.

## The host

`src/card_audio.cpp` is the consumer.  The ingest thread's AUDIO_FRAMES
callback unpacks each message into a jitter buffer (an SPSC ring of
`{spk, ay[4]}` samples, 16 K deep); a sequence gap becomes that many
silent samples.  The audio thread (`AudioOut`) pulls frames from a
`FrameSource` instead of the old finished-frame ring; `CardAudio` is that
source: per frame it pans the chips (Mockingboard: chip 0 left, chip 1
right; Phasor: 0 and 2 left, 1 and 3 right), scales, puts the speaker
through the triangle + Q8 DC blocker the host always had, adds the two
SSI-263s and the chime, clamps and packs.  The SSI-263 steps at real time
now: one `tick()` every two frames (22050 Hz at 44.1 k), its register
writes handed from the decode thread through a small SPSC queue - the
stream still carries every `$Cn2x/$Cn4x/$Cn6x` write, so the card needs no
speech protocol.  The decode thread does no other sound work: `AppleAudio`
keeps the stats and the Mockingboard's decode (mode register, SSI writes)
and nothing per cycle.

**Rate.**  The card's oscillator and the Pi's audio clock differ by tens of
ppm; left alone the jitter buffer drains or fills in minutes.  The audio
thread waits for the buffer to reach its target (30 ms) before it starts
consuming, then keeps a running mean of the depth; once a second the
ingest thread turns the error into a trim of AUDIO_RATE (a proportional
term with a ppm ceiling per step) and writes the register.  Correction at
the source is sample-exact: no resampler, no dropped or doubled frame in
steady state.  A depth beyond 4x the target (the link stalled, the card
restarted) is cut back to the target, and an empty buffer plays silence
until it refills to the target - the old `AudioOut` rules, kept.

## Verifying it

- `sim/run_audio_vl.sh` (Verilator, seconds; ~13 M clocks) - a `mockingboard` with real VIA
  writes setting a tone, the sampler, the packer: the tone's period in the
  samples against the datasheet, the box average of a speaker square wave,
  the NCO's rate, the message framing and the sequence numbers, a full
  FIFO's drops.  In `sim/suite.sh quick` and `sim/lint.sh`.
- Host: `tests/card_audio_test.cpp` (the unpack, the gap fill, the mixer's
  pan and filters, the servo's sign and ceiling); `tests/mb_test.cpp` keeps
  the decode and mode tests and loses the host-side tone tests.
- On hardware: the AppleSoft prompt at 70x (perf on `sw-decode` before and
  after, the Pi's temperature line), Ctrl-G's beep, mb-audit's tone tests
  by ear, Total Replay's music, the AUDIO_STAT counters and the servo's ppm
  on the banner.
