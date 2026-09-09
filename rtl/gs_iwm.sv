`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_iwm - the IIgs's Integrated Woz Machine, at $C0E0-$C0EF, as a STUB.
//
// THE REFERENCE IS KEGS's iwm.c: iwm_touch_switches for the soft switches,
// read_iwm and write_iwm for the data path, iwm_read_status35 for the 3.5"
// status, iwm_read_enable2_handshake for the SmartPort handshake.
//
// WHAT IT IS FOR, EXACTLY (the user's, 2026-09-09): the machine boots from the
// EMULATED SMARTPORT DRIVE IN SLOT 7, never from the IWM.  So this module's
// whole job is to make the ROM's startup scan give up on the IWM quickly and
// move on.  It is not a drive and is not on the way to being one; fidelity
// beyond "there is nothing here, stop asking" is not wanted and would be work
// spent in the wrong place.  The card's own slot-6 Disk II and slot-7
// SmartPort HDC are the machine's real drives, in their own $Cnxx pages.
//
// It still has to be a BELIEVABLE empty IWM, because the ROM talks to the chip
// before it ever asks about a disk, and a chip that answers nonsense hangs it
// (see below).  Believable and empty, and no more than that.
//
// AND IT IS NOT OPTIONAL.  Without it the ROM hangs, at $FF/4720:
//
//     FF/4711  BIT $C0E8      ; motor off
//     FF/4714  BIT $C0ED      ; Q6 = 1
//     FF/4717  LDA $C0EE      ; Q7 = 0, read status
//     FF/471A  AND #$20       ; ...until the motor is really off
//     FF/4720  STY $C0EF      ; Q7 = 1: write the MODE register
//     FF/4723  TYA
//     FF/4724  EOR $C0EE      ; read it back
//     FF/4727  AND #$1F
//     FF/4729  BNE $4720      ; loop until the low five bits agree
//
// A backplane that answers $00 never agrees, and the machine spins there for
// ever: found by running the bench past five million instructions and finding
// the PC had not moved since the first (docs/GS.md rung 3c).
//
// THE ADDRESS IS THE REGISTER.  $C0E0-$C0EF is eight pairs of soft switches:
// the low bit is the value and the rest select which.  $C0E0-$C0E7 are the
// four phase lines, $C0E8/9 the motor, $C0EA/B the drive select, $C0EC/D Q6
// and $C0EE/F Q7.  Every access touches its switch, READ OR WRITE, before
// anything else happens - which is why the ROM can use BIT to set them.
//
// WHAT Q7:Q6 SELECT on an EVEN address (read_iwm):
//   0 0  the data register - $FF with the motor off, which is this stub always
//   0 1  the STATUS register: {write_protect, motor_on, mode[4:0]}
//   1 0  the write handshake - $C0/$80 alternating under ENABLE2
//   1 1  nothing (a read of an odd address returns 0)
// An ODD address with Q7:Q6 = 1,1 and the motor OFF writes the MODE register,
// five bits; with the motor ON it would be a data write, which a stub drops.
//
// PHASES 1 AND 3 TOGETHER ARE `ENABLE2`, the SmartPort's select.  KEGS's
// handshake answers $C0 three times and then $80, which is what makes the
// ROM's SmartPort probe give up rather than wait; that is the whole reason
// this stub has any state beyond the mode register.
//////////////////////////////////////////////////////////////////////////////////
module gs_iwm (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,       // synchronised RES', ACTIVE LOW

    // The registered op and its retire.
    input  wire [7:0]  op_lo,          // the low byte of $C0xx
    input  wire        op_rw,
    input  wire [7:0]  op_wdata,
    input  wire        act,

    output logic [7:0] rd_byte,

    // $C031 DISKREG, AND THE TWO BITS ARE NOT THE WAY ROUND THEY LOOK.
    // iwm.h is explicit: IWM_BIT_C031_APPLE35SEL is 6 and IWM_BIT_C031_CTRL
    // is 7 - so BIT 6 selects the 3.5" drives over the 5.25", and BIT 7 is
    // the control line the 3.5" status multiplexer reads as one of its four
    // select bits.  They were wired the other way round until 2026-09-09,
    // which left apple35_sel low whenever the ROM had actually asked for the
    // 3.5" path: the status register then answered from the 5.25" arm, a
    // CONSTANT write-protect of 1, where the reference walks the mux and
    // returns a different bit for each phase the ROM steps to.  docs/GS.md.
    input  wire        apple35_sel,
    input  wire        c031_ctrl,

    // Diagnostics.
    output logic [7:0] cnt_mode_wr
);

    logic [4:0] mode;               // the IWM mode register
    logic [3:0] phases;
    logic       motor_on;
    logic       drive_sel;
    logic       q6, q7;
    logic [1:0] hs_count;           // the ENABLE2 handshake's three-then-one

    wire enable2 = (phases[1] && phases[3]);
    wire iwm_reset = (phases[0] && phases[2]);

    // ---- the read, composed from the state as it stands ----------------------
    // The switch this access touches has NOT been applied yet when the byte is
    // taken: on real hardware the access and the switch are the same event,
    // and KEGS calls iwm_touch_switches BEFORE it composes the byte.  So the
    // byte is composed from the state the touch WOULD leave, which for the two
    // switches that matter here - Q6 and Q7 - is spelled out.
    wire       t_q6 = (op_lo[3:1] == 3'd6) ? op_lo[0] : q6;
    wire       t_q7 = (op_lo[3:1] == 3'd7) ? op_lo[0] : q7;
    wire [1:0] q7q6 = {t_q7, t_q6};

    // ---- the 3.5" status is a MULTIPLEXER (iwm_read_status35) ---------------
    // Not one bit: the phase lines and $C031's control bit select WHICH sense
    // line bit 7 carries, and the answers differ.  A single constant here is
    // what sent the machine into unpopulated RAM on the first attempt, so the
    // whole mux is spelled out with the answers a machine WITH NO 3.5" DRIVE
    // gives (docs/GS.md's decision: no drive, so the ROM's scan ends).
    //
    //   stat35 = {phase[1], phase[0], $C031 bit 6, phase[2]}
    //
    // KEGS's own answers, with dsk->num_tracks 0, write_prot 1, the motor35
    // off and the head at track 0 - except $0F, "drive installed", where KEGS
    // says drive 0 exists because it emulates one and this says neither does.
    wire [3:0] stat35 = {phases[1], phases[0], c031_ctrl, phases[2]};
    logic status35;
    always_comb begin
        if (!motor_on) begin
            status35 = 1'b1;                 // "Read 3.5 status with drive off"
        end else begin
            case (stat35)
                4'h0: status35 = 1'b0;       // step direction
                4'h1: status35 = 1'b0;       // lower head: instantaneous data
                4'h2: status35 = 1'b1;       // disk in place: 1 = NO disk
                4'h3: status35 = 1'b0;       // upper head
                4'h4: status35 = 1'b1;       // 1 = not stepping
                4'h5: status35 = 1'b1;       // ROM 3's unknown function
                4'h6: status35 = 1'b0;       // disk locked: !write_prot, and it is
                4'h8: status35 = 1'b1;       // motor: 1 = off, and it always is
                4'h9: status35 = 1'b1;       // 1 = two sides
                4'hA: status35 = 1'b0;       // at track 0: 0 = there
                4'hB: status35 = 1'b1;       // ready: 1 = not ready
                4'hC: status35 = 1'b0;       // switched: 0 = not
                4'hD: status35 = 1'b1;       // the false read when ejecting
                4'hE: status35 = 1'b0;       // tachometer
                4'hF: status35 = 1'b1;       // drive installed: 1 = NO DRIVE
                default: status35 = 1'b1;
            endcase
        end
    end
    // A 5.25" drive with no disk reads write-protected (iwm.c:133 - the
    // drive's own init sets write_prot, and no image clears it).
    wire wr_prot = apple35_sel ? status35 : 1'b1;

    // KEGS: val = ((write_prot & 1) << 7) | (state & 0x3f), and state's bit 5
    // is motor_on with the mode in [4:0].  Bit 6 is outside that mask and
    // reads zero.
    //
    // BIT 5 READS ZERO HERE, AND THAT IS THE WHOLE POINT OF THE MODULE.  KEGS
    // reports the IWM's own motor LATCH, because KEGS has drives for it to
    // spin; a real machine's latch is followed by a real motor, and the ROM
    // waits for that motor to stop:
    //
    //     FF/4717  LDA $C0EE / AND #$20 / BNE $4717     ; and again at
    //     FF/5B71  LDA $C08E,X / AND #$20 / BNE $5B71   ; ...$FF/5B71
    //
    // Reporting the latch makes both of those spin for ever, because nothing
    // here ever stops spinning.  THERE IS NO DRIVE, SO THERE IS NO MOTOR: the
    // status says so, both loops fall straight through, and the scan moves on
    // to slot 7.  The latch itself is kept - `motor_on` still gates the data
    // register below, as the chip's own does - it simply is not what the
    // drive's status line reports.
    wire [7:0] status_byte = {wr_prot, 2'b00, mode};
    wire [7:0] handshake   = (hs_count == 2'd3) ? 8'h80 : 8'hC0;

    // ---- the data register, with no disk under the head --------------------
    // A CONSTANT HERE HANGS THE ROM.  At $FF/57B7 the SmartPort routine reads
    // the data register and waits for a byte with bit 6 CLEAR:
    //
    //     FF/57B7  LDA $C08C,X    ; the data register
    //     FF/57BA  AND #$40
    //     FF/57BC  BNE $57B7
    //
    // A real IWM with no disk still has a head over a spinning surface, so
    // the byte varies; KEGS returns ((fbit_pos * 25) >> 11) & 0xff from the
    // drive's bit position (iwm.c:1588), which advances with time.  This
    // stands in for that position: it advances on every read of the register,
    // so the byte changes and the loop ends.  With the motor OFF KEGS returns
    // $FF outright, and so does this.
    logic [23:0] fbit;
    wire [31:0] fbit_scaled = fbit * 24'd25;
    wire [7:0]  data_byte = fbit_scaled[18:11];

    always_comb begin
        if (op_lo[0]) begin
            rd_byte = 8'h00;            // an odd address reads zero
        end else begin
            case (q7q6)
                2'b00:   rd_byte = enable2  ? 8'hFF
                                 : motor_on ? data_byte
                                            : 8'hFF;
                2'b01:   rd_byte = status_byte;
                // THERE IS NO DRIVE, SO THERE IS NOTHING TO UNDERRUN, which
                // is the same argument as the motor's above.  Bit 7 of the
                // handshake is "data register ready" and BIT 6 IS THE WRITE
                // UNDERRUN, which KEGS CLEARS (`status & 0xbf`, iwm.c case
                // 0x02) as soon as the head has moved more than eight bits
                // past the last bit written - so on a machine with nothing
                // writing it is always clear.  A constant $C0 says "a write
                // is in progress and keeping up", for ever, and the ROM's
                // SmartPort probe spins on exactly that:
                //
                //     FF/57B7  LDA $C08C,X / AND #$40 / BNE $57B7
                //
                // The reference trace visits $FF/57B7 ONCE in five million
                // instructions and reads $80 there, falling straight through
                // to a bounded retry.  So does this now.
                2'b10:   rd_byte = enable2 ? handshake : 8'h80;
                default: rd_byte = 8'h00;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            mode <= 5'd0;
            phases <= 4'd0;
            motor_on <= 1'b0;
            drive_sel <= 1'b0;
            q6 <= 1'b0; q7 <= 1'b0;
            hs_count <= 2'd0;
            fbit <= 24'd0;
            cnt_mode_wr <= 8'd0;
        end else if (act) begin
            // ---- every access touches its switch first --------------------
            case (op_lo[3:1])
                3'd0, 3'd1, 3'd2, 3'd3:
                    phases[op_lo[2:1]] <= op_lo[0];
                3'd4: motor_on  <= op_lo[0];
                3'd5: drive_sel <= op_lo[0];
                3'd6: q6        <= op_lo[0];
                default: q7     <= op_lo[0];
            endcase

            // ---- then the data path ---------------------------------------
            if (!op_rw && op_lo[0] && (q7q6 == 2'b11) && !motor_on) begin
                // The MODE register: five bits, and only with the motor off.
                mode <= op_wdata[4:0];
                cnt_mode_wr <= cnt_mode_wr + 8'd1;
            end
            // The head moves on: one bit per read, as a spinning surface
            // would give.  1024 is one bit in KEGS's 512ths-of-a-bit units,
            // doubled so the scaled byte changes on every read.
            if (op_rw && !op_lo[0] && !enable2 && motor_on && (q7q6 == 2'b00))
                fbit <= fbit + 24'd1024;
            // The SmartPort handshake answers $C0 three times and then $80,
            // so a probe under ENABLE2 terminates (iwm_read_enable2_handshake).
            if (op_rw && !op_lo[0] && enable2 && (q7q6 == 2'b10)) begin
                if (hs_count == 2'd3) hs_count <= 2'd0;
                else                  hs_count <= hs_count + 2'd1;
            end
        end
    end

    // The reset line the phases can assert is decoded but drives nothing: with
    // no drive there is nothing to reset.  Named so the decode is visible.
    wire _unused_reset = iwm_reset;
endmodule
