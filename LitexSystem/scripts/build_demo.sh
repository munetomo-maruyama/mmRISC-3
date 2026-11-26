#!/bin/bash
#---------------------------------------------------------------------------
# build_demo.sh : LiteX's bare-metal demo for a build of build_stock.sh, and
#                 the manifests the BIOS boots it with (step 2.0's SD card
#                 and TFTP checks, LitexSystem/docs/BRINGUP.md)
#
#   ./LitexSystem/scripts/build_demo.sh [build directory [name]]
#                  (default LitexSystem/build_stock_vexriscv_smp)
#   ./LitexSystem/scripts/build_demo.sh LitexSystem/build mm2
#                  step 2.3: mmRISC-2's SoC (build_soc.sh)
#
# What comes out, in <build>/demo/:
#   demo.bin    the demo (a small shell: help, led, donut, helloc, ...),
#               linked at main RAM
#   boot.json   {"demo.bin": main RAM}: the root of a FAT card, for sdcardboot
#   vex.json    the same, for `netboot vex.json` from the TFTP server, so as
#               not to take the server's boot.json (mmRISC-2's Linux)
#   <name>.json with a name: {"<name>/demo.bin": main RAM}, for
#               `netboot <name>.json`, demo.bin in the server's <name>/
#               (the server's demo.bin is VexRiscv's)
#---------------------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
REPO=$(dirname "$LITEX_SYSTEM")
LITEX_HOME=${LITEX_HOME:-$(cd "$REPO/../mmRISC-2/LitexRocket" 2>/dev/null && pwd)}
B=$(cd "${1:-$LITEX_SYSTEM/build_stock_vexriscv_smp}" && pwd)
source "$LITEX_HOME/.venv/bin/activate"
export PATH=/opt/riscv/bin:$PATH
RAM=$(awk -F, '$1 == "memory_region" && $2 == "main_ram" {print $3}' "$B/csr.csv")
[ -n "$RAM" ] || { echo "no main_ram in $B/csr.csv"; exit 1; }
rm -rf "$B/demo"; mkdir -p "$B/demo"; cd "$B/demo"
litex_bare_metal_demo --build-path="$B" > build.log 2>&1 || { tail build.log; exit 1; }
printf '{\n    "demo.bin": "%s"\n}\n' "$RAM" > boot.json
if [ -n "$2" ]; then
    printf '{\n    "%s/demo.bin": "%s"\n}\n' "$2" "$RAM" > "$2.json"
    echo "demo in $B/demo (demo.bin at $RAM, boot.json, $2.json for $2/demo.bin)"
else
    cp boot.json vex.json
    echo "demo in $B/demo (demo.bin at $RAM, boot.json, vex.json)"
fi
