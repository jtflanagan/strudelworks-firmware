`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// vidhd_card_tb - the VidHD's slot ROM behind the real driver, with the tb
// playing both the program and the host.
//
// A scripted CPU (floppy_card_tb's) presents one op per bus cycle through
// the real apple_bus_write; the real ft601_msg_rx feeds the card the host's
// ROM.  The card has nothing to say back, so there is no arbiter here.
//
// THE PROPERTIES, each a way this is or could be wrong:
//
//   * nothing is claimed until the host has loaded the ROM, and a ROM
//     message of the wrong length is not a ROM.
//   * $Cn00-$CnFF reads the ROM - the signature at $Cn00, the rest of it -
//     and nothing else does: not $C0nx, not the IIgs's video registers, not
//     another slot's page.
//   * in slot 3 the page is the motherboard's until SLOTC3ROM is set, and
//     INTCXROM takes it back; in another slot only INTCXROM matters.
//   * slot 0 claims nothing.
//   * RES' clears the switches, not the ROM; the card's reset clears both.
//   * the bus is never driven for a read the card did not claim, and the
//     card never raises an override.
//////////////////////////////////////////////////////////////////////////////////

module vidhd_card_tb;

    localparam integer T_PRESENT = 2;
    localparam integer T_EMIT    = 2;
    localparam integer T_DIN     = 44;
    localparam integer T_CYCEN   = 45;

    localparam [7:0] T_VIDHD_ROM = 8'h23;

    localparam [15:0] ELSEWHERE = 16'h1234;
    localparam [15:0] INTCXROM_OFF = 16'hC006, INTCXROM_ON = 16'hC007;
    localparam [15:0] SLOTC3ROM_OFF = 16'hC00A, SLOTC3ROM_ON = 16'hC00B;

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
    reg         res_n = 1'b1;           // active low, idle high

    wire [15:0] op_addr;
    wire        op_rw, op_present, op_commit, op_ovr;
    wire [7:0]  op_wdata;
    wire        rd_claim;
    wire [7:0]  rd_data;
    wire [15:0] addr_drive;
    wire        rw_drive, addr_rw_oe, data_oe, dma_assert, drv_sync, driving;
    wire [7:0]  data_drive;

    // The round trip: the float is $EE, so a read of it cannot pass by luck.
    wire [7:0] data_sync = data_oe ? data_drive : 8'hEE;

    apple_bus_write #(
        .T_PRESENT (T_PRESENT), .T_EMIT (T_EMIT),
        .T_DIN (T_DIN), .T_CYCEN (T_CYCEN)
    ) u_write (
        .clk (clk), .rst (rst),
        .phi0_sync (phi0), .data_sync (data_sync),
        .master_active (master_active),
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

    wire        msg_valid, pay_valid, frame_error;
    wire [7:0]  msg_type, msg_len;
    wire [15:0] msg_free;
    wire [31:0] pay_data;

    ft601_msg_rx u_rx (
        .clk (clk), .rst (rst),
        .fifo_dout (rx_dout), .fifo_empty (rx_empty), .fifo_rd_en (rx_rd_en),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .frame_error (frame_error)
    );

    // ---- the VidHD ----------------------------------------------------------
    reg  [2:0]  slot_assign = 3'd3;
    wire        rom_loaded;

    vidhd_card dut (
        .clk (clk), .rst (rst), .res_sync (res_n),
        .master_active (master_active), .slot_assign (slot_assign),
        .op_addr (op_addr), .op_rw (op_rw),
        .op_present (op_present), .op_commit (op_commit), .op_ovr (op_ovr),
        .rd_claim (rd_claim), .rd_data (rd_data),
        .msg_valid (msg_valid), .msg_type (msg_type), .msg_free (msg_free),
        .msg_len (msg_len), .pay_data (pay_data), .pay_valid (pay_valid),
        .rom_loaded (rom_loaded)
    );

    // ---- observers ----------------------------------------------------------
    integer read_drive_unclaimed = 0;
    always @(posedge clk) if (!rst) begin
        if (data_oe && rw_drive && !rd_claim)
            read_drive_unclaimed = read_drive_unclaimed + 1;
    end
    integer overrides = 0;
    always @(posedge clk) if (op_present && op_ovr) overrides = overrides + 1;
    // Sticky: the card's reset in the last case would otherwise clear the
    // parser's flag before it is checked.  An unknown type is a framing
    // error, and a framing error resets the link on the real card.
    integer frame_errors = 0;
    always @(posedge clk) if (frame_error) frame_errors = frame_errors + 1;

    // ---- the host's ROM -----------------------------------------------------
    // What strudelworks-host synthesises: the signature, a JMP to an RTS,
    // and zeros - for slot n.
    function [7:0] rom_at(input integer slot, input integer i);
        case (i)
            0:       rom_at = 8'h24;
            1:       rom_at = 8'hEA;
            2:       rom_at = 8'h4C;
            3:       rom_at = 8'h05;
            4:       rom_at = 8'hC0 | slot[7:0];
            5:       rom_at = 8'h60;
            default: rom_at = 8'h00;
        endcase
    endfunction
    task send_rom(input integer slot, input [7:0] len);
        integer w;
        begin
            push_word(hdr(T_VIDHD_ROM, len, 16'd0));
            for (w = 0; w < len; w = w + 1)
                push_word({rom_at(slot, 4*w+3), rom_at(slot, 4*w+2),
                           rom_at(slot, 4*w+1), rom_at(slot, 4*w)});
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

    // ---- the test -----------------------------------------------------------
    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        idle(4);

        // ---- case 1: nothing before the ROM, and a wrong-length ROM is not one --
        bus_write(SLOTC3ROM_ON, 8'h00);
        expect_float(16'hC300, "$C300 answered before a ROM was loaded");
        send_rom(3, 8'd63);
        idle(20);
        if (rom_loaded !== 1'b0) fail("a 63-word ROM message was taken as the ROM");
        expect_float(16'hC300, "$C300 answered on a short ROM");
        send_rom(3, 8'd64);
        idle(20);
        if (rom_loaded !== 1'b1) fail("the ROM did not load");
        $display("  ok: nothing is claimed until the whole ROM lands");

        // ---- case 2: the ROM reads back: the signature, the rest, the end ----------
        expect_byte(16'hC300, 8'h24, "$C300 is not the signature's first byte");
        expect_byte(16'hC301, 8'hEA, "$C301 is not the signature's second byte");
        expect_byte(16'hC302, 8'h4C, "$C302 is not the signature's third byte");
        expect_byte(16'hC303, 8'h05, "$C303 is not the JMP's low byte");
        expect_byte(16'hC304, 8'hC3, "$C304 is not the JMP's high byte");
        expect_byte(16'hC305, 8'h60, "$C305 is not the RTS");
        expect_byte(16'hC306, 8'h00, "$C306 is not zero");
        expect_byte(16'hC3FF, 8'h00, "$C3FF is not zero");
        $display("  ok: the ROM reads back - the signature at $Cn00, an RTS to jump to");

        // ---- case 3: only the slot's page ------------------------------------------
        expect_float(16'hC0B0, "$C0B0 was claimed: a VidHD has no device-select registers");
        expect_float(16'hC0BF, "$C0BF was claimed");
        expect_float(16'hC029, "$C029 was claimed: NEWVIDEO is never answered");
        expect_float(16'hC022, "$C022 was claimed");
        expect_float(16'hC034, "$C034 was claimed");
        expect_float(16'hC200, "$C200 was claimed: another slot's page");
        expect_float(16'hC400, "$C400 was claimed: another slot's page");
        expect_float(16'hC800, "$C800 was claimed: there is no expansion ROM");
        bus_write(16'hC300, 8'h55);
        expect_byte(16'hC300, 8'h24, "a write to the ROM changed it");
        $display("  ok: the page is the only thing claimed, and it is read-only");

        // ---- case 4: slot 3 follows SLOTC3ROM and INTCXROM ---------------------------
        bus_write(SLOTC3ROM_OFF, 8'h00);
        expect_float(16'hC300, "$C300 answered with SLOTC3ROM clear: that is the 80-column firmware's");
        bus_write(SLOTC3ROM_ON, 8'h00);
        expect_byte(16'hC300, 8'h24, "$C300 did not come back with SLOTC3ROM set");
        bus_write(INTCXROM_ON, 8'h00);
        expect_float(16'hC300, "$C300 answered with INTCXROM set");
        bus_write(INTCXROM_OFF, 8'h00);
        expect_byte(16'hC300, 8'h24, "$C300 did not come back with INTCXROM clear");
        $display("  ok: slot 3's page follows SLOTC3ROM and INTCXROM");

        // ---- case 5: RES' clears the switches, not the ROM ---------------------------
        res_n = 1'b0;
        idle(4);
        res_n = 1'b1;
        idle(4);
        if (rom_loaded !== 1'b1) fail("RES' lost the ROM");
        expect_float(16'hC300, "$C300 answered after RES' - SLOTC3ROM should have cleared");
        bus_write(SLOTC3ROM_ON, 8'h00);
        expect_byte(16'hC300, 8'h24, "$C300 did not come back after RES'");
        $display("  ok: RES' clears the switches and keeps the ROM");

        // ---- case 6: another slot: only INTCXROM matters, and the JMP is its own --
        slot_assign = 3'd5;
        send_rom(5, 8'd64);
        idle(20);
        bus_write(SLOTC3ROM_OFF, 8'h00);
        expect_byte(16'hC500, 8'h24, "$C500 does not read the ROM in slot 5");
        expect_byte(16'hC504, 8'hC5, "slot 5's JMP does not point into slot 5");
        expect_float(16'hC300, "$C300 answered while the card is in slot 5");
        bus_write(INTCXROM_ON, 8'h00);
        expect_float(16'hC500, "$C500 answered with INTCXROM set");
        bus_write(INTCXROM_OFF, 8'h00);
        expect_byte(16'hC500, 8'h24, "$C500 did not come back");
        $display("  ok: slot 5 answers without SLOTC3ROM and follows INTCXROM");

        // ---- case 7: slot 0 claims nothing -------------------------------------------
        // (A card without the bus - master_active low - presents no ops at
        // all through this driver, so there is nothing to claim and nothing
        // to test here; the gate is the same wire hd_card's and floppy_card's
        // use.)
        slot_assign = 3'd0;
        idle(2);
        expect_float(16'hC500, "slot 0 claimed a page");
        slot_assign = 3'd5;
        idle(2);
        expect_byte(16'hC500, 8'h24, "the card did not come back in slot 5");
        $display("  ok: slot 0 claims nothing");

        // ---- case 8: the card's reset clears the ROM ---------------------------------
        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;
        idle(4);
        if (rom_loaded !== 1'b0) fail("the card's reset kept the ROM");
        expect_float(16'hC500, "$C500 answered after the card's reset");
        $display("  ok: the card's reset clears the ROM");

        // ---- the rules that hold throughout ---------------------------------------
        if (read_drive_unclaimed != 0) fail("the bus was driven for a read the card did not claim");
        if (overrides != 0) fail("the card raised an override");
        if (frame_errors != 0) fail("the parser saw a frame error - VIDHD_ROM is not in ft601_msg_rx's hdr_known");
        else $display("  ok: VIDHD_ROM is a known type");

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
