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
# no I$ miss and no D$ hit) and on OOO_CPU with the real caches (the D$, and
# since step 1.7 H3 the I$ and the L2, Plan/OOC.md 29.58).
# b4/build.sh: riscv-arch-test's I, M, Zca, Zba, Zbb, Zbc, Zbs, Zicond,
# Zicsr, Zifencei, Zicntr, Sm and Exceptions tests that fit the core (185;
# Zaamo, Zalrsc and their Exceptions tests since step 1.4 E1c, Plan/OOC.md 29.74),
# and riscv-tests' -p- programs of mmRISC-2 ($RVTESTS: rv64ui / um / ua / uc /
# uzba / uzbb / uzbc / uzbs / uzicond / mi / si; ua since E1c, not its
# amocas: Zacas) but three that Phase 1
# cannot run: rv64mi-p-breakpoint (the triggers' firing is not wired),
# rv64mi-p-csr (an FP instruction: no FPU), rv64si-p-dirty (paging); on
# both tops, to their HTIF exit; with b4/dir/illegal.S (the exceptions
# found at decode), b4/dir/dcrace.S (the D$'s races behind the L2) and
# b4/dir/atomic.S (the atomics, step 1.4 E1c), b4/dir/devld.S (device loads at the
# head alone, step 1.8 I1). The interrupts (step 1.8 I1, Plan/OOC.md 29.78): b4/irq and
# the Interrupts groups on OOO_CPU alone (its CLINT and PLIC; OOO_CORE has none).
# The restores of the first run are what mutate_core.py holds the mutated
# cores to.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
./build_core.sh || exit 1
# OOO_CPU with OOO_DMISS (step 1.3 E2, Plan/OOC.md 29.34); CPU=0 leaves its 4 runs out
CPU=${CPU:-1}
[ "$CPU" = 1 ] && { ./build_core.sh cpu || exit 1; }
b2/build.sh 20 || exit 1
b3/build.sh || exit 1
b4/build.sh || exit 1
mkdir -p results
T=./obj/core/VOOO_CORE
C=./obj/cpu/VOOO_CPU
cpu() { [ "$CPU" = 1 ] && $C "$@"; }
P=$(ls b2/work/alu-*.elf b2/work/br-*.elf b2/work/ls-*.elf | sort -V)
H=$(ls b3/work/*.elf | sort -V)
A=$(ls b4/work/*/*.elf | grep -vE '/(irq|Interrupts[A-Za-z]*)/' | sort -V)
I=$(ls b4/work/irq/*.elf b4/work/InterruptsSm/*.elf b4/work/InterruptsS/*.elf | sort -V)     # (OOO_CPU's CLINT and PLIC: step 1.8 I1)
RV=${RVTESTS:-../../../mmRISC-2/SIM/SIM_CORE/rvtests}
R=$(ls $RV | grep -E '^rv64(ui|um|ua|uc|uzba|uzbb|uzbc|uzbs|uzicond|mi|si)-p-[a-z0-9_]+$' |
    grep -vE '^rv64mi-p-(breakpoint|csr)$|^rv64si-p-dirty$|^rv64ua-p-amocas_' | sed "s|^|$RV/|")
{
$T +verilator+rand+reset+2 -exit pass -v -restores-out results/core_restores.txt $P
$T +verilator+rand+reset+2 -exit pass -seed 2 $P
$T +verilator+rand+reset+2 -exit pass -miss 0 -dhit 0 -v $P
$T +verilator+rand+reset+2 $H
$T +verilator+rand+reset+2 -seed 2 -dhit 30 $H
cpu +verilator+rand+reset+2 -exit pass -v $P
cpu +verilator+rand+reset+2 $H
$T +verilator+rand+reset+2 $A
$T +verilator+rand+reset+2 -seed 2 -dhit 30 $A
$T +verilator+rand+reset+2 $R
cpu +verilator+rand+reset+2 $A $I
cpu +verilator+rand+reset+2 $R
} | tee results/core.txt
[ "$(grep -c ' 0 failures: PASS' results/core.txt)" = $([ "$CPU" = 1 ] && echo 12 || echo 8) ] || exit 1
echo "run_core: PASS"
