# Phase 1, step 4: putting the integer core together (the plan to G1)

[日本語](CORE_J.md)

- Date: 2026-10-29
- Purpose: step 4 of `Doc/UARCH.md` section 8. The blocks of `RTL/CPU/OOO` and `RTL/CPU/CORE` are written, tested
  alone and measured in Vivado (`Plan/OOC.md` 1 to 25); this plan puts them together into the integer out-of-order
  core (M-mode, bare metal, `Doc/STRATEGY.md` Phase 1) and brings it up to **G1**. It gathers in one place the
  "contracts for the assembly" left in `Plan/OOC.md` and `Doc/UARCH.md`, says what is still to be written, and in which
  order.
- Not in Phase 1: the FPU, the MMU / TLBs and S / U modes in use (CORE_CSR has them; nothing switches to them), PMP,
  debug, interrupts from devices, LiteX. They come in Phase 2.

---

## 1. The core's top (`OOO_CORE`)

```
            +--------------------------- front end ---------------------------+
  I$ <----> | OOO_FETCH (uBTB, PREDEC, TAGE, BTB, RAS) --> OOO_FTQ            |
            |      |  be_stop / be_redirect <-- OOO_FERS <-- FTQ (rs port)    |
            |      v                                                          |
            |   OOO_FBUF --> OOO_DEC x4 --> OOO_FUSE (2 µops)                 |
            +--------------------------------|--------------------------------+
                                             v
   D2  OOO_RENAME  <--- r_go --- OOO_CTRL (masks, go, recovery, commit, ns_ok)
                                             |
   DS  OOO_DSREG (payload, ready snoop) ---> OOO_ROB, OOO_IQ + OOO_IQPL, OOO_LSU (LQ / SQ)
                                             |
   IS  OOO_IQ: port 0 (ALU0, CSR, MUL, MDU, system), port 1 (ALU1), port 2 (LSU)
   RR  OOO_STAGE + OOO_PRF (6 reads) + OOO_IQPL (3 reads)
   EX  port 0: OOO_ALU2 (full) / OOO_CSRU / OOO_PMUL / OOO_MDUP / OOO_SYS
       port 1: OOO_ALU2 (FULL = 0)       port 2: OOO_LSU (E, M) -- OOO_DCAD -- D$
   WB  3 register-file writes (port 0, port 1, LSU), completions to OOO_ROB
   CM  OOO_ROB (2 a cycle) -- OOO_TRAP (exceptions, interrupts, MRET) -- CTRL (free list, LQ / SQ, FTQ pops)
```

| Block | Instances | What it is (the chapter of `Plan/OOC.md`) |
|---|---|---|
| `OOO_FETCH` | 1 | F0 to F2 with uBTB, predecode, TAGE-S, BTB, RAS (14); `be_stop` (21) |
| `OOO_FTQ` | 1 | 16 blocks (D-18), 312 bits of front-end state each (TAGE 270, RAS 42) (13, 21) |
| `OOO_FERS` | 1 | the front end's restore (21) |
| `OOO_FBUF` | 1 | 4 blocks, 4 instructions out (13) |
| `OOO_DEC` | 1 (4 slots) | CORE_DECOMP + CORE_DEC per slot (16) |
| `OOO_FUSE` | 1 | 4 instructions → 2 µops, level 2 (7, 16) |
| `OOO_RENAME` | 1 | 64 registers, 6 checkpoints, busy bits cleared by the wakeups (10, 20) |
| `OOO_CTRL` | 1 | branch masks, go, recovery, ns_ok, commit fan-out, FTQ pops (18 to 22) |
| `OOO_DSREG` | 1 | the DS register's payload, ready snoop (20) |
| `OOO_ROB` | 1 | 24 µops, 4 completion ports (12, 19, 21, 22) |
| `OOO_IQ` + `OOO_IQPL` | 1 + 1 | 10 entries, 3 issues; the payload record (15, 17, 23) |
| `OOO_PRF` | 1 | 64 × 64, 3 writes / 6 reads (9) |
| `OOO_STAGE` | 6 to 8 | the ports' pipeline registers (RR, EX, WB) (20) |
| `OOO_ALU2` | 2 | port 0 full, port 1 `FULL = 0` (8; L7: `Doc/UARCH.md` 6.12) |
| `OOO_CSRU` | 1 | CORE_CSR (2 HPM counters) (23) |
| `OOO_PMUL`, `OOO_MDUP` | 1 + 1 | mul / mulw pipelined; CORE_MDU for the rest (23, 24) |
| `OOO_SYS`, `OOO_TRAP` | 1 + 1 | system µops; exceptions and interrupts (22, 23) |
| `OOO_LSU` + `OOO_DCAD` + `DCACHE` | 1 + 1 + 1 | LQ / SQ 8, the adapter, mmRISC-2's D$ (11, 17) |
| I$ | 1 | mmRISC-2's ICACHE widened to 16 bytes (not in this repository yet), or a model (section 5) |

---

## 2. The formats between the blocks

### 2.1 A µop from fusion to dispatch

What renaming and the DS register take for each of the 2 µops. Most of it is decode's fields of the µop's
instruction(s) (`OOO_DEC`), chosen by `OOO_FUSE`'s `u*_slot` / `u*_kind`.

| Field | Bits | From | To |
|---|---|---|---|
| valid | 1 | FUSE | RENAME, CTRL (`r_valid`) |
| use, src (architectural) | 2 + 2 × 5 | DEC of the pair's halves, the second's read of the first's rd removed | RENAME |
| wr, dst | 1 + 5 | the half that writes (W1: at most one) | RENAME, ROB |
| ckpt | 1 | a conditional branch or a jalr in the µop (a jal never mispredicts) | RENAME, CTRL |
| pc | 38 | FTQ block pc (`rd_pc`) + the first half's parcel | ROB (`disp_pc`), the pc array (section 3.2) |
| len | 3 | halfwords of the µop (1 to 4) | ROB |
| ftq | 3 | **the block of its last half** (+1 when the instruction crosses a line: `Plan/OOC.md` 21.1) | ROB, CTRL (`ds_ftq`) |
| exc, cause, tval | 1 + 5 + 64 | decode: illegal (tval the instruction bits), a fetch fault, ECALL (cause by the level), EBREAK | ROB (`disp_exc`), OOO_TRAP `tv_*` (dispatch ports) |
| port, lat2, ext_ans, ns, md | 2 + 1 + 1 + 1 + 1 | FUSE `u*_port`; DEC; `md` = an MDU µop answered from outside | IQ |
| fused | 1 | `u*_kind` ≠ 0 | ROB (counts 2 in instret), OOO_TRAP (`head_fused`) |
| ld, st | 2 | a load / a store in the µop | LSU, CTRL, ROB |
| the record | W (2.2) | everything RR and EX read | IQPL |
| insn ×2 | 64 | the instruction bits (simulation only) | the trace (section 3.9) |

- Dispatch writes the IQ entry with `disp_wr` = it writes in a slot the queue wakes for (latency 1 or 2); a µop
  answered from outside (MDU long ones, AMO later) is dispatched with `disp_wr` 0 and wakes on `ext_*`.
- A rare class (decoded in slot 0 only) in slot 1 to 3 ends the fetch buffer's group: told by `OOO_RARE` from the first
  parcel, not by decode (`Plan/OOC.md` 26: decode's `cut` in the fetch buffer's loop missed 50 MHz). Illegal
  instructions are reported in every slot.

### 2.2 The payload record (`OOO_IQPL`, W bits)

The record is written at DS and read in RR by the entry. Port 2 reads only its low W2 bits (`Plan/OOC.md` 17.1, G0b
G3). The layout to fix (about 96 bits, as counted in 17.1; the cost is linear in W):

| Bits | Field | Port |
|---|---|---|
| low part (W2 = 48) | rob 5, lq 3, sq 3, offset 12, size 2, signed 1, mem cmd 5 (load / store / AMO / cbo), pair kind 2 (ALU + load, store pair), the ALU + load's operation 6, ftq 3, ckpt 3 | 2 (and the shared ones) |
| high part | imm 32 (an ALU's immediate, a branch's offset), alu_op 6, a_uw, a_shift 2, a1_sel 2, b1_imm, word_op, is_br, br_op 3, br_fused, br_res1_a, br_o_sel 2, is_jal, is_jalr, call, ret, pred_taken, offset in the block 3 (pc, section 3.2), mdu_op 4, csr fields (addr 12, op 2, imm sel) or sys op 3 | 0, 1 |

- The pc is not in the record (38 bits): it comes from the pc array in RR (3.2). A jalr's predicted target comes from
  the target array (3.4).
- csr_addr shares the high bits with the immediate (a CSR µop has no ALU immediate).

### 2.3 The ROB's dispatch fields

`disp_pc`, `disp_wr`, `disp_arch`, `disp_new` / `disp_old` (from renaming), `disp_ld` / `disp_st`, `disp_fused`,
`disp_ns`, `disp_len`, `disp_ftq`, `disp_exc` / `disp_cause`. The completion ports (NCMP 4): port 0's write-back,
port 1's write-back, the LSU's loads, the LSU's stores.

---

## 3. The glue still to be written

| # | Glue | What it is | Notes |
|---|---|---|---|
| 3.1 | `OOO_CORE` and the D2 / DS wiring | the µop of 2.1 from decode and fusion; renaming, CTRL, DSREG, ROB, IQ / IQPL, LSU at dispatch; CTRL's recovery to every block | the contracts of `Plan/OOC.md` 20.1, 21.1, 22.1, 23.1, 24.1 |
| 3.2 | The ports' pipelines | per port: OOO_STAGE after IS (RR) and after RR (EX), the PRF reads (2 a port), IQPL's record, the operand choice (register, immediate, pc), the result into the write-back register (OOO_STAGE) | the pc: a **pc array** (the FTQ blocks' pcs, 8 × 38 bits) with 2 read ports in RR, + the offset (decision 4.1) |
| 3.3 | The bypass and the register-file writes | an operand comes from the PRF or from one of the 3 write-back registers (port 0, port 1, the LSU): the 4 sources `OOC_ALU2` was measured with. For that, a result is written into the PRF at the edge it enters its write-back register | OOO_LSU must give its M result (the D input of its WB register) for the PRF (decision 4.2) |
| 3.4 | Branch resolution | per ALU port in EX: the direction (OOO_ALU2 `take_branch`) against `pred_taken`; a jalr's target against its predicted one (a **target array**, the FTQ blocks' predicted next addresses, read in RR); `br_valid` / `br_mispred` / `br_ckpt` / `br_next` to CTRL and ROB, `br_e` / `br_taken` / `br_call` / `br_ret` to OOO_FERS; the BTB written for an indirect jump (`bt_*`) | a branch's target is pc + imm (direct targets were right at F2) |
| 3.5 | Port 0's units | ALU0, OOO_CSRU (EX, at the head), OOO_PMUL, OOO_MDUP, OOO_SYS; the result into port 0's WB (ALU / CSR in EX, PMUL a cycle later, MDUP when the slot is free); `slot_busy`; `iss_md` / `mdu_ok` / `p0_hold`; OOO_SYS's completion; the tval port of port 0 (CSRU and SYS, one at a time) | OOO_SYS completes without a write: decision 4.3 |
| 3.6 | Port 2's fields and pairs | the LSU's `iss_*` from RR / EX (base, imm, data, size, sign, dst, rob / lq / sq, bm); **ALU + load**: the base is the ALU's result (an ALU in front of the address adder); **store + store**: two SQ entries for one µop | neither pair is in OOO_LSU yet (decision 4.4) |
| 3.7 | Commit | ROB → renaming's committed state, CTRL (free list, LQ / SQ counts, FTQ pops), CSRU's `instret_inc`, OOO_TRAP; the **TAGE update**: each popped FTQ block's slot outcomes (`up_ex` / `up_tk`, kept per block at resolution) with its metadata | the outcomes come from the branches' resolutions (3.4) |
| 3.8 | The front end | OOO_FETCH's block into FBUF and the FTQ (pc, next, taken, end, TAGE metadata, RAS snapshot); `credit` from FBUF and FTQ; decode's FTQ reads (`rd_pc`, 2 blocks); the FERS read; the I$ port | the FTQ is widened to its 312 bits here |
| 3.9 | The commit trace (simulation only) | for `SIM/LOCKSTEP`'s `Commit` records: per ROB entry a shadow of the instruction bits (2 for a pair), the value written (taken at the write-back), the store's address and data (from the LSU in E), the trap's cause; a pair's first half marked `rd_skip` | no hardware cost: `ifdef` in the top |
| 3.10 | Memory for the simulation | the I$ and the D$ on an AXI4 memory model with an ELF loader and HTIF (`tohost`); first a simple model of each cache | tb_dcad's memory model and LOCKSTEP's rules |

---

## 4. Decisions to make on the way (recommendations, accepted 2026-10-29)

| # | Item | Recommendation | Why |
|---|---|---|---|
| 4.1 | The µop's pc in EX | a pc array (FTQ blocks' pcs) with 2 read ports in RR, + the offset; not 38 bits in the record | 2 small LUTRAM reads (tens of LUTs) instead of 38 more bits in 10 entries × 2 banks × 3 reads |
| 4.2 | When the PRF is written | at the edge a result enters its WB register (the WB registers are the bypass sources for the cycle after); OOO_LSU gives its M result for it | keeps the 4-source bypass measured; the alternative, a second level of WB registers, is a 5th source in the ALU loop. The LSU's M → PRF write path is to be measured (its M is the critical path of OOC_LSUDC, +0.820 ns) |
| 4.3 | OOO_SYS's completion | in port 0's completion slot when it is free (the `slot_busy` rule of OOO_MDUP) | a 5th ROB completion port costs a compare per entry; system µops are rare and at the head |
| 4.4 | Port 2's pairs (ALU + load, store pair) | bring the core up with fusion off, then turn the ALU-port kinds on (lui + addi, auipc + x, slli + srli, ALU + branch), then write the two LSU pairs and measure what they bring in the model before keeping them | they are the only kinds that need new LSU logic |
| 4.5 | A jalr's predicted target | a target array (FTQ blocks' next addresses, 8 × 38) with one read port in RR | the FTQ's third read port is OOO_FERS's |
| 4.6 | The I$ for bring-up | a model first (2 cycles on a hit, as OOO_FETCH expects); mmRISC-2's ICACHE widened to 16 bytes before CoreMark | fetch and decode can be brought up before the cache is |

---

## 5. Bring-up order

| Step | What runs | Checked by | Done when |
|---|---|---|---|
| B0 | The test bench: ELF loader, memory model, HTIF, the commit trace into `SIM/LOCKSTEP` | the lock-step self-test on a stream from Spike | the bench runs `selftest`'s streams |
| B1 | The front end alone: fetch through the I$ model, FBUF, decode, fusion off; the decoded stream | against Spike's pc sequence (a back end that takes every µop and follows the true path, as tb_fetch) | rv64ui programs fetch and decode in order |
| B2 | The core with ALU µops only (port 0 / 1), no memory, fusion off | lock-step at every commit | straight-line ALU programs, then branches and jal / jalr (mispredictions, restores) |
| B3 | Loads and stores: LSU with a D$ model, then OOO_DCAD and the real D$ | lock-step | rv64ui's loads and stores, the store-forwarding tests |
| B4 | riscv-arch-test: I, M, C, Zba / Zbb / Zbc / Zbs, Zicond, Zicsr, privileged M (CSRs, traps, MRET, FENCE.I); the MDU and PMUL (the M tests need them) | lock-step (it checks every store: the suite's signature is stores; 5.7) | all pass (the ones mmRISC-2 also fails excepted) |
| B5 | Fusion on, kind by kind; interrupts (a timer model) | lock-step (`rd_skip` for first halves) | B4 again with fusion on |
| B6 | CoreMark (the three builds of `Plan/trace`) with the real caches | its cycles against the model | within ±5 % of the model (G1) |
| B7 | `OOO_CORE` out of context in Vivado | `synth_ooo.tcl` | the LUTs and 50 MHz (G1) |

- Each step keeps the unit tests (`SIM/OOO_UNIT/run.sh`) and the bug injection green; the core gets its own bug
  injection (the lock-step must catch a mutation of the glue) from B2 on.

### 5.1 B0: the test bench (done 2026-10-29)

`SIM/CORE` (its README has the details): the C++ side of the core's test bench, written before the core.

| Part | What it is |
|---|---|
| `Memory` | sparse 4 KB pages over the reference's RAM region, loaded by the bench's own ELF loader (every symbol: `tohost`, `fromhost`, the signature's bounds); the models of the core's ports read and write it, and HTIF sees the writes through a hook |
| `Htif` | the exit and the console from the **committed stores**; `tohost` back to 0 from the **memory side**, when a write that makes it nonzero reaches the memory |
| `TraceSlot` | the commit-trace port of 3.9, 2 slots a cycle: pc, the 1 or 2 instructions, `pair`, trap and cause, the one write (`rd`, `rd_val`, `wr_first`: the write is the first half's, ALU + branch), the store of each half. A first half that neither writes nor stores becomes `rd_skip` |
| `Bench` | lock-step with `SIM/LOCKSTEP` at every instruction, a watchdog, the **architectural memory** (the ELF with the committed stores: riscv-arch-test's signature at B4 comes from it, not from behind a write-back D$), the last 16 commits disassembled on a failure |

It was tested with a stand-in core: a second Spike on the bench's memory, whose stores to the page of `tohost` wait
0 to 24 cycles in a queue (with forwarding) as behind the SQ and the D$, and whose commits go through the trace port,
0 to 2 slots a cycle, fused where one write per pair allows. On the 175 riscv-tests `-p-` and the two g14 CoreMark builds: all pass with the reference's exit code and console, the architectural memory equals the stand-in's, and all 2,019 port mutations that applied are caught (`SIM/CORE/results/standin.txt`); the bug injection into the bench detected 18 of 18 changes (`SIM/CORE/results/mutate.txt`).

Three rules came out of it:

1. **A loop polling `tohost` runs longer in the core** than in Spike (the character's store reaches the memory
   later). `SIM/LOCKSTEP` now gives the reference the core's value for loads of `tohost` and `fromhost`, as for the
   counters, and the reference runs the same loop (CoreMark: 3,667 and 6,715 such loads in the two builds).
2. **`tohost`'s line must not stay in the D$** (to do at B3, with the D$): with the real write-back D$ the core
   would read its own character back for ever. The bench makes that line non-cacheable for the core (the D$ adapter
   sends its loads and stores to the memory; a bench parameter under `ifdef`). The port models of B1 to B3 write the
   memory directly.
3. **The architectural memory holds without translation**: a store commits its virtual address. Phase 2 (the MMU)
   gives the trace the physical address too.

### 5.2 B1: the front end alone (done 2026-10-29)

`RTL/CPU/OOO/OOO_FRONT` puts the front end together up to the D1 / D2 register (glue 3.8); `SIM/CORE/tb_front`
fetches and decodes real programs with it against Spike's path (`SIM/CORE/README.md`).

Decisions made on the way:

| # | Item | What | Why |
|---|---|---|---|
| B1-1 | D1 / D2 | **Since 2026-10-29, D1a / D1b** (`Plan/OOC.md` 26.8): the fetch buffer's group goes raw (4 × 41 bits) into a register R (D1a), or into the **skid** when R is not freed that cycle; R is decoded into the group register (4 decoded instructions, D1b), which takes a new group only when D2 empties it, and R then takes the skid's group, else the buffer's. The fetch buffer's consume is its valid instructions up to the first of a rare class (the buffer's `out_rare`: `OOO_RARE` on its window's parcels, `Plan/OOC.md` 26.11; first decode's `cut`, which missed 50 MHz: `Plan/OOC.md` 26), 0 while the skid is full | The contract of `Plan/OOC.md` 13.6: consume must not depend on what D2 computes (fusion, renaming's go); R's freeing waits for D2 and only enables R and the skid. Reading the buffer and decoding in one cycle closed by 0.03 ns (`Plan/OOC.md` 26.6): each has a cycle now, for one cycle more from a redirect to D2 |
| B1-2 | FTQ | 312 bits a block (TAGE 270, RAS 42); a **fourth read, the head's**, for the TAGE update at the pop; `free_n` for the credit | the update needs the popped block's metadata |
| B1-3 | FTQ pops | **one a cycle** (OOO_CTRL changed from 2; M330 in `SIM/OOO_UNIT/mutate.py`) | TAGE takes one block's update a cycle; two pops would need a second head read of 270 bits. The blocks wait in the FTQ a little longer |
| B1-4 | the slot branches' outcomes | in OOO_FRONT by block and parcel (8 + 8 flip-flops a block): cleared at the push, written when a conditional branch resolves (`rs_*`: block, last parcel, outcome), cleared after the point of a restore, turned into slots at the pop with the parcels in the metadata | the ALU ports may resolve two a cycle; by parcel, the resolution needs no read of the metadata |
| B1-5 | the target array (4.5) | in OOO_FRONT: written at the push, read by `ta_idx` | |
| B1-6 | decode's FP fields | not in the group register in Phase 1 (`is_fp` only) | no FPU |

Results (`SIM/CORE/results/front.txt`):

- 175 riscv-tests `-p-` on 2 seeds and the two g14 CoreMark builds: all fetched and decoded in Spike's order to the
  exit. Every TAGE update (1.74 M in the CoreMark runs) carries the popped block's metadata and the right slots and
  outcomes, and every restore reads back what its block's push wrote: the bench checks the glue exactly, since a
  wrong slice of the history or the RAS only costs predictions.
- What the front end delivers (D2 taking 2 a cycle, no I$ miss, each misprediction resolved 2 to 7 cycles after D2):
  1.51 / 1.56 instructions a cycle on g14 -O2 / sf + -flto. **Since D1a / D1b (`Plan/OOC.md` 26.8): 1.44 / 1.49, limited
  by the FTQ of 8 blocks; with 16, 1.82 / 1.83 (D-18, taken: the FTQ has 16 blocks since 2026-10-29).**
- The unit tests of OOO_CTRL, OOO_FBUF, OOO_FTQ, OOO_FERS, OOO_FETCH pass; the bug injection into the glue detected 35 of 35 changes (`SIM/CORE/results/mutate_front.txt`; the restore's RAS fields and fetch's stop in cycle R needed exact checks in the bench, since they cost only predictions or nothing visible).
- **Mispredicted conditional branches: 6,582 / 5,742 against the model's 4,772 / 4,177** (`Plan/model/tageblk.h`,
  updated at once); 8,426 / 6,106 with D2 at full speed. Here a block's update comes at its pop, after its last
  instruction commits (6.4 to 6.6 blocks after its prediction). **Measured in 5.3: the update delay is a small part;
  most of it is TAGE's history lag, which changes with fetch's stalls** (D-17).
- **Vivado**: `synth_ooo.bat OOC_FE` (the whole front end, `g_take` arriving at 12 ns as from fusion and renaming).

### 5.3 The TAGE update at commit, and the history lag (2026-10-29)

B1 mispredicts 25 to 73 % more conditional branches than the model (5.2). The question was whether the update at
commit is the cause. It is a small part; most of it is **the history lag varying with fetch's timing**.

What was added to the model (`Plan/model`, `results/tagedelay.txt` from `tagedelay.sh`):

- `tage.h`: `predict()` and `update()` apart, the update computed from the entries as read at the prediction and
  writing them whole (what OOO_TAGE does at commit); `step()` unchanged (4,404 on the branches alone, as before).
- `ooo.h`: `upd=1`, each branch's update at its commit (+ `upd_lag` cycles, the pop's write); `stale`.
- `tageblk.h`: `delay`, the block's update that many blocks after its prediction (predictions from the rows as read).
- `model tageref`: **OOO_TAGE's own algorithm** (`SIM/OOO_UNIT/tage_ref.h`, the mirror `tb_tage` holds the RTL to)
  on the same blocks, with the history lag, the delay (and its spread) and fetch stalls.
- `SIM/CORE/tb_front`: the blocks pushed between a block's push and its update (6.4 to 6.6 on the true path in every
  mode), and the mispredictions by branch (`FRONT_BYPC`).

Mispredicted conditional branches (CoreMark/MHz of the cycle model in brackets):

| | g14 -O2 | g14 sf + -flto |
|---|---|---|
| `ooo.h`, TAGE per branch updated at once (G0b, D-16) | 4,393 (6.193) | 3,291 (6.680) |
| `ooo.h`, updated at the branch's commit / 4 cycles after it | 4,436 (6.191) / 4,516 (6.188) | 3,393 (6.675) / 3,498 (6.670) |
| `tageblk.h`, updated at once / 8 / 16 blocks later | 4,752 / 4,985 / 5,583 | 4,153 / 4,209 / 4,317 |
| OOO_TAGE's algorithm, lag 2, updated at once | 4,576 | 3,935 |
| the same, updated 6 blocks later (B1's distance) / 6 ± 3 | 5,279 / 5,418 | 4,526 / 4,569 |
| the same, lag 0 after 10 / 30 / 50 % of the blocks (fetch stalls) | 7,177 / 9,643 / 8,789 | 6,225 / 7,295 / 7,019 |
| **B1** (D2 at random / at full speed) | **6,582 / 8,426** | **5,742 / 6,106** |

1. **The update at commit costs little**: −0.03 % to −0.15 % of CoreMark/MHz with the per-branch TAGE; with
   OOO_TAGE's per-block rows at B1's distance, +700 / +600 mispredictions.
2. **The history lag**: OOO_TAGE reads its tables at F0 with the history of that cycle, which lacks the blocks still
   in F1 and F2: 2 blocks while fetch streams, fewer after a stall (a full FTQ or fetch buffer, an I$ miss, an
   override, a restore). The same branch then reads with another history, another row. In a loop of one block a pass
   (`core_bench_list` at 0x80000f18) both the exit and an iteration are missed every time: 1,788 in B1 (912 taken,
   876 not taken), 1,687 in the model with 30 % stalls, almost none with a constant lag.
3. **The cost**: B1 is +2.2k to +4.0k (-O2) and +2.5k to +2.8k (sf + -flto) above the G0b model; at the model's
   10.2 cycles a misprediction (dispatch held after one), **+1.4 to +2.5 % / +1.7 to +1.9 % of the cycles**: 6.193 / 6.680
   would become about 6.04 to 6.11 / 6.56. Inside G1's ±5 %, but a loss.
4. **The fix (proposed D-17, `Doc/UARCH.md` 9): read with a constant lag of 2 blocks.** The index uses the history
   without the bits of the 2 blocks before the one read, whichever of them are already in it (fetch knows how many
   are in flight). Hardware: the bit counts of the last 2 blocks pushed (2 × 2 bits), a shift of the 70-bit history by
   0 to 6 before the fold (a 7:1 select chosen early from registers, about 0.15k LUTs, on the F0 path to the block
   RAM addresses), and the count of the block before in each FTQ entry (+2 bits) for the restore. Expected: the
   model's 5,279 / 4,526 instead of B1's, **about −1.2k to −3.1k mispredictions, +0.8 to +2.0 % CoreMark**.
5. **For B6**: even then OOO_TAGE (per block, updated at commit) is +0.9k / +1.2k above the per-branch TAGE of
   `ooo.h` (+0.6 % / +0.8 % of the cycles). The model's reference for G1 should get OOO_TAGE's structure with the
   commit timing (`tage_ref.h` in `ooo.h`) before B6 compares the two.

### 5.4 B2: the core with ALU µops only (2026-10-30)

`RTL/CPU/OOO/OOO_CORE` puts the core together for B2: the front end (`OOO_FRONT`), D2 (fusion off), renaming, the
control, the DS register, the ROB, the issue queue and its payload, the register file and the two ALU ports (RR, EX,
WB), branch resolution and commit; no memory, no CSRs, no MDU. `SIM/CORE/tb_core` runs it on the bench of B0 in
lock-step with Spike at every instruction (`SIM/CORE/README.md`).

Decisions made on the way:

| # | Item | What | Why |
|---|---|---|---|
| B2-1 | D2's group | **Rotated to its oldest valid slot** (a 4:1 select by a registered head) before OOO_FUSE and the µops' fields. The group register keeps what D2 left in its slots (B1-1), while OOO_FUSE pairs from slot 0 | Not in the plan: shifting the group register at each take would put a select on all 680 decoded bits behind `g_take` (late). The rotation covers OOO_FUSE's inputs and the two µops' fields: about 0.3k to 0.5k LUTs, not in the budget; measured at B7 |
| B2-2 | Renaming's `ready` | Counts the destinations of the µops **offered** (`in_wr`, given by the core for valid µops), not of those that go (`in_valid` = the control's `r_go`); µop 1's checkpoint id likewise counts µop 0's checkpoint as offered | A combinational loop found when the two blocks were joined: `ready` → `r_go` → `in_valid` → `ready`; the unit tests drove each alone. tb_rename now offers µop 1 only with µop 0, as the control does |
| B2-3 | The record (OOO_IQPL, 96 bits) | B2's fields: ROB index, block, checkpoint, last and first parcel, line cross, length, a jalr's offset, the immediate, the ALU operation and operand choices, branch, jal / jalr, call / ret, the prediction | 2.2's layout with the LSU's fields comes with B3 |
| B2-4 | jal / jalr | The link is the ALU's pc + length (the immediate replaced by the length, the operand by the pc); a jalr's offset goes apart in the record. A jal is never resolved | predecode's target of a jal is always right |
| B2-5 | The pc and the jalr's predicted target in RR | Two reads each of the target array and of a **pc array** (the FTQ blocks' lines, 4.1) in OOO_FRONT; the pc is the line of the first half's block (the µop's block less one when it crosses) and the first half's parcel | 4.1, 4.5; one read per ALU port |
| B2-6 | EX | Resolution and completion in EX; the register file written at the edge the result enters WB (4.2); the bypass from the 2 WB registers (the LSU's comes at B3) | |
| B2-7 | The bench | `boot` / `boot_pc` start fetch; `trap_vec` is an input until the CSRs; B2's programs end at the symbol `pass` (`BenchCfg.exit_sym`), with no HTIF | no memory in B2 |

The programs (`SIM/CORE/b2/gen_b2.py`): 20 random ALU programs (RV64I, Zba, Zbb, Zbs, Zicond, compressed where the
assembler can) and 20 with forward branches, nested counted loops, jal, calls through x1 and x5 (jal, c.jalr, jalr
with an offset, one through the other link register) and returns, indirect jumps (c.jr, jalr with an offset), bursts
of branches behind a dependent chain (the checkpoints run out), long runs only ALU0 takes, and branches on an
xorshift state (half mispredicted). Every register is set first.

Results (`SIM/CORE/results/core.txt`; `./run_core.sh`):

| Run | Result |
|---|---|
| 40 programs, I$ misses at random, 2 seeds; and with no I$ miss | all pass in lock-step to `pass` |
| ALU programs | about 645 instructions in 400 cycles: **IPC 1.58 to 1.63** |
| branch programs | 6k to 16k instructions, 136 to 552 restores each, IPC 0.70 to 0.98 |

- **The resolution is checked against the instruction** (what lock-step cannot see: it only steers the predictors):
  the last parcel, taken for a jalr, call / return as predecode tells them, a conditional branch's outcome to the
  TAGE update, the BTB's write of an indirect jump at its last parcel.
- **Bug injection** (`SIM/CORE/mutate_core.py`): 40 changes of OOO_CORE's glue in the first campaign, each built and run on 4 ALU and 10 branch programs with a budget of restores; 12 were left. **Seven are caught now**: by the check of the resolution (a jalr call not marked a call, a jalr not taken for FERS) and by programs with what the first ones lacked (c.jalr's link, a jalr's offset, a call through the other link register, bursts of branches that run the checkpoints out, where renaming takes 1 µop of 2 and µop 1's checkpoint id matters). **Five are equivalent and left out** (the reasons in `mutate_core.py`): the wrap of the rotated slots (never valid: the mask is gone from the RTL), an empty µop's destination counted by renaming's ready (64 registers never run short with 26 in flight), the branch masks into RR and EX (a killed µop acts at most 2 cycles after a restore, and the restart reaches renaming 6 cycles after it at the earliest), the register file written by an empty EX stage (an empty stage carries wr 0). **35 of 35 detected** (`results/mutate_core.txt`). The unit test of renaming got M346 (ready from the µops that go): 310 unit mutations now.
- Also changed: `tb_front` (B1) uses both reads of the target array and checks the pc array; the unit test of
  renaming (M346 added).

### 5.5 B3: loads and stores (2026-10-31)

`OOO_CORE` gets port 2 and `OOO_LSU`; `RTL/CPU/OOO/OOO_CPU` puts it together with `OOO_DCAD` and mmRISC-2's D$ on an
AXI4 memory bus and an AXI4-Lite peripheral bus. `SIM/CORE/tb_core` runs both in lock-step: `OOO_CORE` with a model of
the LSU's D$ port (B3a), `OOO_CPU` with AXI models on the bench's memory (B3b).

Decisions made on the way:

| # | Item | What | Why |
|---|---|---|---|
| B3-1 | Port 2 | RR and EX stages as the ALU ports; the LSU's E is the core's EX (it adds base and offset there), so the base and a store's data take the bypass in EX like any source; 3 bypass sources now (the two ALU ports' WB registers and the LSU's) | the LSU takes `iss_*` combinationally in E |
| B3-2 | The register file and loads | **`OOO_LSU` gives `rf_*`**, its M result (what its WB register takes), and the register file is written with it at that edge | 4.2: a load's dependent issued 3 cycles after it reads the register file in RR; written from the WB register a cycle later, it would read the old value |
| B3-3 | A late load (a miss, a wait) | **no wakeup of its own**: its WB (`wb_late`) wakes nothing. I first gave it the issue queue's external wakeup 0; the bug injection showed it redundant | the issue queue wakes a load's dependents two cycles after its issue whatever happens, and the load completes marked and is replayed after commit (D-12): nothing waits for a second wakeup |
| B3-4 | The record | the LQ and SQ entries (from `disp_lq` / `disp_sq` at DS, as the ROB index), size, unsigned, load or store, in the 10 bits left | 96 bits in all |
| B3-5 | The D$ in the core | `OOO_CORE` keeps the LSU's abstract D$ port, as it keeps the I$ port; `OOO_CPU` adds `OOO_DCAD` and `DCACHE` (and later the I$) | the bench can drive either |
| B3-6 | `tohost` not cached (rule 2 of 5.1) | `DCACHE` takes, under `DCACHE_SIM_UC` (simulation), one line it does not cache, `sim_uc_line`: its accesses go to the AXI4-Lite bus as below MEM_BASE. The bench gives it `tohost`'s line | the console's polling loop must see the memory side clear `tohost` |
| B3-7 | The trace | per ROB entry a store's address, data and size (taken in E), a load's value (with its completion) | the bench's HTIF and the architectural memory come from the committed stores |

The programs:

- `b2/gen_b2.py ls`: 20 random programs with B2's branches, loops and calls, and loads and stores of every size into a
  24 KB buffer through seven bases (one for the compressed forms, five 4 KB apart: more lines on a set of the D$ than
  its 4 ways, so lines are evicted and written back): stores and loads of the same word soon after each other
  (forwarding, or a wait when the store does not cover the load), values passed through memory to dependent loads,
  bursts of stores (the SQ fills).
- `b3/build.sh`: riscv-tests' rv64ui (loads, stores, `ld_st`, `st_ld`; all but `ma_data` and `fence_i`), rv64uc and the
  Zba / Zbb / Zbs / Zicond tests on `b3/env/riscv_test.h`, an environment without CSRs (every register 0 first; PASS /
  FAIL write `tohost` themselves); `b3/htif.S`, the console through `tohost` with its polling loop.

Results (`SIM/CORE/results/core.txt`; `./run_core.sh`):

| Run | Result |
|---|---|
| OOO_CORE, the D$ model: 60 random programs, 2 seeds (8 % I$ misses, 80 % D$ hits); no I$ miss and no D$ hit | all pass |
| OOO_CORE, the D$ model: the 95 riscv-tests and the console, 2 seeds (80 % / 30 % hits; also 0 %, 50 %, 100 % by hand) | all pass |
| OOO_CPU, OOO_DCAD and the real D$: the 60 random programs and the 96 tests | all pass; the `ls` programs fill about 230 lines and write back about 17 each |

- **The replay after commit works** (D-12): the `ls` programs replay 30 to 106 loads each (the D$ model's misses),
  all in lock-step.
- **Found: a store can be held off by a stream of loads** (performance, not values). `OOO_LSU` drains a committed
  store only in a cycle with no load in E (that load reads the D$ now and searches the SQ next cycle). The console's
  polling loop issues a load of `tohost` nearly every cycle, so the store of the next character waits for a cycle
  with none: with the real D$ (each polling load an uncached read) 25 characters took 301,300 cycles, against 1,509
  with the D$ model. The same holds off stores behind any load-heavy loop until the SQ fills. To fix next
  (proposed): drain when the load in E is to another 8-byte word (a compare; the common case), and when the oldest
  committed store has waited some cycles, drain anyway and send that load to wait in the LQ and be tried again (as an
  older store without its address does). **Done in 5.6** (the second part only).
- **Bug injection** (`SIM/CORE/mutate_core.py`): B2's 35 mutations and 20 for port 2 and the LSU (the record's LQ / SQ entries; loads and stores at dispatch to the LSU, the ROB and the control; the LSU's operands, the offset, the size and sign; the bypass of the base, of a store's data and of the LSU's result; the register-file write of loads; the replay mark; the SQ's restore and commit), each run on 20 random programs and on 10 riscv-tests and the console, on OOO_CORE with the D$ model: 54 of 55 detected. The one left, the late load's external wakeup, was redundant and is gone (B3-3). **54 of 54 detected** (`results/mutate_core.txt`).
- Also changed: `OOO_LSU` (`rf_*`; `tb_lsu` checks that the register file is written with what the WB register
  takes next; M347 / M348 added, 312 unit mutations now), `DCACHE` (`sim_uc_line` under `DCACHE_SIM_UC`).

### 5.6 The store drain no longer held off by loads (2026-10-31)

5.5 found that a stream of loads holds a committed store off: `OOO_LSU` drains one only in a cycle with no load in E.

- **Why only the second half of 5.5's proposal**: the D$ takes one request a cycle. `OOO_DCAD` sends the load in E
  first, then a pending load, then a store, and takes no store while a load is in E or pending. Draining past a load
  to another 8-byte word would need two requests in a cycle, so it cannot happen with the real D$; it was not done.
- **What was done** (`OOO_LSU`, parameter `DRAIN_WAIT` = 8): a counter of the cycles a load in E has held the oldest
  committed store (with its address) off; the cycles it waits for a busy D$ do not count. When it reaches
  `DRAIN_WAIT` the store takes the D$ port: the load in E sends no request,
  goes to wait in M as a load does when an older store has no address (`ld_cancel` for a load from port 2: it completes
  marked and is replayed after commit, D-12) and is tried again from the LQ once the store has left, from the D$. A
  few flip-flops and gates.
- **Counting only the cycles a load holds the store off**: the first version counted every cycle the store waited,
  also for a busy D$, and its forced drains cost replays (the load that gives the port up raises `ld_cancel`): the 20
  `ls` programs on `OOO_CPU` took 0.3 % to 4 % more cycles, `ld_st` 3.6 %. Counted this way:

| `OOO_CPU` (cycles) | before 5.6 | `DRAIN_WAIT` 4 | **8** | 16 |
|---|---|---|---|---|
| the console (25 characters) | 301,300 | 2,005 | **2,240** | 2,611 |
| `rv64ui-ld_st` / `st_ld` | 4,594 / 1,788 | 4,594 / 1,788 | **4,594 / 1,788** | 4,594 / 1,788 |
| the 20 `ls` programs | 159,485 | 159,986 | **159,366** | 159,490 |

- **Tests**: `tb_lsu` and `tb_dcad` have bursts of loads (1,000 cycles in every 4,000: mostly loads, issued 7 cycles in
  8, the D$ always ready); every other burst of `tb_lsu` is a polling loop (only loads, of the last store's word, no
  store after it). `tb_lsu` checks that no load request and store go to the D$ in the same cycle, that loads in E
  never hold a committed store off more than `DRAIN_WAIT` cycles, and that a load gives the port up to no store held
  off less. Every load's value is checked as before. 4 seeds each: PASS.
- **Bug injection**: M46 follows the new line; M349 to M355 (never forced, the load that gave up the port lost,
  taking an answer it never asked for, both requests in a cycle, not tried again, the wait not counted again for the
  next store, the busy D$'s cycles counted): 8 of 8 detected; 319 unit mutations now. "Not tried again" needs the
  polling loop: a load tried again from the LQ that gives the port up in the cycle its store drains has its retry bit
  cleared by that retry, and with no store after it nothing sets it again (the console hangs on `OOO_CPU` with it).
- **The rest still passes**: all 28 unit tests; every LSU and D$-adapter mutation (47 of 47); B2 and B3 on both tops
  (`run_core.sh`, the 7 runs); the core's glue mutations (54 of 54).
- **Vivado** (the author's run): `OOC_LSU` 1,942 → 1,947 LUTs (+5), WNS 6.875 → 6.548 ns; `OOC_LSUDC` 7,678 → 7,681
  LUTs, WNS 0.820 → 1.964 ns (the LSU +5 LUTs; the rest is placement).

### 5.7 B4: riscv-arch-test, the CSRs and traps (2026-10-31)

`OOO_CORE` gets the rest of port 0 (3.5): `OOO_CSRU` (mmRISC-2's CORE_CSR), `OOO_SYS` (FENCE, FENCE.I with the D$
flush and the I$ invalidate, SFENCE.VMA, MRET, SRET, WFI), `OOO_PMUL` and `OOO_MDUP` (planned for B5; the M tests
need them), and `OOO_TRAP` (exceptions, interrupts, the vector, the replay pc). `tb_core` gets FENCE.I's I$ invalidate
and D$ flush on both tops.

Decisions made on the way:

| # | Item | What | Why |
|---|---|---|---|
| B4-1 | The instruction bits for the CSR and system units | per ROB entry (`rob_insn`, written at dispatch, read by port 0's EX at the head), not in the record; the record gets the unit (`kind`, 2 bits) and its operation (`xop`, 4): 102 bits | only the head's µop reads them, and the CSR address and the immediate would take 17 bits of the record |
| B4-2 | Exceptions found at decode | an illegal instruction (and every FP instruction, its loads and stores too: no FPU in Phase 1; decode's `is_fp`), ECALL (cause 8 + the level), EBREAK (cause 3, tval the pc): to the ROB at dispatch, never issued; their tval goes to `OOO_TRAP` through ports 0 / 1 | the ROB takes the exception in order; nothing has to run |
| B4-3 | tval and completion | `OOO_TRAP` with 4 tval ports (dispatch × 2, port 2's misaligned address, the CSR or system unit: one at a time at the head); 6 completion ports (port 0, port 1, loads, stores, PMUL / MDU, the system unit) | one each |
| B4-4 | minstret | an instruction that writes minstret does not count itself (`ir_skip`); **a write to mcountinhibit reaches CORE_CSR at the commit of its instruction**, which counts under the old IR bit (`Sm_mcsr_cntr`) | a CSR µop writes in EX and commits alone next; Spike and Sail count the writing instruction under the old setting |
| B4-5 | mconfigptr | added to CORE_CSR (0xF15, read-only 0) | the privileged spec 1.12 requires it; mmRISC-2 did not have it (`Sm_mcsr_access`) |
| B4-6 | riscv-arch-test without Sail | the ACT4 framework computes the expected values with Sail and compiles them into self-checking ELFs; Sail and the UDB tools are not here. `b4/build.sh` builds each test as the framework builds its signature ELF (`-DSIGNATURE`), and the lock-step with Spike at every instruction checks every register written, every store (the signature is stores) and every trap | the same check, at every instruction instead of at the end |
| B4-7 | The reference set to the core's legal choices (`SIM/LOCKSTEP`) | misa read-only (Spike: writable); mcountinhibit kept by LOCKSTEP (Spike has none; its IR bit takes each instruction's count back from minstret); medeleg's bit 18 reads 0 (no Zicfilp / Zicfiss); a reserved mode of mtvec / stvec written as direct (Spike: bit 1 cleared); the HPM events read the DUT's value | WARL choices both legal, found by `Sm_misa`, `Sm_mcsr_cntr` / `walk-10`, `Sm_mcsr_access` / `walk-00`, `walk-01` / `Sm_scsr_from_m`, `walk-02` to `walk-09` |
| B4-8 | The DUT configuration of the tests (`b4/act`) | `rvtest_config.h` by hand (RV64, M / S / U, C, the B parts, Zicond, Zicsr, Zifencei, Zicntr, Zihpm with 2 counters, 8 PMP entries, mtvec / stvec direct and vectored); `rvmodel_macros.h`: HTIF's halt, x1 to x31 cleared at boot (the PRF has no reset), no access-fault address (the I$ / D$ errors are not wired in Phase 1: those cases are not generated); `riscv_arch_test.h` with `act_sig_macros.h` for `sail_macros.h` (no Sail CLINT: the boot's parking store to mtimecmp goes to a word in the image); the Sm and Exceptions tests generated by the framework's testgen, those whose required extensions fit; the Interrupts tests not built (no interrupt source yet) | the framework wants UDB, Sail and binutils 2.44 |
| B4-9 | binutils 2.43 | `-mno-relax`: 2.43 picks how to fill a code alignment by the relax option at the end of the file, and the tests' `.option pop` sets it back there: the entry's `.p2align` (made under `norelax`) came out as zeros | the tests turn relaxation off anyway |

**Bugs found**:

1. **A load to x0** (`ld zero, ...`): its result has tag 0, and the LSU's write-back register forwarded it to the
   readers of x0 (the PRF reads register 0 as 0, the bypass did not). 19 of the 51 I tests (`add`, `bge`, `srl`, ...:
   the tests load x0 as a source). Fixed: the LSU's bypass only for a tag other than 0. B2 / B3's random programs
   never loaded into x0; `gen_b2.py`'s `ls` programs now do, with a reader of x0 at once.
2. **A multiply to x0** (`mul zero, ...`): `OOO_PMUL`'s result took port 0's write slot, which the issue queue keeps
   only after a multiply with a destination, and the ALU µop of that cycle lost its register write; it was also
   forwarded with tag 0 (and so was a divide's to x0). `M-mul` / `M-mulw` on `OOO_CPU` only (the timing). Fixed: a
   result of the multiplier or the MDU with tag 0 neither takes the slot nor is forwarded. `gen_b2.py`'s `ls`
   programs now multiply, to x0 too, and read x0 after.
3. **mcountinhibit** written in EX made its own instruction count under the new IR bit (B4-4).
4. **mconfigptr** missing (B4-5).
5. **FP loads and stores** were not illegal (only port 3's µops were): `flw` went to the LSU. Found by the directed
   test `b4/dir/illegal.S` written for the bug injection (5.7's last list). Fixed: decode's `is_fp`.
6. **fflags / frm / fcsr with mstatus.FS off** were not illegal: mmRISC-2's CPU_CORE checked it, not CORE_CSR. Fixed
   in `OOO_CSRU`.

Results (`SIM/CORE/results/core.txt`; `./run_core.sh`, 12 runs):

| Run | Result |
|---|---|
| riscv-arch-test, 185 tests (I 51, M 13, Zca 32, Zba 8, Zbb 24, Zbc 3, Zbs 8, Zicond 2, Zicsr 6, Zifencei 1, Zicntr 2, Sm 28, Exceptions 7): OOO_CORE on 2 seeds (80 % / 30 % D$ hits), OOO_CPU | **all pass** |
| riscv-tests' -p- programs of mmRISC-2 (rv64ui / um / uc / uzba / uzbb / uzbc / uzbs / uzicond / mi / si: 130): OOO_CORE, OOO_CPU | **127 pass**; the 3 that Phase 1 cannot run are left out: `rv64mi-p-breakpoint` (the triggers' firing is not wired), `rv64mi-p-csr` (an FP instruction), `rv64si-p-dirty` (paging) |
| `b4/dir/illegal.S` (directed: FP instructions with FS off, illegal compressed encodings and their tval, 32-bit illegal ones, in either slot; on both tops, with the arch-tests) | passes |
| B2 and B3 (5.4, 5.5) | all pass |

- **Bug injection**: `mutate_core.py`, now 84 mutations, run on B2's and B3's programs and then on B4's: B3's 54 (4 follow lines the B4 glue renamed, the WB one split by port), the load to x0's bypass, and 28 for B4 (the exceptions at decode, their cause and tval; the units' µops: kind, MRET, FENCE.I, non-speculative, the MDU's wakeup, the instruction bits, the CSR operand and result, a multiply into the MDU as well, the MDU's write slot, the tag-0 results of the multiplier and the MDU, SRET; completion and tval; OOO_CSRU's counting, tval and the FS check). The first campaign left 6 undetected: an FP instruction not illegal, the tval of an exception in slot 1, an illegal RVC instruction's tval (no program made the case), a multiply into the MDU as well, the MDU's result over the multiply's, a divide to x0 forwarded (no program mixed divides and multiplies). `b4/dir/illegal.S` (which then found bugs 5 and 6) and `ls` programs that multiply after divides and mulh caught five; the sixth, the RVC instruction's tval masked to 16 bits, was redundant (`OOO_FBUF` already gives an RVC instruction with its upper half 0) and the mask is gone. **84 of 84 detected** (`results/mutate_core.txt`). Unit mutations M356 to M358 (a write to minstret counting its own commit, mcountinhibit written in EX, written again at every commit): 3 of 3 detected by `tb_csru`; 322 now.
- **The rest**: all 28 unit tests (`tb_csru` now with the core's protocol for CSR µops: nothing commits in their cycle, one that writes commits alone next; and mcountinhibit); B1 (`run_front.sh`); LOCKSTEP's self-test; `verilator --lint-only -Wall` of both tops: no new warning.

### 5.8 CoreMark, first run (fusion off, 2026-10-31)

`SIM/CORE/run_coremark.sh` (`results/coremark.txt`) runs the three builds of `Plan/trace` in lock-step: on `OOO_CORE`
with no I$ miss and every D$ load a hit (the model's caches), on `OOO_CPU` with the real D$, and on `OOO_CORE` with
misses at random (2 seeds, the second with 30 % D$ hits). **All pass** after these fixes:

1. **Port 0's write-back register took the mask of the µop in EX** for the multiplier's or the MDU's result: a kill
   of a branch younger than the multiply but older than that µop dropped the multiply's bypass for a cycle (the
   register file had it), and a dependent issued on the delayed wakeup read the old value. `g14-sflto` at its 56,598th
   instruction; the runs with misses at random too. Fixed: that result enters WB with no mask (its unit checked the
   kill this cycle; a later kill is of a branch older than it, whose takers die too). B2 to B4 never made the case;
   `mutate_core.py` now ends with CoreMark and has its mutation: **85 of 85 detected**.
2. **The bench**: the register file starts at 0 as Spike's (it has no reset; CoreMark's start saves registers it has
   not written); `DCacheModel` kept the fill of a miss whose LQ entry was freed in the cycle it was in M (the kill was
   applied before that miss was queued), and a new load of the entry took it.

Cycles (whole runs, as the model's; CoreMark/MHz = 10 iterations / cycles):

| | g14 -O2 | g14 sf + -flto | g13 -O2 Zb |
|---|---|---|---|
| the model, fusion off (D-16) | 1,689,007 (5.921) | 1,551,318 (6.446) | 1,718,813 (5.818) |
| `OOO_CORE`, the model's caches | 2,284,618 (4.377) | 2,100,584 (4.761) | 2,290,569 (4.366) |
| `OOO_CPU`, the real D$ | 2,307,398 (4.334) | 2,149,465 (4.652) | 2,304,948 (4.339) |

The core is about 26 % behind the model. Counters of a build with counters (`OOO_CORE`, the model's caches, g14 -O2):

| | the core | the model |
|---|---|---|
| loads that could not finish in M because an older store's address was unknown (completed marked, **replayed after commit**: a flush and a refetch each) | 25,861 (20,618 replays) | none: a load waits for the older stores' addresses (`mem_cons`) |
| mispredicted branches / jalr that commit | 7,582 / 218 | 4,393 / 41 (sf + -flto: 1,593 jalr against 8) |
| cycles with nothing to dispatch / slot 0 held by a full ROB | 275,078 / 192,069 | |

- **The main loss: loads issued past a store whose address is unknown.** A store is one µop that issues with its data
  (`OOO_LSU`), so its address is known late, and the loads after it, whose base is ready, go first and find it
  unknown. The model assumed a store's address known at its issue on the base alone and loads waiting for it. The
  model with stores issued with their data (`st_data_issue=1`, added) and loads waiting: 0.7 % slower without fusion,
  1.9 % with fusion 2. **Proposed**: the issue queue keeps a load while an older store is still in it (registered
  state, off the wakeup-select loop, as the non-speculative condition). **Done in 5.9.**
- **Returns and indirect jumps** mispredict far more than in the model (sf + -flto: 1,593 against 8), and conditional
  branches 1.7 times: to look at after the first fix (the RAS after a replay or a flush, the history after a replay).
- The pipeline's depth is not it: the model with one or two more decode stages loses 0.3 % to 0.5 %.
- **The rest still passes**: `run_core.sh` (12 runs), the stand-in test, the bug injection (85 of 85).

### 5.9 Loads wait for the older stores in the issue queue (2026-10-31)

5.8's proposal: `OOO_IQ` keeps a load (a port-2 µop that is not a store, `disp_st`) while an older store is still in
the queue (`!(port == 2 && !st && (older & v & st) != 0)` in the ready term, beside the non-speculative one: registered
state only). A store issues with its data and knows its address in E; a load issued after it is in M a cycle later
at the earliest, when `OOO_LSU` has the address.

| CoreMark (cycles; CoreMark/MHz) | g14 -O2 | g14 sf + -flto | g13 -O2 Zb |
|---|---|---|---|
| the model, fusion off, stores issued with their data (`st_data_issue=1`) | 1,701,808 (5.876) | 1,562,105 (6.402) | 1,730,925 (5.777) |
| `OOO_CORE`, the model's caches, 5.8 | 2,284,618 (4.377) | 2,100,584 (4.761) | 2,290,569 (4.366) |
| `OOO_CORE`, the model's caches, **now** | **1,913,926 (5.225)** | **1,718,063 (5.820)** | **1,956,056 (5.112)** |
| `OOO_CPU`, the real D$, now | 1,933,121 (5.173) | 1,764,874 (5.666) | 1,967,483 (5.083) |

- 16 % to 18 % fewer cycles; replays 20,618 → 96 (g14 -O2), loads that found an older store's address unknown 25,861 →
  0. Mispredicted jalr that commit: 218 → 62 (sf + -flto: 1,593 → 76): the replays' flushes were what cost the RAS.
- **What is left: 10 % to 13 % behind the model.** Mispredicted conditional branches that commit are still about
  1.75 times the model's (g14 -O2: 7,706 against 4,393), and slot 0 waits for a full ROB 166,098 cycles (the model's
  ROB of the same 24 entries is rarely full): the next things to look at. (*The full ROB was a counter's mistake: 5.12.*)
- **Tests**: `tb_iq` has stores (half the LSU µops answered from outside) and checks that a load issues only with no
  older store in the queue; M359 to M361 (a load past an older store, a load waiting for a younger store, a store
  waiting for an older store) and M230 following the line: 23 of 23 IQ mutations detected, 325 unit mutations now.
  `mutate_core.py`: the IQ's `disp_st` cut (only cycles: the CoreMark stage allows 2,000 replays, `tb_core
  -replays-max`): 86 of 86 detected. `run_core.sh` (12 runs), `run_coremark.sh`, the 28 unit tests, the stand-in test:
  all pass; no new lint warning.
- `OOO_IQ` changed (a flip-flop and an AND-OR of 10 bits per entry): `synth_ooo.bat OOO_IQ` would measure it.

### 5.10 The conditional branches the core mispredicts more (2026-10-31)

After 5.9 the core mispredicts 7,706 conditional branches that commit (g14 -O2, the model's caches) against the
model's 4,393. By branch (a build with counters; the model's `tageref` gives the address of the last parcel, here +2
for a 4-byte branch taken back):

| branch | the core | OOO_TAGE's algorithm, lag 2 always, updated 6 blocks later | the same, lag 0 after 30 % of the blocks |
|---|---|---|---|
| 0x80000f18 `bnez` (`core_bench_list`, a loop of one block) | **1,280** | – (under 56) | 1,687 |
| 0x80000f8c `bnez` (`core_bench_list`) | **796** | – | 718 |
| 0x80000de8 `bge` (`core_list_mergesort`) | 564 | 327 | 544 |
| 0x80000e2e `blez` (`core_list_mergesort`) | 977 | 952 | 1,037 |
| 0x80001492 / 0x80001508 `beq` (`matrix_mul_*`) | 364 / 361 | 361 / 361 | 401 / 388 |
| all | 7,706 | 5,279 | 9,643 |

- **It is 5.3's history lag**: the branches that are hard by nature miss as often as in the model; the excess is in
  the ones a lag changing with fetch's stalls breaks (0x80000f18, 0x80000f8c, part of 0x80000de8), as B1 showed. No
  other cause appears: jalr are 62 (5.9), and a misprediction costs the core about what it costs the model (the front
  end empty 88,499 cycles for 8,439 restores: 10.5 a restore, the model 10.2).
- **D-17 (read with a constant lag of 2 blocks, `Doc/UARCH.md` 9, open)** would bring the core to about the model with
  OOO_TAGE's algorithm, 5,279: about −2.4k mispredictions, at 10.2 cycles about −25k cycles, **+1.3 % CoreMark**
  (g14 -O2). The rest (5,279 against 4,393) is OOO_TAGE's per-block rows (5.3, point 5).
- Of the 10 % to 13 % left to the model this is the smaller part; slot 0 waiting for a full ROB (166,098 cycles of
  1,913,926) is the larger one. (*Wrong: 5.12.*)

### 5.11 D-17: TAGE read with the history lagging 2 blocks (2026-10-31)

Accepted after 5.10. `OOO_TAGE` reads the tables at F0 with the history shifted past the bits of those of the 2
blocks before the one read that are already in it: by the bit counts of the last 2 blocks pushed (`c1`, `c2`), none
when both are still in flight, `c1` when one is, `c1 + c2` when neither. `OOO_FETCH` gives how many live requests are
in flight (`f0_live`, from `qlive`: the ones an override or a redirect dropped do not count). The history register
keeps 76 bits (70 and the 6 a shift can take); TAGE's metadata gets `cprev`, the bit count of the block pushed before
(272 bits, the FTQ's entries 314), which a restore puts back as `c2` (the history field the restore reads is 72 bits
with it; the 6 bits above 70 come back as 0).

| | g14 -O2 | g14 sf + -flto | g13 -O2 Zb |
|---|---|---|---|
| B1, mispredicted (D2 at random / at full speed), before → now | 6,796 / 6,619 → **5,539 / 5,614** | 6,114 / 5,907 → **4,628 / 4,765** | |
| restores in the core (the model's caches), before → now | 8,439 → **5,453** | 6,080 → **5,426** | 6,883 → **6,064** |
| `OOO_CORE`, the model's caches: cycles (CoreMark/MHz) | 1,913,926 → **1,882,020 (5.313)** | 1,718,063 → **1,706,123 (5.861)** | 1,956,056 → **1,945,090 (5.141)** |
| `OOO_CPU`, the real D$ | 1,933,121 → **1,907,780 (5.242)** | 1,764,874 → **1,755,555 (5.696)** | 1,967,483 → **1,958,830 (5.105)** |
| the model, fusion off, stores with their data | 1,701,808 (5.876) | 1,562,105 (6.402) | 1,730,925 (5.777) |

- B1 now mispredicts about what the model with OOO_TAGE's algorithm and a constant lag does (5,279 / 4,526). The core
  gains 0.6 % to 1.7 %; **9 % to 12 % behind the model is left** (not a full ROB: 5.12).
- **Tests**: `tage_ref.h` (the mirror of `tb_tage`, `tb_fetch`) reads with the lag and keeps `c1`, `c2`, `cprev`;
  `tb_tage` gives `f0_live` (the blocks read and not pushed), `tb_fetch` mirrors fetch's live requests (it compares
  all of each block's metadata); `tb_front` compares the 72-bit history field of the restore. Unit mutations M362 to
  M366 (no shift, the wrong count, the count not restored, the wrong count in the metadata, fetch giving 0 in flight)
  and M105 / M112 / M297 following their lines: **330 of 330 detected**; `mutate_front.py` 44 of 44 (a new one: the
  block-before count lost at a restore); `mutate_core.py` 86 of 86. `run_core.sh`, `run_coremark.sh`, B1, the 28
  unit tests, the stand-in test: all pass. `OOC_FRONT` / `OOC_FE` follow the widths (no new lint warning).
- Vivado: `OOC_FE` and `OOC_FRONT` (the shift is on the F0 path to the tables' addresses: `synth_ooo.bat OOC_FE`).

### 5.12 What the core loses against the model, by function (2026-11-01)

**A correction first**: the "full ROB" of 5.9 to 5.11 (166,098 cycles) was a counter's mistake: `rob_avail`,
`iq_ready`, `lq_avail` and `sq_avail` are free counts (0 to 2), and the counter read their bit 0. Counted right
(g14 -O2, the model's caches): dispatch holds slot 0 169,252 cycles, almost all for the issue queue (no free entry
24,201; one free for a pair that needs two 78,275) and the LQ (35,769; 24,553); the ROB has no free entry only 304
cycles (it holds 13.6 µops on average, the issue queue 5.0). The model holds dispatch about as long (the IQ 93,332,
the LQ / SQ 60,555 cycles).

- **Dispatching slot 0 alone** when only one entry is free (the DS register moving slot 1 to slot 0) was tried in a
  copy: no gain (g14 -O2 +0.1 %, g13 −0.1 %), the moved µop costing a cycle of D2. Not kept.
- **By function** (`Plan/model`'s `OOO_BYPC`: the cycles between commits by the pc that ends them; the same counted in
  the core): the core is 180k cycles behind, `matrix_mul_matrix_bitextract` +60k, `core_bench_list` +27k,
  `core_state_transition` +25k, `core_bench_state` +17k, `core_list_mergesort` +14k, and 16k in start-up and
  `ee_printf`, which the model's trace does not hold.
- **`matrix_mul_matrix_bitextract`'s inner loop** (29,160 times, 13 instructions): 10 cycles an iteration in the core
  against 7.6. Six of its µops can go to port 0 only (2 `mulw`, 2 `sh1add.uw`, 2 `sraiw`: L7), and each multiply
  takes port 0's latency-1 slot of the cycle after its issue (its result has port 0's write port, `OOO_IQ` blk0): EX0
  is idle 4 cycles in 10, the next iteration's address µops wait behind the older chain, and the issue queue fills.
- **Two differences the model did not have** (options added; the model with fusion off and stores issued with data):

| model option | g14 -O2 | sf + -flto | g13 |
|---|---|---|---|
| none | 1,701,808 | 1,562,105 | 1,730,925 |
| `mul_wb=1` (the multiply's write slot on ALU0, as the core) | +1.7 % | +2.6 % | +2.2 % |
| `mul_wb=2` (its write slot on ALU1 instead) | +0.7 % | +0.8 % | +1.4 % |
| `lsu_cmt=1` (a load / store commits a cycle later: `OOO_LSU`'s completion through a register) | +1.4 % | +1.5 % | +1.4 % |
| `mul_wb=1 lsu_cmt=1 dec_depth=3` (the core's three) | 1,758,304 (+3.3 %) | 1,629,184 (+4.3 %) | 1,796,933 (+3.8 %) |

  With them the model is 6.5 % / 4.7 % / 8.2 % short of the core (1,882,020 / 1,706,123 / 1,945,090), and in the
  bitextract loop the core still loses 0.8 cycle an iteration at the second multiply.
- **Proposed next**: (A, **done in 5.13**) the multiply writes through port 1's write port and the issue queue keeps port 1's
  latency-1 slot free after a multiply instead of port 0's (ALU1 takes only simple µops, ALU0 everything): about
  −1 % to −1.8 % of the cycles, a 2:1 select on port 1's write and the bypass; (B) a load's completion from M (not
  from the register after it): about −1.4 %, on `OOO_LSU`'s M path (a timing question).

### 5.13 The multiply writes through port 1 (2026-11-01)

5.12's proposal A. `OOO_PMUL`'s result goes into port 1's write-back register (the register file's write port 1
and port 1's bypass), and `OOO_IQ` keeps port 1's latency-1 slot free in the cycle after a multiply (`blk1`: no µop
that writes a register gets port 1 then; it can still go to port 0) instead of port 0's. Port 0 keeps only the MDU's
results (`p0_hold`). ALU1 takes only simple µops and ALU0 everything, so keeping ALU1's slot free costs less.

- **Found on the way**: the MDU's result and the multiply's still share the ROB's completion port (4). With
  `slot_busy` no longer counting the multiply, both completed in one cycle and the MDU's completion was lost: a
  `mulhu` followed by a `mulw` hung `gen_b2.py`'s `ls` programs (10 of 20). The MDU waits for a cycle without the
  multiply's result again (`slot_busy = x_wv || pm_v`); its write slot is port 0's.

| CoreMark (cycles; CoreMark/MHz) | g14 -O2 | g14 sf + -flto | g13 -O2 Zb |
|---|---|---|---|
| `OOO_CORE`, the model's caches, 5.11 → **now** | 1,882,020 → **1,833,565 (5.454)** | 1,706,123 → **1,698,184 (5.889)** | 1,945,090 → **1,894,227 (5.279)** |
| `OOO_CPU`, the real D$ | 1,907,780 → **1,859,255 (5.378)** | 1,755,555 → **1,746,040 (5.727)** | 1,958,830 → **1,907,485 (5.243)** |
| the model, fusion off, stores with their data | 1,701,808 (5.876) | 1,562,105 (6.402) | 1,730,925 (5.777) |

- −2.6 %, −0.5 %, −2.6 % (the model expected −1.0 %, −1.8 %, −0.8 %); **7.7 % / 8.7 % / 9.4 % behind the model** now.
- **Tests**: `tb_iq` follows the rule and has any-ALU µops that write nothing (an eighth: a branch; no source is taken
  from them), so that port 1 is checked to take those after a multiply; M314 follows its line, M367 to M369 (port 1's
  slot taken twice, port 0's kept too, port 1 idle for a µop that writes nothing): 26 of 26 IQ mutations, 333 unit
  mutations. `mutate_core.py`: the MDU's and the multiply's results in one cycle, the multiply's not written on port
  1; the WB-mask mutation of 5.8 no longer reached (only in a cycle with a branch on port 0 mispredicted, a younger µop
  that writes nothing on port 1 and the multiply's result; the guard stays, the reason in its header). `run_core.sh`,
  `run_coremark.sh`, the 28 unit tests, the stand-in test: all pass; no new lint warning.
- `OOO_IQ` and `OOO_CORE` changed (a 2:1 select on port 1's write, the slot rule moved): `synth_ooo.bat OOO_IQ` would
  measure the queue.

---

## 6. What G1 measures

| Item | Criterion | Reference |
|---|---|---|
| Correctness | riscv-arch-test (the suites of B4) and CoreMark in lock-step with Spike, no mismatch | `SIM/LOCKSTEP` |
| Performance | CoreMark/MHz in RTL simulation within ±5 % of the model for each build: 6.243 (g14 -O2), 6.680 (g14 sf + -flto), 6.066 (g13 -O2) | `Plan/model/results/g0b.txt` (L7, D-15, D-16 variant A) |
| Where the cycles go | the model's counters for the same runs (dispatch held by the front end, the IQ, LQ / SQ; mispredictions; overrides) from the RTL's | to explain a difference above 2 % |
| Size | `OOO_CORE` out of context in Vivado (physical LUTs): the out-of-order engine within its budget row (`Doc/UARCH.md` 4.4), and the core's total against the gap (3.5k / 4.9k / 6.2k now) | out of context is fair for a whole core (`Plan/OOC.md` 25.3) |
| Timing | 50 MHz (20 ns) after place and route out of context | the blocks' slack so far: worst +0.569 ns (the CSR unit), +0.820 ns (the LSU with the D$) |

At G1 the reserve levers (L10, B4 / B5 of `Doc/UARCH.md` 6.3) are decided against the measured core.
