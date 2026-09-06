---
name: fw-build
description: The card's Vivado build with the gate around it - lint and microcode pre-flight, a tagged log, WNS/WHS/failing endpoints and the depth-tail diff read from the result. A timing miss is never green.
disable-model-invocation: true
argument-hint: TAG [--board pt_v2|au_v2]
arguments: [tag, board]
allowed-tools: Bash(build/run_build.sh:*), Bash(cd /home/flana/repos/strudelworks-firmware && build/wns.sh:*), Bash(tail:*), Bash(grep:*), Bash(ls:*), Read, Monitor
---

# fw-build: the card build, gated

Repo: /home/flana/repos/strudelworks-firmware (every command starts with `cd` there).
Tag: `$tag`  Board: `$board` (empty = pt_v2)

Where the tree stands:
!`cd /home/flana/repos/strudelworks-firmware && echo "HEAD $(git rev-parse --short HEAD) on $(git branch --show-current), $(git status --short | wc -l) dirty file(s)"`
The previous build:
!`cd /home/flana/repos/strudelworks-firmware && build/wns.sh 2>/dev/null | head -2 || echo "no previous results"`

## Steps

1. Refuse an empty `$tag`, or one whose `build/master_build_$tag.log` already exists
   (`ls build/master_build_*.log`). Then say, in two sentences, what is being built and
   what result is expected (the explain-before-test rule).
2. Run it in the background - Vivado takes 8-10 minutes, past the Bash timeout:
   `cd /home/flana/repos/strudelworks-firmware && build/run_build.sh $tag --board ${board:-pt_v2}`
   with `run_in_background: true`. It does the pre-flight first (`gen_microcode.py --check`,
   `sim/lint.sh`, about a second) and stops there on a failure - report that verbatim.
3. Follow the log with Monitor for `setup WNS|ERROR:|Cannot clear the Vivado work directory|BUILD FAILED`:
   - `Cannot clear the Vivado work directory` = the Vivado GUI holds the project lock:
     tell the user to `File > Close Project` in Vivado, stop.
   - `ERROR: ... constraint(s) matched no port` / `synthesis failed` / `implementation failed`:
     quote the 20 lines around it from the log, stop.
4. When it exits, the last lines are `build/wns.sh`'s verdict. Report in this fixed shape:
   - `TIMING MET|MISS  wns=  whs=  fail=N/total`
   - `depth: max L (was L), tail >= 14: N (was N), NEW DEEP TAIL: none | the endpoints`
   - `bit: build/results/master_top.bit (mtime), stamp`
   - `lint: OK`
5. **A timing miss is reported as `TIMING MISS - not green, do not load`.** The .bit was still
   written (build.tcl only warns); its existence never upgrades the verdict.
   A new deep tail is not a failure but is named, per docs/DLINE.md "no new deep tail".
6. Suggest the docs `Status:` text (`WNS +0.034, bitstream YYYY-MM-DD HH:MM`); do not edit
   docs unless asked. Loading is `/strudelworks-firmware:fw-load`.

Needs nothing but this machine: not the Pi, not the Apple, not the FT2232H cable.
