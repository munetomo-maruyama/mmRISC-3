//---------------------------------------------------------------------------
// OOO_ROB.sv
//
// The reorder buffer of mmRISC-3 (Doc/UARCH.md 3.5): NROB µops (a fused
// pair is one), up to 2 written a cycle at dispatch and up to 2 committed a
// cycle in program order.
//
//   payload   what commit needs and nothing changes after dispatch: pc, the
//             architectural destination and its new and old physical
//             registers, load / store / fused / non-speculative flags. In
//             LUTRAM, two banks by the parity of the index: the 2 µops of a
//             dispatch and the 2 of a commit are always consecutive, so each
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
        parameter int NROB = 24,       // even (two banks)
        parameter int ROBW = 5,
        parameter int VA   = 39,
        parameter int TAGW = 6,
        parameter int CW   = 3,        // checkpoint index
        parameter int NCMP = 4,        // completion ports
        parameter int FTQW = 3         // FTQ index
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // dispatch (slot 1 only with slot 0)
        output logic [1:0]                  rob_avail,   // free entries, 0 .. 2
        input  logic [1:0]                  disp_valid,
        input  logic [1:0][VA-1:1]          disp_pc,
        input  logic [1:0]                  disp_wr,     // writes an architectural register
        input  logic [1:0][4:0]             disp_arch,
        input  logic [1:0][TAGW-1:0]        disp_new,
        input  logic [1:0][TAGW-1:0]        disp_old,
        input  logic [1:0]                  disp_ld,
        input  logic [1:0]                  disp_st,
        input  logic [1:0]                  disp_fused,  // two instructions
        input  logic [1:0]                  disp_ns,     // non-speculative: runs at the head
        input  logic [1:0][2:0]             disp_len,    // halfwords of the µop (1 .. 4)
        input  logic [1:0][FTQW-1:0]        disp_ftq,    // its fetch block (of its last half: Plan/OOC.md 21)
        input  logic [1:0]                  disp_exc,    // an exception known at decode
        input  logic [1:0][4:0]             disp_cause,
        output logic [1:0][ROBW-1:0]        disp_rob,

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
        output logic [1:0]                  cmt_valid,
        output logic [1:0]                  cmt_wr,
        output logic [1:0][4:0]             cmt_arch,
        output logic [1:0][TAGW-1:0]        cmt_new,
        output logic [1:0][TAGW-1:0]        cmt_old,
        output logic [1:0][VA-1:1]          cmt_pc,
        output logic [1:0][FTQW-1:0]        cmt_ftq,
        output logic [1:0]                  cmt_ld_n,    // loads committed now
        output logic [1:0]                  cmt_st_n,    // stores committed now
        output logic [2:0]                  cmt_instret, // instructions (a fused pair counts 2)
        output logic                        trap,        // the head has an exception: flush_all
        output logic [4:0]                  trap_cause,
        output logic [VA-1:1]               trap_pc,
        output logic                        replay,      // a marked µop commits now: flush_all after it
        output logic [VA-1:1]               replay_pc,   // the next instruction, fetched again
        output logic [FTQW-1:0]             rcv_ftq,     // the trapping / replayed µop's block (OOO_FERS)
        output logic [2:0]                  rcv_end      // and the parcel of its last half
    );

    localparam int H  = NROB / 2;
    localparam int HW = $clog2(H);
    typedef logic [ROBW:0] ptr_t;              // {wrap, index}

    function automatic ptr_t nxt(input ptr_t p, input logic [1:0] n);
        ptr_t q;
        q = p;
        for (int k = 0; k < 2; k++)
            if (n > 2'(k)) q = (q[ROBW-1:0] == ROBW'(NROB - 1)) ? {~q[ROBW], ROBW'(0)} : {q[ROBW], q[ROBW-1:0] + ROBW'(1)};
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

    ptr_t head, tail;
    logic [ROBW:0] used;
    assign used = cnt(head, tail);
    assign rob_avail = (used <= (ROBW + 1)'(NROB - 2)) ? 2'd2 : (used == (ROBW + 1)'(NROB - 1)) ? 2'd1 : 2'd0;

    // ---- payload: two banks by parity, written at dispatch, read at commit
    localparam int PW = (VA - 1) + 1 + 5 + 2 * TAGW + 4 + 3 + FTQW;
    typedef logic [PW-1:0] pay_t;
    function automatic pay_t pack(input int u);
        return {disp_pc[u], disp_wr[u], disp_arch[u], disp_new[u], disp_old[u],
                disp_ld[u], disp_st[u], disp_fused[u], disp_ns[u], disp_len[u], disp_ftq[u]};
    endfunction
    (* ram_style = "distributed" *) pay_t bank0 [H];
    (* ram_style = "distributed" *) pay_t bank1 [H];

    /* verilator lint_off UNUSEDSIGNAL */
    ptr_t t1, h1;                              // tail + 1, head + 1 (their wrap bits not needed)
    /* verilator lint_on UNUSEDSIGNAL */
    assign t1 = nxt(tail, 2'd1);
    assign disp_rob[0] = tail[ROBW-1:0];
    assign disp_rob[1] = t1[ROBW-1:0];

    // one write a bank, its slot chosen first: tail and tail + 1 have
    // different parities, so bank 0 takes slot 0 when the tail is even and
    // slot 1 when it is odd (and bank 1 the other). Written as two writes
    // into one bank, Vivado took them for two write ports and built the
    // payload of flip-flops (Plan/OOC.md 12.6)
    logic          we0, we1;
    logic [HW-1:0] wa0, wa1;
    pay_t          wd0, wd1;
    always @(*) begin
        we0 = tail[0] ? disp_valid[1] : disp_valid[0];
        wa0 = tail[0] ? HW'(t1[ROBW-1:1]) : HW'(tail[ROBW-1:1]);
        wd0 = tail[0] ? pack(1) : pack(0);
        we1 = tail[0] ? disp_valid[0] : disp_valid[1];
        wa1 = tail[0] ? HW'(tail[ROBW-1:1]) : HW'(t1[ROBW-1:1]);
        wd1 = tail[0] ? pack(0) : pack(1);
    end
    always_ff @(posedge clk) if (we0) bank0[wa0] <= wd0;
    always_ff @(posedge clk) if (we1) bank1[wa1] <= wd1;

    // ---- status
    logic [NROB-1:0] done, exc, rp;
    logic [4:0]      cause [NROB];

    // in the ROB now: between head and tail
    function automatic logic live(input logic [ROBW-1:0] i);
        return rdist(i, head[ROBW-1:0]) < ROBW'(used) || used == (ROBW + 1)'(NROB);
    endfunction

    // ---- the head and commit
    pay_t p0, p1;                              // the payloads of head and head + 1
    logic [ROBW-1:0] hi0, hi1;
    always @(*) begin
        h1  = nxt(head, 2'd1);
        hi0 = head[ROBW-1:0];
        hi1 = h1[ROBW-1:0];
        p0  = hi0[0] ? bank1[HW'(hi0[ROBW-1:1])] : bank0[HW'(hi0[ROBW-1:1])];
        p1  = hi1[0] ? bank1[HW'(hi1[ROBW-1:1])] : bank0[HW'(hi1[ROBW-1:1])];
    end

    logic c0, c1;
    always @(*) begin
        c0 = used != '0 && done[hi0] && !exc[hi0] && !irq;
        c1 = c0 && !rp[hi0] && used >= (ROBW + 1)'(2) && done[hi1] && !exc[hi1];
        trap       = used != '0 && done[hi0] && exc[hi0];
        trap_cause = cause[hi0];
        trap_pc    = p0[PW-1 -: VA-1];
        replay     = (c0 && rp[hi0]) || (c1 && rp[hi1]);
        replay_pc  = (c0 && rp[hi0]) ? p0[PW-1 -: VA-1] + (VA - 1)'(p0[FTQW+2:FTQW])
                                     : p1[PW-1 -: VA-1] + (VA - 1)'(p1[FTQW+2:FTQW]);
        head_rob   = hi0;
        head_ns    = used != '0 && p0[FTQW+3] && !done[hi0];
        head_valid = used != '0;
        head_fused = p0[FTQW+4];
        // the µop the front end's history and RAS go back to (OOO_FERS): the
        // head for a trap, the marked one for a replay
        begin
            /* verilator lint_off UNUSEDSIGNAL */
            pay_t          pr;              // (its pc's parcel, length and block only)
            logic [VA-1:1] ppc;
            /* verilator lint_on UNUSEDSIGNAL */
            pr      = (trap || irq || (c0 && rp[hi0])) ? p0 : p1;
            ppc     = pr[PW-1 -: VA-1];
            rcv_ftq = pr[FTQW-1:0];
            rcv_end = ppc[3:1] + pr[FTQW+2:FTQW] - 3'd1;
        end
        cmt_valid  = {c1, c0};
        for (int u = 0; u < 2; u++) begin
            pay_t p;
            p = (u == 1) ? p1 : p0;
            cmt_pc[u]   = p[PW-1 -: VA-1];
            cmt_wr[u]   = p[PW-VA];
            cmt_arch[u] = p[PW-VA-1 -: 5];
            cmt_new[u]  = p[PW-VA-6 -: TAGW];
            cmt_old[u]  = p[PW-VA-6-TAGW -: TAGW];
            cmt_ftq[u]  = p[FTQW-1:0];
        end
        cmt_ld_n    = 2'(c0 && p0[FTQW+6]) + 2'(c1 && p1[FTQW+6]);
        cmt_st_n    = 2'(c0 && p0[FTQW+5]) + 2'(c1 && p1[FTQW+5]);
        cmt_instret = (c0 ? (p0[FTQW+4] ? 3'd2 : 3'd1) : 3'd0) + (c1 ? (p1[FTQW+4] ? 3'd2 : 3'd1) : 3'd0);
    end

    // ---- branch resolution: the oldest mispredicted one in the ROB
    logic           r0, r1;
    always @(*) begin
        r0 = br_valid[0] && br_mispred[0] && live(br_rob[0]);
        r1 = br_valid[1] && br_mispred[1] && live(br_rob[1]);
        if (r0 && (!r1 || rdist(br_rob[0], hi0) <= rdist(br_rob[1], hi0))) begin
            restore_rob = br_rob[0]; restore_ckpt = br_ckpt[0];
        end else begin
            restore_rob = br_rob[1]; restore_ckpt = br_ckpt[1];
        end
        restore = (r0 || r1) && !trap && !irq && !replay;
    end

    // ---- pointers
    ptr_t head_n, tail_n;
    always @(*) begin
        head_n = nxt(head, 2'(c0) + 2'(c1));
        if (trap || irq) begin
            tail_n = head;                     // empty
        end else if (replay) begin
            tail_n = head_n;                   // empty after the commits
        end else if (restore) begin
            // just after the branch: its index with the wrap bit of its lap
            // (the head's, or the next one if it lies before the head)
            tail_n = nxt({(restore_rob >= hi0) ? head[ROBW] : ~head[ROBW], restore_rob}, 2'd1);
        end else begin
            tail_n = nxt(tail, 2'(disp_valid[0]) + 2'(disp_valid[1]));
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
        logic n0, n1;
        assign n0 = disp_valid[0] && tail[ROBW-1:0] == ROBW'(i);
        assign n1 = disp_valid[1] && t1[ROBW-1:0] == ROBW'(i);
        always_ff @(posedge clk) begin
            if (n0 || n1) begin
                done[i]  <= n1 ? disp_exc[1] : disp_exc[0];      // an exception at decode is done at once
                exc[i]   <= n1 ? disp_exc[1] : disp_exc[0];
                cause[i] <= n1 ? disp_cause[1] : disp_cause[0];
                rp[i]    <= 1'b0;
            end else begin
                for (int c = 0; c < NCMP; c++)
                    if (cmp_valid[c] && cmp_rob[c] == ROBW'(i)) begin
                        done[i] <= 1'b1;
                        if (cmp_exc[c]) begin exc[i] <= 1'b1; cause[i] <= cmp_cause[c]; end
                        if (cmp_rp[c])  rp[i] <= 1'b1;
                    end
            end
        end
    end

endmodule : OOO_ROB
