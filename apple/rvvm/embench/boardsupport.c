/* SPDX-License-Identifier: GPL-2.0-or-later
 * SPDX-FileCopyrightText: 2026 jtflanagan
 *
 * Embench-IoT's board layer for the RISC-V VM: the triggers read the VM's
 * cycles ECALL (0x5000); main's return value is the guest's exit code, 0 when
 * verify_benchmark() says the result is right. */
#include <support.h>
#include "rvvm.h"

unsigned long long embench_start, embench_stop;

void initialise_board(void) {}
void __attribute__((noinline)) start_trigger(void) { embench_start = rvvm_cycles(); }
void __attribute__((noinline)) stop_trigger(void) { embench_stop = rvvm_cycles(); }
