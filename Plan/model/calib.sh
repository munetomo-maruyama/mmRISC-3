#!/bin/bash
#---------------------------------------------------------------------------
# calib.sh : the in-order model against what mmRISC-2 measured
#
#   ./calib.sh            -> results/calib.txt
#
# Five states of mmRISC-2 in October 2026 (LitexSystem/docs/BENCH.md), each
# measured in SIM_SYS on CoreMark, 10 iterations, GCC 13.2 -O2:
#   P1 after A2 (section 6)       mul_wait=3, 2-bit counters, no late branches
#   P2 decision 61 (section 7)    mul_wait=1
#   P3 decision 63 (section 9)    + gshare
#   P4 decision 64 (section 10)   + late branches
#   P5 Zba / Zbb (section 11)     the same hardware, the Zba / Zbb build
# The traces come from ../trace (trace.sh g13-o2-gc g13-o2-zb), converted
# here by mktrace.py if missing.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
mkdir -p work results
g++ -O2 -std=c++17 -Wall -o work/model model.cpp || exit 1
for b in g13-o2-gc g13-o2-zb; do
    [ -s work/$b.bin ] || python3 mktrace.py ../trace/work/$b.trace.gz work/$b.bin || exit 1
done
{
    run() {   # run <name> <measured cycles> <trace> <options...>
        local n=$1 m=$2 tr=$3; shift 3
        local out=$(./work/model inorder work/$tr.bin "$@")
        local c=$(echo "$out" | sed -n 's/.*cycles \([0-9]*\).*/\1/p' | head -1)
        printf "%-3s %-34s measured %9d  model %9d  %+6.2f %%\n" $n "$*" $m $c \
            $(echo "scale=4; ($c - $m) * 100 / $m" | bc)
        echo "$out" | sed -n '2,3p' | sed 's/^/    /'
    }
    run P1 4312829 g13-o2-gc mul_wait=3 gshare=0 late=0 redirect=2
    run P2 4124913 g13-o2-gc mul_wait=1 gshare=0 late=0 redirect=2
    run P3 4033497 g13-o2-gc mul_wait=1 gshare=1 late=0 redirect=2
    run P4 3908766 g13-o2-gc mul_wait=1 gshare=1 late=1 redirect=2
    run P5 3513870 g13-o2-zb mul_wait=1 gshare=1 late=1 redirect=2
} | tee results/calib.txt
