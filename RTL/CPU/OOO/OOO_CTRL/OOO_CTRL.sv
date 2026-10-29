//---------------------------------------------------------------------------
// OOO_CTRL.sv
//
// The control of mmRISC-3's back end (Doc/UARCH.md 3.1, Plan/OOC.md 18 and
// 19): what decides, every cycle, which µops move from renaming to
// dispatch, which µops a misprediction or a trap throws away, where fetch
// starts again, when a non-speculative µop may issue, and what commit
// gives the rest of the core.
//
// Branch masks: a µop carries one bit for every checkpoint (NCKPT, the
// branches and jalrs not yet resolved) older than it. A misprediction that
// restores checkpoint c kills every µop whose mask has bit c (in the DS
// register here, in the issue queue, in the units' pipelines): exactly the
// µops younger than that branch. A branch resolved as predicted clears its
// bit in every mask (clr), so the checkpoint can be given out again.
//
//   D2  renaming (OOO_RENAME): r_go gives the µops that rename now. A µop
//       that takes a checkpoint goes only if the checkpoint id renaming
//       gives it (out_ckpt_id) is free: renaming copies the RAT into that
//       id in the next cycle, so a live one must not be given out again
//       (the ring of ids is used in order; one still open stops it). The
//       DS register must be free or leaving, renaming must have registers
//       (r_ren_ready), and nothing is renamed in a cycle of recovery.
//       A renamed µop's mask is the live checkpoints then (with the one
//       of slot 0 for slot 1), less those cleared in that cycle.
//   DS  dispatch: the µops of the DS register go together (both or none:
//       ds_valid / d_go; their payload is the assembly's DS register)
//       when the ROB, the issue queue, the LQ and the SQ have room for all
//       of them, with their masks (d_bmask, less this cycle's clears).
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
        parameter int TAGW  = 6
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // D2: renaming
        input  logic [1:0]                  r_valid,    // µops at renaming (slot 1 only with slot 0)
        input  logic [1:0]                  r_ckpt,     // they take a checkpoint
        input  logic [1:0][CW-1:0]          r_ckpt_id,  // OOO_RENAME out_ckpt_id
        input  logic                        r_ren_ready,// OOO_RENAME ready (free registers)
        output logic [1:0]                  r_go,       // rename these now (OOO_RENAME in_valid)

        // DS: dispatch
        output logic [1:0]                  ds_valid,   // the DS register holds these
        output logic                        ds_load,    // it takes renaming's µops (OOO_DSREG load)
        input  logic [1:0]                  ds_ld,      // the DS µops are loads / stores
        input  logic [1:0]                  ds_st,
        input  logic [1:0][FTQW-1:0]        ds_ftq,     // their fetch blocks
        input  logic [1:0]                  rob_avail,  // free entries, 0 .. 2
        input  logic [1:0]                  iq_avail,
        input  logic [1:0]                  lq_avail,
        input  logic [1:0]                  sq_avail,
        input  logic [1:0][LW:0]            ck_lq_tail, // OOO_LSU: the tails after slot 0 / 1
        input  logic [1:0][LW:0]            ck_sq_tail,
        output logic [1:0]                  d_go,       // dispatched now
        output logic [1:0][NCKPT-1:0]       d_bmask,    // their branch masks

        // resolution (the two ALU ports, in EX)
        input  logic [1:0]                  br_valid,
        input  logic [1:0]                  br_mispred,
        input  logic [1:0][CW-1:0]          br_ckpt,    // the branch's own checkpoint
        input  logic [1:0][VA-1:1]          br_next,    // its correct next pc

        // OOO_ROB
        input  logic                        rob_restore,
        input  logic [CW-1:0]               rob_restore_ckpt,
        input  logic                        trap,
        input  logic                        replay,
        input  logic [VA-1:1]               replay_pc,
        input  logic [VA-1:1]               trap_vec,   // mtvec (the CSRs)
        input  logic                        head_ns,    // the head is a non-speculative µop not run yet
        input  logic [1:0]                  cmt_valid,
        input  logic [1:0]                  cmt_wr,
        input  logic [1:0][TAGW-1:0]        cmt_old,
        input  logic [1:0]                  cmt_ld_n,
        input  logic [1:0]                  cmt_st_n,
        input  logic [1:0][FTQW-1:0]        cmt_ftq,

        // OOO_IQ
        input  logic                        iss_ns,     // a non-speculative µop issued now
        output logic                        ns_ok,
        output logic                        ns_busy,    // the head's non-speculative µop has issued (OOO_TRAP: no interrupt)

        // recovery
        output logic                        fe_flush,   // trap / replay: the front end now
        output logic                        flush_all,  // the back end, a cycle later
        output logic                        restore,
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
        output logic [1:0]                  free_valid, // OOO_RENAME: the old mappings back
        output logic [1:0][TAGW-1:0]        free_tag,
        output logic [1:0]                  lq_commit,  // OOO_LSU
        output logic [1:0]                  sq_commit,
        output logic [1:0]                  ftq_pop     // OOO_FTQ
    );

    logic [NCKPT-1:0] ck_bm  [NCKPT];          // the mask of each checkpoint's branch
    logic [LW:0]      ck_lq  [NCKPT];          // the table
    logic [LW:0]      ck_sq  [NCKPT];
    logic [FTQW-1:0]  ck_ftq [NCKPT];
    logic [1:0]             ds_v, ds_ck;       // the DS register's control part
    logic [1:0][CW-1:0]     ds_id;
    logic [1:0][NCKPT-1:0]  ds_bm;

    function automatic logic [NCKPT-1:0] bit_of(input logic [CW-1:0] id);
        logic [NCKPT-1:0] b;
        b = '0;
        b[id] = 1'b1;
        return b;
    endfunction

    // ---- recovery and resolution
    logic [NCKPT-1:0] killset;                 // the restored checkpoint and those younger
    logic             rcv;                     // nothing renamed or dispatched
    logic             flush_q;                 // trap / replay of the cycle before
    logic             ns_busy_n;
    logic [FTQW-1:0]  ftq_hd, ftq_tgt;         // the FTQ's head (a mirror); pop up to the target
    always @(*) begin
        fe_flush   = trap || replay;
        flush_all  = flush_q;
        restore    = rob_restore && !fe_flush && !flush_q;
        restore_id = rob_restore_ckpt;
        kill       = restore ? bit_of(rob_restore_ckpt) : '0;
        killset    = kill;
        for (int j = 0; j < NCKPT; j++)
            if (restore && live[j] && (ck_bm[j] & kill) != '0) killset[j] = 1'b1;
        clr = '0;
        for (int p = 0; p < 2; p++)
            if (br_valid[p] && !br_mispred[p] && live[br_ckpt[p]]) clr[br_ckpt[p]] = 1'b1;
        clr = clr & ~killset;
        if (fe_flush || flush_q) clr = '0;
        restore_lq_tail = ck_lq[rob_restore_ckpt];
        restore_sq_tail = ck_sq[rob_restore_ckpt];
        restore_ftq     = ck_ftq[rob_restore_ckpt];
        rcv         = fe_flush || flush_q || restore;
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
        for (int k = 0; k < 2; k++) begin
            free_valid[k] = cmt_valid[k] && cmt_wr[k];
            free_tag[k]   = cmt_old[k];
        end
        lq_commit = cmt_ld_n;
        sq_commit = cmt_st_n;
        // the FTQ: the blocks before the latest committed µop's (its own too
        // after a replay)
        if (cmt_valid != 2'b00) tgt = (cmt_valid[1] ? cmt_ftq[1] : cmt_ftq[0]) + FTQW'(replay);
        else                    tgt = ftq_tgt;
        ndone   = tgt - ftq_hd;               // blocks done, not popped
        ftq_pop = (ndone != '0) ? 2'd1 : 2'd0;
    end

    // ---- DS: dispatch, all of the register's µops or none
    logic [1:0] nld, nst, nall;
    logic       d_ok;
    always @(*) begin
        nall = 2'(ds_v[0]) + 2'(ds_v[1]);
        nld  = 2'(ds_v[0] && ds_ld[0]) + 2'(ds_v[1] && ds_ld[1]);
        nst  = 2'(ds_v[0] && ds_st[0]) + 2'(ds_v[1] && ds_st[1]);
        d_ok = !rcv && rob_avail >= nall && iq_avail >= nall && lq_avail >= nld && sq_avail >= nst;
        d_go = d_ok ? ds_v : 2'b00;
        for (int k = 0; k < 2; k++) d_bmask[k] = ds_bm[k] & ~clr;
        ds_valid = ds_v;
    end

    // ---- D2: renaming, a prefix of the µops offered
    logic       ds_free;                       // the DS register takes new µops
    logic [1:0] ck_ok;
    always @(*) begin
        ds_free = ds_v == 2'b00 || d_go == ds_v;
        ds_load = ds_free;
        for (int k = 0; k < 2; k++) ck_ok[k] = !r_ckpt[k] || !live[r_ckpt_id[k]];
        r_go[0] = r_valid[0] && ds_free && r_ren_ready && !rcv && ck_ok[0];
        r_go[1] = r_go[0] && r_valid[1] && ck_ok[1];
    end

    // ---- state
    logic [NCKPT-1:0] lv_c;                    // live less this cycle's clears
    assign lv_c = live & ~clr;
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
            for (int k = 0; k < 2; k++) if (r_go[k] && r_ckpt[k]) l[r_ckpt_id[k]] = 1'b1;
            live <= l;
            // the DS register: new µops when it is free, else it keeps what
            // did not go (minus the killed); its masks lose the cleared bits
            if (ds_free) begin
                ds_v <= r_go;
            end else begin
                for (int k = 0; k < 2; k++) if ((ds_bm[k] & kill) != '0) ds_v[k] <= 1'b0;
            end
        end
    end
    always_ff @(posedge clk) begin
        if (ds_free) begin
            ds_ck <= r_ckpt;
            ds_id <= r_ckpt_id;
            ds_bm[0] <= lv_c;
            ds_bm[1] <= lv_c | ((r_go[0] && r_ckpt[0]) ? bit_of(r_ckpt_id[0]) : '0);
        end else begin
            for (int k = 0; k < 2; k++) ds_bm[k] <= ds_bm[k] & ~clr;
        end
        // the masks of the checkpoints: set when given out, cleared bits dropped
        for (int j = 0; j < NCKPT; j++) ck_bm[j] <= ck_bm[j] & ~clr;
        if (r_go[0] && r_ckpt[0]) ck_bm[r_ckpt_id[0]] <= lv_c;
        if (r_go[1] && r_ckpt[1]) ck_bm[r_ckpt_id[1]] <= lv_c | (r_ckpt[0] ? bit_of(r_ckpt_id[0]) : '0);
        // the table, at dispatch
        for (int k = 0; k < 2; k++)
            if (d_go[k] && ds_ck[k]) begin
                ck_lq[ds_id[k]]  <= ck_lq_tail[k];
                ck_sq[ds_id[k]]  <= ck_sq_tail[k];
                ck_ftq[ds_id[k]] <= ds_ftq[k];
            end
    end

endmodule : OOO_CTRL
