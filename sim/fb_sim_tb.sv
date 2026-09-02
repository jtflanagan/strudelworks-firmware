`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// fb_sim_tb - the floating bus simulated, and proven against the machine's.
//
// The real reader, driver, core, hold, lock and MMU shadow around fb_sim,
// wired as master_top wires them, against an Apple whose video scanner is
// Sather's counters (as sim/vbl_lock_tb.sv has them) and whose floating bus
// returns the byte that scanner read - in EVERY mode this time: text or
// hi-res, page 1 or 2, mixed, with the IIe's write steering (80STORE, PAGE2,
// HIRES, RAMWRT) deciding which bank a write lands in.  The testbench's
// scanner address is derived from the counters' bits as the diagram wires
// them; the RTL's from a line and a cycle count.  The two agreeing on every
// cycle of a frame, in every mode, is the property everything below rests on.
//
// THE PROPERTIES:
//
//   * before the lock nothing is compared.
//   * with both text pages and both hi-res pages written through the bus,
//     a frame of floating-bus reads in each of text/hi-res x page 1/2,
//     mixed hi-res on both pages, and page 2 under 80STORE (shown as page 1)
//     is compared on every cycle with no mismatch, on NTSC and on PAL; the
//     mode bits say what the prediction was built from.
//   * a byte changed behind the copy's back is counted exactly as often as
//     the scanner fetches it, in the right count: an ordinary byte in
//     FB_MISMATCH, a screen hole in FB_OTHER's low half, anything on an
//     80-column cycle in its high half - and nowhere else.
//   * a write the switches steer to the auxiliary bank - 80STORE+PAGE2 on
//     the text page, +HIRES on the hi-res page, RAMWRT anywhere, a RamWorks
//     bank - never enters the copy; the same write to main memory does.
//     The peek reads the whole copy back byte for byte.
//   * serving: the core's floating reads get the prediction, the captured
//     event carries it, the bus still carries the machine's byte - shown
//     with the machine's floating bus dead, where the core still sees the
//     picture and the monitor counts every read.  Never on an override (the
//     probe's frame stays real), never on an 80-column cycle.
//   * the counters clear.
//////////////////////////////////////////////////////////////////////////////////

module fb_sim_tb #(parameter UCODE = "cpu65c02_ucode.hex");

    localparam integer T_PRESENT = 2;
    localparam integer T_EMIT    = 2;
    localparam integer T_DIN     = 44;
    localparam integer T_CYCEN   = 45;
    localparam integer ACQ_TIMEOUT = 22_000;
    localparam integer NTSC_CYC = 17030;
    localparam integer PAL_CYC  = 20280;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;               // 100 MHz

    integer errors = 0;
    task fail(input [8*120-1:0] why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask

    // ---- phi0, as the machine makes it --------------------------------------
    localparam integer PHI0_LOW  = 49;
    localparam integer PHI0_HIGH = 49;
    localparam integer CYCLE     = PHI0_LOW + PHI0_HIGH;
    reg phi0 = 0;
    integer phase_ctr = 0;
    always @(posedge clk) begin
        phase_ctr <= phase_ctr + 1;
        if (!phi0 && phase_ctr == PHI0_LOW - 1)  begin phi0 <= 1; phase_ctr <= 0; end
        if ( phi0 && phase_ctr == PHI0_HIGH - 1) begin phi0 <= 0; phase_ctr <= 0; end
    end

    reg     prev_phi0 = 0;
    wire    fall = !phi0 && prev_phi0;
    integer since_fall = 0;
    always @(posedge clk) begin
        prev_phi0 <= phi0;
        if (fall) since_fall <= 0;
        else      since_fall <= since_fall + 1;
    end

    // ---- the video scanner: Sather's counters ---------------------------------
    reg       pal = 1'b0;
    reg [6:0] H = 7'h00;
    reg [8:0] V = 9'h100;
    always @(posedge clk) if (fall) begin
        if (H == 7'h7F) begin
            H <= 7'h00;
            V <= (V == 9'h1FF) ? (pal ? 9'hC8 : 9'hFA) : V + 9'd1;
        end else if (H == 7'h00) begin
            H <= 7'h40;
        end else begin
            H <= H + 7'd1;
        end
    end

    // The address for the scanner's state, as the diagram wires it: A0-A2 =
    // H0-H2, A3-A6 = H5H4H3 + V4V3V4V3 + 1101, A7-A9 = V0-V2; then text:
    // A10/A11 the page; hi-res: A10-A12 = VA-VC, A13/A14 the page.
    function [15:0] sc_addr(input [8:0] v, input [6:0] hh, input hires, input page2);
        reg [3:0] sum;
        begin
            sum = {1'b0, hh[5:3]} + {v[7], v[6], v[7], v[6]} + 4'b1101;
            if (hires) sc_addr = {1'b0, page2, !page2, v[2:0], v[5:3], sum, hh[2:0]};
            else       sc_addr = {4'b0000, page2, !page2, v[5:3], sum, hh[2:0]};
        end
    endfunction

    function integer sc_line(input [8:0] v, input p);
        begin
            if (v >= 9'h100) sc_line = v - 9'h100;
            else             sc_line = v + 256 - (p ? 9'hC8 : 9'hFA);
        end
    endfunction

    // ---- the machine's reset line, and the card's ---------------------------
    reg  res_n = 1'b1;
    wire cpu_rst = rst || !res_n;
    reg  master_active = 1'b1;

    // ---- the reader, on the pins ------------------------------------------------
    reg  [7:0]  data_pin = 8'h00;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, driving, drv_sync;
    wire [7:0]  data_drive;
    wire        phi0_sync, res_sync, tick;
    wire [7:0]  data_sync;
    wire        vbl_level;
    wire [31:0] ev_data;
    wire        ev_valid;
    wire        sub_en;
    wire [7:0]  sub_data;

    apple_bus_read u_read (
        .clk (clk), .rst (rst), .enable (1'b1),
        .apple_data_pin (data_pin), .apple_addr_pin (addr_drive), .apple_rw_pin (rw_drive),
        .apple_phi0_pin (phi0), .apple_m2sel_pin (1'b0), .apple_m2b0_pin (1'b1),
        .apple_inh_pin (1'b1), .apple_res_pin (res_n), .apple_irq_pin (1'b1),
        .apple_rdy_pin (1'b1), .apple_dma_pin (!dma_assert),
        .ev_data (ev_data), .ev_valid (ev_valid), .data_tick (tick),
        .sync_override (drv_sync), .sync_override_en (1'b1),
        .data_override (sub_data), .data_override_en (sub_en),
        .rw_override_en (1'b0), .wdata_override (8'h00), .vbl_level (vbl_level),
        .res_sync (res_sync), .irq_sync (), .phi0_sync (phi0_sync),
        .data_sync (data_sync), .phi0_active ()
    );

    // ---- the core -----------------------------------------------------------
    wire [15:0] cpu_addr;
    wire        cpu_rw, cpu_sync, cpu_cyc_en;
    wire [7:0]  cpu_dout, cpu_din;

    cpu65c02 #(.UCODE_FILE (UCODE)) u_cpu (
        .clk (clk), .rst (cpu_rst), .cyc_en (cpu_cyc_en),
        .addr (cpu_addr), .rw (cpu_rw), .dout (cpu_dout), .i_din (cpu_din), .d_din (cpu_din),
        .irq_n (1'b1), .nmi_n (1'b1),
        .sync (cpu_sync), .halted ()
    );

    // ---- the driver, and the override mux: the lock, then the testbench's own
    // override (the disk's place in master_top), then the hold --------------
    wire [15:0] op_addr;
    wire        op_rw, op_present, op_commit, op_ovr;
    wire [7:0]  op_wdata;
    wire        hold_ovr_en, vbl_ovr_en, vbl_ovr_rw;
    wire [15:0] hold_ovr_addr, vbl_ovr_addr;
    wire [7:0]  vbl_ovr_wdata;
    reg         tb_ovr_en = 1'b0, tb_ovr_rw = 1'b1;
    reg  [15:0] tb_ovr_addr = 16'hC020;
    reg  [7:0]  tb_ovr_wdata = 8'h00;
    wire        ovr_en    = hold_ovr_en | vbl_ovr_en | tb_ovr_en;
    wire [15:0] ovr_addr  = vbl_ovr_en ? vbl_ovr_addr  : tb_ovr_en ? tb_ovr_addr  : hold_ovr_addr;
    wire        ovr_rw    = vbl_ovr_en ? vbl_ovr_rw    : tb_ovr_en ? tb_ovr_rw    : 1'b1;
    wire [7:0]  ovr_wdata = vbl_ovr_en ? vbl_ovr_wdata : tb_ovr_wdata;

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) u_write (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0_sync), .data_sync (data_sync),
        .master_active (master_active),
        // Without the sequencer: the bus owns every cycle, the core is always on offer.
        .bus_owns (1'b1), .core_valid (1'b1),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .drv_sync (drv_sync),
        .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (1'b0), .slot_rd_data (8'h00),
        .din_sub_en (sub_en), .din_sub_data (sub_data),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (ovr_rw),
        .ovr_wdata (ovr_wdata), .op_ovr (op_ovr), .nxt_addr (), .divert (1'b0), .op_divert (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- the hold -----------------------------------------------------------
    reg  arm = 1'b0;
    reg  release_req = 1'b0;
    wire held, runtime;

    boot_hold u_hold (
        .clk (clk), .cpu_rst (cpu_rst),
        .master_active (master_active),
        .arm (arm), .release_req (release_req),
        .menu_trigger (1'b0), .hotkey_hit (1'b0),
        .turbo_sync (1'b0), .cpu_sync (cpu_sync),
        .op_present (op_present), .op_commit (op_commit),
        .op_sync (drv_sync), .op_ovr (op_ovr),
        .op_addr (op_addr), .op_rw (op_rw), .din (cpu_din),
        .ovr_en (hold_ovr_en), .ovr_addr (hold_ovr_addr),
        .held (held), .runtime (runtime)
    );

    // ---- the lock -------------------------------------------------------------
    reg         start = 1'b0, probe = 1'b0;
    reg  [15:0] probe_addr = 16'hC020;
    wire        locked, dpal, busy;
    wire [15:0] mismatches_v, slip;
    wire [3:0]  state, err;
    wire [14:0] pos;
    wire [8:0]  scan_v;
    wire [6:0]  scan_h;

    vbl_lock #(.ACQ_TIMEOUT (ACQ_TIMEOUT)) u_vbl (
        .clk (clk), .rst (rst),
        .master_active (master_active),
        .held (held), .runtime (runtime),
        .tick (tick),
        .op_present (op_present), .op_ovr (op_ovr),
        .op_addr (op_addr), .op_rw (op_rw), .din (cpu_din),
        .start (start), .probe (probe), .probe_addr (probe_addr), .notify (1'b0),
        .ovr_en (vbl_ovr_en), .ovr_addr (vbl_ovr_addr), .ovr_rw (vbl_ovr_rw),
        .ovr_wdata (vbl_ovr_wdata),
        .mark (), .mark_free (), .vbl_level (vbl_level),
        .scan_v (scan_v), .scan_h (scan_h),
        .state (state), .locked (locked), .pal (dpal), .busy (busy), .err (err),
        .mismatches (mismatches_v), .slip (slip), .pos (pos),
        .frames (), .locks ()
    );

    // ---- the MMU shadow --------------------------------------------------------
    wire        cl_valid, cl_rw, cl_wr_image, cl_aux;
    wire [1:0]  cl_cls;
    wire [7:0]  cl_bank;
    wire [15:0] cl_off;
    wire [11:0] sw_state;
    wire [2:0]  vid_sw;

    apple_mmu u_mmu (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .rom_ok (1'b1), .intc8rom (), .q_rw (1'b1), .q_cls (),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux), .cl_bank (cl_bank),
        .cl_off (cl_off), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .pf_off (),
        .sw_state (sw_state), .vid_sw (vid_sw), .rw_bank (),
        .q_addr (16'd0), .q_divert (),
        .p_addr (16'd0), .p_cls (), .p_aux (), .p_off (), .map_changed ()
    );

    // ---- the DUT ------------------------------------------------------------
    reg         fb_serve = 1'b0, fb_cnt_clr = 1'b0;
    reg  [14:0] peek_addr = 15'd0;
    wire [6:0]  mode;
    wire [31:0] compared, mismatches, last, last2, other;
    wire [7:0]  peek_data;

    // The main bank's port B, stood in for: the card's main memory (cmem,
    // written beside the machine's on every main write), one registered
    // clock behind the address, as rtl/page_cache.sv serves it.
    wire [15:0] mb_addr;
    reg  [7:0]  mb_byte;
    always @(posedge clk) mb_byte <= cmem[mb_addr];

    fb_sim dut (
        .clk (clk), .rst (rst),
        .op_addr (op_addr), .op_rw (op_rw),
        .op_present (op_present), .op_commit (op_commit), .op_ovr (op_ovr),
        .mb_addr (mb_addr), .mb_byte (mb_byte),
        .sw_state (sw_state), .vid_sw (vid_sw),
        .locked (locked), .scan_v (scan_v), .scan_h (scan_h), .pal (dpal),
        .master_active (master_active),
        .data_sync (data_sync),
        .slot_rd_claim (1'b0), .kbd_sub_en (1'b0), .pb_sub_en (1'b0),
        .serve (fb_serve), .cnt_clr (fb_cnt_clr), .peek_addr (peek_addr),
        .sub_en (sub_en), .sub_data (sub_data),
        .mode (mode), .compared (compared), .mismatches (mismatches),
        .last (last), .last2 (last2), .other (other), .peek_data (peek_data)
    );

    // ---- the machine: two banks, the switches, the floating bus ------------------
    localparam integer BUS_AT = 70;

    reg [7:0] mem  [0:65535];       // main, the machine's
    reg [7:0] cmem [0:65535];       // main, the card's bank (diverges only
                                    // when a test corrupts one of them)
    reg [7:0] aux [0:65535];        // auxiliary
    reg       sw_text, sw_mixed, sw_page2, sw_hires, sw_store80, sw_col80, sw_ramwrt;
    reg       bus_dead = 1'b0;      // a floating bus that shows nothing
    reg [6:0] kbd_key = 7'h00;
    reg       kbd_strobe = 1'b0;

    // Which bank a write reaches: the IIe's steering.
    function wr_aux(input [15:0] a);
        begin
            if (a[15:12] >= 4'hC)           wr_aux = 1'b0;
            else if (a[15:10] == 6'b000001) wr_aux = sw_store80 ? sw_page2 : sw_ramwrt;
            else if (a[15:13] == 3'b001)    wr_aux = (sw_store80 && sw_hires) ? sw_page2 : sw_ramwrt;
            else if (a[15:9] == 7'd0)       wr_aux = 1'b0;
            else                            wr_aux = sw_ramwrt;
        end
    endfunction

    // The byte the scanner read this cycle, and where it was: text
    // addressing when TEXT, or MIXED on the lines V4 && V2; page 2 only
    // when 80STORE is off.
    wire        sc_text  = sw_text || (sw_mixed && V[7] && V[5]);
    wire        sc_hires = sw_hires && !sc_text;
    wire        sc_page2 = sw_page2 && !sw_store80;
    wire [15:0] sc_now   = sc_addr(V, H, sc_hires, sc_page2);
    wire [7:0]  sc_real  = mem[sc_now];
    wire [7:0]  sc_byte  = bus_dead ? 8'h00 : sc_real;

    // What the scanner showed for the op in flight.
    reg [7:0]  exp_byte;            // the picture's byte, dead bus or not
    reg [15:0] exp_addr;
    integer    cur_line;
    // A byte changed behind the copy's back: how often the scanner fetched it.
    reg [15:0] corrupt_addr = 16'hFFFF;
    integer    hits = 0;

    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        exp_byte = sc_real;
        exp_addr = sc_now;
        cur_line = sc_line(V, pal);
        if (rw_drive && addr_drive[15:8] == 8'hC0 && sc_now == corrupt_addr) hits = hits + 1;
        if (rw_drive) begin
            case (addr_drive)
                16'hC000: data_pin <= {kbd_strobe, kbd_key};
                16'hC010: begin data_pin <= 8'h00; kbd_strobe <= 1'b0; end
                16'hC050: begin sw_text  <= 1'b0; data_pin <= sc_byte; end
                16'hC051: begin sw_text  <= 1'b1; data_pin <= sc_byte; end
                16'hC052: begin sw_mixed <= 1'b0; data_pin <= sc_byte; end
                16'hC053: begin sw_mixed <= 1'b1; data_pin <= sc_byte; end
                16'hC054: begin sw_page2 <= 1'b0; data_pin <= sc_byte; end
                16'hC055: begin sw_page2 <= 1'b1; data_pin <= sc_byte; end
                16'hC056: begin sw_hires <= 1'b0; data_pin <= sc_byte; end
                16'hC057: begin sw_hires <= 1'b1; data_pin <= sc_byte; end
                default:  data_pin <= (addr_drive[15:12] == 4'hC) ? sc_byte : mem[addr_drive];
            endcase
        end else if (data_oe) begin
            case (addr_drive)
                16'hC000: sw_store80 <= 1'b0;
                16'hC001: sw_store80 <= 1'b1;
                16'hC004: sw_ramwrt  <= 1'b0;
                16'hC005: sw_ramwrt  <= 1'b1;
                16'hC00C: sw_col80   <= 1'b0;
                16'hC00D: sw_col80   <= 1'b1;
                16'hC050: sw_text  <= 1'b0;
                16'hC051: sw_text  <= 1'b1;
                16'hC052: sw_mixed <= 1'b0;
                16'hC053: sw_mixed <= 1'b1;
                16'hC054: sw_page2 <= 1'b0;
                16'hC055: sw_page2 <= 1'b1;
                16'hC056: sw_hires <= 1'b0;
                16'hC057: sw_hires <= 1'b1;
                default: begin
                    if (addr_drive[15:12] != 4'hC) begin
                        if (wr_aux(addr_drive)) aux[addr_drive] <= data_drive;
                        else begin
                            mem[addr_drive]  <= data_drive;
                            cmem[addr_drive] <= data_drive;
                        end
                    end
                end
            endcase
            data_pin <= data_drive;
        end
    end

    // ---- the running checks on the core's own floating reads --------------------
    function floats(input [15:0] a);
        floats = (a[15:8] == 8'hC0) && ((a[7:4] >= 4'h2 && a[7:4] <= 4'h5) || a[7:4] == 4'h7 || a[7:4] == 4'h8);
    endfunction

    reg     chk_en = 1'b0, want_sub = 1'b0;
    reg [7:0] want_byte;            // what the core should read
    integer core_reads = 0, core_bad = 0, sub_bad = 0, ev_bad = 0, bus_bad = 0, nz_reads = 0;
    always @(posedge clk) if (op_commit && chk_en && !op_ovr && op_rw && floats(op_addr)) begin
        core_reads = core_reads + 1;
        if (exp_byte != 8'h00) nz_reads = nz_reads + 1;
        want_byte = want_sub ? exp_byte : (bus_dead ? 8'h00 : exp_byte);
        if (cpu_din !== want_byte) begin
            core_bad = core_bad + 1;
            if (core_bad <= 3) $display("    core read $%04X got %02X, wanted %02X (line %0d)", op_addr, cpu_din, want_byte, cur_line);
        end
        if (sub_en !== want_sub) sub_bad = sub_bad + 1;
        if (data_sync !== (bus_dead ? 8'h00 : exp_byte)) bus_bad = bus_bad + 1;
    end
    always @(posedge clk) if (ev_valid && chk_en && ev_data[16] && floats(ev_data[15:0])) begin
        if (ev_data[27:20] !== (want_sub ? exp_byte : (bus_dead ? 8'h00 : exp_byte))) ev_bad = ev_bad + 1;
    end
    integer sub_on_ovr = 0, sub_col80 = 0;
    always @(posedge clk) begin
        if (sub_en && op_ovr) sub_on_ovr = sub_on_ovr + 1;
        if (sub_en && sw_col80) sub_col80 = sub_col80 + 1;
    end

    // ---- helpers ------------------------------------------------------------
    task cycles(input integer n);
        begin repeat (n * CYCLE) @(posedge clk); end
    endtask

    task at_offset(input integer off);
        begin
            @(posedge clk);
            while (since_fall != off) @(posedge clk);
            @(negedge clk);
        end
    endtask

    task machine_reset(input integer hold_cycles);
        begin
            at_offset(0);
            res_n = 1'b0;
            cycles(hold_cycles);
            at_offset(0);
            res_n = 1'b1;
        end
    endtask

    task pulse_start;   begin @(negedge clk); start = 1'b1; @(negedge clk); start = 1'b0; end endtask
    task pulse_probe;   begin @(negedge clk); probe = 1'b1; @(negedge clk); probe = 1'b0; end endtask
    task pulse_release; begin @(negedge clk); release_req = 1'b1; @(negedge clk); release_req = 1'b0; end endtask
    task pulse_clr;     begin @(negedge clk); fb_cnt_clr = 1'b1; @(negedge clk); fb_cnt_clr = 1'b0; end endtask

    task wait_idle(input integer max_cycles);
        integer n;
        begin
            n = 0;
            cycles(2);
            while (busy && n < max_cycles) begin cycles(1); n = n + 1; end
            if (busy) fail("the detector did not finish in time");
        end
    endtask

    // One override op, presented and committed.
    task ovr_op(input [15:0] a, input r, input [7:0] d);
        begin
            @(negedge clk);
            tb_ovr_addr = a; tb_ovr_rw = r; tb_ovr_wdata = d; tb_ovr_en = 1'b1;
            do @(negedge clk); while (!(op_present && op_ovr && op_addr == a && op_rw == r));
            tb_ovr_en = 1'b0;
            do @(negedge clk); while (!op_commit);
            // The switches and the monitor act on the commit's edge.
            repeat (3) @(negedge clk);
        end
    endtask
    task ovr_write(input [15:0] a, input [7:0] d); begin ovr_op(a, 1'b0, d); end endtask
    task ovr_read(input [15:0] a);                 begin ovr_op(a, 1'b1, 8'h00); end endtask

    // n override reads of a, back to back.
    task ovr_reads(input [15:0] a, input integer n);
        integer k;
        begin
            @(negedge clk);
            tb_ovr_addr = a; tb_ovr_rw = 1'b1; tb_ovr_en = 1'b1;
            k = 0;
            while (k < n) begin
                @(negedge clk);
                if (op_present && op_ovr && op_addr == a && op_rw) k = k + 1;
            end
            tb_ovr_en = 1'b0;
            do @(negedge clk); while (!op_commit);
            cycles(2);
        end
    endtask

    // The picture: never a zero byte, different on every page.
    function [7:0] pat(input [15:0] a);
        begin pat = ((a[7:0] ^ {a[12:8], a[15:13]}) + {a[11:10], 6'h13}) | 8'h01; end
    endfunction

    // A frame of floating-bus reads in the current mode: every cycle
    // compared, nothing wrong.
    integer c0, m0, o0, hole0, col0, k;
    integer period;
    task frame_ok(input [8*64-1:0] what);
        begin
            c0 = compared; m0 = mismatches; o0 = other;
            ovr_reads(16'hC020, period);
            if (compared != c0 + period) begin
                $display("FAIL: %0s: %0d compared over a frame, expected %0d", what, compared - c0, period); errors = errors + 1;
            end else if (mismatches != m0 || other != o0) begin
                $display("FAIL: %0s: %0d mismatches, other %08x (was %08x); last %08x %08x", what,
                         mismatches - m0, other, o0, last, last2); errors = errors + 1;
            end else $display("  ok: %0s - %0d cycles compared, 0 mismatches", what, period);
        end
    endtask

    // A frame with one byte changed behind the copy: counted where it should be.
    task frame_corrupt(input [8*64-1:0] what, input [15:0] a, input integer which);   // 0 ordinary, 1 hole, 2 col80
        reg [7:0] was;
        begin
            was = mem[a]; mem[a] = ~was; corrupt_addr = a; hits = 0;
            c0 = compared; m0 = mismatches; hole0 = other[15:0]; col0 = other[31:16];
            ovr_reads(16'hC020, period);
            mem[a] = was; corrupt_addr = 16'hFFFF;
            if (hits == 0) begin $display("FAIL: %0s: the scanner never fetched $%04X", what, a); errors = errors + 1; end
            else if ((mismatches - m0) != (which == 0 ? hits : 0) ||
                     (other[15:0] - hole0) != (which == 1 ? hits : 0) ||
                     (other[31:16] - col0) != (which == 2 ? hits : 0)) begin
                $display("FAIL: %0s: $%04X fetched %0d times; mismatches +%0d, holes +%0d, col80 +%0d", what, a, hits,
                         mismatches - m0, other[15:0] - hole0, other[31:16] - col0); errors = errors + 1;
            end else if (compared != c0 + period) begin
                $display("FAIL: %0s: %0d compared", what, compared - c0); errors = errors + 1;
            end else $display("  ok: %0s - $%04X fetched %0d times, every one counted in the right place", what, a, hits);
        end
    endtask

    task peek(input [14:0] a);
        begin
            @(negedge clk); peek_addr = a;
            repeat (4) @(negedge clk);
        end
    endtask

    integer i, bad, n0;

    initial begin
        $display("fb_sim_tb: the floating bus simulated, against the machine's\n");

        for (i = 0; i < 65536; i = i + 1) begin mem[i] = 8'hEA; cmem[i] = 8'hEA; aux[i] = 8'h00; end
        // The program: two floating reads and a write, forever.
        mem[16'hF000] = 8'hAD; mem[16'hF001] = 8'h20; mem[16'hF002] = 8'hC0;   // LDA $C020
        mem[16'hF003] = 8'hAD; mem[16'hF004] = 8'h30; mem[16'hF005] = 8'hC0;   // LDA $C030
        mem[16'hF006] = 8'h8D; mem[16'hF007] = 8'h00; mem[16'hF008] = 8'h03;   // STA $0300
        mem[16'hF009] = 8'h4C; mem[16'hF00A] = 8'h00; mem[16'hF00B] = 8'hF0;   // JMP $F000
        mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'hF0;
        sw_text = 1'b1; sw_mixed = 1'b0; sw_page2 = 1'b0; sw_hires = 1'b0;
        sw_store80 = 1'b0; sw_col80 = 1'b0; sw_ramwrt = 1'b0;
        period = NTSC_CYC;

        repeat (8) @(posedge clk);
        rst = 0;
        cycles(3);

        // --- case 1 / before the lock: nothing compared ---------------------------
        arm = 1'b1;
        machine_reset(4);
        cycles(30);
        if (held !== 1'b1) fail("case 1: not held");
        ovr_reads(16'hC020, 50);
        if (compared != 0) fail("case 1: floating reads compared before the lock");
        else $display("  ok: 50 floating reads before the lock, none compared");

        // --- case 2 / the lock, then the picture written through the bus ----------
        pulse_start;
        wait_idle(70_000);
        if (err !== 4'd0 || locked !== 1'b1 || dpal !== 1'b0 || mismatches_v !== 16'd0) fail("case 2: no clean NTSC lock");
        else $display("  ok: locked, NTSC, 0 mismatches in the lock's verify frame");
        for (i = 16'h0400; i < 16'h0C00; i = i + 1) ovr_write(i[15:0], pat(i[15:0]));
        for (i = 16'h2000; i < 16'h6000; i = i + 1) ovr_write(i[15:0], pat(i[15:0]));
        $display("  ok: both text pages and both hi-res pages written through the bus");
        // The copy, byte for byte, through the peek.
        bad = 0;
        for (i = 0; i < 2048; i = i + 1) begin
            peek(i[14:0]);
            if (peek_data !== mem[16'h0400 + i]) bad = bad + 1;
        end
        for (i = 0; i < 16384; i = i + 1) begin
            peek(15'h4000 | i[14:0]);
            if (peek_data !== mem[16'h2000 + i]) bad = bad + 1;
        end
        if (bad != 0) begin $display("FAIL: case 2: %0d of 18432 peeked bytes differ from the machine's memory", bad); errors = errors + 1; end
        else $display("  ok: the peek reads all 18432 bytes of the copy back, equal to the machine's memory");

        // --- case 3 / every mode, a frame each -------------------------------------
        frame_ok("text page 1");
        ovr_read(16'hC055);
        if (mode !== 7'b0010011) begin $display("FAIL: case 3: mode %b after PAGE2 on, expected text page 2 shown", mode); errors = errors + 1; end
        frame_ok("text page 2");
        ovr_read(16'hC050); ovr_read(16'hC057); ovr_read(16'hC054);
        if (mode !== 7'b0001001) begin $display("FAIL: case 3: mode %b in hi-res page 1", mode); errors = errors + 1; end
        frame_ok("hi-res page 1");
        ovr_read(16'hC055);
        frame_ok("hi-res page 2");
        ovr_read(16'hC053);
        if (mode !== 7'b0011101) begin $display("FAIL: case 3: mode %b in mixed hi-res page 2", mode); errors = errors + 1; end
        frame_ok("mixed hi-res page 2");
        ovr_read(16'hC054);
        frame_ok("mixed hi-res page 1");
        ovr_write(16'hC001, 8'h00);                       // 80STORE: page 2 selected, page 1 shown
        ovr_read(16'hC055);
        if (mode !== 7'b1001101) begin $display("FAIL: case 3: mode %b with 80STORE and PAGE2", mode); errors = errors + 1; end
        frame_ok("mixed hi-res, PAGE2 under 80STORE (page 1 shown)");
        ovr_read(16'hC052); ovr_read(16'hC051);
        frame_ok("text, PAGE2 under 80STORE (page 1 shown)");
        ovr_write(16'hC000, 8'h00); ovr_read(16'hC054); ovr_read(16'hC056);

        // --- case 4 / a byte changed behind the copy: counted in its place --------
        frame_corrupt("text page 1, an ordinary byte", 16'h0591, 0);
        frame_corrupt("text page 1, a screen hole", 16'h04FB, 1);
        ovr_read(16'hC050); ovr_read(16'hC057);
        frame_corrupt("hi-res page 1, one byte", 16'h3456, 0);
        ovr_read(16'hC053);
        frame_corrupt("mixed hi-res page 1, a byte on a text line", 16'h07D0, 0);
        ovr_read(16'hC052); ovr_read(16'hC051);
        ovr_write(16'hC00D, 8'h00);                       // 80COL
        if (mode[5] !== 1'b1) fail("case 4: col80 not in the mode");
        frame_corrupt("text page 1 in 80 columns", 16'h0591, 2);
        ovr_write(16'hC00C, 8'h00);
        frame_ok("text page 1 again, nothing changed");

        // --- case 5 / writes the switches steer away never enter the copy --------
        ovr_write(16'hC001, 8'h00); ovr_read(16'hC055);   // 80STORE + PAGE2: text writes to aux
        ovr_write(16'h0400, 8'hAA);
        peek(15'd0);
        if (peek_data !== pat(16'h0400) || mem[16'h0400] !== pat(16'h0400) || aux[16'h0400] !== 8'hAA)
            fail("case 5: a $0400 write under 80STORE+PAGE2 reached the copy, or did not reach aux");
        else $display("  ok: $0400 written under 80STORE+PAGE2 goes to aux and not into the copy");
        ovr_read(16'hC057);                               // + HIRES: hi-res writes to aux too
        ovr_write(16'h2000, 8'hBB);
        peek(15'h4000);
        if (peek_data !== pat(16'h2000) || aux[16'h2000] !== 8'hBB) fail("case 5: a $2000 write under 80STORE+HIRES+PAGE2 reached the copy");
        else $display("  ok: $2000 written under 80STORE+HIRES+PAGE2 stays out of the copy");
        ovr_write(16'hC000, 8'h00); ovr_read(16'hC054); ovr_read(16'hC056);
        ovr_write(16'hC005, 8'h00);                       // RAMWRT
        ovr_write(16'h2000, 8'hCC);
        ovr_write(16'h0800, 8'hCD);
        peek(15'h4000);
        if (peek_data !== pat(16'h2000) || aux[16'h2000] !== 8'hCC) fail("case 5: a RAMWRT write to $2000 reached the copy");
        peek(15'h0400);
        if (peek_data !== pat(16'h0800) || aux[16'h0800] !== 8'hCD) fail("case 5: a RAMWRT write to $0800 reached the copy");
        else $display("  ok: RAMWRT writes to $2000 and $0800 stay out of the copy");
        ovr_write(16'hC073, 8'h02);                       // a RamWorks bank
        ovr_write(16'h4000, 8'hEE);
        peek(15'h6000);
        if (peek_data !== pat(16'h4000)) fail("case 5: a RamWorks bank write reached the copy");
        else $display("  ok: a write to RamWorks bank 2 stays out of the copy");
        ovr_write(16'hC073, 8'h00);
        ovr_write(16'hC004, 8'h00);                       // main again
        ovr_write(16'h2000, 8'hDD);
        ovr_write(16'h0800, 8'hDE);
        peek(15'h4000);
        if (peek_data !== 8'hDD || mem[16'h2000] !== 8'hDD) fail("case 5: a main-memory write to $2000 did not enter the copy");
        peek(15'h0400);
        if (peek_data !== 8'hDE || mem[16'h0800] !== 8'hDE) fail("case 5: a main-memory write to $0800 did not enter the copy");
        else $display("  ok: the same writes to main memory enter the copy");
        frame_ok("text page 1 after the steered writes");
        ovr_read(16'hC057); ovr_read(16'hC050); ovr_read(16'hC055);
        frame_ok("hi-res page 2 after the steered writes");
        ovr_read(16'hC054); ovr_read(16'hC056); ovr_read(16'hC051);

        // --- case 6 / serving the core -------------------------------------------
        // The core runs its loop; the checks pair every floating read it
        // makes with the byte the scanner showed.
        pulse_release;
        cycles(20);
        if (held !== 1'b0) fail("case 6: still held");
        // (a) not serving, the bus alive: the core reads the bus, which is right.
        chk_en = 1'b1; want_sub = 1'b0;
        core_reads = 0; core_bad = 0; sub_bad = 0; ev_bad = 0; bus_bad = 0; m0 = mismatches;
        cycles(NTSC_CYC * 2);
        if (core_reads < 2000 || core_bad != 0 || sub_bad != 0 || ev_bad != 0 || mismatches != m0) begin
            $display("FAIL: case 6a: %0d reads, %0d wrong, %0d substituted, %0d events wrong, +%0d mismatches",
                     core_reads, core_bad, sub_bad, ev_bad, mismatches - m0); errors = errors + 1;
        end else $display("  ok: not serving - %0d core reads took the bus's byte, 0 mismatches", core_reads);
        // (b) serving, the bus alive: the same bytes, now from the copy.
        @(negedge clk); fb_serve = 1'b1; want_sub = 1'b1;
        cycles(3);
        core_reads = 0; core_bad = 0; sub_bad = 0; ev_bad = 0; bus_bad = 0; m0 = mismatches;
        cycles(NTSC_CYC * 2);
        if (core_reads < 2000 || core_bad != 0 || sub_bad != 0 || ev_bad != 0 || bus_bad != 0 || mismatches != m0) begin
            $display("FAIL: case 6b: %0d reads, %0d wrong, %0d not substituted, %0d events wrong, %0d bus wrong, +%0d mismatches",
                     core_reads, core_bad, sub_bad, ev_bad, bus_bad, mismatches - m0); errors = errors + 1;
        end else $display("  ok: serving - %0d core reads substituted, the events carry the byte, the bus still right", core_reads);
        // (c) serving with the machine's floating bus dead: the core still
        // sees the picture, the bus shows nothing, the monitor counts it.
        bus_dead = 1'b1;
        cycles(3);
        core_reads = 0; nz_reads = 0; core_bad = 0; sub_bad = 0; ev_bad = 0; bus_bad = 0; m0 = mismatches; hole0 = other[15:0];
        cycles(NTSC_CYC * 2);
        // Every read disagrees with the dead bus: on a hole cycle in FB_OTHER, elsewhere in FB_MISMATCH.
        if (core_reads < 2000 || core_bad != 0 || sub_bad != 0 || ev_bad != 0 || bus_bad != 0 ||
            (mismatches - m0) + (other[15:0] - hole0) != nz_reads || (mismatches - m0) == 0) begin
            $display("FAIL: case 6c: %0d reads (%0d non-zero), %0d wrong, %0d not substituted, %0d events wrong, %0d bus wrong, +%0d mismatches, +%0d on holes",
                     core_reads, nz_reads, core_bad, sub_bad, ev_bad, bus_bad, mismatches - m0, other[15:0] - hole0); errors = errors + 1;
        end else $display("  ok: the machine's floating bus dead - %0d core reads still see the picture, every one counted (%0d on holes)", core_reads, other[15:0] - hole0);
        // (d) not serving with it dead: the core sees nothing.
        @(negedge clk); fb_serve = 1'b0; want_sub = 1'b0;
        cycles(3);
        core_reads = 0; core_bad = 0; sub_bad = 0; ev_bad = 0;
        cycles(NTSC_CYC);
        if (core_reads < 1000 || core_bad != 0 || sub_bad != 0 || ev_bad != 0) begin
            $display("FAIL: case 6d: %0d reads, %0d wrong, %0d substituted, %0d events wrong", core_reads, core_bad, sub_bad, ev_bad); errors = errors + 1;
        end else $display("  ok: not serving, the bus dead - the core reads nothing, as the machine would give it");
        bus_dead = 1'b0;
        // (e) serving in 80 columns: never substituted.
        ovr_write(16'hC00D, 8'h00);
        @(negedge clk); fb_serve = 1'b1; want_sub = 1'b0;
        cycles(3);
        core_reads = 0; core_bad = 0; sub_bad = 0; ev_bad = 0;
        cycles(NTSC_CYC);
        if (core_reads < 1000 || core_bad != 0 || sub_bad != 0 || ev_bad != 0 || sub_col80 != 0) begin
            $display("FAIL: case 6e: %0d reads, %0d wrong, %0d substituted in 80 columns", core_reads, core_bad, sub_bad); errors = errors + 1;
        end else $display("  ok: serving in 80 columns - %0d core reads, none substituted", core_reads);
        ovr_write(16'hC00C, 8'h00);
        chk_en = 1'b0;
        // (f) the probe's frame stays real with serve on.
        machine_reset(4);
        cycles(30);
        if (held !== 1'b1) fail("case 6f: not held");
        c0 = compared; m0 = mismatches;
        probe_addr = 16'hC020;
        pulse_probe;
        wait_idle(20_000);
        if (err !== 4'd0 || compared != c0 + NTSC_CYC || mismatches != m0 || sub_on_ovr != 0) begin
            $display("FAIL: case 6f: err %0d, %0d compared over the probe, +%0d mismatches, %0d substitutions on overrides",
                     err, compared - c0, mismatches - m0, sub_on_ovr); errors = errors + 1;
        end else $display("  ok: the probe's %0d reads are compared, none substituted, 0 mismatches", NTSC_CYC);
        @(negedge clk); fb_serve = 1'b0;

        // --- case 7 / the counters clear -------------------------------------------
        pulse_clr;
        cycles(1);
        if (compared != 0 || mismatches != 0 || other != 0 || last != 0 || last2 != 0) fail("case 7: the counters did not clear");
        else $display("  ok: the counters clear");

        // --- case 8 / PAL --------------------------------------------------------
        pal = 1'b1;
        machine_reset(4);
        cycles(30);
        pulse_start;
        wait_idle(80_000);
        if (err !== 4'd0 || locked !== 1'b1 || dpal !== 1'b1 || mismatches_v !== 16'd0) fail("case 8: no clean PAL lock");
        else $display("  ok: PAL - locked, pal=1, 0 mismatches in the lock's verify frame");
        period = PAL_CYC;
        // The lock's fill repainted text page 1 through the bus; the copy followed.
        frame_ok("PAL text page 1");
        ovr_read(16'hC050); ovr_read(16'hC057); ovr_read(16'hC053); ovr_read(16'hC055);
        frame_ok("PAL mixed hi-res page 2");
        ovr_read(16'hC054);
        frame_corrupt("PAL mixed hi-res page 1, one byte", 16'h2ABC, 0);
        ovr_read(16'hC052); ovr_read(16'hC051);

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
