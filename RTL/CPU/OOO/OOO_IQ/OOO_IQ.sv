//---------------------------------------------------------------------------
// OOO_IQ.sv
//
// The issue queue of mmRISC-3 in the fusion configuration (STRATEGY.md 4):
// unified, N entries, up to 3 sources per µop (a fused pair), 2 µops
// written a cycle, 3 issued a cycle:
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
// ext_*. Entries are freed when issued (a µop that has to be issued again
// waits outside, in the replay path of the LSU).
//
// The payload of a µop (operation, immediates, ROB index) is not here: it
// sits in a LUTRAM indexed by the entry, and iss_entry says which.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_IQ
    #(
        parameter int N    = 16,
        parameter int TAGW = 7,      // physical registers: 96
        parameter int NEXT = 2       // external wakeup ports
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,
        input  logic                  flush,      // misprediction: empty the queue

        // dispatch: up to 2 µops a cycle, in program order (0 the older)
        output logic [1:0]            disp_ready, // room for this many
        input  logic [1:0]            disp_valid,
        input  logic [1:0][1:0]       disp_port,  // 0 any ALU, 1 ALU0 only, 2 LSU
        input  logic [1:0][2:0]       disp_use,   // the sources the µop reads
        input  logic [1:0][2:0][TAGW-1:0] disp_src,
        input  logic [1:0][2:0]       disp_rdy,   // already ready at rename
        input  logic [1:0][1:0]       disp_wr,    // the destinations it writes (a pair: 2)
        input  logic [1:0][1:0][TAGW-1:0] disp_dst,
        input  logic [1:0]            disp_lat2,  // results after 2 cycles (load, multiply)

        // external wakeups
        input  logic [NEXT-1:0]           ext_valid,
        input  logic [NEXT-1:0][TAGW-1:0] ext_tag,

        // issue
        output logic [2:0]            iss_valid,
        output logic [2:0][$clog2(N)-1:0] iss_entry,
        output logic [2:0][2:0][TAGW-1:0] iss_src,
        output logic [2:0][1:0]       iss_wr,
        output logic [2:0][1:0][TAGW-1:0] iss_dst
    );

    localparam int EW = $clog2(N);
    localparam int NB = 3 * 2 + 3 * 2 + NEXT;   // broadcast tags: now (3 ports x 2), delayed (3 x 2), external

    // per entry; arrays (not packed vectors) where an entry is chosen at run time
    logic [N-1:0]                 v;
    logic [N-1:0]                 lat2;
    logic [1:0]                   port  [N];
    logic [2:0]                   use_s [N];
    logic [2:0][TAGW-1:0]         src   [N];
    logic [2:0]                   rdy   [N];
    logic [1:0]                   wr    [N];
    logic [1:0][TAGW-1:0]         dst   [N];
    logic [N-1:0]                 older [N];  // older[i][j]: entry j is older than entry i

    // ---- select
    logic [N-1:0] ready_all, req0, req1, req2, g0, g1, g2;
    always @(*) begin
        for (int i = 0; i < N; i++) begin
            ready_all[i] = v[i] && ((rdy[i] | ~use_s[i]) == 3'b111);
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

    always @(*) begin
        logic [N-1:0] g [3];
        g[0] = g0; g[1] = g1; g[2] = g2;
        for (int p = 0; p < 3; p++) begin
            iss_valid[p] = |g[p];
            iss_entry[p] = enc(g[p]);
            iss_src[p]   = src[iss_entry[p]];
            iss_wr[p]    = iss_valid[p] ? wr[iss_entry[p]] : 2'b00;
            iss_dst[p]   = dst[iss_entry[p]];
        end
    end

    // ---- wakeup tags: those of the µops issued now (latency 1), those
    // issued one cycle ago with latency 2, and the external ones
    logic [2:0][1:0]            d_wr;
    logic [2:0][1:0][TAGW-1:0]  d_dst;
    logic [NB-1:0]              bv;
    logic [NB-1:0][TAGW-1:0]    bt;
    always @(*) begin
        for (int p = 0; p < 3; p++)
            for (int k = 0; k < 2; k++) begin
                bv[p*2+k]     = iss_wr[p][k] && !lat2[iss_entry[p]];
                bt[p*2+k]     = iss_dst[p][k];
                bv[6+p*2+k]   = d_wr[p][k];
                bt[6+p*2+k]   = d_dst[p][k];
            end
        for (int e = 0; e < NEXT; e++) begin
            bv[12+e] = ext_valid[e];
            bt[12+e] = ext_tag[e];
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
    end

    // the latency-2 results issued now wake their dependents next cycle
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_wr <= '0;
        end else begin
            for (int p = 0; p < 3; p++) begin
                d_wr[p]  <= (iss_valid[p] && lat2[iss_entry[p]]) ? iss_wr[p] : 2'b00;
                d_dst[p] <= iss_dst[p];
            end
        end
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
        logic                vq, lq;
        logic [1:0]          pq, wq;
        logic [2:0]          uq, rq;
        logic [2:0][TAGW-1:0] sq;
        logic [1:0][TAGW-1:0] dq;
        logic [N-1:0]        oq;
        assign v[i]     = vq;
        assign lat2[i]  = lq;
        assign port[i]  = pq;
        assign use_s[i] = uq;
        assign src[i]   = sq;
        assign rdy[i]   = rq;
        assign wr[i]    = wq;
        assign dst[i]   = dq;
        assign older[i] = oq;

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
                for (int s = 0; s < 3; s++) rq[s] <= disp_rdy[d][s] || woken(disp_src[d][s]);
                wq <= disp_wr[d];
                dq <= disp_dst[d];
                lq <= disp_lat2[d];
                // age: younger than every entry that stays, and the second of a
                // pair younger than the first
                for (int j = 0; j < N; j++) oq[j] <= v[j] && !issued[j];
                if (disp1[i] && disp_valid[0] && fev[0]) oq[fe[0]] <= 1'b1;
            end else begin
                if (issued[i]) vq <= 1'b0;
                for (int s = 0; s < 3; s++) if (woken(sq[s])) rq[s] <= 1'b1;
                // an entry written now is younger than this one
                for (int j = 0; j < N; j++) if (disp0[j] || disp1[j]) oq[j] <= 1'b0;
            end
        end
    end

endmodule : OOO_IQ
