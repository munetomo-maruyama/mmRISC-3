#!/bin/bash
#---------------------------------------------------------------------------
# run.sh : unit tests of the out-of-order blocks of mmRISC-3 (RTL/CPU/OOO)
#
#   ./run.sh [test ...]       default: all of them
#
#   OOO_RTL=<dir>  another copy of RTL/CPU/OOO (the bug injection of mutate.py)
#   OOO_OBJ=<dir>  where to build (default obj_dir)
#
# Each test is a Verilator C++ testbench (tb_<test>.cpp) that holds one block
# against a reference of its own. The build is always made from scratch in
# obj_dir/<test> (the shared folder keeps file times to one second, so make
# cannot be trusted to see an edit), and every test prints one line ending
# in PASS or FAIL. The exit code is the number of tests that failed.
# Everything without a reset starts with random values (--x-initial unique,
# +verilator+rand+reset+2), so that no test passes by leaning on zeros the
# hardware does not promise.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
HERE=$(pwd)
R=${OOO_RTL:-$(cd ../../RTL/CPU/OOO && pwd)}
OBJ=${OOO_OBJ:-$HERE/obj_dir}

declare -A TOP SRC
TOP[alu2]=OOO_ALU2;     SRC[alu2]="$R/OOO_ALU/OOO_ALU.sv $R/OOO_ALU2/OOO_ALU2.sv"
TOP[fuse]=OOO_FUSE;     SRC[fuse]="$R/OOO_FUSE/OOO_FUSE.sv"
TOP[prf]=OOO_PRF;       SRC[prf]="$R/OOO_PRF/OOO_PRF.sv"
TOP[rename]=OOO_RENAME; SRC[rename]="$R/OOO_RENAME/OOO_RENAME.sv"
TOP[iq]=OOO_IQ;         SRC[iq]="$R/OOO_IQ/OOO_IQ.sv"
TOP[ubtb]=OOO_UBTB;     SRC[ubtb]="$R/OOO_UBTB/OOO_UBTB.sv"
TOP[lsu]=OOO_LSU;       SRC[lsu]="$R/OOO_LSU/OOO_LSU.sv"
TESTS=${*:-alu2 fuse prf rename iq ubtb lsu}

fail=0
for t in $TESTS; do
    o=$OBJ/$t
    rm -rf $o; mkdir -p $o
    if ! verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --x-assign unique --x-initial unique --Mdir $o \
            --top-module ${TOP[$t]} ${SRC[$t]} $HERE/tb_$t.cpp -CFLAGS "-O2 -std=c++17" > $o/build.log 2>&1; then
        echo "tb_$t: build failed (see $o/build.log): FAIL"; fail=$((fail + 1)); continue
    fi
    $o/V${TOP[$t]} +verilator+rand+reset+2 || fail=$((fail + 1))
done
exit $fail
