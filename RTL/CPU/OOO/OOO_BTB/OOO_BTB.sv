//---------------------------------------------------------------------------
// OOO_BTB.sv
//
// The branch target buffer of mmRISC-3 (Doc/UARCH.md 3.2), for indirect
// jumps only: the targets of conditional branches and jal come from
// predecode (OOO_PREDEC computes them from the instruction bits in F2), and
// returns from the RAS. What is left are jalr / c.jr / c.jalr that are not
// returns (jump tables, calls through pointers).
//
// In block RAM, read with the fetch address like the I$: the line address
// indexes 2^NLOG rows, each holding one indirect jump of that line: a tag
// (the next TW bits of the line address), its parcel (of its last half)
// and its last target. Read at F0 (rd_en, the fetch accepted), compared in
// F1 and held for F2 until the next read, as TAGE's results are. Written at
// resolution with the jump's address (its last parcel) and target.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_BTB
    #(
        parameter int VA   = 39,
        parameter int NLOG = 8,
        parameter int TW   = 10
    )
    (
        input  logic                clk,
        input  logic                rst_n,

        input  logic                rd_en,      // F0
        input  logic [VA-1:1]       rd_pc,
        output logic                hit,        // F2: for the block read last
        output logic [2:0]          off,
        output logic [VA-1:1]       tgt,

        input  logic                wr_valid,
        input  logic [VA-1:1]       wr_pc,
        input  logic [VA-1:1]       wr_tgt
    );

    localparam int RW = 1 + TW + 3 + (VA - 1);
    localparam int NR = 1 << NLOG;

    (* ram_style = "block" *) logic [RW-1:0] mem [NR];
    initial for (int r = 0; r < NR; r++) mem[r] = '0;

    // (the parcel bits and the line bits above the tag are not used)
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [NLOG-1:0] idx_of(input logic [VA-1:1] a);
        return a[4 +: NLOG];
    endfunction
    function automatic logic [TW-1:0] tag_of(input logic [VA-1:1] a);
        return a[4 + NLOG +: TW];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge clk) if (wr_valid) mem[idx_of(wr_pc)] <= {1'b1, tag_of(wr_pc), wr_pc[3:1], wr_tgt};

    logic [RW-1:0] rd;
    logic [TW-1:0] tag1;
    logic          v1;
    always_ff @(posedge clk) if (rd_en) begin
        rd   <= mem[idx_of(rd_pc)];
        tag1 <= tag_of(rd_pc);
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) v1 <= 1'b0;
        else        v1 <= rd_en;
    end

    // F1: the compare, held for F2
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) hit <= 1'b0;
        else if (v1) hit <= rd[RW-1] && rd[RW-2 -: TW] == tag1;
    end
    always_ff @(posedge clk) if (v1) begin
        off <= rd[VA-1 +: 3];
        tgt <= rd[VA-2:0];
    end

endmodule : OOO_BTB
