`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// tx_ring - the outgoing stream, through 32 MB of DDR3 on its way to the host.
//
// The slave on the message bus (msg_arb), and the source of the TX FIFO.
// Words are written in one side, a beat at a time, in wire format; they come
// out the other in the same order, and in between they live in one bank of
// the DDR3 as a ring of 16-byte lines: docs/TX_RING.md is the design, and
// docs/DDR3_USAGE.md the reasoning about the memory it leans on.
//
//   WB beats in -> packer -> staging FIFO -> WB writes -> [ bank 7 ] -> WB reads
//                                                     -> receive FIFO -> unpacker -> words out
//
// THE GUARD.  Message atomicity is the bus's: a master holds CYC from header
// to last ack and the arbiter does not switch under it.  This module still
// snoops the length out of every header, for two reasons.  It needs the
// boundary itself, to know where padding may go; and a master that drops CYC
// with payload still owed has torn a message, which the host will read as
// plausible nonsense from then on.  That cannot happen - and when it does it
// is flagged, sticky, in the status word and on the UART, so that whatever
// let it happen can be found.
//
// WHOLE LINES ONLY.  The writer never issues a partial burst: one 16-byte
// write per line, no byte enables, strictly sequential so the bank's open row
// serves 128 lines before it has to change.  A message tail that leaves the
// packer holding a partial line is PADDED with IDLE words - 0x00000000, the
// header-only filler PROTOCOL.md already defines and the heartbeat already
// uses - once it has waited FLUSH_TICKS with nothing more arriving.  Only at
// a message boundary: inside a message the next word is coming by definition
// (PROTOCOL.md case 8), so the packer simply waits for it.  A maximum-size
// message is 64 lines exactly, so a stream of them is never padded at all.
//
// TWO CLIENTS OF wb_arb, one each way, and each works in BATCHES: the writer
// asks for the port with BATCH lines staged (or fewer, once they have waited),
// the reader with data to read AND room for a batch of it.  Reader and writer
// are rows apart in the same bank, so every hand-over between them costs a row
// change plus a read<->write turnaround; batching pays that once per BATCH
// lines instead of once per line.
//
// THE READER ONLY READS WHAT HAS BEEN ACKED.  `committed` counts the writer's
// acks, in order, one line each; the reader's view of the ring ends there.
// UberDDR3 issues in order, so this is more conservative than it needs to be,
// and it is the statement that does not depend on that.
//
// RESET DOES NOT CANCEL A REQUEST.  A Wishbone request accepted cannot be
// taken back, and the controller aborts every outstanding ack the moment cyc
// drops.  So on the link's reset both sides stop issuing, keep their cyc up
// until their acks are home, and only then let the pointers go to zero - and
// they do that on their own clock, not the reset's: the ring stays DRAINING
// until the last ack of EITHER side is in, however short the reset was, and
// acks that arrive while draining count for nothing.  Both sides, together:
// a reader that zeroed its pointer while the writer was still draining would
// see the writer's old `committed` as readable and replay lines nobody sent.
// The link's reset lasts a millisecond and a batch drains in a microsecond,
// so in practice the ring is empty and the port quiet long before the reset
// lets go; the drain is what makes that a convenience rather than a
// requirement.
//
// Pointers are line indices with one wrap bit above them, so full and empty
// tell apart.  The bank field is a constant: the ring cannot evict another
// client's row, except through the anticipation leak DDR3_USAGE.md describes.
//////////////////////////////////////////////////////////////////////////////////
module tx_ring #(
    parameter [2:0]   BANK        = 3'd7,
    parameter integer BATCH       = 64,     // lines per grant; 64 = 1 KB = one FT601 buffer
    parameter integer FLUSH_TICKS = 100,    // 1 us at 100 MHz
    parameter integer STAGE_DEPTH = 256,    // lines of write-side staging (4 KB)
    parameter integer RECV_DEPTH  = 256,    // lines of read-side receive  (4 KB)
    parameter integer ADDR_BITS   = 24,
    parameter integer DATA_BITS   = 128,
    parameter integer DRAIN_TICKS = 10_000_000  // 100 ms at 100 MHz: the drain's patience
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 calib_complete,

    // FROM the message bus: a pipelined Wishbone slave.  Every beat is a
    // word of the stream; the address and select are accepted and ignored.
    input  wire                 s_cyc,
    input  wire                 s_stb,
    input  wire                 s_we,
    input  wire [31:0]          s_adr,
    input  wire [31:0]          s_dat,
    input  wire [3:0]           s_sel,
    output wire                 s_stall,
    output logic                s_ack,

    // TO the TX FIFO
    output wire [31:0]          out_word,
    output wire                 out_valid,
    input  wire                 out_take,

    // wb_arb client 0: the reader
    output wire                 rd_req,
    input  wire                 rd_gnt,
    output wire                 rd_cyc,
    output logic                rd_stb,
    output wire [ADDR_BITS-1:0] rd_addr,
    input  wire                 rd_stall,
    input  wire                 rd_ack,
    input  wire [DATA_BITS-1:0] rd_data,

    // wb_arb client 1: the writer
    output wire                 wr_req,
    input  wire                 wr_gnt,
    output wire                 wr_cyc,
    output logic                wr_stb,
    output wire [ADDR_BITS-1:0] wr_addr,
    output wire [DATA_BITS-1:0] wr_data,
    input  wire                 wr_stall,
    input  wire                 wr_ack,

    // RING_STATUS: [21:0] occupancy in lines, [24] full, [25] calibrated,
    // [26] a message was torn (sticky until reset)
    output wire [31:0]          status
);

    // ---- geometry -----------------------------------------------------------
    // 14 row bits + 7 column bits of lines in one bank.
    localparam integer LINE_BITS = ADDR_BITS - 3;           // 21
    localparam integer PW        = LINE_BITS + 1;           // pointers, with a wrap bit
    localparam [PW-1:0] RING_LINES = PW'(1) << LINE_BITS;  // 2^21

    function automatic [ADDR_BITS-1:0] line_addr(input [PW-1:0] p);
        line_addr = {p[LINE_BITS-1:7], BANK, p[6:0]};
    endfunction

    localparam integer BW = $clog2(BATCH + 1);
    localparam integer FW = $clog2(FLUSH_TICKS + 1);

    // The three pointers.  wptr: next line the writer issues.  committed: lines
    // the writer has had acked, which is where the reader's world ends.  rptr:
    // next line the reader issues.
    logic [PW-1:0] wptr      = '0;
    logic [PW-1:0] committed = '0;
    logic [PW-1:0] rptr      = '0;

    // The drain: reset seen, acks still out on one side or the other.  Both
    // sides' pointers go to zero on the same edge, once both are idle.
    logic drain = 1'b0;
    wire  wr_idle, rd_idle;
    // THE DRAIN'S TIMEOUT (docs/CLEAN_START.md CS5).  A drain waits for every
    // ack still out to come home, and a batch drains in a microsecond - but an
    // ack that never comes (a lost one, a controller that stopped answering)
    // used to hold the ring in the drain until the FPGA was configured again,
    // silently, and every register reply with it.  After DRAIN_TICKS the ring
    // gives up on it: both outstanding counts go to zero, the pointers with
    // them, and the timeouts are counted in STATUS.  An ack that turns up
    // later is ignored (the counts only ever count down from above zero).
    localparam integer DW = $clog2(DRAIN_TICKS + 1);
    logic [DW-1:0] drain_cnt      = '0;
    logic [3:0]    drain_timeouts = 4'd0;
    wire  force_idle = drain && (drain_cnt == DRAIN_TICKS[DW-1:0]);
    wire  all_idle   = (wr_idle && rd_idle) || force_idle;
    always_ff @(posedge clk) begin
        if (rst || drain) drain <= !all_idle;
        if (!drain)                                drain_cnt <= '0;
        else if (drain_cnt != DRAIN_TICKS[DW-1:0]) drain_cnt <= drain_cnt + 1'b1;
        if (force_idle && drain_timeouts != 4'hF)  drain_timeouts <= drain_timeouts + 4'd1;
    end

    wire [PW-1:0] occupancy = wptr - rptr;          // issued, not yet read
    wire [PW-1:0] readable  = committed - rptr;     // acked, not yet read
    wire [PW-1:0] room      = RING_LINES - occupancy;

    // =========================================================================
    // The write side
    // =========================================================================

    // ---- packer -------------------------------------------------------------
    logic [DATA_BITS-1:0] pack  = '0;
    logic [1:0]           wc    = 2'd0;     // words in the partial line
    logic [7:0]           left  = 8'd0;     // payload words owed by the current message
    logic [FW-1:0]        flush = '0;       // cycles the partial line has waited
    logic                 padding = 1'b0;

    wire at_boundary = (left == 8'd0);

    wire                  stage_full, stage_empty;
    wire [DATA_BITS-1:0]  stage_dout;
    logic                 stage_rd;
    wire [$clog2(STAGE_DEPTH+1)-1:0] stage_count;

    // Take a beat when there is a line's worth of room to put it in and the
    // memory is there to write it to.  Padding takes the packer over.  A read
    // beat is accepted and acked and carries nothing; the bus is a stream.
    wire can_pack = !rst && !drain && calib_complete && !stage_full;
    assign s_stall = !(can_pack && !padding);

    wire s_accept = s_cyc && s_stb && !s_stall;
    wire in_take  = s_accept && s_we;
    wire [31:0] in_word = s_dat;

    always_ff @(posedge clk) s_ack <= !rst && s_accept;

    // Torn: CYC dropped with payload still owed.  The arbiter puts a
    // CYC-low bubble between bursts, so this is exact.  The count restarts
    // at the next header - the stream is wrong from here anyway, and a
    // packer waiting forever for words that are not coming would only add a
    // second failure to the first.
    logic torn = 1'b0;
    wire  tear = !s_cyc && !at_boundary;

    wire pack_word  = in_take || (can_pack && padding);
    wire [31:0] pw  = padding ? 32'h0000_0000 : in_word;
    wire line_done  = pack_word && (wc == 2'd3);

    // What goes into the staging FIFO on the fourth word: the three held plus
    // the one arriving.
    wire [DATA_BITS-1:0] line_in = {pw, pack[95:0]};

    wire flush_due = (flush >= FW'(FLUSH_TICKS));

    always_ff @(posedge clk) begin
        if (rst || drain) begin
            pack    <= '0;
            wc      <= 2'd0;
            left    <= 8'd0;
            flush   <= '0;
            padding <= 1'b0;
            torn    <= 1'b0;
        end else begin
            if (pack_word) begin
                pack[wc*32 +: 32] <= pw;
                wc <= wc + 2'd1;
            end

            // Message boundary follows the real words, not the padding: an
            // IDLE word is a header owing nothing, so it leaves `left` alone.
            if (tear) begin
                left <= 8'd0;
                torn <= 1'b1;
            end else if (in_take) begin
                if (at_boundary) left <= in_word[7:0];
                else             left <= left - 8'd1;
            end

            // The wait for the rest of a line starts over on every word, and
            // does not run at all with nothing to flush.
            if (pack_word || (wc == 2'd0)) flush <= '0;
            else if (!flush_due)           flush <= flush + 1'b1;

            // Pad from a boundary once the wait is up, until the line is out.
            // Only with nothing on offer: a word waiting on staging room is
            // still the next word, and it may be a header - padding ahead of
            // it would be padding inside its message.
            if (line_done)                                   padding <= 1'b0;
            else if (!padding && flush_due && at_boundary && wc != 2'd0 && !(s_cyc && s_stb))
                                                             padding <= 1'b1;
        end
    end

    // ---- staging ------------------------------------------------------------
    sync_fifo #(.WIDTH (DATA_BITS), .DEPTH (STAGE_DEPTH)) u_stage (
        .clk (clk), .rst (rst || drain),
        .din (line_in), .wr_en (line_done), .full (stage_full),
        .dout (stage_dout), .rd_en (stage_rd), .empty (stage_empty),
        .count (stage_count)
    );

    // ---- issuing writes -------------------------------------------------------
    // Ask for the port with a batch staged, or with anything staged that has
    // waited.  Only ever with room in the ring for the whole batch, so a
    // batch never has to stop part way.
    logic [FW-1:0] stage_idle = '0;
    wire  stage_waited = (stage_idle >= FW'(FLUSH_TICKS));

    logic          wr_busy  = 1'b0;      // holding the port, issuing
    logic [BW-1:0] wr_todo  = '0;        // lines still to issue this batch
    logic [BW:0]   wr_out   = '0;        // issued, not yet acked
    logic          wr_asked = 1'b0;      // req raised and not yet granted
    logic          wr_pause = 1'b0;      // the cycle after a batch: let go

    // `want` can lapse between asking and being granted - a new line resets
    // the wait - so once asked, stay asked: the arbiter must never grant a
    // client that has changed its mind, and what is staged only grows.
    wire wr_want = (32'(stage_count) >= BATCH) || (!stage_empty && stage_waited);
    wire wr_ask  = (wr_want || wr_asked) && (room >= PW'(BATCH));
    assign wr_req = !rst && !drain && calib_complete && !wr_pause &&
                    (wr_busy ? (wr_todo != '0) : wr_ask);

    assign wr_cyc  = wr_busy || (wr_out != '0);
    assign wr_addr = line_addr(wptr);
    assign wr_data = stage_dout;

    wire wr_accept = wr_stb && !wr_stall;
    assign stage_rd = wr_accept;
    assign wr_idle  = (wr_out == '0) || (wr_ack && wr_out == 1);

    always_ff @(posedge clk) begin
        // Acks are counted through a reset: cyc must stay up until they are
        // home, and the pointers may only go once nothing is in flight.
        if (force_idle)                                wr_out <= '0;
        else if (wr_ack && !wr_accept && wr_out != '0) wr_out <= wr_out - 1'b1;
        else if (wr_accept && !wr_ack)                 wr_out <= wr_out + 1'b1;

        if (rst || drain) begin
            wr_busy    <= 1'b0;
            wr_todo    <= '0;
            wr_stb     <= 1'b0;
            wr_asked   <= 1'b0;
            wr_pause   <= 1'b0;
            stage_idle <= '0;
            // Zero the pointers only once nothing is in flight on either
            // side; until then stay draining, reset or no reset.
            if (all_idle) begin
                wptr      <= '0;
                committed <= '0;
            end
        end else begin
            if (wr_ack) committed <= committed + 1'b1;

            if (line_done || stage_empty) stage_idle <= '0;
            else if (!stage_waited)       stage_idle <= stage_idle + 1'b1;

            wr_pause <= 1'b0;

            if (!wr_busy) begin
                // A grant counts only while we are asking: the arbiter still
                // shows it for the cycle after a batch, when what is staged
                // may be nothing, and a batch of nothing never ends.
                if (wr_gnt && wr_req) begin
                    // Granted.  The batch is what is staged, up to BATCH; we
                    // only asked with room in the ring for all of it.
                    wr_busy  <= 1'b1;
                    wr_asked <= 1'b0;
                    wr_todo  <= (32'(stage_count) >= BATCH) ? BW'(BATCH) : BW'(stage_count);
                    wr_stb   <= 1'b1;
                end else if (wr_req) begin
                    wr_asked <= 1'b1;
                end
            end else begin
                if (wr_accept) begin
                    wptr <= wptr + 1'b1;
                    if (wr_todo == BW'(1)) begin
                        // Batch done: let the port go for a cycle, so the
                        // arbiter's rotation gets its turn.
                        wr_stb   <= 1'b0;
                        wr_busy  <= 1'b0;
                        wr_todo  <= '0;
                        wr_pause <= 1'b1;
                    end else begin
                        wr_todo <= wr_todo - 1'b1;
                    end
                end
            end
        end
    end

    // =========================================================================
    // The read side
    // =========================================================================

    wire                  recv_full, recv_empty;
    wire [DATA_BITS-1:0]  recv_dout;
    logic                 recv_rd;
    wire [$clog2(RECV_DEPTH+1)-1:0] recv_count;

    logic          rd_busy  = 1'b0;
    logic [BW-1:0] rd_todo  = '0;
    logic [BW:0]   rd_out   = '0;       // issued, not yet acked
    logic          rd_pause = 1'b0;

    // Room in the receive FIFO must cover what is already in flight as well
    // as the batch about to be asked for: an ack with nowhere to land is a
    // lost line, and sync_fifo drops on full without a word.  Both terms only
    // move the right way between asking and being granted - an ack moves a
    // line from in-flight to counted, the unpacker only ever frees - so this
    // needs no latch the way the writer's does.
    wire recv_room = (32'(recv_count) + 32'(rd_out) + BATCH <= RECV_DEPTH);

    wire rd_want = (readable != '0) && recv_room;
    assign rd_req = !rst && !drain && calib_complete && !rd_pause &&
                    (rd_busy ? (rd_todo != '0) : rd_want);

    assign rd_cyc  = rd_busy || (rd_out != '0);
    assign rd_addr = line_addr(rptr);

    wire rd_accept = rd_stb && !rd_stall;
    assign rd_idle = (rd_out == '0) || (rd_ack && rd_out == 1);

    always_ff @(posedge clk) begin
        if (force_idle)                                rd_out <= '0;
        else if (rd_ack && !rd_accept && rd_out != '0) rd_out <= rd_out - 1'b1;
        else if (rd_accept && !rd_ack)                 rd_out <= rd_out + 1'b1;

        if (rst || drain) begin
            rd_busy  <= 1'b0;
            rd_todo  <= '0;
            rd_stb   <= 1'b0;
            rd_pause <= 1'b0;
            if (all_idle) rptr <= '0;
        end else begin
            rd_pause <= 1'b0;
            if (!rd_busy) begin
                if (rd_gnt && rd_req) begin
                    rd_busy <= 1'b1;
                    rd_todo <= (readable >= PW'(BATCH)) ? BW'(BATCH) : BW'(readable);
                    rd_stb  <= 1'b1;
                end
            end else begin
                if (rd_accept) begin
                    rptr <= rptr + 1'b1;
                    if (rd_todo == BW'(1)) begin
                        rd_stb   <= 1'b0;
                        rd_busy  <= 1'b0;
                        rd_todo  <= '0;
                        rd_pause <= 1'b1;
                    end else begin
                        rd_todo <= rd_todo - 1'b1;
                    end
                end
            end
        end
    end

    // ---- receive ------------------------------------------------------------
    // Acks arriving during a reset, or the drain that follows one, are
    // discarded - which is what a reset means for what was queued.  The FIFO
    // itself is held in reset for the whole of it, so nothing stale is left
    // behind for the unpacker.
    sync_fifo #(.WIDTH (DATA_BITS), .DEPTH (RECV_DEPTH)) u_recv (
        .clk (clk), .rst (rst || drain),
        .din (rd_data), .wr_en (rd_ack && !rst && !drain), .full (recv_full),
        .dout (recv_dout), .rd_en (recv_rd), .empty (recv_empty),
        .count (recv_count)
    );

    // ---- unpacker -------------------------------------------------------------
    // Low word first: the order the packer put them in.
    logic [1:0] uc = 2'd0;

    assign out_word  = recv_dout[uc*32 +: 32];
    assign out_valid = !recv_empty;
    wire   out_go    = out_valid && out_take;
    assign recv_rd   = out_go && (uc == 2'd3);

    always_ff @(posedge clk) begin
        if (rst || drain) uc <= 2'd0;
        else if (out_go)     uc <= uc + 2'd1;
    end

    // ---- status ---------------------------------------------------------------
    // Occupancy is placed explicitly, whatever width the pointers are: the
    // bank's 2^21 lines need 22 bits, a smaller ring in a testbench fewer.
    wire        ring_full = (room < PW'(BATCH));
    wire [31:0] occ_ext   = 32'(occupancy);
    assign status = {1'd0, drain_timeouts, torn, calib_complete, ring_full, 2'd0, occ_ext[21:0]};

    wire _unused_ok = &{1'b0, recv_full, s_adr, s_sel, 1'b0};

endmodule
