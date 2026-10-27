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
7. **G0b (2026-10-26, decided as recommended, 6.3)**: with every block but the control measured, the gap is 10.1k / 11.5k / 12.8k.
   New levers were found (checkpoints back to 6, the replay trap at commit making a 10-entry issue queue free, rare
   classes decoded in one slot) and every lever was modelled. Recommended: the levers that lose nothing (3.1k), the
   trap with 10 entries (1.9k, +0.2 %), L4 to L6 (1.2k), L7 if it models well, fusion level 2, and the 54k ceiling with
   no PMP / HPM as a reserve decided at G1: about +0.25k of margin in the middle, CoreMark 6.25 / 6.70.

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
| F0 | Next fetch address: uBTB (8 entries since G0b L5, partial tags) in one cycle; redirects from F2 and from the back end win |
| F1 | I$ read (block RAM), TAGE-S and BTB read (block RAM) |
| F2 | I$ way select, predecode (RVC boundaries, the targets of branches and jal), override by TAGE-S / BTB / RAS (a disagreement redirects F0, 2 cycles lost); 16 bytes into the fetch buffer (`OOO_FETCH`, `Plan/OOC.md` 14) |
| D1 | Up to 4 instructions out of the fetch buffer (a window of 8 parcels), RVC expansion, decode |
| D2 | Fusion (4 instructions → 2 µops), renaming (RAT, free list, busy bits, checkpoints) |
| DS | Dispatch: issue queue, ROB, LQ / SQ, payload |
| IS | Wakeup-select (one cycle with the wakeup of latency 1) |
| RR | Register-file read (6 ports) |
| EX | Bypass and the ALU with the branch comparison after it (fusion level 2, 6.7) / address calculation / branch resolution |
| (M) | Loads: D$ access, result 2 cycles after issue to the dependents (hit speculated) |
| WB, CM | Register-file write (3 ports); commit 2 µops a cycle from the ROB head |

A misprediction costs 9 cycles from EX to EX. The model is the reference for the timing (`fe_depth` 3, `dec_depth`
2, `iss_to_ex` 2, `redirect` 1, `override_at` 2).

### 3.2 Front end

| Item | Specification |
|---|---|
| Fetch | 16 bytes a cycle (aligned), the next block after a taken transfer |
| Fetch buffer | `OOO_FBUF`: 4 whole 16-byte blocks in LUTRAM (decided at step 2 instead of a ring of 16 parcels, `Plan/OOC.md` 13.1; G0b's L6, 2 blocks, was measured no smaller and taken back, 6.10); a window of 8 parcels over the head block and the next; up to 4 instructions a cycle out to decode; 32-bit instructions across blocks handled in the window |
| uBTB | `OOO_UBTB`: **8 entries** (G0b L5; 16 before), fully associative, 12-bit partial tags, the first taken hit of the block in parallel, round-robin replacement, returns from the RAS top |
| TAGE-S | `OOO_TAGE`: per fetch block, as it can be built in block RAM (decided at step 2, `Plan/OOC.md` 14.1): 4 tagged tables of 1024 rows indexed by the fetch address and the history, each row with 3 direction counters for the 1st, 2nd and 3rd conditional branch of the block; base table of 2-bit counters per parcel; one history bit per slot branch. A 4th branch in a block is predicted not taken (none in CoreMark). Updated at commit through the FTQ. Against the model's TAGE per branch: about −0.2 % / −0.5 % |
| BTB, RAS | `OOO_BTB`: for indirect jumps only (256 rows in block RAM, read with the fetch address); the targets of branches and jal come from predecode (`OOO_PREDEC`), those of returns from the RAS. `OOO_RAS`: 16 entries in LUTRAM; each block keeps the pointer and the entry a push would overwrite, for recovery |
| FTQ | `OOO_FTQ`: 8 entries, one per fetch block: PC, next address and prediction state for the update and the recovery (LUTRAM). The front end needs 312 bits of state a block (TAGE 270, RAS 42), and the outcomes of the slot branches for the update at commit: the FTQ grows at the core's assembly (`Plan/OOC.md` 14.2) |

### 3.3 Decode and fusion

| Item | Specification |
|---|---|
| Width | 4 instructions decoded, 2 µops out per cycle |
| Decoder | `OOO_DEC`: per slot mmRISC-2's `CORE_DECOMP` + `CORE_DEC` taken without change (`RTL/CPU/CORE`), and the fields fusion, the issue queue and the ROB need (`Plan/OOC.md` 16) |
| Fusion | `OOO_FUSE` **LEVEL 2** (G0b D-14, 6.7; ALU + ALU given up): lui + addi, auipc + x, slli + srli, ALU + load (address), load / store pairs, ALU + branch. Greedy from the oldest slot, adjacent instructions in program order |
| Limits | A pair reads at most 2 registers (`SRC2`) and writes at most 1 (`W1`); so the other operand of a fused branch is one of the two (or x0) |
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
| Issue queue | `OOO_IQ`: unified, **10 entries** (G0b D-12, 6.5), 2 sources and 1 destination, oldest first (age matrix), 3 issues a cycle, 6 wakeup buses, entries freed at issue (a load that misses is replayed after commit, 3.7); payload in LUTRAM (`OOO_IQPL`: two banks with one write port each and a live value table, written at DS to `disp_entry`, read in RR, `Plan/OOC.md` 17.1) |
| Ports | P0: ALU0 + MUL / DIV; P1: ALU1; P2: LSU |
| **Dispatch rules** (the wakeup relies on them) | A latency-2 µop (multiply) is "ALU0 only"; an any-ALU µop has latency 1; an LSU µop writes a register only as a load |
| Physical registers | `OOO_PRF`: 64 × 64, 3 writes / 6 reads, LUTRAM per write bank + LVT |

### 3.6 Execution

| Item | Specification |
|---|---|
| ALU ports | `OOO_ALU2` on P0 and P1: a full `OOO_ALU` (RV64I, Zba, Zbb, Zbs, Zicond; one adder and one shifter shared) and the branch comparison (alone, or fused on the ALU result against s1, s2 or zero); 2 sources, 2 bypassed (6.7) |
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
| LQ / SQ | **8 / 8** (G0b L4; 12 / 12 before); forwarding from the SQ (same address and size); stores write the D$ after commit |
| D$ | mmRISC-2's (non-blocking, 2 MSHRs) behind an adapter with tagged requests and responses (`OOO_DCAD`, `Plan/OOC.md` 17.2): the D$ gives a load hit in its stage 1 (`d_hit_now`, the one output added, also under a miss) for the LSU's M; other answers come in order and are given as fills by LQ entry; a newer request of an LQ entry drops its older answers (no stale value for a load tried again) |
| Misaligned | Trap, as in mmRISC-2 |
| Block | `OOO_LSU` (2026-10-25, `Plan/OOC.md` 11): LQ / SQ, forwarding, `lsu_st_known` for the issue queue, `ld_cancel` for a load that misses its expected cycle, late results, `dc_kill` for the D$ adapter (not needed by `OOO_DCAD`) |
| **Holding back dependents** (decided 2026-10-26, D-12, 6.5; the selective replay of `Plan/OOC.md` 15 before) | **Replay after commit**: a load that raises `ld_cancel` (a miss, a wait) completes later marked (`cmp_ld_rp`); the ROB commits it and empties, and the front end fetches from the next instruction (`replay`, `replay_pc`). What ran on the guess in between is thrown away; the load itself runs once. No masks, no kept entries; the units need not drop anything. +0.2 % / +0.2 % in the model; every load that misses pays a refetch and the work under the miss (code that misses: Linux) |

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
| ALUs, 2 ports (`OOC_ALU2` × 2) | 6,266 → **about 5.9k** | Measured; about −0.2k a port without the third source. **2026-10-26: fusion level 2 (D-14), one ALU and 2 sources a port: 1,926 a port, 3,852 for two, +1.753 ns (6.8)** |
| Issue queue (`OOO_IQ`) | 3,143 → **about 2.45k** | Measured at 16 entries; about 0.78 × at 12. **2026-10-25: with the selective replay measured in Vivado, 4,974 LUTs at 16 entries (+1,831), +3.309 ns; about 3.9k at 12 (+1.4k) (`Plan/OOC.md` 15.5); after the reductions of 15.6, 4,977 LUTs, +2.857 ns (15.7): no change. 2026-10-26: 10 entries with replay after commit (D-12), 1,621 LUTs, +7.843 ns (6.6)** |
| Renaming (`OOC_RENAME`) | 2,267 → **about 2.0k** | Measured with 8 checkpoints; 6 checkpoints |
| Register file (`OOC_PRF`, 64, 3 / 6) | 2,503 | Measured |
| uBTB (`OOO_UBTB`) | 910 | Measured |
| Fusion (`OOC_FUSE`) | 215 | Measured |
| **Measured blocks** | 15,304 → **about 14.0k** | |
| Fetch: PC generation, FTQ, I$ interface, predecode, fetch buffer, 4 instructions out | 2.0k to 2.8k | mmRISC-2's IFU without its BTB is 2,893 for a narrower fetch; the buffer (8 parcels in at any place, 4 instructions out at variable places) about 1.3k to 1.8k. **2026-10-25: measured in Vivado, `OOO_FBUF` 940 LUTs (+3.541 ns after its loop was shortened) and `OOO_FTQ` 148, about 1.09k together (`Plan/OOC.md` 13.6, 13.7); PC generation, the I$ interface and predecode in `OOC_FRONT` (next rows)** |
| TAGE-S logic (tables in block RAM) | 0.8k to 1.5k | Folded histories, tag compares, provider / alternate choice, update and allocation through the FTQ. **2026-10-25: the whole front end with the uBTB (`OOC_FRONT`: uBTB, predecode, TAGE-S, BTB, RAS, fetch control) measured in Vivado, 3,076 LUTs, 5.5 BRAM tiles, +0.959 ns (`Plan/OOC.md` 14.6), at the bottom of its estimate of 3.0k to 4.8k** |
| BTB (block RAM) and RAS 16 | 0.4k to 0.7k | Tag compare and target; RAS in LUTRAM. **2026-10-25: `OOO_BTB` (indirect jumps only) and `OOO_RAS` written; the direct targets are predecode's 8 adders, in the fetch row** |
| Decode × 4 and RVC × 4 | 1.0k to 1.6k | mmRISC-2's CORE_DEC 278 and CORE_DECOMP 78 each; `REDUCE.md` E2. **2026-10-25: `OOO_DEC` measured in Vivado, 1,980 LUTs with every field (the FP and CSR ones too), +8.048 ns (`Plan/OOC.md` 16.4)** |
| ROB 24 | 0.7k to 1.2k | Payload in LUTRAM (two banks), status in flip-flops, commit 2 a cycle, flush. **2026-10-25: `OOO_ROB` written; Vivado first gave 5,173 LUTs with the payload in flip-flops (two write statements per bank), fixed to one write per bank: 1,073 LUTs (160 LUTRAM), +11.060 ns (`Plan/OOC.md` 12.7)** |
| Issue-queue payload | 0.4k to 0.7k | LUTRAM, 2 writes / 3 reads (two banks + LVT). **2026-10-26: `OOO_IQPL` (16 × 96 bits) measured in Vivado, 711 LUTs (384 LUT RAM), +12.237 ns (`Plan/OOC.md` 17.6)** |
| LSU: address calculation, alignment, LQ 12, SQ 12 with forwarding, D$ adapter, hit speculation and replay | 2.5k to 3.5k | mmRISC-2's CORE_LSU is 946 (alignment); the SQ's address compares and data select; the adapter. **2026-10-25: `OOO_LSU` without the adapter measured in Vivado, 2,969 LUTs, +6.265 ns (`Plan/OOC.md` 11.8); 2026-10-26: the adapter `OOO_DCAD` measured with the LSU and the D$ (`OOC_LSUDC`), 227 LUTs (70 LUT RAM); the three together close at +1.254 ns (`Plan/OOC.md` 17.6)** |
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
| Needed, 2026-10-25 evening (the front end measured: fetch buffer 940, FTQ 148, OOC_FRONT 3,076 less the uBTB already counted, + FTQ widened 0.15k to 0.25k, + I$ to 16 bytes 0.05k to 0.2k, in place of the fetch, TAGE-S, BTB and RAS rows) | 25.4k | 26.6k | 27.8k |
| **Over, 2026-10-25 evening** | **7.5k** | **9.5k** | **11.4k** |
| Needed, 2026-10-25 night (the issue queue with selective replay measured: 4,974 LUTs at 16 entries, about 3.9k at 12, +1.4k) | 26.8k | 28.0k | 29.2k |
| **Over, 2026-10-25 night** | **8.9k** | **10.9k** | **12.8k** |
| Needed, 2026-10-25 late (decode measured: 1,980 LUTs with every field, in place of 1.0k to 1.6k) | 27.8k | 28.7k | 29.6k |
| **Over, 2026-10-25 late** | **9.9k** | **11.6k** | **13.2k** |
| Needed, 2026-10-26 (the issue-queue payload measured 711 and the D$ adapter 227, in place of 0.4k to 0.7k and 0.3k to 0.6k) | 28.0k | 28.6k | 29.2k |
| **Over, 2026-10-26** | **10.1k** | **11.5k** | **12.8k** |
| Needed, 2026-10-26 later (G0b tier 1 in the RTL and D-12 measured, 6.6: issue queue 1,621 in place of about 3.9k, ROB 1,232, LSU 2,981, renaming 2,464, decode 1,808, payload 585) | 25.4k | 26.0k | 26.6k |
| **Over, 2026-10-26 later** | **7.5k** | **8.9k** | **10.2k** |
| Needed, 2026-10-26 night (D-14 measured, 6.8: two ALU ports 3,852 in place of about 5.9k, fusion 208, decode 1,791) | 23.3k | 23.9k | 24.5k |
| **Over, 2026-10-26 night** | **5.4k** | **6.8k** | **8.1k** |
| Needed, 2026-10-26 late night (L4 to L6 measured, 6.10: LSU 2,290, front end 2,588, fetch buffer 924, adapter 199) | 22.1k | 22.7k | 23.3k |
| **Over, 2026-10-26 late night** | **4.2k** | **5.6k** | **6.9k** |

The whole design would be about 61k LUTs in the middle (96 % of the device). The uncertainty of the blocks not yet
written (±2.6k) is as large as most levers, so it is measured first (section 8). With the front end measured, what is
left unwritten is decode, the issue-queue payload, the D$ adapter and the control (about ±1.4k). 2026-10-26: only the
control is left (1.5k to 2.5k, ±0.5k).

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

### 6.3 G0b: the levers against the measured gap (2026-10-26, decided as recommended)

The gap is **10.1k / 11.5k / 12.8k** (4.4) with every block but the control measured (1.5k to 2.5k left). The levers
of 6.2 no longer close the middle (L1, L3 to L8 about 4.2k, L9 1.2k, L10 2k), so the measured blocks were searched for
new ones, and every lever with an effect on performance was run in the model (`Plan/model/g0b.sh` →
`results/g0b.txt`; the base is the design as written, G0 with the entries kept until c + 3: **6.550 / 6.786**).

**Found while measuring**:
1. Renaming was measured with **8 checkpoints** (`OOC_RENAME`); G0 has 6. About −0.25k, already in G0's performance.
2. **With the replay trap at commit, the issue queue can have 10 entries at no cost.** The entries kept for open loads
   are what needs 12: 12 → 10 costs −1.9 % with them, nothing without them (6.566 against 6.564). Together about
   −1.9k: the selective replay measured +1.4k at 12 entries (`Plan/OOC.md` 15.5), and two entries fewer of the plain
   queue about −0.5k.
3. **Decode** is 495 LUTs a slot with every field (`Plan/OOC.md` 16.4). The rare classes (FP, CSR, system, AMO / LR /
   SC) decoded in slot 0 only (a group ends before such an instruction in another slot): about −0.4k to −0.7k. None
   of them is in CoreMark's loop.
4. **The payload** is 7.4 LUTs a bit and port 2 needs about half of the fields: −0.1k to −0.2k narrowed per port.

| # | Lever | LUT | `-O2` | Most optimization | What is lost | Decision |
|---|---|---|---|---|---|---|
| | **Tier 1: nothing lost** | | | | | |
| G1 | Checkpoints 8 → 6, as in G0 | −0.25k | 0 | 0 | | G0 |
| L1 | HPM counters 4 → 2 | −0.65k | 0 | 0 | `perf` counts 2 events at once | Taken (D-8) |
| L3 | FPU C2 + C3 | −1.0k to −1.3k | 0 | 0 | Rare floating-point operations slower | D-9: at G0b if needed |
| L8 | Unneeded LiteX peripherals | −0.2k to −0.5k | 0 | 0 | | |
| G2 | Rare classes decoded in slot 0 only | −0.4k to −0.7k | about 0 (none in the loop; not modelled) | about 0 | FP- and CSR-heavy code decodes fewer a cycle | |
| G3 | Payload narrowed per port | −0.1k to −0.2k | 0 | 0 | | |
| | Tier 1 together | **−2.6k to −3.6k (3.1k)** | 0 | 0 | | |
| | **Tier 2: small losses** | | | | | |
| G4 | Replay trap at commit + issue queue 10 | −1.7k to −2.1k (1.9k) | +0.2 % | +0.2 % | Every load that misses refetches what follows it (not in the model: CoreMark has 26 cold misses; code that misses pays) | The author (it reverses 15.1 of `Plan/OOC.md`) |
| L4–L6 | LQ / SQ 8, uBTB 8, fetch buffer 8 | −1.2k | −1.7 % | −0.5 % | | D-10 |
| L7 | Asymmetric ALUs | −0.7k to −1.0k | to be modelled | | | |
| | **Tier 3: choices** | | | | | |
| L9 | Fusion level 2 (no ALU + ALU) | −1.2k | −3.1 % (on tier 2) | −0.8 % | | |
| L10 | Ceiling 52k → 54k | +2k of room | 0 | 0 | Timing and slice congestion | |
| B4 + B5 | No PMP, no HPM counters (beyond A2 and L1) | −1.5k | 0 | 0 | M-mode protection; Linux `perf` | |
| L11 | No fusion, in place of L9 | −2.7k | −7.0 % (on tier 2) | −4.2 % | | |
| L12 | No Ethernet | to be measured | 0 | 0 | Against D5 | |

- **Measured and not recommended**: checkpoints 6 → 4 (−0.25k for −3.2 %), issue queue 8 (−2.2 % even with the
  trap), ROB 24 → 20 (−0.15k for −0.4 %).
- **Tiers 1 and 2 together: about 7.0k** (with L7). That leaves about **4.5k in the middle** (3.0k low, 5.8k high).

Two ways to close the rest (the levers at their middle values):

| End state | Adds | Levers in all | Margin (low / middle / high) | CoreMark/MHz `-O2` / most opt. (pessimistic) |
|---|---|---|---|---|
| **A: fusion level 2** | L9 + L10 + B4 + B5 | 11.75k | +1.65k / **+0.25k** / −1.05k | **6.25 / 6.70** (5.50 / 5.93) |
| B: no fusion | L11 + L10 | 11.75k | +1.65k / +0.25k / −1.05k | 5.99 / 6.47 (5.36 / 5.83) |

- Without L10, both are about 2k short in the middle. The high end is not closed by either.
- The `-O2` goal (5.0) is met with margin by both, even pessimistic. The "above 6.0" goal holds in the nominal pipeline
  and is missed in the pessimistic one (it already was with L4 to L6 alone, 5.97).

**Recommendation**:
1. **Take tier 1 now** (3.1k): G1 is the G0 number, L1 was decided, L3 was planned for G0b, the rest loses nothing.
2. **Take G4** (1.9k at +0.2 %): the author chose selective replay (`Plan/OOC.md` 15.1) when it was estimated at
   +0.7k to 1.2k; it measured +1.4k, and the issue queue it needs is 2 entries larger. The cost moves to code that
   misses in the D$ (Linux), which the model cannot show; the selective replay RTL stays in the repository if it is
   wanted back.
3. **Take L4 to L6** (1.2k, −1.7 %), as D-10 ordered.
4. **Model L7** (the operation class per instruction, C1 of the work plan) and take it if it costs about 1 % or less.
5. **End state A**: L9 now (it shapes the ALU ports the core is built with); **L10 and B4 / B5 as the reserve
   (3.5k), decided at G1** with the whole core in Vivado. The control (±0.5k) and the whole-chip result (packing,
   optimization across modules) move the total by more than the margin. A rather than B: the same LUTs for 4 %
   more CoreMark; B keeps PMP and `perf`.

The decisions are D-11 to D-14 (section 9).

### 6.4 Tier 1 applied (2026-10-26)

| # | Where | What was done | Yosys (a hint only) | State |
|---|---|---|---|---|
| G1 | `OOO_RENAME` | `NCKPT` 8 → 6. The checkpoints are given out in a ring of 6 (an add modulo NCKPT; 6 is not a power of two). The control must keep at most 6 transfers unresolved | `OOC_RENAME` 3,769 → 3,456 LUTs | `tb_rename` PASS on 4 seeds, with the ring full about 32,000 times each |
| G2 | `OOO_DEC` | The rare classes (illegal, FP, CSR and system, SFENCE.VMA, AMO / LR / SC, cbo.zero) are decoded in slot 0 only: their fields are 0 in slots 1 to 3, and a new output `cut` ends the group before one in slot 1 to 3 (it comes to slot 0 next cycle). `CORE_DEC` is kept as it is | `OOC_DEC` 2,246 → 2,078 LUTs (the estimate was −0.4k to −0.7k: the logic that recognizes them stays) | `tb_dec` PASS; each RVC encoding is now also tried in slot 0. CoreMark has 2 such instructions in 3 million (the timer reads) |
| G3 | `OOO_IQPL` | Port 2 reads the low `W2` = 48 bits of a record (the LSU's fields go there when the record is laid out) | `OOC_IQPL` 1,202 → 1,008 LUTs; the LUT RAM stays 384 (a RAM32M has 3 read ports in any case: only the bank choice goes) | `tb_iqpl` PASS on 4 seeds |
| L1 | `CORE_CSR` | Not in the repository yet: applied when the CSRs are brought in for the assembly (a parameter) | | Counted at its estimate |
| L3 | FPU | A design task (C2 shared multiplier, C3 a small iterative unit): in Phase 2, with the FPU | | Counted at its estimate |
| L8 | LiteX | At the LiteX build | | Counted at its estimate |

- **For the assembly**: the fetch buffer and fusion take `valid & ~cut` from decode; dispatch stalls at 6 unresolved
  transfers; the payload's record keeps the LSU's fields in its low 48 bits.
- Bug injection: 5 added (183 + 5 = 188), and 5 retargeted after the decode change; all 188 detected.
- `OOC_DEC` now also registers `cut` (568 output bits).
- **Vivado asked**: `synth_ooo.bat OOC_RENAME`, `OOC_DEC`, `OOC_IQPL`.

### 6.5 D-12 applied: replay after commit, issue queue 10 (2026-10-26)

| Block | What was done | Yosys (a hint only) | Test |
|---|---|---|---|
| `OOO_IQ` | Back to the queue before the selective replay (git f4af1b8: entries freed at issue, no masks, no kept entries, no `ld_cancel` / `iss_ldm` / `ld_kill`), with `disp_entry` kept, **N = 10** | 6,172 → 2,513 LUTs (Vivado before: 3,143 at 16 without the replay, 4,977 with it) | `tb_iq` (its version before the replay, with a seed, `disp_ready` and the entry checks) PASS on 4 seeds |
| `OOO_LSU` | `lcan` per LQ entry: set by `ld_cancel`, cleared at allocation; the load's completion carries it (`cmp_ld_rp`) | 4,779 → 4,662 (noise) | `tb_lsu`, `tb_dcad`: a load that raised `ld_cancel`, and only such a load, completes marked |
| `OOO_ROB` | A replay bit per entry (`cmp_rp`) and the µop's length in the payload (`disp_len`, 3 bits). A marked µop commits, nothing younger with it, and the ROB empties: `replay` with `replay_pc` = its pc + its length. Order: trap, replay, restore | 1,544 → 1,621 | `tb_rob`: marked load completions, the replay and its pc checked; about 5,700 replays a run, PASS on 4 seeds |
| `OOO_IQPL` | 10 entries (the cost is the same up to 32) | | `tb_iqpl` PASS |

- **For the assembly**: `replay` is a `flush_all` for the rest of the core (renaming to the committed state, the LSU,
  the issue queue) with fetch from `replay_pc`; dispatch in that cycle does not go in (as for a trap). Renaming's
  busy bits keep following the wakeup buses. A load that runs only at the head (MMIO, 3.9) must not wake its dependents
  on a guess (it issues as one answered from outside), so it never raises `ld_cancel` for them.
- The selective replay's RTL and its test stay in git (5935e45, 7d93d41) if it is wanted back.
- Bug injection: the 21 mutations of the selective replay (M132 to M152) went with it, 8 were added (M195 to M202),
  4 retargeted: 175 in all, all detected.
- **Vivado asked** (with 6.4's three): `synth_ooo.bat OOO_IQ`, `OOC_ROB`, `OOC_LSU` (and `OOC_IQPL` again, now 10
  entries).

### 6.6 The Vivado results of tier 1 and D-12 (2026-10-26)

| Run | Before | **Now** | Change | Register-to-register slack | Estimate of the lever |
|---|---|---|---|---|---|
| OOO_IQ (10 entries, no selective replay) | 4,977 (16, replay); about 3.9k counted at 12 | **1,621** | **−2,279** against what was counted | +7.843 ns (was +2.857) | G4: −1.9k with the ROB and LSU parts |
| OOC_ROB (replay after commit) | 1,073 | **1,232** (176 LUT RAM) | +159 | +11.233 ns | (in G4) |
| OOC_LSU (the replay mark) | 2,969 | **2,981** | +12 | +5.698 ns | (in G4) |
| OOC_RENAME (6 checkpoints) | 2,624 | **2,464** | −160 | +8.179 ns | G1: −0.25k |
| OOC_DEC (rare classes in slot 0) | 1,980 | **1,808** | −172 | +7.803 ns | G2: −0.4k to −0.7k |
| OOC_IQPL (10 entries, port 2 at 48 bits) | 711 | **585** (320 LUT RAM) | −126 | +12.620 ns | G3: −0.1k to −0.2k |
| **Together** | | | **−2,566** | | **−2.85k** (G1 to G4 at their middle values) |

- **All close at 50 MHz**; the issue queue gained 5 ns of slack.
- **G4 (replay after commit + 10 entries) did better than estimated**: −2.11k with the ROB and LSU parts, against −1.9k.
- **G2 did worse**: −172 against −0.4k to −0.7k, as Yosys said; the logic that recognizes the rare classes stays in
  slots 1 to 3 while `CORE_DEC` is used whole. A light integer-only decoder for slots 1 to 3 (option 1b of the
  decision list) is the way to the rest, about −0.3k to −0.5k more, with new verification.
- **The budget** (4.4): the gap goes to **7.5k / 8.9k / 10.2k**.
- **Against the plan of 6.3**: the measured part of tier 1 and G4 gave 2.57k for 2.85k planned (−0.28k). The levers
  still to come (L1, L3, L8 of tier 1 at 2.15k; L4 to L6 1.2k; L7 0.85k; L9 1.2k; the reserve L10 + B4 / B5 3.5k)
  add up to 8.9k: **the middle margin is now about 0** (−0.03k), +1.4k at the low end, −1.3k at the high end.

### 6.7 D-14 applied: fusion level 2 (2026-10-26)

| Block | What was done | Yosys (a hint only) | Test |
|---|---|---|---|
| `OOO_FUSE` | `LEVEL` 2: the ALU + ALU rule and the `alu2ok` input are gone | `OOC_FUSE` 285 → 269 | `tb_fuse` random PASS; on the CoreMark stream (`FUSE_TRACE`, `mkfuse.py` now at level 2) the RTL forms the model's pairs exactly (156,004 = 156,004) |
| `OOO_ALU2` | One full ALU and the branch comparison. The narrowed second ALU went with ALU + ALU, and **the third source `s3` too**: a fused branch compares the ALU result with s1, s2 or zero (`br_o_sel`), since a pair reads at most 2 registers (SRC2). G0 counted "no third source" (6.1, about −0.4k) but the RTL still had it | `OOC_ALU2` 4,617 → 3,235 (the harness now bypasses 2 sources) | `tb_alu2` PASS (the fused branch with each choice of the other operand, and equal operands on a port the ALU does not read) |
| `OOO_DEC` | `alu2ok` removed | 2,078 → 2,112 (noise) | `tb_dec` PASS |
| `OOO_ALU` | `FULL = 0` (the narrowed form) no longer used; the parameter is kept | | |

- **For the assembly**: decode / fusion give a fused branch `br_o_sel` (which of the µop's two source ports holds the
  branch's other register, or zero for x0); the payload loses the second operation's fields.
- Bug injection: M3, M6, M29, M157, M158 (the second stage, ALU + ALU, `alu2ok`) went with them, M203 to M205 were
  added: 173 in all, all detected.
- **Vivado asked**: `synth_ooo.bat OOC_ALU2`, `OOC_FUSE`, `OOC_DEC`. The budget counts the two ALU ports at about 5.9k
  (6.1); L9 was −1.2k.

### 6.8 The Vivado results of D-14 (2026-10-26)

| Run | Before | **Now** | Change | Register-to-register slack |
|---|---|---|---|---|
| OOC_ALU2 (one port: one ALU, the branch comparison, 2 bypassed sources) | 3,133 | **1,926** (`OOO_ALU` 801 of it) | −1,207 a port | +1.753 ns (was +0.512), 46 levels (33 CARRY4) |
| Two ALU ports | about 5.9k counted (6,266 less the third source of 6.1) | **3,852** | **−2,048** against what was counted | |
| OOC_FUSE (level 2) | 215 | **208** | −7 | +10.591 ns |
| OOC_DEC (no `alu2ok`) | 1,808 | **1,791** | −17 | +8.034 ns |
| **Together** | | | **−2,072** | |

- **All close at 50 MHz**, the ALU port with 1.2 ns more slack than before (its worst path: the bypass → the ALU's
  adder → the fused branch's comparison → `take_branch`, two carry chains in a row).
- **L9 gave −2.07k, against −1.2k planned**: the second ALU and its bypass, and the third source, which G0 had already
  subtracted (−0.4k) but the RTL still had.
- **The budget** (4.4): the gap goes to **5.4k / 6.8k / 8.1k**.
- **L7 (asymmetric ALUs) is worth less now**: its −0.7k to −1.0k was estimated against ports of two chained ALUs. With
  one ALU of 801 LUTs a port, an ALU1 with only add / sub, logic, compares and branches saves about −0.3k to −0.5k
  (to be modelled before it is taken).
- **Against the plan**: still to come L1, L3, L8 (2.15k), L4 to L6 (1.2k), L7 (about 0.4k) and the reserve L10 + B4 /
  B5 (3.5k): 7.25k. **Middle margin about +0.4k** (+1.8k low, −0.9k high). Without the reserve, the middle is about
  3.1k short.

### 6.9 L4 to L6 applied: LQ / SQ 8, uBTB 8, fetch buffer 2 blocks (2026-10-26)

| Lever | Where | Yosys (a hint only) | Test |
|---|---|---|---|
| L4 | `OOO_LSU` `NLQ` / `NSQ` 12 → 8, `OOO_DCAD` `NLQ` 8; the LSU harnesses rewritten for 3-bit entries and 4-bit tails | `OOC_LSU` 4,662 → 3,055; `OOC_LSUDC` 13,843 → 12,455 | `tb_lsu`, `tb_dcad` (widths derived from the sizes) PASS on 4 seeds |
| L5 | `OOO_UBTB` `NE` 16 → 8 (and in `OOO_FETCH`) | `OOO_UBTB` 2,207 → 1,037; `OOC_FRONT` 5,797 → 5,148 | `tb_ubtb`, `tb_fetch` PASS |
| L6 | `OOO_FBUF` `NB` 4 → 2 | `OOC_FBUF` **1,381 → 1,829**, LUT RAM 176 → 0 | `tb_fbuf` PASS on 4 seeds |

- **L6 may save nothing.** The blocks were in LUTRAM, whose cost does not depend on the depth below 32, so 2 blocks
  save no RAM; and a 2-deep memory is built of flip-flops and selects instead (Yosys). The −0.3k estimate counted the
  model's buffer in instructions, not this structure. If Vivado confirms it, L6 goes back to 4 blocks (it costs −0.3 %
  for nothing).
- The model's "L4 to L6" row is −1.7 % / −0.5 % (`results/g0b.txt`).
- Bug injection: 171 of 173 detected. M77 and M86 (the start of the block after B when two blocks are popped) are
  equivalent with 2 blocks: there is never a third block. They are detected with 4 blocks; the RTL stays general,
  since L6 may go back to 4.
- **Vivado asked**: `synth_ooo.bat OOC_LSU`, `OOO_UBTB`, `OOC_FBUF`, `OOC_FRONT` (and `OOC_LSUDC` for the timing with
  the D$).

### 6.10 The Vivado results of L4 to L6 (2026-10-26)

| Run | Before | **Now** | Change | Register-to-register slack | Estimate |
|---|---|---|---|---|---|
| OOC_LSU (LQ / SQ 8) | 2,981 | **2,290** | −691 | +6.866 ns | L4: −0.4k to −0.6k |
| OOO_UBTB alone (8 entries) | 910 | **492** | −418 | +7.078 ns | L5: about −0.4k |
| OOC_FRONT (the uBTB inside) | 3,076 | **2,588** | **−488** (what the budget sees: it counts the front end as OOC_FRONT) | +0.574 ns (was +0.959) | |
| OOC_FBUF (2 blocks) | 940 | **924** (192 LUT RAM, as before) | **−16** | +4.076 ns | L6: about −0.3k |
| OOC_LSUDC (LSU + adapter + D$) | 8,439 | 7,562 (adapter 199, was 227) | −877 | +1.552 ns | |
| **Together, as the budget counts** | | | **−1,223** (LSU, front end, fetch buffer, adapter) | | **−1.2k** |

- **All close at 50 MHz** (the front end with 0.57 ns, the uBTB's loop at 7.1 ns).
- **L4 and L5 did better than estimated; L6 did nothing.** Vivado kept the 2 blocks in LUTRAM (Yosys had not), whose
  cost is the same at any depth below 32: −16 LUTs for −0.5 % / −0.2 % in the model (fb 8 against 16 with the decided
  set: 6.250 / 6.698 against 6.279 / 6.710; pessimistic 5.504 / 5.928 against 5.548 / 5.971). **Recommended: L6 back
  to 4 blocks.** **Done (the author, 2026-10-26)**: `NB` is 4 again; that RTL is the one measured before (940 LUTs,
  13.7), the reports are those again, and M77 / M86 are detected again (173 of 173). The decided set in the model is
  now **6.28 / 6.71** (pessimistic 5.55 / 5.97).
- **The budget** (4.4): the gap goes to **4.2k / 5.6k / 6.9k** (with the fetch buffer back at 940: +16, no change in
  the rounding).
- **Against the plan**: still to come L1, L3, L8 (2.15k), L7 (about 0.4k) and the reserve L10 + B4 / B5 (3.5k):
  6.05k. Middle margin about +0.4k (+1.8k low, −0.9k high), as before: L4 to L6 gave what was planned.

### 6.11 L7 modelled: asymmetric ALUs (2026-10-27)

**The model** (`Plan/model/ooo.h`, option `alu_split`; `g0b.sh` → `results/g0b.txt`): the two ALU ports were pooled
(either took any ALU µop, MUL / DIV too). Now `alu_split` 1 keeps ALU0 and ALU1 apart with MUL / DIV and system on
ALU0 only, as the RTL is; 2 also puts the complex ALU operations on ALU0 only (L7: shifts, Zba, Zbb, Zbs, Zicond, by
the trace's `sub` field), a simple µop taking ALU1 first; 3 is the same with a simple µop taking ALU0 first. A fused
pair is complex when its ALU part is.

| Configuration | `-O2` | Most optimization | Pessimistic |
|---|---|---|---|
| The decided set (trap at commit, issue queue 10, L4, L5, fusion level 2) | 6.279 | 6.710 | 5.548 / 5.971 |
| The same, ALU0 / ALU1 apart (`alu_split` 1) | 6.279 | 6.710 | |
| **+ L7, a simple µop takes ALU1 first** (2) | **6.260 (−0.3 %)** | **6.695 (−0.2 %)** | 5.521 / 5.949 (−0.5 % / −0.4 %) |
| + L7, a simple µop takes ALU0 first (3) | 5.882 (−6.3 %) | 6.264 (−6.6 %) | |

- **The ALU ports apart cost nothing**: MUL / DIV on ALU0 only (as the RTL) gives the same numbers as the pooled model.
- **L7 costs −0.3 % / −0.2 % if a simple µop goes to ALU1 first**, and **−6 % if it goes to ALU0 first**: the complex
  operations are 30 % of the ALU instructions (16.5 % of all in g14 -O2: shifts 5.2 %, Zba 5.2 %, Zbb 3.0 %, Zbs 1.6 %,
  Zicond 1.5 %) and wait behind simple ones on ALU0. So with L7 the issue queue selects **port 1 first** (the oldest
  ready simple µop), then port 0 (the oldest ready of the rest); today it is port 0 first. The depth of the select
  stays the same (one after the other).
- **The size**: the ALU of a port is 801 LUTs in Vivado (6.8). An ALU with only add / sub (with their word forms),
  logic and compares is 165 LUTs in Yosys against 2,174 for the full one (the ratio Vivado / Yosys of the full one is
  0.37): **about −0.5k to −0.65k** for ALU1, if Vivado agrees. More than the −0.3k to −0.5k of 6.8.
- **In the RTL** it would be: decode marks the complex ALU operations "ALU0 only" (port 1, as MUL / DIV already are;
  a fused pair with a complex ALU part too); the issue queue's select order turned round; `OOO_ALU2` of ALU1 with an
  `OOO_ALU` limited to add / sub, logic, compares (the parameter `FULL` is free since D-14).
- **By D-13** (L7 if it costs about 1 % or less) it is to be taken.

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
| 3 | **G0b**: the budget table with measured blocks; the levers of section 6 applied in order | Claude Code proposes, the author decides. **Decided 2026-10-26 as recommended (6.3, D-11 to D-14)** |
| 4 | Integration of the core (M-mode, bare metal), riscv-tests, CoreMark against the model | Claude Code |
| 5 | **G1**: CoreMark in simulation within ±5 % of the model; the core alone in Vivado for LUTs and 50 MHz | |

---

## 9. Decisions for the author

Decided by the author on 2026-10-24 (`Doc/PROMPT.md` entry 23): **Zbc stays, and as a principle the instruction set
is kept** (that of mmRISC-2 Rev.02); everything else as recommended. **G0b (D-11 to D-14) decided by the author on
2026-10-26 (`Doc/PROMPT.md` entry 54): as recommended; tier 1 applied first (6.4).**

| # | Item | Recommendation | **Decision (2026-10-24)** |
|---|---|---|---|
| D-7 | The G0 verdict | Conditional pass; the budget decided at G0b (section 8) | As recommended: **G0 passed with the condition; Phase 1 starts** |
| D-8 | Linux-side reductions L1 and L2 (2 HPM counters, no Zbc) | Take them (no effect on CoreMark) | **L1 taken; L2 not taken** (Zbc stays) |
| D-9 | FPU (D3 reconsidered) | Keep FPU_PIPE; C1 now; C2 and C3 at G0b if needed. Not the multi-cycle FPU (it is larger) | As recommended (C2 / C3 keep the instruction set) |
| D-10 | The order of the levers when the gap remains | L3 → L4 to L6 → L7 → L9 → L10 → L11 / L12 (section 6.2) | As recommended; no lever may remove instructions |
| D-2 | L2 size | Keep 256 KB (block RAM is not the limit) | As recommended |
| D-11 | G0b tier 1 (G1, L1, L3, L8, G2, G3; 6.3) | Take all (about 3.1k, nothing lost) | **As recommended (2026-10-26)** |
| D-12 | Replay policy again: the trap at commit with an issue queue of 10 (G4) | Take it (about 1.9k, +0.2 % CoreMark; code that misses pays a refetch) | **As recommended (2026-10-26)** |
| D-13 | L4 to L6, and L7 after it is modelled | Take L4 to L6 (1.2k, −1.7 %); L7 if about 1 % or less | **As recommended (2026-10-26)**; L6 taken back after Vivado (6.10) |
| D-14 | The end state | A: fusion level 2 now; the 54k ceiling and no PMP / HPM as the reserve, decided at G1 | **As recommended (2026-10-26)** |
