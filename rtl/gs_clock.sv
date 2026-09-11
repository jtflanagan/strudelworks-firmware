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
// checksums.  ON THE CARD IT IS THE HOST'S FEED THAT MOVES IT: a GS_TIME
// message carries one word of seconds and the host re-sends it every second,
// exactly as it feeds the No-Slot Clock, because the card has no oscillator
// of its own to count.  NOTHING TICKS IN RTL, deliberately: a clock that
// advanced here would make the bench's comparison against a recorded trace
// depend on when the run started, and the bench sends no GS_TIME at all.
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
module gs_clock #(
    // The message types, as rtl/ft601_msg_rx.sv and docs/PROTOCOL.md number
    // them.  GS_TIME IS $30: it was $2F here for two days, which is ADB_KEY,
    // so every key the host sent set the clock to its own event word and
    // the Pi's time never arrived - the Control Panel read 1/1/04 (docs/
    // GS.md rung 4's gate, 2026-09-11).  gs_io does not override these.
    parameter [7:0] T_GS_BRAM = 8'h2E,
    parameter [7:0] T_GS_TIME = 8'h30
) (
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
    // reset, and thereafter whatever the host last sent as a GS_TIME; see
    // the header.
    input  wire [31:0] seed_time,

    // The border colour, $C034[3:0], for the host to paint.
    output wire [3:0]  border,

    // THE BATTERY RAM THE HOST SHIPS (docs/GS.md, "The battery RAM the host
    // ships").  Host -> card messages as ft601_msg_rx decodes them: a
    // GS_BRAM carries the whole 256 bytes as 64 words, four bytes a word,
    // low byte first, and is taken ALL OR NOTHING - a partial image is worse
    // than none, because the ROM would checksum it, find it wrong and write
    // its own defaults over the slot settings the host was trying to ship.
    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    input  wire [7:0]  msg_len,
    input  wire [31:0] pay_data,
    input  wire        pay_valid,
    output logic       bram_ok,        // an image has landed whole

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
    //
    // FOUR BYTE-WIDE BANKS, chosen by the index's low two bits.  The host's
    // image arrives four bytes at a time - one message word a clock, and the
    // link will not wait - and a byte-wide array cannot take four writes in a
    // clock; four banks can, one each.  The machine still sees one 256-byte
    // battery RAM: its index picks the bank with its low two bits and the
    // entry with the rest.
    (* ram_style = "distributed" *) logic [7:0] bram0 [0:63];
    (* ram_style = "distributed" *) logic [7:0] bram1 [0:63];
    (* ram_style = "distributed" *) logic [7:0] bram2 [0:63];
    (* ram_style = "distributed" *) logic [7:0] bram3 [0:63];
    integer bi;
    initial for (bi = 0; bi < 64; bi = bi + 1) begin
        bram0[bi] = 8'd0; bram1[bi] = 8'd0; bram2[bi] = 8'd0; bram3[bi] = 8'd0;
    end
    wire [5:0] bram_e = reg1[7:2];
    wire [7:0] bram_q = (reg1[1:0] == 2'd0) ? bram0[bram_e] :
                        (reg1[1:0] == 2'd1) ? bram1[bram_e] :
                        (reg1[1:0] == 2'd2) ? bram2[bram_e] : bram3[bram_e];

    // ---- the host's image, as ft601_msg_rx decodes it ----------------------
    // vidhd_card's shape: a header names the type and the length, the words
    // follow, and the message counts only if it is the WHOLE image.
    logic [7:0] rx_type, rx_idx, rx_left;
    wire rx_word   = pay_valid && (rx_left != 8'd0);
    wire rx_last   = rx_word && (rx_left == 8'd1);
    wire hdr_bram  = msg_valid && (msg_type == T_GS_BRAM);
    wire word_bram = rx_word && (rx_type == T_GS_BRAM);
    // THE HOST'S SECONDS.  One word, seconds since 1904-01-01, and the feed
    // IS the clock: the card has no oscillator of its own to count and a
    // clock that ticked in RTL would make the bench's comparison against a
    // recorded trace depend on when the run started.  The host re-sends it
    // every second, exactly as it feeds the No-Slot Clock (docs/NSC.md), so
    // the machine reads the Pi's time to the second.  It lands whenever it
    // arrives - the ROM reads the register a byte at a time and a seam
    // between two seconds is the same seam a real clock chip has.
    wire hdr_time  = msg_valid && (msg_type == T_GS_TIME);
    wire word_time = rx_word && (rx_type == T_GS_TIME);

    // One write port a bank.  The host's image wins a clock it shares with
    // the machine's byte, which cannot happen in practice - the image lands
    // before RES' is released - and is stated rather than left to chance.
    always_ff @(posedge clk) begin
        if (word_bram) begin
            bram0[rx_idx[5:0]] <= pay_data[7:0];
            bram1[rx_idx[5:0]] <= pay_data[15:8];
            bram2[rx_idx[5:0]] <= pay_data[23:16];
            bram3[rx_idx[5:0]] <= pay_data[31:24];
        end else if (mach_wr) begin
            case (reg1[1:0])
                2'd0: bram0[bram_e] <= c033;
                2'd1: bram1[bram_e] <= c033;
                2'd2: bram2[bram_e] <= c033;
                default: bram3[bram_e] <= c033;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_type <= 8'd0;
            rx_idx  <= 8'd0;
            rx_left <= 8'd0;
            bram_ok <= 1'b0;
        end else begin
            if (msg_valid) begin
                rx_type <= msg_type;
                rx_idx  <= 8'd0;
                rx_left <= msg_len;
                // A battery RAM message is only one if it is the whole 256
                // bytes: a partial image is worse than none, because the ROM
                // would checksum it, find it wrong, and write its own
                // defaults over the slot settings this was shipping.
                if (hdr_bram && msg_len != 8'd64) rx_type <= 8'd0;
                if (hdr_time && msg_len != 8'd1)  rx_type <= 8'd0;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;
                if (word_bram && rx_last) bram_ok <= 1'b1;
            end
        end
    end

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
    // The machine's own byte write into the battery RAM: the transfer strobe
    // of a BRAM1 whose direction agrees with the command's.  Derived here
    // rather than inside the state machine because the banks below have one
    // write port each and the host's image writes them too.
    wire mach_wr = !rst && res_sync && strobe && (mode == M_BRAM1) &&
                   !xfer_rd && !clk_read;

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
            // host reloads it at start, so nothing here clears it.  So does
            // the time: a real clock chip does not forget the date because
            // somebody pressed Control-Reset.
            if (rst) cur_time <= seed_time;
            else if (word_time) cur_time <= pay_data;
        end else begin
            // The host's feed, and the machine's own SET TIME, share this
            // register.  A feed that landed on the clock the machine wrote
            // would lose the write; that cannot happen (the machine's write
            // is a strobe far from a message word) and is stated anyway by
            // giving the machine's write the later assignment below.
            if (word_time) cur_time <= pay_data;
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
                        if (xfer_rd && clk_read)        c033 <= bram_q;
                        else if (!(!xfer_rd && !clk_read)) cnt_bad <= cnt_bad + 8'd1;
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
