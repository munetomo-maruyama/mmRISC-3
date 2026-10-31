//---------------------------------------------------------------------------
// OOO_CORE.sv
//
// The out-of-order integer core of mmRISC-3 (Plan/CORE.md 1), brought up
// step by step (Plan/CORE.md 5). This is B4: ALU µops (B2), loads and
// stores (B3), port 0's CSR, system, multiply and MDU units and traps (B4).
//
//   front end  OOO_FRONT (fetch, FTQ, restore, fetch buffer, D1a / D1b,
//              the group register; the target array and the pc array)
//   D2         the group rotated to its oldest valid slot (the group
//              register keeps what D2 left in its place), OOO_FUSE (fusion
//              off: no_fuse), OOO_RENAME, OOO_CTRL's r_go; g_take back to
//              the front end
//   DS         OOO_DSREG (tags, ready snoop, and the µop's payload: the
//              record of OOO_IQPL, pc, destination, ...); OOO_CTRL's d_go
//              writes OOO_ROB, OOO_IQ and OOO_IQPL
//   IS         OOO_IQ: port 0 (ALU0, OOO_ALU2 full; OOO_CSRU, OOO_SYS,
//              OOO_PMUL, OOO_MDUP), port 1 (ALU1, FULL 0), port 2 (OOO_LSU)
//   RR         OOO_STAGE; OOO_PRF (2 reads a port), OOO_IQPL's record, the
//              pc array and the target array (OOO_FRONT)
//   EX         OOO_STAGE; the operands from the RR read or the 3 write-back
//              registers (the bypass), OOO_ALU2, branch resolution (the
//              direction against the prediction, a jalr's target against
//              the target array) to OOO_CTRL, OOO_ROB and OOO_FRONT (FERS,
//              the TAGE outcomes, the BTB); the register file written at
//              the edge the result enters its write-back register (Plan/
//              CORE.md 4.2); completion to the ROB
//   WB         OOO_STAGE: the bypass source of the cycle after
//   commit     OOO_ROB 2 a cycle: renaming's committed state, OOO_CTRL
//              (free list, LQ / SQ, FTQ pops), OOO_TRAP (exceptions, the
//              interrupt, the vector, the replay pc), the commit trace
//
// B4: an illegal instruction (and every FP instruction, its loads and
// stores too: no FPU in Phase 1; decode's is_fp, slot 0 only, rare), ECALL
// and EBREAK trap at decode (to the ROB at dispatch, never issued; tval
// through OOO_TRAP's ports 0 / 1). Port 0's CSR and system µops are
// non-speculative and read their instruction bits from rob_insn (per ROB
// entry, written at dispatch). A result for x0 (tag 0) of the LSU, the
// multiplier or the MDU is neither written nor forwarded (Plan/CORE.md
// 5.7). Left out: interrupt sources, fusion (B5).
//
// The µop's fields from decode (Plan/CORE.md 2.1):
//   - jal / jalr: the link (pc + length) is computed by the ALU (pc +
//     imm, the immediate replaced by the length); a jalr's own offset goes
//     in the record apart (joff). A jal is never resolved: its target was
//     right at F2 (predecode).
//   - a conditional branch and a jalr take a checkpoint; resolved in EX:
//     a branch by its direction against pred_taken (a taken one's target
//     pc + imm was right at F2), a jalr by its target against the one
//     predicted (the block's next address from the target array if it
//     ended a taken block, else the next instruction).
//   - call / ret as predecode tells them (link registers x1 / x5).
//   - the pc in EX: the pc array's line of the first half's block (the
//     µop's block, of its last half, less one when it crosses a line) and
//     the first half's parcel.
//
// The commit trace (OOO_TRACE, simulation only): per ROB entry the
// instruction bits (written at dispatch) and the value written (at
// completion); at commit with the ROB's pc and destination.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_CORE
    #(
        parameter int VA  = 39,
        parameter int PAW = 40          // physical address bits (Phase 1: the address as it is)
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,
        input  logic                        boot,       // fetch from boot_pc (a cycle after reset)
        input  logic [VA-1:1]               boot_pc,
        // I$
        output logic                        ic_req_valid,
        output logic [VA-1:1]               ic_req_pc,
        input  logic                        ic_req_ready,
        input  logic                        ic_resp_valid,
        input  logic [127:0]                ic_resp_data,
        // the D$ (OOO_LSU's abstract port: OOO_DCAD and the D$, or a model)
        output logic                        dc_req_valid,
        output logic [PAW-1:0]              dc_req_addr,
        output logic [2:0]                  dc_req_tag,
        input  logic                        dc_hit,
        input  logic [63:0]                 dc_rdata,
        input  logic                        dc_fill_valid,
        input  logic [2:0]                  dc_fill_tag,
        input  logic [63:0]                 dc_fill_data,
        output logic                        dc_fill_ready,
        output logic [7:0]                  dc_kill,
        output logic                        dc_st_valid,
        output logic [PAW-1:0]              dc_st_addr,
        output logic [63:0]                 dc_st_data,
        output logic [7:0]                  dc_st_mask,
        input  logic                        dc_st_ready,
        output logic                        fl_req,     // FENCE.I: FLUSH of the D$ (OOO_DCAD)
        input  logic                        fl_take,
        input  logic                        fl_done,
        output logic                        ic_flush,   // FENCE.I: invalidate the I$ (until ic_done)
        input  logic                        ic_done
`ifdef OOO_TRACE
        ,
        // the commit trace: up to 2 µops a cycle, slot 0 the older
        output logic [1:0]                  tr_valid,
        output logic [1:0][VA-1:1]          tr_pc,
        output logic [1:0][31:0]            tr_insn,
        output logic [1:0]                  tr_wr,
        output logic [1:0][4:0]             tr_rd,
        output logic [1:0][63:0]            tr_val,
        output logic                        tr_trap,
        output logic                        tr_int,     // an interrupt (taken before the head)
        output logic [4:0]                  tr_cause,
        output logic [VA-1:1]               tr_trap_pc,
        output logic [1:0]                  tr_st,      // a store: its address, data and size
        output logic [1:0][63:0]            tr_st_addr,
        output logic [1:0][63:0]            tr_st_data,
        output logic [1:0][1:0]             tr_st_size
`endif
    );

    localparam int NFTQ  = 16, FTQW = 4;        // D-18
    localparam int NCKPT = 6,  CW   = 3;
    localparam int TAGW  = 6;                   // 64 physical registers
    localparam int NROB  = 24, ROBW = 5;
    localparam int NIQ   = 10, IQW  = 4;
    localparam int NWK   = 6;                   // wakeup buses (OOO_IQ: 4 + NEXT)

    logic [1:0]          priv;                  // the privilege level (CORE_CSR): ECALL's cause at decode

    // the payload record (OOO_IQPL, 102 bits; the fields of B2 to B4)
    localparam logic [1:0] K_ALU = 2'd0, K_MDU = 2'd1, K_CSR = 2'd2, K_SYS = 2'd3;
    typedef struct packed {
        logic [1:0]      kind;                  // port 0's units: K_ALU (and branches, jumps), K_MDU, K_CSR, K_SYS
        logic [3:0]      xop;                   // an MDU µop's CORE_MDU op (0: mul / mulw, OOO_PMUL); a system µop's OOO_SYS op
        logic [2:0]      lq;                    // a load's LQ entry, a store's SQ entry (OOO_LSU)
        logic [2:0]      sq;
        logic [1:0]      msize;                 // 0 byte .. 3 double
        logic            uns;                   // a load zero extended
        logic            is_ld;                 // (a µop of port 2: a load, else a store)
        logic            pred_taken;            // it ends a block predicted taken
        logic            ret;
        logic            call;
        logic            is_jalr;
        logic            is_jal;
        logic [2:0]      br_op;
        logic            is_br;
        logic            word_op;
        logic            b_sel;                 // imm
        logic [1:0]      a_sel;                 // 0 rs1, 1 pc, 2 zero
        logic [1:0]      a_shift;
        logic            a_uw;
        logic [5:0]      alu_op;
        logic [31:0]     imm;                   // sign extended at its use
        logic [11:0]     joff;                  // a jalr's offset
        logic            len4;                  // 32-bit (else RVC)
        logic            xline;                 // its first half in the block before
        logic [2:0]      off;                   // the first half's parcel
        logic [2:0]      e;                     // the last half's parcel
        logic [CW-1:0]   ckpt;
        logic [FTQW-1:0] ftq;                   // the block of its last half
        logic [ROBW-1:0] rob;
    } rec_t;

    // what the DS register keeps besides the tags
    typedef struct packed {
        rec_t            rec;
        logic [VA-1:1]   pc;
        logic            wr;
        logic [4:0]      arch;
        logic [TAGW-1:0] dst;
        logic [TAGW-1:0] old;
        logic            exc;
        logic [4:0]      cause;                 // an exception at decode: illegal, ECALL, EBREAK
        logic [63:0]     tval;
        logic            ld, st;
        logic            ns;                    // non-speculative: issued at the ROB head
        logic            md;                    // answered from outside (OOO_MDUP): the issue queue does not wake for it
        logic [1:0]      port;
        logic            lat2;
        logic [31:0]     insn;
    } dsp_t;

    // ---- recovery and the front end
    logic                fe_redirect, fe_flush, flush_all, restore_port;
    logic                restore /*verilator public_flat_rd*/;     // (counted by SIM/CORE/tb_core)
    logic [VA-1:1]       fe_pc;
    logic [FTQW-1:0]     restore_ftq, rcv_ftq;
    logic [2:0]          rcv_end;
    logic [CW-1:0]       restore_id;
    logic [NCKPT-1:0]    kill, clr;
    logic [1:0]          ftq_pop;
    logic [1:0][2:0]     br_e     /*verilator public_flat_rd*/;
    // (the resolution's fields are read by SIM/CORE/tb_core, which checks them against the instruction)
    logic [1:0]          br_taken /*verilator public_flat_rd*/;
    logic [1:0]          br_call  /*verilator public_flat_rd*/;
    logic [1:0]          br_ret   /*verilator public_flat_rd*/;
    logic [1:0]          rs_valid /*verilator public_flat_rd*/;
    logic [1:0]          rs_taken /*verilator public_flat_rd*/;
    logic [1:0][FTQW-1:0] rs_ftq;
    logic [1:0][2:0]     rs_e     /*verilator public_flat_rd*/;
    logic                bt_valid /*verilator public_flat_rd*/;
    logic [VA-1:1]       bt_pc    /*verilator public_flat_rd*/;
    logic [VA-1:1]       bt_tgt;
    logic [1:0][FTQW-1:0] ta_idx, pa_idx;
    logic [1:0][VA-1:1]  ta_tgt;
    logic [1:0][VA-1:4]  pa_line;
    logic [2:0]          g_take;

    logic [3:0]          g_valid, g_rvc, g_taken, g_seq;
    logic [3:0][VA-1:1]  g_pc;
    logic [3:0][31:0]    g_insn;
    logic [3:0][FTQW-1:0] g_ftq;
    logic [3:0][2:0]     g_end;
    logic [3:0]          g_illegal;
    logic [3:0][2:0]     g_cls, g_op;
    logic [3:0][4:0]     g_rd, g_rs1, g_rs2;
    logic [3:0]          g_use_rs1, g_use_rs2;
    logic [3:0][31:0]    g_imm;
    logic [3:0][1:0]     g_port;
    logic [3:0]          g_lat2;
    logic [3:0][5:0]     g_alu_op;
    logic [3:0]          g_a_uw;
    logic [3:0][1:0]     g_a_shift, g_a_sel;
    logic [3:0]          g_b_sel, g_word_op, g_is_branch, g_is_jal, g_is_jalr;
    logic [3:0][2:0]     g_br_op;
    logic [3:0][1:0]     g_mem_size;
    /* verilator lint_off UNUSEDSIGNAL */      // (decode's fields B2 does not use: MDU, memory, system, CSR, FP)
    logic [3:0]          g_mem_signed, g_ext_ans, g_nonspec, g_is_sfence, g_is_csr;
    logic [3:0][3:0]     g_mdu_op;
    logic [3:0][7:0]     g_sys;
    logic [3:0]          g_csr_imm_sel, g_csr_wr, g_csr_rd, g_is_fp;     // (the CSR unit decodes the instruction itself)
    logic [3:0][4:0]     g_mem_cmd;
    logic [3:0][11:0]    g_csr_addr;
    logic [3:0][1:0]     g_csr_op;
    /* verilator lint_on UNUSEDSIGNAL */

    OOO_FRONT #(.VA(VA), .NFTQ(NFTQ), .FTQW(FTQW)) u_front
        (.clk(clk), .rst_n(rst_n),
         .fe_redirect(fe_redirect || boot), .fe_flush(fe_flush || boot), .fe_pc(boot ? boot_pc : fe_pc),
         .restore_ftq(restore_ftq), .restore_port(restore_port), .br_e(br_e), .br_taken(br_taken),
         .br_call(br_call), .br_ret(br_ret), .rcv_ftq(rcv_ftq), .rcv_end(rcv_end),
         .rs_valid(rs_valid), .rs_ftq(rs_ftq), .rs_e(rs_e), .rs_taken(rs_taken),
         .bt_valid(bt_valid), .bt_pc(bt_pc), .bt_tgt(bt_tgt), .ftq_pop(ftq_pop),
         .ta_idx(ta_idx), .ta_tgt(ta_tgt), .pa_idx(pa_idx), .pa_line(pa_line),
         .ic_req_valid(ic_req_valid), .ic_req_pc(ic_req_pc), .ic_req_ready(ic_req_ready),
         .ic_resp_valid(ic_resp_valid), .ic_resp_data(ic_resp_data),
         .g_valid(g_valid), .g_pc(g_pc), .g_insn(g_insn), .g_rvc(g_rvc), .g_ftq(g_ftq), .g_end(g_end),
         .g_taken(g_taken), .g_seq(g_seq), .g_illegal(g_illegal), .g_cls(g_cls), .g_op(g_op), .g_rd(g_rd),
         .g_rs1(g_rs1), .g_rs2(g_rs2), .g_use_rs1(g_use_rs1), .g_use_rs2(g_use_rs2), .g_imm(g_imm),
         .g_port(g_port), .g_lat2(g_lat2), .g_ext_ans(g_ext_ans), .g_nonspec(g_nonspec), .g_alu_op(g_alu_op),
         .g_a_uw(g_a_uw), .g_a_shift(g_a_shift), .g_a_sel(g_a_sel), .g_b_sel(g_b_sel), .g_word_op(g_word_op),
         .g_is_branch(g_is_branch), .g_is_jal(g_is_jal), .g_is_jalr(g_is_jalr), .g_br_op(g_br_op),
         .g_mdu_op(g_mdu_op), .g_mem_cmd(g_mem_cmd), .g_mem_size(g_mem_size), .g_mem_signed(g_mem_signed),
         .g_sys(g_sys), .g_is_sfence(g_is_sfence), .g_is_csr(g_is_csr), .g_csr_addr(g_csr_addr),
         .g_csr_op(g_csr_op), .g_csr_imm_sel(g_csr_imm_sel), .g_csr_wr(g_csr_wr), .g_csr_rd(g_csr_rd),
         .g_is_fp(g_is_fp), .g_take(g_take));

    // ---- D2: the group from its oldest valid slot. The valid slots run from
    // hd to the last one given (D2 takes from the oldest, and the register
    // takes a new group only when empty), so the slots that wrap round past
    // slot 3 are below hd and never valid
    logic [1:0]          hd;                    // the oldest valid slot
    logic [3:0][1:0]     rs;                    // rotated slot k is group slot rs[k]
    logic [3:0]          r_v;
    always @(*) begin
        hd = g_valid[0] ? 2'd0 : g_valid[1] ? 2'd1 : g_valid[2] ? 2'd2 : 2'd3;
        for (int k = 0; k < 4; k++) begin
            rs[k]  = hd + 2'(k);
            r_v[k] = g_valid[rs[k]];
        end
    end

    logic [3:0]          f_seq, f_use1, f_use2;
    logic [3:0][2:0]     f_cls, f_op;
    logic [3:0][4:0]     f_rd, f_rs1, f_rs2;
    logic [3:0][11:0]    f_imm;
    logic [3:0][1:0]     f_msize, f_port;
    always @(*) begin
        for (int k = 0; k < 4; k++) begin
            f_seq[k]   = g_seq[rs[k]];
            f_cls[k]   = g_cls[rs[k]];
            f_op[k]    = g_op[rs[k]];
            f_rd[k]    = g_rd[rs[k]];
            f_rs1[k]   = g_rs1[rs[k]];
            f_rs2[k]   = g_rs2[rs[k]];
            f_use1[k]  = g_use_rs1[rs[k]];
            f_use2[k]  = g_use_rs2[rs[k]];
            f_imm[k]   = g_imm[rs[k]][11:0];
            f_msize[k] = g_mem_size[rs[k]];
            f_port[k]  = g_port[rs[k]];
        end
    end

    logic                u0_valid, u1_valid;
    logic [1:0]          u0_slot, u1_slot, u0_port, u1_port;
    logic [3:0]          u0_kind;
    /* verilator lint_off UNUSEDSIGNAL */      // (fusion off in B2)
    logic [3:0]          u1_kind;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [2:0]          consumed;
    OOO_FUSE u_fuse
        (.no_fuse(1'b1), .valid(r_v), .seq(f_seq), .cls(f_cls), .op(f_op), .rd(f_rd), .rs1(f_rs1), .rs2(f_rs2),
         .use_rs1(f_use1), .use_rs2(f_use2), .imm(f_imm), .msize(f_msize), .port(f_port),
         .u0_valid(u0_valid), .u0_slot(u0_slot), .u0_kind(u0_kind), .u0_port(u0_port),
         .u1_valid(u1_valid), .u1_slot(u1_slot), .u1_kind(u1_kind), .u1_port(u1_port), .consumed(consumed));

    // the two µops (fusion off: one instruction each)
    logic [1:0]          r_valid, r_ckpt, r_go, ren_wr;
    logic [1:0][1:0]     ren_use;
    logic [1:0][1:0][4:0] ren_src;
    logic [1:0][4:0]     ren_dst;
    logic [1:0][CW-1:0]  ren_ckpt_id;
    logic [1:0][1:0][TAGW-1:0] ren_osrc;
    logic [1:0][1:0]     ren_ordy;
    logic [1:0][TAGW-1:0] ren_odst, ren_oold;
    logic                ren_ready;
    dsp_t [1:0]          d2;
    logic [1:0][1:0]     us;                    // the group slot of each µop
    assign us[0]   = hd + u0_slot;
    assign us[1]   = hd + u1_slot;
    assign r_valid = {u1_valid, u0_valid};
    always @(*) begin
        for (int j = 0; j < 2; j++) begin
            ren_use[j] = {g_use_rs2[us[j]], g_use_rs1[us[j]]};
            ren_src[j] = {g_rs2[us[j]], g_rs1[us[j]]};
            ren_wr[j]  = r_valid[j] && g_rd[us[j]] != 5'd0;   // (renaming's ready counts the destinations offered)
            ren_dst[j] = g_rd[us[j]];
            r_ckpt[j]  = g_is_branch[us[j]] || g_is_jalr[us[j]];
        end
    end
    always @(*) begin
        logic [1:0] s;
        logic       jmp, link_rd, link_rs1, sysop_v;
        logic [2:0] sysop;
        for (int j = 0; j < 2; j++) begin
            s        = us[j];
            // OOO_SYS's operations: 0 FENCE, 1 FENCE.I, 2 SFENCE.VMA, 3 MRET, 4 WFI, 5 SRET (decode's sys:
            // wfi, sret, mret, ebreak, ecall, cbo, fence.i, fence)
            sysop_v  = g_sys[s][0] || g_sys[s][1] || g_is_sfence[s] || g_sys[s][5] || g_sys[s][7] || g_sys[s][6];
            sysop    = g_sys[s][1] ? 3'd1 : g_is_sfence[s] ? 3'd2 : g_sys[s][5] ? 3'd3 : g_sys[s][7] ? 3'd4 :
                       g_sys[s][6] ? 3'd5 : 3'd0;
            jmp      = g_is_jal[s] || g_is_jalr[s];
            link_rd  = g_rd[s] == 5'd1 || g_rd[s] == 5'd5;
            link_rs1 = g_rs1[s] == 5'd1 || g_rs1[s] == 5'd5;
            d2[j]                = '0;
            d2[j].rec.pred_taken = g_taken[s];
            d2[j].rec.call       = g_is_jalr[s] && link_rd;
            d2[j].rec.ret        = g_is_jalr[s] && link_rs1 && !link_rd;
            d2[j].rec.is_jalr    = g_is_jalr[s];
            d2[j].rec.is_jal     = g_is_jal[s];
            d2[j].rec.br_op      = g_br_op[s];
            d2[j].rec.is_br      = g_is_branch[s];
            d2[j].rec.word_op    = jmp ? 1'b0 : g_word_op[s];
            d2[j].rec.b_sel      = jmp ? 1'b1 : g_b_sel[s];
            d2[j].rec.a_sel      = jmp ? 2'd1 : g_a_sel[s];             // the link: pc + length
            d2[j].rec.a_shift    = jmp ? 2'd0 : g_a_shift[s];
            d2[j].rec.a_uw       = jmp ? 1'b0 : g_a_uw[s];
            d2[j].rec.alu_op     = jmp ? 6'd0 : g_alu_op[s];            // (ADD)
            d2[j].rec.imm        = jmp ? (g_rvc[s] ? 32'd2 : 32'd4) : g_imm[s];
            d2[j].rec.joff       = g_imm[s][11:0];
            d2[j].rec.len4       = !g_rvc[s];
            d2[j].rec.xline      = !g_rvc[s] && g_pc[s][3:1] == 3'd7;
            d2[j].rec.off        = g_pc[s][3:1];
            d2[j].rec.e          = g_end[s];
            d2[j].rec.ckpt       = ren_ckpt_id[j];
            d2[j].rec.ftq        = g_ftq[s];
            d2[j].rec.msize      = g_mem_size[s];
            d2[j].rec.uns        = !g_mem_signed[s];
            d2[j].rec.is_ld      = g_cls[s] == 3'd4;
            d2[j].ld             = g_cls[s] == 3'd4;
            d2[j].st             = g_cls[s] == 3'd5;
            d2[j].pc             = g_pc[s];
            d2[j].wr             = ren_wr[j];
            d2[j].arch           = g_rd[s];
            d2[j].dst            = ren_odst[j];
            d2[j].old            = ren_oold[j];
            d2[j].rec.kind       = g_cls[s] == 3'd6 ? K_MDU : g_is_csr[s] ? K_CSR : sysop_v ? K_SYS : K_ALU;
            d2[j].rec.xop        = g_cls[s] == 3'd6 ? g_mdu_op[s] : {1'b0, sysop};
            // illegal (and in Phase 1 an FP instruction: no FPU), EBREAK, ECALL
            d2[j].exc            = g_illegal[s] || g_is_fp[s] || g_sys[s][4] || g_sys[s][3];
            d2[j].cause          = (g_illegal[s] || g_is_fp[s]) ? 5'd2 : g_sys[s][4] ? 5'd3 : (5'd8 | 5'(priv));
            d2[j].tval           = (g_illegal[s] || g_is_fp[s]) ? {32'd0, g_insn[s]}     // (an RVC one: the upper half 0, OOO_FBUF)
                                 : g_sys[s][4] ? {{(64 - VA){g_pc[s][VA-1]}}, g_pc[s], 1'b0} : 64'd0;
            d2[j].ns             = g_nonspec[s];
            d2[j].md             = g_ext_ans[s];
            d2[j].port           = j == 0 ? u0_port : u1_port;
            d2[j].lat2           = g_lat2[s];
            d2[j].insn           = g_insn[s];
        end
    end
    // instructions taken: µop 1 only with µop 0
    assign g_take = r_go[1] ? consumed : r_go[0] ? ((u0_kind != 4'd0) ? 3'd2 : 3'd1) : 3'd0;

    // ---- the wakeups, commit, the ROB, the issue queue (declared for renaming and CTRL)
    logic [NWK-1:0]            wk_valid;
    logic [NWK-1:0][TAGW-1:0]  wk_tag;
    logic [1:0]                free_valid, cmt_valid, cmt_wr, cmt_ld_n, cmt_st_n;
    logic [1:0][TAGW-1:0]      free_tag, cmt_new, cmt_old;
    logic [1:0][4:0]           cmt_arch;
    logic [1:0][VA-1:1]        cmt_pc;
    logic [1:0][FTQW-1:0]      cmt_ftq;

    OOO_RENAME #(.NREG(64), .TAGW(TAGW), .NCKPT(NCKPT), .NWK(NWK)) u_rename
        (.clk(clk), .rst_n(rst_n), .ready(ren_ready), .in_valid(r_go), .in_use(ren_use), .in_src(ren_src),
         .in_wr(ren_wr), .in_dst(ren_dst), .in_ckpt(r_ckpt), .out_ckpt_id(ren_ckpt_id),
         .out_src(ren_osrc), .out_rdy(ren_ordy), .out_dst(ren_odst), .out_old(ren_oold),
         .wk_valid(wk_valid), .wk_tag(wk_tag), .free_valid(free_valid), .free_tag(free_tag),
         .restore(restore), .restore_id(restore_id),
         .cmt_valid(cmt_valid), .cmt_wr(cmt_wr), .cmt_arch(cmt_arch), .cmt_new(cmt_new), .flush_all(flush_all));

    // ---- DS
    logic [1:0]                d_go, rob_avail, iq_ready;
    /* verilator lint_off UNUSEDSIGNAL */      // (d_go says what dispatches)
    logic [1:0]                ds_valid;
    /* verilator lint_on UNUSEDSIGNAL */
    logic                      ds_load;
    logic [1:0][NCKPT-1:0]     d_bmask;
    logic [1:0][1:0][TAGW-1:0] ds_src;
    logic [1:0][1:0]           ds_use, ds_rdy;
    dsp_t [1:0]                ds;
    logic [1:0][ROBW-1:0]      disp_rob;
    logic [1:0][IQW-1:0]       disp_entry;

    OOO_DSREG #(.W($bits(dsp_t)), .TAGW(TAGW), .NB(NWK)) u_dsreg
        (.clk(clk), .rst_n(rst_n), .load(ds_load), .in_src(ren_osrc), .in_use(ren_use), .in_rdy(ren_ordy),
         .in_data(d2), .wk_valid(wk_valid), .wk_tag(wk_tag),
         .ds_src(ds_src), .ds_use(ds_use), .ds_rdy(ds_rdy), .ds_data(ds));

    logic [1:0]                br_valid /*verilator public_flat_rd*/;
    logic [1:0]                br_mispred;
    logic [1:0][CW-1:0]        br_ckpt;
    logic [1:0][VA-1:1]        br_next;
    logic [1:0][ROBW-1:0]      br_rob   /*verilator public_flat_rd*/;
    logic                      rob_restore, rob_trap, trap, head_ns, iss_ns, ns_ok, ns_busy, irq;
    logic                      replay /*verilator public_flat_rd*/;      // (counted by SIM/CORE/tb_core)
    logic [CW-1:0]             rob_restore_ckpt;
    logic [VA-1:1]             rob_replay_pc, replay_pc, trap_vec;
    logic [ROBW-1:0]           head_rob;
    logic [4:0]                trap_cause;
    logic [VA-1:1]             trap_pc;

    // the LSU's side of dispatch, commit and recovery
    logic [1:0]                lq_avail, sq_avail, lq_commit, sq_commit;
    logic [1:0][3:0]           ck_lq_tail, ck_sq_tail;
    logic [3:0]                restore_lq_tail, restore_sq_tail;
    logic [1:0][2:0]           disp_lq, disp_sq;

    /* verilator lint_off PINCONNECTEMPTY */   // (what OOO_TRAP and interrupts take: not yet)
    OOO_CTRL #(.NCKPT(NCKPT), .CW(CW), .VA(VA), .FTQW(FTQW), .LW(3), .TAGW(TAGW)) u_ctrl
        (.clk(clk), .rst_n(rst_n),
         .r_valid(r_valid), .r_ckpt(r_ckpt), .r_ckpt_id(ren_ckpt_id), .r_ren_ready(ren_ready), .r_go(r_go),
         .ds_valid(ds_valid), .ds_load(ds_load), .ds_ld({ds[1].ld, ds[0].ld}), .ds_st({ds[1].st, ds[0].st}),
         .ds_ftq({ds[1].rec.ftq, ds[0].rec.ftq}), .rob_avail(rob_avail), .iq_avail(iq_ready),
         .lq_avail(lq_avail), .sq_avail(sq_avail), .ck_lq_tail(ck_lq_tail), .ck_sq_tail(ck_sq_tail), .d_go(d_go), .d_bmask(d_bmask),
         .br_valid(br_valid), .br_mispred(br_mispred), .br_ckpt(br_ckpt), .br_next(br_next),
         .rob_restore(rob_restore), .rob_restore_ckpt(rob_restore_ckpt), .trap(trap), .replay(replay),
         .replay_pc(replay_pc), .trap_vec(trap_vec), .head_ns(head_ns),     // (trap, trap_vec, replay_pc: OOO_TRAP)
         .cmt_valid(cmt_valid), .cmt_wr(cmt_wr), .cmt_old(cmt_old), .cmt_ld_n(cmt_ld_n), .cmt_st_n(cmt_st_n),
         .cmt_ftq(cmt_ftq), .iss_ns(iss_ns), .ns_ok(ns_ok), .ns_busy(ns_busy),
         .fe_flush(fe_flush), .flush_all(flush_all), .restore(restore), .restore_id(restore_id),
         .restore_port(restore_port), .restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_sq_tail), .restore_ftq(restore_ftq),
         .kill(kill), .clr(clr), .fe_redirect(fe_redirect), .fe_pc(fe_pc), .live(),
         .free_valid(free_valid), .free_tag(free_tag), .lq_commit(lq_commit), .sq_commit(sq_commit), .ftq_pop(ftq_pop));

    // the ROB
    // completion: 0 port 0's EX, 1 port 1's EX, 2 the LSU's loads, 3 its stores, 4 port 0's multiplier and
    // MDU (their results), 5 the system unit
    localparam int NCMP = 6;
    logic [NCMP-1:0]           cmp_valid, cmp_exc, cmp_rp;
    logic [NCMP-1:0][ROBW-1:0] cmp_rob;
    logic [NCMP-1:0][4:0]      cmp_cause;
    logic [1:0]                disp_go;
    assign disp_go = d_go;
    logic                      head_valid, head_fused;
    logic [ROBW-1:0]           rob_restore_rob;
    logic [2:0]                cmt_instret;
    OOO_ROB #(.NROB(NROB), .ROBW(ROBW), .VA(VA), .TAGW(TAGW), .CW(CW), .NCMP(NCMP), .FTQW(FTQW)) u_rob
        (.clk(clk), .rst_n(rst_n), .rob_avail(rob_avail), .disp_valid(disp_go),
         .disp_pc({ds[1].pc, ds[0].pc}), .disp_wr({ds[1].wr, ds[0].wr}), .disp_arch({ds[1].arch, ds[0].arch}),
         .disp_new({ds[1].dst, ds[0].dst}), .disp_old({ds[1].old, ds[0].old}), .disp_ld({ds[1].ld, ds[0].ld}), .disp_st({ds[1].st, ds[0].st}),
         .disp_fused(2'b00), .disp_ns({ds[1].ns, ds[0].ns}), .disp_len({ds[1].rec.len4 ? 3'd2 : 3'd1, ds[0].rec.len4 ? 3'd2 : 3'd1}),
         .disp_ftq({ds[1].rec.ftq, ds[0].rec.ftq}), .disp_exc({ds[1].exc, ds[0].exc}), .disp_cause({ds[1].cause, ds[0].cause}),
         .disp_rob(disp_rob),
         .cmp_valid(cmp_valid), .cmp_rob(cmp_rob), .cmp_exc(cmp_exc), .cmp_cause(cmp_cause), .cmp_rp(cmp_rp),
         .br_valid(br_valid), .br_rob(br_rob), .br_mispred(br_mispred), .br_ckpt(br_ckpt),
         .restore(rob_restore), .restore_rob(rob_restore_rob), .restore_ckpt(rob_restore_ckpt),
         .head_rob(head_rob), .head_ns(head_ns), .head_valid(head_valid), .head_fused(head_fused), .irq(irq),
         .cmt_valid(cmt_valid), .cmt_wr(cmt_wr), .cmt_arch(cmt_arch), .cmt_new(cmt_new), .cmt_old(cmt_old),
         .cmt_pc(cmt_pc), .cmt_ftq(cmt_ftq), .cmt_ld_n(cmt_ld_n), .cmt_st_n(cmt_st_n), .cmt_instret(cmt_instret),
         .trap(rob_trap), .trap_cause(trap_cause), .trap_pc(trap_pc), .replay(replay), .replay_pc(rob_replay_pc),
         .rcv_ftq(rcv_ftq), .rcv_end(rcv_end));

    // ---- the instructions by ROB entry (what a CSR or system µop reads in EX: its fields, its tval)
    logic [31:0]               rob_insn [NROB];
    always_ff @(posedge clk)
        for (int j = 0; j < 2; j++) if (disp_go[j]) rob_insn[disp_rob[j]] <= ds[j].insn;

    // ---- OOO_TRAP: exceptions and interrupts at the head; the CSRs' trap side
    localparam int NTV = 4;                     // tval: the two dispatch slots, port 2 (misaligned), port 0 (CSR / system)
    logic [NTV-1:0]            tv_valid;
    logic [NTV-1:0][ROBW-1:0]  tv_rob;
    logic [NTV-1:0][63:0]      tv_val;
    logic                      irq_pend, x_ret, x_sret, csr_trap, csr_int, csr_mret, csr_sret, wfi_wake;
    logic [4:0]                irq_cause, csr_cause;
    logic [VA-1:1]             tvec, mepc, sepc, csr_epc;
    logic [63:0]               csr_tval;
    /* verilator lint_off UNUSEDSIGNAL */      // (fusion is off until B5)
    logic                      no_fuse;
    /* verilator lint_on UNUSEDSIGNAL */
    OOO_TRAP #(.VA(VA), .NROB(NROB), .ROBW(ROBW), .NTV(NTV)) u_trap
        (.clk(clk), .rst_n(rst_n),
         .rob_trap(rob_trap), .rob_cause(trap_cause), .rob_pc(trap_pc), .head_valid(head_valid), .head_fused(head_fused),
         .head_rob(head_rob), .rob_replay(replay), .rob_replay_pc(rob_replay_pc), .cmt_instret(cmt_instret),
         .restore(rob_restore), .restore_rob(rob_restore_rob), .irq(irq),
         .ns_busy(ns_busy), .flush_all(flush_all), .take(trap), .vec(trap_vec), .rp_pc(replay_pc),
         .x_ret(x_ret), .x_sret(x_sret), .tv_valid(tv_valid), .tv_rob(tv_rob), .tv_val(tv_val),
         .irq_pend(irq_pend), .irq_cause(irq_cause), .tvec(tvec), .mepc(mepc), .sepc(sepc),
         .csr_trap(csr_trap), .csr_epc(csr_epc), .csr_int(csr_int), .csr_cause(csr_cause), .csr_tval(csr_tval),
         .csr_mret(csr_mret), .csr_sret(csr_sret), .no_fuse(no_fuse));
    always @(*) begin
        for (int j = 0; j < 2; j++) begin                         // an exception at decode
            tv_valid[j] = disp_go[j] && ds[j].exc;
            tv_rob[j]   = disp_rob[j];
            tv_val[j]   = ds[j].tval;
        end
    end

    // the issue queue and its payload (an exception at decode is never issued)
    /* verilator lint_off UNUSEDSIGNAL */      // (port 2, the LSU's: not in B2)
    logic [1:0]                iq_disp;
    logic [2:0]                iss_valid, iss_wr;
    logic [2:0][IQW-1:0]       iss_entry;
    logic [2:0][1:0][TAGW-1:0] iss_src;
    logic [2:0][TAGW-1:0]      iss_dst;
    logic [2:0][NCKPT-1:0]     iss_bm;
    /* verilator lint_off UNUSEDSIGNAL */
    rec_t [2:0]                rr_rec;
    /* verilator lint_on UNUSEDSIGNAL */
    logic                      iss_md, mdu_ok, p0_hold, md_ext_v;
    logic [TAGW-1:0]           md_ext_t;
    assign iq_disp = d_go & ~{ds[1].exc, ds[0].exc};
    OOO_IQ #(.N(NIQ), .TAGW(TAGW), .NEXT(2), .NCK(NCKPT)) u_iq
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .ns_ok(ns_ok), .mdu_ok(mdu_ok),
         .p0_hold(p0_hold), .disp_ready(iq_ready), .disp_entry(disp_entry), .disp_valid(iq_disp),
         .disp_port({ds[1].port, ds[0].port}), .disp_use(ds_use), .disp_src(ds_src), .disp_rdy(ds_rdy),
         .disp_wr({ds[1].wr && !ds[1].md, ds[0].wr && !ds[0].md}), .disp_dst({ds[1].dst, ds[0].dst}),
         .disp_lat2({ds[1].lat2, ds[0].lat2}), .disp_bm(d_bmask), .disp_ns({ds[1].ns, ds[0].ns}),
         .disp_md({ds[1].md && ds[1].rec.kind == K_MDU, ds[0].md && ds[0].rec.kind == K_MDU}),
         .ext_valid({1'b0, md_ext_v}), .ext_tag({TAGW'(0), md_ext_t}),
         .iss_valid(iss_valid), .iss_entry(iss_entry), .iss_src(iss_src), .iss_wr(iss_wr), .iss_dst(iss_dst),
         .iss_bm(iss_bm), .iss_ns(iss_ns), .iss_md(iss_md), .wk_valid(wk_valid), .wk_tag(wk_tag));

    rec_t [1:0]                wrec;
    always @(*) begin
        for (int j = 0; j < 2; j++) begin
            wrec[j]     = ds[j].rec;
            wrec[j].rob = disp_rob[j];
            wrec[j].lq  = disp_lq[j];
            wrec[j].sq  = disp_sq[j];
        end
    end
    OOO_IQPL #(.N(NIQ), .W($bits(rec_t)), .W2($bits(rec_t))) u_iqpl
        (.clk(clk), .rst_n(rst_n), .wr_valid(iq_disp), .wr_entry(disp_entry), .wr_data(wrec),
         .iss_entry(iss_entry), .rr_data(rr_rec));
    /* verilator lint_on PINCONNECTEMPTY */

    // ---- the ports: RR, EX (and WB for the ALU ports; the LSU has its own M and WB)
    localparam int RRW = 3 * TAGW + 1;                          // sources, destination, writes
    typedef struct packed {
        logic [63:0]     v1, v2;                                // the sources as read in RR
        logic [TAGW-1:0] t1, t2;
        logic [TAGW-1:0] dst;
        logic            wr;
        rec_t            rec;
        logic [VA-1:4]   line;                                  // the pc array's line of its first half
        logic [VA-1:1]   ta;                                    // the target array: its block's predicted next
    } ex_t;
    localparam int WBW = TAGW + 64;

    logic [5:0][TAGW-1:0]      prf_ra;
    logic [5:0][63:0]          prf_rd;
    logic [2:0]                prf_we;
    logic [2:0][TAGW-1:0]      prf_wa;
    logic [2:0][63:0]          prf_wd;
    logic [1:0]                wb_v;
    logic [1:0][WBW-1:0]       wb_d;
    // the bypass sources: the ALU ports' WB registers and the LSU's
    logic                      lsu_wb_v;
    /* verilator lint_off UNUSEDSIGNAL */      // (a late load needs no wakeup: its dependents were woken two cycles after
    logic                      lsu_wb_late;    //  its issue, and what ran on that guess is replayed after commit, D-12)
    /* verilator lint_on UNUSEDSIGNAL */
    logic [TAGW-1:0]           lsu_wb_t;
    logic [63:0]               lsu_wb_d;
    logic [2:0]                byp_v;
    logic [2:0][TAGW-1:0]      byp_t;
    logic [2:0][63:0]          byp_d;
    always @(*) begin
        for (int q = 0; q < 2; q++) begin
            byp_v[q] = wb_v[q];
            byp_t[q] = wb_d[q][WBW-1 -: TAGW];
            byp_d[q] = wb_d[q][63:0];
        end
        byp_v[2] = lsu_wb_v && lsu_wb_t != '0;      // a load to x0 has tag 0 (never written: the PRF reads it as 0)
        byp_t[2] = lsu_wb_t;
        byp_d[2] = lsu_wb_d;
    end
    logic [1:0]                ex_v;
    ex_t  [1:0]                ex;
    logic [1:0][63:0]          ex_res;
    logic [1:0]                ex_tk;
    logic [1:0][VA-1:1]        ex_pc /*verilator public_flat_rd*/;
    /* verilator lint_off UNUSEDSIGNAL */      // (port 0's units read port 0's)
    logic [1:0][63:0]          ex_a, ex_b;              // the sources after the bypass
    logic [1:0][NCKPT-1:0]     ex_bms;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [1:0]                wbi_v;                   // into the WB register (and the register file) at the end of the cycle
    logic [1:0][TAGW-1:0]      wbi_t;
    logic [1:0][63:0]          wbi_d;

    for (genvar p = 0; p < 2; p++) begin : g_alu
        // RR
        logic            rr_v;
        logic [NCKPT-1:0] rr_bm, ex_bm;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [NCKPT-1:0] wb_bm;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [RRW-1:0]  rr_d;
        logic [TAGW-1:0] rr_t1, rr_t2, rr_dst;
        logic            rr_wr;
        ex_t             rx;
        OOO_STAGE #(.W(RRW), .NCK(NCKPT)) u_rr
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(iss_valid[p]), .in_bm(iss_bm[p]), .in_data({iss_src[p][1], iss_src[p][0], iss_dst[p], iss_wr[p]}),
             .out_valid(rr_v), .out_bm(rr_bm), .out_data(rr_d));
        assign {rr_t2, rr_t1, rr_dst, rr_wr} = rr_d;
        assign prf_ra[2*p]   = rr_t1;
        assign prf_ra[2*p+1] = rr_t2;
        assign pa_idx[p]     = rr_rec[p].ftq - FTQW'(rr_rec[p].xline);
        assign ta_idx[p]     = rr_rec[p].ftq;
        always @(*) begin
            rx      = '0;
            rx.v1   = prf_rd[2*p];
            rx.v2   = prf_rd[2*p+1];
            rx.t1   = rr_t1;
            rx.t2   = rr_t2;
            rx.dst  = rr_dst;
            rx.wr   = rr_wr;
            rx.rec  = rr_rec[p];
            rx.line = pa_line[p];
            rx.ta   = ta_tgt[p];
        end
        // EX
        OOO_STAGE #(.W($bits(ex_t)), .NCK(NCKPT)) u_ex
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(rr_v), .in_bm(rr_bm), .in_data(rx), .out_valid(ex_v[p]), .out_bm(ex_bm), .out_data(ex[p]));

        logic [63:0]     a, b, pc64, imm64;
        logic [VA-1:1]   pc, pc_nx, b_tgt, j_tgt, nxt, pnx;
        logic            mis;
        always @(*) begin
            // the bypass: the write-back registers (the results of the cycle before), else the RR read
            a = ex[p].v1;
            b = ex[p].v2;
            for (int q = 0; q < 3; q++) begin
                if (byp_v[q] && byp_t[q] == ex[p].t1) a = byp_d[q];
                if (byp_v[q] && byp_t[q] == ex[p].t2) b = byp_d[q];
            end
            ex_a[p] = a;
            ex_b[p] = b;
            pc    = {ex[p].line, ex[p].rec.off};
            ex_pc[p] = pc;
            pc64  = {{(64 - VA){pc[VA-1]}}, pc, 1'b0};
            imm64 = {{32{ex[p].rec.imm[31]}}, ex[p].rec.imm};
        end
        OOO_ALU2 #(.FULL(p == 0)) u_alu
            (.s1(a), .s2(b), .imm1(imm64), .pc(pc64), .op1(ex[p].rec.alu_op), .uw1(ex[p].rec.a_uw),
             .shift1(ex[p].rec.a_shift), .word1(ex[p].rec.word_op), .a1_sel(ex[p].rec.a_sel), .b1_imm(ex[p].rec.b_sel),
             .is_br(ex[p].rec.is_br), .br_op(ex[p].rec.br_op), .br_fused(1'b0), .br_res1_a(1'b0), .br_o_sel(2'd0),
             .res1(ex_res[p]), .take_branch(ex_tk[p]));
        always @(*) begin
            /* verilator lint_off UNUSEDSIGNAL */
            logic [63:0] jt;
            /* verilator lint_on UNUSEDSIGNAL */
            pc_nx = pc + (ex[p].rec.len4 ? (VA - 1)'(2) : (VA - 1)'(1));
            b_tgt = pc + (VA - 1)'({{32{ex[p].rec.imm[31]}}, ex[p].rec.imm} >> 1);
            jt    = a + {{52{ex[p].rec.joff[11]}}, ex[p].rec.joff};
            j_tgt = jt[VA-1:1];
            nxt   = ex[p].rec.is_jalr ? j_tgt : ex_tk[p] ? b_tgt : pc_nx;
            pnx   = ex[p].rec.pred_taken ? (ex[p].rec.is_jalr ? ex[p].ta : b_tgt) : pc_nx;
            mis   = ex[p].rec.is_jalr ? nxt != pnx : ex_tk[p] != ex[p].rec.pred_taken;
            // resolution: OOO_CTRL, OOO_ROB, OOO_FRONT (FERS, TAGE)
            br_valid[p]   = ex_v[p] && (ex[p].rec.is_br || ex[p].rec.is_jalr);
            br_mispred[p] = mis;
            br_ckpt[p]    = ex[p].rec.ckpt;
            br_next[p]    = nxt;
            br_rob[p]     = ex[p].rec.rob;
            br_e[p]       = ex[p].rec.e;
            br_taken[p]   = ex[p].rec.is_jalr || ex_tk[p];
            br_call[p]    = ex[p].rec.call;
            br_ret[p]     = ex[p].rec.ret;
            rs_valid[p]   = ex_v[p] && ex[p].rec.is_br;
            rs_ftq[p]     = ex[p].rec.ftq;
            rs_e[p]       = ex[p].rec.e;
            rs_taken[p]   = ex_tk[p];
            // the register file at the edge the result enters the write-back register (port 0: also the
            // multiplier's and the MDU's results, below); completion in EX, but of what an MDU or the system
            // unit completes later
            prf_we[p]     = wbi_v[p];
            prf_wa[p]     = wbi_t[p];
            prf_wd[p]     = wbi_d[p];
            cmp_valid[p]  = ex_v[p] && ex[p].rec.kind != K_MDU && ex[p].rec.kind != K_SYS;
            cmp_rob[p]    = ex[p].rec.rob;
        end
        assign ex_bms[p] = ex_bm;
        // WB
        OOO_STAGE #(.W(WBW), .NCK(NCKPT)) u_wb
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(wbi_v[p]), .in_bm(ex_bm), .in_data({wbi_t[p], wbi_d[p]}),
             .out_valid(wb_v[p]), .out_bm(wb_bm), .out_data(wb_d[p]));
    end

    // ---- port 0's units beside ALU0: the CSRs, the system µops, the multiplier, the MDU
    logic [31:0]     x_ins;                                     // the instruction of port 0's EX
    logic            x_csr, x_sys, x_mul, x_mdu, x_wv;
    assign x_ins = rob_insn[ex[0].rec.rob];
    assign x_csr = ex_v[0] && ex[0].rec.kind == K_CSR;
    assign x_sys = ex_v[0] && ex[0].rec.kind == K_SYS;
    assign x_mul = ex_v[0] && ex[0].rec.kind == K_MDU && ex[0].rec.xop == 4'd0;
    assign x_mdu = ex_v[0] && ex[0].rec.kind == K_MDU && ex[0].rec.xop != 4'd0;
    assign x_wv  = ex_v[0] && ex[0].wr && ex[0].rec.kind != K_MDU;        // a latency-1 writer (ALU, CSR)

    logic [63:0]     csr_res, csr_tv;
    logic            csr_exc, csr_rp, csr_tv_v;
    logic [ROBW-1:0] csr_tv_rob;
    logic            m_tw, m_tsr, m_tvm;
    /* verilator lint_off UNUSEDSIGNAL */      // (translation, PMP, FP, debug, triggers: Phase 2)
    logic [63:0]     satp;
    logic            m_sum, m_mxr, m_mprv, menv_cbze, senv_cbze, dcsr_step, dcsr_ebm, dcsr_ebs, dcsr_ebu, tctl_mte;
    logic [1:0]      m_mpp, fs;
    logic [2:0]      frm;
    logic [63:0]     pmpcfg;
    logic [511:0]    pmpaddr, pmpmask;
    logic [63:0]     dbg_rdata, dpc;
    logic [31:0]     trig_cfg;
    logic [255:0]    trig_addr;
    logic            tlb_flush;
    /* verilator lint_on UNUSEDSIGNAL */
    // misa as mmRISC-2's (and the reference's): RV64 IMAFDC, S, U
    OOO_CSRU #(.VA(VA), .ROBW(ROBW), .MISA(64'h8000_0000_0014_112F)) u_csr
        (.clk(clk), .rst_n(rst_n),
         .ex_valid(x_csr), .ex_op(x_ins[14:12]), .ex_addr(x_ins[31:20]), .ex_rs1(x_ins[19:15]), .ex_src(ex_a[0]),
         .ex_rob(ex[0].rec.rob), .ex_inst(x_ins), .ex_res(csr_res), .ex_exc(csr_exc), .ex_rp(csr_rp),
         .tv_valid(csr_tv_v), .tv_rob(csr_tv_rob), .tv_val(csr_tv),
         .trap_en(csr_trap), .trap_int(csr_int), .trap_cause(csr_cause), .trap_epc(csr_epc), .trap_tval(csr_tval),
         .mret_en(csr_mret), .sret_en(csr_sret), .tvec(tvec), .mepc(mepc), .sepc(sepc),
         .irq_pend(irq_pend), .irq_cause(irq_cause), .wfi_wake(wfi_wake),
         .irq_m_soft(1'b0), .irq_m_timer(1'b0), .irq_m_ext(1'b0), .irq_s_ext(1'b0), .mtime(64'd0),
         .instret_inc(cmt_instret), .hpm_ev('0),
         .priv(priv), .satp(satp), .mstatus_sum(m_sum), .mstatus_mxr(m_mxr), .mstatus_mprv(m_mprv),
         .mstatus_mpp(m_mpp), .mstatus_tvm(m_tvm), .mstatus_tw(m_tw), .mstatus_tsr(m_tsr),
         .menvcfg_cbze(menv_cbze), .senvcfg_cbze(senv_cbze), .pmpcfg(pmpcfg), .pmpaddr(pmpaddr), .pmpmask(pmpmask),
         .fflags_we(1'b0), .fflags_set(5'd0), .fs_dirty(1'b0), .frm(frm), .fs(fs),
         .dbg_access(1'b0), .dbg_addr(12'd0), .dbg_enter(1'b0), .dbg_cause(3'd0), .dbg_pc(64'd0), .dbg_resume(1'b0),
         .dbg_rdata(dbg_rdata), .dcsr_step(dcsr_step), .dcsr_ebreakm(dcsr_ebm), .dcsr_ebreaks(dcsr_ebs),
         .dcsr_ebreaku(dcsr_ebu), .dpc(dpc), .trig_cfg(trig_cfg), .trig_addr(trig_addr), .tcontrol_mte(tctl_mte),
         .trig_fired(4'd0));

    logic            sys_cv, sys_rp, sys_exc, sys_tv_v;
    logic [ROBW-1:0] sys_rob, sys_tv_rob;
    logic [63:0]     sys_tv;
    OOO_SYS #(.ROBW(ROBW)) u_sys
        (.clk(clk), .rst_n(rst_n), .flush(flush_all),
         .sys_valid(x_sys), .sys_op(ex[0].rec.xop[2:0]), .sys_rob(ex[0].rec.rob), .sys_inst(x_ins), .priv(priv),
         .tw(m_tw), .tsr(m_tsr), .tvm(m_tvm), .sq_drained(sq_drained), .fl_req(fl_req), .fl_take(fl_take),
         .fl_done(fl_done), .ic_flush(ic_flush), .ic_done(ic_done), .tlb_flush(tlb_flush), .x_ret(x_ret),
         .x_sret(x_sret), .wfi_wake(wfi_wake), .cmp_valid(sys_cv), .cmp_rob(sys_rob), .cmp_rp(sys_rp),
         .cmp_exc(sys_exc), .tv_valid(sys_tv_v), .tv_rob(sys_tv_rob), .tv_val(sys_tv));

    logic            pm_v, md_v;
    logic [TAGW-1:0] pm_t, md_t;
    logic [63:0]     pm_d, md_d;
    logic [ROBW-1:0] pm_rob, md_rob;
    OOO_PMUL #(.ROBW(ROBW), .TAGW(TAGW), .NCK(NCKPT)) u_pmul
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill),
         .ex_valid(x_mul), .ex_word(ex[0].rec.word_op), .ex_a(ex_a[0]), .ex_b(ex_b[0]), .ex_rob(ex[0].rec.rob),
         .ex_dst(ex[0].dst), .ex_bm(ex_bms[0]),
         .res_valid(pm_v), .res_tag(pm_t), .res_data(pm_d), .res_rob(pm_rob));
    OOO_MDUP #(.ROBW(ROBW), .TAGW(TAGW), .NCK(NCKPT)) u_mdup
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr),
         .iss_md(iss_md), .iss_bm(iss_bm[0]), .mdu_ok(mdu_ok), .p0_hold(p0_hold),
         .ex_valid(x_mdu), .ex_op(ex[0].rec.xop), .ex_word(ex[0].rec.word_op), .ex_a(ex_a[0]), .ex_b(ex_b[0]),
         .ex_rob(ex[0].rec.rob), .ex_dst(ex[0].dst), .ex_bm(ex_bms[0]), .slot_busy(x_wv || pm_v),
         .res_valid(md_v), .res_tag(md_t), .res_data(md_d), .res_rob(md_rob), .ext_valid(md_ext_v), .ext_tag(md_ext_t));

    // the write-back registers: port 0 takes the multiplier's or the MDU's result, else its EX's (the issue
    // queue and OOO_MDUP keep them to one a cycle). A result for x0 (tag 0: the issue queue keeps no slot for
    // a multiply without a destination) is neither written nor forwarded
    logic pm_w, md_w;
    assign pm_w = pm_v && pm_t != '0;
    assign md_w = md_v && md_t != '0;
    always @(*) begin
        wbi_v[0] = pm_w || md_w || x_wv;
        wbi_t[0] = pm_w ? pm_t : md_w ? md_t : ex[0].dst;
        wbi_d[0] = pm_w ? pm_d : md_w ? md_d : (ex[0].rec.kind == K_CSR ? csr_res : ex_res[0]);
        wbi_v[1] = ex_v[1] && ex[1].wr;
        wbi_t[1] = ex[1].dst;
        wbi_d[1] = ex_res[1];
    end

    // ---- port 2: RR, EX (the LSU's E), the LSU
    logic            p2_rr_v, p2_ex_v, p2_rr_wr;
    logic [NCKPT-1:0] p2_rr_bm, p2_ex_bm;
    logic [RRW-1:0]  p2_rr_d;
    logic [TAGW-1:0] p2_rr_t1, p2_rr_t2, p2_rr_dst;
    ex_t             p2_rx;
    /* verilator lint_off UNUSEDSIGNAL */      // (port 2 uses the record's memory fields only)
    ex_t             p2;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0]     p2_a, p2_b;
    OOO_STAGE #(.W(RRW), .NCK(NCKPT)) u_rr2
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
         .in_valid(iss_valid[2]), .in_bm(iss_bm[2]), .in_data({iss_src[2][1], iss_src[2][0], iss_dst[2], iss_wr[2]}),
         .out_valid(p2_rr_v), .out_bm(p2_rr_bm), .out_data(p2_rr_d));
    assign {p2_rr_t2, p2_rr_t1, p2_rr_dst, p2_rr_wr} = p2_rr_d;
    assign prf_ra[4] = p2_rr_t1;                                // the base
    assign prf_ra[5] = p2_rr_t2;                                // a store's data
    always @(*) begin
        p2_rx     = '0;
        p2_rx.v1  = prf_rd[4];
        p2_rx.v2  = prf_rd[5];
        p2_rx.t1  = p2_rr_t1;
        p2_rx.t2  = p2_rr_t2;
        p2_rx.dst = p2_rr_dst;
        p2_rx.wr  = p2_rr_wr;
        p2_rx.rec = rr_rec[2];
    end
    OOO_STAGE #(.W($bits(ex_t)), .NCK(NCKPT)) u_ex2
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
         .in_valid(p2_rr_v), .in_bm(p2_rr_bm), .in_data(p2_rx), .out_valid(p2_ex_v), .out_bm(p2_ex_bm), .out_data(p2));
    always @(*) begin
        p2_a = p2.v1;
        p2_b = p2.v2;
        for (int q = 0; q < 3; q++) begin
            if (byp_v[q] && byp_t[q] == p2.t1) p2_a = byp_d[q];
            if (byp_v[q] && byp_t[q] == p2.t2) p2_b = byp_d[q];
        end
    end

    logic            sq_drained;
    /* verilator lint_off UNUSEDSIGNAL */      // (ld_cancel: replay after commit, no selective replay)
    logic [7:0]      lsu_st_known;
    logic            ld_cancel;
    logic [TAGW-1:0] ld_cancel_tag;
    /* verilator lint_on UNUSEDSIGNAL */
    logic            cmp_ld_v, cmp_ld_e, cmp_ld_rp, cmp_st_v, cmp_st_e;
    logic [ROBW-1:0] cmp_ld_rob, cmp_st_rob;
    OOO_LSU #(.NLQ(8), .NSQ(8), .PAW(PAW), .TAGW(TAGW), .ROBW(ROBW), .NCK(NCKPT)) u_lsu
        (.clk(clk), .rst_n(rst_n),
         .disp_valid(d_go), .disp_ld({ds[1].ld, ds[0].ld}), .disp_st({ds[1].st, ds[0].st}), .disp_rob(disp_rob),
         .lq_avail(lq_avail), .sq_avail(sq_avail), .disp_lq(disp_lq), .disp_sq(disp_sq),
         .ck_lq_tail(ck_lq_tail), .ck_sq_tail(ck_sq_tail),
         .iss_valid(p2_ex_v), .iss_ld(p2.rec.is_ld), .iss_lq(p2.rec.lq), .iss_sq(p2.rec.sq), .iss_base(p2_a),
         .iss_imm(p2.rec.imm[11:0]), .iss_data(p2_b), .iss_size(p2.rec.msize), .iss_uns(p2.rec.uns),
         .iss_dst(p2.dst), .iss_bm(p2_ex_bm), .lsu_st_known(lsu_st_known),
         .dc_req_valid(dc_req_valid), .dc_req_addr(dc_req_addr), .dc_req_tag(dc_req_tag), .dc_hit(dc_hit),
         .dc_rdata(dc_rdata), .dc_fill_valid(dc_fill_valid), .dc_fill_tag(dc_fill_tag), .dc_fill_data(dc_fill_data),
         .dc_fill_ready(dc_fill_ready), .dc_kill(dc_kill), .sq_drained(sq_drained), .dc_st_valid(dc_st_valid),
         .dc_st_addr(dc_st_addr), .dc_st_data(dc_st_data), .dc_st_mask(dc_st_mask), .dc_st_ready(dc_st_ready),
         .rf_valid(prf_we[2]), .rf_tag(prf_wa[2]), .rf_data(prf_wd[2]),
         .wb_valid(lsu_wb_v), .wb_late(lsu_wb_late), .wb_tag(lsu_wb_t), .wb_data(lsu_wb_d),
         .ld_cancel(ld_cancel), .ld_cancel_tag(ld_cancel_tag),
         .cmp_ld_valid(cmp_ld_v), .cmp_ld_rob(cmp_ld_rob), .cmp_ld_exc(cmp_ld_e), .cmp_ld_rp(cmp_ld_rp),
         .cmp_st_valid(cmp_st_v), .cmp_st_rob(cmp_st_rob), .cmp_st_exc(cmp_st_e),
         .lq_commit(lq_commit), .sq_commit(sq_commit), .restore(restore), .kill(kill),
         .restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_sq_tail), .flush_all(flush_all));

    // completion: port 0 (a CSR µop: illegal, replay after a write), port 1, the LSU's loads and stores
    // (misaligned), port 0's multiplier and MDU, the system unit (illegal, replay)
    always @(*) begin
        cmp_exc   = {sys_exc, 1'b0, cmp_st_e, cmp_ld_e, 1'b0, x_csr && csr_exc};
        cmp_rp    = {sys_rp, 1'b0, 1'b0, cmp_ld_rp, 1'b0, x_csr && csr_rp};
        cmp_cause = {5'd2, 5'd0, 5'd6, 5'd4, 5'd0, 5'd2};
    end
    assign cmp_valid[5:2] = {sys_cv, pm_v || md_v, cmp_st_v, cmp_ld_v};
    assign cmp_rob[5:2]   = {sys_rob, pm_v ? pm_rob : md_rob, cmp_st_rob, cmp_ld_rob};

    // tval: a misaligned access of port 2 (its address), the CSR unit or the system unit (one at a time at the head)
    always @(*) begin
        logic [63:0] ea;
        logic        mis;
        ea  = p2_a + {{52{p2.rec.imm[11]}}, p2.rec.imm[11:0]};
        mis = (p2.rec.msize == 2'd1 && ea[0]) || (p2.rec.msize == 2'd2 && ea[1:0] != 2'd0) || (p2.rec.msize == 2'd3 && ea[2:0] != 3'd0);
        tv_valid[2] = p2_ex_v && mis;
        tv_rob[2]   = p2.rec.rob;
        tv_val[2]   = ea;
        tv_valid[3] = csr_tv_v || sys_tv_v;
        tv_rob[3]   = sys_tv_v ? sys_tv_rob : csr_tv_rob;
        tv_val[3]   = sys_tv_v ? sys_tv : csr_tv;
    end

    // an indirect jump (a jalr not a return) writes the BTB: port 0's first
    always @(*) begin
        logic [1:0] ij;
        for (int p = 0; p < 2; p++) ij[p] = ex_v[p] && ex[p].rec.is_jalr && !ex[p].rec.ret;
        bt_valid = ij != 2'b00;
        bt_pc    = ij[0] ? ex_pc[0] + (VA - 1)'(ex[0].rec.len4) : ex_pc[1] + (VA - 1)'(ex[1].rec.len4);   // its last parcel
        bt_tgt   = ij[0] ? br_next[0] : br_next[1];
    end

    /* verilator lint_off PINCONNECTEMPTY */
    OOO_PRF #(.NREG(64), .NW(3), .NR(6)) u_prf
        (.clk(clk), .ra(prf_ra), .rd(prf_rd), .we(prf_we), .wa(prf_wa), .wd(prf_wd));
    /* verilator lint_on PINCONNECTEMPTY */

`ifdef OOO_TRACE
    // ---- the commit trace
    logic [31:0]     sh_insn [NROB] /*verilator public_flat_rd*/;
    logic [63:0]     sh_val  [NROB];
    logic            sh_st   [NROB];
    logic [63:0]     sh_sa   [NROB];
    logic [63:0]     sh_sd   [NROB];
    logic [1:0]      sh_ss   [NROB];
    always_ff @(posedge clk) begin
        for (int j = 0; j < 2; j++) if (disp_go[j]) begin
            sh_insn[disp_rob[j]] <= ds[j].insn;
            sh_st[disp_rob[j]]   <= 1'b0;
        end
        for (int p = 0; p < 2; p++) if (ex_v[p] && ex[p].wr) sh_val[ex[p].rec.rob] <= ex_res[p];
        if (cmp_ld_v && lsu_wb_v) sh_val[cmp_ld_rob] <= lsu_wb_d;                 // a load's value with its completion
        if (pm_v) sh_val[pm_rob] <= pm_d;                                         // the multiplier's and the MDU's
        if (md_v) sh_val[md_rob] <= md_d;
        if (x_csr) sh_val[ex[0].rec.rob] <= csr_res;                              // a CSR µop's old value
        if (p2_ex_v && !p2.rec.is_ld) begin                                       // a store in E
            sh_st[p2.rec.rob] <= 1'b1;
            sh_sa[p2.rec.rob] <= p2_a + {{52{p2.rec.imm[11]}}, p2.rec.imm[11:0]};
            sh_sd[p2.rec.rob] <= p2_b;
            sh_ss[p2.rec.rob] <= p2.rec.msize;
        end
    end
    always @(*) begin
        logic [ROBW-1:0] i1;
        i1 = (head_rob == ROBW'(NROB - 1)) ? '0 : head_rob + ROBW'(1);
        tr_valid   = cmt_valid;
        tr_pc      = cmt_pc;
        tr_wr      = cmt_wr;
        tr_rd      = cmt_arch;
        tr_insn[0] = sh_insn[head_rob];
        tr_insn[1] = sh_insn[i1];
        tr_val[0]  = sh_val[head_rob];
        tr_val[1]  = sh_val[i1];
        tr_trap    = rob_trap || irq;
        tr_int     = irq;
        tr_cause   = irq ? irq_cause : trap_cause;
        tr_trap_pc = trap_pc;
        tr_st[0]      = sh_st[head_rob];
        tr_st[1]      = sh_st[i1];
        tr_st_addr[0] = sh_sa[head_rob];
        tr_st_addr[1] = sh_sa[i1];
        tr_st_data[0] = sh_sd[head_rob];
        tr_st_data[1] = sh_sd[i1];
        tr_st_size[0] = sh_ss[head_rob];
        tr_st_size[1] = sh_ss[i1];
    end
`endif

endmodule : OOO_CORE
