`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// iprog - reconfigure the FPGA from flash, from inside the design
// (docs/BOOT_LOADER.md: BOOT, and LINK_RESET as a full reset).
//
// On `req`, writes UG470 Table 7-1's IPROG sequence into the configuration port:
//
//   FFFFFFFF dummy, AA995566 sync, 20000000 NOOP, 30020001 write WBSTAR,
//   <addr>, 20000000 NOOP, 30008001 write CMD, 0000000F IPROG, 20000000 NOOP
//
// WBSTAR is the flash byte address to boot from (SPI).  The FPGA reconfigures:
// every user I/O floats until the new image is up (PUDC_B is strapped high), so
// the FT601 link drops and the host reconnects; nothing survives, which is the
// point.
//
// The port (ICAPE2) is the top's, so this simulates: `icap_csib` low with
// `icap_rdwrb` low writes `icap_i` on each clock.  RDWRB goes to write a clock
// before CSIB asserts and does not move while it is asserted.  ICAPE2 takes each byte of a
// word BIT-REVERSED (UG470, "Bit Swapping"), done here.  ICAPE2 runs at up to
// 100 MHz.
//////////////////////////////////////////////////////////////////////////////////

module iprog (
    input  wire         clk,
    input  wire         rst,
    input  wire         req,
    input  wire  [23:0] addr,
    output wire         icap_csib,
    output wire         icap_rdwrb,
    output wire  [31:0] icap_i,
    output wire         busy
);
    // Deselected from configuration on, not only from the first reset clock.
    logic        csib_q  = 1'b1;
    logic        rdwrb_q = 1'b1;
    logic [31:0] i_q     = 32'd0;
    logic        busy_q  = 1'b0;
    assign icap_csib  = csib_q;
    assign icap_rdwrb = rdwrb_q;
    assign icap_i     = i_q;
    assign busy       = busy_q;

    function automatic logic [31:0] swap(input logic [31:0] w);
        logic [31:0] s;
        for (int b = 0; b < 4; b++)
            for (int i = 0; i < 8; i++) s[8*b + i] = w[8*b + 7 - i];
        return s;
    endfunction

    logic [3:0]  n;
    logic [23:0] a;
    logic        setup;

    function automatic logic [31:0] word(input logic [3:0] k, input logic [23:0] wb);
        case (k)
        4'd0: return 32'hFFFFFFFF;
        4'd1: return 32'hAA995566;
        4'd2: return 32'h20000000;
        4'd3: return 32'h30020001;
        4'd4: return {8'h00, wb};
        4'd5: return 32'h20000000;
        4'd6: return 32'h30008001;
        4'd7: return 32'h0000000F;
        default: return 32'h20000000;
        endcase
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q <= 1'b0; n <= '0; csib_q <= 1'b1; rdwrb_q <= 1'b1; i_q <= '0; a <= '0; setup <= 1'b0;
        end else if (!busy_q) begin
            csib_q  <= 1'b1;
            rdwrb_q <= 1'b1;
            if (req) begin busy_q <= 1'b1; n <= '0; a <= addr; setup <= 1'b1; end
        end else if (setup) begin           // RDWRB to write a clock BEFORE CSIB asserts
            rdwrb_q <= 1'b0;
            setup      <= 1'b0;
        end else begin
            csib_q  <= 1'b0;
            i_q     <= swap(word(n, a));
            if (n == 4'd8) busy_q <= 1'b0;    // the device is gone long before anyone sees this
            else n <= n + 4'd1;
        end
    end

endmodule
