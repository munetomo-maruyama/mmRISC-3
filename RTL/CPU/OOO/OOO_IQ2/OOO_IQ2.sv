//---------------------------------------------------------------------------
// OOO_IQ2.sv
//
// The issue queue of the 4-wide core at 50 MHz (Doc/STRATEGY.md 4.2, 4.5 loop 1):
// unified, 24 entries, 4 µops written a cycle, 6 issued a cycle:
//   port 0     ALU0 (the full ALU; MUL / DIV and the operations ALUF does not
//              have, which only go here)
//   port 1..3  ALU1..3 (OOO_ALUF: "any ALU" µops)
//   port 4     LSU0 (loads; stores and everything non-speculative only here)
//   port 5     LSU1 (loads only, one source)
// As in OOO_IQ the selection and the wakeup close in one cycle: ready bits,
// requests, oldest first by an age matrix, the issued µops' destination tags,
// a compare against every source, ready bits. What is new against OOO_IQ:
//
// The ALU ports do not select one after another: a chain of 4 selects took 15.4 of the
// 21 ns the first version reached (Plan/OOC.md 29.2). Every any-ALU µop counts the ready
// any-ALU µops older than it, saturating at 4, in a tree of 4 LUT levels (rank): 0 goes
// to port 3, 1 to port 2, 2 to port 1, 3 to port 0, so a port's grant does not depend on
// another's. Port 0 also takes what only ALU0 can: the oldest such µop goes when at most 3
// any-ALU µops are older than it (those go to ports 3, 2, 1), an any-ALU µop of rank 3 when
// no such µop is older than it. A µop a write slot holds back keeps its rank: its port
// idles for that cycle, and a younger one does not pass it to that port.
// NA = 2, P5 = 0: today's 2-wide core with this queue (Plan/OOC.md 29.18): ports 2, 3 and 5
// give nothing, rank 0 goes to port 1 and rank 1 to port 0, as OOO_IQ's ports 1 and 0 did.
//
// Port 5 selects, then port 4 from what is left, so that a load does not keep LSU0 from
// a store: these 2 are a chain, as a load's wakeup comes a cycle later, off the loop.
//
// Entries are in 4 banks of 6, so that the payload can be 4 LUT RAMs each written by
// one µop (OOO_IQPL's way): a cycle's µops go to different banks, each to the first
// free entry of its bank. The valid slots need not be a prefix (the DS register keeps what
// did not go in its slot), but no more than disp_ready of them. There is no search of 24 for 4, and it costs -0.1 % in the
// model (iq_bank). The fields of a slot go to its bank on one bus, 4 to 1 for the bank, not
// for each entry of it. The banks are given by disp_cand, the slots that go if any do (the
// DS register's, early: dispatch is all of them or none), and written by disp_valid, which
// is late (the go; Plan/OOC.md 29.41): so disp_entry and the payload's buses do not wait
// for the go.
//
// A new entry's age row is all ones but for what is written after it in the same
// cycle: the bits of empty entries do not count, as an empty entry requests nothing.
// So the row does not depend on the select. An entry written later clears its bit.
//
// Wakeup: 7 + NEXT tag buses:
//   port 0..3 now      latency 1 (port 0: what is not of latency 2)
//   port 0 delayed     a multiply, a cycle after its issue
//   port 4, 5 delayed  a load, a cycle after its issue
//   external           NEXT
// A multiply writes through port 1's write slot (OOO_IQ's way): a µop that writes in
// the latency-1 slot is not given port 1 in the cycle after a multiply; ports 2, 3
// and 0 can take it. A result of the MDU is written through port 0's (p0_hold).
//
// The rest is as in OOO_IQ, which has the reasons: a load is guessed to hit; kill,
// clr, flush; iss_bm without this cycle's clr; non-speculative µops at the ROB head,
// one at a time; a load waits while an older store is in the queue.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_IQ2
    #(
        parameter int N     = 24,
        parameter int TAGW  = 7,     // physical registers: 80
        parameter int NEXT  = 2,     // external wakeup ports
        parameter int NCK   = 12,    // checkpoints (branch-mask bits)
        parameter int NBANK = 4,     // N is a multiple of it
        parameter int NA    = 4,     // ALU ports in use: 4, or 2 (ports 0, 1)
        parameter bit P5    = 1'b1   // port 5 in use
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,
        input  logic                  flush,      // flush_all: empty the queue
        input  logic [NCK-1:0]        kill,       // a restored checkpoint: its µops leave (one-hot)
        input  logic [NCK-1:0]        clr,        // checkpoints resolved as predicted
        input  logic                  ns_ok,      // the ROB head is a non-speculative µop not run yet
        input  logic                  mdu_ok,     // an MDU µop may issue now
        input  logic                  p0_hold,    // a result of the MDU waits for port 0's write

        // dispatch: up to 4 µops a cycle, in program order (0 the oldest)
        output logic [2:0]            disp_ready, // room for this many
        output logic [3:0][$clog2(N)-1:0] disp_entry, // the entries they go to (for the payload)
        input  logic [3:0]            disp_valid, // oldest in the lowest slot, gaps allowed
        input  logic [3:0]            disp_cand,  // the slots that go if any do: disp_valid is these or none
        input  logic [3:0][1:0]       disp_port,  // 0 any ALU, 1 ALU0 only, 2 LSU
        input  logic [3:0][1:0]       disp_use,   // the sources the µop reads
        input  logic [3:0][1:0][TAGW-1:0] disp_src,
        input  logic [3:0][1:0]       disp_rdy,   // already ready at rename
        input  logic [3:0]            disp_wr,    // it writes its destination
        input  logic [3:0][TAGW-1:0]  disp_dst,
        input  logic [3:0]            disp_lat2,  // results after 2 cycles (load, multiply)
        input  logic [3:0][NCK-1:0]   disp_bm,    // branch masks
        input  logic [3:0]            disp_ns,    // non-speculative: issued only at the ROB head
        input  logic [3:0]            disp_md,    // an MDU µop (port 0)
        input  logic [3:0]            disp_st,    // a store (port 2): younger loads wait for it to issue

        // external wakeups
        input  logic [NEXT-1:0]           ext_valid,
        input  logic [NEXT-1:0][TAGW-1:0] ext_tag,

        // issue
        output logic [5:0]            iss_valid,
        output logic [5:0][$clog2(N)-1:0] iss_entry,
        output logic [5:0][1:0][TAGW-1:0] iss_src,
        output logic [5:0]            iss_wr,
        output logic [5:0][TAGW-1:0]  iss_dst,
        output logic [5:0][NCK-1:0]   iss_bm,     // the issued µops' branch masks (for the units)
        output logic                  iss_ns,     // a non-speculative µop issued now
        output logic                  iss_md,     // port 0 issued an MDU µop

        // the wakeup tags of this cycle (renaming's busy bits, the DS register)
        output logic [6+NEXT:0]       wk_valid,
        output logic [6+NEXT:0][TAGW-1:0] wk_tag
    );

    localparam int EW = $clog2(N);
    localparam int NB = 7 + NEXT;    // broadcast tags (above)
    localparam int BS = N / NBANK;   // entries in a bank

    // per entry; arrays (not packed vectors) where an entry is chosen at run time
    logic [N-1:0]                 v;
    logic [N-1:0]                 lat2;
    logic [1:0]                   port  [N];
    logic [1:0]                   use_s [N];
    logic [1:0][TAGW-1:0]         src   [N];
    logic [1:0]                   rdy   [N];
    logic [N-1:0]                 wr;
    logic [TAGW-1:0]              dst   [N];
    logic [N-1:0]                 older [N];  // older[i][j]: entry j is older than entry i
    logic [NCK-1:0]               bm    [N];  // branch mask
    logic [N-1:0]                 ns;         // non-speculative
    logic [N-1:0]                 md;         // an MDU µop
    logic [N-1:0]                 st;         // a store
    logic [N-1:0]                 sw;         // a load an older store holds back
    logic [N-1:0]                 nw;         // a non-speculative µop an older one holds back
    logic                         blk0, blk1; // port 0's / port 1's latency-1 write slot is taken

    // ---- select
    function automatic logic [N-1:0] oldest(input logic [N-1:0] r);
        logic [N-1:0] g;
        for (int i = 0; i < N; i++) g[i] = r[i] && ((r & older[i]) == '0);
        return g;
    endfunction

    // how many of x, as far as 4: 3 at a time, then pairs of sums
    function automatic logic [2:0] sat_add(input logic [2:0] p, input logic [2:0] q);
        logic [3:0] s;
        s = 4'(p) + 4'(q);
        return s >= 4'd4 ? 3'd4 : s[2:0];
    endfunction
    function automatic logic [2:0] count4(input logic [N-1:0] x);
        logic [2:0] c [N];
        automatic int n = (N + 2) / 3;
        for (int k = 0; k < n; k++) begin
            logic [2:0] b;
            b = '0;
            for (int j = 3 * k; j < 3 * k + 3 && j < N; j++) b[j - 3 * k] = x[j];
            c[k] = 3'(b[0]) + 3'(b[1]) + 3'(b[2]);
        end
        while (n > 1) begin
            for (int k = 0; k < n / 2; k++) c[k] = sat_add(c[2 * k], c[2 * k + 1]);
            if (n % 2 == 1) c[n / 2] = c[n - 1];
            n = (n + 1) / 2;
        end
        return c[0];
    endfunction

    logic [N-1:0] ready_all, anyalu, only0, ld, mem, g [6];
    logic [2:0]   rank [N];                   // any-ALU µops older than this one, as far as 4
    always @(*) begin
        for (int i = 0; i < N; i++) begin
            // (the waits for older entries are registers, off the
            // wakeup-select loop)
            ready_all[i] = v[i] && ((rdy[i] | ~use_s[i]) == 2'b11) &&
                           (!ns[i] || ns_ok) && !nw[i] && !sw[i];
            anyalu[i] = ready_all[i] && port[i] == 2'd0;
            only0[i]  = ready_all[i] && port[i] == 2'd1 &&
                        !(blk0 && wr[i] && !lat2[i] && !md[i]) && !(md[i] && !mdu_ok);
            mem[i]    = ready_all[i] && port[i] == 2'd2;
            ld[i]     = mem[i] && !st[i] && !ns[i];
        end
        for (int i = 0; i < N; i++) begin
            automatic logic no_only0 = (only0 & older[i]) == '0;
            rank[i] = count4(anyalu & older[i]);
            g[3][i] = NA == 4 && anyalu[i] && rank[i] == 3'd0;
            g[2][i] = NA == 4 && anyalu[i] && rank[i] == 3'd1;
            g[1][i] = anyalu[i] && rank[i] == 3'(NA - 2) && !(blk1 && wr[i]);
            g[0][i] = no_only0 && ((anyalu[i] && rank[i] == 3'(NA - 1) && !(blk0 && wr[i])) ||
                                   (only0[i] && rank[i] <= 3'(NA - 1)));
        end
        g[5] = P5 ? oldest(ld) : '0;
        g[4] = oldest(mem & ~g[5]);
    end

    function automatic logic [EW-1:0] enc(input logic [N-1:0] x);
        logic [EW-1:0] e;
        e = '0;
        for (int i = 0; i < N; i++) if (x[i]) e = e | EW'(i);
        return e;
    endfunction

    // the issued µops, by an AND-OR of the grants (one-hot); only port 0
    // issues both latencies
    logic lat2_0;
    assign lat2_0 = |(g[0] & lat2);
    always @(*) begin
        for (int p = 0; p < 6; p++) begin
            iss_valid[p] = |g[p];
            iss_entry[p] = enc(g[p]);
            iss_src[p]   = '0;
            iss_dst[p]   = '0;
            iss_bm[p]    = '0;
            iss_wr[p]    = |(g[p] & wr);
            for (int i = 0; i < N; i++) begin
                iss_src[p] = iss_src[p] | ({2*TAGW{g[p][i]}} & src[i]);
                iss_dst[p] = iss_dst[p] | ({TAGW{g[p][i]}} & dst[i]);
                iss_bm[p]  = iss_bm[p]  | ({NCK{g[p][i]}}  & bm[i]);
            end
        end
    end

    logic [N-1:0] issued;
    assign issued = g[0] | g[1] | g[2] | g[3] | g[4] | g[5];
    assign iss_ns = (issued & ns) != '0;
    assign iss_md = (g[0] & md) != '0;

    // ---- wakeup tags: the µops issued now with latency 1, those issued one
    // cycle ago with latency 2, and the external ones
    logic                 d_v0, d_v4, d_v5;
    logic [TAGW-1:0]      d_t0, d_t4, d_t5;
    logic [NB-1:0]        bv;
    logic [NB-1:0][TAGW-1:0] bt;
    always @(*) begin
        bv[0] = iss_wr[0] && !lat2_0;       bt[0] = iss_dst[0];
        bv[1] = iss_wr[1];                  bt[1] = iss_dst[1];
        bv[2] = iss_wr[2];                  bt[2] = iss_dst[2];
        bv[3] = iss_wr[3];                  bt[3] = iss_dst[3];
        bv[4] = d_v0;                       bt[4] = d_t0;
        bv[5] = d_v4;                       bt[5] = d_t4;
        bv[6] = d_v5;                       bt[6] = d_t5;
        for (int e = 0; e < NEXT; e++) begin
            bv[7+e] = ext_valid[e];
            bt[7+e] = ext_tag[e];
        end
    end

    assign wk_valid = bv;
    assign wk_tag   = bt;

    function automatic logic woken(input logic [TAGW-1:0] t);
        logic w;
        w = 1'b0;
        for (int b = 0; b < NB; b++) if (bv[b] && bt[b] == t) w = 1'b1;
        return w;
    endfunction

    // the latency-2 results issued now wake their dependents next cycle,
    // unless the µop is killed or flushed now
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_v0 <= 1'b0;
            d_v4 <= 1'b0;
            d_v5 <= 1'b0;
        end else begin
            d_v0 <= iss_wr[0] && lat2_0 && !flush && (iss_bm[0] & kill) == '0;
            d_v4 <= iss_wr[4] && !flush && (iss_bm[4] & kill) == '0;
            d_v5 <= iss_wr[5] && !flush && (iss_bm[5] & kill) == '0;
        end
    end
    always_ff @(posedge clk) begin
        d_t0 <= iss_dst[0];
        d_t4 <= iss_dst[4];
        d_t5 <= iss_dst[5];
    end
    // the latency-1 write slots: port 1's the multiply of the cycle before
    // has, port 0's a result of the MDU waiting for it
    assign blk0 = p0_hold;
    assign blk1 = d_v0;

    // ---- free entries for dispatch: the first of each bank; the k-th valid slot takes
    // the k-th bank with room
    logic [NBANK-1:0]        bf;      // the bank has room
    logic [EW-1:0]           be [NBANK];   // ... this entry first
    logic [1:0]              bs [NBANK];   // the slot of the bank
    logic [NBANK-1:0]        bg;      // ... and takes a µop
    logic [3:0][EW-1:0]      fe;      // the entry each dispatched µop goes to
    logic [1:0]              sl [4];  // the k-th valid slot
    logic [2:0]              nv;
    logic [1:0]              br [NBANK];   // the rank of a bank among those with room
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
    // (apart: disp_ready does not depend on what goes, which depends on it)
    always @(*) begin
        nv = 3'd0;
        for (int k = 0; k < 4; k++) sl[k] = 2'd0;
        for (int k = 0; k < 4; k++) if (disp_cand[k]) begin
            sl[nv[1:0]] = 2'(k);
            nv = nv + 3'd1;
        end
        fe = '0;
        for (int b = 0; b < NBANK; b++) begin
            bs[b] = sl[br[b]];
            bg[b] = bf[b] && 3'(br[b]) < nv;
            if (bg[b]) fe[bs[b]] = be[b];
        end
        disp_entry = fe;
    end

    // which entries are written this cycle; the sources of the slots against the tags
    logic [NBANK-1:0]    bw;          // the bank is written
    logic [N-1:0]        dany;
    logic [N-1:0]        dafter [NBANK];  // written after this bank's slot, in the same cycle
    logic [N-1:0]        st_stay, ns_stay;
    logic [3:0]          dst_older, dns_older;   // an earlier slot writes a store (non-speculative µop)
    logic [3:0][1:0]     dwk;
    always @(*) begin
        for (int d = 0; d < 4; d++)
            for (int s = 0; s < 2; s++) dwk[d][s] = disp_rdy[d][s] || woken(disp_src[d][s]);
        dany = '0;
        for (int b = 0; b < NBANK; b++) begin
            bw[b] = bg[b] && disp_valid[bs[b]];    // (flush wins at the valid bit)
            for (int i = 0; i < N; i++) if (bw[b] && be[b] == EW'(i)) dany[i] = 1'b1;
        end
        for (int b = 0; b < NBANK; b++) begin
            dafter[b] = '0;
            for (int o = 0; o < NBANK; o++)
                if (bs[o] > bs[b]) for (int i = 0; i < BS; i++) dafter[b][o*BS + i] = dany[o*BS + i];
        end
        dst_older[0] = 1'b0;
        dns_older[0] = 1'b0;
        for (int d = 1; d < 4; d++) begin
            dst_older[d] = dst_older[d-1] || (disp_valid[d-1] && disp_st[d-1]);
            dns_older[d] = dns_older[d-1] || (disp_valid[d-1] && disp_ns[d-1]);
        end
        // the stores (non-speculative µops) still in the queue next cycle for the
        // loads (non-speculative µops) that wait: a killed one needs no term,
        // since the entries younger than it die with it (they carry its mask bit)
        // and nothing is dispatched in a kill cycle (OOO_CTRL's d_ok)
        st_stay = v & st & ~issued;
        ns_stay = v & ns & ~issued;
    end

    // the fields of a bank's slot, on one bus for its entries
    logic [1:0]           b_port [NBANK], b_use [NBANK], b_rdy [NBANK];
    logic [1:0][TAGW-1:0] b_src  [NBANK];
    logic                 b_wr   [NBANK], b_lat2 [NBANK], b_ns [NBANK], b_md [NBANK], b_st [NBANK];
    logic [TAGW-1:0]      b_dst  [NBANK];
    logic [NCK-1:0]       b_bm   [NBANK];
    logic                 b_wt   [NBANK], b_wn [NBANK];
    always @(*) begin
        for (int b = 0; b < NBANK; b++) begin
            automatic logic [1:0] k = bs[b];
            b_port[b] = disp_port[k];
            b_use[b]  = disp_use[k];
            b_rdy[b]  = dwk[k];
            b_src[b]  = disp_src[k];
            b_wr[b]   = disp_wr[k];
            b_lat2[b] = disp_lat2[k];
            b_ns[b]   = disp_ns[k];
            b_md[b]   = disp_md[k];
            b_st[b]   = disp_st[k];
            b_dst[b]  = disp_dst[k];
            b_bm[b]   = disp_bm[k];
            // a load waits while an older store is in the queue: every
            // store that stays, and those of the group before it
            b_wt[b]   = disp_port[k] == 2'd2 && !disp_st[k] && (st_stay != '0 || dst_older[k]);
            // a non-speculative µop the same for an older one
            b_wn[b]   = disp_ns[k] && (ns_stay != '0 || dns_older[k]);
        end
    end

    // every entry keeps its own fields
    for (genvar i = 0; i < N; i++) begin : g_ent
        localparam int B = i / BS;    // its bank
        logic                 vq, lq, wq;
        logic [1:0]           pq, uq, rq;
        logic [1:0][TAGW-1:0] sq;
        logic [TAGW-1:0]      dq;
        logic [N-1:0]         oq;
        logic [NCK-1:0]       bq;
        logic                 nq, mq, tq, wtq, wnq;
        assign v[i]     = vq;
        assign lat2[i]  = lq;
        assign port[i]  = pq;
        assign use_s[i] = uq;
        assign src[i]   = sq;
        assign rdy[i]   = rq;
        assign wr[i]    = wq;
        assign dst[i]   = dq;
        assign older[i] = oq;
        assign bm[i]    = bq;
        assign ns[i]    = nq;
        assign md[i]    = mq;
        assign st[i]    = tq;
        assign sw[i]    = wtq;
        assign nw[i]    = wnq;

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                vq <= 1'b0;
            end else if (flush) begin
                vq <= 1'b0;
            end else if (dany[i]) begin
                vq <= 1'b1;
            end else if (issued[i] || (bq & kill) != '0) begin
                vq <= 1'b0;
            end
        end
        always_ff @(posedge clk) begin
            if (dany[i]) begin
                pq  <= b_port[B];
                uq  <= b_use[B];
                sq  <= b_src[B];
                rq  <= b_rdy[B];
                wq  <= b_wr[B];
                dq  <= b_dst[B];
                lq  <= b_lat2[B];
                bq  <= b_bm[B];
                nq  <= b_ns[B];
                mq  <= b_md[B];
                tq  <= b_st[B];
                wtq <= b_wt[B];
                wnq <= b_wn[B];
                // age: younger than every entry but what is written after it
                oq <= ~dafter[B];
                oq[i] <= 1'b0;
            end else begin
                bq <= bq & ~clr;
                for (int s = 0; s < 2; s++) if (woken(sq[s])) rq[s] <= 1'b1;
                wtq <= wtq && (oq & st_stay) != '0;
                wnq <= wnq && (oq & ns_stay) != '0;
                // an entry written now is younger than this one
                oq <= oq & ~dany;
            end
        end
    end

endmodule : OOO_IQ2
