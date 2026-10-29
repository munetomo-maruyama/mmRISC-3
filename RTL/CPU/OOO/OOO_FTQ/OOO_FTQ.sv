//---------------------------------------------------------------------------
// OOO_FTQ.sv
//
// The fetch target queue of mmRISC-3 (Doc/UARCH.md 3.2): one entry per
// fetch block, from F2 until the block's last instruction commits.
//
//   pc      the block's fetch address (the instructions' pc is this with
//           their parcel offset, from the fetch buffer)
//   target  the predicted next fetch address
//   taken / end   the block ends with a predicted-taken transfer at that
//           parcel
//   meta    what the predictors need back at resolution (TAGE's provider
//           and tags, the history; MW bits, opaque here)
//
// In LUTRAM: one write a cycle (the push at F2) and four reads (two for
// decode, whose window spans up to two blocks, one for the restore after a
// misprediction or a trap, OOO_FERS, and the head's metadata for the TAGE
// update at its pop, Plan/CORE.md 5.2). Entries are freed in order (pop,
// from commit). A misprediction keeps the branch's block and drops the
// younger ones (restore); flush_all empties the queue. free_n (blocks it
// can take) is from the pointers alone, for fetch's credit.
//
// 16 entries (D-18, Plan/OOC.md 26.8): a block waits in it through the
// fetch buffer, D1, D2 and the ROB; with 8 the queue was full most of the
// time and stopped fetch. The LUTRAM is the same at any depth up to 32.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FTQ
    #(
        parameter int NFTQ = 16,        // a power of two (D-18: 16)
        parameter int FTQW = 4,
        parameter int VA   = 39,
        parameter int MW   = 32
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        output logic                        push_ready,
        input  logic                        push_valid,
        input  logic [VA-1:1]               push_pc,
        input  logic [VA-1:1]               push_target,
        input  logic                        push_taken,
        input  logic [2:0]                  push_end,
        input  logic [MW-1:0]               push_meta,
        output logic [FTQW-1:0]             push_idx,

        input  logic [1:0][FTQW-1:0]        rd_idx,     // decode
        output logic [1:0][VA-1:1]          rd_pc,

        input  logic [FTQW-1:0]             br_idx,     // branch resolution
        output logic [VA-1:1]               br_pc,
        output logic [VA-1:1]               br_target,
        output logic                        br_taken,
        output logic [2:0]                  br_end,
        output logic [MW-1:0]               br_meta,

        output logic [FTQW-1:0]             hd_idx,     // the head (the next block to pop)
        output logic [MW-1:0]               hd_meta,
        output logic [FTQW:0]               free_n,

        input  logic [1:0]                  pop,        // blocks done (committed)
        input  logic                        restore,    // keep up to restore_idx, drop the rest
        input  logic [FTQW-1:0]             restore_idx,
        input  logic                        flush_all
    );

    localparam int EW = 2 * (VA - 1) + 1 + 3 + MW;
    typedef logic [EW-1:0] ent_t;
    (* ram_style = "distributed" *) ent_t mem [NFTQ];

    logic [FTQW:0] head, tail;                 // with a wrap bit
    logic [FTQW:0] used;
    assign used       = tail - head;
    assign push_ready = used != (FTQW + 1)'(NFTQ);
    assign push_idx   = tail[FTQW-1:0];
    assign hd_idx     = head[FTQW-1:0];
    assign free_n     = (FTQW + 1)'(NFTQ) - used;

    logic push;
    assign push = push_valid && push_ready;    // (during restore / flush_all into a slot left free: harmless)

    always_ff @(posedge clk) if (push) mem[tail[FTQW-1:0]] <= {push_pc, push_target, push_taken, push_end, push_meta};

    always @(*) begin
        ent_t e;
        for (int r = 0; r < 2; r++) begin
            e = mem[rd_idx[r]];
            rd_pc[r] = e[EW-1 -: VA-1];
        end
        e = mem[br_idx];
        {br_pc, br_target, br_taken, br_end, br_meta} = e;
        e = mem[head[FTQW-1:0]];
        hd_meta = e[MW-1:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= '0;
            tail <= '0;
        end else begin
            logic [FTQW:0] h;
            h = head + (FTQW + 1)'(pop);
            head <= h;
            if (flush_all)    tail <= h;
            else if (restore) tail <= {(restore_idx >= head[FTQW-1:0]) ? head[FTQW] : ~head[FTQW], restore_idx}
                                      + (FTQW + 1)'(1);
            else              tail <= tail + (FTQW + 1)'(push);
        end
    end

endmodule : OOO_FTQ
