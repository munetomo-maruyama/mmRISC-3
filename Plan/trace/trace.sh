#!/bin/bash
#---------------------------------------------------------------------------
# trace.sh : traces of the timed part of CoreMark, and their analysis
#
#   ./trace.sh [build ...]       builds named compiler-options-march as in
#                                ../icount (default: the three below)
#
# Each build is made by ../icount/icount.sh (10 iterations), run on Spike
# with -l --log-commits, cut to the timed part by capture.py and analyzed
# by analyze.py (a few minutes per build; the builds run in parallel).
#
# Output: work/<build>.{elf,trace.gz} (not kept), results/<build>.json
# (everything) and results/<build>.limit.txt (the lines of the limit model)
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
SPIKE=${SPIKE:-$HOME/RISCV/toolchain/spike-install/bin/spike}
BUILDS=${*:-g14-o2-zbsc g14-sflto-zbsc g13-o2-zb}
mkdir -p work results

for b in $BUILDS; do
    ITER=10 ../icount/icount.sh ${b//-/:} > /dev/null || exit 1
    cp ../icount/work/$b.elf work/
    $SPIKE --isa=rv64gc_zba_zbb_zbs_zicond -l --log-commits work/$b.elf 2>&1 >/dev/null |
        python3 capture.py work/$b.trace.gz || exit 1
done
for b in $BUILDS; do
    python3 analyze.py work/$b.trace.gz work/$b.elf 10 > /dev/null 2> results/$b.limit.txt &
done
wait
ls results
