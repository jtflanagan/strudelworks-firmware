`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// flash_ctrl - the card's flash block: the image replacing itself over USB3
// (docs/BOOT_LOADER.md, "The flash block").
//
// A register slave beside wb_regfile (card_link decodes 0x8000_0E00-0x8000_0FFF to
// it), the FLASH_PAGE message sink, and the flash executor (rtl/common/flash_exec.sv).
// It depends on nothing but the link: no DDR3, no core, so it answers in stage 1
// whatever state the rest of the card is in.  The image keeps running while it
// rewrites the flash - the FPGA never reads its flash again after configuring -
// and LINK_RESET (IPROG, in card_link) is what boots what was written.
//
// THE MAP IS VERSIONED AND ADDITIVE: any image must be able to load any other, so
// after release these registers and FLASH_PAGE only grow.
//
//   0x8000_0F00  BOOT_ID      RO  {"BL" 0x424C, protocol version, stage}
//   0x8000_0F04  BOOT_PART    RO  the IDCODE this image was built for; a record must match it
//   0x8000_0F08  FLASH_CMD    W   start a command ([3:0]); reads back the last one
//   0x8000_0F0C  FLASH_ADDR   RW  READ's address
//   0x8000_0F10  FLASH_LEN    RW  ERASE's bitstream length, READ's length
//   0x8000_0F14  FLASH_STAT   RO  [0] busy  [1] verified: the last QUERY passed and nothing was
//                                 written since  [4:2] the executor's error  [11:8] result
//                                 [23:16] commands finished (wraps)
//   0x8000_0F18  FLASH_PAGES  RO  [15:0] pages programmed  [31:16] pages refused (both wrap)
//   0x8000_0F1C  FLASH_ID     RO  the flash's JEDEC ID (read at reset)
//   0x8000_0F20  FLASH_CRC    RO  the CRC32 of the last read (zlib's)
//   0x8000_0F24  IMAGE_END    RO  the first byte past the bitstream's room
//   0x8000_0F28  REC_ADDR     RO  where the record lives
//   0x8000_0F40+ REC[0..15]   RO  the record as the last QUERY read it
//   0x8000_0E00+ BUF[0..63]   RO  the executor's 256-byte buffer (while not busy)
//
//   Commands:  1 ID     read the JEDEC ID
//              2 QUERY  read the record at REC_ADDR and check it (magic, version, its own
//                       CRC, the part); then the bitstream from 0 for the record's length
//                       and its CRC.  Sets `verified` on success.
//              3 ERASE  unlock, erase the record's block FIRST (so a load that stops early
//                       leaves no record), then the blocks covering FLASH_LEN bytes from 0.
//              5 READ   FLASH_LEN bytes from FLASH_ADDR: the CRC, and the first 256 in BUF.
//   Results:   0 OK  1 EXEC (see [4:2])  3 NO_RECORD  4 RECORD_CRC  5 IMAGE_CRC
//              6 BAD_PART  7 BAD_ARG  8 PAGE_REFUSED  9 BUSY
//
// FLASH_PAGE (host -> card, 0x40, len 65): [flash address] [64 data words, little-endian
// bytes].  Programmed when it arrives if nothing else is running, else refused and counted.
// The host sends one, then reads FLASH_PAGES until a count moves: stop-and-wait, so the
// receiver's lack of back-pressure never matters.  Any erase or page clears `verified`.
//
// THE RECORD, the first 64 bytes of the sector at REC_ADDR (the rest of it FF):
//   w0 magic 0x4B525753 ("SWRK")   w1 record version (1)   w2 bitstream length in bytes
//   w3 CRC32 of the bitstream       w4 IDCODE               w5 [7:0] board, [15:8] machine
//   w6 flash protocol version       w7 BUILD_DATE           w8 BUILD_TIME
//   w9..w14 zero                    w15 CRC32 of w0..w14 (60 bytes)
//////////////////////////////////////////////////////////////////////////////////

module flash_ctrl #(
    parameter logic [31:0] IDCODE       = 32'h13631093,  // xc7a100t
    parameter logic [23:0] IMAGE_END    = 24'h3FE000,    // the top 8 KB block holds the record
    parameter logic [23:0] REC_ADDR     = 24'h3FF000,
    parameter integer      HALF         = 2,
    parameter integer      TIMEOUT_CLKS = 10_000_000
) (
    input  wire         clk,
    input  wire         rst,
    input  wire  [7:0]  stage,          // BOOT_ID's stage: 1 bootstrap, 2 full operation

    // registers: a one-clock strobe, acknowledged two clocks later with the value after
    input  wire         wb_cyc,
    input  wire         wb_stb,
    input  wire         wb_we,
    input  wire  [31:0] wb_adr,
    input  wire  [31:0] wb_dat_w,
    output logic        wb_ack,
    output logic [31:0] wb_dat_r,

    // messages, from ft601_msg_rx
    input  wire         msg_valid,
    input  wire  [7:0]  msg_type,
    input  wire  [7:0]  msg_len,
    input  wire  [31:0] pay_data,
    input  wire         pay_valid,

    // the flash
    output wire         spi_sck,
    output wire         spi_cs_n,
    output wire         spi_mosi,
    input  wire         spi_miso,
    output wire         spi_wp_n,
    output wire         spi_hold_n
);
    localparam logic [7:0]  PROTO_VER    = 8'd1;
    localparam logic [7:0]  T_FLASH_PAGE = 8'h40;
    localparam logic [31:0] REC_MAGIC    = 32'h4B525753;
    localparam logic [31:0] REC_VERSION  = 32'd1;

    localparam logic [3:0] C_ID = 4'd1, C_QUERY = 4'd2, C_ERASE = 4'd3, C_READ = 4'd5;
    localparam logic [3:0] R_OK = 4'd0, R_EXEC = 4'd1, R_NO_RECORD = 4'd3,
                           R_RECORD_CRC = 4'd4, R_IMAGE_CRC = 4'd5, R_BAD_PART = 4'd6,
                           R_BAD_ARG = 4'd7, R_PAGE_REFUSED = 4'd8, R_BUSY = 4'd9;
    localparam logic [2:0] OP_ID = 3'd1, OP_UNLOCK = 3'd2, OP_ERASE = 3'd3, OP_PROG = 3'd4, OP_READ = 3'd5;

    // the chip's block map (flash_exec's, the datasheet's Figure 3-1)
    function automatic logic [23:0] block_size(input logic [23:0] a);
        if (a < 24'h008000 || a >= 24'h3F8000) return 24'h002000;
        if (a < 24'h010000 || a >= 24'h3F0000) return 24'h008000;
        return 24'h010000;
    endfunction
    function automatic logic [23:0] block_base(input logic [23:0] a);
        if (a < 24'h008000 || a >= 24'h3F8000) return {a[23:13], 13'd0};
        if (a < 24'h010000) return 24'h008000;
        if (a >= 24'h3F0000) return 24'h3F0000;
        return {a[23:16], 16'd0};
    endfunction

    // ---- the executor (the whole chip is the image's) ----------------------------------
    logic        x_valid;
    logic [2:0]  x_op;
    logic [23:0] x_addr, x_len;
    wire         x_busy, x_done;
    wire [2:0]   x_err;
    wire [23:0]  x_id;
    wire [31:0]  x_crc;
    logic        x_buf_we;
    logic [5:0]  x_buf_waddr;
    logic [31:0] x_buf_wdata;
    wire  [5:0]  x_buf_raddr;
    wire  [31:0] x_buf_rdata;

    flash_exec #(.HALF (HALF), .TIMEOUT_CLKS (TIMEOUT_CLKS),
                 .USER_BASE (24'h000000), .USER_END (24'h000000)) u_exec (   // END 0 = the whole chip
        .clk (clk), .rst (rst),
        .cmd_valid (x_valid), .cmd_op (x_op), .cmd_addr (x_addr), .cmd_len (x_len),
        .busy (x_busy), .done (x_done), .err (x_err), .id (x_id), .crc (x_crc),
        .buf_we (x_buf_we), .buf_waddr (x_buf_waddr), .buf_wdata (x_buf_wdata),
        .buf_raddr (x_buf_raddr), .buf_rdata (x_buf_rdata),
        .spi_sck (spi_sck), .spi_cs_n (spi_cs_n), .spi_mosi (spi_mosi), .spi_miso (spi_miso),
        .spi_wp_n (spi_wp_n), .spi_hold_n (spi_hold_n)
    );

    // ---- state ----------------------------------------------------------------
    typedef enum logic [3:0] {
        S_RESET, S_IDLE, S_ISSUE, S_WAIT, S_NEXT, S_PARSE, S_PAGE_WAIT, S_PAGE_IN, S_END
    } state_t;
    state_t      st;
    logic [3:0]  cmd;               // the command running (0 = a page)
    logic [2:0]  step;
    logic [3:0]  result;
    logic [2:0]  xerr;
    logic        verified;
    logic [7:0]  finished;
    logic [15:0] pages_ok, pages_refused;
    logic [23:0] flash_id;
    logic [31:0] last_crc, crc_rec;
    logic [23:0] reg_addr, reg_len;
    logic [23:0] blk;               // ERASE's next block
    logic [31:0] rec [0:15];
    logic [4:0]  parse_i;
    logic [23:0] page_addr;
    logic [6:0]  page_words;
    logic        page_taking;
    logic        ack_q;

    wire idle = (st == S_IDLE);

    // ---- registers --------------------------------------------------------------
    wire        wr     = wb_cyc && wb_stb && wb_we;
    wire [11:0] ra     = wb_adr[11:0];
    wire        cmd_w  = wr && (ra == 12'hF08);

    assign x_buf_raddr = (st == S_PARSE) ? {2'b00, parse_i[3:0]} : ra[7:2];

    logic [31:0] rd;
    always_comb begin
        rd = 32'd0;
        if (ra[11:8] == 4'hE) rd = idle ? x_buf_rdata : 32'd0;
        else if (ra[11:6] == 6'b1111_01) rd = rec[ra[5:2]];
        else case (ra)
            12'hF00: rd = {16'h424C, PROTO_VER, stage};
            12'hF04: rd = IDCODE;
            12'hF08: rd = {28'd0, cmd};
            12'hF0C: rd = {8'd0, reg_addr};
            12'hF10: rd = {8'd0, reg_len};
            12'hF14: rd = {8'd0, finished, 4'd0, result, 3'd0, xerr, verified, !idle};
            12'hF18: rd = {pages_refused, pages_ok};
            12'hF1C: rd = {8'd0, flash_id};
            12'hF20: rd = last_crc;
            12'hF24: rd = {8'd0, IMAGE_END};
            12'hF28: rd = {8'd0, REC_ADDR};
            default: rd = 32'd0;
        endcase
    end

    wire page_hdr = msg_valid && (msg_type == T_FLASH_PAGE);

    // ---- the sequencer ------------------------------------------------------------
    task automatic x_run(input logic [2:0] o, input logic [23:0] a, input logic [23:0] n);
        x_op <= o; x_addr <= a; x_len <= n; st <= S_ISSUE;
    endtask
    task automatic finish(input logic [3:0] r);
        result <= r; st <= S_END;
    endtask

    always_ff @(posedge clk) begin
        // Acknowledged a clock after the write lands, so the reply carries the value the
        // register holds AFTERWARDS (reg_bridge's contract).
        ack_q     <= wb_cyc && wb_stb;
        wb_ack    <= ack_q;
        wb_dat_r  <= rd;
        x_valid   <= 1'b0;
        x_buf_we  <= 1'b0;
        if (rst) begin
            st <= S_RESET; cmd <= '0; step <= '0; result <= R_OK; xerr <= '0; ack_q <= 1'b0;
            wb_ack <= 1'b0;
            verified <= 1'b0; finished <= '0; pages_ok <= '0; pages_refused <= '0;
            flash_id <= '0; last_crc <= '0; reg_addr <= '0; reg_len <= '0;
            page_taking <= 1'b0; page_words <= '0;
            for (int i = 0; i < 16; i++) rec[i] <= '0;
        end else begin
            if (wr && ra == 12'hF0C) reg_addr <= wb_dat_w[23:0];
            if (wr && ra == 12'hF10) reg_len  <= wb_dat_w[23:0];

            // a page's payload: word 0 the address, words 1..64 into the buffer
            if (page_taking && pay_valid) begin
                if (page_words == 7'd0) page_addr <= pay_data[23:0];
                else begin
                    x_buf_we    <= 1'b1;
                    x_buf_waddr <= 6'(page_words - 7'd1);
                    x_buf_wdata <= pay_data;
                end
                page_words <= page_words + 7'd1;
                if (page_words == 7'd64) begin
                    page_taking <= 1'b0;
                    st <= S_PAGE_IN;
                end
            end

            case (st)
            S_RESET: begin                      // read the ID once, so FLASH_ID is always there
                cmd <= C_ID; step <= '0;
                x_run(OP_ID, '0, '0);
            end
            S_IDLE: begin
                if (page_hdr) begin
                    if (msg_len == 8'd65) begin
                        page_taking <= 1'b1; page_words <= '0; verified <= 1'b0;
                        cmd <= 4'd0;
                        st <= S_PAGE_WAIT;
                    end else begin
                        pages_refused <= pages_refused + 16'd1;
                        result <= R_PAGE_REFUSED;
                    end
                end else if (cmd_w) begin
                    cmd <= wb_dat_w[3:0]; step <= '0; xerr <= '0;
                    case (wb_dat_w[3:0])
                    C_ID:    x_run(OP_ID, '0, '0);
                    C_QUERY: begin verified <= 1'b0; x_run(OP_READ, REC_ADDR, 24'd60); end
                    C_ERASE: begin
                        verified <= 1'b0;
                        if (reg_len == 24'd0 || reg_len > IMAGE_END) finish(R_BAD_ARG);
                        else begin blk <= block_base(REC_ADDR); x_run(OP_UNLOCK, '0, '0); end
                    end
                    C_READ:  x_run(OP_READ, reg_addr, reg_len);
                    default: finish(R_BAD_ARG);
                    endcase
                end
            end
            S_ISSUE: if (!x_busy) begin         // the executor takes a command only when idle
                x_valid <= 1'b1;
                st <= S_WAIT;
            end
            S_WAIT: if (x_done) begin
                if (x_err != 3'd0) begin
                    xerr <= x_err;
                    if (cmd == 4'd0) pages_refused <= pages_refused + 16'd1;
                    finish(R_EXEC);
                end else begin
                    last_crc <= x_crc;
                    if (x_op == OP_ID) flash_id <= x_id;
                    st <= S_NEXT;
                end
            end
            S_NEXT: begin
                step <= step + 3'd1;
                case (cmd)
                4'd0:    begin pages_ok <= pages_ok + 16'd1; finish(R_OK); end   // a page, programmed
                C_ID:    finish(R_OK);
                C_READ:  finish(R_OK);
                C_QUERY: case (step)
                    3'd0: begin crc_rec <= x_crc; x_run(OP_READ, REC_ADDR, 24'd64); end
                    3'd1: begin parse_i <= '0; st <= S_PARSE; end
                    default: begin               // the bitstream's CRC is in
                        if (x_crc != rec[3]) finish(R_IMAGE_CRC);
                        else begin verified <= 1'b1; finish(R_OK); end
                    end
                    endcase
                C_ERASE: begin
                    // after the unlock the record's block; then 0 upward until FLASH_LEN is covered
                    if (step == 3'd0) begin
                        x_run(OP_ERASE, blk, '0);
                        blk <= 24'd0;
                    end else if (blk < reg_len) begin
                        x_run(OP_ERASE, blk, '0);
                        blk <= blk + block_size(blk);
                    end else finish(R_OK);
                    if (step == 3'd7) step <= 3'd1;     // (keep counting past the first two)
                end
                default: finish(R_BAD_ARG);
                endcase
            end
            S_PARSE: begin                      // latch the record's 16 words, then judge them
                if (parse_i < 5'd16) begin
                    rec[parse_i[3:0]] <= x_buf_rdata;
                    parse_i <= parse_i + 5'd1;
                end else begin
                    if (rec[0] != REC_MAGIC || rec[1] != REC_VERSION) finish(R_NO_RECORD);
                    else if (crc_rec != rec[15])                      finish(R_RECORD_CRC);
                    else if (rec[4] != IDCODE)                        finish(R_BAD_PART);
                    else if (rec[2] == 32'd0 || rec[2] > {8'd0, IMAGE_END}) finish(R_NO_RECORD);
                    else x_run(OP_READ, 24'd0, rec[2][23:0]);
                end
            end
            S_PAGE_WAIT: ;                      // the page's words are arriving
            S_PAGE_IN: x_run(OP_PROG, page_addr, '0);
            S_END: begin
                finished <= finished + 8'd1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase

            if (cmd_w && !idle) result <= R_BUSY;
            if (page_hdr && !idle) pages_refused <= pages_refused + 16'd1;
        end
    end

endmodule
