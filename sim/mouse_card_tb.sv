`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// mouse_card_tb - the AppleMouse card behind the real driver, with the tb
// playing the firmware ROM's side of the PIA and the host's mouse.
//
// A scripted CPU (vidhd_card_tb's) presents one op per bus cycle through the
// real apple_bus_write; the real ft601_msg_rx feeds the card the host's ROM
// chunks and its MOUSE_MOVE messages.  The tb talks to the PIA exactly as the
// firmware does - a command byte on port A clocked in with PB5, answer bytes
// clocked out with PB4 - so what is checked is AppleWin's protocol as ported,
// command by command.
//
// THE PROPERTIES, each a way this is or could be wrong:
//
//   * nothing is claimed until all eight ROM chunks have landed.
//   * $Cn00-$CnFF reads the ROM page port B selects; $C0n0-$C0n3 the PIA;
//     nothing else is claimed - not another slot, not $C800.
//   * INIT, SET, READ, SERV, CLEAR, POS, CLAMP (the fold included), HOME and
//     TIME do what AppleWin's do, byte for byte in the answers.
//   * a host move is clamped and raises the movement interrupt only when the
//     mode asks; READ reports the movement and clears the status but NOT the
//     IRQ line; SERV reports the reason and releases it.
//   * a button edge raises its interrupt, and READ reports previous/current.
//   * the 60 Hz timer interrupts on the core's ticks, and only with VBL mode.
//   * INTCXROM takes the ROM page but never the device-select registers.
//   * RES' resets the card's state and keeps the ROM; the card's reset clears
//     both.
//   * the bus is never driven for a read the card did not claim.
//////////////////////////////////////////////////////////////////////////////////
module mouse_card_tb;
    localparam integer T_PRESENT = 2;
    localparam integer T_EMIT    = 2;
    localparam integer T_DIN     = 44;
    localparam integer T_CYCEN   = 45;
    localparam [7:0] T_MOUSE_MOVE = 8'h25;
    localparam [7:0] T_MOUSE_ROM  = 8'h26;
    localparam [15:0] ELSEWHERE = 16'h1234;
    localparam [15:0] INTCXROM_OFF = 16'hC006, INTCXROM_ON = 16'hC007;

    // Slot 5: the PIA at $C0D0-$C0D3, the ROM page at $C500.
    localparam [15:0] PRA = 16'hC0D0, CRA = 16'hC0D1, PRB = 16'hC0D2, CRB = 16'hC0D3;
    localparam [15:0] ROM0 = 16'hC500;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;               // 100 MHz

    integer errors = 0;
    task fail(input [8*96-1:0] why);
        begin $display("FAIL: %0s", why); errors = errors + 1; end
    endtask

    // ---- phi0, as the machine makes it --------------------------------------
    localparam integer PHI0_LOW  = 49;
    localparam integer PHI0_HIGH = 49;
    reg phi0 = 0;
    integer phase_ctr = 0;
    always @(posedge clk) begin
        phase_ctr <= phase_ctr + 1;
        if (!phi0 && phase_ctr == PHI0_LOW - 1)  begin phi0 <= 1; phase_ctr <= 0; end
        if ( phi0 && phase_ctr == PHI0_HIGH - 1) begin phi0 <= 0; phase_ctr <= 0; end
    end

    // ---- the scripted CPU ---------------------------------------------------
    reg  [15:0] cpu_addr = 16'h0000;
    reg         cpu_rw   = 1'b1;
    reg  [7:0]  cpu_dout = 8'h00;
    wire        cyc_en;
    wire [7:0]  cpu_din;

    task bus_op(input [15:0] addr, input rw, input [7:0] dout);
        begin
            cpu_addr = addr; cpu_rw = rw; cpu_dout = dout;
            @(posedge cyc_en);
            @(posedge clk);
        end
    endtask
    task bus_write(input [15:0] addr, input [7:0] data);
        bus_op(addr, 1'b0, data);
    endtask
    task bus_read(input [15:0] addr);
        bus_op(addr, 1'b1, 8'h00);
    endtask
    task idle(input integer n);
        begin repeat (n) bus_read(ELSEWHERE); end
    endtask

    // ---- the DUT and the board's wiring -------------------------------------
    reg         master_active = 1'b1;
    reg         res_n = 1'b1;
    reg         fast_tick = 1'b0;
    wire [15:0] op_addr;
    wire        op_rw, op_present, op_commit, op_ovr;
    wire [7:0]  op_wdata;
    wire        rd_claim;
    wire [7:0]  rd_data;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, drv_sync, driving;
    wire [7:0]  data_drive;
    wire [7:0]  data_sync = data_oe ? data_drive : 8'hEE;

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) u_write (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0), .data_sync (data_sync),
        .master_active (master_active), .park_kbd (1'b0),
        .bus_owns (1'b1), .core_valid (1'b1),
        .cpu_addr (cpu_addr), .cpu_rw (cpu_rw), .cpu_dout (cpu_dout),
        .cpu_sync (1'b0), .drv_sync (drv_sync),
        .cyc_en (cyc_en), .cpu_din (cpu_din),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .slot_rd_claim (rd_claim), .slot_rd_data (rd_data),
        .din_sub_en (1'b0), .din_sub_data (8'h00),
        .ovr_en (1'b0), .ovr_addr (16'h0000), .ovr_rw (1'b1), .ovr_wdata (8'h00),
        .op_ovr (op_ovr), .nxt_addr (), .divert (1'b0), .op_divert (),
        .addr_drive (addr_drive), .rw_drive (rw_drive), .data_drive (data_drive),
        .addr_rw_oe (addr_rw_oe), .data_oe (data_oe), .dma_assert (dma_assert),
        .driving (driving)
    );

    // ---- host -> card: a FIFO the real parser reads -------------------------
    reg  [31:0] rx_mem [0:4095];
    integer     rx_wr = 0, rx_rd = 0;
    wire        rx_empty = (rx_rd >= rx_wr);
    wire [31:0] rx_dout  = rx_empty ? 32'd0 : rx_mem[rx_rd];
    wire        rx_rd_en;
    always @(posedge clk) if (rx_rd_en && !rx_empty) rx_rd <= rx_rd + 1;
    task push_word(input [31:0] w);
        begin rx_mem[rx_wr] = w; rx_wr = rx_wr + 1; end
    endtask
    function [31:0] hdr(input [7:0] t, input [7:0] len, input [15:0] free);
        hdr = {free, t, len};
    endfunction

    wire        msg_valid, pay_valid, unknown_valid;
    wire [7:0]  unknown_type, unknown_len;
    integer     unknowns = 0;
    always @(posedge clk) if (unknown_valid) unknowns = unknowns + 1;
    wire [7:0]  msg_type, msg_len;
    wire [15:0] msg_free;
    wire [31:0] pay_data;
    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .unknown_valid (unknown_valid), .unknown_type (unknown_type), .unknown_len (unknown_len)
    );

    // ---- the mouse card -----------------------------------------------------
    reg  [2:0]  slot_assign = 3'd5;
    wire        rom_loaded, irq;
    wire [15:0] pos_x, pos_y;
    wire [3:0]  mode_rd;
    wire [1:0]  buttons_rd;
    wire [7:0]  moves_rd;
    mouse_card dut (
        .clk (clk), .rst (rst), .res_sync (res_n),
        .master_active (master_active), .slot_assign (slot_assign),
        .op_addr (op_addr), .op_rw (op_rw), .op_wdata (op_wdata),
        .op_present (op_present), .op_commit (op_commit),
        .op_dummy (1'b0), .op_ovr (op_ovr),
        .fast_tick (fast_tick),
        .rd_claim (rd_claim), .rd_data (rd_data),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .irq (irq), .rom_loaded (rom_loaded),
        .pos_x (pos_x), .pos_y (pos_y), .mode_rd (mode_rd),
        .buttons_rd (buttons_rd), .moves_rd (moves_rd)
    );

    // ---- observers ----------------------------------------------------------
    integer read_drive_unclaimed = 0;
    always @(posedge clk) if (!rst) begin
        if (data_oe && rw_drive && !rd_claim)
            read_drive_unclaimed = read_drive_unclaimed + 1;
    end

    // ---- the host's side ----------------------------------------------------
    // A ROM with a pattern: byte i of page p is p*37 + i.
    function [7:0] rom_at(input integer page, input integer i);
        rom_at = (page * 37 + i) & 8'hFF;
    endfunction
    task send_chunk(input integer chunk, input [7:0] len);
        integer w;
        begin
            push_word(hdr(T_MOUSE_ROM, len, chunk[15:0]));
            for (w = 0; w < len; w = w + 1)
                push_word({rom_at(chunk, 4*w+3), rom_at(chunk, 4*w+2),
                           rom_at(chunk, 4*w+1), rom_at(chunk, 4*w)});
        end
    endtask
    task send_rom;
        integer c;
        begin for (c = 0; c < 8; c = c + 1) send_chunk(c, 8'd64); end
    endtask
    task host_move(input integer dx, input integer dy, input [1:0] buttons);
        begin
            push_word(hdr(T_MOUSE_MOVE, 8'd1, {14'd0, buttons}));
            push_word({dy[15:0], dx[15:0]});
            idle(4);
        end
    endtask

    // ---- the firmware's side of the PIA -------------------------------------
    // Data direction: a write to the port register with CRx bit 2 clear.
    task set_ddra(input [7:0] v);
        begin bus_write(CRA, 8'h00); bus_write(PRA, v); bus_write(CRA, 8'h04); end
    endtask
    task set_ddrb(input [7:0] v);
        begin bus_write(CRB, 8'h00); bus_write(PRB, v); bus_write(CRB, 8'h04); end
    endtask
    reg [7:0] page_bits = 8'h00;        // PB1-PB3 as the firmware leaves them
    // A byte to the 68705: on port A, then PB5 high and low.
    task put_byte(input [7:0] b);
        begin
            set_ddra(8'hFF);
            bus_write(PRA, b);
            bus_write(PRB, page_bits | 8'h20);
            bus_write(PRB, page_bits);
        end
    endtask
    // A byte from the 68705: the first is on port A already after the
    // command; each next one is clocked out with PB4 high and low.
    task get_byte(input first, output [7:0] b);
        begin
            set_ddra(8'h00);
            if (!first) begin
                bus_write(PRB, page_bits | 8'h10);
                bus_write(PRB, page_bits);
            end
            bus_read(PRA);
            b = cpu_din;
        end
    endtask
    task cmd(input [7:0] c);
        begin put_byte(c); idle(1); end   // the step lands after the commit
    endtask
    reg [7:0] r [0:5];
    task read_mouse;   // READ: x lo, x hi, y lo, y hi, status
        begin
            cmd(8'h10);
            get_byte(1, r[1]); get_byte(0, r[2]); get_byte(0, r[3]); get_byte(0, r[4]); get_byte(0, r[5]);
            bus_write(PRB, page_bits | 8'h10);      // the last clock-out ends the answer
            bus_write(PRB, page_bits);
        end
    endtask
    task serve_mouse(output [7:0] reason);
        begin
            cmd(8'h20);
            get_byte(1, reason);
            bus_write(PRB, page_bits | 8'h10);
            bus_write(PRB, page_bits);
        end
    endtask
    task clamp_mouse(input y, input [15:0] lo, input [15:0] hi);
        begin
            cmd(8'h60 | {7'd0, y});
            put_byte(lo[7:0]); put_byte(hi[7:0]); put_byte(lo[15:8]); put_byte(hi[15:8]);
        end
    endtask
    task pos_mouse(input [15:0] x, input [15:0] y);
        begin
            cmd(8'h40);
            put_byte(x[7:0]); put_byte(x[15:8]); put_byte(y[7:0]); put_byte(y[15:8]);
        end
    endtask
    task init_mouse;
        reg [7:0] b;
        begin
            cmd(8'h50);
            get_byte(1, b);
            if (b !== 8'hFF) fail("INIT did not answer $FF");
            put_byte(8'h00); put_byte(8'h00);
        end
    endtask

    task expect_byte(input [15:0] addr, input [7:0] want, input [8*96-1:0] why);
        begin
            bus_read(addr);
            if (cpu_din !== want) begin
                $display("  at $%04x got $%02x, wanted $%02x", addr, cpu_din, want);
                fail(why);
            end
        end
    endtask
    task expect_float(input [15:0] addr, input [8*96-1:0] why);
        expect_byte(addr, 8'hEE, why);
    endtask
    // The position lands a few clocks after the access or the move that
    // set it (the card's stages); a check waits them out.
    task expect_pos(input [15:0] x, input [15:0] y, input [8*96-1:0] why);
        begin
            idle(1);                     // a bus cycle: aligned, and long enough
            if (pos_x !== x || pos_y !== y) begin
                $display("  position (%0d,%0d), wanted (%0d,%0d)", pos_x, pos_y, x, y);
                fail(why);
            end
        end
    endtask
    task ticks(input integer n);
        begin
            repeat (n) begin
                @(posedge clk); fast_tick <= 1'b1;
                @(posedge clk); fast_tick <= 1'b0;
            end
            @(posedge clk);
        end
    endtask

    reg [7:0] b;
    // ---- the test -----------------------------------------------------------
    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        idle(4);

        // ---- case 1: nothing before the whole ROM ---------------------------
        expect_float(ROM0, "$C500 answered before a ROM was loaded");
        expect_float(PRA, "$C0D0 answered before a ROM was loaded");
        send_chunk(0, 8'd64); send_chunk(1, 8'd64); send_chunk(2, 8'd64); send_chunk(3, 8'd64);
        send_chunk(4, 8'd64); send_chunk(5, 8'd64); send_chunk(6, 8'd64);
        idle(20);
        if (rom_loaded !== 1'b0) fail("seven chunks were taken as the ROM");
        send_chunk(7, 8'd63);
        idle(20);
        if (rom_loaded !== 1'b0) fail("a 63-word chunk was taken as one");
        send_chunk(7, 8'd64);
        idle(20);
        if (rom_loaded !== 1'b1) fail("the ROM did not load");
        $display("  ok: nothing is claimed until all eight chunks land");

        // ---- case 2: the ROM page and the PIA, and nothing else -----------------
        expect_byte(ROM0, rom_at(0, 0), "$C500 is not page 0's first byte");
        expect_byte(16'hC505, rom_at(0, 5), "$C505 is not page 0's sixth byte");
        expect_byte(16'hC5FF, rom_at(0, 255), "$C5FF is not page 0's last byte");
        expect_byte(PRA, 8'h00, "$C0D0 (DDRA after reset) is not 0");
        expect_byte(CRB, 8'h00, "$C0D3 (CRB after reset) is not 0");
        expect_float(16'hC0C0, "$C0C0 was claimed: slot 4's registers");
        expect_float(16'hC0E0, "$C0E0 was claimed: slot 6's registers");
        expect_float(16'hC400, "$C400 was claimed: another slot's page");
        expect_float(16'hC800, "$C800 was claimed: there is no expansion ROM");
        bus_write(ROM0, 8'h55);
        expect_byte(ROM0, rom_at(0, 0), "a write to the ROM changed it");
        $display("  ok: the ROM page and the PIA are all that is claimed");

        // ---- case 3: the PIA's registers -----------------------------------------
        set_ddrb(8'h3E);
        expect_byte(CRB, 8'h04, "CRB did not take the write");
        bus_write(CRB, 8'h00);
        expect_byte(PRB, 8'h3E, "DDRB does not read back with CRB bit 2 clear");
        bus_write(CRB, 8'h04);
        expect_byte(PRB, 8'h40, "PRB does not read PB6 from the 68705 after reset");
        $display("  ok: the PIA's registers read and write");

        // ---- case 4: INIT, then the position is home and the clamps default ----
        init_mouse;
        expect_pos(16'd0, 16'd0, "INIT did not home the mouse");
        host_move(2000, -5, 2'b00);
        expect_pos(16'd1023, 16'd0, "the default clamps are not 0..1023");
        $display("  ok: INIT answers $FF and sets the defaults");

        // ---- case 5: SET on + movement; a move interrupts; READ, SERV --------------
        init_mouse;
        cmd(8'h03);                          // mouse on, movement interrupt
        if (mode_rd !== 4'h3) fail("SET did not take the mode");
        if (irq !== 1'b0) fail("IRQ before any event");
        host_move(10, 20, 2'b00);
        expect_pos(16'd10, 16'd20, "the move did not land");
        if (irq !== 1'b1) fail("a move with the movement interrupt on did not raise IRQ");
        serve_mouse(b);
        if (b !== 8'h02) begin $display("  reason $%02x", b); fail("SERV's reason is not movement"); end
        if (irq !== 1'b0) fail("SERV did not release IRQ");
        read_mouse;
        if (r[1] !== 8'd10 || r[2] !== 8'd0 || r[3] !== 8'd20 || r[4] !== 8'd0)
            fail("READ's position is wrong");
        if (r[5] !== 8'h20) begin $display("  status $%02x", r[5]); fail("READ's status is not 'moved since last read'"); end
        read_mouse;
        if (r[5] !== 8'h00) fail("a second READ still says moved");
        $display("  ok: a move interrupts, SERV says why and releases, READ reports it");

        // ---- case 6: READ clears the status but not the line ----------------------
        host_move(1, 0, 2'b00);
        if (irq !== 1'b1) fail("the second move did not interrupt");
        read_mouse;
        if (irq !== 1'b1) fail("READ released IRQ - only SERV may");
        if (r[5] !== 8'h20) fail("READ after the move does not say moved");
        serve_mouse(b);
        if (b !== 8'h00) fail("SERV after READ should find the status cleared (AppleWin's abnormal case)");
        if (irq !== 1'b0) fail("SERV did not release IRQ");
        $display("  ok: READ leaves the line to SERV");

        // ---- case 7: mouse on, interrupts off: no IRQ, but READ says moved ---------
        cmd(8'h01);
        host_move(3, 3, 2'b00);
        if (irq !== 1'b0) fail("a move interrupted with the movement interrupt off");
        read_mouse;
        if (r[5] !== 8'h20) fail("READ does not report the movement without the interrupt");
        $display("  ok: mode $01 reports movement without interrupting");

        // ---- case 8: the buttons -----------------------------------------------------
        cmd(8'h05);                          // on + button interrupt
        host_move(0, 0, 2'b01);
        if (irq !== 1'b1) fail("a button press did not interrupt");
        if (buttons_rd !== 2'b01) fail("the button level did not land");
        serve_mouse(b);
        if (b !== 8'h04) fail("SERV's reason is not the button");
        read_mouse;
        if (r[5] !== 8'h80) begin $display("  status $%02x", r[5]); fail("READ: current button 0 down expected"); end
        read_mouse;
        if (r[5] !== 8'hC0) fail("READ: previous and current button 0 expected");
        host_move(0, 0, 2'b10);
        serve_mouse(b);
        read_mouse;
        if (r[5] !== 8'h50) begin $display("  status $%02x", r[5]); fail("READ: previous 0, current 1 expected"); end
        host_move(0, 0, 2'b00);
        serve_mouse(b);
        $display("  ok: the buttons interrupt and READ reports previous and current");

        // ---- case 9: CLAMP, the fold, HOME, POS, CLEAR -------------------------------
        clamp_mouse(1'b0, 16'd0, 16'd100);
        host_move(500, 0, 2'b00);
        expect_pos(16'd100, 16'd23, "CLAMP X 0..100 did not hold");
        clamp_mouse(1'b1, 16'hFFEC, 16'h00D3);    // Blazing Paddles: min > max folds
        host_move(0, 1000, 2'b00);
        expect_pos(16'd100, 16'h00BF, "the folded Y clamp is not 0..$BF");
        cmd(8'h70);                          // HOME
        expect_pos(16'd0, 16'd0, "HOME did not home");
        pos_mouse(16'h0123, 16'h0045);
        expect_pos(16'h0123, 16'h0045, "POS did not place the mouse");
        read_mouse;
        if (r[1] !== 8'h23 || r[2] !== 8'h01 || r[3] !== 8'h45 || r[4] !== 8'h00)
            fail("READ after POS is wrong");
        cmd(8'h30);                          // CLEAR
        expect_pos(16'd0, 16'd0, "CLEAR did not zero the position");
        host_move(300, 300, 2'b00);
        expect_pos(16'd100, 16'h00BF, "CLEAR lost the clamps (Fantavision)");
        init_mouse;
        host_move(300, 300, 2'b00);
        expect_pos(16'd300, 16'd300, "INIT did not restore the clamps");
        serve_mouse(b);
        $display("  ok: CLAMP (folded too), HOME, POS, CLEAR keep AppleWin's rules");

        // ---- case 10: the timer ------------------------------------------------------
        cmd(8'h00);                          // everything off
        ticks(17030 + 10);
        if (irq !== 1'b0) fail("the timer interrupted with VBL mode off");
        cmd(8'h08);                          // VBL interrupt, mouse off
        ticks(17030 + 10);
        if (irq !== 1'b1) fail("the timer did not interrupt within a frame at 60 Hz");
        serve_mouse(b);
        if (b !== 8'h08) begin $display("  reason $%02x", b); fail("SERV's reason is not VBL"); end
        if (irq !== 1'b0) fail("SERV did not release the VBL interrupt");
        host_move(5, 5, 2'b00);
        if (irq !== 1'b0) fail("a move interrupted with the mouse off");
        cmd(8'h91);                          // 50 Hz
        ticks(17030 + 10);
        if (irq !== 1'b0) fail("the 50 Hz timer fired within 17030 ticks");
        ticks(20280 - 17030);
        if (irq !== 1'b1) fail("the 50 Hz timer did not fire within 20280 ticks");
        serve_mouse(b);
        $display("  ok: the timer interrupts at 60 Hz and 50 Hz of the core's ticks, VBL mode only");

        // ---- case 11: the ROM page follows PB1-PB3 ---------------------------------------
        page_bits = 8'h06;                   // page 3
        bus_write(PRB, page_bits);
        expect_byte(ROM0, rom_at(3, 0), "$C500 is not page 3's first byte");
        expect_byte(16'hC5FF, rom_at(3, 255), "$C5FF is not page 3's last byte");
        page_bits = 8'h0E;                   // page 7
        bus_write(PRB, page_bits);
        expect_byte(16'hC510, rom_at(7, 16), "$C510 is not page 7's byte 16");
        page_bits = 8'h00;
        bus_write(PRB, page_bits);
        expect_byte(ROM0, rom_at(0, 0), "$C500 did not come back to page 0");
        $display("  ok: the ROM page follows port B");

        // ---- case 12: INTCXROM takes the page, never the registers ------------------------
        bus_write(INTCXROM_ON, 8'h00);
        expect_float(ROM0, "$C500 answered with INTCXROM set");
        expect_byte(CRB, 8'h04, "$C0D3 stopped answering under INTCXROM");
        bus_write(INTCXROM_OFF, 8'h00);
        expect_byte(ROM0, rom_at(0, 0), "$C500 did not come back");
        $display("  ok: INTCXROM takes the page and leaves the registers");

        // ---- case 13: RES' resets the state, keeps the ROM ----------------------------------
        cmd(8'h0F);
        host_move(7, 7, 2'b11);
        if (irq !== 1'b1) fail("no interrupt before RES'");
        page_bits = 8'h06;
        bus_write(PRB, page_bits);
        res_n = 1'b0;
        idle(4);
        res_n = 1'b1;
        idle(4);
        page_bits = 8'h00;
        if (rom_loaded !== 1'b1) fail("RES' lost the ROM");
        if (irq !== 1'b0) fail("RES' left IRQ asserted");
        if (mode_rd !== 4'd0) fail("RES' left the mode");
        expect_pos(16'd0, 16'd0, "RES' left the position");
        expect_byte(ROM0, rom_at(0, 0), "RES' did not return the ROM page to 0");
        expect_byte(CRB, 8'h00, "RES' did not reset the PIA");
        $display("  ok: RES' resets the PIA and the 68705, keeps the ROM");

        // ---- case 14: slot 0 claims nothing; the card's reset clears the ROM ---------------
        slot_assign = 3'd0;
        idle(2);
        expect_float(ROM0, "slot 0 claimed a page");
        expect_float(PRA, "slot 0 claimed the registers");
        slot_assign = 3'd5;
        idle(2);
        expect_byte(ROM0, rom_at(0, 0), "the card did not come back in slot 5");
        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;
        idle(4);
        if (rom_loaded !== 1'b0) fail("the card's reset kept the ROM");
        expect_float(ROM0, "$C500 answered after the card's reset");
        $display("  ok: slot 0 claims nothing; the card's reset clears the ROM");

        // ---- the rules that hold throughout ---------------------------------------
        if (read_drive_unclaimed != 0) fail("the bus was driven for a read the card did not claim");
        if (unknowns != 0) fail("the receiver reported an unknown type - MOUSE_ROM/MOUSE_MOVE missing from its list");
        else $display("  ok: MOUSE_ROM and MOUSE_MOVE are known types");
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
