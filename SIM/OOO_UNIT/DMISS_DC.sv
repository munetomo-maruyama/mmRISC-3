//---------------------------------------------------------------------------
// DMISS_DC.sv : the top of tb_dmiss2 -- OOO_DMISS2 with the D$'s arrays
// (OOO_DCH2 with the victim's copy, VR=1) as OOO_LSU4 joins them (step 1.7b
// W1, Plan/OOC.md 29.61). The bench is the LSU: its loads read the two ports,
// its stores come as st_* and are written only when the LSU would write them
// (no fill's word, no tag written in the cycle: st_ok), which also sets the
// line dirty. The memory bus and the peripheral bus are the ports.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module DMISS_DC
    #(
        parameter int PAW = 40,
        parameter int TW  = PAW - 12
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        // the bench's loads: the arrays' two ports
        input  logic [1:0][8:0]       rd_addr,
        output logic [1:0][3:0][63:0] rd_data,
        // the bench's store into a way that holds its line
        input  logic                  st_en,
        input  logic [1:0]            st_way,
        input  logic [8:0]            st_addr,     // {set, word}
        input  logic [63:0]           st_data,
        input  logic [7:0]            st_strb,
        output logic                  st_ok,
        // OOO_DMISS2's LSU side
        input  logic                  miss_valid,
        input  logic [PAW-1:6]        miss_line,
        input  logic [4:0]            miss_id,
        input  logic                  st_miss_valid,
        input  logic [PAW-1:6]        st_miss_line,
        output logic                  fill_done,
        output logic                  done_v,
        output logic [4:0]            done_id,
        output logic                  tw_en,
        output logic [1:0]            tw_way,
        output logic [5:0]            tw_set,
        output logic [TW:0]           tw_tag,
        output logic                  rf_en,
        input  logic                  uc_req,
        input  logic                  uc_we,
        input  logic [PAW-1:0]        uc_addr,
        input  logic [63:0]           uc_wdata,
        input  logic [7:0]            uc_wmask,
        output logic                  uc_done,
        output logic [63:0]           uc_rdata,
        input  logic                  fl_req,
        output logic                  fl_take,
        output logic                  fl_done,

        // the memory bus (AXI4)
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
        input  logic [1:0]            m_axi4_bresp,
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
        input  logic [1:0]            m_axi4_rresp,
        input  logic                  m_axi4_rlast,
        input  logic                  m_axi4_rvalid,
        output logic                  m_axi4_rready,

        // the peripheral bus (AXI4-Lite)
        output logic [PAW-1:0]        m_axil_awaddr,
        output logic                  m_axil_awvalid,
        input  logic                  m_axil_awready,
        output logic [63:0]           m_axil_wdata,
        output logic [7:0]            m_axil_wstrb,
        output logic                  m_axil_wvalid,
        input  logic                  m_axil_wready,
        input  logic [1:0]            m_axil_bresp,
        input  logic                  m_axil_bvalid,
        output logic                  m_axil_bready,
        output logic [PAW-1:0]        m_axil_araddr,
        output logic                  m_axil_arvalid,
        input  logic                  m_axil_arready,
        input  logic [63:0]           m_axil_rdata,
        input  logic [1:0]            m_axil_rresp,
        input  logic                  m_axil_rvalid,
        output logic                  m_axil_rready
    );

    logic [1:0]  rf_way;
    logic [8:0]  rf_addr;
    logic [63:0] rf_data;
    logic [8:0]  vr_addr;
    logic [1:0]  vr_way;
    logic [63:0] vr_data;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0][3:0][TW:0] rd_tag;
    logic [3:0][TW:0]      sb_tag;
    /* verilator lint_on UNUSEDSIGNAL */

    // as OOO_LSU4: a fill's word first; a store not in a cycle with a tag written
    assign st_ok = st_en && !rf_en && !tw_en;

    OOO_DCH2 #(.SETS(64), .WAYS(4), .WORDS(8), .TW(TW), .VR(1'b1)) u_dch
        (.clk(clk), .rd_addr(rd_addr), .rd_data(rd_data), .rd_tag(rd_tag),
         .sb_set(6'd0), .sb_tag(sb_tag),
         .tw_en(tw_en), .tw_way(tw_way), .tw_set(tw_set), .tw_tag(tw_tag),
         .dw_en(rf_en || st_ok), .dw_way(rf_en ? rf_way : st_way), .dw_addr(rf_en ? rf_addr : st_addr),
         .dw_data(rf_en ? rf_data : st_data), .dw_strb(rf_en ? 8'hff : st_strb),
         .vr_addr(vr_addr), .vr_way(vr_way), .vr_data(vr_data));

    OOO_DMISS2 #(.PAW(PAW), .IW(5)) u_dmiss
        (.clk(clk), .rst_n(rst_n),
         .miss_valid(miss_valid), .miss_line(miss_line), .miss_id(miss_id),
         .st_miss_valid(st_miss_valid), .st_miss_line(st_miss_line),
         .fill_done(fill_done), .done_v(done_v), .done_id(done_id),
         .tw_en(tw_en), .tw_way(tw_way), .tw_set(tw_set), .tw_tag(tw_tag),
         .rf_en(rf_en), .rf_way(rf_way), .rf_addr(rf_addr), .rf_data(rf_data),
         .dirty_set(st_ok), .dirty_way(st_way), .dirty_idx(st_addr[8:3]),
         .vr_addr(vr_addr), .vr_way(vr_way), .vr_data(vr_data),
         .uc_req(uc_req), .uc_we(uc_we), .uc_addr(uc_addr), .uc_wdata(uc_wdata), .uc_wmask(uc_wmask),
         .uc_done(uc_done), .uc_rdata(uc_rdata),
         .fl_req(fl_req), .fl_take(fl_take), .fl_done(fl_done),
         .m_axi4_awid(m_axi4_awid), .m_axi4_awaddr(m_axi4_awaddr), .m_axi4_awlen(m_axi4_awlen),
         .m_axi4_awsize(m_axi4_awsize), .m_axi4_awburst(m_axi4_awburst), .m_axi4_awvalid(m_axi4_awvalid),
         .m_axi4_awready(m_axi4_awready), .m_axi4_wdata(m_axi4_wdata), .m_axi4_wstrb(m_axi4_wstrb),
         .m_axi4_wlast(m_axi4_wlast), .m_axi4_wvalid(m_axi4_wvalid), .m_axi4_wready(m_axi4_wready),
         .m_axi4_bresp(m_axi4_bresp), .m_axi4_bvalid(m_axi4_bvalid), .m_axi4_bready(m_axi4_bready),
         .m_axi4_arid(m_axi4_arid), .m_axi4_araddr(m_axi4_araddr), .m_axi4_arlen(m_axi4_arlen),
         .m_axi4_arsize(m_axi4_arsize), .m_axi4_arburst(m_axi4_arburst), .m_axi4_arvalid(m_axi4_arvalid),
         .m_axi4_arready(m_axi4_arready), .m_axi4_rdata(m_axi4_rdata), .m_axi4_rresp(m_axi4_rresp),
         .m_axi4_rlast(m_axi4_rlast), .m_axi4_rvalid(m_axi4_rvalid), .m_axi4_rready(m_axi4_rready),
         .m_axil_awaddr(m_axil_awaddr), .m_axil_awvalid(m_axil_awvalid), .m_axil_awready(m_axil_awready),
         .m_axil_wdata(m_axil_wdata), .m_axil_wstrb(m_axil_wstrb), .m_axil_wvalid(m_axil_wvalid),
         .m_axil_wready(m_axil_wready), .m_axil_bresp(m_axil_bresp), .m_axil_bvalid(m_axil_bvalid),
         .m_axil_bready(m_axil_bready), .m_axil_araddr(m_axil_araddr), .m_axil_arvalid(m_axil_arvalid),
         .m_axil_arready(m_axil_arready), .m_axil_rdata(m_axil_rdata), .m_axil_rresp(m_axil_rresp),
         .m_axil_rvalid(m_axil_rvalid), .m_axil_rready(m_axil_rready));

endmodule : DMISS_DC
