#!/bin/bash
#---------------------------------------------------------------------------
# tagedelay.sh : the TAGE update at commit and the history lag, in the
# model against B1 (Plan/CORE.md 5.3)
#
#   ./tagedelay.sh     -> results/tagedelay.txt
#
#   1. ooo.h (the cycle model, TAGE-S per branch): the update at the
#      prediction (upd=0, as G0b) or at the branch's commit (upd=1, from the
#      entries as read at the prediction, as OOO_TAGE): mispredicted
#      branches and CoreMark/MHz, the decided configuration (D-16)
#   2. tageblk.h (TAGE-S per block, the design model of OOO_TAGE): the
#      update `delay` blocks after the prediction
#   3. tageref (OOO_TAGE's own algorithm, SIM/OOO_UNIT/tage_ref.h, on the
#      same blocks): the delay of B1 (about 6.5 blocks), the history lag
#      (blocks not in the history at a block's read: 2 while fetch streams,
#      0 after a fetch stall; `stall` = % of the blocks read after one)
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
mkdir -p work results
g++ -O2 -std=c++17 -Wall -o work/model model.cpp || exit 1
D="ubtb=8 rob=24 iq=10 lq=8 sq=8 ckpt=6 fb=16 fusion=2 fuse_2src=1 fuse_1w=1 alu_split=2 redirect=2 mdu_busy=2"
mis() { sed -n 's/.*mispredicted \([0-9]*\).*/\1/p' | head -1; }
{
for b in g14-o2-zbsc g14-sflto-zbsc; do
    echo "== $b"
    for u in "upd=0" "upd=1" "upd=1 upd_lag=4"; do
        o=$(./work/model ooo work/$b.bin $D $u)
        printf "ooo %-16s branches mispredicted %5s  CoreMark/MHz %s\n" "$u" \
            "$(echo "$o" | sed -n 's/.*mispredicted: branch \([0-9]*\).*/\1/p')" "$(echo "$o" | sed -n 's/.*CoreMark\/MHz \([0-9.]*\).*/\1/p')"
    done
    for dl in 0 4 8 12 16; do
        printf "tageblk delay %-3s       mispredicted %5s\n" $dl "$(./work/model tageblk work/$b.bin slots=3 hist=1 lag=2 halve=0 delay=$dl | mis)"
    done
    for a in "lag=2 delay=0" "lag=2 delay=6" "lag=2 delay=7" "lag=2 delay=6 spread=3" "lag=0 delay=6" \
             "lag=2 delay=6 stall=10" "lag=2 delay=6 stall=30" "lag=2 delay=6 stall=50"; do
        printf "tageref %-24s mispredicted %5s\n" "$a" "$(./work/model tageref work/$b.bin $a | mis)"
    done
done
} | tee results/tagedelay.txt
