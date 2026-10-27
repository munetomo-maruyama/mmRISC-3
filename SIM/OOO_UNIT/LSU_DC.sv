//---------------------------------------------------------------------------
// LSU_DC.sv : the top of tb_dcad -- OOO_LSU, OOO_DCAD and mmRISC-2's DCACHE
// (RTL/CPU/CACHE) as they will sit in the core: the LSU's core side and the
// D$'s memory bus (AXI4) are the ports, and the store port between the LSU
// and the adapter is shown for the test bench (mon_st_*). Nothing goes
// below MEM_BASE in the test: the peripheral bus is tied off. tb_hold holds
// the fill handshake between the adapter and the LSU, as if the LSU's fill
// buffer were taken, so that the adapter keeps answers more often. The
// LSU's dc_kill is not used (OOO_DCAD drops old answers on a new request).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module LSU_DC
    #(
        parameter int NLQ  = 8,
        parameter int NSQ  = 8,
        parameter int PAW  = 40,
        parameter int TAGW = 6,
        parameter int ROBW = 5,
        parameter int NCK  = 6
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,
        // OOO_LSU's core side
        input  logic [1:0]                  disp_valid,
        input  logic [1:0]                  disp_ld,
        input  logic [1:0]                  disp_st,
        input  logic [1:0][ROBW-1:0]        disp_rob,
        output logic [1:0]                  lq_avail,
        output logic [1:0]                  sq_avail,
        output logic [1:0][$clog2(NLQ)-1:0] disp_lq,
        output logic [1:0][$clog2(NSQ)-1:0] disp_sq,
        output logic [1:0][$clog2(NLQ):0]   ck_lq_tail,
        output logic [1:0][$clog2(NSQ):0]   ck_sq_tail,
        input  logic                        iss_valid,
        input  logic                        iss_ld,
        input  logic [$clog2(NLQ)-1:0]      iss_lq,
        input  logic [$clog2(NSQ)-1:0]      iss_sq,
        input  logic [63:0]                 iss_base,
        input  logic [11:0]                 iss_imm,
        input  logic [63:0]                 iss_data,
        input  logic [1:0]                  iss_size,
        input  logic                        iss_uns,
        input  logic [TAGW-1:0]             iss_dst,
        input  logic [NCK-1:0]              iss_bm,
        output logic [NLQ-1:0]              lsu_st_known,
        output logic                        wb_valid,
        output logic                        wb_late,
        output logic [TAGW-1:0]             wb_tag,
        output logic [63:0]                 wb_data,
        output logic                        ld_cancel,
        output logic [TAGW-1:0]             ld_cancel_tag,
        output logic                        cmp_ld_valid,
        output logic [ROBW-1:0]             cmp_ld_rob,
        output logic                        cmp_ld_exc,
        output logic                        cmp_ld_rp,
        output logic                        cmp_st_valid,
        output logic [ROBW-1:0]             cmp_st_rob,
        output logic                        cmp_st_exc,
        input  logic [1:0]                  lq_commit,
        input  logic [1:0]                  sq_commit,
        input  logic                        restore,
        input  logic [NCK-1:0]              kill,
        input  logic [$clog2(NLQ):0]        restore_lq_tail,
        input  logic [$clog2(NSQ):0]        restore_sq_tail,
        input  logic                        flush_all,
        input  logic                        tb_hold,       // no fill to the LSU now
        // the store port between the LSU and the adapter (for the test bench)
        output logic                        mon_st,        // a store taken now
        output logic [PAW-1:0]              mon_st_addr,
        output logic [63:0]                 mon_st_data,
        output logic [7:0]                  mon_st_mask,
        output logic                        mon_hit,       // a load answered in M
        output logic                        mon_fill,      // a fill taken by the LSU
        output logic                        mon_req,       // a request to the D$ taken
        output logic                        mon_req_ld,
        // the D$'s memory bus
        output logic [3:0]                  m_axi4_awid,
        output logic [PAW-1:0]              m_axi4_awaddr,
        output logic [7:0]                  m_axi4_awlen,
        output logic [2:0]                  m_axi4_awsize,
        output logic [1:0]                  m_axi4_awburst,
        output logic                        m_axi4_awvalid,
        input  logic                        m_axi4_awready,
        output logic [63:0]                 m_axi4_wdata,
        output logic [7:0]                  m_axi4_wstrb,
        output logic                        m_axi4_wlast,
        output logic                        m_axi4_wvalid,
        input  logic                        m_axi4_wready,
        input  logic [1:0]                  m_axi4_bresp,
        input  logic                        m_axi4_bvalid,
        output logic                        m_axi4_bready,
        output logic [3:0]                  m_axi4_arid,
        output logic [PAW-1:0]              m_axi4_araddr,
        output logic [7:0]                  m_axi4_arlen,
        output logic [2:0]                  m_axi4_arsize,
        output logic [1:0]                  m_axi4_arburst,
        output logic                        m_axi4_arvalid,
        input  logic                        m_axi4_arready,
        input  logic [63:0]                 m_axi4_rdata,
        input  logic [1:0]                  m_axi4_rresp,
        input  logic                        m_axi4_rlast,
        input  logic                        m_axi4_rvalid,
        output logic                        m_axi4_rready
    );

    localparam int LW = $clog2(NLQ);

    logic             dc_req_valid, dc_hit, dc_fill_valid, dc_fill_ready, dc_st_valid, dc_st_ready;
    logic             l_fill_valid, l_fill_ready;     // the fill handshake as the LSU sees it
    logic [PAW-1:0]   dc_req_addr, dc_st_addr;
    logic [LW-1:0]    dc_req_tag, dc_fill_tag;
    logic [63:0]      dc_rdata, dc_fill_data, dc_st_data;
    logic [NLQ-1:0]   dc_kill;
    logic [7:0]       dc_st_mask;

    OOO_LSU #(.NLQ(NLQ), .NSQ(NSQ), .PAW(PAW), .TAGW(TAGW), .ROBW(ROBW), .NCK(NCK)) u_lsu
        (.clk, .rst_n,
         .disp_valid, .disp_ld, .disp_st, .disp_rob, .lq_avail, .sq_avail, .disp_lq, .disp_sq,
         .ck_lq_tail, .ck_sq_tail,
         .iss_valid, .iss_ld, .iss_lq, .iss_sq, .iss_base, .iss_imm, .iss_data, .iss_size, .iss_uns,
         .iss_dst, .iss_bm, .lsu_st_known,
         .dc_req_valid, .dc_req_addr, .dc_req_tag, .dc_hit, .dc_rdata,
         .dc_fill_valid(l_fill_valid), .dc_fill_tag, .dc_fill_data, .dc_fill_ready(l_fill_ready), .dc_kill,
         .dc_st_valid, .dc_st_addr, .dc_st_data, .dc_st_mask, .dc_st_ready,
         .wb_valid, .wb_late, .wb_tag, .wb_data, .ld_cancel, .ld_cancel_tag,
         .cmp_ld_valid, .cmp_ld_rob, .cmp_ld_exc, .cmp_ld_rp, .cmp_st_valid, .cmp_st_rob, .cmp_st_exc,
         .lq_commit, .sq_commit, .restore, .kill, .restore_lq_tail, .restore_sq_tail, .flush_all);

    logic             d_req_valid, d_req_ready, d_req_cancel, d_resp_valid, d_hit_now;
    logic [PAW-1:0]   d_req_addr, d_req_paddr;
    logic [1:0]       d_req_size;
    logic [4:0]       d_req_cmd;
    logic [63:0]      d_req_wdata, d_resp_data, d_hit_now_data;

    OOO_DCAD #(.NLQ(NLQ), .PAW(PAW), .DEPTH(8)) u_dcad
        (.clk, .rst_n,
         .dc_req_valid, .dc_req_addr, .dc_req_tag, .dc_hit, .dc_rdata,
         .dc_fill_valid, .dc_fill_tag, .dc_fill_data, .dc_fill_ready,
         .dc_st_valid, .dc_st_addr, .dc_st_data, .dc_st_mask, .dc_st_ready,
         .d_req_valid, .d_req_ready, .d_req_addr, .d_req_size, .d_req_cmd, .d_req_wdata,
         .d_req_paddr, .d_req_cancel, .d_resp_valid, .d_resp_data, .d_hit_now, .d_hit_now_data);

    /* verilator lint_off PINCONNECTEMPTY */
    DCACHE #(.PADDR_WIDTH(PAW), .ROB_DEPTH(8)) u_dc
        (.clk, .rst_n,
         .d_req_valid, .d_req_ready, .d_req_addr, .d_req_size, .d_req_cmd, .d_req_wdata,
         .d_req_paddr, .d_req_cancel, .d_resp_valid, .d_resp_drop(), .d_resp_data, .d_resp_error(),
         .d_hit_now, .d_hit_now_data,
         .m_axi4_awid, .m_axi4_awaddr, .m_axi4_awlen, .m_axi4_awsize, .m_axi4_awburst,
         .m_axi4_awvalid, .m_axi4_awready, .m_axi4_wdata, .m_axi4_wstrb, .m_axi4_wlast,
         .m_axi4_wvalid, .m_axi4_wready, .m_axi4_bresp, .m_axi4_bvalid, .m_axi4_bready,
         .m_axi4_arid, .m_axi4_araddr, .m_axi4_arlen, .m_axi4_arsize, .m_axi4_arburst,
         .m_axi4_arvalid, .m_axi4_arready, .m_axi4_rdata, .m_axi4_rresp, .m_axi4_rlast,
         .m_axi4_rvalid, .m_axi4_rready,
         .m_axil_awaddr(), .m_axil_awvalid(), .m_axil_awready(1'b0), .m_axil_wdata(), .m_axil_wstrb(),
         .m_axil_wvalid(), .m_axil_wready(1'b0), .m_axil_bresp(2'b00), .m_axil_bvalid(1'b0), .m_axil_bready(),
         .m_axil_araddr(), .m_axil_arvalid(), .m_axil_arready(1'b0), .m_axil_rdata(64'd0), .m_axil_rresp(2'b00),
         .m_axil_rvalid(1'b0), .m_axil_rready(),
         .ev_miss(), .ev_vic_copy());
    /* verilator lint_on PINCONNECTEMPTY */

    assign l_fill_valid  = dc_fill_valid && !tb_hold;
    assign dc_fill_ready = l_fill_ready && !tb_hold;
    assign mon_st      = dc_st_valid && dc_st_ready;
    assign mon_st_addr = dc_st_addr;
    assign mon_st_data = dc_st_data;
    assign mon_st_mask = dc_st_mask;
    assign mon_hit     = dc_hit;
    assign mon_fill    = dc_fill_valid && dc_fill_ready;
    assign mon_req     = d_req_valid && d_req_ready;
    assign mon_req_ld  = d_req_cmd == 5'd0;

endmodule
