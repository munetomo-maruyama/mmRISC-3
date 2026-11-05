//---------------------------------------------------------------------------
// OOO_BUSY.sv
//
// Which physical registers wait for their value, for the 4-wide core at 50 MHz
// (Doc/STRATEGY.md 4.5 loop 6, Plan/OOC.md 29.13). OOO_RENAME2 has no busy bits: it was made
// for OOO_SDISP, which compares a source with what is pending. OOO_IQ2 asks for each source
// whether it is ready at dispatch (disp_rdy).
//
//   set    a new register, at the edge its µop goes from R to the DS register (r1_*)
//   clear  a wakeup tag (OOO_IQ2's wk_*); a set wins, a tag cannot be meant for a register
//          just given out
//   read   by the sources in the DS register, in the cycle they dispatch, from the bits. So
//          the DS register needs no snoop: a wakeup of this very cycle is OOO_IQ2's
//          (disp_rdy || woken), and those before are in the bits. A source on a µop older in
//          its group is busy already, as all of a group is set at one edge.
//
// A recovery does nothing here. What is restored maps to registers whose bits are right; a
// killed µop's register keeps its bit until it is given out again, when it is set anyway.
// Register 0 is never set.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_BUSY
    #(
        parameter int NREG = 80,
        parameter int TAGW = 7,
        parameter int NWK  = 9
    )
    (
        input  logic                      clk,
        input  logic                      rst_n,

        // ---- from OOO_RENAME2
        input  logic [3:0]                set_v,
        input  logic [3:0][TAGW-1:0]      set_t,

        // ---- OOO_IQ2's wakeup tags
        input  logic [NWK-1:0]            wk_valid,
        input  logic [NWK-1:0][TAGW-1:0]  wk_tag,

        // ---- the DS register's sources
        input  logic [3:0][1:0][TAGW-1:0] rd_t,
        output logic [3:0][1:0]           rd_rdy
    );

    logic [NREG-1:0] busy;

    // a tag's line in 2 steps, shared among the registers
    function automatic logic [NREG-1:0] line(input logic v, input logic [TAGW-1:0] t);
        logic [NREG-1:0] l;
        l = '0;
        if (v && int'(t) < NREG) l[t] = 1'b1;
        return l;
    endfunction

    logic [NREG-1:0] clr, set;
    always @(*) begin
        clr = '0;
        for (int b = 0; b < NWK; b++) clr = clr | line(wk_valid[b], wk_tag[b]);
        set = '0;
        for (int k = 0; k < 4; k++) set = set | line(set_v[k], set_t[k]);
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) busy <= '0;
        else        busy <= set | (busy & ~clr);
    end

    always @(*) begin
        for (int k = 0; k < 4; k++)
            for (int s = 0; s < 2; s++) rd_rdy[k][s] = int'(rd_t[k][s]) >= NREG || !busy[rd_t[k][s]];
    end

endmodule : OOO_BUSY
