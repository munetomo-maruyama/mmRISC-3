//---------------------------------------------------------------------------
// OOO_FIQ.sv
//
// The FP issue queue of the renamed FPU (step 1.8 U1, Plan/OOC.md 29.80, 29.81):
// 12 entries, 4 µops written a cycle, 2 issued a cycle.
//   port A   the FPU (OOO_FPUW): every FP operation, the FP -> integer ones, divide
//            and square root; only when fpu_ok (no divide in the FPU or ahead of it,
//            no int -> FP µop waiting for the FPU's input), an FP -> integer one only
//            when f2i_ok as well (its FIFO will have room)
//   port B   an FP store's data (source 0), to the SQ through the FP file's 4th read
//            port (OOO_LSU4's second data port)
// Each port takes the oldest of its requests, by an age matrix (OOO_IQ3's), and the
// selection and the wakeup close in one cycle as there. The entries are in 4 banks of
// 3 written as OOO_IQ3's are (a cycle's µops to different banks, each to the first
// free entry of its bank; disp_cand early, disp_valid late), and a new entry's age row
// the same.
//
// Unlike OOO_IQ3 this queue makes no wakeup of its own: every FP result's tag comes on
// the external buses, at the cycle its dependents may issue the cycle after (OOO_FPUW's
// fixed latency and its divide, the load ports' FP loads: the integrator's timing).
// What travels with a µop and is not the queue's business (the FPU's operation and
// format, the rounding mode, the ROB index, an integer destination, an SQ index) is
// the payload, PLW bits, written with the entry and given out with its issue.
//
// kill, clr, flush as in OOO_IQ3: a killed entry leaves, a resolved checkpoint's bit
// is cleared, flush empties the queue; ia_bm / ib_bm without this cycle's clr, and an
// issue in a cycle that kills it is the unit's to drop.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FIQ
    #(
        parameter int N     = 12,
        parameter int TAGW  = 6,     // FP physical registers: 64
        parameter int NEXT  = 4,     // wakeup buses
        parameter int NCK   = 12,
        parameter int NBANK = 4,
        parameter int PLW   = 32     // the payload
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,
        input  logic                  flush,
        input  logic [NCK-1:0]        kill,
        input  logic [NCK-1:0]        clr,
        input  logic                  fpu_ok,     // port A may issue
        input  logic                  f2i_ok,     // ... an FP -> integer µop too

        // dispatch: up to 4 µops a cycle, in program order (0 the oldest)
        output logic [2:0]            disp_ready,
        input  logic [3:0]            disp_valid,
        input  logic [3:0]            disp_cand,
        input  logic [3:0][2:0]       disp_use,   // the FP sources it reads (a store's data: source 0)
        input  logic [3:0][2:0][TAGW-1:0] disp_src,
        input  logic [3:0][2:0]       disp_rdy,   // already ready at rename
        input  logic [3:0]            disp_wr,    // it writes an FP register
        input  logic [3:0][TAGW-1:0]  disp_dst,
        input  logic [3:0][NCK-1:0]   disp_bm,
        input  logic [3:0]            disp_sd,    // an FP store's data (port B)
        input  logic [3:0]            disp_dv,    // a divide / square root
        input  logic [3:0]            disp_f2i,   // its result goes to an integer register
        input  logic [3:0][PLW-1:0]   disp_pl,

        // wakeups
        input  logic [NEXT-1:0]           ext_valid,
        input  logic [NEXT-1:0][TAGW-1:0] ext_tag,

        // port A: the FPU
        output logic                  ia_valid,
        output logic [2:0][TAGW-1:0]  ia_src,
        output logic                  ia_wr,
        output logic [TAGW-1:0]       ia_dst,
        output logic [NCK-1:0]        ia_bm,
        output logic                  ia_dv,
        output logic                  ia_f2i,
        output logic [PLW-1:0]        ia_pl,

        // port B: a store's data
        output logic                  ib_valid,
        output logic [TAGW-1:0]       ib_src,
        output logic [NCK-1:0]        ib_bm,
        output logic [PLW-1:0]        ib_pl
    );

    localparam int EW = $clog2(N);
    localparam int BS = N / NBANK;

    logic [N-1:0]                 v;
    logic [2:0]                   use_s [N];
    logic [2:0][TAGW-1:0]         src   [N];
    logic [2:0]                   rdy   [N];
    logic [N-1:0]                 wr, sd, dv, f2i;
    logic [TAGW-1:0]              dst   [N];
    logic [N-1:0]                 older [N];
    logic [NCK-1:0]               bm    [N];
    logic [PLW-1:0]               pl    [N];

    function automatic logic [N-1:0] oldest(input logic [N-1:0] r);
        logic [N-1:0] g;
        for (int i = 0; i < N; i++) g[i] = r[i] && ((r & older[i]) == '0);
        return g;
    endfunction

    function automatic logic woken(input logic [TAGW-1:0] t);
        logic w;
        w = 1'b0;
        for (int b = 0; b < NEXT; b++) if (ext_valid[b] && ext_tag[b] == t) w = 1'b1;
        return w;
    endfunction

    // ---- select
    logic [N-1:0] ra, rb, ga, gb;
    always @(*) begin
        for (int i = 0; i < N; i++) begin
            automatic logic ok = (rdy[i] | ~use_s[i]) == 3'b111;
            ra[i] = v[i] && ok && !sd[i] && fpu_ok && (!f2i[i] || f2i_ok);
            rb[i] = v[i] && ok && sd[i];
        end
        ga = oldest(ra);
        gb = oldest(rb);
    end

    always @(*) begin
        ia_valid = |ga;
        ib_valid = |gb;
        ia_src = '0; ia_dst = '0; ia_bm = '0; ia_pl = '0;
        ib_src = '0; ib_bm = '0; ib_pl = '0;
        ia_wr  = |(ga & wr);
        ia_dv  = |(ga & dv);
        ia_f2i = |(ga & f2i);
        for (int i = 0; i < N; i++) begin
            ia_src = ia_src | ({3*TAGW{ga[i]}} & src[i]);
            ia_dst = ia_dst | ({TAGW{ga[i]}} & dst[i]);
            ia_bm  = ia_bm  | ({NCK{ga[i]}} & bm[i]);
            ia_pl  = ia_pl  | ({PLW{ga[i]}} & pl[i]);
            ib_src = ib_src | ({TAGW{gb[i]}} & src[i][0]);
            ib_bm  = ib_bm  | ({NCK{gb[i]}} & bm[i]);
            ib_pl  = ib_pl  | ({PLW{gb[i]}} & pl[i]);
        end
    end

    logic [N-1:0] left;
    assign left = ga | gb;

    // ---- free entries for dispatch (OOO_IQ3's)
    logic [NBANK-1:0]        bf;
    logic [EW-1:0]           be [NBANK];
    logic [1:0]              bs [NBANK];
    logic [NBANK-1:0]        bg;
    logic [1:0]              sl [4];
    logic [2:0]              nv;
    logic [1:0]              br [NBANK];
    always @(*) begin
        automatic logic [2:0] n = 3'd0;
        for (int b = 0; b < NBANK; b++) begin
            bf[b] = 1'b0;
            be[b] = '0;
            for (int i = BS - 1; i >= 0; i--) if (!v[b*BS + i]) begin bf[b] = 1'b1; be[b] = EW'(b*BS + i); end
            br[b] = n[1:0];
            if (bf[b]) n = n + 3'd1;
        end
        disp_ready = n;
    end
    always @(*) begin
        nv = 3'd0;
        for (int k = 0; k < 4; k++) sl[k] = 2'd0;
        for (int k = 0; k < 4; k++) if (disp_cand[k]) begin
            sl[nv[1:0]] = 2'(k);
            nv = nv + 3'd1;
        end
        for (int b = 0; b < NBANK; b++) begin
            bs[b] = sl[br[b]];
            bg[b] = bf[b] && 3'(br[b]) < nv;
        end
    end

    logic [NBANK-1:0]    bw;
    logic [N-1:0]        dany;
    logic [N-1:0]        dafter [NBANK];
    logic [3:0][2:0]     dwk;
    always @(*) begin
        for (int d = 0; d < 4; d++)
            for (int s = 0; s < 3; s++) dwk[d][s] = disp_rdy[d][s] || woken(disp_src[d][s]);
        dany = '0;
        for (int b = 0; b < NBANK; b++) begin
            bw[b] = bg[b] && disp_valid[bs[b]];
            for (int i = 0; i < N; i++) if (bw[b] && be[b] == EW'(i)) dany[i] = 1'b1;
        end
        for (int b = 0; b < NBANK; b++) begin
            dafter[b] = '0;
            for (int o = 0; o < NBANK; o++)
                if (bs[o] > bs[b]) for (int i = 0; i < BS; i++) dafter[b][o*BS + i] = dany[o*BS + i];
        end
    end

    // the fields of a bank's slot
    logic [2:0]           b_use [NBANK], b_rdy [NBANK];
    logic [2:0][TAGW-1:0] b_src [NBANK];
    logic                 b_wr [NBANK], b_sd [NBANK], b_dv [NBANK], b_f2i [NBANK];
    logic [TAGW-1:0]      b_dst [NBANK];
    logic [NCK-1:0]       b_bm  [NBANK];
    logic [PLW-1:0]       b_pl  [NBANK];
    always @(*) begin
        for (int b = 0; b < NBANK; b++) begin
            automatic logic [1:0] k = bs[b];
            b_use[b] = disp_use[k];
            b_rdy[b] = dwk[k];
            b_src[b] = disp_src[k];
            b_wr[b]  = disp_wr[k];
            b_sd[b]  = disp_sd[k];
            b_dv[b]  = disp_dv[k];
            b_f2i[b] = disp_f2i[k];
            b_dst[b] = disp_dst[k];
            b_bm[b]  = disp_bm[k];
            b_pl[b]  = disp_pl[k];
        end
    end

    for (genvar i = 0; i < N; i++) begin : g_ent
        localparam int B = i / BS;
        logic                 vq, wq, sq_, dq_, fq;
        logic [2:0]           uq, rq;
        logic [2:0][TAGW-1:0] srq;
        logic [TAGW-1:0]      dsq;
        logic [N-1:0]         oq;
        logic [NCK-1:0]       bq;
        logic [PLW-1:0]       pq;
        assign v[i]     = vq;
        assign use_s[i] = uq;
        assign src[i]   = srq;
        assign rdy[i]   = rq;
        assign wr[i]    = wq;
        assign sd[i]    = sq_;
        assign dv[i]    = dq_;
        assign f2i[i]   = fq;
        assign dst[i]   = dsq;
        assign older[i] = oq;
        assign bm[i]    = bq;
        assign pl[i]    = pq;

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n)                              vq <= 1'b0;
            else if (flush)                          vq <= 1'b0;
            else if (dany[i])                        vq <= 1'b1;
            else if (left[i] || (bq & kill) != '0)   vq <= 1'b0;
        end
        always_ff @(posedge clk) begin
            if (dany[i]) begin
                uq  <= b_use[B];
                srq <= b_src[B];
                rq  <= b_rdy[B];
                wq  <= b_wr[B];
                sq_ <= b_sd[B];
                dq_ <= b_dv[B];
                fq  <= b_f2i[B];
                dsq <= b_dst[B];
                bq  <= b_bm[B];
                pq  <= b_pl[B];
                oq  <= ~dafter[B];
                oq[i] <= 1'b0;
            end else begin
                bq <= bq & ~clr;
                for (int s = 0; s < 3; s++) if (woken(srq[s])) rq[s] <= 1'b1;
                oq <= oq & ~dany;
            end
        end
    end

endmodule : OOO_FIQ
