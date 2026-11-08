//---------------------------------------------------------------------------
// OOO_DMISS.sv
//
// The D$'s miss handler of the 4-wide core (step 1.3 E2, Plan/OOC.md 29.34): what
// OOO_LSU3 has outside it, on the D$'s memory bus (AXI4) and its peripheral bus
// (AXI4-Lite). One thing at a time but the writes, which go on beside it:
//
//   a line     asked for by a load (miss_*, with the asker's id) or by a store that
//              drains (st_miss_*); kept in a short queue, a line asked twice once. When
//              every write before it has its answer (memory has them), it is filled:
//              a way free in the set, else one at random but the set's last written
//              (dirty_set); that way's tag invalid; a burst of 8 beats; each word into
//              the arrays (rf_*); the tag valid; fill_done, with done_v for a load's.
//              A line already there (asked again meanwhile) is answered at once. The
//              tags are kept here as they are written. A full queue drops the ask:
//              the asker asks again at the next event (a fill's end among them).
//   a write    the D$ is written through: every store the D$ takes comes here (wt_*)
//              into a queue of NWQ; one beat each on AXI4, several out at once (the
//              address, the data and the answer go on apart); wt_ready while the
//              queue has room. So a line evicted has nothing to write back, and
//              FENCE.I's FLUSH (fl_*) waits only for the queue to empty.
//   a device   what is not cacheable (uc_*, one at a time): one beat on AXI4-Lite, when
//              the writes are out.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DMISS
    #(
        parameter int PAW = 40,
        parameter int IW  = 5,          // the askers' ids (OOO_LSU3's LQ and SQ entries)
        parameter int NAQ = 4,          // lines asked for
        parameter int NWQ = 8           // writes
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        // ---- OOO_LSU3
        input  logic                  miss_valid,
        input  logic [PAW-1:6]        miss_line,
        input  logic [IW-1:0]         miss_id,
        input  logic                  st_miss_valid,
        input  logic [PAW-1:6]        st_miss_line,
        output logic                  fill_done,
        output logic                  done_v,
        output logic [IW-1:0]         done_id,
        output logic                  tw_en,
        output logic [1:0]            tw_way,
        output logic [5:0]            tw_set,
        output logic [PAW-12:0]       tw_tag,       // {valid, tag}
        output logic                  rf_en,
        output logic [1:0]            rf_way,
        output logic [8:0]            rf_addr,
        output logic [63:0]           rf_data,
        input  logic                  dirty_set,
        input  logic [1:0]            dirty_way,
        input  logic [5:0]            dirty_idx,
        input  logic                  wt_valid,
        input  logic [PAW-1:0]        wt_addr,
        input  logic [63:0]           wt_data,
        input  logic [7:0]            wt_mask,
        output logic                  wt_ready,
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
    localparam int WW = $clog2(NWQ);

    // ---- the tags as written, a free way, the last written way of a set
    // (a RAM a way, one write, one read at the line's set: LUT RAM. As one array of 64 x 4 they were 7.4k flip-flops,
    // Plan/OOC.md 29.35)
    logic [TW:0]  tagr [4];             // the tags of f_line's set
    logic [1:0]   lastr;                // its last written way
    logic [15:0]  lfsr;
    logic [PAW-1:6] f_line;
    for (genvar w = 0; w < 4; w++) begin : g_tag
        (* ram_style = "distributed" *) logic [TW:0] tagm [64];
        initial for (int s = 0; s < 64; s++) tagm[s] = '0;
        always_ff @(posedge clk) if (tw_en && int'(tw_way) == w) tagm[tw_set] <= tw_tag;
        assign tagr[w] = tagm[f_line[11:6]];
    end
    (* ram_style = "distributed" *) logic [1:0] lastw [64];
    initial for (int s = 0; s < 64; s++) lastw[s] = '0;
    always_ff @(posedge clk) if (dirty_set) lastw[dirty_idx] <= dirty_way;
    assign lastr = lastw[f_line[11:6]];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hace1;
        else        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    // ---- the lines asked for
    logic [PAW-1:6]  aq_line [NAQ];
    logic [IW:0]     aq_id   [NAQ];     // {a load's, its id}
    logic [QW:0]     aq_n;
    logic            aq_pop;
    function automatic logic asked(input logic [PAW-1:6] l, input logic [QW:0] n);
        logic a;
        a = 1'b0;
        for (int i = 0; i < NAQ; i++) if ((QW + 1)'(i) < n && aq_line[i] == l) a = 1'b1;
        return a;
    endfunction
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) aq_n <= '0;
        else begin
            automatic logic [QW:0] n = aq_n;
            if (aq_pop) begin
                for (int i = 0; i < NAQ - 1; i++) begin
                    aq_line[i] <= aq_line[i+1];
                    aq_id[i]   <= aq_id[i+1];
                end
                n = n - 1'b1;
            end
            // (an ask lands after the pop: its place is counted from the queue as it will be)
            if (miss_valid && !asked(miss_line, aq_n) && n != (QW + 1)'(NAQ)) begin
                aq_line[n[QW-1:0]] <= miss_line;
                aq_id[n[QW-1:0]]   <= {1'b1, miss_id};
                n = n + 1'b1;
            end
            if (st_miss_valid && !asked(st_miss_line, aq_n) && !(miss_valid && miss_line == st_miss_line) &&
                n != (QW + 1)'(NAQ)) begin
                aq_line[n[QW-1:0]] <= st_miss_line;
                aq_id[n[QW-1:0]]   <= '0;
                n = n + 1'b1;
            end
            aq_n <= n;
        end
    end

    // ---- the writes: a queue, one beat each; the address, the data and the answers go on apart, so that several
    // writes are out at once (an entry leaves with its answer: the answers come in order, one id)
    logic [PAW-1:0] wq_a [NWQ];
    logic [63:0]    wq_d [NWQ];
    logic [7:0]     wq_m [NWQ];
    logic [WW:0]    wq_h, wq_t, aw_p, w_p;   // (a lap's bit above the index)
    logic [WW:0]    wq_n;
    assign wq_n     = wq_t - wq_h;
    assign wt_ready = wq_n != (WW + 1)'(NWQ);
    always_ff @(posedge clk) if (wt_valid && wt_ready) begin
        wq_a[wq_t[WW-1:0]] <= wt_addr;
        wq_d[wq_t[WW-1:0]] <= wt_data;
        wq_m[wq_t[WW-1:0]] <= wt_mask;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wq_h <= '0; wq_t <= '0; aw_p <= '0; w_p <= '0;
        end else begin
            if (wt_valid && wt_ready)            wq_t <= wq_t + 1'b1;
            if (m_axi4_awvalid && m_axi4_awready) aw_p <= aw_p + 1'b1;
            if (m_axi4_wvalid && m_axi4_wready)   w_p  <= w_p + 1'b1;
            if (m_axi4_bvalid)                    wq_h <= wq_h + 1'b1;
        end
    end
    assign m_axi4_awid    = '0;
    assign m_axi4_awaddr  = {wq_a[aw_p[WW-1:0]][PAW-1:3], 3'b000};
    assign m_axi4_awlen   = 8'd0;
    assign m_axi4_awsize  = 3'd3;
    assign m_axi4_awburst = 2'b01;
    assign m_axi4_awvalid = aw_p != wq_t;
    assign m_axi4_wdata   = wq_d[w_p[WW-1:0]];
    assign m_axi4_wstrb   = wq_m[w_p[WW-1:0]];
    assign m_axi4_wlast   = 1'b1;
    assign m_axi4_wvalid  = w_p != aw_p;          // (each beat after its address)
    assign m_axi4_bready  = 1'b1;
    logic wr_quiet;                         // every write has its answer: memory has them
    assign wr_quiet = wq_n == '0;

    // ---- the one thing at a time: a line, a device, FENCE.I
    typedef enum logic [3:0] { S_IDLE, S_LOOK, S_INV, S_AR, S_R, S_TAG, S_DONE, S_UAW, S_UW, S_UB, S_UAR, S_UR, S_FL } st_t;
    st_t            st;
    logic [IW:0]    f_id;
    logic [1:0]     f_way;
    logic [2:0]     f_beat;
    logic           u_pend, u_we;           // a device access asked for, not begun
    /* verilator lint_off UNUSEDSIGNAL */      // (the bus takes the 8-byte word's address, the strobes the bytes)
    logic [PAW-1:0] u_a;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0]    u_d;
    logic [7:0]     u_m;
    logic           f_have;
    logic [1:0]     f_free;
    logic           f_any;
    always @(*) begin
        f_have = 1'b0; f_any = 1'b0; f_free = '0;
        for (int w = 3; w >= 0; w--) begin
            if (tagr[w][TW] && tagr[w][TW-1:0] == f_line[PAW-1:12]) f_have = 1'b1;
            if (!tagr[w][TW]) begin f_any = 1'b1; f_free = 2'(w); end
        end
    end
    assign aq_pop = st == S_IDLE && !u_pend && !fl_req && aq_n != '0 && wr_quiet;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; u_pend <= 1'b0;
        end else begin
            if (uc_req) u_pend <= 1'b1;
            case (st)
                S_IDLE: if (u_pend && wr_quiet) begin u_pend <= 1'b0; st <= u_we ? S_UAW : S_UAR; end
                        else if (fl_req)        st <= S_FL;
                        else if (aq_pop)        st <= S_LOOK;
                S_LOOK: st <= f_have ? S_DONE : S_INV;
                S_INV:  st <= S_AR;
                S_AR:   if (m_axi4_arready) st <= S_R;
                S_R:    if (m_axi4_rvalid && f_beat == 3'd7) st <= S_TAG;
                S_TAG:  st <= S_DONE;
                S_DONE: st <= S_IDLE;
                S_UAW:  if (m_axil_awready) st <= S_UW;
                S_UW:   if (m_axil_wready) st <= S_UB;
                S_UB:   if (m_axil_bvalid) st <= S_IDLE;
                S_UAR:  if (m_axil_arready) st <= S_UR;
                S_UR:   if (m_axil_rvalid) st <= S_IDLE;
                S_FL:   if (wr_quiet) st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
    end
    always_ff @(posedge clk) begin
        if (aq_pop) begin
            f_line <= aq_line[0];
            f_id   <= aq_id[0];
        end
        if (st == S_LOOK) begin
            f_way  <= f_any ? f_free : (lfsr[1:0] == lastr ? lfsr[1:0] + 2'd1 : lfsr[1:0]);
            f_beat <= '0;
        end
        if (st == S_R && m_axi4_rvalid) f_beat <= f_beat + 3'd1;
        if (uc_req) begin
            u_we <= uc_we; u_a <= uc_addr; u_d <= uc_wdata; u_m <= uc_wmask;
        end
    end

    // the arrays: the victim's tag invalid, the words, the tag valid
    always @(*) begin
        tw_en   = st == S_INV || st == S_TAG;
        tw_way  = f_way;
        tw_set  = f_line[11:6];
        tw_tag  = st == S_TAG ? {1'b1, f_line[PAW-1:12]} : {1'b0, tagr[f_way][TW-1:0]};
        rf_en   = st == S_R && m_axi4_rvalid;
        rf_way  = f_way;
        rf_addr = {f_line[11:6], f_beat};
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

    // FENCE.I: taken at once, done when every write has its answer
    assign fl_take = st == S_IDLE && !u_pend;
    assign fl_done = st == S_FL && wr_quiet;

endmodule : OOO_DMISS
