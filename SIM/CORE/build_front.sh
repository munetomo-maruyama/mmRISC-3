#!/bin/bash
#---------------------------------------------------------------------------
# build_front.sh : B1, the front end alone (tb_front.cpp on OOO_FRONT)
#
#   ./build_front.sh            -> obj/front/VOOO_FRONT
#   OOO_RTL=<dir> OBJ=<dir>     another copy of RTL/CPU/OOO and where to build
#                               (the bug injection of mutate_front.py)
#
# Verilator from scratch every time (the shared folder keeps file times to
# one second), with the options of SIM/OOO_UNIT/run.sh: what has no reset
# starts random (--x-initial unique; run with +verilator+rand+reset+2).
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
HERE=$(pwd)
R=${OOO_RTL:-$(cd ../../RTL/CPU/OOO && pwd)}
C=$(cd ../../RTL/CPU/CORE && pwd)
S=${SPIKE:-$HOME/RISCV/toolchain/spike-install}
O=${OBJ:-$HERE/obj/front}
rm -rf $O; mkdir -p $O
verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --x-assign unique --x-initial unique --Mdir $O \
    --top-module OOO_FRONT \
    $R/OOO_UBTB/OOO_UBTB.sv $R/OOO_PREDEC/OOO_PREDEC.sv $R/OOO_TAGE/OOO_TAGE.sv $R/OOO_BTB/OOO_BTB.sv $R/OOO_RAS/OOO_RAS.sv \
    $R/OOO_FETCH/OOO_FETCH.sv $R/OOO_FTQ/OOO_FTQ.sv $R/OOO_FERS/OOO_FERS.sv $R/OOO_FBUF/OOO_FBUF.sv \
    $C/CORE_DECOMP/CORE_DECOMP.sv $C/CORE_DEC/CORE_DEC.sv $R/OOO_RARE/OOO_RARE.sv $R/OOO_DEC/OOO_DEC.sv $R/OOO_FRONT/OOO_FRONT.sv \
    $HERE/tb_front.cpp $HERE/bench.cc $HERE/../LOCKSTEP/lockstep.cc \
    -CFLAGS "-O2 -std=c++17 -I$HERE -I$HERE/../LOCKSTEP -I$S/include -I$S/include/riscv -I$S/include/softfloat -I$S/include/fesvr -Wno-c++20-extensions" \
    -LDFLAGS "-L$S/lib -lriscv -lsoftfloat -ldisasm -lfesvr -Wl,-rpath,$S/lib -lpthread -ldl" > $O/build.log 2>&1 \
    || { echo "build_front: failed (see $O/build.log)"; exit 1; }
