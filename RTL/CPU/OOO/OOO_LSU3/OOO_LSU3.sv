//---------------------------------------------------------------------------
// OOO_LSU3.sv
//
// The memory ports of the 4-wide core at 50 MHz (Doc/STRATEGY.md 4.2, 4.5 loop 3,
// Plan/OOC.md 29.7): load-use 2 with 2 ports, a D$ in block RAM, a DTLB and an SQ of 16.
// Port 0 (the queue's port 4) takes loads and stores, and what is tried again; port 1
// (port 5) loads only. OOO_LSU2 with M1 and M2 in one stage, and with what 100 MHz asked
// for gone:
//
//   RR  a µop from the queue, or one tried again on port 0 (rt_*)
//   E   the address (OOO_EXU2's ag); the arrays read its low bits at the end of the
//       stage; a store's data (OOO_EXU2's sd)
//   M   the arrays' data, aligned in each way; the tags compared; the DTLB; the SQ
//       searched; the result chosen; a store written into the SQ
//   W   what came of it: complete, or wait, a miss, a walk
//
// As in OOO_LSU2:
//   - The alignment in each way, before the way is known, with the SQ's word as a fifth way.
//   - The search compares the page's offset only. The rest is checked for the one store
//     chosen; a store with another page behind that offset makes the load wait for it
//     to leave.
//   - Nothing waits for the hit: ld_nv and ld_nt come with any load in M, and the register
//     is written whatever its value. The queue has no cancel: the dependents of a load are
//     woken at its issue + 2, and what they did is undone by replaying at the load's
//     commit (cmp_ld_rp).
//   - A µop that cannot finish goes to wait, and is tried again at an event that may have
//     changed things, one at a time, in turn; but first the µop whose miss or walk has
//     just ended. A try has no branch mask: any recovery drops it, and the event tries it
//     again.
//   - The stores that drain have their own pipeline and copy of the tags.
//
// New: a store is one µop, its data with it (Plan/OOC.md 29), so no load finds a store
// without its data. The queue lets a load go only after every older store's issue, a
// cycle before at least, so the store has written its entry when the load is in M.
//
// With 2 ports: each has its copy of the arrays (OOO_DCH2), its DTLB (written alike) and
// its search. Only port 0 asks for a line or a walk: a load of port 1 that needs one goes
// to wait and is tried again at once, on port 0 (its failure is an event). A miss costs some
// cycles more that way, and the mux is not on M's latest signals. What stays of a µop for a
// try is kept in a RAM per port, and a bit per LQ entry says which.
//
// What is not cacheable (step 1.3 E1b, Plan/OOC.md 29.33): an address outside [CBASE, CTOP), or in
// the line uc_line names (the bench's tohost). A load that finds one in W waits, whatever the D$ or
// the SQ has (a device's register is read, not forwarded); when it is the ROB's head (head_rob) and
// the SQ is drained, a try of it goes, and that try's W asks the device (uc_*); the answer's word
// goes into a register, and a last try takes it in M as its result. A store that finds one as it
// drains goes to the device, not to the D$. One access to a device at a time. Not here yet: AMO,
// LR, SC. The miss handler is outside, by miss_*, st_miss_*, tw_*, rf_*, fill_done.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_LSU3
    #(
        parameter int NLQ  = 16,
        parameter int NSQ  = 16,
        parameter int PAW  = 40,
        parameter int VA   = 39,
        parameter int TAGW = 7,
        parameter int ROBW = 6,
        parameter int NCK  = 12,
        parameter logic [PAW-1:0] CBASE = 40'h00_8000_0000,  // the cacheable memory: [CBASE, CTOP)
        parameter logic [PAW-1:0] CTOP  = 40'h01_0000_0000
    )
    (
        input  logic                     clk,
        input  logic                     rst_n,
        input  logic                     tr_on,

        // ---- dispatch: how many; renaming numbers them from the tails
        input  logic [2:0]               lq_alloc,
        input  logic [2:0]               sq_alloc,
        output logic [$clog2(NLQ):0]     lq_tail,
        output logic [$clog2(NSQ):0]     sq_tail,
        output logic [$clog2(NLQ):0]     lq_free,
        output logic [$clog2(NSQ):0]     sq_free,

        // ---- RR
        input  logic [1:0]               rr_valid,
        input  logic                     rr_ld,      // port 0: else a store (port 1: a load)
        input  logic [1:0][$clog2(NLQ)-1:0] rr_lq,
        input  logic [$clog2(NSQ)-1:0]   rr_sq,
        input  logic [1:0][$clog2(NSQ):0] rr_st,     // sq_tail at the load's dispatch: the stores older than it
        input  logic [1:0][1:0]          rr_size,
        input  logic [1:0]               rr_uns,
        input  logic [1:0][TAGW-1:0]     rr_dst,
        input  logic [1:0][ROBW-1:0]     rr_rob,
        input  logic [1:0][NCK-1:0]      rr_bm,
        output logic                     rt_v,       // a try goes in port 0's RR: the operand takes rt_base, offset 0
        output logic [PAW-1:0]           rt_base,

        // ---- E: from OOO_EXU2, late in the stage
        input  logic [1:0][63:0]         e_addr,
        input  logic [63:0]              e_sd,       // port 0: a store's data

        // ---- the result, in M: into OOO_EXU2's result registers and the register file
        output logic [1:0]               ld_nv,
        output logic [1:0][TAGW-1:0]     ld_nt,
        output logic [1:0][63:0]         ld_d,

        // ---- W
        output logic [1:0]               cmp_ld_valid,
        output logic [1:0][ROBW-1:0]     cmp_ld_rob,
        output logic [1:0]               cmp_ld_exc,
        output logic [1:0]               cmp_ld_rp,  // it ran more than once: fetch again what follows it
        output logic                     cmp_st_valid,  // a store: translated, with its data
        output logic [ROBW-1:0]          cmp_st_rob,
        output logic                     cmp_st_exc,

        // ---- commit and recovery
        input  logic [2:0]               lq_commit,
        input  logic [2:0]               sq_commit,
        input  logic                     restore,
        input  logic [NCK-1:0]           kill,
        input  logic [$clog2(NLQ):0]     restore_lq_tail,
        input  logic [$clog2(NSQ):0]     restore_sq_tail,
        input  logic                     flush_all,
        output logic                     sq_drained,

        // ---- the miss handler (outside), from and to registers
        output logic                     miss_valid,
        output logic [PAW-1:6]           miss_line,
        output logic [$clog2(NLQ+NSQ)-1:0] miss_id,  // who asks, for done_id
        output logic                     st_miss_valid,
        output logic [PAW-1:6]           st_miss_line,
        input  logic                     fill_done,
        input  logic                     done_v,     // with fill_done or tlb_done: it is for this µop
        input  logic [$clog2(NLQ+NSQ)-1:0] done_id,
        input  logic                     tw_en,
        input  logic [1:0]               tw_way,
        input  logic [5:0]               tw_set,
        input  logic [PAW-12:0]          tw_tag,     // {valid, tag}
        input  logic                     rf_en,      // a word of a fill; a store waits for it
        input  logic [1:0]               rf_way,
        input  logic [8:0]               rf_addr,
        input  logic [63:0]              rf_data,
        output logic                     dirty_set,
        output logic [1:0]               dirty_way,
        output logic [5:0]               dirty_idx,

        // ---- the walk (outside)
        output logic                     tlb_miss,
        output logic [VA-1:12]           tlb_miss_vpn,
        output logic [$clog2(NLQ+NSQ)-1:0] walk_id,
        input  logic                     tlb_done,   // an answer: written, or nothing (a fault says r_ok, w_ok at 0)
        input  logic                     tlb_we,
        input  logic [VA-1:12]           tlb_vpn,
        input  logic [PAW-1:12]          tlb_ptag,
        input  logic                     tlb_r,
        input  logic                     tlb_w,
        input  logic                     tlb_flush,
        output logic                     tlb_busy,

        // ---- what is not cacheable (step 1.3 E1b)
        input  logic                     uc_line_v,  // a line not cached (simulation: tohost)
        input  logic [PAW-1:6]           uc_line,
        input  logic [ROBW-1:0]          head_rob,   // the ROB's head
        output logic                     uc_req,     // an access to a device, one at a time
        output logic                     uc_we,
        output logic [PAW-1:0]           uc_addr,    // the byte's address
        output logic [1:0]               uc_size,
        output logic [63:0]              uc_wdata,   // a store's: its bytes in their places in the 8-byte word
        output logic [7:0]               uc_wmask,
        input  logic                     uc_done,    // the answer (a load's: uc_rdata, the 8-byte word)
        input  logic [63:0]              uc_rdata,

        // ---- a store written into the D$ goes on to memory too (the D$ written through: step 1.3 E2, Plan/OOC.md 29.34)
        output logic                     wt_valid,
        output logic [PAW-1:0]           wt_addr,    // the 8-byte word's address
        output logic [63:0]              wt_data,    // its bytes in their places
        output logic [7:0]               wt_mask,
        input  logic                     wt_ready    // the handler takes it; else the store waits in the drain
    );

    localparam int LW = $clog2(NLQ);
    localparam int SW = $clog2(NSQ);
    localparam int TW = PAW - 12;
    localparam int IW = $clog2(NLQ + NSQ);

    typedef logic [SW:0] sptr_t;
    typedef logic [LW:0] lptr_t;

    function automatic logic uncached(input logic [PAW-1:0] pa);
        return pa < CBASE || pa >= CTOP || (uc_line_v && pa[PAW-1:6] == uc_line);
    endfunction
    function automatic logic misal(input logic [1:0] size, input logic [2:0] a);
        case (size)
            2'd1:    return a[0];
            2'd2:    return a[1:0] != 2'd0;
            2'd3:    return a != 3'd0;
            default: return 1'b0;
        endcase
    endfunction
    function automatic logic [7:0] bmask(input logic [1:0] size, input logic [2:0] off);
        case (size)
            2'd0:    return 8'h01 << off;
            2'd1:    return 8'h03 << off;
            2'd2:    return 8'h0f << off;
            default: return 8'hff;
        endcase
    endfunction
    // entries from a up to b of a ring, b not behind a
    function automatic logic [NSQ-1:0] sring(input sptr_t a, input sptr_t b);
        logic [NSQ-1:0] ta, tb;
        for (int i = 0; i < NSQ; i++) begin
            ta[i] = SW'(i) < a[SW-1:0];
            tb[i] = SW'(i) < b[SW-1:0];
        end
        return (a[SW] == b[SW]) ? (~ta & tb) : (~ta | tb);
    endfunction
    function automatic logic [NLQ-1:0] lring(input lptr_t a, input lptr_t b);
        logic [NLQ-1:0] ta, tb;
        for (int i = 0; i < NLQ; i++) begin
            ta[i] = LW'(i) < a[LW-1:0];
            tb[i] = LW'(i) < b[LW-1:0];
        end
        return (a[LW] == b[LW]) ? (~ta & tb) : (~ta | tb);
    endfunction

    // a naturally aligned access: a bit of the result comes from few places.
    // spos: the byte with the sign; misaligned is an exception, its result unused
    function automatic logic [63:0] align(input logic [63:0] w, input logic [2:0] off, input logic [2:0] spos,
                                          input logic s0, input logic s01, input logic s3, input logic sen);
        logic        sg;
        logic [63:0] r;
        case (spos)
            3'd0:    sg = w[7];
            3'd1:    sg = w[15];
            3'd2:    sg = w[23];
            3'd3:    sg = w[31];
            3'd4:    sg = w[39];
            3'd5:    sg = w[47];
            3'd6:    sg = w[55];
            default: sg = w[63];
        endcase
        sg = sg && sen;
        case (off)
            3'd0:    r[7:0] = w[7:0];
            3'd1:    r[7:0] = w[15:8];
            3'd2:    r[7:0] = w[23:16];
            3'd3:    r[7:0] = w[31:24];
            3'd4:    r[7:0] = w[39:32];
            3'd5:    r[7:0] = w[47:40];
            3'd6:    r[7:0] = w[55:48];
            default: r[7:0] = w[63:56];
        endcase
        case ({s0, off[2:1]})
            3'b000:  r[15:8] = w[15:8];
            3'b001:  r[15:8] = w[31:24];
            3'b010:  r[15:8] = w[47:40];
            3'b011:  r[15:8] = w[63:56];
            default: r[15:8] = {8{sg}};
        endcase
        r[31:16] = s01 ? {16{sg}} : off[2] ? w[63:48] : w[31:16];
        r[63:32] = s3  ? w[63:32] : {32{sg}};
        return r;
    endfunction

    // ---- pointers
    lptr_t lq_head, lq_tail_q, lq_head_n, lq_tail_n;
    sptr_t sq_head, sq_cmt, sq_tail_q, sq_head_n, sq_cmt_n, sq_tail_n;
    logic  d3_v;
    assign lq_tail = lq_tail_q;
    assign sq_tail = sq_tail_q;
    always @(*) begin
        lq_head_n = lq_head + lptr_t'(lq_commit);
        sq_head_n = sq_head + sptr_t'(d3_v);
        sq_cmt_n  = sq_cmt + sptr_t'(sq_commit);
        lq_tail_n = flush_all ? lq_head_n : restore ? restore_lq_tail : lq_tail_q + lptr_t'(lq_alloc);
        sq_tail_n = flush_all ? sq_cmt_n  : restore ? restore_sq_tail : sq_tail_q + sptr_t'(sq_alloc);
        lq_free   = (LW + 1)'(NLQ) - (lq_tail_q - lq_head);
        sq_free   = (SW + 1)'(NSQ) - (sq_tail_q - sq_head);
        sq_drained = sq_head == sq_cmt;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lq_head <= '0; lq_tail_q <= '0;
            sq_head <= '0; sq_cmt <= '0; sq_tail_q <= '0;
        end else begin
            lq_head <= lq_head_n; lq_tail_q <= lq_tail_n;
            sq_head <= sq_head_n; sq_cmt <= sq_cmt_n; sq_tail_q <= sq_tail_n;
        end
    end

    // ---- the queues' state
    logic [NLQ-1:0] lv, lwait, lretry, lkp1;
    logic [NLQ-1:0] luc, lucd;               // a load for a device; its word is in uc_q
    logic [ROBW-1:0] lrob [NLQ];             // (a load for a device: its ROB entry)
    logic           uc_busy;                 // an access to a device is out
    logic [63:0]    uc_q;
    logic [NLQ-1:0] ugo;                     // a load for a device that may go now
    always @(*)
        for (int e = 0; e < NLQ; e++) ugo[e] = luc[e] && !lucd[e] && lrob[e] == head_rob && sq_drained && !uc_busy;
    logic [NSQ-1:0] sv, sp, swait, sretry;
    logic [8:0]     swa   [NSQ];         // the word's address in the page
    logic [7:0]     smask [NSQ];

    // what stays of the µop for a try: at its first M
    localparam int KW = PAW + 2 + 1 + TAGW + ROBW + (SW + 1);
    (* ram_style = "distributed" *) logic [KW-1:0] kp0 [NLQ + NSQ];
    (* ram_style = "distributed" *) logic [KW-1:0] kp1 [NLQ];

    // ---- what can be tried, a cycle ahead; then read; then at the first free RR
    logic [NLQ+NSQ-1:0] cand;
    logic [IW-1:0]      r_next, r_q, r_id;
    logic               r_any, r_qv, r_dv, r_busy, p_v;
    logic [IW-1:0]      p_id;
    logic [KW-1:0]      r_d;
    always @(*) begin
        cand   = {sv & swait & sretry, lv & lwait & lretry & (~luc | lucd | ugo)};
        r_any  = cand != '0;
        // in turn: the first after the last one tried; but first who has just been answered
        r_next = '0;
        for (int i = NLQ + NSQ - 1; i >= 0; i--) if (cand[i]) r_next = IW'(i);
        for (int i = NLQ + NSQ - 1; i >= 0; i--)
            if (cand[i] && IW'(i) > r_q) r_next = IW'(i);
        if (p_v && cand[p_id]) r_next = p_id;
    end

    logic          rec;       // a recovery: all tries go
    logic          w_done_try;
    assign rec  = restore || flush_all;
    assign rt_v = r_dv && !rr_valid[0] && !rec;
    logic [KW-1:0] rd_k;
    assign rd_k = (!r_q[LW] && lkp1[r_q[LW-1:0]]) ? kp1[r_q[LW-1:0]] : kp0[r_q];
    logic [PAW-1:0] r_va;
    logic [1:0]     r_size;
    logic           r_uns;
    logic [TAGW-1:0] r_dst;
    logic [ROBW-1:0] r_rob;
    logic [SW:0]    r_st;
    assign {r_va, r_size, r_uns, r_dst, r_rob, r_st} = r_d;
    assign rt_base = r_va;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_qv <= 1'b0; r_dv <= 1'b0; r_busy <= 1'b0;
        end else if (rec) begin
            r_qv <= 1'b0; r_dv <= 1'b0; r_busy <= 1'b0;
        end else begin
            if (!r_busy && r_any) begin
                r_qv   <= 1'b1;
                r_busy <= 1'b1;
            end else begin
                r_qv <= 1'b0;
                if (w_done_try) r_busy <= 1'b0;
            end
            if (r_qv)      r_dv <= 1'b1;
            else if (rt_v) r_dv <= 1'b0;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  p_v <= 1'b0;
        else if (done_v)             p_v <= 1'b1;
        else if (!r_busy || rec)     p_v <= 1'b0;
    end
    always_ff @(posedge clk) begin
        if (done_v) p_id <= done_id;
        if (!r_busy) r_q <= r_next;
        if (r_qv) begin
            r_d  <= rd_k;
            r_id <= r_q;
        end
    end

    function automatic logic drop(input logic tr, input logic [NCK-1:0] bm);
        return flush_all || (tr ? restore : (bm & kill) != '0);
    endfunction

    // ---- the arrays
    logic [1:0][8:0]       a_rd;
    logic [1:0][3:0][63:0] a_d;
    logic [1:0][3:0][TW:0] a_t;
    logic [3:0][TW:0]      s_t;
    logic [5:0]            d0_set;
    logic                  dw_en;
    logic [1:0]            dw_way;
    logic [8:0]            dw_addr;
    logic [63:0]           dw_data;
    logic [7:0]            dw_strb;
    OOO_DCH2 #(.SETS(64), .WAYS(4), .WORDS(8), .TW(TW)) u_dch
        (.clk(clk), .rd_addr(a_rd), .rd_data(a_d), .rd_tag(a_t),
         .sb_set(d0_set), .sb_tag(s_t),
         .tw_en(tw_en), .tw_way(tw_way), .tw_set(tw_set), .tw_tag(tw_tag),
         .dw_en(dw_en), .dw_way(dw_way), .dw_addr(dw_addr), .dw_data(dw_data), .dw_strb(dw_strb));

    // the SQ's RAMs, written by a store in M; read by the forwards and the drain
    (* ram_style = "distributed" *) logic [63:0]   sd_f [NSQ];
    (* ram_style = "distributed" *) logic [TW-1:0] st_r [NSQ];
    (* ram_style = "distributed" *) logic [7:0]    sm_f [NSQ];

    // ---- what the ports have in M and W, for the state below
    logic [1:0]           w_lives, w_oks, w_excs;
    logic                 w_ask1;     // port 1 needs a line or a walk
    logic                 w_try0, m_st0;
    logic [1:0][LW-1:0]   w_lqs;
    logic [1:0]           w_ucs;      // a load for a device, waiting for its turn
    logic [1:0][ROBW-1:0] w_robs;
    logic                 uc_ld_go;   // port 0's W asks a device for a load
    logic [LW-1:0]        uc_ld_lq;
    logic [PAW-1:0]       uc_ld_a;
    logic [1:0]           uc_ld_size;
    logic [1:0][IW-1:0]   m_ids;
    logic [1:0][KW-1:0]   m_kp;
    logic [1:0]           m_kpw;
    logic [1:0]           t_busy;

    for (genvar p = 0; p < 2; p++) begin : g_port
        // ---- E
        logic            e_v, e_ld, e_try, e_uns, e_live;
        logic [LW-1:0]   e_lq;
        logic [SW-1:0]   e_sq;
        logic [SW:0]     e_st;
        logic [1:0]      e_size;
        logic [TAGW-1:0] e_dst;
        logic [ROBW-1:0] e_rob;
        logic [NCK-1:0]  e_bm;
        logic [IW-1:0]   e_id;
        logic [63:0]     e_a;
        assign e_a     = e_addr[p];
        assign a_rd[p] = e_a[11:3];
        assign e_live  = e_v && !drop(e_try, e_bm);
        if (p == 0) begin : g_e0
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) e_v <= 1'b0;
                else        e_v <= (rr_valid[0] && !drop(1'b0, rr_bm[0])) || rt_v;
            end
            always_ff @(posedge clk) begin
                e_try  <= !rr_valid[0];
                e_ld   <= rr_valid[0] ? rr_ld : !r_id[LW];
                e_id   <= rr_valid[0] ? (rr_ld ? {1'b0, rr_lq[0]} : {1'b1, rr_sq}) : r_id;
                e_lq   <= rr_valid[0] ? rr_lq[0] : r_id[LW-1:0];
                e_sq   <= rr_valid[0] ? rr_sq : r_id[SW-1:0];
                e_st   <= rr_valid[0] ? rr_st[0] : r_st;
                e_size <= rr_valid[0] ? rr_size[0] : r_size;
                e_uns  <= rr_valid[0] ? rr_uns[0] : r_uns;
                e_dst  <= rr_valid[0] ? rr_dst[0] : r_dst;
                e_rob  <= rr_valid[0] ? rr_rob[0] : r_rob;
                e_bm   <= rr_valid[0] ? rr_bm[0] : '0;
            end
        end else begin : g_e1
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) e_v <= 1'b0;
                else        e_v <= rr_valid[1] && !drop(1'b0, rr_bm[1]);
            end
            assign e_try = 1'b0;
            assign e_ld  = 1'b1;
            assign e_sq  = '0;
            always_ff @(posedge clk) begin
                e_id   <= {1'b0, rr_lq[1]};
                e_lq   <= rr_lq[1];
                e_st   <= rr_st[1];
                e_size <= rr_size[1];
                e_uns  <= rr_uns[1];
                e_dst  <= rr_dst[1];
                e_rob  <= rr_rob[1];
                e_bm   <= rr_bm[1];
            end
        end

        // ---- M: from E's registers
        logic            m_v, m_ld, m_try, m_uns, m_live;
        logic [LW-1:0]   m_lq;
        /* verilator lint_off UNUSEDSIGNAL */      // (a store's, port 0 only)
        logic [SW-1:0]   m_sq;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [SW:0]     m_st;
        logic [TAGW-1:0] m_dst;
        logic [ROBW-1:0] m_rob;
        logic [NCK-1:0]  m_bm;
        logic [1:0]      m_size;
        logic [IW-1:0]   m_id;
        logic [PAW-1:0]  m_a;                  // the address as far as it is used
        logic [63:VA-1]  m_hi;                 // Sv39: all the same
        logic            m_mis;
        logic [8:0]      m_wa;                 // for the search
        logic [7:0]      m_lmask;
        logic [2:0]      m_off, m_spos;
        logic            m_s0, m_s01, m_s3, m_sen;
        logic [NSQ-1:0]  m_older, m_below;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) m_v <= 1'b0;
            else        m_v <= e_live;
        end
        always_ff @(posedge clk) begin
            m_ld    <= e_ld;
            m_try   <= e_try;
            m_uns   <= e_uns;
            m_lq    <= e_lq;
            m_sq    <= e_sq;
            m_st    <= e_st;
            m_dst   <= e_dst;
            m_rob   <= e_rob;
            m_bm    <= e_bm;
            m_size  <= e_size;
            m_id    <= e_id;
            m_a     <= e_a[PAW-1:0];
            m_hi    <= e_a[63:VA-1];
            m_mis   <= misal(e_size, e_a[2:0]);
            m_wa    <= e_a[11:3];
            m_lmask <= bmask(e_size, e_a[2:0]);
            m_off   <= e_a[2:0];
            case (e_size)
                2'd0:    m_spos <= e_a[2:0];
                2'd1:    m_spos <= e_a[2:0] | 3'd1;
                default: m_spos <= e_a[2:0] | 3'd3;
            endcase
            m_s0    <= e_size == 2'd0;
            m_s01   <= !e_size[1];
            m_s3    <= e_size == 2'd3;
            m_sen   <= !e_uns && e_size != 2'd3;
            m_older <= sring(sq_head, e_st);
            for (int i = 0; i < NSQ; i++) m_below[i] <= SW'(i) < e_st[SW-1:0];
        end
        assign m_live = m_v && !drop(m_try, m_bm);
        assign m_ids[p] = m_id;
        // the first M keeps what a try needs
        assign m_kpw[p] = m_v && !m_try;
        assign m_kp[p]  = {m_a, m_size, m_uns, m_dst, m_rob, m_st};

        // the DTLB
        logic            t_hit, t_r, t_w;
        logic [PAW-1:12] t_ptag;
        OOO_DTLB2 #(.SETS(32), .VA(VA), .PAW(PAW)) u_tlb
            (.clk(clk), .rst_n(rst_n), .tr_on(tr_on), .va(m_a[PAW-1:12]),
             .hit(t_hit), .ptag(t_ptag), .r_ok(t_r), .w_ok(t_w),
             .tlb_we(tlb_we), .tlb_vpn(tlb_vpn), .tlb_ptag(tlb_ptag), .tlb_r(tlb_r), .tlb_w(tlb_w),
             .tlb_flush(tlb_flush), .busy(t_busy[p]));

        // the search: the youngest older store with this offset, that has bytes of the
        // load: the first one going back from the load's place in the ring
        logic [NSQ-1:0] sm, smb;
        logic           f_any;
        logic [SW-1:0]  f_idx;
        always @(*) begin
            for (int i = 0; i < NSQ; i++)
                sm[i] = m_older[i] && swa[i] == m_wa && (smask[i] & m_lmask) != 8'd0;
            smb   = sm & m_below;
            f_any = sm != '0;
            f_idx = '0;
            if (smb != '0) begin
                for (int i = 0; i < NSQ; i++) if (smb[i]) f_idx = SW'(i);
            end else begin
                for (int i = 0; i < NSQ; i++) if (sm[i]) f_idx = SW'(i);
            end
        end

        // the result
        logic [3:0]  hit, sel;
        logic [63:0] m_f, m_w [4];
        logic        f_ok, m_hit;
        logic        m_bad, m_perm;
        logic        m_uc, m_ucd;           // for a device; the last try of one, with its word in uc_q
        logic [63:0] m_u;
        always @(*) begin
            for (int w = 0; w < 4; w++) begin
                m_w[w] = align(a_d[p][w], m_off, m_spos, m_s0, m_s01, m_s3, m_sen);
                hit[w] = a_t[p][w][TW] && a_t[p][w][TW-1:0] == t_ptag;
                sel[w] = hit[w] && !f_any;
            end
            m_f    = align(sd_f[f_idx], m_off, m_spos, m_s0, m_s01, m_s3, m_sen);
            m_hit  = hit != 4'd0;
            f_ok   = (sm_f[f_idx] & m_lmask) == m_lmask && sp[f_idx] && st_r[f_idx] == t_ptag;
            m_bad  = m_mis || (tr_on && !(&m_hi || !(|m_hi)));
            m_perm = m_ld ? t_r : t_w;
            m_uc   = uncached({t_ptag, m_a[11:0]});
            m_ucd  = p == 0 && m_ld && m_try && !m_id[LW] && lucd[m_id[LW-1:0]];
            m_u    = align(uc_q, m_off, m_spos, m_s0, m_s01, m_s3, m_sen);
        end
        assign ld_nv[p] = m_v && m_ld;
        assign ld_nt[p] = m_dst;
        assign ld_d[p]  = m_ucd ? m_u :
                          ({64{sel[0]}} & m_w[0]) | ({64{sel[1]}} & m_w[1]) | ({64{sel[2]}} & m_w[2]) |
                          ({64{sel[3]}} & m_w[3]) | ({64{f_any}} & m_f);

        // a store, port 0 alone
        if (p == 0) begin : g_st
            logic [63:0] m_sd, sd_rep;
            always_ff @(posedge clk) m_sd <= e_sd;
            always @(*) begin
                case (m_size)
                    2'd0:    sd_rep = {8{m_sd[7:0]}};
                    2'd1:    sd_rep = {4{m_sd[15:0]}};
                    2'd2:    sd_rep = {2{m_sd[31:0]}};
                    default: sd_rep = m_sd;
                endcase
            end
            always_ff @(posedge clk) begin
                if (m_v && !m_ld) begin
                    if (!m_try) sd_f[m_sq] <= sd_rep;
                    sm_f[m_sq] <= m_lmask;
                    st_r[m_sq] <= t_ptag;
                end
                for (int i = 0; i < NSQ; i++) begin
                    if (m_v && !m_ld && m_sq == SW'(i)) begin
                        swa[i]   <= m_wa;
                        smask[i] <= m_lmask;
                    end
                end
            end
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) sp <= '0;
                else begin
                    for (int i = 0; i < NSQ; i++) begin
                        if (!sv[i]) sp[i] <= 1'b0;
                        else if (m_v && !m_ld && m_sq == SW'(i)) sp[i] <= t_hit && t_w;
                    end
                end
            end
        end

        // ---- W
        logic            w_v, w_ld, w_try, w_ok, w_exc, w_miss, w_walk, w_live, w_uc;
        /* verilator lint_off UNUSEDSIGNAL */      // (port 0's: the device's address and size)
        logic [PAW-1:0]  w_a;
        logic [1:0]      w_size;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [ROBW-1:0] w_rob;
        logic [NCK-1:0]  w_bm;
        logic [LW-1:0]   w_lq;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) w_v <= 1'b0;
            else        w_v <= m_live;
        end
        always_ff @(posedge clk) begin
            w_ld   <= m_ld;
            w_try  <= m_try;
            w_rob  <= m_rob;
            w_bm   <= m_bm;
            w_lq   <= m_lq;
            w_exc  <= m_bad || (t_hit && !m_perm);
            w_walk <= !m_bad && !t_hit;
            // a store is done with its translation; a load for a device waits for its turn, then takes uc_q
            w_ok   <= m_ucd || (t_hit && m_perm && !m_bad && (!m_ld || (!m_uc && (f_any ? f_ok : m_hit))));
            w_miss <= m_ld && t_hit && m_perm && !m_bad && !f_any && !m_hit && !m_uc;
            w_uc   <= m_ld && t_hit && m_perm && !m_bad && m_uc && !m_ucd;
            w_a    <= {t_ptag, m_a[11:0]};
            w_size <= m_size;
        end
        assign w_live = w_v && !drop(w_try, w_bm);
        assign w_lives[p] = w_live && w_ld;
        assign w_oks[p]   = w_ok;
        assign w_excs[p]  = w_exc;
        assign w_lqs[p]   = w_lq;
        assign w_ucs[p]   = w_live && w_ld && w_uc;
        assign w_robs[p]  = w_rob;
        assign cmp_ld_valid[p] = w_live && w_ld && (w_ok || w_exc);
        assign cmp_ld_rob[p]   = w_rob;
        assign cmp_ld_exc[p]   = w_exc;
        assign cmp_ld_rp[p]    = w_try;
        if (p == 0) begin : g_w0
            assign cmp_st_valid = w_live && !w_ld && (w_ok || w_exc);
            assign cmp_st_rob   = w_rob;
            assign cmp_st_exc   = w_exc;
            assign w_try0       = w_v && w_try;
            assign m_st0        = m_v && !m_ld;
            logic [SW-1:0] w_sq;
            logic [IW-1:0] w_id;
            always_ff @(posedge clk) begin
                w_sq         <= m_sq;
                w_id         <= m_id;
                miss_line    <= {t_ptag, m_a[11:6]};
                tlb_miss_vpn <= m_a[VA-1:12];
            end
            assign miss_valid = w_live && w_miss;
            // a try of a load for a device whose turn it is: ask the device
            assign uc_ld_go   = w_live && w_ld && w_uc && w_try && ugo[w_lq];
            assign uc_ld_lq   = w_lq;
            assign uc_ld_a    = w_a;
            assign uc_ld_size = w_size;
            assign miss_id    = w_id;
            assign tlb_miss   = w_live && w_walk;
            assign walk_id    = w_id;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) swait <= '0;
                else begin
                    for (int i = 0; i < NSQ; i++) begin
                        if (!sv[i]) swait[i] <= 1'b0;
                        else if (w_live && !w_ld && w_sq == SW'(i)) swait[i] <= !(w_ok || w_exc);
                    end
                end
            end
        end else begin : g_w1
            assign w_ask1 = w_live && (w_miss || w_walk);
        end
    end

    assign tlb_busy   = t_busy != 2'd0;
    assign w_done_try = w_try0;

    // the first M keeps what a try needs
    always_ff @(posedge clk) begin
        if (m_kpw[0]) kp0[m_ids[0]] <= m_kp[0];
        if (m_kpw[1]) kp1[m_ids[1][LW-1:0]] <= m_kp[1];
        for (int e = 0; e < NLQ; e++) begin
            if (m_kpw[1] && m_ids[1][LW-1:0] == LW'(e)) lkp1[e] <= 1'b1;
            else if (m_kpw[0] && m_ids[0] == IW'(e))    lkp1[e] <= 1'b0;
        end
    end

    // ---- what may let a waiting µop go. A try that a recovery dropped goes again
    logic ev;
    assign ev = m_st0 || w_ask1 || d3_v || fill_done || tlb_done || rec || uc_done;
    logic launch_l, launch_s;
    assign launch_l = rt_v && !r_id[LW];
    assign launch_s = rt_v &&  r_id[LW];

    logic [NLQ-1:0] lv_n;
    logic [NSQ-1:0] sv_n;
    assign lv_n = lring(lq_head_n, lq_tail_n);
    assign sv_n = sring(sq_head_n, sq_tail_n);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lv <= '0; lwait <= '0; lretry <= '0; luc <= '0; lucd <= '0;
            sv <= '0; sretry <= '0;
        end else begin
            lv <= lv_n;
            sv <= sv_n;
            for (int e = 0; e < NLQ; e++) begin
                if (!lv[e]) begin
                    lwait[e]  <= 1'b0;
                    lretry[e] <= 1'b0;
                    luc[e]    <= 1'b0;
                    lucd[e]   <= 1'b0;
                end else begin
                    for (int p = 0; p < 2; p++)
                        if (w_ucs[p] && w_lqs[p] == LW'(e)) luc[e] <= 1'b1;
                    if (uc_done && uc_is_ld && uc_lq == LW'(e) && luc[e]) lucd[e] <= 1'b1;
                    for (int p = 0; p < 2; p++)
                        if (w_lives[p] && w_lqs[p] == LW'(e)) lwait[e] <= !(w_oks[p] || w_excs[p]);
                    if (ev) lretry[e] <= 1'b1;
                    else if (launch_l && r_id[LW-1:0] == LW'(e)) lretry[e] <= 1'b0;
                end
            end
            for (int i = 0; i < NSQ; i++) begin
                if (!sv[i]) sretry[i] <= 1'b0;
                else if (ev) sretry[i] <= 1'b1;
                else if (launch_s && r_id[SW-1:0] == SW'(i)) sretry[i] <= 1'b0;
            end
        end
    end

    // ---- what is not cacheable: the access to a device, one at a time (a load's from port 0's W, a store's
    // from the drain; never both, as a load goes only with the SQ drained)
    logic           uc_is_ld, st_uc_go;
    logic [LW-1:0]  uc_lq;
    logic [PAW-1:0] st_uc_a;
    logic [63:0]    st_uc_d;
    logic [7:0]     st_uc_m;
    always_ff @(posedge clk) begin
        for (int p = 0; p < 2; p++)
            if (w_ucs[p]) lrob[w_lqs[p]] <= w_robs[p];
        if (uc_ld_go) uc_lq <= uc_ld_lq;
        if (uc_req) uc_is_ld <= !uc_we;
        if (uc_done) uc_q <= uc_rdata;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)       uc_busy <= 1'b0;
        else if (uc_req)  uc_busy <= 1'b1;
        else if (uc_done) uc_busy <= 1'b0;
    end
    always @(*) begin
        uc_req   = st_uc_go || uc_ld_go;
        uc_we    = st_uc_go;
        uc_addr  = st_uc_go ? st_uc_a : uc_ld_a;
        uc_size  = st_uc_go ? (st_uc_m == 8'hff ? 2'd3 : (st_uc_m & 8'h0f) == 8'h0f || (st_uc_m & 8'hf0) == 8'hf0 ? 2'd2 :
                              (st_uc_m & 8'h55) == 8'd0 || (st_uc_m & 8'haa) == 8'd0 ? 2'd0 : 2'd1) : uc_ld_size;
        uc_wdata = st_uc_d;
        uc_wmask = st_uc_m;
    end

    // ---- the drain
    sptr_t         dp;                         // the next store to start
    logic          d_wait;                     // after a miss, for a fill
    logic          d0_v, d1_v, d2_v, d_back;
    logic          d1_st, d2_st;               // a tag was written since its lookup began
    sptr_t         d1_p, d2_p;
    logic [8:0]    d1_a, d2_a;
    logic [7:0]    d1_m, d2_m;
    logic [3:0]    d_hit;
    logic [1:0]    d2_way;
    logic          d2_hit, d2_uc;              // (a store for a device: to it, not to the D$)
    logic [63:0]   d2_d;
    logic [TW-1:0] d1_tag;
    logic [PAW-1:6] d2_line;
    assign d0_v   = dp != sq_cmt && !d_wait && !d_back;
    assign d0_set = swa[dp[SW-1:0]][8:3];
    always @(*) begin
        d1_tag = st_r[d1_p[SW-1:0]];
        for (int w = 0; w < 4; w++) d_hit[w] = s_t[w][TW] && s_t[w][TW-1:0] == d1_tag;
        // a fill's word first; a tag written since the lookup began sends the store back; a store for a
        // device goes to it when no access to a device is out, else it goes back
        st_uc_go = d2_v && d2_uc && !uc_busy;
        d_back  = d2_v && (d2_uc ? uc_busy : (!d2_hit || rf_en || tw_en || d2_st || !wt_ready));
        dw_en   = rf_en || (d2_v && !d2_uc && d2_hit && !tw_en && !d2_st && wt_ready);
        dw_way  = rf_en ? rf_way : d2_way;
        dw_addr = rf_en ? rf_addr : d2_a;
        dw_data = rf_en ? rf_data : d2_d;
        dw_strb = rf_en ? 8'hff : d2_m;
        st_miss_valid = d2_v && !d2_uc && !d2_hit && !tw_en && !d2_st;
        st_miss_line  = d2_line;
        dirty_set = d2_v && !d2_uc && d2_hit && !rf_en && !tw_en && !d2_st && wt_ready;
        wt_valid  = dirty_set;
        wt_addr   = {d2_line, d2_a[2:0], 3'b000};
        wt_data   = d2_d;
        wt_mask   = d2_m;
        st_uc_a   = {d2_line, d2_a[2:0], 3'b000};
        st_uc_d   = d2_d;
        st_uc_m   = d2_m;
        dirty_way = d2_way;
        dirty_idx = d2_a[8:3];
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dp <= '0; d_wait <= 1'b0; d1_v <= 1'b0; d2_v <= 1'b0; d3_v <= 1'b0;
        end else begin
            d3_v <= dirty_set || st_uc_go;
            if (d_back) begin
                dp   <= d2_p;
                d1_v <= 1'b0;
                d2_v <= 1'b0;
                if (st_miss_valid) d_wait <= 1'b1;
            end else begin
                if (d0_v) dp <= dp + 1'b1;
                d1_v <= d0_v;
                d2_v <= d1_v;
            end
            if (fill_done) d_wait <= 1'b0;
        end
    end
    always_ff @(posedge clk) begin
        d1_st   <= tw_en;
        d2_st   <= d1_st || tw_en;
        d1_p    <= dp;
        d1_a    <= swa[dp[SW-1:0]];
        d1_m    <= smask[dp[SW-1:0]];
        d2_p    <= d1_p;
        d2_a    <= d1_a;
        d2_m    <= d1_m;
        d2_hit  <= d_hit != 4'd0;
        d2_way  <= d_hit[3] ? 2'd3 : d_hit[2] ? 2'd2 : d_hit[1] ? 2'd1 : 2'd0;
        d2_d    <= sd_f[d1_p[SW-1:0]];
        d2_line <= {d1_tag, d1_a[8:3]};
        d2_uc   <= uncached({d1_tag, d1_a, 3'b000});
    end

endmodule : OOO_LSU3
