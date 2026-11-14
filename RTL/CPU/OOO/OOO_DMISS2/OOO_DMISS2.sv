//---------------------------------------------------------------------------
// OOO_DMISS2.sv
//
// The D$'s miss handler, the D$ written back (step 1.7b W1, Plan/OOC.md 29.61):
// OOO_DMISS (29.34) with the write-through's queue replaced by dirty lines and
// their write out. Since step 1.7c C2 (Plan/OOC.md 29.68) the D$ has 256 sets of
// 4 ways (64 KB): the set is the virtual address's 13:6, so each line asked for
// comes with its vx (the virtual address's 13:12; the line itself is physical), and
// a physical line could sit in 4 sets (synonyms, once pages are translated). It is
// kept in one: see "a synonym" below. What OOO_LSU4 has outside it, on the D$'s memory bus (AXI4)
// and its peripheral bus (AXI4-Lite). One thing at a time but a line's write
// out, which goes on beside it:
//
//   a store    written into the D$ by the LSU, as before; here only its line
//              becomes dirty (dirty_set, dirty_way, dirty_idx): a bit a line,
//              in LUT RAM (a set and a clear never come in one cycle: no store is
//              written in a cycle with a tag written, nor during FENCE.I).
//   a line     asked for by a load (miss_*, with the asker's id) or by a store that
//              drains (st_miss_*); kept in a short queue, a line asked twice once. When
//              the write out before it has its answer, it is filled in the set of its
//              vx and its index (the physical 11:6): a way free in
//              the set, else one at random but the set's last written (dirty_set);
//              that way's tag invalid (no store writes it from then on: the LSU
//              sends back a store whose lookup saw a tag written); if it was dirty,
//              its 8 words are read (vr_*: a copy of the data of its own in OOO_DCH2,
//              answered a cycle later) into the evict buffer and written out as one
//              line write (8 beats, every byte); the burst of the new line, 8 beats,
//              each word into the arrays (rf_*); the tag valid; fill_done, with
//              done_v for a load's. A beat never overwrites a victim's word not yet
//              read: the words are read one a cycle from the first cycle of AR on,
//              and beat k comes at the earliest k + 1 cycles after AR is taken.
//              A line already there (asked again meanwhile) is answered at once. The
//              tags are kept here as they are written, in 4 banks by vx, so the 4 sets
//              a line could be in are read at once.
//   a synonym  the line asked for, valid in one of the 3 other sets of its index
//              (seen at once with its own set's tags): that way's tag invalid; if it
//              is dirty, it is written out, and the fill waits for B. Then the fill
//              as above. A line is never in two sets. A full queue drops the ask:
//              the asker asks again at the next event (a fill's end among them).
//   a write    only a line's write out, one at a time: AW, then the 8 beats as
//   out        their words are in the buffer, then B. A line written out is in no
//              way of the D$ until it is asked again, and that fill waits for B:
//              memory has the line before it is read back.
//   a device   what is not cacheable (uc_*, one at a time): one beat on AXI4-Lite
//              (a write out may go on beside it: a dirty line stays in the D$ anyway,
//              so waiting for it would order nothing).
//   FENCE.I    FLUSH (fl_*): the 1,024 lines walked, set by set, each dirty one
//              written out and clean (it stays in the D$); done when the last
//              write out has its answer. OOO_SYS asks only with the SQ drained, so
//              no store makes a line dirty meanwhile.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DMISS2
    #(
        parameter int PAW = 40,
        parameter int IW  = 5,          // the askers' ids (OOO_LSU4's LQ and SQ entries)
        parameter int NAQ = 4           // lines asked for
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        // ---- OOO_LSU4
        input  logic                  miss_valid,
        input  logic [PAW-1:6]        miss_line,    // physical
        input  logic [1:0]            miss_vx,      // the virtual address's 13:12: the set's top 2 bits
        input  logic [IW-1:0]         miss_id,
        input  logic                  st_miss_valid,
        input  logic [PAW-1:6]        st_miss_line,
        input  logic [1:0]            st_miss_vx,
        output logic                  fill_done,
        output logic                  done_v,
        output logic [IW-1:0]         done_id,
        output logic                  tw_en,
        output logic [1:0]            tw_way,
        output logic [7:0]            tw_set,
        output logic [PAW-12:0]       tw_tag,       // {valid, tag}
        output logic                  rf_en,
        output logic [1:0]            rf_way,
        output logic [10:0]           rf_addr,      // {set, word}
        output logic [63:0]           rf_data,
        input  logic                  dirty_set,    // a store written into the D$
        input  logic [1:0]            dirty_way,
        input  logic [7:0]            dirty_idx,
        output logic [10:0]           vr_addr,      // the victim's words: {set, word}
        output logic [1:0]            vr_way,
        input  logic [63:0]           vr_data,      // (a cycle after vr_addr)
        input  logic                  uc_req,
        input  logic                  uc_we,
        input  logic [PAW-1:0]        uc_addr,
        input  logic [63:0]           uc_wdata,
        input  logic [7:0]            uc_wmask,
        output logic                  uc_done,
        output logic [63:0]           uc_rdata,

        // ---- OOO_SYS: FENCE.I's FLUSH of the D$
        input  logic                  fl_req,
        output logic                  fl_take,
        output logic                  fl_done,

        // ---- the memory bus (AXI4)
        output logic [3:0]            m_axi4_awid,
        output logic [PAW-1:0]        m_axi4_awaddr,
        output logic [7:0]            m_axi4_awlen,
        output logic [2:0]            m_axi4_awsize,
        output logic [1:0]            m_axi4_awburst,
        output logic                  m_axi4_awvalid,
        input  logic                  m_axi4_awready,
        output logic [63:0]           m_axi4_wdata,
        output logic [7:0]            m_axi4_wstrb,
        output logic                  m_axi4_wlast,
        output logic                  m_axi4_wvalid,
        input  logic                  m_axi4_wready,
        /* verilator lint_off UNUSEDSIGNAL */      // (no error is told on: the memory answers OKAY)
        input  logic [1:0]            m_axi4_bresp,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic                  m_axi4_bvalid,
        output logic                  m_axi4_bready,
        output logic [3:0]            m_axi4_arid,
        output logic [PAW-1:0]        m_axi4_araddr,
        output logic [7:0]            m_axi4_arlen,
        output logic [2:0]            m_axi4_arsize,
        output logic [1:0]            m_axi4_arburst,
        output logic                  m_axi4_arvalid,
        input  logic                  m_axi4_arready,
        input  logic [63:0]           m_axi4_rdata,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [1:0]            m_axi4_rresp,
        input  logic                  m_axi4_rlast,  // (the 8th beat is counted)
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic                  m_axi4_rvalid,
        output logic                  m_axi4_rready,

        // ---- the peripheral bus (AXI4-Lite)
        output logic [PAW-1:0]        m_axil_awaddr,
        output logic                  m_axil_awvalid,
        input  logic                  m_axil_awready,
        output logic [63:0]           m_axil_wdata,
        output logic [7:0]            m_axil_wstrb,
        output logic                  m_axil_wvalid,
        input  logic                  m_axil_wready,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [1:0]            m_axil_bresp,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic                  m_axil_bvalid,
        output logic                  m_axil_bready,
        output logic [PAW-1:0]        m_axil_araddr,
        output logic                  m_axil_arvalid,
        input  logic                  m_axil_arready,
        input  logic [63:0]           m_axil_rdata,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [1:0]            m_axil_rresp,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic                  m_axil_rvalid,
        output logic                  m_axil_rready
    );

    localparam int TW = PAW - 12;       // a tag
    localparam int QW = $clog2(NAQ);

    typedef enum logic [3:0] { S_IDLE, S_LOOK, S_SINV, S_SYW, S_INV, S_AR, S_R, S_TAG, S_DONE, S_UAW, S_UW, S_UB, S_UAR, S_UR, S_FL, S_FLW } st_t;
    st_t            st;
    logic [9:0]     fi;                 // FENCE.I's walk: {set, way}

    // ---- the tags as written, a free way, the last written way of a set
    // (a RAM a way and a bank, one write, one read: LUT RAM, Plan/OOC.md 29.35). A bank holds the sets of one vx, all
    // read at the index in hand: the line's (its own set and its 3 synonyms' sets), or the walk's
    logic [TW:0]  tagb [4][4];          // [bank][way]
    logic [TW:0]  tagr [4];             // the bank in hand's (t_set)
    logic [1:0]   lastr;
    logic [15:0]  lfsr;
    logic [PAW-1:6] f_line;
    logic [1:0]   f_vx;
    logic [1:0]   y_vx, y_way;          // a synonym: its set's vx, its way
    logic [7:0]   t_set;                // the set in hand: the walk's, a synonym's, the line's
    assign t_set = st == S_FL ? fi[9:2] : {st == S_SINV ? y_vx : f_vx, f_line[11:6]};
    for (genvar b = 0; b < 4; b++) begin : g_bank
        for (genvar w = 0; w < 4; w++) begin : g_tag
            (* ram_style = "distributed" *) logic [TW:0] tagm [64];
            initial for (int s = 0; s < 64; s++) tagm[s] = '0;
            always_ff @(posedge clk) if (tw_en && int'(tw_way) == w && int'(tw_set[7:6]) == b) tagm[tw_set[5:0]] <= tw_tag;
            assign tagb[b][w] = tagm[t_set[5:0]];
        end
    end
    always @(*) for (int w = 0; w < 4; w++) tagr[w] = tagb[t_set[7:6]][w];
    (* ram_style = "distributed" *) logic [1:0] lastw [256];
    initial for (int s = 0; s < 256; s++) lastw[s] = '0;
    always_ff @(posedge clk) if (dirty_set) lastw[dirty_idx] <= dirty_way;
    assign lastr = lastw[{f_vx, f_line[11:6]}];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hace1;
        else        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    // ---- the lines asked for
    logic [PAW-1:6]  aq_line [NAQ];
    logic [1:0]      aq_vx   [NAQ];
    logic [IW:0]     aq_id   [NAQ];     // {a load's, its id}
    logic [QW:0]     aq_n;
    logic            aq_pop;
    function automatic logic asked(input logic [PAW-1:6] l, input logic [1:0] x, input logic [QW:0] n);
        logic a;
        a = 1'b0;
        for (int i = 0; i < NAQ; i++) if ((QW + 1)'(i) < n && aq_line[i] == l && aq_vx[i] == x) a = 1'b1;
        return a;
    endfunction
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) aq_n <= '0;
        else begin
            automatic logic [QW:0] n = aq_n;
            if (aq_pop) begin
                for (int i = 0; i < NAQ - 1; i++) begin
                    aq_line[i] <= aq_line[i+1];
                    aq_vx[i]   <= aq_vx[i+1];
                    aq_id[i]   <= aq_id[i+1];
                end
                n = n - 1'b1;
            end
            // (an ask lands after the pop: its place is counted from the queue as it will be)
            if (miss_valid && !asked(miss_line, miss_vx, aq_n) && n != (QW + 1)'(NAQ)) begin
                aq_line[n[QW-1:0]] <= miss_line;
                aq_vx[n[QW-1:0]]   <= miss_vx;
                aq_id[n[QW-1:0]]   <= {1'b1, miss_id};
                n = n + 1'b1;
            end
            if (st_miss_valid && !asked(st_miss_line, st_miss_vx, aq_n) &&
                !(miss_valid && miss_line == st_miss_line && miss_vx == st_miss_vx) && n != (QW + 1)'(NAQ)) begin
                aq_line[n[QW-1:0]] <= st_miss_line;
                aq_vx[n[QW-1:0]]   <= st_miss_vx;
                aq_id[n[QW-1:0]]   <= '0;
                n = n + 1'b1;
            end
            aq_n <= n;
        end
    end

    // ---- the dirty lines: a bit a line (a store sets; a line's write out clears: a fill's victim, a synonym, the walk's).
    // Never both in one cycle: no store is written in the cycle of a tag's write (S_INV, S_SINV), nor during the walk.
    // So one write port: a RAM a way (LUT RAM; at 256 sets, 1,024 flip-flops and their mux before)
    logic        ev_go;                 // a dirty line's write out begins: the victim's, a synonym's, or the walk's
    logic [1:0]  ev_way;
    logic        ev_dirty;              // the line in hand (ev_way of t_set) is dirty
    logic [3:0]  dtyr;                  // the ways' bits at t_set
    assign ev_way   = st == S_FL ? fi[1:0] : st == S_SINV ? y_way : f_way;
    assign ev_dirty = dtyr[ev_way];
    for (genvar w = 0; w < 4; w++) begin : g_dty
        (* ram_style = "distributed" *) logic dm [256];
        initial for (int s = 0; s < 256; s++) dm[s] = 1'b0;
        always_ff @(posedge clk)
            if (ev_go ? int'(ev_way) == w : dirty_set && int'(dirty_way) == w) dm[ev_go ? t_set : dirty_idx] <= !ev_go;
        assign dtyr[w] = dm[t_set];
    end

    // ---- a line's write out: its 8 words read from the D$'s copy into the buffer, AW at once, each beat when its word
    // is in, then B (an only id, one at a time)
    logic           e_on;               // from ev_go to B
    logic           e_aw;               // AW sent
    logic [3:0]     e_k;                // words read (asked)
    logic [3:0]     e_c;                // words in the buffer
    logic [3:0]     e_w;                // beats sent
    logic           e_rq;               // a word asked last cycle: in now
    logic [PAW-1:6] e_line;
    logic [7:0]     e_set;              // where it is in the D$ (its vx and its index)
    logic [1:0]     e_way;
    (* ram_style = "distributed" *) logic [63:0] eb [8];
    always_ff @(posedge clk) begin
        if (e_rq) eb[e_c[2:0]] <= vr_data;
        if (ev_go) begin
            e_line <= {tagr[ev_way][TW-1:0], t_set[5:0]};
            e_set  <= t_set;
            e_way  <= ev_way;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e_on <= 1'b0; e_aw <= 1'b0; e_k <= '0; e_c <= '0; e_w <= '0; e_rq <= 1'b0;
        end else begin
            e_rq <= e_on && !e_k[3];
            if (ev_go) begin
                e_on <= 1'b1; e_aw <= 1'b0; e_k <= '0; e_c <= '0; e_w <= '0;
            end else if (e_on) begin
                if (!e_k[3])                          e_k <= e_k + 1'b1;
                if (e_rq)                             e_c <= e_c + 1'b1;
                if (m_axi4_awvalid && m_axi4_awready) e_aw <= 1'b1;
                if (m_axi4_wvalid && m_axi4_wready)   e_w <= e_w + 1'b1;
                if (m_axi4_bvalid)                    e_on <= 1'b0;
            end
        end
    end
    assign vr_addr        = {e_set, e_k[2:0]};
    assign vr_way         = e_way;
    assign m_axi4_awid    = '0;
    assign m_axi4_awaddr  = {e_line, 6'd0};
    assign m_axi4_awlen   = 8'd7;
    assign m_axi4_awsize  = 3'd3;
    assign m_axi4_awburst = 2'b01;
    assign m_axi4_awvalid = e_on && !e_aw;
    assign m_axi4_wdata   = eb[e_w[2:0]];
    assign m_axi4_wstrb   = 8'hff;
    assign m_axi4_wlast   = e_w == 4'd7;
    assign m_axi4_wvalid  = e_on && e_aw && e_w < e_c;   // (each beat after the address and its word)
    assign m_axi4_bready  = 1'b1;
    logic wr_quiet;                     // no write out: memory has every line written out
    assign wr_quiet = !e_on;

    // ---- the one thing at a time: a line, a device, FENCE.I
    logic [IW:0]    f_id;
    logic [1:0]     f_way;
    logic [2:0]     f_beat;
    logic           u_pend, u_we;       // a device access asked for, not begun
    /* verilator lint_off UNUSEDSIGNAL */      // (the bus takes the 8-byte word's address, the strobes the bytes)
    logic [PAW-1:0] u_a;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0]    u_d;
    logic [7:0]     u_m;
    logic           f_have;
    logic [1:0]     f_free;
    logic           f_any;
    logic           y_any;              // the line in a synonym's set (one at most)
    logic [1:0]     y_b, y_w;
    always @(*) begin
        f_have = 1'b0; f_any = 1'b0; f_free = '0;
        for (int w = 3; w >= 0; w--) begin
            if (tagr[w][TW] && tagr[w][TW-1:0] == f_line[PAW-1:12]) f_have = 1'b1;
            if (!tagr[w][TW]) begin f_any = 1'b1; f_free = 2'(w); end
        end
        y_any = 1'b0; y_b = '0; y_w = '0;
        for (int b = 0; b < 4; b++)
            for (int w = 0; w < 4; w++)
                if (2'(b) != f_vx && tagb[b][w][TW] && tagb[b][w][TW-1:0] == f_line[PAW-1:12]) begin
                    y_any = 1'b1; y_b = 2'(b); y_w = 2'(w);
                end
    end
    assign aq_pop = st == S_IDLE && !u_pend && !fl_req && aq_n != '0 && wr_quiet;
    assign ev_go  = ((st == S_INV || st == S_SINV) && ev_dirty) || (st == S_FL && ev_dirty && !e_on);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; u_pend <= 1'b0; fi <= '0;
        end else begin
            if (uc_req) u_pend <= 1'b1;
            case (st)
                S_IDLE: if (u_pend)             begin u_pend <= 1'b0; st <= u_we ? S_UAW : S_UAR; end
                        else if (fl_req && !u_pend) begin fi <= '0; st <= S_FL; end   // (as fl_take)
                        else if (aq_pop)        st <= S_LOOK;
                S_LOOK: st <= f_have ? S_DONE : y_any ? S_SINV : S_INV;
                S_SINV: st <= S_SYW;                // the synonym's tag invalid, its write out begun if dirty
                S_SYW:  if (wr_quiet) st <= S_INV;  // memory has it before it is read back
                S_INV:  st <= S_AR;
                S_AR:   if (m_axi4_arready) st <= S_R;
                S_R:    if (m_axi4_rvalid && m_axi4_rready && f_beat == 3'd7) st <= S_TAG;
                S_TAG:  st <= S_DONE;
                S_DONE: st <= S_IDLE;
                S_UAW:  if (m_axil_awready) st <= S_UW;
                S_UW:   if (m_axil_wready) st <= S_UB;
                S_UB:   if (m_axil_bvalid) st <= S_IDLE;
                S_UAR:  if (m_axil_arready) st <= S_UR;
                S_UR:   if (m_axil_rvalid) st <= S_IDLE;
                // a dirty line waits for the write out before it; a clean one is passed
                S_FL:   if (!ev_dirty || !e_on) begin
                            fi <= fi + 1'b1;
                            if (fi == 10'h3ff) st <= S_FLW;
                        end
                S_FLW:  if (wr_quiet) st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
    end
    always_ff @(posedge clk) begin
        if (aq_pop) begin
            f_line <= aq_line[0];
            f_vx   <= aq_vx[0];
            f_id   <= aq_id[0];
        end
        if (st == S_LOOK) begin
            y_vx   <= y_b;
            y_way  <= y_w;
            f_way  <= f_any ? f_free : (lfsr[1:0] == lastr ? lfsr[1:0] + 2'd1 : lfsr[1:0]);
            f_beat <= '0;
        end
        if (m_axi4_rvalid && m_axi4_rready) f_beat <= f_beat + 3'd1;
        if (uc_req) begin
            u_we <= uc_we; u_a <= uc_addr; u_d <= uc_wdata; u_m <= uc_wmask;
        end
    end

    // the arrays: a synonym's tag invalid, the victim's tag invalid, the words, the tag valid
    always @(*) begin
        tw_en   = st == S_SINV || st == S_INV || st == S_TAG;
        tw_way  = st == S_SINV ? y_way : f_way;
        tw_set  = t_set;
        tw_tag  = st == S_TAG ? {1'b1, f_line[PAW-1:12]} : {1'b0, tagr[tw_way][TW-1:0]};
        rf_en   = m_axi4_rvalid && m_axi4_rready;
        rf_way  = f_way;
        rf_addr = {f_vx, f_line[11:6], f_beat};
        rf_data = m_axi4_rdata;
        fill_done = st == S_DONE;
        done_v    = st == S_DONE && f_id[IW];
        done_id   = f_id[IW-1:0];
    end
    assign m_axi4_arid    = '0;
    assign m_axi4_araddr  = {f_line, 6'd0};
    assign m_axi4_arlen   = 8'd7;
    assign m_axi4_arsize  = 3'd3;
    assign m_axi4_arburst = 2'b01;
    assign m_axi4_arvalid = st == S_AR;
    assign m_axi4_rready  = st == S_R;

    // the device
    assign m_axil_awaddr  = {u_a[PAW-1:3], 3'b000};
    assign m_axil_awvalid = st == S_UAW;
    assign m_axil_wdata   = u_d;
    assign m_axil_wstrb   = u_m;
    assign m_axil_wvalid  = st == S_UW;
    assign m_axil_bready  = st == S_UB;
    assign m_axil_araddr  = {u_a[PAW-1:3], 3'b000};
    assign m_axil_arvalid = st == S_UAR;
    assign m_axil_rready  = st == S_UR;
    assign uc_done  = (st == S_UB && m_axil_bvalid) || (st == S_UR && m_axil_rvalid);
    assign uc_rdata = m_axil_rdata;

    // FENCE.I: taken at once, done when the walk is over and the last write out has its answer
    assign fl_take = st == S_IDLE && !u_pend;
    assign fl_done = st == S_FLW && wr_quiet;

endmodule : OOO_DMISS2
