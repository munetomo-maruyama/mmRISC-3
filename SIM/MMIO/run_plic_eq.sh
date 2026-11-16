#!/bin/bash
#---------------------------------------------------------------------------
# run_plic_eq.sh : CPU_PLIC (RTL/CPU/MMIO, its choice a tree since step 1.8 I2,
# Plan/OOC.md 29.79) against mmRISC-2's (CPU_PLIC_MM2.sv: the choice a loop),
# side by side under the same random inputs (tb_plic_eq.cpp). PASS: no difference.
#---------------------------------------------------------------------------
set -e
cd "$(dirname "$0")"
verilator --cc --exe --build -O2 -Wno-fatal -Wno-lint --top-module tb_plic_eq \
    tb_plic_eq.sv ../../RTL/CPU/MMIO/CPU_PLIC/CPU_PLIC.sv CPU_PLIC_MM2.sv tb_plic_eq.cpp -Mdir obj_dir > obj_dir.log 2>&1 || { tail obj_dir.log; exit 1; }
./obj_dir/Vtb_plic_eq && echo "run_plic_eq: PASS" || { echo "run_plic_eq: FAIL"; exit 1; }
