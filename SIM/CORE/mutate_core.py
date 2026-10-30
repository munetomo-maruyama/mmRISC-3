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
# and run on B2's programs (b2/work: 4 ALU, 10 with branches and jumps) with
# a budget of restores (-restores-max: a fault in what only steers the
# predictors costs mispredictions, not values). DETECTED when a run fails.
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
#     bit off, and that is the case above.
#---------------------------------------------------------------------------
import glob, os, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
OOO = os.path.normpath(os.path.join(HERE, '../../RTL/CPU/OOO'))
W = os.path.join(HERE, 'b2/work')
PROGS = [os.path.join(W, 'alu-%d.elf' % i) for i in range(1, 5)] + [os.path.join(W, 'br-%d.elf' % i) for i in range(1, 11)]
RMAX = '1.30'      # restores at most 1.3 times the clean run's, program by program (results/core_restores.txt)

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
    (C, ".disp_wr({ds[1].wr, ds[0].wr}), .disp_dst", ".disp_wr(2'b11), .disp_dst", 'IQ: every µop wakes for its destination'),
    # the ALU ports
    (C, "if (wb_v[q] && wb_d[q][WBW-1 -: TAGW] == ex[p].t1) a = wb_d[q][63:0];", '', 'bypass: none for the first source'),
    (C, "if (wb_v[q] && wb_d[q][WBW-1 -: TAGW] == ex[p].t2) b = wb_d[q][63:0];", '', 'bypass: none for the second source'),
    (C, "for (int q = 0; q < 2; q++) begin\n                if (wb_v[q]", "for (int q = 0; q < 1; q++) begin\n                if (wb_v[q]", 'bypass: port 1\'s result not forwarded'),
    (C, ".in_valid(ex_v[p] && ex[p].wr), .in_bm(ex_bm)", ".in_valid(ex_v[p]), .in_bm(ex_bm)", 'WB: a µop without a destination forwards'),
    (C, "assign pa_idx[p]     = rr_rec[p].ftq - FTQW'(rr_rec[p].xline);", "assign pa_idx[p]     = rr_rec[p].ftq;", 'pc: the line of the last half\'s block'),
    (C, "assign ta_idx[p]     = rr_rec[p].ftq;", "assign ta_idx[p]     = rr_rec[p].ftq + FTQW'(1);", 'jalr: the next block\'s predicted target'),
    (C, "rx.v2   = prf_rd[2*p+1];", "rx.v2   = prf_rd[2*p];", 'RR: the second source from the first read'),
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
    (C, "cmp_valid[p]  = ex_v[p];", "cmp_valid[p]  = ex_v[p] && ex[p].wr;", 'ROB: µops without a destination never complete'),
    (C, "cmp_rob[p]    = ex[p].rec.rob;", "cmp_rob[p]    = ex[0].rec.rob;", 'ROB: port 1 completes port 0\'s entry'),
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
