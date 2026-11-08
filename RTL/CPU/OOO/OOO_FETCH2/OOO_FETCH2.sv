//---------------------------------------------------------------------------
// OOO_FETCH2.sv
//
// The front end of the 4-wide core at 50 MHz (step 1.5, F1a, Plan/OOC.md 29.37): F0 to
// F2 for blocks of 32 bytes, as OOO_FETCH is for 16 (its description holds for the
// rest: the requests in flight, the credit, the stop and the restore).
//
//   F0  the fetch address: OOO_UBTB2 (32 sets of 3 ways: the next one in one cycle), or
//       a redirect; the I$ request, OOO_TAGE2 and OOO_BTB read with it
//   F1  the I$ looks its tags up; TAGE and BTB compare theirs
//   F2  the I$ answer (32 bytes) into OOO_FDEC2, which finds the instructions and the
//       transfers of its 16 parcels, decides the block with what TAGE and the BTB give
//       (the first transfer predicted taken ends it), compares the next address with
//       where fetch went on and overrides F0 when they differ (2 cycles lost, as
//       before), moves the RAS (in it) and trains the uBTB a cycle later. The slots it
//       decided go back to TAGE in the same cycle (its metadata, its history).
//
// The block goes out as OOO_FETCH's does, with what OOO_FBUF3 takes besides: where
// instructions start (out_st) and the transfer that ends it (out_first). A 32-bit
// instruction across two lines: its first half (parcel 15) is kept in OOO_FDEC2 and
// finished with the next block, which then starts at parcel 0; the block of the first
// half ends at 15 without it (out_cross).
//
// The I$ is 32 bytes wide; in the simulation it is tb_core's model (the real one is
// step 1.7).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FETCH2
    #(
        parameter int VA = 39,
        parameter bit M  = 1'b1,        // OOO_TAGE2 with TAGE-M's sizes (0: S's)
        parameter int MW = M ? 531 : 290    // OOO_TAGE2's metadata
    )
    (
        input  logic                clk,
        input  logic                rst_n,

        // back end
        input  logic                be_stop,    // OOO_CTRL fe_redirect: stop now (the restore comes next cycle)
        input  logic                be_redirect,
        input  logic [VA-1:1]       be_pc,
        input  logic [(M ? 200 : 70)+1:0] be_hist,  // {cprev, history}: OOO_TAGE2's metadata of the block
        input  logic [1:0]          be_hist_n,
        input  logic [2:0]          be_hist_bits,
        input  logic [3:0]          be_ras_ptr,
        input  logic [VA-1:1]       be_ras_val,
        input  logic                be_ras_push,
        input  logic [VA-1:1]       be_ras_addr,
        input  logic                be_ras_pop,
        input  logic [3:0]          credit,     // blocks the fetch buffer and the FTQ can take

        // I$
        output logic                ic_req_valid,
        output logic [VA-1:1]       ic_req_pc,  // the fetch address (the I$ reads its line)
        input  logic                ic_req_ready,
        input  logic                ic_resp_valid,
        input  logic [255:0]        ic_resp_data,

        // the block (F2)
        output logic                out_valid,
        output logic [VA-1:1]       out_pc,     // the fetch address (its parcel is the start)
        output logic [255:0]        out_data,
        output logic [15:0]         out_st,     // an instruction starts at this parcel
        output logic [15:0]         out_first,  // the transfer that ends it, by its last parcel
        output logic                out_cross,  // a first half at parcel 15, for the next block
        output logic [3:0]          out_end,
        output logic                out_taken,
        output logic [VA-1:1]       out_next,   // the predicted next fetch address
        output logic [MW-1:0]       out_tmeta,
        output logic [3:0]          out_ras_ptr,
        output logic [VA-1:1]       out_ras_val,

        // TAGE update (commit), BTB update (resolution)
        input  logic                up_valid,
        input  logic [MW-1:0]       up_meta,
        input  logic [2:0]          up_ex,
        input  logic [2:0]          up_tk,
        input  logic [15:0]         up_pex,     // the branches past the slots (OOO_TAGE2)
        input  logic [15:0]         up_ptk,
        input  logic                bt_valid,
        input  logic [VA-1:1]       bt_pc,
        input  logic [VA-1:1]       bt_tgt
    );

    // ---- F0: the fetch address and the requests in flight
    logic [VA-1:1] pc_q;
    logic          ub_taken;
    logic [3:0]    ub_off;
    logic          ovr;                 // F2 redirects F0
    logic [VA-1:1] ovr_pc;
    logic          ub_upd, ub_upd_taken, ub_upd_cond, ub_upd_ret;     // the training, from OOO_FDEC2's registers
    logic [VA-1:1] ub_upd_pc, ub_upd_tgt;
    logic [VA-1:1] ras_top;
    logic          acc;

    OOO_UBTB2 #(.SETS(32), .VA(VA), .TW(12)) u_ubtb
        (.clk(clk), .rst_n(rst_n),
         .redirect(be_redirect || ovr), .redirect_pc(be_redirect ? be_pc : ovr_pc),
         .ras_top(ras_top), .stall(!acc),
         .fetch_pc(pc_q), .pred_taken(ub_taken), .pred_off(ub_off),
         .upd_valid(ub_upd), .upd_pc(ub_upd_pc), .upd_taken(ub_upd_taken), .upd_target(ub_upd_tgt),
         .upd_cond(ub_upd_cond), .upd_ret(ub_upd_ret));

    // the requests in flight, oldest first: address, still wanted, the uBTB's guess
    logic [VA-1:1] qpc   [4];
    logic [3:0]    qlive;
    logic [3:0]    qubt;
    logic [3:0]    quoff [4];
    logic [1:0]    qh;
    logic [2:0]    qn;
    logic [2:0]    nlive;
    always @(*) begin
        nlive = '0;
        for (int k = 0; k < 4; k++) if (3'(k) < qn && qlive[qh + 2'(k)]) nlive = nlive + 3'd1;
    end
    logic stop;                         // a redirect now or the cycle before it (what is in
                                        // flight then is dropped by the redirect)
    assign stop         = be_stop || be_redirect;
    assign ic_req_valid = !stop && {1'b0, credit} > {2'b0, nlive};
    assign ic_req_pc    = pc_q;
    assign acc          = ic_req_valid && ic_req_ready;

    // where fetch went on after the oldest request: the next one in flight, or F0
    logic [VA-1:1] expect_pc;
    assign expect_pc = (qn >= 3'd2) ? qpc[qh + 2'd1] : pc_q;

    // ---- F2
    logic          f2;                  // a block to use in this cycle, unless fetch is stopped now (stop:
    logic [VA-1:1] hpc;                 // late, so it only enables what the block does: Plan/OOC.md 29.41)
    assign f2 = ic_resp_valid && qlive[qh];

    logic [2:0]       hv, pp;
    logic [15:0]      base;
    logic [2:0]       sl_v, sl_pred;
    logic [2:0][3:0]  sl_par;
    logic [1:0]       sl_n;
    logic             b_hit;
    logic [3:0]       b_off;
    logic [VA-1:1]    b_tgt;
    logic [MW-1:0]    tmeta;

    OOO_FDEC2 #(.VA(VA)) u_fdec
        (.clk(clk), .rst_n(rst_n), .flush(be_redirect),
         .f2_valid(f2), .f2_kill(stop), .f2_line(hpc[VA-1:5]), .f2_start(hpc[4:1]), .f2_seq(hpc[4:1] == 4'd0),
         .f2_data(ic_resp_data), .f2_expect(expect_pc),
         .f2_hv(hv), .f2_pp(pp), .f2_base(base),
         .f2_bh(b_hit), .f2_boff(b_off), .f2_btgt(b_tgt),
         .f2_ubt(qubt[qh]), .f2_uoff(quoff[qh]),
         .out_valid(out_valid), .out_st(out_st), .out_first(out_first), .out_cross(out_cross),
         .out_end(out_end), .ovr(ovr), .ovr_pc(ovr_pc),
         .sl_v(sl_v), .sl_par(sl_par), .sl_pred(sl_pred), .sl_n(sl_n),
         .ub_valid(ub_upd), .ub_pc(ub_upd_pc), .ub_taken(ub_upd_taken), .ub_tgt(ub_upd_tgt),
         .ub_cond(ub_upd_cond), .ub_ret(ub_upd_ret),
         .rs_valid(be_redirect), .rs_ptr(be_ras_ptr), .rs_val(be_ras_val),
         .rs_push(be_ras_push), .rs_addr(be_ras_addr), .rs_pop(be_ras_pop),
         .ras_top(ras_top), .snap_ptr(out_ras_ptr), .snap_val(out_ras_val));

    OOO_TAGE2 #(.VA(VA), .M(M), .MW(MW)) u_tage
        (.clk(clk), .rst_n(rst_n),
         .f0_valid(acc), .f0_pc(pc_q), .f0_live((nlive >= 3'd2) ? 2'd2 : nlive[1:0]),
         .f2_hv(hv), .f2_pp(pp), .f2_base(base),
         .f2_sv(sl_v), .f2_par(sl_par), .f2_pred(sl_pred),
         .f2_push(f2), .f2_n(sl_n), .f2_meta(tmeta),      // (a stopped block's push: the restore of the next cycle wins)
         .rs_valid(be_redirect), .rs_hist(be_hist), .rs_n(be_hist_n), .rs_bits(be_hist_bits),
         .up_valid(up_valid), .up_meta(up_meta), .up_ex(up_ex), .up_tk(up_tk),
         .up_pex(up_pex), .up_ptk(up_ptk));

    OOO_BTB #(.VA(VA), .NLOG(8), .TW(10), .LB(5)) u_btb
        (.clk(clk), .rst_n(rst_n),
         .rd_en(acc), .rd_pc(pc_q), .hit(b_hit), .off(b_off), .tgt(b_tgt),
         .wr_valid(bt_valid), .wr_pc(bt_pc), .wr_tgt(bt_tgt));

    assign out_pc    = hpc;
    assign out_data  = ic_resp_data;
    assign out_taken = out_first != 16'd0;
    assign out_next  = ovr_pc;
    assign out_tmeta = tmeta;

    // ---- the state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qh    <= '0;
            qn    <= '0;
            qlive <= '0;
        end else begin
            logic [1:0] h;
            logic [2:0] n;
            h = qh; n = qn;
            if (ic_resp_valid) begin h = h + 2'd1; n = n - 3'd1; end
            // a redirect: nothing in flight is wanted any more (the answer of this cycle is used or dropped now)
            if (be_redirect || ovr) qlive <= '0;
            if (acc) begin
                qlive[h + n[1:0]] <= !(be_redirect || ovr);
                n = n + 3'd1;
            end
            qh <= h;
            qn <= n;
        end
    end
    always_ff @(posedge clk) begin
        if (acc) begin
            logic [1:0] t;              // the new entry goes after the ones there (a pop this cycle moves only the head)
            t = qh + qn[1:0];
            qpc[t]   <= pc_q;
            qubt[t]  <= ub_taken;
            quoff[t] <= ub_off;
        end
        // the oldest request after this cycle's answer and request
        if (ic_resp_valid) begin
            if (qn >= 3'd2) hpc <= qpc[qh + 2'd1];
            else if (acc)   hpc <= pc_q;
        end else if (qn == 3'd0 && acc) begin
            hpc <= pc_q;
        end
    end

endmodule : OOO_FETCH2
