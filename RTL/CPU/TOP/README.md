# RTL/CPU/TOP

[日本語](README_J.md)

mmRISC-3 as one block for a SoC (step 2.6, `Doc/STRATEGY.md`; the LiteX wrapper `LitexSystem/cpu/mmrisc3`).

```
CPU_TOP
├─ DBG_TOP     the debug logic (RTL/CPU/DBG): JTAG / cJTAG, the DTM, the DM
├─ OOO_CPU     the core with its I$, D$, L2, CLINT and PLIC (RTL/CPU/OOO)
├─ the start   OOO_CPU's boot at RESET_VECTOR a few cycles after its reset
└─ the DMA port and the arbiter: the SoC's DMA (AXI4-Lite slave) and the DM's Access Memory /
               SBA on OOO_CPU's bus master port (bm_*: OOO_DMISS2's debugger port)
```

| Port | What |
|---|---|
| `clk`, `rst_dbg_n`, `rst_n` | The CPU's clock; the debug logic's power-on reset; the system reset (the CPU's alone; with the DM's ndmreset and hartreset it makes `OOO_CPU`'s reset, `DBG_TOP`'s `rst_bus_n`) |
| `irq_src[31:1]` | The PLIC's sources 1 to 31 |
| `jtag_*`, `cjtag_*`, `dbg_auth_*` | The debug port's pins, the cJTAG switch, the authentication switch and key |
| `dbg_halted`, `dbg_running`, `dbg_dmactive` | The status (the board's LEDs) |
| `m_axi4_*` | `OOO_CPU`'s memory bus (the L2's AXI4): the D$'s lines in `[CBASE, CTOP)` and **every fetch** (`OOO_ICACHE` caches what it fetches): the SoC routes a boot ROM's lines from it |
| `m_axil_*` | `OOO_CPU`'s peripheral bus (AXI4-Lite): the D$'s accesses outside `[CBASE, CTOP)` but the CLINT and the PLIC, which `CPU_MMIO` answers inside |
| `s_dma_*` | **The DMA port** (AXI4-Lite slave, 64 bits): memory as the core sees it, through the D$ |

**The DMA port.** One access at a time through `OOO_CPU`'s bus master port, which goes to `OOO_DMISS2`'s debugger port:
inside `[CBASE, CTOP)` through the D$ (a line it does not hold is filled first; a write makes it dirty), coherent
with the core's caches whether the hart runs or not, as mmRISC-2's `DMA_CACHE` was; outside it, one beat on the
peripheral bus. A read is one 8-byte access at the address's 8-byte word. A write is cut by its strobes into aligned
pieces, the lowest first: 8 bytes when all 8 strobes are set, else the largest of 4, 2, 1 at each lowest strobe left
(0x3c: 2 + 2 bytes; 0x81: 1 + 1); no strobe: answered, nothing written. An error answer (a device's) is SLVERR. The
DM's requests (a pulse each) are kept until served and go first. An access begins only with `OOO_CPU` out of reset;
one in flight when it is reset ends there. A DMA write, like the DM's, makes `OOO_DBG` run its fence.i sequence at the
next resume from debug mode (harmless).

**Tests**: `SIM/TOP/run_top.sh` (the DMA port against the D$: a word dirty in the D$ read, writes in pieces seen by
the core, a device, SLVERR), `SIM/OCD/run_ocd.sh top` (OpenOCD's 50 checks through `CPU_TOP`, with and without
authentication), `LitexSystem/sim/run_sim.sh` (LiteX's BIOS in simulation).
