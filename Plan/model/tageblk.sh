#!/bin/bash
#---------------------------------------------------------------------------
# tageblk.sh : TAGE-S per fetch block (tageblk.h, as OOO_TAGE builds it in
# block RAM) against TAGE-S per branch (tage.h, the model's), on the
# conditional branches of CoreMark
#
#   ./tageblk.sh       -> results/tageblk.txt
#
# slots: direction counters per row (the 1st, 2nd, ... branch of a block);
# hist 1: only the slot branches go into the history (0: every branch);
# lag: blocks not yet in the history used for the index (2: the blocks in
# F1 and F2 when a block is in F0, the realistic case); halve 0: no
# periodic halving of the useful counters. Plan/OOC.md 14.1.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
mkdir -p work results
g++ -O2 -std=c++17 -Wall -o work/model model.cpp || exit 1
{
for b in g14-o2-zbsc g14-sflto-zbsc; do
    echo "== $b"
    ./work/model tage work/$b.bin | head -1
    for a in "slots=1 hist=1 lag=0" "slots=2 hist=0 lag=0" "slots=2 hist=1 lag=0" "slots=2 hist=1 lag=2" \
             "slots=3 hist=1 lag=0" "slots=3 hist=1 lag=1" "slots=3 hist=1 lag=2" "slots=3 hist=1 lag=2 halve=0"; do
        ./work/model tageblk work/$b.bin $a | head -1
    done
done
} | tee results/tageblk.txt
