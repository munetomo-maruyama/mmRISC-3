//---------------------------------------------------------------------------
// OOC_WRAP.sv : register-to-register harnesses of the blocks of mmRISC-3
// for out-of-context synthesis (synth_ooo.tcl)
//
// A combinational block alone has only input-to-output paths, which the I/O
// delays of out-of-context synthesis can only guess at. Each harness puts
// flip-flops on every input and output, so that the timing reported is the
// block between registers, as it will sit in the core.
//
//   OOC_ALU2    the 1-cycle loop of an ALU port: each of the 2 sources
//               chosen among the register file, the port's own result of
//               the last cycle and the other ports' results (the bypass),
//               then the ALU and the branch comparison (fused after it),
//               into the result register that feeds the bypass again
//   OOC_FUSE    fusion of a group of 4 decoded instructions
//   OOC_PRF     the register file: read address -> data
//   OOC_RENAME  renaming with its inputs and outputs registered
//   OOC_LSU / OOC_ROB / OOC_FBUF / OOC_FTQ / OOC_FRONT / OOC_DEC / OOC_IQPL
//               the same, each with one input bus and one output bus
//   OOC_LSUDC   the LSU, the D$ adapter and mmRISC-2's D$ together
//   OOC_CTRL    the control (branch masks, go, recovery, commit)
//   OOC_DSREG   the DS register's payload: ready bits snooping the wakeups
//   OOC_FERS    the front end's restore with the FTQ it reads
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOC_ALU2
    #(
        parameter int FULL = 1          // 0: ALU1, the limited ALU (G0b L7)
    )
    (
        input  logic        clk,
        input  logic [63:0] prf1, prf2,           // register file data
        input  logic [63:0] ext0, ext1,           // the other ALU port and the load
        input  logic [1:0]  bsel1, bsel2,         // 0 prf, 1 own result, 2 ext0, 3 ext1
        input  logic [63:0] imm1, pc,
        input  logic [5:0]  op1,
        input  logic        uw1, word1, b1_imm, is_br, br_fused, br_res1_a,
        input  logic [1:0]  shift1, a1_sel, br_o_sel,
        input  logic [2:0]  br_op,
        output logic [63:0] out1,
        output logic        out_br
    );
    logic [63:0] p1, p2, e0, e1, i1, pcq, r1, s1, s2, n1;
    logic [1:0]  q1, q2, h1, as1, os;
    logic [2:0]  bo;
    logic [5:0]  o1;
    logic        u1, w1, bi, ib, bf, br1, nbr, rbr;

    always_ff @(posedge clk) begin
        p1 <= prf1; p2 <= prf2; e0 <= ext0; e1 <= ext1;
        q1 <= bsel1; q2 <= bsel2; i1 <= imm1; pcq <= pc;
        o1 <= op1; u1 <= uw1; w1 <= word1; bi <= b1_imm; ib <= is_br; bf <= br_fused; br1 <= br_res1_a;
        h1 <= shift1; as1 <= a1_sel; os <= br_o_sel; bo <= br_op;
        r1 <= n1; rbr <= nbr;
    end
    function automatic logic [63:0] byp(input logic [1:0] s, input logic [63:0] p);
        case (s)
            2'd1:    return r1;
            2'd2:    return e0;
            2'd3:    return e1;
            default: return p;
        endcase
    endfunction
    assign s1 = byp(q1, p1);
    assign s2 = byp(q2, p2);

    OOO_ALU2 #(.FULL(FULL[0])) u_alu2
        (.s1(s1), .s2(s2), .imm1(i1), .pc(pcq),
         .op1(o1), .uw1(u1), .shift1(h1), .word1(w1), .a1_sel(as1), .b1_imm(bi),
         .is_br(ib), .br_op(bo), .br_fused(bf), .br_res1_a(br1), .br_o_sel(os),
         .res1(n1), .take_branch(nbr));

    assign out1 = r1;
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
        input  logic [3:0][1:0]  msize, port,
        output logic [19:0]      out
    );
    logic             nf;
    logic [3:0]       va, sq, u1, u2;
    logic [3:0][2:0]  cl, opq;
    logic [3:0][4:0]  d, a, b;
    logic [3:0][11:0] im;
    logic [3:0][1:0]  ms, pt;
    logic             v0, v1;
    logic [1:0]       s0, s1;
    logic [3:0]       k0, k1;
    logic [1:0]       p0, p1;
    logic [2:0]       cn;
    always_ff @(posedge clk) begin
        nf <= no_fuse; va <= valid; sq <= seq; u1 <= use_rs1; u2 <= use_rs2;
        cl <= cls; opq <= op; d <= rd; a <= rs1; b <= rs2; im <= imm; ms <= msize; pt <= port;
        out <= {v0, s0, k0, p0, v1, s1, k1, p1, cn[1:0]};
    end
    OOO_FUSE u_fuse
        (.no_fuse(nf), .valid(va), .seq(sq), .cls(cl), .op(opq), .rd(d), .rs1(a), .rs2(b),
         .use_rs1(u1), .use_rs2(u2), .imm(im), .msize(ms), .port(pt),
         .u0_valid(v0), .u0_slot(s0), .u0_kind(k0), .u0_port(p0), .u1_valid(v1), .u1_slot(s1), .u1_kind(k1), .u1_port(p1),
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
        input  logic [5:0]        wk_valid,     // OOO_IQ's wakeup tags: not registered (late, 13 ns)
        input  logic [5:0][5:0]   wk_tag,
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
        fv <= free_valid; ft <= free_tag; rs <= restore; rid <= restore_id;
        cv <= cmt_valid; cw <= cmt_wr; ca <= cmt_arch; cn <= cmt_new; fa <= flush_all;
        out <= {rdy, ckid, os, ordy, od, oo};
    end
    OOO_RENAME #(.NREG(64), .TAGW(6), .NCKPT(6), .NWK(6)) u_ren
        (.clk(clk), .rst_n(rst_n), .ready(rdy), .in_valid(iv), .in_use(iu), .in_src(is),
         .in_wr(iw), .in_dst(id), .in_ckpt(ick), .out_ckpt_id(ckid), .out_src(os), .out_rdy(ordy),
         .out_dst(od), .out_old(oo), .wk_valid(wk_valid), .wk_tag(wk_tag), .free_valid(fv), .free_tag(ft),
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
        input  logic [332:0]  in,
        output logic [299:0]  out
    );
    logic [332:0] q;
    always_ff @(posedge clk) q <= in;

    // in (LQ 8, SQ 8: 3-bit entries, 4-bit tails)
    logic [1:0]   disp_valid, disp_ld, disp_st, iss_size, lq_commit, sq_commit;
    logic [9:0]   disp_rob;
    logic         iss_valid, iss_ld, iss_uns, dc_hit, dc_fill_valid, dc_st_ready, restore, flush_all;
    logic [2:0]   iss_lq, iss_sq, dc_fill_tag;
    logic [63:0]  iss_base, iss_data, dc_rdata, dc_fill_data;
    logic [11:0]  iss_imm;
    logic [5:0]   iss_dst;
    logic [3:0]   restore_lq_tail, restore_sq_tail;
    logic [5:0]   iss_bm, kill;
    assign {disp_valid, disp_ld, disp_st, disp_rob, iss_valid, iss_ld, iss_lq, iss_sq, iss_base, iss_imm,
            iss_data, iss_size, iss_uns, iss_dst, iss_bm, dc_hit, dc_rdata, dc_fill_valid, dc_fill_tag, dc_fill_data,
            dc_st_ready, lq_commit, sq_commit, restore, kill, restore_lq_tail, restore_sq_tail, flush_all} = q;

    // out
    logic [1:0]   lq_avail, sq_avail;
    logic [5:0]   disp_lq, disp_sq;
    logic [7:0]   ck_lq_tail, ck_sq_tail;
    logic [7:0]   st_known, dc_kill;
    logic         dc_req_valid, dc_fill_ready, dc_st_valid, wb_valid, wb_late, ld_cancel;
    logic         cmp_ld_valid, cmp_ld_exc, cmp_ld_rp, cmp_st_valid, cmp_st_exc;
    logic [39:0]  dc_req_addr, dc_st_addr;
    logic [2:0]   dc_req_tag;
    logic [63:0]  dc_st_data, wb_data;
    logic [7:0]   dc_st_mask;
    logic [5:0]   wb_tag, ld_cancel_tag;
    logic [4:0]   cmp_ld_rob, cmp_st_rob;

    OOO_LSU #(.NLQ(8), .NSQ(8), .PAW(40), .TAGW(6), .ROBW(5)) u_lsu
        (.clk(clk), .rst_n(rst_n),
         .disp_valid(disp_valid), .disp_ld(disp_ld), .disp_st(disp_st), .disp_rob(disp_rob),
         .lq_avail(lq_avail), .sq_avail(sq_avail), .disp_lq(disp_lq), .disp_sq(disp_sq),
         .ck_lq_tail(ck_lq_tail), .ck_sq_tail(ck_sq_tail),
         .iss_valid(iss_valid), .iss_ld(iss_ld), .iss_lq(iss_lq), .iss_sq(iss_sq),
         .iss_base(iss_base), .iss_imm(iss_imm), .iss_data(iss_data), .iss_size(iss_size),
         .iss_uns(iss_uns), .iss_dst(iss_dst), .iss_bm(iss_bm), .lsu_st_known(st_known),
         .dc_req_valid(dc_req_valid), .dc_req_addr(dc_req_addr), .dc_req_tag(dc_req_tag),
         .dc_hit(dc_hit), .dc_rdata(dc_rdata),
         .dc_fill_valid(dc_fill_valid), .dc_fill_tag(dc_fill_tag), .dc_fill_data(dc_fill_data),
         .dc_fill_ready(dc_fill_ready), .dc_kill(dc_kill),
         .dc_st_valid(dc_st_valid), .dc_st_addr(dc_st_addr), .dc_st_data(dc_st_data), .dc_st_mask(dc_st_mask),
         .dc_st_ready(dc_st_ready),
         .wb_valid(wb_valid), .wb_late(wb_late), .wb_tag(wb_tag), .wb_data(wb_data),
         .ld_cancel(ld_cancel), .ld_cancel_tag(ld_cancel_tag),
         .cmp_ld_valid(cmp_ld_valid), .cmp_ld_rob(cmp_ld_rob), .cmp_ld_exc(cmp_ld_exc), .cmp_ld_rp(cmp_ld_rp),
         .cmp_st_valid(cmp_st_valid), .cmp_st_rob(cmp_st_rob), .cmp_st_exc(cmp_st_exc),
         .lq_commit(lq_commit), .sq_commit(sq_commit),
         .restore(restore), .kill(kill), .restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_sq_tail), .flush_all(flush_all));

    always_ff @(posedge clk)
        out <= {lq_avail, sq_avail, disp_lq, disp_sq, ck_lq_tail, ck_sq_tail, st_known, dc_kill,
                dc_req_valid, dc_req_addr, dc_req_tag, dc_fill_ready, dc_st_valid, dc_st_addr,
                dc_st_data, dc_st_mask, wb_valid, wb_late, wb_tag, wb_data, ld_cancel, ld_cancel_tag,
                cmp_ld_valid, cmp_ld_rob, cmp_ld_exc, cmp_ld_rp, cmp_st_valid, cmp_st_rob, cmp_st_exc};
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
        input  logic [217:0]  in,
        output logic [242:0]  out
    );
    logic [217:0] q;
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
    logic replay;
    logic [37:0] replay_pc;
    logic [5:0] cmt_ftq;
    logic [2:0] rcv_ftq, rcv_end;
    OOO_ROB #(.NROB(24), .ROBW(5), .VA(39), .TAGW(6), .CW(3), .NCMP(4)) u_rob
        (.clk(clk), .rst_n(rst_n),
         .disp_valid(q[1:0]), .disp_pc(q[77:2]), .disp_wr(q[79:78]), .disp_arch(q[89:80]),
         .disp_new(q[101:90]), .disp_old(q[113:102]), .disp_ld(q[115:114]), .disp_st(q[117:116]),
         .disp_fused(q[119:118]), .disp_ns(q[121:120]), .disp_exc(q[123:122]), .disp_cause(q[133:124]),
         .cmp_valid(q[137:134]), .cmp_rob(q[157:138]), .cmp_exc(q[161:158]), .cmp_cause(q[181:162]),
         .br_valid(q[183:182]), .br_rob(q[193:184]), .br_mispred(q[195:194]), .br_ckpt(q[201:196]), .disp_len(q[207:202]), .cmp_rp(q[211:208]), .disp_ftq(q[217:212]), .cmt_ftq(cmt_ftq),
         .rob_avail(rob_avail), .disp_rob(disp_rob), .restore(restore), .restore_rob(restore_rob),
         .restore_ckpt(restore_ckpt), .head_rob(head_rob), .head_ns(head_ns), .cmt_valid(cmt_valid),
         .cmt_wr(cmt_wr), .cmt_arch(cmt_arch), .cmt_new(cmt_new), .cmt_old(cmt_old),
         .cmt_pc(cmt_pc), .cmt_ld_n(cmt_ld_n), .cmt_st_n(cmt_st_n), .cmt_instret(cmt_instret),
         .trap(trap), .trap_cause(trap_cause), .trap_pc(trap_pc),
         .replay(replay), .replay_pc(replay_pc), .rcv_ftq(rcv_ftq), .rcv_end(rcv_end));
    always_ff @(posedge clk)
        out <= {rob_avail, disp_rob, restore, restore_rob, restore_ckpt, head_rob, head_ns, cmt_valid, cmt_wr, cmt_arch, cmt_new, cmt_old, cmt_pc, cmt_ld_n, cmt_st_n, cmt_instret, trap, trap_cause, trap_pc, replay, replay_pc, cmt_ftq, rcv_ftq, rcv_end};
endmodule : OOC_ROB

//---------------------------------------------------------------------------
// OOC_FBUF: the fetch buffer with its inputs and outputs registered (4
// blocks, 4 instructions out). Decode takes all the instructions given
// unless it is stalled (take, a flip-flop in the core as well), so the path
// that counts runs from the buffer's state through the window and the
// instruction lengths to the count taken, and back into the head pointer
// and parcel; one input bus and one output bus, generated by the field list
//---------------------------------------------------------------------------
module OOC_FBUF
    (
        input  logic          clk,
        input  logic          rst_n,
        input  logic [140:0]  in,
        output logic [168:0]  out
    );
    logic [140:0] q;
    always_ff @(posedge clk) q <= in;
    logic in_ready;
    logic [3:0] out_valid;
    logic [127:0] out_inst;
    logic [3:0] out_rvc;
    logic [11:0] out_off;
    logic [11:0] out_ftq;
    logic [3:0] out_taken;
    logic [3:0] out_seq;
    logic [2:0] consume;
    always @(*) begin
        consume = 3'd0;
        if (q[140])
            for (int i = 0; i < 4; i++) if (out_valid[i]) consume = 3'(i + 1);
    end
    OOO_FBUF #(.NB(4), .FTQW(3)) u_fbuf
        (
         .clk(clk), .rst_n(rst_n), .flush(q[0]), .in_valid(q[1]), .in_data(q[129:2]), .in_start(q[132:130]),
         .in_end(q[135:133]), .in_taken(q[136]), .in_ftq(q[139:137]), .consume(consume), .in_ready(in_ready),
         .out_valid(out_valid), .out_inst(out_inst), .out_rvc(out_rvc), .out_off(out_off), .out_ftq(out_ftq),
         .out_taken(out_taken), .out_seq(out_seq));
    always_ff @(posedge clk)
        out <= {in_ready, out_valid, out_inst, out_rvc, out_off, out_ftq, out_taken, out_seq};
endmodule : OOC_FBUF

//---------------------------------------------------------------------------
// OOC_FTQ: the fetch target queue with its inputs and outputs registered
// (8 entries, 32 bits of predictor state each); one input bus and one
// output bus, generated by the field list
//---------------------------------------------------------------------------
module OOC_FTQ
    (
        input  logic          clk,
        input  logic          rst_n,
        input  logic [128:0]  in,
        output logic [191:0]  out
    );
    logic [128:0] q;
    always_ff @(posedge clk) q <= in;
    logic push_ready;
    logic [2:0] push_idx;
    logic [75:0] rd_pc;
    logic [37:0] br_pc;
    logic [37:0] br_target;
    logic br_taken;
    logic [2:0] br_end;
    logic [31:0] br_meta;
    OOO_FTQ #(.NFTQ(8), .FTQW(3), .VA(39), .MW(32)) u_ftq
        (
         .clk(clk), .rst_n(rst_n), .push_valid(q[0]), .push_pc(q[38:1]), .push_target(q[76:39]),
         .push_taken(q[77]), .push_end(q[80:78]), .push_meta(q[112:81]), .rd_idx(q[118:113]),
         .br_idx(q[121:119]), .pop(q[123:122]), .restore(q[124]), .restore_idx(q[127:125]),
         .flush_all(q[128]), .push_ready(push_ready), .push_idx(push_idx), .rd_pc(rd_pc), .br_pc(br_pc),
         .br_target(br_target), .br_taken(br_taken), .br_end(br_end), .br_meta(br_meta));
    always_ff @(posedge clk)
        out <= {push_ready, push_idx, rd_pc, br_pc, br_target, br_taken, br_end, br_meta};
endmodule : OOC_FTQ

//---------------------------------------------------------------------------
// OOC_FRONT: the front end (OOO_FETCH with the uBTB, predecode, TAGE-S,
// BTB and RAS) with its inputs and outputs registered. The I$ answer comes
// from a register in the core too (the I$'s output); its ready and the
// fetch buffer's credit are registered here, so the I$'s own tag compare in
// front of `ic_req_ready` is not in the path measured. One input bus and
// one output bus, generated by the field list
//---------------------------------------------------------------------------
module OOC_FRONT
    (
        input  logic          clk,
        input  logic          rst_n,
        input  logic [684:0]  in,
        output logic [559:0]  out
    );
    logic [684:0] q;
    always_ff @(posedge clk) q <= in;
    logic ic_req_valid;
    logic [37:0] ic_req_pc;
    logic out_valid;
    logic [37:0] out_pc;
    logic [127:0] out_data;
    logic [2:0] out_end;
    logic out_taken;
    logic [37:0] out_next;
    logic [269:0] out_tmeta;
    logic [3:0] out_ras_ptr;
    logic [37:0] out_ras_val;
    OOO_FETCH #(.VA(39), .MW(270)) u_fetch
        (
         .clk(clk), .rst_n(rst_n), .be_stop(q[684]), .be_redirect(q[0]), .be_pc(q[38:1]), .be_hist(q[108:39]),
         .be_hist_n(q[110:109]), .be_hist_bits(q[113:111]), .be_ras_ptr(q[117:114]), .be_ras_val(q[155:118]),
         .be_ras_push(q[156]), .be_ras_addr(q[194:157]), .be_ras_pop(q[195]), .credit(q[199:196]),
         .ic_req_ready(q[200]), .ic_resp_valid(q[201]), .ic_resp_data(q[329:202]), .up_valid(q[330]),
         .up_meta(q[600:331]), .up_ex(q[603:601]), .up_tk(q[606:604]), .bt_valid(q[607]), .bt_pc(q[645:608]),
         .bt_tgt(q[683:646]), .ic_req_valid(ic_req_valid), .ic_req_pc(ic_req_pc), .out_valid(out_valid),
         .out_pc(out_pc), .out_data(out_data), .out_end(out_end), .out_taken(out_taken), .out_next(out_next),
         .out_tmeta(out_tmeta), .out_ras_ptr(out_ras_ptr), .out_ras_val(out_ras_val));
    always_ff @(posedge clk)
        out <= {ic_req_valid, ic_req_pc, out_valid, out_pc, out_data, out_end, out_taken, out_next, out_tmeta, out_ras_ptr, out_ras_val};
endmodule : OOC_FRONT

//---------------------------------------------------------------------------
// OOC_DEC: decode of 4 instructions (OOO_DEC: 4 x CORE_DECOMP + CORE_DEC
// and the fields for fusion, the issue queue and the ROB) between the fetch
// buffer's output and the D1 / D2 register, every output kept (the FP and
// CSR fields too, which Phase 1 leaves unused); one input bus and one
// output bus, generated by the field list
//---------------------------------------------------------------------------
module OOC_DEC
    (
        input  logic          clk,
        input  logic          rst_n,
        input  logic [131:0]  in,
        output logic [563:0]  out
    );
    logic [131:0] q;
    always_ff @(posedge clk) q <= in;
    logic [3:0] illegal;
    logic [3:0][2:0] cls;
    logic [3:0][2:0] op;
    logic [3:0][4:0] rd;
    logic [3:0][4:0] rs1;
    logic [3:0][4:0] rs2;
    logic [3:0] use_rs1;
    logic [3:0] use_rs2;
    logic [3:0][31:0] imm;
    logic [3:0][1:0] port;
    logic [3:0] lat2;
    logic [3:0] ext_ans;
    logic [3:0] nonspec;
    logic [3:0][5:0] alu_op;
    logic [3:0] a_uw;
    logic [3:0][1:0] a_shift;
    logic [3:0][1:0] a_sel;
    logic [3:0] b_sel;
    logic [3:0] word_op;
    logic [3:0] is_branch;
    logic [3:0] is_jal;
    logic [3:0] is_jalr;
    logic [3:0][2:0] br_op;
    logic [3:0][3:0] mdu_op;
    logic [3:0][4:0] mem_cmd;
    logic [3:0][1:0] mem_size;
    logic [3:0] mem_signed;
    logic [3:0][7:0] sys;
    logic [3:0] is_sfence;
    logic [3:0] is_csr;
    logic [3:0][11:0] csr_addr;
    logic [3:0][1:0] csr_op;
    logic [3:0] csr_imm_sel;
    logic [3:0] csr_wr;
    logic [3:0] csr_rd;
    logic [3:0] is_fp;
    logic [3:0][4:0] fp_op;
    logic [3:0] fp_fmt;
    logic [3:0][2:0] fp_rm;
    logic [3:0][2:0] use_fs;
    logic [3:0][4:0] rs3;
    logic [3:0] fp_we_rd;
    logic [3:0] fp_int_signed;
    logic [3:0] fp_int_w;
    logic [3:0] cut;
    OOO_DEC u_dec
        (.in_inst(q[127:0]), .in_rvc(q[131:128]), .illegal(illegal), .cls(cls), .op(op), .rd(rd), .rs1(rs1),
         .rs2(rs2), .use_rs1(use_rs1), .use_rs2(use_rs2), .imm(imm), .port(port),
         .lat2(lat2), .ext_ans(ext_ans), .nonspec(nonspec), .alu_op(alu_op), .a_uw(a_uw), .a_shift(a_shift),
         .a_sel(a_sel), .b_sel(b_sel), .word_op(word_op), .is_branch(is_branch), .is_jal(is_jal),
         .is_jalr(is_jalr), .br_op(br_op), .mdu_op(mdu_op), .mem_cmd(mem_cmd), .mem_size(mem_size),
         .mem_signed(mem_signed), .sys(sys), .is_sfence(is_sfence), .is_csr(is_csr), .csr_addr(csr_addr),
         .csr_op(csr_op), .csr_imm_sel(csr_imm_sel), .csr_wr(csr_wr), .csr_rd(csr_rd), .is_fp(is_fp),
         .fp_op(fp_op), .fp_fmt(fp_fmt), .fp_rm(fp_rm), .use_fs(use_fs), .rs3(rs3), .fp_we_rd(fp_we_rd),
         .fp_int_signed(fp_int_signed), .fp_int_w(fp_int_w), .cut(cut));
    always_ff @(posedge clk)
        out <= {illegal, cls, op, rd, rs1, rs2, use_rs1, use_rs2, imm, port, lat2, ext_ans, nonspec, alu_op, a_uw, a_shift, a_sel, b_sel, word_op, is_branch, is_jal, is_jalr, br_op, mdu_op, mem_cmd, mem_size, mem_signed, sys, is_sfence, is_csr, csr_addr, csr_op, csr_imm_sel, csr_wr, csr_rd, is_fp, fp_op, fp_fmt, fp_rm, use_fs, rs3, fp_we_rd, fp_int_signed, fp_int_w, cut};
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_rst;
    assign unused_rst = rst_n;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule : OOC_DEC

//---------------------------------------------------------------------------
// OOC_IQPL: the payload of the issue queue (10 entries, 96-bit records)
// with its inputs and outputs registered; the read addresses get a second
// register inside the block, as the grants come late in IS
//---------------------------------------------------------------------------
module OOC_IQPL
    (
        input  logic          clk,
        input  logic          rst_n,
        input  logic [213:0]  in,
        output logic [287:0]  out
    );
    logic [213:0] q;
    always_ff @(posedge clk) q <= in;
    logic [1:0]       wr_valid;
    logic [1:0][3:0]  wr_entry;
    logic [1:0][95:0] wr_data;
    logic [2:0][3:0]  iss_entry;
    logic [2:0][95:0] rr_data;
    assign {wr_valid, wr_entry, wr_data, iss_entry} = q;
    OOO_IQPL #(.N(10), .W(96), .W2(48)) u_iqpl
        (.clk(clk), .rst_n(rst_n), .wr_valid(wr_valid), .wr_entry(wr_entry), .wr_data(wr_data),
         .iss_entry(iss_entry), .rr_data(rr_data));
    always_ff @(posedge clk) out <= rr_data;
endmodule : OOC_IQPL

//---------------------------------------------------------------------------
// OOC_LSUDC: OOO_LSU, OOO_DCAD and mmRISC-2's DCACHE (RTL/CPU/CACHE) as in
// the core, with the LSU's core side and the D$'s AXI4 bus registered. The
// adapter's size is its row in the hierarchical report (summary.txt lists
// the instances); the path that is new is the D$'s stage-1 hit (d_hit_now)
// through the LSU's M into wb_data and ld_cancel. The peripheral bus is
// tied off, and the LSU's dc_kill is not used by the adapter.
//---------------------------------------------------------------------------
module OOC_LSUDC
    (
        input  logic          clk,
        input  logic          rst_n,
        input  logic [272:0]  in,
        output logic [325:0]  out
    );
    logic [272:0] q;
    always_ff @(posedge clk) q <= in;

    // LSU core side, in
    logic [1:0]       disp_valid, disp_ld, disp_st, lq_commit, sq_commit, iss_size;
    logic [1:0][4:0]  disp_rob;
    logic             iss_valid, iss_ld, iss_uns, restore, flush_all;
    logic [2:0]       iss_lq, iss_sq;
    logic [63:0]      iss_base, iss_data;
    logic [11:0]      iss_imm;
    logic [5:0]       iss_dst;
    logic [3:0]       restore_lq_tail, restore_sq_tail;
    logic [5:0]       iss_bm, kill;
    // AXI4, in
    logic             awready, wready, bvalid, arready, rlast, rvalid;
    logic [1:0]       bresp, rresp;
    logic [63:0]      rdata;
    assign {disp_valid, disp_ld, disp_st, disp_rob, iss_valid, iss_ld, iss_lq, iss_sq, iss_base, iss_imm,
            iss_data, iss_size, iss_uns, iss_dst, iss_bm, lq_commit, sq_commit, restore, kill, restore_lq_tail,
            restore_sq_tail, flush_all,
            awready, wready, bresp, bvalid, arready, rdata, rresp, rlast, rvalid} = q;

    // LSU core side, out
    logic [1:0]       lq_avail, sq_avail;
    logic [1:0][2:0]  disp_lq, disp_sq;
    logic [1:0][3:0]  ck_lq_tail, ck_sq_tail;
    logic [7:0]       st_known;
    logic             wb_valid, wb_late, ld_cancel, cmp_ld_valid, cmp_ld_exc, cmp_ld_rp, cmp_st_valid, cmp_st_exc;
    logic [5:0]       wb_tag, ld_cancel_tag;
    logic [63:0]      wb_data;
    logic [4:0]       cmp_ld_rob, cmp_st_rob;
    // AXI4, out
    logic [3:0]       awid, arid;
    logic [39:0]      awaddr, araddr;
    logic [7:0]       awlen, arlen, wstrb;
    logic [2:0]       awsize, arsize;
    logic [1:0]       awburst, arburst;
    logic             awvalid, wlast, wvalid, bready, arvalid, rready;
    logic [63:0]      wdata;

    // between the blocks
    logic             dc_req_valid, dc_hit, dc_fill_valid, dc_fill_ready, dc_st_valid, dc_st_ready;
    logic [39:0]      dc_req_addr, dc_st_addr;
    logic [2:0]       dc_req_tag, dc_fill_tag;
    logic [63:0]      dc_rdata, dc_fill_data, dc_st_data;
    logic [7:0]       dc_st_mask;
    logic             d_req_valid, d_req_ready, d_req_cancel, d_resp_valid, d_hit_now;
    logic [39:0]      d_req_addr, d_req_paddr;
    logic [1:0]       d_req_size;
    logic [4:0]       d_req_cmd;
    logic [63:0]      d_req_wdata, d_resp_data, d_hit_now_data;

    OOO_LSU #(.NLQ(8), .NSQ(8), .PAW(40), .TAGW(6), .ROBW(5)) u_lsu
        (.clk(clk), .rst_n(rst_n),
         .disp_valid(disp_valid), .disp_ld(disp_ld), .disp_st(disp_st), .disp_rob(disp_rob),
         .lq_avail(lq_avail), .sq_avail(sq_avail), .disp_lq(disp_lq), .disp_sq(disp_sq),
         .ck_lq_tail(ck_lq_tail), .ck_sq_tail(ck_sq_tail),
         .iss_valid(iss_valid), .iss_ld(iss_ld), .iss_lq(iss_lq), .iss_sq(iss_sq),
         .iss_base(iss_base), .iss_imm(iss_imm), .iss_data(iss_data), .iss_size(iss_size),
         .iss_uns(iss_uns), .iss_dst(iss_dst), .iss_bm(iss_bm), .lsu_st_known(st_known),
         .dc_req_valid(dc_req_valid), .dc_req_addr(dc_req_addr), .dc_req_tag(dc_req_tag),
         .dc_hit(dc_hit), .dc_rdata(dc_rdata),
         .dc_fill_valid(dc_fill_valid), .dc_fill_tag(dc_fill_tag), .dc_fill_data(dc_fill_data),
         .dc_fill_ready(dc_fill_ready), .dc_kill(),
         .dc_st_valid(dc_st_valid), .dc_st_addr(dc_st_addr), .dc_st_data(dc_st_data), .dc_st_mask(dc_st_mask),
         .dc_st_ready(dc_st_ready),
         .wb_valid(wb_valid), .wb_late(wb_late), .wb_tag(wb_tag), .wb_data(wb_data),
         .ld_cancel(ld_cancel), .ld_cancel_tag(ld_cancel_tag),
         .cmp_ld_valid(cmp_ld_valid), .cmp_ld_rob(cmp_ld_rob), .cmp_ld_exc(cmp_ld_exc), .cmp_ld_rp(cmp_ld_rp),
         .cmp_st_valid(cmp_st_valid), .cmp_st_rob(cmp_st_rob), .cmp_st_exc(cmp_st_exc),
         .lq_commit(lq_commit), .sq_commit(sq_commit),
         .restore(restore), .kill(kill), .restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_sq_tail),
         .flush_all(flush_all));

    OOO_DCAD #(.NLQ(8), .PAW(40), .DEPTH(8)) u_dcad
        (.clk(clk), .rst_n(rst_n),
         .dc_req_valid(dc_req_valid), .dc_req_addr(dc_req_addr), .dc_req_tag(dc_req_tag),
         .dc_hit(dc_hit), .dc_rdata(dc_rdata),
         .dc_fill_valid(dc_fill_valid), .dc_fill_tag(dc_fill_tag), .dc_fill_data(dc_fill_data),
         .dc_fill_ready(dc_fill_ready),
         .dc_st_valid(dc_st_valid), .dc_st_addr(dc_st_addr), .dc_st_data(dc_st_data), .dc_st_mask(dc_st_mask),
         .dc_st_ready(dc_st_ready),
         .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
         .d_req_size(d_req_size), .d_req_cmd(d_req_cmd), .d_req_wdata(d_req_wdata),
         .d_req_paddr(d_req_paddr), .d_req_cancel(d_req_cancel),
         .d_resp_valid(d_resp_valid), .d_resp_data(d_resp_data),
         .d_hit_now(d_hit_now), .d_hit_now_data(d_hit_now_data));

    DCACHE #(.PADDR_WIDTH(40), .ROB_DEPTH(8)) u_dc
        (.clk(clk), .rst_n(rst_n),
         .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
         .d_req_size(d_req_size), .d_req_cmd(d_req_cmd), .d_req_wdata(d_req_wdata),
         .d_req_paddr(d_req_paddr), .d_req_cancel(d_req_cancel),
         .d_resp_valid(d_resp_valid), .d_resp_drop(), .d_resp_data(d_resp_data), .d_resp_error(),
         .d_hit_now(d_hit_now), .d_hit_now_data(d_hit_now_data),
         .m_axi4_awid(awid), .m_axi4_awaddr(awaddr), .m_axi4_awlen(awlen), .m_axi4_awsize(awsize),
         .m_axi4_awburst(awburst), .m_axi4_awvalid(awvalid), .m_axi4_awready(awready),
         .m_axi4_wdata(wdata), .m_axi4_wstrb(wstrb), .m_axi4_wlast(wlast), .m_axi4_wvalid(wvalid),
         .m_axi4_wready(wready), .m_axi4_bresp(bresp), .m_axi4_bvalid(bvalid), .m_axi4_bready(bready),
         .m_axi4_arid(arid), .m_axi4_araddr(araddr), .m_axi4_arlen(arlen), .m_axi4_arsize(arsize),
         .m_axi4_arburst(arburst), .m_axi4_arvalid(arvalid), .m_axi4_arready(arready),
         .m_axi4_rdata(rdata), .m_axi4_rresp(rresp), .m_axi4_rlast(rlast), .m_axi4_rvalid(rvalid),
         .m_axi4_rready(rready),
         .m_axil_awaddr(), .m_axil_awvalid(), .m_axil_awready(1'b0), .m_axil_wdata(), .m_axil_wstrb(),
         .m_axil_wvalid(), .m_axil_wready(1'b0), .m_axil_bresp(2'b00), .m_axil_bvalid(1'b0), .m_axil_bready(),
         .m_axil_araddr(), .m_axil_arvalid(), .m_axil_arready(1'b0), .m_axil_rdata(64'd0), .m_axil_rresp(2'b00),
         .m_axil_rvalid(1'b0), .m_axil_rready(),
         .ev_miss(), .ev_vic_copy());

    always_ff @(posedge clk)
        out <= {lq_avail, sq_avail, disp_lq, disp_sq, ck_lq_tail, ck_sq_tail, st_known,
                wb_valid, wb_late, wb_tag, wb_data, ld_cancel, ld_cancel_tag,
                cmp_ld_valid, cmp_ld_rob, cmp_ld_exc, cmp_ld_rp, cmp_st_valid, cmp_st_rob, cmp_st_exc,
                awid, awaddr, awlen, awsize, awburst, awvalid, wdata, wstrb, wlast, wvalid, bready,
                arid, araddr, arlen, arsize, arburst, arvalid, rready};
endmodule : OOC_LSUDC

//---------------------------------------------------------------------------
// OOC_CTRL: the control's first part (6 checkpoints) with its inputs and
// outputs registered
//---------------------------------------------------------------------------
module OOC_CTRL
    (
        input  logic          clk,
        input  logic          rst_n,
        input  logic [240:0]  in,
        output logic [114:0]  out
    );
    logic [240:0] q;
    always_ff @(posedge clk) q <= in;
    logic [1:0]       r_valid, r_ckpt, ds_ld, ds_st, rob_avail, iq_avail, lq_avail, sq_avail, br_valid, br_mispred;
    logic [1:0][2:0]  r_ckpt_id, ds_ftq, br_ckpt;
    logic             r_ren_ready, rob_restore, trap, replay, head_ns, iss_ns;
    logic [1:0]       cmt_valid, cmt_wr, cmt_ld_n, cmt_st_n;
    logic [1:0][5:0]  cmt_old;
    logic [1:0][2:0]  cmt_ftq;
    logic [1:0][3:0]  ck_lq_tail, ck_sq_tail;
    logic [1:0][37:0] br_next;
    logic [2:0]       rob_restore_ckpt;
    logic [37:0]      replay_pc, trap_vec;
    assign {r_valid, r_ckpt, r_ckpt_id, r_ren_ready, ds_ld, ds_st, ds_ftq, rob_avail, iq_avail, lq_avail, sq_avail,
            ck_lq_tail, ck_sq_tail, br_valid, br_mispred, br_ckpt, br_next, rob_restore, rob_restore_ckpt, trap,
            replay, replay_pc, trap_vec, head_ns, cmt_valid, cmt_wr, cmt_old, cmt_ld_n, cmt_st_n, cmt_ftq, iss_ns} = q;
    logic [1:0]       r_go, ds_valid, d_go;
    logic [1:0][5:0]  d_bmask;
    logic             flush_all, restore, restore_port, fe_redirect, fe_flush, ns_ok, ds_load;
    logic [1:0]       free_valid, lq_commit, sq_commit, ftq_pop;
    logic [1:0][5:0]  free_tag;
    logic [2:0]       restore_id, restore_ftq;
    logic [3:0]       restore_lq_tail, restore_sq_tail;
    logic [5:0]       kill, clr, live;
    logic [37:0]      fe_pc;
    OOO_CTRL #(.NCKPT(6), .CW(3), .VA(39), .FTQW(3), .LW(3), .TAGW(6)) u_ctrl
        (.clk(clk), .rst_n(rst_n),
         .r_valid(r_valid), .r_ckpt(r_ckpt), .r_ckpt_id(r_ckpt_id), .r_ren_ready(r_ren_ready), .r_go(r_go),
         .ds_valid(ds_valid), .ds_load(ds_load), .ds_ld(ds_ld), .ds_st(ds_st), .ds_ftq(ds_ftq),
         .rob_avail(rob_avail), .iq_avail(iq_avail), .lq_avail(lq_avail), .sq_avail(sq_avail),
         .ck_lq_tail(ck_lq_tail), .ck_sq_tail(ck_sq_tail), .d_go(d_go), .d_bmask(d_bmask),
         .br_valid(br_valid), .br_mispred(br_mispred), .br_ckpt(br_ckpt), .br_next(br_next),
         .rob_restore(rob_restore), .rob_restore_ckpt(rob_restore_ckpt), .trap(trap), .replay(replay),
         .replay_pc(replay_pc), .trap_vec(trap_vec), .head_ns(head_ns), .cmt_valid(cmt_valid), .cmt_wr(cmt_wr),
         .cmt_old(cmt_old), .cmt_ld_n(cmt_ld_n), .cmt_st_n(cmt_st_n), .cmt_ftq(cmt_ftq), .iss_ns(iss_ns), .ns_ok(ns_ok),
         .fe_flush(fe_flush),
         .flush_all(flush_all), .restore(restore), .restore_id(restore_id), .restore_port(restore_port), .restore_lq_tail(restore_lq_tail),
         .restore_sq_tail(restore_sq_tail), .restore_ftq(restore_ftq), .kill(kill), .clr(clr),
         .fe_redirect(fe_redirect), .fe_pc(fe_pc), .live(live), .free_valid(free_valid), .free_tag(free_tag),
         .lq_commit(lq_commit), .sq_commit(sq_commit), .ftq_pop(ftq_pop));
    always_ff @(posedge clk)
        out <= {r_go, ds_valid, ds_load, d_go, d_bmask, flush_all, restore, restore_port, restore_id, restore_lq_tail, restore_sq_tail,
                restore_ftq, kill, clr, fe_redirect, fe_pc, live, ns_ok, fe_flush, free_valid, free_tag, lq_commit,
                sq_commit, ftq_pop};
endmodule : OOC_CTRL

//---------------------------------------------------------------------------
// OOC_DSREG: the DS register's payload (Plan/OOC.md 20) with its inputs and
// outputs registered, but for the wakeup tags, which come straight from
// OOO_IQ's select (late: synth_ooo.tcl gives them 13 ns). The payload is 8
// bits a slot here: the rest are flip-flops with an enable, no LUTs.
//---------------------------------------------------------------------------
module OOC_DSREG
    (
        input  logic              clk,
        input  logic              rst_n,
        input  logic [48:0]       in,
        input  logic [5:0]        wk_valid,     // OOO_IQ's wakeup tags: not registered
        input  logic [5:0][5:0]   wk_tag,
        output logic [47:0]       out
    );
    logic [48:0] q;
    always_ff @(posedge clk) q <= in;
    logic                  load;
    logic [1:0][1:0][5:0]  in_src, ds_src;
    logic [1:0][1:0]       in_use, in_rdy, ds_use, ds_rdy;
    logic [1:0][7:0]       in_data, ds_data;
    assign {load, in_src, in_use, in_rdy, in_data} = q;
    OOO_DSREG #(.W(8), .TAGW(6), .NB(6)) u_ds
        (.clk(clk), .rst_n(rst_n), .load(load), .in_src(in_src), .in_use(in_use), .in_rdy(in_rdy),
         .in_data(in_data), .wk_valid(wk_valid), .wk_tag(wk_tag),
         .ds_src(ds_src), .ds_use(ds_use), .ds_rdy(ds_rdy), .ds_data(ds_data));
    always_ff @(posedge clk) out <= {ds_src, ds_use, ds_rdy, ds_data};
endmodule : OOC_DSREG

//---------------------------------------------------------------------------
// OOC_FERS: the front end's restore (Plan/OOC.md 21) with the FTQ it reads
// (8 entries of the front end's 312 bits: TAGE's 270, the RAS snapshot 42),
// inputs and outputs registered: the path is the restore point's register
// -> the FTQ's read (LUTRAM) -> the history's slot bits and the RAS address
// -> be_* (into OOO_FETCH's TAGE history and RAS in the core)
//---------------------------------------------------------------------------
module OOC_FERS
    (
        input  logic          clk,
        input  logic          rst_n,
        input  logic [461:0]  in,
        output logic [199:0]  out
    );
    logic [461:0] q;
    always_ff @(posedge clk) q <= in;
    // the FTQ's side
    logic             push_valid, push_taken, restore, flush_all;
    logic [37:0]      push_pc, push_target;
    logic [2:0]       push_end, restore_idx;
    logic [311:0]     push_meta;
    logic [1:0]       pop;
    // the restore's side
    logic             fe_redirect, fe_flush, restore_port;
    logic [37:0]      fe_pc;
    logic [2:0]       restore_ftq, rcv_ftq, rcv_end;
    logic [1:0][2:0]  br_e;
    logic [1:0]       br_taken, br_call, br_ret;
    assign {push_valid, push_pc, push_target, push_taken, push_end, push_meta, pop, restore, restore_idx, flush_all,
            fe_redirect, fe_flush, fe_pc, restore_ftq, restore_port, br_e, br_taken, br_call, br_ret, rcv_ftq, rcv_end} = q;

    logic             push_ready;
    logic [2:0]       push_idx, rs_idx;
    logic [37:0]      ft_pc, ft_target;
    logic             ft_taken;
    logic [2:0]       ft_end;
    logic [311:0]     ft_meta;
    OOO_FTQ #(.NFTQ(8), .FTQW(3), .VA(39), .MW(312)) u_ftq
        (.clk(clk), .rst_n(rst_n), .push_ready(push_ready), .push_valid(push_valid), .push_pc(push_pc),
         .push_target(push_target), .push_taken(push_taken), .push_end(push_end), .push_meta(push_meta),
         .push_idx(push_idx), .rd_idx('0), .rd_pc(), .br_idx(rs_idx), .br_pc(ft_pc), .br_target(ft_target),
         .br_taken(ft_taken), .br_end(ft_end), .br_meta(ft_meta), .pop(pop), .restore(restore),
         .restore_idx(restore_idx), .flush_all(flush_all));

    // the metadata: TAGE's (history, predictions, slot valid bits, parcels at its top), then the RAS snapshot
    logic             be_redirect, be_ras_push, be_ras_pop;
    logic [37:0]      be_pc, be_ras_val, be_ras_addr;
    logic [69:0]      be_hist;
    logic [1:0]       be_hist_n;
    logic [2:0]       be_hist_bits;
    logic [3:0]       be_ras_ptr;
    OOO_FERS #(.VA(39), .FTQW(3), .HL(70), .RW(4)) u_fers
        (.clk(clk), .rst_n(rst_n), .fe_redirect(fe_redirect), .fe_flush(fe_flush), .fe_pc(fe_pc),
         .restore_ftq(restore_ftq), .restore_port(restore_port), .br_e(br_e), .br_taken(br_taken),
         .br_call(br_call), .br_ret(br_ret), .rcv_ftq(rcv_ftq), .rcv_end(rcv_end),
         .rs_idx(rs_idx), .ft_line(ft_pc[37:3]), .ft_hist(ft_meta[311:242]),
         .ft_sv(ft_meta[238:236]), .ft_par(ft_meta[235:227]), .ft_ras_ptr(ft_meta[41:38]), .ft_ras_val(ft_meta[37:0]),
         .be_redirect(be_redirect), .be_pc(be_pc), .be_hist(be_hist), .be_hist_n(be_hist_n),
         .be_hist_bits(be_hist_bits), .be_ras_ptr(be_ras_ptr), .be_ras_val(be_ras_val),
         .be_ras_push(be_ras_push), .be_ras_addr(be_ras_addr), .be_ras_pop(be_ras_pop));
    always_ff @(posedge clk)
        out <= {push_ready, push_idx, be_redirect, be_pc, be_hist, be_hist_n, be_hist_bits, be_ras_ptr, be_ras_val,
                be_ras_push, be_ras_addr, be_ras_pop};
endmodule : OOC_FERS
