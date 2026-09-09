`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// audio_tx - the samples to the host: AUDIO_FRAMES messages (docs/AUDIO.md).
//
// Three words a sample into a FIFO:
//
//   w0  {ay0[15:0], spk[15:0]}
//   w1  {ay2[15:0], ay1[15:0]}
//   w2  {seq[15:0], ay3[15:0]}     seq counts EVERY sample the sampler made
//
// and whenever SAMPLES_PER_MSG whole samples wait, one message through the
// message bus (rtl/msg_master.sv's word/valid/take):
//
//   header   {free = {drops[7:0], n[7:0]}, T_AUDIO_FRAMES, len = 3n}
//   payload  the 3n words
//
// A sample that arrives with no room for its three words is dropped whole:
// `drops` counts it and `seq` still advances, so the host sees the gap in
// the numbers and keeps its time base by playing that many frames of
// silence.  The FIFO takes DEPTH/4 samples - 128 at 512, 2.9 ms - which is
// longer than any reply or capture burst holds the bus, so the drops are for
// a link that is down, not for a busy one.
//
// The source is continuous but bounded by the wall clock - 1378 messages a
// second of 97 words at 44.1 kHz - which is the message arbiter's condition
// for a port above the capture (rtl/msg_arb.sv).
//////////////////////////////////////////////////////////////////////////////////
module audio_tx #(
    parameter integer SAMPLES_PER_MSG = 32,
    parameter integer DEPTH = 512
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,         // AUDIO_CTRL[0]

    input  wire        smp_valid,
    input  wire [15:0] smp_spk,
    input  wire [63:0] smp_ay,
    // The Ensoniq's stereo pair (rtl/gs_doc.sv), zero on the IIe build.
    input  wire [15:0] smp_doc_l,
    input  wire [15:0] smp_doc_r,

    // TO msg_master
    output wire [31:0] word,
    output wire        valid,
    input  wire        take,

    // AUDIO_STAT: [15:0] samples sent, [23:16] drops, [24] the FIFO full now
    output wire [31:0] stat
);

    localparam [7:0] T_AUDIO_FRAMES = 8'h2C;
    localparam integer WORDS_PER_MSG = 4 * SAMPLES_PER_MSG;
    localparam integer CW = $clog2(DEPTH + 1);

    // ---- the writer: FOUR words a sample -------------------------------------
    // It was three until the Ensoniq arrived (docs/GS.md rung 7).  The DOC is
    // stereo - the channel's low bit is the side - so its pair is a word of
    // its own, and the sequence number moves into it rather than growing a
    // fifth.  At 44.1 kHz that is 706 kB/s where it was 529, against a link
    // that runs at 335 MB/s (docs/PROTOCOL.md, host-load-model).
    logic [15:0] seq = 16'd0;
    logic [7:0]  drops = 8'd0;
    logic [31:0] w1_q, w2_q, w3_q;
    logic [2:0]  wr_left = 3'd0;        // words of the current sample still to write
    logic [31:0] fifo_din;
    logic        fifo_wr;
    wire         fifo_full;
    wire  [CW-1:0] fifo_count;
    wire         room = (fifo_count <= (CW)'(DEPTH - 8));

    // Samples committed to the FIFO, less samples sent: a message may start
    // when a whole message's worth is in.
    logic [CW-1:0] queued = '0;
    wire   sample_in  = (wr_left == 3'd1);          // the last word goes this clock
    logic  sample_out;                               // a whole message's samples left the FIFO

    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            seq     <= 16'd0;
            drops   <= 8'd0;
            wr_left <= 3'd0;
            fifo_wr <= 1'b0;
            queued  <= '0;
        end else begin
            fifo_wr <= 1'b0;
            if (smp_valid) begin
                seq <= seq + 16'd1;
                if (room && wr_left == 3'd0) begin
                    fifo_din <= {smp_ay[15:0], smp_spk};
                    fifo_wr  <= 1'b1;
                    w1_q     <= {smp_ay[47:32], smp_ay[31:16]};
                    w2_q     <= {smp_doc_l, smp_ay[63:48]};
                    w3_q     <= {seq, smp_doc_r};
                    wr_left  <= 3'd3;
                end else begin
                    drops <= drops + 8'd1;
                end
            end else if (wr_left != 3'd0) begin
                fifo_din <= (wr_left == 3'd3) ? w1_q :
                            (wr_left == 3'd2) ? w2_q : w3_q;
                fifo_wr  <= 1'b1;
                wr_left  <= wr_left - 3'd1;
            end
            case ({sample_in, sample_out})
                2'b10:   queued <= queued + 1'b1;
                2'b01:   queued <= queued - (CW)'(SAMPLES_PER_MSG);
                2'b11:   queued <= queued + 1'b1 - (CW)'(SAMPLES_PER_MSG);
                default: ;
            endcase
        end
    end

    wire [31:0] fifo_dout;
    wire        fifo_empty;
    logic       fifo_rd;

    sync_fifo #(.WIDTH (32), .DEPTH (DEPTH)) u_fifo (
        .clk   (clk),
        .rst   (rst || !enable),
        .din   (fifo_din),
        .wr_en (fifo_wr),
        .full  (fifo_full),
        .dout  (fifo_dout),
        .rd_en (fifo_rd),
        .empty (fifo_empty),
        .count (fifo_count)
    );

    // ---- the reader: one message at a time ------------------------------------
    logic       in_hdr = 1'b0, in_body = 1'b0;
    logic [7:0] left = 8'd0;
    logic [15:0] sent = 16'd0;

    wire [31:0] hdr = {drops, 8'(SAMPLES_PER_MSG), T_AUDIO_FRAMES, 8'(WORDS_PER_MSG)};

    assign word  = in_hdr ? hdr : fifo_dout;
    assign valid = in_hdr || (in_body && !fifo_empty);
    assign fifo_rd = in_body && take;
    assign sample_out = in_body && take && (left == 8'd1);

    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            in_hdr  <= 1'b0;
            in_body <= 1'b0;
            left    <= 8'd0;
            sent    <= 16'd0;
        end else begin
            if (!in_hdr && !in_body) begin
                if (queued >= (CW)'(SAMPLES_PER_MSG)) in_hdr <= 1'b1;
            end else if (in_hdr) begin
                if (take) begin
                    in_hdr  <= 1'b0;
                    in_body <= 1'b1;
                    left    <= 8'(WORDS_PER_MSG);
                end
            end else if (take) begin
                left <= left - 8'd1;
                if (left == 8'd1) begin
                    in_body <= 1'b0;
                    sent    <= sent + 16'(SAMPLES_PER_MSG);
                end
            end
        end
    end

    assign stat = {7'd0, fifo_full, drops, sent};

endmodule
