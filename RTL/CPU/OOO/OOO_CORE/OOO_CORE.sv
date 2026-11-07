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
//              register keeps what D2 left in its place): up to 4 µops, one
//              instruction each (step 1.2 C, Plan/OOC.md 29.19: no pairing,
//              OOO_FUSE is gone), OOO_RENAME2's R1, OOO_CTRL's r_go (a
//              prefix, at most 2 checkpoints); g_take back to the front end
//   DS         OOO_RENAME2's R2 (tags, 4 slots), OOO_BUSY for the ready bits,
//              and the µop's payload: the record of OOO_IQPL2, pc, ...;
//              OOO_CTRL's d_go writes OOO_ROB, OOO_IQ2, OOO_IQPL2 and the LSU
//   IS         OOO_IQ2 (24 entries; NA 2, P5 0 so far, Plan/OOC.md 29.18): port 0 (ALU0, OOO_ALU2 full; OOO_CSRU, OOO_SYS,
//              OOO_PMUL, OOO_MDUP), port 1 (ALU1, FULL 0), port 2 (OOO_LSU)
//   RR         OOO_STAGE; OOO_PRF (2 reads a port), OOO_IQPL2's record, the
//              pc array and the target array (OOO_FRONT)
//   EX         OOO_STAGE; the operands from the RR read or the 3 write-back
//              registers (the bypass), OOO_ALU2, branch resolution (the
//              direction against the prediction, a jalr's target against
//              the target array) to OOO_CTRL, OOO_ROB and OOO_FRONT (FERS,
//              the TAGE outcomes, the BTB); the register file written at
//              the edge the result enters its write-back register (Plan/
//              CORE.md 4.2); completion to the ROB
//   WB         OOO_STAGE: the bypass source of the cycle after
//   commit     OOO_ROB 4 a cycle: renaming's committed state, OOO_CTRL
//              (free list, LQ / SQ, FTQ pops), OOO_TRAP (exceptions, the
//              interrupt, the vector, the replay pc), the commit trace
//
// B4: an illegal instruction (and every FP instruction, its loads and
// stores too: no FPU in Phase 1; decode's is_fp, slot 0 only, rare), ECALL
// and EBREAK trap at decode (to the ROB at dispatch, never issued; tval
// through OOO_TRAP's ports 0 .. 3, one a dispatch slot). Port 0's CSR and system µops are
// non-speculative and read their instruction bits from rob_insn (per ROB
// entry, written at dispatch). A result for x0 (tag 0) of the LSU, the
// multiplier or the MDU is neither written nor forwarded (Plan/CORE.md
// 5.7). Left out: interrupt sources, the fusion kinds but ALU + branch.
//
// B5a (Plan/CORE.md 5.19; turned off in 5.21, KINDS 0: the fused compare
// after the ALU does not fit in a cycle, Plan/OOC.md 27.5, and D1b's refill
// keeps its gain small; the pairing in D2 taken out at step 1.2 C, the
// fields kept, FUSE_AB 0, Plan/OOC.md 29.19): an ALU operation and the conditional branch
// after it that reads its rd are one µop: the ALU's fields, rd and
// sources, the branch's comparison in OOO_ALU2 (res1 against the other
// operand: s1, s2 or zero; on s2 when the ALU operation does not read
// rs2), the branch's offset in joff, prediction, last parcel, block and
// checkpoint. A pair whose halves are in two blocks reads the pc array at
// the branch's block less one (xline; an ALU half across two lines is in
// its second line's block, as is the branch right after it). Not paired:
// either half with an exception at decode, either reading one register
// twice (beq rd, rd; or rd, rs, rs: the branch's other operand would need
// a third place). The ROB counts the pair as two instructions; an
// exception at a pair cannot happen (OOO_TRAP's refetch unfused stays for
// the kinds to come).
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
        output logic [3:0]                  dc_req_tag,
        input  logic                        dc_hit,
        input  logic [63:0]                 dc_rdata,
        input  logic                        dc_fill_valid,
        input  logic [3:0]                  dc_fill_tag,
        input  logic [63:0]                 dc_fill_data,
        output logic                        dc_fill_ready,
        output logic [15:0]                 dc_kill,
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
        output logic [3:0]                  tr_valid,
        output logic [3:0][VA-1:1]          tr_pc,
        output logic [3:0][31:0]            tr_insn,
        output logic [3:0]                  tr_pair,    // a fused pair: its second instruction
        output logic [3:0][31:0]            tr_insn2,
        output logic [3:0]                  tr_wr,
        output logic [3:0][4:0]             tr_rd,
        output logic [3:0][63:0]            tr_val,
        output logic                        tr_trap,
        output logic                        tr_int,     // an interrupt (taken before the head)
        output logic [4:0]                  tr_cause,
        output logic [VA-1:1]               tr_trap_pc,
        output logic [3:0]                  tr_st,      // a store: its address, data and size
        output logic [3:0][63:0]            tr_st_addr,
        output logic [3:0][63:0]            tr_st_data,
        output logic [3:0][1:0]             tr_st_size
`endif
    );

    localparam int NFTQ  = 16, FTQW = 4;        // D-18
    localparam int NCKPT = 12, CW   = 4;        // step 1.2 A (Plan/OOC.md 29.16): the frozen sizes first
    localparam int TAGW  = 7;                   // 80 physical registers
    localparam int NROB  = 48, ROBW = 6;
    localparam int NIQ   = 24, IQW  = 5;
    localparam int ND    = 4;                   // renamed, dispatched and committed a cycle (step 1.2 C, Plan/OOC.md 29.19)
    localparam int NAP   = 4;                   // ALU ports (step 1.2 D, Plan/OOC.md 29.27); the LSU's is port NAP
    // the fusion kinds (OOO_FUSE's KINDS): ALU + branch (B5a, 8'h80) is off (5.21). FUSE_AB gates the pair's
    // uses after D2 as well: the record goes through OOO_IQPL2's LUT RAM, where synthesis cannot see `fused` as a
    // constant, and the compare after the ALU would stay in EX (Plan/OOC.md 27.7)
    localparam logic [7:0] FUSE_KINDS = 8'h00;
    localparam bit         FUSE_AB    = FUSE_KINDS[7];
    localparam int NWK   = 9;                   // wakeup buses (OOO_IQ2: 7 + NEXT)

    logic [1:0]          priv;                  // the privilege level (CORE_CSR): ECALL's cause at decode

    // the payload record (OOO_IQPL2, 102 bits; the fields of B2 to B4)
    localparam logic [1:0] K_ALU = 2'd0, K_MDU = 2'd1, K_CSR = 2'd2, K_SYS = 2'd3;
    typedef struct packed {
        logic [1:0]      kind;                  // port 0's units: K_ALU (and branches, jumps), K_MDU, K_CSR, K_SYS
        logic [3:0]      xop;                   // an MDU µop's CORE_MDU op (0: mul / mulw, OOO_PMUL); a system µop's OOO_SYS op
        logic [3:0]      lq;                    // a load's LQ entry, a store's SQ entry (OOO_LSU)
        logic [3:0]      sq;
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
        logic            fused;                 // ALU + branch (B5a): the branch compares the ALU's result
        logic            b_res1a;               // the result is the comparison's first operand
        logic [1:0]      b_osel;                // the other operand: 0 s1, 1 s2, 2 zero
        logic            len4b;                 // the branch half is 32-bit
        logic            word_op;
        logic            b_sel;                 // imm
        logic [1:0]      a_sel;                 // 0 rs1, 1 pc, 2 zero
        logic [1:0]      a_shift;
        logic            a_uw;
        logic [5:0]      alu_op;
        logic [31:0]     imm;                   // sign extended at its use
        logic [11:0]     joff;                  // a jalr's offset; a fused branch's offset (halfwords)
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
`ifdef OOO_TRACE
        logic [31:0]     insn2;                 // a pair's second instruction (the trace only)
`endif
    } dsp_t;

    // ---- recovery and the front end
    logic                fe_redirect, fe_flush, flush_all, restore_port;
    logic                restore /*verilator public_flat_rd*/;     // (counted by SIM/CORE/tb_core)
    logic                restore_k;               // the kill's: not held off by a trap or replay (the LSU's)
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

    logic [3:0]          g_valid, g_rvc, g_taken;
    logic [3:0][VA-1:1]  g_pc;
    logic [3:0][31:0]    g_insn;
    logic [3:0][FTQW-1:0] g_ftq;
    logic [3:0][2:0]     g_end;
    logic [3:0]          g_illegal;
    logic [3:0][2:0]     g_cls;
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
    logic [3:0]          g_seq;                 // (a pair's second half follows the first: no pairs now)
    logic [3:0][2:0]     g_op;
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

    // the µops: one instruction each, ND of them (Plan/OOC.md 29.19: OOO_FUSE pairs 2 µops out of 4 slots, and
    // with 4 µops a group no pairing is left; ALU + branch has been off since 5.21)
    /* verilator lint_off UNUSEDSIGNAL */
    logic                no_fuse;               // OOO_TRAP: a pair being fetched again (no pairs now)
    /* verilator lint_on UNUSEDSIGNAL */
    logic [ND-1:0]       r_valid, r_ckpt, r_go, ren_wr;
    logic [ND-1:0][1:0]  ren_use;
    logic [ND-1:0][1:0][4:0] ren_src;
    logic [ND-1:0][4:0]  ren_dst;
    logic [ND-1:0][CW-1:0] ren_ckpt_id;
    logic                ren_ready;
    dsp_t [ND-1:0]       d2;
    always @(*) begin
        for (int j = 0; j < ND; j++) begin
            r_valid[j] = r_v[j];
            ren_use[j] = {g_use_rs2[rs[j]], g_use_rs1[rs[j]]};
            ren_src[j] = {g_rs2[rs[j]], g_rs1[rs[j]]};
            ren_wr[j]  = r_valid[j] && g_rd[rs[j]] != 5'd0;   // (renaming's ready counts the destinations offered)
            ren_dst[j] = g_rd[rs[j]];
            r_ckpt[j]  = g_is_branch[rs[j]] || g_is_jalr[rs[j]];
        end
    end
    always @(*) begin
        logic [1:0] s;
        logic       jmp, link_rd, link_rs1, sysop_v;
        logic [2:0] sysop;
        for (int j = 0; j < ND; j++) begin
            s        = rs[j];
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
            d2[j].rec.len4b      = !g_rvc[s];
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
            d2[j].rec.kind       = g_cls[s] == 3'd6 ? K_MDU : g_is_csr[s] ? K_CSR : sysop_v ? K_SYS : K_ALU;
            d2[j].rec.xop        = g_cls[s] == 3'd6 ? g_mdu_op[s] : {1'b0, sysop};
            // illegal (and in Phase 1 an FP instruction: no FPU), EBREAK, ECALL
            d2[j].exc            = g_illegal[s] || g_is_fp[s] || g_sys[s][4] || g_sys[s][3];
            d2[j].cause          = (g_illegal[s] || g_is_fp[s]) ? 5'd2 : g_sys[s][4] ? 5'd3 : (5'd8 | 5'(priv));
            d2[j].tval           = (g_illegal[s] || g_is_fp[s]) ? {32'd0, g_insn[s]}     // (an RVC one: the upper half 0, OOO_FBUF)
                                 : g_sys[s][4] ? {{(64 - VA){g_pc[s][VA-1]}}, g_pc[s], 1'b0} : 64'd0;
            d2[j].ns             = g_nonspec[s];
            d2[j].md             = g_ext_ans[s];
            d2[j].port           = g_port[s];
            d2[j].lat2           = g_lat2[s];
            d2[j].insn           = g_insn[s];
`ifdef OOO_TRACE
            d2[j].insn2          = g_insn[s];
`endif
        end
    end
    // instructions taken: r_go is a prefix
    assign g_take = r_go[3] ? 3'd4 : r_go[2] ? 3'd3 : r_go[1] ? 3'd2 : r_go[0] ? 3'd1 : 3'd0;

    // ---- the wakeups, commit, the ROB, the issue queue (declared for renaming and CTRL)
    logic [NWK-1:0]            wk_valid;
    logic [NWK-1:0][TAGW-1:0]  wk_tag;
    logic [ND-1:0]             free_valid, cmt_valid, cmt_wr;
    logic [2:0]                cmt_ld_n, cmt_st_n;
    logic [ND-1:0][TAGW-1:0]   free_tag, cmt_new, cmt_old;
    logic [ND-1:0][4:0]        cmt_arch;
    logic [ND-1:0][VA-1:1]     cmt_pc;
    logic [ND-1:0][FTQW-1:0]   cmt_ftq;

    // ---- renaming: 4 slots
    logic [ND-1:0]             d_go;
    logic [3:0]                r1_wr, r2_wr_all;
    logic [3:0][TAGW-1:0]      r1_tag, r2_dst_all, r2_old_all;
    logic [3:0][1:0][TAGW-1:0] r2_src_all;
    logic [3:0][CW-1:0]        r1_ckid;
    /* verilator lint_off UNUSEDSIGNAL */      // (R2's valid and checkpoint: the DS register has them from D2)
    logic [3:0]                r2_v_all, r2_ck_all;
    logic [3:0][CW-1:0]        r2_ckid_all;
    logic                      r1_adv;
    logic [2:0]                r1_take;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [3:0][1:0]           ren_rdy;
    OOO_RENAME2 #(.NREG(80), .TAGW(TAGW), .NCK(NCKPT)) u_rename
        (.clk(clk), .rst_n(rst_n), .in_valid(r_go), .in_src(ren_src),
         .in_wr(ren_wr), .in_dst(ren_dst), .in_ckpt(r_ckpt), .in_take(r1_take),
         .r1_adv(r1_adv), .r1_wr(r1_wr), .r1_tag(r1_tag), .r1_ready(ren_ready), .r1_ckid(r1_ckid),
         .r2_valid(r2_v_all), .r2_src(r2_src_all), .r2_wr(r2_wr_all), .r2_dst(r2_dst_all), .r2_old(r2_old_all),
         .r2_ck(r2_ck_all), .r2_ckid(r2_ckid_all), .disp_go(d_go),
         .cmt_wr(free_valid), .cmt_arch(cmt_arch), .cmt_new(cmt_new),
         .cmt_old(free_tag), .restore(restore), .restore_id(restore_id), .flush_all(flush_all));
    assign ren_ckpt_id = r1_ckid;
    OOO_BUSY #(.NREG(80), .TAGW(TAGW), .NWK(NWK)) u_busy
        (.clk(clk), .rst_n(rst_n), .set_v(r1_wr), .set_t(r1_tag), .wk_valid(wk_valid), .wk_tag(wk_tag),
         .rd_t(r2_src_all), .rd_rdy(ren_rdy));

    // ---- DS
    logic [2:0]                rob_avail, iq_ready;
    /* verilator lint_off UNUSEDSIGNAL */      // (d_go says what dispatches)
    logic [ND-1:0]             ds_valid;
    /* verilator lint_on UNUSEDSIGNAL */
    logic                      ds_load;
    logic [ND-1:0][NCKPT-1:0]  d_bmask;
    logic [ND-1:0][1:0][TAGW-1:0] ds_src;
    logic [ND-1:0][1:0]        ds_use, ds_rdy;
    dsp_t [ND-1:0]             ds;
    logic [ND-1:0][ROBW-1:0]   disp_rob;
    logic [ND-1:0][IQW-1:0]    disp_entry;
    // the DS µops' fields by slot, for the units' ports
    logic [ND-1:0]             dv_ld, dv_st, dv_wr, dv_ns, dv_exc, dv_iqwr, dv_lat2, dv_md;
    logic [ND-1:0][FTQW-1:0]   dv_ftq;
    logic [ND-1:0][VA-1:1]     dv_pc;
    logic [ND-1:0][4:0]        dv_arch, dv_cause;
    logic [ND-1:0][TAGW-1:0]   dv_dst, dv_old;
    logic [ND-1:0][1:0]        dv_port;

    // the DS register: the tags are R2's, the ready bits from the busy bits as of now
    // (OOO_BUSY: no snoop is needed), and the rest of the µop travels beside them
    dsp_t [ND-1:0]             ds_q;
    logic [ND-1:0][1:0]        ds_use_q;
    always_ff @(posedge clk) begin
        if (ds_load) begin
            ds_q     <= d2;
            ds_use_q <= ren_use;
        end
    end
    always @(*) begin
        ds     = ds_q;
        ds_use = ds_use_q;
        for (int j = 0; j < ND; j++) begin
            ds[j].dst = r2_wr_all[j] ? r2_dst_all[j] : '0;   // (tag 0: a result for x0 is not written, 5.7)
            ds[j].old = r2_old_all[j];
            ds_src[j] = r2_src_all[j];
            ds_rdy[j] = ren_rdy[j];
        end
        for (int j = 0; j < ND; j++) begin
            dv_ld[j]    = ds[j].ld;
            dv_st[j]    = ds[j].st;
            dv_wr[j]    = ds[j].wr;
            dv_ns[j]    = ds[j].ns;
            dv_exc[j]   = ds[j].exc;
            dv_iqwr[j]  = ds[j].wr && !ds[j].md;
            dv_lat2[j]  = ds[j].lat2;
            dv_md[j]    = ds[j].md && ds[j].rec.kind == K_MDU;
            dv_ftq[j]   = ds[j].rec.ftq;
            dv_pc[j]    = ds[j].pc;
            dv_arch[j]  = ds[j].arch;
            dv_cause[j] = ds[j].cause;
            dv_dst[j]   = ds[j].dst;
            dv_old[j]   = ds[j].old;
            dv_port[j]  = ds[j].port;
        end
    end

    // the resolution (registered: e_* as EX makes it, Plan/CORE.md 5.20)
    logic [1:0]                br_valid /*verilator public_flat_rd*/;
    logic [1:0]                br_mispred;
    logic [1:0][CW-1:0]        br_ckpt;
    logic [1:0][VA-1:1]        br_next;
    logic [1:0][ROBW-1:0]      br_rob   /*verilator public_flat_rd*/;
    logic [1:0][VA-1:1]        br_pc    /*verilator public_flat_rd*/;     // (tb_core: the pc it resolved at)
    logic [1:0]                e_br_valid, e_br_mispred, e_br_taken, e_br_call, e_br_ret, e_rs_valid, e_rs_taken;
    logic [1:0][CW-1:0]        e_br_ckpt;
    logic [1:0][VA-1:1]        e_br_next;
    logic [1:0][ROBW-1:0]      e_br_rob;
    logic [1:0][2:0]           e_br_e, e_rs_e;
    logic [1:0][FTQW-1:0]      e_rs_ftq;
    logic                      e_bt_valid;
    logic [VA-1:1]             e_bt_pc, e_bt_tgt;
    logic                      rob_restore, rob_restore_k, rob_trap, trap, head_ns, iss_ns, ns_ok, ns_busy, irq;
    logic                      replay /*verilator public_flat_rd*/;      // (counted by SIM/CORE/tb_core)
    logic [CW-1:0]             rob_restore_ckpt;
    logic [VA-1:1]             rob_replay_pc, replay_pc, trap_vec;
    logic [ROBW-1:0]           head_rob;
    logic [4:0]                trap_cause;
    logic [VA-1:1]             trap_pc;

    // the LSU's side of dispatch, commit and recovery
    logic [2:0]                lq_avail, sq_avail, lq_commit, sq_commit;
    logic [ND-1:0][4:0]        ck_lq_tail, ck_sq_tail;
    logic [4:0]                restore_lq_tail, restore_sq_tail;
    logic [ND-1:0][3:0]        disp_lq, disp_sq;

    /* verilator lint_off PINCONNECTEMPTY */   // (what OOO_TRAP and interrupts take: not yet)
    OOO_CTRL #(.NCKPT(NCKPT), .CW(CW), .VA(VA), .FTQW(FTQW), .LW(4), .TAGW(TAGW), .ND(ND)) u_ctrl
        (.clk(clk), .rst_n(rst_n),
         .r_valid(r_valid), .r_ckpt(r_ckpt), .r_ckpt_id(ren_ckpt_id), .r_ren_ready(ren_ready), .r_go(r_go),
         .ds_valid(ds_valid), .ds_load(ds_load), .ds_ld(dv_ld), .ds_st(dv_st),
         .ds_ftq(dv_ftq), .rob_avail(rob_avail), .iq_avail(iq_ready),
         .lq_avail(lq_avail), .sq_avail(sq_avail), .ck_lq_tail(ck_lq_tail), .ck_sq_tail(ck_sq_tail), .d_go(d_go), .d_bmask(d_bmask),
         .br_valid(br_valid), .br_mispred(br_mispred), .br_ckpt(br_ckpt), .br_next(br_next),
         .cl_valid(br_valid & ~br_mispred), .cl_ckpt(br_ckpt),
         .rob_restore(rob_restore), .rob_restore_k(rob_restore_k), .rob_restore_ckpt(rob_restore_ckpt), .trap(trap), .replay(replay),
         .replay_pc(replay_pc), .trap_vec(trap_vec), .head_ns(head_ns),     // (trap, trap_vec, replay_pc: OOO_TRAP)
         .cmt_valid(cmt_valid), .cmt_wr(cmt_wr), .cmt_old(cmt_old), .cmt_ld_n(cmt_ld_n), .cmt_st_n(cmt_st_n),
         .cmt_ftq(cmt_ftq), .iss_ns(iss_ns), .ns_ok(ns_ok), .ns_busy(ns_busy),
         .fe_flush(fe_flush), .flush_all(flush_all), .restore(restore), .restore_k(restore_k), .restore_id(restore_id),
         .restore_port(restore_port), .restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_sq_tail), .restore_ftq(restore_ftq),
         .kill(kill), .clr(clr), .fe_redirect(fe_redirect), .fe_pc(fe_pc), .live(),
         .free_valid(free_valid), .free_tag(free_tag), .lq_commit(lq_commit), .sq_commit(sq_commit), .ftq_pop(ftq_pop));

    // the ROB
    // completion: 0 port 0's EX, 1 port 1's EX, 2 the LSU's loads, 3 its stores, 4 port 0's multiplier and
    // MDU (their results), 5 the system unit, 6 / 7 the mispredicted branches of ports 0 / 1 with their restore
    localparam int NCMP = NAP + 7;
    logic [NCMP-1:0]           cmp_valid, cmp_exc, cmp_rp;
    logic [NCMP-1:0][ROBW-1:0] cmp_rob;
    logic [NCMP-1:0][4:0]      cmp_cause;
    logic [ND-1:0]             disp_go;
    assign disp_go = d_go;
    logic                      head_valid, head_fused;
    logic [ROBW-1:0]           rob_restore_rob;
    logic [3:0]                cmt_instret;
    logic [ND-1:0][2:0]        disp_len;                    // halfwords
    logic [ND-1:0]             disp_fused;
    always @(*)
        for (int j = 0; j < ND; j++) begin
            disp_len[j]   = (ds[j].rec.len4 ? 3'd2 : 3'd1) + ((FUSE_AB && ds[j].rec.fused) ? (ds[j].rec.len4b ? 3'd2 : 3'd1) : 3'd0);
            disp_fused[j] = FUSE_AB && ds[j].rec.fused;
        end
    OOO_ROB #(.NROB(NROB), .ROBW(ROBW), .VA(VA), .TAGW(TAGW), .CW(CW), .NCMP(NCMP), .FTQW(FTQW), .ND(ND)) u_rob
        (.clk(clk), .rst_n(rst_n), .rob_avail(rob_avail), .disp_valid(disp_go),
         .disp_pc(dv_pc), .disp_wr(dv_wr), .disp_arch(dv_arch),
         .disp_new(dv_dst), .disp_old(dv_old), .disp_ld(dv_ld), .disp_st(dv_st),
         .disp_fused(disp_fused), .disp_ns(dv_ns), .disp_len(disp_len),
         .disp_ftq(dv_ftq), .disp_exc(dv_exc), .disp_cause(dv_cause),
         .disp_rob(disp_rob),
         .cmp_valid(cmp_valid), .cmp_rob(cmp_rob), .cmp_exc(cmp_exc), .cmp_cause(cmp_cause), .cmp_rp(cmp_rp),
         .br_valid(br_valid), .br_rob(br_rob), .br_mispred(br_mispred), .br_ckpt(br_ckpt),
         .restore(rob_restore), .restore_k(rob_restore_k), .restore_rob(rob_restore_rob), .restore_ckpt(rob_restore_ckpt),
         .head_rob(head_rob), .head_ns(head_ns), .head_valid(head_valid), .head_fused(head_fused), .irq(irq),
         .cmt_valid(cmt_valid), .cmt_wr(cmt_wr), .cmt_arch(cmt_arch), .cmt_new(cmt_new), .cmt_old(cmt_old),
         .cmt_pc(cmt_pc), .cmt_ftq(cmt_ftq), .cmt_ld_n(cmt_ld_n), .cmt_st_n(cmt_st_n), .cmt_instret(cmt_instret),
         .trap(rob_trap), .trap_cause(trap_cause), .trap_pc(trap_pc), .replay(replay), .replay_pc(rob_replay_pc),
         .rcv_ftq(rcv_ftq), .rcv_end(rcv_end));

    // ---- the instructions by ROB entry (what a CSR or system µop reads in EX: its fields, its tval)
    logic [31:0]               rob_insn [NROB];
    always_ff @(posedge clk)
        for (int j = 0; j < ND; j++) if (disp_go[j]) rob_insn[disp_rob[j]] <= ds[j].insn;

    // ---- OOO_TRAP: exceptions and interrupts at the head; the CSRs' trap side
    localparam int NTV = ND + 2;                // tval: the dispatch slots, port 2 (misaligned), port 0 (CSR / system)
    logic [NTV-1:0]            tv_valid;
    logic [NTV-1:0][ROBW-1:0]  tv_rob;
    logic [NTV-1:0][63:0]      tv_val;
    logic                      irq_pend, x_ret, x_sret, csr_trap, csr_int, csr_mret, csr_sret, wfi_wake;
    logic [4:0]                irq_cause, csr_cause;
    logic [VA-1:1]             tvec, mepc, sepc, csr_epc;
    logic [63:0]               csr_tval;
    /* verilator lint_off UNUSEDSIGNAL */      // (fusion is off until B5)
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
        for (int j = 0; j < ND; j++) begin                        // an exception at decode
            tv_valid[j] = disp_go[j] && ds[j].exc;
            tv_rob[j]   = disp_rob[j];
            tv_val[j]   = ds[j].tval;
        end
    end

    // the issue queue and its payload (an exception at decode is never issued)
    /* verilator lint_off UNUSEDSIGNAL */      // (port NAP, the LSU's: not in B2)
    logic [ND-1:0]             iq_disp;
    logic [NAP:0]              iss_valid, iss_wr;
    logic [NAP:0][IQW-1:0]     iss_entry;
    logic [NAP:0][1:0][TAGW-1:0] iss_src;
    logic [NAP:0][TAGW-1:0]    iss_dst;
    logic [NAP:0][NCKPT-1:0]   iss_bm;
    /* verilator lint_off UNUSEDSIGNAL */
    rec_t [NAP:0]              rr_rec;
    /* verilator lint_on UNUSEDSIGNAL */
    logic                      iss_md, mdu_ok, p0_hold, md_ext_v;
    logic [TAGW-1:0]           md_ext_t;
    assign iq_disp = d_go & ~dv_exc;
    // OOO_IQ2: ALU ports 0..3 and LSU0 (port 4); no LSU1 yet (step 1.2 E)
    logic [2:0]                q_ready;
    logic [3:0][IQW-1:0]       q_entry;
    logic [5:0]                q_valid, q_wr;
    logic [5:0][IQW-1:0]       q_ientry;
    logic [5:0][1:0][TAGW-1:0] q_src;
    logic [5:0][TAGW-1:0]      q_dst;
    logic [5:0][NCKPT-1:0]     q_bm;
    OOO_IQ2 #(.N(NIQ), .TAGW(TAGW), .NEXT(2), .NCK(NCKPT), .NA(NAP), .P5(1'b0)) u_iq
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .ns_ok(ns_ok), .mdu_ok(mdu_ok),
         .p0_hold(p0_hold), .disp_ready(q_ready), .disp_entry(q_entry), .disp_valid(iq_disp),
         .disp_port(dv_port), .disp_use(ds_use), .disp_src(ds_src), .disp_rdy(ds_rdy),
         .disp_wr(dv_iqwr), .disp_dst(dv_dst), .disp_lat2(dv_lat2), .disp_bm(d_bmask), .disp_ns(dv_ns),
         .disp_md(dv_md), .disp_st(dv_st),
         .ext_valid({1'b0, md_ext_v}), .ext_tag({TAGW'(0), md_ext_t}),
         .iss_valid(q_valid), .iss_entry(q_ientry), .iss_src(q_src), .iss_wr(q_wr), .iss_dst(q_dst),
         .iss_bm(q_bm), .iss_ns(iss_ns), .iss_md(iss_md), .wk_valid(wk_valid), .wk_tag(wk_tag));
    assign iq_ready   = q_ready;
    assign disp_entry = q_entry;
    always @(*) begin
        for (int p = 0; p <= NAP; p++) begin
            automatic int q = p == NAP ? 4 : p;                 // (the queue's LSU0 is its port 4 whatever NA is)
            iss_valid[p] = q_valid[q];
            iss_entry[p] = q_ientry[q];
            iss_src[p]   = q_src[q];
            iss_wr[p]    = q_wr[q];
            iss_dst[p]   = q_dst[q];
            iss_bm[p]    = q_bm[q];
        end
    end

    rec_t [ND-1:0]             wrec;
    always @(*) begin
        for (int j = 0; j < ND; j++) begin
            wrec[j]     = ds[j].rec;
            wrec[j].rob = disp_rob[j];
            wrec[j].lq  = disp_lq[j];
            wrec[j].sq  = disp_sq[j];
        end
    end
    OOO_IQPL2 #(.N(NIQ), .NBANK(4), .W($bits(rec_t)), .NR(NAP + 1)) u_iqpl
        (.clk(clk), .wr_valid(iq_disp), .wr_entry(disp_entry), .wr_data(wrec),
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

    logic [2*NAP+1:0][TAGW-1:0] prf_ra;
    logic [2*NAP+1:0][63:0]    prf_rd;
    logic [NAP:0]              prf_we;
    logic [NAP:0][TAGW-1:0]    prf_wa;
    logic [NAP:0][63:0]        prf_wd;
    logic [NAP-1:0]            wb_v;
    logic [NAP-1:0][WBW-1:0]   wb_d;
    // the bypass sources: the ALU ports' WB registers and the LSU's
    logic                      lsu_wb_v;
    /* verilator lint_off UNUSEDSIGNAL */      // (a late load needs no wakeup: its dependents were woken two cycles after
    logic                      lsu_wb_late;    //  its issue, and what ran on that guess is replayed after commit, D-12)
    /* verilator lint_on UNUSEDSIGNAL */
    logic [TAGW-1:0]           lsu_wb_t;
    logic [63:0]               lsu_wb_d;
    logic [NAP:0]              byp_v;
    logic [NAP:0][TAGW-1:0]    byp_t;
    logic [NAP:0][63:0]        byp_d;
    always @(*) begin
        for (int q = 0; q < NAP; q++) begin
            byp_v[q] = wb_v[q];
            byp_t[q] = wb_d[q][WBW-1 -: TAGW];
            byp_d[q] = wb_d[q][63:0];
        end
        byp_v[NAP] = lsu_wb_v && lsu_wb_t != '0;    // a load to x0 has tag 0 (never written: the PRF reads it as 0)
        byp_t[NAP] = lsu_wb_t;
        byp_d[NAP] = lsu_wb_d;
    end
    logic [NAP-1:0]            ex_v;
    logic                      pm_w, md_w;     // port 0's multiplier / MDU result written (below)
    logic                      md_wr, wbw0;    // the MDU's register-file write (also when killed now), port 0's
    ex_t  [NAP-1:0]            ex;
    logic [NAP-1:0][63:0]      ex_res;
    /* verilator lint_off UNUSEDSIGNAL */      // (ALU1..3: no branch; port 0's units read port 0's operands)
    logic [NAP-1:0]            ex_tk;
    logic [1:0][VA-1:1]        ex_pc /*verilator public_flat_rd*/;      // (ports 0, 1: the resolution's)
    logic [NAP-1:0][63:0]      ex_a, ex_b;              // the sources after the bypass
    logic [NAP-1:0][NCKPT-1:0] ex_bms;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [NAP-1:0]            wbi_v;                   // into the WB register (and the register file) at the end of the cycle
    logic [NAP-1:0][TAGW-1:0]  wbi_t;
    logic [NAP-1:0][63:0]      wbi_d;

    for (genvar p = 0; p < NAP; p++) begin : g_alu
        // RR
        logic            rr_v;
        logic [NCKPT-1:0] rr_bm, ex_bm;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [NCKPT-1:0] wb_bm;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [RRW-1:0]  rr_d;
        logic [TAGW-1:0] rr_t1, rr_t2, rr_dst;
        logic            rr_wr;
        logic [VA-1:4]   p_line;                                // the pc array's line, the target array's next
        logic [VA-1:1]   p_ta;                                  // (ports 0, 1: the arrays' 2 read ports)
        ex_t             rx;
        OOO_STAGE #(.W(RRW), .NCK(NCKPT)) u_rr
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(iss_valid[p]), .in_bm(iss_bm[p]), .in_data({iss_src[p][1], iss_src[p][0], iss_dst[p], iss_wr[p]}),
             .out_valid(rr_v), .out_bm(rr_bm), .out_data(rr_d));
        assign {rr_t2, rr_t1, rr_dst, rr_wr} = rr_d;
        assign prf_ra[2*p]   = rr_t1;
        assign prf_ra[2*p+1] = rr_t2;
        if (p < 2) begin : g_pa
            assign pa_idx[p] = rr_rec[p].ftq - FTQW'(rr_rec[p].xline);
            assign ta_idx[p] = rr_rec[p].ftq;
            assign p_line    = pa_line[p];
            assign p_ta      = ta_tgt[p];
        end else begin : g_npa                                  // (ports 2, 3: nothing that needs the pc)
            assign p_line    = '0;
            assign p_ta      = '0;
        end
        always @(*) begin
            rx      = '0;
            rx.v1   = prf_rd[2*p];
            rx.v2   = prf_rd[2*p+1];
            rx.t1   = rr_t1;
            rx.t2   = rr_t2;
            rx.dst  = rr_dst;
            rx.wr   = rr_wr;
            rx.rec  = rr_rec[p];
            rx.line = p_line;
            rx.ta   = p_ta;
        end
        // EX
        OOO_STAGE #(.W($bits(ex_t)), .NCK(NCKPT)) u_ex
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(rr_v), .in_bm(rr_bm), .in_data(rx), .out_valid(ex_v[p]), .out_bm(ex_bm), .out_data(ex[p]));

        logic [63:0]     a, b, pc64, imm64;
        logic [VA-1:1]   pc;
        always @(*) begin
            // the bypass: the write-back registers (the results of the cycle before), else the RR read
            a = ex[p].v1;
            b = ex[p].v2;
            for (int q = 0; q < NAP + 1; q++) begin
                if (byp_v[q] && byp_t[q] == ex[p].t1) a = byp_d[q];
                if (byp_v[q] && byp_t[q] == ex[p].t2) b = byp_d[q];
            end
            ex_a[p] = a;
            ex_b[p] = b;
            pc    = {ex[p].line, ex[p].rec.off};
            pc64  = {{(64 - VA){pc[VA-1]}}, pc, 1'b0};
            imm64 = {{32{ex[p].rec.imm[31]}}, ex[p].rec.imm};
        end
        // ALU0 is the full ALU (and the only one with branches, jumps and the pc: OOO_DEC gives
        // them to it, Plan/OOC.md 29.27); ALU1..3 the middle set (OOO_ALU MID)
        OOO_ALU2 #(.FULL(p == 0), .MID(p != 0)) u_alu
            (.s1(a), .s2(b), .imm1(imm64), .pc(pc64), .op1(ex[p].rec.alu_op), .uw1(ex[p].rec.a_uw),
             .shift1(ex[p].rec.a_shift), .word1(ex[p].rec.word_op), .a1_sel(ex[p].rec.a_sel), .b1_imm(ex[p].rec.b_sel),
             .is_br(p < 2 && ex[p].rec.is_br), .br_op(ex[p].rec.br_op), .br_fused(FUSE_AB && ex[p].rec.fused), .br_res1_a(ex[p].rec.b_res1a),
             .br_o_sel(ex[p].rec.b_osel),
             .res1(ex_res[p]), .take_branch(ex_tk[p]));
        logic isbr;                                             // a branch or jalr: resolved, and completed, a cycle later
        if (p < 2) begin : g_br
            logic [VA-1:1] pc_b, pc_nx, b_tgt, j_tgt, nxt, pnx;
            logic          mis;
            always @(*) begin
                /* verilator lint_off UNUSEDSIGNAL */
                logic [63:0] jt;
                /* verilator lint_on UNUSEDSIGNAL */
                ex_pc[p] = pc;
                // (a pair: the branch at pc + the ALU half's length, its offset in joff)
                pc_b  = pc + (ex[p].rec.len4 ? (VA - 1)'(2) : (VA - 1)'(1));
                pc_nx = (FUSE_AB && ex[p].rec.fused) ? pc_b + (ex[p].rec.len4b ? (VA - 1)'(2) : (VA - 1)'(1)) : pc_b;
                b_tgt = (FUSE_AB && ex[p].rec.fused) ? pc_b + (VA - 1)'({{52{ex[p].rec.joff[11]}}, ex[p].rec.joff})
                                        : pc + (VA - 1)'({{32{ex[p].rec.imm[31]}}, ex[p].rec.imm} >> 1);
                jt    = a + {{52{ex[p].rec.joff[11]}}, ex[p].rec.joff};
                j_tgt = jt[VA-1:1];
                nxt   = ex[p].rec.is_jalr ? j_tgt : ex_tk[p] ? b_tgt : pc_nx;
                pnx   = ex[p].rec.pred_taken ? (ex[p].rec.is_jalr ? ex[p].ta : b_tgt) : pc_nx;
                mis   = ex[p].rec.is_jalr ? nxt != pnx : ex_tk[p] != ex[p].rec.pred_taken;
                // resolution: OOO_CTRL, OOO_ROB, OOO_FRONT (FERS, TAGE), through the register below
                e_br_valid[p]   = ex_v[p] && (ex[p].rec.is_br || ex[p].rec.is_jalr);
                e_br_mispred[p] = mis;
                e_br_ckpt[p]    = ex[p].rec.ckpt;
                e_br_next[p]    = nxt;
                e_br_rob[p]     = ex[p].rec.rob;
                e_br_e[p]       = ex[p].rec.e;
                e_br_taken[p]   = ex[p].rec.is_jalr || ex_tk[p];
                e_br_call[p]    = ex[p].rec.call;
                e_br_ret[p]     = ex[p].rec.ret;
                e_rs_valid[p]   = ex_v[p] && ex[p].rec.is_br;
                e_rs_ftq[p]     = ex[p].rec.ftq;
                e_rs_e[p]       = ex[p].rec.e;
                e_rs_taken[p]   = ex_tk[p];
            end
            assign isbr = e_br_valid[p];
        end else begin : g_nbr
            assign isbr = 1'b0;
        end
        always @(*) begin
            // the register file at the edge the result enters the write-back register (port 0: also the
            // multiplier's and the MDU's results, below); completion in EX, but of what an MDU or the system
            // unit completes later, and of a branch or jalr: through the resolution's register, a cycle later
            // (below, Plan/OOC.md 29.25)
            prf_we[p]     = p == 0 ? wbw0 : wbi_v[p];
            prf_wa[p]     = wbi_t[p];
            prf_wd[p]     = wbi_d[p];
            cmp_valid[p]  = ex_v[p] && ex[p].rec.kind != K_MDU && ex[p].rec.kind != K_SYS && ex[p].rec.kind != K_CSR && !isbr;
            cmp_rob[p]    = ex[p].rec.rob;
        end
        assign ex_bms[p] = ex_bm;
        // WB's mask: EX's µop's, but not for the MDU's result on port 0 or the multiplier's on port 1 (they checked it
        // against kill with their own masks this cycle; a later kill can only be of a branch older than the
        // result, whose takers are younger and killed too, and its tag is not given out again in a cycle)
        logic [NCKPT-1:0] wb_in_bm;
        assign wb_in_bm = ((p == 0 && md_w) || (p == 1 && pm_w)) ? '0 : ex_bm;
        // WB
        OOO_STAGE #(.W(WBW), .NCK(NCKPT)) u_wb
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(wbi_v[p]), .in_bm(wb_in_bm), .in_data({wbi_t[p], wbi_d[p]}),
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
         .instret_inc(cmt_instret[2:0]), .hpm_ev('0),
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

    logic            pm_v, md_v, md_we;
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
         .iss_md(iss_md), .iss_bm(iss_bm[0]), .mdu_ok(mdu_ok), .p0_hold(p0_hold), .res_we(md_we),
         .ex_valid(x_mdu), .ex_op(ex[0].rec.xop), .ex_word(ex[0].rec.word_op), .ex_a(ex_a[0]), .ex_b(ex_b[0]),
         .ex_rob(ex[0].rec.rob), .ex_dst(ex[0].dst), .ex_bm(ex_bms[0]), .slot_busy(x_wv || pm_v),   // (pm: the completion port they share)
         .res_valid(md_v), .res_tag(md_t), .res_data(md_d), .res_rob(md_rob), .ext_valid(md_ext_v), .ext_tag(md_ext_t));

    // the write-back registers: port 0 takes the MDU's result, else its EX's; port 1 the multiplier's, else
    // its EX's (Plan/CORE.md 5.13; the issue queue and OOO_MDUP keep them to one a cycle). A result for x0
    // (tag 0: the issue queue keeps no slot for a multiply without a destination) is neither written nor
    // forwarded
    assign pm_w = pm_v && pm_t != '0;
    assign md_w = md_v && md_t != '0;
    // the register file's write from port 0 does not wait on the kill (Plan/OOC.md 29.28): the MDU's raw
    // write, which implies no latency-1 writer (slot_busy), so the choice below can take it too
    assign md_wr = md_we && md_t != '0;
    assign wbw0  = md_wr || x_wv;
    always @(*) begin
        wbi_v[0] = md_w || x_wv;
        wbi_t[0] = md_wr ? md_t : ex[0].dst;
        wbi_d[0] = md_wr ? md_d : (ex[0].rec.kind == K_CSR ? csr_res : ex_res[0]);
        wbi_v[1] = pm_w || (ex_v[1] && ex[1].wr);
        wbi_t[1] = pm_w ? pm_t : ex[1].dst;
        wbi_d[1] = pm_w ? pm_d : ex_res[1];
        for (int p = 2; p < NAP; p++) begin                     // ALU2, ALU3: their own results only
            wbi_v[p] = ex_v[p] && ex[p].wr;
            wbi_t[p] = ex[p].dst;
            wbi_d[p] = ex_res[p];
        end
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
         .in_valid(iss_valid[NAP]), .in_bm(iss_bm[NAP]), .in_data({iss_src[NAP][1], iss_src[NAP][0], iss_dst[NAP], iss_wr[NAP]}),
         .out_valid(p2_rr_v), .out_bm(p2_rr_bm), .out_data(p2_rr_d));
    assign {p2_rr_t2, p2_rr_t1, p2_rr_dst, p2_rr_wr} = p2_rr_d;
    assign prf_ra[2*NAP]   = p2_rr_t1;                          // the base
    assign prf_ra[2*NAP+1] = p2_rr_t2;                          // a store's data
    always @(*) begin
        p2_rx     = '0;
        p2_rx.v1  = prf_rd[2*NAP];
        p2_rx.v2  = prf_rd[2*NAP+1];
        p2_rx.t1  = p2_rr_t1;
        p2_rx.t2  = p2_rr_t2;
        p2_rx.dst = p2_rr_dst;
        p2_rx.wr  = p2_rr_wr;
        p2_rx.rec = rr_rec[NAP];
    end
    OOO_STAGE #(.W($bits(ex_t)), .NCK(NCKPT)) u_ex2
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
         .in_valid(p2_rr_v), .in_bm(p2_rr_bm), .in_data(p2_rx), .out_valid(p2_ex_v), .out_bm(p2_ex_bm), .out_data(p2));
    always @(*) begin
        p2_a = p2.v1;
        p2_b = p2.v2;
        for (int q = 0; q < NAP + 1; q++) begin
            if (byp_v[q] && byp_t[q] == p2.t1) p2_a = byp_d[q];
            if (byp_v[q] && byp_t[q] == p2.t2) p2_b = byp_d[q];
        end
    end

    logic            sq_drained;
    /* verilator lint_off UNUSEDSIGNAL */      // (ld_cancel: replay after commit, no selective replay)
    logic [15:0]     lsu_st_known;
    logic            ld_cancel;
    logic [TAGW-1:0] ld_cancel_tag;
    /* verilator lint_on UNUSEDSIGNAL */
    logic            cmp_ld_v, cmp_ld_e, cmp_ld_rp, cmp_st_v, cmp_st_e;
    /* verilator lint_off UNUSEDSIGNAL */      // (the trace's: the PRF takes rf_we)
    logic            lsu_rf_v;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [ROBW-1:0] cmp_ld_rob, cmp_st_rob;
    OOO_LSU #(.NLQ(16), .NSQ(16), .PAW(PAW), .TAGW(TAGW), .ROBW(ROBW), .NCK(NCKPT), .ND(ND)) u_lsu
        (.clk(clk), .rst_n(rst_n),
         .disp_valid(d_go), .disp_ld(dv_ld), .disp_st(dv_st), .disp_rob(disp_rob),
         .lq_avail(lq_avail), .sq_avail(sq_avail), .disp_lq(disp_lq), .disp_sq(disp_sq),
         .ck_lq_tail(ck_lq_tail), .ck_sq_tail(ck_sq_tail),
         .iss_valid(p2_ex_v), .iss_ld(p2.rec.is_ld), .iss_lq(p2.rec.lq), .iss_sq(p2.rec.sq), .iss_base(p2_a),
         .iss_imm(p2.rec.imm[11:0]), .iss_data(p2_b), .iss_size(p2.rec.msize), .iss_uns(p2.rec.uns),
         .iss_dst(p2.dst), .iss_bm(p2_ex_bm), .lsu_st_known(lsu_st_known),
         .dc_req_valid(dc_req_valid), .dc_req_addr(dc_req_addr), .dc_req_tag(dc_req_tag), .dc_hit(dc_hit),
         .dc_rdata(dc_rdata), .dc_fill_valid(dc_fill_valid), .dc_fill_tag(dc_fill_tag), .dc_fill_data(dc_fill_data),
         .dc_fill_ready(dc_fill_ready), .dc_kill(dc_kill), .sq_drained(sq_drained), .dc_st_valid(dc_st_valid),
         .dc_st_addr(dc_st_addr), .dc_st_data(dc_st_data), .dc_st_mask(dc_st_mask), .dc_st_ready(dc_st_ready),
         .rf_valid(lsu_rf_v), .rf_we(prf_we[NAP]), .rf_tag(prf_wa[NAP]), .rf_data(prf_wd[NAP]),
         .wb_valid(lsu_wb_v), .wb_late(lsu_wb_late), .wb_tag(lsu_wb_t), .wb_data(lsu_wb_d),
         .ld_cancel(ld_cancel), .ld_cancel_tag(ld_cancel_tag),
         .cmp_ld_valid(cmp_ld_v), .cmp_ld_rob(cmp_ld_rob), .cmp_ld_exc(cmp_ld_e), .cmp_ld_rp(cmp_ld_rp),
         .cmp_st_valid(cmp_st_v), .cmp_st_rob(cmp_st_rob), .cmp_st_exc(cmp_st_e),
         .lq_commit(lq_commit), .sq_commit(sq_commit), .restore(restore_k), .kill(kill),
         .restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_sq_tail), .flush_all(flush_all));

    // completion: port 0 (a CSR µop: illegal, replay after a write), port 1, the LSU's loads and stores
    // (misaligned), port 0's multiplier and MDU, the system unit (illegal, replay), the branches and jalrs
    // of ports 0 and 1 (all of them through the resolution's register: completed in EX, as predicted, the
    // misprediction's compare lay on the 4-wide core's paths, Plan/OOC.md 29.25). A load completes into
    // the ROB a cycle after M, through a register for the same reason (the D$'s hit and fill). A late
    // completion of a µop killed or flushed meanwhile is harmless: its entry is out of the ROB, and an
    // entry given out again in that cycle takes its new state first (OOO_ROB's status writes)
    logic            ld_cv, ld_ce, ld_crp;
    logic [ROBW-1:0] ld_crob;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ld_cv <= 1'b0;
        else        ld_cv <= cmp_ld_v;
    end
    always_ff @(posedge clk) begin
        ld_crob <= cmp_ld_rob;
        ld_ce   <= cmp_ld_e;
        ld_crp  <= cmp_ld_rp;
    end
    // A CSR µop completes, and reports its tval, a cycle after EX too: its illegal check lay on the 4-wide core's
    // paths (Plan/OOC.md 29.28). It runs at the ROB head alone, so this costs a cycle a CSR instruction
    logic            csr_cv, csr_ce, csr_crp, csr_tvq;
    logic [ROBW-1:0] csr_crob, csr_tvq_rob;
    logic [63:0]     csr_tvq_val;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_cv  <= 1'b0;
            csr_tvq <= 1'b0;
        end else begin
            csr_cv  <= x_csr;
            csr_tvq <= csr_tv_v;
        end
    end
    always_ff @(posedge clk) begin
        csr_crob    <= ex[0].rec.rob;
        csr_ce      <= csr_exc;
        csr_crp     <= csr_rp;
        csr_tvq_rob <= csr_tv_rob;
        csr_tvq_val <= csr_tv;
    end
    always @(*) begin
        cmp_exc   = {csr_ce, 2'b00, sys_exc, 1'b0, cmp_st_e, ld_ce, (NAP)'(0)};
        cmp_rp    = {csr_crp, 2'b00, sys_rp, 1'b0, 1'b0, ld_crp, (NAP)'(0)};
        cmp_cause = {5'd2, 5'd0, 5'd0, 5'd2, 5'd0, 5'd6, 5'd4, (5 * NAP)'(0)};
    end
    assign cmp_valid[NCMP-1:NAP] = {csr_cv, br_valid, sys_cv, pm_v || md_v, cmp_st_v, ld_cv};
    assign cmp_rob[NCMP-1:NAP]   = {csr_crob, br_rob, sys_rob, pm_v ? pm_rob : md_rob, cmp_st_rob, ld_crob};

    // tval: a misaligned access of port 2 (its address), the CSR unit or the system unit (one at a time at the head)
    always @(*) begin
        logic [63:0] ea;
        logic        mis;
        ea  = p2_a + {{52{p2.rec.imm[11]}}, p2.rec.imm[11:0]};
        mis = (p2.rec.msize == 2'd1 && ea[0]) || (p2.rec.msize == 2'd2 && ea[1:0] != 2'd0) || (p2.rec.msize == 2'd3 && ea[2:0] != 3'd0);
        tv_valid[ND]     = p2_ex_v && mis;
        tv_rob[ND]       = p2.rec.rob;
        tv_val[ND]       = ea;
        tv_valid[ND + 1] = csr_tvq || sys_tv_v;                // (the CSR's a cycle late: never with the system unit's,
        tv_rob[ND + 1]   = sys_tv_v ? sys_tv_rob : csr_tvq_rob;  //  as both run at the ROB head and complete first)
        tv_val[ND + 1]   = sys_tv_v ? sys_tv : csr_tvq_val;
    end

    // an indirect jump (a jalr not a return) writes the BTB: port 0's first
    always @(*) begin
        logic [1:0] ij;
        for (int p = 0; p < 2; p++) ij[p] = ex_v[p] && ex[p].rec.is_jalr && !ex[p].rec.ret;
        e_bt_valid = ij != 2'b00;
        e_bt_pc    = ij[0] ? ex_pc[0] + (VA - 1)'(ex[0].rec.len4) : ex_pc[1] + (VA - 1)'(ex[1].rec.len4);   // its last parcel
        e_bt_tgt   = ij[0] ? e_br_next[0] : e_br_next[1];
    end

    // ---- the resolution through a register (Plan/CORE.md 5.20, Plan/OOC.md 27.3): what EX resolves acts a
    // cycle later (the restore, the kill, the redirect, the predictors' training, the BTB, every branch's
    // completion), so that no block uses EX's comparison in the cycle it is made. Dropped when the branch is
    // killed or flushed as it leaves EX. In the cycle between, the branch is not complete (it cannot commit,
    // nor anything younger), and the younger µops move a stage on, killed there by their masks if it was
    // mispredicted. A branch resolved as predicted completed in EX until Plan/OOC.md 29.25 (the misprediction's
    // compare gated it). Its checkpoint is cleared from this register too (OOO_CTRL's cl_*), not by its
    // commit: from EX, it lay on the 4-wide core's paths (29.21; a checkpoint held a cycle longer cost 2 % with
    // 6 of them).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            br_valid <= '0;
            rs_valid <= '0;
            bt_valid <= 1'b0;
        end else begin
            for (int p = 0; p < 2; p++) begin
                br_valid[p] <= e_br_valid[p] && !flush_all && (ex_bms[p] & kill) == '0;
                rs_valid[p] <= e_rs_valid[p] && !flush_all && (ex_bms[p] & kill) == '0;
            end
            bt_valid <= e_bt_valid && !flush_all &&
                        ((ex_v[0] && ex[0].rec.is_jalr && !ex[0].rec.ret) ? (ex_bms[0] & kill) == '0 : (ex_bms[1] & kill) == '0);
        end
    end
    always_ff @(posedge clk) begin
        br_mispred <= e_br_mispred;
        br_ckpt    <= e_br_ckpt;
        br_next    <= e_br_next;
        br_rob     <= e_br_rob;
        br_pc      <= ex_pc;
        br_e       <= e_br_e;
        br_taken   <= e_br_taken;
        br_call    <= e_br_call;
        br_ret     <= e_br_ret;
        rs_ftq     <= e_rs_ftq;
        rs_e       <= e_rs_e;
        rs_taken   <= e_rs_taken;
        bt_pc      <= e_bt_pc;
        bt_tgt     <= e_bt_tgt;
    end

    /* verilator lint_off PINCONNECTEMPTY */
    OOO_PRF #(.NREG(80), .NW(NAP + 1), .NR(2 * NAP + 2)) u_prf
        (.clk(clk), .ra(prf_ra), .rd(prf_rd), .we(prf_we), .wa(prf_wa), .wd(prf_wd));
    /* verilator lint_on PINCONNECTEMPTY */

`ifdef OOO_TRACE
    // ---- the commit trace
    logic [31:0]     sh_insn [NROB] /*verilator public_flat_rd*/;
    logic [31:0]     sh_insn2 [NROB] /*verilator public_flat_rd*/;  // a pair's branch (tb_core checks its resolution)
    logic            sh_pair [NROB] /*verilator public_flat_rd*/;
    logic [VA-1:1]   sh_pc [NROB] /*verilator public_flat_rd*/;     // (tb_core checks the pc a branch resolves at)
    logic [63:0]     sh_val  [NROB];
    logic            sh_st   [NROB];
    logic [63:0]     sh_sa   [NROB];
    logic [63:0]     sh_sd   [NROB];
    logic [1:0]      sh_ss   [NROB];
    always_ff @(posedge clk) begin
        for (int j = 0; j < ND; j++) if (disp_go[j]) begin
            sh_insn[disp_rob[j]]  <= ds[j].insn;
            sh_insn2[disp_rob[j]] <= ds[j].insn2;
            sh_pair[disp_rob[j]]  <= FUSE_AB && ds[j].rec.fused;
            sh_pc[disp_rob[j]]    <= ds[j].pc;
            sh_st[disp_rob[j]]    <= 1'b0;
        end
        for (int p = 0; p < NAP; p++) if (ex_v[p] && ex[p].wr) sh_val[ex[p].rec.rob] <= ex_res[p];
        if (cmp_ld_v && lsu_rf_v) sh_val[cmp_ld_rob] <= prf_wd[NAP];               // a load's value with its completion (M)
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
        logic [ROBW-1:0] ik;
        tr_valid   = cmt_valid;
        tr_pc      = cmt_pc;
        tr_wr      = cmt_wr;
        tr_rd      = cmt_arch;
        tr_trap    = rob_trap || irq;
        tr_int     = irq;
        tr_cause   = csr_cause;              // (OOO_TRAP's: irq_cause a cycle late)
        tr_trap_pc = trap_pc;
        ik = head_rob;
        for (int k = 0; k < ND; k++) begin
            tr_insn[k]    = sh_insn[ik];
            tr_pair[k]    = sh_pair[ik];
            tr_insn2[k]   = sh_insn2[ik];
            tr_val[k]     = sh_val[ik];
            tr_st[k]      = sh_st[ik];
            tr_st_addr[k] = sh_sa[ik];
            tr_st_data[k] = sh_sd[ik];
            tr_st_size[k] = sh_ss[ik];
            ik = (ik == ROBW'(NROB - 1)) ? '0 : ik + ROBW'(1);
        end
    end
`endif

endmodule : OOO_CORE
