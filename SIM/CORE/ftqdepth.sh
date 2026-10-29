#!/bin/bash
#---------------------------------------------------------------------------
# ftqdepth.sh : what the front end delivers with an FTQ of 8 and of 16
# blocks, against the delay from D2 to commit (Plan/OOC.md 26.8)
#
#   ./ftqdepth.sh               -> results/ftqdepth.txt
#
# A block stays in the FTQ from its push to the pop after its last
# instruction commits: through the fetch buffer, D1a, D1b, D2 and the back
# end. Fetch asks only while the FTQ has room, so a long delay to commit
# stops fetch. tb_front -full (no I$ miss, D2 takes 2 a cycle) on the two
# g14 CoreMark builds, with commit 2 / 4 / 7 / 10 cycles after D2, and at
# random 4 to 10 cycles (the default), for FTQW 3 and 4.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
mkdir -p results
W=../../Plan/trace/work
OBJ=obj/front_q8 FTQW=3 ./build_front.sh || exit 1
OBJ=obj/front_q16 FTQW=4 ./build_front.sh || exit 1
{
echo "instructions a cycle (mispredicted): g14 -O2, g14 sf + -flto"
for q in 8 16; do
    for a in "-lag 2" "-lag 4" "-lag 7" "-lag 10" ""; do
        o=$(./obj/front_q$q/VOOO_FRONT +verilator+rand+reset+2 -full $a $W/g14-o2-zbsc.elf $W/g14-sflto-zbsc.elf)
        printf "FTQ %2d  commit %-12s %s\n" $q "${a:-4 to 10}" \
            "$(echo "$o" | awk '/insns\/cycle/ {printf "%s (%s)  ", $7, $9}')"
        echo "$o" | grep -q " 0 failures: PASS" || echo "  FAIL"
    done
done
} | tee results/ftqdepth.txt
