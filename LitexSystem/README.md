# LitexSystem

The LiteX SoC on the Digilent Nexys Video (XC7A200T), phase 2 of `Doc/STRATEGY.md` (`Doc/BOARD.md` for the board).
Japanese: `README_J.md`.

| Path | What |
|---|---|
| `scripts/build_stock.sh` | Step 2.0: LiteX's own Nexys Video target as it is (Rocket, 100 MHz, DDR3-800, SD card, Ethernet), generated here; Vivado on the Windows VM |
| `scripts/build_nexys_video.bat` | The Windows side's run, copied next to the tcl |
| `CPU=vexriscv_smp scripts/build_stock.sh` | The same with VexRiscv-SMP (RV32, 100 MHz) into `build_stock_vexriscv_smp/`: Rocket does not close 100 MHz on this part (`docs/BRINGUP.md` 2) |
| `build_stock/` | The output (not in git): `gateware/` (Verilog, XDC, tcl, the bitstream), `software/bios/`, `csr.csv`, `csr.json` |
| `docs/BRINGUP.md` | The bring-up record (step 2.5's), section by step |

The LiteX workspace and its Python environment are mmRISC-2's (`../mmRISC-2/LitexRocket`, the versions pinned by its
`LitexSystem/scripts/setup_litex.sh`); `LITEX_HOME` points elsewhere.

```bash
./LitexSystem/scripts/build_stock.sh
```

Then, on the Windows VM, in `LitexSystem\build_stock\gateware`: `build_nexys_video.bat`.
