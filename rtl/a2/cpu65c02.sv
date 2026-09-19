`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// cpu65c02 - a microcoded 65C02, built around the bus cycle.
//
// WHY MICROCODE, AND WHY IT IS NOT ABOUT AREA.  This core has to satisfy two
// requirements a software-grade 6502 does not: the same NUMBER of cycles per
// instruction as the published 65C02, and eventually the same ADDRESS driven
// during each of them, dummy reads included.  Microcode earns its place because
// it lets the work be spread EXPLICITLY across the cycles the instruction set
// already grants, rather than crammed into one cycle by a state machine with
// nowhere else to put it.
//
// The 6502 is unusually generous here.  Every 16-bit address computation splits
// into an 8-bit add plus a carry into the high byte, and the ISA hands over an
// extra cycle exactly when that carry has to propagate: the indexed page-cross
// penalty, the taken-branch page cross, the sixth cycle of JMP (abs) that buys
// the CMOS page-wrap fix.  So the rule the microcode obeys is:
//
//   *** no microinstruction adds two arbitrary 8-bit operands into the high
//       byte.  The AGU's high half is an incrementer, never an adder - and it
//       never consumes a live carry: agu_co lands in the agu_c register
//       before anything arithmetic reads it. ***
//
// The longest arithmetic path in the core is therefore eight bits wide, and
// no cycle chains two arithmetic events.  See sim/gen_microcode.py, which is
// where both rules are enforced and explained.
//
// THE OTHER HALF OF THE SPEED is that the ROM address is {opcode, ucycle} with
// no mapping stage.  There is no instruction decoder: the opcode indexes the ROM
// directly, so the 256-way decode that dominated the previous state-machine
// version's critical path does not exist as logic at all.  It costs a few block
// RAMs, which this design has to spare.
//
// STRUCTURE.  Two units run in parallel, which is the other reason this is fast:
//
//   AGU - 8-bit adder plus a high-byte incrementer.  Addresses only.
//   ALU - 8-bit.  Data only.
//
// Neither feeds the other, so neither is in the other's timing path.  A cycle
// can compute an effective address and an ALU result at once, which is what lets
// a store latch its index while the bus still shows the un-indexed address.
//
// THE INVARIANT, unchanged from the previous implementation: every
// microinstruction is exactly one bus cycle, and every bus cycle is one
// microinstruction.  An instruction's cycle count is the number of
// microinstructions it executes, and a dummy cycle is an ordinary
// microinstruction that happens to discard din.
//
// TIMING CONTRACT.  One bus cycle per `cyc_en` pulse.  addr/rw/dout are driven
// from the ROM output register and the register file, so they settle just after
// the edge that begins their cycle and are stable across it; din is sampled by
// the edge that ends it.  One cyc_en per phi0 gives the address a full bus cycle
// of setup; cyc_en tied high runs a bus cycle per clk.
//
// WHAT IS NOT VERIFIED: the dummy-cycle addresses.  Cycle counts are checked
// against the published table by sim/cpu_cycles_tb.sv.  WHICH address appears
// during a dummy cycle is not checked by anything, and cannot be - Klaus
// Dormann's suites test results, not buses.  The microcode's choices are
// structurally motivated (the fixup cycle shows the un-fixed address, because
// that is the state the hardware is actually in) but they are not evidence.
//
// The list, so it is in one place: the indexed page-cross fixup address, the
// JMP (abs) extra cycle, the decimal extra cycle, the five filler cycles of
// $5C, and the two reads at PC that open the reset sequence - which this core
// drives at PC and PC, where a real part may show PC and PC+1.
//
// sim/run_trace_replay.sh is what settles these: it replays a captured Apple II
// bus trace against this core and compares the address on every cycle.
//
// HARDWARE INTERRUPTS are verified by sim/cpu_irq_tb.sv, added after the first
// one ever fired on hardware.  The functional suites drive irq_n high and the
// cycle test has no interrupt line, so the IRQ entry path - taken only at an
// instruction boundary, PC HELD across it so RTI returns to the interrupted
// instruction rather than two bytes past it - had no coverage until a
// Mockingboard's timer interrupt exposed it.  See int_pc_hold below.
//
// VARIANT: the BASE 65C02 - the first-generation part (NCR / GTE / Synertek and
// Rockwell's own early parts), which is what the machine this core stands in for
// actually has.  So: the CMOS additions are all here - BRA, PHX/PHY/PLX/PLY,
// STZ, TRB/TSB, INC A/DEC A, JMP (abs,X), the new BIT and (zp) modes, and the
// decimal ADC/SBC fix - but Rockwell's RMB/SMB/BBR/BBS and WDC's STP/WAI are
// NOT.  Those encodings are one-byte one-cycle NOPs, as they are on the part.
//
// This is not a simplification, it is the point: a core that answers $x7 with a
// read-modify-write where the real chip does nothing is not standing in for that
// chip.  sim/gen_microcode.py is where the variant lives.
//
// The undefined encodings are the CMOS NOPs throughout, never the NMOS
// undocumented instructions.
//////////////////////////////////////////////////////////////////////////////////

module cpu65c02 #(
    // Both generated by sim/gen_microcode.py and committed.  Overridable so a
    // testbench can point at an experimental ROM without editing the RTL.
    parameter UCODE_FILE = "cpu65c02_ucode.hex"
) (
    input  wire         clk,
    input  wire         rst,        // synchronous; starts the 65C02 reset sequence
    input  wire         cyc_en,     // one pulse per bus cycle

    output wire  [15:0] addr,
    output wire         rw,         // 1 = read, 0 = write
    output wire  [7:0]  dout,
    // The data return, SPLIT BY STREAM (the user's design): the byte for a
    // program-stream cycle arrives on i_din, everything else on d_din, and
    // the core muxes by its own cyc_is_i - so an instruction front can hold
    // its predicted byte on i_din every clock, and a data front its own on
    // d_din, neither ever caring what the other is speculating.  A consumer
    // with one data source ties them together and nothing changes.
    input  wire  [7:0]  i_din,
    input  wire  [7:0]  d_din,

    input  wire         irq_n,      // level sensitive, active low
    input  wire         nmi_n,      // edge sensitive, active low

    output wire         sync,       // high during an opcode fetch
    output wire         halted,     // STP executed; only rst clears it

    // ---- the split I/D front (acceleration) ---------------------------------
    // Classified views of the one bus above, plus the one piece of genuinely
    // new information a predictive icache needs.  The 6502 cannot fetch
    // instructions and data at once, so these are not a second bus: cyc_is_i
    // says which stream THIS cycle belongs to, i_addr/d_addr are addr seen
    // through that classification, and i_pred is the address of the NEXT
    // program-stream fetch - driven a cycle ahead of it, which is what lets an
    // icache have the line already read when the fetch begins.  The data
    // return is split above (i_din/d_din), muxed by cyc_is_i inside.  A
    // consumer that does not care (the bus-locked driver, every existing
    // testbench) ties the two din ports together, ignores the rest, and
    // nothing changes.
    output wire         cyc_is_i,   // 1: program stream (opcode fetch or any
                                    //    cycle addressed from PC, dummies
                                    //    included); 0: data, stack, vectors,
                                    //    and the LAST/FIXUP dummy re-reads
    output wire  [15:0] i_addr,     // = addr; the I view, meaningful when cyc_is_i
    output wire  [15:0] pc_addr,    // {pch, pcl}, REGISTER-DIRECT: equals addr on
                                    //    every PC-sourced cycle by construction
                                    //    (the mux's default case IS these
                                    //    registers), and free of the AGU and din
                                    //    on every other - the compare source an
                                    //    instruction front wants
    output wire  [15:0] i_pred,     // next program-stream address (see next_pc)
    output wire  [15:0] d_addr,     // = addr; the D view, meaningful when !cyc_is_i
    output wire         d_rw,       // = rw
    output wire  [7:0]  d_dout,     // = dout
    // The data-stream prediction, i_pred's mirror (see d_pred_mux below): the
    // address and direction of the NEXT cycle, valid when that cycle is a
    // data cycle - driven a cycle ahead of it, which is what lets a data
    // front have the byte already read when the cycle begins.  Not a guess:
    // the next microinstruction's addr_sel is in the ROM's combinational read
    // this cycle, and every data source it can pick is a register whose
    // next-state value this cycle already computes.  It inherits din's timing
    // (the ROM read descends from din at a sync), so it settles when din does
    // and no earlier - the consumer REGISTERS it, always.  d_pred_v covers
    // every data cycle but a next-cycle live-AGU address, which after the
    // carry-gift work only the $5C NOP drives.
    output wire  [15:0] d_pred,
    output wire         d_pred_v,   // next cycle is a data cycle and d_pred names it
    output wire         d_pred_rw,  // ... and will be a read (1) or a write (0)
    output wire  [7:0]  p_flags     // {N,V,1,0,D,I,Z,C} REGISTER-DIRECT: the
                                    // flags a branch will test, final from the
                                    // edge that begins its opcode fetch (the
                                    // previous instruction's writeback landed
                                    // there, and a branch writes none) - the
                                    // instruction front resolves branches early
                                    // on them (rtl/iline.sv)
);

`include "cpu65c02_ucode.vh"

    // The one data return the architecture sees, muxed from the split ports
    // by this cycle's own stream classification (cyc_is_i, below).  One 2:1
    // level on a path whose sources - the fronts' registered bytes - are
    // register-direct.
    wire [7:0] din = cyc_is_i ? i_din : d_din;

    // ---- microcode ROM ------------------------------------------------------
    // {opcode, ucycle} addressing, so there is no decode between the opcode
    // arriving and the ROM being read.  2048 x 51 bits; the `uc` register on
    // the ROM's output IS the pipeline stage - the word for cycle N is fetched
    // combinationally during N-1 and the datapath runs from the flop.
    localparam int UA_W = 8 + UC_SLOTS_LOG2;

    // Distributed, not block: the microcode is a CONSTANT ($readmemh at
    // synthesis, never written), so Vivado logic-optimizes the contents
    // rather than storing them - measured +257 LUTs against the block
    // version's 3 RAMB36, the two tiles the page cache's banks needed back
    // on the XC7A35T (docs/PAGE_CACHE.md), and no SLICEM spent.  The fetch
    // stays a registered read; the one-clock contract is unchanged.
    //
    // The ROM is read TWICE, once per next-address arm (the dual-arm fetch at
    // uaddr_taken/uaddr_alt below): both addresses are register-direct, so
    // both cones start at the clock edge, and the late microcode-branch
    // condition picks between two fetched WORDS - one LUT level - instead of
    // steering the address into the whole tree.  The second cone's LUTs are
    // the price of that late select.
    (* rom_style = "distributed" *) logic [UC_W-1:0] ucode [0:(1 << UA_W) - 1];
    initial $readmemh(UCODE_FILE, ucode);

    logic [UC_W-1:0] uc;            // the microinstruction driving THIS cycle

    // Field extraction.  Positions come from the generated header, so these
    // cannot drift from the assembler.
    wire       f_sync   = uc[UCP_SYNC];
    wire       f_rw     = uc[UCP_RW];
    wire [3:0] f_asel   = uc[UCP_ADDR_SEL +: 4];
    wire [1:0] f_lo_a   = uc[UCP_LO_A     +: 2];
    wire [2:0] f_lo_b   = uc[UCP_LO_B     +: 3];
    wire       f_lo_ci  = uc[UCP_LO_CI];
    wire [2:0] f_hi_a   = uc[UCP_HI_A     +: 3];
    wire [1:0] f_hi_c   = uc[UCP_HI_C     +: 2];
    wire [1:0] f_hi_d   = uc[UCP_HI_D     +: 2];
    wire [1:0] f_ld_adl = uc[UCP_LD_ADL   +: 2];
    wire [1:0] f_ld_adh = uc[UCP_LD_ADH   +: 2];
    wire [2:0] f_ld_pc  = uc[UCP_LD_PC    +: 3];
    wire [1:0] f_ld_s   = uc[UCP_LD_S     +: 2];
    wire [2:0] f_dout   = uc[UCP_DOUT     +: 3];
    wire [4:0] f_alu_op = uc[UCP_ALU_OP   +: 5];
    wire [2:0] f_alu_a  = uc[UCP_ALU_A    +: 3];
    wire [2:0] f_wb     = uc[UCP_WB       +: 3];
    wire       f_fl     = uc[UCP_FL];
    wire       f_seti   = uc[UCP_SETI];
    wire [2:0] f_cond   = uc[UCP_COND     +: 3];
    wire [2:0] f_alt    = uc[UCP_ALT      +: 3];

    // ---- architectural state ------------------------------------------------
    logic [7:0]  a, x, y, s;
    logic [7:0]  pcl, pch;          // split: the PC increment is 8-bit + carry
    logic        f_n, f_v, f_d, f_i, f_z, f_c;
    logic [7:0]  ir;                // current opcode; the ROM's high address bits
    logic [7:0]  adl, adh;          // effective address under construction
    logic [7:0]  md;                // scratch: RMW result, jump target low byte
    logic [2:0]  ucyc;
    logic        agu_c;             // carry SAVED from the previous AGU add
    logic        in_rst, int_brk, int_nmi, nmi_prev, nmi_pend;
    logic [15:0] last_addr;
    logic [7:0]  dm;                // the last din: the ADC/SBC operand, for the decimal slot

    wire [7:0] p_bits = {f_n, f_v, 1'b1, 1'b0, f_d, f_i, f_z, f_c};
    assign p_flags = p_bits;

    // ---- AGU ----------------------------------------------------------------
    // Low half: a real 8-bit adder.  High half: an incrementer/decrementer only.
    // The asymmetry is the design rule, not an accident - see the header.
    logic [7:0] lo_a, lo_b;
    always_comb begin
        case (f_lo_a)
            UC_LO_A_PCL: lo_a = pcl;
            UC_LO_A_S:   lo_a = s;
            UC_LO_A_MD:  lo_a = md;
            default:     lo_a = adl;
        endcase
    end

    // The interrupt vector low byte.  Reset and NMI displace the BRK vector, and
    // the +1 for the high half is the ordinary AGU carry-in.
    wire [7:0] vec_lo = in_rst  ? 8'hFC :
                        int_nmi ? 8'hFA : 8'hFE;

    always_comb begin
        case (f_lo_b)
            UC_LO_B_X:   lo_b = x;
            UC_LO_B_Y:   lo_b = y;
            UC_LO_B_ONE: lo_b = 8'h01;
            UC_LO_B_FF:  lo_b = 8'hFF;
            UC_LO_B_ADL: lo_b = adl;
            // There is deliberately no din arm here.  No microinstruction ever
            // fed the bus into the adder, but the arm's mere existence put the
            // instruction front's combinational serve path in series with this
            // carry chain on every static timing path through the AGU - the
            // depth audit's whole 18-20-level tail.  Every remaining operand
            // is a register or a constant.
            UC_LO_B_VEC: lo_b = vec_lo;
            default:     lo_b = 8'h00;
        endcase
    end

    wire [8:0] agu_sum = {1'b0, lo_a} + {1'b0, lo_b} + {8'd0, f_lo_ci};
    wire [7:0] agu_lo  = agu_sum[7:0];
    wire       agu_co  = agu_sum[8];

    logic [7:0] hi_a;
    always_comb begin
        case (f_hi_a)
            UC_HI_A_PCH:  hi_a = pch;
            UC_HI_A_ZERO: hi_a = 8'h00;
            UC_HI_A_ONE:  hi_a = 8'h01;
            UC_HI_A_FF:   hi_a = 8'hFF;
            default:      hi_a = adh;
        endcase
    end

    // +1, -1 or nothing.  `SAVED` is the carry from an add a cycle or more ago -
    // the cycle the instruction set granted for exactly this.  There is no LIVE
    // arm: the high byte never consumes agu_co in the cycle that computes it
    // (the rule in sim/gen_microcode.py), so the low adder's carry chain and
    // this incrementer are never in series.  agu_co's only arithmetic consumer
    // is the agu_c register below.
    wire hi_carry = (f_hi_c == UC_HI_C_SAVED) ? agu_c : 1'b0;
    wire hi_dec   = (f_hi_d == UC_HI_D_ONE)   ? 1'b1   :
                    (f_hi_d == UC_HI_D_SIGN)  ? adl[7] : 1'b0;
    wire [7:0] agu_hi = hi_a + {7'd0, hi_carry} - {7'd0, hi_dec};

    // ---- PC incrementer -----------------------------------------------------
    // Its own unit, so the AGU stays free to compute an effective address in the
    // same cycle the PC advances.  8-bit increment plus a carry, not a 16-bit
    // adder.
    wire       pcl_co  = &pcl;
    wire [7:0] pcl_inc = pcl + 8'd1;
    wire [7:0] pch_inc = pch + {7'd0, pcl_co};

    // ---- address bus --------------------------------------------------------
    // Every source but AGU is a plain concatenation of registers, so this mux
    // costs one level and no arithmetic.
    logic [15:0] addr_mux;
    logic        asel_is_pc;        // this cycle's address comes from PC: the
                                    // program stream, for cyc_is_i.  Set in the
                                    // one place that knows, so the
                                    // classification can never drift from the
                                    // mux it describes.
    always_comb begin
        asel_is_pc = 1'b0;
        case (f_asel)
            UC_ADDR_AGU:  addr_mux = {agu_hi, agu_lo};
            // The address driven during the PREVIOUS bus cycle.  This is the
            // whole of the CMOS dummy-cycle rule: where the NMOS part put a
            // partially-formed effective address on the bus during an internal
            // cycle, the 65C02 re-reads whatever it read last - the operand
            // byte, the pointer's high byte, PC.  Measured across 24.7 million
            // cycles against a real part; see docs/DERISK.md.
            //
            // A registered mux input, so it costs the same as any other source
            // and keeps this mux at one level with no arithmetic in it.
            UC_ADDR_LAST: addr_mux = last_addr;
            // The indexed fixup cycle, where what the part drives depends on
            // the DATA and not on the instruction: it re-reads the last program
            // byte when the index carried and the address therefore needs
            // fixing, and drives the effective address when it did not.  The
            // saved carry is the same one this cycle uses to move ADH, so this
            // costs a two-input mux and no new state.
            UC_ADDR_FIXUP: addr_mux = agu_c ? last_addr : {adh, adl};
            UC_ADDR_ZP:   addr_mux = {8'h00, adl};
            UC_ADDR_AD:   addr_mux = {adh, adl};
            UC_ADDR_SP:   addr_mux = {8'h01, s};
            UC_ADDR_VEC:  addr_mux = {8'hFF, vec_lo};
            UC_ADDR_VEC1: addr_mux = {8'hFF, vec_lo + 8'd1};
            default: begin
                addr_mux   = {pch, pcl};
                asel_is_pc = 1'b1;
            end
        endcase
    end

    assign addr   = addr_mux;

    // The classified views.  Same wires, two names: which one is meaningful
    // this cycle is exactly what cyc_is_i says.
    assign cyc_is_i = asel_is_pc;
    assign i_addr   = addr_mux;
    assign pc_addr  = {pch, pcl};
    assign d_addr   = addr_mux;
    assign d_rw     = rw;
    assign d_dout   = dout;

    // One cycle of history, for UC_ADDR_LAST above.  Advanced on cyc_en so it
    // tracks BUS cycles rather than clocks, which is what the rule is about.
    always_ff @(posedge clk) begin
        if (rst)          last_addr <= 16'h0000;
        else if (cyc_en)  last_addr <= addr_mux;
    end

    // Reset runs the BRK microcode but must not write: the three stack cycles
    // become reads.  Cheaper and less error-prone than a second sequence.
    assign rw     = f_rw | in_rst;
    assign sync   = f_sync;
    assign halted = 1'b0;               // STP is not on the base part (rung 7: the register went)

    // ---- ALU ----------------------------------------------------------------
    // Entirely parallel to the AGU; the two never feed each other.
    logic [7:0] alu_m;
    always_comb begin
        case (f_alu_a)
            UC_ALU_A_A:    alu_m = a;
            UC_ALU_A_X:    alu_m = x;
            UC_ALU_A_Y:    alu_m = y;
            UC_ALU_A_S:    alu_m = s;
            UC_ALU_A_ZERO: alu_m = 8'h00;
            UC_ALU_A_MD:   alu_m = md;
            default:       alu_m = din;
        endcase
    end

    logic [7:0] alu_res;
    logic       alu_n, alu_v, alu_z, alu_c;

    wire [7:0] add_m   = (f_alu_op == UC_OP_SBC) ? ~din : din;
    wire [8:0] bin_sum = {1'b0, a} + {1'b0, add_m} + {8'd0, f_c};
    wire [7:0] add_vv  = ~(a ^ add_m) & (a ^ bin_sum[7:0]);
    wire       add_v   = add_vv[7];

    wire [7:0] cmp_a = a - din;
    wire [7:0] cmp_x = x - din;
    wire [7:0] cmp_y = y - din;

    // Decimal ADC/SBC, nibble at a time.  Continuous assignments so each
    // correction step visibly feeds the next.
    wire [3:0] a_lo = a[3:0],   a_hi = a[7:4];
    // THE DECIMAL OPERATION RUNS IN ITS OWN CYCLE (2026-09-14).  The 65C02
    // spends one extra cycle on ADC/SBC with D set - a dummy read at PC the
    // generator already emitted - and the BCD add now happens THERE, from
    // registers: the operand is dm (the byte the read slot latched), A and
    // the carry are untouched in between because the read slot writes
    // nothing in decimal mode (dec_defer).  These chains are textually the
    // one-cycle version's with din replaced by dm.  Before, the nibble
    // correction sat between the served byte's carry chain and A/Z: the
    // IIe's deepest core chain (build woz5, dline dq_sx -> f_z, 15 levels,
    // five LUT6 after the CARRY4, all of them this select and its zero test).
    wire [3:0] m_lo = dm[3:0],  m_hi = dm[7:4];

    wire [4:0] adc_lo0 = {1'b0, a_lo} + {1'b0, m_lo} + {4'd0, f_c};
    wire [4:0] adc_lo1 = (adc_lo0 > 5'd9) ? (adc_lo0 + 5'd6) : adc_lo0;
    wire [5:0] adc_hi0 = {1'b0, a_hi} + {1'b0, m_hi} + {5'd0, adc_lo1[4]};
    wire [5:0] adc_hi1 = (adc_hi0 > 6'd9) ? (adc_hi0 + 6'd6) : adc_hi0;
    wire [7:0] dadc_res = {adc_hi1[3:0], adc_lo1[3:0]};
    wire       dadc_c   = (adc_hi1 > 6'd15);

    // SBC: C and V come from the BINARY result on the 65C02; only the digits are
    // corrected.  N and Z follow the corrected result, which is the CMOS fix.
    wire [4:0] sbc_lo0 = {1'b0, a_lo} - {1'b0, m_lo} - {4'd0, ~f_c};
    wire [5:0] sbc_hi0 = {1'b0, a_hi} - {1'b0, m_hi} - {5'd0, sbc_lo0[4]};
    wire [4:0] sbc_lo1 = sbc_lo0[4] ? (sbc_lo0 - 5'd6) : sbc_lo0;
    wire [5:0] sbc_hi1 = sbc_hi0[5] ? (sbc_hi0 - 6'd6) : sbc_hi0;
    wire [7:0] dsbc_res = {sbc_hi1[3:0], sbc_lo1[3:0]};

    // The decimal slot's binary terms, from the same registers: V is the
    // binary overflow in both modes and SBC's carry the binary borrow, as the
    // one-cycle version had them.
    wire [7:0] dadd_m   = (f_alu_op == UC_OP_DSBC) ? ~dm : dm;
    wire [8:0] dbin_sum = {1'b0, a} + {1'b0, dadd_m} + {8'd0, f_c};
    wire [7:0] dadd_vv  = ~(a ^ dadd_m) & (a ^ dbin_sum[7:0]);
    wire       dadd_v   = dadd_vv[7];

    // A read slot of ADC/SBC with D set defers to the decimal slot: no A, no
    // flags.  Register-rooted (a uc field and f_d), so it gates nothing late.
    // sim/gen_microcode.py check_decimal holds every ADC/SBC word to having
    // that slot behind it.
    wire dec_defer = f_d && ((f_alu_op == UC_OP_ADC) || (f_alu_op == UC_OP_SBC));

    always_comb begin
        alu_res = alu_m;
        alu_n   = f_n;
        alu_v   = f_v;
        alu_z   = f_z;
        alu_c   = f_c;
        case (f_alu_op)
        UC_OP_LD:  begin alu_res = alu_m; alu_n = alu_m[7]; alu_z = (alu_m == 8'h00); end
        UC_OP_TXS:       alu_res = alu_m;                        // no flags
        UC_OP_AND: begin alu_res = a & din; alu_n = alu_res[7]; alu_z = (alu_res == 8'h00); end
        UC_OP_ORA: begin alu_res = a | din; alu_n = alu_res[7]; alu_z = (alu_res == 8'h00); end
        UC_OP_EOR: begin alu_res = a ^ din; alu_n = alu_res[7]; alu_z = (alu_res == 8'h00); end
        UC_OP_ADC: begin
            alu_v   = add_v;
            alu_res = bin_sum[7:0];
            alu_c   = bin_sum[8];
            alu_n   = alu_res[7];
            alu_z   = (alu_res == 8'h00);
        end
        UC_OP_SBC: begin
            alu_v   = add_v;
            alu_res = bin_sum[7:0];
            alu_c   = bin_sum[8];
            alu_n   = alu_res[7];
            alu_z   = (alu_res == 8'h00);
        end
        UC_OP_DADC: begin
            alu_v   = dadd_v;
            alu_res = dadc_res;
            alu_c   = dadc_c;
            alu_n   = alu_res[7];
            alu_z   = (alu_res == 8'h00);
        end
        UC_OP_DSBC: begin
            alu_v   = dadd_v;
            alu_res = dsbc_res;
            alu_c   = dbin_sum[8];                               // binary borrow, as before
            alu_n   = alu_res[7];
            alu_z   = (alu_res == 8'h00);
        end
        UC_OP_CMP: begin alu_n = cmp_a[7]; alu_z = (a == din); alu_c = (a >= din); end
        UC_OP_CPX: begin alu_n = cmp_x[7]; alu_z = (x == din); alu_c = (x >= din); end
        UC_OP_CPY: begin alu_n = cmp_y[7]; alu_z = (y == din); alu_c = (y >= din); end
        UC_OP_BIT: begin alu_n = din[7]; alu_v = din[6]; alu_z = ((a & din) == 8'h00); end
        UC_OP_BITI:      alu_z = ((a & din) == 8'h00);           // BIT # touches Z only
        UC_OP_ASL: begin alu_res = {alu_m[6:0], 1'b0}; alu_c = alu_m[7]; alu_n = alu_res[7]; alu_z = (alu_res == 8'h00); end
        UC_OP_LSR: begin alu_res = {1'b0, alu_m[7:1]}; alu_c = alu_m[0]; alu_n = alu_res[7]; alu_z = (alu_res == 8'h00); end
        UC_OP_ROL: begin alu_res = {alu_m[6:0], f_c};  alu_c = alu_m[7]; alu_n = alu_res[7]; alu_z = (alu_res == 8'h00); end
        UC_OP_ROR: begin alu_res = {f_c, alu_m[7:1]};  alu_c = alu_m[0]; alu_n = alu_res[7]; alu_z = (alu_res == 8'h00); end
        UC_OP_INC: begin alu_res = alu_m + 8'd1; alu_n = alu_res[7]; alu_z = (alu_res == 8'h00); end
        UC_OP_DEC: begin alu_res = alu_m - 8'd1; alu_n = alu_res[7]; alu_z = (alu_res == 8'h00); end
        UC_OP_TRB: begin alu_res = din & ~a; alu_z = ((a & din) == 8'h00); end
        UC_OP_TSB: begin alu_res = din |  a; alu_z = ((a & din) == 8'h00); end
        default: ;
        endcase
    end

    // ---- write data ---------------------------------------------------------
    // B is a property of the PUSH, not a register: set by PHP and BRK, clear for
    // a hardware interrupt.
    wire [7:0] p_push = {p_bits[7:6], 1'b1, int_brk | (ir == 8'h08), p_bits[3:0]};

    logic [7:0] dout_mux;
    always_comb begin
        case (f_dout)
            UC_DOUT_X:    dout_mux = x;
            UC_DOUT_Y:    dout_mux = y;
            UC_DOUT_ZERO: dout_mux = 8'h00;
            UC_DOUT_P_B:  dout_mux = p_push;
            UC_DOUT_PCL:  dout_mux = pcl;
            UC_DOUT_PCH:  dout_mux = pch;
            UC_DOUT_MD:   dout_mux = md;
            default:      dout_mux = a;
        endcase
    end
    assign dout = dout_mux;

    // ---- sequencing ---------------------------------------------------------
    // Branch condition: ir[7:6] picks the flag, ir[5] the sense.  BRA collides
    // with that encoding and gets COND_ALWAYS from the microcode instead, so it
    // never reaches here.
    wire br_flag = (ir[7:6] == 2'b00) ? f_n :
                   (ir[7:6] == 2'b01) ? f_v :
                   (ir[7:6] == 2'b10) ? f_c : f_z;

    // A taken branch needs the extra cycle exactly when the low-byte add left
    // the page: carry out disagreeing with the offset's sign.
    wire page_adj = agu_co ^ adl[7];

    logic cond_met;
    always_comb begin
        case (f_cond)
            UC_COND_NEVER:  cond_met = 1'b0;
            UC_COND_CARRY:  cond_met = agu_co;
            UC_COND_BRANCH: cond_met = (br_flag == ir[5]);
            UC_COND_PAGE:   cond_met = page_adj;
            UC_COND_DEC:    cond_met = f_d;
            default:        cond_met = 1'b1;
        endcase
    end

    wire [2:0] ucyc_next = cond_met ? (ucyc + 3'd1) : f_alt;

    // An instruction boundary is the only place an interrupt gets in.
    wire irq_ready = nmi_pend | (~irq_n & ~f_i);
    wire take_int  = f_sync & irq_ready & ~in_rst;


    // The PC must NOT advance on a hardware interrupt: the pushed return address
    // is the instruction that was ABOUT to run, so RTI comes back to it rather
    // than two bytes past it.  BRK is the opposite - a two-byte instruction that
    // DOES advance to PC+2 - and int_brk is what tells them apart, both running
    // this same microcode.
    //
    // Two cycles increment PC on the way into that microcode and both must be
    // held for an interrupt:
    //   * the hijacked opcode fetch          - take_int, the boundary cycle
    //   * BRK's operand-read slot (slot 0)    - ir==0, ucyc==0, and NOT a BRK
    // On a real 65C02 both of those are dummy reads at the SAME address (the
    // boundary), which is exactly what holding PC across them produces.
    //
    // Reset runs the microcode too but is excluded: its pushes are discarded
    // and its PC is overwritten by the vector, so whether it increments in
    // between changes nothing - and leaving in_rst out keeps that path
    // bit-for-bit as it was measured.  This was invisible until a live IRQ:
    // every testbench ties irq_n high, so nothing ever entered here as an
    // interrupt rather than a reset or a BRK.
    wire int_pc_hold = take_int |
                       (~in_rst & ~int_brk & (ir == 8'h00) & (ucyc == 3'd0));

    // ---- microinstruction fetch: dual-arm read, late select -----------------
    // Both candidate addresses are EARLY (registers and uc fields; din only
    // under f_sync, never the critical path).  The one LATE term is cond_met -
    // agu_co through the AGU carry chain - and it selects between two
    // already-fetched words, one LUT level, instead of steering the address
    // into the whole ROM tree.
    wire [UA_W-1:0] uaddr_taken = {ir, ucyc + 3'd1};    // the fall-through arm

    logic [UA_W-1:0] uaddr_alt;                         // every other arm
    always_comb begin
        if (f_sync) begin
            // The opcode is on din right now.  An interrupt hijacks the slot by
            // running BRK's microcode against the byte that was just discarded.
            // i_din, not din: a SYNC cycle is an instruction-stream cycle by
            // definition (cyc_is_i = asel_is_pc), so the byte is i_din's and
            // the mux is transparent - but written through `din` the data
            // front's served byte (d_din) reached the microcode ROM address
            // and, through it, the D-side prediction: a false path static
            // timing charged at zero margin (docs/DLINE.md, the serve-byte
            // cone).  Sourcing the opcode from the I byte cuts it.
            uaddr_alt = take_int ? {8'h00, 3'd0} : {i_din, 3'd0};
        end else begin
            uaddr_alt = {ir, f_alt};
        end
    end

    wire [UC_W-1:0] uc_taken = ucode[uaddr_taken];
    wire [UC_W-1:0] uc_alt   = ucode[uaddr_alt];

    // f_sync wins over the condition: take_seq is 0 whenever the fetch arm
    // fires, so uc_alt carries it regardless of what cond_met says.  ucyc_next
    // above derives from the same cond_met, so sequencer and fetch cannot
    // disagree.
    wire take_seq = ~f_sync & cond_met;
    wire [UC_W-1:0] uc_next = take_seq ? uc_taken : uc_alt;

    // ---- register file ------------------------------------------------------
    // Every load is unconditional (rung 7, 2026-09-19): the `ld_if` gate that
    // let BBR/BBS branch without a cycle - a field no word of this ROM set -
    // sat in every register's enable cone for nothing.

    // ---- next PC ------------------------------------------------------------
    // The value the PC registers take at this cycle's edge - equivalently, the
    // address of the NEXT program-stream fetch, whenever it comes.  Exported
    // as i_pred so a predictive icache can have the line read BEFORE the fetch
    // cycle begins: sequential flow, taken branches, jumps and returns all
    // predict exactly, because this is not a guess - it is the same mux that
    // loads the registers, and the registers load FROM it below, so predictor
    // and architecture cannot disagree.  It inherits din's timing
    // (UC_LD_PC_JMP takes the high byte from the bus), so it settles when din
    // does and no earlier.
    //
    // Held on an interrupt entry - see int_pc_hold above.  BRK and every
    // ordinary fetch still advance.
    logic [15:0] next_pc;
    always_comb begin
        next_pc = {pch, pcl};
        begin
            case (f_ld_pc)
                UC_LD_PC_INC:    if (!int_pc_hold) next_pc = {pch_inc, pcl_inc};
                UC_LD_PC_AGU:    next_pc = {agu_hi, agu_lo};
                UC_LD_PC_AGU_LO: next_pc = {pch, agu_lo};
                UC_LD_PC_AGU_HI: next_pc = {agu_hi, pcl};
                UC_LD_PC_JMP:    next_pc = {din, md};
                default: ;
            endcase
        end
    end
    assign i_pred = next_pc;

    // ---- next data address --------------------------------------------------
    // d_pred: the address of the NEXT cycle when that cycle is a data cycle -
    // the D-side mirror of next_pc/i_pred, and like it, not a guess.  The
    // microinstruction that will RUN next cycle is uc_next, the very word the
    // uc register is about to load; its addr_sel
    // names next cycle's source, and every data source is either a register
    // this cycle's loads settle (adl/adh/s - the next-state values below are
    // the same expressions the register file's edge applies), this cycle's own
    // bus address (LAST re-reads it), or this cycle's carry-out (FIXUP,
    // consumed next cycle as the saved carry).  A next-cycle live-AGU address
    // is the one thing not named a cycle early; after the carry-gift work only
    // the $5C NOP drives one, and d_pred_v is simply low there.
    //
    // Nothing here is new logic on any existing path: the fetch is the one
    // uc already takes, and the next-state muxes parallel the register file.
    // Like i_pred this settles with din; a consumer registers it and has the
    // full data cycle to act on the registered copy (rtl/iline.sv's contract).
    wire [3:0]      n_asel   = uc_next[UCP_ADDR_SEL +: 4];
    wire            n_rw_bit = uc_next[UCP_RW];

    // The registers as this cycle's edge will leave them - the same arms,
    // gated the same way, as the clocked loads below.
    logic [7:0] adl_n, adh_n, s_n;
    always_comb begin
        adl_n = adl; adh_n = adh; s_n = s;
        begin
            case (f_ld_adl)
                UC_LD_ADL_AGU: adl_n = agu_lo;
                UC_LD_ADL_DIN: adl_n = din;
                UC_LD_ADL_MD:  adl_n = md;
                default: ;
            endcase
            case (f_ld_adh)
                UC_LD_ADH_AGU: adh_n = agu_hi;
                UC_LD_ADH_DIN: adh_n = din;
                default: ;
            endcase
            case (f_ld_s)
                UC_LD_S_INC: s_n = s + 8'd1;
                UC_LD_S_DEC: s_n = s - 8'd1;
                default: ;
            endcase
            // TXS: the only word that writes S, and its operand is X, so S
            // takes X itself - not the ALU result, whose cone holds the served
            // byte (din).  s_n is the next data address's source (UC_ADDR_SP),
            // and through alu_res a served byte reached it in the same clock:
            // a path the microcode never exercises, but the worst path of the
            // whole design (the dline serve loop, 17 levels, 2026-09-06).
            if (f_wb == UC_WB_S) s_n = x;
        end
    end

    // Reset holds rw high next cycle as this one (`rw = f_rw | in_rst`); the
    // vector fetch's PC load is what ends in_rst, on this cycle's edge.
    wire in_rst_n = in_rst && !(cyc_en && f_ld_pc == UC_LD_PC_JMP);

    logic [15:0] d_pred_mux;
    logic        d_pred_known;
    always_comb begin
        d_pred_known = 1'b1;
        case (n_asel)
            UC_ADDR_ZP:    d_pred_mux = {8'h00, adl_n};
            UC_ADDR_AD:    d_pred_mux = {adh_n, adl_n};
            UC_ADDR_SP:    d_pred_mux = {8'h01, s_n};
            UC_ADDR_VEC:   d_pred_mux = {8'hFF, vec_lo};
            UC_ADDR_VEC1:  d_pred_mux = {8'hFF, vec_lo + 8'd1};
            UC_ADDR_LAST:  d_pred_mux = addr_mux;
            UC_ADDR_FIXUP: d_pred_mux = agu_co ? addr_mux : {adh_n, adl_n};
            default: begin
                // AGU: a live add next cycle ($5C only).  PC-sourced cycles
                // are the I stream and d_pred_v is gated off below either way.
                d_pred_mux   = 16'h0000;
                d_pred_known = (n_asel != UC_ADDR_AGU);
            end
        endcase
    end

`ifndef SYNTHESIS
    // The assumption s_n rests on: a word that writes S has X as its ALU
    // operand (TXS).  Anything else is a microcode change that must revisit
    // s_n, not silently write the wrong S.
    always_ff @(posedge clk) begin
        if (!rst && cyc_en && f_wb == UC_WB_S && f_alu_a != UC_ALU_A_X)
            $error("cpu65c02: a microcode word writes S from an ALU operand other than X");
    end
`endif

`ifndef SYNTHESIS
    // The deferred decimal operation against the one-cycle one: at a read
    // slot that defers, compute what that slot USED to write, from the live
    // din, and demand the decimal slot write exactly that - A, N, V, Z, C.
    // Every decimal ADC/SBC any bench runs becomes an equivalence check.
    function automatic [11:0] dec_ref(input [7:0] ra, input [7:0] rm, input rc, input sbc);
        logic [4:0] l0, l1;
        logic [5:0] h0, h1;
        logic [7:0] am, vv, res;
        logic [8:0] bs;
        logic       cc;
        am = sbc ? ~rm : rm;
        bs = {1'b0, ra} + {1'b0, am} + {8'd0, rc};
        vv = ~(ra ^ am) & (ra ^ bs[7:0]);
        if (!sbc) begin
            l0 = {1'b0, ra[3:0]} + {1'b0, rm[3:0]} + {4'd0, rc};
            l1 = (l0 > 5'd9) ? (l0 + 5'd6) : l0;
            h0 = {2'b00, ra[7:4]} + {2'b00, rm[7:4]} + {5'd0, l1[4]};
            h1 = (h0 > 6'd9) ? (h0 + 6'd6) : h0;
            cc = (h1 > 6'd15);
        end else begin
            l0 = {1'b0, ra[3:0]} - {1'b0, rm[3:0]} - {4'd0, ~rc};
            h0 = {2'b00, ra[7:4]} - {2'b00, rm[7:4]} - {5'd0, l0[4]};
            l1 = l0[4] ? (l0 - 5'd6) : l0;
            h1 = h0[5] ? (h0 - 6'd6) : h0;
            cc = bs[8];
        end
        res = {h1[3:0], l1[3:0]};
        dec_ref = {res, res[7], vv[7], (res == 8'h00), cc};
    endfunction
    logic [11:0] dchk_exp;
    logic        dchk_pend;
    always_ff @(posedge clk) begin
        if (rst) dchk_pend <= 1'b0;
        else if (cyc_en) begin
            if (dec_defer) begin
                dchk_exp  <= dec_ref(a, din, f_c, f_alu_op == UC_OP_SBC);
                dchk_pend <= 1'b1;
            end else if (f_alu_op == UC_OP_DADC || f_alu_op == UC_OP_DSBC) begin
                if (!dchk_pend)
                    $error("cpu65c02: a decimal slot with no deferred ADC/SBC before it");
                else if ({alu_res, alu_n, alu_v, alu_z, alu_c} != dchk_exp)
                    $error("cpu65c02: deferred decimal %s wrote %02x nvzc=%b, the one-cycle form %02x nvzc=%b",
                           f_alu_op == UC_OP_DSBC ? "SBC" : "ADC", alu_res, {alu_n, alu_v, alu_z, alu_c},
                           dchk_exp[11:4], dchk_exp[3:0]);
                dchk_pend <= 1'b0;
            end
        end
    end
`endif

    assign d_pred    = d_pred_mux;
    assign d_pred_v  = d_pred_known &&
                       (n_asel != UC_ADDR_PC) && (n_asel != UC_ADDR_AGU);
    assign d_pred_rw = n_rw_bit | in_rst_n;

    always_ff @(posedge clk) begin
        if (rst) begin
            a <= 8'h00; x <= 8'h00; y <= 8'h00; s <= 8'h00;
            pcl <= 8'h00; pch <= 8'h00;
            f_n <= 1'b0; f_v <= 1'b0; f_d <= 1'b0;
            f_i <= 1'b1; f_z <= 1'b0; f_c <= 1'b0;
            ir <= 8'h00; adl <= 8'h00; adh <= 8'h00; md <= 8'h00;
            agu_c <= 1'b0;
            nmi_prev <= 1'b1; nmi_pend <= 1'b0;
            int_brk <= 1'b0; int_nmi <= 1'b0; in_rst <= 1'b1;
            // Enter BRK's microcode from the top.  Reset runs the same sequence
            // an interrupt does - a dummy read at PC, three stack accesses (as
            // reads, forced by `rw = f_rw | in_rst`), then the vector - so it is
            // the same microcode, not a special case.
            //
            // 3'd7, not 3'd0, and the reason is the ROM's pipeline: the fetch
            // addresses hold ucyc_NEXT, so the slot fetched during a cycle is
            // the one that RUNS in the following one.  The cycle out of reset
            // runs the zeroed `uc` below, and what it fetches is slot ucyc+1.
            // Entering at 7 therefore makes that zeroed cycle stand in for a
            // slot of its own and resumes at slot 0; entering at 1 - as this
            // did - skipped slot 1 entirely, which cost reset a stack cycle
            // and left S one byte high.  From 7 the dual-arm fetch reads
            // address 0 on BOTH arms (uaddr_taken wraps 7+1 to 0 and the
            // zeroed f_alt is 0), so the entry does not depend on how a
            // zeroed condition field evaluates.
            //
            // The count that results is the part's: two reads at PC (this cycle
            // and slot 0), three stack, two vector - seven.
            ucyc  <= 3'd7;
            uc    <= '0;
        end else if (cyc_en) begin
            uc   <= uc_next;
            ucyc <= f_sync ? 3'd0 : ucyc_next;

            // The PC loads FROM next_pc - the same mux i_pred exports - so a
            // predictive icache follows the architecture by construction.
            // next_pc already folds in int_pc_hold and the hold default, hence
            // no gate here.
            pcl <= next_pc[7:0];
            pch <= next_pc[15:8];

            nmi_prev <= nmi_n;
            if (nmi_prev & ~nmi_n) nmi_pend <= 1'b1;

            agu_c <= agu_co;
            dm    <= din;

            if (f_sync) begin
                if (take_int) begin
                    ir       <= 8'h00;              // run BRK's microcode
                    int_brk  <= 1'b0;
                    int_nmi  <= nmi_pend;
                    nmi_pend <= 1'b0;
                end else begin
                    ir      <= i_din;               // the I byte: see uaddr_alt
                    int_brk <= (i_din == 8'h00);
                    int_nmi <= 1'b0;
                end
            end

            begin
                case (f_ld_adl)
                    UC_LD_ADL_AGU: adl <= agu_lo;
                    UC_LD_ADL_DIN: adl <= din;
                    UC_LD_ADL_MD:  adl <= md;
                    default: ;
                endcase
                case (f_ld_adh)
                    UC_LD_ADH_AGU: adh <= agu_hi;
                    UC_LD_ADH_DIN: adh <= din;
                    default: ;
                endcase
                case (f_ld_s)
                    UC_LD_S_INC: s <= s + 8'd1;
                    UC_LD_S_DEC: s <= s - 8'd1;
                    default: ;
                endcase

                case (f_wb)
                    UC_WB_A:  if (!dec_defer) a <= alu_res;
                    UC_WB_X:  x  <= alu_res;
                    UC_WB_Y:  y  <= alu_res;
                    UC_WB_S:  s  <= x;                  // TXS; see s_n above
                    UC_WB_MD: md <= alu_res;
                    UC_WB_P:  begin
                        f_n <= din[7]; f_v <= din[6]; f_d <= din[3];
                        f_i <= din[2]; f_z <= din[1]; f_c <= din[0];
                    end
                    default: ;
                endcase

                if (f_fl && !dec_defer) begin
                    f_n <= alu_n; f_v <= alu_v; f_z <= alu_z; f_c <= alu_c;
                end

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

                // Interrupt entry: mask further IRQs, and clear D - the CMOS
                // behaviour the NMOS part lacks.
                if (f_seti) begin
                    f_i <= 1'b1;
                    f_d <= 1'b0;
                end
            end

            // The vector fetch is the end of the reset/interrupt sequence.
            if (f_ld_pc == UC_LD_PC_JMP) begin
                in_rst  <= 1'b0;
                int_nmi <= 1'b0;
            end

        end
    end

endmodule
