#!/bin/bash
#---------------------------------------------------------------------------
# sweep.sh : the synthesis runs behind REDUCE.md, 6 at a time
#
#   ./sweep.sh            -> results/sweep.txt
#
# CORE_CSR / CORE_MMU / CPU_PLIC with their parameters as in mmRISC-2
# (CPU_CORE passes HPM_EVENTS 30, TRIGGERS 4; CPU_TOP passes 31 PLIC
# sources) and with smaller values; the other modules at their defaults,
# to set the ratio of Vivado's LUTs to Yosys's.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
mkdir -p results
CSR="HPM_EVENTS=30"
cat > work/runs.txt <<EOF
CORE_CSR $CSR
CORE_CSR $CSR TRIGGERS=2
CORE_CSR $CSR TRIGGERS=1
CORE_CSR $CSR HPM_COUNTERS=2
CORE_CSR $CSR HPM_COUNTERS=0
CORE_CSR $CSR PMP_ENTRIES=4
CORE_CSR $CSR PMP_ENTRIES=0
CORE_CSR $CSR TRIGGERS=2 HPM_COUNTERS=2 PMP_ENTRIES=4
CORE_MMU
CORE_MMU PMP_ENTRIES=4
CORE_MMU PMP_ENTRIES=0
CORE_MMU ITLB_ENTRIES=8 DTLB_ENTRIES=16
CORE_MMU ITLB_ENTRIES=16 DTLB_ENTRIES=16
CORE_MMU PMP_ENTRIES=4 ITLB_ENTRIES=8 DTLB_ENTRIES=16
CPU_PLIC
CPU_CLINT
FPU_PIPE TAG_W=5
CORE_MDU
DCACHE
ICACHE
CPU_DBG
CORE_IFU
CORE_EXU
EOF

xargs -P 6 -L 1 ./synth.sh < work/runs.txt | sort > results/sweep.txt
cat results/sweep.txt
