#!/bin/bash
#---------------------------------------------------------------------------
# run.sh : unit tests of the out-of-order blocks of mmRISC-3 (RTL/CPU/OOO)
#
#   ./run.sh [test ...]       default: all of them
#
#   OOO_RTL=<dir>  another copy of RTL/CPU/OOO (the bug injection of mutate.py)
#   CORE_RTL=<dir> another copy of RTL/CPU/CORE (the same)
#   CACHE_RTL=<dir> another copy of RTL/CPU/CACHE (the same)
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
C=${CORE_RTL:-$(cd ../../RTL/CPU/CORE && pwd)}   # blocks taken from mmRISC-2
CA=${CACHE_RTL:-$(cd ../../RTL/CPU/CACHE && pwd)} # mmRISC-2's D$
SP=${SPIKE:-$HOME/RISCV/toolchain/spike-install}   # Spike, the judge of tb_dec
OBJ=${OOO_OBJ:-$HERE/obj_dir}

declare -A TOP SRC XC XL GV
TOP[alu2]=OOO_ALU2;     SRC[alu2]="$R/OOO_ALU/OOO_ALU.sv $R/OOO_ALU2/OOO_ALU2.sv"
TOP[alu1]=OOO_ALU2;     SRC[alu1]="${SRC[alu2]}"; GV[alu1]="-GFULL=0"   # ALU1 (G0b L7)
TOP[fuse]=OOO_FUSE;     SRC[fuse]="$R/OOO_FUSE/OOO_FUSE.sv"
TOP[prf]=OOO_PRF;       SRC[prf]="$R/OOO_PRF/OOO_PRF.sv"
TOP[rename]=OOO_RENAME; SRC[rename]="$R/OOO_RENAME/OOO_RENAME.sv"
TOP[iq]=OOO_IQ;         SRC[iq]="$R/OOO_IQ/OOO_IQ.sv"
TOP[ctrl]=OOO_CTRL;     SRC[ctrl]="$R/OOO_CTRL/OOO_CTRL.sv"
TOP[dsreg]=OOO_DSREG;   SRC[dsreg]="$R/OOO_DSREG/OOO_DSREG.sv"; GV[dsreg]="-GW=16"
TOP[fers]=OOO_FERS;     SRC[fers]="$R/OOO_FERS/OOO_FERS.sv"
TOP[stage]=OOO_STAGE;   SRC[stage]="$R/OOO_STAGE/OOO_STAGE.sv"; GV[stage]="-GW=16"
TOP[iqpl]=OOO_IQPL;     SRC[iqpl]="$R/OOO_IQPL/OOO_IQPL.sv"
TOP[ubtb]=OOO_UBTB;     SRC[ubtb]="$R/OOO_UBTB/OOO_UBTB.sv"
TOP[lsu]=OOO_LSU;       SRC[lsu]="$R/OOO_LSU/OOO_LSU.sv"
TOP[dcad]=LSU_DC;       SRC[dcad]="$R/OOO_LSU/OOO_LSU.sv $R/OOO_DCAD/OOO_DCAD.sv $CA/CACHE_TAG_ARRAY/CACHE_TAG_ARRAY.sv $CA/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv $CA/DCACHE/DCACHE.sv $HERE/LSU_DC.sv"
TOP[rob]=OOO_ROB;       SRC[rob]="$R/OOO_ROB/OOO_ROB.sv"
TOP[fbuf]=OOO_FBUF;     SRC[fbuf]="$R/OOO_FBUF/OOO_FBUF.sv"
TOP[ftq]=OOO_FTQ;       SRC[ftq]="$R/OOO_FTQ/OOO_FTQ.sv"
TOP[predec]=OOO_PREDEC; SRC[predec]="$R/OOO_PREDEC/OOO_PREDEC.sv"
TOP[ras]=OOO_RAS;       SRC[ras]="$R/OOO_RAS/OOO_RAS.sv"
TOP[btb]=OOO_BTB;       SRC[btb]="$R/OOO_BTB/OOO_BTB.sv"
TOP[tage]=OOO_TAGE;     SRC[tage]="$R/OOO_TAGE/OOO_TAGE.sv"
TOP[dec]=OOO_DEC;       SRC[dec]="$C/CORE_DECOMP/CORE_DECOMP.sv $C/CORE_DEC/CORE_DEC.sv $R/OOO_DEC/OOO_DEC.sv"
XC[dec]="-I$SP/include -I$SP/include/riscv -I$SP/include/softfloat -I$SP/include/fesvr -Wno-c++20-extensions"
XL[dec]="-L$SP/lib -lriscv -ldisasm -lsoftfloat -lfesvr -Wl,-rpath,$SP/lib -lpthread -ldl"
TOP[fetch]=OOO_FETCH;   SRC[fetch]="$R/OOO_UBTB/OOO_UBTB.sv $R/OOO_PREDEC/OOO_PREDEC.sv $R/OOO_TAGE/OOO_TAGE.sv $R/OOO_BTB/OOO_BTB.sv $R/OOO_RAS/OOO_RAS.sv $R/OOO_FETCH/OOO_FETCH.sv"
TESTS=${*:-alu2 alu1 fuse prf rename ctrl dsreg stage fers iq iqpl ubtb lsu dcad rob fbuf ftq predec ras btb tage fetch dec}

fail=0
for t in $TESTS; do
    o=$OBJ/$t
    rm -rf $o; mkdir -p $o
    if ! verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --x-assign unique --x-initial unique --Mdir $o \
            --top-module ${TOP[$t]} ${GV[$t]} ${SRC[$t]} $HERE/tb_$t.cpp -CFLAGS "-O2 -std=c++17 ${XC[$t]}" ${XL[$t]:+-LDFLAGS "${XL[$t]}"} > $o/build.log 2>&1; then
        echo "tb_$t: build failed (see $o/build.log): FAIL"; fail=$((fail + 1)); continue
    fi
    $o/V${TOP[$t]} +verilator+rand+reset+2 || fail=$((fail + 1))
done
exit $fail
