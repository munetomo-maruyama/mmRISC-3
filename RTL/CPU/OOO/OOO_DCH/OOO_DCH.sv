//---------------------------------------------------------------------------
// OOO_DCH.sv
//
// The arrays of the D$'s hit path at 100 MHz (Doc/STRATEGY.md 4.3, 4.5 loop 3,
// Plan/OOC.md 28.13): all block RAM, read at the end of a stage, the data in the
// next one, with no logic in the block.
//
//   data  one memory per way of 64-bit words, byte write enables (a simple dual
//         port RAMB36, 512 x 72)
//   tags  {valid, tag} per set and way, twice: one copy for loads, one for the
//         stores that drain, so that neither waits for the other
//
// A read in the cycle of a write to the same place returns the old value.
// OOO_LSU2 counts on that: a store is still in the SQ then, and a line is made
// invalid before its data is overwritten.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DCH
    #(
        parameter int SETS  = 64,
        parameter int WAYS  = 4,
        parameter int WORDS = 8,       // 64-bit words in a line
        parameter int TW    = 28
    )
    (
        input  logic                                  clk,

        // loads: the word's address at the end of E
        input  logic [$clog2(SETS*WORDS)-1:0]         rd_addr,
        output logic [WAYS-1:0][63:0]                 rd_data,
        output logic [WAYS-1:0][TW:0]                 rd_tag,

        // the store being drained: the set
        input  logic [$clog2(SETS)-1:0]               sb_set,
        output logic [WAYS-1:0][TW:0]                 sb_tag,

        // writes: a line's tag
        input  logic                                  tw_en,
        input  logic [$clog2(WAYS)-1:0]               tw_way,
        input  logic [$clog2(SETS)-1:0]               tw_set,
        input  logic [TW:0]                           tw_tag,

        // writes: a word
        input  logic                                  dw_en,
        input  logic [$clog2(WAYS)-1:0]               dw_way,
        input  logic [$clog2(SETS*WORDS)-1:0]         dw_addr,
        input  logic [63:0]                           dw_data,
        input  logic [7:0]                            dw_strb
    );

    localparam int WB = $clog2(WORDS);

    for (genvar w = 0; w < WAYS; w++) begin : g_way
        (* ram_style = "block" *) logic [63:0] mem [SETS*WORDS];
        (* ram_style = "block" *) logic [TW:0] tla [SETS];
        (* ram_style = "block" *) logic [TW:0] tlb [SETS];
        logic [63:0] dq;
        logic [TW:0] lq, sq;
        initial begin
            dq = '0; lq = '0; sq = '0;
            for (int i = 0; i < SETS*WORDS; i++) mem[i] = '0;
            for (int i = 0; i < SETS; i++) begin tla[i] = '0; tlb[i] = '0; end
        end
        always_ff @(posedge clk) begin
            for (int b = 0; b < 8; b++)
                if (dw_en && int'(dw_way) == w && dw_strb[b])
                    mem[dw_addr][8*b +: 8] <= dw_data[8*b +: 8];
            dq <= mem[rd_addr];
        end
        always_ff @(posedge clk) begin
            if (tw_en && int'(tw_way) == w) tla[tw_set] <= tw_tag;
            lq <= tla[rd_addr[$clog2(SETS*WORDS)-1:WB]];
        end
        always_ff @(posedge clk) begin
            if (tw_en && int'(tw_way) == w) tlb[tw_set] <= tw_tag;
            sq <= tlb[sb_set];
        end
        assign rd_data[w] = dq;
        assign rd_tag[w]  = lq;
        assign sb_tag[w]  = sq;
    end

endmodule : OOO_DCH
