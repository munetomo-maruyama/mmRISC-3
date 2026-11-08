//---------------------------------------------------------------------------
// OOO_CTRL.sv
//
// The control of mmRISC-3's back end (Doc/UARCH.md 3.1, Plan/OOC.md 18 and
// 19; ND slots, 2 or 4: Plan/OOC.md 29.19): what decides, every cycle, which µops move from renaming to
// dispatch, which µops a misprediction or a trap throws away, where fetch
// starts again, when a non-speculative µop may issue, and what commit
// gives the rest of the core.
//
// Branch masks: a µop carries one bit for every checkpoint (NCKPT, the
// branches and jalrs not yet resolved) older than it. A misprediction that
// restores checkpoint c kills every µop whose mask has bit c (in the DS
// register here, in the issue queue, in the units' pipelines): exactly the
// µops younger than that branch. A branch resolved as predicted clears its
// bit in every mask (clr), so the checkpoint can be given out again. The
// clear comes from the registered resolution (cl_*, br_* as predicted;
// Plan/CORE.md 5.20), with the restore: from EX it lay on the 4-wide core's
// paths (Plan/OOC.md 29.21). A checkpoint lives a cycle longer (with 6 that
// cost 2 %; with 12, see 29.21).
//
//   D2  renaming (OOO_RENAME): r_go gives the µops that rename now. A µop
//       that takes a checkpoint goes only if the checkpoint id renaming
//       gives it (out_ckpt_id) is free: renaming copies the RAT into that
//       id in the next cycle, so a live one must not be given out again
//       (the ring of ids is used in order; one still open stops it). The
//       DS register must be free or leaving, renaming must have registers
//       (r_ren_ready), and nothing is renamed in a cycle of restore or of
//       flush_all. In a cycle of trap or replay it may: flush_all of the next
//       cycle puts renaming back to the committed RAT and free list
//       (OOO_RENAME2's arat, chead), and clears the DS register (Plan/OOC.md
//       29.35).
//       A renamed µop's mask is the live checkpoints then (with the one
//       of slot 0 for slot 1), less those cleared in that cycle.
//   DS  dispatch: the µops of the DS register go together (both or none:
//       ds_valid / d_go; their payload is the assembly's DS register)
//       when the ROB, the issue queue, the LQ and the SQ have room for all
//       of them, with their masks (d_bmask, less this cycle's clears),
//       not in a cycle of restore (restore_k) or of flush_all. In a cycle of
//       trap or replay they may go: the ROB's tail goes back and flush_all
//       of the next cycle clears the rest (waiting on the trap lay on the
//       4-wide core's paths, Plan/OOC.md 29.24).
//       ds_load: the register takes renaming's µops (it is empty or its
//       µops go now; the enable of the payload, OOO_DSREG).
//       A µop with a checkpoint writes the checkpoint table: the LSU's
//       tails after it (ck_*_tail) and its fetch block (ds_ftq).
//   recovery, in this order:
//     trap      (OOO_ROB: an exception at the head): flush_all, fetch from
//               trap_vec (mtvec)
//     replay    (OOO_ROB: a load that raised ld_cancel commits): flush_all,
//               fetch from replay_pc
//     restore   (OOO_ROB: the oldest mispredicted branch of the cycle, by
//               its checkpoint): restore with that id (renaming), the LSU
//               tails and the FTQ index of the table, kill = its bit, fetch
//               from the branch's correct next pc (br_next of the port
//               that resolved it: restore_port, also for OOO_FERS)
//   The checkpoints younger than a restored one (their masks have its
//   bit) and the restored one itself are free again; flush_all frees all.
//
// A branch resolved in the cycle a restore kills it (it is younger) clears
// nothing: its id may be given out again. Units drop what they have in
// flight with a killed bit (iss mask & kill), so no later resolution of a
// killed branch arrives.
//
// Trap and replay: the front end is flushed at once (fe_flush: the FTQ,
// the fetch buffer, fetch from fe_pc), the back end a cycle later
// (flush_all: renaming, the LSU, the issue queue, the units). A replay
// commits its load in the cycle it is found, and renaming goes back to its
// committed state, which takes that commit only at the clock edge; flushed
// in the same cycle, the load's mapping would be lost. In between nothing
// is renamed or dispatched, and the ROB is already empty.
//
// Non-speculative µops (Doc/UARCH.md 3.9): ns_ok lets the issue queue give
// the oldest one when the ROB head is one not run yet (head_ns), once:
// after one has issued (iss_ns), no other until the head commits. ns_ok is
// a register (from the cycle before): it feeds the issue queue's select,
// and head_ns comes from the ROB's payload read; combinational, that path
// missed 50 MHz through the issue queue (Plan/OOC.md 19.4). A
// non-speculative µop waits one cycle more for it. A µop
// that changes what younger ones do (a CSR write, FENCE.I, SFENCE.VMA,
// MRET) completes marked for replay after commit (the unit's contract), so
// what follows it is fetched again.
//
// Commit: the old mappings of the committed µops go back to the free list
// (free_*), the LQ / SQ get the counts (lq_commit / sq_commit; renaming
// takes the committed state straight from the ROB). The FTQ pops the
// blocks before the block of the latest committed µop (cmt_ftq), one a
// cycle (the rest the next cycles: TAGE takes one block's update a cycle,
// its metadata from the FTQ's head read, Plan/CORE.md 5.2); after a replay
// the load's own block too (what follows it comes in new blocks). A trap or
// a replay flushes the FTQ: blocks still to pop then go without their
// predictor update.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_CTRL
    #(
        parameter int NCKPT = 6,
        parameter int CW    = 3,        // checkpoint id bits
        parameter int VA    = 39,
        parameter int FTQW  = 4,
        parameter int LW    = 3,        // LQ / SQ entry bits (the tails have one more)
        parameter int TAGW  = 6,
        parameter int ND    = 2         // renamed, dispatched, committed a cycle: 2 or 4 (Plan/OOC.md 29.19)
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // D2: renaming
        input  logic [ND-1:0]                  r_valid,    // µops at renaming (slot 1 only with slot 0)
        input  logic [ND-1:0]                  r_ckpt,     // they take a checkpoint
        input  logic [ND-1:0][CW-1:0]          r_ckpt_id,  // OOO_RENAME out_ckpt_id
        input  logic                        r_ren_ready,// OOO_RENAME ready (free registers)
        output logic [ND-1:0]                  r_go,       // rename these now (OOO_RENAME in_valid)

        // DS: dispatch
        output logic [ND-1:0]                  ds_valid,   // the DS register holds these
        output logic                        ds_load,    // it takes renaming's µops (OOO_DSREG load)
        input  logic [ND-1:0]                  ds_ld,      // the DS µops are loads / stores
        input  logic [ND-1:0]                  ds_st,
        input  logic [ND-1:0][FTQW-1:0]        ds_ftq,     // their fetch blocks
        input  logic [2:0]                  rob_avail,  // free entries, 0 .. 2
        input  logic [2:0]                  iq_avail,
        input  logic [2:0]                  lq_avail,
        input  logic [2:0]                  sq_avail,
        input  logic [ND-1:0][LW:0]            ck_lq_tail, // OOO_LSU: the tails after slot 0 / 1
        input  logic [ND-1:0][LW:0]            ck_sq_tail,
        output logic [ND-1:0]                  d_go,       // dispatched now
        output logic [ND-1:0][NCKPT-1:0]       d_bmask,    // their branch masks

        // resolution (the two ALU ports, registered after EX: Plan/CORE.md 5.20)
        /* verilator lint_off UNUSEDSIGNAL */          // (port 1's: restore_port asks port 0 alone)
        input  logic [1:0]                  br_valid,
        input  logic [1:0]                  br_mispred,
        input  logic [1:0][CW-1:0]          br_ckpt,    // the branch's own checkpoint
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [1:0][VA-1:1]          br_next,    // its correct next pc
        input  logic [1:0]                  cl_valid,   // a branch resolved as predicted (with br_*)
        input  logic [1:0][CW-1:0]          cl_ckpt,

        // OOO_ROB
        input  logic                        rob_restore,
        input  logic                        rob_restore_k, // ... a trap or replay or not (the kill's)
        input  logic [CW-1:0]               rob_restore_ckpt,
        input  logic                        trap,
        input  logic                        replay,
        input  logic [VA-1:1]               replay_pc,
        input  logic [VA-1:1]               trap_vec,   // mtvec (the CSRs)
        input  logic                        head_ns,    // the head is a non-speculative µop not run yet
        input  logic [ND-1:0]                  cmt_valid,
        input  logic [ND-1:0]                  cmt_wr,
        input  logic [ND-1:0][TAGW-1:0]        cmt_old,
        input  logic [2:0]                  cmt_ld_n,
        input  logic [2:0]                  cmt_st_n,
        input  logic [ND-1:0][FTQW-1:0]        cmt_ftq,

        // OOO_IQ
        input  logic                        iss_ns,     // a non-speculative µop issued now
        output logic                        ns_ok,
        output logic                        ns_busy,    // the head's non-speculative µop has issued (OOO_TRAP: no interrupt)

        // recovery
        output logic                        fe_flush,   // trap / replay: the front end now
        output logic                        flush_all,  // the back end, a cycle later
        output logic                        restore,
        output logic                        restore_k,  // the kill's restore: the LSU's
        output logic [CW-1:0]               restore_id,
        output logic                        restore_port, // the ALU port of the restoring branch (OOO_FERS)
        output logic [LW:0]                 restore_lq_tail,
        output logic [LW:0]                 restore_sq_tail,
        output logic [FTQW-1:0]             restore_ftq,
        output logic [NCKPT-1:0]            kill,       // µops with this bit die (one-hot)
        output logic [NCKPT-1:0]            clr,        // checkpoints resolved as predicted
        output logic                        fe_redirect,
        output logic [VA-1:1]               fe_pc,
        output logic [NCKPT-1:0]            live,       // checkpoints given out, not resolved

        // commit
        output logic [ND-1:0]                  free_valid, // OOO_RENAME: the old mappings back
        output logic [ND-1:0][TAGW-1:0]        free_tag,
        output logic [2:0]                  lq_commit,  // OOO_LSU
        output logic [2:0]                  sq_commit,
        output logic [1:0]                  ftq_pop     // OOO_FTQ
    );

    logic [NCKPT-1:0] ck_bm  [NCKPT];          // the mask of each checkpoint's branch
    logic [LW:0]      ck_lq  [NCKPT];          // the table
    logic [LW:0]      ck_sq  [NCKPT];
    logic [FTQW-1:0]  ck_ftq [NCKPT];
    logic [ND-1:0]          ds_v, ds_ck;       // the DS register's control part
    logic [ND-1:0][CW-1:0]  ds_id;
    logic [ND-1:0][NCKPT-1:0] ds_bm;

    function automatic logic [NCKPT-1:0] bit_of(input logic [CW-1:0] id);
        logic [NCKPT-1:0] b;
        b = '0;
        b[id] = 1'b1;
        return b;
    endfunction

    // ---- recovery and resolution
    logic [NCKPT-1:0] killset;                 // the restored checkpoint and those younger
    logic             flush_q;                 // trap / replay of the cycle before
    logic             ns_busy_n;
    logic [FTQW-1:0]  ftq_hd, ftq_tgt;         // the FTQ's head (a mirror); pop up to the target
    always @(*) begin
        fe_flush   = trap || replay;
        flush_all  = flush_q;
        restore    = rob_restore && !fe_flush && !flush_q;
        restore_id = rob_restore_ckpt;
        // the kill does not wait on a trap or replay of the cycle (the flush of
        // the next cycle overrides it): through them it lay on the 4-wide core's
        // paths (Plan/OOC.md 29.23). The rest of the restore does wait, here too
        restore_k  = rob_restore_k && !flush_q;
        kill       = restore_k ? bit_of(rob_restore_ckpt) : '0;
        killset    = restore ? kill : '0;
        for (int j = 0; j < NCKPT; j++)
            if (restore && live[j] && (ck_bm[j] & kill) != '0) killset[j] = 1'b1;
        clr = '0;
        for (int p = 0; p < 2; p++)
            if (cl_valid[p] && live[cl_ckpt[p]]) clr[cl_ckpt[p]] = 1'b1;
        clr = clr & ~killset;
        if (fe_flush || flush_q) clr = '0;
        restore_lq_tail = ck_lq[rob_restore_ckpt];
        restore_sq_tail = ck_sq[rob_restore_ckpt];
        restore_ftq     = ck_ftq[rob_restore_ckpt];
        restore_port = !(br_valid[0] && br_mispred[0] && br_ckpt[0] == rob_restore_ckpt);
        fe_redirect = fe_flush || restore;
        if (trap)                                                   fe_pc = trap_vec;
        else if (replay)                                            fe_pc = replay_pc;
        else if (!restore_port)                                     fe_pc = br_next[0];
        else                                                        fe_pc = br_next[1];
    end

    // ---- non-speculative µops, commit
    logic [FTQW-1:0] tgt, ndone;
    always @(*) begin
        ns_busy_n = (fe_flush || flush_q || cmt_valid[0]) ? 1'b0 : (ns_busy || iss_ns);
        for (int k = 0; k < ND; k++) begin
            free_valid[k] = cmt_valid[k] && cmt_wr[k];
            free_tag[k]   = cmt_old[k];
        end
        lq_commit = cmt_ld_n;
        sq_commit = cmt_st_n;
        // the FTQ: the blocks before the latest committed µop's (its own too
        // after a replay)
        tgt = ftq_tgt;
        for (int k = 0; k < ND; k++) if (cmt_valid[k]) tgt = cmt_ftq[k] + FTQW'(replay);
        ndone   = tgt - ftq_hd;               // blocks done, not popped
        ftq_pop = (ndone != '0) ? 2'd1 : 2'd0;
    end

    // ---- DS: dispatch, all of the register's µops or none
    logic [2:0] nld, nst, nall;
    logic       d_ok;
    always @(*) begin
        nall = '0; nld = '0; nst = '0;
        for (int k = 0; k < ND; k++) begin
            nall = nall + 3'(ds_v[k]);
            nld  = nld + 3'(ds_v[k] && ds_ld[k]);
            nst  = nst + 3'(ds_v[k] && ds_st[k]);
        end
        d_ok = !flush_q && !restore_k && rob_avail >= nall && iq_avail >= nall && lq_avail >= nld && sq_avail >= nst;
        d_go = d_ok ? ds_v : '0;
        for (int k = 0; k < ND; k++) d_bmask[k] = ds_bm[k] & ~clr;
        ds_valid = ds_v;
    end

    // ---- D2: renaming, a prefix of the µops offered
    logic [NCKPT-1:0] lv_c;                    // live less this cycle's clears
    assign lv_c = live & ~clr;

    // (at most 2 checkpoints a group: OOO_RENAME2 takes no more, up to the second)
    logic          ds_free;                    // the DS register takes new µops
    logic [ND-1:0][NCKPT-1:0] r_bm;            // the masks the slots take: the live ones, and those of the slots before
    always @(*) begin
        automatic logic [1:0] nck = 2'd0;
        ds_free = ds_v == '0 || d_go == ds_v;
        ds_load = ds_free;
        for (int k = 0; k < ND; k++) begin
            r_go[k] = (k == 0 ? ds_free && r_ren_ready && !flush_q && !restore_k : r_go[k-1]) && r_valid[k] && nck != 2'd2 &&
                      (!r_ckpt[k] || !live[r_ckpt_id[k]]);
            r_bm[k] = lv_c;
            for (int m = 0; m < k; m++) if (r_go[m] && r_ckpt[m]) r_bm[k] = r_bm[k] | bit_of(r_ckpt_id[m]);
            if (r_valid[k] && r_ckpt[k] && nck != 2'd2) nck = nck + 2'd1;
        end
    end

    // ---- state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_q <= 1'b0;
            ns_busy <= 1'b0;
            ns_ok   <= 1'b0;
            ftq_hd  <= '0;
            ftq_tgt <= '0;
        end else begin
            flush_q <= fe_flush;
            ns_busy <= ns_busy_n;
            ns_ok   <= head_ns && !ns_busy_n && !fe_flush && !flush_q;
            ftq_hd  <= ftq_hd + FTQW'(ftq_pop);
            // a flushed FTQ keeps no blocks to pop
            ftq_tgt <= fe_flush ? ftq_hd + FTQW'(ftq_pop) : tgt;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            live <= '0;
            ds_v <= '0;
        end else if (flush_q) begin
            live <= '0;
            ds_v <= '0;
        end else begin
            logic [NCKPT-1:0] l;
            l = lv_c & ~killset;
            for (int k = 0; k < ND; k++) if (r_go[k] && r_ckpt[k]) l[r_ckpt_id[k]] = 1'b1;
            live <= l;
            // the DS register: new µops when it is free, else it keeps what
            // did not go (minus the killed); its masks lose the cleared bits
            if (ds_free) begin
                ds_v <= r_go;
            end else begin
                for (int k = 0; k < ND; k++) if (restore && (ds_bm[k] & kill) != '0) ds_v[k] <= 1'b0;
            end
        end
    end
    always_ff @(posedge clk) begin
        if (ds_free) begin
            ds_ck <= r_ckpt;
            ds_id <= r_ckpt_id;
            for (int k = 0; k < ND; k++) ds_bm[k] <= r_bm[k];
        end else begin
            for (int k = 0; k < ND; k++) ds_bm[k] <= ds_bm[k] & ~clr;
        end
        // the masks of the checkpoints: set when given out, cleared bits dropped
        for (int j = 0; j < NCKPT; j++) ck_bm[j] <= ck_bm[j] & ~clr;
        for (int k = 0; k < ND; k++) if (r_go[k] && r_ckpt[k]) ck_bm[r_ckpt_id[k]] <= r_bm[k];
        // the table, at dispatch
        for (int k = 0; k < ND; k++)
            if (d_go[k] && ds_ck[k]) begin
                ck_lq[ds_id[k]]  <= ck_lq_tail[k];
                ck_sq[ds_id[k]]  <= ck_sq_tail[k];
                ck_ftq[ds_id[k]] <= ds_ftq[k];
            end
    end

endmodule : OOO_CTRL
