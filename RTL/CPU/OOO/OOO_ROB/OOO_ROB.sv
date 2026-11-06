//---------------------------------------------------------------------------
// OOO_ROB.sv
//
// The reorder buffer of mmRISC-3 (Doc/UARCH.md 3.5): NROB µops (a fused
// pair is one), up to ND written a cycle at dispatch and up to ND committed a
// cycle in program order (ND 2, or 4 for the 4-wide core: Plan/OOC.md 29.19).
//
//   payload   what commit needs and nothing changes after dispatch: pc, the
//             architectural destination and its new and old physical
//             registers, load / store / fused / non-speculative flags. In
//             LUTRAM, ND banks by the index modulo ND: the µops of a
//             dispatch and those of a commit are always consecutive, so each
//             bank has one write and one read a cycle
//   status    done, exception and its cause, in flip-flops (written by the
//             NCMP completion ports)
//
// Completion: a unit reports a µop done (with an exception or not) by its
// ROB index. Branches are resolved on the two ALU ports: of the
// mispredicted ones in a cycle the oldest wins; the ROB gives restore with
// its index and checkpoint (for renaming, the LSU and the front end) and
// cuts its tail back to just after it. A misprediction of an entry no
// longer in the ROB is ignored. A completion needs no such check (bug
// injection showed it redundant): an entry not in the ROB is cleared when
// it is given out again; the units drop what they have in flight for
// flushed µops. Dispatch in a cycle of trap or restore writes only entries
// beyond the new tail (cleared when given out), so it needs no gate.
//
// Commit: from the head, up to 2 µops that are done and have no exception,
// in order. A µop marked non-speculative (CSR, AMO, MMIO load and so on,
// 3.9) runs only at the head: head_ns says the head is one that has not run
// yet. An exception at the head is a trap: trap gives its cause and pc, and
// the ROB empties (flush_all for the rest of the core). A trap wins over a
// restore in the same cycle. irq (OOO_TRAP) takes an interrupt before the
// head: nothing commits, and the ROB empties as for a trap (head_fused
// tells OOO_TRAP that an exception at the head is inside a fused pair).
//
// Replay after commit (Doc/UARCH.md 6.3, D-12): a load that could not give
// its result in its expected cycle (ld_cancel) had its dependents woken on
// a guess, so what follows it may have run on a wrong value. Its completion
// comes marked (cmp_rp); it commits like any µop, nothing younger commits
// with it, and replay empties the ROB (flush_all) with the pc of the next
// instruction (replay_pc = its pc + its length, disp_len in halfwords), from
// where the front end fetches again. The load itself is not run again (a
// peripheral read happens once). Order: trap, then replay, then restore.
//
// The commit outputs feed the committed-state RAT and the free list
// (renaming), the LQ / SQ (counts), the FTQ's pops (the µop's fetch block,
// cmt_ftq: OOO_CTRL pops the blocks before the latest one committed) and
// the commit trace (pc, lock-step).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_ROB
    #(
        parameter int NROB = 24,       // a multiple of ND (the banks)
        parameter int ND   = 2,        // dispatched and committed a cycle: 2 or 4
        parameter int ROBW = 5,
        parameter int VA   = 39,
        parameter int TAGW = 6,
        parameter int CW   = 3,        // checkpoint index
        parameter int NCMP = 4,        // completion ports
        parameter int FTQW = 4         // FTQ index
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // dispatch (a prefix of the slots)
        output logic [2:0]                  rob_avail,   // free entries, 0 .. ND
        input  logic [ND-1:0]                  disp_valid,
        input  logic [ND-1:0][VA-1:1]          disp_pc,
        input  logic [ND-1:0]                  disp_wr,     // writes an architectural register
        input  logic [ND-1:0][4:0]             disp_arch,
        input  logic [ND-1:0][TAGW-1:0]        disp_new,
        input  logic [ND-1:0][TAGW-1:0]        disp_old,
        input  logic [ND-1:0]                  disp_ld,
        input  logic [ND-1:0]                  disp_st,
        input  logic [ND-1:0]                  disp_fused,  // two instructions
        input  logic [ND-1:0]                  disp_ns,     // non-speculative: runs at the head
        input  logic [ND-1:0][2:0]             disp_len,    // halfwords of the µop (1 .. 4)
        input  logic [ND-1:0][FTQW-1:0]        disp_ftq,    // its fetch block (of its last half: Plan/OOC.md 21)
        input  logic [ND-1:0]                  disp_exc,    // an exception known at decode
        input  logic [ND-1:0][4:0]             disp_cause,
        output logic [ND-1:0][ROBW-1:0]        disp_rob,

        // completion
        input  logic [NCMP-1:0]             cmp_valid,
        input  logic [NCMP-1:0][ROBW-1:0]   cmp_rob,
        input  logic [NCMP-1:0]             cmp_exc,
        input  logic [NCMP-1:0][4:0]        cmp_cause,
        input  logic [NCMP-1:0]             cmp_rp,      // replay after commit (a load that raised ld_cancel)

        // branch resolution (ALU ports)
        input  logic [1:0]                  br_valid,
        input  logic [1:0][ROBW-1:0]        br_rob,
        input  logic [1:0]                  br_mispred,
        input  logic [1:0][CW-1:0]          br_ckpt,
        output logic                        restore,
        output logic [ROBW-1:0]             restore_rob,
        output logic [CW-1:0]               restore_ckpt,

        // the head
        output logic [ROBW-1:0]             head_rob,
        output logic                        head_ns,     // a non-speculative µop at the head, not run yet
        output logic                        head_valid,  // the ROB is not empty
        output logic                        head_fused,  // the head is a fused pair
        input  logic                        irq,         // OOO_TRAP: take an interrupt before the head now

        // commit
        output logic [ND-1:0]                  cmt_valid,
        output logic [ND-1:0]                  cmt_wr,
        output logic [ND-1:0][4:0]             cmt_arch,
        output logic [ND-1:0][TAGW-1:0]        cmt_new,
        output logic [ND-1:0][TAGW-1:0]        cmt_old,
        output logic [ND-1:0][VA-1:1]          cmt_pc,
        output logic [ND-1:0][FTQW-1:0]        cmt_ftq,
        output logic [2:0]                   cmt_ld_n,    // loads committed now
        output logic [2:0]                   cmt_st_n,    // stores committed now
        output logic [3:0]                  cmt_instret, // instructions (a fused pair counts 2)
        output logic                        trap,        // the head has an exception: flush_all
        output logic [4:0]                  trap_cause,
        output logic [VA-1:1]               trap_pc,
        output logic                        replay,      // a marked µop commits now: flush_all after it
        output logic [VA-1:1]               replay_pc,   // the next instruction, fetched again
        output logic [FTQW-1:0]             rcv_ftq,     // the trapping / replayed µop's block (OOO_FERS)
        output logic [2:0]                  rcv_end      // and the parcel of its last half
    );

    localparam int H  = NROB / ND;             // entries in a bank
    localparam int HW = $clog2(H);
    localparam int BW = $clog2(ND);
    typedef logic [ROBW:0] ptr_t;              // {wrap, index}

    function automatic ptr_t nxt(input ptr_t p, input logic [2:0] n);
        ptr_t q;
        q = p;
        for (int k = 0; k < ND; k++)
            if (n > 3'(k)) q = (q[ROBW-1:0] == ROBW'(NROB - 1)) ? {~q[ROBW], ROBW'(0)} : {q[ROBW], q[ROBW-1:0] + ROBW'(1)};
        return q;
    endfunction
    function automatic logic [ROBW:0] cnt(input ptr_t a, input ptr_t b);
        return (a[ROBW] == b[ROBW]) ? (ROBW + 1)'(b[ROBW-1:0] - a[ROBW-1:0])
                                    : (ROBW + 1)'(NROB) + (ROBW + 1)'(b[ROBW-1:0]) - (ROBW + 1)'(a[ROBW-1:0]);
    endfunction
    // entry i's distance from index h (0 .. NROB-1)
    function automatic logic [ROBW-1:0] rdist(input logic [ROBW-1:0] i, input logic [ROBW-1:0] h);
        return (i >= h) ? ROBW'(i - h) : ROBW'(i + ROBW'(NROB) - h);
    endfunction
    // an index's bank and row: the index modulo ND and divided by it
    function automatic logic [BW-1:0] bk(input logic [ROBW-1:0] i);
        return BW'(i % ROBW'(ND));
    endfunction
    function automatic logic [HW-1:0] rw(input logic [ROBW-1:0] i);
        return HW'(i / ROBW'(ND));
    endfunction

    ptr_t head, tail;
    logic [ROBW:0] used;
    assign used = cnt(head, tail);
    always @(*) begin
        automatic logic [ROBW:0] fr = (ROBW + 1)'(NROB) - used;
        rob_avail = fr >= (ROBW + 1)'(ND) ? 3'(ND) : 3'(fr);
    end

    // ---- payload: ND banks by the index modulo ND, written at dispatch, read at commit
    localparam int PW = (VA - 1) + 1 + 5 + 2 * TAGW + 4 + 3 + FTQW;
    typedef logic [PW-1:0] pay_t;
    function automatic pay_t pack(input int u);
        return {disp_pc[u], disp_wr[u], disp_arch[u], disp_new[u], disp_old[u],
                disp_ld[u], disp_st[u], disp_fused[u], disp_ns[u], disp_len[u], disp_ftq[u]};
    endfunction

    ptr_t tk [ND];                             // tail + k, head + k
    ptr_t hk [ND];
    always @(*) begin
        for (int k = 0; k < ND; k++) begin
            tk[k] = nxt(tail, 3'(k));
            hk[k] = nxt(head, 3'(k));
            disp_rob[k] = tk[k][ROBW-1:0];
        end
    end

    // one write a bank: the slot whose entry falls in it. Written as several writes
    // into one array, Vivado took them for as many write ports and built the payload
    // of flip-flops (Plan/OOC.md 12.6)
    pay_t pk [ND];                             // the payloads of head .. head + ND - 1
    pay_t rdv [ND][ND];                        // bank b's read for the head's k-th
    for (genvar b = 0; b < ND; b++) begin : g_bank
        (* ram_style = "distributed" *) pay_t mem [H];
        logic          we;
        logic [HW-1:0] wa;
        pay_t          wd;
        always @(*) begin
            we = 1'b0; wa = '0; wd = '0;
            for (int k = 0; k < ND; k++)
                if (bk(tk[k][ROBW-1:0]) == BW'(b)) begin
                    we = disp_valid[k]; wa = rw(tk[k][ROBW-1:0]); wd = pack(k);
                end
        end
        always_ff @(posedge clk) if (we) mem[wa] <= wd;
        // the head's k-th: in bank (head + k) mod ND
        for (genvar k = 0; k < ND; k++) begin : g_rd
            logic [ROBW-1:0] hi;
            pay_t            q;
            assign hi = hk[k][ROBW-1:0];
            assign q  = mem[rw(hi)];
        end
    end
    always @(*) begin
        for (int k = 0; k < ND; k++) pk[k] = '0;
        for (int k = 0; k < ND; k++)
            for (int b = 0; b < ND; b++)
                if (bk(hk[k][ROBW-1:0]) == BW'(b)) pk[k] = rdv[b][k];
    end
    for (genvar b = 0; b < ND; b++) begin : g_rv
        for (genvar k = 0; k < ND; k++) begin : g_k
            assign rdv[b][k] = g_bank[b].g_rd[k].q;
        end
    end

    // ---- status
    logic [NROB-1:0] done, exc, rp;
    logic [4:0]      cause [NROB];

    // in the ROB now: between head and tail
    function automatic logic live(input logic [ROBW-1:0] i);
        return rdist(i, head[ROBW-1:0]) < ROBW'(used) || used == (ROBW + 1)'(NROB);
    endfunction

    // ---- the head and commit
    logic [ROBW-1:0] hi [ND];
    logic [ND-1:0]   c;                        // commits now
    logic [ND-1:0]   crp;                      // ... and is marked for replay
    logic [2:0]      nc;
    always @(*) begin
        for (int k = 0; k < ND; k++) hi[k] = hk[k][ROBW-1:0];
        for (int k = 0; k < ND; k++) begin
            c[k]   = (k == 0 ? !irq : c[k-1] && !rp[hi[k-1]]) && used > (ROBW + 1)'(k) && done[hi[k]] && !exc[hi[k]];
            crp[k] = c[k] && rp[hi[k]];
        end
        nc = '0;
        for (int k = 0; k < ND; k++) nc = nc + 3'(c[k]);
        trap       = used != '0 && done[hi[0]] && exc[hi[0]];
        trap_cause = cause[hi[0]];
        trap_pc    = pk[0][PW-1 -: VA-1];
        replay     = crp != '0;
        replay_pc  = '0;
        for (int k = ND - 1; k >= 0; k--)
            if (crp[k]) replay_pc = pk[k][PW-1 -: VA-1] + (VA - 1)'(pk[k][FTQW+2:FTQW]);
        head_rob   = hi[0];
        head_ns    = used != '0 && pk[0][FTQW+3] && !done[hi[0]];
        head_valid = used != '0;
        head_fused = pk[0][FTQW+4];
        // the µop the front end's history and RAS go back to (OOO_FERS): the
        // head for a trap, the marked one for a replay
        begin
            /* verilator lint_off UNUSEDSIGNAL */
            pay_t          pr;              // (its pc's parcel, length and block only)
            logic [VA-1:1] ppc;
            /* verilator lint_on UNUSEDSIGNAL */
            pr = pk[0];
            if (!(trap || irq))
                for (int k = ND - 1; k >= 0; k--) if (crp[k]) pr = pk[k];
            ppc     = pr[PW-1 -: VA-1];
            rcv_ftq = pr[FTQW-1:0];
            rcv_end = ppc[3:1] + pr[FTQW+2:FTQW] - 3'd1;
        end
        cmt_valid   = c;
        cmt_ld_n    = '0;
        cmt_st_n    = '0;
        cmt_instret = '0;
        for (int u = 0; u < ND; u++) begin
            cmt_pc[u]   = pk[u][PW-1 -: VA-1];
            cmt_wr[u]   = pk[u][PW-VA];
            cmt_arch[u] = pk[u][PW-VA-1 -: 5];
            cmt_new[u]  = pk[u][PW-VA-6 -: TAGW];
            cmt_old[u]  = pk[u][PW-VA-6-TAGW -: TAGW];
            cmt_ftq[u]  = pk[u][FTQW-1:0];
            cmt_ld_n    = cmt_ld_n + 3'(c[u] && pk[u][FTQW+6]);
            cmt_st_n    = cmt_st_n + 3'(c[u] && pk[u][FTQW+5]);
            cmt_instret = cmt_instret + (c[u] ? (pk[u][FTQW+4] ? 4'd2 : 4'd1) : 4'd0);
        end
    end

    // ---- branch resolution: the oldest mispredicted one in the ROB
    logic           r0, r1;
    always @(*) begin
        r0 = br_valid[0] && br_mispred[0] && live(br_rob[0]);
        r1 = br_valid[1] && br_mispred[1] && live(br_rob[1]);
        if (r0 && (!r1 || rdist(br_rob[0], hi[0]) <= rdist(br_rob[1], hi[0]))) begin
            restore_rob = br_rob[0]; restore_ckpt = br_ckpt[0];
        end else begin
            restore_rob = br_rob[1]; restore_ckpt = br_ckpt[1];
        end
        restore = (r0 || r1) && !trap && !irq && !replay;
    end

    // ---- pointers
    ptr_t head_n, tail_n;
    always @(*) begin
        automatic logic [2:0] nd = '0;
        for (int k = 0; k < ND; k++) nd = nd + 3'(disp_valid[k]);
        head_n = nxt(head, nc);
        if (trap || irq) begin
            tail_n = head;                     // empty
        end else if (replay) begin
            tail_n = head_n;                   // empty after the commits
        end else if (restore) begin
            // just after the branch: its index with the wrap bit of its lap
            // (the head's, or the next one if it lies before the head)
            tail_n = nxt({(restore_rob >= hi[0]) ? head[ROBW] : ~head[ROBW], restore_rob}, 3'd1);
        end else begin
            tail_n = nxt(tail, nd);
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= '0;
            tail <= '0;
        end else begin
            head <= (trap || irq) ? head : head_n;
            tail <= tail_n;
        end
    end

    // ---- status writes: new entries cleared, completions set
    for (genvar i = 0; i < NROB; i++) begin : g_ent
        logic         nw;
        logic [BW-1:0] sl;                     // the slot that writes it
        always @(*) begin
            nw = 1'b0; sl = '0;
            for (int k = 0; k < ND; k++)
                if (disp_valid[k] && tk[k][ROBW-1:0] == ROBW'(i)) begin nw = 1'b1; sl = BW'(k); end
        end
        always_ff @(posedge clk) begin
            if (nw) begin
                done[i]  <= disp_exc[sl];                       // an exception at decode is done at once
                exc[i]   <= disp_exc[sl];
                cause[i] <= disp_cause[sl];
                rp[i]    <= 1'b0;
            end else begin
                for (int c2 = 0; c2 < NCMP; c2++)
                    if (cmp_valid[c2] && cmp_rob[c2] == ROBW'(i)) begin
                        done[i] <= 1'b1;
                        if (cmp_exc[c2]) begin exc[i] <= 1'b1; cause[i] <= cmp_cause[c2]; end
                        if (cmp_rp[c2])  rp[i] <= 1'b1;
                    end
            end
        end
    end

endmodule : OOO_ROB
