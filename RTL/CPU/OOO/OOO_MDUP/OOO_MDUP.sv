//---------------------------------------------------------------------------
// OOO_MDUP.sv
//
// Port 0's multiply / divide unit of mmRISC-3 (Plan/OOC.md 23, 24): mmRISC-2's
// CORE_MDU (RTL/CPU/CORE, without change) behind issue port 0 for mulh*,
// clmul* and the divides; mul / mulw go to the pipelined multiplier beside
// it (OOO_PMUL, Doc/UARCH.md D-16). CORE_MDU does one operation at a time,
// over several cycles.
//
//   the operations   answered from outside (ext_answer: dispatched as
//                    writing nothing): started in EX, done when CORE_MDU
//                    is, then written in a cycle when port 0's write-back
//                    slot is free (slot_busy: a latency-1 writer in EX, or
//                    OOO_PMUL's result, which writes through port 1's since
//                    Plan/CORE.md 5.13 but shares the ROB's completion port
//                    with the MDU), with their wakeup (ext_*); while
//                    one waits, p0_hold keeps the issue queue from giving
//                    port 0 latency-1 writers, so the slot comes within two
//                    cycles
//   mdu_ok           (a register) an MDU µop may issue now: none between
//                    its issue and its write
//
// A µop is killed by its branch mask (kill) or flush_all in EX, while
// CORE_MDU works on it (CORE_MDU kill), or as it is done (nothing written);
// the mask loses the cleared bits while it is held, as in OOO_STAGE.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_MDUP
    #(
        parameter int ROBW = 5,
        parameter int TAGW = 6,
        parameter int NCK  = 6
    )
    (
        input  logic                clk,
        input  logic                rst_n,
        input  logic                flush,      // OOO_CTRL flush_all
        input  logic [NCK-1:0]      kill,
        input  logic [NCK-1:0]      clr,

        // OOO_IQ: what port 0 issues now
        input  logic                iss_md,
        input  logic [NCK-1:0]      iss_bm,     // OOO_IQ iss_bm[0]
        output logic                mdu_ok,
        output logic                p0_hold,

        // port 0's EX: the MDU µop starts here
        input  logic                ex_valid,
        input  logic [3:0]          ex_op,      // CORE_MDU op (never 0: mul goes to OOO_PMUL)
        input  logic                ex_word,
        input  logic [63:0]         ex_a,
        input  logic [63:0]         ex_b,
        input  logic [ROBW-1:0]     ex_rob,
        input  logic [TAGW-1:0]     ex_dst,
        input  logic [NCK-1:0]      ex_bm,
        input  logic                slot_busy,  // port 0's write-back slot is taken this cycle

        // into port 0's write-back register at the end of this cycle
        output logic                res_valid,
        output logic [TAGW-1:0]     res_tag,
        output logic [63:0]         res_data,
        output logic [ROBW-1:0]     res_rob,    // its completion
        output logic                ext_valid,  // OOO_IQ ext_*: its wakeup
        output logic [TAGW-1:0]     ext_tag
    );

    // the µop CORE_MDU works on
    logic            h_v;
    logic [ROBW-1:0] h_rob;
    logic [TAGW-1:0] h_dst;
    logic [NCK-1:0]  h_bm;
    // an MDU µop from its issue to its write
    logic            lb_v;
    logic [NCK-1:0]  lb_bm;

    logic start, h_kill, done, busy, ack;
    logic [63:0] result;
    always @(*) begin
        start     = ex_valid && !flush && (ex_bm & kill) == '0;
        h_kill    = h_v && (flush || (h_bm & kill) != '0);
        ack       = h_v && done && !h_kill && !slot_busy;
        res_valid = ack;
        res_tag   = h_dst;
        res_data  = result;
        res_rob   = h_rob;
        ext_valid = ack;
        ext_tag   = h_dst;
    end

    CORE_MDU u_mdu
        (.clk(clk), .rst_n(rst_n), .start(start), .kill(h_kill), .op(ex_op), .word_op(ex_word),
         .rs1_data(ex_a), .rs2_data(ex_b), .busy(busy), .done(done), .ack(ack), .result(result));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_v     <= 1'b0;
            lb_v    <= 1'b0;
            mdu_ok  <= 1'b1;
            p0_hold <= 1'b0;
        end else begin
            logic lb;
            if (start)                 h_v <= 1'b1;
            else if (ack || h_kill)    h_v <= 1'b0;
            if (flush)                                              lb = 1'b0;
            else if (iss_md && (iss_bm & kill) == '0)               lb = 1'b1;
            else if (lb_v && ((lb_bm & kill) != '0 || ack))         lb = 1'b0;
            else                                                    lb = lb_v;
            lb_v    <= lb;
            mdu_ok  <= !lb;
            p0_hold <= h_v && done && !ack && !h_kill;
        end
    end
    always_ff @(posedge clk) begin
        if (start) begin
            h_rob  <= ex_rob;
            h_dst  <= ex_dst;
            h_bm   <= ex_bm & ~clr;
        end else begin
            h_bm   <= h_bm & ~clr;
        end
        if (iss_md) lb_bm <= iss_bm & ~clr;
        else        lb_bm <= lb_bm & ~clr;
    end

    // (busy: CORE_MDU's, not needed here: mdu_ok keeps a start from finding it busy)
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_busy;
    assign unused_busy = busy;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule : OOO_MDUP
