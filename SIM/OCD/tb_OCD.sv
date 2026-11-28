//---------------------------------------------------------------------------
// tb_OCD.sv : OpenOCD with mmRISC-3's OOO_CPU and its debug logic (step 1.8 J1,
// Plan/OOC.md 29.101), Verilator only (--timing)
//
// As mmRISC-2's SIM_OCD: OpenOCD (adapter driver remote_bitbang) connects to the
// DPI-C server in jtag_rbb.cpp, which drives JTAG; each pin update is applied
// every TCK_STEP ns while the system clock runs on its own, so the DTM's CDC is
// exercised with a real debugger. The system:
//
//   DBG_TOP (RTL/CPU/DBG: cJTAG / JTAG, the DTM, the DM) - OOO_CPU's hart_*, reg_*, bm_*
//   OOO_CPU's memory bus  -> AXI4_RAM  at 0x8000_0000 (512 KB)
//   OOO_CPU's peripheral bus (what CPU_MMIO does not answer: the CLINT, the PLIC)
//                         -> AXIL_RAM  at 0x1200_0000 (4 KB)
//
// The reset: a power-on reset of the debug logic and of the system; the system
// reset also by OpenOCD's SRST and by the DM (ndmreset, hartreset: DBG_TOP's
// rst_bus_n). After rst_bus_n the hart is started (OOO_CPU boot) at 0x8000_0000;
// until then it is not ready (the DM shows it unavailable).
//
//   +port=<n>     TCP port (default 44853)
//   +auth=1       authentication on (the key 0xbeefcafe, as mmRISC-2's)
//   +sysmhz=<n>   the system clock in MHz (default 50)
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_OCD;

    import "DPI-C" function int rbb_init(input int port);
    import "DPI-C" function int rbb_tick(inout int tck, inout int tms, inout int tdi,
                                         inout int trst_n, inout int srst_n, input int tdo);

    localparam real TCK_STEP = 7.0;     // ns per remote_bitbang command
    localparam int  VA = 39, PAW = 40;

    real  sys_half = 10.0;
    logic clk = 1'b0;
    always begin
        #(sys_half);
        clk = ~clk;
    end

    // ---- resets
    logic [7:0] por = '0;
    logic       rst_dbg_n, rst_sys_n, rst_bus_n, ndmreset;
    always_ff @(posedge clk) if (!(&por)) por <= por + 1'b1;
    assign rst_dbg_n = &por;
    logic jtag_tck = 1'b0, jtag_tms = 1'b1, jtag_tdi = 1'b0, jtag_trst_n = 1'b1, srst_n = 1'b1;
    assign rst_sys_n = rst_dbg_n && srst_n;

    // the start after each reset: OOO_CPU boot a few cycles after rst_bus_n
    logic [3:0] bt;
    logic       boot, booted;
    always_ff @(posedge clk or negedge rst_bus_n) begin
        if (!rst_bus_n) begin bt <= '0; booted <= 1'b0; end
        else if (!booted) begin bt <= bt + 1'b1; if (&bt) booted <= 1'b1; end
    end
    assign boot = !booted && &bt;

    // ---- the debug logic
    logic        auth = 1'b0;
    logic        haltreq, resumereq, resethaltreq, halted, running, resumed;
    logic        reg_req, reg_wr, reg_size64, reg_ack, reg_err;
    logic [15:0] reg_regno;
    logic [63:0] reg_wdata, reg_rdata;
    logic        bm_req, bm_wr, bm_ack;
    logic [PAW-1:0] bm_addr;
    logic [1:0]  bm_size;
    logic [63:0] bm_wdata, bm_rdata;
    logic [2:0]  bm_err;
    wire         tdo, tdo_oe;
`ifndef VIA_CPU_TOP
    /* verilator lint_off PINCONNECTEMPTY */
    DBG_TOP #(.ADDR_WIDTH(PAW)) u_dbg
        (.clk(clk), .rst_dbg_n(rst_dbg_n), .rst_n(rst_sys_n), .rst_bus_n(rst_bus_n), .ndmreset(ndmreset),
         .hart_not_ready(!booted),
         .jtag_tck(jtag_tck), .jtag_tms_i(jtag_tms), .jtag_tms_o(), .jtag_tms_oe(), .jtag_tdi(jtag_tdi),
         .jtag_tdo(tdo), .jtag_tdo_oe(tdo_oe), .jtag_trst_n(jtag_trst_n), .cjtag_en(1'b0), .cjtag_online(),
         .dbg_auth_en(auth), .dbg_auth_key(32'hbeefcafe), .dbg_dmactive(),
         .hart_haltreq(haltreq), .hart_resumereq(resumereq), .hart_resethaltreq(resethaltreq),
         .hart_halted(halted), .hart_running(running), .hart_resumed(resumed),
         .reg_req(reg_req), .reg_wr(reg_wr), .reg_regno(reg_regno), .reg_size64(reg_size64), .reg_wdata(reg_wdata),
         .reg_ack(reg_ack), .reg_rdata(reg_rdata), .reg_err(reg_err),
         .bm_req(bm_req), .bm_wr(bm_wr), .bm_addr(bm_addr), .bm_size(bm_size), .bm_wdata(bm_wdata),
         .bm_ack(bm_ack), .bm_rdata(bm_rdata), .bm_err(bm_err));
    /* verilator lint_on PINCONNECTEMPTY */
`endif

    // ---- the core
    logic [3:0]     awid, arid;
    logic [PAW-1:0] awaddr, araddr;
    logic [7:0]     awlen, arlen, wstrb;
    logic [2:0]     awsize, arsize;
    logic [1:0]     awburst, arburst, bresp, rresp;
    logic           awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
    logic [63:0]    wdata, rdata;
    logic [PAW-1:0] l_awaddr, l_araddr;
    logic           l_awvalid, l_awready, l_wvalid, l_wready, l_bvalid, l_bready, l_arvalid, l_arready, l_rvalid, l_rready;
    logic [63:0]    l_wdata, l_rdata;
    logic [7:0]     l_wstrb;
    logic [1:0]     l_bresp, l_rresp;
`ifndef VIA_CPU_TOP
    OOO_CPU #(.VA(VA), .PAW(PAW)) u_cpu
        (.clk(clk), .rst_n(rst_bus_n), .boot(boot), .boot_pc((VA-1)'(64'h8000_0000 >> 1)), .irq_src('0),
         .hart_haltreq(haltreq), .hart_resumereq(resumereq), .hart_resethaltreq(resethaltreq),
         .hart_halted(halted), .hart_running(running), .hart_resumed(resumed),
         .reg_req(reg_req), .reg_wr(reg_wr), .reg_regno(reg_regno), .reg_size64(reg_size64), .reg_wdata(reg_wdata),
         .reg_ack(reg_ack), .reg_rdata(reg_rdata), .reg_err(reg_err),
         .bm_req(bm_req), .bm_wr(bm_wr), .bm_addr(bm_addr), .bm_size(bm_size), .bm_wdata(bm_wdata),
         .bm_ack(bm_ack), .bm_rdata(bm_rdata), .bm_err(bm_err),
         .m_axi4_awid(awid), .m_axi4_awaddr(awaddr), .m_axi4_awlen(awlen), .m_axi4_awsize(awsize),
         .m_axi4_awburst(awburst), .m_axi4_awvalid(awvalid), .m_axi4_awready(awready), .m_axi4_wdata(wdata),
         .m_axi4_wstrb(wstrb), .m_axi4_wlast(wlast), .m_axi4_wvalid(wvalid), .m_axi4_wready(wready),
         .m_axi4_bresp(bresp), .m_axi4_bvalid(bvalid), .m_axi4_bready(bready), .m_axi4_arid(arid),
         .m_axi4_araddr(araddr), .m_axi4_arlen(arlen), .m_axi4_arsize(arsize), .m_axi4_arburst(arburst),
         .m_axi4_arvalid(arvalid), .m_axi4_arready(arready), .m_axi4_rdata(rdata), .m_axi4_rresp(rresp),
         .m_axi4_rlast(rlast), .m_axi4_rvalid(rvalid), .m_axi4_rready(rready),
         .m_axil_awaddr(l_awaddr), .m_axil_awvalid(l_awvalid), .m_axil_awready(l_awready), .m_axil_wdata(l_wdata),
         .m_axil_wstrb(l_wstrb), .m_axil_wvalid(l_wvalid), .m_axil_wready(l_wready), .m_axil_bresp(l_bresp),
         .m_axil_bvalid(l_bvalid), .m_axil_bready(l_bready), .m_axil_araddr(l_araddr), .m_axil_arvalid(l_arvalid),
         .m_axil_arready(l_arready), .m_axil_rdata(l_rdata), .m_axil_rresp(l_rresp), .m_axil_rvalid(l_rvalid),
         .m_axil_rready(l_rready));
`else
    // VIA_CPU_TOP (step 2.6, run_ocd.sh top): the same through RTL/CPU/TOP's CPU_TOP, which joins
    // the two as above, starts the hart itself, and puts the DM's memory accesses through its
    // arbiter with the DMA port (idle here)
    assign rst_bus_n = rst_sys_n;           // (only for the start above, not used here)
    /* verilator lint_off PINCONNECTEMPTY */
    CPU_TOP #(.VA(VA), .PAW(PAW), .RESET_VECTOR(64'h8000_0000)) u_top
        (.clk(clk), .rst_dbg_n(rst_dbg_n), .rst_n(rst_sys_n), .ndmreset(ndmreset), .irq_src('0),
         .jtag_tck(jtag_tck), .jtag_tms_i(jtag_tms), .jtag_tms_o(), .jtag_tms_oe(), .jtag_tdi(jtag_tdi),
         .jtag_tdo(tdo), .jtag_tdo_oe(tdo_oe), .jtag_trst_n(jtag_trst_n), .cjtag_en(1'b0), .cjtag_online(),
         .dbg_auth_en(auth), .dbg_auth_key(32'hbeefcafe), .dbg_halted(), .dbg_running(), .dbg_dmactive(),
         .m_axi4_awid(awid), .m_axi4_awaddr(awaddr), .m_axi4_awlen(awlen), .m_axi4_awsize(awsize),
         .m_axi4_awburst(awburst), .m_axi4_awvalid(awvalid), .m_axi4_awready(awready), .m_axi4_wdata(wdata),
         .m_axi4_wstrb(wstrb), .m_axi4_wlast(wlast), .m_axi4_wvalid(wvalid), .m_axi4_wready(wready),
         .m_axi4_bresp(bresp), .m_axi4_bvalid(bvalid), .m_axi4_bready(bready), .m_axi4_arid(arid),
         .m_axi4_araddr(araddr), .m_axi4_arlen(arlen), .m_axi4_arsize(arsize), .m_axi4_arburst(arburst),
         .m_axi4_arvalid(arvalid), .m_axi4_arready(arready), .m_axi4_rdata(rdata), .m_axi4_rresp(rresp),
         .m_axi4_rlast(rlast), .m_axi4_rvalid(rvalid), .m_axi4_rready(rready),
         .m_axil_awaddr(l_awaddr), .m_axil_awvalid(l_awvalid), .m_axil_awready(l_awready), .m_axil_wdata(l_wdata),
         .m_axil_wstrb(l_wstrb), .m_axil_wvalid(l_wvalid), .m_axil_wready(l_wready), .m_axil_bresp(l_bresp),
         .m_axil_bvalid(l_bvalid), .m_axil_bready(l_bready), .m_axil_araddr(l_araddr), .m_axil_arvalid(l_arvalid),
         .m_axil_arready(l_arready), .m_axil_rdata(l_rdata), .m_axil_rresp(l_rresp), .m_axil_rvalid(l_rvalid),
         .m_axil_rready(l_rready),
         .s_dma_awaddr('0), .s_dma_awvalid(1'b0), .s_dma_awready(), .s_dma_wdata('0), .s_dma_wstrb('0),
         .s_dma_wvalid(1'b0), .s_dma_wready(), .s_dma_bresp(), .s_dma_bvalid(), .s_dma_bready(1'b0),
         .s_dma_araddr('0), .s_dma_arvalid(1'b0), .s_dma_arready(), .s_dma_rdata(), .s_dma_rresp(),
         .s_dma_rvalid(), .s_dma_rready(1'b0));
    /* verilator lint_on PINCONNECTEMPTY */
`endif

    // ---- the RAMs (they keep their contents over a system reset: rst_dbg_n)
    /* verilator lint_off PINCONNECTEMPTY */
    AXI4_RAM #(.ID_WIDTH(4), .ADDR_WIDTH(PAW), .DEPTH(65536), .BASE_ADDR(40'h00_8000_0000)) u_ram
        (.clk(clk), .rst_n(rst_dbg_n),
         .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awlock(1'b0),
         .awcache(4'd0), .awprot(3'd0), .awqos(4'd0), .awvalid(awvalid), .awready(awready),
         .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
         .bid(), .bresp(bresp), .bvalid(bvalid), .bready(bready),
         .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arlock(1'b0),
         .arcache(4'd0), .arprot(3'd0), .arqos(4'd0), .arvalid(arvalid), .arready(arready),
         .rid(), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready));
    /* verilator lint_on PINCONNECTEMPTY */
    AXIL_RAM #(.ADDR_WIDTH(PAW), .DEPTH(512), .BASE_ADDR(40'h00_1200_0000)) u_pram
        (.clk(clk), .rst_n(rst_dbg_n),
         .awaddr(l_awaddr), .awprot(3'd0), .awvalid(l_awvalid), .awready(l_awready),
         .wdata(l_wdata), .wstrb(l_wstrb), .wvalid(l_wvalid), .wready(l_wready),
         .bresp(l_bresp), .bvalid(l_bvalid), .bready(l_bready),
         .araddr(l_araddr), .arprot(3'd0), .arvalid(l_arvalid), .arready(l_arready),
         .rdata(l_rdata), .rresp(l_rresp), .rvalid(l_rvalid), .rready(l_rready));

`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_OCD.vcd");
        $dumpvars(0, tb_OCD);
    end
`endif

    initial begin
        int port, au, mhz, st;
        int tck, tms, tdi, trst_n, sr_n;
        if (!$value$plusargs("port=%d", port)) port = 44853;
        if (!$value$plusargs("auth=%d", au)) au = 0;
        if (!$value$plusargs("sysmhz=%d", mhz)) mhz = 50;
        auth     = (au != 0);
        sys_half = 500.0 / mhz;
        $display("[tb_OCD] system clock %0d MHz, authentication %s", mhz, au ? "on" : "off");
        wait (rst_dbg_n === 1'b1);
        #1000;
        if (rbb_init(port) != 0) $finish;
        tck = 0; tms = 1; tdi = 0; trst_n = 1; sr_n = 1;
        forever begin
            st = rbb_tick(tck, tms, tdi, trst_n, sr_n, (tdo === 1'b1) ? 1 : 0);
            if (st == 2) begin
                $display("[tb_OCD] OpenOCD disconnected at %0t", $time);
                $finish;
            end
            jtag_tck    = tck[0];
            jtag_tms    = tms[0];
            jtag_tdi    = tdi[0];
            jtag_trst_n = trst_n[0];
            srst_n      = sr_n[0];
            #(TCK_STEP);
        end
    end

endmodule : tb_OCD
