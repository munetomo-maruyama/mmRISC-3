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
#---------------------------------------------------------------------------
import os, runpy, sys

if os.environ.get("SD_CARD_RESET") != "1":
    import litesdcard.phy as phy
    _init = phy.SDPHYInit.__init__
    def _init_no_reset(self, sdpads_layout, with_reset=False):
        _init(self, sdpads_layout, with_reset=False)
    phy.SDPHYInit.__init__ = _init_no_reset
    print("nexys_video_target.py: the SD card PHY without the card reset (rst held low)")

import litex_boards.targets.digilent_nexys_video as target
sys.argv[0] = target.__file__
runpy.run_path(target.__file__, run_name="__main__")
