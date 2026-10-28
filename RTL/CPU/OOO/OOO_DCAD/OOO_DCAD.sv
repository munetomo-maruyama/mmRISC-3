//---------------------------------------------------------------------------
// OOO_DCAD.sv
//
// The adapter between the D$ port of OOO_LSU (tagged requests, a hit one
// cycle after the request, fills by LQ entry, a store port) and the CPU
// port of mmRISC-2's DCACHE (RTL/CPU/CACHE/DCACHE: valid / ready requests,
// answers in request order, two cycles after the request at the earliest).
//
// Requests: one a cycle, in this order of priority:
//   1. the load in the LSU's E (dc_req_*): an 8-byte read at its word
//   2. a load the D$ could not take when it was in E (pending, below)
//   3. the store the LSU drains (dc_st_*: the byte mask becomes a size and
//      an offset, the data is shifted down); the LSU never drains one in a
//      cycle with a load in E, and stores wait while loads are pending
//   4. FLUSH for FENCE.I (OOO_SYS fl_req, Plan/OOC.md 22: the dirty lines
//      written back, as mmRISC-2 does before invalidating the I$): fl_take
//      when the D$ takes it, fl_done when its answer comes in order
// The physical address is the address of the cycle before (Phase 1 has no
// translation): d_req_paddr is registered when a request is taken.
//
// A load is answered in two ways:
//   - in M, the cycle after E: dc_hit and dc_rdata come from the D$'s
//     stage 1 (d_hit_now, a load hit, also under a miss) when the D$ took
//     the load in E. The answer the D$ gives again in request order is
//     dropped.
//   - otherwise later, as a fill: the D$'s in-order answer, kept by LQ entry
//     until the LSU takes it (one fill a cycle, dc_fill_ready).
// What the D$ answers in order is followed by a queue of the requests it
// took (DEPTH, the D$'s ROB_DEPTH: it takes no more than that): load or
// store, LQ entry, and whether the answer is still wanted.
//
// An answer is not wanted any more (dropped):
//   - the load hit in M (it has its data);
//   - the same LQ entry sent a newer request: a load that was not done in M
//     (an older store without its address, a partial overlap, a recovery)
//     is tried again by the LSU, and an older store may have reached the D$
//     in between. Its old answer comes first (in order) and does not have
//     that store; given to the entry, now waiting for its new request, it
//     would be a stale value. The answers kept for the entry go too.
// This also covers the LQ entries freed while their loads are in the D$
// (the LSU's dc_kill, not used here): a later owner of the entry sends a
// request before it waits for a fill, which drops the old answers, and
// until then the LSU takes no fill for it (bug injection showed dropping
// on dc_kill redundant, Plan/OOC.md 17.3).
// A load the D$ does not take in E (not ready) is kept by LQ entry (address
// in LUTRAM, a pending bit) and sent when nothing comes from E; for the LSU
// it is a miss like any other.
//
// Not done here (Plan/OOC.md 17.4): d_resp_error (a bus error on a load
// should be an access fault; below STORE_ACK_LIMIT memory never answers
// with one) and loads below MEM_BASE (the LSU reads 8-byte words before
// commit; a peripheral must be read at its size and not speculatively).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DCAD
    #(
        parameter int NLQ   = 8,
        parameter int PAW   = 40,
        parameter int DEPTH = 8         // the D$'s ROB_DEPTH
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // OOO_LSU
        input  logic                        dc_req_valid,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [PAW-1:0]              dc_req_addr,  // [2:0]: a load reads its 8-byte word
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [$clog2(NLQ)-1:0]      dc_req_tag,
        output logic                        dc_hit,
        output logic [63:0]                 dc_rdata,
        output logic                        dc_fill_valid,
        output logic [$clog2(NLQ)-1:0]      dc_fill_tag,
        output logic [63:0]                 dc_fill_data,
        input  logic                        dc_fill_ready,
        input  logic                        dc_st_valid,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [PAW-1:0]              dc_st_addr,   // 8-byte aligned
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [63:0]                 dc_st_data,
        input  logic [7:0]                  dc_st_mask,
        output logic                        dc_st_ready,

        // OOO_SYS: FENCE.I
        input  logic                        fl_req,
        output logic                        fl_take,
        output logic                        fl_done,

        // DCACHE
        output logic                        d_req_valid,
        input  logic                        d_req_ready,
        output logic [PAW-1:0]              d_req_addr,
        output logic [1:0]                  d_req_size,
        output logic [4:0]                  d_req_cmd,
        output logic [63:0]                 d_req_wdata,
        output logic [PAW-1:0]              d_req_paddr,
        output logic                        d_req_cancel,
        input  logic                        d_resp_valid,
        input  logic [63:0]                 d_resp_data,
        input  logic                        d_hit_now,
        input  logic [63:0]                 d_hit_now_data
    );

    localparam int LW = $clog2(NLQ);
    localparam int DW = $clog2(DEPTH);
    localparam logic [4:0] CMD_LOAD  = 5'd0;
    localparam logic [4:0] CMD_STORE = 5'd1;
    localparam logic [4:0] CMD_FLUSH = 5'd14;

    // ---- loads waiting to be sent, by LQ entry
    logic [NLQ-1:0] pnd;
    (* ram_style = "distributed" *) logic [PAW-4:0] pa [NLQ];
    // ---- answers waiting for the LSU, by LQ entry
    logic [NLQ-1:0] fr;
    (* ram_style = "distributed" *) logic [63:0] fd [NLQ];
    // ---- the requests the D$ has taken, in order
    logic [DEPTH-1:0] q_ld, q_live, q_fl;
    logic [LW-1:0]    q_tag [DEPTH];
    logic [DW-1:0]    q_head, q_tail;
    // ---- the request in the D$'s stage 1
    logic             s1_e;             // the LSU's load from E: the LSU is in M with it
    logic [DW-1:0]    s1_slot;
    logic [PAW-1:0]   s1_pa;

    function automatic logic [LW-1:0] lowest(input logic [NLQ-1:0] m);
        logic [LW-1:0] r;
        r = '0;
        for (int i = NLQ - 1; i >= 0; i--) if (m[i]) r = LW'(i);
        return r;
    endfunction

    // ---- the request of this cycle
    logic          e_go, p_go, s_go, f_go, take;
    logic [LW-1:0] p_sel;
    logic [2:0]    s_off;
    logic [1:0]    s_size;
    always @(*) begin
        p_sel = lowest(pnd);
        e_go  = dc_req_valid;
        p_go  = !dc_req_valid && pnd != '0;
        s_go  = !dc_req_valid && pnd == '0 && dc_st_valid;
        f_go  = !dc_req_valid && pnd == '0 && !dc_st_valid && fl_req;
        s_off = '0;
        for (int b = 7; b >= 0; b--) if (dc_st_mask[b]) s_off = 3'(b);
        case (dc_st_mask)
            8'hff:                      s_size = 2'd3;
            8'h0f, 8'hf0:               s_size = 2'd2;
            8'h03, 8'h0c, 8'h30, 8'hc0: s_size = 2'd1;
            default:                    s_size = 2'd0;
        endcase
        d_req_valid  = e_go || p_go || s_go || f_go;
        d_req_addr   = e_go ? {dc_req_addr[PAW-1:3], 3'b000}
                     : p_go ? {pa[p_sel], 3'b000}
                     :        {dc_st_addr[PAW-1:3], s_off};
        d_req_size   = s_go ? s_size : 2'd3;
        d_req_cmd    = s_go ? CMD_STORE : f_go ? CMD_FLUSH : CMD_LOAD;
        d_req_wdata  = dc_st_data >> {s_off, 3'b000};
        d_req_paddr  = s1_pa;
        d_req_cancel = 1'b0;
        dc_st_ready  = !dc_req_valid && pnd == '0 && d_req_ready;
        take         = d_req_valid && d_req_ready;
        fl_take      = f_go && d_req_ready;
        fl_done      = d_resp_valid && q_fl[q_head];
    end

    // ---- M: the hit of the LSU's load
    assign dc_hit   = s1_e && d_hit_now;
    assign dc_rdata = d_hit_now_data;

    // ---- which answers are still wanted after this cycle
    logic [DEPTH-1:0] q_keep;
    always @(*) begin
        for (int i = 0; i < DEPTH; i++)
            q_keep[i] = q_live[i] &&
                        !(e_go && q_tag[i] == dc_req_tag) &&
                        !(dc_hit && s1_slot == DW'(i));
    end

    // ---- answers to the LSU: a kept one first, else the D$'s of this cycle
    logic          a_want, f_kept, f_take;
    logic [LW-1:0] a_tag, f_sel;
    always @(*) begin
        a_tag  = q_tag[q_head];
        a_want = d_resp_valid && q_ld[q_head] && q_keep[q_head];
        f_sel  = lowest(fr);
        f_kept = fr != '0;
        dc_fill_valid = f_kept || a_want;
        dc_fill_tag   = f_kept ? f_sel : a_tag;
        dc_fill_data  = f_kept ? fd[f_sel] : d_resp_data;
        f_take        = dc_fill_valid && dc_fill_ready;
    end

    // the LUTRAMs: one write each
    always_ff @(posedge clk) begin
        if (e_go && !d_req_ready) pa[dc_req_tag] <= dc_req_addr[PAW-1:3];
        if (a_want && !(f_take && !f_kept)) fd[a_tag] <= d_resp_data;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pnd    <= '0;
            fr     <= '0;
            q_live <= '0;
            q_head <= '0;
            q_tail <= '0;
            s1_e   <= 1'b0;
        end else begin
            // pending loads: kept when the D$ does not take them in E,
            // dropped when sent or when the entry sends again
            for (int e = 0; e < NLQ; e++) begin
                if (e_go && dc_req_tag == LW'(e))                   pnd[e] <= !d_req_ready;
                else if (p_go && d_req_ready && p_sel == LW'(e))    pnd[e] <= 1'b0;
            end
            // answers kept for the LSU
            for (int e = 0; e < NLQ; e++) begin
                if (e_go && dc_req_tag == LW'(e))                  fr[e] <= 1'b0;
                else if (a_want && !(f_take && !f_kept) && a_tag == LW'(e)) fr[e] <= 1'b1;
                else if (f_take && f_kept && f_sel == LW'(e))      fr[e] <= 1'b0;
            end
            // the queue of what the D$ took
            q_live <= q_keep;
            if (d_resp_valid) q_head <= (q_head == DW'(DEPTH - 1)) ? '0 : q_head + 1'b1;
            if (take) begin
                q_tail          <= (q_tail == DW'(DEPTH - 1)) ? '0 : q_tail + 1'b1;
                q_ld[q_tail]    <= !s_go && !f_go;
                q_live[q_tail]  <= !s_go && !f_go;
                q_fl[q_tail]    <= f_go;
                q_tag[q_tail]   <= e_go ? dc_req_tag : p_sel;
            end
            s1_e <= take && e_go;
        end
    end

    always_ff @(posedge clk) begin
        if (take) begin
            s1_slot <= q_tail;
            s1_pa   <= d_req_addr;
        end
    end

endmodule
