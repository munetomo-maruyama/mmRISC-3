#!/usr/bin/env python3
#---------------------------------------------------------------------------
# mutate.py : bug injection for the L2 (RTL/CPU/CACHE/CPU_L2) and the memory
# bus's arbiter (RTL/CPU/OOO/OOO_MARB), step 1.7 H2, Plan/OOC.md 29.57
#
#   ./mutate.py [L1 L5 ...]       default: all, 4 at a time
#
# Each mutation is one literal change of one line, made in copies of
# RTL/CPU/CACHE and RTL/CPU/OOO under obj_dir/mutate/<id>; run.sh's 'small'
# configuration (8 KB, 4 ways: evictions all the time) runs on the copies and
# must FAIL. L1 to L31 are mmRISC-2's SIM/SIM_L2/bug_inject.sh (L16 to L18
# rewritten: a part write that hits is now kept in the L2). Each line of the
# report is DETECTED, NOT DETECTED, or NOT APPLIED (it does not build, or the
# text was not found exactly once), and every line has to be read.
#---------------------------------------------------------------------------
import concurrent.futures
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.abspath(os.path.join(HERE, '..', '..', 'RTL', 'CPU', 'CACHE'))
OOO = os.path.abspath(os.path.join(HERE, '..', '..', 'RTL', 'CPU', 'OOO'))
L2 = 'L2:CPU_L2/CPU_L2.sv'
AR = 'OOO:OOO_MARB/OOO_MARB.sv'
DA = 'L2:CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv'

M = [
    # id, file, old, new, what it breaks
    ('L1', L2, "assign cmp_vdirty = t_rd_valid[vic_way] && t_rd_dirty[vic_way];", "assign cmp_vdirty = 1'b0;", 'a dirty victim is dropped, not written out'),
    ('L2', L2, "t_wr_way_en[hit_way] = 1'b1;", ";", 'a write that hits does not make the line dirty'),
    ('L3', L2, "t_wr_way_en[way] = 1'b1;             // the new line, dirty", "begin t_wr_way_en[way] = 1'b1; t_wr_dirty = 1'b0; end", 'a line write that misses allocates a clean line'),
    ('L4', L2, "t_wr_dirty       = 1'b0;", "t_wr_dirty       = 1'b1;", 'a fill makes the line dirty (clean victims are written out)'),
    ('L5', L2, "assign cmp_need   = !cur_write || !cur_line || cmp_vdirty;", "assign cmp_need   = (cur_write && !cur_line) || cmp_vdirty;", 'a read miss does not wait for the write out in the evict buffer'),
    ('L6', L2, "assign cmp_need   = !cur_write || !cur_line || cmp_vdirty;", "assign cmp_need   = !cur_write || cmp_vdirty;", 'a part write does not wait for the write out in the evict buffer'),
    ('L7', L2, "assign cmp_need   = !cur_write || !cur_line || cmp_vdirty;", "assign cmp_need   = !cur_write || !cur_line;", 'a line write with a dirty victim overwrites a full evict buffer'),
    ('L8', L2, "m_axi4_wdata   = eb_data[dcnt];", "m_axi4_wdata   = eb_data[0];", 'the write out sends word 0 eight times'),
    ('L9', L2, "eb_addr  <= {vic_tag, cur_idx", "eb_addr  <= {cur_tag, cur_idx", 'the write out goes to the address of the new line'),
    ('L10', L2, "t_wr_way_en = '1;", "t_wr_way_en = '0;", 'the walk after reset does not clear the tags'),
    ('L11', L2, "st        <= M_INIT;", "st        <= M_IDLE;", 'no walk after reset'),
    ('L12', L2, "r[node] = ~dir;", "r[node] = dir;", 'pseudo LRU points at the way just used'),
    ('L13', L2, "iss_now = ((f_cnt + 3'(rd_pend)) < 3'(FIFO_D));", "iss_now = 1'b1;", 'a read hit streams into a full R FIFO'),
    ('L14', L2, "(st == M_FILL) && (f_cnt < 3'(FIFO_D));", "(st == M_FILL);", 'a fill takes beats into a full R FIFO'),
    ('L15', L2, "(f_cnt == 3'd0) && ", "", 'a read is taken while beats of the last one wait'),
    ('L16', L2, "d_wr_addr = {cur_idx, cur_word + wcnt};  // (a part write's words from its own)", "d_wr_addr = {cur_idx, wcnt};", "a part write that hits writes the line's first word"),
    ('L17', L2, "if (cur_write && hit_any)", "if (cur_write && cur_line && hit_any)", 'a part write that hits leaves the line clean (lost when evicted)'),
    ('L18', L2, "d_wr_addr = {cur_idx, cur_word + wcnt};  // (a part write's words from its own)", "d_wr_addr = {cur_idx, cur_word + wcnt}; d_wr_strb = 8'hff;", 'a part write that hits writes every byte of the word'),
    ('L19', L2, "(wcnt >= cur_word) && ", "", 'a fill passes on the beats before the one asked for'),
    ('L20', L2, "f_in_last = (4'(pend_word) == last_beat);", "f_in_last = 1'b0;", 'a read hit has no RLAST'),
    ('L21', L2, "f_in_data = d_rd_data[hit_way*64 +: 64];", "f_in_data = d_rd_data[0 +: 64];", 'the first beat of a hit comes from way 0'),
    ('L22', L2, "if ((dst == D_B) && m_axi4_bvalid) eb_valid <= 1'b0;", "if ((dst == D_AW) && m_axi4_awready) eb_valid <= 1'b0;", 'the evict buffer is free before its write out is done'),
    ('L23', L2, "t_rd_index  = acc_ar ? s_axi4_araddr[OFF_BITS +: IDX_BITS]", "t_rd_index  = acc_ar ? s_axi4_awaddr[OFF_BITS +: IDX_BITS]", 'a read looks up the set of the write address'),
    ('L24', L2, "cur_line  <= acc_aw && (s_axi4_awlen == 8'd7) &&", "cur_line  <= acc_aw && (s_axi4_awlen != 8'd9) &&", 'a part write is taken as a line write'),
    ('L25', L2, "f_id[f_wp]   <= cur_id;", "f_id[f_wp]   <= '0;", 'R carries ID 0'),
    ('L26', L2, "assign ev_miss = (st == M_CMP) && !cur_write && !hit_any;", "assign ev_miss = (st == M_CMP) && !cur_write;", 'the PMU counts every read as a miss'),
    ('L27', L2, "pend_word <= cmp_iss ? cur_word + 3'd1 : iss_word;", "pend_word <= iss_word;", "a hit's second beat is taken for another word"),
    ('L28', L2, "t_wr_valid       = !(fill_err || (m_axi4_rresp != 2'b00));", "t_wr_valid       = 1'b0;", 'a fill leaves the line invalid'),
    ('L29', L2, "if (dcnt == 3'd7) dst <= D_B;", "if (dcnt == 3'd6) dst <= D_B;", 'the write out stops after 7 beats'),
    ('L30', L2, "hit_vec[w] = t_rd_valid[w] && (t_rd_tag[w*TAG_BITS +: TAG_BITS] == cur_tag);", "hit_vec[w] = t_rd_valid[w] && (t_rd_tag[w*TAG_BITS+1 +: TAG_BITS-1] == cur_tag[TAG_BITS-1:1]);", 'the tag compare drops the lowest tag bit'),
    ('L31', L2, "if (!need_buf || !eb_valid) begin", "if (1'b1) begin", 'M_WAIT does not wait for the evict buffer'),
    # the part write that hits (mmRISC-3)
    ('L32', L2, "if (!hit_any) begin", "if (!hit_any || (cur_write && !cur_line)) begin", 'a part write that hits passed through, the line not written'),
    ('L33', L2, "end else if (hit_any) begin\n                        st <= M_WLINE;", "end else if (cur_line && hit_any) begin\n                        st <= M_WLINE;", 'a part write that hits goes nowhere'),
    # OOO_MARB
    ('L34', AR, "else if (i_arvalid && d_arvalid) sel = !last;", "else if (i_arvalid && d_arvalid) sel = last;", 'the port served last goes again'),
    ('L35', AR, "else if (i_arvalid && d_arvalid) sel = !last;", "else if (i_arvalid && d_arvalid) sel = 1'b1;", "the D$'s port always first"),
    ('L36', AR, "if (lock)                       sel = lsel;", "if (1'b0)                       sel = lsel;", 'a waiting AR not held'),
    ('L37', AR, "lsel <= sel;", "lsel <= 1'b0;", "a held AR taken as the I$'s"),
    ('L38', AR, "if (m_arvalid && m_arready) last <= sel;", "last <= sel;", 'the port served last moved without a handshake'),
    ('L39', AR, "assign r_i      = m_rid == IC_ID;", "assign r_i      = 1'b0;", "every R beat to the D$'s port"),
    ('L40', AR, "assign m_rready = r_i ? i_rready : d_rready;", "assign m_rready = d_rready;", "the I$'s R beats taken on the D$'s rready"),
    ('L41', AR, "assign i_arready = !sel && m_arready;", "assign i_arready = m_arready;", "the I$'s AR taken with the D$'s"),
    ('L42', AR, "assign m_araddr  = sel ? d_araddr  : i_araddr;", "assign m_araddr  = sel ? i_araddr  : i_araddr;", "the D$'s AR with the I$'s address"),
    ('L43', AR, "assign m_arid    = sel ? d_arid    : i_arid;", "assign m_arid    = sel ? d_arid    : d_arid;", "the I$'s AR with the D$'s ID"),
    ('L44', AR, "else                            sel = d_arvalid;", "else                            sel = i_arvalid;", "the D$'s port alone never chosen"),
    ('L45', AR, "assign m_wstrb   = d_wstrb;", "assign m_wstrb   = '1;", 'every write with all its strobes'),
    ('L46', AR, "assign m_arlen   = sel ? d_arlen   : i_arlen;", "assign m_arlen   = sel ? d_arlen   : d_arlen;", "the I$'s AR with the D$'s length"),
    # the data array's write port registered (step 1.7c C3)
    ('L47', L2, "(f_cnt == 3'd0) && !wr_held && ", "(f_cnt == 3'd0) && ", "a read taken while the fill's last word is still in the write register"),
    ('L48', L2, "else        wr_held <= d_wr_en;", "else        wr_held <= 1'b0;", 'the write register never seen as holding a write'),
    ('L49', DA, "w_en[w] <= wr_en && (int'(wr_way) == w);", "w_en[w] <= wr_en;", 'a registered write goes into every way'),
    ('L50', DA, "w_strb <= wr_strb;", "w_strb <= '1;", 'a registered write writes every byte'),
    ('L51', DA, "w_addr <= wr_addr;", "w_addr <= wr_addr ^ 1'b1;", 'a registered write into the next word'),
]


def run(m):
    mid, f, old, new, what = m
    work = os.path.join(HERE, 'obj_dir', 'mutate', mid)
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(CACHE, os.path.join(work, 'cache'))
    shutil.copytree(OOO, os.path.join(work, 'ooo'), ignore=shutil.ignore_patterns('*.md'))
    kind, rel = f.split(':', 1)
    path = os.path.join(work, 'cache' if kind == 'L2' else 'ooo', rel)
    src = open(path).read()
    if src.count(old) != 1:
        return mid, 'NOT APPLIED', what, f'found {src.count(old)} times'
    open(path, 'w').write(src.replace(old, new))
    env = dict(os.environ, L2_RTL=os.path.join(work, 'cache'), OOO_RTL=os.path.join(work, 'ooo'), L2_OBJ=os.path.join(work, 'obj'))
    r = subprocess.run([os.path.join(HERE, 'run.sh'), 'small'], env=env, capture_output=True, text=True)
    last = (r.stdout.strip().splitlines() or [''])[-1]
    if 'build failed' in last:
        return mid, 'NOT APPLIED', what, last
    return mid, ('DETECTED' if r.returncode != 0 else 'NOT DETECTED'), what, last[:110]


def main():
    sel = sys.argv[1:]
    ms = [m for m in M if not sel or m[0] in sel]
    with concurrent.futures.ThreadPoolExecutor(4) as ex:
        res = list(ex.map(run, ms))
    nd = 0
    for mid, st, what, last in res:
        print(f'{mid:4s} {st:13s} {what:55s} | {last}')
        nd += st != 'DETECTED'
    print(f'{len(res)} mutations, {len(res) - nd} detected')
    sys.exit(nd)


if __name__ == '__main__':
    main()
