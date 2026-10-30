#!/usr/bin/env python3
#---------------------------------------------------------------------------
# mutate.py : bug injection for the unit tests of RTL/CPU/OOO
#
#   ./mutate.py [M1 M5 ...]       default: all, 4 at a time
#
# Every mutation is one literal change of one line of the RTL (a wrong
# operand, a dropped condition, a wrong constant), made in a copy of
# RTL/CPU/OOO (or of $OOO_RTL; RTL/CPU/CORE for 'CORE:' files, RTL/CPU/CACHE
# for 'CACHE:') under obj_dir/mutate/<M>; the test of that block is run on the
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
CORE = os.path.abspath(os.path.join(HERE, '..', '..', 'RTL', 'CPU', 'CORE'))   # blocks taken from mmRISC-2 ('CORE:' files)
CACHE = os.path.abspath(os.path.join(HERE, '..', '..', 'RTL', 'CPU', 'CACHE'))  # mmRISC-2's D$ ('CACHE:' files)

M = [
    # id, file, test, old, new, what it breaks
    ('M1', 'OOO_ALU/OOO_ALU.sv', 'alu2', "ALU_BEXT:  r_ext = {63'd0, shr[0]};", "ALU_BEXT:  r_ext = {63'd0, shr[1]};", 'bext takes the wrong bit'),
    ('M2', 'OOO_ALU/OOO_ALU.sv', 'alu2', "sum   = {1'b0, FULL ? a_zx << a_shift : a_zx}", "sum   = {1'b0, a_zx}", 'sh*add without the shift'),
    ('M4', 'OOO_ALU2/OOO_ALU2.sv', 'alu2', "3'b101:  take_branch = is_br & ~lt;", "3'b101:  take_branch = is_br & lt;", 'BGE taken as BLT'),
    ('M5', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "cls[k+1] == C_LOAD && d != 5'd0 && rs1[k+1] == d", "cls[k+1] == C_STORE && d != 5'd0 && rs1[k+1] == d", 'ALU + load fused as ALU + store'),
    ('M7', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "s1       = (pk[0] != K_NONE) ? 3'd2 : 3'd1;", "s1       = (pk[0] != K_NONE) ? 3'd1 : 3'd1;", 'the second µop starts inside the first pair'),
    ('M8', 'OOO_PRF/OOO_PRF.sv', 'prf', "lvt[wa[w]] <= LW'(w);", "lvt[wa[w]] <= LW'(0);", 'the LVT always names bank 0'),
    ('M9', 'OOO_PRF/OOO_PRF.sv', 'prf', "assign rd[r] = (ra[r] == '0) ? 64'd0 : rb[r][lvt[ra[r]]];", "assign rd[r] = rb[r][lvt[ra[r]]];", 'register 0 not zero'),
    ('M10', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "out_rdy[1][s] = 1'b0;", "out_rdy[1][s] = 1'b1;", 'in-group source marked ready'),
    ('M11', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "busy[new_tag[u]] <= 1'b1;", "busy[new_tag[u]] <= 1'b0;", 'a new register not busy'),
    ('M12', 'OOO_RENAME/OOO_RENAME.sv', 'rename', 'head    <= ck_head[restore_id];', 'head    <= head;', 'restore keeps the free-list head'),
    ('M13', 'OOO_RENAME/OOO_RENAME.sv', 'rename', 'if (alloc[0] && in_dst[0] == in_dst[1]) out_old[1] = new_tag[0];', 'if (alloc[0] && in_dst[0] == in_dst[1]) out_old[1] = out_old[1];', 'in-group old mapping'),
    ('M14', 'OOO_IQ/OOO_IQ.sv', 'iq', "g1[i] = req1[i] && ((req1 & older[i]) == '0);", "g1[i] = req1[i] && ((req1 & older[i] & ~req1) == '0);", 'port 1 not oldest first'),
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
    ('M30', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "return n > 3'd2;", "return n > 3'd3;", '3 sources allowed'),
    ('M31', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', 'first = at & (~at + 8\'d1);', 'first = at;', 'not the first hit of the block'),
    ('M32', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', 'return b[TW-1:0] ^ b[2*TW-1:TW];', 'return b[TW-1:0];', 'tag not folded'),
    ('M34', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "rd[k+1] != 5'd0 && rd[k] != rd[k+1])", "rd[k+1] != 5'd0 && 1'b0)", 'a pair writing 2 registers fused'),
    # 2026-10-24: renaming and the issue queue with 2 sources and 1 destination (Plan/OOC.md 10)
    ('M35', 'OOO_RENAME/OOO_RENAME.sv', 'rename', '(fx_v[restore_id] && fx_a[restore_id]', "(1'b0 && fx_a[restore_id]", 'restore without undoing µop 1'),
    ('M36', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "if ((pk_v[0] && pk_id[0] == CW'(c)) || (pk_v[1] && pk_id[1] == CW'(c)))", "if ((pk_v[0] && pk_id[0] == CW'(c)))", "µop 1's checkpoint never copied"),
    ('M37', 'OOO_RENAME/OOO_RENAME.sv', 'rename', 'fx_v[out_ckpt_id[u]]    <= (u == 0) && alloc[1];', 'fx_v[out_ckpt_id[u]]    <= alloc[1];', "µop 1's checkpoint undoes µop 1"),
    ('M38', 'OOO_IQ/OOO_IQ.sv', 'iq', 'd_v2 <= iss_wr[2] && !flush', "d_v2 <= 1'b0 && !flush", 'loads never wake their dependents'),
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
    ('M61', 'OOO_ROB/OOO_ROB.sv', 'rob', "c1 = c0 && !rp[hi0] && used >= (ROBW + 1)'(2) && done[hi1] && !exc[hi1];", "c1 = c0 && !rp[hi0] && used >= (ROBW + 1)'(2) && done[hi1];", 'the second commit ignores its exception'),
    ('M62', 'OOO_ROB/OOO_ROB.sv', 'rob', 'done[i]  <= n1 ? disp_exc[1] : disp_exc[0];', "done[i]  <= 1'b0;", 'an exception at decode never done'),
    ('M63', 'OOO_ROB/OOO_ROB.sv', 'rob', "(c0 ? (p0[FTQW+4] ? 3'd2 : 3'd1) : 3'd0)", "(c0 ? 3'd1 : 3'd0)", 'a fused pair counted once in instret'),
    ('M64', 'OOO_ROB/OOO_ROB.sv', 'rob', "head_ns    = used != '0 && p0[FTQW+3] && !done[hi0];", "head_ns    = used != '0 && p0[FTQW+3];", 'head_ns stays after the µop ran'),
    ('M67', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "+ (FW + 1)'(cmt_valid[1] && cmt_wr[1]);", ";", 'the committed head misses slot 1'),
    ('M69', 'OOO_ROB/OOO_ROB.sv', 'rob', 'we0 = tail[0] ? disp_valid[1] : disp_valid[0];', 'we0 = disp_valid[0];', 'bank 0 written only by slot 0'),
    ('M33', 'OOO_UBTB/OOO_UBTB.sv', 'ubtb', "else if (upd_valid && !found && upd_taken) rr <= rr + EW'(1);", "else if (upd_valid && upd_taken) rr <= rr + EW'(1);", 'replacement moves on a hit'),
    # 2026-10-25: the fetch buffer and the fetch target queue
    ('M70', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', "jb = 4'(bs[ib]) + 4'(k) - na;", "jb = 4'(k) - na;", 'the next block read from parcel 0, not its start'),
    ('M71', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', "wv[k]   = av && bv && jb <= 4'(be[ib]) && !jb[3];", "wv[k]   = av && bv && !jb[3];", 'parcels past the end of the next block used'),
    ('M72', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', 'wend[k] = btk[hb] && ja == be[hb];', 'wend[k] = btk[hb];', 'every parcel of a taken head block is its end'),
    ('M73', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', "(!len2 || (s < 4'd7 && wv[s[2:0] + 3'd1]))", "(!len2 || s < 4'd7)", 'a 32-bit instruction given without its second half'),
    ('M74', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', 'out_ftq[i]   = wb[s[2:0]] ? bftq[ib] : bftq[hb];', 'out_ftq[i]   = bftq[hb];', 'the FTQ index of the head block for all'),
    ('M75', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', "out_taken[i] = len2 ? wend[s[2:0] + 3'd1] : wend[s[2:0]];", 'out_taken[i] = wend[s[2:0]];', 'a 32-bit taken transfer seen at its first half'),
    ('M76', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', "bs[ib] + 3'(used - na)", "3'(used - na)", 'into the next block without its start'),
    ('M77', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', "? bs[ic] : in_start", "? bs[ib] : in_start", 'the new head starts where the old one did'),
    ('M78', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', "hoff_n = av ? hoff + 3'(used) : in_start;", "hoff_n = hoff + 3'(used);", 'a block into an empty buffer from a stale parcel'),
    ('M79', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', "assign in_ready = nblk != (BW + 1)'(NB);", "assign in_ready = 1'b1;", 'a full buffer takes a block'),
    ('M80', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', "+ 4'd1 || !bv)", " || !bv)", 'a next block used up exactly not popped'),
    ('M86', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', "(nblk >= (BW + 1)'(3)) ? bs[ic]", "(nblk >= (BW + 1)'(2)) ? bs[ic]", 'the head after two pops from a stale slot'),
    # 2026-10-25: the front end: predecode, RAS, BTB, TAGE-S, fetch control
    ('M87', 'OOO_PREDEC/OOO_PREDEC.sv', 'predec', 'hi[k] = st[k-1] && l32[k-1];', 'hi[k] = st[k-1] && l32[k];', 'the length read from the wrong parcel'),
    ('M88', 'OOO_PREDEC/OOO_PREDEC.sv', 'predec', "st[k] = 3'(k) >= start && !hi[k];", "st[k] = 3'(k) > start && !hi[k];", 'the start parcel not an instruction'),
    ('M89', 'OOO_PREDEC/OOO_PREDEC.sv', 'predec', 'cross_out = st[7] && l32[7];', 'cross_out = l32[7];', 'a second half at parcel 7 taken as crossing'),
    ('M90', 'OOO_PREDEC/OOO_PREDEC.sv', 'predec', 'imm   = {{10{i[31]}}, i[7], i[30:25], i[11:8]};', 'imm   = {{10{i[31]}}, i[31], i[30:25], i[11:8]};', 'branch offset bit 11 wrong'),
    ('M91', 'OOO_PREDEC/OOO_PREDEC.sv', 'predec', 'c[8], c[10:9], c[6], c[7], c[2]', 'c[8], c[10:9], c[7], c[6], c[2]', 'c.j offset bits 6 and 7 swapped'),
    ('M92', 'OOO_PREDEC/OOO_PREDEC.sv', 'predec', 'ret[e]  = link(rs1) && !link(rd);', 'ret[e]  = link(rs1);', 'a call through ra taken as a return'),
    ('M93', 'OOO_PREDEC/OOO_PREDEC.sv', 'predec', 'call[e] = c[12];', "call[e] = 1'b0;", 'c.jalr not a call'),
    ('M94', 'OOO_PREDEC/OOO_PREDEC.sv', 'predec', "+ {{(VA-22){imm[20]}}, imm} - (VA-1)'(hi[e]);", '+ {{(VA-22){imm[20]}}, imm};', 'a 32-bit target from its second half'),
    ('M95', 'OOO_RAS/OOO_RAS.sv', 'ras', "assign top      = mem[ptr - PW'(1)];", 'assign top      = mem[ptr];', 'the top one entry off'),
    ('M96', 'OOO_RAS/OOO_RAS.sv', 'ras', "ptr <= rs_ptr + PW'(rs_push) - PW'(rs_pop);", 'ptr <= rs_ptr;', 'recovery without the push or pop'),
    ('M97', 'OOO_RAS/OOO_RAS.sv', 'ras', 'wd = rs_valid ? (rs_push ? rs_addr : rs_val) : push_addr;', 'wd = rs_valid ? rs_val : push_addr;', 'recovery push writes the old entry'),
    ('M98', 'OOO_BTB/OOO_BTB.sv', 'btb', 'hit <= rd[RW-1] && rd[RW-2 -: TW] == tag1;', 'hit <= rd[RW-1];', 'no tag compare'),
    ('M99', 'OOO_BTB/OOO_BTB.sv', 'btb', 'off <= rd[VA-1 +: 3];', 'off <= rd[VA +: 3];', 'the parcel read off by one bit'),
    ('M100', 'OOO_TAGE/OOO_TAGE.sv', 'tage', 'idx0[j] = f0_pc[NLOG:1] ^ f0_pc[NLOG - j + 1 +: NLOG] ^ fi;', 'idx0[j] = f0_pc[NLOG:1] ^ fi;', 'index without the shifted pc'),
    ('M101', 'OOO_TAGE/OOO_TAGE.sv', 'tage', 'if (k < L) v[k % c] = v[k % c] ^ h[k];', 'if (k <= L) v[k % c] = v[k % c] ^ h[k];', 'one history bit too many folded'),
    ('M102', 'OOO_TAGE/OOO_TAGE.sv', 'tage', 'av1 = pv1; ar = pr;', "av1 = 1'b0; ar = pr;", 'no alternate'),
    ('M103', 'OOO_TAGE/OOO_TAGE.sv', 'tage', "pweak1[s] = (c == 3'd3 || c == 3'd4) && pr[10:9] == 2'd0;", "pweak1[s] = (c == 3'd3 || c == 3'd4);", 'weak without the useful counter'),
    ('M104', 'OOO_TAGE/OOO_TAGE.sv', 'tage', '((pweak2[s] && use_alt[3]) ? ap : ptk2[s])', '((pweak2[s] && use_alt[2]) ? ap : ptk2[s])', 'use_alt threshold 4'),
    ('M105', 'OOO_TAGE/OOO_TAGE.sv', 'tage', "2'd2:    return {h[HMAX-3:0], b[0], b[1]};", "2'd2:    return {h[HMAX-3:0], b[1], b[0]};", 'two history bits in the wrong order'),
    ('M106', 'OOO_TAGE/OOO_TAGE.sv', 'tage', 'ja    = (n2 && !(tick ^ s[0])) ? f1 : f0;', 'ja    = f0;', 'always the shortest free table'),
    ('M107', 'OOO_TAGE/OOO_TAGE.sv', 'tage', 'init[q] = (q == s) ? tk : ', 'init[q] = (q == s) ? !tk : ', 'an allocated counter the wrong way'),
    ('M108', 'OOO_TAGE/OOO_TAGE.sv', 'tage', 'if (pp != ap) u = sat2(u, pp == tk);', 'u = sat2(u, pp == tk);', 'useful counter moved when both agree'),
    ('M109', 'OOO_TAGE/OOO_TAGE.sv', 'tage', "if (!av && u == 2'd0) b[um.par[s]]", "if (u == 2'd0) b[um.par[s]]", 'base updated though an alternate exists'),
    ('M110', 'OOO_TAGE/OOO_TAGE.sv', 'tage', "wd[j][10:9] = um.row[j][10:9] - 2'd1;", 'wd[j][10:9] = um.row[j][10:9];', 'useful counters never go down'),
    ('M111', 'OOO_TAGE/OOO_TAGE.sv', 'tage', "if (ap == tk) ua = (ua == 4'd15) ? ua : ua + 4'd1;", "if (ap != tk) ua = (ua == 4'd15) ? ua : ua + 4'd1;", 'use_alt moves the wrong way'),
    ('M112', 'OOO_TAGE/OOO_TAGE.sv', 'tage', 'if (rs_valid)     h <= hpush(rs_hist, rs_n, rs_bits);', "if (rs_valid)     h <= hpush(rs_hist, 2'd0, rs_bits);", 'restore without the right outcomes'),
    ('M113', 'OOO_TAGE/OOO_TAGE.sv', 'tage', 'tick_n    = tick ^ (^up_ex);', 'tick_n    = tick;', 'the allocation choice never alternates'),
    ('M114', 'OOO_TAGE/OOO_TAGE.sv', 'tage', "btbl[r] = 16'haaaa;", "btbl[r] = 16'h5555;", 'base starts weakly not taken'),
    ('M115', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', "if (br[e] && n != 2'd3) begin", 'if (br[e]) begin', 'a 4th branch reuses slot 0'),
    ('M116', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', "(br[e] && slot[e] != 2'd3 && tpred[slot[e]])", "(br[e] && (slot[e] == 2'd3 || tpred[slot[e]]))", 'a 4th branch always taken'),
    ('M117', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', "(b_hit && b_off == 3'(e))", 'b_hit', 'the BTB entry used at any parcel'),
    ('M118', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'ret[e] ? ras_top : b_tgt;', 'b_tgt;', 'returns from the BTB'),
    ('M119', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', "if (sv[s] && par[s] <= e_end) hn = hn + 2'd1;", "if (sv[s]) hn = hn + 2'd1;", 'branches past the end in the history'),
    ('M120', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', "assign expect_pc = (qn >= 3'd2) ? qpc[qh + 2'd1] : pc_q;", 'assign expect_pc = pc_q;', 'compared with F0, not the request behind'),
    ('M121', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', ".push_addr({hpc[VA-1:4], e_end} + (VA-1)'(1)),", '.push_addr({hpc[VA-1:4], e_end}),', 'return address one parcel short'),
    ('M122', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'else if (f2)     carry_v <= cross_out && !taken;', 'else if (f2)     carry_v <= cross_out;', 'a carry after a taken block'),
    ('M123', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', "{1'b0, credit} > {2'b0, nlive}", "{1'b0, credit} >= {2'b0, nlive}", 'one request more than the credit'),
    ('M124', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'qlive[h + n[1:0]] <= !(be_redirect || ovr);', "qlive[h + n[1:0]] <= 1'b1;", 'a request of a redirect cycle kept'),
    ('M125', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'hit_first = taken && !(qubt[qh] && quoff[qh] < e_end);', 'hit_first = taken;', 'the earlier wrong guess never weakened'),
    ('M126', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'ub_upd       = ovr && (hit_first || qubt[qh]);', "ub_upd       = 1'b0;", 'the uBTB never trained'),
    ('M127', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'ub_upd_cond  = br[e_end];', "ub_upd_cond  = 1'b0;", 'every uBTB entry unconditional'),
    ('M128', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'assign f2  = ic_resp_valid && qlive[qh] && !stop;', 'assign f2  = ic_resp_valid && qlive[qh];', 'a block out in a redirect cycle'),
    ('M129', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', "if (qn >= 3'd2) hpc <= qpc[qh + 2'd1];", "if (qn >= 3'd2) hpc <= qpc[qh];", 'the head address not moved on'),
    ('M130', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'ret[e] ? ras_top == expect_pc : b_tgt == expect_pc;', 'ret[e] ? b_tgt == expect_pc : b_tgt == expect_pc;', 'a return compared with the BTB target'),
    ('M131', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', "end else if (qn == 3'd0 && acc) begin", 'end else if (acc) begin', 'the head address taken by a younger request'),
    # 2026-10-25: loads that miss, taken back in the issue queue
    # 2026-10-25: decode (OOO_DEC, and the blocks taken from mmRISC-2)
    ('M153', 'OOO_DEC/OOO_DEC.sv', 'dec', 'ld   = is_load  && !is_store && l_mem_cmd == CMD_LOAD  && !is_fp_load;', 'ld   = is_load  && !is_store && l_mem_cmd == CMD_LOAD;', 'an FP load counted as an integer load'),
    ('M154', 'OOO_DEC/OOO_DEC.sv', 'dec', 'amo  = is_load && (is_store || l_mem_cmd != CMD_LOAD);', 'amo  = is_load && is_store;', 'LR not an atomic'),
    ('M155', 'OOO_DEC/OOO_DEC.sv', 'dec', "else if (alu_op[k] == ALU_SLL && b_sel[k] && !a_uw[k])      op[k] = 3'd3;", "else if (alu_op[k] == ALU_SLL && b_sel[k])                  op[k] = 3'd3;", 'slli.uw taken as slli'),
    ('M156', 'OOO_DEC/OOO_DEC.sv', 'dec', "else if (alu_op[k] == ALU_ADD && !b_sel[k])                 op[k] = 3'd5;", "else if (alu_op[k] == ALU_SUB && !b_sel[k])                 op[k] = 3'd5;", 'sub taken as add'),
    ('M159', 'OOO_DEC/OOO_DEC.sv', 'dec', "else if (is_load || is_store)       port[k] = 2'd2;", "else if (is_load)                   port[k] = 2'd2;", 'stores not to the LSU'),
    ('M160', 'OOO_DEC/OOO_DEC.sv', 'dec', "else if (l_fp && S0)                port[k] = 2'd3;", "else if (1'b0)                      port[k] = 2'd3;", 'FP arithmetic not to the FPU'),
    ('M161', 'OOO_DEC/OOO_DEC.sv', 'dec', "lat2[k]    = !ill && ((is_mdu && mdu_op[k] == 4'd0) || ld);", 'lat2[k]    = !ill && ld;', 'multiplies with latency 1'),
    ('M162', 'OOO_DEC/OOO_DEC.sv', 'dec', "ext_ans[k] = !ill && ((is_mdu && mdu_op[k] != 4'd0) || (amo && S0));", 'ext_ans[k] = !ill && ((is_mdu && mdu_op[k][2]) || (amo && S0));', 'the wrong MDU operations answered from outside'),
    ('M163', 'OOO_DEC/OOO_DEC.sv', 'dec', 'nonspec[k] = S0 && !ill && (sysm || amo || cbo);', 'nonspec[k] = S0 && !ill && (sysm || amo);', 'cbo.zero speculative'),
    ('M164', 'OOO_DEC/OOO_DEC.sv', 'dec', "rd[k] = (we_rd && !ill) ? d_rd : 5'd0;", "rd[k] = we_rd ? d_rd : 5'd0;", 'a register for a reserved RVC encoding'),
    ('M165', 'OOO_DEC/OOO_DEC.sv', 'dec', 'assign sys[k]          = S0 ? {wfi, sret, mret, ebreak, ecall, cbo, fei, fe} : \'0;', 'assign sys[k]          = S0 ? {wfi, mret, sret, ebreak, ecall, cbo, fei, fe} : \'0;', 'mret and sret swapped'),
    ('M166', 'OOO_DEC/OOO_DEC.sv', 'dec', 'assign xi = in_rvc[k] ? x : in_inst[k];', 'assign xi = in_inst[k];', 'RVC not expanded'),
    ('M167', 'OOO_DEC/OOO_DEC.sv', 'dec', 'ill  = d_ill || (in_rvc[k] && c_ill);', 'ill  = d_ill;', 'reserved RVC encodings legal'),
    ('M168', 'OOO_DEC/OOO_DEC.sv', 'dec', 'assign imm[k]   = imm_full[31:0];', "assign imm[k]   = {imm_full[31:1], 1'b0};", 'immediate bit 0 lost'),
    ('M169', 'CORE:CORE_DECOMP/CORE_DECOMP.sv', 'dec', "if (insn_c[12:5] == 8'd0) illegal = 1'b1;   // also the all zero word", "if (insn_c[12:6] == 7'd0) illegal = 1'b1;   // also the all zero word", 'c.addi4spn reserved check one bit short'),
    ('M170', 'CORE:CORE_DEC/CORE_DEC.sv', 'dec', "{7'b0000101, 3'b100}: alu_op = ALU_MIN;", "{7'b0000101, 3'b100}: alu_op = ALU_MAX;", 'min decoded as max'),
    ('M171', 'CORE:CORE_DEC/CORE_DEC.sv', 'dec', 'mem_signed = ~funct3[2];', 'mem_signed = funct3[2];', 'loads extended the wrong way'),
    ('M172', 'CORE:CORE_DEC/CORE_DEC.sv', 'dec', "3'b010:  fp_op = FOP_EQ;", "3'b010:  fp_op = FOP_LT;", 'feq decoded as flt'),
    # 2026-10-25: the issue-queue payload and the D$ adapter (Plan/OOC.md 17)
    ('M173', 'OOO_IQPL/OOO_IQPL.sv', 'iqpl', "if (wr_valid[1]) lvt[wr_entry[1]] <= 1'b1;", "if (wr_valid[1]) lvt[wr_entry[1]] <= 1'b0;", 'the LVT never names bank 1'),
    ('M174', 'OOO_IQPL/OOO_IQPL.sv', 'iqpl', 'rr_data[p] = lvt[ra[p]] ? bank1[ra[p]] : bank0[ra[p]];', 'rr_data[p] = lvt[ra[p]] ? bank1[iss_entry[p]] : bank0[iss_entry[p]];', 'read a cycle early'),
    ('M175', 'OOO_IQPL/OOO_IQPL.sv', 'iqpl', 'if (wr_valid[1]) bank1[wr_entry[1]] <= wr_data[1];', 'if (wr_valid[1]) bank1[wr_entry[0]] <= wr_data[1];', 'slot 1 written to the entry of slot 0'),
    ('M176', 'OOO_IQ/OOO_IQ.sv', 'iq', 'disp_entry = fe;', 'disp_entry = {fe[0], fe[1]};', 'payload entries of the two slots swapped'),
    ('M177', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', "!(e_go && q_tag[i] == dc_req_tag) &&", "1'b1 &&", 'the answer of an older request of the entry kept (stale)'),
    ('M178', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', 'dc_fill_data  = f_kept ? fd[f_sel] : d_resp_data;', 'dc_fill_data  = d_resp_data;', 'a kept answer given with the data of the D$ now'),
    ('M179', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', "!(dc_hit && s1_slot == DW'(i));", "1'b1;", 'a load answered in M answered again'),
    ('M180', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', "if (e_go && dc_req_tag == LW'(e))                   pnd[e] <= !d_req_ready;", "if (e_go && dc_req_tag == LW'(e))                   pnd[e] <= 1'b0;", 'a load the D$ did not take is forgotten'),
    ('M181', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', 'assign dc_hit   = s1_e && d_hit_now;', 'assign dc_hit   = d_hit_now;', 'a hit of another request given to the load in M'),
    ('M182', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', ":        {dc_st_addr[PAW-1:3], s_off};", ":        {dc_st_addr[PAW-1:3], 3'b000};", 'stores at the start of their word'),
    ('M183', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', "8'h0f, 8'hf0:               s_size = 2'd2;", "8'h0f:                      s_size = 2'd2;", 'a store to the upper word written as a byte'),
    ('M184', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', "else if (a_want && !(f_take && !f_kept) && a_tag == LW'(e)) fr[e] <= 1'b1;", "else if (a_want && a_tag == LW'(e)) fr[e] <= 1'b1;", 'an answer given now kept to be given again'),
    ('M185', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', 's1_pa   <= d_req_addr;', 's1_pa   <= dc_req_addr;', 'the physical address of the load in E for every request'),
    ('M186', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', "else if (f_take && f_kept && f_sel == LW'(e))      fr[e] <= 1'b0;", "else if (1'b0)                                     fr[e] <= 1'b0;", 'a kept answer given again and again'),
    ('M187', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', "if (e_go && dc_req_tag == LW'(e))                  fr[e] <= 1'b0;", "if (1'b0)                                          fr[e] <= 1'b0;", 'an answer kept for the entry survives its new request'),
    ('M188', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', "s_go  = !dc_req_valid && pnd == '0 && dc_st_valid;", "s_go  = !dc_req_valid && dc_st_valid;", 'a store sent with a pending load'),
    ('M189', 'CACHE:DCACHE/DCACHE.sv', 'dcad', 'assign d_hit_now      = hit && s1_is_load && s1_can_go;', 'assign d_hit_now      = hit && s1_is_load;', 'a hit in a way being filled or evicted answered now'),
    # 2026-10-26: G0b tier 1 (Doc/UARCH.md 6.4)
    ('M190', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "if (s >= (CW + 1)'(NCKPT)) s = s - (CW + 1)'(NCKPT);", "if (s > (CW + 1)'(NCKPT)) s = s - (CW + 1)'(NCKPT);", 'the checkpoint ring wraps at 7, not 6'),
    ('M191', 'OOO_DEC/OOO_DEC.sv', 'dec', 'for (int k = 1; k < 4; k++) cut[k] = cut[k-1] || rare[k];', 'for (int k = 1; k < 4; k++) cut[k] = rare[k];', 'the group goes on past a rare class'),
    ('M192', 'OOO_RARE/OOO_RARE.sv', 'dec', "            5'b01011,                   // AMO\n", '', 'AMO not a rare class'),
    ('M331', 'OOO_RARE/OOO_RARE.sv', 'dec', "            5'b00001,                   // LOAD-FP\n", '', 'FP loads not a rare class'),
    ('M332', 'OOO_RARE/OOO_RARE.sv', 'dec', "            5'b11100:                   // SYSTEM\n", "            5'b11111:\n", 'SYSTEM not a rare class'),
    ('M333', 'OOO_RARE/OOO_RARE.sv', 'dec', "            5'b00011,                   // MISC-MEM\n", '', 'FENCE / FENCE.I / cbo.zero not a rare class'),
    ('M334', 'OOO_RARE/OOO_RARE.sv', 'dec', " || p == 16'h9002;", ';', 'c.ebreak not a rare class'),
    ('M335', 'OOO_RARE/OOO_RARE.sv', 'dec', "rc = ((p[1:0] == 2'b00 || p[1:0] == 2'b10) && p[14:13] == 2'b01)", "rc = (p[1:0] == 2'b00 && p[14:13] == 2'b01)", 'c.fldsp / c.fsdsp not a rare class'),
    ('M336', 'OOO_RARE/OOO_RARE.sv', 'dec', "assign rare = (p[1:0] == 2'b11) ? r32 : rc;", 'assign rare = r32;', 'RVC told by the 32-bit opcodes'),
    ('M337', 'OOO_RARE/OOO_RARE.sv', 'dec', "            5'b10100,                   // OP-FP\n", '', 'OP-FP not a rare class'),
    ('M338', 'OOO_RARE/OOO_RARE.sv', 'dec', "5'b10000, 5'b10001, 5'b10010, 5'b10011,", "5'b10000, 5'b10001, 5'b10010,", 'FNMADD not a rare class'),
    ('M339', 'OOO_DEC/OOO_DEC.sv', 'dec', 'illegal[k] = ill && (S0 || !rare[k]);', 'illegal[k] = S0 && ill;', 'illegal reported in slot 0 only'),
    ('M340', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', 'out_rare[i]  = wr[s[2:0]];', "out_rare[i]  = wr[s[2:0] + 3'd1];", "rare from the parcel after the instruction's first"),
    ('M341', 'OOO_FBUF/OOO_FBUF.sv', 'fbuf', 'OOO_RARE u_rare (.p(w[k]), .rare(wr[k]));', 'OOO_RARE u_rare (.p(w[0]), .rare(wr[k]));', "every window parcel told by the first one's opcode"),
    ('M343', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'else        ub_upd_q <= ub_upd;', "else        ub_upd_q <= 1'b0;", 'the uBTB never trained'),
    ('M344', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', '.upd_valid(ub_upd_q), .upd_pc(ub_upd_pc_q)', '.upd_valid(ub_upd_q), .upd_pc(ub_upd_pc)', "the training at the next cycle's address"),
    ('M345', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', '.upd_valid(ub_upd_q), .upd_pc', '.upd_valid(ub_upd), .upd_pc', 'trained in the cycle of the override with the last one'),
    ('M342', 'OOO_RARE/OOO_RARE.sv', 'fbuf', "            5'b01011,                   // AMO\n", '', 'AMO not a rare class (seen by the fetch buffer)'),
    ('M193', 'OOO_DEC/OOO_DEC.sv', 'dec', "assign mem_cmd[k]      = S0 ? l_mem_cmd : {4'd0, is_store};", "assign mem_cmd[k]      = S0 ? l_mem_cmd : {4'd0, is_load};", 'slots 1 to 3: loads as stores'),
    ('M194', 'OOO_IQPL/OOO_IQPL.sv', 'iqpl', 'rr_data[2][W2-1:0] = lvt[ra[2]] ? bank1[ra[2]][W2-1:0] : bank0[ra[2]][W2-1:0];', 'rr_data[2][W2-1:0] = bank0[ra[2]][W2-1:0];', 'port 2 without the live value table'),
    # 2026-10-26: D-12, replay after commit in place of the selective replay (Doc/UARCH.md 6.5;
    # M132 to M152, written for the selective replay, went with it)
    ('M195', 'OOO_ROB/OOO_ROB.sv', 'rob', "c1 = c0 && !rp[hi0] && used", "c1 = c0 && used", 'a µop younger than a replay commits with it'),
    ('M196', 'OOO_ROB/OOO_ROB.sv', 'rob', "replay_pc  = (c0 && rp[hi0]) ? p0[PW-1 -: VA-1] + (VA - 1)'(p0[FTQW+2:FTQW])", "replay_pc  = (c0 && rp[hi0]) ? p0[PW-1 -: VA-1]", 'fetched again from the load itself'),
    ('M197', 'OOO_ROB/OOO_ROB.sv', 'rob', 'restore = (r0 || r1) && !trap && !irq && !replay;', 'restore = (r0 || r1) && !trap && !irq;', 'a restore in the cycle of a replay'),
    ('M198', 'OOO_ROB/OOO_ROB.sv', 'rob', "if (cmp_rp[c])  rp[i] <= 1'b1;", "if (1'b0)  rp[i] <= 1'b1;", 'the replay mark lost'),
    ('M199', 'OOO_ROB/OOO_ROB.sv', 'rob', "rp[i]    <= 1'b0;", 'rp[i]    <= rp[i];', 'the replay mark of the last owner of an entry kept'),
    ('M200', 'OOO_ROB/OOO_ROB.sv', 'rob', 'tail_n = head_n;                   // empty after the commits', 'tail_n = tail;', 'the ROB not emptied by a replay'),
    ('M201', 'OOO_LSU/OOO_LSU.sv', 'lsu', "if (ld_cancel && m_lq == LW'(e)) lcan[e] <= 1'b1;", "if (1'b0) lcan[e] <= 1'b1;", 'a cancelled load completes without the mark'),
    ('M202', 'OOO_LSU/OOO_LSU.sv', 'lsu', "lcan[e]   <= 1'b0;", 'lcan[e]   <= lcan[e];', 'the mark of the last owner of an LQ entry kept'),
    # 2026-10-26: D-14, fusion level 2 (Doc/UARCH.md 6.7; M3, M6, M29, M157, M158 went with ALU + ALU)
    ('M203', 'OOO_ALU2/OOO_ALU2.sv', 'alu2', "            2'd1:    o = s2;", "            2'd1:    o = s1;", 'a fused branch compares with s1 for s2'),
    ('M204', 'OOO_ALU2/OOO_ALU2.sv', 'alu2', "            2'd2:    o = 64'd0;", "            2'd2:    o = s2;", 'beqz after an operation compares with s2'),
    ('M205', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', 'parameter int LEVEL = 2,', 'parameter int LEVEL = 1,', 'ALU + branch not fused'),
    # 2026-10-27: L7, asymmetric ALUs (Doc/UARCH.md 6.12)
    ('M206', 'OOO_DEC/OOO_DEC.sv', 'dec', "simple = (alu_op[k] == ALU_ADD && !a_uw[k] && a_shift[k] == 2'd0) || alu_op[k] == ALU_SUB ||", "simple = (alu_op[k] == ALU_ADD) || alu_op[k] == ALU_SUB ||", 'sh*add / add.uw sent to ALU1'),
    ('M207', 'OOO_DEC/OOO_DEC.sv', 'dec', 'alu_op[k] == ALU_SLT || alu_op[k] == ALU_SLTU || alu_op[k] == ALU_XOR ||', 'alu_op[k] == ALU_SLTU || alu_op[k] == ALU_XOR ||', 'slt kept off ALU1'),
    ('M208', 'OOO_FUSE/OOO_FUSE.sv', 'fuse', "else if (a == 2'd1 || b == 2'd1) return 2'd1;", "else if (a == 2'd1) return 2'd1;", 'a pair with an ALU0-only second half on any ALU'),
    ('M209', 'OOO_IQ/OOO_IQ.sv', 'iq', "g0[i] = req0[i] && !g1[i] && (((req0 & ~g1) & older[i]) == '0);", "g0[i] = req0[i] && !g1[i] && ((req0 & older[i]) == '0);", "port 0 held by an older µop port 1 took"),
    ('M210', 'OOO_IQ/OOO_IQ.sv', 'iq', "g0[i] = req0[i] && !g1[i] && (((req0 & ~g1) & older[i]) == '0);", "g0[i] = req0[i] && (((req0 & ~g1) & older[i]) == '0);", 'port 0 issues what port 1 took'),
    ('M211', 'OOO_ALU/OOO_ALU.sv', 'alu1', "ALU_SLT:   r_ext = {63'd0, lt_s};", "ALU_SLT:   r_ext = {63'd0, FULL && lt_s};", 'ALU1 without slt'),
    ('M212', 'OOO_ALU/OOO_ALU.sv', 'alu1', "ALU_AND:            r_log = op_a & lb;", "ALU_AND:            r_log = FULL ? op_a & lb : 64'd0;", 'ALU1 without and'),
    # 2026-10-27: the control, first part (Plan/OOC.md 18), and the issue queue's branch masks
    ('M213', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', "for (int k = 0; k < 2; k++) ck_ok[k] = !r_ckpt[k] || !live[r_ckpt_id[k]];", "for (int k = 0; k < 2; k++) ck_ok[k] = 1'b1;", 'a live checkpoint id given out again'),
    ('M214', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', "if (restore && live[j] && (ck_bm[j] & kill) != '0) killset[j] = 1'b1;", "if (1'b0) killset[j] = 1'b1;", 'checkpoints younger than a restored one stay live'),
    ('M215', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', 'clr = clr & ~killset;', 'clr = clr;', 'a branch killed in the cycle it resolves clears its id'),
    ('M216', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', "for (int k = 0; k < 2; k++) d_bmask[k] = ds_bm[k] & ~clr;", "for (int k = 0; k < 2; k++) d_bmask[k] = ds_bm[k];", 'a mask dispatched with a bit cleared in that cycle'),
    ('M217', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', "ds_bm[1] <= lv_c | ((r_go[0] && r_ckpt[0]) ? bit_of(r_ckpt_id[0]) : '0);", "ds_bm[1] <= lv_c;", "slot 1's mask without slot 0's checkpoint"),
    ('M218', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', 'd_ok = !rcv && rob_avail >= nall && iq_avail >= nall && lq_avail >= nld && sq_avail >= nst;', 'd_ok = !rcv && rob_avail >= nall && iq_avail >= nall && lq_avail >= nld;', 'dispatch without room in the SQ'),
    ('M219', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', 'ds_free = ds_v == 2\'b00 || d_go == ds_v;', 'ds_free = ds_v == 2\'b00;', 'renaming waits a cycle after every dispatch'),
    ('M220', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', 'if (d_go[k] && ds_ck[k]) begin', 'if (d_go[k]) begin', 'the table written by µops without a checkpoint'),
    ('M221', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', 'else if (replay)                                            fe_pc = replay_pc;', 'else if (1\'b0)                                             fe_pc = replay_pc;', 'a replay fetches from the branch target'),
    ('M222', 'OOO_IQ/OOO_IQ.sv', 'iq', "if (issued[i] || (bq & kill) != '0) vq <= 1'b0;", "if (issued[i]) vq <= 1'b0;", 'killed µops stay in the queue'),
    ('M223', 'OOO_IQ/OOO_IQ.sv', 'iq', 'bq <= bq & ~clr;', 'bq <= bq;', 'resolved bits stay in the masks'),
    # 2026-10-27: the control, second part (Plan/OOC.md 19)
    ('M224', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', 'ns_ok   <= head_ns && !ns_busy_n && !fe_flush && !flush_q;', 'ns_ok   <= head_ns && !fe_flush && !flush_q;', 'a second non-speculative µop issued at the same head'),
    ('M225', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', "ns_busy_n = (fe_flush || flush_q || cmt_valid[0]) ? 1'b0 : (ns_busy || iss_ns);", "ns_busy_n = (fe_flush || flush_q) ? 1'b0 : (ns_busy || iss_ns);", 'the next head never gets ns_ok'),
    ('M226', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', 'flush_all  = flush_q;', 'flush_all  = fe_flush;', 'the back end flushed in the cycle of the replay'),
    ('M227', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', "if (cmt_valid != 2'b00) tgt = (cmt_valid[1] ? cmt_ftq[1] : cmt_ftq[0]) + FTQW'(replay);", "if (cmt_valid != 2'b00) tgt = (cmt_valid[1] ? cmt_ftq[1] : cmt_ftq[0]);", "the replayed load's block not popped"),
    ('M228', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', "ftq_tgt <= fe_flush ? ftq_hd + FTQW'(ftq_pop) : tgt;", 'ftq_tgt <= tgt;', 'blocks of a flushed FTQ still popped'),
    ('M330', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', "ftq_pop = (ndone != '0) ? 2'd1 : 2'd0;", "ftq_pop = (ndone >= FTQW'(2)) ? 2'd2 : 2'(ndone);", 'two FTQ pops a cycle (TAGE takes one update)'),
    ('M229', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', 'free_valid[k] = cmt_valid[k] && cmt_wr[k];', 'free_valid[k] = cmt_valid[k];', 'a mapping freed for a µop that writes none'),
    ('M230', 'OOO_IQ/OOO_IQ.sv', 'iq', "(!ns[i] || (ns_ok && (older[i] & v & ns) == '0));", '(!ns[i] || ns_ok);', 'a younger non-speculative µop issued first'),
    ('M231', 'OOO_IQ/OOO_IQ.sv', 'iq', "assign iss_ns      = ((g0 | g1 | g2) & ns) != '0;", "assign iss_ns      = ((g0 | g1) & ns) != '0;", 'a non-speculative LSU µop not reported'),
    ('M232', 'OOO_ROB/OOO_ROB.sv', 'rob', 'cmt_ftq[u]  = p[FTQW-1:0];', 'cmt_ftq[u]  = p[FTQW:1];', 'the fetch block read a bit off'),
    # 2026-10-28: the units dropping by mask, the DS register's payload, wakeups for the busy bits (Plan/OOC.md 20)
    ('M233', 'OOO_LSU/OOO_LSU.sv', 'lsu', "e_iss   = iss_valid && (iss_bm & kill) == '0 && !flush_all;", 'e_iss   = iss_valid && !flush_all;', 'a killed µop not dropped in E'),
    ('M234', 'OOO_LSU/OOO_LSU.sv', 'lsu', "m_rec     = flush_all || (m_retry ? restore : (m_bm & kill) != '0);", "m_rec     = flush_all || (m_retry ? restore : 1'b0);", 'a killed load in M completes'),
    ('M235', 'OOO_LSU/OOO_LSU.sv', 'lsu', "m_bm    <= e_retry ? '0 : iss_bm;", "m_bm    <= '0;", 'the mask not taken into M'),
    ('M236', 'OOO_LSU/OOO_LSU.sv', 'lsu', 'e_st_w  = e_iss && !iss_ld && sv[iss_sq];', 'e_st_w  = iss_valid && !iss_ld && sv[iss_sq];', 'a killed store writes its entry and completes'),
    ('M237', 'OOO_LSU/OOO_LSU.sv', 'lsu', "m_rec     = flush_all || (m_retry ? restore : (m_bm & kill) != '0);", "m_rec     = flush_all || (m_bm & kill) != '0;", 'a retried load completes in a restore'),
    ('M240', 'OOO_IQ/OOO_IQ.sv', 'iq', "d_v2 <= iss_wr[2] && !flush && (iss_bm[2] & kill) == '0;", 'd_v2 <= iss_wr[2] && !flush;', 'a load killed as it issues still wakes'),
    ('M241', 'OOO_IQ/OOO_IQ.sv', 'iq', "d_v0 <= iss_wr[0] && lat2_0 && !flush && (iss_bm[0] & kill) == '0;", "d_v0 <= iss_wr[0] && lat2_0 && (iss_bm[0] & kill) == '0;", 'a multiply flushed as it issues still wakes'),
    ('M242', 'OOO_IQ/OOO_IQ.sv', 'iq', 'assign wk_tag   = bt;', 'assign wk_tag   = {bt[4], bt[5], bt[3], bt[2], bt[1], bt[0]};', 'the external wakeup tags swapped'),
    ('M243', 'OOO_RENAME/OOO_RENAME.sv', 'rename', "for (int w = 0; w < NWK; w++) if (wk_valid[w]) busy[wk_tag[w]] <= 1'b0;", "for (int w = 0; w < 3; w++) if (wk_valid[w]) busy[wk_tag[w]] <= 1'b0;", 'three of the six wakeup buses clear busy'),
    ('M244', 'OOO_DSREG/OOO_DSREG.sv', 'dsreg', 'ds_rdy[k][s] = rq[k][s] || woken_q(ds_src[k][s]);', 'ds_rdy[k][s] = rq[k][s];', 'wakeups between renaming and dispatch missed'),
    ('M245', 'OOO_DSREG/OOO_DSREG.sv', 'dsreg', 'rq      <= ds_rdy;', 'rq      <= rq;', 'a wakeup seen once and forgotten'),
    ('M246', 'OOO_DSREG/OOO_DSREG.sv', 'dsreg', "for (int b = 0; b < NB; b++) if (wq_v[b] && wq_t[b] == t) w = 1'b1;", "for (int b = 0; b < NB - 1; b++) if (wq_v[b] && wq_t[b] == t) w = 1'b1;", 'the last wakeup bus not snooped'),
    ('M247', 'OOO_DSREG/OOO_DSREG.sv', 'dsreg', 'rq      <= in_rdy;', "rq      <= '0;", "renaming's ready bits dropped"),
    ('M248', 'OOO_STAGE/OOO_STAGE.sv', 'stage', "else if (en)                    out_valid <= in_valid && (in_bm & kill) == '0;", 'else if (en)                    out_valid <= in_valid;', 'a µop killed as it is taken kept'),
    ('M249', 'OOO_STAGE/OOO_STAGE.sv', 'stage', "else if ((out_bm & kill) != '0) out_valid <= 1'b0;", "else if (1'b0) out_valid <= 1'b0;", 'a held µop never killed'),
    ('M250', 'OOO_STAGE/OOO_STAGE.sv', 'stage', 'out_bm   <= in_bm & ~clr;', 'out_bm   <= in_bm;', "a mask taken in keeps that cycle's clears"),
    ('M251', 'OOO_STAGE/OOO_STAGE.sv', 'stage', 'out_bm   <= out_bm & ~clr;', 'out_bm   <= out_bm;', 'a held mask keeps its clears'),
    ('M252', 'OOO_STAGE/OOO_STAGE.sv', 'stage', "else if (flush)                 out_valid <= 1'b0;", "else if (1'b0)                  out_valid <= 1'b0;", 'a flush keeps the µop'),
    ('M253', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', 'ds_load = ds_free;', "ds_load = ds_v == 2'b00;", 'the payload not loaded as its µops leave'),
    # 2026-10-28: the front end's restore (Plan/OOC.md 21)
    ('M254', 'OOO_FERS/OOO_FERS.sv', 'fers', 'q_ftq  <= fe_flush ? rcv_ftq : restore_ftq;', 'q_ftq  <= restore_ftq;', "a trap reads the checkpoint's block"),
    ('M255', 'OOO_FERS/OOO_FERS.sv', 'fers', 'q_e    <= fe_flush ? rcv_end : br_e[restore_port];', 'q_e    <= fe_flush ? rcv_end : br_e[0];', 'the point always from port 0'),
    ('M256', 'OOO_FERS/OOO_FERS.sv', 'fers', "if (ft_sv[s] && ft_par[s] < q_e)          n = 2'(s + 1);", "if (ft_sv[s] && ft_par[s] <= q_e)         n = 2'(s + 1);", "a trap at a branch counts the branch's slot"),
    ('M257', 'OOO_FERS/OOO_FERS.sv', 'fers', "if (ft_sv[s] && ft_par[s] == q_e && q_rs) begin be_hist_bits[s] = q_tk; n = 2'(s + 1); end", "if (ft_sv[s] && ft_par[s] == q_e && q_rs) begin be_hist_bits[s] = 1'b1; n = 2'(s + 1); end", 'the mispredicted branch restored as taken'),
    ('M258', 'OOO_FERS/OOO_FERS.sv', 'fers', 'ft_par[s] == q_e && q_rs)', 'ft_par[s] == q_e)', "a trap at a branch takes the branch's outcome"),
    ('M259', 'OOO_FERS/OOO_FERS.sv', 'fers', "be_ras_addr = {ft_line, q_e} + (VA - 1)'(1);", 'be_ras_addr = {ft_line, q_e};', 'a call pushes its own address'),
    ('M260', 'OOO_FERS/OOO_FERS.sv', 'fers', 'q_call <= !fe_flush && br_call[restore_port];', 'q_call <= br_call[restore_port];', "a trap pushes the port's call"),
    ('M261', 'OOO_FERS/OOO_FERS.sv', 'fers', 'else        be_redirect <= fe_redirect;', 'else        be_redirect <= fe_redirect && !fe_flush;', 'a trap or a replay never restarts fetch'),
    ('M262', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', "assign ic_req_valid = !stop && {1'b0, credit} > {2'b0, nlive};", "assign ic_req_valid = !be_redirect && {1'b0, credit} > {2'b0, nlive};", 'a request in the cycle of a stop'),
    ('M263', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'assign f2  = ic_resp_valid && qlive[qh] && !stop;', 'assign f2  = ic_resp_valid && qlive[qh] && !be_redirect;', 'a block goes out in the cycle of a stop'),
    ('M264', 'OOO_CTRL/OOO_CTRL.sv', 'ctrl', 'restore_port = !(br_valid[0] && br_mispred[0] && br_ckpt[0] == rob_restore_ckpt);', 'restore_port = !(br_valid[0] && br_mispred[0]);', "port 0's misprediction taken for the oldest"),
    ('M265', 'OOO_ROB/OOO_ROB.sv', 'rob', 'pr      = (trap || irq || (c0 && rp[hi0])) ? p0 : p1;', 'pr      = (trap || (c0 && rp[hi0])) ? p0 : p1;', 'an interrupt goes back to head + 1'),
    ('M266', 'OOO_ROB/OOO_ROB.sv', 'rob', "rcv_end = ppc[3:1] + pr[FTQW+2:FTQW] - 3'd1;", 'rcv_end = ppc[3:1];', 'the point at its first parcel'),
    # 2026-10-28: exceptions and interrupts, the system µops (Plan/OOC.md 22)
    ('M267', 'OOO_TRAP/OOO_TRAP.sv', 'trap', 'irq     = irq_pend && head_valid && !ns_busy;', 'irq     = irq_pend && head_valid;', 'an interrupt under an issued non-speculative µop'),
    ('M268', 'OOO_TRAP/OOO_TRAP.sv', 'trap', 'exc     = rob_trap && !irq;', 'exc     = rob_trap;', 'an exception taken with the interrupt'),
    ('M269', 'OOO_TRAP/OOO_TRAP.sv', 'trap', 'refetch = exc && head_fused;', "refetch = 1'b0;", 'an exception in a pair trapped as it is'),
    ('M270', 'CORE:CORE_CSR/CORE_CSR.sv', 'csru', "? {tvec_sel[63:2], 2'b00} + {57'd0, trap_cause, 2'b00}", "? {tvec_sel[63:2], 2'b00} + {58'd0, trap_cause, 1'b0}", 'the vector at 2 x cause'),
    ('M271', 'OOO_TRAP/OOO_TRAP.sv', 'trap', 'rp_pc     = !x_pend ? rob_replay_pc : x_s ? sepc : mepc;', 'rp_pc     = rob_replay_pc;', 'MRET goes to pc + length'),
    ('M272', 'OOO_TRAP/OOO_TRAP.sv', 'trap', "csr_tval  = irq ? 64'd0 : tv_d;", 'csr_tval  = tv_d;', 'an interrupt with a tval'),
    ('M273', 'OOO_TRAP/OOO_TRAP.sv', 'trap', 'if (tv_valid[k] && !flush_all &&', 'if (tv_valid[k] &&', 'a flushed report kept'),
    ('M274', 'OOO_TRAP/OOO_TRAP.sv', 'trap', '!(restore && rdist(tv_rob[k], head_rob) > rdist(restore_rob, head_rob)) &&', "1'b1 &&", 'a killed report kept'),
    ('M275', 'OOO_TRAP/OOO_TRAP.sv', 'trap', "else if (restore && v && rdist(r, head_rob) > rdist(restore_rob, head_rob)) v = 1'b0;", "else if (1'b0) v = 1'b0;", "a killed µop's tval kept"),
    ('M276', 'OOO_TRAP/OOO_TRAP.sv', 'trap', '(!v || rdist(tv_rob[k], head_rob) <= rdist(r, head_rob))) begin', "1'b1) begin", 'the latest tval, not the oldest'),
    ('M277', 'OOO_TRAP/OOO_TRAP.sv', 'trap', "if (3'(nf_cnt) + cmt_instret >= 3'd2) no_fuse <= 1'b0;", "if (3'(nf_cnt) + cmt_instret >= 3'd1) no_fuse <= 1'b0;", 'fusion back after one instruction'),
    ('M278', 'OOO_TRAP/OOO_TRAP.sv', 'trap', 'end else if (take) begin', "end else if (1'b0) begin", 'no_fuse kept through a trap'),
    ('M279', 'OOO_TRAP/OOO_TRAP.sv', 'trap', 'csr_mret  = rob_replay && x_pend && !x_s;', 'csr_mret  = x_pend && !x_s;', 'mstatus updated before the MRET commits'),
    ('M280', 'OOO_SYS/OOO_SYS.sv', 'sys', 'S_SQ:    if (sq_drained) st <=', "S_SQ:    if (1'b1) st <=", 'a fence without the stores drained'),
    ('M281', 'OOO_SYS/OOO_SYS.sv', 'sys', 'S_DWAIT: if (fl_done)    st <= S_IFL;', "S_DWAIT: if (1'b1)       st <= S_IFL;", 'the I$ invalidated before the FLUSH ends'),
    ('M282', 'OOO_SYS/OOO_SYS.sv', 'sys', 'S_IFL:   if (ic_done)    st <= S_DONE;', "S_IFL:   if (1'b1)       st <= S_DONE;", 'FENCE.I completes before the I$'),
    ('M283', 'OOO_SYS/OOO_SYS.sv', 'sys', 'S_WFI:   if (wfi_wake)   st <= S_DONE;', "S_WFI:   if (1'b1)       st <= S_DONE;", 'WFI does not wait'),
    ('M284', 'OOO_SYS/OOO_SYS.sv', 'sys', 'rp      <= !ill && (sys_op == OP_FENCEI || sys_op == OP_SFENCE || sys_op == OP_MRET || sys_op == OP_SRET);', 'rp      <= !ill && (sys_op == OP_FENCEI || sys_op == OP_MRET || sys_op == OP_SRET);', 'SFENCE.VMA without the refetch'),
    ('M285', 'OOO_SYS/OOO_SYS.sv', 'sys', 'tlb_flush = st == S_SQ && op == OP_SFENCE && sq_drained;', 'tlb_flush = st == S_SQ && op == OP_SFENCE;', 'the TLBs flushed before the stores drain'),
    ('M286', 'OOO_SYS/OOO_SYS.sv', 'sys', "S_SQ:    if (sq_drained) st <= (op == OP_FENCEI) ? S_DFL : S_DONE;", "S_SQ:    if (sq_drained) st <= (op == OP_FENCEI) ? S_IFL : S_DONE;", 'FENCE.I without the D$ FLUSH'),
    ('M287', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', 'd_req_cmd    = s_go ? CMD_STORE : f_go ? CMD_FLUSH : CMD_LOAD;', 'd_req_cmd    = s_go ? CMD_STORE : CMD_LOAD;', 'the FLUSH sent as a load'),
    ('M288', 'OOO_DCAD/OOO_DCAD.sv', 'dcad', 'fl_done      = d_resp_valid && q_fl[q_head];', 'fl_done      = fl_take;', 'the FLUSH done when it is taken'),
    ('M290', 'OOO_ROB/OOO_ROB.sv', 'rob', "c0 = used != '0 && done[hi0] && !exc[hi0] && !irq;", "c0 = used != '0 && done[hi0] && !exc[hi0];", 'the head commits under the interrupt'),
    ('M291', 'OOO_ROB/OOO_ROB.sv', 'rob', '        if (trap || irq) begin', '        if (trap) begin', 'the ROB not emptied by an interrupt'),
    ('M292', 'OOO_ROB/OOO_ROB.sv', 'rob', 'head_fused = p0[FTQW+4];', 'head_fused = p0[FTQW+3];', 'the non-speculative bit read as fused'),
    ('M293', 'OOO_LSU/OOO_LSU.sv', 'lsu', 'sq_drained  = sq_head == sq_cmt;', 'sq_drained  = sq_head == sq_tail;', 'drained only with no store at all'),
    ('M294', 'OOO_ROB/OOO_ROB.sv', 'rob', 'restore = (r0 || r1) && !trap && !irq && !replay;', 'restore = (r0 || r1) && !trap && !replay;', 'a restore in the cycle of an interrupt'),
    ('M295', 'OOO_ROB/OOO_ROB.sv', 'rob', 'pr      = (trap || irq || (c0 && rp[hi0])) ? p0 : p1;', 'pr      = p0;', 'a replay of head + 1 goes back to the head'),
    # 2026-10-28: CORE_CSR and CORE_MDU behind port 0 (Plan/OOC.md 23)
    ('M296', 'OOO_CSRU/OOO_CSRU.sv', 'csru', "wants_write = ex_op[1:0] == 2'b01 || ex_rs1 != 5'd0;", "wants_write = 1'b1;", 'csrrs / csrrc with x0 write'),
    ('M297', 'OOO_CSRU/OOO_CSRU.sv', 'csru', 'ill         = !ex_exists || ex_denied || (wants_write && ex_readonly);', 'ill         = !ex_exists || ex_denied || ex_readonly;', 'reading a read-only CSR is illegal'),
    ('M298', 'OOO_CSRU/OOO_CSRU.sv', 'csru', '2\'b11:   wdata = rmw_data & ~src;', '2\'b11:   wdata = rmw_data & src;', 'csrrc keeps the bits it should clear'),
    ('M299', 'OOO_CSRU/OOO_CSRU.sv', 'csru', "src         = ex_op[2] ? {59'd0, ex_rs1} : ex_src;", 'src         = ex_src;', 'the immediate forms take the register'),
    ('M300', 'OOO_CSRU/OOO_CSRU.sv', 'csru', ".trap_epc({{(65 - VA){trap_epc[VA-1]}}, trap_epc[VA-2:1], 1'b0})", ".trap_epc({{(65 - VA){1'b0}}, trap_epc[VA-2:1], 1'b0})", 'mepc not sign extended'),
    ('M301', 'CORE:CORE_CSR/CORE_CSR.sv', 'csru', "minstret <= minstret + 64'(instret_inc);", "minstret <= minstret + 64'd1;", 'minstret counts one a cycle'),
    ('M302', 'OOO_CSRU/OOO_CSRU.sv', 'csru', 'ex_rp    = wants_write && !ill;', 'ex_rp    = wants_write;', 'an illegal CSR write marked for replay'),
    ('M303', 'OOO_CSRU/OOO_CSRU.sv', 'csru', 'parameter int          HPM_COUNTERS = 2,', 'parameter int          HPM_COUNTERS = 4,', 'L1 not applied'),
    ('M305', 'OOO_TRAP/OOO_TRAP.sv', 'trap', 'rp_pc     = !x_pend ? rob_replay_pc : x_s ? sepc : mepc;', 'rp_pc     = !x_pend ? rob_replay_pc : mepc;', 'SRET goes to mepc'),
    ('M306', 'OOO_TRAP/OOO_TRAP.sv', 'trap', 'csr_sret  = rob_replay && x_pend && x_s;', "csr_sret  = 1'b0;", 'SRET does not tell the CSRs'),
    ('M307', 'OOO_SYS/OOO_SYS.sv', 'sys', 'OP_MRET:   ill = priv != PRIV_M;', "OP_MRET:   ill = 1'b0;", 'MRET below M'),
    ('M308', 'OOO_SYS/OOO_SYS.sv', 'sys', 'OP_SRET:   ill = priv == PRIV_U || (priv == PRIV_S && tsr);', 'OP_SRET:   ill = priv == PRIV_U;', 'SRET under TSR'),
    ('M309', 'OOO_SYS/OOO_SYS.sv', 'sys', 'OP_SFENCE: ill = priv == PRIV_U || (priv == PRIV_S && tvm);', 'OP_SFENCE: ill = priv == PRIV_U;', 'SFENCE.VMA under TVM'),
    ('M310', 'OOO_SYS/OOO_SYS.sv', 'sys', 'OP_WFI:    ill = priv != PRIV_M && tw;', "OP_WFI:    ill = 1'b0;", 'WFI under TW'),
    ('M311', 'OOO_SYS/OOO_SYS.sv', 'sys', 'tv_valid  = sys_valid && st == S_IDLE && ill;', "tv_valid  = 1'b0;", 'an illegal system µop without its tval'),
    ('M312', 'OOO_IQ/OOO_IQ.sv', 'iq', '!(blk0 && wr[i] && !lat2[i] && !md[i]) && !(md[i] && !mdu_ok);', '!(md[i] && !mdu_ok);', "port 0's write slot taken twice"),
    ('M313', 'OOO_IQ/OOO_IQ.sv', 'iq', '!(blk0 && wr[i] && !lat2[i] && !md[i]) && !(md[i] && !mdu_ok);', '!(blk0 && wr[i] && !lat2[i] && !md[i]);', 'an MDU µop without mdu_ok'),
    ('M314', 'OOO_IQ/OOO_IQ.sv', 'iq', 'assign blk0 = d_v0 || p0_hold;', 'assign blk0 = d_v0;', 'p0_hold ignored'),
    ('M315', 'OOO_IQ/OOO_IQ.sv', 'iq', "assign iss_md      = (g0 & md) != '0;", "assign iss_md      = (g1 & md) != '0;", 'an MDU µop on port 0 not reported'),
    ('M316', 'OOO_MDUP/OOO_MDUP.sv', 'mdup', 'mdu_ok  <= !lb;', "mdu_ok  <= 1'b1;", 'two MDU µops at once'),
    ('M317', 'OOO_MDUP/OOO_MDUP.sv', 'mdup', 'ack       = h_v && done && !h_kill && !slot_busy;', 'ack       = h_v && done && !h_kill;', "a result written in a busy slot"),
    ('M318', 'OOO_MDUP/OOO_MDUP.sv', 'mdup', 'p0_hold <= h_v && done && !ack && !h_kill;', "p0_hold <= 1'b0;", 'a result can wait for ever'),
    ('M319', 'OOO_MDUP/OOO_MDUP.sv', 'mdup', "else if (lb_v && ((lb_bm & kill) != '0 || ack))         lb = 1'b0;", "else if (lb_v && ack)         lb = 1'b0;", 'a killed one blocks the MDU'),
    ('M320', 'OOO_PMUL/OOO_PMUL.sv', 'pmul', 'p_lh  <= ex_a[31:0]  * ex_b[63:32];', 'p_lh  <= ex_a[31:0]  * ex_b[31:0];', 'a cross product of the wrong halves'),
    ('M321', 'OOO_MDUP/OOO_MDUP.sv', 'mdup', "start     = ex_valid && !flush && (ex_bm & kill) == '0;", 'start     = ex_valid && !flush;', 'a killed µop starts'),
    ('M322', 'OOO_MDUP/OOO_MDUP.sv', 'mdup', "h_kill    = h_v && (flush || (h_bm & kill) != '0);", 'h_kill    = h_v && flush;', 'a held µop never killed'),
    ('M323', 'OOO_MDUP/OOO_MDUP.sv', 'mdup', 'h_bm   <= h_bm & ~clr;', 'h_bm   <= h_bm;', 'a held mask keeps its clears'),
    ('M324', 'OOO_DEC/OOO_DEC.sv', 'dec', "lat2[k]    = !ill && ((is_mdu && mdu_op[k] == 4'd0) || ld);", 'lat2[k]    = !ill && (is_mdu || ld);', 'mulh woken at latency 2'),
    # 2026-10-28: the pipelined mul / mulw beside CORE_MDU (D-16 variant A, Plan/OOC.md 24)
    ('M325', 'OOO_PMUL/OOO_PMUL.sv', 'pmul', "s         = p_ll + {p_lh + p_hl, 32'd0};", "s         = p_ll + {p_lh, 32'd0};", 'a cross product left out'),
    ('M326', 'OOO_PMUL/OOO_PMUL.sv', 'pmul', "res_data  = m_w ? {{32{s[31]}}, s[31:0]} : s;", "res_data  = m_w ? {32'd0, s[31:0]} : s;", 'mulw not sign extended'),
    ('M327', 'OOO_PMUL/OOO_PMUL.sv', 'pmul', "else        m_v <= ex_valid && !flush && (ex_bm & kill) == '0;", 'else        m_v <= ex_valid && !flush;', 'a mul killed in EX taken'),
    ('M328', 'OOO_PMUL/OOO_PMUL.sv', 'pmul', "res_valid = m_v && !flush && (m_bm & kill) == '0;", 'res_valid = m_v && !flush;', 'a mul killed in its second cycle written'),
    ('M329', 'OOO_PMUL/OOO_PMUL.sv', 'pmul', "res_valid = m_v && !flush && (m_bm & kill) == '0;", "res_valid = m_v && (m_bm & kill) == '0;", 'a flushed mul written'),
    ('M81', 'OOO_FTQ/OOO_FTQ.sv', 'ftq', "assign push_ready = used != (FTQW + 1)'(NFTQ);", "assign push_ready = 1'b1;", 'a full FTQ takes a block'),
    ('M82', 'OOO_FTQ/OOO_FTQ.sv', 'ftq', "{(restore_idx >= head[FTQW-1:0]) ? head[FTQW] : ~head[FTQW], restore_idx}", "{head[FTQW], restore_idx}", 'restored tail with the wrong lap'),
    ('M83', 'OOO_FTQ/OOO_FTQ.sv', 'ftq', 'if (flush_all)    tail <= h;', 'if (flush_all)    tail <= head;', 'flush_all without the pops of that cycle'),
    ('M84', 'OOO_FTQ/OOO_FTQ.sv', 'ftq', 'rd_pc[r] = e[EW-1 -: VA-1];', 'rd_pc[r] = e[EW-2 -: VA-1];', 'decode reads the pc a bit off'),
    ('M85', 'OOO_FTQ/OOO_FTQ.sv', 'ftq', "h = head + (FTQW + 1)'(pop);", "h = head + (FTQW + 1)'(pop[0]);", 'only one block popped a cycle'),
]


def run(m):
    mid, f, test, old, new, what = m
    work = os.path.join(HERE, 'obj_dir', 'mutate', mid)
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(RTL, os.path.join(work, 'rtl'))
    shutil.copytree(CORE, os.path.join(work, 'core'))
    shutil.copytree(CACHE, os.path.join(work, 'cache'))
    if f.startswith('CORE:'):    path = os.path.join(work, 'core', f[5:])
    elif f.startswith('CACHE:'): path = os.path.join(work, 'cache', f[6:])
    else:                        path = os.path.join(work, 'rtl', f)
    src = open(path).read()
    if src.count(old) != 1:
        return mid, 'NOT APPLIED', what, f'found {src.count(old)} times'
    open(path, 'w').write(src.replace(old, new))
    env = dict(os.environ, OOO_RTL=os.path.join(work, 'rtl'), CORE_RTL=os.path.join(work, 'core'), CACHE_RTL=os.path.join(work, 'cache'), OOO_OBJ=os.path.join(work, 'obj'))
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
