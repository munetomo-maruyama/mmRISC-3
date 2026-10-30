//---------------------------------------------------------------------------
// OOO_RENAME.sv
//
// Register renaming of mmRISC-3 in the fusion configuration (STRATEGY.md
// 4): 2 µops a cycle, each with up to 2 sources and 1 destination (a fused
// pair reads at most 2 registers and writes at most 1, OOO_FUSE SRC2 / W1,
// Plan/OOC.md 7.4).
//
//   RAT        32 x TAGW in flip-flops (4 source reads, 2 old-mapping reads
//              and 2 writes a cycle are too many ports for distributed RAM;
//              192 bits)
//   free list  a ring of NREG - 32 tags (a power of two; with one register
//              per µop and a ROB of 32, 64 registers never run out): up to 2
//              taken a cycle at rename, up to 2 given back a cycle at commit
//              (the old mappings). head / tail carry one wrap bit, so the
//              number of free registers is tail - head and stays right
//              across a restore
//   busy bits  NREG: set when a register is given out, cleared when its
//              producer wakes its dependents (the issue queue's wakeup
//              tags, OOO_IQ wk_*: Plan/OOC.md 20); rename reads them to tell
//              the issue queue which sources are ready already. Cleared at
//              the write-back instead, a µop renamed between the wakeup and
//              the write would wait for a wakeup that has gone (the DS
//              register covers only the cycles from renaming to dispatch,
//              OOO_DSREG)
//   in-group   a source of µop 1 that is µop 0's destination takes µop 0's
//              new tag (and is not ready)
//   checkpoints NCKPT copies of the RAT and of the free list's head, for a
//              µop with a control transfer; a misprediction restores one
//              (the registers given out after it come back by moving the
//              head back: the ring order makes them the right ones). They
//              are given out in a ring of NCKPT (6 in G0, not a power of
//              two); the pipeline keeps at most NCKPT unresolved
//
// A checkpoint copies the RAT one cycle late, from the RAT flip-flops: the
// state after both µops of the group. A checkpoint of µop 0 also keeps what
// undoes µop 1's destination (its register and old mapping), applied on a
// restore. So every checkpoint bit takes the same data with an enable,
// instead of a choice between the state after µop 0 and after µop 1 (Plan/
// OOC.md 10). It needs a checkpoint not to be restored in the cycle right
// after its µop is renamed, which the pipeline guarantees (dispatch, issue
// and execution come between).
//
// The committed state (Plan/OOC.md 11.4): the RAT of the committed µops
// (arat, written at commit: cmt_*) and the committed head of the free list
// (chead, advanced by every committed allocation; cmt_wr is set only for
// one, so never for x0). flush_all (a trap, a serialization) goes back to
// it: RAT = arat, head = chead. The busy bits need nothing (bug injection
// showed clearing them redundant): every register in arat was woken for
// before its µop committed, and a free register's bit is set again when it
// is given out.
//
// x0 maps to physical register 0 forever, is never given out and is always
// ready. Rename stalls (ready = 0) when the free list cannot cover the
// destinations of both µops offered, and in the cycle of a restore. ready
// counts the destinations from in_wr / in_dst, not from in_valid: in the
// core in_valid is the control's r_go, which waits for ready (the caller
// gives in_wr only for a µop it offers; Plan/CORE.md 5.4). For the same
// reason µop 1's checkpoint id counts µop 0's checkpoint as offered.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_RENAME
    #(
        parameter int NREG  = 64,
        parameter int TAGW  = 6,
        parameter int NCKPT = 6,        // G0 (Doc/UARCH.md 3.4)
        parameter int NWK   = 6      // wakeup buses that clear busy bits (OOO_IQ wk_*)
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // the 2 µops of this cycle (0 the older)
        output logic                        ready,
        input  logic [1:0]                  in_valid,
        input  logic [1:0][1:0]             in_use,      // sources used
        input  logic [1:0][1:0][4:0]        in_src,      // architectural
        input  logic [1:0]                  in_wr,       // the destination is written
        input  logic [1:0][4:0]             in_dst,
        input  logic [1:0]                  in_ckpt,     // take a checkpoint after this µop
        output logic [1:0][$clog2(NCKPT)-1:0] out_ckpt_id,

        output logic [1:0][1:0][TAGW-1:0]   out_src,     // physical
        output logic [1:0][1:0]             out_rdy,
        output logic [1:0][TAGW-1:0]        out_dst,
        output logic [1:0][TAGW-1:0]        out_old,     // the previous mapping, freed at commit

        // write-back: the value of a register is there
        input  logic [NWK-1:0]              wk_valid,
        input  logic [NWK-1:0][TAGW-1:0]    wk_tag,

        // commit: old mappings back to the free list (up to 2 a cycle)
        input  logic [1:0]                  free_valid,
        input  logic [1:0][TAGW-1:0]        free_tag,

        // misprediction: back to a checkpoint
        input  logic                        restore,
        input  logic [$clog2(NCKPT)-1:0]    restore_id,

        // commit: the committed-state RAT (from the ROB), and the full flush
        input  logic [1:0]                  cmt_valid,
        input  logic [1:0]                  cmt_wr,
        input  logic [1:0][4:0]             cmt_arch,
        input  logic [1:0][TAGW-1:0]        cmt_new,
        input  logic                        flush_all
    );

    localparam int NF = NREG - 32;
    localparam int FW = $clog2(NF);
    localparam int CW = $clog2(NCKPT);

    initial begin
        if ((1 << FW) != NF) $error("OOO_RENAME: NREG - 32 must be a power of two");
    end

    // arrays (not packed vectors) where an entry is chosen at run time
    logic [TAGW-1:0]         rat    [32];
    logic [TAGW-1:0]         fl     [NF]; // free list ring
    logic [FW:0]             head, tail;  // with a wrap bit
    logic [TAGW-1:0]         arat   [32]; // the committed state
    logic [FW:0]             chead;
    logic [FW:0]             nfree;
    logic [NREG-1:0]         busy;
    logic [TAGW-1:0]         ck_rat [NCKPT][32];
    logic [FW:0]             ck_head[NCKPT];
    logic [NCKPT-1:0]        fx_v;        // undo µop 1's destination on a restore
    logic [4:0]              fx_a   [NCKPT];
    logic [TAGW-1:0]         fx_t   [NCKPT];
    logic [CW-1:0]           ck_next;
    logic [1:0]              pk_v;        // the checkpoints to copy the RAT into this cycle
    logic [1:0][CW-1:0]      pk_id;

    assign nfree = tail - head;

    // the checkpoint ring: a + n modulo NCKPT (n is 0 to 2)
    function automatic logic [CW-1:0] cadd(input logic [CW-1:0] a, input logic [1:0] n);
        logic [CW:0] s;
        s = {1'b0, a} + (CW + 1)'(n);
        if (s >= (CW + 1)'(NCKPT)) s = s - (CW + 1)'(NCKPT);
        return s[CW-1:0];
    endfunction

    // allocation: µop 0 takes the register at the head, µop 1 the next one
    // (or the head, when µop 0 writes none)
    logic [1:0]           want, alloc;
    logic [1:0]           want_n, need;
    logic [1:0][TAGW-1:0] new_tag;
    // ready from the destinations offered, apart from in_valid (it waits for ready)
    always @(*) begin
        for (int u = 0; u < 2; u++) want[u] = in_wr[u] && in_dst[u] != 5'd0;
        want_n = 2'(want[0]) + 2'(want[1]);
    end
    assign ready = (nfree >= (FW + 1)'(want_n)) && !restore && !flush_all;
    always @(*) begin
        for (int u = 0; u < 2; u++) alloc[u] = in_valid[u] && want[u];
        need       = 2'(alloc[0]) + 2'(alloc[1]);
        new_tag[0] = alloc[0] ? fl[head[FW-1:0]] : '0;
        new_tag[1] = alloc[1] ? fl[FW'(head + (FW + 1)'(alloc[0]))] : '0;
    end

    // rename
    always @(*) begin
        for (int u = 0; u < 2; u++) begin
            for (int s = 0; s < 2; s++) begin
                out_src[u][s] = rat[in_src[u][s]];
                out_rdy[u][s] = !in_use[u][s] || in_src[u][s] == 5'd0 || !busy[out_src[u][s]];
            end
            out_dst[u] = new_tag[u];
            out_old[u] = rat[in_dst[u]];
        end
        // µop 1 sees µop 0's destination
        for (int s = 0; s < 2; s++)
            if (alloc[0] && in_dst[0] == in_src[1][s]) begin
                out_src[1][s] = new_tag[0];
                out_rdy[1][s] = 1'b0;
            end
        if (alloc[0] && in_dst[0] == in_dst[1]) out_old[1] = new_tag[0];
        out_ckpt_id[0] = ck_next;
        out_ckpt_id[1] = cadd(ck_next, 2'(in_ckpt[0]));   // (µop 1 goes only with µop 0: not from in_valid, which waits for these ids)
    end

    logic go;
    assign go = ready && (in_valid != 2'b00);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int a = 0; a < 32; a++) rat[a] <= TAGW'(a);     // x_a in p_a at reset
            for (int f = 0; f < NF; f++) fl[f] <= TAGW'(32 + f);
            head    <= '0;
            tail    <= (FW + 1)'(NF);                          // all NF free
            busy    <= '0;
            ck_next <= '0;
            pk_v    <= '0;
            chead   <= '0;
            for (int a = 0; a < 32; a++) arat[a] <= TAGW'(a);
        end else begin
            logic [FW:0] t;
            // a wakeup clears busy (a register given out now is set below)
            for (int w = 0; w < NWK; w++) if (wk_valid[w]) busy[wk_tag[w]] <= 1'b0;
            // commit returns registers at the tail
            t = tail;
            for (int k = 0; k < 2; k++)
                if (free_valid[k]) begin fl[t[FW-1:0]] <= free_tag[k]; t = t + (FW + 1)'(1); end
            tail <= t;
            pk_v <= '0;
            // the committed state
            for (int u = 0; u < 2; u++)
                if (cmt_valid[u] && cmt_wr[u]) arat[cmt_arch[u]] <= cmt_new[u];
            chead <= chead + (FW + 1)'(cmt_valid[0] && cmt_wr[0]) + (FW + 1)'(cmt_valid[1] && cmt_wr[1]);
            if (flush_all) begin
                for (int a = 0; a < 32; a++) rat[a] <= arat[a];
                head <= chead;
            end else if (restore) begin
                for (int a = 0; a < 32; a++)
                    rat[a] <= (fx_v[restore_id] && fx_a[restore_id] == 5'(a)) ? fx_t[restore_id]
                                                                               : ck_rat[restore_id][a];
                head    <= ck_head[restore_id];
                ck_next <= cadd(restore_id, 2'd1);
            end else if (go) begin
                for (int u = 0; u < 2; u++)
                    if (alloc[u]) begin
                        rat[in_dst[u]]   <= new_tag[u];
                        busy[new_tag[u]] <= 1'b1;
                    end
                head <= head + (FW + 1)'(need);
                for (int u = 0; u < 2; u++)
                    if (in_valid[u] && in_ckpt[u]) begin
                        ck_head[out_ckpt_id[u]] <= head + ((u == 0) ? (FW + 1)'(alloc[0]) : (FW + 1)'(need));
                        fx_v[out_ckpt_id[u]]    <= (u == 0) && alloc[1];
                        fx_a[out_ckpt_id[u]]    <= in_dst[1];
                        fx_t[out_ckpt_id[u]]    <= out_old[1];
                    end
                pk_v    <= in_valid & in_ckpt;
                pk_id   <= out_ckpt_id;
                ck_next <= cadd(ck_next, 2'(in_valid[0] && in_ckpt[0]) + 2'(in_valid[1] && in_ckpt[1]));
            end
        end
    end

    // the copies of the RAT, a cycle late: the same data for every checkpoint
    for (genvar c = 0; c < NCKPT; c++) begin : g_ck
        always_ff @(posedge clk)
            if ((pk_v[0] && pk_id[0] == CW'(c)) || (pk_v[1] && pk_id[1] == CW'(c)))
                for (int a = 0; a < 32; a++) ck_rat[c][a] <= rat[a];
    end

endmodule : OOO_RENAME
