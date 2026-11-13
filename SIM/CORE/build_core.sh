#!/bin/bash
#---------------------------------------------------------------------------
# build_core.sh : the core's bench (tb_core.cpp on OOO_CORE, B2 on)
#
#   ./build_core.sh             -> obj/core/VOOO_CORE  (the D$: a model on the LSU's port)
#   ./build_core.sh cpu         -> obj/cpu/VOOO_CPU    (the D$, the I$, the arbiter and the L2 on AXI models, step 1.7 H3)
#   OOO_RTL=<dir> OBJ=<dir>     another copy of RTL/CPU/OOO and where to build
#                               (the bug injection of mutate_core.py)
#   L2KB=<n>                    OOO_CPU's L2 of n KB (256 by default; mutate_core.py
#                               takes 4: most accesses miss it, so memory's stalls
#                               reach the D$ and its writes go through to memory)
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
CA=$(cd ../../RTL/CPU/CACHE && pwd)
if [ "$1" = cpu ]; then
    L2KB=${L2KB:-256}
    TOP=OOO_CPU; O=${OBJ:-$HERE/obj/cpu}; DEF="+define+DCACHE_SIM_UC -GL2_SIZE=$((L2KB * 1024)) $HERE/tb_cpu.vlt"; CDEF="-DCPU_TOP -DL2_SETS=$((L2KB * 4))"
    XSRC="$R/OOO_DMISS/OOO_DMISS.sv $R/OOO_ICACHE/OOO_ICACHE.sv $R/OOO_MARB/OOO_MARB.sv $CA/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv $CA/CPU_L2/L2_TAG_ARRAY.sv $CA/CPU_L2/CPU_L2.sv $R/OOO_CPU/OOO_CPU.sv"
else
    TOP=OOO_CORE; O=${OBJ:-$HERE/obj/core}; DEF=""; CDEF=""; XSRC=""
fi
rm -rf $O; mkdir -p $O
verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT --x-assign unique --x-initial unique --Mdir $O \
    --top-module $TOP +define+OOO_TRACE $DEF \
    $R/OOO_UBTB2/OOO_UBTB2.sv $R/OOO_FDEC2/OOO_FDEC2.sv $R/OOO_TAGE2/OOO_TAGE2.sv $R/OOO_BTB/OOO_BTB.sv $R/OOO_RAS/OOO_RAS.sv \
    $R/OOO_FETCH2/OOO_FETCH2.sv $R/OOO_FTQ/OOO_FTQ.sv $R/OOO_FERS/OOO_FERS.sv $R/OOO_FBUF3/OOO_FBUF3.sv \
    $C/CORE_DECOMP/CORE_DECOMP.sv $C/CORE_DEC/CORE_DEC.sv $R/OOO_RARE/OOO_RARE.sv $R/OOO_DEC/OOO_DEC.sv $R/OOO_FRONT/OOO_FRONT.sv \
    $R/OOO_RENAME2/OOO_RENAME2.sv $R/OOO_BUSY/OOO_BUSY.sv $R/OOO_CTRL/OOO_CTRL.sv $R/OOO_DSREG/OOO_DSREG.sv $R/OOO_ROB/OOO_ROB.sv \
    $R/OOO_IQ3/OOO_IQ3.sv $R/OOO_IQPL2/OOO_IQPL2.sv $R/OOO_STAGE/OOO_STAGE.sv $R/OOO_ALU/OOO_ALU.sv $R/OOO_ALU2/OOO_ALU2.sv \
    $R/OOO_PRF/OOO_PRF.sv $R/OOO_DTLB2/OOO_DTLB2.sv $R/OOO_DCH2/OOO_DCH2.sv $R/OOO_LSU4/OOO_LSU4.sv $C/CORE_CSR/CORE_CSR.sv $R/OOO_CSRU/OOO_CSRU.sv $R/OOO_TRAP/OOO_TRAP.sv \
    $R/OOO_SYS/OOO_SYS.sv $R/OOO_PMUL/OOO_PMUL.sv $C/CORE_MDU/CORE_MDU.sv $R/OOO_MDUP/OOO_MDUP.sv $R/OOO_CORE/OOO_CORE.sv $XSRC \
    $HERE/tb_core.cpp $HERE/bench.cc $HERE/../LOCKSTEP/lockstep.cc \
    -CFLAGS "-O2 -std=c++17 $CDEF -I$HERE -I$HERE/../LOCKSTEP -I$S/include -I$S/include/riscv -I$S/include/softfloat -I$S/include/fesvr -Wno-c++20-extensions" \
    -LDFLAGS "-L$S/lib -lriscv -lsoftfloat -ldisasm -lfesvr -Wl,-rpath,$S/lib -lpthread -ldl" > $O/build.log 2>&1 \
    || { echo "build_core: failed (see $O/build.log)"; exit 1; }
