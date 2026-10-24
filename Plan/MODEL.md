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

The 2-wide out-of-order model (`ooo.h`) in the same framework:

1. Front end: uBTB (no bubble) + TAGE / BTB override in the second cycle, FTQ, 16-byte fetch, RVC alignment and
   instructions across words.
2. Core: decode / rename (2 µops, up to 4 instructions with fusion), ROB, issue queues (capacity and wakeup-select),
   2 ALUs / 1 LSU / MUL, 2-cycle load-use (hit prediction), misprediction recovery (cycles from resolution to the next
   execution computed from the stages).
3. LSU: conservative memory dependence, store-to-load forwarding, stores after commit.
4. Output: CoreMark/MHz and the losses by kind (front end, mispredictions, dependences, structural); the table of
   configurations goes into a following section of `MODEL.md` (step 2).
