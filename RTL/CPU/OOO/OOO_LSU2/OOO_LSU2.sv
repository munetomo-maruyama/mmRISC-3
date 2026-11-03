//---------------------------------------------------------------------------
// OOO_LSU2.sv
//
// The memory port of the 4-issue core at 100 MHz (Doc/STRATEGY.md 4.3, 4.5 loop
// 3, Plan/OOC.md 28.13): load-use 3 with a D$ in block RAM, a DTLB and an SQ of 16.
//
//   RR2  a µop from the memory queue, or one tried again (rt_*)
//   E    the address; the D$ arrays read its low bits at the end of the stage
//   M1   the arrays' data, aligned in each way; the tags into a register; the
//        DTLB; the SQ searched by the offset in the page; a store's offset written
//   M2   the tags compared, the result chosen; a store's physical tag written
//   M3   what came of it: complete, or wait, a miss, a walk
//
// What makes it fit:
//   - The alignment is in M1, in each way, before the way is known: a naturally
//     aligned access needs a mux of 8 for one byte and less for the others. So M2
//     has the compare and one AND-OR, with the SQ's word as a fifth way.
//   - The search compares the page's offset only, as M1 does not have the physical
//     address yet. M2 checks the rest for the one store chosen; a store with
//     another page behind that offset makes the load wait for it to leave.
//   - The SQ's data and physical tags are in distributed RAM, read by the entry
//     the search chose. A store's data is replicated to 64 bits when it comes, so
//     it is in the lane of whatever load reads it, and of the D$'s byte enables.
//   - Nothing waits for the hit: ld_nv and ld_nt come with any load in M2, and
//     the register is written whatever its value. The scheduler has no cancel
//     (OOO_SCHED): the dependents of a load are woken at its issue + 2, and what
//     they did is undone by replaying at the load's commit (cmp_ld_rp, as OOO_LSU).
//     A write of a load that failed goes to a register nobody may read yet, and
//     a killed one's cannot meet the register's next owner: that takes 5 cycles.
//
// The scheduler lets a load go only after every older store's issue (OOO_SCHED),
// so all the offsets it has to compare with are there in its M1.
//
// A µop that cannot finish goes to wait, and is tried again, at an event that may
// have changed things: a store translated, its data came, a store left, a fill, a
// walk done, a recovery. An event at any time since the try began counts. Tries are
// not a path of their own: through RR2 in a cycle without a µop, its address as
// the operand and offset 0, so there is no mux in E. What it needs was kept at its
// first M1 in one RAM (kp: one write, one read, loads and stores in one depth). A
// try has no branch mask: any recovery drops it, and the event tries it again.
// One at a time, in turn; but first the µop whose miss or walk has just ended
// (done_id), so that what it asked for is still there, and none can go on for ever
// losing its line or page to the others'. A miss has no data path: a try finds the
// line in the D$.
//
// The queues are allocated at dispatch by counts (renaming numbers its µops from
// the tails), and freed in order, the LQ at commit, the SQ after a store has been
// written. The stores that drain have their own copy of the tags and a pipeline of
// their own, so loads never wait for them, nor they for loads:
//   D0  the set, read in the tags' second copy
//   D1  the tags compared
//   D2  written, or a miss: back to D0 with this store after the fill
//   D3  it leaves at the end of this stage
// A load in E in D2's cycle reads the old word; it still finds the store in M1,
// as the store is there until the end of D3, and its mask of older stores was
// made with the head of its own E. A tag written meanwhile sends the store back.
//
// A store's data comes on sd_*: a µop of queue 2, whose value ends at the SQ
// (Plan/OOC.md 28.13). If a load finds its store without the data, it replays, and
// wt_* says so: the wait table makes that load wait for older stores' data next
// time.
//
// Not here yet: what is not cacheable, AMO, LR, SC (non-speculative, at the ROB's
// head: Plan/OOC.md 28.13). The miss handler is outside (the half-rate part,
// Doc/STRATEGY.md 4.4), by miss_*, st_miss_*, tw_*, rf_*, fill_done, and its
// victim's read would go through RR2 as a try does.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_LSU2
    #(
        parameter int NLQ  = 16,
        parameter int NSQ  = 16,
        parameter int PAW  = 40,
        parameter int VA   = 39,
        parameter int TAGW = 7,
        parameter int ROBW = 6,
        parameter int NCK  = 12
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

        // ---- RR2
        input  logic                     rr_valid,
        input  logic                     rr_ld,      // else a store's address
        input  logic [$clog2(NLQ)-1:0]   rr_lq,
        input  logic [$clog2(NSQ)-1:0]   rr_sq,
        input  logic [$clog2(NSQ):0]     rr_st,      // sq_tail at the load's dispatch: the stores older than it
        input  logic [11:0]              rr_imm,
        input  logic [1:0]               rr_size,
        input  logic                     rr_uns,
        input  logic [TAGW-1:0]          rr_dst,
        input  logic [ROBW-1:0]          rr_rob,
        input  logic [NCK-1:0]           rr_bm,
        output logic                     rt_v,       // a try goes in this RR2: the operand takes rt_base
        output logic [PAW-1:0]           rt_base,

        // ---- E: the operand after EX's mux (OOO_EXU a[NA])
        input  logic [63:0]              e_base,

        // ---- the result, in M2: into OOO_EXU's result registers
        output logic                     ld_nv,
        output logic [TAGW-1:0]          ld_nt,
        output logic [63:0]              ld_d,

        // ---- M3
        output logic                     cmp_ld_valid,
        output logic [ROBW-1:0]          cmp_ld_rob,
        output logic                     cmp_ld_exc,
        output logic                     cmp_ld_rp,  // it ran more than once: fetch again what follows it
        output logic                     cmp_sa_valid,  // a store's address
        output logic [ROBW-1:0]          cmp_sa_rob,
        output logic                     cmp_sa_exc,
        output logic                     wt_valid,   // a load found its store without the data
        output logic [ROBW-1:0]          wt_rob,

        // ---- a store's data
        input  logic                     sd_valid,
        input  logic [$clog2(NSQ)-1:0]   sd_sq,
        input  logic [1:0]               sd_size,
        input  logic [63:0]              sd_data,

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
        input  logic                     tlb_done,   // an answer: written, or nothing (a fault says r_ok, w_ok at 0)
        input  logic                     tlb_we,
        input  logic [VA-1:12]           tlb_vpn,
        input  logic [PAW-1:12]          tlb_ptag,
        input  logic                     tlb_r,
        input  logic                     tlb_w,
        input  logic                     tlb_flush,
        output logic                     tlb_busy
    );

    localparam int LW = $clog2(NLQ);
    localparam int SW = $clog2(NSQ);
    localparam int TW = PAW - 12;

    typedef logic [SW:0] sptr_t;
    typedef logic [LW:0] lptr_t;

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
    logic [NLQ-1:0] lv, lwait, lretry;
    logic [NSQ-1:0] sv, sdv, sp, swait, sretry;
    logic [8:0]     swa   [NSQ];         // the word's address in the page
    logic [7:0]     smask [NSQ];

    // what stays of the µop for a try: at its first M1
    localparam int KW = PAW + 2 + 1 + TAGW + ROBW + (SW + 1);
    (* ram_style = "distributed" *) logic [KW-1:0] kp [NLQ + NSQ];

    // ---- what can be tried, a cycle ahead; then read; then at the first free RR2
    logic [NLQ+NSQ-1:0]        cand;
    logic [$clog2(NLQ+NSQ)-1:0] r_next, r_q, r_id;
    logic                      r_any, r_qv, r_dv, r_busy, p_v;
    logic [$clog2(NLQ+NSQ)-1:0] p_id;
    logic [KW-1:0]             r_d;
    always @(*) begin
        cand   = {sv & swait & sretry, lv & lwait & lretry};
        r_any  = cand != '0;
        // in turn: the first after the last one tried; but first who has just been answered
        r_next = '0;
        for (int i = NLQ + NSQ - 1; i >= 0; i--) if (cand[i]) r_next = ($clog2(NLQ+NSQ))'(i);
        for (int i = NLQ + NSQ - 1; i >= 0; i--)
            if (cand[i] && ($clog2(NLQ+NSQ))'(i) > r_q) r_next = ($clog2(NLQ+NSQ))'(i);
        if (p_v && cand[p_id]) r_next = p_id;
    end

    logic          rec;       // a recovery: all tries go
    logic          m3_done_try;
    assign rec  = restore || flush_all;
    assign rt_v = r_dv && !rr_valid && !rec;
    logic [KW-1:0] rd_k;
    assign rd_k = kp[r_q];
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
                if (m3_done_try) r_busy <= 1'b0;
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

    // ---- E
    logic            e_v, e_ld, e_try, e_uns;
    logic [LW-1:0]   e_lq;
    logic [SW-1:0]   e_sq;
    logic [SW:0]     e_st;
    logic [11:0]     e_imm;
    logic [1:0]      e_size;
    logic [TAGW-1:0] e_dst;
    logic [ROBW-1:0] e_rob;
    logic [NCK-1:0]  e_bm;
    logic [$clog2(NLQ+NSQ)-1:0] e_id;
    logic [63:0]     e_sum;
    logic            e_live, m1_live, m2_live, m3_live;
    function automatic logic drop(input logic tr, input logic [NCK-1:0] bm);
        return flush_all || (tr ? restore : (bm & kill) != '0);
    endfunction
    assign e_live = e_v && !drop(e_try, e_bm);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) e_v <= 1'b0;
        else        e_v <= (rr_valid && !drop(1'b0, rr_bm)) || rt_v;
    end
    always_ff @(posedge clk) begin
        e_try  <= !rr_valid;
        e_ld   <= rr_valid ? rr_ld : !r_id[LW];
        e_id   <= rr_valid ? (rr_ld ? {1'b0, rr_lq} : {1'b1, rr_sq}) : r_id;
        e_lq   <= rr_valid ? rr_lq : r_id[LW-1:0];
        e_sq   <= rr_valid ? rr_sq : r_id[SW-1:0];
        e_st   <= rr_valid ? rr_st : r_st;
        e_imm  <= rr_valid ? rr_imm : 12'd0;
        e_size <= rr_valid ? rr_size : r_size;
        e_uns  <= rr_valid ? rr_uns : r_uns;
        e_dst  <= rr_valid ? rr_dst : r_dst;
        e_rob  <= rr_valid ? rr_rob : r_rob;
        e_bm   <= rr_valid ? rr_bm : '0;
    end
    assign e_sum = e_base + {{52{e_imm[11]}}, e_imm};

    // ---- the arrays
    logic [3:0][63:0] a_d;
    logic [3:0][TW:0] a_t, s_t;
    logic [5:0]       d0_set;
    logic             dw_en;
    logic [1:0]       dw_way;
    logic [8:0]       dw_addr;
    logic [63:0]      dw_data;
    logic [7:0]       dw_strb;
    OOO_DCH #(.SETS(64), .WAYS(4), .WORDS(8), .TW(TW)) u_dch
        (.clk(clk), .rd_addr(e_sum[11:3]), .rd_data(a_d), .rd_tag(a_t),
         .sb_set(d0_set), .sb_tag(s_t),
         .tw_en(tw_en), .tw_way(tw_way), .tw_set(tw_set), .tw_tag(tw_tag),
         .dw_en(dw_en), .dw_way(dw_way), .dw_addr(dw_addr), .dw_data(dw_data), .dw_strb(dw_strb));

    // ---- M1: from E's registers
    logic            m1_v, m1_ld, m1_try, m1_uns;
    logic [LW-1:0]   m1_lq;
    logic [SW-1:0]   m1_sq;
    logic [SW:0]     m1_st;
    logic [TAGW-1:0] m1_dst;
    logic [ROBW-1:0] m1_rob;
    logic [NCK-1:0]  m1_bm;
    logic [1:0]      m1_size;
    logic [$clog2(NLQ+NSQ)-1:0] m1_id;
    logic [PAW-1:0]  m1_a;                     // the address as far as it is used
    logic [63:VA-1]  m1_hi;                    // Sv39: all the same
    logic            m1_mis;
    (* max_fanout = 16 *) logic [8:0] m1_wa;   // for the search
    (* max_fanout = 16 *) logic [7:0] m1_lmask;
    (* max_fanout = 32 *) logic [2:0] m1_off, m1_spos;
    (* max_fanout = 32 *) logic       m1_s0, m1_s01, m1_s3, m1_sen;
    logic [NSQ-1:0]  m1_older, m1_below;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) m1_v <= 1'b0;
        else        m1_v <= e_live;
    end
    always_ff @(posedge clk) begin
        m1_ld    <= e_ld;
        m1_try   <= e_try;
        m1_uns   <= e_uns;
        m1_lq    <= e_lq;
        m1_sq    <= e_sq;
        m1_st    <= e_st;
        m1_dst   <= e_dst;
        m1_rob   <= e_rob;
        m1_bm    <= e_bm;
        m1_size  <= e_size;
        m1_id    <= e_id;
        m1_a     <= e_sum[PAW-1:0];
        m1_hi    <= e_sum[63:VA-1];
        m1_mis   <= misal(e_size, e_sum[2:0]);
        m1_wa    <= e_sum[11:3];
        m1_lmask <= bmask(e_size, e_sum[2:0]);
        m1_off   <= e_sum[2:0];
        case (e_size)
            2'd0:    m1_spos <= e_sum[2:0];
            2'd1:    m1_spos <= e_sum[2:0] | 3'd1;
            default: m1_spos <= e_sum[2:0] | 3'd3;
        endcase
        m1_s0    <= e_size == 2'd0;
        m1_s01   <= !e_size[1];
        m1_s3    <= e_size == 2'd3;
        m1_sen   <= !e_uns && e_size != 2'd3;
        m1_older <= sring(sq_head, e_st);
        for (int i = 0; i < NSQ; i++) m1_below[i] <= SW'(i) < e_st[SW-1:0];
    end
    assign m1_live = m1_v && !drop(m1_try, m1_bm);

    // the first M1 keeps what a try needs
    always_ff @(posedge clk) begin
        if (m1_v && !m1_try)
            kp[m1_id] <= {m1_a, m1_size, m1_uns, m1_dst, m1_rob, m1_st};
    end

    // the DTLB
    logic           t_hit, t_r, t_w;
    logic [PAW-1:12] t_ptag;
    OOO_DTLB2 #(.SETS(32), .VA(VA), .PAW(PAW)) u_tlb
        (.clk(clk), .rst_n(rst_n), .tr_on(tr_on), .va(m1_a[PAW-1:12]),
         .hit(t_hit), .ptag(t_ptag), .r_ok(t_r), .w_ok(t_w),
         .tlb_we(tlb_we), .tlb_vpn(tlb_vpn), .tlb_ptag(tlb_ptag), .tlb_r(tlb_r), .tlb_w(tlb_w),
         .tlb_flush(tlb_flush), .busy(tlb_busy));

    // the search: the youngest older store with this offset, that has bytes of the
    // load: the first one going back from the load's place in the ring
    logic [NSQ-1:0] m, mb;
    logic           f_any;
    logic [SW-1:0]  f_idx;
    always @(*) begin
        for (int i = 0; i < NSQ; i++)
            m[i] = m1_older[i] && swa[i] == m1_wa && (smask[i] & m1_lmask) != 8'd0;
        mb    = m & m1_below;
        f_any = m != '0;
        f_idx = '0;
        if (mb != '0) begin
            for (int i = 0; i < NSQ; i++) if (mb[i]) f_idx = SW'(i);
        end else begin
            for (int i = 0; i < NSQ; i++) if (m[i]) f_idx = SW'(i);
        end
    end

    // ---- M2
    logic            m2_v, m2_ld, m2_try;
    logic [TAGW-1:0] m2_dst;
    logic [ROBW-1:0] m2_rob;
    logic [NCK-1:0]  m2_bm;
    logic [LW-1:0]   m2_lq;
    logic [SW-1:0]   m2_sq;
    logic [VA-1:6]   m2_a;
    logic            m2_bad, m2_any, m2_thit, m2_perm;
    logic [SW-1:0]   m2_fi;
    logic [7:0]      m2_lmask;
    (* max_fanout = 32 *) logic [2:0] m2_off, m2_spos;
    (* max_fanout = 32 *) logic       m2_s0, m2_s01, m2_s3, m2_sen;
    (* keep = "true", max_fanout = 16 *) logic [TW-1:0] m2_pt;
    logic [TW:0]     m2_t [4];
    logic [63:0]     m2_w [4];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) m2_v <= 1'b0;
        else        m2_v <= m1_live;
    end
    always_ff @(posedge clk) begin
        m2_ld    <= m1_ld;
        m2_try   <= m1_try;
        m2_dst   <= m1_dst;
        m2_rob   <= m1_rob;
        m2_bm    <= m1_bm;
        m2_lq    <= m1_lq;
        m2_sq    <= m1_sq;
        m2_a     <= m1_a[VA-1:6];
        m2_bad   <= m1_mis || (tr_on && !(&m1_hi || !(|m1_hi)));
        m2_any   <= f_any;
        m2_thit  <= t_hit;
        m2_perm  <= m1_ld ? t_r : t_w;
        m2_pt    <= t_ptag;
        m2_fi    <= f_idx;
        m2_lmask <= m1_lmask;
        m2_off   <= m1_off;
        m2_spos  <= m1_spos;
        m2_s0    <= m1_s0;
        m2_s01   <= m1_s01;
        m2_s3    <= m1_s3;
        m2_sen   <= m1_sen;
        for (int w = 0; w < 4; w++) begin
            m2_t[w] <= a_t[w];
            m2_w[w] <= align(a_d[w], m1_off, m1_spos, m1_s0, m1_s01, m1_s3, m1_sen);
        end
    end
    assign m2_live = m2_v && !drop(m2_try, m2_bm);

    // the SQ's RAMs: the forward's read, the drain's read
    (* ram_style = "distributed" *) logic [63:0]   sd_f [NSQ];
    (* ram_style = "distributed" *) logic [63:0]   sd_d [NSQ];
    (* ram_style = "distributed" *) logic [TW-1:0] st_r [NSQ];   // read by the forward and the drain
    (* ram_style = "distributed" *) logic [7:0]    sm_f [NSQ];   // the mask, for the forward
    logic [63:0] sd_rep;
    always @(*) begin
        case (sd_size)
            2'd0:    sd_rep = {8{sd_data[7:0]}};
            2'd1:    sd_rep = {4{sd_data[15:0]}};
            2'd2:    sd_rep = {2{sd_data[31:0]}};
            default: sd_rep = sd_data;
        endcase
    end
    always_ff @(posedge clk) begin
        if (sd_valid) begin
            sd_f[sd_sq] <= sd_rep;
            sd_d[sd_sq] <= sd_rep;
        end
        if (m1_v && !m1_ld) sm_f[m1_sq] <= m1_lmask;
        if (m2_v && !m2_ld) st_r[m2_sq] <= m2_pt;
    end

    logic [3:0]  hit, sel;
    logic [63:0] m2_f;
    logic        f_ok, f_data, m2_hit;
    always @(*) begin
        for (int w = 0; w < 4; w++) begin
            hit[w] = m2_t[w][TW] && m2_t[w][TW-1:0] == m2_pt;
            sel[w] = hit[w] && !m2_any;
        end
        m2_f   = align(sd_f[m2_fi], m2_off, m2_spos, m2_s0, m2_s01, m2_s3, m2_sen);
        m2_hit = hit != 4'd0;
        f_data = sdv[m2_fi];
        f_ok   = (sm_f[m2_fi] & m2_lmask) == m2_lmask && sp[m2_fi] && st_r[m2_fi] == m2_pt;
    end
    assign ld_nv = m2_v && m2_ld;
    assign ld_nt = m2_dst;
    assign ld_d  = ({64{sel[0]}} & m2_w[0]) | ({64{sel[1]}} & m2_w[1]) | ({64{sel[2]}} & m2_w[2]) |
                   ({64{sel[3]}} & m2_w[3]) | ({64{m2_any}} & m2_f);

    // ---- M3
    logic            m3_v, m3_ld, m3_try, m3_ok, m3_exc, m3_miss, m3_walk, m3_late;
    logic [ROBW-1:0] m3_rob;
    logic [NCK-1:0]  m3_bm;
    logic [LW-1:0]   m3_lq;
    logic [SW-1:0]   m3_sq;
    logic [PAW-1:6]  m3_line;
    logic [VA-1:12]  m3_vpn;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) m3_v <= 1'b0;
        else        m3_v <= m2_live;
    end
    always_ff @(posedge clk) begin
        m3_ld   <= m2_ld;
        m3_try  <= m2_try;
        m3_rob  <= m2_rob;
        m3_bm   <= m2_bm;
        m3_lq   <= m2_lq;
        m3_sq   <= m2_sq;
        m3_line <= {m2_pt, m2_a[11:6]};
        m3_vpn  <= m2_a[VA-1:12];
        m3_exc  <= m2_bad || (m2_thit && !m2_perm);
        m3_walk <= !m2_bad && !m2_thit;
        m3_late <= m2_ld && m2_any && !f_data;
        // a store is done with its translation; its data comes apart
        m3_ok   <= m2_thit && m2_perm && !m2_bad &&
                   (!m2_ld || (m2_any ? f_ok && f_data : m2_hit));
        m3_miss <= m2_ld && m2_thit && m2_perm && !m2_bad && !m2_any && !m2_hit;
    end
    assign m3_live = m3_v && !drop(m3_try, m3_bm);
    assign m3_done_try = m3_v && m3_try;

    assign cmp_ld_valid = m3_live && m3_ld && (m3_ok || m3_exc);
    assign cmp_ld_rob   = m3_rob;
    assign cmp_ld_exc   = m3_exc;
    assign cmp_ld_rp    = m3_try;
    assign cmp_sa_valid = m3_live && !m3_ld && (m3_ok || m3_exc);
    assign cmp_sa_rob   = m3_rob;
    assign cmp_sa_exc   = m3_exc;
    assign wt_valid     = m3_live && m3_late;
    assign wt_rob       = m3_rob;
    assign miss_valid   = m3_live && m3_miss;
    assign miss_line    = m3_line;
    assign miss_id      = m3_ld ? {1'b0, m3_lq} : {1'b1, m3_sq};
    assign tlb_miss     = m3_live && m3_walk;
    assign tlb_miss_vpn = m3_vpn;

    // ---- what may let a waiting µop go. A try that a recovery dropped goes again
    logic ev;
    assign ev = (m2_v && !m2_ld) || sd_valid || d3_v || fill_done || tlb_done || rec;
    logic launch_l, launch_s;
    assign launch_l = rt_v && !r_id[LW];
    assign launch_s = rt_v &&  r_id[LW];

    logic [NLQ-1:0] lv_n;
    logic [NSQ-1:0] sv_n;
    assign lv_n = lring(lq_head_n, lq_tail_n);
    assign sv_n = sring(sq_head_n, sq_tail_n);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lv <= '0; lwait <= '0; lretry <= '0;
            sv <= '0; sdv <= '0; sp <= '0; swait <= '0; sretry <= '0;
        end else begin
            lv <= lv_n;
            sv <= sv_n;
            for (int e = 0; e < NLQ; e++) begin
                if (!lv[e]) begin
                    lwait[e]  <= 1'b0;
                    lretry[e] <= 1'b0;
                end else begin
                    if (m3_live && m3_ld && m3_lq == LW'(e)) lwait[e] <= !(m3_ok || m3_exc);
                    if (ev) lretry[e] <= 1'b1;
                    else if (launch_l && r_id[LW-1:0] == LW'(e)) lretry[e] <= 1'b0;
                end
            end
            for (int i = 0; i < NSQ; i++) begin
                if (!sv[i]) begin
                    sdv[i]    <= 1'b0;
                    sp[i]     <= 1'b0;
                    swait[i]  <= 1'b0;
                    sretry[i] <= 1'b0;
                end else begin
                    if (sd_valid && sd_sq == SW'(i)) sdv[i] <= 1'b1;
                    if (m2_v && !m2_ld && m2_sq == SW'(i)) sp[i] <= m2_thit && m2_perm;
                    if (m3_live && !m3_ld && m3_sq == SW'(i)) swait[i] <= !(m3_ok || m3_exc);
                    if (ev) sretry[i] <= 1'b1;
                    else if (launch_s && r_id[SW-1:0] == SW'(i)) sretry[i] <= 1'b0;
                end
            end
        end
    end
    always_ff @(posedge clk) begin
        for (int i = 0; i < NSQ; i++) begin
            if (m1_v && !m1_ld && m1_sq == SW'(i)) begin
                swa[i]   <= m1_wa;
                smask[i] <= m1_lmask;
            end
        end
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
    logic          d2_hit;
    logic [63:0]   d2_d;
    logic [TW-1:0] d1_tag;
    logic [PAW-1:6] d2_line;
    assign d0_v   = dp != sq_cmt && !d_wait && !d_back;
    assign d0_set = swa[dp[SW-1:0]][8:3];
    always @(*) begin
        d1_tag = st_r[d1_p[SW-1:0]];
        for (int w = 0; w < 4; w++) d_hit[w] = s_t[w][TW] && s_t[w][TW-1:0] == d1_tag;
        // a fill's word first; a tag written since the lookup began sends the store back
        d_back  = d2_v && (!d2_hit || rf_en || tw_en || d2_st);
        dw_en   = rf_en || (d2_v && d2_hit && !tw_en && !d2_st);
        dw_way  = rf_en ? rf_way : d2_way;
        dw_addr = rf_en ? rf_addr : d2_a;
        dw_data = rf_en ? rf_data : d2_d;
        dw_strb = rf_en ? 8'hff : d2_m;
        st_miss_valid = d2_v && !d2_hit && !tw_en && !d2_st;
        st_miss_line  = d2_line;
        dirty_set = d2_v && d2_hit && !rf_en && !tw_en && !d2_st;
        dirty_way = d2_way;
        dirty_idx = d2_a[8:3];
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dp <= '0; d_wait <= 1'b0; d1_v <= 1'b0; d2_v <= 1'b0; d3_v <= 1'b0;
        end else begin
            d3_v <= dirty_set;
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
        d2_d    <= sd_d[d1_p[SW-1:0]];
        d2_line <= {d1_tag, d1_a[8:3]};
    end

endmodule : OOO_LSU2
