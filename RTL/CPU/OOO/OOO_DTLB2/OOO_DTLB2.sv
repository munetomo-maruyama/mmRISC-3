//---------------------------------------------------------------------------
// OOO_DTLB2.sv
//
// The DTLB of the hit path at 100 MHz (Doc/STRATEGY.md 4.3 M1, Plan/OOC.md 28.13):
// SETS sets of 2 ways of 4 KB pages, in distributed RAM, read in M1 from the
// address in a register. As OOO_UBTB2: 2 compares, not 32, and a RAM of 32 is as
// small as one of 16.
//
//   A larger page is kept as the 4 KB of it that were asked for: a TLB is a cache,
//   so that is allowed, and the lookup has one index.
//   No ASID: tlb_flush when satp changes. r_ok, w_ok are what the walk found for
//   the privilege of now, with PMP (Plan/OOC.md 28.13: not joined yet).
//
// A flush walks the sets, a cycle each: it comes at the ROB's head (SFENCE.VMA,
// OOO_SYS), with nothing in flight, and busy holds whoever must wait for it.
// A refill replaces a way in turn; the walk (half-rate, Doc/STRATEGY.md 4.4)
// writes through tlb_w*, from registers.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DTLB2
    #(
        parameter int SETS = 32,
        parameter int VA   = 39,
        parameter int PAW  = 40
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        input  logic                  tr_on,      // translation; else the address is physical
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [PAW-1:12]       va,         // M1: bits above VA are physical ones, with tr_on off
        /* verilator lint_on UNUSEDSIGNAL */
        output logic                  hit,        // M1, all of it from a register
        output logic [PAW-1:12]       ptag,
        output logic                  r_ok,
        output logic                  w_ok,

        input  logic                  tlb_we,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [VA-1:12]        tlb_vpn,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [PAW-1:12]       tlb_ptag,
        input  logic                  tlb_r,
        input  logic                  tlb_w,
        input  logic                  tlb_flush,
        output logic                  busy
    );

    localparam int IW = $clog2(SETS);
    localparam int TW = VA - 12 - IW;
    localparam int EW = 1 + 2 + TW + (PAW - 12);

    logic [IW-1:0] wa;
    logic [EW-1:0] wd;
    logic [1:0]    we;
    logic          turn, walk;
    logic [IW-1:0] wp;

    logic [EW-1:0] e [2];
    logic [1:0]    h;
    for (genvar w = 0; w < 2; w++) begin : g_way
        (* ram_style = "distributed" *) logic [EW-1:0] m [SETS];
        initial for (int i = 0; i < SETS; i++) m[i] = '0;
        always_ff @(posedge clk) if (we[w]) m[wa] <= wd;
        assign e[w] = m[va[12+IW-1:12]];
        assign h[w] = e[w][EW-1] && e[w][EW-4:PAW-12] == va[VA-1:12+IW];
    end

    always @(*) begin
        hit  = !tr_on || h != 2'd0;
        ptag = !tr_on ? va : h[1] ? e[1][PAW-13:0] : e[0][PAW-13:0];
        r_ok = !tr_on || (h[1] ? e[1][EW-2] : e[0][EW-2]);
        w_ok = !tr_on || (h[1] ? e[1][EW-3] : e[0][EW-3]);
        // the walk writes both ways of a set, with the valid bit at 0
        wa   = walk ? wp : tlb_vpn[12+IW-1:12];
        wd   = walk ? '0 : {1'b1, tlb_r, tlb_w, tlb_vpn[VA-1:12+IW], tlb_ptag};
        we   = walk ? 2'b11 : tlb_we ? (turn ? 2'b10 : 2'b01) : 2'b00;
        busy = walk;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            turn <= 1'b0;
            walk <= 1'b0;
            wp   <= '0;
        end else begin
            if (tlb_we && !walk) turn <= !turn;
            if (tlb_flush && !walk) begin
                walk <= 1'b1;
                wp   <= '0;
            end else if (walk) begin
                wp <= wp + 1'b1;
                if (wp == IW'(SETS - 1)) walk <= 1'b0;
            end
        end
    end

endmodule : OOO_DTLB2
