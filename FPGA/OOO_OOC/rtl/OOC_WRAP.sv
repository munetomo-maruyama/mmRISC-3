//---------------------------------------------------------------------------
// OOC_WRAP.sv : register-to-register harnesses of the blocks of mmRISC-3
// for out-of-context synthesis (synth_ooo.tcl)
//
// A combinational block alone has only input-to-output paths, which the I/O
// delays of out-of-context synthesis can only guess at. Each harness puts
// flip-flops on every input and output, so that the timing reported is the
// block between registers, as it will sit in the core.
//
//   OOC_ALU2    the 1-cycle loop of an ALU port: each source chosen among
//               the register file, the port's own two results of the last
//               cycle and the other ports' results (the bypass), then the
//               two chained ALUs and the branch comparison, into the result
//               registers that feed the bypass again
//   OOC_FUSE    fusion of a group of 4 decoded instructions
//   OOC_PRF     the register file: read address -> data
//   OOC_RENAME  renaming with its inputs and outputs registered
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOC_ALU2
    (
        input  logic        clk,
        input  logic [63:0] prf1, prf2, prf3,     // register file data
        input  logic [63:0] ext0, ext1,           // the other ALU port and the load
        input  logic [2:0]  bsel1, bsel2, bsel3,  // 0 prf, 1 own res1, 2 own res2, 3 ext0, 4 ext1
        input  logic [63:0] imm1, imm2, pc,
        input  logic [5:0]  op1, op2,
        input  logic        uw1, uw2, word1, word2, b1_imm, a2_s3, is_br, br_fused, br_res1_a,
        input  logic [1:0]  shift1, shift2, a1_sel, b2_sel,
        input  logic [2:0]  br_op,
        output logic [63:0] out1, out2,
        output logic        out_br
    );
    logic [63:0] p1, p2, p3, e0, e1, i1, i2, pcq, r1, r2, s1, s2, s3, n1, n2;
    logic [2:0]  q1, q2, q3, bo;
    logic [5:0]  o1, o2;
    logic        u1, u2, w1, w2, bi, a2, ib, bf, br1, nbr, rbr;
    logic [1:0]  h1, h2, as1, bs2;

    always_ff @(posedge clk) begin
        p1 <= prf1; p2 <= prf2; p3 <= prf3; e0 <= ext0; e1 <= ext1;
        q1 <= bsel1; q2 <= bsel2; q3 <= bsel3; i1 <= imm1; i2 <= imm2; pcq <= pc;
        o1 <= op1; o2 <= op2; u1 <= uw1; u2 <= uw2; w1 <= word1; w2 <= word2;
        bi <= b1_imm; a2 <= a2_s3; ib <= is_br; bf <= br_fused; br1 <= br_res1_a;
        h1 <= shift1; h2 <= shift2; as1 <= a1_sel; bs2 <= b2_sel; bo <= br_op;
        r1 <= n1; r2 <= n2; rbr <= nbr;
    end
    function automatic logic [63:0] byp(input logic [2:0] s, input logic [63:0] p);
        case (s)
            3'd1:    return r1;
            3'd2:    return r2;
            3'd3:    return e0;
            3'd4:    return e1;
            default: return p;
        endcase
    endfunction
    assign s1 = byp(q1, p1);
    assign s2 = byp(q2, p2);
    assign s3 = byp(q3, p3);

    OOO_ALU2 u_alu2
        (.s1(s1), .s2(s2), .s3(s3), .imm1(i1), .imm2(i2), .pc(pcq),
         .op1(o1), .uw1(u1), .shift1(h1), .word1(w1), .a1_sel(as1), .b1_imm(bi),
         .op2(o2), .uw2(u2), .shift2(h2), .word2(w2), .a2_s3(a2), .b2_sel(bs2),
         .is_br(ib), .br_op(bo), .br_fused(bf), .br_res1_a(br1),
         .res1(n1), .res2(n2), .take_branch(nbr));

    assign out1 = r1;
    assign out2 = r2;
    assign out_br = rbr;
endmodule : OOC_ALU2

module OOC_FUSE
    (
        input  logic             clk,
        input  logic             no_fuse,
        input  logic [3:0]       valid, seq, use_rs1, use_rs2,
        input  logic [3:0][2:0]  cls, op,
        input  logic [3:0][4:0]  rd, rs1, rs2,
        input  logic [3:0][11:0] imm,
        input  logic [3:0][1:0]  msize,
        input  logic [3:0]       alu2ok,
        output logic [15:0]      out
    );
    logic             nf;
    logic [3:0]       va, sq, u1, u2, ok2;
    logic [3:0][2:0]  cl, opq;
    logic [3:0][4:0]  d, a, b;
    logic [3:0][11:0] im;
    logic [3:0][1:0]  ms;
    logic             v0, v1;
    logic [1:0]       s0, s1;
    logic [3:0]       k0, k1;
    logic [2:0]       cn;
    always_ff @(posedge clk) begin
        nf <= no_fuse; va <= valid; sq <= seq; u1 <= use_rs1; u2 <= use_rs2;
        cl <= cls; opq <= op; d <= rd; a <= rs1; b <= rs2; im <= imm; ms <= msize; ok2 <= alu2ok;
        out <= {v0, s0, k0, v1, s1, k1, cn[1:0]};
    end
    OOO_FUSE u_fuse
        (.no_fuse(nf), .valid(va), .seq(sq), .cls(cl), .op(opq), .rd(d), .rs1(a), .rs2(b),
         .use_rs1(u1), .use_rs2(u2), .imm(im), .msize(ms), .alu2ok(ok2),
         .u0_valid(v0), .u0_slot(s0), .u0_kind(k0), .u1_valid(v1), .u1_slot(s1), .u1_kind(k1),
         .consumed(cn));
endmodule : OOC_FUSE

module OOC_PRF
    #(
        parameter int NREG = 96,
        parameter int NW   = 5,
        parameter int NR   = 8
    )
    (
        input  logic                            clk,
        input  logic [NR-1:0][$clog2(NREG)-1:0] ra,
        output logic [NR-1:0][63:0]             rd,
        input  logic [NW-1:0]                   we,
        input  logic [NW-1:0][$clog2(NREG)-1:0] wa,
        input  logic [NW-1:0][63:0]             wd
    );
    logic [NR-1:0][$clog2(NREG)-1:0] raq;
    logic [NR-1:0][63:0]             rdn;
    logic [NW-1:0]                   weq;
    logic [NW-1:0][$clog2(NREG)-1:0] waq;
    logic [NW-1:0][63:0]             wdq;
    always_ff @(posedge clk) begin
        raq <= ra; rd <= rdn; weq <= we; waq <= wa; wdq <= wd;
    end
    OOO_PRF #(.NREG(NREG), .NW(NW), .NR(NR)) u_prf
        (.clk(clk), .ra(raq), .rd(rdn), .we(weq), .wa(waq), .wd(wdq));
endmodule : OOC_PRF

module OOC_RENAME
    (
        input  logic              clk,
        input  logic              rst_n,
        input  logic [1:0]        in_valid,
        input  logic [1:0][1:0]   in_use,
        input  logic [1:0][1:0][4:0] in_src,
        input  logic [1:0]        in_wr,
        input  logic [1:0][4:0]   in_dst,
        input  logic [1:0]        in_ckpt,
        input  logic [2:0]        wb_valid,
        input  logic [2:0][5:0]   wb_tag,
        input  logic [1:0]        free_valid,
        input  logic [1:0][5:0]   free_tag,
        input  logic              restore,
        input  logic [2:0]        restore_id,
        output logic [58:0]       out
    );
    logic [1:0]        iv, ick, iw, fv;
    logic [1:0][1:0]   iu;
    logic [1:0][1:0][4:0] is;
    logic [1:0][4:0]   id;
    logic [2:0]        wv;
    logic [2:0][5:0]   wt;
    logic [1:0][5:0]   ft;
    logic              rs;
    logic [2:0]        rid;
    logic              rdy;
    logic [1:0][2:0]   ckid;
    logic [1:0][1:0][5:0] os;
    logic [1:0][1:0]   ordy;
    logic [1:0][5:0]   od, oo;
    always_ff @(posedge clk) begin
        iv <= in_valid; iu <= in_use; is <= in_src; iw <= in_wr; id <= in_dst; ick <= in_ckpt;
        wv <= wb_valid; wt <= wb_tag; fv <= free_valid; ft <= free_tag; rs <= restore; rid <= restore_id;
        out <= {rdy, ckid, os, ordy, od, oo};
    end
    OOO_RENAME #(.NREG(64), .TAGW(6), .NCKPT(8), .NWB(3)) u_ren
        (.clk(clk), .rst_n(rst_n), .ready(rdy), .in_valid(iv), .in_use(iu), .in_src(is),
         .in_wr(iw), .in_dst(id), .in_ckpt(ick), .out_ckpt_id(ckid), .out_src(os), .out_rdy(ordy),
         .out_dst(od), .out_old(oo), .wb_valid(wv), .wb_tag(wt), .free_valid(fv), .free_tag(ft),
         .restore(rs), .restore_id(rid));
endmodule : OOC_RENAME
