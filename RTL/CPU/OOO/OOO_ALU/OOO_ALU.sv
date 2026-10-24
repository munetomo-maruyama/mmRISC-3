//---------------------------------------------------------------------------
// OOO_ALU.sv
//
// One integer ALU of mmRISC-3: RV64I + Zba / Zbb / Zbs / Zicond.
// Combinational; the operands are already selected (register, immediate,
// pc, or the result of the first half of a fused pair, OOO_ALU2).
//
// The operations and their encoding are those of mmRISC-2's CORE_EXU
// (mmRISC-2 RTL/CPU/CPU_CORE/CORE_EXU), so that the decoder and the tests
// of mmRISC-2 carry over:
//   Zba is the adder with two changes to the first operand in front of it:
//   its low half zero extended (a_uw, the .uw forms, also slli.uw) and a
//   shift left by one to three (a_shift, sh1add .. sh3add).
//   word_op: the 32 bit forms (the result sign extended from bit 31).
//
// The units are shared, as in CORE_EXU (Plan/OOC.md 7.2: one unit per
// operation made the first version 3k to 4.7k LUTs):
//   adder    add, sub, and the comparisons of slt / sltu / min / max from
//            its carry (a - b = a + ~b + 1)
//   shifter  one right funnel shift of {hi, lo} by 0 .. 63: srl / sra (hi
//            zero / sign), ror (hi = lo), bext; the left shifts and rol are
//            the same on the bit-reversed operand, reversed back
//   counts   ctz as a tree over bytes (clz is ctz of the reversed operand),
//            cpop as a tree of adders
//
// FULL = 0 is the second stage of a fused ALU + ALU pair (OOO_ALU2): only
// the operations that CoreMark puts there (Plan/OOC.md 7.2) and the cheap
// ones beside them,
//   add / sub, sh*add(.uw), the logic operations, srl (srliw is the only
//   shift CoreMark has there), sext.b / sext.h / zext.h, czero.eqz /
//   czero.nez, bext
// (OOO_FUSE alu2ok, tb_alu2 OPS2); without sll / sra (the reversal and the sign fill of
// the shifter), rotates, comparisons, min / max, counts, orc.b / rev8 and
// bset / bclr / binv. Their result is 0 there; the fusion
// never puts them in a second stage (OOO_FUSE, alu2ok).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_ALU
    #(
        parameter bit FULL = 1'b1
    )
    (
        input  logic [63:0] op_a,
        input  logic [63:0] op_b,
        input  logic [5:0]  alu_op,
        input  logic        a_uw,         // op_a : the low half, zero extended
        input  logic [1:0]  a_shift,      // op_a : shifted left by this much (adder)
        input  logic        word_op,
        output logic [63:0] result
    );

    localparam logic [5:0] ALU_ADD  = 6'd0;
    localparam logic [5:0] ALU_SUB  = 6'd1;
    localparam logic [5:0] ALU_SLL  = 6'd2;
    localparam logic [5:0] ALU_SLT  = 6'd3;
    localparam logic [5:0] ALU_SLTU = 6'd4;
    localparam logic [5:0] ALU_XOR  = 6'd5;
    localparam logic [5:0] ALU_SRL  = 6'd6;
    localparam logic [5:0] ALU_SRA  = 6'd7;
    localparam logic [5:0] ALU_OR   = 6'd8;
    localparam logic [5:0] ALU_AND  = 6'd9;
    // Zbb
    localparam logic [5:0] ALU_ANDN = 6'd10;
    localparam logic [5:0] ALU_ORN  = 6'd11;
    localparam logic [5:0] ALU_XNOR = 6'd12;
    localparam logic [5:0] ALU_MIN  = 6'd13;
    localparam logic [5:0] ALU_MINU = 6'd14;
    localparam logic [5:0] ALU_MAX  = 6'd15;
    localparam logic [5:0] ALU_MAXU = 6'd16;
    localparam logic [5:0] ALU_ROL  = 6'd17;
    localparam logic [5:0] ALU_ROR  = 6'd18;
    localparam logic [5:0] ALU_CLZ  = 6'd19;
    localparam logic [5:0] ALU_CTZ  = 6'd20;
    localparam logic [5:0] ALU_CPOP = 6'd21;
    localparam logic [5:0] ALU_SEXTB= 6'd22;
    localparam logic [5:0] ALU_SEXTH= 6'd23;
    localparam logic [5:0] ALU_ZEXTH= 6'd24;
    localparam logic [5:0] ALU_ORCB = 6'd25;
    localparam logic [5:0] ALU_REV8 = 6'd26;
    // Zicond
    localparam logic [5:0] ALU_CZEQZ= 6'd27;
    localparam logic [5:0] ALU_CZNEZ= 6'd28;
    // Zbs
    localparam logic [5:0] ALU_BSET = 6'd29;
    localparam logic [5:0] ALU_BCLR = 6'd30;
    localparam logic [5:0] ALU_BINV = 6'd31;
    localparam logic [5:0] ALU_BEXT = 6'd32;

    function automatic logic [63:0] rev64(input logic [63:0] v);
        for (int i = 0; i < 64; i++) rev64[i] = v[63-i];
    endfunction

    // trailing zeros: per byte, then the first byte that is not zero
    function automatic logic [6:0] ctz64(input logic [63:0] v);
        logic [7:0] nz;
        logic [2:0] bz [8];
        logic [2:0] sel;
        for (int b = 0; b < 8; b++) begin
            nz[b] = |v[8*b +: 8];
            bz[b] = 3'd0;
            for (int i = 7; i >= 0; i--) if (v[8*b+i]) bz[b] = 3'(i);
        end
        sel = 3'd0;
        for (int b = 7; b >= 0; b--) if (nz[b]) sel = 3'(b);
        return (nz == 8'd0) ? 7'd64 : {1'b0, sel, bz[sel]};
    endfunction

    // ones: a tree of adders over the nibbles
    function automatic logic [6:0] pop64(input logic [63:0] v);
        logic [2:0] p4  [16];
        logic [3:0] p8  [8];
        logic [4:0] p16 [4];
        logic [5:0] p32 [2];
        for (int i = 0; i < 16; i++)
            p4[i] = 3'(v[4*i]) + 3'(v[4*i+1]) + 3'(v[4*i+2]) + 3'(v[4*i+3]);
        for (int i = 0; i < 8; i++) p8[i]  = 4'(p4[2*i])  + 4'(p4[2*i+1]);
        for (int i = 0; i < 4; i++) p16[i] = 5'(p8[2*i])  + 5'(p8[2*i+1]);
        for (int i = 0; i < 2; i++) p32[i] = 6'(p16[2*i]) + 6'(p16[2*i+1]);
        return 7'(p32[0]) + 7'(p32[1]);
    endfunction

    logic [63:0] res;
    logic [31:0] a32;
    logic [63:0] a_zx;            // op_a with the .uw change

    // adder
    logic        inv_b;           // a - b (sub, and the comparisons)
    logic [64:0] sum;
    logic        lt_u, lt_s;

    // shifter
    logic [5:0]  shamt;
    logic        left, rot;
    logic [63:0] sx;              // what is shifted, before the reversal for left
    logic [63:0] lo, hi;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [127:0] fun;            // (the upper half is not used)
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0] shr, shl;        // the right result, and reversed back (left)

    // counts
    logic [6:0]  n_tz, n_pop;
    logic [63:0] bmask;

    // the result
    logic [63:0] lb, r_log, r_ext;
    logic        g_add, g_log, g_shr, g_shl, g_cz, g_mna, g_mnb;

    always @(*) begin
        a32  = op_a[31:0];
        a_zx = a_uw ? {32'd0, a32} : op_a;

        // adder: the first operand shifted for sh*add, the second inverted for
        // a subtraction; the carry out is "a >= b" unsigned
        inv_b = (alu_op == ALU_SUB) || (FULL && (alu_op == ALU_SLT || alu_op == ALU_SLTU ||
                (alu_op >= ALU_MIN && alu_op <= ALU_MAXU)));
        sum   = {1'b0, a_zx << a_shift} + {1'b0, inv_b ? ~op_b : op_b} + {64'd0, inv_b};
        lt_u  = !sum[64];
        lt_s  = lt_u ^ op_a[63] ^ op_b[63];

        // shifter: right funnel {hi, lo} >> shamt; the left forms reverse lo
        // before and the result after. A 32 bit form shifts the zero / sign
        // extended low half (a 32 bit rotate the low half twice, which is the
        // 32 bit rotation in the low half for amounts below 32)
        shamt = word_op ? {1'b0, op_b[4:0]} : op_b[5:0];
        left  = FULL && (alu_op == ALU_SLL || alu_op == ALU_ROL);
        rot   = FULL && (alu_op == ALU_ROL || alu_op == ALU_ROR);
        if (!word_op)               sx = a_zx;
        else if (rot)               sx = {a32, a32};
        else if (FULL && alu_op == ALU_SRA) sx = {{32{a32[31]}}, a32};
        else                        sx = {32'd0, a32};
        lo  = left ? rev64(sx) : sx;
        if (rot)                    hi = lo;
        else if (FULL && alu_op == ALU_SRA) hi = {64{sx[63]}};
        else                        hi = 64'd0;
        fun = {hi, lo} >> shamt;
        shr = fun[63:0];
        shl = rev64(shr);

        // counts: clz is ctz of the reversed operand (a 32 bit form puts its
        // half where the count sees it, with ones behind it)
        n_tz  = 7'd0;
        n_pop = 7'd0;
        bmask = 64'd0;
        if (FULL) begin
            if (alu_op == ALU_CLZ) n_tz = ctz64(rev64(word_op ? {a32, 32'hFFFF_FFFF} : op_a));
            else                   n_tz = ctz64(word_op ? {32'hFFFF_FFFF, a32} : op_a);
            n_pop = pop64(word_op ? {32'd0, a32} : op_a);
            bmask = 64'd1 << op_b[5:0];
        end

        // the logic unit, also for bset / bclr / binv (the bit mask in place
        // of op_b): one LUT per bit
        lb = (FULL && alu_op >= ALU_BSET && alu_op <= ALU_BINV) ? bmask : op_b;
        case (alu_op)
            ALU_XOR, ALU_BINV:  r_log = op_a ^ lb;
            ALU_OR,  ALU_BSET:  r_log = op_a | lb;
            ALU_AND:            r_log = op_a & lb;
            ALU_ANDN, ALU_BCLR: r_log = op_a & ~lb;
            ALU_ORN:            r_log = op_a | ~lb;
            default:            r_log = ~(op_a ^ lb);     // ALU_XNOR
        endcase

        // the result: an AND-OR of the units, each enabled by its operations
        // (the full ALU's units are constant 0 in the narrowed one)
        g_add = (alu_op == ALU_ADD) || (alu_op == ALU_SUB);
        g_log = (alu_op == ALU_XOR) || (alu_op == ALU_OR) || (alu_op == ALU_AND) ||
                (alu_op >= ALU_ANDN && alu_op <= ALU_XNOR) ||
                (FULL && alu_op >= ALU_BSET && alu_op <= ALU_BINV);
        g_shr = (alu_op == ALU_SRL) || (FULL && (alu_op == ALU_SRA || alu_op == ALU_ROR));
        g_shl = FULL && (alu_op == ALU_SLL || alu_op == ALU_ROL);
        g_cz  = (alu_op == ALU_CZEQZ) ? (op_b != 64'd0) :
                (alu_op == ALU_CZNEZ) ? (op_b == 64'd0) : 1'b0;
        g_mna = FULL && ((alu_op == ALU_MIN && lt_s) || (alu_op == ALU_MINU && lt_u) ||
                         (alu_op == ALU_MAX && !lt_s) || (alu_op == ALU_MAXU && !lt_u));
        g_mnb = FULL && ((alu_op == ALU_MIN && !lt_s) || (alu_op == ALU_MINU && !lt_u) ||
                         (alu_op == ALU_MAX && lt_s) || (alu_op == ALU_MAXU && lt_u));
        r_ext = 64'd0;
        case (alu_op)
            ALU_SEXTB: r_ext = {{56{op_a[7]}},  op_a[7:0]};
            ALU_SEXTH: r_ext = {{48{op_a[15]}}, op_a[15:0]};
            ALU_ZEXTH: r_ext = {48'd0, op_a[15:0]};
            ALU_BEXT:  r_ext = {63'd0, shr[0]};
            ALU_SLT:   r_ext = {63'd0, FULL && lt_s};
            ALU_SLTU:  r_ext = {63'd0, FULL && lt_u};
            ALU_CLZ, ALU_CTZ: r_ext = {57'd0, n_tz};
            ALU_CPOP:  r_ext = {57'd0, n_pop};
            ALU_ORCB:  if (FULL) for (int i = 0; i < 8; i++) r_ext[8*i +: 8] = {8{|op_a[8*i +: 8]}};
            ALU_REV8:  if (FULL) for (int i = 0; i < 8; i++) r_ext[8*i +: 8] = op_a[8*(7-i) +: 8];
            default:   ;
        endcase
        res = ({64{g_add}} & sum[63:0]) | ({64{g_log}} & r_log) | ({64{g_shr}} & shr) |
              ({64{g_shl}} & shl) | ({64{g_cz}} & op_a) | ({64{g_mna}} & op_a) |
              ({64{g_mnb}} & op_b) | r_ext;

        result = word_op ? {{32{res[31]}}, res[31:0]} : res;
    end

endmodule : OOO_ALU
