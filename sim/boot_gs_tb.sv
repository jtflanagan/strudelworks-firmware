`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// boot_gs_tb - the IIgs ROM booting on the card, in simulation.
//
// The GS sibling of sim/boot_tb.sv, and deliberately a much smaller machine.
// boot_tb boots a real operating system off a real .hdv and checks every byte
// the core reads against a reference memory it keeps in program order; this
// bench has a better oracle than any reference it could keep, because KEGS has
// already executed the same ROM instruction for instruction
// (tools/kegs/README.md).  So there is no reference memory here, no host
// model and no disk: there is the ROM, the card's memory path, the soft
// 65816 - and a trace, compared against KEGS's by tools/trace_diff816.py.
//
// WHAT IS IN IT.  cpu65816 on rtl/accel_seq.sv's dispatcher (GS = 1: no
// fronts, docs/GS.md rung 3), rtl/apple_mmu.sv with GS = 1 and its 24-bit op
// path, rtl/rom_loader.sv carrying 512 chunks of ROM 3 to physical bank $FC,
// rtl/page_cache.sv, rtl/page_client.sv and a DDR3 stub behind them, and
// rtl/apple_bus_write.sv driving a IIe backplane that answers nothing.
//
// WHAT IS NOT IN IT YET, and why the trace is expected to diverge.  The IIgs
// chipset - the VGC registers, the ADB micro, the clock and battery RAM, the
// interrupt controller, the IWM and SCC stubs - is rung 3b's `gs_io.sv`.
// Until it exists, every $C0xx access is BUS class and rides a real bus cycle
// to a backplane that returns FLOAT_BYTE, so the ROM's first read of a
// register that matters is where this bench parts company with KEGS.  THAT
// INDEX IS THE MEASUREMENT: it is printed as `divergence at instruction N`,
// and rung 3b's job is to move it.  The bench therefore does not FAIL on a
// divergence - it reports one - and fails only on the things that would mean
// the machine itself is wrong: the ROM not loading, the core not reaching the
// reset vector's target, a cache mismatch, a dropped duplicate, an address
// outside the image.
//
// THE TRACE, one twenty-byte record per instruction, in KEGS's own shape so
// the two decode with the same code:
//     w0 {dbr[7:0], pbr[7:0], pc[15:0]}    w1 {op[7:0], 24'd0}
//     w2 {psr[15:0] (bit 8 = E), a[15:0]}  w3 {x[15:0], y[15:0]}
//     w4 {s[15:0], d[15:0]}
// The registers are the ones the instruction LEFT BEHIND, which is what KEGS
// logs: a record is emitted at the fetch of the NEXT instruction, when the
// previous one's last writeback has landed and the new opcode is on din.
//////////////////////////////////////////////////////////////////////////////////
module boot_gs_tb #(parameter UCODE  = "cpu65816_ucode.hex",
                    parameter UCODE0 = "cpu65816_ucode0.hex",
                    parameter USEQ0  = "cpu65816_useq0.hex",
                    parameter ROMF   = "gsrom.hex",     // 256K ROM 3, xxd -p -c1
                    parameter TRACEF = "boot_gs.trc",
                    parameter integer ROM_CHUNKS = 512,
                    parameter integer MODE = 2,
                    parameter integer TARGET = 0,
                    parameter integer MAX_INSTRS = 200000,
                    parameter integer MAX_CLKS = 400000000,
                    parameter integer PHI0_HIGH = 49,
                    // What the IIe backplane puts on the data pins when
                    // nothing drives them.  KEGS's unclaimed I/O reads return
                    // the floating bus; until gs_io answers, a constant is
                    // both honest and repeatable.
                    parameter [7:0] FLOAT_BYTE = 8'h00,
                    // Seconds since 1904-01-01; see the gs_io wiring below.
                    parameter [31:0] SEED_TIME = 32'd3871713600,
                    // The slot-7 SmartPort HDC and the image it serves.  THE
                    // MACHINE BOOTS FROM THIS (the user's, 2026-09-09): the
                    // IWM is only skipped, and the GS ROM's own defaults
                    // already mark slot 7 "Your Card" ($C02D = $80), so the
                    // scan looks here.
                    parameter HDROMF = "hdrom.hex",
                    // The IIgs's SmartPort ROM is loaded, so its eleven-byte
                    // command FIFO is what the host model must decode.  The
                    // run script sets it from which ROM was named.
                    parameter bit GS_HD_ROM = 1'b1,
                    parameter HDVF   = "hdv.hex",
                    parameter integer HDV_BLOCKS = 2880,
                    // 0 when no image was given: the bench still runs the
                    // whole machine and the ROM still scans, it simply finds
                    // an empty slot, so "no block was read" is the expected
                    // outcome rather than a failure.
                    parameter integer HAS_HDV = 0,
                    parameter integer HD_SLOT = 7,
                    parameter integer HOST_DELAY = 2000,
                    // The DDR3 model's read latency per beat, in clocks.  12
                    // is the model's original figure; the card's UberDDR3
                    // behind the arbiter is slower and burstier, and the
                    // fronts' first hardware run (docs/GS.md rung 6) died
                    // where this bench passed.
                    parameter integer DDR_LAT = 12,
                    // Name every $C0Fx write and every write to the ProDOS
                    // block-driver parameters at $40-$47, from the first
                    // EXECUTE on; see "the block number" below.
                    parameter integer DISK_TRACE = 0,
                    // Name every $C08x touch with the state it left, and
                    // census what is ever written into the language card;
                    // see "the language card" below.
                    parameter integer LC_TRACE = 0,
                    // Print every CPU cycle - address, direction, VDA/VPA,
                    // the byte handed back - between two instruction
                    // numbers.  The general form of the probes that answered
                    // rung 3e: a divergence index names an instruction, and
                    // this says what the machine did around it.
                    parameter integer WATCH_FROM = 0,
                    parameter integer WATCH_TO   = 0,
                    // The page-cache engine's fills and victims, for the
                    // ROM's pages; see "the engine's history" below.
                    parameter integer ENG_TRACE = 0,
                    // THE BATTERY RAM THE HOST SHIPS (docs/GS.md).  Off by
                    // default and it must stay that way for the reference
                    // comparison: KEGS boots with an all-zero battery RAM
                    // when its config names no `bram` lines, so the ROM finds
                    // an invalid checksum on both machines and initialises it
                    // the same way.  Ship one and the two part company at
                    // once - correctly, and not at the floor.
                    // THE MIRROR'S SIDE (docs/GS.md rung 3e).  Every retired
                    // op, in the host's own 64-bit record shape
                    // (protocol.hpp), and the physical pages the machine
                    // wrote - so the host's AppleMemory can replay the one
                    // and be held to the other.  Empty = write neither.
                    // Name a physical page and the bench says which op first
                    // wrote it - the fastest way from "these bytes are not in
                    // the stream" to "this is what put them there".
                    parameter integer PAGE_WATCH = 0,
                    // THE 3.5" DRIVE (rtl/gs_iwm.sv, docs/IWM35.md): the
                    // image's 160 tracks nibblized by tools/nib35.py at a
                    // fixed stride, their nibble counts, and the clocks the
                    // modelled host takes to answer a seek.  The FTA demos
                    // boot from here and nowhere else.
                    parameter FD35F = "fd35.hex",
                    parameter FD35_COUNTSF = "fd35.counts",
                    parameter integer FD35_STRIDE = 10240,
                    parameter integer HAS_FD35 = 0,
                    parameter integer FD35_DELAY = 50000,
                    // Name every IWM access with the byte it took and the
                    // drive's state after it, for the first N accesses.
                    parameter integer FD35_TRACE = 0,
                    // THE 5.25" DRIVES ON THE IWM (rtl/gs_iwm.sv): a 140K
                    // image nibblized by tools/nib525.py exactly as the host's
                    // floppy service does it (35 tracks x 6656 bytes, 6384
                    // nibbles a track), in drive 1, and the clocks the modelled
                    // host takes to answer a seek.
                    parameter FD525F = "fd525.hex",
                    parameter FD525_COUNTSF = "fd525.counts",
                    parameter integer HAS_FD525 = 0,
                    parameter integer FD525_DELAY = 50000,
                    parameter OPSF  = "",
                    parameter PAGESF = "",
                    parameter ADB_KEYMAP = "adb_keymap.hex",
                    // A key, pressed at an instruction number (docs/GS.md,
                    // ADB_KEY): the ADB keycode, the modifier byte in
                    // $C025's own order, and when.  0 = type nothing.
                    // THE MOUSE BUTTON (2026-09-13).  The XMAS demo's
                    // "CLICK MOUSE" prompt does NOT take a key: one
                    // pressed at it left the machine in the same loop
                    // twenty million instructions later, which is how
                    // this was found.  It polls $C061, so the button is
                    // what advances it - pb_sel's PB0 field, forced down.
                    parameter integer BTN_AT   = 0,
                    parameter integer BTN_HOLD = 2000000,
                    parameter integer KEY_AT   = 0,
                    parameter integer KEY_CODE = 0,
                    parameter integer KEY_MODS = 0,
                    // How long the key is held, in clocks.  Long enough and
                    // the ADB micro's auto-repeat should fire.
                    parameter integer KEY_HOLD = 20000,
                    parameter BRAMF = "gsbram.hex",
                    parameter integer HAS_BRAM = 0);

    localparam integer T_PRESENT = 2, T_EMIT = 2, T_DIN = 44, T_CYCEN = 45;
    localparam integer PHI0_LOW = 98 - PHI0_HIGH, CYCLE = 98;
    localparam integer BUS_AT = 70;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    integer errors = 0, checks = 0;
    task fail(input string why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask
    task ok(input string what);
        begin $display("ok: %0s", what); checks = checks + 1; end
    endtask

    // ---- phi0 -------------------------------------------------------------------
    reg phi0 = 0;
    integer phase_ctr = 0;
    always @(posedge clk) begin
        phase_ctr <= phase_ctr + 1;
        if (!phi0 && phase_ctr == PHI0_LOW - 1)  begin phi0 <= 1; phase_ctr <= 0; end
        if ( phi0 && phase_ctr == PHI0_HIGH - 1) begin phi0 <= 0; phase_ctr <= 0; end
    end
    reg prev_phi0 = 0;
    wire fall = !phi0 && prev_phi0;
    integer since_fall = 0;
    always @(posedge clk) begin
        prev_phi0 <= phi0;
        if (fall) since_fall <= 0; else since_fall <= since_fall + 1;
    end
    integer bus_cycles = 0;
    always @(posedge clk) if (fall) bus_cycles = bus_cycles + 1;
    // The IIgs frame is the IIe's: 262 lines x 65 cycles = 17030 bus cycles at
    // 59.92 Hz (docs/GS.md).  One pulse per frame is the interrupt
    // controller's whole clock; on the card it comes from rtl/vbeam.sv, which
    // counts the machine's own cycles so an accelerated program sees the same
    // number of VBLs per program-second.
    reg frame_tick = 1'b0;
    always @(posedge clk)
        frame_tick <= fall && (bus_cycles % 17030 == 17029);
    // ...and the blanking interval itself, the last 4550 cycles of the frame,
    // for $C019.  On the card this is rtl/vbeam.sv's own.
    wire vbl_active = (bus_cycles % 17030) >= 12480;
    // THE BEAM'S LINE AND COLUMN, for $C02E/$C02F: 65 cycles a line, 262
    // lines a frame, the same frame the VBL above is cut from.  A boot
    // block that waits for the vertical count to reach the blanking (the
    // XMAS demo's does, `LDA $C02E / CMP #$F8 / BCC`) waited for ever on a
    // beam tied to zero.
    wire [8:0] tb_scan_v = 9'((bus_cycles % 17030) / 65);
    wire [6:0] tb_scan_h = 7'(bus_cycles % 65);

    // ---- the backplane, the reader and the driver --------------------------------
    reg  res_n = 1'b1;
    wire cpu_rst = rst || !res_n;
    reg  master_active = 1'b1;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, driving, drv_sync;
    wire [7:0]  data_drive;
    wire        phi0_sync, res_sync, bus_tick;
    wire [7:0]  data_sync;
    wire        mem_sub_en, bus_owns, core_valid;
    wire [7:0]  mem_sub_data;
    // The card's byte reaches the reader only for a bus op it answered.
    wire        sub_en   = mem_sub_en && bus_owns;
    wire [7:0]  sub_data = mem_sub_data;
    // The IIe on the pins: it holds no memory this machine uses and no card
    // this machine talks to, so it answers every read with the same byte.
    wire [7:0]  data_pin = data_oe ? data_drive : FLOAT_BYTE;

    wire [15:0] op_addr, nxt_addr;
    // The forced mouse button (BTN_AT below).  Declared up here, above the
    // gs_io instance that uses it: a name used before its declaration is
    // the undriven-net trap of 2026-09-11.
    logic [5:0] pb_force = 6'd0;

    wire        op_rw, op_present, op_commit, op_ovr, op_divert, op_dummy, op_inflight, q_divert;
    wire [7:0]  op_wdata;
    wire        drv_cyc_done;
    wire [7:0]  drv_din;

    apple_bus_read u_read (
        .clk (clk), .rst (rst), .enable (1'b1),
        .apple_data_pin (data_pin), .apple_addr_pin (addr_drive), .apple_rw_pin (rw_drive),
        .apple_phi0_pin (phi0), .apple_m2sel_pin (1'b0), .apple_m2b0_pin (1'b0),
        .apple_inh_pin (1'b1), .apple_res_pin (res_n), .apple_irq_pin (1'b1),
        .apple_rdy_pin (1'b1), .apple_dma_pin (!dma_assert),
        .ev_data (), .ev_valid (), .data_tick (bus_tick),
        .sync_override (drv_sync), .sync_override_en (1'b1),
        .data_override (sub_data), .data_override_en (sub_en),
        .rw_override_en (op_divert), .wdata_override (op_wdata), .vbl_level (1'b0),
        .res_sync (res_sync), .irq_sync (), .phi0_sync (phi0_sync),
        .data_sync (data_sync), .phi0_active ()
    );

    // ---- the core ---------------------------------------------------------------
    wire [23:0] cpu_a24;
    wire [15:0] cpu_addr = cpu_a24[15:0];
    wire [7:0]  cpu_bank = cpu_a24[23:16];
    wire        cpu_rw, cpu_sync, cpu_cyc_en;
    wire        cpu_vda, cpu_vpa, cpu_vpb, cpu_emu, cpu_halted;
    wire [7:0]  cpu_dout;
    // THE SPLIT FRONT (docs/GS.md rung 6), wired as rtl/master_top.sv wires
    // it: the instruction front owns i_din, the data front d_din, the
    // sequencer's byte reaches the core through them.  cpu_din below is the
    // byte the core CONSUMED - the front's on its stream - which is what the
    // bench's own checks and its trace read.
    wire        cpu_cyc_is_i, cpu_d_pred_v, cpu_d_pred_rw, cpu_bank_wr;
    wire [23:0] cpu_pc24, cpu_d_pred;
    wire [1:0]  cpu_d_pred_bcls;
    wire [7:0]  cpu_p_flags, cpu_dbr, i_din_w, d_din_w, seq_din;
    wire [7:0]  cpu_din = cpu_cyc_is_i ? i_din_w : d_din_w;

    cpu65816 #(.UCODE_FILE (UCODE), .UCODE0_FILE (UCODE0), .USEQ0_FILE (USEQ0)) u_cpu (
        .clk (clk), .rst (cpu_rst), .cyc_en (cpu_cyc_en),
        .addr (cpu_a24), .rw (cpu_rw), .dout (cpu_dout), .i_din (i_din_w), .d_din (d_din_w),
        .cyc_is_i (cpu_cyc_is_i), .pc_addr (cpu_pc24), .d_pred (cpu_d_pred),
        .d_pred_v (cpu_d_pred_v), .d_pred_rw (cpu_d_pred_rw), .d_pred_bcls (cpu_d_pred_bcls),
        .p_flags (cpu_p_flags), .dbr_o (cpu_dbr), .bank_wr (cpu_bank_wr),
        // The chipset's one interrupt line, active low into the core.
        .irq_n (!gsio_irq), .nmi_n (1'b1),
        .sync (cpu_sync), .vda (cpu_vda), .vpa (cpu_vpa), .vpb (cpu_vpb),
        .emu (cpu_emu), .halted (cpu_halted)
    );

    // AN INTERNAL CYCLE IS NOT AN ACCESS, and this is where a 65816 system
    // says so.  VDA AND VPA BOTH LOW is the part's own encoding for "this
    // cycle touches nothing" - an operand fetch has VDA low too, so VDA
    // alone is not the test - and the address it leaves on the pins is
    // whatever the last address step happened to put there.  For this core
    // that is very often THE LAST OPERAND'S ADDRESS PLUS ONE: the M-sized
    // slots share their first cycle with the 16-bit path, which walks
    // forward, and the 8-bit tail walks back a cycle later.
    //
    // Handed downstream as it comes off the pins, that cycle is a real
    // access, and it cost this bench both halves of a boot:
    //   - as a WRITE, because the part drives R/W LOW through the internal
    //     cycle of a read-modify-write (the 6502's dummy write, and the
    //     reference's cycle list agrees): `INC $46` in the ProDOS boot block
    //     put the old $02 into $47, and the boot asked for block $0203;
    //   - as a READ, because $C0xx reads are strobes: two instructions after
    //     ProDOS's `LDA $C082` an internal cycle carrying $C083 switched the
    //     language card back to RAM, and `JSR $FE84` read $00.
    //
    // So the cycle is PARKED, in the same idiom and for the same reason as
    // rtl/apple_bus_write.sv's dummy: $0000 is RAM on every Apple II, so a
    // read of it disturbs nothing even if something downstream decodes it.
    // Everything downstream of the core takes THESE, never the raw pins.
    // docs/GS.md rung 3e; rung 4's master_top must wire it the same way.
    wire        cyc_internal = !cpu_vda && !cpu_vpa;
    wire        cpu_rw_eff   = cpu_rw | cyc_internal;
    wire [23:0] cpu_a24_eff  = cyc_internal ? 24'h000000 : cpu_a24;
    wire [15:0] cpu_addr_eff = cpu_a24_eff[15:0];

    // The four registers apple_mmu owns and gs_io shows.  Declared here rather
    // than beside the chipset below because the vector-pull redirect needs
    // SHADOW, and a wire has to exist before it is read.
    wire [7:0]  gs_shadow_w, gs_cyareg_w, gs_sltrom_w, gs_state_w;

    // ---- A VECTOR PULL COMES FROM THE ROM ----------------------------------
    // The same redirect rtl/master_top.sv makes, at the same point and for
    // the same reason: the 65816 forces PBR to zero for a vector fetch, but a
    // IIgs's FPI watches VP' and takes the vector from BANK $FF unless
    // SHADOW[6] says $00/$FFxx is plain RAM.  KEGS's moremem_fix_vector_pull.
    // This bench is what found it - with the language card in RAM-read mode,
    // which GS/OS sets early, $00/$FFFE read $00 $00 and the first IRQ sent
    // the machine to $00/0000 for the rest of the run.
    wire [7:0]  cpu_bank_eff = (cpu_vpb && !gs_shadow_w[6]) ? 8'hFF
                                                            : cpu_a24_eff[23:16];

    // ---- the dispatcher ----------------------------------------------------------
    reg  [1:0]  mode = 2'd0;
    reg  [15:0] target = 16'd0;
    reg         serve = 1'b0;
    wire        u_present, u_commit, u_rw, u_sync, u_ovr, u_divert;
    wire [15:0] u_addr;
    wire [7:0]  u_bank, u_wdata;
    wire        fev_valid, fev_rw, fev_sync;
    wire [15:0] fev_addr;
    wire [7:0]  fev_bank, fev_data;
    wire        accel_on, decided, busy;
    wire [1:0]  q_cls;
    wire [3:0]  seq_state;
    wire [31:0] fast_ops, bus_ops, cycles, wait_clocks, accel_maps, turbo_ops;
    wire [7:0]  retries;
    wire        mem_image_ready, mem_invalidating;
    wire        q_swi_mmu, q_swi_quiet, q_slot, swi_commit, sl_win, seq_slot_q;
    wire [7:0]  mmu_swi_stat;
    // The chipset's face (rtl/gs_io.sv, docs/GS.md rung 3b): what it claims
    // joins the dispatcher's internalized-op question, and its byte joins the
    // internalized read's answer.  apple_mmu's own swi is OFF on this build
    // (swi_on tied low), so the two never both claim.
    wire        gsio_claim, gsio_u_claim;
    wire [7:0]  gsio_byte;
    wire        gsio_irq;
    wire        q_swi = q_swi_mmu || gsio_claim;
    // The byte mux follows the REGISTERED op, exactly as master_top's does.
    wire [7:0]  swi_byte = gsio_u_claim ? gsio_byte : mmu_swi_stat;
    wire        map_changed, map_settling;

    // The fronts, as master_top chains them (rung 6): the sequencer's cyc_en
    // and byte pass through iline then dline to the core; the books ride
    // turbo_commit/d_commit; the bank-write hold joins the settle.
    wire        seq_cyc_en, iline_cyc_en, turbo_en, turbo_ok, turbo_commit, turbo_sync;
    wire        turbo_claim, turbo_wr, turbo_tick, dline_tick, seq_fast_tick;
    wire        d_commit_w, d_claim_w, d_pending_w;
    wire        front_settling = map_settling || cpu_bank_wr;
    wire        tev_valid, tev_sync, dev_valid, dev_rw;
    wire [15:0] tev_addr, dev_addr;
    wire [7:0]  tev_data, dev_data, tev_bank, dev_bank;
    wire [23:0] p_addr_w, dq_addr_w;
    wire        dq_rw_w;
    wire        il_req, il_ack, il_done, il_ok, dl_req_w;
    wire [15:0] il_ppn_w, dl_ppn_w;
    wire [3:0]  il_line_w, dl_line_w;
    wire [127:0] il_row;
    wire        pw_valid_w, ws_valid_w;
    wire [15:0] pw_ppn_w, ws_ppn_w;
    wire [7:0]  pw_off_w, pw_data_w, ws_off8_w;
    logic il_src_q;
    always_ff @(posedge clk) if (il_ack) il_src_q <= !il_req;
    // THE MERGE'S BACK-PRESSURE, modelled as sim/accel_tb.sv models it: the
    // fronts' room comes and goes in bursts (an xorshift LFSR), the write
    // room a clock behind the read room as the real merge registers it.
    // Tied high, the first GS run of the fronts passed here and hung on
    // hardware (docs/GS.md rung 6).
    logic [31:0] room_lfsr = 32'h2545F491;
    logic        room_q = 1'b1, room_w_q = 1'b1;
    logic [5:0]  room_burst = 6'd0;
    always_ff @(posedge clk) begin
        room_lfsr <= {room_lfsr[30:0], room_lfsr[31] ^ room_lfsr[21] ^ room_lfsr[1] ^ room_lfsr[0]};
        if (room_burst != 6'd0) room_burst <= room_burst - 6'd1;
        else if (room_lfsr[7:0] < 8'd12) room_burst <= room_lfsr[13:8];   // ~5%: a burst of no room
        room_q   <= (room_burst == 6'd0);
        room_w_q <= room_q;
    end

    accel_seq #(.GS (1'b1)) u_seq (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .master_active (master_active),
        .mode (mode), .target (target), .cnt_clr (1'b0),
        .q_swi (q_swi), .q_swi_quiet (q_swi_quiet), .swi_byte (swi_byte),
        .swi_commit (swi_commit), .fast_tick (seq_fast_tick), .mem_served (seq_mem_served_w), .fev_quiet (),
        .q_slot (q_slot), .slot_q_o (seq_slot_q), .sl_win (sl_win),
        // The 3.5" drive holds the core while its track is on the way, as
        // the card does (rtl/master_top.sv: fd_stall || u2_stall || fd35_stall).
        .stall (fd35_stall),
        .mem_serve (serve), .mem_image_ready (mem_image_ready), .mem_invalidating (mem_invalidating),
        .q_cls (q_cls),
        .cpu_addr (cpu_addr_eff), .cpu_bank (cpu_bank_eff), .cpu_rw (cpu_rw_eff), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .cyc_is_i (cpu_cyc_is_i), .cyc_int (cyc_internal),
        .cyc_en (seq_cyc_en), .cpu_din (seq_din),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok),
        .turbo_commit (turbo_commit), .d_commit (d_commit_w), .turbo_claim (turbo_claim | d_claim_w),
        .turbo_wr (turbo_wr), .d_pending (d_pending_w),
        .op_present (op_present), .op_commit (op_commit), .op_dummy (op_dummy), .op_ovr (op_ovr),
        .op_divert (op_divert), .op_sync (drv_sync), .op_addr (op_addr), .op_rw (op_rw),
        .op_wdata (op_wdata), .cyc_done (drv_cyc_done), .drv_din (drv_din),
        .op_inflight (op_inflight), .ovr_en (hd_ovr_en), .ovr_bank (hd_ovr_en ? hd_ovr_bank : 8'd0),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .mem_sub_en (mem_sub_en), .mem_sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .mq_valid (1'b0),
        .bus_tick (bus_tick),
        .u_present (u_present), .u_commit (u_commit), .u_addr (u_addr), .u_bank (u_bank),
        .u_rw (u_rw), .u_wdata (u_wdata), .u_sync (u_sync), .u_ovr (u_ovr), .u_divert (u_divert),
        .fev_valid (fev_valid), .fev_addr (fev_addr), .fev_bank (fev_bank), .fev_rw (fev_rw),
        .fev_data (fev_data), .fev_sync (fev_sync),
        .accel_on (accel_on), .held_governor (), .state_o (seq_state), .reset_seq_o (),
        .fast_ops (fast_ops), .map_changed (map_changed), .map_settling (front_settling),
        .maps (accel_maps), .cen_v (), .cen_sel (), .turbo_ops (turbo_ops), .bus_ops (bus_ops),
        .cycles (cycles), .wait_clocks (wait_clocks), .retries (retries),
        .fronts_dis (1'b0)
    );

    // ---- the fronts (rtl/iline.sv, rtl/dline.sv at GS = 1) ---------------------
    // The instruction front: two lines of the program stream ahead of the
    // sequencer, in the program's bank.
    iline #(.GS (1'b1)) u_iline (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst),
        .pc_addr (cpu_pc24[15:0]), .pc_bank (cpu_pc24[23:16]),
        .cpu_rw (cpu_rw_eff), .cpu_sync (cpu_sync),
        .cyc_is_i (cpu_cyc_is_i), .p_flags (cpu_p_flags),
        .cyc_en (iline_cyc_en), .i_din (i_din_w),
        .accel_cyc_en (seq_cyc_en), .accel_din (seq_din),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok), .claim (turbo_claim),
        .turbo_commit (turbo_commit), .turbo_sync (turbo_sync),
        .tick_q (turbo_tick),
        .tev_valid (tev_valid), .tev_addr (tev_addr), .tev_data (tev_data),
        .tev_sync (tev_sync), .tev_bank (tev_bank), .ev_room (room_q),
        .p_addr (p_addr_w),
        .p_ppn (p_ppn_w), .p_reg (p_reg_w), .p_fold (p_fold_w), .p_fs (p_fs_w),
        .cl_ppn (cl_ppn_w), .rt_rd_flat (rt_rd_flat), .rwb_p1 (rwb_p1_w),
        .map_settling (front_settling), .idrop_o (), .irevive_o (),
        .map_changed (map_changed), .intc8rom (intc8rom),
        .il_req (il_req), .il_ppn (il_ppn_w), .il_line (il_line_w),
        .il_ack (il_ack && il_req), .il_done (il_done && !il_src_q),
        .il_ok (il_ok), .il_row (il_row),
        .cl_valid (cl_valid), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image),
        .cl_aux (cl_aux), .cl_bank (cl_bank), .cl_off (cl_off),
        .ws_valid (ws_valid_w), .ws_ppn (ws_ppn_w), .ws_off8 (ws_off8_w),
        .serve (serve), .inval (1'b0),
        .fill_busy (), .dbg_sel (4'd0), .dbg_val ()
    );

    // The data front, chained after it: its cyc_en is the core's.
    // The chipset's fast reads, as master_top feeds them (docs/LONG_DATA.md
    // rung 3): gs_io's fr_vec registered once, and the status page's switches.
    wire [15:0]  mmu_stat_bits;
    wire [247:0] gsio_fr_vec;
    reg  [247:0] io_vec_q = 248'd0;
    always @(posedge clk) io_vec_q <= gsio_fr_vec;
    dline #(.GS (1'b1)) u_dline (
        // The keyboard read at one clock, from the ADB micro's own byte.
        .kbd_en (1'b1), .kbd_byte (gs_c000_byte), .kbd_rd (dl_kbd_rd),
        .io_flat (gs_shadow_w[6]), .io_vec (io_vec_q), .swi_busy (swi_commit),
        .op_take (seq_mem_served_w), .op_row_v (op_row_v_w), .op_row (op_row_w), .op_row_ppn (op_row_ppn_w),
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst),
        .d_pred (cpu_d_pred), .d_pred_v (cpu_d_pred_v), .d_pred_rw (cpu_d_pred_rw),
        .d_pred_bcls (cpu_d_pred_bcls), .dbr (cpu_dbr),
        .cpu_addr (cpu_addr_eff), .cpu_bank (cpu_bank_eff), .cyc_int (cyc_internal),
        .cpu_rw (cpu_rw_eff), .cpu_dout (cpu_dout), .cyc_is_i (cpu_cyc_is_i),
        .il_cyc_en (iline_cyc_en), .seq_cyc_en (seq_cyc_en), .accel_din (seq_din), .i_din (i_din_w),
        .cyc_en (cpu_cyc_en), .d_din (d_din_w),
        .turbo_en (turbo_en), .turbo_ok (turbo_ok), .wr_en (turbo_wr),
        .d_commit (d_commit_w), .claim (d_claim_w), .tick_q (dline_tick), .pending (d_pending_w),
        .dev_valid (dev_valid), .dev_addr (dev_addr), .dev_data (dev_data), .dev_rw (dev_rw),
        .dev_bank (dev_bank),
        .ev_room (room_q), .ev_room_w (room_w_q),
        .altzp (sw_state[3]),
        .dq_addr (dq_addr_w), .dq_rw (dq_rw_w), .d_cls (dcls_w), .d_off (doff_w),
        .rw_bank (rw_bank), .map_changed (map_changed),
        .d_ppn (d_ppn_w), .d_reg (d_reg_w), .d_fold (d_fold_w), .d_sh (d_sh_w),
        .rt_rd_flat (rt_rd_flat), .rwb_p1 (rwb_p1_w), .map_settling (front_settling),
        .dl_req (dl_req_w), .dl_ppn (dl_ppn_w), .dl_line (dl_line_w),
        .dl_ack (il_ack && !il_req), .dl_done (il_done && il_src_q),
        .dl_ok (il_ok), .dl_row (il_row),
        .cl_valid (cl_valid), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_posted (cl_posted),
        .cl_ppn (cl_ppn_w), .cl_off (cl_off), .wdata (cl_wdata),
        .pw_valid (pw_valid_w), .pw_ppn (pw_ppn_w), .pw_off (pw_off_w),
        .pw_data (pw_data_w), .pw_take (pw_take_w && pw_valid_w),
        .ws_valid (ws_valid_w), .ws_ppn (ws_ppn_w), .ws_off8 (ws_off8_w),
        .inval (1'b0),
        .cnt_clr (1'b0),
        .cnt_serves (dl_serves), .cnt_claims (), .cnt_splices (),
        .cnt_cam_serves (), .cnt_lb_serves (), .cnt_posts (dl_posts), .cnt_post_waits (),
        .cnt_reval_drop (), .cnt_reval_revive (), .cnt_rev_serves (),
        .fill_busy (), .dbg_sel (4'd0), .dbg_val (), .dbg_val2 ()
    );
    wire [31:0] dl_serves, dl_posts;

    // The posted-write seam, shared with the ROM loader as in master_top.
    wire        pw_any_valid = pw_valid_w || rl_pw_valid;
    wire [15:0] pw_any_ppn   = pw_valid_w ? pw_ppn_w  : rl_pw_ppn;
    wire [7:0]  pw_any_off   = pw_valid_w ? pw_off_w  : rl_pw_off;
    wire [7:0]  pw_any_data  = pw_valid_w ? pw_data_w : rl_pw_data;

    apple_bus_write #(.T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT), .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)) u_write (
        .clk (clk), .rst (rst), .phi0_sync (phi0_sync), .data_sync (data_sync),
        .master_active (master_active), .park_kbd (1'b0), .park_addr (16'h0000),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .cpu_addr (cpu_addr_eff), .cpu_rw (cpu_rw_eff), .cpu_dout (cpu_dout), .cpu_sync (cpu_sync),
        .drv_sync (drv_sync), .cyc_en (drv_cyc_done), .cpu_din (drv_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (hd_rd_claim), .slot_rd_data (hd_rd_data),
        .din_sub_en (sub_en), .din_sub_data (sub_data),
        .ovr_en (hd_ovr_en), .ovr_addr (hd_ovr_addr), .ovr_rw (hd_ovr_rw),
        .ovr_wdata (hd_ovr_wdata),
        .op_ovr (op_ovr), .op_dummy (op_dummy), .op_inflight (op_inflight),
        .nxt_addr (nxt_addr), .divert (serve && q_divert), .op_divert (op_divert),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- the hard disk: the real card, in slot 7 ---------------------------------
    // The GS build has no on-card slot fast path - apple_mmu's `swi_on` is
    // low, so q_slot never fires - which means the peripherals see the
    // DRIVER's op stream, exactly as they did before docs/CXXX.md's closed
    // regime.  A $C0Fx or $C7xx access is BUS class and rides a real cycle,
    // which is what "Your Card" means on this machine.
    reg  [31:0] rx_mem [0:4095];
    integer     rx_wr = 0, rx_rd = 0;
    reg  [31:0] rx_head = 32'd0;
    reg         rx_head_v = 1'b0;
    wire [31:0] rx_dout  = rx_head;
    wire        rx_empty = !rx_head_v;
    wire        rx_rd_en;
    always @(posedge clk) begin
        if (rst) begin
            rx_head_v <= 1'b0;
        end else if ((rx_rd_en && rx_head_v) || !rx_head_v) begin
            if (rx_rd < rx_wr) begin
                rx_head <= rx_mem[rx_rd % 4096];
                rx_head_v <= 1'b1;
                rx_rd <= rx_rd + 1;
            end else rx_head_v <= 1'b0;
        end
    end
    task automatic push_word(input [31:0] w);
        begin rx_mem[rx_wr % 4096] = w; rx_wr = rx_wr + 1; end
    endtask
    function automatic [31:0] hdr(input [7:0] t, input [7:0] len, input [15:0] free);
        hdr = {free, t, len};
    endfunction
    localparam [7:0] T_HD_ROM = 8'h18, T_HD_DONE = 8'h19;

    wire        hmsg_valid, hpay_valid, unknown_valid;
    wire [7:0]  hmsg_type, hmsg_len, unknown_type_w;
    wire [15:0] hmsg_free;
    wire [31:0] hpay_data;
    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (hmsg_valid), .msg_type (hmsg_type), .msg_free (hmsg_free),
        .msg_len (hmsg_len), .pay_data (hpay_data), .pay_valid (hpay_valid),
        .unknown_valid (unknown_valid), .unknown_type (unknown_type_w), .unknown_len ()
    );
    integer unknowns = 0;
    always @(posedge clk) if (unknown_valid) begin
        unknowns = unknowns + 1;
        if (unknowns <= 5) $display("[%0t] msg_rx: unknown type %02x", $time, unknown_type_w);
    end

    wire        hd_rom_loaded, hd_busy, hd_rd_claim;
    wire [7:0]  hd_rd_data, hd_execs;
    wire [31:0] hd_tx_word;
    wire        hd_tx_valid;
    wire        hd_exec_q;
    // The IIgs's card: the DMA's bank carries.  (Overriding ANY hd_card
    // parameter here used to segfault Verilator 5.020 - see host_pump
    // below for the cause and the one-line workaround.)
    hd_card #(.GS (1)) u_hd (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .res_sync (res_sync),
        .master_active (master_active), .slot_assign (3'(HD_SLOT)),
        .op_addr (op_addr), .op_rw (op_rw), .op_present (op_present),
        .op_commit (op_commit), .op_ovr (op_ovr), .op_bank (drv_bank), .din (drv_din),
        .ovr_en (hd_ovr_en), .ovr_addr (hd_ovr_addr), .ovr_rw (hd_ovr_rw),
        .ovr_wdata (hd_ovr_wdata), .ovr_bank (hd_ovr_bank),
        .rd_claim (hd_rd_claim), .rd_data (hd_rd_data),
        .msg_valid (hmsg_valid), .msg_type (hmsg_type), .msg_free (hmsg_free),
        .msg_len (hmsg_len), .pay_data (hpay_data), .pay_valid (hpay_valid),
        .tx_word (hd_tx_word), .tx_valid (hd_tx_valid), .tx_take (hd_tx_valid),
        .rom_loaded (hd_rom_loaded), .busy (hd_busy), .execs (hd_execs), .exec_q (hd_exec_q)
    );
    wire        hd_ovr_en, hd_ovr_rw;
    wire [15:0] hd_ovr_addr;
    wire [7:0]  hd_ovr_wdata;
    wire [7:0]  hd_ovr_bank;
    // AN OVERRIDE BRINGS ITS OWN BANK, formed exactly as master_top forms it:
    // the DMA buffer's while the hard disk drives the bus, zero otherwise.
    wire [7:0]  drv_bank = hd_ovr_en ? hd_ovr_bank : cpu_bank_eff;

    // ---- the memory path, on the unified stream ----------------------------------
    wire        cl_valid, cl_rw, cl_wr_image, cl_aux, cl_posted, cl_sh, intc8rom;
    wire [1:0]  cl_cls;
    wire [7:0]  cl_bank, cl_wdata, shd_drops;
    wire        tb_mwx_stb;
    wire [7:0]  tb_mw_bank, tb_mw_byte;
    wire [15:0] tb_mw_addr;
    wire [15:0] cl_off, pf_off, cl_ppn_w, pf_ppn_w;
    wire [11:0] sw_state;
    wire [7:0]  rw_bank, rwb_p1_w;
    wire        rom_loaded, invalidating, image_ready, rot_ok, mem_idle;
    wire [31:0] hits, misses, served, mismatches, last_mismatch, diverted;
    wire [7:0]  late_fills, fifo_drops;
    reg         msg_valid = 1'b0, pay_valid = 1'b0;
    reg  [7:0]  msg_type = 8'd0, msg_len = 8'd0;
    reg  [31:0] pay_data = 32'd0;
    wire        pq_busy, pq_valid, pq_we, pq_ready, pr_valid;
    wire [19:0] pq_line;
    wire [127:0] pq_wdata, pr_data;
    wire        pw_take_w, pw_ready_w;
    wire [15:0] p_ppn_w, d_ppn_w;
    wire [3:0]  p_reg_w, d_reg_w;
    wire        p_fold_w, p_fs_w, d_fold_w;
    wire        d_sh_w;
    wire         op_row_v_w;
    wire         seq_mem_served_w;
    wire [127:0] op_row_w;
    wire [15:0]  op_row_ppn_w;
    wire [7:0]  gs_c000_byte;
    wire        dl_kbd_rd;
    wire [1:0]  p_cls;
    wire        p_aux_w;
    wire [15:0] p_off_w;
    wire [1:0]  dcls_w;
    wire        daux_w;
    wire [15:0] doff_w;
    wire [103:0] rt_rd_flat;
    assign mem_image_ready = image_ready;
    assign mem_invalidating = invalidating;

    // The map's shadow duplicate, as its own entrant into the cache
    // (docs/GS.md rung 3e).
    wire        shd_take_w;
    wire [15:0] shd_ppn_w;
    wire [7:0]  shd_off_w;
    apple_mmu #(.GS (1'b1)) u_mmu (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_bank (u_bank), .op_addr (u_addr), .op_rw (u_rw), .op_wdata (u_wdata),
        .op_present (u_present), .op_commit (u_commit),
        .rom_ok (rom_loaded),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_aux (cl_aux), .cl_bank (cl_bank),
        .cl_off (cl_off), .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .intc8rom (intc8rom),
        .cl_posted (cl_posted), .cl_sh (cl_sh), .shd_drops (shd_drops), .cl_wdata (cl_wdata),
        .pw_valid (pw_any_valid), .pw_ppn (pw_any_ppn), .pw_off (pw_any_off),
        .pw_data (pw_any_data), .pw_ready (pw_ready_w), .pw_take (pw_take_w),
        .shd_take_o (shd_take_w), .shd_ppn_o (shd_ppn_w), .shd_off_o (shd_off_w),
        .pf_off (pf_off),
        .sw_state (sw_state), .vid_sw (), .rw_bank (rw_bank),
        .gs_shadow_o (gs_shadow_w), .gs_cyareg_o (gs_cyareg_w),
        .gs_sltrom_o (gs_sltrom_w), .gs_state_o (gs_state_w),
        .q_addr ({drv_bank, nxt_addr}), .q_divert (q_divert), .q_rw (cpu_rw_eff), .q_cls (q_cls),
        // Nothing is internalized on the GS build yet: $C0xx is BUS class and
        // rides a real cycle until rtl/gs_io.sv answers it (rung 3b).
        .swi_on (1'b0), .swi_kbd_ok (1'b0), .swi_fb_ok (1'b0),
        .swi_vbl_ok (1'b0), .swi_vbl_bar (1'b1), .swi_kbd_low (7'd0),
        .swi_pb_ok (1'b0), .swi_pdl_ok (1'b0),
        .swi_hd_slot (3'd0), .swi_fd_slot (3'd0), .swi_mb_slot (3'd0),
        .swi_mouse_slot (3'd0), .swi_u2_slot (3'd0), .swi_prn_slot (3'd0),
        .q_nsc (), .q_slot (q_slot), .q_swi (q_swi_mmu), .q_swi_quiet (q_swi_quiet),
        .swi_stat_byte (mmu_swi_stat), .swi_stat_bits (mmu_stat_bits),
        .p_addr (p_addr_w), .p_cls (p_cls), .p_aux (p_aux_w), .p_off (p_off_w),
        .d_addr (dq_addr_w), .d_rw (dq_rw_w), .d_cls (dcls_w), .d_aux (daux_w), .d_off (doff_w),
        .map_changed (map_changed),
        .cl_ppn (cl_ppn_w), .pf_ppn (pf_ppn_w),
        .p_ppn (p_ppn_w), .p_reg (p_reg_w), .p_fold (p_fold_w), .p_fs (p_fs_w),
        .d_ppn (d_ppn_w), .d_reg (d_reg_w), .d_fold (d_fold_w), .d_sh (d_sh_w),
        .map_settling (map_settling), .rt_rd_flat (rt_rd_flat), .rwb_p1 (rwb_p1_w),
        .core_dbr (cpu_dbr), .core_pbr (cpu_pc24[23:16])
    );

    // ---- the IIgs chipset on $C0xx ------------------------------------------------
    // One instance, two claims: `claim` off the LIVE address for the
    // dispatcher's decision, and `u_claim` off the REGISTERED op for the byte
    // mux (rtl/gs_io.sv, "the two faces of an op").
    gs_io #(.adb_keymap (ADB_KEYMAP)) u_gsio (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .q_addr ({drv_bank, nxt_addr}), .q_rw (cpu_rw_eff), .claim (gsio_claim),
        .u_bank (u_bank), .u_addr (u_addr), .u_rw (u_rw), .u_wdata (u_wdata),
        .u_commit (swi_commit),
        .gs_shadow (gs_shadow_w), .gs_cyareg (gs_cyareg_w),
        .gs_sltrom (gs_sltrom_w), .gs_state (gs_state_w),
        .stat_byte (mmu_swi_stat), .stat_bits (mmu_stat_bits), .kbd_low (7'd0), .vbl (vbl_active),
        .fr_vec (gsio_fr_vec),
        .scan_v (tb_scan_v), .scan_h (tb_scan_h),
        // The image's write tap, ANY bank, for the SCBs at $E1/9D00: the
        // scan-line interrupt is what launches the XMAS demo (its handler on
        // the $E1/0028 hook JSLs to bank $0E), and with the tap tied off the
        // bench loaded the whole demo and never saw it start (docs/IWM35.md).
        .mw_stb (tb_mwx_stb), .mw_bank (tb_mw_bank), .mw_addr (tb_mw_addr), .mw_byte (tb_mw_byte),
        // PINNED TO KEGS's OWN CLOCK.  tools/kegs/trace_rom.sh runs the
        // reference with -pintime 3871713600 (2026-09-08 12:00:00 since
        // 1904) so its trace is the same every run; the card must believe the
        // same seconds or the two disagree about a byte the ROM checksums.
        .seed_time (SEED_TIME), .border (),
        // The battery RAM the host ships, sent before RES' is released.
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (16'd0),
        .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid), .bram_ok (bram_landed),
        .clk_dbg_idx (6'd0), .clk_dbg_word (), .clk_stat (),
        // The IIe's own keyboard (rtl/gs_kbd_a2.sv) is a TOP-LEVEL wiring:
        // it feeds on the driver's parked dummy cycles, and this bench has no
        // driver and no backplane.  sim/gs_kbd_a2_tb.sv drives it from a
        // model IOU instead.  Quiet here, so the reference trace is unmoved.
        .loc_valid (1'b0), .loc_code (7'd0), .loc_up (1'b0),
        .loc_mods (8'd0), .live_mods (8'd0), .pb_sel (pb_force),

        // The bench's frame is counted in BUS cycles, which is wall time
        // here, so the micro's wall tick is the same pulse.
        .frame_tick (frame_tick), .wall_tick (frame_tick),
        .c000_ext (dl_kbd_rd), .c000_byte (gs_c000_byte),
        // The 3.5" drive: the platter turns with the core's ops, its seek
        // notices come out here and the modelled host below answers them.
        .core_tick (seq_fast_tick || turbo_tick || dline_tick || (op_commit && !op_dummy && !op_ovr)),
        .fd35_word (fd35_word), .fd35_valid (fd35_valid), .fd35_take (fd35_take),
        .fd35_inserted (fd35_inserted), .fd35_wp (1'b1),
        .fd35_late_clr (1'b0), .fd35_fill_clr (1'b0),
        .fd35_stale (), .fd35_track (), .fd35_side (), .fd35_motor35 (), .fd35_motor (),
        .fd35_ctl (), .fd35_seeks (), .fd35_late (), .fd35_fill_max (), .fd35_stall (fd35_stall),
        .fd525_inserted (fd525_inserted), .fd525_wp (fd525_wp),
        .fd525_cell ({13'd32, 13'd32}), .fd525_tracks ({6'd35, 6'd35}),
        .fd525_flush (2'b00),
        .fd525_stale (), .fd525_dirty (), .fd525_phase (),
        .u_claim (gsio_u_claim), .rd_byte (gsio_byte), .irq (gsio_irq)
    );

    // ---- the 3.5" drive's host (docs/IWM35.md) ------------------------------
    // The image's tracks as tools/nib35.py wrote them, at FD35_STRIDE a track;
    // a seek {seq, 0, qtr, 0} is answered FD35_DELAY clocks later with the
    // track's chunks - {seq, chunk, qtr, 0}, {chunks, 0, nibbles}, then up to
    // 252 words - through the same message pins the ROM loader used.
    wire [31:0] fd35_word;
    wire        fd35_valid, fd35_stall;
    wire        fd35_take = 1'b1;
    reg         fd35_inserted = 1'b0;
    reg  [1:0]  fd525_inserted = 2'b00;   // the 5.25" drives on the IWM (--fd525)
    // Writable, as the host's floppy service reports an image it can write.
    reg  [1:0]  fd525_wp = 2'b00;
    reg [7:0]   fd35_img [0:160*FD35_STRIDE-1];
    integer     fd35_counts [0:159];
    reg         fd35_hdr_seen = 1'b0;
    reg [7:0]   fd35_req_seq = 8'd0, fd35_req_qtr = 8'd0;
    integer     fd35_pending = 0;
    integer     fd35_seeks = 0, fd35_fills = 0;
    reg         msg_lock = 1'b0;
    initial if (HAS_FD35) begin
        integer fc, k;
        $readmemh(FD35F, fd35_img);
        fc = $fopen(FD35_COUNTSF, "r");
        for (k = 0; k < 160; k = k + 1) if ($fscanf(fc, "%d\n", fd35_counts[k]) != 1) fd35_counts[k] = 0;
        $fclose(fc);
    end
    // The IWM's one link source carries both drives' seeks: FD35_SEEK ($32)
    // for the 3.5" drive, the Disk II's FD_SEEK ($20) for a 5.25" drive - and
    // FD_DIRTY ($21) uploads of a written 5.25" track, which this host takes
    // and drops.  Messages are split by their header's length.
    reg [7:0]   fd_hdr_type = 8'd0;
    integer     fd_left = 0, fd_idx = 0;
    integer     fd525_dirty_chunks = 0;
    // The tracks as BIT STREAMS (tools/nib525.py --bits), 6656 bytes a track,
    // and each track's bit count.
    reg [7:0]   fd525_img [0:35*6656-1];
    integer     fd525_bits [0:34];
    reg [7:0]   fd525_req_seq = 8'd0;
    reg [7:0]   fd525_req_qtr = 8'd0;
    reg [6:0]   fd525_req_phase = 7'd0;
    reg         fd525_req_drive = 1'b0;
    integer     fd525_pending = 0;
    integer     fd525_seeks = 0, fd525_fills = 0;
    initial if (HAS_FD525) begin : fd525_load
        integer fc, k;
        $readmemh(FD525F, fd525_img);
        fc = $fopen(FD525_COUNTSF, "r");
        for (k = 0; k < 35; k = k + 1) if ($fscanf(fc, "%d\n", fd525_bits[k]) != 1) fd525_bits[k] = 0;
        $fclose(fc);
    end
    always @(posedge clk) if (fd35_valid && fd35_take) begin
        if (fd_left == 0) begin
            fd_hdr_type = fd35_word[15:8];
            fd_left     = fd35_word[7:0];
            fd_idx      = 0;
            if (fd_hdr_type == 8'h21) fd525_dirty_chunks = fd525_dirty_chunks + 1;
        end else begin
            if (fd_idx == 0) begin
                if (fd_hdr_type == 8'h32) begin
                    fd35_req_seq  = fd35_word[31:24];
                    fd35_req_qtr  = fd35_word[15:8];
                    fd35_pending  = fd35_pending + 1;
                    fd35_seeks    = fd35_seeks + 1;
                end else if (fd_hdr_type == 8'h20) begin
                    fd525_req_seq   = fd35_word[31:24];
                    fd525_req_qtr   = fd35_word[15:8];
                    fd525_req_phase = fd35_word[7:1];
                    fd525_req_drive = fd35_word[0];
                    fd525_pending   = fd525_pending + 1;
                    fd525_seeks     = fd525_seeks + 1;
                end
            end
            fd_idx  = fd_idx + 1;
            fd_left = fd_left - 1;
        end
    end
    // A 5.25" track as the host's floppy service sends it: seven FD_TRACK
    // chunks, {seq, chunk, qtr, drive}, {bits}, then 252 words of the bit
    // stream (152 in the last).  The track under a quarter-track position is
    // the phase's (phase >> 1), as the host does for a sector image; past the
    // image, no bits.
    task send_fd525_track(input [7:0] sq, input [7:0] qtr, input [6:0] ph, input drv);
        integer c, n, k, base, trk, nbits;
        begin
            trk   = ph >> 1;
            nbits = (trk < 35) ? fd525_bits[trk] : 0;
            for (c = 0; c < 7; c = c + 1) begin
                n = (c < 6) ? 252 : 152;
                @(negedge clk);
                msg_valid <= 1'b1; msg_type <= 8'h1F; msg_len <= 8'(n + 2);
                @(negedge clk);
                msg_valid <= 1'b0; pay_valid <= 1'b1;
                pay_data <= {sq, c[7:0], qtr, 7'd0, drv};
                @(negedge clk);
                pay_data <= {16'd0, nbits[15:0]};
                @(negedge clk);
                base = trk * 6656 + c * 1008;
                for (k = 0; k < n; k = k + 1) begin
                    pay_data <= (trk < 35) ? {fd525_img[base + 4*k + 3], fd525_img[base + 4*k + 2],
                                              fd525_img[base + 4*k + 1], fd525_img[base + 4*k]} : 32'd0;
                    @(negedge clk);
                end
                pay_valid <= 1'b0;
                @(negedge clk);
            end
            fd525_fills = fd525_fills + 1;
        end
    endtask
    initial if (HAS_FD525) begin : fd525_host
        wait (boot_go);
        repeat (100) @(negedge clk);
        fd525_inserted = 2'b01;         // the disk goes in drive 1
        forever begin
            wait (fd525_pending > 0);
            repeat (FD525_DELAY) @(negedge clk);
            wait (!msg_lock);
            msg_lock = 1'b1;
            send_fd525_track(fd525_req_seq, fd525_req_qtr, fd525_req_phase, fd525_req_drive);
            msg_lock = 1'b0;
            fd525_pending = fd525_pending - 1;
        end
    end
    task send_fd35_track(input [7:0] sq, input [7:0] qtr);
        integer nib, words, chunks, c, n, k, base;
        begin
            nib    = fd35_counts[qtr];
            words  = (nib + 3) / 4;
            chunks = (words + 251) / 252;
            for (c = 0; c < chunks; c = c + 1) begin
                n = (words - c * 252 > 252) ? 252 : words - c * 252;
                @(negedge clk);
                msg_valid <= 1'b1; msg_type <= 8'h31; msg_len <= 8'(n + 2);
                @(negedge clk);
                msg_valid <= 1'b0; pay_valid <= 1'b1;
                pay_data <= {sq, c[7:0], qtr, 8'd0};
                @(negedge clk);
                pay_data <= {chunks[7:0], 8'd0, nib[15:0]};
                @(negedge clk);
                base = qtr * FD35_STRIDE + c * 1008;
                for (k = 0; k < n; k = k + 1) begin
                    pay_data <= {fd35_img[base + 4*k + 3], fd35_img[base + 4*k + 2],
                                 fd35_img[base + 4*k + 1], fd35_img[base + 4*k]};
                    @(negedge clk);
                end
                pay_valid <= 1'b0;
                @(negedge clk);
            end
            fd35_fills = fd35_fills + 1;
        end
    endtask
    initial if (HAS_FD35) begin : fd35_host
        // The message pins are shared with the ROM download and the battery
        // RAM: the disk goes in only once the machine is released to boot,
        // when nothing else is being sent.
        wait (boot_go);
        repeat (100) @(negedge clk);
        fd35_inserted = 1'b1;           // the disk goes in: the card fetches track 0
        forever begin
            wait (fd35_pending > 0);
            repeat (FD35_DELAY) @(negedge clk);
            wait (!msg_lock);
            msg_lock = 1'b1;
            send_fd35_track(fd35_req_seq, fd35_req_qtr);
            msg_lock = 1'b0;
            fd35_pending = fd35_pending - 1;
        end
    end
    // The IWM trace: each access to $C0Ex as it retires, with the byte a
    // read took, and the chip and drive as the access leaves them.
    integer fd35_traced = 0;
    always @(posedge clk) if (FD35_TRACE != 0 && u_gsio.u_iwm.iwm_act && fd35_traced < FD35_TRACE) begin
        fd35_traced = fd35_traced + 1;
        $display("    IWM %8d %s $C0%02X %s%02X  ph=%b mot=%0d q7q6=%0d%0d sel35=%0d ctl=%0d stat35=$%X trk=%0d side=%0d m35=%0d stale=%0d pos=%0d latch=%02X v=%0d mode=$%02X per=%0d acc=%0d hp=%0d/%0d",
                 trace_instrs, u_gsio.u_iwm.op_rw ? "rd" : "WR", u_gsio.u_iwm.op_lo,
                 u_gsio.u_iwm.op_rw ? "-> " : "<- ",
                 u_gsio.u_iwm.op_rw ? u_gsio.u_iwm.rd_byte : u_gsio.u_iwm.op_wdata,
                 u_gsio.u_iwm.phases, u_gsio.u_iwm.motor_on, u_gsio.u_iwm.q7, u_gsio.u_iwm.q6,
                 u_gsio.u_iwm.apple35_sel, u_gsio.u_iwm.c031_ctrl, u_gsio.u_iwm.stat35,
                 u_gsio.u_iwm.track35, u_gsio.u_iwm.side35, u_gsio.u_iwm.motor35, u_gsio.u_iwm.stale,
                 u_gsio.u_iwm.pos, u_gsio.u_iwm.latch, u_gsio.u_iwm.latch_valid, u_gsio.u_iwm.mode,
                 8'd224, u_gsio.u_iwm.nib_acc,
                 u_gsio.u_iwm.ph5[0], u_gsio.u_iwm.ph5[1]);
    end

    // Every 5.25" store - a byte the machine wrote into the buffered track -
    // with the chip's state as it landed, the first 40 of them.
    integer d5_stores_shown = 0;
    always @(posedge clk) if (HAS_FD525 && u_gsio.u_iwm.store && d5_stores_shown < 40) begin
        d5_stores_shown = d5_stores_shown + 1;
        $display("    STORE %8d $C0%02X <- %02X  ph=%b en2=%0d mot=%0d q7q6=%0d%0d sel35=%0d drv=%0d pos=%0d buf_id=%03x mode=$%02X",
                 trace_instrs, u_gsio.u_iwm.op_lo, u_gsio.u_iwm.op_wdata, u_gsio.u_iwm.phases,
                 u_gsio.u_iwm.enable2, u_gsio.u_iwm.motor_on, u_gsio.u_iwm.q7, u_gsio.u_iwm.q6,
                 u_gsio.u_iwm.apple35_sel, u_gsio.u_iwm.drive_sel, u_gsio.u_iwm.pos,
                 u_gsio.u_iwm.buf_id, u_gsio.u_iwm.mode);
    end

    // THE SCAN-LINE INTERRUPT'S INGREDIENTS, named as they happen: every SCB
    // write the chipset's tap sees, every write to NEWVIDEO and the VGC
    // interrupt register, and the interrupt itself.  The XMAS demo launches
    // from this interrupt (docs/IWM35.md), so a run that loads it and never
    // starts it is missing one of these.
    integer scb_writes = 0, scan_irqs = 0;
    reg scan_q_prev = 1'b0;
    always @(posedge clk) begin
        scan_q_prev <= u_gsio.irq_scan_q;
        if (u_gsio.scb_hit) begin
            scb_writes = scb_writes + 1;
            if (scb_writes <= 8 || u_gsio.mw_byte[6])
                $display("    SCB write #%0d at instruction %0d: $E1/%04X <- $%02X", scb_writes, trace_instrs, u_gsio.mw_addr, u_gsio.mw_byte);
        end
        if (u_gsio.act && !u_gsio.u_rw && (u_gsio.u_addr[7:0] == 8'h29 || u_gsio.u_addr[7:0] == 8'h23))
            $display("    VGC write at instruction %0d: $%02X/C0%02X <- $%02X", trace_instrs, u_gsio.u_bank, u_gsio.u_addr[7:0], u_gsio.u_wdata);
        if (u_gsio.irq_scan_q && !scan_q_prev) begin
            scan_irqs = scan_irqs + 1;
            if (scan_irqs <= 5) $display("    scan-line interrupt #%0d at instruction %0d, line %0d", scan_irqs, trace_instrs, u_gsio.scan_v);
        end
    end

    // The demo launched: the first instruction fetched from bank $0E, which
    // is where the FTA loader puts the demo proper (the KEGS trace of the
    // XMAS demo enters it at instruction 1,499,453 - KEGS's disk gives a
    // nibble per read and its slot-7 firmware jumps straight to slot 5; here
    // the scan times out on slot 6 first and the platter turns at its real
    // rate, so the same point is millions of instructions later).
    integer demo_launched_at = 0;
    always @(posedge clk) if (cpu_cyc_en && cpu_sync && demo_launched_at == 0 &&
                              cpu_a24[23:16] == 8'h0E && trace_instrs > 0)
        demo_launched_at = trace_instrs;

    // ROM 3 is 512 chunks of 512 bytes landing at physical bank $FC page $00.
    wire        rl_pw_valid;
    wire [15:0] rl_pw_ppn;
    wire [7:0]  rl_pw_off, rl_pw_data;
    wire        rom_busy;
    wire [7:0]  rom_overruns;
    rom_loader #(.N_CHUNKS (ROM_CHUNKS), .ROM_PPN0 (16'hFC00)) u_rom (
        .clk (clk), .rst (rst),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid),
        .op_present (u_present), .image_ready (image_ready),
        .pw_valid (rl_pw_valid), .pw_ppn (rl_pw_ppn), .pw_off (rl_pw_off),
        .pw_data (rl_pw_data), .pw_take (pw_take_w && !pw_valid_w),
        .busy (rom_busy), .overruns (rom_overruns), .rom_ok (rom_loaded)
    );

    page_cache u_cache (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_ppn (cl_ppn_w), .cl_off (cl_off[7:0]),
        .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_wdata (cl_wdata), .cl_posted (cl_posted),
        .pw_pending (d_pending_w), .pw_ready (pw_ready_w),
        .pf_ppn (pf_ppn_w), .pf_off (pf_off[7:0]),
        .pw_take (pw_take_w), .pw_ppn (pw_any_ppn), .pw_off (pw_any_off),
        .shd_take (shd_take_w), .shd_ppn (shd_ppn_w), .shd_off (shd_off_w),
        .op_addr (u_addr),
        .op_present (u_present), .op_commit (u_commit), .op_divert (u_divert), .data_sync (data_sync),
        .sub_en (mem_sub_en), .sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .op_row_v (op_row_v_w), .op_row (op_row_w), .op_row_ppn (op_row_ppn_w),
        .mw_stb (), .mw_addr (tb_mw_addr), .mw_byte (tb_mw_byte), .mwx_stb (tb_mwx_stb), .mw_bank (tb_mw_bank),
        .il_req (il_req | dl_req_w), .il_ppn (il_req ? il_ppn_w : dl_ppn_w),
        .il_line (il_req ? il_line_w : dl_line_w), .il_src (!il_req),
        .il_ack (il_ack), .il_done (il_done), .il_ok (il_ok), .il_row (il_row),
        .serve (serve), .inval (1'b0), .cnt_clr (1'b0), .image_ready (image_ready),
        .invalidating (invalidating),
        .hits (hits), .misses (misses), .served (served), .mismatches (mismatches),
        .last_mismatch (last_mismatch), .diverted (diverted), .late_fills (late_fills),
        .fifo_drops (fifo_drops),
        .mem_fills (mem_fills), .mem_flushes (mem_flushes), .mem_declines (mem_declines),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data),
        .dbg_sel (4'd0), .dbg_val ()
    );
    wire [31:0] mem_fills, mem_flushes, mem_declines;

    wire [1:0]   c_req, c_gnt, c_cyc, c_stb, c_we, c_stall, c_ack;
    wire [47:0]  c_addr;
    wire [255:0] c_data;
    wire [31:0]  c_sel;
    wire [127:0] c_rdata;
    wire         wb_cyc, wb_stb, wb_we, wb_stall, wb_ack;
    wire [23:0]  wb_addr;
    wire [127:0] wb_data, wb_rdata;
    wire [15:0]  wb_sel;
    wire [3:0]   wb_aux, wb_rdata_aux;
    assign c_req[0] = 1'b0; assign c_cyc[0] = 1'b0; assign c_stb[0] = 1'b0; assign c_we[0] = 1'b0;
    assign c_addr[23:0] = 24'd0; assign c_data[127:0] = 128'd0; assign c_sel[15:0] = 16'd0;

    wb_arb #(.N (2), .HAS_PRIO (1'b1)) u_arb (
        .clk (clk), .rst (rst), .rot_ok (rot_ok),
        .c_req (c_req), .c_gnt (c_gnt), .c_cyc (c_cyc), .c_stb (c_stb),
        .c_we (c_we), .c_addr (c_addr), .c_data (c_data), .c_sel (c_sel),
        .c_stall (c_stall), .c_ack (c_ack), .c_rdata (c_rdata),
        .wb_cyc (wb_cyc), .wb_stb (wb_stb), .wb_we (wb_we), .wb_addr (wb_addr),
        .wb_data (wb_data), .wb_sel (wb_sel), .wb_aux (wb_aux),
        .wb_stall (wb_stall), .wb_ack (wb_ack), .wb_rdata (wb_rdata), .wb_rdata_aux (wb_rdata_aux)
    );

    page_client u_client (
        .clk (clk), .rst (rst), .calib_complete (1'b1),
        .master_active (master_active), .op_present (op_present),
        .accel (accel_on),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data),
        .req (c_req[1]), .gnt (c_gnt[1]), .cyc (c_cyc[1]), .stb (c_stb[1]),
        .we (c_we[1]), .addr (c_addr[47:24]), .data (c_data[255:128]), .sel (c_sel[31:16]),
        .stall (c_stall[1]), .ack (c_ack[1]), .rdata (c_rdata),
        .rot_ok (rot_ok), .mem_idle (mem_idle),
        .image_ready (image_ready)
    );

    // ---- the DDR3 stub: the whole 16 MB, in order, twelve clocks late -------------
    localparam integer IMG = 16 * 1024 * 1024;
    reg [7:0] smem [0:IMG-1];
    localparam integer DL = 64;
    reg [127:0] dl_d [0:DL-1];
    reg [3:0]   dl_aux [0:DL-1];
    integer     dl_time [0:DL-1];
    integer     dl_wp = 0, dl_rp = 0, now = 0, s_cnt = 0;
    reg         wb_ack_r = 0, s_stall = 0;
    reg [127:0] wb_rdata_r = 0;
    reg [3:0]   wb_aux_r = 0;
    integer     ddr_range_bad = 0;
    // How many 16-byte line write-backs the DDR3 was ever given per physical
    // page: a page that comes back wrong having been given none was evicted
    // with no write-back at all.
    integer     bad_flush = 0;
    reg [15:0]  wb_pg;
    integer     wb_ri;
    integer     wb_lines [0:65535];
    integer     wbi;
    initial for (wbi = 0; wbi < 65536; wbi = wbi + 1) wb_lines[wbi] = 0;
    assign wb_ack = wb_ack_r; assign wb_rdata = wb_rdata_r; assign wb_rdata_aux = wb_aux_r;
    assign wb_stall = s_stall;
    function automatic [23:0] wb_to_byte(input [23:0] a);
        wb_to_byte = {{a[22:10], a[6:0]}, 4'd0};    // {ppn, line} * 16
    endfunction
    integer i;
    always @(posedge clk) begin
        now <= now + 1;
        s_cnt <= s_cnt + 1;
        s_stall <= ((s_cnt % 41) < 2);
        wb_ack_r <= 1'b0;
        if (wb_cyc && wb_stb && !wb_stall) begin
            if (wb_addr[9:7] != 3'd0 || wb_addr[23])
                ddr_range_bad = ddr_range_bad + 1;
            if (wb_we) begin
                for (i = 0; i < 16; i = i + 1)
                    if (wb_sel[i]) smem[wb_to_byte(wb_addr) + i] <= wb_data[8*i +: 8];
                // rtl/page_client.sv line_to_wb: a[22:10] is ppn[15:3] and
                // a[6:0] is {ppn[2:0], line[3:0]}, so the page is both halves.
                wb_lines[{wb_addr[22:10], wb_addr[6:4]}] =
                    wb_lines[{wb_addr[22:10], wb_addr[6:4]}] + 1;
                // THE FLUSH ORACLE.  A page in the ROM's physical range can
                // never have changed - nothing in the machine can write it
                // (apple_mmu gives banks $FC-$FF wr = 0) and the loader is
                // long done - so a write-back of one that is not the image
                // is a BAD FLUSH, caught here at the clock it is issued
                // rather than a hundred thousand instructions later when
                // something fetches from it.  docs/GS.md rung 3e.
                wb_pg = {wb_addr[22:10], wb_addr[6:4]};
                if (wb_pg >= 16'hFC00) begin
                    wb_ri = (int'(wb_pg) - 16'hFC00) * 256 + int'(wb_addr[3:0]) * 16;
                    for (i = 0; i < 16; i = i + 1)
                        if (wb_sel[i] && wb_data[8*i +: 8] !== rom_img[wb_ri + i]) begin
                            bad_flush = bad_flush + 1;
                            if (bad_flush <= 8)
                                $display("    BAD FLUSH at %0d clocks: ROM page $%04X line %0d byte %0d wrote $%02X, the image has $%02X",
                                         now, wb_pg, wb_addr[3:0], i,
                                         wb_data[8*i +: 8], rom_img[wb_ri + i]);
                        end
                end
                dl_d[dl_wp % DL] <= 128'd0;
            end else begin
                for (i = 0; i < 16; i = i + 1)
                    dl_d[dl_wp % DL][8*i +: 8] <= smem[wb_to_byte(wb_addr) + i];
            end
            dl_aux[dl_wp % DL] <= wb_aux;
            dl_time[dl_wp % DL] <= now + DDR_LAT;
            dl_wp <= dl_wp + 1;
        end
        if (dl_rp != dl_wp && now >= dl_time[dl_rp % DL] && !wb_ack_r) begin
            wb_ack_r <= 1'b1; wb_rdata_r <= dl_d[dl_rp % DL]; wb_aux_r <= dl_aux[dl_rp % DL];
            dl_rp <= dl_rp + 1;
        end
    end

    // ---- the trace ---------------------------------------------------------------
    // One record per instruction, emitted at the NEXT instruction's fetch so
    // the registers are the ones this instruction left (see the header).
    reg boot_go = 1'b0, have_prev = 1'b0;
    reg [7:0]  pv_pbr = 8'd0, pv_op = 8'd0;
    reg [15:0] pv_pc = 16'd0;
    integer tf, trace_instrs = 0;
    initial tf = $fopen(TRACEF, "wb");

    wire [15:0] cpu_psr = {7'd0, u_cpu.f_e,
                           u_cpu.f_n, u_cpu.f_v, u_cpu.f_m, u_cpu.f_x,
                           u_cpu.f_d, u_cpu.f_i, u_cpu.f_z, u_cpu.f_c};
    // The opcode is on din at the edge that ends the fetch cycle.
    wire fetch_now = boot_go && !cpu_rst && cpu_cyc_en && cpu_sync;

    always @(posedge clk) if (fetch_now) begin
        if (have_prev) begin
            $fwrite(tf, "%u%u%u%u%u",
                    {u_cpu.dbr, pv_pbr, pv_pc},
                    {pv_op, 24'd0},
                    {cpu_psr, u_cpu.a},
                    {u_cpu.x, u_cpu.y},
                    {u_cpu.s, u_cpu.d});
            trace_instrs = trace_instrs + 1;
        end
        pv_pbr <= cpu_bank; pv_pc <= cpu_addr; pv_op <= cpu_din;
        have_prev <= 1'b1;
    end

    // ---- the bank census: what an OTHER-class data cycle is ------------------------
    // docs/GS.md rung 6's open item, and the question behind a data-front arm
    // for long addressing.  rtl/dline.sv serves the ZERO and DBR classes from
    // precomputed per-line bits, and a class-OTHER candidate serves nothing.
    // An arm that PREDICTED the bank - the last few OTHER banks seen, each
    // with one precomputed bit per line - serves a candidate whose bank is in
    // that table.  So the number that sizes it is how often the bank is among
    // the last 1, 2 or 4 DISTINCT OTHER banks: a k-entry table with
    // least-recently-used replacement.  ZERO and DBR cycles in between touch
    // no entry, exactly as they would not in the table.
    //
    // I/O IS COUNTED APART.  An OTHER cycle into $C000-$CFFF of a pair bank
    // ($00/$01/$E0/$E1) is the I/O page or slot ROM, which no line serves
    // whatever its bank - and a VBL wait polling through a long address
    // (the XMAS demo's LDA $E1Cxxx / BPL) is most of that demo's OTHER
    // cycles.  Those stay OUT of the table, the regions, the opcodes and the
    // banks, so everything below "memory" describes what the arm could serve.
    //
    // Counted at the edge the candidate registers (dline's dq_addr <= d_pred):
    // the core moves, d_pred_v, and d_pred names the cycle about to run.  The
    // instruction's opcode is pv_op, latched at its fetch.  An interval line
    // every BC_EVERY instructions keeps the boot's phases apart.
    localparam integer BC_EVERY = 1000000;
    localparam integer BC_K     = 4;
    wire bc_move = boot_go && !cpu_rst && cpu_cyc_en;
    reg  bc_freeze = 1'b0;               // the end of the run: both censuses stop, the card's drains
    wire bc_edge = bc_move && cpu_d_pred_v && !bc_freeze;
    longint bc_cls  [0:2][0:1];         // [class ZERO/DBR/OTHER][read, write]
    longint bc_io   [0:1];              // OTHER into a pair bank's $Cxxx, [read, write]
    longint bc_reg  [0:3];              // OTHER memory by bank region
    longint bc_eq0, bc_eqd, bc_eqp;     // OTHER memory whose bank is zero / the DBR / the PBR anyway
    longint bc_mru  [0:BC_K][0:1];      // position in the table (BC_K = not in it), [read, write]
    longint bc_op   [0:255];            // OTHER memory by opcode
    longint bc_bank [0:255];            // OTHER memory by bank
    longint bc_cycles;                  // every cycle the core moved
    reg [7:0] bc_list [0:BC_K-1];
    integer   bc_len;
    // The interval's baseline.
    longint bi_data, bi_oth, bi_io, bi_w, bi_m1, bi_m2, bi_m4;
    integer   bi_from;
    initial begin : bc_init
        integer k, j;
        for (k = 0; k < 3; k = k + 1) for (j = 0; j < 2; j = j + 1) bc_cls[k][j] = 0;
        for (k = 0; k < 4; k = k + 1) bc_reg[k] = 0;
        for (k = 0; k <= BC_K; k = k + 1) for (j = 0; j < 2; j = j + 1) bc_mru[k][j] = 0;
        for (k = 0; k < 256; k = k + 1) begin bc_op[k] = 0; bc_bank[k] = 0; end
        for (k = 0; k < BC_K; k = k + 1) bc_list[k] = 8'd0;
        bc_io[0] = 0; bc_io[1] = 0;
        bc_eq0 = 0; bc_eqd = 0; bc_eqp = 0; bc_cycles = 0; bc_len = 0;
        bi_data = 0; bi_oth = 0; bi_io = 0; bi_w = 0; bi_m1 = 0; bi_m2 = 0; bi_m4 = 0; bi_from = 0;
    end

    always @(posedge clk) begin : bc_count
        integer pos, sh, k;
        reg [7:0] b;
        reg       pair;
        integer w;
        if (bc_move) bc_cycles = bc_cycles + 1;
        if (bc_edge && cpu_d_pred_bcls != 2'd3) begin
            b = cpu_d_pred[23:16];
            w = cpu_d_pred_rw ? 0 : 1;
            pair = (b == 8'h00 || b == 8'h01 || b == 8'hE0 || b == 8'hE1);
            bc_cls[cpu_d_pred_bcls][w] = bc_cls[cpu_d_pred_bcls][w] + 1;
            if (cpu_d_pred_bcls == 2'd2 && pair && cpu_d_pred[15:12] == 4'hC) begin
                bc_io[w] = bc_io[w] + 1;
            end else if (cpu_d_pred_bcls == 2'd2) begin
                if (pair)                            bc_reg[0] = bc_reg[0] + 1;
                else if (b >= 8'h02 && b <= 8'h7F)   bc_reg[1] = bc_reg[1] + 1;
                else if (b >= 8'hFC)                 bc_reg[2] = bc_reg[2] + 1;
                else                                 bc_reg[3] = bc_reg[3] + 1;
                if (b == 8'h00)             bc_eq0 = bc_eq0 + 1;
                if (b == cpu_dbr)           bc_eqd = bc_eqd + 1;
                if (b == cpu_pc24[23:16])   bc_eqp = bc_eqp + 1;
                bc_op[pv_op] = bc_op[pv_op] + 1;
                bc_bank[b]   = bc_bank[b] + 1;
                // Where it stands in the table, then to the front of it.
                pos = BC_K;
                for (k = bc_len - 1; k >= 0; k = k - 1) if (bc_list[k] == b) pos = k;
                bc_mru[pos][w] = bc_mru[pos][w] + 1;
                if (pos < BC_K)          sh = pos;
                else if (bc_len < BC_K)  begin sh = bc_len; bc_len = bc_len + 1; end
                else                     sh = BC_K - 1;
                for (k = sh; k > 0; k = k - 1) bc_list[k] = bc_list[k-1];
                bc_list[0] = b;
            end
        end
    end

    // ---- the card's census, fed as rtl/master_top.sv feeds it ------------------
    // rtl/bank_census.sv on copies of the snapshot registers master_top keeps
    // (h_ret, top_w4_q, top_w3_q).  At the end its counters must equal this
    // bench's census count for count: the bench's was written first, from
    // the core's contract, and is the oracle.
    reg          bcq_ret = 1'b0, bcq_v = 1'b0, bcq_rw = 1'b0;
    reg  [1:0]   bcq_cls = 2'd0;
    reg  [23:0]  bcq_cand = 24'd0;
    wire [31:0]  bcq_dbg;
    always @(posedge clk) begin
        bcq_ret  <= bc_move && !bc_freeze;
        bcq_v    <= cpu_d_pred_v;
        bcq_rw   <= cpu_d_pred_rw;
        bcq_cls  <= cpu_d_pred_bcls;
        bcq_cand <= u_dline.dq_addr;
    end
    bank_census u_bank_census (
        .clk (clk), .rst (!boot_go), .clr (1'b0),
        .moved_q (bcq_ret), .pv_q (bcq_v), .prw_q (bcq_rw), .pcls_q (bcq_cls),
        .cand_qq (bcq_cand), .sel (4'd0), .dbg (bcq_dbg)
    );

    function automatic string bc_pct(input longint n, input longint d);
        bc_pct = (d == 0) ? "  -  " : $sformatf("%5.1f", 100.0 * real'(n) / real'(d));
    endfunction

    always @(posedge clk) if (fetch_now && have_prev && trace_instrs > 0 &&
                              (trace_instrs % BC_EVERY) == 0) begin : bc_interval
        longint data, oth, io, mem, wr, m1, m2, m4;
        data = bc_cls[0][0] + bc_cls[0][1] + bc_cls[1][0] + bc_cls[1][1] + bc_cls[2][0] + bc_cls[2][1];
        oth  = bc_cls[2][0] + bc_cls[2][1];
        io   = bc_io[0] + bc_io[1];
        mem  = oth - io;
        wr   = bc_cls[2][1] - bc_io[1];
        m1   = bc_mru[0][0] + bc_mru[0][1];
        m2   = m1 + bc_mru[1][0] + bc_mru[1][1];
        m4   = m2 + bc_mru[2][0] + bc_mru[2][1] + bc_mru[3][0] + bc_mru[3][1];
        $display("    bank census %0d-%0d: %0d data, OTHER I/O %0d (%s%%), OTHER memory %0d (%s%%, %0d writes), in last 1/2/4: %s / %s / %s %%",
                 bi_from, trace_instrs, data - bi_data,
                 io - bi_io, bc_pct(io - bi_io, data - bi_data),
                 mem - (bi_oth - bi_io), bc_pct(mem - (bi_oth - bi_io), data - bi_data), wr - bi_w,
                 bc_pct(m1 - bi_m1, mem - (bi_oth - bi_io)), bc_pct(m2 - bi_m2, mem - (bi_oth - bi_io)),
                 bc_pct(m4 - bi_m4, mem - (bi_oth - bi_io)));
        bi_data = data; bi_oth = oth; bi_io = io; bi_w = wr; bi_m1 = m1; bi_m2 = m2; bi_m4 = m4;
        bi_from = trace_instrs;
    end

    task dump_bank_census;
        longint data, oth, mr, mw, mem, r1, r2, r4, w1, w2, w4, best;
        integer k, n, pick;
        bit taken [0:255];
        begin
            data = bc_cls[0][0] + bc_cls[0][1] + bc_cls[1][0] + bc_cls[1][1] + bc_cls[2][0] + bc_cls[2][1];
            oth  = bc_cls[2][0] + bc_cls[2][1];
            mr   = bc_cls[2][0] - bc_io[0];
            mw   = bc_cls[2][1] - bc_io[1];
            mem  = mr + mw;
            $display("    ---- the bank census: %0d data cycles predicted, of %0d cycles the core moved ----",
                     data, bc_cycles);
            $display("      ZERO   reads %0d writes %0d (%s%% of data cycles)", bc_cls[0][0], bc_cls[0][1],
                     bc_pct(bc_cls[0][0] + bc_cls[0][1], data));
            $display("      DBR    reads %0d writes %0d (%s%%)", bc_cls[1][0], bc_cls[1][1],
                     bc_pct(bc_cls[1][0] + bc_cls[1][1], data));
            $display("      OTHER  reads %0d writes %0d (%s%%)", bc_cls[2][0], bc_cls[2][1], bc_pct(oth, data));
            $display("        I/O, a pair bank's $Cxxx: reads %0d writes %0d (%s%%)", bc_io[0], bc_io[1],
                     bc_pct(bc_io[0] + bc_io[1], data));
            $display("        memory:                    reads %0d writes %0d (%s%%)", mr, mw, bc_pct(mem, data));
            if (mem > 0) begin
                $display("      OTHER memory by region: pair $00/$01/$E0/$E1 %0d, RAM $02-$7F %0d, ROM $FC-$FF %0d, elsewhere %0d",
                         bc_reg[0], bc_reg[1], bc_reg[2], bc_reg[3]);
                $display("      OTHER memory whose bank is anyway: zero %0d, the DBR %0d, the PBR %0d",
                         bc_eq0, bc_eqd, bc_eqp);
                r1 = bc_mru[0][0]; r2 = r1 + bc_mru[1][0]; r4 = r2 + bc_mru[2][0] + bc_mru[3][0];
                w1 = bc_mru[0][1]; w2 = w1 + bc_mru[1][1]; w4 = w2 + bc_mru[2][1] + bc_mru[3][1];
                $display("      OTHER memory bank in the last 1 / 2 / 4 distinct OTHER memory banks:");
                $display("        reads  %s / %s / %s %%", bc_pct(r1, mr), bc_pct(r2, mr), bc_pct(r4, mr));
                $display("        writes %s / %s / %s %%", bc_pct(w1, mw), bc_pct(w2, mw), bc_pct(w4, mw));
                $display("        all    %s / %s / %s %%", bc_pct(r1 + w1, mem), bc_pct(r2 + w2, mem),
                         bc_pct(r4 + w4, mem));
                for (k = 0; k < 256; k = k + 1) taken[k] = 0;
                $write("      OTHER memory by opcode:");
                for (n = 0; n < 12; n = n + 1) begin
                    best = 0; pick = -1;
                    for (k = 0; k < 256; k = k + 1) if (!taken[k] && bc_op[k] > best) begin best = bc_op[k]; pick = k; end
                    if (pick >= 0) begin taken[pick] = 1; $write(" $%02X:%s%%", pick[7:0], bc_pct(best, mem)); end
                end
                $display("");
                for (k = 0; k < 256; k = k + 1) taken[k] = 0;
                $write("      OTHER memory by bank:  ");
                for (n = 0; n < 12; n = n + 1) begin
                    best = 0; pick = -1;
                    for (k = 0; k < 256; k = k + 1) if (!taken[k] && bc_bank[k] > best) begin best = bc_bank[k]; pick = k; end
                    if (pick >= 0) begin taken[pick] = 1; $write(" $%02X:%s%%", pick[7:0], bc_pct(best, mem)); end
                end
                $display("");
            end
            begin : bc_card
                longint p0, p1, p23, pm, io;
                p0  = bc_mru[0][0] + bc_mru[0][1];
                p1  = bc_mru[1][0] + bc_mru[1][1];
                p23 = bc_mru[2][0] + bc_mru[2][1] + bc_mru[3][0] + bc_mru[3][1];
                pm  = bc_mru[4][0] + bc_mru[4][1];
                io  = bc_io[0] + bc_io[1];
                if (64'(u_bank_census.c_data) == data && 64'(u_bank_census.c_io) == io &&
                    64'(u_bank_census.c_mrd) == mr && 64'(u_bank_census.c_mwr) == mw &&
                    64'(u_bank_census.c_p0) == p0 && 64'(u_bank_census.c_p1) == p1 &&
                    64'(u_bank_census.c_p23) == p23 && 64'(u_bank_census.c_miss) == pm)
                    ok($sformatf("the card's bank census (rtl/bank_census.sv) agrees with the bench's: %0d data, %0d OTHER memory, %0d I/O",
                                 data, mem, io));
                else begin
                    fail("the card's bank census (rtl/bank_census.sv) disagrees with the bench's");
                    $display("      card:  data %0d mrd %0d mwr %0d io %0d p0 %0d p1 %0d p23 %0d miss %0d",
                             u_bank_census.c_data, u_bank_census.c_mrd, u_bank_census.c_mwr, u_bank_census.c_io,
                             u_bank_census.c_p0, u_bank_census.c_p1, u_bank_census.c_p23, u_bank_census.c_miss);
                    $display("      bench: data %0d mrd %0d mwr %0d io %0d p0 %0d p1 %0d p23 %0d miss %0d",
                             data, mr, mw, io, p0, p1, p23, pm);
                end
            end
        end
    endtask

    // ---- the host, mirrored off the driver's op stream ------------------------------
    // strudelworks-host src/hd_card.cpp, register for register.
    localparam [7:0] CMD_BLK_STATUS = 8'h00, CMD_BLK_READ = 8'h01, CMD_BLK_WRITE = 8'h02,
                     CMD_BLK_FORMAT = 8'h03, CMD_SP_STATUS = 8'h80, CMD_SP_READ = 8'h81,
                     CMD_SP_WRITE = 8'h82, CMD_SP_FORMAT = 8'h83, CMD_SP_BUSY = 8'hBF;
    localparam [7:0] ERR_OK = 8'h00, ERR_BADCTL = 8'h21, ERR_IO = 8'h27,
                     ERR_NOTCONN = 8'h28, ERR_NOWRITE = 8'h2B;
    localparam integer UNIT_NONE = -1, UNIT_CTL = -2;
    localparam integer NUM_DEVICES = 1;

    reg [7:0] himg [0:HDV_BLOCKS*512-1];

    reg [7:0]  hm_cmd, hm_unit_num, hm_fifo, hm_sc;
    // ---- the IIgs's SmartPort FIFO (firmware/hdc_smartport_gs.s) ---------
    // A DIFFERENT ROM, not a patched one, so a different command shape: the
    // //e's pushes seven bytes that map onto the registers above, and the
    // IIgs's pushes ELEVEN that do not, because an extended call's pointer
    // and block are wider than those registers.  Collected whole and decoded
    // at the end, exactly as the host's src/hd_card.cpp does it.
    reg [7:0]  hm_gs [0:15];
    reg [7:0]  hm_gsn;
    reg        hm_ext;
    reg [7:0]  hm_membank [0:8];
    reg        hm_armed;
    reg [15:0] hm_memblock [0:8];       // 8 = the controller's
    // THIRTY-TWO BITS, as src/hd_card.cpp's is.  An extended call's block
    // number is four bytes; keeping only three would read the wrong block
    // SILENTLY where the host keeps the fourth and the executor refuses.
    reg [31:0] hm_diskblock [0:8];
    reg [7:0]  hm_uerr [0:8];
    task hm_clear;
        integer k;
        begin
            hm_cmd = 0; hm_fifo = 0; hm_sc = 0; hm_armed = 0;
            hm_gsn = 0; hm_ext = 0;
            for (int gi = 0; gi <= 8; gi = gi + 1) hm_membank[gi] = 8'd0;
            hm_unit_num = {1'b0, 3'(HD_SLOT), 4'd0};        // slot << 4
            for (k = 0; k <= 8; k = k + 1) begin
                hm_memblock[k] = 0; hm_diskblock[k] = 0; hm_uerr[k] = 0;
            end
        end
    endtask

    function automatic integer hm_resolve;
        integer slot_from_unit, offset;
        begin
            if ((hm_cmd & 8'h80) == 0) begin
                slot_from_unit = (hm_unit_num >> 4) & 7;
                offset = (slot_from_unit == HD_SLOT) ? 0 : 2;
                hm_resolve = offset + (hm_unit_num >> 7);
            end else if (hm_unit_num > 8) hm_resolve = UNIT_NONE;
            else if (hm_unit_num > NUM_DEVICES) hm_resolve = UNIT_NONE;
            else if (hm_unit_num == 0) hm_resolve = UNIT_CTL;
            else hm_resolve = hm_unit_num - 1;
        end
    endfunction
    function automatic integer hm_ridx;      // unit_regs(): 8 = controller, -1 = none
        integer u;
        begin
            u = hm_resolve();
            if (u == UNIT_NONE) hm_ridx = -1;
            else if (u == UNIT_CTL) hm_ridx = 8;
            else hm_ridx = u;
        end
    endfunction

    task automatic hm_io_write(input [7:0] idx_in, input [7:0] d_in);
        integer r, depth;
        reg [7:0] idx, d;
        begin
            idx = idx_in; d = d_in;
            if (idx >= 8'h2 && idx <= 8'hA) hm_armed = 1;
            if (GS_HD_ROM && idx == 8'hA) begin
                hm_gs[hm_gsn[3:0]] = d;
                hm_gsn = hm_gsn + 8'd1;
                if (hm_gsn >= 8'd11) begin hm_gs_decode(); hm_gsn = 0; end
                r = -1;                       // handled: nothing else to do
            end else begin
            r = -2;                                          // -2: not needed
            if (idx != 8'h2 && idx != 8'h3 &&
                !((idx == 8'h9 || idx == 8'hA) && hm_fifo < 2)) begin
                r = hm_ridx();
                if (r < 0) begin
                    depth = (idx == 8'h9) ? 6 : 7;
                    hm_fifo = (hm_fifo + 1) % depth;
                end
            end
            if (r >= -2 && r != -1) begin
            if (idx == 8'h9 || idx == 8'hA) begin
                if (idx == 8'hA && hm_fifo == 0) d = d | 8'h80;
                depth = (idx == 8'h9) ? 6 : 7;
                idx = 8'h2 + hm_fifo;
                hm_fifo = (hm_fifo + 1) % depth;
            end
            case (idx)
                8'h2: hm_cmd = d;
                8'h3: hm_unit_num = d;
                8'h4: if (r >= 0) hm_memblock[r] = {hm_memblock[r][15:8], d};
                8'h5: if (r >= 0) hm_memblock[r] = {d, hm_memblock[r][7:0]};
                8'h6: begin
                    if (hm_cmd != CMD_SP_STATUS) begin
                        if (r >= 0) hm_diskblock[r] = {hm_diskblock[r][31:8], d};
                    end else hm_sc = d;
                end
                8'h7: if (r >= 0) hm_diskblock[r] = {hm_diskblock[r][31:16], d, hm_diskblock[r][7:0]};
                8'h8: if ((hm_cmd & 8'h80) != 0 && r >= 0)
                          hm_diskblock[r] = {8'd0, d, hm_diskblock[r][15:0]};
                default: ;
            endcase
            if (r >= 0 && (hm_cmd & 8'h80) == 0) hm_diskblock[r] = hm_diskblock[r] & 32'h0000FFFF;
            end
            end
        end
    endtask

    // The eleven bytes, decoded.  The host's gs_decode(), same order:
    //   0 command (bit 6 = extended, the card's $80 marks it SmartPort)
    //   1 the parameter count   2 the unit
    //   3.. the buffer pointer, then the block number or the status code
    task automatic hm_gs_decode;
        integer r;
        reg [7:0] pb;
        begin
            // BIT 6 COMES OFF HERE, and is kept beside the command rather
            // than in it - src/hd_card.cpp gs_decode(), the same words.  The
            // executor dispatches on the command as a whole (CMD_SP_READ is
            // $81, not $C1), so an extended call carrying its marker any
            // further fell through to default and answered I/O ERROR.  This
            // model had the bug the host was fixed for in rung 7b, which is
            // why it never saw one.
            hm_cmd      = (hm_gs[0] & 8'h3F) | 8'h80;
            hm_ext      = (hm_gs[0] & 8'h40) != 0;
            hm_unit_num = hm_gs[2];
            r = hm_resolve();
            if (r == UNIT_CTL) r = 8;
            if (r >= 0) begin
                hm_memblock[r] = {hm_gs[4], hm_gs[3]};
                hm_membank[r]  = hm_ext ? hm_gs[5] : 8'd0;
                pb             = hm_ext ? 8'd7 : 8'd5;   // where the block starts
                if ((hm_gs[0] & 8'h3F) == 8'h00) hm_sc = hm_gs[pb];
                hm_diskblock[r] = hm_ext
                    ? {hm_gs[pb+3], hm_gs[pb+2], hm_gs[pb+1], hm_gs[pb]}
                    : {8'd0, hm_gs[pb+2], hm_gs[pb+1], hm_gs[pb]};
            end
        end
    endtask

    // The command queue an EXECUTE snapshots into.  A write command's block
    // is captured HERE, from the reference through the read map - the real
    // host reads its program-order mirror at the EXECUTE's place in the
    // stream (src/pipeline.cpp), and never asks the card.
    localparam integer QN = 64;
    reg [7:0]  q_cmd [0:QN-1];
    reg [7:0]  q_unum [0:QN-1];
    integer    q_unit [0:QN-1];
    reg [7:0]  q_sc [0:QN-1];
    // EXTENDED and the buffer's BANK travel with the command, as HdCommand's
    // `extended` and `membank` do.  Neither can be read off the command byte
    // any more: bit 6 comes off at decode, and a plain call has no bank.
    reg        q_ext [0:QN-1];
    reg [7:0]  q_bank [0:QN-1];
    reg [15:0] q_mem [0:QN-1];
    reg [31:0] q_disk [0:QN-1];
    integer    q_at [0:QN-1];
    reg [7:0]  q_blk [0:QN-1][0:511];
    integer    qw = 0, qr = 0;
    integer    host_execs = 0, host_reads = 0, host_writes = 0, host_statuses = 0;
    // The block most recently DMA'd in, waiting to be checked: see the
    // EXECUTE below and the checker under card_byte.
    reg        pend_valid = 1'b0, chk_go = 1'b0;
    reg [15:0] pend_addr = 16'd0;
    reg [7:0]  pend_bank = 8'd0;
    // The language card's state AS THE BLOCK LANDED: $D000-$DFFF folds onto
    // physical $Cx in bank 1 of the card (apple_mmu "if (fold) pg = {4'hC,
    // va[11:8]}"), and altzp puts the whole region in the aux bank - so where
    // the machine will look for a block DMA'd into the LC is not its virtual
    // address.  Captured here because the switches may move before the check.
    reg        pend_b2 = 1'b0, pend_azp = 1'b0;
    // ...and whether the MACHINE wrote into the block before the check got
    // to it.  While the boot is a read-then-jump the block is still the
    // host's when the next command goes out; once an operating system is
    // running it reads a block into a buffer, WORKS ON IT, and only then
    // asks for the next thing.  A block the machine has written is not
    // evidence about the DMA either way, so it is skipped and counted.
    reg        pend_dirty = 1'b0;
    integer    blocks_touched = 0;
    // ...and a write the DATA FRONT retired into it (rtl/dline.sv's posted
    // path, rung 6): it never reaches the dispatcher, so the u_* watch below
    // cannot see it.  Before the fronts, every write was a dispatcher op.
    reg        pend_dirty_dl = 1'b0;
    integer    blocks_touched_dl = 0;
    integer    pend_blk = 0, blocks_verified = 0;

    task automatic hm_io_read0;
        integer u, r, k;
        begin
            if (hm_armed) begin                             // else: a poll
                hm_armed = 0;
                // The block the LAST command brought in, checked now: the
                // machine has finished with it and is asking for the next
                // thing, so it is still where the host put it.  Checking at
                // the end of the run instead only worked while the boot
                // stalled - a boot that gets going relocates over $0800.
                if (pend_valid) chk_go = 1;
                host_execs = host_execs + 1;
                u = hm_resolve();
                $display("    disk: EXEC cmd $%02X unit $%02X -> resolved %0d at instruction %0d",
                         hm_cmd, hm_unit_num, u, trace_instrs);
                q_cmd[qw % QN] = hm_cmd; q_unum[qw % QN] = hm_unit_num;
                q_ext[qw % QN] = hm_ext;
                q_unit[qw % QN] = u; q_sc[qw % QN] = hm_sc; q_at[qw % QN] = now;
                if (u != UNIT_NONE) begin
                    r = (u == UNIT_CTL) ? 8 : u;
                    q_mem[qw % QN] = hm_memblock[r];
                    q_bank[qw % QN] = hm_membank[r];
                    q_disk[qw % QN] = hm_diskblock[r];
                    // A BLOCK WRITE takes its block HERE, at the EXECUTE, from
                    // the card's own memory where the machine left it - the
                    // way the host takes it from its mirror - through the
                    // same translation the landing check reads with.  The
                    // queue's write arm puts it into the image when the host
                    // gets to it.  Until 2026-09-13 this only failed loudly:
                    // q_blk was never filled, so a GS/OS write put a block of
                    // nothing into the image and every run past ~9.9 M
                    // instructions read it back.  A write captured while the
                    // data front still has posted writes in flight is named,
                    // because those bytes may not be in the card's memory yet.
                    if (hm_cmd == CMD_BLK_WRITE || hm_cmd == CMD_SP_WRITE) begin
                        for (k = 0; k < 512; k = k + 1)
                            q_blk[qw % QN][k] = blk_card_byte(hm_membank[r], hm_memblock[r], k,
                                                              sw_state[8], sw_state[3]);
                        if (u_dline.pending)
                            $display("    disk: WRITE of block %0d captured with posted writes in flight at instruction %0d",
                                     hm_diskblock[r], trace_instrs);
                    end
                    hm_cmd = (hm_cmd & 8'h80) ? CMD_SP_BUSY : CMD_BLK_STATUS;
                    hm_fifo = 0;
                    hm_gsn = 0;
                    hm_ext = 0;                 // ...as the host clears gs_ext_
                end
                qw = qw + 1;
            end
        end
    endtask

    // The mirror taps the peripherals' view of the stream - the driver's
    // ops, and the on-card slot ops served fast in the closed regime - as
    // the real host taps the capture (bus words and fast words alike).
    always @(posedge clk) begin
        if (op_present && !op_ovr && !op_rw && op_addr[15:4] == {8'hC0, 4'h8 + 4'(HD_SLOT)})
            hm_io_write(op_addr[3:0], op_wdata);
        if (op_commit && !op_ovr && op_rw && op_addr[15:4] == {8'hC0, 4'h8 + 4'(HD_SLOT)})
            if (op_addr[3:0] == 4'h0) hm_io_read0();
    end
    // ---- rung 3e: the block number, byte by byte, on its way to the card ----------
    // The third read asks for block $0203 where it means $0003, so the two
    // places the high byte can go wrong are named here: what the DRIVER wrote
    // into the card's registers, and what the boot block had in $46/$47 for
    // the driver to read.  Both with the PC that did it.  DISK_TRACE turns
    // them on from the first EXECUTE, which is where the interesting window
    // starts and keeps the ROM's own scan out of the log.
    always @(posedge clk) if (DISK_TRACE != 0 && host_execs > 0) begin
        if (op_present && !op_ovr && !op_rw &&
            op_addr[15:4] == {8'hC0, 4'h8 + 4'(HD_SLOT)})
            $display("    reg: $%04X <= $%02X from %02X/%04X at instruction %0d",
                     op_addr, op_wdata, last_sync[23:16], last_sync[15:0], trace_instrs);
        if (u_present && !u_rw && u_bank == 8'h00 &&
            u_addr >= 16'h0040 && u_addr <= 16'h0047)
            $display("    zp:  $%04X <= $%02X from %02X/%04X at instruction %0d",
                     u_addr, u_wdata, last_sync[23:16], last_sync[15:0], trace_instrs);
    end

    // The window the divergence index names, cycle by cycle.
    always @(posedge clk)
        if (WATCH_TO != 0 && cpu_cyc_en &&
            trace_instrs >= WATCH_FROM && trace_instrs <= WATCH_TO)
            $display("    cyc %0d: %06X rw=%0d vda=%0d vpa=%0d sync=%0d din=$%02X dout=$%02X (pc %02X/%04X)",
                     trace_instrs, cpu_a24, cpu_rw, cpu_vda, cpu_vpa, cpu_sync,
                     cpu_din, cpu_dout, last_sync[23:16], last_sync[15:0]);

    // The page-cache engine's history for the ROM's pages: every miss that
    // names one as the page being filled or as the victim, with the way, the
    // set and whether the victim was believed dirty.  There are only a
    // hundred-odd in a run, so all of them fit, and the pair of lines that
    // name the SAME page as victim twice is what found rung 3e's second bug.
    reg [3:0] eng_prev = 4'd15;
    always @(posedge clk) if (ENG_TRACE != 0) begin
        eng_prev <= u_cache.state;
        if (u_cache.state != eng_prev && eng_prev == u_cache.E_IDLE &&
            (u_cache.e_ppn >= 16'hFC00 || u_cache.e_old >= 16'hFC00 ||
             (PAGE_WATCH != 0 && (u_cache.e_ppn == PAGE_WATCH[15:0] ||
                                  u_cache.e_old == PAGE_WATCH[15:0]))))
            $display("    eng %0d: fill ppn $%04X crit line %0d, victim $%04X %0s, set %0d way %02X, %0s",
                     now, u_cache.e_ppn, u_cache.e_crit, u_cache.e_old,
                     u_cache.e_dirty ? "DIRTY" : "clean",
                     u_cache.e_set, u_cache.e_way,
                     u_cache.e_rw ? "read" : "write");
    end

    // The cache's own clash counter, which nothing has ever looked at: it
    // counts a cl_* arriving whose page is NOT the one the P1 stage read the
    // directory for.  A shadow duplicate is exactly that - apple_mmu sets
    // cl_valid for it, but page_cache's e_any (op_present | pw_take | il_ack)
    // has no term for it, so no P0 ever runs and the compare, the victim and
    // the landing row all belong to whatever op went before.
    // THE TEXT SCREEN, out of the card's own memory - the same habit as the
    // host's `screen`: ask the machine what it decided, never guess.  Main
    // text page 1, the Apple II's interleave, high ASCII folded down.
    task dump_text;
        integer row, col, base;
        reg [7:0] b;
        string    line;
        begin
            $display("    ---- the text screen (main page 1) ----");
            for (row = 0; row < 24; row = row + 1) begin
                base = 16'h0400 + (row % 8) * 16'h80 + (row / 8) * 16'h28;
                line = "";
                for (col = 0; col < 40; col = col + 1) begin
                    b = card_byte({8'd0, 8'((base + col) >> 8)}, 8'(base + col));
                    b = b & 8'h7F;
                    if (b < 8'h20) b = b + 8'h40;
                    line = {line, string'(b)};
                end
                $display("      |%0s|", line);
            end
        end
    endtask

    task dump_iwm;
        begin
            $display("    the IWM at the end: motor %0d enable2 %0d q6 %0d q7 %0d phases %04b mode %02b%03b apple35 %0d",
                     u_gsio.u_iwm.motor_on, u_gsio.u_iwm.enable2,
                     u_gsio.u_iwm.q6, u_gsio.u_iwm.q7, u_gsio.u_iwm.phases,
                     u_gsio.u_iwm.mode[4:3], u_gsio.u_iwm.mode[2:0],
                     u_gsio.u_iwm.apple35_sel);
            $display("    data reads served from a disk: %0d from the 3.5\" drive, %0d from a 5.25\" drive",
                     u_gsio.u_iwm.rd35, u_gsio.u_iwm.rd525);
            if (HAS_FD525)
                $display("    the 5.25\" drives: %0d seeks, %0d fills, heads at half-track %0d / %0d",
                         fd525_seeks, fd525_fills, u_gsio.u_iwm.ph5[0], u_gsio.u_iwm.ph5[1]);
            if (HAS_FD525)
                $display("    the 5.25\" writes: %0d bytes loaded, %0d bits written, %0d tracks sent home, %0d FD_DIRTY chunks taken",
                         u_gsio.u_iwm.ld525, u_gsio.u_iwm.wr525, u_gsio.u_iwm.up525, fd525_dirty_chunks);
        end
    endtask
    // The Ensoniq's state (rtl/gs_doc.sv, docs/GS.md rung 7): which
    // oscillators the machine left running, how they are configured, and how
    // busy the interrupt queue is.  A pair handing back and forth over dead
    // wave tables, or a queue that never empties, shows here.
    integer dj;
    // Rising edges of the chipset's interrupt line: how many times the machine
    // was actually asked.
    integer irqs_taken = 0;
    reg     irq_q = 1'b0;
    integer last_rise = 0;          // the instruction the line last went up at
    integer last_fall = 0;          // ...and last came down at
    integer c047_n = 0, last_c047 = 0;   // the acknowledge, and when it last happened
    always @(posedge clk) begin
        if (gsio_irq && !irq_q) begin
            irqs_taken = irqs_taken + 1;
            last_rise  = trace_instrs;
        end
        if (!gsio_irq && irq_q) last_fall = trace_instrs;
        irq_q <= gsio_irq;
        // $C047 is the acknowledge: a read or a write drops the Mega II's
        // two timer interrupts.  It is an internalized op, so it is watched
        // on the retire the chipset sees.
        if (swi_commit && (u_addr[7:0] == 8'h47) &&
            ((u_bank == 8'h00) || (u_bank == 8'h01) ||
             (u_bank == 8'hE0) || (u_bank == 8'hE1))) begin
            c047_n = c047_n + 1;
            last_c047 = trace_instrs;
        end
    end
    // WHAT THE CHIP ACTUALLY PUTS OUT.  Every check the DOC's own bench makes
    // reads a register back, so the output pair was never watched by anything
    // - and the card played silence on hardware for a boot in which twelve
    // oscillators were running (docs/GS.md rung 7, 2026-09-13).  A peak either
    // side of zero, and a count of the clocks the mix was not zero, says
    // whether the engine is producing a waveform at all.
    integer doc_pk_l = 0, doc_pk_r = 0, doc_mn_l = 0, doc_mn_r = 0;
    integer doc_nz = 0;
    always @(posedge clk) begin
        if (u_gsio.u_doc.snd_l > doc_pk_l) doc_pk_l = u_gsio.u_doc.snd_l;
        if (u_gsio.u_doc.snd_r > doc_pk_r) doc_pk_r = u_gsio.u_doc.snd_r;
        if (u_gsio.u_doc.snd_l < doc_mn_l) doc_mn_l = u_gsio.u_doc.snd_l;
        if (u_gsio.u_doc.snd_r < doc_mn_r) doc_mn_r = u_gsio.u_doc.snd_r;
        if ((u_gsio.u_doc.snd_l != 0) || (u_gsio.u_doc.snd_r != 0))
            doc_nz = doc_nz + 1;
    end

    // EVERY $C03C-$C03F OP THE MACHINE RETIRED, AGAINST EVERY ONE THE CHIP WAS
    // HANDED.  gs_io's `act` is `swi_commit && mine`, and swi_commit fires only
    // for the soft-switch internalization path - so an op served by some other
    // fast path is a write the Ensoniq never sees.  The two counts differing is
    // the whole question; the control-register writes are logged because a
    // register write that does not start an oscillator is the symptom.
    integer doc_ops_u = 0, doc_ops_act = 0, doc_ctlw = 0, doc_starts = 0;
    wire doc_pair_b = (u_bank == 8'h00) || (u_bank == 8'h01) ||
                      (u_bank == 8'hE0) || (u_bank == 8'hE1);
    wire doc_addr_b = (u_addr[15:8] == 8'hC0) && (u_addr[7:2] == 6'b001111);
    always @(posedge clk) begin
        if (u_commit   && doc_pair_b && doc_addr_b) doc_ops_u   = doc_ops_u + 1;
        if (swi_commit && doc_pair_b && doc_addr_b) doc_ops_act = doc_ops_act + 1;
        if (swi_commit && doc_pair_b && (u_addr[7:0] == 8'h3D) && !u_rw &&
            !u_gsio.u_doc.sound_ctl[6] && (u_gsio.u_doc.ptr[7:5] == 3'd5)) begin
            doc_ctlw = doc_ctlw + 1;
            // Only the writes that CLEAR the halt bit are starts, and those are
            // the ones in question - the ROM's init halts all 32 at boot and
            // would otherwise fill the log.
            if (!u_wdata[0]) begin
                doc_starts = doc_starts + 1;
                if (doc_starts <= 24)
                    $display("      DOC START #%0d at instr %0d: osc %0d <= $%02x (was $%02x), osc_en %0d",
                             doc_starts, trace_instrs, u_gsio.u_doc.ptr[4:0], u_wdata,
                             u_gsio.u_doc.ctl[u_gsio.u_doc.ptr[4:0]], u_gsio.u_doc.osc_en);
            end
        end
    end

    task dump_doc;
        begin
            $display("    the Ensoniq OPS: %0d retired to $C03C-$C03F, %0d handed to the chip, %0d control writes, %0d of them starts",
                     doc_ops_u, doc_ops_act, doc_ctlw, doc_starts);
            $display("    the Ensoniq OUT: L %0d..%0d  R %0d..%0d, nonzero on %0d clocks",
                     doc_mn_l, doc_pk_l, doc_mn_r, doc_pk_r, doc_nz);
            $display("    the Ensoniq: osc_en %0d, ends %0d, irqs %0d, queue %0d, irq %0d, ctl $C03C=%02x",
                     u_gsio.u_doc.osc_en, u_gsio.u_doc.cnt_ends,
                     u_gsio.u_doc.cnt_irqs, u_gsio.u_doc.q_n,
                     u_gsio.u_doc.irq, u_gsio.u_doc.sound_ctl);
            for (dj = 0; dj < 32; dj = dj + 1)
                if (u_gsio.u_doc.running[dj] || !u_gsio.u_doc.ctl[dj][0])
                    $display("      osc %2d RUNNING=%0d ctl=%02x (halt %0d mode %0d int %0d chan %0d) freq=%04x vol=%02x wptr=%02x wsize=%02x",
                             dj, u_gsio.u_doc.running[dj], u_gsio.u_doc.ctl[dj],
                             u_gsio.u_doc.ctl[dj][0], u_gsio.u_doc.ctl[dj][2:1],
                             u_gsio.u_doc.ctl[dj][3], u_gsio.u_doc.ctl[dj][7:4],
                             u_gsio.u_doc.freq[dj], u_gsio.u_doc.vol[dj],
                             u_gsio.u_doc.wptr[dj], u_gsio.u_doc.wsize[dj]);
        end
    endtask
    // The interrupt controller's state (rtl/gs_intc.sv).  A machine spinning
    // on a RAM flag that a handler is supposed to set wants this: which
    // sources are pending, which are ENABLED, and whether the line into the
    // core has ever gone up.
    // Every read of the IWM's status register, with the multiplexer index the
    // phase lines and $C031 selected: which sense line the ROM is asking for.
    always @(posedge clk) begin
        if (swi_commit && u_rw && (u_addr[15:0] == 16'hC0EE) && (n_iwmstat < 12)) begin
            $display("    IWM status read #%0d at instruction %0d: stat35 =$%01X -> sense %0d, motor %0d, apple35 %0d, phases %04b",
                     n_iwmstat, trace_instrs, u_gsio.u_iwm.stat35,
                     u_gsio.u_iwm.status35, u_gsio.u_iwm.motor_on,
                     u_gsio.u_iwm.apple35_sel, u_gsio.u_iwm.phases);
            n_iwmstat = n_iwmstat + 1;
        end
    end
    integer n_iwmstat = 0;

    task dump_intc;
        begin
            $display("    the interrupt controller: irq %0d, taken %0d; $C041=%02x $C023=%02x $C046=%02x; pending vbl %0d .25s %0d 1s %0d scan %0d; adb %0d doc %0d",
                     u_gsio.u_intc.irq, irqs_taken,
                     u_gsio.u_intc.c041, u_gsio.u_intc.c023, u_gsio.u_intc.c046,
                     u_gsio.u_intc.p_vbl, u_gsio.u_intc.p_25sec,
                     u_gsio.u_intc.p_1sec, u_gsio.u_intc.p_scan,
                     u_gsio.u_intc.irq_adb, u_gsio.u_intc.irq_doc);
            $display("    ...the line last went UP at instruction %0d and last came DOWN at %0d; $C047 acknowledged %0d times, last at %0d",
                     last_rise, last_fall, c047_n, last_c047);
        end
    endtask
    // THE STACK RUNAWAY WATCHDOG (2026-09-13).  On hardware the demo's second
    // page - the menu after the mouse click - ends with the machine writing
    // page one 25,416 times and READING IT NOT ONCE, the stack marching down
    // and rolling over twenty-three times, while the Ensoniq still plays and
    // only a handful of code addresses ever execute.  Pushes with no pulls.
    // The question is what keeps re-entering, and the answer is two numbers
    // that only exist in here: which interrupt source is pending, and how deep
    // the Ensoniq's interrupt queue is.  `irq_doc` is a LEVEL with no enable
    // and no INTFLAG bit - faithful to KEGS, which has neither - asserted
    // while that queue is not empty and cleared only by a read of DOC register
    // $E0, so ONE unserviced sound interrupt holds the line high for ever.
    //
    // Firing here rather than at the end of the run is the point: the state
    // wanted is the state AT the failure, and a run long enough to reach it is
    // an hour of simulation that must not also be spent guessing where to look.
    // THE TRIGGER IS THE STACK POINTER WRAPPING, not a count of writes: the
    // ROM's own memory clear writes page one thousands of times and reads it
    // never, and a count caught that at instruction 0 the first time this was
    // tried.  A stack that UNDERFLOWS - pushed past $0100 and round to $01FF -
    // three times over is a runaway and nothing else; on hardware it went
    // round twenty-three times.
    // ...and it must be a wrap caused by PUSHING - the stack stepping down off
    // $0100 and round to $01FF - not the stack pointer being LOADED.  At reset
    // the core sets S to $01FF, and a low-to-high test called that a wrap and
    // fired at instruction 0 the second time this was tried.  Requiring the
    // old and new values to sit within a push's width of the two ends makes it
    // a decrement and nothing else.  Armed only once the demo is past the
    // click, because the ROM's startup moves the stack about freely.
    logic [15:0] s_prev = 16'h01FF;
    integer s_wraps = 0;
    integer runaway = 0;
    wire armed = (trace_instrs > 6000000);
    always @(posedge clk) begin
        if (armed && (s_prev[15:8] == 8'h01) && (u_cpu.s[15:8] == 8'h01) &&
            (s_prev[7:0] <= 8'h03) && (u_cpu.s[7:0] >= 8'hFC))
            s_wraps = s_wraps + 1;
        s_prev <= u_cpu.s;
        if (!runaway && (s_wraps >= 3)) begin
            runaway = 1;
            $display("");
            $display("== STACK RUNAWAY at instruction %0d: the stack has wrapped %0d times",
                     trace_instrs, s_wraps);
            $display("    the CPU: PC $%02x/%04x  S $%04x  P $%02x  E %0d",
                     u_cpu.pbr, u_cpu.pc, u_cpu.s,
                     {u_cpu.f_n, u_cpu.f_v, u_cpu.f_m, u_cpu.f_x,
                      u_cpu.f_d, u_cpu.f_i, u_cpu.f_z, u_cpu.f_c}, u_cpu.f_e);
            dump_intc();
            dump_doc();
            $display("== end of the runaway report");
            $display("");
            $finish;
        end
    end

    task dump_clash;
        begin
            $display("    the cache's clash counters: ppn_clash %0d, land_clash %0d, posted %0d, posted_miss %0d",
                     u_cache.cnt_ppn_clash, u_cache.cnt_land_clash,
                     u_cache.cnt_posted, u_cache.cnt_posted_miss);
            $display("    the map's shadow duplicates: %0d taken, %0d dropped", shd_taken, shd_drops);
        end
    endtask
    integer shd_taken = 0;
    always @(posedge clk) if (u_mmu.shd_take) shd_taken = shd_taken + 1;

    // THE ROM, HELD TO THE IMAGE THE HOST SENT.  Banks $FC-$FF ARE the ROM
    // on a IIgs - there is nothing else they can be - so every byte the core
    // reads from one must be the byte in the file, and a memory path that
    // ever answers otherwise has lost it.  Cheap, and it names the fetch
    // rather than the instruction that fell over three cycles later.
    integer rom_bad = 0, rom_bad_first = -1;
    reg [23:0] rom_bad_at = 24'd0;
    reg [7:0]  rom_bad_got = 8'd0, rom_bad_want = 8'd0;
    always @(posedge clk)
        if (boot_go && cpu_cyc_en && cpu_rw && (cpu_vda || cpu_vpa) &&
            cpu_bank >= 8'hFC) begin
            if (cpu_din !== rom_img[{cpu_bank - 8'hFC, cpu_addr}]) begin
                rom_bad = rom_bad + 1;
                if (rom_bad_first < 0) begin
                    rom_bad_first = trace_instrs;
                    rom_bad_at   = cpu_a24;
                    rom_bad_got  = cpu_din;
                    rom_bad_want = rom_img[{cpu_bank - 8'hFC, cpu_addr}];
                end
            end
        end

    // THE INVARIANT, COUNTED.  How many cycles the park above took out of
    // the machine's reach, and how many of those would have been a WRITE or
    // a STROBE of an I/O register - the two that each cost this bench a
    // boot, and neither of which any instruction in the code asks for.
    integer internal_cycles = 0, internal_writes = 0, internal_io = 0;
    wire internal_pair = (cpu_bank == 8'h00) || (cpu_bank == 8'h01) ||
                         (cpu_bank == 8'hE0) || (cpu_bank == 8'hE1);
    // A BLOCKED ENTRANT, named: an op or a posted write that reached the
    // cache's decision while the engine ran (docs/GS.md rung 6, the slow
    // DDR3 model).  The design says none can; the count says otherwise.
    always @(posedge clk) if (u_cache.dec_block && !u_cache.iv_run)
        $display("    BLOCKED at %0d clocks: %s %s ppn $%04X off $%02X (posted %0d, cls %0d) - engine state %0d filling ppn $%04X, hit %0d; last sync %02x/%04x",
                 $time / 10, u_cache.s_rw ? "read" : "write", u_cache.s_posted ? "posted" : "op",
                 u_cache.s_ppn, u_cache.s_off, u_cache.s_posted, u_cache.s_cls,
                 u_cache.state, u_cache.e_ppn, u_cache.s_hit, last_sync[23:16], last_sync[15:0]);
    always @(posedge clk) if (boot_go && cpu_cyc_en && cyc_internal) begin
        internal_cycles = internal_cycles + 1;
        if (!cpu_rw) internal_writes = internal_writes + 1;
        if (internal_pair && cpu_addr[15:8] == 8'hC0) internal_io = internal_io + 1;
        if (DISK_TRACE != 0 && internal_cycles <= 4)
            $display("    parked an internal cycle: %06X rw=%0d (pc %02X/%04X)",
                     cpu_a24, cpu_rw, last_sync[23:16], last_sync[15:0]);
    end

    // ---- the op stream, as the host's mirror takes it -------------------------------
    // proto::encode_event's own layout (the host's protocol.hpp), so a
    // replay needs no translation:
    //   lo = {tag[3:0], bank[7:0], vbl, sync, res, rw, addr[15:0]}
    //   hi = {data[7:0], cls[3:0], cpu[3:0], 16'd0}
    // Every retired op goes down as an EVENT - the mirror applies fast and
    // bus ops the same way, and a replay wants them all, in order.  `res` is
    // HIGH for a machine that is not being held: reset_asserted() is its
    // complement.  The override's own DMA is not the machine's op and is
    // left out, as it is everywhere else in this bench.
    // TAPPED AT THE CORE, not at the dispatcher: a read's BYTE is only known
    // when the core takes it, and the mirror learns memory from reads as
    // well as writes - it is a mirror, not a write log.  So this is every
    // cycle the core actually accesses something, in order, with the byte it
    // moved: cpu_din on a read, cpu_dout on a write.  Internal cycles are
    // not accesses and are not here (docs/GS.md rung 3e).
    integer opsf = 0, ops_written = 0;
    initial if (OPSF != "") opsf = $fopen(OPSF, "wb");
    wire [31:0] op_lo_w = {4'hF, cpu_bank, 1'b0, cpu_sync, 1'b1, cpu_rw, cpu_addr};
    wire [31:0] op_hi_w = {cpu_rw ? cpu_din : cpu_dout, 4'd0, 4'd0, 16'd0};
    // ...AND THE HOST'S OWN DMA.  A block the card DMAs in never goes near
    // the core, so the core's cycles do not carry it - but it is a write to
    // the machine's memory like any other, it goes through the map, and it
    // SHADOWS like any other.  On real hardware the host does the DMA itself
    // and its mirror knows; a replay has to be told.  Emitted from the same
    // block so the order is the one the machine saw.
    wire [31:0] dma_lo_w = {4'hF, u_bank, 1'b0, 1'b0, 1'b1, 1'b0, u_addr};
    wire [31:0] dma_hi_w = {u_wdata, 4'd0, 4'd0, 16'd0};
    always @(posedge clk) if (opsf != 0 && boot_go) begin
        if (cpu_cyc_en && !cyc_internal) begin
            $fwrite(opsf, "%u%u", op_lo_w, op_hi_w);
            ops_written = ops_written + 1;
        end
        if (u_present && u_ovr && !u_rw) begin
            $fwrite(opsf, "%u%u", dma_lo_w, dma_hi_w);
            ops_written = ops_written + 1;
        end
    end

    // The physical pages the machine wrote, so the replay has something to be
    // held to.  Taken from the CLASSIFIED op - the map's own answer for where
    // the byte landed - and not from the virtual address, which is the whole
    // question the mirror is being asked.
    reg     pg_dirty [0:65535];
    integer pgi, pages_dirty = 0;
    initial for (pgi = 0; pgi < 65536; pgi = pgi + 1) pg_dirty[pgi] = 1'b0;
    // ...and WHICH BYTES of it, because a byte the stream never wrote has no
    // agreed value: the mirror starts at zero and the card's cache starts at
    // whatever its way was left holding.  Comparing those compares two
    // arbitrary choices.  32 bytes of mask a page, one bit a byte.
    reg [255:0] pg_mask [0:65535];
    initial for (pgi = 0; pgi < 65536; pgi = pgi + 1) pg_mask[pgi] = 256'd0;
    integer pw_shown = 0, pw_writes = 0;
    reg [7:0] pw_lowest = 8'hFF;
    always @(posedge clk)
        if (PAGE_WATCH != 0 && boot_go && cl_valid && !cl_rw && cl_wr_image &&
            cl_ppn_w == PAGE_WATCH[15:0]) begin
            pw_writes = pw_writes + 1;
            if (cl_off[7:0] < pw_lowest) pw_lowest = cl_off[7:0];
        end
    always @(posedge clk)
        if (PAGE_WATCH != 0 && boot_go && cl_valid && !cl_rw && cl_wr_image &&
            cl_ppn_w == PAGE_WATCH[15:0] && cl_off[7:0] < 8'h70 && pw_shown < 8) begin
            pw_shown = pw_shown + 1;
            $display("    page $%04X <= $%02X at offset $%02X, %0d clocks; the op is %02X/%04X %0s",
                     cl_ppn_w, cl_wdata, cl_off[7:0], now, u_bank, u_addr,
                     u_rw ? "read" : "write");
        end
    always @(posedge clk)
        if (boot_go && cl_valid && !cl_rw && cl_wr_image && !pg_dirty[cl_ppn_w]) begin
            pg_dirty[cl_ppn_w] = 1'b1;
            pages_dirty = pages_dirty + 1;
        end
    always @(posedge clk)
        if (boot_go && cl_valid && !cl_rw && cl_wr_image)
            pg_mask[cl_ppn_w][cl_off[7:0]] = 1'b1;
    // THE SAME MASK FROM POWER-UP, for the rung 4c audit alone.  pg_mask
    // starts at boot_go because the mirror's op stream does - but the CORE
    // DOES NOT: it leaves reset before the ROM is loaded, executes zeros,
    // BRKs through a zero vector and wraps the stack round page one until the
    // bench pulls reset.  Those pushes are real writes the cache rightly
    // keeps, and a mask that begins later calls them "never written".  That is
    // the whole of the "previous tenant's bytes" the mirror replay reported.
    reg [255:0] wr_ever [0:65535];
    initial for (pgi = 0; pgi < 65536; pgi = pgi + 1) wr_ever[pgi] = 256'd0;
    always @(posedge clk)
        if (cl_valid && !cl_rw && cl_wr_image)
            wr_ever[cl_ppn_w][cl_off[7:0]] = 1'b1;
    // ...and for text page 1 of main memory (physical pages $0004-$0007),
    // whether the LAST write to each byte OWED a copy in $E0: text shadowing
    // on (SHADOW[0] clear) as it landed.  SHADOW cannot move while posted
    // writes are pending (a map change waits for the drain), so the state at
    // the landing is the state at the write.  A program that switches the
    // text shadow off and writes the page owes nothing, and the end-of-run
    // check below must not call that a missing duplicate.
    // THE ONE BYTE ARKANOID'S SHADOW CHECK FAILS ON (2026-09-13): every landing
    // in main $07F7 and in $E0/07F7, as the classified stream carries it -
    // the op's own write, a posted write draining, or a shadow duplicate - so
    // a duplicate that is lost or lands out of order shows as a gap.
    always @(posedge clk)
        if (boot_go && cl_valid && !cl_rw && cl_wr_image && (cl_off[7:0] == 8'hF7) &&
            (cl_ppn_w == 16'h0007 || cl_ppn_w == 16'hE007))
            $display("    BYTE WATCH %0d clk %0d instr: $%04X%02X <= $%02X  posted=%0d sh=%0d  op %02X/%04X %0s SHADOW=$%02X pending=%0d",
                     now, trace_instrs, cl_ppn_w, cl_off[7:0], cl_wdata, cl_posted, cl_sh,
                     u_bank, u_addr, u_rw ? "rd" : "wr", gs_shadow_w, u_dline.pending);
    reg [255:0] wr_text_sh [0:3];
    initial for (pgi = 0; pgi < 4; pgi = pgi + 1) wr_text_sh[pgi] = 256'd0;
    always @(posedge clk)
        if (cl_valid && !cl_rw && cl_wr_image && (cl_ppn_w[15:2] == 14'd1))
            wr_text_sh[cl_ppn_w[1:0]][cl_off[7:0]] = !gs_shadow_w[0];
    // ...and a DIRECT write into $E0's text page (a program addressing the
    // Mega II bank itself, not a duplicate - duplicates are posted, from the
    // data front and from the map alike) supersedes the copy: Arkanoid writes
    // $E0/07F7 itself long after the $00 byte's duplicate landed, and $00 and
    // $E0 then rightly differ.
    always @(posedge clk)
        if (cl_valid && !cl_rw && cl_wr_image && !cl_posted && (cl_ppn_w[15:2] == 14'h3801))
            wr_text_sh[cl_ppn_w[1:0]][cl_off[7:0]] = 1'b0;

    // ---- THE COUT VECTOR: who writes $36/$37, and from where -----------------
    // GS/OS's COUT jumped through a zero $36/$37 after 1,431 good calls.  Every
    // write to the two bytes, with the PC that did it and the stack pointer at
    // that moment: a push landing here says the stack has left page one.
    integer csw_shown = 0;
    always @(posedge clk)
        if (boot_go && u_present && !u_rw && u_bank == 8'h00 &&
            (u_addr == 16'h0036 || u_addr == 16'h0037) && csw_shown < 16) begin
            csw_shown = csw_shown + 1;
            $display("    CSW: $%04X <= $%02X from %02X/%04X at instruction %0d, S=$%04X E=%0d D=$%04X",
                     u_addr, u_wdata, last_sync[23:16], last_sync[15:0], trace_instrs,
                     u_cpu.s, u_cpu.f_e, u_cpu.d);
        end

    // ---- RUNG 4c: EVERY WRITER THAT TOUCHES SET 1, LINE 0 ------------------
    // The junk is all in line 0 of the watched page's set, and the fill left
    // that line at zero, so somebody writes it afterwards.  Both ports of the
    // way RAM are named here - the landing write and the engine - with the
    // way, the byte enables and the byte, so the writer identifies itself.
    integer pw4c = 0;
    always @(posedge clk) if (PAGE_WATCH != 0 && pw4c < 24) begin
        if (u_cache.wl_v && u_cache.wl_row == {7'd1, 4'd0}) begin
            pw4c = pw4c + 1;
            $display("    4c LAND: way %02x be %04x byte $%02X at %0d clocks; the entrant was ppn $%04X off $%02X",
                     u_cache.wl_way, u_cache.wl_be, u_cache.wl_data[7:0], now,
                     cl_ppn_w, cl_off[7:0]);
        end
        if (u_cache.eb_en && u_cache.eb_we != 16'd0 &&
            u_cache.eb_addr == {7'd1, 4'd0}) begin
            pw4c = pw4c + 1;
            $display("    4c ENG: state %0d way %02x we %04x byte $%02X at %0d clocks; e_ppn $%04X e_old $%04X",
                     u_cache.state, u_cache.e_way, u_cache.eb_we,
                     u_cache.eb_wdata[7:0], now, u_cache.e_ppn, u_cache.e_old);
        end
    end

    // ---- RUNG 4c: THE PAGE AS ITS FILL LEFT IT -----------------------------
    // The bisection.  A fill is sixteen beats of the DDR3's own bytes, so the
    // moment its retag lands the page must read EXACTLY what the DDR3 held -
    // all zeros, in this bench.  Count the non-zero bytes here and compare
    // with the count at the end: junk present now means the FILL did not
    // deliver, junk only at the end means a writer the mask cannot see.
    // Sampled a few clocks late because the beats are synchronous writes.
    reg [3:0] pw_fd = 4'd0;
    always @(posedge clk) begin
        if (PAGE_WATCH != 0 && u_cache.eng_retag &&
            u_cache.e_ppn == PAGE_WATCH[15:0]) pw_fd <= 4'd8;
        else if (pw_fd != 4'd0) begin
            pw_fd <= pw_fd - 4'd1;
            if (pw_fd == 4'd1) begin : pw_fill_count
                integer k, n;
                n = 0;
                for (k = 0; k < 256; k = k + 1)
                    if (card_byte(PAGE_WATCH[15:0], 8'(k)) !== 8'h00) n = n + 1;
                $display("    rung 4c: page $%04X at %0d clocks, just after its fill retag: %0d of 256 bytes NON-ZERO (the DDR3 held all zeros)",
                         PAGE_WATCH[15:0], now, n);
            end
        end
    end

    // ...written out at the end as {ppn, 256 bytes}, little-endian ppn.
    task dump_pages;
        integer f, k, off;
        begin
            if (PAGESF == "") return;
            f = $fopen(PAGESF, "wb");
            for (k = 0; k < 65536; k = k + 1)
                if (pg_dirty[k]) begin
                    $fwrite(f, "%c%c", k[7:0], k[15:8]);
                    for (off = 0; off < 32; off = off + 1)
                        $fwrite(f, "%c", pg_mask[k][8*off +: 8]);
                    for (off = 0; off < 256; off = off + 1)
                        $fwrite(f, "%c", card_byte(16'(k), 8'(off)));
                end
            $fclose(f);
            // ...and the op stream's own tail, which is buffered and would
            // otherwise be short of the last few hundred ops - which is
            // exactly the stack, written to the end.
            if (opsf != 0) $fclose(opsf);
            if (PAGE_WATCH != 0) begin
                $write("    page $%04X in the card's memory:", PAGE_WATCH[15:0]);
                for (off = 0; off < 16; off = off + 1)
                    $write(" %02X", card_byte(PAGE_WATCH[15:0], 8'(off)));
                $display("  (%0d writes, lowest offset $%02X, %0s)",
                         pw_writes, pw_lowest,
                         card_resident(PAGE_WATCH[15:0]) ? "RESIDENT in the cache"
                                                         : "not resident: from DDR3");
                $write("    ...and what DDR3 holds for it:");
                for (off = 0; off < 16; off = off + 1)
                    $write(" %02X", smem[{PAGE_WATCH[15:0], 8'(off)}]);
                $display("");
            end
            $display("    the mirror's side: %0d ops and %0d written pages out",
                     ops_written, pages_dirty);
        end
    endtask

    // ---- rung 3e: the language card ------------------------------------------------
    // Where ProDOS stops: it relocates, then calls `JSR $FE84` and reads $00
    // there.  Two things decide what $00/$D000-$FFFF answers - the $C08x
    // switches, and whether anything was ever written into the RAM behind
    // them - so both are named here.  sw_state is
    // {prewrite, wren, ramrd, bank2, ...} (rtl/apple_mmu.sv).
    integer lc_wr [0:47];               // per page, $D0..$FF of bank 0
    integer lc_writes = 0, lc_first = -1, lc_last = -1, lc_touches = 0;
    integer lci;
    initial for (lci = 0; lci < 48; lci = lci + 1) lc_wr[lci] = 0;
    wire lc_pair = (u_bank == 8'h00) || (u_bank == 8'h01) ||
                   (u_bank == 8'hE0) || (u_bank == 8'hE1);
    always @(posedge clk) if (boot_go) begin
        if (u_present && lc_pair && u_addr[15:4] == 12'hC08) begin
            lc_touches = lc_touches + 1;
            if (LC_TRACE != 0)
                $display("    lc:  $%04X %0s from %02X/%04X at instruction %0d -> bank%0d %0s read, write %0s",
                         u_addr, u_rw ? "read " : "write",
                         last_sync[23:16], last_sync[15:0], trace_instrs,
                         sw_state[8] ? 2 : 1, sw_state[9] ? "RAM" : "ROM",
                         sw_state[10] ? "enabled" : "protected");
        end
        // ...and the CYCLES underneath, so a touch that no instruction in
        // the code makes can be told from one that is really there.
        if (LC_TRACE != 0 && cpu_cyc_en && cpu_a24[15:4] == 12'hC08)
            $display("    lc cyc: %06X rw=%0d vda=%0d vpa=%0d sync=%0d (pc %02X/%04X)",
                     cpu_a24, cpu_rw, cpu_vda, cpu_vpa, cpu_sync,
                     last_sync[23:16], last_sync[15:0]);
        // What lands in the RAM behind the switches, in bank 0.
        if (u_present && !u_rw && u_bank == 8'h00 && u_addr[15:12] >= 4'hD) begin
            lc_wr[u_addr[15:8] - 8'hD0] = lc_wr[u_addr[15:8] - 8'hD0] + 1;
            lc_writes = lc_writes + 1;
            if (lc_first < 0) lc_first = trace_instrs;
            lc_last = trace_instrs;
        end
    end
    task dump_lc_census;
        integer k, lo, hi;
        begin
            $display("    ---- the language card: %0d $C08x touches, %0d writes into $00/D000-FFFF ----",
                     lc_touches, lc_writes);
            if (lc_writes > 0) begin
                lo = -1; hi = -1;
                for (k = 0; k < 48; k = k + 1) if (lc_wr[k] != 0) begin
                    if (lo < 0) lo = k;
                    hi = k;
                end
                $display("      pages $%02X-$%02X, first at instruction %0d, last at %0d",
                         8'hD0 + lo[7:0], 8'hD0 + hi[7:0], lc_first, lc_last);
                for (k = 0; k < 48; k = k + 1)
                    if (lc_wr[k] != 0) $write(" $%02X:%0d", 8'hD0 + k[7:0], lc_wr[k]);
                $display("");
            end
            $display("      the state it ended in: bank%0d, %0s read, write %0s, altzp %0d",
                     sw_state[8] ? 2 : 1, sw_state[9] ? "RAM" : "ROM",
                     sw_state[10] ? "enabled" : "protected", sw_state[3]);
        end
    endtask

    // RES' drops what the card drops.
    reg res_prev = 1'b1;
    always @(posedge clk) begin
        if (!res_sync && res_prev) begin
            hm_fifo = 0; hm_armed = 0; qr = qw;             // nothing outstanding
        end
        res_prev = res_sync;
    end

    // The I/O page exists in banks $00/$01/$E0/$E1 alone; everywhere else on a
    // IIgs $C000-$CFFF is RAM (src/hd_card.cpp dma_hits_io, the same words).
    function automatic bit dma_hits_io(input [7:0] bank, input [15:0] a, input integer len);
        integer k;
        begin
            dma_hits_io = 0;
            if (bank != 8'h00 && bank != 8'h01 && bank != 8'hE0 && bank != 8'hE1) return 0;
            for (k = 0; k < len; k = k + 256) begin
                if (((a + k) & 16'hF000) == 16'hC000) dma_hits_io = 1;
            end
            if (((a + len - 1) & 16'hF000) == 16'hC000) dma_hits_io = 1;
        end
    endfunction
    function automatic [7:0] status_byte(input [7:0] err);
        status_byte = (err != 0) ? {(err[5:0]), 1'b1} : 8'h00;
    endfunction

    // Building and pushing an answer.  The bytes it carries land in the
    // machine by the card's DMA - bus writes through the override path -
    // so the reference follows them through the unified stream on its own.
    reg [7:0] ans [0:1023];              // data bytes of the completion
    integer   ans_n;
    // WHICH BANK THE ANSWER LANDS IN.  rtl/hd_card.sv reads it from the
    // spare byte of HD_DONE's size word (pay_data[23:16]) and drives it into
    // the override's address, so an extended call's buffer in bank $02 got
    // here and then landed in bank zero for as long as this was hard zero.
    reg [7:0] ans_bank;
    task automatic push_done(input [7:0] status, input [15:0] addr, input [15:0] size16);
        integer k;
        reg [31:0] w;
        begin
            if (ans_n == 0) push_word(hdr(T_HD_DONE, 8'd0, {8'd0, status}));
            else begin
                push_word(hdr(T_HD_DONE, 8'(2 + (ans_n + 3) / 4), {8'd0, status}));
                push_word({16'(ans_n), addr});
                push_word({8'd0, ans_bank, size16});
                for (k = 0; k < ans_n; k = k + 4) begin
                    w = 32'd0;
                    w[7:0]   = ans[k];
                    if (k + 1 < ans_n) w[15:8]  = ans[k+1];
                    if (k + 2 < ans_n) w[23:16] = ans[k+2];
                    if (k + 3 < ans_n) w[31:24] = ans[k+3];
                    push_word(w);
                end
            end
        end
    endtask
    task automatic id_string(input string s);
        integer k, n;
        begin
            n = s.len() > 16 ? 16 : s.len();
            ans[ans_n] = 8'(n); ans_n = ans_n + 1;
            for (k = 0; k < n; k = k + 1) begin ans[ans_n] = s[k]; ans_n = ans_n + 1; end
            for (k = n; k < 16; k = k + 1) begin ans[ans_n] = 8'h20; ans_n = ans_n + 1; end
        end
    endtask

    integer hd_blocks_read = 0, hd_blocks_written = 0;

    // Every command the card was given, and what came back, so a boot that
    // stops can be read off rather than guessed at.
    // The host's worker: answers each queued command HOST_DELAY clocks after
    // its EXECUTE, in order - and never while the card is still moving a
    // previous answer's bytes, as the real host spaces its HD_DONEs for
    // exactly that reason (hd_service.cpp: an unspaced one would be dropped).
    task automatic host_serve_one;
        integer u, r, k, base;
        reg [7:0] cmd, sc, err, unum, membank;
        reg       ext;
        reg [15:0] memblock, size16;
        reg [31:0] diskblock;
        begin
            cmd = q_cmd[qr % QN]; unum = q_unum[qr % QN]; u = q_unit[qr % QN];
            sc = q_sc[qr % QN]; memblock = q_mem[qr % QN]; diskblock = q_disk[qr % QN];
            ext = q_ext[qr % QN]; membank = q_bank[qr % QN];
            ans_n = 0;
            ans_bank = membank;
            size16 = 16'd0;
            if (u >= 0 && u < NUM_DEVICES) size16 = 16'(HDV_BLOCKS);
            if (u == UNIT_NONE) begin
                push_done(status_byte(ERR_NOTCONN), 16'd0, 16'd0);
            end else begin
                r = (u == UNIT_CTL) ? 8 : u;
                err = ERR_OK;
                if (u >= NUM_DEVICES && u != UNIT_CTL &&
                    cmd != CMD_BLK_STATUS && cmd != CMD_SP_STATUS) begin
                    hm_uerr[r] = ERR_NOTCONN;
                    push_done(status_byte(ERR_NOTCONN), 16'd0, 16'd0);
                end else if ((cmd == CMD_SP_READ || cmd == CMD_SP_WRITE) && diskblock > 24'h7FFFFF) begin
                    hm_uerr[r] = ERR_IO;
                    push_done(status_byte(ERR_IO), 16'd0, size16);
                end else begin
                    hm_uerr[r] = ERR_OK;
                    case (cmd)
                        CMD_BLK_STATUS: begin
                            host_statuses = host_statuses + 1;
                            if (u == UNIT_CTL || u >= NUM_DEVICES) err = ERR_IO;
                            push_done(status_byte(err), 16'd0, (u >= 0 && u < NUM_DEVICES) ? size16 : 16'd0);
                            hm_uerr[r] = err;
                        end
                        CMD_SP_BUSY: push_done(status_byte(ERR_OK), 16'd0, size16);
                        CMD_SP_STATUS: begin
                            host_statuses = host_statuses + 1;
                            if (u == UNIT_CTL) begin
                                case (sc)
                                    8'h00, 8'h03: begin
                                        ans[ans_n] = 8'(NUM_DEVICES); ans_n = ans_n + 1;
                                        for (k = 0; k < 7; k = k + 1) begin ans[ans_n] = 0; ans_n = ans_n + 1; end
                                        if (sc == 8'h03) begin
                                            id_string("STRUDELWORKS SP");
                                            ans[ans_n] = 8'h00; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h00; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h01; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h00; ans_n = ans_n + 1;
                                        end
                                    end
                                    default: err = ERR_BADCTL;
                                endcase
                            end else begin
                                case (sc)
                                    8'h00, 8'h03: begin
                                        ans[ans_n] = (u < NUM_DEVICES) ? 8'hF8 : 8'hE8; ans_n = ans_n + 1;
                                        ans[ans_n] = (u < NUM_DEVICES) ? 8'(HDV_BLOCKS & 255) : 8'd0; ans_n = ans_n + 1;
                                        ans[ans_n] = (u < NUM_DEVICES) ? 8'((HDV_BLOCKS >> 8) & 255) : 8'd0; ans_n = ans_n + 1;
                                        ans[ans_n] = 8'd0; ans_n = ans_n + 1;
                                        // AN EXTENDED DIB CARRIES A FOURTH
                                        // SIZE BYTE - 26 bytes where a plain
                                        // one returns 25, which is what KEGS
                                        // returns and what src/hd_card.cpp
                                        // returns.  Without it the list is
                                        // one byte short and every field
                                        // after it reads one byte early.
                                        if (ext) begin
                                            ans[ans_n] = 8'd0; ans_n = ans_n + 1;
                                        end
                                        if (sc == 8'h03) begin
                                            id_string($sformatf("STRUDELWORKS D#%0d", unum));
                                            ans[ans_n] = 8'h02; ans_n = ans_n + 1;
                                            // THE DEVICE SUBTYPE, and it is
                                            // where a IIgs boot lives or dies:
                                            // GS/OS's loader tests BIT 7,
                                            // "extended calls supported".  It
                                            // follows the ROM, exactly as the
                                            // host's set_gs() follows
                                            // machine = iigs: $C0 for the
                                            // IIgs's SmartPort, $20 for the
                                            // //e's, which does not claim it
                                            // and could not keep it.  This
                                            // model said $20 either way for a
                                            // rung after the extended calls
                                            // behind the bit were built, so
                                            // GS/OS walked away here and the
                                            // bench never saw an extended
                                            // call at all (docs/GS.md 7c).
                                            ans[ans_n] = GS_HD_ROM ? 8'hC0 : 8'h20; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h01; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h00; ans_n = ans_n + 1;
                                        end
                                    end
                                    default: err = ERR_BADCTL;
                                endcase
                            end
                            if (err == ERR_OK && dma_hits_io(membank, memblock, ans_n)) err = ERR_BADCTL;
                            if (err != ERR_OK) ans_n = 0;
                            hm_uerr[r] = err;
                            push_done(status_byte(err), memblock, size16);
                        end
                        CMD_BLK_READ, CMD_SP_READ: begin
                            if (diskblock >= HDV_BLOCKS || dma_hits_io(membank, memblock, 512)) begin
                                err = ERR_IO; ans_n = 0;
                                $display("    disk: REFUSED block %0d -> $%02X/%04X (%0s) at instruction %0d",
                                         diskblock, membank, memblock,
                                         (diskblock >= HDV_BLOCKS) ? "past the end of the image"
                                                                   : "the DMA would cross the I/O page",
                                         trace_instrs);
                            end else begin
                                base = diskblock * 512;
                                for (k = 0; k < 512; k = k + 1) begin ans[k] = himg[base + k]; end
                                ans_n = 512;
                                hd_blocks_read = hd_blocks_read + 1;
                                $display("    disk: READ block %0d -> $%02X/%04X at instruction %0d",
                                         diskblock, membank, memblock, trace_instrs);
                                host_reads = host_reads + 1;
                                pend_addr = memblock; pend_bank = membank; pend_blk = diskblock;
                                pend_b2 = sw_state[8]; pend_azp = sw_state[3];
                                pend_dirty = 1'b0;
                                pend_dirty_dl = 1'b0;
                                pend_valid = 1'b1;
                            end
                            hm_uerr[r] = err;
                            push_done(status_byte(err), memblock, size16);
                        end
                        CMD_BLK_WRITE, CMD_SP_WRITE: begin
                            if (diskblock >= HDV_BLOCKS || dma_hits_io(membank, memblock, 512)) begin
                                hm_uerr[r] = ERR_IO;
                                push_done(status_byte(ERR_IO), 16'd0, size16);
                            end else begin
                                // The block was captured from the mirror at
                                // the EXECUTE; it goes straight to the image.
                                base = diskblock * 512;
                                for (k = 0; k < 512; k = k + 1)
                                    himg[base + k] = q_blk[qr % QN][k];
                                hd_blocks_written = hd_blocks_written + 1;
                                host_writes = host_writes + 1;
                                push_done(status_byte(ERR_OK), 16'd0, size16);
                            end
                        end
                        CMD_BLK_FORMAT, CMD_SP_FORMAT: begin
                            for (k = 0; k < HDV_BLOCKS * 512; k = k + 1) himg[k] = 8'h00;
                            push_done(status_byte(ERR_OK), 16'd0, size16);
                        end
                        default: begin
                            hm_uerr[r] = ERR_IO;
                            push_done(status_byte(ERR_IO), 16'd0, size16);
                        end
                    endcase
                end
            end
            qr = qr + 1;
        end
    endtask

    initial begin : host_pump
        forever begin
            @(posedge clk);
            // `u_hd.st == 2'd0` and not `== u_hd.S_IDLE`: S_IDLE is the enum's
            // first item (value 0), and a HIERARCHICAL REFERENCE TO AN ENUM
            // ITEM of a module specialised by a parameter override is what
            // the simulator, 5.020, segfaults on: V3Broken "Broken link in
            // node", the ENUMITEMREF left pointing at the unspecialised module
            // (and a comment line may not begin with the tool's name: that is
            // a directive to it) - found with --debugi 1 after the
            // hd_card #(.GS (1)) above took
            // the whole bench down (docs/GS.md, 2026-09-11).
            if (qr < qw && (now - q_at[qr % QN]) >= HOST_DELAY && u_hd.st == 2'd0)
                host_serve_one();
        end
    end

    // ---- the I/O census: what the ROM asks the chipset for -------------------------
    // Every $C0xx the ROM touches, counted by address and direction, with the
    // instruction number of the FIRST touch.  This is rung 3b's work list in
    // the ROM's own order (docs/GS.md): a register with an early first touch
    // and a large count is one the machine is waiting on.
    integer io_rd [0:255];
    integer io_wr [0:255];
    integer io_first [0:255];
    integer ic;
    initial for (ic = 0; ic < 256; ic = ic + 1) begin
        io_rd[ic] = 0; io_wr[ic] = 0; io_first[ic] = -1;
    end
    // A IIgs sees I/O at $C0xx in a pair bank only, which is the rule the map
    // applies; the census counts what the map would call I/O.
    wire io_touch = boot_go && u_present && (u_addr[15:8] == 8'hC0) &&
                    ((u_bank == 8'h00) || (u_bank == 8'h01) ||
                     (u_bank == 8'hE0) || (u_bank == 8'hE1));
    always @(posedge clk) if (io_touch) begin
        if (u_rw) io_rd[u_addr[7:0]] = io_rd[u_addr[7:0]] + 1;
        else      io_wr[u_addr[7:0]] = io_wr[u_addr[7:0]] + 1;
        if (io_first[u_addr[7:0]] < 0) io_first[u_addr[7:0]] = trace_instrs;
    end
    // The SLOT pages beside the $C0xx registers: $C0n0-$C0nF device select
    // and $Cn00-$CnFF ROM, per slot.  The machine boots from the emulated
    // SmartPort in SLOT 7 (the user's, 2026-09-09), so what matters most is
    // whether the ROM's scan ever reaches slot 7's pages at all.
    integer slot_dev [0:7];
    integer slot_rom [0:7];
    integer slot_first [0:7];
    integer sc;
    initial for (sc = 0; sc < 8; sc = sc + 1) begin
        slot_dev[sc] = 0; slot_rom[sc] = 0; slot_first[sc] = -1;
    end
    wire slot_pair = (u_bank == 8'h00) || (u_bank == 8'h01) ||
                     (u_bank == 8'hE0) || (u_bank == 8'hE1);
    wire dev_touch = boot_go && u_present && slot_pair &&
                     (u_addr[15:8] == 8'hC0) && (u_addr[7:4] >= 4'h8);
    wire rom_touch = boot_go && u_present && slot_pair &&
                     (u_addr[15:12] == 4'hC) && (u_addr[11:8] >= 4'h1) &&
                     (u_addr[11:8] <= 4'h7);
    always @(posedge clk) begin
        if (dev_touch) begin
            slot_dev[u_addr[6:4]] = slot_dev[u_addr[6:4]] + 1;
            if (slot_first[u_addr[6:4]] < 0) slot_first[u_addr[6:4]] = trace_instrs;
        end
        if (rom_touch) begin
            slot_rom[u_addr[10:8]] = slot_rom[u_addr[10:8]] + 1;
            if (slot_first[u_addr[10:8]] < 0) slot_first[u_addr[10:8]] = trace_instrs;
        end
    end
    task dump_slot_census;
        integer k;
        begin
            $display("    ---- the slot census: device select, ROM page, first touch ----");
            for (k = 1; k < 8; k = k + 1)
                $display("      slot %0d  $C0%0dx %-9d  $C%0dxx %-9d  first @ %0d",
                         k, k + 8, slot_dev[k], k, slot_rom[k], slot_first[k]);
        end
    endtask

    // What the ROM made of the machine's configuration: the slot register it
    // ended up with, and the battery RAM it wrote.  With an all-zero BRAM the
    // ROM finds a bad checksum and writes its own defaults, and THOSE are
    // what decide which slots are "Your Card" - which is what the slot-7
    // SmartPort boot turns on (docs/GS.md rung 3d).
    task dump_config;
        integer k, r;
        string line;
        begin
            $display("    ---- the configuration the ROM settled on ----");
            $display("      $C02D SLOTROMSEL = $%02X  (a SET bit gives that page to the slot)",
                     gs_sltrom_w);
            for (k = 1; k < 8; k = k + 1)
                $display("        slot %0d: %0s", k,
                         gs_sltrom_w[k] ? "the SLOT's card" : "internal ROM");
            $display("      $C035 SHADOW = $%02X   $C036 CYAREG = $%02X   $C068 STATEREG = $%02X",
                     gs_shadow_w, gs_cyareg_w, gs_state_w);
            $display("    ---- the battery RAM the ROM wrote ----");
            for (r = 0; r < 16; r = r + 1) begin
                line = $sformatf("      %02X:", r * 16);
                for (k = 0; k < 16; k = k + 1)
                    line = $sformatf("%s %02X", line, card_bram(8'(r*16 + k)));
                $display("%0s", line);
            end
        end
    endtask

    task dump_io_census;
        integer k, touched;
        begin
            touched = 0;
            $display("    ---- the $C0xx census: addr, reads, writes, first touch ----");
            for (k = 0; k < 256; k = k + 1)
                if (io_rd[k] != 0 || io_wr[k] != 0) begin
                    touched = touched + 1;
                    $display("      $C0%02X  r %-9d w %-9d first @ %0d", k,
                             io_rd[k], io_wr[k], io_first[k]);
                end
            $display("    %0d distinct $C0xx addresses touched", touched);
        end
    endtask

    // Who writes $C02D, and with what: the slot register is built from the
    // battery RAM, and finding the BRAM bytes behind it means finding this
    // routine (docs/GS.md rung 3d).
    always @(posedge clk)
        if (swi_commit && !u_rw && (u_addr[15:0] == 16'hC02D))
            $display("    $C02D <= $%02X written from %02X/%04X at instruction %0d",
                     u_wdata, last_sync[23:16], last_sync[15:0], trace_instrs);

    // ---- the engine's overruns, named ---------------------------------------------
    // late_fills is "an op missed while the fill engine was busy, and was not
    // served" - which for a write means the byte is gone.  boot_tb asserts it
    // is zero; this bench does too, and prints the op that was blocked and
    // what the engine was doing, because on the GS there is a producer the
    // IIe never had: the SHADOW DUPLICATE, which starts a fill of its own one
    // clock behind its op and is outside the dispatcher's `busy` gate.
    reg [7:0] lf_q = 8'd0, fd_q = 8'd0;
    always @(posedge clk) begin
        lf_q <= late_fills; fd_q <= fifo_drops;
        if (late_fills != lf_q)
            $display("    LATE FILL #%0d at %0d clocks: blocked op ppn $%04X off $%02X rw %0d posted %0d; engine state %0d on ppn $%04X",
                     late_fills, now, u_cache.s_ppn, u_cache.s_off, u_cache.s_rw,
                     u_cache.s_posted, u_cache.state, u_cache.e_ppn);
        if (fifo_drops != fd_q)
            $display("    FIFO DROP #%0d at %0d clocks", fifo_drops, now);
    end

    // ---- the heartbeat -----------------------------------------------------------
    reg [23:0] last_sync = 24'd0;
    always @(posedge clk) if (cpu_cyc_en && cpu_sync) last_sync <= cpu_a24;
    always @(posedge clk) if (now % 2_000_000 == 1_999_999)
        $display("    ...%0d clocks, %0d bus cycles, %0d instructions, PC~$%02X/%04X, fast %0d bus %0d, fills %0d",
                 now + 1, bus_cycles, trace_instrs, last_sync[23:16], last_sync[15:0],
                 fast_ops, bus_ops, mem_fills);

    // ---- ROM loading -------------------------------------------------------------
    reg [7:0] rom_img [0:262143];
    reg [7:0] hd_rom [0:255];
    task send_chunk(input integer c);
        integer k;
        begin
            @(negedge clk);
            msg_valid <= 1'b1; msg_type <= 8'h22; msg_len <= 8'd129;
            @(negedge clk);
            msg_valid <= 1'b0; pay_valid <= 1'b1; pay_data <= c;
            @(negedge clk);
            for (k = 0; k < 128; k = k + 1) begin
                pay_data <= {rom_img[c*512 + 4*k + 3], rom_img[c*512 + 4*k + 2],
                             rom_img[c*512 + 4*k + 1], rom_img[c*512 + 4*k]};
                @(negedge clk);
            end
            pay_valid <= 1'b0;
            @(negedge clk);
            while (rom_busy) @(negedge clk);
        end
    endtask

    // One ADB_KEY: a single word, {mods[7:0], is_up, keycode[6:0]}.
    task send_key(input [6:0] code, input up, input [7:0] mods);
        begin
            @(negedge clk);
            msg_valid <= 1'b1; msg_type <= 8'h2F; msg_len <= 8'd1;
            @(negedge clk);
            msg_valid <= 1'b0; pay_valid <= 1'b1;
            pay_data <= {16'd0, mods, up, code};
            @(negedge clk);
            pay_valid <= 1'b0;
            @(negedge clk);
        end
    endtask

    // The typist: waits for the machine to get where it is going, presses the
    // key and lets it up.  Held apart from the run's own process because it
    // has to happen WHILE the machine runs, not before or after it.
    integer keys_sent = 0;
    integer adb_repeats = 0;
    always @(posedge clk) if (u_gsio.u_adb.rpt_fire) adb_repeats = adb_repeats + 1;
    // PB0 held down for a while at BTN_AT: 2'b10 is "down", 2'b00 "the
    // hardware's" (rtl/pb_inject.sv holds the same word).
    initial if (BTN_AT != 0) begin : clicker
        wait (trace_instrs >= BTN_AT);
        $display("== the mouse button goes DOWN at instruction %0d", trace_instrs);
        pb_force = 6'b000010;
        repeat (BTN_HOLD) @(posedge clk);
        pb_force = 6'd0;
        $display("== the mouse button is released at instruction %0d", trace_instrs);
    end

    initial if (KEY_AT != 0) begin : typist
        wait (trace_instrs >= KEY_AT);
        wait (!msg_lock); msg_lock = 1'b1;
        send_key(7'(KEY_CODE), 1'b0, 8'(KEY_MODS));
        msg_lock = 1'b0;
        keys_sent = keys_sent + 1;
        if (u_gsio.u_adb.kbd_buf[0][7] !== 1'b1)
            fail("the key went down and $C000's strobe did not set");
        else
            ok($sformatf("keycode $%02X reached the keyboard: $C000 reads $%02X, $C025 $%02X",
                         KEY_CODE, u_gsio.u_adb.kbd_buf[0], u_gsio.u_adb.c025_val));
        repeat (KEY_HOLD) @(negedge clk);
        wait (!msg_lock); msg_lock = 1'b1;
        send_key(7'(KEY_CODE), 1'b1, 8'(KEY_MODS));
        msg_lock = 1'b0;
        if (KEY_HOLD >= 4000000) begin
            // Held for tens of frames with the machine polling $C000: the
            // micro should have re-fired the key on its own.
            if (adb_repeats == 0)
                fail("the key was held for tens of frames and never repeated");
            else
                ok($sformatf("the ADB micro repeated the held key %0d times",
                             adb_repeats));
        end
    end

    // The battery RAM the host ships, as one GS_BRAM: 64 words, four bytes a
    // word, low byte first, taken all or nothing (rtl/gs_clock.sv).
    reg [7:0] bram_img [0:255];
    task send_bram;
        integer k;
        begin
            @(negedge clk);
            msg_valid <= 1'b1; msg_type <= 8'h2E; msg_len <= 8'd64;
            @(negedge clk);
            msg_valid <= 1'b0; pay_valid <= 1'b1;
            for (k = 0; k < 64; k = k + 1) begin
                pay_data <= {bram_img[4*k + 3], bram_img[4*k + 2],
                             bram_img[4*k + 1], bram_img[4*k]};
                @(negedge clk);
            end
            pay_valid <= 1'b0;
            @(negedge clk);
        end
    endtask
    // The card's battery RAM, out of its four banks (rtl/gs_clock.sv).
    function automatic [7:0] card_bram(input [7:0] i);
        begin
            case (i[1:0])
                2'd0: card_bram = u_gsio.u_clock.bram0[i[7:2]];
                2'd1: card_bram = u_gsio.u_clock.bram1[i[7:2]];
                2'd2: card_bram = u_gsio.u_clock.bram2[i[7:2]];
                default: card_bram = u_gsio.u_clock.bram3[i[7:2]];
            endcase
        end
    endfunction

    // ---- reading the card's memory back (boot_tb's, verbatim) ---------------------
    // Hash the physical page to its set, scan the ways, take the one that
    // holds it - else the DDR3 stub has it.  The bench needs this to check
    // that a block the host DMA'd in actually landed where the machine will
    // look for it.
    localparam integer MEM_SETS = 128, MEM_WAYS = 8;
    localparam integer SIDX = $clog2(MEM_SETS);
    function automatic [7:0] card_byte(input [15:0] ppn, input [7:0] off);
        int st, w, hit;
        logic [127:0] row;
        begin
            st  = int'(ppn[SIDX-1:0] ^ ppn[2*SIDX-1 -: SIDX]);
            hit = -1;
            for (w = 0; w < MEM_WAYS; w = w + 1)
                if (u_cache.dir[w][st][17] && u_cache.dir[w][st][15:0] == ppn) hit = w;
            row = 128'd0;
            case (hit)
                0: row = u_cache.g_way[0].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                1: row = u_cache.g_way[1].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                2: row = u_cache.g_way[2].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                3: row = u_cache.g_way[3].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                4: row = u_cache.g_way[4].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                5: row = u_cache.g_way[5].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                6: row = u_cache.g_way[6].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                7: row = u_cache.g_way[7].u_way.mem[{st[SIDX-1:0], off[7:4]}];
                default: ;
            endcase
            card_byte = (hit >= 0) ? row[8 * off[3:0] +: 8] : smem[{ppn, off}];
        end
    endfunction

    function automatic integer card_resident(input [15:0] ppn);
        int st, w;
        begin
            st = int'(ppn[SIDX-1:0] ^ ppn[2*SIDX-1 -: SIDX]);
            card_resident = 0;
            for (w = 0; w < MEM_WAYS; w = w + 1)
                if (u_cache.dir[w][st][17] && u_cache.dir[w][st][15:0] == ppn) card_resident = 1;
        end
    endfunction

    // Every block the host sent, checked where the machine will look for it,
    // at the moment the machine asks the card for the next thing.
    // The physical page a virtual address in bank 0 lands on, for the LC
    // state that was in force: see pend_b2/pend_azp above.
    function automatic [15:0] land_ppn(input [15:0] va, input b2, input azp);
        reg [7:0] pg;
        begin
            pg = (va[15:12] == 4'hD && !b2) ? {4'hC, va[11:8]} : va[15:8];
            land_ppn = {(va[15:12] >= 4'hD && azp) ? 8'd1 : 8'd0, pg};
        end
    endfunction
    // Bank zero folds through the language card and ALTZP; every other bank
    // of RAM is its own page one-to-one (apple_mmu: "$02-$7F: ordinary RAM,
    // its own bank, no switch on it").
    function automatic [15:0] land_ppn_b(input [15:0] va, input [7:0] bank, input b2, input azp);
        land_ppn_b = (bank == 8'd0) ? land_ppn(va, b2, azp) : {bank, va[15:8]};
    endfunction
    // Byte k of a block DMA'd to {bank, addr}, as the card lands it: at
    // GS = 1 the 24-bit sum CARRIES into the next bank (rtl/hd_card.sv,
    // docs/GS.md "the DMA wrapped at a bank edge").  Every place this bench
    // follows a block through memory - the landing check, the machine's
    // writes into it, a write's capture - goes through here; until
    // 2026-09-13 they wrapped in sixteen bits, and every block straddling a
    // bank edge "did not land" from exactly the edge on.
    function automatic [23:0] blk_a24(input [7:0] bank, input [15:0] addr, input integer k);
        blk_a24 = {bank, addr} + 24'(k);
    endfunction
    function automatic [7:0] blk_card_byte(input [7:0] bank, input [15:0] addr, input integer k,
                                           input b2, input azp);
        reg [23:0] a;
        begin
            a = blk_a24(bank, addr, k);
            blk_card_byte = card_byte(land_ppn_b(a[15:0], a[23:16], b2, azp), a[7:0]);
        end
    endfunction
    task verify_landed(input [15:0] addr, input integer blk);
        integer k, bad, first;
        reg [7:0] got;
        begin
            bad = 0; first = -1;
            for (k = 0; k < 512; k = k + 1) begin
                got = blk_card_byte(pend_bank, addr, k, pend_b2, pend_azp);
                if (got !== himg[blk * 512 + k]) begin
                    bad = bad + 1;
                    if (first < 0) first = k;
                end
            end
            if (bad != 0)
                fail($sformatf("block %0d did not land at $%02X/%04X: %0d of 512 bytes wrong, first at +%0d (got $%02X, want $%02X)",
                               blk, pend_bank, addr, bad, first,
                               blk_card_byte(pend_bank, addr, first, pend_b2, pend_azp),
                               himg[blk * 512 + first]));
            else
                blocks_verified = blocks_verified + 1;
        end
    endtask
    // The machine writing into the block it was just given: through the
    // dispatcher (u_*), or posted by the data front (dev_*), which since
    // fw e3720fd includes bank zero's shadowable $2000-$9FFF - GS/OS's
    // buffer at $9A00.  Without the second watch every block GS/OS wrote
    // through the front was checked as if untouched and "did not land".
    always @(posedge clk) begin
        if (boot_go && pend_valid && u_present && !u_rw && !u_ovr &&
            {u_bank, u_addr} >= {pend_bank, pend_addr} &&
            {u_bank, u_addr} <= blk_a24(pend_bank, pend_addr, 511))
            pend_dirty <= 1'b1;
        if (boot_go && pend_valid && dev_valid && !dev_rw &&
            {dev_bank, dev_addr} >= {pend_bank, pend_addr} &&
            {dev_bank, dev_addr} <= blk_a24(pend_bank, pend_addr, 511)) begin
            pend_dirty    <= 1'b1;
            pend_dirty_dl <= 1'b1;
        end
    end

    always @(posedge clk) if (chk_go) begin
        chk_go = 1'b0;
        if (pend_dirty) begin
            blocks_touched = blocks_touched + 1;
            if (pend_dirty_dl) blocks_touched_dl = blocks_touched_dl + 1;
        end else begin
            verify_landed(pend_addr, pend_blk);
        end
        pend_valid = 1'b0;
    end

    // ---- the run -----------------------------------------------------------------
    integer a, c;
    initial begin
        $readmemh(ROMF, rom_img);
        $readmemh(HDROMF, hd_rom);
        $readmemh(HDVF, himg);
        for (a = 0; a < IMG; a = a + 1) smem[a] = 8'h00;
        hm_clear();

        $display("boot_gs_tb: GS=1 MODE %0d TARGET %04x ROM %0d chunks, max %0d instructions / %0d clocks",
                 MODE, TARGET, ROM_CHUNKS, MAX_INSTRS, MAX_CLKS);

        repeat (5) @(negedge clk);
        rst <= 1'b0;
        @(negedge clk);
        for (c = 0; c < ROM_CHUNKS; c = c + 1) send_chunk(c);
        if (!rom_loaded) fail("the IIgs ROM did not load");
        else ok($sformatf("the IIgs ROM loaded: %0d chunks into bank $FC", ROM_CHUNKS));
        if (rom_overruns != 0)
            fail($sformatf("%0d ROM chunks were dropped: the load outran the seam", rom_overruns));

        // The battery RAM, before RES' is released, so the ROM's first read
        // of it is the host's image and not the zeros it comes up with.
        if (HAS_BRAM != 0) begin : ship_bram
            integer k, bad;
            $readmemh(BRAMF, bram_img);
            send_bram();
            if (!bram_landed) fail("the battery RAM did not land");
            else begin
                bad = 0;
                for (k = 0; k < 256; k = k + 1)
                    if (card_bram(8'(k)) !== bram_img[k]) bad = bad + 1;
                if (bad != 0)
                    fail($sformatf("the battery RAM landed wrong: %0d of 256 bytes", bad));
                else ok("the host's battery RAM landed whole in the card's clock chip");
            end
        end

        // The slot ROM the card answers $C700-$C7FF from, as the host sends
        // it.  The GS ROM has no slot-7 firmware of its own - bank $FF's
        // $C700 is 256 zero bytes - so this IS what the scan finds.
        // With a 3.5" disk and NO slot-7 image the ROM is not sent at all,
        // as the host sends none with hd1 empty: a SmartPort ROM with no
        // unit behind it still answered the scan's boot read, and the ROM
        // jumped into an empty block and crashed before it ever reached
        // slot 5 (docs/IWM35.md).  The plain boot keeps the ROM, so its
        // floor against the reference is unmoved.
        if (HAS_HDV != 0 || (HAS_FD35 == 0 && HAS_FD525 == 0)) begin
            push_word(hdr(T_HD_ROM, 8'd64, 16'd0));
            for (c = 0; c < 64; c = c + 1)
                push_word({hd_rom[4*c+3], hd_rom[4*c+2], hd_rom[4*c+1], hd_rom[4*c]});
            c = 0;
            while (!hd_rom_loaded && c < 2000) begin @(posedge clk); c = c + 1; end
            if (!hd_rom_loaded) begin
                fail("the slot ROM did not load");
                $display("    rx_wr %0d rx_rd %0d unknowns %0d", rx_wr, rx_rd, unknowns);
            end else ok("the slot-7 SmartPort ROM loaded");
        end else begin
            $display("    (no slot-7 image with a disk in the IWM: the SmartPort ROM is not sent, as the host sends none)");
        end

        serve <= 1'b1;
        mode <= 2'(MODE);
        target <= 16'(TARGET);

        res_n <= 1'b0;
        repeat (5 * CYCLE) @(negedge clk);
        res_n <= 1'b1;
        boot_go <= 1'b1;
        $display("boot_gs_tb: reset released, the ROM runs");

        while (now < MAX_CLKS && trace_instrs < MAX_INSTRS) @(posedge clk);
        $fflush(tf);

        $display("boot_gs_tb: done at %0d clocks / %0d bus cycles / %0d instructions",
                 now, bus_cycles, trace_instrs);
        $display("    counters: fast_ops %0d bus_ops %0d cycles %0d maps %0d retries %0d turbo %0d dline %0d posts %0d",
                 fast_ops, bus_ops, cycles, accel_maps, retries, turbo_ops, dl_serves, dl_posts);
        // The bank table (docs/LONG_DATA.md rung 1): OTHER-memory read
        // candidates, how many found their bank settled in the table, how
        // many the ways served through it, how many anything here served.
        $display("    bank table: OTHER-memory reads %0d, bank in the table %0d, served by the ways %0d (%s%%), by the front at all %0d (%s%%), loads %0d, table $%02X $%02X; writes posted into $02-$7F %0d; chipset fast reads %0d",
                 u_dline.cnt_ob_cand, u_dline.cnt_ob_known,
                 u_dline.cnt_ob_serves, bc_pct(longint'(u_dline.cnt_ob_serves), longint'(u_dline.cnt_ob_cand)),
                 u_dline.cnt_ob_any, bc_pct(longint'(u_dline.cnt_ob_any), longint'(u_dline.cnt_ob_cand)),
                 u_dline.cnt_ob_loads, u_dline.ob[0], u_dline.ob[1], u_dline.cnt_post_hi, u_dline.cnt_io_serves);
        $display("    cache: hits %0d misses %0d fills %0d flushes %0d declines %0d late %0d drops %0d",
                 hits, misses, mem_fills, mem_flushes, mem_declines, late_fills, fifo_drops);
        $display("    last PC $%02X/%04X", last_sync[23:16], last_sync[15:0]);
        dump_io_census();
        dump_slot_census();
        dump_config();
        dump_lc_census();
        dump_clash();
        dump_iwm();
        dump_doc();
        bc_freeze = 1'b1;
        repeat (8) @(posedge clk);
        dump_bank_census();
        dump_intc();
        // A shipped image the ROM ACCEPTS is one it does not rewrite: it
        // checksums the battery RAM at startup and writes its own defaults
        // over an image it does not believe (docs/GS.md, "The battery RAM the
        // host ships").  So this is the whole point of shipping one.
        if (HAS_BRAM != 0) begin : kept_bram
            integer k, bad;
            bad = 0;
            for (k = 0; k < 256; k = k + 1)
                if (card_bram(8'(k)) !== bram_img[k]) bad = bad + 1;
            if (bad != 0)
                fail($sformatf("the ROM rewrote %0d of the battery RAM's 256 bytes: it did not believe the image",
                               bad));
            else ok("the ROM kept the host's battery RAM: it checksummed and believed it");
        end
        dump_text();
        dump_pages();

        $display("    the disk: %0d blocks read, %0d written, %0d statuses, %0d execs",
                 hd_blocks_read, hd_blocks_written, host_statuses, host_execs);

        // THE MILESTONE, when there is an image to find: the ROM's scan
        // reached slot 7 and read from the card.  With no image the scan
        // finds an empty slot and reads nothing, which is not a failure.
        if (HAS_HDV == 0)
            $display("    (no image given: the scan had nothing to find)");
        else if (hd_blocks_read == 0)
            fail("no block was ever read: the scan did not boot from slot 7");
        else begin
            ok($sformatf("%0d blocks read from the slot-7 SmartPort", hd_blocks_read));
            // Not the end-of-run snapshot rung 3d took: a boot that gets
            // going relocates over $0800 long before this point, so each
            // block is checked while it is still the machine's newest, and
            // all that is left here is that it happened.
            if (blocks_verified == 0 && hd_blocks_read > 1)
                fail("no block was ever checked where the machine would look for it");
            else
                ok($sformatf("%0d blocks landed intact where the machine looks for them (%0d the machine had already written to, %0d of those through the data front)",
                             blocks_verified, blocks_touched, blocks_touched_dl));
        end
        $display("    parked %0d internal cycles: %0d would have written, %0d would have hit $C0xx",
                 internal_cycles, internal_writes, internal_io);

        // THE 3.5" MILESTONE, when there is a disk in the drive: the ROM's
        // scan found it, read from it, and the demo's own loader took it
        // the rest of the way into bank $0E.
        if (HAS_FD35 != 0) begin
            $display("    the 3.5\" drive: %0d seeks, %0d fills, head at track %0d side %0d, %0d late, fill max %0d us, IWM mode $%02X",
                     fd35_seeks, fd35_fills, u_gsio.u_iwm.track35, u_gsio.u_iwm.side35,
                     u_gsio.u_iwm.late, u_gsio.u_iwm.fill_max, u_gsio.u_iwm.mode);
            if (fd35_seeks == 0)
                fail("no track was ever asked for: the machine never moved the 3.5\" head");
            else
                ok($sformatf("%0d tracks fetched for the 3.5\" drive", fd35_fills));
            if (demo_launched_at != 0)
                ok($sformatf("the demo launched: bank $0E at instruction %0d", demo_launched_at));
            else if (MAX_INSTRS >= 12000000)
                fail("the demo never launched: no instruction from bank $0E");
            else
                $display("    (run too short to see the demo launch: the slot-6 timeout costs a million instructions and the loader turns the disk at its real rate; 12M instructions does)");
        end

        // The machine itself, not the ROM's opinion of it.
        if (trace_instrs == 0) fail("the core executed nothing");
        else ok($sformatf("%0d instructions executed and traced", trace_instrs));
        if (mismatches != 0)
            fail($sformatf("the cache's monitor counted %0d mismatches (last %08x)", mismatches, last_mismatch));
        if (late_fills != 0 || fifo_drops != 0)
            fail($sformatf("late fills %0d, drops %0d", late_fills, fifo_drops));
        if (shd_drops != 0)
            fail($sformatf("%0d shadow duplicates were dropped", shd_drops));
        if (ddr_range_bad != 0)
            fail($sformatf("%0d DDR3 addresses outside the image", ddr_range_bad));
        if (cpu_halted) fail("the core executed STP");
        // A COUNTER THAT IS NEVER ASSERTED ON IS NOT A GATE.  This one had
        // been counting every shadow duplicate since the day it was written
        // (docs/GS.md rung 3e part 2); it is a check now.
        if (u_cache.cnt_ppn_clash != 0)
            fail($sformatf("%0d ops reached the cache whose page the directory was never read for (cnt_ppn_clash)",
                           u_cache.cnt_ppn_clash));
        else ok("every op that reached the cache had its own directory read");
        // ---- RUNG 4c: DOES THE CACHE HOLD A LINE IT WAS NEVER GIVEN? ---------
        // The mirror replay found this as a by-product and its oracle had to
        // mask it away: a byte the machine never wrote has no agreed value
        // BETWEEN TWO MODELS, but it has a very definite one HERE - the DDR3
        // stub starts at all zeros (smem's initial), so in the machine's own
        // RAM every byte pg_mask says was never written must still read $00.
        //
        // It is checked in BOTH places on purpose, because that is what tells
        // the two failures apart.  A non-zero byte in a RESIDENT page is the
        // cache holding a previous tenant's bytes: a READ hazard.  A non-zero
        // byte in the DDR3 is worse - the dirty bit is per PAGE and a dirty
        // page flushes WHOLE, so it means a flush has already written another
        // page's bytes over memory the machine owns.
        begin : stale_lines
            integer pg, off, c_bad, d_bad, c_pages, d_pages, shown, res;
            reg [7:0] cb, db;
            reg pgc, pgd;
            c_bad = 0; d_bad = 0; c_pages = 0; d_pages = 0; shown = 0;
            // Physical banks 0 and 1 - the RAM the machine itself has, which
            // is the monitor's contract too.  The ROM's pages are swept above.
            for (pg = 0; pg < 512; pg = pg + 1) begin
                pgc = 1'b0; pgd = 1'b0;
                res = card_resident(16'(pg));
                for (off = 0; off < 256; off = off + 1)
                    if (!wr_ever[16'(pg)][off[7:0]]) begin
                        db = smem[{16'(pg), 8'(off)}];
                        if (db !== 8'h00) begin d_bad = d_bad + 1; pgd = 1'b1; end
                        if (res) begin
                            cb = card_byte(16'(pg), 8'(off));
                            if (cb !== 8'h00) begin
                                c_bad = c_bad + 1; pgc = 1'b1;
                                if (shown < 8) begin
                                    $display("      stale: page $%04X offset $%02X - cache $%02X, DDR3 $%02X, never written; the page took %0d DDR3 line writes",
                                             pg, off, cb, db, wb_lines[16'(pg)]);
                                    shown = shown + 1;
                                end
                            end
                        end
                    end
                if (pgc) c_pages = c_pages + 1;
                if (pgd) d_pages = d_pages + 1;
            end
            $display("    rung 4c, never-written bytes in physical banks 0-1: %0d wrong in the CACHE over %0d pages, %0d wrong in the DDR3 over %0d pages",
                     c_bad, c_pages, d_bad, d_pages);
            // A GATE, not a counter (docs/GS.md rung 4c): zero on a ROM boot
            // and on an eight-million-instruction GS/OS boot, 1690 fills and
            // 665 whole-page flushes.
            if (c_bad != 0 || d_bad != 0)
                fail($sformatf("the cache or the DDR3 holds %0d/%0d bytes in RAM the machine never wrote", c_bad, d_bad));
            else ok("every never-written byte of the machine's RAM is zero, in the cache and in the DDR3");
        end

        // THE SHADOW'S SECOND LANDING, now that the data front posts it
        // itself (rtl/dline.sv, "the shadow duplicate"): every byte the
        // machine wrote into text page 1 of main memory ($0400-$07FF, physical
        // pages $0004-$0007) has its copy in $E0 (pages $E004-$E007) - unless
        // SHADOW[0] inhibits it, which the ROM does not.  Written bytes only:
        // wr_ever is the classified stream, posted writes and duplicates
        // included.
        // ONLY THE BYTES WHOSE LAST WRITE OWED A COPY are compared (wr_text_sh):
        // Arkanoid switches the text shadow while it writes the page, and a
        // byte last written with SHADOW[0] set rightly has none.
        begin : shadow_dup
            integer pg, off, n_cmp, n_bad, n_skip;
            logic [7:0] b0, be;
            n_cmp = 0; n_bad = 0; n_skip = 0;
            begin
                for (pg = 4; pg < 8; pg = pg + 1)
                    for (off = 0; off < 256; off = off + 1)
                        if (wr_ever[16'(pg)][off[7:0]] && !wr_text_sh[pg - 4][off[7:0]]) begin
                            n_skip = n_skip + 1;
                        end else if (wr_ever[16'(pg)][off[7:0]]) begin
                            b0 = card_byte(16'(pg), 8'(off));
                            be = card_byte(16'hE000 | 16'(pg), 8'(off));
                            n_cmp = n_cmp + 1;
                            if (b0 !== be) begin
                                n_bad = n_bad + 1;
                                if (n_bad <= 4)
                                    $display("      shadow: $00/%02X%02X = $%02X but $E0/%02X%02X = $%02X",
                                             pg[7:0], off[7:0], b0, pg[7:0], off[7:0], be);
                            end
                        end
                if (n_cmp == 0)      fail("the boot wrote nothing into text page 1 with the shadow on, so the duplicate was never exercised");
                else if (n_bad != 0) fail($sformatf("%0d of %0d written text-page bytes that owed a copy have none in $E0 (%0d last written with the shadow off, not compared)",
                                                    n_bad, n_cmp, n_skip));
                else ok($sformatf("every written text-page byte that owed a copy (%0d) has it in $E0; %0d last written with the shadow off",
                                  n_cmp, n_skip));
            end
        end

        // ...and the ROM as it now sits in the machine's memory, page by
        // page: a byte read wrong is either a page that went bad or a serve
        // that glitched, and this tells the two apart.
        begin : rom_sweep
            integer bad, k, p0, badpg, res, shown;
            reg [7:0] got;
            bad = 0; badpg = 0; shown = 0;
            for (k = 0; k < 262144; k = k + 256) begin : pg
                integer j, n;
                n = 0;
                for (j = 0; j < 256; j = j + 1) begin
                    got = card_byte(16'hFC00 + 16'(k >> 8), 8'(j));
                    if (got !== rom_img[k + j]) n = n + 1;
                end
                if (n != 0) begin
                    bad = bad + n; badpg = badpg + 1;
                    res = card_resident(16'hFC00 + 16'(k >> 8));
                    if (shown < 6) begin
                        $display("      ROM page $%04X: %0d of 256 bytes wrong, %0s, DDR3 was given %0d line writes",
                                 16'hFC00 + 16'(k >> 8), n,
                                 res ? "RESIDENT in the cache" : "not resident: this is what DDR3 gave back",
                                 wb_lines[16'hFC00 + 16'(k >> 8)]);
                        shown = shown + 1;
                    end
                end
            end
            if (badpg != 0)
                $display("      %0d ROM pages of 1024 are wrong", badpg);
            // How much write-back actually reached the DDR3, against what
            // the flush count says was sent: 16 line writes per flush.
            p0 = 0; res = 0;
            for (k = 0; k < 65536; k = k + 1)
                if (wb_lines[k] != 0) begin p0 = p0 + wb_lines[k]; res = res + 1; end
            $display("      the DDR3 was given %0d line writes over %0d pages; %0d flushes x 16 = %0d",
                     p0, res, mem_flushes, mem_flushes * 16);
            // ...and how much of it the DDR3 behind the cache actually
            // holds.  A ROM page that is only ever resident is lost the
            // moment it is evicted.
            p0 = 0;
            for (k = 0; k < 262144; k = k + 1)
                if (smem[{16'hFC00 + 16'(k >> 8), 8'(k)}] !== rom_img[k]) p0 = p0 + 1;
            $display("    the ROM behind the cache: %0d of 262144 bytes differ from the image", p0);
            if (bad != 0)
                fail($sformatf("%0d of 262144 ROM bytes are no longer the image's in the card's memory", bad));
            else
                ok("the ROM in the card's memory is still the image, all 256 KB");
        end
        if (bad_flush != 0)
            fail($sformatf("%0d bytes were written BACK to the ROM's pages that are not the image's", bad_flush));
        else ok("every write-back of a ROM page carried the image's bytes");
        if (rom_bad != 0)
            fail($sformatf("the core read %0d bytes from banks $FC-$FF that are not the ROM's; first at instruction %0d, %02X/%04X gave $%02X where the image has $%02X",
                           rom_bad, rom_bad_first, rom_bad_at[23:16], rom_bad_at[15:0],
                           rom_bad_got, rom_bad_want));
        else ok("every byte read from banks $FC-$FF was the ROM image's");

        $display("%0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $fclose(tf);
        $finish;
    end
endmodule
