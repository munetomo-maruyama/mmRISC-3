# Phase 0-3: cycle model (1) framework and calibration against mmRISC-2

- Date: 2026-10-24
- Purpose: `ISSUES.md` 3.1 and step 1 of section 5. Build the framework of a trace-driven C++ cycle model and calibrate
  it against mmRISC-2's 8-stage in-order core. Step 2 builds the 2-wide out-of-order core in the same framework
- Working files: `Plan/model/` (`mktrace.py`, `model.h`, `pred_mm2.h`, `inorder.h`, `model.cpp`, `calib.sh`,
  `results/calib.txt`)

---

## 1. Summary

1. **The model reproduces mmRISC-2's 8-stage in-order core within ±0.3 % at all five measured points of CoreMark.**
   There is one free parameter (cycles from resolving a misprediction to IF1, `redirect = 2`), and it fits the five
   points at once.
2. The waits agree with the measurements too: multiply waits (281,880 / 93,960) exactly, load-use waits 203,282 /
   67,982 (measured 203,281 / 67,982), branches resolved in MR 135,300 (measured 135,299). One misprediction costs
   4.16 cycles (measured 4.12).
3. This confirms that the basic parts of the model (reading the trace, dependences, fetch, mmRISC-2's predictor) agree
   with the real numbers. The 2-wide out-of-order core is built by adding parts to this framework (step 2).

---

## 2. Structure of the model

| File | Content |
|---|---|
| `mktrace.py` | Turns a trace of `../trace/` (text) into fixed records of 32 bytes per instruction. Decoding is shared with `../trace/analyze.py` (the same instructions seen the same way) |
| `model.h` | The record (pc, memory address, size, class, flags, 3 sources, destination, base, operation kind for fusion), reading, `key=value` options |
| `pred_mm2.h` | mmRISC-2's branch prediction: a direct-mapped BTB per 8-byte word (256, with an owner, made only when taken), gshare (PHT 8192, 12 bits of history folded into the upper bits) or the BTB's 2-bit counters, a return address stack (8) |
| `inorder.h` | Timing of mmRISC-2's 8-stage in-order core |
| `model.cpp` | Main (`model inorder <trace.bin> [key=value ...]`) |
| `calib.sh` | Runs the five calibration points next to the measurements (`results/calib.txt`) |

### 2.1 The in-order model (`inorder.h`)

| Element | How it is modelled | Basis in mmRISC-2 |
|---|---|---|
| Fetch | One 8-byte word per cycle in IF1; an instruction can enter EX `fetch_to_ex = 3` cycles after the IF1 of the word with its last parcel | IF1 → IF2 → ID → EX (CPU_CORE_SPEC 3.2) |
| Correctly predicted taken | The target word is read in IF1 in the next cycle (no bubble) | The BTB is read in IF1 (4.2) |
| Misprediction | Resolved in cycle t, the target enters IF1 at `t + redirect`. **`redirect = 2` is the only tuned value** | The redirect path from EX (decision 46) |
| Multiply | Holds EX 1 cycle (MULH family 2) | Decision 61 |
| Load-use | The instruction right after a load reading its value waits 1 cycle in EX; a conditional branch does not wait but is resolved in MR (1 cycle later if wrong) | 3.2, decision 64 |
| Caches | Always hit | CoreMark misses per 1000 instructions: I$ 0.49, D$ 0.16 (board) |

---

## 3. Calibration

Five points of CoreMark measured by mmRISC-2 in October in SIM_SYS (10 iterations, GCC 13.2, `-O2`), each changing
one thing in the hardware (`LitexSystem/docs/BENCH.md`).

| Point | State of mmRISC-2 | Measured (cycles) | Model | Difference |
|---|---|---|---|---|
| P1 | After A2 (section 6): multiply wait 3, 2-bit counters of the BTB | 4,312,829 | 4,314,572 | +0.04 % |
| P2 | Decision 61 (section 7): multiply wait 1 | 4,124,913 | 4,126,652 | +0.04 % |
| P3 | Decision 63 (section 9): gshare | 4,033,497 | 4,044,524 | +0.27 % |
| P4 | Decision 64 (section 10): branches resolved in MR | 3,908,766 | 3,911,568 | +0.07 % |
| P5 | Same hardware, the Zba / Zbb build (section 11) | 3,513,870 | 3,518,805 | +0.14 % |

| Breakdown | Measured | Model |
|---|---|---|
| Multiply waits (P1 / P2) | 281,880 / 93,960 | 281,880 / 93,960 |
| Load-use waits (P1 / P4) | 203,281 / 67,982 | 203,282 / 67,982 |
| Branches resolved in MR / wrong (P4) | 135,299 / 2,321 | 135,300 / 2,344 |
| Loss from mispredictions (P1) | 5.6 % (about 241.5k), 4.12 each | 240,165, 4.16 each |
| Conditional branch mispredictions: 2-bit (P1) / gshare (P3) | 54,001 / 31,435 | 52,069 / 32,529 |
| `jal` / `jalr` mispredictions (P1) | 1,028 / 3,559 | 2,691 / 2,962 |

- Conditional branch mispredictions agree within ±4 %. The split between `jal` and `jalr` differs, but the totals
  (4,587 and 5,653) are close and the effect on cycles is small. The likely cause is the simplification of mmRISC-2's
  "tail entries of branches across words" and "misfetch detection" (top of `pred_mm2.h`).
- With `redirect` = 1 every point comes out about 1 to 1.3 % low; 2 fits the five points at once, so the parameter is
  judged sound.

---

## 4. Limits

- Being trace-driven, the model never executes wrong-path instructions (no pollution of predictors or caches).
  CoreMark fits in the caches even on wrong paths, so the effect is small.
- Caches always hit. mmRISC-2's SIM_SYS memory answers at once, and the difference to the board (CoreMark/MHz 2.85 →
  2.79 measured) is not in the model. Out-of-order configurations are compared on the same assumption.
- Only the in-order parts (fetch, predictor, dependences, multiply) are calibrated. The parts specific to
  out-of-order (renaming, issue queues, wakeup, ROB, LSQ, TAGE, uBTB, fusion) have no real core to calibrate
  against. So step 2 states the timing of each part as a specification, in a form that can explain part by part the
  difference to the limit model (`TRACE.md`).

---

## 5. Next (step 2)

Done on 2026-10-24; the results are in section 6.

The 2-wide out-of-order model (`ooo.h`) in the same framework:

1. Front end: uBTB (no bubble) + TAGE / BTB override in the second cycle, FTQ, 16-byte fetch, RVC alignment and
   instructions across words.
2. Core: decode / rename (2 µops, up to 4 instructions with fusion), ROB, issue queues (capacity and wakeup-select),
   2 ALUs / 1 LSU / MUL, 2-cycle load-use (hit prediction), misprediction recovery (cycles from resolution to the next
   execution computed from the stages).
3. LSU: conservative memory dependence, store-to-load forwarding, stores after commit.
4. Output: CoreMark/MHz and the losses by kind (front end, mispredictions, dependences, structural); the table of
   configurations goes into a following section of `MODEL.md` (step 2).

---

## 6. Cycle model (2): 2-wide out-of-order (step 2, 2026-10-24)

Working files: `Plan/model/ooo.h` (the model), `tage.h` (TAGE), `sweep.sh` (one parameter at a time,
`results/sweep.txt`)

### 6.1 Summary

1. **A 2-wide out-of-order core is now expected to reach the goals even without fusion.** The baseline gives
   **6.07** CoreMark/MHz with `-O2` and **6.57** with the most optimization. A pessimistic configuration (small
   structures, a slower pipeline and 3-cycle load-use all at once) still gives 5.61 and 6.05.
2. **Fusion adds margin**: with ALU + ALU included, 7.06 / 7.59 for the baseline and 6.41 / 6.88 for the pessimistic
   configuration. It needs 4-wide decode (with 2-wide decode it gives only +3 %).
3. **The "−19 % for a bubble per taken transfer" of the limit model (`TRACE.md`) does not happen with a decoupled
   out-of-order front end.** 16-byte fetch through a buffer is faster than dispatching 2 per cycle, so the bubbles
   at taken transfers are almost all absorbed. Even with no uBTB, losing a cycle to the override at every taken
   transfer, the loss is 0.9 %. **Fetch width matters instead** (8 bytes: −3.8 %).
4. What matters (change from the baseline): the predictor (gshare −13 %, TAGE-S → M +0.9 %), 3-cycle load-use
   −5.9 %, no forwarding −4.3 %, one ALU −36 %, 4 checkpoints −1.8 %, 2 LSUs +1.6 %.
5. What hardly matters: ROB (32 to 96), issue queue (16 and up), pipeline depth (about −0.3 % per stage, since
   mispredictions are rare), uBTB size (16 to 128), conservative memory dependence, multiply latency, 3 ALUs, limiting
   issue to 3 per cycle, MUL sharing an ALU port.
6. **Checks**: (a) with perfect prediction and no fetch or queue limits, IPC is 1.9507, matching 1.951 of the limit
   model "without group break". (b) The C++ TAGE gives exactly the mispredictions of the Python trace analysis
   (S / M / L). (c) A configuration close to NaxRiscv (gshare, 3-cycle load-use) gives 4.83 on the build of
   mmRISC-2's condition, close to NaxRiscv RV64's published 4.94 (compiler and ISA differ, so only as a sanity
   check).

### 6.2 Specification of the model (baseline)

| Item | Baseline | Meaning |
|---|---|---|
| Width | 2 µops dispatched / committed, 4 instructions decoded, 3 issued in total per cycle | `w`, `dec_w`, `issue_w` |
| Units | 2 ALUs (with branches), 1 LSU, MUL / DIV sharing an ALU port | `alu`, `lsu`, `mul_shared` |
| Front end | 16 bytes (aligned) fetched per cycle, the next block after a taken transfer, 16-instruction fetch buffer | `fetch_bytes`, `fb` |
| Prediction | uBTB 64 (fully associative, LRU, 2-bit counters, returns from the RAS) gives the next PC with no bubble; TAGE-S + BTB + 16-entry RAS override it 2 cycles after F0 | `ubtb`, `pred`, `override_at` |
| Stages | F0 → decode 3, decode → dispatch 2, dispatch → issue 1, issue → end of EX 2, resolution → F0 1. **A misprediction costs 9 cycles from EX to EX** | `fe_depth`, `dec_depth`, `iss_to_ex`, `redirect` |
| Window | ROB 64, issue queue 24 (unified, freed at issue), LQ 16 / SQ 16, unlimited checkpoints | `rob`, `iq`, `lq`, `sq`, `ckpt` |
| Latencies | Issue to the issue of a dependent: ALU 1, load 2 (hit), MUL 2 | `lat_*` |
| Memory | Conservative memory dependence, forwarding from the SQ, stores after commit; a store issued with its data too (its address known then: `OOO_LSU`, Plan/CORE.md 5.8) | `mem_cons`, `fwd`, `st_data_issue` |
| Fusion | None (1: address calculation + load, pairs, lui / auipc; 2: + ALU + branch; 3: + ALU + ALU chained in one cycle) | `fusion`, `chain` |

### 6.3 Results (excerpt; every row in `Plan/model/results/sweep.txt`)

CoreMark/MHz; `-O2` is g14 / o2 / zbsc, the most optimization g14 / sflto / zbsc.

| Configuration | `-O2` | Most optimization |
|---|---|---|
| **Baseline** | **6.07** | **6.57** |
| Perfect prediction | 6.24 | 6.71 |
| gshare (like mmRISC-2) | 5.27 | 5.73 |
| TAGE-M | 6.12 | 6.59 |
| No uBTB (override at every taken transfer) | 6.02 | 6.56 |
| Fusion 1 / 2 / 3 | 6.38 / 6.65 / **7.06** | 6.66 / 6.93 / **7.59** |
| Fusion 3 with 2-wide decode | 6.24 | 6.89 |
| 8-byte fetch | 5.84 | 6.26 |
| 3-cycle load-use | 5.71 | 6.15 |
| No forwarding | 5.81 | 6.29 |
| 4 checkpoints | 5.96 | 6.42 |
| Small structures (ROB 32, IQ 16, LQ / SQ 12, 8 checkpoints, uBTB 32) | 6.06 | 6.53 |
| **Pessimistic** (small structures + 1 more cycle in each part + override at 3 + 3-cycle load-use) | **5.61** | **6.05** |
| Pessimistic + fusion 2 / 3 | 6.09 / 6.41 | 6.35 / 6.88 |
| Close to NaxRiscv (gshare, 3-cycle load-use, IQ 32) | 4.92 | 5.33 |
| Reference: 3-wide | 7.47 | 8.12 |
| Reference: 1-wide out-of-order | 3.17 | 3.53 |

### 6.4 What changes (proposal)

| Item | So far | After the model |
|---|---|---|
| Front end | A zero-bubble uBTB is required (`ISSUES.md` 3.2) | **16-byte fetch decoupled from dispatch (a buffer) is what matters.** 16 to 32 uBTB entries suffice, and without one −1 %; if the 1-cycle next-PC loop does not close, the uBTB can go |
| Fusion | +15 %, 4-wide decode for 0.7k LUTs | **+16 % (baseline) / +14 % (pessimistic)**; 4-wide decode required. D-4: "ALU + branch" (+9 %) as the minimum, ALU + ALU depending on the timing of two ALU stages |
| Structure sizes | ROB 48 to 64, IQ 16 to 24 | **ROB 32, IQ 16, LQ / SQ 12 to 16 and 8 checkpoints suffice** (−0.3 %); the LUTs can be saved |
| Load-use | 2 cycles (−3 to 4 %) | Keeping 2 cycles is worth **about 6 %**; hit prediction and speculative wakeup are required |
| LSU | 1 | 2 gives +1.6 %; a candidate if resources allow |
| Predictor | TAGE-S to M | TAGE-S (62 kbit) suffices (0.9 % below TAGE-M) |
| Expectation | With fusion, `-O2` 5.1 to 5.7, most optimization 5.6 to 6.4 | **Without fusion `-O2` 5.6 to 6.1, most optimization 6.05 to 6.6; with fusion 6.1 to 7.1 / 6.35 to 7.6** |

### 6.5 Limits (what the model leaves out)

- **Cache misses and the board's memory**: always hit. In mmRISC-2 the board was about 2 % below the simulation (2.79
  against 2.85); read the numbers with about that subtracted.
- **Wrong-path instructions**: not executed. Wrong-path µops occupying the ROB / IQ / ports make reality a little
  worse (with 1.4 mispredictions per 1000 instructions the effect is expected to be small).
- **Issue selection**: ideal oldest first; no approximation of a real select, no port-assignment constraints.
- **PRF capacity and ports**: unconstrained (PRF 96 with ROB 64 is enough by count); 3 issues per cycle need 6 read
  ports.
- **Feasibility of the timing**: whether each stage assumption (1-cycle wakeup-select, chaining two ALU stages, the
  2-cycle TAGE override) closes at 50 MHz is checked by OOC synthesis (`ISSUES.md` 3.5).
- **Correctness handling of fusion**: the cost of splitting and re-executing a pair on an exception is not in the
  model (CoreMark raises no exceptions).

### 6.6 Next

1. OOC synthesis of the main loops (two ALU stages, wakeup-select, uBTB next PC, renaming, PRF); RTL by Claude Code,
   Vivado by the author.
2. Carry the revisions of 6.4 into `STRATEGY.md` and `ISSUES.md`, and gather the material for the G0 decisions
   (D-4 fusion scope, structure sizes).
3. If needed, add I$ / D$ and the board's memory latency to the model, and check with traces of Linux loads
   (mmRISC-2's workload) too.
