#!/bin/bash
#---------------------------------------------------------------------------
# csize.sh : the caches' sizes on an OS workload (Plan/OOC.md 29.64)
#
#   ./csize.sh       -> work/ (OpenSBI, the initrds, the logs), results/
#
# Linux (the kernel Image of $LINUX, defconfig) boots under Spike with its cache
# models (--ic, --dc, --l2: S sets : W ways : 64-byte lines) on OpenSBI's
# fw_jump (generic, built from $OPENSBI into work/sbi), with an initramfs of a
# static busybox ($BUSYBOX) and init_work (3 rounds of ls -lR /sys, 4 MB of
# zeros md5summed, gzip / gunzip of busybox, find / and sort, cp and cmp of
# 4 MB, awk) or init_boot (nothing: power off). Spike prints the caches'
# counts once, at the exit, so the workload is work minus boot (parse.py).
# Each run boots Linux: 10 to 25 minutes; 8 at a time.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
H=$(pwd); W=$H/work; mkdir -p $W/res results
S=${SPIKE:-$HOME/RISCV/toolchain/spike-install}/bin/spike
LINUX=${LINUX:-$HOME/RISCV/riscv64-linux/linux}
BUSYBOX=${BUSYBOX:-$HOME/RISCV/riscv64-linux/busybox/busybox}
OPENSBI=${OPENSBI:-$HOME/RISCV/mmRISC-2/LitexRocket/software/opensbi}
make -C $OPENSBI O=$W/sbi PLATFORM=generic CROSS_COMPILE=/opt/riscv/bin/riscv64-unknown-linux-gnu- -j8 > $W/sbi.log 2>&1 || exit 1
gcc -O2 -o $W/gen_init_cpio $LINUX/usr/gen_init_cpio.c || exit 1
for n in boot work; do
    sed "s#\$HOME/RISCV/riscv64-linux/busybox/busybox#$BUSYBOX#; s#\$W/init_work#$H/init_$n#" initrd.txt > $W/list_$n.txt
    $W/gen_init_cpio $W/list_$n.txt > $W/initrd_$n.cpio || exit 1
done
run()   # <cfg> <initrd> <ic> <dc> <l2>
{
    timeout 5400 $S -p1 --isa=rv64gc_zicntr --kernel=$LINUX/arch/riscv/boot/Image --initrd=$W/initrd_$2.cpio \
        --ic=$3 --dc=$4 --l2=$5 $W/sbi/platform/generic/firmware/fw_jump.elf > $W/res/$1_$2.log 2>&1
    grep -E '^(L2|D|I)\$ ' $W/res/$1_$2.log > results/$1_$2.txt
}
C1=("base 64:8:64 64:4:64 1024:4:64" "d32 64:8:64 64:8:64 1024:4:64" "d64 64:8:64 64:16:64 1024:4:64" "i64 64:16:64 64:4:64 1024:4:64"
    "l512 64:8:64 64:4:64 2048:4:64" "l1m 64:8:64 64:4:64 4096:4:64" "big 64:16:64 64:8:64 2048:4:64" "i16 64:4:64 64:4:64 1024:4:64")
C2=("i64s 128:8:64 64:4:64 1024:4:64" "i128s 256:8:64 64:4:64 1024:4:64" "d32s 64:8:64 128:4:64 1024:4:64" "l512w8 64:8:64 64:4:64 1024:8:64"
    "big2 128:8:64 64:8:64 2048:4:64" "d64s 64:8:64 256:4:64 1024:4:64" "rec 256:8:64 256:4:64 1024:4:64")
for set in C1 C2; do
    declare -n L=$set
    for n in work boot; do
        for c in "${L[@]}"; do set -- $c; run $1 $n $2 $3 $4 & done
        wait
    done
done
./parse.py > results/table.txt; cat results/table.txt
