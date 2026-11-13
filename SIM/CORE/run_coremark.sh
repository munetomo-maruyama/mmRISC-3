#!/bin/bash
#---------------------------------------------------------------------------
# run_coremark.sh : CoreMark (the three builds of Plan/trace) on the core in
# lock-step with Spike (Plan/CORE.md 5.8)
#
#   ./run_coremark.sh           -> results/coremark.txt
#
# OOO_CORE with no I$ miss and every D$ load a hit (the model's caches: its
# cycles are what Plan/model's are compared with), OOO_CPU with the real
# caches (the I$, the D$, the L2: step 1.7 H3, Plan/OOC.md 29.58) on the
# tests' memory (3 to 16 cycles) and on the board's (-mlat 25: the first
# beat 25 to 45 cycles after the address; gate S1-B's number), and OOO_CORE
# with misses at random (2 seeds: 8 % I$ misses and 80 % D$ hits; 30 % D$
# hits) for the recoveries. Fusion is off (B5).
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
./build_core.sh || exit 1
# OOO_CPU with OOO_DMISS (step 1.3 E2, Plan/OOC.md 29.34); CPU=0 leaves it out
CPU=${CPU:-1}
[ "$CPU" = 1 ] && { ./build_core.sh cpu || exit 1; }
mkdir -p results
T=../../Plan/trace/work
E="$T/g14-o2-zbsc.elf $T/g14-sflto-zbsc.elf $T/g13-o2-zb.elf"
O="+verilator+rand+reset+2 -max 100000000 -v"
mkdir -p obj/cm
./obj/core/VOOO_CORE $O -miss 0 -dhit 100 $E > obj/cm/ideal.txt 2>&1 &
if [ "$CPU" = 1 ]; then
    ./obj/cpu/VOOO_CPU $O $E > obj/cm/cpu.txt 2>&1 &
    ./obj/cpu/VOOO_CPU $O -mlat 25 $E > obj/cm/board.txt 2>&1 &
else
    echo "(OOO_CPU: left out, CPU=0)" > obj/cm/cpu.txt; echo "(OOO_CPU: left out, CPU=0)" > obj/cm/board.txt
fi
./obj/core/VOOO_CORE $O $E > obj/cm/rand1.txt 2>&1 &
./obj/core/VOOO_CORE $O -seed 2 -dhit 30 $E > obj/cm/rand2.txt 2>&1 &
wait
{
echo "== OOO_CORE, no I\$ miss, every D\$ load a hit";  cat obj/cm/ideal.txt
echo "== OOO_CPU, the real caches (I\$, D\$, L2), the tests' memory (3 to 16 cycles)"; cat obj/cm/cpu.txt
echo "== OOO_CPU, the real caches, the board's memory (-mlat 25: 25 to 45 cycles)"; cat obj/cm/board.txt
echo "== OOO_CORE, misses at random (seed 1)";         cat obj/cm/rand1.txt
echo "== OOO_CORE, misses at random (seed 2, 30 % D\$ hits)"; cat obj/cm/rand2.txt
} > results/coremark.txt
grep "tb_core:" results/coremark.txt
[ "$(grep -c ' 0 failures: PASS' results/coremark.txt)" = $([ "$CPU" = 1 ] && echo 5 || echo 3) ] || exit 1
echo "run_coremark: PASS"
