#!/bin/bash
#---------------------------------------------------------------------------
# yosys_size.sh : a first estimate of the blocks of synth_ooo.tcl with
# Yosys (synth_xilinx for the Artix-7), before the author's Vivado runs
#
#   ./yosys_size.sh            -> output/yosys_size.txt
#   ./yosys_size.sh <top> [NAME=value ...]   one run, printed only
#
# For every top: LUTs, LUT RAM, flip-flops, CARRY4 and the longest path in
# cells between flip-flops (ltp -noff: LUTs, multiplexers and carry chains in
# a row), the logic depth that Vivado's timing will turn into nanoseconds.
# Yosys is not Vivado: the LUT counts differ (Plan/REDUCE.md measured
# ratios of 0.5 to 1.4 per module), and only Vivado gives the delay.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
YOSYS=${YOSYS:-$HOME/TinyTapeout/yosys/yosys}
SV2V=${SV2V:-$HOME/RISCV/sv2v/bin/sv2v}
R=../../RTL/CPU/OOO
mkdir -p output/yosys
SRCS="$R/OOO_ALU/OOO_ALU.sv $R/OOO_ALU2/OOO_ALU2.sv $R/OOO_FUSE/OOO_FUSE.sv $R/OOO_PRF/OOO_PRF.sv
      $R/OOO_RENAME/OOO_RENAME.sv $R/OOO_IQ/OOO_IQ.sv $R/OOO_UBTB/OOO_UBTB.sv $R/OOO_LSU/OOO_LSU.sv $R/OOO_ROB/OOO_ROB.sv
      $R/OOO_FBUF/OOO_FBUF.sv $R/OOO_FTQ/OOO_FTQ.sv $R/OOO_PREDEC/OOO_PREDEC.sv $R/OOO_TAGE/OOO_TAGE.sv
      $R/OOO_BTB/OOO_BTB.sv $R/OOO_RAS/OOO_RAS.sv $R/OOO_FETCH/OOO_FETCH.sv rtl/OOC_WRAP.sv"

one() {   # one <top> [NAME=value ...]
    local top=$1; shift
    local tag=$top; for g in "$@"; do tag="${tag}_${g//=/}"; done
    local d=output/yosys/$tag; mkdir -p $d
    # the parameters of OOC_PRF: new defaults in a copy, before sv2v
    local srcs=""
    for f in $SRCS; do cp $f $d/; srcs="$srcs $d/$(basename $f)"; done
    for g in "$@"; do
        sed -i -E "s/(parameter int ${g%%=*} *= *)[0-9]+/\1${g#*=}/" $d/OOC_WRAP.sv $d/OOO_PRF.sv
    done
    $SV2V $srcs > $d/all.v 2> $d/sv2v.log || { echo "$tag: sv2v failed"; return; }
    $YOSYS -q -l $d/yosys.log -p "read_verilog $d/all.v; synth_xilinx -family xc7 -top $top -flatten;
        tee -q -o $d/stat.json stat -json; tee -q -o $d/ltp.txt ltp -noff" > /dev/null 2>&1 \
        || { echo "$tag: yosys failed (see $d/yosys.log)"; return; }
    python3 - $d/stat.json $d/ltp.txt "$tag" <<'EOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
m = list(d['modules'].values())[0]
c = m.get('num_cells_by_type', {})
lut = sum(v for k, v in c.items() if k.startswith('LUT'))
ram = sum(v * (4 if k.startswith(('RAM64M', 'RAM32M')) else 1) for k, v in c.items() if k.startswith('RAM') and not k.startswith('RAMB'))
ff = sum(v for k, v in c.items() if k.startswith('FD'))
cy = c.get('CARRY4', 0)
lt = open(sys.argv[2]).read()
mm = re.search(r'Longest topological path in .* \(length=(\d+)\)', lt)
print(f"{sys.argv[3]:22s} LUT {lut:6d}  LUTRAM {ram:5d}  FF {ff:6d}  CARRY4 {cy:4d}  longest path {mm.group(1) if mm else '?':>3s} cells")
EOF
}

run_all() {
one OOC_ALU2
one OOC_FUSE
one OOC_RENAME
one OOO_IQ
one OOO_UBTB
one OOC_LSU
one OOC_ROB
one OOC_FBUF
one OOC_FTQ
one OOC_FRONT
one OOC_PRF NW=3 NR=8
one OOC_PRF NW=5 NR=8
one OOC_PRF NW=6 NR=9
one OOC_PRF NW=3 NR=6
one OOC_PRF NW=5 NR=6
}
if [ $# -gt 0 ]; then one "$@"; else run_all | tee output/yosys_size.txt; fi
