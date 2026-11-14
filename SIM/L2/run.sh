#!/bin/bash
#---------------------------------------------------------------------------
# run.sh : the L2 (RTL/CPU/CACHE/CPU_L2) behind the memory bus's arbiter
# (RTL/CPU/OOO/OOO_MARB), step 1.7 H2, Plan/OOC.md 29.57
#
#   ./run.sh [config ...]     default: all; each prints one line, PASS or FAIL
#
#   L2_RTL=<dir>   another copy of RTL/CPU/CACHE (the bug injection of mutate.py)
#   OOO_RTL=<dir>  another copy of RTL/CPU/OOO (the same)
#   L2_OBJ=<dir>   where to build (default obj_dir)
#
# tb_L2.sv is mmRISC-2 Rev.02's SIM/SIM_L2 bench with two masters (the I$'s and
# the D$'s ports) and the part writes kept in the L2. The configurations are
# mmRISC-2's sweep (sweep.sh) less its large ones: the design (512 KB, 4 ways
# since step 1.7c C3; 256 KB before),
# and small L2s that evict all the time. Verilator builds every time (the
# shared folder keeps file times to one second).
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
HERE=$(pwd)
CA=${L2_RTL:-$(cd ../../RTL/CPU/CACHE && pwd)}
R=${OOO_RTL:-$(cd ../../RTL/CPU/OOO && pwd)}
OBJ=${L2_OBJ:-$HERE/obj_dir}
SRCS="$CA/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv $CA/CPU_L2/L2_TAG_ARRAY.sv $CA/CPU_L2/CPU_L2.sv $R/OOO_MARB/OOO_MARB.sv $HERE/AXI4_SLAVE_MEM.sv $HERE/tb_L2.sv"

declare -A P A D
D[big]="512 KB, 4 ways (the design)";      P[big]="";                                   A[big]="+ops=4000"
D[small]="8 KB, 4 ways";                    P[small]="-GL2_SIZE=8192";                   A[small]="+ops=20000"
D[rand]="8 KB, 4 ways, random";             P[rand]="-GL2_SIZE=8192 -GL2_RANDOM=1";      A[rand]="+ops=20000"
D[dm]="4 KB, direct mapped";                P[dm]="-GL2_SIZE=4096 -GL2_WAYS=1";          A[dm]="+ops=20000"
D[w8]="16 KB, 8 ways, memory 16 x";         P[w8]="-GL2_SIZE=16384 -GL2_WAYS=8 -GRANGE_X=16"; A[w8]="+ops=20000"
D[seed]="8 KB, 4 ways, another seed";       P[seed]="-GL2_SIZE=8192";                    A[seed]="+ops=20000 +seed=7"
CONFIGS=${*:-big small rand dm w8 seed}

fail=0
for c in $CONFIGS; do
    o=$OBJ/$c
    rm -rf $o; mkdir -p $o
    if ! verilator --binary --timing -j 2 --top-module tb_L2 -Wno-fatal -Mdir $o ${P[$c]} $SRCS > $o/build.log 2>&1; then
        echo "tb_L2 $c: build failed (see $o/build.log): FAIL"; fail=$((fail + 1)); continue
    fi
    timeout 1800 $o/Vtb_L2 ${A[$c]} +maxcycles=5000000 > $o/sim.log 2>&1
    if grep -q "RESULT : PASS" $o/sim.log; then
        echo "tb_L2 $c (${D[$c]}): $(grep 'RESULT' $o/sim.log | sed 's/ *L2 RESULT : //'): PASS"
    else
        echo "tb_L2 $c (${D[$c]}): $(grep -m3 'ERROR\|RESULT' $o/sim.log | tr '\n' ' '): FAIL"; fail=$((fail + 1))
    fi
done
exit $fail
