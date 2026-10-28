//---------------------------------------------------------------------------
// OOO_FETCH.sv
//
// The front end of mmRISC-3 (Doc/UARCH.md 3.1, 3.2): F0 to F2, from the
// next fetch address to a block for the fetch buffer and the FTQ.
//
//   F0  the fetch address (OOO_UBTB: the next one in one cycle, or a
//       redirect); the I$ request, TAGE and BTB read with it
//   F1  the I$ looks its tags up; TAGE and BTB compare theirs
//   F2  the I$ answer (16 bytes); predecode (OOO_PREDEC) finds the control
//       transfers; the first one predicted taken ends the block:
//         conditional branch  TAGE (its slot: 1st, 2nd, 3rd branch of the
//                             block); a 4th or later one: not taken (its
//                             counters would never be trained; none in
//                             CoreMark, Plan/OOC.md 14.1)
//         jal, c.j            always, target from predecode
//         return              always, target from the RAS
//         other jalr          when the BTB has it at that parcel
//       The block goes out (out_*: to the fetch buffer and the FTQ, with
//       the predictor state the FTQ keeps); the history gets the slot
//       predictions, the RAS the call's push or the return's pop. If the
//       next address differs from the one fetch went on with (the uBTB's
//       guess), F0 is redirected there (2 cycles lost, `override_at` 2 of
//       the model) and the uBTB is trained.
//
// The I$ (mmRISC-2's ICACHE, 16 bytes wide): a request accepted at F0 is
// answered 2 cycles later on a hit, later on a miss, in order; a request
// is accepted the cycle after another only if that one hits. TAGE and BTB
// keep their F1 results for exactly that timing. Fetch keeps the requests
// in flight (at most 2, plus one in a redirect cycle) and drops the answers
// to the ones a redirect made useless; the I$ answers every request it
// accepted (no kill: the order of the answers is all fetch needs). It asks
// for a block only while the fetch buffer and the FTQ have room for it and
// those in flight (`credit`), so an answer never has to wait.
//
// A 32-bit instruction across two lines: the block of its first half ends
// there without it (out_end 7, its parcel 7 kept as `carry`), and it is
// predecoded with the next block, which is always the next line (OOO_FBUF
// gives it from the first half's block).
//
// A misprediction found in the back end (be_redirect) restarts fetch at
// be_pc and puts back the history (the block's TAGE metadata and its slot
// outcomes) and the RAS (its snapshot, and the push or pop of the
// mispredicted transfer), all from the FTQ (OOO_FERS, a cycle after the
// back end's redirect). In that cycle before, be_stop (OOO_CTRL's
// redirect) stops fetch at once: nothing in flight is used and nothing is
// asked, so no block of the wrong path reaches the fetch buffer or the FTQ
// while the restore is read (Plan/OOC.md 21). TAGE is updated at commit
// (up_*), the BTB at the resolution of an indirect jump (bt_*).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FETCH
    #(
        parameter int VA = 39,
        parameter int MW = 270          // OOO_TAGE's metadata
    )
    (
        input  logic                clk,
        input  logic                rst_n,

        // back end
        input  logic                be_stop,    // OOO_CTRL fe_redirect: stop now (the restore comes next cycle)
        input  logic                be_redirect,
        input  logic [VA-1:1]       be_pc,
        input  logic [69:0]         be_hist,
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
        input  logic [127:0]        ic_resp_data,

        // the block (F2)
        output logic                out_valid,
        output logic [VA-1:1]       out_pc,     // the fetch address (its parcel is the start)
        output logic [127:0]        out_data,
        output logic [2:0]          out_end,
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
        input  logic                bt_valid,
        input  logic [VA-1:1]       bt_pc,
        input  logic [VA-1:1]       bt_tgt
    );

    // ---- F0: the fetch address and the requests in flight
    logic [VA-1:1] pc_q;
    logic          ub_taken;
    logic [2:0]    ub_off;
    logic          ovr;                 // F2 redirects F0
    logic [VA-1:1] ovr_pc;
    logic          ub_upd, ub_upd_taken, ub_upd_cond, ub_upd_ret;
    logic [VA-1:1] ub_upd_pc, ub_upd_tgt;
    logic [VA-1:1] ras_top;
    logic          acc;

    OOO_UBTB #(.NE(8), .VA(VA), .TW(12)) u_ubtb
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
    logic [2:0]    quoff [4];
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
    logic          f2;                  // a block to use in this cycle
    logic [VA-1:1] hpc;                 // the oldest request's address, in a register of its own
    logic          carry_v;              // (not read from the queue: it starts the longest path, Plan/OOC.md 14.5)
    logic [15:0]   carry;
    assign f2  = ic_resp_valid && qlive[qh] && !stop;

    logic [7:0]          iv, br, jal, jalr, call, ret;
    logic [7:0][VA-1:1]  tgt;
    logic                cross_out;
    OOO_PREDEC #(.VA(VA)) u_predec
        (.line(hpc[VA-1:4]), .start(hpc[3:1]), .carry_v(carry_v), .carry(carry), .data(ic_resp_data),
         .iv(iv), .br(br), .jal(jal), .jalr(jalr), .call(call), .ret(ret), .tgt(tgt),
         .cross_out(cross_out));

    // the slots: the first three conditional branches of the block
    logic [2:0]       sv;
    logic [2:0][2:0]  par;
    logic [7:0][1:0]  slot;             // the slot of the branch at each parcel (3: past the slots)
    always @(*) begin
        logic [1:0] n;
        n = '0; sv = '0; par = '0;
        for (int e = 0; e < 8; e++) begin
            slot[e] = n;
            if (br[e] && n != 2'd3) begin
                sv[n]  = 1'b1;
                par[n] = 3'(e);
                n = n + 2'd1;
            end
        end
    end

    logic [2:0]    tpred;
    logic [MW-1:0] tmeta;
    logic          b_hit;
    logic [2:0]    b_off;
    logic [VA-1:1] b_tgt;
    logic [1:0]    hn;

    // the first transfer predicted taken, the end of the block, the next address
    logic [7:0]    tk, first;
    logic          taken, same;
    logic [2:0]    e_end;
    logic [VA-1:1] nxt;
    always @(*) begin
        for (int e = 0; e < 8; e++)
            tk[e] = iv[e] && ((br[e] && slot[e] != 2'd3 && tpred[slot[e]]) || jal[e] ||
                              (jalr[e] && (ret[e] || (b_hit && b_off == 3'(e)))));
        first = tk & (~tk + 8'd1);
        taken = tk != 8'd0;
        e_end = 3'd7;
        for (int e = 7; e >= 0; e--) if (first[e]) e_end = 3'(e);
        nxt = {hpc[VA-1:4] + (VA-4)'(1), 3'd0};
        for (int e = 0; e < 8; e++)
            if (first[e]) nxt = (br[e] || jal[e]) ? tgt[e] : ret[e] ? ras_top : b_tgt;
        // whether it is where fetch went on: every candidate compared in parallel
        // (the targets are ready long before the choice), the result chosen as nxt is
        same = {hpc[VA-1:4] + (VA-4)'(1), 3'd0} == expect_pc;
        for (int e = 0; e < 8; e++)
            if (first[e]) same = (br[e] || jal[e]) ? tgt[e] == expect_pc : ret[e] ? ras_top == expect_pc : b_tgt == expect_pc;
        // the slot predictions up to the end go into the history
        hn = '0;
        for (int s = 0; s < 3; s++) if (sv[s] && par[s] <= e_end) hn = hn + 2'd1;
    end

    assign ovr    = f2 && !same;
    assign ovr_pc = nxt;

    // train the uBTB with F2's decision when they differed: its transfer, or
    // (when it guessed a taken one earlier, or none at all) its guess not taken
    always @(*) begin
        logic hit_first;
        hit_first = taken && !(qubt[qh] && quoff[qh] < e_end);
        ub_upd       = ovr && (hit_first || qubt[qh]);
        ub_upd_pc    = {hpc[VA-1:4], hit_first ? e_end : quoff[qh]};
        ub_upd_taken = hit_first;
        ub_upd_tgt   = nxt;
        ub_upd_cond  = br[e_end];
        ub_upd_ret   = ret[e_end];
    end

    OOO_TAGE #(.VA(VA), .MW(MW)) u_tage
        (.clk(clk), .rst_n(rst_n),
         .f0_valid(acc), .f0_pc(pc_q),
         .f2_sv(sv), .f2_par(par), .f2_pred(tpred),
         .f2_push(f2), .f2_n(hn), .f2_meta(tmeta),
         .rs_valid(be_redirect), .rs_hist(be_hist), .rs_n(be_hist_n), .rs_bits(be_hist_bits),
         .up_valid(up_valid), .up_meta(up_meta), .up_ex(up_ex), .up_tk(up_tk));

    OOO_BTB #(.VA(VA), .NLOG(8), .TW(10)) u_btb
        (.clk(clk), .rst_n(rst_n),
         .rd_en(acc), .rd_pc(pc_q), .hit(b_hit), .off(b_off), .tgt(b_tgt),
         .wr_valid(bt_valid), .wr_pc(bt_pc), .wr_tgt(bt_tgt));

    logic [3:0] ras_ptr;
    OOO_RAS #(.VA(VA), .N(16)) u_ras
        (.clk(clk), .rst_n(rst_n),
         .top(ras_top), .snap_ptr(ras_ptr), .snap_val(out_ras_val),
         .push(f2 && taken && call[e_end]), .push_addr({hpc[VA-1:4], e_end} + (VA-1)'(1)),
         .pop(f2 && taken && ret[e_end]),
         .rs_valid(be_redirect), .rs_ptr(be_ras_ptr), .rs_val(be_ras_val),
         .rs_push(be_ras_push), .rs_addr(be_ras_addr), .rs_pop(be_ras_pop));
    assign out_ras_ptr = ras_ptr;

    assign out_valid = f2;
    assign out_pc    = hpc;
    assign out_data  = ic_resp_data;
    assign out_end   = e_end;
    assign out_taken = taken;
    assign out_next  = nxt;
    assign out_tmeta = tmeta;

    // ---- the state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qh      <= '0;
            qn      <= '0;
            qlive   <= '0;
            carry_v <= 1'b0;
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
            if (be_redirect) carry_v <= 1'b0;
            else if (f2)     carry_v <= cross_out && !taken;
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
        if (f2) carry <= ic_resp_data[127:112];
        // the oldest request after this cycle's answer and request
        if (ic_resp_valid) begin
            if (qn >= 3'd2) hpc <= qpc[qh + 2'd1];
            else if (acc)   hpc <= pc_q;
        end else if (qn == 3'd0 && acc) begin
            hpc <= pc_q;
        end
    end

endmodule : OOO_FETCH
