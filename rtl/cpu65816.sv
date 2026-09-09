`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// cpu65816 - a microcoded 65C816, built around the bus cycle.
//
// STATUS: VERIFIED AGAINST SingleStepTests/65816 (2026-09-08): 981,610 cases,
// native and emulated, every cycle's address, direction, data and VDA/VPA/VPB,
// the count, and the state after - sim/run_cpu816_trace.sh.  The cycle
// STRUCTURE is also held to the suite's counts by sim/gen_cycle_table816.py.
// Not covered by the suite: reset, IRQ, NMI, ABORT entry and MLB.  The GS
// programme's core (docs/GS.md rung 1); the exploration that produced it is
// docs/UCODE816.md.
//
// THE INVARIANT.  Every microinstruction is exactly one bus cycle, and every bus
// cycle is one microinstruction.  An instruction's cycle count is the number of
// microinstructions it executes, and a dummy cycle is an ordinary
// microinstruction that happens to discard din.  The ROM is addressed by
// {opcode, ucycle} with no mapping stage, so there is no instruction decoder in
// the design - the 256-way decode that dominates a state-machine core's critical
// path does not exist as logic at all.
//
// THE AGU IS 16 BITS WIDE, and it is worth knowing exactly which mode forces
// that, because most of them do not.  Microcode earns its place by spreading
// work across the cycles the instruction set already grants, and the 65816 is
// generous - long,X decomposes into an 8-bit add in the cycle that reads the
// address high byte and another in the cycle that reads the bank byte; abs,X
// puts its high add in the fixup cycle granted for a page cross.  But:
//
//   *** (dp),Y reads the pointer's high byte and produces the final effective
//       address in the SAME cycle - ADL = MDL + YL and ADH = din + YH + carry,
//       together.  The one cycle it grants is already spent on the page-cross
//       fixup.  [dp],Y and (sr,S),Y are the same shape, and [dp],Y carries on
//       into the bank byte as well. ***
//
// So the AGU is a real 16-bit adder with an 8-bit bank incrementer above it.
// Out of context on xc7a35tftg256-2 the core closes at ~122 MHz, and the binding
// path is the sequencer loop - the microcode ROM's output back to its own
// address input.  The AGU is IN that loop, though not as address arithmetic:
// COND_CARRY/COND_IDX/COND_PAGE test its carry out live, so the next ROM address
// cannot form until the add has resolved.  The largest single term in the path
// is not logic at all, but 2.1 ns of block RAM clock-to-out, paid by every path
// out of the ROM before any logic runs.
//
// Reading BOTH successors on the block RAM's second port, so that the condition
// picks a fetched WORD instead of an ADDRESS, was prototyped: it works, costs no
// extra block RAM, removes the loop from the top twenty paths entirely - and
// gains 0.3 MHz, because the loop led the next path by almost nothing and the
// design is simply balanced at ~8.2 ns.  It was reverted for +82 LUTs of no
// benefit; see docs/UCODE816.md, and git history on this branch for the code.
// The only lever left against the shared 2.1 ns is the ROM's optional output
// register, which makes the read two cycles deep - so two cycles of lookahead,
// so FOUR candidate successors, so two copies of the ROM: 16 RAMB36 for
// ~143 MHz.
//
// THE ALU, by contrast, stays 8 bits wide.  Every 16-bit memory operation takes
// two bus cycles because the operand is two bytes, and the instruction set
// charges for both - so ADC #$1234 is two 8-bit adds in the two cycles it was
// already going to spend.  Only the operations that are two cycles REGARDLESS of
// width - INC A, ASL A, the transfers, the 16-bit half of an RMW - need to move
// sixteen bits at once, and none of those is an add against an arbitrary second
// operand.  They get a shift/increment unit, which is carry chain without
// operand muxing.
//
// THE MODE BITS DO NOT INDEX THE ROM.  An instruction's length here depends on
// m, x, DL and e.  Widening the ROM address with them would multiply it by
// eight, to 64 block RAMs, which does not fit the part at all; instead every
// mode-dependent cycle is a conditional slot the sequencer skips.  A condition
// selects the SUCCESSOR slot - it does not suppress the microinstruction
// carrying it - so a cycle that must be skipped is tested by the slot before it.
//
// TIMING CONTRACT.  One bus cycle per `cyc_en` pulse.  addr/rw/dout
// are driven from the ROM output register and the register file, so they settle
// just after the edge that begins their cycle and are stable across it; din is
// sampled by the edge that ends it.
//
// WHAT IS NOT IMPLEMENTED: MLB and ABORT.  VDA/VPA/VPB are outputs, from a
// microcode field and the vector address sources; sim/run_cpu816_trace.sh
// checks them against the suite.  See docs/UCODE816.md.
//
// A CYCLE WITH VDA LOW IS NOT A MEMORY ACCESS, AND ITS ADDRESS MEANS NOTHING.
// This is the part's own rule and an integrator MUST apply it: gate the write
// with VDA - `rw | ~vda` - before anything downstream sees it.  `rw` alone is
// not enough, because the part drives R/W LOW through the internal cycle of a
// read-modify-write (the 6502's dummy write, which the reference's cycle list
// shows), and the address this core leaves on the pins for that cycle is the
// operand's PLUS ONE on the M-sized RMWs: their read slot is shared with the
// 16-bit path, which has already stepped forward, and the 8-bit tail steps
// back a cycle later.  Trusting the bare R/W is what made the IIgs boot ask
// its disk for block $0203 where it meant 3 - docs/GS.md rung 3e.
//////////////////////////////////////////////////////////////////////////////////

module cpu65816 #(
    // Both generated by sim/gen_microcode816.py and committed.
    parameter UCODE_FILE  = "cpu65816_ucode.hex",
    parameter UCODE0_FILE = "cpu65816_ucode0.hex",
    parameter USEQ0_FILE  = "cpu65816_useq0.hex"
) (
    input  wire         clk,
    input  wire         rst,        // synchronous; starts the reset sequence
    input  wire         cyc_en,     // one pulse per bus cycle

    output wire  [23:0] addr,       // 24-bit: {bank, high, low}
    output wire         rw,         // 1 = read, 0 = write
    output wire  [7:0]  dout,
    input  wire  [7:0]  din,

    input  wire         irq_n,      // level sensitive, active low
    input  wire         nmi_n,      // edge sensitive, active low

    output wire         sync,       // high during an opcode fetch
    output wire         vda,        // valid data address
    output wire         vpa,        // valid program address (both on a fetch)
    output wire         vpb,        // vector pull, active high here
    output wire         emu,        // E flag: 1 = 6502 emulation mode
    output wire         halted      // STP executed; only rst clears it
);

`include "cpu65816_ucode.vh"

    // ---- microcode ROM ------------------------------------------------------
    // {opcode, ucycle}: 4096 x 66 bits.  Sixteen slots per opcode because a
    // 16-bit RMW under a non-zero direct page runs to nine cycles and the block
    // moves need a loop slot on top; 11 is the deepest actually used.
    //
    // DECODE ONCE, THEN RUN FROM REGISTERS - which is how the original part
    // works, and the reason every 6502 instruction takes at least two cycles.
    // The first cycle decodes; the cycles after it are driven by the REGISTERED
    // result of that decode rather than by consulting the control store again.
    //
    // Read straight, a block RAM microcode store puts its own clock-to-out -
    // 2.1 ns on this part, a quarter of the cycle - at the head of every path in
    // the core, before a single LUT.  So the store is read ONE CYCLE AHEAD and
    // parked in a fabric flop, whose clock-to-Q is about 0.4 ns:
    //
    //   cycle N-1 : block RAM reads the microinstruction for cycle N
    //   edge N    : it lands in uc_q
    //   cycle N   : the datapath runs from uc_q, a flop
    //
    // That needs the address a further cycle ahead, and the trick that makes it
    // affordable is that `urom` - the block RAM output during cycle N - ALREADY
    // holds the microinstruction for cycle N+1, cond and alt fields included.
    // So the successor of the successor can be computed from it directly, and
    // the microcode image needs no lookahead field and no reordering.
    //
    // Evaluating a condition a cycle early is only legal because of what the
    // conditions test: 1146 of 1521 slots are unconditional, 302 test mode state
    // (m, x, DL, decimal, e) which is INSTRUCTION-INVARIANT - no instruction
    // tests a mode it has already rewritten - and 10 test registered flags that
    // the intervening cycle does not touch.  See docs/UCODE816.md.  The
    // remaining 33 test a carry produced in the very cycle that tests it, and
    // are handled by the early-carry adder below.
    localparam int UA_W = 8 + UC_SLOTS_LOG2;

    (* rom_style = "block" *) logic [UC_W-1:0] ucode [0:(1 << UA_W) - 1];
    initial $readmemh(UCODE_FILE, ucode);

    // Slot 0 of every opcode, in distributed RAM.  The opcode arrives on din at
    // the END of its fetch cycle, so the first microinstruction is the one that
    // cannot have been prefetched - nothing was available to address the block
    // RAM with.  This is that constraint's answer, and it is why the original
    // part cannot execute an instruction in one cycle either.  256 words read
    // combinationally from the registered opcode, ~1 ns rather than 2.1.
    (* rom_style = "distributed" *) logic [UC_W-1:0] ucode0 [0:255];
    initial $readmemh(UCODE0_FILE, ucode0);

    logic [UC_W-1:0] urom;          // block RAM output: NEXT cycle's microinstruction
    logic [UC_W-1:0] uc_q;          // the flop the datapath actually runs from
    logic            use_dec;       // this cycle is slot 0: take the decode ROM
    logic [UA_W-1:0] uaddr;         // combinational

    // The wide decode ROM is addressed by `ir` ALONE, and that is a timing
    // decision, not a convenience.  Slot 0's branch decision has to be made
    // during the fetch cycle, from the opcode still arriving on din - but if the
    // wide ROM served that read too, its address would depend on din and on the
    // interrupt decision, and since its output feeds the whole datapath through
    // `uc`, static timing would put `f_i -> take_int -> ROM -> everything` in
    // front of every register in the core.  Measured: doing exactly that cost
    // 14 MHz.  The fetch-cycle read gets its own 8-bit ROM below instead.
    wire [UC_W-1:0] dec_word = ucode0[ir];
    wire [UC_W-1:0] uc = use_dec ? dec_word : uc_q;

    // Slot 0's cond/alt only, addressed by the opcode arriving now.  Eight bits
    // wide, so this feeds the next-address logic and nothing else.
    (* rom_style = "distributed" *) logic [7:0] useq0 [0:255];
    initial $readmemh(USEQ0_FILE, useq0);

    wire [7:0] fetch_op = take_int ? 8'h00 : din;
    wire [7:0] seq0     = useq0[fetch_op];

    // Field extraction.  Positions come from the generated header, so these
    // cannot drift from the assembler.
    // f_sync is taken from the FLOP rather than from `uc`, which is what keeps
    // the decode ROM's address out of its own cone: `uc` would otherwise depend
    // on dec_word, which depends on take_int, which depends on f_sync.  The two
    // are identical because no opcode's slot 0 is itself a fetch - the minimum
    // instruction is two microinstructions, checked by the generator.  A
    // one-cycle opcode would break this equality, and the symptom would be a
    // combinational loop reported by the linter.
    wire       f_sync   = ~use_dec & uc_q[UCP_SYNC];
    wire       f_rw     = uc[UCP_RW];
    wire [2:0] f_asel   = uc[UCP_ADDR_SEL +: 3];
    wire [2:0] f_lo_a   = uc[UCP_LO_A     +: 3];
    wire [2:0] f_lo_b   = uc[UCP_LO_B     +: 3];
    wire       f_lo_ci  = uc[UCP_LO_CI];
    wire [2:0] f_hi_a   = uc[UCP_HI_A     +: 3];
    wire [2:0] f_hi_b   = uc[UCP_HI_B     +: 3];
    wire [1:0] f_hi_c   = uc[UCP_HI_C     +: 2];
    wire [1:0] f_hi_d   = uc[UCP_HI_D     +: 2];
    wire       f_bk_a   = uc[UCP_BK_A];
    wire [1:0] f_bk_c   = uc[UCP_BK_C     +: 2];
    wire [1:0] f_ld_adl = uc[UCP_LD_ADL   +: 2];
    wire [1:0] f_ld_adh = uc[UCP_LD_ADH   +: 2];
    wire [2:0] f_ld_bk  = uc[UCP_LD_BK    +: 3];
    wire [3:0] f_ld_pc  = uc[UCP_LD_PC    +: 4];
    wire [2:0] f_ld_s   = uc[UCP_LD_S     +: 3];
    wire [4:0] f_dout   = uc[UCP_DOUT     +: 5];
    wire [4:0] f_alu_op = uc[UCP_ALU_OP   +: 5];
    wire [2:0] f_alu_a  = uc[UCP_ALU_A    +: 3];
    wire [4:0] f_wb     = uc[UCP_WB       +: 5];
    wire [1:0] f_fl     = uc[UCP_FL       +: 2];
    wire       f_seti   = uc[UCP_SETI];
    wire       f_ew     = uc[UCP_EW];
    wire [1:0] f_bus    = uc[UCP_BUS      +: 2];
    wire [3:0] f_cond   = uc[UCP_COND     +: 4];
    wire [3:0] f_alt    = uc[UCP_ALT      +: 4];

    // ---- architectural state ------------------------------------------------
    logic [15:0] a, x, y, s, d;
    logic [15:0] pc;
    logic [7:0]  dbr, pbr;
    logic        f_n, f_v, f_m, f_x, f_d, f_i, f_z, f_c, f_e;
    logic [7:0]  ir;
    logic [7:0]  adl, adh, bank;    // effective address under construction
    logic [15:0] md;                // scratch: RMW result, pointer, jump target
    logic [3:0]  ucyc;      // slot index of THIS cycle's microinstruction
    logic [3:0]  nslot;     // slot index of NEXT cycle's microinstruction
    logic        agu_c, agu_hc;     // carries SAVED from a previous AGU cycle
    logic        in_rst, int_brk, int_nmi, nmi_prev, nmi_pend, hlt;

    wire [7:0] pcl = pc[7:0], pch = pc[15:8];

    // In emulation mode the index registers are eight bits.  The stack pointer
    // is NOT forced here: its page-one confinement is a property of the
    // 6502-era stack steps (LD_S INC/DEC), and the 65816-only instructions
    // really do run it through $00FF mid-instruction - so the address bus and
    // the sr,S adder take S as it is.  It is always $01xx at an instruction's
    // start in emulation mode, which the steps and NORM guarantee.
    wire [15:0] s_eff = s;
    wire [15:0] x_eff = f_x ? {8'h00, x[7:0]} : x;
    wire [15:0] y_eff = f_x ? {8'h00, y[7:0]} : y;

    // B is a property of the PUSH, not a register.  In emulation mode bit 4 is
    // the break flag - set for everything a program does (BRK, COP, PHP) and
    // clear only for a hardware interrupt, which is the one case where ir is
    // $00 without int_brk; in native mode it is X.
    wire [7:0] p_bits = {f_n, f_v, f_m, f_x, f_d, f_i, f_z, f_c};
    wire [7:0] p_push = f_e ? {f_n, f_v, 1'b1, int_brk | (ir != 8'h00),
                               f_d, f_i, f_z, f_c}
                            : p_bits;

    // ---- AGU ----------------------------------------------------------------
    // A 16-bit adder with a bank incrementer on top.  The low half is a real
    // adder; the high half is a real adder too, and with hi_c = LIVE the two are
    // chained, making the pair a 16-bit adder.  (dp),Y is the mode that forces
    // this; see the header.
    logic [7:0] lo_a, lo_b;
    always_comb begin
        case (f_lo_a)
            UC_LO_A_PCL:  lo_a = pcl;
            UC_LO_A_SL:   lo_a = s_eff[7:0];
            UC_LO_A_MDL:  lo_a = md[7:0];
            UC_LO_A_ZERO: lo_a = 8'h00;
            UC_LO_A_DIN:  lo_a = din;
            UC_LO_A_ADH:  lo_a = adh;
            UC_LO_A_DL:   lo_a = d[7:0];
            default:      lo_a = adl;
        endcase
    end

    // The interrupt vector low byte.  Native and emulation mode have separate
    // vectors for every source, which is the one place the 65816's interrupt
    // handling is genuinely different rather than just wider.
    wire [7:0] vec_lo = in_rst          ? 8'hFC :
                        int_nmi         ? (f_e ? 8'hFA : 8'hEA) :
                        (ir == 8'h02)   ? (f_e ? 8'hF4 : 8'hE4) :   // COP
                        int_brk         ? (f_e ? 8'hFE : 8'hE6) :
                                          (f_e ? 8'hFE : 8'hEE);

    always_comb begin
        case (f_lo_b)
            UC_LO_B_XL:  lo_b = x_eff[7:0];
            UC_LO_B_YL:  lo_b = y_eff[7:0];
            UC_LO_B_ONE: lo_b = 8'h01;
            UC_LO_B_FF:  lo_b = 8'hFF;
            UC_LO_B_DIN: lo_b = din;
            UC_LO_B_DL:  lo_b = d[7:0];
            UC_LO_B_ADL: lo_b = adl;
            default:     lo_b = 8'h00;
        endcase
    end

    wire [8:0] agu_sum = {1'b0, lo_a} + {1'b0, lo_b} + {8'd0, f_lo_ci};
    wire [7:0] agu_lo  = agu_sum[7:0];
    wire       agu_co  = agu_sum[8];

    logic [7:0] hi_a, hi_b;
    always_comb begin
        case (f_hi_a)
            UC_HI_A_PCH:  hi_a = pch;
            UC_HI_A_ZERO: hi_a = 8'h00;
            UC_HI_A_ONE:  hi_a = 8'h01;
            UC_HI_A_DIN:  hi_a = din;
            UC_HI_A_SH:   hi_a = s_eff[15:8];
            UC_HI_A_MDH:  hi_a = md[15:8];
            UC_HI_A_DH:   hi_a = d[15:8];
            default:      hi_a = adh;
        endcase
    end

    always_comb begin
        case (f_hi_b)
            UC_HI_B_XH:  hi_b = x_eff[15:8];
            UC_HI_B_YH:  hi_b = y_eff[15:8];
            UC_HI_B_DH:  hi_b = d[15:8];
            UC_HI_B_MDH: hi_b = md[15:8];
            default:     hi_b = 8'h00;
        endcase
    end

    // LIVEW: the 6502's direct-page wrap.  In emulation mode with DL zero the
    // carry out of the low byte is dropped, so dp,X and a (dp) pointer's
    // second byte stay inside the page.
    wire dp_wrap  = f_e & (d[7:0] == 8'h00);
    wire hi_carry = (f_hi_c == UC_HI_C_LIVE)  ? agu_co :
                    (f_hi_c == UC_HI_C_LIVEW) ? (agu_co & ~dp_wrap) :
                    (f_hi_c == UC_HI_C_SAVED) ? agu_c  : 1'b0;
    wire hi_dec   = (f_hi_d == UC_HI_D_ONE)   ? 1'b1   :
                    (f_hi_d == UC_HI_D_SIGN)  ? adl[7] : 1'b0;

    wire [8:0] agu_hsum = {1'b0, hi_a} + {1'b0, hi_b} + {8'd0, hi_carry}
                                       - {8'd0, hi_dec};
    wire [7:0] agu_hi  = agu_hsum[7:0];
    wire       agu_hco = agu_hsum[8];

    // The bank half is only ever a register plus a carry - a 65816 index can
    // run off the end of a bank, but nothing ever ADDS a second bank operand.
    // For a decrement (ad_dec: low + $FF, high + carry - 1) the high half's
    // ninth bit is set exactly when the high byte wrapped below zero, so
    // BORROW is bank - agu_hco.
    wire [7:0] bk_a = (f_bk_a == UC_BK_A_DIN) ? din : bank;
    wire bk_carry = (f_bk_c == UC_BK_C_LIVE)  ? agu_hco :
                    (f_bk_c == UC_BK_C_SAVED) ? agu_hc  : 1'b0;
    wire [7:0] agu_bk = (f_bk_c == UC_BK_C_BORROW) ? (bk_a - {7'd0, agu_hco})
                                                   : (bk_a + {7'd0, bk_carry});

    // ---- PC incrementer -----------------------------------------------------
    // Its own unit, so the AGU stays free to compute an effective address in
    // the same cycle the PC advances.  The PC does not carry into PBR: a 65816
    // program counter wraps inside its bank, which is why a bank boundary is
    // something you jump across and never fall across.
    wire [15:0] pc_inc = pc + 16'd1;

    // ---- address bus --------------------------------------------------------
    // Every source is a concatenation of REGISTERS.  The AGU result is
    // deliberately absent: every addressing mode computes into ADL/ADH/BANK and
    // drives from AD on a later cycle, so the adder never has to reach the
    // address pins, and the address bus costs one mux level from flops rather
    // than a mux level behind a 16-bit carry chain.
    logic [23:0] addr_mux;
    always_comb begin
        case (f_asel)
            UC_ADDR_AD:   addr_mux = {bank, adh, adl};
            UC_ADDR_SP:   addr_mux = {8'h00, s_eff};
            UC_ADDR_VEC:  addr_mux = {8'h00, 8'hFF, vec_lo};
            UC_ADDR_VEC1: addr_mux = {8'h00, 8'hFF, vec_lo + 8'd1};
            default:      addr_mux = {pbr, pc};
        endcase
    end

    assign addr   = addr_mux;
    // Reset runs the interrupt microcode but must not write: the stack cycles
    // become reads.  Cheaper and less error-prone than a second sequence.
    // Reset runs the interrupt microcode but must not write.  An RMW's
    // internal cycle is a dummy write in emulation mode (ew), VDA low.
    assign rw     = (f_rw & ~(f_ew & f_e)) | in_rst;
    assign sync   = f_sync;
    // The bus class is a microcode field; an internal cycle is neither.  The
    // vector pull follows the two vector address sources.
    assign vpa    = f_bus[0];
    assign vda    = f_bus[1];
    assign vpb    = (f_asel == UC_ADDR_VEC) || (f_asel == UC_ADDR_VEC1);
    assign emu    = f_e;
    assign halted = hlt;

    // ---- ALU ----------------------------------------------------------------
    // Two units.  An 8-bit arithmetic core for everything driven by a memory
    // operand, used once per byte - so a 16-bit ADC is two passes in the two
    // cycles the operand already costs.  And a 16-bit shift/increment unit for
    // the operations that are two cycles whatever their width, which therefore
    // have to move all sixteen bits at once.
    //
    // `f_fl` says which pass this is, and that is what selects the accumulator
    // half: L16 is the low pass, H16 the high one, B8 a plain 8-bit operation.
    wire hi_pass = (f_fl == UC_FL_H16);

    wire [7:0] acc8 = hi_pass ? a[15:8] : a[7:0];
    wire [7:0] xr8  = hi_pass ? x_eff[15:8] : x_eff[7:0];
    wire [7:0] yr8  = hi_pass ? y_eff[15:8] : y_eff[7:0];

    logic [15:0] alu_m16;
    always_comb begin
        case (f_alu_a)
            UC_ALU_A_A:    alu_m16 = a;
            UC_ALU_A_X:    alu_m16 = x_eff;
            UC_ALU_A_Y:    alu_m16 = y_eff;
            UC_ALU_A_S:    alu_m16 = s_eff;
            UC_ALU_A_D:    alu_m16 = d;
            UC_ALU_A_MD:   alu_m16 = md;
            UC_ALU_A_ZERO: alu_m16 = 16'h0000;
            default:       alu_m16 = {8'h00, din};
        endcase
    end

    // How wide is this operation?  The destination says so: the accumulator
    // follows M, the index registers follow X, and S and D have no 8-bit form.
    wire op_wide = (f_wb == UC_WB_A16 || f_wb == UC_WB_MD16) ? ~f_m :
                   (f_wb == UC_WB_X16 || f_wb == UC_WB_Y16)  ? ~f_x :
                   (f_wb == UC_WB_S16 || f_wb == UC_WB_D16 ||
                    f_wb == UC_WB_AF16)                      ? 1'b1 : 1'b0;

    // The 8-bit arithmetic core.
    wire [7:0] add_m   = (f_alu_op == UC_OP_SBC) ? ~din : din;
    wire [8:0] bin_sum = {1'b0, acc8} + {1'b0, add_m} + {8'd0, f_c};
    // V comes from the binary sum, except in decimal ADC where the part takes
    // it from the sum after the LOW nibble's adjust and before the high one -
    // which is what the suite shows.  Decimal SBC keeps the binary V.
    wire [7:0] add_vv  = ~(acc8 ^ add_m) & (acc8 ^ bin_sum[7:0]);
    wire       add_v_bin = add_vv[7];

    // The high pass of a 16-bit compare owes the low pass its borrow, which
    // the low pass left in C.
    wire       cmp_bi = hi_pass & ~f_c;
    wire [8:0] cmp_a = {1'b0, acc8} - {1'b0, din} - {8'd0, cmp_bi};
    wire [8:0] cmp_x = {1'b0, xr8}  - {1'b0, din} - {8'd0, cmp_bi};
    wire [8:0] cmp_y = {1'b0, yr8}  - {1'b0, din} - {8'd0, cmp_bi};

    // Decimal ADC/SBC, nibble at a time, on the pass's own byte.
    wire [3:0] a_lo = acc8[3:0], a_hi = acc8[7:4];
    wire [3:0] m_lo = din[3:0],  m_hi = din[7:4];

    // A nibble sum above nine carries whether or not the +6 fits in the
    // adjusted nibble's bits - test the sum, not the adjusted value.
    wire [4:0] adc_lo0 = {1'b0, a_lo} + {1'b0, m_lo} + {4'd0, f_c};
    wire       adc_lc  = (adc_lo0 > 5'd9);
    wire [4:0] adc_lo1 = adc_lc ? (adc_lo0 + 5'd6) : adc_lo0;
    wire [5:0] adc_hi0 = {1'b0, a_hi} + {1'b0, m_hi} + {5'd0, adc_lc};
    wire       dadc_c  = (adc_hi0 > 6'd9);
    wire [5:0] adc_hi1 = dadc_c ? (adc_hi0 + 6'd6) : adc_hi0;
    wire [7:0] dadc_res = {adc_hi1[3:0], adc_lo1[3:0]};
    wire [7:0] dadc_pre = {adc_hi0[3:0], adc_lo1[3:0]};
    wire       dadc_v   = ~(acc8[7] ^ din[7]) & (acc8[7] ^ dadc_pre[7]);
    wire       add_v    = (f_d & (f_alu_op == UC_OP_ADC)) ? dadc_v : add_v_bin;

    wire [4:0] sbc_lo0 = {1'b0, a_lo} - {1'b0, m_lo} - {4'd0, ~f_c};
    wire [5:0] sbc_hi0 = {1'b0, a_hi} - {1'b0, m_hi} - {5'd0, sbc_lo0[4]};
    wire [4:0] sbc_lo1 = sbc_lo0[4] ? (sbc_lo0 - 5'd6) : sbc_lo0;
    wire [5:0] sbc_hi1 = sbc_hi0[5] ? (sbc_hi0 - 6'd6) : sbc_hi0;
    wire [7:0] dsbc_res = {sbc_hi1[3:0], sbc_lo1[3:0]};

    // The 16-bit shift/increment unit.  No operand mux on the second input, so
    // this is carry chain and wiring, not a second adder.
    wire [15:0] inc16 = alu_m16 + 16'd1;
    wire [15:0] dec16 = alu_m16 - 16'd1;
    wire        msb   = op_wide ? alu_m16[15] : alu_m16[7];
    wire        lsb   = alu_m16[0];
    wire [15:0] asl16 = {alu_m16[14:0], 1'b0};
    wire [15:0] lsr16 = op_wide ? {1'b0, alu_m16[15:1]}
                                : {8'h00, 1'b0, alu_m16[7:1]};
    wire [15:0] rol16 = {alu_m16[14:0], f_c};
    wire [15:0] ror16 = op_wide ? {f_c, alu_m16[15:1]}
                                : {8'h00, f_c, alu_m16[7:1]};

    logic [15:0] alu_res;
    logic        alu_n, alu_v, alu_z, alu_c;

    // Zero over the width that was actually written.
    function automatic logic zero16(input logic [15:0] v);
        zero16 = op_wide ? (v == 16'h0000) : (v[7:0] == 8'h00);
    endfunction
    function automatic logic neg16(input logic [15:0] v);
        neg16 = op_wide ? v[15] : v[7];
    endfunction

    always_comb begin
        alu_res = alu_m16;
        alu_n   = f_n;
        alu_v   = f_v;
        alu_z   = f_z;
        alu_c   = f_c;
        case (f_alu_op)
        UC_OP_LD:  begin
            alu_res = alu_m16;
            alu_n   = din[7];
            alu_z   = (din == 8'h00);
        end
        UC_OP_MOV: begin
            alu_res = alu_m16;
            alu_n   = neg16(alu_m16);
            alu_z   = zero16(alu_m16);
        end
        UC_OP_TCS:       alu_res = alu_m16;                      // no flags
        UC_OP_XBA: begin
            alu_res = {alu_m16[7:0], alu_m16[15:8]};
            alu_n   = alu_m16[15];                               // flags on the
            alu_z   = (alu_m16[15:8] == 8'h00);                  // NEW low byte
        end
        UC_OP_AND: begin alu_res = {8'h00, acc8 & din}; alu_n = alu_res[7]; alu_z = (alu_res[7:0] == 8'h00); end
        UC_OP_ORA: begin alu_res = {8'h00, acc8 | din}; alu_n = alu_res[7]; alu_z = (alu_res[7:0] == 8'h00); end
        UC_OP_EOR: begin alu_res = {8'h00, acc8 ^ din}; alu_n = alu_res[7]; alu_z = (alu_res[7:0] == 8'h00); end
        UC_OP_ADC: begin
            alu_v   = add_v;
            alu_res = {8'h00, f_d ? dadc_res : bin_sum[7:0]};
            alu_c   = f_d ? dadc_c : bin_sum[8];
            alu_n   = alu_res[7];
            alu_z   = (alu_res[7:0] == 8'h00);
        end
        UC_OP_SBC: begin
            alu_v   = add_v;
            alu_res = {8'h00, f_d ? dsbc_res : bin_sum[7:0]};
            alu_c   = bin_sum[8];                                // binary carry
            alu_n   = alu_res[7];
            alu_z   = (alu_res[7:0] == 8'h00);
        end
        UC_OP_CMP: begin alu_n = cmp_a[7]; alu_z = (cmp_a[7:0] == 8'h00); alu_c = ~cmp_a[8]; end
        UC_OP_CPX: begin alu_n = cmp_x[7]; alu_z = (cmp_x[7:0] == 8'h00); alu_c = ~cmp_x[8]; end
        UC_OP_CPY: begin alu_n = cmp_y[7]; alu_z = (cmp_y[7:0] == 8'h00); alu_c = ~cmp_y[8]; end
        UC_OP_BIT: begin alu_n = din[7]; alu_v = din[6]; alu_z = ((acc8 & din) == 8'h00); end
        UC_OP_BITI:      alu_z = ((acc8 & din) == 8'h00);        // BIT # : Z only
        UC_OP_ASL: begin alu_res = asl16; alu_c = msb; alu_n = neg16(asl16); alu_z = zero16(asl16); end
        UC_OP_LSR: begin alu_res = lsr16; alu_c = lsb; alu_n = neg16(lsr16); alu_z = zero16(lsr16); end
        UC_OP_ROL: begin alu_res = rol16; alu_c = msb; alu_n = neg16(rol16); alu_z = zero16(rol16); end
        UC_OP_ROR: begin alu_res = ror16; alu_c = lsb; alu_n = neg16(ror16); alu_z = zero16(ror16); end
        UC_OP_INC: begin alu_res = inc16; alu_n = neg16(inc16); alu_z = zero16(inc16); end
        UC_OP_DEC: begin alu_res = dec16; alu_n = neg16(dec16); alu_z = zero16(dec16); end
        // The operand is in MD (an RMW's internal cycle has no din); Z is the
        // test of A against it, over the width being written.
        UC_OP_TRB: begin alu_res = alu_m16 & ~a; alu_z = zero16(alu_m16 & a); end
        UC_OP_TSB: begin alu_res = alu_m16 |  a; alu_z = zero16(alu_m16 & a); end
        default: ;
        endcase
    end

    // ---- write data ---------------------------------------------------------
    logic [7:0] dout_mux;
    always_comb begin
        case (f_dout)
            UC_DOUT_AH:   dout_mux = a[15:8];
            UC_DOUT_XL:   dout_mux = x_eff[7:0];
            UC_DOUT_XH:   dout_mux = x_eff[15:8];
            UC_DOUT_YL:   dout_mux = y_eff[7:0];
            UC_DOUT_YH:   dout_mux = y_eff[15:8];
            UC_DOUT_ZERO: dout_mux = 8'h00;
            UC_DOUT_P_B:  dout_mux = p_push;
            UC_DOUT_PCL:  dout_mux = pcl;
            UC_DOUT_PCH:  dout_mux = pch;
            UC_DOUT_PBR:  dout_mux = pbr;
            UC_DOUT_MDL:  dout_mux = md[7:0];
            UC_DOUT_MDH:  dout_mux = md[15:8];
            UC_DOUT_DBR:  dout_mux = dbr;
            UC_DOUT_DL:   dout_mux = d[7:0];
            UC_DOUT_DH:   dout_mux = d[15:8];
            UC_DOUT_ADL:  dout_mux = adl;
            UC_DOUT_ADH:  dout_mux = adh;
            default:      dout_mux = a[7:0];
        endcase
    end
    assign dout = dout_mux;

    // ---- sequencing ---------------------------------------------------------
    // Branch condition: bits [7:6] of the opcode pick the flag and bit [5] the
    // sense.  BRA collides with that encoding and gets COND_ALWAYS from the
    // microcode instead.
    //
    // The opcode used here is NOT `ir` on a fetch cycle.  Slot 0's condition is
    // evaluated while the opcode that selects it is still arriving on din - `ir`
    // does not hold it until the next edge - so a branch would otherwise be
    // resolved against the PREVIOUS instruction's opcode bits.  That is the
    // single subtlest consequence of deciding a cycle early, and the only one
    // the equivalence testbench caught rather than the audit.
    wire [7:0] seq_ir = f_sync ? fetch_op : ir;
    wire br_flag = (seq_ir[7:6] == 2'b00) ? f_n :
                   (seq_ir[7:6] == 2'b01) ? f_v :
                   (seq_ir[7:6] == 2'b10) ? f_c : f_z;

    // A taken branch needs the extra cycle when the low-byte add left the page
    // - and ONLY in emulation mode.  A native-mode 65816 does not pay it, which
    // the suite confirms: opcode $10 shows counts of 2/3/4 with e=1 and only
    // 2/3 with e=0.
    wire page_adj = agu_co ^ adl[7];

    // The indexed fixup cycle runs when the low add carried, OR whenever the
    // index register is sixteen bits - in which case the high byte has to be
    // added no matter what the low half did.
    wire idx_fix = ~f_x | agu_co;

    // A block move moves A+1 bytes, decrementing A per byte, so it is done
    // when A has wrapped to $FFFF.  Tested a cycle early like every other
    // condition: A was decremented on the write cycle, two cycles before the
    // slot that carries the test.
    wire mv_done = (a == 16'hFFFF);

    // ---- the NEXT microinstruction's sequencing ------------------------------
    // `urom` is the block RAM output during this cycle, and it holds the
    // microinstruction that will run NEXT cycle.  Its cond/alt fields are
    // therefore available a full cycle before that microinstruction executes,
    // which is what lets the address of the one AFTER it be computed now.
    // On an opcode fetch the microinstruction that runs next is slot 0, which is
    // in the decode ROM rather than in `urom` - so the sequencing fields come
    // from there instead.  No slot 0 tests a live carry (checked: all slot-0
    // conditions are ALWAYS/DL/M16/X16/BRANCH/NOTEMU), so evaluating one during
    // the fetch cycle is sound.
    wire [3:0] n_cond = f_sync ? seq0[7:4] : urom[UCP_COND +: 4];
    wire [3:0] n_alt  = f_sync ? seq0[3:0] : urom[UCP_ALT  +: 4];
    // The early-carry operand select is only consulted for IDX/EPAGE, and no
    // slot 0 uses either, so this never needs the fetch-cycle word.
    wire [2:0] n_lo_b = urom[UCP_LO_B +: 3];

    // THE EARLY-CARRY ADDER, for the 33 slots whose condition tests a carry
    // produced in the very cycle that tests it.  There are only four shapes, and
    // every one of them adds an index (or the incremented PC) to a byte that the
    // PREVIOUS slot loads straight from din:
    //
    //   EPAGE : PCL + ADL, and the slot before loads ADL from din  -> pc_inc + din
    //   IDX   : ADL + XL,  same                                    -> XL     + din
    //   IDX   : ADL + YL,  same                                    -> YL     + din
    //   IDX   : MDL + YL,  and the slot before loads MDL from din  -> YL     + din
    //
    // So the carry is always din plus one of three registers, computable a cycle
    // early - and which one is selected by the prefetched microinstruction's own
    // fields, so this needs no extra bit in the ROM.  This is exactly the kind of
    // special-case hardware the original part's random control logic is made of.
    wire [7:0] early_b = (n_cond == UC_COND_EPAGE) ? pc_inc[7:0] :
                         (n_lo_b == UC_LO_B_XL)    ? x_eff[7:0]  : y_eff[7:0];
    wire [8:0] early_sum = {1'b0, din} + {1'b0, early_b};
    wire       early_co  = early_sum[8];

    // The branch page-cross test compares the carry against the offset's sign,
    // and the offset is the din being read right now.
    wire early_page = early_co ^ din[7];

    logic cond_next;
    always_comb begin
        case (n_cond)
            UC_COND_NEVER:  cond_next = 1'b0;
            UC_COND_BRANCH: cond_next = (br_flag == seq_ir[5]);
            UC_COND_DEC:    cond_next = f_d;
            UC_COND_M16:    cond_next = ~f_m;
            UC_COND_X16:    cond_next = ~f_x;
            UC_COND_DL:     cond_next = (d[7:0] != 8'h00);
            UC_COND_IDX:    cond_next = ~f_x | early_co;
            UC_COND_EPAGE:  cond_next = f_e & early_page;
            UC_COND_NOTEMU: cond_next = ~f_e;
            UC_COND_MVDONE: cond_next = mv_done;
            default:        cond_next = 1'b1;
        endcase
    end

    // An instruction boundary is the only place an interrupt gets in.
    wire irq_ready = nmi_pend | (~irq_n & ~f_i);
    wire take_int  = f_sync & irq_ready & ~in_rst;

    // WAI parks by looping slot 1 on itself (cond NEVER, alt 1), so the
    // sequential successor port is already pointing at slot 2 - its exit - every
    // cycle it waits.  Waking is therefore just forcing the condition true.
    wire wai_wake = (ir == 8'hCB) && (nmi_pend || ~irq_n);

    wire       cond_sel = cond_next | wai_wake;
    // On a fetch, the microinstruction running next cycle is slot 0, so the
    // successor is counted from 0 rather than from a stale nslot.
    wire [3:0] cur_next = f_sync ? 4'd0 : nslot;
    wire [3:0] slot_n2  = cond_sel ? (cur_next + 4'd1) : n_alt;

    // The address presented this cycle is for the microinstruction TWO cycles
    // out.  On an opcode fetch that is slot 1 of whatever din turns out to be -
    // slot 0 comes from the decode ROM, because nothing could have addressed the
    // block RAM for it in time.
    always_comb begin
        if (rst)          uaddr = {8'h00, 4'd2};    // prime: the reset entry slot
        else if (f_sync)  uaddr = {fetch_op, slot_n2};
        else              uaddr = {ir, slot_n2};
    end

    // ---- register file ------------------------------------------------------
    // NOTE, and it is the difference between 115 MHz and 128 MHz: there is no
    // conditional-load gate here.  An earlier version carried a `ld_if` field
    // that ANDed cond_met into every register's clock enable, so that a
    // conditional slot could suppress its own write-backs.  Nothing in this
    // instruction set needs it - it existed for BBR/BBS, which the 65816 does
    // not have - but Vivado cannot see that, because `ld_if` arrives from a
    // block RAM whose contents it will not constant-fold.  The result was that
    // cond_met, and therefore the AGU carry it depends on, sat in the clock
    // enable of nearly every flop in the core: all twenty worst paths ended on
    // a CE pin.  Deleting the field moved cond_met off ~200 enable pins and
    // left it driving only the 4-bit next-microcycle mux.
    //
    // If a conditional load is ever genuinely needed, gate the ONE register
    // that needs it.  Do not reintroduce a global enable.

    always_ff @(posedge clk) begin
        if (rst) begin
            a <= 16'h0000; x <= 16'h0000; y <= 16'h0000;
            s <= 16'h01FF; d <= 16'h0000;
            pc <= 16'h0000; dbr <= 8'h00; pbr <= 8'h00;
            f_n <= 1'b0; f_v <= 1'b0; f_d <= 1'b0;
            f_i <= 1'b1; f_z <= 1'b0; f_c <= 1'b0;
            // Reset leaves the part in emulation mode with 8-bit registers -
            // a 65816 comes up as a 6502 and stays one until XCE says otherwise.
            f_e <= 1'b1; f_m <= 1'b1; f_x <= 1'b1;
            ir <= 8'h00; adl <= 8'h00; adh <= 8'h00; bank <= 8'h00;
            md <= 16'h0000;
            agu_c <= 1'b0; agu_hc <= 1'b0; hlt <= 1'b0;
            nmi_prev <= 1'b1; nmi_pend <= 1'b0;
            int_brk <= 1'b0; int_nmi <= 1'b0; in_rst <= 1'b1;
            // Reset enters the interrupt sequence at slot 2 - the first of the
            // three stack cycles, which reset performs as reads.  The first
            // cycle out of reset runs a zeroed microinstruction, a benign read
            // at PC, while the pipeline fills: uaddr is forced to {$00, 2}
            // whenever rst holds, so `urom` already has slot 2 in hand.
            uc_q    <= '0;
            use_dec <= 1'b0;
            nslot   <= 4'd2;
            ucyc    <= 4'd1;
        end else if (cyc_en) begin
            // The three-deep pipeline: the block RAM reads two cycles out, the
            // flop holds one cycle out, and uc runs from the flop.
            uc_q    <= urom;
            use_dec <= f_sync;
            ucyc    <= f_sync ? 4'd0 : nslot;
            nslot   <= slot_n2;

            nmi_prev <= nmi_n;
            if (nmi_prev & ~nmi_n) nmi_pend <= 1'b1;

            agu_c  <= agu_co;
            agu_hc <= agu_hco;

            if (f_sync) begin
                if (take_int) begin
                    ir       <= 8'h00;
                    int_brk  <= 1'b0;
                    int_nmi  <= nmi_pend;
                    nmi_pend <= 1'b0;
                end else begin
                    ir      <= din;
                    int_brk <= (din == 8'h00);
                    int_nmi <= 1'b0;
                end
            end

            begin
                case (f_ld_adl)
                    UC_LD_ADL_AGU: adl <= agu_lo;
                    UC_LD_ADL_DIN: adl <= din;
                    UC_LD_ADL_MDL: adl <= md[7:0];
                    default: ;
                endcase
                case (f_ld_adh)
                    UC_LD_ADH_AGU: adh <= agu_hi;
                    UC_LD_ADH_DIN: adh <= din;
                    UC_LD_ADH_MDH: adh <= md[15:8];
                    default: ;
                endcase
                case (f_ld_bk)
                    UC_LD_BK_AGU:  bank <= agu_bk;
                    UC_LD_BK_DIN:  bank <= din;
                    UC_LD_BK_DBR:  bank <= dbr;
                    UC_LD_BK_PBR:  bank <= pbr;
                    UC_LD_BK_ZERO: bank <= 8'h00;
                    default: ;
                endcase
                case (f_ld_pc)
                    UC_LD_PC_INC:    pc <= pc_inc;
                    UC_LD_PC_AGU:    pc <= {agu_hi, agu_lo};
                    UC_LD_PC_AGU_LO: pc[7:0]  <= agu_lo;
                    UC_LD_PC_AGU_HI: pc[15:8] <= agu_hi;
                    UC_LD_PC_JMP:    pc <= {din, md[7:0]};
                    UC_LD_PC_JMPL:   pc <= {md[15:8], md[7:0]};
                    UC_LD_PC_MD:     pc <= md;
                    // The block moves' rewind, and the only conditional
                    // register load in the core: PC back to the opcode while
                    // the move has more to do.  Gated on THIS register alone.
                    UC_LD_PC_M3C:    if (~mv_done) pc <= pc - 16'd3;
                    default: ;
                endcase
                // The 6502-era steps stay in page one in emulation mode; the
                // 65816-only instructions' steps (INCN/DECN) run through all
                // sixteen bits, and NORM restores the page on their last cycle.
                case (f_ld_s)
                    UC_LD_S_INC:  s <= f_e ? {8'h01, s[7:0] + 8'd1} : s + 16'd1;
                    UC_LD_S_DEC:  s <= f_e ? {8'h01, s[7:0] - 8'd1} : s - 16'd1;
                    UC_LD_S_INCN: s <= s + 16'd1;
                    UC_LD_S_DECN: s <= s - 16'd1;
                    UC_LD_S_NORM: if (f_e) s[15:8] <= 8'h01;
                    UC_LD_S_AGU:  s <= {agu_hi, agu_lo};
                    default: ;
                endcase

                case (f_wb)
                    UC_WB_AL:  a[7:0]   <= alu_res[7:0];
                    UC_WB_AH:  a[15:8]  <= alu_res[7:0];
                    UC_WB_XL:  x[7:0]   <= alu_res[7:0];
                    UC_WB_XH:  x[15:8]  <= alu_res[7:0];
                    UC_WB_YL:  y[7:0]   <= alu_res[7:0];
                    UC_WB_YH:  y[15:8]  <= alu_res[7:0];
                    UC_WB_MDL: md[7:0]  <= alu_res[7:0];
                    UC_WB_MDH: md[15:8] <= alu_res[7:0];
                    UC_WB_DL:  d[7:0]   <= alu_res[7:0];
                    UC_WB_DH:  d[15:8]  <= alu_res[7:0];
                    UC_WB_DBR: dbr      <= alu_res[7:0];
                    UC_WB_PBR: pbr      <= din;
                    // The mode-sized write-backs.  An 8-bit accumulator write
                    // leaves B - the hidden high half - alone, which is what
                    // makes XBA useful in the first place.
                    UC_WB_A16: if (op_wide) a <= alu_res; else a[7:0] <= alu_res[7:0];
                    UC_WB_X16: if (op_wide) x <= alu_res; else x <= {8'h00, alu_res[7:0]};
                    UC_WB_Y16: if (op_wide) y <= alu_res; else y <= {8'h00, alu_res[7:0]};
                    UC_WB_S16: s <= f_e ? {8'h01, alu_res[7:0]} : alu_res;
                    UC_WB_D16: d <= alu_res;
                    UC_WB_MD16: md <= alu_res;
                    // The block-move count is 16 bits whatever M says.
                    UC_WB_AF16: a <= alu_res;
                    UC_WB_P: begin
                        f_n <= din[7]; f_v <= din[6];
                        f_d <= din[3]; f_i <= din[2];
                        f_z <= din[1]; f_c <= din[0];
                        // M and X only exist in native mode; pulling P in
                        // emulation mode cannot clear them.  Setting X
                        // truncates the index registers to eight bits.
                        if (~f_e) begin
                            f_m <= din[5]; f_x <= din[4];
                            if (din[4]) begin x[15:8] <= 8'h00; y[15:8] <= 8'h00; end
                        end
                    end
                    default: ;
                endcase

                case (f_fl)
                    UC_FL_B8: begin
                        f_n <= alu_n; f_v <= alu_v; f_z <= alu_z; f_c <= alu_c;
                    end
                    // The low pass of a 16-bit operation, which is ALSO the
                    // whole of an 8-bit one: every flag is set, and the high
                    // pass, if there is one, overwrites N/V/C and ANDs into Z.
                    UC_FL_L16: begin
                        f_n <= alu_n; f_v <= alu_v; f_z <= alu_z; f_c <= alu_c;
                    end
                    UC_FL_H16: begin
                        f_n <= alu_n; f_v <= alu_v; f_c <= alu_c;
                        f_z <= f_z & alu_z;
                    end
                    default: ;
                endcase

                // CLC/SEC/CLI/SEI/CLV/CLD/SED.  ir[7:6] picks the flag and
                // ir[5] the value; there is no SEV, so that slot always clears.
                if (f_alu_op == UC_OP_FLAG) begin
                    case (ir[7:6])
                        2'b00: f_c <= ir[5];
                        2'b01: f_i <= ir[5];
                        2'b10: f_v <= 1'b0;
                        default: f_d <= ir[5];
                    endcase
                end

                // REP/SEP clear or set the P bits named by the operand.  M and
                // X are inert in emulation mode, where they are pinned to 1.
                if (f_alu_op == UC_OP_REP) begin
                    if (din[7]) f_n <= 1'b0;
                    if (din[6]) f_v <= 1'b0;
                    if (din[3]) f_d <= 1'b0;
                    if (din[2]) f_i <= 1'b0;
                    if (din[1]) f_z <= 1'b0;
                    if (din[0]) f_c <= 1'b0;
                    if (~f_e) begin
                        if (din[5]) f_m <= 1'b0;
                        if (din[4]) f_x <= 1'b0;
                    end
                end
                if (f_alu_op == UC_OP_SEP) begin
                    if (din[7]) f_n <= 1'b1;
                    if (din[6]) f_v <= 1'b1;
                    if (din[3]) f_d <= 1'b1;
                    if (din[2]) f_i <= 1'b1;
                    if (din[1]) f_z <= 1'b1;
                    if (din[0]) f_c <= 1'b1;
                    if (~f_e) begin
                        if (din[5]) f_m <= 1'b1;
                        if (din[4]) begin
                            f_x <= 1'b1;
                            x[15:8] <= 8'h00; y[15:8] <= 8'h00;
                        end
                    end
                end

                // XCE swaps C and E - the only way in or out of native mode.
                // Leaving emulation does not by itself widen anything; entering
                // it forces M and X back to 8-bit and truncates the index
                // registers, which is the trap that catches emulation-mode code
                // returning from a native-mode routine.
                if (f_alu_op == UC_OP_XCE) begin
                    f_e <= f_c;
                    f_c <= f_e;
                    if (f_c) begin
                        f_m <= 1'b1;
                        f_x <= 1'b1;
                        x[15:8] <= 8'h00;
                        y[15:8] <= 8'h00;
                    end
                end

                // Interrupt entry: mask further IRQs, and clear D.
                if (f_seti) begin
                    f_i <= 1'b1;
                    f_d <= 1'b0;
                end

                // Entering emulation mode (XCE with C set) pins the stack to
                // page one; the stack steps above keep it there.
                if (f_alu_op == UC_OP_XCE && f_c) s[15:8] <= 8'h01;
            end

            // The vector fetch ends the reset/interrupt sequence.  PBR is
            // forced to zero: every 65816 vector lands in bank zero.
            if (f_ld_pc == UC_LD_PC_JMP && f_asel == UC_ADDR_VEC1) begin
                in_rst  <= 1'b0;
                int_nmi <= 1'b0;
                pbr     <= 8'h00;
            end

            if (ir == 8'hDB && ucyc == 4'd1) hlt <= 1'b1;
        end

        // The microcode read is deliberately outside the reset branch: while rst
        // holds it primes the pipeline from the forced address, so the first
        // cycle after release already has its successor in hand.
        if (rst || cyc_en) urom <= ucode[uaddr];
    end

endmodule
