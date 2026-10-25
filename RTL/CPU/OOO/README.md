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
| `OOO_BTB` | Branch target buffer for indirect jumps only: 256 rows in block RAM read with the fetch address, one jump per line | `tb_btb`: against a reference table |
| `OOO_FBUF` | Fetch buffer: a queue of 4 whole 16-byte blocks (start / end parcel, taken, FTQ index), a window of 8 parcels over the head block and the next, up to 4 instructions a cycle (RVC or 32-bit, also across blocks) | `tb_fbuf`: an execution model with random taken transfers, flushes and partial takes; the exact count given, 9 seeds |
| `OOO_FTQ` | Fetch target queue: 8 entries (fetch address, next address, taken parcel, predictor state) in LUTRAM, 2 reads for decode and 1 for resolution, pop / restore / flush_all | `tb_ftq`: against a reference queue, 4 seeds |
| `OOO_FETCH` | The front end F0–F2 around `OOO_UBTB`, `OOO_PREDEC`, `OOO_TAGE`, `OOO_BTB` and `OOO_RAS`: I$ requests and answers, the first transfer predicted taken ends the block, F2 overrides the uBTB (2 cycles) and trains it, recovery from the back end, credit from the fetch buffer and the FTQ | `tb_fetch`: a random program through an I$ with misses, a back end on the true path; every fetch address and every block against mirrors of the predictors, 11 programs |
| `OOO_FUSE` | Fusion: 4 decoded instructions → the next 2 µops (lui + addi, auipc + x, slli + srli, ALU + load, load / store pairs, ALU + branch, ALU + ALU); a pair reads at most 2 sources and writes at most 1 register, and the second half of ALU + ALU is an operation of the second stage | `tb_fuse`: random against the rules; the CoreMark stream gives at least 99.99 % of the model's pairs |
| `OOO_IQ` | Issue queue: 16 entries, 2 sources and 1 destination per µop, 6 wakeup buses, 2 in / 3 out per cycle (ALU0 + MUL/DIV, ALU1, LSU), 1-cycle wakeup-select, oldest first by an age matrix, latency-2 and external wakeups | `tb_iq`: every issue against an independent account of when values are usable |
| `OOO_RAS` | Return address stack: 16 entries in LUTRAM, recovery from a block's snapshot (pointer and the entry a push overwrites) | `tb_ras`: against a reference stack |
| `OOO_RENAME` | Renaming: 2 µops per cycle with 2 sources and 1 destination, 64 physical registers, RAT, free list, busy bits, in-group dependences, 8 checkpoints copied a cycle late, the committed-state RAT for `flush_all` | `tb_rename`: against a reference with commits, write-backs and restores |
| `OOO_PREDEC` | Predecode (F2): instruction boundaries (with a 32-bit instruction carried from the line before), the kind of each control transfer and the targets of branches and jal, 8 adders in parallel | `tb_predec`: 2,000,000 random blocks against a reference from the specification |
| `OOO_PRF` | Physical registers: NREG × 64 (64 in the fusion configuration), NW writes / NR reads (3 / 6), LUTRAM banks + live value table | `tb_prf`: random reads and writes against an array |
| `OOO_LSU` | Load / store unit: LQ 12, SQ 12, forwarding from the youngest older store, conservative ordering (`lsu_st_known`), `ld_cancel` and late results for misses, recovery to a checkpoint or the committed state | `tb_lsu`: the rest of the core modelled, every load value against program order, 7 seeds |
| `OOO_ROB` | Reorder buffer: 24 µops, 2 in / 2 committed a cycle, payload in two LUTRAM banks by parity, 4 completion ports, the oldest misprediction of a cycle restores, traps at the head, `head_ns` for non-speculative µops | `tb_rob`: against a reference ROB, 4 seeds |
| `OOO_TAGE` | TAGE-S per fetch block in block RAM: 4 tagged tables × 1024 rows with 3 slots (the 1st–3rd conditional branch of a block), base per parcel, history from a 70-bit shift register, update at commit from the metadata kept in the FTQ | `tb_tage`: against `tage_ref.h`, every prediction and all metadata, 4 seeds |
| `OOO_UBTB` | Next-line predictor: 16 entries, 12-bit partial tags, next fetch address in one cycle with a parallel choice | `tb_ubtb`: against a reference table |

- Coding follows mmRISC-2 (`logic`, `always_ff` with active-low asynchronous reset, comments on what and why).
- Every block is linted by Verilator (`-Wall`); the unit tests start everything that has no reset at random values.
- `SIM/OOO_UNIT/mutate.py` breaks the RTL on purpose (122 mutations); all are detected.
- Out-of-context synthesis in Vivado: `FPGA/OOO_OOC` (`synth_ooo.bat`), run by the author.
