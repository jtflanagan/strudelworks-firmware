`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// sst26_model - a behavioural Microchip SST26VF032B for the benches, x1 SPI only.
//
// Written from the datasheet (DS20005218E), not from flash_exec, and strict where
// the chip is silent, because a real chip that ignores a command gives no error:
//
//   - It powers up WRITE-PROTECTED: BPR = 5555_FFFFFFFF_FFFFFFFF (Table 5-6's
//     footnote prints a third word of F; 80 bits is 20 digits).
//     An erase or program aimed at a write-locked block is ignored (5.17-5.19).
//     Chip erase is ignored if ANY block is locked.
//   - Erase, program, WBPR and ULBPR need WEL (a WREN before); they clear it.
//   - While BUSY only RDSR (05h) is honoured.
//   - A command takes effect when chip select rises, and only on a whole number of
//     bytes of the right length; anything else is ignored.
//   - Program ANDs into the array (a 1 cannot be written back without an erase)
//     and wraps inside its 256-byte page.
//
// Everything the datasheet calls a violation (HOLD# low, WP# low, a read faster
// than 40 MHz, SCK faster than 104 MHz, a command while BUSY other than RDSR,
// a short or ragged command) counts in `violations` and is printed; a bench
// fails on any.  `ignored` counts commands the chip dropped by its own rules
// (protection, no WEL) - a bench decides whether that was expected.
//
// BUSY times are parameters, scaled down for a bench.  Fault knobs: `stick_next`
// makes the next erase/program hold BUSY forever (`stuck`, cleared by the bench);
// `drop_wbpr` accepts WBPR on the wire and changes nothing.
// The array has backdoor tasks (peek/poke) for the bench.
//////////////////////////////////////////////////////////////////////////////////

module sst26_model #(
    parameter real T_ERASE_NS = 20_000.0,     // the chip: 18-25 ms
    parameter real T_PROG_NS  = 2_000.0,      // the chip: up to 1.5 ms
    parameter real T_BPR_NS   = 200.0
) (
    input  wire sck,
    input  wire cs_n,
    input  wire si,
    output logic so,
    input  wire wp_n,
    input  wire hold_n
);
    localparam integer SIZE = 1 << 22;

    logic [7:0]  mem [0:SIZE-1];
    logic [79:0] bpr;
    logic        wel;
    realtime     busy_until;
    bit          stuck;
    bit          stick_next;            // the next erase/program holds BUSY forever
    bit          drop_wbpr;             // WBPR is accepted on the wire but changes nothing
    integer      violations, ignored, commands;
    integer      dummy_clocks;          // SCK rises under a high chip select before the first command

    initial begin
        for (int i = 0; i < SIZE; i++) mem[i] = 8'hFF;
        bpr = 80'h5555_FFFFFFFF_FFFFFFFF;
        wel = 1'b0; busy_until = 0; stuck = 0; stick_next = 0; drop_wbpr = 0;
        violations = 0; ignored = 0; commands = 0; dummy_clocks = 0;
        so = 1'b0;
    end

    function automatic bit busy_now();
        return stuck || ($realtime < busy_until);
    endfunction

    // ---- protection map (Table 5-6) ---------------------------------------
    function automatic int wl_bit(input int a);
        if (a < 'h8000)        return 64 + 2 * (a >> 13);
        if (a < 'h10000)       return 62;
        if (a < 'h3F0000)      return (a >> 16) - 1;
        if (a < 'h3F8000)      return 63;
        return 72 + 2 * ((a - 'h3F8000) >> 13);
    endfunction
    function automatic bit locked(input int a);
        return bpr[wl_bit(a)];
    endfunction
    function automatic int block_base(input int a);
        if (a < 'h8000)   return a & ~'h1FFF;
        if (a < 'h10000)  return 'h8000;
        if (a < 'h3F0000) return a & ~'hFFFF;
        if (a < 'h3F8000) return 'h3F0000;
        return a & ~'h1FFF;
    endfunction
    function automatic int block_size(input int a);
        if (a < 'h8000)   return 'h2000;
        if (a < 'h10000)  return 'h8000;
        if (a < 'h3F0000) return 'h10000;
        if (a < 'h3F8000) return 'h8000;
        return 'h2000;
    endfunction
    function automatic bit any_locked();
        for (int k = 0; k < 64; k++) if (bpr[k]) return 1;
        for (int k = 64; k < 80; k += 2) if (bpr[k]) return 1;
        return 0;
    endfunction

    task automatic violation(input string what);
        violations++;
        $display("MODEL VIOLATION @%0t: %s", $time, what);
    endtask

    // ---- the command in flight -----------------------------------------
    integer     nbits;
    logic [7:0] cmd;
    logic [23:0] addr;
    logic [7:0] data [0:255];   // bytes after the opcode (+ address)
    integer     ndata;
    logic [7:0] cur;
    realtime    last_rise;

    always @(negedge cs_n) begin
        nbits = 0; ndata = 0; cmd = 8'h00; addr = '0; cur = 8'h00;
        last_rise = 0;
    end

    always @(posedge sck) begin
        if (!hold_n) violation("HOLD# low");
        if (!wp_n)   violation("WP# low");
        if (cs_n) begin
            if (commands == 0) dummy_clocks++;
        end else begin
            if (last_rise != 0) begin
                if ($realtime - last_rise < 9.6) violation("SCK above 104 MHz");
                if (cmd == 8'h03 && nbits > 8 && $realtime - last_rise < 25.0)
                    violation("03h read above 40 MHz");
            end
            last_rise = $realtime;
            cur = {cur[6:0], si};
            nbits++;
            if (nbits == 8) begin
                cmd = cur;
                if (busy_now() && cmd != 8'h05) violation($sformatf("command %02h while BUSY", cmd));
            end else if (nbits % 8 == 0) begin
                if ((cmd == 8'h02 || cmd == 8'h20 || cmd == 8'hD8 || cmd == 8'h03) && nbits <= 32)
                    addr = {addr[15:0], cur};
                else if (ndata < 256) begin data[ndata] = cur; ndata++; end
                else if (cmd == 8'h02) begin    // past 256 bytes: the page keeps the last 256
                    for (int i = 0; i < 255; i++) data[i] = data[i+1];
                    data[255] = cur;
                end
            end
        end
    end

    // outputs change on the falling edge
    always @(negedge sck) begin
        if (!cs_n && nbits >= 8) begin
            int b;
            case (cmd)
            8'h9F: begin
                b = nbits - 8;
                case ((b / 8) % 3)
                0: so = 8'hBF >> (7 - b % 8);
                1: so = 8'h26 >> (7 - b % 8);
                default: so = 8'h42 >> (7 - b % 8);
                endcase
            end
            8'h05: begin
                logic [7:0] sr;
                sr = {6'd0, wel, busy_now()};
                so = sr[7 - (nbits - 8) % 8];
            end
            8'h72: begin
                b = nbits - 8;
                so = (b < 80) ? bpr[79 - b] : 1'b0;
            end
            8'h03: if (nbits >= 32) begin
                b = nbits - 32;
                so = mem[(int'(addr) + b / 8) % SIZE][7 - b % 8];
            end
            default: ;
            endcase
        end
    end

    // effects when chip select rises
    always @(posedge cs_n) begin
        if (nbits > 0) begin
            commands++;
            if (nbits % 8 != 0) violation($sformatf("command %02h ended after %0d bits", cmd, nbits));
            else if (busy_now()) begin
                if (cmd != 8'h05) ignored++;
            end else case (cmd)
            8'h06: if (nbits == 8) wel = 1'b1; else violation("WREN with data");
            8'h04: wel = 1'b0;
            8'h9F, 8'h05, 8'h72, 8'h03: ;
            8'h42: begin
                if (nbits != 8 + 80) violation($sformatf("WBPR with %0d bits", nbits - 8));
                else if (!wel) ignored++;
                else if (!drop_wbpr) begin
                    for (int i = 0; i < 10; i++) bpr[79 - 8*i -: 8] = data[i];
                    busy_until = $realtime + T_BPR_NS;
                end
                wel = 1'b0;
            end
            8'h98: begin
                if (!wel) ignored++;
                else begin
                    for (int k = 0; k < 64; k++) bpr[k] = 1'b0;
                    for (int k = 64; k < 80; k += 2) bpr[k] = 1'b0;
                end
                wel = 1'b0;
            end
            8'h20, 8'hD8: begin
                int a, base, size;
                a = int'(addr);
                if (nbits != 32) violation($sformatf("erase %02h with %0d bits", cmd, nbits));
                else if (!wel || locked(a)) ignored++;
                else begin
                    base = (cmd == 8'h20) ? (a & ~'hFFF) : block_base(a);
                    size = (cmd == 8'h20) ? 'h1000 : block_size(a);
                    for (int i = 0; i < size; i++) mem[base + i] = 8'hFF;
                    busy_until = $realtime + T_ERASE_NS;
                    if (stick_next) begin stuck = 1; stick_next = 0; end
                end
                wel = 1'b0;
            end
            8'hC7, 8'h60: begin
                if (!wel || any_locked()) ignored++;
                else begin
                    for (int i = 0; i < SIZE; i++) mem[i] = 8'hFF;
                    busy_until = $realtime + 2.0 * T_ERASE_NS;
                end
                wel = 1'b0;
            end
            8'h02: begin
                int a, n;
                a = int'(addr); n = (ndata > 256) ? 256 : ndata;
                if (nbits < 40) violation("page program with no data");
                else if (!wel || locked(a)) ignored++;
                else begin
                    for (int i = 0; i < n; i++) begin
                        int t;
                        t = (a & ~'hFF) | ((a + i) & 'hFF);
                        mem[t] = mem[t] & data[i];
                    end
                    busy_until = $realtime + T_PROG_NS;
                    if (stick_next) begin stuck = 1; stick_next = 0; end
                end
                wel = 1'b0;
            end
            default: violation($sformatf("unknown command %02h", cmd));
            endcase
        end
        so = 1'b0;
    end

    // ---- backdoor -------------------------------------------------------
    function automatic logic [7:0] peek(input int a);
        return mem[a];
    endfunction
    task automatic poke(input int a, input logic [7:0] v);
        mem[a] = v;
    endtask

endmodule
