//---------------------------------------------------------------------------
// OOO_LSU.sv
//
// The load / store unit of mmRISC-3 (Doc/UARCH.md 3.7): one load or store a
// cycle from issue port 2, a load queue and a store queue of NLQ / NSQ
// entries, forwarding from the store queue, stores written to the D$ after
// commit.
//
// Pipeline (the issue queue's IS and RR come before):
//   E  address = base + offset; a misaligned access is an exception; a
//      store writes its entry of the SQ (address, byte mask, data) and is
//      complete; a load sends its address to the D$
//   M  a load: the D$ answers (hit and data), the SQ is searched for the
//      youngest older store to the same 8-byte word, and the result is
//      chosen and aligned:
//        - the youngest older matching store covers the load: its data
//        - no older store matches, D$ hit: the D$ data
//        - D$ miss: the load waits for the fill (dc_fill_*)
//        - a matching store does not cover the load, or an older store has
//          no address yet: the load waits and is tried again from the LQ
//   WB the result register: the register-file write and the bypass, 2
//      cycles after issue as far as the dependents are concerned
// A load that cannot give its result in WB (miss, wait, exception) raises
// ld_cancel with its tag in M, so that the dependents woken for it can be
// held back (the replay policy of the core is outside this block). It
// gives its result later through the same write port, marked late (it
// needs a wakeup of its own then).
//
// Ordering: conservative. A load only takes data from the D$ when every
// older store has its address; the issue queue is expected to hold loads
// until then (lsu_st_known), and the LSU checks again in M.
//
// Queues: the LQ and the SQ are allocated in program order at dispatch (up
// to 2 a cycle) and freed in order: the LQ at commit, the SQ when a
// committed store has been written to the D$. What is in flight for an LQ
// entry never reaches a later owner of it, without an epoch (bug injection
// showed one redundant): a load in E moves to M in one cycle and not at all
// in a cycle of recovery; a freed entry is not given out again in the same
// cycle, so a fill kept in the LSU for it is dropped first (its entry is
// no longer live); fills still in the D$ are dropped by dc_kill. A store
// has nothing in flight: it writes its SQ entry in E.
// Recovery: restore sets the tails to the values of a checkpoint (taken
// from ck_*_tail at dispatch); flush_all goes back to the committed state
// (the LQ empty, the SQ down to its committed stores, which still drain).
//
// The D$ port is abstract: the adapter to mmRISC-2's D$ (tagged requests
// and fills, the write port) is outside, as is address translation (Phase
// 1 is M-mode, physical addresses: the address is used as it is). The
// adapter must drop the pending fill of every LQ entry in dc_kill (freed
// by a commit or a flush; the line itself is still filled): an entry can be
// given out again while its old miss is outstanding.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_LSU
    #(
        parameter int NLQ  = 12,
        parameter int NSQ  = 12,
        parameter int PAW  = 40,        // physical address bits (mmRISC-2's PADDR_WIDTH)
        parameter int TAGW = 6,         // physical register tags
        parameter int ROBW = 5          // ROB index (24 entries)
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // dispatch: up to 2 µops a cycle in program order, each a load, a
        // store or neither
        input  logic [1:0]                  disp_valid,
        input  logic [1:0]                  disp_ld,
        input  logic [1:0]                  disp_st,
        input  logic [1:0][ROBW-1:0]        disp_rob,
        output logic [1:0]                  lq_avail,   // free entries, 0 .. 2
        output logic [1:0]                  sq_avail,
        output logic [1:0][$clog2(NLQ)-1:0] disp_lq,    // the entries given
        output logic [1:0][$clog2(NSQ)-1:0] disp_sq,
        output logic [1:0][$clog2(NLQ):0]   ck_lq_tail, // the tails after slot 0 / 1, for checkpoints
        output logic [1:0][$clog2(NSQ):0]   ck_sq_tail,

        // issue port 2
        input  logic                        iss_valid,
        input  logic                        iss_ld,     // else a store
        input  logic [$clog2(NLQ)-1:0]      iss_lq,
        input  logic [$clog2(NSQ)-1:0]      iss_sq,
        input  logic [63:0]                 iss_base,
        input  logic [11:0]                 iss_imm,
        input  logic [63:0]                 iss_data,   // store data
        input  logic [1:0]                  iss_size,   // 0 byte .. 3 double
        input  logic                        iss_uns,    // load zero extended
        input  logic [TAGW-1:0]             iss_dst,
        output logic [NLQ-1:0]              lsu_st_known, // LQ entry: every older store has its address

        // D$ (abstract)
        output logic                        dc_req_valid,
        output logic [PAW-1:0]              dc_req_addr,
        output logic [$clog2(NLQ)-1:0]      dc_req_tag,   // the LQ entry
        input  logic                        dc_hit,       // in M
        input  logic [63:0]                 dc_rdata,     // the 8-byte word, in M
        input  logic                        dc_fill_valid,
        input  logic [$clog2(NLQ)-1:0]      dc_fill_tag,
        input  logic [63:0]                 dc_fill_data,
        output logic                        dc_fill_ready,
        output logic [NLQ-1:0]              dc_kill,      // LQ entries freed now: drop their pending fills
        output logic                        dc_st_valid,
        output logic [PAW-1:0]              dc_st_addr,   // 8-byte aligned
        output logic [63:0]                 dc_st_data,
        output logic [7:0]                  dc_st_mask,
        input  logic                        dc_st_ready,

        // results
        output logic                        wb_valid,     // register-file write
        output logic                        wb_late,      // not in its expected cycle: needs a wakeup
        output logic [TAGW-1:0]             wb_tag,
        output logic [63:0]                 wb_data,
        output logic                        ld_cancel,    // in M: the load issued 2 cycles before gives no result in WB
        output logic [TAGW-1:0]             ld_cancel_tag,
        output logic                        cmp_ld_valid, // ROB completion of a load (with the write, or an exception)
        output logic [ROBW-1:0]             cmp_ld_rob,
        output logic                        cmp_ld_exc,
        output logic                        cmp_st_valid, // ROB completion of a store (in E)
        output logic [ROBW-1:0]             cmp_st_rob,
        output logic                        cmp_st_exc,

        // commit and recovery
        input  logic [1:0]                  lq_commit,    // loads committed this cycle
        input  logic [1:0]                  sq_commit,    // stores committed this cycle
        input  logic                        restore,
        input  logic [$clog2(NLQ):0]        restore_lq_tail,
        input  logic [$clog2(NSQ):0]        restore_sq_tail,
        input  logic                        flush_all
    );

    localparam int LW = $clog2(NLQ);
    localparam int SW = $clog2(NSQ);
    localparam int WAW = PAW - 3;               // 8-byte word address

    typedef logic [LW:0] lptr_t;                // {wrap, index}
    typedef logic [SW:0] sptr_t;

    function automatic lptr_t lnext(input lptr_t p, input logic [1:0] n);
        lptr_t q;
        q = p;
        for (int k = 0; k < 2; k++)
            if (n > 2'(k)) q = (q[LW-1:0] == LW'(NLQ - 1)) ? {~q[LW], LW'(0)} : {q[LW], q[LW-1:0] + LW'(1)};
        return q;
    endfunction
    function automatic sptr_t snext(input sptr_t p, input logic [1:0] n);
        sptr_t q;
        q = p;
        for (int k = 0; k < 2; k++)
            if (n > 2'(k)) q = (q[SW-1:0] == SW'(NSQ - 1)) ? {~q[SW], SW'(0)} : {q[SW], q[SW-1:0] + SW'(1)};
        return q;
    endfunction
    // the number of entries from a to b (b at or after a, at most N)
    function automatic logic [LW:0] lcount(input lptr_t a, input lptr_t b);
        return (a[LW] == b[LW]) ? (LW + 1)'(b[LW-1:0] - a[LW-1:0])
                                : (LW + 1)'(NLQ) + (LW + 1)'(b[LW-1:0]) - (LW + 1)'(a[LW-1:0]);
    endfunction
    function automatic logic [SW:0] scount(input sptr_t a, input sptr_t b);
        return (a[SW] == b[SW]) ? (SW + 1)'(b[SW-1:0] - a[SW-1:0])
                                : (SW + 1)'(NSQ) + (SW + 1)'(b[SW-1:0]) - (SW + 1)'(a[SW-1:0]);
    endfunction
    // entry i's distance from the head h (0 .. N-1)
    function automatic logic [SW-1:0] sdist(input logic [SW-1:0] i, input logic [SW-1:0] h);
        return (i >= h) ? SW'(i - h) : SW'(i + SW'(NSQ) - h);
    endfunction
    function automatic logic [LW-1:0] ldist(input logic [LW-1:0] i, input logic [LW-1:0] h);
        return (i >= h) ? LW'(i - h) : LW'(i + LW'(NLQ) - h);
    endfunction
    function automatic logic [7:0] bmask(input logic [1:0] size, input logic [2:0] off);
        return 8'((9'd1 << (9'd1 << size)) - 9'd1) << off;
    endfunction

    // ---- queue state
    lptr_t lq_head, lq_tail;
    sptr_t sq_head, sq_cmt, sq_tail;           // sq_cmt: the first store not committed

    // LQ entries: kept in the per-entry blocks below, read through these
    localparam logic [1:0] L_IDLE = 2'd0, L_WAIT = 2'd1, L_MISS = 2'd2, L_DONE = 2'd3;
    logic [NLQ-1:0]       lv, lretry;
    logic [1:0]           lst  [NLQ];
    logic [ROBW-1:0]      lrob [NLQ];
    sptr_t                lbnd [NLQ];          // the SQ tail at the load's dispatch
    logic [PAW-1:0]       laddr[NLQ];
    logic [1:0]           lsize[NLQ];
    logic [NLQ-1:0]       luns;
    logic [TAGW-1:0]      ldst [NLQ];

    // SQ entries
    logic [NSQ-1:0]       sv, sknown;
    logic [ROBW-1:0]      srob [NSQ];
    logic [WAW-1:0]       swa  [NSQ];
    logic [7:0]           smask[NSQ];
    logic [63:0]          sdata[NSQ];

    // ---- dispatch
    logic [1:0] l_new, s_new;                  // slots that take an entry
    lptr_t      lt1;
    sptr_t      st1;
    logic [LW:0] l_used;
    logic [SW:0] s_used;
    always @(*) begin
        l_used = lcount(lq_head, lq_tail);
        s_used = scount(sq_head, sq_tail);
        lq_avail = (l_used <= (LW + 1)'(NLQ - 2)) ? 2'd2 : (l_used == (LW + 1)'(NLQ - 1)) ? 2'd1 : 2'd0;
        sq_avail = (s_used <= (SW + 1)'(NSQ - 2)) ? 2'd2 : (s_used == (SW + 1)'(NSQ - 1)) ? 2'd1 : 2'd0;
        for (int u = 0; u < 2; u++) begin
            l_new[u] = disp_valid[u] && disp_ld[u];
            s_new[u] = disp_valid[u] && disp_st[u];
        end
        lt1 = lnext(lq_tail, {1'b0, l_new[0]});
        st1 = snext(sq_tail, {1'b0, s_new[0]});
        disp_lq[0] = lq_tail[LW-1:0];
        disp_lq[1] = lt1[LW-1:0];
        disp_sq[0] = sq_tail[SW-1:0];
        disp_sq[1] = st1[SW-1:0];
        ck_lq_tail[0] = lt1;
        ck_lq_tail[1] = lnext(lt1, {1'b0, l_new[1]});
        ck_sq_tail[0] = st1;
        ck_sq_tail[1] = snext(st1, {1'b0, s_new[1]});
    end

    // ---- which older stores have addresses: per LQ entry
    logic [SW:0] s_head_known;                 // stores from the head with an address, in a row
    always @(*) begin
        logic stop;
        stop = 1'b0;
        s_head_known = '0;
        for (int k = 0; k < NSQ; k++) begin
            logic [SW:0]   ik;                 // one bit more: head + k reaches 2 NSQ - 2
            logic [SW-1:0] i;
            ik = (SW + 1)'(sq_head[SW-1:0]) + (SW + 1)'(k);
            i  = (ik >= (SW + 1)'(NSQ)) ? SW'(ik - (SW + 1)'(NSQ)) : SW'(ik);
            if (!stop && (SW + 1)'(k) < s_used && sknown[i]) s_head_known = s_head_known + (SW + 1)'(1);
            else stop = 1'b1;
        end
        for (int e = 0; e < NLQ; e++)
            lsu_st_known[e] = lv[e] && (scount(sq_head, lbnd[e]) > (SW + 1)'(NSQ) ||   // all older ones drained
                                        scount(sq_head, lbnd[e]) <= s_head_known);
    end

    // ---- E: a new µop from port 2, or a load tried again from the LQ
    logic          r_any;                      // an LQ entry to try again
    logic [LW-1:0] r_e;
    always @(*) begin
        logic [LW-1:0] best;
        r_any = 1'b0; r_e = '0; best = '1;
        for (int e = 0; e < NLQ; e++)
            if (lv[e] && lst[e] == L_WAIT && lretry[e] && ldist(LW'(e), lq_head[LW-1:0]) <= best) begin
                r_any = 1'b1; r_e = LW'(e); best = ldist(LW'(e), lq_head[LW-1:0]);
            end
    end

    logic          e_v, e_ld, e_retry, e_mis;
    logic [LW-1:0] e_lq;
    logic [PAW-1:0] e_addr;
    logic [1:0]    e_size;
    logic          e_uns;
    logic [TAGW-1:0] e_dst;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0]   e_sum;                      // above PAW: translation comes in Phase 2
    /* verilator lint_on UNUSEDSIGNAL */
    always @(*) begin
        e_retry = !iss_valid && r_any && !restore && !flush_all;
        e_v     = (iss_valid || e_retry) && !restore && !flush_all;
        e_ld    = iss_valid ? iss_ld : 1'b1;
        e_lq    = iss_valid ? iss_lq : r_e;
        e_sum   = iss_base + {{52{iss_imm[11]}}, iss_imm};
        e_addr  = iss_valid ? e_sum[PAW-1:0] : laddr[r_e];
        e_size  = iss_valid ? iss_size : lsize[r_e];
        e_uns   = iss_valid ? iss_uns  : luns[r_e];
        e_dst   = iss_valid ? iss_dst  : ldst[r_e];
        case (e_size)
            2'd1:    e_mis = e_addr[0];
            2'd2:    e_mis = e_addr[1:0] != 2'd0;
            2'd3:    e_mis = e_addr[2:0] != 3'd0;
            default: e_mis = 1'b0;
        endcase
        dc_req_valid = e_v && e_ld && !e_mis;
        dc_req_addr  = e_addr;
        dc_req_tag   = e_lq;
    end
    // a store in E: its entry and its completion
    logic          e_st_w;
    logic [7:0]    e_mask;
    logic [63:0]   e_wdata;
    always @(*) begin
        e_st_w  = iss_valid && !iss_ld && sv[iss_sq] && !restore && !flush_all;
        e_mask  = bmask(iss_size, e_sum[2:0]);
        e_wdata = iss_data << {e_sum[2:0], 3'b000};
        cmp_st_valid = e_st_w;
        cmp_st_rob   = srob[iss_sq];
        cmp_st_exc   = e_mis;
    end

    // ---- M: the registers between E and M
    logic          m_v, m_retry, m_mis;
    logic [LW-1:0] m_lq;
    logic [PAW-1:0] m_addr;
    logic [1:0]    m_size;
    logic          m_uns;
    logic [TAGW-1:0] m_dst;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) m_v <= 1'b0;
        else        m_v <= e_v && e_ld && !restore && !flush_all;
    end
    always_ff @(posedge clk) begin
        m_retry <= e_retry;
        m_mis   <= e_mis;
        m_lq    <= e_lq;
        m_addr  <= e_addr;
        m_size  <= e_size;
        m_uns   <= e_uns;
        m_dst   <= e_dst;
    end

    // ---- M: the search of the SQ
    logic          m_live;                     // the entry is still the one that was issued
    logic [7:0]    m_lmask;
    logic [NSQ-1:0] older, hit_st;
    logic          m_unknown;                  // an older store without an address
    logic          m_fwd_any, m_cover;
    logic [SW-1:0] m_fwd_e;
    logic [63:0]   m_word;                     // the 8-byte word the load reads
    always @(*) begin
        logic [SW:0]   nb;                     // older stores still in the SQ
        logic [SW-1:0] best;
        m_live  = m_v && lv[m_lq];
        m_lmask = bmask(m_size, m_addr[2:0]);
        nb = scount(sq_head, lbnd[m_lq]);
        if (nb > (SW + 1)'(NSQ)) nb = '0;     // the head has passed the boundary
        m_unknown = 1'b0;
        for (int i = 0; i < NSQ; i++) begin
            older[i]  = sv[i] && (SW + 1)'(sdist(SW'(i), sq_head[SW-1:0])) < nb;
            hit_st[i] = older[i] && sknown[i] && swa[i] == m_addr[PAW-1:3] && (smask[i] & m_lmask) != 8'd0;
            if (older[i] && !sknown[i]) m_unknown = 1'b1;
        end
        // the youngest older matching store: the one farthest from the head
        m_fwd_any = 1'b0; m_fwd_e = '0; best = '0;
        for (int i = 0; i < NSQ; i++)
            if (hit_st[i] && (!m_fwd_any || sdist(SW'(i), sq_head[SW-1:0]) >= best)) begin
                m_fwd_any = 1'b1; m_fwd_e = SW'(i); best = sdist(SW'(i), sq_head[SW-1:0]);
            end
        m_cover = (smask[m_fwd_e] & m_lmask) == m_lmask;
        m_word  = m_fwd_any ? sdata[m_fwd_e] : dc_rdata;
    end

    function automatic logic [63:0] align(input logic [63:0] w, input logic [2:0] off,
                                          input logic [1:0] size, input logic uns);
        logic [63:0] s;
        s = w >> {off, 3'b000};
        case (size)
            2'd0:    return uns ? {56'd0, s[7:0]}  : {{56{s[7]}},  s[7:0]};
            2'd1:    return uns ? {48'd0, s[15:0]} : {{48{s[15]}}, s[15:0]};
            2'd2:    return uns ? {32'd0, s[31:0]} : {{32{s[31]}}, s[31:0]};
            default: return s;
        endcase
    endfunction

    // the outcome of the load in M. In a cycle of recovery nothing
    // completes: a load whose entry stays waits and is tried again
    logic m_ok, m_to_miss, m_to_wait, m_exc, m_rec;
    always @(*) begin
        m_rec     = restore || flush_all;
        m_exc     = m_live && !m_rec && m_mis;
        m_to_wait = m_live && (m_rec || (!m_mis && (m_unknown || (m_fwd_any && !m_cover))));
        m_ok      = m_live && !m_rec && !m_mis && !m_unknown && (m_fwd_any ? m_cover : dc_hit);
        m_to_miss = m_live && !m_rec && !m_mis && !m_unknown && !m_fwd_any && !dc_hit;
        // the dependents of a load from port 2 were woken for WB
        ld_cancel     = m_v && !m_retry && !m_ok;
        ld_cancel_tag = m_dst;
    end

    // ---- fills of misses, one buffered when the write port is taken
    logic           fb_v;
    logic [LW-1:0]  fb_tag;
    logic [63:0]    fb_data;
    logic           f_v;                       // a fill to write back this cycle
    logic [LW-1:0]  f_e;
    logic [63:0]    f_word;
    logic           f_from_buf, f_live;
    always @(*) begin
        f_from_buf = fb_v;
        f_e    = f_from_buf ? fb_tag : dc_fill_tag;
        f_word = f_from_buf ? fb_data : dc_fill_data;
        f_live = lv[f_e] && lst[f_e] == L_MISS;
        // no completion in a cycle of recovery: an entry that stays keeps its
        // fill (in the buffer) and takes it afterwards
        f_v    = (fb_v || dc_fill_valid) && f_live && !m_ok && !m_exc && !restore && !flush_all;
        dc_fill_ready = !fb_v;
    end

    // ---- WB: one write a cycle, M first, then a fill
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_valid     <= 1'b0;
            cmp_ld_valid <= 1'b0;
            fb_v         <= 1'b0;
        end else begin
            wb_valid     <= (m_ok || f_v) && !restore && !flush_all;
            cmp_ld_valid <= (m_ok || m_exc || f_v) && !restore && !flush_all;
            // the buffer holds a fill until it is written back, or until its
            // entry is gone (flushed); an incoming fill (accepted only while
            // the buffer is empty) goes there when it cannot be written now
            if (fb_v) fb_v <= !(f_v || !f_live);
            else      fb_v <= dc_fill_valid && f_live && !f_v;
        end
    end
    always_ff @(posedge clk) begin
        if (m_ok || m_exc) begin
            wb_late    <= m_retry;
            wb_tag     <= m_dst;
            wb_data    <= align(m_word, m_addr[2:0], m_size, m_uns);
            cmp_ld_rob <= lrob[m_lq];
            cmp_ld_exc <= m_exc;
        end else begin
            wb_late    <= 1'b1;
            wb_tag     <= ldst[f_e];
            wb_data    <= align(f_word, laddr[f_e][2:0], lsize[f_e], luns[f_e]);
            cmp_ld_rob <= lrob[f_e];
            cmp_ld_exc <= 1'b0;
        end
        if (!fb_v && dc_fill_valid) begin
            fb_tag  <= dc_fill_tag;
            fb_data <= dc_fill_data;
        end
    end

    // ---- store drain: the oldest committed store with its address. Not
    // while a load is in E: that load reads the D$ now and searches the SQ
    // next cycle, so the store must still be in the SQ then
    logic s_drain;
    always @(*) begin
        dc_st_valid = sq_head != sq_cmt && sknown[sq_head[SW-1:0]] && !(e_v && e_ld);
        dc_st_addr  = {swa[sq_head[SW-1:0]], 3'b000};
        dc_st_data  = sdata[sq_head[SW-1:0]];
        dc_st_mask  = smask[sq_head[SW-1:0]];
        s_drain     = dc_st_valid && dc_st_ready;
    end

    // ---- pointers
    lptr_t lq_tail_n;
    sptr_t sq_tail_n, sq_head_n, sq_cmt_n;
    always @(*) begin
        lq_tail_n = lnext(lnext(lq_tail, {1'b0, l_new[0]}), {1'b0, l_new[1]});
        sq_tail_n = snext(snext(sq_tail, {1'b0, s_new[0]}), {1'b0, s_new[1]});
        sq_head_n = snext(sq_head, {1'b0, s_drain});
        sq_cmt_n  = snext(sq_cmt, sq_commit);
        if (flush_all) begin
            lq_tail_n = lnext(lq_head, lq_commit);
            sq_tail_n = sq_cmt_n;
        end else if (restore) begin
            lq_tail_n = restore_lq_tail;
            sq_tail_n = restore_sq_tail;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lq_head <= '0; lq_tail <= '0;
            sq_head <= '0; sq_cmt <= '0; sq_tail <= '0;
        end else begin
            lq_head <= lnext(lq_head, lq_commit);
            lq_tail <= lq_tail_n;
            sq_head <= sq_head_n;
            sq_cmt  <= sq_cmt_n;
            sq_tail <= sq_tail_n;
        end
    end

    // is position i (an index) inside [a, b) of a ring of n
    function automatic logic l_in(input lptr_t a, input lptr_t b, input logic [LW-1:0] i);
        return ldist(i, a[LW-1:0]) < LW'(lcount(a, b)) || lcount(a, b) == (LW + 1)'(NLQ);
    endfunction
    function automatic logic s_in(input sptr_t a, input sptr_t b, input logic [SW-1:0] i);
        return sdist(i, a[SW-1:0]) < SW'(scount(a, b)) || scount(a, b) == (SW + 1)'(NSQ);
    endfunction

    logic st_event;                            // a store got its address or left: waiting loads may try again
    assign st_event = e_st_w || s_drain;

    // ---- LQ entries
    for (genvar e = 0; e < NLQ; e++) begin : g_lq
        logic a0, a1, keep;
        assign a0   = l_new[0] && lq_tail[LW-1:0] == LW'(e);
        assign a1   = l_new[1] && lt1[LW-1:0] == LW'(e);
        assign keep = l_in(lnext(lq_head, lq_commit), lq_tail_n, LW'(e));
        assign dc_kill[e] = lv[e] && !keep;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                lv[e]  <= 1'b0;
            end else if ((a0 || a1) && !restore && !flush_all) begin
                lv[e]  <= 1'b1;
            end else begin
                lv[e]  <= lv[e] && keep;
            end
        end
        always_ff @(posedge clk) begin
            if ((a0 || a1) && !restore && !flush_all) begin
                lst[e]    <= L_IDLE;
                lrob[e]   <= a1 ? disp_rob[1] : disp_rob[0];
                lbnd[e]   <= a1 ? st1 : sq_tail;
                lretry[e] <= 1'b0;
            end else begin
                if (iss_valid && iss_ld && iss_lq == LW'(e) && !restore && !flush_all) begin
                    laddr[e] <= e_sum[PAW-1:0];
                    lsize[e] <= iss_size;
                    luns[e]  <= iss_uns;
                    ldst[e]  <= iss_dst;
                end
                if (m_live && m_lq == LW'(e)) begin
                    if (m_ok || m_exc)  lst[e] <= L_DONE;
                    else if (m_to_miss) lst[e] <= L_MISS;
                    else if (m_to_wait) lst[e] <= L_WAIT;
                end else if (f_v && f_e == LW'(e)) begin
                    lst[e] <= L_DONE;
                end
                if (m_live && m_lq == LW'(e) && m_rec)  lretry[e] <= 1'b1;   // put back by a recovery
                else if (e_retry && r_e == LW'(e))      lretry[e] <= 1'b0;
                else if (st_event)                      lretry[e] <= 1'b1;
            end
        end
    end

    // ---- SQ entries
    for (genvar i = 0; i < NSQ; i++) begin : g_sq
        logic a0, a1, keep;
        assign a0   = s_new[0] && sq_tail[SW-1:0] == SW'(i);
        assign a1   = s_new[1] && st1[SW-1:0] == SW'(i);
        assign keep = s_in(sq_head_n, sq_tail_n, SW'(i));
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                sv[i]  <= 1'b0;
            end else if ((a0 || a1) && !restore && !flush_all) begin
                sv[i]  <= 1'b1;
            end else begin
                sv[i]  <= sv[i] && keep;
            end
        end
        always_ff @(posedge clk) begin
            if ((a0 || a1) && !restore && !flush_all) begin
                sknown[i] <= 1'b0;
                srob[i]   <= a1 ? disp_rob[1] : disp_rob[0];
            end else if (e_st_w && iss_sq == SW'(i) && !e_mis) begin
                sknown[i] <= 1'b1;
                swa[i]    <= e_sum[PAW-1:3];
                smask[i]  <= e_mask;
                sdata[i]  <= e_wdata;
            end
        end
    end

endmodule : OOO_LSU
