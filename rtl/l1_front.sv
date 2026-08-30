`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// l1_front - the level-1 front end: the icache and its TLB, ahead of the
// sequencer.
//
// Between rtl/cpu65c02.sv and rtl/accel_seq.sv.  The sequencer still owns
// every op it sees; what this module adds is ops it never sees: a program-
// stream fetch whose page the I-TLB knows and whose line the icache holds
// retires in ONE CLOCK - cyc_en asserted combinationally, the byte off the
// steered row - with only turbo_commit telling the sequencer to charge the
// governor, count it, and emit its event.  turbo_ok is the sequencer's
// permission (sitting in S_DECIDE, credit to pay, no override, no reset
// sequence, the card serving), so nothing here can run while an op rides the
// bus, an override holds the machine, or the reset sequence is on the pins.
//
// THE CLAIM.  An I-fetch this module might yet serve raises l1_claim for its
// first three clocks, which holds the sequencer's dispatcher off: clock 0
// looks (and refills the TLB if the page is cold), clock 1 retries with the
// row steered to the actual address (a mispredicted branch lands here: two
// clocks, not nine), clock 2 retries once more (a fetch whose TLB entry was
// cold at clock 0).  Then the claim falls and the op takes the sequencer's
// path exactly as before, at most two clocks later than it would have.  The
// claim never blocks a data cycle, never outlives `tries`, and drops at once
// for a page the TLB knows is not servable - so it cannot deadlock the
// dispatcher, only delay it, boundedly.
//
// FILLS.  An image line arrives by OBSERVATION: the fetch that missed here
// rides the sequencer to mem_cache, and the completion's sub_line - the
// whole 16 bytes the byte came from - is installed as it flies past.  A ROM
// line cannot (the ROM is beside the cache, not behind it), so a small
// filler streams the four words from apple_rom's second port and installs
// them itself, racing the op's own nine-clock service and losing nothing if
// it loses.  Both installs are gated by the TLB entry still standing: a map
// change between look and install kills the install with the entry.
//
// COHERENCE.  Every write that lands in the image - the core's, a diverted
// RamWorks write, the hard disk's DMA - passes the MMU classified, and its
// cl_pa snoops the icache the same clock, before the write has reached the
// image.  Self-modifying code therefore cannot fetch a stale byte: the line
// dies before the write completes, and the refetch rides the sequencer
// behind it, in order.  The flash covers the rest: the host invalidating the
// image, the ROM being (re)loaded.
//////////////////////////////////////////////////////////////////////////////////
module l1_front (
    input  wire        clk,
    input  wire        rst,          // the card's

    // The core.  i_addr is the PC registers, not the address mux: equal to
    // the bus address on every I cycle, and with no din behind it - which is
    // what keeps the combinational serve loop-free (a D cycle's address can
    // contain live din through the AGU, and cpu_din must never descend from
    // it).
    input  wire [15:0] i_addr,
    input  wire        cpu_sync,
    input  wire        cyc_is_i,
    // The core's register-only prediction (cpu65c02.i_steer): equal to the
    // exact i_pred wherever a steer could tell the difference - the 6502's
    // granted cycles cover every carried or data-borne PC load - and with
    // no din, AGU or condition logic behind it, which is what keeps the
    // steer cone flip-flop-shallow.
    input  wire [15:0] i_steer,
    output wire        cyc_en,
    output wire [7:0]  cpu_din,

    // The sequencer.
    input  wire        accel_cyc_en,
    input  wire [7:0]  accel_din,
    input  wire        turbo_ok,
    output wire        l1_claim,
    output wire        turbo_commit,
    output wire [15:0] turbo_addr,
    output wire [7:0]  turbo_data,
    output wire        turbo_sync,

    // The MMU: the I-TLB's refill query and the flush.
    output wire [7:0]  t_page,
    input  wire        t_r_ok,
    input  wire [16:0] t_r_ppage,
    input  wire        t_w_ok,
    input  wire [16:0] t_w_ppage,
    input  wire        map_changed,

    // The cache behind: an observed completion's line.
    input  wire [127:0] sub_line,
    input  wire         sub_line_ok,

    // The ROM's fill port.
    output logic        rom_r2_en,
    output logic [11:0] rom_r2_addr,
    input  wire [31:0]  rom_r2_data,

    // The write snoop: the MMU's classified op.
    input  wire        cl_valid,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire [23:0] cl_pa,
    // ...and the DMA drain's lines, second in line: the op's snoop wins a
    // same-clock collision and the drain waits (snoop2_take says it went).
    input  wire        snoop2_en,
    input  wire [23:0] snoop2_pa,
    output wire        snoop2_take,

    // The flash triggers.
    input  wire        mem_invalidating,
    input  wire        rom_ok
);

    // ---- the I-TLB and the page register ------------------------------------
    // The TLB LUTRAM is too slow for the fetch clock (the first build: 22
    // levels, -4.8 ns, two LUTRAMs chained), so the fetch clock never reads
    // it.  Instead ONE entry - the last one used - is held in registers,
    // and the prediction is that the next fetch uses it too.  It almost
    // always does: only a page CROSSING mismatches, and then the fetch
    // stalls one clock while the TLB - now a register-to-register read
    // with a whole clock to make it - reloads the register and the row
    // re-steers.  The user's design.
    wire        a_hit, a_r_ok;
    wire [16:0] a_r_ppage;
    wire        a_w_ok_nc;
    wire [16:0] a_w_ppage_nc;

    class_tlb u_itlb (
        .clk       (clk),
        .rst       (rst),
        .flush     (map_changed),
        .l_addr    (i_addr),
        .l_hit     (a_hit),
        .l_r_ok    (a_r_ok),
        .l_r_ppage (a_r_ppage),
        .l_w_ok    (a_w_ok_nc),        // the I side never writes
        .l_w_ppage (a_w_ppage_nc),
        .w_en      (cyc_is_i && !a_hit),        // cold page: refill, retry free
        .w_page    (i_addr[15:8]),
        .w_r_ok    (t_r_ok),
        .w_r_ppage (t_r_ppage),
        .w_w_ok    (t_w_ok),
        .w_w_ppage (t_w_ppage)
    );
    assign t_page = i_addr[15:8];

    // The page register: {page, servable, physical page}, standing until
    // the map moves.  Reloaded - from the TLB, itself refilled first when
    // cold - on the fetch clock that mismatches it.
    logic        lp_valid, lp_ok;
    logic [7:0]  lp_page;
    logic [16:0] lp_ppage;
    wire page_match = lp_valid && (i_addr[15:8] == lp_page);
    always_ff @(posedge clk) begin
        if (rst || map_changed) begin
            lp_valid <= 1'b0;
        end else if (cyc_is_i && !page_match && a_hit) begin
            lp_valid <= 1'b1;
            lp_page  <= i_addr[15:8];
            lp_ok    <= a_r_ok;
            lp_ppage <= a_r_ppage;
        end
    end

    // Everything the fetch clock needs is now flip-flops on both sides:
    // the page compare, the physical address, the icache index.
    wire [24:0] cur_pa  = {lp_ppage, i_addr[7:0]};
    wire [7:0]  cur_idx = cur_pa[11:4];
    // The predicted fetch is assumed IN the page.  A cross-page prediction
    // steers a wrong row, and that fetch then stalls on the page mismatch
    // anyway - the stall that fixes it.
    wire [7:0]  pred_idx = {lp_ppage[3:0], i_steer[7:4]};
    // During a page-mismatch stall, steer from the TLB's live output, so
    // the reload and the re-steer share the one stall clock.
    wire [7:0]  mm_idx   = {a_r_ppage[3:0], i_addr[7:4]};

    // ---- the icache ---------------------------------------------------------
    wire ic_hit;
    wire [7:0] ic_byte;
    logic        inst_en;
    logic [24:0] inst_pa;
    logic [127:0] inst_line;

    logic rom_ok_q;
    always_ff @(posedge clk) rom_ok_q <= rom_ok;
    wire flash = mem_invalidating || (rom_ok != rom_ok_q);

    icache_l1 u_ic (
        .clk       (clk),
        .rst       (rst),
        .flash     (flash),
        .look_pa   (cur_pa),
        .look_hit  (ic_hit),
        .look_byte (ic_byte),
        // Advancing: have the predicted fetch ready.  Stalled: have THIS
        // one - from the TLB's live answer while the page register reloads.
        // The tag rides with the index, from the same source.
        .steer_idx (cyc_en ? pred_idx : (page_match ? cur_idx : mm_idx)),
        .steer_tag ((cyc_en || page_match) ? lp_ppage[16:4]
                                           : a_r_ppage[16:4]),
        .inst_en   (inst_en),
        .inst_pa   (inst_pa),
        .inst_line (inst_line),
        .snoop_en  (cl_snoop || snoop2_en),
        .snoop_pa  (cl_snoop ? cl_pa : snoop2_pa)
    );
    wire cl_snoop = cl_valid && !cl_rw && cl_wr_image;
    assign snoop2_take = snoop2_en && !cl_snoop;

    // ---- the turbo op -------------------------------------------------------
    wire servable = cyc_is_i && page_match && lp_ok;
    wire turbo_hit = turbo_ok && servable && ic_hit;

    assign cyc_en   = accel_cyc_en || turbo_hit;
    assign cpu_din  = turbo_hit ? ic_byte : accel_din;

    assign turbo_commit = turbo_hit;
    assign turbo_addr   = i_addr;
    assign turbo_data   = ic_byte;
    assign turbo_sync   = cpu_sync;

    // ---- the claim ----------------------------------------------------------
    // Three clocks of hope per fetch, then the sequencer's op.  See the header.
    logic [1:0] tries;
    always_ff @(posedge clk) begin
        if (rst || cyc_en || !cyc_is_i) tries <= 2'd0;
        else if (tries != 2'd3)         tries <= tries + 2'd1;
    end
    // A page the register says is unservable drops the claim at once; an
    // unmatched page burns at most the window while it reloads.
    assign l1_claim = cyc_is_i && (tries != 2'd3) && !(page_match && !lp_ok);

    // ---- the image install: observation -------------------------------------
    // The op that missed here completed on the sequencer's path; its line
    // flies past on sub_line.  Gated on the TLB entry still standing, so a
    // map change between look and completion kills it.
    wire img_inst = accel_cyc_en && servable && !cur_pa[24] && sub_line_ok;

    // ---- the ROM filler -----------------------------------------------------
    // Four words off apple_rom's second port, latency two, streamed.  Started
    // at the second retry, racing the op's own service.  fstep 0-3 issue,
    // 2-5 collect, 6 waits for the install slot.
    logic         filling;
    logic [2:0]   fstep;
    logic [24:0]  fill_pa;
    logic [127:0] facc;

    wire fill_go = servable && cur_pa[24] && !ic_hit && !filling &&
                   (tries == 2'd2);
    wire rom_inst = filling && (fstep == 3'd7) && !img_inst;

    always_ff @(posedge clk) begin
        rom_r2_en <= 1'b0;
        if (rst || flash || map_changed) begin
            filling <= 1'b0;
            fstep   <= 3'd0;
        end else if (fill_go) begin
            filling <= 1'b1;
            fstep   <= 3'd0;
            fill_pa <= cur_pa;
        end else if (filling) begin
            if (fstep <= 3'd3) begin
                rom_r2_en   <= 1'b1;
                rom_r2_addr <= {fill_pa[13:4], fstep[1:0]};
            end
            // rom_r2_en is registered and the port has two registers of its
            // own, so word w, issued at step w, is on rom_r2_data during
            // step w+3.
            case (fstep)
                3'd3: facc[31:0]   <= rom_r2_data;
                3'd4: facc[63:32]  <= rom_r2_data;
                3'd5: facc[95:64]  <= rom_r2_data;
                3'd6: facc[127:96] <= rom_r2_data;
                default: ;
            endcase
            if (fstep != 3'd7)      fstep <= fstep + 3'd1;
            else if (rom_inst)      filling <= 1'b0;
        end
    end

    always_comb begin
        inst_en   = img_inst || rom_inst;
        inst_pa   = img_inst ? cur_pa   : fill_pa;
        inst_line = img_inst ? sub_line : facc;
    end

endmodule
