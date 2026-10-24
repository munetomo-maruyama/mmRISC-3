//---------------------------------------------------------------------------
// OOO_PRF.sv
//
// The integer physical register file of mmRISC-3: NREG x 64 bits, NW write
// ports, NR read ports (STRATEGY.md 4: 96 registers; Plan/OOC.md measures
// what the ports cost).
//
//   - One bank of distributed RAM per write port, each read by every read
//     port, and a live value table (LVT) that says which bank holds the
//     newest value of each register: the technique of mmRISC-2's CORE_RF,
//     with more ports. The synthesis tool replicates a bank for its read
//     ports (a RAM64M gives three reads beside the write).
//   - Physical register 0 is x0: it reads as zero and is never written.
//   - Reads are asynchronous; a read of a register written in the same cycle
//     gives the old value (the bypass network forwards the new one).
//   - Two ports never write one register in the same cycle (renaming gives
//     every destination its own register).
//
// Ports in the fusion configuration: reads 3 + 3 (two ALU ports, a fused
// pair has 3 sources) + 2 or 3 (LSU, a store pair has 3) = 8 or 9; writes
// 2 + 2 (a fused pair writes up to 2) + 1 or 2 (a load pair) = 5 or 6,
// or 3 when fused pairs write one register (Plan/MODEL.md: -4 % / -9 %).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_PRF
    #(
        parameter int NREG = 96,
        parameter int NW   = 5,
        parameter int NR   = 8
    )
    (
        input  logic                           clk,

        input  logic [NR-1:0][$clog2(NREG)-1:0] ra,
        output logic [NR-1:0][63:0]             rd,

        input  logic [NW-1:0]                   we,
        input  logic [NW-1:0][$clog2(NREG)-1:0] wa,
        input  logic [NW-1:0][63:0]             wd
    );

    localparam int LW = (NW > 1) ? $clog2(NW) : 1;

    logic [LW-1:0] lvt [NREG];
    logic [63:0]   rb  [NR][NW];     // what bank w holds at read address r

    // one bank per write port, each its own array with one write port, so
    // that it maps to distributed RAM (read by every read port). The
    // attribute keeps it out of block RAM, which the tools would otherwise
    // pick when the read address is registered (block RAM is kept for the
    // predictors and the caches: Plan/ISSUES.md 2)
    for (genvar w = 0; w < NW; w++) begin : g_bank
        (* ram_style = "distributed" *) logic [63:0] mem [NREG];
        always_ff @(posedge clk) begin
            if (we[w] && wa[w] != '0) mem[wa[w]] <= wd[w];
        end
        for (genvar r = 0; r < NR; r++) begin : g_rd
            assign rb[r][w] = mem[ra[r]];
        end
    end

    always_ff @(posedge clk) begin
        for (int w = 0; w < NW; w++)
            if (we[w] && wa[w] != '0) lvt[wa[w]] <= LW'(w);
    end

    // the bank the LVT names
    for (genvar r = 0; r < NR; r++) begin : g_out
        assign rd[r] = (ra[r] == '0) ? 64'd0 : rb[r][lvt[ra[r]]];
    end

endmodule : OOO_PRF
