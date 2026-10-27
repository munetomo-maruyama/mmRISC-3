//---------------------------------------------------------------------------
// OOO_CTRL.sv
//
// The control of mmRISC-3's back end (Doc/UARCH.md 3.1, Plan/OOC.md 18),
// first part: what decides, every cycle, which µops move from renaming to
// dispatch, which µops a misprediction or a trap throws away, and where
// fetch starts again.
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
//               that resolved it)
//   The checkpoints younger than a restored one (their masks have its
//   bit) and the restored one itself are free again; flush_all frees all.
//
// A branch resolved in the cycle a restore kills it (it is younger) clears
// nothing: its id may be given out again. Units drop what they have in
// flight with a killed bit (iss mask & kill), so no later resolution of a
// killed branch arrives.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_CTRL
    #(
        parameter int NCKPT = 6,
        parameter int CW    = 3,        // checkpoint id bits
        parameter int VA    = 39,
        parameter int FTQW  = 3,
        parameter int LW    = 3         // LQ / SQ entry bits (the tails have one more)
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

        // recovery
        output logic                        flush_all,
        output logic                        restore,
        output logic [CW-1:0]               restore_id,
        output logic [LW:0]                 restore_lq_tail,
        output logic [LW:0]                 restore_sq_tail,
        output logic [FTQW-1:0]             restore_ftq,
        output logic [NCKPT-1:0]            kill,       // µops with this bit die (one-hot)
        output logic [NCKPT-1:0]            clr,        // checkpoints resolved as predicted
        output logic                        fe_redirect,
        output logic [VA-1:1]               fe_pc,
        output logic [NCKPT-1:0]            live        // checkpoints given out, not resolved
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
    logic             rcv;                     // a cycle of recovery
    always @(*) begin
        flush_all  = trap || replay;
        restore    = rob_restore && !flush_all;
        restore_id = rob_restore_ckpt;
        kill       = restore ? bit_of(rob_restore_ckpt) : '0;
        killset    = kill;
        for (int j = 0; j < NCKPT; j++)
            if (restore && live[j] && (ck_bm[j] & kill) != '0) killset[j] = 1'b1;
        clr = '0;
        for (int p = 0; p < 2; p++)
            if (br_valid[p] && !br_mispred[p] && live[br_ckpt[p]]) clr[br_ckpt[p]] = 1'b1;
        clr = clr & ~killset;
        if (flush_all) clr = '0;
        restore_lq_tail = ck_lq[rob_restore_ckpt];
        restore_sq_tail = ck_sq[rob_restore_ckpt];
        restore_ftq     = ck_ftq[rob_restore_ckpt];
        rcv         = flush_all || restore;
        fe_redirect = rcv;
        if (trap)                                                   fe_pc = trap_vec;
        else if (replay)                                            fe_pc = replay_pc;
        else if (br_valid[0] && br_mispred[0] && br_ckpt[0] == rob_restore_ckpt) fe_pc = br_next[0];
        else                                                        fe_pc = br_next[1];
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
        for (int k = 0; k < 2; k++) ck_ok[k] = !r_ckpt[k] || !live[r_ckpt_id[k]];
        r_go[0] = r_valid[0] && ds_free && r_ren_ready && !rcv && ck_ok[0];
        r_go[1] = r_go[0] && r_valid[1] && ck_ok[1];
    end

    // ---- state
    logic [NCKPT-1:0] lv_c;                    // live less this cycle's clears
    assign lv_c = live & ~clr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            live <= '0;
            ds_v <= '0;
        end else if (flush_all) begin
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
