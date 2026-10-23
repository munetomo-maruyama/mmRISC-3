# Study memo: a dual-issue / out-of-order RV64GC core on the Arty A7-100T

- Subject: as the successor of mmRISC-2 (single issue / in-order / RV64GC), build a dual-issue / out-of-order RV64GC core
  on the same board and run Linux on it
- Date: 2026-10-13
- Status: the problems listed with counters and compromises (most numbers are rough estimates, to be confirmed by
  measurement)
- History: a preliminary study made during the development of mmRISC-2 (at Rev.01). Moved on 2026-10-24 from
  `Doc/mmRISC-OoO_検討メモ.md` to this file (content as it was). For mmRISC-3, `Doc/STRATEGY.md` takes precedence.
  This is the English translation of `PRESTUDY_MMRISC2_J.md`

---

## 0. Summary

1. mmRISC-2 already almost fills the FPGA (LUT 74.0 %, slices 86.2 %). Going out-of-order is therefore not "adding
   logic" but **reallocating resources**: deciding what to cut to make room for out-of-order execution.
2. An out-of-order core made for FPGAs (NaxRiscv, RV64 configuration) is about 18k LUTs for the core alone. That number
   includes neither an FPU nor the Zb extensions.
3. The Arty is speed grade -1. **Keeping 50 MHz** and spending the frequency slack on fewer pipeline stages (= fewer
   LUTs / FFs) is the better deal.
4. What decides whether Linux runs is not the performance parts but **keeping operations with side effects
   non-speculative** (MMIO loads, CSRs, AMOs, the A/D updates of the PTW and so on).
5. The largest fork is **how to handle the FPU** (its own renaming / a physical register file shared by integer and FP
   / a reduced multi-cycle FPU).
6. Expected performance: the ceiling of CoreMark/MHz is about 1.6 times. On the kernel loads of Linux, about 1.2 to
   1.4 times in practice. The value is more in the design assets and as a subject than in the performance itself.
7. How to proceed: **measure NaxRiscv RV64 on the Arty** → **boot Linux on a 1-wide out-of-order core** → go 2-wide
   → speculative loads and multiple MSHRs → stronger FPU and predictor.

---

## 1. Resources today (mmRISC-2 Rev.01)

| Item | Value |
|---|---|
| Frequency | 50 MHz (WNS +0.664 ns) |
| LUT | 46,928 / 63,400 (74.0 %) |
| Slices | 86.2 % |
| BRAM | 108.5 / 135 tiles (with the 256 KB L2) |
| Performance | 2.786 CoreMark/MHz (-O2, Zba / Zbb), 3.025 with optimization, 1.496 DMIPS/MHz |
| Pipeline | 8-stage in-order (IF1 / IF2 / FQ / ID / EX / MR / MA / WB) |
| Caches | L1 I$ / D$ 16 KB each (4 ways, 64 B); the D$ is non-blocking and write-back; L2 256 KB |

### Reading
- The real limit is the **86 % of slices** more than the 74 % of LUTs. With routing congestion in mind, the practical
  ceiling is about 80 to 85 % of LUTs.
- Only **about 5k to 8k LUTs** can be added.
- Block RAM still has room, and shrinking the L2 frees more. The basic strategy is to move logic from LUTs to block
  RAM / LUTRAM / DSPs.

### First thing to do (Phase 0)
Break down today's design with `report_utilization -hierarchical` into the units below. Every discussion of the budget
starts from these numbers.

- Core (front end / EX / LSU / CSR / PMU)
- FPU (FPU_PIPE)
- MMU (TLB / PTW / PMP)
- L1 caches, L2 cache
- Debug (DTM / DM / triggers)
- LiteX (LiteDRAM / LiteEth / SD / UART / CSR bus)

Also check how many DSP48s are used (the unused ones out of 240 can take multipliers and adders).

---

## 2. A sense of scale: NaxRiscv

The closest example of an out-of-order RISC-V for FPGAs, already integrated in LiteX.

| Configuration | CoreMark/MHz | DMIPS/MHz | LUT | FF | BRAM | DSP | Fmax (Artix-7 -3) |
|---|---|---|---|---|---|---|---|
| RV32 2 decode / 3 issue / 2 retire | 5.02 | 2.93 | 13.3k | 10.3k | 12 | 4 | 155 MHz |
| RV32 one ALU (branches moved to the shared pipe) | 4.44 | 2.71 | 12.1k | 9.9k | 12 | 4 | 148 MHz |
| RV32 1 decode / one ALU | 3.35 | 1.70 | 10.8k | 9.7k | 12 | 4 | 155 MHz |
| RV64 (2 × Int + 1 × LSU/MulDiv/CSR) | 4.94 | 2.94 | 17.9k | 12.5k | 12 | 16 | 137 MHz |

Main parameters of the RV32 configuration:
- 64-bit fetch, 2 decode, 3 issue, 2 retire
- A shared issue queue of 32 entries
- 64 physical registers
- LQ / SQ 16 each
- Load-hit prediction (load-to-use 3 cycles)
- I$ / D$ 16 KB / 4 ways
- BTB 512, GSHARE 4 KB, RAS 32

### What this tells
- An out-of-order core made with FPGAs in mind can fit in about 20k LUTs for the core alone.
- But NaxRiscv's numbers are **without an FPU or Zb extensions**. Matching mmRISC-2's ISA (RV64GC + Zba / Zbb / Zbs /
  Zbc / Zicond / Zicboz, Sstc, Sscofpmf, Sdtrig) adds to them accordingly.
- The numbers are for speed grade -3. On the Arty's -1, 137 MHz corresponds to roughly 100 MHz. Aiming at 50 MHz
  leaves frequency slack.
- Lessons from NaxRiscv's development notes:
  - An out-of-order core without branch prediction performs very badly
  - Not making store data wait in the issue queue reduces wrong load speculation
  - Making the ALU 2-cycle latency costs about 15 % of performance
  - Adding execution units quickly gives diminishing returns

---

## 3. What grows with out-of-order execution, and how to keep it down on an FPGA

| Block | What is heavy | Counter on an FPGA |
|---|---|---|
| Physical register file | Many ports (4R2W or more for 2-wide) | **Actually cheap.** RAM64M (1W3R LUTRAM), one bank per write port, selected by an LVT (Live Value Table). Even 64 × 64-bit is a few hundred LUTs. **Most important: do not build it from FFs** |
| Issue queue | Tag-compare CAM of wakeup, and select (priority choice) | Distributed queues (about 8 each for ALU / MEM / FP). Non-collapsing, with age kept by an age matrix. Wakeup by a dependency matrix also suits LUTs |
| Renaming | RAT read ports, dependences within a group, branch recovery | RAT in LUTRAM. Only 2 to 4 checkpoints; when they run out, roll back by walking the ROB. Snapshots for every branch make FFs explode, so avoid them |
| ROB | Entries × information | 24 to 32 entries. The PC is not kept per entry but in an FTQ per fetch block. The payload in LUTRAM or block RAM |
| LSQ | Address CAM of loads / stores, detection of order violations | **First version with conservative memory dependence** (a load is not issued until the addresses of older stores are known). No violation detection or replay in the LQ is needed. Store-to-load forwarding only for the same address and size |
| Bypass network | 64 bits × sources × operands | Keep the number of execution units small |
| Two-instruction fetch with RVC | Finding instruction boundaries, 32-bit instructions across fetch blocks | A fetch buffer in 16-bit parcels, predecode bits in the I$ to move the boundary decision earlier. Unglamorous but laborious |
| Recovery from mispredictions | Larger penalty (over 10 cycles), repairing GHR and RAS | Save the GHR and the RAS top pointer in checkpoints. Strengthen the predictor itself with block RAM |

### Size of the PRF (reference calculation)
- One RAM64M (4 LUTs) holds 64 entries × 3 bits, 3R1W
- 64 bits take 22 RAM64Ms = 88 LUTs (for 3 read ports)
- 4 read ports → 2 sets, about 176 LUTs
- 2 write banks → about 352 LUTs
- With the LVT and the output 2:1 muxes (64 bits × 4 ports), **under 1k LUTs in total**

### Critical timing
- **The wakeup-select loop** (the 1-cycle loop that issues dependent instructions back to back)
  - Likely to fit in one cycle at 50 MHz
  - If it does not close, fall back to a 2-cycle ALU latency (about 15 % of performance)
- Detecting dependences within a rename group (resolving the dependence between 2 instructions by RAT reads and
  bypass)
- Updating the free list when committing 2 per cycle

---

## 4. Non-speculative execution for Linux

What typically breaks Linux on an out-of-order core is not the performance parts but **side effects**. As a rule, the
following wait until they reach the head of the ROB, and flush the pipeline where needed.

| Target | Handling | Note |
|---|---|---|
| **Loads from device regions (MMIO)** | If the PMA says non-cacheable, no speculative issue; execute at the head | Reading the UART / SD / Ethernet registers of LiteX changes their state. Forgetting this gives very hard-to-trace bugs of the "characters of the UART are sometimes lost" kind |
| Stores to MMIO | Issued after commit (stores are executed after commit anyway) | Mind the ordering if posted uncached stores are added |
| All CSR instructions | Executed at the head, younger ones flushed | Rare, almost no effect on performance |
| SFENCE.VMA / FENCE.I / WFI | Executed at the head, flush | FENCE.I also invalidates the I$ and the fetch buffer |
| ECALL / EBREAK / MRET / SRET | Executed at the head, flush | |
| AMO / LR / SC | Executed at the head | The AMO / LR-SC mechanism of the existing D$ can be reused |
| **A/D bit updates by the PTW** | A speculative PTW only reads. If A/D must be updated, wait for the head or raise a page fault (Svade-like) | How far speculative updates are allowed needs checking in the privileged spec |
| Exceptions and interrupts | Taken at commit | Precise exceptions |
| fflags / frm | fflags accumulated at commit; writes of frm serialized as CSRs | |
| Debug halt and single step | Handled at the ROB head; a single step is "commit one instruction and flush" | Most of the existing Debug Spec 1.0 implementation can be reused |
| Triggers (Sdtrig) | Match results carried in the ROB, fired at commit | Must not fire falsely on a speculative path |
| PMU events | Distinguish committed and speculative events | Affects how `perf` is read |
| DMA coherence | The existing path through the D$ as it is | Mind consistency with speculative load values in the LSQ (a conservative LSQ rarely has problems) |

---

## 5. Compromises and cuts (largest effect first)

### A. The FPU (the largest fork)

| Option | Content | Pros | Cons |
|---|---|---|---|
| Option 1: renaming for FP alone | A RAT and PRF for FP (about 48 registers), a small FP issue queue. The existing 9-stage FPU_PIPE as an execution unit | The orthodox way; FP performance kept | RAT, free list and PRF in two sets |
| **Option 2: one PRF for integer and FP** | In RV64D f0-f31 are also 64 bits, so 64 architectural registers are managed by one RAT and one free list | Only one set of renaming logic | The 3 sources of FMA add read ports (the FP side can read from a separate bank) |
| Option 3: reduce to a multi-cycle FPU | Drop the 9-stage FMA pipeline and go back to something like the old CORE_FPU | Large LUT saving; hardly any effect on how Linux feels | FP throughput drops a lot |
| Option 4: FP as an in-order side pipe | The ROB keeps only the order; FP issues in order | Out-of-order cost concentrated on the integer side | Stalls easily on dependences between FP and integer instructions |

FDIV and FSQRT can stay iterative in every option.

### B. Asymmetric execution units
- ALU0: everything (Zba / Zbb / Zbs / Zicond, branches, 64-bit barrel shifter, clz / ctz / cpop)
- ALU1: add / subtract, logic, compare and (if needed) branches only
- MUL / DIV and Zbc (carry-less multiply) share one of the ports
- Multiplication entirely in DSP48s

### C. Moving from LUTs to block RAM / LUTRAM / DSP
- To block RAM: BTB, gshare's PHT, ROB payload, second-level TLB (consistent with the second-level TLB in the ROADMAP)
- To LUTRAM: small fully associative TLBs (with partial compares), RAT, PRF, FTQ
- The misprediction penalty grows over 10 cycles, so strengthening the predictor with block RAM (gshare → small TAGE)
  pays off

### D. Cuts in the SoC, debug and observation

| Target | Cut | Effect |
|---|---|---|
| L2 cache | 256 KB → 128 KB | About 30 block RAM tiles freed (LUTs hardly change) |
| LiteEth | Removed during development; boot from SD only | Several k LUTs |
| PMU | Fewer of the 26 events, fewer counters | The 64-bit counters and event selection add up to a non-negligible amount |
| Debug triggers | 4 → 2 | The comparators |
| PMP | Fewer than 8 entries | The comparators (OpenSBI's behavior to be checked) |
| Zbc | Removed or shared with the MDU | Small to medium |
| LiteX CSR bus | Unneeded peripherals removed | Small |

### E. Keep 50 MHz
- Fewer stages, saving LUTs / FFs, pays more on this board than closing out-of-order timing on speed grade -1.
- The relation with the clock domain of LiteDRAM follows today's configuration.

---

## 6. Recommended baseline (first draft)

| Item | Configuration |
|---|---|
| Fetch | 64 bits per cycle, fetch buffer in 16-bit parcels, predecode bits in the I$ |
| Decode / rename / commit | 2-wide |
| Execution units | ALU0 (full + branches), ALU1 (simple + MUL / DIV), one LSU, one FPU |
| Issue queues | Distributed (ALU 8, MEM 8, FP 8) or shared 16 to 24 |
| PRF | 64 integer (+ 48 FP), or about 96 unified |
| ROB | 24 to 32 entries |
| LSQ | LQ 8 / SQ 8, conservative memory dependence at first |
| Branch recovery | 2 to 4 checkpoints + ROB walk |
| Branch prediction | Reuse the existing BTB / gshare / RAS, TAGE later |
| L1 / L2 / MMU / CSR / debug | Reuse the assets of mmRISC-2 as much as possible |
| D$ | Multiple MSHRs added (miss under miss) |
| Frequency | 50 MHz |

### Rough size estimate (to be measured)

| Block | Estimate (LUT) | Note |
|---|---|---|
| Front end (2-wide, RVC aligner, predictor) | 3k to 4k | |
| Decode × 2 + RVC expansion × 2 | 1.5k to 2k | |
| Renaming (RAT, free list, checkpoints) | 1.5k to 3k | upper end if FP has its own set |
| Issue queues (wakeup / select) | 2k to 4k | |
| ROB | 1k to 2k | |
| PRF + bypass | 1.5k to 2.5k | |
| ALU × 2 (asymmetric) | 2k to 3k | |
| MUL / DIV / Zbc | 1.5k to 2k | |
| LSU + LSQ | 3k to 4k | |
| FPU | existing | measured in Phase 0 |
| CSR / traps / PMU / debug | existing | same |
| MMU | existing | same |

---

## 7. Expected performance

- NaxRiscv RV64's 4.94 CoreMark/MHz is a reference. Against mmRISC-2's 3.025 /MHz with optimization, **about 1.6
  times is the ceiling**.
- Linux kernel loads are largely memory-bound. Hiding the latencies of an L2 hit (14 cycles) and an L2 miss (31
  cycles), both after an L1 miss, with out-of-order execution requires a D$ that can have several misses outstanding.
- The practical gain is expected to be **about 1.2 to 1.4 times**.
- The 8-stage in-order pipeline with gshare already performs well, so the relative gain of out-of-order execution is
  modest.

---

## 8. Verification

### Reused assets
- SIM_CORE / SIM_SYS / SIM_BIOS (Linux boot), riscv-tests, the bug-injection framework

### Added for out-of-order execution
| Means | Purpose |
|---|---|
| Lock-step comparison with Spike at commit | Correctness per instruction (design a commit-trace interface like RVFI from the start) |
| Random instruction streams from riscv-dv | Dense hazards to find holes in renaming and recovery |
| Exception and interrupt injection | Interrupts during a misprediction, page faults on the speculative path and so on |
| Konata-format pipeline view | Much better debugging efficiency for out-of-order execution |
| Random tests for the LSQ alone | Store forwarding, MMIO, AMO, conflicts with DMA |
| Bug injection | Into renaming, the free list and checkpoints, to check the tests catch them |

### Debugging on the board
- There should be no LUT or block RAM room for an ILA.
- Put a **ring buffer of the commit trace** (1 or 2 block RAMs) in the core, read over JTAG, from the start.

---

## 9. Steps

| Phase | Content | Done when |
|---|---|---|
| 0 | Utilization by hierarchy today, budget | A table of LUT / BRAM / DSP per block |
| 1 | **Build NaxRiscv RV64 (with FPU) with LiteX on the Arty A7-100T and measure it** | Does it fit, how many LUTs, performance under Linux. This gives the upper bound of "how realistic is an out-of-order RV64GC on the Arty 100T" |
| 2 | 1-wide out-of-order (renaming, ROB, issue queue, conservative LSQ, all non-speculative handling) | Linux boots, stress test PASS |
| 3 | 2-wide decode / rename / commit, RVC aligner | Linux boots, CoreMark/MHz improves |
| 4 | Speculative loads (store-wait prediction bits), store forwarding, multiple MSHRs | Better CPI on kernel loads |
| 5 | Stronger FPU and a TAGE predictor within the remaining resources | Trade-off of resources and performance settled |

NaxRiscv's 1-decode configuration still gives 3.35 CoreMark/MHz. Building a solid base of correctness with the 1-wide
out-of-order core of Phase 2 is well worth it.

---

## 10. Fallbacks (if it does not fit)

| Alternative | Size increase | Expected performance | Note |
|---|---|---|---|
| Dual-issue in-order (like the U74) | +20 to 30 % | 1.2 to 1.3 times | Makes the most of today's 8-stage pipeline and branch prediction |
| Out-of-order for integer only, FP as an in-order side pipe | Medium | Out-of-order on the integer side | Keeps RV64GC with the out-of-order cost on the integer side |
| Stop at 1-wide out-of-order | Small to medium | Like NaxRiscv's 1-decode | Still valuable as a design asset |

---

## 11. Open items

- [ ] Utilization by hierarchy today (especially FPU, L2, LiteX)
- [ ] DSP48s used and free
- [ ] Does NaxRiscv RV64 + FPU fit the Arty A7-100T; if so, its LUTs and performance
- [ ] How to handle the FPU (options 1 to 4)
- [ ] Check the privileged spec on speculative A/D updates by the PTW
- [ ] OpenSBI's behavior with fewer PMP entries
- [ ] Issue queue style (distributed / shared)
- [ ] Early timing evaluation of whether wakeup-select closes in one cycle

---

## References

- mmRISC-2: https://github.com/munetomo-maruyama/mmRISC-2
- NaxRiscv Performance and Area: https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html
- NaxRiscv: https://github.com/SpinalHDL/NaxRiscv
