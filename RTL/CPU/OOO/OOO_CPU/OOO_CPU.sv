//---------------------------------------------------------------------------
// OOO_CPU.sv
//
// The core with its caches (Plan/CORE.md 1, B3; step 1.3 E2, Plan/OOC.md 29.34; step
// 1.7 H3, Plan/OOC.md 29.58; step 1.7b W2, 29.62): OOO_CORE, whose OOO_LSU4 has the D$'s
// arrays (with the victim's copy); OOO_DMISS2, the D$'s miss handler; OOO_ICACHE, the I$
// on OOO_FETCH2's port (FENCE.I's invalidate from OOO_SYS); OOO_MARB, which puts the
// I$'s fills and OOO_DMISS2's fills and line writes on one AXI4; and CPU_L2 (mmRISC-2's,
// 256 KB, write back) behind it. The ports: the L2's memory bus (AXI4) and the D$'s
// peripheral bus (AXI4-Lite: what is not cacheable). The D$ is written back, into the
// L2; FENCE.I's FLUSH of the D$ (OOO_SYS) goes to OOO_DMISS2, which writes every dirty
// line out and waits for the last answer (from the L2, which keeps it in order with the
// I$'s fills).
//
// Simulation (DCACHE_SIM_UC): sim_uc_line names one line not cached (OOO_LSU3's
// uc_line): the test bench's tohost, which HTIF must see in the memory and set back to
// 0 there (Plan/CORE.md 5.1 rule 2).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_CPU
    #(
        parameter int VA      = 39,
        parameter int PAW     = 40,
        parameter int L2_SIZE = 256 * 1024
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,
        input  logic                        boot,
        input  logic [VA-1:1]               boot_pc,
        // the memory bus (the L2's)
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
        output logic                        m_axi4_rready,
        // the D$'s peripheral bus (uncached)
        output logic [PAW-1:0]              m_axil_awaddr,
        output logic                        m_axil_awvalid,
        input  logic                        m_axil_awready,
        output logic [63:0]                 m_axil_wdata,
        output logic [7:0]                  m_axil_wstrb,
        output logic                        m_axil_wvalid,
        input  logic                        m_axil_wready,
        input  logic [1:0]                  m_axil_bresp,
        input  logic                        m_axil_bvalid,
        output logic                        m_axil_bready,
        output logic [PAW-1:0]              m_axil_araddr,
        output logic                        m_axil_arvalid,
        input  logic                        m_axil_arready,
        input  logic [63:0]                 m_axil_rdata,
        input  logic [1:0]                  m_axil_rresp,
        input  logic                        m_axil_rvalid,
        output logic                        m_axil_rready
`ifdef DCACHE_SIM_UC
        ,
        input  logic [PAW-1:6]              sim_uc_line
`endif
`ifdef OOO_TRACE
        ,
        output logic [3:0]                  tr_valid,
        output logic [3:0][VA-1:1]          tr_pc,
        output logic [3:0][31:0]            tr_insn,
        output logic [3:0]                  tr_pair,
        output logic [3:0][31:0]            tr_insn2,
        output logic [3:0]                  tr_wr,
        output logic [3:0][4:0]             tr_rd,
        output logic [3:0][63:0]            tr_val,
        output logic                        tr_trap,
        output logic                        tr_int,
        output logic [4:0]                  tr_cause,
        output logic [VA-1:1]               tr_trap_pc,
        output logic [3:0]                  tr_st,
        output logic [3:0][63:0]            tr_st_addr,
        output logic [3:0][63:0]            tr_st_data,
        output logic [3:0][1:0]             tr_st_size
`endif
    );

    logic             dc_miss_valid, dc_st_miss_valid, dc_fill_done, dc_done_v, dc_tw_en, dc_rf_en, dc_dirty_set;
    logic [PAW-1:6]   dc_miss_line, dc_st_miss_line;
    logic [4:0]       dc_miss_id, dc_done_id;
    logic [1:0]       dc_tw_way, dc_rf_way, dc_dirty_way;
    logic [5:0]       dc_tw_set, dc_dirty_idx;
    logic [PAW-12:0]  dc_tw_tag;
    logic [8:0]       dc_rf_addr;
    logic [63:0]      dc_rf_data;
    logic             dc_uc_req, dc_uc_we, dc_uc_done;
    logic [PAW-1:0]   dc_uc_addr;
    /* verilator lint_off UNUSEDSIGNAL */      // (the bus takes the strobes; the SQ's state is OOO_SYS's)
    logic [1:0]       dc_uc_size;
    logic             dc_sq_drained;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0]      dc_uc_wdata, dc_uc_rdata;
    logic [7:0]       dc_uc_wmask;
    logic [8:0]       dc_vr_addr;
    logic [1:0]       dc_vr_way;
    logic [63:0]      dc_vr_data;
    logic             fl_req, fl_take, fl_done;
    logic             ic_req_valid, ic_req_ready, ic_resp_valid, ic_flush, ic_done;
    logic [VA-1:1]    ic_req_pc;
    logic [255:0]     ic_resp_data;
    OOO_CORE #(.VA(VA), .PAW(PAW)) u_core
        (.clk(clk), .rst_n(rst_n), .boot(boot), .boot_pc(boot_pc),
         .ic_req_valid(ic_req_valid), .ic_req_pc(ic_req_pc), .ic_req_ready(ic_req_ready),
         .ic_resp_valid(ic_resp_valid), .ic_resp_data(ic_resp_data),
         .dc_miss_valid(dc_miss_valid), .dc_miss_line(dc_miss_line), .dc_miss_id(dc_miss_id),
         .dc_st_miss_valid(dc_st_miss_valid), .dc_st_miss_line(dc_st_miss_line), .dc_fill_done(dc_fill_done),
         .dc_done_v(dc_done_v), .dc_done_id(dc_done_id), .dc_tw_en(dc_tw_en), .dc_tw_way(dc_tw_way), .dc_tw_set(dc_tw_set),
         .dc_tw_tag(dc_tw_tag), .dc_rf_en(dc_rf_en), .dc_rf_way(dc_rf_way), .dc_rf_addr(dc_rf_addr), .dc_rf_data(dc_rf_data),
         .dc_dirty_set(dc_dirty_set), .dc_dirty_way(dc_dirty_way), .dc_dirty_idx(dc_dirty_idx), .dc_sq_drained(dc_sq_drained),
`ifdef DCACHE_SIM_UC
         .dc_uc_line_v(1'b1), .dc_uc_line(sim_uc_line),
`else
         .dc_uc_line_v(1'b0), .dc_uc_line('0),
`endif
         .dc_uc_req(dc_uc_req), .dc_uc_we(dc_uc_we), .dc_uc_addr(dc_uc_addr), .dc_uc_size(dc_uc_size),
         .dc_uc_wdata(dc_uc_wdata), .dc_uc_wmask(dc_uc_wmask), .dc_uc_done(dc_uc_done), .dc_uc_rdata(dc_uc_rdata),
         .dc_wt_valid(), .dc_wt_addr(), .dc_wt_data(), .dc_wt_mask(),     // (a store written into the D$: the bench's)
         .dc_vr_addr(dc_vr_addr), .dc_vr_way(dc_vr_way), .dc_vr_data(dc_vr_data),
         .fl_req(fl_req), .fl_take(fl_take), .fl_done(fl_done), .ic_flush(ic_flush), .ic_done(ic_done)
`ifdef OOO_TRACE
         ,
         .tr_valid(tr_valid), .tr_pc(tr_pc), .tr_insn(tr_insn), .tr_pair(tr_pair), .tr_insn2(tr_insn2), .tr_wr(tr_wr), .tr_rd(tr_rd), .tr_val(tr_val),
         .tr_trap(tr_trap), .tr_int(tr_int), .tr_cause(tr_cause), .tr_trap_pc(tr_trap_pc), .tr_st(tr_st), .tr_st_addr(tr_st_addr),
         .tr_st_data(tr_st_data), .tr_st_size(tr_st_size)
`endif
        );

    // ---- the D$'s and the I$'s buses into the L2
    logic [3:0]       d_awid, d_arid, i_arid, l_awid, l_arid, l_bid, l_rid;
    logic [PAW-1:0]   d_awaddr, d_araddr, i_araddr, l_awaddr, l_araddr;
    logic [7:0]       d_awlen, d_arlen, i_arlen, l_awlen, l_arlen, d_wstrb, l_wstrb;
    logic [2:0]       d_awsize, d_arsize, i_arsize, l_awsize, l_arsize;
    logic [1:0]       d_awburst, d_arburst, i_arburst, l_awburst, l_arburst, d_bresp, d_rresp, i_rresp, l_bresp, l_rresp;
    logic             d_awvalid, d_awready, d_wlast, d_wvalid, d_wready, d_bvalid, d_bready, d_arvalid, d_arready,
                      d_rlast, d_rvalid, d_rready, i_arvalid, i_arready, i_rlast, i_rvalid, i_rready,
                      l_awvalid, l_awready, l_wlast, l_wvalid, l_wready, l_bvalid, l_bready, l_arvalid, l_arready,
                      l_rlast, l_rvalid, l_rready;
    logic [63:0]      d_wdata, d_rdata, i_rdata, l_wdata, l_rdata;

    OOO_DMISS2 #(.PAW(PAW), .IW(5)) u_dmiss
        (.clk(clk), .rst_n(rst_n),
         .miss_valid(dc_miss_valid), .miss_line(dc_miss_line), .miss_id(dc_miss_id),
         .st_miss_valid(dc_st_miss_valid), .st_miss_line(dc_st_miss_line), .fill_done(dc_fill_done),
         .done_v(dc_done_v), .done_id(dc_done_id), .tw_en(dc_tw_en), .tw_way(dc_tw_way), .tw_set(dc_tw_set),
         .tw_tag(dc_tw_tag), .rf_en(dc_rf_en), .rf_way(dc_rf_way), .rf_addr(dc_rf_addr), .rf_data(dc_rf_data),
         .dirty_set(dc_dirty_set), .dirty_way(dc_dirty_way), .dirty_idx(dc_dirty_idx),
         .vr_addr(dc_vr_addr), .vr_way(dc_vr_way), .vr_data(dc_vr_data),
         .uc_req(dc_uc_req), .uc_we(dc_uc_we), .uc_addr(dc_uc_addr), .uc_wdata(dc_uc_wdata), .uc_wmask(dc_uc_wmask),
         .uc_done(dc_uc_done), .uc_rdata(dc_uc_rdata),
         .fl_req(fl_req), .fl_take(fl_take), .fl_done(fl_done),
         .m_axi4_awid(d_awid), .m_axi4_awaddr(d_awaddr), .m_axi4_awlen(d_awlen),
         .m_axi4_awsize(d_awsize), .m_axi4_awburst(d_awburst), .m_axi4_awvalid(d_awvalid),
         .m_axi4_awready(d_awready), .m_axi4_wdata(d_wdata), .m_axi4_wstrb(d_wstrb),
         .m_axi4_wlast(d_wlast), .m_axi4_wvalid(d_wvalid), .m_axi4_wready(d_wready),
         .m_axi4_bresp(d_bresp), .m_axi4_bvalid(d_bvalid), .m_axi4_bready(d_bready),
         .m_axi4_arid(d_arid), .m_axi4_araddr(d_araddr), .m_axi4_arlen(d_arlen),
         .m_axi4_arsize(d_arsize), .m_axi4_arburst(d_arburst), .m_axi4_arvalid(d_arvalid),
         .m_axi4_arready(d_arready), .m_axi4_rdata(d_rdata), .m_axi4_rresp(d_rresp),
         .m_axi4_rlast(d_rlast), .m_axi4_rvalid(d_rvalid), .m_axi4_rready(d_rready),
         .m_axil_awaddr(m_axil_awaddr), .m_axil_awvalid(m_axil_awvalid), .m_axil_awready(m_axil_awready),
         .m_axil_wdata(m_axil_wdata), .m_axil_wstrb(m_axil_wstrb), .m_axil_wvalid(m_axil_wvalid),
         .m_axil_wready(m_axil_wready), .m_axil_bresp(m_axil_bresp), .m_axil_bvalid(m_axil_bvalid),
         .m_axil_bready(m_axil_bready), .m_axil_araddr(m_axil_araddr), .m_axil_arvalid(m_axil_arvalid),
         .m_axil_arready(m_axil_arready), .m_axil_rdata(m_axil_rdata), .m_axil_rresp(m_axil_rresp),
         .m_axil_rvalid(m_axil_rvalid), .m_axil_rready(m_axil_rready));

    OOO_ICACHE #(.VA(VA), .PAW(PAW), .SETS(256), .WAYS(8), .AXI_ID(4'd2)) u_icache
        (.clk(clk), .rst_n(rst_n),
         .ic_req_valid(ic_req_valid), .ic_req_pc(ic_req_pc), .ic_req_ready(ic_req_ready),
         .ic_resp_valid(ic_resp_valid), .ic_resp_data(ic_resp_data), .ic_flush(ic_flush), .ic_done(ic_done),
         .m_axi4_arid(i_arid), .m_axi4_araddr(i_araddr), .m_axi4_arlen(i_arlen), .m_axi4_arsize(i_arsize),
         .m_axi4_arburst(i_arburst), .m_axi4_arvalid(i_arvalid), .m_axi4_arready(i_arready),
         .m_axi4_rdata(i_rdata), .m_axi4_rresp(i_rresp), .m_axi4_rlast(i_rlast), .m_axi4_rvalid(i_rvalid),
         .m_axi4_rready(i_rready));

    OOO_MARB #(.PAW(PAW), .IC_ID(4'd2)) u_marb
        (.clk(clk), .rst_n(rst_n),
         .i_arid(i_arid), .i_araddr(i_araddr), .i_arlen(i_arlen), .i_arsize(i_arsize), .i_arburst(i_arburst),
         .i_arvalid(i_arvalid), .i_arready(i_arready),
         .i_rdata(i_rdata), .i_rresp(i_rresp), .i_rlast(i_rlast), .i_rvalid(i_rvalid), .i_rready(i_rready),
         .d_awid(d_awid), .d_awaddr(d_awaddr), .d_awlen(d_awlen), .d_awsize(d_awsize), .d_awburst(d_awburst),
         .d_awvalid(d_awvalid), .d_awready(d_awready),
         .d_wdata(d_wdata), .d_wstrb(d_wstrb), .d_wlast(d_wlast), .d_wvalid(d_wvalid), .d_wready(d_wready),
         .d_bresp(d_bresp), .d_bvalid(d_bvalid), .d_bready(d_bready),
         .d_arid(d_arid), .d_araddr(d_araddr), .d_arlen(d_arlen), .d_arsize(d_arsize), .d_arburst(d_arburst),
         .d_arvalid(d_arvalid), .d_arready(d_arready),
         .d_rdata(d_rdata), .d_rresp(d_rresp), .d_rlast(d_rlast), .d_rvalid(d_rvalid), .d_rready(d_rready),
         .m_awid(l_awid), .m_awaddr(l_awaddr), .m_awlen(l_awlen), .m_awsize(l_awsize), .m_awburst(l_awburst),
         .m_awvalid(l_awvalid), .m_awready(l_awready),
         .m_wdata(l_wdata), .m_wstrb(l_wstrb), .m_wlast(l_wlast), .m_wvalid(l_wvalid), .m_wready(l_wready),
         .m_bid(l_bid), .m_bresp(l_bresp), .m_bvalid(l_bvalid), .m_bready(l_bready),
         .m_arid(l_arid), .m_araddr(l_araddr), .m_arlen(l_arlen), .m_arsize(l_arsize), .m_arburst(l_arburst),
         .m_arvalid(l_arvalid), .m_arready(l_arready),
         .m_rid(l_rid), .m_rdata(l_rdata), .m_rresp(l_rresp), .m_rlast(l_rlast), .m_rvalid(l_rvalid),
         .m_rready(l_rready));

    /* verilator lint_off UNUSEDSIGNAL */      // (the memory side's other AXI4 fields are the bus's: constants)
    logic             l2_awlock, l2_arlock, l2_ready, l2_ev_read, l2_ev_miss;
    logic [3:0]       l2_awcache, l2_arcache, l2_awqos, l2_arqos;
    logic [2:0]       l2_awprot, l2_arprot;
    /* verilator lint_on UNUSEDSIGNAL */
    CPU_L2 #(.ADDR_WIDTH(PAW), .ID_WIDTH(4), .SIZE_BYTES(L2_SIZE), .WAYS(4)) u_l2
        (.clk(clk), .rst_n(rst_n),
         .s_axi4_awid(l_awid), .s_axi4_awaddr(l_awaddr), .s_axi4_awlen(l_awlen), .s_axi4_awsize(l_awsize),
         .s_axi4_awburst(l_awburst), .s_axi4_awvalid(l_awvalid), .s_axi4_awready(l_awready),
         .s_axi4_wdata(l_wdata), .s_axi4_wstrb(l_wstrb), .s_axi4_wlast(l_wlast), .s_axi4_wvalid(l_wvalid),
         .s_axi4_wready(l_wready), .s_axi4_bid(l_bid), .s_axi4_bresp(l_bresp), .s_axi4_bvalid(l_bvalid),
         .s_axi4_bready(l_bready),
         .s_axi4_arid(l_arid), .s_axi4_araddr(l_araddr), .s_axi4_arlen(l_arlen), .s_axi4_arsize(l_arsize),
         .s_axi4_arburst(l_arburst), .s_axi4_arvalid(l_arvalid), .s_axi4_arready(l_arready),
         .s_axi4_rid(l_rid), .s_axi4_rdata(l_rdata), .s_axi4_rresp(l_rresp), .s_axi4_rlast(l_rlast),
         .s_axi4_rvalid(l_rvalid), .s_axi4_rready(l_rready),
         .m_axi4_awid(m_axi4_awid), .m_axi4_awaddr(m_axi4_awaddr), .m_axi4_awlen(m_axi4_awlen),
         .m_axi4_awsize(m_axi4_awsize), .m_axi4_awburst(m_axi4_awburst), .m_axi4_awlock(l2_awlock),
         .m_axi4_awcache(l2_awcache), .m_axi4_awprot(l2_awprot), .m_axi4_awqos(l2_awqos),
         .m_axi4_awvalid(m_axi4_awvalid), .m_axi4_awready(m_axi4_awready),
         .m_axi4_wdata(m_axi4_wdata), .m_axi4_wstrb(m_axi4_wstrb), .m_axi4_wlast(m_axi4_wlast),
         .m_axi4_wvalid(m_axi4_wvalid), .m_axi4_wready(m_axi4_wready),
         .m_axi4_bid(4'd0), .m_axi4_bresp(m_axi4_bresp), .m_axi4_bvalid(m_axi4_bvalid), .m_axi4_bready(m_axi4_bready),
         .m_axi4_arid(m_axi4_arid), .m_axi4_araddr(m_axi4_araddr), .m_axi4_arlen(m_axi4_arlen),
         .m_axi4_arsize(m_axi4_arsize), .m_axi4_arburst(m_axi4_arburst), .m_axi4_arlock(l2_arlock),
         .m_axi4_arcache(l2_arcache), .m_axi4_arprot(l2_arprot), .m_axi4_arqos(l2_arqos),
         .m_axi4_arvalid(m_axi4_arvalid), .m_axi4_arready(m_axi4_arready),
         .m_axi4_rid(4'd0), .m_axi4_rdata(m_axi4_rdata), .m_axi4_rresp(m_axi4_rresp), .m_axi4_rlast(m_axi4_rlast),
         .m_axi4_rvalid(m_axi4_rvalid), .m_axi4_rready(m_axi4_rready),
         .ready(l2_ready), .ev_read(l2_ev_read), .ev_miss(l2_ev_miss));

endmodule : OOO_CPU
