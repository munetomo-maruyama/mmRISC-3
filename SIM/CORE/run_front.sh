#!/bin/bash
#---------------------------------------------------------------------------
# run_front.sh : B1, the front end alone (tb_front.cpp on OOO_FRONT), on
# riscv-tests and CoreMark
#
#   ./run_front.sh              -> results/front.txt
#   RVTESTS=<dir>  the built riscv-tests (default: mmRISC-2's SIM_CORE/rvtests)
#
# Every "-p-" test of rv64ui / um / ua / uc / uf / ud / uzba / uzbb / uzbc /
# uzbs / uzicond / mi / si on 2 seeds (I$ misses, D2 taking 0 to 2 a cycle,
# redirect and commit delays at random), and the two g14 CoreMark builds of
# Plan/trace that way and with -full (no I$ miss, D2 takes 2 a cycle).
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
RVTESTS=${RVTESTS:-../../../mmRISC-2/SIM/SIM_CORE/rvtests}
./build_front.sh || exit 1
mkdir -p results
T=./obj/front/VOOO_FRONT
tests=$(ls $RVTESTS | grep -E '^rv64(ui|um|ua|uc|uf|ud|uzba|uzbb|uzbc|uzbs|uzicond|mi|si)-p-[a-z0-9_]+$' | sed "s|^|$RVTESTS/|")
W=../../Plan/trace/work
{
$T +verilator+rand+reset+2 -seed 1 $tests
$T +verilator+rand+reset+2 -seed 2 $tests
$T +verilator+rand+reset+2 -v $W/g14-o2-zbsc.elf $W/g14-sflto-zbsc.elf
$T +verilator+rand+reset+2 -v -full $W/g14-o2-zbsc.elf $W/g14-sflto-zbsc.elf
} | tee results/front.txt
[ "$(grep -c ' 0 failures: PASS' results/front.txt)" = 4 ] || exit 1
echo "run_front: PASS"
