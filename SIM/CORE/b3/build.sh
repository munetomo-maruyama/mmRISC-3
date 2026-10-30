#!/bin/bash
#---------------------------------------------------------------------------
# build.sh : B3's programs -> b3/work/<suite>-<test>.elf
#
#   ./build.sh
#
# riscv-tests' rv64ui (all but ma_data, a trap, and fence_i, FENCE.I: B4),
# rv64uc and the Zba / Zbb / Zbs / Zicond tests, on env/riscv_test.h (no
# CSRs; PASS / FAIL write tohost themselves) and riscv-tests' env/p layout;
# htif.S, characters through tohost with its polling loop.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
RT=${RISCV_TESTS:-$HOME/RISCV/riscv-tests}
CC=${CC:-/opt/riscv/bin/riscv64-unknown-elf-gcc}
mkdir -p work
n=0
for suite in rv64ui rv64uc rv64uzba rv64uzbb rv64uzbs rv64uzicond; do
    [ -d $RT/isa/$suite ] || continue
    for s in $RT/isa/$suite/*.S; do
        t=$(basename $s .S)
        case $suite-$t in rv64ui-ma_data|rv64ui-fence_i) continue;; esac
        $CC -nostdlib -nostartfiles -march=rv64gc_zba_zbb_zbc_zbs_zicond -mabi=lp64 -I env -I $RT/env -I $RT/isa/macros/scalar \
            -T $RT/env/p/link.ld $s -o work/$suite-$t.elf || exit 1
        n=$((n + 1))
    done
done
$CC -nostdlib -nostartfiles -march=rv64gc -mabi=lp64 -T $RT/env/p/link.ld htif.S -o work/htif.elf || exit 1   # the console
n=$((n + 1))
echo "build.sh: $n programs"
