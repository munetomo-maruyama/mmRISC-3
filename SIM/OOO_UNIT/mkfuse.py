#!/usr/bin/env python3
#---------------------------------------------------------------------------
# mkfuse.py : the static fields OOO_FUSE sees, for every instruction of a
# CoreMark trace, for tb_fuse (trace mode)
#
#   mkfuse.py ../../Plan/trace/work/<build>.trace.gz obj_dir/<build>.fuse
#
# One line per instruction:
#   seq cls op rd rs1 rs2 use_rs1 use_rs2 imm msize alu2ok
# seq is 0 when the instruction before it transferred control (a taken
# branch or jump: it is not in the same run of the fetch). The first line
# gives the number of pairs the model forms on the same stream (the kinds
# of Plan/trace/analyze.py fusion_kind, greedy over the whole stream, with
# the limits of 2 sources and 1 write, fuse_2src and fuse_1w of
# Plan/model/ooo.h), the number the
# window of 4 of the hardware is held against. alu2ok: the operation is one
# of the narrowed second stage of OOO_ALU2 (OOO_ALU FULL = 0); the model
# does not limit it, so a pair lost to it shows as a difference.
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


# the narrowed second stage (OOO_ALU FULL = 0): add / sub, sh*add(.uw), the
# logic operations, srl, sext / zext, czero, bext; the pseudo-instructions
# and compressed forms of them
ALU2OK = {'add', 'addw', 'addi', 'addiw', 'add.uw', 'sub', 'subw', 'sh1add', 'sh2add', 'sh3add',
          'sh1add.uw', 'sh2add.uw', 'sh3add.uw', 'xor', 'xori', 'or', 'ori', 'and', 'andi', 'andn',
          'orn', 'xnor', 'srl', 'srli', 'srlw', 'srliw', 'sext.b', 'sext.h', 'zext.h', 'czero.eqz',
          'czero.nez', 'bext', 'bexti', 'mv', 'li', 'lui', 'neg', 'negw', 'not', 'sext.w', 'zext.w',
          'zext.b', 'nop'}


def alu2ok(mn):
    return int((mn[2:] if mn.startswith('c.') else mn) in ALU2OK)


def model_pairs_2src(tr, allk):
    """greedy pairs as analyze.fused_pairs, without pairs reading more than
    2 registers from outside or writing 2 different registers"""
    def nsrc(a, b):
        s = set(r for r in a.srcs if r != 0)
        s |= set(r for r in b.srcs if r != 0 and r != a.dst)
        return len(s)
    n, i = 0, 0
    while i < len(tr) - 1:
        a, b = tr[i], tr[i + 1]
        two_writes = a.dst is not None and b.dst is not None and a.dst != b.dst
        if A.fusion_kind(a, b) in allk and nsrc(a, b) <= 2 and not two_writes:
            n += 1
            i += 2
        else:
            i += 1
    return n


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
    model_pairs = model_pairs_2src(tr, allk)
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
            f.write(f'{seq} {cls} {op_of(x.mn)} {rd} {rs1} {rs2} {u1} {u2} {imm} {ms} {alu2ok(x.mn)}\n')


if __name__ == '__main__':
    main()
