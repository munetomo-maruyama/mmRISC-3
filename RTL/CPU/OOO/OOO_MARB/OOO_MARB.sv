//---------------------------------------------------------------------------
// OOO_MARB.sv
//
// The memory bus's arbiter in front of the L2 (step 1.7 H2, Plan/OOC.md 29.57): the
// I$'s fills (OOO_ICACHE, reads only, ID IC_ID) and OOO_DMISS (the D$'s fills, its
// writes through, other IDs) on one AXI4 into CPU_L2.
//
//   AR  the two in turn when both ask (the one not served last first); the choice
//       is held while its AR waits for arready, so an AR never changes under
//       arvalid. The rest goes through as it is.
//   R   back by its ID (CPU_L2 keeps the asker's): IC_ID to the I$, any other to
//       the D$; rready from the one it goes to.
//   AW, W, B   the D$'s only: straight through.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_MARB
    #(
        parameter int PAW = 40,
        parameter logic [3:0] IC_ID = 4'd2
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        // ---- the I$ (reads)
        input  logic [3:0]            i_arid,
        input  logic [PAW-1:0]        i_araddr,
        input  logic [7:0]            i_arlen,
        input  logic [2:0]            i_arsize,
        input  logic [1:0]            i_arburst,
        input  logic                  i_arvalid,
        output logic                  i_arready,
        output logic [63:0]           i_rdata,
        output logic [1:0]            i_rresp,
        output logic                  i_rlast,
        output logic                  i_rvalid,
        input  logic                  i_rready,

        // ---- the D$ (OOO_DMISS)
        input  logic [3:0]            d_awid,
        input  logic [PAW-1:0]        d_awaddr,
        input  logic [7:0]            d_awlen,
        input  logic [2:0]            d_awsize,
        input  logic [1:0]            d_awburst,
        input  logic                  d_awvalid,
        output logic                  d_awready,
        input  logic [63:0]           d_wdata,
        input  logic [7:0]            d_wstrb,
        input  logic                  d_wlast,
        input  logic                  d_wvalid,
        output logic                  d_wready,
        output logic [1:0]            d_bresp,
        output logic                  d_bvalid,
        input  logic                  d_bready,
        input  logic [3:0]            d_arid,
        input  logic [PAW-1:0]        d_araddr,
        input  logic [7:0]            d_arlen,
        input  logic [2:0]            d_arsize,
        input  logic [1:0]            d_arburst,
        input  logic                  d_arvalid,
        output logic                  d_arready,
        output logic [63:0]           d_rdata,
        output logic [1:0]            d_rresp,
        output logic                  d_rlast,
        output logic                  d_rvalid,
        input  logic                  d_rready,

        // ---- to the L2
        output logic [3:0]            m_awid,
        output logic [PAW-1:0]        m_awaddr,
        output logic [7:0]            m_awlen,
        output logic [2:0]            m_awsize,
        output logic [1:0]            m_awburst,
        output logic                  m_awvalid,
        input  logic                  m_awready,
        output logic [63:0]           m_wdata,
        output logic [7:0]            m_wstrb,
        output logic                  m_wlast,
        output logic                  m_wvalid,
        input  logic                  m_wready,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [3:0]            m_bid,        // (the D$'s only)
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [1:0]            m_bresp,
        input  logic                  m_bvalid,
        output logic                  m_bready,
        output logic [3:0]            m_arid,
        output logic [PAW-1:0]        m_araddr,
        output logic [7:0]            m_arlen,
        output logic [2:0]            m_arsize,
        output logic [1:0]            m_arburst,
        output logic                  m_arvalid,
        input  logic                  m_arready,
        input  logic [3:0]            m_rid,
        input  logic [63:0]           m_rdata,
        input  logic [1:0]            m_rresp,
        input  logic                  m_rlast,
        input  logic                  m_rvalid,
        output logic                  m_rready
    );

    // ---- AR
    logic lock, lsel, last;                     // an AR held (and whose: 1 the D$); the one served last
    logic sel;
    always @(*) begin
        if (lock)                       sel = lsel;
        else if (i_arvalid && d_arvalid) sel = !last;
        else                            sel = d_arvalid;
    end
    assign m_arvalid = sel ? d_arvalid : i_arvalid;
    assign m_arid    = sel ? d_arid    : i_arid;
    assign m_araddr  = sel ? d_araddr  : i_araddr;
    assign m_arlen   = sel ? d_arlen   : i_arlen;
    assign m_arsize  = sel ? d_arsize  : i_arsize;
    assign m_arburst = sel ? d_arburst : i_arburst;
    assign i_arready = !sel && m_arready;
    assign d_arready =  sel && m_arready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock <= 1'b0;
            lsel <= 1'b0;
            last <= 1'b0;
        end else begin
            lock <= m_arvalid && !m_arready;
            lsel <= sel;
            if (m_arvalid && m_arready) last <= sel;
        end
    end

    // ---- R
    logic r_i;
    assign r_i      = m_rid == IC_ID;
    assign i_rvalid = m_rvalid &&  r_i;
    assign d_rvalid = m_rvalid && !r_i;
    assign i_rdata  = m_rdata;
    assign d_rdata  = m_rdata;
    assign i_rresp  = m_rresp;
    assign d_rresp  = m_rresp;
    assign i_rlast  = m_rlast;
    assign d_rlast  = m_rlast;
    assign m_rready = r_i ? i_rready : d_rready;

    // ---- AW, W, B: the D$'s
    assign m_awid    = d_awid;
    assign m_awaddr  = d_awaddr;
    assign m_awlen   = d_awlen;
    assign m_awsize  = d_awsize;
    assign m_awburst = d_awburst;
    assign m_awvalid = d_awvalid;
    assign d_awready = m_awready;
    assign m_wdata   = d_wdata;
    assign m_wstrb   = d_wstrb;
    assign m_wlast   = d_wlast;
    assign m_wvalid  = d_wvalid;
    assign d_wready  = m_wready;
    assign d_bresp   = m_bresp;
    assign d_bvalid  = m_bvalid;
    assign m_bready  = d_bready;

endmodule
