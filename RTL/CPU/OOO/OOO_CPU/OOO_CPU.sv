//---------------------------------------------------------------------------
// OOO_CPU.sv
//
// The core with its D$ (Plan/CORE.md 1, B3): OOO_CORE, OOO_DCAD (the
// adapter from the LSU's abstract port to mmRISC-2's D$) and DCACHE, with
// the D$'s memory bus (AXI4) and its peripheral bus (AXI4-Lite: below
// MEM_BASE, nothing cached) as ports. The I$ is still a port (a model in
// the test bench, Plan/CORE.md 4.6); FENCE.I's FLUSH of the D$ (OOO_SYS)
// comes with B4.
//
// The LSU's dc_kill is not used: OOO_DCAD drops the older answers of an LQ
// entry when the entry sends a new request (OOO_LSU's header).
//
// Simulation (DCACHE_SIM_UC): sim_uc_line names one line the D$ does not
// cache, passed to the peripheral bus like an access below MEM_BASE: the
// test bench's tohost, which HTIF must see in the memory and set back to 0
// there (Plan/CORE.md 5.1 rule 2).
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
        input  logic [VA-1:1]               trap_vec,
        // I$
        output logic                        ic_req_valid,
        output logic [VA-1:1]               ic_req_pc,
        input  logic                        ic_req_ready,
        input  logic                        ic_resp_valid,
        input  logic [127:0]                ic_resp_data,
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
        output logic [1:0]                  tr_valid,
        output logic [1:0][VA-1:1]          tr_pc,
        output logic [1:0][31:0]            tr_insn,
        output logic [1:0]                  tr_wr,
        output logic [1:0][4:0]             tr_rd,
        output logic [1:0][63:0]            tr_val,
        output logic                        tr_trap,
        output logic [4:0]                  tr_cause,
        output logic [VA-1:1]               tr_trap_pc,
        output logic [1:0]                  tr_st,
        output logic [1:0][63:0]            tr_st_addr,
        output logic [1:0][63:0]            tr_st_data,
        output logic [1:0][1:0]             tr_st_size
`endif
    );

    logic             dc_req_valid, dc_hit, dc_fill_valid, dc_fill_ready, dc_st_valid, dc_st_ready;
    logic [PAW-1:0]   dc_req_addr, dc_st_addr;
    logic [2:0]       dc_req_tag, dc_fill_tag;
    logic [63:0]      dc_rdata, dc_fill_data, dc_st_data;
    logic [7:0]       dc_st_mask;
    /* verilator lint_off UNUSEDSIGNAL */      // (OOO_DCAD drops old answers itself)
    logic [7:0]       dc_kill;
    /* verilator lint_on UNUSEDSIGNAL */

    OOO_CORE #(.VA(VA), .PAW(PAW)) u_core
        (.clk(clk), .rst_n(rst_n), .boot(boot), .boot_pc(boot_pc), .trap_vec(trap_vec),
         .ic_req_valid(ic_req_valid), .ic_req_pc(ic_req_pc), .ic_req_ready(ic_req_ready),
         .ic_resp_valid(ic_resp_valid), .ic_resp_data(ic_resp_data),
         .dc_req_valid(dc_req_valid), .dc_req_addr(dc_req_addr), .dc_req_tag(dc_req_tag), .dc_hit(dc_hit),
         .dc_rdata(dc_rdata), .dc_fill_valid(dc_fill_valid), .dc_fill_tag(dc_fill_tag), .dc_fill_data(dc_fill_data),
         .dc_fill_ready(dc_fill_ready), .dc_kill(dc_kill), .dc_st_valid(dc_st_valid), .dc_st_addr(dc_st_addr),
         .dc_st_data(dc_st_data), .dc_st_mask(dc_st_mask), .dc_st_ready(dc_st_ready)
`ifdef OOO_TRACE
         ,
         .tr_valid(tr_valid), .tr_pc(tr_pc), .tr_insn(tr_insn), .tr_wr(tr_wr), .tr_rd(tr_rd), .tr_val(tr_val),
         .tr_trap(tr_trap), .tr_cause(tr_cause), .tr_trap_pc(tr_trap_pc), .tr_st(tr_st), .tr_st_addr(tr_st_addr),
         .tr_st_data(tr_st_data), .tr_st_size(tr_st_size)
`endif
        );

    logic             d_req_valid, d_req_ready, d_req_cancel, d_resp_valid, d_hit_now;
    logic [PAW-1:0]   d_req_addr, d_req_paddr;
    logic [1:0]       d_req_size;
    logic [4:0]       d_req_cmd;
    logic [63:0]      d_req_wdata, d_resp_data, d_hit_now_data;
    /* verilator lint_off PINCONNECTEMPTY */
    OOO_DCAD #(.NLQ(8), .PAW(PAW), .DEPTH(8)) u_dcad
        (.clk(clk), .rst_n(rst_n),
         .dc_req_valid(dc_req_valid), .dc_req_addr(dc_req_addr), .dc_req_tag(dc_req_tag), .dc_hit(dc_hit),
         .dc_rdata(dc_rdata), .dc_fill_valid(dc_fill_valid), .dc_fill_tag(dc_fill_tag), .dc_fill_data(dc_fill_data),
         .dc_fill_ready(dc_fill_ready), .dc_st_valid(dc_st_valid), .dc_st_addr(dc_st_addr), .dc_st_data(dc_st_data),
         .dc_st_mask(dc_st_mask), .dc_st_ready(dc_st_ready),
         .fl_req(1'b0), .fl_take(), .fl_done(),
         .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr), .d_req_size(d_req_size),
         .d_req_cmd(d_req_cmd), .d_req_wdata(d_req_wdata), .d_req_paddr(d_req_paddr), .d_req_cancel(d_req_cancel),
         .d_resp_valid(d_resp_valid), .d_resp_data(d_resp_data), .d_hit_now(d_hit_now), .d_hit_now_data(d_hit_now_data));
    DCACHE #(.PADDR_WIDTH(PAW), .ROB_DEPTH(8)) u_dc
        (.clk(clk), .rst_n(rst_n),
         .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr), .d_req_size(d_req_size),
         .d_req_cmd(d_req_cmd), .d_req_wdata(d_req_wdata), .d_req_paddr(d_req_paddr), .d_req_cancel(d_req_cancel),
         .d_resp_valid(d_resp_valid), .d_resp_drop(), .d_resp_data(d_resp_data), .d_resp_error(),
         .d_hit_now(d_hit_now), .d_hit_now_data(d_hit_now_data),
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
         .m_axil_rvalid(m_axil_rvalid), .m_axil_rready(m_axil_rready),
         .ev_miss(), .ev_vic_copy()
`ifdef DCACHE_SIM_UC
         ,
         .sim_uc_line(sim_uc_line)
`endif
        );
    /* verilator lint_on PINCONNECTEMPTY */

endmodule : OOO_CPU
