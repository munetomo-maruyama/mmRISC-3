#!/usr/bin/env python3
#---------------------------------------------------------------------------
# mkfuse.py : the static fields OOO_FUSE sees, for every instruction of a
# CoreMark trace, for tb_fuse (trace mode)
#
#   mkfuse.py ../../Plan/trace/work/<build>.trace.gz obj_dir/<build>.fuse
#
# One line per instruction:
#   seq cls op rd rs1 rs2 use_rs1 use_rs2 imm msize
# seq is 0 when the instruction before it transferred control (a taken
# branch or jump: it is not in the same run of the fetch). The first line
# gives the number of pairs the model forms on the same stream
# (Plan/trace/analyze.py fused_pairs, all kinds, greedy over the whole
# stream), the number the window of 4 of the hardware is held against.
#---------------------------------------------------------------------------
import gzip
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'Plan', 'trace'))
import analyze as A   # noqa: E402

CLS = {'alu': 0, 'br': 1, 'jal': 2, 'jalr': 3, 'load': 4, 'store': 5, 'mul': 6, 'div': 6,
       'sys': 7, 'fp': 7}
SIZE = {'b': 0, 'h': 1, 'w': 2, 'd': 3}


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
    if m in ('add', 'addw', 'add.uw') or (m.startswith('sh') and 'add' in m):
        return 5
    if m in ('addi', 'addiw'):
        return 6
    return 0


def msize(mn):
    m = mn[2:] if mn.startswith('c.') else mn
    m = m.replace('sp', '')
    for ch in m[1:]:
        if ch in SIZE:
            return SIZE[ch]
    return 3


def main():
    tr = A.load_trace(sys.argv[1])
    taken = A.taken_flags(tr)
    allk = {'lui+addi', 'auipc+x', 'slli+srli', 'alu+load(addr)', 'load+load(pair)',
            'store+store(pair)', 'alu+branch', 'alu+alu'}
    model_pairs = sum(A.fused_pairs(tr, allk))
    offs = []
    with gzip.open(sys.argv[1], 'rt') as f:
        for line in f:
            dis = line.split('\t')[2]
            m = re.search(r'(-?\d+)\((\w+)\)', dis)
            offs.append(int(m.group(1)) if m else 0)
    with open(sys.argv[2], 'w') as f:
        f.write(f'{len(tr)} {model_pairs}\n')
        for i, x in enumerate(tr):
            seq = 0 if i == 0 or taken[i - 1] else 1
            cls = CLS[x.cls]
            rd = x.dst if x.dst is not None and x.dst < 32 else 0
            ints = [s for s in x.srcs if s < 32]
            if x.cls == 'load':
                rs1, rs2, u1, u2 = (x.base or 0), 0, 1, 0
            elif x.cls == 'store':
                data = [s for s in ints if s != x.base]
                rs1, rs2, u1, u2 = (x.base or 0), (data[0] if data else 0), 1, 1 if data else 0
            else:
                rs1 = ints[0] if len(ints) > 0 else 0
                rs2 = ints[1] if len(ints) > 1 else 0
                u1, u2 = int(len(ints) > 0), int(len(ints) > 1)
            imm = offs[i] & 0xfff
            ms = msize(x.mn) if x.cls in ('load', 'store') else 0
            f.write(f'{seq} {cls} {op_of(x.mn)} {rd} {rs1} {rs2} {u1} {u2} {imm} {ms}\n')


if __name__ == '__main__':
    main()
