//---------------------------------------------------------------------------
// CPU_TOP.sv
//
// mmRISC-3 as one block for a SoC (step 2.6, Doc/STRATEGY.md; LitexSystem/cpu/mmrisc3):
// OOO_CPU (the core, its I$, D$, L2, CLINT and PLIC) with DBG_TOP (the debug logic,
// JTAG / cJTAG), as SIM/OCD's tb_OCD joins them, and what a SoC needs beside:
//
//   the start     OOO_CPU starts at RESET_VECTOR (boot, boot_pc) a few cycles after its
//                 reset (DBG_TOP's rst_bus_n: the system reset, ndmreset, hartreset);
//                 until then the DM shows the hart unavailable (hart_not_ready)
//   the DMA port  an AXI4-Lite slave (s_dma_*, 64 bits) for the SoC's DMA masters (LiteX's
//                 SD card), taken through OOO_CPU's bus master port (bm_*: OOO_DMISS2's
//                 debugger port), so it sees and changes memory as the core does: through
//                 the D$, coherent with it and with the L2 (as mmRISC-2's DMA_CACHE). One
//                 access at a time, shared with the DM's Access Memory and SBA (the DM's
//                 request, a pulse, is kept until it is served; the DM first). A read is
//                 one 8-byte access at the address's 8-byte word; a write is cut by its
//                 strobes into aligned pieces of 8, 4, 2, 1 bytes (8 when all 8 are set),
//                 the lowest first. An error answer (a device's, outside the cacheable
//                 memory) is SLVERR.
//
// The buses are OOO_CPU's: the L2's AXI4 memory bus, which carries every fetch (OOO_ICACHE
// caches what it fetches: the SoC routes the boot ROM's lines from it), and the D$'s
// AXI4-Lite peripheral bus (what is outside [CBASE, CTOP), less CPU_MMIO's CLINT and PLIC).
//
// Resets (DBG_TOP's): rst_dbg_n the debug logic's power-on reset, rst_n the system's (the
// CPU's alone: LiteX's CPU reset, the board's nSRST); a reset empties the write-back caches.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_TOP
    #(
        parameter int VA      = 39,
        parameter int PAW     = 40,
        parameter int L2_SIZE = 512 * 1024,
        parameter int CLINT_TICK_DIV = 100,
        parameter logic [63:0]    RESET_VECTOR = 64'h0000_0000_1000_0000,
        parameter logic [PAW-1:0] CBASE = 40'h00_8000_0000,
        parameter logic [PAW-1:0] CTOP  = 40'h01_0000_0000
    )
    (
        input  logic                  clk,
        input  logic                  rst_dbg_n,
        input  logic                  rst_n,
        output logic                  ndmreset,
        input  logic [31:1]           irq_src,
        // JTAG / cJTAG
        input  logic                  jtag_tck,
        input  logic                  jtag_tms_i,
        output logic                  jtag_tms_o,
        output logic                  jtag_tms_oe,
        input  logic                  jtag_tdi,
        output logic                  jtag_tdo,
        output logic                  jtag_tdo_oe,
        input  logic                  jtag_trst_n,
        input  logic                  cjtag_en,
        output logic                  cjtag_online,
        input  logic                  dbg_auth_en,
        input  logic [31:0]           dbg_auth_key,
        output logic                  dbg_halted,
        output logic                  dbg_running,
        output logic                  dbg_dmactive,
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
        output logic                  m_axil_rready,
        // the DMA port (AXI4-Lite slave; the 8-byte word of its addresses: the strobes say the bytes)
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [PAW-1:0]        s_dma_awaddr,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic                  s_dma_awvalid,
        output logic                  s_dma_awready,
        input  logic [63:0]           s_dma_wdata,
        input  logic [7:0]            s_dma_wstrb,
        input  logic                  s_dma_wvalid,
        output logic                  s_dma_wready,
        output logic [1:0]            s_dma_bresp,
        output logic                  s_dma_bvalid,
        input  logic                  s_dma_bready,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [PAW-1:0]        s_dma_araddr,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic                  s_dma_arvalid,
        output logic                  s_dma_arready,
        output logic [63:0]           s_dma_rdata,
        output logic [1:0]            s_dma_rresp,
        output logic                  s_dma_rvalid,
        input  logic                  s_dma_rready
    );

    // ---- the start
    /* verilator lint_off SYNCASYNCNET */
    logic       rst_bus_n;                  // (DBG_TOP's, released in step with clk: also used as a level below)
    /* verilator lint_on SYNCASYNCNET */
    logic [3:0] bt;
    logic       boot, booted;
    always_ff @(posedge clk or negedge rst_bus_n) begin
        if (!rst_bus_n) begin bt <= '0; booted <= 1'b0; end
        else if (!booted) begin bt <= bt + 1'b1; if (&bt) booted <= 1'b1; end
    end
    assign boot = !booted && &bt;

    // ---- the debug logic
    logic           haltreq, resumereq, resethaltreq, halted, running, resumed;
    logic           reg_req, reg_wr, reg_size64, reg_ack, reg_err;
    logic [15:0]    reg_regno;
    logic [63:0]    reg_wdata, reg_rdata;
    logic           dm_req, dm_wr;
    logic [PAW-1:0] dm_addr;
    logic [1:0]     dm_size;
    logic [63:0]    dm_wdata;
    logic           dm_ack;
    logic           bm_req, bm_wr, bm_ack;
    logic [PAW-1:0] bm_addr;
    logic [1:0]     bm_size;
    logic [63:0]    bm_wdata, bm_rdata;
    logic [2:0]     bm_err;
    DBG_TOP #(.ADDR_WIDTH(PAW)) u_dbg
        (.clk(clk), .rst_dbg_n(rst_dbg_n), .rst_n(rst_n), .rst_bus_n(rst_bus_n), .ndmreset(ndmreset),
         .hart_not_ready(!booted),
         .jtag_tck(jtag_tck), .jtag_tms_i(jtag_tms_i), .jtag_tms_o(jtag_tms_o), .jtag_tms_oe(jtag_tms_oe),
         .jtag_tdi(jtag_tdi), .jtag_tdo(jtag_tdo), .jtag_tdo_oe(jtag_tdo_oe), .jtag_trst_n(jtag_trst_n),
         .cjtag_en(cjtag_en), .cjtag_online(cjtag_online),
         .dbg_auth_en(dbg_auth_en), .dbg_auth_key(dbg_auth_key), .dbg_dmactive(dbg_dmactive),
         .hart_haltreq(haltreq), .hart_resumereq(resumereq), .hart_resethaltreq(resethaltreq),
         .hart_halted(halted), .hart_running(running), .hart_resumed(resumed),
         .reg_req(reg_req), .reg_wr(reg_wr), .reg_regno(reg_regno), .reg_size64(reg_size64), .reg_wdata(reg_wdata),
         .reg_ack(reg_ack), .reg_rdata(reg_rdata), .reg_err(reg_err),
         .bm_req(dm_req), .bm_wr(dm_wr), .bm_addr(dm_addr), .bm_size(dm_size), .bm_wdata(dm_wdata),
         .bm_ack(dm_ack), .bm_rdata(bm_rdata), .bm_err(bm_err));
    assign dbg_halted  = halted;
    assign dbg_running = running;

    // ---- the bus master port: the DM's requests and the DMA's, one at a time
    typedef enum logic [1:0] { A_IDLE, A_BUSY, A_RESP } a_st_t;
    a_st_t          a_st;
    logic           a_dm, a_rd;             // the access in flight: the DM's; a DMA read
    logic           dm_pend, dm_pwr;
    logic [PAW-1:0] dm_paddr;
    logic [1:0]     dm_psize;
    logic [63:0]    dm_pwdata;
    logic [PAW-1:3] w_word;                 // a DMA write: its 8-byte word, data, strobes left
    logic [63:0]    w_data;
    logic [7:0]     w_left;
    logic           w_err;

    // the next piece of a write: the lowest strobe, the largest aligned piece there
    logic [2:0] p_lo;
    logic [1:0] p_size;
    logic [7:0] p_mask;
    always_comb begin
        p_lo = 3'd0;
        for (int i = 7; i >= 0; i--) if (w_left[i]) p_lo = 3'(i);
        if (w_left == 8'hff)                                       begin p_size = 2'd3; p_mask = 8'hff; end
        else if (p_lo[1:0] == 2'd0 && w_left[p_lo +: 4] == 4'hf)  begin p_size = 2'd2; p_mask = 8'h0f << p_lo; end
        else if (p_lo[0] == 1'b0 && w_left[p_lo +: 2] == 2'b11)    begin p_size = 2'd1; p_mask = 8'h03 << p_lo; end
        else                                                       begin p_size = 2'd0; p_mask = 8'h01 << p_lo; end
    end

    // an access is begun only with OOO_CPU out of reset; one in flight when it is reset ends
    // there (b_done), with whatever bm_rdata says: nothing waits for an answer that cannot come
    logic b_done;
    assign b_done        = bm_ack || !rst_bus_n;
    assign s_dma_awready = a_st == A_IDLE && rst_bus_n && !dm_pend && s_dma_awvalid && s_dma_wvalid;
    assign s_dma_wready  = s_dma_awready;
    assign s_dma_arready = a_st == A_IDLE && rst_bus_n && !dm_pend && !(s_dma_awvalid && s_dma_wvalid) && s_dma_arvalid;
    assign dm_ack        = a_st == A_BUSY && b_done && a_dm;

    always_ff @(posedge clk or negedge rst_dbg_n) begin
        if (!rst_dbg_n) begin
            a_st <= A_IDLE; a_dm <= 1'b0; a_rd <= 1'b0; dm_pend <= 1'b0; bm_req <= 1'b0;
            s_dma_bvalid <= 1'b0; s_dma_rvalid <= 1'b0; w_left <= '0; w_err <= 1'b0;
        end else begin
            bm_req <= 1'b0;
            if (dm_req) dm_pend <= 1'b1;
            case (a_st)
                A_IDLE:
                    if (dm_pend && rst_bus_n) begin
                        dm_pend <= dm_req;          // (a new pulse only after this one's answer)
                        a_dm <= 1'b1; a_rd <= 1'b0; bm_req <= 1'b1; a_st <= A_BUSY;
                    end else if (s_dma_awready) begin
                        a_dm <= 1'b0; a_rd <= 1'b0; w_err <= 1'b0;
                        if (s_dma_wstrb == 8'd0) begin s_dma_bvalid <= 1'b1; a_st <= A_RESP; end
                        else begin w_left <= s_dma_wstrb; bm_req <= 1'b1; a_st <= A_BUSY; end
                    end else if (s_dma_arready) begin
                        a_dm <= 1'b0; a_rd <= 1'b1; bm_req <= 1'b1; a_st <= A_BUSY;
                    end
                A_BUSY:
                    if (b_done) begin
                        if (a_dm) a_st <= A_IDLE;
                        else if (a_rd) begin s_dma_rvalid <= 1'b1; a_st <= A_RESP; end
                        else begin
                            w_left <= w_left & ~p_mask;
                            w_err  <= w_err || bm_err != 3'd0;
                            if ((w_left & ~p_mask) == 8'd0) begin s_dma_bvalid <= 1'b1; a_st <= A_RESP; end
                            else bm_req <= rst_bus_n;   // the next piece (w_left as it is now: p_* next cycle)
                        end
                    end
                A_RESP: begin
                    if (s_dma_bvalid && s_dma_bready) begin s_dma_bvalid <= 1'b0; a_st <= A_IDLE; end
                    if (s_dma_rvalid && s_dma_rready) begin s_dma_rvalid <= 1'b0; a_st <= A_IDLE; end
                end
                default: a_st <= A_IDLE;
            endcase
        end
    end
    always_ff @(posedge clk) begin
        if (dm_req) begin dm_pwr <= dm_wr; dm_paddr <= dm_addr; dm_psize <= dm_size; dm_pwdata <= dm_wdata; end
        if (s_dma_awready) begin w_word <= s_dma_awaddr[PAW-1:3]; w_data <= s_dma_wdata; end
        if (s_dma_arready) w_word <= s_dma_araddr[PAW-1:3];
        if (a_st == A_BUSY && b_done && a_rd) begin
            s_dma_rdata <= bm_rdata;
            s_dma_rresp <= bm_err != 3'd0 ? 2'b10 : 2'b00;
        end
    end
    assign s_dma_bresp = w_err ? 2'b10 : 2'b00;

    // what goes to OOO_CPU with bm_req (it takes them in that cycle)
    always_comb begin
        if (a_dm) begin
            bm_wr = dm_pwr; bm_addr = dm_paddr; bm_size = dm_psize; bm_wdata = dm_pwdata;
        end else if (a_rd) begin
            bm_wr = 1'b0; bm_addr = {w_word, 3'd0}; bm_size = 2'd3; bm_wdata = '0;
        end else begin
            bm_wr = 1'b1; bm_addr = {w_word, p_lo}; bm_size = p_size; bm_wdata = w_data >> {p_lo, 3'd0};
        end
    end

    // ---- the core
    OOO_CPU #(.VA(VA), .PAW(PAW), .L2_SIZE(L2_SIZE), .CLINT_TICK_DIV(CLINT_TICK_DIV), .CBASE(CBASE), .CTOP(CTOP)) u_cpu
        (.clk(clk), .rst_n(rst_bus_n), .boot(boot), .boot_pc(RESET_VECTOR[VA-1:1]), .irq_src(irq_src),
         .hart_haltreq(haltreq), .hart_resumereq(resumereq), .hart_resethaltreq(resethaltreq),
         .hart_halted(halted), .hart_running(running), .hart_resumed(resumed),
         .reg_req(reg_req), .reg_wr(reg_wr), .reg_regno(reg_regno), .reg_size64(reg_size64), .reg_wdata(reg_wdata),
         .reg_ack(reg_ack), .reg_rdata(reg_rdata), .reg_err(reg_err),
         .bm_req(bm_req), .bm_wr(bm_wr), .bm_addr(bm_addr), .bm_size(bm_size), .bm_wdata(bm_wdata),
         .bm_ack(bm_ack), .bm_rdata(bm_rdata), .bm_err(bm_err),
         .m_axi4_awid(m_axi4_awid), .m_axi4_awaddr(m_axi4_awaddr), .m_axi4_awlen(m_axi4_awlen), .m_axi4_awsize(m_axi4_awsize),
         .m_axi4_awburst(m_axi4_awburst), .m_axi4_awvalid(m_axi4_awvalid), .m_axi4_awready(m_axi4_awready),
         .m_axi4_wdata(m_axi4_wdata), .m_axi4_wstrb(m_axi4_wstrb), .m_axi4_wlast(m_axi4_wlast), .m_axi4_wvalid(m_axi4_wvalid),
         .m_axi4_wready(m_axi4_wready), .m_axi4_bresp(m_axi4_bresp), .m_axi4_bvalid(m_axi4_bvalid), .m_axi4_bready(m_axi4_bready),
         .m_axi4_arid(m_axi4_arid), .m_axi4_araddr(m_axi4_araddr), .m_axi4_arlen(m_axi4_arlen), .m_axi4_arsize(m_axi4_arsize),
         .m_axi4_arburst(m_axi4_arburst), .m_axi4_arvalid(m_axi4_arvalid), .m_axi4_arready(m_axi4_arready),
         .m_axi4_rdata(m_axi4_rdata), .m_axi4_rresp(m_axi4_rresp), .m_axi4_rlast(m_axi4_rlast), .m_axi4_rvalid(m_axi4_rvalid),
         .m_axi4_rready(m_axi4_rready),
         .m_axil_awaddr(m_axil_awaddr), .m_axil_awvalid(m_axil_awvalid), .m_axil_awready(m_axil_awready),
         .m_axil_wdata(m_axil_wdata), .m_axil_wstrb(m_axil_wstrb), .m_axil_wvalid(m_axil_wvalid), .m_axil_wready(m_axil_wready),
         .m_axil_bresp(m_axil_bresp), .m_axil_bvalid(m_axil_bvalid), .m_axil_bready(m_axil_bready),
         .m_axil_araddr(m_axil_araddr), .m_axil_arvalid(m_axil_arvalid), .m_axil_arready(m_axil_arready),
         .m_axil_rdata(m_axil_rdata), .m_axil_rresp(m_axil_rresp), .m_axil_rvalid(m_axil_rvalid), .m_axil_rready(m_axil_rready));

endmodule
