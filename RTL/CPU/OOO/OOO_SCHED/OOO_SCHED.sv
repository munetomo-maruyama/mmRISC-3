//---------------------------------------------------------------------------
// OOO_SCHED.sv
//
// The distributed schedulers of the 4-issue core at 100 MHz (Doc/STRATEGY.md
// 4.2, 4.5 loop 1): NQ ALU queues of N entries and a memory queue of NM, one
// select each, up to W µops dispatched a cycle. Queue 0 alone takes the
// multiply, the MDU and the system µops. Dispatch is OOO_SDISP.
//
// The loop that decides the clock: a µop of latency 1 issued now lets its
// dependents, in any queue, issue in the next cycle. No tag travels in it
// (dependency matrix, Goshima et al., MICRO 2001; Plan/OOC.md 28.2, 28.3):
//   rv (entry can ask) -> select, oldest first -> grant -> clear of the
//   entry's column in every row -> no bit left in a row -> rv
// Every entry has a row with one wait bit per entry of all the queues: "I wait
// for that entry". The two sources of a µop share the row.
//
// A µop of latency L clears its column L - 1 cycles after its issue (sr) and
// keeps its entry until then: a column has one meaning at a time. Costs
// nothing in the model (Plan/model: hold=1). A µop whose result comes at an
// unknown time (disp_ext: MDU, AMO, LR, SC) keeps it until ext_* names it. So
// an entry is free when !oc, and can ask when rv. The write-back slots:
// each ALU queue has one register-file write port, so a µop of latency L is not
// selected if a µop already issued writes L cycles from now (rs), and in
// queue 0 no latency-1 writer with q0_hold (a result of the MDU waits).
//
// The order waits use the same cells: a load waits for the column of every
// older store not issued yet (Plan/CORE.md 5.9), and a non-speculative µop for
// that of every older one, in any queue (Plan/CORE.md 5.16). A store clears
// its column when it issues. A killed entry clears nothing: whoever waits for
// it is younger, and dies with it.
//
// Dispatch takes 2 cycles, S1 and S2 (OOO_SDISP). An entry's fields are written
// at the end of S1, its row at the end of S2; it can ask from the cycle after.
// The fields a queue cannot use are not there (localparams below); the slots
// keep to them: queues 1 .. NQ-1 latency 1 or 2; queue 0 latency 1, 2 or 4,
// external, non-speculative, MDU; the memory queue a store (latency 1), a
// load (3), external, non-speculative.
//
// Mispredictions (OOO_CTRL): as OOO_IQ. Each entry has its branch mask (bq);
// kill frees those with the bit, in S2 too, clr clears the bit in every mask.
// Nothing is dispatched in a kill cycle (OOO_CTRL's d_ok), that is, in S1;
// flush empties everything.
//
// The issue is seen a cycle later (rr_*, stage RR1), from the grants kept in a
// register, so the mask's AND-OR and the encoder hang off the loop. The entry
// keeps its fields through that cycle (it cannot be written before its end).
// The payload (the operation, the sources' tags) is not here: a LUTRAM per
// queue, written at disp_q / disp_e, read at rr_entry.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_SCHED
    #(
        parameter int NQ   = 3,      // ALU queues
        parameter int N    = 8,      // entries of an ALU queue (even)
        parameter int NM   = 12,     // entries of the memory queue (even)
        parameter int W    = 4,      // µops dispatched a cycle
        parameter int TAGW = 7,      // physical registers: 80
        parameter int NCK  = 12,     // checkpoints (branch-mask bits)
        parameter int NEXT = 2       // external results a cycle
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,
        input  logic                  flush,
        input  logic [NCK-1:0]        kill,
        input  logic [NCK-1:0]        clr,
        input  logic                  ns_ok,      // the ROB head is a non-speculative µop not run yet
        input  logic                  mdu_ok,     // an MDU µop may issue now
        input  logic                  q0_hold,    // a result of the MDU waits for queue 0's write port

        // dispatch (S1), in program order (0 the oldest), valid as a prefix
        input  logic [W-1:0]          disp_valid,
        input  logic [W-1:0][1:0]     disp_kind,  // 0 any ALU queue, 1 queue 0 only, 2 the memory queue
        input  logic [W-1:0][1:0]     disp_use,   // the sources the µop waits for
        input  logic [W-1:0][1:0][TAGW-1:0] disp_src,
        input  logic [W-1:0]          disp_wr,    // it writes its destination
        input  logic [W-1:0][TAGW-1:0] disp_dst,
        input  logic [W-1:0][1:0]     disp_lat,   // latency - 1
        input  logic [W-1:0]          disp_ext,   // its result comes on ext_* (disp_lat ignored)
        input  logic [W-1:0][NCK-1:0] disp_bm,    // branch mask
        input  logic [W-1:0]          disp_ns,    // non-speculative: only at the ROB head
        input  logic [W-1:0]          disp_md,    // an MDU µop (queue 0)
        input  logic [W-1:0]          disp_st,    // a store (memory queue): younger loads wait for its issue
        output logic [W-1:0]          disp_go,    // these go now
        output logic [W-1:0][$clog2(NQ+1)-1:0] disp_q,  // into this queue
        output logic [W-1:0][$clog2(N > NM ? N : NM)-1:0] disp_e,  // this entry of it

        // results that come at an unknown time: entry number over all queues
        input  logic [NEXT-1:0]       ext_valid,
        input  logic [NEXT-1:0][$clog2(NQ*N+NM)-1:0] ext_entry,

        // the issue of the last cycle, a queue each
        output logic [NQ:0]           rr_valid,
        output logic [NQ:0][$clog2(N > NM ? N : NM)-1:0] rr_entry,
        output logic [NQ:0][NCK-1:0]  rr_bm,
        output logic                  rr_ns,      // a non-speculative µop among them
        output logic                  rr_md       // an MDU µop among them
    );

    localparam int NE = NQ * N + NM;
    localparam int NB = 2 * (NQ + 1);
    localparam int LW = $clog2(N > NM ? N : NM);

    function automatic int q_of(input int e);
        return e < NQ * N ? e / N : NQ;
    endfunction
    function automatic int q_base(input int q);
        return q * N;
    endfunction
    function automatic int q_n(input int q);
        return q < NQ ? N : NM;
    endfunction
    function automatic int b_of(input int e);    // the bank of an entry
        return 2 * q_of(e) + (e - q_base(q_of(e))) % 2;
    endfunction

    // per entry
    logic [NE-1:0]           oc;         // occupied, the column not cleared yet
    logic [NE-1:0]           pw;         // a result pending
    logic [NE-1:0]           v;          // not issued yet
    logic [NE-1:0]           rv;         // not issued and nothing left to wait for
    logic [NE-1:0]           gq;         // issued in the last cycle
    logic [NE-1:0]           wrq;        // writes
    logic [NE-1:0]           l1q;        // latency 1 (clears at its issue)
    logic [NE-1:0]           l2q;        // latency 2
    logic [NE-1:0]           l3q;        // latency 3
    logic [NE-1:0]           l4q;        // latency 4
    logic [NE-1:0]           nsq, mdq, stq;
    logic [NE-1:0][TAGW-1:0] dq;
    logic [NCK-1:0]          bq [NE];
    logic [NE-1:0]           sr0;        // the column clears now, by latency
    logic [NE-1:0]           killed;     // the mask has a killed bit

    logic [NE-1:0]           g;          // grants
    logic [NE-1:0]           col;        // the entry's column clears now
    logic [NE-1:0]           wa;         // S1: the entry is taken now
    logic [NE-1:0]           w2;         // S2: the entry's row is written now
    logic                    nsb, mdb;   // an issue in the last cycle: ns_ok / mdu_ok have not seen it

    assign nsb   = rr_ns;
    assign mdb   = rr_md;

    always @(*) begin
        for (int e = 0; e < NE; e++) begin
            col[e] = (g[e] && l1q[e]) || sr0[e];
            for (int x = 0; x < NEXT; x++) if (ext_valid[x] && int'(ext_entry[x]) == e) col[e] = 1'b1;
        end
    end

    // ---- dispatch
    logic [NB-1:0][W-1:0] bsel;
    logic [NE-1:0]        pd [NB];
    OOO_SDISP #(.NQ(NQ), .N(N), .NM(NM), .W(W), .TAGW(TAGW)) u_disp
        (.clk(clk), .rst_n(rst_n), .flush(flush),
         .disp_valid(disp_valid), .disp_kind(disp_kind), .disp_use(disp_use), .disp_src(disp_src),
         .disp_wr(disp_wr), .disp_dst(disp_dst), .disp_ns(disp_ns), .disp_st(disp_st),
         .disp_go(disp_go), .disp_q(disp_q), .disp_e(disp_e),
         .oc(oc), .v(v), .pw(pw), .stq(stq), .nsq(nsq), .dq(dq), .col(col),
         .wa(wa), .bsel(bsel), .w2(w2), .pd(pd));

    // a bank's fields, from the slot it takes (one at most)
    logic [NB-1:0]           f_wr, f_l1, f_l2, f_l3, f_l4, f_ns, f_md, f_st;
    logic [TAGW-1:0]         f_dst [NB];
    logic [NCK-1:0]          f_bm  [NB];
    always @(*) begin
        for (int b = 0; b < NB; b++) begin
            f_wr[b] = 1'b0; f_l1[b] = 1'b0; f_l2[b] = 1'b0; f_l3[b] = 1'b0; f_l4[b] = 1'b0;
            f_ns[b] = 1'b0; f_md[b] = 1'b0; f_st[b] = 1'b0;
            f_dst[b] = '0; f_bm[b] = '0;
            for (int k = 0; k < W; k++) if (bsel[b][k]) begin
                f_wr[b]  = f_wr[b] | disp_wr[k];
                f_dst[b] = f_dst[b] | disp_dst[k];
                f_bm[b]  = f_bm[b] | disp_bm[k];
                f_ns[b]  = f_ns[b] | disp_ns[k];
                f_md[b]  = f_md[b] | disp_md[k];
                f_st[b]  = f_st[b] | disp_st[k];
                f_l1[b]  = f_l1[b] | (!disp_ext[k] && disp_lat[k] == 2'd0);
                f_l2[b]  = f_l2[b] | (!disp_ext[k] && disp_lat[k] == 2'd1);
                f_l3[b]  = f_l3[b] | (!disp_ext[k] && disp_lat[k] == 2'd2);
                f_l4[b]  = f_l4[b] | (!disp_ext[k] && disp_lat[k] == 2'd3);
            end
        end
    end

    // ---- the rows
    logic [NE-1:0] wn [NE];              // the row's next state
    for (genvar r = 0; r < NE; r++) begin : g_row
        localparam int BR = b_of(r);
        for (genvar c = 0; c < NE; c++) begin : g_col
            logic wq;
            assign wn[r][c] = !col[c] && (w2[r] ? pd[BR][c] : wq);
            always_ff @(posedge clk) wq <= wn[r][c];
        end
    end

    // ---- every entry's fields
    for (genvar e = 0; e < NE; e++) begin : g_ent
        localparam int Q  = q_of(e);
        localparam int B  = b_of(e);
        localparam int D  = Q == 0 ? 3 : Q < NQ ? 1 : 2;  // the cycles it can wait after its issue
        localparam bit H2 = Q < NQ;      // it can have latency 2
        localparam bit H3 = Q == NQ;     // 3
        localparam bit H4 = Q == 0;      // 4
        localparam bit HX = Q == 0 || Q == NQ;  // external, non-speculative
        logic         vn;
        logic [D-1:0] sr, srn;           // shifted out: the column clears
        assign killed[e] = (bq[e] & kill) != '0;
        assign vn = !flush && (wa[e] || (v[e] && !g[e] && !killed[e]));
        assign sr0[e] = sr[0];
        always @(*) begin
            srn = D'(sr >> 1);
            if (g[e]) begin
                if (l2q[e]) srn[0] = 1'b1;
                if (l3q[e]) srn[D >= 2 ? 1 : 0] = 1'b1;
                if (l4q[e]) srn[D >= 3 ? 2 : 0] = 1'b1;
            end
            if (flush || killed[e]) srn = '0;
        end
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                oc[e] <= 1'b0; pw[e] <= 1'b0; v[e] <= 1'b0; rv[e] <= 1'b0; gq[e] <= 1'b0; sr <= '0;
            end else begin
                oc[e] <= !flush && (wa[e] || (oc[e] && !col[e] && !killed[e]));
                pw[e] <= !flush && ((wa[e] && f_wr[B]) || (pw[e] && !col[e] && !killed[e]));
                v[e]  <= vn;
                rv[e] <= vn && !wa[e] && wn[e] == '0;
                gq[e] <= g[e] && !flush && !killed[e];
                sr    <= srn;
            end
        end
        always_ff @(posedge clk) begin
            bq[e] <= wa[e] ? f_bm[B] : bq[e] & ~clr;
            if (wa[e]) begin
                wrq[e] <= f_wr[B];
                dq[e]  <= f_dst[B];
                l1q[e] <= f_l1[B];
            end
        end
        if (H2) begin : g_l2
            logic l2f;
            always_ff @(posedge clk) if (wa[e]) l2f <= f_l2[B];
            assign l2q[e] = l2f;
        end else begin : g_nol2
            assign l2q[e] = 1'b0;
        end
        if (H3) begin : g_l3
            logic l3f, stf;
            always_ff @(posedge clk) if (wa[e]) begin l3f <= f_l3[B]; stf <= f_st[B]; end
            assign l3q[e] = l3f;
            assign stq[e] = stf;
        end else begin : g_nol3
            assign l3q[e] = 1'b0;
            assign stq[e] = 1'b0;
        end
        if (H4) begin : g_l4
            logic l4f, mdf;
            always_ff @(posedge clk) if (wa[e]) begin l4f <= f_l4[B]; mdf <= f_md[B]; end
            assign l4q[e] = l4f;
            assign mdq[e] = mdf;
        end else begin : g_nol4
            assign l4q[e] = 1'b0;
            assign mdq[e] = 1'b0;
        end
        if (HX) begin : g_ns
            logic nsf;
            always_ff @(posedge clk) if (wa[e]) nsf <= f_ns[B];
            assign nsq[e] = nsf;
        end else begin : g_nons
            assign nsq[e] = 1'b0;
        end
    end

    // ---- a queue's select, its write slots, what it issued
    for (genvar q = 0; q <= NQ; q++) begin : g_q
        localparam int B  = q_base(q);
        localparam int QN = q_n(q);
        logic [QN-1:0] req, gr;
        logic [3:1]    rs;               // the write slot that many cycles from now is taken
        // age: ag[i][j]: entry i is older than entry j
        logic [QN-1:0] ag [QN];
        for (genvar i = 0; i < QN; i++) begin : g_i
            for (genvar j = i + 1; j < QN; j++) begin : g_j
                logic aq;
                always_ff @(posedge clk) begin
                    // (taken together: bank A, the even entry, has the older µop)
                    if (wa[B+i] && wa[B+j]) aq <= i % 2 == 0;
                    else if (wa[B+i])       aq <= 1'b0;  // i is new: j, if any, is older
                    else if (wa[B+j])       aq <= 1'b1;
                end
                assign ag[i][j] = aq;
                assign ag[j][i] = !aq;
            end
            assign ag[i][i] = 1'b0;
        end
        always @(*) begin
            for (int i = 0; i < QN; i++) begin
                req[i] = rv[B+i];
                if (q < NQ && wrq[B+i]) begin
                    if (l1q[B+i] && rs[1]) req[i] = 1'b0;
                    if (l2q[B+i] && rs[2]) req[i] = 1'b0;
                    if (q == 0 && l1q[B+i] && q0_hold) req[i] = 1'b0;
                end
                if (nsq[B+i] && (!ns_ok || nsb)) req[i] = 1'b0;
                if (q == 0 && mdq[B+i] && (!mdu_ok || mdb)) req[i] = 1'b0;
            end
            for (int i = 0; i < QN; i++) begin
                gr[i] = req[i];
                for (int j = 0; j < QN; j++) if (j != i && req[j] && ag[j][i]) gr[i] = 1'b0;
                g[B+i] = gr[i];
            end
        end
        // (a later latency sets a later slot; queues 1 .. NQ-1 have latency 2 at most.
        // A kill or a flush leaves them: a slot kept free for nothing, a few cycles)
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) rs <= '0;
            else begin
                rs[1] <= rs[2] || (gr & wrq[B+:QN] & l2q[B+:QN]) != '0;
                rs[2] <= q == 0 && (rs[3] || (gr & wrq[B+:QN] & l3q[B+:QN]) != '0);
                rs[3] <= q == 0 && (gr & wrq[B+:QN] & l4q[B+:QN]) != '0;
            end
        end
        // RR1
        always @(*) begin
            rr_valid[q] = gq[B+:QN] != '0;
            rr_entry[q] = '0;
            rr_bm[q]    = '0;
            for (int i = 0; i < QN; i++) if (gq[B+i]) begin
                rr_entry[q] = rr_entry[q] | LW'(i);
                rr_bm[q]    = rr_bm[q] | bq[B+i];
            end
        end
    end
    assign rr_ns = (gq & nsq) != '0;
    assign rr_md = (gq & mdq) != '0;

endmodule : OOO_SCHED
