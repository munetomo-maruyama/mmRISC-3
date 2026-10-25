# mmRISC-3 micro-architecture specification (G0)

- Date: 2026-10-24
- Status: the G0 specification of `STRATEGY.md` section 7 (step 5 of `Plan/ISSUES.md` section 5): the
  micro-architecture of Phase 1 frozen, the predicted CoreMark/MHz and the LUT budget in numbers. **Passed with a
  condition on 2026-10-24** (the author's decisions in section 9; the budget is decided at G0b).
- Basis: the cycle model (`Plan/MODEL.md`, `Plan/model/g0.sh` → `Plan/model/results/g0.txt`), the RTL blocks and
  their Vivado runs (`Plan/OOC.md`), mmRISC-2 Rev.02 measured by hierarchy (`Plan/ISSUES.md` section 2), the reduction
  options (`Plan/REDUCE.md`).

---

## 1. Summary

1. **Performance: the goals are met with margin.** The G0 configuration gives **6.56 CoreMark/MHz with `-O2` and 6.80
   with the most optimization** (goals 5.0 and above 6.0). With a pessimistic pipeline (one more stage in each part
   and 3-cycle load-use, all at once) it still gives 5.85 / 6.14.
2. **The micro-architecture is frozen** (section 3): 2-wide out-of-order, 4-wide decode with fusion (at most 2 sources
   and 1 write per pair), uBTB 16 + TAGE-S, ROB 24, issue queue 12, 64 physical registers (3 writes / 6 reads), 2 ALU
   ports of two chained stages, 1 LSU with LQ / SQ 12, 6 checkpoints. Against the configuration before G0 the
   changes (ROB 32 → 24, issue queue 16 → 12, checkpoints 8 → 6) cost −0.4 % / −0.6 % and save about 1k LUTs.
3. **The budget does not close yet.** The blocks measured in Vivado (15.3k LUTs; about 14.0k with the G0 changes) and
   the blocks not yet written (front end, decode, ROB, LSU and the rest: estimated 9.3k to 14.5k) need **23.3k to
   28.5k**. The room for them is **16.4k to 17.9k** (52k ceiling, mmRISC-2's other blocks, group A of `REDUCE.md`).
   **The gap is 5.4k to 12.1k, about 8.8k in the middle.**
4. **D3 (FPU): the premise was wrong.** In mmRISC-2 the multi-cycle FPU (`CORE_FPU`, 9,757 LUTs) was larger than the
   pipelined one (`FPU_PIPE`, 9,060), because it also produced every partial product at once. "Back to multi-cycle
   frees several k LUTs" has no basis. The FPU levers are its breakdown (C1) and then sharing the multiplier (C2) and
   moving the rare operations to a small iterative unit (C3): 1.5k to 3k, to be measured.
5. **Closing the gap** (section 6): without touching fusion, Ethernet or the ceiling, the listed levers give about
   3.6k to 4.8k (the FPU part measured by C1 on 2026-10-25) (Linux-side options, the FPU, three small structures at −0.3 to −0.7 % each, an asymmetric ALU). That
   closes the low end of the estimate, not the middle. The remaining choices are fusion level 2 (−3.4 % / −0.7 %,
   about −1.2k), a 54k ceiling (+2k, a timing risk) and, last, no fusion (−7.8 % / −4.3 %) or no Ethernet.
6. **G0 verdict (proposed): a conditional pass.** The performance and the micro-architecture are fixed; the budget is
   checked again at **G0b**, once the front end, decode, ROB and LSU are written and measured, which is the first
   step of Phase 1 anyway. The FPU breakdown (C1) is measured in parallel by the author. The levers are applied in
   the order of section 6.

---

## 2. Goals and predicted performance

The goals (`STRATEGY.md` D1): 5.0 CoreMark/MHz with `-O2` (Zba / Zbb / Zbs / Zicond, GCC 14.2), above 6.0 with the
most optimization (sf + `-flto`). From `Plan/model/results/g0.txt`:

| Configuration | `-O2` | Most optimization | mmRISC-2's condition (g13 -O2 zb) |
|---|---|---|---|
| Before G0 (ROB 32, issue queue 16, 8 checkpoints) | 6.59 | 6.84 | 6.36 |
| **G0** | **6.56** | **6.80** | 6.35 |
| G0, pessimistic pipeline | 5.85 | 6.14 | 5.69 |
| G0 + the three small-loss levers (6.2) | 6.45 | 6.75 | 6.28 |
| G0 + the three, pessimistic | 5.65 | 5.97 | 5.53 |
| G0 without ALU + ALU (fusion 2) | 6.34 | 6.75 | 6.16 |
| G0 without fusion (2-wide decode) | 6.05 | 6.51 | 5.90 |
| G0 without fusion, pessimistic | 5.51 | 5.97 | 5.40 |
| G0 + 2 writes per pair (W5, the first to buy back) | 6.87 | 7.40 | 6.64 |

- Every row meets the `-O2` goal. The most-optimization goal (above 6.0) is missed only by the pessimistic rows
  without ALU + ALU margin (5.97). **So fusion is what keeps the "above 6.0" goal safe against a slower pipeline.**
- What must hold (each alone, from G0): 2-cycle load-use (3 cycles: −7.9 %), TAGE-S (gshare: −14.5 %), forwarding
  from the SQ (−4.3 %, `MODEL.md`), one stage from issue to EX (one more: −1.1 %).
- The model's limits (`MODEL.md` 6.5) apply: no wrong-path effects, an idealized LSU replay. G1 checks the RTL against
  the model within ±5 %.

---

## 3. The frozen micro-architecture

### 3.1 Pipeline

| Stage | Work |
|---|---|
| F0 | Next fetch address: uBTB (16 entries, partial tags) in one cycle; redirects from F2 and from the back end win |
| F1 | I$ read (block RAM), TAGE-S and BTB read (block RAM) |
| F2 | I$ way select, predecode (RVC boundaries, the targets of branches and jal), override by TAGE-S / BTB / RAS (a disagreement redirects F0, 2 cycles lost); 16 bytes into the fetch buffer (`OOO_FETCH`, `Plan/OOC.md` 14) |
| D1 | Up to 4 instructions out of the fetch buffer (a window of 8 parcels), RVC expansion, decode |
| D2 | Fusion (4 instructions → 2 µops), renaming (RAT, free list, busy bits, checkpoints) |
| DS | Dispatch: issue queue, ROB, LQ / SQ, payload |
| IS | Wakeup-select (one cycle with the wakeup of latency 1) |
| RR | Register-file read (6 ports) |
| EX | Bypass and the two chained ALU stages / address calculation / branch resolution |
| (M) | Loads: D$ access, result 2 cycles after issue to the dependents (hit speculated) |
| WB, CM | Register-file write (3 ports); commit 2 µops a cycle from the ROB head |

A misprediction costs 9 cycles from EX to EX. The model is the reference for the timing (`fe_depth` 3, `dec_depth`
2, `iss_to_ex` 2, `redirect` 1, `override_at` 2).

### 3.2 Front end

| Item | Specification |
|---|---|
| Fetch | 16 bytes a cycle (aligned), the next block after a taken transfer |
| Fetch buffer | `OOO_FBUF`: 4 whole 16-byte blocks in LUTRAM (decided at step 2 instead of a ring of 16 parcels, `Plan/OOC.md` 13.1); a window of 8 parcels over the head block and the next; up to 4 instructions a cycle out to decode; 32-bit instructions across blocks handled in the window |
| uBTB | `OOO_UBTB`: 16 entries, fully associative, 12-bit partial tags, the first taken hit of the block in parallel, round-robin replacement, returns from the RAS top |
| TAGE-S | `OOO_TAGE`: per fetch block, as it can be built in block RAM (decided at step 2, `Plan/OOC.md` 14.1): 4 tagged tables of 1024 rows indexed by the fetch address and the history, each row with 3 direction counters for the 1st, 2nd and 3rd conditional branch of the block; base table of 2-bit counters per parcel; one history bit per slot branch. A 4th branch in a block is predicted not taken (none in CoreMark). Updated at commit through the FTQ. Against the model's TAGE per branch: about −0.2 % / −0.5 % |
| BTB, RAS | `OOO_BTB`: for indirect jumps only (256 rows in block RAM, read with the fetch address); the targets of branches and jal come from predecode (`OOO_PREDEC`), those of returns from the RAS. `OOO_RAS`: 16 entries in LUTRAM; each block keeps the pointer and the entry a push would overwrite, for recovery |
| FTQ | `OOO_FTQ`: 8 entries, one per fetch block: PC, next address and prediction state for the update and the recovery (LUTRAM). The front end needs 312 bits of state a block (TAGE 270, RAS 42), and the outcomes of the slot branches for the update at commit: the FTQ grows at the core's assembly (`Plan/OOC.md` 14.2) |

### 3.3 Decode and fusion

| Item | Specification |
|---|---|
| Width | 4 instructions decoded, 2 µops out per cycle |
| Fusion | `OOO_FUSE` LEVEL 3: lui + addi, auipc + x, slli + srli, ALU + load (address), load / store pairs, ALU + branch, ALU + ALU (chained). Greedy from the oldest slot, adjacent instructions in program order |
| Limits | A pair reads at most 2 registers (`SRC2`) and writes at most 1 (`W1`); the second half of ALU + ALU is an operation of the narrowed second stage (`alu2ok` from the decoder) |
| Off | `no_fuse`: single-step, armed triggers, the refetch after an exception in a pair (3.8) |

### 3.4 Renaming

`OOO_RENAME`: 2 µops a cycle, 2 sources and 1 destination each, 64 physical registers (6-bit tags), RAT in
flip-flops, a free list of 32, busy bits cleared by the 3 write-back ports, in-group dependences, 6 checkpoints
(copied a cycle late from the RAT, `Plan/OOC.md` 10.1). A checkpoint is taken for a µop with a conditional branch or
a jalr (a jal cannot mispredict in the back end). Restoring a checkpoint needs at least 2 cycles after its renaming,
which the pipeline gives.

**Added 2026-10-25 (`Plan/OOC.md` 11.4)**: a full flush (exceptions, interrupts, serialization) goes back to the
committed state, which needs the RAT of the committed state (32 × 6 bits, written at commit) and the committed head of
the free list; renaming gets them (about 0.3k LUTs).

### 3.5 Dispatch, ROB and issue queue

| Item | Specification |
|---|---|
| ROB | 24 µops; payload in LUTRAM banked by the parity of the index (one write port each), done and exception bits in flip-flops; commit 2 a cycle |
| Issue queue | `OOO_IQ`: unified, 12 entries, 2 sources and 1 destination, oldest first (age matrix), 3 issues a cycle, 6 wakeup buses; payload in LUTRAM |
| Ports | P0: ALU0 + MUL / DIV; P1: ALU1; P2: LSU |
| **Dispatch rules** (the wakeup relies on them) | A latency-2 µop (multiply) is "ALU0 only"; an any-ALU µop has latency 1; an LSU µop writes a register only as a load |
| Physical registers | `OOO_PRF`: 64 × 64, 3 writes / 6 reads, LUTRAM per write bank + LVT |

### 3.6 Execution

| Item | Specification |
|---|---|
| ALU ports | `OOO_ALU2` on P0 and P1: a full `OOO_ALU` (RV64I, Zba, Zbb, Zbs, Zicond; one adder and one shifter shared) and a narrowed one in series (add / sub, sh*add, logic, srl, extensions, czero, bext), plus the branch comparison (alone, or on the first result) |
| Sources | 2 per µop (the third source input of `OOO_ALU2` goes in Phase 1: the second stage takes res1, s1, s2 or imm2) |
| Bypass | In front of the ALUs in EX: the register file, the own result, the other ALU port, the load |
| MUL / DIV | mmRISC-2's CORE_MDU behind P0 (multiply in DSP blocks, latency 2; divide iterative, woken from outside) |
| Branches | Target adders beside the ALUs; a misprediction restores a checkpoint and redirects F0 |
| FPU | mmRISC-2's FPU_PIPE (D3: pipelined at first), behind its own port, flushed by ROB tag (`REDUCE.md` E4) |

### 3.7 LSU and memory

| Item | Specification |
|---|---|
| LSU | 1 load or store a cycle; load-use 2 cycles with hit speculation, a replay on a miss |
| Ordering | Conservative memory dependence: a load issues only when the addresses of all older stores are known (no loss in the model) |
| LQ / SQ | 12 / 12; forwarding from the SQ (same address and size); stores write the D$ after commit |
| D$ | mmRISC-2's (non-blocking, 2 MSHRs) behind an adapter with tagged requests and responses |
| Misaligned | Trap, as in mmRISC-2 |
| Block | `OOO_LSU` (2026-10-25, `Plan/OOC.md` 11): LQ / SQ, forwarding, `lsu_st_known` for the issue queue, `ld_cancel` for a load that misses its expected cycle, late results, `dc_kill` for the D$ adapter |
| **Open: holding back dependents** | The dependents of a load are woken before its result is known (2-cycle load-use). When it cannot give its result (a miss, a wait), the dependents already woken must be held back; candidate: the issue queue cancels speculative wakeups and keeps the entries of µops issued in the shadow until confirmed. Decided before the core is put together |

### 3.8 Commit, exceptions and fused pairs

- Exceptions and interrupts are taken at the ROB head, between µops. A pair commits as one µop and counts 2 in
  `minstret` and the PMU.
- **An exception inside a fused pair** (for example a page fault of the load of ALU + load): the pair is thrown away
  and fetched again with fusion off for that group, so the two instructions run one at a time and `mepc` / `mtval`
  and the registers are exact (with one write per pair, the first half's result may never have been written).
- Debug halts and single steps are taken at commit; no fusion while single-stepping or with triggers armed.

### 3.9 What runs only at the ROB head (non-speculative list)

| Kind | Handling |
|---|---|
| CSR instructions (including `fcsr`, `satp`, counters) | Serialized at the head; younger µops wait |
| ECALL, EBREAK, MRET, SRET, WFI | At the head |
| FENCE, FENCE.I, SFENCE.VMA | At the head; FENCE.I and SFENCE.VMA flush the front end |
| AMO, LR, SC | At the head, with the store queue drained |
| Loads from non-cacheable memory (MMIO) | Known after translation; held until the head, then performed |
| Stores | To the D$ (or MMIO) only after commit |
| Page-table walks | May run speculatively: A / D bits are not written by hardware (Svade, as in mmRISC-2) |
| `fflags` | Accumulated at commit |
| Interrupts, debug requests | At a µop boundary at the head |

### 3.10 Reused from mmRISC-2

L1 / L2 caches (D$ with the adapter), MMU (TLBs, PTW, PMP), CSR, debug (Sdtrig, debug module), MDU, FPU_PIPE, LiteX
integration, SIM_BIOS, the bug-injection method. Group A of `REDUCE.md` is applied as these blocks are brought over.

---

## 4. Resource budget

### 4.1 How it is counted

Physical LUTs (the "Total LUTs" of Vivado's hierarchical report, LUT RAM included), the unit of mmRISC-2's
measurement. "Measured" is Vivado out of context (`Plan/OOC.md`) or mmRISC-2's placed design; "estimate" is from the
structure, with the basis given. The ceiling is about 52k LUTs (80 to 82 % of 63,400; mmRISC-2 was at 79 % with 93 %
of the slices).

### 4.2 The whole chip

| Part | LUT | Basis |
|---|---|---|
| LiteX SoC (with Ethernet) | 4,826 | mmRISC-2 measured |
| Outside the core: L1 caches 8,217, L2 1,256, debug 1,234, MMIO 1,096, DMA 620, arbiter 144 | 12,567 | mmRISC-2 measured |
| Core blocks kept: CSR 4,750, MMU 4,190, MDU 3,423, FPU 8,815, FP registers 544 | 21,722 | mmRISC-2 measured |
| **Room for the out-of-order engine** under 52k | **12.9k** | 52k − 39.1k |
| + group A of `REDUCE.md` (triggers, PMP, D$ buffers, TLBs, CSRs in LUTRAM) | **16.4k to 17.9k** | 3.5k to 5k, partly measured |

### 4.3 The out-of-order engine

| Block | LUT | Basis |
|---|---|---|
| ALUs, 2 ports (`OOC_ALU2` × 2) | 6,266 → **about 5.9k** | Measured; about −0.2k a port without the third source |
| Issue queue (`OOO_IQ`) | 3,143 → **about 2.45k** | Measured at 16 entries; about 0.78 × at 12 |
| Renaming (`OOC_RENAME`) | 2,267 → **about 2.0k** | Measured with 8 checkpoints; 6 checkpoints |
| Register file (`OOC_PRF`, 64, 3 / 6) | 2,503 | Measured |
| uBTB (`OOO_UBTB`) | 910 | Measured |
| Fusion (`OOC_FUSE`) | 215 | Measured |
| **Measured blocks** | 15,304 → **about 14.0k** | |
| Fetch: PC generation, FTQ, I$ interface, predecode, fetch buffer, 4 instructions out | 2.0k to 2.8k | mmRISC-2's IFU without its BTB is 2,893 for a narrower fetch; the buffer (8 parcels in at any place, 4 instructions out at variable places) about 1.3k to 1.8k. **2026-10-25: measured in Vivado, `OOO_FBUF` 940 LUTs (+3.541 ns after its loop was shortened) and `OOO_FTQ` 148, about 1.09k together (`Plan/OOC.md` 13.6, 13.7)** |
| TAGE-S logic (tables in block RAM) | 0.8k to 1.5k | Folded histories, tag compares, provider / alternate choice, update and allocation through the FTQ. **2026-10-25: `OOO_TAGE` written; in Vivado with the front end (`OOC_FRONT`, `Plan/OOC.md` 14.4)** |
| BTB (block RAM) and RAS 16 | 0.4k to 0.7k | Tag compare and target; RAS in LUTRAM. **2026-10-25: `OOO_BTB` (indirect jumps only) and `OOO_RAS` written; the direct targets are predecode's 8 adders, in the fetch row** |
| Decode × 4 and RVC × 4 | 1.0k to 1.6k | mmRISC-2's CORE_DEC 278 and CORE_DECOMP 78 each; `REDUCE.md` E2 |
| ROB 24 | 0.7k to 1.2k | Payload in LUTRAM (two banks), status in flip-flops, commit 2 a cycle, flush. **2026-10-25: `OOO_ROB` written; Vivado first gave 5,173 LUTs with the payload in flip-flops (two write statements per bank), fixed to one write per bank: 1,073 LUTs (160 LUTRAM), +11.060 ns (`Plan/OOC.md` 12.7)** |
| Issue-queue payload | 0.4k to 0.7k | LUTRAM, 2 writes / 3 reads (two banks + LVT) |
| LSU: address calculation, alignment, LQ 12, SQ 12 with forwarding, D$ adapter, hit speculation and replay | 2.5k to 3.5k | mmRISC-2's CORE_LSU is 946 (alignment); the SQ's address compares and data select; the adapter. **2026-10-25: `OOO_LSU` without the adapter measured in Vivado, 2,969 LUTs, +6.265 ns (`Plan/OOC.md` 11.8)** |
| Dispatch, branch resolution, redirects, commit and exceptions, the ports to CSR / MDU / FPU / MMU | 1.5k to 2.5k | mmRISC-2's pipeline itself is 2,511 |
| **Not yet written** | **9.3k to 14.5k** | Estimates |
| **The out-of-order engine** | **23.3k to 28.5k** | |

### 4.4 The gap

| | Low | Middle | High |
|---|---|---|---|
| Needed | 23.3k | 25.9k | 28.5k |
| Room (with group A) | 17.9k | 17.1k | 16.4k |
| **Over** | **5.4k** | **8.8k** | **12.1k** |
| Needed, 2026-10-25 (LSU measured 2,969 + adapter 0.3k to 0.6k; committed-state RAT 0.3k, 3.4) | 24.4k | 26.6k | 28.9k |
| **Over, 2026-10-25** | **6.5k** | **9.5k** | **12.5k** |
| Needed, 2026-10-25 later (ROB measured 1,073; renaming with its committed state measured 2,624, 8 checkpoints) | 25.1k | 27.1k | 29.1k |
| **Over, 2026-10-25 later** | **7.2k** | **9.9k** | **12.7k** |

The whole design would be about 61k LUTs in the middle (96 % of the device). The uncertainty of the blocks not yet
written (±2.6k) is as large as most levers, so it is measured first (section 8).

Block RAM and DSP are not the limit: 26.5 tiles are free, TAGE-S and the BTB need about 4 to 6, so the L2 stays at
256 KB (D-2); 32 of 240 DSPs are used.

---

## 5. D3: the FPU

- The author's decision (2026-10-24): start with the pipelined FPU (mmRISC-2's FPU_PIPE, 8,815 LUTs in the SoC),
  reconsidered depending on the logic size.
- **What the reconsideration found**: mmRISC-2 measured both FPUs alone (`CPU_FPU/README.md` section 4, 2026-10-09):
  the multi-cycle `CORE_FPU` 9,757 LUTs, the pipelined `FPU_PIPE` 9,060. The multi-cycle one produced every partial
  product in one cycle as well, and its state machine's multiplexers disappeared when it was pipelined. **Going back
  to the multi-cycle FPU frees nothing; it costs 0.7k.** The "several k" of the earlier recommendation assumed a narrow
  iterative FPU that does not exist.
- What remains (group C of `REDUCE.md`), measured before deciding:

| # | Option | LUT | Content |
|---|---|---|---|
| C1 | The FPU's breakdown | — | OOC synthesis of FPU_PIPE split into multiply, add, alignment, normalization, rounding (963 measured), conversion, divide / square root. **The author's Vivado run, now** |
| C2 | One multiplier for the MDU and the FPU | 0.5k to 1k (and 16 DSPs); **measured by C1: about 0.3k** (the multiply is mostly DSPs) | MUL / DIV and the FPU on the same issue port; multiply throughput drops (30 multiplies per 1000 instructions in CoreMark) |
| C3 | FMA / add / multiply pipelined; conversions, compares, sign operations, classification in a small iterative unit | 1k to 2k; **measured by C1: about 0.7k to 0.9k** (P2 862 and the conversion's second half 340 replaced) | Depends on C1; slower rare floating-point operations, no effect on CoreMark |
| C4 | A new narrow iterative FPU | several k | A new design and new verification; floating-point performance drops a lot. Not recommended |

- **Recommendation**: keep FPU_PIPE as the base (it is verified and Linux runs on it); do C1 now; take C2 and C3 at
  G0b if the gap is still there.

---

## 6. Closing the gap

### 6.1 Already in the G0 configuration (in the 14.0k)

| Change | LUT | `-O2` | Most optimization |
|---|---|---|---|
| Issue queue 16 → 12 | about −0.7k | −0.0 % | −0.2 % |
| ROB 32 → 24 | about −0.1k to −0.2k | −0.0 % | −0.2 % |
| Checkpoints 8 → 6 | about −0.25k | −0.3 % | −0.5 % |
| No third source in `OOO_ALU2` and its bypass | about −0.4k | 0 | 0 |

### 6.2 Levers, in the recommended order

| # | Lever | LUT | `-O2` | Most optimization | What is lost |
|---|---|---|---|---|---|
| L1 | HPM counters 4 → 2 (`REDUCE.md` B1) | −0.65k | 0 | 0 | `perf` counts 2 events at once |
| ~~L2~~ | ~~No Zbc (B2)~~ | — | | | **Not taken (author, 2026-10-24): the instruction set is kept** |
| L3 | FPU C2 + C3 (after C1) | −1.0k to −1.3k (C1 measured 2026-10-25: C2 about 0.3k, C3 about 0.7k to 0.9k; `Plan/OOC.md` 11.6) | 0 | 0 | Rare floating-point operations slower |
| L4 | LQ / SQ 12 → 8 | −0.4k to −0.6k | −0.7 % | −0.5 % | |
| L5 | uBTB 16 → 8 | about −0.4k | −0.6 % | −0.1 % | |
| L6 | Fetch buffer 16 → 8 | about −0.3k | −0.3 % | −0.1 % | |
| L7 | Asymmetric ALUs (`REDUCE.md` E3: ALU1 with a simple first stage) | −0.7k to −1.0k | to be modelled | | The model needs the operation class per instruction first |
| L8 | Unneeded LiteX peripherals (D1) | −0.2k to −0.5k | 0 | 0 | |
| | **L1, L3 to L8** | **−3.6k to −4.8k** | about −1.8 % | about −0.7 % | (L7 not included in the performance; L3 from C1) |
| L9 | Fusion level 2 (no ALU + ALU; ALU + branch and 4-wide decode stay) | about −1.2k | −3.4 % | −0.7 % | The second ALU stages go |
| L10 | Ceiling 52k → 54k | +2k of room | 0 | 0 | Timing and slice congestion; needs an early whole-chip trial |
| L11 | No fusion (2-wide decode) | −2.5k to −3k | −7.8 % | −4.3 % | Pessimistic most optimization 5.97, below 6.0 |
| L12 | No Ethernet | to be measured | 0 | 0 | Against the author's decision D5 |
| (buy back) | 2 writes per pair (W5) | +3.4k | +4.6 % | +8.8 % | Only if room is left |

- Per 1k LUTs, fusion (L11) is worth about 3 % with `-O2`, more than most of the small levers; that is why it comes
  last.
- **Middle of the estimate (8.8k over)**: L1 and L3 to L8 (about 4.2k) + L9 (1.2k) leave about 3.4k, which needs
  L10 and more. **Low end (5.4k)**: L1 and L3 to L8 with L9 nearly close it. **High end (12.1k)**: even L1 to L11 fall short, and the FPU or
  Ethernet has to be reconsidered.

---

## 7. Verification

| Item | Specification |
|---|---|
| Lock-step | Every commit compared with Spike (1.1.1-dev, installed): PC, register written and value, CSR effects, exceptions. A commit-trace port in the style of RVFI (simulation only) |
| Fused pairs | Reported as 2 instructions; when the first half's result is not written (one write per pair), only its PC is compared and the register is compared after the second half |
| Unit level | The Phase 0 unit tests and bug injection (`SIM/OOO_UNIT`, 39 mutations) carry over and grow with each block |
| Core level | **riscv-arch-test** (the author's instruction, 2026-10-25: the instruction tests from now on), random instruction streams, exception injection, bug injection into renaming and the LSQ. The riscv-tests of mmRISC-2 served only the self-test of the lock-step checker |
| Performance | CoreMark in simulation against the cycle model (G1: within ±5 %); Konata pipeline views |
| Spike's support | Sstc, Zicboz, Smcntrpmf, Sdtrig, PMP checked before Phase 2 |

---

## 8. G0 verdict and the next steps

**Proposed verdict: conditional pass.**

- Passed: the predicted performance (6.56 / 6.80, every lever row above the `-O2` goal), the micro-architecture
  (section 3), the loops that must close in one cycle (two ALU stages +0.51 ns, wakeup-select +5.07 ns, uBTB +5.10 ns,
  renaming +8.91 ns, all in Vivado).
- Open: the budget (5.4k to 12.1k over). **G0b**, a budget gate inside Phase 1, decides it once the blocks not yet
  written have Vivado numbers.

| Step | Work | Who |
|---|---|---|
| 1 | The lock-step framework (Spike at commit, commit-trace port) | Claude Code. **Done 2026-10-25: `SIM/LOCKSTEP`** (175 riscv-tests and CoreMark; all 3,520 injected mismatches caught) |
| 2 | RTL of the front end, decode, ROB, LSU (with their unit tests and bug injection), each out of context in Vivado | Claude Code, Vivado by the author |
| 2' | FPU breakdown (C1), in parallel | The author's Vivado |
| 2'' | The model gets the operation class per instruction, for L7 (asymmetric ALUs) | Claude Code |
| 3 | **G0b**: the budget table with measured blocks; the levers of section 6 applied in order | Claude Code proposes, the author decides |
| 4 | Integration of the core (M-mode, bare metal), riscv-tests, CoreMark against the model | Claude Code |
| 5 | **G1**: CoreMark in simulation within ±5 % of the model; the core alone in Vivado for LUTs and 50 MHz | |

---

## 9. Decisions for the author

Decided by the author on 2026-10-24 (`Doc/PROMPT.md` entry 23): **Zbc stays, and as a principle the instruction set
is kept** (that of mmRISC-2 Rev.02); everything else as recommended.

| # | Item | Recommendation | **Decision (2026-10-24)** |
|---|---|---|---|
| D-7 | The G0 verdict | Conditional pass; the budget decided at G0b (section 8) | As recommended: **G0 passed with the condition; Phase 1 starts** |
| D-8 | Linux-side reductions L1 and L2 (2 HPM counters, no Zbc) | Take them (no effect on CoreMark) | **L1 taken; L2 not taken** (Zbc stays) |
| D-9 | FPU (D3 reconsidered) | Keep FPU_PIPE; C1 now; C2 and C3 at G0b if needed. Not the multi-cycle FPU (it is larger) | As recommended (C2 / C3 keep the instruction set) |
| D-10 | The order of the levers when the gap remains | L3 → L4 to L6 → L7 → L9 → L10 → L11 / L12 (section 6.2) | As recommended; no lever may remove instructions |
| D-2 | L2 size | Keep 256 KB (block RAM is not the limit) | As recommended |
