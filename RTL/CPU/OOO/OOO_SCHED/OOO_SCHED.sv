//---------------------------------------------------------------------------
// OOO_SCHED.sv
//
// The distributed schedulers of the 4-issue core at 100 MHz (Doc/STRATEGY.md
// 4.2, 4.5 loop 1): NQ ALU queues of N entries and a memory queue of NM, one
// select each, up to W µops dispatched a cycle (2 at most into a queue).
// Queue 0 alone takes the multiply, the MDU and the system µops.
//
// The loop that decides the clock: a µop of latency 1 issued now lets its
// dependents, in any queue, issue in the next cycle. With MATRIX = 1 no tag
// travels in it (dependency matrix, Goshima et al., MICRO 2001):
//   rv (entry can ask) -> select, oldest first -> grant -> clear of the
//   entry's column in every row -> no bit left in a row -> rv
// Every entry has a row with one wait bit per entry of all the queues: "I wait
// for that entry". The tags are compared once, at dispatch, against the
// entries still pending (din below), which replaces renaming's busy bits and
// the DS register's snoop. The two sources of a µop share the row.
//
// With MATRIX = 0 the sources keep their tags (today's OOO_IQ): the clear
// goes on one tag bus per queue, compared against every source, and a table
// of busy bits answers at dispatch. Same cycles as MATRIX = 1: it is there to
// be measured against it. The order waits below keep their cells in both.
//
// A µop of latency L clears its column L - 1 cycles after its issue (sr) and
// keeps its entry until then: a column has one meaning at a time. Costs
// nothing in the model (Plan/model: hold=1). A µop whose result comes at an
// unknown time (disp_ext: MDU, AMO, LR, SC) keeps it until ext_* names it. So
// an entry is free when !oc, and can ask when rv. The write-back slots:
// each queue has one register-file write port, so a µop of latency L is not
// selected if a µop already issued writes L cycles from now (rs), and in
// queue 0 no latency-1 writer with q0_hold (a result of the MDU waits).
//
// The order waits use the same cells: a load waits for the column of every
// older store not issued yet (Plan/CORE.md 5.9), and a non-speculative µop for
// that of every older one, in any queue (Plan/CORE.md 5.16). A store and a
// non-speculative µop of latency 1 clear theirs when they issue. A killed
// entry clears nothing: whoever waits for it is younger, and dies with it.
//
// Mispredictions (OOO_CTRL): as OOO_IQ. Each entry has its branch mask (bq);
// kill frees those with the bit, clr clears the bit in every mask. Nothing is
// dispatched in a kill cycle (OOO_CTRL's d_ok); flush empties everything.
//
// Steering: rk orders the ALU queues, the emptiest first, as they were in the
// last cycle: the first any-ALU µop of a group goes to rk[0], the next to
// rk[1], rk[2], rk[0]; an ALU-0-only µop to queue 0. A µop stops, and with it
// the younger ones, if its queue has no entry or write port left.
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
        parameter int N    = 8,      // entries of an ALU queue
        parameter int NM   = 12,     // entries of the memory queue
        parameter int W    = 4,      // µops dispatched a cycle
        parameter int TAGW = 7,      // physical registers: 80
        parameter int NCK  = 12,     // checkpoints (branch-mask bits)
        parameter int NEXT = 2,      // external results a cycle
        parameter bit MATRIX = 1'b1  // dependency matrix, or tag compare
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

        // dispatch, in program order (0 the oldest), valid as a prefix
        input  logic [W-1:0]          disp_valid,
        input  logic [W-1:0][1:0]     disp_kind,  // 0 any ALU queue, 1 queue 0 only, 2 the memory queue
        input  logic [W-1:0][1:0]     disp_use,   // the sources the µop waits for
        input  logic [W-1:0][1:0][TAGW-1:0] disp_src,
        input  logic [W-1:0]          disp_wr,    // it writes its destination
        input  logic [W-1:0][TAGW-1:0] disp_dst,
        input  logic [W-1:0][1:0]     disp_lat,   // latency - 1: a load 2, a multiply 3; queues 1 .. NQ-1 up to 1
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
    localparam int LW = $clog2(N > NM ? N : NM);
    localparam int QW = $clog2(NQ + 1);
    localparam int NT = 1 << TAGW;

    function automatic int q_of(input int e);
        return e < NQ * N ? e / N : NQ;
    endfunction
    function automatic int q_base(input int q);
        return q * N;
    endfunction
    function automatic int q_n(input int q);
        return q < NQ ? N : NM;
    endfunction
    // the cycles a queue's µops can wait after their issue (sr's length)
    function automatic int q_dly(input int q);
        return q == 0 ? 3 : q < NQ ? 1 : 2;
    endfunction
    // the cells of the order waits alone (MATRIX = 0): stores and
    // non-speculative µops live in queue 0 and the memory queue
    function automatic bit keep(input int r, input int c);
        return MATRIX || ((q_of(r) == 0 || q_of(r) == NQ) && (q_of(c) == 0 || q_of(c) == NQ));
    endfunction

    // per entry
    logic [NE-1:0]           oc;         // occupied, the column not cleared yet
    logic [NE-1:0]           v;          // not issued yet
    logic [NE-1:0]           rv;         // not issued and nothing left to wait for
    logic [NE-1:0]           gq;         // issued in the last cycle
    logic [NE-1:0]           wrq;        // writes
    logic [NE-1:0]           l1q;        // latency 1 (clears at its issue)
    logic [NE-1:0]           l2q;        // latency 2
    logic [NE-1:0]           l3q;        // latency 3
    logic [NE-1:0]           l4q;        // latency 4
    logic [NE-1:0]           nsq, mdq, stq;
    logic [TAGW-1:0]         dq [NE];
    logic [NCK-1:0]          bq [NE];
    logic [NE-1:0]           sr0;        // the column clears now, by latency
    logic [NE-1:0]           killed;     // the mask has a killed bit

    logic [NE-1:0]           g;          // grants
    logic [NE-1:0]           col;        // the entry's column clears now
    logic [NE-1:0]           wr0, wr1;   // the entry is written through its queue's port 0, 1
    logic                    nsb, mdb;   // an issue in the last cycle: ns_ok / mdu_ok have not seen it

    assign nsb   = rr_ns;
    assign mdb   = rr_md;

    always @(*) begin
        for (int e = 0; e < NE; e++) begin
            col[e] = (g[e] && l1q[e]) || sr0[e];
            for (int x = 0; x < NEXT; x++) if (ext_valid[x] && int'(ext_entry[x]) == e) col[e] = 1'b1;
        end
    end

    // ---- steering
    logic [QW-1:0] rk [NQ];              // the ALU queues, the emptiest first (last cycle's)
    logic [NQ:0]   fr0, fr1;             // a queue has one free entry, two
    logic [NE-1:0] ff0, ff1;             // the first, the second free entry of its queue
    always @(*) begin
        ff0 = '0; ff1 = '0;
        for (int q = 0; q <= NQ; q++) begin
            automatic int s = 0;
            for (int i = 0; i < q_n(q); i++) if (!oc[q_base(q) + i]) begin
                if (s == 0) ff0[q_base(q) + i] = 1'b1;
                if (s == 1) ff1[q_base(q) + i] = 1'b1;
                if (s < 2) s = s + 1;
            end
            fr0[q] = s >= 1;
            fr1[q] = s >= 2;
        end
    end

    logic [W-1:0][QW-1:0] sq;            // the queue of a slot
    logic [W-1:0]         sp;            // the write port of its queue
    logic [NQ:0]          used0, used1;  // a queue's ports taken
    always @(*) begin
        automatic logic [1:0] nalu = 2'd0;
        automatic logic stop = flush;
        used0 = '0; used1 = '0;
        for (int k = 0; k < W; k++) begin
            automatic int q = disp_kind[k] == 2'd2 ? NQ : disp_kind[k] == 2'd1 ? 0 : int'(rk[int'(nalu) % NQ]);
            automatic logic room = used0[q] ? (!used1[q] && fr1[q]) : fr0[q];
            sq[k] = QW'(q);
            sp[k] = used0[q];
            disp_go[k] = disp_valid[k] && !stop && room;
            if (!disp_go[k]) stop = 1'b1;
            else begin
                if (used0[q]) used1[q] = 1'b1;
                used0[q] = 1'b1;
                if (disp_kind[k] == 2'd0) nalu = nalu + 2'd1;
            end
        end
    end
    assign disp_q = sq;

    // the entry a slot goes to; the slots a queue's port takes
    logic [NE-1:0] alloc [W];
    always @(*) begin
        wr0 = '0; wr1 = '0;
        for (int k = 0; k < W; k++) begin
            alloc[k]  = '0;
            disp_e[k] = '0;
            for (int e = 0; e < NE; e++)
                if (disp_go[k] && int'(sq[k]) == q_of(e) && (sp[k] ? ff1[e] : ff0[e])) begin
                    alloc[k][e] = 1'b1;
                    disp_e[k]   = LW'(e - q_base(q_of(e)));
                    if (sp[k]) wr1[e] = 1'b1; else wr0[e] = 1'b1;
                end
        end
    end

    // ---- what a dispatched µop waits for
    logic [NE-1:0] din [W];
    always @(*) begin
        for (int k = 0; k < W; k++) begin
            for (int j = 0; j < NE; j++) begin
                automatic logic b = 1'b0;
                // a producer still pending (matrix)
                if (MATRIX) for (int s = 0; s < 2; s++)
                    if (disp_use[k][s] && oc[j] && wrq[j] && dq[j] == disp_src[k][s]) b = 1'b1;
                // older stores for a load, older non-speculative µops for one
                if (disp_kind[k] == 2'd2 && !disp_st[k] && v[j] && stq[j]) b = 1'b1;
                if (disp_ns[k] && oc[j] && nsq[j]) b = 1'b1;
                // the same among the older slots of the group
                for (int m = 0; m < k; m++) if (alloc[m][j]) begin
                    if (MATRIX) for (int s = 0; s < 2; s++)
                        if (disp_use[k][s] && disp_wr[m] && disp_dst[m] == disp_src[k][s]) b = 1'b1;
                    if (disp_kind[k] == 2'd2 && !disp_st[k] && disp_st[m]) b = 1'b1;
                    if (disp_ns[k] && disp_ns[m]) b = 1'b1;
                end
                din[k][j] = b;
            end
        end
    end

    // through a queue's write ports
    logic [NE-1:0] pd0 [NQ+1], pd1 [NQ+1];
    always @(*) begin
        for (int q = 0; q <= NQ; q++) begin
            pd0[q] = '0; pd1[q] = '0;
            for (int k = 0; k < W; k++) if (disp_go[k] && int'(sq[k]) == q) begin
                if (sp[k]) pd1[q] = pd1[q] | din[k];
                else       pd0[q] = pd0[q] | din[k];
            end
        end
    end

    // ---- the rows
    logic [NE-1:0] wn [NE];              // the row's next state
    for (genvar r = 0; r < NE; r++) begin : g_row
        localparam int QR = q_of(r);
        for (genvar c = 0; c < NE; c++) begin : g_col
            if (keep(r, c)) begin : g_cell
                logic wq;
                assign wn[r][c] = !col[c] && (wr0[r] ? pd0[QR][c] : wr1[r] ? pd1[QR][c] : wq);
                always_ff @(posedge clk) wq <= wn[r][c];
            end else begin : g_none
                assign wn[r][c] = 1'b0;
            end
        end
    end

    // ---- tag compare (MATRIX = 0)
    logic [NE-1:0]             srdy;     // all the sources ready, next state
    if (MATRIX) begin : g_nosrc
        assign srdy = '1;
    end else begin : g_tags
        // one bus a queue (a queue has one clear of a writer a cycle: rs), one
        // for each external result
        localparam int NB = NQ + 1 + NEXT;
        logic [NB-1:0]         bv;
        logic [TAGW-1:0]       bt [NB];
        always @(*) begin
            for (int b = 0; b < NB; b++) begin bv[b] = 1'b0; bt[b] = '0; end
            for (int e = 0; e < NE; e++) begin
                automatic logic c = ((g[e] && l1q[e]) || sr0[e]) && wrq[e];
                if (c) bv[q_of(e)] = 1'b1;
                bt[q_of(e)] = bt[q_of(e)] | ({TAGW{c}} & dq[e]);
                for (int x = 0; x < NEXT; x++) begin
                    automatic logic h = ext_valid[x] && int'(ext_entry[x]) == e && wrq[e];
                    if (h) bv[NQ+1+x] = 1'b1;
                    bt[NQ+1+x] = bt[NQ+1+x] | ({TAGW{h}} & dq[e]);
                end
            end
        end
        function automatic logic woken(input logic [TAGW-1:0] t);
            for (int b = 0; b < NB; b++) if (bv[b] && bt[b] == t) return 1'b1;
            return 1'b0;
        endfunction
        // busy bits: set at dispatch, cleared by a bus
        logic [NT-1:0] busy;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) busy <= '0;
            else if (flush) busy <= '0;
            else begin
                for (int b = 0; b < NB; b++) if (bv[b]) busy[bt[b]] <= 1'b0;
                for (int k = 0; k < W; k++) if (disp_go[k] && disp_wr[k]) busy[disp_dst[k]] <= 1'b1;
            end
        end
        // the sources as dispatched: ready, unless busy or an older slot's
        logic [1:0] dr [W];
        always @(*) begin
            for (int k = 0; k < W; k++) for (int s = 0; s < 2; s++) begin
                automatic logic r = !disp_use[k][s] || !busy[disp_src[k][s]] || woken(disp_src[k][s]);
                for (int m = 0; m < k; m++)
                    if (disp_use[k][s] && disp_wr[m] && disp_dst[m] == disp_src[k][s]) r = 1'b0;
                dr[k][s] = r;
            end
        end
        for (genvar e = 0; e < NE; e++) begin : g_ent
            logic [1:0][TAGW-1:0] st;
            logic [1:0]           rq, rn;
            always @(*) begin
                rn = rq;
                for (int s = 0; s < 2; s++) if (woken(st[s])) rn[s] = 1'b1;
                for (int k = 0; k < W; k++) if (alloc[k][e]) rn = dr[k];
            end
            always_ff @(posedge clk) begin
                rq <= rn;
                for (int k = 0; k < W; k++) if (alloc[k][e]) st <= disp_src[k];
            end
            assign srdy[e] = rn == 2'b11;
        end
    end

    // ---- every entry's fields
    for (genvar e = 0; e < NE; e++) begin : g_ent
        localparam int Q = q_of(e);
        localparam int D = q_dly(Q);
        logic [W-1:0] a;
        logic         wany, vn;
        logic [D-1:0] sr, srn;           // shifted out: the column clears
        for (genvar k = 0; k < W; k++) begin : g_a
            assign a[k] = alloc[k][e];
        end
        assign wany = wr0[e] || wr1[e];
        assign killed[e] = (bq[e] & kill) != '0;
        assign vn = !flush && (wany || (v[e] && !g[e] && !killed[e]));
        assign sr0[e] = sr[0];
        always @(*) begin
            srn = D'(sr >> 1);
            if (g[e]) begin
                if (l2q[e])          srn[0]   = 1'b1;
                if (D >= 2 && l3q[e]) srn[D >= 2 ? 1 : 0] = 1'b1;
                if (D >= 3 && l4q[e]) srn[D >= 3 ? 2 : 0] = 1'b1;
            end
            if (flush || killed[e]) srn = '0;
        end
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                oc[e] <= 1'b0; v[e] <= 1'b0; rv[e] <= 1'b0; gq[e] <= 1'b0; sr <= '0;
            end else begin
                oc[e] <= !flush && (wany || (oc[e] && !col[e] && !killed[e]));
                v[e]  <= vn;
                rv[e] <= vn && wn[e] == '0 && srdy[e];
                gq[e] <= g[e] && !flush && !killed[e];
                sr    <= srn;
            end
        end
        always_ff @(posedge clk) begin
            bq[e] <= bq[e] & ~clr;
            for (int k = 0; k < W; k++) if (a[k]) begin
                wrq[e] <= disp_wr[k];
                dq[e]  <= disp_dst[k];
                bq[e]  <= disp_bm[k];
                nsq[e] <= disp_ns[k];
                mdq[e] <= disp_md[k];
                stq[e] <= disp_st[k];
                l1q[e] <= !disp_ext[k] && disp_lat[k] == 2'd0;
                l2q[e] <= !disp_ext[k] && disp_lat[k] == 2'd1;
                l3q[e] <= !disp_ext[k] && disp_lat[k] == 2'd2;
                l4q[e] <= !disp_ext[k] && disp_lat[k] == 2'd3;
            end
        end
    end

    // ---- a queue's select, its write slots, what it issued
    for (genvar q = 0; q <= NQ; q++) begin : g_q
        localparam int B  = q_base(q);
        localparam int QN = q_n(q);
        logic [QN-1:0] req, gr;
        logic [3:1]    rs;               // the write slot that many cycles from now is taken
        // age: ag[i][j], i < j: entry i is older than entry j
        logic [QN-1:0] ag [QN];
        for (genvar i = 0; i < QN; i++) begin : g_i
            for (genvar j = i + 1; j < QN; j++) begin : g_j
                logic aq;
                always_ff @(posedge clk) begin
                    // (written together: port 0 has the lower entry and the older µop)
                    if (wr0[B+i] && wr1[B+j])      aq <= 1'b1;
                    else if (wr0[B+i] || wr1[B+i]) aq <= 1'b0;   // i is new: j, if any, is older
                    else if (wr0[B+j] || wr1[B+j]) aq <= 1'b1;
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
        // (a later latency sets a later slot; queues 1 .. NQ-1 have latency 2 at most)
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) rs <= '0;
            else if (flush) rs <= '0;
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

    // ---- the ALU queues by how full, for the next cycle's steering
    logic [3:0] cn [NQ];
    always @(*) begin
        for (int q = 0; q < NQ; q++) begin
            cn[q] = '0;
            for (int i = 0; i < N; i++) if (oc[q_base(q) + i]) cn[q] = cn[q] + 4'd1;
        end
    end
    logic [QW-1:0] o [NQ];
    always @(*) begin
        logic [QW-1:0] t;
        t = '0;
        for (int i = 0; i < NQ; i++) o[i] = QW'(i);
        for (int a = 1; a < NQ; a++) for (int b = a; b > 0; b--)
            if (cn[int'(o[b])] < cn[int'(o[b-1])]) begin
                t = o[b]; o[b] = o[b-1]; o[b-1] = t;
            end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NQ; i++) rk[i] <= QW'(i);
        end else begin
            for (int i = 0; i < NQ; i++) rk[i] <= o[i];
        end
    end

endmodule : OOO_SCHED
