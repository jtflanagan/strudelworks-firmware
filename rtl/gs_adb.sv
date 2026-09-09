`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_adb - the IIgs's ADB microcontroller, at $C024-$C027.
//
// THE REFERENCE IS KEGS's adb.c, transcribed function by function rather than
// reasoned out, for the reason docs/GS.md records at rung 2: a model written
// from the reference disagrees with the RTL wherever either is wrong, while a
// model written from the RTL agrees with its bugs.  The functions this
// transcribes are named at each block: adb_read_c026, adb_write_c026,
// do_adb_cmd, adb_read_c027, adb_write_c027, adb_send_bytes,
// adb_response_packet, read_adb_ram, write_adb_ram, adb_kbd_talk_reg0.
//
// WHAT IT IS.  Not an ADB bus - a MICROCONTROLLER with a command port.  The
// ROM writes a command byte to $C026, sometimes follows it with a fixed
// number of argument bytes, and the micro answers by putting bytes in a queue
// and raising DATA_VALID in $C027 bit 5.  The ROM polls that bit and drains
// the queue through $C026.  That poll is where the card sat before this
// module existed: docs/GS.md rung 3a ends in the ROM's timeout loop at
// $FF/819C, waiting for a bit no one was setting.
//
// THE THREE STATES are KEGS's: IDLE, IN_CMD (collecting a command's argument
// bytes), SENDING (draining the answer queue).  Two things make $C027 say
// DATA_VALID - a non-zero INTERRUPT BYTE, the micro's own out-of-band answer,
// and a non-empty queue in any state but IN_CMD - and $C026 reads them in
// that order: the interrupt byte first, from IDLE, and only then the queue,
// from SENDING.  adb_response_packet sets both at once (an interrupt byte of
// $80 + count - 1) and stays IDLE, which is how a Talk answers;
// adb_send_bytes sets the queue alone and goes straight to SENDING, which is
// how every other command answers.  The difference is visible - a Talk costs
// one extra $C026 read to collect the interrupt byte - so the two are kept
// apart here rather than merged.
//
// SIDE EFFECTS HAPPEN ON THE COMMIT, NOT ON THE BYTE.  `rd_byte` is
// combinational on the registered op and must be stable across the clocks the
// dispatcher takes to serve it (rtl/accel_seq.sv, "swi_byte is taken through
// ONE register"), so the queue pops on `act` - the op's synthetic commit,
// once per op - and never on the read itself.  ONE sequential block owns all
// of the state for the same reason a microcoded core has one: a command that
// completes on its last argument byte both leaves IN_CMD and loads the queue,
// and those are one decision, not two.
//
// WHAT IS NOT HERE YET: the keyboard and mouse themselves (rung 3c wires the
// Pi's evdev feeds to them, and the real IIe keyboard beside them), the SRQ,
// and the wiring of irq_data/irq_mouse into gs_intc.  With no keys a Talk
// register 0 answers with a zero-byte response packet, which is exactly what
// KEGS does with an empty buffer.
//////////////////////////////////////////////////////////////////////////////////
module gs_adb #(
    parameter [7:0] T_ADB_KEY = 8'h2F,
    // The ADB micro's keymap, 128 entries of {ctrl, shift, plain}, each
    // {none, special, byte}: tools/gen_adb_keymap.py from KEGS's own table.
    parameter KEYMAP = "adb_keymap.hex"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,       // synchronised RES', ACTIVE LOW

    // The registered op and its retire.  `act` is one clock, and op_* are
    // stable across it.
    input  wire [7:0]  op_lo,          // the low byte of $C0xx
    input  wire        op_rw,          // 1 = read
    input  wire [7:0]  op_wdata,
    input  wire        act,            // this op retired: apply its effect

    // The byte a read of op_lo would take, combinational.
    output logic [7:0] rd_byte,

    // THE KEYS, from the host (docs/GS.md, ADB_KEY).  One word an event:
    // the ADB keycode, whether it went up, and the modifier byte the host
    // resolved - shift, control, caps, option and command, in $C025's own
    // bit order.  The micro holds the keymap, as a real one does, so what
    // arrives is a keycode and not an ASCII byte.
    // One pulse a video frame, the machine's own (rtl/vbeam.sv): the ADB
    // micro's auto-repeat counts in frames because KEGS's does - its delay
    // and rate are in g_vbl_count units, out of the set-config byte.
    input  wire        frame_tick,

    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    input  wire [7:0]  msg_len,
    input  wire [31:0] pay_data,
    input  wire        pay_valid,

    // The keyboard registers this module now owns beside the micro's own:
    // $C000's latched byte, and $C025's modifiers.  $C010 is an ACCESS, not
    // a read - a write to it clears the strobe too - so it arrives as a
    // pulse rather than through rd_byte.
    output logic [7:0] c025_val,

    // Interrupt requests into gs_intc, each gated by its own $C027 enable.
    output wire        irq_data,
    output wire        irq_mouse,

    // Diagnostics a bench reads through the hierarchy.
    output logic [7:0] cnt_cmds,
    output logic [7:0] cnt_unknown
);

    localparam [1:0] S_IDLE = 2'd0, S_IN_CMD = 2'd1, S_SENDING = 2'd2;

    // $C027's bits (adb.c:46-58).  NEG_MASK is the half a write keeps: the
    // three interrupt ENABLES.  The rest is status the micro composes.
    localparam [7:0] C027_MOUSE_DATA  = 8'h80;
    localparam [7:0] C027_MOUSE_INT   = 8'h40;
    localparam [7:0] C027_DATA_VALID  = 8'h20;
    localparam [7:0] C027_DATA_INT    = 8'h10;
    localparam [7:0] C027_KBD_VALID   = 8'h08;
    localparam [7:0] C027_MOUSE_COORD = 8'h02;
    localparam [7:0] C027_CMD_FULL    = 8'h01;
    localparam [7:0] C027_NEG_MASK    = ~(C027_MOUSE_DATA | C027_DATA_VALID |
                                          C027_KBD_VALID | C027_MOUSE_COORD |
                                          C027_CMD_FULL);   // $54

    logic [1:0] st;
    logic [7:0] cmd;
    logic [3:0] cmd_len, cmd_so_far;
    logic [7:0] cmd_data [0:7];

    // The answer queue, eight deep and drained from the head.  KEGS's
    // MAX_ADB_DATA_PEND is larger, but no command this machine issues sends
    // more than four bytes.
    logic [7:0] dq [0:7];
    logic [3:0] dq_n;

    // ---- the keyboard (adb_key_event, adb_read_c000, adb_access_c010) -------
    // Two queues, because the machine has two ways to ask.  kbd_buf is the
    // ASCII one $C000 reads, head first, bit 7 the strobe; reg0 is the RAW
    // ADB events a Talk register 0 drains, {is_up, keycode}.  A key that has
    // no ASCII - a function key, a modifier - goes only into reg0, which is
    // KEGS's `hard_key` split.
    localparam integer KBD_N = 8, REG0_N = 8;
    logic [7:0] kbd_buf [0:KBD_N-1];
    logic [3:0] kbd_n;
    logic [7:0] reg0 [0:REG0_N-1];
    logic [3:0] reg0_n;
    logic       hard_key_down;
    logic [6:0] a2code_down;

    // ---- auto-repeat (adb_key_event, adb_read_c000, adb_set_config) --------
    // KEGS holds a frame number to repeat at and compares the frame count
    // with it; a counter that runs DOWN says the same thing without a
    // free-running frame number to keep, and cannot wrap into a false
    // compare.  key_down is KEGS's g_key_down: a hard key is held AND the
    // delay is not zero, which is set-config's way of turning repeat off.
    logic        key_down;
    logic [15:0] rpt_left;
    // The timing follows `repeat_info` itself rather than a second copy of
    // it: set-config writes that register and these are what it means.
    // adb_set_config's val2: the high nibble is the delay, four meaning
    // never, otherwise (n+1) * 15 frames; the low nibble is the rate, which
    // ROM 3 sends as 9 - n, through a table that is not linear.
    wire [3:0] cfg_delay_n = repeat_info[7:4];
    wire [3:0] cfg_rate_n  = 4'd9 - repeat_info[3:0];
    wire [7:0] cfg_delay = (cfg_delay_n == 4'd4) ? 8'd0
                         : (cfg_delay_n <  4'd4) ? ((8'd1 + {4'd0, cfg_delay_n}) * 8'd15)
                                                 : 8'd45;
    logic [7:0] cfg_rate;
    always_comb begin
        case (cfg_rate_n)
            4'd0:    cfg_rate = 8'd1;
            4'd1:    cfg_rate = 8'd2;
            4'd2:    cfg_rate = 8'd3;
            4'd3:    cfg_rate = 8'd3;
            4'd4:    cfg_rate = 8'd4;
            4'd5:    cfg_rate = 8'd5;
            4'd6:    cfg_rate = 8'd7;
            4'd7:    cfg_rate = 8'd15;
            4'd8:    cfg_rate = 8'd30;
            4'd9:    cfg_rate = 8'd60;
            default: cfg_rate = 8'd3;
        endcase
    end

    // THE REPEAT FIRES WHEN THE MACHINE LOOKS, not on the timer.  KEGS does
    // it inside adb_read_c000 - a program that never reads the keyboard does
    // not accumulate repeats in the buffer, and one that polls gets them at
    // the rate - so this is a read of $C000 with the strobe already gone, a
    // key still held, and the count run out.  It is taken as an EVENT, so
    // the whole of adb_key_event applies to it, which is what KEGS's calling
    // itself amounts to.
    wire c000_rd_act = act && op_rw && (op_lo == 8'h00);
    wire rpt_fire = c000_rd_act && key_down && !kbd_buf[0][7] &&
                    (rpt_left == 16'd0) && !ev_v;

    // The keymap: 128 entries of {ctrl, shift, plain}, each {none, special,
    // byte}.  Distributed, and read combinationally - one event at a time and
    // nothing else wants the port.
    (* rom_style = "distributed" *) logic [29:0] keymap [0:127];
    initial $readmemh(KEYMAP, keymap);

    logic [7:0] int_byte;
    logic [7:0] c027_val;
    logic [7:0] adb_mode;

    // The configuration (adb_set_config; read back by command $0B).
    logic [3:0] mouse_ctl_addr, kbd_ctl_addr;
    logic [3:0] char_set, layout_lang;
    logic [7:0] repeat_info;
    logic [3:0] kbd_dev_addr;
    logic [15:0] kbd_reg3;

    // The mouse, not yet fed.
    logic mouse_valid, mouse_coord;

    // The micro's own 256 bytes, read combinationally at the clock a Read Mem
    // command completes.
    (* ram_style = "distributed" *) logic [7:0] adb_ram [0:255];

    // ---- $C027, composed (adb_read_c027) ------------------------------------
    wire data_valid = (int_byte != 8'd0) ||
                      ((dq_n != 4'd0) && (st != S_IN_CMD));
    wire [7:0] c027_rd = (c027_val & C027_NEG_MASK) |
                         (mouse_valid ? C027_MOUSE_DATA  : 8'd0) |
                         (data_valid  ? C027_DATA_VALID  : 8'd0) |
                         (mouse_coord ? C027_MOUSE_COORD : 8'd0);

    // ---- $C026, without its side effects (adb_read_c026) --------------------
    wire [7:0] c026_rd = (st == S_IDLE)   ? int_byte
                       : (st == S_IN_CMD) ? 8'h00
                                          : dq[0];

    // ---- $C000 and $C010, the keyboard the machine has always had -----------
    // adb_read_c000 returns the head of the buffer as it stands; bit 7 is the
    // strobe, set when a key is waiting.  adb_access_c010 answers with the
    // strobe CLEARED and bit 7 replaced by "a hard key is still down", and
    // clears the strobe as a side effect - which is why $C010 is an access
    // and not a read: a WRITE to it clears the strobe too.
    //
    // NOT HERE YET: KEGS's auto-repeat (g_adb_repeat_vbl and the $C025 bit 3
    // it sets) and its "read five times with keys pending, toss one" nudge,
    // both of which need the frame count.  docs/GS.md's decision table asks
    // for auto-repeat from set-config; it is a rung of its own.
    wire [7:0] c000_rd = kbd_buf[0];
    wire [7:0] c010_rd = {hard_key_down, kbd_buf[0][6:0]};

    always_comb begin
        case (op_lo)
            8'h00:   rd_byte = c000_rd;
            8'h10:   rd_byte = c010_rd;
            8'h25:   rd_byte = c025_val;
            8'h26:   rd_byte = c026_rd;
            8'h27:   rd_byte = c027_rd;
            default: rd_byte = 8'h00;
        endcase
    end

    assign irq_data  = ((c027_val & C027_DATA_INT)  != 8'd0) && data_valid;
    assign irq_mouse = ((c027_val & C027_MOUSE_INT) != 8'd0) && mouse_valid;

    // ---- a command's argument count (adb_write_c026) ------------------------
    // Zero means the command answers on its own byte.
    function automatic [3:0] arg_len(input [7:0] c);
        begin
            case (c)
                8'h04, 8'h05, 8'h11:        arg_len = 4'd1;
                8'h06:                      arg_len = 4'd3;
                8'h07:                      arg_len = 4'd8;   // ROM 3; ROM 01 is 4
                8'h08, 8'h09, 8'h12, 8'h13: arg_len = 4'd2;
                default: arg_len = (c[7:4] == 4'hB) ? 4'd2 : 4'd0;   // Listen dev reg 3
            endcase
        end
    endfunction

    // The last argument byte has not landed in cmd_data on the clock the
    // command completes, so every argument is read through this: the write's
    // own byte for the slot it is filling, the register for the rest.
    function automatic [7:0] arg(input [3:0] k);
        arg = (cmd_so_far == k) ? op_wdata : cmd_data[k[2:0]];
    endfunction

    // ---- an ADB_KEY, decoded (adb_key_event) --------------------------------
    // The message word is {mods[7:0], is_up, keycode[6:0]}.  The keymap is
    // read on the word's own clock and the whole event registered, so the
    // apply below is a mux of registers and not a ROM lookup.
    logic [7:0] rx_type_k, rx_left_k;
    wire rx_word_k  = pay_valid && (rx_left_k != 8'd0);
    wire hdr_key    = msg_valid && (msg_type == T_ADB_KEY);
    wire word_key   = rx_word_k && (rx_type_k == T_ADB_KEY);
    // One address, two sources: the message's keycode, or the held key when
    // the repeat re-fires it.
    wire [6:0]  km_addr = word_key ? pay_data[6:0] : a2code_down;
    wire [29:0] km_in   = keymap[km_addr];

    logic        ev_v;
    logic [6:0]  ev_code;
    logic        ev_up;
    logic        ev_rpt;        // this event is a repeat, not a new press
    logic [7:0]  ev_mods;
    logic [29:0] ev_km;

    // Which column the modifiers choose, KEGS's order: caps lock lifts a-z,
    // shift lifts anything, and control overrides both when the key has one.
    // $C025's bits are 0 shift, 1 control, 2 caps (adb.c's SHIFT_DOWN etc).
    wire ev_shift = ev_mods[0], ev_ctrl = ev_mods[1], ev_caps = ev_mods[2];
    wire [9:0] km_plain = ev_km[9:0];
    wire [9:0] km_shift = ev_km[19:10];
    wire [9:0] km_ctrl  = ev_km[29:20];
    wire       lower_az = !km_plain[9] && !km_plain[8] &&
                          (km_plain[7:0] >= 8'h61) && (km_plain[7:0] <= 8'h7A);
    wire [9:0] km_sel   = (ev_ctrl && !km_ctrl[9])       ? km_ctrl
                        : (ev_shift || (ev_caps && lower_az)) ? km_shift
                                                          : km_plain;
    // KEGS decides "this key has an ASCII" from the PLAIN column alone and
    // then reads whichever column the modifiers chose - see
    // tools/gen_adb_keymap.py.
    wire ev_hard = !km_plain[9] && !km_plain[8];

    // adb_kbd_talk_reg0's choice, spelled out: val0 is the head, val1 the
    // one behind it, and a RESET ($7F with either up bit) never shares a
    // packet.  t0_num is how many the answer consumes.
    wire [7:0] t0_v0  = reg0[0];
    wire [7:0] t0_v1  = reg0[1];
    wire       t0_r0  = (t0_v0[6:0] == 7'h7F);
    wire       t0_r1  = (t0_v1[6:0] == 7'h7F);
    wire [7:0] t0_hi  = t0_v0;
    wire [7:0] t0_lo  = t0_r0            ? t0_v0            // reset: doubled
                      : (reg0_n > 4'd1)  ? (t0_r1 ? 8'hFF : t0_v1)
                                         : 8'hFF;
    wire [1:0] t0_num = t0_r0           ? 2'd1
                      : (reg0_n > 4'd1) ? (t0_r1 ? 2'd1 : 2'd2)
                                        : 2'd1;

    // Named so they can be bit-selected: a function call cannot be.
    wire [7:0] a0 = arg(4'd0), a1 = arg(4'd1), a2 = arg(4'd2), a3 = arg(4'd3);

    wire [15:0] ram_addr = {a1, a0};
    // read_adb_ram (adb.c:1210): above $00FF only the ROM self-test's
    // checksum answers, at $1400/$1401; on ROM 3 address $0C reads the live
    // modifier keys.
    wire [7:0] ram_rd = (ram_addr == 16'h1400)     ? 8'h72
                      : (ram_addr == 16'h1401)     ? 8'hF7
                      : (ram_addr >= 16'h0100)     ? 8'h00
                      : (ram_addr[7:0] == 8'h0C)   ? (c025_val & 8'hC7)
                      : adb_ram[ram_addr[7:0]];

    // The message's own header/word counter, and the event register.  An
    // event WAITS for a clock with no `act`: the apply below and the command
    // machine both touch reg0 - one pushes, a Talk pops - and the module
    // keeps one writer for its state, so they take turns rather than
    // arbitrate.  Ops are tens of clocks apart even accelerated, so the wait
    // is one clock at most.
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_type_k <= 8'd0; rx_left_k <= 8'd0;
            ev_v <= 1'b0;
        end else begin
            if (msg_valid) begin
                rx_type_k <= msg_type;
                rx_left_k <= msg_len;
                if (hdr_key && msg_len != 8'd1) rx_type_k <= 8'd0;
            end else if (rx_word_k) begin
                rx_left_k <= rx_left_k - 8'd1;
            end
            if (word_key) begin
                ev_v    <= 1'b1;
                ev_code <= pay_data[6:0];
                ev_up   <= pay_data[7];
                ev_rpt  <= 1'b0;
                ev_mods <= pay_data[15:8];
                ev_km   <= km_in;
            end else if (rpt_fire) begin
                // The held key again, with the modifiers as they stand.
                ev_v    <= 1'b1;
                ev_code <= a2code_down;
                ev_up   <= 1'b0;
                ev_rpt  <= 1'b1;
                ev_mods <= c025_val;
                ev_km   <= km_in;
            end else if (ev_v && !act) begin
                ev_v <= 1'b0;
            end
        end
    end
    wire ev_go = ev_v && !act;

    // adb_access_c010: the strobe goes, the head leaves, and $C025's
    // "a key is available" bit goes with it.  A task because a read of $C010
    // and a write to it do the same thing - it is an ACCESS.
    integer j;
    task automatic kbd_shift;
        begin
            kbd_buf[0] <= {1'b0, kbd_buf[0][6:0]};
            if (kbd_n != 4'd0) begin
                // ONLY THE ENTRIES BEHIND THE HEAD MOVE.  KEGS's loop is
                // `for(i = 1; i < g_kbd_chars_buffered; i++)`, so with ONE
                // character buffered it does not run at all and the head
                // keeps the byte with its strobe cleared - which is what
                // $C000 goes on reading until the next key.  Shifting
                // unconditionally zeroes it instead, and the machine sees a
                // character it never typed go away.
                for (j = 1; j < KBD_N; j = j + 1)
                    if (j < int'(kbd_n)) kbd_buf[j-1] <= kbd_buf[j];
                kbd_n <= kbd_n - 4'd1;
            end
            c025_val <= c025_val & ~8'h08;
        end
    endtask

    integer i;
    wire [7:0] c    = op_wdata;         // the command byte being written
    wire [3:0] wdev = op_wdata[3:0];    // ...and the device in its low nibble

    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            st <= S_IDLE;
            cmd <= 8'd0; cmd_len <= 4'd0; cmd_so_far <= 4'd0;
            dq_n <= 4'd0;
            for (i = 0; i < 8; i = i + 1) begin dq[i] <= 8'd0; cmd_data[i] <= 8'd0; end
            int_byte <= 8'd0;
            c027_val <= 8'd0;
            adb_mode <= 8'd0;
            // adb.c:136-164; adb_reset() restores the same values.
            mouse_ctl_addr <= 4'd3; kbd_ctl_addr <= 4'd2;
            char_set <= 4'd0; layout_lang <= 4'd0;
            repeat_info <= 8'h23;
            kbd_dev_addr <= 4'd2;
            kbd_reg3 <= 16'h0602;
            mouse_valid <= 1'b0; mouse_coord <= 1'b0;
            cnt_cmds <= 8'd0; cnt_unknown <= 8'd0;
            // The keyboard.  A RESET clears the buffers and the modifiers;
            // c025 bit 5 is "no hard key is down", which is true of a machine
            // that has just been reset.
            kbd_n <= 4'd0; reg0_n <= 4'd0;
            hard_key_down <= 1'b0; a2code_down <= 7'd0;
            key_down <= 1'b0; rpt_left <= 16'd0;
            c025_val <= 8'h20;
            for (i = 0; i < KBD_N; i = i + 1) kbd_buf[i] <= 8'd0;
            for (i = 0; i < REG0_N; i = i + 1) reg0[i] <= 8'd0;
        end else if (ev_go) begin
            // ---- adb_key_event ------------------------------------------
            // The raw event always goes to register 0, up or down; the ASCII
            // only on a press of a key that has one.
            if (reg0_n < REG0_N[3:0]) begin
                reg0[reg0_n[2:0]] <= {ev_up, ev_code};
                reg0_n <= reg0_n + 4'd1;
            end
            if (!ev_up && ev_hard) begin
                if (kbd_n < KBD_N[3:0]) begin
                    // KEGS's `key = (ascii & 0x7f) + 0x80`: bit 7 is the
                    // strobe the machine polls, not part of the character.
                    kbd_buf[kbd_n[2:0]] <= {1'b1, km_sel[6:0]};
                    kbd_n <= kbd_n + 4'd1;
                end
                hard_key_down <= 1'b1;
                a2code_down   <= ev_code;
                // A press arms the delay; a repeat arms the rate.  A delay of
                // zero is set-config's way of saying "never repeat", and
                // KEGS clears g_key_down for it rather than counting.
                key_down <= (cfg_delay != 8'd0);
                rpt_left <= ev_rpt ? {8'd0, cfg_rate} : {8'd0, cfg_delay};
            end else if (ev_up && ev_hard && (ev_code == a2code_down)) begin
                hard_key_down <= 1'b0;
                key_down      <= 1'b0;
            end
            // The modifiers are the host's, and bit 5 is this module's:
            // set when no hard key is down, which is what the ROM's own
            // "update the modifier latch" reads.
            // ...and bit 3, "a key is available", which KEGS sets on a
            // repeat and $C010 clears.
            c025_val <= (ev_mods & 8'hC7) | (c025_val & 8'h08) |
                        (ev_rpt ? 8'h08 : 8'h00) |
                        ((!ev_up && ev_hard) ? 8'h00 : 8'h20);
        end else if (frame_tick) begin
            if (rpt_left != 16'd0) rpt_left <= rpt_left - 16'd1;
        end else if (act && !op_rw && (op_lo == 8'h10)) begin
            // ---- adb_access_c010, the write half ------------------------
            kbd_shift();
        end else if (act && op_rw && (op_lo == 8'h10)) begin
            kbd_shift();
        end else if (act && op_rw && (op_lo == 8'h26)) begin
            // ---- a read of $C026 drains (adb_read_c026) ---------------------
            case (st)
                S_IDLE: begin
                    // The interrupt byte is taken whole; a queue waiting
                    // behind it is drained by the reads that follow.
                    int_byte <= 8'd0;
                    if (dq_n != 4'd0) st <= S_SENDING;
                end
                S_IN_CMD: ;                     // returns zero, changes nothing
                default: begin                  // S_SENDING
                    for (i = 0; i < 7; i = i + 1) dq[i] <= dq[i+1];
                    dq[7] <= 8'd0;
                    if (dq_n <= 4'd1) begin
                        dq_n <= 4'd0;
                        st   <= S_IDLE;
                    end else begin
                        dq_n <= dq_n - 4'd1;
                    end
                end
            endcase
        end else if (act && !op_rw && (op_lo == 8'h27)) begin
            // ---- $C027: the three interrupt enables (adb_write_c027) --------
            c027_val <= op_wdata & C027_NEG_MASK;
        end else if (act && !op_rw && (op_lo == 8'h26)) begin
            if (st == S_IN_CMD) begin
                // ---- an argument byte, and the command it completes ---------
                cmd_data[cmd_so_far[2:0]] <= op_wdata;
                if (cmd_so_far + 4'd1 >= cmd_len) begin
                    st <= S_IDLE;
                    // do_adb_cmd (adb.c:1002).
                    case (cmd)
                        8'h04: adb_mode <= adb_mode |  a0;   // set modes
                        8'h05: adb_mode <= adb_mode & ~a0;   // clear modes
                        8'h06: begin                                 // set config
                            mouse_ctl_addr <= a0[7:4];
                            kbd_ctl_addr   <= a0[3:0];
                            repeat_info    <= a2;
                        end
                        8'h07: begin                                 // SYNC
                            adb_mode       <= a0;
                            mouse_ctl_addr <= a1[7:4];
                            kbd_ctl_addr   <= a1[3:0];
                            repeat_info    <= a3;
                        end
                        8'h08: adb_ram[a0] <= a1;      // write mem
                        8'h09: begin                                 // read mem
                            // adb_send_1byte: the queue AND the state.
                            dq[0] <= ram_rd; dq_n <= 4'd1; st <= S_SENDING;
                        end
                        8'h11, 8'h12, 8'h13: ;   // send keycodes, cmd 12, cmd 13
                        default: begin
                            // Listen device x register 3.  The only field
                            // that matters here is the keyboard's address.
                            if ((cmd[7:4] == 4'hB) && (cmd[3:0] == kbd_dev_addr) &&
                                (a1 == 8'hFE))
                                kbd_dev_addr <= a0[3:0];
                        end
                    endcase
                end else begin
                    cmd_so_far <= cmd_so_far + 4'd1;
                end
            end else begin
                // ---- a new command (adb_write_c026, the IDLE arm) -----------
                cmd <= c;
                cmd_so_far <= 4'd0;
                cmd_len <= arg_len(c);
                cnt_cmds <= cnt_cmds + 8'd1;
                if (arg_len(c) != 4'd0) begin
                    st <= S_IN_CMD;
                end else begin
                    case (c)
                        // Abort, flush keyboard, reset, disable mouse SRQ:
                        // KEGS does nothing observable for any of them.
                        8'h01, 8'h03, 8'h10, 8'h73: ;
                        8'h0A: begin dq[0] <= adb_mode; dq_n <= 4'd1; st <= S_SENDING; end
                        8'h0B: begin                                 // read config
                            dq[0] <= 8'h82;
                            dq[1] <= {mouse_ctl_addr, kbd_ctl_addr};
                            dq[2] <= {char_set, layout_lang};
                            dq[3] <= repeat_info;
                            dq_n  <= 4'd4; st <= S_SENDING;
                        end
                        // Version: ROM 3 checks for >= 6.
                        8'h0D: begin dq[0] <= 8'd6;   dq_n <= 4'd1; st <= S_SENDING; end
                        8'h0E: begin dq[0] <= 8'h08; dq[1] <= 8'h00; dq_n <= 4'd2; st <= S_SENDING; end
                        8'h0F: begin dq[0] <= 8'h0A; dq[1] <= 8'h00; dq_n <= 4'd2; st <= S_SENDING; end
                        default: begin
                            if (c[7:4] == 4'hC) begin
                                // Talk device, register 0: the raw key
                                // events (adb_kbd_talk_reg0).  Empty answers
                                // adb_response_packet(0, ...) - no queued
                                // bytes, interrupt byte $80 - which is what
                                // this did before there were any keys.
                                //
                                // With keys it is always a TWO-byte packet,
                                // even when only one event goes: the second
                                // byte is $FF, "nothing here".  A RESET
                                // ($7F either way) travels alone - KEGS will
                                // not put one second, and doubles it when it
                                // is first.
                                if (wdev != kbd_dev_addr) begin
                                    cnt_unknown <= cnt_unknown + 8'd1;
                                end else if (reg0_n == 4'd0) begin
                                    int_byte <= int_byte | 8'h80;
                                end else begin
                                    dq[0]    <= t0_lo;
                                    dq[1]    <= t0_hi;
                                    dq_n     <= 4'd2;
                                    int_byte <= int_byte | 8'h81;
                                    for (i = 0; i < REG0_N - 1; i = i + 1)
                                        if (i + int'(t0_num) < REG0_N)
                                            reg0[i] <= reg0[i + int'(t0_num)];
                                    reg0_n <= reg0_n - {2'd0, t0_num};
                                end
                            end else if (c[7:4] == 4'hF) begin
                                // Talk device, register 3.  Two bytes, and
                                // the response packet stays IDLE.
                                if (wdev == kbd_dev_addr) begin
                                    dq[0]    <= kbd_reg3[7:0];
                                    dq[1]    <= kbd_reg3[15:8];
                                    dq_n     <= 4'd2;
                                    int_byte <= int_byte | 8'h81;
                                end else cnt_unknown <= cnt_unknown + 8'd1;
                            end else begin
                                cnt_unknown <= cnt_unknown + 8'd1;
                            end
                        end
                    endcase
                end
            end
        end
    end
endmodule
