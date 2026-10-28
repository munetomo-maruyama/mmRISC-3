#!/bin/bash
#---------------------------------------------------------------------------
# run_standin.sh : the core's test bench tested with the stand-in core
# (standin.cc) on riscv-tests and CoreMark
#
#   ./run_standin.sh             -> results/standin.txt
#   RVTESTS=<dir>  the built riscv-tests (default: mmRISC-2's SIM_CORE/rvtests)
#
# The programs of SIM/LOCKSTEP/run_selftest.sh: every "-p-" test of rv64ui /
# um / ua / uc / uf / ud / uzba / uzbb / uzbc / uzbs / uzicond / mi / si and
# the two g14 CoreMark builds of Plan/trace, 13 port mutations each (one of
# every kind). The same programs as there end with a nonzero exit code
# (ma_data, amocas_*): the program's verdict on itself, not the bench's.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
RVTESTS=${RVTESTS:-../../../mmRISC-2/SIM/SIM_CORE/rvtests}
./build.sh || exit 1
mkdir -p results
tests=$(ls $RVTESTS | grep -E '^rv64(ui|um|ua|uc|uf|ud|uzba|uzbb|uzbc|uzbs|uzicond|mi|si)-p-[a-z0-9_]+$' | sed "s|^|$RVTESTS/|")
{
./obj/standin -n 13 $tests
./obj/standin -n 13 ../../Plan/trace/work/g14-o2-zbsc.elf ../../Plan/trace/work/g14-sflto-zbsc.elf
} | tee results/standin.txt
[ "$(grep -c ' 0 failures: PASS' results/standin.txt)" = 2 ] || exit 1
got=$(grep '^programs with a nonzero exit code:' results/standin.txt | sed 's/.*code://; s/ ([0-9]*)//g' | tr ' ' '\n' | grep -v '^$\|^none$' | sort | tr '\n' ' ')
want="rv64ua-p-amocas_d rv64ua-p-amocas_q rv64ua-p-amocas_w rv64ui-p-ma_data "
[ "$got" = "$want" ] || { echo "unexpected nonzero exit codes: $got"; exit 1; }
echo "run_standin: PASS"
