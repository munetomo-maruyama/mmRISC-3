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
