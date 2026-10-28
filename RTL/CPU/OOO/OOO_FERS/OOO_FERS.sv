//---------------------------------------------------------------------------
// OOO_FERS.sv
//
// The front end's restore of mmRISC-3 (Plan/OOC.md 21): what OOO_FETCH gets
// back after a misprediction, a trap or a replay (be_*), from the FTQ entry
// of the block where the redirect starts.
//
//   R      OOO_CTRL redirects (fe_redirect): the front end stops at once
//          (OOO_FETCH be_stop: nothing in flight is used, no request), and
//          the point of the redirect is taken into a register:
//            restore  the mispredicted transfer (restore_port: the ALU port
//                     that resolved it): its block (restore_ftq, from the
//                     checkpoint table), the parcel of its last half
//                     (br_e), its outcome, call / return
//            trap, replay  the trapping / replayed µop (OOO_ROB rcv_ftq,
//                     rcv_end)
//   R + 1  the FTQ entry of that block is read (rs_idx -> ft_*), and fetch
//          restarts (be_redirect) at fe_pc of cycle R with
//            history  the block's history before it (TAGE's metadata), and
//                     the block's slot branches up to the point: those
//                     before it not taken (as predicted: one predicted
//                     taken would have ended the block before it), the
//                     point's own slot, if it is one, with its outcome; a
//                     trap is taken before its µop (a debug trigger can be
//                     on a branch), and a replayed µop is never a branch,
//                     so there only the slots before it
//            RAS      the block's snapshot (before its push or pop), then
//                     the point's own push (a call: the parcel after it)
//                     or pop (a return)
//
// One cycle more than a redirect straight from the resolution (Doc/UARCH.md
// D-15: −0.27 % in the model): the history must be in TAGE's register before
// the first fetch reads the tables with it, and from the branch's comparison
// through the ROB's choice, the control, the checkpoint table, the FTQ read
// and the push into the history to the block RAM addresses there would be
// one cycle. A restore in the next cycle (an older branch) or a trap takes
// over: the later redirect wins.
//
// The block of a µop is the block of its last half (where predecode saw it
// and its slot is): an instruction across two lines belongs to the second
// block; br_e and rcv_end are parcels of that block.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FERS
    #(
        parameter int VA   = 39,
        parameter int FTQW = 3,
        parameter int HL   = 70,        // OOO_TAGE's history
        parameter int RW   = 4          // OOO_RAS's pointer
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // R: the redirect and its point
        input  logic                        fe_redirect,    // OOO_CTRL
        input  logic                        fe_flush,       // a trap or a replay (else a restore)
        input  logic [VA-1:1]               fe_pc,
        input  logic [FTQW-1:0]             restore_ftq,
        input  logic                        restore_port,
        input  logic [1:0][2:0]             br_e,           // the ALU ports' transfers: last parcel
        input  logic [1:0]                  br_taken,       // the outcome
        input  logic [1:0]                  br_call,
        input  logic [1:0]                  br_ret,
        input  logic [FTQW-1:0]             rcv_ftq,        // OOO_ROB: the trapping / replayed µop's block
        input  logic [2:0]                  rcv_end,        // and its last parcel

        // R + 1: the FTQ entry (OOO_FTQ's resolution read port)
        output logic [FTQW-1:0]             rs_idx,
        input  logic [VA-1:4]               ft_line,        // the block's line (its fetch address)
        input  logic [HL-1:0]               ft_hist,        // OOO_TAGE's metadata: the history before the block
        input  logic [2:0]                  ft_sv,          // the slots that hold a branch (a prefix)
        input  logic [2:0][2:0]             ft_par,         // their last parcels (in order)
        input  logic [RW-1:0]               ft_ras_ptr,     // the RAS snapshot
        input  logic [VA-1:1]               ft_ras_val,

        // R + 1: OOO_FETCH
        output logic                        be_redirect,
        output logic [VA-1:1]               be_pc,
        output logic [HL-1:0]               be_hist,
        output logic [1:0]                  be_hist_n,
        output logic [2:0]                  be_hist_bits,
        output logic [RW-1:0]               be_ras_ptr,
        output logic [VA-1:1]               be_ras_val,
        output logic                        be_ras_push,
        output logic [VA-1:1]               be_ras_addr,
        output logic                        be_ras_pop
    );

    logic [VA-1:1]   q_pc;
    logic [FTQW-1:0] q_ftq;
    logic [2:0]      q_e;
    logic            q_rs, q_tk, q_call, q_ret;    // q_rs: a restore (not a trap / replay)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) be_redirect <= 1'b0;
        else        be_redirect <= fe_redirect;
    end
    always_ff @(posedge clk) begin
        q_pc   <= fe_pc;
        q_ftq  <= fe_flush ? rcv_ftq : restore_ftq;
        q_e    <= fe_flush ? rcv_end : br_e[restore_port];
        q_rs   <= !fe_flush;
        q_tk   <= br_taken[restore_port];
        q_call <= !fe_flush && br_call[restore_port];
        q_ret  <= !fe_flush && br_ret[restore_port];
    end

    assign rs_idx = q_ftq;

    // the slots up to the point: before it not taken, at it the outcome
    // (only a conditional branch ends at a slot's parcel; not for a trap)
    always @(*) begin
        logic [1:0] n;
        n = '0;
        be_hist_bits = '0;
        for (int s = 0; s < 3; s++) begin
            if (ft_sv[s] && ft_par[s] < q_e)          n = 2'(s + 1);
            if (ft_sv[s] && ft_par[s] == q_e && q_rs) begin be_hist_bits[s] = q_tk; n = 2'(s + 1); end
        end
        be_hist_n   = n;
        be_pc       = q_pc;
        be_hist     = ft_hist;
        be_ras_ptr  = ft_ras_ptr;
        be_ras_val  = ft_ras_val;
        be_ras_push = q_call;
        be_ras_pop  = q_ret;
        be_ras_addr = {ft_line, q_e} + (VA - 1)'(1);
    end

endmodule : OOO_FERS
