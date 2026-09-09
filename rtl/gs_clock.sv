`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_clock - the IIgs's clock chip and battery RAM, at $C033/$C034.
//
// THE REFERENCE IS KEGS's clock.c (clock_write_c034, do_clock_data) and
// moremem.c's $C033/$C034 cases, transcribed rather than reasoned out.
//
// WHAT IT IS.  A serial-ish protocol over two registers.  $C033 is a DATA
// LATCH the CPU reads and writes freely.  $C034 is control: bits 3:0 are the
// BORDER COLOUR and have nothing to do with the clock, bit 6 says which way
// the next transfer goes, bit 5 says "last", and WRITING BIT 7 IS THE STROBE
// that makes the chip act on whatever is in $C033.  Bit 7 is not stored, so a
// read of $C034 never shows it (KEGS: g_c034_val = val & 0x7f).
//
// THE FIVE STATES are KEGS's g_clk_mode.  From IDLE a strobed WRITE carries a
// command byte in $C033: bit 7 says whether the transfer that follows is a
// read, bits 6:4 the operation, bits 3:2 a register index.  The operation
// picks the next state - the seconds register (TIME), the chip's internal
// test and write-protect registers (INTERNAL), the low sixteen bytes of
// battery RAM or $10-$13 (BRAM1), or the two-byte address form that reaches
// all 256 (BRAM2, which collects the rest of the address and falls into
// BRAM1).  The state after that does the transfer and returns to IDLE.  So
// every byte of battery RAM costs two or three strobes, which is why the ROM
// touches $C034 twenty-two thousand times during a boot.
//
// THE TIME IS SECONDS SINCE 1904-01-01, four bytes, indexed by the command's
// register field.  `seed_time` is what the machine believes: on the card the
// host sends it as the No-Slot Clock's time already is (docs/NSC.md), and in
// sim/boot_gs_tb.sv it is pinned to the same value tools/kegs/trace_rom.sh
// pins KEGS's to, or the two machines would disagree about a byte the ROM
// checksums.  IT DOES NOT TICK YET: a clock that advanced would make the
// bench's comparison against a recorded trace depend on when the run started.
// Rung 3c gives it the host's seconds and a virtual-time tick.
//
// THE BATTERY RAM is 256 bytes, all zero from reset, which is exactly what
// KEGS boots with when its config file names no `bram` lines - so the ROM
// finds an invalid checksum on both machines and initialises it the same way.
// Persistence across runs is the host's (docs/GS.md: a `gs_bram` file);
// nothing here writes to it but the ROM.
//
// SIDE EFFECTS HAPPEN ON THE COMMIT, as in rtl/gs_adb.sv and for the same
// reason: `rd_byte` is combinational on the registered op and must be stable
// across the clocks the dispatcher takes to serve it.
//////////////////////////////////////////////////////////////////////////////////
module gs_clock (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,       // synchronised RES', ACTIVE LOW

    // The registered op and its retire.
    input  wire [7:0]  op_lo,
    input  wire        op_rw,
    input  wire [7:0]  op_wdata,
    input  wire        act,

    output logic [7:0] rd_byte,

    // Seconds since 1904-01-01, as the machine believes them.  Sampled at
    // reset; see the header.
    input  wire [31:0] seed_time,

    // The border colour, $C034[3:0], for the host to paint.
    output wire [3:0]  border,

    // Diagnostics.
    output logic [7:0] cnt_strobes,
    output logic [7:0] cnt_bad
);

    localparam [2:0] M_IDLE = 3'd0, M_TIME = 3'd1, M_INTERNAL = 3'd2,
                     M_BRAM1 = 3'd3, M_BRAM2 = 3'd4;

    logic [2:0] mode;
    logic [7:0] c033;               // the data latch
    logic [6:0] c034;               // control; bit 7 is a strobe, never stored
    logic [7:0] reg1;               // the address or index the command named
    logic       clk_read;           // the command said the transfer is a read
    logic [31:0] cur_time;

    // Distributed RAM, zero at configuration.  It is initialised HERE rather
    // than cleared in the reset arm because a 256-entry clear in one clock
    // makes Vivado infer flops instead of LUTRAM; an initial block becomes
    // the INIT values, which is what a real battery RAM's contents are.
    (* ram_style = "distributed" *) logic [7:0] bram [0:255];
    integer bi;
    initial for (bi = 0; bi < 256; bi = bi + 1) bram[bi] = 8'd0;

    assign border = c034[3:0];

    always_comb begin
        case (op_lo)
            8'h33:   rd_byte = c033;
            8'h34:   rd_byte = {1'b0, c034};
            default: rd_byte = 8'h00;
        endcase
    end

    // The command byte, decoded out of the data latch (do_clock_data's
    // CLK_IDLE arm).
    wire       cmd_read = c033[7];
    wire [2:0] cmd_op   = c033[6:4];
    wire [1:0] cmd_reg  = c033[3:2];

    // A write of $C034 with bit 7 set is the strobe; `read` is bit 6 of the
    // value being written, which is the direction of THIS transfer.
    wire wr_c034 = act && !op_rw && (op_lo == 8'h34);
    wire strobe  = wr_c034 && op_wdata[7];
    wire xfer_rd = op_wdata[6];

    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            mode <= M_IDLE;
            c033 <= 8'd0;
            c034 <= 7'd0;
            reg1 <= 8'd0;
            clk_read <= 1'b0;
            cnt_strobes <= 8'd0;
            cnt_bad <= 8'd0;
            // The battery RAM survives RES' - it is a BATTERY RAM - and the
            // host reloads it at start, so nothing here clears it.
            if (rst) cur_time <= seed_time;
        end else begin
            if (act && !op_rw && (op_lo == 8'h33)) c033 <= op_wdata;
            if (wr_c034) c034 <= op_wdata[6:0];

            if (strobe) begin
                cnt_strobes <= cnt_strobes + 8'd1;
                case (mode)
                    M_IDLE: begin
                        // The command byte names the transfer that follows.
                        clk_read <= cmd_read;
                        if (xfer_rd) begin
                            // KEGS prints and stays IDLE: a read strobe from
                            // IDLE is not part of the protocol.
                            mode <= M_IDLE;
                            cnt_bad <= cnt_bad + 8'd1;
                        end else begin
                            case (cmd_op)
                                3'h0: begin                 // seconds register
                                    mode <= M_TIME;
                                    reg1 <= {6'd0, cmd_reg};
                                end
                                3'h3: begin                 // internal registers...
                                    if (cmd_reg[1]) begin
                                        // ...or the two-byte BRAM address,
                                        // whose top three bits are here.
                                        mode <= M_BRAM2;
                                        reg1 <= {c033[2:0], 5'd0};
                                    end else begin
                                        mode <= M_INTERNAL;
                                        reg1 <= {6'd0, cmd_reg};
                                    end
                                end
                                3'h2: begin                 // BRAM $10-$13
                                    mode <= M_BRAM1;
                                    reg1 <= {6'd0, cmd_reg} + 8'h10;
                                end
                                default: begin              // 4-7: BRAM $00-$0F
                                    mode <= M_BRAM1;
                                    reg1 <= {4'd0, c033[5:2]};
                                end
                            endcase
                        end
                    end

                    M_BRAM2: begin
                        // The rest of the address: five more bits, and the
                        // byte must otherwise be clear.
                        if (!xfer_rd && ((c033 & 8'h83) == 8'h00)) begin
                            reg1 <= reg1 | {3'd0, c033[6:2]};
                            mode <= M_BRAM1;
                        end else begin
                            mode <= M_IDLE;
                            cnt_bad <= cnt_bad + 8'd1;
                        end
                    end

                    M_BRAM1: begin
                        // The transfer itself.  The direction the command
                        // announced and the direction of this strobe must
                        // agree; KEGS halts when they do not, so this counts.
                        if (xfer_rd && clk_read)        c033 <= bram[reg1];
                        else if (!xfer_rd && !clk_read) bram[reg1] <= c033;
                        else                            cnt_bad <= cnt_bad + 8'd1;
                        mode <= M_IDLE;
                    end

                    M_TIME: begin
                        if (xfer_rd) begin
                            if (!clk_read) cnt_bad <= cnt_bad + 8'd1;
                            case (reg1[1:0])
                                2'd0: c033 <= cur_time[7:0];
                                2'd1: c033 <= cur_time[15:8];
                                2'd2: c033 <= cur_time[23:16];
                                default: c033 <= cur_time[31:24];
                            endcase
                        end else begin
                            if (clk_read) cnt_bad <= cnt_bad + 8'd1;
                            case (reg1[1:0])
                                2'd0: cur_time[7:0]   <= c033;
                                2'd1: cur_time[15:8]  <= c033;
                                2'd2: cur_time[23:16] <= c033;
                                default: cur_time[31:24] <= c033;
                            endcase
                        end
                        mode <= M_IDLE;
                    end

                    // The test and write-protect registers.  KEGS keeps no
                    // state for either - it prints when something interesting
                    // is written and moves on - so neither does this.
                    default: begin
                        if (xfer_rd) cnt_bad <= cnt_bad + 8'd1;
                        mode <= M_IDLE;
                    end
                endcase
            end
        end
    end
endmodule
