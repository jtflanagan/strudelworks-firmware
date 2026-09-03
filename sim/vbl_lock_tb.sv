`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// vbl_lock_tb - the scanner found on the floating bus, and followed.
//
// The real reader, driver, core, hold and detector, wired as master_top wires
// them, against an Apple whose VIDEO SCANNER is modelled and whose floating
// bus returns what that scanner read.  The scanner here is NOT the RTL's
// formula: it is Sather's counters themselves - a 7-bit H that presets from
// $00 to $40 and a 9-bit V that presets from $1FF to $FA or $C8 - with the
// address bits picked off them as his diagram has it.  The RTL derives the
// same addresses arithmetically from a line and a cycle count; the two
// agreeing on every cycle of a frame is one of the properties below.
//
// THE PROPERTIES, each a way this is or could be wrong:
//
//   * a start with the machine not held, or held by the runtime door, is
//     refused and presents nothing.
//   * held at the vector, a start presents the seven switch accesses in
//     order, then exactly 960 writes: every non-hole byte of the text page,
//     ascending, with its row's letter, and NO hole touched.  The switches
//     start wrong (hi-res, page 2, aux writes) so that the fill would miss
//     if they were not set.
//   * then reads of $C054 until the lock: locked, NTSC, no error, zero
//     mismatches over the verify frame.  Then the hold's keyboard reads
//     resume and the machine is still held.
//   * from then on the counter agrees with the scanner on EVERY cycle - held
//     or running - and with notify on, the mark is raised on exactly the
//     cycles where the scanner is at V=$100, H=$00, and on no other.
//   * a second detection on a locked counter reports slip 0.
//   * a reset in the middle of a detection aborts it (err 4) and the earlier
//     lock stands.
//   * a probe reads probe_addr exactly one period of cycles; a //e's $C019
//     modelled on the tb's scanner shows VBL' low exactly where the DUT's
//     counter says lines 192 and up are.
//   * on a PAL machine the lock says so, and the counter wraps at 20280.
//   * a floating bus that shows nothing gives err 2 after the timeout, and
//     the lock stands.
//
// The screen holes hold 'A', 'H' and 'Q' - the three bytes the acquisition
// looks at - throughout.
//////////////////////////////////////////////////////////////////////////////////

module vbl_lock_tb #(parameter UCODE = "cpu65c02_ucode.hex");

    localparam integer T_PRESENT = 2;
    localparam integer T_EMIT    = 2;
    localparam integer T_DIN     = 44;
    localparam integer T_CYCEN   = 45;
    localparam integer ACQ_TIMEOUT = 22_000;    // one PAL frame and change, for the timeout case

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;               // 100 MHz

    integer errors = 0;
    task fail(input [8*96-1:0] why);
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
    // Advanced at the start of every cycle; free-running from time zero and
    // never reset, as the machine's is.  `pal` picks the vertical preset.
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

    // Text page 1's address for the scanner's state, as the diagram wires it:
    // A0-A2 = H0-H2, A3-A6 = H5H4H3 + V4V3V4V3 + 1101, A7-A9 = V0-V2, A10 = 1.
    function [15:0] sc_addr(input [8:0] v, input [6:0] hh);
        reg [3:0] sum;
        begin
            sum = {1'b0, hh[5:3]} + {v[7], v[6], v[7], v[6]} + 4'b1101;
            sc_addr = {5'b00000, 1'b1, v[5:3], sum, hh[2:0]};
        end
    endfunction

    // The scanner's position as a line and a cycle, for the checks.
    function integer sc_line(input [8:0] v, input p);
        begin
            if (v >= 9'h100) sc_line = v - 9'h100;
            else             sc_line = v + 256 - (p ? 9'hC8 : 9'hFA);
        end
    endfunction
    function integer sc_hc(input [6:0] hh);
        begin sc_hc = (hh == 7'h00) ? 0 : hh - 7'h3F; end
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
    wire        vbl_level;          // the DUT's level, into bit 19 of the event
    wire [31:0] ev_data;
    wire        ev_valid;

    apple_bus_read u_read (
        .clk (clk), .rst (rst), .enable (1'b1),
        .apple_data_pin (data_pin), .apple_addr_pin (addr_drive), .apple_rw_pin (rw_drive),
        .apple_phi0_pin (phi0), .apple_m2sel_pin (1'b0), .apple_m2b0_pin (1'b1),
        .apple_inh_pin (1'b1), .apple_res_pin (res_n), .apple_irq_pin (1'b1),
        .apple_rdy_pin (1'b1), .apple_dma_pin (!dma_assert),
        .ev_data (ev_data), .ev_valid (ev_valid), .data_tick (tick),
        .sync_override (drv_sync), .sync_override_en (1'b1),
        .data_override (8'h00), .data_override_en (1'b0),
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

    // ---- the driver, and the mux as master_top has it ----------------------------
    wire [15:0] op_addr;
    wire        op_rw, op_present, op_commit, op_ovr;
    wire [7:0]  op_wdata;
    wire        hold_ovr_en, vbl_ovr_en, vbl_ovr_rw;
    wire [15:0] hold_ovr_addr, vbl_ovr_addr;
    wire [7:0]  vbl_ovr_wdata;
    wire        ovr_en   = hold_ovr_en | vbl_ovr_en;
    wire [15:0] ovr_addr = vbl_ovr_en ? vbl_ovr_addr : hold_ovr_addr;
    wire        ovr_rw   = vbl_ovr_en ? vbl_ovr_rw   : 1'b1;

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) u_write (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0_sync), .data_sync (data_sync),
        .master_active (master_active), .park_kbd (1'b0),
        // Without the sequencer: the bus owns every cycle, the core is always on offer.
        .bus_owns (1'b1), .core_valid (1'b1),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .drv_sync (drv_sync),
        .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (1'b0), .slot_rd_data (8'h00),
        .din_sub_en (1'b0), .din_sub_data (8'h00),
        .ovr_en (ovr_en), .ovr_addr (ovr_addr), .ovr_rw (ovr_rw),
        .ovr_wdata (vbl_ovr_wdata), .op_ovr (op_ovr), .nxt_addr (), .divert (1'b0), .op_divert (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- the hold -----------------------------------------------------------
    reg  arm = 1'b0;
    reg  release_req = 1'b0;
    reg  menu_trigger = 1'b0;
    wire held, runtime;

    boot_hold u_hold (
        .clk (clk), .cpu_rst (cpu_rst),
        .master_active (master_active),
        .arm (arm), .release_req (release_req),
        .menu_trigger (menu_trigger), .hotkey_hit (1'b0),
        .turbo_sync (1'b0), .cpu_sync (cpu_sync),
        .op_present (op_present), .op_commit (op_commit),
        .op_sync (drv_sync), .op_ovr (op_ovr),
        .op_addr (op_addr), .op_rw (op_rw), .din (cpu_din),
        .ovr_en (hold_ovr_en), .ovr_addr (hold_ovr_addr),
        .held (held), .runtime (runtime)
    );

    // ---- the DUT ------------------------------------------------------------
    reg         start = 1'b0, probe = 1'b0, notify = 1'b0;
    reg  [15:0] probe_addr = 16'hC019;
    wire        mark, locked, dpal, busy;
    wire [15:0] mark_free, mismatches, slip;
    wire [3:0]  state, err;
    wire [14:0] pos;
    wire [7:0]  frames, locks;

    vbl_lock #(.ACQ_TIMEOUT (ACQ_TIMEOUT)) dut (
        .clk (clk), .rst (rst),
        .master_active (master_active),
        .held (held), .runtime (runtime),
        .tick (tick),
        .op_present (op_present), .op_ovr (op_ovr),
        .op_addr (op_addr), .op_rw (op_rw), .din (cpu_din),
        .start (start), .probe (probe), .probe_addr (probe_addr), .notify (notify),
        .ovr_en (vbl_ovr_en), .ovr_addr (vbl_ovr_addr), .ovr_rw (vbl_ovr_rw),
        .ovr_wdata (vbl_ovr_wdata),
        .mark (mark), .mark_free (mark_free), .vbl_level (vbl_level),
        .state (state), .locked (locked), .pal (dpal), .busy (busy), .err (err),
        .mismatches (mismatches), .slip (slip), .pos (pos),
        .frames (frames), .locks (locks)
    );

    // ---- the machine: memory, switches, keyboard, and the floating bus ----------
    localparam integer BUS_AT = 70;
    localparam [15:0] VECTOR = 16'hF000;

    reg [7:0] mem  [0:65535];       // main
    reg [7:0] aux  [0:65535];       // auxiliary, where RAMWRT sends writes
    reg [7:0] hole_copy [0:63];     // the holes as they were, to check they stay
    reg       sw_text, sw_mixed, sw_page2, sw_hires, sw_store80, sw_col80, sw_ramwrt;
    reg       bus_dead = 1'b0;      // a floating bus that shows nothing
    reg [6:0] kbd_key = 7'h00;
    reg       kbd_strobe = 1'b0;

    // The byte the scanner read this cycle, and where it was.
    wire [15:0] sc_now  = sc_addr(V, H);
    wire [7:0]  sc_byte = (sw_text && !sw_hires && !sw_page2 && !bus_dead) ? mem[sc_now] : 8'h00;
    wire        vbl_n   = (sc_line(V, pal) < 192);

    // What the scanner showed for the op in flight, recorded when the bus
    // answered; the checks pair it with the DUT's word at the commit.
    integer cur_line, cur_hc, cur_fc;
    integer log_line = 0;

    always @(posedge clk) if (since_fall == BUS_AT && driving) begin
        cur_line = sc_line(V, pal);
        cur_hc   = sc_hc(H);
        cur_fc   = cur_line * 65 + cur_hc;
        if (rw_drive) begin
            case (addr_drive)
                16'hC000: data_pin <= {kbd_strobe, kbd_key};
                16'hC010: begin data_pin <= 8'h00; kbd_strobe <= 1'b0; end
                16'hC019: data_pin <= {vbl_n, sc_byte[6:0]};
                16'hC050: begin sw_text  <= 1'b0; data_pin <= sc_byte; end
                16'hC051: begin sw_text  <= 1'b1; data_pin <= sc_byte; end
                16'hC052: begin sw_mixed <= 1'b0; data_pin <= sc_byte; end
                16'hC053: begin sw_mixed <= 1'b1; data_pin <= sc_byte; end
                16'hC054: begin sw_page2 <= 1'b0; data_pin <= sc_byte; end
                16'hC055: begin sw_page2 <= 1'b1; data_pin <= sc_byte; end
                16'hC056: begin sw_hires <= 1'b0; data_pin <= sc_byte; end
                16'hC057: begin sw_hires <= 1'b1; data_pin <= sc_byte; end
                default:  data_pin <= (addr_drive >= 16'hC000 && addr_drive < 16'hD000)
                                      ? sc_byte : (sw_ramwrt && addr_drive >= 16'h0200 && addr_drive < 16'hC000
                                                   ? mem[addr_drive] : mem[addr_drive]);
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
                    if (sw_ramwrt && addr_drive >= 16'h0200 && addr_drive < 16'hC000)
                        aux[addr_drive] <= data_drive;
                    else
                        mem[addr_drive] <= data_drive;
                end
            endcase
            data_pin <= data_drive;
        end
    end

    // ---- the op log (windowed) ---------------------------------------------------
    reg [15:0] log_addr [0:4095];
    reg        log_rw   [0:4095];
    reg        log_ovr  [0:4095];
    reg [7:0]  log_wd   [0:4095];
    reg        log_en = 1'b0;
    integer    nops = 0;
    always @(posedge clk) if (op_present && log_en && nops < 4096) begin
        log_addr[nops] = op_addr;
        log_rw[nops]   = op_rw;
        log_ovr[nops]  = op_ovr;
        log_wd[nops]   = op_wdata;
        nops = nops + 1;
    end

    // ---- the running checks ----------------------------------------------------------
    // At every commit: the DUT's position (pre-increment: the cycle just
    // done) against the scanner's for the op that just completed, and the
    // mark against the origin.
    reg     track_en = 1'b0;
    integer track_n = 0, track_bad = 0, marks = 0, marks_bad = 0, origins = 0, origins_unmarked = 0;
    integer last_mark_fc = -1, mark_gap = 0;
    always @(posedge clk) if (op_commit && track_en) begin
        track_n = track_n + 1;
        if (pos !== cur_fc[14:0]) begin
            track_bad = track_bad + 1;
            if (track_bad <= 3) $display("    track: dut fc=%0d, scanner line %0d cycle %0d (fc %0d)",
                                         pos, cur_line, cur_hc, cur_fc);
        end
        if (mark) begin
            marks = marks + 1;
            if (cur_fc != 0) marks_bad = marks_bad + 1;
            if (last_mark_fc >= 0) mark_gap = marks_total_cycles - last_mark_fc;
            last_mark_fc = marks_total_cycles;
        end
        if (cur_fc == 0) begin
            origins = origins + 1;
            if (!mark) origins_unmarked = origins_unmarked + 1;
        end
    end
    integer marks_total_cycles = 0;
    always @(posedge clk) if (op_commit) marks_total_cycles = marks_total_cycles + 1;

    // The VBL level against the scanner: high exactly on lines 192 and up
    // (AppleWin's VBL', on the floating-bus count), never before the lock,
    // and bit 19 of every event the reader emits is that level - with the
    // m2b0 pin tied HIGH above, so a reader still recording the pin would
    // be caught here.
    integer vbl_n_chk = 0, vbl_bad = 0, vbl_early = 0, ev_n = 0, ev_vbl_bad = 0;
    always @(posedge clk) if (op_commit && track_en) begin
        vbl_n_chk = vbl_n_chk + 1;
        if (vbl_level !== (cur_line >= 192)) begin
            vbl_bad = vbl_bad + 1;
            if (vbl_bad <= 3) $display("    vbl: level %0d on scanner line %0d cycle %0d", vbl_level, cur_line, cur_hc);
        end
    end
    always @(posedge clk) if (!locked && vbl_level) vbl_early = vbl_early + 1;
    always @(posedge clk) if (ev_valid) begin
        ev_n = ev_n + 1;
        if (ev_data[19] !== vbl_level) ev_vbl_bad = ev_vbl_bad + 1;
    end

    // The probe: every $C019 read's bit 7 against the DUT's own line.
    integer probe_reads = 0, probe_bad = 0, probe_low = 0;
    reg     probe_en = 1'b0;
    always @(posedge clk) if (op_commit && probe_en && op_addr == 16'hC019 && op_rw && op_ovr) begin
        probe_reads = probe_reads + 1;
        if (!cpu_din[7]) probe_low = probe_low + 1;
        if (cpu_din[7] !== (pos < 15'd12480)) probe_bad = probe_bad + 1;
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

    task pulse_start;  begin @(negedge clk); start = 1'b1; @(negedge clk); start = 1'b0; end endtask
    task pulse_probe;  begin @(negedge clk); probe = 1'b1; @(negedge clk); probe = 1'b0; end endtask
    task pulse_release; begin @(negedge clk); release_req = 1'b1; @(negedge clk); release_req = 1'b0; end endtask
    task pulse_trigger; begin @(negedge clk); menu_trigger = 1'b1; @(negedge clk); menu_trigger = 1'b0; end endtask

    // Wait for the DUT to go idle, or give up.
    task wait_idle(input integer max_cycles);
        integer n;
        begin
            n = 0;
            cycles(2);
            while (busy && n < max_cycles) begin cycles(1); n = n + 1; end
            if (busy) fail("the detector did not finish in time");
        end
    endtask

    task wait_state(input [3:0] s, input integer max_cycles);
        integer n;
        begin
            n = 0;
            while (state != s && n < max_cycles) begin cycles(1); n = n + 1; end
            if (state != s) fail("the detector did not reach the expected state");
        end
    endtask

    // Fill the holes with the three letters the acquisition looks at.
    task set_holes;
        integer s, b;
        begin
            for (s = 0; s < 8; s = s + 1)
                for (b = 0; b < 8; b = b + 1) begin
                    mem[16'h0478 + s * 16'h80 + b] = (b % 3 == 0) ? 8'hC1 : (b % 3 == 1) ? 8'hC8 : 8'hD1;
                    hole_copy[s * 8 + b] = mem[16'h0478 + s * 16'h80 + b];
                end
        end
    endtask

    // Row r of the text page, per the fill's convention.
    function [7:0] row_byte(input [15:0] a);
        reg [1:0] g;
        begin
            g = (a[6:0] < 7'h28) ? 2'd0 : (a[6:0] < 7'h50) ? 2'd1 : 2'd2;
            row_byte = 8'hC1 + {3'b000, g, a[9:7]};
        end
    endfunction

    integer i, k, base, bad, ovr_count, fill_n, sw_n, period_seen;
    reg [15:0] prev_addr;

    initial begin
        $display("vbl_lock_tb: the scanner found on the floating bus, and followed\n");

        for (i = 0; i < 65536; i = i + 1) begin mem[i] = 8'hEA; aux[i] = 8'h00; end
        mem[16'hF000] = 8'hA9; mem[16'hF001] = 8'h42;
        mem[16'hF002] = 8'h8D; mem[16'hF003] = 8'h00; mem[16'hF004] = 8'h03;
        mem[16'hF005] = 8'h4C; mem[16'hF006] = 8'h05; mem[16'hF007] = 8'hF0;
        mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'hF0;
        set_holes;
        // The switches start WRONG: the fill must set them.
        sw_text = 1'b0; sw_mixed = 1'b1; sw_page2 = 1'b1; sw_hires = 1'b1;
        sw_store80 = 1'b1; sw_col80 = 1'b1; sw_ramwrt = 1'b1;

        repeat (8) @(posedge clk);
        rst = 0;
        cycles(3);

        // --- case 1 / not held: refused, nothing presented --------------------
        machine_reset(4);
        cycles(30);
        if (held !== 1'b0) fail("case 1: held with the hold unarmed");
        log_en = 1'b1; nops = 0;
        pulse_start;
        cycles(20);
        log_en = 1'b0;
        if (err !== 4'd1) fail("case 1: a start on an unheld machine was not refused (err 1)");
        else if (busy) fail("case 1: busy after a refused start");
        else begin
            ovr_count = 0;
            for (i = 0; i < nops; i = i + 1) if (log_ovr[i]) ovr_count = ovr_count + 1;
            if (ovr_count != 0) fail("case 1: an override was presented after a refused start");
            else $display("  ok: not held - the start is refused (err 1) and nothing is presented");
        end

        // --- case 2 / held at the vector: switches, fill, lock -------------------
        arm = 1'b1;
        machine_reset(4);
        cycles(30);
        if (held !== 1'b1 || runtime !== 1'b0) fail("case 2: not boot-held");
        // Case 1's program ran with RAMWRT on and left its mark in aux;
        // from here every byte that lands there is the fill's fault.
        for (i = 0; i < 65536; i = i + 1) aux[i] = 8'h00;
        log_en = 1'b1; nops = 0;
        pulse_start;
        cycles(4);
        if (!busy) fail("case 2: not busy after start");
        wait_state(4'd3, 2000);                     // ACQ: the switches and the fill are done
        cycles(3);                                  // ...and the first probe read is out
        log_en = 1'b0;
        // The first 7 override ops are the switches, the first of them a
        // WRITE to $C000 - which is how it is told from the hold's reads.
        base = -1;
        for (i = 0; i < nops && base < 0; i = i + 1) if (log_ovr[i] && !log_rw[i]) base = i;
        if (base < 0 || nops < base + 967) fail("case 2: too few ops logged for the switches and the fill");
        else begin
            sw_n = 0;
            if (log_rw[base+0] !== 1'b0 || log_addr[base+0] !== 16'hC000) sw_n = 1;
            if (log_rw[base+1] !== 1'b0 || log_addr[base+1] !== 16'hC004) sw_n = 1;
            if (log_rw[base+2] !== 1'b0 || log_addr[base+2] !== 16'hC00C) sw_n = 1;
            if (log_rw[base+3] !== 1'b1 || log_addr[base+3] !== 16'hC051) sw_n = 1;
            if (log_rw[base+4] !== 1'b1 || log_addr[base+4] !== 16'hC052) sw_n = 1;
            if (log_rw[base+5] !== 1'b1 || log_addr[base+5] !== 16'hC054) sw_n = 1;
            if (log_rw[base+6] !== 1'b1 || log_addr[base+6] !== 16'hC056) sw_n = 1;
            if (sw_n) fail("case 2: the seven switch accesses are not the expected ones, in order");
            else $display("  ok: 80STORE, RAMWRT, 80COL written off; TEXT, MIXED off, PAGE1, HIRES off read");
            // Then 960 writes, ascending, never a hole, each its row's letter.
            fill_n = 0; bad = 0; prev_addr = 16'h03FF;
            for (i = base + 7; i < base + 967; i = i + 1) begin
                if (!log_ovr[i] || log_rw[i] !== 1'b0) bad = bad + 1;
                else begin
                    fill_n = fill_n + 1;
                    if (log_addr[i] <= prev_addr) bad = bad + 1;
                    if (log_addr[i] < 16'h0400 || log_addr[i] > 16'h07FF) bad = bad + 1;
                    if (log_addr[i][6:0] >= 7'h78) bad = bad + 1;
                    if (log_wd[i] !== row_byte(log_addr[i])) bad = bad + 1;
                    prev_addr = log_addr[i];
                end
            end
            if (bad != 0 || fill_n != 960) begin
                $display("FAIL: case 2: the fill - %0d writes, %0d wrong", fill_n, bad); errors = errors + 1;
            end else $display("  ok: 960 writes, ascending through the page, every row its letter, no hole");
            if (log_addr[base+7] !== 16'h0400 || log_addr[base+966] !== 16'h07F7)
                fail("case 2: the fill does not run from $0400 to $07F7");
            // ...and after them, reads of $C054.
            if (!log_ovr[base+967] || log_rw[base+967] !== 1'b1 || log_addr[base+967] !== 16'hC054)
                fail("case 2: the first op after the fill is not a read of $C054");
        end
        wait_idle(70_000);
        if (err !== 4'd0) begin $display("FAIL: case 2: err=%0d after the run", err); errors = errors + 1; end
        if (locked !== 1'b1) fail("case 2: not locked");
        else if (dpal !== 1'b0) fail("case 2: NTSC read as PAL");
        else if (mismatches !== 16'd0) begin
            $display("FAIL: case 2: %0d mismatches in the verify frame", mismatches); errors = errors + 1;
        end else if (locks !== 8'd1) fail("case 2: locks is not 1");
        else if (slip !== 16'd0) fail("case 2: a first lock reported a slip");
        else $display("  ok: locked, NTSC, no error, 0 mismatches over the verify frame, slip 0");
        // Memory: every non-hole byte its letter, every hole as it was.
        bad = 0;
        for (i = 16'h0400; i <= 16'h07FF; i = i + 1) begin
            if (i[6:0] >= 7'h78) begin
                if (mem[i] !== hole_copy[(i[9:7]) * 8 + (i[2:0])]) bad = bad + 1;
            end else if (mem[i] !== row_byte(i[15:0])) bad = bad + 1;
        end
        if (bad != 0) begin $display("FAIL: case 2: %0d text page bytes wrong after the fill", bad); errors = errors + 1; end
        else $display("  ok: the text page holds the picture and the holes are untouched");
        if (sw_text !== 1'b1 || sw_mixed !== 1'b0 || sw_page2 !== 1'b0 || sw_hires !== 1'b0 ||
            sw_store80 !== 1'b0 || sw_col80 !== 1'b0 || sw_ramwrt !== 1'b0)
            fail("case 2: the switches are not 40-column text, page 1, main memory");
        for (i = 0; i < 65536; i = i + 1) if (aux[i] !== 8'h00) begin fail("case 2: a byte landed in aux memory"); i = 65536; end
        if (held !== 1'b1) fail("case 2: the hold dropped");
        // The hold's keyboard reads are back.
        log_en = 1'b1; nops = 0;
        cycles(6);
        log_en = 1'b0;
        bad = 0;
        for (i = 0; i < nops; i = i + 1) if (!log_ovr[i] || (log_addr[i] !== 16'hC000 && log_addr[i] !== 16'hC010)) bad = bad + 1;
        if (bad != 0 || nops == 0) fail("case 2: the hold's keyboard reads did not resume");
        else $display("  ok: the hold is still on and reading the keyboard again");

        // --- case 3 / the counter follows the scanner; the mark is the origin --
        notify = 1'b1;
        track_n = 0; track_bad = 0; marks = 0; marks_bad = 0; origins = 0; origins_unmarked = 0;
        track_en = 1'b1;
        cycles(17030 * 2 + 200);
        if (track_bad != 0) begin $display("FAIL: case 3: the counter disagreed with the scanner on %0d of %0d cycles", track_bad, track_n); errors = errors + 1; end
        else $display("  ok: the counter agrees with the scanner on all %0d cycles, held", track_n);
        if (marks < 2 || marks_bad != 0 || origins_unmarked != 0) begin
            $display("FAIL: case 3: %0d marks (%0d off the origin), %0d origins unmarked", marks, marks_bad, origins_unmarked);
            errors = errors + 1;
        end else $display("  ok: %0d marks, every one at line 0 cycle 0, every origin marked; frames=%0d", marks, frames);
        if (mark_gap != 17030) begin $display("FAIL: case 3: marks %0d cycles apart, not 17030", mark_gap); errors = errors + 1; end
        else $display("  ok: marks are 17030 cycles apart");
        if (mark_free[0] !== 1'b0) fail("case 3: mark_free says PAL");
        if (vbl_bad != 0 || vbl_n_chk == 0) begin $display("FAIL: case 3: the VBL level disagreed with the scanner on %0d of %0d cycles", vbl_bad, vbl_n_chk); errors = errors + 1; end
        else $display("  ok: the VBL level is high on lines 192-261 and low on 0-191, all %0d cycles", vbl_n_chk);
        if (vbl_early != 0) fail("case 3: the VBL level was high before the lock");
        if (ev_vbl_bad != 0 || ev_n == 0) begin $display("FAIL: case 3: bit 19 of %0d of %0d events was not the VBL level", ev_vbl_bad, ev_n); errors = errors + 1; end
        else $display("  ok: bit 19 of all %0d events is the VBL level (the m2b0 pin is high and not recorded)", ev_n);
        // Notify off: no marks.
        notify = 1'b0;
        marks = 0;
        cycles(17030 + 100);
        if (marks != 0) fail("case 3: marks with notify off");
        else $display("  ok: no marks with notify off");
        notify = 1'b1;

        // --- case 4 / released: the program runs, the counter keeps following ---
        track_n = 0; track_bad = 0;
        pulse_release;
        cycles(17030 + 100);
        if (held !== 1'b0) fail("case 4: still held");
        if (mem[16'h0300] !== 8'h42) fail("case 4: the program did not run");
        if (track_bad != 0) begin $display("FAIL: case 4: %0d disagreements with the core running", track_bad); errors = errors + 1; end
        else $display("  ok: the core runs and the counter still agrees on all %0d cycles", track_n);

        // --- case 5 / a second detection: slip 0 ---------------------------------
        machine_reset(4);
        cycles(30);
        if (held !== 1'b1) fail("case 5: not held");
        pulse_start;
        wait_idle(70_000);
        if (err !== 4'd0 || locked !== 1'b1 || locks !== 8'd2) fail("case 5: the second detection did not lock");
        else if (slip !== 16'd0) begin $display("FAIL: case 5: slip %0d on a re-lock", $signed(slip)); errors = errors + 1; end
        else if (mismatches !== 16'd0) fail("case 5: mismatches on the re-lock");
        else $display("  ok: a second detection locks again with slip 0, 0 mismatches, locks=2");
        if (track_bad != 0) fail("case 5: the counter disagreed across the re-lock");

        // --- case 6 / a reset mid-detection aborts it; the lock stands ----------
        pulse_start;
        wait_state(4'd2, 200);                       // FILL
        at_offset(0); res_n = 1'b0;                  // the switch bounces
        cycles(3);
        if (busy) fail("case 6: still busy with the hold dropped");
        else if (err !== 4'd4) begin $display("FAIL: case 6: err=%0d, expected 4 (aborted)", err); errors = errors + 1; end
        else if (locked !== 1'b1 || locks !== 8'd2) fail("case 6: the earlier lock did not stand");
        else $display("  ok: a reset mid-detection aborts it (err 4); the lock stands");
        at_offset(0); res_n = 1'b1;
        cycles(30);
        if (held !== 1'b1) fail("case 6: the hold did not re-engage");
        if (track_bad != 0) fail("case 6: the counter disagreed across the reset");
        // The fill was interrupted and the page is partly rewritten; a fresh
        // start must still lock.
        pulse_start;
        wait_idle(70_000);
        if (err !== 4'd0 || locks !== 8'd3 || slip !== 16'd0) fail("case 6: the detection after the abort did not lock cleanly");
        else $display("  ok: the detection after the abort locks (locks=3, slip 0)");

        // --- case 7 / the probe: $C019 for one frame -----------------------------
        probe_addr = 16'hC019;
        probe_reads = 0; probe_bad = 0; probe_low = 0;
        probe_en = 1'b1;
        pulse_probe;
        wait_idle(20_000);
        cycles(2);
        probe_en = 1'b0;
        if (err !== 4'd0) fail("case 7: the probe reported an error");
        if (probe_reads != 17030) begin $display("FAIL: case 7: %0d probe reads, expected 17030", probe_reads); errors = errors + 1; end
        else $display("  ok: the probe read $C019 on exactly 17030 cycles");
        if (probe_bad != 0 || probe_low != 70 * 65) begin
            $display("FAIL: case 7: VBL' low on %0d cycles (expected %0d), %0d against the counter", probe_low, 70 * 65, probe_bad);
            errors = errors + 1;
        end else $display("  ok: the machine's VBL' is low on exactly the 70 lines the counter calls 192 and up");
        // A probe with nothing locked, or unheld, is refused: shown unheld.
        pulse_release;
        cycles(20);
        pulse_probe;
        cycles(4);
        if (err !== 4'd5 || busy) fail("case 7: a probe on an unheld machine was not refused (err 5)");
        else $display("  ok: a probe with the machine running is refused (err 5)");

        // --- case 8 / PAL --------------------------------------------------------
        pal = 1'b1;                                  // the vertical preset changes: 312 lines
        machine_reset(4);
        cycles(30);
        track_en = 1'b0;
        pulse_start;
        wait_idle(80_000);
        if (err !== 4'd0 || locked !== 1'b1) fail("case 8: no lock on PAL");
        else if (dpal !== 1'b1) fail("case 8: PAL read as NTSC");
        else if (mismatches !== 16'd0) begin $display("FAIL: case 8: %0d mismatches on PAL", mismatches); errors = errors + 1; end
        else $display("  ok: PAL - locked, pal=1, 0 mismatches over the 312-line verify frame");
        track_n = 0; track_bad = 0; marks = 0; marks_bad = 0; origins = 0; origins_unmarked = 0; last_mark_fc = -1; vbl_bad = 0;
        track_en = 1'b1;
        cycles(20280 * 2 + 200);
        if (track_bad != 0) begin $display("FAIL: case 8: %0d disagreements on PAL", track_bad); errors = errors + 1; end
        else $display("  ok: the counter agrees with the PAL scanner on all %0d cycles", track_n);
        if (marks < 2 || marks_bad != 0 || origins_unmarked != 0 || mark_gap != 20280) begin
            $display("FAIL: case 8: %0d marks, %0d off, %0d unmarked, gap %0d", marks, marks_bad, origins_unmarked, mark_gap);
            errors = errors + 1;
        end else $display("  ok: marks 20280 cycles apart, each at the origin; mark_free says PAL=%0d", mark_free[0]);
        if (mark_free[0] !== 1'b1) fail("case 8: mark_free does not say PAL");
        if (vbl_bad != 0) begin $display("FAIL: case 8: the VBL level disagreed with the PAL scanner on %0d cycles", vbl_bad); errors = errors + 1; end
        else $display("  ok: the VBL level is high on lines 192-311 on PAL");
        track_en = 1'b0;

        // --- case 9 / the runtime door: refused --------------------------------
        pulse_release;
        cycles(40);
        pulse_trigger;
        cycles(12);
        if (held !== 1'b1 || runtime !== 1'b1) fail("case 9: not runtime-held");
        log_en = 1'b1; nops = 0;
        pulse_start;
        cycles(12);
        log_en = 1'b0;
        bad = 0;
        for (i = 0; i < nops; i = i + 1) if (log_ovr[i] && log_addr[i] !== 16'hC000 && log_addr[i] !== 16'hC010) bad = bad + 1;
        if (err !== 4'd1 || busy || bad != 0) fail("case 9: a start from the runtime hold was not refused");
        else $display("  ok: a start from the runtime hold is refused (err 1): a running program's memory is not written");
        pulse_release;
        cycles(20);

        // --- case 10 / a dead floating bus: err 2 after the timeout -------------
        bus_dead = 1'b1;
        machine_reset(4);
        cycles(30);
        pulse_start;
        wait_idle(ACQ_TIMEOUT + 3000);
        if (busy) fail("case 10: still busy past the timeout");
        else if (err !== 4'd2) begin $display("FAIL: case 10: err=%0d, expected 2 (no signal)", err); errors = errors + 1; end
        else if (locked !== 1'b1 || dpal !== 1'b1) fail("case 10: the lock did not stand through a failed detection");
        else $display("  ok: a floating bus showing nothing gives err 2 after the timeout; the lock stands");
        bus_dead = 1'b0;

        $display("");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
