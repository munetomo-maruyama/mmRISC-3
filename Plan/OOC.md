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

### 14.5 The Vivado result, and the override path shortened (2026-10-25)

| Run | LUT | of it LUTRAM | FF | Block RAM | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|---|
| OOC_FRONT | **2,968** | 106 | 2,538 | 5.5 tiles | **−0.162 ns** | 25 |

| Instance (Vivado's hierarchy) | LUT |
|---|---|
| u_ubtb | 1,565 |
| u_tage | 710 |
| u_ras | 338 |
| u_btb | 298 |
| the rest of OOO_FETCH (control; predecode was merged into its neighbours) | 57 |

- **The size is at the bottom of the estimate**: 2,968 LUTs for all of it with the uBTB (estimate 3.0k to 4.8k;
  Vivado / Yosys 0.50). Vivado moved predecode's and fetch's logic into the instances next to it (u_ubtb grew from
  910 alone to 1,565, u_btb and u_ras hold the target select and the compare), so only the total counts.
  5.5 block RAM tiles (TAGE 4 + base 0.5, BTB 1).
- **The timing missed by 0.162 ns** (20.1 ns, 25 levels, 75 % of it routing): the override path of 14.4. From the
  queue's head pointer `qh`, the head request's address read from the queue's LUTRAM (1.4 ns), predecode (the
  boundaries from the start parcel), the slots, TAGE's prediction, the first taken transfer, the target select, then
  a 38-bit compare of the next address with where fetch went on (a carry chain, 1.7 ns), and the redirect into the
  uBTB's fetch address.
- **Fixed**, in two places:
  - The head request's address is kept in a register of its own (loaded when the head moves on), so the path starts
    at a flip-flop and not at a LUTRAM read.
  - The compare is no longer after the select: every candidate (8 predecode targets, the RAS top, the BTB target, the
    next line) is compared with where fetch went on in parallel (the targets come from the adders long before the
    choice), and the one-hot of the first taken transfer selects the result.
- The test gives the same numbers as before (the same blocks, cycle for cycle) and PASSes on 11 programs; 3
  mutations added for the new logic (M129–M131), all 17 of fetch detected (125 in all). Yosys: 5,797 LUTs + 88
  LUTRAM (no more than before).
- **Please rerun `synth_ooo.bat OOC_FRONT`** (about 3 ns more slack expected, the size about the same).

### 14.6 The front end rerun (2026-10-25)

| Run | LUT | of it LUTRAM | FF | Block RAM | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|---|
| OOC_FRONT (first version) | 2,968 | 106 | 2,538 | 5.5 tiles | −0.162 ns | 25 |
| **OOC_FRONT (fixed in 14.5)** | **3,076** | 82 | 2,576 | 5.5 tiles | **+0.959 ns** | 16 |

- **It closes at 50 MHz.** The override path lost its LUTRAM read and its compare after the select (25 → 16 levels);
  108 LUTs more (the parallel compares).
- The worst path now runs from the head request's address through predecode, the slots, TAGE, the first taken
  transfer and the uBTB's training (the match of the update against the 16 entries) into the write enable of a uBTB
  entry. If the core needs more margin, the training can be registered and applied a cycle later (no effect on the
  predictions to speak of); not done now.
- **The budget** (`Doc/UARCH.md` 4.4): the fetch buffer, the FTQ and the front end measured (940 + 148 + 3,076 less
  the uBTB counted before), with the FTQ widened for the front end's state (+0.15k to 0.25k) and the I$ to 16 bytes
  (+0.05k to 0.2k), in place of the estimates of fetch, TAGE-S, BTB and RAS (3.2k to 5.0k): the gap is **7.5k / 9.5k
  / 11.4k** (it was 7.2k / 9.9k / 12.7k). The spread narrows; what is left unwritten is decode, the issue-queue
  payload, the D$ adapter and the control (about ±1.4k).

## 15. Loads that miss: selective replay in the issue queue (2026-10-25)

> **Replaced on 2026-10-26** by the replay after commit with a 10-entry issue queue (G0b D-12, `Doc/UARCH.md` 6.3 and
> 6.5): the selective replay measured +1.4k and needs 2 more entries. This section records what was built; its RTL is
> in git (5935e45, 7d93d41).

The open item of 11.4 (B1 of the work plan): the dependents of a load are woken before its result is known (2-cycle
load-use), so when the LSU finds in M that the load gives no result in WB (`ld_cancel`: a D$ miss, a wait), what was
issued on that guess has to be taken back.

### 15.1 Measured first, and the author's decision

- **How often in CoreMark** (the raw traces, a 16 KB 4-way D$ model, stores in flight over 32 instructions): in 10
  iterations, **26 D$ misses of loads (all cold) and no partial overlap** with a store in flight (33,914 / 33,168
  loads are forwarded in full). With conservative ordering (`lsu_st_known`) there are no other waits. So the mechanism
  hardly matters for CoreMark; it matters for code that misses (Linux).
- Two options were put to the author: a replay trap at commit (a cancelled load is marked in the ROB and everything
  younger is refetched when it commits; about +0.05k LUTs, no change to the issue queue, but every D$ miss would cost a
  refetch and the work done under it) or **selective replay in the issue queue** (about +0.7k to 1.2k LUTs).
  **The author chose selective replay.**

### 15.2 The design (`RTL/CPU/OOO/OOO_IQ`)

| Item | Content |
|---|---|
| Load slots | A load issued in cycle c owns slot c mod 4 (4 slots: a load is open from its wakeup until c + 3). It is decided in c + 3 by `ld_cancel` of M in that cycle: cancelled or confirmed |
| Masks | Every wakeup bus carries the mask of the open loads its value depends on (a load adds its own slot); every source keeps the mask it was woken with; a µop issues with the OR of its sources' masks (`iss_ldm`) |
| Kept entries | A µop issued with a mask stays in the queue, not selectable, until its loads are confirmed, then its entry is freed. If one is cancelled, it goes back to waiting, and every source woken through that load is not ready any more |
| The cancelled load | Not issued again by the queue (the LSU tries it again from the LQ and answers late on `ext_*`): its entry waits, never selected, until that answer |
| Dispatch | A source whose producer is in the queue and not issued (taken back, or a cancelled load) is not ready, whatever renaming says; one whose producer is still unconfirmed gets the producer's mask. This looks at the queue's 12 producers instead of a table of 64 registers with masks (about 1k LUTs) |
| `ld_cancel` is late | It comes from the LSU's M at the end of its cycle, so it only acts on the next state of the entries, never on the select of the cycle: a µop selected on the cancelled slot in that cycle is taken back as if not issued, and its delayed wakeup does not go out |
| Units | `ld_kill` (the slot cancelled in the cycle before) and `iss_ldm`: a µop in RR or EX whose mask meets `ld_kill` is dropped (no write-back, no completion, no branch resolution; in the LSU no SQ write and no D$ request) |

- **Why decide in c + 3 and not a cycle later through a register**: the entries of µops issued on a load are kept
  until it is decided, which takes issue-queue room. In the model (`keep_spec`, 15.3) keeping them until c + 4 costs
  −1.1 % / −0.5 %, until c + 3 −0.2 % / −0.2 %.
- **For the core's assembly**:
  - every unit drops by `iss_ldm` and `ld_kill` (above); the LSU's port-2 pipeline has no stall between issue and M
    (as it is), and its `ld_cancel` goes to the issue queue as it is
  - renaming's ready bits (`disp_rdy`) follow the wakeup buses (a tag is ready from its broadcast), including the
    broadcasts in the cycle between renaming and dispatch, as `tb_iq` assumes; this was needed before as well (with
    the bits cleared at write-back, a µop dispatched between the wakeup and the write would never be woken); the queue
    corrects them after a cancel
  - loads are still to be held in the queue until `lsu_st_known` (11.1)

### 15.3 The cost in the model

| Configuration (G0) | -O2 | max. optimization |
|---|---|---|
| Entries freed at issue (the model so far) | 6.564 | 6.801 |
| Kept until c + 4 (a registered cancel) | 6.491 (−1.1 %) | 6.766 (−0.5 %) |
| **Kept until c + 3 (as built)** | **6.550 (−0.2 %)** | **6.786 (−0.2 %)** |
| Kept until c + 4, issue queue 14 | 6.556 | 6.795 |
| Kept until c + 4, issue queue 16 | 6.564 | 6.801 |

(`Plan/model`, `keep_spec`; the model has no misses, so this is the cost of the kept entries alone.)

### 15.4 Verification, size, and the Vivado run asked of the author

- **`tb_iq` (rewritten)**: the account of when values are usable now keeps, for every value, the open loads it depends
  on. A quarter of the loads are cancelled (`ld_cancel` 3 cycles after their issue); a cancel makes every value
  depending on the load unusable, sends the µops issued on it back to waiting (also one issued in the cycle of the
  cancel), and the load waits for a late answer; a confirmation drops it from the sets. Renaming's ready bits are
  given as renaming would know them (set by a wakeup, not taken back by a cancel), so the queue's correction is
  tested. Checked every cycle: every issue (oldest first, nothing early or twice), its load mask, `ld_kill`, and
  `disp_ready` (the kept and waiting entries). PASS on 12 seeds; on one: 173,765 µops issued, 73,508 kept, 10,988 loads
  cancelled, 10,134 µops taken back.
- The test's own errors on the way: the second of a pair reading the first got renaming's old ready bit; tags of
  flushed producers were read by new µops, and the late answer of a flushed cancelled load was announced (neither can
  happen after renaming's recovery and the LSU's flush).
- **Bug injection**: 21 for the issue queue (16 new for the replay, 5 for its late-cancel form; M132–M152), all
  detected (146 in all).
- **Size (Yosys, 16 entries)**: 7,288 LUTs (5,255 before, +2.0k). With the ratios so far (Vivado / Yosys 0.6, 12 entries
  0.78 times) about **+1.0k** in the core.

```
cd FPGA\OOO_OOC
synth_ooo.bat OOO_IQ
```

### 15.5 The Vivado result (2026-10-25)

| Run | LUT | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|
| OOO_IQ, 16 entries (10.x) | 3,143 | 702 | +5.065 ns | 12 |
| **OOO_IQ with selective replay, 16 entries** | **4,974** | 975 | **+3.309 ns** | 13 |

- **It closes at 50 MHz** with 3.3 ns to spare. The worst path is still the wakeup-select loop (a ready bit through
  the select, the issued tags and the compares into another ready bit); `ld_cancel` is not on it. It lost 1.8 ns,
  mostly routing (83 %) in a larger block.
- **It is larger than estimated: +1,831 LUTs at 16 entries** (Vivado / Yosys 0.68, against 0.6 before), about
  **+1.4k at 12 entries** (expected +1.0k; the range given to the author was +0.7k to 1.2k). The per-source masks
  (32 sources × 4 bits, each chosen from the 6 buses and cleared by confirm and cancel) and the dispatch compares
  against the 16 producers are most of it.
- **The budget** (`Doc/UARCH.md` 4.4): the gap goes to **8.9k / 10.9k / 12.8k**.
- **For G0b**: going back to the replay trap at commit (15.1) would save about 1.4k and gain 0.2 % on CoreMark (no
  kept entries), at the cost of a refetch on every D$ miss in code that misses. It is listed with the levers; the
  decision stays with the author.

### 15.6 Making it smaller (2026-10-25)

What each part costs was first measured by taking it out in Yosys (16 entries); the numbers move by several hundred
LUTs between variants of the same logic, so they were checked against a count of the structure.

| Taken out (Yosys, from 7,541) | LUT | | Kept? |
|---|---|---|---|
| The cancelled load's entry freed by a compare with every wakeup bus → with the external ones only | 6,791 | −750 | **Changed**: its late answer only ever comes on `ext_*` |
| The producer's mask taken at dispatch | 6,707 | −830 | Kept (see below) |
| The source masks altogether | 6,408 | −1,130 | Needed |
| The dispatch correction altogether | 6,244 | −1,300 | Needed |

- **Instead of taking the producer's mask at dispatch, wait for its confirmation?** In the model it costs little
  (−0.06 % / 0.00 % / −0.14 %), but in the RTL every source then keeps the producer's entry number (4 bits) and a
  16-to-1 select of the entries freed by confirmation: by the structure about 0.3k, against about 0.1k for the mask
  OR it replaces (Yosys gave −0.46k for the two changes together, i.e. it ate most of the first one). Dropped. Stopping
  dispatch until the confirmation instead is cheap but costs −1.5 % / −5.9 %.
- **3 load slots instead of 4.** A load is open from its wakeup until c + 3, so masks only ever hold the loads issued
  in the last 3 cycles; the 4th slot was there because the load issued in c + 3 takes the slot decided in that cycle.
  With 3, a load's own bit is kept out of what is decided in the cycle it is set (it is added to its kept mask and its
  wakeup after the decision) and out of `iss_ldm` (a load is never dropped by its own cancel: the LSU keeps it).
  Every mask bit is a quarter fewer.
- **Logic removed by bug injection**: clearing the confirmed bits in a load's delayed wakeup. With 3 slots the bit
  confirmed in the cycle of the load's issue is the load's own slot, which the wakeup carries anyway.
- **Result**: the same issue, cycle for cycle (`tb_iq`: identical counts), PASS on 12 seeds; the mutations follow the
  new code (M134, M142, M151 retargeted), all 27 of the issue queue detected (146 in all). Yosys 7,288 → **6,172 LUTs**
  (−15 %), 975 → 924 FFs. With Vivado / Yosys at 0.68 as measured in 15.5, about 4.2k at 16 entries (from 4,974),
  about 3.3k at 12.

```
cd FPGA\OOO_OOC
synth_ooo.bat OOO_IQ
```

### 15.7 The Vivado rerun (2026-10-25)

| Run (16 entries) | LUT | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|
| OOO_IQ before the replay (10.x) | 3,143 | 702 | +5.065 ns | 12 |
| With selective replay (15.5) | 4,974 | 975 | +3.309 ns | 13 |
| **After the reductions of 15.6** | **4,977** | **924** | **+2.857 ns** | 12 |

- **No gain in Vivado.** The Yosys estimate fell by 15 % (7,288 → 6,172), but Vivado's LUTs did not move (4,974 →
  4,977); only the flip-flops fell (975 → 924, the 4th mask bit). Vivado had evidently already built the parts Yosys
  counted twice (the compare of the cancelled load's tag with buses that never carry it, the 4th mask bit), and its
  count moves by a few percent from run to run anyway. The Yosys / Vivado gap of this block (0.68 → 0.81) shows again
  that Yosys cannot judge small structural changes (Plan/OOC.md 7.1).
- It still closes at 50 MHz with 2.9 ns to spare (the wakeup-select loop, 87 % routing).
- **The budget stays at 8.9k / 10.9k / 12.8k** (`Doc/UARCH.md` 4.4): the selective replay costs about +1.4k at 12
  entries. The RTL changes of 15.6 stay (fewer flip-flops, simpler: the same behavior).
- What is left to reduce it is not a detail: the per-source masks are the bulk and cannot go while the replay is
  selective. The real lever is the policy itself (the replay trap at commit, about −1.4k, 15.5), for G0b.

## 16. Decode × 4 and RVC expansion (step 2 of Phase 1, 2026-10-25)

A2 of the work plan: D1, between the fetch buffer and fusion.

### 16.1 The block (`RTL/CPU/OOO/OOO_DEC`)

- **mmRISC-2's decoders are used as they are.** `CORE_DECOMP` (RVC → 32-bit) and `CORE_DEC` (RV64GC + Zba / Zbb /
  Zbc / Zbs / Zicond / Zicsr / Zifencei / Zicboz and the privileged instructions) are taken from mmRISC-2 Rev.02
  without change into `RTL/CPU/CORE`: the instruction set is mmRISC-2's (kept, G0), and `OOO_ALU` already uses
  CORE_EXU's operation encoding, so CORE_DEC's record feeds it directly. They booted Linux in mmRISC-2.
- `OOO_DEC` puts one of each in each of the 4 slots and derives what the rest of the core needs:

| Field | For | Content |
|---|---|---|
| `cls`, `op`, `rd`, `rs1`, `rs2`, `use_rs1`, `use_rs2`, `imm`[11:0], `mem_size`, `alu2ok` | `OOO_FUSE` | The class (ALU, branch, jal, jalr, integer load, integer store, MUL / DIV, other), the operation kind of the model (lui, auipc, slli(w), srli / srai(w), add(w) / sh*add(.uw) / add.uw, addi(w)), integer registers only (rd 0 when no integer register is written), and whether the operation exists in the narrowed second stage |
| `port`, `lat2`, `ext_ans` | the issue queue | 0 any ALU, 1 ALU0 only (MUL / DIV, CSR and system), 2 LSU, 3 FPU; a 2-cycle result (multiply, integer load); a result woken from outside (divide; AMO / LR / SC) |
| `illegal`, `nonspec`, `sys`, CSR fields | the ROB | A reserved RVC encoding or an unknown instruction; what runs only at the head (`Doc/UARCH.md` 3.9) |
| the rest of CORE_DEC's record | execution | ALU operation and operands, 32-bit immediate, branch, MDU, memory command, FP fields |

- FP loads and stores, AMO / LR / SC and cbo.zero are "other" for fusion (Phase 1 has no FP renaming, and the
  others run at the head). `op` comes from the encoding, not the mnemonic: c.li and mv count as addi (the model's trace
  named them li and mv; a pair this adds is still limited by W1 / SRC2).

### 16.2 Verification (`SIM/OOO_UNIT/tb_dec.cpp`)

- **The reference** is written apart from CORE_DEC / CORE_DECOMP: a 32-bit decoder from the specification's tables
  (opcode, funct3, funct7), an RVC expander that uses Spike's own field extractors (`insn_t::rvc_*`), and the derived
  fields from `Doc/UARCH.md`.
- **What exists is decided by Spike, running the instruction**: a processor_t built for mmRISC-2's instruction set,
  in M-mode with the FPU on, steps the instruction; it exists unless it traps with an illegal instruction. Spike's
  disassembler alone could not decide it: it knows every extension whatever the ISA string (vector, quad, Zfh,
  crypto), and it takes the reserved RVC encodings. Spike also runs vector instructions with V absent, so those
  encodings are not asked; CSR instructions (whether the CSR exists is a run-time matter) and reserved static rounding
  modes are not asked either.
- **The runs**: all 49,152 RVC encodings and 3,000,000 32-bit words (their opcode, funct3 and funct7 drawn from the
  encodings that exist and the rest, and wholly random ones), the 4 slots with different instructions each time.
  First the reference's own idea of what exists is checked against Spike: **no difference**. Then every output of every
  slot against the reference: **PASS** (1,549,165 legal, 1,499,987 illegal).
- **Bug injection**: 20 added (16 in OOO_DEC, 1 in CORE_DECOMP, 3 in CORE_DEC; `mutate.py` can now break the
  `RTL/CPU/CORE` files too), all detected (166 in all). On the way, two conditions found redundant were removed (the
  divide check's Zbc bit, the FPU port's "arithmetic" flag), and illegal instructions were made to give no register,
  latency or port of their own (the test now checks that).

### 16.3 Size (Yosys), and the Vivado run asked of the author

| Block | Yosys | G0 estimate |
|---|---|---|
| OOC_DEC (4 slots, every field kept) | 2,246 LUTs, 636 FFs (all of the harness) | 1.0k to 1.6k |

- With the Vivado / Yosys ratios seen so far (0.5 to 0.8), about 1.1k to 1.8k: near the top of the estimate. The
  harness keeps every output, the FP and CSR fields included; in the Phase 1 core the fields it does not use are
  removed by synthesis, so this is the upper side.

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_DEC
```

### 16.4 The Vivado result (2026-10-25)

| Run | LUT | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|
| OOC_DEC (4 slots, every field kept) | **1,980** | 628 | **+8.048 ns** | 9 |

- **It closes at 50 MHz with plenty of margin** (11.8 ns, 9 levels).
- **It is above the estimate** (1.0k to 1.6k): about 495 LUTs a slot, where mmRISC-2 measured 278 + 78 = 356 for
  CORE_DEC and CORE_DECOMP in its pipeline. The rest is the derived fields of `OOO_DEC` and the outputs mmRISC-2's
  pipeline did not use. The FP and CSR fields stay in the count: the instruction set is kept, so the final core
  decodes them too.
- **The budget** (`Doc/UARCH.md` 4.4): in place of 1.0k to 1.6k, the gap goes to **9.9k / 11.6k / 13.2k**. What is
  left unwritten is the issue-queue payload, the D$ adapter and the control.
- Not tried now: sharing or narrowing decode (for example RVC expansion in only some slots) would change what the
  model measured; it is a G0b matter if it comes to it.

---

## 17. The issue-queue payload and the D$ adapter (step 2 of Phase 1, 2026-10-25)

A4 and A3 of the work plan.

### 17.1 The issue-queue payload (`RTL/CPU/OOO/OOO_IQPL`)

| Item | Content |
|---|---|
| What | One record of W bits for each entry of `OOO_IQ`: what a µop needs in RR and EX besides its tags (operation, immediate, ROB / LQ / SQ index and so on). The queue keeps only what the select and the wakeup read |
| Write | At DS, up to 2, to the entries the queue gives the two µops. `OOO_IQ` now outputs them (`disp_entry`, never the same entry) |
| Read | Up to 3, in RR: the grant's entry (`iss_entry`, late in IS) is registered, and the LUTRAM is read through it |
| Structure | Two banks with one write port each (bank 0 written only by slot 0, bank 1 only by slot 1) and a live value table (one flip-flop per entry: which bank wrote it last). Each bank has one write and three reads (RAM32M-shaped). One write statement per bank, as Vivado needs for LUTRAM (12.6) |
| Timing | An entry is not given out again in the cycle it is freed, so the earliest write of a new µop to it is in the cycle of the old µop's read in RR, and the LUTRAM still answers the old record then. A µop kept after its issue (selective replay, 15) keeps its entry and its record |

- **W = 96** for now. A count of what the units need: ROB 5, LQ 4, SQ 4, FTQ index and offset about 9, checkpoint 3,
  immediate 32, ALU operation and operand choices about 12, branch about 6, MDU 4, memory about 8, fusion about 4
  (about 91). It is fixed when the core is put together; the cost is linear in W.
- At 16 entries (`OOO_IQ`'s default) as at 12: a RAM32M is 32 deep, so the depth costs nothing below 32.
- Not done now: narrower records per port (port 2 needs about half of the fields), a lever if it comes to it.

### 17.2 The D$ adapter (`RTL/CPU/OOO/OOO_DCAD`) and one output added to mmRISC-2's D$

**The two sides do not match.** `OOO_LSU` (11.1) sends a load in E with its LQ entry and expects hit and data in M,
the next cycle; it has no ready for loads, takes the fills of misses by LQ entry, and drains stores through a port with
ready. mmRISC-2's `DCACHE` takes requests with valid / ready and answers them **in request order, 2 cycles after the
request at the earliest** (`d_resp_valid` is a register).

**One output added to the D$** (`RTL/CPU/CACHE`: `DCACHE`, `CACHE_TAG_ARRAY`, `CACHE_DATA_ARRAY` taken from mmRISC-2
Rev.02; the arrays without change): `d_hit_now` / `d_hit_now_data`, a load hit in stage 1, in the cycle it is found
(the 8-byte word). `hit && s1_is_load && s1_can_go`: the request leaves stage 1 now with its data in the reorder
buffer. Unlike `s1_fast` it does not ask that nothing older is waiting: that condition is only for the order of
`d_resp_*`, which still answers in order (the adapter drops that copy). So the LSU gets **hits under misses**.

| Item | Content |
|---|---|
| Requests | One a cycle: (1) the load in E, an 8-byte read of its word; (2) a load the D$ did not take in E (pending); (3) the store being drained (the byte mask becomes size and offset, the data is shifted down). The LSU drains no store in a cycle with a load in E; stores wait while loads are pending |
| Physical address | The address of the request, registered when it is taken (`d_req_paddr`; Phase 1 has no translation). `d_req_cancel` is 0 |
| Answer in M | `dc_hit` = the D$ took the LSU's load in E last cycle and `d_hit_now` |
| Answer as a fill | The D$'s in-order answer; given to the LSU at once, or kept by LQ entry (data in LUTRAM) while the LSU's fill buffer is taken |
| In-order queue | 8 entries (the D$'s `ROB_DEPTH`, it takes no more): load or store, LQ entry, answer still wanted |
| Pending loads | By LQ entry: a bit and the word address (LUTRAM); the lowest is sent when nothing comes from E |
| Answers dropped | The load hit in M; or **the same LQ entry sent a newer request** (with the answers kept for it, and its pending request) |

- **Why a newer request drops the old answers**: a load not done in M (an older store without its address, a partial
  overlap, a recovery) is tried again by the LSU, and an older store may reach the D$ in between. The old answer comes
  first (in order) and does not have that store: given to the entry, now waiting for its new request, it is a stale
  value.
- **The LSU's `dc_kill` is not used**: the same rule covers LQ entries freed while their loads are in the D$. A later
  owner of the entry sends a request before it waits for a fill (which drops the old answers), and until then the
  LSU takes no fill for it. Bug injection showed dropping on `dc_kill` redundant (17.3).

### 17.3 Verification

- **`tb_iqpl`**: random writes (up to 2 a cycle, to two different entries, leaning towards the entries being read) and
  3 grants a cycle against an array. All PASS on 4 seeds (1.2 million reads each, 218,000 of them in the cycle their
  entry was written again, 266,000 changes of the writing slot).
- **`tb_iq`** now also checks `disp_entry` (never an entry in use, never the same for both slots) and that
  `iss_entry` is the entry of the issued µop: PASS on 4 seeds.
- **`tb_dcad`**: `OOO_LSU`, `OOO_DCAD` and the real `DCACHE` (64 sets, 4 ways, 2 MSHRs, 2 write-back buffers, 8
  answers in flight) together (`SIM/OOO_UNIT/LSU_DC.sv`), with a memory model on the AXI4 bus (random delays, gaps
  between beats, random ready signals). The rest of the core is `tb_lsu`'s model, with all its checks (every load's
  value against program order, ld_cancel, the stores in commit order, lsu_st_known, no deadlock), and each load the D$
  took is answered once at most. The words used lie on 8 lines, **6 of them in one set** of the 4-way D$ (lines are
  evicted, dirty ones written back, and filled again all the time); `DCAD_SPREAD=1` puts one line in a set. The fill
  handshake to the LSU is held now and then (`tb_hold`) so that the adapter keeps answers.

| Layout (300,000 cycles, one seed) | Loads (late) | D$ reads | Hits in M | Fills | Line fills | Write-backs |
|---|---|---|---|---|---|---|
| 6 lines in one set | 25,641 (17,479) | 42,076 | 9,839 | 25,811 | 11,753 | 6,457 |
| One line a set | 92,540 (7,938) | 111,325 | 111,306 | 16 | 8 | 0 |

- All PASS on 5 seeds in each layout. With the condition of `s1_fast` (nothing older waiting), the first version had
  4,400 hits in M on the first layout; without it, 10,300.
- **Bug injection**: 17 added (3 in `OOO_IQPL`, 1 in `OOO_IQ`, 12 in `OOO_DCAD`, 1 in `DCACHE`; `mutate.py` can break
  `RTL/CPU/CACHE` too). At first:
  - 2 were not detected, which showed dropping answers on `dc_kill` redundant (17.2): removed from the adapter, as the
    LSU's epoch was (11.2).
  - 1 was not detected because the adapter seldom kept answers (dropping a kept answer on a newer request): `tb_hold`
    added, and it is detected now.
  - 1 made the test bench crash (a read outside the lines used): it reports it now.

  All are detected (183 in all).

### 17.4 Open points for the assembly

1. **The timing of the hit path.** The D$'s tag RAM → hit → `d_hit_now` → the LSU's M (the forwarding choice,
   alignment) → `wb_data`, and → `ld_cancel` → the issue queue's next state. mmRISC-2's worst path is already tag RAM
   → hit → `rob_data` (12 levels, +4.4 ns), and the LSU's M is 13 levels (+6.265 ns). `OOC_LSUDC` measures the first
   part; if it misses 50 MHz, the way it is fixed is decided on the result.
2. `d_resp_error` is not reported (a bus error on a load should be an access fault). Below `STORE_ACK_LIMIT` memory
   never answers with one.
3. Loads below `MEM_BASE` (peripherals): the LSU reads 8-byte words, speculatively. A peripheral has to be read at its
   size and only at the head (the LSU and the ROB, when the core is put together).
4. The LSU's `dc_kill` can be removed then.

### 17.5 Size (Yosys), and the Vivado runs asked of the author

| Block | Yosys | G0 estimate |
|---|---|---|
| OOC_IQPL (16 entries, 96 bits) | 1,202 LUTs + 384 LUT RAM, 530 FFs (502 of them the harness's) | 0.4k to 0.7k |
| OOO_DCAD alone (no harness) | 486 LUTs + 72 LUT RAM, 122 FFs | 0.3k to 0.6k |
| OOC_LSUDC (LSU + adapter + D$) | 13,843 LUTs + 72 LUT RAM, 8,246 FFs | |

- The payload is at least the 384 LUT RAM (2 banks × 3 reads × 96 bits) and the 3 × 96 bank choices; Yosys's logic
  count is above what that needs, and Vivado decides.
- `OOC_LSUDC` is there for the timing of 17.4 and for the adapter's own row; `summary.txt` now lists the instances
  of a harness with several blocks. The D$ is mmRISC-2's and counted with the caches.

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_IQPL
synth_ooo.bat OOC_LSUDC
```

### 17.6 The Vivado results (2026-10-26)

| Run | LUT | of it LUT RAM | FF | BRAM tiles | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|---|
| OOC_IQPL (16 entries, 96 bits) | **711** | 384 | 533 (502 the harness's) | 0 | **+12.237 ns** | 3 |
| OOC_LSUDC (LSU + adapter + D$) | 8,439 | 70 | 8,240 | 6 | **+1.254 ns** | 21 |

| Instance of OOC_LSUDC | LUT | of it LUT RAM | FF |
|---|---|---|---|
| `u_dcad` (`OOO_DCAD`) | **227** | 70 | 110 |
| `u_lsu` (`OOO_LSU`) | 3,004 | 0 | 2,603 |
| `u_dc` (`DCACHE`, arrays included) | 5,211 | 0 | 5,012 |

- **Both close at 50 MHz.**
- **The payload is 711 LUTs**: 384 LUT RAM (2 banks × 3 reads × 96 bits, as counted) and 327 logic, mostly the
  3 × 96 bank choices. Just above its estimate (0.4k to 0.7k). It is linear in W: about 7.4 LUTs a bit.
- **The adapter is 227 LUTs**, below its estimate (0.3k to 0.6k). The LSU in this harness is 3,004 (2,969 alone, 11.8):
  what feeds `dc_kill` and the fill input is optimized a little differently.
- **The worst path is not the hit path of 17.4.** It runs from the D$'s tag forwarding through the tag compare to
  `s1_can_go` → `d_req_ready` → the adapter's `dc_st_ready` → the LSU's store drain → the SQ's head and valid bits (21
  levels, +1.254 ns). Paths inside the D$ to `rob_data` follow (+2.07 ns). The new hit path, `d_hit_now` → the LSU's M
  → `wb_data` / `ld_cancel`, is not among the 10 worst, so its slack is above 2.07 ns. In the core `ld_cancel` goes on
  into the issue queue's next state, which this harness does not have (17.4 item 1 stays open for that part).
- If the drain path gets in the way when the core is put together, `dc_st_ready` can be made from the registered state
  of the D$ (a store drains a cycle later), at no cost in the model's terms (stores drain after commit).
- The D$ is mmRISC-2's and counted with the L1 caches outside the engine (`Doc/UARCH.md` 4.2: 8,217 for both). Its
  5,012 FFs are mostly the line buffers of the MSHRs and write-back buffers: `REDUCE.md` A3 (to LUTRAM, 0.8k to 1.5k)
  is still to be done, and it is already counted in the room (group A, `Doc/UARCH.md` 4.2), not a new lever.
- **The budget** (`Doc/UARCH.md` 4.4): the payload 711 and the adapter 227 in place of 0.4k to 0.7k and 0.3k to 0.6k:
  the gap goes to **10.1k / 11.5k / 12.8k**. What is left unwritten is the control (dispatch, branch resolution,
  redirects, commit and exceptions, the ports to CSR / MDU / FPU / MMU; 1.5k to 2.5k).

---

## 18. The control, first part: branch masks, dispatch and recovery (step 2 of Phase 1, 2026-10-27)

The last block left unwritten (`Doc/UARCH.md` 4.3: dispatch, branch resolution, redirects, commit and exceptions,
1.5k to 2.5k). This first part decides which µops move from renaming to dispatch, which µops a misprediction or a trap
throws away, and where fetch starts again.

### 18.1 What was missing, found while writing it

1. **The issue queue emptied completely on a misprediction** (`flush`), which loses the older µops still waiting.
   It needs a selective squash. Chosen: **branch masks** (one bit per checkpoint, 6): a µop carries the checkpoints
   older than it; a restore of checkpoint c kills every µop with bit c (in the DS register, the issue queue, the
   units' pipelines); a branch resolved as predicted clears its bit everywhere. The other way, comparing ROB indices
   against the restored one relative to the head in every entry, costs more compares.
2. **A checkpoint id must be checked at renaming, not at dispatch.** `OOO_RENAME` copies the RAT into the id it gives
   in the next cycle, so a µop that would take a live id must wait at renaming (the ring of ids is used in order: one
   still open stops it even when later ones are free).
3. The units must drop what they have in flight whose mask meets `kill` (the issue queue gives `iss_bm`).

### 18.2 The block (`RTL/CPU/OOO/OOO_CTRL`)

| Part | Content |
|---|---|
| D2 (renaming) | `r_go`: the prefix of the µops offered that rename now: the DS register free or leaving, registers free (`OOO_RENAME` ready), no recovery, and a checkpoint id not in use for a µop that takes one. Its mask is the live checkpoints (with slot 0's for slot 1) less this cycle's clears |
| DS (dispatch) | The DS register's µops go together, both or none (`d_go`), when the ROB, the issue queue, the LQ and the SQ have room for all of them; their masks (`d_bmask`) lose this cycle's clears. A µop with a checkpoint writes the table: the LSU's tails after it and its fetch block |
| Recovery | trap (flush_all, fetch from the trap vector), then replay (flush_all, fetch from `replay_pc`), then restore (the ROB's oldest mispredicted branch: restore id, the table's LSU tails and FTQ index, `kill` = its bit, fetch from the branch's correct next pc). The restored checkpoint and those younger (their masks have its bit) are free again |
| Clears | `clr`: the branches resolved as predicted, unless this cycle's restore kills them (their ids may be given out again) |

- Both or none at DS is simpler than moving slot 1 to slot 0 (a select on the whole payload); it can lose a cycle
  when exactly one entry is free. Not in the model yet.

### 18.3 The issue queue with branch masks (`OOO_IQ`)

Every entry keeps its mask (`disp_bm`); `kill` frees the entries whose mask has the bit, in the next state (the select
of that cycle is unchanged: a µop selected then is dropped by its unit, its mask in `iss_bm`); `clr` clears bits.
`flush` is flush_all only.

### 18.4 Verification

- **`tb_ctrl`**: a random stream of µops (a quarter branches, loads, stores) offered to renaming; the test bench plays
  `OOO_RENAME`'s ring of checkpoint ids and the ROB (the oldest mispredicted branch of the cycle; now and then a trap
  or a replay), with random room in every queue and random resolutions at a rate that changes every 500 cycles (so
  that the checkpoints run out at times). Checked every cycle against an account of the µops in program order:
  `r_go`, `ds_valid`, `d_go`, every mask (exactly the older branches not resolved), `live`, `kill`, `clr`, the restore
  id, tails and FTQ index, and the redirect pc. PASS on 4 seeds (400,000 cycles each: about 207,000 µops renamed,
  6,600 restores, 2,000 flushes, 4,000 stalls on a checkpoint id).
- **`tb_iq`** with masks: the open ids kept in program order, a µop taking them as its mask and sometimes opening
  one; kills (without dispatch in that cycle, as `OOO_CTRL` gives them) and clears; `iss_bm` checked. PASS on 6 seeds
  (about 6,000 kills and 39,000 clears a run).
  - **A hole found in `tb_iq` itself**: a random destination tag could be one the older µop of the same group read, a
    dependence on a younger µop. Without kills the two then waited for each other until the next flush; a kill made
    it visible. Fixed: the queue now issues about 278,000 µops a run instead of 100,000.
- **Bug injection**: 11 added (9 in `OOO_CTRL`, 2 for the masks of `OOO_IQ`), all detected (191 in all).

### 18.5 Size (Yosys), and the Vivado runs asked of the author

| Block | Yosys |
|---|---|
| OOC_CTRL | 384 LUTs, 428 FFs (most of them the harness's) |
| OOO_IQ with masks | 2,833 (2,571 without) |

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_CTRL
synth_ooo.bat OOO_IQ
```

### 18.6 The Vivado results (2026-10-27)

| Run | LUT | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|
| OOC_CTRL | **340** | 428 (most of them the harness's) | **+13.564 ns** | 4 |
| OOO_IQ with branch masks | **1,775** (1,597 without: +178) | 444 | +7.841 ns | 10 |

- **Both close at 50 MHz**, the control with plenty of margin. The issue queue's worst path is still the
  wakeup-select loop; the masks are not on it.
- **The budget** (`Doc/UARCH.md` 4.4): the control's estimate (1.5k to 2.5k) stays the whole control's, its first
  part (340) inside it; the masks of the issue queue (+178) were not in any estimate and are added: the gap goes to
  **3.2k / 4.6k / 5.9k**. With the levers still to come (5.65k with the reserve), the middle margin is about +1.1k.

### 18.7 What the control still needs (the next parts)

1. **Non-speculative µops** (`Doc/UARCH.md` 3.9): held in the issue queue until they are at the ROB head (`head_ns`
   and the µop's ROB index), and younger µops waiting behind CSR writes.
2. **Commit**: renaming's free list and committed state from the ROB's commits; the LQ / SQ counts; the FTQ's pops,
   which need to know which µop ends a fetch block (not in the ROB's payload yet).
3. **The units' pipelines** dropping by mask, and the pipeline registers between D2 and DS (the payload of the DS
   register).
4. **The front end's restore**: the FTQ entry's history and RAS state into `OOO_FETCH` (`be_*`).
5. **Exceptions and interrupts**: the trap vector and the CSR writes (mepc, mcause, mtval), interrupts at a µop
   boundary, the refetch with fusion off after an exception inside a pair (3.8), FENCE.I / SFENCE.VMA flushing the
   front end.

---

## 19. The control, second part: non-speculative µops, commit and the FTQ's pops (2026-10-27)

Items 1 and 2 of 18.7.

### 19.1 What was done

| Block | What was done |
|---|---|
| `OOO_IQ` | A non-speculative bit per entry (`disp_ns`: CSR, system, AMO / LR / SC, cbo.zero). Such an entry may be selected only with `ns_ok` and when no older non-speculative entry is in the queue (the head's is the oldest); `iss_ns` says that one issued. The condition is of registered state and `ns_ok`, off the wakeup-select loop |
| `OOO_CTRL` | `ns_ok` = the ROB head is a non-speculative µop not run yet (`head_ns`) and none has issued since that head came (`head_ns` alone stays up while an issued CSR executes). The commit fan-out: the old mappings to the free list (`free_*`), the LQ / SQ counts. The FTQ's pops: the blocks before the block of the latest committed µop, up to 2 a cycle, its own block too after a replay. The back end flushed a cycle after a trap or a replay (below) |
| `OOO_ROB` | The µop's fetch block in the payload (`disp_ftq` → `cmt_ftq`, 3 bits) |

- **A µop that changes what younger ones do** (a CSR write, FENCE.I, SFENCE.VMA, MRET) completes marked for replay
  after commit, so what follows it is fetched again: the ROB's existing mechanism, a contract for the units and no new
  logic. CSR reads need nothing more than `ns_ok`.
- **Found: a replay flushed renaming in the cycle it commits the load.** Renaming goes back to its committed state,
  which takes that cycle's commit only at the clock edge, so the load's mapping (and the free list's committed head)
  would be lost. Now the front end is flushed at once (`fe_flush`: the FTQ, the fetch buffer, fetch from `fe_pc`) and
  the back end a cycle later (`flush_all`: renaming, the LSU, the issue queue, the units); in between nothing is
  renamed or dispatched, and the ROB is already empty. A trap commits nothing in its cycle, but goes the same way.
- **Lost predictor updates**: a trap or a replay flushes the FTQ; blocks still to pop then (only when more than 2
  blocks end in a cycle) go without their update.

### 19.2 Verification

- **`tb_ctrl`** also checks: `fe_flush` at once and `flush_all` a cycle later, with nothing renamed, dispatched or
  cleared in either cycle; `ns_ok` against its own model of the busy bit (random `head_ns` and issues); the free list
  and LQ / SQ fan-out; the FTQ pops against a mirror of the FTQ's head with random commits whose blocks move on by 0
  to 2 a µop. PASS on 4 seeds (about 200,000 pops a run).
- **`tb_iq`**: an eighth of the ALU0-only and LSU µops non-speculative, `ns_ok` random; such a µop issues only with
  it and as the oldest one queued; `iss_ns` checked. PASS on 4 seeds (about 17,000 a run).
- **`tb_rob`**: the fetch block at commit. PASS.
- **Bug injection**: 9 added (6 in `OOO_CTRL`, 2 in `OOO_IQ`, 1 in `OOO_ROB`), 3 of the ROB retargeted (its payload's
  fields moved): 200 in all.

### 19.3 Size (Yosys), and the Vivado runs asked of the author

| Block | Yosys | Before |
|---|---|---|
| OOC_CTRL | 388 | 384 |
| OOO_IQ | 2,986 | 2,833 |
| OOC_ROB | 1,668 | 1,621 |

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_CTRL
synth_ooo.bat OOO_IQ
synth_ooo.bat OOC_ROB
```

### 19.4 The Vivado results, and ns_ok registered (2026-10-27)

| Run | LUT | Before | Register-to-register slack | Worst slack (with the ports) |
|---|---|---|---|---|
| OOC_CTRL | **355** | 340 | +13.444 ns | |
| OOO_IQ | **1,885** | 1,775 | +7.417 ns | **−0.261 ns** |
| OOC_ROB | **1,235** | 1,232 | +9.856 ns | |

- **The issue queue missed 50 MHz on a path through its ports**: `ns_ok` (input, 6 ns of input delay) → the ready bits
  → the select → `iss_src` (output, 6 ns of output delay), 10 levels, 8.225 ns against 8 ns. Not only the harness's
  assumption: in the core `ns_ok` came from the ROB's payload read (`head_ns`) through logic, late in its cycle, into
  the select.
- **Fixed**: `ns_ok` is now a register of `OOO_CTRL` (from the cycle before; a non-speculative µop waits one cycle
  more: 2 such instructions in 3 million in CoreMark), and the OOO_IQ run gives that input 1 ns of input delay (it
  comes from a flip-flop). `tb_ctrl` PASS on 4 seeds with the registered `ns_ok`; the two mutations of it retargeted
  and detected.
- **The budget** (`Doc/UARCH.md` 4.4): the control's second part (+15) stays inside the control's estimate; the issue
  queue's non-speculative hold (+110) and the ROB's fetch block (+3) are added: the gap goes to **3.3k / 4.7k /
  6.0k**.
- **The rerun (2026-10-28)** with `ns_ok` registered:

| Run | LUT | Before | Register-to-register slack | Worst slack (with the ports) |
|---|---|---|---|---|
| OOC_CTRL | **350** | 355 | +13.433 ns (5 levels) | +11.501 ns |
| OOO_IQ | **1,866** | 1,885 | +6.573 ns (12 levels) | **+0.776 ns** |

  The issue queue closes at 50 MHz. Its worst path is now its own select, `vq` (a register) → `iss_src` (output,
  6 ns of output delay), 12.215 ns: the cycle the select has anyway, not the `ns_ok` input. Both blocks got a little
  smaller (−19, −5); the budget does not move at 0.1k (still 3.3k / 4.7k / 6.0k).

### 19.5 What is left of the control

Items 3 to 5 of 18.7: the units' pipelines dropping by mask and the DS register's payload, the front end's restore
(history, RAS), exceptions and interrupts (CSR writes, interrupts at a µop boundary, the refetch with fusion off after
an exception inside a pair).

---

## 20. The control, third part: the units dropping by mask, the DS register's payload (2026-10-28)

Item 3 of 18.7.

### 20.1 What was done

| Block | What was done |
|---|---|
| `OOO_STAGE` (new) | One pipeline register of a unit: valid, branch mask and W bits. A µop whose mask has the killed bit is not taken (`in_bm & kill`) or, held (`en` = 0: an iterative divide), leaves; the cleared bits leave the mask whether it is taken or held; `flush` empties it. The ALU ports use it after IS (RR), after RR (EX) and after EX (write-back) |
| `OOO_DSREG` (new) | The DS register's payload: the two µops' source tags, use and ready bits, and W bits of everything else dispatch writes. Loaded with `ds_load`, else it holds. Its ready bits snoop the issue queue's wakeup tags of the cycle before, every cycle (registered tags, off renaming's and the issue queue's paths) |
| `OOO_LSU` | A µop from port 2 carries its mask (`iss_bm`): dropped in E and M when it has the killed bit (`kill`); an older one goes on through a restore as in any cycle. A load tried again from the LQ has no mask: it does not start in a cycle of recovery and one in M is put back, as before |
| `OOO_IQ` | The wakeup tags go out (`wk_valid` / `wk_tag`, 6 buses). The delayed wakeup (a load, a multiply) is not sent for a µop killed or flushed in the cycle it issued |
| `OOO_RENAME` | The busy bits are cleared by the issue queue's wakeup tags (`wk_*`, 6) at the edge of their cycle, no longer by the 3 write-back ports. A register given out in the same cycle stays busy |
| `OOO_CTRL` | `ds_load`: the DS register takes renaming's µops (it is empty or its µops go now), the payload's enable |

- **Found: the LSU lost an older µop issued in a restore cycle.** It dropped everything in E and M on any restore
  (written before the masks, when a misprediction emptied the issue queue): an older load or store issued in that
  cycle never completed, since the issue queue had freed its entry, and the core would wait for it for ever. `tb_lsu`
  never issued in a cycle of recovery; now it does (with the masks of the branches older than each µop), and the old
  code deadlocks in 2,800 cycles.
- **Found: a µop could miss its wakeup between renaming and dispatch.** The busy bits were cleared at the write-back
  (an ALU result 3 cycles after its wakeup) and the issue queue takes only the wakeups of the cycle a µop is
  dispatched. A µop renamed between a wakeup and its write-back read its source busy, and nothing would ever wake it:
  no unit test held renaming and the issue queue together. `Doc/UARCH.md` 6.5 already assumed the busy bits follow
  the wakeup buses; 3.4 and the RTL had the write-back ports. Now a µop renamed after a wakeup reads its source ready,
  and the DS register adds the wakeups between renaming and dispatch: those of the capture cycle (seen the cycle
  after) and of every cycle it holds.
- **Stale wakeups.** With the busy bits and the DS register taking wakeups, one for a register that has been given
  out again would mark a new µop's source ready. A µop killed or flushed as it issues has its register given out a
  cycle later at the earliest: only its delayed wakeup can come then, and the issue queue no longer sends it.
  Contract for the units that wake from outside (divide, AMO): only for live µops.
- **What a unit does in the cycle of a kill is not held back** (`OOO_STAGE`): a killed branch clears nothing
  (`OOO_CTRL`), and its register and ROB entry are given out again only later (renaming a cycle after the restore,
  dispatch two), so its write and its completion land on nothing live.
- **Clears.** A checkpoint cleared in cycle t is killed again in t + 5 at the earliest (renamed, dispatched, issued,
  read, resolved), so the LSU's one-cycle M needs no clears. `OOO_STAGE` clears both when it takes a µop and while it
  holds: I first left the clear out when taking; a µop taken with a bit cleared in that cycle into a stage that then
  holds (a divide) would keep the bit, and the next branch with that id would kill it (`tb_stage`, M250).

### 20.2 Verification

- **`tb_stage`** (new): the stage against the history of the µop it holds (taken, killed, cleared, flushed), ids
  given out again the cycle after they close (sooner than the core can), holds in bursts. 400,000 cycles, 4 seeds.
- **`tb_dsreg`** (new): renaming's busy bits played (cleared at the edge of the wakeup's cycle); every cycle, every
  source of the µops held must be ready exactly when its producer woke in a cycle before this one: what the issue
  queue needs, since it takes the wakeups of the dispatch cycle itself. In-group sources, holds of up to 20 cycles,
  wakeups a few or 40 cycles after renaming. 300,000 cycles, 162,492 sources made ready by the snoop, 4 seeds.
- **`tb_lsu` / `tb_dcad`**: branches hold checkpoint ids, every µop issued carries the mask of the unresolved
  branches older than it, a restore kills its id, and µops issue in cycles of recovery too: one younger than the
  branch must not write the SQ or complete, one older must go on as in any cycle.
- **`tb_iq`**: the 6 wakeup buses checked bus by bus every cycle (the delayed one absent for a µop killed or flushed
  as it issued). **`tb_rename`**: 6 wakeup buses clear the busy bits. **`tb_ctrl`**: `ds_load` set when µops rename,
  clear while the DS register keeps µops that do not go.
- **Bug injection**: 19 new mutations (M233–M237, M240–M253) and M38 retargeted; all detected.
- **Not checked**: an older load in M put back by a restore (as the LSU did before) is not a wrong value, only a late
  one with a replay after commit, which the tests accept; the mutation of it is not in the list.

### 20.3 Size (Yosys), and the Vivado runs asked of the author

| Block | Before | Now | |
|---|---|---|---|
| `OOC_RENAME` | 3,456 | 3,753 | +297: 6 buses clear the busy bits instead of 3 |
| `OOO_IQ` | 2,986 | 3,163 | +177: the wakeup tags as outputs, the gated delayed wakeups |
| `OOC_LSU` | 3,055 | 3,148 | +93: the masks in E and M |
| `OOC_CTRL` | 388 | 386 | `ds_load` |
| `OOC_DSREG` | | 121 | new: 4 sources × 6 buses compared |

- Yosys only hints (the IQ's +177 is more than the change looks; Vivado decides). The stage registers are about 1 LUT
  of mask check each (3 a port); the payload of the DS register (about 150 bits a slot) and of the stages are
  flip-flops with an enable, no LUTs.
- **Timing to watch**: the busy bits now take the issue queue's wakeup tags, which come late in the cycle from its
  select (its worst path reaches the port at about 13.2 ns, 19.4). The `OOC_RENAME` harness feeds them unregistered
  with 13 ns of input delay, `OOC_DSREG` too. If renaming misses: the busy bits take the tags a cycle later (from a
  register) and the DS register snoops two cycles back (twice the compares).
- **Please run** `synth_ooo.bat OOC_RENAME`, `synth_ooo.bat OOO_IQ`, `synth_ooo.bat OOC_LSU` and
  `synth_ooo.bat OOC_DSREG` (new in the list).

### 20.4 The Vivado results (2026-10-28)

| Run | LUT | Before | Worst slack | |
|---|---|---|---|---|
| OOC_RENAME | **2,702** | 2,464 | **+3.443 ns** (register to register +8.272 ns) | the worst path is the new one: `wk_tag` (in at 13 ns) → `busy` (3 levels, 4.477 ns) |
| OOO_IQ | **1,874** | 1,866 | +1.248 ns (register to register +6.293 ns) | the wakeup tags as outputs cost 8 |
| OOC_LSU | **1,942** | 2,290 | +6.875 ns | −348: more than the change explains (every LQ / SQ write was gated by `!restore && !flush_all`, now by the shared `e_iss`); flip-flops +18 as expected (`m_bm` and the harness's 12 inputs), so nothing was trimmed away |
| OOC_DSREG | **69** | | +6.835 ns (register to register +15.922 ns) | new; Yosys 121 |

- **All four close at 50 MHz.** Renaming takes the issue queue's wakeup tags straight from its select with 3.4 ns to
  spare (with 13 ns assumed for them), so the busy bits are cleared at the edge of the wakeup's cycle as designed; the
  fallback of 20.3 (a cycle later, the DS register snooping two cycles back) is not needed.
- **The budget** (`Doc/UARCH.md` 4.4): renaming +238, the LSU −348, the issue queue +8 are added; the DS register's 69
  stays inside the control's estimate (the control so far 350 + 69). The gap goes to **3.2k / 4.6k / 5.9k**.

### 20.5 What is left of the control

Items 4 and 5 of 18.7: the front end's restore (the FTQ entry's history and RAS state into `OOO_FETCH`), exceptions
and interrupts (the trap vector and the CSR writes, interrupts at a µop boundary, the refetch with fusion off after an
exception inside a pair, FENCE.I / SFENCE.VMA).

---

## 21. The control, fourth part: the front end's restore (2026-10-28)

Item 4 of 18.7.

### 21.1 What was done

| Block | What was done |
|---|---|
| `OOO_FERS` (new) | Takes the point of a redirect into a register in cycle R (a restore: the block from the checkpoint table, the last parcel, outcome and call / return of the port that resolved the branch; a trap or a replay: the µop's block and last parcel from the ROB), reads that block's FTQ entry in R + 1 and gives `OOO_FETCH` the restart: `fe_pc`, the block's history, its slot branches up to the point (before it not taken, the point's own slot with its outcome; for a trap or a replay only those before it), the RAS snapshot and the point's own push (the parcel after a call) or pop |
| `OOO_FETCH` | `be_stop` (the control's redirect in cycle R): no request and no block in that cycle; the restart comes with `be_redirect` in R + 1 |
| `OOO_CTRL` | `restore_port`: the ALU port whose branch restores (it also chooses `fe_pc`) |
| `OOO_ROB` | `rcv_ftq` / `rcv_end`: the block and last parcel of the µop a trap (the head) or a replay (the marked µop, at the head or the one after it) goes back to |

- **The restart a cycle after the resolution** (D-15, decided by the author as recommended on 2026-10-28). The history must be in TAGE's register
  before the first fetch reads the tables with it; straight from the resolution, the branch's comparison, the ROB's
  choice of the oldest misprediction, the control, the checkpoint table, the FTQ read, the push into the history and
  TAGE's block RAM address would be one cycle. A redirect in R + 1 costs 1 cycle a misprediction: −0.27 % / −0.22 % /
  −0.26 % in the model (6.260 → 6.243 CoreMark/MHz on -O2; 1.44 mispredictions per thousand instructions). A
  misprediction costs 10 cycles from EX to EX.
- **The front end still stops at once.** If it went on until the restart, a wrong-path block could reach the fetch
  buffer or the FTQ in R + 1 (the FTQ was restored in R) and be renamed. `be_stop` keeps both empty: no request, no
  block; what is in flight is dropped by the restart.
- **The block of a µop is the block of its last half.** Predecode puts an instruction across two lines in the second
  block, with its slot and its prediction; the fetch buffer gives the first half's block. Decode must give the back end
  the second block (+1 when the instruction crosses), and the checkpoint table, the ROB (`disp_ftq`, the FTQ's pops)
  and the restore use it.
- **Found while testing: a trap can be at a branch** (a debug trigger on it): the trap comes before the branch, so its
  slot must not go into the history. I had thought only a resolved transfer ends at a slot's parcel; `tb_fers` makes
  traps at any instruction, and the point's slot now counts only for a restore.
- **Simplified**: the slot branches before the point go in not taken, not "as predicted": one predicted taken would
  have ended the block before the point, so the predictions there are always 0 (the bit injection of "as predicted
  → 0" was not detectable; the input is gone).
- **The FTQ's read ports**: the third (the resolution's) is the restore's, in R + 1. A jalr's predicted target, which
  the resolution needs to see a misprediction, travels with the µop (the payload), or needs a fourth read: for the
  assembly.

### 21.2 Verification

- **`tb_fers`** (new): blocks built from their instructions (slot branches predicted by a coin until one is taken and
  ends the block, a branch past the slots, calls, returns, other jalr), an FTQ of 8 that refills; redirects at any
  instruction of a block (a restore of a mispredicted transfer on port 0 or 1 with random values on the other; a trap
  or a replay at any instruction), often in two cycles in a row. The cycle after: the block read, the pc, the history,
  the slot outcomes, the RAS snapshot, push / pop and push address. 400,000 cycles, 200,321 redirects, 4 seeds.
- **`tb_fetch`**: the back end stops fetch a cycle before the restore, as the core will; no request and no block in a
  cycle of a stop or a redirect. 11 programs.
- **`tb_rob`**: `rcv_ftq` / `rcv_end` for every trap and replay. **`tb_ctrl`**: `restore_port` for every restore.
- **Bug injection**: 13 new mutations (M254–M266) and M128 retargeted (its line now gates on `stop`); 232 of 232
  detected.

### 21.3 Size (Yosys), and the Vivado runs asked of the author

| Block | Yosys | |
|---|---|---|
| `OOC_FERS` | 38 (88 LUT RAM) | new: the restore with the FTQ it reads (8 × 312 bits of the front end's state; Yosys keeps only the bits read) |
| `OOC_FRONT` | 5,262 | `be_stop`: two gates (Yosys moves by ±0.3k between runs here) |
| `OOC_ROB` | 1,688 | `rcv_*` |
| `OOC_CTRL` | 399 | `restore_port` |

- **Please run** `synth_ooo.bat OOC_FERS` (new in the list), `synth_ooo.bat OOC_FRONT`, `synth_ooo.bat OOC_ROB` and
  `synth_ooo.bat OOC_CTRL`.

### 21.4 The Vivado results (2026-10-28)

| Run | LUT | Before | Worst slack | |
|---|---|---|---|---|
| OOC_FRONT | **2,611** | 2,588 | +0.835 ns (was +0.574) | `be_stop`: +23 |
| OOC_ROB | **1,246** | 1,235 | +10.606 ns | `rcv_ftq` / `rcv_end`: +11 |
| OOC_CTRL | **351** | 350 | +11.501 ns | `restore_port`: +1 |
| OOC_FERS | — | | | **failed in synthesis**: my harness took `ft_pc[38:4]` of a `[37:0]` bus (the line is bits 37:3 there); fixed. Verilator warned (SELRANGE), but I had filtered the lint for errors only. All harnesses are now linted with `-Wall` and every warning on them read |

- **The rerun of OOC_FERS**: **151 LUTs** (37 logic + 114 LUT RAM, the FTQ the harness reads: only the bits read are
  kept), register to register +13.393 ns (10 levels: the restore point's register → the FTQ read → the slot compares
  → the history bits); worst +11.501 ns at the ports. The restore's 37 stay inside the control's estimate (the control
  so far 351 + 69 + 37); the FTQ's growth to the front end's 312 bits a block is the FTQ's, counted at the assembly.
- The budget does not move at 0.1k (+35): still 3.2k / 4.6k / 5.9k (`Doc/UARCH.md` 4.4).

### 21.5 What is left of the control

Item 5 of 18.7: exceptions and interrupts (the trap vector and the CSR writes: mepc, mcause, mtval; interrupts at a
µop boundary; the refetch with fusion off after an exception inside a pair; FENCE.I / SFENCE.VMA). The budget is
updated with the Vivado results.

---

## 22. The control, last part: exceptions, interrupts and the system µops (2026-10-28)

Item 5 of 18.7.

### 22.1 What was done

| Block | What was done |
|---|---|
| `OOO_TRAP` (new) | What happens at the ROB head. **An interrupt** (`irq_pend` and its cause from the CSRs) is taken before the head µop (`irq` empties the ROB, nothing commits): mepc = its pc, the interrupt cause, mtval 0, mtvec (+ 4 × cause when vectored); not while the head is a non-speculative µop that has issued (`ns_busy`: its effect has happened), and it wins over the head's exception. **An exception**: mepc, mcause, mtval = the tval of the oldest exception reported, mtvec. **An exception in a fused pair**: no CSR written, the pair fetched again from its pc with fusion off (`no_fuse`, until two instructions have committed or the next trap). **MRET**: its replay goes to mepc and updates mstatus (`csr_mret`). Its outputs are OOO_CTRL's `trap`, `trap_vec` and `replay_pc` |
| `OOO_SYS` (new) | The system µops at the head, one at a time: FENCE waits for every committed store to be in the D$ (`sq_drained`); FENCE.I the same, then FLUSH of the D$ (the dirty lines to memory) and the I$ invalidated, as mmRISC-2 does, then a replay; SFENCE.VMA waits for the stores, flushes the TLBs (Phase 2), replay; MRET `x_mret` and replay; WFI completes when an interrupt is pending in mie |
| `OOO_DCAD` | FLUSH as a fourth request (after loads and stores): `fl_req`, `fl_take`, `fl_done` when its answer comes in order |
| `OOO_ROB` | `irq` (empty before the head, nothing commits; the point for OOO_FERS is the head), `head_valid`, `head_fused` |
| `OOO_CTRL` | `ns_busy` out. `OOO_LSU`: `sq_drained` (the committed stores all in the D$) |

- **Interrupts and non-speculative µops.** A CSR write, an MMIO load or WFI at the head has its effect when it runs,
  before it commits; an interrupt taken then would discard the µop after its effect (an MMIO read twice, a CSR write
  done and then done again). So no interrupt while the head's non-speculative µop has issued (`ns_busy`, which the
  control already had for `ns_ok`). WFI is non-speculative too: it completes when an interrupt is pending, commits,
  and the interrupt is taken before the next µop (mepc after the WFI, as the specification wants).
- **tval**: every unit that reports an exception reports its tval with it (address, instruction bits, or 0) on a
  `tv_*` port (dispatch 2, the LSU); the oldest by ROB position is kept, so the head's own is there when it traps.
  Found while testing: reports of flushed or killed µops still on their way must not be kept (none in the cycle of
  `flush_all`, none younger than the restored branch in the cycle of a restore): kept, a stale one at a small distance
  from the head would look older than the next real one and hide it. The check that the report kept is the head's
  turned out redundant (bug injection), and is gone.
- **FENCE.I does not clear the predictors**: predecode reads the targets of branches and jal from the instructions,
  so after new code a stale uBTB or BTB entry is a misprediction, not a wrong instruction.
- **Contracts for the assembly**: the CSRs (mmRISC-2's `CORE_CSR`) take `csr_trap` / `csr_mret` and give `mtvec`,
  `mepc`, `irq_pend` / `irq_cause` (enabled and pending, by priority) and `wfi_wake`; CSR writes complete marked for
  replay; ECALL / EBREAK / illegal instructions are exceptions at decode with their tval; the units that wake from
  outside, and every unit that reports an exception, follow 20.1 and the tval contract above.

### 22.2 Verification

- **`tb_trap`** (new): OOO_TRAP inside a model ROB of 24: µops dispatched (fused pairs, exceptions), completing out
  of order (an exception with its tval on one of three ports, `done` a cycle later as in the ROB), committing; restores
  at a branch resolving now, replays, MRETs, issued non-speculative heads, interrupts (mtvec direct or vectored), and
  stale reports in the cycles of flush_all and of a restore. Checked: irq, take, the vector, the CSR writes (mepc,
  mcause, mtval), the refetch with no_fuse and its end, the replay pc after MRET. 400,000 cycles, 7,631 traps, 2,477
  refetches, 9,075 interrupts, 4 seeds. Two of my model's mistakes were found on the way (a trap in the cycle of its
  report, a restore at a µop committing then): neither can happen in the core.
- **`tb_sys`** (new): every system µop's steps in order and within 3 cycles of what they wait for, with random answers
  (also answers nobody asked for) and abandoned µops. 400,000 cycles, 4 seeds.
- **`tb_dcad`**: FENCE.I's FLUSH through the adapter to the real D$: after its answer the memory holds every store the
  D$ took before it (102 FLUSHes a run, 5 seeds in both line layouts).
- **`tb_rob`**: interrupts (nothing commits, the ROB empties, the point is the head), head_valid / head_fused.
  **`tb_lsu`**: sq_drained exactly when no committed store is left. **`tb_ctrl`**: ns_busy.
- **Bug injection**: 28 new mutations (M267–M295 but M289) and M197 / M265 retargeted (their ROB lines now have
  `irq`); 260 of 260 detected.

### 22.3 Size (Yosys), and the Vivado runs asked of the author

| Block | Yosys | |
|---|---|---|
| `OOC_TRAP` | 644 | new: mostly the oldest tval (3 report ports of 64 bits and their ROB-age compares) |
| `OOC_SYS` | 18 | new |
| `OOC_ROB` | 1,680 | `irq` |
| `OOC_CTRL` | 399 | `ns_busy` |
| `OOO_DCAD` | 440 | the FLUSH request |

- If OOC_TRAP is as large in Vivado, the tval can be narrower (40 bits: addresses and instruction bits) or take one
  port for the dispatch slots together.
- **Please run** `synth_ooo.bat OOC_TRAP`, `synth_ooo.bat OOC_SYS` (both new in the list), `synth_ooo.bat OOC_ROB`,
  `synth_ooo.bat OOC_CTRL` and `synth_ooo.bat OOC_LSUDC`.

### 22.4 The control is written

All five items of 18.7 are done. What is left before the assembly: the CSRs (`CORE_CSR` with L1), MUL / DIV and the
FPU behind their ports, the I$ and the TLBs (Phase 2), debug, and the core's assembly itself (G1).
