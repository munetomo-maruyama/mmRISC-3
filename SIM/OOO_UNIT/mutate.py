#!/usr/bin/env python3
#---------------------------------------------------------------------------
# mutate.py : bug injection for the unit tests of RTL/CPU/OOO
#
#   ./mutate.py [M1 M5 ...]       default: all, 4 at a time
#
# Every mutation is one literal change of one line of the RTL (a wrong
# operand, a dropped condition, a wrong constant), made in a copy of
# RTL/CPU/OOO (or of $OOO_RTL) under obj_dir/mutate/<M>; the test of that block is run on the
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
RTL = os.environ.get('OOO_RTL') or os.path.abspath(os.path.join(HERE, '..', '..', 'RTL', 'CPU', 'OOO'))

M = [
    # id, file, test, old, new, what it breaks
    ('M1', 'OOO_ALU/OOO_ALU.sv', 'alu2', "ALU_BEXT:  r_ext = {63'd0, shr[0]};", "ALU_BEXT:  r_ext = {63'd0, shr[1]};", 'bext takes the wrong bit'),
    ('M2', 'OOO_ALU/OOO_ALU.sv', 'alu2', "sum   = {1'b0, a_zx << a_shift}", "sum   = {1'b0, a_zx}", 'sh*add without the shift'),
    ('M3', 'OOO_ALU2/OOO_ALU2.sv', 'alu2', "            2'd1:    b2 = s3;", "            2'd1:    b2 = imm2;", 'second ALU: s3 replaced by imm2'),
    ('M4', 'OOO_ALU2/OOO_ALU2.sv', 'alu2', "3'b101:  take_branch = is_br & ~lt;", "3'b101:  take_branch = is_br & lt;", 'BGE taken as BLT'),
    ('M5', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "cls[k+1] == C_LOAD && d != 5'd0 && rs1[k+1] == d", "cls[k+1] == C_STORE && d != 5'd0 && rs1[k+1] == d", 'ALU + load fused as ALU + store'),
    ('M6', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', 'cls[k+1] == C_ALU && rd_b && alu2ok[k+1])', 'cls[k+1] == C_ALU && alu2ok[k+1])', 'ALU + ALU without the dependence'),
    ('M7', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "s1       = (pk[0] != K_NONE) ? 3'd2 : 3'd1;", "s1       = (pk[0] != K_NONE) ? 3'd1 : 3'd1;", 'the second µop starts inside the first pair'),
    ('M8', 'OOO_PRF/OOO_PRF.sv', 'prf', "lvt[wa[w]] <= LW'(w);", "lvt[wa[w]] <= LW'(0);", 'the LVT always names bank 0'),
    ('M9', 'OOO_PRF/OOO_PRF.sv', 'prf', "assign rd[r] = (ra[r] == '0) ? 64'd0 : rb[r][lvt[ra[r]]];", "assign rd[r] = rb[r][lvt[ra[r]]];", 'register 0 not zero'),
    ('M10', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "out_rdy[1][s] = 1'b0;", "out_rdy[1][s] = 1'b1;", 'in-group source marked ready'),
    ('M11', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "busy[new_tag[u]] <= 1'b1;", "busy[new_tag[u]] <= 1'b0;", 'a new register not busy'),
    ('M12', 'OOO_RENAME/OOO_RENAME.sv', 'rename', 'head    <= ck_head[restore_id];', 'head    <= head;', 'restore keeps the free-list head'),
    ('M13', 'OOO_RENAME/OOO_RENAME.sv', 'rename', 'if (alloc[0] && in_dst[0] == in_dst[1]) out_old[1] = new_tag[0];', 'if (alloc[0] && in_dst[0] == in_dst[1]) out_old[1] = out_old[1];', 'in-group old mapping'),
    ('M14', 'OOO_IQ/OOO_IQ.sv', 'iq', "g0[i] = req0[i] && ((req0 & older[i]) == '0);", 'g0[i] = req0[i] && (req0[i] == req0[i]) && ((req0 & older[i] & ~req0) == \'0);', 'port 0 not oldest first'),
    ('M15', 'OOO_IQ/OOO_IQ.sv', 'iq', 'bv[0] = iss_wr[0] && !lat2_0;', 'bv[0] = iss_wr[0];', 'latency 2 woken after 1'),
    ('M16', 'OOO_IQ/OOO_IQ.sv', 'iq', "if (disp1[i] && disp_valid[0] && fev[0]) oq[fe[0]] <= 1'b1;", "if (disp1[i] && disp_valid[0] && fev[0]) oq[fe[0]] <= 1'b0;", 'second µop of a pair as old as the first'),
    ('M17', 'OOO_IQ/OOO_IQ.sv', 'iq', 'bv[4+e] = ext_valid[e];', "bv[4+e] = 1'b0;", 'external wakeups lost'),
    ('M18', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', 'off[e] >= pc_q[3:1]', 'off[e] > pc_q[3:1]', 'an entry at the fetch start ignored'),
    ('M19', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', '(!cond[e] || cnt[e][1])', '(!cond[e] || cnt[e][0])', 'counter bit 0 instead of 1'),
    ('M20', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', "if (cnt[e] != 2'd3) cnt[e] <= cnt[e] + 2'd1;", 'cnt[e] <= cnt[e];', 'taken never strengthens'),
    ('M21', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', "if ((sel & ret) != '0) t_sel = ras_top;", "if (1'b0) t_sel = ras_top;", 'returns without the RAS'),
    # 2026-10-24: the rewritten ALU, the limits of fusion, the parallel uBTB (Plan/OOC.md 8)
    ('M22', 'OOO_ALU/OOO_ALU.sv', 'alu2', 'lt_s  = lt_u ^ op_a[63] ^ op_b[63];', 'lt_s  = lt_u ^ op_a[63];', 'signed compare from one sign only'),
    ('M23', 'OOO_ALU/OOO_ALU.sv', 'alu2', 'if (rot)                    hi = lo;', "if (rot)                    hi = 64'd0;", 'rotates do not wrap'),
    ('M24', 'OOO_ALU/OOO_ALU.sv', 'alu2', "return (nz == 8'd0) ? 7'd64 : {1'b0, sel, bz[sel]};", "return (nz == 8'd0) ? 7'd63 : {1'b0, sel, bz[sel]};", 'clz / ctz of zero is 63'),
    ('M25', 'OOO_ALU/OOO_ALU.sv', 'alu2', "p8[i]  = 4'(p4[2*i])  + 4'(p4[2*i+1]);", "p8[i]  = 4'(p4[2*i])  + 4'(p4[2*i]);", 'cpop counts a nibble twice'),
    ('M26', 'OOO_ALU2/OOO_ALU2.sv', 'alu2', 'lt   = ltu ^ ca[63] ^ cb[63];', 'lt   = ltu ^ ca[63];', 'blt / bge from one sign only'),
    ('M27', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "v[3] = use_rs2[k+1] && rs2[k+1] != 5'd0 && rs2[k+1] != rd[k];", "v[3] = use_rs2[k+1] && rs2[k+1] != 5'd0;", 'the value passed on counted as a source'),
    ('M28', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', 'dup = dup || (v[j] && c[j] == c[i]);', 'dup = dup;', 'a register read twice counted twice'),
    ('M29', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', '&& rd_b && alu2ok[k+1])', '&& rd_b)', 'ALU + ALU without the second-stage flag'),
    ('M30', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "return n > 3'd2;", "return n > 3'd3;", '3 sources allowed'),
    ('M31', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', 'first = at & (~at + 8\'d1);', 'first = at;', 'not the first hit of the block'),
    ('M32', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', 'return b[TW-1:0] ^ b[2*TW-1:TW];', 'return b[TW-1:0];', 'tag not folded'),
    ('M34', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "rd[k+1] != 5'd0 && rd[k] != rd[k+1])", "rd[k+1] != 5'd0 && 1'b0)", 'a pair writing 2 registers fused'),
    # 2026-10-24: renaming and the issue queue with 2 sources and 1 destination (Plan/OOC.md 10)
    ('M35', 'OOO_RENAME/OOO_RENAME.sv', 'rename', '(fx_v[restore_id] && fx_a[restore_id]', "(1'b0 && fx_a[restore_id]", 'restore without undoing µop 1'),
    ('M36', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "if ((pk_v[0] && pk_id[0] == CW'(c)) || (pk_v[1] && pk_id[1] == CW'(c)))", "if ((pk_v[0] && pk_id[0] == CW'(c)))", "µop 1's checkpoint never copied"),
    ('M37', 'OOO_RENAME/OOO_RENAME.sv', 'rename', 'fx_v[out_ckpt_id[u]]    <= (u == 0) && alloc[1];', 'fx_v[out_ckpt_id[u]]    <= alloc[1];', "µop 1's checkpoint undoes µop 1"),
    ('M38', 'OOO_IQ/OOO_IQ.sv', 'iq', 'd_v2 <= iss_wr[2];', "d_v2 <= 1'b0;", 'loads never wake their dependents'),
    ('M39', 'OOO_IQ/OOO_IQ.sv', 'iq', 'bv[1] = iss_wr[1];', "bv[1] = 1'b0;", 'ALU1 never wakes its dependents'),
    # 2026-10-25: the load / store unit (Doc/UARCH.md 3.7)
    ('M40', 'OOO_LSU/OOO_LSU.sv', 'lsu', "fsel[i] = hit_st[i] && (hit_st & syoung[i]) == '0;", 'fsel[i] = hit_st[i];', 'every matching store forwarded, not the youngest'),
    ('M41', 'OOO_LSU/OOO_LSU.sv', 'lsu', 'm_cover = (f_mask & m_lmask) == m_lmask;', "m_cover = 1'b1;", 'a partial overlap forwarded'),
    ('M42', 'OOO_LSU/OOO_LSU.sv', 'lsu', "m_unknown = (older & ~sknown) != '0;", "m_unknown = 1'b0;", 'an older store without an address ignored'),
    ('M43', 'OOO_LSU/OOO_LSU.sv', 'lsu', "lold[e]   <= (sv & ~s_free) |", "lold[e]   <= (sv & ~s_free) | (s_new[1] ? (NSQ'(1) << st1[SW-1:0]) : '0) |", 'the store of slot 1 counted as older'),
    ('M44', 'OOO_LSU/OOO_LSU.sv', 'lsu', "e_wdata = iss_data << {e_sum[2:0], 3'b000};", 'e_wdata = iss_data;', 'store data not aligned'),
    ('M45', 'OOO_LSU/OOO_LSU.sv', 'lsu', "2'd1:    return uns ? {48'd0, s[15:0]} : {{48{s[15]}}, s[15:0]};", "2'd1:    return {48'd0, s[15:0]};", 'halfword loads never sign extended'),
    ('M46', 'OOO_LSU/OOO_LSU.sv', 'lsu', "sknown[sq_head[SW-1:0]] && !(e_v && e_ld);", "sknown[sq_head[SW-1:0]];", 'a store drained while a load reads the D$'),
    ('M47', 'OOO_LSU/OOO_LSU.sv', 'lsu', 'ld_cancel     = m_v && !m_retry && !m_ok;', 'ld_cancel     = m_v && !m_ok;', 'retried loads cancelled too'),
    ('M48', 'OOO_LSU/OOO_LSU.sv', 'lsu', 'assign dc_kill[e] = lv[e] && !keep;', "assign dc_kill[e] = 1'b0;", 'pending fills of freed entries not dropped'),
    ('M50', 'OOO_LSU/OOO_LSU.sv', 'lsu', 'lq_tail_n = restore_lq_tail;', 'lq_tail_n = lq_tail;', 'restore keeps the LQ tail'),
    ('M51', 'OOO_LSU/OOO_LSU.sv', 'lsu', 'sq_cmt_n  = snext(sq_cmt, sq_commit);', "sq_cmt_n  = snext(sq_cmt, {1'b0, sq_commit[0]});", 'only one store committed a cycle'),
    ('M53', 'OOO_LSU/OOO_LSU.sv', 'lsu', 'lold[e] <= lold[e] & ~s_free;', 'lold[e] <= lold[e];', 'a drained store stays in the older mask'),
    ('M54', 'OOO_LSU/OOO_LSU.sv', 'lsu', "syoung[i][j] <= a0 && s_new[1] && st1[SW-1:0] == SW'(j);", "syoung[i][j] <= 1'b0;", 'slot 1 not younger than slot 0'),
    ('M55', 'OOO_LSU/OOO_LSU.sv', 'lsu', 'f_v    = (fb_v || dc_fill_valid) && f_live && !m_v && !restore && !flush_all;', 'f_v    = (fb_v || dc_fill_valid) && f_live && !restore && !flush_all;', 'a fill writes over the load in M'),
    ('M56', 'OOO_LSU/OOO_LSU.sv', 'lsu', "r_any = r_qv && lv[r_q] && lst[r_q] == L_WAIT && lretry[r_q];", 'r_any = r_qv;', 'a stale retry candidate tried'),
    # 2026-10-25: the reorder buffer, and the committed state of renaming
    ('M57', 'OOO_ROB/OOO_ROB.sv', 'rob', "if (r0 && (!r1 || rdist(br_rob[0], hi0) <= rdist(br_rob[1], hi0))) begin", "if (r0) begin", 'port 0 restores even when younger'),
    ('M59', 'OOO_ROB/OOO_ROB.sv', 'rob', 'r0 = br_valid[0] && br_mispred[0] && live(br_rob[0]);', 'r0 = br_valid[0] && br_mispred[0];', 'a stale misprediction restores'),
    ('M60', 'OOO_ROB/OOO_ROB.sv', 'rob', "tail_n = nxt({(restore_rob >= hi0) ? head[ROBW] : ~head[ROBW], restore_rob}, 2'd1);", "tail_n = nxt({head[ROBW], restore_rob}, 2'd1);", 'restored tail with the wrong lap'),
    ('M61', 'OOO_ROB/OOO_ROB.sv', 'rob', "c1 = c0 && used >= (ROBW + 1)'(2) && done[hi1] && !exc[hi1];", "c1 = c0 && used >= (ROBW + 1)'(2) && done[hi1];", 'the second commit ignores its exception'),
    ('M62', 'OOO_ROB/OOO_ROB.sv', 'rob', 'done[i]  <= n1 ? disp_exc[1] : disp_exc[0];', "done[i]  <= 1'b0;", 'an exception at decode never done'),
    ('M63', 'OOO_ROB/OOO_ROB.sv', 'rob', "(c0 ? (p0[1] ? 3'd2 : 3'd1) : 3'd0)", "(c0 ? 3'd1 : 3'd0)", 'a fused pair counted once in instret'),
    ('M64', 'OOO_ROB/OOO_ROB.sv', 'rob', "head_ns    = used != '0 && p0[0] && !done[hi0];", "head_ns    = used != '0 && p0[0];", 'head_ns stays after the µop ran'),
    ('M67', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "+ (FW + 1)'(cmt_valid[1] && cmt_wr[1]);", ";", 'the committed head misses slot 1'),
    ('M33', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', "else if (upd_valid && !found && upd_taken) rr <= rr + EW'(1);", "else if (upd_valid && upd_taken) rr <= rr + EW'(1);", 'replacement moves on a hit'),
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
