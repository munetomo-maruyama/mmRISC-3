#---------------------------------------------------------------------------
# nexys_video_target.py : LiteX's digilent_nexys_video target, run as it is
#                         but for the SD card PHY's card reset (build_stock.sh)
#
#   python3 nexys_video_target.py <the target's arguments>
#
# LiteSDCard (b0d2771, 2026-06-19) power-cycles the card through the board's
# rst pad (V20 on the Nexys Video) whenever the BIOS writes phy_init_initialize:
# 4096 SD clocks, about 10 ms at the 400 kHz of initialisation, with CMD held
# high. The BIOS's sdcard_init() sends CMD0 / CMD8 1 ms after that write, into
# the reset, so CMD8 times out (1 s) on every one of its 1000 tries, each try
# starting a new reset: sdcard_init() looks hung for some 17 minutes, and so
# does sdcardboot (LitexSystem/docs/BRINGUP.md 10). Here the PHY is built
# without that reset, as before b0d2771: the rst pad held low, the card powered
# from the configuration on. SD_CARD_RESET=1 keeps the stock PHY.
#
# --eth-dhcp (step 2.3): the target has --eth-dynamic-ip but no --eth-dhcp,
# and passes its eth_ip (default 192.168.1.50) with either, which LiteX
# refuses (Doc/BOARD.md 2). With --eth-dhcp, taken off the command line here,
# add_ethernet gets with_dhcp=True and no local IP, as the Arty's target
# does: the BIOS asks for its address by DHCP before netboot.
#
# Step 2.4 (Doc/BOARD.md 2, 8):
# - The switches and buttons are LVCMOS12 (Digilent's XDC): they sit at VADJ,
#   1.2 V by the board's resistors as long as SET_VADJ is left alone; the
#   platform's LVCMOS25 would read a 1.2 V high as low.
# - The LED chaser takes the LEDs left: the CPU's debug port (core.py,
#   add_jtag) uses LD0-LD3 for its status, and request_all("user_led") asks
#   by index from 0, so it would find none; request_remaining gives LD4-LD7.
#---------------------------------------------------------------------------
import os, runpy, sys

if os.environ.get("SD_CARD_RESET") != "1":
    import litesdcard.phy as phy
    _init = phy.SDPHYInit.__init__
    def _init_no_reset(self, sdpads_layout, with_reset=False):
        _init(self, sdpads_layout, with_reset=False)
    phy.SDPHYInit.__init__ = _init_no_reset
    print("nexys_video_target.py: the SD card PHY without the card reset (rst held low)")

if "--eth-dhcp" in sys.argv:
    sys.argv.remove("--eth-dhcp")
    from litex.soc.integration.soc import LiteXSoC
    _add_ethernet = LiteXSoC.add_ethernet
    def _add_ethernet_dhcp(self, *args, **kwargs):
        kwargs.update(with_dhcp=True, dynamic_ip=True, local_ip=None)
        return _add_ethernet(self, *args, **kwargs)
    LiteXSoC.add_ethernet = _add_ethernet_dhcp
    print("nexys_video_target.py: Ethernet with DHCP (no fixed local IP)")

import litex_boards.platforms.digilent_nexys_video as platform_mod
from litex.build.generic_platform import IOStandard
# (user_btn 5 is G4, CPU RESET's pin in the DDR3's 1.5 V bank: left alone)
platform_mod._io[:] = [
    (r[:-1] + (IOStandard("LVCMOS12"),))
    if r[0] in ("user_sw", "user_btn") and (r[0], r[1]) != ("user_btn", 5) and isinstance(r[-1], IOStandard)
    else r for r in platform_mod._io]
_request_all = platform_mod.Platform.request_all
def _request_all_leds(self, name, *args, **kwargs):
    if name == "user_led":
        return self.request_remaining(name)
    return _request_all(self, name, *args, **kwargs)
platform_mod.Platform.request_all = _request_all_leds

import litex_boards.targets.digilent_nexys_video as target
sys.argv[0] = target.__file__
runpy.run_path(target.__file__, run_name="__main__")
