//---------------------------------------------------------------------------
// OOO_DCH2.sv
//
// The arrays of the D$'s hit path with 2 load ports (Doc/STRATEGY.md 4.5 loop 3, Plan/OOC.md
// 29.7): OOO_DCH with a copy of the data and of the tags for each load port. A block RAM
// has 2 ports, and 2 loads and a write would need 3: with a copy each, a read has its
// own memory and a write goes to all, so loads, a store that drains and a fill never
// wait for each other. There are 365 tiles on this device, for 14 here.
//
//   data  2 copies, one memory per way of 64-bit words, byte write enables (a simple
//         dual port RAMB36, 512 x 72)
//   tags  {valid, tag} per set and way, 3 copies: 2 for loads, 1 for the stores that drain
//
// A read in the cycle of a write to the same place returns the old value, as in OOO_DCH.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DCH2
    #(
        parameter int SETS  = 64,
        parameter int WAYS  = 4,
        parameter int WORDS = 8,       // 64-bit words in a line
        parameter int TW    = 28
    )
    (
        input  logic                                  clk,

        // loads: the word's address at the end of E
        input  logic [1:0][$clog2(SETS*WORDS)-1:0]    rd_addr,
        output logic [1:0][WAYS-1:0][63:0]            rd_data,
        output logic [1:0][WAYS-1:0][TW:0]            rd_tag,

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
        for (genvar p = 0; p < 2; p++) begin : g_rd
            (* ram_style = "block" *) logic [63:0] mem [SETS*WORDS];
            (* ram_style = "block" *) logic [TW:0] tl  [SETS];
            logic [63:0] dq;
            logic [TW:0] lq;
            initial begin
                dq = '0; lq = '0;
                for (int i = 0; i < SETS*WORDS; i++) mem[i] = '0;
                for (int i = 0; i < SETS; i++) tl[i] = '0;
            end
            always_ff @(posedge clk) begin
                for (int b = 0; b < 8; b++)
                    if (dw_en && int'(dw_way) == w && dw_strb[b])
                        mem[dw_addr][8*b +: 8] <= dw_data[8*b +: 8];
                dq <= mem[rd_addr[p]];
            end
            always_ff @(posedge clk) begin
                if (tw_en && int'(tw_way) == w) tl[tw_set] <= tw_tag;
                lq <= tl[rd_addr[p][$clog2(SETS*WORDS)-1:WB]];
            end
            assign rd_data[p][w] = dq;
            assign rd_tag[p][w]  = lq;
        end
        (* ram_style = "block" *) logic [TW:0] tlb [SETS];
        logic [TW:0] sq;
        initial begin
            sq = '0;
            for (int i = 0; i < SETS; i++) tlb[i] = '0;
        end
        always_ff @(posedge clk) begin
            if (tw_en && int'(tw_way) == w) tlb[tw_set] <= tw_tag;
            sq <= tlb[sb_set];
        end
        assign sb_tag[w] = sq;
    end

endmodule : OOO_DCH2
