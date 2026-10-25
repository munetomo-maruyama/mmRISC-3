# RTL/CPU/OOO

[日本語](README_J.md)

The first blocks of mmRISC-3's out-of-order core in the **fusion configuration** (`Doc/STRATEGY.md` section 4): the
loops that have to close in one cycle at 50 MHz and the parts whose cost decides the configuration. They are written
to be used as they are in Phase 1, and are measured alone first (Phase 0, step 3 of `Plan/ISSUES.md`; results in
`Plan/OOC.md`).

| Block | What it is | Test (`SIM/OOO_UNIT`) |
|---|---|---|
| `OOO_ALU` | One integer ALU: RV64I + Zba / Zbb / Zbs / Zicond, the operation set and encoding of mmRISC-2's CORE_EXU; the adder and the shifter are shared between operations; `FULL = 0` is the narrowed one for the second stage of fusion | through OOO_ALU2 |
| `OOO_ALU2` | The ALU of one issue port: a full `OOO_ALU` and a narrowed one in series, so that a fused ALU + ALU pair finishes in one cycle, and the branch comparison (alone, or on the first result for a fused ALU + branch) | `tb_alu2`: 2,000,000 random vectors against the specification |
| `OOO_FUSE` | Fusion: 4 decoded instructions → the next 2 µops (lui + addi, auipc + x, slli + srli, ALU + load, load / store pairs, ALU + branch, ALU + ALU); a pair reads at most 2 sources and writes at most 1 register, and the second half of ALU + ALU is an operation of the second stage | `tb_fuse`: random against the rules; the CoreMark stream gives at least 99.99 % of the model's pairs |
| `OOO_IQ` | Issue queue: 16 entries, 2 sources and 1 destination per µop, 6 wakeup buses, 2 in / 3 out per cycle (ALU0 + MUL/DIV, ALU1, LSU), 1-cycle wakeup-select, oldest first by an age matrix, latency-2 and external wakeups | `tb_iq`: every issue against an independent account of when values are usable |
| `OOO_RENAME` | Renaming: 2 µops per cycle with 2 sources and 1 destination, 64 physical registers, RAT, free list, busy bits, in-group dependences, 8 checkpoints copied a cycle late | `tb_rename`: against a reference with commits, write-backs and restores |
| `OOO_PRF` | Physical registers: NREG × 64 (64 in the fusion configuration), NW writes / NR reads (3 / 6), LUTRAM banks + live value table | `tb_prf`: random reads and writes against an array |
| `OOO_LSU` | Load / store unit: LQ 12, SQ 12, forwarding from the youngest older store, conservative ordering (`lsu_st_known`), `ld_cancel` and late results for misses, recovery to a checkpoint or the committed state | `tb_lsu`: the rest of the core modelled, every load value against program order, 7 seeds |
| `OOO_UBTB` | Next-line predictor: 16 entries, 12-bit partial tags, next fetch address in one cycle with a parallel choice | `tb_ubtb`: against a reference table |

- Coding follows mmRISC-2 (`logic`, `always_ff` with active-low asynchronous reset, comments on what and why).
- Every block is linted by Verilator (`-Wall`); the unit tests start everything that has no reset at random values.
- `SIM/OOO_UNIT/mutate.py` breaks the RTL on purpose (50 mutations); all are detected.
- Out-of-context synthesis in Vivado: `FPGA/OOO_OOC` (`synth_ooo.bat`), run by the author.
