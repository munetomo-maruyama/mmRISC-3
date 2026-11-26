#!/bin/bash
#---------------------------------------------------------------------------
# build_soc.sh : step 2.1, the LiteX SoC around mmRISC-2 on the Nexys Video
#                (Doc/STRATEGY.md 2.1): LiteX's own target (as step 2.0,
#                through nexys_video_target.py), the CPU mmRISC-2 (Rev.02,
#                cpu/mmrisc/core.py, its RTL from mmRISC-2's repository);
#                step 2.2: LiteX at 100 MHz, the CPU at 50 MHz through
#                crossings; step 2.3: the microSD card (J3) and Ethernet
#                (RGMII, RTL8211E) with DHCP
#
#   ./LitexSystem/scripts/build_soc.sh [extra litex arguments]
#   SYS_CLK=50e6 CPU_CLK=50e6 ./LitexSystem/scripts/build_soc.sh
#                  step 2.1's SoC: everything at 50 MHz, the DDR3 at DDR3-400
#
# What comes out, in LitexSystem/build/ (not in git):
#   gateware/digilent_nexys_video.v / .xdc / .tcl  the SoC and its Vivado script
#   gateware/build_nexys_video.bat                 the Windows side's run
#   software/bios/bios.bin, csr.json, csr.csv      the BIOS and the map
#
# The map is mmRISC-2's (ROM 0x1000_0000, SRAM 0x1100_0000, CSRs 0x1200_0000,
# main RAM 0x8000_0000, 512 MiB here). Step 2.1 ran the whole SoC at the CPU's
# 50 MHz, as on the Arty, so LiteDRAM ran the DDR3 at 4 x 50 MHz, DDR3-400,
# below JEDEC's range (Doc/BOARD.md 4, option D, a trial). Step 2.2 (the
# default now): LiteX at SYS_CLK = 100 MHz, its default on this board (the
# DDR3 at DDR3-800, as step 2.0), the CPU at CPU_CLK = 50 MHz in a clock
# domain of its own from the same MMCM, its buses crossed in core.py
# (Doc/BOARD.md 4, option A). Step 2.3: --with-sdcard (the PHY without
# LiteSDCard's card reset, nexys_video_target.py, BRINGUP 10; its registers
# in the I/O blocks, as build_stock.sh and mmRISC-2), --with-ethernet
# --eth-dhcp (nexys_video_target.py: the BIOS takes its address by DHCP; the
# TFTP server is REMOTE_IP, default 192.168.0.42, changed at the litex>
# prompt with eth_remote_ip). The SD card's DMA goes on the CPU's DMA bus
# (core.py). Not yet here: the debug port on JA (step 2.4).
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
    --sys-clk-freq "${SYS_CLK:-100e6}" \
    --cpu-clk-freq "${CPU_CLK:-50e6}" \
    --with-sdcard \
    --with-ethernet --eth-dhcp \
    --remote-ip "${REMOTE_IP:-192.168.0.42}" \
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
XDC="$G/digilent_nexys_video.xdc"
if [ -f "$XDC" ] && grep -q "sdcard_clk" "$XDC" && ! grep -q "IOB TRUE.*sdcard" "$XDC"; then
    # (a newline first: LiteX's XDC ends without one)
    cat >> "$XDC" <<'EOF2'

# mmRISC-3 step 2.3: SD card PHY registers in the I/O blocks (build_soc.sh)
set_property IOB TRUE [get_ports {sdcard_clk sdcard_cmd {sdcard_data[*]}}]
EOF2
    echo "  SD card registers put in the I/O blocks"
fi
cp "$HERE/build_nexys_video.bat" "$HERE/program_nexys_video.bat" "$HERE/program_nexys_video.tcl" "$G/"
echo ""
echo "SoC built in $BUILD"
echo "  next (Windows VM): gateware\\build_nexys_video.bat"
