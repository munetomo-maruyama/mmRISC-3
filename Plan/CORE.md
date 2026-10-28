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
| `OOO_FTQ` | 1 | 8 blocks, 312 bits of front-end state each (TAGE 270, RAS 42) (13, 21) |
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
- `cut` from decode ends the group before a rare class (slot 0 only) and goes to FBUF and FUSE as `valid & ~cut`.

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

## 4. Decisions to make on the way (recommendations)

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
| B4 | riscv-arch-test: I, M, C, Zba / Zbb / Zbc / Zbs, Zicond, Zicsr, privileged M (CSRs, traps, MRET, FENCE.I) | lock-step and the suite's signatures | all pass (the ones mmRISC-2 also fails excepted) |
| B5 | Fusion on, kind by kind; the MDU and PMUL; interrupts (a timer model) | lock-step (`rd_skip` for first halves) | B4 again with fusion on |
| B6 | CoreMark (the three builds of `Plan/trace`) with the real caches | its cycles against the model | within ±5 % of the model (G1) |
| B7 | `OOO_CORE` out of context in Vivado | `synth_ooo.tcl` | the LUTs and 50 MHz (G1) |

- Each step keeps the unit tests (`SIM/OOO_UNIT/run.sh`) and the bug injection green; the core gets its own bug
  injection (the lock-step must catch a mutation of the glue) from B2 on.

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
