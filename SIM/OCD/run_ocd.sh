#!/bin/bash
#---------------------------------------------------------------------------
# run_ocd.sh : OpenOCD with OOO_CPU and its debug logic (step 1.8 J1, Plan/OOC.md 29.101)
#
#   ./run_ocd.sh          build tb_OCD, run it with OpenOCD (test_ocd.tcl), then again with
#                         authentication on (AUTH=1); PASS when both pass
#   ./run_ocd.sh build    the build alone
#   ./run_ocd.sh top      the same through RTL/CPU/TOP's CPU_TOP (step 2.6: its arbiter between the DM's
#                         memory accesses and the DMA port, its start of the hart); "top build" builds only
#   OPENOCD=<path>        OpenOCD (riscv-openocd; default: openocd)
#   PORT=<n>              remote_bitbang's port (44853)
#
# Verilator from scratch every time (the shared folder keeps file times to one second).
# Logs: obj/build.log, sim.log / openocd.log, sim_auth.log / openocd_auth.log.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
HERE=$(pwd)
R=$(cd ../../RTL/CPU/OOO && pwd); C=$(cd ../../RTL/CPU/CORE && pwd); CA=$(cd ../../RTL/CPU/CACHE && pwd)
MM=$(cd ../../RTL/CPU/MMIO && pwd); FP=$(cd ../../RTL/CPU/FPU && pwd); D=$(cd ../../RTL/CPU/DBG && pwd)
OPENOCD=${OPENOCD:-openocd}
PORT=${PORT:-44853}
VIA=""
if [ "$1" = top ]; then VIA="+define+VIA_CPU_TOP $(cd ../../RTL/CPU/TOP && pwd)/CPU_TOP.sv"; shift; fi
rm -rf obj; mkdir -p obj
verilator --binary --timing -j 0 -O2 --top-module tb_OCD --Mdir obj -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT $VIA \
    $D/DBG_CDC/DBG_CDC.sv $D/DBG_CJTAG/DBG_CJTAG.sv $D/DBG_DTM/DBG_DTM.sv $D/DBG_DM/DBG_DM.sv $D/DBG_TOP/DBG_TOP.sv \
    $R/OOO_UBTB2/OOO_UBTB2.sv $R/OOO_FDEC2/OOO_FDEC2.sv $R/OOO_TAGE2/OOO_TAGE2.sv $R/OOO_BTB/OOO_BTB.sv $R/OOO_RAS/OOO_RAS.sv \
    $R/OOO_FETCH2/OOO_FETCH2.sv $R/OOO_FTQ/OOO_FTQ.sv $R/OOO_FERS/OOO_FERS.sv $R/OOO_FBUF3/OOO_FBUF3.sv \
    $C/CORE_DECOMP/CORE_DECOMP.sv $C/CORE_DEC/CORE_DEC.sv $R/OOO_RARE/OOO_RARE.sv $R/OOO_DEC/OOO_DEC.sv $R/OOO_FRONT/OOO_FRONT.sv \
    $R/OOO_RENAME2/OOO_RENAME2.sv $R/OOO_BUSY/OOO_BUSY.sv $R/OOO_CTRL/OOO_CTRL.sv $R/OOO_DSREG/OOO_DSREG.sv $R/OOO_ROB/OOO_ROB.sv \
    $R/OOO_IQ3/OOO_IQ3.sv $R/OOO_IQPL2/OOO_IQPL2.sv $R/OOO_STAGE/OOO_STAGE.sv $R/OOO_ALU/OOO_ALU.sv $R/OOO_ALU2/OOO_ALU2.sv \
    $R/OOO_PRF/OOO_PRF.sv $R/OOO_DTLB3/OOO_DTLB3.sv $R/OOO_PMP/OOO_PMP.sv $R/OOO_PTW/OOO_PTW.sv $R/OOO_DCH2/OOO_DCH2.sv \
    $R/OOO_LSU4/OOO_LSU4.sv $C/CORE_CSR/CORE_CSR.sv $R/OOO_CSRU/OOO_CSRU.sv $R/OOO_TRAP/OOO_TRAP.sv $R/OOO_DBG/OOO_DBG.sv \
    $R/OOO_SYS/OOO_SYS.sv $R/OOO_PMUL/OOO_PMUL.sv $C/CORE_MDU/CORE_MDU.sv $R/OOO_MDUP/OOO_MDUP.sv \
    $FP/FPU_ROUND/FPU_ROUND.sv $FP/FPU_PIPE/FPU_PIPE.sv $R/OOO_FREN/OOO_FREN.sv $R/OOO_FIQ/OOO_FIQ.sv $R/OOO_FPUW/OOO_FPUW.sv \
    $R/OOO_CORE/OOO_CORE.sv $R/OOO_DMISS2/OOO_DMISS2.sv $R/OOO_ICACHE/OOO_ICACHE.sv $R/OOO_MARB/OOO_MARB.sv \
    $CA/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv $CA/CPU_L2/L2_TAG_ARRAY.sv $CA/CPU_L2/CPU_L2.sv \
    $MM/CPU_CLINT/CPU_CLINT.sv $MM/CPU_PLIC/CPU_PLIC.sv $MM/CPU_MMIO/CPU_MMIO.sv $R/OOO_CPU/OOO_CPU.sv \
    $HERE/AXI4_RAM.sv $HERE/AXIL_RAM.sv $HERE/tb_OCD.sv $HERE/jtag_rbb.cpp > obj/build.log 2>&1 \
    || { echo "run_ocd: build failed (see obj/build.log)"; exit 1; }
[ "$1" = build ] && exit 0
fail=0
for a in 0 1; do
    sfx=$([ $a = 1 ] && echo _auth)
    ./obj/Vtb_OCD +port=$PORT +auth=$a > sim$sfx.log 2>&1 &
    sim=$!
    sleep 2
    AUTH=$a $OPENOCD -f openocd_sim.cfg -c "remote_bitbang port $PORT" -f test_ocd.tcl > openocd$sfx.log 2>&1
    kill $sim 2>/dev/null; wait $sim 2>/dev/null
    if grep -q "OPENOCD TEST RESULT : PASS" openocd$sfx.log; then
        echo "run_ocd: authentication $([ $a = 1 ] && echo on || echo off): PASS ($(grep -c '\[ OK \]' openocd$sfx.log) checks)"
    else
        echo "run_ocd: authentication $([ $a = 1 ] && echo on || echo off): FAIL (see openocd$sfx.log)"; fail=1
    fi
done
[ $fail = 0 ] && echo "run_ocd: PASS" || { echo "run_ocd: FAIL"; exit 1; }
