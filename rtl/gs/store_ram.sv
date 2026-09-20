// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// store_ram - one way of the instruction store (rtl/gs/l1i_store.sv): 4096
// bytes in one RAMB36, READ A BYTE AT A TIME and WRITTEN EIGHT AT A TIME.
//
// The read port is the fetch's: the byte at rd_addr lands in the RAM's own
// output register one clock later, and that register IS the core's din for
// a resident fetch - no mux of any width behind it but the way select.  The
// write port lands a fill's row as two 64-bit halves.  This is UG901's
// "asymmetric port RAM, write wider than read" shape: the array is the
// narrow width and the wide write stores its eight bytes to eight
// consecutive entries in one clock; the synthesizer maps it onto one block
// RAM with the two port widths.
module store_ram (
    input  wire         clk,
    input  wire         rd_en,
    input  wire [11:0]  rd_addr,
    output logic [7:0]  rd_data,     // one clock after rd_en
    input  wire         wr_en,
    input  wire [8:0]   wr_addr,     // the 64-bit word: {row, half}
    input  wire [63:0]  wr_data
);
    (* ram_style = "block" *) logic [7:0] mem [0:4095];

    always_ff @(posedge clk) begin
        if (wr_en)
            for (int i = 0; i < 8; i = i + 1)
                mem[{wr_addr, 3'(i)}] <= wr_data[8 * i +: 8];
        if (rd_en) rd_data <= mem[rd_addr];
    end
endmodule
