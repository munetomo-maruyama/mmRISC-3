#!/bin/bash
#---------------------------------------------------------------------------
# build_soc.sh : step 2.1, the LiteX SoC around mmRISC-2 on the Nexys Video
#                (Doc/STRATEGY.md 2.1): LiteX's own target (as step 2.0,
#                through nexys_video_target.py), the CPU mmRISC-2 (Rev.02,
#                cpu/mmrisc/core.py, its RTL from mmRISC-2's repository),
#                the whole SoC at 50 MHz
#
#   ./LitexSystem/scripts/build_soc.sh [extra litex arguments]
#
# What comes out, in LitexSystem/build/ (not in git):
#   gateware/digilent_nexys_video.v / .xdc / .tcl  the SoC and its Vivado script
#   gateware/build_nexys_video.bat                 the Windows side's run
#   software/bios/bios.bin, csr.json, csr.csv      the BIOS and the map
#
# Step 2.1 is the first light: the map is mmRISC-2's (ROM 0x1000_0000, SRAM
# 0x1100_0000, CSRs 0x1200_0000, main RAM 0x8000_0000, 512 MiB here), and the
# whole SoC runs at the CPU's 50 MHz, as on the Arty. LiteDRAM then runs the
# DDR3 at 4 x 50 MHz, DDR3-400, below JEDEC's range (Doc/BOARD.md 4, option D,
# a trial only): step 2.2 puts LiteX at 100 MHz and the CPU at 50 MHz
# through crossings. Not yet here: the SD card and Ethernet (step 2.3), the
# debug port on JA (step 2.4).
#
# As mmRISC-2's build_soc.sh (its comments say why): --l2-size 0 (the SoC
# bus's L2, which this CPU never sees), physical optimisation after placement
# and routing (AggressiveExplore). The LiteX workspace and its environment
# are mmRISC-2's, as build_stock.sh; LiteX finds --cpu-type mmrisc by running
# from LitexSystem/cpu.
#---------------------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
REPO=$(dirname "$LITEX_SYSTEM")
LITEX_HOME=${LITEX_HOME:-$(cd "$REPO/../mmRISC-2/LitexRocket" 2>/dev/null && pwd)}
MMRISC2_HOME=${MMRISC2_HOME:-$(cd "$REPO/../mmRISC-2" 2>/dev/null && pwd)}
export MMRISC2_HOME
LITEX_WS="$LITEX_HOME/litex_ws"
VENV="$LITEX_HOME/.venv"
BUILD="$LITEX_SYSTEM/build"

[ -d "$VENV" ]                 || { echo "no venv at $VENV (mmRISC-2/LitexSystem/scripts/setup_litex.sh)"; exit 1; }
[ -d "$LITEX_WS" ]             || { echo "no LiteX workspace at $LITEX_WS"; exit 1; }
[ -d "$MMRISC2_HOME/RTL/CPU" ] || { echo "no mmRISC-2 RTL at $MMRISC2_HOME/RTL"; exit 1; }
source "$VENV/bin/activate"
export PATH=/opt/riscv/bin:$PATH

cd "$LITEX_SYSTEM/cpu"
python3 "$HERE/nexys_video_target.py" \
    --build --no-compile-gateware \
    --cpu-type mmrisc \
    --sys-clk-freq 50e6 \
    --l2-size 0 \
    --vivado-post-place-phys-opt-directive AggressiveExplore \
    --vivado-post-route-phys-opt-directive AggressiveExplore \
    --output-dir "$BUILD" \
    "$@"

G="$BUILD/gateware"
TCL="$G/digilent_nexys_video.tcl"
# Vivado runs on the other VM: every absolute path (this repository,
# mmRISC-2's RTL, LiteX's workspace) made relative to the gateware directory
if [ -f "$TCL" ]; then
    python3 - "$TCL" "$REPO" "$MMRISC2_HOME" "$LITEX_HOME" <<'PY'
import sys, os
tcl = sys.argv[1]
gw  = os.path.dirname(os.path.realpath(tcl))
text = open(tcl).read()
for root in sorted({os.path.realpath(p) for p in sys.argv[2:]}, key=len, reverse=True):
    n = text.count(root)
    text = text.replace(root, os.path.relpath(root, gw))
    print(f"  {n} absolute paths under {root} made relative")
open(tcl, "w").write(text)
PY
fi
cp "$HERE/build_nexys_video.bat" "$HERE/program_nexys_video.bat" "$HERE/program_nexys_video.tcl" "$G/"
echo ""
echo "SoC built in $BUILD"
echo "  next (Windows VM): gateware\\build_nexys_video.bat"
