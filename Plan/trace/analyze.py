#!/usr/bin/env python3
#---------------------------------------------------------------------------
# analyze.py : what the timed part of CoreMark is made of, from a trace of
# capture.py
#
#   analyze.py work/<build>.trace.gz work/<build>.elf ITERATIONS > results/<build>.txt
#   (also writes results/<build>.json)
#
# 1. Instruction mix (per 1000 instructions)
# 2. Control flow: taken rate of conditional branches, the run of
#    instructions between taken transfers (what the front end must deliver)
# 3. Dependences: distance from producer to consumer, load-use distance
# 4. Branch prediction: bimodal, the gshare of mmRISC-2, TAGE of 3 sizes
#    (trace-driven, updated at once: optimistic against real hardware)
# 5. SFB candidates: forward branches over 1 / 2 / up to 4 simple ALU
#    instructions, and how many of the mispredictions they are
# 6. Fusion candidates: adjacent dependent pairs by pattern
# 7. Limit model: an idealized out-of-order core (W-wide dispatch / commit,
#    ROB of R, ports ALU x2 / LSU x1 / MUL x1, no cache misses, perfect
#    memory disambiguation) with perfect or simulated prediction. Not
#    calibrated: it gives upper bounds and sensitivities, not the answer
#---------------------------------------------------------------------------
import bisect
import collections
import gzip
import json
import os
import re
import subprocess
import sys

OBJDUMP = '/opt/riscv/bin/riscv64-unknown-elf-objdump'
NM = '/opt/riscv/bin/riscv64-unknown-elf-nm'

#---------------------------------------------------------------------------
# registers and classes
#---------------------------------------------------------------------------
ABI = ['zero', 'ra', 'sp', 'gp', 'tp', 't0', 't1', 't2', 's0', 's1'] + \
      [f'a{i}' for i in range(8)] + [f's{i}' for i in range(2, 12)] + \
      ['t3', 't4', 't5', 't6']
FABI = [f'ft{i}' for i in range(8)] + ['fs0', 'fs1'] + [f'fa{i}' for i in range(8)] + \
       [f'fs{i}' for i in range(2, 12)] + [f'ft{i}' for i in range(8, 12)]
REG = {n: i for i, n in enumerate(ABI)}
REG['fp'] = 8
REG.update({n: 32 + i for i, n in enumerate(FABI)})
REG.update({f'x{i}': i for i in range(32)})

LOADS = {'lb', 'lh', 'lw', 'ld', 'lbu', 'lhu', 'lwu', 'flw', 'fld', 'c.lw', 'c.ld',
         'c.lwsp', 'c.ldsp', 'c.fld', 'c.fldsp', 'lr.w', 'lr.d'}
STORES = {'sb', 'sh', 'sw', 'sd', 'fsw', 'fsd', 'c.sw', 'c.sd', 'c.swsp', 'c.sdsp',
          'c.fsd', 'c.fsdsp', 'sc.w', 'sc.d'}
BRANCHES = {'beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu', 'beqz', 'bnez', 'blez', 'bgez',
            'bltz', 'bgtz', 'bgt', 'ble', 'bgtu', 'bleu', 'c.beqz', 'c.bnez'}
JALS = {'j', 'jal', 'c.j', 'c.jal'}
JALRS = {'jr', 'jalr', 'ret', 'c.jr', 'c.jalr'}
MULS = {'mul', 'mulh', 'mulhsu', 'mulhu', 'mulw', 'clmul', 'clmulh', 'clmulr'}
DIVS = {'div', 'divu', 'rem', 'remu', 'divw', 'divuw', 'remw', 'remuw'}
ZBA = {'sh1add', 'sh2add', 'sh3add', 'sh1add.uw', 'sh2add.uw', 'sh3add.uw', 'add.uw',
       'slli.uw', 'zext.w'}
ZBB = {'andn', 'orn', 'xnor', 'clz', 'clzw', 'ctz', 'ctzw', 'cpop', 'cpopw', 'max', 'maxu',
       'min', 'minu', 'sext.b', 'sext.h', 'zext.h', 'rol', 'rolw', 'ror', 'rori', 'roriw',
       'rorw', 'orc.b', 'rev8'}
ZBS = {'bclr', 'bclri', 'bext', 'bexti', 'binv', 'binvi', 'bset', 'bseti'}
ZICOND = {'czero.eqz', 'czero.nez'}
SHIFTS = {'sll', 'slli', 'srl', 'srli', 'sra', 'srai', 'sllw', 'slliw', 'srlw', 'srliw',
          'sraw', 'sraiw', 'c.slli', 'c.srli', 'c.srai'}
# compressed forms whose first operand is read as well as written
C_RD_SRC = {'c.addi', 'c.addiw', 'c.slli', 'c.srli', 'c.srai', 'c.andi', 'c.add', 'c.sub',
            'c.xor', 'c.or', 'c.and', 'c.addw', 'c.subw', 'c.addi16sp'}


def classify(mn):
    if mn in LOADS:
        return 'load'
    if mn in STORES or mn.startswith('amo'):
        return 'store'
    if mn in BRANCHES:
        return 'br'
    if mn in JALS:
        return 'jal'
    if mn in JALRS:
        return 'jalr'
    if mn in MULS:
        return 'mul'
    if mn in DIVS:
        return 'div'
    if mn.startswith('csr') or mn in ('fence', 'fence.i', 'ecall', 'ebreak', 'wfi', 'mret'):
        return 'sys'
    if mn.startswith('f'):
        return 'fp'
    return 'alu'


def subclass(mn):
    if mn in ZBA:
        return 'zba'
    if mn in ZBB:
        return 'zbb'
    if mn in ZBS:
        return 'zbs'
    if mn in ZICOND:
        return 'zicond'
    if mn in SHIFTS:
        return 'shift'
    return ''


RE_OFF = re.compile(r'pc ([+-]) (\d+)')


class Ins:
    __slots__ = ('pc', 'size', 'mn', 'cls', 'sub', 'srcs', 'dst', 'mem', 'off', 'base')


def parse_ops(mn, ops_text):
    """registers read, the first operand if it is a register, the base of a memory operand"""
    toks = [t.strip() for t in ops_text.split(',')] if ops_text else []
    regs, base = [], None
    for k, t in enumerate(toks):
        m = re.match(r'^-?(?:0x)?[0-9a-f]*\((\w+)\)$', t)
        if m:
            base = REG.get(m.group(1))
            regs.append((k, base))
        elif t in REG:
            regs.append((k, REG[t]))
    return toks, regs, base


def load_trace(path):
    tr = []
    with gzip.open(path, 'rt') as f:
        for line in f:
            pc, ins, dis, reg, mem = line.rstrip('\n').split('\t')
            x = Ins()
            x.pc = int(pc, 16)
            x.size = 2 if (int(ins, 16) & 3) != 3 else 4
            parts = dis.split(None, 1)
            mn = parts[0]
            x.mn = mn
            x.cls = classify(mn)
            x.sub = subclass(mn)
            toks, regs, base = parse_ops(mn, parts[1] if len(parts) > 1 else '')
            x.base = base
            # sources: every register operand, except the first operand when it is
            # the destination (not for stores / branches / compressed rd-also-source)
            if mn == 'ret':
                srcs = [1]
            elif x.cls in ('store', 'br') or mn in C_RD_SRC:
                srcs = [r for k, r in regs]
            elif x.cls == 'jalr':
                srcs = [r for k, r in regs][-1:]
            else:
                srcs = [r for k, r in regs if k != 0]
            x.srcs = tuple(r for r in srcs if r is not None and r != 0)
            if reg == '-':
                x.dst = None
            else:
                x.dst = int(reg[1:]) + (32 if reg[0] == 'f' else 0)
                if x.dst == 0:
                    x.dst = None
            x.mem = int(mem, 16) if mem != '-' else None
            m = RE_OFF.search(dis)
            x.off = (int(m.group(2)) * (1 if m.group(1) == '+' else -1)) if m else None
            tr.append(x)
    return tr


def static_code(elf):
    """pc -> (size, class) of every instruction of the program, from objdump"""
    out = subprocess.run([OBJDUMP, '-d', '-M', 'no-aliases', elf], capture_output=True,
                         text=True).stdout
    code = {}
    for line in out.splitlines():
        m = re.match(r'^\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(\S+)', line)
        if m:
            code[int(m.group(1), 16)] = (len(m.group(2)) // 2, classify(m.group(3)))
    return code


def functions(elf):
    out = subprocess.run([NM, '-n', elf], capture_output=True, text=True).stdout
    addrs, names = [], []
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3 and p[1] in 'tT':
            addrs.append(int(p[0], 16))
            names.append(p[2])
    return lambda pc: names[bisect.bisect_right(addrs, pc) - 1] if pc >= addrs[0] else '?'


def taken_flags(tr):
    """taken[i]: instruction i transferred control (the next pc is not pc + size)"""
    t = [False] * len(tr)
    for i in range(len(tr) - 1):
        t[i] = tr[i + 1].pc != tr[i].pc + tr[i].size
    x = tr[-1]
    t[-1] = x.cls in ('jal', 'jalr')
    return t


#---------------------------------------------------------------------------
# 1-3. mix, control flow, dependences
#---------------------------------------------------------------------------
def mix(tr, taken):
    n = len(tr)
    c = collections.Counter(x.cls for x in tr)
    s = collections.Counter(x.sub for x in tr if x.sub)
    rvc = sum(1 for x in tr if x.size == 2)
    br = [i for i, x in enumerate(tr) if x.cls == 'br']
    brt = sum(1 for i in br if taken[i])
    back = sum(1 for i in br if tr[i].off is not None and tr[i].off < 0)
    calls = sum(1 for x in tr if x.cls in ('jal', 'jalr') and x.dst == 1)
    rets = sum(1 for x in tr if x.mn in ('ret',) or (x.cls == 'jalr' and x.srcs == (1,) and x.dst is None))
    k = 1000.0 / n
    r = {'instructions': n, 'per1000': {cl: c[cl] * k for cl in sorted(c)},
         'sub_per1000': {cl: s[cl] * k for cl in sorted(s)}, 'rvc_share': rvc / n,
         'cond_branches': len(br), 'cond_taken_rate': brt / len(br),
         'cond_backward_share': back / len(br), 'calls_per1000': calls * k,
         'returns_per1000': rets * k}
    # runs between taken transfers (instructions and bytes, the transfer included)
    runs, rb, cur, curb = [], [], 0, 0
    for i, x in enumerate(tr):
        cur += 1
        curb += x.size
        if taken[i]:
            runs.append(cur)
            rb.append(curb)
            cur, curb = 0, 0
    r['taken_per1000'] = len(runs) * k
    r['run_mean_instr'] = sum(runs) / len(runs)
    r['run_mean_bytes'] = sum(rb) / len(rb)
    tot = sum(runs)
    r['instr_in_runs_le'] = {L: sum(v for v in runs if v <= L) / tot for L in (2, 4, 8, 16)}
    return r


def dependences(tr):
    last = {}
    dist = collections.Counter()
    first_use = {}      # load index -> distance to its first consumer
    loads_open = {}     # register -> load index whose value is unread
    for i, x in enumerate(tr):
        for s in x.srcs:
            p = last.get(s)
            if p is not None:
                d = i - p
                dist[min(d, 9)] += 1
                li = loads_open.pop(s, None)
                if li is not None:
                    first_use[li] = i - li
        if x.dst is not None:
            loads_open.pop(x.dst, None)
            last[x.dst] = i
            if x.cls == 'load':
                loads_open[x.dst] = i
    # loads that read bytes written by one of the 64 instructions before them
    fwd = 0
    recent = collections.deque()
    for i, x in enumerate(tr):
        while recent and recent[0][0] < i - 64:
            recent.popleft()
        if x.cls == 'load' and x.mem is not None:
            if any(a >> 3 == x.mem >> 3 for _, a in recent):
                fwd += 1
        elif x.cls == 'store' and x.mem is not None:
            recent.append((i, x.mem))
    nsrc = sum(dist.values())
    nload = sum(1 for x in tr if x.cls == 'load')
    lu = collections.Counter(min(d, 4) for d in first_use.values())
    return {'src_distance_share': {str(d): dist[d] / nsrc for d in sorted(dist)},
            'load_first_use_share': {str(d): lu[d] / nload for d in sorted(lu)},
            'load_never_used_share': 1 - len(first_use) / nload,
            'load_from_store_within_64_share': fwd / nload}


#---------------------------------------------------------------------------
# 4. branch predictors (conditional branches; returns the mispredicted flags)
#---------------------------------------------------------------------------
def pred_bimodal(seq, log=12):
    t = [2] * (1 << log)
    m = (1 << log) - 1
    out = []
    for pc, tk in seq:
        i = (pc >> 1) & m
        p = t[i] >= 2
        out.append(p != tk)
        t[i] = min(3, t[i] + 1) if tk else max(0, t[i] - 1)
    return out


def pred_gshare_m2(seq):
    """the gshare of mmRISC-2 (decision 63): PHT 8192 x 2 bits, 12 bits of the
    directions of conditional branches folded into the upper bits of the index
    (XOR with the word address), weakly taken at start. Every conditional
    branch enters the history (mmRISC-2: only those with a BTB entry)."""
    t = [2] * 8192
    h = 0
    out = []
    for pc, tk in seq:
        i = ((pc >> 2) ^ (h << 1)) & 8191
        p = t[i] >= 2
        out.append(p != tk)
        t[i] = min(3, t[i] + 1) if tk else max(0, t[i] - 1)
        h = ((h << 1) | tk) & 0xfff
    return out


class Folded:
    __slots__ = ('comp', 'clen', 'olen', 'outpoint', 'mask')

    def __init__(self, olen, clen):
        self.comp, self.clen, self.olen = 0, clen, olen
        self.outpoint = olen % clen
        self.mask = (1 << clen) - 1

    def update(self, newbit, oldbit):
        c = (self.comp << 1) | newbit
        c ^= oldbit << self.outpoint
        c ^= c >> self.clen
        self.comp = c & self.mask


class Tage:
    """TAGE (Seznec): a bimodal base and tagged tables with geometric histories,
    3-bit counters, 2-bit useful counters, use-alt-on-new-allocation."""

    def __init__(self, base_log, nlog, tags, hists):
        self.base = [2] * (1 << base_log)
        self.bmask = (1 << base_log) - 1
        self.n = len(hists)
        self.nlog, self.tags, self.hists = nlog, tags, hists
        self.ctr = [[4] * (1 << nlog) for _ in hists]
        self.tag = [[-1] * (1 << nlog) for _ in hists]
        self.u = [[0] * (1 << nlog) for _ in hists]
        self.fi = [Folded(h, nlog) for h in hists]
        self.ft1 = [Folded(h, t) for h, t in zip(hists, tags)]
        self.ft2 = [Folded(h, t - 1) for h, t in zip(hists, tags)]
        self.ghist = 0
        self.maxh = max(hists)
        self.use_alt = 8
        self.tick = 0
        self.bits = (2 << base_log) + sum((1 << nlog) * (3 + 2 + t) for t in tags)

    def run(self, seq):
        out = []
        n, nmask = self.n, (1 << self.nlog) - 1
        for pc, tk in seq:
            pcs = pc >> 1
            idx = [(pcs ^ (pcs >> (self.nlog - j)) ^ self.fi[j].comp) & nmask for j in range(n)]
            tg = [(pcs ^ self.ft1[j].comp ^ (self.ft2[j].comp << 1)) & ((1 << self.tags[j]) - 1)
                  for j in range(n)]
            prov = alt = -1
            for j in range(n - 1, -1, -1):
                if self.tag[j][idx[j]] == tg[j]:
                    if prov < 0:
                        prov = j
                    else:
                        alt = j
                        break
            bi = pcs & self.bmask
            base_p = self.base[bi] >= 2
            alt_p = (self.ctr[alt][idx[alt]] >= 4) if alt >= 0 else base_p
            if prov >= 0:
                c = self.ctr[prov][idx[prov]]
                prov_p = c >= 4
                weak = c in (3, 4) and self.u[prov][idx[prov]] == 0
                pred = alt_p if (weak and self.use_alt >= 8) else prov_p
                if weak and prov_p != alt_p:
                    self.use_alt = min(15, self.use_alt + 1) if alt_p == tk else max(0, self.use_alt - 1)
            else:
                prov_p = pred = base_p
            out.append(pred != tk)
            # allocation on a misprediction
            if pred != tk and prov < n - 1:
                free = [j for j in range(prov + 1, n) if self.u[j][idx[j]] == 0]
                if free:
                    j = free[0] if len(free) == 1 or (self.tick & 1) else free[1]
                    self.tag[j][idx[j]] = tg[j]
                    self.ctr[j][idx[j]] = 4 if tk else 3
                    self.u[j][idx[j]] = 0
                else:
                    for j in range(prov + 1, n):
                        self.u[j][idx[j]] = max(0, self.u[j][idx[j]] - 1)
            # counters
            if prov >= 0:
                c = self.ctr[prov][idx[prov]]
                self.ctr[prov][idx[prov]] = min(7, c + 1) if tk else max(0, c - 1)
                if prov_p != alt_p:
                    uu = self.u[prov][idx[prov]]
                    self.u[prov][idx[prov]] = min(3, uu + 1) if prov_p == tk else max(0, uu - 1)
                if alt < 0 and self.u[prov][idx[prov]] == 0:
                    b = self.base[bi]
                    self.base[bi] = min(3, b + 1) if tk else max(0, b - 1)
            else:
                b = self.base[bi]
                self.base[bi] = min(3, b + 1) if tk else max(0, b - 1)
            # periodic aging of the useful counters
            self.tick += 1
            if (self.tick & 0x3ffff) == 0:
                for j in range(n):
                    self.u[j] = [x >> 1 for x in self.u[j]]
            # history
            self.ghist = ((self.ghist << 1) | tk) & ((1 << (self.maxh + 1)) - 1)
            for j in range(n):
                old = (self.ghist >> self.hists[j]) & 1
                self.fi[j].update(tk, old)
                self.ft1[j].update(tk, old)
                self.ft2[j].update(tk, old)
        return out


TAGE_CONFIGS = {
    # name: (base log2, table log2, tag bits per table, history lengths)
    'TAGE-S': (12, 10, [8, 8, 9, 9], [5, 12, 30, 70]),
    'TAGE-M': (13, 11, [9, 9, 10, 10, 11, 11], [4, 9, 20, 44, 96, 200]),
    'TAGE-L': (14, 12, [10, 10, 11, 11, 12, 12, 13, 13], [4, 8, 16, 32, 64, 128, 256, 640]),
}


def jalr_mispredicts(tr, taken):
    """returns by a perfect return address stack; other jalr by the last target"""
    last, miss, n = {}, 0, 0
    for i, x in enumerate(tr):
        if x.cls == 'jalr' and not (x.srcs == (1,) and x.dst is None):
            n += 1
            tgt = tr[i + 1].pc if i + 1 < len(tr) else None
            if last.get(x.pc) != tgt:
                miss += 1
            last[x.pc] = tgt
    return n, miss


#---------------------------------------------------------------------------
# 5. SFB candidates
#---------------------------------------------------------------------------
def sfb_shadow(code, pc, size, off):
    """number of instructions a forward branch jumps over, if all are simple ALU"""
    if off is None or off <= size:
        return None
    a, k = pc + size, 0
    while a < pc + off:
        if a not in code:
            return None
        sz, cl = code[a]
        if cl != 'alu':
            return None
        a += sz
        k += 1
    return k if a == pc + off else None


#---------------------------------------------------------------------------
# 6. fusion candidates (adjacent, sequential, dependent pairs)
#---------------------------------------------------------------------------
def simple_alu(x):
    return x.cls == 'alu'


def fusion_kind(a, b):
    if b.pc != a.pc + a.size:
        return None
    d = a.dst
    if a.mn in ('lui', 'c.lui') and b.mn in ('addi', 'addiw', 'c.addi', 'c.addiw') and d in b.srcs:
        return 'lui+addi'
    if a.mn == 'auipc' and d is not None and d in b.srcs:
        return 'auipc+x'
    if a.sub == 'shift' and b.sub == 'shift' and d is not None and d in b.srcs and \
            a.mn.endswith('slli') and not b.mn.endswith('slli'):
        return 'slli+srli'
    if b.cls == 'load' and d is not None and b.base == d and simple_alu(a):
        return 'alu+load(addr)'
    if a.cls == 'load' and b.cls == 'load' and a.base is not None and a.base == b.base and \
            a.dst != a.base and a.mem is not None and b.mem is not None and abs(a.mem - b.mem) <= 8:
        return 'load+load(pair)'
    if a.cls == 'store' and b.cls == 'store' and a.base is not None and a.base == b.base and \
            a.mem is not None and b.mem is not None and abs(a.mem - b.mem) <= 8:
        return 'store+store(pair)'
    if simple_alu(a) and b.cls == 'br' and d is not None and d in b.srcs:
        return 'alu+branch'
    if simple_alu(a) and simple_alu(b) and d is not None and d in b.srcs:
        return 'alu+alu'
    return None


CONSERVATIVE = {'lui+addi', 'auipc+x', 'slli+srli', 'alu+load(addr)', 'load+load(pair)',
                'store+store(pair)'}


def fusion(tr):
    kinds = collections.Counter()
    same_rd = collections.Counter()
    for a, b in zip(tr, tr[1:]):
        k = fusion_kind(a, b)
        if k:
            kinds[k] += 1
            if a.dst is not None and a.dst == b.dst:
                same_rd[k] += 1

    def greedy(allowed):
        i, pairs = 0, 0
        while i < len(tr) - 1:
            k = fusion_kind(tr[i], tr[i + 1])
            if k in allowed:
                pairs += 1
                i += 2
            else:
                i += 1
        return pairs
    n = len(tr)
    pc_ = greedy(CONSERVATIVE)
    pa = greedy(set(kinds))
    return {'pairs_per1000': {k: v * 1000 / n for k, v in kinds.most_common()},
            'same_rd_share': {k: same_rd[k] / kinds[k] for k in kinds},
            'uops_per_instr_conservative': (n - pc_) / n,
            'uops_per_instr_all': (n - pa) / n}


#---------------------------------------------------------------------------
# 7. limit model
#---------------------------------------------------------------------------
LAT = {'alu': 1, 'br': 1, 'jal': 1, 'jalr': 1, 'load': 2, 'store': 1, 'mul': 2, 'div': 20,
       'sys': 1, 'fp': 4}
PORT = {'alu': 'alu', 'br': 'alu', 'jal': 'alu', 'jalr': 'alu', 'sys': 'alu', 'load': 'lsu',
        'store': 'lsu', 'mul': 'mul', 'div': 'mul', 'fp': 'fp'}


def fused_pairs(tr, allowed):
    """second[i]: instruction i is the second of a fused pair (greedy, in order)"""
    second = [False] * len(tr)
    i = 0
    while i < len(tr) - 1:
        if fusion_kind(tr[i], tr[i + 1]) in allowed:
            second[i + 1] = True
            i += 2
        else:
            i += 1
    return second


def limit_model(tr, taken, mispred, W=2, R=64, P=8, ports=None, group_break=True,
                lat=None, second=None, bubble=0, mem_conservative=False):
    """IPC of an idealized out-of-order core. mispred: set of instruction indices that
    mispredict (None: perfect). P: cycles from the execution of a mispredicted branch to
    the execution of the first correct-path instruction. second: fused pairs (fused_pairs);
    a pair takes one dispatch / issue / commit slot and one port, and each half has the
    latency of its own class from the issue of the pair (so add + load gives the load in 2
    cycles and two dependent ALU operations finish in one, chained in the cycle). bubble:
    cycles the front end loses on every taken transfer (0: zero-bubble prediction).
    mem_conservative: a load does not issue before the addresses of all older stores are
    known (otherwise memory disambiguation is perfect)."""
    ports = ports or {'alu': 2, 'lsu': 1, 'mul': 1, 'fp': 1}
    lat = lat or LAT
    n = len(tr)
    ready = {}
    use = collections.defaultdict(lambda: collections.Counter())
    disp, comm = [], []
    redirect = 0
    last_i = -1
    st_addr = 0         # when the addresses of all stores so far are known
    i = 0
    while i < n:
        x = tr[i]
        pair = second is not None and i + 1 < n and second[i + 1]
        y = tr[i + 1] if pair else None
        u = len(disp)
        d = redirect
        if u >= 1:
            d = max(d, disp[u - 1] + ((1 + bubble) if (group_break and taken[last_i]) else 0))
        if u >= W:
            d = max(d, disp[u - W] + 1)
        if u >= R:
            d = max(d, comm[u - R] + 1)
        disp.append(d)
        t = d + 1
        srcs = list(x.srcs)
        if pair:
            srcs += [s for s in y.srcs if s != x.dst]
        for s in srcs:
            r = ready.get(s, 0)
            if r > t:
                t = r
        if mem_conservative:
            for z in ((x, y) if pair else (x,)):
                if z.cls == 'load' and st_addr > t:
                    t = st_addr
                elif z.cls == 'store':
                    st_addr = max(st_addr, d + 1, ready.get(z.base, 0) if z.base else 0)
        p = PORT[x.cls] if not pair or PORT[y.cls] == 'alu' else PORT[y.cls]
        cap = ports[p]
        while use[t][p] >= cap:
            t += 1
        use[t][p] += 1
        done = t + lat[x.cls]
        if x.dst is not None:
            ready[x.dst] = done
        if pair:
            done_y = t + lat[y.cls]
            if y.dst is not None:
                ready[y.dst] = done_y
            done = max(done, done_y)
        c = done
        if u >= 1 and comm[u - 1] > c:
            c = comm[u - 1]
        if u >= W and comm[u - W] + 1 > c:
            c = comm[u - W] + 1
        comm.append(c)
        if mispred is not None and (i in mispred or (pair and i + 1 in mispred)):
            redirect = t + P - 1
        last_i = i + 1 if pair else i
        i += 2 if pair else 1
        if (u & 0xffff) == 0:
            for k in [k for k in use if k < t - 64]:
                del use[k]
    return n / comm[-1]


#---------------------------------------------------------------------------
def main():
    trace, elf, iters = sys.argv[1], sys.argv[2], int(sys.argv[3])
    name = os.path.basename(trace).replace('.trace.gz', '')
    tr = load_trace(trace)
    taken = taken_flags(tr)
    code = static_code(elf)
    func = functions(elf)
    n = len(tr)
    per_iter = n / iters
    res = {'build': name, 'iterations': iters, 'instructions_per_iteration': per_iter}

    res['mix'] = mix(tr, taken)
    res['dependences'] = dependences(tr)

    # branch prediction
    bidx = [i for i, x in enumerate(tr) if x.cls == 'br']
    seq = [(tr[i].pc, taken[i]) for i in bidx]
    half = n // 2
    preds = {'bimodal-4K': pred_bimodal(seq), 'gshare-m2': pred_gshare_m2(seq)}
    bits = {'bimodal-4K': 2 * 4096, 'gshare-m2': 2 * 8192}
    for nm_, cfg in TAGE_CONFIGS.items():
        t = Tage(*cfg)
        preds[nm_] = t.run(seq)
        bits[nm_] = t.bits
    jn, jm = jalr_mispredicts(tr, taken)
    res['jalr_other'] = {'count': jn, 'mispredicted': jm}

    # SFB eligibility per conditional branch
    shadow = [sfb_shadow(code, tr[i].pc, tr[i].size, tr[i].off) for i in bidx]
    res['sfb'] = {}
    for kmax in (1, 2, 4):
        el = [s is not None and s <= kmax for s in shadow]
        ne = sum(el)
        extra = sum(shadow[j] for j, i in enumerate(bidx) if el[j] and taken[i])
        res['sfb'][f'k<={kmax}'] = {'branches_per1000': ne * 1000 / n,
                                     'share_of_cond': ne / len(bidx),
                                     'extra_uops_per1000': extra * 1000 / n}
    res['pred'] = {}
    for nm_, mp in preds.items():
        m_all = sum(mp)
        m_2nd = sum(1 for j, i in enumerate(bidx) if mp[j] and i >= half)
        b_2nd = sum(1 for i in bidx if i >= half)
        d = {'kbits': bits[nm_] / 1024, 'miss_rate': m_all / len(bidx), 'mpki': m_all * 1000 / n,
             'miss_rate_2nd_half': m_2nd / b_2nd, 'mpki_2nd_half': m_2nd * 2000 / n}
        for kmax in (1, 2, 4):
            ms = sum(1 for j in range(len(bidx)) if mp[j] and shadow[j] is not None and shadow[j] <= kmax)
            d[f'sfb_k<={kmax}_share_of_misses'] = ms / m_all if m_all else 0
            d[f'mpki_after_sfb_k<={kmax}'] = (m_all - ms) * 1000 / n
        res['pred'][nm_] = d

    # mispredictions by function (gshare-m2 and TAGE-L)
    byf = {}
    for nm_ in ('gshare-m2', 'TAGE-L'):
        c = collections.Counter(func(tr[bidx[j]].pc) for j, m in enumerate(preds[nm_]) if m)
        byf[nm_] = {k: v * 1000 / n for k, v in c.most_common(8)}
    ci = collections.Counter(func(x.pc) for x in tr)
    res['functions_instr_share'] = {k: v / n for k, v in ci.most_common(10)}
    res['functions_mpki'] = byf

    res['fusion'] = fusion(tr)

    # limit model
    lm = {}

    def miss_set(nm_, sfb_k=None):
        s = set()
        for j, m in enumerate(preds[nm_]):
            if m and not (sfb_k and shadow[j] is not None and shadow[j] <= sfb_k):
                s.add(bidx[j])
        return s
    sets = {'perfect': None, 'gshare-m2': miss_set('gshare-m2'), 'TAGE-M': miss_set('TAGE-M'),
            'TAGE-L': miss_set('TAGE-L'), 'TAGE-L+SFB2': miss_set('TAGE-L', 2)}
    allk = {'lui+addi', 'auipc+x', 'slli+srli', 'alu+load(addr)', 'load+load(pair)',
            'store+store(pair)', 'alu+branch', 'alu+alu'}
    sec_c = fused_pairs(tr, CONSERVATIVE)
    sec_b = fused_pairs(tr, CONSERVATIVE | {'alu+branch'})
    sec_a = fused_pairs(tr, allk)
    runs = [('W2 R32 perfect', dict(W=2, R=32), 'perfect'),
            ('W2 R64 perfect', dict(W=2, R=64), 'perfect'),
            ('W2 R128 perfect', dict(W=2, R=128), 'perfect'),
            ('W2 R64 perfect, no group break', dict(W=2, R=64, group_break=False), 'perfect'),
            ('W2 R64 perfect, load-use 3', dict(W=2, R=64, lat=dict(LAT, load=3)), 'perfect'),
            ('W2 R64 perfect, ALU x3', dict(W=2, R=64, ports={'alu': 3, 'lsu': 1, 'mul': 1, 'fp': 1}), 'perfect'),
            ('W2 R64 perfect, LSU x2', dict(W=2, R=64, ports={'alu': 2, 'lsu': 2, 'mul': 1, 'fp': 1}), 'perfect'),
            ('W3 R64 perfect', dict(W=3, R=64, ports={'alu': 3, 'lsu': 1, 'mul': 1, 'fp': 1}), 'perfect'),
            ('W4 R96 perfect', dict(W=4, R=96, ports={'alu': 4, 'lsu': 2, 'mul': 1, 'fp': 1}), 'perfect'),
            ('W2 R64 gshare-m2 P8', dict(W=2, R=64, P=8), 'gshare-m2'),
            ('W2 R64 TAGE-M P8', dict(W=2, R=64, P=8), 'TAGE-M'),
            ('W2 R64 TAGE-L P6', dict(W=2, R=64, P=6), 'TAGE-L'),
            ('W2 R64 TAGE-L P8', dict(W=2, R=64, P=8), 'TAGE-L'),
            ('W2 R64 TAGE-L P10', dict(W=2, R=64, P=10), 'TAGE-L'),
            ('W2 R64 TAGE-L+SFB2 P8', dict(W=2, R=64, P=8), 'TAGE-L+SFB2'),
            ('W3 R64 TAGE-L+SFB2 P8', dict(W=3, R=64, P=8, ports={'alu': 3, 'lsu': 1, 'mul': 1, 'fp': 1}), 'TAGE-L+SFB2'),
            ('W2 R64 TAGE-L P8 fusion-cons', dict(W=2, R=64, P=8, second=sec_c), 'TAGE-L'),
            ('W2 R64 TAGE-L P8 fusion-cons+alu+branch', dict(W=2, R=64, P=8, second=sec_b), 'TAGE-L'),
            ('W2 R64 TAGE-L P8 fusion-all', dict(W=2, R=64, P=8, second=sec_a), 'TAGE-L'),
            ('W2 R64 perfect fusion-all', dict(W=2, R=64, second=sec_a), 'perfect'),
            ('W2 R64 TAGE-L P8 fusion-all, load-use 3', dict(W=2, R=64, P=8, second=sec_a, lat=dict(LAT, load=3)), 'TAGE-L'),
            ('W2 R64 TAGE-L P8 fusion-all, ALU x3', dict(W=2, R=64, P=8, second=sec_a, ports={'alu': 3, 'lsu': 1, 'mul': 1, 'fp': 1}), 'TAGE-L'),
            ('W2 R64 TAGE-L P8, conservative memory', dict(W=2, R=64, P=8, mem_conservative=True), 'TAGE-L'),
            ('W2 R64 TAGE-L P8 fusion-all, conservative memory', dict(W=2, R=64, P=8, second=sec_a, mem_conservative=True), 'TAGE-L'),
            ('W2 R64 TAGE-L P8, taken bubble 1', dict(W=2, R=64, P=8, bubble=1), 'TAGE-L'),
            ('W2 R64 TAGE-L P8 fusion-all, taken bubble 1', dict(W=2, R=64, P=8, second=sec_a, bubble=1), 'TAGE-L'),
            ('W2 R64 TAGE-L P8 fusion-all, LSU x2', dict(W=2, R=64, P=8, second=sec_a, ports={'alu': 2, 'lsu': 2, 'mul': 1, 'fp': 1}), 'TAGE-L')]
    for label, kw, ps in runs:
        ipc = limit_model(tr, taken, sets[ps], **kw)
        lm[label] = {'ipc': ipc, 'coremark_per_mhz': ipc * 1e6 / per_iter}
        print(f'  {label:36s} IPC {ipc:.3f}  CoreMark/MHz {ipc * 1e6 / per_iter:.2f}',
              file=sys.stderr)
    res['limit_model'] = lm

    os.makedirs('results', exist_ok=True)
    with open(f'results/{name}.json', 'w') as f:
        json.dump(res, f, indent=1)
    print(json.dumps(res, indent=1))


if __name__ == '__main__':
    main()
