#!/usr/bin/env python3
#---------------------------------------------------------------------------
# mutate_front.py : bug injection into the front end's glue (OOO_FRONT, the
# FTQ's head read and free count, the fetch buffer's free count), judged by
# B1 (tb_front.cpp)
#
#   ./mutate_front.py          -> results/mutate_front.txt
#   ./mutate_front.py 2 9      only those (by index; nothing written)
#
# Each mutation is one textual change of a copy of RTL/CPU/OOO (it must
# match exactly once, or it is NOT APPLIED); tb_front is built on the copy
# and run on 8 riscv-tests and a CoreMark build with a budget of
# mispredictions (-mpki-max: a fault in the history, the RAS or the TAGE
# update breaks nothing but the predictions). DETECTED when a run fails.
# Every line of the result is to be read: grep NOT.
#---------------------------------------------------------------------------
import os, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
OOO = os.path.normpath(os.path.join(HERE, '../../RTL/CPU/OOO'))
RV = os.path.join(HERE, '../../../mmRISC-2/SIM/SIM_CORE/rvtests')
TESTS = [os.path.join(RV, t) for t in ('rv64ui-p-add', 'rv64ui-p-beq', 'rv64ui-p-jalr', 'rv64uc-p-rvc', 'rv64ui-p-fence_i',
                                      'rv64mi-p-csr', 'rv64mi-p-illegal', 'rv64ud-p-fadd')]
CM = os.path.join(HERE, '../../Plan/trace/work/g14-sflto-zbsc.elf')
MPKI = '2.3'

F, Q, B = 'OOO_FRONT/OOO_FRONT.sv', 'OOO_FTQ/OOO_FTQ.sv', 'OOO_FBUF/OOO_FBUF.sv'
MUT = [
    (F, "m = (FTQW + 1)'(fb_free) < ftq_free ? (FTQW + 1)'(fb_free) : ftq_free;", "m = (FTQW + 1)'(fb_free);", 'credit: the FTQ not counted'),
    (F, "m = (FTQW + 1)'(fb_free) < ftq_free ? (FTQW + 1)'(fb_free) : ftq_free;", "m = ftq_free;", 'credit: the fetch buffer not counted'),
    (F, '.be_stop(fe_redirect)', ".be_stop(1'b0)", 'fetch not stopped in cycle R'),
    (F, '.restore(fe_redirect && !fe_flush)', ".restore(1'b0)", 'FTQ: no restore'),
    (F, '.flush_all(fe_redirect && fe_flush)', ".flush_all(1'b0)", 'FTQ: no flush'),
    (F, '.flush(fe_redirect)', ".flush(1'b0)", 'fetch buffer not flushed'),
    (F, 'assign ft_hist    = ft_meta[TM+269:TM+200];', 'assign ft_hist    = ft_meta[TM+268:TM+199];', 'restore: history slice off by one'),
    (F, 'assign ft_sv      = ft_meta[TM+196:TM+194];', 'assign ft_sv      = ft_meta[TM+199:TM+197];', 'restore: the predictions taken for the slots'),
    (F, 'assign ft_par     = ft_meta[TM+193:TM+185];', 'assign ft_par     = ft_meta[TM+192:TM+184];', 'restore: slot parcels off by one'),
    (F, 'assign ft_ras_ptr = ft_meta[TM-1:TM-4];', 'assign ft_ras_ptr = ft_meta[TM-2:TM-5];', 'restore: RAS pointer slice'),
    (F, 'assign ft_ras_val = ft_meta[VA-2:0];', 'assign ft_ras_val = ft_meta[VA-1:1];', 'restore: RAS value slice'),
    (F, 'assign ft_line    = ft_pc[VA-1:4];', 'assign ft_line    = ft_pc[VA-2:3];', 'restore: the line for a call\'s push'),
    (F, 'assign up_meta    = hd_meta[FW-1:TM];', 'assign up_meta    = hd_meta[FW-2:TM-1];', 'update: metadata slice'),
    (F, 'up_ex[s] = sv[s] && oc_ex[hd_idx][par[s]];', 'up_ex[s] = sv[s];', 'update: every slot counted as run'),
    (F, 'up_tk[s] = oc_tk[hd_idx][par[s]];', "up_tk[s] = 1'b1;", 'update: every outcome taken'),
    (F, "up_valid = ftq_pop != 2'd0;", "up_valid = 1'b0;", 'update: never'),
    (F, "if (out_valid && push_idx == FTQW'(f)) oc_ex[f][p] <= 1'b0;", '', 'outcomes not cleared at the push'),
    (F, "if (fe_redirect && !fe_flush && restore_ftq == FTQW'(f) && 3'(p) > br_e[restore_port]) oc_ex[f][p] <= 1'b0;", '',
     'outcomes after the restore point not cleared'),
    (F, 'oc_tk[f][p] <= rs_taken[k];', "oc_tk[f][p] <= 1'b0;", 'outcomes: taken lost'),
    (F, 'if (out_valid) ta_mem[push_idx] <= out_next;', "if (out_valid) ta_mem[push_idx + FTQW'(1)] <= out_next;", 'target array: wrong entry'),
    (F, 'g_bsel[k]   <= i_ftq[k] != i_ftq[0];', "g_bsel[k]   <= 1'b0;", 'pc: always the first block\'s line'),
    (F, "assign rd_idx[1] = i_ftq[0] + FTQW'(1);", 'assign rd_idx[1] = i_ftq[0];', 'pc: the second line from the first block'),
    (F, "g_ftq_q[k]  <= i_ftq[k] + FTQW'(i_off[k] == 3'd7 && !i_rvc[k]);", 'g_ftq_q[k]  <= i_ftq[k];', 'block of an instruction across two lines'),
    (F, "assign g_end[k] = g_off[k] + 3'(!g_rvc_q[k]);", 'assign g_end[k] = g_off[k];', 'last parcel of a 32-bit instruction'),
    (F, 'else if (!g_load)   s_m <= fb_m;', "else if (!g_load)   s_m <= 4'd0;", 'skid: a group lost'),
    (F, "if (s_v)            s_m <= g_load ? 4'd0 : s_m;", "if (s_v)            s_m <= 4'd0;", 'skid: not held'),
    (F, "consume = s_v ? 3'd0 :", 'consume =', 'fetch buffer gives while the skid is full'),
    (F, 'run     = run && fb_v[k] && (k == 0 || !fb_rare[k]);', 'run     = run && fb_v[k];', 'the rare classes not cut'),
    (F, 'tm[k] = g_v[k] && n < g_take;', 'tm[k] = g_v[k] && n <= g_take;', 'group: one taken too many'),
    (F, "g_load = g_left == 4'd0 && i_m != 4'd0;", "g_load = i_m != 4'd0;", 'group overwritten while busy'),
    (F, """        end else if (fe_redirect) begin
            g_v <= '0;
            s_m <= '0;
        end else begin""", """        end else begin""", 'group and skid not flushed'),
    (F, 'assign i_inst = s_v ? s_inst : fb_inst;', 'assign i_inst = fb_inst;', 'decode does not read the skid'),
    (Q, 'e = mem[head[FTQW-1:0]];', "e = mem[head[FTQW-1:0] + FTQW'(1)];", 'FTQ: head read of the next entry'),
    (Q, "assign free_n     = (FTQW + 1)'(NFTQ) - used;", "assign free_n     = (FTQW + 1)'(NFTQ) - used + (FTQW + 1)'(1);", 'FTQ: one free too many'),
    (B, "assign free_n   = (BW + 1)'(NB) - nblk;", "assign free_n   = (BW + 1)'(NB) - nblk + (BW + 1)'(1);", 'fetch buffer: one free too many'),
]


def run(i, m):
    f, old, new, desc = m
    src = open(os.path.join(OOO, f)).read()
    if src.count(old) != 1:
        return i, 'NOT APPLIED', desc
    d = os.path.join(HERE, 'obj/fmut%d' % i)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(OOO, os.path.join(d, 'OOO'))
    open(os.path.join(d, 'OOO', f), 'w').write(src.replace(old, new))
    env = dict(os.environ, OOO_RTL=os.path.join(d, 'OOO'), OBJ=os.path.join(d, 'obj'))
    if subprocess.run([os.path.join(HERE, 'build_front.sh')], env=env, capture_output=True).returncode:
        return i, 'BUILD FAILED', desc
    t = os.path.join(d, 'obj', 'VOOO_FRONT')
    try:
        for args in (TESTS, ['-mpki-max', MPKI, CM]):
            if subprocess.run([t, '+verilator+rand+reset+2'] + args, capture_output=True, timeout=600).returncode:
                shutil.rmtree(d, ignore_errors=True)
                return i, 'DETECTED', desc
    except subprocess.TimeoutExpired:
        return i, 'NOT DETECTED', desc + ' (the run did not end)'
    shutil.rmtree(d, ignore_errors=True)
    return i, 'NOT DETECTED', desc


if __name__ == '__main__':
    os.makedirs(os.path.join(HERE, 'results'), exist_ok=True)
    sel = [int(x) for x in sys.argv[1:]]          # indices to run (default: all)
    with ThreadPoolExecutor(max_workers=4) as ex:
        res = sorted(ex.map(lambda a: run(*a), [(i, m) for i, m in enumerate(MUT) if not sel or i in sel]))
    lines = ['%2d %-13s %s' % r for r in res]
    det = sum(1 for r in res if r[1] == 'DETECTED')
    lines.append('%d mutations, %d detected' % (len(res), det))
    out = '\n'.join(lines) + '\n'
    if not sel:
        open(os.path.join(HERE, 'results/mutate_front.txt'), 'w').write(out)
    print(out, end='')
    sys.exit(0 if det == len(res) else 1)
