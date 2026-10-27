//---------------------------------------------------------------------------
// OOO_DSREG.sv
//
// The payload of mmRISC-3's DS register (Plan/OOC.md 20), between renaming
// (D2) and dispatch (DS): the two renamed µops' source tags with their ready
// bits, and W bits each of everything else dispatch writes (the issue
// queue's fields and payload, the ROB's, the LSU's). Their valid bits and
// branch masks are OOO_CTRL's (ds_valid, d_bmask); load is OOO_CTRL ds_load
// (the register is empty or its µops go now), else the register holds.
//
// The ready bits must not miss a wakeup. Renaming's busy bits are cleared by
// the issue queue's wakeup tags (OOO_IQ wk_*, at the clock edge of the
// cycle they are broadcast), so a µop renamed after a wakeup reads its
// source ready; the issue queue takes the wakeup of the cycle a µop is
// dispatched (OOO_IQ disp_rdy || woken). Between the two, a µop renamed in
// cycle r and dispatched in cycle d > r + 1 would miss the wakeups of
// cycles r .. d - 1. The register keeps a copy of the wakeup tags from the
// cycle before (wq) and ORs them into its ready bits every cycle: the
// ready bits given to dispatch are the held ones with the wakeups of the
// cycle before (the capture cycle's own wakeups the cycle after it). All
// compares are of registered tags, off renaming's and the issue queue's
// paths.
//
// A stale wakeup (of a µop that was killed or flushed, whose register may
// be given out again) must not reach it: the issue queue does not send the
// delayed wakeup of a µop killed or flushed when it issued, and the units
// that wake from outside (a divide, AMO) only wake for live µops; renaming
// gives out a killed µop's register a cycle after the restore at the
// earliest, when only those can still come.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DSREG
    #(
        parameter int W    = 64,
        parameter int TAGW = 6,
        parameter int NB   = 6          // wakeup buses (OOO_IQ wk_*)
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,
        input  logic                        load,       // OOO_CTRL ds_load
        input  logic [1:0][1:0][TAGW-1:0]   in_src,     // OOO_RENAME out_src
        input  logic [1:0][1:0]             in_use,
        input  logic [1:0][1:0]             in_rdy,     // OOO_RENAME out_rdy
        input  logic [1:0][W-1:0]           in_data,
        input  logic [NB-1:0]               wk_valid,   // OOO_IQ wk_*
        input  logic [NB-1:0][TAGW-1:0]     wk_tag,
        output logic [1:0][1:0][TAGW-1:0]   ds_src,
        output logic [1:0][1:0]             ds_use,
        output logic [1:0][1:0]             ds_rdy,     // to OOO_IQ disp_rdy
        output logic [1:0][W-1:0]           ds_data
    );

    logic [NB-1:0]           wq_v;
    logic [NB-1:0][TAGW-1:0] wq_t;
    logic [1:0][1:0]         rq;

    function automatic logic woken_q(input logic [TAGW-1:0] t);
        logic w;
        w = 1'b0;
        for (int b = 0; b < NB; b++) if (wq_v[b] && wq_t[b] == t) w = 1'b1;
        return w;
    endfunction

    always @(*) begin
        for (int k = 0; k < 2; k++)
            for (int s = 0; s < 2; s++)
                ds_rdy[k][s] = rq[k][s] || woken_q(ds_src[k][s]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) wq_v <= '0;
        else        wq_v <= wk_valid;
    end
    always_ff @(posedge clk) begin
        wq_t <= wk_tag;
        if (load) begin
            ds_src  <= in_src;
            ds_use  <= in_use;
            rq      <= in_rdy;
            ds_data <= in_data;
        end else begin
            rq      <= ds_rdy;
        end
    end

endmodule : OOO_DSREG
