# Phase 0-2: CoreMark trace analysis (instruction mix, branch prediction, SFB, fusion, limit model)

- Date: 2026-10-24
- Purpose: before any RTL, find out from instruction traces whether a 2-wide out-of-order core can reach the goals
  (5.0 CoreMark/MHz with `-O2`, 6.0 with the most optimization) and what matters for it (`Doc/STRATEGY.md`
  section 5.2, steps 1 and the first half of 2)
- Working files: `Plan/trace/` (`trace.sh`, `capture.py`, `analyze.py`, `results/`)
- Premise: the compiler for measurements is GCC 14.2 (Debian 13), and `-O2` includes Zba / Zbb / Zbs / Zicond
  (decided 2026-10-24, `ICOUNT.md`)

---

## 1. Summary

1. **TAGE solves branch prediction.** mmRISC-2's gshare mispredicts 9.4 times per 1000 instructions (MPKI); a TAGE
   brings it down to **0.9 to 1.4** (a seventh to a tenth). CoreMark processes the same data in every iteration, so a
   predictor with long histories learns almost all of it. Even a small TAGE (62 kbit, 2 or 3 block RAMs) reaches MPKI
   1.4, which is expected to be within 1 % of a large one in performance.
2. **With the mispredictions gone, the limit of a 2-wide core is the width itself.** In an idealized model (below, not
   calibrated) the IPC stops at 1.86 even with perfect prediction, and neither more execution units (3 ALUs, 2 LSUs)
   nor a larger ROB (32 → 128) changes it.
3. **Instruction fusion is the way past the width.** Making adjacent dependent pairs one µop removes up to 13 to 15 %
   of the µops and raises the model's IPC by **+15 % (1.84 → 2.11)**. The largest group is "an ALU instruction + an
   ALU instruction that uses its result" (64 pairs per 1000 instructions): two ALU stages in series within one cycle
   at 50 MHz. In 89 % of these pairs the intermediate result is dead, so one register write is enough.
4. **A 1-cycle bubble on every taken transfer costs −19 %.** There are 125 taken transfers per 1000 instructions (one
   every 8 instructions on average). **A zero-bubble next-line predictor is a must.**
5. **SFB (short-forward-branch predication) does almost nothing for CoreMark.** Its candidates are 2 % of the
   conditional branches and at most 2 % of TAGE's mispredictions; GCC 14 has already removed short branches with
   Zicond. It leaves rank 3 of `STRATEGY.md` section 2.
6. **Conservative memory dependence (loads wait until older store addresses are known) costs 0 %.** CoreMark's store
   addresses are known early, so the first LSQ can be conservative. But 11 % of the loads read data stored within the
   previous 64 instructions, so **store-to-load forwarding is needed**.
7. **Load-use of 3 cycles instead of 2 costs 3 to 4 %.** 38 % of the loads are used by the very next instruction.
8. The idealized upper bounds are **5.9 /MHz (TAGE) → 6.8 /MHz (TAGE + fusion)** with `-O2`, and **6.5 → 7.5 /MHz**
   with the most optimization. A real core is expected to lose 10 to 25 % from these (to be calibrated), giving 5.1 to
   5.7 with `-O2` and 5.6 to 6.4 with the most optimization. **Without fusion, 5.0 with `-O2` is borderline and 6.0
   with the most optimization is out of reach.** Fusion is a precondition for a 2-wide core to reach the goals.

---

## 2. Method

### 2.1 Traces
| Item | Content |
|---|---|
| Builds | From `ICOUNT.md`: g14 / o2 / zbsc (the main `-O2`), g14 / sflto / zbsc (most optimization), g13 / o2 / zb (mmRISC-2's condition), g13 / o2 / gc (for the gshare calibration); 10 iterations each |
| Capture | Spike `-l --log-commits`, cut to the timed part (between the two reads of `minstret`) by `capture.py`; the count agrees with `icount.sh` within 1 instruction |
| Analysis | `analyze.py`: the class from the mnemonic of the disassembly, the registers read from the operands, the register written from the commit line; SFB is judged on the static code (objdump) |

### 2.2 Branch predictors (conditional branches, trace-driven)
| Name | Configuration | Size |
|---|---|---|
| bimodal-4K | 4096 2-bit counters | 8 kbit |
| gshare-m2 | mmRISC-2's gshare (decision 63): PHT 8192 × 2 bits, 12 bits of directions XORed into the upper index bits, weakly taken at start | 16 kbit |
| TAGE-S | base 4K + 4 tagged tables × 1K, histories 5 / 12 / 30 / 70 | 62 kbit |
| TAGE-M | base 8K + 6 tagged tables × 2K, histories 4 to 200 | 196 kbit |
| TAGE-L | base 16K + 8 tagged tables × 4K, histories 4 to 640 | 560 kbit |

The predictors are updated immediately after each branch (more optimistic than the delayed updates of real
hardware). Returns are all predicted by the return address stack; other `jalr` by their previous target.

**Calibration**: g13 / o2 / gc has **582,985 conditional branches, exactly the number of mmRISC-2's SIM_SYS** (BENCH.md
section 9). gshare-m2 mispredicts **5.28 %** against mmRISC-2's measured 5.4 % (31,435), 2 % apart. In mmRISC-2 only
branches with a BTB entry enter the history; within that difference the predictor model reproduces the real one.

### 2.3 Limit model (not calibrated; for upper bounds and sensitivities)
An idealized out-of-order core:
- width W (dispatch / commit), ROB R, ports (ALU 2 / LSU 1 / MUL 1)
- latencies: ALU and branches 1, loads 2, multiply 2
- misprediction penalty P (from the execution of the branch to the execution of the first correct-path instruction)
- a dispatch group ends at a taken transfer (no bubble; optionally 1)
- a fused pair takes one dispatch / issue / commit slot and one port, and each half completes with its own latency
  from the issue of the pair (add + load gives the load in 2 cycles, two dependent ALU operations finish in 1)

**Not modelled**: I$ / BTB misses, predictor read latency, issue-queue and PRF capacity, wakeup delay, rename
stalls, fetch alignment of RVC instructions, memory-dependence mispredictions. So the IPC is an upper bound; the
ratio to a real core is set by the next step (the calibrated cycle model).

---

## 3. Results (g14 / o2 / zbsc first; the other builds show the same trends)

### 3.1 Instruction mix (per 1000 instructions)

| | g13 / o2 / zb | g14 / o2 / zbsc | g14 / sflto / zbsc |
|---|---|---|---|
| ALU (of which shift / Zba / Zbb / Zbs / Zicond) | 552 (51 / 51 / 29 / — / —) | 545 (52 / 52 / 30 / 16 / 15) | 531 (49 / 58 / 31 / 18 / 17) |
| Conditional branches (taken rate / backward share) | 183 (57 % / 60 %) | 186 (57 % / 58 %) | 175 (35 % / 34 %) |
| `jal` / `jalr` | 13.2 / 6.7 | 12.5 / 6.9 | 13.6 / 4.4 |
| Loads / stores | 171 / 45 | 174 / 46 | 192 / 51 |
| Multiplies | 29.5 | 30.1 | 33.4 |
| Share of 16-bit (RVC) instructions | 47 % | 46 % | 23 % |
| Taken transfers (branches and jumps) / mean distance | 124 / 8.1 instructions (24.7 B) | 126 / 8.0 instructions (24.5 B) | 79 / 12.6 instructions (44.7 B) |

- 34 % of the instructions are in runs of 8 or fewer before a taken transfer. The front end has to deliver 2
  instructions per cycle without bubbles through a flow that jumps every 8 instructions.
- An instruction is about 3.1 B on average (46 % RVC). 2 per cycle needs 6.2 B per cycle on average, but with
  alignment and runs across taken transfers in mind the fetch stays at 16 B per cycle (as in `STRATEGY.md` section 4).

### 3.2 Dependences
| | g14 / o2 / zbsc |
|---|---|
| Sources produced by the previous 1 / within 2 instructions | 20 % / 39 % |
| First use of a load's value: next / 2nd / 3rd / 4th or later instruction | 38 % / 16 % / 30 % / 16 % |
| Loads reading data stored within the previous 64 instructions | 11 % |

### 3.3 Branch prediction

| Predictor | Miss rate | MPKI (all 10 iterations) | MPKI (last 5) |
|---|---|---|---|
| bimodal-4K | 7.72 % | 14.3 | 14.3 |
| gshare-m2 (mmRISC-2) | 5.05 % | 9.4 | 9.2 |
| TAGE-S (62 kbit) | 0.76 % | 1.41 | 1.07 |
| TAGE-M (196 kbit) | 0.51 % | 0.94 | 0.57 |
| TAGE-L (560 kbit) | 0.53 % | 0.99 | 0.58 |

- More than half of gshare's mispredictions (MPKI 5.0) are in `core_state_transition` (branches on the input
  characters of the state machine). TAGE takes them down to 0.08.
- Most of what TAGE still mispredicts is in `core_list_mergesort` (0.6).
- TAGE-M and TAGE-L are about the same. TAGE-S is MPKI 0.5 above TAGE-M: with a penalty of 10 cycles, 5 cycles per
  1000 instructions (under 1 %).
- The difference between the first and second halves shows the learning in the first iterations. The board runs
  thousands of iterations, so it will be close to the second-half values.

### 3.4 SFB candidates
| | g14 / o2 / zbsc | g14 / sflto / zbsc |
|---|---|---|
| Forward branches over 1 or 2 simple ALU instructions | 4.2 per 1000 instructions (2.2 % of conditional branches) | about 0 |
| Their share of TAGE-L's mispredictions | 1.6 % | 0 % |
| MPKI that SFB would remove | 0.02 | 0 |

### 3.5 Fusion candidates (adjacent, dependent pairs)

| Pair | Per 1000 instructions | Intermediate result dead |
|---|---|---|
| ALU + ALU (the second uses the result) | 63.5 | 89 % |
| ALU + branch (compare / update, then branch on it) | 39.9 | — |
| ALU + load (address calculation) | 31.5 | 33 % |
| Load + load (same base, adjacent) | 1.4 | — |
| Store + store (same base, adjacent) | 1.0 | — |
| `lui + addi`, `auipc + x`, `slli + srli` | about 0 (gone with Zba / Zbb) | |

| Fusion scope | µops / instruction |
|---|---|
| Conservative (address calculation + load, pairs, `lui` / `auipc` forms) | 0.966 |
| + ALU + branch | 0.926 |
| All (+ ALU + ALU) | 0.867 |

### 3.6 Limit model (IPC / CoreMark/MHz)

| Configuration | g13 / o2 / zb | **g14 / o2 / zbsc** | **g14 / sflto / zbsc** |
|---|---|---|---|
| W2 R64 perfect prediction | 1.854 / 5.82 | 1.862 / 5.97 | 1.861 / 6.62 |
| W2 R32 perfect | 1.854 / 5.82 | 1.862 / 5.97 | 1.842 / 6.56 |
| W2 R64 perfect, no group break | 1.944 / 6.10 | 1.951 / 6.25 | 1.930 / 6.87 |
| W2 R64 perfect, load-use 3 | 1.798 / 5.64 | 1.802 / 5.78 | 1.790 / 6.37 |
| W2 R64 perfect, 3 ALUs / 2 LSUs | no change | no change | ≤ +0.4 % |
| W2 R64 gshare-m2 P8 | 1.630 / 5.12 | 1.631 / 5.23 | 1.629 / 5.80 |
| W2 R64 TAGE-M P8 | 1.829 / 5.74 | 1.836 / 5.89 | 1.834 / 6.53 |
| W2 R64 TAGE-L P6 / P8 / P10 | 5.76 / 5.74 / 5.72 | 5.90 / 5.88 / 5.86 | 6.55 / 6.53 / 6.50 |
| W2 R64 TAGE-L P8 + SFB | no change | no change | no change |
| W2 R64 TAGE-L P8, conservative memory dependence | no change | no change | no change |
| **W2 R64 TAGE-L P8, 1 bubble per taken transfer** | 1.493 / 4.69 | **1.493 / 4.79** | 1.605 / 5.71 |
| W2 R64 TAGE-L P8 fusion (conservative) | 1.897 / 5.95 | 1.915 / 6.14 | 1.855 / 6.60 |
| W2 R64 TAGE-L P8 fusion (conservative + ALU + branch) | 1.965 / 6.17 | 1.978 / 6.34 | 1.919 / 6.83 |
| **W2 R64 TAGE-L P8 fusion (all)** | 2.072 / 6.50 | **2.110 / 6.76** | **2.109 / 7.51** |
| same, load-use 3 | 1.984 / 6.23 | 2.017 / 6.47 | 2.015 / 7.17 |
| same, 1 bubble per taken transfer | 1.651 / 5.18 | 1.670 / 5.36 | 1.811 / 6.44 |
| W3 R64 perfect (reference) | 2.327 / 7.31 | 2.362 / 7.57 | 2.373 / 8.45 |
| W4 R96 perfect (reference) | 2.848 / 8.94 | 2.926 / 9.38 | 3.021 / 10.75 |

- The misprediction penalty P from 6 to 10 changes only −0.7 %, because TAGE mispredicts so little.
- 3-wide with perfect prediction gives +27 %: there is plenty of ILP, and what limits 2-wide is the width.

---

## 4. Changes to `STRATEGY.md` (proposal)

| Item | Before | After (proposal) |
|---|---|---|
| Section 2, order of the levers | 1 prediction, 2 penalty, 3 SFB, 4 front end, 5 fusion | **1 prediction (TAGE), 2 zero-bubble front end, 3 fusion (with ALU chaining)**, 4 load-use 2 cycles, 5 penalty. SFB dropped |
| Predictor | TAGE (large) | TAGE-S or TAGE-M (2 to 8 block RAMs); TAGE-L not needed |
| Fusion | "chosen after measuring the fusion rate" | Candidates **ALU + ALU (two stages in a cycle), ALU + branch, address calculation + load**; check early by OOC synthesis that two ALU stages close at 50 MHz |
| LSQ | Start conservative | Conservative is enough (0 % loss); store-to-load forwarding is required |
| Execution units | 2 ALUs + MUL / DIV + 1 LSU | As they are (more do not help) |
| ROB | 48 to 64 | 32 to 64 (32 is about the same in the limit model; decided by the real stalls) |
| Expectation | `-O2` 4.5 to 5.0, most optimization 5.0 to 5.5 | With fusion, `-O2` 5.1 to 5.7, most optimization 5.6 to 6.4 (estimate before calibration) |

---

## 5. Cautions

- The limit model is **not calibrated**. An IPC of 1.86 for 2-wide with perfect prediction comes only from the
  dispatch and commit widths. A real core adds front-end alignment, predictor read latency (a TAGE in block RAM takes
  2 cycles), issue-queue and wakeup constraints and rename stalls.
- "Loses 10 to 25 %" is a placeholder from experience. The next step builds a cycle model that reproduces mmRISC-2's
  8-stage in-order core (CPI 1.103) to pin this ratio down.
- The predictors are trace-driven with immediate updates, so they come out a little better than real hardware
  (speculative history updates and repair, delayed updates).
- Chaining two ALU stages costs timing and PRF read ports (3 sources). Which pairs to take is decided by LUTs and
  timing, not only by the fusion rate.

---

## 6. Next

1. **A calibrated cycle model** (C++): the same traces, with mmRISC-2's 8-stage in-order core and the 2-wide
   out-of-order core in one framework. Once it reproduces mmRISC-2's CoreMark CPI 1.103 and 5.4 % mispredictions,
   compare out-of-order configurations (front-end depth and alignment, TAGE read latency, issue queues, fusion pairs).
2. Early timing: OOC synthesis of two ALU stages in a cycle (for fusion) and of wakeup-select (Vivado, run by the
   author).
3. Measure the resources of NaxRiscv and mmRISC-2 (`STRATEGY.md` section 5.2, step 5).
