#!/bin/bash
#---------------------------------------------------------------------------
# run_core.sh : B2 and B3, the core in lock-step with Spike (tb_core.cpp)
#
#   ./run_core.sh               -> results/core.txt, results/core_restores.txt
#
# b2/build.sh: 20 random ALU programs, 20 with branches, loops, jal, calls
# and returns, indirect jumps, 20 with loads and stores as well; run to the
# symbol `pass`. b3/build.sh: riscv-tests' rv64ui (loads, stores, the
# store-forwarding tests), rv64uc and the Zb* / Zicond tests on a minimal
# environment, and the console through tohost; run to their HTIF exit.
# On OOO_CORE with the D$ model (I$ misses and D$ hits at random, 2 seeds;
# no I$ miss and no D$ hit) and on OOO_CPU with OOO_DCAD and the real D$.
# The restores of the first run are what mutate_core.py holds the mutated
# cores to.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
./build_core.sh || exit 1
./build_core.sh cpu || exit 1
b2/build.sh 20 || exit 1
b3/build.sh || exit 1
mkdir -p results
T=./obj/core/VOOO_CORE
C=./obj/cpu/VOOO_CPU
P=$(ls b2/work/alu-*.elf b2/work/br-*.elf b2/work/ls-*.elf | sort -V)
H=$(ls b3/work/*.elf | sort -V)
{
$T +verilator+rand+reset+2 -exit pass -v -restores-out results/core_restores.txt $P
$T +verilator+rand+reset+2 -exit pass -seed 2 $P
$T +verilator+rand+reset+2 -exit pass -miss 0 -dhit 0 -v $P
$T +verilator+rand+reset+2 $H
$T +verilator+rand+reset+2 -seed 2 -dhit 30 $H
$C +verilator+rand+reset+2 -exit pass -v $P
$C +verilator+rand+reset+2 $H
} | tee results/core.txt
[ "$(grep -c ' 0 failures: PASS' results/core.txt)" = 7 ] || exit 1
echo "run_core: PASS"
