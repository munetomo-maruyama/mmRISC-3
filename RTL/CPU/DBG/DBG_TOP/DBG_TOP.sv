//---------------------------------------------------------------------------
// DBG_TOP.sv
//
// The debug logic of mmRISC-3 (step 1.8 J1, Plan/OOC.md 29.101; RISC-V Debug Spec 1.0,
// JTAG / cJTAG): mmRISC-2's DBG_CJTAG, DBG_DTM, DBG_CDC and DBG_DM as they were, wired
// as mmRISC-2's CPU_DBG wired them, for OOO_CPU:
//
//   DBG_CJTAG - DBG_DTM - DBG_CDC - DBG_DM -+- hart_*, reg_*: OOO_CPU's (OOO_TRAP, OOO_DBG)
//   [TCK domain]           [clk domain]     +- bm_*: OOO_CPU's (Access Memory, SBA through
//                                              OOO_DMISS2, coherent with the D$)
//
// What mmRISC-2's CPU_DBG had beside (its bus master DBG_BUSMST, its D$ port DBG_CACHE, its
// stand-in hart) is not here: OOO_CPU takes the DM's bus master interface itself.
//
// Resets, as mmRISC-2's (its CPU_DBG_SPEC.md 4.2):
//   rst_dbg_n   the debug logic's power-on reset: the DTM, the CDC and the DM (never a
//               system reset: "no mechanism to reset the DM other than dmactive")
//   jtag_trst_n the TAP alone
//   rst_n       the system reset; with ndmreset and hartreset it makes rst_bus_n, the
//               reset of OOO_CPU (the core, its caches, the L2: one hart). A reset empties
//               the write-back caches: what they hold and memory does not is lost (load a
//               program after `reset halt`, not before)
// hart_not_ready: the hart is out of reset and cannot run yet; the DM shows it unavailable.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module DBG_TOP
    #(
        parameter int          ADDR_WIDTH = 40,
        parameter logic [31:0] IDCODE     = 32'h36d6d001       // version 3, part 0x6d6d ("mm"), as mmRISC-2's 2
    )
    (
        input  logic                  clk,
        input  logic                  rst_dbg_n,
        input  logic                  rst_n,
        output logic                  rst_bus_n,
        output logic                  ndmreset,
        input  logic                  hart_not_ready,

        // JTAG / cJTAG pins
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

        // authentication
        input  logic                  dbg_auth_en,
        input  logic [31:0]           dbg_auth_key,
        output logic                  dbg_dmactive,

        // the hart (OOO_CPU)
        output logic                  hart_haltreq,
        output logic                  hart_resumereq,     // a pulse
        output logic                  hart_resethaltreq,
        input  logic                  hart_halted,
        input  logic                  hart_running,
        input  logic                  hart_resumed,       // a pulse
        output logic                  reg_req,            // a pulse
        output logic                  reg_wr,
        output logic [15:0]           reg_regno,
        output logic                  reg_size64,
        output logic [63:0]           reg_wdata,
        input  logic                  reg_ack,            // a pulse
        input  logic [63:0]           reg_rdata,
        input  logic                  reg_err,

        // its memory (OOO_CPU's bm_*)
        output logic                  bm_req,             // a pulse
        output logic                  bm_wr,
        output logic [ADDR_WIDTH-1:0] bm_addr,
        output logic [1:0]            bm_size,
        output logic [63:0]           bm_wdata,
        input  logic                  bm_ack,             // a pulse
        input  logic [63:0]           bm_rdata,
        input  logic [2:0]            bm_err
    );

    // ---- resets
    logic t_por_n, tap_rst_n, s_por_n, hartreset;
    DBG_RST_SYNC u_rst_t_por (.clk(jtag_tck), .rst_in_n(rst_dbg_n),               .rst_out_n(t_por_n));
    DBG_RST_SYNC u_rst_tap   (.clk(jtag_tck), .rst_in_n(rst_dbg_n & jtag_trst_n), .rst_out_n(tap_rst_n));
    DBG_RST_SYNC u_rst_s_por (.clk(clk),      .rst_in_n(rst_dbg_n),               .rst_out_n(s_por_n));
    DBG_RST_SYNC u_rst_bus   (.clk(clk),      .rst_in_n(rst_n & ~ndmreset & ~hartreset), .rst_out_n(rst_bus_n));
    logic bus_in_reset, hart_rst;
    DBG_SYNC #(.WIDTH(1), .RESET_VAL(1'b1)) u_sync_bus_rst
        (.clk(clk), .rst_n(s_por_n), .d(~rst_bus_n), .q(bus_in_reset));
    DBG_SYNC #(.WIDTH(1), .RESET_VAL(1'b1)) u_sync_hart_rst
        (.clk(clk), .rst_n(s_por_n), .d(~rst_n | ndmreset | hartreset), .q(hart_rst));
    logic        auth_en_s;
    logic [31:0] auth_key_s;
    DBG_SYNC #(.WIDTH(1),  .RESET_VAL(1'b1)) u_sync_auth_en
        (.clk(clk), .rst_n(s_por_n), .d(dbg_auth_en), .q(auth_en_s));
    DBG_SYNC #(.WIDTH(32), .RESET_VAL(32'd0)) u_sync_auth_key
        (.clk(clk), .rst_n(s_por_n), .d(dbg_auth_key), .q(auth_key_s));

    // ---- cJTAG / JTAG, the DTM, the CDC
    logic tap_ce, tap_tms, tap_tdi, tap_hold, dtm_tdo, dtm_tdo_oe;
    DBG_CJTAG u_cjtag
        (.por_n(rst_dbg_n), .cjtag_en(cjtag_en), .tck(jtag_tck), .tms_i(jtag_tms_i), .tms_o(jtag_tms_o),
         .tms_oe(jtag_tms_oe), .tdi(jtag_tdi), .tdo(jtag_tdo), .tdo_oe(jtag_tdo_oe), .t_rst_n(t_por_n),
         .tap_ce(tap_ce), .tap_tms(tap_tms), .tap_tdi(tap_tdi), .tap_hold(tap_hold), .dtm_tdo(dtm_tdo),
         .dtm_tdo_oe(dtm_tdo_oe), .online(cjtag_online));
    logic        t_start, t_wr, t_abort, t_busy, t_err;
    logic [6:0]  t_addr;
    logic [31:0] t_wdata, t_rdata;
    DBG_DTM #(.IDCODE(IDCODE), .ABITS(7)) u_dtm
        (.tck(jtag_tck), .tap_rst_n(tap_rst_n), .tap_ce(tap_ce), .tap_tms(tap_tms), .tap_tdi(tap_tdi),
         .tap_hold(tap_hold), .tdo(dtm_tdo), .tdo_oe(dtm_tdo_oe), .dmi_start(t_start), .dmi_addr(t_addr),
         .dmi_wr(t_wr), .dmi_wdata(t_wdata), .dmi_abort(t_abort), .dmi_busy(t_busy), .dmi_rdata(t_rdata),
         .dmi_err(t_err));
    logic        dmi_req, dmi_wr, dmi_ack, dmi_err;
    logic [6:0]  dmi_addr;
    logic [31:0] dmi_wdata, dmi_rdata;
    DBG_CDC #(.ABITS(7)) u_cdc
        (.tck(jtag_tck), .t_rst_n(t_por_n), .t_start(t_start), .t_addr(t_addr), .t_wr(t_wr), .t_wdata(t_wdata),
         .t_abort(t_abort), .t_busy(t_busy), .t_rdata(t_rdata), .t_err(t_err),
         .clk(clk), .s_rst_n(s_por_n), .dmi_req(dmi_req), .dmi_addr(dmi_addr), .dmi_wr(dmi_wr),
         .dmi_wdata(dmi_wdata), .dmi_ack(dmi_ack), .dmi_rdata(dmi_rdata), .dmi_err(dmi_err));

    // ---- the DM
    /* verilator lint_off PINCONNECTEMPTY */
    DBG_DM #(.ADDR_WIDTH(ADDR_WIDTH)) u_dm
        (.clk(clk), .rst_n(s_por_n), .dmi_req(dmi_req), .dmi_wr(dmi_wr), .dmi_addr(dmi_addr), .dmi_wdata(dmi_wdata),
         .dmi_ack(dmi_ack), .dmi_rdata(dmi_rdata), .dmi_err(dmi_err), .auth_en(auth_en_s), .auth_key(auth_key_s),
         .hart_haltreq(hart_haltreq), .hart_resumereq(hart_resumereq), .hart_resethaltreq(hart_resethaltreq),
         .hart_hartreset(hartreset), .hart_halted(hart_halted), .hart_running(hart_running),
         .hart_resumed(hart_resumed), .hart_in_reset(hart_rst), .hart_not_ready(hart_not_ready),
         .reg_req(reg_req), .reg_wr(reg_wr), .reg_regno(reg_regno), .reg_size64(reg_size64), .reg_wdata(reg_wdata),
         .reg_ack(reg_ack), .reg_rdata(reg_rdata), .reg_err(reg_err),
         .bm_req(bm_req), .bm_wr(bm_wr), .bm_addr(bm_addr), .bm_size(bm_size), .bm_wdata(bm_wdata),
         .bm_ack(bm_ack), .bm_rdata(bm_rdata), .bm_err(bm_err), .bus_in_reset(bus_in_reset),
         .ndmreset(ndmreset), .sys_in_reset(bus_in_reset), .dmactive_o(dbg_dmactive), .authenticated_o());
    /* verilator lint_on PINCONNECTEMPTY */

endmodule : DBG_TOP
