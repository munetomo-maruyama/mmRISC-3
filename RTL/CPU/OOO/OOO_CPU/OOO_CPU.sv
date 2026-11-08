//---------------------------------------------------------------------------
// OOO_CPU.sv
//
// The core with its D$ (Plan/CORE.md 1, B3; step 1.3 E2, Plan/OOC.md 29.34): OOO_CORE,
// whose OOO_LSU3 has the D$'s arrays, and OOO_DMISS, its miss handler, with the D$'s
// memory bus (AXI4) and its peripheral bus (AXI4-Lite: what is not cacheable) as
// ports. The D$ is written through. The I$ is still a port (a model in the test bench,
// Plan/CORE.md 4.6), with FENCE.I's invalidate; FENCE.I's FLUSH of the D$ (OOO_SYS)
// goes to OOO_DMISS, which waits for its writes.
//
// Simulation (DCACHE_SIM_UC): sim_uc_line names one line not cached (OOO_LSU3's
// uc_line): the test bench's tohost, which HTIF must see in the memory and set back to
// 0 there (Plan/CORE.md 5.1 rule 2).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_CPU
    #(
        parameter int VA  = 39,
        parameter int PAW = 40
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,
        input  logic                        boot,
        input  logic [VA-1:1]               boot_pc,
        // I$
        output logic                        ic_req_valid,
        output logic [VA-1:1]               ic_req_pc,
        input  logic                        ic_req_ready,
        input  logic                        ic_resp_valid,
        input  logic [255:0]                ic_resp_data,
        output logic                        ic_flush,   // FENCE.I: invalidate the I$ (until ic_done)
        input  logic                        ic_done,
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
    logic             dc_uc_req, dc_uc_we, dc_uc_done, dc_wt_valid, dc_wt_ready;
    logic [PAW-1:0]   dc_uc_addr, dc_wt_addr;
    /* verilator lint_off UNUSEDSIGNAL */      // (the bus takes the strobes; the SQ's state is OOO_SYS's)
    logic [1:0]       dc_uc_size;
    logic             dc_sq_drained;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0]      dc_uc_wdata, dc_uc_rdata, dc_wt_data;
    logic [7:0]       dc_uc_wmask, dc_wt_mask;
    logic             fl_req, fl_take, fl_done;
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
         .dc_wt_valid(dc_wt_valid), .dc_wt_addr(dc_wt_addr), .dc_wt_data(dc_wt_data), .dc_wt_mask(dc_wt_mask),
         .dc_wt_ready(dc_wt_ready),
         .fl_req(fl_req), .fl_take(fl_take), .fl_done(fl_done), .ic_flush(ic_flush), .ic_done(ic_done)
`ifdef OOO_TRACE
         ,
         .tr_valid(tr_valid), .tr_pc(tr_pc), .tr_insn(tr_insn), .tr_pair(tr_pair), .tr_insn2(tr_insn2), .tr_wr(tr_wr), .tr_rd(tr_rd), .tr_val(tr_val),
         .tr_trap(tr_trap), .tr_int(tr_int), .tr_cause(tr_cause), .tr_trap_pc(tr_trap_pc), .tr_st(tr_st), .tr_st_addr(tr_st_addr),
         .tr_st_data(tr_st_data), .tr_st_size(tr_st_size)
`endif
        );

    OOO_DMISS #(.PAW(PAW), .IW(5)) u_dmiss
        (.clk(clk), .rst_n(rst_n),
         .miss_valid(dc_miss_valid), .miss_line(dc_miss_line), .miss_id(dc_miss_id),
         .st_miss_valid(dc_st_miss_valid), .st_miss_line(dc_st_miss_line), .fill_done(dc_fill_done),
         .done_v(dc_done_v), .done_id(dc_done_id), .tw_en(dc_tw_en), .tw_way(dc_tw_way), .tw_set(dc_tw_set),
         .tw_tag(dc_tw_tag), .rf_en(dc_rf_en), .rf_way(dc_rf_way), .rf_addr(dc_rf_addr), .rf_data(dc_rf_data),
         .dirty_set(dc_dirty_set), .dirty_way(dc_dirty_way), .dirty_idx(dc_dirty_idx),
         .wt_valid(dc_wt_valid), .wt_addr(dc_wt_addr), .wt_data(dc_wt_data), .wt_mask(dc_wt_mask), .wt_ready(dc_wt_ready),
         .uc_req(dc_uc_req), .uc_we(dc_uc_we), .uc_addr(dc_uc_addr), .uc_wdata(dc_uc_wdata), .uc_wmask(dc_uc_wmask),
         .uc_done(dc_uc_done), .uc_rdata(dc_uc_rdata),
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

endmodule : OOO_CPU
