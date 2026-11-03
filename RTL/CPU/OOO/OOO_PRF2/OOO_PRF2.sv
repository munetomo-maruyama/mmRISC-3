//---------------------------------------------------------------------------
// OOO_PRF2.sv
//
// The integer physical register file at 100 MHz (Doc/STRATEGY.md 4.2, 4.3): as
// OOO_PRF, one bank of distributed RAM per write port, each read by every read
// port, and a live value table (LVT), but read in 2 stages (Plan/OOC.md 28.6):
//
//   RR1  ra1: the LVT says which bank, into a register with the address
//   RR2  rd:  the banks read at that address, the one the LVT named
//
// So rd gives the value with all writes up to the end of RR1; a write at the
// end of RR2 is not seen (OOO_EXU takes it from the result it is written from).
// A write in RR1 is seen by comparing, as the LVT itself changes only at the
// end of RR1.
//
// A bank is 64 + NH registers: 80 in a single memory would be 2 cells of 64 per
// bit, where 16 take a cell of 32, smaller by a quarter (Plan/OOC.md 28.7). So
// 64 < NREG <= 96, and NH a power of 2.
//
// The write's address and enable come a cycle ahead, and every read port's copy
// of the banks, and the LVT, has its own register of them, near what it drives:
// about 1,000 RAM cells per address bit took 9 ns of route from one (Plan/OOC.md
// 28.8). The data comes with the write.
//
// Register 0 is not special here: it is never written, and whoever reads x0
// does not use the read (OOO_EXU's rr_use). Two ports never write one register
// in the same cycle (renaming gives every destination its own register).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_PRF2
    #(
        parameter int NREG = 80,
        parameter int NW   = 4,
        parameter int NR   = 8
    )
    (
        input  logic                           clk,

        input  logic [NR-1:0][$clog2(NREG)-1:0] ra1,
        output logic [NR-1:0][63:0]             rd,

        input  logic [NW-1:0]                   we_n,  // a cycle before wd
        input  logic [NW-1:0][$clog2(NREG)-1:0] wa_n,
        input  logic [NW-1:0][63:0]             wd
    );

    localparam int LW = (NW > 1) ? $clog2(NW) : 1;
    localparam int AW = $clog2(NREG);
    localparam int NH = NREG - 64;
    localparam int HW = $clog2(NH);

    (* keep = "true" *) logic [NW-1:0] we [NR+1];
    (* keep = "true" *) logic [AW-1:0] wa [NR+1][NW];
    always_ff @(posedge clk) begin
        for (int r = 0; r <= NR; r++) begin
            we[r] <= we_n;
            for (int w = 0; w < NW; w++) wa[r][w] <= wa_n[w];
        end
    end

    logic [LW-1:0] lvt [NREG];
    logic [LW-1:0] lvn [NR];
    (* max_fanout = 16 *) logic [LW-1:0] lq [NR];
    (* max_fanout = 32 *) logic [AW-1:0] aq [NR];
    logic [63:0]   rb  [NR][NW];

    always @(*) begin
        for (int r = 0; r < NR; r++) begin
            lvn[r] = lvt[ra1[r]];
            for (int w = 0; w < NW; w++)
                if (we[NR][w] && wa[NR][w] == ra1[r]) lvn[r] = LW'(w);
        end
    end
    always_ff @(posedge clk) begin
        for (int w = 0; w < NW; w++)
            if (we[NR][w]) lvt[wa[NR][w]] <= LW'(w);
        for (int r = 0; r < NR; r++) begin
            lq[r] <= lvn[r];
            aq[r] <= ra1[r];
        end
    end

    for (genvar w = 0; w < NW; w++) begin : g_bank
        for (genvar r = 0; r < NR; r++) begin : g_rd
            (* ram_style = "distributed" *) logic [63:0] mem_l [64];
            (* ram_style = "distributed" *) logic [63:0] mem_h [NH];
            always_ff @(posedge clk) begin
                if (we[r][w] && !wa[r][w][AW-1]) mem_l[wa[r][w][5:0]] <= wd[w];
                if (we[r][w] &&  wa[r][w][AW-1]) mem_h[wa[r][w][HW-1:0]] <= wd[w];
            end
            assign rb[r][w] = aq[r][AW-1] ? mem_h[aq[r][HW-1:0]] : mem_l[aq[r][5:0]];
        end
    end

    for (genvar r = 0; r < NR; r++) begin : g_out
        assign rd[r] = rb[r][lq[r]];
    end

endmodule : OOO_PRF2
