//---------------------------------------------------------------------------
// OOO_ALUR.sv
//
// The operations not in OOO_ALUF, on queue 0 alone, latency 3 (Doc/STRATEGY.md
// 4.2, Plan/OOC.md 28.8): shifts by a register and their word forms, slli.uw,
// rotates, clz, ctz, cpop, orc.b, rev8, min, max, bset, bclr, binv, bext. None of
// them runs in CoreMark (Plan/model: slow2); other programs will see the latency.
//
//   the cycle before   op, uw, word: decoded into registers
//   stage 1            a, b from registers: the rotation and its mask, the
//                      counts, the bit operations, the comparison
//   stage 2            the result, combinational from q_*
//
// A shift is as in OOO_ALUF: a rotation, a mask of the bits that are the
// result's, the fill in the others. Rotating a low half that is twice in the
// operand rotates it within 32 bits.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_ALUR
    (
        input  logic        clk,
        input  logic [5:0]  op,           // OOO_ALU's encoding
        input  logic        uw,           // slli.uw
        input  logic        word,
        input  logic [63:0] a,            // a cycle after op
        input  logic [63:0] b,
        output logic [63:0] result        // a cycle after a, b
    );

    localparam logic [5:0] ALU_SLL  = 6'd2;
    localparam logic [5:0] ALU_SRL  = 6'd6;
    localparam logic [5:0] ALU_SRA  = 6'd7;
    localparam logic [5:0] ALU_MIN  = 6'd13;
    localparam logic [5:0] ALU_MINU = 6'd14;
    localparam logic [5:0] ALU_MAX  = 6'd15;
    localparam logic [5:0] ALU_MAXU = 6'd16;
    localparam logic [5:0] ALU_ROL  = 6'd17;
    localparam logic [5:0] ALU_ROR  = 6'd18;
    localparam logic [5:0] ALU_CLZ  = 6'd19;
    localparam logic [5:0] ALU_CTZ  = 6'd20;
    localparam logic [5:0] ALU_CPOP = 6'd21;
    localparam logic [5:0] ALU_ORCB = 6'd25;
    localparam logic [5:0] ALU_REV8 = 6'd26;
    localparam logic [5:0] ALU_BSET = 6'd29;
    localparam logic [5:0] ALU_BCLR = 6'd30;
    localparam logic [5:0] ALU_BINV = 6'd31;
    localparam logic [5:0] ALU_BEXT = 6'd32;

    function automatic logic [63:0] rev64(input logic [63:0] x);
        for (int i = 0; i < 64; i++) rev64[i] = x[63-i];
    endfunction

    // trailing zeros: per byte, then the first byte that is not zero
    function automatic logic [6:0] ctz64(input logic [63:0] x);
        logic [7:0] nz;
        logic [2:0] bz [8];
        logic [2:0] sel;
        for (int i = 0; i < 8; i++) begin
            nz[i] = |x[8*i +: 8];
            bz[i] = 3'd0;
            for (int j = 7; j >= 0; j--) if (x[8*i+j]) bz[i] = 3'(j);
        end
        sel = 3'd0;
        for (int i = 7; i >= 0; i--) if (nz[i]) sel = 3'(i);
        return (nz == 8'd0) ? 7'd64 : {1'b0, sel, bz[sel]};
    endfunction

    // ones: a tree of adders over the nibbles
    function automatic logic [6:0] pop64(input logic [63:0] x);
        logic [2:0] p4  [16];
        logic [3:0] p8  [8];
        logic [4:0] p16 [4];
        logic [5:0] p32 [2];
        for (int i = 0; i < 16; i++)
            p4[i] = 3'(x[4*i]) + 3'(x[4*i+1]) + 3'(x[4*i+2]) + 3'(x[4*i+3]);
        for (int i = 0; i < 8; i++) p8[i]  = 4'(p4[2*i])  + 4'(p4[2*i+1]);
        for (int i = 0; i < 4; i++) p16[i] = 5'(p8[2*i])  + 5'(p8[2*i+1]);
        for (int i = 0; i < 2; i++) p32[i] = 6'(p16[2*i]) + 6'(p16[2*i+1]);
        return 7'(p32[0]) + 7'(p32[1]);
    endfunction

    // ---- the operation, decoded
    (* max_fanout = 16 *) logic d_uw, d_word, d_left, d_rot, d_right, d_sra, d_bext, d_mm;
    (* max_fanout = 16 *) logic d_clz, d_ctz, d_pop, d_orcb, d_rev8, d_bset, d_bclr, d_binv;
    logic d_sgn, d_lpick, d_neg;
    always_ff @(posedge clk) begin
        d_uw    <= uw;
        d_word  <= word;
        d_left  <= op == ALU_SLL;
        d_rot   <= op == ALU_ROL || op == ALU_ROR;
        d_right <= op == ALU_SRL || op == ALU_SRA;
        d_sra   <= op == ALU_SRA;
        d_bext  <= op == ALU_BEXT;
        d_mm    <= op == ALU_MIN || op == ALU_MINU || op == ALU_MAX || op == ALU_MAXU;
        d_clz   <= op == ALU_CLZ;
        d_ctz   <= op == ALU_CTZ;
        d_pop   <= op == ALU_CPOP;
        d_orcb  <= op == ALU_ORCB;
        d_rev8  <= op == ALU_REV8;
        d_bset  <= op == ALU_BSET;
        d_bclr  <= op == ALU_BCLR;
        d_binv  <= op == ALU_BINV;
        d_sgn   <= op == ALU_MIN || op == ALU_MAX;
        d_lpick <= op == ALU_MIN || op == ALU_MINU;
        d_neg   <= op == ALU_SLL || op == ALU_ROL;
    end

    // ---- stage 1
    logic [31:0] a32;
    logic [5:0]  n, amt;
    logic [63:0] sx, r0, r1, rot, mask, bm, other, orc, rv8;
    logic [6:0]  tz, pc;
    logic        fill, lt;
    always @(*) begin
        a32 = a[31:0];
        n   = d_word ? {1'b0, b[4:0]} : b[5:0];
        amt = d_neg ? 6'd0 - n : n;
        if (d_rot && d_word)        sx = {a32, a32};
        else if (d_uw)              sx = {32'd0, a32};
        else if (d_word && d_sra)   sx = {{32{a32[31]}}, a32};
        else if (d_word && d_right) sx = {32'd0, a32};
        else                        sx = a;
        case (amt[1:0])
            2'd1:    r0 = {sx[0],    sx[63:1]};
            2'd2:    r0 = {sx[1:0],  sx[63:2]};
            2'd3:    r0 = {sx[2:0],  sx[63:3]};
            default: r0 = sx;
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
        mask = 64'd0;
        if (d_rot)   mask = ~64'd0;
        if (d_left)  mask = ~64'd0 << n;
        if (d_right) mask = ~64'd0 >> n;
        if (d_bext)  mask = 64'd1;
        fill = d_sra && sx[63];

        // the counts: clz is ctz of the reversed operand (a word form puts its
        // half where the count sees it, with ones behind it)
        if (d_clz) tz = ctz64(rev64(d_word ? {a32, 32'hFFFF_FFFF} : a));
        else       tz = ctz64(d_word ? {32'hFFFF_FFFF, a32} : a);
        pc = pop64(d_word ? {32'd0, a32} : a);

        for (int i = 0; i < 8; i++) begin
            orc[8*i +: 8] = {8{|a[8*i +: 8]}};
            rv8[8*i +: 8] = a[8*(7-i) +: 8];
        end
        bm = 64'd1 << b[5:0];
        other = ({64{d_clz || d_ctz}} & {57'd0, tz}) | ({64{d_pop}} & {57'd0, pc}) |
                ({64{d_orcb}} & orc) | ({64{d_rev8}} & rv8) |
                ({64{d_bset}} & (a | bm)) | ({64{d_bclr}} & (a & ~bm)) | ({64{d_binv}} & (a ^ bm));
        lt = {a[63] ^ d_sgn, a[62:0]} < {b[63] ^ d_sgn, b[62:0]};
    end

    // ---- stage 2
    logic [63:0] q_rot, q_mask, q_other, q_a, q_b, res;
    logic        q_fill, q_mm, q_pa, q_word;
    always_ff @(posedge clk) begin
        q_rot   <= rot;
        q_mask  <= mask;
        q_fill  <= fill;
        q_other <= other;
        q_a     <= a;
        q_b     <= b;
        q_mm    <= d_mm;
        q_pa    <= d_lpick ? lt : !lt;
        q_word  <= d_word;
    end
    always @(*) begin
        res = (q_mask & q_rot) | ({64{q_fill}} & ~q_mask) | q_other |
              ({64{q_mm && q_pa}} & q_a) | ({64{q_mm && !q_pa}} & q_b);
        result = q_word ? {{32{res[31]}}, res[31:0]} : res;
    end

endmodule : OOO_ALUR
