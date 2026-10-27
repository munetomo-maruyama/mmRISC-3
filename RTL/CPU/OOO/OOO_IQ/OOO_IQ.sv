//---------------------------------------------------------------------------
// OOO_IQ.sv
//
// The issue queue of mmRISC-3 in the fusion configuration (STRATEGY.md 4):
// unified, N entries, up to 2 sources and 1 destination per µop (a fused
// pair too: OOO_FUSE SRC2 / W1, Plan/OOC.md 7.4), 2 µops written a cycle,
// 3 issued a cycle:
//   port 0  ALU0 (and MUL / DIV, and the ALU operations ALU1 does not have,
//           which only go here)
//   port 1  ALU1 (add / sub, slt / sltu, logic, branches: "any ALU" µops)
//   port 2  LSU
// Port 1 selects first (the oldest ready "any ALU" µop), then port 0 (the
// oldest ready ALU µop of the rest), so that a µop ALU1 can take does not
// keep ALU0 from one only ALU0 can take (G0b L7, Doc/UARCH.md 6.11: −0.3 %
// this way round, −6 % the other way).
// The selection and the wakeup close in one cycle (the loop that lets a
// dependent ALU µop issue in the cycle after its producer):
//   ready bits -> requests -> oldest first by an age matrix -> the issued
//   µops' destination tags -> compare against every source -> ready bits.
// Latency 1 (ALU) wakes in the same cycle as the select. Latency 2 (a load
// that is predicted to hit, a multiply) goes through one register first.
// External wakeups (a divide; AMO, LR, SC) come in on ext_*. Entries are
// freed when issued.
//
// A load is guessed to hit: its dependents are woken for 2 cycles after it
// and nothing takes them back here. When the load cannot give its result
// then (ld_cancel of the LSU: a miss, a wait), what ran on the guess may
// have a wrong value; the load completes marked, and the ROB commits it and
// fetches everything after it again (replay after commit, Doc/UARCH.md 6.3
// D-12, in place of the selective replay of Plan/OOC.md 15). With no
// entries kept for open loads, 10 entries do the work of 12 (the model).
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
// Mispredictions (OOO_CTRL, Doc/UARCH.md 6.14): every entry keeps the branch
// mask of its µop (the checkpoints older than it, disp_bm); kill (the
// restored checkpoint, one-hot) frees the entries whose mask has that bit,
// the µops younger than the branch, in the next state; clr (checkpoints
// resolved as predicted) clears bits in every mask. The issued µop's mask
// goes out (iss_bm) for the units, which drop what has a killed bit. flush
// (flush_all) frees every entry.
//
// The payload of a µop (operation, immediates, ROB index) is not here: it
// sits in a LUTRAM indexed by the entry (OOO_IQPL): disp_entry says where
// it is written, iss_entry where it is read.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_IQ
    #(
        parameter int N    = 10,     // G0b (Doc/UARCH.md 6.3, D-12)
        parameter int TAGW = 6,      // physical registers: 64
        parameter int NEXT = 2,      // external wakeup ports
        parameter int NCK  = 6       // checkpoints (branch-mask bits)
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,
        input  logic                  flush,      // flush_all: empty the queue
        input  logic [NCK-1:0]        kill,       // a restored checkpoint: its µops leave (one-hot)
        input  logic [NCK-1:0]        clr,        // checkpoints resolved as predicted

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
        input  logic [1:0][NCK-1:0]   disp_bm,    // branch masks (OOO_CTRL d_bmask)

        // external wakeups
        input  logic [NEXT-1:0]           ext_valid,
        input  logic [NEXT-1:0][TAGW-1:0] ext_tag,

        // issue
        output logic [2:0]            iss_valid,
        output logic [2:0][$clog2(N)-1:0] iss_entry,
        output logic [2:0][1:0][TAGW-1:0] iss_src,
        output logic [2:0]            iss_wr,
        output logic [2:0][TAGW-1:0]  iss_dst,
        output logic [2:0][NCK-1:0]   iss_bm      // the issued µops' branch masks (for the units)
    );

    localparam int EW = $clog2(N);
    localparam int NB = 4 + NEXT;    // broadcast tags (above)

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

    // ---- select
    logic [N-1:0] ready_all, req0, req1, req2, g0, g1, g2;
    always @(*) begin
        for (int i = 0; i < N; i++) begin
            ready_all[i] = v[i] && ((rdy[i] | ~use_s[i]) == 2'b11);
            req0[i] = ready_all[i] && (port[i] == 2'd0 || port[i] == 2'd1);
            req1[i] = ready_all[i] && (port[i] == 2'd0);
            req2[i] = ready_all[i] && (port[i] == 2'd2);
        end
        for (int i = 0; i < N; i++) begin
            g1[i] = req1[i] && ((req1 & older[i]) == '0);
            g2[i] = req2[i] && ((req2 & older[i]) == '0);
        end
        for (int i = 0; i < N; i++) begin
            g0[i] = req0[i] && !g1[i] && (((req0 & ~g1) & older[i]) == '0);
        end
    end

    function automatic logic [EW-1:0] enc(input logic [N-1:0] g);
        logic [EW-1:0] e;
        e = '0;
        for (int i = 0; i < N; i++) if (g[i]) e = EW'(i);
        return e;
    endfunction

    // the issued µops, by an AND-OR of the grants (one-hot); only port 0
    // issues both latencies
    logic lat2_0;
    always @(*) begin
        logic [N-1:0] g [3];
        g[0] = g0; g[1] = g1; g[2] = g2;
        for (int p = 0; p < 3; p++) begin
            iss_valid[p] = |g[p];
            iss_entry[p] = enc(g[p]);
            iss_src[p]   = '0;
            iss_dst[p]   = '0;
            iss_bm[p]    = '0;
            iss_wr[p]    = |(g[p] & wr);
            lat2_0       = |(g0 & lat2);
            for (int i = 0; i < N; i++) begin
                iss_src[p] = iss_src[p] | ({2*TAGW{g[p][i]}} & src[i]);
                iss_dst[p] = iss_dst[p] | ({TAGW{g[p][i]}} & dst[i]);
                iss_bm[p]  = iss_bm[p]  | ({NCK{g[p][i]}}  & bm[i] & ~clr);
            end
        end
    end

    // ---- wakeup tags: the µops issued now with latency 1, those issued one
    // cycle ago with latency 2, and the external ones
    logic                 d_v0, d_v2;
    logic [TAGW-1:0]      d_t0, d_t2;
    logic [NB-1:0]        bv;
    logic [NB-1:0][TAGW-1:0] bt;
    always @(*) begin
        bv[0] = iss_wr[0] && !lat2_0;       bt[0] = iss_dst[0];
        bv[1] = iss_wr[1];                  bt[1] = iss_dst[1];
        bv[2] = d_v0;                       bt[2] = d_t0;
        bv[3] = d_v2;                       bt[3] = d_t2;
        for (int e = 0; e < NEXT; e++) begin
            bv[4+e] = ext_valid[e];
            bt[4+e] = ext_tag[e];
        end
    end

    function automatic logic woken(input logic [TAGW-1:0] t);
        logic w;
        w = 1'b0;
        for (int b = 0; b < NB; b++) if (bv[b] && bt[b] == t) w = 1'b1;
        return w;
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

    // the latency-2 results issued now wake their dependents next cycle
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_v0 <= 1'b0;
            d_v2 <= 1'b0;
        end else begin
            d_v0 <= iss_wr[0] && lat2_0;
            d_v2 <= iss_wr[2];
        end
    end
    always_ff @(posedge clk) begin
        d_t0 <= iss_dst[0];
        d_t2 <= iss_dst[2];
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
        logic                 vq, lq, wq;
        logic [1:0]           pq, uq, rq;
        logic [1:0][TAGW-1:0] sq;
        logic [TAGW-1:0]      dq;
        logic [N-1:0]         oq;
        logic [NCK-1:0]       bq;
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

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                vq <= 1'b0;
            end else if (flush) begin
                vq <= 1'b0;
            end else if (disp0[i] || disp1[i]) begin
                automatic int d = disp1[i] ? 1 : 0;
                vq <= 1'b1;
                pq <= disp_port[d];
                uq <= disp_use[d];
                sq <= disp_src[d];
                for (int s = 0; s < 2; s++) rq[s] <= disp_rdy[d][s] || woken(disp_src[d][s]);
                wq <= disp_wr[d];
                dq <= disp_dst[d];
                lq <= disp_lat2[d];
                bq <= disp_bm[d];
                // age: younger than every entry that stays, and the second of a
                // pair younger than the first
                for (int j = 0; j < N; j++) oq[j] <= v[j] && !issued[j];
                if (disp1[i] && disp_valid[0] && fev[0]) oq[fe[0]] <= 1'b1;
            end else begin
                if (issued[i] || (bq & kill) != '0) vq <= 1'b0;
                bq <= bq & ~clr;
                for (int s = 0; s < 2; s++) if (woken(sq[s])) rq[s] <= 1'b1;
                // an entry written now is younger than this one
                for (int j = 0; j < N; j++) if (disp0[j] || disp1[j]) oq[j] <= 1'b0;
            end
        end
    end

endmodule : OOO_IQ
