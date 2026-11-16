#!/usr/bin/env python3
#---------------------------------------------------------------------------
# fpsched.py : a scheduling model of OOO_CORE with the renamed FPU of step
# 1.8 U0 (Plan/OOC.md 29.80), on Spike's log of a DSP kernel (gen.py)
#
#   fpsched.py <spike.log> <kstart> <kend> [key=value ...]
#
# Only the region from the first kstart to the next kend is modelled, from an
# empty machine. What it holds (the core as built, Doc/UARCH.md A, plus the
# FP side as 29.80 proposes):
#   - dispatch: w (4) instructions a cycle in order, a group ending after a
#     taken branch; each needs a ROB entry (rob 48), its queue entries (a
#     store two: the address in the integer queue, the data in the integer
#     queue or, for fsw / fsd, the FP queue), an LQ / SQ entry (lq / sq 16),
#     a free physical register of its destination's file (ireg 80, freg 64:
#     32 of each architectural), a checkpoint for a conditional branch
#     (ckpt 12)
#   - the integer queue (iq 24): 6 ports, oldest first: port 0 everything
#     (branches, mul, int -> FP moves and conversions), ports 1..3 simple ALU
#     (port 1 also an integer store's data), port 4 loads and store
#     addresses, port 5 loads
#   - the FP queue (fq 16): oldest first, one FPU operation a cycle (not while
#     a divide / square root holds the FPU, nor in a cycle an int -> FP µop
#     from port 0 takes the FPU's input) and one FP store's data (fsd_w 1)
#   - latencies: ALU 1, mul 2, load 2 (FP loads too: the FP file written by
#     the load ports, the FP queue woken at issue + 2), FPU lat (9; 10 = no
#     bypass from its output to its input), FP -> integer lat + 1 (the
#     integer write slot), int -> FP: port 0, then the FPU at the next free
#     slot, + lat; divide / square root: the engine (single 64 + 9, double
#     128 + 9; square root 64 + 9), the FPU held
#   - commit: cw (4) a cycle in order; a store's SQ entry free once drained
#     (one a cycle after commit)
#   - prediction perfect, every load a hit: it measures the window and the
#     FPU, not the memory or the front end
# Prints the cycles, instructions, FPU operations a cycle, and what held
# dispatch.
#---------------------------------------------------------------------------
import re
import sys

IREG = {n: i for i, n in enumerate(
    'zero ra sp gp tp t0 t1 t2 s0 s1 a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6'.split())}
IREG['fp'] = 8
FREG = {n: i for i, n in enumerate(
    'ft0 ft1 ft2 ft3 ft4 ft5 ft6 ft7 fs0 fs1 fa0 fa1 fa2 fa3 fa4 fa5 fa6 fa7 fs2 fs3 fs4 fs5 fs6 fs7 fs8 fs9 fs10 fs11 ft8 ft9 ft10 ft11'.split())}
for i in range(32):
    IREG['x%d' % i] = i
    FREG['f%d' % i] = i

BR2 = {'beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu', 'bgt', 'ble', 'bgtu', 'bleu'}
BR1 = {'beqz', 'bnez', 'blez', 'bgez', 'bltz', 'bgtz'}
LDI = {'lb', 'lh', 'lw', 'ld', 'lbu', 'lhu', 'lwu'}
STI = {'sb', 'sh', 'sw', 'sd'}


def reg(tok):
    """('i' | 'f', index) of a register operand, or None"""
    t = tok.strip()
    if t in IREG:
        return ('i', IREG[t])
    if t in FREG:
        return ('f', FREG[t])
    return None


class Ins:
    __slots__ = ('pc', 'mn', 'kind', 'dst', 'srcs', 'taken', 'prod', 'sprod', 'disp', 'iss', 'iss2', 'ready', 'done',
                 'unit', 'dprod')

    def __init__(self, pc, mn, kind, dst, srcs):
        self.pc, self.mn, self.kind, self.dst, self.srcs = pc, mn, kind, dst, srcs
        self.taken = False
        self.iss = self.iss2 = None
        self.ready = self.done = None


def decode(mn, ops):
    """kind, destination, sources (the store's data last)"""
    toks = [o for o in re.split(r'[,()]', ops) if o.strip()]
    regs = [reg(t) for t in toks]
    if mn in BR2:
        return 'br', None, [r for r in regs[:2] if r]
    if mn in BR1:
        return 'br', None, [r for r in regs[:1] if r]
    if mn in ('j', 'jal', 'jalr', 'ret', 'jr', 'c.j'):
        d = regs[0] if mn in ('jal', 'jalr') and regs and len(toks) > 1 and regs[0] and regs[0][1] != 0 else None
        return 'jmp', d, [r for r in regs[1:] if r] if mn == 'jalr' else []
    if mn in LDI:
        return 'ld', regs[0], [r for r in regs[1:] if r]
    if mn in ('flw', 'fld'):
        return 'fld', regs[0], [r for r in regs[1:] if r]
    if mn in STI:
        return 'st', None, [r for r in regs[1:] if r] + [regs[0]]
    if mn in ('fsw', 'fsd'):
        return 'fst', None, [r for r in regs[1:] if r] + [regs[0]]
    d = regs[0] if regs and regs[0] and not (regs[0][0] == 'i' and regs[0][1] == 0) else None
    s = [r for r in regs[1:] if r and not (r[0] == 'i' and r[1] == 0)]
    if mn.startswith('f') and not mn.startswith('fence'):
        if mn.startswith(('fdiv', 'fsqrt')):
            return ('fsqrt' if mn.startswith('fsqrt') else 'fdiv') + mn[-1], d, s
        if d and d[0] == 'i':
            return 'f2i', d, s                     # compares, fclass, fmv.x.*, fcvt to integers
        if any(r[0] == 'i' for r in s) or mn in ('fmv.w.x', 'fmv.d.x'):
            return 'i2f', d, s                     # fmv.*.x, fcvt from integers
        return 'fpu', d, s
    if mn in ('mul', 'mulw', 'mulh', 'mulhu', 'mulhsu'):
        return 'mul', d, s
    if mn.startswith(('div', 'rem')):
        return 'div', d, s
    return 'alu', d, s


def load(path, kstart, kend):
    out, on, prev = [], False, None
    for line in open(path):
        m = re.match(r'core\s+\d+: 0x([0-9a-f]+) \(0x[0-9a-f]+\) (\S+)\s*(.*)$', line)
        if not m:
            continue
        pc = int(m.group(1), 16)
        if pc == kstart:
            on = True
        if not on:
            continue
        if pc == kend:
            break
        mn = m.group(2)
        kind, d, s = decode(mn, m.group(3))
        i = Ins(pc, mn, kind, d, s)
        if prev is not None:
            prev.taken = pc != prev.pc + 4
        out.append(i)
        prev = i
    return out


def run(tr, o):
    W, CW = o['w'], o['cw']
    lat = o['lat']
    last = {}                                   # (file, reg) -> producer
    for i in tr:
        i.prod = [last.get(s) for s in i.srcs]
        if i.dst:
            last[i.dst] = i
    n = len(tr)
    rob = []                                    # in order
    iq, fq = [], []                             # [ins, part] in age order; part 0 the µop, 1 a store's data
    inflight = {'i': 0, 'f': 0}
    lq = sq = ck = 0
    drain = 0                                   # committed stores not drained
    fpu_busy_until = 0                          # a divide / square root holds the FPU
    i2f_wait = []                               # int -> FP µops issued on port 0, waiting for the FPU's input
    nxt, cyc = 0, 0
    stall = {}
    fpu_ops = 0
    done_n = 0

    def ready(p, c):
        return p is None or (p.ready is not None and p.ready <= c)

    while done_n < n:
        # commit
        k = 0
        while rob and k < CW:
            h = rob[0]
            if h.done is None or h.done > cyc:
                break
            rob.pop(0)
            k += 1
            done_n += 1
            if h.dst:
                inflight[h.dst[0]] -= 1
            if h.kind in ('ld', 'fld'):
                lq -= 1
            if h.kind in ('st', 'fst'):
                drain += 1
            if h.kind == 'br':
                ck -= 1
        if drain:
            drain -= 1
            sq -= 1
        # the FPU's input this cycle: an int -> FP µop first
        fpu_free = cyc >= fpu_busy_until
        if fpu_free and i2f_wait and i2f_wait[0][1] <= cyc:
            ins, _ = i2f_wait.pop(0)
            ins.ready = cyc + lat
            ins.done = ins.ready
            fpu_free = False
            fpu_ops += 1
        # issue: the integer queue
        ports = [True] * 6
        keep = []
        for e in iq:
            ins, part = e
            if part == 1:                         # an integer store's data: port 1 (any ALU port in the RTL? port 1)
                if ports[1] and ready(ins.prod[-1], cyc):
                    ports[1] = False
                    ins.iss2 = cyc
                    if ins.iss is not None:
                        ins.done = max(ins.iss, ins.iss2) + 1
                    continue
                keep.append(e)
                continue
            srcs = ins.prod[:-1] if ins.kind in ('st', 'fst') else ins.prod
            if not all(ready(p, cyc) for p in srcs):
                keep.append(e)
                continue
            kd = ins.kind
            if kd in ('ld', 'fld'):
                pl = [4, 5]
            elif kd in ('st', 'fst'):
                pl = [4]
            elif kd in ('br', 'jmp', 'mul', 'div', 'i2f'):
                pl = [0]
            else:
                pl = [0, 1, 2, 3]
            got = next((q for q in pl if ports[q]), None)
            if got is None:
                keep.append(e)
                continue
            ports[got] = False
            ins.iss = cyc
            if kd in ('ld', 'fld'):
                ins.ready = ins.done = cyc + 2
            elif kd in ('st', 'fst'):
                if ins.iss2 is not None:
                    ins.done = max(ins.iss, ins.iss2) + 1
            elif kd == 'mul':
                ins.ready = ins.done = cyc + 2
            elif kd == 'div':
                ins.ready = ins.done = cyc + 34
            elif kd == 'i2f':
                i2f_wait.append((ins, cyc + 1))
            else:
                ins.ready = ins.done = cyc + 1
        iq = keep
        # issue: the FP queue
        fsd_left = o['fsd_w']
        keep = []
        for e in fq:
            ins, part = e
            if part == 1:                         # an FP store's data
                if fsd_left and ready(ins.prod[-1], cyc):
                    fsd_left -= 1
                    ins.iss2 = cyc
                    if ins.iss is not None:
                        ins.done = max(ins.iss, ins.iss2) + 1
                    continue
                keep.append(e)
                continue
            if fpu_free and all(ready(p, cyc) for p in ins.prod):
                fpu_free = False
                ins.iss = cyc
                fpu_ops += 1
                kd = ins.kind
                if kd.startswith(('fdiv', 'fsqrt')):
                    eng = 128 if kd == 'fdivd' else 64
                    ins.ready = ins.done = cyc + eng + lat
                    fpu_busy_until = cyc + eng + 2
                elif kd == 'f2i':
                    ins.ready = ins.done = cyc + lat + 1
                else:
                    ins.ready = ins.done = cyc + lat
                continue
            keep.append(e)
        fq = keep
        # dispatch
        k = 0
        while k < W and nxt < n:
            ins = tr[nxt]
            kd = ins.kind
            need_iq = 2 if kd == 'st' else 1 if kd != 'fpu' and not kd.startswith(('fdiv', 'fsqrt', 'f2i')) else 0
            need_fq = 1 if kd in ('fpu', 'f2i', 'fst') or kd.startswith(('fdiv', 'fsqrt')) else 0
            why = None
            if len(rob) >= o['rob']:
                why = 'rob'
            elif len(iq) + need_iq > o['iq']:
                why = 'iq'
            elif len(fq) + need_fq > o['fq']:
                why = 'fq'
            elif kd in ('ld', 'fld') and lq >= o['lq']:
                why = 'lq'
            elif kd in ('st', 'fst') and sq >= o['sq']:
                why = 'sq'
            elif ins.dst and inflight[ins.dst[0]] >= (o['ireg'] if ins.dst[0] == 'i' else o['freg']) - 32:
                why = 'ireg' if ins.dst[0] == 'i' else 'freg'
            elif kd == 'br' and ck >= o['ckpt']:
                why = 'ckpt'
            if why:
                if k == 0:
                    stall[why] = stall.get(why, 0) + 1
                break
            ins.disp = cyc
            rob.append(ins)
            if ins.dst:
                inflight[ins.dst[0]] += 1
            if kd in ('ld', 'fld'):
                lq += 1
            if kd in ('st', 'fst'):
                sq += 1
            if kd == 'br':
                ck += 1
            if kd == 'st':
                iq.append([ins, 0])
                iq.append([ins, 1])
            elif kd == 'fst':
                iq.append([ins, 0])
                fq.append([ins, 1])
            elif need_fq:
                fq.append([ins, 0])
            else:
                iq.append([ins, 0])
            nxt += 1
            k += 1
            if ins.taken:
                break
        cyc += 1
        if cyc > 50 * n + 1000:
            raise SystemExit('fpsched: no progress')
    return cyc, fpu_ops, stall


DEF = dict(w=4, cw=4, rob=48, iq=24, fq=16, lq=16, sq=16, ireg=80, freg=64, ckpt=12, lat=9, fsd_w=1)

if __name__ == '__main__':
    path, ks, ke = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
    o = dict(DEF)
    for a in sys.argv[4:]:
        k, v = a.split('=')
        o[k] = int(v)
    tr = load(path, ks, ke)
    cyc, fops, stall = run(tr, o)
    fma = sum(1 for i in tr if i.kind == 'fpu')
    st = ' '.join('%s %d' % (k, v) for k, v in sorted(stall.items(), key=lambda x: -x[1]))
    print('insns %d cycles %d IPC %.2f FPU ops %d (%.3f a cycle) stalls: %s' % (len(tr), cyc, len(tr) / cyc, fops, fops / cyc, st))
