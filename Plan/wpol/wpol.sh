#!/bin/bash
#---------------------------------------------------------------------------
# wpol.sh : the D$'s write policy, measured (Plan/OOC.md 29.60)
#
#   ./wpol.sh        -> work/ (copies of the RTL and the bench), results/*.txt
#
# On copies, never on RTL/ or SIM/CORE: OOO_CPU with OOO_DMISS's write queue
# of 8, 16, 32, 64 (n8 .. n64), the same with the L2 answering a part write
# in 3 cycles, not 4 (l3n8, l3n16: cpu_l2_b3.patch, B with the last beat),
# and OOO_CORE with every D$ load a hit, its write taken 80 % of the cycles
# as the bench has it (core0) and every cycle (core1: a write that never
# waits, what a write-back D$ gives a store that hits). The bench with
# tb_core_wp.patch prints with -v a line "WP": the timed window, the stores
# the D$ wrote through, the cycles the queue was full, the stores to a word
# or a line already in the queue and not yet sent, fills held for the
# writes, the cycles the L2 was busy, the queue's mean occupancy.
# Programs: CoreMark g14-o2-zbsc (board's memory, -mlat 25), stset.S
# (memset of 4 KB, 16 times) and stcpy.S (memcpy of 4 KB, 16 times), both
# in the D$ (their timed window is the 16 passes).
# Made on the write-through RTL (commit d5d5eb9): the patches do not apply to
# the write-back D$ of step 1.7b W2 and later (check out d5d5eb9 to rerun).
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
H=$(pwd); ROOT=$(cd ../.. && pwd); W=$H/work
CC=${CC:-/opt/riscv/bin/riscv64-unknown-elf-gcc}
rm -rf $W; mkdir -p $W/sim $W/bw results
cp -r $ROOT/RTL/CPU/OOO $ROOT/RTL/CPU/CACHE $W/
cp $ROOT/SIM/CORE/{tb_core.cpp,bench.cc,bench.h,ports.h,build_core.sh} $W/sim/
cp tb_cpu_wp.vlt $W/sim/tb_cpu.vlt
patch -s $W/sim/tb_core.cpp tb_core_wp.patch || exit 1
mkdir -p $W/ca3; cp -r $W/CACHE/* $W/ca3/; patch -s $W/ca3/CPU_L2/CPU_L2.sv cpu_l2_b3.patch || exit 1
S=$W/sim/build_core.sh
sed -i "s#^R=.*#R=\${OOO_RTL:-$W/OOO}#; s#^C=.*#C=$ROOT/RTL/CPU/CORE#; s#^CA=.*#CA=\${OOO_CA:-$W/CACHE}#; s#\$HERE/\.\./LOCKSTEP#$ROOT/SIM/LOCKSTEP#g" $S
sed -i 's#CDEF="-DCPU_TOP#CDEF="-DWQN=${WQN:-8} -DCPU_TOP#; s#TOP=OOO_CORE; O=${OBJ:-$HERE/obj/core}; DEF=""; CDEF=""#TOP=OOO_CORE; O=${OBJ:-$HERE/obj/core}; DEF=""; CDEF="-DWT_ALWAYS=${WTA:-0}"#' $S
for k in stset stcpy; do $CC -nostdlib -nostartfiles -march=rv64gc -mabi=lp64 -T $ROOT/SIM/CORE/b2/link.ld $k.S -o $W/bw/$k.elf || exit 1; done
var()   # <name> <nwq> <cache dir>
{
    mkdir -p $W/rtl_$1; cp -r $W/OOO $W/rtl_$1/
    sed -i "s/parameter int NWQ = 8 /parameter int NWQ = $2 /" $W/rtl_$1/OOO/OOO_DMISS/OOO_DMISS.sv
    WQN=$2 OOO_RTL=$W/rtl_$1/OOO OOO_CA=$3 OBJ=$W/obj_$1 $S cpu
}
var n8 8 $W/CACHE & var n16 16 $W/CACHE & var n32 32 $W/CACHE & var n64 64 $W/CACHE &
var l3n8 8 $W/ca3 & var l3n16 16 $W/ca3 &
WTA=0 OOO_RTL=$W/OOO OBJ=$W/obj_core0 $S & WTA=1 OOO_RTL=$W/OOO OBJ=$W/obj_core1 $S &
wait
T=$ROOT/Plan/trace/work
E="$T/g14-o2-zbsc.elf $W/bw/stset.elf $W/bw/stcpy.elf"
O="+verilator+rand+reset+2 -max 100000000 -v"
for n in n8 n16 n32 n64 l3n8 l3n16; do $W/obj_$n/VOOO_CPU $O -mlat 25 $E > results/$n.txt 2>&1 & done
for n in core0 core1; do $W/obj_$n/VOOO_CORE $O -miss 0 -dhit 100 $E > results/$n.txt 2>&1 & done
wait
grep -H "PASS\|FAIL\|timed window\|WP" results/*.txt
