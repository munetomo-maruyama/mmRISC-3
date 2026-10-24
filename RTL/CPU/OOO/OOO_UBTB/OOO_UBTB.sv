//---------------------------------------------------------------------------
// OOO_UBTB.sv
//
// The next-line predictor of mmRISC-3 (F0, STRATEGY.md 4): it gives the
// fetch address of the next cycle from the one of this cycle, a 1-cycle
// loop. NE entries, fully associative, one control transfer each:
//   block   the 16-byte block of the transfer (address / 16)
//   off     its parcel in the block (0 .. 7, the parcel of its last half,
//           which is where fetch must stop)
//   target, cnt (2 bits, a conditional branch is taken from 2 up), ret (the
//   target is the top of the return address stack), cond
//
// The fetch address may start in the middle of a block (after a jump);
// entries before that point do not count. Of the hits, the first one in the
// block that is predicted taken decides: next = its target, else the next
// block. A redirect (the override of F2, or the back end) wins over the
// prediction. The table is written by upd_* (after the F2 predictors or at
// resolution), replacing round robin when the transfer has no entry.
//
// The model (Plan/MODEL.md 6) found the uBTB worth little in CoreMark with
// a decoupled front end (no uBTB: -0.9 %); the loop is kept small so that it
// closes at 50 MHz, or can be left out.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_UBTB
    #(
        parameter int NE = 32,
        parameter int VA = 39          // Sv39
    )
    (
        input  logic          clk,
        input  logic          rst_n,

        input  logic          redirect,
        input  logic [VA-1:1] redirect_pc,
        input  logic [VA-1:1] ras_top,
        input  logic          stall,          // fetch cannot take a block this cycle

        output logic [VA-1:1] fetch_pc,       // F0: this cycle's fetch address
        output logic          pred_taken,
        output logic [2:0]    pred_off,       // the parcel the block ends at

        input  logic          upd_valid,
        input  logic [VA-1:1] upd_pc,         // address of the transfer's last parcel
        input  logic          upd_taken,
        input  logic [VA-1:1] upd_target,
        input  logic          upd_cond,
        input  logic          upd_ret
    );

    localparam int BW = VA - 4;               // block address bits
    localparam int EW = $clog2(NE);

    // arrays (not packed vectors) where an entry is chosen at run time
    logic [NE-1:0]          v;
    logic [NE-1:0]          cond, ret;
    logic [BW-1:0]          blk [NE];
    logic [2:0]             off [NE];
    logic [VA-1:1]          tgt [NE];
    logic [1:0]             cnt [NE];
    logic [EW-1:0]          rr;

    logic [VA-1:1] pc_q;
    assign fetch_pc = pc_q;

    // prediction
    logic [VA-1:1] next_pc;
    always @(*) begin
        logic [NE-1:0] hit;
        logic [3:0]    best;            // 8: none
        logic [EW-1:0] bi;
        for (int e = 0; e < NE; e++)
            hit[e] = v[e] && blk[e] == pc_q[VA-1:4] && off[e] >= pc_q[3:1]
                     && (!cond[e] || cnt[e][1]);
        best = 4'd8; bi = '0;
        for (int e = 0; e < NE; e++)
            if (hit[e] && {1'b0, off[e]} < best) begin best = {1'b0, off[e]}; bi = EW'(e); end
        pred_taken = !best[3];
        pred_off   = best[3] ? 3'd7 : best[2:0];
        if (pred_taken) next_pc = ret[bi] ? ras_top : tgt[bi];
        else            next_pc = {pc_q[VA-1:4] + BW'(1), 3'd0};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        pc_q <= '0;
        else if (redirect) pc_q <= redirect_pc;
        else if (!stall)   pc_q <= next_pc;
    end

    // update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v  <= '0;
            rr <= '0;
        end else if (upd_valid) begin
            logic          found;
            logic [EW-1:0] fe;
            found = 1'b0; fe = '0;
            for (int e = 0; e < NE; e++)
                if (v[e] && blk[e] == upd_pc[VA-1:4] && off[e] == upd_pc[3:1]) begin found = 1'b1; fe = EW'(e); end
            if (found) begin
                if (upd_taken) begin
                    tgt[fe] <= upd_target;
                    if (cnt[fe] != 2'd3) cnt[fe] <= cnt[fe] + 2'd1;
                end else if (cnt[fe] != 2'd0) begin
                    cnt[fe] <= cnt[fe] - 2'd1;
                end
            end else if (upd_taken) begin
                v[rr]    <= 1'b1;
                blk[rr]  <= upd_pc[VA-1:4];
                off[rr]  <= upd_pc[3:1];
                tgt[rr]  <= upd_target;
                cnt[rr]  <= 2'd2;
                cond[rr] <= upd_cond;
                ret[rr]  <= upd_ret;
                rr       <= rr + EW'(1);
            end
        end
    end

endmodule : OOO_UBTB
