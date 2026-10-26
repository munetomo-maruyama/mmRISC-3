//---------------------------------------------------------------------------
// OOO_UBTB.sv
//
// The next-line predictor of mmRISC-3 (F0, STRATEGY.md 4): it gives the
// fetch address of the next cycle from the one of this cycle, a 1-cycle
// loop. NE entries, fully associative, one control transfer each:
//   tag     a partial tag of the 16-byte block of the transfer: the block
//           address (address / 16) folded to TW bits (its low TW bits XOR
//           the next TW). Two blocks may share a tag; the prediction is
//           checked at F2 anyway, so an alias costs an override only
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
// resolution), replacing round robin when the transfer has no entry, so no
// two entries have the same tag and parcel.
//
// The choice is parallel (Plan/OOC.md 7.6: written as a loop over the
// entries, each comparing its parcel with the best so far, it became 32
// comparisons in series, 65 logic levels): for each of the 8 parcels the OR
// of the entries that hit there, the first parcel by an 8-bit priority, and
// the target read by an AND-OR of the one entry that hit at that parcel.
// 8 entries since G0b (L5, Doc/UARCH.md 6.3: 16 -> 8 is -0.6 % / -0.1 %
// in the model); 16 were -0.2 % / -0.1 % against 32 (Plan/OOC.md 7.6), and
// none would be -4.8 % / -2.1 %.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_UBTB
    #(
        parameter int NE = 8,          // G0b L5 (Doc/UARCH.md 6.3): 16 -> 8
        parameter int VA = 39,         // Sv39
        parameter int TW = 12          // partial tag
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

    // (the parcel bits and the block bits above 2 TW are not in the tag)
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [TW-1:0] tag_of(input logic [VA-1:1] a);
        logic [BW-1:0] b;
        b = a[VA-1:4];
        return b[TW-1:0] ^ b[2*TW-1:TW];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // arrays (not packed vectors) where an entry is chosen at run time
    logic [NE-1:0]          v;
    logic [NE-1:0]          cond, ret;
    logic [TW-1:0]          tag [NE];
    logic [2:0]             off [NE];
    logic [VA-1:1]          tgt [NE];
    logic [1:0]             cnt [NE];
    logic [EW-1:0]          rr;

    logic [VA-1:1] pc_q;
    assign fetch_pc = pc_q;

    // prediction
    logic [TW-1:0] ptag;
    logic [NE-1:0] hit, sel;
    logic [7:0]    at, first;           // a hit at parcel o; the first of them, one-hot
    logic [VA-1:1] next_pc, t_sel;
    always @(*) begin
        ptag = tag_of(pc_q);
        for (int e = 0; e < NE; e++)
            hit[e] = v[e] && tag[e] == ptag && off[e] >= pc_q[3:1] && (!cond[e] || cnt[e][1]);
        at = 8'd0;
        for (int e = 0; e < NE; e++)
            at = at | ({7'd0, hit[e]} << off[e]);
        first = at & (~at + 8'd1);      // the lowest bit that is set
        for (int e = 0; e < NE; e++)
            sel[e] = hit[e] && first[off[e]];
        // the target of the entry chosen, or the stack for a return (chosen
        // after the AND-OR, not in every entry)
        t_sel = '0;
        for (int e = 0; e < NE; e++)
            t_sel = t_sel | ({(VA-1){sel[e]}} & tgt[e]);
        if ((sel & ret) != '0) t_sel = ras_top;
        pred_taken = at != 8'd0;
        pred_off   = 3'd7;
        for (int o = 7; o >= 0; o--) if (first[o]) pred_off = 3'(o);
        next_pc = pred_taken ? t_sel : {pc_q[VA-1:4] + BW'(1), 3'd0};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        pc_q <= '0;
        else if (redirect) pc_q <= redirect_pc;
        else if (!stall)   pc_q <= next_pc;
    end

    // update: the entry of the transfer (at most one), else a new one
    logic [TW-1:0] utag;
    logic [NE-1:0] match;
    logic          found;
    always @(*) begin
        utag = tag_of(upd_pc);
        for (int e = 0; e < NE; e++)
            match[e] = v[e] && tag[e] == utag && off[e] == upd_pc[3:1];
        found = match != '0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                rr <= '0;
        else if (upd_valid && !found && upd_taken) rr <= rr + EW'(1);
    end

    for (genvar e = 0; e < NE; e++) begin : g_ent
        logic fill;
        assign fill = upd_valid && !found && upd_taken && rr == EW'(e);
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) v[e] <= 1'b0;
            else if (fill) v[e] <= 1'b1;
        end
        always_ff @(posedge clk) begin
            if (fill) begin
                tag[e]  <= utag;
                off[e]  <= upd_pc[3:1];
                tgt[e]  <= upd_target;
                cnt[e]  <= 2'd2;
                cond[e] <= upd_cond;
                ret[e]  <= upd_ret;
            end else if (upd_valid && match[e]) begin
                if (upd_taken) begin
                    tgt[e] <= upd_target;
                    if (cnt[e] != 2'd3) cnt[e] <= cnt[e] + 2'd1;
                end else if (cnt[e] != 2'd0) begin
                    cnt[e] <= cnt[e] - 2'd1;
                end
            end
        end
    end

endmodule : OOO_UBTB
