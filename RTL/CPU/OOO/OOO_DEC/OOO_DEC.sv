//---------------------------------------------------------------------------
// OOO_DEC.sv
//
// Decode of mmRISC-3 (D1, Doc/UARCH.md 3.1, 3.3): the 4 instructions the
// fetch buffer gives a cycle, each expanded if it is RVC and decoded, with
// mmRISC-2's CORE_DECOMP and CORE_DEC (RTL/CPU/CORE, taken without change:
// the instruction set is mmRISC-2's, and OOO_ALU uses CORE_EXU's operation
// encoding). Combinational, one slot per instruction, nothing between the
// slots (fusion and renaming come in D2).
//
// What comes out per slot: CORE_DEC's record (the µop's payload: ALU
// operation and operands, immediate, branch, MDU, memory, system, CSR and
// FP fields), and what OOO_FUSE, the issue queue and the ROB need of it:
//   illegal   reserved RVC encoding or an instruction CORE_DEC does not know
//   cls       0 ALU 1 BR 2 JAL 3 JALR 4 LOAD 5 STORE 6 MUL/DIV 7 other, for
//             OOO_FUSE; loads and stores are the integer ones (FP loads and
//             stores, AMO / LR / SC and cbo.zero are "other": not fused in
//             Phase 1, which has no FP renaming)
//   op        1 lui 2 auipc 3 slli(w) 4 srli / srai(w) 5 add(w) / sh*add(.uw)
//             / add.uw 6 addi(w), else 0 (Plan/model/mktrace.py op_of; here
//             from the encoding, so c.li and mv count as addi)
//   rd, rs1, rs2, use_rs1, use_rs2   integer registers only: rd is 0 when
//             no integer register is written (x0 or an FP destination)
//   imm       the immediate, 32 bits (sign extended at its use); its low 12
//             bits are the load / store offset OOO_FUSE pairs on
//   port      0 any ALU, 1 ALU0 only (MUL / DIV, CSR and system: they run
//             at the ROB head beside ALU0; and the ALU operations ALU1 does
//             not have, G0b L7: everything but add / sub, slt / sltu and
//             the logic operations, so shifts, Zba, Zbb, Zbs, Zicond), 2
//             LSU, 3 FPU (Doc/UARCH.md 3.5)
//   lat2      the result comes 2 cycles after issue (mul / mulw, a load)
//   ext_ans   the result comes from outside, woken on ext_* (the other MDU
//             operations: mulh*, clmul*, divides, which mmRISC-2's CORE_MDU
//             takes more than one cycle for, OOO_MDUP; AMO, LR, SC from the
//             LSU at the head)
//   nonspec   runs only at the ROB head (Doc/UARCH.md 3.9: CSR, ECALL,
//             EBREAK, MRET, SRET, WFI, FENCE, FENCE.I, SFENCE.VMA, AMO, LR,
//             SC, cbo.zero)
//   cut       slot k is not taken this cycle: the rare classes (illegal,
//             FP, CSR and system, SFENCE.VMA, AMO / LR / SC, cbo.zero) are
//             decoded in slot 0 only (G0b G2, Doc/UARCH.md 6.3), so a group
//             ends before one in slot 1 to 3; it comes to slot 0 in the
//             next cycle. In slots 1 to 3 the fields only those classes use
//             are 0, and synthesis removes their decoding there. CoreMark
//             has 2 such instructions in 3 million (the timer reads).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DEC
    (
        input  logic [3:0][31:0]    in_inst,    // an RVC one in the low 16 bits
        input  logic [3:0]          in_rvc,

        // for fusion, the issue queue and the ROB
        output logic [3:0]          illegal,
        output logic [3:0][2:0]     cls,
        output logic [3:0][2:0]     op,
        output logic [3:0][4:0]     rd,
        output logic [3:0][4:0]     rs1,
        output logic [3:0][4:0]     rs2,
        output logic [3:0]          use_rs1,
        output logic [3:0]          use_rs2,
        output logic [3:0][31:0]    imm,
        output logic [3:0][1:0]     port,
        output logic [3:0]          lat2,
        output logic [3:0]          ext_ans,
        output logic [3:0]          nonspec,
        output logic [3:0]          cut,        // not taken this cycle (see above); cut[0] is 0

        // the rest of CORE_DEC's record
        output logic [3:0][5:0]     alu_op,
        output logic [3:0]          a_uw,
        output logic [3:0][1:0]     a_shift,
        output logic [3:0][1:0]     a_sel,
        output logic [3:0]          b_sel,
        output logic [3:0]          word_op,
        output logic [3:0]          is_branch,
        output logic [3:0]          is_jal,
        output logic [3:0]          is_jalr,
        output logic [3:0][2:0]     br_op,
        output logic [3:0][3:0]     mdu_op,
        output logic [3:0][4:0]     mem_cmd,
        output logic [3:0][1:0]     mem_size,
        output logic [3:0]          mem_signed,
        output logic [3:0][7:0]     sys,        // fence, fence.i, cbo.zero, ecall, ebreak, mret, sret, wfi
        output logic [3:0]          is_sfence,
        output logic [3:0]          is_csr,
        output logic [3:0][11:0]    csr_addr,
        output logic [3:0][1:0]     csr_op,
        output logic [3:0]          csr_imm_sel,
        output logic [3:0]          csr_wr,
        output logic [3:0]          csr_rd,
        output logic [3:0]          is_fp,
        output logic [3:0][4:0]     fp_op,
        output logic [3:0]          fp_fmt,
        output logic [3:0][2:0]     fp_rm,
        output logic [3:0][2:0]     use_fs,     // fs1, fs2, fs3 (bit 0: fs1)
        output logic [3:0][4:0]     rs3,
        output logic [3:0]          fp_we_rd,
        output logic [3:0]          fp_int_signed,
        output logic [3:0]          fp_int_w
    );

    localparam logic [5:0] ALU_ADD = 6'd0, ALU_SUB = 6'd1, ALU_SLL = 6'd2, ALU_SLT = 6'd3, ALU_SLTU = 6'd4,
                           ALU_XOR = 6'd5, ALU_SRL = 6'd6, ALU_SRA = 6'd7, ALU_OR = 6'd8, ALU_AND = 6'd9;
    localparam logic [4:0] CMD_LOAD = 5'd0, CMD_STORE = 5'd1;

    for (genvar k = 0; k < 4; k++) begin : g_slot
        logic [31:0] x, xi;
        logic        c_ill;
        CORE_DECOMP u_decomp (.insn_c(in_inst[k][15:0]), .insn(x), .illegal(c_ill));
        assign xi = in_rvc[k] ? x : in_inst[k];

        logic        d_ill, we_rd, is_mdu, is_load, is_store, fe, fei, cbo, ecall, ebreak, mret, sret, wfi;
        logic        is_fp_load, is_fp_store;
        // the fields only the rare classes use: given out in slot 0 only
        logic        l_sfence, l_csr, l_csr_imm_sel, l_csr_wr, l_csr_rd, l_fp, l_fp_fmt, l_fp_we_rd, l_fp_int_signed, l_fp_int_w;
        logic [11:0] l_csr_addr;
        logic [1:0]  l_csr_op;
        logic [4:0]  l_fp_op, l_mem_cmd;
        logic [2:0]  l_fp_rm, l_use_fs;
        logic [4:0]  d_rd;
        logic [63:0] d_imm;
        /* verilator lint_off PINCONNECTEMPTY */     // (fp_arith: an FP instruction that is not a load or store)
        CORE_DEC u_dec
            (.insn(xi),
             .rs1(rs1[k]), .rs2(rs2[k]), .rd(d_rd), .use_rs1(use_rs1[k]), .use_rs2(use_rs2[k]), .we_rd(we_rd),
             .imm(d_imm), .alu_op(alu_op[k]), .a_uw(a_uw[k]), .a_shift(a_shift[k]), .a_sel(a_sel[k]), .b_sel(b_sel[k]),
             .word_op(word_op[k]),
             .is_branch(is_branch[k]), .is_jal(is_jal[k]), .is_jalr(is_jalr[k]), .br_op(br_op[k]),
             .is_mdu(is_mdu), .mdu_op(mdu_op[k]),
             .is_load(is_load), .is_store(is_store), .mem_cmd(l_mem_cmd), .mem_size(mem_size[k]), .mem_signed(mem_signed[k]),
             .is_fence(fe), .is_fence_i(fei), .is_cbo_zero(cbo), .is_ecall(ecall), .is_ebreak(ebreak),
             .is_mret(mret), .is_sret(sret), .is_sfence(l_sfence), .is_wfi(wfi), .illegal(d_ill),
             .is_fp(l_fp), .fp_arith(), .fp_op(l_fp_op), .fp_fmt(l_fp_fmt), .fp_rm(l_fp_rm),
             .use_fs1(l_use_fs[0]), .use_fs2(l_use_fs[1]), .use_fs3(l_use_fs[2]), .fp_we_rd(l_fp_we_rd),
             .fp_int_signed(l_fp_int_signed), .fp_int_w(l_fp_int_w), .is_fp_load(is_fp_load), .is_fp_store(is_fp_store),
             .is_csr(l_csr), .csr_addr(l_csr_addr), .csr_op(l_csr_op), .csr_imm_sel(l_csr_imm_sel),
             .csr_wr(l_csr_wr), .csr_rd(l_csr_rd));
        /* verilator lint_on PINCONNECTEMPTY */

        /* verilator lint_off UNUSEDSIGNAL */   // (the immediate is never wider than 32 bits)
        logic [63:0] imm_full;
        /* verilator lint_on UNUSEDSIGNAL */
        assign imm_full = d_imm;
        assign imm[k]   = imm_full[31:0];
        localparam bit S0 = (k == 0);
        assign rs3[k]          = S0 ? xi[31:27] : '0;
        assign sys[k]          = S0 ? {wfi, sret, mret, ebreak, ecall, cbo, fei, fe} : '0;
        assign is_sfence[k]    = S0 && l_sfence;
        assign is_csr[k]       = S0 && l_csr;
        assign csr_addr[k]     = S0 ? l_csr_addr : '0;
        assign csr_op[k]       = S0 ? l_csr_op : '0;
        assign csr_imm_sel[k]  = S0 && l_csr_imm_sel;
        assign csr_wr[k]       = S0 && l_csr_wr;
        assign csr_rd[k]       = S0 && l_csr_rd;
        assign is_fp[k]        = S0 && l_fp;
        assign fp_op[k]        = S0 ? l_fp_op : '0;
        assign fp_fmt[k]       = S0 && l_fp_fmt;
        assign fp_rm[k]        = S0 ? l_fp_rm : '0;
        assign use_fs[k]       = S0 ? l_use_fs : '0;
        assign fp_we_rd[k]     = S0 && l_fp_we_rd;
        assign fp_int_signed[k] = S0 && l_fp_int_signed;
        assign fp_int_w[k]     = S0 && l_fp_int_w;
        // slots 1 to 3 carry integer loads and stores only
        assign mem_cmd[k]      = S0 ? l_mem_cmd : {4'd0, is_store};

        always @(*) begin
            logic ill, ld, st, amo, alu, sysm, simple;
            ill  = d_ill || (in_rvc[k] && c_ill);
            // integer loads and stores; AMO / LR / SC have both or a command of their own
            ld   = is_load  && !is_store && l_mem_cmd == CMD_LOAD  && !is_fp_load;
            st   = is_store && !is_load  && l_mem_cmd == CMD_STORE && !is_fp_store;
            amo  = is_load && (is_store || l_mem_cmd != CMD_LOAD);
            sysm = l_csr || fe || fei || ecall || ebreak || mret || sret || wfi || l_sfence;
            alu  = !ill && !is_branch[k] && !is_jal[k] && !is_jalr[k] && !is_load && !is_store && !is_mdu &&
                   !sysm && !l_fp;
            rare[k]    = ill || l_fp || is_fp_load || is_fp_store || sysm || amo || cbo;
            illegal[k] = S0 && ill;
            rd[k] = (we_rd && !ill) ? d_rd : 5'd0;
            // the class for fusion
            if (ill)                cls[k] = 3'd7;
            else if (is_branch[k])  cls[k] = 3'd1;
            else if (is_jal[k])     cls[k] = 3'd2;
            else if (is_jalr[k])    cls[k] = 3'd3;
            else if (ld)            cls[k] = 3'd4;
            else if (st)            cls[k] = 3'd5;
            else if (is_mdu)        cls[k] = 3'd6;
            else if (alu)           cls[k] = 3'd0;
            else                    cls[k] = 3'd7;
            // the operation kind for fusion
            op[k] = 3'd0;
            if (alu) begin
                if (a_sel[k] == 2'd2)                                       op[k] = 3'd1;   // lui
                else if (a_sel[k] == 2'd1)                                  op[k] = 3'd2;   // auipc
                else if (alu_op[k] == ALU_SLL && b_sel[k] && !a_uw[k])      op[k] = 3'd3;   // slli, slliw
                else if ((alu_op[k] == ALU_SRL || alu_op[k] == ALU_SRA) && b_sel[k]) op[k] = 3'd4;   // srli, srai (w)
                else if (alu_op[k] == ALU_ADD && !b_sel[k])                 op[k] = 3'd5;   // add(w), sh*add(.uw), add.uw
                else if (alu_op[k] == ALU_ADD && b_sel[k])                  op[k] = 3'd6;   // addi(w)
            end
            // an operation ALU1 has (OOO_ALU FULL = 0): add / sub without the
            // Zba changes of the first operand, slt / sltu, xor / or / and
            simple = (alu_op[k] == ALU_ADD && !a_uw[k] && a_shift[k] == 2'd0) || alu_op[k] == ALU_SUB ||
                     alu_op[k] == ALU_SLT || alu_op[k] == ALU_SLTU || alu_op[k] == ALU_XOR ||
                     alu_op[k] == ALU_OR || alu_op[k] == ALU_AND;
            // where it issues, how its result comes
            if (ill)                            port[k] = 2'd1;    // (an exception at decode: never issued)
            else if (is_load || is_store)       port[k] = 2'd2;
            else if (l_fp && S0)                port[k] = 2'd3;    // (FP loads and stores went to the LSU)
            else if (is_mdu || (sysm && S0))    port[k] = 2'd1;
            else if (alu && !simple)            port[k] = 2'd1;    // ALU0 only (L7)
            else                                port[k] = 2'd0;
            lat2[k]    = !ill && ((is_mdu && mdu_op[k] == 4'd0) || ld);
            ext_ans[k] = !ill && ((is_mdu && mdu_op[k] != 4'd0) || (amo && S0));
            nonspec[k] = S0 && !ill && (sysm || amo || cbo);
        end
    end

    // a group ends before a rare class in slot 1 to 3
    logic [3:0] rare;
    always @(*) begin
        cut[0] = 1'b0;
        for (int k = 1; k < 4; k++) cut[k] = cut[k-1] || rare[k];
    end

endmodule : OOO_DEC
