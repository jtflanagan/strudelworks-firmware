`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// flash_exec - the configuration flash's command executor (docs/BOOT_LOADER.md BL1).
//
// The flash is a Microchip SST26VF032B (4 MB, JEDEC BF 26 42) on both the Au V2
// and the Pt V2.  This module speaks x1 SPI mode 0 to it and runs five commands,
// one at a time, each ending in a `done` pulse and an error code:
//
//   OP_ID      9Fh, three bytes back into `id`.
//   OP_UNLOCK  WREN, WBPR 42h with BPR (below), wait, then RBPR 72h and compare:
//              E_BPR if the chip did not take it.
//   OP_ERASE   WREN, D8h block erase of the 64 KB block at `cmd_addr`, poll BUSY.
//   OP_PROG    WREN, 02h page program of the 256-byte buffer at `cmd_addr`, poll BUSY.
//   OP_READ    03h from `cmd_addr` for `cmd_len` bytes: every byte into the CRC32
//              (`crc`, zlib's), the first 256 into the buffer.
//
// THE FLASH POWERS UP WRITE-PROTECTED, and an erase or program aimed at a protected
// block is IGNORED by the chip - no error, nothing changes.  OP_UNLOCK clears only
// the user region's write-locks; the golden image's blocks stay locked, so even a
// wrong address that got past the fence below could not touch golden.  Chip erase
// (C7h) and the global unlock (98h) are never sent.
//
// THE FENCE.  OP_ERASE and OP_PROG refuse (E_FENCE, nothing sent) any address
// outside [USER_BASE, USER_END) or not aligned to its block / page.  With the BPR
// that makes two independent guards on golden.
//
// Every BUSY poll is bounded by TIMEOUT_CLKS (E_TIMEOUT): the executor never hangs.
//
// The SPI clock is clk / (2*HALF).  03h is limited to 40 MHz by the datasheet, so
// HALF >= 2 at a 100 MHz clk.  MISO is sampled as SCK rises (mode 0), a half period
// after the flash drove it on the falling edge.  On hardware SCK reaches the CCLK
// pin through STARTUPE2's USRCCLKO, which swallows the first three clocks after
// configuration: the executor starts with eight clocks under a high chip select.
// That primitive is instantiated by the top, not here, so this module simulates.
//
// The buffer is 256 bytes, written and read by the host 32 bits at a time, little-
// endian (byte 4n is bits 7:0 of word n).  The host writes it only while !busy.
//////////////////////////////////////////////////////////////////////////////////

module flash_exec #(
    parameter integer      HALF         = 2,           // clk cycles per SCK half period
    parameter integer      TIMEOUT_CLKS = 10_000_000,  // 100 ms at 100 MHz; erase max is 25 ms
    parameter logic [23:0] USER_BASE    = 24'h100000,  // first byte of the user region
    parameter logic [23:0] USER_END     = 24'h3F0000   // first byte past it (the top 64 KB is 8/32 KB blocks)
) (
    input  wire         clk,
    input  wire         rst,

    // one command at a time; taken only while !busy
    input  wire         cmd_valid,
    input  wire  [2:0]  cmd_op,
    input  wire  [23:0] cmd_addr,
    input  wire  [23:0] cmd_len,        // OP_READ only
    output wire         busy,
    output logic        done,           // one clock, at the end of every command taken
    output logic [2:0]  err,            // the last command's result, E_NONE on success
    output logic [23:0] id,
    output wire  [31:0] crc,            // CRC32 of the last OP_READ's bytes

    // the page buffer
    input  wire         buf_we,
    input  wire  [5:0]  buf_waddr,
    input  wire  [31:0] buf_wdata,
    input  wire  [5:0]  buf_raddr,
    output wire  [31:0] buf_rdata,

    // the flash (x1 SPI; WP# and HOLD# held high)
    output logic        spi_sck,
    output logic        spi_cs_n,
    output logic        spi_mosi,
    input  wire         spi_miso,
    output wire         spi_wp_n,
    output wire         spi_hold_n
);

    localparam logic [2:0] OP_ID = 3'd1, OP_UNLOCK = 3'd2, OP_ERASE = 3'd3,
                           OP_PROG = 3'd4, OP_READ = 3'd5;
    localparam logic [2:0] E_NONE = 3'd0, E_FENCE = 3'd1, E_TIMEOUT = 3'd2,
                           E_BPR = 3'd3, E_ARG = 3'd4;

    assign spi_wp_n   = 1'b1;
    assign spi_hold_n = 1'b1;

    // ---- the Block-Protection Register we write -----------------------------
    // Datasheet Table 5-6: BPR[61:0] are the 64 KB blocks at 0x010000..0x3EFFFF
    // (block k at k<<16 is bit k-1), [62]/[63] the 32 KB blocks at the bottom and
    // top, [79:64] the eight 8 KB blocks (even bits write-lock, odd bits read-lock).
    // Power-on is 5555_FFFFFFFF_FFFFFFFF; we clear the user region's bits.
    function automatic logic [79:0] user_bpr(input logic [23:0] base, input logic [23:0] lim);
        logic [79:0] b;
        b = 80'h5555_FFFFFFFF_FFFFFFFF;
        for (int k = 1; k < 63; k++)
            if ((k << 16) >= int'(base) && (k << 16) < int'(lim)) b[k-1] = 1'b0;
        return b;
    endfunction
    localparam logic [79:0] BPR = user_bpr(USER_BASE, USER_END);

    function automatic logic [31:0] crc_byte(input logic [31:0] c, input logic [7:0] d);
        logic [31:0] x;
        x = c ^ {24'd0, d};
        for (int i = 0; i < 8; i++) x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
        return x;
    endfunction

    // ---- the page buffer ----------------------------------------------------
    logic [7:0] pbuf [0:255];
    assign buf_rdata = {pbuf[{buf_raddr, 2'd3}], pbuf[{buf_raddr, 2'd2}],
                        pbuf[{buf_raddr, 2'd1}], pbuf[{buf_raddr, 2'd0}]};

    // ---- the transaction engine ---------------------------------------------
    // One chip-select-low transaction: an opcode, optionally three address bytes,
    // then `t_ntx` payload bytes out OR `t_nrx` bytes in.  `t_nocs` sends one byte
    // of clocks with chip select HIGH (the post-configuration dummy clocks).
    localparam logic [1:0] SRC_BUF = 2'd0, SRC_BPR = 2'd1;
    localparam logic [1:0] DST_ID = 2'd0, DST_BUFCRC = 2'd1, DST_BPRCMP = 2'd2, DST_STATUS = 2'd3;

    logic        t_go, t_done;
    logic [7:0]  t_op;
    logic        t_addr3, t_nocs;
    logic [23:0] t_addr;
    logic [8:0]  t_ntx;
    logic [23:0] t_nrx;
    logic [1:0]  t_src, t_dst;

    typedef enum logic [1:0] {E_IDLE, E_CSL, E_BYTE, E_CSH} estate_t;
    estate_t     es;
    localparam integer HCW = (HALF > 1) ? $clog2(2*HALF) : 1;   // counts to 2*HALF-1 in E_CSH
    localparam logic [HCW-1:0] HC_HALF = HCW'(HALF - 1), HC_FULL = HCW'(2*HALF - 1);
    logic [HCW-1:0] hc;
    logic        ph;
    logic [2:0]  bitn;
    logic [7:0]  txb, rxb;
    logic [24:0] bidx;          // byte index within the transaction
    logic [24:0] bytes_total;
    logic [2:0]  nhdr;

    // the byte to send at index i
    function automatic logic [7:0] tx_byte(input logic [24:0] i);
        logic [24:0] p;
        if (i == 0)                   return t_nocs ? 8'hFF : t_op;
        if (t_addr3 && i == 1)        return t_addr[23:16];
        if (t_addr3 && i == 2)        return t_addr[15:8];
        if (t_addr3 && i == 3)        return t_addr[7:0];
        p = i - 25'(nhdr);
        if (p < 25'(t_ntx))
            return (t_src == SRC_BUF) ? pbuf[p[7:0]] : BPR[79 - 8*p[3:0] -: 8];
        return 8'h00;
    endfunction

    wire [7:0] tx_cur = tx_byte(bidx);
    wire [7:0] tx_nxt = tx_byte(bidx + 1'b1);

    // the rx side, visible to the sequencer
    logic        rx_valid;      // one clock, a received byte in rx_byte at index rx_idx
    logic [7:0]  rx_byte;
    logic [23:0] rx_idx;

    always_ff @(posedge clk) begin
        rx_valid <= 1'b0;
        t_done   <= 1'b0;
        if (rst) begin
            es <= E_IDLE; spi_sck <= 1'b0; spi_cs_n <= 1'b1; spi_mosi <= 1'b0;
            hc <= '0; ph <= 1'b0; bitn <= '0; bidx <= '0;
        end else begin
            case (es)
            E_IDLE: if (t_go) begin
                nhdr        <= t_nocs ? 3'd1 : (t_addr3 ? 3'd4 : 3'd1);
                bytes_total <= (t_nocs ? 25'd1 : (t_addr3 ? 25'd4 : 25'd1)) + 25'(t_ntx) + 25'(t_nrx);
                bidx        <= '0;
                spi_cs_n    <= t_nocs;
                hc          <= '0;
                es          <= E_CSL;
            end
            E_CSL: begin                        // chip select setup: one half period
                if (hc == HC_HALF) begin
                    hc   <= '0;
                    txb  <= tx_cur;
                    spi_mosi <= tx_cur[7];
                    ph   <= 1'b0; bitn <= '0;
                    es   <= E_BYTE;
                end else hc <= hc + 1'b1;
            end
            E_BYTE: begin
                if (hc == HC_HALF) begin
                    hc <= '0;
                    if (!ph) begin              // rising edge: the flash samples MOSI, we sample MISO
                        spi_sck <= 1'b1;
                        rxb     <= {rxb[6:0], spi_miso};
                        ph      <= 1'b1;
                    end else begin              // falling edge: next bit out
                        spi_sck <= 1'b0;
                        ph      <= 1'b0;
                        if (bitn == 3'd7) begin
                            if (bidx >= 25'(nhdr) + 25'(t_ntx) && !t_nocs) begin
                                rx_valid <= 1'b1;
                                rx_byte  <= rxb;
                                rx_idx   <= 24'(bidx - 25'(nhdr) - 25'(t_ntx));
                            end
                            if (bidx + 1'b1 == bytes_total) begin
                                es <= E_CSH;
                            end else begin
                                bidx     <= bidx + 1'b1;
                                txb      <= tx_nxt;
                                spi_mosi <= tx_nxt[7];
                                bitn     <= '0;
                            end
                        end else begin
                            bitn     <= bitn + 1'b1;
                            spi_mosi <= txb[6 - bitn];
                        end
                    end
                end else hc <= hc + 1'b1;
            end
            E_CSH: begin                        // chip select high for a full SCK period
                spi_cs_n <= 1'b1;
                if (hc == HC_FULL) begin
                    hc     <= '0;
                    t_done <= 1'b1;
                    es     <= E_IDLE;
                end else hc <= hc + 1'b1;
            end
            endcase
        end
    end

    // ---- the sequencer ------------------------------------------------------
    typedef enum logic [3:0] {Q_INIT, Q_INITW, Q_IDLE, Q_WREN, Q_MAIN, Q_POLL, Q_VERIFY, Q_WAIT, Q_END} qstate_t;
    qstate_t     qs, q_after;       // q_after: where Q_WAIT goes when the transaction ends
    logic [2:0]  op;
    logic [23:0] addr, len;
    logic [31:0] crc_q;
    logic        st_busy;           // the last RDSR's BUSY bit
    logic [$clog2(TIMEOUT_CLKS+1)-1:0] tmo;
    logic        bpr_bad;

    assign busy = (qs != Q_IDLE);
    assign crc  = ~crc_q;

    wire fence_erase = (cmd_addr[15:0] != 16'h0) || (cmd_addr < USER_BASE) || (cmd_addr >= USER_END);
    wire fence_prog  = (cmd_addr[7:0]  != 8'h0)  || (cmd_addr < USER_BASE) || (cmd_addr >= USER_END);
    wire bad_read    = (cmd_len == 24'd0) || ({1'b0, cmd_addr} + {1'b0, cmd_len} > 25'h400000);

    // start a transaction and wait for it in Q_WAIT
    task automatic go(input logic [7:0] o, input logic a3, input logic [8:0] ntx,
                      input logic [23:0] nrx, input logic [1:0] src, input logic [1:0] dst,
                      input qstate_t nxt);
        t_go <= 1'b1; t_op <= o; t_addr3 <= a3; t_nocs <= 1'b0; t_addr <= addr;
        t_ntx <= ntx; t_nrx <= nrx; t_src <= src; t_dst <= dst;
        q_after <= nxt; qs <= Q_WAIT;
    endtask

    always_ff @(posedge clk) begin
        t_go <= 1'b0;
        done <= 1'b0;
        if (rst) begin
            qs <= Q_INIT; err <= E_NONE; id <= '0; crc_q <= 32'hFFFFFFFF;
            t_nocs <= 1'b0; t_ntx <= '0; t_nrx <= '0; t_addr3 <= 1'b0; t_op <= '0;
            st_busy <= 1'b0; bpr_bad <= 1'b0; tmo <= '0;
        end else begin
            // received bytes, wherever they are going
            if (rx_valid) begin
                case (t_dst)
                DST_ID:     id <= {id[15:0], rx_byte};
                DST_BUFCRC: begin
                    crc_q <= crc_byte(crc_q, rx_byte);
                    if (rx_idx < 24'd256) pbuf[rx_idx[7:0]] <= rx_byte;
                end
                DST_BPRCMP: if (rx_byte != BPR[79 - 8*rx_idx[3:0] -: 8]) bpr_bad <= 1'b1;
                DST_STATUS: st_busy <= rx_byte[0];
                endcase
            end else if (buf_we && qs == Q_IDLE) begin
                {pbuf[{buf_waddr, 2'd3}], pbuf[{buf_waddr, 2'd2}],
                 pbuf[{buf_waddr, 2'd1}], pbuf[{buf_waddr, 2'd0}]} <= buf_wdata;
            end

            case (qs)
            Q_INIT: begin                   // eight clocks under a high chip select
                t_go <= 1'b1; t_nocs <= 1'b1; t_ntx <= '0; t_nrx <= '0; t_addr3 <= 1'b0;
                qs <= Q_INITW;
            end
            Q_INITW: if (t_done) qs <= Q_IDLE;
            Q_IDLE: if (cmd_valid) begin
                op <= cmd_op; addr <= cmd_addr; len <= cmd_len;
                err <= E_NONE; bpr_bad <= 1'b0;
                case (cmd_op)
                OP_ID:     qs <= Q_MAIN;
                OP_UNLOCK: qs <= Q_WREN;
                OP_ERASE:  if (fence_erase) begin err <= E_FENCE; qs <= Q_END; end else qs <= Q_WREN;
                OP_PROG:   if (fence_prog)  begin err <= E_FENCE; qs <= Q_END; end else qs <= Q_WREN;
                OP_READ:   if (bad_read)    begin err <= E_ARG;   qs <= Q_END; end
                           else begin crc_q <= 32'hFFFFFFFF; qs <= Q_MAIN; end
                default:   begin err <= E_ARG; qs <= Q_END; end
                endcase
            end
            Q_WREN: go(8'h06, 1'b0, 9'd0, 24'd0, SRC_BUF, DST_STATUS, Q_MAIN);
            Q_MAIN: begin
                case (op)
                OP_ID:     go(8'h9F, 1'b0, 9'd0,   24'd3, SRC_BUF, DST_ID,     Q_END);
                OP_UNLOCK: go(8'h42, 1'b0, 9'd10,  24'd0, SRC_BPR, DST_STATUS, Q_POLL);
                OP_ERASE:  go(8'hD8, 1'b1, 9'd0,   24'd0, SRC_BUF, DST_STATUS, Q_POLL);
                OP_PROG:   go(8'h02, 1'b1, 9'd256, 24'd0, SRC_BUF, DST_STATUS, Q_POLL);
                default:   go(8'h03, 1'b1, 9'd0,   len,   SRC_BUF, DST_BUFCRC, Q_END);
                endcase
                tmo <= '0;
            end
            Q_POLL: go(8'h05, 1'b0, 9'd0, 24'd1, SRC_BUF, DST_STATUS, Q_VERIFY);
            Q_VERIFY: begin                 // after a poll: again, give up, or move on
                if (st_busy) begin
                    if (tmo >= TIMEOUT_CLKS[$bits(tmo)-1:0]) begin err <= E_TIMEOUT; qs <= Q_END; end
                    else qs <= Q_POLL;
                end else if (op == OP_UNLOCK && t_op != 8'h72) begin
                    go(8'h72, 1'b0, 9'd0, 24'd10, SRC_BUF, DST_BPRCMP, Q_VERIFY);
                end else begin
                    if (op == OP_UNLOCK && bpr_bad) err <= E_BPR;
                    qs <= Q_END;
                end
            end
            Q_WAIT: if (t_done) qs <= q_after;
            Q_END: begin
                done <= 1'b1;
                qs   <= Q_IDLE;
            end
            default: qs <= Q_IDLE;
            endcase

            // the poll's clock runs from the command's issue to BUSY clearing
            if (qs == Q_POLL || qs == Q_VERIFY || (qs == Q_WAIT && t_op == 8'h05))
                if (tmo != {$bits(tmo){1'b1}}) tmo <= tmo + 1'b1;
        end
    end

endmodule
