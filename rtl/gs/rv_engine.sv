`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// rv_engine - the RISC-V engine as the 65816 sees it (docs/REQ_RVVM.md
// section 9): rtl/gs/rv_core.sv behind its window page, `$EF:FE00`-`$EF:FEFF`.
//
// THE WINDOW, a byte bus with TWO FACES, as gs_io has (gs_top: the claim on
// the live address, the byte and the side effects on the registered op):
//   * PRESENTED - pre_sel/pre_rw/pre_off: the 65816's data cycle as it waits
//     to be decided.  A STEP read presented steps the engine (once) and
//     win_stall holds it until the result is in; the step re-arms when the
//     presented cycle is no longer a STEP read.
//   * SERVED - srv_sel/srv_rw/srv_off/srv_wdata: the op being served;
//     win_rdata answers its read (combinational on srv_off), and srv_act says
//     it retires now, when a write is applied.
// The sim harness (sim/rvvm_sys.sv) drives both faces from its one live bus.
//
//   +00-+7F  x0-x31, 4 bytes each, little-endian      R/W
//   +80-+83  pc                                        R/W
//   +84      STEP: executes one instruction; the result code    R (side effect)
//   +85      RUN: executes until an event or a yield; the result code (0 = yielded)  R (side effect)
//   +86      RESUME: any write finishes the pending event        W
//   +88-+8B  ev_addr (tval, the effective address, the pc)       R
//   +8C-+8F  ev_iw (the event's instruction)                     R
//   +90-+93  ev_data (a delegated store's value)                 R
//   +94-+97  the resume value (a delegated load's, a fetch's)    R/W
//   +98-+9B  the ID: "RVE" and the version, 2 (RUN)              R
//   +9C      status: bit 0 busy, bit 1 an event pending          R
//   +A4,+A5  the RUN slice: clocks per read before a yield (4096) R/W
// A register, the pc and the resume value are written in 16-bit halves: the
// even byte is latched and the odd byte commits the half (so a 16-bit STA -
// low byte first - lands whole).  A register or pc write cancels a
// speculation (rv_core).
//
// THE MEMORY SIDE.  MEM = 0 (integration rung 1): the VM - every fetch, load
// and store is delegated, the engine never touches memory itself.  MEM = 1:
// rtl/gs/rv_mem.sv on the L2's ports (il_*, dr_*, the eviction broadcast and
// the placement report), serving what the machine's map makes engine-direct (rv_mem.sv) -
// with DIRECT_WRITES = 0 (rung 3a) stores are still delegated.  `cancel` (a
// 65816 write outside the window) cancels a speculation and empties the row
// buffers; `inval` (anything else that writes guest memory) empties them.
//
// RUN (REQ_RVVM "RUN"): the read stalls while the engine retires instruction
// after instruction, and ends with an event's code - or with 0 when the run
// YIELDS at an instruction boundary: `irq_yield` (an interrupt the 65816 would
// take is pending; it cannot while stalled inside the read) or the slice
// spent.  At least one instruction retires per read.  Every retired
// instruction is one op to the governor: a write-back waits for `gov_ok` (its
// token) and `gov_pay` pulses as it commits - STEP's included.
//////////////////////////////////////////////////////////////////////////////////
module rv_engine #(
    parameter integer MEM = 0,
    parameter integer DIRECT_WRITES = 0,
    parameter integer SIDX = 4,
    parameter integer LEV  = 3,
    parameter integer SLICE0 = 4096,    // the RUN slice at reset (+A4/+A5)
    parameter integer TN     = 4,       // rv_mem's page -> {set, way} table: entries
    parameter integer AW     = 25       // the address space: 25 = the whole 32 MB bank (rv_pipe, rv_mem)
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         pre_sel,
    input  wire         pre_rw,
    input  wire  [7:0]  pre_off,
    input  wire         srv_sel,
    input  wire         srv_rw,
    input  wire  [7:0]  srv_off,
    input  wire  [7:0]  srv_wdata,
    input  wire         srv_act,
    output logic [7:0]  win_rdata,
    output wire         win_stall,
    input  wire         cancel,
    input  wire  [23:0] wsn_a,          // cancel's write: where (rv_mem drops the row it names)
    input  wire         inval,
    output wire         retired,        // a pulse per retired instruction (counters, the harness's lockstep)
    input  wire         irq_yield,      // an interrupt the 65816 would take is pending: RUN yields
    input  wire         gov_ok,         // the governor's token is there: a write-back may commit
    output wire         gov_pay,        // ...and one did: charge the governor one op
    // the L2 (MEM = 1)
    output wire             il_req,
    output wire  [AW-9:0]   il_ppn,
    output wire  [3:0]      il_line,
    output wire             il_fill,
    input  wire             il_ack,
    input  wire             il_done,
    input  wire             il_ok,
    input  wire  [127:0]    il_row,
    input  wire  [SIDX-1:0] il_set,
    input  wire  [LEV-1:0]  il_way,
    output wire             dr_req,
    output wire  [SIDX-1:0] dr_set,
    output wire  [LEV-1:0]  dr_way,
    output wire  [3:0]      dr_line,
    input  wire             dr_ack,
    input  wire             dr_done,
    input  wire  [127:0]    dr_row,
    input  wire             op_place_v,
    input  wire  [AW-9:0]   op_place_ppn,
    input  wire             evict_v,
    input  wire  [SIDX-1:0] evict_set,
    input  wire  [LEV-1:0]  evict_way,
    output wire             pw_req,
    output wire  [AW-3:0]   pw_addr,
    output wire  [3:0]      pw_be,
    output wire  [31:0]     pw_data,
    input  wire             pw_ack,
    output wire             ref_v,
    output wire             ref_on,
    output wire  [SIDX-1:0] ref_set,
    output wire  [LEV-1:0]  ref_way,
    output wire             rec_v,          // the engine-write record (tag 0xB), held until...
    output wire  [63:0]     rec,
    input  wire             rec_take        // ...the event stream takes it
);
    localparam logic [7:0] O_PC = 8'h80, O_STEP = 8'h84, O_RESUME = 8'h86, O_EVADDR = 8'h88,
                           O_EVIW = 8'h8C, O_EVDATA = 8'h90, O_RVAL = 8'h94, O_ID = 8'h98,
                           O_STAT = 8'h9C,
                           O_RUN = 8'h85, O_SLICE = 8'hA4;

    // ---- the core -------------------------------------------------------------
    logic        step, resume, w_en, pc_we, run;
    logic [31:0] resume_val, w_val, pc_wval;
    logic [4:0]  rsel, w_sel;
    wire  [31:0] rval, pc, ev_addr, ev_data, ev_iw;
    wire         busy;
    wire  [7:0]  result;
    wire         f_req, d_req, d_we, req_spec;
    wire         f_valid, f_delegate, f_abort, d_valid, d_delegate, d_abort;
    wire  [31:0] f_data, d_rdata, pk_word;
    wire  [AW-3:0] pk_addr, d_pre, f_pre;
    wire         pk_use;
    wire         wr_busy;       // rv_mem: a posted store not yet landed
    wire         pk_hit;
    wire  [AW-3:0] f_addr, d_addr;
    wire  [3:0]  d_be;
    wire  [31:0] d_wdata;

    rv_pipe #(.AW (AW)) u_core (
        .clk (clk), .rst (rst),
        .step (step), .cancel (cancel), .resume (resume), .resume_val (resume_val),
        .run (run), .hold (!gov_ok), .paid (gov_pay),
        .busy (busy), .retired (retired), .result (result), .ev_addr (ev_addr), .ev_data (ev_data), .ev_iw (ev_iw),
        .rsel (rsel), .rval (rval), .w_en (w_en), .w_sel (w_sel), .w_val (w_val),
        .pc_we (pc_we), .pc_wval (pc_wval), .pc (pc),
        .f_req (f_req), .f_addr (f_addr), .f_pre (f_pre), .req_spec (req_spec),
        .f_valid (f_valid), .f_delegate (f_delegate), .f_abort (f_abort), .f_data (f_data),
        .pk_addr (pk_addr), .pk_use (pk_use), .pk_hit (pk_hit), .pk_word (pk_word),
        .d_req (d_req), .d_we (d_we), .d_addr (d_addr), .d_pre (d_pre), .d_be (d_be), .d_wdata (d_wdata),
        .d_valid (d_valid), .d_delegate (d_delegate), .d_abort (d_abort), .d_rdata (d_rdata)
    );

    // THE 65816'S SIDE, A CLOCK LATE: the write snoop (cancel, wsn_a) and the
    // invalidations reach the memory side through a register.  Combinational,
    // they put the 65816's whole cycle decision in front of the engine's caches
    // (29 levels, gs_rvicache2).  The 65816 writes only while the engine stands
    // (outside a STEP/RUN read, or held in one), so a snoop a clock late still
    // lands before the engine's next access; a DMA racing a running engine is a
    // race whatever the latency, and the driver orders it.
    logic        wsn_v_q, inval_q;
    logic [23:0] wsn_a_q;
    always_ff @(posedge clk) begin
        wsn_v_q <= !rst && cancel;
        inval_q <= !rst && inval;
        wsn_a_q <= wsn_a;
    end

    // The engine-direct bank range: the window's registers, rv_mem's permission map
    // (declared ahead of the generate that names it - Vivado resolves no forward
    // reference into a generate scope).

    generate if (MEM != 0) begin : g_mem
        rv_mem #(.SIDX (SIDX), .LEV (LEV), .DIRECT_WRITES (DIRECT_WRITES), .TN (TN), .AW (AW)) u_mem (
            .clk (clk), .rst (rst), .all_deleg (1'b0), .wsn_v (wsn_v_q), .wsn_a (wsn_a_q), .inval (inval_q),
            .req_spec (req_spec),
            .f_req (f_req), .f_addr (f_addr), .f_pre (f_pre), .f_valid (f_valid), .f_delegate (f_delegate), .f_abort (f_abort), .f_data (f_data),
            .pk_addr (pk_addr), .pk_use (pk_use), .pk_hit (pk_hit), .pk_word (pk_word),
            .d_req (d_req), .d_we (d_we), .d_addr (d_addr), .d_pre (d_pre), .d_be (d_be), .d_wdata (d_wdata),
            .d_valid (d_valid), .d_delegate (d_delegate), .d_abort (d_abort), .d_rdata (d_rdata),
            .il_req (il_req), .il_ppn (il_ppn), .il_line (il_line), .il_fill (il_fill), .il_ack (il_ack), .il_done (il_done),
            .il_ok (il_ok), .il_row (il_row), .il_set (il_set), .il_way (il_way),
            .dr_req (dr_req), .dr_set (dr_set), .dr_way (dr_way), .dr_line (dr_line),
            .dr_ack (dr_ack), .dr_done (dr_done), .dr_row (dr_row),
            .op_place_v (op_place_v), .op_place_ppn (op_place_ppn),
            .pw_req (pw_req), .pw_addr (pw_addr), .pw_be (pw_be), .pw_data (pw_data), .pw_ack (pw_ack),
            .evict_v (evict_v), .evict_set (evict_set), .evict_way (evict_way),
            .ref_v (ref_v), .ref_on (ref_on), .ref_set (ref_set), .ref_way (ref_way),
            .rec_v (rec_v), .rec (rec), .rec_take (rec_take), .wr_busy (wr_busy)
        );
    end else begin : g_delegate
        // Rung 1: the memory side delegates everything, at once.
        assign f_valid = f_req;  assign f_delegate = 1'b1; assign f_abort = 1'b0; assign f_data = 32'd0;
        assign pk_hit = 1'b0;    assign pk_word = 32'd0;
        assign d_valid = d_req;  assign d_delegate = 1'b1; assign d_abort = 1'b0; assign d_rdata = 32'd0;
        assign il_req = 1'b0; assign il_ppn = '0; assign il_line = 4'd0; assign il_fill = 1'b0;
        assign dr_req = 1'b0; assign dr_set = '0; assign dr_way = '0; assign dr_line = 4'd0;
        assign pw_req = 1'b0; assign pw_addr = '0; assign pw_be = 4'd0; assign pw_data = 32'd0;
        assign ref_v = 1'b0; assign ref_on = 1'b0; assign ref_set = '0; assign ref_way = '0;
        assign rec_v = 1'b0; assign rec = 64'd0; assign wr_busy = 1'b0;
    end endgenerate

    // ---- the window's own registers -----------------------------------------
    logic [7:0]  lo_latch;          // the even byte of a half being written
    logic [31:0] rval_q;            // the resume value
    logic        armed;             // the STEP read in progress has stepped the core
    logic [15:0] slice;             // RUN: clocks per read before a yield
    logic [15:0] run_clk;           // ...spent by the read in progress

    wire [7:0] win_off = srv_off;                      // the served face's register
    wire is_reg  = win_off[7] == 1'b0;                 // +00-+7F
    wire is_pc   = win_off[7:2] == O_PC[7:2];
    wire is_rval = win_off[7:2] == O_RVAL[7:2];
    wire step_rd = pre_sel && pre_rw && (pre_off == O_STEP || pre_off == O_RUN);
    wire run_rd  = pre_sel && pre_rw && pre_off == O_RUN;

    // THE STEP: fire on the read's first appearance, hold it until the core
    // has its answer.  The clock after a step, busy is up if there is work
    // left, and `result` is already the answer if there is not (a parked
    // speculation commits on the step's own clock).
    assign step = step_rd && !armed;
    // (and until rv_mem's posted store has landed: the VM must not meet a copy of
    // memory the engine's last store has not reached yet - REQ_RVVM, the posted store)
    assign win_stall = step_rd && (!armed || busy || wr_busy);
    always_ff @(posedge clk) begin
        if (rst) armed <= 1'b0;
        else     armed <= step_rd;          // re-armed once no STEP read is presented
    end
    // RUN: keep going while the read stands, nothing asks for a yield and the
    // slice is not spent (counted from the read's first clock).
    always_ff @(posedge clk)
        run_clk <= (rst || !run_rd) ? 16'd0 : (run_clk == 16'hFFFF ? run_clk : run_clk + 16'd1);
    // (through a register: `run` comes from the presented read, and so from the
    // 65816's address - an override's bank included - which is not a thing to put
    // in front of the pipe's fetch; a yield lands a clock later, one fetch more)
    logic run_q;
    always_ff @(posedge clk) run_q <= !rst && run_rd && !irq_yield && (run_clk < slice);
    assign run = run_q;

    // Reads: a byte of whichever register the offset names.
    assign rsel = win_off[6:2];
    function automatic logic [7:0] byte_of(input logic [31:0] w, input logic [1:0] k);
        return w[{k, 3'b000} +: 8];
    endfunction
    always_comb begin
        win_rdata = 8'h00;
        if (is_reg)                              win_rdata = byte_of(rval, win_off[1:0]);
        else if (is_pc)                          win_rdata = byte_of(pc, win_off[1:0]);
        else if (win_off == O_STEP || win_off == O_RUN) win_rdata = result;
        else if (win_off[7:2] == O_EVADDR[7:2])  win_rdata = byte_of(ev_addr, win_off[1:0]);
        else if (win_off[7:2] == O_EVIW[7:2])    win_rdata = byte_of(ev_iw, win_off[1:0]);
        else if (win_off[7:2] == O_EVDATA[7:2])  win_rdata = byte_of(ev_data, win_off[1:0]);
        else if (is_rval)                        win_rdata = byte_of(rval_q, win_off[1:0]);
        else if (win_off[7:2] == O_ID[7:2])      win_rdata = byte_of({8'd2, "E", "V", "R"}, win_off[1:0]);
        else if (win_off == O_STAT)              win_rdata = {6'd0, result != 8'd0, busy};
        else if (win_off == O_SLICE)             win_rdata = slice[7:0];
        else if (win_off == O_SLICE + 8'd1)      win_rdata = slice[15:8];
    end

    // Writes: halves commit on their odd byte, merged with the other half.
    wire        wr      = srv_sel && !srv_rw && srv_act;
    wire        commit_half = wr && win_off[0];
    wire [15:0] half    = {srv_wdata, lo_latch};
    function automatic logic [31:0] merge(input logic [31:0] old, input logic hi, input logic [15:0] h);
        return hi ? {h, old[15:0]} : {old[31:16], h};
    endfunction
    always_comb begin
        w_en    = commit_half && is_reg;
        w_sel   = win_off[6:2];
        w_val   = merge(rval, win_off[1], half);
        pc_we   = commit_half && is_pc;
        pc_wval = merge(pc, win_off[1], half);
        resume  = wr && win_off == O_RESUME;
        resume_val = rval_q;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            // $80-$DF is VOID to the 65816 until it becomes RAM (REQ_RVVM), and the
            // engine reads the physical image: keep the two views equal - $02-$7F.
            lo_latch <= 8'd0; rval_q <= 32'd0;
            slice <= 16'(SLICE0);
        end else if (wr) begin
            if (!win_off[0]) lo_latch <= srv_wdata;
            if (commit_half && is_rval) rval_q <= merge(rval_q, win_off[1], half);
            if (win_off == O_SLICE)         slice[7:0]  <= srv_wdata;
            if (win_off == O_SLICE + 8'd1)  slice[15:8] <= srv_wdata;
        end
    end

    wire unused = &{1'b0, il_ack, il_done, il_ok, il_row, il_set, il_way, dr_ack, dr_done, dr_row,
                    op_place_v, op_place_ppn, evict_v, evict_set, evict_way, pw_ack, inval};
endmodule
