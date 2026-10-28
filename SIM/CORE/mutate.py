#!/usr/bin/env python3
#---------------------------------------------------------------------------
# mutate.py : bug injection into the core's test bench (bench.cc) and the
# lock-step checker's rules it relies on (lockstep.cc)
#
#   ./mutate.py            -> results/mutate.txt
#
# Each mutation is one textual change of a copy of the file (it must match
# exactly once, or it is reported NOT APPLIED); the stand-in (standin.cc,
# without its own port mutations) is built with the copy and run on a few
# riscv-tests and a CoreMark build. A mutation is DETECTED when the run
# fails. Every line of the result is to be read: grep NOT.
#---------------------------------------------------------------------------
import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
RV = os.path.join(HERE, '../../../mmRISC-2/SIM/SIM_CORE/rvtests')
PROGS = [os.path.join(RV, t) for t in ('rv64ui-p-add', 'rv64ui-p-sd', 'rv64uc-p-rvc', 'rv64mi-p-csr')] + \
        [os.path.join(HERE, '../../Plan/trace/work/g14-sflto-zbsc.elf')]

B, L = 'bench.cc', '../LOCKSTEP/lockstep.cc'
MUT = [
    (L, '|| p->htif_load) && r.rd > 0', '|| false) && r.rd > 0',
     'LOCKSTEP: loads of tohost do not take the DUT\'s value'),
    (B, '    if (!zero) return;\n', '    return;\n',
     'HTIF: tohost never put back to 0 in the memory'),
    (B, 'm.read64(tohost)) zero = true;', 'm.read64(tohost) && n == 4) zero = true;',
     'HTIF: only a 4-byte write to tohost seen in the memory'),
    (B, 'else if (dev == 1 && cmd == 1) out += (char)(shadow & 0xff);', 'else if (dev == 1 && cmd == 1) ;',
     'HTIF: console characters lost'),
    (B, 'code = (int)((shadow << 16) >> 17);', 'code = (int)((shadow << 16) >> 16);',
     'HTIF: exit code not shifted'),
    (B, 'if (dev == 0 && cmd == 0 && (shadow & 1))', 'if (shadow & 1)',
     'HTIF: bit 0 tested before the device'),
    (B, 'shadow = 0;\n    return true;', 'return true;',
     'HTIF: the committed tohost not cleared after an action'),
    (B, 'if (b < tohost || b >= tohost + 8) continue;', 'if (b < tohost || b >= tohost + 4) continue;',
     'HTIF: the upper word of tohost not seen at commit'),
    (B, 'y.pc = s.pc + insn_len(s.insn[0]);', 'y.pc = s.pc + 4;',
     'port: second half at pc + 4 whatever the length'),
    (B, 'if (!s.wr_first && !s.st[0].v) x.rd_skip = true;', '',
     'port: first half not marked rd_skip'),
    (B, 'write(s.wr_first ? x : y);', 'write(y);',
     'port: wr_first ignored'),
    (B, '    store(y, s.st[1]);\n', '',
     'port: the second half\'s store lost'),
    (B, 'for (int j = 0; j < k; j++) {', 'for (int j = 0; j < 1; j++) {',
     'bench: second halves not checked'),
    (B, 'm.poke(s.first, s.second.data(), s.second.size());', 'm.poke(s.first + 4, s.second.data(), s.second.size());',
     'ELF: segments loaded 4 bytes off'),
    (B, 'if (rd_le<uint32_t>(f, ph) != 1) continue;', 'if (rd_le<uint32_t>(f, ph) != 1 || i > 0) continue;',
     'ELF: only the first program header loaded'),
    (B, '            a->poke(x.st_addr, &x.st_data, x.st_size);\n', '',
     'arch memory: committed stores not applied'),
    (B, 'if (cycles - last_commit_cycle > c.hang_cycles)', 'if (false)',
     'watchdog: no check of cycles without a commit'),
    (B, 'else if (cycles >= c.max_cycles)', 'else if (false)',
     'watchdog: no limit of cycles'),
]


def run(i, m):
    f, old, new, desc = m
    src = open(os.path.join(HERE, f)).read()
    if src.count(old) != 1:
        return i, 'NOT APPLIED', desc
    d = os.path.join(HERE, 'obj/mut%d' % i)
    os.makedirs(d, exist_ok=True)
    mf = os.path.join(d, os.path.basename(f))
    open(mf, 'w').write(src.replace(old, new))
    env = dict(os.environ, OUT=os.path.join(d, 'standin'))
    env['BENCH' if f == B else 'LOCKSTEP'] = mf
    if subprocess.run([os.path.join(HERE, 'build.sh')], env=env, capture_output=True).returncode:
        return i, 'BUILD FAILED', desc
    try:
        r = subprocess.run([os.path.join(d, 'standin'), '-n', '0'] + PROGS, capture_output=True, timeout=900)
        rc = r.returncode
    except subprocess.TimeoutExpired:
        return i, 'NOT DETECTED', desc + ' (the run did not end)'
    return i, 'DETECTED' if rc else 'NOT DETECTED', desc


if __name__ == '__main__':
    os.makedirs(os.path.join(HERE, 'results'), exist_ok=True)
    with ThreadPoolExecutor(max_workers=4) as ex:
        res = sorted(ex.map(lambda a: run(*a), enumerate(MUT)))
    lines = ['%2d %-13s %s' % r for r in res]
    det = sum(1 for r in res if r[1] == 'DETECTED')
    lines.append('%d mutations, %d detected' % (len(MUT), det))
    out = '\n'.join(lines) + '\n'
    open(os.path.join(HERE, 'results/mutate.txt'), 'w').write(out)
    print(out, end='')
    sys.exit(0 if det == len(MUT) else 1)
