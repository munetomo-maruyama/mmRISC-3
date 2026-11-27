#!/bin/bash
#---------------------------------------------------------------------------
# build_dramlat.sh : software/dramlat (the memory's latency and throughput on
#                    the board, step 2.5, LitexSystem/docs/BRINGUP.md 27) for
#                    a build of build_soc.sh, into <build>/dramlat/
#
#   ./LitexSystem/scripts/build_dramlat.sh [build directory]   (default LitexSystem/build)
#
# Out: <build>/dramlat/dramlat.bin, linked at the main RAM (0x8000_0000), for
# the BIOS's serial boot (scripts/run_dramlat.py) or netboot.
#---------------------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
REPO=$(dirname "$LITEX_SYSTEM")
LITEX_HOME=${LITEX_HOME:-$(cd "$REPO/../mmRISC-2/LitexRocket" 2>/dev/null && pwd)}
B=$(cd "${1:-$LITEX_SYSTEM/build}" && pwd)
source "$LITEX_HOME/.venv/bin/activate"
export PATH=/opt/riscv/bin:$PATH
O="$B/dramlat"
mkdir -p "$O"
cp "$LITEX_SYSTEM/software/dramlat/"{Makefile,linker.ld,dramlat.c} "$O/"
make -C "$O" BUILD_DIR="$B" > "$O/build.log" 2>&1 || { tail -20 "$O/build.log"; exit 1; }
echo "dramlat in $O/dramlat.bin ($(stat -c %s "$O/dramlat.bin") bytes)"
