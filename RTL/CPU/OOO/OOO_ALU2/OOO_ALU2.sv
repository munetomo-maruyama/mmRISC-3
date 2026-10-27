//---------------------------------------------------------------------------
// OOO_ALU2.sv
//
// The ALU of one issue port of mmRISC-3 (STRATEGY.md 4): one full ALU and
// the comparison of a branch, so that a fused ALU + branch finishes in one
// cycle (Plan/MODEL.md 6). Combinational; the operands come from the
// register file or the bypass, chosen in front of it.
//
//   ALU    : res1 = op1(a1, b1)    a1 = s1 / pc / 0, b1 = s2 / imm1
//   branch : the comparison of a branch. Alone: s1 against s2. Fused after
//            an ALU operation (ALU + branch): one side is res1, the other
//            s1, s2 or zero (br_o_sel). A pair reads at most 2 registers
//            (OOO_FUSE SRC2), so the branch's other register is one of the
//            two the pair reads (on s2 when the ALU operation takes an
//            immediate), or x0 (beqz / bnez after an operation that reads
//            two): no third source and no third bypass (G0, Doc/UARCH.md
//            6.1).
//
// Fusion level 2 (G0b D-14, Doc/UARCH.md 6.3 and 6.7): the second, narrowed
// ALU of a fused ALU + ALU is gone with that pair.
//
// FULL = 0 is ALU1 (G0b L7, Doc/UARCH.md 6.11 and 6.12): its OOO_ALU has only
// add / sub, slt / sltu and the logic operations (OOO_ALU FULL = 0); the
// issue queue gives it only µops decoded as "any ALU", which those are (a
// branch, alone or fused after such an operation, compares here as well).
//
// What is not here: the target of a branch or jump (pc + imm, a separate
// adder beside this one, not on the chained path) and the link value.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_ALU2
    #(
        parameter bit FULL = 1'b1       // 0: ALU1, the limited ALU
    )
    (
        input  logic [63:0] s1,
        input  logic [63:0] s2,
        input  logic [63:0] imm1,
        input  logic [63:0] pc,

        // the operation
        input  logic [5:0]  op1,
        input  logic        uw1,
        input  logic [1:0]  shift1,
        input  logic        word1,
        input  logic [1:0]  a1_sel,       // 0 s1, 1 pc (auipc), 2 zero (lui)
        input  logic        b1_imm,       // 1: imm1, 0: s2

        // branch
        input  logic        is_br,
        input  logic [2:0]  br_op,        // funct3 of the branch
        input  logic        br_fused,     // ALU + branch: compare res1 with the other operand
        input  logic        br_res1_a,    // res1 is the first operand (else the second)
        input  logic [1:0]  br_o_sel,     // the other operand of a fused branch: 0 s1, 1 s2, 2 zero

        output logic [63:0] res1,
        output logic        take_branch
    );

    logic [63:0] a1, b1, o, ca, cb;

    always @(*) begin
        case (a1_sel)
            2'd1:    a1 = pc;
            2'd2:    a1 = 64'd0;
            default: a1 = s1;
        endcase
        b1 = b1_imm ? imm1 : s2;
    end

    OOO_ALU #(.FULL(FULL)) u_alu1
        (.op_a(a1), .op_b(b1), .alu_op(op1), .a_uw(uw1), .a_shift(shift1), .word_op(word1),
         .result(res1));

    // the comparison: alone s1 / s2, fused res1 / the other operand in
    // either order; one subtraction gives both orders of "less than" (its
    // carry is ca >= cb unsigned, the signs turn that into the signed one)
    logic        eq, lt, ltu;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [64:0] diff;            // only its carry is used
    /* verilator lint_on UNUSEDSIGNAL */
    always @(*) begin
        case (br_o_sel)
            2'd1:    o = s2;
            2'd2:    o = 64'd0;
            default: o = s1;
        endcase
        if (br_fused) begin
            ca = br_res1_a ? res1 : o;
            cb = br_res1_a ? o : res1;
        end else begin
            ca = s1;
            cb = s2;
        end
        diff = {1'b0, ca} + {1'b0, ~cb} + 65'd1;
        ltu  = !diff[64];
        lt   = ltu ^ ca[63] ^ cb[63];
        eq   = (ca == cb);
    end

    always @(*) begin
        case (br_op)
            3'b000:  take_branch = is_br &  eq;     // BEQ
            3'b001:  take_branch = is_br & ~eq;     // BNE
            3'b100:  take_branch = is_br &  lt;     // BLT
            3'b101:  take_branch = is_br & ~lt;     // BGE
            3'b110:  take_branch = is_br &  ltu;    // BLTU
            3'b111:  take_branch = is_br & ~ltu;    // BGEU
            default: take_branch = 1'b0;
        endcase
    end

endmodule : OOO_ALU2
