#!/bin/bash
#---------------------------------------------------------------------------
# build_linux_vexriscv.sh : Linux for step 2.0's VexRiscv-SMP SoC
#                           (LitexSystem/docs/BRINGUP.md 12)
#
#   ./LitexSystem/scripts/build_linux_vexriscv.sh [build directory]
#       (default LitexSystem/build_stock_vexriscv_smp)
#
# linux-on-litex-vexriscv's pre-built images (its issue 164:
# linux_2022_03_23.zip, 5.4 MB: Linux 5.14 Image, Buildroot's rootfs.cpio,
# OpenSBI 0.8's opensbi.bin), downloaded once into <build>/linux/dl/, with
# the device tree generated here from the SoC's own csr.json (the archive's
# rv32.dtb is another SoC's: 64 MiB, other interrupts). Out, in <build>/linux/:
#   tftp/vexlinux/   Image, rv32.dtb, rootfs.cpio, opensbi.bin, boot.json
#                    with the paths under vexlinux/ (/srv/tftp keeps
#                    mmRISC-2's Image and boot.json):
#                      sudo cp -r <build>/linux/tftp/vexlinux /srv/tftp/
#                      litex> netboot vexlinux/boot.json
#   sd/              the same four files and boot.json, for a FAT card's root
#                    (written from the Mac): litex> sdcardboot
# Login root, no password. The kernel has no IP autoconfiguration (the DTB's
# ip= is ignored): ip addr add 192.168.0.50/24 dev eth0; ip link set eth0 up
#---------------------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
REPO=$(dirname "$LITEX_SYSTEM")
LITEX_HOME=${LITEX_HOME:-$(cd "$REPO/../mmRISC-2/LitexRocket" 2>/dev/null && pwd)}
BUILD=$(cd "${1:-$LITEX_SYSTEM/build_stock_vexriscv_smp}" && pwd)
L="$BUILD/linux"
ZIP="$L/dl/linux_2022_03_23.zip"
URL=https://github.com/litex-hub/linux-on-litex-vexriscv/files/8331338/linux_2022_03_23.zip

[ -f "$BUILD/csr.json" ] || { echo "no csr.json in $BUILD (build_stock.sh with CPU=vexriscv_smp)"; exit 1; }
if [ ! -f "$ZIP" ]; then
    mkdir -p "$L/dl"
    echo "downloading $URL (5.4 MB)"
    curl -L --fail -o "$ZIP" "$URL"
fi
rm -rf "$L/x" "$L/tftp" "$L/sd"
mkdir -p "$L/x" "$L/tftp/vexlinux" "$L/sd"
python3 -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ZIP" "$L/x"

source "$LITEX_HOME/.venv/bin/activate"
litex_json2dts_linux "$BUILD/csr.json" > "$L/rv32.dts"
dtc -O dtb -o "$L/rv32.dtb" "$L/rv32.dts"

# boot.json: opensbi.bin last, as the BIOS jumps to the last image's address
for d in tftp/vexlinux sd; do
    cp "$L/x/Image" "$L/x/rootfs.cpio" "$L/x/opensbi.bin" "$L/rv32.dtb" "$L/$d/"
done
P=vexlinux/
for d in tftp/vexlinux sd; do
    cat > "$L/$d/boot.json" <<EOF2
{
	"${P}Image":       "0x40000000",
	"${P}rv32.dtb":    "0x40ef0000",
	"${P}rootfs.cpio": "0x41000000",
	"${P}opensbi.bin": "0x40f00000"
}
EOF2
    P=
done
echo ""
echo "Linux images in $L"
echo "  TFTP:    sudo cp -r $L/tftp/vexlinux /srv/tftp/   then  litex> netboot vexlinux/boot.json"
echo "  SD card: the files of $L/sd at the card's root      then  litex> sdcardboot"
