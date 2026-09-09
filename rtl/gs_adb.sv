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
module gs_adb (
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

    // The modifier-key register $C025, fed from outside (rung 3c).
    input  wire [7:0]  c025_val,

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

    always_comb begin
        case (op_lo)
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
                                // Talk device, register 0: the key buffer.
                                // Empty, so adb_response_packet(0, ...) -
                                // no queued bytes, interrupt byte $80.
                                if (wdev == kbd_dev_addr) int_byte <= int_byte | 8'h80;
                                else cnt_unknown <= cnt_unknown + 8'd1;
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
