#!/bin/bash
#---------------------------------------------------------------------------
# yest.sh : Yosys estimates for the FP blocks of step 1.8 U0 (Plan/OOC.md
# 29.80): the blocks of the integer side as built, then with the FP side's
# sizes, so that the ratio can be applied to Vivado's count of the block as
# built (Yosys's own counts are not Vivado's: Plan/REDUCE.md)
#
#   ./yest.sh            -> results/yest.txt
#
#   OOC_PRF      NREG 80 NW 6 NR 10 (as built) / 64 3 4 / 48 3 4 (the FP file)
#   OOO_IQ3      N 24 TAGW 7 (as built) / N 16 TAGW 6 (the FP queue's size; it
#                has 2 sources and 6 ports, the FP queue 3 and 2: see 29.80)
#   OOO_RENAME2  NREG 80 TAGW 7 (as built) / NREG 64 TAGW 6 (the FP map; 2
#                sources a µop, the FP map 3: see 29.80)
# Uses FPGA/OOO_OOC/yosys_size.sh's tools (YOSYS, SV2V).
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
YOSYS=${YOSYS:-$HOME/TinyTapeout/yosys/yosys}
SV2V=${SV2V:-$HOME/RISCV/sv2v/bin/sv2v}
R=../../RTL/CPU/OOO
mkdir -p work/yosys results

one() {   # one <top> <file> [NAME=value ...]
    local top=$1 f=$2; shift 2
    local tag=$top; for g in "$@"; do tag="${tag}_${g//=/}"; done
    local d=work/yosys/$tag; mkdir -p $d
    cp $f $d/
    local src=$d/$(basename $f)
    for g in "$@"; do sed -i -E "s/(parameter int ${g%%=*} *= *)[0-9]+/\1${g#*=}/" $src; done
    $SV2V $src > $d/all.v 2> $d/sv2v.log || { echo "$tag: sv2v failed"; return; }
    $YOSYS -q -l $d/yosys.log -p "read_verilog $d/all.v; synth_xilinx -family xc7 -top $top -flatten;
        tee -q -o $d/stat.json stat -json" > /dev/null 2>&1 || { echo "$tag: yosys failed"; return; }
    python3 - $d/stat.json "$tag" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
m = list(d['modules'].values())[0]
c = m.get('num_cells_by_type', {})
lut = sum(v for k, v in c.items() if k.startswith('LUT'))
ram = sum(v * (4 if k.startswith(('RAM64M', 'RAM32M')) else 1) for k, v in c.items() if k.startswith('RAM') and not k.startswith('RAMB'))
ff = sum(v for k, v in c.items() if k.startswith('FD'))
print(f"{sys.argv[2]:28s} LUT {lut:6d}  LUTRAM {ram:5d}  FF {ff:6d}")
EOF
}

{
one OOO_PRF $R/OOO_PRF/OOO_PRF.sv NREG=80 NW=6 NR=10
one OOO_PRF $R/OOO_PRF/OOO_PRF.sv NREG=64 NW=3 NR=4
one OOO_PRF $R/OOO_PRF/OOO_PRF.sv NREG=48 NW=3 NR=4
one OOO_IQ3 $R/OOO_IQ3/OOO_IQ3.sv N=24 TAGW=7
one OOO_IQ3 $R/OOO_IQ3/OOO_IQ3.sv N=16 TAGW=6
one OOO_RENAME2 $R/OOO_RENAME2/OOO_RENAME2.sv NREG=80 TAGW=7
one OOO_RENAME2 $R/OOO_RENAME2/OOO_RENAME2.sv NREG=64 TAGW=6
} | tee results/yest.txt
