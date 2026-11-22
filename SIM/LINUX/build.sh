#!/bin/bash
#---------------------------------------------------------------------------
# build.sh : the Linux image of the simulation bench (step 1.8 L1,
#            Plan/OOC.md 29.99)
#
#   ./build.sh        -> work/linux.elf (and work/linux.dtb, work/initrd.cpio.gz)
#   CBOZ=0 ./build.sh -> work/linux_nocboz.elf: the device tree without Zicboz (a
#                        diagnostic: Linux then zeroes pages with stores)
#   PAYLOAD=pmu_sbi ./build.sh -> work/pmu_sbi.elf: pmu_sbi/ (mmRISC-2's S-mode
#                        program on the SBI PMU extension, as Linux's perf calls
#                        it) in place of the kernel; it ends by the SBI system reset
#
# One ELF that SIM/CORE's tb_core (OOO_CPU, in lock-step with Spike) and Spike
# itself load as they load a test:
#   0x8000_0000  OpenSBI fw_jump (generic, linked here: FW_PIC=n, so its
#                tohost / fromhost are absolute), with bench.dts built in
#                (FW_FDT_PATH; it gives the tree to Linux at 0x8240_0000) and
#                mmRISC-2's OpenSBI patches (software/boot/opensbi_patches)
#   0x8020_0000  the kernel: mmRISC-2's (litex-hub/linux 7.2.0-rc2 and
#                software/boot/linux.config, the one that runs on its board),
#                with the SBI console added (HVC_RISCV_SBI and its early
#                console: the bench has HTIF, not LiteUART), built out of the
#                tree into $KBUILD
#   0x8200_0000  the initramfs: mmRISC-2's BusyBox (~/mmlitex_build/initrd_bb,
#                as its SIM_BIOS ran) with overlay/ appended (a second cpio:
#                the kernel unpacks both, the later file wins): inittab runs
#                overlay/l1.sh, an interactive ash on a few commands, then
#                poweroff (HTIF's exit)
# tohost / fromhost: OpenSBI's own, as symbols of the ELF (the bench and the
# reference find HTIF by them).
#
# The sources, outside this repository (as Plan/csize's):
#   MMRISC2  mmRISC-2's repository (patches, linux.config) and its kernel
#            source (LitexRocket/software/linux) and OpenSBI
#            (LitexRocket/software/opensbi, 3593a5f)
#   INITRD   the BusyBox initramfs
#   KBUILD   the kernel's build directory (about 300 MB: local disk)
#---------------------------------------------------------------------------
set -e
cd "$(dirname "$0")"
H=$(pwd); W=$H/work; mkdir -p $W
MMRISC2=${MMRISC2:-$(cd $H/../../.. && pwd)/mmRISC-2}
LINUX=${LINUX:-$MMRISC2/LitexRocket/software/linux}
OPENSBI=${OPENSBI:-$MMRISC2/LitexRocket/software/opensbi}
INITRD=${INITRD:-$HOME/mmlitex_build/initrd_bb}
KBUILD=${KBUILD:-$HOME/mmrisc3_linux/kbuild}
X=/opt/riscv/bin/riscv64-unknown-linux-gnu-
E=/opt/riscv/bin/riscv64-unknown-elf-

# ---- the kernel: mmRISC-2's configuration with the SBI console
mkdir -p $KBUILD
{ cat $MMRISC2/LitexSystem/software/boot/linux.config
  echo CONFIG_NONPORTABLE=y; echo CONFIG_HVC_RISCV_SBI=y; echo CONFIG_SERIAL_EARLYCON_RISCV_SBI=y; } > $W/kernel.config
if ! cmp -s $W/kernel.config $KBUILD/.config.in; then
    cp $W/kernel.config $KBUILD/.config.in; cp $W/kernel.config $KBUILD/.config
    make -C $LINUX O=$KBUILD ARCH=riscv CROSS_COMPILE=$X olddefconfig > $W/kernel.log 2>&1
fi
echo "== the kernel"
make -C $LINUX O=$KBUILD ARCH=riscv CROSS_COMPILE=$X -j$(nproc) Image >> $W/kernel.log 2>&1 || { tail -20 $W/kernel.log; exit 1; }
cp $KBUILD/arch/riscv/boot/Image $W/Image
K=$W/Image
if [ "${PAYLOAD:-}" = pmu_sbi ]; then
    echo "== pmu_sbi"
    ${E}gcc -march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany -O2 -nostdlib -nostartfiles -ffreestanding \
        -Wl,--no-warn-rwx-segments -T $H/pmu_sbi/link.ld -o $W/pmu_sbi_s.elf $H/pmu_sbi/start.S $H/pmu_sbi/pmu_sbi.c
    ${E}objcopy -O binary $W/pmu_sbi_s.elf $W/pmu_sbi.bin
    K=$W/pmu_sbi.bin
fi

# ---- the initramfs: BusyBox, then the overlay
echo "== the initramfs"
gcc -O2 -o $W/gen_init_cpio $LINUX/usr/gen_init_cpio.c
cat > $W/overlay.txt <<EOF
dir /etc 755 0 0
file /etc/inittab $H/overlay/inittab 644 0 0
dir /root 700 0 0
file /root/l1.sh $H/overlay/l1.sh 755 0 0
EOF
$W/gen_init_cpio $W/overlay.txt | gzip -9n > $W/overlay.cpio.gz
cat $INITRD $W/overlay.cpio.gz > $W/initrd.cpio.gz

# ---- the device tree: the initramfs's end
end=$(printf '0x%x' $(( 0x82000000 + $(stat -c %s $W/initrd.cpio.gz) )))
N=linux; [ "${CBOZ:-1}" = 0 ] && N=linux_nocboz; [ "${PAYLOAD:-}" = pmu_sbi ] && N=pmu_sbi
sed "s/<INITRD_END>/<$end>/" $H/bench.dts > $W/linux.dts
[ $N = linux_nocboz ] && sed -i 's/_zicboz//; s/"zicboz", //; /cboz-block-size/d' $W/linux.dts
dtc -q -I dts -O dtb -o $W/linux.dtb $W/linux.dts

# ---- OpenSBI: a copy with mmRISC-2's patches, linked at 0x8000_0000
echo "== OpenSBI"
rm -rf $W/opensbi; cp -r $OPENSBI $W/opensbi; rm -rf $W/opensbi/build
for p in $MMRISC2/LitexSystem/software/boot/opensbi_patches/*.patch; do patch -s -p1 -d $W/opensbi < $p; done
make -C $W/opensbi -j$(nproc) PLATFORM=generic CROSS_COMPILE=$X FW_PIC=n FW_TEXT_START=0x80000000 \
    FW_FDT_PATH=$W/linux.dtb FW_JUMP_ADDR=0x80200000 FW_JUMP_FDT_ADDR=0x82400000 > $W/opensbi.log 2>&1 || { tail -20 $W/opensbi.log; exit 1; }
F=$W/opensbi/build/platform/generic/firmware
th=$(${E}nm $F/fw_jump.elf | awk '$3 == "tohost" { print "0x" $1 }')
fh=$(${E}nm $F/fw_jump.elf | awk '$3 == "fromhost" { print "0x" $1 }')
[ -n "$th" ] && [ -n "$fh" ] || { echo "OpenSBI has no tohost / fromhost"; exit 1; }
cp $F/fw_jump.bin $W/fw_jump.bin

# ---- one ELF
echo "== $N.elf"
cat > $W/image.S <<EOF
    .section .sbi, "ax"
    .incbin "$W/fw_jump.bin"
    .section .kernel, "ax"
    .incbin "$K"
    .section .initrd, "a"
    .incbin "$W/initrd.cpio.gz"
EOF
cat > $W/image.ld <<EOF
OUTPUT_ARCH(riscv)
ENTRY(_start)
PHDRS { sbi PT_LOAD; kernel PT_LOAD; initrd PT_LOAD; }
SECTIONS {
    . = 0x80000000; .sbi    : { _start = .; *(.sbi) } :sbi
    . = 0x80200000; .kernel : { *(.kernel) } :kernel
    . = 0x82000000; .initrd : { *(.initrd) } :initrd
}
EOF
${E}as -march=rv64gc -o $W/image.o $W/image.S
${E}ld -T $W/image.ld --defsym=tohost=$th --defsym=fromhost=$fh -o $W/$N.elf $W/image.o
echo "work/$N.elf: OpenSBI $(stat -c %s $W/fw_jump.bin), $(basename $K) $(stat -c %s $K), initramfs $(stat -c %s $W/initrd.cpio.gz) bytes; tohost $th, fromhost $fh"
