//---------------------------------------------------------------------------
// OOO_DTLB3.sv
//
// The DTLB of OOO_LSU4 with translation on (step 1.8 V1, Plan/OOC.md 29.87):
// OOO_DTLB2 (SETS sets of 2 ways of 4 KB pages in LUT RAM, read in M from the
// address in a register; a larger page kept as the 4 KB of it asked for) with
// two changes:
//
//   The permissions are checked at the lookup, not at the walk. An entry keeps
//   the leaf's U, R, X and W (W only with D: Svade, a store to a page not dirty
//   faults), and AF (the walk met an access fault: the table or the page outside
//   what can be addressed); the privilege of the access comes from registers of
//   the core (allow_u: U pages, U mode or S with SUM; allow_s: S pages, S mode;
//   mxr). So a change of privilege, SUM, MXR or MPRV needs no flush (as
//   mmRISC-2's MMU_PTW). A page fault the walk found (not valid, reserved, not
//   accessed, misaligned superpage, no leaf) is an entry with U, R, W, X at 0: it
//   faults at any privilege, as the walk would again (a TLB may keep a fault; an
//   OS fixes the entry with SFENCE.VMA after it). AF has R, W, X at 0 too.
//   The valid bits in flip-flops: a flush (SFENCE.VMA, a write of satp; no ASID)
//   takes one cycle, and nothing waits for it. A write in the cycle of a flush is
//   dropped: the walker that made it is aborted by the same flush.
//   A refill takes an invalid way of its set, else the ways in turn.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DTLB3
    #(
        parameter int SETS = 32,
        parameter int VA   = 39,
        parameter int PAW  = 40
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        input  logic                  tr_on,      // translation; else the address is physical
        input  logic                  allow_u,    // U pages may be accessed (U mode, or S with SUM)
        input  logic                  allow_s,    // S pages may be accessed (S mode)
        input  logic                  mxr,        // X pages may be read
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [PAW-1:12]       va,         // M: bits above VA are physical ones, with tr_on off
        /* verilator lint_on UNUSEDSIGNAL */
        output logic                  hit,        // M, all of it from a register
        output logic [PAW-1:12]       ptag,
        output logic                  r_ok,
        output logic                  w_ok,
        output logic                  af,         // no permission is an access fault (else a page fault)

        input  logic                  tlb_we,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [VA-1:12]        tlb_vpn,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [PAW-1:12]       tlb_ptag,
        input  logic                  tlb_u,
        input  logic                  tlb_r,
        input  logic                  tlb_w,      // W and D
        input  logic                  tlb_x,
        input  logic                  tlb_af,
        input  logic                  tlb_flush
    );

    localparam int IW = $clog2(SETS);
    localparam int TW = VA - 12 - IW;
    localparam int EW = 5 + TW + (PAW - 12);     // {u, r, w, x, af, tag, ptag}

    logic [IW-1:0] wa;
    logic [EW-1:0] wd;
    logic [1:0]    we;
    logic          turn;
    logic [1:0][SETS-1:0] vb;                    // the valid bits

    logic [EW-1:0] e [2];
    logic [1:0]    h;
    logic [1:0]    rk, wk;                       // each way's permissions for this access
    for (genvar w = 0; w < 2; w++) begin : g_way
        (* ram_style = "distributed" *) logic [EW-1:0] m [SETS];
        initial for (int i = 0; i < SETS; i++) m[i] = '0;
        always_ff @(posedge clk) if (we[w]) m[wa] <= wd;
        assign e[w] = m[va[12+IW-1:12]];
        assign h[w] = vb[w][va[12+IW-1:12]] && e[w][EW-6:PAW-12] == va[VA-1:12+IW];
        // the privilege: a U page from U (or S with SUM), an S page from S
        logic pv;
        assign pv    = e[w][EW-1] ? allow_u : allow_s;
        assign rk[w] = pv && (e[w][EW-2] || (mxr && e[w][EW-4]));
        assign wk[w] = pv && e[w][EW-3];
    end

    always @(*) begin
        hit  = !tr_on || h != 2'd0;
        ptag = !tr_on ? va : h[1] ? e[1][PAW-13:0] : e[0][PAW-13:0];
        r_ok = !tr_on || (h[1] ? rk[1] : rk[0]);
        w_ok = !tr_on || (h[1] ? wk[1] : wk[0]);
        af   = tr_on && (h[1] ? e[1][EW-5] : e[0][EW-5]);
        wa   = tlb_vpn[12+IW-1:12];
        wd   = {tlb_u, tlb_r, tlb_w, tlb_x, tlb_af, tlb_vpn[VA-1:12+IW], tlb_ptag};
        // an invalid way first, else the ways in turn
        we   = (!tlb_we || tlb_flush) ? 2'b00 :
               !vb[0][wa] ? 2'b01 : !vb[1][wa] ? 2'b10 : turn ? 2'b10 : 2'b01;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            turn <= 1'b0;
            vb   <= '0;
        end else begin
            if (we != 2'b00) turn <= !turn;
            if (tlb_flush) vb <= '0;
            else begin
                if (we[0]) vb[0][wa] <= 1'b1;
                if (we[1]) vb[1][wa] <= 1'b1;
            end
        end
    end

endmodule : OOO_DTLB3
