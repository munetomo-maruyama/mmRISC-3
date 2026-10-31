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
# jumps, 6 with loads and stores; b3/work: 10 riscv-tests and the console,
# to their HTIF exit) on OOO_CORE with the D$ model, with
# a budget of restores (-restores-max: a fault in what only steers the
# predictors costs mispredictions, not values); then on B4's (b4/work:
# riscv-arch-test, 185; riscv-tests' -p- programs as run_core.sh runs
# them), last on CoreMark (g14 sf + -flto; at most 2,000 replays: about
# 250 now, 21,000 with loads issued past older stores). DETECTED when a run
# fails.
# Every line of the result is to be read: grep NOT.
#
# Left out, as found by the first campaign:
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
#---------------------------------------------------------------------------
import glob, os, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
OOO = os.path.normpath(os.path.join(HERE, '../../RTL/CPU/OOO'))
W = os.path.join(HERE, 'b2/work')
PROGS = ([os.path.join(W, 'alu-%d.elf' % i) for i in range(1, 5)] + [os.path.join(W, 'br-%d.elf' % i) for i in range(1, 11)] +
         [os.path.join(W, 'ls-%d.elf' % i) for i in range(1, 7)])
B3 = os.path.join(HERE, 'b3/work')
HPROGS = [os.path.join(B3, t + '.elf') for t in ('rv64ui-ld_st', 'rv64ui-st_ld', 'rv64ui-lb', 'rv64ui-lhu', 'rv64ui-lwu', 'rv64ui-sb',
                                                 'rv64ui-sh', 'rv64ui-sd', 'rv64ui-jalr', 'rv64uc-rvc', 'htif')]
RMAX = '1.30'      # restores at most 1.3 times the clean run's, program by program (results/core_restores.txt)
APROGS = sorted(glob.glob(os.path.join(HERE, 'b4/work/*/*.elf')))
CM = [os.path.join(HERE, '../../Plan/trace/work/g14-sflto-zbsc.elf')]     # CoreMark, the last stage
RV = os.environ.get('RVTESTS', os.path.join(HERE, '../../../mmRISC-2/SIM/SIM_CORE/rvtests'))
RPROGS = sorted(os.path.join(RV, t) for t in os.listdir(RV)
                if __import__('re').fullmatch(r'rv64(ui|um|uc|uzba|uzbb|uzbc|uzbs|uzicond|mi|si)-p-[a-z0-9_]+', t) and
                t not in ('rv64mi-p-breakpoint', 'rv64mi-p-csr', 'rv64si-p-dirty'))
CS = 'OOO_CSRU/OOO_CSRU.sv'

C = 'OOO_CORE/OOO_CORE.sv'
MUT = [
    # D2
    (C, "hd = g_valid[0] ? 2'd0 : g_valid[1] ? 2'd1 : g_valid[2] ? 2'd2 : 2'd3;", "hd = 2'd0;", 'D2: the group not rotated'),
    (C, "assign us[1]   = hd + u1_slot;", "assign us[1]   = hd + u0_slot;", 'D2: µop 1 from µop 0\'s slot'),
    (C, "assign g_take = r_go[1] ? consumed : r_go[0] ? ((u0_kind != 4'd0) ? 3'd2 : 3'd1) : 3'd0;",
     "assign g_take = r_go[0] ? consumed : 3'd0;", 'D2: both taken when only µop 0 goes'),
    (C, "r_ckpt[j]  = g_is_branch[us[j]] || g_is_jalr[us[j]];", "r_ckpt[j]  = g_is_branch[us[j]];", 'D2: a jalr without a checkpoint'),
    (C, "d2[j].rec.ckpt       = ren_ckpt_id[j];", "d2[j].rec.ckpt       = ren_ckpt_id[0];", 'D2: µop 1 with µop 0\'s checkpoint id'),
    (C, "d2[j].rec.imm        = jmp ? (g_rvc[s] ? 32'd2 : 32'd4) : g_imm[s];", "d2[j].rec.imm        = jmp ? 32'd4 : g_imm[s];", 'link: pc + 4 for RVC too'),
    (C, "d2[j].rec.a_sel      = jmp ? 2'd1 : g_a_sel[s];", "d2[j].rec.a_sel      = g_a_sel[s];", 'link: a jalr\'s from rs1'),
    (C, "d2[j].rec.xline      = !g_rvc[s] && g_pc[s][3:1] == 3'd7;", "d2[j].rec.xline      = 1'b0;", 'pc: an instruction across two lines from its second'),
    (C, "d2[j].rec.pred_taken = g_taken[s];", "d2[j].rec.pred_taken = 1'b0;", 'every transfer predicted not taken'),
    (C, "d2[j].rec.ret        = g_is_jalr[s] && link_rs1 && !link_rd;", "d2[j].rec.ret        = g_is_jalr[s] && link_rs1;", 'a call through x1 / x5 counted as a return'),
    (C, "d2[j].rec.call       = g_is_jalr[s] && link_rd;", "d2[j].rec.call       = 1'b0;", 'jalr calls not calls (the RAS on a restore)'),
    # DS, ROB, IQ
    (C, "wrec[j].rob = disp_rob[j];", "wrec[j].rob = disp_rob[0];", 'the record: µop 1 with µop 0\'s ROB entry'),
    (C, ".disp_new({ds[1].dst, ds[0].dst}), .disp_old({ds[1].old, ds[0].old})", ".disp_new({ds[1].dst, ds[0].dst}), .disp_old({ds[1].dst, ds[0].dst})",
     'ROB: the new mapping as the old'),
    (C, ".ds_ftq({ds[1].rec.ftq, ds[0].rec.ftq})", ".ds_ftq({ds[0].rec.ftq, ds[1].rec.ftq})", 'CTRL: the checkpoints\' blocks swapped'),
    (C, ".disp_ftq({ds[1].rec.ftq, ds[0].rec.ftq})", ".disp_ftq({ds[1].rec.ftq, ds[1].rec.ftq})", 'ROB: µop 0 with µop 1\'s block (FTQ pops)'),
    (C, ".disp_wr({ds[1].wr && !ds[1].md, ds[0].wr && !ds[0].md}), .disp_dst", ".disp_wr(2'b11), .disp_dst", 'IQ: every µop wakes for its destination'),
    # the ALU ports
    (C, "if (byp_v[q] && byp_t[q] == ex[p].t1) a = byp_d[q];", '', 'bypass: none for the first source'),
    (C, "if (byp_v[q] && byp_t[q] == ex[p].t2) b = byp_d[q];", '', 'bypass: none for the second source'),
    (C, "byp_v[q] = wb_v[q];", "byp_v[q] = (q == 0) && wb_v[q];", 'bypass: port 1\'s result not forwarded'),
    (C, "wbi_v[1] = pm_w || (ex_v[1] && ex[1].wr);", "wbi_v[1] = pm_w || ex_v[1];", 'WB: a µop of port 1 without a destination forwards'),
    (C, "assign x_wv  = ex_v[0] && ex[0].wr && ex[0].rec.kind != K_MDU;", "assign x_wv  = ex_v[0] && ex[0].rec.kind != K_MDU;",
     'WB: a µop of port 0 without a destination forwards'),
    (C, "assign pa_idx[p]     = rr_rec[p].ftq - FTQW'(rr_rec[p].xline);", "assign pa_idx[p]     = rr_rec[p].ftq;", 'pc: the line of the last half\'s block'),
    (C, "assign ta_idx[p]     = rr_rec[p].ftq;", "assign ta_idx[p]     = rr_rec[p].ftq + FTQW'(1);", 'jalr: the next block\'s predicted target'),
    (C, "rx.v2   = prf_rd[2*p+1];", "rx.v2   = prf_rd[2*p];", 'RR: the second source from the first read'),
    # port 2 and the LSU (B3)
    (C, "d2[j].rec.is_ld      = g_cls[s] == 3'd4;", "d2[j].rec.is_ld      = 1'b1;", 'every µop of port 2 a load'),
    (C, "d2[j].rec.uns        = !g_mem_signed[s];", "d2[j].rec.uns        = g_mem_signed[s];", 'loads sign- and zero-extended the other way'),
    (C, "wrec[j].lq  = disp_lq[j];", "wrec[j].lq  = disp_lq[0];", 'the record: µop 1 with µop 0\'s LQ entry'),
    (C, "wrec[j].sq  = disp_sq[j];", "wrec[j].sq  = disp_sq[0];", 'the record: µop 1 with µop 0\'s SQ entry'),
    (C, ".ds_ld({ds[1].ld, ds[0].ld}), .ds_st", ".ds_ld(2'b00), .ds_st", 'CTRL: loads not counted against the LQ'),
    (C, ".disp_ld({ds[1].ld, ds[0].ld}), .disp_st({ds[1].st, ds[0].st}),\n         .disp_fused", ".disp_ld(2'b00), .disp_st({ds[1].st, ds[0].st}),\n         .disp_fused",
     'ROB: loads not marked (the LQ never freed)'),
    (C, ".disp_st({ds[1].st, ds[0].st}), .disp_rob(disp_rob)", ".disp_st(2'b00), .disp_rob(disp_rob)", 'LSU: stores not given SQ entries'),
    (C, ".iss_ld(p2.rec.is_ld)", ".iss_ld(1'b1)", 'LSU: stores issued as loads'),
    (C, ".iss_lq(p2.rec.lq), .iss_sq(p2.rec.sq)", ".iss_lq(p2.rec.sq), .iss_sq(p2.rec.sq)", 'LSU: a load\'s LQ entry from the SQ field'),
    (C, ".iss_imm(p2.rec.imm[11:0])", ".iss_imm(12'd0)", 'LSU: the offset left out'),
    (C, ".iss_size(p2.rec.msize)", ".iss_size(2'd3)", 'LSU: every access a double word'),
    (C, ".iss_uns(p2.rec.uns)", ".iss_uns(1'b0)", 'LSU: lbu / lhu / lwu sign-extended'),
    (C, "if (byp_v[q] && byp_t[q] == p2.t1) p2_a = byp_d[q];", "", 'port 2: no bypass for the base'),
    (C, "if (byp_v[q] && byp_t[q] == p2.t2) p2_b = byp_d[q];", "", 'port 2: no bypass for a store\'s data'),
    (C, "byp_v[2] = lsu_wb_v && lsu_wb_t != '0;", "byp_v[2] = 1'b0;", 'bypass: the LSU\'s result not forwarded'),
    (C, "byp_v[2] = lsu_wb_v && lsu_wb_t != '0;", "byp_v[2] = lsu_wb_v;", 'bypass: a load to x0 forwarded (tag 0)'),
    (C, ".rf_valid(prf_we[2]), .rf_tag(prf_wa[2])", ".rf_valid(), .rf_tag(prf_wa[2])", 'register file: loads not written'),
    (C, "1'b0, 1'b0, cmp_ld_rp, 1'b0,", "1'b0, 1'b0, 1'b0, 1'b0,", 'ROB: no replay after a load that raised ld_cancel'),
    (C, ".restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_sq_tail), .flush_all", ".restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_lq_tail), .flush_all",
     'LSU: the SQ restored to the LQ\'s tail'),
    (C, ".lq_commit(lq_commit), .sq_commit(sq_commit), .restore(restore)", ".lq_commit(lq_commit), .sq_commit(2'b00), .restore(restore)", 'LSU: stores never committed'),
    # resolution
    (C, "mis   = ex[p].rec.is_jalr ? nxt != pnx : ex_tk[p] != ex[p].rec.pred_taken;", "mis   = ex[p].rec.is_jalr ? 1'b0 : ex_tk[p] != ex[p].rec.pred_taken;", 'a jalr never mispredicted'),
    (C, "mis   = ex[p].rec.is_jalr ? nxt != pnx : ex_tk[p] != ex[p].rec.pred_taken;", "mis   = ex[p].rec.is_jalr ? nxt != pnx : ex_tk[p];", 'a branch mispredicted when taken'),
    (C, "pc_nx = pc + (ex[p].rec.len4 ? (VA - 1)'(2) : (VA - 1)'(1));", "pc_nx = pc + (VA - 1)'(2);", 'the next pc after an RVC instruction'),
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
    (C, "d2[j].exc            = g_illegal[s] || g_is_fp[s] || g_sys[s][4] || g_sys[s][3];",
     "d2[j].exc            = g_illegal[s] || g_is_fp[s] || g_sys[s][4];", 'ECALL not an exception'),
    (C, "d2[j].exc            = g_illegal[s] || g_is_fp[s] || g_sys[s][4] || g_sys[s][3];",
     "d2[j].exc            = g_illegal[s] || g_sys[s][4] || g_sys[s][3];", 'an FP instruction not illegal (no FPU)'),
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
    (C, ".slot_busy(x_wv || pm_v)", ".slot_busy(x_wv)", 'the MDU\'s result and the multiply\'s in one cycle (one completion port)'),
    (C, ".slot_busy(x_wv || pm_v)", ".slot_busy(pm_v)", 'the MDU\'s result over an ALU0 µop\'s'),
    (C, "wbi_v[1] = pm_w || (ex_v[1] && ex[1].wr);", "wbi_v[1] = ex_v[1] && ex[1].wr;", 'port 1: the multiply\'s result not written'),
    (C, "assign pm_w = pm_v && pm_t != '0;", "assign pm_w = pm_v;", 'port 1: a multiply to x0 takes the write slot'),
    (C, "assign md_w = md_v && md_t != '0;", "assign md_w = md_v;", 'port 0: a divide to x0 forwarded (tag 0)'),
    (C, ".disp_st({ds[1].st, ds[0].st}),\n         .ext_valid", ".disp_st(2'b00),\n         .ext_valid", 'IQ: loads not held for older stores (replays)'),
    (C, ".mret_en(csr_mret), .sret_en(csr_sret)", ".mret_en(csr_mret), .sret_en(1'b0)", 'SRET: the CSRs not restored'),
    # B4: completion and tval
    (C, "cmp_valid[p]  = ex_v[p] && ex[p].rec.kind != K_MDU && ex[p].rec.kind != K_SYS;",
     "cmp_valid[p]  = ex_v[p] && ex[p].rec.kind != K_MDU;", 'a system µop complete at EX'),
    (C, "x_csr && csr_exc}", "1'b0}", 'CSR: an illegal access completes'),
    (C, "x_csr && csr_rp}", "1'b0}", 'CSR: no replay after a write'),
    (C, "{sys_rob, pm_v ? pm_rob : md_rob,", "{sys_rob, md_rob,", 'the multiply completes the MDU\'s entry'),
    (C, "tv_valid[2] = p2_ex_v && mis;", "tv_valid[2] = 1'b0;", 'tval: a misaligned address not given'),
    (C, "tv_valid[3] = csr_tv_v || sys_tv_v;", "tv_valid[3] = sys_tv_v;", 'tval: an illegal CSR access\'s not given'),
    # B4: OOO_CSRU
    (CS, "else if (wr_en && ex_addr == 12'hB02)      ir_skip <= 1'b1;", "", 'minstret: a write counts its own commit'),
    (CS, "assign c_wr_en = (wr_en && ex_addr != 12'h320) || (ih_pend && instret_inc != 3'd0);", "assign c_wr_en = wr_en;",
     'mcountinhibit: written at EX (its own commit under the new bit)'),
    (CS, "tv_val   = {32'd0, ex_inst};", "tv_val   = 64'd0;", 'CSR: an illegal access\'s tval 0'),
    (CS, "(fs == 2'b00 && (ex_addr == 12'h001", "(1'b0 && (ex_addr == 12'h001", 'CSR: fcsr with mstatus.FS off not illegal'),
]


def run(i, m):
    f, old, new, desc = m
    src = open(os.path.join(OOO, f)).read()
    if src.count(old) != 1:
        return i, 'NOT APPLIED', desc
    d = os.path.join(HERE, 'obj/cmut%d' % i)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(OOO, os.path.join(d, 'OOO'))
    open(os.path.join(d, 'OOO', f), 'w').write(src.replace(old, new))
    env = dict(os.environ, OOO_RTL=os.path.join(d, 'OOO'), OBJ=os.path.join(d, 'obj'))
    if subprocess.run([os.path.join(HERE, 'build_core.sh')], env=env, capture_output=True).returncode:
        return i, 'BUILD FAILED', desc
    t = os.path.join(d, 'obj', 'VOOO_CORE')
    try:
        r = subprocess.run([t, '+verilator+rand+reset+2', '-exit', 'pass', '-restores-ref',
                            os.path.join(HERE, 'results/core_restores.txt'), '-restores-max', RMAX] + PROGS,
                           capture_output=True, timeout=900)
        det = r.returncode != 0
        if not det:
            det = subprocess.run([t, '+verilator+rand+reset+2'] + HPROGS, capture_output=True, timeout=900).returncode != 0
        if not det:
            det = subprocess.run([t, '+verilator+rand+reset+2', '-max', '3000000'] + APROGS + RPROGS,
                                 capture_output=True, timeout=1800).returncode != 0
        if not det:
            det = subprocess.run([t, '+verilator+rand+reset+2', '-max', '100000000', '-miss', '0', '-dhit', '100',
                                  '-replays-max', '2000'] + CM,
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
