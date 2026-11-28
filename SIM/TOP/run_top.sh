#!/bin/bash
#---------------------------------------------------------------------------
# run_top.sh : tb_CPU_TOP, CPU_TOP's DMA port against the D$ (step 2.6, RTL/CPU/TOP)
#
#   ./run_top.sh       build (Verilator from scratch: the shared folder keeps file
#                      times to one second) and run; PASS or FAIL at the end
# Logs: obj/build.log, sim.log.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
HERE=$(pwd)
CC=${CC:-/opt/riscv/bin/riscv64-unknown-elf-gcc}
OBJCOPY=${OBJCOPY:-/opt/riscv/bin/riscv64-unknown-elf-objcopy}
T=$(cd ../../RTL/CPU && pwd)
rm -rf obj; mkdir -p obj
$CC -nostdlib -nostartfiles -march=rv64gc -mabi=lp64 -Wl,-Ttext=0x80000000 dma_prog.S -o obj/dma_prog.elf || exit 1
$OBJCOPY -O binary obj/dma_prog.elf obj/dma_prog.bin || exit 1
python3 -c "
import sys
b = open('obj/dma_prog.bin', 'rb').read(); b += bytes(-len(b) % 8)
open('obj/dma_prog.hex', 'w').write(''.join('%016x\n' % int.from_bytes(b[i:i+8], 'little') for i in range(0, len(b), 8)))"
SRC=""
for f in OOO/OOO_UBTB2/OOO_UBTB2 OOO/OOO_FDEC2/OOO_FDEC2 OOO/OOO_TAGE2/OOO_TAGE2 OOO/OOO_BTB/OOO_BTB OOO/OOO_RAS/OOO_RAS \
         OOO/OOO_FETCH2/OOO_FETCH2 OOO/OOO_FTQ/OOO_FTQ OOO/OOO_FERS/OOO_FERS OOO/OOO_FBUF3/OOO_FBUF3 \
         CORE/CORE_DECOMP/CORE_DECOMP CORE/CORE_DEC/CORE_DEC OOO/OOO_RARE/OOO_RARE OOO/OOO_DEC/OOO_DEC OOO/OOO_FRONT/OOO_FRONT \
         OOO/OOO_RENAME2/OOO_RENAME2 OOO/OOO_BUSY/OOO_BUSY OOO/OOO_CTRL/OOO_CTRL OOO/OOO_DSREG/OOO_DSREG OOO/OOO_ROB/OOO_ROB \
         OOO/OOO_IQ3/OOO_IQ3 OOO/OOO_IQPL2/OOO_IQPL2 OOO/OOO_STAGE/OOO_STAGE OOO/OOO_ALU/OOO_ALU OOO/OOO_ALU2/OOO_ALU2 \
         OOO/OOO_PRF/OOO_PRF OOO/OOO_DTLB3/OOO_DTLB3 OOO/OOO_PMP/OOO_PMP OOO/OOO_PTW/OOO_PTW OOO/OOO_DCH2/OOO_DCH2 \
         OOO/OOO_LSU4/OOO_LSU4 CORE/CORE_CSR/CORE_CSR OOO/OOO_CSRU/OOO_CSRU OOO/OOO_TRAP/OOO_TRAP OOO/OOO_DBG/OOO_DBG \
         OOO/OOO_SYS/OOO_SYS OOO/OOO_PMUL/OOO_PMUL CORE/CORE_MDU/CORE_MDU OOO/OOO_MDUP/OOO_MDUP \
         FPU/FPU_ROUND/FPU_ROUND FPU/FPU_PIPE/FPU_PIPE OOO/OOO_FREN/OOO_FREN OOO/OOO_FIQ/OOO_FIQ OOO/OOO_FPUW/OOO_FPUW \
         OOO/OOO_CORE/OOO_CORE OOO/OOO_DMISS2/OOO_DMISS2 OOO/OOO_ICACHE/OOO_ICACHE OOO/OOO_MARB/OOO_MARB \
         CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY CACHE/CPU_L2/L2_TAG_ARRAY CACHE/CPU_L2/CPU_L2 \
         MMIO/CPU_CLINT/CPU_CLINT MMIO/CPU_PLIC/CPU_PLIC MMIO/CPU_MMIO/CPU_MMIO OOO/OOO_CPU/OOO_CPU \
         DBG/DBG_CDC/DBG_CDC DBG/DBG_CJTAG/DBG_CJTAG DBG/DBG_DTM/DBG_DTM DBG/DBG_DM/DBG_DM DBG/DBG_TOP/DBG_TOP TOP/CPU_TOP; do
    SRC="$SRC $T/$f.sv"
done
verilator --binary --timing -j 0 -O2 --top-module tb_CPU_TOP --Mdir obj -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
    $SRC ../OCD/AXI4_RAM.sv ../OCD/AXIL_RAM.sv tb_CPU_TOP.sv > obj/build.log 2>&1 \
    || { echo "run_top: build failed (see obj/build.log)"; exit 1; }
(cd obj && ./Vtb_CPU_TOP +verilator+rand+reset+2) | tee sim.log
grep -q "\] PASS" sim.log
