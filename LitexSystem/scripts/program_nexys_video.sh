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
#
# Step 2.4: the external FT2232H of the debug port ("Dual RS232") has the
# same 0403:6010, so J12 is picked by its product name, "Digilent USB
# Device", and passed to openFPGALoader by its USB bus and device numbers
# (not its FTDI serial: libftdi stops at the other FT2232H, which has none);
# with several FT2232Hs openFPGALoader would otherwise take the first it finds.
#---------------------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
BIT=${1:-$LITEX_SYSTEM/build_stock_vexriscv_smp/gateware/digilent_nexys_video.bit}
[ -f "$BIT" ] || { echo "no bitstream: $BIT"; exit 1; }
BUSDEV=""
for d in /sys/bus/usb/devices/*; do
    [ "$(cat "$d/idVendor" 2>/dev/null)" = 0403 ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = 6010 ] &&
    [ "$(cat "$d/product" 2>/dev/null)" = "Digilent USB Device" ] && BUSDEV="$(cat "$d/busnum"):$(cat "$d/devnum")"
done
[ -n "$BUSDEV" ] || { echo "J12 (Digilent USB Device, 0403:6010) is not connected to this VM (Parallels: Devices > USB)"; exit 1; }
openFPGALoader -b nexysVideo --busdev-num "$BUSDEV" "$BIT"
