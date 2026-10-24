# Remaining study items of Phase 0 (problems and countermeasures)

- Date: 2026-10-24
- Status: the items to study before G0 (micro-architecture frozen, `Doc/STRATEGY.md` section 7), as problems and
  countermeasures. Based on `ICOUNT.md`, `TRACE.md` and the measured resources of mmRISC-2 Rev.02 (section 2 here).
- Updated as the work goes on (like `ROADMAP.md` of mmRISC-2).

---

## 0. Summary

1. **Where we are**: the IPC needed is 1.56 for 5.0 with `-O2` and 1.69 for 6.0 with the most optimization
   (`ICOUNT.md`). In the limit model of the trace analysis, TAGE + a zero-bubble front end + instruction fusion reach
   6.8 /MHz with `-O2` and 7.5 with the most optimization (`TRACE.md`). But it is not calibrated: until the loss of a
   real core (10 to 25 % as a placeholder) is pinned down, whether the goals are reachable cannot be judged.
2. **First priority: the calibrated cycle model** (3.1). Most later decisions depend on its numbers.
3. Three structural crux points:
   - **A zero-bubble front end together with a TAGE in block RAM** (3.2): a bubble per taken branch costs −19 %.
   - **Whether instruction fusion is feasible at 50 MHz on speed grade -1** (3.3): two ALU stages in series, 4-wide
     decode, exceptions.
   - **The LUT budget** (3.4): measured, LiteX is only 4.8k LUTs, and the FPU at 8.8k LUTs is the largest block in the
     core. **How the FPU is handled is the largest lever of the resource allocation.**
4. How to proceed: the cycle model (Claude Code) and early OOC synthesis of small blocks (RTL by Claude Code, Vivado
   by the author) in parallel; their results go into the G0 specification.

---

## 1. Where we are (done and decided)

| Item | Result | Document |
|---|---|---|
| Strategy | CoreMark first, measure before building, phases and gates | `Doc/STRATEGY.md` |
| Measurement rules | Fixed at GCC 14.2 (Debian 13); `-O2` with Zba / Zbb / Zbs / Zicond; Zicond in the hardware (decided 2026-10-24) | `ICOUNT.md` section 4 |
| Instruction counts | 311,890 with `-O2`, 280,958 with the most optimization (sf + `-flto`) per iteration | `ICOUNT.md` |
| Trace analysis | TAGE takes MPKI from 9.4 to 0.9 - 1.4; the 2-wide limit is the width; fusion +15 %, a bubble per taken transfer −19 %; SFB does not help; a conservative LSQ loses nothing | `TRACE.md` |
| Tools | Spike (1.1.1-dev), GCC 14.2 of Debian 13 (qemu-user), trace capture, analysis and limit model | `Plan/README.md` |
| Record | Prompt log (English and Japanese) | `Doc/PROMPT.md` |

---

## 2. New: the measured resources of mmRISC-2 Rev.02

From mmRISC-2's `LitexSystem/build/gateware/digilent_arty_utilization_hierarchical_place.rpt` (2026-10-19, after
placement). This answers the open item "utilization by hierarchy" of Phase 0.

| Hierarchy | LUT | FF | RAMB36 / RAMB18 | DSP |
|---|---|---|---|---|
| **Total** | **50,301 (79.3 %)** | 29,473 | 102 / 13 (108.5 tiles / 135) | 32 / 240 |
| LiteX (outside CPU_TOP) | **4,826** | 4,458 | 26 / 5 | 0 |
| CPU_TOP | 45,482 | 25,015 | 76 / 8 | 32 |
| └ CPU_CORE | 32,929 | 16,043 | 0 | 32 |
| 　├ FPU_PIPE | **8,815** | 2,678 | 0 | 16 |
| 　├ CORE_IFU | 5,738 | 2,647 | 0 | 0 |
| 　├ CORE_CSR | 4,750 | 2,629 | 0 | 0 |
| 　├ CORE_MMU | 4,190 | 4,612 | 0 | 0 |
| 　├ CORE_MDU | 3,423 | 925 | 0 | 16 |
| 　├ Pipeline itself (directly in CPU_CORE) | 2,511 | 2,455 | 0 | 0 |
| 　├ CORE_EXU | 1,670 | 0 | 0 | 0 |
| 　├ CORE_LSU / RF / FRF / DEC / DECOMP | 946 / 384 / 544 / 278 / 78 | | | |
| └ CPU_CACHE (I$ 660 / D$ 7,497) | 8,217 | 5,959 | 8 / 8 | 0 |
| └ CPU_L2 | 1,256 | 933 | **68** / 0 | 0 |
| └ CPU_DBG / CPU_MMIO / DMA / BUS_ARB | 1,234 / 1,096 / 620 / 144 | | | |

### The budget revised (correcting the estimate of `STRATEGY.md` section 3)

| Item | Estimate (STRATEGY) | From the measurement |
|---|---|---|
| LiteX SoC | 11k to 13k | **4.8k** |
| CPU_TOP outside the core (caches, L2, debug, MMIO, DMA) | about 9k | 12.6k |
| Left for the core (total up to about 52k) | about 30k | **about 34.6k** (mmRISC-2's core is 32.9k) |
| Needed regardless of out-of-order (CSR, MMU, MDU, FPU, FRF) | about 15k | **21.7k** (FPU 8.8k of it) |
| Left for the out-of-order engine + front end + ALUs + LSU | 15k to 16k | **about 12.9k** (more by whatever a smaller FPU frees) |

- **The FPU is 27 % of the core.** Going back to a multi-cycle FPU is expected to free several k LUTs. But the size of
  the FPU before pipelining cannot be read reliably from mmRISC-2's records (cross-boundary optimization counted part
  of the FPU under the LSU at the time, TIMING.md); it is measured by OOC synthesis. A smaller FPU is almost a
  precondition for room comparable to NaxRiscv RV64 (about 18k, integer only).
- 26.5 block RAM tiles are free. TAGE-S to -M (3 to 8), BTB (2 to 4) and ROB payload (1 or 2) fit. If short, an L2 of
  128 KB instead of 256 KB frees 32 tiles (no effect on CoreMark; an effect on Linux loads).
- Slice usage of 93 % (mmRISC-2) was the main cause of routing delay, so the LUT ceiling stays about the same (about
  52k).

---

## 3. Study items (problems and countermeasures)

### 3.1 Calibrated cycle model [first priority]

| | Content |
|---|---|
| Problem | The limit model leaves out front-end alignment, predictor read latency, issue-queue capacity, wakeup delay, rename stalls and wrong load-hit predictions. Until the gap to a real core (10 to 25 % as a placeholder) is pinned down, neither reaching the goals nor what to build can be decided |
| Countermeasure | A C++ cycle model on the same traces, with explicit pipeline stages and the configuration as parameters. **First reproduce and calibrate against mmRISC-2's 8-stage in-order core**: CoreMark CPI 1.103 (SIM_SYS), 5.4 % mispredictions, the load-use and multiply waits (BENCH.md sections 8, 9 and 13). Then build the 2-wide out-of-order core from the same parts |
| Done when | In-order CPI within ±3 %, the waits in the same order as measured; for out-of-order, a table of CoreMark/MHz and each factor's contribution |
| Caution | A trace-driven model does not execute wrong-path instructions (no pollution of predictors or the I$). CoreMark fits in the caches, so the effect is small, but it is recorded as a limit |
| Who | Claude Code |

### 3.2 Front end: zero bubbles together with TAGE

**Added 2026-10-24**: in the out-of-order cycle model (`MODEL.md` section 6), 16-byte fetch decoupled from dispatch
by a buffer absorbs almost all bubbles at taken transfers (−0.9 % even without a uBTB); fetch width is what matters
(8 bytes: −3.8 %). Read the weight of the problem below in that light.

| | Content |
|---|---|
| Problem | There are 125 taken branches per 1000 instructions, and one bubble each costs −19 %. A TAGE and BTB in block RAM take 2 cycles to read, so they cannot give the next PC in one cycle. With 46 % RVC, instruction boundaries and 32-bit instructions across 16 B fetch blocks (3 to 9 %) also need handling |
| Countermeasure | **Two-level prediction**: a small next-line predictor (uBTB, LUTRAM) gives the next PC in one cycle with no bubble, and TAGE and the BTB override it in the second cycle (1 or 2 cycles lost only when they disagree). Sizing of the uBTB: CoreMark has 184 to 206 instructions that are ever taken, and **64 entries cover 87 to 93 %, 128 entries 98 to 99.6 %** (measured for this document). 16 B fetch + a fetch buffer in 16-bit parcels, predecode bits in the I$; an FTQ decouples prediction and fetch |
| Check | In the cycle model, sweep the uBTB size, the override rate and loss, the fetch width. OOC synthesis of the uBTB next-PC path early |
| Related | In mmRISC-2, branches across words were once 54 % of the mispredictions (CPU_CORE_SPEC 4.2); boundary handling goes into the spec from the start |

### 3.3 Feasibility of instruction fusion

| | Content |
|---|---|
| Problem | (1) **Timing**: ALU + ALU fusion puts two 64-bit ALUs in series in one cycle; does it close at 50 MHz (grade -1) with bypass and wakeup? (2) **Width**: up to 4 instructions in 2 µops means decoding 4 instructions a cycle (4 decoders and RVC expanders, more LUTs). (3) **Correctness**: an exception inside a fused pair (page fault of address calculation + load), single-step debug, triggers, counting `minstret` and PMU events. (4) **PRF ports**: a pair has 3 sources |
| Countermeasure | (1) OOC synthesis of a small RTL of two ALU stages to measure the delay; if it does not close, limit fusion to ALU + branch (compare + branch, no write) and address calculation + load (one more adder in the AGU). (2) Estimate the LUTs of 4-wide decode; fuse only adjacent pairs within one fetch block. (3) On an exception or in debug, **split the pair and re-execute one at a time** (a common technique); no fusion while single-stepping or with triggers set; `minstret` counts instructions. (4) Prefer pairs whose intermediate result is dead (89 % of ALU + ALU), so no write port is added |
| Check | In the cycle model, compare each fusion kind and the latency assumption (chained in 1 cycle / 2 cycles); OOC synthesis for timing |
| Who | RTL pieces and model by Claude Code, Vivado by the author |

### 3.4 Resource allocation

| | Content |
|---|---|
| Problem | About 12.9k LUTs remain for the out-of-order engine (with the FPU as it is), less than NaxRiscv RV64's integer core (about 18k). The D$ is also large (7.5k) and grows when connected to an out-of-order LSU |
| Countermeasure | **Make the FPU smaller** (multi-cycle, or an in-order side pipe: options 3 / 4 of `PRESTUDY_MMRISC2.md` 5.A): several k LUTs expected (size checked by OOC synthesis). CoreMark uses no floating point; F / D stay for Debian's lp64d. Other candidates: PMP 16 → 8 (check OpenSBI), triggers 4 → 2, sharing the Zbc (clmul) of the MDU. Large tables in block RAM / LUTRAM, never in FFs |
| To decide | FPU style (D-1), L2 size (D-2), keeping Ethernet (D-3). **The list of reduction options is `REDUCE.md`** (2026-10-24; about 3.5k to 5k LUTs from options that lose no feature or performance) |
| Check | Add up LUTs from OOC synthesis of the main blocks into a budget table at G0 |

### 3.5 Timing crux points at 50 MHz (grade -1)

| | Content |
|---|---|
| Problem | mmRISC-2 started at −20.4 ns with 7 in-order stages (closed with 8). Out-of-order has several loops that must close in one cycle: wakeup-select, renaming (dependences within a group of 4 instructions + fusion), next-PC generation (uBTB), two ALU stages, PRF reads through the LVT |
| Countermeasure | **OOC synthesis of a small RTL of each loop before G0** (as FPU_OOC / L2_OOC in mmRISC-2). A loop that does not close gets split into stages in the spec. The last resort is a 2-cycle ALU (about −15 % in NaxRiscv's notes; checked in the cycle model) |
| Who | RTL pieces by Claude Code, OOC synthesis by the author |

### 3.6 LSU and memory

| | Content |
|---|---|
| Problem | Keeping load-use at 2 cycles needs load-hit prediction with speculative wakeup of dependents and replay on a miss (3-cycle load-use costs 3 to 4 %). 11 % of the loads read data just stored, so store-to-load forwarding is required. mmRISC-2's D$ interface assumes one in-order LSU |
| Countermeasure | Conservative memory dependence (0 % loss confirmed) with LQ / SQ and forwarding (same address and size). Stores write the D$ after commit. Keep mmRISC-2's D$ (non-blocking, 2 MSHRs) behind an adapter with tagged requests / responses on the out-of-order side; reread CPU_CACHE_SPEC's interface and list the changes |
| Check | In the cycle model: loss from wrong hit predictions and replay, SQ depth |

### 3.7 Hooks for Linux (non-speculative execution)

| | Content |
|---|---|
| Problem | What typically breaks Linux on out-of-order cores is side effects: MMIO loads, CSRs, AMO / LR / SC, SFENCE.VMA / FENCE.I, A/D updates by the PTW, precise exceptions, debug, triggers, PMU (`PRESTUDY_MMRISC2.md` section 4). With a CoreMark-first Phase 1 (M-mode only), adding these later risks breakage |
| Countermeasure | Put into the Phase 1 spec "the list of instructions serialized at the ROB head" and "the hooks for precise exceptions" (implemented simply, but all the way through from the start). Check the privileged spec on speculative A/D updates by the PTW |
| Check | The list exists in the G0 specification |

### 3.8 Verification infrastructure

| | Content |
|---|---|
| Problem | Out-of-order bugs are harder to find than in-order ones. mmRISC-2's assets (SIM_CORE / SYS / BIOS, riscv-tests, bug injection) do not assume per-instruction comparison |
| Countermeasure | **Lock-step comparison with Spike at commit** from day one (Spike is installed; check how far it supports mmRISC-2's extensions: Sstc, Zicboz, Smcntrpmf, Sdtrig, PMP and so on). A commit-trace interface like RVFI, Konata pipeline views, cycle comparison with the cycle model (performance bugs), random instruction streams, exception injection, bug injection into renaming and the LSQ |
| Check | The first deliverable of Phase 1 is the lock-step comparison framework |

### 3.9 Measuring on the board

| | Content |
|---|---|
| Problem | On the board CoreMark is the posix port under Linux (glibc), so its count does not match the bare-metal one exactly. The options of the most optimization (sf + `-flto` or sf) must be chosen by cycles, not by instruction counts |
| Countermeasure | Fix how the board's CoreMark is built with GCC 14.2 (qemu-user on the host, or gcc on the board). Choose the most-optimization options by comparing cycles in the cycle model and RTL simulation |

### 3.10 Measuring NaxRiscv (lower priority)

| | Content |
|---|---|
| Problem | It was planned as the way to know the upper bound of an out-of-order core on the Arty (`STRATEGY.md` 5.2, step 5). With mmRISC-2's measurement most of the budget is known, so its value drops to "a reference for the LUTs of an out-of-order engine" |
| Countermeasure | Do it when the budget turns out to be tight: build with LiteX `--cpu-type naxriscv --xlen 64`, synthesized by the author in Vivado |

---

## 4. Decisions for the author

| # | Item | Options | Recommendation | When |
|---|---|---|---|---|
| D-1 | FPU style | Pipelined as now / multi-cycle / in-order side pipe | Multi-cycle (LUTs to the integer side; no effect on CoreMark) | **Decided 2026-10-24: pipelined at first**; reconsidered depending on the logic size |
| D-2 | L2 size | 256 KB / 128 KB | Keep 256 KB; 128 KB if block RAM runs out | G0 |
| D-3 | Ethernet | Keep / remove | Keep; the first candidate to cut if LUTs run out | **Decided 2026-10-24: kept**; reduce by the options of `REDUCE.md` |
| D-4 | Fusion scope | Address calculation + load only / + ALU + branch / + ALU + ALU | Decided by the cycle model and OOC synthesis | G0 |
| D-5 | TAGE size | S (62 kbit) / M (196 kbit) | Start with S; M if block RAM allows | G0 |
| D-6 | Most-optimization options | sf + `-flto` / sf | Decided by cycles | Phase 1 |

---

## 5. How to proceed

| Step | Work | Who | Deliverable |
|---|---|---|---|
| 1 | Cycle model: framework, calibration with the 8-stage in-order core | Claude Code | `Plan/model/`, `Plan/MODEL.md` |
| 2 | Cycle model: 2-wide out-of-order, front end (uBTB + TAGE), fusion, LSU | Claude Code | CoreMark/MHz per configuration and a table of factors |
| 3 | OOC synthesis of small blocks: two ALU stages, wakeup-select, uBTB next PC, renaming, PRF (LVT), multi-cycle FPU | RTL by Claude Code, Vivado by the author | Table of delays and LUTs |
| 4 | Resource budget table and decisions D-1 to D-5 | Claude Code proposes, the author decides | — |
| 5 | **G0: micro-architecture specification** (the Phase 1 spec, with the lock-step verification framework and the non-speculative list) | Claude Code | `Spec/` or `Doc/` |

Steps 1 and 3 are independent and can run in parallel. The RTL pieces of step 3 are written so that Phase 1 can use
them as they are.

---

## 6. Risks and fallbacks (revised)

| Risk | Sign | Counter / fallback |
|---|---|---|
| The calibrated model does not reach 5.0 with `-O2` | Result of step 2 | Work on the largest losses first (front end, hit prediction); if still short, revisit the goals with the author |
| Two ALU stages do not close at 50 MHz | Step 3 | Limit fusion to ALU + branch and address calculation + load (+15 % → about +8 %) |
| Not enough LUTs | Steps 3 and 4 | Smaller FPU, fewer PMP entries and triggers, remove Ethernet; if still short, drop 4-wide decode and fuse only address calculation + load |
| The zero-bubble next PC does not close in one cycle | Step 3 | A smaller uBTB, or accept one bubble per taken branch and win it back with fusion (evaluated in the model) |
