# SIM/OCD: OpenOCD with OOO_CPU (step 1.8 J1)

[日本語](README_J.md)

OpenOCD (riscv-openocd) debugs `OOO_CPU` through its debug logic (`RTL/CPU/DBG`'s `DBG_TOP`), both in RTL under
Verilator, as mmRISC-2's `SIM/SIM_OCD` did its core (`Plan/OOC.md` 29.102).

```
OpenOCD --remote_bitbang (TCP)-- jtag_rbb.cpp (DPI-C) -- tb_OCD.sv:
    DBG_TOP (JTAG, the DTM, the DM) -- OOO_CPU's hart_*, reg_*, bm_*
    OOO_CPU's memory bus  -> AXI4_RAM at 0x8000_0000 (512 KB)
    OOO_CPU's peripheral bus (beyond CPU_MMIO's CLINT and PLIC) -> AXIL_RAM at 0x1200_0000 (4 KB)
```

Each remote_bitbang command is applied every 7 ns while the 50 MHz system clock runs on its own (`--timing`), so
the DTM's clock crossing meets a real debugger. After a reset (power-on, OpenOCD's SRST, ndmreset, hartreset) the
hart is started at 0x8000_0000 (`OOO_CPU` boot), and until then the DM shows it unavailable.

```bash
./run_ocd.sh
```

builds `tb_OCD` (`obj/`), runs it with OpenOCD and `test_ocd.tcl`, then again with authentication on (the key
0xbeefcafe, `riscv authdata_write`); PASS when both are. `test_ocd.tcl` is mmRISC-2's (50 checks): halt, GPRs, FPRs
and CSRs (misa, mhartid, dpc, dcsr), memory by every size on both buses, a block of 256 words, `load_image` /
`verify_image`, steps, a software breakpoint (the EBREAK written through the D$, fetched after the resume's
`fence.i`), a hardware breakpoint (an execute trigger, dcsr.cause 2), watchpoints on a store and a load (the
access not done when the hart halts; the store's line read while it is dirty in the D$), a free run and a halt, and
`reset halt` (before the first instruction).

Changed from mmRISC-2's: misa (0x800000000014112f), IDCODE (0x36d6d001), an FPR read back, and the reset: the
write-back caches lose what memory does not have yet (`RTL/CPU/DBG/README.md`), so memory is written and read after
`reset halt` instead of kept over it. The `Unable to insert program into progbuf` lines are OpenOCD probing CSRs
the core does not have (vlenb, mtopi) with a program buffer it does not have either: harmless, as in mmRISC-2.

Files: `tb_OCD.sv`, `openocd_sim.cfg`, `test_ocd.tcl`, `run_ocd.sh`; `jtag_rbb.cpp`, `AXI4_RAM.sv` and `AXIL_RAM.sv`
are mmRISC-2's, unchanged (a line in each header says so).
