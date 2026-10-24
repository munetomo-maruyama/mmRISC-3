#!/bin/bash
#---------------------------------------------------------------------------
# run_selftest.sh : the self-test of the lock-step checker on riscv-tests
# and CoreMark (selftest.cc)
#
#   ./run_selftest.sh            -> results/selftest.txt
#   RVTESTS=<dir>  the built riscv-tests (default: mmRISC-2's SIM_CORE/rvtests)
#
# All the "-p-" tests (machine mode, physical memory) of rv64ui / um / ua /
# uc / uf / ud / uzba / uzbb / uzbc / uzbs / uzicond / mi / si, 20 mutations
# each; the CoreMark builds of Plan/trace (g14 -O2 and the most
# optimization), 10 mutations each. The reference has mmRISC-2's instruction
# set and 16 PMP entries (lockstep.h). Expected to end with a nonzero exit
# code, as in mmRISC-2's run_riscv_tests.sh: ma_data (wants misaligned
# accesses done in hardware; mmRISC-2 traps) and amocas_* (Zacas is not
# implemented); the comparison must still pass on them.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
RVTESTS=${RVTESTS:-../../../mmRISC-2/SIM/SIM_CORE/rvtests}
./build.sh || exit 1
mkdir -p results
tests=$(ls $RVTESTS | grep -E '^rv64(ui|um|ua|uc|uf|ud|uzba|uzbb|uzbc|uzbs|uzicond|mi|si)-p-[a-z0-9_]+$' | sed "s|^|$RVTESTS/|")
{
./obj/selftest -n 20 $tests
./obj/selftest -n 10 ../../Plan/trace/work/g14-o2-zbsc.elf ../../Plan/trace/work/g14-sflto-zbsc.elf
} | tee results/selftest.txt
# both runs pass, and only the expected tests end with a nonzero exit code
[ "$(grep -c ' 0 failures: PASS' results/selftest.txt)" = 2 ] || exit 1
got=$(grep '^programs with a nonzero exit code:' results/selftest.txt | sed 's/.*code://; s/ ([0-9]*)//g' | tr ' ' '\n' | grep -v '^$\|^none$' | sort | tr '\n' ' ')
want="rv64ua-p-amocas_d rv64ua-p-amocas_q rv64ua-p-amocas_w rv64ui-p-ma_data "
[ "$got" = "$want" ] || { echo "unexpected nonzero exit codes: $got"; exit 1; }
echo "run_selftest: PASS"
