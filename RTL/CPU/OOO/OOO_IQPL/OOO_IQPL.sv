//---------------------------------------------------------------------------
// OOO_IQPL.sv
//
// The payload of the issue queue of mmRISC-3 (Doc/UARCH.md 3.6): what a µop
// needs in RR and EX besides its tags (operation, immediate, ROB / LQ / SQ
// index, ...), one record of W bits per entry of OOO_IQ. The issue queue
// itself only keeps what the select and the wakeup look at.
//
//   DS  up to 2 records written, to the entries the queue gives the two
//       dispatched µops (OOO_IQ disp_entry; never the same entry)
//   IS  the queue's grants name up to 3 entries (OOO_IQ iss_entry)
//   RR  their records, read through registered addresses
//
// LUTRAM with 2 writes and 3 reads, built of memories with one write port
// each (all Vivado can map to LUTRAM, Plan/OOC.md 12.6): bank 0 is written
// by dispatch slot 0 only, bank 1 by slot 1 only, and a live value table
// (one flip-flop per entry) says which bank wrote the entry last. A read
// takes both banks at its entry and chooses by that bit. Each bank has one
// write and three reads (RAM32M-shaped).
//
// Port 2 (the LSU) needs about half of a record (ROB / LQ / SQ index,
// offset, size, sign, the second half of a fused pair): the record keeps
// those fields in its low W2 bits, and port 2 reads only them (G0b G3,
// Doc/UARCH.md 6.3); its upper bits are 0, so synthesis drops that read
// port and its bank choice for them.
//
// A record is read in the cycle after the grant. An entry is not given out
// again in the cycle it is freed (OOO_IQ), so the earliest write of a new
// µop to it comes in the cycle of that read, and the LUTRAM still answers
// the old record then (the write takes effect at the clock edge). A µop
// kept in the queue after its issue (selective replay, OOO_IQ) keeps its
// entry, so its record is still there when it issues again.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_IQPL
    #(
        parameter int N = 10,           // entries of OOO_IQ
        parameter int W  = 96,          // bits of a record (Plan/OOC.md 17.1)
        parameter int W2 = 48           // the low bits port 2 reads
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,
        // DS
        input  logic [1:0]                  wr_valid,
        input  logic [1:0][$clog2(N)-1:0]   wr_entry,
        input  logic [1:0][W-1:0]           wr_data,
        // IS: the entries granted now
        input  logic [2:0][$clog2(N)-1:0]   iss_entry,
        // RR: their records
        output logic [2:0][W-1:0]           rr_data
    );

    localparam int EW = $clog2(N);

    (* ram_style = "distributed" *) logic [W-1:0] bank0 [N];
    (* ram_style = "distributed" *) logic [W-1:0] bank1 [N];
    logic [N-1:0] lvt;                  // 1: bank 1 has the entry's last record

    always_ff @(posedge clk) if (wr_valid[0]) bank0[wr_entry[0]] <= wr_data[0];
    always_ff @(posedge clk) if (wr_valid[1]) bank1[wr_entry[1]] <= wr_data[1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lvt <= '0;
        end else begin
            if (wr_valid[0]) lvt[wr_entry[0]] <= 1'b0;
            if (wr_valid[1]) lvt[wr_entry[1]] <= 1'b1;
        end
    end

    logic [2:0][EW-1:0] ra;             // the read addresses, registered at IS
    always_ff @(posedge clk) ra <= iss_entry;

    always @(*) begin
        for (int p = 0; p < 2; p++)
            rr_data[p] = lvt[ra[p]] ? bank1[ra[p]] : bank0[ra[p]];
        rr_data[2] = '0;
        rr_data[2][W2-1:0] = lvt[ra[2]] ? bank1[ra[2]][W2-1:0] : bank0[ra[2]][W2-1:0];
    end

endmodule
