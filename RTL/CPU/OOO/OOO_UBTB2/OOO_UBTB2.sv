//---------------------------------------------------------------------------
// OOO_UBTB2.sv
//
// The next-line predictor of the 4-issue core at 100 MHz (F0; Doc/STRATEGY.md
// 4.5 loop 6, Plan/OOC.md 28.11): the fetch address of the next cycle from the
// one of this cycle, a 1-cycle loop, for fetch blocks of 32 bytes.
//
// SETS sets of 3 ways, indexed by the block's address, all in distributed RAM,
// so that a lookup compares 3 tags, not all of them, and the capacity costs next
// to nothing: a RAM of 32 is as small as one of 16.
//   tag   TW bits of the block's address above the index (not folded: one level
//         less). Two blocks may share them; F2 checks the prediction anyway, so
//         an alias costs an override, and so does a stale entry: there is no
//         reset of the table but its initial state
//   off   its parcel in the block (0 .. 15, the parcel of its last half)
//   act   predicted taken: not a conditional branch, or its counter at 2 or 3
//   ret   the target is the top of the return address stack
//   tgt   the target
// In a set the first way by parcel wins: which of 2 ways comes first is kept in
// 3 bits per set, written with a way, so no parcels are compared in the choice.
// (No 2 ways that hit have the same parcel: that would be one transfer.)
//
// The prediction reads its own copy, the update another (u_*): the entry of the
// transfer (at most one), else a new one, round robin in the set.
//
// redirect, redirect_pc, stall, ras_top must come from registers: they are in
// the last LUT with pc_q's next value, but with nothing in front of that.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_UBTB2
    #(
        parameter int SETS = 32,
        parameter int VA   = 39,       // Sv39
        parameter int TW   = 12        // partial tag
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
        output logic [3:0]    pred_off,       // the parcel the block ends at

        input  logic          upd_valid,
        input  logic [VA-1:1] upd_pc,         // address of the transfer's last parcel
        input  logic          upd_taken,
        input  logic [VA-1:1] upd_target,
        input  logic          upd_cond,
        input  logic          upd_ret
    );

    localparam int IW = $clog2(SETS);
    localparam int OW = TW + 4 + 1;           // tag, off, ret

    // a[4:1] the parcel, a[5+IW-1:5] the index, then the tag; the rest is not looked at
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [IW-1:0] idx_of(input logic [VA-1:1] a);
        return a[5+IW-1:5];
    endfunction
    function automatic logic [TW-1:0] tag_of(input logic [VA-1:1] a);
        return a[5+IW+TW-1:5+IW];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    logic [VA-1:1] pc_q;
    (* keep = "true", max_fanout = 32 *) logic [IW-1:0] pi_q;       // pc_q's index, for the RAM alone
    assign fetch_pc = pc_q;

    logic [IW-1:0]   wi;                      // the update's set
    logic [2:0]      we_new, we_upd;          // a way: filled; its transfer seen
    logic            we_any;
    logic [2:0]      we_tgt;
    logic [TW-1:0]   w_tag;
    logic [3:0]      w_off;
    logic [1:0]      w_cnt [3];
    logic            w_act [3];

    // ---- the ways
    logic [2:0]      r_act, r_ret, hit;
    logic [TW-1:0]   r_tag [3];
    logic [3:0]      r_off [3];
    logic [VA-1:1]   r_tgt [3];
    logic [2:0]      u_v, u_cond, match;
    logic [TW-1:0]   u_tag [3];
    logic [3:0]      u_off [3];
    logic [1:0]      u_cnt [3];
    for (genvar w = 0; w < 3; w++) begin : g_way
        (* ram_style = "distributed" *) logic [OW-1:0]   p_t [SETS];
        (* ram_style = "distributed" *) logic            p_a [SETS];
        (* ram_style = "distributed" *) logic [VA-1:1]   p_d [SETS];
        (* ram_style = "distributed" *) logic [TW+5:0]   q_t [SETS];
        (* ram_style = "distributed" *) logic [1:0]      q_c [SETS];
        initial begin
            for (int i = 0; i < SETS; i++) begin
                p_t[i] = '0; p_a[i] = 1'b0; p_d[i] = '0; q_t[i] = '0; q_c[i] = '0;
            end
        end
        always_ff @(posedge clk) begin
            if (we_new[w]) p_t[wi] <= {w_tag, w_off, upd_ret};
            if (we_new[w]) q_t[wi] <= {1'b1, upd_cond, w_tag, w_off};
            if (we_new[w] || we_upd[w]) begin
                p_a[wi] <= w_act[w];
                q_c[wi] <= w_cnt[w];
            end
            if (we_tgt[w]) p_d[wi] <= upd_target;
        end
        assign {r_tag[w], r_off[w], r_ret[w]} = p_t[pi_q];
        assign r_act[w] = p_a[pi_q];
        assign r_tgt[w] = p_d[pi_q];
        assign {u_v[w], u_cond[w], u_tag[w], u_off[w]} = q_t[wi];
        assign u_cnt[w] = q_c[wi];
    end

    // the order in a set: way 0 before 1, 0 before 2, 1 before 2
    (* ram_style = "distributed" *) logic [2:0] p_b [SETS];
    (* ram_style = "distributed" *) logic [1:0] q_r [SETS];         // the next way to fill
    logic [2:0] b, new_b;
    logic [1:0] w_rr;
    initial begin
        for (int i = 0; i < SETS; i++) begin p_b[i] = '0; q_r[i] = '0; end
    end
    assign b    = p_b[pi_q];
    assign w_rr = q_r[wi];
    always_ff @(posedge clk) begin
        if (we_any) begin
            p_b[wi] <= new_b;
            q_r[wi] <= w_rr == 2'd2 ? 2'd0 : w_rr + 2'd1;
        end
    end

    // ---- the prediction
    logic [TW-1:0] ptag;
    logic [3:0]    start;
    logic [2:0]    sel, sel_t;
    logic          any, any_r, ovr;
    logic [VA-1:1] t, late, seq, hr;
    always @(*) begin
        ptag  = tag_of(pc_q);
        start = pc_q[4:1];
        for (int w = 0; w < 3; w++)
            hit[w] = r_act[w] && r_tag[w] == ptag && r_off[w] >= start;
        sel[0] = hit[0] && !(hit[1] && !b[0]) && !(hit[2] && !b[1]);
        sel[1] = hit[1] && !(hit[0] &&  b[0]) && !(hit[2] && !b[2]);
        sel[2] = hit[2] && !(hit[0] &&  b[1]) && !(hit[1] &&  b[2]);
        sel_t  = sel & ~r_ret;
        any    = hit != 3'd0;
        any_r  = (sel & r_ret) != 3'd0;
        pred_taken = any;
        pred_off   = ({4{sel[0]}} & r_off[0]) | ({4{sel[1]}} & r_off[1]) | ({4{sel[2]}} & r_off[2]);
        if (!any) pred_off = 4'd15;

        t    = ({(VA-1){sel_t[0]}} & r_tgt[0]) | ({(VA-1){sel_t[1]}} & r_tgt[1]) | ({(VA-1){sel_t[2]}} & r_tgt[2]);
        seq  = {pc_q[VA-1:5] + (VA-5)'(1), 4'd0};
        late = ({(VA-1){any_r}} & ras_top) | ({(VA-1){!any}} & seq);
        ovr  = redirect || stall;
        hr   = redirect ? redirect_pc : pc_q;
    end

    logic [VA-1:1] pc_d;
    assign pc_d = ovr ? hr : t | late;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_q <= '0;
            pi_q <= '0;
        end else begin
            pc_q <= pc_d;
            pi_q <= idx_of(pc_d);
        end
    end

    // ---- the update
    logic       found;
    logic [3:0] o0, o1, o2;
    always @(*) begin
        wi    = idx_of(upd_pc);
        w_tag = tag_of(upd_pc);
        w_off = upd_pc[4:1];
        for (int w = 0; w < 3; w++)
            match[w] = u_v[w] && u_tag[w] == w_tag && u_off[w] == w_off;
        found  = match != 3'd0;
        we_any = upd_valid && !found && upd_taken;
        for (int w = 0; w < 3; w++) begin
            we_new[w] = we_any && w_rr == 2'(w);
            we_upd[w] = upd_valid && match[w];
            we_tgt[w] = we_new[w] || (we_upd[w] && upd_taken);
            if (we_new[w]) begin
                w_cnt[w] = 2'd2;
                w_act[w] = 1'b1;
            end else if (upd_taken) begin
                w_cnt[w] = u_cnt[w] == 2'd3 ? 2'd3 : u_cnt[w] + 2'd1;
                w_act[w] = !u_cond[w] || w_cnt[w][1];
            end else begin
                w_cnt[w] = u_cnt[w] == 2'd0 ? 2'd0 : u_cnt[w] - 2'd1;
                w_act[w] = !u_cond[w] || w_cnt[w][1];
            end
        end
        o0 = we_new[0] ? w_off : u_off[0];
        o1 = we_new[1] ? w_off : u_off[1];
        o2 = we_new[2] ? w_off : u_off[2];
        new_b = {o1 <= o2, o0 <= o2, o0 <= o1};
    end

endmodule : OOO_UBTB2
