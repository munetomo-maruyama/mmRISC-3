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
6. Next: out-of-context synthesis in the author's Vivado (section 6), to fix the timing of the two-stage ALU, the size
   of the issue queue, and the LUTs and timing of each register-file port configuration.

---

## 2. The blocks

| Block | What it is | Main parameters |
|---|---|---|
| `OOO_ALU` | Integer ALU: RV64I + Zba / Zbb / Zbs / Zicond (operations and encoding of mmRISC-2's CORE_EXU) | — |
| `OOO_ALU2` | An issue port's ALU: two OOO_ALU in series (a fused ALU + ALU in one cycle) + the branch comparison (alone, or against the first result for ALU + branch) | — |
| `OOO_FUSE` | 4 decoded instructions → the next 2 µops (paired greedily from the oldest) | `LEVEL` (1 to 3) |
| `OOO_IQ` | Unified issue queue: 3 sources, 2 in / 3 out, 1-cycle wakeup-select, age matrix, latency-2 and external wakeups | `N`=16, `TAGW`=7 |
| `OOO_RENAME` | 2 µops per cycle, 3 sources and 2 destinations, RAT, free list, busy bits, in-group dependences, checkpoints | `NREG`=96, `NCKPT`=8 |
| `OOO_PRF` | 96 × 64, LUTRAM per write bank + LVT | `NW`, `NR` |
| `OOO_UBTB` | 32-entry fully associative next-line predictor, next fetch address in one cycle | `NE`=32 |

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

## 7. Next

1. With the author's Vivado results, decide the details of D-4 (2 sources, write ports, operations of the second
   stage) and put the limit into `OOO_FUSE` (counting sources as `fuse_2src` of `Plan/model/ooo.h` does).
2. If the issue queue is too large: read the issued µop with a one-hot AND-OR instead of encoding to a number and
   multiplexing; fewer wakeup tag buses (port 1 never issues latency-2 µops, so it needs no delayed bus; two
   destinations only on the ALU ports); split the queue (ALU 12 + LSU 6 and so on).
3. The G0 specification: freeze the micro-architecture including the scope of this RTL (step 5 of `ISSUES.md`
   section 5).
