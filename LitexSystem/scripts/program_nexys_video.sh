#!/bin/bash
#---------------------------------------------------------------------------
# program_nexys_video.sh : load a bitstream into the Nexys Video's FPGA over
#                          J12 from this Linux VM, with openFPGALoader
#                          (volatile; step 2.0, LitexSystem/docs/BRINGUP.md 6)
#
#   ./LitexSystem/scripts/program_nexys_video.sh [bitstream]
#       (default LitexSystem/build_stock_vexriscv_smp/gateware/digilent_nexys_video.bit)
#
# J12 (the Digilent USB-JTAG, an FT2232H, 0403:6010) must be connected to this
# VM (Parallels: Devices > USB), as J13's FT232R is for the UART. The cable is
# openFPGALoader's digilent_b (the FT2232H's port B), as for -b nexysVideo.
# The Windows side's program_nexys_video.bat found no cable from a batch
# Vivado while the GUI could program (BRINGUP 6).
#---------------------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
BIT=${1:-$LITEX_SYSTEM/build_stock_vexriscv_smp/gateware/digilent_nexys_video.bit}
[ -f "$BIT" ] || { echo "no bitstream: $BIT"; exit 1; }
lsusb -d 0403:6010 > /dev/null || { echo "J12 (0403:6010) is not connected to this VM (Parallels: Devices > USB)"; exit 1; }
openFPGALoader -b nexysVideo "$BIT"
