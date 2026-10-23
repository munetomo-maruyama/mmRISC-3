#!/usr/bin/env python3
#---------------------------------------------------------------------------
# capture.py : the timed part of CoreMark from Spike's log, as a compact
# trace
#
#   spike -l --log-commits --isa=... x.elf 2>&1 >/dev/null | capture.py out.trace.gz
#
# Spike prints two lines per instruction: the disassembly (-l) and the
# commit (--log-commits: register written, memory address). Only the part
# between the two reads of minstret (start_time / stop_time of
# core_portme.c) is kept, so the trace holds exactly the instructions that
# icount.sh counts.
#
# One line per instruction, tab separated:
#   pc  instruction(hex)  disassembly  register written  memory address
# (pc and addresses in hex, the register as x<n> / f<n>, "-" if none)
#---------------------------------------------------------------------------
import gzip
import re
import sys

RE_DIS = re.compile(r'^core\s+\d+: 0x([0-9a-f]+) \(0x([0-9a-f]+)\) (.*)$')
RE_COM = re.compile(r'^core\s+\d+: \d+ 0x([0-9a-f]+) \(0x([0-9a-f]+)\)(.*)$')
RE_REG = re.compile(r'^\s*([xf])\s*(\d+)\s+0x[0-9a-f]+')
RE_MEM = re.compile(r'mem 0x([0-9a-f]+)')


def main():
    out = gzip.open(sys.argv[1], 'wt', compresslevel=1)
    state = 0               # 0 before, 1 inside, 2 after the timed part
    pend = None             # the disassembly waiting for its commit line
    n = 0
    for line in sys.stdin:
        m = RE_DIS.match(line)
        if m:
            pc, ins, dis = m.group(1), m.group(2), m.group(3).strip()
            if 'minstret' in dis and dis.startswith('csrr'):
                state += 1
                pend = None
                if state == 2:
                    break
                continue
            pend = (pc, ins, dis) if state == 1 else None
            continue
        m = RE_COM.match(line)
        if m and pend is not None:
            if m.group(1) != pend[0]:
                sys.exit(f'commit of {m.group(1)} after disassembly of {pend[0]}')
            rest = m.group(3)
            r = RE_REG.match(rest)
            reg = f'{r.group(1)}{r.group(2)}' if r else '-'
            mm = RE_MEM.search(rest)
            mem = mm.group(1).lstrip('0') or '0' if mm else '-'
            out.write(f'{pend[0].lstrip("0")}\t{pend[1]}\t{pend[2]}\t{reg}\t{mem}\n')
            pend = None
            n += 1
    out.close()
    if state < 2:
        sys.exit(f'timed part not closed (state {state}, {n} instructions)')
    print(f'{n} instructions')


if __name__ == '__main__':
    main()
