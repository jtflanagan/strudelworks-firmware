/* SPDX-License-Identifier: GPL-2.0-or-later
   SPDX-FileCopyrightText: 2026 jtflanagan
   The PC harness's stand-in for librvgs's rvgs.h (tools/doom_music): only the sound
   constants opl_rv.c and mus_rv.c take, the OPL's rate from the build (-DOPL_RATE). */
#define RVGS_SND_CHUNK 256
#ifdef OPL_RATE
#define RVGS_SND_RATE  OPL_RATE
#endif
#define RVGS_SND_CRATE 26320
