# LitexSystem

The LiteX SoC on the Digilent Nexys Video (XC7A200T), phase 2 of `Doc/STRATEGY.md` (`Doc/BOARD.md` for the board).
Japanese: `README_J.md`.

| Path | What |
|---|---|
| `scripts/build_stock.sh` | Step 2.0: LiteX's own Nexys Video target as it is (Rocket, 100 MHz, DDR3-800, SD card, Ethernet), generated here; Vivado on the Windows VM |
| `scripts/nexys_video_target.py` | The target as `build_stock.sh` runs it: LiteX's own, but the SD card PHY without LiteSDCard's card reset (`docs/BRINGUP.md` 10: the BIOS's `sdcard_init` hangs otherwise); `SD_CARD_RESET=1` keeps it |
| `scripts/build_nexys_video.bat` | The Windows side's run, copied next to the tcl |
| `CPU=vexriscv_smp scripts/build_stock.sh` | The same with VexRiscv-SMP (RV32, 100 MHz) into `build_stock_vexriscv_smp/`: Rocket does not close 100 MHz on this part (`docs/BRINGUP.md` 2) |
| `scripts/program_nexys_video.bat` / `.tcl` | The bitstream into the FPGA over J12 (Vivado's hardware manager), copied next to the tcl |
| `scripts/program_nexys_video.sh` | The same from this Linux VM with openFPGALoader (J12 connected to the VM) |
| `scripts/build_demo.sh` | LiteX's bare-metal demo for a build, with `boot.json` (SD card) and `vex.json` (TFTP) in `<build>/demo/` |
| `scripts/build_linux_vexriscv.sh` | Linux for the VexRiscv-SMP SoC: linux-on-litex-vexriscv's pre-built images (downloaded once) with the SoC's own DTB, as a TFTP folder (`vexlinux/`) and an SD card's files (`docs/BRINGUP.md` 12) |
| `scripts/build_soc.sh` | Steps 2.1 and 2.2: the SoC around mmRISC-2 (`cpu/mmrisc/`, its RTL from mmRISC-2's repository) on LiteX's Nexys Video target, LiteX at 100 MHz and the CPU at 50 MHz through crossings (`SYS_CLK` / `CPU_CLK`; both 50e6 is step 2.1's), into `build/`; Vivado on the Windows VM (`docs/BRINGUP.md` 13, 15) |
| `cpu/mmrisc/` | mmRISC-2's LiteX wrapper (from mmRISC-2 Rev.02): the RTL read from `MMRISC2_HOME` (default `../mmRISC-2`), the debug port off until step 2.4 |
| `build_stock/` | The output (not in git): `gateware/` (Verilog, XDC, tcl, the bitstream), `software/bios/`, `csr.csv`, `csr.json` |
| `docs/BRINGUP.md` | The bring-up record (step 2.5's), section by step |

The LiteX workspace and its Python environment are mmRISC-2's (`../mmRISC-2/LitexRocket`, the versions pinned by its
`LitexSystem/scripts/setup_litex.sh`); `LITEX_HOME` points elsewhere.

```bash
./LitexSystem/scripts/build_stock.sh
```

Then, on the Windows VM, in `LitexSystem\build_stock\gateware`: `build_nexys_video.bat`.
