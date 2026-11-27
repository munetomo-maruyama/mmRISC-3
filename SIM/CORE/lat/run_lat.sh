#!/bin/bash
#---------------------------------------------------------------------------
# run_lat.sh : the pointer chase on OOO_CPU (the real caches) against
#              tb_core's memory model, for -mlat values (step 2.5: the board's
#              DRAM latency into the model, LitexSystem/docs/BRINGUP.md 27)
#
#   ./run_lat.sh [mlat ...]        (default 25 20 15 13 10)
#
# 256 KB random: past the D$ (128 KB), in the L2 (512 KB); 2 MB random and
# linear: past the L2, the memory model's latency. Prints the cycles of one
# load; the board's (dramlat on mmRISC-2) are compared in BRINGUP 27.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
ML=${*:-25 20 15 13 10}
CC=${CC:-/opt/riscv/bin/riscv64-unknown-elf-gcc}
../build_core.sh cpu > /dev/null || exit 1
mkdir -p work
for c in "256 random" "2048 random" "2048 linear"; do
    set -- $c
    [ -f work/chase_$1_$2.elf ] && continue
    python3 gen_chase.py $1 $2 > work/chase_$1_$2.S
    $CC -nostdlib -nostartfiles -march=rv64gc -mabi=lp64 -T ../b2/link.ld work/chase_$1_$2.S -o work/chase_$1_$2.elf || exit 1
done
for m in $ML; do
    for c in 256_random 2048_random 2048_linear; do
        ( n=$(( ${c%%_*} * 16 ))
          w=$(../obj/cpu/VOOO_CPU +verilator+rand+reset+2 -max 100000000 -v -mlat $m work/chase_$c.elf 2>&1 |
              awk '/timed window/ {print $(NF-1)}')
          awk -v m=$m -v c=$c -v w=$w -v n=$n 'BEGIN {printf "mlat %3d  %-12s %8d cycles  %6.2f cycles/load\n", m, c, w, w / n}' ) &
    done
    wait
done
