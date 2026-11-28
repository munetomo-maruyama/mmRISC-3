# SIM/TOP: CPU_TOP's DMA port (step 2.6)

[日本語](README_J.md)

`tb_CPU_TOP.sv` tests `RTL/CPU/TOP`'s `CPU_TOP` on its DMA port (AXI4-Lite slave), Verilator only (`--timing`):
the memory bus to `SIM/OCD`'s `AXI4_RAM` at 0x8000_0000 (`dma_prog.S` in it), the peripheral bus to its `AXIL_RAM`
at 0x1200_0000. The core runs `dma_prog.S`: a word written to 0x8000_1000 (dirty in the D$, memory still 0), then a
wait for the DMA's word at 0x8000_2000 in its D$ line, then a copy of 0x8000_2008 to 0x8000_3000. The bench, on the
DMA port:

1. reads 0x8000_1000: the core's word, from the D$ (coherent);
2. writes 0x8000_2008 in pieces (strobes 0x3c: 2 + 2 bytes; 0x81: 1 + 1);
3. writes with no strobe (answered, nothing written);
4. writes 0x8000_2000, the word the core waits for;
5. reads 0x8000_3000: the core's copy of the pieces (it saw both writes);
6. writes and reads a device word (0x1200_0010, the peripheral bus), reads 0x0 (no device: SLVERR).

```bash
./run_top.sh
```

builds (`obj/`, from scratch) and runs; **PASS** (2026-11-28, 13 checks). Files: `tb_CPU_TOP.sv`, `dma_prog.S`,
`run_top.sh`.
