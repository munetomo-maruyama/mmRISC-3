# Phase 0-4: RTL blocks of the fusion configuration, and getting ready for out-of-context synthesis

- Date: 2026-10-24
- Purpose: step 3 of `ISSUES.md` section 5. Write in RTL the blocks of the fusion configuration (`Doc/STRATEGY.md`
  section 4) that are loops which must close in one cycle, or whose cost decides the configuration; verify them alone
  and measure size and timing. The author's Vivado decides the timing
- Working files: `RTL/CPU/OOO/` (RTL), `SIM/OOO_UNIT/` (unit tests and bug injection), `FPGA/OOO_OOC/` (Vivado OOC
  synthesis, Yosys estimates)

---

## 1. Summary

1. **The six blocks of the fusion configuration are in RTL, verified by unit tests and bug injection**: two-stage
   ALU, fusion, issue queue, renaming, physical registers, uBTB. Verilator `-Wall` lint gives 0, all six unit tests
   PASS, and all 21 deliberately injected bugs are detected.
2. **The fusion RTL forms the pairs of the model.** With the CoreMark stream through the 4-instruction window it forms
   99.99 % of the model's pairs with `-O2` (415,297 / 415,337) and 411,999 / 412,000 with the most optimization, at
   the model's 0.867 / 0.853 µops per instruction. The window edges and judging load / store pairs by static offsets
   cost nothing.
3. **What the tests found**:
   - One RTL bug: renaming advanced its checkpoint number for a request of an invalid µop.
   - A coding problem: tables indexed by run-time values were written as packed multi-dimensional vectors, which
     became tens of thousands of LUTs in Yosys. Fixed by making them arrays and giving each register-file bank its own
     array (renaming 57k → 9.2k, issue queue 47.7k → 15.6k, register file 94k → 4.9k + LUTRAM, Yosys LUTs).
   - One hole in the tests: whether x0 reads as zero was missed by relying on memory starting at zero. Closed by
     starting everything without a reset at random values.
4. **The main finding: the register-file ports become the largest item of the resources.** If a fused pair reads 3
   sources and writes 2, the file needs 8 to 9 reads and 5 to 6 writes: 17k to 19k LUTs + LUTRAM in Yosys, the whole
   out-of-order budget (16 to 18k) by itself. In the model, **limiting fused pairs to 2 sources costs −1.7 % / −1.1 %**
   (6 read ports); limiting them to 1 write costs −4.4 % / −9.1 %.
5. **Recommendation (fixed at G0)**: fuse pairs of at most 2 sources (6 read ports). Write ports: 5 (2 per pair) as the
   base, down to 3 (1 per pair) if Vivado shows the file too heavy. Every combination stays above the goals in the
   model: 6.6 to 6.9 with `-O2`, 6.9 to 7.5 with the most optimization.
6. **The Vivado results (section 7)**:
   - The issue queue, renaming and fusion closed in one cycle at 50 MHz.
   - The two-stage ALU missed by −0.70 ns and the uBTB by −24.5 ns.
   - The register files had not run, because of a mistake in the batch file.
   - **In size, the measured blocks alone were about twice the budget of the out-of-order part.**
   - Decisions: keep ALU + ALU fusion. Rewrite the ALU and narrow its second stage to the operations that appear in
     CoreMark (no loss). Give the uBTB 16 entries and a parallel choice. The limit of 2 sources is fixed.
   - The number of write ports is decided by rerunning the register files. → **3 write ports** (4,942 physical LUTs,
     against 8,350 for 5), with 5 ports the first thing to buy back if G0 finds room (7.4).
7. **The decisions in the RTL (section 8)**: the ALU rewritten with a narrowed second stage (OOC_ALU2 8,225 → about 4.6k
   in Yosys), fusion limited to 2 sources and 1 write with the second-stage flag (pairs equal to the model's on
   CoreMark), and the uBTB at 16 entries with a parallel choice (5,041 → about 2.3k). All unit tests PASS and all 34
   mutations are detected. Vivado still to confirm.
8. **The issue queue and renaming rebuilt (section 10)**: 2 sources and 1 destination per µop, 64 physical registers.
   In Yosys, renaming about 9.0k → 3.2k and the issue queue about 15.5k → 5.0k. The checkpoints are copied a cycle late
   (no performance lost). In Vivado the ALU (3,133, +0.51 ns), the uBTB (910, +5.10 ns), fusion (215), the issue queue (3,143, +5.07 ns)
   and renaming (2,267, +8.91 ns) all close. The
   register file is 2,503 with 64 registers (about half of 96). The measured blocks total 15,304, inside the
   out-of-order budget (16k to 18k; the ROB, LSU, decode and so on are not counted yet).

---

## 2. The blocks

| Block | What it is | Main parameters |
|---|---|---|
| `OOO_ALU` | Integer ALU: RV64I + Zba / Zbb / Zbs / Zicond (operations and encoding of mmRISC-2's CORE_EXU) | — |
| `OOO_ALU2` | An issue port's ALU: a full OOO_ALU and a narrowed one (section 8) in series (a fused ALU + ALU in one cycle) + the branch comparison (alone, or against the first result for ALU + branch) | — |
| `OOO_FUSE` | 4 decoded instructions → the next 2 µops (paired greedily from the oldest) | `LEVEL` (1 to 3), `SRC2` (section 8) |
| `OOO_IQ` | Unified issue queue: 3 sources (2 and 1 destination from section 10), 2 in / 3 out, 1-cycle wakeup-select, age matrix, latency-2 and external wakeups | `N`=16, `TAGW`=7 (6 from section 10) |
| `OOO_RENAME` | 2 µops per cycle, 3 sources and 2 destinations (2 and 1 from section 10), RAT, free list, busy bits, in-group dependences, checkpoints | `NREG`=96 (64 from section 10), `NCKPT`=8 |
| `OOO_PRF` | 96 × 64, LUTRAM per write bank + LVT | `NW`, `NR` |
| `OOO_UBTB` | Fully associative next-line predictor, next fetch address in one cycle | `NE`=32 (16 from section 8, partial tag `TW`=12) |

The registered harnesses for OOC synthesis (`FPGA/OOO_OOC/rtl/OOC_WRAP.sv`): `OOC_ALU2` builds the 1-cycle loop as it is
(result registers → 5-input bypass → two-stage ALU → result registers); `OOC_FUSE`, `OOC_PRF` and `OOC_RENAME` put
flip-flops on their inputs and outputs.

---

## 3. Verification

| Test | How | Result |
|---|---|---|
| `tb_alu2` | Against a reference written from the specification (RV64I / Zba / Zbb / Zbs / Zicond), random operations, operand selections and values (biased to the edges) | 2,000,000 vectors, 0 mismatches |
| `tb_fuse` | Against a reference of the rules, random; plus the CoreMark stream through the window, against the model | 1,000,000 groups, 0 mismatches; pairs 99.99 % of the model's |
| `tb_prf` | Up to 5 writes to different registers and 8 reads per cycle, against an array | 2,400,000 reads, 0 mismatches |
| `tb_rename` | Against a reference (RAT, free list, busy, checkpoints) with commits, write-backs and restores after mispredictions | 400,000 cycles, 596,069 µops, 25,489 restores, 0 mismatches |
| `tb_iq` | An account of when values are usable kept independently of the queue; every cycle "each port issues the oldest ready µop" (wakeup time, back-to-back issue, oldest first, no idle port while a µop is ready) | 300,000 cycles, 114,649 µops, 147 flushes, 0 mismatches |
| `tb_ubtb` | Against a reference table, random updates, redirects and stalls | 500,000 cycles, 0 mismatches |
| `mutate.py` | 21 deliberate one-line breaks of the RTL (2 to 4 per block); every line of the report read | **All 21 detected** (no NOT DETECTED / NOT APPLIED) |

Writing the tests also turned up 4 mistakes on the testbench side (the 12-bit mask of a reference, the fall of the
reset not being an edge in Verilator, outputs read after the clock, reallocating a tag a source still waits for). Each
was traced cycle by cycle to make sure the RTL was not at fault before fixing it.

---

## 4. First estimate of size (Yosys, `FPGA/OOO_OOC/output/yosys_size.txt`)

Yosys (`synth_xilinx`) values. **The ratio to Vivado varies a lot by module, 0.4 to 1.4** (`REDUCE.md` section 3;
mmRISC-2's CORE_EXU is 0.44), and there is no delay; so these are for the order of size and for comparing blocks.

| Block | LUT | LUTRAM | FF | Longest path (cells) | Reading |
|---|---|---|---|---|---|
| OOC_ALU2 (two-stage ALU + bypass) | 8,225 | 0 | 682 | 1,423 | About 3.6k with CORE_EXU's ratio 0.44. The long path is the 64-step loops of clz / ctz / cpop (written as in mmRISC-2), which Yosys lays out as they are; Vivado fit the same code into 50 MHz in mmRISC-2 |
| OOC_FUSE | 207 | 0 | 158 | 22 | Small and shallow |
| OOC_RENAME | 9,168 | 0 | 2,884 | 146 | Most FFs are the checkpoints (8 × 224 bits) |
| OOO_IQ | 15,595 | 0 | 1,056 | 713 | **Large**; to be checked in Vivado; ways to reduce in section 7 |
| OOO_UBTB | 5,041 | 0 | 2,635 | 390 | 32-entry fully associative; the model loses only −0.9 % without a uBTB, so it goes if heavy |
| OOC_PRF writes 3 / reads 8 | 4,936 | 3,456 | 976 | 24 | |
| OOC_PRF writes 5 / reads 8 | 11,006 | 5,760 | 1,216 | 30 | |
| OOC_PRF writes 6 / reads 9 | 12,009 | 6,912 | 1,359 | 29 | The fusion configuration as it is |
| **OOC_PRF writes 3 / reads 6** | 3,600 | 2,304 | 834 | 21 | Pairs limited to 2 sources and 1 write |
| **OOC_PRF writes 5 / reads 6** | 6,899 | 3,840 | 1,074 | 24 | Pairs limited to 2 sources (recommended base) |

- The register-file banks carry `ram_style = "distributed"`. Without it, the tool chose block RAM when the read address
  is registered and used 24 RAMB36 (only 26.5 tiles are free).
- Estimated from RAM64M (4 LUTs for 64 × 1 bit with 3 reads), the register file in Vivado is about 4k LUTs for writes 3
  / reads 6, about 6.5k for writes 5 / reads 6, and about 11.5k for writes 6 / reads 9 (LUTRAM included).

---

## 5. Register-file ports against performance (cycle model)

`ooo` of `Plan/model` (with `fuse_2src` and `fuse_1w` added). CoreMark/MHz.

| Fusion limit | `-O2` | Most optimization | Read / write ports |
|---|---|---|---|
| No fusion | 6.07 | 6.57 | 6 / 3 |
| Fusion (no limit) | 7.06 | 7.59 | 8 to 9 / 5 to 6 |
| **Up to 2 sources** | **6.94** (−1.7 %) | **7.51** (−1.1 %) | **6 / 5** |
| Up to 1 write | 6.75 (−4.4 %) | 6.90 (−9.1 %) | 8 to 9 / 3 |
| Up to 2 sources and 1 write | 6.62 | 6.87 | 6 / 3 |
| Up to ALU + branch, 2 sources, 1 write | 6.37 | 6.83 | 6 / 3 |

The source limit cuts the read ports by a third at almost no cost, while the write limit loses 9 % with the most
optimization. So the reasonable course is to **take the 2-source limit and decide the write ports from Vivado**.

---

## 6. The Vivado runs asked of the author

```
cd FPGA\OOO_OOC
synth_ooo.bat
```

It runs `OOC_ALU2`, `OOC_FUSE`, `OOC_RENAME`, `OOO_IQ`, `OOO_UBTB` and five register files (writes 3 / reads 8, 5 / 8,
6 / 9, 3 / 6, 5 / 6) out of context at 50 MHz through place and route. The results are in `output\<top>\summary.txt`
(LUTs, WNS, register-to-register slack and logic levels) and `timing_reg2reg.rpt`.

| Result | What it decides |
|---|---|
| Register-to-register slack of OOC_ALU2 | Whether chaining two ALU stages (chain = 1) closes at 50 MHz. If not: narrow the second stage's operations (clz / ctz / cpop / rotates / orc.b / rev8 never appear as the second half of a fused pair), or drop ALU + ALU fusion and keep ALU + branch and address calculation + load (`MODEL.md`, fusion 2: −6 %) |
| LUTs and slack of OOO_IQ | Whether wakeup-select closes in one cycle and fits the budget |
| LUTs of the five OOC_PRF | The number of write ports (detail of D-4) |
| OOC_RENAME, OOO_UBTB, OOC_FUSE | Whether they close in one cycle; the uBTB goes if heavy |

---

## 7. Vivado results and decisions (2026-10-24)

The results of `synth_ooo.bat` in the author's Vivado (`FPGA/OOO_OOC/output/<top>/summary.txt`, `timing_reg2reg.rpt`,
`utilization.rpt`). 50 MHz (20 ns), out of context, after place and route.

### 7.1 Results

| Block | LUT (Vivado) | FF | Register-to-register slack | Logic levels | Ratio to Yosys | Verdict |
|---|---|---|---|---|---|---|
| OOC_ALU2 | 7,879 | 705 | **−0.696 ns** | 25 | 0.96 | Does not close; large |
| OOC_FUSE | 172 | 158 | +10.606 ns | 11 | 0.83 | Closes |
| OOC_RENAME | 6,098 | 2,830 | +4.793 ns | 9 | 0.67 | Closes; large |
| OOO_IQ | 6,200 | 1,056 | +2.370 ns | 16 | 0.40 | Closes; large |
| OOO_UBTB | 3,132 | 2,648 | **−24.524 ns** | 65 | 0.62 | Does not close |
| OOC_PRF (5 configurations) | 4,942 to 14,271 | 946 to 1,668 | +1.77 to +6.23 ns | 0 to 1 | 0.64 to 0.84 | Closes (7.4) |

- **The LUTs are physical LUTs**: "Total LUTs" of the hierarchical utilization report, LUT RAM included, two LUTs packed
  in one LUT6_2 counted once. This is how mmRISC-2's budget (`ISSUES.md` section 2) counts. The "LUT" of `summary.txt`
  is the number of LUT cells and leaves LUT RAM out, which matters for the register files (3,619 against 8,350 for 5
  writes / 6 reads). `synth_ooo.tcl` gives physical LUTs too from the next run on.

- **The register files did not run because of a mistake in `synth_ooo.bat`.** `vivado` is itself a batch file, so
  calling it without `call` ends the calling batch after the first call outside a loop. Fixed with `call`, and
  `synth_ooo.bat prf` added to run the register files only.
- OOO_IQ's WNS (+0.085 ns) is on a path through the input / output delays the harness assumes (6 ns each), not a real
  path. Register to register it is +2.37 ns.
- The ratio to Yosys differs a lot between blocks, 0.40 to 0.96 (the same tendency as 0.4 to 1.4 in `REDUCE.md`).

### 7.2 Two-stage ALU (OOC_ALU2)

**Worst path**: the second stage's result register → bypass → first stage (a shift, about 8.7 ns with the bypass) →
the second stage's comparison (8 CARRY4) → a 64-bit select with fan-out 129 (min / max) → the result select → the
second stage's result register. The second stage alone takes about 10.8 ns.

**Size**: the first OOO_ALU is 4,663 LUTs and the second 3,095. That is 2 to 3 times the whole of mmRISC-2's CORE_EXU
(1,670). OOO_ALU writes a separate unit for each operation: add and subtract, the comparisons (slt / min / max), the
left and right shifts and the rotates, and clz / ctz / cpop are all independent, and became circuits as they are.

**The operations that appear as the second half of fused pairs in CoreMark** (fused pairs counted on the instruction
streams of `Plan/trace`):

| Build | ALU + ALU pairs | Second-half operations (most frequent first) |
|---|---|---|
| `-O2` | 193,884 | bexti, xor, andi, addw, addiw, sh2add.uw, or, srliw, sh1add.uw, zext.h, sext.h, mv, add, subw |
| Most optimization | 268,882 | xor, andi, czero.eqz, addw, sh2add.uw, sh1add.uw, srliw, or, sext.h, zext.h, bexti, mv, addiw, subw |

slt / sltu, min / max, clz / ctz / cpop, the rotates and orc.b / rev8 never appear in the second stage. slt and
czero.eqz do appear in the first stage, so the first stage stays full.

**Decisions**:

1. **Keep ALU + ALU fusion (chain = 1).** Going down to fusion 2 (up to ALU + branch) costs −6 %.
2. **Narrow the second stage.** It keeps only add / subtract (with the .w forms), sh1add to sh3add (with .uw), the
   logic operations (with immediates), bext / bexti, zext.h / sext.h / sext.b, czero.eqz / czero.nez and the shifts by
   an immediate. Every second half in CoreMark is in this set, so nothing is lost. Fusion does not put an operation
   outside the set in the second stage (`OOO_FUSE` gets a "can be second" flag from the decoder).
3. **Rewrite OOO_ALU.** As CORE_EXU does, one adder is shared by subtraction, the comparisons and min / max, and one
   shifter (a funnel shifter) does the left and right shifts, the rotates and bext. A comparison then comes from the
   adder's carry, which also removes the compare-then-select in series. The target is at most 2.5k LUTs per port for
   both stages.
4. After the rewrite, the timing and size are checked again in Vivado.

### 7.3 Issue queue (OOO_IQ)

**Decisions**:

- **Wakeup-select of 16 entries closes in one cycle** (+2.37 ns, 16 levels). Go on with this scheme.
- **Its 6.8k is large for the budget.** Reduce it to around 4k with the means of section 8: reading the issued µop by
  a one-hot AND-OR, fewer wakeup tag buses, and splitting the queue.

### 7.4 Register file (OOC_PRF)

The rerun with `synth_ooo.bat prf` (physical LUTs):

| Writes / reads | LUT | of it LUT RAM | FF | Register-to-register slack | Estimate of section 4 |
|---|---|---|---|---|---|
| 3 / 8 | 6,455 | 4,128 | 1,116 | +6.23 ns | — |
| 5 / 8 | 10,657 | 6,880 | 1,456 | +2.18 ns | — |
| 6 / 9 | 14,271 | 9,288 | 1,668 | +1.77 ns | about 11.5k |
| **3 / 6** | **4,942** | 3,096 | 946 | +2.70 ns | about 4k |
| 5 / 6 | 8,350 | 5,160 | 1,246 | +2.21 ns | about 6.5k |

- Every configuration closes at 50 MHz. The worst path goes into a LUT RAM write address (0 to 1 logic levels).
- 20 to 30 % above the estimates of section 4. The amount of LUT RAM is set by the number of write banks and by one copy
  for every 3 read ports.
- Going from 8 reads to 6 saves 2.3k with 5 writes and 1.5k with 3 writes. That alone more than pays for the limit of 2
  sources (−1.7 % / −1.1 %).

**Decisions**:

- **Fused pairs of at most 2 sources is fixed.** That is 6 read ports, at a cost of −1.7 % / −1.1 % (section 5).
- **3 write ports (1 write per pair).**
  - The difference from 5 ports is 3.4k LUTs, about a fifth of the out-of-order budget (16k to 18k).
  - The performance difference is −4.7 % / −8.2 % (with the sizes of the fusion configuration: ROB 32, IQ 16, LQ / SQ
    12, 8 checkpoints, 16-entry uBTB, at most 2 sources: 6.91 / 7.45 → 6.59 / 6.84). With 3 ports the goals (5.0 / 6.0)
    are still exceeded.
  - With one write per pair, renaming and the issue queue need only one destination per µop, and both can shrink
    further for it (section 9).
  - **64 physical registers are then enough**: 32 architectural + ROB 32 × one per µop, instead of the 96 needed with 2
    writes per pair. 64 fits the 64-deep LUT RAM exactly (96 splits into 64 + 32), and the tags go from 7 to 6 bits. The
    register file should shrink further; 8.4 measures it.
- **5 ports become the first thing to buy back if G0 finds room in the budget.** At about +1.4 % / +2.6 % per 1k LUTs (compared
  at 96 physical registers) it is the most efficient of the remaining options. Room freed by a multi-cycle FPU (D3) or similar goes here first.

### 7.5 Renaming (OOC_RENAME) and fusion (OOC_FUSE)

- **Renaming closes in one cycle** (+4.79 ns). **It is large at 6.9k.** Its breakdown (checkpoints of 8 × 32 × 7 bits
  and their restore select, the free list, busy bits) is not measured separately yet; it is measured by hierarchy, then
  reduced. Fewer checkpoints cost −0.9 % / −0.9 % for 8 → 6 and −4.3 % / −4.1 % for 8 → 4 (16-entry uBTB, at most 2
  sources). The number stays 8; the reduction comes from the coding.
- **Fusion is fine at +10.6 ns and 186 LUTs.**

### 7.6 uBTB (OOO_UBTB)

**Why it missed so badly**: choosing, among the entries that hit, the first one in the block that is taken was written
as a loop over the 32 entries in turn, each comparing its offset with the best so far. The tool made it a chain of 32
comparisons in series (65 levels).

**Correcting an earlier judgment**: "without a uBTB it is only −0.9 %, so drop it if heavy" was a number without
fusion. With fusion the back end is faster, and the front end weighs more. The model rerun with at most 2 sources:

| uBTB | `-O2` | Most optimization |
|---|---|---|
| None | 6.61 (−4.8 %) | 7.35 (−2.1 %) |
| 4 | 6.78 | 7.45 |
| 8 | 6.87 (−1.0 %) | 7.47 |
| **16** | **6.92 (−0.2 %)** | **7.50 (−0.1 %)** |
| 32 | 6.94 | 7.51 |

**Decisions**:

- **Keep the uBTB, with 16 entries.**
- **Make the choice parallel.** For each of the 8 positions in the block, OR the "hit and taken" of the entries;
  choose the position with an 8-bit priority select; read the target with a one-hot AND-OR.
- **Use partial tags (about 12 bits).** The prediction is checked at F2, so a partial tag is enough.
- The size target is at most 1k LUTs.

### 7.7 Outlook for the budget

| Block | Vivado (this run) | Target after the decisions |
|---|---|---|
| ALUs, 2 ports (2 stages each) | 15,758 | at most 5k |
| Issue queue | 6,200 | around 4k (less with one destination) |
| Renaming | 6,098 | after measuring (at most 5k with one destination) |
| uBTB | 3,132 | at most 1k |
| Fusion | 172 | 0.2k |
| Register file | 4,942 (3 writes) to 8,350 (5 writes) | **at most 4.9k (3 writes; less with 64 registers)** |
| Total | 31.4k + register file (36.3k to 39.7k) | **about 20k** |

- **The budget of the out-of-order part is 16k to 18k** (up to group A of `REDUCE.md` section 2). It also has to hold
  the ROB, the LSU, the LQ / SQ, decode and the front end. The blocks measured this time were already about twice the
  budget by themselves.
- Even reduced to the targets, the measured blocks alone go a little over the budget. **G0 will probably have to
  revisit the budget itself.** The main candidates:
  - Return the FPU to multi-cycle (D3, "to be reconsidered depending on logic size"; the FPU is 8.8k)
  - Groups B / C of `REDUCE.md`
- The OOC numbers are for each block alone; built into the whole, optimization across boundaries can make them larger
  or smaller.

---

## 8. The decisions put into the RTL (2026-10-24)

Of the decisions of section 7, three are in the RTL: the ALU, fusion (2 sources, 1 write) and the uBTB. The reductions of the issue queue and
of renaming are not in yet.

### 8.1 Changes

| Block | Change |
|---|---|
| OOO_ALU | Rewritten. One adder (used by add / sub / sh*add; slt / sltu / min / max come from its carry). One funnel shifter for the right shifts, the rotates and bext; the left shifts and rol go through the same shifter with the bits reversed. clz / ctz as a tree over bytes (clz is ctz after a reversal), cpop as a tree of adders. The result is chosen by an AND-OR of the units. The parameter `FULL` = 0 gives the narrowed form for the second stage |
| OOO_ALU2 | The second stage is `FULL = 0`. The branch comparison comes from one subtraction (signed and unsigned both) |
| OOO_FUSE | An input `alu2ok` (whether the operation can be the second half of ALU + ALU; the decoder gives it) a parameter `SRC2` (a pair reads at most 2 sources) and `W1` (a pair writes at most 1 register, 7.4) |
| OOO_UBTB | 16 entries, a 12-bit partial tag (the low 12 bits of the block address XOR the next 12), and a parallel choice. Different blocks with the same partial tag share an entry. An update looks for the existing entry before it inserts one, so no two entries ever have the same tag and position |

**The second stage is narrowed further than the plan of 7.2.** It keeps add / subtract (with .w), sh1add to sh3add
(with .uw), the logic operations, srl, sext.b / sext.h / zext.h, czero.eqz / czero.nez and bext. The only shift
CoreMark puts in the second stage is srliw, so sll and sra are out too. That takes the bit reversal and the sign fill
of the shifter out of the second stage.

### 8.2 Verification

- **Unit tests**: all six PASS.
  - tb_alu2 gives the second stage only its narrowed operations.
  - tb_fuse's reference has the second-stage flag and the rules of at most 2 sources and at most 1 write.
  - tb_ubtb's reference uses the partial tag. A quarter of the addresses are moved to another block with the same
    partial tag, so that aliases meet in the table.
- **Fusion matches the model.** On the CoreMark streams the number of pairs matches the model:
  - at most 2 sources: `-O2` 363,593 / 363,633, most optimization 382,436 / 382,436
  - at most 2 sources and 1 write: `-O2` 276,058 / 276,058, most optimization 135,776 / 135,776
  - These are also the numbers of pairs that the cycle model's `fuse_2src` and `fuse_1w` (`Plan/model`) form. The
    second-stage flag loses no pair.
- **Bug injection**: 13 mutations added for the new parts, 34 in all, every one detected. One (M6) first came out NOT
  APPLIED, because adding `alu2ok` changed the text it rewrites; its text was fixed and it was run again.

### 8.3 Size (Yosys)

| Block | Before | Now |
|---|---|---|
| OOC_ALU2 | 8,225 (Vivado 7,879) | **about 4.6k** |
| 　of it the full OOO_ALU (alone) | (Vivado 4,663) | about 2.2k |
| 　of it the second-stage OOO_ALU (alone) | (Vivado 3,095) | about 0.9k |
| OOO_UBTB | 5,041 LUT / 2,635 FF (Vivado 3,132 LUT) | **about 2.2k to 2.3k LUT / 970 FF** |
| OOC_FUSE | 207 (Vivado 172) | about 0.28k |

- **Yosys's numbers vary by 5 to 7 % between runs of the same RTL** (uBTB 2,197 and 2,344, renaming 9,304 and 8,917).
  They are taken as rough figures.

- About 1.4k of OOC_ALU2's 4.6k are outside the ALUs (the bypass, the operand selection, the branch comparison).
- For reference, mmRISC-2's CORE_EXU is about 3.8k in Yosys (1,670 in Vivado, ratio 0.44). The full OOO_ALU is smaller
  than that in Yosys.
- The uBTB's Yosys number probably includes a feedback select for each of the 912 bits of its table (Vivado uses clock
  enables). For the previous version, Vivado came to 0.63 times Yosys.
- **Yosys's "longest path" means nothing for blocks with loops (OOC_ALU2, OOO_UBTB, OOO_IQ).** After `synth_xilinx`,
  `ltp` does not take the flip-flops (FDRE / FDCE) as flip-flops and follows the loops (it warns "Detected loop").
  Timing is judged from Vivado only.

### 8.4 The Vivado runs asked of the author

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_ALU2
synth_ooo.bat OOO_UBTB
synth_ooo.bat OOC_FUSE
synth_ooo.bat OOC_PRF 20.0 1 "NREG=64 NW=3 NR=6"
```

What the runs should show:

| Result | What it decides |
|---|---|
| Register-to-register slack and LUTs of OOC_ALU2 | Whether the rewritten ALU closes the two-stage chain at 50 MHz, and fits the size target (at most 2.5k per port for both stages) |
| Register-to-register slack and LUTs of OOO_UBTB | Whether the parallel choice closes in one cycle, and fits the size target (at most 1k) |
| LUTs and slack of OOC_FUSE | That counting the sources and the writes costs nothing that matters |
| LUTs of OOC_PRF (64 registers, 3 writes / 6 reads) | The size of the register file with 64 physical registers (4,942 with 96) |

---

## 9. Next

1. **Author**: rerun the three blocks of 8.4 (the register file is settled in 7.4). → 10.5
2. **RTL**:
   - Give renaming and the issue queue 2 sources and 1 destination per µop (what at most 2 sources and 1 write per pair
     imply; the issue queue is built with 3 sources now), with 64 physical
     registers (6-bit tags), and build the register file with 3 write ports. → section 10
   - Reduce the issue queue (one-hot AND-OR read, fewer wakeup buses, consider splitting the queue).
   - Measure the breakdown of renaming by hierarchy, then reduce it.
   - Redo the unit tests and bug injection for each, and check them in Vivado.
3. **The G0 specification**: freeze the micro-architecture including the scope of this RTL (step 5 of `ISSUES.md`
   section 5). The budget revision (including D3) is decided there too.

---

## 10. The issue queue and renaming rebuilt (2026-10-24)

What 7.4 implies (a pair reads at most 2 sources and writes at most 1 register) is now in the issue queue and
renaming: 2 sources and 1 destination per µop, and 64 physical registers (6-bit tags).

### 10.1 Renaming (OOO_RENAME)

| | Before | Now |
|---|---|---|
| µop | 3 sources, 2 destinations | 2 sources, 1 destination |
| Physical registers / tag | 96 / 7 bits | 64 / 6 bits |
| RAT reads / writes | 6 + 4 / 4 | 4 + 2 / 2 |
| Free list | 64; 4 taken and 4 given back a cycle | 32; 2 taken and 2 given back |
| Write-backs that clear busy bits | 5 | 3 (the register-file write ports) |
| Checkpoints | 8 × 224 bits, each written with a choice between the RAT after µop 0 and after µop 1 | 8 × 192 bits, copied a cycle late from the RAT flip-flops (no choice), plus 11 bits to undo µop 1 |

**The checkpoints are copied differently**:

- **Before**: each of the 1,792 checkpoint bits chose between the RAT after µop 0 and the RAT after µop 1.
- **Now**: the RAT after the group (what the RAT flip-flops hold in the next cycle) is copied a cycle late. Every bit
  takes the same data, so an enable is enough. A checkpoint of µop 0 also keeps µop 1's destination and its old
  mapping, and a restore undoes it.
- **Condition**: a checkpoint is not restored in the cycle right after its µop is renamed. The pipeline always meets
  this, with dispatch, issue and execution in between.
  - The test resolves many transfers at that earliest point, 2 cycles after renaming (22,916 times).
  - It was also checked that the test fails if a transfer may be resolved 1 cycle after (68,492 mismatches).
- **Not taken**: "at most one checkpoint a cycle". In the model it costs −1.7 % / −2.0 % (`ck1` of `Plan/model`).
  Taking no checkpoint for jal does not change that (`ck_jal`; CoreMark's inner loops have hardly any jal).

### 10.2 Issue queue (OOO_IQ)

| | Before | Now |
|---|---|---|
| µop | 3 sources, 2 destinations | 2 sources, 1 destination |
| Wakeup tag buses | 14 (3 ports × 2 × now and delayed, external 2) | 6 (port 0 now, port 1 now, port 0 delayed, port 2 delayed, external 2) |
| Source comparators | 16 × 3 × 14 = 672 | 16 × 2 × 6 = 192 |
| Reading the issued µop | encode to a number, then select | AND-OR of the one-hot grants |

**Why fewer buses are enough**: the two rules below go into the specification as rules of dispatch. The µops of the
test keep them too.

- Port 1 (ALU1) issues latency 1 only. A latency-2 µop (a multiply) is dispatched as "ALU0 only".
- Port 2 (LSU) writes a register only for a load (latency 2). A store writes none.

### 10.3 Verification

- **Unit tests**: all six PASS.
  - tb_rename and tb_iq were rewritten for 2 sources, 1 destination and 6-bit tags.
  - With only 64 tags, tb_iq gives a tag out again 4 cycles after its µop leaves the queue (counted from the
    announcement for a µop answered from outside), longer than the delayed wakeup bus (1 cycle).
- **Bug injection**: the 8 existing mutations of renaming and the queue moved to the new RTL, and 5 added for the new
  parts. All 13 are detected (39 in all).

### 10.4 Size (Yosys)

| Block | Before | Now |
|---|---|---|
| OOC_RENAME | about 9.0k LUT / 2,884 FF (Vivado 6,098) | **3,216 LUT / 2,289 FF** |
| OOO_IQ | about 15.5k LUT / 1,056 FF (Vivado 6,200) | **5,009 LUT / 702 FF** |

### 10.5 The Vivado results of 8.4

| Block | Before (LUT / register-to-register slack) | Now | Verdict |
|---|---|---|---|
| OOC_ALU2 | 7,879 / −0.696 ns | **3,133 / +0.512 ns** (36 levels) | Closes |
| OOO_UBTB | 3,132 / −24.524 ns | **910 / +5.100 ns** (13 levels) | Closes; within the target (at most 1k) |
| OOC_FUSE | 172 / +10.606 ns | **215 / +10.125 ns** | Fine |
| OOC_PRF (64 registers, 3 writes / 6 reads) | 4,942 (96 registers) / +2.697 ns | **2,503 / +7.917 ns** (LUT RAM 1,548) | Closes; about half of 96 registers |

- **The two-stage ALU closes at 50 MHz.** The worst path runs into the adder of the second stage (19 CARRY4).
- **The ALU's size is 0.6k over the target (at most 2.5k per port for both stages).** About 1k of the 3,133 is
  outside the ALUs (bypass, operand selection, branch comparison; estimated from the Yosys ratio). The next candidate
  is E3 of REDUCE.md (an asymmetric ALU, a simpler first stage in ALU1). But the first halves of fused pairs are often
  Zbb / Zbs / Zicond (srliw, bexti, zext.h, czero.eqz and so on), so the model decides first.
- The OOC_FUSE harness did not connect the `alu2ok` input added in section 8. It was fixed before this run (the 215
  LUTs include `alu2ok`).
- Vivado / Yosys: OOC_ALU2 0.68, OOO_UBTB 0.41, OOC_FUSE 0.75.
- The 64-register file is about half of the 96-register one because it fits the 64-deep LUT RAM in one level (96 is
  64 + 32, two levels), and the select behind them goes away.

### 10.6 Outlook for the budget (updated)

| Block | At 7.7 | Now | From |
|---|---|---|---|
| ALUs, 2 ports | 15,758 | **6,266** | Vivado |
| Issue queue | 6,200 | **3,143** | Vivado (10.8) |
| Renaming | 6,098 | **2,267** | Vivado (10.8, with the harness) |
| uBTB | 3,132 | **910** | Vivado |
| Fusion | 172 | **215** | Vivado |
| Register file | 4,942 to 8,350 | **2,503** | Vivado |
| Total | 36.3k to 39.7k | **15,304** | all Vivado |

- The measured blocks total 15.3k (15,304), inside the out-of-order budget (16k to 18k).
- But the budget also has to hold the ROB, the LSU, the LQ / SQ, decode and the front end, none of which is written yet,
  and only 0.7k to 2.7k is left for them. Revisiting the budget at G0 (7.7) is still needed.

### 10.7 The Vivado runs asked of the author

```
cd FPGA\OOO_OOC
synth_ooo.bat OOO_IQ
synth_ooo.bat OOC_RENAME
```

### 10.8 The Vivado results of the issue queue and renaming

| Block | Before (LUT / register-to-register slack) | Now | Verdict |
|---|---|---|---|
| OOO_IQ | 6,200 / +2.370 ns (16 levels) | **3,143 / +5.065 ns** (12 levels) | Closes; within the target (around 4k) |
| OOO_RENAME (no harness) | 6,098 / +4.793 ns (9 levels, with the harness) | 2,271 / +9.598 ns (2 levels), 2,151 FF | Closes |
| **OOC_RENAME (with the harness)** | as above | **2,267 / +8.912 ns** (4 levels), 2,296 FF | Closes; within the target (at most 5k) |

- **Issue queue**: the worst wakeup-select path (from one entry's ready bit to another's) has 12 levels and +5.07 ns
  of slack, 2.7 ns more than the previous version. The WNS (+0.201 ns) is on a path through the input / output delays
  the harness assumes (6 ns each), not a real path.
- **Renaming ran without its harness** (`OOO_RENAME`; 10.7 asked for `OOC_RENAME`, which registers the inputs and
  outputs).
  - The LUT count holds as it is: the harness adds only flip-flops.
  - The worst register-to-register path is +9.60 ns (the write enable of a checkpoint, 2 levels).
  - The worst path overall (+0.896 ns) is combinational from input to output (`in_src` → RAT → busy → `out_rdy`, 7
    levels). It fits in the 8 ns left after the 6 ns input and output delays. In the core this path sits between
    flip-flops and has a whole cycle (20 ns), so it closes with ample margin.
- **The rerun with the harness (`OOC_RENAME`) is the last row of the table.** 2,267 LUTs, about the same as without the
  harness (the 4 of difference is placement); 145 more flip-flops, those of the harness.
  - The worst register-to-register path is +8.912 ns, the restore (`restore_id` → checkpoint select → RAT, 4 levels).
  - The input-to-output path (the RAT and busy reads) is register to register inside the harness and is not among the
    10 worst (more than +9 ns of slack).
  - The totals below use 2,267, with the harness.
- Vivado / Yosys: OOO_IQ 0.63, OOO_RENAME 0.71.
- Against the first versions: the issue queue 6,200 → 3,143 (−49 %), renaming 6,098 → 2,271 (−63 %). Most of it comes
  from 2 sources and 1 destination per µop and from 64 physical registers.


---

## 11. LSU (step 2 of Phase 1, 2026-10-25)

The first block of step 2 of `Doc/UARCH.md` section 8. The LSU (LQ / SQ and forwarding), the block whose estimate had
the widest spread, is written, verified by a unit test and bug injection, and has its Vivado scripts.

### 11.1 The block (`RTL/CPU/OOO/OOO_LSU`)

| Item | Content |
|---|---|
| Pipeline | E: address calculation (base + immediate), the misaligned check; a store writes its SQ entry and is complete, a load sends its request to the D$. M: the D$ answer, the search of the SQ (the youngest older store to the same 8-byte word), the result chosen and aligned. WB: the result register (2 cycles after issue as the dependents see it) |
| LQ / SQ | 12 / 12. Allocated in order at dispatch (up to 2 a cycle). The LQ is freed at commit, the SQ when a committed store has been written to the D$. The tails after each slot are given out for the checkpoints |
| Forwarding | The data of the youngest older matching store when it covers the load. When it does not (a partial overlap), the load waits and is tried again from the LQ |
| Ordering | Conservative: a load uses D$ data only when every older store has its address. `lsu_st_known` (per LQ entry) lets the issue queue hold loads until then, and M checks again |
| Misses | The load waits for the fill (`dc_fill_*`) and writes back late (`wb_late`: it needs a wakeup). A fill arriving while the write port is taken is buffered (one) |
| Cancelling speculative wakeups | A load from port 2 that cannot give its result in its expected cycle (WB) raises `ld_cancel` with its tag in M. How the dependents are held back (the replay policy) is outside this block and decided when the core is put together (11.4) |
| Recovery | `restore` sets the tails of a checkpoint. `flush_all` goes to the committed state (the LQ empty, the SQ down to its committed stores, which still drain). A load in M in a cycle of recovery waits and is tried again if its entry stays |
| D$ | The port is abstract (tagged requests and fills, a write port); the adapter to mmRISC-2's D$ is outside. The adapter drops the answers of the fills of the LQ entries in `dc_kill` (freed entries; the line is still filled) |

**No store drains in a cycle with a load in E.** That load reads the D$ now and searches the SQ next cycle, so the store
must still be in the SQ then (the block RAM reads first, so a store written in the same cycle is not read).

### 11.2 Verification (`SIM/OOO_UNIT/tb_lsu.cpp`)

- **The test bench plays the rest of the core.** It sends a random stream of loads, stores, branches and other µops in
  program order to a few 8-byte words (loads and stores meet often). It dispatches up to 2 a cycle while the queues and
  a 24-entry window have room, issues to port 2 in random order (a load mostly after `lsu_st_known`, now and then
  earlier to exercise the LSU's own wait), and commits in order. The D$ model answers hit or miss at random, fills after
  a few cycles, and takes stores (now and then not). Branches resolve at random, some mispredicted (restore to the
  checkpoint); a misaligned access is an exception that does `flush_all` at the head.
- **Checked**:
  - every load's value: the committed memory with the older uncommitted stores applied in program order (flushed
    stores never count)
  - a load completes once (on time or late; a misaligned one with an exception and no write)
  - `ld_cancel` is raised exactly when a load from port 2 gives no result in its expected cycle
  - the stores reach the D$ in commit order with their data and byte mask
  - `lsu_st_known` is never set for a load with an older store whose address is not known
  - no deadlock
- **Result**: all PASS on 7 seeds (300,000 cycles each, 2.1 million in all). On one seed: 76,407 loads (21,918 of them
  late), 80,510 stores, 32,432 cancels, 6,052 restores, 3,475 flushes.
- **RTL bugs the test found** (all fixed):
  1. Counting from the SQ head, `head + k` was computed at the width of an index (4 bits) and wrapped at 16 (the queue
     is 12)
  2. A load in M in a cycle of recovery was neither completed nor kept, so an older load that survives the recovery
     never completed
  3. The D$ fill of a flushed load was taken by the owner of the same LQ entry two allocations later (the 1-bit epoch
     had come round). Fixed by adding `dc_kill`
- **Bug injection**: 11 added, all detected (50 in all). At first the two that remove the epoch were not detected,
  which showed the epoch redundant, so it was removed (`dc_kill`, never giving out a freed entry in the same cycle, and
  not moving E to M in a cycle of recovery are enough). The one that removes the drain restriction was not detected
  at first either: a hole in the test, whose D$ model wrote before it read; it now reads first.

### 11.3 Size (Yosys), and the Vivado runs asked of the author

| Block | LUT | FF | From |
|---|---|---|---|
| OOC_LSU (LQ 12, SQ 12, PAW 40) | 4,768 | 2,939 (about 640 of the harness included) | Yosys |
| Expected in Vivado | about 2.9k to 3.6k | | The Vivado / Yosys ratios so far, 0.6 to 0.75 |
| G0 estimate (with the D$ adapter) | 2.5k to 3.5k | | `Doc/UARCH.md` 4.3 |

- Without the adapter it is already near the top of the estimate. Candidates to reduce it: the SQ data (12 × 64 bits)
  and the LQ addresses (12 × 40 bits) in LUTRAM (written once, read through 1 or 2 ports), removing flip-flops and
  12-to-1 selects (a few hundred LUTs together). Decided after the Vivado result.

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_LSU
cd ..\FPU_C1
synth_fpu_c1.bat
```

### 11.4 What the specification was missing (found writing the LSU)

1. **Going back to the committed state**: a full flush for exceptions, interrupts and serialization needs the RAT of
   the committed state (32 × 6 bits) and the committed head of the free list. The design has only checkpoints (at
   branches). Renaming gets them (about 0.3k LUTs).
2. **Holding back the dependents of a load that misses**: for 2-cycle load-use the dependents are woken before the
   result is known. When a load cannot give its result (a miss, a wait), the dependents already woken must be held
   back. The candidate: the issue queue cancels speculative wakeups and keeps the entries of µops issued in the shadow
   until confirmed. Decided before the core is put together.

(Added to the G0 specification, `Doc/UARCH.md` 3.4 and 3.7.)

### 11.5 The LSU in Vivado, and the M stage rewritten (2026-10-25)

| Run | LUT | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|
| OOC_LSU (first version) | **2,912** | 2,943 | **−4.019 ns** | 29 |

- **The size is inside the estimate** (2,912; the G0 estimate of 2.5k to 3.5k included the D$ adapter). Vivado /
  Yosys is 0.61.
- **The timing missed by 4 ns.** The worst path: the LQ number of the load in M → the entry's state and boundary
  (about 5 ns) → the boundary arithmetic and compare for every SQ entry → the youngest match chosen by a loop that
  compares with the best so far (a chain of compares, about 15 ns) → the choice of the write port between the load and a
  fill, made on whether the load succeeded (`m_ok`) → `wb_data`. As with the uBTB, a serial choice was the cause.
- **Rewritten**:
  1. **Mask of older stores**: every LQ entry keeps the mask (12 bits) of the SQ entries older than it, taken at
     dispatch and cleared as stores drain. The boundary arithmetic goes, and `lsu_st_known` becomes an AND of masks.
  2. **Age matrix of the SQ**: the youngest matching store comes out as a one-hot select in two levels; its data and
     mask are read by an AND-OR.
  3. **Write-port priority**: whenever a load is in M the write port is M's, whether or not it succeeds, so the choice
     is a register and does not wait for the search (in a cycle where the load in M fails, a fill waits one cycle).
- All PASS on 7 seeds. 14 LSU mutations (3 added for the new parts, 3 retargeted after the rewrite), all detected. One
  place where the test bench crashed on an RTL error now reports it instead.
- Yosys 4,768 → 4,292 LUTs, FFs 2,939 → 3,167 (about 230 more for the age matrix and the masks). About 2.6k expected
  in Vivado. **Please rerun `synth_ooo.bat OOC_LSU`.**

### 11.6 The FPU breakdown (C1, 2026-10-25)

The result of `FPGA/FPU_C1` (`output/FPU_C1/breakdown.txt`). FPU_PIPE is 9,060 LUTs (cells), 2,631 FFs, 16 DSPs, +3.76 ns
register to register, as in mmRISC-2's measurement. Per group of register names, the LUTs in the group's fan-in cone
("only this group": in no other group's cone):

| Function | Groups | LUTs only of this function |
|---|---|---|
| FMA datapath | P3 product (`pp`, `prod`, 16 DSPs), P4 alignment (`al` 1,506), P5 add (`sum` 766), P6 normalization (`q` 1,239), the addend (`c` 464) | **about 4.3k** |
| Rounder | `u_round` | 1,032 |
| Divide / square root (iterative) | `dv` / `sq` / `ds` (much shared; the cone of `dv` is 1,127) | about 1.3k |
| Other operations | P2 (`p2`: compares, min / max, sign injection, classification, moves and so on) | 862 |
| Second half of the float-to-integer conversion | `r` | 340 |
| Unpacking (`a` / `b`), output, the rest | | Mostly shared |

- 990 LUTs feed more than one group, and 918 feed no group and no output (the SRLs of the waiting bundles and the DSP
  inputs: the script does not count SRLs and DSPs as group endpoints).
- **The FMA datapath (about 4.3k) is the bulk.** It is the double-precision FMA itself, kept for performance (also the
  part C3 keeps).
- **Sharing the multiplier (C2) is about 0.3k**: the multiply is mostly DSPs; its LUTs are about the sum of partial
  products (`prod` 316). Less than the G0 estimate (0.5k to 1k).
- **Moving the rare operations to an iterative unit (C3) is about 0.7k to 0.9k**: P2 (862) and the second half of the
  conversion (340) replaced by a small iterative unit (0.3k to 0.5k expected).
- **The FPU levers (L3) are about 1.0k to 1.3k together** (1.5k to 3k at G0). The gap is that much harder to close
  (`Doc/UARCH.md` 6.2 updated).

### 11.7 The LSU rerun, and the remaining path fixed (2026-10-25)

| Run | LUT | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|
| OOC_LSU (first version) | 2,912 | 2,943 | −4.019 ns | 29 |
| OOC_LSU (rewritten in 11.5) | **2,943** | 3,157 | **−0.352 ns** | 25 |

- The rewrite of 11.5 took the 4 ns miss down to 0.35 ns, at about the same size (2,943).
- **The remaining path**: an LQ entry's valid bit → the choice of the entry to try again (a loop keeping the oldest so
  far: serial once more) → the choice of E's address (a new µop or a load tried again) → the misaligned check → a
  store's write into the SQ. A store never comes from a retry, so its check need not wait for the retry choice.
- **Fixed**:
  1. **The retry choice a cycle ahead**: the lowest-numbered waiting entry, by a parallel priority select, into a
     register. E only checks with bit lookups that it is still valid and waiting. Retries are rare, and any order is
     correct.
  2. **The misaligned check per source**: the issued µop's straight from its address, a retried load's from the LQ,
     chosen afterwards.
- All PASS on 7 seeds. One mutation added (a stale candidate tried again); all 15 LSU mutations detected (54 in all).
- **Please rerun `synth_ooo.bat OOC_LSU`.**

### 11.8 The LSU closes at 50 MHz (2026-10-25)

| Run | LUT | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|
| OOC_LSU (first version) | 2,912 | 2,943 | −4.019 ns | 29 |
| OOC_LSU (rewritten in 11.5) | 2,943 | 3,157 | −0.352 ns | 25 |
| **OOC_LSU (fixed in 11.7)** | **2,969** | 3,162 | **+6.265 ns** | 13 |

- **The LSU closes at 50 MHz.** The worst path runs from the load in M to `wb_data` (alignment and sign extension, 13
  levels with 4 CARRY4).
- 2,969 LUTs. With the D$ adapter (tagged requests and fills, `dc_kill`, the write port; about 0.3k to 0.6k expected)
  about 3.3k to 3.6k, at the top of the G0 estimate (2.5k to 3.5k, adapter included).
- The effect on the budget is recorded in `Doc/UARCH.md` 4.4 (with the LSU measured and the committed-state RAT of
  11.4, the gap is about 9.5k in the middle).

---

## 12. The ROB, and the committed state of renaming (step 2 of Phase 1, 2026-10-25)

The second block of step 2. The ROB is written, and renaming gets the committed-state RAT (the first item of 11.4). Both
are verified by unit tests and bug injection, with Vivado scripts.

### 12.1 The ROB (`RTL/CPU/OOO/OOO_ROB`)

| Item | Content |
|---|---|
| Size | 24 µops (a fused pair is one); up to 2 dispatched a cycle (slot 1 only with slot 0) and up to 2 committed, in program order |
| Payload | pc, the architectural destination and its new and old physical registers, load / store / fused / non-speculative flags. LUTRAM in two banks by the parity of the index: the 2 µops of a dispatch and the 2 of a commit are consecutive, so each bank has one write and one read a cycle |
| Status | Done, exception and its cause, in flip-flops (written by 4 completion ports: ALU0, ALU1, LSU loads, LSU stores) |
| Branch resolution | From the two ALU ports. Of the mispredictions in a cycle the oldest wins: `restore` (index and checkpoint) is given and the tail cut back to just after it. A misprediction of an index not in the ROB is ignored |
| Commit | From the head, up to 2 µops that are done with no exception. A non-speculative µop runs only at the head (`head_ns`). An exception at the head is a trap (`trap`, cause, pc) and the ROB empties (`flush_all` for the rest). A trap wins over a restore in the same cycle |
| Commit outputs | To the committed-state RAT and the free list (renaming), load / store counts (LQ / SQ), instructions (a fused pair counts 2), pc (commit trace, lock-step) |

### 12.2 The committed state of renaming (`OOO_RENAME`)

- The committed-state RAT (32 × 6 bits, written at commit) and the committed head of the free list (advanced by every
  committed allocation) are added.
- `flush_all`: RAT ← committed RAT, free-list head ← committed head.
- Contract: `cmt_wr` is set only for a µop that allocated (never for x0; the ROB's `disp_wr` comes from renaming's
  allocation).

### 12.3 Verification

- **`tb_rob.cpp` (new)**: against a reference ROB. Random µops (ALU / fused / load / store / branch / non-speculative /
  exception found at decode) dispatched, completed out of order on the 4 ports (now and then with an exception);
  branches resolved on the ALU ports in their completion cycle, some mispredicted (sometimes two at once); completions
  and resolutions for indices not in the ROB mixed in, and dispatch offered in cycles of trap or restore (must not go
  in). Every cycle `rob_avail` and the indices given, the head and `head_ns`, the trap (cause, pc), every field and
  count of the commits, and the restore's index and checkpoint are checked. All PASS on 4 seeds (400,000 cycles each).
  On one seed: 196,138 µops committed (235,378 instructions), 13,357 traps, 12,845 restores (415 with two mispredictions
  at once).
- **`tb_rename.cpp` (extended)**: commits also update the reference's committed state (a µop commits only after it is
  written back, as in the core), and now and then a `flush_all` comes. PASS (909 flushes).
- **Bug injection**: 9 added for the ROB and 3 for renaming. At first 4 were not detected; all four were redundant
  logic, and were removed (12.4). The remaining 8 are all detected (62 in all).

### 12.4 Logic removed by bug injection

| Logic | Why it was redundant |
|---|---|
| ROB: ignoring a completion for an index not in the ROB | An entry not in the ROB is cleared when it is given out. What is in flight for flushed µops is dropped by each unit (this check could not catch it anyway) |
| ROB: blocking dispatch in a cycle of trap or restore | The tail is set by the trap or restore, so nothing is allocated; the writes go only to entries beyond the new tail (cleared when given out) |
| Renaming: excluding x0 from the committed-state RAT | `cmt_wr` is never set for x0 (contract) |
| Renaming: clearing every busy bit on `flush_all` | A register in the committed-state RAT was written before it committed, so its busy bit is 0; a free register's bit is set again when it is given out |

### 12.5 Size (Yosys), and the Vivado runs asked of the author

| Block | Yosys | Expected in Vivado | G0 estimate |
|---|---|---|---|
| OOC_ROB | 1,446 LUTs + 80 LUTRAM, 536 FFs (about 390 of the harness) | about 1.0k to 1.2k | 0.7k to 1.2k |
| OOC_RENAME | 3,216 → 3,769 LUTs (+0.55k) | 2,267 → about 2.6k to 2.7k | +0.3k for the committed state |

- The ROB is at the top of its estimate; the committed state of renaming is a little more than assumed (about +0.4k
  against +0.3k).
- Checkpoints: the G0 configuration has 6, but renaming's ring of checkpoint numbers assumes a power of two and the RTL
  keeps 8. Whether to go to 6 is decided when the core is put together (8 → 6 is −0.3 % / −0.5 % in the model).

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_ROB
synth_ooo.bat OOC_RENAME
```

### 12.6 The Vivado results, and the ROB's payload fixed (2026-10-25)

| Block | LUT | LUTRAM | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|
| OOC_RENAME (with the committed state) | **2,624** | 0 | 2,530 | +9.905 ns | 6 |
| OOC_ROB | **5,173** | **0** | 2,061 | +7.018 ns | 2 |

- **Renaming**: 2,267 → 2,624 (+357), as expected for the committed state (+0.3k to 0.4k). It closes at 50 MHz with
  plenty of margin.
- **The ROB closes, but its payload became flip-flops** (0 LUTRAM, 5,173 LUTs). Each bank was written by two
  statements, slot 0's and slot 1's, so Vivado took them for two write ports and did not use LUTRAM (one write port).
  The two never write the same bank in the same cycle, but Vivado cannot see that (Yosys did, and used 80 LUTRAM).
- **Fixed**: one write per bank, with the writing slot chosen first (bank 0 takes slot 0 when the tail is even, slot 1
  when it is odd). The test PASSes on 4 seeds; all 8 ROB mutations (one added for the choice) are detected (63 in all).
- **Please rerun `synth_ooo.bat OOC_ROB`** (about 1.0k to 1.2k expected).

### 12.7 The ROB rerun (2026-10-25)

| Run | LUT | of it LUTRAM | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|
| OOC_ROB (first version) | 5,173 | 0 | 2,061 | +7.018 ns | 2 |
| **OOC_ROB (fixed in 12.6)** | **1,073** | 160 | 538 | **+11.060 ns** | 3 |

- **The payload is in LUTRAM now: 5,173 → 1,073 LUTs** (913 logic + 160 LUTRAM), inside the G0 estimate (0.7k to
  1.2k). Without the harness's flip-flops it has very few FFs.
- It closes at 50 MHz with plenty of margin (the worst path runs from a completion port to the write of an exception
  cause, 3 levels).
- The effect on the budget is recorded in `Doc/UARCH.md` 4.4 (with the ROB and the renaming with its committed state
  measured, the gap is about 9.9k in the middle).

## 13. The fetch buffer and the FTQ (step 2 of Phase 1, 2026-10-25)

The third block of step 2: between the I$ (F2) and decode (D1). Both blocks are verified by unit tests and bug
injection, with Vivado scripts. PC generation, the I$ interface, predecode and the predictors' override (TAGE-S, BTB,
RAS) come with those blocks.

### 13.1 The fetch buffer (`RTL/CPU/OOO/OOO_FBUF`)

| Item | Content |
|---|---|
| Storage | A queue of **4 whole 16-byte blocks**, not a ring of parcels. A block goes into its slot as it is, with its first and last parcel to use (fetch starts in the middle of a block after a taken transfer; a block ends at the last half of a predicted-taken transfer), taken, and its FTQ index. The data is in LUTRAM (one write, two reads: the head block and the next one) |
| Window | 8 parcels: the rest of the head block from the current parcel, then the used part of the next block. The parcels between a taken transfer and its target are skipped by construction |
| Out | Up to 4 instructions a cycle, RVC (one parcel) or 32-bit (two), from the instruction lengths of the window (a prefix sum of 4 steps). For each: bits, RVC, FTQ index and parcel of its first half, predicted-taken (its last half is the end of a taken block), and whether it follows the one before directly (for fusion). A 32-bit instruction whose second half is not there yet waits |
| In / out | One block a cycle in (`in_ready` while a slot is free); decode takes the first `consume`; up to 2 blocks are freed a cycle; `flush` (a redirect) empties it |

- **Why blocks and not parcels**: a parcel ring (`Doc/UARCH.md` 3.2, 16 parcels) needs a select in front of every
  parcel to put 8 parcels in at any place; a block queue writes a block as it is and needs only the window's select
  on the way out (two 8-to-1 selects per parcel of the window, then the 4 instructions out of it). The storage is
  32 parcels, but in LUTRAM.
- **Limit**: only two blocks feed the window, so when the head block and the next are both short (a taken transfer
  near the start of the next block), a third block could have given more that cycle. The cycle model counts the
  buffer in instructions; its size hardly matters there (16 → 8 is −0.3 %, `MODEL.md` 6).

### 13.2 The fetch target queue (`RTL/CPU/OOO/OOO_FTQ`)

| Item | Content |
|---|---|
| Entries | 8, one per fetch block, from F2 until the block's last instruction commits |
| Fields | Fetch address, predicted next address, taken and its parcel, and 32 bits of predictor state (TAGE's provider and tags, the history; opaque here). LUTRAM, one write a cycle |
| Reads | Two for decode (the window spans up to two blocks; the pc of an instruction is its block's address with its parcel), one for a branch's resolution |
| Recovery | `pop` (up to 2 blocks a cycle, at commit), `restore` (a misprediction: its block stays, the younger ones go), `flush_all` (empty) |

### 13.3 Verification

- **`tb_fbuf.cpp` (new)**: an execution model. A random program (about a quarter of the parcels start a 32-bit
  instruction) runs with random taken transfers to random targets; the run is cut into fetch blocks as fetch would
  (to the end of the block or to the last half of a taken transfer; a 32-bit instruction starting at parcel 7 ends
  its block there and finishes in the next one, also when it is the taken transfer). Blocks are pushed when
  `in_ready` (now and then not), decode takes a random number of what is given, and now and then a flush makes fetch
  start again at the oldest instruction not taken. Every cycle, for every slot: the bits, RVC, parcel offset, FTQ
  index, taken and seq, and **the exact number given** (as many complete instructions as lie in the window, up to 4).
  PASS on 9 seeds (400,000 cycles each). On one seed: 708,445 instructions taken, 101,522 taken transfers, 17,333
  instructions across blocks, 1,313 flushes.
- **`tb_ftq.cpp` (new)**: against a reference queue: random pushes, pops, restores to an entry in the queue (also
  with the queue full, across the wrap), flush_all with pops in the same cycle; the three read ports, `push_ready` and
  `push_idx` every cycle. PASS on 4 seeds.
- **Bugs found by the tests**: the buffer popped from an empty queue (stale block values decided it), and did not set
  the head parcel when a block went into an empty queue. Both fixed.
- **Bug injection**: 11 for the buffer and 7 for the FTQ. Two were not detected, both redundant logic (13.4); the
  other 16 are all detected (79 in all).

### 13.4 Logic removed by bug injection

| Logic | Why it was redundant |
|---|---|
| Buffer: no block written in a cycle of flush | The pointers are reset by the flush, so the block goes into a slot that is free |
| FTQ: no entry written in a cycle of restore or flush_all | The tail is set by the restore or flush_all, so the entry goes into a slot beyond the new tail |

### 13.5 Size (Yosys), and the Vivado runs asked of the author

| Block | Yosys | G0 estimate |
|---|---|---|
| OOC_FBUF | 1,381 LUTs + 176 LUTRAM (about 1.56k physical), 359 FFs (about 310 of the harness) | the buffer 1.3k to 1.8k |
| OOC_FTQ | 15 LUTs + 224 LUTRAM (about 0.24k), 329 FFs (all of the harness) | in the fetch's 2.0k to 2.8k |

- In OOC_FBUF, decode takes all the instructions given unless it is stalled, so the path measured runs from the
  buffer's state through the window and the instruction lengths to the count taken, and back into the head pointer
  and parcel: the loop the core will have.
- The buffer is in its estimate. The fetch row of `Doc/UARCH.md` 4.3 (2.0k to 2.8k) also holds PC generation, the I$
  interface and predecode, not written yet.
- L6 (fetch buffer 16 → 8) is worth less now: the storage is LUTRAM, and the window's selects do not depend on the
  number of blocks.

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_FBUF
synth_ooo.bat OOC_FTQ
```

### 13.6 The Vivado results, and the head parcel read ahead (2026-10-25)

| Block | LUT | of it LUTRAM | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|
| OOC_FBUF | **931** | 192 | 323 | **+0.539 ns** | 16 |
| OOC_FTQ | **148** | 132 | 329 | +15.844 ns | 1 |

- **Both are smaller than Yosys said** (FBUF 1.56k → 931, FTQ 0.24k → 148) and well inside the estimate (the buffer
  1.3k to 1.8k). All the FFs are the harness's, and the blocks' data is in LUTRAM.
- **The FTQ** is only its LUTRAM, with plenty of margin.
- **The fetch buffer closes at 50 MHz, but only by 0.539 ns** (19.3 ns, 16 levels, 79 % of it routing). The path is
  the loop of 13.5: the head pointer `hb` → the block data (LUTRAM) → the window → the chain of instruction lengths →
  the count taken → the blocks popped (`npop`) → **a second LUTRAM read, the start parcel of the new head block
  (`bs[hb + npop]`)** → the head parcel `hoff`. In the core, place and route around it will be worse than alone, so
  this margin is too thin.
- **Fixed**: the second read no longer waits for `npop`. Every candidate for the next head parcel (further into the
  head block, into the next one, the start of the block after it from a third read port, the block coming in) is
  ready before `npop` is known, and `npop` only selects among them. The end of the path loses a LUTRAM read and a
  LUT, about 2 ns.
- **Contract for the core**: decode's count taken must come from the buffer's own valid instructions and a registered
  stall (as in the harness); anything that decode computes in D1 (fusion, the rename's free registers) must not feed
  `consume` in the same cycle.
- **Checked**: all 10 unit tests PASS, `tb_fbuf` on 9 seeds; the buffer's mutations follow the new code (3 rewritten,
  M86 added for the start read after two pops), all 12 detected (80 in all).
- **Please rerun `synth_ooo.bat OOC_FBUF`** (the size should hardly change; the slack should grow by about 2 ns).

### 13.7 The fetch buffer rerun (2026-10-25)

| Run | LUT | of it LUTRAM | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|
| OOC_FBUF (first version) | 931 | 192 | 323 | +0.539 ns | 16 |
| **OOC_FBUF (fixed in 13.6)** | **940** | 192 | 323 | **+3.541 ns** | 14 |

- **The slack grows by 3.0 ns** (more than the 2 ns expected), for 9 LUTs more (the third read port of the block
  starts).
- The worst path now ends at the head pointer: `hb` → the block data (LUTRAM) → the window → the chain of instruction
  lengths → the count taken → `npop` → `hb`. It is the loop itself, with no second read after it; what remains is the
  window and the length chain, 79 % of it routing.
- The fetch buffer and the FTQ come to **about 1.09k** (940 + 148). The fetch row of `Doc/UARCH.md` 4.3 (2.0k to
  2.8k) is kept until PC generation, the I$ interface and predecode are written and measured too; the gap in 4.4 is
  not changed yet.

## 14. The front end (step 2 of Phase 1, 2026-10-25)

The fourth block of step 2: PC generation, the I$ interface, predecode, TAGE-S, BTB and RAS, from F0 to the block that
goes into the fetch buffer and the FTQ. All are verified by unit tests and bug injection, with a Vivado script for
the whole front end.

### 14.1 TAGE-S per fetch block (measured first)

The model's TAGE-S (`Plan/model/tage.h`) predicts one branch at a time, indexed by its own pc, with one history bit
per branch, updated at once. In hardware the tables are read in F1 with the fetch address only, before predecode has
found the branches of the block, and one 16-byte block can hold several conditional branches. So the predictor works
per block (`Plan/model/tageblk.h`): rows indexed and tagged by the fetch address and the history, with direction
counters for the 1st, 2nd, ... conditional branch of the block ("slots"), a base table per parcel, and the history
used for the index lagging by the blocks still in F1 and F2. Measured on the conditional branches of CoreMark
(`Plan/model/tageblk.sh`, `results/tageblk.txt`):

| Predictor | -O2 | max. optimization |
|---|---|---|
| The model's TAGE-S per branch | 0.761 % | 0.683 % |
| Per block, 1 slot | 2.301 % | 2.970 % |
| Per block, 2 slots | 0.808 % | 1.303 % |
| Per block, 2 slots, history lagging 2 blocks | 0.863 % | 1.412 % |
| Per block, **3 slots** | 0.773 % | 0.777 % |
| Per block, 3 slots, history lagging 2 blocks | 0.825 % | 0.850 % |
| The same without halving the useful counters | **0.821 %** | **0.845 %** |

- **3 slots**: with 2, the maximum-optimization build has many blocks with a third branch (10,778 branches past the
  slots), and the base counter alone predicts them badly. With 3, no branch is past the slots in either build.
- **History**: one bit per slot branch (at most 3 a block). The blocks in F1 and F2 when a block is in F0 are not in
  its history yet; the lag is 0 to 2 blocks, 2 when fetch runs without bubbles, which is the case measured.
- **No halving** of the useful counters (it would need a scan of every row): no effect.
- Against the model: +348 / +799 mispredicted branches in 10 iterations, about **−0.2 % / −0.5 %** of CoreMark/MHz
  (9 cycles each).

### 14.2 The blocks (`RTL/CPU/OOO`)

| Block | What it is |
|---|---|
| `OOO_PREDEC` | Predecode (F2): the instruction boundaries of the block (from the start parcel, or after the second half of a 32-bit instruction carried from the line before), and per end parcel the kind of control transfer (conditional branch, jal, jalr, call, return) and the target of branches and jal: 8 adders in parallel, so that the choice of the first taken transfer is followed only by a select |
| `OOO_TAGE` | TAGE-S per block (14.1): 4 tagged tables of 1024 rows (histories 5 / 12 / 30 / 70, tags 8 / 8 / 9 / 9 bits; a row holds a valid bit, a tag, a useful counter and 3 direction counters) and a base table of 512 rows × 8 parcels, all in block RAM. The folded histories are XORs of a 70-bit shift register (no folded registers to save). F1 compares the tags and keeps provider and alternate for F2. The update at commit recomputes provider and alternate from the rows as read at prediction (270 bits of metadata a block), and follows Seznec's TAGE slot by slot; each table is written at most once |
| `OOO_BTB` | For indirect jumps only (jalr / c.jr / c.jalr that are not returns): 256 rows in block RAM, read with the fetch address, one jump per line (tag, parcel, target), written at resolution |
| `OOO_RAS` | 16 entries in LUTRAM, pushed and popped at F2; a block keeps the pointer and the entry a push would overwrite, and a misprediction puts them back and does the mispredicted transfer's own push or pop |
| `OOO_FETCH` | F0 to F2 around `OOO_UBTB`: the I$ request with the fetch address; the requests in flight (at most 2, plus one in a redirect cycle); at F2 the first transfer predicted taken ends the block (branch: its TAGE slot; jal: always; return: RAS; other jalr: BTB at that parcel); if the next address differs from the one fetch went on with, F0 is redirected (2 cycles) and the uBTB trained; the block goes out with its TAGE metadata and RAS snapshot |

Decisions made while writing them:

- **Direct targets from predecode, a BTB for indirect jumps only.** The targets of branches and jal are in the
  instruction bits, which the I$ gives in F2; 8 adders give them without a table (no cold misses, nothing to learn).
  The model's BTB (unlimited, last target) only gated a branch's first prediction.
- **A 4th or later conditional branch of a block is predicted not taken.** Bug injection showed it: its base counter
  would never be trained (the update covers the slots only), so it was in effect "always taken". None in CoreMark.
- **The I$ contract** (mmRISC-2's ICACHE, to be widened to 16 bytes): a request accepted at F0 is answered 2 cycles
  later on a hit, later on a miss, in order; another request is accepted the next cycle only if this one hits. TAGE and
  the BTB keep their F1 results for exactly that timing. Every accepted request is answered (no kill): fetch drops
  the answers a redirect made useless. The request carries the full fetch address.
- **Credit**: fetch asks for a block only while the fetch buffer and the FTQ have room for it and for those in
  flight, so an answer never waits.
- **A 32-bit instruction across two lines** is predecoded with the second block (its first half kept as `carry`),
  which is always the next line; OOO_FBUF gives it from the first half's block.
- **The uBTB is trained from F2** when it and F2 differed (the F2 transfer, or its own guess weakened when it was
  earlier). An unconditional uBTB entry that F2 finds wrong (an alias) cannot be weakened and stays until it is
  replaced; the override fixes each occurrence.
- **For the core's assembly**: the FTQ keeps 312 bits of front-end state a block (TAGE 270, RAS 42), read at the head
  for the update and at a mispredicted block for the recovery, and the outcomes of the slot branches written at
  resolution (by their parcel; a branch across two lines belongs to the next block). From 32 to 312 bits in LUTRAM
  is about +0.2k. The back end computes the recovery (history bits of the slots up to the mispredicted transfer, RAS
  push / pop) from the block's metadata.

### 14.3 Verification

- **`tb_predec`**: 2,000,000 random blocks built from instructions (32-bit and compressed branches, jal, jalr with link
  and other registers, c.jr / c.jalr / c.ebreak, other instructions), cut at random places, with random start parcels
  and carried halves, against a predecoder written from the specification's tables with byte offsets
  (`predec_ref.h`). PASS.
- **`tb_ras`**, **`tb_btb`**: against reference structures (recoveries from snapshots; reads in the same cycle as
  writes to the same row). PASS.
- **`tb_tage`**: against `tage_ref.h`, a reference written from the specification. Blocks are read with the I$
  timing; 40 blocks with fixed slots and outcome patterns, so that the tables learn (provider hit in 65 % of the
  predictions, an alternate in 11 %, a weak new entry in 8 %); updates in order up to the first taken or mispredicted
  slot; restores. Every prediction and all 270 bits of metadata (which carry the rows as read, so a wrong write is
  seen when the row is read again) are compared. PASS on 4 seeds.
- **`tb_fetch`**: the front end runs a random 4 KB program (branches with loop / always / never / random behavior,
  forward jumps, calls and returns by jal and jalr, indirect jumps, runs of compressed branches) through an I$ with
  random misses; a back end walks the blocks along the program's true path, redirects on mispredictions with the
  recovery data, commits (TAGE update) and updates the BTB. Checked: every fetch address of every cycle (a mirror of
  the uBTB and its training), every block's start, end, taken, next address, 270 bits of TAGE metadata and RAS
  snapshot (mirrors of TAGE read at the request's cycle, BTB, RAS, carried half, and predecode), the true path, the
  credit, and progress. PASS on 11 programs (400,000 cycles each; on one: 180,443 instructions, 102,232 blocks,
  17,199 mispredictions, 9,630 carried halves).
- **Bug injection**: 42 added (M87–M128: predecode 8, RAS 3, BTB 2, TAGE 15, fetch 14). At first 2 were not
  detected (the 4th-branch path, see 14.2: the design was changed, and the test program got runs of compressed
  branches); now all 42 are detected (122 in all).

### 14.4 Size (Yosys), and the Vivado run asked of the author

| Module | Yosys LUT (hierarchical) | Block RAM |
|---|---|---|
| OOO_UBTB | 2,190 (Vivado measured 910, 7.6) | |
| OOO_TAGE | 2,034 | 5 |
| OOO_PREDEC | 1,134 | |
| OOO_FETCH (control) | 1,044 | |
| OOO_RAS | 53 + 14 LUTRAM cells | |
| OOO_BTB | 8 | 1 |
| **OOC_FRONT (flattened)** | **5,884 + 116 LUTRAM**, 2,626 FFs (about 1,250 of the harness) | 6 |

- Yosys has given 1.6 to 2.4 times Vivado's LUTs on these blocks (uBTB 2,207 → 910, FBUF 1,557 → 940), so about 3k
  to 3.7k are expected in Vivado, with the uBTB.
- G0 estimate for these parts: the fetch row less the fetch buffer and FTQ (about 0.9k to 1.7k), TAGE-S 0.8k to
  1.5k, BTB and RAS 0.4k to 0.7k, and the uBTB 0.91k: **3.0k to 4.8k**.
- To watch in the timing: the F2 path from the I$ data through predecode, the first taken transfer and the target
  select to the comparison with the next address and the redirect into the uBTB's fetch address; and the TAGE update
  (3 slots in a row).
- The summary of `synth_ooo.tcl` now also gives the block RAM tiles.

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_FRONT
```
