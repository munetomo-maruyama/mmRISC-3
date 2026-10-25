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
    ('M128', 'OOO_FETCH/OOO_FETCH.sv', 'fetch', 'assign f2  = ic_resp_valid && qlive[qh] && !be_redirect;', 'assign f2  = ic_resp_valid && qlive[qh];', 'a block out in a redirect cycle'),
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
