#!/bin/bash
#---------------------------------------------------------------------------
# run_coremark.sh : CoreMark (the three builds of Plan/trace) on the core in
# lock-step with Spike (Plan/CORE.md 5.8)
#
#   ./run_coremark.sh           -> results/coremark.txt
#
# OOO_CORE with no I$ miss and every D$ load a hit (the model's caches: its
# cycles are what Plan/model's are compared with), OOO_CPU with the real D$
# (no I$ miss), and OOO_CORE with misses at random (2 seeds: 8 % I$ misses
# and 80 % D$ hits; 30 % D$ hits) for the recoveries. Fusion is off (B5).
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
./build_core.sh || exit 1
./build_core.sh cpu || exit 1
mkdir -p results
T=../../Plan/trace/work
E="$T/g14-o2-zbsc.elf $T/g14-sflto-zbsc.elf $T/g13-o2-zb.elf"
O="+verilator+rand+reset+2 -max 100000000 -v"
mkdir -p obj/cm
./obj/core/VOOO_CORE $O -miss 0 -dhit 100 $E > obj/cm/ideal.txt 2>&1 &
./obj/cpu/VOOO_CPU $O -miss 0 $E > obj/cm/cpu.txt 2>&1 &
./obj/core/VOOO_CORE $O $E > obj/cm/rand1.txt 2>&1 &
./obj/core/VOOO_CORE $O -seed 2 -dhit 30 $E > obj/cm/rand2.txt 2>&1 &
wait
{
echo "== OOO_CORE, no I\$ miss, every D\$ load a hit";  cat obj/cm/ideal.txt
echo "== OOO_CPU, the real D\$, no I\$ miss";           cat obj/cm/cpu.txt
echo "== OOO_CORE, misses at random (seed 1)";         cat obj/cm/rand1.txt
echo "== OOO_CORE, misses at random (seed 2, 30 % D\$ hits)"; cat obj/cm/rand2.txt
} > results/coremark.txt
grep "tb_core:" results/coremark.txt
[ "$(grep -c ' 0 failures: PASS' results/coremark.txt)" = 4 ] || exit 1
echo "run_coremark: PASS"
