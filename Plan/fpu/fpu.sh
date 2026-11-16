#!/bin/bash
#---------------------------------------------------------------------------
# fpu.sh : step 1.8 U0's study of the renamed FPU (Plan/OOC.md 29.80)
#
#   ./fpu.sh             -> results/kernels.txt, results/sweep.txt
#
# gen.py writes the DSP kernels (work/src), each is built for rv64gc and run
# on Spike (it checks itself: exit 0), Spike's log (work/log) goes through
# fpsched.py: once with the proposed sizes (results/kernels.txt: the
# instructions, the FPU operations, the cycles), then the FP queue, the FP
# physical registers, the FPU's latency, the LQ and the ROB varied
# (results/sweep.txt).
# work/ is not kept.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
CC=${CC:-/opt/riscv/bin/riscv64-unknown-elf-gcc}
SPIKE=${SPIKE:-$HOME/RISCV/toolchain/spike-install/bin/spike}
mkdir -p work/src work/elf work/log results
python3 gen.py work/src > /dev/null || exit 1
K=""
for s in work/src/*.S; do
    b=$(basename $s .S)
    $CC -nostdlib -nostartfiles -march=rv64gc -mabi=lp64d -T ../../SIM/CORE/b2/link.ld $s -o work/elf/$b.elf || exit 1
    $SPIKE --isa=rv64gc -l --log=work/log/$b.log work/elf/$b.elf || { echo "$b: FAILED on Spike"; exit 1; }
    K="$K $b"
done
ks() { nm work/elf/$1.elf | awk '$3 == "kstart" {print $1}'; }
ke() { nm work/elf/$1.elf | awk '$3 == "kend" {print $1}'; }
model() { python3 fpsched.py work/log/$1.log $(ks $1) $(ke $1) "${@:2}"; }

{
    echo "fpsched.py with the proposed sizes (w 4, rob 48, iq 24, fq 16, freg 64, lat 9, one FPU op and one FP store's data a cycle)"
    for b in $K; do printf "%-14s %s\n" $b "$(model $b)"; done
} | tee results/kernels.txt

{
    echo "FPU operations a cycle as the FP side is varied (the rest as results/kernels.txt)"
    hdr="kernel        "
    cols=("fq=8" "fq=12" "fq=24" "freg=48" "freg=80" "lat=10" "lq=24" "lq=32" "rob=64 lq=24" "rob=96 fq=32 freg=96 iq=32 lq=32 sq=32")
    for c in "${cols[@]}"; do hdr="$hdr $(printf '%8s' "${c%% *}")"; done
    echo "$hdr   (rob=64: with lq 24; rob=96: with fq 32, freg 96, iq 32, lq 32, sq 32)"
    for b in $K; do
        line=$(printf "%-14s" $b)
        for c in "${cols[@]}"; do
            v=$(model $b $c | sed -E 's/.*\(([0-9.]+) a cycle\).*/\1/')
            line="$line $(printf '%8s' $v)"
        done
        echo "$line"
    done
} | tee results/sweep.txt
