# Bring-up of the Nexys Video

The record of phase 2 (`Doc/STRATEGY.md` 2.0 to 2.6), one section per step, newest at the end. Japanese:
`BRINGUP_J.md`. The board's facts and the plan for each part are in `Doc/BOARD.md`.

## 1. Step 2.0: LiteX's own target as it is (2026-11-24)

**What**: the most proven CPU first, before mmRISC-2 and mmRISC-3: litex-boards' `digilent_nexys_video.py` with
Rocket (variant `linux`, one core: `LitexConfig_linux_1_1`, RV64IMAFDC, Sv39, 16 KiB L1 caches), 100 MHz,
`A7DDRPHY` with the MT41K256M16 at DDR3-800, LiteSDCard on J3, LiteEth over RGMII. It checks the board, its DDR3 at
100 MHz, the SD slot and the gigabit port with nothing of ours in the way, and gives a Linux to compare with.

**Generated** (`scripts/build_stock.sh`, in the VM): the SoC's Verilog, XDC and Vivado tcl, the BIOS (43.6 KiB of the
128 KiB ROM). Map (as mmRISC-2's): ROM 0x1000_0000, SRAM 0x1100_0000 (8 KiB), CSRs 0x1200_0000, Ethernet buffers
0x3000_0000, CLINT 0x0200_0000, PLIC 0x0C00_0000, **main RAM 0x8000_0000, 512 MiB**; the clock 100 MHz.

**Taken from mmRISC-2's bring-up, not from the stock target**: the SD card's output registers in the I/O blocks
(mmRISC-2's BRINGUP 13: without it a build read the card in the BIOS but got CRC errors in Linux); physical
optimisation after placement and after routing (AggressiveExplore), as mmRISC-2's builds. **Left as they are for
this step** (`Doc/BOARD.md` 2, taken up at 2.1): the switches' `LVCMOS25` (not used by the stock SoC), the LED
chaser on all 8 LEDs, the static addresses (the target has no DHCP: the board 192.168.1.50, the TFTP server
192.168.1.100, both changeable at the `litex>` prompt with `eth_local_ip` / `eth_remote_ip`, or by `ETH_IP` /
`REMOTE_IP` when generating).

**Found**: mmRISC-2's venv lacks `pythondata-cpu-rocket` (the repository is in its workspace, not installed);
`build_stock.sh` finds it through `PYTHONPATH` and leaves the venv as it is.

**Next**: the Vivado run (the author's, `build_nexys_video.bat`): timing at 100 MHz (Rocket at 50 MHz on the Arty
had +0.409 ns; at 100 MHz on the -1 part it may not close: then Rocket at a lower clock is no use for DDR3-800, and
the fall-back for this step is VexRiscv at 100 MHz for the board's checks, with Linux on Rocket left to the CPU's
own crossing at 2.2), the LUTs, `report_power` (`Doc/BOARD.md` 10, 13). On the board: the BIOS prompt, LiteDRAM's
memory test, `sdcardboot` / reading the card, TFTP; then Linux on Rocket (linux-on-litex-rocket supports this board).
