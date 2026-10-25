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
        input  logic [1:0]        cmt_valid,
        input  logic [1:0]        cmt_wr,
        input  logic [1:0][4:0]   cmt_arch,
        input  logic [1:0][5:0]   cmt_new,
        input  logic              flush_all,
        output logic [58:0]       out
    );
    logic [1:0]        cv, cw;
    logic [1:0][4:0]   ca;
    logic [1:0][5:0]   cn;
    logic              fa;
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
        cv <= cmt_valid; cw <= cmt_wr; ca <= cmt_arch; cn <= cmt_new; fa <= flush_all;
        out <= {rdy, ckid, os, ordy, od, oo};
    end
    OOO_RENAME #(.NREG(64), .TAGW(6), .NCKPT(8), .NWB(3)) u_ren
        (.clk(clk), .rst_n(rst_n), .ready(rdy), .in_valid(iv), .in_use(iu), .in_src(is),
         .in_wr(iw), .in_dst(id), .in_ckpt(ick), .out_ckpt_id(ckid), .out_src(os), .out_rdy(ordy),
         .out_dst(od), .out_old(oo), .wb_valid(wv), .wb_tag(wt), .free_valid(fv), .free_tag(ft),
         .restore(rs), .restore_id(rid),
         .cmt_valid(cv), .cmt_wr(cw), .cmt_arch(ca), .cmt_new(cn), .flush_all(fa));
endmodule : OOC_RENAME

//---------------------------------------------------------------------------
// OOC_LSU: the load / store unit with its inputs and outputs registered
// (the issue fields come from RR, the D$ data from the block RAM, and the
// D$ address goes to it, all through flip-flops in the core as well).
// The inputs come in one bus and the outputs go out in one, to keep the
// harness short; the parameters are those of the G0 configuration.
//---------------------------------------------------------------------------
module OOC_LSU
    (
        input  logic          clk,
        input  logic          rst_n,
        input  logic [325:0]  in,
        output logic [315:0]  out
    );
    logic [325:0] q;
    always_ff @(posedge clk) q <= in;

    logic [1:0]   lq_avail, sq_avail;
    logic [7:0]   disp_lq, disp_sq;
    logic [9:0]   ck_lq_tail, ck_sq_tail;
    logic [11:0]  st_known, dc_kill;
    logic         dc_req_valid, dc_fill_ready, dc_st_valid, wb_valid, wb_late, ld_cancel;
    logic         cmp_ld_valid, cmp_ld_exc, cmp_st_valid, cmp_st_exc;
    logic [39:0]  dc_req_addr, dc_st_addr;
    logic [3:0]   dc_req_tag;
    logic [63:0]  dc_st_data, wb_data;
    logic [7:0]   dc_st_mask;
    logic [5:0]   wb_tag, ld_cancel_tag;
    logic [4:0]   cmp_ld_rob, cmp_st_rob;

    OOO_LSU #(.NLQ(12), .NSQ(12), .PAW(40), .TAGW(6), .ROBW(5)) u_lsu
        (.clk(clk), .rst_n(rst_n),
         .disp_valid(q[1:0]), .disp_ld(q[3:2]), .disp_st(q[5:4]), .disp_rob(q[15:6]),
         .lq_avail(lq_avail), .sq_avail(sq_avail), .disp_lq(disp_lq), .disp_sq(disp_sq),
         .ck_lq_tail(ck_lq_tail), .ck_sq_tail(ck_sq_tail),
         .iss_valid(q[16]), .iss_ld(q[17]), .iss_lq(q[21:18]), .iss_sq(q[25:22]),
         .iss_base(q[89:26]), .iss_imm(q[101:90]), .iss_data(q[165:102]), .iss_size(q[167:166]),
         .iss_uns(q[168]), .iss_dst(q[174:169]), .lsu_st_known(st_known),
         .dc_req_valid(dc_req_valid), .dc_req_addr(dc_req_addr), .dc_req_tag(dc_req_tag),
         .dc_hit(q[175]), .dc_rdata(q[239:176]),
         .dc_fill_valid(q[240]), .dc_fill_tag(q[244:241]), .dc_fill_data(q[308:245]),
         .dc_fill_ready(dc_fill_ready), .dc_kill(dc_kill),
         .dc_st_valid(dc_st_valid), .dc_st_addr(dc_st_addr), .dc_st_data(dc_st_data), .dc_st_mask(dc_st_mask),
         .dc_st_ready(q[309]),
         .wb_valid(wb_valid), .wb_late(wb_late), .wb_tag(wb_tag), .wb_data(wb_data),
         .ld_cancel(ld_cancel), .ld_cancel_tag(ld_cancel_tag),
         .cmp_ld_valid(cmp_ld_valid), .cmp_ld_rob(cmp_ld_rob), .cmp_ld_exc(cmp_ld_exc),
         .cmp_st_valid(cmp_st_valid), .cmp_st_rob(cmp_st_rob), .cmp_st_exc(cmp_st_exc),
         .lq_commit(q[311:310]), .sq_commit(q[313:312]),
         .restore(q[314]), .restore_lq_tail(q[319:315]), .restore_sq_tail(q[324:320]), .flush_all(q[325]));

    always_ff @(posedge clk)
        out <= {lq_avail, sq_avail, disp_lq, disp_sq, ck_lq_tail, ck_sq_tail, st_known, dc_kill,
                dc_req_valid, dc_req_addr, dc_req_tag, dc_fill_ready, dc_st_valid, dc_st_addr,
                dc_st_data, dc_st_mask, wb_valid, wb_late, wb_tag, wb_data, ld_cancel, ld_cancel_tag,
                cmp_ld_valid, cmp_ld_rob, cmp_ld_exc, cmp_st_valid, cmp_st_rob, cmp_st_exc};
endmodule : OOC_LSU

//---------------------------------------------------------------------------
// OOC_ROB: the reorder buffer with its inputs and outputs registered (G0
// configuration: 24 entries, 4 completion ports); one input bus and one
// output bus, generated by the field list
//---------------------------------------------------------------------------
module OOC_ROB
    (
        input  logic          clk,
        input  logic          rst_n,
        input  logic [201:0]  in,
        output logic [191:0]  out
    );
    logic [201:0] q;
    always_ff @(posedge clk) q <= in;
    logic [1:0] rob_avail;
    logic [9:0] disp_rob;
    logic restore;
    logic [4:0] restore_rob;
    logic [2:0] restore_ckpt;
    logic [4:0] head_rob;
    logic head_ns;
    logic [1:0] cmt_valid;
    logic [1:0] cmt_wr;
    logic [9:0] cmt_arch;
    logic [11:0] cmt_new;
    logic [11:0] cmt_old;
    logic [75:0] cmt_pc;
    logic [1:0] cmt_ld_n;
    logic [1:0] cmt_st_n;
    logic [2:0] cmt_instret;
    logic trap;
    logic [4:0] trap_cause;
    logic [37:0] trap_pc;
    OOO_ROB #(.NROB(24), .ROBW(5), .VA(39), .TAGW(6), .CW(3), .NCMP(4)) u_rob
        (.clk(clk), .rst_n(rst_n),
         .disp_valid(q[1:0]), .disp_pc(q[77:2]), .disp_wr(q[79:78]), .disp_arch(q[89:80]),
         .disp_new(q[101:90]), .disp_old(q[113:102]), .disp_ld(q[115:114]), .disp_st(q[117:116]),
         .disp_fused(q[119:118]), .disp_ns(q[121:120]), .disp_exc(q[123:122]), .disp_cause(q[133:124]),
         .cmp_valid(q[137:134]), .cmp_rob(q[157:138]), .cmp_exc(q[161:158]), .cmp_cause(q[181:162]),
         .br_valid(q[183:182]), .br_rob(q[193:184]), .br_mispred(q[195:194]), .br_ckpt(q[201:196]),
         .rob_avail(rob_avail), .disp_rob(disp_rob), .restore(restore), .restore_rob(restore_rob),
         .restore_ckpt(restore_ckpt), .head_rob(head_rob), .head_ns(head_ns), .cmt_valid(cmt_valid),
         .cmt_wr(cmt_wr), .cmt_arch(cmt_arch), .cmt_new(cmt_new), .cmt_old(cmt_old),
         .cmt_pc(cmt_pc), .cmt_ld_n(cmt_ld_n), .cmt_st_n(cmt_st_n), .cmt_instret(cmt_instret),
         .trap(trap), .trap_cause(trap_cause), .trap_pc(trap_pc));
    always_ff @(posedge clk)
        out <= {rob_avail, disp_rob, restore, restore_rob, restore_ckpt, head_rob, head_ns, cmt_valid, cmt_wr, cmt_arch, cmt_new, cmt_old, cmt_pc, cmt_ld_n, cmt_st_n, cmt_instret, trap, trap_cause, trap_pc};
endmodule : OOC_ROB
