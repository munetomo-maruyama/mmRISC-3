#!/usr/bin/env python3
#---------------------------------------------------------------------------
# mutate_core.py : bug injection into the core's glue (OOO_CORE: D2, DS,
# the ALU ports, branch resolution, commit), judged by tb_core in lock-step
# (B2 of Plan/CORE.md 5)
#
#   ./mutate_core.py          -> results/mutate_core.txt
#   ./mutate_core.py 2 9      only those (by index; nothing written)
#
# Each mutation is one textual change of a copy of RTL/CPU/OOO (it must
# match exactly once, or it is NOT APPLIED); tb_core is built on the copy
# and run on B2's and B3's programs (b2/work: 4 ALU, 10 with branches and
# jumps, 6 with loads and stores, 8 with FP since step 1.8 U2; b3/work: 10 riscv-tests and the console,
# to their HTIF exit) on OOO_CORE with the D$ model, with
# a budget of restores (-restores-max: a fault in what only steers the
# predictors costs mispredictions, not values); then on B4's (b4/work:
# riscv-arch-test, 209 since E1c, illegal.S, dcrace.S, atomic.S, devld.S;
# F, D, Zcd, the FP Sm / Exceptions tests and Plan/fpu's DSP kernels since step
# 1.8 U2; riscv-tests' -p- programs as run_core.sh runs them, 146 with rv64ua,
# 170 with rv64uf / ud and rv64mi-p-csr, 171 with rv64si-p-dirty and b4/dir/vm.S since step 1.8 V1; atomic.S's part 7 since V3b),
# on OOO_CPU then the interrupts' programs (b4/irq, the Interrupts groups,
# each to exit 0: -exit0, step 1.8 I1, Plan/OOC.md 29.78; a mutation with a
# 5th field CPU runs on OOO_CPU, as OOO_DMISS2's, OOO_CPU's, OOO_ICACHE's and CPU_PLIC's do), last on CoreMark (g14 sf + -flto; at most 2,000 replays: about
# 250 now, 21,000 with loads issued past older stores). DETECTED when a run
# fails.
# Every line of the result is to be read: grep NOT.
#
# Left out, as found by the first campaign:
#   - a mispredicted branch's checkpoint cleared too (cl_valid without ~br_mispred): equivalent since
#     Plan/OOC.md 29.21 / 29.23, its clear is always masked by killset (its own restore or an older one's)
#     or by fe_flush (Plan/OOC.md 29.32);
#   - every µop reading 2 sources (ds_use): only later, as what it waits for needlessly is
#     woken in time: cycles, no value (Plan/OOC.md 29.17);
#   - the wrap of the rotated slots past slot 3 masked: they are below the
#     oldest valid slot and never valid (the mask is gone from the RTL);
#   - an empty µop offered with a destination (renaming's ready counting
#     it): with 64 registers, at most 26 in flight (ROB 24, DS 2), the free
#     list never holds fewer than 2, so ready never waits for it here;
#   - the branch masks into the ALU ports' RR and EX stages: a µop killed
#     there acts at most 2 cycles after the restore (EX, then WB), and the
#     restart reaches renaming 6 cycles after it at the earliest (FERS,
#     F0 to F2, D1a, D1b), so the registers, ROB entries and checkpoint ids
#     it holds are not given out again by then. The masks stay: the
#     contract of OOO_STAGE, for units that hold a µop longer;
#   - the register file written by an empty EX stage (we without ex_v): an
#     empty stage carries wr 0 (the issue queue's outputs are an AND-OR of
#     its grants, 0 with none); only a killed µop has wr with its valid
#     bit off, and that is the case above;
#   - a late load's result as an external wakeup of the issue queue: the
#     queue wakes a load's dependents two cycles after its issue whatever
#     happens, and what ran on that guess is replayed after commit (D-12),
#     so nothing waits for a second wakeup (the connection is gone);
#   - (B4) an illegal RVC instruction's tval masked to its 16 bits at
#     dispatch: OOO_FBUF already gives an RVC instruction with its upper
#     half 0 (b4/dir/illegal.S has the next parcel nonzero; the mask is gone);
#   - (Plan/CORE.md 5.13) the multiply's result entering port 1's WB with the
#     mask of port 1's EX µop: CoreMark caught it while the multiply wrote
#     through port 0. Now port 1's EX holds then at most a µop that writes
#     nothing, and the result is dropped only if a branch on port 0 is
#     mispredicted in that very cycle, that µop is younger than it, and a
#     consumer of the multiply older than the branch takes the bypass next:
#     no program makes it. Not equivalent: the guard stays.
#   - (step 1.4 E1c) an AMO's load part without the write permission (m_perm): no
#     translation in Phase 1 (tr_on 0), so the DTLB grants both; for step 1.8.
#   - (step 1.8 U2, kept in the list) an FP -> integer result that does not hold port 0's latency-1
#     writers (212): equivalent in time. The result waits for a free slot; while it waits it is at
#     the ROB's head or behind it, so commit stops, the ROB and the queue fill, and port 0 runs dry:
#     the slot comes. The guard stays (the MDU's way: within two cycles).
#   - (step 1.4 E1c) an AMO's new value computed without its rs2 there (at_sdw without
#     sdv[at_sq]): equivalent in time. rs2's producer is older, so it has woken the data
#     by the time the AMO is the ROB's head; IQ3 sends store data oldest first, so the
#     AMO's goes the next cycle (issue, RR, sd_w), while its address part issues at the
#     head at the earliest and reaches A_DATA after E, M, W and its load's answer. The
#     guard stays.
#---------------------------------------------------------------------------
import glob, os, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
OOO = os.path.normpath(os.path.join(HERE, '../../RTL/CPU/OOO'))
MMIO = os.path.normpath(os.path.join(HERE, '../../RTL/CPU/MMIO'))   # (copied beside OOO: CPU_PLIC's mutations, step 1.8 I2)
W = os.path.join(HERE, 'b2/work')
PROGS = ([os.path.join(W, 'alu-%d.elf' % i) for i in range(1, 5)] + [os.path.join(W, 'br-%d.elf' % i) for i in range(1, 11)] +
         [os.path.join(W, 'ls-%d.elf' % i) for i in range(1, 7)] + [os.path.join(W, 'fp-%d.elf' % i) for i in range(1, 9)])
B3 = os.path.join(HERE, 'b3/work')
HPROGS = [os.path.join(B3, t + '.elf') for t in ('rv64ui-ld_st', 'rv64ui-st_ld', 'rv64ui-lb', 'rv64ui-lhu', 'rv64ui-lwu', 'rv64ui-sb',
                                                 'rv64ui-sh', 'rv64ui-sd', 'rv64ui-jalr', 'rv64uc-rvc', 'htif')]
RMAX = '1.30'      # restores at most 1.3 times the clean run's, program by program (results/core_restores.txt)
APROGS = sorted(p for p in glob.glob(os.path.join(HERE, 'b4/work/*/*.elf'))
                if not __import__('re').search(r'/(irq|Interrupts[A-Za-z]*)/', p))
# the interrupts (step 1.8 I1, Plan/OOC.md 29.78): OOO_CPU's CLINT and PLIC, so on OOO_CPU alone, each to exit 0
IPROGS = sorted(glob.glob(os.path.join(HERE, 'b4/work/irq/*.elf')) + glob.glob(os.path.join(HERE, 'b4/work/InterruptsS*/*.elf')))
CM = [os.path.join(HERE, '../../Plan/trace/work/g14-sflto-zbsc.elf')]     # CoreMark, the last stage
RV = os.environ.get('RVTESTS', os.path.join(HERE, '../../../mmRISC-2/SIM/SIM_CORE/rvtests'))
RPROGS = sorted(os.path.join(RV, t) for t in os.listdir(RV)
                if (__import__('re').fullmatch(r'rv64(ui|um|ua|uf|ud|uc|uzba|uzbb|uzbc|uzbs|uzicond|mi|si)-p-[a-z0-9_]+', t) or
                    __import__('re').fullmatch(r'rv64(ui|um|ua|uf|ud|uc|uzba|uzbb|uzbc|uzbs|uzicond)-v-[a-z0-9_]+', t)) and
                t not in ('rv64mi-p-breakpoint',) and not t.startswith('rv64ua-p-amocas_'))
CS = 'OOO_CSRU/OOO_CSRU.sv'

C = 'OOO_CORE/OOO_CORE.sv'
L3 = 'OOO_LSU4/OOO_LSU4.sv'   # (OOO_LSU3's lines, in OOO_LSU4 since step 1.5b G3)
DM = 'OOO_DMISS2/OOO_DMISS2.sv' # (on OOO_CPU: the runs take VOOO_CPU; the D$ written back since step 1.7b W2)
CP = 'OOO_CPU/OOO_CPU.sv'       # (the same, step 1.7 H3)
IC = 'OOO_ICACHE/OOO_ICACHE.sv' # (the same)
FR = 'OOO_FRONT/OOO_FRONT.sv'   # (the ITLB, step 1.8 V2)
DE = 'OOO_DEC/OOO_DEC.sv'
IQ = 'OOO_IQ3/OOO_IQ3.sv'
SY = 'OOO_SYS/OOO_SYS.sv'
PL = '../MMIO/CPU_PLIC/CPU_PLIC.sv'   # (RTL/CPU/MMIO, from OOO's copy: on OOO_CPU, step 1.8 I2)
RB = 'OOO_ROB/OOO_ROB.sv'      # (the PMU's head_mem, step 1.8 K1)
L4 = L3
CPU = True                      # a 5th field: the mutation runs on OOO_CPU (with the interrupts' programs)
MUT = [
    # D2
    (C, "hd = g_valid[0] ? 2'd0 : g_valid[1] ? 2'd1 : g_valid[2] ? 2'd2 : 2'd3;", "hd = 2'd0;", 'D2: the group not rotated'),
    (C, "s        = rs[j];", "s        = rs[j == 1 ? 0 : j];", "D2: µop 1 from µop 0's slot"),
    (C, "r_go[0] ? 3'd1 : 3'd0;", "r_go[0] ? 3'd2 : 3'd0;", 'D2: two taken when only µop 0 goes'),
    (C, "r_ckpt[j]  = g_is_branch[rs[j]] || g_is_jalr[rs[j]];", "r_ckpt[j]  = g_is_branch[rs[j]];", 'D2: a jalr without a checkpoint'),
    (C, "d2[j].rec.ckpt       = ren_ckpt_id[j];", "d2[j].rec.ckpt       = ren_ckpt_id[0];", 'D2: µop 1 with µop 0\'s checkpoint id'),
    (C, "d2[j].rec.imm        = jmp ? (g_rvc[s] ? 32'd2 : 32'd4) :", "d2[j].rec.imm        = jmp ? 32'd4 :", 'link: pc + 4 for RVC too'),
    (C, "d2[j].rec.a_sel      = jmp ? 2'd1 : g_a_sel[s];", "d2[j].rec.a_sel      = g_a_sel[s];", "link: a jalr's from rs1"),
    (C, "d2[j].rec.xline      = !g_rvc[s] && g_pc[s][4:1] == 4'd15;", "d2[j].rec.xline      = 1'b0;", 'pc: an instruction across two lines from its second'),
    (C, "d2[j].rec.pred_taken = g_taken[s];", "d2[j].rec.pred_taken = 1'b0;", 'every transfer predicted not taken'),
    (C, "d2[j].rec.ret        = g_is_jalr[s] && link_rs1 && !link_rd;", "d2[j].rec.ret        = g_is_jalr[s] && link_rs1;", 'a call through x1 / x5 counted as a return'),
    (C, "d2[j].rec.call       = g_is_jalr[s] && link_rd;", "d2[j].rec.call       = 1'b0;", 'jalr calls not calls (the RAS on a restore)'),
    # DS, ROB, IQ
    (C, "ds[j].dst = r2_wr_all[j] ? r2_dst_all[j] : '0;", "ds[j].dst = r2_dst_all[j];", 'DS: a load to x0 writes a free register (found so, 29.17)'),
    (C, "ds_rdy[j] = ren_rdy[j];", "ds_rdy[j] = 2'b11;", 'DS: every source ready'),
    (C, ".set_v(r1_wr)", ".set_v(4'd0)", 'busy bits never set'),
    (C, "assign ren_ckpt_id = r1_ckid;", "assign ren_ckpt_id = {r1_ckid[3], r1_ckid[2], r1_ckid[0], r1_ckid[0]};", "renaming: µop 1 told µop 0's id"),
    (C, ".cmt_wr(free_valid)", ".cmt_wr({free_valid[3:2], 1'b0, free_valid[0]})", 'renaming: the second commit does not count'),
    (C, ".cmt_old(free_tag)", ".cmt_old({free_tag[3:2], free_tag[0], free_tag[0]})", 'renaming: the old mapping of the first for the second'),
    (C, "wrec[j].rob = disp_rob[j];", "wrec[j].rob = disp_rob[0];", 'the record: µop 1 with µop 0\'s ROB entry'),
    (C, ".disp_new(dv_dst), .disp_old(dv_old)", ".disp_new(dv_dst), .disp_old(dv_dst)", 'ROB: the new mapping as the old'),
    (C, ".ds_ftq(dv_ftq)", ".ds_ftq({dv_ftq[3:2], dv_ftq[0], dv_ftq[1]})", "CTRL: the checkpoints' blocks of µops 0 and 1 swapped"),
    (C, ".disp_ftq(dv_ftq)", ".disp_ftq({dv_ftq[3:1], dv_ftq[1]})", "ROB: µop 0 with µop 1's block (FTQ pops)"),
    (C, ".disp_wr(dv_iqwr)", ".disp_wr(4'b1111)", 'IQ: every µop wakes for its destination'),
    # the ALU ports
    (C, "if (byp_v[q] && ex_m1[q]) a = byp_d[q];", '', 'bypass: none for the first source'),
    (C, "if (byp_v[q] && ex_m2[q]) b = byp_d[q];", '', 'bypass: none for the second source'),
    (C, "byp_v[q] = wb_v[q];", "byp_v[q] = (q == 0) && wb_v[q];", 'bypass: port 1\'s result not forwarded'),
    (C, "wbi_v[1] = pm_w || (ex_v[1] && ex[1].wr);", "wbi_v[1] = pm_w || ex_v[1];", 'WB: a µop of port 1 without a destination forwards'),
    (C, "assign x_wv  = ex_v[0] && ex[0].wr && ex[0].rec.kind != K_MDU;", "assign x_wv  = ex_v[0] && ex[0].rec.kind != K_MDU;",
     'WB: a µop of port 0 without a destination forwards'),
    (C, "assign pa_idx[p] = rr_rec[p].ftq - FTQW'(rr_rec[p].xline);", "assign pa_idx[p] = rr_rec[p].ftq;", 'pc: the line of the last half\'s block'),
    (C, "assign ta_idx[p] = rr_rec[p].ftq;", "assign ta_idx[p] = rr_rec[p].ftq + FTQW'(1);", 'jalr: the next block\'s predicted target'),
    (C, "rx.v2   = prf_rd[2*p+1];", "rx.v2   = prf_rd[2*p];", 'RR: the second source from the first read'),
    # port 2 and the LSU (B3)
    (C, "d2[j].rec.is_ld      = g_cls[s] == 3'd4 || (at && g_mem_cmd[s] != 5'd3) || fpld[j];", "d2[j].rec.is_ld      = 1'b1;", 'every µop of port 2 a load'),
    (C, "d2[j].rec.uns        = !g_mem_signed[s];", "d2[j].rec.uns        = g_mem_signed[s];", 'loads sign- and zero-extended the other way'),
    (C, "wrec[j].lq  = disp_lq[j];", "wrec[j].lq  = disp_lq[0];", 'the record: µop 1 with µop 0\'s LQ entry'),
    (C, "wrec[j].sq  = disp_sq[j];", "wrec[j].sq  = disp_sq[0];", 'the record: µop 1 with µop 0\'s SQ entry'),
    (C, ".ds_ld(dv_ld)", ".ds_ld(4'b0000)", 'CTRL: loads not counted against the LQ'),
    (C, ".disp_ld(dv_ld), .disp_st(dv_st),\n         .disp_fused", ".disp_ld(4'b0000), .disp_st(dv_st),\n         .disp_fused", 'ROB: loads not marked (the LQ never freed)'),
    (C, "sq_alloc = sq_alloc + 3'(d_go[k] && dv_st[k]);", "sq_alloc = sq_alloc + 3'(1'b0);", 'LSU: stores not given SQ entries'),
    (C, '.rr_ld(rr_rec[NAP].is_ld)', ".rr_ld(1'b1)", 'LSU: stores issued as loads'),
    (C, '.rr_lq({rr_rec[NAP+1].lq, rr_rec[NAP].lq})', '.rr_lq({rr_rec[NAP+1].lq, rr_rec[NAP].sq})', "LSU: a load's LQ entry from the SQ field"),
    (C, 'm_ea[m] = m_a[m] + {{52{m_ex[m].rec.imm[11]}}, m_ex[m].rec.imm[11:0]};', 'm_ea[m] = m_a[m];', 'LSU: the offset left out'),
    (C, '.rr_size({rr_rec[NAP+1].msize, rr_rec[NAP].msize})', ".rr_size({2'd3, 2'd3})", 'LSU: every access a double word'),
    (C, '.rr_uns({rr_rec[NAP+1].uns, rr_rec[NAP].uns})', ".rr_uns(2'b00)", 'LSU: lbu / lhu / lwu sign-extended'),
    (C, 'if (byp_v[q] && m_m1[q]) m_a[m] = byp_d[q];', '', 'port 2: no bypass for the base'),
    (C, 'byp_v[NAP + m] = lw_v[m];', "byp_v[NAP + m] = 1'b0;", "bypass: the LSU's result not forwarded"),
    (C, "lw_v[m] <= ld_nv[m] && !ld_fp[m] && ld_nt[m][TAGW-1:0] != '0 && !flush_all;", "lw_v[m] <= ld_nv[m] && !ld_fp[m] && !flush_all;", 'bypass: a load to x0 forwarded (tag 0)'),
    (C, "prf_we[NAP + m] = ld_nv[m] && !ld_fp[m];", "prf_we[NAP + m] = 1'b0;", 'register file: loads not written'),
    (C, "1'b0, 1'b0, ld_crp, (NAP)'(0)}", "1'b0, 1'b0, 1'b0, (NAP)'(0)}", 'ROB: no replay after a load that raised ld_cancel'),
    (C, ".restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_sq_tail), .flush_all", ".restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_lq_tail), .flush_all",
     'LSU: the SQ restored to the LQ\'s tail'),
    (C, ".lq_commit(lq_commit), .sq_commit(sq_commit), .restore(restore_k)", ".lq_commit(lq_commit), .sq_commit(3'b000), .restore(restore_k)", 'LSU: stores never committed'),
    # resolution
    (C, "mis   = ex[p].rec.is_jalr ? nxt != pnx : ex_tk[p] != ex[p].rec.pred_taken;", "mis   = ex[p].rec.is_jalr ? 1'b0 : ex_tk[p] != ex[p].rec.pred_taken;", 'a jalr never mispredicted'),
    (C, "mis   = ex[p].rec.is_jalr ? nxt != pnx : ex_tk[p] != ex[p].rec.pred_taken;", "mis   = ex[p].rec.is_jalr ? nxt != pnx : ex_tk[p];", 'a branch mispredicted when taken'),
    (C, "pc_b  = pc + (ex[p].rec.len4 ? (VA - 1)'(2) : (VA - 1)'(1));", "pc_b  = pc + (VA - 1)'(2);", 'the next pc after an RVC instruction'),
    (C, "jt    = a + {{52{ex[p].rec.joff[11]}}, ex[p].rec.joff};", "jt    = a;", 'a jalr\'s offset left out'),
    (C, "pnx   = ex[p].rec.pred_taken ? (ex[p].rec.is_jalr ? ex[p].ta : b_tgt) : pc_nx;", "pnx   = ex[p].rec.pred_taken ? b_tgt : pc_nx;", 'a jalr predicted to the branch target'),
    (C, "br_valid[p]   = ex_v[p] && (ex[p].rec.is_br || ex[p].rec.is_jalr);", "br_valid[p]   = ex_v[p] && ex[p].rec.is_br;", 'jalrs not resolved'),
    (C, "br_taken[p]   = ex[p].rec.is_jalr || ex_tk[p];", "br_taken[p]   = ex_tk[p];", 'FERS: a jalr not taken (the history)'),
    (C, "rs_taken[p]   = ex_tk[p];", "rs_taken[p]   = 1'b1;", 'TAGE: every branch taken'),
    (C, "rs_valid[p]   = ex_v[p] && ex[p].rec.is_br;", "rs_valid[p]   = 1'b0;", 'TAGE: no outcomes'),
    (C, "bt_valid = ij != 2'b00;", "bt_valid = 1'b0;", 'BTB: never written'),
    (C, "cmp_valid[p]  = ex_v[p] && ex[p].rec.kind", "cmp_valid[p]  = ex_v[p] && ex[p].wr && ex[p].rec.kind", 'ROB: µops without a destination never complete'),
    (C, "cmp_rob[p]    = ex[p].rec.rob;", "cmp_rob[p]    = ex[0].rec.rob;", 'ROB: port 1 completes port 0\'s entry'),
    # B4: exceptions at decode
    (C, "d2[j].exc            = ifl || g_illegal[s] || fexc[j] || g_sys[s][4] || g_sys[s][3];",
     "d2[j].exc            = ifl || g_illegal[s] || fexc[j] || g_sys[s][4];", 'ECALL not an exception'),
    (C, "d2[j].exc            = ifl || g_illegal[s] || fexc[j] || g_sys[s][4] || g_sys[s][3];",
     "d2[j].exc            = ifl || g_illegal[s] || g_sys[s][4] || g_sys[s][3];", 'an FP instruction that traps (FS off, a reserved rounding mode) not illegal (U2: was no FPU)'),
    (C, "g_sys[s][4] ? 5'd3 : (5'd8 | 5'(priv));", "g_sys[s][4] ? 5'd3 : 5'd8;", 'ECALL: the cause without the level'),
    (C, "g_sys[s][4] ? 5'd3 : (5'd8 | 5'(priv));", "g_sys[s][4] ? 5'd2 : (5'd8 | 5'(priv));", 'EBREAK: cause 2'),
    (C, "tv_val[j]   = ds[j].tval;", "tv_val[j]   = ds[0].tval;", 'tval at decode: µop 1 with µop 0\'s'),
    # B4: the µops of port 0's units
    (C, "d2[j].rec.kind       = g_cls[s] == 3'd6 ? K_MDU : g_is_csr[s] ? K_CSR : sysop_v ? K_SYS : K_ALU;",
     "d2[j].rec.kind       = g_is_csr[s] ? K_CSR : sysop_v ? K_SYS : K_ALU;", 'multiplies and divides on the ALU'),
    (C, "sysop_v  = g_sys[s][0] || g_sys[s][1] || g_is_sfence[s] || g_sys[s][5] || g_sys[s][7] || g_sys[s][6];",
     "sysop_v  = g_sys[s][0] || g_sys[s][1] || g_is_sfence[s] || g_sys[s][7] || g_sys[s][6];", 'MRET an ALU µop'),
    (C, "sysop    = g_sys[s][1] ? 3'd1 :", "sysop    = g_sys[s][1] ? 3'd0 :", 'FENCE.I run as FENCE'),
    (C, "d2[j].ns             = g_nonspec[s];", "d2[j].ns             = 1'b0;", 'CSR and system µops issued before the head'),
    (C, "d2[j].md             = g_ext_ans[s];", "d2[j].md             = 1'b0;", 'the MDU\'s µops wake their dependents at issue'),
    (C, "rob_insn[disp_rob[j]] <= ds[j].insn;", "rob_insn[disp_rob[0]] <= ds[j].insn;", 'the instruction bits of µop 1 at µop 0\'s entry'),
    (C, ".ex_valid(x_csr), .ex_op(x_ins[14:12]), .ex_addr(x_ins[31:20]), .ex_rs1(x_ins[19:15]), .ex_src(ex_a[0]),",
     ".ex_valid(x_csr), .ex_op(x_ins[14:12]), .ex_addr(x_ins[31:20]), .ex_rs1(x_ins[19:15]), .ex_src(ex_b[0]),", 'CSR: rs1 from the second read'),
    (C, "(ex[0].rec.kind == K_CSR ? csr_res : ex_res[0])", "ex_res[0]", 'CSR: the old value not written'),
    (C, "assign x_mdu = ex_v[0] && ex[0].rec.kind == K_MDU && ex[0].rec.xop != 4'd0;",
     "assign x_mdu = ex_v[0] && ex[0].rec.kind == K_MDU;", 'a multiply to the MDU as well'),
    (C, ".slot_busy(x_wv || pm_we)", ".slot_busy(x_wv)", 'the MDU\'s result and the multiply\'s in one cycle (one completion port)'),
    (C, ".slot_busy(x_wv || pm_we)", ".slot_busy(pm_we)", 'the MDU\'s result over an ALU0 µop\'s'),
    (C, "wbi_v[1] = pm_w || (ex_v[1] && ex[1].wr);", "wbi_v[1] = ex_v[1] && ex[1].wr;", 'port 1: the multiply\'s result not written'),
    (C, "assign wbw1  = pm_wr || (ex_v[1] && ex[1].wr);", "assign wbw1  = ex_v[1] && ex[1].wr;", 'port 1: the multiply not written to the register file'),
    (C, "assign pm_wr = pm_we && pm_t != '0;", "assign pm_wr = pm_we;", 'port 1: a multiply to x0 takes the file\'s write and the choice'),
    (C, "assign pm_w = pm_v && pm_t != '0;", "assign pm_w = pm_v;", 'port 1: a multiply to x0 takes the write slot'),
    (C, "assign md_w = md_v && md_t != '0;", "assign md_w = md_v;", 'port 0: a divide to x0 forwarded (tag 0)'),
    (C, ".disp_md(dv_md), .disp_st(dv_st),", ".disp_md(dv_md), .disp_st(4'b0000),", 'IQ: loads not held for older stores (replays)'),
    (C, ".mret_en(csr_mret), .sret_en(csr_sret)", ".mret_en(csr_mret), .sret_en(1'b0)", 'SRET: the CSRs not restored'),
    # B4: completion and tval
    (C, "cmp_valid[p]  = ex_v[p] && ex[p].rec.kind != K_MDU && ex[p].rec.kind != K_SYS &&",
     "cmp_valid[p]  = ex_v[p] && ex[p].rec.kind != K_MDU &&", 'a system µop complete at EX'),
    (C, "cmp_exc   = {2'b00, csr_ce, 2'b00,", "cmp_exc   = {2'b00, 1'b0, 2'b00,", 'CSR: an illegal access completes'),
    (C, "cmp_rp    = {2'b00, csr_crp, 2'b00,", "cmp_rp    = {2'b00, 1'b0, 2'b00,", 'CSR: no replay after a write'),
    (C, "sys_rob, pm_v ? pm_rob : md_rob,", "sys_rob, md_rob,", 'the multiply completes the MDU\'s entry'),
    (C, "tv_valid[ND]     = l_tv_v[0];", "tv_valid[ND]     = 1'b0;", 'tval: LSU0\'s exceptions\' address not given (from OOO_LSU4 since step 1.8 V1)'),
    (C, "tv_valid[ND + 1] = csr_tvq || sys_tv_v;", "tv_valid[ND + 1] = sys_tv_v;", "tval: an illegal CSR access's not given"),
    (C, "for (int j = 0; j < ND; j++) if (disp_go[j]) rob_insn[disp_rob[j]] <= ds[j].insn;", "for (int j = 0; j < 2; j++) if (disp_go[j]) rob_insn[disp_rob[j]] <= ds[j].insn;", '4 wide: slots 2 and 3 leave rob_insn unwritten (a CSR µop reads a stale one)'),
    (C, "assign g_take = r_go[3] ? 3'd4 :", "assign g_take = r_go[3] ? 3'd3 :", '4 wide: four go, three taken (one runs twice)'),
    (C, "dv_port[j]  = ds[j].port;", "dv_port[j]  = ds[j & 1].port;", '4 wide: slots 2 and 3 with the ports of slots 0 and 1'),
    # B4: OOO_CSRU
    (CS, "ir_skip  <= ex_addr == 12'hB02 || (rd_data[2] && !wdata[2]);", "ir_skip  <= rd_data[2] && !wdata[2];", 'minstret: a write counts its own commit'),
    (CS, "ir_force <= ex_addr == 12'h320 && !rd_data[2] && wdata[2];", "ir_force <= 1'b0;",
     'mcountinhibit: setting IR, its own commit not counted (under the new bit)'),
    # the resolution through a register (Plan/CORE.md 5.20)
    (C, "ex[p].rec.kind != K_CSR && !isbr &&", "ex[p].rec.kind != K_CSR &&", 'a branch complete in EX, mispredicted or not (younger µops commit before the restore)'),
    (C, "br_valid[p] <= e_br_valid[p] && !flush_all && (ex_bms[p] & kill) == '0;", "br_valid[p] <= e_br_valid[p] && !flush_all;", 'a branch killed as it leaves EX resolves'),
    (C, "br_valid[p] <= e_br_valid[p] && !flush_all && (ex_bms[p] & kill) == '0;", "br_valid[p] <= e_br_valid[p] && (ex_bms[p] & kill) == '0;", 'a branch flushed as it leaves EX resolves'),
    (C, "iw_ack, csr_cv, br_valid, sys_cv,", "iw_ack, csr_cv, br_valid & ~br_mispred, sys_cv,", 'a mispredicted branch never completes'),
    (C, "tv_valid[ND + 2] = l_tv_v[1];", "tv_valid[ND + 2] = 1'b0;", 'tval: LSU1\'s exceptions\' address not given'),
    (L3, "return pa < CBASE || pa >= CTOP || (uc_line_v && pa[PAW-1:6] == uc_line);", "return pa < CBASE || pa >= CTOP;", 'uncached: the bench\'s line cached'),
    (L3, "(!m_ld || (!m_uc && (f_any ? f_ok : m_hit))));", "(!m_ld || (f_any ? f_ok : m_hit)));", 'uncached: a load for a device takes the D$ or the SQ'),
    (L3, "ugo[e] = luc[e] && !lucd[e] && lrob[e] == head_rob && sq_drained && !uc_busy;", "ugo[e] = luc[e] && !lucd[e] && lrob[e] == head_rob && !uc_busy;", 'uncached: a load goes before older stores reach the devices'),
    (L3, "ugo[e] = luc[e] && !lucd[e] && lrob[e] == head_rob && sq_drained && !uc_busy;", "ugo[e] = luc[e] && !lucd[e] && sq_drained && !uc_busy;", 'uncached: a load goes before it is the head'),
    (L3, "d_back  = d2_v && (d2_uc ? uc_busy : ", "d_back  = d2_v && (d2_uc ? 1'b0 : ", 'uncached: a store for a device lost while another access is out'),
    (L3, "st_uc_go = d2_v && d2_uc && !uc_busy;", "st_uc_go = d2_v && d2_uc;", 'uncached: two accesses to devices at once'),
    (L3, "m_ucd  = p == 0 && m_ld && m_try && !m_id[LW] && lucd[m_id[LW-1:0]];", "m_ucd  = 1'b0;", 'uncached: the device\'s word never taken'),
    (DM, "if (miss_valid && !asked(miss_line, miss_vx, aq_n) && n != (QW + 1)'(NAQ)) begin", "if (1'b0) begin", 'OOO_DMISS2: a load\'s miss never filled'),
    (DM, "tw_en   = st == S_SINV || st == S_INV || st == S_TAG;", "tw_en   = st == S_SINV || st == S_TAG;", 'OOO_DMISS2: the victim\'s tag valid while its words are replaced'),
    (DM, "assign aq_pop = st == S_IDLE && !u_pend && !fl_req && !p_pend && aq_n != '0 && wr_quiet;", "assign aq_pop = st == S_IDLE && !u_pend && !fl_req && !p_pend && aq_n != '0;", 'OOO_DMISS2: a fill before the write out has its answer'),
    (DM, "if (ev_go ? int'(ev_way) == w : dirty_set && int'(dirty_way) == w)", "if (ev_go ? int'(ev_way) == w : 1'b0 && int'(dirty_way) == w)", 'OOO_DMISS2: a store never makes its line dirty'),
    (DM, "assign ev_go  = ((st == S_INV || st == S_SINV) && ev_dirty) ||", "assign ev_go  = ((st == S_SINV) && ev_dirty) ||", 'OOO_DMISS2: a dirty victim not written out'),
    (DM, "e_line <= {tagr[ev_way][TW-1:0], t_set[5:0]};", "e_line <= {f_line[PAW-1:12], t_set[5:0]};", 'OOO_DMISS2: a victim written out at the new line\'s address'),
    (DM, "assign m_axi4_wvalid  = e_on && e_aw && e_w < e_c;", "assign m_axi4_wvalid  = e_on && e_aw;", 'OOO_DMISS2: a beat before its word is in the buffer'),
    (DM, "S_FL:   if (!ev_dirty || !e_on) begin", "S_FL:   if (1'b1) begin", 'OOO_DMISS2: FENCE.I\'s walk passes a dirty line'),
    (DM, "assign fl_done = st == S_FLW && wr_quiet;", "assign fl_done = st == S_FLW;", 'OOO_DMISS2: FENCE.I done before the last write out is answered'),
    (DM, "rf_addr = {f_vx, f_line[11:6], f_beat};", "rf_addr = {f_vx, f_line[11:6], 3'd0};", 'OOO_DMISS2: every word of a fill to the line\'s first'),
    (CP, ".dc_vr_way(dc_vr_way)", ".dc_vr_way(2'd0)", 'W2: the victim\'s copy read in way 0'),
    (CP, ".miss_vx(dc_miss_vx)", ".miss_vx(2'd0)", "C2: a load's miss filled in the set of vx 0"),
    (CP, ".st_miss_vx(dc_st_miss_vx)", ".st_miss_vx(2'd0)", "C2: a store's miss filled in the set of vx 0"),
    (C, ".e_addr({m_ea[1], rt_q ? {{(64 - PAW){rt_bq[PAW-1]}}, rt_bq} : m_ea[0]})", ".e_addr({m_ea[1], m_ea[0]})", 'LSU0: a try takes the address left in EX'),
    (C, "            disp_st[k] = st;", "            disp_st[k] = st + 5'd1;", 'LSU: a load takes the store after it as older'),
    (C, "            ck_lq_tail[k] = lt;", "            ck_lq_tail[k] = l3_lq_tail;", 'LSU: a restore takes the LQ\'s tail of the group\'s start'),
    (C, "            csr_cv  <= x_csr;", "            csr_cv  <= 1'b0;", 'a CSR µop never completes'),
    (C, "        csr_ce      <= csr_exc;", "        csr_ce      <= 1'b0;", 'an illegal CSR access completes without its exception'),
    (C, "    assign wbw0  = md_wr || x_wv || f2i_wr;", "    assign wbw0  = x_wv || f2i_wr;", 'register file: the MDU\'s results not written'),
    (C, "ex[p].rec.kind != K_SYS && ex[p].rec.kind != K_CSR && !isbr &&", "ex[p].rec.kind != K_SYS && !isbr &&", 'a CSR µop completes in EX too (twice: the late one may hit the next µop)'),
    (C, "        for (int q = 0; q < NAP; q++) begin\n            byp_v[q] = wb_v[q];", "        for (int q = 0; q < NAP - 1; q++) begin\n            byp_v[q] = wb_v[q];", 'bypass: ALU3\'s result not forwarded'),
    (C, "            wbi_v[p] = ex_v[p] && ex[p].wr;\n            wbi_t[p] = ex[p].dst;", "            wbi_v[p] = ex_v[p] && ex[p].wr && p != 3;\n            wbi_t[p] = ex[p].dst;", 'register file: ALU3\'s results not written'),
    (C, "iw_ack, csr_cv, br_valid, sys_cv,", "iw_ack, csr_cv, br_valid & br_mispred, sys_cv,", 'a branch resolved as predicted never completes'),
    (C, "cmp_exc   = {2'b00, csr_ce, 2'b00, sys_exc, 1'b0, cmp_st_e, ld_ce,", "cmp_exc   = {2'b00, csr_ce, 2'b00, sys_exc, 1'b0, cmp_st_e, cmp_ld_e,", "a load's exception a cycle before its completion"),
    (CS, "tv_val   = {32'd0, ex_inst};", "tv_val   = 64'd0;", 'CSR: an illegal access\'s tval 0'),
    (CS, "(fs == 2'b00 && (ex_addr == 12'h001", "(1'b0 && (ex_addr == 12'h001", 'CSR: fcsr with mstatus.FS off not illegal'),
    # step 1.5b G3 (Plan/OOC.md 29.53): a store's data on port 1, the wait table
    (C, "cmp_valid[p]  = ex_v[p] && ex[p].rec.kind != K_MDU && ex[p].rec.kind != K_SYS && ex[p].rec.kind != K_CSR && !isbr &&\n                            !ex[p].sd && !ex[p].rec.fx;", "cmp_valid[p]  = ex_v[p] && ex[p].rec.kind != K_MDU && ex[p].rec.kind != K_SYS && ex[p].rec.kind != K_CSR && !isbr && !ex[p].rec.fx;", 'G3: a store completes when its data goes on port 1'),
    (C, 'rx.sd   = rr_sd;', "rx.sd   = 1'b0;", "G3: a store's data never reaches the LSU"),
    (C, '.in_data({p == 1 && iss_sd, iss_src[p][1]', '.in_data({iss_sd, iss_src[p][1]', "G3: every ALU port's µop taken for a store's data"),
    (C, 'sd_data <= ex_b[1];', 'sd_data <= ex[1].v2;', "G3: a store's data without the bypass"),
    (C, 'sd_sq   <= ex[1].rec.sq;', 'sd_sq   <= ex[1].rec.lq;', "G3: a store's data into another SQ entry"),
    (C, 'sd_size <= ex[1].rec.msize;', "sd_size <= 2'd3;", "G3: a store's data not replicated by its size"),
    (C, 'else        sd_v <= ex[1].sd;', "else        sd_v <= 1'b0;", "G3: a store's data never written into the SQ"),
    (C, '.disp_wt(dv_wt)', ".disp_wt('0)", 'G3: the wait table never read'),
    (C, "for (int m = 0; m < 2; m++) if (cmp_ld_v[m] && cmp_ld_sd[m]) rob_sd[cmp_ld_rob[m]] <= 1'b1;", '', 'G3: the wait table never written'),
    (C, 'd2[j].wt             = wt_g[s];', "d2[j].wt             = 1'b0;", "G3: the group's wait bits dropped"),
    # step 1.7 H3 (Plan/OOC.md 29.58): the I$, the arbiter and the L2 in OOO_CPU
    (CP, ".AXI_ID(4'd2)) u_icache", ".AXI_ID(4'd0)) u_icache", "H3: the I$'s fills answered to the D$"),
    (CP, ".ic_resp_data(ic_resp_data), .ic_flush(ic_flush)", ".ic_resp_data(ic_resp_data), .ic_flush(1'b0)", 'H3: FENCE.I never reaches the I$'),
    (IC, "if (ic_flush && !ic_done && !cl && !busy && !s1_miss) cl <= 1'b1;", "if (ic_flush && !ic_done && !cl && !busy && !s1_miss) ic_done <= 1'b1;", 'H3: FENCE.I done without the sweep (stale code runs)'),
    # step 1.4 E1c (Plan/OOC.md 29.74): the atomics (Zaamo, Zalrsc, their Exceptions tests, rv64ua, b4/dir/atomic.S)
    (C, "g_mem_cmd[s] <= 5'd12 && !g_is_fp[s]", "g_mem_cmd[s] <= 5'd11 && !g_is_fp[s]", 'E1c: AMOMAXU not an atomic'),
    (C, "d2[j].st             = g_cls[s] == 3'd5 || (at && g_mem_cmd[s] != 5'd2) || fpst[j];", "d2[j].st             = g_cls[s] == 3'd5 || (at && g_mem_cmd[s] == 5'd3) || fpst[j];", 'E1c: an AMO without an SQ entry'),
    (C, ".ext_valid({at_wk_v, md_ext_v || f2i_wr})", ".ext_valid({1'b0, md_ext_v || f2i_wr})", "E1c: an atomic's result wakes nothing"),
    (C, "cmp_st_cause == 2'd1 ? 5'd7 : 5'd6", "5'd6", "E1c: an AMO's access fault reported as misaligned"),
    (C, "cmp_ld_cause[m] == 2'd1 ? 5'd5 : 5'd4", "5'd4", "E1c: an LR's access fault reported as misaligned"),
    (L4, "at_cause <= w_cause;", "at_cause <= 2'd0;", "E1c: an atomic's cause lost (misaligned; one tval for all since step 1.8 V1)"),
    (DE, "lr   = amo && l_mem_cmd == CMD_LR;", "lr   = 1'b0;", 'E1c: LR answered from outside, as an AMO'),
    (IQ, "split[i] = st[i];", "split[i] = st[i] && !ns[i];", "E1c: an AMO's or SC's data never goes (not split, as before E1c)"),
    (IQ, "assign iss_ns = (((issued & ~st) | a_now) & ns) != '0;", "assign iss_ns = (issued & ns) != '0;", "E1c: an AMO's data counts as its issue"),
    (L3, "if (w_live && w_lr && w_ok) resv_v <= 1'b1;", "if (1'b0) resv_v <= 1'b1;", 'E1c: LR sets no reservation (every SC fails)'),
    (L3, "w_lr   <= m_at == 4'd2;", "w_lr   <= m_at == 4'd2 && !m_try;", 'E1c: an LR that waited (a miss) sets no reservation'),
    (L3, "else if (sc_dec) resv_v <= 1'b0;", "else if (1'b0) resv_v <= 1'b0;", 'E1c: SC keeps the reservation'),
    (L3, "assign sc_fail = !(resv_v && resv_a == w_a);", "assign sc_fail = !resv_v;", 'E1c: SC succeeds at any address'),
    (L3, "if (sc_dec && sc_fail && sc_sq == SW'(i)) smask[i] <= 8'd0;", '', 'E1c: an SC that fails stores'),
    (L3, "at_res <= sc_fail;", "at_res <= 1'b0;", "E1c: an SC's result always 0"),
    (L3, "(m_atw ? (at_sc ? {63'd0, at_res} : at_old) : m_u)", "(m_atw ? at_old : m_u)", "E1c: an SC's result is an AMO's register"),
    (L3, "assign ld_nt[p] = m_atw ? at_dst : m_dst;", "assign ld_nt[p] = m_dst;", "E1c: an atomic's result into another register"),
    (L3, "else        m_atw <= at_ph == A_INJ && !m_atw && !(e_v && e_ld) && !flush_all;", "else        m_atw <= at_ph == A_INJ && !m_atw && !flush_all;", "E1c: an atomic's result over a load's in M"),
    (L3, "&& sp[f_idx] && !sat[f_idx] && st_r[f_idx]", "&& sp[f_idx] && st_r[f_idx]", "E1c: a younger load forwards from an AMO or SC not decided"),
    (L3, "e_sq   <= rr_valid[0] ? rr_sq : r_at[3:2] != 2'd0 ? at_sq : r_id[SW-1:0];", "e_sq   <= rr_valid[0] ? rr_sq : r_id[SW-1:0];", "E1c: an AMO's try writes another SQ entry"),
    (L3, "if (m_amo) at_old <= ld_d[p];", "if (m_amo && !m_try) at_old <= ld_d[p];", "E1c: an AMO's old value from its first M (a miss's)"),
    (L3, "if (at_w) at_new = {2{at_new[31:0]}};", '', "E1c: an AMO.W's new value not replicated (its upper half)"),
    (L3, "ltu = w ? a[31:0] < b[31:0] : a < b;", "ltu = a < b;", 'E1c: AMOMINU.W / AMOMAXU.W compare 64 bits'),
    (L3, "4'd9:    return lt  ? x : y;", "4'd9:    return ltu ? x : y;", 'E1c: AMOMIN unsigned'),
    (L3, "assign at_sdw = at_ph == A_DATA && sdv[at_sq] && !sd_v;", "assign at_sdw = at_ph == A_DATA && sdv[at_sq];", "E1c: an AMO's new value lost to a store's data written then"),
    (L3, "assign cmp_ld_valid[p] = w_live && w_ld && (w_ok || w_exc) && !w_amo;", "assign cmp_ld_valid[p] = w_live && w_ld && (w_ok || w_exc);", 'E1c: an AMO completes with its load part'),
    (L3, "at_go        = at_ph == A_CMP && (!at_sc || at_exc || sdv[at_sq])", "at_go        = at_ph == A_CMP && (!at_sc || at_exc)", 'E1c: an SC completes before its data is there'),
    (L3, "assign at_uc  = m_at != 4'd0 && m_uc;", "assign at_uc  = 1'b0;", 'E1c: an atomic outside the memory goes on'),
    # step 1.8 I1 (Plan/OOC.md 29.78): the interrupts, on OOO_CPU (its CLINT and PLIC) with b4/irq and the Interrupts tests
    (C, ".irq_m_timer(irq_m_timer)", ".irq_m_timer(1'b0)", 'I1: no machine timer interrupt', CPU),
    (C, ".irq_m_soft(irq_m_soft)", ".irq_m_soft(1'b0)", 'I1: no machine software interrupt', CPU),
    (C, ".irq_m_ext(irq_m_ext)", ".irq_m_ext(1'b0)", 'I1: no machine external interrupt', CPU),
    (C, ".irq_s_ext(irq_s_ext)", ".irq_s_ext(1'b0)", 'I1: no supervisor external interrupt', CPU),
    (C, ".mtime(mtime),", ".mtime(64'd0),", 'I1: the CSRs\' time at 0 (Sstc compares with it)', CPU),
    (CP, ".ext_irq({irq_src, 1'b0})", ".ext_irq({irq_src[30:1], 2'b0})", "I1: the PLIC's sources one off"),
    (CP, "<= {mm_m_soft, mm_m_timer, mm_m_ext, mm_s_ext};", "<= {mm_m_soft, mm_m_timer, mm_s_ext, mm_m_ext};", "I1: the PLIC's contexts swapped"),
    (DM, "assign m_axil_awaddr  = u_a;", "assign m_axil_awaddr  = {u_a[PAW-1:3], 3'b000};", "I1: a device's write at its word's address (the PLIC's register at +4 missed)"),
    (DM, "assign m_axil_araddr  = u_a;", "assign m_axil_araddr  = {u_a[PAW-1:3], 3'b000};", "I1: a device's read at its word's address (the claim at +4 missed)"),
    (L3, "low_byte(d2_m)};", "3'b000};", "I1: a store to a device at its word's address", CPU),
    (L3, "if (ev || (w_ucs[0] && w_lqs[0] == LW'(e)) || (w_ucs[1] && w_lqs[1] == LW'(e))) lretry[e] <= 1'b1;", "if (ev) lretry[e] <= 1'b1;", 'I1: a load for a device that waits is tried only at an event (devld.S hangs)'),
    (SY, "OP_WFI:    ill = priv == PRIV_U || (priv == PRIV_S && tw);", "OP_WFI:    ill = priv != PRIV_M && tw;", 'I1: WFI in U mode waits (Spike: illegal)', CPU),
    # step 1.8 I2 (Plan/OOC.md 29.79): CPU_PLIC's choice a tree (irq.S part 3b polls the claims), the lines registered
    (PL, "if (t_prio[c][2*k + 1] > t_prio[c][2*k]) begin", "if (t_prio[c][2*k + 1] >= t_prio[c][2*k]) begin", "I2: the PLIC's tree: equal priorities to the higher number"),
    (PL, "if (pending[s] && enable[c][s] && (prio[s] > threshold[c]))", "if (pending[s] && enable[c][s] && (prio[s] >= threshold[c]))", "I2: the PLIC's threshold lets its own priority through"),
    (PL, "if (pending[s] && enable[c][s] && (prio[s] > threshold[c]))", "if (pending[s] && (prio[s] > threshold[c]))", "I2: the PLIC's choice ignores the context's enables"),
    (PL, "t_id[c][k]   = t_id[c][2*k + 1];", "t_id[c][k]   = t_id[c][2*k];", "I2: the PLIC's tree keeps the right child's priority with the left one's number"),
    (CP, "else        {irq_m_soft, irq_m_timer, irq_m_ext, irq_s_ext} <=", "else if (0) {irq_m_soft, irq_m_timer, irq_m_ext, irq_s_ext} <=", "I2: the interrupt lines' registers never loaded"),
    # step 1.8 U2 (Plan/OOC.md 29.82): the renamed FPU in the core
    (C, "fexc[j]  = f_ok[j] && (fs == 2'b00 || ", "fexc[j]  = f_ok[j] && (1'b0 || ", 'U2: an FP instruction with FS off runs'),
    (C, "(rm == 3'd5 || rm == 3'd6 || (rm == 3'd7 && frm >= 3'd5))", "(rm == 3'd5 || rm == 3'd6)", 'U2: a dynamic rounding mode with frm reserved runs'),
    (C, "|| g_fp_op[s] == FOP_CVT_I_F);", ");", 'U2: fcvt to an integer taken for an FP result'),
    (C, "(g_fp_op[s] == FOP_MV_F_X || g_fp_op[s] == FOP_CVT_F_I);", "(g_fp_op[s] == FOP_MV_F_X);", 'U2: fcvt from an integer sent to OOO_FIQ'),
    (C, "(g_fp_op[s] == FOP_DIV || g_fp_op[s] == FOP_SQRT);", "(g_fp_op[s] == FOP_DIV);", 'U2: a square root not marked a divide'),
    (C, "d2[j].fuse           = fpst[j] ? 3'b001 : g_use_fs[s];", "d2[j].fuse           = g_use_fs[s];", "U2: an FP store's data waits for its fs2 in the wrong place"),
    (C, "fq_src[j]  = ds[j].fsd ? {f2_src[j][2], f2_src[j][0], f2_src[j][1]} : f2_src[j];", "fq_src[j]  = f2_src[j];", "U2: an FP store's data from its fs1"),
    (C, "fq_rdy[j]  = ds[j].fsd ? {frdy[j][2], frdy[j][0], frdy[j][1]} : frdy[j];", "fq_rdy[j]  = frdy[j];", "U2: an FP store's data ready as its fs1"),
    (C, "frdy[j]  = {fbsy_b[j][0], fbsy_a[j][1], fbsy_a[j][0]};", "frdy[j]  = {fbsy_a[j][1], fbsy_a[j][1], fbsy_a[j][0]};", "U2: an FMA's fs3 ready as its fs2"),
    (C, "u_fbusy_a\n        (.clk(clk), .rst_n(rst_n), .set_v(f1_wr)", "u_fbusy_a\n        (.clk(clk), .rst_n(rst_n), .set_v(4'd0)", 'U2: the FP busy bits never set'),
    (C, ".r_ren_ready(ren_ready && fren_ready)", ".r_ren_ready(ren_ready)", "U2: renaming goes without FP registers"),
    (C, "assign iq_ready   = (q_ready >= n_iq && fq_ready >= n_fq) ? 3'd4 : 3'd0;", "assign iq_ready   = (q_ready >= n_iq) ? 3'd4 : 3'd0;", "U2: dispatch without room in OOO_FIQ"),
    (C, "fwk_v[1 + m] = m_rr_v[m] && rr_rec[NAP+m].fpd", "fwk_v[1 + m] = 1'b0 && rr_rec[NAP+m].fpd", "U2: an FP load wakes nothing"),
    (C, "ld_db[m] = ld_nt[m][TAGW+1] ? {32'hFFFF_FFFF, ld_d[m][31:0]} : ld_d[m];", "ld_db[m] = ld_d[m];", "U2: flw not NaN boxed"),
    (C, "prf_we[NAP + m] = ld_nv[m] && !ld_fp[m];", "prf_we[NAP + m] = ld_nv[m];", "U2: an FP load written into the integer file too"),
    (C, "lw_v[m] <= ld_nv[m] && !ld_fp[m] && ld_nt", "lw_v[m] <= ld_nv[m] && ld_nt", "U2: an FP load forwarded to integer readers"),
    (C, "assign b2_dat   = (fw_valid && fw_tag == b2_src) ? fw_data : fp_rd[3];", "assign b2_dat   = fp_rd[3];", "U2: an FP store's data without the FP result's bypass"),
    (C, "sd2_size <= {1'b1, b2_pl[28]};", "sd2_size <= 2'd3;", "U2: fsw stored as a double"),
    (C, "assign iw_ack = iw_valid && !x_wv && !md_we;", "assign iw_ack = iw_valid && !x_wv;", "U2: an FP -> integer result over the MDU's"),
    (C, "assign iw_ack = iw_valid && !x_wv && !md_we;", "assign iw_ack = iw_valid && !md_we;", "U2: an FP -> integer result over a latency-1 writer's"),
    (C, ".ext_valid({at_wk_v, md_ext_v || f2i_wr})", ".ext_valid({at_wk_v, md_ext_v})", "U2: an FP -> integer result wakes nothing"),
    (C, ".p0_hold(p0_hold || f2i_hold)", ".p0_hold(p0_hold)", "U2: an FP -> integer result does not hold port 0's writers"),
    (C, "assign xf_ok = x_ready && !(g_alu[0].rr_v && rr_rec[0].fx) && !(ex_v[0] && ex[0].rec.fx);", "assign xf_ok = x_ready;", "U2: int -> FP µops back to back into one buffer"),
    (C, "!ex[p].sd && !ex[p].rec.fx;", "!ex[p].sd;", "U2: an int -> FP µop completed in port 0's EX"),
    (C, "f_fl_set = f_fl_set | fr_fl[ik];", "f_fl_set = fr_fl[ik];", "U2: fflags from the last µop committed alone"),
    (C, "if (cmt_fx[k][FXW-1] || fr_fl[ik] != 5'd0) f_dirty = 1'b1;", "if (cmt_fx[k][FXW-1]) f_dirty = 1'b1;", "U2: new flags alone leave FS clean"),
    (C, "if (iw_ack)   fr_fl[iw_rob] <= iw_flags;", "", "U2: an FP -> integer µop's flags lost"),
    (C, "x_pl[11 +: ROBW] = ex[0].rec.rob;", "", "U2: an int -> FP µop completes entry 0"),
    (C, "fcmt_wr[k]   = cmt_valid[k] && cmt_fx[k][FXW-1];", "fcmt_wr[k]   = 1'b0;", "U2: the committed FP map never written"),
    (C, "|| (at && g_mem_cmd[s] != 5'd2) || fpst[j];", "|| (at && g_mem_cmd[s] != 5'd2);", "U2: an FP store without an SQ entry"),
    (C, "fi2f[j] ? {21'd0, g_fp_int_w[s], g_fp_int_signed[s], g_fp_rm[s], g_fp_fmt[s], g_fp_op[s]} : g_imm[s];", "g_imm[s];", "U2: an int -> FP µop's operation not passed"),
    (IQ, "sdq <= b_nd[B];", "sdq <= 1'b0;", "U2: an FP store's data waited for on port 1"),
    (IQ, "&& !(xf[i] && !xf_ok);", ";", "U2: the queue ignores xf_ok"),
    (L4, "assign sd2_rep = sd2_size == 2'd2 ? {2{sd2_data[31:0]}} : sd2_data;", "assign sd2_rep = sd2_data;", "U2: fsw's data not replicated"),
    (L4, "if (sd2_v) sd_lv[sd2_sq] <= 1'b1;", "", "U2: an FP store's data read from the integer RAM"),
    (L4, "|| (sd2_v && sd2_sq == SW'(i))) sdv[i] <= 1'b1;", ") sdv[i] <= 1'b1;", "U2: an FP store's data never valid"),
    (DE, "assign rs3[k]          = xi[31:27];", "assign rs3[k]          = xi[24:20];", "U2: an FMA's rs3 its rs2"),
    (C, "assign iq_ready   = (q_ready >= n_iq && fq_ready >= n_fq) ? 3'd4 : 3'd0;", "assign iq_ready   = (fq_ready >= n_fq) ? 3'd4 : 3'd0;", "U2b: dispatch without room in OOO_IQ3"),
    (DE, "assign fp_we_rd[k]     = l_fp_we_rd;", "assign fp_we_rd[k]     = S0 && l_fp_we_rd;", "U2b: an FP destination in slot 0 only"),
    (C, "f2_dst[j], f2_old[j]};", "f2_old[j], f2_dst[j]};", "U3b: the FP destination's new and old swapped in OOO_ROB"),
    (C, "fcmt_arch[k] = cmt_fx[k][2*FTAGW +: 5];", "fcmt_arch[k] = cmt_fx[k][FTAGW +: 5];", "U3b: the FP map's architectural register read off"),
    # Sv39's data side (step 1.8 V1, Plan/OOC.md 29.87): b4/dir/vm.S, rv64si-p-dirty
    (C, "assign tr_eff = (m_mprv && priv == 2'd3) ? m_mpp : priv;", "assign tr_eff = priv;", "V1: MPRV ignored"),
    (C, "tr_au  <= tr_eff == 2'd0 || (tr_eff == 2'd1 && m_sum);", "tr_au  <= tr_eff == 2'd0;", "V1: SUM ignored"),
    (C, "tr_as  <= tr_eff == 2'd1;", "tr_as  <= 1'b1;", "V1: S pages from U"),
    (C, "tr_mxr <= m_mxr;", "tr_mxr <= 1'b0;", "V1: MXR ignored"),
    (C, "tr_on  <= satp[63:60] == 4'd8 && tr_eff != 2'd3;", "tr_on  <= satp[63:60] == 4'd8;", "V1: M mode translated"),
    (C, "assign tlb_flush_all = tlb_flush || satp_q != satp;", "assign tlb_flush_all = tlb_flush;", "V1: a change of satp leaves the DTLBs"),
    (C, "ld_ccause[m] <= cmp_ld_cause[m] == 2'd2 ? 5'd13 :", "ld_ccause[m] <= cmp_ld_cause[m] == 2'd2 ? 5'd5 :", "V1: a load's page fault reported as an access fault"),
    (C, "cmp_st_cause == 2'd2 ? 5'd15 :", "cmp_st_cause == 2'd2 ? 5'd13 :", "V1: a store's page fault reported as a load's"),
    (C, ".satp_ppn(satp[43:0])", ".satp_ppn({satp[42:0], 1'b0})", "V1: the walk's root a page off"),
    (DM, "pt_data   = st == S_PANS ? vr_data : p_q;", "pt_data   = p_q;", "V1: an entry found in the D$ answered from the last fill", CPU),
    # Sv39's fetch side (step 1.8 V2, Plan/OOC.md 29.88): b4/dir/vmx.S, riscv-tests' -v-, riscv-arch-test's Sv groups
    (C, "rt_q ? {{(64 - PAW){rt_bq[PAW-1]}}, rt_bq} : m_ea[0]", "rt_q ? 64'(rt_bq) : m_ea[0]", "V2: a try's address not sign extended (S mode's high addresses)"),
    (FR, "assign ic_req_valid = f_req_v && it_hit && !pw_chk;", "assign ic_req_valid = f_req_v && !pw_chk;", "V2: a fetch without its translation"),
    (FR, ".ic_req_ready(ic_req_ready && it_hit && !pw_chk)", ".ic_req_ready(ic_req_ready && !pw_chk)", "V2: fetch takes a request the I$ did not"),
    (FR, "!it_xok ? {it_afo ? 2'd2 : 2'd1, 8'd0}", "!it_xok ? {2'd1, 8'd0}", "V2: a fetch's access fault said to be a page fault"),
    (FR, "bf[push_idx] <= {bf_w7, fq_f[fq_h]};", "bf[push_idx] <= '0;", "V2: a block's fetch fault lost"),
    (FR, "bfk = g_bsel[k] ? g_bf1 : g_bf0;", "bfk = g_bf0;", "V2: the fault of the group's first block for all"),
    (C, "ipc                  = g_pc[s] + (VA - 1)'(g_ifx[s]);", "ipc                  = g_pc[s];", "V2: an instruction across into a faulting page: tval its pc"),
    (C, "d2[j].cause          = ifl ? (g_ifault[s] == 2'd1 ? 5'd12 : 5'd1) :", "d2[j].cause          = ifl ? 5'd12 :", "V2: a fetch's access fault reported as a page fault"),
    (C, "assign it_on = satp[63:60] == 4'd8 && priv != 2'd3;", "assign it_on = satp[63:60] == 4'd8 && tr_eff != 2'd3;", "V2: fetch translated with MPRV's privilege"),
    (C, "assign it_au = priv == 2'd0;", "assign it_au = 1'b1;", "V2: S runs user pages"),
    (C, ".req_id(w_req ? {1'b0, w_rid} : 6'b100000)", ".req_id(w_req ? {1'b0, w_rid} : 6'b000000)", "V2: the fetch's walk taken for the LSU's"),
    # PMP (step 1.8 P1, Plan/OOC.md 29.89): the PMP group of riscv-arch-test, b4/dir/pmpx.S
    (FR, ": {2'd0, pmpw};", ": {2'd0, 8'd0};", "P1: the fetch's PMP denials lost"),
    (FR, "bf_w7        <= fq_f[fq_h][7];", "bf_w7        <= 1'b0;", "P1: the word 7 denial of the block before lost"),
    (FR, "d1  = g_x[k] ? bfk[10] : pdk[g_off[k][3:1]];", "d1  = g_x[k] ? 1'b0 : pdk[g_off[k][3:1]];", "P1: across two blocks, the first half's denial ignored"),
    (FR, "d2  = g_x[k] ? bfk[0]  : !g_rvc_q[k] && pdk[w2];", "d2  = g_x[k] ? bfk[0]  : 1'b0;", "P1: in one block, the second half's denial ignored"),
    (FR, "g_ifx[k]    = !d1;", "g_ifx[k]    = 1'b1;", "P1: across two blocks, a first half denied: tval pc + 2"),
    (FR, ".priv(pw_chk ? 2'd1 : it_priv)", ".priv(it_priv)", "P1: the walker's entries checked with the fetch's privilege"),
    (FR, "assign ic_req_valid = f_req_v && it_hit && !pw_chk;", "assign ic_req_valid = f_req_v && it_hit;", "P1: a fetch in the walker's check's cycle"),
    (C, "tr_ep  <= tr_eff;", "tr_ep  <= priv;", "P1: PMP without MPRV"),
    # the store search's offset and bytes compared at E (step 1.8 V3b, Plan/OOC.md 29.91): b4/dir/atomic.S part 7
    (L4, "if (sc_dec && sc_fail && sc_sq == SW'(i)) e_om[i] = 1'b0;", "if (1'b0) e_om[i] = 1'b0;", "V3b: an SC failing in the load's E still has its bytes for the search"),
    (L4, "e_om[i] = (sw0_v && sw0_sq == SW'(i)) ? swm : swa[i] == e_a[11:3] && (smask[i] & lm) != 8'd0;", "e_om[i] = swa[i] == e_a[11:3] && (smask[i] & lm) != 8'd0;", "V3b: a store writing its entry in the load's E not seen by the search"),
    # the bypass's compare at RR (step 1.8 V3c, Plan/OOC.md 29.93)
    (C, "for (int q = 0; q < NAP; q++) byp_nt[q] = wbi_t[q];", "for (int q = 0; q < NAP; q++) byp_nt[q] = ex[q].dst;", "V3c: the bypass's compare with EX's tag, not the MDU's, the multiplier's or the FP -> integer result's"),
    (C, "ex_m2[q] <= byp_nt[q] == rr_t2;", "ex_m2[q] <= byp_nt[q] == rr_t1;", "V3c: the second operand's compare with the first's tag"),
    # the kill registered from EX's end, the fetch's fault queue written at F1 (step 1.8 V3d, Plan/OOC.md 29.95)
    (C, "k_ckpt <= (k_m[0] && (!k_m[1] || k_d[0] <= k_d[1])) ? e_br_ckpt[0] : e_br_ckpt[1];", "k_ckpt <= e_br_ckpt[1];", "V3d: the kill's checkpoint always port 1's (port 0 resolves every branch since step 1.2 D)"),
    (C, "else        k_v <= k_m != 2'b00;", "else        k_v <= k_m[1];", "V3d: port 0's misprediction kills nothing"),
    (C, "k_m[p] = e_br_valid[p] && e_br_mispred[p] && !flush_all && (ex_bms[p] & kill) == '0;", "k_m[p] = e_br_valid[p] && e_br_mispred[p] && !flush_all;", "V3d: a misprediction killed in EX still restores"),
    (FR, "fq_wi <= fq_h + fq_n[1:0];", "fq_wi <= fq_h;", "V3d: a fetch fault written at the queue's head"),
    (FR, "if (fq_wv) fq_f[fq_wi] <= fq_wd;", "if (fq_wv) fq_f[fq_h + fq_n[1:0]] <= fq_wd;", "V3d: the fault queue's slot taken in the write's cycle, not the request's"),
    # the PMU's events (step 1.8 K1, Plan/OOC.md 29.98): tb_core's account every cycle and at the end, b4/dir/pmu.S
    (C, "hpm_ev[1]  <= 4'd1;", "hpm_ev[1]  <= 4'd2;", 'K1: cycles counted 2 a cycle'),
    (C, 'hpm_ev[2]  <= cmt_instret;', "hpm_ev[2]  <= 4'(cmt_ld_n);", "K1: instructions retired: the loads'"),
    (C, "hpm_ev[3]  <= 4'(cmt_ld_n);", "hpm_ev[3]  <= 4'(cmt_st_n);", "K1: loads retired: the stores'"),
    (C, "hpm_ev[4]  <= 4'(cmt_st_n);", "hpm_ev[4]  <= 4'(cmt_st_n != 3'd0);", 'K1: stores retired counted 1 a cycle'),
    (C, "hpm_ev[5]  <= 4'(rs_valid[0]);", "hpm_ev[5]  <= 4'(rs_valid[1]);", "K1: branches resolved: port 1's"),
    (C, "hpm_ev[6]  <= 4'(restore);", "hpm_ev[6]  <= 4'(fe_redirect);", 'K1: mispredictions with the traps and replays'),
    (C, "hpm_ev[7]  <= 4'(ev_mem[0]);", "hpm_ev[7]  <= 4'(ev_mem[1]);", "K1: I$ fills: the D$'s"),
    (C, "hpm_ev[8]  <= 4'(ev_mem[1]);", "hpm_ev[8]  <= 4'(ev_mem[0]);", "K1: D$ fills: the I$'s"),
    (C, "hpm_ev[9]  <= 4'(w_start && !w_req);", "hpm_ev[9]  <= 4'(w_start);", "K1: the fetch's walks with the LSU's"),
    (C, "hpm_ev[10] <= 4'(w_start && w_req);", "hpm_ev[10] <= 4'(w_req);", "K1: the LSU's walks: every ask, the dropped ones too"),
    (C, "hpm_ev[11] <= 4'(head_valid && cmt_valid == '0 && head_mem);", "hpm_ev[11] <= 4'(head_valid && head_mem);", "K1: the head's wait on memory counted when it commits"),
    (RB, 'head_mem   = has[0] && (pk[0][FTQW+6] || pk[0][FTQW+5]);', 'head_mem   = has[0] && pk[0][FTQW+6];', 'K1: a store at the head not a memory µop'),
    (C, "hpm_ev[12] <= ev_recn ? 4'd0 : 4'(3'(ND) - ev_offer);", "hpm_ev[12] <= ev_recn ? 4'd0 : 4'(3'(ND) - ev_used);", "K1: the front end's slots with the back end's"),
    (C, "hpm_ev[13] <= 4'(replay);", "hpm_ev[13] <= 4'(fe_flush);", 'K1: replays with the traps'),
    (C, "hpm_ev[14] <= 4'(head_valid && cmt_valid == '0 && !head_mem);", "hpm_ev[14] <= 4'(cmt_valid == '0 && !head_mem);", "K1: the head's other wait counted with the ROB empty"),
    (C, "hpm_ev[15] <= 4'(csr_trap && !csr_int);", "hpm_ev[15] <= 4'(csr_trap);", 'K1: exceptions with the interrupts'),
    (C, "hpm_ev[16] <= 4'(csr_trap && csr_int);", "hpm_ev[16] <= 4'(irq_pend);", 'K1: interrupts: the cycles one is pending'),
    (C, "hpm_ev[17] <= ev_recn ? 4'd0 : 4'(ev_offer - ev_used);", "hpm_ev[17] <= ev_recn ? 4'd0 : 4'(ev_offer);", "K1: the back end's slots with the used ones"),
    (C, "hpm_ev[18] <= 4'(ev_mem[2]);", "hpm_ev[18] <= 4'(ev_mem[3]);", 'K1: L2 reads: its misses', 'CPU'),
    (CP, 'assign ev_mem = {l2_ev_miss, l2_ev_read, d_arvalid && d_arready, i_arvalid && i_arready};', 'assign ev_mem = {l2_ev_miss, l2_ev_read, d_arvalid, i_arvalid && i_arready};', 'K1: a D$ read counted each cycle it waits'),
    (C, "hpm_ev[20] <= 4'(ev_used);", "hpm_ev[20] <= 4'(ev_offer);", 'K1: the slots used: the µops offered'),
    (C, "ev_rec <= fe_flush || restore_k || (ev_rec && r_go == '0);", 'ev_rec <= fe_flush || restore_k;', 'K1: recovery not held until renaming starts again'),
    (C, 'ev_recn  = ev_rec || flush_all || restore_k;', 'ev_recn  = ev_rec;', "K1: the restore's and flush's own cycles not recovery"),
    (C, "hpm_ev[22] <= 4'(pop4(cmt_valid));", "hpm_ev[22] <= 4'(cmt_valid[0]);", 'K1: µops retired counted 1 a cycle'),
    (C, "hpm_ev[23] <= 4'(ev_dwait[0]);", "hpm_ev[23] <= 4'(ev_dwait[1]);", "K1: dispatch's wait for the ROB: the queue's"),
    (C, "hpm_ev[26] <= 4'(ev_rreg);", "hpm_ev[26] <= 4'(ev_rckpt);", "K1: renaming's wait for registers: for a checkpoint"),
    (C, 'if (w_start) w_own_f <= !w_req;', 'if (w_start) w_own_f <= w_req;', "K1: the walker's busy cycles given to the other side"),
    (C, "hpm_ev[30] <= 4'(!head_valid);", "hpm_ev[30] <= 4'(cmt_valid == '0);", 'K1: the ROB empty: no commit'),
]

# B5a's (Plan/CORE.md 5.19): ALU + branch fusion is off since 5.21 (OOO_FUSE's KINDS 0, Plan/OOC.md 27.5),
# and step 1.2 C took the pairing out of D2 (4 µops a group, Plan/OOC.md 29.19). Kept as a record: they
# apply to the core before C (dcf5580) with its FUSE_KINDS 8'h80 (B5A=1), not to this one
MUT_B5A = [
    (C, "FUSE_KINDS = 8'h80;", "FUSE_KINDS = 8'h90;", 'B5a: ALU + load paired too (not executed as a pair)'),
    (C, "r_ckpt[j]  = pr[j] || ", "r_ckpt[j]  = ", 'B5a: a pair without a checkpoint'),
    (C, "d2[j].rec.pred_taken = g_taken[b];", "d2[j].rec.pred_taken = g_taken[s];", 'B5a: a pair\'s prediction its ALU half\'s'),
    (C, "d2[j].rec.e          = g_end[b];", "d2[j].rec.e          = g_end[s];", 'B5a: a pair\'s last parcel its ALU half\'s'),
    (C, "pc_nx = (FUSE_AB && ex[p].rec.fused) ? pc_b + (ex[p].rec.len4b ? (VA - 1)'(2) : (VA - 1)'(1)) : pc_b;", "pc_nx = pc_b;", 'B5a: a pair\'s next pc after its ALU half'),
    (C, "b_tgt = (FUSE_AB && ex[p].rec.fused) ? pc_b + ", "b_tgt = (FUSE_AB && ex[p].rec.fused) ? pc + ", 'B5a: a pair\'s target from its ALU half\'s pc'),
    (C, "|| g_ftq[s] != g_ftq[b];", ";", 'B5a: a pair across blocks reads its branch\'s line'),
    (C, "(g_use_rs1[rs[k]] && g_use_rs2[rs[k]] && g_rs1[rs[k]] == g_rs2[rs[k]])) ? 3'd7", "1'b0) ? 3'd7", 'B5a: an operation reading one register twice paired'),
    (C, "(pr[j] && g_a_sel[s] == 2'd0 && !a_s1[j]) ? 2'd2 : g_a_sel[s];", "g_a_sel[s];", 'B5a: an x0 read on s1 kept (the branch\'s operand goes there)'),
    (C, "else if (!a_s2[j])                     b_os[j] = 2'd1;", "else if (1'b0)                     b_os[j] = 2'd1;", 'B5a: the branch\'s operand on s1 when s2 is free'),
    (C, ".br_fused(FUSE_AB && ex[p].rec.fused)", ".br_fused(1'b0)", 'B5a: a pair\'s branch compares s1 with s2'),
    (C, ".br_res1_a(ex[p].rec.b_res1a)", ".br_res1_a(1'b0)", 'B5a: the result always the second operand'),
]
if os.environ.get('B5A'):
    MUT += MUT_B5A


def run(i, m):
    f, old, new, desc = m[:4]
    src = open(os.path.join(OOO, f)).read()
    if src.count(old) != 1:
        return i, 'NOT APPLIED', desc
    d = os.path.join(HERE, 'obj/cmut%d' % i)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(OOO, os.path.join(d, 'OOO'))
    shutil.copytree(MMIO, os.path.join(d, 'MMIO'))
    open(os.path.join(d, 'OOO', f), 'w').write(src.replace(old, new))
    cpu = f in (DM, CP, IC, PL) or len(m) > 4   # OOO_DMISS2, OOO_CPU's wiring and OOO_ICACHE run in OOO_CPU only,
                                        # with an L2 of 4 KB (step 1.7 H3, Plan/OOC.md 29.58): most accesses
                                        # miss it, so memory's stalls reach the D$ and its dirty lines go to memory
    env = dict(os.environ, OOO_RTL=os.path.join(d, 'OOO'), MMIO_RTL=os.path.join(d, 'MMIO'), OBJ=os.path.join(d, 'obj'), L2KB='4' if cpu else '256')
    if subprocess.run([os.path.join(HERE, 'build_core.sh')] + (['cpu'] if cpu else []), env=env, capture_output=True).returncode:
        return i, 'BUILD FAILED', desc
    t = os.path.join(d, 'obj', 'VOOO_CPU' if cpu else 'VOOO_CORE')
    try:
        r = subprocess.run([t, '+verilator+rand+reset+2', '-exit', 'pass'] +
                           ([] if cpu else ['-restores-ref', os.path.join(HERE, 'results/core_restores.txt'), '-restores-max', RMAX]) + PROGS,
                           capture_output=True, timeout=900)
        det = r.returncode != 0
        if not det:
            det = subprocess.run([t, '+verilator+rand+reset+2'] + HPROGS, capture_output=True, timeout=900).returncode != 0
        if not det:
            det = subprocess.run([t, '+verilator+rand+reset+2', '-max', '3000000'] + APROGS + RPROGS,
                                 capture_output=True, timeout=1800).returncode != 0
        if not det and cpu:
            det = subprocess.run([t, '+verilator+rand+reset+2', '-max', '3000000', '-exit0'] + IPROGS,
                                 capture_output=True, timeout=1800).returncode != 0
        if not det:
            det = subprocess.run([t, '+verilator+rand+reset+2', '-max', '100000000', '-miss', '0'] + ([] if cpu else ['-dhit', '100']) +
                                 ['-replays-max', '2000'] + CM,
                                 capture_output=True, timeout=3600).returncode != 0
    except subprocess.TimeoutExpired:
        return i, 'NOT DETECTED', desc + ' (the run did not end)'
    shutil.rmtree(d, ignore_errors=True)
    return i, 'DETECTED' if det else 'NOT DETECTED', desc


if __name__ == '__main__':
    os.makedirs(os.path.join(HERE, 'results'), exist_ok=True)
    sel = [int(x) for x in sys.argv[1:]]
    with ThreadPoolExecutor(max_workers=4) as ex:
        res = sorted(ex.map(lambda a: run(*a), [(i, m) for i, m in enumerate(MUT) if not sel or i in sel]))
    lines = ['%2d %-13s %s' % r for r in res]
    det = sum(1 for r in res if r[1] == 'DETECTED')
    lines.append('%d mutations, %d detected' % (len(res), det))
    out = '\n'.join(lines) + '\n'
    if not sel:
        open(os.path.join(HERE, 'results/mutate_core.txt'), 'w').write(out)
    print(out, end='')
    sys.exit(0 if det == len(res) else 1)
