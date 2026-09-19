`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// reg_front - two masters in front of the register file (docs/TELEMETRY.md).
//
// The register Wishbone had one master, reg_bridge, since the day it was
// built.  The telemetry sender (rtl/telem_tx.sv) is the second: once a second
// it reads the whole map.  This is the door they share.
//
// REGISTERED, on purpose.  The register file's read mux has been the design's
// binding path twice, and its select is the address.  A combinational 2:1 in
// front of it would be one more level on that select; here the chosen address
// is a flop of this module's, exactly as it was a flop of the bridge's, so the
// mux sees what it always saw.  The cost is one clock on a bridge access
// (three where it was two), against a host round trip measured in hundreds of
// microseconds.
//
// THE BRIDGE WINS A TIE, and waits out a sweep.  The telemetry master asks
// with a level (t_req) and keeps the door for its whole sweep - a few hundred
// clocks - because a sample is one instant of the map and a host write landing
// in the middle of one would be in half of it.  The bridge is stalled
// meanwhile; it honours stall, and it has no timeout to trip.
//
// THE TELEMETRY PORT CANNOT WRITE: it has no write enable and no write data.
// The bridge's write data goes round this module's flops rather than through
// them - the bridge holds it steady from its strobe to its ack.
//
// t_req MAY DROP ONLY BETWEEN READS.  An ack that came home after the door had
// changed hands would be handed to the wrong master; the sender's FSM drops
// the request from a state with nothing outstanding.
//////////////////////////////////////////////////////////////////////////////////
module reg_front (
    input  wire        clk,
    input  wire        rst,

    // FROM reg_bridge: its Wishbone master, as the register file used to see it.
    input  wire        b_cyc,
    input  wire        b_stb,
    input  wire        b_we,
    input  wire [31:0] b_adr,
    output wire        b_ack,
    output wire        b_stall,

    // FROM the telemetry sender: reads only, a strobe and a register offset.
    input  wire        t_req,          // level: the door, for a whole sweep
    output wire        t_gnt,
    input  wire        t_stb,          // one clock per read, only while granted
    input  wire [15:0] t_off,          // byte offset within the register region
    output wire        t_ack,

    // TO wb_regfile.  Read data and write data do not pass through here.
    output logic       s_cyc,
    output logic       s_stb,
    output logic       s_we,
    output logic [31:0] s_adr,
    input  wire        s_ack
);

    localparam [15:0] REGION = 16'h8000;

    typedef enum logic [1:0] { F_IDLE, F_BRIDGE, F_TELEM } fstate_t;
    fstate_t state = F_IDLE;

    wire b_asks = b_cyc && b_stb;

    assign b_stall = (state != F_IDLE);
    assign b_ack   = s_ack && (state == F_BRIDGE);
    assign t_gnt   = (state == F_TELEM);
    assign t_ack   = s_ack && (state == F_TELEM);

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= F_IDLE;
            s_cyc <= 1'b0;
            s_stb <= 1'b0;
            s_we  <= 1'b0;
            s_adr <= 32'd0;
        end else begin
            // One clock of strobe per access: the register file acks the clock
            // after it sees one and must not see it twice.
            s_cyc <= 1'b0;
            s_stb <= 1'b0;
            case (state)
                F_IDLE: begin
                    if (b_asks) begin
                        s_cyc <= 1'b1;
                        s_stb <= 1'b1;
                        s_we  <= b_we;
                        s_adr <= b_adr;
                        state <= F_BRIDGE;
                    end else if (t_req) begin
                        state <= F_TELEM;
                    end
                end
                F_BRIDGE: if (s_ack) state <= F_IDLE;
                F_TELEM: begin
                    if (t_stb) begin
                        s_cyc <= 1'b1;
                        s_stb <= 1'b1;
                        s_we  <= 1'b0;
                        s_adr <= {REGION, t_off};
                    end
                    if (!t_req) state <= F_IDLE;
                end
                default: state <= F_IDLE;
            endcase
        end
    end

endmodule
