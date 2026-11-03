//---------------------------------------------------------------------------
// OOO_ALUF.sv
//
// The ALU of one cycle at 100 MHz (Doc/STRATEGY.md 4.5 loop 2, Plan/OOC.md
// 28.6). Combinational; OOO_EXU decodes the operation in the stage before, so
// everything that selects comes from a register, and no selection depends on
// the operands but czero's and the comparisons' results.
//
// What is here is what CoreMark executes (Plan/model: slow2):
//   adder    add, sub, addw, subw, add.uw, sh1add .. sh3add(.uw); slt, sltu and
//            the comparison of a branch from its carry
//   logic    xor, or, and, andn, orn, xnor
//   shifter  slli, srli, srai and their word forms, bexti: by an immediate
//   the rest sext.b, sext.h, zext.h, czero.eqz, czero.nez
//
// Everything else is OOO_ALUR's, on queue 0 (OOO_EXU).
//
// The shifter is a rotation right, 3 stages of 4 to 1 with nothing in front, and
// a mask m, decoded from the immediate in the stage before (Plan/OOC.md 28.8): a
// bit of the result is the rotation's where m has a 1, the fill where it has a
// 0. A left shift by n rotates by 64 - n. srai's sign does not go through the
// rotation with its fan-out. The upper half of slliw is bit 31 of the rotation.
//
// The result is an AND-OR of the units: with all g_*, m at 0 it is 0, which is
// what a µop that writes nothing gives. The last level is one LUT a bit, the
// adder and the rotation on its inputs (Plan/OOC.md 28.7): what else makes a
// result, and extra (port 0's other results), comes in by o. So a word's sign
// extension is 2 levels after the sum: the upper half has its own g_addh, and
// takes bit 31 from sgn.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_ALUF
    (
        input  logic [63:0] a,
        input  logic [63:0] b,

        // the adder
        input  logic        inv,          // a - b: sub, slt, sltu, a branch
        input  logic        a_uw,         // a: the low half, zero extended
        input  logic [1:0]  a_shift,      // a: shifted left by this much
        // which unit gives the result
        input  logic        g_add,        // the lower half; the upper half:
        input  logic        g_addh,       //   the sum's
        input  logic        g_addw,       //   bit 31 of the sum (addw, subw)
        input  logic        g_log,
        input  logic [2:0]  lop,          // 0 xor, 1 or, 2 and, 3 andn, 4 orn, 5 xnor
        input  logic [63:0] m,            // the rotation's bits in the result
        input  logic        fill63,       // the others: bit 63 of a (srai)
        input  logic        fill31,       //   ... or bit 31 (sraiw, srliw by 0)
        input  logic        g_slw,        // slliw: the upper half is bit 31
        input  logic [5:0]  amt,
        input  logic        g_slt,
        input  logic        g_sltu,
        input  logic        g_zh,         // zext.h
        input  logic        g_sb,         // sext.b
        input  logic        g_sxh,        // sext.h
        input  logic        g_cz,         // czero
        input  logic        cz_n,         // czero.nez
        input  logic [63:0] extra,        // ORed into the result

        output logic [63:0] result,
        output logic [63:0] sum,          // the adder's sum (jalr's target, an address)
        output logic        c_eq,         // a == b
        output logic        c_lt,         // with inv: a < b signed
        output logic        c_ltu         // with inv: a < b unsigned
    );

    // the adder: one LUT and carry per bit, behind the change of a
    logic [63:0] az, as;
    logic [64:0] s65;
    always @(*) begin
        az = a_uw ? {32'd0, a[31:0]} : a;
        case (a_shift)
            2'd1:    as = {az[62:0], 1'b0};
            2'd2:    as = {az[61:0], 2'd0};
            2'd3:    as = {az[60:0], 3'd0};
            default: as = az;
        endcase
        s65   = {1'b0, as} + {1'b0, inv ? ~b : b} + {64'd0, inv};
        sum   = s65[63:0];
        c_ltu = !s65[64];
        c_lt  = c_ltu ^ a[63] ^ b[63];
        c_eq  = a == b;
    end

    // the logic unit: one LUT per bit
    logic [63:0] l;
    always @(*) begin
        case (lop)
            3'd0:    l = a ^ b;
            3'd1:    l = a | b;
            3'd2:    l = a & b;
            3'd3:    l = a & ~b;
            3'd4:    l = a | ~b;
            default: l = ~(a ^ b);
        endcase
    end

    // the rotation
    logic [63:0] r0, r1, rot;
    always @(*) begin
        case (amt[1:0])
            2'd1:    r0 = {a[0],    a[63:1]};
            2'd2:    r0 = {a[1:0],  a[63:2]};
            2'd3:    r0 = {a[2:0],  a[63:3]};
            default: r0 = a;
        endcase
        case (amt[3:2])
            2'd1:    r1 = {r0[3:0],  r0[63:4]};
            2'd2:    r1 = {r0[7:0],  r0[63:8]};
            2'd3:    r1 = {r0[11:0], r0[63:12]};
            default: r1 = r0;
        endcase
        case (amt[5:4])
            2'd1:    rot = {r1[15:0], r1[63:16]};
            2'd2:    rot = {r1[31:0], r1[63:32]};
            2'd3:    rot = {r1[47:0], r1[63:48]};
            default: rot = r1;
        endcase
    end

    // the rest; czero's zero test is the one late selection of many bits
    logic [63:0] x, o;
    logic        cz_pass, fill, slt, sgn;
    always @(*) begin
        cz_pass = cz_n ? (b == 64'd0) : (b != 64'd0);
        fill     = (fill63 && a[63]) || (fill31 && a[31]);
        x[7:0]   = (g_zh || g_sb || g_sxh) ? a[7:0] : 8'd0;
        x[15:8]  = (g_zh || g_sxh) ? a[15:8] : g_sb ? {8{a[7]}} : 8'd0;
        x[63:16] = g_sb ? {48{a[7]}} : g_sxh ? {48{a[15]}} : 48'd0;
        o   = ({64{g_log}} & l) | x | ({64{g_cz && cz_pass}} & a) | ({64{fill}} & ~m) | extra;
        // (one LUT from the carry out, which comes late)
        slt = (g_slt || g_sltu) && (c_ltu ^ (g_slt && (a[63] ^ b[63])));
        sgn = (g_addw && sum[31]) || (g_slw && rot[31]);
    end

    // the last level
    always @(*) begin
        result[31:0]  = ({32{g_add}} & sum[31:0]) | (m[31:0] & rot[31:0]) | o[31:0];
        result[0]     = result[0] | slt;
        result[63:32] = ({32{g_addh}} & sum[63:32]) | (m[63:32] & rot[63:32]) | o[63:32] | {32{sgn}};
    end

endmodule : OOO_ALUF
