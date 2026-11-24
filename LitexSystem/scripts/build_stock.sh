#!/bin/bash
#---------------------------------------------------------------------------
# build_stock.sh : step 2.0, LiteX's own Nexys Video target as it is
#                  (Doc/STRATEGY.md 2.0, Doc/BOARD.md 2): Rocket (linux
#                  variant, one core) at 100 MHz, LiteDRAM's DDR3 at
#                  DDR3-800, the SD card, Ethernet over RGMII
#
#   ./LitexSystem/scripts/build_stock.sh [extra litex arguments]
#   SYS_CLK=50e6 ./LitexSystem/scripts/build_stock.sh     (another clock)
#
# What comes out, in LitexSystem/build_stock/ (not in git):
#   gateware/digilent_nexys_video.v / .xdc / .tcl  the SoC and its Vivado script
#   gateware/build_nexys_video.bat                 the Windows side's run
#   software/bios/bios.bin, csr.json, csr.csv      the BIOS and the map
#
# The LiteX workspace and its virtual environment are mmRISC-2's (pinned
# versions, mmRISC-2/LitexSystem/scripts/setup_litex.sh); LITEX_HOME points
# elsewhere. As build_soc.sh in mmRISC-2: no Vivado here (it lives on the
# Windows VM); the tcl's paths to this repository are made relative.
#
# Changes from the stock target, all from mmRISC-2's bring-up on the Arty:
#   the SD card's output registers in the I/O blocks (LitexSystem/docs of
#   mmRISC-2, BRINGUP 13: CRC errors in Linux otherwise); physical
#   optimisation after placement and routing (AggressiveExplore).
# Ethernet: the target has no DHCP option (Doc/BOARD.md 2), so the board is
# ETH_IP (192.168.1.50) and the TFTP server REMOTE_IP (192.168.1.100), both
# changeable at the litex> prompt (eth_local_ip, eth_remote_ip).
#---------------------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
REPO=$(dirname "$LITEX_SYSTEM")
LITEX_HOME=${LITEX_HOME:-$(cd "$REPO/../mmRISC-2/LitexRocket" 2>/dev/null && pwd)}
LITEX_WS="$LITEX_HOME/litex_ws"
VENV="$LITEX_HOME/.venv"
BUILD="$LITEX_SYSTEM/build_stock"

[ -d "$VENV" ]     || { echo "no venv at $VENV (mmRISC-2/LitexSystem/scripts/setup_litex.sh)"; exit 1; }
[ -d "$LITEX_WS" ] || { echo "no LiteX workspace at $LITEX_WS"; exit 1; }
source "$VENV/bin/activate"
export PATH=/opt/riscv/bin:$PATH
# Rocket's pre-generated Verilog (pythondata-cpu-rocket) is in the workspace
# but not installed in mmRISC-2's venv: found through PYTHONPATH, the venv
# left as it is
export PYTHONPATH="$LITEX_WS/pythondata-cpu-rocket${PYTHONPATH:+:$PYTHONPATH}"

python3 "$LITEX_WS/litex-boards/litex_boards/targets/digilent_nexys_video.py" \
    --build --no-compile-gateware \
    --cpu-type rocket --cpu-variant linux \
    --sys-clk-freq "${SYS_CLK:-100e6}" \
    --with-sdcard \
    --with-ethernet \
    --eth-ip "${ETH_IP:-192.168.1.50}" \
    --remote-ip "${REMOTE_IP:-192.168.1.100}" \
    --vivado-post-place-phys-opt-directive AggressiveExplore \
    --vivado-post-route-phys-opt-directive AggressiveExplore \
    --output-dir "$BUILD" \
    "$@"

G="$BUILD/gateware"
TCL="$G/digilent_nexys_video.tcl"
# Vivado runs on the other VM, where the shares are mounted elsewhere: every
# absolute path (this repository, LiteX's workspace with Rocket's Verilog)
# made relative to the gateware directory
if [ -f "$TCL" ]; then
    python3 - "$TCL" "$REPO" "$LITEX_HOME" <<'PY'
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
XDC="$G/digilent_nexys_video.xdc"
if [ -f "$XDC" ] && grep -q "sdcard_clk" "$XDC" && ! grep -q "IOB TRUE.*sdcard" "$XDC"; then
    cat >> "$XDC" <<'EOF2'
# mmRISC-3 step 2.0: SD card PHY registers in the I/O blocks (build_stock.sh)
set_property IOB TRUE [get_ports {sdcard_clk sdcard_cmd {sdcard_data[*]}}]
EOF2
    echo "  SD card registers put in the I/O blocks"
fi
cp "$HERE/build_nexys_video.bat" "$G/"
echo ""
echo "SoC built in $BUILD"
echo "  next (Windows VM): gateware\\build_nexys_video.bat"
