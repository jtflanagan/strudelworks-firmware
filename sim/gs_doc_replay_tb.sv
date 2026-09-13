`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//
// gs_doc_replay_tb - the Ensoniq fed the REGISTER STREAM A REAL MACHINE SENT IT.
//
// WHY THIS EXISTS.  sim/gs_doc_tb.sv proves the chip's BEHAVIOUR - oscillators
// start, halt, interrupt in arrival order, the wave RAM reads back - and it
// passes 25 checks while the card in the machine plays SILENCE.  Every one of
// those checks reads a register back.  Not one of them looks at snd_l/snd_r,
// which is the only thing the speaker ever hears, so the whole output path was
// untested (2026-09-13).
//
// The stimulus is not invented here.  sim/doc_work/docstream.hex is every
// $C03C-$C03F access the card served during a real boot of the FTA XMAS demo,
// in order, with its data byte, pulled out of a live bus capture
// (tools/swtrace, then the $C03x filter).  sim/doc_work is a work directory and
// the file is NOT in the repository; it is made from a capture of the running
// machine, which is the whole point of it:
//
//   (host)  tools/pi.sh trace boot.swbt --reset --seconds 25
//   (here)  python3 - <<'EOF'
//           import struct
//           d=open('boot.swbt','rb').read(); n=(len(d)-32)//8
//           w=struct.unpack('<%dQ'%n, d[32:32+8*n]); out=[]
//           for x in w:
//               if ((x>>28)&0xF) not in (0xF,0xC): continue
//               a=x&0xFFFF
//               if 0xC03C<=a<=0xC03F:
//                   out.append(f"{a&0xFF:02X} {(x>>16)&1} {(x>>56)&0xFF:02X}")
//           open('sim/doc_work/docstream.hex','w').write('\n'.join(out)+'\n')
//           EOF
//
// The machine that produced the one this was written against has
// twelve oscillators running at the end with real frequencies, real volumes
// and 41,338 non-silence bytes in its wave RAM - and produced no sound.  So
// the question this bench asks is the only one that matters: given exactly
// what the machine sent, does the chip put anything on its output?
//
// The ops are replayed back to back rather than at their original spacing.
// The register file's FINAL state is what decides whether an oscillator runs,
// and the accumulator is restarted on every start, so the end state is faithful
// even though the timing is compressed; the scan runs throughout.
module gs_doc_replay_tb;

    localparam int MAX_OPS = 200000;

    logic clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz, the card's control clock

    logic rst = 1'b1, res_sync = 1'b0;
    logic [7:0] op_lo = 8'd0, op_wdata = 8'd0;
    logic op_rw = 1'b0, act = 1'b0;
    wire [7:0] rd_byte;
    wire signed [20:0] snd_l, snd_r;
    wire irq;
    wire [7:0] cnt_ends, cnt_irqs;

    gs_doc u_doc (
        .clk (clk), .rst (rst), .res_sync (res_sync),
        .op_lo (op_lo), .op_rw (op_rw), .op_wdata (op_wdata), .act (act),
        .rd_byte (rd_byte),
        .snd_l (snd_l), .snd_r (snd_r),
        .irq (irq), .cnt_ends (cnt_ends), .cnt_irqs (cnt_irqs)
    );

    // The stream, as three parallel byte arrays: lo, rw, data.
    logic [7:0] s_lo   [0:MAX_OPS-1];
    logic [7:0] s_rw   [0:MAX_OPS-1];
    logic [7:0] s_data [0:MAX_OPS-1];
    int n_ops = 0;

    // Peak tracking on the output, sampled every clock.
    longint unsigned nz_l = 0, nz_r = 0;
    int signed peak_l = 0, peak_r = 0;
    int signed mn_l = 0, mn_r = 0;

    task automatic watch(input int clocks);
        for (int i = 0; i < clocks; i++) begin
            @(posedge clk);
            if (snd_l != 0) nz_l++;
            if (snd_r != 0) nz_r++;
            if (snd_l > peak_l) peak_l = snd_l;
            if (snd_r > peak_r) peak_r = snd_r;
            if (snd_l < mn_l) mn_l = snd_l;
            if (snd_r < mn_r) mn_r = snd_r;
        end
    endtask

    int gap = 3;
    int fd, code, a, b, c;
    int running_n;

    initial begin
        // ---- read the stream ------------------------------------------------
        fd = $fopen("sim/doc_work/docstream.hex", "r");
        if (fd == 0) begin
            $display("FAIL: cannot open sim/doc_work/docstream.hex");
            $finish;
        end
        while (n_ops < MAX_OPS) begin
            code = $fscanf(fd, "%h %d %h\n", a, b, c);
            if (code != 3) break;
            s_lo[n_ops]   = a[7:0];
            s_rw[n_ops]   = b[7:0];
            s_data[n_ops] = c[7:0];
            n_ops++;
        end
        $fclose(fd);
        if (!$value$plusargs("gap=%d", gap)) gap = 3;
        $display("replaying %0d DOC ops the card served on real hardware, gap %0d clocks", n_ops, gap);

        // ---- reset ----------------------------------------------------------
        repeat (4) @(posedge clk);
        rst = 1'b0; res_sync = 1'b1;
        repeat (4) @(posedge clk);

        // ---- replay ---------------------------------------------------------
        for (int i = 0; i < n_ops; i++) begin
            @(posedge clk);
            op_lo    <= s_lo[i];
            op_rw    <= s_rw[i][0];
            op_wdata <= s_data[i];
            act      <= 1'b1;
            @(posedge clk);
            act <= 1'b0;
            // The gap between ops.  A real machine spaces its DOC writes by
            // hundreds of clocks and the scan runs in between, so an
            // oscillator can start and reach the end of its table before the
            // next write arrives - a back-to-back replay would never see it.
            // +gap=N sets it; the default is the tight one.
            repeat (gap) @(posedge clk);
        end
        $display("stream replayed; cnt_ends=%0d cnt_irqs=%0d", cnt_ends, cnt_irqs);

        // How many oscillators does the chip think are running?
        running_n = 0;
        for (int o = 0; o < 32; o++)
            if (u_doc.running[o]) running_n++;
        $display("oscillators running in the chip: %0d of 32, osc_en=%0d",
                 running_n, u_doc.osc_en);
        for (int o = 0; o < 32; o++)
            if (u_doc.running[o])
                $display("   osc %0d: ctl=$%02h freq=%0d vol=%0d wp=$%02h wsize=$%02h acc=%0d",
                         o, u_doc.ctl[o], u_doc.freq[o], u_doc.vol[o],
                         u_doc.wptr[o], u_doc.wsize[o], u_doc.acc[o]);

        // ---- listen ---------------------------------------------------------
        // Long enough for many scans: a sample is (osc_en + 2) slots and a slot
        // is ~112 clocks, so 2,000,000 clocks is some hundreds of samples.
        watch(2000000);

        $display("");
        $display("output over the listening window:");
        $display("   snd_l: nonzero %0d clocks, max %0d, min %0d", nz_l, peak_l, mn_l);
        $display("   snd_r: nonzero %0d clocks, max %0d, min %0d", nz_r, peak_r, mn_r);
        if (nz_l == 0 && nz_r == 0)
            $display("VERDICT: SILENT - the chip produced nothing from a stream that should play");
        else
            $display("VERDICT: SOUND - the chip produces output, so the fault is downstream");
        $finish;
    end

endmodule
