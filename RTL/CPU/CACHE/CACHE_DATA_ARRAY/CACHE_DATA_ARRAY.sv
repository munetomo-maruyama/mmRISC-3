//---------------------------------------------------------------------------
// CACHE_DATA_ARRAY.sv
//
// (mmRISC-3: taken from mmRISC-2 Rev.02, RTL/CPU/CACHE/README.md. One change,
// step 1.7c C3, Plan/OOC.md 29.70: WR_REG = 1 registers the write port -- the
// address, the data, the strobes and one enable a way -- so that each way's
// block RAMs are written from flip-flops, one route away; a write lands one
// cycle after wr_en. CPU_L2 at 512 KB takes it (its 128 tiles spread far);
// WR_REG = 0, the default, is the module as it was.)
//
// Data storage of a set-associative L1 cache.
//
//   - 64-bit words, one memory per way, byte write enables.
//   - Address = set * WORDS_PER_BLOCK + word offset inside the block.
//   - Synchronous read: rd_data is valid one cycle after rd_en. All ways are
//     read in parallel and returned as one packed vector.
//   - One array per way (generate), so that the memories are inferred as
//     block RAM on the FPGA. Reading and writing the same address in the same
//     cycle returns undefined data for the bytes that are written; the cache
//     forwards those bytes itself (fwd_* in DCACHE).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CACHE_DATA_ARRAY
    #(
        parameter int SETS        = 64,
        parameter int WAYS        = 4,
        parameter int BLOCK_BYTES = 64,
        parameter bit WR_REG      = 1'b0,   // 1: the write port registered
        // derived; do not override
        parameter int ADDR_BITS   = $clog2(SETS * BLOCK_BYTES / 8),
        parameter int WAY_BITS    = (WAYS > 1) ? $clog2(WAYS) : 1
    )
    (
        input  logic                     clk,

        input  logic                     rd_en,
        input  logic [ADDR_BITS-1:0]     rd_addr,
        output logic [WAYS*64-1:0]       rd_data,

        input  logic                     wr_en,
        input  logic [WAY_BITS-1:0]  wr_way,
        input  logic [ADDR_BITS-1:0]     wr_addr,
        input  logic [63:0]              wr_data,
        input  logic [7:0]               wr_strb
    );

    localparam int WORDS_PER_BLOCK = BLOCK_BYTES / 8;
    localparam int WORDS           = SETS * WORDS_PER_BLOCK;

    //-----------------------------------------------------------------
    // One memory per way, written through a decoded way enable.
    //
    // This is the shape Vivado needs to infer block RAM: a single array
    // indexed only by the word address, one write port with byte enables
    // and one read port. Using the way as a variable index of a two
    // dimensional array instead is NOT recognised by Vivado, and the
    // arrays end up in flip flops - 2 x 4 x 512 x 64 bit does not fit into
    // an Artix-7 100T (the 2026-09-20 build failed with DRC UTLZ-1).
    //-----------------------------------------------------------------
    // the write port as the arrays see it: as it comes (WR_REG = 0), or a
    // cycle later from flip-flops (WR_REG = 1), each way with its own enable
    logic [WAYS-1:0]      w_en;
    logic [ADDR_BITS-1:0] w_addr;
    logic [63:0]          w_data;
    logic [7:0]           w_strb;
    generate
        if (WR_REG) begin : g_wreg
            initial begin
                w_en = '0; w_addr = '0; w_data = '0; w_strb = '0;
            end
            always_ff @(posedge clk) begin
                for (int w = 0; w < WAYS; w++)
                    w_en[w] <= wr_en && (int'(wr_way) == w);
                w_addr <= wr_addr;
                w_data <= wr_data;
                w_strb <= wr_strb;
            end
        end else begin : g_wdir
            always_comb
                for (int w = 0; w < WAYS; w++)
                    w_en[w] = wr_en && (int'(wr_way) == w);
            assign w_addr = wr_addr;
            assign w_data = wr_data;
            assign w_strb = wr_strb;
        end
    endgenerate

    genvar gw;
    generate
        for (gw = 0; gw < WAYS; gw++) begin : g_way
            (* ram_style = "block" *)
            logic [63:0] mem [0:WORDS-1];
            logic [63:0] rd_w;                  // output register of this way

            initial begin
                rd_w = 64'd0;
                for (int i = 0; i < WORDS; i++) mem[i] = 64'd0;
            end

            // write port : byte enables, one way selected
            always_ff @(posedge clk) begin
                if (w_en[gw])
                    for (int b = 0; b < 8; b++)
                        if (w_strb[b]) mem[w_addr][8*b +: 8] <= w_data[8*b +: 8];
            end

            // read port
            always_ff @(posedge clk) begin
                if (rd_en) rd_w <= mem[rd_addr];
            end

            assign rd_data[gw*64 +: 64] = rd_w;
        end
    endgenerate

endmodule : CACHE_DATA_ARRAY
