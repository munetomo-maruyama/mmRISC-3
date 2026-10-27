//---------------------------------------------------------------------------
// OOO_STAGE.sv
//
// One pipeline register of a unit of mmRISC-3 (Plan/OOC.md 20): a µop's
// valid bit, its branch mask and W bits of whatever the stage carries. The
// ALU ports have one after IS (RR) and one after RR (EX), and one after EX
// for the write-back; MUL / DIV and the FPU the same, the LSU its own
// (OOO_LSU, with the mask in E and M).
//
// A misprediction kills the µops younger than the branch (OOO_CTRL kill:
// the restored checkpoint, one-hot): a µop whose mask has that bit is not
// taken into the register (in_bm & kill), and one held there leaves (en =
// 0: an iterative divide waiting). The checkpoints resolved as predicted
// (clr) leave the mask, taken in or held, so that a checkpoint given out
// again never kills an older µop through a bit that should have gone (a
// mask taken in with that cycle's clears would keep them for as long as
// the stage holds). flush (OOO_CTRL flush_all) empties the register.
//
// What a stage does in the cycle of a kill (a branch resolved, a result
// written, a completion) is not held back: a killed µop's branch clears
// nothing (OOO_CTRL), its register and its ROB entry are given out again
// only later, so its write and its completion land on nothing live
// (renaming gives a register out a cycle after the restore at the
// earliest, dispatch two; OOO_ROB clears done at dispatch). Only what it
// would do afterwards is stopped, here.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_STAGE
    #(
        parameter int W   = 8,
        parameter int NCK = 6
    )
    (
        input  logic            clk,
        input  logic            rst_n,
        input  logic            flush,
        input  logic [NCK-1:0]  kill,
        input  logic [NCK-1:0]  clr,
        input  logic            en,         // take the input (else hold)
        input  logic            in_valid,
        input  logic [NCK-1:0]  in_bm,
        input  logic [W-1:0]    in_data,
        output logic            out_valid,
        output logic [NCK-1:0]  out_bm,
        output logic [W-1:0]    out_data
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     out_valid <= 1'b0;
        else if (flush)                 out_valid <= 1'b0;
        else if (en)                    out_valid <= in_valid && (in_bm & kill) == '0;
        else if ((out_bm & kill) != '0) out_valid <= 1'b0;
    end
    always_ff @(posedge clk) begin
        if (en) begin
            out_bm   <= in_bm & ~clr;
            out_data <= in_data;
        end else begin
            out_bm   <= out_bm & ~clr;
        end
    end

endmodule : OOO_STAGE
