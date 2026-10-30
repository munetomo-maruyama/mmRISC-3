#!/bin/bash
#---------------------------------------------------------------------------
# build.sh : B2's and B3's test programs (gen_b2.py) -> b2/work/<kind>-<seed>.elf
#
#   ./build.sh [n]      n programs of each kind (default 10)
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
N=${1:-10}
CC=${CC:-/opt/riscv/bin/riscv64-unknown-elf-gcc}
mkdir -p work
for kind in alu br ls; do
    for s in $(seq 1 $N); do
        ./gen_b2.py $kind $s $([ $kind = alu ] && echo 400 || echo 160) > work/$kind-$s.S || exit 1
        $CC -nostdlib -nostartfiles -march=rv64gc_zba_zbb_zbs_zicond -mabi=lp64 -T link.ld work/$kind-$s.S -o work/$kind-$s.elf || exit 1
    done
done
