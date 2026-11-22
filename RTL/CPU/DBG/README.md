# RTL/CPU/DBG

[日本語](README_J.md)

mmRISC-3's debug logic (step 1.8 J1, `Plan/OOC.md` 29.101 / 29.102; RISC-V Debug Specification 1.0): mmRISC-2 Rev.02's
JTAG / cJTAG front end, DTM, CDC and Debug Module **unchanged** (its `RTL/CPU/CPU_DBG`, specified in its
`CPU_DBG_SPEC.md`), with a wrapper of mmRISC-3's for `OOO_CPU`. Each file taken has a line added to its header to say
where it comes from; the rest is mmRISC-2's text.

```
DBG_TOP
├─ DBG_CJTAG   cJTAG (IEEE 1149.7 OScan1) or JTAG: the TAP's pins
├─ DBG_DTM     the TAP: IDCODE, dtmcs, dmi, BYPASS [TCK]
├─ DBG_CDC     TCK to the system clock (DBG_SYNC, DBG_RST_SYNC; a 4-phase handshake)
└─ DBG_DM      the Debug Module's registers, abstract commands (Access Register, Access Memory), SBA,
               authentication, haltsum0, resethaltreq, hartreset, ndmreset [clk]
               -> the hart: OOO_CPU's hart_*, reg_* (OOO_TRAP, OOO_DBG), bm_* (OOO_DMISS2)
```

| Block | What it is | Change from mmRISC-2 |
|---|---|---|
| `DBG_CJTAG` | cJTAG's OScan1 receiver; JTAG passes through (`cjtag_en` 0) | None |
| `DBG_DTM` | The JTAG TAP and the DTM's registers; a DMI access to the CDC | None |
| `DBG_CDC` | The synchronizers, the reset synchronizers, the DMI's handshake between TCK and the system clock | None |
| `DBG_DM` | The Debug Module: 1 hart, datacount 4, **progbufsize 0** (no program buffer), abstractauto, Access Register (to the hart's `reg_*`), Access Memory and SBA (sbasize 40, 8 to 64 bits; to `bm_*`), authentication, the reset-halt hold over the L2's clearing | None |
| `DBG_TOP` | **mmRISC-3's wrapper**: the four above as mmRISC-2's `CPU_DBG` wired them (resets: `rst_dbg_n` the debug logic's power-on reset, `jtag_trst_n` the TAP's, `rst_n` the system's, with ndmreset and hartreset making `rst_bus_n`, OOO_CPU's reset), the hart's and the bus master's ports out for `OOO_CPU`. Not taken from `CPU_DBG`: its bus master `DBG_BUSMST`, its D$ port `DBG_CACHE` and its stand-in hart (OOO_CPU takes the DM's bus master interface itself: the D$ is coherent with it). IDCODE 0x36d6d001 (mmRISC-2's 0x26d6d001 with version 3) | New |

The hart's side is in the core: halt, resume, step, EBREAK and the triggers at the ROB head (`OOO_TRAP`), register
accesses through short sequences the core runs in debug mode (`OOO_DBG`), memory through the D$'s miss handler
(`OOO_DMISS2`): `RTL/CPU/OOO/README.md`.

- **A reset empties the write-back caches** (the D$, the L2): what they hold and memory does not is lost with a
  system reset, ndmreset or hartreset. Load a program after `reset halt`, not before (mmRISC-2's test of memory kept
  over ndmreset does not apply).
- Tests: `SIM/OCD` (OpenOCD by remote_bitbang on `OOO_CPU` with `DBG_TOP`); the hart's side also in `SIM/CORE`
  (`tb_core -dbg`, in lock-step). mmRISC-2's `SIM_DBG` (the DTM and the DM with a stand-in hart, cJTAG among them)
  verified the four files taken; it is not repeated here.
