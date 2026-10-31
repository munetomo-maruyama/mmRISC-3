#!/bin/bash
#---------------------------------------------------------------------------
# run_core.sh : B2, B3 and B4, the core in lock-step with Spike (tb_core.cpp)
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
# b4/build.sh: riscv-arch-test's I, M, Zca, Zba, Zbb, Zbc, Zbs, Zicond,
# Zicsr, Zifencei, Zicntr, Sm and Exceptions tests that fit the core (185),
# and riscv-tests' -p- programs of mmRISC-2 ($RVTESTS: rv64ui / um / uc /
# uzba / uzbb / uzbc / uzbs / uzicond / mi / si) but three that Phase 1
# cannot run: rv64mi-p-breakpoint (the triggers' firing is not wired),
# rv64mi-p-csr (an FP instruction: no FPU), rv64si-p-dirty (paging); on
# both tops, to their HTIF exit; with b4/dir/illegal.S (the exceptions
# found at decode).
# The restores of the first run are what mutate_core.py holds the mutated
# cores to.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
./build_core.sh || exit 1
./build_core.sh cpu || exit 1
b2/build.sh 20 || exit 1
b3/build.sh || exit 1
b4/build.sh || exit 1
mkdir -p results
T=./obj/core/VOOO_CORE
C=./obj/cpu/VOOO_CPU
P=$(ls b2/work/alu-*.elf b2/work/br-*.elf b2/work/ls-*.elf | sort -V)
H=$(ls b3/work/*.elf | sort -V)
A=$(ls b4/work/*/*.elf | sort -V)
RV=${RVTESTS:-../../../mmRISC-2/SIM/SIM_CORE/rvtests}
R=$(ls $RV | grep -E '^rv64(ui|um|uc|uzba|uzbb|uzbc|uzbs|uzicond|mi|si)-p-[a-z0-9_]+$' |
    grep -vE '^rv64mi-p-(breakpoint|csr)$|^rv64si-p-dirty$' | sed "s|^|$RV/|")
{
$T +verilator+rand+reset+2 -exit pass -v -restores-out results/core_restores.txt $P
$T +verilator+rand+reset+2 -exit pass -seed 2 $P
$T +verilator+rand+reset+2 -exit pass -miss 0 -dhit 0 -v $P
$T +verilator+rand+reset+2 $H
$T +verilator+rand+reset+2 -seed 2 -dhit 30 $H
$C +verilator+rand+reset+2 -exit pass -v $P
$C +verilator+rand+reset+2 $H
$T +verilator+rand+reset+2 $A
$T +verilator+rand+reset+2 -seed 2 -dhit 30 $A
$T +verilator+rand+reset+2 $R
$C +verilator+rand+reset+2 $A
$C +verilator+rand+reset+2 $R
} | tee results/core.txt
[ "$(grep -c ' 0 failures: PASS' results/core.txt)" = 12 ] || exit 1
echo "run_core: PASS"
