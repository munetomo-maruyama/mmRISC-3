#!/bin/bash
#---------------------------------------------------------------------------
# run_core.sh : B2, the core with ALU µops only (tb_core.cpp on OOO_CORE),
# on B2's programs in lock-step with Spike
#
#   ./run_core.sh               -> results/core.txt, results/core_restores.txt
#
# b2/build.sh: 20 random ALU programs and 20 with branches, loops, jal,
# calls and returns, indirect jumps; each run to the symbol `pass` on two
# seeds (I$ misses at random) and with no I$ miss. The restores of the
# first run are what mutate_core.py holds the mutated cores to.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
./build_core.sh || exit 1
b2/build.sh 20 || exit 1
mkdir -p results
T=./obj/core/VOOO_CORE
P=$(ls b2/work/alu-*.elf b2/work/br-*.elf | sort -V)
{
$T +verilator+rand+reset+2 -exit pass -v -restores-out results/core_restores.txt $P
$T +verilator+rand+reset+2 -exit pass -seed 2 $P
$T +verilator+rand+reset+2 -exit pass -miss 0 -v $P
} | tee results/core.txt
[ "$(grep -c ' 0 failures: PASS' results/core.txt)" = 3 ] || exit 1
echo "run_core: PASS"
