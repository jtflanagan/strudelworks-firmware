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
                    parameter HDVF   = "hdv.hex",
                    parameter integer HDV_BLOCKS = 2880,
                    // 0 when no image was given: the bench still runs the
                    // whole machine and the ROM still scans, it simply finds
                    // an empty slot, so "no block was read" is the expected
                    // outcome rather than a failure.
                    parameter integer HAS_HDV = 0,
                    parameter integer HD_SLOT = 7,
                    parameter integer HOST_DELAY = 2000,
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
                    parameter OPSF  = "",
                    parameter PAGESF = "",
                    parameter ADB_KEYMAP = "adb_keymap.hex",
                    // A key, pressed at an instruction number (docs/GS.md,
                    // ADB_KEY): the ADB keycode, the modifier byte in
                    // $C025's own order, and when.  0 = type nothing.
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
    wire [7:0]  cpu_dout, cpu_din;
    // The census's "this cycle is an instruction fetch" is the 65816's VPA.
    wire        cpu_cyc_is_i = cpu_vpa;

    cpu65816 #(.UCODE_FILE (UCODE), .UCODE0_FILE (UCODE0), .USEQ0_FILE (USEQ0)) u_cpu (
        .clk (clk), .rst (cpu_rst), .cyc_en (cpu_cyc_en),
        .addr (cpu_a24), .rw (cpu_rw), .dout (cpu_dout), .din (cpu_din),
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

    // The fronts are OFF on the GS build (docs/GS.md rung 6 turns them on):
    // everything the core does goes through the dispatcher, so every retire
    // is the dispatcher's and the front-side books are tied still.
    accel_seq #(.GS (1'b1)) u_seq (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .master_active (master_active),
        .mode (mode), .target (target), .cnt_clr (1'b0),
        .q_swi (q_swi), .q_swi_quiet (q_swi_quiet), .swi_byte (swi_byte),
        .swi_commit (swi_commit), .fast_tick (), .fev_quiet (),
        .q_slot (q_slot), .slot_q_o (seq_slot_q), .sl_win (sl_win),
        .stall (1'b0),
        .mem_serve (serve), .mem_image_ready (mem_image_ready), .mem_invalidating (mem_invalidating),
        .q_cls (q_cls),
        .cpu_addr (cpu_addr_eff), .cpu_bank (cpu_bank_eff), .cpu_rw (cpu_rw_eff), .cpu_dout (cpu_dout),
        .cpu_sync (cpu_sync), .cyc_is_i (cpu_cyc_is_i), .cyc_int (cyc_internal),
        .cyc_en (cpu_cyc_en), .cpu_din (cpu_din),
        .turbo_en (), .turbo_ok (),
        .turbo_commit (1'b0), .d_commit (1'b0), .turbo_claim (1'b0),
        .turbo_wr (), .d_pending (1'b0),
        .op_present (op_present), .op_commit (op_commit), .op_dummy (op_dummy), .op_ovr (op_ovr),
        .op_divert (op_divert), .op_sync (drv_sync), .op_addr (op_addr), .op_rw (op_rw),
        .op_wdata (op_wdata), .cyc_done (drv_cyc_done), .drv_din (drv_din),
        .op_inflight (op_inflight), .ovr_en (hd_ovr_en),
        .bus_owns (bus_owns), .core_valid (core_valid),
        .mem_sub_en (mem_sub_en), .mem_sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .mq_valid (1'b0),
        .bus_tick (bus_tick),
        .u_present (u_present), .u_commit (u_commit), .u_addr (u_addr), .u_bank (u_bank),
        .u_rw (u_rw), .u_wdata (u_wdata), .u_sync (u_sync), .u_ovr (u_ovr), .u_divert (u_divert),
        .fev_valid (fev_valid), .fev_addr (fev_addr), .fev_bank (fev_bank), .fev_rw (fev_rw),
        .fev_data (fev_data), .fev_sync (fev_sync),
        .accel_on (accel_on), .held_governor (), .state_o (seq_state), .reset_seq_o (),
        .fast_ops (fast_ops), .map_changed (map_changed), .map_settling (map_settling),
        .maps (accel_maps), .cen_v (), .cen_sel (), .turbo_ops (turbo_ops), .bus_ops (bus_ops),
        .cycles (cycles), .wait_clocks (wait_clocks), .retries (retries)
    );

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
    hd_card u_hd (
        .clk (clk), .rst (rst), .cpu_rst (cpu_rst), .res_sync (res_sync),
        .master_active (master_active), .slot_assign (3'(HD_SLOT)),
        .op_addr (op_addr), .op_rw (op_rw), .op_present (op_present),
        .op_commit (op_commit), .op_ovr (op_ovr), .din (drv_din),
        .ovr_en (hd_ovr_en), .ovr_addr (hd_ovr_addr), .ovr_rw (hd_ovr_rw),
        .ovr_wdata (hd_ovr_wdata),
        .rd_claim (hd_rd_claim), .rd_data (hd_rd_data),
        .msg_valid (hmsg_valid), .msg_type (hmsg_type), .msg_free (hmsg_free),
        .msg_len (hmsg_len), .pay_data (hpay_data), .pay_valid (hpay_valid),
        .tx_word (hd_tx_word), .tx_valid (hd_tx_valid), .tx_take (hd_tx_valid),
        .rom_loaded (hd_rom_loaded), .busy (hd_busy), .execs (hd_execs), .exec_q (hd_exec_q)
    );
    wire        hd_ovr_en, hd_ovr_rw;
    wire [15:0] hd_ovr_addr;
    wire [7:0]  hd_ovr_wdata;

    // ---- the memory path, on the unified stream ----------------------------------
    wire        cl_valid, cl_rw, cl_wr_image, cl_aux, cl_posted, cl_sh, intc8rom;
    wire [1:0]  cl_cls;
    wire [7:0]  cl_bank, cl_wdata, shd_drops;
    wire [15:0] cl_off, pf_off, cl_ppn_w, pf_ppn_w;
    wire [11:0] sw_state;
    wire [7:0]  rw_bank, rwb_p1_w;
    wire        rom_loaded, invalidating, image_ready, refresh_ok, rot_ok, mem_idle;
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
        .pw_valid (rl_pw_valid), .pw_ppn (rl_pw_ppn), .pw_off (rl_pw_off),
        .pw_data (rl_pw_data), .pw_ready (pw_ready_w), .pw_take (pw_take_w),
        .shd_take_o (shd_take_w), .shd_ppn_o (shd_ppn_w), .shd_off_o (shd_off_w),
        .pf_off (pf_off),
        .sw_state (sw_state), .vid_sw (), .rw_bank (rw_bank),
        .gs_shadow_o (gs_shadow_w), .gs_cyareg_o (gs_cyareg_w),
        .gs_sltrom_o (gs_sltrom_w), .gs_state_o (gs_state_w),
        .q_addr ({cpu_bank_eff, nxt_addr}), .q_divert (q_divert), .q_rw (cpu_rw_eff), .q_cls (q_cls),
        // Nothing is internalized on the GS build yet: $C0xx is BUS class and
        // rides a real cycle until rtl/gs_io.sv answers it (rung 3b).
        .swi_on (1'b0), .swi_kbd_ok (1'b0), .swi_fb_ok (1'b0),
        .swi_vbl_ok (1'b0), .swi_vbl_bar (1'b1), .swi_kbd_low (7'd0),
        .swi_pb_ok (1'b0), .swi_pdl_ok (1'b0),
        .swi_hd_slot (3'd0), .swi_fd_slot (3'd0), .swi_mb_slot (3'd0),
        .swi_mouse_slot (3'd0), .swi_u2_slot (3'd0), .swi_prn_slot (3'd0),
        .q_nsc (), .q_slot (q_slot), .q_swi (q_swi_mmu), .q_swi_quiet (q_swi_quiet),
        .swi_stat_byte (mmu_swi_stat),
        .p_addr (24'd0), .p_cls (p_cls), .p_aux (p_aux_w), .p_off (p_off_w),
        .d_addr (24'd0), .d_rw (1'b1), .d_cls (dcls_w), .d_aux (daux_w), .d_off (doff_w),
        .map_changed (map_changed),
        .cl_ppn (cl_ppn_w), .pf_ppn (pf_ppn_w),
        .p_ppn (p_ppn_w), .p_reg (p_reg_w), .p_fold (p_fold_w), .p_fs (p_fs_w),
        .d_ppn (d_ppn_w), .d_reg (d_reg_w), .d_fold (d_fold_w),
        .map_settling (map_settling), .rt_rd_flat (rt_rd_flat), .rwb_p1 (rwb_p1_w)
    );

    // ---- the IIgs chipset on $C0xx ------------------------------------------------
    // One instance, two claims: `claim` off the LIVE address for the
    // dispatcher's decision, and `u_claim` off the REGISTERED op for the byte
    // mux (rtl/gs_io.sv, "the two faces of an op").
    gs_io #(.adb_keymap (ADB_KEYMAP)) u_gsio (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .q_addr ({cpu_bank_eff, nxt_addr}), .q_rw (cpu_rw_eff), .claim (gsio_claim),
        .u_bank (u_bank), .u_addr (u_addr), .u_rw (u_rw), .u_wdata (u_wdata),
        .u_commit (swi_commit),
        .gs_shadow (gs_shadow_w), .gs_cyareg (gs_cyareg_w),
        .gs_sltrom (gs_sltrom_w), .gs_state (gs_state_w),
        .stat_byte (mmu_swi_stat), .vbl (vbl_active),
        // PINNED TO KEGS's OWN CLOCK.  tools/kegs/trace_rom.sh runs the
        // reference with -pintime 3871713600 (2026-09-08 12:00:00 since
        // 1904) so its trace is the same every run; the card must believe the
        // same seconds or the two disagree about a byte the ROM checksums.
        .seed_time (SEED_TIME), .border (),
        // The battery RAM the host ships, sent before RES' is released.
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (16'd0),
        .msg_len (msg_len),
        .pay_data (pay_data), .pay_valid (pay_valid), .bram_ok (bram_landed),
        // The IIe's own keyboard (rtl/gs_kbd_a2.sv) is a TOP-LEVEL wiring:
        // it feeds on the driver's parked dummy cycles, and this bench has no
        // driver and no backplane.  sim/gs_kbd_a2_tb.sv drives it from a
        // model IOU instead.  Quiet here, so the reference trace is unmoved.
        .loc_valid (1'b0), .loc_code (7'd0), .loc_up (1'b0),
        .loc_mods (8'd0), .live_mods (8'd0),

        .frame_tick (frame_tick),
        .u_claim (gsio_u_claim), .rd_byte (gsio_byte), .irq (gsio_irq)
    );

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
        .pw_data (rl_pw_data), .pw_take (pw_take_w),
        .busy (rom_busy), .overruns (rom_overruns), .rom_ok (rom_loaded)
    );

    page_cache u_cache (
        .clk (clk), .rst (rst),
        .cl_valid (cl_valid), .cl_cls (cl_cls), .cl_ppn (cl_ppn_w), .cl_off (cl_off[7:0]),
        .cl_rw (cl_rw), .cl_wr_image (cl_wr_image), .cl_wdata (cl_wdata), .cl_posted (cl_posted),
        .pw_pending (1'b0), .pw_ready (pw_ready_w),
        .pf_ppn (pf_ppn_w), .pf_off (pf_off[7:0]),
        .pw_take (pw_take_w), .pw_ppn (rl_pw_ppn), .pw_off (rl_pw_off),
        .shd_take (shd_take_w), .shd_ppn (shd_ppn_w), .shd_off (shd_off_w),
        .op_addr (u_addr),
        .op_present (u_present), .op_commit (u_commit), .op_divert (u_divert), .data_sync (data_sync),
        .sub_en (mem_sub_en), .sub_data (mem_sub_data), .decided (decided), .busy (busy),
        .mw_stb (), .mw_addr (), .mw_byte (),
        .il_req (1'b0), .il_ppn (16'd0), .il_line (4'd0), .il_src (1'b0),
        .il_ack (), .il_done (), .il_ok (), .il_row (),
        .serve (serve), .inval (1'b0), .cnt_clr (1'b0), .image_ready (image_ready),
        .invalidating (invalidating),
        .hits (hits), .misses (misses), .served (served), .mismatches (mismatches),
        .last_mismatch (last_mismatch), .diverted (diverted), .late_fills (late_fills),
        .fifo_drops (fifo_drops),
        .mem_fills (mem_fills), .mem_flushes (mem_flushes), .mem_declines (mem_declines),
        .pq_busy (pq_busy), .pq_valid (pq_valid), .pq_we (pq_we),
        .pq_line (pq_line), .pq_wdata (pq_wdata), .pq_ready (pq_ready),
        .pr_valid (pr_valid), .pr_data (pr_data)
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
        .refresh_ok (refresh_ok), .rot_ok (rot_ok), .mem_idle (mem_idle),
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
            dl_time[dl_wp % DL] <= now + 12;
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
    reg        hm_armed;
    reg [15:0] hm_memblock [0:8];       // 8 = the controller's
    reg [23:0] hm_diskblock [0:8];
    reg [7:0]  hm_uerr [0:8];
    task hm_clear;
        integer k;
        begin
            hm_cmd = 0; hm_fifo = 0; hm_sc = 0; hm_armed = 0;
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
                        if (r >= 0) hm_diskblock[r] = {hm_diskblock[r][23:8], d};
                    end else hm_sc = d;
                end
                8'h7: if (r >= 0) hm_diskblock[r] = {hm_diskblock[r][23:16], d, hm_diskblock[r][7:0]};
                8'h8: if ((hm_cmd & 8'h80) != 0 && r >= 0)
                          hm_diskblock[r] = {d, hm_diskblock[r][15:0]};
                default: ;
            endcase
            if (r >= 0 && (hm_cmd & 8'h80) == 0) hm_diskblock[r] = hm_diskblock[r] & 24'h00FFFF;
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
    reg [15:0] q_mem [0:QN-1];
    reg [23:0] q_disk [0:QN-1];
    integer    q_at [0:QN-1];
    reg [7:0]  q_blk [0:QN-1][0:511];
    integer    qw = 0, qr = 0;
    integer    host_execs = 0, host_reads = 0, host_writes = 0, host_statuses = 0;
    // The block most recently DMA'd in, waiting to be checked: see the
    // EXECUTE below and the checker under card_byte.
    reg        pend_valid = 1'b0, chk_go = 1'b0;
    reg [15:0] pend_addr = 16'd0;
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
                q_unit[qw % QN] = u; q_sc[qw % QN] = hm_sc; q_at[qw % QN] = now;
                if (u != UNIT_NONE) begin
                    r = (u == UNIT_CTL) ? 8 : u;
                    q_mem[qw % QN] = hm_memblock[r];
                    q_disk[qw % QN] = hm_diskblock[r];
                    // BLOCK WRITES ARE NOT MODELLED HERE.  boot_tb captures
                    // the block from its reference memory, which this bench
                    // does not keep - the ROM's boot only reads, so rather
                    // than write zeros over the image and call it a pass,
                    // this fails loudly and rung 3e can model it when GS/OS
                    // needs it.
                    if (hm_cmd == CMD_BLK_WRITE || hm_cmd == CMD_SP_WRITE)
                        fail("a block WRITE was issued: this bench does not model one");
                    hm_cmd = (hm_cmd & 8'h80) ? CMD_SP_BUSY : CMD_BLK_STATUS;
                    hm_fifo = 0;
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
        end
    endtask
    // The Ensoniq's state (rtl/gs_doc.sv, docs/GS.md rung 7): which
    // oscillators the machine left running, how they are configured, and how
    // busy the interrupt queue is.  A pair handing back and forth over dead
    // wave tables, or a queue that never empties, shows here.
    integer dj;
    task dump_doc;
        begin
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

    function automatic bit dma_hits_io(input [15:0] a, input integer len);
        integer k;
        begin
            dma_hits_io = 0;
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
    task automatic push_done(input [7:0] status, input [15:0] addr, input [15:0] size16);
        integer k;
        reg [31:0] w;
        begin
            if (ans_n == 0) push_word(hdr(T_HD_DONE, 8'd0, {8'd0, status}));
            else begin
                push_word(hdr(T_HD_DONE, 8'(2 + (ans_n + 3) / 4), {8'd0, status}));
                push_word({16'(ans_n), addr});
                push_word({16'd0, size16});
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
        reg [7:0] cmd, sc, err, unum;
        reg [15:0] memblock, size16;
        reg [23:0] diskblock;
        begin
            cmd = q_cmd[qr % QN]; unum = q_unum[qr % QN]; u = q_unit[qr % QN];
            sc = q_sc[qr % QN]; memblock = q_mem[qr % QN]; diskblock = q_disk[qr % QN];
            ans_n = 0;
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
                                        if (sc == 8'h03) begin
                                            id_string($sformatf("STRUDELWORKS D#%0d", unum));
                                            ans[ans_n] = 8'h02; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h20; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h01; ans_n = ans_n + 1;
                                            ans[ans_n] = 8'h00; ans_n = ans_n + 1;
                                        end
                                    end
                                    default: err = ERR_BADCTL;
                                endcase
                            end
                            if (err == ERR_OK && dma_hits_io(memblock, ans_n)) err = ERR_BADCTL;
                            if (err != ERR_OK) ans_n = 0;
                            hm_uerr[r] = err;
                            push_done(status_byte(err), memblock, size16);
                        end
                        CMD_BLK_READ, CMD_SP_READ: begin
                            if (diskblock >= HDV_BLOCKS || dma_hits_io(memblock, 512)) begin
                                err = ERR_IO; ans_n = 0;
                                $display("    disk: REFUSED block %0d -> $%04X (%0s) at instruction %0d",
                                         diskblock, memblock,
                                         (diskblock >= HDV_BLOCKS) ? "past the end of the image"
                                                                   : "the DMA would cross the I/O page",
                                         trace_instrs);
                            end else begin
                                base = diskblock * 512;
                                for (k = 0; k < 512; k = k + 1) begin ans[k] = himg[base + k]; end
                                ans_n = 512;
                                hd_blocks_read = hd_blocks_read + 1;
                                $display("    disk: READ block %0d -> $%04X at instruction %0d",
                                         diskblock, memblock, trace_instrs);
                                host_reads = host_reads + 1;
                                pend_addr = memblock; pend_blk = diskblock;
                                pend_b2 = sw_state[8]; pend_azp = sw_state[3];
                                pend_dirty = 1'b0;
                                pend_valid = 1'b1;
                            end
                            hm_uerr[r] = err;
                            push_done(status_byte(err), memblock, size16);
                        end
                        CMD_BLK_WRITE, CMD_SP_WRITE: begin
                            if (diskblock >= HDV_BLOCKS || dma_hits_io(memblock, 512)) begin
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
            if (qr < qw && (now - q_at[qr % QN]) >= HOST_DELAY && u_hd.st == u_hd.S_IDLE)
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
    initial if (KEY_AT != 0) begin : typist
        wait (trace_instrs >= KEY_AT);
        send_key(7'(KEY_CODE), 1'b0, 8'(KEY_MODS));
        keys_sent = keys_sent + 1;
        if (u_gsio.u_adb.kbd_buf[0][7] !== 1'b1)
            fail("the key went down and $C000's strobe did not set");
        else
            ok($sformatf("keycode $%02X reached the keyboard: $C000 reads $%02X, $C025 $%02X",
                         KEY_CODE, u_gsio.u_adb.kbd_buf[0], u_gsio.u_adb.c025_val));
        repeat (KEY_HOLD) @(negedge clk);
        send_key(7'(KEY_CODE), 1'b1, 8'(KEY_MODS));
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
    task verify_landed(input [15:0] addr, input integer blk);
        integer k, bad, first;
        reg [7:0] got;
        begin
            bad = 0; first = -1;
            for (k = 0; k < 512; k = k + 1) begin
                got = card_byte(land_ppn(16'(addr + k), pend_b2, pend_azp),
                                8'(16'(addr + k)));
                if (got !== himg[blk * 512 + k]) begin
                    bad = bad + 1;
                    if (first < 0) first = k;
                end
            end
            if (bad != 0)
                fail($sformatf("block %0d did not land at $%04X: %0d of 512 bytes wrong, first at +%0d (got $%02X, want $%02X)",
                               blk, addr, bad, first,
                               card_byte(land_ppn(16'(addr + first), pend_b2, pend_azp),
                                         8'(16'(addr + first))),
                               himg[blk * 512 + first]));
            else
                blocks_verified = blocks_verified + 1;
        end
    endtask
    // The machine writing into the block it was just given.
    always @(posedge clk)
        if (boot_go && pend_valid && u_present && !u_rw && !u_ovr &&
            u_bank == 8'h00 &&
            u_addr >= pend_addr && u_addr <= (pend_addr + 16'd511))
            pend_dirty <= 1'b1;

    always @(posedge clk) if (chk_go) begin
        chk_go = 1'b0;
        if (pend_dirty) blocks_touched = blocks_touched + 1;
        else            verify_landed(pend_addr, pend_blk);
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
        push_word(hdr(T_HD_ROM, 8'd64, 16'd0));
        for (c = 0; c < 64; c = c + 1)
            push_word({hd_rom[4*c+3], hd_rom[4*c+2], hd_rom[4*c+1], hd_rom[4*c]});
        c = 0;
        while (!hd_rom_loaded && c < 2000) begin @(posedge clk); c = c + 1; end
        if (!hd_rom_loaded) begin
            fail("the slot ROM did not load");
            $display("    rx_wr %0d rx_rd %0d unknowns %0d", rx_wr, rx_rd, unknowns);
        end else ok("the slot-7 SmartPort ROM loaded");

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
        $display("    counters: fast_ops %0d bus_ops %0d cycles %0d maps %0d retries %0d",
                 fast_ops, bus_ops, cycles, accel_maps, retries);
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
                ok($sformatf("%0d blocks landed intact where the machine looks for them (%0d the machine had already written to)",
                             blocks_verified, blocks_touched));
        end
        $display("    parked %0d internal cycles: %0d would have written, %0d would have hit $C0xx",
                 internal_cycles, internal_writes, internal_io);

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
