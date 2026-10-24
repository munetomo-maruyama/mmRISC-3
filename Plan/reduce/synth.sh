#!/bin/bash
#---------------------------------------------------------------------------
# synth.sh : LUTs of one module of mmRISC-2, synthesized by Yosys for the
# Artix-7, with parameters changed
#
#   ./synth.sh TOP [PARAM=VALUE ...]
#
# The RTL of mmRISC-2 (the list of LitexSystem/cpu/mmrisc/core.py) is
# copied, the defaults of the given parameters of TOP are rewritten in the
# copy, and the copy is converted by sv2v. Changing the default before sv2v
# (not chparam after it) keeps every width sv2v derives from a parameter
# consistent. TOP and the modules it instantiates are synthesized alone
# (synth_xilinx -flatten) and one line is printed:
#   TOP PARAMS  LUT <logic LUTs> LUTRAM <LUTs as RAM> FF <flip-flops> DSP <n> BRAM <n>
# Every run has its own files under work/<run>/, so runs can go in parallel.
#
# Yosys is not Vivado: the absolute numbers differ, so only the differences
# between parameter values are used, scaled by the ratio of Vivado to Yosys
# at the default parameters (REDUCE.md).
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
YOSYS=${YOSYS:-$HOME/TinyTapeout/yosys/yosys}
SV2V=${SV2V:-$HOME/RISCV/sv2v/bin/sv2v}
R=$(cd ../../../mmRISC-2/RTL && pwd)

TOP=$1; shift
TAG=$(IFS=,; echo "$*")
D=work/${TOP}_${TAG//[=,]/_}
mkdir -p $D/rtl

SRCS=$(python3 -c "
import re
s = open('$R/../LitexSystem/cpu/mmrisc/core.py').read()
m = re.search(r'RTL_SOURCES = \[(.*?)\]', s, re.S)
print(' '.join(x for x in re.findall(r'\"([^\"]+\.sv)\"', m.group(1)) if 'CPU_BFM' not in x))")
LIST=""
for f in $SRCS; do
    mkdir -p $D/rtl/$(dirname $f)
    cp $R/$f $D/rtl/$f
    LIST="$LIST $D/rtl/$f"
done
# new defaults for the parameters of TOP, in the file that defines TOP
F=$(grep -l "^module $TOP\b" $LIST)
for p in "$@"; do
    k=${p%%=*}; v=${p#*=}
    grep -qE "parameter\s+(int\s+)?$k\s*=" $F || { echo "$TOP: no parameter $k"; exit 1; }
    sed -i -E "s/(parameter\s+(int\s+)?$k\s*=\s*)[^,)/ ]+/\1$v/" $F
done
$SV2V $LIST > $D/all.v 2> $D/sv2v.log || { echo "$TOP ${TAG}: sv2v failed"; exit 1; }
python3 deps.py $D/all.v $TOP > $D/top.v || exit 1
$YOSYS -q -l $D/yosys.log -p "read_verilog -sv $D/top.v; synth_xilinx -family xc7 -top $TOP -flatten; tee -q -o $D/stat.json stat -json" > /dev/null 2>&1 \
    || { echo "$TOP ${TAG}: yosys failed (see $D/yosys.log)"; exit 1; }
python3 - "$D/stat.json" "$TOP" "$TAG" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
mods = d['modules']
top = mods.get('\\' + sys.argv[2]) or mods[next(iter(mods))]
c = top.get('num_cells_by_type', {})
lut = sum(v for k, v in c.items() if k.startswith('LUT'))
ram = sum(v * (4 if k.startswith(('RAM64M', 'RAM32M')) else 1) for k, v in c.items()
          if k.startswith(('RAM', 'ram')) and not k.startswith('RAMB'))
ff = sum(v for k, v in c.items() if k.startswith('FD'))
dsp = sum(v for k, v in c.items() if k.startswith('DSP'))
bram = sum(v for k, v in c.items() if k.startswith('RAMB'))
print(f"{sys.argv[2]:12s} {sys.argv[3] or 'default':45s} LUT {lut:6d} LUTRAM {ram:5d} FF {ff:6d} DSP {dsp:3d} BRAM {bram:3d}")
EOF
