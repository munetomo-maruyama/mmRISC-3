//---------------------------------------------------------------------------
// OOO_IQPL2.sv
//
// The payload of OOO_IQ2 (Plan/OOC.md 29.19): what a µop needs in RR and EX
// besides its tags (operation, immediate, ROB / LQ / SQ index, ...), one
// record of W bits per entry of the queue, as OOO_IQPL for OOO_IQ.
//
//   DS  up to 4 records written, to the entries the queue gives the
//       dispatched µops (OOO_IQ2 disp_entry)
//   IS  the queue's grants name up to NR entries (iss_entry)
//   RR  their records, read through registered addresses
//
// OOO_IQ2 keeps its entries in NBANK banks of N / NBANK, and gives a cycle's
// µops entries of different banks. So bank b here is a LUT RAM written by
// the one µop that goes to bank b (each memory has one write port: all
// Vivado maps to LUT RAM, Plan/OOC.md 12.6), and no live value table is
// needed: an entry is only ever written in its own bank. The bank's address and data are
// chosen by wr_cand (early: the slots that go if any do), its write by wr_valid (the go,
// late; Plan/OOC.md 29.41). A bank is
// addressed by the whole entry number (N <= 32: one RAM32M deep), so a read
// takes the 4 banks at its entry and chooses by the entry's bank.
//
// The last NRL read ports (the LSU's) need about half of a record (ROB /
// LQ / SQ index, offset, size, sign): the record keeps those fields in its
// low W2 bits, and those ports read only them; their upper bits are 0, so
// synthesis drops that part of their reads.
//
// A record is read in the cycle after the grant. An entry is not given out
// again in the cycle it is freed (OOO_IQ2), so the earliest write of a new
// µop to it comes in the cycle of that read, and the LUT RAM still answers
// the old record then. A µop kept in the queue after its issue (selective
// replay) keeps its entry, so its record is still there when it issues
// again.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_IQPL2
    #(
        parameter int N     = 24,       // entries of OOO_IQ2
        parameter int NBANK = 4,        // its banks (N a multiple of it)
        parameter int W     = 96,       // bits of a record
        parameter int NR    = 3,        // read ports
        parameter int NRL   = 0,        // the last of them read only the low W2 bits
        parameter int W2    = 48
    )
    (
        input  logic                          clk,
        // DS: the dispatch slots (OOO_IQ2's disp_valid and disp_entry)
        input  logic [NBANK-1:0]              wr_valid,
        input  logic [NBANK-1:0]              wr_cand,    // wr_valid is these or none; their entries in different banks
        input  logic [NBANK-1:0][$clog2(N)-1:0] wr_entry,
        input  logic [NBANK-1:0][W-1:0]       wr_data,
        // IS: the entries granted now
        input  logic [NR-1:0][$clog2(N)-1:0]  iss_entry,
        // RR: their records
        output logic [NR-1:0][W-1:0]          rr_data
    );

    localparam int EW = $clog2(N);
    localparam int BS = N / NBANK;      // entries in a bank
    localparam int BW = NBANK > 1 ? $clog2(NBANK) : 1;

    function automatic logic [BW-1:0] bank_of(input logic [EW-1:0] e);
        logic [BW-1:0] b;
        b = '0;
        for (int k = 1; k < NBANK; k++) if (e >= EW'(k * BS)) b = BW'(k);
        return b;
    endfunction

    // the write of each bank: the slot whose entry is in it (at most one)
    logic [NBANK-1:0]          bw;
    logic [NBANK-1:0][EW-1:0]  ba;
    logic [NBANK-1:0][W-1:0]   bd;
    always @(*) begin
        for (int b = 0; b < NBANK; b++) begin
            bw[b] = 1'b0; ba[b] = '0; bd[b] = '0;
            for (int k = 0; k < NBANK; k++)
                if (wr_cand[k] && bank_of(wr_entry[k]) == BW'(b)) begin
                    bw[b] = wr_valid[k]; ba[b] = wr_entry[k]; bd[b] = wr_data[k];
                end
        end
    end

    logic [NR-1:0][EW-1:0] ra;          // the read addresses, registered at IS
    always_ff @(posedge clk) ra <= iss_entry;

    for (genvar b = 0; b < NBANK; b++) begin : g_bank
        (* ram_style = "distributed" *) logic [W-1:0] mem [N];
        always_ff @(posedge clk) if (bw[b]) mem[ba[b]] <= bd[b];
    end

    logic [NR-1:0][NBANK-1:0][W-1:0] rb;       // each bank at each read address
    for (genvar b = 0; b < NBANK; b++) begin : g_rd
        for (genvar p = 0; p < NR; p++) begin : g_p
            assign rb[p][b] = g_bank[b].mem[ra[p]];
        end
    end

    always @(*) begin
        for (int p = 0; p < NR; p++) begin
            rr_data[p] = rb[p][bank_of(ra[p])];
            if (p >= NR - NRL) rr_data[p][W-1:W2] = '0;
        end
    end

endmodule : OOO_IQPL2
