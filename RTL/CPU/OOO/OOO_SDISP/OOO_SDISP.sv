//---------------------------------------------------------------------------
// OOO_SDISP.sv
//
// The dispatch of OOO_SCHED, in two phases (Plan/OOC.md 28.4):
//
//   S1, with renaming's R2: which queue, which bank, which entry; what each
//      slot waits for. An entry's fields are written at its end.
//   S2, the stage DS: the wait bits go into the row (OOO_SCHED).
//
// So nothing here depends on the grants but the choice of a free entry, and
// a slot's data does not pass through the decision of whether it goes.
//
// A queue is 2 banks, its even and its odd entries, each written by one µop
// a cycle, so an entry has one source for its fields, without a mux. The
// first µop into a queue takes bank A if it has room, else B; a second takes
// B, only after A. A third, or none free, stops the slot and the younger ones.
// The slot's bank does not depend on whether the older slots go: they all
// go if it does.
//
// The registers that decide it:
//   ff, bf   the first free entry of each bank, and that there is one, from
//            the state of the last cycle: an entry can be chosen the cycle
//            after its column clears (a killed one a cycle later)
//   rk       the ALU queues, the emptiest first, as they were: the first
//            any-ALU µop of a group goes to rk[0], the next to rk[1], rk[2], rk[0]
//
// What a slot waits for (din, a bit per entry, kept for S2):
//   - a source's producer still pending: pw[j] && dq[j] == the source's tag.
//     This compare replaces renaming's busy bits and the DS register's snoop.
//   - a load: every older store not issued; a non-speculative µop: every older
//     one still in its entry; a load the wait table marks (disp_wl): every older
//     store's data µop not issued (Plan/OOC.md 28.13)
//   - the same among the older slots of the group, at the entries they get
// A column clearing in S1 was not seen in din: col_q takes it out in S2; one
// clearing in S2 OOO_SCHED's cell takes out.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_SDISP
    #(
        parameter int NQ   = 3,
        parameter int N    = 8,
        parameter int NM   = 12,
        parameter int W    = 4,
        parameter int TAGW = 7
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,
        input  logic                  flush,

        // the slots, in program order, valid as a prefix
        input  logic [W-1:0]          disp_valid,
        input  logic [W-1:0][1:0]     disp_kind,
        input  logic [W-1:0][1:0]     disp_use,
        input  logic [W-1:0][1:0][TAGW-1:0] disp_src,
        input  logic [W-1:0]          disp_wr,
        input  logic [W-1:0][TAGW-1:0] disp_dst,
        input  logic [W-1:0]          disp_ns,
        input  logic [W-1:0]          disp_st,
        input  logic [W-1:0]          disp_sd,
        input  logic [W-1:0]          disp_wl,
        output logic [W-1:0]          disp_go,
        output logic [W-1:0][$clog2(NQ+1)-1:0] disp_q,
        output logic [W-1:0][$clog2(N > NM ? N : NM)-1:0] disp_e,

        // the entries, as OOO_SCHED has them
        input  logic [NQ*N+NM-1:0]    oc,         // occupied, its column not cleared yet
        input  logic [NQ*N+NM-1:0]    v,          // not issued yet
        input  logic [NQ*N+NM-1:0]    pw,         // a result pending
        input  logic [NQ*N+NM-1:0]    stq,        // a store
        input  logic [NQ*N+NM-1:0]    sdq,        // a store's data
        input  logic [NQ*N+NM-1:0]    nsq,        // non-speculative
        input  logic [NQ*N+NM-1:0][TAGW-1:0] dq,  // its destination
        input  logic [NQ*N+NM-1:0]    col,        // its column clears now

        // S1: an entry taken now, and which slot writes each bank
        output logic [NQ*N+NM-1:0]    wa,
        output logic [2*(NQ+1)-1:0][W-1:0] bsel,
        // S2: the row of an entry written now, and each bank's bits for it
        output logic [NQ*N+NM-1:0]    w2,
        output logic [NQ*N+NM-1:0]    pd [2*(NQ+1)]
    );

    localparam int NE = NQ * N + NM;
    localparam int NB = 2 * (NQ + 1);
    localparam int LW = $clog2(N > NM ? N : NM);
    localparam int QW = $clog2(NQ + 1);

    function automatic int q_of(input int e);
        return e < NQ * N ? e / N : NQ;
    endfunction
    function automatic int b_of(input int e);    // the bank of an entry
        return 2 * q_of(e) + (e - q_of(e) * N) % 2;
    endfunction

    // ---- the registers that decide it
    logic [NE-1:0] ff;
    logic [NB-1:0] bf;
    logic [QW-1:0] rk [NQ];
    logic [LW-1:0] fe [NB];              // ff, encoded: a bank's entry in its queue
    always @(*) begin
        for (int b = 0; b < NB; b++) fe[b] = '0;
        for (int e = 0; e < NE; e++) if (ff[e]) fe[b_of(e)] = fe[b_of(e)] | LW'(e - q_of(e) * N);
    end

    // ---- steering
    logic [W-1:0] room;
    always @(*) begin
        automatic logic [1:0]  nalu = 2'd0;
        automatic logic [NQ:0] ua = '0;
        automatic logic [NQ:0] ub = '0;
        for (int k = 0; k < W; k++) begin
            automatic int q = disp_kind[k] == 2'd2 ? NQ : disp_kind[k] == 2'd1 ? 0 : disp_kind[k] == 2'd3 ? NQ - 1 : int'(rk[int'(nalu) % NQ]);
            automatic logic ta = !ua[q] && bf[2*q];
            automatic logic tb = !ub[q] && !ta && bf[2*q+1];
            disp_q[k] = QW'(q);
            room[k]   = ta || tb;
            for (int b = 0; b < NB; b++) bsel[b][k] = 1'b0;
            bsel[2*q][k]   = ta;
            bsel[2*q+1][k] = tb;
            if (ta) ua[q] = 1'b1;
            if (tb) ub[q] = 1'b1;
            if (disp_kind[k] == 2'd0) nalu = nalu + 2'd1;
        end
    end
    always @(*) begin
        automatic logic ok = !flush;
        for (int k = 0; k < W; k++) begin
            ok = ok && disp_valid[k] && room[k];
            disp_go[k] = ok;
            disp_e[k]  = '0;
            for (int b = 0; b < NB; b++) if (bsel[b][k]) disp_e[k] = disp_e[k] | fe[b];
        end
    end
    logic [NB-1:0] bgo;                  // a bank is written now
    always @(*) begin
        for (int b = 0; b < NB; b++) bgo[b] = (bsel[b] & disp_go) != '0;
        for (int e = 0; e < NE; e++) wa[e] = ff[e] && bgo[b_of(e)];
    end

    // ---- the next choices
    logic [NE-1:0] avail, ffn;
    logic [NB-1:0] bfn;
    always @(*) begin
        avail = (~oc | col) & ~wa;
        ffn = '0; bfn = '0;
        for (int e = 0; e < NE; e++) if (avail[e] && !bfn[b_of(e)]) begin
            ffn[e] = 1'b1;
            bfn[b_of(e)] = 1'b1;
        end
    end
    logic [3:0] cn [NQ];
    always @(*) begin
        for (int q = 0; q < NQ; q++) begin
            cn[q] = '0;
            for (int i = 0; i < N; i++) if (oc[q * N + i]) cn[q] = cn[q] + 4'd1;
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
            ff <= '0; bf <= '0;
            for (int i = 0; i < NQ; i++) rk[i] <= QW'(i);
        end else begin
            ff <= ffn; bf <= bfn;
            for (int i = 0; i < NQ; i++) rk[i] <= o[i];
        end
    end

    // ---- what a slot waits for
    logic [NE-1:0] din [W];
    logic [W-1:0]  grp [W];              // grp[k][m]: slot k waits for the older slot m
    always @(*) begin
        for (int k = 0; k < W; k++) begin
            grp[k] = '0;
            for (int m = 0; m < k; m++) begin
                for (int s = 0; s < 2; s++)
                    if (disp_use[k][s] && disp_wr[m] && disp_dst[m] == disp_src[k][s]) grp[k][m] = 1'b1;
                if (disp_kind[k] == 2'd2 && !disp_st[k] && disp_st[m]) grp[k][m] = 1'b1;
                if (disp_wl[k] && disp_sd[m]) grp[k][m] = 1'b1;
                if (disp_ns[k] && disp_ns[m]) grp[k][m] = 1'b1;
            end
            for (int j = 0; j < NE; j++) begin
                automatic logic b = 1'b0;
                for (int s = 0; s < 2; s++)
                    if (disp_use[k][s] && pw[j] && dq[j] == disp_src[k][s]) b = 1'b1;
                if (disp_kind[k] == 2'd2 && !disp_st[k] && v[j] && stq[j]) b = 1'b1;
                if (disp_wl[k] && v[j] && sdq[j]) b = 1'b1;
                if (disp_ns[k] && oc[j] && nsq[j]) b = 1'b1;
                for (int m = 0; m < k; m++) if (grp[k][m] && bsel[b_of(j)][m] && ff[j]) b = 1'b1;
                din[k][j] = b;
            end
        end
    end

    // ---- S2
    logic [NE-1:0]         d2 [W];
    logic [NB-1:0][W-1:0]  s2;
    logic [NE-1:0]         col_q;
    always_ff @(posedge clk) begin
        for (int k = 0; k < W; k++) d2[k] <= din[k];
        col_q <= col;
        s2 <= bsel;                      // (a bank not written has no use for it)
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) w2 <= '0;
        else        w2 <= wa;
    end
    always @(*) begin
        for (int b = 0; b < NB; b++) begin
            pd[b] = '0;
            for (int k = 0; k < W; k++) if (s2[b][k]) pd[b] = pd[b] | d2[k];
            pd[b] = pd[b] & ~col_q;
        end
    end

endmodule : OOO_SDISP
