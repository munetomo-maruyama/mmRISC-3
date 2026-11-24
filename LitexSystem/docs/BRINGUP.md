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

## 2. Step 2.0: Rocket at 100 MHz does not close; VexRiscv-SMP generated (2026-11-24)

**The run** (by the author, `build_nexys_video.bat` on section 1's output, Vivado 2025.1, 33 minutes): bitstream
written, but **WNS −5.208 ns, TNS −31,934 ns, 14,607 endpoints failing** (of 59,393 in the 100 MHz domain); hold
+0.034 ns. Every other clock met: the 100 MHz input +7.755 ns, the DDR3's `clkout3` +1.246 ns, Ethernet's RX +1.272
ns. **37,563 LUTs (28.1 %)**, 19,417 FF, 40.5 BRAM tiles, 15 DSP; `report_power` **1.04 W** on chip (0.87 W
dynamic), junction 28.4 °C at 25 °C ambient: no cooling question at this size (`Doc/BOARD.md` 10, 13).

**The path**: all inside Rocket: the I$'s output (`frontend/icache/s2_dout`) → the decode → the enables of EX's
operand registers (`core/ex_reg_rs_msb`), 14.66 ns, 15 levels, 84 % route. Rocket's pipeline needs about 15 ns
on the -1 part (about 65 MHz), as its 50 MHz on the Arty (+0.409 ns) suggested. A lower system clock is no way
out: the DDR3 runs from it (1:4), and below 75 MHz it is under DDR3's lowest data rate with the DLL on (DDR3-600,
`Doc/BOARD.md` 4); Rocket at its own clock behind a crossing is step 2.2's work, not LiteX's target as it is.

**Found in `build_stock.sh`**: LiteX's XDC ends without a newline, and the appended comment ran onto its last line,
so Vivado dropped `set_clock_groups ... sys_clk ... main_crg_clkin_signal -asynchronous` (CRITICAL WARNING 17-170).
No effect on this result (the one path between the two met by +2.717 ns, the failures are inside the 100 MHz
domain); fixed (a newline first). Stock warnings left as they are: `create_clock` on `eth_rx_clk` / `eth_tx_clk`
nets that synthesis renamed.

**So, as section 1 planned**: the board's checks with **VexRiscv-SMP at 100 MHz** (`CPU=vexriscv_smp
./LitexSystem/scripts/build_stock.sh`, into `build_stock_vexriscv_smp/`): RV32IMA with Sv32, one core, 4 KiB L1
caches, on LiteDRAM's 128-bit port directly, coherent DMA (the SD card's), what linux-on-litex-vexriscv runs on
this board at 100 MHz; its netlist pre-generated (`..._Ldw128_Cdma_Ood`, with `--hardware-breakpoints 0`: with the
default 1 LiteX would run SpinalHDL through sbt, which downloads). Its map is VexRiscv's: ROM 0x0000_0000, SRAM
0x1000_0000, main RAM **0x4000_0000, 512 MiB**, CSRs 0xF000_0000, Ethernet 0x8000_0000. The rest as section 1
(DDR3-800, SD, Ethernet at 192.168.1.50 / .100, the SD registers in the I/O blocks). Linux on Rocket, the
64-bit reference, waits for 2.2's crossing (Rocket at 50 MHz, LiteX at 100 MHz) or is dropped for mmRISC-2's own.

**Next**: the Vivado run of `build_stock_vexriscv_smp` (the author's, `build_nexys_video.bat` there).
