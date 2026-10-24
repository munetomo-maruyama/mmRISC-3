# mmRISC-3 Development Strategy (CoreMark first)

- Date: 2026-10-23
- Inputs: `Plan/PRESTUDY_MMRISC2.md` (the study memo of 2026-10-13), the mmRISC-2 white paper, `LitexSystem/docs/BENCH.md` and `TIMING.md`
- Status: the strategy that sets the direction. Numbers marked "measured" are mmRISC-2 records; the rest are estimates to be checked in Phase 0

---

## 0. Summary

1. **Splitting the goal into "instruction count × IPC" shows how hard it is.** mmRISC-2's `-O2` (Zba / Zbb) runs
   **318.6k instructions** per CoreMark iteration (measured). At that count, 5.0 /MHz needs **IPC 1.59** and 6.0 /MHz
   needs **IPC 1.91**. The limit of a 2-wide machine is 2.0, so 6.0 is 96 % of the theoretical limit and not realistic.
2. The earlier study memo saw a ceiling of about 1.6 times (about 4.9 /MHz). The new goal is above that, so **the
   memo's modest out-of-order baseline will not reach it**. The design centre moves to "remove the items of CoreMark's
   CPI stack".
3. The main enemy is **branch misprediction**. mmRISC-2 mispredicts 13 times per 1000 instructions on CoreMark
   (measured). At about 10 cycles each in an out-of-order core, that alone costs 130 cycles per 1000 instructions,
   the whole budget for 5.0 /MHz (128 cycles, below). **The predictor (TAGE-like, in block RAM) and a shallow pipeline
   come first.**
4. Three ways past the IPC-2 wall: (a) **macro-op fusion** (up to 4 instructions in 2 decode slots), (b)
   **short-forward-branch predication (SFB)**, which removes mispredictions, (c) **fewer instructions** through the
   compiler and ISA extensions. A 3-wide decoder hardly fits the LUT budget of the Arty A7-100T (below).
5. The rule is the one mmRISC-2 settled on: **measure before building**. Before any RTL, a **trace-driven performance
   model** is built, calibrated against mmRISC-2's measured CPI, and used to choose the configuration (Phase 0,
   gate G0).
6. Order of work: **CoreMark first**. The integer out-of-order core reaches the CoreMark goal in simulation first
   (M-mode, bare metal); the MMU, FPU, debug and Linux come after. The hooks Linux needs (non-speculative execution,
   precise exceptions) are in the design from the start.
7. Realistic expectation (to be checked): **4.5 to 5.0 /MHz** with `-O2`, **5.0 to 5.5 /MHz** with the most
   optimization. **6.0 or more with the most optimization is the upside** if fusion, SFB and the instruction-count
   reduction all work. The Phase 0 model turns this into numbers.
8. **Revised 2026-10-24 (results of the cycle model, `Plan/MODEL.md` section 6)**: 2-wide out-of-order gives 6.07 with
   `-O2` and 6.57 with the most optimization even without fusion, and 5.61 / 6.05 in a pessimistic configuration.
   **By the author's instruction the "fusion configuration" (4-wide decode, fusion up to chained ALU + ALU) is the
   baseline** (7.06 / 7.59). Limiting a fused pair to one register write drops it to 6.75 / 6.90, so two writes per
   pair are assumed and their cost is checked by OOC synthesis. The configuration is the right column of the table in
   section 4.

---

## 1. Splitting the goal

### 1.1 CoreMark/MHz, instruction count and IPC

CoreMark/MHz = 10^6 / (cycles per iteration) = 10^6 × IPC / (instructions per iteration)

| Build | Instructions / iteration | mmRISC-2 (measured) | IPC for 5.0 /MHz | IPC for 6.0 /MHz |
|---|---|---|---|---|
| `-O2`, Zba / Zbb | 318.6k (measured, SIM_SYS) | 2.794 /MHz, CPI 1.123 | **1.59** | **1.91** |
| Most optimization (sf), Zba / Zbb | 294.5k (measured, Spike) | 3.034 /MHz | 1.47 | **1.77** |
| `-O2`, GCC 14.2, Zba / Zbb / Zbs / Zicond | 311.9k (measured, Spike) | — | **1.56** | 1.87 |
| Most optimization (sf + `-flto`), GCC 14.2, same | 281.0k (measured, Spike) | — | 1.40 | **1.69** |

The measurement of the instruction counts is in `Plan/ICOUNT.md` (2026-10-24). With GCC 14.2 + Zicond the IPC needed
goes down to 1.56 for 5.0 with `-O2` and 1.69 for 6.0 with the most optimization.

- A well-made 2-wide core sustains an IPC of about 1.3 to 1.6 (NaxRiscv RV32 with 2 decoders, 5.02 /MHz, is thought
  to be in this range).
- **6.0 with `-O2` is not a target for a 2-wide core.** The targets are 5.0 with `-O2` and 6.0 with the most
  optimization.

### 1.2 IPC budget (CPI stack), example: 5.0 /MHz with `-O2`

In cycles per 1000 instructions the budget is 628. The ideal 2 per cycle is 500, so **only 128 cycles are left for
all losses**.

| Item | Budget (per 1000 instructions) | mmRISC-2 (measured) |
|---|---|---|
| Ideal (2 per cycle) | 500 | — |
| Branch mispredictions | 40 (4 × 10 cycles) | 13 mispredictions, about 5 cycles each (8-stage in-order) |
| Front-end bubbles (taken branches, I$ misses) | 30 | 0.49 I$ misses |
| Data dependences (load-use, multiply, serial chains) | 45 | load-use 2.0 %, multiply wait 2.6 % |
| Structural (port conflicts, full ROB / IQ) | 13 | — |
| **Total** | **628 → IPC 1.59** | CPI 1.123 |

What the table decides:
- **At most 4 mispredictions per 1000 instructions** (a third of today). CoreMark processes the same input in every
  iteration, so a predictor with long histories learns it well. A large TAGE-like predictor in block RAM pays off.
- **A misprediction costs 10 cycles or less.** The 20 ns of the fixed 50 MHz go into fewer stages (= a smaller
  penalty).
- **No bubble on a taken branch** (a zero-bubble next-line predictor).

### 1.3 Fix the measurement first

Before arguing about performance, the conditions are fixed, taken over from mmRISC-2.

| Item | Rule |
|---|---|
| Where | On the board, under Linux, 50 MHz (`bench.sh` as in mmRISC-2's BENCH) |
| `-O2` | `-O2` only; `-march=rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicond` (**Zicond included, and implemented in the hardware**; decided 2026-10-24) |
| Most optimization | Any options within CoreMark's run rules (source unchanged); every option recorded |
| Compiler | **Fixed at GCC 14.2 (Debian 13, the same as the gcc on the board)** (decided 2026-10-24, reasons in `Plan/ICOUNT.md`) |
| Bitstream | **The same bitstream that runs Linux** (no CoreMark-only configuration) |

---

## 2. The levers (in order of effect on CoreMark)

| Rank | Lever | What | Cost on the FPGA |
|---|---|---|---|
| 1 | Prediction accuracy | TAGE (4 to 6 tables, long histories) + loop predictor; BTB and PHT in block RAM | Mostly block RAM, few LUTs |
| 2 | Misprediction penalty | Merge stages using the slack of 50 MHz. Goal: 10 cycles or less from the branch's execution to the execution of the correct path | Fewer stages, fewer FFs |
| 3 | SFB (short-forward-branch predication) | Turn "a branch over 1 or 2 instructions" into conditional execution; the misprediction disappears | Small (decode and ALU) |
| 4 | Front-end bandwidth | 16 B fetch per cycle, decoupled by an FTQ, zero-bubble next-line prediction, RVC aligner | Medium |
| 5 | Macro-op fusion | `lui+addi`, `auipc+jalr`, `slli+srli`, `add+load` and so on; chosen after measuring the fusion rate in traces | Small to medium (decoder) |
| 6 | Shorter load-use | D$ hit in 2 cycles + speculative wakeup by hit prediction, store-to-load forwarding | Medium |
| 7 | Short dependences | 1-cycle ALU wakeup-select, multiply in 1 to 2 cycles (DSP48) | Medium |
| 8 | Fewer instructions | Zicond / Zbs, compiler and options (a `-mtune` that emits fusible sequences) | Hardware exists |
| 9 | Memory-dependence speculation | Issue loads before older store addresses are known (a simple store-set) | Medium to large; only after the model shows the gain |

**Added 2026-10-24**: after the trace analysis (`Plan/TRACE.md` section 4) and the cycle model (`Plan/MODEL.md` 6.4) the
order becomes: 1 predictor (TAGE-S), 2 fusion and 4-wide decode, 3 2-cycle load-use, 4 store-to-load forwarding,
5 16-byte fetch decoupled from dispatch. SFB dropped. The misprediction penalty (depth) and the uBTB hardly matter in
out-of-order.

More execution units quickly give diminishing returns (NaxRiscv's notes). **For CoreMark, prediction and short
latencies matter more than the number of units.**

---

## 3. Resource budget (Arty A7-100T)

| Item | Value |
|---|---|
| Device | XC7A100T-1: LUT 63,400, FF 126,800, BRAM 135, DSP 240 |
| mmRISC-2 Rev.02 | LUT 79 %, slices 93 % (measured); the slice pressure was the main cause of routing delay |
| Practical limit | LUT 80 to 82 % (about 51k) |
| LiteX SoC (LiteDRAM / LiteEth / SD / UART) | about 11k to 13k LUTs (estimate, measured in Phase 0) |
| L1 / L2 / MMIO | about 9k LUTs (estimate from mmRISC-2) |
| **Left for the core** | **about 30k LUTs** (FPU, MMU, CSR and debug included) |

The parts of mmRISC-2 needed regardless of out-of-order execution (CSR about 3.3k, MMU about 5k, FPU + FRF about 6k,
MDU about 1.1k, debug) take about 15k LUTs. **About 15k to 16k LUTs remain for the out-of-order engine, the front end
and the LSU.** NaxRiscv RV64 (integer only) is about 18k LUTs for the whole core, so this is **tight**.

**Added 2026-10-24**: the measurement of mmRISC-2 Rev.02 by hierarchy shows LiteX at 4.8k LUTs and the FPU at 8.8k LUTs.
The estimate above is corrected in `Plan/ISSUES.md` section 2 (about 34.6k left for the core, about 12.9k for the
out-of-order parts).

What follows:
- **Design on the assumption that 3-wide decode does not fit** (IPC comes from 2-wide + fusion + SFB).
- **The FPU does nothing for CoreMark, so its LUTs go to the integer side.** First candidates: option 3 of the memo
  (multi-cycle FPU) or option 4 (in-order side pipe). F / D stay for Debian (lp64d).
- Large tables go to block RAM / LUTRAM (predictors, ROB payload, PRF, RAT), never to flip-flops (mmRISC-2 moved its
  BTB from FFs to LUTRAM and saved 3,060 LUTs / 7,936 FFs).
- Candidates to cut what Linux does not need: PMP 16 → 8 entries, triggers 4 → 2.

---

## 4. Initial configuration (hypothesis, fixed in Phase 0)

| Item | Hypothesis (first) | **Fusion configuration (revised 2026-10-24, `Plan/MODEL.md` section 6)** |
|---|---|---|
| Fetch | 16 B per cycle, decoupled by an FTQ, zero-bubble next-line predictor (LUTRAM) + BTB (BRAM) + TAGE (BRAM) + RAS | 16 B per cycle, decoupled by a 16-instruction fetch buffer; uBTB 16 (partial tags, next PC in F0; `Plan/OOC.md` 7.6), TAGE-S (62 kbit) + BTB + 16-entry RAS override in F2 |
| Decode / rename / commit | 2 µops per cycle (up to 4 instructions with fusion) | **4-wide decode + fusion** (address calculation + load, load / store pairs, lui / auipc, ALU + branch, ALU + ALU); rename, dispatch and commit 2 µops per cycle; a fused pair reads at most 2 registers and writes at most 1 (`Plan/OOC.md` 7.4) |
| ROB | 48 to 64 entries (payload in LUTRAM / BRAM) | 32 entries |
| PRF | about 96 integer registers (LUTRAM, banked by write port + LVT) | 64 integer registers (32 + ROB 32 × 1), LUTRAM, 3 writes / 6 reads, banked by write port + LVT (`Plan/OOC.md` 7.4) |
| Issue queue | unified 16 to 24, or distributed; 1-cycle wakeup-select | unified 16 entries, 2 sources (fused pairs also at most 2, `Plan/OOC.md` 7.4), 1-cycle wakeup-select, oldest first (age matrix), 3 issues per cycle |
| Execution units | ALU0 (full + branch), ALU1 (simple + branch), MUL/DIV, LSU (1 load + 1 store), FPU (reduced) | 2 ALU ports, each two stages chained (full → narrowed, `Plan/OOC.md` 8: a fused ALU + ALU / ALU + branch in one cycle), MUL / DIV sharing ALU0's port, 1 LSU, FPU (pipelined, decision D3) |
| Load-use | 2 cycles (speculative wakeup by hit prediction) | 2 cycles (required; 3 costs −6 %) |
| Memory | — | conservative memory dependence, LQ / SQ 16, forwarding from the SQ (required), 8 checkpoints |
| Misprediction penalty | 10 cycles or less | 9 cycles from EX to EX (depth hardly matters) |
| Reused | L1 / L2, MMU, CSR, debug, FPU, LiteX integration, SIM_BIOS, bug injection | same |
| Frequency | 50 MHz | 50 MHz |

---

## 5. Measure before building: the Phase 0 performance model

### 5.1 Why the model first
- How far 2-wide gets, and how much fusion and SFB give, **can be measured on CoreMark's instruction stream in a few
  days**. In RTL each choice takes one or two weeks.
- In mmRISC-2 a wrong simulation assumption (memory that answers at once) made the I$ prefetch look "faster".
  **The model is calibrated against mmRISC-2's measurements before it is used.**

### 5.2 Content
1. **Instruction traces**: commit traces of CoreMark from Spike (introduced here, since lock-step verification needs
   it too). First a table of **instruction counts** for `-O2` / most optimization × GCC 13 / 14 / 15 × `-march` (this
   alone fixes the IPC needed).
2. **Trace-driven cycle model** (C++): width, ROB / IQ / PRF sizes, predictor (gshare / TAGE, sizes), penalty,
   load-use, fusion pairs, SFB and memory-dependence handling as parameters.
3. **Calibration**: with an 8-stage in-order setting, reproduce mmRISC-2's CoreMark CPI 1.103 (SIM_SYS) and its
   misprediction rate of 5.4 % within ±3 %.
4. **Design-space exploration**: sweep the parameters and tabulate each one's contribution to CoreMark/MHz.
5. **Against resources**: build NaxRiscv RV64 with LiteX on the Arty and measure it (LUTs, performance under Linux);
   take mmRISC-2's utilization by hierarchy again on Rev.02.

### 5.3 Later use
- The model becomes the **performance reference** of the RTL: when the RTL's CoreMark cycles leave the model's, it is
  investigated as a performance bug (a way to find losses like the 0.8 % of mmRISC-2's decision 82).

---

## 6. Verification

mmRISC-2's assets (SIM_CORE / SIM_SYS / SIM_BIOS, riscv-tests, bug injection), plus what out-of-order execution needs,
**from the start**.

| Means | Purpose |
|---|---|
| **Lock-step comparison with Spike at commit** | Correctness per instruction (a commit-trace interface like RVFI designed first) |
| Random instruction streams (riscv-dv or home-made) | Dense dependences to find holes in renaming and recovery |
| Exception and interrupt injection | Interrupts during a misprediction, page faults on the speculative path |
| Konata pipeline view | Debugging efficiency |
| Cycle comparison with the performance model | Finding performance bugs |
| Bug injection | Into renaming, the free list, checkpoints and the LSQ, to check the tests catch them |
| Commit-trace ring buffer (BRAM) | Debugging on the board (no room for an ILA) |

---

## 7. Phases and gates

| Phase | Content | Gate |
|---|---|---|
| **0** | Repository, measurement rules, instruction-count table, performance model and calibration, design-space exploration, NaxRiscv measured, resource budget | **G0**: micro-architecture spec frozen, with the predicted CoreMark/MHz and the LUT budget in numbers. If the goal is out of reach, the goal or the configuration is revised here |
| 1 | Integer out-of-order core (2-wide, M-mode only, bare metal), Spike lock-step, riscv-tests (rv64ui/um/uc + Zb) | **G1**: CoreMark in simulation within ±5 % of the model; the core alone (OOC) in Vivado for LUTs and 50 MHz |
| 2 | Privilege / CSR / MMU / exceptions / debug / FPU (reduced), all non-speculative handling | **G2**: Linux prompt in SIM_BIOS, all tests PASS, all bug injections detected |
| 3 | LiteX integration, timing, Linux on the board (BusyBox, Debian 13) | **G3**: 120-minute stress test PASS, CoreMark measured on the board |
| 4 | Performance work (larger predictor, more fusion, memory-dependence speculation and so on, in the order the model ranks them) | **G4**: goal reached, or the stopping point decided (as in mmRISC-2, themes estimated under a few % are dropped) |

**Why Phase 1 is CoreMark first**: it is the top metric, and simulation gives the fastest iterations. The risk is
that adding Linux support later breaks things, so serialization at the ROB head, precise exceptions and
non-speculative MMIO loads are already in the Phase 1 spec.

---

## 8. Decisions for the author

Decided by the author on 2026-10-24 (`Doc/PROMPT.md` entry 11).

| # | Item | Recommendation | **Decision (2026-10-24)** |
|---|---|---|---|
| D1 | The goal | 5.0 with `-O2`, 6.0 with the most optimization; confirmed by the model at G0 (6.0 with `-O2` is not a 2-wide target) | As recommended; **the goal is to exceed 6.0 with the most optimization** |
| D2 | Width | Fixed at 2 µops + fusion + SFB; 3-wide reconsidered only if G0 shows plenty of resources | As recommended (SFB was dropped by the trace analysis, `Plan/TRACE.md`) |
| D3 | FPU | Reduced multi-cycle FPU or in-order side pipe (LUTs to the integer side) | **Start with the pipelined FPU (mmRISC-2's FPU_PIPE)**; reconsidered depending on the logic size |
| D4 | Frequency | Fixed at 50 MHz; CoreMark/MHz is the metric, so the slack goes into fewer stages | Fixed at 50 MHz |
| D5 | Ethernet | Kept in the Linux configuration; the first candidate to cut if LUTs run out | **Kept**; logic is reduced by other means (`Plan/REDUCE.md`) |
| D6 | Repository | Same shape as mmRISC-2 (Apache-2.0, main / dev, documents in English and Japanese) | As recommended |

---

## 9. Risks

| Risk | Effect | Counter |
|---|---|---|
| LUTs do not fit | Smaller configuration | Budget in Phase 0, core synthesized alone at G1, FPU reduced, PMP and others cut |
| 2-wide does not reach IPC 1.6 | Goal missed | Known early at G0; fusion and SFB measured in the model first |
| 50 MHz does not close on the -1 grade | More stages, larger penalty | Early OOC synthesis of wakeup-select; a 2-cycle ALU (about −15 %) only as the last resort |
| Out-of-order bugs specific to Linux (MMIO, A/D updates) | Unexplained stops on the board | Non-speculative list in the spec, SIM_BIOS, exception injection |
| Wrong assumptions in the model | Wrong choices | Calibrated against mmRISC-2, cycle comparison with the RTL throughout |

---

## References

- mmRISC-2: https://github.com/munetomo-maruyama/mmRISC-2 (BENCH.md sections 13 / 17 / 28, TIMING.md)
- NaxRiscv Performance and Area: https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html
- `Plan/PRESTUDY_MMRISC2.md` (the study made during mmRISC-2)
