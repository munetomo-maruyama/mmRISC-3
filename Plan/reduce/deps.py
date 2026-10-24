#!/usr/bin/env python3
#---------------------------------------------------------------------------
# deps.py : TOP and the modules it instantiates, out of one Verilog file
#
#   deps.py work/mmrisc2.v TOP > work/TOP.v
#
# Yosys reads every module it is given and cannot parse all of mmRISC-2
# after sv2v (e.g. CORE_FRF), so each synthesis gets only what it needs.
#---------------------------------------------------------------------------
import re
import sys

src = open(sys.argv[1]).read()
mods = {m.group(1): m.group(0)
        for m in re.finditer(r'^module (\w+)\b.*?^endmodule', src, re.S | re.M)}
need, todo = [], [sys.argv[2]]
while todo:
    t = todo.pop()
    if t in need:
        continue
    need.append(t)
    todo += [m for m in mods if m != t and re.search(r'^\s*' + m + r'\b', mods[t], re.M)]
print('\n\n'.join(mods[m] for m in reversed(need)))
