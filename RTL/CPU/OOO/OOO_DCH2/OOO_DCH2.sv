//---------------------------------------------------------------------------
// OOO_DCH2.sv
//
// The arrays of the D$'s hit path with 2 load ports (Doc/STRATEGY.md 4.5 loop 3, Plan/OOC.md
// 29.7): OOO_DCH with a copy of the data and of the tags for each load port. A block RAM
// has 2 ports, and 2 loads and a write would need 3: with a copy each, a read has its
// own memory and a write goes to all, so loads, a store that drains and a fill never
// wait for each other. There are 365 tiles on this device, for 18 here at 64 sets (with the
// victim's copy), 54 at 256 (the D$ of 64 KB in OOO_LSU4, step 1.7c C2, Plan/OOC.md 29.68: each
// copy of a way 2,048 words, 4 RAMB36 as 2K x 18 side by side; the tags still one RAMB18 each).
//
//   data  2 copies, one memory per way of 64-bit words, byte write enables (a simple
//         dual port RAMB36, 512 x 72)
//   tags  {valid, tag} per set and way, 3 copies: 2 for loads, 1 for the stores that drain
//   VR=1  a 3rd copy of the data (written as the others), read by OOO_DMISS2 for a dirty
//         victim's words and FENCE.I's write out (vr_*: the word of vr_way, a cycle later;
//         the D$ written back, step 1.7b W1, Plan/OOC.md 29.61). 4 tiles more
//
// A read in the cycle of a write to the same place returns the old value, as in OOO_DCH.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DCH2
    #(
        parameter int SETS  = 64,
        parameter int WAYS  = 4,
        parameter int WORDS = 8,       // 64-bit words in a line
        parameter int TW    = 28,
        parameter bit VR    = 1'b0     // the victim's copy
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
        input  logic [7:0]                            dw_strb,

        // the victim's copy (VR): a word of a way
        /* verilator lint_off UNUSEDSIGNAL */      // (VR=0: not read)
        input  logic [$clog2(SETS*WORDS)-1:0]         vr_addr,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [$clog2(WAYS)-1:0]               vr_way,
        output logic [63:0]                           vr_data
    );

    localparam int WB = $clog2(WORDS);
    logic [WAYS-1:0][63:0]     vr_w;
    logic [$clog2(WAYS)-1:0]   vr_wq;

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
        if (VR) begin : g_vr
            (* ram_style = "block" *) logic [63:0] vm [SETS*WORDS];
            logic [63:0] vq;
            initial begin
                vq = '0;
                for (int i = 0; i < SETS*WORDS; i++) vm[i] = '0;
            end
            always_ff @(posedge clk) begin
                for (int b = 0; b < 8; b++)
                    if (dw_en && int'(dw_way) == w && dw_strb[b])
                        vm[dw_addr][8*b +: 8] <= dw_data[8*b +: 8];
                vq <= vm[vr_addr];
            end
            assign vr_w[w] = vq;
        end else begin : g_novr
            assign vr_w[w] = '0;
        end
    end
    always_ff @(posedge clk) vr_wq <= vr_way;
    assign vr_data = vr_w[vr_wq];

endmodule : OOO_DCH2
