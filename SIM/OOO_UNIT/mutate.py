#!/usr/bin/env python3
#---------------------------------------------------------------------------
# mutate.py : bug injection for the unit tests of RTL/CPU/OOO
#
#   ./mutate.py [M1 M5 ...]       default: all, 4 at a time
#
# Every mutation is one literal change of one line of the RTL (a wrong
# operand, a dropped condition, a wrong constant), made in a copy of
# RTL/CPU/OOO under obj_dir/mutate/<M>; the test of that block is run on the
# copy and must FAIL. Each line of the report is DETECTED, NOT DETECTED, or
# NOT APPLIED (the text to change was not found exactly once: a rename moved
# it), and every line has to be read: the count alone can hide one.
#---------------------------------------------------------------------------
import concurrent.futures
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.abspath(os.path.join(HERE, '..', '..', 'RTL', 'CPU', 'OOO'))

M = [
    # id, file, test, old, new, what it breaks
    ('M1', 'OOO_ALU/OOO_ALU.sv', 'alu2', "res = {63'd0, srl_v[0]};", "res = {63'd0, srl_v[1]};", 'bext takes the wrong bit'),
    ('M2', 'OOO_ALU/OOO_ALU.sv', 'alu2', 'a_add = a_zx << a_shift;', 'a_add = a_zx;', 'sh*add without the shift'),
    ('M3', 'OOO_ALU2/OOO_ALU2.sv', 'alu2', "            2'd1:    b2 = s3;", "            2'd1:    b2 = imm2;", 'second ALU: s3 replaced by imm2'),
    ('M4', 'OOO_ALU2/OOO_ALU2.sv', 'alu2', "3'b101:  take_branch = is_br & ~lt;", "3'b101:  take_branch = is_br & lt;", 'BGE taken as BLT'),
    ('M5', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "cls[k+1] == C_LOAD && d != 5'd0 && rs1[k+1] == d", "cls[k+1] == C_STORE && d != 5'd0 && rs1[k+1] == d", 'ALU + load fused as ALU + store'),
    ('M6', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', 'cls[k+1] == C_ALU && rd_b)', 'cls[k+1] == C_ALU)', 'ALU + ALU without the dependence'),
    ('M7', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "s1       = (pk[0] != K_NONE) ? 3'd2 : 3'd1;", "s1       = (pk[0] != K_NONE) ? 3'd1 : 3'd1;", 'the second µop starts inside the first pair'),
    ('M8', 'OOO_PRF/OOO_PRF.sv', 'prf', "lvt[wa[w]] <= LW'(w);", "lvt[wa[w]] <= LW'(0);", 'the LVT always names bank 0'),
    ('M9', 'OOO_PRF/OOO_PRF.sv', 'prf', "assign rd[r] = (ra[r] == '0) ? 64'd0 : rb[r][lvt[ra[r]]];", "assign rd[r] = rb[r][lvt[ra[r]]];", 'register 0 not zero'),
    ('M10', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "out_rdy[1][s] = 1'b0;", "out_rdy[1][s] = 1'b1;", 'in-group source marked ready'),
    ('M11', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "busy[new_tag[u][k]] <= 1'b1;", "busy[new_tag[u][k]] <= 1'b0;", 'a new register not busy'),
    ('M12', 'OOO_RENAME/OOO_RENAME.sv', 'rename', 'head    <= ck_head[restore_id];', 'head    <= head;', 'restore keeps the free-list head'),
    ('M13', 'OOO_RENAME/OOO_RENAME.sv', 'rename', 'out_old[1][k] = new_tag[0][j];', 'out_old[1][k] = out_old[1][k];', 'in-group old mapping'),
    ('M14', 'OOO_IQ/OOO_IQ.sv', 'iq', "g0[i] = req0[i] && ((req0 & older[i]) == '0);", 'g0[i] = req0[i] && (req0[i] == req0[i]) && ((req0 & older[i] & ~req0) == \'0);', 'port 0 not oldest first'),
    ('M15', 'OOO_IQ/OOO_IQ.sv', 'iq', 'bv[p*2+k]     = iss_wr[p][k] && !lat2[iss_entry[p]];', 'bv[p*2+k]     = iss_wr[p][k];', 'latency 2 woken after 1'),
    ('M16', 'OOO_IQ/OOO_IQ.sv', 'iq', "if (disp1[i] && disp_valid[0] && fev[0]) oq[fe[0]] <= 1'b1;", "if (disp1[i] && disp_valid[0] && fev[0]) oq[fe[0]] <= 1'b0;", 'second µop of a pair as old as the first'),
    ('M17', 'OOO_IQ/OOO_IQ.sv', 'iq', 'bv[12+e] = ext_valid[e];', "bv[12+e] = 1'b0;", 'external wakeups lost'),
    ('M18', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', 'off[e] >= pc_q[3:1]', 'off[e] > pc_q[3:1]', 'an entry at the fetch start ignored'),
    ('M19', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', '(!cond[e] || cnt[e][1])', '(!cond[e] || cnt[e][0])', 'counter bit 0 instead of 1'),
    ('M20', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', "if (cnt[fe] != 2'd3) cnt[fe] <= cnt[fe] + 2'd1;", 'cnt[fe] <= cnt[fe];', 'taken never strengthens'),
    ('M21', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', 'next_pc = ret[bi] ? ras_top : tgt[bi];', 'next_pc = tgt[bi];', 'returns without the RAS'),
]


def run(m):
    mid, f, test, old, new, what = m
    work = os.path.join(HERE, 'obj_dir', 'mutate', mid)
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(RTL, os.path.join(work, 'rtl'))
    path = os.path.join(work, 'rtl', f)
    src = open(path).read()
    if src.count(old) != 1:
        return mid, 'NOT APPLIED', what, f'found {src.count(old)} times'
    open(path, 'w').write(src.replace(old, new))
    env = dict(os.environ, OOO_RTL=os.path.join(work, 'rtl'), OOO_OBJ=os.path.join(work, 'obj'))
    r = subprocess.run([os.path.join(HERE, 'run.sh'), test], env=env, capture_output=True, text=True)
    last = (r.stdout.strip().splitlines() or [''])[-1]
    return mid, ('DETECTED' if r.returncode != 0 else 'NOT DETECTED'), what, last


def main():
    sel = sys.argv[1:]
    ms = [m for m in M if not sel or m[0] in sel]
    with concurrent.futures.ThreadPoolExecutor(4) as ex:
        res = list(ex.map(run, ms))
    nd = 0
    for mid, st, what, last in res:
        print(f'{mid:4s} {st:13s} {what:45s} | {last}')
        nd += st != 'DETECTED'
    print(f'{len(res)} mutations, {len(res) - nd} detected')
    sys.exit(nd)


if __name__ == '__main__':
    main()
