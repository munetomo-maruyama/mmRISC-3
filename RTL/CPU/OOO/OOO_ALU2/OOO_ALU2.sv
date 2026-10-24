//---------------------------------------------------------------------------
// OOO_ALU2.sv
//
// The ALU of one issue port of mmRISC-3 in the fusion configuration
// (STRATEGY.md 4): two full ALUs in series, so that a fused pair finishes
// in one cycle (Plan/MODEL.md 6, `chain` = 1). Combinational; the operands
// come from the register file or the bypass, chosen in front of it.
//
//   first  : res1 = op1(a1, b1)    a1 = s1 / pc / 0, b1 = s2 / imm1
//   second : res2 = op2(a2, b2)    a2 = res1 / s3, b2 = res1 / s3 / imm2
//            (only for a fused ALU + ALU; the trace analysis shows the second
//            halves are add, and, xor, or, sh*add.uw, bexti, zext.h, sext.h
//            and so on, so the second ALU is a full one too)
//   branch : the comparison of a branch. Alone: s1 against s2. Fused after
//            an ALU operation (ALU + branch): one side is res1, the other s3
//            (x0 reads as zero, so beqz / bnez are s3 = 0).
//
// What is not here: the target of a branch or jump (pc + imm, a separate
// adder beside this one, not on the chained path) and the link value.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_ALU2
    (
        input  logic [63:0] s1,
        input  logic [63:0] s2,
        input  logic [63:0] s3,
        input  logic [63:0] imm1,
        input  logic [63:0] imm2,
        input  logic [63:0] pc,

        // first operation
        input  logic [5:0]  op1,
        input  logic        uw1,
        input  logic [1:0]  shift1,
        input  logic        word1,
        input  logic [1:0]  a1_sel,       // 0 s1, 1 pc (auipc), 2 zero (lui)
        input  logic        b1_imm,       // 1: imm1, 0: s2

        // second operation (fused ALU + ALU)
        input  logic [5:0]  op2,
        input  logic        uw2,
        input  logic [1:0]  shift2,
        input  logic        word2,
        input  logic        a2_s3,        // 1: s3, 0: res1
        input  logic [1:0]  b2_sel,       // 0 res1, 1 s3, 2 imm2

        // branch
        input  logic        is_br,
        input  logic [2:0]  br_op,        // funct3 of the branch
        input  logic        br_fused,     // ALU + branch: compare res1 / s3
        input  logic        br_res1_a,    // res1 is the first operand (else the second)

        output logic [63:0] res1,
        output logic [63:0] res2,
        output logic        take_branch
    );

    logic [63:0] a1, b1, a2, b2, ca, cb;

    always @(*) begin
        case (a1_sel)
            2'd1:    a1 = pc;
            2'd2:    a1 = 64'd0;
            default: a1 = s1;
        endcase
        b1 = b1_imm ? imm1 : s2;
    end

    OOO_ALU u_alu1
        (.op_a(a1), .op_b(b1), .alu_op(op1), .a_uw(uw1), .a_shift(shift1), .word_op(word1),
         .result(res1));

    always @(*) begin
        a2 = a2_s3 ? s3 : res1;
        case (b2_sel)
            2'd1:    b2 = s3;
            2'd2:    b2 = imm2;
            default: b2 = res1;
        endcase
    end

    OOO_ALU u_alu2
        (.op_a(a2), .op_b(b2), .alu_op(op2), .a_uw(uw2), .a_shift(shift2), .word_op(word2),
         .result(res2));

    // the comparison: alone s1 / s2, fused res1 / s3 in either order
    logic eq, lt, ltu;
    always @(*) begin
        if (br_fused) begin
            ca = br_res1_a ? res1 : s3;
            cb = br_res1_a ? s3 : res1;
        end else begin
            ca = s1;
            cb = s2;
        end
    end
    assign eq  = (ca == cb);
    assign lt  = ($signed(ca) < $signed(cb));
    assign ltu = (ca < cb);

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
