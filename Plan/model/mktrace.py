#!/usr/bin/env python3
#---------------------------------------------------------------------------
# mktrace.py : a trace of capture.py (text) as fixed records for the cycle
# model (binary)
#
#   mktrace.py ../trace/work/<build>.trace.gz work/<build>.bin
#
# The decoding is the one of ../trace/analyze.py (load_trace), so the model
# and the trace analysis see the same instructions. One record of 32 bytes
# per instruction (little endian, struct Rec of model.h):
#
#   u64 pc, u64 mem (0: none), u8 size, u8 cls, u8 sub, u8 flags,
#   u8 src[3] (255: none), u8 dst (255: none), u8 base (255: none),
#   u8 op, u16 pad, u32 pad
#
#   cls  : 0 alu 1 br 2 jal 3 jalr 4 load 5 store 6 mul 7 div 8 sys 9 fp
#   sub  : 0 - 1 shift 2 zba 3 zbb 4 zbs 5 zicond
#   flags: bit0 taken (the next pc is not pc + size), bit1 call, bit2 return,
#          bit3 MULH family (2-cycle multiply in mmRISC-2)
#   op   : 0 other 1 lui 2 auipc 3 slli 4 srli / srai 5 add / sh*add (two
#          registers) 6 addi
#---------------------------------------------------------------------------
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'trace'))
import analyze as A   # noqa: E402

CLS = {'alu': 0, 'br': 1, 'jal': 2, 'jalr': 3, 'load': 4, 'store': 5, 'mul': 6, 'div': 7,
       'sys': 8, 'fp': 9}
SUB = {'': 0, 'shift': 1, 'zba': 2, 'zbb': 3, 'zbs': 4, 'zicond': 5}
LINK = (1, 5)   # ra, t0: the registers of calls and returns (RISC-V hint convention)


def op_of(mn):
    m = mn[2:] if mn.startswith('c.') else mn
    if m == 'lui':
        return 1
    if m == 'auipc':
        return 2
    if m in ('slli', 'slliw'):
        return 3
    if m in ('srli', 'srai', 'srliw', 'sraiw'):
        return 4
    if m in ('add', 'addw') or m.startswith('sh') and m.endswith(('add', 'add.uw')) or m == 'add.uw':
        return 5
    if m in ('addi', 'addiw'):
        return 6
    return 0


def main():
    tr = A.load_trace(sys.argv[1])
    taken = A.taken_flags(tr)
    with open(sys.argv[2], 'wb') as f:
        for i, x in enumerate(tr):
            fl = 1 if taken[i] else 0
            if x.cls in ('jal', 'jalr') and x.dst in LINK:
                fl |= 2
            if x.cls == 'jalr' and x.dst is None and len(x.srcs) == 1 and x.srcs[0] in LINK:
                fl |= 4
            if x.mn in ('mulh', 'mulhsu', 'mulhu', 'clmulh', 'clmulr'):
                fl |= 8
            src = list(x.srcs[:3]) + [255] * (3 - len(x.srcs[:3]))
            f.write(struct.pack('<QQBBBB3BBBBHI', x.pc, x.mem or 0, x.size, CLS[x.cls],
                                SUB[x.sub], fl, *src,
                                255 if x.dst is None else x.dst,
                                255 if x.base is None else x.base,
                                op_of(x.mn), 0, 0))
    print(f'{len(tr)} records')


if __name__ == '__main__':
    main()
