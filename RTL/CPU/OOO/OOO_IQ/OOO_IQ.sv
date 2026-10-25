//---------------------------------------------------------------------------
// OOO_IQ.sv
//
// The issue queue of mmRISC-3 in the fusion configuration (STRATEGY.md 4):
// unified, N entries, up to 2 sources and 1 destination per µop (a fused
// pair too: OOO_FUSE SRC2 / W1, Plan/OOC.md 7.4), 2 µops written a cycle,
// 3 issued a cycle:
//   port 0  ALU0 (and MUL / DIV, which only go here)
//   port 1  ALU1
//   port 2  LSU
// The selection and the wakeup close in one cycle (the loop that lets a
// dependent ALU µop issue in the cycle after its producer):
//   ready bits -> requests -> oldest first by an age matrix -> the issued
//   µops' destination tags -> compare against every source -> ready bits.
// Latency 1 (ALU) wakes in the same cycle as the select. Latency 2 (a load
// that is predicted to hit, a multiply) goes through one register first.
// External wakeups (a load answered after a miss, a divide) come in on
// ext_*.
//
// The wakeup has 4 + NEXT tag buses, one per result that can come
// (Plan/OOC.md 10), by what each port issues:
//   port 0 now      ALU0, latency 1
//   port 1 now      ALU1 (latency 1 only: a latency-2 µop is dispatched
//                   as ALU0 only or to the LSU, never as "any ALU")
//   port 0 delayed  a multiply, a cycle after its issue
//   port 2 delayed  a load, a cycle after its issue (port 2 writes a
//                   register only with latency 2; a store writes none)
//   external        NEXT
// The issued µops are read by an AND-OR of the one-hot grants, not through
// their encoded entry numbers (iss_entry is only for the payload).
//
// Loads that miss (Plan/OOC.md 15): the dependents of a load are woken
// before its result is known, so that they issue 2 cycles after it; when
// the LSU finds in M that the load gives no result in WB (ld_cancel: a
// miss, a wait), what was issued on that guess is taken back, selectively:
//   - a load issued in cycle c owns load slot c mod 3; it is decided in
//     cycle c + 3, by ld_cancel of M in that cycle: cancelled or confirmed;
//     the load issued in that cycle takes the same slot, so a load's own
//     bit is never decided in the cycle it is set (it is not in iss_ldm:
//     a load is not dropped by its own cancel, the LSU keeps it)
//   - every wakeup carries the mask of the open loads its value depends on
//     (a load adds its own slot), every source keeps the mask it was woken
//     with, and a µop issues with the OR of its sources' masks (iss_ldm,
//     for the units: a µop in RR or EX whose mask meets ld_kill, the slot
//     cancelled in the cycle before, is dropped)
//   - a µop issued with a mask stays in the queue (not selectable) until
//     its loads are confirmed, then its entry is freed; if one is
//     cancelled it goes back to waiting, and every source woken through
//     the cancelled load is not ready any more
//   - ld_cancel comes late in its cycle (from the LSU's M), so it only
//     acts on the next state of the entries, never on this cycle's select:
//     a µop selected in the cycle of the cancel on its slot is taken back
//     as if not issued (the units drop it with ld_kill a cycle later), and
//     its wakeups do not count
//   (deciding a cycle later, through a register, would keep the entries a
//   cycle longer: -1.1 % / -0.5 % in the model against -0.2 % / -0.2 %)
//   - the cancelled load itself is not issued again (the LSU tries it
//     again from the LQ and answers late on ext_*): its entry waits,
//     never selected, until that answer, so that a µop dispatched meanwhile
//     sees its producer as not ready
//   - at dispatch, a source whose producer is in the queue and not issued
//     (one taken back, or a cancelled load) is not ready whatever
//     disp_rdy says, and one whose producer is still unconfirmed gets the
//     producer's mask (disp_rdy follows the wakeups, Plan/OOC.md 15.2)
// Entries are freed when issued with no open load (or when their loads
// are confirmed).
//
// The payload of a µop (operation, immediates, ROB index) is not here: it
// sits in a LUTRAM indexed by the entry (OOO_IQPL): disp_entry says where
// it is written, iss_entry where it is read.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_IQ
    #(
        parameter int N    = 16,
        parameter int TAGW = 6,      // physical registers: 64
        parameter int NEXT = 2       // external wakeup ports
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,
        input  logic                  flush,      // misprediction: empty the queue

        // dispatch: up to 2 µops a cycle, in program order (0 the older)
        output logic [1:0]            disp_ready, // room for this many
        output logic [1:0][$clog2(N)-1:0] disp_entry, // the entries they go to (for the payload)
        input  logic [1:0]            disp_valid,
        input  logic [1:0][1:0]       disp_port,  // 0 any ALU, 1 ALU0 only, 2 LSU
        input  logic [1:0][1:0]       disp_use,   // the sources the µop reads
        input  logic [1:0][1:0][TAGW-1:0] disp_src,
        input  logic [1:0][1:0]       disp_rdy,   // already ready at rename
        input  logic [1:0]            disp_wr,    // it writes its destination
        input  logic [1:0][TAGW-1:0]  disp_dst,
        input  logic [1:0]            disp_lat2,  // results after 2 cycles (load, multiply)

        // external wakeups
        input  logic [NEXT-1:0]           ext_valid,
        input  logic [NEXT-1:0][TAGW-1:0] ext_tag,

        // the LSU in M: the load from port 2 issued 3 cycles ago gives no result in WB
        input  logic                  ld_cancel,

        // issue
        output logic [2:0]            iss_valid,
        output logic [2:0][$clog2(N)-1:0] iss_entry,
        output logic [2:0][1:0][TAGW-1:0] iss_src,
        output logic [2:0]            iss_wr,
        output logic [2:0][TAGW-1:0]  iss_dst,
        output logic [2:0][2:0]       iss_ldm,    // the open loads it depends on (load slots)
        output logic [2:0]            ld_kill     // the load slot cancelled in the cycle before
    );

    localparam int EW = $clog2(N);
    localparam int NB = 4 + NEXT;    // broadcast tags (above)
    localparam int NS = 3;           // load slots (Plan/OOC.md 15.6: 3, not 4)

    // ---- the open loads: slots, and the decision 3 cycles after the issue
    logic [1:0]    lslot;            // the slot of a load issued in this cycle
    logic [2:0]    lvh;              // lvh[k]: a load issued k + 1 cycles ago
    logic [NS-1:0] kill_m, conf_m;   // the slot decided in this cycle (late in it: next state only)
    logic [NS-1:0] kill_q;
    always @(*) begin                // (the slot of the load issued 3 cycles ago is this cycle's)
        kill_m = '0;
        conf_m = '0;
        if (lvh[2]) begin
            if (ld_cancel) kill_m[lslot] = 1'b1;
            else           conf_m[lslot] = 1'b1;
        end
    end
    assign ld_kill = kill_q;

    // per entry; arrays (not packed vectors) where an entry is chosen at run time
    logic [N-1:0]                 v;
    logic [N-1:0]                 isd;        // issued, kept until its loads are confirmed
    logic [N-1:0]                 phl;        // a cancelled load, waiting for its late answer
    logic [N-1:0]                 lat2;
    logic [1:0]                   port  [N];
    logic [1:0]                   use_s [N];
    logic [1:0][TAGW-1:0]         src   [N];
    logic [1:0]                   rdy   [N];
    logic [1:0][NS-1:0]           sm    [N];  // the mask each source was woken with
    logic [NS-1:0]                em    [N];  // the mask it issued with
    logic [N-1:0]                 wr;
    logic [TAGW-1:0]              dst   [N];
    logic [N-1:0]                 older [N];  // older[i][j]: entry j is older than entry i

    // ---- select
    logic [N-1:0] ready_all, req0, req1, req2, g0, g1, g2;
    always @(*) begin
        for (int i = 0; i < N; i++) begin
            ready_all[i] = v[i] && !isd[i] && !phl[i] && ((rdy[i] | ~use_s[i]) == 2'b11);
            req0[i] = ready_all[i] && (port[i] == 2'd0 || port[i] == 2'd1);
            req1[i] = ready_all[i] && (port[i] == 2'd0);
            req2[i] = ready_all[i] && (port[i] == 2'd2);
        end
        for (int i = 0; i < N; i++) begin
            g0[i] = req0[i] && ((req0 & older[i]) == '0);
        end
        for (int i = 0; i < N; i++) begin
            g1[i] = req1[i] && !g0[i] && (((req1 & ~g0) & older[i]) == '0);
            g2[i] = req2[i] && ((req2 & older[i]) == '0);
        end
    end

    function automatic logic [EW-1:0] enc(input logic [N-1:0] g);
        logic [EW-1:0] e;
        e = '0;
        for (int i = 0; i < N; i++) if (g[i]) e = EW'(i);
        return e;
    endfunction

    // the mask a µop issues with: its sources'; a load adds its own slot
    // to what it keeps and to its wakeup
    logic [NS-1:0] emn [N];
    logic [NS-1:0] own;
    always @(*) begin
        own = NS'(1) << lslot;
        for (int i = 0; i < N; i++) emn[i] = sm[i][0] | sm[i][1];
    end

    // the issued µops, by an AND-OR of the grants (one-hot); only port 0
    // issues both latencies
    logic lat2_0;
    always @(*) begin
        logic [N-1:0] g [3];
        g[0] = g0; g[1] = g1; g[2] = g2;
        lat2_0 = |(g0 & lat2);
        for (int p = 0; p < 3; p++) begin
            iss_valid[p] = |g[p];
            iss_entry[p] = enc(g[p]);
            iss_src[p]   = '0;
            iss_dst[p]   = '0;
            iss_ldm[p]   = '0;
            iss_wr[p]    = |(g[p] & wr);
            for (int i = 0; i < N; i++) begin
                iss_src[p] = iss_src[p] | ({2*TAGW{g[p][i]}} & src[i]);
                iss_dst[p] = iss_dst[p] | ({TAGW{g[p][i]}} & dst[i]);
                iss_ldm[p] = iss_ldm[p] | ({NS{g[p][i]}} & emn[i]);
            end
        end
    end

    // ---- wakeup tags and masks: the µops issued now with latency 1, those
    // issued one cycle ago with latency 2 (not if taken back), and the
    // external ones
    logic                    d_v0, d_v2;
    logic [TAGW-1:0]         d_t0, d_t2;
    logic [NS-1:0]           d_m0, d_m2;
    logic [NB-1:0]           bv;
    logic [NB-1:0][TAGW-1:0] bt;
    logic [NB-1:0][NS-1:0]   bm;
    always @(*) begin
        bv[0] = iss_wr[0] && !lat2_0;       bt[0] = iss_dst[0]; bm[0] = iss_ldm[0];
        bv[1] = iss_wr[1];                  bt[1] = iss_dst[1]; bm[1] = iss_ldm[1];
        bv[2] = d_v0;                       bt[2] = d_t0;       bm[2] = d_m0;
        bv[3] = d_v2;                       bt[3] = d_t2;       bm[3] = d_m2;
        for (int e = 0; e < NEXT; e++) begin
            bv[4+e] = ext_valid[e];
            bt[4+e] = ext_tag[e];
            bm[4+e] = '0;
        end
    end

    function automatic logic woken(input logic [TAGW-1:0] t);
        logic w;
        w = 1'b0;
        for (int b = 0; b < NB; b++) if (bv[b] && bt[b] == t) w = 1'b1;
        return w;
    endfunction
    function automatic logic xwoken(input logic [TAGW-1:0] t);   // by an external wakeup
        logic w;
        w = 1'b0;
        for (int e = 0; e < NEXT; e++) if (ext_valid[e] && ext_tag[e] == t) w = 1'b1;
        return w;
    endfunction
    function automatic logic [NS-1:0] wmask(input logic [TAGW-1:0] t);
        logic [NS-1:0] m;
        m = '0;
        for (int b = 0; b < NB; b++) if (bv[b] && bt[b] == t) m = m | bm[b];
        return m;
    endfunction

    // ---- free entries for dispatch: the first two
    logic [EW-1:0] f0, f1;
    logic          f0v, f1v;
    logic [1:0][EW-1:0] fe;       // the entry each dispatched µop goes to
    logic [1:0]         fev;
    always @(*) begin
        f0v = 1'b0; f1v = 1'b0; f0 = '0; f1 = '0;
        for (int i = N - 1; i >= 0; i--) if (!v[i]) begin f1 = f0; f1v = f0v; f0 = EW'(i); f0v = 1'b1; end
        disp_ready = (f0v && f1v) ? 2'd2 : f0v ? 2'd1 : 2'd0;
        fe[0] = f0; fe[1] = f1; fev[0] = f0v; fev[1] = f1v;
        disp_entry = fe;
    end

    // ---- the sources of the µops dispatched now: ready (and with what
    // mask), looking at their producers in the queue too
    logic [1:0][1:0]         drdy;
    logic [1:0][1:0][NS-1:0] dm;
    always @(*) begin
        for (int d = 0; d < 2; d++) begin
            for (int s = 0; s < 2; s++) begin
                logic          wait_q;
                logic [NS-1:0] kept;
                logic [TAGW-1:0] t;
                t = disp_src[d][s];
                wait_q = 1'b0;
                kept   = '0;
                for (int j = 0; j < N; j++) begin
                    if (v[j] && wr[j] && dst[j] == t) begin
                        if (isd[j]) kept   = kept | em[j];
                        else        wait_q = 1'b1;
                    end
                end
                if (woken(t)) begin
                    drdy[d][s] = (wmask(t) & kill_m) == '0;
                    dm[d][s]   = drdy[d][s] ? wmask(t) & ~conf_m : '0;
                end else begin
                    drdy[d][s] = disp_rdy[d][s] && !wait_q && (kept & kill_m) == '0;
                    dm[d][s]   = drdy[d][s] ? kept & ~conf_m : '0;
                end
            end
        end
    end

    // the latency-2 results issued now wake their dependents next cycle;
    // the loads issued now are decided in 4 cycles
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_v0   <= 1'b0;
            d_v2   <= 1'b0;
            lslot  <= '0;
            lvh    <= '0;
            kill_q <= '0;
        end else begin
            d_v0   <= iss_wr[0] && lat2_0 && (iss_ldm[0] & kill_m) == '0;
            d_v2   <= iss_wr[2] && (iss_ldm[2] & kill_m) == '0;
            lslot  <= (lslot == 2'd2) ? 2'd0 : lslot + 2'd1;
            lvh    <= {lvh[1:0], iss_wr[2]};
            kill_q <= kill_m;
        end
    end
    always_ff @(posedge clk) begin
        d_t0 <= iss_dst[0];
        d_t2 <= iss_dst[2];
        d_m0 <= iss_ldm[0] & ~conf_m;
        d_m2 <= iss_ldm[2] | own;            // (a bit confirmed now is this slot: the load's own)
    end

    // which entries are written and which issue this cycle
    logic [N-1:0] issued, disp0, disp1;
    always @(*) begin
        for (int i = 0; i < N; i++) begin
            issued[i] = g0[i] || g1[i] || g2[i];
            disp0[i]  = !flush && disp_valid[0] && fev[0] && fe[0] == EW'(i);
            disp1[i]  = !flush && disp_valid[1] && fev[1] && fe[1] == EW'(i);
        end
    end

    // every entry keeps its own fields
    for (genvar i = 0; i < N; i++) begin : g_ent
        logic                 vq, iq, phq, lq, wq;
        logic [1:0]           pq, uq, rq, oslq;   // oslq: the slot of a load (its own)
        logic [1:0][TAGW-1:0] sq;
        logic [1:0][NS-1:0]   smq;
        logic [NS-1:0]        emq;
        logic [TAGW-1:0]      dq;
        logic [N-1:0]         oq;
        assign v[i]     = vq;
        assign isd[i]   = iq;
        assign phl[i]   = phq;
        assign lat2[i]  = lq;
        assign port[i]  = pq;
        assign use_s[i] = uq;
        assign src[i]   = sq;
        assign rdy[i]   = rq;
        assign sm[i]    = smq;
        assign em[i]    = emq;
        assign wr[i]    = wq;
        assign dst[i]   = dq;
        assign older[i] = oq;

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                vq  <= 1'b0;
                iq  <= 1'b0;
                phq <= 1'b0;
            end else if (flush) begin
                vq  <= 1'b0;
                iq  <= 1'b0;
                phq <= 1'b0;
            end else if (disp0[i] || disp1[i]) begin
                automatic int d = disp1[i] ? 1 : 0;
                vq  <= 1'b1;
                iq  <= 1'b0;
                phq <= 1'b0;
                pq  <= disp_port[d];
                uq  <= disp_use[d];
                sq  <= disp_src[d];
                for (int s = 0; s < 2; s++) begin
                    rq[s]  <= drdy[d][s];
                    smq[s] <= disp_use[d][s] ? dm[d][s] : '0;
                end
                wq <= disp_wr[d];
                dq <= disp_dst[d];
                lq <= disp_lat2[d];
                // age: younger than every entry there, and the second of a
                // pair younger than the first
                for (int j = 0; j < N; j++) oq[j] <= v[j];
                if (disp1[i] && disp_valid[0] && fev[0]) oq[fe[0]] <= 1'b1;
            end else begin
                // the sources: woken (with the wakeup's mask), or taken back by a cancel
                for (int s = 0; s < 2; s++) begin
                    if (woken(sq[s]) && (wmask(sq[s]) & kill_m) == '0) begin
                        rq[s]  <= 1'b1;
                        smq[s] <= uq[s] ? wmask(sq[s]) & ~conf_m : '0;   // (a source not read has no mask)
                    end else if (woken(sq[s]) || (smq[s] & kill_m) != '0) begin
                        rq[s]  <= 1'b0;
                        smq[s] <= '0;
                    end else begin
                        smq[s] <= smq[s] & ~conf_m;
                    end
                end
                if (issued[i] && (emn[i] & kill_m) != '0) begin
                    // selected on the load cancelled now: as if not issued
                end else if (issued[i]) begin
                    // freed now, or kept until its loads are decided (a load at least until itself)
                    if ((emn[i] & ~conf_m) == '0 && !(pq == 2'd2 && wq)) vq <= 1'b0;
                    else begin
                        iq   <= 1'b1;
                        emq  <= (emn[i] & ~conf_m) | ((pq == 2'd2 && wq) ? own : '0);
                        oslq <= lslot;
                    end
                end else if (iq) begin
                    if ((emq & kill_m) != '0) begin
                        iq <= 1'b0;                 // back to waiting (its sources taken back above)
                        if (pq == 2'd2 && wq && kill_m[oslq]) phq <= 1'b1;   // the cancelled load itself
                    end else if ((emq & ~conf_m) == '0) begin
                        vq <= 1'b0;
                        iq <= 1'b0;
                    end else begin
                        emq <= emq & ~conf_m;
                    end
                end else if (phq && xwoken(dq)) begin
                    vq  <= 1'b0;                    // its late answer (only ever on ext_*)
                    phq <= 1'b0;
                end
                // an entry written now is younger than this one
                for (int j = 0; j < N; j++) if (disp0[j] || disp1[j]) oq[j] <= 1'b0;
            end
        end
    end

endmodule : OOO_IQ
