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

## 3. Step 2.0: VexRiscv-SMP at 100 MHz: met (2026-11-24)

**The run** (by the author, `build_nexys_video.bat` in `build_stock_vexriscv_smp/gateware`, 8 minutes): **all
constraints met: WNS +0.631 ns, TNS 0, hold +0.026 ns**; the 100 MHz input +7.914 ns, the DDR3's `clkout3` +1.215
ns, Ethernet's RX +1.272 ns. **9,262 LUTs (6.9 %)**, 8,433 FF, 27.5 BRAM tiles, 4 DSP; `report_power` **0.76 W**
(0.60 W dynamic), junction 27.5 °C. The only critical warnings are the stock ones (`create_clock` on the renamed
`eth_rx_clk` / `eth_tx_clk` nets); section 2's dropped `set_clock_groups` is now read (the newline fix works).

**The worst path is LiteDRAM's, not the CPU's**: a bank machine's command address → its tRAS counter's reset
(`bankmachine7 ... trascon_count`), 10 levels, +0.631 ns. LiteX's own logic at 100 MHz has about 0.6 ns to spare;
worth remembering at 2.2 and 2.6, where LiteX stays at 100 MHz around a CPU at 50 MHz.

Also seen: the author's second run of section 1's Rocket build (in `build_stock/`, by mistake for this one) gave the
same result to the digit (WNS −5.208 ns, 14,607 endpoints, 37,563 LUTs, 1.04 W): the flow is reproducible.

**Step 2.0's Vivado part is done**: a bitstream of LiteX's own SoC on this part at 100 MHz with DDR3-800, the SD
card and Ethernet (`build_stock_vexriscv_smp/gateware/digilent_nexys_video.bit`). **Next, on the board** (when it is
there): the BIOS prompt on the UART (115,200 baud), LiteDRAM's calibration and memory test of 512 MiB, the SD card
(`sdcardboot`, reading a block), TFTP from 192.168.1.100 over the gigabit port; then Linux (linux-on-litex-vexriscv's
images for this board) as the reference.

## 4. Step 2.0 on the board: the procedure (2026-11-24)

The board is here. **Found before starting**: the LAN is 192.168.0.0/24 (the TFTP server, this Ubuntu VM bridged,
is 192.168.0.42), not 192.168.1.x; and the BIOS's `eth_local_ip` / `eth_remote_ip` commands exist only with a dynamic
IP, which this target cannot give (`Doc/BOARD.md` 2), so section 1 was wrong to call them changeable at the prompt.
`build_stock_vexriscv_smp` is generated again with **the board at 192.168.0.50** (no answer to ARP there before) and
**the server at 192.168.0.42** (`CPU=vexriscv_smp ETH_IP=192.168.0.50 REMOTE_IP=192.168.0.42`); only the BIOS's
constants change, so section 3's timing holds, but the bitstream needs Vivado again for TFTP. Section 3's bitstream
(192.168.1.x) serves for everything but TFTP.

**New here**: `scripts/program_nexys_video.bat` / `.tcl` (the bitstream into the FPGA over J12 from Vivado's hardware
manager, volatile), `scripts/build_demo.sh` (LiteX's bare-metal demo linked at main RAM, with `boot.json` for the SD
card and `vex.json` for TFTP: the server's `boot.json` is mmRISC-2's Linux, at addresses that on this SoC are not
RAM, so it must not be taken).

**The checks, in order** (J12 to the Windows VM for programming, J13 to a terminal at 115,200 8N1, no flow control;
JP4 on JTAG; no SD card at first):
1. **Program**: `program_nexys_video.bat` in `build_stock_vexriscv_smp\gateware`. Expected: the LiteX banner, `CPU: VexRiscv SMP-LINUX @ 100MHz`, the
   identifier `LiteX SoC on Nexys Video` with its build date.
2. **DDR3**: the BIOS calibrates at boot (`Initializing SDRAM @0x40000000...`, write leveling, read leveling per
   module, `Memtest OK`, the speeds). Then at `litex>`: `mem_test 0x40000000 0x20000000` (all 512 MiB, a few
   minutes) and `mem_speed 0x40000000 0x1000000`. Press Q or ESC at the boot to stop the automatic boot.
3. **UART load** (needs no card or network): `litex_term --kernel demo.bin --kernel-adr 0x40000000 /dev/ttyUSB0`
   from the demo folder, then `reboot`: the demo's prompt (`help`, `led`, `donut`).
4. **SD card**: a spare FAT card (not mmRISC-2's `LITEXBOOT`) with `demo.bin` and `boot.json` in its root, written
   from the Mac (the stale-mount problem of mmRISC-2), in J3 under the board; `sdcard_init`, `sdcardboot`: the demo.
5. **TFTP** (after the Vivado run of the regenerated SoC): `sudo cp demo.bin vex.json /srv/tftp/` on this VM,
   the RJ-45 on the gigabit switch; `netboot vex.json`: the demo.

Then Linux as the reference (linux-on-litex-vexriscv's images for this board, to be fetched).

## 5. Step 2.0 on the board: the BIOS and the DDR3 (2026-11-25)

**Programming**: `program_nexys_video.bat` failed at `open_hw_target` ("There is no current hw_target"): the
hw_server it had just launched did not list the cable yet. Programmed from the Vivado GUI instead. The tcl now looks
for the targets again for up to 20 s (`refresh_hw_server`) and opens the first.

**The BIOS** (section 3's bitstream, the BIOS of 2026-11-24 17:02, local IP 192.168.1.50): the banner, `CPU: VexRiscv
SMP-LINUX @ 100MHz`, `SDRAM: 512.0MiB 16-bit @ 800MT/s (CL-6 CWL-5)`, **the board, the 100 MHz clock, the UART on
J13 and the BIOS work**.

**The DDR3**: read leveling found its window in bitslip 2 for both byte lanes (m0, m1: delays 9 ± 7 taps, 15 good of
32), with a second window in bitslip 3 (from tap 19 to the end); `Memtest OK` on the BIOS's 2 MiB; **156.6 MiB/s
write, 77.8 MiB/s read** (sequential, the CPU's 32-bit Wishbone; not the DDR3's limit). **DDR3-800 calibrates on
this board's part** (`Doc/BOARD.md` 4, concern 4).

**Where it stopped**: after the serial boot's timeout (the `sL5DdSMmkekro` is its request to `litex_term`, normal
in another terminal), `Booting from SDCard in SD-Mode...`, `Booting from boot.json...`, then nothing. A card was in
J3 and the BIOS read its FAT partition and its `boot.json` (so the SD slot, the card's initialisation and LiteSDCard's
reads work); if the card was mmRISC-2's `LITEXBOOT`, its `boot.json` loads `Image` (15 MB) to 0x8020_0000 and
`fw_jump.bin` to 0x8000_0000, which on this SoC are not RAM (the Ethernet buffers at 0x8000_0000, nothing above
0x8000_2000): the load goes to no memory, and the BIOS does not come back. Section 4 asked for no card at first;
the card's own `boot.json` must be the demo's (`build_demo.sh`).

**Next**: without the card (or Q / ESC at "Press Q or ESC"), `mem_test 0x40000000 0x20000000`; then the UART load,
the demo's card, TFTP, as section 4.

## 6. Programming from the Linux VM (2026-11-25)

Section 5's retry did not help: the batch Vivado's hw_server listed no cable for 20 s (`ERROR: no JTAG cable
found`), while the GUI programs the board. Not pursued further on the Windows side (the GUI stays the fall-back).

**From this VM instead**: `scripts/program_nexys_video.sh` runs `openFPGALoader -b nexysVideo <bit>` (installed in
`/usr/local/bin`, its board list has `nexysVideo` on the `digilent_b` cable; the Digilent udev rules are there). J12's
FT2232H (0403:6010) has to be connected to this VM in Parallels; J13's FT232R (0403:6001) already is
(`/dev/ttyUSB0`, the author's minicom). With both here, programming and the console are on one side.
