#!/usr/bin/env python3
# parse.py : the caches' misses of each configuration (results/<cfg>_<boot|work>.txt); the workload = work - boot
import re, sys, glob, os
def stats(f):
    d = {}
    for l in open(f, errors='replace'):
        m = re.match(r'(L2\$|D\$|I\$) (.+?):\s+([0-9.]+)', l)
        if m: d[(m.group(1), m.group(2))] = float(m.group(3))
    return d
cfgs = sys.argv[1:] or ['base', 'i16', 'i64', 'i64s', 'i128s', 'd32', 'd32s', 'd64', 'l512', 'l512w8', 'l1m', 'big', 'big2', 'd64s', 'rec', 'rec512', 'rec1m', 'bbase', 'brec', 'brec512', 'brec1m']
# penalties (cycles, my estimates for OOO_CPU at 50 MHz): an L1 miss that hits the L2, an L2 miss (the board's DDR3)
P1, PM = 15, 40
print('%-7s %8s | %8s %8s %8s %8s | %7s %7s %7s | %s' % ('cfg', 'part', 'insns M', 'I$ mis', 'D$ mis', 'L2 mis', 'I MPKI', 'D MPKI', 'L2MPKI', 'stall/insn'))
for c in cfgs:
    r = {}
    for part in ('work', 'boot'):
        f = 'results/%s_%s.txt' % (c, part)
        if os.path.exists(f): r[part] = stats(f)
    if 'work' in r and 'boot' in r and r['work'] and r['boot']:
        r['diff'] = {k: r['work'][k] - r['boot'].get(k, 0) for k in r['work']}
    for part in ('boot', 'diff'):
        if part not in r or not r[part]: continue
        d = r[part]
        n = d[('I$', 'Read Accesses')]
        im = d[('I$', 'Read Misses')]; dm = d[('D$', 'Read Misses')] + d[('D$', 'Write Misses')]
        lm = d[('L2$', 'Read Misses')] + d[('L2$', 'Write Misses')]
        st = ((im + dm) * P1 + lm * PM) / n
        print('%-7s %8s | %8.1f %8.2f %8.2f %8.2f | %7.2f %7.2f %7.2f | %.3f' % (c, part, n / 1e6, im / 1e6, dm / 1e6, lm / 1e6,
              1000 * im / n, 1000 * dm / n, 1000 * lm / n, st))
