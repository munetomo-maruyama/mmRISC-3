#!/usr/bin/env python3
#---------------------------------------------------------------------------
# gen_b2.py : B2's test programs (Plan/CORE.md 5.4): random programs with
# ALU instructions only, no memory, ending at the symbol `pass` (a jump to
# itself; tb_core -exit pass). Every register is set first (li), so that
# the lock-step compares every value from the start.
#
#   ./gen_b2.py <kind> <seed> <n> > prog.S
#     alu    n random ALU instructions (RV64I, Zba, Zbb, Zbs, Zicond; the
#            assembler compresses what it can)
#     br     n segments: ALU instructions, forward conditional branches on
#            the random values, counted loops (nested), jal forward, calls
#            (jal, c.jalr, jalr with an offset, through x1 and x5) and
#            returns, indirect jumps (c.jr, jalr with an offset), bursts of
#            branches behind a chain of dependent instructions (the
#            checkpoints run out: renaming takes 1 µop of 2), runs of
#            instructions only ALU0 has (port 1 idle), branches on an
#            xorshift state (half of them mispredicted); x1, x3 to x7, x30
#            and x31 are kept for them
#     ls     (B3) the same, and loads and stores of every size into a 24 KB
#            buffer through seven bases (x9 at its start for the compressed
#            forms, x28 2 KB in, x23 to x27 4 KB apart from there: more
#            lines on a set of the D$ than it has ways, so lines are evicted
#            and written back): stores and loads of the same word soon after each
#            other (forwarding), smaller stores under larger loads (a store
#            that does not cover the load: it waits), values passed through
#            memory to dependent loads (or to x0, read at once: tag 0), bursts
#            of stores (the SQ fills); multiplies after divides or mulh now and
#            then (to x0 too, then x0 read)
#     fp     (step 1.8 U2, Plan/OOC.md 29.82) ls's program with FP segments
#            as well (mstatus.FS on, every f register set first): FP
#            operations single and double with every rounding mode (dynamic
#            too; frm written by fsrmi now and then, a CSR write that replays),
#            chains on a few registers and FMAs (OOO_FIQ fills), divides and
#            square roots (the FPU held), FP -> integer results (compares,
#            fclass, fmv.x, fcvt to integers; to x0 too) and branches on
#            them (mispredicted with FP µops in flight), int -> FP (fmv.*.x,
#            fcvt from integers), FP loads and stores of both sizes (c.fld /
#            c.fsd through x9), an FP store then a load of the same word (FP
#            or integer; an integer store then an FP load), bursts of FP
#            stores (port B), fflags read and written
#---------------------------------------------------------------------------
import random, sys

R3 = ['add', 'sub', 'sll', 'slt', 'sltu', 'xor', 'srl', 'sra', 'or', 'and', 'addw', 'subw', 'sllw', 'srlw', 'sraw',
      'sh1add', 'sh2add', 'sh3add', 'add.uw', 'sh1add.uw', 'sh2add.uw', 'sh3add.uw',
      'andn', 'orn', 'xnor', 'max', 'maxu', 'min', 'minu', 'rol', 'ror', 'rolw', 'rorw',
      'bclr', 'bext', 'binv', 'bset', 'czero.eqz', 'czero.nez']
RI = [('addi', 12), ('slti', 12), ('sltiu', 12), ('xori', 12), ('ori', 12), ('andi', 12), ('addiw', 12)]
P0 = [('slli', 6), ('srli', 6), ('srai', 6), ('rori', 6), ('bseti', 6), ('binvi', 6)]   # ALU0 only (G0b L7)
P0R = ['clz', 'ctz', 'cpop', 'rev8', 'orc.b', 'sext.b']
SH = [('slli', 6), ('srli', 6), ('srai', 6), ('slliw', 5), ('srliw', 5), ('sraiw', 5), ('rori', 6), ('roriw', 5),
      ('slli.uw', 6), ('bclri', 6), ('bexti', 6), ('binvi', 6), ('bseti', 6)]
R2 = ['clz', 'ctz', 'cpop', 'clzw', 'ctzw', 'cpopw', 'sext.b', 'sext.h', 'zext.h', 'rev8', 'orc.b', 'mv', 'neg', 'not']
BR = ['beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu', 'beqz', 'bnez']
FR = ['f%d' % i for i in range(32)]
FFEW = ['f%d' % i for i in range(8, 16)]
RMS = ['', '', '', '', 'rne', 'rtz', 'rdn', 'rup', 'rmm', 'dyn']


def fpop(rnd):
    # an FP operation on FP registers (single or double), its rounding mode at random
    fmt = rnd.choice(['s', 'd'])
    fp = lambda: rnd.choice(FFEW) if rnd.random() < 0.7 else rnd.choice(FR)
    rm = rnd.choice(RMS)
    rms = (', ' + rm) if rm else ''
    k = rnd.random()
    if k < 0.35:
        return '%s.%s %s, %s, %s%s' % (rnd.choice(['fadd', 'fsub', 'fmul']), fmt, fp(), fp(), fp(), rms)
    if k < 0.60:
        return '%s.%s %s, %s, %s, %s%s' % (rnd.choice(['fmadd', 'fmsub', 'fnmadd', 'fnmsub']), fmt, fp(), fp(), fp(), fp(), rms)
    if k < 0.75:
        return '%s.%s %s, %s, %s' % (rnd.choice(['fmin', 'fmax', 'fsgnj', 'fsgnjn', 'fsgnjx']), fmt, fp(), fp(), fp())
    if k < 0.85:
        return 'fcvt.s.d %s, %s%s' % (fp(), fp(), rms) if rnd.random() < 0.5 else 'fcvt.d.s %s, %s' % (fp(), fp())
    if k < 0.93:
        return 'fdiv.%s %s, %s, %s%s' % (fmt, fp(), fp(), fp(), rms)
    if k < 0.97:
        return 'fsqrt.%s %s, %s%s' % (fmt, fp(), fp(), rms)
    return 'fmv.%s %s, %s' % (fmt, fp(), fp())


def f2i(rnd, xd, fs):
    fmt = rnd.choice(['s', 'd'])
    k = rnd.random()
    if k < 0.35:
        return '%s.%s %s, %s, %s' % (rnd.choice(['feq', 'flt', 'fle']), fmt, xd, fs, rnd.choice(FR))
    if k < 0.45:
        return 'fclass.%s %s, %s' % (fmt, xd, fs)
    if k < 0.60:
        return 'fmv.x.%s %s, %s' % ('w' if fmt == 's' else 'd', xd, fs)
    rm = rnd.choice(RMS)
    return 'fcvt.%s.%s %s, %s%s' % (rnd.choice(['w', 'wu', 'l', 'lu']), fmt, xd, fs, (', ' + rm) if rm else '')


def i2f(rnd, fd, xs):
    fmt = rnd.choice(['s', 'd'])
    if rnd.random() < 0.4:
        return 'fmv.%s.x %s, %s' % ('w' if fmt == 's' else 'd', fd, xs)
    src = rnd.choice(['w', 'wu', 'l', 'lu'])
    rm = '' if fmt == 'd' and src in ('w', 'wu') else rnd.choice(RMS)    # (exact: no rounding mode)
    return 'fcvt.%s.%s %s, %s%s' % (fmt, src, fd, xs, (', ' + rm) if rm else '')


def alu(rnd, regs, few=None):
    # few: the registers to use most of the time (so that values pass on and short RVC forms come)
    pick = lambda: rnd.choice(few) if few and rnd.random() < 0.7 else rnd.choice(regs)
    d, a, b = pick(), pick(), pick()
    k = rnd.random()
    if k < 0.40:
        return '%s %s, %s, %s' % (rnd.choice(R3), d, a, b)
    if k < 0.60:
        op, w = rnd.choice(RI)
        return '%s %s, %s, %d' % (op, d, a, rnd.randint(-(1 << (w - 1)), (1 << (w - 1)) - 1))
    if k < 0.75:
        op, w = rnd.choice(SH)
        return '%s %s, %s, %d' % (op, d, a, rnd.randint(0, (1 << w) - 1))
    if k < 0.85:
        return '%s %s, %s' % (rnd.choice(R2), d, a)
    if k < 0.92:
        return 'lui %s, %d' % (d, rnd.randint(0, (1 << 20) - 1))
    if k < 0.96:
        return 'auipc %s, %d' % (d, rnd.randint(0, (1 << 20) - 1))
    return 'li %s, %d' % (d, rnd.randint(-32, 31))       # c.li


def main():
    kind, seed, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    rnd = random.Random(seed)
    out = ['    .section .text.init', '    .globl _start', '_start:']
    for r in range(1, 32):
        out.append('    li x%d, %d' % (r, rnd.getrandbits(64) - (1 << 63)))
    if kind == 'fp':                                       # FS on (dirty), every f register set (a value, or random bits)
        out += ['    li x1, 0x6000', '    csrs mstatus, x1']
        for r in range(32):
            if r % 3 == 0:
                out.append('    fmv.d.x f%d, x%d' % (r, rnd.randint(1, 31)))
            else:
                out.append('    li x1, %d' % rnd.randint(-1000, 1000))
                out.append('    fcvt.%s.l f%d, x1' % (rnd.choice('sd'), r))
        out.append('    li x1, %d' % (rnd.getrandbits(64) - (1 << 63)))
    if kind == 'alu':
        regs = ['x%d' % r for r in range(1, 32)]
        few = ['x8', 'x9', 'x10', 'x11', 'x12', 'x13', 'x14', 'x15']
        for _ in range(n):
            out.append('    ' + alu(rnd, regs, few))
        out += ['    .globl pass', 'pass:', '    j pass']
    else:
        BASES = ['x9', 'x28', 'x27', 'x26', 'x25', 'x24', 'x23']
        mem = kind in ('ls', 'fp')
        regs = ['x%d' % r for r in range(2, 30) if r not in (3, 4, 5, 6, 7) + ((9, 28, 27, 26, 25, 24, 23) if mem else ())]
        LD = [('ld', 8), ('lw', 4), ('lwu', 4), ('lh', 2), ('lhu', 2), ('lb', 1), ('lbu', 1)]
        ST = [('sd', 8), ('sw', 4), ('sh', 2), ('sb', 1)]

        def mem_off(base, sz):                       # an aligned offset inside the buffer
            if base == 'x9':
                return rnd.randrange(0, 256, max(sz, 4) if sz >= 4 else sz)
            return rnd.randrange(-2048, 2047 - sz + 1, sz) // sz * sz

        def memop(store):
            base = rnd.choice(BASES)
            op, sz = rnd.choice(ST if store else LD)
            return '    %s %s, %d(%s)' % (op, rnd.choice(few if base == 'x9' else regs), mem_off(base, sz), base)
        few = [r for r in ['x8', 'x9', 'x10', 'x11', 'x12', 'x13', 'x14', 'x15'] if r in regs]   # (x9 is a base in ls)
        lab = [0]
        funcs = []

        def new():
            lab[0] += 1
            return 'L%d' % lab[0]

        def seg(depth):
            body = []
            for _ in range(rnd.randint(1, 4)):
                body.append('    ' + alu(rnd, regs, few))
            if kind == 'fp' and rnd.random() < 0.5:
                body += fpseg()
            if mem and rnd.random() < 0.15:                # a multiply (OOO_PMUL), to x0 now and then, x0 read soon
                if rnd.random() < 0.5:                     # after an MDU µop (OOO_MDUP: its result and the multiply's meet)
                    body.append('    %s %s, %s, %s' % (rnd.choice(['div', 'divu', 'rem', 'remu', 'divw', 'remuw', 'mulh', 'mulhu']),
                                                      'x0' if rnd.random() < 0.3 else rnd.choice(few), rnd.choice(regs), rnd.choice(regs)))
                body.append('    %s %s, %s, %s' % (rnd.choice(['mul', 'mulw']), 'x0' if rnd.random() < 0.4 else rnd.choice(few),
                                                  rnd.choice(regs), rnd.choice(regs)))
                for _ in range(rnd.randint(0, 2)):
                    body.append('    ' + alu(rnd, regs, few))
                body.append('    add %s, x0, %s' % (rnd.choice(regs), rnd.choice(regs)))
            if mem and rnd.random() < 0.5:                 # memory
                m = rnd.random()
                base = rnd.choice(BASES)
                if m < 0.3:                                # a few loads and stores at random
                    for _ in range(rnd.randint(1, 5)):
                        body.append(memop(rnd.random() < 0.5))
                elif m < 0.55:                             # store, then load the same word soon after (forwarding, or a wait)
                    sop, ssz = rnd.choice(ST)
                    o = mem_off(base, 8)
                    so = o + rnd.randrange(0, 8, ssz)
                    body.append('    %s %s, %d(%s)' % (sop, rnd.choice(few if base == 'x9' else regs), so, base))
                    for _ in range(rnd.randint(0, 3)):
                        body.append('    ' + alu(rnd, regs, few))
                    lop, lsz = rnd.choice(LD)
                    body.append('    %s %s, %d(%s)' % (lop, rnd.choice(regs), o + rnd.randrange(0, 8, lsz), base))
                elif m < 0.75:                             # a value through memory to a dependent load and its user
                    r = rnd.choice(few)
                    o = mem_off(base, 8)
                    body.append('    sd %s, %d(%s)' % (r, o, base))
                    if rnd.random() < 0.25:                # or to x0 (tag 0) and a reader of x0 at once
                        r = 'x0'
                    body.append('    ld %s, %d(%s)' % (r, o, base))
                    body.append('    add %s, %s, %s' % (rnd.choice(regs), r, rnd.choice(regs)))
                else:                                      # a burst of stores (the SQ fills), then loads
                    for _ in range(rnd.randint(6, 12)):
                        body.append(memop(True))
                    for _ in range(rnd.randint(1, 4)):
                        body.append(memop(False))
                return body
            k = rnd.random()
            if k < 0.35:                                   # a forward branch over a few instructions
                l = new()
                op = rnd.choice(BR)
                a, b = rnd.choice(regs), rnd.choice(regs)
                body.append('    %s %s, %s' % (op, a, l) if op in ('beqz', 'bnez') else '    %s %s, %s, %s' % (op, a, b, l))
                for _ in range(rnd.randint(0, 5)):
                    body.append('    ' + alu(rnd, regs, few))
                body.append(l + ':')
            elif k < 0.50 and depth < 2:                   # a counted loop (x31 / x30 by depth)
                c = 'x31' if depth == 0 else 'x30'
                l = new()
                body.append('    li %s, %d' % (c, rnd.randint(1, 12)))
                body.append(l + ':')
                for _ in range(rnd.randint(1, 3)):
                    body += seg(depth + 1)
                body.append('    addi %s, %s, -1' % (c, c))
                body.append('    bnez %s, %s' % (c, l))
            elif k < 0.60:                                 # jal forward
                l = new()
                body.append('    j ' + l)
                for _ in range(rnd.randint(0, 3)):
                    body.append('    ' + alu(rnd, regs, few))
                body.append(l + ':')
            elif k < 0.70:                                 # a call: jal, c.jalr or jalr with an offset; link x1 or x5
                f = 'F%d' % len(funcs)
                link = rnd.choice(['x1', 'x1', 'x5'])
                funcs.append((f, link))
                tmp = 'x6' if link == 'x5' else 'x7'
                w = rnd.random()
                if w < 0.4:
                    body.append('    jal %s, %s' % (link, f))
                elif w < 0.6 and link == 'x1':
                    body.append('    la %s, %s' % (tmp, f))
                    body.append('    jalr %s' % tmp)                         # c.jalr
                elif w < 0.7 and link == 'x1':
                    body.append('    la x5, %s' % f)                         # through the other link register:
                    body.append('    jalr x1, 0(x5)')                        # a call, not a return
                else:
                    o = rnd.choice([-2047, -100, -6, 4, 22, 2046])
                    body.append('    la %s, %s' % (tmp, f))
                    body.append('    addi %s, %s, %d' % (tmp, tmp, -o))
                    body.append('    jalr %s, %d(%s)' % (link, o, tmp))
            elif k < 0.76 and depth == 0:                  # an indirect jump forward: c.jr or jalr with an offset
                l = new()
                body.append('    la x7, ' + l)
                if rnd.random() < 0.5:
                    body.append('    jr x7')
                else:
                    o = rnd.choice([-64, -2, 10, 1000])
                    body.append('    addi x7, x7, %d' % -o)
                    body.append('    jalr x0, %d(x7)' % o)
                for _ in range(rnd.randint(0, 3)):
                    body.append('    ' + alu(rnd, regs, few))
                body.append(l + ':')
            elif k < 0.84:                                 # a burst of branches behind a dependent chain
                r = rnd.choice(few)
                for _ in range(rnd.randint(2, 8)):
                    body.append('    %s %s, %s, %s' % (rnd.choice(['add', 'xor', 'sub', 'or']), r, r, rnd.choice(regs)))
                for _ in range(rnd.randint(3, 9)):
                    l = new()
                    op = rnd.choice(['beq', 'bne', 'blt', 'bgeu'])
                    body.append('    %s %s, %s, %s' % (op, r, rnd.choice(['x0', rnd.choice(regs)]), l))
                    if rnd.random() < 0.4:
                        body.append('    ' + alu(rnd, regs, few))
                    body.append(l + ':')
            elif k < 0.90:                                 # a run that only ALU0 can take (long enough for registers to come round)
                for _ in range(rnd.randint(8, 24) if rnd.random() < 0.7 else rnd.randint(40, 90)):
                    d, a = rnd.choice(regs), rnd.choice(regs)
                    if rnd.random() < 0.7:
                        op, w = rnd.choice(P0)
                        body.append('    %s %s, %s, %d' % (op, d, a, rnd.randint(0, (1 << w) - 1)))
                    else:
                        body.append('    %s %s, %s' % (rnd.choice(P0R), d, a))
            else:                                          # a branch on an xorshift bit: half mispredicted
                l = new()
                body += ['    slli x4, x3, 13', '    xor x3, x3, x4', '    srli x4, x3, 7', '    xor x3, x3, x4',
                         '    slli x4, x3, 17', '    xor x3, x3, x4', '    andi x4, x3, %d' % (1 << rnd.randint(0, 9))]
                body.append('    beqz x4, ' + l)
                for _ in range(rnd.randint(1, 6)):
                    body.append('    ' + alu(rnd, regs, few))
                body.append(l + ':')
            return body

        def fpseg():                                   # the FP side (kind fp)
            body = []
            fp = lambda: rnd.choice(FFEW) if rnd.random() < 0.7 else rnd.choice(FR)
            k = rnd.random()
            if k < 0.30:                                   # FP operations, chains on a few registers
                for _ in range(rnd.randint(1, 8)):
                    body.append('    ' + fpop(rnd))
            elif k < 0.42:                                 # an FP -> integer result, used, a branch on it (mispredicted often)
                l = new()
                xd = 'x0' if rnd.random() < 0.15 else rnd.choice(few)
                body.append('    ' + f2i(rnd, xd, fp()))
                body.append('    add %s, %s, %s' % (rnd.choice(regs), xd, rnd.choice(regs)))
                body.append('    %s %s, %s' % (rnd.choice(['beqz', 'bnez']), xd, l))
                for _ in range(rnd.randint(0, 4)):
                    body.append('    ' + (fpop(rnd) if rnd.random() < 0.6 else alu(rnd, regs, few)))
                body.append(l + ':')
            elif k < 0.52:                                 # int -> FP, used
                f = fp()
                body.append('    ' + i2f(rnd, f, rnd.choice(regs)))
                body.append('    fadd.d %s, %s, %s' % (fp(), f, fp()))
            elif k < 0.60:                                 # a divide or square root, work behind it (the FPU held)
                fmt = rnd.choice('sd')
                if rnd.random() < 0.7:
                    body.append('    fdiv.%s %s, %s, %s' % (fmt, fp(), fp(), fp()))
                else:
                    body.append('    fsqrt.%s %s, %s' % (fmt, fp(), fp()))
                for _ in range(rnd.randint(1, 6)):
                    body.append('    ' + (fpop(rnd) if rnd.random() < 0.5 else f2i(rnd, rnd.choice(few), fp())))
            elif k < 0.78:                                 # FP loads and stores
                base = rnd.choice(BASES)
                m = rnd.random()
                if m < 0.35:
                    for _ in range(rnd.randint(1, 5)):
                        sz = rnd.choice([4, 8])
                        op = ('fsw' if sz == 4 else 'fsd') if rnd.random() < 0.5 else ('flw' if sz == 4 else 'fld')
                        body.append('    %s %s, %d(%s)' % (op, rnd.choice(FFEW) if base == 'x9' else fp(), mem_off(base, sz), base))
                elif m < 0.65:                             # an FP store, then a load of the same word (FP or integer)
                    sz = rnd.choice([4, 8])
                    o = mem_off(base, 8)
                    body.append('    %s %s, %d(%s)' % ('fsw' if sz == 4 else 'fsd', fp(), o, base))
                    for _ in range(rnd.randint(0, 2)):
                        body.append('    ' + fpop(rnd))
                    if rnd.random() < 0.5:
                        body.append('    %s %s, %d(%s)' % ('flw' if sz == 4 else 'fld', fp(), o, base))
                    else:
                        lop, lsz = rnd.choice(LD)
                        body.append('    %s %s, %d(%s)' % (lop, rnd.choice(regs), o + rnd.randrange(0, sz, lsz) if lsz <= sz else o, base))
                elif m < 0.80:                             # an integer store, then an FP load of it, used
                    o = mem_off(base, 8)
                    body.append('    sd %s, %d(%s)' % (rnd.choice(regs), o, base))
                    f = fp()
                    body.append('    %s %s, %d(%s)' % (rnd.choice(['fld', 'flw']), f, o, base))
                    body.append('    fmul.d %s, %s, %s' % (fp(), f, fp()))
                else:                                      # a burst of FP stores (port B), the results of FMAs
                    for _ in range(rnd.randint(4, 10)):
                        if rnd.random() < 0.4:
                            body.append('    ' + fpop(rnd))
                        sz = rnd.choice([4, 8])
                        body.append('    %s %s, %d(%s)' % ('fsw' if sz == 4 else 'fsd', fp(), mem_off(base, sz), base))
            elif k < 0.86:                                 # fflags read (and written), compared at the CSR read
                body.append('    frflags %s' % rnd.choice(few))
                if rnd.random() < 0.3:
                    body.append('    fsflags %s' % rnd.choice(['x0', rnd.choice(regs)]))
            elif k < 0.90:                                 # frm (a CSR write: what follows replays), a valid mode
                body.append('    fsrmi %d' % rnd.randint(0, 4))
            else:                                          # FP results through moves to integer and back
                f, x = fp(), rnd.choice(few)
                body.append('    fmv.x.d %s, %s' % (x, f))
                body.append('    xor %s, %s, %s' % (x, x, rnd.choice(regs)))
                body.append('    fmv.d.x %s, %s' % (fp(), x))
            return body

        if mem:
            out += ['    la x9, buf', '    la x28, buf + 2048'] + ['    la x%d, buf + %d' % (27 - k, 2048 + 4096 * (k + 1)) for k in range(5)]
        for _ in range(n):
            out += seg(0)
        out += ['    .globl pass', 'pass:', '    j pass']
        for f, link in funcs:                              # the functions: a few ALU instructions and a return
            out.append(f + ':')
            for _ in range(rnd.randint(0, 6)):
                out.append('    ' + alu(rnd, regs, few))
            out.append('    jr %s' % link)                 # (a return: c.jr ra / jalr x0, 0(t0))
    out += ['    .section .tohost, "aw", @progbits', '    .align 6', '    .globl tohost', 'tohost: .dword 0',
            '    .globl fromhost', 'fromhost: .dword 0']
    if kind in ('ls', 'fp'):                               # the buffer, filled with random words
        out += ['    .section .data', '    .align 6', 'buf:'] + ['    .dword %d' % rnd.getrandbits(64) for _ in range(3072)]
    print('\n'.join(out))


if __name__ == '__main__':
    main()
