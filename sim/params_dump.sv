`timescale 1ps / 1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
// Instantiate ddr3_controller with the strudelworks configuration purely so its
// self-describing $display block prints the derived timing for OUR parameters.
// Ports are left dangling; nothing is clocked.
module params_dump;
    ddr3_controller #(
        .CONTROLLER_CLK_PERIOD (10_000),
        .DDR3_CLK_PERIOD       ( 2_500),
        .ROW_BITS              (14),
        .COL_BITS              (10),
        .BA_BITS               (3),
        .DQ_BITS               (8),
        .LANES                 (2),
        .AUX_WIDTH             (4),
        .DUAL_RANK_DIMM        (0),
        .SPEED_BIN             (3),
        .SDRAM_CAPACITY        (3),
        .ODELAY_SUPPORTED      (0),
        .SECOND_WISHBONE       (0),
        .DLL_OFF               (0),
        .BIST_MODE             (1),
        .ECC_ENABLE            (0)
    ) dut ();
    initial #1 $finish;
endmodule
