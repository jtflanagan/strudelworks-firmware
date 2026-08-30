`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mem_cache - the card's copy of the Apple's memory, served to the core.
//
// The image of the machine's RAM lives in DDR3 (bank 0, rtl/mem_client.sv);
// this is the cache in front of it: four ways of SETS lines of 16 bytes, one
// DDR3 burst per line, tree pseudo-LRU replacement.  Every op the card drives
// comes through here after rtl/apple_mmu.sv has said which physical byte it
// touches.  A read of RAM that hits is answered from the way; a read that
// misses fetches its line and answers from the fetched burst; a write updates
// the line if it is present and always goes through to the DDR3 - WRITE-THROUGH,
// so a line is never dirty, a miss is always exactly one read burst, and
// evicting a line costs nothing.  ROM reads are answered from rtl/apple_rom.sv,
// which is always a hit.
//
// THE BUS IS STILL DRIVEN.  Nothing here changes what the machine sees: the
// address and R/W go out as they always did, the write data too, and the
// machine's own RAM keeps every write - the video scanner reads it.  What
// changes is where the core's byte comes from: on a read this module can hand
// it a byte through din_sub, the same route the keyboard injection uses, and
// the bus's byte is ignored.  The capture records the byte the core consumed.
//
// WHEN IT ANSWERS.  Only when it is sure: the class is served (serve[]), the
// image is ready, the line hit or its fill has landed, and no invalidation is
// running.  On any doubt it says nothing and the core takes the bus's byte,
// exactly as before this module existed.  A fill that lands after the next op
// has been presented is dropped and counted (late_fills), never applied: it
// would answer the wrong cycle.  That counter must read zero on hardware; at
// Apple speed a fill has ~90 clocks and needs ~15.
//
// THE MONITOR STOPS AT THE MACHINE'S MEMORY.  Image banks 0 and 1 - main
// and the regular auxiliary memory - exist in the machine, so the bus's byte
// is an opinion worth comparing with.  Banks 2 and up are the RamWorks's
// extension (rtl/apple_mmu.sv), memory the machine does not have: the bus
// carries whatever its one auxiliary bank holds there, which every bank's
// writes have been landing in, and a comparison would count nothing but
// the difference between a RamWorks and a 128K IIe.  Those reads are served
// and cached like any other, and not compared.
//
// UNWRITTEN MEMORY IS GARBAGE, by decision (docs/MEMORY.md): nothing here
// tracks which bytes have been written, because a powered-up Apple's memory
// is garbage too and programs are written for that.  The consequence is that
// the monitor, which runs in every mode, cannot tell a wrong byte from an
// unwritten one - so its mismatch count is noise until the machine's working
// set has been written, and the number to watch is whether it PLATEAUS.
//
// THE PIPELINE, in clocks after op_present (P0):
//
//   P1  apple_mmu has classified the op; the tag word and all four ways are
//       addressed by the set
//   P3  the block RAMs' second output registers hold the tag word and lines
//   P4  four tag compares, four 16:1 byte selects, registered
//   P5  hit, the hit way's byte, the victim, registered
//   P6  the decision: sub_en/sub_data, a fill or a write to mem_client, a
//       byte into a way, the tag word written back with its LRU bits
//
// Six clocks of a ~98-clock bus cycle, and no stage is more than a few LUT
// levels: this design has 0.3 ns of setup slack to spend and is not spending it.
//
// ONE OP AT A TIME.  The bus presents one op per cycle and the next cannot
// begin before the previous has been decided, so nothing here forwards or
// bypasses.  Running the core faster than the bus - the accelerated mode this
// is the groundwork for - would need a write-then-read bypass on the ways and
// on the tag word; that is listed in docs/MEMORY.md and is not here.
//////////////////////////////////////////////////////////////////////////////////
module mem_cache #(
    parameter integer SETS = 512
) (
    input  wire        clk,
    // The card's reset.  RES' never comes here: like real RAM, the image and
    // the cache survive the machine being reset.
    input  wire        rst,

    // The classified op, from apple_mmu, plus the op's own address and write
    // data from apple_bus_write.
    input  wire        cl_valid,
    input  wire [1:0]  cl_cls,
    input  wire [23:0] cl_pa,
    input  wire        cl_rw,
    input  wire        cl_wr_image,
    input  wire [15:0] op_addr,
    input  wire [7:0]  op_wdata,
    input  wire        op_present,
    input  wire        op_commit,
    // The driver sent this write out as a read (apple_bus_write.sv): counted
    // here with the rest of the image's numbers.
    input  wire        op_divert,
    // The bus's byte, for the monitor.
    input  wire [7:0]  data_sync,

    // The ROM's byte for this op, valid from P3.
    input  wire [7:0]  rom_byte,
    input  wire        rom_loaded,

    // To the din mux: hold from the decision until the next op_present.
    output logic       sub_en,
    output logic [7:0] sub_data,
    // The whole 16-byte line sub_data came from, for an L1 install: valid
    // with sub_en when the answer came from the image (a way hit or a fill),
    // never for ROM - rtl/apple_rom.sv hands its lines out itself.
    output logic [127:0] sub_line,
    output logic         sub_line_ok,
    // For rtl/accel_seq.sv, which presents the next op only when this one is
    // over: `decided` pulses on the clock the op's outcome is known - P6 for a
    // hit, a ROM read, a write or an op nothing here answers; the clock the
    // fill lands for a miss - with sub_en/sub_data valid on the same edge.
    // `busy` is high from the op's arrival until then, fill included, and is
    // what a fresh start (after reset, after a hold) waits on.
    output logic       decided,
    output wire        busy,

    // Control and status, from MEM_CTRL / to MEM_STAT.
    input  wire        serve,          // all-or-nothing: serve every cacheable class, or none
    input  wire        inval,          // pulse: invalidate every line
    // One line invalidated on request (the DMA drain's): taken in an idle
    // window, three clocks, sharing no port with an op's read.  A read of
    // the very line CONCURRENT with the drain is the mid-DMA overlap corner
    // (program error, undefined - docs/HARDDISK.md); a read after busy
    // drops misses here and fills from the DDR3 the same in-order queue
    // just wrote, and is fresh by construction.
    input  wire        inv_line_en,
    input  wire [23:0] inv_line_pa,
    output wire        inv_line_rdy,
    input  wire        cnt_clr,        // pulse: clear the counters
    input  wire        image_ready,
    output logic       invalidating,
    output logic [31:0] hits,
    output logic [31:0] misses,
    output logic [31:0] served,
    output logic [31:0] mismatches,
    output logic [31:0] last_mismatch, // {addr, cache byte, bus byte}
    output logic [31:0] diverted,      // writes sent out as reads
    output logic [7:0]  late_fills,
    output logic [7:0]  fifo_drops,    // requests mem_client could not take

    // To mem_client: a request, held until taken.
    output logic        mq_valid,
    output logic        mq_kind,       // 0 = byte write, 1 = line fill
    output logic [1:0]  mq_id,
    output logic [19:0] mq_line,
    output logic [3:0]  mq_byte,
    output logic [7:0]  mq_data,
    input  wire         mq_ready,
    // From mem_client: a fill's line, tagged with the id it was asked with.
    input  wire         mr_valid,
    input  wire [1:0]   mr_id,
    input  wire [127:0] mr_data
);

    localparam integer IW = $clog2(SETS);      // set index
    localparam integer TW = 20 - IW;           // tag: the rest of the line address
    localparam integer EW = TW + 1;            // {valid, tag}
    localparam integer TAGW = 4 * EW + 3;      // four entries and the LRU bits

    localparam [1:0] CLS_BUS = 2'd0;
    localparam [1:0] CLS_RAM = 2'd1;
    localparam [1:0] CLS_LC  = 2'd2;
    localparam [1:0] CLS_ROM = 2'd3;

    // ---- the op, held for its whole cycle ------------------------------------
    logic [23:0] p_pa;
    logic [15:0] p_addr;
    logic [1:0]  p_cls;
    logic        p_rw, p_wr_image;
    logic        p_machine;            // the op reaches memory the machine has

    wire [IW-1:0] set_in  = cl_pa[IW+3:4];
    wire [IW-1:0] p_set   = p_pa[IW+3:4];
    wire [TW-1:0] p_tag   = p_pa[23:IW+4];
    wire [3:0]    p_byte  = p_pa[3:0];

    // ---- the memories ----------------------------------------------------------
    logic [127:0] way_rd [0:3];
    logic [15:0]  way_be;
    logic [IW-1:0] way_waddr;
    logic [127:0] way_wdata;
    logic [3:0]   way_wsel;                // which ways take the write

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_way
            cache_way_ram #(.SETS (SETS)) u_way (
                .clk     (clk),
                .rd_en   (cl_valid),
                .rd_addr (set_in),
                .rd_data (way_rd[g]),
                .wr_be   (way_wsel[g] ? way_be : 16'd0),
                .wr_addr (way_waddr),
                .wr_data (way_wdata)
            );
        end
    endgenerate

    // The tag word: {plru[2:0], entry3, entry2, entry1, entry0}, each entry
    // {valid, tag}.  One block RAM, read like the ways, written whole.
    (* ram_style = "block" *) logic [TAGW-1:0] tags [0:SETS-1];
    logic [TAGW-1:0] tag_q, tag_rd;
    logic            tag_we;
    logic [IW-1:0]   tag_waddr;
    logic [TAGW-1:0] tag_wdata;

    always_ff @(posedge clk) begin
        if (tag_we) tags[tag_waddr] <= tag_wdata;
    end
    always_ff @(posedge clk) begin
        if (cl_valid)      tag_q <= tags[set_in];
        else if (li_rd_en) tag_q <= tags[inv_line_pa[IW+3:4]];
        tag_rd <= tag_q;
    end

    // ---- one line, invalidated on request ------------------------------------
    // IDLE -> RD (the set's word lands in tag_q) -> WR (it is in tag_rd:
    // clear any way holding the line, write it back).  Starts only with the
    // pipeline empty, so tag_q/tag_rd are free; an op arriving mid-sequence
    // reads the tag RAM's other port and is untouched.
    typedef enum logic [1:0] {LI_IDLE, LI_RD, LI_WR} li_t;
    li_t li_st;
    logic [IW-1:0] li_set;
    logic [TW-1:0] li_tag;
    wire li_idle_ok = !cl_valid && !v1 && !v2 && !v3 && !v4 &&
                      !fill_pending && !invalidating;
    wire li_rd_en   = (li_st == LI_IDLE) && inv_line_en && li_idle_ok;
    assign inv_line_rdy = (li_st == LI_IDLE) && li_idle_ok;

    // ---- the pipeline's valid bits -----------------------------------------------
    logic v1, v2, v3, v4;
    logic [127:0] hline;               // P5: the hit way's whole line

    // P4: compares and byte selects, registered.
    logic [3:0]      hitv;
    logic [7:0]      wbyte [0:3];
    logic [TAGW-1:0] tagword;
    logic [7:0]      rom_q;

    // P5: the hit, the byte, the victim, registered.
    logic        hit;
    logic [7:0]  rbyte;
    logic [1:0]  hway;
    logic [1:0]  victim;
    logic [2:0]  plru_after_hit;
    logic [2:0]  plru_after_fill;

    // ---- tree PLRU ------------------------------------------------------------------
    // b0 splits {0,1} from {2,3}; b1 orders 0/1, b2 orders 2/3.  A bit points
    // AWAY from the half used last, so the victim is where every bit points.
    function automatic [1:0] plru_victim(input [2:0] b);
        plru_victim = b[0] ? (b[2] ? 2'd3 : 2'd2) : (b[1] ? 2'd1 : 2'd0);
    endfunction
    function automatic [2:0] plru_touch(input [2:0] b, input [1:0] w);
        plru_touch = b;
        plru_touch[0] = ~w[1];
        if (!w[1]) plru_touch[1] = ~w[0];
        else       plru_touch[2] = ~w[0];
    endfunction

    wire [2:0] plru_now = tagword[4*EW +: 3];

    // ---- the fill in flight -------------------------------------------------------------
    logic        fill_pending;
    logic [1:0]  fill_id;
    logic        fill_serve;           // answer the core when it lands
    logic        fill_cmp;             // and compare it at op_commit
    logic [7:0]  fill_byte;

    // What the monitor compares this op's byte against, and whether to.
    logic        cmp_valid;
    logic [7:0]  cmp_byte;
    logic [7:0]  data_q;               // data_sync a clock ago: the T_DIN sample

    // ---- the invalidate walk --------------------------------------------------------
    logic [IW:0] inv_idx;              // one extra bit: == SETS means done
    assign invalidating = !inv_idx[IW];

    // All-or-nothing: when serving, every RAM and LC read is answered from the
    // image and every ROM read from the card's ROM; a $Cxxx (BUS) read never is.
    wire serve_cls = serve && ((p_cls == CLS_RAM) || (p_cls == CLS_LC) ||
                               (p_cls == CLS_ROM && rom_loaded));
    wire cacheable = (p_cls == CLS_RAM) || (p_cls == CLS_LC);
    wire may_touch = image_ready && !invalidating;

    assign busy = v1 || v2 || v3 || v4 || fill_pending;

    integer w;
    always_ff @(posedge clk) begin
        // Defaults: single-cycle strobes.
        way_be    <= 16'd0;
        way_wsel  <= 4'd0;
        tag_we    <= 1'b0;
        data_q    <= data_sync;
        // Decided on this edge: P6 unless a fill is being raised, or the fill.
        decided   <= (v4 && !(p_rw && cacheable && !hit && may_touch)) ||
                     (mr_valid && fill_pending && mr_id == fill_id);

        if (rst) begin
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v4 <= 1'b0;
            p_pa <= 24'd0; p_addr <= 16'd0; p_cls <= CLS_BUS; p_rw <= 1'b1;
            p_wr_image <= 1'b0; p_machine <= 1'b0;
            hitv <= 4'd0; tagword <= '0; rom_q <= 8'd0;
            hit <= 1'b0; rbyte <= 8'd0; hway <= 2'd0; victim <= 2'd0;
            plru_after_hit <= 3'd0; plru_after_fill <= 3'd0;
            sub_en <= 1'b0; sub_data <= 8'd0;
            sub_line <= 128'd0; sub_line_ok <= 1'b0;
            fill_pending <= 1'b0; fill_id <= 2'd0; fill_serve <= 1'b0;
            fill_cmp <= 1'b0; fill_byte <= 8'd0;
            cmp_valid <= 1'b0; cmp_byte <= 8'd0;
            decided <= 1'b0;
            mq_valid <= 1'b0; mq_kind <= 1'b0; mq_id <= 2'd0;
            mq_line <= 20'd0; mq_byte <= 4'd0; mq_data <= 8'd0;
            hits <= 32'd0; misses <= 32'd0; served <= 32'd0;
            mismatches <= 32'd0; last_mismatch <= 32'd0; diverted <= 32'd0;
            late_fills <= 8'd0; fifo_drops <= 8'd0;
            inv_idx <= '0;                 // a reset invalidates everything
            li_st <= LI_IDLE; li_set <= '0; li_tag <= '0;
            way_waddr <= '0; way_wdata <= '0;
            tag_waddr <= '0; tag_wdata <= '0;
            for (w = 0; w < 4; w = w + 1) wbyte[w] <= 8'd0;
        end else begin
            // ---- the request handshake --------------------------------------
            if (mq_valid && mq_ready) mq_valid <= 1'b0;

            // ---- a new op: the previous one is over -------------------------
            if (op_present) begin
                sub_en       <= 1'b0;
                sub_line_ok  <= 1'b0;
                fill_pending <= 1'b0;
                cmp_valid    <= 1'b0;
            end

            // ---- P1: the op arrives classified --------------------------------
            v1 <= cl_valid;
            if (cl_valid) begin
                p_pa       <= cl_pa;
                p_addr     <= op_addr;
                p_cls      <= cl_cls;
                p_rw       <= cl_rw;
                p_wr_image <= cl_wr_image;
                p_machine  <= (cl_pa[23:17] == 7'd0);
            end
            v2 <= v1;

            // ---- P4: the RAMs have answered -----------------------------------
            v3 <= v2;
            if (v2) begin
                tagword <= tag_rd;
                rom_q   <= rom_byte;
                for (w = 0; w < 4; w = w + 1) begin
                    hitv[w]  <= tag_rd[w*EW + TW] && (tag_rd[w*EW +: TW] == p_tag)
                                && !invalidating;
                    wbyte[w] <= way_rd[w][8 * p_byte +: 8];
                end
            end

            // ---- P5: one way, one byte, one victim ---------------------------
            v4 <= v3;
            if (v3) begin
                // The hit way's whole line, while way_rd still holds it (the
                // way RAM's output registers only move on rd_en).
                hline <= (hitv[0] ? way_rd[0] : 128'd0) |
                         (hitv[1] ? way_rd[1] : 128'd0) |
                         (hitv[2] ? way_rd[2] : 128'd0) |
                         (hitv[3] ? way_rd[3] : 128'd0);
                hit   <= |hitv;
                rbyte <= (hitv[0] ? wbyte[0] : 8'd0) | (hitv[1] ? wbyte[1] : 8'd0) |
                         (hitv[2] ? wbyte[2] : 8'd0) | (hitv[3] ? wbyte[3] : 8'd0);
                hway  <= hitv[3] ? 2'd3 : hitv[2] ? 2'd2 : hitv[1] ? 2'd1 : 2'd0;
                victim <= plru_victim(plru_now);
                plru_after_hit  <= plru_touch(plru_now,
                                     hitv[3] ? 2'd3 : hitv[2] ? 2'd2 : hitv[1] ? 2'd1 : 2'd0);
                plru_after_fill <= plru_touch(plru_now, plru_victim(plru_now));
            end

            // ---- P6: the decision ----------------------------------------------
            if (v4) begin
                if (p_rw) begin
                    if (cacheable) begin
                        if (hit) begin
                            hits <= hits + 32'd1;
                            if (serve_cls && may_touch) begin
                                sub_en   <= 1'b1;
                                sub_data <= rbyte;
                                sub_line <= hline;
                                sub_line_ok <= 1'b1;
                                served   <= served + 32'd1;
                            end
                            cmp_valid <= 1'b1;
                            cmp_byte  <= rbyte;
                            // Touch the LRU bits.
                            tag_we    <= 1'b1;
                            tag_waddr <= p_set;
                            tag_wdata <= {plru_after_hit, tagword[4*EW-1:0]};
                        end else begin
                            misses <= misses + 32'd1;
                            if (may_touch) begin
                                fill_pending <= 1'b1;
                                fill_id      <= fill_id + 2'd1;
                                fill_serve   <= serve_cls;
                                if (mq_valid) fifo_drops <= fifo_drops + 8'd1;
                                mq_valid <= 1'b1;
                                mq_kind  <= 1'b1;
                                mq_id    <= fill_id + 2'd1;
                                mq_line  <= p_pa[23:4];
                                mq_byte  <= p_byte;
                            end
                        end
                    end else if (p_cls == CLS_ROM && rom_loaded) begin
                        if (serve) begin
                            sub_en   <= 1'b1;
                            sub_data <= rom_q;
                            served   <= served + 32'd1;
                        end
                        cmp_valid <= 1'b1;
                        cmp_byte  <= rom_q;
                    end
                end else if (p_wr_image) begin
                    // Through to the image, and into the line if it is here.
                    if (mq_valid) fifo_drops <= fifo_drops + 8'd1;
                    mq_valid <= 1'b1;
                    mq_kind  <= 1'b0;
                    mq_line  <= p_pa[23:4];
                    mq_byte  <= p_byte;
                    mq_data  <= op_wdata;
                    if (hit && may_touch) begin
                        way_be    <= 16'd1 << p_byte;
                        way_wsel  <= hitv;
                        way_waddr <= p_set;
                        way_wdata <= {16{op_wdata}};
                        tag_we    <= 1'b1;
                        tag_waddr <= p_set;
                        tag_wdata <= {plru_after_hit, tagword[4*EW-1:0]};
                    end
                end
            end

            // ---- a fill lands --------------------------------------------------
            if (mr_valid) begin
                if (fill_pending && mr_id == fill_id) begin
                    fill_pending <= 1'b0;
                    way_be    <= 16'hFFFF;
                    way_wsel  <= 4'd1 << victim;
                    way_waddr <= p_set;
                    way_wdata <= mr_data;
                    tag_we    <= 1'b1;
                    tag_waddr <= p_set;
                    tag_wdata <= tagword;
                    tag_wdata[victim*EW +: EW] <= {1'b1, p_tag};
                    tag_wdata[4*EW +: 3]       <= plru_after_fill;
                    if (fill_serve) begin
                        sub_en   <= 1'b1;
                        sub_data <= mr_data[8 * p_byte +: 8];
                        sub_line <= mr_data;
                        sub_line_ok <= 1'b1;
                        served   <= served + 32'd1;
                    end
                    cmp_valid <= 1'b1;
                    cmp_byte  <= mr_data[8 * p_byte +: 8];
                end else begin
                    late_fills <= late_fills + 8'd1;
                end
            end

            // ---- a diverted write, once per cycle -------------------------------------
            if (op_commit && op_divert) diverted <= diverted + 32'd1;

            // ---- the monitor, at the data phase ----------------------------------
            if (op_commit && cmp_valid && p_machine && cmp_byte != data_q) begin
                mismatches    <= mismatches + 32'd1;
                last_mismatch <= {p_addr, cmp_byte, data_q};
            end

            // ---- one line invalidated (see the port comment) -------------------
            case (li_st)
                LI_IDLE: if (li_rd_en) begin
                    li_set <= inv_line_pa[IW+3:4];
                    li_tag <= inv_line_pa[23:IW+4];
                    li_st  <= LI_RD;
                end
                LI_RD: li_st <= LI_WR;
                LI_WR: begin
                    tag_we    <= 1'b1;
                    tag_waddr <= li_set;
                    tag_wdata <= tag_rd;
                    for (w = 0; w < 4; w = w + 1)
                        if (tag_rd[w*EW + TW] && (tag_rd[w*EW +: TW] == li_tag))
                            tag_wdata[w*EW + TW] <= 1'b0;
                    li_st <= LI_IDLE;
                end
                default: li_st <= LI_IDLE;
            endcase

            // ---- the invalidate walk ---------------------------------------------
            if (inval) inv_idx <= '0;
            else if (invalidating) begin
                tag_we    <= 1'b1;
                tag_waddr <= inv_idx[IW-1:0];
                tag_wdata <= '0;
                inv_idx   <= inv_idx + 1'b1;
            end

            if (cnt_clr) begin
                hits <= 32'd0; misses <= 32'd0; served <= 32'd0;
                mismatches <= 32'd0; last_mismatch <= 32'd0; diverted <= 32'd0;
                late_fills <= 8'd0; fifo_drops <= 8'd0;
            end
        end
    end

endmodule
