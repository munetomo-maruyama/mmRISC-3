# Options to reduce the logic

- Date: 2026-10-24
- Status: following the author's decisions (2026-10-24, `Doc/PROMPT.md` entry 11), Ethernet stays and the FPU starts
  pipelined, and these are the options that free LUTs. Every option concerns a block reused from mmRISC-2 or one built
  for mmRISC-3.
- Working files: `Plan/reduce/` (`synth.sh`, `sweep.sh`, `results/sweep.txt`)

---

## 0. Summary

1. **The options with no effect on CoreMark or on Linux performance are expected to free about 3.5k to 5k LUTs and 7k
   to 8k FFs** (A1 to A5 in 1.1). Two triggers (A1) and four PMP entries (A2) are parameter changes only, about 1.3k
   LUTs together (measured); the other three change how tables are built (FFs → LUTRAM) and are estimates.
2. With them, even with the pipelined FPU kept, the LUTs left for the out-of-order engine go from about 12.9k
   (`ISSUES.md` section 2) to **about 16k to 18k**, close to NaxRiscv RV64's integer core (about 18k).
3. If still short, use the options that trade Linux features or performance (group B), then the FPU options (group C,
   reconsidered at G0 per the author's decision).
4. Measured with Yosys (Vivado is only on the author's machine): only differences are used, converted by the ratio to
   Vivado. CSR differences vary by about ±0.2k from one synthesis to another, so they are given as ranges.

---

## 1. The options

LUTs and FFs are converted to Vivado terms. "Measured" means converted from Yosys differences; "estimate" means
estimated from the structure.

### 1.1 Group A: no effect on CoreMark or on Linux performance (recommended from G0)

| # | Option | LUT | FF | Basis | Effect / caution |
|---|---|---|---|---|---|
| A1 | **Sdtrig triggers 4 → 2** | about 0.3k (0.1 to 0.55k) | 0.15k | Measured (CORE_CSR) | Up to 2 gdb hardware breakpoints / watchpoints at once; enough for development |
| A2 | **PMP 8 → 4 entries** | about 0.95k | 0.45k | Measured (CSR 0.24k + MMU comparators 0.72k) | Check in SIM_BIOS how many entries OpenSBI v1.9 uses (a few, for protecting the firmware and allowing the rest) |
| A3 | **D$ line buffers from FFs to LUTRAM** (fill, write-back, store data per MSHR; 512 bits each) | 0.8 to 1.5k | about 3k | Estimate | Written and read one word at a time, which suits LUTRAM. The same idea as mmRISC-2's BTB moving from FFs to LUTRAM (−3,060 LUTs / −7,936 FFs). Done when the D$ gets its out-of-order adapter anyway |
| A4 | **TLBs as set-associative LUTRAM** (same capacity, ITLB 16 / DTLB 32) | about 1k | 3 to 4k | Estimate (today fully associative in FFs; the MMU has 4.6k FFs) | Hit rate changes slightly. Alternative: a small L1 TLB (FFs) + a large L2 TLB (LUTRAM / block RAM), the second-level TLB of mmRISC-2's ROADMAP, which is even better for Linux |
| A5 | **Rarely written 64-bit CSRs in LUTRAM** (mscratch, mepc, mtval, sscratch, sepc, stval, dpc, dscratch and so on) | 0.5 to 1k | about 0.6k | Estimate (smaller CSR read multiplexer) | LUTRAM has one write port: a trap writing mepc / mcause / mtval at once is split over a few cycles. Out-of-order runs CSR instructions and traps serially at the ROB head, so performance is not affected |
| | **Total of group A** | **about 3.5 to 5k** | **about 7 to 8k** | | Far fewer FFs also relieve slice congestion (93 % in mmRISC-2) |

### 1.2 Group B: trades Linux features or performance (no effect on CoreMark)

| # | Option | LUT | FF | Basis | What is lost |
|---|---|---|---|---|---|
| B1 | HPM counters 4 → 2 | about 0.65k (0.4 to 0.9k) | 0.15k | Measured | `perf` counts 2 events at once; measurements take twice the runs (mmRISC-2's `perf.sh` / `workload.sh`) |
| B2 | Remove Zbc (clmul) | 0.3 to 0.6k | small | Estimate | Linux's crc32 gets slower. CoreMark's `-march` (Zba / Zbb / Zbs / Zicond) does not include it, so no effect on CoreMark |
| B3 | TLBs 16 / 32 → 8 / 16 entries | about 1.2k | about 2.2k | Measured | Back to mmRISC-2 Rev.01's size; user-mode loads 11 to 20 % slower (BENCH.md section 26). Not needed if A4 is taken |
| B4 | No PMP (0 entries) | about 1.9k | 0.9k | Measured | No M-mode protection; OpenSBI booting without PMP needs checking |
| B5 | No HPM counters (no Sscofpmf) | about 1.2k | 0.33k | Measured | Linux `perf` is lost. It was the basis of the performance work in mmRISC-2, so not recommended |

### 1.3 Group C: the FPU (author's decision: pipelined at first, reconsidered at G0 depending on the logic size)

| # | Option | LUT | Basis | Content |
|---|---|---|---|---|
| C1 | **Get the FPU's breakdown** | — | — | Split FPU_PIPE (8.8k in Vivado) into multiply, add, alignment, normalization, rounding, conversion and iterative divide by OOC synthesis. The rounder (FPU_ROUND) is about 23 % (measured, about 2.1k in Vivado terms). The basis for C2 onwards |
| C2 | Share the multiplier between MDU and FPU | 0.5 to 1k (+ 16 DSPs) | Estimate | Out-of-order can put MUL / DIV and the FPU on the same issue port; the sums of partial products of the 64 × 64 integer and 53 × 53 significand multiplies become one. Multiply throughput drops (CoreMark has 30 multiplies per 1000 instructions; checked in the model) |
| C3 | Keep only FMA pipelined; conversions, compares, sign operations and so on in a separate small iterative unit | Depends on C1 | — | FMA / add / multiply still accepted every cycle (the ones that matter for performance); less logic for the rare operations |
| C4 | Multi-cycle FPU (the original recommendation) | several k | Estimate | The last resort; floating-point performance drops a lot; no effect on CoreMark. **G0: mmRISC-2's multi-cycle FPU was 9,757 LUTs against 9,060 for FPU_PIPE; only a new narrow design would be smaller (`Doc/UARCH.md` section 5)** |

### 1.4 Group D: SoC side

| # | Option | LUT | Content |
|---|---|---|---|
| D1 | Remove unneeded LiteX peripherals | 0.2 to 0.5k (estimate) | LiteX is 4.8k in total: LEDs, buttons, identifier, unused timers and so on. List what LiteX options can remove, and check in the author's Vivado |
| D2 | Fewer PLIC sources | small | The PLIC is 0.46k in Vivado. In Yosys 31 → 8 sources did not reduce it and the results were inconsistent, so it is not counted |
| D3 | Ethernet | — | Kept, by the author's decision |
| D4 | Remove the L2 | 1.26k + 68 BRAM | Not recommended: Linux loads 1.2 to 1.7 times slower (measured in mmRISC-2) |

### 1.5 Group E: how mmRISC-3 itself is built

Not reductions but principles for building the out-of-order parts small.

| # | Principle | Content |
|---|---|---|
| E1 | No large tables in FFs | RAT, PRF (write banks + LVT), ROB payload, FTQ, issue-queue payload in LUTRAM; predictors in block RAM; no FF CAMs |
| E2 | Decoders are cheap | mmRISC-2's CORE_DEC is 278 LUTs and CORE_DECOMP 78. 4-wide decode for fusion is expected to add about 0.7k, a small price for +15 % |
| E3 | Asymmetric ALUs | ALU0 everything (Zba / Zbb / Zbs / Zicond, branches), ALU1 add / subtract, logic, compare and branches only. mmRISC-2's CORE_EXU is 1.67k |
| E4 | Simpler FPU control | The hold / kill control in mmRISC-2's FPU_PIPE, which stops and cancels it with the core's pipeline, is replaced by flushing by ROB tag |

---

## 2. Outlook

| Stage | LUTs for the out-of-order engine | Content |
|---|---|---|
| Estimate so far (`ISSUES.md` section 2) | about 12.9k | Pipelined FPU, mmRISC-2's blocks reused as they are |
| + group A | **about 16 to 18k** | No feature or performance lost |
| + B1, B2 | about 17 to 19k | Trades the number of simultaneous perf counts and Linux's crc32 |
| + group C (decided at G0) | several k more | Depends on the FPU breakdown |

NaxRiscv RV64's integer core is about 18k (no FPU, with CSR and MMU). Whether mmRISC-3's out-of-order engine (front
end, renaming, ROB, issue queues, ALUs, LSU) fits in 16 to 18k is checked by adding up OOC syntheses before G0
(`ISSUES.md` 3.4 and step 3 of section 5).

---

## 3. Method and limits

- `Plan/reduce/synth.sh`: copies mmRISC-2's RTL, rewrites the defaults of the target module's parameters, converts
  with sv2v and synthesizes the module alone with Yosys (0.56, `synth_xilinx -family xc7 -flatten`). Changing them
  with `chparam` after sv2v can contradict widths sv2v derived, so they are rewritten before the conversion.
- `Plan/reduce/sweep.sh`: every measured condition of section 1 (`results/sweep.txt`).
- **Conversion to Vivado**: the differences are multiplied by the ratio of Vivado (mmRISC-2's post-placement report by
  hierarchy) to Yosys at the default parameters: 1.43 for CORE_CSR, 0.53 for CORE_MMU, 0.79 for FPU_PIPE, 0.67 for
  DCACHE. Optimization across module boundaries makes the ratio differ a lot between modules.
- **Variation**: CORE_CSR's LUTs went from 3,214 to 3,450 for the same parameters depending on how it was converted
  (Yosys's ABC mapping is sensitive to small structural differences), so CSR differences are the mean of two runs with
  a range. FF differences agreed every time; the MMU results were stable.
- **Vivado decides**: the options taken are confirmed by the author's Vivado OOC synthesis once mmRISC-3's RTL exists.
