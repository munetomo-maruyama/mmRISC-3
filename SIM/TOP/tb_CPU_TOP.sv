//---------------------------------------------------------------------------
// tb_CPU_TOP.sv : CPU_TOP's DMA port (step 2.6, RTL/CPU/TOP), Verilator only (--timing)
//
//   CPU_TOP's memory bus     -> AXI4_RAM at 0x8000_0000 (SIM/OCD's), dma_prog.hex in it
//   CPU_TOP's peripheral bus -> AXIL_RAM at 0x1200_0000 (SIM/OCD's)
//
// The core runs dma_prog.S from 0x8000_0000. The bench, on the DMA port (AXI4-Lite):
//   1 reads 0x8000_1000: the core's word, dirty in the D$ (memory still 0): coherent
//   2 writes 0x8000_2008 in pieces (strobes 0x3c, then 0x81: 2 + 2 bytes, then 1 + 1)
//   3 a write with no strobe (answered, nothing written)
//   4 writes 0x8000_2000 (8 bytes), the word the core waits for in its D$ line
//   5 reads 0x8000_3000: the core's copy of 0x8000_2008 (it saw both of the DMA's writes)
//   6 writes and reads 0x1200_0010 (a device, through the peripheral bus) and reads
//     0x0000_0000 (no device: AXIL_RAM's DECERR, SLVERR on the DMA port)
// and, all along, the DM idle. PASS when every answer is as expected.
//---------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_CPU_TOP;
    localparam int PAW = 40;
    logic clk = 1'b0;
    always #10 clk = ~clk;
    logic [7:0] por = '0;
    always_ff @(posedge clk) if (!(&por)) por <= por + 1'b1;
    wire rst_n = &por;

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
    logic [PAW-1:0] d_awaddr = '0, d_araddr = '0;
    logic           d_awvalid = 0, d_awready, d_wvalid = 0, d_wready, d_bvalid, d_bready = 0;
    logic           d_arvalid = 0, d_arready, d_rvalid, d_rready = 0;
    logic [63:0]    d_wdata = '0, d_rdata;
    logic [7:0]     d_wstrb = '0;
    logic [1:0]     d_bresp, d_rresp;

    /* verilator lint_off PINCONNECTEMPTY */
    CPU_TOP #(.RESET_VECTOR(64'h8000_0000), .CLINT_TICK_DIV(1)) u_top
        (.clk(clk), .rst_dbg_n(rst_n), .rst_n(rst_n), .ndmreset(), .irq_src('0),
         .jtag_tck(1'b0), .jtag_tms_i(1'b1), .jtag_tms_o(), .jtag_tms_oe(), .jtag_tdi(1'b0), .jtag_tdo(), .jtag_tdo_oe(),
         .jtag_trst_n(1'b1), .cjtag_en(1'b0), .cjtag_online(), .dbg_auth_en(1'b0), .dbg_auth_key(32'h0),
         .dbg_halted(), .dbg_running(), .dbg_dmactive(),
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
         .s_dma_awaddr(d_awaddr), .s_dma_awvalid(d_awvalid), .s_dma_awready(d_awready), .s_dma_wdata(d_wdata),
         .s_dma_wstrb(d_wstrb), .s_dma_wvalid(d_wvalid), .s_dma_wready(d_wready), .s_dma_bresp(d_bresp),
         .s_dma_bvalid(d_bvalid), .s_dma_bready(d_bready), .s_dma_araddr(d_araddr), .s_dma_arvalid(d_arvalid),
         .s_dma_arready(d_arready), .s_dma_rdata(d_rdata), .s_dma_rresp(d_rresp), .s_dma_rvalid(d_rvalid),
         .s_dma_rready(d_rready));
    AXI4_RAM #(.ID_WIDTH(4), .ADDR_WIDTH(PAW), .DEPTH(4096), .BASE_ADDR(40'h00_8000_0000)) u_ram
        (.clk(clk), .rst_n(rst_n),
         .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awlock(1'b0),
         .awcache(4'd0), .awprot(3'd0), .awqos(4'd0), .awvalid(awvalid), .awready(awready),
         .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
         .bid(), .bresp(bresp), .bvalid(bvalid), .bready(bready),
         .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arlock(1'b0),
         .arcache(4'd0), .arprot(3'd0), .arqos(4'd0), .arvalid(arvalid), .arready(arready),
         .rid(), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready));
    /* verilator lint_on PINCONNECTEMPTY */
    AXIL_RAM #(.ADDR_WIDTH(PAW), .DEPTH(512), .BASE_ADDR(40'h00_1200_0000)) u_pram
        (.clk(clk), .rst_n(rst_n),
         .awaddr(l_awaddr), .awprot(3'd0), .awvalid(l_awvalid), .awready(l_awready),
         .wdata(l_wdata), .wstrb(l_wstrb), .wvalid(l_wvalid), .wready(l_wready),
         .bresp(l_bresp), .bvalid(l_bvalid), .bready(l_bready),
         .araddr(l_araddr), .arprot(3'd0), .arvalid(l_arvalid), .arready(l_arready),
         .rdata(l_rdata), .rresp(l_rresp), .rvalid(l_rvalid), .rready(l_rready));

    initial begin
        logic [63:0] img [0:255];
        for (int i = 0; i < 256; i++) img[i] = 64'h0;
        $readmemh("dma_prog.hex", img);   // (obj/, where it runs)
        #1;
        for (int i = 0; i < 256; i++) u_ram.mem[i] = img[i];
    end

    int fails = 0;
    task automatic dma_write(input logic [PAW-1:0] a, input logic [63:0] d, input logic [7:0] s, output logic [1:0] resp);
        @(negedge clk);
        d_awaddr = a; d_wdata = d; d_wstrb = s; d_awvalid = 1; d_wvalid = 1;
        do @(posedge clk); while (!d_awready);
        @(negedge clk); d_awvalid = 0; d_wvalid = 0; d_bready = 1;
        while (!d_bvalid) @(negedge clk);
        resp = d_bresp;
        @(posedge clk); @(negedge clk); d_bready = 0;
    endtask
    task automatic dma_read(input logic [PAW-1:0] a, output logic [63:0] d, output logic [1:0] resp);
        @(negedge clk);
        d_araddr = a; d_arvalid = 1;
        do @(posedge clk); while (!d_arready);
        @(negedge clk); d_arvalid = 0; d_rready = 1;
        while (!d_rvalid) @(negedge clk);
        d = d_rdata; resp = d_rresp;
        @(posedge clk); @(negedge clk); d_rready = 0;
    endtask
    task automatic check(input string what, input logic [63:0] got, input logic [63:0] exp);
        if (got !== exp) begin $display("[tb_CPU_TOP] FAIL %s: 0x%016x, expected 0x%016x", what, got, exp); fails++; end
        else $display("[tb_CPU_TOP] ok   %s: 0x%016x", what, got);
    endtask

    initial begin
        logic [63:0] d; logic [1:0] r;
        wait (rst_n === 1'b1);
        repeat (3000) @(posedge clk);
        check("memory at 0x8000_1000 before (the core's word only in the D$)", u_ram.mem[12'h200], 64'h0);
        dma_read(40'h8000_1000, d, r);           check("1 DMA read of the core's dirty word", d, 64'h1122334455667788);
        check("  its answer", {62'd0, r}, 64'd0);
        dma_write(40'h8000_2008, 64'hffeeddccbbaa9988, 8'h3c, r);  check("2 DMA write, strobes 0x3c: answer", {62'd0, r}, 64'd0);
        dma_write(40'h8000_2008, 64'h0100000000000002, 8'h81, r);  check("  strobes 0x81: answer", {62'd0, r}, 64'd0);
        dma_write(40'h8000_2010, 64'h5555555555555555, 8'h00, r);  check("3 DMA write, no strobe: answer", {62'd0, r}, 64'd0);
        dma_write(40'h8000_2000, 64'hcafef00ddeadbeef, 8'hff, r);  check("4 DMA write of the word the core waits for", {62'd0, r}, 64'd0);
        repeat (500) @(posedge clk);
        dma_read(40'h8000_3000, d, r);           check("5 the core's copy of the pieces", d, 64'h0100ddccbbaa0002);
        dma_read(40'h8000_2010, d, r);           check("  the word of no strobe", d, 64'h0);
        dma_write(40'h1200_0010, 64'h0123456789abcdef, 8'hff, r);  check("6 DMA write to a device: answer", {62'd0, r}, 64'd0);
        dma_read(40'h1200_0010, d, r);           check("  read back", d, 64'h0123456789abcdef);
        check("  the device's own word", u_pram.mem[2], 64'h0123456789abcdef);
        dma_read(40'h0000_0000, d, r);           check("  no device there: SLVERR", {62'd0, r}, 64'd2);
        $display("[tb_CPU_TOP] %s (%0d failures)", fails == 0 ? "PASS" : "FAIL", fails);
        $finish;
    end
    initial begin #2000000; $display("[tb_CPU_TOP] FAIL: timeout"); $finish; end
endmodule
