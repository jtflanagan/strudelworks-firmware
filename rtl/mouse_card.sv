`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mouse_card - an AppleMouse II interface card on the card that IS the CPU,
// with the mouse on the host.
//
// The AppleMouse II card is a 6821 PIA and a 68705 microcontroller behind a
// 2 KB firmware ROM.  The 6502 talks only to the PIA: four registers at
// DEVICE SELECT ($C0n0-$C0n3, A2-A3 undecoded), port A carrying a byte each
// way and port B the handshake - the firmware clocks a command byte into the
// 68705 with PB5, reads answer bytes out with PB4, and switches the ROM's
// 256-byte page into I/O SELECT ($Cn00-$CnFF) with PB1-PB3.  The 68705 keeps
// the mouse itself: position, the clamps, the mode byte, the status byte, and
// the interrupt it raises on movement, a button, or its own 60 Hz timer.
//
// This module is AppleWin's model of that (source/MouseInterface.cpp and
// 6821.cpp, the project's reference) written as gateware: the PIA's
// registers, the byte protocol on port B, the command set - SET, READ, SERV,
// CLEAR, POS, INIT, CLAMP, HOME, TIME - and the interrupt rules, including
// the one that matters most and is easiest to get wrong: READMOUSE clears the
// status byte's interrupt bits but NOT the IRQ line; only SERVEMOUSE releases
// it (AppleWin's "abnormal operation" note).  The one thing on the host is the
// physical mouse: the Pi's, whose motion and buttons arrive as MOUSE_MOVE
// messages - a signed delta pair and the button levels - and are applied here
// exactly as AppleWin's SetPositionRel/SetButton would, clamps and all.
//
// WHERE IT HANGS: on the peripherals' view of the op stream, like the
// Mockingboard (rtl/mockingboard.sv, docs/CXXX.md "The on-card slots") - the
// driver's presented op on the bus, the unified op for an internalized access
// in the closed regime.  A claimed read's byte goes back through
// apple_bus_write's data window; the slot is gated by rtl/slot_switches.sv
// for the ROM page (INTCXROM, SLOTC3ROM) and never for the device-select
// registers, which is the IIe's own rule.  IRQ takes the Mockingboard's short
// route into the soft core (master_top folds it into irq_n).  The card only
// exists while the soft core masters: with the native 6502 driving nothing
// can answer at the peripheral's tap.
//
// THE 60 Hz: the real card's VBL interrupt is the 68705's own timer, not the
// video scanner's blanking (that is why the firmware has a "50 Hz" command),
// so it is a free-running counter here too - of the CORE's cycles, like the
// VIAs' clocks, so a program's frame interrupts come at the core's pace under
// acceleration and at exactly 60 Hz of machine time at 1x, locked video or
// not.  17030 cycles a frame at 60 Hz, 20280 at 50 Hz.
//
// THE ROM: 2 KB the HOST loads (MOUSE_ROM, eight 64-word chunks; nothing in
// the gateware knows what the firmware looks like), read a byte at a time by
// page and address - distributed RAM so the byte is combinational off the
// presented address and registered at present, the same timing the VidHD's
// and the Mockingboard's answers have.  Block RAM would save the LUTs at the
// cost of a clock of latency the fast-op decision does not have to spare.
//
// ACROSS CLOCKS: nothing here is combinational from the bus to the state.
// The PIA access lands its registers at the commit and latches a port B
// event; the 68705's step runs from that latch on the NEXT clock; a host
// move goes through an add clock and a clamp clock (a CLAMP command's
// re-clamp takes the same two); and the interrupt decision runs a clock
// after whichever of those changed the state, from registered values
// only, never on a clock the 68705 is stepping.  A first cut did all of
// it in one clock and missed 100 MHz by 7 ns (17 ns, 29 levels from the
// driver's data byte to the status flop); the user's rule for this card
// is that a few clocks of latency on an event source this slow are
// invisible, and they are: a program cannot read the PIA again within a
// clock of writing it (the instruction fetches between take at least
// one each), and the mouse itself moves once a millisecond.
//
// WHAT THIS CARD NEVER DOES: take a bus cycle, or drive one it did not claim.
//
// RESET: the card's reset clears everything, the ROM included; RES' resets
// the PIA and the 68705's state, as the slot's RES pin does, and keeps the
// ROM.
//////////////////////////////////////////////////////////////////////////////////
module mouse_card #(
    parameter [7:0] T_MOUSE_MOVE = 8'h25,
    parameter [7:0] T_MOUSE_ROM  = 8'h26
) (
    input  wire        clk,
    // The CARD's reset: everything.
    input  wire        rst,
    // Synchronised RES', ACTIVE LOW.
    input  wire        res_sync,
    // 1 while the soft core owns the bus.  Nothing here exists otherwise.
    input  wire        master_active,
    // Which slot to answer as; 0 disables.  Latched at RES' by wb_regfile.
    input  wire [2:0]  slot_assign,
    // The presented op (the peripherals' view): stable from op_present
    // through op_commit.  op_ovr says the op was an override rather than the
    // core's; op_dummy that the cycle carried no op.
    input  wire [15:0] op_addr,
    input  wire        op_rw,          // 1 = read
    input  wire [7:0]  op_wdata,
    input  wire        op_present,     // pulse: a new op has been presented
    input  wire        op_commit,      // pulse: the cycle's data phase
    input  wire        op_dummy,
    input  wire        op_ovr,
    // A fast op of the accelerated core completed: a tick of the core's
    // time that the bus never saw.
    input  wire        fast_tick,
    // A claimed READ cycle and the byte to emit.  Registered at op_present.
    output logic       rd_claim,
    output logic [7:0] rd_data,
    // Host -> card messages, as ft601_msg_rx decodes them.
    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    input  wire [15:0] msg_free,
    input  wire [7:0]  msg_len,
    input  wire [31:0] pay_data,
    input  wire        pay_valid,
    // ACTIVE HIGH, for the top to fold into the soft core's irq_n.
    output wire        irq,
    // For the register's readback.
    output wire        rom_loaded,
    output wire [15:0] pos_x,
    output wire [15:0] pos_y,
    output wire [3:0]  mode_rd,
    output wire [1:0]  buttons_rd,
    output wire [7:0]  moves_rd
);
    // ---- the commands and the bits, AppleWin's names ------------------------
    localparam [7:0] MOUSE_SET   = 8'h00;
    localparam [7:0] MOUSE_READ  = 8'h10;
    localparam [7:0] MOUSE_SERV  = 8'h20;
    localparam [7:0] MOUSE_CLEAR = 8'h30;
    localparam [7:0] MOUSE_POS   = 8'h40;
    localparam [7:0] MOUSE_INIT  = 8'h50;
    localparam [7:0] MOUSE_CLAMP = 8'h60;
    localparam [7:0] MOUSE_HOME  = 8'h70;
    localparam [7:0] MOUSE_TIME  = 8'h90;

    localparam [7:0] STAT_PREV_BUTTON1 = 8'h01;
    localparam [7:0] STAT_INT_MOVEMENT = 8'h02;
    localparam [7:0] STAT_INT_BUTTON   = 8'h04;
    localparam [7:0] STAT_INT_VBL      = 8'h08;
    localparam [7:0] STAT_CURR_BUTTON1 = 8'h10;
    localparam [7:0] STAT_MOVED        = 8'h20;   // X/Y moved since the last READMOUSE
    localparam [7:0] STAT_PREV_BUTTON0 = 8'h40;
    localparam [7:0] STAT_CURR_BUTTON0 = 8'h80;
    localparam [7:0] STAT_INT_ALL      = STAT_INT_VBL | STAT_INT_BUTTON | STAT_INT_MOVEMENT;

    localparam [3:0] MODE_ON       = 4'h1;
    localparam [3:0] MODE_INT_VBL  = 4'h8;
    localparam [3:0] MODE_INT_ALL  = 4'hE;

    localparam [14:0] FRAME_60 = 15'd17030;
    localparam [14:0] FRAME_50 = 15'd20280;

    // ---- what this card answers as -------------------------------------------
    wire enabled = master_active && (slot_assign != 3'd0) && rom_loaded;

    wire io_select;
    slot_switches u_sw (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_addr (op_addr), .op_rw (op_rw), .op_commit (op_commit),
        .slot (slot_assign),
        .io_select (io_select)
    );

    // ---- the ROM ----------------------------------------------------------------
    // 512 words: eight 256-byte pages, the page from port B (below).
    logic [31:0] rom [0:511];
    logic [7:0]  rom_have;              // one bit per chunk landed
    assign rom_loaded = &rom_have;

    // ---- the state ----------------------------------------------------------------
    // The PIA (VICE's mc6821 as AppleWin carries it).
    logic [7:0] pra, ddra, cra, prb, ddrb, crb;
    logic [7:0] ia, ib;                 // what the 68705 presents on each port
    // The port B event the access latched for the 68705's step next clock.
    logic       pb_pend;
    logic [7:0] pb_data;
    // The 68705's side.
    logic [7:0]  a6821, b6821;          // the last port A byte, its own port B bits
    logic [7:0]  buff [0:7];            // buff[0] the command
    logic [3:0]  buffpos, datalen;
    logic [3:0]  mode;
    logic [7:0]  stat;
    logic signed [17:0] ix, iy;         // the position; always 0..$FFFF once settled
    logic [15:0] nx, ny;                // the position as READMOUSE last latched it
    logic [15:0] minx, maxx, miny, maxy;
    logic        btn0, btn1;            // the buttons as READMOUSE last latched them
    logic        but0, but1;            // the buttons as the host holds them
    logic        irq_q;
    logic [14:0] frame_ctr;
    logic        frame_50;
    logic [7:0]  moves;
    // The move pipeline: the host's deltas pending, the sum before its
    // clamp, and the flags between the stages.
    logic signed [19:0] dx_pend, dy_pend;
    logic [1:0]  btn_pend, btn_plus;
    logic        mv_pend, reclamp, settling, ev_pend, vbl_pend;
    logic signed [19:0] ix_plus, iy_plus;

    assign irq        = enabled && irq_q;
    assign pos_x      = ix[15:0];
    assign pos_y      = iy[15:0];
    assign mode_rd    = mode;
    assign buttons_rd = {but1, but0};
    assign moves_rd   = moves;

    wire [2:0]  rom_page = b6821[3:1];
    wire [31:0] rom_word = rom[{rom_page, op_addr[7:2]}];
    wire [7:0]  rom_byte = rom_word[8 * op_addr[1:0] +: 8];

    // ---- decode ------------------------------------------------------------------
    wire hit_page = enabled && !op_ovr && io_select &&
                    (op_addr[15:8] == {4'hC, 1'b0, slot_assign});
    wire hit_dev  = enabled && !op_ovr &&
                    (op_addr[15:8] == 8'hC0) && op_addr[7] && (op_addr[6:4] == slot_assign);

    logic hit_dev_q, hit_page_q;

    // The PIA's read data, combinational off the presented address.
    wire [7:0] pia_rd = (op_addr[1:0] == 2'd0) ? (cra[2] ? ((pra & ddra) | (ia & ~ddra)) : ddra)
                      : (op_addr[1:0] == 2'd1) ? cra
                      : (op_addr[1:0] == 2'd2) ? (crb[2] ? ((prb & ddrb) | (ib & ~ddrb)) : ddrb)
                      :                          crb;

    // ---- host -> card messages ---------------------------------------------------
    logic [7:0]  rx_type;
    logic [7:0]  rx_idx;
    logic [7:0]  rx_left;
    logic [2:0]  rx_chunk;
    logic [1:0]  rx_buttons;
    wire rx_hdr  = msg_valid;
    wire rx_word = pay_valid && (rx_left != 8'd0);
    wire hdr_rom  = rx_hdr && (msg_type == T_MOUSE_ROM);
    wire hdr_move = rx_hdr && (msg_type == T_MOUSE_MOVE);
    wire word_rom  = rx_word && (rx_type == T_MOUSE_ROM);
    wire word_move = rx_word && (rx_type == T_MOUSE_MOVE) && enabled;
    wire signed [15:0] mv_dx = pay_data[15:0];
    wire signed [15:0] mv_dy = pay_data[31:16];

    // The ROM, written on its own so nothing with a reset shares its block.
    always_ff @(posedge clk) begin
        if (word_rom) rom[{rx_chunk, rx_idx[5:0]}] <= pay_data;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_type    <= 8'd0;
            rx_idx     <= 8'd0;
            rx_left    <= 8'd0;
            rx_chunk   <= 3'd0;
            rx_buttons <= 2'd0;
            rom_have   <= 8'd0;
        end else begin
            if (rx_hdr) begin
                rx_type    <= msg_type;
                rx_idx     <= 8'd0;
                rx_left    <= msg_len;
                rx_chunk   <= msg_free[2:0];
                rx_buttons <= msg_free[1:0];
                // A ROM chunk is only one if it is a whole chunk; a move is
                // one word.
                if (hdr_rom  && msg_len != 8'd64) rx_type <= 8'd0;
                if (hdr_move && msg_len != 8'd1)  rx_type <= 8'd0;
            end else if (rx_word) begin
                rx_idx  <= rx_idx + 8'd1;
                rx_left <= rx_left - 8'd1;
                if (word_rom && rx_left == 8'd1) rom_have[rx_chunk] <= 1'b1;
            end
        end
    end

    // ---- the core's clock and the frame timer -----------------------------------
    wire tick = enabled && ((op_commit && !op_dummy) || fast_tick);
    wire frame_end = tick && (frame_ctr == (frame_50 ? FRAME_50 : FRAME_60) - 15'd1);

    wire dev_commit = op_commit && hit_dev_q;
    wire dev_write  = dev_commit && !op_rw;
    wire dev_read   = dev_commit &&  op_rw;

    // RES' resets the PIA and the 68705's state (AppleWin's Reset), the
    // card's reset too; the ROM is the card's reset's alone (above).
    wire state_reset = rst || !res_sync || !enabled;

    // ---- stage 1: the PIA access, at the commit --------------------------------
    // The registers as the 6502 wrote them, and the port B event - the
    // byte the 68705 sees, DDR applied - latched for next clock's step.
    always_ff @(posedge clk) begin
        if (state_reset) begin
            pra <= 8'd0; ddra <= 8'd0; cra <= 8'd0;
            prb <= 8'd0; ddrb <= 8'd0; crb <= 8'd0;
            a6821 <= 8'd0;
            pb_pend <= 1'b0; pb_data <= 8'd0;
        end else begin
            pb_pend <= 1'b0;
            if (dev_read) begin
                // Reading a data port clears that side's interrupt flags.
                if (op_addr[1:0] == 2'd0 && cra[2]) cra[7:6] <= 2'b00;
                if (op_addr[1:0] == 2'd2 && crb[2]) crb[7:6] <= 2'b00;
            end
            if (dev_write) begin
                case (op_addr[1:0])
                    2'd0: begin
                        if (cra[2]) begin
                            pra <= op_wdata;
                            if (ddra != 8'd0) a6821 <= op_wdata & ddra;
                        end else if (op_wdata != ddra) begin
                            ddra <= op_wdata;
                            if (op_wdata != 8'd0) a6821 <= pra & op_wdata;
                        end
                    end
                    2'd1: cra <= op_wdata;
                    2'd2: begin
                        if (crb[2]) begin
                            prb <= op_wdata;
                            if (ddrb != 8'd0) begin pb_pend <= 1'b1; pb_data <= op_wdata & ddrb; end
                        end else if (op_wdata != ddrb) begin
                            ddrb <= op_wdata;
                            if (op_wdata != 8'd0) begin pb_pend <= 1'b1; pb_data <= prb & op_wdata; end
                        end
                    end
                    2'd3: crb <= op_wdata;
                endcase
            end
        end
    end

    // ---- stage 2: the 68705's step, and the interrupt decision ---------------------
    // AppleWin's On6821_B from the latched event, one clock after the
    // access; OnMouseEvent from the flags, on a clock the 68705 is NOT
    // stepping, from registered state alone.  `*_n` is the state after.
    logic [7:0] ia_n, ib_n, b6821_n;
    logic [7:0] buff_n [0:7];
    logic [3:0] buffpos_n, datalen_n, mode_n;
    logic [7:0] stat_n;
    logic signed [17:0] ix_n, iy_n;
    logic [15:0] nx_n, ny_n, minx_n, maxx_n, miny_n, maxy_n;
    logic btn0_n, btn1_n, irq_n, frame_50_n, reclamp_n, pos_set, ev_taken;

    // AppleWin's SetClampX/Y: min above max folds to 0..(min+max).
    function automatic [31:0] fold_clamp(input [15:0] lo, input [15:0] hi);
        begin
            if (lo > hi) fold_clamp = {16'd0, lo + hi};
            else         fold_clamp = {lo, hi};
        end
    endfunction

    // ClampX/Y on a 20-bit signed sum against 16-bit unsigned bounds.
    function automatic signed [17:0] clamp(input signed [19:0] p, input [15:0] lo, input [15:0] hi);
        begin
            if (p > $signed({4'b0000, hi}))      clamp = $signed({2'b00, hi});
            else if (p < $signed({4'b0000, lo})) clamp = $signed({2'b00, lo});
            else                                 clamp = p[17:0];
        end
    endfunction

    always_comb begin : step
        logic [7:0]  b_new, diff, cmd, ev;
        logic [3:0]  pos, npos, dlen;
        logic [15:0] c_lo, c_hi;
        logic [31:0] folded;
        integer i;

        ia_n = ia; ib_n = ib; b6821_n = b6821;
        for (i = 0; i < 8; i = i + 1) buff_n[i] = buff[i];
        buffpos_n = buffpos; datalen_n = datalen; mode_n = mode; stat_n = stat;
        ix_n = ix; iy_n = iy; nx_n = nx; ny_n = ny;
        minx_n = minx; maxx_n = maxx; miny_n = miny; maxy_n = maxy;
        btn0_n = btn0; btn1_n = btn1;
        irq_n = irq_q; frame_50_n = frame_50; reclamp_n = reclamp;
        pos_set = 1'b0; ev_taken = 1'b0;

        // ---- the 68705's side of port B (AppleWin's On6821_B) -------------------
        if (pb_pend) begin
            diff = (b6821 ^ pb_data) & 8'h3E;
            if (diff != 8'd0) begin
                b_new = (b6821 & ~8'h3E) | (pb_data & 8'h3E);
                pos = buffpos; dlen = datalen;
                if (diff[5]) begin
                    if (pb_data[5]) begin
                        b_new[7] = 1'b1;            // ready to be read by the PIA
                    end else begin
                        // Clock activate: the 6502's byte on port A lands.
                        cmd = (pos == 4'd0) ? a6821 : buff[0];
                        buff_n[pos[2:0]] = a6821;
                        npos = pos + 4'd1;
                        if (pos == 4'd0) begin
                            // OnCommand
                            case (cmd & 8'hF0)
                                MOUSE_SET: begin
                                    dlen = 4'd1;
                                    mode_n = cmd[3:0];
                                end
                                MOUSE_READ: begin
                                    dlen = 4'd6;
                                    stat_n = stat & STAT_MOVED;
                                    nx_n = ix[15:0];
                                    ny_n = iy[15:0];
                                    if (btn0) stat_n = stat_n | STAT_PREV_BUTTON0;
                                    if (btn1) stat_n = stat_n | STAT_PREV_BUTTON1;
                                    btn0_n = but0;
                                    btn1_n = but1;
                                    if (but0) stat_n = stat_n | STAT_CURR_BUTTON0;
                                    if (but1) stat_n = stat_n | STAT_CURR_BUTTON1;
                                    buff_n[1] = ix[7:0];
                                    buff_n[2] = ix[15:8];
                                    buff_n[3] = iy[7:0];
                                    buff_n[4] = iy[15:8];
                                    buff_n[5] = stat_n;
                                    stat_n = stat_n & ~STAT_MOVED;
                                end
                                MOUSE_SERV: begin
                                    dlen = 4'd2;
                                    buff_n[1] = stat & ~STAT_MOVED;   // the reason
                                    irq_n = 1'b0;
                                end
                                MOUSE_CLEAR: begin
                                    // Clear(): the clamps stay (Fantavision)
                                    dlen = 4'd1;
                                    stat_n = 8'd0;
                                    nx_n = 16'd0; ny_n = 16'd0;
                                    btn0_n = 1'b0; btn1_n = 1'b0;
                                    ix_n = 18'sd0; iy_n = 18'sd0;
                                    pos_set = 1'b1;
                                end
                                MOUSE_POS:   dlen = 4'd5;
                                MOUSE_INIT: begin
                                    dlen = 4'd3;
                                    buff_n[1] = 8'hFF;
                                end
                                MOUSE_CLAMP: dlen = 4'd5;
                                MOUSE_HOME: begin
                                    dlen = 4'd1;
                                    ix_n = 18'sd0; iy_n = 18'sd0;
                                    pos_set = 1'b1;
                                end
                                MOUSE_TIME: begin
                                    case (cmd[3:2])
                                        2'b00: dlen = 4'd1;
                                        2'b01: dlen = 4'd3;
                                        2'b10: dlen = 4'd2;
                                        2'b11: dlen = 4'd4;
                                    endcase
                                    frame_50_n = cmd[0];
                                end
                                8'hA0:       dlen = 4'd2;
                                default:     dlen = 4'd1;   // $B0, $C0 and the unknown
                            endcase
                            // SetPA(buff[1]): what the ROM reads first.  For
                            // the commands that fill it, the fresh byte.
                            ia_n = buff_n[1];
                        end
                        if (npos == dlen || npos > 4'd7) begin
                            // OnWrite: the command is complete.
                            case (cmd & 8'hF0)
                                MOUSE_CLAMP: begin
                                    // The bounds now; the position is brought
                                    // inside them by the pipeline (reclamp).
                                    c_lo = {buff_n[3], buff_n[1]};
                                    c_hi = {buff_n[4], buff_n[2]};
                                    folded = fold_clamp(c_lo, c_hi);
                                    if (cmd[0]) begin
                                        miny_n = folded[31:16]; maxy_n = folded[15:0];
                                    end else begin
                                        minx_n = folded[31:16]; maxx_n = folded[15:0];
                                    end
                                    reclamp_n = 1'b1;
                                end
                                MOUSE_POS: begin
                                    nx_n = {buff_n[2], buff_n[1]};
                                    ny_n = {buff_n[4], buff_n[3]};
                                    ix_n = $signed({2'b00, nx_n});
                                    iy_n = $signed({2'b00, ny_n});
                                    pos_set = 1'b1;
                                end
                                MOUSE_INIT: begin
                                    nx_n = 16'd0; ny_n = 16'd0;
                                    minx_n = 16'd0; maxx_n = 16'd1023;
                                    miny_n = 16'd0; maxy_n = 16'd1023;
                                    ix_n = 18'sd0; iy_n = 18'sd0;
                                    pos_set = 1'b1;
                                end
                                default: ;
                            endcase
                            npos = 4'd0;
                        end
                        pos = npos;
                        b_new[7] = 1'b0;            // for the next reading
                    end
                end
                if (diff[4]) begin
                    if (pb_data[4]) begin
                        b_new[6] = 1'b0;            // preparing the next value
                    end else begin
                        // Clock activate for a read: the next answer byte.
                        npos = (pos != 4'd0) ? pos + 4'd1 : 4'd0;
                        if (npos == dlen || npos > 4'd7) begin
                            npos = 4'd0;            // all read: ready for a command
                        end else begin
                            ia_n = buff_n[npos[2:0]];
                        end
                        pos = npos;
                        b_new[6] = 1'b1;            // for the next writing
                    end
                end
                buffpos_n = pos;
                datalen_n = dlen;
                b6821_n = b_new;
                ib_n = b_new;
            end
        end

        // ---- OnMouseEvent, on a clock of its own -------------------------------
        if (!pb_pend && (ev_pend || vbl_pend)) begin
            ev_taken = 1'b1;
            ev = 8'd0;
            if (mode[3] && vbl_pend) ev = ev | STAT_INT_VBL;
            if (mode[0]) begin
                if (nx != ix[15:0] || ny != iy[15:0]) begin
                    ev = ev | STAT_INT_MOVEMENT | STAT_MOVED;
                    stat_n = stat_n | STAT_MOVED;
                end
                if (btn0 != but0 || btn1 != but1) ev = ev | STAT_INT_BUTTON;
                ev = ev & ({4'd0, mode & MODE_INT_ALL} | STAT_MOVED);
            end else begin
                ev = ev & STAT_INT_VBL;             // mouse off: VBL alone (GH#1138)
            end
            if ((ev & STAT_INT_ALL) != 8'd0) begin
                stat_n = stat_n | ev;
                irq_n = 1'b1;
            end
        end
    end

    // ---- the move pipeline ------------------------------------------------------
    // A host move accumulates while one is in flight; the add clock takes
    // the sum (never while the 68705 steps, whose command may move the
    // position); the clamp clock settles it against the bounds as they are
    // registered - a CLAMP that lands meanwhile sets reclamp and the
    // pipeline runs once more for it - and applies the buttons.  A command
    // that sets the position while a sum is waiting to settle wins, and
    // that sum is dropped: the race is one nobody could call.
    wire start_now  = !settling && !pb_pend && (mv_pend || reclamp);
    wire settle_now = settling && !pb_pend;
    wire drop_now   = settling && pb_pend && pos_set;

    function automatic signed [19:0] sat20(input signed [20:0] v);
        begin
            if (v > 21'sd65535)       sat20 = 20'sd65535;
            else if (v < -21'sd65535) sat20 = -20'sd65535;
            else                      sat20 = v[19:0];
        end
    endfunction

    integer k;
    always_ff @(posedge clk) begin
        if (state_reset) begin
            ia <= 8'd0; ib <= 8'h40;
            b6821 <= 8'h40;                          // PB6 set
            for (k = 0; k < 8; k = k + 1) buff[k] <= 8'd0;
            buffpos <= 4'd0; datalen <= 4'd1;
            mode <= 4'd0; stat <= 8'd0;
            ix <= 18'sd0; iy <= 18'sd0; nx <= 16'd0; ny <= 16'd0;
            minx <= 16'd0; maxx <= 16'd1023; miny <= 16'd0; maxy <= 16'd1023;
            btn0 <= 1'b0; btn1 <= 1'b0; but0 <= 1'b0; but1 <= 1'b0;
            irq_q <= 1'b0;
            frame_ctr <= 15'd0; frame_50 <= 1'b0;
            moves <= 8'd0;
            dx_pend <= 20'sd0; dy_pend <= 20'sd0; btn_pend <= 2'd0; btn_plus <= 2'd0;
            mv_pend <= 1'b0; reclamp <= 1'b0; settling <= 1'b0;
            ev_pend <= 1'b0; vbl_pend <= 1'b0;
            ix_plus <= 20'sd0; iy_plus <= 20'sd0;
        end else begin
            ia <= ia_n; ib <= ib_n; b6821 <= b6821_n;
            for (k = 0; k < 8; k = k + 1) buff[k] <= buff_n[k];
            buffpos <= buffpos_n; datalen <= datalen_n;
            mode <= mode_n; stat <= stat_n;
            nx <= nx_n; ny <= ny_n;
            minx <= minx_n; maxx <= maxx_n; miny <= miny_n; maxy <= maxy_n;
            btn0 <= btn0_n; btn1 <= btn1_n;
            irq_q <= irq_n;
            frame_50 <= frame_50_n;
            if (frame_end)  frame_ctr <= 15'd0;
            else if (tick)  frame_ctr <= frame_ctr + 15'd1;

            // The position: a command's, or the settled sum.
            if (settle_now) begin
                ix <= clamp(ix_plus, minx, maxx);
                iy <= clamp(iy_plus, miny, maxy);
                but0 <= btn_plus[0];
                but1 <= btn_plus[1];
            end else begin
                ix <= ix_n;
                iy <= iy_n;
            end

            // The host's deltas, accumulating until the add clock takes them.
            if (word_move) begin
                moves <= moves + 8'd1;
                btn_pend <= rx_buttons;
                mv_pend <= 1'b1;
            end
            if (start_now) begin
                ix_plus <= $signed({2'b00, ix}) + (mv_pend ? dx_pend : 20'sd0);
                iy_plus <= $signed({2'b00, iy}) + (mv_pend ? dy_pend : 20'sd0);
                btn_plus <= mv_pend ? btn_pend : {but1, but0};
                dx_pend <= word_move ? $signed({{4{mv_dx[15]}}, mv_dx}) : 20'sd0;
                dy_pend <= word_move ? $signed({{4{mv_dy[15]}}, mv_dy}) : 20'sd0;
                mv_pend <= word_move;
                settling <= 1'b1;
            end else if (word_move) begin
                dx_pend <= sat20($signed({dx_pend[19], dx_pend}) + $signed({{5{mv_dx[15]}}, mv_dx}));
                dy_pend <= sat20($signed({dy_pend[19], dy_pend}) + $signed({{5{mv_dy[15]}}, mv_dy}));
            end
            reclamp <= start_now ? 1'b0 : reclamp_n;
            if (settle_now || drop_now) settling <= 1'b0;
            ev_pend  <= settle_now ? 1'b1 : (ev_taken ? 1'b0 : ev_pend);
            vbl_pend <= frame_end  ? 1'b1 : (ev_taken ? 1'b0 : vbl_pend);
        end
    end

    // ---- claim and read data ------------------------------------------------------
    // Registered on op_present: one stable answer per bus cycle, decided in
    // the address phase.  The PIA's read mux and the ROM byte are
    // combinational off op_addr, stable since T_PRESENT; the previous
    // access's commit-time side effects landed clocks before this present.
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_claim   <= 1'b0;
            rd_data    <= 8'd0;
            hit_dev_q  <= 1'b0;
            hit_page_q <= 1'b0;
        end else if (op_present) begin
            hit_dev_q  <= hit_dev;
            hit_page_q <= hit_page;
            rd_claim   <= (hit_dev || hit_page) && op_rw;
            rd_data    <= hit_dev ? pia_rd : rom_byte;
        end else if (!enabled) begin
            rd_claim   <= 1'b0;
            hit_dev_q  <= 1'b0;
            hit_page_q <= 1'b0;
        end
    end

endmodule
