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
#            memory to dependent loads, bursts of stores (the SQ fills)
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
    if kind == 'alu':
        regs = ['x%d' % r for r in range(1, 32)]
        few = ['x8', 'x9', 'x10', 'x11', 'x12', 'x13', 'x14', 'x15']
        for _ in range(n):
            out.append('    ' + alu(rnd, regs, few))
        out += ['    .globl pass', 'pass:', '    j pass']
    else:
        BASES = ['x9', 'x28', 'x27', 'x26', 'x25', 'x24', 'x23']
        regs = ['x%d' % r for r in range(2, 30) if r not in (3, 4, 5, 6, 7) + ((9, 28, 27, 26, 25, 24, 23) if kind == 'ls' else ())]
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
            if kind == 'ls' and rnd.random() < 0.5:        # memory
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

        if kind == 'ls':
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
    if kind == 'ls':                                       # the buffer, filled with random words
        out += ['    .section .data', '    .align 6', 'buf:'] + ['    .dword %d' % rnd.getrandbits(64) for _ in range(3072)]
    print('\n'.join(out))


if __name__ == '__main__':
    main()
