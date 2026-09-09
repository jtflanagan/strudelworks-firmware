`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// gs_doc - the Ensoniq 5503 DOC, the IIgs's sound chip, at $C03C-$C03F.
//
// THE REFERENCE IS KEGS's doc.c, for the reason docs/GS.md keeps giving: a
// model written from the reference disagrees with the RTL wherever either is
// wrong, while a model written from the RTL agrees with its bugs.  What is
// transcribed is doc_write_c03d, doc_read_c03d, doc_write_ctl_reg,
// doc_sound_end, doc_start_sound, doc_recalc_sound_parms, doc_add_sound_irq
// and doc_remove_sound_irq.  What is NOT transcribed is doc_play: that is a
// host emulator generating a buffer of samples in floating point, batched
// over a whole audio period, and it is a re-statement of the chip rather than
// the chip.  The chip is below.
//
// WHY IT HAD TO BE BUILT.  Before this the module was a FACE - four latches
// that read back what the ROM wrote - and its data port answered $00 to
// everything.  Register $E0 is the interrupt register and BIT 7 CLEAR MEANS
// AN INTERRUPT IS PENDING (doc.c:769, "Clear IRQ on read of e0, if any irq
// pend"), so a face answering zero says "oscillator 0 is interrupting" for
// ever.  GS/OS's dispatcher believed it, found nobody to claim it, and the
// screen flashed "Unclaimed Sound Interrupt".  Exactly the shape of the IWM's
// constant $C0 in rung 3e - a stub whose one constant happens to mean "I need
// attention".  The fix is not a better constant.
//
// ---- THE SCAN ---------------------------------------------------------------
// The 5503 services ONE OSCILLATOR PER SLOT at a fixed rate, and the enabled
// count sets how often any one of them comes round: DOC_SCAN_RATE is
// 28.63636 MHz / 32 = 894886.25 Hz (doc.c:63) and each oscillator ticks at
// that over (osc_en + 2).  With the usual 32 enabled that is 26320 Hz, the
// IIgs's familiar sample rate.  So there is no per-oscillator timer here: one
// NCO, one scan index, and an oscillator's tick IS its slot coming round.
// At 100 MHz a slot is ~112 clocks, which is room enough for the register
// read, the wave fetch and the multiply without any of it being tight.
//
// ---- THE ACCUMULATOR --------------------------------------------------------
// Each oscillator has a 24-bit accumulator; its slot adds `freq` to it.  The
// byte played is at
//
//     index = acc >> (17 - sz + res),   masked to sz bits
//     addr  = (waveptr << 8) & ~(size - 1)  |  index
//
// where size = 1 << sz, sz = ((wavesize >> 3) & 7) + 8 and res = wavesize & 7
// (doc_recalc_sound_parms).  KEGS carries the same arithmetic scaled into its
// own SND_PTR_SHIFT fixed point and folded together with the host's audio
// rate; unfolded, it is this.  The table is played through exactly once, so
// the oscillator ENDS when
//
//     acc >= (1 << (17 + res))
//
// and that is the check the shape confirms: at res = 7 and sz = 15 - the
// largest table, the finest resolution - the end is 1 << 24, which is exactly
// the accumulator's width.  It fits the register the chip has, at the corner,
// with nothing left over.
//
// ---- HOW AN OSCILLATOR STOPS ------------------------------------------------
// Two ways, and they are not the same (doc_sound_end's `can_repeat`):
//
//   the byte fetched is ZERO   the wavetable's terminator.  can_repeat = 0.
//   the accumulator runs out   the table was played to its end.  can_repeat = 1.
//
// Then, with `mode` = (ctl >> 1) & 3 and the partner being osc ^ 1:
//
//   mode 0, free-run, and can_repeat   start again, from acc = 0.  A
//                                      free-running table with no zero byte
//                                      in it loops for ever, which is how a
//                                      held note is made.
//   mode 3 (swap), OR THE PARTNER IN   halt this one and start the partner,
//   MODE 3                             unless this one is one-shot and hit a
//                                      zero byte.  "If either this osc or
//                                      it's partner is in swap mode, treat
//                                      the pair as being in swap mode" -
//                                      doc.c:311, credited to Ian Schmidt,
//                                      and the one-shot exception credited to
//                                      Olivier Goguel.  Neither is guessable.
//   otherwise                          halt: ctl |= 1.
//
// The accumulator is reset to zero on EVERY end, before any of that.
//
// ---- THE INTERRUPT IS A QUEUE, NOT A BIT VECTOR ------------------------------
// This is the part a reasonable implementation gets wrong.  $E0 does not name
// the lowest-numbered interrupting oscillator; it names the OLDEST.  KEGS
// keeps `has_irq_pending` as a 1-based ARRIVAL RANK per oscillator and
// renumbers the survivors when one is removed from the middle
// (doc_remove_sound_irq's loop), so what $E0 reports walks the oscillators in
// the order their interrupts happened.  A bit vector with a priority encoder
// would answer differently the moment two oscillators interrupt out of index
// order, and software that services them in turn would see the wrong one.
//
// So it is a real queue here: `q_osc` holds up to 32 oscillator numbers in
// arrival order, and a removal compacts it.  The compaction is done one entry
// a clock by a small state machine rather than as a 32-wide combinational
// shift, because this design's timing is tight and nothing needs it sooner.
//
// $E0 reads {1'b0, osc, 1'b0} for the head, or $FF when the queue is empty -
// doc_reg_e0's power-on value, and the value the remove path lands on when
// the last interrupt goes (its `first` starts as 0x40 | (e0 >> 1), so the
// shift back up sets bit 7).  A READ OF $E0 CLEARS THE HEAD's interrupt.
//
// ---- THE OUTPUT -------------------------------------------------------------
// The byte is unsigned with silence at $80, so the signed sample is
// (byte - 128) * vol - KEGS's `(val * imul) - off` with off = imul * 128.
// Bit 4 of the control register picks the channel, and on a IIgs the channel's
// low bit is the stereo side (doc_play: `if(ctl & 0x10) outptr += 1`).  Each
// slot adds its oscillator's contribution to a running left/right pair, and
// rtl/audio_sampler.sv box-averages those the way it already does the AYs.
//////////////////////////////////////////////////////////////////////////////////
module gs_doc #(
    // The scan NCO's phase step: DOC_SCAN_RATE / clk in 0.32 fixed point.
    // 894886.25 / 100e6 * 2^32 = 38430819.
    parameter [31:0] SCAN_INC = 32'd38430819
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,        // synchronised RES', ACTIVE LOW

    // The register face: $C03C-$C03F, as gs_io presents an internalized op.
    input  wire [7:0]  op_lo,
    input  wire        op_rw,
    input  wire [7:0]  op_wdata,
    input  wire        act,             // this op retired: apply its effect
    output logic [7:0] rd_byte,

    // The oscillators' mix, signed, latched once a scan.
    output logic signed [20:0] snd_l,
    output logic signed [20:0] snd_r,

    // Into gs_intc.
    output wire        irq,

    // Diagnostics a bench reads through the hierarchy.
    output logic [7:0] cnt_ends,
    output logic [7:0] cnt_irqs
);

    // ---- the register file --------------------------------------------------
    logic [15:0] freq  [0:31];
    logic [7:0]  vol   [0:31];
    logic [7:0]  wptr  [0:31];
    logic [7:0]  ctl   [0:31];
    logic [7:0]  wsize [0:31];
    logic [7:0]  lastv [0:31];      // the data register reads this back
    logic [23:0] acc   [0:31];
    logic [31:0] running;

    // The three globals.
    logic [7:0]  sound_ctl;         // $C03C: [6] RAM/registers, [5] auto-inc, [3:0] volume
    logic [7:0]  saved;             // $C03D's ONE-ACCESS READ DELAY
    logic [15:0] ptr;               // $C03E/$C03F
    logic [5:0]  osc_en;            // from $E1: oscillators enabled, 1..32

    // ---- the wave RAM: 64 KB, true dual port --------------------------------
    // Port A is the machine's, through $C03D; port B is the scan's fetch.
    // rtl/way_ram.sv's template and its reasons: two processes, one array, the
    // read registered so Vivado infers block RAM.  16 BRAM36 tiles, which
    // docs/GS.md budgeted for this rung.
    (* ram_style = "block" *) logic [7:0] wram [0:65535];
    logic [7:0]  a_q, b_q;
    logic [15:0] b_addr;
    wire         a_we = act && !op_rw && (op_lo == 8'h3D) && sound_ctl[6];
    always_ff @(posedge clk) begin
        if (a_we) wram[ptr] <= op_wdata;
        a_q <= wram[ptr];
    end
    always_ff @(posedge clk) begin
        b_q <= wram[b_addr];
    end

    // ---- the interrupt queue ------------------------------------------------
    // Arrival order, not index order - see the header.  Up to 32 deep, which
    // is every oscillator interrupting at once.
    logic [4:0] q_osc [0:31];
    logic [5:0] q_n;
    wire        q_empty = (q_n == 6'd0);
    wire [7:0]  reg_e0  = q_empty ? 8'hFF : {2'b00, q_osc[0], 1'b0};
    assign irq = !q_empty;

    // Is this oscillator in the queue, and where?  One comparison an entry;
    // the queue is short and the result is only used a clock later.
    logic [5:0] q_find;             // 0 = not present, else index + 1
    logic [4:0] q_want;
    integer f;
    always_comb begin
        q_find = 6'd0;
        for (f = 31; f >= 0; f = f - 1)
            if ((f < int'(q_n)) && (q_osc[f] == q_want)) q_find = f[5:0] + 6'd1;
    end

    // ---- $C03D's fetch, without its side effects ----------------------------
    wire [4:0] p_osc  = ptr[4:0];
    wire [2:0] p_type = ptr[7:5];
    logic [7:0] fetch;
    always_comb begin
        if (sound_ctl[6]) begin
            fetch = a_q;                                  // the RAM
        end else begin
            case (p_type)
                3'd0:    fetch = freq[p_osc][7:0];
                3'd1:    fetch = freq[p_osc][15:8];
                3'd2:    fetch = vol[p_osc];
                3'd3:    fetch = lastv[p_osc];
                3'd4:    fetch = wptr[p_osc];
                3'd5:    fetch = ctl[p_osc];
                3'd6:    fetch = wsize[p_osc];
                // $E0-$FF: only three of them answer (doc.c:766).
                default: case (p_osc)
                             5'h00:   fetch = reg_e0;
                             5'h01:   fetch = {1'b0, (osc_en[5:0] - 6'd1), 1'b0};
                             5'h02:   fetch = 8'h80;
                             default: fetch = 8'h00;
                         endcase
            endcase
        end
    end

    always_comb begin
        case (op_lo)
            8'h3C:   rd_byte = sound_ctl;
            8'h3D:   rd_byte = saved;
            8'h3E:   rd_byte = ptr[7:0];
            8'h3F:   rd_byte = ptr[15:8];
            default: rd_byte = 8'h00;
        endcase
    end

    // ---- the scan's slot ----------------------------------------------------
    // The oscillator being serviced, latched at the slot's start so the
    // arithmetic below is on stable values while the wave byte comes back.
    logic [4:0]  s_osc;
    logic [7:0]  s_ws, s_vol, s_ctl, s_wp;
    logic [15:0] s_freq;
    logic [23:0] s_acc;

    wire [3:0]  sz   = 4'd8 + {1'b0, s_ws[5:3]};          // 8..15
    wire [2:0]  res  = s_ws[2:0];
    wire [4:0]  shf  = (5'd17 - {1'b0, sz}) + {2'b00, res};
    // The table is played through once: the end is 1 << (17 + res), which at
    // res = 7 is 1 << 24 - the accumulator's own width, exactly.
    wire [24:0] a_end = 25'd1 << (5'd17 + {2'b00, res});
    wire [15:0] size_m1 = (16'd1 << sz) - 16'd1;
    wire [15:0] base    = {s_wp, 8'd0} & ~size_m1;
    wire [23:0] shifted = s_acc >> shf;
    wire [15:0] s_addr  = base | (shifted[15:0] & size_m1);

    wire [24:0] acc_next = {1'b0, s_acc} + {9'd0, s_freq};

    // The slot: address out, the RAM's clock, then apply.
    localparam [2:0] SL_IDLE = 3'd0, SL_ADDR = 3'd1, SL_WAIT = 3'd2,
                     SL_APPLY = 3'd3, SL_END = 3'd4;
    logic [2:0]  sl;
    logic [5:0]  slot;              // 0..osc_en+1; the last two are the chip's
                                    // refresh slots, which is where the "+2"
                                    // in the per-oscillator rate comes from.
    logic [32:0] nco;
    wire         slot_tick = nco[32];

    // The mix, accumulated across a scan and latched when it wraps.
    logic signed [20:0] mix_l, mix_r;
    wire signed [8:0]   samp   = {1'b0, b_q} - 9'sd128;    // silence is $80
    // ONE MULTIPLY, AND IT IS A DSP48.  The volume scaling is the only
    // arithmetic here wide enough to matter to timing, and this design has 238
    // of the 240 slices idle, so it is asked for by name rather than left to
    // inference - a 9x9 signed product is small enough that Vivado would
    // otherwise be free to build it out of LUTs on the slot's path.
    (* use_dsp = "yes" *) wire signed [17:0] contrib = samp * $signed({1'b0, s_vol});

    // ---- the machine's writes, decoded --------------------------------------
    wire op_wr   = act && !op_rw;
    wire wr_c03d = op_wr && (op_lo == 8'h3D) && !sound_ctl[6];
    wire rd_c03d = act && op_rw && (op_lo == 8'h3D);
    wire [2:0] w_type = ptr[7:5];
    wire [4:0] w_osc  = ptr[4:0];
    // A write to a control register, and a read of $E0, both touch the queue.
    wire ctl_wr  = wr_c03d && (w_type == 3'd5) && (ctl[w_osc] != op_wdata);
    wire e0_rd   = rd_c03d && !sound_ctl[6] && (w_type == 3'd7) && (w_osc == 5'd0)
                   && !q_empty;

    // What a control write means (doc_write_ctl_reg).
    wire       new_halt = op_wdata[0];
    wire       old_halt = ctl[w_osc][0];
    wire [1:0] old_mode = ctl[w_osc][2:1];
    wire [4:0] w_part   = {w_osc[4:1], ~w_osc[0]};

    // What an end means (doc_sound_end), computed on the slot's oscillator.
    logic       e_repeat;
    wire [1:0]  e_mode  = s_ctl[2:1];
    wire [4:0]  e_part  = {s_osc[4:1], ~s_osc[0]};
    wire [1:0]  e_omode = ctl[e_part][2:1];
    wire        e_swap  = (e_mode == 2'd3) || (e_omode == 2'd3);
    wire        e_oneshot_stop = (e_mode == 2'd1) && !e_repeat;

    // The push: this oscillator is ending, its control register asks for an
    // interrupt, and it does not already have one pending (doc_sound_end's
    // `if(rptr->has_irq_pending == 0)`).
    wire do_push = (sl == SL_END) && s_ctl[3] && (q_find == 6'd0) && (q_n < 6'd32);

    integer i, k;

    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            for (i = 0; i < 32; i = i + 1) begin
                freq[i] <= 16'd0; vol[i] <= 8'd0; wptr[i] <= 8'd0;
                ctl[i] <= 8'h01;                  // doc_reset: all halted
                wsize[i] <= 8'd0; lastv[i] <= 8'd0;
                acc[i] <= 24'd0; q_osc[i] <= 5'd0;
            end
            running <= 32'd0;
            sound_ctl <= 8'd0; saved <= 8'd0; ptr <= 16'd0;
            osc_en <= 6'd1;                       // g_doc_num_osc_en = 1
            q_n <= 6'd0; q_want <= 5'd0;
            nco <= 33'd0; slot <= 6'd0; sl <= SL_IDLE;
            snd_l <= 21'sd0; snd_r <= 21'sd0;
            mix_l <= 21'sd0; mix_r <= 21'sd0;
            s_osc <= 5'd0; s_ws <= 8'd0; s_vol <= 8'd0; s_ctl <= 8'd0;
            s_wp <= 8'd0; s_freq <= 16'd0; s_acc <= 24'd0;
            b_addr <= 16'd0; e_repeat <= 1'b0;
            cnt_ends <= 8'd0; cnt_irqs <= 8'd0;
        end else begin
            // ---- the scan NCO ----------------------------------------------
            nco <= {1'b0, nco[31:0]} + {1'b0, SCAN_INC};

            // ---- the machine's ops -----------------------------------------
            if (op_wr) begin
                case (op_lo)
                    8'h3C: sound_ctl <= op_wdata;
                    8'h3E: ptr[7:0]  <= op_wdata;
                    8'h3F: ptr[15:8] <= op_wdata;
                    default: ;
                endcase
            end
            if (wr_c03d) begin
                case (w_type)
                    3'd0: freq[w_osc][7:0]  <= op_wdata;
                    3'd1: freq[w_osc][15:8] <= op_wdata;
                    3'd2: vol[w_osc]        <= op_wdata;
                    3'd3: ;                          // the data register: read only
                    3'd4: wptr[w_osc]       <= op_wdata;
                    3'd5: ;                          // the control register, below
                    3'd6: wsize[w_osc]      <= op_wdata;
                    default:
                        // $E1 is the enable count: ((val & 0x3e) >> 1) + 1,
                        // floored at one (doc.c:951).  $E0 is read-only in
                        // practice and $E2 is the A/D.
                        if (w_osc == 5'd1)
                            osc_en <= {1'b0, op_wdata[5:1]} + 6'd1;
                endcase
            end
            // The pointer steps on either direction of $C03D when the control
            // register's auto-increment bit is set (doc_read/write_c03d).
            if ((wr_c03d || a_we || rd_c03d) && sound_ctl[5]) ptr <= ptr + 16'd1;
            // The one-access read delay.
            if (rd_c03d) saved <= fetch;

            // ---- the control register (doc_write_ctl_reg) -------------------
            if (ctl_wr) begin
                ctl[w_osc] <= op_wdata;
                q_want <= w_osc;                 // the removal, next clock
                if (new_halt) begin
                    running[w_osc] <= 1'b0;
                    // "don't clear acc if free-running"
                    if (old_mode != 2'd0) acc[w_osc] <= 24'd0;
                end else if (old_halt) begin
                    // Starting.  An oscillator past the enabled count cannot
                    // run: doc_start_sound halts it again instead.
                    if ({1'b0, w_osc} >= osc_en) begin
                        ctl[w_osc] <= op_wdata | 8'h01;
                    end else begin
                        running[w_osc] <= 1'b1;
                        acc[w_osc] <= 24'd0;
                        // Sync mode on an even oscillator starts its odd
                        // partner, if the partner is stopped in sync mode
                        // (ctl & 7 == 5).  doc_start_sound.
                        if ((op_wdata[2:1] == 2'd2) && (w_osc[0] == 1'b0) &&
                            ((ctl[w_part] & 8'h07) == 8'h05)) begin
                            ctl[w_part] <= ctl[w_part] & ~8'h01;
                            running[w_part] <= 1'b1;
                            acc[w_part] <= 24'd0;
                        end
                    end
                end
            end

            // ---- the interrupt queue ----------------------------------------
            // A control write removes this oscillator's pending interrupt
            // ("no matter what"), and a read of $E0 removes the head's.  Both
            // compact the queue, which is what keeps $E0 in ARRIVAL order.
            if (ctl_wr && (q_find != 6'd0)) begin
                for (k = 0; k < 31; k = k + 1)
                    if (k[5:0] >= (q_find - 6'd1)) q_osc[k] <= q_osc[k+1];
                q_n <= q_n - 6'd1;
            end else if (e0_rd) begin
                for (k = 0; k < 31; k = k + 1) q_osc[k] <= q_osc[k+1];
                q_n <= q_n - 6'd1;
            end else if (do_push) begin
                q_osc[q_n[4:0]] <= s_osc;
                q_n <= q_n + 6'd1;
                cnt_irqs <= cnt_irqs + 8'd1;
            end
            if (!ctl_wr) q_want <= s_osc;        // the slot's, for an end

            // ---- the slot ---------------------------------------------------
            case (sl)
                SL_IDLE: if (slot_tick) begin
                    // The chip services one oscillator a slot and spends two
                    // more on refresh, which is the "+2" in the rate.
                    if (slot + 6'd1 >= osc_en + 6'd2) begin
                        slot  <= 6'd0;
                        // A scan is complete: the mix is a whole sample.
                        snd_l <= mix_l; snd_r <= mix_r;
                        mix_l <= 21'sd0; mix_r <= 21'sd0;
                    end else begin
                        slot <= slot + 6'd1;
                    end
                    if ((slot < osc_en) && running[slot[4:0]]) begin
                        s_osc  <= slot[4:0];
                        s_ws   <= wsize[slot[4:0]];
                        s_vol  <= vol[slot[4:0]];
                        s_ctl  <= ctl[slot[4:0]];
                        s_wp   <= wptr[slot[4:0]];
                        s_freq <= freq[slot[4:0]];
                        s_acc  <= acc[slot[4:0]];
                        sl     <= SL_ADDR;
                    end
                end
                SL_ADDR: begin b_addr <= s_addr; sl <= SL_WAIT; end
                SL_WAIT: sl <= SL_APPLY;
                SL_APPLY: begin
                    // The byte is played first and the accumulator advances
                    // after, which is the order doc_play reads them in.  This
                    // state only DECIDES; doc_sound_end is the next one.
                    lastv[s_osc] <= b_q;
                    if (b_q == 8'd0) begin
                        // The wavetable's terminator: can_repeat = 0.  No
                        // sound is produced for it.
                        e_repeat <= 1'b0;
                        sl <= SL_END;
                    end else begin
                        if (s_ctl[4]) mix_r <= mix_r + {{3{contrib[17]}}, contrib};
                        else          mix_l <= mix_l + {{3{contrib[17]}}, contrib};
                        if (acc_next >= a_end) begin
                            // Played to the table's end: can_repeat = 1.
                            e_repeat <= 1'b1;
                            sl <= SL_END;
                        end else begin
                            acc[s_osc] <= acc_next[23:0];
                            sl <= SL_IDLE;
                        end
                    end
                end
                SL_END: begin
                    // ---- doc_sound_end ------------------------------------
                    // The accumulator is reset whatever happens next, and the
                    // interrupt (if this oscillator asked for one) is pushed
                    // by the queue block above on this same clock.
                    sl <= SL_IDLE;
                    acc[s_osc] <= 24'd0;
                    cnt_ends <= cnt_ends + 8'd1;
                    if ((e_mode == 2'd0) && e_repeat) begin
                        // Free-running with no zero byte: go again.  This is
                        // how a held note is made, and it does NOT halt.
                        running[s_osc] <= 1'b1;
                    end else if (e_swap) begin
                        // Swap: either of the pair being in swap mode makes
                        // the PAIR swap (doc.c:311, Ian Schmidt).  Hand over
                        // to the partner - unless we are one-shot and hit a
                        // zero byte, where Olivier Goguel says just stop.
                        running[s_osc] <= 1'b0;
                        ctl[s_osc] <= s_ctl | 8'h01;
                        if (!e_oneshot_stop && !running[e_part] && ctl[e_part][0]) begin
                            ctl[e_part] <= ctl[e_part] & ~8'h01;
                            running[e_part] <= 1'b1;
                            acc[e_part] <= 24'd0;
                        end
                    end else begin
                        running[s_osc] <= 1'b0;
                        ctl[s_osc] <= s_ctl | 8'h01;
                    end
                end
                default: sl <= SL_IDLE;
            endcase
        end
    end

endmodule
