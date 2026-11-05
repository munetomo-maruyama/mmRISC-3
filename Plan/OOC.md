# Phase 0-4: RTL blocks of the fusion configuration, and getting ready for out-of-context synthesis

- Date: 2026-10-24
- Purpose: step 3 of `ISSUES.md` section 5. Write in RTL the blocks of the fusion configuration (`Plan/STRATEGY_A100T.md`
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

### 22.4 The Vivado results (2026-10-28)

| Run | LUT | Before | Worst slack | |
|---|---|---|---|---|
| OOC_TRAP | **203** | (Yosys 644) | +6.577 ns (13 levels) | the worst path is the tval's update: a report's ROB index → the age compares → the enable of `tv_d` |
| OOC_SYS | **15** | (Yosys 18) | +11.501 ns | |
| OOC_ROB | **1,235** | 1,246 | +9.615 ns (17 levels, was 8) | `irq` into the commit and the pointers |
| OOC_CTRL | **351** | 351 | +11.501 ns | `ns_busy` is a register already there |
| OOC_LSUDC | **7,678** | 7,562 | +0.820 ns (was +1.552) | the LSU +2, the adapter 203 (+4); the D$ +110: the adapter can now send FLUSH, so Vivado keeps the D$'s flush machinery it had trimmed (only LOAD and STORE came before). The worst path is still the D$'s stage 1 → the LSU's fill buffer |

- All close at 50 MHz. Yosys's 644 for OOC_TRAP was not Vivado's: no narrowing of the tval is needed.
- **The budget**: the trap unit (203) and the system unit (15) go inside the control's estimate (the control so far
  351 + 69 + 37 + 203 + 15 = 675, against 1.5k to 2.5k); the ROB −11 and the adapter +4 move nothing at 0.1k; the D$
  is counted at mmRISC-2's measured size, which has its flush. The gap stays **3.2k / 4.6k / 5.9k**.

### 22.5 The control is written

All five items of 18.7 are done. What is left before the assembly: the CSRs (`CORE_CSR` with L1), MUL / DIV and the
FPU behind their ports, the I$ and the TLBs (Phase 2), debug, and the core's assembly itself (G1).

---

## 23. mmRISC-2's CSRs and MDU behind port 0 (2026-10-28)

### 23.1 What was done

| Block | What was done |
|---|---|
| `RTL/CPU/CORE/CORE_CSR` | mmRISC-2 Rev.02's CSR file, with one change: `instret_inc` counts the instructions retired in a cycle (0 to 4: two µops of up to two instructions) instead of one bit |
| `RTL/CPU/CORE/CORE_MDU` | mmRISC-2 Rev.02's multiply / divide unit, without change |
| `OOO_CSRU` (new) | The CSR unit: CORE_CSR with `HPM_COUNTERS` = 2 (**L1 applied**). A CSR µop (non-speculative, so at the ROB head and sure to commit) reads, checks and writes its CSR in EX of port 0 (mmRISC-2 wrote at commit; EX at the head is as late as it gets); csrrs / csrrc with x0 do not write; not implemented / not allowed / a write to a read-only CSR is an illegal instruction with the instruction bits as tval; a µop that writes completes marked for replay. Its trap side is OOO_TRAP's: trap entry, MRET / SRET, the vector, mepc / sepc, the interrupt to take and WFI's wakeup |
| `OOO_MDUP` (new) | Port 0's MDU: CORE_MDU (one operation at a time). mul / mulw: latency 2 for the issue queue (started in EX two cycles after the issue, done the cycle after, into port 0's write-back register). The other operations: answered from outside: written when port 0's EX has no latency-1 writer, with their wakeup on `ext_*`; `p0_hold` while one waits. `mdu_ok` (a register) for the issue queue. Killed by mask or flush_all in EX, while CORE_MDU works, or as it is done |
| `OOO_IQ` | An MDU bit per entry (`disp_md`): port 0 gives one only with `mdu_ok`; port 0's latency-1 write slot: a µop that writes in it is not given port 0 in the cycle after a multiply (they would both write in the same cycle) nor with `p0_hold` (it still goes to port 1 if it may); `iss_md` / `iss_md_long` for OOO_MDUP |
| `OOO_DEC` | Latency 2 only for mul / mulw; mulh*, clmul* and the divides answer from outside |
| `OOO_TRAP` | The vector is the CSRs' (`tvec`: mtvec, or stvec for a trap delegated to S), no longer computed from mtvec here; SRET beside MRET (`x_sret`, `csr_sret`, sepc) |
| `OOO_SYS` | SRET; the privilege checks (MRET below M, SRET in U or S with TSR, SFENCE.VMA in U or S with TVM, WFI below M with TW: an illegal instruction with its bits as tval, doing nothing) |

- **D-16 (for the author to confirm): CORE_MDU as it is.** It does one operation at a time: mul is done the cycle after
  its start (latency 2 holds), but the next can start only two cycles later, and mulh / clmul / divides take longer.
  In the model (`Plan/model`, new option `mdu_busy`): −0.8 % / 0 / 0 against a pipelined multiplier; with every
  operation answered from outside, −2.4 % / −0.9 % / −3.0 %. A pipelined multiplier beside CORE_MDU would win the
  0.8 % on -O2 back for LUTs and DSPs.
- **Found: port 0's write slot.** The issue queue let port 0 issue a latency-1 µop in the cycle after a multiply;
  both would write in the same cycle through port 0's one register-file write port (the register file has 3). Now the
  queue does not give port 0 such a µop then (port 1 can take it). The long operations of the MDU write in a cycle
  port 0 leaves free, and hold port 0 until they do.
- **Contracts for the assembly**: the port-0 pipeline completes a CSR µop with its result in the latency-1 slot (the
  CSR unit gives the value, the exception and the replay mark in EX), and an MDU µop through OOO_MDUP (not in EX);
  µops answered from outside are dispatched as writing nothing (`disp_wr` 0: their wakeup is `ext_*`); the tval port
  of port 0 is shared by the CSR unit and the system unit (one at a time at the head); ECALL's cause needs the level
  (CORE_CSR `priv`) at decode.

### 23.2 Verification

- **`tb_csru`** (new): CSR µops on mscratch, sscratch, mepc, mtval, mtvec, mhpmcounter3 / 4 (L1's two),
  mhpmcounter5 / 6 (not there: read 0, writes ignored), minstret, mvendorid and cycle (read only) and a CSR that does
  not exist, every form; the value read, the exception and its tval, the replay mark, what was written read back,
  minstret counting 0 to 4 a cycle, trap entry (mepc sign extended, mcause, the vector direct or vectored) and MRET's
  mepc. 300,000 cycles, 4 seeds. Two of my test bench's mistakes on the way (cycle is read only; an MRET returns to
  MPP, which only a trap from M sets to M).
- **`tb_mdup`** (new): port 0 played by the queue's rules (MDU µops only with mdu_ok, latency-1 writers not after a
  mul nor under p0_hold, a quarter of the time a writer every cycle it may); every MDU operation with operands that hit
  division by zero and the overflow; branch masks, kills, clears, flushes. Checked against the M / Zbc semantics:
  every µop not killed written once with its tag and ROB index, a mul exactly 3 cycles after its issue, a long one
  never over a latency-1 writer and with its wakeup, none killed written, nothing waiting 200 cycles, mdu_ok never
  stuck. 400,000 cycles, 4 seeds.
- **`tb_iq`** (the MDU rules), **`tb_dec`** (latency 2 / outside), **`tb_trap`** (the CSRs' vector, SRET),
  **`tb_sys`** (SRET, the privilege checks with their tval).
- **Bug injection**: 28 new mutations (M296–M324 but M304); M161 / M162 / M231 / M270 / M271 / M279 / M284
  retargeted (their lines changed; M270's vector is CORE_CSR's now); 288 of 288 detected. Decode's `div` was left
  unused by the change of latencies and is gone.

### 23.3 Size (Yosys), and the Vivado runs asked of the author

| Block | Yosys | |
|---|---|---|
| `OOC_CSRU` | 2,823 | new: CORE_CSR with 2 HPM counters (mmRISC-2's CSR in Vivado: 4,750 with 4; L1 estimated −0.65k) |
| `OOC_MDUP` | 3,742 | new: Yosys builds the multipliers of LUTs here; Vivado uses DSP blocks (mmRISC-2's MDU: 3,423) |
| `OOC_TRAP` | 644 | the CSRs' vector instead of mtvec's (Vivado 203 before) |
| `OOC_SYS` | 25 | the privilege checks |
| `OOO_IQ` | 3,078 | the MDU bit, port 0's write slot |

- **Please run** `synth_ooo.bat OOC_CSRU`, `synth_ooo.bat OOC_MDUP` (both new in the list), `synth_ooo.bat OOO_IQ`,
  `synth_ooo.bat OOC_TRAP` and `synth_ooo.bat OOC_SYS`. The budget is updated with them (L1 measured instead of
  estimated).

### 23.4 D-16: what a pipelined multiplier beside CORE_MDU would cost (2026-10-28)

Measured with Yosys (`synth_xilinx -family xc7`, DSP48E1 inferred), two cycles as the latency-2 slot gives (the
operands into the DSPs in EX, the sum in the cycle after):

| Variant | LUT | DSP48E1 | FF | What it wins |
|---|---|---|---|---|
| A: mul / mulw only (the low 64 bits: three 32 × 32 products, the cross ones to 32 bits) | 143 | 10 | 100 | every multiply of CoreMark: the traces of all three builds have 93,960 mulw a run and no mulh, no divide; the 0.8 % on -O2 |
| B: also mulh / mulhsu / mulhu (the 128-bit product, signs corrected) | 499 | 16 | 326 | nothing more for CoreMark; mulh at latency 2 for division by a constant elsewhere |

- Around it: port 0's write-back takes one more 64-bit source (about 64 LUTs), and mul / mulw stop being MDU µops (the
  issue queue's MDU bit only for the long ones, OOO_MDUP's mul path goes): **A is about 0.2k LUTs and 10 DSPs** (32
  of 240 used in mmRISC-2), **B about 0.55k and 16**. CORE_MDU stays as it is for the rest (with A, its multiplier
  still does mulh; with B it would be unused but kept).
- Against the gap (4.6k in the middle), A is 4 % of it for +0.8 % on -O2 only (0 on the other two): about the yield
  of the levers taken (fusion, the best, is about 3 % per 1k on -O2). Recommendation: keep D-16 as it is now, and put A
  on the list of things to buy back at G1 if the whole-core measurement leaves room.

---

## 24. D-16 variant A: the pipelined mul / mulw beside CORE_MDU (2026-10-28)

The author decided D-16 for variant A of 23.4 (`Doc/PROMPT.md` entry 81).

### 24.1 What was done

| Block | What was done |
|---|---|
| `OOO_PMUL` (new) | mul / mulw on port 0, one a cycle, latency 2: in EX the operands go into the DSP blocks (three 32 × 32 products: a_lo × b_lo whole, the cross ones to 32 bits), the cycle after they are summed into port 0's write-back register (mulw: the low 32 bits sign extended). Killed by mask or flush in EX or in the cycle after (that cycle keeps EX's clears, as the LSU's M) |
| `OOO_MDUP` | Only mulh*, clmul* and the divides now (all answered from outside): the mul path, `iss_md_long` and the long / short flag are gone; it writes when port 0's write-back slot is free (`slot_busy`: a latency-1 writer in EX or OOO_PMUL's result) |
| `OOO_IQ` | The MDU bit marks only those (`disp_md`: mul / mulw are latency-2 µops of OOO_PMUL); `iss_md_long` gone. Port 0's write slot after a multiply stays (OOO_PMUL writes there) |

- Performance back to the model's pipelined multiplier: 6.243 / 6.680 / 6.066 (D-15 included); CoreMark has only
  mulw (23.4). Cost: about 0.2k LUTs and 10 DSP blocks (Vivado to confirm).
- **Contract for the assembly**: `disp_md` = an MDU µop answered from outside (decode's `cls` 6 with `ext_ans`); a
  mul / mulw goes to OOO_PMUL from port 0's EX and completes with its result; `slot_busy` = port 0's EX holds a
  latency-1 writer, or OOO_PMUL's `res_valid`.

### 24.2 Verification

- **`tb_pmul`** (new): back-to-back mul / mulw with operands on the signs and the 32-bit edges, branch masks, kills,
  clears, flushes in either cycle (a closed id opens again 5 cycles later at the earliest, as in the core): every µop
  not killed written the cycle after EX with its tag, ROB index and product. 400,000 cycles, 4 seeds.
- **`tb_mdup`**: port 0 now also issues muls for OOO_PMUL (their result takes the slot 3 cycles after the issue); a
  quarter of the time a latency-1 writer every cycle it may and no mul, where the slot comes only by p0_hold.
- **`tb_iq`**: MDU µops only among those answered from outside.
- **Bug injection**: M315 / M316 / M317 / M318 / M319 / M320 retargeted (their lines changed or went), 5 new
  (M325–M329); all detected. Two holes of my test benches found by them: tb_pmul gave a µop the ids open after the
  cycle's kill (so it never carried the killed bit), and tb_mdup's busy phase still had muls, which left the slot free
  without p0_hold.

### 24.3 Size (Yosys), and the Vivado runs asked of the author

| Block | Yosys | |
|---|---|---|
| `OOC_PMUL` | 149 (10 DSP48E1) | new |
| `OOC_MDUP` | 3,759 | the multipliers in LUTs in Yosys; Vivado uses DSP blocks |
| `OOO_IQ` | 2,985 | `iss_md_long` gone |

- **Please run** `synth_ooo.bat OOC_PMUL` (new in the list) with the five of 23.3: `OOC_CSRU`, `OOC_MDUP`, `OOO_IQ`,
  `OOC_TRAP`, `OOC_SYS`.

### 24.4 The Vivado results (2026-10-28)

| Run | LUT | DSP | Before | Worst slack | |
|---|---|---|---|---|---|
| OOC_PMUL | **164** | 10 | (Yosys 149) | +11.501 ns (register to register +12.305, 11 levels) | new |
| OOC_CSRU | **2,537** (CORE_CSR 2,499) | 0 | (Yosys 2,823) | **+0.569 ns** (28 levels: the CSR read) | new |
| OOC_MDUP | **3,258** (CORE_MDU 3,240) | 16 | (Yosys 3,759) | +5.921 ns | new |
| OOO_IQ | **1,894** | | 1,874 | +1.165 ns | +20: the MDU bit, port 0's write slot |
| OOC_TRAP | **217** | | 203 | +6.915 ns | the CSRs' vector, SRET |
| OOC_SYS | **23** | | 15 | +11.501 ns | SRET, the privilege checks |

- **All close at 50 MHz**; the CSR unit with the least margin (its read mux, as in mmRISC-2's EX).
- **In context or out of it.** mmRISC-2's hierarchical report of the whole chip gave CORE_CSR 4,750 LUTs and 2,629
  flip-flops; out of context here it is 2,499 LUTs with 2,475 flip-flops (two HPM counters fewer). The flip-flops say
  the logic is the same; the LUTs differ by more than L1 can (estimated 0.65k). The D$ shows the same kind of gap
  (7,497 in the chip, 5,325 here in OOC_LSUDC), CORE_MDU hardly any (3,423, 3,240). The budget counts mmRISC-2's blocks
  at their in-chip sizes, so it keeps doing that and takes only what was measured as a change; the whole core at G1
  settles which is right.
- **L1 measured**: please run `synth_ooo.bat OOC_CSRU 20.0 1 "HPM=4"` (the harness now has the parameter): the
  difference to this run is what L1 saves, which then replaces its estimate.
- **The budget** (`Doc/UARCH.md` 4.4): D-16's multiplier 164 and its input into port 0's write-back (about 64), the
  issue queue +20; the trap and system units (217, 23) inside the control's estimate (the control so far 697). The gap
  goes to **3.5k / 4.9k / 6.2k**. DSP blocks: 42 of 240 (mmRISC-2's 32 and the multiplier's 10).

### 24.5 L1 measured, and what out of context means against the chip (2026-10-28)

| Run | LUT | FF | WNS |
|---|---|---|---|
| OOC_CSRU, 4 HPM counters (mmRISC-2's configuration) | **2,770** (CORE_CSR 2,732) | 2,623 | +2.081 ns |
| OOC_CSRU, 2 (L1) | 2,537 (CORE_CSR 2,499) | 2,475 | +0.569 ns |
| **L1, out of context** | **−233** | **−148** | |
| L1 in mmRISC-2's chip builds (`Plan/REDUCE.md` B1, measured) | −0.65k (0.4k to 0.9k) | −0.15k | |

- **The budget keeps L1 at −0.65k**: its base is mmRISC-2's in-chip sizes, and B1 is an in-chip measurement too. The
  gap stays **3.5k / 4.9k / 6.2k**.
- **A calibration point, and a risk.** With 4 counters this is mmRISC-2's CORE_CSR exactly (2,623 flip-flops here,
  2,629 in the chip), yet 2,732 LUTs out of context against 4,750 in the chip: **1.74 ×**. The others with both
  numbers: the D$ 1.41 × (5,325 in OOC_LSUDC, 7,497), CORE_MDU 1.06 × (3,240, 3,423), L1's difference 2.8 ×. The flip-flops
  agree, so the logic is the same; the chip adds LUTs (placement at 79 % LUTs / 93 % slices, timing-driven
  replication, logic moved across hierarchy boundaries, LiteX's synthesis settings). **The out-of-order engine is
  measured out of context only** (about 21k LUTs: the ALU ports, issue queue and payload, renaming, register file,
  front end, fetch buffer, FTQ, decode, fusion, ROB, LSU and adapter, the control): if it grew like these in the chip,
  the gap would grow by 1k (1.06 ×) to 15k (1.74 ×). This needs a calibration before G1: mmRISC-2's whole CPU_CORE (32,929 LUTs in the
  chip, every block of it summed so that boundary effects cancel) run out of context with this flow gives the ratio
  for a whole core.


---

## 25. The calibration: mmRISC-2's whole CPU_CORE out of context (2026-10-28)

Asked by 24.5: the same RTL was 1.06 × to 1.74 × larger in mmRISC-2's chip than out of context, and the out-of-order
engine (about 21k LUTs) is measured out of context only.

### 25.1 The run

`synth_ooo.bat MM2_CPU_CORE`: `synth_ooo.tcl` reads mmRISC-2 Rev.02's CPU_CORE alone from `../../../mmRISC-2/RTL`
(beside this repository; mmRISC-3's copies of CORE_CSR / CORE_DEC have the same module names) and synthesizes it with
the same flow (xc7a100tcsg324-1, 20 ns, out of context, place and route), into `output/MM2_CPU_CORE/summary.txt` with
the rows of its instances. CPU_CORE's parameter defaults are those of the chip build (PMP 8, ITLB 16 / DTLB 32, BTB
256, the fetch queue 16 parcels, MEM_BASE 0x8000_0000). The sources lint clean alone (Verilator).

| Block in the chip (`Plan/ISSUES.md` 2) | LUT in the chip | Out of context |
|---|---|---|
| CPU_CORE | **32,929** | (this run) |
| FPU_PIPE | 8,815 | |
| CORE_IFU | 5,738 | |
| CORE_CSR | 4,750 | 2,732 (24.5, through OOC_CSRU) |
| CORE_MMU | 4,190 | |
| CORE_MDU | 3,423 | 3,240 (24.4, through OOC_MDUP) |
| CPU_CORE's own logic | 2,511 | |
| CORE_EXU | 1,670 | |

### 25.2 What it decides

- The ratio R = 32,929 / the run's total, for a whole core: the sum of every block, so logic that moves across the
  hierarchy's boundaries in the chip cancels out.
- **R about 1.0 to 1.15**: out of context is a fair measure of a core; the per-block differences of 24.5 are logic
  attributed to other blocks in the chip. The budget stands.
- **R about 1.3 or more**: the chip really needs more LUTs than out of context (placement at 79 % LUTs and 93 %
  slices, timing-driven replication). The out-of-order engine's 21k would count about 21k × R in the chip: the gap
  grows by (R − 1) × 21k, 6k at R = 1.3. Then a whole-chip trial comes before G1 (as L10 already wants) and the plan
  of the levers is redone.
- The rows of the instances give R block by block, against the chip's rows above.

### 25.3 The result (2026-10-29)

| Block | In the chip | This run (out of context) | |
|---|---|---|---|
| **CPU_CORE** | **32,929** | **33,014** (16,270 FF, 32 DSP) | **R = 1.00** |
| FPU_PIPE | 8,815 | 8,660 | |
| CORE_IFU (with CORE_BTB) | 5,738 | 6,614 (BTB 3,791) | |
| CORE_CSR | 4,750 | **8,251** (2,631 FF) | alone in OOC_CSRU: 2,732 |
| CORE_MMU | 4,190 | 4,269 | its three MMU_PMP: **0** |
| CORE_MDU | 3,423 | 3,410 | |
| CORE_LSU | 946 | 1,142 | |
| CORE_RF / CORE_FRF | 384 / 544 | 390 / 549 | |

- **Out of context measures a whole core as the chip does**: 33,014 against 32,929 (+0.3 %). The risk of 24.5 is gone:
  the out-of-order engine's out-of-context numbers stand, and so does the budget (3.5k / 4.9k / 6.2k).
- **The differences block by block were where Vivado puts logic, not more of it.** Here the PMP checkers (inside
  CORE_MMU, fed by the CSRs' pmpaddr / pmpmask) have 0 LUTs and CORE_CSR 8,251: Vivado optimized the checks across the
  boundary into the CSR block. In the chip a part of them went there (CSR 4,750), alone none (2,732). The D$'s 1.41 ×
  is the same kind of thing. So a block's number is only as good as the boundary it was measured at; sums over whole
  units are what the budget should compare, which it does.
- **Timing**: register to register +0.002 ns, 28 levels: mmRISC-2's core just closes at 50 MHz out of context, as in
  its chip. The worst slack with the ports (−2.496 ns) is the 6 ns of I/O delay on the core's combinational port
  paths (the caches' interface), which the chip does not have.

## 26. The front end put together (OOC_FE), and decode out of the fetch buffer's loop (2026-10-29)

The first Vivado run of the assembled front end (`OOO_FRONT`, B1 of `Plan/CORE.md` 5.2) in the harness `OOC_FE`.

### 26.1 The result

| Run | LUT | of it LUTRAM | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|
| OOC_FE (first version) | 6,602 | 602 | 2,690 | **−2.168 ns** | 23 |

| Instance | LUT | The same block alone |
|---|---|---|
| OOO_FETCH | 2,234 | 2,611 (OOC_FRONT) |
| OOO_FBUF, with decode (Vivado put OOO_DEC's logic in it) | 3,240 | 940 + 1,823 (OOC_FBUF + OOC_DEC) |
| OOO_FTQ (312 bits a block, 4 reads) | 750 | 148 (32 bits, 3 reads; with FERS's read of 312 bits: about 150) |
| OOO_FERS | 53 | (in the 150 above) |
| the rest of OOO_FRONT (skid, group register, outcomes, target array, credit) | about 325 | — |

- **Size**: 1.08k above the parts measured alone (5.52k). Most of it is the FTQ with its four reads (+0.6k; the budget
  had +0.15k to 0.25k for widening it, `Doc/UARCH.md` 4.4), the rest the glue of B1 (about 0.3k). The budget row is
  updated after the rerun.
- **Timing**: all ten worst paths are one loop, from the fetch buffer's head pointer back to it (`hb` → `hoff` / `hb`).

### 26.2 The worst path

| ns | Where |
|---|---|
| 0 → 3.5 | `hb` → the block data (LUTRAM read) |
| → 10.0 | the window and the chain of instruction lengths, to slot 2's bits (through the skid's select) |
| → 12.7 | RVC expansion (CORE_DECOMP) |
| → 16.9 | CORE_DEC's illegal |
| → 17.6 | decode's `cut` (a rare class in slot 1 to 3) |
| → 22.8 | the count taken (`consume`), `npop`, the head parcel `hoff` |

The contract of 13.6 (the count taken must not wait for anything decode computes) was broken by `cut`, which
`Plan/CORE.md` 2.1 sent to the fetch buffer: a full decode, 7.6 ns, sat in the loop.

### 26.3 The fix

- **`OOO_RARE`** (new): whether an instruction is of a rare class (decoded in slot 0 only, G0b G2), **from its first
  parcel alone**: the 32-bit major opcodes LOAD-FP, STORE-FP, the FMAs, OP-FP, AMO, MISC-MEM, SYSTEM; c.fld, c.fsd,
  c.fldsp, c.fsdsp, c.ebreak. Every legal instruction of those classes is caught (and the illegal encodings in those
  opcodes, which then go to slot 0). A few LUTs, 2 or 3 levels.
- **OOO_FRONT** cuts the fetch buffer's group with OOO_RARE on the buffer's own first parcels, before the skid's
  select; decode's `cut` is no longer used there.
- **Illegal is no longer a cut class**: OOO_DEC reports it in every slot (in slots 1 to 3 for an encoding outside the
  rare opcodes; those are cut). Plan/CORE.md 2.1's exception fields come from the µop's own slot. Its `cut` is now
  OOO_RARE's too.
- **The contract of 13.6, as it stands now**: the count taken comes from the buffer's own valid instructions, a
  predecode of their first parcels of a few gates, and a registered stall; nothing of decode.
- Expected: the loop loses the 7.6 ns of decode for about 1 ns of OOO_RARE, and the skid's select: about +4 ns.

### 26.4 Verification

- **`tb_dec`**: the expected `cut` from a predecode written in the test from the opcode list; every legal instruction
  of a rare class must be caught by it (decode leaves their fields out in slots 1 to 3); illegal checked in every slot.
  3 million instructions (1.5 million illegal) and every RVC encoding: PASS.
- **B1** (`SIM/CORE/run_front.sh`): 175 riscv-tests on 2 seeds and both CoreMark builds in both modes: PASS (the bench
  checks that the CSR / FP / system classes D2 sees are those of the bits, in every slot).
- **Bug injection**: SIM/OOO_UNIT M192 rewritten and M331 to M339 added (OOO_RARE's opcodes, c.ebreak, the RVC FP
  loads and stores, the RVC / 32-bit select; illegal in slot 0 only): all detected. `SIM/CORE/mutate_front.py`'s cut
  mutation follows the new line. B1's campaign: 35 of 35. All 28 unit tests PASS; the unit campaign now has 303 mutations.
- Not a mutation: in slots 1 to 3 illegal is masked by the rare opcodes only so that synthesis can drop the legality
  decode of the rare classes there; without the mask nothing changes but the size.

### 26.5 Please rerun

- `synth_ooo.bat OOC_FE` (the fix), and `synth_ooo.bat OOC_DEC` (decode now reports illegal in every slot and takes
  its cut from OOO_RARE: its size may move a little).

### 26.6 The rerun (2026-10-29)

| Run | LUT | of it LUTRAM | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|
| OOC_FE (first version) | 6,602 | 602 | 2,690 | −2.168 ns | 23 |
| **OOC_FE (fixed in 26.3)** | **6,162** | 602 | 2,696 | **+0.030 ns** | 18 |
| OOC_DEC (before) | 1,823 | 0 | 504 | +7.813 ns | 9 |
| **OOC_DEC (illegal in every slot, cut from OOO_RARE)** | **1,807** | 0 | 507 | **+7.900 ns** | 9 |

| Instance | Before | Now |
|---|---|---|
| OOO_FBUF, with decode | 3,240 | **2,849** (940 + 1,807 alone: +0.1k) |
| OOO_FETCH | 2,234 | 2,211 |
| OOO_FTQ | 750 | 745 |
| OOO_FERS | 53 | 54 |
| the rest of OOO_FRONT | about 325 | about 303 |

- **The loop is gone from the worst paths, and the size fell by 440 LUTs**: the fetch buffer with decode lost 391
  (no `cut` from decode, and no longer squeezed to make the loop). Against the parts as the budget counts them
  (OOC_FRONT 2,588, fetch buffer 940, FTQ 148, decode 1,808, the FTQ widened 0.15k to 0.25k) OOC_FE is **+0.4k to
  +0.5k**: the FTQ's four reads beyond the widening allowed for, and the glue. The budget (`Doc/UARCH.md` 4.4) takes
  the measured 6,162 in place of those parts.
- **But it closes by 0.030 ns only.** All ten worst paths are one forward path, not a loop: the head pointer `hb` →
  the block data (LUTRAM) → the window and the chain of instruction lengths to **slot 3**'s bits (through the skid's
  select) → **the whole decode of slot 3** → the group register (`g_d[3]`: `rd`'s reset, `port`, `cls`, `ext_ans`,
  `lat2`).

| ns | Where |
|---|---|
| 1.0 → 4.0 | `hb` (fan-out 150) → the block data (LUTRAM read) |
| → 10.9 | the window and the length chain, to slot 3's bits (the skid's select) |
| → 20.4 | decode of slot 3 (RVC expansion, CORE_DEC, the slot's fields): 9 levels, 9.5 ns |

  This is D1 as planned (read the buffer and decode in one cycle), 80 % of it routing. Inside the whole core, place
  and route will be worse, and 13.6 judged 0.539 ns too thin: **this margin is not enough**. The loop's own slack is
  not in the reports (all ten paths end at `g_d[3]`); without decode it is at least that of OOC_FBUF alone in 13.7
  (+3.5 ns) less OOO_RARE.

### 26.7 What can be done (proposed)

| Way | Effect on the path | Cost |
|---|---|---|
| **A. A raw stage before decode** (D1a: the window into a raw register; D1b: decode from it into the group register) | The read and the window get a cycle (about 11 ns), decode gets a cycle (about 12 ns, as OOC_DEC alone): both with about 8 ns of slack | One cycle more from a redirect to D2: **−0.3 % / −0.2 % CoreMark/MHz** in the model (`dec_depth` 2 → 3: 6.191 → 6.172, 6.675 → 6.660); about 170 FFs and a few tens of LUTs |
| B. Trim D1 as it is (`hb` duplicated against its fan-out of 150, the instruction starts precomputed when a block is written) | 1 to 2 ns, not sure | A few tens of LUTs; the starts need fetch's predecode to give them |
| C. Keep it | — | The risk at G1 |

- Not possible: decoding slots 2 and 3 a cycle later from the group register. Fusion (`OOO_FUSE`, 4 instructions → 2
  µops) may take all 4 slots in the cycle after the group register loads.
- **A, in detail**: the raw register R takes the fetch buffer's group; R moves into the group register (decoded)
  when the group register empties (`g_left` = 0, which waits for D2's `g_take`). For the fetch buffer's `consume` to
  stay free of `g_take` (13.6), the existing skid stays as a second raw entry: the buffer gives while the skid is
  empty (a registered condition); R takes the skid's group, or the buffer's. The skid's select moves in front of R,
  out of the path to decode.
- **Recommended: A.** It costs 0.2 to 0.3 % and makes both halves of D1 close with room, where B is a guess, and the
  front end is the one block whose timing the whole core cannot help (its paths are long and 80 % routing already
  alone). If it is taken: OOO_FRONT, B1 (`tb_front` follows the extra stage), the front end's mutations, and a report
  of the loop's own worst path in `synth_ooo.tcl` for OOC_FE.

### 26.8 A applied: D1a / D1b (2026-10-29)

**The RTL** (`OOO_FRONT`):

| Stage | What | Its path |
|---|---|---|
| D1a | The fetch buffer's group goes raw (4 × 41 bits) into the register R when R is freed in this cycle (R empty, or moving into the group register), else into the skid S; R takes S's group when S holds one. The buffer gives while S is empty (`consume` as before: its valid instructions up to the first rare class, 0 while S is full) | `hb` → LUTRAM → window → the select of S or the buffer (by S's occupancy, a register) → R |
| D1b | R is decoded, and its two lines read from the FTQ (`rd_idx` from R's blocks, a register now), into the group register when D2 empties it | R → decode → group register |
| D2 | as before | |

- R's freeing waits for `g_take` (D2) but only enables R and S; nothing of it reaches `consume` (13.6). S holds a group
  only while R does, so a group of 4 still follows one D2 takes in 2 cycles without a bubble.
- Lint (`-Wall`): only PINCONNECTEMPTY, as before.

**B1** (`SIM/CORE/run_front.sh`): all pass (175 riscv-tests on 2 seeds, both CoreMark builds both ways, every TAGE
update and restore checked).

**What it costs, and what B1 found about the FTQ.** With `-full` (no I$ miss, D2 takes 2 a cycle) the front end
delivered 1.504 / 1.560 instructions a cycle before, **1.442 / 1.488** now (g14 -O2 / sf + -flto): −4 %, not the
−0.3 % of the model. The difference is the FTQ: a block stays in it from its push to the pop after its last commit,
fetch asks only while it has room, and with 8 entries it is full most of the time; one stage more keeps each block a
cycle longer. With 16 entries the stage costs almost nothing (`-full`, instructions a cycle, -O2 / sf + -flto; "old"
is the RTL before this section, built from git):

| Commit after D2 | old, FTQ 8 | new, FTQ 8 | old, FTQ 16 | **new, FTQ 16** |
|---|---|---|---|---|
| 2 cycles | 1.834 / 1.826 | 1.814 / 1.828 | 1.835 / 1.827 | 1.826 / 1.829 |
| 4 cycles | 1.806 / 1.823 | 1.755 / 1.794 | 1.830 / 1.824 | 1.825 / 1.822 |
| 7 cycles | 1.668 / 1.719 | 1.572 / 1.644 | 1.829 / 1.825 | 1.824 / 1.824 |
| 10 cycles | 1.455 / 1.514 | 1.386 / 1.435 | 1.830 / 1.821 | 1.825 / 1.825 |
| 4 to 10 at random (B1's default) | 1.504 / 1.560 | 1.442 / 1.488 | 1.833 / 1.821 | **1.824 / 1.826** |

- **The FTQ of 8 blocks is too small, with or without the stage**: 7 cycles from D2 to commit already cost 9 %, 10
  cycles 21 %. In the core a block waits for the ROB (24 µops, about 7 blocks of 3.3 instructions) besides the fetch
  buffer (4 blocks) and D1 / D2: the FTQ must cover them all, about 14 to 16 blocks. **The model has no FTQ** (it
  never stops fetch for it), so its CoreMark numbers assume one large enough.
- **With 16 the stage costs 0.0 % to 0.5 %**, as the model said (−0.2 % / −0.3 % CoreMark/MHz for `dec_depth` 3).
- **The cost of 16**: the FTQ's LUTRAM is the same (a RAM32M holds 32 rows at any depth up to 32), the target array
  too; the outcomes of the slot branches grow from 128 to 256 flip-flops with 16:1 selects in place of 8:1 at the pop,
  and every FTQ index gets a bit (the fetch buffer, OOO_FERS, OOO_CTRL, the ROB's payload). About +0.1k to 0.2k LUTs.
  Proposed as **D-18** (`Doc/UARCH.md` chapter 9); `SIM/CORE/ftqdepth.sh` measures it (`tb_front` and
  `build_front.sh` now take the FTQ's size, `FTQW`).

**Bug injection** (`SIM/CORE/mutate_front.py`): the skid's and the group register's mutations follow the new lines
(7 rewritten), 5 added for R (the skid's group or the buffer's, R's bits and blocks from the skid, R not freed when
it moves, R empty not counted as free) and one for R alone not flushed: **40 of 40 detected**. The first run left
"R empty not counted as free": a group then waits in the skid a cycle for nothing, which costs only cycles. The
bench now checks that the skid holds a group only while R does.

**Vivado** (`synth_ooo.tcl`): for OOC_FE, `summary.txt` now also gives the worst path into each stage of D1 (the
fetch buffer's loop into `hb` / `hoff`, D1a into R and S, D1b into the group register), and `timing_d1.rpt` their
paths in full, so that the loop's slack shows even when it is not among the ten worst.

**Please run** `synth_ooo.bat OOC_FE`. Expected: D1a and D1b each with several ns of slack; the size about +0.2k
(R's 164 bits and its select, now a register's input instead of decode's).

### 26.9 D-18 applied: the FTQ of 16 blocks (2026-10-29)

The author took D-18 (`Doc/PROMPT.md` entry 94).

- **RTL**: the default FTQ is 16 entries, its index 4 bits (`NFTQ` 16, `FTQW` 4 in OOO_FTQ and OOO_FRONT; `FTQW` 4 in
  OOO_FERS, OOO_FBUF, OOO_CTRL and OOO_ROB). Nothing else changes: every block was written for any power of two.
  OOO_FRONT's credit (the smaller of the fetch buffer's and the FTQ's room) is written without a truncated
  intermediate (lint with the 5-bit free count).
- **Tests**: tb_ftq (16 entries), tb_fers (an FTQ of 16 blocks), tb_fbuf, tb_ctrl (the FTQ mirror), tb_rob (4-bit
  indices), tb_fetch (its FTQ model of 16); `tb_front` and `build_front.sh` default to 16 (`FTQW=3` builds 8).
- **Harnesses**: OOC_FE has the 16 (295 bits in, 753 out); OOC_ROB, OOC_FBUF, OOC_FTQ, OOC_CTRL and OOC_FERS keep the
  8 (index of 3 bits) they were measured with. Lint (`-Wall`) of OOC_FE and OOC_ROB: only PINCONNECTEMPTY.
- **Results**: all 28 unit tests PASS; B1 PASS (175 riscv-tests on 2 seeds, both CoreMark builds both ways). The
  front end delivers **1.824 / 1.826** instructions a cycle with `-full` (1.442 / 1.488 with 8), 0.883 / 0.888 at
  random (0.856 / 0.868).
- **Bug injection**: the unit mutations of the blocks touched (FTQ, FERS, FBUF, CTRL, ROB, fetch): 84 of 84
  detected. The front end's first run left 2 of 40: "credit: the FTQ not counted" and "FTQ: one free too many". With
  16 blocks the FTQ never fills at B1's delays (4 to 10 cycles to commit), so a credit past it is never used. B1 now
  also runs the riscv-tests with `-full` and commit 40 cycles after D2, where the FTQ is full in about 100 to 200
  cycles a program (`tb_front -v` counts them), and the campaign runs that too: **40 of 40 detected**.
- **Please run** `synth_ooo.bat OOC_FE` (D1a / D1b and the FTQ of 16 together). Expected: D1a and D1b with several
  ns of slack; the size about +0.2k for R and +0.1k to 0.2k for the FTQ of 16. The budget (`Doc/UARCH.md` 4.4) is
  updated with the result.

### 26.10 The rerun with D1a / D1b and the FTQ of 16 (2026-10-29)

| Run | LUT | of it LUTRAM | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|
| OOC_FE (26.3: decode out of the loop) | 6,162 | 602 | 2,696 | +0.030 ns | 18 |
| **OOC_FE (D1a / D1b, FTQ 16)** | **6,171** | 602 | 3,015 | **+0.622 ns** | 18 |

| Path (the new report of `synth_ooo.tcl`) | Slack | Levels |
|---|---|---|
| the fetch buffer's loop (into `hb` / `hoff`) | **+0.622 ns** | 18 |
| D1a (into R and the skid) | +5.005 ns | 14 |
| D1b (R → decode → group register) | +5.752 ns | 15 |
| next: fetch's training of the uBTB from the I$ answer (a harness input) | +0.715 ns | 16 |

| Instance | Before | Now |
|---|---|---|
| OOO_FBUF | 2,849 (decode put in it) | 1,030 (decode now in OOO_FRONT) |
| OOO_FTQ | 745 | **950** (16 entries: the LUTRAM the same, 302; the logic +205) |
| OOO_FETCH | 2,211 | 2,209 |
| OOO_FERS | 54 | 23 |
| the rest of OOO_FRONT (decode, R, the skid, the group register, outcomes, target array) | about 303 | about 1,959 |

- **D1 splits as planned**: D1a and D1b each have 5 to 6 ns. Decode, now from a register, is no longer replicated for
  timing: the fetch buffer with decode, R and the rest come to 163 LUTs less than before, which pays for the FTQ of 16
  (+205 in OOO_FTQ; 128 flip-flops more for the outcomes). **The whole is +9 LUTs**; FFs +319 (R's 164 bits, the
  outcomes, the skid's place).
- **The worst path is now the fetch buffer's loop, +0.622 ns** (19.0 ns, 18 levels):

| ns | Where |
|---|---|
| 1.0 → 5.0 | `hb` (fan-out 150) → the block data (LUTRAM read) |
| → 12.0 | the window and the length chain, to **slot 3's first parcel** (all its 16 bits) |
| → 15.1 | OOO_RARE on it and the group's run (4 levels) |
| → 15.9 | `consume` |
| → 20.0 | `npop`, `nblk` → `hb` |

  In OOC_FBUF alone (13.7, +3.5 ns) `consume` waited only for the slots' valid bits, which come from the length chain
  without the whole parcel. OOO_RARE needs slot 3's parcel, which comes out of the slot's select at 12.0 ns, and adds
  its levels after it: about 3 ns more than expected in 26.3. The FTQ of 16 is not on the path.
- **The uBTB's training (+0.715 ns)** starts at the harness's register of the I$ answer: predecode → the uBTB's
  update enables. It was +0.574 ns in OOC_FRONT alone (`Doc/UARCH.md` 6.10) and its start depends on how the I$ gives
  its data in the core; not changed here.

### 26.11 The rare classes told from the window's parcels (proposed)

- **Where**: OOO_FBUF. OOO_RARE on each of the window's 8 parcels (`w[k]`, out of the LUTRAM before any instruction
  is picked), in parallel with the length chain; each slot then takes the bit of its own first parcel with the
  select that already takes its length (`w[st[i]][1:0]`). A new output `out_rare[3:0]`, which OOO_FRONT uses in place
  of its four OOO_RARE on the slots' bits.
- **Effect**: slot 3's rare bit arrives with its length bit (about 10 ns) instead of at 15.1 ns: the loop gains
  about 2 to 3 ns, back near OOC_FBUF alone (+3.5 ns).
- **Cost**: 8 OOO_RARE in place of 4 (about +20 to 40 LUTs) and four 1-bit 8:1 selects; no storage.
- **Tests**: tb_fbuf checks `out_rare` of each slot against the predecode of its first parcel; B1 unchanged (the
  group's cut is the same); a mutation of the select (a slot's bit from the parcel after its own) and of a window
  parcel's OOO_RARE.
- **Recommended**: yes, before the core is put together. The alternative, storing a rare bit per parcel at the
  write, costs 32 bits of LUTRAM for the same timing.

### 26.12 26.11 applied: the rare classes from the window (2026-10-29)

- **OOO_FBUF**: OOO_RARE on each of the window's 8 parcels (`w[k]`), and a new output `out_rare[i] = wr[st[i]]`,
  taken with the select that takes the instruction's length bit. **OOO_FRONT** cuts the group at `out_rare` and
  loses its four OOO_RARE on the slots' bits.
- **OOC_FBUF** cuts its group at `out_rare` too, as OOO_FRONT does (so that the harness's loop is the core's), gives
  `out_rare` out (173 bits) and connects `free_n` (left out since B1). Lint (`-Wall`) of OOC_FBUF and OOC_FE: only
  PINCONNECTEMPTY.
- **tb_fbuf** checks every slot's `out_rare` against a predecode of its first parcel written in the test from the
  opcode list (G2), with c.ebreak parcels put in the random program: 4 seeds PASS, about 270,000 to 370,000 rare
  slots given each.
- **All 28 unit tests PASS; B1 PASS**, with the same numbers as before (the group is cut the same way: 1.824 / 1.826
  instructions a cycle with `-full`).
- **Bug injection**: M340 to M342 added to SIM/OOO_UNIT (a slot's rare bit from the parcel after its own, every
  window parcel told by the first one's opcode, AMO not rare as the fetch buffer sees it; 306 in all). With the fetch
  buffer's other mutations and OOO_RARE's in tb_dec: 18 of 18 detected. The front end's campaign: 40 of 40.
- **Please run** `synth_ooo.bat OOC_FE` (and `OOC_FBUF`, whose harness now has the loop of the core). Expected: the
  loop at about +2.5 to 3.5 ns; the size about +20 to 40 LUTs.

### 26.13 The rerun with the rare classes from the window (2026-10-29)

| Run | LUT | of it LUTRAM | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|
| OOC_FBUF (13.7: the count taken from the valid instructions only) | 940 | 192 | 323 | +3.541 ns | 14 |
| **OOC_FBUF (cut at `out_rare`, as in the core)** | **1,001** | 192 | 327 | **+3.078 ns** | 15 |
| OOC_FE (26.10) | 6,171 | 602 | 3,015 | +0.622 ns | 18 |
| **OOC_FE (`out_rare`)** | **6,231** | 602 | 3,015 | **+0.868 ns** | 18 |

| OOC_FE's paths | 26.10 | Now |
|---|---|---|
| the fetch buffer's loop | +0.622 ns (18 levels) | **+1.016 ns** (17) |
| D1a / D1b | +5.005 / +5.752 ns | +5.299 / +5.451 ns |
| the TAGE update (the FTQ's head read → TAGE's update → its block RAM's write data) | (not among the ten) | **+0.868 ns** (18) |
| the uBTB's training (fetch's `carry_v` → predecode → an entry's write enable) | +0.715 ns (from the harness's input) | **+0.943 ns** |

- **The loop gained less than expected**: +0.39 ns, not 2 to 3 ns. The rare bit now arrives about 1.3 ns earlier (the
  group's run ends at 14.2 ns, was 15.1 + 0.8), but in the whole front end the loop is 2 levels and about 1.8 ns of
  routing longer than in OOC_FBUF alone (18.6 against 16.8 ns; 79 % routing; `hb` drives 150 loads). Alone, the cut
  at `out_rare` costs only 0.46 ns against no cut at all.
- **Size**: +60 LUTs in OOC_FE (+61 in OOC_FBUF: the 8 OOO_RARE and their selects), more than the 20 to 40 estimated.
- **Three families of paths are now within 0.15 ns of one another (+0.87 to +1.02 ns)**, all about 80 % routing: the
  TAGE update, the uBTB's training and the fetch buffer's loop. Placement decides which is worst; in the whole core
  (about 3.5 times the LUTs) routing will be longer.

### 26.14 What can be done next (proposed)

| Way | Path | Cost | Effect on the predictions |
|---|---|---|---|
| **A. Register the TAGE update**: the popped block's metadata and outcomes into a register, TAGE updated from it a cycle later | the TAGE update: the FTQ's LUTRAM read and the update logic each get a cycle | about 280 FFs, a few LUTs | the update a cycle later (about half a block more than B1's 6.5 blocks): the RTL's algorithm with 6 → 7 blocks of delay gave +194 / +36 mispredicted branches (`Plan/model/results/tagedelay.txt`), about 0.1 % of CoreMark or less |
| **B. Register the uBTB's training** (14.6: "the training can be registered and applied a cycle later") | the uBTB's training | about 50 FFs (the entry's tag, target, offset, the update's enable) | a uBTB entry written a cycle later; a block fetched in that cycle may miss it once |
| C. Duplicate `hb` (fan-out 150) in the fetch buffer | the loop: its first nets | a few FFs | none |
| D. Leave them for G1 | — | — | — |

- **Recommended: A and B now, C at G1 if the loop is then the worst.** A and B are what 14.6 and 5.3 already planned
  as the levers, each costs only flip-flops and changes the predictions by little, and they take two of the three
  families off the edge; B1 checks both (the update against the push's record a cycle later, the mispredictions with
  `-mpki-max`). The loop has +3.1 ns alone; whether its routing in the core needs C shows only there.

### 26.15 26.14 A and B applied: the TAGE update and the uBTB's training registered (2026-10-30)

- **A (OOO_FRONT)**: the popped block's update (`up_valid`, the 270 bits of metadata from the FTQ's head read, the
  slots run and their outcomes) goes into a register (`up_*_q`, 277 flip-flops); TAGE is updated from it a cycle
  after the pop. OOO_FETCH and OOO_TAGE are unchanged.
- **B (OOO_FETCH)**: F2's training of the uBTB (valid, pc, taken, target, cond, ret: 80 flip-flops) goes into a
  register and reaches OOO_UBTB a cycle after the override. The uBTB's invariant (no two entries with the same tag
  and parcel) holds: the writes stay one a cycle, in order, each matched against the table as it is then.
- **Tests**:
  - tb_fetch's mirror of the uBTB takes each training a cycle after the override (it checks every F0 address with
    it): PASS on 4 seeds.
  - `tb_front` checks every cycle that TAGE's update is the pop's of the cycle before (all 270 bits).
  - All 28 unit tests PASS; B1 PASS (`run_front.sh`, the 5 runs).
- **Predictions** (B1, CoreMark g14 -O2 / sf + -flto; the cycles hardly move):

| B1 | before | registered |
|---|---|---|
| mispredicted, D2 at random | 6,561 / 5,862 | 6,796 / 6,114 (+235 / +252) |
| mispredicted, `-full` | 6,511 / 5,868 | 6,619 / 5,907 (+108 / +39) |
| instructions a cycle, `-full` | 1.824 / 1.826 | 1.824 / 1.828 |

  About +0.1 to 0.25k mispredictions, as 26.14 expected from the model (6 → 7 blocks of delay: +194 / +36); at about
  10 cycles each, 0.1 to 0.2 % of CoreMark's cycles.
- **Bug injection**: SIM/OOO_UNIT M343 to M345 (the uBTB never trained, the training at the next cycle's address,
  trained in the override's cycle with the last training's fields; 309 in all): with the fetch and uBTB mutations, 29
  of 29 detected. The front end's campaign: 3 added (TAGE never updated, the slots run taken from the outcomes, TAGE
  updated at the pop with the metadata of the pop before): **43 of 43**.
- **Please run** `synth_ooo.bat OOC_FE` (and `OOC_FRONT`, the fetch side alone, for the uBTB's training). Expected:
  the TAGE update and the uBTB's training off the edge (each with several ns); the worst path the fetch buffer's
  loop at about +1 ns; about +360 flip-flops and a few LUTs.

### 26.16 The rerun with the TAGE update and the uBTB's training registered (2026-10-30)

| Run | LUT | of it LUTRAM | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|
| OOC_FRONT (fetch alone, 6.10: the uBTB's training) | 2,611 | 82 | 2,112 | +0.835 ns | 16 |
| **OOC_FRONT (training registered)** | **2,570** | 82 | 2,119 | **+2.235 ns** | 15 |
| OOC_FE (26.13) | 6,231 | 602 | 3,015 | +0.868 ns | 18 |
| **OOC_FE (both registered)** | **6,184** | 602 | 3,288 | **+1.095 ns** | 17 |

| OOC_FE's paths | 26.13 | Now |
|---|---|---|
| the fetch buffer's loop | +1.016 ns | **+1.095 ns** (the 7 worst paths, to +2.49 ns) |
| D1a / D1b | +5.299 / +5.451 ns | +5.893 / +5.076 ns |
| the TAGE update | +0.868 ns | not among the ten (above +2.68 ns) |
| the uBTB's training | +0.943 ns | not among the ten |
| next: fetch's head pc → the RAS's LUTRAM write enable | — | +2.683 ns (15 levels) |

- **Both trainings are off the edge**, as expected: in OOC_FE neither is among the ten worst paths; in OOC_FRONT
  (fetch alone) the uBTB's training gave way to the RAS's write enable, +0.835 → +2.235 ns.
- **The fetch buffer's loop is now the only family under +2 ns**: +1.095 ns, 17 levels, its own seven paths.
- **Size**: OOC_FE −47 LUTs (the TAGE update logic, no longer squeezed into one cycle with the FTQ's read, is
  smaller; Vivado now puts it in OOO_TAGE, 527 → 786, the FTQ 952 → 663), +273 FFs (the two registers, 357 bits,
  partly merged). OOC_FRONT −41 LUTs.
- **The budget** (`Doc/UARCH.md` 4.4): OOC_FE 6,184 in place of 6,231.
- **The front end stands here until G1**: the loop's lever (duplicating `hb`, 26.14 C) waits for the whole core,
  where routing decides whether it is needed.

### 26.17 OOC_FE with the pc array and the second target-array read (B2, 2026-10-31)

| Run | LUT | of it LUTRAM | FF | Register-to-register slack | Logic levels |
|---|---|---|---|---|---|
| OOC_FE (26.16) | 6,184 | 602 | 3,288 | +1.095 ns | 17 |
| **OOC_FE (pc array, 2 target-array reads)** | **6,254** | 676 | 3,408 | **+1.703 ns** | 15 |

- **+70 LUTs**, nearly all LUTRAM (+74): the pc array (16 × 35 bits) and the second read of the target array, as
  `Plan/CORE.md` 4.1 / 4.5 expected ("tens of LUTs" each).
- **The worst path is fetch's head pc → the RAS's LUTRAM write enable** (+1.703 ns, 15 levels); the fetch buffer's
  loop is +2.019 ns this time (+1.095 before: placement), D1a / D1b +5.4 / +5.3 ns. No path is under +1.7 ns.
- The budget (`Doc/UARCH.md` 4.4): OOC_FE 6,254 in place of 6,184.

### 26.18 The blocks changed for CoreMark (Plan/CORE.md 5.7 to 5.14, 2026-11-01)

| Run | LUT | FF | Slack (all / register to register) | What changed |
|---|---|---|---|---|
| OOC_LSU | 1,947 → **1,949** | 2,317 → 2,309 | +7.031 ns (+6.548) | a load completes in M (5.14) |
| OOC_LSUDC | 7,681 → **7,573** | 7,527 → 7,372 | +1.340 ns (+1.964) | the same; the D$ placed differently (−115), the LSU 2,153 |
| OOO_IQ | 1,894 → **1,951** | 464 → 474 | **+0.360** / +5.884 ns (+1.165 / +6.605) | loads wait for the older stores (5.9), port 1's slot after a multiply (5.13) |
| OOC_FE | 6,254 → **6,622** | 3,408 → 3,418 | **+0.863 ns** (+1.703) | D-17 (5.11): TAGE 785 → 1,014 |
| OOC_CSRU | 2,537 → **2,695** | 4,454 → 4,523 | +1.066 ns (+0.569) | mconfigptr, the FP CSRs with FS off, mcountinhibit at commit (5.7) |

- **OOO_IQ**: the worst path is now a store bit (`tq`) → the load's wait term → ready → select → `iss_entry` (the
  payload's read address): the 10-bit AND-OR of `older & v & st` sits in front of the select. The register-to-register
  paths are fine (+5.9 ns). **To do**: keep the wait as a register per entry, its next state computed from the issue
  and the kills of the cycle (off the select).
- **OOC_FE**: +368 LUTs, TAGE +229 of it (D-17's 7:1 shift of the history in front of the four folds, against the
  0.15k expected), the uBTB +78 and the RAS +43 (placement). The worst path is the fetch buffer's loop (+0.863 ns, 17
  levels; +2.019 last time: the fetch buffer did not change, the larger design placed it differently); no TAGE path is
  among the ten worst (all above +1.35 ns).
- **OOC_CSRU**: +158 LUTs, +69 FF, nearly all for holding a write to mcountinhibit until its commit (64 bits held and
  a 64-bit select on CORE_CSR's write; Yosys: +182 LUTs, +65 FF; the FS check about +90). **To do**: count the writing
  instruction under the old bit without holding the write (CORE_CSR writes it in EX as before; OOO_CSRU keeps the old
  and new IR bits, and the commit counts one more, or one less, through a small input of CORE_CSR's minstret
  increment): a few flip-flops and LUTs.
- **OOC_LSU / OOC_LSUDC**: a load's completion from M is not on the worst paths (OOC_LSUDC's is the D$'s address
  → the SQ's valid bits, as before; −0.6 ns of placement).
- The budget (`Doc/UARCH.md` 4.4): +0.6k (OOC_FE +368, the issue queue +57, the CSR unit +158, the LSU +2).

### 26.19 26.18's two fixes (Plan/CORE.md 5.15, 2026-11-01)

| Top | Yosys before → after (LUT / FF) | What changed |
|---|---|---|
| OOO_IQ | 3,118 / 474 → 3,119 / 484 | the load's wait a register per entry (`wtq`), set at dispatch, cleared when the last older store leaves |
| OOC_CSRU | 3,040 / 4,538 → 2,732 / 4,474 | mcountinhibit written in EX again; the writer's commit one less (IR cleared) or one more (IR set, `instret_force`) |

- **OOO_IQ**: the same LUTs, 10 more flip-flops; what the select sees of the wait is one register bit, so the logic in
  front of the select is back to what it was before 5.9 (the next state takes the grants, as the age matrix does, after the
  select). The issue sequence is the same, cycle for cycle (`tb_iq` unchanged).
- **OOC_CSRU**: −308 LUTs and −64 FF in Yosys (the hold +182 / +65 by the same tool): Vivado's 2,695 should go back
  near 26.18's start (2,537) plus the FS check.
- Vivado to rerun: `synth_ooo.bat OOO_IQ` and `synth_ooo.bat OOC_CSRU`.

### 26.20 The rerun after 26.19 (2026-11-01)

| Run | LUT | FF | Slack (all / register to register) |
|---|---|---|---|
| OOO_IQ | 1,951 → **1,997** | 474 → 484 | **+0.371** / +6.607 ns (+0.360 / +5.884) |
| OOC_CSRU | 2,695 → **2,496** | 4,523 → 4,456 | **+3.509 ns** (+1.066) |

- **OOC_CSRU**: −199 LUTs, below 26.18's start (2,537) although the FS check stays: the hold was all of the growth.
  CORE_CSR 2,683 → 2,476. The slack went from +1.066 to +3.509 ns (26 levels, the counters' compare).
- **OOO_IQ**: the load's wait is off the worst path, and register to register is back (+6.6 ns), but the worst path
  is now the same shape one bit over: a non-speculative bit (`nq`) → `(older & v & ns) == '0` → ready → select →
  `iss_src` (the payload's source tags out, 6 ns of output delay): 12 levels, 10.7 of 12.6 ns in the routes. The
  non-speculative term has been there since 19.4; before 5.9 the same placement gave +1.165 ns. +46 LUTs, the wait's
  next state (Yosys +1).
- **What can be done**: the non-speculative term as the wait was made, a register per entry ("an older
  non-speculative entry stays"), the select seeing only `ns_ok` and that bit; about 10 FFs. 50 MHz is met as it is;
  the output delay of the out-of-context run is a guess for what feeds the PRF's read in the core (B7 measures it).
- The budget (`Doc/UARCH.md` 4.4): −0.15k (the CSR unit −199, the issue queue +46).

### 26.21 The non-speculative term a register (Plan/CORE.md 5.16, 2026-11-01)

26.20's worst path: the non-speculative term becomes a register per entry (`wnq`), as the load's wait did. Yosys:
OOO_IQ 3,119 → 3,221 LUTs, 484 → 494 FF. In front of the select there is no AND-OR over the other entries left:
ready is the operands, `ns_ok` and the two wait bits. Vivado to rerun: `synth_ooo.bat OOO_IQ`.

### 26.22 The rerun after 26.21 (2026-11-01)

| Run | LUT | FF | Slack (all / register to register) |
|---|---|---|---|
| OOO_IQ | 1,997 → **1,999** | 484 → 494 | **+1.735** / +7.219 ns (+0.371 / +6.607) |

- Both waits are off the worst paths. The worst is now the select itself: an entry's port (`pq`) → its request →
  the oldest-first grant → `iss_src` out (10 levels, 9.4 of 11.3 ns in the routes, 6 ns of output delay); register
  to register it is the wakeup-select loop (`rq` → ready → select → the issued tags → `rq`, 11 levels, +7.2 ns), the
  loop the queue is built around. Better than before 5.9 (+1.165 / +6.605).
- +2 LUTs for the two wait registers (Yosys +102): the budget stays as in 26.20.

## 27. The whole core out of context (B7, 2026-11-01)

`synth_ooo.bat OOO_CPU`: mmRISC-3's core with its D$ (OOO_CORE, OOO_DCAD, DCACHE) as the top, its own ports with the
30 % I/O delay, as MM2_CPU_CORE (25). Plan/CORE.md 5.17.

### 27.1 What the run is compared with

| Part | From the blocks (Vivado, out of context) | |
|---|---|---|
| The out-of-order engine | 22.4k / 23.0k / 23.5k | `Doc/UARCH.md` 4.4, 2026-11-01 later (with the D$ adapter; including the I$'s widening, 0.05k to 0.2k, which OOO_CPU does not have) |
| CORE_CSR (OOC_CSRU) | 2,496 | 26.20 |
| CORE_MDU | about 3.4k | mmRISC-2's chip (3,423) |
| The D$ | about 5.2k | OOC_LSUDC 7,573 less the LSU (2,153) and the adapter (about 0.2k) |
| **OOO_CPU** | **about 33.5k to 34.6k** | Yosys 47,525 LUT cells + 2,848 LUT RAM (about 33k to 36k) |

- The engine's own number is the total less the D$ (`u_dc`), CORE_CSR (`u_core/u_csr/u_csr`) and CORE_MDU
  (`u_core/u_mdup/...`): the instance rows of summary.txt.
- The paths between the blocks: the 20 worst between flip-flops by endpoint in summary.txt (timing_paths.rpt in
  full), against the blocks' own slack (worst +0.863 ns, OOC_FE's fetch-buffer loop).

### 27.2 The first run: size (2026-11-01, the RTL of 48d30d2, before B5a)

| | LUT | FF | |
|---|---|---|---|
| **OOO_CPU** | **35,961** (33,169 logic + 2,792 LUT RAM) | 17,830 | 26 DSP, 11.5 block-RAM tiles; Yosys 47,525 LUT cells + 2,848 LUT RAM |
| the D$ (`u_dc`) | 6,282 | 5,309 | 27.1's estimate about 5.2k |
| CORE_CSR (`u_core/u_csr/u_csr`) | 556 | 1,821 | alone 2,496: Phase 1 leaves its PMP, translation, debug and trigger outputs open, so Vivado removes what feeds only them (the chip budget keeps mmRISC-2's 4,750, `Doc/UARCH.md` 4.2) |
| CORE_MDU (`u_core/u_mdup/u_mdu`) | 2,945 | 920 | mmRISC-2's chip 3,423 |
| **the out-of-order engine** (`u_core` less CORE_CSR and CORE_MDU, with the adapter) | **26,178** | | the budget's 23.0k (middle) from the blocks; their own runs add up to about 21.5k |

- **The engine is 3.2k above the budget's middle, 4.7k above the sum of its blocks' own runs** (OOC_FE 6,622, issue
  queue 1,999, payload 585, renaming 2,702, ROB 1,235, control 351, DS register 69, register file 2,546, ALU0 1,928,
  ALU1 684, LSU 1,949, adapter 199, OOO_TRAP 217, OOO_SYS 23, OOO_PMUL 164, fusion 215). The difference is OOO_CORE's
  own logic, which no block run had: D2 (rotation, fusion's fields, the record), the DS payload, each port's RR / EX
  (the bypass muxes, the pc from the pc array, branch resolution with its adders and compares, port 0's result
  select and completion), the LSU's RR / EX. Vivado puts it into the child instances (port 0's EX stage holds 4,223
  LUTs, ALU0 included; the LSU 3,186 against 1,949 alone), so only the sums compare (25.3).
- Against the room (`Doc/UARCH.md` 4.4): over by 8.3k / 9.1k / 9.8k, the whole chip about 61k LUTs in the middle
  (the 52k ceiling + 9.1k: 96 % of the device's 63,400, where 80 % is what routes; corrected 2026-11-02). The timing must be closed first (below: a failing run may grow some logic); then the
  reserve levers (L10, B4 / B5 of `Doc/UARCH.md` 6.3) and the core's own logic are what is left to cut.

### 27.3 The first run: timing

WNS **−5.716 ns** (46 levels), 15,202 failing endpoints (TNS −22,896 ns). The 100 worst (one per endpoint) all
begin at port 1's write-back register (the bypass) and end in OOO_TRAP's tval (49), the ROB's exception bits (39), the
register file's write (10, through the LSU) and the D$ (2, `rob_done`):

| along the worst path | arrives |
|---|---|
| port 1's WB register → the bypass → ALU1's operand | 6.1 ns |
| the branch's compare (a carry chain) → `take_branch` | 10.5 ns |
| the next pc and the misprediction (`br_mispred`) | 13.4 ns |
| the ROB's oldest misprediction of the cycle (`restore_rob`) | 15.8 ns |
| OOO_TRAP's tval kept or dropped (`restore && rdist(r) > rdist(restore_rob)`, four reports in a row) | 26.2 ns |

- **The resolution acts in the cycle it is made**: EX's misprediction picks the restore in the ROB, and the restore
  (OOO_CTRL's `kill`, renaming's restore, the LSU's tails, the FTQ, the ROB's tail, OOO_TRAP's tval) is used by every
  block in that same cycle. The block runs had it as an input with 30 % of the period; here it comes at 15.8 ns, and
  what each block does with it (a priority over the tval reports, the LSU's kill of M into the D$'s request and the
  completion and register-file write) does not fit in the 4 ns left.
- **Proposed (A): the resolution through a register.** EX's `br_*` (valid, misprediction, checkpoint, next pc,
  ROB index, last parcel) into a register at the end of EX; the restore, the kill and the redirect a cycle later.
  It costs a cycle per misprediction: the model with the fetch restarting one cycle later still (`redirect=3`)
  +0.26 % / +0.21 % / +0.25 %. What it needs: the mispredicted branch must not commit, and nothing younger with it, in
  the cycle between (the ROB holds its completion back, or commit stops at a µop marked), and the younger µops of that
  cycle go on one more stage (they are killed there with their masks, as now: a stage's valid and its kill).
- (B) instead: register each slow consumer (OOO_TRAP's tval, the ROB's exception bits, the LSU's kill of M) and keep
  the restore. Smaller steps, but every consumer must then tolerate a late kill, and the next class behind would be
  the same signal into another block.
- The 100 worst all share one start, so what comes behind them is not seen: synth_ooo.tcl now reports, for OOO_CPU,
  the worst path into and out of each block's flip-flops.
- This run is before B5a (the fused compare adds the ALU's result in front of the comparison: it lengthens this
  path, so (A) is needed for fusion as well).

### 27.4 27.3's proposal A applied (Plan/CORE.md 5.20, 2026-11-01)

The resolution goes through a register: the restore, the kill and the redirect a cycle after EX; the clear of a
checkpoint stays in EX (a cycle later cost 2 % in checkpoints held), a mispredicted branch completes with its
restore. CoreMark +0.36 % / +0.43 % / +0.38 %. What is left on the path of 27.3 in the cycle of EX: the bypass, the
compare, the misprediction (13.4 ns) into the register, the clear (into the masks' flip-flops) and the done bit's
write enable. To rerun: `synth_ooo.bat OOO_CPU`.

### 27.5 The second run: with B5a and 5.20 (2026-11-01, the RTL of 089d31f)

| | first run (27.2, 27.3) | **second run** |
|---|---|---|
| OOO_CPU | 35,961 LUTs, 17,830 FF | **38,071 LUTs**, 18,044 FF |
| the engine (less CORE_CSR, CORE_MDU; with the adapter) | 26,178 | **28,152** |
| WNS / failing endpoints / TNS | −5.716 ns / 15,202 / −22,896 ns | **−6.442 ns** / **3,400** / −6,735 ns |

- **5.20 worked**: the restore's class is gone (no worst path ends in OOO_TRAP's tval or the ROB through the restore),
  and the failing endpoints fell to a fifth.
- **B5a does not fit in a cycle**: the new worst path (58 levels) is port 0's WB → the bypass → ALU0 (its result
  at 14.5 ns) → the fused compare (a carry chain, `take_branch` at 18.3 ns) → the misprediction (21.4 ns) → the
  clear from EX (`cl_*` → OOO_CTRL's `clr`, 23.9 ns) → the masks into the issue queue, MDUP and the RR stages (27.4
  ns). The fused compare alone ends past the period; an unfused branch compares at about 10.5 ns (27.3).
- **The classes behind it** (the new per-block report; the worst path into or out of each block):

| class | slack | from → to |
|---|---|---|
| D2: the group → fusion → renaming → the DS register | −4.05 ns (28 levels) | `u_front/g_v` → `u_dsreg` / `u_rename` (−3.94) / back to the front end's take (−3.73) |
| the completion's exception into the ROB's entries | −3.05 ns (25 levels) | the D$ (load completion from M, 5.14) / OOO_CSRU (−2.58) / the adapter (−2.07) → `u_rob/g_ent[*].exc` |
| a load's data into the register file | −2.29 ns (24 levels) | the D$'s forwarding way → `u_prf` (5.14) |
| OOO_TRAP | −1.30 ns (24 levels) | CORE_CSR's privilege → `u_trap` |
| the fetch buffer's loop | −0.946 ns (17 levels) | (+0.863 alone: placement in the larger design) |

- **Size**: +2.1k against the first run. Yosys with and without ALU + branch fusion: 49,932 / 49,106 LUT cells, so
  fusion is about 0.5k in Vivado; the rest is 5.20's (the ROB's eight completion ports: the ROB 2,576 → 3,195) and
  D2 (the front end's instance 7,345 → 8,662, which takes D2's rotation and fusion's fields).
- **Proposed next**: (1) turn ALU + branch fusion off (`KINDS` 0, the RTL kept): it gives −0.3 % to −0.6 % only
  while D1b refills when empty (5.19), costs 0.5k LUTs, and its compare does not fit; it comes back with the fused
  compare in the cycle after EX or with D2's refill. (2) Then the classes above, in order: D2's path, the
  completion's exception into the ROB (register it, as the misprediction), the load's data into the register file
  (5.14's completion from M: the data could stay a cycle later than the completion), OOO_TRAP's privilege input.

### 27.6 27.5's step 1: ALU + branch fusion off (Plan/CORE.md 5.21, 2026-11-01)

OOO_FUSE's `KINDS` 0 in the core; CoreMark +0.22 % / +0.60 % / +0.52 % against 5.14. To rerun: `synth_ooo.bat
OOO_CPU`; expected: the fused compare's class gone (an unfused branch's misprediction at about 13.4 ns, 27.3), about
0.5k LUTs less, and the classes of 27.5 (D2, the completion's exception into the ROB, the load's data into the
register file, OOO_TRAP, the fetch buffer) as the worst.

### 27.7 The third run: fusion off (2026-11-02, the RTL of 7d4a8fa)

| | second run (27.5) | **third run** |
|---|---|---|
| OOO_CPU | 38,071 LUTs | **37,421 LUTs** (−650) |
| the engine | 28,152 | **27,485** |
| WNS / failing endpoints / TNS | −6.442 ns / 3,400 / −6,735 ns | **−7.362 ns** / 2,596 / −3,707 ns |

- **The fused compare is still there.** The worst path (63 levels) is port 1's WB → the bypass → ALU0's adder
  (9.5 ns) → its result → the compare's carry chain (`take_branch` 19.4 ns) → the misprediction (21.9 ns) → the
  done bit's gate and `cl_*` → OOO_CTRL's `clr` (24.4 ns) → the issue queue's `iss_bm` → the RR stages' valid, MDUP
  (28.3 ns). `KINDS` 0 makes the pairs' fields constants at D2, but the record goes through OOO_IQPL's LUT RAM, which
  Vivado cannot see as constant: `rec.fused` stays a variable in EX, and with it the compare after the ALU.
- **D2's class is gone** (renaming −0.85 ns, the DS register +1.01 ns: fusion's fields were most of it).
- **The clear runs into the select's output**: OOO_IQ gives `iss_bm` as the entry's mask and `~clr` (line 214), but
  every user registers it with `& ~clr` again (OOO_STAGE, MDUP), and the kill compare does not need it (a checkpoint
  cleared is never the one restored, OOO_CTRL's `clr & ~killset`).
- **Proposed**: (1) gate the fused path in EX with the fusion parameter (a constant `rec.fused` when `KINDS` is 0:
  the compare reads s1 / s2 alone, about 10.5 ns, 27.3); (2) `iss_bm` without `~clr`. Then the next classes, from the
  per-block report:

| class | slack | from → to |
|---|---|---|
| the CSR unit's result into the register file | −2.68 ns (24 levels) | `u_csr` → `u_prf/lvt` (port 0's write) |
| a load's data into the register file | −2.40 ns (21 levels) | `u_dc` → `u_prf/lvt` (5.14's completion in M) |
| the privilege level into OOO_TRAP, the D$, the LSU | −2.10 / −1.60 / −0.96 ns | CORE_CSR's `priv_r` → `u_trap`, `u_dc`, `u_lsu` |
| the fetch buffer's loop | −0.141 ns (17 levels) | |

### 27.8 27.7's two fixes (Plan/CORE.md 5.22, 2026-11-02)

The fused path gated by the core's fusion parameter (`FUSE_AB`), and OOO_IQ's `iss_bm` without the cycle's clear.
Yosys: OOO_CPU 49,106 → 46,768 LUT cells (the fused compare, its selects and the pair's adders were still in EX).
To rerun: `synth_ooo.bat OOO_CPU`; expected: an unfused branch's misprediction at about 13.4 ns, the clear into the
masks' flip-flops after it, and the classes of 27.7's table (the CSR result and a load's data into the register
file, the privilege level, the fetch buffer) as the worst.

### 27.9 The fourth run: 50 MHz met (2026-11-02, the RTL of 289cc2a)

| | third run (27.7) | **fourth run** |
|---|---|---|
| OOO_CPU | 37,421 LUTs | **36,445 LUTs** (33,629 logic + 2,816 LUT RAM), 18,013 FF |
| the engine (less CORE_CSR 667, CORE_MDU 2,692; with the adapter 194) | 27,485 | **27,042** |
| WNS / failing endpoints | −7.362 ns / 2,596 | **+0.159 ns / 0** (25 levels) |

- **The whole core closes at 50 MHz out of context**, the first time (G1's timing criterion; mmRISC-2's core closed
  with +0.002 ns in the same conditions, 25.3). The 20 worst all end in the ROB's exception and cause bits (their
  write enables) and begin at CORE_CSR's privilege level (`priv_r`): the privilege into the checks of a completing
  µop (the CSR unit's legality, ECALL's cause), the completion's exception into an entry.
- **What is close** (the per-block report): the ROB's exception from the privilege +0.159 ns; port 0's EX into the
  masks through the clear (OOO_CTRL's `ck_bm` +0.79 to +0.98 ns, 34 levels: EX's compare → `cl_*` → `clr`); the
  issue queue +1.13 ns; the fetch buffer's loop +1.42 ns. Nothing else below +1.5 ns.
- **Size**: −976 against the third run (the fused path gated, 5.22); the ROB 3,717 (eight completion ports, +619 on
  the first run; the mispredicted branches' two could share EX's ports, as their EX completion is held then).
- Against the room: over by 9.1k / 9.9k / 10.6k (the whole chip about 62k in the middle: the 52k ceiling + 9.9k, 98 % of the device's 63,400).
  With the timing closed, size is what stands between the core and G1.

## 28. The move to the XC7A200T (2026-11-02)

`synth_ooo.tcl` now targets **xc7a200tsbg484-1** (`Doc/STRATEGY.md`). Every result above and in `output/` from before
this date is on xc7a100tcsg324-1: same speed grade, smaller device. The first task on the new part, at the new target of 100 MHz, is `synth_ooo.bat
t100` (results in `output/<top>_T10`), step 1.0: today's blocks at 10 ns. `OOC_ALU2` has a `FUSED` parameter for it, and the input
delays fixed in ns (the wakeup tags, `g_take`) now scale with the period. The budget is now `Doc/UARCH.md` 4.5; `Doc/UARCH.md`
4.4's overrun is history.

### 28.1 Step 1.0: today's blocks at a 10 ns target (2026-11-02)

`synth_ooo.bat t100`, on xc7a200tsbg484-1. "At 20 ns" is the earlier result on the XC7A100T: an upper bound, since Vivado stops
working once a path meets its target. `FUSED=0`: the fused compare out, as in the proposal.

| Block | LUTs at 10 ns (at 20 ns) | Register to register | Levels | Path (at 20 ns), route | Worst path |
|---|---|---|---|---|---|
| `OOC_ALU2`, `FUSED=0` (full ALU) | 1,791 (1,928 with fused) | **−0.660** | 23 (14 CARRY4) | 10.6 ns (18.5), 6.6 | `as1` → `r1[37]` |
| `OOC_ALU2`, `FULL=0 FUSED=0` (ALU1) | 495 (684 with fused) | +2.335 | 20 | 7.7 ns | |
| `OOC_DEC` | 1,841 (1,807) | +0.361 | 8 | 9.0 ns (12.1) | |
| `OOC_RENAME` (2 µops) | 2,657 (2,702) | +1.044 | 7 | 8.6 ns (11.7) | |
| `OOC_ROB` (2 wide) | 1,236 (1,235) | +1.026 | 17 | 9.0 ns | |
| `OOC_LSU` | 1,983 (1,949) | −1.014 | 14 | 11.0 ns | |
| `OOO_IQ` (10 entries, 3 ports) | 2,115 (1,999) | **−1.946** | 11 | 11.8 ns (12.8), 9.8 | `uq` → `rq` |
| `OOO_UBTB` (8 entries) | 567 (492) | **−2.037** | 12 | 11.9 ns (12.9), 9.5 | `pc_q` → `pc_q` |
| `OOC_LSUDC` | 7,989 (7,573) | **−2.657** | 17 | 12.6 ns (18.7) | `u_dc/s1_addr` → `u_lsu/wb_data` |
| `OOC_FBUF` | 1,115 (1,001) | **−3.306** | 15 | 13.3 ns (16.9), 10.7 | `hb` → `hoff` |
| `OOC_FE` | 7,290 (6,622) | **−4.789** | 21 | 14.3 ns (19.1) | `hpc` → RAS memory |

**What it says**

- **The 20 ns results were far from the limit**: the full ALU moved most, 18.5 to 10.6 ns. Nothing here refutes 100 MHz.
- **Nothing here proves it either.** These are today's blocks, 2-wide, in the stages of a 50 MHz design. A block that misses
  and is to be cut in two (`OOC_LSUDC`, `OOC_FBUF`, `OOC_FE`) says little; one that passes at 2 µops (`OOC_RENAME`, `OOC_ROB`)
  says little about 4. Alone is not in the chip: the core at 20 ns added about 1 ns to its worst block.
- **Routes stay the larger part**: 62 % of the ALU's path, 80 to 83 % of the fetch buffer's, the queue's and the uBTB's.
- **Loop 1 moved least** (12.8 to 11.8 ns), and it is worth 20 %. The queue of 8 with one select has less fan-out on the
  select but must take more wakeups than today's (3 ALUs + load). Measured first.
- **Loop 2 is near**: 0.66 ns short with all functions, 2.34 ns over with ALU1's. The proposal, with the rare operations at 2
  cycles, lies between, but its bypass has more sources: this harness has today's.
- **The uBTB is a sixth loop**: 2.04 ns short at 8 entries, and the proposal wants 16. A new option in the model,
  `taken_gap=2`, puts a bubble on each taken branch: **6.435, −6.8 %** (`Plan/model/results/g100.txt`). 8 entries without a
  bubble is 6.660 (−3.5 %), 4 entries 6.400 (−7.3 %). The path has 9 LUT6: the compare of all entries, the choice of the
  target and the priority of redirects, all back into `pc_q`. To try: redirects in a last mux with their own registers,
  fewer candidates per lookup (set-associative), the sequential add apart.
- **The tighter target costs area where it misses**: uBTB +15 %, `OOC_FBUF` +11 %, `OOC_FE` +10 %, `OOO_IQ` +6 %, `OOC_LSUDC` +5 %; those
  that pass stay within 2 %. The engine's estimate of 59k (52k to 66k) has to absorb that, on a 75 % ceiling.

The next step is 1.1 (`Doc/STRATEGY.md` section 5), the queue of 8 first. The gate S1-A stays open.

### 28.2 The queue of 8: `OOO_SCHED`, `OOC_SCHED` (2026-11-02)

The first harness of step 1.1, for loop 1, and the first RTL of the new core: `RTL/CPU/OOO/OOO_SCHED`, 3 ALU queues of 8 and a
memory queue of 12, measured together, since a wakeup crosses queues. Run with `synth_ooo.bat sched` (`output/OOC_SCHED_T10_MATRIX1`,
`_MATRIX0`). Not measured when written: everything about its timing and size below is an expectation; the first run is in 28.3.

**Today's path (28.1) is 11 levels**: port 1's select, port 0's select chained after it, the AND-OR of the destination tags (fan-out
41 on a tag bit), the compare against every source, the ready bit. What changes:

| | `OOO_IQ` | `OOO_SCHED`, `MATRIX=1` |
|---|---|---|
| Selects in the loop | 2, chained | 1 |
| A wakeup | an encoded tag, compared against every source | one column of wait bits, cleared |
| Tags in the loop | yes | **none**: compared once, at dispatch, against what is pending |
| Fields read at the grant | sources, destination, mask | none: `rr_*` a cycle later, from the grants in a register |
| The age matrix on a write | reads `v` and the grants | none: a new entry is younger than all |
| Waits of loads and non-speculative µops | registers of their own | the same wait cells |
| Expected levels | 11 | 6 to 8: select 2 or 3, clear 1, cell 1, the row's AND 2 |

`MATRIX=0` keeps the same queues and the same cycles with tag compares (one bus per queue + 2 external, a table of busy bits), to
measure what the matrix buys rather than assume it. Its LUTs are not a fair comparison: it keeps wait cells for the order waits, 400
of them, where the registers of `OOO_IQ` would do.

What the matrix costs, a column per entry in every row: 1,296 flip-flops and LUT6s (a cell has its own clear and write-enable pair, too many
control sets to use the flip-flops' CE and R), and the tags compared at dispatch: 8 sources × 36 entries. In exchange
renaming needs no busy bits and the DS register no snoop. My estimate is 3.5k to 4.5k LUTs without the payload, against a budget of 6.5k with it
(`Doc/UARCH.md` 4.5).

**CoreMark/MHz** (model, `Plan/model/results/g100.txt`, `-O2` / most optimization / g13); three things had to be built that the
proposal's 6.901 did not include:

| Option | Why it is needed | `-O2` |
|---|---|---|
| `hold=1` | A latency L µop keeps its entry until its column clears: a column has one meaning at a time | 6.908: nothing |
| `qw=2 qwl=2` | 2 writes a queue; the LUT6 of a cell has room for exactly that | 6.895; with 1 write 6.816 |
| `steer=1` (round robin, rejected) | Without counts | 6.851 |
| `steer=2` | The queues as full as they were in the last cycle, emptiest first; the group's µops in turn | |
| **All, as built** | | **6.870 / 7.378 / 6.644, −0.4 %** |

So it keeps the performance. Queues of 10 would give only +0.3 % (6.892): 8 stays.

**Verification**: `SIM/OOO_UNIT/tb_sched.cpp` holds both modes (tests `sched`, `schedt`) against an account of when each value is usable,
400,000 cycles: which µop each queue issues, where each slot goes, masks, kills, flushes, write slots. About 300,000 back-to-back issues, 3/4 across queues. Both
modes give identical cycles. Bug injection M382 to M443: 60, all detected, after two rounds: the first found a branch of the age matrix that cannot happen (port 0 always has the lower entry; removed) and fields the bench never varied (a non-writer's destination, an external µop's latency). Not connected to the core: the core is still `OOO_IQ`.

A mutation that did not compile used to count as detected in `mutate.py` (M428 here). So the whole list was run again with that closed, on 2026-11-03: **406 mutations, 406 detected, no failed build, none not applied**; the older 346 were all real. `SIM/CORE/mutate_core.py` already has `BUILD FAILED` as a result of its own, and needed no rerun.

Things to look at in the results: `summary.txt` has the worst path per class (`loop`, `wake`, `disp`, `free`, `issue`), full paths in
`timing_loop.rpt`. `disp` may be the worst: steering, first free entry, a same-group producer and the write all fall in one stage.
If so it is not the loop that fails, and it can take a stage: one more before the queues gives 6.842, −0.4 % (`dec_depth=6 redirect=7`).

### 28.3 `OOC_SCHED`, the first run (2026-11-03)

`synth_ooo.bat sched`. Place and route finished for both; the class report then stopped on an error in my script (a list of more than
500 cells, and names that did not match), so **the loop's own slack is not known yet**. `report_sched.tcl` is corrected and reads a finished run:
`synth_ooo.bat schedrpt`.

| Run | LUTs | FFs | Register to register | Levels | Worst path |
|---|---|---|---|---|---|
| `MATRIX=1` | **7,969** | 2,596 | **−10.336** | 24 | 20.3 ns, route 83 %: `oc` → `rv` |
| `MATRIX=0` | 9,186 | | −8.057 | 18 | 18.0 ns, route 85 %: `oc` → `rv` |

- **All ten worst paths of the matrix begin at `oc`: dispatch, as feared in 28.2, not the wakeup-select loop.** The path: the occupied
  bits, a queue's free count, a slot's go, the next slot's room and so on through the 4 slots (`stop`, `used`), the slot's entry, a younger
  slot's same-group dependence, the port's mux, the wait cell, the row's AND, `rv`. One stage cannot hold that.
- **My estimate of 3.5k to 4.5k was wrong by a factor of 2**, and the budget of 6.5k with the payload is exceeded. The tags compared at dispatch
  and the muxes of slots onto ports, per column, are what I most underrated; the report per block will not separate them, since it is one module.
- Both point at the same place, so dispatch has to be redesigned whatever the loop gives: steering and the entries in a stage of their own, without
  the sequential decision per slot; the producer's entry from a table by tag rather than a compare against 36 entries. One more stage costs −0.4 % in the model.

**The classes** (`synth_ooo.bat schedrpt`, `summary_loop.txt`, full paths in `timing_loop.rpt`; slack in ns, levels):

| Class | `MATRIX=1` | `MATRIX=0` |
|---|---|---|
| `loop`: request, grant, request | **−2.429, 7** | **−4.900, 18** |
| `wake`: request into the wait cell / ready bit | −0.927, 4 | −4.280, 15 |
| `free`: occupied bits into the block | −10.336, 24 | −8.057, 18 |
| `steer`: the queue order into the block | −8.752, 22 | −7.270, 17 |
| `disp`: the slots' registers into the block | −8.612, 22 | −7.250, 17 |
| `kill`: `kill`, `clr` into the block | −1.126, 6 | −1.176, 8 |
| `issue`: the grants in a register, out | +2.321, 4 | +3.308, 4 |

**The matrix did what it was built for, in levels: 7, against 11 in `OOO_IQ` and 18 for tags at this size.** The logic of its loop is 1.39 ns of the
12.37 ns path; the route is 10.99, and one net is 5.25 ns of that: a column's clear, fan-out 38, from slice X36 to X18. Vivado stops improving other paths when the
worst one cannot be met, and here that one is 8 ns worse, so **−2.43 is not the loop's limit, only what it was left with**. A loop with 7 levels should fit in 10 ns; that is not measured until dispatch
no longer dominates. The tag version's loop runs through its dispatch snoop (`dr`) as well; its 18 levels are not all the loop's own, but its logic alone is 2.69 ns.

Decision: **keep the matrix**, and redesign dispatch, as `OOO_SCHED`'s next step, in its own module, so that the report per block shows what it costs.

### 28.4 Dispatch redesigned: `OOO_SDISP` (2026-11-03)

`OOO_SCHED` with dispatch in a module of its own, `OOO_SDISP`, so that the report per block separates them. The tag version is gone from the RTL (its
results stay in `output/OOC_SCHED_T10_MATRIX0`). Run: `synth_ooo.bat sched`, in `output/OOC_SCHED_T10`. Not measured yet.

| What was in one stage | Now |
|---|---|
| Occupied bits → free entries → go | `ff`, `bf`: the first free entry of each bank, **in registers**, chosen the cycle before |
| Slots' decisions in sequence, through go | The slot's bank does not depend on whether older slots go (they all do if it does) |
| Entry's fields, 4 slots onto each | **A queue is 2 banks** (even and odd entries), one write each: one source per field, no mux at the entry |
| Tag compare, group dependence, port mux, wait cell, row, `rv` | **S1**: compare, into a register per slot. **S2**: port mux, wait cell, row, `rv` |

S1 runs alongside renaming's R2 and S2 is the existing stage DS, so **no stage is added** if rename of 4 can share its go with it: to be checked with loop 4's harness. If not, a stage more gives 6.801.

**CoreMark/MHz** (`Plan/model/g100.sh`, `-O2` / most optimization / g13):

| Step | Result |
|---|---|
| The last version (28.2) | 6.870 / 7.378 / 6.644 |
| Banks in place of 2 writes a queue | 6.866 / 7.386 / 6.645: nothing |
| **As built**: a freed entry a cycle later, the queues' order 2 cycles old | **6.829 / 7.320 / 6.604, −1.0 % against the proposal's 6.901** |
| A freed entry 2 cycles later (no grant into `ff`) | 6.789: why the grant stays in that path |
| Queues of 10, as built | 6.862: +0.5 %, for 1.36 times the wait cells: no |

At the usual 0.94 of the model the RTL would give about 6.42, above gate S1-B's 6.3.

**What I proposed and did not do: the producer's entry from a table by tag.** Worked out, it does not pay: a table of 80 × 6 bits with 4 writes and 8 reads, plus a way to tell a live entry from
a stale one (busy bits, with tags on a bus again), comes to about what the compare costs (288 compares), and it would bind the free list to banks. So the compare stays.

**Size**: my estimate is about 5k LUTs, against 7,969. The last estimate was off by 2, so this one is to be read as a direction only; (`u_disp` in `utilization.rpt` turned out not to be dispatch alone: 28.5.)

**Verification**: `tb_sched` has steering, banks and free entries in full, against the account. 3 seeds, no mismatch. Bug injection M382 to M477 replaces the last list: 93, all detected, after a first round that found 3 redundant conditions in the bank choice and the flush of the write slots (removed; a slot kept free for nothing after a flush costs a cycle at most) and a flush the bench never drove with slots valid (added).

### 28.5 `OOC_SCHED` meets 10 ns (2026-11-03)

`synth_ooo.bat sched`, in `output/OOC_SCHED_T10`: **the block meets 10 ns, register to register +0.056 ns, in 5,353 LUTs.** Only the block: no payload, no core around it.

| | First run (28.3) | Now |
|---|---|---|
| Physical LUTs | 7,969 | **5,353** (−33 %; my estimate was about 5k) |
| FFs (the harness's 318 included) | 2,910 after synthesis | 3,139 |
| Register to register | −10.336 ns, 24 levels | **+0.056 ns, 9 levels** |
| `loop`: request → grant → request | −2.429, 7 levels | +0.208, 9 levels |
| `wake`: request → wait cell | −0.927, 4 levels | +2.036, 5 levels |
| `free`: then occupied bits → the block, now a request → the first free entries | −10.336, 24 levels | +1.909, 9 levels |
| `s1`: the slots' registers → the block | −8.612, 22 levels | +0.233, 9 levels |
| `ff`: free entries, queue order → the block | −8.752, 22 levels (`steer`) | +0.329, 9 levels |
| `s2`: S2's registers → the block | (not separate) | +1.032, 7 levels |
| `kill`: kill, clr → the block | −1.126, 6 levels | +2.747, 4 levels |
| `issue`: the grants' registers → out | +2.321, 4 levels | +4.504, 4 levels |

#### What it says
- **Dispatch was the problem, as 28.3 guessed, and the loop was not at its limit there.** No more tag-compare version to compare with: the matrix stays.
- **The margin is not known.** Vivado's estimate after placement was +0.511, so it skipped physical optimization, and stopped working on the routes once they met: 84 % of the worst path is route (1.57 ns of logic, 8.32 ns of route), with a grant's net of fan-out 78 alone at 1.52 ns. So +0.056 is where it stopped, not where it could get. `synth_ooo.bat sched85` asks for 8.5 ns to find out, and 10 ns inside the whole core needs that margin.
- **The worst path was in none of the classes I had defined.** It starts at a non-speculative flag: `nsf` → request → grant → column → row → `rv`. It is the loop with a longer start; `report_sched.tcl` now has the class `guard`.
- **The report does not separate dispatch.** `u_disp` shows 4,825 LUTs and the rest of `u_sched` 531, but the wait cells alone need 1,296 and they are in `OOO_SCHED`: LUTs of `g_ent[14].rv[14]_i_22` and the like are named under `u_disp`, because synthesis rebuilds the hierarchy after flattening. So what 28.4 promised does not hold: only the sum is meaningful. Separating them needs a run with the hierarchy kept, which would not be the same netlist; nothing depends on it now, so I have not asked for one.

#### What is still open
- **The payload** (tags, ROB index, op fields, read by `rr_entry`) is not in the block: 1.1k LUTs remain of the budget of 6.5k. With one writer per bank it can be LUT RAM. Not designed yet, so that is an expectation.
- **Sharing go with rename of 4**: here the slots come from registers, and `s1` at +0.233 already passes through go into `rv`. Whatever rename adds before go comes out of it. Loop 4's harness decides; a stage more costs 6.801 against 6.829.
- **Loop 1 in the core**: 10 ns alone is not 10 ns in the chip (routes are 62 to 83 % of the paths, 28.1), hence the margin run and step 1.6.

Loop 1 is within reach for gate S1-A; the other five are not measured as designed. Next is loop 2, bypass + ALU with the new sources.

**The margin** (`synth_ooo.bat sched85`, `output/OOC_SCHED_T8.5`, the same RTL at 8.5 ns): WNS **−0.776 ns, so about 9.3 ns**, 5,397 LUTs. `loop` −0.776 (8 levels; 1.45 ns of logic, 7.78 ns of route), `ff` −0.742, `guard` −0.702, `s1` −0.633, `free` −0.223, `s2` +0.057, `wake` +0.818, `kill` +1.112, `issue` +2.347. So the block has about **0.7 ns in hand**, for a core that added about 1 ns to its worst block at 20 ns (28.1). Not comfortable, and to be read again in step 1.6. The paths are close together: nothing single stands out to fix.

### 28.6 Loop 2: `OOO_EXU`, `OOO_ALUF`, `OOO_PRF2`, `OOC_EXU` (2026-11-03)

The block of bypass + ALU as the proposal has it, not today's with more sources. Not measured when written: `synth_ooo.bat exu`, in `output/OOC_EXU_T10`.

#### What stays in the cycle: measured, by operation
The trace now keeps a class per operation (`Plan/model`: `opx`, `slow2`, `q0_slow`, `q0_jalr`; `results/g100.txt`). What CoreMark executes is narrow: of the operations beyond add, logic and compares only `sh1add.uw`, `sh2add.uw`, `zext.h`, `sext.h`, `sraiw`, `srliw`, `c.srli`, `srli`, `bexti`, `czero.eqz`. No left shift to speak of in the Zb builds, no shift by a register, no min / max at all.

| Taken to 2 cycles, on top of the row before | `-O2` | most optimization | g13 | rv64gc (g13, Debian's default) |
|---|---|---|---|---|
| As built so far (28.4) | 6.829 | 7.320 | 6.604 | 5.902 |
| **Counts, `rev8`, `orc.b`, rotates, min / max, `bset` / `bclr` / `binv`, `bext`, shifts by a register, all on queue 0; `jalr` on queue 0** | **6.823** | **7.315** | **6.599** | 5.898 |
| ... and `slli` | 6.824 | 7.316 | 6.599 | 5.561 on queue 0 |
| ... or `srli`, `srai` | 6.725 | 7.206 | 6.514 | 5.631 (alone) |
| ... or `bexti` | 6.629 | 7.109 | 6.599 | |
| ... or `czero` | 6.625 | 7.103 | 6.599 | |
| ... or Zba | 6.647 | 7.085 | 6.427 | |
| ... or `zext.h`, `sext` | 6.591 | 7.032 | 6.369 | |

So the bold row is what `OOO_ALUF` leaves out, for −0.1 %, all of it from `jalr`. **`slli` is the one free lever left in CoreMark** (nothing with Zb), but costs 5.7 % on rv64gc, so it stays in EX while it fits. These are CoreMark's numbers: what leaves the cycle still runs, in 2 cycles, and other programs will see it.

The "rare operations" of `Doc/STRATEGY.md` 4.2 was an assumption; this replaces it.

#### The design
| Item | Choice | Why |
|---|---|---|
| Shifts in EX | By an immediate only; left by the same funnel (`hi = a`, `amt = 64 - n`) | No path from a bypassed register into the amount with its fan-out of 64, and no reversal before and after |
| Selections | Decoded in RR2, in registers, `max_fanout` 16 | Today's 6-bit `alu_op` is decoded in EX |
| pc, immediate, zero | In the operand register from RR2 | `a1_sel` and `b1_imm` leave EX's path; today's worst path started at `a1_sel` |
| EX's mux | Own register, 3 ALUs, load: 5 sources, selection in a register | As `Doc/STRATEGY.md` 4.3 |
| A result | 3 registers: for EX's muxes, for RR2's, for the register file | 16 mux sinks and more than 16 RAM cells per bit |
| A branch | On the adder, plus a comparator; flags in a register, the decision in EX + 1 | One adder less, no `br_op` in EX |
| `jalr` | Queue 0; target from the adder's sum, link ORed into the result | No target adder or link on ports 1, 2 |
| What is not in `OOO_ALUF` | `OOO_ALU` itself, from registers, in the cycle after EX | Verified, nothing new; its size may be trimmed later |
| Register file | `OOO_PRF2`: LVT in RR1 with a compare against writes, banks in RR2 | The LVT and banks in one stage measured 17 to 18 ns |

How a source gets its value, with T the cycle its result is in a register: a consumer in RR2 at T − 1 is given it by EX's mux, at T by RR2's mux, later from the register file. So RR2 has 6 sources, EX 5, and tags are compared only in RR2.

**`OOC_EXU` includes the register file**: 80 × 64, 4 writes, 8 reads, so RR2 and the result's fan-out are real. It will be the largest part, I expect. The harness leaves out the SQ, the multiplier and the MDU behind `p0_a`, `p0_b`, and M2's real delay before `ld_d`. Branch masks are not in the block: those stay with valid bits in `OOO_STAGE` when it joins the core.

#### Verification
- `tb_exu`: 4 ports, 1.5 million cycles, each source through EX's mux (2.9 million), RR2's (1.4 million), or the modelled register file (1.8 million, stale if read too early). Values from `ref_alu`, the specification. Loads and results from outside at any time, write slots as the scheduler keeps them, flushes. **It found a bug in the first version**: a µop flushed in RR2 left its result to be ORed onto what port 0 shared its write with.
- `tb_prf2`: 80 × 64, reads of a register being written (849,326 of 2.4 million).
- Bug injection M478 to M556: 78 mutations, all detected. One more was removed, as equivalent: reading the LVT in RR2 instead gives the same values, since the register is there for timing only. `verilator -Wall` is clean on the new modules and the harness's lines.

#### What to read from the run
`summary.txt` has the classes (`report_exu.tcl`): `loop` (a result, through EX's mux and the ALU, to a result); `sel`, `ctl`, `oper` (the rest of EX); `flag`, `rare`; `rf`, `lvt`, `tags`, `snoop`, `write` (RR1, RR2, the write).

If `loop` is short, the levers in order: `slli` out of EX (nothing in CoreMark), Zba's change of `a` by the fan-out, the fan-outs, the size of `max_fanout`.

### 28.7 `OOC_EXU`, the first run: −0.356 ns; the last levels rebuilt (2026-11-03)

`synth_ooo.bat exu`, `output/OOC_EXU_T10`, the design of 28.6 at 10 ns: **WNS −0.356 ns, so about 10.4 ns, 15,731 LUTs** (10,227 logic + 5,504 LUT RAM), 5,086 FF of which 2,395 are the harness's. `OOO_EXU` 7,703 LUTs, `OOO_PRF2` 8,027 (2,523 logic + 5,504 LUT RAM). Against `Doc/UARCH.md`'s rows, register file 4.6k and ALU ports 10k, 14.6k together: the sum is 1.1k over, all of it the register file.

| Class | Worst at 10 ns | Levels | The path |
|---|---|---|---|
| `loop` | **−0.356** | 14 | Port 1 → port 0: bit 9, 6 carry cells, `sum[31]`, then 4 LUTs of `addw`'s sign into bit 61 |
| `rare` | −0.338 | 9 | `rop` (fan-out 92) through `OOO_ALU`, 1.57 ns of logic, 8.65 ns of routes |
| `sel` | −0.188 | 13 | The same way from a selection |
| `oper` | −0.037 | 10 | `ob` → czero's zero test → the same last LUTs |
| `write` | +0.035 | 0 | Tag → RAM write address: fan-out 654, 9.4 ns of route alone |
| `tags` | +0.438 | 5 | `rt`, fan-out 515, compare, select of RR2's mux (fan-out 65, 4.1 ns) |
| `lvt` | +1.057 | 6 | |
| `ctl` | +1.288 | 7 | The funnel from its controls |
| `rf` | +1.374 | 4 | |
| `flag` | +1.518 | 15 | |
| `snoop` | +2.772 | 2 | |

The 10 worst paths all end in port 0's result. **The worst is not the adder but what follows it**: of 10.2 ns, 4.3 ns come after `sum[31]`: 2 LUTs of the AND-OR, `res[31]` with a fan-out of 33, the word's mux on each upper bit, and the OR with port 0's other results. A 64-bit add was not the limit: the full carry chain reaches `fl_lt` with +2.05 ns. Routes are 70 % of the path.

**What changed, with no change in the model** (all timing estimates below are from the report, not measured):

| Change | Why |
|---|---|
| `OOO_ALUF`'s last level is one LUT per bit: `g_add & sum`, `g_sh & sh`, `o`, and `sgn` in the upper half | From the sum to the register 1 LUT, or 2 for a word's sign (was 4, with the fan-out in the middle). Upper-half controls `g_addh`, `g_shh`, and `g_addw`, `g_shw` for the sign, decoded in RR2 |
| Everything else goes in by `o`, and port 0's other results by `extra` into `o` | Port 0's extra LUT after the ALU is gone; czero, logic, `rare` and `x_d` are 2 levels before the register |
| `slt` a term of the last level at bit 0 | The carry out comes late |
| Tag and valid kept twice: `rt`, `rv` for comparisons, `rt_w`, `rv_w` (`max_fanout` 128) for the write | The write's fan-out was 515 on the comparisons' tag; `write` had no margin at all |
| A bank of `OOO_PRF2` is 64 + 16, not one memory | 80 in one memory takes 2 cells of 64 per bit; 16 fit a cell of 32. **5,504 → about 4,160 LUT RAM** (expected), also fewer sinks for the write. Reads and writes as before |

`rare` is unchanged in itself: its last levels are a little shorter, the −0.338 is partly because the placer had a worse path in front, as 28.5 saw. If the next run shows it is real, the cheap answer is a longer latency on queue 0, where the scheduler already has 4 for the multiplier: it costs nothing in CoreMark (those operations do not run there) but others would see it. Not done.

**`synth_ooo.bat exu9`** runs this at 9 ns, in `output/OOC_EXU_T9`: 10 ns would stop improving once met (28.5), and this block needs margin too, the core adding about 1 ns (28.1). Target: about 9.3 ns, as the scheduler.

Tests: `tb_exu`, `tb_prf2`, `tb_alu2` PASS with the same counts, as the behaviour is the same. `-Wall` clean on these modules and the harness's lines. Bug injection: M478 to M571, 92 mutations, all detected. One was removed as equivalent now: M524, `rv` not cleared by a flush. `rv` used to drive the write too; now it only gates comparisons, and a flushed tag is no live source, so a stale `rv` for the one cycle matches nothing. The write's own clear is M570, detected. The clear stays in the RTL.

Levers if `loop` is still short, in order, as 28.6: `slli` out of EX, Zba's change of `a`, then fan-outs.

### 28.8 `OOC_EXU` at 9 ns: about 10.7 ns; the shifter, the slow operations, the write (2026-11-03)

`synth_ooo.bat exu9`, `output/OOC_EXU_T9`, the RTL of 28.7 at 9 ns: **WNS −1.674 ns, so about 10.7 ns; 13,207 LUTs** (9,047 logic + 4,160 LUT RAM), 2,524 fewer than at 28.7's start. `OOO_PRF2` 5,661 (was 8,027): the LUT RAM came out at exactly the 4,160 expected, and its logic fell from 2,523 to 1,501. Together with `OOO_EXU`'s 7,545 this is 1.4k under `Doc/UARCH.md`'s 14.6k.

| Class | Worst at 9 ns | So about | Levels | The path |
|---|---|---|---|---|
| `rare` | **−1.674** | 10.7 ns | 27 | `rop` → the comparison of min / max (17 carry cells) → select, fan-out 64 → 4 LUTs |
| `sel` | −1.285 | 10.3 ns | 8 | A selection → `a` → **the sign of `sraiw`** through the funnel → `sgn`, fan-out 96 (the set pins) |
| `oper` | −1.122 | 10.1 ns | 8 | `a` → the LUT in front of the funnel → 3 stages → last LUT |
| `loop` | −1.120 | 10.1 ns | 8 | As `sel`, from a result |
| `write` | −0.896 | 9.9 ns | 0 | Tag → RAM write address, fan-out 295, **9.2 ns of route, no logic**; `max_fanout` 128 did not reach it |
| `tags` | −0.207 | 9.2 ns | 5 | |
| `ctl` | +0.117 | 8.9 ns | 6 | |
| `flag` | +0.324 | 8.7 ns | 21 | The whole carry chain |
| `lvt`, `rf`, `snoop` | +0.932, +1.588, +3.036 | | | |

What it says: **`rare` was real** (28.7 left that open), and is 0.4 ns ahead of the rest, so the rest may also be held back. **The worst of EX is no longer the adder**: 64 bits of add reach the flags at 8.7 ns, the shifter is what is long. `slt` through the carry out is −1.033: 3 LUTs after the carry.

**What changed.**

| Change | Why | Cost |
|---|---|---|
| **The shifter is a rotation and a mask** (`OOO_ALUF`): 3 stages of 4 to 1 on `a` with nothing in front, and `m`, 64 bits decoded from the immediate in RR2, on the last LUT. The fill goes in by `o` where `m` is 0, with no path through the rotation. Left by n is a rotation by 64 − n. `bexti` is a mask of 1 | 1 LUT level fewer from `a`, the fill's fan-out of 63 is gone, `sraiw` needs no `sgn`. `sgn` only keeps `addw` and `slliw` | None in the model; 64 FF per ALU for about 230 LUTs fewer per ALU (estimated) |
| **`slt` is one LUT from the carry out**, on the last level of bit 0 | Was 3 | None |
| **`OOO_ALUR`, new, replaces `OOO_ALU` for the slow operations**: decoded the cycle before, stage 1 (rotation and mask, counts, bit operations, comparison), stage 2 (the result). **Latency 3, was 2.** Queue 0 gets a latency-3 field (`OOO_SCHED`: 8 FF, and `rs[3]` in `req`) | Stage 1 has no result to select, stage 2 very little | **Nothing in CoreMark**: 6.823 / 7.315 / 6.599, rv64gc 5.898, as for latency 2, as CoreMark has none of them. **Other programs will see 3 cycles for a shift by a register**: `Plan/model` cannot say how much, it has no other program |
| **Each read port's copy of the banks has its own write address and enable** (`OOO_PRF2`, 9 copies with the LVT's; 8 bits × 4 ports × 9 = 288 FF), from `wb_nv`, `wb_nt`, a cycle ahead | About 130 sinks each, near what they drive, rather than about 1,000 from one | 288 FF, less what the placer replicated |

Latency 4 is the other choice (no change to the scheduler): the same in CoreMark, one more cycle for others, so 3.

**Test gap found.** M530 (a flushed `jalr` leaves its link on port 0) came back undetected. Earlier campaigns detected it by luck: it shows only with a result from outside in the cycle right after the flush. `tb_exu` now gives one in that cycle, flushes 3 times as often, and checks the coverage (`cov_xfl`). The RTL was right; the bench was thin.

Tests: `tb_exu` (with `wb_nv`, `wb_nt` against the next cycle's `wb_v`, `wb_t`, and the slow operations at latency 3), `tb_prf2` (address a cycle before the data), `tb_sched` (latency 3 now on queue 0 too; 89,386 issues at latency 3, loads included) PASS. `-Wall` clean on these modules and the harness's lines. Bug injection: all of `OOO_SCHED`'s, M478 to M609, 185 mutations, all detected, every line read (M530 after the bench's change).

**Not measured yet**: all of this. `synth_ooo.bat exu9` again; `synth_ooo.bat sched85` too, as `OOO_SCHED` changed a little. Classes now: `rare1` (stage 1) and `rare` (stage 2).

Levers if `loop` is still short, in order: `slli` out of EX (now worth less: it would take the rotation's 64 − n and little else), Zba's change of `a`, then fan-outs.

### 28.9 `OOC_EXU` about 9.2 ns; `OOC_SCHED` about 9.9 ns, and how much of it is noise (2026-11-03)

`synth_ooo.bat exu9` and `sched85`, the RTL of 28.8.

**`OOC_EXU`: WNS −0.163 ns at 9 ns, so about 9.2 ns; 12,472 LUTs** (8,312 logic + 4,160 LUT RAM). 1.5 ns better than the run before. `OOO_EXU` 5,971 of which `OOO_ALUR` 1,178 (`OOO_ALU` measured 1.9k), `OOO_PRF2` 6,500; 2.1k under `Doc/UARCH.md`'s 14.6k, though the harness has no multiplier or resolution. 3,177 FF outside the harness's.

| Class | At 9 ns | Before (28.8) | |
|---|---|---|---|
| `sel` | **−0.163** | −1.285 | 15 levels: selection → `a` → Zba's LUT → 7 carry cells → carry out → `slt` → bit 0 |
| `loop` | −0.156 | −1.120 | The same from a result |
| `oper` | +0.023 | −1.122 | |
| `write` | +0.375 | −0.896 | Now the data, not the address: fan-out 17, 7.8 ns of route |
| `tags` | +0.814 | −0.207 | |
| `flag` | +0.906 | +0.324 | |
| `rare1` | +0.962 | | New: stage 1 |
| `lvt` | +0.989 | +0.932 | |
| `rare` | +1.177 | −1.674 | Stage 2 |
| `ctl` | +1.177 | +0.117 | |
| `rf`, `snoop` | +1.937, +2.264 | +1.588, +3.036 | |

**Loop 2 fits the target of about 9.3 ns, at a model of 6.823.** No lever had to be used: `slli`, Zba and `srli` stay in the cycle. The path left is the adder's own: `slt`, with 64 bits of carry. Routes are 65 % of it, against 84 % before. It is one block alone: the core will add to it.

**`OOC_SCHED`: WNS −1.400 ns at 8.5 ns, so about 9.9 ns; 5,868 LUTs.** Was −0.776 and 5,397. The change was 8 FF and one term in queue 0's request, for latency 3 (28.8).

| Class | 8.5 ns, now | Before | |
|---|---|---|---|
| `s1` | **−1.400** | −0.633 | Ends at `rv[27]`, in the memory queue |
| `ff` | −1.310 | −0.742 | The same |
| `guard` | −1.239 | −0.702 | |
| `loop` | −0.997 | −0.776 | |
| `s2` | +0.055 | +0.057 | |
| `kill` | +0.490 | +1.112 | |
| `wake` | +1.317 | +0.818 | |
| `free` | +1.440 | −0.223 | **1.7 ns better** |
| `issue` | +2.712 | +2.347 | |

**I read this mostly as noise, but two runs cannot prove that.** The worst paths end in the memory queue, which the change does not touch, and `free` improved by 1.7 ns with nothing done for it. Synthesis gave 314 more LUTs, far more than 8 FF and a term should, 214 of them reported under `u_disp` (which is not dispatch alone, 28.5): it restructured, and the paths gained a level. If so, the 9.3 of 28.5 is one sample, and the block's real figure is somewhere from 9.3 to 9.9, which matters as much as the design: the gate cannot be read from single runs at this margin.

**What changed.** `rv` no longer has `wa` in its input: `!wa` was redundant, as a free entry has no `v` (checked by a temporary check in `tb_sched`, which never fired; its output is byte for byte the same after the change, and all 95 mutations of the scheduler are detected). So dispatch's late signal leaves `rv`, where the 3 worst classes end. It still reaches `oc`, `v`, `pw`, which were 0.01 ns behind in the earlier run, so do not expect all of it.

**To tell noise from cause**: `synth_ooo.bat sched85` and `synth_ooo.bat sched86` on the same RTL, 8.5 and 8.6 ns: the period differs by little, the placement by whatever it does. If they are about 9.3, latency 3 stays. If this RTL stays near 9.9 in both, the cheaper answer is latency 4 on queue 0, which needs no change to the scheduler and is the same in CoreMark; others pay a cycle.

Verification: `tb_sched` as above; `-Wall` clean.

### 28.10 `OOC_SCHED` on 2 placements: 9.3 and 9.6 ns; latency 3 stays (2026-11-03)

`synth_ooo.bat sched85` and `sched86`, the RTL of 28.9. **Synthesis gave the same netlist in both (5,607 LUTs, 3,147 FF), so this is the first measure of the spread of placement alone.**

| Class | 8.5 ns (`T8.5`) | 8.6 ns (`T8.6`) | 8.5 ns, before `rv` changed (28.9) | 8.5 ns, the first (28.5) |
|---|---|---|---|---|
| **Reached** | **9.31 ns** | **9.57 ns** | 9.90 ns | 9.28 ns |
| `s1` | −0.810 | −0.973 | −1.400 | −0.633 |
| `ff` | −0.589 | −0.745 | −1.310 | −0.742 |
| `guard` | −0.272 | −0.572 | −1.239 | −0.702 |
| `loop` | **−0.179** | −0.504 | −0.997 | −0.776 |
| `kill` | +0.120 | −0.056 | +0.490 | +1.112 |
| `s2` | +0.530 | −0.058 | +0.055 | +0.057 |
| `free` | +0.896 | +0.657 | +1.440 | −0.223 |
| `wake` | +1.393 | +1.499 | +1.317 | +0.818 |
| `issue` | +2.722 | +2.903 | +2.712 | +2.347 |
| LUTs after routing | 5,692 | 5,716 | 5,868 | 5,397 |

What it says:
- **The spread of one netlist is 0.26 ns here.** So differences under about 0.3 ns between single runs mean nothing, and that applies to every comparison so far in this section.
- **"Mostly noise" in 28.9 is not borne out.** 0.26 ns does not explain a change of 0.6 ns. Part of the 9.9 had a cause, or was synthesis giving a worse netlist (a different one, so outside this spread); with `rv` changed in the same step I cannot separate them.
- **Latency 3 stays**, as 28.9 said for this outcome: 9.31 and 9.57 against 9.28 for the scheduler without it, which is within the spread at the low end. The cost, if any, is under 0.3 ns.
- **The `rv` change did what it was for.** `loop`, the deciding loop, is at **8.7 and 9.1 ns**, and `guard` at 8.8 and 9.2. The worst endpoints moved from `rv` to the age bits `aq`, `ff`, `oc`: what dispatch's S1 still writes through `wa`.
- **So the block's limit is now dispatch's first phase**, `dk` → steering → bank selection → `wa` (fan-out 33 to 37) → endpoint, 9 levels, 7.4 to 7.7 ns of route. In this harness `dk` comes from a register, and rename of 4 will have to share that cycle (28.5), so loop 4's harness decides what this has to be. I leave it until then.

**A lever noted, not taken**: the age bits can update from `w2` a cycle later rather than `wa`, as an entry cannot ask before then. It would remove the worst endpoint at no cost, but the next ones (`ff`, `oc`) are 0.03 ns behind, within the spread, so a run could not show it.

**Reading the two blocks**: scheduler 9.3 to 9.6 ns, EX 9.2 ns (one placement). Against 10 ns that is about 0.4 to 0.8 ns in hand, and the core added about 1 ns at 20 ns (28.1). Within reach for gate S1-A; not comfortable for the chip, and read again at step 1.6. Model 6.823. Loops 1 and 2, the two life-or-death ones, both reach 10 ns as blocks; the next is loop 6, the uBTB of 16.

### 28.11 Loop 6: `OOO_UBTB2`, `OOC_UBTB2`, set-associative in LUT RAM (2026-11-03)

Not measured when written: `synth_ooo.bat ubtb`, in `output/OOC_UBTB2_T9`, at 9 ns as loop 2 needed (28.9).

Today's `OOO_UBTB` is 2.04 ns short at 8 entries (11.9 ns, 12 levels; 28.1), and 16 are wanted. Its path: compare all tags, then which parcel is first (`at`, `first`), then which entry (`sel`, fan-out 39), then the AND-OR of all targets. All of those grow with the entries.

**What the model says first.** `Plan/model` had an ideal uBTB: all in one set, LRU, whatever is in the block. It now has sets (`ub_sets`, by the fetch block's address, so all transfers of a block share a set) and round robin (`ub_rr`).

| uBTB | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| 16, all in one set, LRU (the proposal so far) | 6.823 | 7.315 | 6.599 | 5.898 |
| 16, all in one set, round robin (as `OOO_UBTB`) | 6.794 | 7.326 | 6.589 | 5.896 |
| 16, 4 sets of 4, round robin | 6.797 | 7.312 | 6.531 | 5.890 |
| 16, 8 sets of 2, round robin | 6.756 | 7.293 | 6.521 | 5.869 |
| 24, 8 sets of 3, round robin | 6.848 | 7.375 | 6.563 | 5.906 |
| 48, 16 sets of 3, round robin | 6.879 | 7.414 | 6.618 | 5.910 |
| **96, 32 sets of 3, round robin** | **6.889** | **7.416** | **6.650** | **5.917** |
| 128, 32 sets of 4, round robin | 6.905 | 7.422 | 6.654 | 5.921 |
| 2,048, LRU (for scale) | 6.915 | 7.427 | 6.667 | 5.928 |

So **sets cost almost nothing here**, and capacity is worth more than associativity. In LUT RAM a depth of 32 costs the same as one of 16, so the choice is 32 sets of 3: **96 entries, +1.0 % against the proposal's 16**, if the timing holds. Those figures are optimistic in 2 ways: tags are exact in the model, and training is immediate.

**The design** (`RTL/CPU/OOO/OOO_UBTB2`, a new block; `OOO_UBTB` stays with today's core).

| Item | Choice | Why |
|---|---|---|
| Storage | Distributed RAM, one copy for the prediction, one for the update | 3 tag compares instead of 16; the target's AND-OR is 3 inputs, not 16 |
| Tag | 12 bits of the block's address above the index, not folded | One level less: folding was the first LUT of today's path. An alias costs an override, as before |
| First in the block | 3 bits per set, which of 2 ways comes first, written with a way | No parcels compared and no priority in the path: one LUT for `sel` |
| Predicted taken | One bit in the RAM, computed when the counter changes | Not computed from `cond` and the counter in the path |
| Next address | Last LUT: `ovr ? hr : t \| late`; a redirect, a stall, the stack's top and the sequential address are in LUTs before it | Only the target's way is late |
| Reset | None for the table, only its initial state | A stale entry is a misprediction checked at F2, as for stale code (`Plan/OOC.md`) |
| The index | A register of its own (`pi_q`) with `max_fanout` 32 | The RAM's address has a large fan-out, the tag compare should not share it |

Levels expected, counted: RAM, compare (2), hit, `sel`, target, last: 7 or 8, against 12. Size unknown until the run: by counting, about 180 LUTs of RAM plus the logic, against 567 LUTs and 505 FF for today's 8 entries.

**What it asks of the core**: `redirect`, `redirect_pc`, `stall`, `ras_top` from registers. Today `OOO_FETCH` drives them from logic (`be_redirect || ovr`, `!acc`); the harness has registers, so **the run measures the loop, not its joining**. That has to be designed with the fetch of 32 bytes at step 1.4 and may cost: an override already takes its stages in the model, a `stall` from a register would be a cycle late.

**Verification.** `tb_ubtb2`: 800,000 cycles against a reference table of 32 sets of 3: 513,821 predicted taken, 55,152 returns, 218,886 lookups with several hits, 241,445 fills, aliases in the table, no mismatch. Bug injection M610 to M645: 36 of 36 detected. `-Wall` clean on the block and the harness's lines. `results/g100.txt` has the rows above; the old ones are unchanged.

What to read: `idx` (the index, through the RAM), `tag`, `in`, `out`, `upd`, and the total LUTs. Levers if short: 16 sets (same size; −0.1 %), a smaller tag, then fan-outs.

### 28.12 `OOC_UBTB2` meets 9 ns: about 8.9 ns, 378 LUTs, 96 entries stay (2026-11-03)

`synth_ooo.bat ubtb`, the RTL of 28.11, asked for 9 ns, in `output/OOC_UBTB2_T9`. **WNS +0.124 ns, register to register, at 96 entries: smaller and faster than today's 8.**

| | `OOO_UBTB`, 8 entries (`T10`, 28.1) | `OOO_UBTB2`, 96 entries (`T9`) |
|---|---|---|
| Asked for | 10 ns | 9 ns |
| Slack | −2.037 ns | **+0.124 ns** |
| Levels of the worst path | 12 | 8 |
| LUTs after routing | 567 | **378** (190 logic + 188 LUT RAM) |
| FF | 506 | 53, and 184 of the harness |

| Class | Slack at 9 ns | Reached | Levels | Route |
|---|---|---|---|---|
| `upd`: the update, compare, order bits, into the RAM | +0.124 | 8.88 ns | 8 | 75 % |
| **`idx`: the index, through the RAM, to the fetch address: the loop** | **+0.361** | **8.64 ns** | 8 | 72 % |
| `tag`: the fetch address's tag, to the fetch address | +1.278 | 7.72 ns | 7 | 74 % |
| `out`: the prediction, to the register that takes it | +1.897 | 7.10 ns | 7 | 68 % |
| `in`: a redirect, to the fetch address | +4.231 | 4.77 ns | 1 | 86 % |

What it says:
- **The count held**: 8 levels against 7 or 8 expected, and 188 LUTs of RAM against about 180.
- **These are ceilings, not limits**: the target was met, so Vivado stopped improving. 8.88 ns is what it left, and no run at a tighter period is needed: the question was whether the block is within about 9.3 ns, and even with the spread of a placement (0.26 ns, 28.10) it is.
- **The worst path is not the loop.** It is the update: `s_up`'s index with a fan-out of 313 (1.16 ns of route), then a tag read, the compare, `we_new`, `new_b`, into the set's order bits. Should it ever matter, the update can take a second cycle at no cost but training a cycle later. Not needed now.
- **The loop is `pi_q` (fan-out 58) → RAM → compare → `hit` → `sel` → `sel_t` (fan-out 38) → target → last LUT**, as designed. Nothing else stands in it.
- **The joining looks better than feared, not yet measured.** 28.11 asked for `redirect`, `stall`, `ras_top` from registers, and `in` has 4.2 ns to spare at 9 ns, with 3.3 ns of that path a net of fan-out 38 left unimproved. So some logic may stand in front of them: `be_redirect` and `acc` probably, while `ovr`, a compare at F2, is the one to look at. Step 1.4 decides, as said; this run did not have logic there.

**Decision: 96 entries stay, none of the levers used.** The model's 6.889 / 7.416 / 6.650 / 5.917 stands as far as this block goes, with the two optimistic points of 28.11 (exact tags, immediate training).

**Reading the three blocks**, each alone:

| Loop | Block | Reached |
|---|---|---|
| 1 | `OOC_SCHED` | 9.3 and 9.6 ns (`loop` 8.7 and 9.1) |
| 2 | `OOC_EXU` | 9.2 ns |
| 6 | `OOC_UBTB2` | 8.9 ns (`idx` 8.6) |

Left in step 1.1: M1 / M2 with block RAM (loop 3), rename of 4 (loop 4), the fetch buffer split (loop 5).

### 28.13 Loop 3: `OOO_LSU2`, `OOO_DCH`, `OOO_DTLB2`, `OOC_LSU2`; what a store's data costs (2026-11-03)

Not measured when written: `synth_ooo.bat lsu2`, in `output/OOC_LSU2_T9`, at 9 ns as loop 2 needed (28.9).

Building M2 turned up something the model did not have, so that comes first.

**A load whose store has no data yet.** The proposal splits stores: the address issues alone, and a load behind it need not wait for the data (+3.8 %). The model then gave such a load its value when the data came, and woke its dependents then. The scheduler cannot do that: a load's dependents are woken at a fixed time after its issue, with no cancel (`OOO_SCHED`), so a load that finds its store without the data has to replay at its commit, as for a miss. CoreMark does this about once in 270 instructions. New options in `Plan/model`: `ld_rp` (it replays), `sd_lag`, `sd_alu` (the data is a µop), `sd_q`, `ld_wt` (a wait table), `sd_ord`. `Plan/model/results/g100.txt`; rv64gc from the same options.

| A store's data | `-O2` | most optimization | g13 | rv64gc | Replays in `-O2` |
|---|---|---|---|---|---|
| As modelled so far: no slot, no replays, no wait | 6.889 | 7.416 | 6.650 | 5.917 | 0 |
| The same, with the replays, the data a cycle behind a dependent | **5.767** | 6.199 | 5.614 | 4.984 | 11,412 |
| Stores not split: a store issues with its data | 6.320 | 6.903 | 6.129 | 5.568 | 0 |
| A µop in any ALU queue: slot, dispatch, entry; no replays | 6.784 | 7.344 | 6.551 | 5.831 | 0 |
| ... with replays | 5.588 | 6.041 | 5.435 | 4.939 | 12,825 |
| ... with a wait table of 1,024 bits | 6.749 | 7.294 | 6.510 | | |
| ... of 64 bits | 6.741 | 7.271 | 6.493 | 5.795 | 10 |
| **... and on queue 2 alone: proposed** | **6.726** | **7.234** | **6.484** | **5.797** | 11 |
| No µop: the SQ reads the data in order, 4 cycles behind, wait table | 6.464 | 6.833 | 6.272 | 5.655 | 18 |

So: **+3.8 % was not real as it stood, and not splitting costs −8.3 % against what the proposal claimed, more than the +3.8 % suggested.** What keeps most of it:
- **The data is a µop of its own**, in an ALU queue, with the operand going through to the SQ: a dispatch slot, an entry, an issue slot. −1.5 %.
- **A wait table, as the Alpha 21264's**: a bit per load pc; a load that replayed for this waits next time for the data of all older stores. 64 bits are enough (10 replays against 11,000), so one LUT, read at decode. The rest of the cost is those loads' waiting: −0.6 %.
- **Queue 2 alone**, so that the SQ's data has one write: −0.2 %.

**The proposal: 6.726, −2.4 % against 6.889; about 6.32 in RTL at × 0.94**, just above the gate's 6.3, under step 1.2's "model ≥ 6.8". **The author decides** (`Doc/STRATEGY.md` 4.2 keeps it marked so). What it asks elsewhere: dispatch cracks a store into 2 µops; `OOO_SDISP` gives a marked load's row the columns of the older data µops (the cells are there, a load's row already covers all the queues); a kind "queue 2 only". Loop 1's block will have to be run again with that. The way from queue 2's operand to `sd_*` is not in `OOO_EXU` yet.

An offset alias (below) costs nothing in these programs: 22 at most, 6.484 to 6.482.

**The design** (`RTL/CPU/OOO/OOO_LSU2`, `OOO_DCH`, `OOO_DTLB2`, new; `OOO_LSU` stays with today's core). The D$ stays 64 sets of 4 ways, 64-byte lines, 16 KB. The pipeline: RR2, E, M1, M2, M3.

| Item | Choice | Why |
|---|---|---|
| The arrays | Block RAM, read at the end of E; data, and 2 copies of the tags | Clock to out about 2.5 ns in M1; a copy of the tags for the drain, so loads and stores never wait for each other (today's `s_force`, `DRAIN_WAIT` go) |
| Alignment | In M1, in each way, before the way is known; naturally aligned so one byte has a mux of 8, the others less; the sign from one mux of 8 chosen in E | About 40 LUTs a way; M2 has no shifter |
| M2 | Tag compare, then one AND-OR of 5: 4 ways and the SQ's word | The levels of today's path that this removes: align, sign, the choice of way behind miss logic |
| The result's valid | With any load in M2, whatever the hit | `ld_nv` has fan-out to 3 + 9 copies; a hit is late. A write that failed goes to a register nobody may read yet |
| DTLB | 32 sets of 2 ways of 4 KB in LUT RAM, as `OOO_UBTB2`; a larger page is kept as the 4 KB asked for | 2 compares, not 32. In M1 from a register. No ASID: flushed at a change of `satp`, by a walk of the sets |
| The search of the SQ | Page offset and bytes in M1, one store chosen; in M2 the physical tag, coverage, the data of that one | M1 has no physical address. A store with another page behind that offset: the load waits for it to leave |
| Choosing the youngest | From the load's place in the ring, 2 priority encoders | No age matrix (240 FF less); the load carries `sq_tail` from dispatch, its older stores come from it and the head |
| A store's data | Replicated to 64 bits when it comes, in LUT RAM, 2 copies | It is in the right lane for any load and any byte enable, without its offset: the data may come first. Also, the SQ's data takes 88 LUTs in place of 1,024 FF |
| The SQ's word | A fifth way, aligned by the same function | |
| Tries | Through RR2 in a free cycle, the address as the operand, offset 0; one RAM for loads and stores; at an event; in turn, but first the µop just answered (`done_id`) | No mux in E. And no fill path: a miss's data is found in the D$ by a try. One at a time; any recovery drops it |
| What the scheduler guarantees | A load issues after every older store, so all the offsets are there in its M1 | No "store without an address" bit or check, which `OOO_LSU` had |
| The drain | Own pipeline, D0 to D3; a store that misses or meets a tag write goes back | One a cycle, whatever the loads do |

Levels expected, by counting. E: mux 2, adder, RAM's setup. M1: RAM, 3 for a way's align. The search: 3 for a match, 4 for the choice. M2: compare 3, way 1, AND-OR 2, or RAM, align 3, AND-OR 2. Size unknown; today's `OOC_LSUDC` is 7,989 LUTs with the miss logic.

**What the run measures, and does not.** The hit path, the queues at 16, the drain, the DTLB. The harness has EX's mux of 5, the operand and the result's 3 registers, but not their other sinks. **Not there**: the miss handler (ports, step 1.7, half-rate); what is not cacheable, AMO, LR, SC (non-speculative at the ROB's head); the victim's read, which would go through RR2 as a try does, with a way to hold the queue off; PMP (in the DTLB's `r_ok`, `w_ok` from the walk with translation on; with it off, open); the wait table and the crack (decode, dispatch).

**Verification.** `tb_lsu2`: 2 runs of 600,000 cycles, physical and translated: a random program over 8 pages and 6 lines per page, part of the time few pages, part of the time 4 pages in one set of the DTLB. Quiet phases: no new µops, recoveries or walks, and all must end. With nothing in flight, 2 pages change places behind a DTLB flush. The value of every load against program order, exceptions, a replay exactly when it ran twice, every store written in commit order into the way with its line, nothing else writing the data array.

| Covered | Physical | Translated |
|---|---|---|
| Loads, stores | 53,045, 43,967 | 49,950, 42,910 |
| Loads meeting a store (partly) | 4,634 (1,947) | 4,340 (1,733) |
| Another page at the same offset | 12,021 | 10,754 |
| Tries, replays | 39,858, 13,977 | 40,184, 13,417 |
| Misses, stores' misses, evictions | 13,784, 8,519, 11,560 | 5,374, 2,987, 6,108 |
| Walks, DTLB flushes | | 22,199, 119 |
| Data late | 558 | 406 |
| Exceptions, recoveries, flushes | 604, 885, 857 | 865, 788, 1,100 |

**It found 2 faults in the design**: a try dropped by a recovery in M3 cleared its wait, so the load was lost; and tries by lowest number starved a store behind loads that kept losing their page, so they go in turn, and who was answered goes first. And 3 errors of its own: commits past unresolved branches, values behind an exception, too few pages.

**Bug injection**: M650 to M706, **48 of 48 detected**, every line read. The passes before missed these, each read too:
- **Bench gaps, closed**: a µop killed in RR2 (none was issued then), a line or a DTLB entry invalid hits (the tag stayed 0), the tag's top bit, a store not translated that forwards (its page must share a DTLB set with the load's), a flush that leaves a way (the mapping never changed), a store written over a tag write (too rare to show in a value: the bench now looks at the array's write enable; so `--public-flat-rw` for this test).
- **Not needed, removed from the RTL**: the store-without-an-address check, 3 mutations with it: the scheduler guarantees it.
- **Removed as they change only the time**: the head a cycle earlier (one try more), a store with no byte of the load matching (a wait), tries without an event, the data's or a translation's coming as no event (a store's leaving wakes them anyway), an event at the launch (the try sees what it did), no turns. So `sd_valid` and a store's M2 in `ev` are for speed, and a slower design passes.
- **Not proved: `done_id`**. Without the first try the bench hung once (5,000 cycles without a commit), and has not since, with the thrash phase aimed at it. So it stays as a guard against a livelock that I could not make come on demand, with no mutation.

What to read: `e_ram`, `dat`, `cam`, `hit`, `fwd`, then the rest, and the total. Levers if short: `DO_REG` is no use (a cycle); the sign and the upper half after M2's AND-OR; the DTLB's `tr_on` mux; an SQ of 12.

### 28.14 `OOC_LSU2` about 8.1 ns, 2,053 LUTs; stores decided; the data µop in `OOO_SCHED` (2026-11-03)

`synth_ooo.bat lsu2`, the RTL of 28.13, asked for 9 ns, in `output/OOC_LSU2_T9`. **WNS +0.898 ns, register to register: loop 3 fits, by the widest margin of the loops so far.**

| Class | Slack at 9 ns | Reached | Levels |
|---|---|---|---|
| **The tags to the result**, RAM's output register, compare, way, AND-OR | **+0.898** | **8.10 ns** | 7 |
| `hit`: the physical tag to the result | +1.344 | 7.66 ns | 7 |
| `cam`: the search of the SQ | +1.363 | 7.64 ns | 6 |
| `fwd`: the SQ's data to the result | +1.513 | 7.49 ns | 5 |
| `drain` | +1.673 | 7.33 ns | 6 |
| `try` | +2.007 | 6.99 ns | 6 |
| `tlb` | +2.094 | 6.91 ns | 5 |
| `e_ram`: EX's mux, the adder, the arrays' address | +2.124 | 6.88 ns | 5 |
| `dat`: the data's clock to out, a way's alignment | +2.513 | 6.49 ns | 3 |
| `ok` | +2.517 | 6.48 ns | 7 |
| `e_m1` | +2.707 | 6.29 ns | 6 |
| `m3` | +2.888 | 6.11 ns | 6 |
| `way`: a way's word to the result | +5.242 | 3.76 ns | 2 |

Size: 2,053 LUTs (1,778 logic, 248 LUT RAM, 27 shift registers), 1,335 FF in the block and 1,346 of the harness, 4 RAMB36 + 8 RAMB18. Today's `OOC_LSUDC`, −2.657 ns at 10, is 7,989 LUTs, but with all of the miss logic (5,460 in `DCACHE`), which this does not have; its `OOO_LSU` alone, 8 and 8 entries, is 2,242.

What it says:
- **Levels as counted**: 7 at M2 against 6 expected, 6 in the search against 7, 5 in E.
- **The class `tag` said "no cells"**: Vivado moved `m2_t` into the block RAM's own output register, so the tags' first LUT starts about 1.2 ns after the clock. It is what the design wants, with the same cycles. `report_lsu2.tcl` now reads `tag` from the RAM to the result.
- **It stopped once met**, so 8.1 ns is a ceiling. 70 % of the worst path is route, 1.9 ns of it the first way's hit, fan-out 26. No run at a tighter period is needed: the block is well inside about 9.3 ns.
- **What this does not have will cost, how much is not known**: the miss handler, what is not cacheable, the other sinks of EX's mux and of `ld_d`, `sd_data` straight from EX's mux. None of them is in M2's compare; they load its neighbours.

**The author accepts the stores of 28.13 (2026-11-03): the data a µop on queue 2, a wait table of 64 bits. The model is 6.726 / 7.234 / 6.484 / 5.797, RTL about 6.32, 632 CoreMark/s.** It leaves 0.02 over gate S1-B's 6.3, and step 1.2's "model ≥ 6.8" is no longer met; its figure is the author's to change (`Doc/STRATEGY.md` 5).

**In `OOO_SCHED`, `OOO_SDISP`**: `disp_kind` 3, queue 2 alone; `disp_sd`, a field in that queue's 8 entries; `disp_wl`: a marked load's row takes the data µops not issued, with the same term as older stores' (and one for those of its group). Nothing new in the loop: the row's cells are there, a data µop clears its column at its issue as a store does. The new terms are in dispatch's S1, the limit of `OOC_SCHED` (28.10), so **it has to be measured again**: `synth_ooo.bat sched85`, to compare with 9.31 ns (spread 0.26 ns). `OOC_SCHED` has the 2 new inputs.

Not built yet: the crack in decode and renaming, the table itself (a RAM of 64 × 1, trained by `wt_*` through the ROB's pc), the way from queue 2's operand to `sd_*`. They come with steps 1.3 and 1.4; only the crack bears on loop 4, which comes next.

**Verification.** `tb_sched`: as before, with data µops and marked loads in the account: 443,860 issued, 28,355 data µops, a marked load held by one 20,545 times, no mismatch. Bug injection: all of `OOO_SCHED`, `OOO_SDISP`, with M710 to M716 new: **102 of 102 detected**, every line read (M445's text had moved, and was run again). -Wall clean on the blocks and harness.

### 28.15 `OOC_SCHED` with stores in 2 µops: 9.06 ns; nothing lost (2026-11-03)

`synth_ooo.bat sched85`, the RTL of 28.14, against the same target before the change (28.10).

| Class | 8.5 ns, with the data µop | 8.5 ns, before (28.10) | 8.6 ns, before (28.10) |
|---|---|---|---|
| **Reached** | **9.06 ns** | 9.31 ns | 9.57 ns |
| `s1` | −0.563 | −0.810 | −0.973 |
| `guard` | −0.560 | −0.272 | −0.572 |
| `ff` | −0.467 | −0.589 | −0.745 |
| `loop` | **−0.186** | −0.179 | −0.504 |
| `kill` | +0.200 | +0.120 | −0.056 |
| `s2` | +0.279 | +0.530 | −0.058 |
| `free` | +1.434 | +0.896 | +0.657 |
| `wake` | +1.573 | +1.393 | +1.499 |
| `issue` | +3.078 | +2.722 | +2.903 |
| LUTs after routing | 5,707 | 5,692 | 5,716 |
| FF in the block | 2,837 | 2,832 | |

**The data µop and the marked load cost nothing that can be seen.** 15 LUTs and 5 FF more: 8 FF of `sdq` less what synthesis merged. **Not an improvement**: 9.06 against 9.31 is 0.25 ns, within the 0.26 ns of 2 placements, and this is a different netlist. `guard` went the other way by the same amount. What can be said: loop 1 stays at 9.1 to 9.6 ns, `loop` itself at 8.7 to 9.1, and the worst endpoint is still dispatch's S1 into the age bits, the lever of 28.10 still unused.

So **the stores of 28.13 hold in loop 1**, and the model's 6.726 stands for what is built. Next: loop 4, rename of 4, with the store's 2 µops.

### 28.16 Loop 4: `OOO_RENAME2`, `OOC_RENAME2`, rename of 4 in 2 stages (2026-11-03)

Not measured when written: `synth_ooo.bat ren2`, in `output/OOC_RENAME2_T9`, at 9 ns. **`synth_ooo.bat sched85` has to run again too**: `OOO_SDISP` changed below.

Today's `OOO_RENAME` is +1.04 ns at 2 µops in one stage, with 2,657 LUTs, a RAT of 4 + 2 read ports, 6 checkpoints in flip-flops. Scaled to 4 µops, 12 checkpoints, 80 registers, it would be 3 times the reads and 5 times the checkpoint bits. So it is a new block. `OOO_RENAME` stays with today's core.

**What R1 and R2 have to be.** `OOO_SDISP`'s S1 is R2, and it compares `disp_src`, `disp_dst` from registers: so the physical sources and the new registers have to be known at the end of R1, not R2. So R1 does it all and R2 is registers.

| Item | Choice | Why |
|---|---|---|
| R1 | RAT read, dependences among the 4, the new registers, the RAT written, at its end | S1 needs them from registers. Counted: 5 levels |
| R2 | What S1 does not take stays in its slot; R1 moves when none is left | `adv` is S1's late `disp_go`. Slots do not shift, so no mux of 4 on some 170 bits; so `OOO_SDISP` takes gaps: a slot not valid has no part in steering (changed here) |
| Busy bits | None | `OOO_SDISP` compares a source with what is pending (28.4) |
| Free list | A ring of 64 places for 48 registers, 4 banks of LUT RAM, place p in bank p % 4 | A group's n places touch n banks once, for reads and for writes, so one port a bank. A power of 2, with no wrap logic. Read from a register per bank (`rb`), no adder in the path: about 32 LUTs against 48 × 7 FF and their muxes |
| Short of registers | A group waits if fewer than 8 were free in the last cycle | No count in the path; the ROB's 48 entries keep it from happening but with nearly all writers. Not in the model |
| Checkpoints | LUT RAM, one write, one read: 12 of 269 bits. **2 a group**, ids in a ring so one even, one odd, each its bank | About 360 LUTs + the read's mux against 3,200 FF and a mux of 12. A write of all the bits has one address, which is what LUT RAM is good for |
| Inside a group | The RAT as it is after the group, a cycle later, and what undoes the younger µops: up to 3 | Every checkpoint takes the same data, as today's |
| Restore | 2 cycles: the RAT, then the undoes through the RAT's write ports, the oldest on the port that wins | No mux of undoes on the RAT. The front end is at least 8 stages behind, so it costs nothing |
| Ids | A restore gives its own id next | The open ones stay in a row of the ring. `OOO_RENAME`'s `restore_id + 1` leaves a hole: **found by the bench**, as ids were reused while open |

**What the model says about checkpoints a cycle** (`Plan/model`: `ck_max`, `ck_end`):

| Checkpoints | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| Any number | 6.726 | 7.234 | 6.484 | 5.797 |
| **2 a cycle: as built** | **6.722** | **7.234** | **6.487** | **5.797** |
| 1 a cycle | 6.697 | 7.182 | 6.438 | 5.731 |
| A checkpoint ends its group | 6.543 | 7.074 | 6.322 | 5.685 |
| Any number, rename a stage more | 6.698 | 7.203 | 6.459 | 5.777 |

The simplest choice, a checkpoint ending its group with no undoes, costs −2.7 %, so it is not taken. 1 a cycle costs −0.4 % and would have put RTL (× 0.94) under the gate's 6.3: 6.295. So **the model is now 6.722 / 7.234 / 6.487 / 5.797, RTL about 6.32**. A stage more for rename would cost −0.4 %, the fallback named in `Doc/STRATEGY.md` 4.5.

**In `OOO_SDISP`**: slots may be not valid among valid ones: `ta`, `tb` and `nalu` take `disp_valid`; a slot not valid does not stop the younger ones. A bit more in S1, the block's limit, so it runs again.

The store's 2 µops are 2 slots here, each with one source; neither takes a register. So nothing in this block knows about them: the crack comes before it, the ROB entry after.

**What the run measures, and does not.** The harness has `disp_go` as a port with 55 % of the period as its delay, my estimate of where it comes in S1's worst path; the rest from registers. `adv` to about 170 R2 bits, the RAT's 224 and the ids is the path to read, with `go`. Not there: the ROB entry (`OOO_ROB` at 4 wide comes with step 1.5), the branch mask (`OOO_CTRL`), the decoded queue before it. `arat` is in flip-flops as today's, 224 FF and 4 writes: to be moved to banks with an LVT if size calls for it, as a flush can walk it in 8 cycles.

**Verification.** `tb_rename2`: 800,000 cycles against a reference of its own: 605,485 µops, 80,921 sources inside a group, 45,921 groups with 2 checkpoints, 33,116 restores (10,342 with undoes, 9,832 at the earliest cycle), 777 flushes, 302,362 commits, 170,063 cycles short of registers, 207,313 slots held in R2, no mismatch. It found 2 faults: the next id after 2 checkpoints came from the first, and the hole above. `tb_sched`, with slots not valid among valid: 425,427 issued, 76,494 such slots, no mismatch. Bug injection: `rename2` M720 to M751 but M734, M751, **30 of 30**, `sched` with M717 to M719 **105 of 105**, every line read. M734 (an id for one not taken: its younger ones are not taken either) was equivalent and removed; M751 showed that `pk_head`, `pk_ad` need no enable, and the RTL lost it. M447's text had moved and was corrected. -Wall clean on the block and harness.

What to read: `go`, `r1`, `read`, `tag`, `rat`, `ck`, `rest`, `cmt`, and the total. Levers if short: the R2 fields with `max_fanout`, a stage more (−0.4 %); the old mapping's 4 read ports could go to the ROB's commit.

### 28.17 `OOC_RENAME2` about 8.1 ns but for `disp_go`; `OOC_SCHED` 9.95 ns with gaps; steering a cycle ahead (2026-11-04)

`synth_ooo.bat ren2`, the RTL of 28.16, in `output/OOC_RENAME2_T9`, and `sched85`.

**`OOC_RENAME2` at 9 ns: register to register +0.909 ns, 8.09 ns, 3,146 LUTs (376 LUT RAM), 679 FF in the block.** Today's 2-µop block is 2,657 LUTs: 4 µops, 12 checkpoints and 80 registers for 18 % more.

| Class | Slack at 9 ns | Reached | Levels |
|---|---|---|---|
| **`go`: the port, at 55 % of the period, to the state** | **−0.092** | 4.83 ns of path after the port | 5 |
| `rat` | +0.909 | 8.09 ns | 5 |
| `rest` | +1.347 | 7.65 ns | 3 |
| `ck` | +1.728 | 7.27 ns | 3 |
| `cmt` | +1.813 | 7.19 ns | 3 |
| `r1` | +2.359 | 6.64 ns | 5 |
| `read` | +2.580 | 6.42 ns | 5 |
| `tag` | +2.624 | 6.38 ns | 4 |

Levels as counted (5). So what is left is one question: when `disp_go` comes.

**`OOC_SCHED` at 8.5 ns, with `disp_valid` in the steering: 9.95 ns**, against 9.06 ns (28.15), 5,808 LUTs. 0.89 ns is more than the 0.26 ns of placement. `s1` −1.450, `ff` −1.290, `guard` −0.943, `loop` −0.767, `kill` −0.454, `s2` −0.079. The worst path is 10 levels: slot's kind, its queue by `rk` and `nalu`, the older slots' banks one after another, `disp_go`, then `wa`. And it shows the estimate of 28.16 was wrong: **`disp_go[3]` comes about 7 levels in, at 70 to 80 % of the period, not 55 %.** With the 4.83 ns behind it, `adv` would need about 11 ns. Taking `disp_valid` out of the steering would give back S1, not `adv`.

**So the steering moves a cycle ahead.** In the cycle before S1, for the slots as they will be then (`s0_valid`, `s0_kind`: R1's if the group moves on, else what stays of R2's), `OOO_SDISP` chooses each slot's queue and how many go before it there, into registers (`sq`, `sr`). In S1 a slot's bank is 1 or 2 LUTs from those and the banks' room: the first takes A, else B; a second takes B if A has room too, as then the first took A; a third waits. `disp_go` is about 3 levels from registers, and `wa`'s path, the worst of S1, the same levels shorter. Nothing else in S1 changes.

| Steering | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| The order 2 old, in S1 (28.16) | 6.722 | 7.234 | 6.487 | 5.797 |
| **The order 3 old, chosen again every cycle: as built** | **6.709** | **7.229** | **6.465** | **5.757** |
| The order 4 old | 6.665 | 7.208 | 6.421 | 5.729 |
| A group's queues fixed at R1, not chosen again | 6.502 | 7.002 | 6.261 | 5.597 |

The last row is why it has to be chosen again every cycle: a µop stuck on a full queue goes to an emptier one a cycle later, which is worth 3 %. So `s0_*` is a mux by `adv`, and `disp_go` runs into it: the reason `sq`, `sr` need `disp_go` early too.

**The model is now 6.709 / 7.229 / 6.465 / 5.757, RTL at × 0.94 about 6.31, 631 CoreMark/s. That is 0.01 over gate S1-B's 6.3: nothing in hand.** A lever if the RTL falls short: queues of 10 (6.767 on the row of 28.13), with loop 1's cost to measure.

**The harness** `OOC_SCHED` now has R2 as `OOO_RENAME2` has it: what stays stays, `adv` enables the fields, and `s0_*` is the mux. `report_sched.tcl` has 2 new classes: `go`, to the top bits of `out`, and `ahead`. `OOC_RENAME2`'s `disp_go` delay is now 45 % of the period, to be checked against `go`: at 9 ns that is 4 ns; if `go` says later, the delay goes with it.

**Verification.** `tb_sched`: the group is chosen at the end of the cycle before, with the order the block has then: 421,091 issued, 76,109 slots not valid among those valid, 26,588 data µops, no mismatch. Bug injection on all of `OOO_SCHED`, `OOO_SDISP`, with the steering's rewritten and M779 new: **106 of 106 detected**, every line read; M778 (no new queue for a slot not valid) was equivalent and removed. The mux `s0_*` itself is R2's, not in this block: the bench's groups do not stay, so choosing again is not tested until R2 joins it; the harness has it for the timing.

Next: `synth_ooo.bat sched85` and `ren2`. To read: `go`, then `s1`, `ff`, `loop`, against 9.06 ns.

### 28.18 Steering a cycle ahead: `OOC_SCHED` 8.91 ns, `OOC_RENAME2` about 9.1 ns; loops 1 and 4 hold (2026-11-04)

`synth_ooo.bat sched85` and `ren2`, the RTL of 28.17.

| `OOC_SCHED` at 8.5 ns | Steering ahead | With gaps in S1 (28.17) | Before gaps (28.15) |
|---|---|---|---|
| **Reached** | **8.91 ns** | 9.95 ns | 9.06 ns |
| `guard` | **−0.402** | −0.943 | −0.560 |
| `loop` | −0.136 | −0.767 | −0.186 |
| `ff` | +0.001 | −1.290 | −0.467 |
| `ahead`: the steering of the next cycle | +0.001 (14 levels) | | |
| `s1` | **+0.232** | −1.450 | −0.563 |
| `s2` | +0.258 | −0.079 | +0.279 |
| `kill` | +0.215 | −0.454 | +0.200 |
| `free` | +1.113 | +0.418 | +1.434 |
| `wake` | +1.401 | +1.378 | +1.573 |
| `issue` | +2.486 | +3.236 | +3.078 |
| `go`: to `disp_go` | +3.573 (5 levels) | | |
| LUTs after routing | 5,710 | 5,808 | 5,707 |
| FF in the block | 2,851 | 2,837 | 2,837 |

**The first run of this block under 9 ns, with the harness now carrying R2.** The overall gain of 0.15 ns against 28.15 is within the spread (0.26 ns), but **`s1` moved by 0.8 ns, which is not**: dispatch is no longer the limit. What limits now is the loop itself: `guard` 8.90, `loop` 8.64. 14 FF more for `sq`, `sr`, no LUTs to speak of.

**`disp_go` comes at about 4.9 ns** (`go`, 8.5 − 3.57), 58 % of that period: 5 levels, not the 3 I counted, and not optimized as it had time to spare. `ahead` runs through it, `adv`, the mux, the rank, 14 levels, and was met at +0.001, so Vivado stopped there: it is a ceiling, and worth looking at when the core is joined.

| `OOC_RENAME2` at 9 ns | `disp_go` at 45 % | `disp_go` at 55 % (28.17) |
|---|---|---|
| `go` | +0.289 | −0.092 |
| `rat` | +1.082 | +0.909 |
| `ck` | +1.857 | +1.728 |
| `rest` | +2.325 | +1.347 |
| `cmt` | +2.377 | +1.813 |
| `r1` | +2.394 | +2.359 |
| `tag` | +2.878 | +2.624 |
| `read` | +2.897 | +2.580 |
| LUTs | 3,143 | 3,146 |

The RTL of the block is the same in both, so they measure 2 arrivals. **The 45 % I set (4.05 ns) is earlier than the 4.9 ns measured, so the run to go by is the earlier one**, 55 % (4.95 ns): −0.092, **about 9.1 ns**. Register to register, 7.9 to 8.1 ns. No run is needed for that; the delay in `synth_ooo.tcl` goes back to 55 %.

**Decision: both hold, no lever used. The model stands at 6.709 / 7.229 / 6.465 / 5.757, RTL about 6.31.**

Where the loops are, each alone:

| Loop | Block | Reached |
|---|---|---|
| 1 | `OOC_SCHED` | 8.9 ns (`loop` 8.6), 9.1 to 9.6 before |
| 2 | `OOC_EXU` | 9.2 ns |
| 3 | `OOC_LSU2` | 8.1 ns |
| 4 | `OOC_RENAME2` | 9.1 ns with `disp_go`; 8.1 from registers |
| 6 | `OOC_UBTB2` | 8.9 ns |

Left in step 1.1: the fetch buffer split (loop 5), −3.31 ns as today's. Then gate S1-A.

### 28.19 Loop 5: `OOO_FBUF2`, `OOC_FBUF2`, the head an instruction, not a parcel (2026-11-04)

Not measured when written: `synth_ooo.bat fbuf2`, in `output/OOC_FBUF2_T9`, at 9 ns.

Today's `OOO_FBUF` is −3.31 ns at 10 ns, 15 levels: the head parcel, a window of 8 parcels from 2 blocks, the lengths one after another, the count taken, the head parcel. For 32-byte blocks and 6 instructions all of those grow. `OOO_FBUF` stays with today's core.

**Nothing in the loop looks at an instruction any more.**

| Item | Choice | Why |
|---|---|---|
| Boundaries | From F3's predecode (`in_st`), which has to find them anyway | The chain of lengths is gone from here |
| F4 | A table of the block's instructions: where each is (`p`), how many (`n`), whether any is rare | 16 × 5 bits; counted about 8 levels from registers |
| D1 | The head is an instruction: a count down of what is left and a counter per slot | **The loop is what is left → how many → what is left: 3 levels**, against 15 |
| One block a cycle | What is left of a block goes alone | No second block in any path, no window. The model below |
| Slots | Counter → table → a mux of 17 of parcels, per slot | Not a loop. About 1,150 LUTs: the largest part |
| Across 2 blocks | A first half at the last parcel is the next block's first: that block keeps it in place 0, and its FTQ entry | The slots' mux has one more input; a block with only a first half is not kept |
| Rare classes | A block with any gives 1 instruction a cycle | Not in the count. CoreMark has none where it counts; FP code pays, with its unit half-rate anyway. **Not in the model** |
| The blocks that wait | 8 in LUT RAM, one wide word; a block goes straight to the one being read when none waits | About 400 bits at about 270 LUTs; no extra cycle |
| Decode's room | All or nothing, from the decoded queue's room in a register | No late `consume` |

**The model** (`Plan/model`: `dec_block`):

| Decode | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| Any 6 across blocks (28.17) | 6.709 | 7.229 | 6.465 | 5.757 |
| **One block a cycle: as built** | **6.707** | **7.226** | **6.460** | **5.755** |
| Any 6, decode a stage more | 6.681 | 7.198 | 6.440 | 5.738 |

So one block a cycle costs nothing to speak of, as a block seldom has more than 6, and it saves a stage worth −0.4 %. **RTL at × 0.94 about 6.305, 630 CoreMark/s: 0.005 over gate S1-B's 6.3.** The gate is now a matter of the 0.94 itself, which is today's core's ratio and not known for this one. I am saying so plainly: it is for gate S1-A.

**What the run measures, and does not.** F4's table, D1, the wait, from registers into what would be D2's. `in_st` from a register: OOO_PREDEC has to give it at F3's end, 16 parcels and the carry-in, not measured. Not there: `OOO_FETCH` at 32 bytes, the FTQ, decode of 6, the decoded queue with the store's crack (step 1.4).

**Verification.** `tb_fbuf2`: 2 million cycles against the program it is given: 706,068 blocks (414,424 taken, 65,702 with only a first half), 2,911,760 instructions in, 141,020 across 2 blocks, 294,573 cycles with 6, 992 flushes, no mismatch; every instruction's bits, parcel, FTQ entry, taken, slot 0's rare, the number given exactly, nothing idle. Bug injection: M780 to M811 but M801, **31 of 31**, every line read; M801 (a block straight in also written to the RAM, with the pointer not moved) was equivalent and removed. -Wall clean on the block and harness.

What to read: `loop`, `slot`, `tab`, `rare`, `load`, `ram`, and the total. Levers if short: the slots' positions read a cycle ahead; `tab` across F3 and F4.

### 28.20 `OOC_FBUF2` about 8.65 ns, 2,003 LUTs; all six loops measured; gate S1-A open (2026-11-04)

`synth_ooo.bat fbuf2`, the RTL of 28.19, asked for 9 ns, in `output/OOC_FBUF2_T9`. **WNS +0.352 ns, register to register.** Today's is −3.31 ns at 10 ns.

| Class | Slack at 9 ns | Reached | Levels |
|---|---|---|---|
| Worst: `c_v`, the count, keep it, into the RAM's write enable | +0.352 | 8.65 ns | 5 |
| `tab`: the starts to the same | +0.541 | 8.46 ns | 5 |
| `slot`: counters, table, parcels, to the slots | +1.015 | 7.99 ns | 7 |
| `load` | +2.807 | 6.19 ns | 2 |
| `ram` | +2.794 | 6.21 ns | 2 |
| `rare` | +2.845 | 6.16 ns | 7 |
| **`loop`: the head's loop** | **+3.505** | **5.50 ns** | 2 |

Size: 2,003 LUTs (258 LUT RAM), 458 FF in the block. Today's: 1,115 LUTs for 4 slots from 16-byte blocks.

What it says:
- **The loop is gone as a limit**: 2 levels against 15. It stopped once met, so 5.50 ns is a ceiling.
- **The worst path is no loop**: an empty block not being written. 81 % route. An easy lever if it ever matters: a block's emptiness from `in_st` alone.
- **The count held**: the slots 7 levels, about as expected. The table is 5 levels, against about 8 counted: LUTs took more than I gave them.

**Decision: it holds, no lever used. The model stands at 6.707 / 7.226 / 6.460 / 5.755, RTL about 6.305, 630 CoreMark/s.**

**All six loops, each alone:**

| Loop | Block | Asked for | Reached | LUTs | Today's at 10 ns |
|---|---|---|---|---|---|
| 1 Wakeup + select | `OOC_SCHED` | 8.5 ns | **8.91 ns** (`loop` 8.64); 9.1 to 9.6 on earlier RTL | 5,710 | −1.95 |
| 2 Bypass + ALU | `OOC_EXU`, with the register file | 9 ns | **9.16 ns** | 12,472 | −0.66 |
| 3 M1 + M2 | `OOC_LSU2`, without the miss logic | 9 ns | **8.10 ns** | 2,053 | −2.66 |
| 4 Rename of 4 | `OOC_RENAME2` | 9 ns | **9.09 ns** with `disp_go` as measured; 8.1 from registers | 3,143 | +1.04, 2 µops |
| 5 Fetch buffer | `OOC_FBUF2` | 9 ns | **8.65 ns** (`loop` 5.50) | 2,003 | −3.31 |
| 6 uBTB | `OOC_UBTB2` | 9 ns | **8.88 ns** (`idx` 8.64) | 378 | −2.04, 8 entries |

**Gate S1-A (`Doc/STRATEGY.md` 5): "all six within reach at 10 ns; the configuration frozen; go, or fall back to 75 MHz, or to 50 MHz and 3-wide".** It is the author's. What I can put in front of it:

- **For going on.** All six are under 9.2 ns alone, against the 10.6 to 14.3 of today's. None uses the fallback in its row. The worst of the model's costs, a load-use of 4 or an ALU in 2 cycles, are not needed.
- **The margin is thin.** The core added about 1 ns at 20 ns (28.1). So loops 2 and 4 would be at about 10.2 and 10.1 ns, and loop 1 about 9.9. That is within reach, not inside it. It was measured once, at 50 MHz, on another design.
- **The joins are not measured.** `OOO_FETCH` at 32 bytes with the predecode's `in_st` (`OOC_FE` is −4.79 ns today, the worst of all, and is not one of the six), the FTQ, decode of 6, the decoded queue with the store's crack, the ROB at 4 wide (`OOC_ROB`: +1.03 at 2), `OOO_CTRL`, the miss handler, what is not cacheable. `OOC_FE` is the largest of these.
- **CoreMark/MHz has no margin.** The model went from 6.90 to 6.707 as the blocks were built: stores −2.4 %, steering −0.2 %, the rest less. At × 0.94 that is 6.305, against gate S1-B's 6.3; and 0.94 is today's core's ratio. The goal itself, above 6.0, needs × 0.895. Step 1.2's "model ≥ 6.8" is not met, and that figure is the author's to change.
- **A lever for the model, unmeasured.** Queues of 10: about +0.5 %, at loop 1's cost.

**My recommendation: go, with the configuration of 28.13 to 28.19 frozen; step 1.2's figure at 6.7; gate S1-B's 6.3 kept as a working target, knowing that the goal is above 6.0.** The fallback to 90 MHz stays open without a change of pipeline (567 CoreMark/s), and it can be decided at step 1.6 with a whole core to measure. And the next piece of work should be the largest unknown: `OOC_FE`.

### 28.21 The largest unknown: `OOO_FDEC`, `OOC_FE2`, F3 and F4 of 32-byte fetch; the override is a stage later (2026-11-05)

The author held gate S1-A for this: today's `OOC_FE` is −4.79 ns at 10 ns, the worst of all, and none of the six loops. Not measured when written: `synth_ooo.bat fe2`, in `output/OOC_FE2_T9`, at 9 ns.

**What building it showed first: the override cannot be in F3.** The proposal had F3 do predecode, TAGE's decision and the override, and `override_at=3`. With 16 parcels: the boundaries are about 6 levels, a parcel's kind 1 more, the count of branches 3, the prediction 2, the first taken 3, the choice 2, into F0 1: about 18 levels, and the 16 targets beside them. Today's has 8 parcels, the same chain, and is the path at −4.79. So 2 stages:

| Stage | What | Why |
|---|---|---|
| F3 | Boundaries, kinds, 16 targets, **each target compared with where fetch went on**, which branch of the block | All from F2's registers, none of it waits for a decision |
| F4 | A branch's prediction from its own parcel's base counter and its slot's hit; the first taken; whether fetch was right, from the compares already made; the next address | About 8 levels, and F0's last LUT has room: `in` was +4.2 ns (28.12) |
| The buffer | `in_st` runs on past the taken transfer, `in_first` comes late and only cuts the count | `OOO_FBUF2`'s table does not wait for the choice. A rare class past the transfer slows the block, nothing else |
| The stack | Read in F4, moved at F4's end, the call's address without an adder | Today's worst path was this push |

So the override leaves in F4, and the model's `override_at` is 4 on the same reckoning as today's 2 (F2, then F0 again a cycle on).

| Override | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| `override_at` 3: the proposal | 6.707 | 7.226 | 6.460 | 5.755 |
| **`override_at` 4: from F4, in F4: as built** | **6.656** | **7.182** | **6.415** | **5.733** |
| `override_at` 5: F4's decision in a register, if F4 does not fit | 6.574 | 7.114 | 6.352 | 5.693 |

**The model is 6.656, −0.8 %. RTL at × 0.94 about 6.26, 626 CoreMark/s: under gate S1-B's 6.3 by 0.04, above the goal of 6.0.** If F4 does not fit, 6.574 and 6.18.

**What the run measures, and does not.** `OOC_FE2` joins `OOO_FDEC`, `OOO_UBTB2`, `OOO_RAS` and `OOO_FBUF2`: the override into F0, the cut into the table, the training into the uBTB. From registers: the data of F2, TAGE's and the BTB's results. **Not there**: the arrays and tag compares of F1 and F2, the I$ (mmRISC-2's, to repipeline: step 1.7), TAGE M itself and its update, the FTQ, the requests in flight and the credit (`OOO_FETCH`'s `qpc`, which `f3_expect` stands for). So it answers for today's worst path, not for all of `OOC_FE`.

**Verification.** `tb_fdec`: 600,000 cycles against a walk of each block written apart: 352,823 blocks, 290,292 taken, 194,335 overrides, 74,065 first halves, 17,211 finished in the next block, 71,827 returns, 148,965 slot predictions, 2,375 flushes, no mismatch. `tb_fbuf2` with the late cut: no mismatch. Bug injection: `fdec` M820 to M849 **30 of 30**; `fbuf2` with M812 to M815 new **35 of 35**; every line read. M828, M840, M841 got through at first: fetch's guess was never near the right place, nor a place another choice would have gone to; the bench now does that. -Wall clean on the blocks and the harness.

What to read: `ovr`, `f3`, `cut`, `ras`, `ubup`, `tab`, `loop`, `slot`, `dloop`, and the total. Levers if short: `cnt` into F4; F4's decision in a register (6.574).

### 28.22 `OOC_FE2`: 9.85 ns; 2 changes that cost nothing, to measure again (2026-11-05)

`synth_ooo.bat fe2`, the RTL of 28.21, asked for 9 ns, in `output/OOC_FE2_T9`. **WNS −0.849 ns, about 9.85 ns, 5,095 LUTs (498 LUT RAM).** Today's `OOC_FE` is −4.79 ns at 10 ns, about 14.8 ns, 7,290 LUTs (with decode, which this does not have).

| Class | Slack at 9 ns | Reached | Levels |
|---|---|---|---|
| **`ovr`: F4's choice into F0** | **−0.849** | 9.85 ns | 12 |
| `loop`: F0's own | −0.817 | 9.82 ns | 9 |
| `f3`: the block to F4's registers | −0.726 | 9.73 ns | 19 |
| `cut`: F4's choice into the buffer's table | −0.531 | 9.53 ns | 11 |
| `ras` | −0.378 | 9.38 ns | 8 |
| `ubup` | −0.101 | 9.10 ns | 10 |
| `tab` | +0.381 | 8.62 ns | 8 |
| `slot` | +0.734 | 8.27 ns | 6 |
| `dloop` | +2.992 | 6.01 ns | 2 |

What it says:
- **The worst path of today is gone**, by 5 ns, and the F4 path did fit in a cycle, at 12 levels against about 8 counted: the choice's carry chain (3 CARRY4), `first`, fan-out 55, the compare's AND-OR over 3 LUTs, then F0.
- **`loop` 9.82 is not a change of the loop**: alone it is 8.64 (28.12), with the same logic. It is placed with what pulls on `pc_q` and was not worked on past the worst, so I read it as following `ovr`, which the next run will tell.
- **`f3`'s 19 levels are the boundaries in front of the target compares**: `c_v`, the chain, `hi`, the offset's form, the adder, the compare. The compare needs none of the boundaries, if it can tell the form otherwise.

**2 changes, at no cost in the model's terms:**

| Change | What | Why |
|---|---|---|
| A target's form from the bits alone | 32-bit if the parcel before looks like a branch or a jal; otherwise by the parcel's own bit | The chain leaves the adders and compares. Wrong only for a 16-bit transfer right behind the second half of a 32-bit instruction whose bits 22:16 look like that opcode. It costs a wrong target that the back end finds. **In the 4 CoreMark builds there are 5 such places, and none runs: 0 in 12.7 million instructions** |
| The compare's own `first_s`, and the kinds in F3 | A per-parcel "is right" kept in a register, and a copy of `first` with only this load | By count 2 levels less into `ovr`, and fan-out 55 stays away from it |

Not in the model, as it has no effect on these programs. The block's comment says so.

**Verification.** `tb_fdec`: the walk with the same rule for the form: 352,822 blocks, 194,336 overrides, no mismatch. Bug injection on `fdec`: M820 to M853, **34 of 34**, every line read, with M850 to M853 new. -Wall clean.

Next: `synth_ooo.bat fe2` again. To read: `ovr`, `f3`, `loop`, `cut`, against the table above. **Gate S1-A stays open until then.**

### 28.23 `OOC_FE2`: 9.5 ns; gate S1-A again (2026-11-05)

`synth_ooo.bat fe2`, the RTL of 28.22, asked for 9 ns, in `output/OOC_FE2_T9`: **WNS −0.820 ns, 4,884 LUTs. But the worst path, into the history bits, is not one the design needs in F4.**

| Class | Now | Before (28.22) | Levels now |
|---|---|---|---|
| The history bits (not a class): into `o_ht` | **−0.820** | | 12 |
| **`ovr`** | **−0.518**, 9.52 ns | −0.849 | 13 |
| **`f3`** | **−0.503**, 9.50 ns | −0.726 (19 levels) | 10 |
| `tab` | −0.212, 9.21 ns | +0.381 | 10 |
| `loop` | −0.139, 9.14 ns | −0.817 | 9 |
| `cut` | −0.126, 9.13 ns | −0.531 | 10 |
| `ubup` | +0.144, 8.86 ns | −0.101 | 10 |
| `ras` | +0.291, 8.71 ns | −0.378 | 11 |
| `slot` | +0.725, 8.28 ns | +0.734 | 6 |
| `dloop` | +3.015, 5.99 ns | +2.992 | 2 |

What it says:
- **The 2 changes worked**: `f3` lost 9 levels, its worst now the count of branches. 0.33 ns on `ovr`, and 0.68 on `loop`, which did follow it (28.22). 211 LUTs fewer.
- **The history bits move a cycle on** (`f5_hn`, `f5_ht`, from registers): they have no one waiting. Done, with the bench; **no new run**: nothing else depends on them, and the next worst are in this table.
- **`tb_fdec` passes with them there; bug injection on `fdec` 34 of 34**, every line read (bc7940a went in before M843 and M844 had run: my edit had given 2 mutations one id. Corrected in the next commit and both detected).
- **So F0 to D1 is about 9.5 ns alone, against about 14.8 ns.** Not in it: the arrays, the I$, TAGE M, the FTQ, the requests in flight.

A history lag noted: the tables are read at F1 and the history pushed at F5, so a block reads with more blocks missing than today's 2. For the block TAGE-S at `slots=3`: 4,772 mispredictions at lag 2, 4,757 at lag 4 on `-O2`; 4,969 and 5,264 on g13. Under 6 %, of about 1 in 1,000 instructions. Not in the model, whose TAGE M is also not the block's: `OOO_TAGE` is S, and M has yet to be built.

**Gate S1-A, as it stands now.**

| What | Alone | With about 1 ns for the core |
|---|---|---|
| F0 to D1 (`OOC_FE2`) | 9.5 ns | 10.5 |
| Loop 2 (`OOC_EXU`) | 9.2 ns | 10.2 |
| Loop 4 (`OOC_RENAME2`) | 9.1 ns | 10.1 |
| Loop 1 (`OOC_SCHED`) | 8.9 ns | 9.9 |
| Loop 3 (`OOC_LSU2`) | 8.1 ns | 9.1 |

Model 6.656 / 7.182 / 6.415 / 5.733, RTL about 6.26.

| Whole core at | CoreMark/s at 6.26 | Against the 50 MHz design (337) |
|---|---|---|
| 100 MHz | 626 | 1.9 times |
| 95 MHz | 595 | 1.8 |
| 90 MHz | 563 | 1.7 |
| 75 MHz | 470 | 1.4 |

**What I recommend: go.** 100 MHz is not secured: the sums above say about 95 MHz, and the goal of 600 CoreMark/s then needs 6.3 or the levers that are left. But the configuration beats the 50 MHz design at any clock above about 54 MHz, and nothing found so far argues for another one. With it:
- **Freeze** the configuration of 28.13 to 28.23.
- **Step 1.2's** "model ≥ 6.8" to **≥ 6.6**.
- **Gate S1-B's** "RTL ≥ 6.3" to **≥ 6.2**; the goal stays above 6.0.
- **Levers left**, each measured: queues of 10 (+0.5 %), F4 into a register if it does not close (−1.2 %), rename in 3 stages (−0.4 %), a lower clock with no change of pipeline.

These figures are the author's to set.

### 28.24 Gate S1-A: go, configuration frozen, 100 MHz kept (2026-11-05)

**The author's decision on 28.23: go, as proposed; 100 MHz stays the target as far as it can.**

| What | Decided |
|---|---|
| Configuration | **Frozen**, as of 28.13 to 28.23: `Doc/STRATEGY.md` 4.2, 4.3 |
| Clock | **100 MHz stays the target.** The sums of 28.23 say about 95 MHz; a lower clock is not a plan, only the last of the levers |
| Goal | `-O2` above 6.0 CoreMark/MHz, above 600 CoreMark/s, unchanged |
| Step 1.2 | "Model ≥ 6.8" is now **≥ 6.6**: met, at 6.656 |
| Gate S1-B | "RTL ≥ 6.3" is now **≥ 6.2** |

What follows from keeping 100 MHz: a lever that costs CoreMark/MHz is taken only when a measurement of the whole shows it is needed, and the first such measurement should come early. So step 1.6's `OOO_CPU` out of context runs from the first step of the new pipeline: what the core really adds over the blocks alone (about 1 ns, measured once, on another design at 50 MHz) is the largest number here that nobody has measured.

### 28.25 Step 1.3, the first stage: RR1, select to EX in 3 cycles; `OOO_CPU` at 10 ns (2026-11-05)

Step 1.3 moves today's 2-wide core to the new pipeline, width unchanged, a stage at a time, with the tests passing after each: Plan:

| # | What | From, to | Status |
|---|---|---|---|
| A | RR1: select to EX 3 cycles | `iss_to_ex` 2, 3 | **Done here** |
| B | Load-use 3: E, M1, M2, on today's D$ | `lat_load` 2, 3 | Next |
| C | Multiply 4 cycles | `lat_mul` 2, 4 | |
| D | Decode and rename 5 stages: D1, D2, D3, R1, R2 | `dec_depth` 3, 5 | |
| E | Fetch 5 stages: override at F4 | `fe_depth`, `override_at` | |
| F | The redirect 6 after EX | `redirect` 3, 6 | |

**A.** A stage on all 3 ports between IS and RR (`OOO_CORE`: `g_r1`, the record kept in `rr_rq`); nothing else moves, as every µop waits one more and their distances stay. Bypass and register file as they are.

| `g14 -O2`, cycles | Before | After | |
|---|---|---|---|
| RTL | 1,817,188 | 1,857,214 | +2.20 % |
| Model, today's options, `iss_to_ex` 2, 3 | 1,722,666 | 1,756,596 | +1.97 % |
| RTL / model | 0.948 | 0.946 | |

So the model holds on this step. Lock-step with Spike: all of `run_core.sh` (60, 96, 186, 127 programs on both tops) and CoreMark on all 4 configurations, 3 builds each: 0 failures, first time. Bug injection of the core (`mutate_core.py`) is left for the end of step 1.3: nothing new to be wrong yet.

**`synth_ooo.bat cpu10`: new.** The whole of today's core with its D$, at a 10 ns target, `output/OOO_CPU_T10`. It is what 28.24 asked for: **against each block's own `T10` of 28.1, what does the core add at this target?** That has been a single figure, measured at 20 ns. The core is today's, and it will miss by a lot; it is the difference per block that is wanted.

### 28.26 `OOO_CPU` at 10 ns: 18.8 ns, and it is the joins (2026-11-05)

`synth_ooo.bat cpu10`, today's core with step 1.3 A, asked for 10 ns, in `output/OOO_CPU_T10`. **WNS −8.824 ns, about 18.8 ns, 37,240 LUTs, 23 levels.** Not a surprise for this core, but **the question of 28.24 does not get the answer it asked for**.

**What limits it is no block but the paths between them**, 23 to 35 levels through 3 or 4 blocks, each of them fitting 50 MHz by design:

| Worst | Levels | Path |
|---|---|---|
| −8.82 | 23 | The ROB head's exception → the commit's decision → `flush`, `rob_restore` → OOO_CTRL's go → dispatch valid → the tval's read → OOO_TRAP |
| −7.91 | 35 | A result in WB → bypass → ALU → the misprediction → the ROB's done bit |
| −7.80 | 35 | EX → ALU → the misprediction → the ROB's done bit |
| −7.69 | 25 | `rob_insn` → OOO_CSRU |
| −7.65 | 35 | The LSU's bypass and address → the ROB's done bit |
| −7.60 | 34 | ALU1's EX to the other ports' stages, the queue, OOO_CTRL, OOO_MDUP |
| −6.17 | 16 | The fetch buffer's loop, as itself: −3.31 alone |
| −6.02 | 15 | Fetch's own: `OOC_FE` −4.79 alone |

What it says:
- **The "about 1 ns the core adds" is still not measured.** The only same path in both is the buffer's loop, 2.86 ns worse here, and fetch, 1.2. But Vivado does not work on paths behind one 2 to 3 ns worse, so those are upper bounds, and they say little for a design with these joins cut.
- **The six loops were never the whole.** These joins are not in them. None is a limit of principle: each is a decision made in the same cycle as something it could follow by a cycle. But they have to be cut, and that is new work, not in step 1.3's plan.

**What cutting them costs in the model** (`cmp_lag`, as built):

| | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| As built | 6.656 | 7.182 | 6.415 | 5.733 |
| Every result's done bit a cycle later | 6.624 | 7.156 | 6.384 | 5.710 |
| 2 cycles later | 6.577 | 7.111 | 6.339 | 5.661 |
| The redirect a cycle later | 6.643 | 7.166 | 6.403 | 5.724 |
| Both a cycle later | 6.610 | 7.141 | 6.372 | 5.701 |

Only a branch's done bit needs the misprediction: the others come from registers. So **the proposal is: a branch completes with the registered resolution, everything else as now**, costing less than the −0.5 % of the second row, to be measured; a trap's flush from a register, which costs nothing in CoreMark. So:

| # | Cut | Expected |
|---|---|---|
| A2a | The ROB head's exception, through a register, before `flush` | The −8.82 path goes; traps a cycle later |
| A2b | A branch's completion from the registered resolution | The −7.9 family goes |
| A2c | The LSU's completion from a register | −7.65 goes (OOO_LSU2 has it so) |
| A2d | `rob_insn` read a stage before the CSR | −7.69 goes |

Then `cpu10` again: **each cut shows the next**, and only then will the whole say what the core adds.

---

## 29. 100 MHz given up: 50 MHz, CoreMark/MHz first (2026-11-05)

**The author's decision** (`Doc/PROMPT.md` 163, 164): 100 MHz is not aimed at on this device; CoreMark/MHz comes first; the CPU at 50 MHz, LiteX at 100 MHz. The plan is `Doc/STRATEGY.md`; the one it replaces is kept as `Plan/STRATEGY_100MHz.md`. Sections 28.1 to 28.26 stand as measurements: they are what the fallbacks of `Doc/STRATEGY.md` 4.5 rest on.

**The model** (`Plan/model/g50.sh`, `results/g50.txt`): 4 renamed, 6 decoded, 32-byte fetch, 4 ALUs + 2 LSUs, 6 issues, unified queue of 24, ROB 48, LQ / SQ 16, 12 checkpoints, TAGE M, uBTB 96, today's depth: **8.677, `-O2`; 9.480 maximum optimization; 8.300 g13; 7.401 rv64gc**.

**A correction to what I told the author before the decision.** That comparison used stores split in 2 µops with no replays, the same assumption that had to be taken back in 28.13: it gave 8.90 at 50 MHz. A late store's data does replay a load: **split with replays 7.947, −8.4 %; one µop with its data, as today, 8.677**. So stores stay as they are. It also made other rows too high:

| | Told before | With one-µop stores |
|---|---|---|
| 33.3 MHz, load-use 1 | 9.74 | 9.66 |
| 50 MHz | 8.90 | **8.68** |
| 66.7 MHz, load-use 2 | 8.63 | 8.21: this row now also delays the override with the added fetch stage |
| 66.7 MHz, load-use 3 | 7.83 | 7.27 |
| 100 MHz | 7.39 | 7.00 |
| 4 ALUs + 1 LSU | 8.49 | 7.98 |
| 3 ALUs + 2 LSUs | 8.63 | 8.37 |

The order of the clocks and the choice of 50 MHz do not change.

**Rows that did not end.** With 4 distributed queues, `steer=3` (`OOO_SDISP`'s steering) and 2 LSU ports the model did not finish in 150 s, so those rows are not in `results/g50.txt`. A store's data µop on an ALU queue (`sd_alu`) without distributed queues did not end either. Neither is the chosen configuration; the cause was not looked into. If the fallback of loop 1 is taken, the model has to be looked at first.

**RR1 taken out** (28.25): `OOO_CORE.sv` is as it was before 467a817. CoreMark `-O2` on `OOO_CORE` with no misses: **1,817,188 cycles**, as before RR1 (1,857,214 with it); `run_core.sh` 0 failures in all its runs, `run_coremark.sh` PASS.

**The 4 cuts of 28.26 are not made**: at 20 ns they are not asked for yet.

**Next**: step 1.1, the six loops of `Doc/STRATEGY.md` 4.5 at a 20 ns target, the unified queue of 24 with 6 selects first.

### 29.1 Loop 1: `OOO_IQ2`, `OOC_IQ2`, the queue of 24 with 6 selects (2026-11-05)

**The block.** `RTL/CPU/OOO/OOO_IQ2`: unified, 24 entries, 4 µops in, 6 ports, tag compare as in `OOO_IQ`: the straightforward design first, to be measured before anything cleverer. Ports 3, 2, 1, then 0 from what is left; 5, then 4 from what is left. So the longest path is a chain of 4 selects, then a tag's AND-OR, then 9 compares.

**What it asks of the model, which treated every port as able to take anything** (new options `st_lsu0`, `p0_ops`, `p0_opx`, `iq_bank`; `results/g50.txt`):

| Limit | -O2 | max | g13 | rv64gc |
|---|---|---|---|---|
| None | 8.677 | 9.480 | 8.300 | 7.401 |
| A store only on LSU 0 (so port 5 reads one source: 11 reads, not 12) | 8.669 | 9.472 | 8.295 | 7.401 |
| Multiply, divide, system only on ALU 0 | 8.664 | 9.480 | 8.288 | 7.415 |
| ... and the slow operations | 8.664 | 9.480 | 8.288 | 7.415 |
| ... a multiply takes port 1's write slot (6 writes, not 7) | 8.652 | 9.456 | 8.277 | 7.397 |
| 4 banks of 6 | 8.667 | 9.476 | 8.293 | 7.397 |
| **All: as built** | **8.633** | **9.445** | **8.265** | **7.391** |

All together −0.5 %. The gain of "only on ALU 0" on rv64gc is the model's: with no limit a divide stopped all 4 ALUs, with it only the MDU.

**Simplifications from the 50 MHz budget and from 4 writes:**
- The free entries: the first of each bank, not a search of 24 for 4.
- The age row of a new entry: all ones but for what is written after it, as an empty entry requests nothing. So the row does not depend on the select.

**The bench.** `tb_iq2`: an account of when every value can be used, kept apart from the queue's bits, as `tb_iq`; 400,000 cycles, 532,542 µops, 2,734 cycles with all 6 ports, the queue full in 95,133 cycles, the banks short in 136,842, 0 mismatches. **Mutations M860 to M898: 39 of 39 detected.**

**The harness.** `OOC_IQ2`, `report_iq2.tcl`, `synth_ooo.bat iq2`, **at 15 ns**, not 20: Vivado stops when a target is met, and what is wanted is the margin for the joins. No payload yet (`OOO_IQPL` with 4 writes and 6 reads comes after this loop). Lint clean on its lines with `-Wall`.

**What the result will decide:**

| `loop` reaches | Reading |
|---|---|
| About 15 ns or less | Room for the joins: unified 24 stays |
| 15 to 18 ns | Unified 24 possible: then look at the paths before deciding |
| Above 18 ns | No margin: first a dependency matrix or a chain of fewer selects, then `OOO_SCHED` (−2.4 %) |

These limits are my judgement, before any measurement.

### 29.2 `OOC_IQ2` about 21.1 ns: the chain of selects; selected by rank instead (2026-11-05)

**Measured** (`synth_ooo.bat iq2`, asked for 15 ns): **WNS −6.138 ns, about 21.1 ns; 9,968 LUTs (no LUT RAM), 2,211 FF, without the payload.** 19 levels, 86 % routes. Over the 18 ns of 29.1, and over 20 ns alone.

| Class | Slack at 15 ns | Levels | Reached |
|---|---|---|---|
| `guard` | −6.138 | 19 | 21.1 ns |
| `loop` | −6.097 | 19 | 21.1 ns |
| `free` | −5.776 | 19 | 20.8 ns |
| `age` | −5.657 | 18 | 20.7 ns |
| `wait` | −5.444 | 19 | 20.4 ns |
| `issue` | −3.480 | 16 | 18.5 ns |
| `leave` | −3.295 | 14 | 18.3 ns |
| `wk` | −2.836 | 15 | 17.8 ns |
| `delay` | −1.606 | 14 | 16.6 ns |
| `kill` | +2.640 | 4 | 12.4 ns |
| `slot` | +2.696 | 3 | 12.3 ns |
| `ready` | +6.703 | 3 | 8.3 ns |

**The worst `loop` path, by what it does:**

| Part | ns | |
|---|---|---|
| Ready bit, first select (port 3) | 5.9 | Clock to Q too |
| Second select (port 2) | 5.4 | Nets of 24 to 65 fan-out between them |
| Third select | 4.1 | |
| **The chain of selects** | **15.4** | **73 %** |
| The tag's AND-OR | 2.5 | Its net: fan-out 88 |
| Compare, ready bit | 3.2 | |

So it is the chain, not the tags. A dependency matrix would take off at most part of the last 5.7 ns; the chain takes 15.4.

**The change: selected by rank, no chain.** Every any-ALU µop counts the ready any-ALU µops older than it, saturating at 4, in a tree of 4 LUT levels. Rank 0 goes to port 3, 1 to port 2, 2 to port 1, 3 to port 0. No port's grant depends on another's. Port 0 also takes the oldest ALU0-only µop when at most 3 any-ALU µops are older than it. Ports 5 and 4 stay a chain of 2: a load's wakeup comes a cycle later, off the loop.

The price: a µop that a write slot holds back keeps its rank, so its port idles that cycle where the chain would have given it to a younger µop. That happens only in the cycle after a multiply or with `p0_hold`, and only with 3 or 4 any-ALU µops ready. It is not in the model; I expect it below what the model can show, but that is not measured.

**The LUTs.** 9,968 against the 9k I estimated with the payload: the queue is over its share. Where it can be seen: each entry had a 4-to-1 mux on about 44 bits for the slot that writes it. Since a bank has one entry written a cycle, **the mux is now per bank, on one bus**: 4 of them, not 24. The count of 24 per entry adds some of it back.

**Also removed:** `!flush` when a bank is written. The campaign left it undetected (M889 of the first set), and it is redundant: flush wins at the valid bit, and an empty entry's fields do not count. The bench now also dispatches in a flush.

**A mistake of mine in the campaign's filter:** `grep -v " DETECTED "` also hides `NOT DETECTED`, so one run showed only "47 of 48". I ran it again keeping every line to see which. (The first set's 39 of 39 is not affected: the total says so.)

**The bench and mutations**: `tb_iq2` 0 mismatches, with port 0's rule above as the reference. M860 to M908 on the final RTL: 49 of 49 detected, every line read before this commit. The first run is kept as `output/OOC_IQ2_T15_chain`.

**Next**: `synth_ooo.bat iq2` again, the same 15 ns. My estimate is 13 to 15 ns: select about 7, then 5.7 for the tags. Not measured.

### 29.3 `OOC_IQ2` about 15.6 ns, 8,888 LUTs: selected by rank (2026-11-05)

**Measured** (`synth_ooo.bat iq2`, asked for 15 ns): **WNS −0.619 ns, about 15.6 ns; 8,888 LUTs, 2,212 FF, without the payload.** 13 levels, 86 % routes. −5.5 ns and −1,080 LUTs against the chain (29.2).

| Class | Slack at 15 ns, chain | Now | Levels | Reached |
|---|---|---|---|---|
| `loop` | −6.097 | **−0.619** | 13 | 15.6 ns |
| `guard` | −6.138 | −0.610 | 13 | 15.6 ns |
| `wait` | −5.444 | −0.508 | 14 | 15.5 ns |
| `free` | −5.776 | −0.153 | 13 | 15.2 ns |
| `age` | −5.657 | +0.136 | 12 | 14.9 ns |
| `issue` | −3.480 | +0.141 | 14 | 14.9 ns |
| `wk` | −2.836 | +2.658 | 10 | 12.3 ns |
| `leave` | −3.295 | +2.804 | 11 | 12.2 ns |
| `delay` | −1.606 | +3.968 | 8 | 11.0 ns |
| `slot` | +2.696 | +4.580 | 5 | 10.4 ns |
| `kill` | +2.640 | +6.725 | 5 | 8.3 ns |
| `ready` | +6.703 | +8.052 | 3 | 7.0 ns |

**The worst path now:** clock to Q and ready 2.6 (from the clock's edge at 0.97), the rank and its grant to the issued tag 8.8, the tag's fan-out of 57 1.7, compare 3.4: 15.6 in all. My estimate was 13 to 15 ns; it is a little above.

**Reading (the table of 29.1): 15 to 18 ns, "possible", at its lower edge. Unified 24 stays.** There are about 4.4 ns against the 20 ns for what the core adds. How much that is, is the question at the joins: the whole core added 2.86 and 1.2 ns where it could be compared (28.26), and those are upper bounds. Vivado stopped near its target here, so the block's limit may be lower; a run at a harder target would tell, and is not needed until the joins ask.

**The price not measured**: the idle port of 29.2 is not in the model.

**The LUTs: the budget moves.** The queue 8.9k without its payload; the payload, in 4 banks with 6 reads, estimated at 2.1k (not built). So 11k against the 9k taken, and the whole chip about 111k, 82 %, over the ceiling of 80 %, with only this part measured. **What is left to decide it is mostly the register file and the ALU ports**, loop 2, next.

The first run stays as `output/OOC_IQ2_T15_chain`.

**Next**: loop 2, the register file of 6 writes and 11 reads with bypass and 4 ALUs. It decides the most LUTs still unknown.
