# mmRISC-3 log of prompts and answers

The prompts the author gave Claude Code and Claude Code's answers to them, in the order they were typed, with the date
and time (JST), from the first prompt at 2026-10-23 23:23. This is the English translation of `PROMPT_J.md`, the
original in Japanese.

- Prompts: entries 1 to 8 (up to 2026-10-24 01:01) were written out from the session log; later ones are appended to
  `PROMPT_J.md` by a Claude Code hook (`.claude/hooks/record_prompt.py`) at every prompt. The text is translated as
  it is (an attached file stays as `@path`). Messages of the system (background jobs finishing and so on) are not
  included.
- Answers: the last answer Claude Code wrote in the turn of that prompt. Up to entry 13 they were written out from the
  session log; later ones are written into `PROMPT_J.md` by the same script at the end of each turn (Stop hook).
  Headings are two levels down and links are relative to this file. Short progress notes during the work and tool
  output are not included.
- "(button)" marks a prompt sent from the next-step choices Claude Code offered (the wording was prepared by Claude
  Code).
- "(shell)" marks a command typed in the shell mode (`!`), with its output.
- Claude Code translates a prompt here in the same turn, and an answer at the start of the next turn (the answer is the
  last thing written in a turn).

## 1. 2026-10-23 23:23:47 JST

```text
@"/media/psf/Home/Documents/CQ/RISCV/mmRISC/mmRISC-2/Doc/20261020_WhitePaper_mmRISC-2.pdf"
I want to start the development project of mmRISC-3.
(1) Last time I developed a single-issue, in-order 64-bit RISC-V CPU core and succeeded in running Linux (BusyBox, Debian 13) on the FPGA board ARTY-A7-100T (50 MHz). The details are documented as .md files in each level of the repository https://github.com/munetomo-maruyama/mmRISC-2 (the attachment is the white paper of mmRISC-2).
(2) mmRISC-3 is to be designed as a dual-issue, out-of-order 64-bit RISC-V CPU core, and as before I want to run Linux (BusyBox, Debian 13) on the FPGA board ARTY-A7-100T. The material you studied in the previous session is under Doc in this directory mmRISC-3.
(3) What I want to weigh most in this goal is pushing CoreMark performance to the limit: 5 to 6 CoreMark/MHz with -O2, and 6 CoreMark/MHz or more with -O3 + maximum optimization.
(4) Please study what strategy to take to settle the direction.
(5) The work is done in this directory mmRISC-3. Early on, I want to create a repository mmRISC-3 on GitHub https://github.com/munetomo-maruyama and work there.
```

<!-- answer -->
**Claude Code's answer**

Based on the white paper, the earlier study memo and the measurements in mmRISC-2's BENCH.md / TIMING.md, I put the strategy together in [STRATEGY_J.md](../Doc/STRATEGY_J.md) (English: [STRATEGY.md](../Doc/STRATEGY.md)).

#### Key points

**1. Splitting the goal into "instruction count × IPC" shows how hard it is**
mmRISC-2's `-O2` (Zba/Zbb) runs 318.6k instructions per CoreMark iteration (measured). At that count, the IPC needed is:
- 5.0 /MHz: IPC 1.59
- 6.0 /MHz: IPC 1.91

The limit of 2-wide is IPC 2.0, so **6.0 with `-O2` is not realistic for 2-wide**. I recommend the goals "5.0 with `-O2`, 6.0 with the most optimization". The earlier memo's expectation (about 4.9 /MHz) does not reach this, so the design's center of gravity has to change.

**2. The main enemy is branch misprediction**
Today there are 13 mispredictions per 1000 instructions (measured). At about 10 cycles each in an out-of-order core, that is 130 cycles lost per 1000 instructions, while the budget for losses at 5.0 /MHz is only 128 cycles: this alone uses it up. Three things to make work first:
- A large TAGE-like predictor in block RAM (CoreMark has the same input every time, so long histories work well)
- Use the slack of 50 MHz for fewer stages, keeping a misprediction at 10 cycles or less
- Short-forward-branch predication (SFB) to remove mispredictions altogether

**3. Get past the IPC-2 wall by means other than width**
About 30k LUTs are available for the core on the Arty. About 15k remain for the out-of-order engine, less than NaxRiscv RV64 (about 18k, integer only), so 3-wide decode hardly fits. Make up for it with:
- Macro-op fusion
- SFB
- Fewer instructions (compiler and ISA extensions)
- The FPU does nothing for CoreMark, so shrink it and give its LUTs to the integer side

**4. To "measure before building", a performance model in Phase 0**
- Take CoreMark traces with Spike and build a trace-driven C++ model.
- Calibrate it to reproduce mmRISC-2's CPI 1.103, then compare widths, predictors and fusion.
- Freeze the micro-architecture once the predicted CoreMark/MHz and the LUT budget are in numbers (gate G0).

**5. CoreMark first**
Build only the integer out-of-order core first and reach the CoreMark goal in simulation; then add MMU / FPU / Linux. So that nothing breaks later, the hooks for non-speculative execution and precise exceptions are in the spec from the start. Commit-level comparison with Spike is used for correctness from day one.

**Realistic expectation**: 4.5 to 5.0 with `-O2`, 5.0 to 5.5 with the most optimization. These are estimates, to be checked in Phase 0. 6.0 or more with the most optimization is the upside if fusion, SFB and fewer instructions all work.

Section 8 of the document lists the points for your decision with recommendations (D1 to D6: the goal, width, FPU, frequency, Ethernet, repository).

GitHub is authenticated and the name `mmRISC-3` is still free. Once created, I will make the first commit in the same form as mmRISC-2 (Apache-2.0, main / dev, README in English and Japanese) and push it.
<!-- /answer -->

## 2. 2026-10-23 23:32:00 JST (button)

```text
Create the mmRISC-3 repository in the same form as mmRISC-2 (public, Apache-2.0, main/dev, README in English and Japanese), make the first commit of Doc and push it.
```

<!-- answer -->
**Claude Code's answer**

I created the public mmRISC-3 repository on GitHub and pushed the first commit.

- **URL**: https://github.com/munetomo-maruyama/mmRISC-3 (default branch main)
- **Branches**: main and dev point to the same first commit `bb7e952`. dev is checked out locally, and work goes on there.
- **Content of the first commit**:
  - Doc: `STRATEGY.md` / `STRATEGY_J.md` and the earlier study memo
  - `README.md` / `README_J.md`: the goals (5.0 CoreMark/MHz with `-O2`, 6.0 with the most optimization), status (Phase 0), list of documents, branch policy
  - `LICENSE` (Apache-2.0 as mmRISC-2) and `NOTICE`
  - `.gitignore`: Spec/ and .DS_Store excluded (as in mmRISC-2)
- **Repository description**: set in English as "2-wide OoO RV64GC, Linux on Arty A7, aiming at 5-6 CoreMark/MHz, designed by Claude Code, successor of mmRISC-2".

The note at the top of the README about the design by Claude Code does not copy mmRISC-2's "designed entirely" but says "is to be written".

This session's working directory is still mmRISC-2. From Phase 0 on, opening a new session with mmRISC-3 as the working directory will make paths simpler.
<!-- /answer -->

## 3. 2026-10-23 23:37:15 JST

```text
Please gather the working files and documents of the performance evaluation, as preliminary studies, in a directory called Plan.
Please start the instruction-count measurement of Phase 0.
```

<!-- answer -->
**Claude Code's answer**

(No answer in this turn: it stopped on a tool search that took too long. The result is in the answer to entry 4.)
<!-- /answer -->

## 4. 2026-10-23 23:58:41 JST

```text
Please try again.
```

<!-- answer -->
**Claude Code's answer**

I finished counting CoreMark's instructions. GCC 14.2 + Zicond gives the fewest instructions, and the IPC the goals need goes down from the first estimate. The results are in [Plan/ICOUNT_J.md](../Plan/ICOUNT_J.md) (English: [ICOUNT.md](../Plan/ICOUNT.md)), pushed to dev in commit `8b52ea7`.

#### Results

| Goal | Fewest with | Instructions per iteration | IPC needed (first estimate) |
|---|---|---|---|
| 5.0 /MHz with `-O2` | GCC 14.2, Zba/Zbb/Zbs/Zicond | 311,890 | **1.56** (1.59) |
| 6.0 /MHz with the most optimization | GCC 14.2, sf + `-flto` | 280,958 | **1.69** (1.77) |

- **Reliability**: Spike's count agrees with mmRISC-2's SIM_SYS measurement within 7 instructions (0.0002 %). crcfinal is right in every build, and the count per iteration does not change from 10 to 20 iterations.
- **Compiler**: GCC 14.2 gives the fewest. clang 18 gives 19 to 29 % more, so it should not be used for measuring CoreMark. Ubuntu's 13.3 gives exactly the same count as 13.2.
- **ISA extensions**:
  - Zba/Zbb: −11 to 13 %, the largest effect
  - Zicond: −1.5 % with GCC 14 (GCC 13 and older do not use it)
  - Zbs: almost no effect
- **Most optimization**: `-flto` reduces the count with GCC 14 but increases it by 7 to 8 % with GCC 12/13. And fewer instructions do not always mean fewer cycles (the code grows to 34 KB, the I$ is 16 KB). The final options are chosen by the cycles of the performance model.

#### What was built

- **Plan/icount/**: `icount.sh` (builds compiler × options × `-march` and counts on Spike), the bare-metal port for Spike (`port/`), all data (`results/icount.csv`)
- **Tools outside the repository**:
  - Spike built into `~/RISCV/toolchain/spike-install`.
  - Debian 13's gcc 14.2 (the same as the gcc on the board) runs under qemu-user, from mmRISC-2's Debian root fs unpacked into `~/RISCV/toolchain/debian13-rootfs`. Where and how are in Plan/README.
- **Existing documents updated**: the estimates of §1.1 of Doc/STRATEGY replaced by the measurements, links from the README to Plan/ added.

#### For your decision (ICOUNT §4)

- Fix the compiler for measurements at GCC 14.2 (Debian 13)
- Include Zicond in the definition of `-O2`, and put Zicond in the hardware

Doc/ still holds STRATEGY and the earlier study memo. If you want the preliminary memo moved to Plan/ too, please say so.
<!-- /answer -->

## 5. 2026-10-24 00:20:03 JST

```text
Please move the preliminary study memo in Doc to Plan, give it a file name meaning "preliminary study made during the development of mmRISC-2", and also keep an English translation of it. For the study, please go on to the trace analysis with the following.

* Fix the compiler for measurements at GCC 14.2 (Debian 13)
* Include Zicond in the definition of `-O2`, and put Zicond in the hardware too
```

<!-- answer -->
**Claude Code's answer**

(No closing answer: the author switched to the next question during the turn. The work is in commit 9d79414 (the study memo moved and translated, the decisions recorded) and 34a0dcd (the trace analysis), the document in `Plan/TRACE.md`.)
<!-- /answer -->

## 6. 2026-10-24 00:47:09 JST

```text
In the left pane of this screen, "mmRISC-3開発戦略" (mmRISC-3 development strategy) under Code is inside the light-colored mmRISC-2. Can it be placed under the light-colored mmRISC-3?
```

<!-- answer -->
**Claude Code's answer**

Yes, it can be moved. I changed this session's working folder to mmRISC-3, so when this turn ends "mmRISC-3開発戦略" will appear under the mmRISC-3 heading of the sidebar. The sidebar groups sessions by working folder, and the cause was that the working folder was still mmRISC-2.

**Copying the memory**: Claude Code's memory is kept per working folder, so after the move the notes made on the mmRISC-2 side would no longer be loaded. So I copied them to mmRISC-3's memory: the warning about make on the shared folder, documents in two languages, the policy of mmRISC-3 and so on. Only the note about mmRISC-2's GF180 was left out as unrelated.

**Interrupted work**: the results and documents of the trace analysis are pushed to dev in commit `34a0dcd`. But the check that `trace.sh` run from scratch reproduces the same results was interrupted and is not done yet.

Which do you want next?
- Run the interrupted reproduction check of `trace.sh` (about 5 minutes for one build)
- Leave the check for later and go on to the next work (the cycle model calibrated against mmRISC-2's measurements)
<!-- /answer -->

## 7. 2026-10-24 00:48:24 JST (button)

```text
Run the interrupted reproduction check of trace.sh (run it end to end with g13-o2-zb and see whether it matches the committed results).
```

<!-- answer -->
**Claude Code's answer**

I ran `trace.sh` from scratch with g13-o2-zb, and the rebuilt results match the committed ones byte for byte.

- **Run**: build → trace on Spike → analysis went through without errors, in 2 minutes 32 seconds.
- **Match**: `results/g13-o2-zb.json` (all analyses) and `results/g13-o2-zb.limit.txt` (the limit model) were both rebuilt now, and git shows no difference. The procedure is reproducible.
- **Cleanup**: on the way `icount.sh` rewrote `icount.csv`, but only the order of the rows changed and the values are the same, so I restored it. The working tree is clean, with no extra commit.
<!-- /answer -->

## 8. 2026-10-24 01:01:12 JST

```text
In this development project, I want the prompts I type recorded, going back to the very first one and continuing with the ones to come. Please append them, with the date and time, in a file Doc/PROMPT.
```

<!-- answer -->
**Claude Code's answer**

I made [Doc/PROMPT.md](../Doc/PROMPT.md) and recorded the 8 prompts from the first one to this request, with the date and time (JST) they were typed. Pushed to dev in commit `c931a77`.

- **The past ones**: written out as they are from this session's log.
  - The first one keeps the attached white paper as `@path`.
  - The two sent from the next-step buttons (creating the repository, and the reproduction check of trace.sh) are marked "(button)", because I prepared their wording.
  - Messages of the system, such as background jobs finishing, are not included.
- **The ones to come**: I set up a mechanism (a Claude Code hook) that appends every prompt you type automatically.
  - The script that appends is `.claude/hooks/record_prompt.py`, put in the repository.
  - The hook is registered in `.claude/settings.local.json`, which is not committed, so that someone else who gets the repository does not have their own prompts appended to this file.
- **Not yet checked**: whether the hook actually works. When you type your next prompt I will check that it was appended as entry 9. If not (for example if a new session is needed to load the settings), I will append it myself in the same form. This arrangement is also in my memory.
- **File name**: I added `.md` to the `Doc/PROMPT` you named, making `Doc/PROMPT.md`, so that GitHub shows the headings and text as they are. If you prefer no extension, I will change it.
- **README**: the English and Japanese READMEs link to this record.
<!-- /answer -->

## 9. 2026-10-24 01:05:02 JST

```text
Thank you. Please keep an English translation of PROMPT as well.
```

<!-- answer -->
**Claude Code's answer**

I put an English translation of the prompt log in place. Pushed to dev in commit `875fa8c`.

- **File names**: following this project's rule for documents (English `XXXX.md`, Japanese `XXXX_J.md`).
  - Original: [Doc/PROMPT_J.md](../Doc/PROMPT_J.md) (as typed)
  - Translation: [Doc/PROMPT.md](../Doc/PROMPT.md)
- **Scope of the translation**: all 9 entries, with numbers, times and button marks the same as the original.
- **The hook checked**: the hook appended this prompt automatically as entry 9, so what could not be checked last time is now confirmed. It now appends to `PROMPT_J.md`.
- **Translations from now on**: a hook cannot translate. I append the translation of each new prompt to `PROMPT.md` within the same turn. This arrangement is also in my memory.
- **README**: the links of both READMEs now point to both files.
<!-- /answer -->

## 10. 2026-10-24 01:21:12 JST

```text
Please sort out here the items to study next, including the problems and their countermeasures.
```

<!-- answer -->
**Claude Code's answer**

I sorted out the items to study before G0, as problems and countermeasures, in [Plan/ISSUES_J.md](../Plan/ISSUES_J.md) (English: [ISSUES.md](../Plan/ISSUES.md)). With this prompt's record and translation, pushed to dev in commit `c986141`.

#### New this time (resources measured)

A post-placement report of utilization by hierarchy was left in mmRISC-2's build results, and I used it.

- **Where the estimate was off**: I had estimated LiteX's peripherals at 11 to 13k LUTs; they are actually **4.8k LUTs**. What is left for the core grows to about 34.6k LUTs.
- **The FPU is the largest block**: the FPU takes 27 % of the core (**8.8k LUTs**).
  - The parts needed regardless of out-of-order execution (CSR, MMU, multiply/divide, FPU and so on) take 21.7k LUTs.
  - So about 12.9k LUTs remain for the out-of-order engine itself, less than NaxRiscv's integer core (about 18k): **whether to make the FPU smaller is the largest lever of the resource allocation**.
  - The correction is added to the resource-budget section of Doc/STRATEGY.

#### Main items, problems and countermeasures

| Item | Problem | Countermeasure |
|---|---|---|
| ① Calibrated cycle model (first priority) | The limit model so far is idealized; the loss of a real core is unknown | Calibrate by reproducing mmRISC-2's 8-stage in-order core (CPI 1.103, 5.4 % mispredictions), then compare out-of-order configurations |
| ② Front end | One empty cycle per taken branch costs −19 %; a TAGE in block RAM takes 2 cycles to read | A small predictor that gives the next PC in one cycle (uBTB), with TAGE overriding later: two levels. In CoreMark a 64-entry uBTB covers 87 to 93 % of taken branches, 128 entries 98 to 99.6 % (measured this time) |
| ③ Instruction fusion | Whether two ALU stages close at 50 MHz, the need to decode 4 instructions a cycle, exceptions in the middle of a fused pair | Synthesize small blocks first and measure the delay; on an exception, split the pair and re-execute one at a time; if it does not close, narrow the fusion (the gain drops to about +8 %) |
| ④ Timing at 50 MHz | Several things must close in one cycle: wakeup-select, renaming, next PC, two ALU stages | Synthesize each as a small RTL before freezing the spec |
| ⑤ Others | LSU (speculative use of load results, passing values from stores), the non-speculative hooks for Linux, verification by commit-level comparison with Spike, measuring on the board | Sorted out in ISSUES 3.6 to 3.9 |

**For your decision**: D-1 to D-6, six points with recommendations (FPU style, L2 size, Ethernet, fusion scope, TAGE size, most-optimization options). All assume decisions after the model and the early syntheses; nothing needs deciding now.

**How to proceed**: the cycle model (me) and early synthesis of small blocks (RTL by me, synthesis in Vivado by you) are independent and can run in parallel. Their results go into the G0 specification.
<!-- /answer -->

## 11. 2026-10-24 17:08:53 JST

```text
(D1) Target performance: basically the recommendation is OK. With the most optimization I want to exceed 6 cm/mhz.
(D2) Width: the recommendation is OK.
(D3) FPU: at first I want to think of it as pipelined. To be reconsidered depending on the logic size.
(D4) Frequency: fixed at 50 MHz.
(D5) Ethernet: go ahead with it. The logic-size problem is shared with D3, but please put forward various ideas, such as making the triggers 2.
(D6) Repository: as recommended, OK.
```

<!-- answer -->
**Claude Code's answer**

I recorded the decisions D1 to D6 and put the options for reducing the logic in [Plan/REDUCE_J.md](../Plan/REDUCE_J.md) (English: [REDUCE.md](../Plan/REDUCE.md)). Pushed to dev in commit `b8385d6`.

#### Decisions recorded

A column "Decision (2026-10-24)" added to section 8 of STRATEGY, and written into D-1 (FPU) and D-3 (Ethernet) of ISSUES.

- The goal is to exceed 6.0 CoreMark/MHz with the most optimization
- The FPU stays pipelined at first, reconsidered at G0 depending on the logic size
- Ethernet is kept

#### Reduction options

The savings were measured by synthesizing mmRISC-2's RTL with Yosys, with parameters changed, and converting the differences to Vivado terms (Vivado is only on your machine).

**Group A: no effect on CoreMark or on Linux performance (recommended from G0)**

| Option | Saving (LUT) | Basis |
|---|---|---|
| A1 Triggers 4 → 2 | about 0.3k (0.1 to 0.55k) | Measured |
| A2 PMP 8 → 4 entries | about 0.95k | Measured |
| A3 D$ 512-bit line buffers from FFs to LUTRAM | 0.8 to 1.5k | Estimate |
| A4 TLBs as set-associative LUTRAM (same capacity) | about 1k | Estimate |
| A5 Rarely written CSRs in LUTRAM | 0.5 to 1k | Estimate |
| **Total** | **about 3.5 to 5k** (FFs about 7 to 8k) | |

- A2 needs a simulation check that 4 entries are enough for OpenSBI.
- With group A, even with the pipelined FPU kept, the LUTs for the out-of-order engine grow from about 12.9k to **about 16 to 18k**, close to NaxRiscv's integer core (about 18k).

**Group B: trades Linux features or performance (no effect on CoreMark)**
- HPM counters 4 → 2 (about 0.65k): `perf` counts fewer events at once, so measurements take twice the runs.
- Remove Zbc (clmul) (0.3 to 0.6k): Linux's crc32 gets slower. Not in CoreMark's `-march`.
- TLBs back to Rev.01's size (about 1.2k): user-mode loads 11 to 20 % slower.
- No PMP (about 1.9k): no M-mode protection.

**Group C: the FPU (reconsidered at G0)**
- First get the FPU's breakdown; this time the rounder was about 23 % of the FPU.
- Options: share the multiplier with the MDU (0.5 to 1k), keep only FMA pipelined, and so on.

Also included: removing unneeded LiteX peripherals (group D) and principles for building the out-of-order parts small (group E). As an example of E, decoders are cheap, so 4-wide decode for fusion is expected to add only about 0.7k.

**Reliability of the measurement**
- CSR LUTs varied by about ±0.2k between syntheses of the same conditions, so they are given as ranges. FF and MMU values were stable every time.
- The PLIC gave an unnatural result (no fewer LUTs with fewer interrupt sources), so it is not counted. The PLIC itself is only 0.46k, so it does not matter.

#### The prompt log

This input is recorded as three entries, 11, 12 and 13. 11 and 12 seem to be partial submissions of the same content as 13. I kept all three as typed, with translations. If they are not needed, I will delete them.
<!-- /answer -->

## 12. 2026-10-24 17:24:45 JST ("11 and 12" in the text are the numbers before deletion: the two partial submissions of entry 11)

```text
Prompts 11 and 12 are not needed.
When that is done, let's go on to the cycle model.
```

<!-- answer -->
**Claude Code's answer**

After deleting entries 11 and 12 of the prompt log, I built the framework of the cycle model and calibrated it against mmRISC-2's 8-stage in-order core. It reproduces all five measured CoreMark points within ±0.3 %. Pushed to dev in commit `e1a8ecb`.

#### Prompt log

- Entries 11 and 12 deleted; the old 13 is now 11.
- This input is entry 12; its heading notes that "11 and 12" in the text are the numbers before the deletion.
- The numbers in STRATEGY and REDUCE that referred to the decisions were corrected too.

#### Cycle model (step 1)

The calibration uses five points left in mmRISC-2's BENCH. Each measured CoreMark in simulation, with one change in the hardware from point to point.

| Point | Change in mmRISC-2 | Measured (cycles) | Model | Difference |
|---|---|---|---|---|
| P1 | Start (multiply wait 3, 2-bit counters) | 4,312,829 | 4,314,572 | +0.04 % |
| P2 | Multiply wait 1 | 4,124,913 | 4,126,652 | +0.04 % |
| P3 | + gshare | 4,033,497 | 4,044,524 | +0.27 % |
| P4 | + branches waiting for a load value resolved in MR | 3,908,766 | 3,911,568 | +0.07 % |
| P5 | The Zba/Zbb build | 3,513,870 | 3,518,805 | +0.14 % |

- **Only one parameter was tuned** (2 cycles from resolving a misprediction to refetch), and with it the five points fit at once.
- **The breakdown of the waits agrees too**: the multiply waits exactly, the load-use waits 203,282 / 67,982 (measured 203,281 / 67,982). A misprediction costs 4.16 cycles (measured 4.12).
- **What is off**: the split of mispredictions between `jal` and `jalr`. The totals are close, so the effect on cycles is small; I think the cause is the simplified details of the predictor (handling of branches across words).

The model is in `Plan/model/`: the conversion of traces to fixed records, mmRISC-2's predictor, the in-order timing, and `calib.sh`, which reproduces the table above. The description is in [Plan/MODEL_J.md](../Plan/MODEL_J.md) and its English version.

#### Limits

Only the in-order parts could be calibrated: fetch, predictor, dependences, multiply. The parts specific to out-of-order (renaming, issue queues, TAGE, fusion) have no real core to compare with. So in step 2 the timing of each part is stated as a specification, in a form that explains part by part the difference to TRACE's limit model.
<!-- /answer -->

## 13. 2026-10-24 17:34:44 JST (button)

```text
Go on to step 2 of MODEL_J.md section 5, the 2-wide out-of-order model.
```

<!-- answer -->
**Claude Code's answer**

I built the 2-wide out-of-order cycle model and put the results in section 6 of [Plan/MODEL_J.md](../Plan/MODEL_J.md) (English: [MODEL.md](../Plan/MODEL.md)). By the model, **2-wide reaches the goals even without fusion**. Pushed to dev in commit `d7c53e3`.

#### Results (CoreMark/MHz)

| Configuration | -O2 | Most optimization |
|---|---|---|
| Baseline (TAGE-S, 16 B fetch, load-use 2, no fusion) | **6.07** | **6.57** |
| Pessimistic (small structures + 1 more cycle per part + load-use 3) | 5.61 | 6.05 |
| Baseline + fusion (up to ALU+ALU) | 7.06 | 7.59 |
| Pessimistic + fusion (up to ALU+ALU) | 6.41 | 6.88 |
| Reference: gshare like mmRISC-2 | 5.27 | 5.73 |

The goal of exceeding 6.0 with the most optimization is just met even by the pessimistic configuration; fusion gives margin.

#### How the model was checked

- With perfect prediction and the limits removed, IPC is 1.9507, matching TRACE's limit model (1.951).
- The C++ TAGE gives exactly the mispredictions of the Python trace analysis.
- A configuration close to NaxRiscv (gshare, load-use 3) gives 4.83, close to NaxRiscv RV64's published 4.94. Compiler and ISA differ, so only as a rough comparison.

#### Findings (that bear on the policy)

- **One correction to TRACE.** "−19 % for one empty cycle per taken branch" was the estimate of a limit model tying fetch directly to dispatch. With 16-byte fetch decoupled by a buffer, these empty cycles are almost all absorbed: even without a uBTB the loss is −0.9 %, and fetch width matters instead (8 bytes: −3.8 %). ISSUES 3.2 notes the correction.
- **What matters**: the branch predictor (gshare: −13 %), keeping load-use at 2 cycles (3: −5.9 %), store-to-load forwarding (none: −4.3 %), the 4-wide decode fusion needs (with 2-wide decode fusion gives only +3 %).
- **Structures that can be small**: ROB 32, issue queue 16, LQ/SQ 12 to 16, 8 checkpoints are enough (−0.3 %); the freed LUTs can go elsewhere.
- **What hardly matters**: pipeline depth (about −0.3 % per stage), uBTB size, multiply latency, limiting issue to 3 per cycle.

#### Limits (when reading the results)

- Caches always hit. In mmRISC-2 the board was about 2 % below the simulation; read the numbers with about that subtracted.
- Wrong-path instructions are not executed, so reality is a little worse.
- Whether the timing assumptions of the stages (1-cycle wakeup-select, chaining two ALU stages, the TAGE override in the second cycle) close at 50 MHz is not checked yet; the next OOC synthesis must confirm it.
<!-- /answer -->

## 14. 2026-10-24 18:49:10 JST

```text
Before going on: I had PROMPT record only what I type, but I also want Claude's answers recorded. They contain very valuable insights. Please change PROMPT (English and Japanese) that way.

After that, reflecting the policy,
please create the RTL in the "fusion" configuration.
```

<!-- answer -->
**Claude Code's answer**

I changed PROMPT to record "prompt and answer", then wrote the RTL of the fusion configuration reflecting the policy. Pushed to dev in commit `b88fd90` and others.

#### 1. Answers recorded in PROMPT

- **Entries so far**: to every entry 1 to 13 I attached the last answer I wrote in that turn, transcribed from the session record, in both the Japanese and English versions. Headings are lowered by two levels and links rewritten to work from Doc/.
- **Two entries without an answer**: entry 3 (a turn that stopped) and entry 5 (a turn that moved on to the next instruction midway) have no summarizing answer. They carry a note saying so, and where the results are (commits and documents).
- **From now on**: I added a hook (Stop) that writes the answer automatically at the end of a turn. This answer also goes into entry 14. The English translation can only be made after the answer is written, so I add it at the start of the next turn.

#### 2. Reflecting the policy

I added a "fusion configuration" column to section 4 of STRATEGY and made it the baseline. Its main points: 4-instruction decode with fusion up to ALU+ALU, ROB 32, issue queue 16, 96 physical registers, TAGE-S. D-4 (go with the fusion configuration) and D-5 (TAGE-S) of ISSUES are also recorded as decisions.

#### 3. RTL of the fusion configuration (`RTL/CPU/OOO/`)

Six blocks: the two-stage ALU, fusion, issue queue, renaming, physical registers and uBTB, in a form usable as they are in Phase 1.

- **Verification**: all six unit tests PASS. Each test checks against an independently written reference, and state without a reset starts at random values. All 21 deliberately injected bugs were detected, and the results were checked line by line.
- **Fusion matches the model**: streaming CoreMark's instructions through the 4-instruction window forms 99.99 % of the pairs the model forms (415,297 / 415,337).
- **What the tests found**:
  - One RTL bug: the checkpoint number advanced even for requests of invalid µops.
  - A coding problem: tables indexed by run-time values were written as packed arrays, and the logic grew to tens of thousands of LUTs. Fixed by rewriting them as arrays.
  - One hole in the tests: whether x0 returns zero was missed by relying on memory starting at 0.

**The biggest finding is the number of register-file ports.** If a fused pair uses 3 reads and 2 writes, 8 to 9 read and 5 to 6 write ports are needed. In Yosys' estimate that alone is 17k to 19k LUTs, using up the whole out-of-order budget. The model sweep:

| Fusion limit | -O2 | Most optimization | Read / write ports |
|---|---|---|---|
| No limit | 7.06 | 7.59 | 8 to 9 / 5 to 6 |
| **Up to 2 sources** | **6.94** (−1.7%) | **7.51** (−1.1%) | **6 / 5** |
| Up to 1 write | 6.75 (−4.4%) | 6.90 (−9.1%) | 8 to 9 / 3 |

I recommend adopting the 2-source limit. The number of write ports is decided from the Vivado results. Details in [Plan/OOC.md](../Plan/OOC.md).

#### Request (Vivado)

`FPGA\OOO_OOC\synth_ooo.bat` synthesizes each block and five register-file configurations out of context at 50 MHz through place and route. The results go to `output\<top>\summary.txt`. With them I want to settle three points:

- Whether chaining the two-stage ALU closes at 50 MHz
- The size of the issue queue (Yosys puts it large, at 15.6k LUTs)
- The number of write ports
<!-- /answer -->

## 15. 2026-10-24 21:03:00 JST

```text
I ran synth_ooo.bat of FPGA/OOO_OOC in Vivado. Please read the results under output and make the decisions of section 6 of OOC_J.md.
```

<!-- answer -->
**Claude Code's answer**

I made the section 6 decisions from the Vivado results. Two blocks miss 50 MHz: the 2-stage ALU and the uBTB. The size is the bigger problem: the blocks measured so far come to about twice the out-of-order budget by themselves. The details are in section 7 of [Plan/OOC_J.md](../Plan/OOC_J.md) (English: [OOC.md](../Plan/OOC.md)) and in ISSUES D-4, pushed to dev as `4f683c3`.

**The register-file runs did not happen.** `vivado` is itself a batch file. Without `call`, `synth_ooo.bat` stopped after the five block runs. I fixed it with `call` and added `synth_ooo.bat prf`, which runs only the five register-file configurations.

| Block | LUT | Register-to-register slack | Decision |
|---|---|---|---|
| 2-stage ALU | 8,248 | **−0.70 ns** | Keep ALU + ALU fusion (dropping it costs −6%). Narrow the second stage and rewrite the ALU. |
| Issue queue | 6,783 | +2.37 ns | One-cycle wakeup-select works; keep it. Reduce the size to about 4k. |
| Renaming | 6,934 | +4.79 ns | Closes; keep 8 checkpoints. Measure the breakdown before reducing it. |
| Fusion | 186 | +10.6 ns | No problem. |
| uBTB | 3,194 | **−24.5 ns** | Keep it with 16 entries, choose the hit in parallel, and use partial tags. |
| Register file | not run | — | Pairs are fixed at 2 sources at most (6 read ports). Write ports (5 or 3) after the rerun. |

**The ALU:**
- **Why it misses:** in the worst path, the second stage alone takes about 10.8 ns, and it ends in the min/max compare and select.
- **Narrowing the second stage costs nothing:** I counted the operations that appear in the second half of ALU + ALU pairs in the CoreMark traces. slt, min/max, clz/ctz/cpop, rotates and orc.b/rev8 never appear there, so removing them from the second stage loses no performance.
- **Why rewrite it:** a single OOO_ALU is 3–4.7k LUTs, 2–3 times mmRISC-2's whole CORE_EXU (1,670). It has a separate circuit for every operation. The rewrite shares one adder and one shifter across operations, as CORE_EXU does.

**The uBTB:** it misses because picking the first taken hit was written as a loop, which Vivado built as 32 comparisons in series (65 logic levels). I also had to correct an earlier statement. "No uBTB costs only −0.9%" was measured without fusion. With fusion, no uBTB costs −4.8% at -O2, and 16 entries cost only −0.2%.

**Budget:** the measured blocks total 33.6k LUTs plus the register file. The out-of-order part has a budget of 16–18k, and that also has to cover the ROB, LSU and decode. Even if every reduction hits its target, these blocks alone come to about 19–22k. So at G0 we will probably need to revisit the budget itself. The main option is D3, going back to a multi-cycle FPU (8.8k LUTs now).

For your next Vivado run:
```
synth_ooo.bat prf
```

The prompt log is up to date: the English for answer 14 and prompt 15 is in Doc/PROMPT.md. I committed the Vivado reports but not the .dcp checkpoints.
<!-- /answer -->

## 16. 2026-10-24 21:17:19 JST (shell)

```text
<bash-input>synth_ooo.bat prf</bash-input><bash-stdout>synth_ooo.bat: command not found</bash-stdout><bash-stderr></bash-stderr>
```

<!-- answer -->
**Claude Code's answer**

That command ran in this Linux VM's shell, where `synth_ooo.bat` can't run. It's a Windows batch file, and Vivado runs on your Windows side. It also only works from inside its own folder. Run it from a Windows Command Prompt the same way you ran the first batch:

```
cd FPGA\OOO_OOC
synth_ooo.bat prf
```

This runs only the five register-file configurations, which take place and route at 50 MHz. The results go to `output\OOC_PRF_NW3_NR8\summary.txt` and so on. When it finishes, tell me and I'll read them and decide between 5 and 3 write ports.
<!-- /answer -->

## 17. 2026-10-24 21:18:04 JST

```text
I will run synth_ooo.bat prf myself. Meanwhile, please go ahead with the RTL changes of section 8 of OOC_J.md (rewriting the ALU and narrowing its second stage, the limits in OOO_FUSE, and the 16-entry parallel uBTB).
```

<!-- answer -->
**Claude Code's answer**

The RTL changes of section 8 of OOC_J.md (the ALU, the fusion limits, the uBTB) are done. All six unit tests PASS and all 34 injected bugs are detected. The `synth_ooo.bat prf` results also came in during the work, so I decided the number of write ports too. Pushed to dev as `d1af292`.

**RTL changes**

- **ALU**: one adder and one shifter, shared between operations, and the second stage narrowed to the operations CoreMark puts there. The only shift in a second stage is srliw, so sll and sra are out too. In Yosys, one port goes from 8.2k to about 4.6k.
- **Fusion**: three limits added. On the CoreMark stream the number of pairs equals the model's exactly (276,058 / 276,058 at `-O2`), and the second-stage flag loses no pair.
  - whether the operation can be a second stage (`alu2ok`)
  - at most 2 sources
  - at most 1 write
- **uBTB**: 16 entries, 12-bit partial tags, the hit chosen in parallel. In Yosys, 5,041 → about 2.3k LUTs, and 2,635 → 970 FFs.

**Register file: 3 write ports decided**

| Writes / reads | Physical LUTs | Register-to-register slack |
|---|---|---|
| **3 / 6** | **4,942** | +2.70 ns |
| 5 / 6 | 8,350 | +2.21 ns |

- Every configuration closes at 50 MHz.
- The difference from 5 ports is 3.4k LUTs, about a fifth of the out-of-order budget. Performance is −4.7% / −8.2% (6.59 / 6.84), but 3 ports still exceed the goals.
- 5 ports became the first thing to buy back if G0 finds room in the budget.
- With one write per pair, 64 physical registers are enough. The issue queue and renaming also need only 2 sources and 1 destination per µop, so they can shrink further.

**A correction to how sizes were read**

The "LUT" of the earlier `summary.txt` was the number of LUT cells and did not include LUT RAM. Counted again in physical LUTs, as the budget is, the measured blocks total 31.4k + the register file. From now on `synth_ooo.tcl` also gives physical LUTs.

**The next Vivado runs** (OOC_J.md 8.4)

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_ALU2
synth_ooo.bat OOO_UBTB
synth_ooo.bat OOC_FUSE
synth_ooo.bat OOC_PRF 20.0 1 "NREG=64 NW=3 NR=6"
```

They should settle three things:

- whether the two-stage chain closes at 50 MHz with the rewritten ALU
- whether the uBTB closes in one cycle
- the size of the 64-register file

**Noticed along the way**

- **Batch file**: I edited `synth_ooo.bat` once during the work, but rewriting a batch file while it runs can make it misbehave, so I put it back at once. The PRF runs finished normally at 21:35. The change that keeps a separate log for a single run went in again afterwards.
- **Prompt log**: answer 15 was missing. The hook had taken the summary of a context compaction for the prompt; I fixed the hook and filled the answer in. My previous two answers were in English, so the Japanese versions were translated and put in. From now on I answer in Japanese.
<!-- /answer -->

## 18. 2026-10-24 21:58:40 JST

```text
I will run the Vivado runs of 8.4 (OOC_ALU2, OOO_UBTB, OOC_FUSE, the 64-register OOC_PRF). Meanwhile, please go ahead with rebuilding the issue queue and renaming of section 9 of OOC_J.md (2 sources and 1 destination per µop, 64 physical registers).
```

<!-- answer -->
**Claude Code's answer**

I rebuilt the issue queue and renaming: 2 sources and 1 destination per µop, 64 physical registers (6-bit tags). All six unit tests PASS and all 39 injected bugs are detected. The Vivado runs of 8.4 that I asked for all close too. The record is in section 10 of OOC_J.md (English: OOC.md), pushed to dev as `f4af1b8` and `1198110`.

**The rebuilt blocks** (Yosys)

| Block | Before | Now | Main change |
|---|---|---|---|
| Renaming | about 9.0k | **3,216** | The checkpoints are copied a cycle late from the RAT flip-flops |
| Issue queue | about 15.5k | **5,009** | Wakeup tag buses from 14 to 6; comparators from 672 to 192 |

- **Checkpoints**: before, each of the 1,792 bits chose between the RAT "after µop 0" and "after µop 1". Now the RAT after the group is copied into every bit as it is, and a checkpoint of µop 0 keeps an undo of µop 1 (11 bits). No performance is lost.
  - The condition is that a checkpoint is not restored in the cycle after the renaming, which the pipeline always meets.
  - The alternative "at most one checkpoint a cycle" was −1.7% / −2.0% in the model, so it was not taken.
- **The rules that allow fewer wakeup buses**: they go into the specification as rules of dispatch.
  - ALU1 issues latency 1 only; a multiply is dispatched as "ALU0 only".
  - The LSU writes a register only for a load.

**The Vivado results of 8.4** (physical LUTs)

| Block | Before | Now |
|---|---|---|
| Two-stage ALU | 7,879 / −0.696 ns | **3,133 / +0.512 ns** (closes) |
| uBTB | 3,132 / −24.5 ns | **910 / +5.10 ns** |
| Fusion | 172 | **215 / +10.1 ns** |
| Register file | 4,942 (96 registers) | **2,503 / +7.92 ns** (64 registers) |

- The 64-register file is about half because it fits the 64-deep LUT RAM in one level.
- **The measured blocks total about 14k to 16k, inside the out-of-order budget (16k to 18k)** (36k to 40k last time). The issue queue and renaming are estimates from Yosys. The ROB, LSU and decode are not counted yet, so the budget revision at G0 is still needed.
- The ALU is 3.1k per port, 0.6k over the 2.5k target. The next candidate is an asymmetric ALU with a simpler ALU1, but the first halves of fused pairs are often Zbb-type operations, so the model checks the effect first.

**Noticed along the way**

- **A gap in the fusion harness**: the OOC_FUSE harness did not connect the `alu2ok` input added last time. It was fixed before this OOC_FUSE run started, so the 215 LUTs include `alu2ok`.
- **Swapping the RTL in**: Vivado reads all the RTL at every run, so the work was done on a copy and swapped in after the tests passed.

The next Vivado runs (issue queue and renaming):

```
cd FPGA\OOO_OOC
synth_ooo.bat OOO_IQ
synth_ooo.bat OOC_RENAME
```
<!-- /answer -->

## 19. 2026-10-24 22:19:04 JST

```text
I ran synth_ooo.bat OOO_IQ and synth_ooo.bat OOC_RENAME. Please read the results and record them in section 10 of OOC_J.md.
```

<!-- answer -->
**Claude Code's answer**

(No answer in this turn. The same prompt was sent again as entry 20, and the answer is there.)
<!-- /answer -->

## 20. 2026-10-24 22:28:40 JST

```text
I ran synth_ooo.bat OOO_IQ and synth_ooo.bat OOC_RENAME. Please read the results and record them in section 10 of OOC_J.md.
```

<!-- answer -->
**Claude Code's answer**

I read the Vivado results of the issue queue and renaming and recorded them in 10.8 of OOC_J.md section 10 (English: OOC.md). Both close at 50 MHz and fit their size targets. Pushed to dev as `925552b`.

| Block | First version | Now | Register-to-register slack |
|---|---|---|---|
| Issue queue | 6,200 | **3,143** (−49%) | +5.07 ns (12 levels) |
| Renaming | 6,098 | **2,271** (−63%) | +9.60 ns (2 levels) |

- **Issue queue**: the worst wakeup-select path is 2.7 ns faster than in the previous version.
- **Renaming ran without its harness.** What ran was `OOO_RENAME`; what I asked for was `OOC_RENAME`, which puts flip-flops on the inputs and outputs (sorry for the confusing names). The result can be used as it is anyway.
  - The harness adds only flip-flops, so the LUT count is the same.
  - The worst path overall (+0.90 ns) is combinational from input to output, and it fits in the 8 ns left after the 6 ns input and output delays. In the core it gets a whole cycle (20 ns), so it closes with ample margin.

**Budget**: all measured blocks now have Vivado numbers, totalling **15,308 LUTs** (36k to 40k at first).

- Breakdown: ALUs (2 ports) 6,266, issue queue 3,143, renaming 2,271, register file 2,503, uBTB 910, fusion 215
- The out-of-order budget is 16k to 18k. But only 0.7k to 2.7k is left for the ROB, LSU, LQ / SQ, decode and front end, not written yet, so the budget revision at G0 (including the FPU of D3) is needed.

In the prompt log, entries 19 and 20 were the same prompt (sent again). I noted in 19 that its answer is in 20, and added the English for answer 18 and prompts 19 and 20.
<!-- /answer -->

## 21. 2026-10-24 22:37:08 JST

```text
I reran OOC_RENAME; please check it.
```

<!-- answer -->
**Claude Code's answer**

I checked the rerun of OOC_RENAME. It is a fresh result (22:34), the log has no errors, and it closes at 50 MHz.

| Run | LUT | FF | Worst register to register |
|---|---|---|---|
| OOO_RENAME (no harness, last time) | 2,271 | 2,151 | +9.598 ns |
| **OOC_RENAME (with the harness, now)** | **2,267** | 2,296 | **+8.912 ns** (4 levels) |

- **LUTs**: about the same as without the harness; the difference of 4 is placement. The 145 more FFs are the harness's flip-flops on the inputs and outputs.
- **Worst path**: the restore (`restore_id` → checkpoint select → RAT), with +8.9 ns of slack.
- **The input-to-output path that was the concern last time** (the RAT and busy reads): inside the harness it is a register-to-register path and is not even among the 10 worst (+9 ns or more). As expected last time, it closes with ample margin.

I added the row with the harness to 10.8 of OOC_J.md / OOC.md and updated the total to **15,304 LUTs** with this value. The prompt log (answer 20 and the English of 21) is updated too. Pushed to dev as `16f28c5`.
<!-- /answer -->

## 22. 2026-10-24 22:39:35 JST

```text
Please go on to the G0 specification. Put together the freeze of the micro-architecture and the budget revision including the ROB, LSU and decode (and the FPU of D3).
```

<!-- answer -->
**Claude Code's answer**

I put the G0 specification together in [Doc/UARCH_J.md](../Doc/UARCH_J.md) (English: [Doc/UARCH.md](../Doc/UARCH.md)). The micro-architecture is frozen, but the budget does not close yet, so the proposed verdict is "a conditional pass, with the budget decided at G0b inside Phase 1". Pushed to dev as `c878b09`.

**Performance (the goals are met)**

| Configuration | `-O2` | Most optimization |
|---|---|---|
| **G0** | **6.56** | **6.80** |
| G0, pessimistic pipeline | 5.85 | 6.14 |
| G0 without fusion, pessimistic | 5.51 | 5.97 |

Only without fusion and with the pessimistic pipeline does the most optimization fall below 6.0. What keeps "above 6.0" safe against a slower pipeline is fusion.

**The frozen configuration**: 2-wide, 4-wide decode with fusion (2 sources and 1 write per pair), uBTB 16 + TAGE-S, ROB 24, issue queue 12, 64 physical registers, LQ / SQ 12, 6 checkpoints. The changes from before G0 (ROB 32 → 24, issue queue 16 → 12, checkpoints 8 → 6) cost −0.4% / −0.6% and save about 1k LUTs.

**Budget (does not close yet)**

| | LUT |
|---|---|
| Blocks measured in Vivado (with the G0 changes) | about 14.0k |
| Estimate of what is not written yet (front end, TAGE, decode, ROB, LSU, control) | 9.3k to 14.5k |
| Needed | 23.3k to 28.5k |
| Room (52k ceiling, group A included) | 16.4k to 17.9k |
| **Over** | **5.4k to 12.1k (about 8.8k in the middle)** |

**Reconsidering D3 (FPU) found a wrong premise.** In mmRISC-2's measurements the multi-cycle FPU (9,757 LUTs) is larger than the pipelined one (9,060), so going back to multi-cycle frees nothing. FPU_PIPE stays; its breakdown (C1) is measured first, then sharing the multiplier (C2) and moving the rare operations to an iterative unit (C3) are considered (1.5k to 3k).

**Closing the gap** (section 6, in the recommended order)

- Without touching fusion, Ethernet or the ceiling: 4.4k to 7.1k: Linux-side reductions, the FPU, three small structures (−0.7% or less each), asymmetric ALUs. At the low end of the estimate this is enough.
- In the middle of the estimate, fusion level 2 (only ALU + ALU out, −3.4% / −0.7%) and raising the ceiling to 54k are needed as well.
- No fusion (−7.8% / −4.3%) and no Ethernet are the last resort. Fusion is efficient in performance per 1k LUTs, so it comes last.

The spread of the estimate for the blocks not yet written (±2.6k) is as large as most levers, so measuring it first is the point of G0b. Phase 1 starts with the lock-step framework and the RTL and Vivado measurements of the front end, decode, ROB and LSU. What I ask of the author is to measure the FPU breakdown (C1) in parallel.

The model runs are reproduced by `Plan/model/g0.sh` (results in `results/g0.txt`). STRATEGY, ISSUES, REDUCE and the READMEs are updated for G0.
<!-- /answer -->

## 23. 2026-10-24 23:38:35 JST

```text
I want to keep Zbc of L2. As a principle I want to keep the instruction set. Everything else, let's go as recommended.
```

<!-- answer -->
**Claude Code's answer**

(No summarizing answer in this turn: the PC was rebooted in the middle of the work. The decisions had been recorded in UARCH section 9 and elsewhere and pushed in commit `634b9c4`, and step 1 of Phase 1 (the lock-step framework) had just begun. The work continued in entry 24.)
<!-- /answer -->

## 24. 2026-10-25 00:07:41 JST

```text
The PC was behaving strangely, so I rebooted it. Please continue the work.
```

<!-- answer -->
**Claude Code's answer**

I resumed the work after the reboot. But **the usage limit was reached, so I stop here**.

**Done**

- **The G0 decisions recorded**: Zbc stays, and as a principle the instruction set is kept. Everything else is as recommended, and G0 passed with a condition (commit `634b9c4`).
- **Step 1 of Phase 1: lock-step comparison (`SIM/LOCKSTEP`)**. Pushed as commit `87cbbc6`.
  - Every instruction the core commits is compared with Spike, one at a time. Spike is used as a library, set to the instruction set and PMP of mmRISC-2.
  - Compared: PC, instruction, the register written and its value, stores, traps and their cause
  - The first half of a fused pair whose result is not written is compared by its PC and instruction only.
  - Self-test: with a second Spike standing in for the core, on 175 riscv-tests. No mismatch, and all 3,500 deliberately injected errors were caught at the very place they were injected. Only ma_data and amocas end with a nonzero exit code, as expected in mmRISC-2 too.
- Prompt log: a note on entry 23, cut off by the reboot, and the English of entry 24.

**Left**

- **CoreMark, open**: the two CoreMark builds pass the comparison. But on this reference CoreMark prints only "2" and exits with 37, and the cause is not known yet. I think a CSR or device missing from the reference is the cause. It is recorded as open in the README.
- After that, step 2 of Phase 1: the RTL and Vivado measurements of the front end, decode, ROB and LSU. In parallel I ask the author for the Vivado run of the FPU breakdown (C1).

Also: the `find /` (a search of the whole file system) I ran in the previous turn reached into the shared folder and may have caused the PC's trouble. From now on I search in named places only, and recorded that in memory.
<!-- /answer -->

## 25. 2026-10-25 02:01:28 JST

```text
I was reset, so please continue.
```

<!-- answer -->
**Claude Code's answer**

I solved the CoreMark problem left last time, and **step 1 of Phase 1 (lock-step comparison) is done**. Pushed to dev as `0e97174`.

**The exit code 37 came from the checker, not from CoreMark.**

- One character written through HTIF has the form `(1 << 56) | (1 << 48) | character code`. The checker looked at bit 0 before the device number, so a character with an odd code was taken for an "exit".
- "2" (0x32, even) was printed, the next "K" (0x4B, odd) was taken as the exit, and the exit code became 37 (0x25).
- Now the device number is checked first. Both CoreMark builds run to the end and print what running `spike` directly printed in Phase 0. The "Errors detected" in the output is only because 10 iterations fall short of the 10 seconds CoreMark asks for, the same as in Phase 0.

**Results of the self-test** (`SIM/LOCKSTEP/run_selftest.sh`, PASS)

| Target | Result |
|---|---|
| 175 riscv-tests | No mismatch. All 3,500 deliberately injected errors caught at the very place injected |
| 2 CoreMark builds (about 3 million instructions each) | No mismatch, exit code 0. All 20 injected errors caught |
| Tests ending with a nonzero code | Only ma_data and amocas (the ones expected to fail in mmRISC-2 too) |

Step 1 is marked done in UARCH section 8, and the prompt log (answer 24 and the English of 25) is updated.

Next is step 2 (RTL and Vivado measurements of the front end, decode, ROB and LSU), to narrow the spread of the estimates with measurements for the budget decision at G0b. For the FPU breakdown (C1) I first need to prepare an OOC script that synthesizes FPU_PIPE in parts, so I will make it together with step 2.
<!-- /answer -->

## 26. 2026-10-25 10:17:51 JST

```text
Please go on to step 2 of Phase 1. Start with the LSU (LQ / SQ and forwarding), whose estimate has the widest spread, and prepare its unit test and Vivado scripts. If you also make the OOC script for the FPU breakdown (C1), I will run it in Vivado.
```

<!-- answer -->
**Claude Code's answer**

As the first part of step 2 of Phase 1, I prepared the LSU's RTL, unit test and Vivado scripts, and the OOC script for the FPU breakdown (C1). Pushed to dev as `d44b69a`. The instruction given midway, "instruction tests with riscv-arch-test from now on", is recorded in UARCH and STRATEGY. riscv-arch-test is fetched to `~/RISCV/riscv-arch-test`; setting it up is a separate piece of work after the LSU.

**LSU (`RTL/CPU/OOO/OOO_LSU`)**

- **Structure**: LQ 12 / SQ 12. A load forwards from the youngest older matching store when that store covers its data. Ordering is conservative, with `lsu_st_known` given out for the issue queue. On a miss or a wait it raises `ld_cancel` and returns the result later. Recovery works both to a checkpoint (`restore`) and to the committed state (`flush_all`).
- **D$**: the port is abstract; the adapter to mmRISC-2's D$ sits outside.

**Verification (`tb_lsu.cpp`)**

The test bench plays the rest of the core. It makes a random instruction stream with reordered issue, D$ misses, branch mispredictions and exceptions, and checks every load's value against the program-order answer.

- **Result**: 2.1 million cycles over 7 seeds, all PASS.
- **Three RTL bugs found by the test** (all fixed):
  1. Counting from the SQ head wrapped at 16 (the queue is 12)
  2. A load in M in a cycle of recovery was lost
  3. The D$ fill of a flushed load was taken by a later owner of the same LQ entry. Fixed by adding `dc_kill`
- **Bug injection**: 11 added, all detected (50 in all). The injection showed the epoch bit redundant, so it was removed. One that was at first not detected was a hole in the test, so the D$ model was fixed.

**Size**: the LSU is 4,768 LUTs in Yosys, about 2.9k to 3.6k expected in Vivado. Even without the D$ adapter it is near the top of the G0 estimate (2.5k to 3.5k, adapter included). Putting the SQ data and LQ addresses in LUTRAM should save a few hundred LUTs.

**What the specification was missing** (found writing the LSU; recorded in UARCH)

- **Going back to the committed state**: a full flush for exceptions and the like needs the committed RAT and the committed head of the free list. Renaming gets them (about 0.3k LUTs).
- **Holding back dependents when a load misses**: the way to hold back dependents already woken (replay) must be decided before the core is put together.

**Vivado runs asked**

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_LSU
cd ..\FPU_C1
synth_fpu_c1.bat
```

`synth_fpu_c1.bat` reads the neighbouring mmRISC-2 tree as `..\..\..\mmRISC-2`. If it is elsewhere, set `MMRISC2=<path>` first. The result goes to `output\FPU_C1\breakdown.txt`, as LUT counts per register group.
<!-- /answer -->

## 27. 2026-10-25 10:18:39 JST

```text
Also, from now on please do the instruction tests with riscv-arch-test.
https://github.com/riscv/riscv-arch-test
```

<!-- answer -->
**Claude Code's answer**

(A prompt sent in the middle of the turn of entry 26. Its answer is part of the answer of entry 26.)
<!-- /answer -->

## 28. 2026-10-25 11:09:39 JST

```text
I ran synth_ooo.bat OOC_LSU and synth_fpu_c1.bat. Please read the results and record them.
```

<!-- answer -->
**Claude Code's answer**

I read the two results and recorded them in 11.5 to 11.6 of OOC_J.md / OOC.md. The LSU's size is inside the estimate, but it fell 4 ns short of 50 MHz, so I rewrote it right away. Pushed to dev as `6e456de`.

**LSU (OOC_LSU)**

| | LUT | Register-to-register slack |
|---|---|---|
| First version | **2,912** (estimate 2.5k to 3.5k, adapter included) | **−4.019 ns** (29 levels) |

It did not close because three things were in series. As with the uBTB, a serial choice was the main cause.

1. The SQ boundary was computed from the load's LQ number
2. The youngest matching store was chosen by a loop comparing with "the best so far" (a chain of compares, about 15 ns)
3. Whether the write port went to a fill or to the load waited for the result of the search

What was rewritten:

- **A mask of older stores**: each LQ entry keeps the SQ entries older than it as a bit mask. The boundary arithmetic goes.
- **An age matrix of the SQ**: the youngest match comes out as a one-hot select in two levels.
- **Write-port priority**: whenever a load is in M, the port always goes to M. The choice no longer waits for the search.

After the rewrite all 7 seeds still PASS, and all 14 LSU mutations are detected (53 in all). In Yosys 4,768 → 4,292 LUTs, about 2.6k expected in Vivado. The test bench had one place where it crashed on an RTL error; it now reports it instead of crashing.

**FPU breakdown (C1)**: FPU_PIPE is 9,060 LUTs, the same as mmRISC-2's measurement.

| Function | LUT |
|---|---|
| FMA datapath (alignment 1.5k, normalization 1.2k, add 0.8k, others) | about 4.3k |
| Divide / square root (iterative) | about 1.3k |
| Rounder | 1.0k |
| Other operations (compares, min / max, sign, classification and so on) | 0.86k |
| Second half of the float-to-integer conversion | 0.34k |

- **The FPU levers turned out smaller than thought.** The multiply is mostly DSPs, so sharing the multiplier (C2) saves about 0.3k LUTs. Moving the rare operations to an iterative unit (C3) saves about 0.7k to 0.9k. Together about 1.0k to 1.3k, less than the 1.5k to 3k assumed at G0.
- Reflecting this, I updated the outlook for closing the gap in UARCH 6.2. The levers usable without touching fusion, Ethernet or the ceiling come to 3.6k to 4.8k; closing the middle of the estimate (8.8k over) needs fusion level 2 and raising the ceiling to 54k, or more.
- The FMA datapath (about 4.3k) is the double-precision FMA itself, the part kept for performance.

**The next Vivado run** (checking the rewritten LSU):

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_LSU
```
<!-- /answer -->

## 29. 2026-10-25 11:47:56 JST

```text
I reran synth_ooo.bat OOC_LSU. Please read the result and record it.
```

<!-- answer -->
**Claude Code's answer**

I read the result of the rerun and recorded it in 11.7 of OOC_J.md / OOC.md. The previous rewrite took the shortfall from 4 ns down to 0.35 ns. It is still a little short, so I fixed the remaining path as well. Pushed to dev as `96d9f5f`.

| Run | LUT | Register-to-register slack | Logic levels |
|---|---|---|---|
| First version | 2,912 | −4.019 ns | 29 |
| Previous rewrite (this run) | **2,943** | **−0.352 ns** | 25 |

The size is about the same and stays inside the estimate.

**The remaining path**: from an LQ valid bit to a store's write into the SQ.

1. The choice of the load to try again was once more a loop keeping "the oldest so far", in series
2. Its result chose E's address (a new µop, or a load tried again)
3. A store's misaligned check waited for that choice

A store never comes from a retry, so this was a path with no need to wait.

**What was fixed**

- **The retry choice a cycle ahead**: a waiting entry is chosen by a parallel priority select and put in a register. E only checks with bits that it is still valid and waiting. Retries are rare and any order is correct, so there is no effect on performance.
- **The misaligned check per source**: the issued µop's straight from its address, a retried load's from the LQ, chosen afterwards.

The test PASSes on 7 seeds. One bug injection was added for the new mechanism, and all 15 LSU ones are detected (54 in all).

The next Vivado run (checking the fixed LSU):

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_LSU
```
<!-- /answer -->

## 30. 2026-10-25 12:07:09 JST

```text
I reran synth_ooo.bat OOC_LSU. Please read the result and record it.
```

<!-- answer -->
**Claude Code's answer**

**The LSU closes at 50 MHz.** Recorded in 11.8 of OOC_J.md / OOC.md and pushed to dev as `4ad3206`.

| Run | LUT | Register-to-register slack | Logic levels |
|---|---|---|---|
| First version | 2,912 | −4.019 ns | 29 |
| First rewrite (mask of older stores, age matrix, write-port priority) | 2,943 | −0.352 ns | 25 |
| **Second fix (the retry choice a cycle ahead, the misaligned check per source)** | **2,969** | **+6.265 ns** | 13 |

- The worst path now is aligning and sign-extending the result of the load in M into `wb_data`, with more than 6 ns of slack.
- 2,969 LUTs. With the D$ adapter (about 0.3k to 0.6k expected) about 3.3k to 3.6k, at the top of the G0 estimate (2.5k to 3.5k, adapter included).

**Effect on the budget** (a row added to UARCH 4.4)

With the LSU measured and the committed-state RAT found while writing the LSU (about 0.3k), the gap widens a little:

| | Low | Middle | High |
|---|---|---|---|
| At G0 | 5.4k | 8.8k | 12.1k |
| **Now (2026-10-25)** | **6.5k** | **9.5k** | **12.5k** |

The blocks not written yet are the front end, TAGE, BTB / RAS, decode, the ROB and control, whose estimates still have their spread. The way forward is unchanged: measure the rest and decide the levers at G0b.
<!-- /answer -->

## 31. 2026-10-25 12:24:35 JST

```text
As the next block of step 2, please go on with the ROB and renaming with the committed-state RAT added. Prepare the unit tests and Vivado scripts too.
```

<!-- answer -->
**Claude Code's answer**

As the second block of step 2, I made the ROB and the committed state of renaming (the committed-state RAT), with unit tests and Vivado scripts. The record is in section 12 of OOC_J.md (English: OOC.md), pushed to dev as `f7435e5`.

**ROB (`RTL/CPU/OOO/OOO_ROB`)**

- **Structure**: 24 µops, 2 in and 2 committed a cycle.
  - The payload (pc, destination, new and old physical registers and so on) is in LUTRAM split in two by the parity of the index. Two consecutive entries always fall in different banks, so each bank needs one write and one read.
  - Done and exception are flip-flops, written by 4 completion ports.
- **Branch mispredictions**: with two in a cycle the older is chosen; `restore` is given and the tail cut back to just after that branch.
- **The head**: an exception at the head becomes a trap with a full flush. A µop that runs only at the head, such as a CSR instruction, is told by `head_ns` that it may run.

**The committed state of renaming**: a RAT written at commit and the committed head of the free list are added; `flush_all` goes back to that state. This was missing from the G0 specification.

**Verification**

- **`tb_rob` (new)**: checked against a reference ROB every cycle, with out-of-order completion, two mispredictions at once, completions for indices not in the ROB, and dispatch in cycles of trap or restore. All PASS on 4 seeds (1.6 million cycles in all).
- **`tb_rename`**: commits and `flush_all` added; PASS (909 flushes).
- **Bug injection**: of the 12 added, 4 were not detected at first. All four turned out to be redundant logic, so they were taken out of the RTL. For example, clearing every busy bit on a flush is not needed, since the registers of the committed state have busy at 0 already. The remaining 8 are all detected (62 in all).

**Size** (Yosys)

| Block | Yosys | Expected in Vivado | G0 estimate |
|---|---|---|---|
| ROB | 1,446 LUTs + 80 LUTRAM | about 1.0k to 1.2k | 0.7k to 1.2k |
| Renaming | 3,216 → 3,769 | about 2.6k to 2.7k (about +0.4k) | +0.3k for the committed state |

The number of checkpoints is 6 at G0, but the RTL's renaming keeps 8, because its ring of numbers assumes a power of two. Whether to go to 6 is decided when the core is put together; in the model 8 → 6 is −0.3% / −0.5%.

**Vivado runs asked**:

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_ROB
synth_ooo.bat OOC_RENAME
```
<!-- /answer -->

## 32. 2026-10-25 14:04:50 JST

```text
I ran synth_ooo.bat OOC_ROB and synth_ooo.bat OOC_RENAME. Please read the results and record them.
```

<!-- answer -->
**Claude Code's answer**

I read the two results and recorded them in 12.6 of OOC_J.md / OOC.md. Renaming came out as expected, but the ROB came out large because of how it was written, so I fixed it. Pushed to dev as `3e7384c`.

| Block | LUT | LUTRAM | Register-to-register slack |
|---|---|---|---|
| Renaming (with the committed state) | **2,624** (+357) | 0 | +9.905 ns |
| ROB | **5,173** | **0** | +7.018 ns |

- **Renaming**: the committed state added 357 LUTs, as expected (+0.3k to 0.4k). It has plenty of margin at 50 MHz.
- **The ROB closes, but its payload became flip-flops instead of LUTRAM.** Each bank was written by two statements, "slot 0 writes" and "slot 1 writes", so Vivado took them for two write ports and did not use LUTRAM, which has one write. In fact the two never write the same bank in the same cycle, but Vivado cannot see that (Yosys could, which is why the estimate had LUTRAM).
- **What was fixed**: one write per bank, with the writing slot chosen first. The test PASSes on 4 seeds. One bug injection that breaks this choice was added, and all 8 ROB ones are detected (63 in all).

The next Vivado run (checking the fixed ROB; about 1.0k to 1.2k expected):

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_ROB
```
<!-- /answer -->

## 33. 2026-10-25 14:20:56 JST

```text
I reran synth_ooo.bat OOC_ROB. Please read the result and record it.
```

<!-- answer -->
**Claude Code's answer**

**The fixed ROB is inside the estimate.** Recorded in 12.7 of OOC_J.md / OOC.md and pushed to dev as `67e6150`.

| Run | LUT | of it LUTRAM | Register-to-register slack |
|---|---|---|---|
| First version | 5,173 | 0 | +7.018 ns |
| **Fixed version** | **1,073** | 160 | **+11.060 ns** |

The payload is in LUTRAM now, 4,100 LUTs fewer. It is within the G0 estimate (0.7k to 1.2k), with plenty of margin at 50 MHz.

**Effect on the budget** (a row added to UARCH 4.4)

With the ROB and the renaming with its committed state (2,624) replaced by measurements, the gap becomes:

| | Low | Middle | High |
|---|---|---|---|
| At G0 | 5.4k | 8.8k | 12.1k |
| After the LSU was measured | 6.5k | 9.5k | 12.5k |
| **After the ROB and renaming were measured** | **7.2k** | **9.9k** | **12.7k** |

It widened mainly because the committed state of renaming came in, and because the checkpoints were measured at 8. G0 counted 6; going to 6 saves about 0.25k.

Every block measured so far (ALU, uBTB, fusion, register file, issue queue, renaming, LSU, ROB) closes at 50 MHz. What remains is the front end (fetch, fetch buffer, TAGE, BTB / RAS), decode and control, where the spread of the estimates still lies.
<!-- /answer -->

## 34. 2026-10-25 14:32:31 JST

```text
As the next block of step 2, please go on with fetch and the fetch buffer. Prepare the unit tests and Vivado scripts too.
```

<!-- answer -->
**Claude Code's answer**

I wrote the fetch buffer (`OOO_FBUF`) and the FTQ (`OOO_FTQ`). Both unit tests PASS, and all 16 mutations added are detected. The Vivado scripts are ready, and everything is pushed to dev (bb06c8c). Vivado has not been run yet.

**What I wrote**
- **[OOO_FBUF.sv](../RTL/CPU/OOO/OOO_FBUF/OOO_FBUF.sv)**
  - Instead of UARCH's "ring of 16 parcels", a queue of 4 whole 16-byte blocks.
  - A ring needs a select in front of every parcel; a block queue needs one only at the exit, and the data goes into LUTRAM.
  - Up to 4 instructions a cycle come out of a window of 8 parcels over the head block and the next. 32-bit instructions across blocks are handled.
- **[OOO_FTQ.sv](../RTL/CPU/OOO/OOO_FTQ/OOO_FTQ.sv)**
  - 8 entries in LUTRAM. Each holds the PC, the next address, the taken parcel and 32 bits of predictor state.
  - Two reads for decode and one for branch resolution.
  - pop at commit, restore on a misprediction, and flush_all.

**Verification**
- `tb_fbuf`: a random program runs with random taken transfers, and the run is cut into blocks as fetch would. Every slot's contents and the exact number of instructions given are checked every cycle. PASS on 9 seeds.
- `tb_ftq`: against a reference queue, PASS on 4 seeds. With the existing ones, all 10 tests PASS.
- The tests found two RTL bugs: popping from an empty queue, and not setting the head parcel when a block went into an empty queue. Both fixed.
- 16 mutations added, all detected (79 in all). The two not detected at first were both redundant conditions: stopping the write during flush or restore, which in fact only writes a free slot. They were removed.

**Size (Yosys estimate)**

| Block | Physical LUTs | G0 estimate |
|---|---|---|
| OOC_FBUF | about 1.56k (LUT 1,381 + LUTRAM 176) | the buffer 1.3k to 1.8k |
| OOC_FTQ | about 0.24k (LUT 15 + LUTRAM 224) | within the fetch's 2.0k to 2.8k |

- In the OOC_FBUF harness, decode takes all the instructions given unless it is stalled. That measures the very loop the core will have: state → window → instruction lengths → count taken → head pointer.

Recorded in `Plan/OOC.md` section 13 (and the Japanese version), the fetch rows of `Doc/UARCH`, and the RTL READMEs.

**Request**: please run these two in Vivado.
```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_FBUF
synth_ooo.bat OOC_FTQ
```

The rest of the fetch budget (PC generation, the I$ interface, predecode) is written together with TAGE, BTB and RAS.
<!-- /answer -->

## 35. 2026-10-25 15:16:49 JST

```text
I ran FBUF and FTQ in Vivado.
```

<!-- answer -->
**Claude Code's answer**

(No answer was recorded: the safety check returned no verdict and the turn stopped. Reading the Vivado results and the fix are in the answer to 36.)
<!-- /answer -->

## 36. 2026-10-25 15:25:30 JST

```text
Please try again
```

<!-- answer -->
**Claude Code's answer**

I tried again, but the shell is still unusable. The safety check returns no verdict, so even a simple command like `ls` is stopped. The FBUF fix is neither tested nor committed.

**Vivado results** (recorded in `Plan/OOC.md` 13.6, the Japanese version, and `Doc/UARCH`)

| Block | LUT | of it LUTRAM | FF | Register-to-register slack | Levels |
|---|---|---|---|---|---|
| OOC_FBUF | **931** | 192 | 323 | **+0.539 ns** | 16 |
| OOC_FTQ | **148** | 132 | 329 | +15.844 ns | 1 |

- Both are smaller than the Yosys estimates (1.56k → 931, 0.24k → 148) and well inside the G0 estimate.
- The FTQ has plenty of margin too.
- The FBUF closes at 50 MHz, but with only 0.539 ns. The worst path reads LUTRAM twice.
  - Path: `hb` → block data read → window → chain of instruction lengths → count taken → `npop` → read of `bs[hb+npop]` → `hoff`
  - In the core, place and route will be worse than alone, so this margin is too thin.

**Fix (written, not run yet)**
- In [OOO_FBUF.sv](../RTL/CPU/OOO/OOO_FBUF/OOO_FBUF.sv), every candidate for the next head parcel is ready before `npop`, and `npop` only selects among them.
  - The four candidates: further into the head block, into the next block, the start of the block after it (a third read port), the block coming in.
  - The end of the path loses a LUTRAM read and a LUT, about 2 ns.
- I checked by reading the code, case by case of `npop`, that it gives the same values as before. Not yet by the tests.
- Three mutations rewritten for the new code, and one (M86) added.
- The contract for the core is recorded too: decode's count taken comes only from the buffer's own valid instructions and a registered stall.

When the shell is back, in this order:
1. lint, `tb_fbuf` (9 seeds), all 10 tests
2. the FBUF mutations
3. commit and push

Then please rerun `synth_ooo.bat OOC_FBUF`.
<!-- /answer -->

## 37. 2026-10-25 15:29:36 JST

```text
Please try again. Go on through the tests, the bug injection, commit and push.
```

<!-- answer -->
**Claude Code's answer**

I tried again, and again it could not run. The safety check returns no verdict, so not only Bash but also running from the terminal panel is stopped. The FBUF fix is as written; no tests, bug injection or commit yet.

The checks are in one script:

```bash
bash SIM/OOO_UNIT/obj_dir/fbuf_check.sh
```

Please run it at the top of the repository. It does four things:
- lint of `OOO_FBUF.sv`
- all 10 tests (`run.sh`)
- `tb_fbuf` on 8 seeds
- the 12 FBUF mutations (M70 to M80 and M86)

The results go into `SIM/OOO_UNIT/obj_dir/fbuf_check.txt`. Reading files works without the check, so tell me when it has run and I will read and judge it.

If all is well, I commit and push as soon as the shell is back: the fix, `mutate.py`, `OOC 13.6`, `UARCH`, the prompt log. Then please rerun `synth_ooo.bat OOC_FBUF`.

If you switch the permission mode away from auto in the settings, I may be able to run it myself.
<!-- /answer -->

## 38. 2026-10-25 15:31:39 JST

```text
I ran fbuf_check.sh. Please read obj_dir/fbuf_check.txt, and if there is no problem go on through commit and push.
```

<!-- answer -->
**Claude Code's answer**

Thank you for running it, but the result file `SIM/OOO_UNIT/obj_dir/fbuf_check.txt` is not there. The script seems not to have run in this repository. The work folder of M86, the mutation just added, is missing too, so it did not run partway either. Most likely it was run from a folder other than the top of the repository, and the relative path `bash SIM/OOO_UNIT/...` found no file.

With the absolute path it runs from anywhere:

```bash
bash /media/psf/Home/Documents/CQ/RISCV/mmRISC/mmRISC-3/SIM/OOO_UNIT/obj_dir/fbuf_check.sh
```

It runs all the tests and 12 mutations, so it takes several minutes to a quarter of an hour.

The `/auto-mode-setup` settings went in, but the safety check on my side still returns no verdict, and both Bash and reading the terminal stay stopped. If you switch the permission mode away from auto (to approval), I can run it myself without this check and go on through commit and push.
<!-- /answer -->

## 39. 2026-10-25 15:35:45 JST

```text
I reran fbuf_check.sh with the absolute path. Please read fbuf_check.txt, and if there is no problem go on through commit and push.
```

<!-- answer -->
**Claude Code's answer**

I checked `fbuf_check.txt`, found no problem, and committed and pushed the FBUF fix to dev (e668be9). The slack of the new path has not been measured in Vivado yet.

**Results of the check**
- No lint warnings.
- All 10 unit tests PASS, and `tb_fbuf` PASSes on 9 seeds.
- In the first run of the bug injection, 11 were detected and 1 (M80) was not applied.
  - Rewriting the npop line had removed the text M80 replaces.
  - I fixed its definition and reran it; M80 is detected too. All 12 FBUF mutations are detected (80 in all).
- The shell came back partway, so I reran M80 and did the commit and push myself.

**What was committed**
- The fix to `OOO_FBUF.sv`: the candidates for the next head parcel are read before `npop`, which only selects among them.
- `mutate.py`, `Plan/OOC` 13.6, `Doc/UARCH`, the RTL READMEs (all in both languages).
- The Vivado reports of OOC_FBUF and OOC_FTQ.
- The prompt log (English for 35 to 39). 35 has a note that no answer was recorded, since the turn stopped on the safety check's failure.
- The temporary `fbuf_check.sh` was removed.

**Request**: please rerun `synth_ooo.bat OOC_FBUF`. The size should hardly change, and the slack should grow by about 2 ns from +0.539 ns.
<!-- /answer -->

## 40. 2026-10-25 16:00:46 JST

```text
I ran synth_ooo.bat OOC_FBUF.
```

<!-- answer -->
**Claude Code's answer**

The fetch buffer rerun widened the slack from +0.539 ns to **+3.541 ns**. The size, 940 LUTs, hardly changed.

| Run | LUT | of it LUTRAM | FF | Register-to-register slack | Levels |
|---|---|---|---|---|---|
| OOC_FBUF (first version) | 931 | 192 | 323 | +0.539 ns | 16 |
| **OOC_FBUF (fixed)** | **940** | 192 | 323 | **+3.541 ns** | 14 |

- **The slack grew by 3.0 ns**, more than the 2 ns or so expected, for only 9 more LUTs (the third port reading the block starts).
- **The worst path is now the loop itself.** It starts and ends at the head pointer `hb`, and the second LUTRAM read is gone.
  - Path: `hb` → block data → window → chain of instruction lengths → count taken → `npop` → `hb`
  - What remains is the window and the length chain; 79 % of the delay is routing.
- **Budget**: the fetch buffer and the FTQ together come to about 1.09k (940 + 148).
  - The fetch row of UARCH 4.3 (2.0k to 2.8k) also holds PC generation, the I$ interface and predecode, not written yet.
  - So the gap in 4.4 is left as it is until the whole fetch is measured.

Recorded in `Plan/OOC.md` 13.7 (and the Japanese version) and the fetch rows of `Doc/UARCH`, with the English of the prompt log (answer 39 and prompt 40). Pushed to dev (cfc712f).
<!-- /answer -->

## 41. 2026-10-25 16:16:40 JST

```text
Please lay out the work from here on.
```

<!-- answer -->
**Claude Code's answer**

I laid out the work up to G1 from the steps of `Doc/UARCH.md` section 8, the budget table of 4.3 and the open items of `Plan/OOC.md` 11.4. We are now in the second half of step 2 (the RTL block by block).

#### Done so far
- **Step 1**: the lock-step checker (`SIM/LOCKSTEP`).
- **Blocks of step 2 measured**: ALU2, uBTB, fusion, PRF, IQ, renaming (with the committed state), LSU, ROB, fetch buffer, FTQ. All close at 50 MHz.
- **Step 2'**: the FPU breakdown (C1).

#### Work left

**A. The remaining blocks of step 2** (each with unit tests, bug injection and Vivado scripts)

| # | Block | G0 estimate | Content |
|---|---|---|---|
| A1 | The rest of the front end | about 2.1k to 3.9k | PC generation and redirects (F0), I$ interface, predecode, TAGE-S logic (tables in BRAM), BTB, RAS 16 |
| A2 | Decode × 4 and RVC expansion × 4 | 1.0k to 1.6k | Takes the FBUF's output and feeds the measured fusion block |
| A3 | D$ adapter | 0.3k to 0.6k | Connects the LSU to mmRISC-2's D$ |
| A4 | Issue-queue payload | 0.4k to 0.7k | LUTRAM, 2 writes / 3 reads |

- A1 has the widest estimate (about 1.8k), so as with the LSU I recommend measuring it first.
- A1 also checks the timing of the F0 loop (uBTB → next PC).

**B. To decide before assembling the core**
- **B1 How to stop the dependents of a missing load (the replay policy)**: the biggest design decision left open in 11.4.
  - It will likely add the cancellation of speculative wakeups to the issue queue, which changes the size and timing of the measured `OOO_IQ`.
  - So it should be decided well before assembly, at the latest before G0b.
- **B2 Checkpoints 8 → 6**: the RTL has 8 now. 6 saves about 0.25k, −0.3 % / −0.5 % in the model. It can be decided at G0b.

**C. In parallel**
- **C1 Step 2''**: give the model the kind of operation per instruction, to measure L7 (asymmetric ALUs, −0.7k to −1.0k). Needed before G0b.
- **C2 riscv-arch-test setup**: `~/RISCV/riscv-arch-test` is cloned. Building the tests and running them through Spike and the lock-step checker can be done now, without the core.

**D. Step 3: G0b (the budget gate)**
- Once A1 to A4 are measured, rebuild the tables of 4.3 and 4.4.
- The gap is now about 9.9k in the middle.
- Then apply the levers of 6.2 in the decided order and let the author decide (L1 → L3 → L4 to L6 → L7 → L9 → L10 ...). No lever that removes instructions.

**E. Step 4: assembling the core** (M-mode, bare metal)
- Dispatch, branch resolution and redirect, commit and exceptions, MDU, minimal CSRs (estimate 1.5k to 2.5k).
- Checked by riscv-arch-test and the lock-step checker; CoreMark in simulation compared with the model.

**F. Step 5: G1**
- CoreMark in simulation within ±5 % of the model.
- The whole core synthesized OOC in Vivado: LUTs and 50 MHz.

#### Recommended order
1. **A1 the rest of the front end**: the widest budget, and the F0 timing.
2. **B1 the replay policy**: decide it in the documents, add the cancellation to `OOO_IQ`, measure again.
3. **A2 decode**, **A3 D$ adapter**, **A4 IQ payload**.
4. **C1 operation kinds in the model**, at the same time as A2.
5. **D G0b**, the author's decision.
6. **E assembly**, with C2 (riscv-arch-test) ready before it.
7. **F G1**.

The Vivado runs of A1 to A4 and B1 are each asked of the author.

The English of the prompt log (answer 40 and prompt 41) is added but not committed yet; it goes in with the next block.
<!-- /answer -->

## 42. 2026-10-25 16:20:52 JST

```text
As recommended, please go on next with the front end (PC generation, the I$ interface, predecode, TAGE-S, BTB, RAS). Prepare the unit tests and Vivado scripts too.
```

<!-- answer -->
**Claude Code's answer**

I wrote the front end: PC generation, the I$ interface, predecode, TAGE-S, BTB and RAS. All 15 unit tests PASS, and all 42 mutations added are detected (122 in all). The Vivado script is ready, and everything is pushed to dev (299588c). Vivado has not been run yet.

#### Measured first: TAGE-S per block
The block-RAM tables are read in F1 with the fetch address only, before predecode has found the branches. So predicting one branch at a time as the model does cannot be built. I compared per-block forms on CoreMark's conditional branches.

| Predictor | -O2 | max. optimization |
|---|---|---|
| The model (per branch) | 0.761 % | 0.683 % |
| Per block, 2 slots | 0.808 % | **1.303 %** |
| **Per block, 3 slots** (the realistic case, history lagging 2 blocks) | 0.821 % | 0.845 % |

- With 2 slots, the maximum-optimization build has many blocks with a third branch, and accuracy drops. 3 slots fix it, and no branch ever reaches a 4th slot.
- Against the model, the cost is estimated at about −0.2 % / −0.5 %.
- The periodic halving of the useful counters has no effect, so it is left out: no scan of every row is needed.

#### The blocks
- **`OOO_PREDEC`**: instruction boundaries and the kind of control transfers; the targets of branches and jal from 8 adders in parallel.
- **`OOO_BTB`**: since predecode gives the direct targets, it holds **indirect jumps only**; 256 rows in block RAM.
- **`OOO_TAGE`**: 4 tables of 1024 rows, each row with direction counters for 3 slots; updated at commit from 270 bits of metadata kept in the FTQ.
- **`OOO_RAS`**: 16 entries, recovered from per-block snapshots.
- **`OOO_FETCH`**: the F0–F2 control, with the uBTB inside.
  - The I$ is handled with the timing of mmRISC-2's ICACHE.
  - Requests go out only as far as the fetch buffer and the FTQ have room (credit).
  - When F2's decision differs from the uBTB, F0 starts again (override) and the uBTB is trained.
  - A 32-bit instruction across two lines is carried to the next block for predecode.

#### Found in verification
- Bug injection left 2 mutations undetected. Tracing them showed that the counter predicting a block's 4th or later conditional branch was never trained, so it was in effect "always taken".
- So a 4th or later branch is now predicted **not taken**, constantly. No branch in CoreMark gets that far. The test program got places with compressed branches packed densely.
- `tb_fetch` runs a random program along its true path. Every fetch address of every cycle and every block's decision (end, taken, next address, 270 bits of metadata, RAS snapshot) are checked against mirrors of the predictors. PASS on 11 programs.

#### Size (Yosys)
- `OOC_FRONT`: 5,884 LUTs + 116 LUTRAM, 6 block RAMs.
- Yosys has given 1.6 to 2.4 times Vivado's LUTs so far, so about 3k to 3.7k are expected in Vivado. The G0 estimate for this part is 3.0k to 4.8k.
- What worries me most is the timing of the F2 path (I$ data → predecode → first taken → compare with the next address → redirect).

#### Left for the core's assembly
- The state the FTQ keeps grows from 32 to 312 bits a block (about +0.2k), and it must also hold the outcomes of the slot branches.
- The I$ (mmRISC-2's ICACHE) is widened to 16 bytes; no kill is used.

Recorded in `Plan/OOC.md` section 14 (and the Japanese version), 3.2 and 4.3 of `Doc/UARCH`, the RTL READMEs, and `Plan/model/results/tageblk.txt`.

**Request**: please run this in Vivado.
```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_FRONT
```
<!-- /answer -->

## 43. 2026-10-25 17:28:39 JST

```text
I ran synth_ooo.bat OOC_FRONT.
```

<!-- answer -->
**Claude Code's answer**

The whole front end is **2,968 LUTs**, at the bottom of its estimate (3.0k to 4.8k) even with the uBTB. But the timing missed by **−0.162 ns (25 levels)**, so I fixed it. Pushed to dev (56e266a); whether it closes now waits for the rerun.

| Run | LUT | of it LUTRAM | FF | Block RAM | Register-to-register slack | Levels |
|---|---|---|---|---|---|---|
| OOC_FRONT | **2,968** | 106 | 2,538 | 5.5 tiles | **−0.162 ns** | 25 |

- **Size**: Vivado / Yosys was 0.50.
  - Vivado moved the logic of predecode and control into the instances next to it (u_ubtb grew from 910 alone to 1,565). So the breakdown by module means nothing; only the total counts.
  - Block RAM: 4.5 tiles for TAGE, 1 for the BTB.
- **Timing**: the worst path was the F2 override path I was worried about.
  - Path: the head request's address read from the queue's LUTRAM (1.4 ns) → predecode → slots → TAGE → first taken → target select → 38-bit compare with the next address (a carry chain, 1.7 ns) → into the uBTB's fetch address. 75 % of the delay is routing.

**Fixed** (two places)
- The head request's address is kept in a register of its own. The path now starts at a flip-flop, not at a LUTRAM read.
- The compare is taken out from behind the select. Every candidate (8 targets, the RAS top, the BTB, the next line) is compared in parallel, and the one-hot of the first taken transfer selects the result. The targets come out of the adders long before the decision, so the compares are not on the path.

**Checked**
- `tb_fetch` gives the same results as before, cycle for cycle, and PASSes on 11 programs.
- 3 mutations added for the new logic (M129–M131); all 17 of the fetch control are detected (125 in all).
- Yosys: 5,797 LUTs + 88 LUTRAM, no larger.

Recorded in `Plan/OOC.md` 14.5 (and the Japanese version), the TAGE-S row of `Doc/UARCH`, the RTL READMEs and the prompt log (answer 42 and the English of 43).

**Request**: please rerun `synth_ooo.bat OOC_FRONT`. About 3 ns more slack is expected, with about the same size.
<!-- /answer -->

## 44. 2026-10-25 17:42:54 JST

```text
I reran it.
```

<!-- answer -->
**Claude Code's answer**

The front end closes at 50 MHz.

| Run | LUT | of it LUTRAM | FF | Block RAM | Register-to-register slack | Levels |
|---|---|---|---|---|---|---|
| OOC_FRONT (first version) | 2,968 | 106 | 2,538 | 5.5 tiles | −0.162 ns | 25 |
| **OOC_FRONT (fixed)** | **3,076** | 82 | 2,576 | 5.5 tiles | **+0.959 ns** | 16 |

- **The slack grew by 1.1 ns and it closes.** Not the 3 ns or so expected: with the override path shortened, another path became the worst. 25 levels went to 16, and the parallel compares cost 108 LUTs.
- **The worst path now** runs from the head address through F2's decision and the uBTB's training (the match against its 16 entries) into the write enable of a uBTB entry.
  - If the core lacks margin later, registering the training and applying it a cycle late shortens it, with hardly any effect on the predictions. Not done now.
- **The budget** (a row added to UARCH 4.4): the estimates of the fetch buffer, the FTQ and the front end are replaced with the measured values, with the FTQ widened and the I$ to 16 bytes added.

| | Low | Middle | High |
|---|---|---|---|
| After the ROB and renaming were measured | 7.2k | 9.9k | 12.7k |
| **After the front end was measured** | **7.5k** | **9.5k** | **11.4k** |

The spread narrows and the middle drops by 0.4k. What is left unwritten is decode, the issue-queue payload, the D$ adapter and the control, about ±1.4k together.

Recorded in `Plan/OOC.md` 14.6 (and the Japanese version), 4.3 and 4.4 of `Doc/UARCH`, and the prompt log (answer 43 and the English of 44); pushed to dev (5f1663d).

Next, in the order laid out before, I recommend deciding how to hold back the dependents of a missing load (the replay policy, B1).
<!-- /answer -->

## 45. 2026-10-25 17:47:09 JST

```text
As recommended, next please decide how to hold back the dependents of a missing load (the replay policy, B1), and add the cancellation to OOO_IQ. Prepare the unit tests and Vivado scripts too.
```

(During this turn I asked the author which policy to take, with the CoreMark measurement: a replay trap at commit, recommended, about +0.05k LUTs, or selective replay in the issue queue, about +0.7k to 1.2k. The author chose selective replay in the issue queue.)

<!-- answer -->
**Claude Code's answer**

As you decided, a missing load is handled by selective replay in the issue queue, built into `OOO_IQ`. All 15 unit tests PASS and all 21 IQ mutations are detected (146 in all). Pushed to dev (5935e45). Vivado has not been run yet.

**Measured first**: in 10 iterations of CoreMark, the only loads that could not give their result in the expected cycle were the 26 cold D$ misses. Partial overlaps with stores: 0. You chose the policy having seen this.

**The policy**
- **Load slots**: a load issued in cycle c owns slot "c mod 4", and at c+3 the `ld_cancel` of the LSU's M decides "cancel" or "confirm".
- **Masks**: the wakeup buses carry the mask of the open loads a value relies on. Each source remembers it, and a µop issues with its sources' masks combined (`iss_ldm`).
- **Kept entries**: a µop issued on an open load keeps its entry until the load is confirmed. On a cancel it goes back to waiting, and the sources woken through that load go back to not ready.
- **The cancelled load**: not issued again from the queue. It waits in its entry until the LSU's late answer.
- **Correction at dispatch**: a source whose producer waits in the queue is not ready whatever renaming says, and gets the producer's mask if the producer is unconfirmed. Instead of a table of masks for 64 registers (about 1k LUTs), the queue's producers are compared.

**Changed on the way**: at first I decided at c+4, with `ld_cancel` through a register. But measured in the model, keeping the entries a cycle longer cost a lot.

| Configuration (G0) | -O2 | max. optimization |
|---|---|---|
| Entries freed at issue (so far) | 6.564 | 6.801 |
| Kept until c+4 (through a register) | 6.491 (−1.1 %) | 6.766 (−0.5 %) |
| **Kept until c+3 (as built)** | **6.550 (−0.2 %)** | **6.786 (−0.2 %)** |

The M-stage signal comes at the end of the cycle, so it is kept out of the select loop and acts only on the entries' next state. A µop selected in the cycle of the cancel is taken back as if not issued. `ld_kill` for the units is given a cycle later.

**Verification**
- `tb_iq` is rewritten: an account follows, for every value, "the open loads it relies on". A quarter of the loads are cancelled.
- Renaming's ready bits are given without knowing about cancels, so the queue's correction is tested too. PASS on 12 seeds.
- Checked: every cycle's issue, its mask, `ld_kill`, and the number of free entries.

**Size**: Yosys 5,255 → 7,288 LUTs at 16 entries (+2.0k). With the ratios so far, about **+1.0k** in the core. The budget gap is updated once Vivado gives the number.

**Needed at the core's assembly** (recorded in `Plan/OOC.md` 15.2)
- Every unit drops a µop in RR/EX whose `iss_ldm` meets `ld_kill`; in the LSU, no SQ write and no D$ request either.
- Renaming's ready bits are set with the wakeup broadcasts. This is unrelated to this change: it was needed before, and I noticed now that setting them at write-back would miss some.
- Holding loads in the queue until `lsu_st_known` is still to be wired.

Recorded in `Plan/OOC.md` section 15 (and the Japanese version), 3.5, 3.7 and 4.3 of `Doc/UARCH`, the RTL READMEs, the model (`keep_spec` and `results/g0.txt`) and the prompt log.

**Request**: please run this in Vivado.
```
cd FPGA\OOO_OOC
synth_ooo.bat OOO_IQ
```
<!-- /answer -->

## 46. 2026-10-25 19:47:18 JST

```text
I have finished running OOO_IQ.
```

<!-- answer -->
**Claude Code's answer**

The issue queue with selective replay closes at 50 MHz, but came out larger than estimated.

| Run | LUT | FF | Register-to-register slack | Levels |
|---|---|---|---|---|
| OOO_IQ, 16 entries (previous version) | 3,143 | 702 | +5.065 ns | 12 |
| **With selective replay, 16 entries** | **4,974** | 975 | **+3.309 ns** | 13 |

- **Timing**: it closes with 3.3 ns to spare. The worst path is still the wakeup-select loop; `ld_cancel` is not on it. The 1.8 ns lost is mostly longer routing in a larger block (83 % of the delay is routing).
- **Size**: +1,831 LUTs at 16 entries, about **+1.4k** at G0's 12 entries.
  - The estimate was +1.0k, and the range shown when you decided was +0.7k to 1.2k; it is above even its top.
  - Two causes: the per-source masks (32 sources × 4 bits, chosen from 6 buses and cleared by confirm and cancel) and the dispatch compares against the 16 producers.
- **Budget** (a row added to UARCH 4.4):

| | Low | Middle | High |
|---|---|---|---|
| After the front end was measured | 7.5k | 9.5k | 11.4k |
| **After the IQ (with replay) was measured** | **8.9k** | **10.9k** | **12.8k** |

- **A lever for G0b**: going back to the replay trap at commit saves about 1.4k and gains 0.2 % on CoreMark (no kept entries). In exchange, code that misses refetches on every D$ miss. It is listed in the levers, but the policy stays as you decided; whether to change it is yours at G0b.

Recorded in `Plan/OOC.md` 15.5 (and the Japanese version), 4.3 and 4.4 of `Doc/UARCH`, and the prompt log (answer 45 and the English of 46). The English of 45 notes the question I asked about the policy. Pushed to dev (adf12c8).

Next is either decode × 4 and RVC expansion (A2), in the order laid out, or first looking at whether this IQ can be made smaller.
<!-- /answer -->

## 47. 2026-10-25 19:50:21 JST

```text
First, please look at whether the IQ with selective replay can be made smaller.
```

<!-- answer -->
**Claude Code's answer**

The IQ got smaller: in Yosys, 7,288 → **6,172 LUTs** at 16 entries (−15 %). The issue is the same, cycle for cycle; all 15 tests PASS and all 146 mutations are detected. Pushed to dev (7d93d41); not yet checked in Vivado.

**How**: each part was taken out and measured in Yosys. But the same logic moves by hundreds of LUTs with how it is written, so I checked against a count of the structure before deciding.

**Changes taken**
- **Freeing the cancelled load's entry**: it was compared with all 6 wakeup buses; now with the 2 external ones only. The late answer always comes on the external buses.
- **Load slots from 4 to 3**: a load is open for 3 cycles after its issue, so the masks only ever hold the last 3 loads.
  - The 4th slot was there because the next load takes the slot in the cycle it is decided.
  - With 3, a load's own bit is kept out of that cycle's decision and out of the mask for the units.
  - Every mask bit is a quarter fewer.
- **Redundant logic removed**: with 3 slots, clearing confirmed bits in a load's delayed wakeup became unnecessary; bug injection found it, so it was removed.

**Considered and not taken**
- **Waiting at dispatch for the producer's confirmation**: hardly any loss in the model (−0.06 % / 0.00 % / −0.14 %). But every source needs an entry number and a 16-to-1 select, more than the logic it replaces.
- **Stopping dispatch until the confirmation**: cheap logic, but −1.5 % / −5.9 % in performance.
- **The per-source masks themselves**: the largest part, but needed to handle the cancels correctly; they cannot go.

**Expected**: with last time's Vivado / Yosys of 0.68, 4,974 → about 4.2k at 16 entries, about 3.3k at 12. The increase over the version without replay (about 2.45k at 12) would shrink from +1.4k to about +0.85k. The budget table is updated once Vivado gives the number.

Recorded in `Plan/OOC.md` 15.6 (and the Japanese version) and the prompt log (answer 46 and the English of 47).

**Request**: please run `synth_ooo.bat OOO_IQ` once more.
<!-- /answer -->

## 48. 2026-10-25 21:29:43 JST

```text
I ran synth_ooo.bat OOO_IQ. Please check it.
```

<!-- answer -->
**Claude Code's answer**

I checked it. The estimate I gave last time was wrong: Yosys had fallen 15 %, but in Vivado **the LUTs did not fall**.

| Run (16 entries) | LUT | FF | Register-to-register slack | Levels |
|---|---|---|---|---|
| Before the replay | 3,143 | 702 | +5.065 ns | 12 |
| With selective replay | 4,974 | 975 | +3.309 ns | 13 |
| **After last time's reductions** | **4,977** | **924** | **+2.857 ns** | 12 |

- **The LUTs are the same** (4,974 → 4,977). Only the FFs fell, by the 4th mask bit (975 → 924).
  - Vivado apparently built efficiently from the start the parts Yosys counted twice: the compare of the cancelled load's tag with buses that never carry it, and the 4th mask bit.
  - Vivado's numbers also move by a few percent from run to run.
  - Last time I said "shrinks to about +0.85k"; taking the Yosys difference as the estimate was the mistake. This made it clear that Yosys cannot judge small structural differences. The lesson is recorded, and from now on a saving is promised only subject to Vivado's confirmation.
- **Timing**: it still closes at 50 MHz with 2.9 ns to spare.
- **Budget**: the gap stays at 8.9k / 10.9k / 12.8k; selective replay costs about +1.4k at 12 entries. Last time's RTL changes stay: the behavior is the same, with fewer FFs and a simpler build.
- **Further reduction**: no more can come from details. Most of it is the per-source masks, which cannot go while the replay is selective. The big lever left is the policy itself (the replay trap at commit, about −1.4k), listed for your decision at G0b.

Recorded in `Plan/OOC.md` 15.7 (and the Japanese version), the issue-queue row of `Doc/UARCH`, and the prompt log (answer 47 and the English of 48); pushed to dev (51ce7c1).
<!-- /answer -->

## 49. 2026-10-25 21:58:01 JST

```text
Next, please go on with decode × 4 and RVC expansion (A2). Prepare the unit tests and Vivado scripts too.
```

<!-- answer -->
**Claude Code's answer**

I wrote decode × 4 and RVC expansion (A2). All 16 unit tests PASS and all 20 mutations added are detected (166 in all). The Vivado script is ready, and everything is pushed to dev (8c31e6a). Vivado has not been run yet.

**How: mmRISC-2's decoders as they are**
- mmRISC-2 Rev.02's `CORE_DECOMP` (RVC → 32-bit) and `CORE_DEC` (RV64GC + Zba/Zbb/Zbc/Zbs/Zicond/Zicsr/Zifencei/Zicboz, privileged instructions) are brought unchanged into `RTL/CPU/CORE`.
  - The instruction set is kept as mmRISC-2's, and the ALU's operation encoding is the same, so the decode result goes on as it is.
  - In mmRISC-2 these booted Linux.
- The new **`OOO_DEC`** expands RVC and decodes in each of the 4 slots, and derives the fields the other blocks use.

| To | Fields |
|---|---|
| Fusion (`OOO_FUSE`) | class, op kind, integer registers, whether the narrowed second stage can run it |
| Issue queue | port, 2-cycle result, result from outside |
| ROB | illegal, the mark of instructions that run only at the ROB head |

**How it is checked (`tb_dec`)**
- Two references. One is a decoder and RVC expander written separately from the specification's tables; the RVC expansion uses Spike's own field extractors. The other decides whether an instruction exists, by **actually running it in Spike**.
- At first I tried to decide that with Spike's disassembler, but it could not be used: whatever the ISA string, it knows every extension, vector and quad included, and it takes the reserved RVC encodings.
- Running it, Spike still accepts vector instructions without V, so only the vector encoding space is left out of the judgment.
- All 49,152 RVC encodings and 3,000,000 32-bit words. First the reference and Spike were checked to agree (no difference); then every output of the RTL against the reference: PASS.
- Two redundant conditions found on the way were removed. The test now also checks that illegal instructions have no register or port.

**Size (Yosys)**: `OOC_DEC` is 2,246 LUTs. With the ratios so far, about 1.1k to 1.8k, near the top of the estimate (1.0k to 1.6k). The harness keeps every field, FP and CSR included, so in the Phase 1 core the unused part is removed by synthesis and it should be smaller.

Recorded in `Plan/OOC.md` section 16 (and the Japanese version), 3.3 and 4.3 of `Doc/UARCH`, `RTL/CPU/CORE/README` (new), the RTL READMEs and the prompt log (answer 48 and the English of 49).

**Request**: please run this in Vivado.
```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_DEC
```
<!-- /answer -->

## 50. 2026-10-25 23:25:04 JST

```text
synth_ooo.bat OOC_DEC has finished.
```

<!-- answer -->
**Claude Code's answer**

Decode closes at 50 MHz with plenty of margin, but its size is above the estimate.

| Run | LUT | FF | Register-to-register slack | Levels |
|---|---|---|---|---|
| OOC_DEC (4 slots, every field) | **1,980** | 628 | **+8.048 ns** | 9 |

- **Timing**: 11.8 ns, comfortably closed.
- **Size**: the estimate was 1.0k to 1.6k; it came to about 495 LUTs a slot.
  - Inside mmRISC-2's pipeline, `CORE_DEC` + `CORE_DECOMP` were 356 LUTs.
  - The difference is the fields `OOO_DEC` derives and the outputs mmRISC-2's pipeline did not use.
  - Last time I said "the fields Phase 1 does not use disappear and it gets smaller", but I counted the FP and CSR fields in the budget: the instruction set is kept, so the final core decodes them too.
- **Budget** (a row added to UARCH 4.4):

| | Low | Middle | High |
|---|---|---|---|
| After the IQ with replay was measured | 8.9k | 10.9k | 12.8k |
| **After decode was measured** | **9.9k** | **11.6k** | **13.2k** |

- What is left unwritten is the issue-queue payload, the D$ adapter and the control.
- Sharing or narrowing decode in some slots would change the model's assumptions, so I did not try it. If needed, it becomes an item for G0b.

Recorded in `Plan/OOC.md` 16.4 (and the Japanese version), 4.3 and 4.4 of `Doc/UARCH`, and the prompt log (answer 49 and the English of 50); pushed to dev (e5a12df).

The gap has widened to 11.6k in the middle. There are two ways on: measure the remaining small blocks first (the issue-queue payload A4 and the D$ adapter A3), or start the G0b budget review now.
<!-- /answer -->

## 51. 2026-10-25 23:31:14 JST

```text
Next, please go ahead with the issue-queue payload (A4) and the D$ adapter (A3). Prepare everything up to the unit tests and the Vivado scripts.
```

<!-- answer -->
**Claude Code's answer**

I wrote the issue-queue payload (A4) and the D$ adapter (A3), up to the unit tests and the Vivado scripts. All 18 tests PASS and all 183 bug injections are detected. It is pushed to dev (ecd950c), but Vivado has not been run yet.

**A4: the issue-queue payload (`OOO_IQPL`)**
- A LUTRAM with 2 writes and 3 reads. It has two banks with one write port each, and remembers per entry, in one bit, which bank wrote it last (LVT).
- Each bank is written by one statement so that Vivado makes LUTRAM of it (what we learned with the ROB).
- The write address is needed, so `OOO_IQ` now outputs `disp_entry`. tb_iq now also checks the entry number of every µop.
- The record is 96 bits for now. Counting the fields needed gives about 91 bits; it is fixed when the core is put together.

**A3: the D$ adapter (`OOO_DCAD`)**
- **What did not match**: the LSU waits for hit and data in the cycle after the request (M), while mmRISC-2's D$ answers 2 cycles later at the earliest, in request order.
- **Only one output was added to the D$**: `d_hit_now` gives a load hit in the cycle stage 1 finds it. The D$ files were copied to `RTL/CPU/CACHE`.
  - mmRISC-2's condition "no older answer waiting" is only there to answer in order, so I left it out.
  - Hits now come back under misses too. In the layout with many evictions, hits in M went from about 4,400 to about 10,300.
- **Answers of misses**: the D$'s in-order answers are given to the LSU as fills by LQ entry.
- **The rule that keeps stale values out**: a load the LSU tries again can receive the answer of its first request late. That answer is an old value without the store that came in between. So when an entry sends a new request, its older answers are dropped.
- **`dc_kill` was removed**: bug injection showed it is not needed given the rule above, as with the LSU's epoch.

**Verification**
- tb_dcad puts together the LSU, the adapter, the real D$ and an AXI4 memory model, keeping all of tb_lsu's checks.
  - 6 lines are put in one set of the 4-way D$, so that evictions and write-backs happen all the time.
  - PASS on 5 seeds in each of two layouts.
- Bug injection found one hole in the test: the adapter seldom kept answers. A hook that holds the fills now and then was added, and it is detected now.

**Size (Yosys)**

| Block | Yosys | G0 estimate |
|---|---|---|
| OOC_IQPL | 1,202 LUTs + 384 LUT RAM | 0.4k to 0.7k |
| OOO_DCAD (alone) | 486 LUTs + 72 LUT RAM | 0.3k to 0.6k |

**What worries me: the timing of the hit path**
- The path is the D$'s tag RAM → hit → the LSU's M → `wb_data` / `ld_cancel`.
- In mmRISC-2, tag to hit is already 12 levels (+4.4 ns of margin), and the LSU's M is 13 levels. Whether it fits 50 MHz is not known until OOC_LSUDC (LSU + adapter + D$) is run.
- The result's `summary.txt` now also has a row per instance (the adapter's own size).

The other points left for the assembly (reporting the D$'s bus errors, loads to peripherals) are in `Plan/OOC.md` 17.4.

```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_IQPL
synth_ooo.bat OOC_LSUDC
```
<!-- /answer -->

## 52. 2026-10-26 20:36:45 JST

```text
I ran synth_ooo.bat OOC_IQPL and synth_ooo.bat OOC_LSUDC. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

Both close at 50 MHz. The payload is just above the top of its estimate; the adapter is below its estimate.

| Run | LUT | of it LUT RAM | Register-to-register slack | Levels |
|---|---|---|---|---|
| OOC_IQPL (16 entries × 96 bits) | **711** | 384 | **+12.237 ns** | 3 |
| OOC_LSUDC (LSU + adapter + D$) | 8,439 | 70 | **+1.254 ns** | 21 |
| └ adapter `OOO_DCAD` | **227** | 70 | | |
| └ `OOO_LSU` | 3,004 | 0 | | |
| └ D$ `DCACHE` | 5,211 | 0 | | |

- **Payload**: 711 against an estimate of 0.4k to 0.7k. The 384 LUT RAM are as counted; the remaining 327 logic LUTs are mostly the bank choice. About 7.4 LUTs a bit, so once the record width is fixed, the size follows directly.
- **Adapter**: 227 against an estimate of 0.3k to 0.6k.
- **The hit path I was worried about last time was not a problem.**
  - The worst path is the D$'s `d_req_ready` → the adapter → the LSU's store drain → the SQ's valid bits, 21 levels, +1.254 ns.
  - The path `d_hit_now` → the LSU's M → `wb_data` / `ld_cancel` is not among the 10 worst, so its slack is above 2.07 ns.
  - In the core `ld_cancel` goes on into the issue queue; that part is checked when the core is put together.
  - If the drain path gets in the way, it can be cut by draining stores a cycle later. Stores drain after commit, so performance is not affected.
- **The D$**'s 5,211 is already counted in the budget, as the L1 caches outside the engine (8,217). It has 5,012 FFs, mostly line buffers; moving them to LUTRAM, A3 of `REDUCE.md` (0.8k to 1.5k), stays a G0b candidate.

**Budget** (a row added to UARCH 4.4)

| | Low | Middle | High |
|---|---|---|---|
| After decode was measured | 9.9k | 11.6k | 13.2k |
| **After the payload and the adapter were measured** | **10.1k** | **11.5k** | **12.8k** |

Only the control (1.5k to 2.5k) is left unwritten, so the remaining uncertainty is about ±0.5k.

Recorded in `Plan/OOC.md` 17.6 (English and Japanese), 4.3 and 4.4 of `Doc/UARCH`, and the prompt log (answer 51 and the English of 52); pushed to dev with the Vivado reports (d3b49dd).
<!-- /answer -->

## 53. 2026-10-26 20:40:28 JST

```text
Start the G0b budget review now: list the levers against the 11.5k gap and recommend a set.
```

<!-- answer -->
**Claude Code's answer**

I've done the G0b review. The levers listed at G0 (about 4.2k, or 5.4k with fusion level 2) can no longer close the middle 11.5k. Measuring turned up new levers. With them and some decisions from you, the middle closes with about +0.25k to spare. The high end (12.8k) does not close with any set.

**What I found while measuring** (every lever that affects performance was run in the model)
1. Renaming was measured with 8 checkpoints, but G0 specifies 6. Building it as specified saves about −0.25k at no cost; G0's performance figures already assume 6.
2. **With the replay trap at commit, the issue queue can drop to 10 entries for free.** Only the entries kept for open loads need 12. Cutting to 10 loses 1.9% with them and nothing without them. Together that is about −1.9k, at +0.2% CoreMark.
3. Decoding the rare classes (FP, CSR, system, AMO) only in slot 0 saves about −0.4k to −0.7k. None of them is in CoreMark's loop.
4. Narrowing the payload per port saves −0.1k to −0.2k.

**The levers** (`-O2` change against the design as written, 6.550)

| Tier | Lever | LUT | `-O2` |
|---|---|---|---|
| 1: nothing lost | Checkpoints 6, HPM 2 (already decided), FPU C2+C3, LiteX peripherals, rare classes in slot 0, payload narrowed | **−3.1k** | 0 |
| 2: small loss | Trap at commit + issue queue 10 | −1.9k | +0.2% |
| | LQ/SQ 8, uBTB 8, fetch buffer 8 (L4 to L6) | −1.2k | −1.7% |
| | Asymmetric ALUs (L7) | −0.7k to −1.0k | not modelled yet |
| 3: your choice | Fusion level 2 | −1.2k | −3.1% |
| | 54k ceiling | +2k | 0 (timing risk) |
| | No PMP, no HPM counters | −1.5k | 0 (Linux features lost) |
| | No fusion (instead of level 2) | −2.7k | −7.0% |

- **Measured, not worth taking**: 4 checkpoints (−3.2% for 0.25k), issue queue 8, ROB 20.
- Tiers 1 and 2 together give about 7.0k, which leaves about 4.5k in the middle.

**Two ways to close the rest**

| End state | CoreMark `-O2` / most optimization (pessimistic) | Middle margin |
|---|---|---|
| **A: fusion level 2 + 54k ceiling + no PMP / HPM** | **6.25 / 6.70** (5.50 / 5.93) | +0.25k |
| B: no fusion + 54k ceiling | 5.99 / 6.47 (5.36 / 5.83) | +0.25k |

Both meet the `-O2` goal (5.0) with margin. The "above 6.0" goal holds in the normal pipeline but fails in the pessimistic one (L4 to L6 alone already bring it to 5.97). Without the 54k ceiling, both end states are about 2k short in the middle.

**Recommendation** (decisions D-11 to D-14 in UARCH section 9)
1. Take all of tier 1 now (3.1k).
2. Switch to the trap at commit with a 10-entry issue queue (1.9k). You chose selective replay when it was estimated at +0.7k to 1.2k; it measured +1.4k, and it needs 2 more queue entries. The cost moves to code that misses in the D$ (Linux), which the model can't show. The selective-replay RTL stays in the repository if you want it back.
3. Take L4 to L6, and model L7 first, taking it if it costs about 1% or less.
4. End state A: fusion level 2 now, because it fixes the shape of the ALU ports the core is built with. Keep the 54k ceiling and no PMP / HPM (3.5k together) in reserve, and decide them at G1 once the whole core has a Vivado number. The control (±0.5k) and whole-chip effects can move the total by more than the margin. I prefer A over B because it gets 4% more CoreMark for the same LUTs; B keeps PMP and `perf`.

One correction to my last answer: moving the D$ line buffers to LUTRAM (REDUCE A3) is already counted in the room as part of group A, so it isn't a new lever. I fixed that line in Plan/OOC 17.6.

Everything is in `Doc/UARCH` 6.3 (English and Japanese), with the model runs in `Plan/model/g0b.sh` and `results/g0b.txt`. Pushed to dev (32fce9d).
<!-- /answer -->
## 54. 2026-10-26 20:58:53 JST

```text
I accept D-11 to D-14 as recommended. Record the decisions and apply tier 1 first.
```

<!-- answer -->
**Claude Code's answer**

I have stopped. I am waiting for your instructions on how to go on.

Where things stand (nothing committed or pushed):
- **Recorded**: the decisions D-11 to D-14, in section 9 and 6.3 of `Doc/UARCH` (English and Japanese).
- **The three tier-1 items that are in the RTL are changed**:
  - **G1**: `OOO_RENAME` has 6 checkpoints. The ring now wraps at 6; tb_rename PASSes on 4 seeds.
  - **G2**: `OOO_DEC` decodes the rare classes in slot 0 only. A `cut` output was added; tb_dec PASSes.
  - **G3**: port 2 of `OOO_IQPL` reads only the low 48 bits; tb_iqpl PASSes on 4 seeds.
  - 5 bug injections added, all 5 detected.
- **Yosys** (a hint only): renaming −313, decode −168, payload −194 LUTs. output/yosys_size.txt updated.
- **Not checked yet**:
  - All tests and all bug injections ran in the background; the notice that they finished came, but I have not read the results.
  - I stopped while about to read the `OOC_DEC` harness, to add the new `cut` output to it.
- **The rest of tier 1 (L1, L3, L8)**: their blocks (CSR, FPU, LiteX) are not in this repository yet, so they are not touched.
- **Not started**: UARCH 6.4 (the record of tier 1), the READMEs, the prompt log, the Vivado request.
<!-- /answer -->

## 55. 2026-10-26 21:21:17 JST

```text
Please sort out the items that need a decision here and tell me the pros and cons of each.
```

<!-- answer -->
**Claude Code's answer**

Seven items need a decision now. For each: the options, their pros and cons, and my recommendation.

First the state. All the background tests (18) PASS. Of 188 bug injections 183 are detected and the other 5 are NOT APPLIED: G2 changed the text of `OOO_DEC`, so their targets are no longer found. That needs no decision; I will rewrite them.

---

**1. What to do with G2 (rare classes decoded in slot 0 only)**

Yosys gives −168 LUTs, short of the estimate of −0.4k to −0.7k. `CORE_DEC` is used as it is with its outputs forced to 0, so the logic that tells whether an instruction is of a rare class stays in slots 1 to 3.

| Option | Pros | Cons |
|---|---|---|
| **a. Keep it and measure in Vivado** | Changed and tested already; no effect on CoreMark (2 in 3 million instructions) | One more contract at the assembly: the fetch buffer and fusion end the group by `cut`. The gain may be small |
| b. Write a new light decoder, integer only, for slots 1 to 3 | May come close to the estimated saving | Leaves `CORE_DEC`, proven in mmRISC-2, and needs new verification |
| c. Revert | No new contract | Loses about 0.2k |

Recommendation: a. Whether to go to b is decided on the Vivado number.

**2. Whether the `OOC_DEC` harness registers `cut`** (the work you stopped)

| Option | Pros | Cons |
|---|---|---|
| **Register it** | Measured as it sits in the core | The harness's output bus changes, so a comparison with the last number needs a note |
| Leave it out | The harness stays as it is | The logic of `cut` is removed by synthesis, and the result comes out a few tens of LUTs smaller |

Recommendation: register it.

**3. G3 (port 2 of the payload reads only the low 48 bits)**

Yosys gives −194 LUTs, but the LUT RAM stays 384: a RAM32M comes with 3 read ports, so narrowing port 2 removes only the bank choice. And 48 bits is a provisional width, before the record's contents are fixed.

| Option | Pros | Cons |
|---|---|---|
| **a. Keep 48 bits** | A number soon | Commits early to a layout with the LSU's fields in the low bits; the width changes if they do not fit |
| b. Fix the record's contents now | Exact | Before the control is written, some of it cannot be decided |
| c. Revert | No new contract | Loses 0.1k to 0.2k |

Recommendation: a, reviewed when the contents are fixed at the assembly.

**4. G1 (6 checkpoints)**: less a decision than a contract to confirm.
- The control has to keep unresolved transfers at 6 or fewer. The model's G0 numbers already assume it.
- 6 is not a power of two, so turning the ring at 6 takes a few compares more.
- Keeping 8 numbers and limiting the unresolved ones to 6 saves no LUTs.

Recommendation: go on as it is.

**5. When to apply L1, L3 and L8** (the CSR, the FPU and LiteX are not in this repository yet)
- **L1 (HPM counters 4 → 2)**: a parameter change only; applied at the assembly, when the CSRs are brought in.
- **L3 (FPU C2 + C3)**: a large task, designing a new small iterative unit for the rare operations.

| L3 option | Pros | Cons |
|---|---|---|
| **In Phase 2, when the FPU comes in** | Phase 1 (up to CoreMark) is not held up | Its 1.15k stays an estimate in the budget until then |
| Build it now | The number is fixed | Phase 1 is delayed |

- **L8 (removing unused LiteX peripherals)**: at the LiteX build.

Recommendation: those times. Until then they are counted at their estimates in the budget.

**6. When to ask for Vivado**

| Option | Pros | Cons |
|---|---|---|
| **Three now (OOC_RENAME, OOC_DEC, OOC_IQPL)** | Tier 1's effect is known early, and whether 1b is needed can be decided | Fusion level 2 (D-14) makes decode's `alu2ok` unneeded, so `OOC_DEC` has to run again later |
| Together, after the changes of D-12 to D-14 | One run for you | Tier 1's numbers come later |

Recommendation: now. All three are short runs.

**7. The order of D-12 to D-14**

| Item | Size of the work | Content |
|---|---|---|
| D-12 trap + issue queue 10 | Medium | Remove the selective replay from `OOO_IQ`; the ROB gets the trap mark and the LSU's `ld_cancel` goes to the ROB |
| D-14 fusion level 2 | Medium | Remove the second stage of `OOO_ALU2` and ALU + ALU from `OOO_FUSE` |
| D-13 L4 to L6 | Small | Parameters LQ/SQ 8, uBTB 8, fetch buffer 8, and the tests adjusted |
| D-13 L7 | Medium (model) | Add the operation class per instruction to the model and measure the loss of asymmetric ALUs |

Recommended order: D-12 → D-14 → L4 to L6 → L7.
- D-12 is the largest (1.9k), and the shape of the issue queue fixes the payload's entry count, so it comes first.
- D-14 fixes the shape of the ALU ports, so it comes next.
- L4 to L6 are small and can be done at any time.
<!-- /answer -->

## 56. 2026-10-26 21:25:43 JST

```text
Proceed as recommended on all seven items: keep G2 and G3, add cut to the OOC_DEC harness, then commit and ask for the three Vivado runs, and start D-12.
```

<!-- answer -->
**Claude Code's answer**

I went ahead on the seven items as recommended. Tier 1 is pushed to dev as `ace55f7` and D-12 as `eb600dd`. All 18 tests PASS and all 175 bug injections are detected. Vivado has not been run yet.

**Tier 1 (`ace55f7`)**
- The decisions D-11 to D-14 are recorded in section 9 and 6.3 of `Doc/UARCH`; what tier 1 did is in 6.4.
- **G1**: renaming has 6 checkpoints. 6 is not a power of two, so the numbers now turn in a ring of 6.
- **G2**: the rare classes are decoded in slot 0 only. The output `cut` is also registered by the `OOC_DEC` harness.
- **G3**: port 2 of the payload reads only the low 48 bits.
- The 5 bug injections that G2's change of text had moved off their targets were rewritten and are detected.

**D-12: replay after commit and an issue queue of 10 (`eb600dd`)**
- **Issue queue**: back to the version before the selective replay (git f4af1b8), with 10 entries. The masks and the kept entries are gone; entries are freed at issue. Its test went back to that version too, with checks of `disp_ready` and the entry numbers added.
- **LSU**: a load that raised `ld_cancel` (a miss, a wait) is marked, and its late completion carries the mark (`cmp_ld_rp`).
- **ROB**: a marked µop commits alone, and then the ROB empties. Fetch starts again from the next instruction (`replay`, `replay_pc` = pc + the µop's length).
  - The load itself is not run again, so a peripheral read never happens twice.
  - For that the payload got the length (3 bits).
- **Bug injection**: the 21 for the selective replay went with the logic they targeted; 8 added, 4 rewritten.
- The selective replay's RTL and test stay in git (5935e45, 7d93d41).

**Size in Yosys** (a hint only; Vivado decides)

| Block | Before | After |
|---|---|---|
| Issue queue | 6,172 | **2,513** |
| Renaming | 3,769 | 3,456 |
| Decode | 2,246 | 2,078 |
| Payload | 1,202 | 515 |
| ROB | 1,544 | 1,621 (the replay adds a little) |

**Contracts for the assembly** (in `Doc/UARCH` 6.4 and 6.5)
- The fetch buffer and fusion take `valid & ~cut` from decode.
- Dispatch stops when 6 transfers are unresolved.
- `replay` is a `flush_all` for the rest of the core.
- A load that runs only at the head (MMIO) must not wake what follows it on a guess.

The rest of tier 1 (L1, L3, L8) is not touched yet: the CSR, the FPU and LiteX are not in the repository. The budget counts them at their estimates.

**Vivado request** (six; `OOC_IQPL` again, now with 10 entries)
```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_RENAME
synth_ooo.bat OOC_DEC
synth_ooo.bat OOC_IQPL
synth_ooo.bat OOO_IQ
synth_ooo.bat OOC_ROB
synth_ooo.bat OOC_LSU
```
<!-- /answer -->

## 57. 2026-10-26 22:07:41 JST

```text
I ran synth_ooo.bat for OOC_RENAME, OOC_DEC, OOC_IQPL, OOO_IQ, OOC_ROB and OOC_LSU. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

All six close at 50 MHz. Together they saved about 2.57k LUTs, and the gap in the middle is now 8.9k. That is 0.28k short of the 2.85k planned, and the middle margin of the G0b plan is now about 0.

| Run | Before | **Now** | Change | Register-to-register slack | Estimate |
|---|---|---|---|---|---|
| Issue queue (10 entries, no replay) | about 3.9k in the budget | **1,621** | **−2,279** | +7.843 ns (was +2.857) | G4: −1.9k with the ROB and LSU parts |
| ROB (replay after commit) | 1,073 | 1,232 | +159 | +11.233 ns | (in G4) |
| LSU (the replay mark) | 2,969 | 2,981 | +12 | +5.698 ns | (in G4) |
| Renaming (6 checkpoints) | 2,624 | 2,464 | −160 | +8.179 ns | G1: −0.25k |
| Decode (rare classes in slot 0) | 1,980 | 1,808 | −172 | +7.803 ns | G2: −0.4k to −0.7k |
| Payload (10 entries, port 2 at 48 bits) | 711 | 585 | −126 | +12.620 ns | G3: −0.1k to −0.2k |
| **Together** | | | **−2,566** | | −2.85k |

- **G4 (replay after commit with 10 entries) did better than estimated**: −2.11k with the ROB and LSU increases included (estimate −1.9k). The issue queue also gained 5 ns of slack.
- **G2 (decode) fell short** (−172), as Yosys said: while `CORE_DEC` is used whole, the logic that recognizes the rare classes stays in slots 1 to 3. The remaining −0.3k to −0.5k needs a light integer-only decoder for slots 1 to 3 (1b of the earlier list), with new verification.

**Budget** (a row added to UARCH 4.4)

| | Low | Middle | High |
|---|---|---|---|
| After the payload and the adapter were measured | 10.1k | 11.5k | 12.8k |
| **After tier 1 and D-12 were measured** | **7.5k** | **8.9k** | **10.2k** |

**Where we stand against the plan**
- The levers still to come add up to 8.9k: the rest of tier 1 (L1, L3, L8) 2.15k, L4 to L6 1.2k, L7 0.85k, fusion level 2 (L9) 1.2k, and the reserve, the 54k ceiling (L10) and no PMP / HPM (B4 / B5), 3.5k.
- With the reserve the middle margin is about 0 (−0.03k), +1.4k at the low end, −1.3k at the high end.
- Getting through without the reserve is hard, and even the small ups and downs of each measurement can make it short. The light decoder (1b above) is one candidate to fill that difference.

Recorded in `Doc/UARCH` 6.6 and 4.4 (English and Japanese) and the prompt log (answer 56 and the English of 57); pushed to dev with the Vivado reports (d633f71).
<!-- /answer -->

## 58. 2026-10-26 22:13:33 JST

```text
Go on to D-14 (fusion level 2) as planned.
```

<!-- answer -->
**Claude Code's answer**

D-14 (fusion level 2) is in the RTL and pushed to dev (`3600489`). All 18 tests PASS and all 173 bug injections are detected. Vivado has not been run yet.

**What was done**
- **`OOO_FUSE`**: level 2. The ALU + ALU rule and the `alu2ok` input are gone.
  - On the CoreMark stream the RTL forms exactly as many pairs as the model (156,004).
- **`OOO_ALU2`**: one full ALU and the branch comparison only.
  - The narrowed second ALU went with ALU + ALU.
  - **The third source `s3` went too.** G0 counted "no third source" in the budget (about −0.4k), but the RTL still had it.
  - A pair reads at most 2 registers, so a fused branch only has to compare the ALU result with s1, s2 or zero (`br_o_sel`).
  - The harness bypasses 2 sources now.
- **`OOO_DEC`**: `alu2ok` removed.
- **Bug injection**: the 5 aimed at the second stage, ALU + ALU and `alu2ok` went with them; 3 added.

**Size in Yosys** (a hint only; Vivado decides)
- ALU port: 4,617 → **3,235**
- Fusion: 285 → 269
- Decode: about the same

The budget counts the two ALU ports at about 5.9k, and L9 was expected at −1.2k. How much is saved is decided by the Vivado number.

**Contracts for the assembly** (in `Doc/UARCH` 6.7)
- Decode and fusion give a fused branch `br_o_sel`: which of the two source ports holds the branch's other register, or 0 for x0.
- The payload loses the second operation's fields.

Recorded in 3.1, 3.3, 3.6 and 6.7 of `Doc/UARCH` (English and Japanese), the READMEs, and the prompt log (answer 57 and the English of 58).

**Vivado request**
```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_ALU2
synth_ooo.bat OOC_FUSE
synth_ooo.bat OOC_DEC
```
<!-- /answer -->

## 59. 2026-10-26 22:47:01 JST

```text
I ran synth_ooo.bat for OOC_ALU2, OOC_FUSE and OOC_DEC. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

All three close at 50 MHz. Fusion level 2 saved about 2.07k LUTs, well beyond the −1.2k planned. The gap in the middle is now 6.8k.

| Run | Before | **Now** | Change | Register-to-register slack |
|---|---|---|---|---|
| ALU port (one) | 3,133 | **1,926** (`OOO_ALU` 801 of it) | −1,207 a port | +1.753 ns (was +0.512) |
| Two ALU ports | about 5.9k counted | **3,852** | **−2,048** | |
| Fusion | 215 | 208 | −7 | +10.591 ns |
| Decode | 1,808 | 1,791 | −17 | +8.034 ns |
| **Together** | | | **−2,072** | |

- **Why it beat the plan**: besides the second ALU and its bypass, the third source went too. G0 had already taken about 0.4k off the budget for it, but the RTL still had it.
- **Timing**: the ALU port gained 1.2 ns of slack. The worst path is the bypass → the ALU's adder → the fused branch's comparison → `take_branch`, 46 levels with two carry chains in a row.

**Budget** (a row added to UARCH 4.4)

| | Low | Middle | High |
|---|---|---|---|
| After tier 1 and D-12 were measured | 7.5k | 8.9k | 10.2k |
| **After D-14 was measured** | **5.4k** | **6.8k** | **8.1k** |

**Where we stand against the plan**
- **L7 (asymmetric ALUs) is worth less now.** Its −0.7k to −1.0k assumed ports of two chained ALUs. With one ALU a port (801 LUTs), an ALU1 with only add / sub, logic, compares and branches saves about −0.3k to −0.5k. Its loss is to be modelled before it is taken.
- The levers still to come add up to 7.25k: the rest of tier 1 (L1, L3, L8) 2.15k, L4 to L6 1.2k, L7 about 0.4k, and the reserve, the 54k ceiling and no PMP / HPM (L10 + B4 / B5), 3.5k.
- The middle margin is now **about +0.4k** (+1.8k low, −0.9k high). Better than the about 0 of last time, but without the reserve the middle is about 3.1k short.

Recorded in `Doc/UARCH` 6.8 and 4.4 (English and Japanese) and the prompt log (answer 58 and the English of 59); pushed to dev with the Vivado reports (174a21b).
<!-- /answer -->

## 60. 2026-10-26 22:54:51 JST

```text
Go on to L4 to L6 (LQ/SQ 8, uBTB 8, fetch buffer 8) as planned.
```

<!-- answer -->
**Claude Code's answer**

L4 to L6 are in the RTL and pushed to dev (`662a191`). All 18 tests PASS. Of 173 bug injections 171 are detected; the other 2 are mutations that change nothing with 2 blocks (equivalent). L6 (the fetch buffer) came out larger in Yosys.

**What was done**
- **L4 (LQ / SQ to 8)**: `OOO_LSU` and `OOO_DCAD` have 8 entries.
  - The bit widths written out in the tests are now computed from the sizes.
  - The two LSU harnesses (OOC_LSU, OOC_LSUDC) were rewritten for 3-bit entries and 4-bit tails.
- **L5 (uBTB to 8)**: `OOO_UBTB` has 8 entries, the one inside `OOO_FETCH` too, and tb_fetch's mirror of the uBTB.
- **L6 (fetch buffer to 2 blocks)**: `OOO_FBUF` has 2 blocks.

**Size in Yosys** (a hint only; Vivado decides)

| Block | Before | After |
|---|---|---|
| LSU | 4,662 | 3,055 |
| uBTB | 2,207 | 1,037 |
| Whole front end | 5,797 | 5,148 |
| LSU + adapter + D$ | 13,843 | 12,455 |
| Fetch buffer | 1,381 | **1,829 (larger)** |

**L6 may save nothing.**
- The blocks were in LUTRAM, and LUTRAM costs the same at any depth up to 32: 2 blocks instead of 4 save no RAM.
- And the 2-deep memory was built of flip-flops and selects instead.
- The −0.3k estimate counted the model's buffer in instructions; it did not look at this structure.
- If Vivado shows no saving either, I recommend going back to 4 blocks; as it is, it pays CoreMark's −0.3 % for nothing.

**The 2 not detected (M77, M86)**
- Both break "the start of the next (third) block when 2 blocks are popped". With 2 blocks there is no third block, so breaking it changes nothing.
- With 4 blocks they are detected. L6 may go back, so the RTL stays general.
- In this campaign my filter also dropped the "NOT DETECTED" lines; the count line (171 of 173) caught it. I wrote it into memory for next time.

Recorded in 3.1, 3.2, 3.7 and 6.9 of `Doc/UARCH` (English and Japanese), the READMEs, and the prompt log (answer 59 and the English of 60).

**Vivado request** (OOC_LSUDC for the timing with the D$)
```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_LSU
synth_ooo.bat OOO_UBTB
synth_ooo.bat OOC_FBUF
synth_ooo.bat OOC_FRONT
synth_ooo.bat OOC_LSUDC
```
<!-- /answer -->

## 61. 2026-10-26 23:50:11 JST

```text
I ran synth_ooo.bat for OOC_LSU, OOO_UBTB, OOC_FBUF, OOC_FRONT and OOC_LSUDC. Please check output/*/summary.txt.
```

## 62. 2026-10-26 23:54:11 JST

```text
Yes, put the fetch buffer back to 4 blocks (revert L6) and record it.
```

<!-- answer -->
**Claude Code's answer**

Fetch buffer back at 4 blocks, as you asked, and recorded. Pushed to dev as `aee000c`.

- **RTL**: `OOO_FBUF` is back to 4 blocks, and the harness and `tb_fbuf` match. Apart from comments, this RTL is the 4-block version measured before (940 LUTs), so I restored that Vivado report instead of asking for a new run.
- **Tests**: `tb_fbuf` passes on 4 seeds. The two bug injections that couldn't be caught with 2 blocks (M77, M86) are caught again, so all 173 are now detected.
- **Performance**: the model gives 6.28 / 6.71 CoreMark/MHz for the decided set (pessimistic 5.55 / 5.97), about 0.5% better than with 2 blocks.
- **Budget**: the gap stays 4.2k / 5.6k / 6.9k. Going back adds only 16 LUTs.
- **Docs** (English and Japanese): the change is in `Doc/UARCH` 3.2, 6.10 and decision D-13, and in the READMEs.
- **Fix in the docs**: the D-11 to D-14 rows had an extra empty cell since I first recorded those decisions. It's corrected in both versions.
<!-- /answer -->

## 63. 2026-10-27 21:39:54 JST

```text
Next, add the operation class to the model and measure L7 (asymmetric ALUs).
```

<!-- answer -->
**Claude Code's answer**

I added the operation class of each instruction to the model and measured L7 (asymmetric ALUs). The loss is −0.3 % / −0.2 %, inside D-13's criterion (about 1 % or less). There is one condition: the issue queue has to give simple operations to ALU1 first. The other way round it is −6 %.

**Changes to the model** (`alu_split` added to `Plan/model/ooo.h`)
- Until now the two ALU ports were pooled: either could take any operation.
- `alu_split` 1: ALU0 and ALU1 apart, MUL / DIV and system instructions on ALU0 only (as the RTL).
- `alu_split` 2: also the "complex" operations (shifts, Zba, Zbb, Zbs, Zicond) on ALU0 only; simple operations take ALU1 first (L7).
- `alu_split` 3: as 2, with simple operations taking ALU0 first.

**Results** (the decided set as the base: 6.279 / 6.710)

| Configuration | `-O2` | Most optimization |
|---|---|---|
| Ports apart only (1) | 6.279 (no loss) | 6.710 |
| **L7, simple operations to ALU1 first (2)** | **6.260 (−0.3 %)** | **6.695 (−0.2 %)** |
| L7, simple operations to ALU0 first (3) | 5.882 (−6.3 %) | 6.264 (−6.6 %) |

- In the pessimistic pipeline L7 (2) is −0.5 % / −0.4 %.
- **Why the order matters**: the complex operations are 30 % of the ALU instructions (16.5 % of all). If simple operations take ALU0 first, the complex ones wait behind them.
- **What it means for the RTL**: the issue queue now selects port 0 (ALU0) first. With L7 it selects port 1 first (the oldest ready simple operation) and port 0 from the rest. The select's depth stays the same.

**Size expected**
- The ALU of a port is 801 LUTs in Vivado now.
- In Yosys an ALU with only add / sub, logic and compares is 165 LUTs, the full one 2,174. With the full one's Vivado / Yosys ratio (0.37), ALU1 saves **about −0.5k to −0.65k**.
- Yosys differences are only a hint; Vivado decides.

**Work to put it into the RTL** (not in the RTL yet)
- Decode and fusion: complex operations, and fused pairs with a complex ALU part, become "ALU0 only", the class MUL / DIV already use.
- Issue queue: the select order turned round.
- ALU1's `OOO_ALU2`: an `OOO_ALU` with only the simple operations; the parameter `FULL`, free since D-14, can be used for it.

Recorded in `Doc/UARCH` 6.11 (English and Japanese), `Plan/model/results/g0b.txt` and the prompt log (answer 62 and the English of 63); pushed to dev (`728ceaa`).

By the way, my last answer (62) was written in English by mistake. From now on I answer in Japanese.
<!-- /answer -->

## 64. 2026-10-27 21:52:16 JST

```text
Build L7 into the RTL: complex ALU ops ALU0-only in decode and fusion, the issue queue selecting port 1 first, and ALU1 with the limited ALU. Then tests and Vivado scripts.
```

<!-- answer -->
**Claude Code's answer**

L7 (asymmetric ALUs) is in the RTL and pushed to dev (`12e5a60`). All 19 tests PASS, including the new tb_alu1, and all 180 bug injections are detected. Vivado has not been run yet.

**What was done**
- **ALU1's limited ALU**: `OOO_ALU`'s `FULL = 0` now has only ALU1's operations: add / sub (with the word forms), slt / sltu, xor / or / and.
  - `OOO_ALU2` passes this parameter down, so ALU1 is `OOO_ALU2 #(.FULL(0))`.
  - Its new test is `tb_alu1`; `run.sh` got a way to pass parameters to Verilator (`GV`).
- **Decode**: the other ALU instructions (shifts, Zba, Zbb, Zbs, Zicond) are "ALU0 only" (port 1), as MUL / DIV are.
- **Fusion**: gives the issue port of each µop. A pair is LSU if a half is, else ALU0 only if a half is, else any ALU.
  - On the CoreMark stream it still forms exactly the model's pairs.
- **Issue queue**: port 1 selects first (the oldest ready simple operation), and port 0 from the rest.
  - The test's reference uses the same order, and "ALU0 only" µops now come with latency 1 and 2.
- **Bug injection**: 7 added for the new parts, 2 rewritten whose text changed.

**Size in Yosys** (a hint only; Vivado decides)
- ALU port: full 3,088 → ALU1 **1,263** (−1,825 a port).
- With the port's Vivado / Yosys ratio (about 0.6), **about −1.1k**.
- More than last time's −0.5k to −0.65k, which looked only at the ALU itself; this compares the whole port (operand selection and so on).

Performance in the model: −0.3 % / −0.2 % (6.260 / 6.695).

**Contract for the assembly**: the payload of a µop going to port 1 needs no shift or Zba / Zbb fields.

Recorded in 3.5, 3.6 and 6.12 of `Doc/UARCH` (English and Japanese), the READMEs, and the prompt log (answer 63 and the English of 64).

**Vivado request** (ALU1 is the run with `FULL=0`; running `synth_ooo.bat` without arguments also does it at the end of the loop)
```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_ALU2 20.0 1 FULL=0
synth_ooo.bat OOC_ALU2
synth_ooo.bat OOC_FUSE
synth_ooo.bat OOO_IQ
synth_ooo.bat OOC_DEC
```
<!-- /answer -->

## 65. 2026-10-27 22:26:36 JST

```text
I ran synth_ooo.bat for OOC_ALU2 (and with FULL=0), OOC_FUSE, OOO_IQ and OOC_DEC. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

All five close at 50 MHz. L7 saved about 1.23k LUTs, beyond what was expected (about 0.4k in the plan, about 1.1k by the Yosys ratio). The gap in the middle is 4.4k.

| Run | Before | **Now** | Change | Register-to-register slack |
|---|---|---|---|---|
| ALU1's port (`FULL=0`) | 1,926 | **684** (the limited ALU 226 of it) | **−1,242** | +5.735 ns |
| ALU0's port (unchanged) | 1,926 | 1,928 | +2 | +1.480 ns |
| Fusion (with the port outputs) | 208 | 215 | +7 | +9.565 ns |
| Issue queue (port 1 selects first) | 1,621 | 1,597 | −24 | +7.438 ns |
| Decode (the "ALU0 only" marks) | 1,791 | 1,823 | +32 | +7.813 ns |
| **Together** | | | **−1,225** | |

It saved more than expected because besides the ALU itself (799 → 226), the port's operand selection shrank with it.

**Budget** (a row added to UARCH 4.4)

| | Low | Middle | High |
|---|---|---|---|
| After L4 to L6 were measured | 4.2k | 5.6k | 6.9k |
| **After L7 was measured** | **3.0k** | **4.4k** | **5.7k** |

**Where we stand against the plan**
- The levers still to come add up to 5.65k: the rest of tier 1 (L1, L3, L8) 2.15k and the reserve (the 54k ceiling, L10, and no PMP / HPM, B4 / B5) 3.5k.
- The middle margin is now **about +1.3k** (+2.7k low, about 0 high).
- Without any of the reserve, the middle is about 2.2k short; with only one of its parts, about 0.2k short with L10 alone, about 0.7k with B4 / B5 alone. Both are still assumed, but the margin has grown from last time's +0.4k.

**A fault in the run, and the fix**
- The `FULL=0` of the command I gave was not quoted, so cmd.exe split it at the `=` and Vivado got only `-generic FULL`. My instruction was wrong.
- Vivado took FULL as 0 (I checked the log), so the result is valid for ALU1.
- For the future, `synth_ooo.tcl` now puts split `NAME value` pairs back together. This run's output was moved to `output/OOC_ALU2_FULL0`.

Recorded in `Doc/UARCH` 6.13 and 4.4 (English and Japanese) and the prompt log (answer 64 and the English of 65); pushed to dev with the Vivado reports (`ae6d8a7`).
<!-- /answer -->

## 66. 2026-10-27 22:33:20 JST

```text
Start writing the control (dispatch, branch resolution, redirects, commit and exceptions), with unit tests and Vivado scripts.
```

<!-- answer -->
**Claude Code's answer**

I wrote the control's first part (`OOO_CTRL`) and the issue queue's branch masks, and pushed them to dev (`642bda5`). All 20 tests PASS, including the new tb_ctrl, and all 191 bug injections are detected. Vivado has not been run yet. Five parts of the control remain.

**What was missing, found while writing it**
- **A misprediction emptied the issue queue completely** (`flush`). That loses the µops older than the branch that are still waiting.
  - Fixed with branch masks: each µop carries one bit (6 bits) for every unresolved checkpoint older than it.
  - A restore throws away only the µops with that bit, the ones younger than the branch. A branch resolved as predicted clears its bit everywhere.
- **The checkpoint id has to be checked at renaming, not at dispatch.** Renaming copies the RAT into the id it gives in the next cycle, so giving out an id still in use overwrites it.

**What `OOO_CTRL` holds**
- **Renaming (D2)**: decides which µops may rename now: the DS register comes free, registers are free, no recovery, the checkpoint id is free.
- **Dispatch (DS)**: sends the DS register's two µops both or none, only when the ROB, the issue queue, the LQ and the SQ all have room.
  - It can lose a cycle when exactly one entry is free; not in the model yet.
- **The checkpoint table**: per branch, the LSU's tails and the FTQ index.
- **Recovery**: trap → replay → branch restore, in that priority. It gives the throw-away mark (kill), the clear mark (clr) and the pc fetch restarts from.

**Issue queue**: a mask per entry. kill removes the entries the mask meets, clr clears bits. The issued µop's mask (`iss_bm`) goes out so that the units can throw away what they have in flight.

**Verification**
- `tb_ctrl` checks against an account in program order, playing renaming's ring of ids and the ROB, with the checkpoints running out at times. PASS on 4 seeds.
- `tb_iq` with kills and clears PASS on 6 seeds.
- **A hole in `tb_iq` itself was found too.** It made combinations where an older µop of a group read a younger µop's result. The two waited for each other until the next flush; with it fixed, the issues a run went from about 100,000 to about 278,000, a stronger test.

**Size in Yosys** (a hint only): the control's first part 384 LUTs, the issue queue +262 for the masks.

**What remains of the control** (`Plan/OOC.md` 18.6)
1. Holding non-speculative µops (CSRs and so on) until they are at the ROB head.
2. The commit's follow-up (the free list and so on) and the FTQ's pops. The pops need "which µop is the last of a fetch block", not in the ROB yet.
3. The units' pipelines throwing away by mask, and the DS register's payload.
4. Restoring the branch history and the RAS state.
5. Exceptions and interrupts (the CSR writes, the refetch with fusion off after an exception inside a pair, FENCE.I).

Recorded in `Plan/OOC.md` 18 (English and Japanese), 3.5 and 4.3 of `Doc/UARCH`, the READMEs and the prompt log (answer 65 and the English of 66).

**Vivado request**
```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_CTRL
synth_ooo.bat OOO_IQ
```
<!-- /answer -->

## 67. 2026-10-27 23:02:53 JST

```text
I ran synth_ooo.bat OOC_CTRL and synth_ooo.bat OOO_IQ. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

Both close at 50 MHz. The gap in the middle is now 4.6k, a little wider than last time's 4.4k: the issue queue's branch masks are a new cost that was in no estimate.

| Run | LUT | Register-to-register slack | Levels |
|---|---|---|---|
| The control's first part (`OOC_CTRL`) | **340** | +13.564 ns | 4 |
| Issue queue (with branch masks) | **1,775** (+178 for the masks) | +7.841 ns | 10 |

- The control has plenty of timing margin.
- The issue queue's worst path is the same wakeup-select loop as before; the masks are not on it.

**How the budget counts it**
- The whole control's estimate (1.5k to 2.5k) stays, and these 340 are counted inside it. The remaining parts are to be written and measured.
- The issue queue's masks (+178) are added: a new cost, to fix last time's finding that a misprediction emptied the issue queue completely.

| | Low | Middle | High |
|---|---|---|---|
| After L7 was measured | 3.0k | 4.4k | 5.7k |
| **After the control's first part was measured** | **3.2k** | **4.6k** | **5.9k** |

With the levers still to come (5.65k including the reserve), the middle margin is about +1.1k.

Recorded in `Plan/OOC.md` 18.6 and 4.3 / 4.4 of `Doc/UARCH` (English and Japanese) and the prompt log (answer 66 and the English of 67); pushed to dev with the Vivado reports (`1b5dfdd`). By the way, last time's answer called the list of remaining parts "18.6"; since the Vivado results went into 18.6, that list is now 18.7.
<!-- /answer -->

## 68. 2026-10-27 23:05:07 JST

```text
Go on with the control's next part: non-speculative µops held until the ROB head, the commit fan-out, and the FTQ pops (with the block end in the ROB).
```

<!-- answer -->
**Claude Code's answer**

I wrote the control's second part and pushed it to dev (`d26ae01`): holding non-speculative µops until the ROB head, the commit's follow-up, and the FTQ's pops. All 20 tests PASS and all 200 bug injections are detected. Vivado has not been run yet. On the way, a fault around the replay was found and fixed.

**The fault found and fixed**
- The replay (refetching after a load that missed commits) flushed renaming in the same cycle as it committed the load.
- A flush takes renaming back to its committed state, but that cycle's commit only goes in at the clock edge, so the load's register mapping would have been lost.
- The fix: the front end (fetch, FTQ, fetch buffer) is flushed at once (`fe_flush`), the back end (renaming, LSU, issue queue, units) a cycle later (`flush_all`). In between nothing is renamed or dispatched, and the ROB is already empty.

**What was done**
- **Non-speculative µops** (CSRs, system instructions, AMO and so on): a mark on the issue queue's entries.
  - Such a µop may issue only with the control's permission (`ns_ok`) and as the oldest non-speculative µop in the queue.
  - The permission is given when "the ROB head is a non-speculative µop not run yet, and none has issued since it became the head". An issued CSR stays at the head while it executes, so this keeps a second one from going.
- **What changes what younger µops do** (CSR writes, FENCE.I, MRET and so on): completes marked for replay after commit, and what follows is fetched again. It uses the ROB's existing mechanism, so no new logic: recorded as a contract the units keep.
- **The commit's follow-up**: the old register mappings go back to the free list, the LQ / SQ get the commit counts.
- **The FTQ's pops**: the ROB keeps the µop's fetch block number (3 bits).
  - The blocks before the block of the latest committed µop are popped, up to 2 a cycle; after a replay, that block itself too.
  - Only when 3 or more blocks end in a cycle can a flush lose a predictor update (rare).

**Size in Yosys** (a hint only): control +4, issue queue +153, ROB +47 LUTs.

**What is left of the control**: the units' pipelines throwing away by mask and the DS register's payload, restoring the branch history and the RAS, exceptions and interrupts (`Plan/OOC.md` 19.4).

Recorded in `Plan/OOC.md` 19 (English and Japanese), 3.5, 3.9 and 4.3 of `Doc/UARCH`, the READMEs and the prompt log (answer 67 and the English of 68).

**Vivado request**
```
cd FPGA\OOO_OOC
synth_ooo.bat OOC_CTRL
synth_ooo.bat OOO_IQ
synth_ooo.bat OOC_ROB
```
<!-- /answer -->

## 69. 2026-10-27 23:44:13 JST

```text
I ran synth_ooo.bat for OOC_CTRL, OOO_IQ and OOC_ROB. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

I checked the three Vivado runs. CTRL and ROB meet timing, but the IQ missed by 0.261 ns on a path through its ports. I fixed it by registering ns_ok. All 20 unit tests PASS and all 200 mutations are detected. Not yet confirmed in Vivado.

**Results (physical LUTs / WNS)**

| Block | LUT | Before | WNS |
|---|---|---|---|
| OOC_CTRL | 355 | 340 | +13.444 ns |
| OOO_IQ | 1,885 | 1,775 | register to register +7.417 ns, **through the ports −0.261 ns** |
| OOC_ROB | 1,235 | 1,232 | +9.856 ns |

- **Where the IQ fails:** input ns_ok → issue select → output iss_src, 10 levels, 8.225 ns against the 8 ns limit.
- **Cause:** ns_ok was made by logic from the ROB head's state and then went through the IQ's select.

**Fix**
- ns_ok is now a register inside OOO_CTRL.
  - `ns_ok <= head_ns && !ns_busy_n && !fe_flush && !flush_q`
  - As a side effect, µops that wait for the ROB head (CSR writes and so on) issue a cycle later. They are rare, so CoreMark is hardly affected.
- synth_ooo.tcl gives ns_ok a 1 ns input delay only in the OOO_IQ run, for the time from the register's output to the IQ.
- tb_ctrl now expects the registered ns_ok. The mutations retargeted for it (M224/M225) are detected.

**Budget**
- The gap is 3.3k / 4.7k / 6.0k LUTs (low / middle / high).
- The control's first and second parts together are 355 LUTs, inside the original estimate of 1.5k to 2.5k.
- Recorded in section 19.4 of Plan/OOC(_J).md and 4.4 of Doc/UARCH(_J).md, pushed to dev in commit 444160b.

Please resynthesize the IQ and CTRL in Vivado and let me check output/*/summary.txt.

```bat
cd FPGA\OOO_OOC
synth_ooo.bat OOO_IQ
synth_ooo.bat OOC_CTRL
```

Two things to confirm:
- the WNS of the IQ's port path is positive;
- the CTRL's LUTs hardly change: it is only one more register bit.
<!-- /answer -->

## 70. 2026-10-28 00:25:44 JST

```text
I ran synth_ooo.bat OOO_IQ and synth_ooo.bat OOC_CTRL. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

I checked the resynthesis. With ns_ok registered, the IQ now fits in 50 MHz too.

| Block | LUT | Before | Register to register | Worst (with the ports) |
|---|---|---|---|---|
| OOO_IQ | **1,866** | 1,885 | +6.573 ns (12 levels) | **+0.776 ns** (−0.261 ns before) |
| OOC_CTRL | **350** | 355 | +13.433 ns (5 levels) | +11.501 ns |

- **The IQ's worst path:** now the IQ's own select, `vq` (a register) → `iss_src` (output), 12.215 ns; no longer the ns_ok input.
  - That slack is with a strict 6 ns output delay.
- **LUTs:** the IQ lost 19, CTRL 5.
- **Budget:** unchanged at 0.1k; the gap stays 3.3k / 4.7k / 6.0k LUTs (low / middle / high).

Every block measured in Vivado so far now meets 50 MHz. Recorded in section 19.4 of Plan/OOC(_J).md and 4.4 of Doc/UARCH(_J).md, with the English of answer 69 in PROMPT.md; pushed to dev in commit 6b2667c.
<!-- /answer -->

## 71. 2026-10-28 00:29:52 JST

```text
Go on with the control's next part: the units' pipelines dropping by branch mask and the DS register's payload.
```

<!-- answer -->
**Claude Code's answer**

As the control's third part, I built the units dropping µops by branch mask and the DS register's payload. On the way I found two bugs that lead to deadlock and fixed them. All 22 tests PASS and all 219 mutations are detected. Pushed to dev in commit 1dbff9a; not yet confirmed in Vivado.

**Bugs found**
1. **The LSU lost older µops issued in a restore cycle.** It threw away everything in E and M on every restore.
   - An older load or store issued in that cycle never completes, since its issue queue entry is already free.
   - `tb_lsu` never issued in a cycle of recovery, so it did not show. Issuing there, the old code deadlocks in 2,800 cycles.
2. **A µop could miss its wakeup between renaming and dispatch.** The busy bits were cleared at the write-back, but the issue queue takes only the wakeups of the cycle a µop is dispatched.
   - A µop renamed in that gap is never woken.
   - UARCH 6.5 was written assuming busy follows the wakeup buses, but 3.4 and the RTL still had the write-back ports.
   - No unit test ran renaming and the issue queue together, so it did not show.

**Changes**
- **OOO_STAGE (new):** one pipeline register of a unit. A µop with a killed bit is dropped, whether it is being taken or held.
  - Cleared bits leave the mask both when it is taken and while it is held.
  - I first left out the clear when taking. Without it, a stage that holds (like a divide) keeps a stale bit and another µop's kill hits it by mistake. tb_stage caught it.
- **OOO_DSREG (new):** the DS register's payload. Its ready bits are updated every cycle from the wakeup tags of the cycle before.
- **OOO_LSU:** drops by mask in E and M. A µop older than the branch goes on through a restore.
- **OOO_RENAME:** the busy bits are cleared by the issue queue's 6 wakeup tags.
- **OOO_IQ:** the wakeup tags go out. No delayed wakeup for a µop killed or flushed as it issues.
- **OOO_CTRL:** `ds_load`, the payload's enable.

**Size (Yosys, a hint only)**

| Block | Before | Now |
|---|---|---|
| OOC_RENAME | 3,456 | 3,753 (+297) |
| OOO_IQ | 2,986 | 3,163 (+177) |
| OOC_LSU | 3,055 | 3,148 (+93) |
| OOC_DSREG (new) | — | 121 |

The budget will be updated once the Vivado results are in.

**Timing to watch:** the busy bits now take the wakeup tags, which come late (about 13 ns) from the issue queue's select.
- The OOC_RENAME and OOC_DSREG harnesses take these tags unregistered with an input delay of 13 ns.
- If renaming does not fit, the busy bits are cleared a cycle after the tag and the DS register snoops two cycles back; the comparators double.

Recorded in chapter 20 of Plan/OOC(_J).md, 3.4 / 3.5 / 3.7 of Doc/UARCH(_J).md, the READMEs and PROMPT.md (the English of answer 70).

Please run these four in Vivado and let me check output/*/summary.txt. OOC_DSREG has been added to the list in synth_ooo.bat.

```bat
cd FPGA\OOO_OOC
synth_ooo.bat OOC_RENAME
synth_ooo.bat OOO_IQ
synth_ooo.bat OOC_LSU
synth_ooo.bat OOC_DSREG
```
<!-- /answer -->

## 72. 2026-10-28 01:28:52 JST

```text
I ran synth_ooo.bat for OOC_RENAME, OOO_IQ, OOC_LSU and OOC_DSREG. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

All four fit in 50 MHz. The busy bits can take the late wakeup tags directly.

| Block | LUT | Before | Worst slack | Note |
|---|---|---|---|---|
| OOC_RENAME | **2,702** | 2,464 | **+3.443 ns** | the worst path is the new one: `wk_tag` (arriving at 13 ns) → `busy`, 3 levels, 4.477 ns |
| OOO_IQ | **1,874** | 1,866 | +1.248 ns | +8 for the wakeup tags as outputs |
| OOC_LSU | **1,942** | 2,290 | +6.875 ns | −348 |
| OOC_DSREG | **69** | new | +6.835 ns | Yosys estimated 121 |

- **Renaming:** 3.4 ns to spare even with the tags assumed at 13 ns. The alternative raised last time (a cycle later, the DS register snooping two cycles back) is not needed.
- **The LSU's −348:** more than the change explains, and the reason is not clear.
  - I think Vivado could simplify the LQ / SQ write conditions now that they all share `e_iss`.
  - Flip-flops are +18 as expected (`m_bm` and the harness's 12 inputs), so nothing was trimmed away.
- **Budget:** renaming +238, the LSU −348, the IQ +8 added. DSREG's 69 stays inside the control's estimate (the control so far 350 + 69).
  - The gap is now **3.2k / 4.6k / 5.9k LUTs** (low / middle / high), 0.1k less than before.

Recorded in section 20.4 of Plan/OOC(_J).md and 4.4 of Doc/UARCH(_J).md, with the English of answer 71 in PROMPT.md; pushed to dev in commit 921385d.
<!-- /answer -->

## 73. 2026-10-28 18:39:36 JST

```text
Go on with the control's next part: the front end's restore (the FTQ entry's history and RAS state into OOO_FETCH).
```

<!-- answer -->
**Claude Code's answer**

As the control's fourth part, I built the front end's restore. All 23 tests PASS and all 232 mutations are detected; pushed to dev in commit 958d318. Not yet confirmed in Vivado.

**How it works**
- **Cycle R (the cycle the control redirects):** the front end stops at once with `be_stop` and issues no request and no block. Without the stop, a wrong-path block would enter the FTQ or the fetch buffer and go on to renaming.
  - In the same cycle OOO_FERS (new) takes the point to go back to into a register: for a misprediction the transfer of the ALU port that resolved it, for a trap or a replay the ROB's µop.
- **Cycle R+1:** it reads the FTQ entry of the point's block and restarts fetch.
  - The history is the block's history plus the slot branches up to the point: those before it not taken, the point itself with its actual outcome.
  - The RAS is the block's snapshot with the point's own push (call) or pop (return).

**For you to decide (D-15):** with the restart a cycle after the resolution, a misprediction costs 10 cycles from EX to EX instead of 9.
- −0.27 % / −0.22 % / −0.26 % in the model (6.260 → 6.243 CoreMark/MHz on -O2).
- Restarting in the same cycle would need the branch compare → the ROB's choice → the control → the checkpoint table → the FTQ read → the history push → TAGE's BRAM address in one cycle, which I judged impossible at 20 ns.
- It is applied as recommended and recorded as waiting for your confirmation.

**Found**
- **A trap can happen at a branch:** when a debug trigger is on a branch. The trap comes before the branch, so that branch's slot is kept out of the history. At first I thought it happens only at a resolved branch; tb_fers found it.
- **One more contract with the back end:** a µop's block is the block holding the last half of its instruction.
  - An instruction across two lines belongs to the second block in predecode, but the fetch buffer gives the first half's block number.
  - Decode has to add 1 to the block of such an instruction before passing it on.

**Other changes**
- `restore_port` added to OOO_CTRL.
- `rcv_ftq` / `rcv_end`, the point of a trap / replay, added to OOO_ROB. A replay can be the µop after the head.
- The bits of the slots before the point are always 0, so the prediction-bit input was removed.
- M128's target line was rewritten, so the mutation was retargeted.

**Size (Yosys):** OOC_FERS's logic is about 38 LUTs, plus 88 LUT RAM of the FTQ put in the harness.

Recorded in chapter 21 of Plan/OOC(_J).md, 3.1 / 3.2 and D-15 of Doc/UARCH(_J).md, the READMEs and PROMPT.md (the English of answer 72).

If you accept D-15, please also run these four in Vivado. OOC_FERS has been added to the list in synth_ooo.bat.

```bat
cd FPGA\OOO_OOC
synth_ooo.bat OOC_FERS
synth_ooo.bat OOC_FRONT
synth_ooo.bat OOC_ROB
synth_ooo.bat OOC_CTRL
```
<!-- /answer -->

## 74. 2026-10-28 19:56:35 JST

```text
I accept D-15 (restart a cycle after the resolution). I will run synth_ooo.bat for OOC_FERS, OOC_FRONT, OOC_ROB and OOC_CTRL.
```

<!-- answer -->
**Claude Code's answer**

I recorded D-15 (restart fetch a cycle after the resolution) as the author's decision. Pushed to dev in commit 3d0272c.

- **Doc/UARCH(_J).md chapter 9:** D-15's row now reads "as recommended (2026-10-28, entry 74)", and the history of decisions at the top of the chapter has it too.
- **Plan/OOC(_J).md 21.1:** "for the author to confirm" became "decided by the author as recommended on 2026-10-28".
- **PROMPT.md:** the English of answer 73 and prompt 74.

When the four Vivado results are in, I will check output/*/summary.txt and put them into the budget.
<!-- /answer -->

## 75. 2026-10-28 20:00:25 JST

```text
I ran synth_ooo.bat for OOC_FERS, OOC_FRONT, OOC_ROB and OOC_CTRL. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

FRONT, ROB and CTRL fit in 50 MHz. OOC_FERS had failed in synthesis because of my mistake in its harness; it is fixed. Please run OOC_FERS alone again.

| Block | LUT | Before | Worst slack | Note |
|---|---|---|---|---|
| OOC_FRONT | **2,611** | 2,588 | +0.835 ns (+0.574 before) | +23 for `be_stop` |
| OOC_ROB | **1,246** | 1,235 | +10.606 ns | +11 for `rcv_ftq` / `rcv_end` |
| OOC_CTRL | **351** | 350 | +11.501 ns | +1 for `restore_port` |
| OOC_FERS | — | | | failed in synthesis (below) |

- **Why OOC_FERS failed:** the harness took `ft_pc[38:4]` from a `[37:0]` bus; on that bus the line is bits 37:3.
  - Verilator did warn (SELRANGE), but I missed it because I was looking only at the errors of the lint.
  - After the fix I linted every harness again with `-Wall` and checked every warning. I also saved this practice in memory.
- **Budget:** +35 in all, so unchanged at 0.1k; the gap stays 3.2k / 4.6k / 5.9k LUTs.
- **About the last commit:** the three results were already in the files before I wrote my answer, and went into the last commit (3d0272c, D-15) without notice. This commit's message explains it.

Recorded in section 21.4 of Plan/OOC(_J).md; pushed to dev in commit 2afc2ea.

```bat
cd FPGA\OOO_OOC
synth_ooo.bat OOC_FERS
```
<!-- /answer -->

## 76. 2026-10-28 20:11:44 JST

```text
I ran synth_ooo.bat OOC_FERS. Please check output/OOC_FERS/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

OOC_FERS fits in 50 MHz too. That finishes the front end's restore, confirmed in Vivado.

| Item | Value |
|---|---|
| LUT | **151** (37 logic + 114 LUT RAM) |
| Register to register | +13.393 ns (10 levels) |
| Worst with the ports | +11.501 ns |

- **LUT RAM 114:** the FTQ put in the harness; only the bits read are kept.
- **Longest path:** the restore point's register → the FTQ read → the slot compares → the history bits, 10 levels.
- **Budget:** the restore's 37 logic LUTs go inside the control's estimate (the control so far 351 + 69 + 37). Widening the FTQ to 312 bits a block is the FTQ's matter and is counted at the assembly. The gap stays 3.2k / 4.6k / 5.9k LUTs.

Recorded in section 21.4 of Plan/OOC(_J).md and PROMPT.md (the English of answer 75); pushed to dev in commit ea49d54.

What is left of the control is its last part, exceptions and interrupts.
<!-- /answer -->

## 77. 2026-10-28 20:36:28 JST

```text
Go on with the control's last part: exceptions and interrupts (trap vector and CSR writes, interrupts at a µop boundary, refetch with fusion off after an exception inside a pair, FENCE.I / SFENCE.VMA).
```

<!-- answer -->
**Claude Code's answer**

I built the control's last part, exceptions, interrupts and the system µops; all five items of the control are now there. All 25 tests PASS and all 260 mutations are detected; pushed to dev in commit 8118131. Not yet confirmed in Vivado.

**OOO_TRAP (new): what happens at the ROB head**
- **Interrupts:** taken before the head µop. The ROB empties without committing anything, mepc gets the head's pc, mcause the interrupt cause, mtval 0, and fetch goes to mtvec (mtvec + 4 × cause when vectored).
  - Not taken while the head is a non-speculative µop that has issued (a CSR write, an MMIO load, WFI): its effect has already happened, so discarding it here would run it twice.
  - An interrupt wins over an exception at the head.
- **Exceptions:** mepc and mcause are written; mtval gets the tval of the oldest exception reported.
- **An exception inside a fused pair:** no CSR is written. The pair is fetched again from its pc with fusion off, and stays unfused until two instructions have committed or the next trap comes.
- **MRET:** its replay goes to mepc and updates mstatus.

**OOO_SYS (new): the system µops at the head**
- **FENCE:** waits until every committed store is in the D$.
- **FENCE.I:** waits the same, then FLUSHes the D$ and invalidates the I$ in mmRISC-2's order, and fetches again by replay.
  - The D$ FLUSH was added to OOO_DCAD as a fourth request.
  - The predictors are not cleared: predecode reads targets from the instructions themselves, so a stale entry costs only a misprediction.
- **SFENCE.VMA:** waits for the stores, flushes the TLBs (TLBs come in Phase 2), and replays.
- **WFI:** completes when an interrupt is pending in mie.

**Found in testing**
- Reports of tval from flushed or killed µops still on their way must not be taken; taken, such a stale report hides the next real one. None are taken in the cycles of flush_all and of a restore.
- The check "is the tval held the head's?" turned out redundant in bug injection and was removed.
- tb_sys's failures on other seeds were the tb's: the 200-cycle limit on WFI's wakeup was exceeded by chance about once a run. The limit was widened and five other seeds PASS.

**Size (Yosys)**

| Block | LUT |
|---|---|
| OOC_TRAP | 644 |
| OOC_SYS | 18 |

OOC_TRAP is larger than I expected; most of it, I think, is holding the oldest tval (three 64-bit report ports and their ROB-age compares). If Vivado also finds it large, the tval can be narrowed to 40 bits or the two dispatch slots can share one port.

**What is left before the assembly (G1):** the CSRs (`CORE_CSR`), MUL/DIV and the FPU, the I$ and the TLBs, debug, and the core's assembly itself. The contract for the CSRs' inputs and outputs is in section 22.1.

Recorded in chapter 22 of Plan/OOC(_J).md, 3.8 / 3.9 of Doc/UARCH(_J).md, the READMEs and PROMPT.md (the English of answer 76).

Please run these five in Vivado. OOC_TRAP and OOC_SYS have been added to the list in synth_ooo.bat.

```bat
cd FPGA\OOO_OOC
synth_ooo.bat OOC_TRAP
synth_ooo.bat OOC_SYS
synth_ooo.bat OOC_ROB
synth_ooo.bat OOC_CTRL
synth_ooo.bat OOC_LSUDC
```
<!-- /answer -->

## 78. 2026-10-28 21:57:49 JST

```text
I ran synth_ooo.bat for OOC_TRAP, OOC_SYS, OOC_ROB, OOC_CTRL and OOC_LSUDC. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

All five fit in 50 MHz. With this the control is all written and confirmed in Vivado.

| Block | LUT | Before | Worst slack | Note |
|---|---|---|---|---|
| OOC_TRAP | **203** | (Yosys 644) | +6.577 ns (13 levels) | the worst path is the tval's update (a report's ROB index → the age compares → the enable of `tv_d`) |
| OOC_SYS | **15** | (Yosys 18) | +11.501 ns | |
| OOC_ROB | **1,235** | 1,246 | +9.615 ns (17 levels, 8 before) | `irq` entered the commit and pointer paths |
| OOC_CTRL | **351** | 351 | +11.501 ns | `ns_busy` is only an existing register brought out |
| OOC_LSUDC | **7,678** | 7,562 | +0.820 ns (+1.552 before) | below |

- **OOC_TRAP:** Yosys's 644 is 203 in Vivado; narrowing the tval, raised last time, is not needed.
- **OOC_LSUDC's +116:** the LSU +2, the adapter +4, the D$ +110.
  - The D$ itself is unchanged. Until now the adapter sent only LOAD and STORE, so Vivado had trimmed the D$'s flush logic; now that FLUSH can arrive, that logic stays.
  - The worst path is the same as before, the D$'s stage 1 → the LSU's fill buffer. Its slack has narrowed to 0.8 ns.
- **Budget:** the control so far is 351 + 69 + 37 + 203 + 15 = **675 LUTs**, inside its 1.5k–2.5k estimate.
  - The ROB's −11 and the adapter's +4 do not show at 0.1k.
  - The D$ is counted at mmRISC-2's measured value, which includes its flush logic.
  - The gap stays 3.2k / 4.6k / 5.9k LUTs.

Recorded in section 22.4 of Plan/OOC(_J).md and PROMPT.md (the English of answer 77); pushed to dev in commit fb8ea6b.

What is left before the assembly (G1) are the blocks to bring from mmRISC-2 (CSR, MDU, FPU, I$, TLB, debug) and the assembly itself.
<!-- /answer -->

## 79. 2026-10-28 22:01:47 JST

```text
Go on: bring mmRISC-2's CORE_CSR (with L1) and CORE_MDU into mmRISC-3, wired to OOO_TRAP / OOO_SYS and port 0, with tests and Vivado scripts.
```

<!-- answer -->
**Claude Code's answer**

I brought mmRISC-2's CORE_CSR (with L1 applied) and CORE_MDU in, put them behind port 0 and wired them to OOO_TRAP / OOO_SYS. All 27 tests PASS and all 288 mutations are detected; pushed to dev in commit 5344aff. Not yet confirmed in Vivado.

**Brought in (RTL/CPU/CORE)**
- **CORE_CSR:** one change only: `instret_inc` went from one bit to "the number of instructions retired in a cycle (0 to 4)", since two µops that are fused pairs make four instructions.
- **CORE_MDU:** without change.
- Both were checked identical to mmRISC-2 Rev.02.

**New blocks**
- **OOO_CSRU:** CORE_CSR with `HPM_COUNTERS = 2` (L1 applied).
  - CSR µops are non-speculative, so they read, check and write their CSR in EX at the ROB head.
  - A µop that wrote completes marked for replay. A violation is an illegal instruction exception with the instruction bits as tval.
  - Trap entry, MRET / SRET, the vector, mepc / sepc, the interrupt to take and WFI's wakeup go to and from OOO_TRAP / OOO_SYS.
- **OOO_MDUP:** CORE_MDU behind port 0.
  - mul / mulw at latency 2.
  - mulh, clmul and the divides answer from outside: written when port 0's write slot is free, with their wakeup.
  - It gives the issue queue `mdu_ok` and `p0_hold`.

**Found on the way**
- **Port 0's write slot taken twice:** the issue queue let port 0 issue a latency-1 µop in the cycle after a multiply, so both used port 0's only write port in the same cycle. Now port 0 does not take it in that cycle (port 1 can).
- **OOO_TRAP's vector:** now the one the CSRs compute; delegation to S mode is done there too, so the own computation from mtvec is gone.
- **SRET and privilege checks added:** MRET below M, SRET under TSR, SFENCE.VMA under TVM and WFI under TW are illegal instructions.

**For you to decide (D-16):** CORE_MDU does one operation at a time, so mul goes at most one every 2 cycles.
- In the model −0.8 % / 0 / 0, only the matrix code of -O2; for this I added an option for the MDU's occupancy to the model.
- With every operation answered from outside: −2.4 % / −0.9 % / −3.0 %.
- A pipelined multiplier beside CORE_MDU would win the 0.8 % back, for LUTs and DSPs.
- As the budget is tight, it is in as recommended with CORE_MDU as it is, recorded as waiting for your confirmation.

**Size (Yosys, a hint only)**

| Block | Yosys | For comparison |
|---|---|---|
| OOC_CSRU | 2,823 | mmRISC-2's CSR is 4,750 in Vivado (4 HPM); L1's estimated saving −0.65k |
| OOC_MDUP | 3,742 | Yosys builds the multipliers of LUTs here; Vivado uses DSPs (mmRISC-2's MDU is 3,423) |

Recorded in chapter 23 of Plan/OOC(_J).md, 3.6 / 6.4 / D-16 of Doc/UARCH(_J).md, the READMEs of RTL/CPU/CORE and OOO, and PROMPT.md (the English of answer 78).

If you accept D-16, please also run these five in Vivado. OOC_CSRU and OOC_MDUP have been added to the list in synth_ooo.bat.

```bat
cd FPGA\OOO_OOC
synth_ooo.bat OOC_CSRU
synth_ooo.bat OOC_MDUP
synth_ooo.bat OOO_IQ
synth_ooo.bat OOC_TRAP
synth_ooo.bat OOC_SYS
```
<!-- /answer -->

## 80. 2026-10-28 22:47:46 JST

```text
Before deciding D-16, estimate what a pipelined multiplier beside CORE_MDU would cost in LUTs and DSPs.
```

<!-- answer -->
**Claude Code's answer**

I measured a pipelined multiplier beside CORE_MDU with Yosys (for the Artix-7, DSP48E1 inferred). Two stages to fit the latency-2 slot: the operands go into the DSPs in EX, and the sum is taken in the next cycle.

| Variant | LUT | DSP48E1 | FF | What it gains |
|---|---|---|---|---|
| **A: mul / mulw only** (the low 64 bits) | 143 | 10 | 100 | every multiply of CoreMark → wins back the 0.8 % on -O2 |
| **B: mulh / mulhsu / mulhu too** (the 128-bit product, signs corrected) | 499 | 16 | 326 | nothing more for CoreMark |

- **The multiplies and divides CoreMark uses:** the traces of all three builds have 93,960 mulw a run and no mulh, no divide. A wins back the whole 0.8 %.
- **The estimate with what is around it:** port 0's write-back gets one more 64-bit input (about 64 LUTs). mul / mulw no longer go through the MDU, and OOO_MDUP's mul path is no longer needed.
  - **A is about 0.2k LUTs and 10 DSPs.** mmRISC-2 uses only 32 of 240 DSPs, so there is room.
  - **B is about 0.55k LUTs and 16 DSPs.**
- **How it pays:** A's 0.2k is about 4 % of the gap (4.6k in the middle), and it helps only -O2's +0.8 % (0 on the other two builds). That is about the yield of the reductions taken so far; even fusion, the most efficient, was about 3 % per 1k on -O2.

**Recommendation:** keep D-16 with CORE_MDU now, and leave A as a candidate to buy back if the whole measurement at G1 leaves room.

Recorded in section 23.4 of Plan/OOC(_J).md and the D-16 row of UARCH; pushed to dev in commit 6ad3c31.
<!-- /answer -->

## 81. 2026-10-28 22:53:40 JST

```text
Add the pipelined mul/mulw multiplier (variant A) beside CORE_MDU now, with tests and Vivado scripts.
```

<!-- answer -->
**Claude Code's answer**

I added D-16's variant A, a pipelined multiplier for mul / mulw only, beside CORE_MDU. All 28 tests PASS and all 293 mutations are detected; pushed to dev in commit db85eec. Not yet confirmed in Vivado.

**Changes**
- **OOO_PMUL (new):** mul / mulw on port 0, one a cycle, at latency 2.
  - The operands go into the DSPs in EX; the next cycle the three 32×32 products are added and written into port 0's write-back register.
  - Only the low 64 bits are computed, so signs do not matter. mulw sign extends the low 32 bits.
  - It is killed by mask or flush in either cycle.
- **OOO_MDUP:** CORE_MDU now handles only mulh, clmul and the divides.
  - The mul path and the long / short distinction are no longer needed and were removed.
  - It writes when port 0's write-back slot is free: a cycle with no latency-1 writer in EX and no PMUL result.
- **OOO_IQ:** the MDU bit marks only the long operations. `iss_md_long` was removed.
- **Performance:** in the model, back to the pipelined multiplier's 6.243 / 6.680 / 6.066. Cost about 0.2k LUTs and 10 DSPs.
- **D-16:** recorded in UARCH as the author's decision (variant A).

**Tests**
- **tb_pmul (new):** back-to-back mul / mulw with operands on the signs and the 32-bit edges, against the product, with masks, kills and flushes.
- **tb_mdup:** port 0 now also issues muls for PMUL. And for a quarter of the time it issues no mul and a latency-1 writer every cycle, a situation where nothing can be written without `p0_hold`.
- **Bug injection:** the new mutations found two holes in my test benches.
  - tb_pmul built the mask from the ids left after the kill, so a µop never carried the killed bit.
  - tb_mdup's busy phase had muls mixed in, which left the slot free even without `p0_hold`.
  - Both were fixed, and those mutations are detected.

**Other:** in chapter 23 I had written the date as 2026-10-29 by mistake; corrected to 2026-10-28.

**Size (Yosys)**

| Block | Yosys |
|---|---|
| OOC_PMUL | 149 LUTs, 10 DSP48E1 |

Recorded in chapter 24 of Plan/OOC(_J).md, 3.6 and D-16 of Doc/UARCH(_J).md, the READMEs and PROMPT.md (the English of answer 80).

Please run these six in Vivado. OOC_PMUL has been added to the list in synth_ooo.bat.

```bat
cd FPGA\OOO_OOC
synth_ooo.bat OOC_PMUL
synth_ooo.bat OOC_CSRU
synth_ooo.bat OOC_MDUP
synth_ooo.bat OOO_IQ
synth_ooo.bat OOC_TRAP
synth_ooo.bat OOC_SYS
```
<!-- /answer -->

## 82. 2026-10-28 23:40:52 JST

```text
I ran synth_ooo.bat for OOC_PMUL, OOC_CSRU, OOC_MDUP, OOO_IQ, OOC_TRAP and OOC_SYS. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

All six fit in 50 MHz. But in the budget the gap grew by 0.3k, mostly for the multiplier added, to 3.5k / 4.9k / 6.2k LUTs.

| Block | LUT | DSP | Before | Worst slack |
|---|---|---|---|---|
| OOC_PMUL | **164** | 10 | (Yosys 149) | +11.501 ns |
| OOC_CSRU | **2,537** (CORE_CSR 2,499 of it) | 0 | (Yosys 2,823) | **+0.569 ns** (28 levels, the CSR read) |
| OOC_MDUP | **3,258** (CORE_MDU 3,240 of it) | 16 | (Yosys 3,759) | +5.921 ns |
| OOO_IQ | **1,894** | | 1,874 | +1.165 ns |
| OOC_TRAP | **217** | | 203 | +6.915 ns |
| OOC_SYS | **23** | | 15 | +11.501 ns |

- **The least margin is the CSR unit's**, +0.569 ns. The CSR read multiplexer is deep, the same structure as mmRISC-2's EX.
- **The size of the CSRs:** CORE_CSR synthesized alone is 2,499 LUTs, much smaller than the 4,750 LUTs of mmRISC-2's whole-chip report.
  - The flip-flops, 2,475 against 2,629, are nearly the same, so the circuit is the same. The LUT difference cannot be explained by L1 alone (two HPM counters fewer, estimated 0.65k).
  - The D$ shows the same kind of difference (7,497 in the chip against 5,325 alone), while the MDU hardly any (3,423 against 3,240).
  - The budget has counted mmRISC-2's blocks at their in-chip sizes, so that stays, and only what changed this time is added. Which way of counting is right will be settled by synthesizing the whole core at G1.
- **Measuring L1:** I added a parameter for the number of HPM counters to the harness. A run with 4 counters gives, by its difference to this run (2), what L1 saves, to replace the estimate.
- **Budget:** the multiplier's 164, its write-back input (about 64) and the issue queue's +20 were added. The trap and system units go inside the control's estimate (the control so far 697 in all).
  - The gap is **3.5k / 4.9k / 6.2k LUTs** (3.2k / 4.6k / 5.9k before).
  - DSPs: 42 of 240 (mmRISC-2's 32 plus the multiplier's 10).

Recorded in section 24.4 of Plan/OOC(_J).md, 4.4 of Doc/UARCH(_J).md and PROMPT.md (the English of answer 81); pushed to dev in commit 073a76f.

To measure L1, please run this one.

```bat
cd FPGA\OOO_OOC
synth_ooo.bat OOC_CSRU 20.0 1 "HPM=4"
```
<!-- /answer -->

## 83. 2026-10-28 23:49:29 JST

```text
I ran synth_ooo.bat OOC_CSRU 20.0 1 "HPM=4". Please check output/OOC_CSRU_HPM4/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

L1's saving measured out of context is **233 LUTs**. The budget, true to its base, keeps the −0.65k measured in the chip, so the gap stays at 3.5k / 4.9k / 6.2k LUTs. But comparing them brought out a large risk for the whole budget.

| Run | LUT | FF | WNS |
|---|---|---|---|
| 4 HPM counters (mmRISC-2's configuration) | **2,770** (CORE_CSR 2,732 of it) | 2,623 | +2.081 ns |
| 2 HPM counters (L1 applied) | 2,537 (CORE_CSR 2,499 of it) | 2,475 | +0.569 ns |
| **L1's saving (out of context)** | **−233** | **−148** | |
| L1's saving (measured in mmRISC-2's chip, REDUCE B1) | −0.65k | −0.15k | |

- **How the budget takes it:** the budget counts mmRISC-2's blocks at their in-chip sizes, and B1's −0.65k was measured in the chip too. So L1 stays at −0.65k.

**The risk found (a calibration is needed)**
- The 4-counter configuration is exactly mmRISC-2's CORE_CSR (2,623 flip-flops here, 2,629 in the chip). Yet its LUTs are 2,732 alone and 4,750 in the chip: **1.74×**.
- The other blocks with both numbers lean the same way: the D$ 1.41×, CORE_MDU 1.06×, L1's difference 2.8×.
  - The flip-flops agree, so the logic is the same and the chip adds LUTs. Possible causes: the crowded placement at 79 % LUTs / 93 % slices, replication for timing, logic moving across the hierarchy, LiteX's synthesis settings.
- **The out-of-order part (about 21k LUTs) has only out-of-context numbers.** If it grows the same way in the chip, the gap may grow by 1k (1.06×) to 15k (1.74×).
- So before G1 I propose a calibration measuring the ratio for a whole core: mmRISC-2's whole CPU_CORE (32,929 LUTs in the chip) synthesized alone with this flow. Summing every block cancels the differences at the hierarchy's boundaries.

Recorded in section 24.5 of Plan/OOC(_J).md, 4.1 / 6.4 of Doc/UARCH(_J).md and PROMPT.md (the English of answer 82); pushed to dev in commit b367994.
<!-- /answer -->

## 84. 2026-10-28 23:55:11 JST

```text
Set up the calibration: a synth_ooo run of mmRISC-2's whole CPU_CORE out of context, to compare with its 32,929 LUTs in the chip.
```

<!-- answer -->
**Claude Code's answer**

I set up the calibration run. It synthesizes mmRISC-2's whole CPU_CORE alone with the same flow as before. It has not run yet, so please run it in Vivado. The result is compared with the 32,929 LUTs in the chip.

**What was set up**
- **synth_ooo.tcl:** a new top name `MM2_CPU_CORE`.
  - It reads mmRISC-2 Rev.02's CPU_CORE from the repository beside this one, `../../../mmRISC-2/RTL`: IFU / EXU / LSU / RF / FRF / DEC / DECOMP / CSR / MDU, FPU_PIPE and CORE_MMU.
  - mmRISC-3's copies of CORE_CSR / CORE_DEC have the same module names, so this run reads only mmRISC-2's sources.
  - The settings are the same as before (xc7a100tcsg324-1, 20 ns, alone, place and route).
- **Parameters:** CPU_CORE's defaults were checked to be the chip build's (PMP 8, TLBs 16/32, BTB 256, the fetch queue 16 parcels).
- **Checks:** the sources pass Verilator's lint alone, and the script is complete Tcl.
- **synth_ooo.bat:** the command is noted. It takes long, so it is not in the loop of all runs.
- **Output:** summary.txt has the rows of the sub-blocks (u_*) too, for a block-by-block comparison with the chip's report.

**What the result decides** (the ratio R = 32,929 / the total alone)
- **R about 1.0 to 1.15:** synthesis alone is a fair measure of a whole core. The differences block by block seen in section 24.5 are logic counted in other blocks in the chip. The budget can stay as it is.
- **R about 1.3 or more:** the chip really adds LUTs. The out-of-order part's about 21k has to be counted again as "21k × R"; at R = 1.3 the gap grows by about 6k. Then I propose a trial synthesis of the whole chip before G1 and redoing the plan of reduction measures.

Recorded in chapter 25 of Plan/OOC(_J).md and PROMPT.md (the English of answer 83); pushed to dev in commit a2df4e0.

```bat
cd FPGA\OOO_OOC
synth_ooo.bat MM2_CPU_CORE
```
<!-- /answer -->

## 85. 2026-10-29 00:23:46 JST

```text
I ran synth_ooo.bat MM2_CPU_CORE. Please check output/MM2_CPU_CORE/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

The calibration came out with mmRISC-2's whole CPU_CORE at **33,014 LUTs** synthesized alone, nearly equal to the 32,929 LUTs in the chip (ratio R = 1.00, difference +0.3 %). Synthesis alone measures a whole core as the chip does, so the risk feared in section 24.5 is gone. The out-of-context numbers of the out-of-order part can be used as they are, and the budget (gap 3.5k / 4.9k / 6.2k LUTs) does not change.

| Block | In the chip | This run (alone) |
|---|---|---|
| **CPU_CORE whole** | **32,929** | **33,014** |
| FPU_PIPE | 8,815 | 8,660 |
| CORE_IFU (with the BTB) | 5,738 | 6,614 |
| CORE_CSR | 4,750 | **8,251** (the CSR synthesized alone: 2,732) |
| CORE_MMU | 4,190 | 4,269 (the 3 PMPs in it: **0** LUTs) |
| CORE_MDU | 3,423 | 3,410 |

- **What the block-by-block differences are:** not the amount of logic, but which block Vivado counts it in.
  - In this run the PMP checks inside the MMU have 0 LUTs and CORE_CSR has 8,251 LUTs. The PMP checks take the CSRs' pmpaddr / pmpmask as inputs, so Vivado optimizes them across the hierarchy's boundary into the CSR side.
  - In the chip part of them went into the CSR (4,750); in the CSR synthesized alone none (2,732). The D$'s 1.41× is the same kind of difference.
  - A block's number changes with the boundary it was measured at, so what to compare is the sum over whole units. The budget compares that way already.
- **Timing:** register to register +0.002 ns (28 levels); mmRISC-2's core just fits 50 MHz alone too. The −2.496 ns with the ports comes from assuming 6 ns of I/O delay on the combinational paths to the caches, a condition the chip does not have.

Recorded in section 25.3 of Plan/OOC(_J).md, 4.1 of Doc/UARCH(_J).md and PROMPT.md (the English of answer 84). "Compare sums, not blocks" is also kept in memory. Pushed to dev in commit 9cdc987.
<!-- /answer -->

## 86. 2026-10-29 00:28:41 JST

```text
I want to go on to the next step: where should I start?
```

<!-- answer -->
**Claude Code's answer**

Next is step 4 of the plan, putting the integer core together (UARCH chapter 8): run it in M-mode, bare metal, bring it up in lock-step with Spike and aim at G1.

G1 has two pass criteria.
- CoreMark in simulation within ±5 % of the model.
- The core synthesized alone in Vivado for its LUT count and 50 MHz.

The parts are almost all there, and the control is confirmed in Vivado. The lock-step framework (SIM/LOCKSTEP) exists too. The FPU, the MMU / TLBs and S mode come in Phase 2 or later, so they are not needed here.

**The "glue" not written yet**
1. **The ALU ports' pipelines:** the RR → EX → WB registers, the bypass network, branch resolution (deciding mispredictions, making `br_*`), the result multiplexer (ALU / CSR / PMUL / MDU).
2. **The format µops are passed in:** the fields from decode to DS, IQPL and ROB, and the wiring by the contracts such as `disp_md`.
3. **The predictors' update paths:** the TAGE update at commit and the BTB update at resolution.
4. **The I$:** mmRISC-2's ICACHE widened to 16 bytes. The first bring-up can use a simulation memory model instead and switch to the real one later.
5. **The commit-trace port:** to connect to the lock-step.
6. **The top OOO_CORE:** the wiring of every block.

**The recommended way**
- **I recommend writing the integration plan Plan/CORE(_J).md first:** the top's structure, the formats, the list of glue, the bring-up order and what G1 measures.
  - The blocks so far have their "contracts for the assembly" scattered over the chapters. Gathering them once before the biggest step keeps anything from being missed.
- The order after that:
  1. The ALU ports' pipelines with the bypass and branch resolution (with unit tests)
  2. Wiring OOO_CORE with memory models
  3. Straight-line integer programs
  4. riscv-arch-test
  5. CoreMark against the model
  6. Switching to the real I$ / D$
  7. The core alone in Vivado (G1)

It is also possible to skip the plan and start writing the ALU ports' pipelines straight away.
<!-- /answer -->

## 87. 2026-10-29 00:34:24 JST

```text
Start with the integration plan: write Plan/CORE(_J).md with the core's top, the payload formats, the glue still missing, the bring-up order and what G1 measures.
```

<!-- answer -->
**Claude Code's answer**

I wrote the integration plan Plan/CORE(_J).md. It is pushed to dev as commit d3f15c0; no RTL was changed.

**What the plan contains**
1. **The core's top OOO_CORE:** a diagram, and a list of the about 20 kinds of blocks used (how many of each, and the chapter each was written in).
2. **The formats between the blocks:**
   - The fields of a µop from fusion to dispatch.
   - The layout of the payload record (about 96 bits), split into the low 48 bits that port 2 reads and the high part for the ALU ports.
   - The fields given to the ROB.
3. **The glue not written yet (10 items):** the D2 / DS wiring, the ports' pipelines, the bypass and the register-file writes, branch resolution, port 0's units, port 2's fields and pairs, commit and the TAGE update, the front end, the commit trace, memory for the simulation.
4. **Decisions to make on the way (with recommendations):**
   - **4.1 / 4.5:** a µop's pc and a jalr's predicted target are not put in the payload; they are read in RR from small arrays holding a value per FTQ block.
   - **4.2:** the register file is written at the same clock as the result enters its write-back register. This keeps the 4-source bypass already measured. For it, the LSU must give out its M stage's result.
   - **4.3:** OOO_SYS completes in port 0's free slot.
   - **4.4:** fusion is off at first. The pairs that involve the LSU (ALU + load, store pairs) need new logic in the LSU, so they come last, and whether to keep them is decided after measuring what they bring in the model.
   - **4.6:** a model stands in for the I$ at first, replaced by the real one before CoreMark.
5. **The bring-up order:**

   | Step | What |
   |---|---|
   | B0 | The test bench |
   | B1 | The front end alone |
   | B2 | The core with ALU µops only |
   | B3 | Loads / stores |
   | B4 | riscv-arch-test |
   | B5 | Fusion, the MDU, interrupts |
   | B6 | CoreMark against the model |
   | B7 | The core alone synthesized in Vivado |

6. **What G1 measures:**
   - Correctness: no mismatch in lock-step.
   - Performance: within ±5 % of the model for each build (6.243 / 6.680 / 6.066).
   - Size and 50 MHz: checked by synthesizing the whole core alone. That out-of-context synthesis gives about the same value as in the chip was confirmed in section 25.3.

**What I found on the way**
- The LSU as it is cannot handle fused pairs (ALU + load, store pairs).
- The ports need a µop's pc and a jalr's predicted target, but nothing gives them yet.
- The ROB does not hold the instruction bits and the values written that the lock-step needs, so a simulation-only trace is put beside it.

All of these are in the plan. It is linked from Plan/README and from step 4 of UARCH chapter 8.
<!-- /answer -->

## 88. 2026-10-29 00:47:27 JST

```text
I accept the plan's recommendations (4.1 to 4.6). Start with B0: the core's test bench (ELF loader, memory model, HTIF, the commit trace into SIM/LOCKSTEP).
```

<!-- answer -->
**Claude Code's answer**

B0 (the core's test bench) is done. It is in `SIM/CORE`, pushed to dev as commit fffec6d; no RTL was changed.

**What the bench contains** ([bench.h](SIM/CORE/bench.h), [bench.cc](SIM/CORE/bench.cc))
- **Memory:** a sparse memory model holding the RAM region (64 MB from 0x8000_0000) in 4 KB pages, only as many as are used.
  - The ELF loader is written apart from LOCKSTEP's, so a wrong image shows as a mismatch.
  - The models of the I$ / D$ ports from B1 on read and write this memory.
- **HTIF:**
  - The exit and the console are taken from the committed stores. That gives them correctly in program order, whatever the caches still hold.
  - tohost is put back to 0 on the memory side, when the write reaches the memory.
- **The commit-trace port:** 2 slots a cycle. Each slot has the pc, 1 or 2 instructions, whether it is a fused pair, the trap, the one write (with `wr_first`) and each instruction's store. These are turned into LOCKSTEP's Commit records. The specification of the RTL's signals is in the README.
- **Also:**
  - Lock-step comparison.
  - A watchdog.
  - The architectural memory (the ELF plus the committed stores). B4's riscv-arch-test signature comes from it, so the write-back D$ does not affect it.
  - On a failure, the last 16 commits disassembled.

**Verification** ([results/standin.txt](SIM/CORE/results/standin.txt), [results/mutate.txt](SIM/CORE/results/mutate.txt))
- The stand-in core is a second Spike running on the bench's memory.
  - Stores to tohost are delayed 0 to 24 cycles in a queue, imitating being behind the SQ and the D$.
  - Commits go through the port, 0 to 2 slots a cycle, fused at random.
- All 177 programs passed: 175 riscv-tests and 2 CoreMark builds.
  - Exit codes and console output agree with the reference, and so does the memory.
  - The only nonzero exit codes are ma_data and amocas_*, which are nonzero on the reference too.
- All 2,019 cases with a broken port field were caught by the lock-step.
- Bug injection into the bench itself: 18/18 detected. It found one redundant piece of code, which I removed, and where detection fell short I added a unit check of HTIF.
- LOCKSTEP's own self-test still passes.

**Rules decided (recorded in Plan/CORE section 5.1)**
1. **Polling tohost:** in the core a character's store reaches the memory later than in Spike, so `while (tohost)` loops more times. I changed LOCKSTEP so that, as for the counters, loads of tohost / fromhost give the core's value to the reference. In CoreMark there are 3,667 and 6,715 such extra loads, and the reference loops the same number of times.
2. **tohost's line is not kept in the D$ (to do at B3):** with the real write-back D$ the core would read back the character it wrote for ever. At B3, when the D$ comes in, this line is made non-cacheable as a bench parameter.
3. **The architectural memory is right only without address translation:** stores commit with their virtual address. The physical address is added to the trace in Phase 2. The comparison is left out for rv64si-p-dirty, which uses translation.

Decisions 4.1 to 4.6 are recorded as accepted in Plan/CORE(_J), and answer 87 and prompt 88 were added to PROMPT.md.
<!-- /answer -->

## 89. 2026-10-29 17:55:34 JST

```text
Go on with B1: the front end alone (fetch through the I$ model, FBUF, decode, fusion off), checked against Spike's pc sequence.
```

<!-- answer -->
**Claude Code's answer**

B1 (the front end alone) is done. It is pushed to dev as commit 04effe7.

**What I built**
- **[OOO_FRONT.sv](RTL/CPU/OOO/OOO_FRONT/OOO_FRONT.sv):** a module that puts the front end together up to the D1/D2 register. OOO_CORE will use it as it is.
  - It holds fetch, the FTQ, the restore (FERS), the fetch buffer, decode, and the group register of 4 decoded instructions.
  - Besides those, it has the credit (the fetch buffer's and the FTQ's free room), the branch outcomes kept for the TAGE update, and the target array for jalr.
- **[tb_front.cpp](SIM/CORE/tb_front.cpp):** a bench that fetches and decodes real programs through the I$ model and compares them with Spike's path.
  - The bench stands in for D2 and the back end (redirect on a misprediction, flush on traps and FENCE.I, commit, the FTQ's pops).
  - Every TAGE update and every restore is compared with what the block's push wrote.

**Decided on the way (Plan/CORE section 5.2)**
- **A skid between D1 and D2:** there is the contract (OOC 13.6) that the fetch buffer's consume must not depend on D2's result. Without the skid every group leaves a 1-cycle gap, 4 instructions in 3 cycles. The skid's select is on the 164 raw bits before decode, cheaper than on the 680 bits after it.
- **FTQ:** widened to 312 bits a block, with a fourth read port, reading the head, for the TAGE update.
- **One FTQ pop a cycle:** OOO_CTRL changed from 2 to 1, because TAGE can update only one block a cycle. Its unit test and the bug injection (M330) were updated too.
- **How the branch outcomes are kept:** in flip-flops by block × parcel, turned into slots at the pop.
- In Phase 1 the FP fields are not put in the group register.

**Results**
- 175 riscv-tests (2 seeds) and 2 CoreMark builds all ran to their exit in the same order as Spike.
  - CoreMark's 1.74 million TAGE updates and its restores all matched too.
- What the front end can deliver, with 2 instructions taken a cycle and no I$ miss: 1.51 / 1.56 instructions a cycle.
- Bug injection into the front end's glue: 35/35 detected.
  - At first 4 slipped through. A wrong RAS slice or not stopping fetch in cycle R only costs a few predictions, or shows nothing outside.
  - So the bench got an exact comparison with what was pushed, and a check that "there is no I$ request in cycle R".
- For the changed FTQ / FBUF / CTRL, the unit tests and the unit bug injection (35/35) pass as well.

**The gap with the model (to look at before B6)**
- Mispredicted conditional branches are 6,466 / 5,870, 25 to 73 % more than the model's 4,772 / 4,177.
- The updates' contents were all checked correct, so the cause is the update's timing. The model updates TAGE at once, but in the real core it is not updated until the block's last instruction commits and the block is popped.
- In the core commit comes about 6 cycles after D2, so I expect CoreMark's cycles to grow by 1 to 1.5 %. The model does not have this.

**Request:** please run `synth_ooo.bat OOC_FE` in Vivado. It checks the LUTs and 50 MHz of the whole front end. The .bat is unchanged; only synth_ooo.tcl and OOC_WRAP.sv were changed.
<!-- /answer -->

## 90. 2026-10-29 19:04:07 JST

```text
Add the TAGE update delay to the model (tageblk.h / ooo.h) and measure how much it changes CoreMark's mispredictions and cycles, against B1's numbers.
```

<!-- answer -->
**Claude Code's answer**

I put the TAGE update delay into the model and compared it with B1. In short, **the loss from the update delay itself is small, and the main cause of B1's extra mispredictions lies elsewhere**: the history lag changes every time fetch stalls. Pushed to dev as commit 5e222fb.

**What was added to the model** (`Plan/model`, [results/tagedelay.txt](Plan/model/results/tagedelay.txt))
- **tage.h:** prediction and update are apart. As in the RTL, the update is computed from the entries as read at the prediction, and writes them back whole.
- **ooo.h:** with `upd=1`, each branch's update is made at that branch's commit.
- **tageblk.h:** with `delay`, a block's update comes the given number of blocks later.
- **A new mode `model tageref`:** runs the RTL's TAGE algorithm itself (tage_ref.h, which tb_tage holds the RTL to) on the same blocks. The history lag, the update delay and fetch stalls can be set.
- **tb_front:** now measures the distance from a block's prediction to its update (6.4 to 6.6 blocks on the true path). It can also give the mispredictions by branch address.

**Results (mispredicted conditional branches, CoreMark/MHz in brackets)**

| | g14 -O2 | g14 sf+flto |
|---|---|---|
| Model (TAGE per branch, updated at once) | 4,393 (6.193) | 3,291 (6.680) |
| Model, updated at commit | 4,436 (6.191) | 3,393 (6.675) |
| The RTL's algorithm, updated 6 blocks later | 5,279 | 4,526 |
| The same, fetch stalled at 10 % / 30 % of the blocks | 7,177 / 9,643 | 6,225 / 7,295 |
| **B1** (D2 at random / at full speed) | **6,582 / 8,426** | **5,742 / 6,106** |

1. **The update at commit costs little:** −0.03 to −0.15 % of CoreMark/MHz with the per-branch TAGE. Even the RTL's per-block TAGE, delayed by B1's distance, gets only +700 / +600.
2. **The main cause is the history lag varying:**
   - The RTL's TAGE reads its tables at F0 with the history of that cycle. While fetch streams, the 2 blocks in F1/F2 are not in the history; right after a stall (a full FTQ, an I$ miss, an override, a restore) fewer are missing.
   - So the same branch reads with another history, that is another row, and its training does not stick.
   - In a loop of one block a pass (`core_bench_list` at 0x80000f18) the exit and one iteration are missed every time. 1,788 in B1; 1,687 in the model with 30 % stalls; almost 0 with a constant lag.
3. **The size of the loss:** B1 mispredicts +2.2k to +4.0k (-O2) and +2.5k to +2.8k (sf+flto) more than the model, +1.4 to +2.5 % / +1.7 to +1.9 % in cycles. Inside G1's ±5 %, but a loss.
4. **The fix (proposed as D-17, entered as open in UARCH chapter 9):**
   - Fix the read's lag at 2 blocks always. The bits of the 2 blocks before are left out of the index even when they are already in the history.
   - The cost is about 0.15k LUTs (a 7:1 shift before the fold, 2 more bits a block in the FTQ).
   - Expected: about −1.2k to −3.1k mispredictions, **CoreMark +0.8 to +2.0 %**.
5. **To do before B6:** even with D-17, the RTL's TAGE is +0.9k / +1.2k above the model's per-branch TAGE (cycles +0.6 % / +0.8 %). The model used as G1's reference (ooo.h) should get the RTL's TAGE structure and the commit timing.

Besides that, with `-lag` the bench could resolve a branch after its commit, which made the update comparison fail falsely; I fixed it. After the fix I reran the whole B1 set, which all passed, and the bug injection is still 35/35.

**The Vivado result of OOC_FE was there**
- 6,602 LUTs, **WNS −2.168 ns** (23 levels): it does not reach 50 MHz.
- The worst path is the loop: the fetch buffer's window → slot 2's decode → decode's `cut` → `consume` → the buffer's head parcel.
- Putting `cut` into `consume` put a whole decode into the loop OOC 13.6 forbade. B1's RTL needs fixing.
<!-- /answer -->

## 91. 2026-10-29 19:41:01 JST

```text
Analyze the OOC_FE result (WNS -2.168 ns through decode's cut into the fetch buffer's consume) and fix the path, with tests and Vivado scripts.
```

<!-- answer -->
**Claude Code's answer**

I analyzed OOC_FE's timing violation and took decode out of the path that caused it. Commit 2fbe489 is pushed to dev. Whether it now fits 50 MHz is not yet confirmed by a Vivado rerun.

**Analysis (Plan/OOC chapter 26)**
- All ten worst paths were one loop: from the fetch buffer's head pointer (`hb`) back to the head parcel (`hoff`) and `hb` itself.
- The worst path, step by step:

  | Section | Time |
  |---|---|
  | LUTRAM read | 3.5 ns |
  | Window and length chain (to slot 2's bits) | 10.0 ns |
  | RVC expansion | 12.7 ns |
  | CORE_DEC's illegal | 16.9 ns |
  | `cut` | 17.6 ns |
  | `consume` → `npop` → `hoff` | 22.8 ns |

- The **7.6 ns from 10.0 to 17.6 ns are a full decode**. Plan/CORE 2.1 sent decode's `cut` to the fetch buffer, which put decode into the loop that OOC 13.6 forbade.
- Size: 6,602 LUTs, 1.08k more than the parts measured alone.
  - Most of it is the FTQ with four read ports, +0.6k; the budget allowed only 0.15k to 0.25k for widening it.
  - The remaining 0.3k or so is B1's glue.
  - The budget table (UARCH 4.4) is updated after the rerun.

**The fix**
- **New module OOO_RARE:** tells from the first parcel alone whether an instruction is of a "rare class" decoded in slot 0 only. A few gates, 2 or 3 levels.
  - 32-bit instructions by major opcode (LOAD-FP, STORE-FP, FMA, OP-FP, AMO, MISC-MEM, SYSTEM).
  - Compressed: c.fld / c.fsd / c.fldsp / c.fsdsp / c.ebreak.
- **OOO_FRONT:** the fetch buffer's group is cut with OOO_RARE on the buffer's own output, before the skid's select, so both decode and the skid's select leave the loop.
- **OOO_DEC:** illegal is no longer a cut class; it is reported in every slot (in slots 1 to 3 for illegal encodings outside the rare opcodes).
- The OOC 13.6 contract now reads: the count taken comes only from the buffer's own valid instructions, a predecode of a few gates and a registered stall; nothing of decode.
- Expected: decode's 7.6 ns and the skid's select leave, OOO_RARE's ~1 ns enters: about +4 ns of slack.

**Verification**
- **tb_dec:** the expected `cut` checked against a predecode written in the test from the opcode list; every legal instruction of a rare class caught by OOO_RARE; illegal in every slot. 3 million instructions (1.5 million illegal) and every RVC encoding: PASS.
- **Unit tests:** all 28 PASS.
- **B1:** 175 riscv-tests × 2 seeds and both CoreMark builds PASS; CoreMark's numbers unchanged.
- **Bug injection:**
  - Unit side: 10 mutations (OOO_RARE's opcodes, c.ebreak, RVC FP loads/stores, the RVC/32-bit select, the old behaviour of illegal in slot 0 only; M192 rewritten, M331 to M339 added), all detected. The unit campaign now has 303.
  - Front-end side: still 35/35.
- **Scripts:** OOO_RARE added to synth_ooo.tcl and yosys_size.sh. The .bat unchanged. The first OOC_FE reports committed too.

**Request:** please rerun in Vivado:
- `synth_ooo.bat OOC_FE` (to check the fix)
- `synth_ooo.bat OOC_DEC` (illegal now in every slot and cut taken from OOO_RARE, so its size may move a little)
<!-- /answer -->

## 92. 2026-10-29 21:39:05 JST

```text
I ran synth_ooo.bat OOC_FE and synth_ooo.bat OOC_DEC. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

OOC_FE now fits 50 MHz, but only by +0.030 ns. The loop from last time has left the worst paths; D1's forward path (read the buffer, decode slot 3) is the limit now. The results are recorded and pushed (57ba5e4).

**Results**

| Run | LUT | Slack | Levels |
|---|---|---|---|
| OOC_FE (before) | 6,602 | −2.168 ns | 23 |
| **OOC_FE (now)** | **6,162** | **+0.030 ns** | 18 |
| OOC_DEC | 1,823 → **1,807** | +7.813 → **+7.900 ns** | 9 |

- **Size:** 440 LUTs fewer, nearly all in the fetch buffer with decode (3,240 → 2,849).
- **Against the budget:** the budget counted the parts one by one (OOC_FRONT 2,588, FBUF 940, FTQ 148, DEC 1,808, the FTQ widened 0.15k to 0.25k). OOC_FE is +0.4k to 0.5k above them: the FTQ's four reads and the glue. UARCH 4.4 now uses the measured 6,162 instead, and the gap is **4.0k / 5.4k / 6.6k** (was 3.5k / 4.9k / 6.2k).

**The new worst path**
All ten worst paths are one forward path, not a loop, into `g_d[3]`:

| ns | Section |
|---|---|
| 1.0 → 4.0 | `hb` (fan-out 150) → LUTRAM read |
| → 10.9 | window and length chain to slot 3's bits (through the skid's select) |
| → 20.4 | the whole decode of slot 3 (9 levels, 9.5 ns) |

- This is D1 as planned (read and decode in one cycle), 80 % of it routing.
- In 13.6 even 0.539 ns was judged too thin and fixed. Inside the whole core place and route gets worse, so 0.030 ns is not enough.
- The loop's own slack is not in the reports (all ten end at `g_d[3]`).

**What can be done (Plan/OOC 26.7)**
- **A. One raw stage before decode (recommended)**
  - The window goes into a raw register first and is decoded the next cycle. Both the read side and the decode side are expected at about 8 ns of slack.
  - The cost is a cycle more from a redirect: in the model CoreMark/MHz 6.191 → 6.172, 6.675 → 6.660 (−0.3 % / −0.2 %); also about 170 FFs and a few tens of LUTs.
  - To keep the fetch buffer's `consume` free of D2's `g_take` (the 13.6 contract), the current skid stays as a second raw entry.
- **B. Trim D1 as it is:** duplicate `hb`, precompute the instruction starts. Expected 1 to 2 ns, not sure.
- **Not possible:** decoding only slots 2–3 a cycle later, since OOO_FUSE may take all 4 slots in the cycle after the group arrives.

If A is taken, I fix OOO_FRONT, B1 and the front end's bug injection, and add a report of the loop's own worst path to synth_ooo.tcl.
<!-- /answer -->

## 93. 2026-10-29 21:58:09 JST

```text
Implement plan A of Plan/OOC 26.7 (a raw stage before decode), with B1, the bug injection and the Vivado script.
```

<!-- answer -->
**Claude Code's answer**

I put plan A (a raw stage before decode, D1a / D1b) in, checked it with B1 and the bug injection, and pushed it (d8de863). It is not yet measured in Vivado. B1 also found another problem: the FTQ's 8 blocks are too shallow and cap what the front end can deliver.

**RTL (OOO_FRONT)**
- **D1a:** the fetch buffer's group goes raw into a register R; when R is not freed that cycle, into the skid S.
- **D1b:** R is decoded into the group register. The FTQ's two line reads also come from R, now a register.
- Whether R is freed waits for D2's `g_take`, but it only enables R and S. `consume` is as before, from S's occupancy (a register) only. The 13.6 contract holds.
- S holds a group only while R does, so groups of 4 follow without a bubble.
- Lint (-Wall): only PINCONNECTEMPTY, as before.

**Verification**
- **B1:** 175 riscv-tests × 2 seeds and both CoreMark builds both ways: all PASS.
- **Bug injection:** 40 of 40 detected.
  - 5 added for R and S, 1 for R alone not flushed, 7 rewritten for the new lines.
  - The first run left "R empty not counted as free", which only adds a bubble and changes no result. The bench now checks that S holds a group only while R does, which catches it.
- **Vivado script:** OOC_FE's summary.txt now gives the worst path into each stage of D1 (the loop, D1a, D1b), with the full paths in timing_d1.rpt, so the loop's slack shows even when it is not among the ten worst.

**What B1 found: the FTQ is too shallow**
With `-full` the delivered rate fell from 1.504 / 1.560 to **1.442 / 1.488 instructions a cycle (−4 %)**, against the model's −0.3 %. The cause is the FTQ.

| D2 to commit | before, FTQ 8 | now, FTQ 8 | now, FTQ 16 |
|---|---|---|---|
| 2 cycles | 1.834 | 1.814 | 1.826 |
| 7 cycles | 1.668 | 1.572 | 1.824 |
| 10 cycles | 1.455 | 1.386 | 1.825 |
| 4 to 10 at random | 1.504 | 1.442 | **1.824** |

(g14 -O2; sf + -flto shows the same.)

- A block stays in the FTQ from its push to the pop after its last commit. With 8 blocks, with or without the stage, the rate falls the longer commit takes (9 % at 7 cycles, 21 % at 10).
- In the real core the FTQ must cover the ROB (24 µops, about 7 blocks), the fetch buffer (4 blocks) and D1 / D2: 14 to 16 blocks.
- The model has no FTQ, so its CoreMark numbers assume one deep enough.
- With 16 blocks it delivers 1.82 to 1.83 instructions a cycle whatever the delay, and the raw stage then costs 0.0 to 0.5 %, as the model said.
- The cost of 16 blocks is estimated at about +0.1k to 0.2k LUTs: the LUTRAM is the same, the slot branches' outcome flip-flops go from 128 to 256, and every FTQ index gets a bit.
- I entered it as **D-18** in UARCH chapter 9, "Open". The script that measures it is SIM/CORE/ftqdepth.sh.

Recorded in Plan/OOC 26.8, Plan/CORE B1-1, UARCH D-18, the READMEs and PROMPT.md, in both languages.

**Vivado request:** please run `synth_ooo.bat OOC_FE`. I expect several ns of slack on both D1a and D1b, and about +0.2k in size. If you take D-18, running it after the FTQ is made 16 saves a second Vivado run.
<!-- /answer -->

## 94. 2026-10-29 22:22:55 JST

```text
I accept D-18. Make the FTQ 16 blocks (OOO_FRONT, OOO_FTQ, FERS, CTRL, ROB and their tests), then I will run synth_ooo.bat OOC_FE.
```

<!-- answer -->
**Claude Code's answer**

The FTQ is now 16 blocks (D-18), on top of D1a / D1b. All tests and both bug-injection campaigns pass, and it is pushed as 724f535. Next is your Vivado run of OOC_FE.

**RTL**
- OOO_FTQ and OOO_FRONT now default to 16 entries with a 4-bit index; OOO_FERS, OOO_FBUF, OOO_CTRL and OOO_ROB default to a 4-bit index too.
- Every block was already written for any power-of-two depth, so nothing else in the logic had to change.
- I rewrote the credit (the smaller of the fetch buffer's and the FTQ's free room) without a truncated intermediate, because `-Wall` lint warned once the FTQ's free count grew to 5 bits.

**Tests**
- Unit tests updated for 16 entries: tb_ftq, tb_fers, tb_fbuf, tb_ctrl, tb_rob and tb_fetch.
- B1 (`tb_front` / `build_front.sh`) now defaults to 16; `FTQW=3` still builds the 8-entry version.

| Check | Result |
|---|---|
| Unit tests (28) | All PASS |
| B1 | All PASS |
| Delivered rate (`-full`) | **1.824 / 1.826** instructions/cycle (1.442 / 1.488 with 8) |
| Unit bug injection (FTQ, FERS, FBUF, CTRL, ROB, fetch) | 84 of 84 detected |
| Front-end bug injection | 40 of 40 detected |

**A gap the change opened, now closed**
- With 16 blocks, the FTQ never fills at B1's commit delays (4–10 cycles). So two mutations went undetected at first: "credit: the FTQ not counted" and "FTQ: one free too many".
- B1 now also runs the riscv-tests with `-full` and commit 40 cycles after D2. There the FTQ fills for about 100–200 cycles per program; `tb_front -v` reports the count.
- The bug-injection campaign runs that case as well, and both mutations are now caught.

**Harnesses**
- OOC_FE now uses the 16-block FTQ (295 bits in, 753 out), and `-Wall` lint shows only the expected PINCONNECTEMPTY.
- OOC_ROB, OOC_FBUF, OOC_FTQ, OOC_CTRL and OOC_FERS stay at the 8 blocks their reports were measured with. I added an explicit `FTQW(3)` to OOC_ROB, since it had been relying on the default.

D-18 is marked decided in UARCH chapter 9. The FTQ depth is updated in UARCH, Plan/CORE and the READMEs, and the work is recorded in Plan/OOC 26.9, all in both languages. PROMPT.md is updated too.

**Please run `synth_ooo.bat OOC_FE`.** It measures D1a / D1b and the 16-block FTQ together. I expect several ns of slack on both D1a and D1b, and the size to grow by about 0.2k for the raw register plus 0.1k–0.2k for the deeper FTQ. I will update the UARCH 4.4 budget from the result.
<!-- /answer -->

## 95. 2026-10-29 23:20:37 JST

```text
I ran synth_ooo.bat OOC_FE. Please check output/OOC_FE/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

OOC_FE fits 50 MHz (slack +0.622 ns). The D1a / D1b split worked as intended, and making the FTQ 16 barely grew the whole. But the worst path has moved to the fetch buffer's loop, and I think 0.622 ns is too thin. The result is recorded and pushed (d6ef8b4).

**Results**

| Path | Slack | Levels |
|---|---|---|
| The fetch buffer's loop (into `hb` / `hoff`) | **+0.622 ns** | 18 |
| D1a (into R and the skid) | +5.005 ns | 14 |
| D1b (R → decode → group register) | +5.752 ns | 15 |
| Next: the uBTB's training from the I$ answer | +0.715 ns | 16 |

- **Size:** 6,171 LUTs, only 9 more than before.
  - The FTQ at 16 entries went 745 → 950 LUTs (+205); the LUTRAM stays 302, the logic grew.
  - Decode, now reading from a register, no longer needs replicating: decode and around lost 163 LUTs, which nearly cancels the FTQ.
  - FFs +319: R's 164 bits and the branch-outcome flip-flops.
- **Budget:** a row is added to UARCH 4.4; the gap stays 4.0k / 5.4k / 6.6k.

**The new worst path (the fetch buffer's loop)**

| ns | Section |
|---|---|
| 1.0 → 5.0 | `hb` → LUTRAM read |
| → 12.0 | window and length chain, to slot 3's first parcel (all 16 bits) |
| → 15.1 | OOO_RARE and the group's run (4 levels) |
| → 20.0 | `consume` → `npop` → `hb` |

- In the fetch buffer alone (13.7, +3.5 ns), `consume` waited only for the slots' valid bits, which come early from the length chain.
- OOO_RARE needs slot 3's parcel itself, which does not come out until 12.0 ns, so it is about 3 ns worse than 26.3 expected. The FTQ of 16 has nothing to do with this path.
- The uBTB training (+0.715 ns) was already +0.574 ns in OOC_FRONT alone. It starts at the harness's register of the I$ answer, so its real timing depends on how the I$ gives its data in the core. Not touched now.

**Proposal (Plan/OOC 26.11)**
- In OOO_FBUF, OOO_RARE on each of the window's 8 parcels. It runs in parallel with the length chain, so each slot only takes its own bit with the same select as its length.
- Slot 3's rare bit then arrives at about 10 ns. The loop gains about 2 to 3 ns, back near the +3.5 ns of the buffer alone.
- Cost: about 20 to 40 LUTs, no storage.

Recorded in Plan/OOC 26.10 to 26.11, UARCH 4.4 and PROMPT.md, in both languages.
<!-- /answer -->

## 96. 2026-10-29 23:25:29 JST

```text
Implement Plan/OOC 26.11: OOO_RARE on the window's parcels in OOO_FBUF (out_rare), with tb_fbuf, B1, the bug injection and the scripts.
```

<!-- answer -->
**Claude Code's answer**

I put Plan/OOC 26.11 in, checked it with the tests and the bug injection, and pushed it (50df306). The rare classes are now told from the fetch buffer's window parcels. Not yet measured in Vivado.

**RTL**
- **OOO_FBUF:** OOO_RARE on each of the window's 8 parcels, and a new output `out_rare`.
  - Each slot takes its bit with the same select that takes its length bit. It runs in parallel with the length chain, so it does not wait for slot 3's parcel.
- **OOO_FRONT:** cuts the group at `out_rare`, and drops its four OOO_RARE on the slots' bits. The group is cut the same way as before.
- **OOC_FBUF harness:**
  - It now cuts its group at the rare classes as the core does, so the harness's loop is the core's.
  - `out_rare` goes to the output (173 bits).
  - The `free_n` connection left out since B1 is fixed.
  - Lint (-Wall): only the expected PINCONNECTEMPTY.

**Verification**
- **tb_fbuf:** every slot's `out_rare` checked against a predecode written in the test from the opcode list; c.ebreak put in the random program. 4 seeds PASS, about 270,000 to 370,000 rare slots each.
- **Unit tests:** all 28 PASS.
- **B1:** PASS, with exactly the same numbers (1.824 / 1.826 instructions a cycle with `-full`).
- **Bug injection:**
  - M340 to M342 added: a slot's bit from the next parcel, every window parcel told by the first, AMO missed. The unit campaign now has 306.
  - With the fetch buffer's mutations and OOO_RARE's in tb_dec: 18/18 detected.
  - Front-end side: 40/40.

Recorded in Plan/OOC 26.12, Plan/CORE B1-1, the READMEs and PROMPT.md, in both languages.

**Vivado request:** please run `synth_ooo.bat OOC_FE` and `synth_ooo.bat OOC_FBUF`. I expect the loop at about +2.5 to 3.5 ns, and about 20 to 40 LUTs more.
<!-- /answer -->

## 97. 2026-10-29 23:49:17 JST

```text
I ran synth_ooo.bat OOC_FE and synth_ooo.bat OOC_FBUF. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

OOC_FE meets 50 MHz with +0.868 ns of slack. The loop improved less than I expected: +0.39 ns, not the 2–3 ns I estimated. Three groups of paths now sit at about +0.9–1.0 ns, so a fix to the loop alone would not widen the margin. The results and a proposal are recorded and pushed (5d4b356).

**Results**

| Run | LUT | Slack | Levels |
|---|---|---|---|
| OOC_FBUF (before, no cut) | 940 | +3.541 ns | 14 |
| **OOC_FBUF (cut at `out_rare`, as in the core)** | **1,001** | **+3.078 ns** | 15 |
| OOC_FE (before) | 6,171 | +0.622 ns | 18 |
| **OOC_FE (`out_rare`)** | **6,231** | **+0.868 ns** | 18 |

| OOC_FE's paths | Before | Now |
|---|---|---|
| Fetch buffer loop | +0.622 ns | +1.016 ns |
| D1a / D1b | +5.0 / +5.8 ns | +5.3 / +5.5 ns |
| TAGE update (FTQ head read → TAGE block RAM write) | not in the worst 10 | **+0.868 ns** |
| uBTB training (fetch's `carry_v` → predecode → entry write) | +0.715 ns | +0.943 ns |

- **The loop:** the rare-class bit now arrives about 1.3 ns earlier. Inside the whole front end, though, the loop is 2 levels and about 1.8 ns of routing longer than in OOC_FBUF alone. 79 % of its delay is routing, and `hb` has a fan-out of 150. On its own, cutting at `out_rare` costs only 0.46 ns compared with no cut.
- **Size:** +60 LUTs, more than my estimate of 20–40.
- **Budget:** I added a row to UARCH 4.4. The overshoot is now 4.1k / 5.5k / 6.7k (it was 4.0k / 5.4k / 6.6k).
- **Three paths at the edge:** all three are about 80 % routing, so placement decides which one is worst. The whole core is about 3.5 times as large, so routing will get longer there.

**Proposal (Plan/OOC 26.14)**
- **A. Register the TAGE update.** The popped block's metadata and outcomes go into a register, and TAGE updates from it one cycle later.
  - Cost: about 280 FFs.
  - Effect on prediction: in the model, one more block of update delay (6 → 7) added +194 / +36 mispredicted branches. A cycle is only about half a block, so the cost should be about 0.1 % of CoreMark or less.
- **B. Register the uBTB training.** This was already named as a fallback in 14.6.
  - Cost: about 50 FFs.
  - Effect: a block fetched in the cycle right after a training may miss that new entry once.
- **C. Duplicate `hb` (fan-out 150).** I would leave this until G1, and do it only if the loop is the worst path there.

I recommend A and B now. Both cost only flip-flops and barely change prediction, and together they take two of the three paths off the edge. B1 can check both. On its own the loop has +3.1 ns, so only the whole core will show whether it needs C.

Everything is recorded in Plan/OOC 26.13–26.14, UARCH 4.4 and PROMPT.md, in both languages.
<!-- /answer -->

## 98. 2026-10-30 21:25:42 JST

```text
Implement Plan/OOC 26.14 A and B: register the TAGE update and the uBTB training, with the unit tests, B1, the bug injection and the scripts.
```

<!-- answer -->
**Claude Code's answer**

I put Plan/OOC 26.14 A and B in, checked them with the tests and the bug injection, and pushed them (a6c7639). Both the TAGE update and the uBTB training now go through a register and arrive a cycle later. Not yet measured in Vivado.

**RTL**
- **A (OOO_FRONT):** the popped block's update goes into a register of 277 FFs: valid, the 270 bits of metadata read from the FTQ's head, the slots that ran and their outcomes. TAGE is updated from it a cycle after the pop. OOO_FETCH and OOO_TAGE are unchanged.
- **B (OOO_FETCH):** F2's training of the uBTB goes into a register of 80 FFs and reaches the uBTB a cycle after the override. The writes stay one a cycle and in order, so "no two entries with the same tag and parcel" holds.
- Lint (-Wall): only the expected PINCONNECTEMPTY.

**Tests**
- **tb_fetch:** the uBTB mirror now trains a cycle late; every F0 address is checked against it. 4 seeds PASS.
- **B1:** checks every cycle, all 270 bits, that the update TAGE receives is the pop's of the cycle before.
- **Overall:** all 28 unit tests and B1's 5 runs PASS.

**Effect on prediction (B1, both CoreMark builds)**

| | Before | Now |
|---|---|---|
| Mispredicted (D2 at random) | 6,561 / 5,862 | 6,796 / 6,114 |
| Mispredicted (`-full`) | 6,511 / 5,868 | 6,619 / 5,907 |
| Instructions a cycle (`-full`) | 1.824 / 1.826 | 1.824 / 1.828 |

- About 0.1k to 0.25k more mispredictions, as the model predicted; at 10 cycles each, 0.1 to 0.2 % of CoreMark's cycles.

**Bug injection**
- **Unit:** M343 to M345 added (the uBTB never trained, trained at the next cycle's address, trained in the override's cycle with the last training's fields). With the fetch and uBTB mutations, 29/29 detected; the unit campaign now has 309.
- **Front end:** 3 added (TAGE never updated, the slots run taken from the outcomes, updated with the previous pop's metadata). 43/43 detected.

Recorded in Plan/OOC 26.15, the READMEs and PROMPT.md, in both languages.

**Vivado request:** please run `synth_ooo.bat OOC_FE` and the fetch side alone, `synth_ooo.bat OOC_FRONT`. I expect several ns of margin on both the TAGE update and the uBTB training, with the fetch buffer's loop (about +1 ns) as the worst path. Size: about 360 FFs and a few LUTs more.
<!-- /answer -->

## 99. 2026-10-30 22:32:50 JST

```text
I ran synth_ooo.bat OOC_FE and synth_ooo.bat OOC_FRONT. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

The TAGE update and the uBTB training are both off the list of worst paths. OOC_FE's margin is +1.095 ns. Only the fetch buffer's loop is still under 2 ns. The result is recorded and pushed (54f14a2).

**Results**

| Run | LUT | FF | Slack | Levels |
|---|---|---|---|---|
| OOC_FRONT (before) | 2,611 | 2,112 | +0.835 ns | 16 |
| **OOC_FRONT (training registered)** | **2,570** | 2,119 | **+2.235 ns** | 15 |
| OOC_FE (before) | 6,231 | 3,015 | +0.868 ns | 18 |
| **OOC_FE (both registered)** | **6,184** | 3,288 | **+1.095 ns** | 17 |

| OOC_FE's paths | Before | Now |
|---|---|---|
| Fetch buffer loop | +1.016 ns | **+1.095 ns** (all 7 of the worst) |
| D1a / D1b | +5.3 / +5.5 ns | +5.9 / +5.1 ns |
| TAGE update | +0.868 ns | not among the worst 10 |
| uBTB training | +0.943 ns | not among the worst 10 |
| Next: fetch's pc → the RAS's write enable | — | +2.683 ns |

- **TAGE update and uBTB training:** both gained margin as expected. In fetch alone (OOC_FRONT) the uBTB training also left the worst path, +0.835 to +2.235 ns.
- **Size:** OOC_FE lost 47 LUTs. The TAGE update logic no longer has to be squeezed into the cycle of the FTQ read, so it is built smaller. FFs +273.
- **Budget:** UARCH 4.4 recounted with 6,184; the gap is 4.0k / 5.4k / 6.6k (was 4.1k / 5.5k / 6.7k).
- **The loop:** the front end stops here until G1. The remaining lever is duplicating `hb` (26.14 C), but whether it is needed cannot be decided before seeing the routing in the whole core.

Recorded in Plan/OOC 26.16, UARCH 4.4 and PROMPT.md, in both languages.

With the front end at a break, the next step by the plan is B2 (the core with ALU µops only, in lock-step). D-17 (the TAGE history lag), still open, could also be decided first.
<!-- /answer -->

## 100. 2026-10-30 22:35:48 JST

```text
Go on with B2: the core with ALU µops only (port 0 / 1), no memory, fusion off, lock-step at every commit.
```

<!-- answer -->
**Claude Code's answer**

B2 is running: the core with ALU µops only (ports 0 and 1, fusion off, no memory) executes random programs in lock-step with Spike at every instruction. It is pushed as 0bffdf2.

**What I built**
- **OOO_CORE (new):** the B2 core with:
  - the front end and D2 (fusion off, renaming, the control's go);
  - the DS register, the ROB, the issue queue and its payload, the register file;
  - two ALU ports (RR, EX, WB, bypass from the write-back registers);
  - branch resolution, commit, and a commit trace for simulation.
- **Front end:** OOO_FRONT now has a pc array and a second read of the target array (one read per ALU port). B1's bench checks them too.
- **Bench:** tb_core, plus a generator for test programs. B2's programs have no memory, so they end at the symbol `pass` instead of the HTIF exit.

**Two issues that came up while connecting the blocks**
- **Combinational loop between renaming and the control.** Renaming's `ready` depended on its `in_valid`, which is the control's `r_go`, which waits for `ready`. The unit tests drove each block alone, so this never showed. I fixed renaming to count the µops offered instead (the same for µop 1's checkpoint id). tb_rename now offers µops the way the control does, and I added mutation M346 for it.
- **D2 has to rotate the group (B2-1, not in the plan).** The group register leaves the remaining instructions in their slots after a partial take, but OOO_FUSE expects the group to start at slot 0. I rotated it to the oldest valid slot just before OOO_FUSE. I estimate this costs about 0.3k–0.5k LUTs, which is not in the budget. B7 will measure it.

**Results**

| Check | Result |
|---|---|
| 20 random ALU programs + 20 with branches, loops, calls and jumps; 2 seeds, plus a run with no I$ misses | **All pass in lock-step** |
| ALU programs | IPC 1.58–1.63 |
| Branch programs | 6k–16k instructions, 136–552 mispredictions each, IPC 0.70–0.98 |
| Core glue bug injection | **35 of 35 detected** |
| Unit tests (28), B1, front-end bug injection (43/43), renaming mutations (11/11) | All pass |

- The first bug-injection run left 12 of 40.
  - **7 are caught now:** by a new bench check of each resolved branch and jalr against its instruction (call/return, the last parcel, taken; lock-step cannot see these, since they only steer the predictors), and by programs that now include c.jalr, jalr with an offset, a call through the other link register, and bursts of branches that use up the checkpoints.
  - **5 I left out as equivalent at today's design**, with the reasons recorded in `mutate_core.py`. For example, a killed µop acts at most 2 cycles after a restore, while the restarted fetch reaches renaming no sooner than 6 cycles after it.

Everything is recorded in Plan/CORE 5.4, the READMEs, UARCH and PROMPT.md, in both languages.

One thing for Vivado: the OOC_FE harness now includes the new pc-array ports. If you want to measure them, rerun `synth_ooo.bat OOC_FE`; it is not urgent.
<!-- /answer -->

## 101. 2026-10-31 00:05:56 JST

```text
I ran the OOC_FE by Vivado.
Go on with B3: loads and stores, the LSU with a D$ model first, then OOO_DCAD and the real D$, in lock-step.
```

<!-- answer -->
**Claude Code's answer**

B3 is done: loads and stores run in lock-step with Spike, first against a D$ model and then on OOO_DCAD with the real D$. Everything is pushed as 4e05b40. Your OOC_FE rerun is recorded too (pushed as 01bbaff): +70 LUTs for the pc array and the second target-array read, +1.703 ns, and no path under +1.7 ns.

**RTL**
- **OOO_CORE:** I added port 2 (the load/store port) and OOO_LSU. Port 2 has the same RR and EX stages as the ALU ports, because the LSU's address stage is the core's EX. The bypass now takes from three write-back registers: the two ALU ports and the LSU.
- **OOO_LSU:** it now also outputs its M result, so the register file is written at the edge the load enters WB (decision 4.2). Writing from the WB register a cycle later would let a dependent read the old value.
- **OOO_CPU (new):** OOO_CORE plus OOO_DCAD and mmRISC-2's D$, on an AXI4 memory bus and an AXI4-Lite peripheral bus. OOO_CORE keeps an abstract D$ port, the same way it keeps the I$ port.
- **DCACHE:** for simulation only (`DCACHE_SIM_UC`), it can leave one line uncached. The bench uses this for tohost, so HTIF sees writes in memory (rule 2 of 5.1).

**Tests**
- **Random load/store programs (20):** every access size into a 24 KB buffer. They cover store→load forwarding, stores that only partly cover a load, values passed through memory, bursts that fill the store queue, and conflicts that make the D$ evict and write lines back.
- **riscv-tests (95):** all of rv64ui except `ma_data` and `fence_i` (the load/store and forwarding tests included), plus rv64uc and the Zb*/Zicond tests. They need CSRs normally, so I built them on a minimal environment without CSRs. Plus a console test that prints through tohost.

| Run | Result |
|---|---|
| OOO_CORE + D$ model: 60 random programs and 96 tests, several seeds and hit rates (0–100 %) | **All pass** |
| OOO_CPU + real D$: the same 60 + 96 | **All pass** (about 230 line fills and 17 write-backs per program) |
| Replay after a load miss (D-12) | 30–106 replays per program, all correct |
| Core glue bug injection | **54 of 54 detected**: 20 new port-2 mutations; the one survivor was redundant logic, which I removed |
| Unit tests | All 28 pass; unit mutations now 312 |

**One redundant piece removed:** I had made a late load's result wake the issue queue again. The bug injection showed this does nothing, because the queue already wakes a load's dependents 2 cycles after issue, and anything that ran on that guess is replayed after commit.

**A performance problem found (results stay correct)**
- The LSU only writes a committed store to the D$ in a cycle when no load is in its address stage.
- The console test's polling loop issues a load nearly every cycle. With the real D$, printing 25 characters took 301,300 cycles, against 1,509 with the D$ model.
- The same thing holds back stores behind any load-heavy loop until the store queue fills.
- **Proposed fix:** let a store drain when the load in the address stage is to a different 8-byte word; once a committed store has waited a few cycles, drain it anyway and send that load to wait in the load queue for a retry.

Everything is recorded in Plan/CORE 5.5, the READMEs, UARCH and PROMPT.md, in both languages.
<!-- /answer -->

## 102. 2026-10-31 01:14:51 JST

```text
Fix the store drain in OOO_LSU as proposed in Plan/CORE 5.5 (drain when the load in E is to another word; after some cycles drain anyway and send the load to wait), with tests and the bug injection.
```

<!-- answer -->
**Claude Code's answer**

OOO_LSU's store drain is fixed. Once loads in E have held a committed store off for 8 cycles, the store takes the D$ port. Pushed as dc18aab.

**Why I built only the second half of the proposal**
- The D$ takes one request per cycle. OOO_DCAD sends the load in E first and never takes a store while a load is in E or waiting.
- Draining past a load to a different word would need two requests in the same cycle, which can't happen with the real D$. So I didn't add it.

**What I changed (OOO_LSU, `DRAIN_WAIT` = 8)**
- A counter tracks how many cycles a load in E has held the oldest committed store off.
- When it reaches 8, the store gets the D$ port. The load in E sends no request and waits in the load queue, the same way a load waits when an older store has no address yet. It is retried after the store has left.
- **First version, too costly:** it counted every cycle the store waited, including cycles where the D$ was simply busy. Each forced drain costs a replay of the load's dependents (`ld_cancel`), so the 20 load/store programs got 0.3–4 % slower. Counting only the cycles a load actually blocks the store removes that cost:

| OOO_CPU cycles | Before | Wait 4 | **Wait 8** | Wait 16 |
|---|---|---|---|---|
| Console (25 characters) | 301,300 | 2,005 | **2,240** | 2,611 |
| `ld_st` / `st_ld` | 4,594 / 1,788 | unchanged | **unchanged** | unchanged |
| The 20 load/store programs | 159,485 | 159,986 | **159,366** | 159,490 |

**Tests**
- **tb_lsu and tb_dcad** now include bursts of loads, and tb_lsu also includes polling windows (only loads to the last store's word, with no store after it). tb_lsu checks:
  - a load request and a store never go to the D$ in the same cycle;
  - loads never hold a committed store off longer than 8 cycles;
  - a load never gives up the port to a store that hasn't waited that long.
  
  Every load value is still checked. Each passes on 4 seeds.
- **Bug injection:** I updated the old drain mutation (M46) and added M349–M355; all 8 are detected. Unit mutations now total 319.
  - One of them only shows up in the polling windows. If a retried load gives up the port in the same cycle its store drains, and no store follows, nothing retries it again. With that mutation, the console test hangs on OOO_CPU.
- **Everything else still passes:** 28 unit tests, all 47 LSU/D$-adapter mutations, B2/B3 on both tops (7 runs), and the core glue mutations (54/54).

Recorded in Plan/CORE 5.6, the READMEs and PROMPT.md, in both languages.

Since OOO_LSU changed, its size and timing may have moved a little. A Vivado run of `OOC_LSU` and `OOC_LSUDC` would measure that.
<!-- /answer -->

## 103. 2026-10-31 13:00:46 JST

```text
Go on with B4
```

<!-- answer -->
**Claude Code's answer**

B4 is done and pushed to dev as 8a57aef. On both tops (OOO_CORE and OOO_CPU), every test passes in lock-step, with each instruction checked against Spike. The changes to OOO_CORE, OOO_CSRU and CORE_CSR have not been through Vivado yet.

**Results (all 12 runs of run_core.sh pass)**

| Run | Result |
|---|---|
| riscv-arch-test, 185 tests (I, M, Zca, Zba, Zbb, Zbc, Zbs, Zicond, Zicsr, Zifencei, Zicntr, Sm, Exceptions) plus 1 directed test | all pass on both tops (OOO_CORE on 2 seeds) |
| riscv-tests -p-, 127 programs | all pass on both tops |
| B2 and B3 regression | all pass |

Three of the 130 -p- programs are left out because Phase 1 cannot run them: breakpoint (the triggers' firing is not wired), csr (it uses an FP instruction) and si-dirty (it needs paging). ma_fetch failed before; it now passes thanks to the reference-side misa adjustment below.

**Six bugs found and fixed**
1. **A load to x0:** its result kept tag 0 and went onto the write-back bypass, so instructions reading x0 received the loaded value. This made 19 of the 51 arch-test I tests fail.
2. **A multiply to x0:** OOO_PMUL's result took port 0's write slot, and the ALU result of the same cycle was lost. It was also forwarded with tag 0, and so was a divide's. It showed only in M-mul / M-mulw on OOO_CPU.
3. **mcountinhibit:** it was written in EX, so the writing instruction itself was counted under the new IR setting. The write now waits for the commit, so the instruction counts under the old setting, as in Spike and Sail.
4. **mconfigptr:** required by privileged spec 1.12, but missing from CORE_CSR (inherited from mmRISC-2). Added as read-only 0.
5. **FP loads and stores** were not illegal (only FP arithmetic was).
6. **fcsr and the other FP CSRs with FS off** were not illegal. mmRISC-2 checked this in CPU_CORE, so the check moved to OOO_CSRU.

Bugs 5 and 6 were found by `b4/dir/illegal.S`, a directed test I wrote to reach mutations that had survived.

**How arch-test runs here**
- The recommended Sail, UDB and binutils 2.44 are not on this machine. Each test is built like the framework's signature ELF, and lock-step does the checking instead of expected values. The signature is stores, so the check is the same.
- The DUT configuration (`b4/act`) is written by hand. The Sm and Exceptions tests are not in the checkout, so they are generated with the framework's testgen.
- With binutils 2.43 the alignment padding at the tests' entry came out as zeros; `-mno-relax` avoids it.

**Adjustments on the reference side (LOCKSTEP)**
For some CSR WARL fields, CORE_CSR and Spike make different choices that are both legal. There, LOCKSTEP now puts Spike where CORE_CSR is:
- misa is treated as read-only (Spike lets it be written);
- mcountinhibit, which Spike lacks, is kept by LOCKSTEP, and while IR is set the minstret increment is cancelled;
- medeleg's bit 18 is not kept;
- a reserved mode written to mtvec / stvec becomes direct;
- reads of the HPM events take the DUT's value.

The stand-in test (Spike against Spike) turns these adjustments off.

**Bug injection**
- `mutate_core.py` detects 84 of 84. The first campaign left 6 undetected; the directed test and the gen_b2 extensions (multiplies after divides, loads and multiplies into x0) caught 5 of them.
- The last one (cutting an illegal RVC instruction's tval to 16 bits) was equivalent, because FBUF already passes the upper half as 0. The redundant mask is gone from the RTL.
- 3 unit mutations added (M356–M358), 322 in all.
- The 28 unit tests, B1 and the LOCKSTEP self-test pass, and the `-Wall` lint shows no new warning.

The author's Vivado results for OOC_LSU / OOC_LSUDC are also recorded in Plan/CORE 5.6 and included in the same commit. The store-drain fix costs 5 LUTs in the LSU, and OOC_LSU's WNS went from 6.875 to 6.548 ns.

Everything is recorded in Plan/CORE 5.7, the READMEs, UARCH and PROMPT.md, in both languages.
<!-- /answer -->

## 104. 2026-10-31 20:18:30 JST

```text
Please suggest the next steps.
```

<!-- answer -->
**Claude Code's answer**

G1 measures four things: correctness, performance (CoreMark within ±5 % of the model), size, and 50 MHz. Judging the remaining B5–B7 against those, I propose this order.

**1. Run CoreMark on the core as it is (part of B6 brought forward, fusion off) [recommended]**
- **Why:** arch-test is a set of short tests. Running a real program of millions of instructions in lock-step catches bugs that only long runs show (the ROB wrapping, the FTQ or free list running dry, races with D$ evictions).
- **What:** run the three builds of Plan/trace on OOO_CORE (D$ model) and OOO_CPU (real D$), take the cycles without fusion, and compare with the model run without fusion. Before fusion goes in, this shows where the front end, the IQ and the LSU differ from the model.
- **Size:** small, since the bench is used as it is.

**2. B5a: fusion, kind by kind**
- **Why:** the model's targets (6.243 and so on) include fusion, so it is needed before B6's ±5 % judgement.
- **What:** add one kind of fusion at a time, rerun the whole B4 set (arch-test, -p-) in lock-step each time, and add bug injection.
- **Interrupts:** the timer interrupt planned for B5 is not needed by CoreMark, so I propose moving it later (B5b).

**3. A real I$ for B6**
OOO_CPU's I$ is still the bench's model. G1 is judged with the real caches, so mmRISC-2's I$ and FENCE.I's invalidate path need to be connected.

**4. Vivado (on the author's machine, in parallel)**
- **OOC_CSRU:** the block with the least slack (+0.569 ns); the FS check and the mcountinhibit delay were just added, so I'd measure it first.
- **B7 brought forward (OOC_CORE, the whole core):** the size is already over budget (4.1k / 5.5k / 6.7k). The sooner the whole core's LUTs and timing are known, the more choices remain. I'll prepare the wrapper and the tcl.

**A separate decision: the A extension (AMO / LR / SC)**
misa has A set, but it was outside B4: arch-test's Zaamo and Zalrsc have not been run, and how far AMOs work in OOO_LSU has not been checked. Since the instruction set is kept, a step to verify it should go in somewhere before B5 or B6.

This prompt (104) and the English of the previous answer are in PROMPT.md, not committed yet.
<!-- /answer -->

## 105. 2026-10-31 20:23:17 JST

```text
Start with CoreMark
```

<!-- answer -->
**Claude Code's answer**

The three CoreMark builds (g14 -O2, g14 sf + -flto, g13 -O2 Zb) now run to the end in lock-step on both tops, pushed to dev as fa2e3d6. They also pass with I$ / D$ misses at random on 2 seeds. Performance, though, is about 26 % behind the model without fusion; the main cause and the fix are in sight.

**Found and fixed**
- **An RTL bug:** port 0's WB register used, for a result of the multiplier or divider (MDU), the branch mask of "whatever other µop was in EX then". A kill of that µop alone dropped the multiply's bypass for a cycle, and a dependent instruction read the old value. Found at the 56,598th instruction of g14-sflto; B2–B4 never made the case. OOO_CORE is fixed, and the mutation campaign now ends with a CoreMark stage (85 of 85 detected).
- **On the bench (2):**
  - The PRF has no reset, so it is set to 0 after reset, as Spike's registers. CoreMark's start-up saves registers it has not written yet.
  - The D$ model kept, instead of dropping, the fill of a miss killed in the very cycle it was in M. The order is fixed.

**Performance (whole-run cycles, as the model counts them)**

| | g14 -O2 | g14 sf+flto | g13 -O2 |
|---|---|---|---|
| Model (fusion off) | 1,689,007 (5.92) | 1,551,318 (6.45) | 1,718,813 (5.82) |
| OOO_CORE (the model's ideal caches) | 2,284,618 (4.38) | 2,100,584 (4.76) | 2,290,569 (4.37) |
| OOO_CPU (the real D$) | 2,307,398 (4.33) | 2,149,465 (4.65) | 2,304,948 (4.34) |

The numbers in parentheses are CoreMark/MHz.

**Where the difference goes (g14 -O2, on a build with counters)**
- **The biggest cause is replayed loads:** 25,861 loads issued before an older store's address was known could not complete in M. That led to 20,618 replays after commit (a flush of the whole pipeline and a refetch).
  - The RTL's store is one µop issued together with its data, so its address is known late and the loads behind it go first.
  - The model assumes "a load waits until the older stores' addresses are known" and has no such cost.
  - With a new `st_data_issue` option in the model ("a store issues with its data, loads wait for it"), the loss is only 0.7 % without fusion and 1.9 % with fusion.
  - **Proposal:** add to the IQ the condition "no load issues while an older store is still in the IQ". It depends on registered state only, so like the non-speculative condition it can sit outside the wakeup-select loop.
- **Branch prediction is also worse:** conditional branches mispredicted on the true path are 1.7 times the model's. jalr (returns and indirect jumps) is 1,593 in sflto against the model's 8, an order of magnitude off. I suspect the RAS after a replay or a flush, or the repair of the branch history after a replay.
- **The pipeline depth is not the cause:** one or two more decode stages in the model cost only 0.3–0.5 %.

Recorded in Plan/CORE 5.8, MODEL, the READMEs and UARCH in both languages. This prompt (105) and the English of the previous answer are in PROMPT.md, included in this commit.
<!-- /answer -->

## 106. 2026-10-31 21:42:24 JST

```text
Yes, implement it
```

<!-- answer -->
**Claude Code's answer**

The IQ no longer issues a load while an older store is still in the queue. Pushed to dev as 1ce7f1b. CoreMark is 16–18 % faster, and the gap to the model went from 26 % to 10–13 %. OOO_IQ has not been through Vivado yet.

**Changes**
- **OOO_IQ:** a `disp_st` port and a store bit per entry. A load is ready only when "no older valid store is in the queue". The condition depends on registered state only and sits beside the non-speculative condition, so it is not in the wakeup-select loop.
- **Timing:** a store's address is known in E. A load issued after it reaches M a cycle later at the earliest, when the LSU already has the address.
- **OOO_CORE:** only connects DS's "is it a store" to the IQ.

**CoreMark (cycles; CoreMark/MHz in parentheses)**

| | g14 -O2 | g14 sf+flto | g13 -O2 |
|---|---|---|---|
| Model (fusion off, stores issued with their data) | 1,701,808 (5.88) | 1,562,105 (6.40) | 1,730,925 (5.78) |
| Before (OOO_CORE, ideal caches) | 2,284,618 (4.38) | 2,100,584 (4.76) | 2,290,569 (4.37) |
| **Now (OOO_CORE, ideal caches)** | **1,913,926 (5.23)** | **1,718,063 (5.82)** | **1,956,056 (5.11)** |
| Now (OOO_CPU, real D$) | 1,933,121 (5.17) | 1,764,874 (5.67) | 1,967,483 (5.08) |

- Replays went from 20,618 to 96, and loads held by an unknown store address from 25,861 to 0.
- Mispredicted jalr went from 218 to 62 (sf+flto: 1,593 to 76). The RAS disturbance I suspected last time was caused by the replays' flushes.

**Candidates for the remaining 10–13 %**
- Conditional branches mispredicted on the true path are still about 1.75 times the model's (g14 -O2: 7,706 against 4,393).
- Dispatch stops for a full ROB in 166k cycles. The model has the same 24 entries but its ROB is hardly ever full.

**Tests**
- tb_iq now has stores and checks that "a load issues only when no older store is in the queue".
- 3 unit mutations added (M359–M361), and M230, whose line changed, is fixed. The IQ mutations: 23 of 23 detected; 325 in all.
- A mutation that cuts `disp_st` into the IQ leaves values correct and only adds cycles, so lock-step cannot see it. tb_core got a replay limit, `-replays-max`, used in the mutation campaign's CoreMark stage. The core's mutations: 86 of 86 detected.
- run_core.sh (12 runs), run_coremark.sh (4 setups), the 28 unit tests and the stand-in test all pass, and the lint shows no new warning.

OOO_IQ only gains a flip-flop and a 10-bit AND-OR per entry, but `synth_ooo.bat OOO_IQ` would measure its size and timing.

Recorded in Plan/CORE 5.9 (5.8's proposal marked done in 5.9), the READMEs and UARCH in both languages. This prompt (106) and the English of the previous answer are in PROMPT.md, included in this commit.
<!-- /answer -->

## 107. 2026-10-31 22:35:51 JST

```text
Branch mispredicts
```

<!-- answer -->
**Claude Code's answer**

The core's poor branch prediction is the "TAGE history lag" found in Plan/CORE 5.3: every fetch stall changes the lag, and the same branch reads a different row. No other cause appears. The result is recorded in Plan/CORE 5.10 and pushed as a545127. The fix, D-17, is still open and not implemented.

**What I measured**
On a build with counters I counted, branch by branch, the mispredictions that commit (true path), next to the model running OOO_TAGE's own algorithm (g14 -O2).

| Branch | RTL | Model (lag always 2) | Model (lag changing with fetch stalls) |
|---|---|---|---|
| 0x80000f18 `bnez` (core_bench_list's one-block loop) | **1,280** | almost 0 | 1,687 |
| 0x80000f8c `bnez` (core_bench_list) | **796** | almost 0 | 718 |
| 0x80000de8 `bge` (mergesort) | 564 | 327 | 544 |
| 0x80000e2e `blez` (mergesort) | 977 | 952 | 1,037 |
| 0x80001492 / 0x80001508 `beq` (matrix) | 364 / 361 | 361 / 361 | 401 / 388 |
| Total | 7,706 | 5,279 | 9,643 |

- **Branches that are hard by nature** (e2e, the matrix beqs) miss about as often in the RTL as in the model.
- **The excess sits in particular branches**, those a changing lag breaks (f18, f8c, part of de8): the same symptom as B1 in 5.3.
- **Why it is not another cause:**
  - jalr mispredictions are down to 62.
  - A misprediction costs about the same as in the model: 88,499 cycles with the front end empty for 8,439 restores is 10.5 cycles each; the model's is 10.2.

**The fix would be D-17 (Open in UARCH's decision table)**
- **What:** TAGE always reads with the history "lagging 2 blocks".
- **Cost:** about 0.15k LUTs: a 7:1 shift of the history before the fold, and 2 more bits in each FTQ entry.
- **Expected effect:**
  - Mispredictions go from 7,706 to about 5,279, about 2.4k fewer.
  - At 10.2 cycles each, about 25k cycles fewer: about +1.3 % CoreMark (g14 -O2).
  - The difference left, 5,279 against 4,393, comes from OOO_TAGE keeping its rows per block (5.3, point 5).

**Where it stands among the rest**
Of the remaining 10–13 % to the model, branch prediction is about 1.3 %, the smaller part. The larger part is dispatch stopping for a full ROB: 166,098 of 1,913,926 cycles. Whether or not D-17 goes in, that is worth looking at next.

This prompt (107) and the English of the previous answer are in PROMPT.md, included in this commit.
<!-- /answer -->

## 108. 2026-10-31 22:46:32 JST

```text
Yes, accept D-17
```

<!-- answer -->
**Claude Code's answer**

D-17 is in: TAGE always reads with a history "lagging 2 blocks", so the same branch reads the same row even when fetch stalls. Pushed to dev as 65cef7f. CoreMark is 0.6–1.7 % faster, and the gap to the model is 9–12 %. The new shift sits on the path from F0 to the tables' addresses, so its timing, not measured yet, can be checked with `synth_ooo.bat OOC_FE`.

**Implementation**
- **OOO_TAGE:**
  - Keeps c1 / c2, the bit counts of the last 2 blocks pushed.
  - When F0 reads, the history is shifted by the bits of those of the 2 blocks before that are already in it: 0 if both are still in flight, c1 if one is, c1+c2 if neither.
  - The history register is 76 bits: 70 plus the 6 a shift uses.
  - The metadata gets the "bit count of the block before" (cprev, 2 bits): the metadata is 272 bits, the FTQ's entries 314. A restore puts it back as c2.
- **OOO_FETCH:** gives TAGE the number of live requests in flight (`f0_live`); requests dropped by an override or a redirect do not count.
- **OOO_FRONT / FERS:** the history field a restore reads is 72 bits, with cprev.

**Results**

| | g14 -O2 | g14 sf+flto | g13 -O2 |
|---|---|---|---|
| B1 mispredictions (full speed) | 6,619 → **5,614** | 5,907 → **4,765** | |
| The core's restores | 8,439 → **5,453** | 6,080 → **5,426** | 6,883 → **6,064** |
| OOO_CORE (ideal caches) | 1,913,926 → **1,882,020 (5.31)** | 1,718,063 → **1,706,123 (5.86)** | 1,956,056 → **1,945,090 (5.14)** |
| OOO_CPU (real D$) | 1,933,121 → **1,907,780 (5.24)** | 1,764,874 → **1,755,555 (5.70)** | 1,967,483 → **1,958,830 (5.11)** |
| Model (fusion off) | 1,701,808 (5.88) | 1,562,105 (6.40) | 1,730,925 (5.78) |

B1's mispredictions are now about the model's (OOO_TAGE's algorithm, constant lag): 5,279 / 4,526. The numbers in parentheses in the cycle rows are CoreMark/MHz.

**Tests**
- The unit tests' mirror (tage_ref.h) has the lag and c1 / c2 / cprev.
  - tb_tage gives `f0_live`.
  - tb_fetch mirrors FETCH's live requests and compares all of each block's metadata.
  - tb_front compares the 72-bit history field.
- **Mutations:**
  - 5 for D-17 added on the unit side (M362–M366).
  - M105 and M112 had lost their TAGE lines and are fixed. M297 had been lost since the FS check went into CSRU last time; found and fixed now.
  - Unit 330 of 330, front 44 of 44 (one added: cprev lost at a restore), core 86 of 86 detected.
- run_core.sh (12 runs), run_coremark.sh, B1, the 28 unit tests and the stand-in test all pass. The OOC wrappers (OOC_FRONT, OOC_FE) follow the new widths, and the lint shows no new warning.

**The difference left**
9–12 % to the model, most of it dispatch stopping for a full ROB (about 166k cycles in g14 -O2 with ideal caches).

UARCH's D-17 is marked "decided 2026-10-31"; recorded in Plan/CORE 5.11 and the READMEs in both languages. This prompt (108) and the English of the previous answer are in PROMPT.md, included in this commit.
<!-- /answer -->

## 109. 2026-11-01 00:30:32 JST

```text
Yes, ROB-full stalls
```

<!-- answer -->
**Claude Code's answer**

A correction first. The "ROB full, dispatch stopped for 166k cycles" I reported before was my counter's mistake. `rob_avail`, `iq_ready`, `lq_avail` and `sq_avail` are 2-bit free counts (0–2), and I read only their bit 0. Counted again correctly, the ROB has no free entry in only 304 cycles, and its average occupancy is 13.6 of 24. Correction notes are in Plan/CORE 5.9–5.11, and what I found is recorded as 5.12, pushed as 0f5ef0a. No RTL changed.

**The correct breakdown (g14 -O2, ideal caches)**
- Dispatch stops in 169k cycles, nearly all for the IQ (no free entry 24k; a pair needing 2 with 1 free 78k) and the LQ (36k / 25k).
- The model stops about as much (IQ 93k, LQ/SQ 61k). So the back end is congested about as in the model.
- Dispatching slot 0 alone when one entry is free was tried in a copy: no effect (±0.1 %), not kept.

**Where the difference is (cycles between commits summed by pc, RTL against the model by function)**
- 180k cycles in all. The largest is matrix_mul_matrix_bitextract +60k, then core_bench_list +27k, core_state_transition +25k, core_bench_state +17k, mergesort +14k.
- 16k of it is start-up and printf, which the model's trace does not hold at all.
- bitextract's inner loop takes 10 cycles an iteration in the RTL, 7.6 in the model.
  - 6 of its 13 instructions (2 each of mulw, sh1add.uw, sraiw) can go to port 0 only.
  - The multiply's result uses port 0's write port, so the IQ does not give port 0 a latency-1 µop in the cycle after a multiply.
  - EX0 is therefore idle 4 cycles in 10, the next iteration's address computation waits, and the IQ fills.

**RTL differences the model did not have (options added to the model)**

| | g14 -O2 | sf+flto | g13 |
|---|---|---|---|
| The multiply's write slot on port 0 (the RTL now) | +1.7 % | +2.6 % | +2.2 % |
| The same slot moved to port 1 | +0.7 % | +0.8 % | +1.4 % |
| Loads / stores commit a cycle later (the RTL now) | +1.4 % | +1.5 % | +1.4 % |

With these 3 (the decode depth included) the model is still 5–8 % faster than the RTL, and in bitextract 0.8 cycle an iteration is left at the second multiply.

**Fixes**
- **A:** the multiply's result is written through port 1's write port, and the slot blocked in the cycle after a multiply moves from port 0 to port 1. ALU1 does only simple operations and ALU0 everything, so blocking ALU1 costs less. About 1–1.8 %, adding about a 2:1 select on port 1's write and bypass.
- **B:** a load's completion comes straight from M, not from the register after M. About 1.4 %, but LSU's M-stage timing may be an issue.

Also, the model's tageref mode had stopped building with D-17's change to tage_ref.h; fixed. This prompt (109) and the English of the previous answer are in PROMPT.md, included in this commit.
<!-- /answer -->

## 110. 2026-11-01 00:57:01 JST

```text
Yes, do A
```

<!-- answer -->
**Claude Code's answer**

Fix A is in: the multiply's result is written through port 1's write port, and the slot kept free in the cycle after a multiply moved to port 1 as well. Pushed to dev as 084525b. CoreMark is 0.5–2.6 % faster, 7.7–9.4 % behind the model. OOO_IQ has not been through Vivado yet.

**Changes**
- **OOO_CORE:** the multiply's result goes into port 1's WB register (the PRF's write port 1 and port 1's bypass). Port 0 keeps only the divider's (MDU) results.
- **OOO_IQ:** in the cycle after a multiply, no µop that writes a register gets port 1; it can still go to port 0.

**A bug found on the way**
- **Symptom:** the MDU and the multiplier still share the ROB's completion port. With the MDU no longer waiting for the multiply's result, both completed in the same cycle and the MDU's completion was lost.
- **Found by:** 10 of the 20 gen_b2 ls programs hung where a `mulw` follows a `mulhu`. arch-test and CoreMark did not show it.
- **Fix:** the MDU again waits for a cycle without the multiply's result. The write ports stay separate.

**CoreMark (cycles; CoreMark/MHz in parentheses)**

| | g14 -O2 | g14 sf+flto | g13 -O2 |
|---|---|---|---|
| OOO_CORE (ideal caches) | 1,882,020 → **1,833,565 (5.45)** | 1,706,123 → **1,698,184 (5.89)** | 1,945,090 → **1,894,227 (5.28)** |
| OOO_CPU (real D$) | 1,907,780 → **1,859,255 (5.38)** | 1,755,555 → **1,746,040 (5.73)** | 1,958,830 → **1,907,485 (5.24)** |
| Model (fusion off) | 1,701,808 (5.88) | 1,562,105 (6.40) | 1,730,925 (5.78) |

Against the model's expectation (−1.0 / −1.8 / −0.8 %), the gain came out larger for g14 -O2 and g13 and smaller for sf+flto.

**Tests**
- **tb_iq:** checks the new rule, and mixes in "ALU µops that write nothing (branches)" to confirm those still go to port 1 in the cycle after a multiply.
- **IQ mutations:** M314, which had lost its line, is fixed and M367–M369 added: 26 of 26 detected. 333 unit mutations in all.
- **Core mutations:** 87 of 87 detected.
  - The "WB mask" mutation added in 5.8 is no longer detected by any test. With the multiply's write on port 1, showing it needs a branch mispredicted on port 0 and the rest all in the same cycle.
  - It is not equivalent, so the RTL guard stays; the mutation is taken out of the campaign with the reason written down.
- run_core.sh (12 runs), run_coremark.sh, the 28 unit tests and the stand-in test all pass, and the lint shows no new warning.

**Next candidate**
Fix B (a load's completion from M) is worth about 1.4 % in the model. It lengthens LSU's M-stage path, so the timing needs checking.

Recorded in Plan/CORE 5.13, the READMEs and UARCH in both languages. This prompt (110) and the English of the previous answer are in PROMPT.md, included in this commit.
<!-- /answer -->

## 111. 2026-11-01 09:49:54 JST

```text
Yes, do B
```

<!-- answer -->
**Claude Code's answer**

Fix B is in: a load's completion goes to the ROB in the same cycle as its register-file write (in M or with a fill), not from the register after M. Loads now commit a cycle earlier (stores already completed from E), and CoreMark is 1.1–1.2 % faster. Pushed to dev as 6b8d6d8. The path now running from M's search to the ROB's done bits has not been measured in Vivado yet.

**Changes**
- **OOO_LSU:** the 4 completion signals (valid, ROB index, exception, replay mark) are combinational. Their content is what the register used to take, a cycle sooner.
- **OOO_CORE:** the commit trace takes a load's value from the register-file write.

**CoreMark (cycles; CoreMark/MHz in parentheses)**

| | g14 -O2 | g14 sf+flto | g13 -O2 |
|---|---|---|---|
| OOO_CORE (ideal caches) | 1,833,565 → **1,813,160 (5.52)** | 1,698,184 → **1,678,934 (5.96)** | 1,894,227 → **1,871,639 (5.34)** |
| OOO_CPU (real D$) | 1,859,255 → **1,837,109 (5.44)** | 1,746,040 → **1,726,134 (5.79)** | 1,907,485 → **1,884,608 (5.31)** |
| Model (fusion off) | 1,701,808 (5.88) | 1,562,105 (6.40) | 1,730,925 (5.78) |

The gain is a little smaller than the model's expectation (about 1.4 %). The gap to the model is 6.5 / 7.5 / 8.1 %. Since CoreMark started (26 %) the gains add up from 5.9 (loads wait for older stores), 5.11 (D-17), 5.13 (the multiply on port 1) and now 5.14.

**Tests**
- **tb_lsu / tb_dcad:** the new completion signals delayed a cycle equal the old register outputs, so the usual "check against the result register" is used as it was. tb_lsu also checks that a completion comes in the same cycle as the register-file write (none for an exception). Both pass on 4 seeds.
- **Mutations:** 4 added on the unit side (M370–M373). LSU and D$-adapter mutations 50 of 50, core mutations 87 of 87 detected.
- run_core.sh (12 runs), run_coremark.sh, the 28 unit tests and the stand-in test all pass, and the lint shows no new warning.
- **A slip on the way:** while a regression was running I briefly reverted the working tree with `git stash` to compare lint warnings. It might have built with the old RTL, so I stopped that regression and ran it again from the start; the results above are from the rerun.

**What I'd like measured in Vivado**
The blocks changed so far that may matter for timing:
- `synth_ooo.bat OOC_LSU`, `synth_ooo.bat OOC_LSUDC`: a load's completion is now combinational. The path into the ROB can only be measured with the whole core (B7).
- `synth_ooo.bat OOO_IQ`: the wait for stores (5.9) and the moved write slot of the multiply (5.13).
- `synth_ooo.bat OOC_FE`: D-17's history shift sits on the path from F0 to the tables' addresses (5.11).
- `synth_ooo.bat OOC_CSRU`: the FS check and the mcountinhibit delay were added (5.7).

Recorded in Plan/CORE 5.14, the READMEs and UARCH in both languages. This prompt (111) and the English of the previous answer are in PROMPT.md, included in this commit.
<!-- /answer -->

## 112. 2026-11-01 10:40:30 JST

```text
I'll run Vivado
```

<!-- answer -->
**Claude Code's answer**

The 5 tops are ready to run in Vivado as they are. I linted them with the same file list as synth_ooo.tcl and pushed, as 79b1ddc, the one wrapper fix found on the way.

**What I fixed**
- OOC_LSUDC's wrapper had a 274-bit input bus whose top bit was not used (a WIDTHTRUNC warning since 2026-10-28). The fields are assigned from the bottom, so it did no harm, but the bus is now 273 bits and the warning is gone.
- No width or pin warning comes from the blocks changed this time. The PINMISSING warnings left (LSU's `rf_*` not connected to outputs, and the like) were there before.

**Commands to run (FPGA/OOO_OOC)**

```bash
synth_ooo.bat OOC_LSU
```
```bash
synth_ooo.bat OOC_LSUDC
```
```bash
synth_ooo.bat OOO_IQ
```
```bash
synth_ooo.bat OOC_FE
```
```bash
synth_ooo.bat OOC_CSRU
```

What each should show:

| Top | Change to look at | Last values |
|---|---|---|
| OOC_LSU / OOC_LSUDC | A load's completion is combinational in M (5.14) | LSU 1,947 LUTs, WNS 6.548 ns / LSUDC 7,681 LUTs, WNS 1.964 ns |
| OOO_IQ | The store-wait bit (5.9), the multiply's write slot moved to port 1 (5.13) | – |
| OOC_FE | D-17's history shift (the path from F0 to the tables' addresses, 5.11) | – |
| OOC_CSRU | The FS check, the mcountinhibit delay (5.7) | slack +0.569 ns (the smallest) |

OOC_LSU's wrapper takes `cmp_ld_*` into output registers, so the new completion path (M's search and the D$ hit → output) is measured as well. The path into the ROB shows only with the whole core (B7).

When the runs are done, ask me to check `output/*/summary.txt`, and I'll compare them with the last values.
<!-- /answer -->

## 113. 2026-11-01 11:14:17 JST

```text
I have finished the Vivado runs. Please check output/*/summary.txt.
```

## 114. 2026-11-01 11:14:42 JST

```text
I have finished the Vivado runs. Please check output/*/summary.txt.
```

<!-- answer -->
**Claude Code's answer**

All five runs meet 50 MHz (a 20 ns period). But two of the changes made for CoreMark cost more than expected: the IQ's timing got tight, and the CSR unit's LUTs grew. The analysis is in Plan/OOC 26.18 and UARCH's budget table, pushed as bfca0db.

| Top | LUTs | Slack (all / reg to reg) | Main change |
|---|---|---|---|
| OOC_LSU | 1,947 → 1,949 | +7.031 ns (last +6.548) | A load completes in M (5.14) |
| OOC_LSUDC | 7,681 → 7,573 | +1.340 ns (last +1.964) | Same (D$ placement −115) |
| OOO_IQ | 1,894 → 1,951 | **+0.360** / +5.884 ns (last +1.165 / +6.605) | Store wait (5.9), the multiply's slot on port 1 (5.13) |
| OOC_FE | 6,254 → 6,622 | **+0.863 ns** (last +1.703) | D-17 (5.11) |
| OOC_CSRU | 2,537 → 2,695 | +1.066 ns (last +0.569) | FS check, mconfigptr, mcountinhibit's delay (5.7) |

**Problem 1: OOO_IQ's slack fell to +0.36 ns**
- The worst path is "store bit → the load's wait (`older & v & st`, a 10-bit AND-OR) → ready → select → `iss_entry` (the payload's read address)".
- I had said it could stay out of the wakeup-select loop, but once it is in the ready term, the logic before the select is deeper.
- **Fix:** keep the wait as a 1-bit register per entry, its next state computed from the cycle's issue and kill. The logic before the select is back to what it was.

**Problem 2: OOC_CSRU +158 LUTs**
- Nearly all of it is holding a write to mcountinhibit until its commit (a 64-bit hold register and a 64-bit selector on CORE_CSR's write data). Compared with Yosys, that part alone is about +180 LUTs / +65 FFs. The FS check is required by the spec and stays.
- **Fix:** write in EX as before. OOO_CSRU keeps the old and new IR bits instead, and a small input to CORE_CSR's minstret add counts the writer's own commit one more (or one less). The counting stays as Spike's and Sail's, with only a few FFs and LUTs.

**The other three**
- **OOC_FE:** of +368 LUTs, TAGE is +229, more than the estimate (about 150). TAGE's paths are not in the top 10; their slack is 1.35 ns or more. The worst path, FBUF's loop (+0.863 ns), did not change; it is placement in a bigger design.
- **OOC_LSU / OOC_LSUDC:** the path of a load completing in M is not the worst one.

**Budget**
These five blocks add +0.6k LUTs; the overrun grows to 4.7k / 6.1k / 7.3k.

Prompts 112–114's English is in PROMPT.md, in the same commit.
<!-- /answer -->

## 115. 2026-11-01 11:22:38 JST

```text
Yes, both
```

<!-- answer -->
**Claude Code's answer**

Both are fixed and pushed as b86e1ae.

**1) OOO_IQ: the load's wait is a register**
- The wait is a 1-bit register per entry, `wtq`. The 10-bit AND-OR in front of the select is gone; the select sees only this bit.
- Its next state is "does an older store stay in the queue next cycle", so the issue sequence is the same, cycle for cycle. tb_iq agrees on 7 seeds with its reference unchanged.
- There is no term for a killed store: the loads younger than it carry the same mask bit and die with it, and nothing is dispatched in a kill cycle (OOO_CTRL's `d_ok`). The first mutation tried was not detected, which showed the term was equivalent.

**2) OOO_CSRU: mcountinhibit written in EX**
- The hold until commit (a 64-bit register and the write-data selector) is gone; it is written in EX like any other CSR.
- As in Spike and Sail, the writing instruction counts under the old IR bit. If it cleared IR, its commit is not counted (`ir_skip`, as for a write to minstret). If it set IR, it is counted although inhibited, through a new CORE_CSR input `instret_force` (the third change from mmRISC-2).

**Size (Yosys, before → after)**

| Top | LUT | FF |
|---|---|---|
| OOO_IQ | 3,118 → 3,119 | 474 → 484 |
| OOC_CSRU | 3,040 → **2,732** | 4,538 → 4,474 |

**Tests**
- The 28 unit tests, tb_csru on 4 seeds, run_core.sh's 12 runs, CoreMark and the stand-in test all pass.
- Mutations: the 41 of the issue queue and the CSR unit and mutate_core.py's 87 all detected; 340 unit mutations in all.
- CoreMark's cycles are unchanged. results/core.txt changed cycles in some runs, not from the RTL: every one of the 246 B2 and B4 programs run alone gives the same cycles as the RTL before.
  - The cause is tb_core: it makes a new model for each program, and Verilator's random initial values continue through the run. With a different number of registers, the models from the second on start with other values in what has no reset (the predictors' tables). This is noted in SIM/CORE/README.

Recorded in Plan/CORE 5.15, Plan/OOC 26.19 and the READMEs (English and Japanese).

**Please rerun Vivado.**

```bash
synth_ooo.bat OOO_IQ
```

```bash
synth_ooo.bat OOC_CSRU
```

Last time OOO_IQ was 1,951 LUTs with +0.360 ns, OOC_CSRU 2,695 LUTs. Expected: OOO_IQ's slack back near its value before 5.9 (+1.165 ns), OOC_CSRU around 2,537 LUTs plus the FS check. When done, ask me to check output/*/summary.txt.
<!-- /answer -->

## 116. 2026-11-01 12:27:22 JST

```text
I have finished the Vivado runs. Please check the results.
```

## 117. 2026-11-01 12:27:35 JST

```text
I have finished the Vivado runs. Please check the results.
```

<!-- answer -->
**Claude Code's answer**

I checked the results. Both meet 50 MHz. The CSR unit came out better than expected. In the IQ the load's wait is off the worst path, but another path of the same shape is now the worst, and the slack barely moved. Recorded in Plan/OOC 26.20 and UARCH's budget table, pushed as 0c0d9d3.

| Top | LUT | Slack (all / reg to reg) |
|---|---|---|
| OOC_CSRU | 2,695 → **2,496** (−199) | +1.066 → **+3.509 ns** |
| OOO_IQ | 1,951 → 1,997 (+46) | +0.360 → **+0.371 ns** / +5.884 → +6.607 ns |

**OOC_CSRU**
- With the FS check kept, it is smaller than before 5.7 (2,537): what had grown was only the write hold.
- The slack widened to +3.5 ns.

**OOO_IQ**
- The load's wait is off the worst path and register to register is back (+6.6 ns).
- The worst path is now "non-speculative bit (`nq`) → `older & v & ns` → ready → select → `iss_src` out": exactly the shape of the load's wait, one term over. The term has been there since 19.4; before 5.9 the same structure gave +1.165 ns, so the difference is placement. Of the 12.6 ns, 10.7 ns are routes.
- +46 LUTs are the wait's next-state logic (Yosys said +1).
- **What can be done:** make the non-speculative term a register per entry too ("an older non-speculative entry stays"), so the select sees only `ns_ok` and that bit. About 10 FFs.
- 50 MHz is met as it is, though. The out-of-context output delay of 6 ns is a guess for the path into the PRF's read in the core; the real margin shows in the whole-core run (B7).

**Budget**
−0.15k (CSR unit −199, issue queue +46); the overrun is now 4.5k / 5.9k / 7.1k.

The English of answer 115 and prompts 116–117 is in PROMPT.md, in this commit.
<!-- /answer -->

## 118. 2026-11-01 12:41:54 JST

```text
Yes, do it
```

<!-- answer -->
**Claude Code's answer**

The non-speculative wait is now a register per entry too, pushed as 4402888.

**Change (Plan/CORE 5.16)**
- The non-speculative term `(older & v & ns) == '0` is a 1-bit register per entry, `wnq` ("an older non-speculative entry stays"), made like the load's wait (5.15).
  - At dispatch it is set when a non-speculative µop stays in the queue or the first of the pair is one.
  - After that it stays set while an older non-speculative µop stays.
  - No term for a killed one, for the same reason as the load's wait.
- No AND-OR across the other entries is left in front of the select: ready takes only the operands, `ns_ok` and the two wait bits.
- The issue sequence is the same, cycle for cycle.

**Size (Yosys)**
OOO_IQ 3,119 → 3,221 LUTs, 484 → 494 FF. Last time the load's wait was +1 LUT in Yosys and +46 in Vivado.

**Tests**
- tb_iq agrees on 7 seeds with its reference unchanged, with the same issue counts.
- Mutations: M230 and M359 follow the new line, M377–M380 added. The 33 of the issue queue and mutate_core.py's 87 all detected; 344 unit mutations in all.
- The 28 unit tests, run_core.sh's 12 runs, CoreMark and the stand-in test all pass. CoreMark's cycles are unchanged.
- results/core.txt's cycles moved again only through tb_core's random initial values: the 246 B2 and B4 programs run alone all give the same cycles as with 5.15.

Recorded in Plan/CORE 5.16, Plan/OOC 26.21 and RTL/CPU/OOO/README (English and Japanese). Answer 117's English and prompt 118 are in PROMPT.md.

**Please rerun Vivado.**

```bash
synth_ooo.bat OOO_IQ
```

Last time 1,997 LUTs, slack +0.371 ns. I'll see whether the worst path has moved to the real wakeup-select loop (an operand's ready → select) or to one like before 5.9. When done, ask me to check output/OOO_IQ/summary.txt.
<!-- /answer -->

## 119. 2026-11-01 13:29:41 JST

```text
Vivado has finished. Please check the results.
```

<!-- answer -->
**Claude Code's answer**

The IQ's slack is back. Recorded in Plan/OOC 26.22, pushed as 0237a98.

| | LUT | FF | Slack (all / reg to reg) |
|---|---|---|---|
| Before 5.9 | 1,894 | 464 | +1.165 / +6.605 ns |
| After 5.15 | 1,997 | 484 | +0.371 / +6.607 ns |
| **After 5.16 (now)** | **1,999** | 494 | **+1.735 / +7.219 ns** |

- **Both waits are off the worst paths.** Only +2 LUTs (Yosys estimated +102).
- The worst path is now the select itself: "an entry's port (`pq`) → request → oldest-first grant → `iss_src` out", 10 levels, 9.4 of 11.3 ns in the routes.
- Register to register, the worst is the wakeup-select loop (`rq` → ready → select → issued tags → `rq`, 11 levels). The issue queue is built around that loop, so the path that should remain is the one that remains.
- The margin is larger than before the store wait (before 5.9).
- The budget stays as in 26.20; the overrun is 4.5k / 5.9k / 7.1k.

So the worst slack left among the per-block runs is OOC_FE's fetch-buffer loop (+0.863 ns), then the LSU with the D$ (+1.340 ns), then the issue queue (+1.735 ns). Plan/CORE section 6's timing entry is updated to these values.

Answer 118's English and prompt 119 are in PROMPT.md, in this commit.
<!-- /answer -->

## 120. 2026-11-01 17:10:58 JST

```text
Please propose the next steps to go on with.
```

<!-- answer -->
**Claude Code's answer**

From where things stand, I propose this order toward G1.

**Where things stand**
- B0 to B4 are done. B6 is partly there: CoreMark passes in lock-step with Spike.
- **Performance:** 6.5 % / 7.5 % / 8.1 % behind the model (fusion off). G1's targets 6.243 / 6.680 / 6.066 are the model with fusion, so they cannot be reached without fusion.
- **Size:** from the sum of the blocks, 4.5k / 5.9k / 7.1k LUTs over budget, about 96 % of the device: the biggest risk.
- **Not done yet:** B5 (fusion on, interrupts), B7 (the whole core in Vivado), the real I$ (CoreMark runs with an ideal I$ now).

**Proposal 1: B7, the whole core out of context (first, in parallel)**
- An OOC_WRAP for OOO_CORE (or OOO_CPU with the D$) and a synth_ooo.bat top. Little work on my side; Vivado runs on your Windows machine while I go on with proposal 2.
- What it shows: whether the overrun is as estimated (a whole core out of context counts as on the chip), and the real paths between blocks, e.g. `iss_src` → the PRF's read, or the LSU's completion → the ROB, which per-block runs measure only with guessed I/O delays.
- If the overrun is real, the reserve levers (L10, B4 / B5 reductions) need deciding early, and further performance changes can be chosen with size in view.

**Proposal 2: B5, fusion on (kind by kind)**
- OOO_FUSE is already wired with fusion off. Turn it on kind by kind, each time passing the B4 suite and CoreMark in lock-step (first halves checked with `rd_skip`).
- In the model fusion is worth about 6 % (5.876 → 6.243). This is needed to compare with G1's targets.
- Interrupts (a timer model) come in B5's second half: not for CoreMark, but needed for Phase 1's correctness.

**Proposal 3: the real I$ (finishing B6)**
Widen mmRISC-2's ICACHE to 16 bytes and connect it to OOO_CPU. CoreMark should have few I$ misses, but "within ±5 % with the real caches" is G1's criterion.

**Proposal 4: the remaining performance gap**
If the gap is still above 5 % after fusion, look function by function as in 5.12: candidates are bitextract's second multiply, `core_bench_list`, `core_state_transition`.

My recommendation: **write B7's wrapper first and have you run Vivado, and meanwhile go on with B5's fusion.**

Prompt 120 is logged in PROMPT.md but not committed yet; it goes in with the next work.
<!-- /answer -->

## 121. 2026-11-01 17:16:35 JST

```text
Yes, B7 then B5
```

<!-- answer -->
**Claude Code's answer**

B7 is ready, and the model has decided how to go on with B5.

**B7: the whole core out of context (48d30d2)**
- The new top `OOO_CPU` is OOO_CORE with OOO_DCAD and the D$, the core as it will go into the chip. It is synthesized with its own ports (the I$ port, AXI4, AXI4-Lite) and the 30 % I/O delay, the same conditions as mmRISC-2's calibration (Plan/OOC 25, ratio 1.00). The simulation ports go away without defines such as `OOO_TRACE`.
- summary.txt gives, besides the usual numbers, the 20 worst paths between flip-flops by endpoint (100 in timing_paths.rpt). The paths between the blocks are seen here for the first time without guessed I/O delays.
- **Checked beforehand:**
  - lint (`-Wall`): 27 warnings, all known. OOO_CORE's 3 UNOPTFLAT are Verilator grouping always blocks; bit by bit there is no loop.
  - Yosys: 47,525 LUT cells + 2,848 LUT RAM, 18,003 FF. From the ratios on the blocks so far, about 33k to 36k in Vivado. The expectation summed from the blocks (33.5k to 34.6k) is in Plan/OOC 27.1.

**Please run Vivado (it takes long).**

```bash
synth_ooo.bat OOO_CPU
```

**B5: the fusion kinds CoreMark uses (1146615, Plan/CORE 5.18)**
With the model in the core's configuration, each fusion kind on alone against fusion off (the model has a new `fuse_kinds` option):

| Kind | g14 -O2 | g14 sf+lto | g13 |
|---|---|---|---|
| All of level 2 | −3.30 % | −2.50 % | −3.15 % |
| ALU + branch | −2.34 % | −2.23 % | −2.41 % |
| ALU + load | −0.96 % | −0.25 % | −0.55 % |
| auipc + x | 33 pairs, 0 | 5 pairs, 0 | 33 pairs, 0 |
| lui+addi, slli+srli, load pairs, store pairs | 0 | 0 | 0 |

- **CoreMark has only two fusion kinds, ALU + branch and ALU + load: 99.98 % of the pairs.** Load and store pairs do not pass the SRC2 / W1 limits.
- ALU + branch is worth the most, and almost everything for it is there: OOO_ALU2 has the fused compare, and the ROB and OOO_TRAP handle fused pairs. OOO_CORE only ties them to constants now.
- ALU + load is worth about a third of that and needs an ALU operation in the LSU.
- The model with fusion gives 6.076 / 6.566 / 5.965 CoreMark/MHz. Section 6's G1 targets (6.243 / 6.680 / 6.066) were made before stores issued with their data (5.8), so these are lower. Whether to bring the targets to these values needs deciding separately.

My recommendation: **as B5a, turn on ALU + branch only, and leave the kinds CoreMark does not use off in OOO_FUSE.** ALU + load (B5b) to be decided after B5a's results.

Prompt 121 is logged in PROMPT.md, in the B7 commit.
<!-- /answer -->

## 122. 2026-11-01 17:36:06 JST

```text
Yes, ALU + branch
```

<!-- answer -->
**Claude Code's answer**

ALU + branch fusion (B5a) is in, pushed as 434d327. It works correctly, but CoreMark is hardly faster.

**Implementation (Plan/CORE 5.19)**
- OOO_FUSE has a kind mask `KINDS`; the core turns on ALU + branch only.
- A pair is one µop: the ALU half's operation, rd and sources, with the fused compare in OOO_ALU2 and the branch's offset, prediction and checkpoint. The ROB counts it as two instructions.
- Found by the tests and fixed:
  - `or s1, s1, s1` + a branch (br-1): the branch's other operand has no place. An operation reading one register twice is not paired.
  - `mv a0, a0` + `beq a7, a0` (br-10): an x0 the ALU half reads becomes the constant 0, which frees that side, and a7 goes there.
- A pair across two FTQ blocks works by reading the pc array one block back. The filter added first ("not paired when the ALU half crosses a line") was for a case that cannot happen. A mutation that no test detected showed it, and the filter is gone.
- tb_core checks a pair's resolution against its branch, and every resolution's pc against the pc at dispatch.

**Tests**
run_core.sh's 12 runs, CoreMark, the 28 unit tests and the stand-in test all pass, with no new lint warning. Core mutations: all 99 detected, 12 of them for B5a. OOO_FUSE's 8 unit mutations detected too.

**Result: about a seventh of the model's gain**

| Cycles | g14 -O2 | g14 sf+lto | g13 |
|---|---|---|---|
| OOO_CORE (the model's caches) | 1,813,160 → 1,807,119 (−0.33 %) | 1,678,934 → 1,668,660 (−0.61 %) | 1,871,639 → 1,866,911 (−0.25 %) |
| Model (ALU + branch) | −2.34 % | −2.23 % | −2.41 % |

- The core makes 74 % / 86 % / 63 % of the model's pairs; the rest are split at D2's group boundary.
- The cause of the small gain is D1b: its group register takes the next group only when D2 has emptied it. Taking "a pair + one instruction" out of 4, the last instruction goes alone the next cycle. Counted, the cycles dispatching one µop only grow from 115,938 to 180,453, nearly cancelling what fusion saves.
- To get the gain, D2 must take µops across the group boundary: a change touching D1b / D2's timing (Plan/OOC 26.8).

**B7's result is in too**
The Vivado run is of the RTL of 48d30d2, before B5a. Not recorded or analyzed in detail yet.
- **Size:** OOO_CPU is 35,961 LUTs, a little above the estimate from the blocks (33.5k to 34.6k): the estimate roughly holds.
- **Timing:** WNS **−5.716 ns** (46 levels), not meeting 50 MHz. The path is "port 1's WB (bypass) → ALU1's branch compare → misprediction → the ROB's restore choice (oldest misprediction) → OOO_TRAP's tval keep-or-drop (`tv_d`), and the ROB's exception bits": a path across blocks that the per-block runs could not see. Applying the restore to TRAP and the ROB a cycle later is a candidate fix.

Prompt 122 is logged in PROMPT.md, in this commit.
<!-- /answer -->

## 123. 2026-11-01 19:33:02 JST

```text
Yes, analyze B7
```

<!-- answer -->
**Claude Code's answer**

I analyzed B7's first run. Both size and timing are tighter than estimated from the per-block runs. Recorded in Plan/OOC 27.2–27.3 and UARCH's budget table, pushed as cc5f9c1 (the run is of the RTL before B5a).

**Size: the OoO engine is 3.2k larger**

| | LUT |
|---|---|
| OOO_CPU in all | 35,961 (FF 17,830) |
| D$ | 6,282 (estimate about 5.2k) |
| CORE_CSR | 556 (alone 2,496) |
| CORE_MDU | 2,945 |
| **OoO engine** (u_core − CSR − MDU + adapter) | **26,178** (budget middle 23.0k, sum of the blocks about 21.5k) |

- **CORE_CSR is small because Phase 1 leaves its PMP, translation and debug outputs open.** Vivado removes what only feeds them. The chip budget keeps mmRISC-2's 4,750.
- **The 4.7k over the blocks' sum is OOO_CORE's own logic:** D2, the DS payload, each port's RR / EX (bypass, pc, branch resolution, port 0's result select), which no per-block run contained. Vivado spreads it into the child instances (port 0's EX stage has 4,223 LUTs, for one), so only sums compare.
- Over budget by **8.3k / 9.1k / 9.8k**: the whole chip about 64k LUTs, more than the device (63,400). After timing is closed, the reserve levers (L10, B4 / B5) and the core's own logic are what to cut.

**Timing: WNS −5.716 ns, 15,202 failing endpoints**
The 100 worst all start at port 1's WB register.

| Along the worst path | Arrives |
|---|---|
| WB → bypass → ALU1's operand | 6.1 ns |
| branch compare → `take_branch` | 10.5 ns |
| misprediction | 13.4 ns |
| the ROB's oldest misprediction (`restore_rob`) | 15.8 ns |
| OOO_TRAP's tval keep or drop | 26.2 ns |

- **The cause: a misprediction found in EX is used as the restore by every block in the same cycle** (OOO_CTRL's kill, renaming, LSU, FTQ, ROB, TRAP). The per-block runs saw it as an input with 30 % of the period; really it arrives at 15.8 ns, and the TRAP tval, the ROB's exception bits and the LSU's kill into the D$ and the PRF do not fit in the 4 ns left.
- **Proposal A (recommended):** put the branch resolution through a register, and restore / kill / redirect a cycle later.
  - It costs a cycle per misprediction: +0.21 to 0.26 % in the model.
  - Two things are needed: in the cycle between, the mispredicted branch and the µops younger than it must not commit; the younger µops of that cycle move one stage on and are killed there by their masks, as now.
  - The fused compare makes the path longer still, so it is needed for B5a as well.
- **Proposal B:** register each slow consumer (TRAP, ROB, LSU). Smaller steps, but every consumer must tolerate a late kill, and the same signal into another block would just become the next worst path.
- All 100 share one start, so what is behind them is not seen yet. For the next run, synth_ooo.tcl now reports the worst path into and out of each OOO_CPU block.

Prompt 123 is logged in PROMPT.md, in this commit.
<!-- /answer -->

## 124. 2026-11-01 19:41:20 JST

```text
Yes, do A
```

## 125. 2026-11-01 22:09:12 JST

```text
Please try again.
```

<!-- answer -->
**Claude Code's answer**

Proposal A (the branch resolution through a register) is in, pushed as 089d31f. The CoreMark cost stays at about +0.4 %.

**Change (Plan/CORE 5.20)**
- Everything EX decides about a branch goes into a register at the end of EX and acts a cycle later: `br_*` (misprediction, checkpoint, next pc, ...), `rs_*` (the predictors' training), `bt_*` (the BTB's write). The restore, kill and redirect are a cycle later too. A branch killed or flushed as it leaves EX is dropped.
- **Commit:** a mispredicted branch completes in the cycle of its restore (the ROB's completion ports 6 / 7 added). In the cycle between, neither it nor any younger µop commits. A branch resolved as predicted completes in EX as before.
- **The checkpoint clear (`clr`) stays in EX** (OOO_CTRL has new inputs `cl_valid` / `cl_ckpt`).
  - First the clear was a cycle later too, which made CoreMark 1.8 to 2.2 % slower.
  - A trial build with 8 checkpoints took the loss away, showing the cause: every branch held its checkpoint a cycle longer.
  - Clearing early is safe: even if the checkpoint of a branch killed the next cycle is freed first, renaming is stopped in that cycle, and the younger µops carry the restoring branch's bit as well.

**CoreMark (cycles)**

| | g14 -O2 | g14 sf+lto | g13 |
|---|---|---|---|
| OOO_CORE | 1,807,119 → 1,813,605 (+0.36 %) | 1,668,660 → 1,675,783 (+0.43 %) | 1,866,911 → 1,873,955 (+0.38 %) |
| Model (a cycle more per misprediction) | +0.26 % | +0.21 % | +0.25 % |

**Tests**
- run_core.sh's 12 runs, CoreMark and the 28 unit tests all pass, with no new lint warning.
- Core mutations: all 103 detected (4 new). OOO_CTRL's 18 unit mutations all detected.
- OOO_CTRL's per-block harness (OOC_CTRL) has its input bus widened to 249 bits.

**Please rerun Vivado.**

```bash
synth_ooo.bat OOO_CPU
```

This run includes B5a's fusion too. What remains in EX's cycle is "bypass → compare → misprediction (13.4 ns last time) → register", the `clr` (into the masks' flip-flops) and the done bit's write enable, so last time's −5.7 ns path should be gone. summary.txt now also gives the worst path into and out of each block, so what is behind will show. When it finishes, ask me to check the results.

Prompts 124 and 125 are logged in PROMPT.md, in this commit.
<!-- /answer -->

## 126. 2026-11-01 23:28:50 JST

```text
The Vivado rerun has finished. Please check the results.
```

<!-- answer -->
**Claude Code's answer**

I checked the results. 5.20, the branch resolution through a register, worked, but the fused compare that came in with this run (B5a) does not fit in a cycle, and WNS got worse. Recorded in Plan/OOC 27.5 and UARCH's budget table, pushed as daa25c6.

| | 1st run | **2nd run (with B5a and 5.20)** |
|---|---|---|
| OOO_CPU | 35,961 LUTs | **38,071 LUTs** |
| OoO engine | 26,178 | **28,152** |
| WNS | −5.716 ns | **−6.442 ns** |
| Failing endpoints | 15,202 | **3,400** |
| TNS | −22,896 ns | −6,735 ns |

**5.20 worked**
The class of paths through the restore into TRAP and the ROB is gone. The failing endpoints fell to a fifth and TNS to about 30 %.

**WNS got worse because of B5a's fused compare**
The new worst path (58 levels):

| Along the path | Arrives |
|---|---|
| WB → bypass → ALU0's result | 14.5 ns |
| fused compare (`take_branch`) | 18.3 ns |
| misprediction | 21.4 ns |
| the clr out of EX | 23.9 ns |
| the masks of the issue queue and others | 27.4 ns |

The ALU operation followed by the compare in one cycle alone exceeds the 20 ns period. An unfused branch finishes its compare at about 10.5 ns.

**The paths behind it (newly visible in the per-block report)**

| Class | Slack |
|---|---|
| D2: group → fusion → renaming → DS register | −4.05 ns |
| the completion's exception into the ROB's entries (a load completing in M from the D$, the CSRs) | −3.05 ns |
| a load's data into the register file (from the D$'s forwarding, 5.14) | −2.29 ns |
| OOO_TRAP (from the privilege input) | −1.30 ns |
| the fetch buffer's loop | −0.95 ns |

**Size**
+2.1k on the first run. Yosys with and without fusion puts fusion at about 0.5k in Vivado; the rest is the ROB with eight completion ports (2,576 → 3,195) and D2's added logic. The overrun is now 10.3k / 11.1k / 11.8k.

**Proposals**
1. First turn ALU + branch fusion off (`KINDS` 0, the RTL kept). While D1b refills only when empty it is worth only −0.3 to 0.6 %, yet costs about 0.5k LUTs and its compare does not fit. Bring it back when the compare moves to the cycle after EX or D2's refill is fixed.
2. Then the paths in the table above in order: D2's path, the completion's exception (through a register, as the misprediction), a load's data (with 5.14's completion in M, the data could be a cycle after the completion), TRAP's privilege input.

Prompt 126 is logged in PROMPT.md, in this commit.
<!-- /answer -->

## 127. 2026-11-01 23:39:26 JST

```text
Yes, turn it off
```

<!-- answer -->
**Claude Code's answer**

ALU + branch fusion is off, pushed as 7d4a8fa.

**Change (Plan/CORE 5.21)**
- The core's OOO_FUSE has `KINDS` 0. No pair forms, and the pairs' logic (its fields become constants) is removed by synthesis.
- The RTL stays. It comes back when the fused compare moves to the cycle after EX (the resolution register of 5.20) or D2's refill is fixed.
- B5a's 12 core mutations cannot be detected while no pair forms, so they are in `MUT_B5A`; with `KINDS` back at 8'h80 they run with `B5A=1`.

**CoreMark (cycles)**

| | g14 -O2 | g14 sf+lto | g13 |
|---|---|---|---|
| OOO_CORE (5.20 → now) | 1,813,605 → 1,817,188 | 1,675,783 → 1,688,978 | 1,873,955 → 1,881,282 |
| Against 5.14 (no fusion, resolved in EX) | +0.22 % | +0.60 % | +0.52 % |
| OOO_CPU (the real D$) | 1,846,314 | 1,731,810 | 1,893,730 |

**Tests**
run_core.sh's 12 runs and CoreMark pass; all 91 core mutations detected.

**Please rerun Vivado.**

```bash
synth_ooo.bat OOO_CPU
```

Expected: the fused compare's path gone (an unfused branch's misprediction at about 13.4 ns), about 0.5k fewer LUTs, and the worst paths moving to the classes seen behind it last time (D2 −4.05 ns, the completion's exception into the ROB −3.05 ns, a load's data into the register file −2.29 ns, TRAP −1.30 ns, the fetch buffer −0.95 ns). When done, ask me to check the results.

Prompt 127 is logged in PROMPT.md, in this commit.
<!-- /answer -->

## 128. 2026-11-02 00:44:23 JST

```text
Vivado has finished. Please check the results.
```

<!-- answer -->
**Claude Code's answer**

I checked the results. With fusion off, the fused compare's path was still in the circuit. WNS is −7.362 ns. Recorded in Plan/OOC 27.7 and UARCH's budget table, pushed as 7fb17c9.

| | 2nd run | **3rd run (fusion off)** |
|---|---|---|
| OOO_CPU | 38,071 LUTs | **37,421 LUTs** (−650) |
| OoO engine | 28,152 | **27,485** |
| WNS | −6.442 ns | **−7.362 ns** |
| Failing endpoints | 3,400 | 2,596 |
| TNS | −6,735 ns | −3,707 ns |

**Why the fused compare remains**
- The worst path (63 levels):
  - WB → ALU0's adder → the compare's carry chain (`take_branch` 19.4 ns) → misprediction (21.9 ns)
  - → the clr out of EX (24.4 ns) → the issue queue's `iss_bm` → RR's valid, MDUP (28.3 ns)
- With `KINDS` 0 the pairs' fields are constants at D2, but the µop record goes through OOO_IQPL's LUT RAM, so Vivado cannot tell that `fused` is always 0. The "compare with the ALU's result" path stays in EX.
- D2's class of paths is gone (renaming −0.85 ns, DS register +1.01 ns): D2's delay was mostly fusion's fields.

**The clr reaches the issue queue's select output**
OOO_IQ gives `iss_bm` as `bm & ~clr`, but every receiver (the RR stages, MDUP) applies `& ~clr` again as it registers, and the kill compare does not need it (a checkpoint being cleared is never the one restored). That `~clr` pulls EX's clr into the select's output path.

**Proposals (both small)**
1. Gate EX's fused path with the fusion parameter: with `KINDS` 0, `fused` is a constant and the compare reads s1 / s2 alone (about 10.5 ns).
2. Take `~clr` out of `iss_bm`.

**What to fix after that**

| Class | Slack |
|---|---|
| the CSR unit's result into the register file | −2.68 ns |
| a load's data into the register file (5.14's completion in M) | −2.40 ns |
| the privilege level into TRAP / D$ / LSU | −2.10 / −1.60 / −0.96 ns |
| the fetch buffer's loop | −0.14 ns |

Size went down by only 650 LUTs (part of fusion's logic remains). The overrun is 9.6k / 10.4k / 11.1k.

Prompt 128 is logged in PROMPT.md, in this commit.
<!-- /answer -->

## 129. 2026-11-02 00:48:35 JST

```text
Yes, both
```

<!-- answer -->
**Claude Code's answer**

Both are fixed, pushed as 289cc2a.

**1) The fused path gated by the core's parameter**
- OOO_CORE has `FUSE_KINDS` (OOO_FUSE's `KINDS`) and `FUSE_AB` (its ALU + branch bit). Every use of a pair after D2 is gated by `FUSE_AB`: the fused compare's `br_fused`, the next pc and target after the ALU half, the ROB's `disp_fused` and length, the trace's pair.
- With fusion off, `fused` is a constant and EX's compare reads s1 / s2 alone.
- Yosys: OOO_CPU 49,106 → 46,768 LUT cells (−2,338). The fused compare, its selects and the pair's adders were larger than expected.

**2) `~clr` out of the issue queue's `iss_bm`**
- The issued µop's mask is the entry's as it is. Every receiver applies `& ~clr` as it registers it or only compares it with kill, so behavior is unchanged.
- The clr from EX no longer enters the select's output path.
- tb_iq now expects "the mask before that cycle's clr". Two unit mutations added (M381, M381b).

**Tests**
- CoreMark's cycles are exactly unchanged, as expected for two changes that do not alter what the core does.
- run_core.sh and the 28 unit tests (tb_iq on 7 seeds) pass, with no new lint warning.
- Core mutations: all 91 detected; unit mutations: 346 detected. The B5a mutations set aside follow the gated lines.

**Please rerun Vivado.**

```bash
synth_ooo.bat OOO_CPU
```

Expected: an unfused branch's misprediction at about 13.4 ns, with the clr after it only going into the masks' flip-flops; about 1.5k fewer LUTs; the worst paths moving to the classes seen behind last time (the CSR result and a load's data into the register file, the privilege level, the fetch buffer). When done, ask me to check the results.

Prompt 129 is logged in PROMPT.md, in this commit.
<!-- /answer -->

## 130. 2026-11-02 01:51:38 JST

```text
The Vivado rerun has finished.
```

<!-- answer -->
**Claude Code's answer**

**The whole core meets 50 MHz.** WNS is +0.159 ns with no failing endpoint. This is the first time a whole-core out-of-context run has closed timing (mmRISC-2's core had +0.002 ns under the same conditions). Recorded in Plan/OOC 27.9 and UARCH's budget table, pushed as cfac2ee.

| | 1st run | 3rd run | **4th run** |
|---|---|---|---|
| OOO_CPU | 35,961 LUTs | 37,421 LUTs | **36,445 LUTs** |
| OoO engine | 26,178 | 27,485 | **27,042** |
| WNS | −5.716 ns | −7.362 ns | **+0.159 ns** |
| Failing endpoints | 15,202 | 2,596 | **0** |

**Paths with little margin**
- **+0.159 ns:** CORE_CSR's privilege level (`priv_r`) → the checks of a completing µop (CSR legality, ECALL's cause) → the write enables of the ROB's exception and cause bits (25 levels). All of the 20 worst are of this kind.
- **+0.79 to 0.98 ns:** EX's compare → the clr from EX → OOO_CTRL's checkpoint masks (34 levels).
- **+1.13 ns:** the issue queue.
- **+1.42 ns:** the fetch buffer's loop.
- Nothing else is below +1.5 ns.

**Size is what is left for G1**
- Over budget by 9.1k / 9.9k / 10.6k. The whole chip is about 62k LUTs in the middle estimate (the 52k ceiling + 9.9k), 98 % of the device. About 80 % is what routes, so it does not fit as it is.
- The "about 64k" of the earlier analysis (27.2) was miscalculated; with the same "ceiling + overrun" it is about 61k, corrected too (f770b71).
- Candidates to cut:
  - **Reserve levers:** L10, B4 / B5.
  - **The core's own logic:** about 4.7k that was in no per-block run, as the first analysis showed.
  - **ROB:** 3,717 LUTs with eight completion ports; the mispredicted branches' two could share EX's.
  - **D$:** 6,046 LUTs.
  - **Front end:** 7,831 LUTs.

Prompt 130 is logged in PROMPT.md, in this commit.
<!-- /answer -->

## 131. 2026-11-02 20:41:54 JST

```text
Thank you for all this study. Here I want to make an important change of plan.

(1) The FPGA's logic capacity is short now, and reducing logic for it keeps us from the performance we want. If this goes on, working hard on a superscalar out-of-order design loses its meaning, I think. So I want to use a larger FPGA.

(2) The FPGA chip to use now is the Xilinx XC7A200T-1SBG484C, twice the size of the XC7A100T designed for so far. The FPGA board changes to the Digilent Nexys Video. The technical information on that FPGA and board is in Ref in the local repository.
Do not push this Ref to the remote repository.

(3) For logic at the size of the XC7A200T, review the micro-architecture anew so that, as a CPU core, it comfortably exceeds 6.0 CoreMark/MHz with -O2.

(4) The FPGA board changes, but in the end I want BusyBox and Debian 13 to boot from a micro SD card, and Ethernet to connect. The micro SD card should work plugged directly into socket J3 on the board, without a PMOD. Ethernet's PHY chip changes to the RTL8211E. The JTAG/cJTAG debug interface should be brought out on the board's PMOD connector JA as before. Consider the switches and LEDs following the previous use. Let us consider 50 MHz as before for the operating frequency.

(5) First, sort out what has to be done for this change of plan, and put the order of work together. I think it divides broadly into these 3 steps:
- Review the architecture and RTL of the CPU core and related functions, and reach the performance.
- Review the peripheral logic and fit it to the new FPGA board.
- Prepare Linux (BusyBox and Debian) and boot it.

(6) With this change of plan, also make a large review of the documents as a whole.

(7) Point out any problems or concerns. In particular, I want to know any concerns about the new FPGA board early, to go ahead with the purchase.
```

<!-- answer -->
**Claude Code's answer**

I sorted out the order of work and the concerns for the change of plan, and rewrote the documents (pushed as d90ef38). `Ref/` is in `.gitignore`, and I confirmed it is not on the remote. All the numbers are from the model or estimates; the RTL's function has not changed, and nothing has been tried on the board.

**Conclusion: I propose 3-wide.** Comparing configurations in the model set to today's core (g14 `-O2`; the RTL value is from today's RTL being about 0.94 of the model):

| Configuration | Model | RTL expected |
|---|---|---|
| Today's core (2-wide) | 5.805 | 5.50 (measured) |
| 2-wide, everything but fusion | 6.07 | 5.7 |
| 2-wide, everything with fusion | 6.37 | 6.0 |
| **3-wide proposal** | **7.17** | **about 6.7** |

- **The limit of 2-wide:** larger ROB and IQ hardly help; it cannot reach "comfortably above 6.0".
- **The proposal:** 3 full ALUs + LSU, 4 issues, IQ 16, ROB 32, LQ / SQ 12, 8 checkpoints, TAGE M.
- **Size:** about 84k LUTs for the whole chip, 62 % of 134,600 (the ceiling is 80 %). The blocks from mmRISC-2 can stay at full size.
- **The limit is now timing:** the same -1 speed grade; about twice the logic but not faster, and today's 2-wide core has only +0.159 ns.

**Order of work (`Doc/STRATEGY.md` section 5)**
1. **The core:** freeze the configuration with the decode group's boundary in the model; a queue between decode and rename; the width as a parameter (first 2-wide with no cycle changed, then 3-wide); the real I$ / L2; MMU, FPU, interrupts, debug. Gates: RTL `-O2` ≥ 6.5 with real caches, Linux booting in simulation.
2. **The board (in parallel when it arrives):** first mmRISC-2, known to work, for DDR3, SD on J3, Ethernet, JTAG on JA, then mmRISC-3. This differs from your order (board after core), and I recommend it because it separates the board's problems from the new core's.
3. **Linux:** OpenSBI, device tree, BusyBox, Debian 13, Ethernet. Gates: the 120-minute stress test, `-O2` above 6.0 on the board under Linux (working target 6.2).

The switches, LEDs and JA assignments are in `Doc/BOARD.md` sections 7 and 8. SW2, SW3 and JA's positions stay; with no RGB LEDs, the status moves to LD0 to LD3.

**To check before ordering**

| # | Concern | What to do |
|---|---|---|
| 1 | **Lead time:** 11 weeks, or a 70-week factory lead time, are listed | Check stock with Japanese distributors |
| 2 | **Power:** 12 V, at least 3 A, not USB; distributors list a supply with US / EU plugs | Check it is in the box and rated for 100 V |
| 3 | **The other end of Ethernet:** LiteEth's RGMII is 1 Gb/s only | A 1000BASE-T port is needed (check your setup; a small gigabit switch solves it) |
| 4 | **Cooling:** I could not confirm a heat sink from the documents | Ask the seller (there are solder points for a fan) |
| 5 | **microSD position:** J3 is on the underside | The board is lifted to change cards; stand-offs help |

The free Vivado ML Standard covers the XC7A200T; no licence to buy.

**Design concerns**
- **DDR3 (the most important):** mmRISC-2 ran DDR3-400, below JEDEC's minimum. The Nexys Video has 4 possible DDR3 parts, and the same is not guaranteed on all. I recommend LiteDRAM at 100 MHz (DDR3-800) with the CPU staying at 50 MHz.
- **Switch and button voltage:** VADJ defaults to 1.2 V, but LiteX's platform says `LVCMOS25`, which would read a high as low. `LVCMOS12` it is.
- **SD:** `SD_RESET` must be low to power the slot. LiteSDCard handles it.
- **JTAG:** JA3 (AB20) is a configuration dual-purpose pin, but an output, which suits TDO. The 200 Ω series resistor (for below 10 MHz) is within TCK's 10 MHz too.
- **Risks of 3-wide:** whether it closes at 50 MHz, and whether the RTL falls further behind the model. Fusion stays off for now. Measured at each step, with the stores' split and 2 LSU ports in reserve.

**Documents**
- New: `Doc/BOARD`, `Plan/model/g200t.sh`
- Rewritten: `Doc/STRATEGY`, `README`
- Revised: `Doc/UARCH` (section 0 and 4.5), `Plan/CORE`, `Plan/OOC`
- Kept as history: the old strategy moved to `Plan/STRATEGY_A100T`; `Plan/REDUCE` and `Plan/ISSUES` of the Arty era say so at the top.

`synth_ooo.tcl` now targets the XC7A200T. **Even before the board arrives**, this shows the build time and memory on the larger device:

```bash
synth_ooo.bat OOO_CPU
```

**To decide (`Doc/STRATEGY.md` section 7)**, my recommendations: 3-wide; 6.0 measured on the board under Linux as before; the board brought up first with mmRISC-2; LiteDRAM at 100 MHz; Ethernet 1 Gb/s only; fusion stays off.

Prompt 131 is logged in PROMPT.md, in this commit.
<!-- /answer -->

## 132. 2026-11-02 21:02:12 JST

```text
With this FPGA's size, can it be extended from 2 issues to 4 issues?
Also, LiteX seems to support the Nexys Video board, so please consider making use of those resources too.
```

<!-- answer -->
**Claude Code's answer**

**By area alone, 4-wide also fits on the XC7A200T. But 4-wide alone hardly speeds things up, and the real question is whether 50 MHz holds.** LiteX supports the Nexys Video, so it becomes the base on the board's side. Recorded in `Doc/STRATEGY` 4.1 and `Doc/BOARD` sections 2 to 4, pushed as dff98d9.

**On 4-wide (4-issue)**
A note on terms: today's core renames 2 and issues 3 a cycle (2 ALUs + LSU). The earlier proposal **already issues 4** (3 ALUs + LSU) and renames 3. Rename and dispatch width matter more than issues: 4 issues with 2 dispatched stays at 6.04. "4-wide" below means 4 renamed, dispatched and committed.

| Configuration | Model `-O2` | RTL expected | Chip LUTs (estimate) | Needs besides the width |
|---|---|---|---|---|
| **3-wide (proposal)** | **7.17** | **6.7** | 84k, 62 % | |
| 3-wide + 2 LSU ports | 7.46 | 7.0 | 92k, 68 % | D$ with 2 ports |
| 4-wide (3 ALUs + LSU, the proposal's sizes) | 7.22 | 6.8 | 88k, 65 % | Almost no gain |
| 4-wide (4 ALUs + LSU, IQ 24, ROB 48) | 7.45 | 7.0 | 96k, 71 % | Fetch limits it |
| 4-wide (3 ALUs + 2 LSU) | 7.75 | 7.3 | 102k, 76 % | D$ with 2 ports |
| 4-wide (4 ALUs + LSU, 6 decoded, 32-byte fetch) | 7.97 | 7.5 | 105k, 78 % | I$ 32 bytes wide |
| 4-wide (4 ALUs + 2 LSU, 6 decoded, 32-byte fetch) | 8.60 | 8.1 | 115k, **85 %** | Both; over the 80 % |

- **Area:** fits up to the ceiling of about 107k; the full version exceeds it. The 4-wide estimates are rougher than 3-wide's.
- **Effect:** 4-wide alone gives +0.7 to 3.8 %. It pays only with a wider fetch and a second LSU port, each a large piece of work.
- **Timing (unmeasured):** rename's dependence checks in a cycle go from 1 to 6, the bypass from 3 sources to 6, select from 3 ports to 5 or 6. Today's 2-wide has only +0.159 ns.

**I recommend building 3-wide first.** It reaches the goal with a margin, and with the width as a parameter the way to 4-wide stays open. After gate S1-B (RTL `-O2` ≥ 6.5 with real caches), in order of measured effect: 2 LSU ports (+4 %), then 4-wide.

This shows the timing of a 24-entry issue queue right away (with today's 3 ports):

```bash
synth_ooo.bat OOO_IQ 20.0 1 N=24
```

**Making use of LiteX**
With the local LiteX, the stock target with Rocket, SD and Ethernet generated its Verilog, constraints and Vivado script (generation only; no Vivado, no board). The memory map is mmRISC-2's, main RAM 512 MiB from 0x8000_0000.

**This changes the plan in two points.**
1. **A first check (step 2.0):** the stock SoC (Rocket) as it is, to check BIOS, memory test, SD and TFTP, and as a Linux reference. The Vivado run needs no board. The order is stock SoC → mmRISC-2 → mmRISC-3.
2. **The DDR3 recommendation changes:** last time LiteDRAM alone at 100 MHz. Now **all of LiteX at its default 100 MHz (DDR3-800), the CPU alone at 50 MHz**, using LiteX's AXI clock crossings in the CPU's wrapper. The stock target is used almost as it is, and the new logic is in one file. Peripherals at 100 MHz and the crossing's DRAM latency are to be measured.

**Other parts available:** `xadc.py` (temperature and voltage, useful for the cooling concern); `spiflash4x` + LiteSPI (boot from flash); `i2c` (MAC address from the EEPROM); `icap.py` (reconfiguring from software); `fan` + `pwm.py` (if a fan is fitted).

**Not used as they are:** `LVCMOS25` on switches and buttons (to `LVCMOS12`); `--eth-dynamic-ip` (tried: it conflicts with the default `eth_ip`, and the target has no `--eth-dhcp`; the Arty's is added to our target); `LedChaser` taking all LEDs; SD pins without timing constraints.

The list is in `Doc/BOARD.md` section 2.

Prompt 132 is logged in PROMPT.md, in this commit.
<!-- /answer -->

## 133. 2026-11-02 21:21:41 JST

```text
Is aiming for 100 MHz on the CPU core a large risk?
```

<!-- answer -->
**Claude Code's answer**

**Yes, the risk is large. And not only technically: it conflicts with the goal of "-O2 above 6.0 CoreMark/MHz" itself.** 100 MHz needs a longer pipeline; performance per second rises, but CoreMark/MHz falls below 6.0.

The 3-wide proposal with a longer pipeline in the model (g14 `-O2`; the stage counts are estimates from measured paths):

| Clock | Pipeline | Model /MHz | RTL expected /MHz | CoreMark/s |
|---|---|---|---|---|
| **50 MHz** | The proposal | **7.17** | **6.7** | **337** |
| 66.7 MHz | Decode +1, redirect +1, load 3, mul 3 | 6.28 | 5.9 | 394 |
| 100 MHz (best) | Fetch, decode, RR +1, load 3, mul 4 | 6.01 | 5.65 | 565 |
| 100 MHz (likely) | + fetch +1, load 4 | 5.35 | 5.0 | 503 |
| 100 MHz (worst) | + ALU 2 cycles | 4.33 | 4.1 | 407 |

**Why the risk is large**
- **The period must halve.** The whole core is 19.8 ns today, 82 % of it routes. Alone: the full ALU 18.5 ns, the front end 19.1, the LSU with D$ 18.7, the CSR unit 16.5, the issue-queue loop 12.8 (10 entries). Almost no large block is under 10 ns. These are at a 20 ns target, so what Vivado did not squeeze may shorten; 3-wide makes them harder.
- **mmRISC-2's assets are 50 MHz designs.** Its CPU_CORE has only +0.002 ns at 50 MHz. The premise of reusing the caches, MMU, FPU, CSR, L2 goes; they need new pipelines and verification.
- **The loop that decides IPC is at stake.** If "bypass + add + wakeup-select" does not fit in 10 ns and the ALU takes 2 cycles, that alone costs 23 %.
- **Outside examples are not easy either.** NaxRiscv, built for Fmax, gives 5.02 CoreMark/MHz at 155 MHz on the fastest-grade Artix-7 (RV32, about 13k LUTs). Ours is the slowest grade, RV64, about 3 times the size.

**Recommendation**
**Keep 50 MHz as the target.** The CPU's clock is separate from LiteX's (`Doc/BOARD.md` section 4), so raising it later is just the MMCM's setting. Measure Fmax at each step, and once Linux runs, raise it as far as it closes without changing the pipeline. CoreMark/MHz is basically kept (the DRAM latency grows in cycles; that part is measured).

**If what matters is performance per second (CoreMark/s) rather than CoreMark/MHz, that is different.** As the table shows, 100 MHz could reach up to 1.7 times 50 MHz. Then all of step 1's design changes, so it should be decided now.

Recorded in `Doc/STRATEGY.md` 4.2, the model's results in `Plan/model/results/g200t.txt`. The model has a new `lat_alu` option for the ALU's latency. Pushed as 7bcf0b6; prompt 133 is logged in PROMPT.md.
<!-- /answer -->

## 134. 2026-11-02 21:29:10 JST

```text
It is challenging, but I want to design aiming for 4-issues at 100 MHz. Please review the micro-architecture.
```

<!-- answer -->
**Claude Code's answer**

I redesigned the micro-architecture for 4-issue at 100 MHz (pushed as c16b57c). **In the model `-O2` gives 6.90 CoreMark/MHz, in RTL about 6.5 is expected, so about 650 CoreMark/s**, which reaches the goal of 6.0. These numbers are a model and estimates; 10 ns is yet to be measured. The core's RTL function has not changed (only a `FUSED` parameter in the OOC wrapper).

#### The proposed configuration
I read "4-issue" as **4 renamed and 4 issued a cycle**. With rename left at 3, the 100 MHz pipeline stays at 5.85, below the goal.

| Item | Today | Proposal |
|---|---|---|
| Clock | 50 MHz | **100 MHz** |
| Fetch, decode | 16 B, 4 instructions | **32 B, 6 instructions**, with a decoded-instruction queue |
| Rename, dispatch, commit | 2 | **4** |
| Scheduler | Unified 10, 3 issues | **ALU queues 8 × 3, memory queue 12: 4 issues** |
| ALU | 1 full + 1 limited | **3 full** |
| ROB / LQ, SQ / checkpoints | 24 / 8 / 6 | **48 / 16 / 12** |
| Load-use / multiply | 2 / 2 cycles | **3 / 4 cycles** |
| Store | Issued with its data | **Split into address and data** |
| Predictor | TAGE S, uBTB 8 | **TAGE M, uBTB 16** |

The pipeline is about 4 stages longer (stage by stage in `Doc/STRATEGY.md` 4.3). Fusion stays off.

#### The design's thinking
- **Distributed schedulers.** A unified queue of 24 is 1.7 % better, but its wakeup-select loop cannot be expected to fit in 10 ns.
- **mmRISC-2's assets are kept in half-rate islands.** The FPU, division and `mulh`, CSRs, the page-table walker, L2 and debug run at 50 MHz from the same MMCM. Only the L1 hit paths are redone.
- **At the same 100 MHz as LiteX.** The memory bus needs no clock crossing.

#### Size
About 98k LUTs for the chip (73 %). **At 100 MHz the ceiling is taken as 75 %**, so the margin is small; a second LSU port or a fourth ALU only if timing and the ceiling allow. The engine's 59k or so is a rough value with nothing measured yet, more than twice today's 27.0k.

#### The five loops that decide it
| Loop | If it fails |
|---|---|
| Wakeup + select (1 cycle) | **−20 %** (ALU 2 cycles, a redesign) |
| Bypass + ALU (1 cycle) | **−20 %** |
| Load (load-use 3) | −7.9 % at 4, −15 % at 5 |
| Rename of 4 (2 stages) | about −1 % |
| Fetch buffer's boundaries (1 stage) | about −1 % |

The first two are life or death. All measurements so far have a 20 ns target, so the real limit at 10 ns is not known yet.

#### An honest view of the risk
- **The work is close to a new core.** Every stage, block and test changes, and part of the RTL so far remains. Knowledge and the verification environment carry over.
- **If 100 MHz does not close, the clock comes down.** Without changing the pipeline, 90 MHz gives 585 and 75 MHz 488 CoreMark/s (337 for 3-wide at 50 MHz).
- **Measurement decides whether to go on (gate S1-A).** The lower the clock, the less this deep pipeline pays, so going back to 75 MHz, or 50 MHz and 3-wide, is decided there.

#### What I would like next
Before the rework, measure today's blocks on the XC7A200T at a 10 ns target (step 1.0). It needs no RTL change and no board.

```bash
synth_ooo.bat t100
```

Results go to `output/<top>_T10` (20 ns results are not overwritten). The ALU is measured without the fused compare (`FUSED=0`). The bat's new branch has not been run yet, so tell me if an error appears, and ask me to check when it ends. With that result I go on to harnesses of the new loops alone (step 1.1).

Recorded in `Doc/STRATEGY.md` (rewritten), `Doc/UARCH.md` sections 0 and 4.5, `Plan/model/g100.sh`. `Doc/BOARD.md` and the README follow. The model has options for distributed schedulers and 2-cycle ALU operations. Prompt 134 is logged in PROMPT.md.
<!-- /answer -->

## 135. 2026-11-02 22:40:54 JST

```text
synth_ooo.bat t100 has finished.
Yes, "4-issue" is 4 renamed and 4 issued.
```

<!-- answer -->
**Claude Code's answer**

I checked the results of `synth_ooo.bat t100`. **Nothing measured refutes 100 MHz, but nothing proves it either**: what was measured is today's 2-wide blocks, not the new design. "4-issue = 4 renamed + 4 issued" is now recorded as confirmed in the documents.

#### Results (XC7A200T, 10 ns target)

| Block | Loop | Register-to-register slack | Path (at the 20 ns target) | In the new design |
|---|---|---|---|---|
| Full ALU | 2 | **−0.66 ns** | 10.6 ns (18.5) | Rare operations in 2 cycles |
| ALU1's functions only | 2 | +2.34 ns | 7.7 ns | A guide to the room for the above |
| Issue queue (10 entries, 3 ports) | 1 | **−1.95 ns** | 11.8 ns (12.8) | Queues of 8 with one select |
| LSU + D$ | 3 | **−2.66 ns** | 12.6 ns (18.7) | Split into M1 / M2 |
| Rename (2 µops) | 4 | +1.04 ns | 8.6 ns (11.7) | 4 µops in 2 stages (not measured) |
| Fetch buffer | 5 | **−3.31 ns** | 13.3 ns (16.9) | Split the stage |
| uBTB (8 entries) | **6 (new)** | **−2.04 ns** | 11.9 ns (12.9) | 16 entries wanted |
| Whole front end | | **−4.79 ns** | 14.3 ns (19.1) | More stages |
| Decode | | +0.36 ns | 9.0 ns (12.1) | Grows to 6 instructions |
| ROB (2 wide) | | +1.03 ns | 9.0 ns | Grows to 4 wide |

#### What it says
- **The good news:** the 20 ns results were far from the limit. The full ALU above all went from 18.5 ns to 10.6 ns, 0.66 ns short.
- **The biggest worry is the issue queue.** It only went from 12.8 ns to 11.8 ns, with 83 % of the path in routes. If this loop does not fit it costs −20 %, so it is measured first.
- **The uBTB is a new worry.** It is 2 ns short even at 8 entries, half of the proposal's. I added an option to the model that puts a 1-cycle bubble on each taken branch.

| uBTB | Model CoreMark/MHz | Against the proposal (6.901) |
|---|---|---|
| 16 entries, bubble | 6.435 | **−6.8 %** |
| 8 entries, no bubble | 6.660 | −3.5 % |
| 4 entries, no bubble | 6.400 | −7.3 % |

  The bubble's loss is close to that of a load-use of 4 (−7.9 %), so the deciding loops went from five to six.

#### Cautions
- **Alone is not the whole chip.** At 20 ns too, the whole core was about 1 ns slower than its worst block.
- **A tighter target costs area.** The blocks that miss grew 5 to 15 % (uBTB +15 %, fetch buffer +11 %, front end +10 %). The engine's estimate of about 59k (52k to 66k) must absorb that inside the 75 % ceiling.

#### Next
Gate S1-A cannot be judged yet. Next is step 1.1, harnesses of the new loops alone, in this order:

1. The queue of 8 with its wakeups
2. The ALU with the new bypass sources
3. A uBTB of 16
4. M1 / M2 with block RAM
5. Rename of 4 µops
6. The split fetch buffer

When the first harness is ready I will ask you for a Vivado run again.

Recorded in `Plan/OOC.md` 28.1 and `Doc/STRATEGY.md` 4.3, 4.5, 5, 7 (both with Japanese versions). The model's results are in `Plan/model/results/g100.txt`. Pushed as bcb313d; I confirmed Ref is not on the remote.
<!-- /answer -->

## 136. 2026-11-02 22:53:27 JST

```text
I want to keep the 100 MHz target and CoreMark/MHz as far as possible.
Please build the queue-of-8 harness.
```

<!-- answer -->
**Claude Code's answer**

I built the queue-of-8 harness `OOC_SCHED` and pushed it (b711731, a383236). **The model gives 6.870 CoreMark/MHz, within −0.4 % of the proposal's 6.901.** Timing and size are still expectations until the Vivado run.

#### The method
Rather than shrink today's issue queue's worst path (11 levels) to 8 entries, I took the tags out of the loop with a **dependency matrix**. I wrote `OOO_SCHED`, the first step of the RTL for the new core (ALU queues 8 entries × 3, memory queue 12). A wakeup crosses queues, so the 4 are measured together.

| | Today's `OOO_IQ` | `OOO_SCHED` |
|---|---|---|
| Selects in the loop | 2, chained | 1 |
| Wakeup | Tag compared with every source | One column of wait bits cleared |
| Tag compare | Every cycle, in the loop | Once, at dispatch |
| Read at the grant | Sources, destination, mask | Nothing (a cycle later, from a register) |
| Levels | 11 | **6 to 8 (expected)** |

So as not to assume what the matrix buys, a tag-compare version with the same cycles (`MATRIX=0`) is measured with it.

#### The effect on CoreMark/MHz
What building it requires went into the model (`-O2`).

| Condition | Result |
|---|---|
| A µop of latency 2 or more keeps its entry until its column clears | 6.908 (no loss) |
| 2 writes a queue | 6.895 (6.816 with 1, so 2 is taken) |
| **All, with the real steering (by how full the queues were in the last cycle)** | **6.870 / 7.378 / 6.644 (`-O2` / most optimization / g13)** |

With RTL at about 0.94 of the model as usual, that is about 6.46, above the gate's 6.3. Queues of 10 give only +0.3 %, so 8 stays.

#### Verification
- **Tests:** both versions against an independent reference for 400,000 cycles, no mismatch. About 330,000 back-to-back issues, 77 % across queues. The cycles of the two versions are identical.
- **Bug injection:** all 60 detected (M382 to M443). Three things were found and fixed on the way:
  - A branch of the age matrix that cannot happen (removed)
  - Fields the test bench never varied (stimulus added)
  - `mutate.py` counting a mutation that does not compile as "detected" (now shown as NOT APPLIED)

#### Request
Please run this on the Windows side:

```bash
synth_ooo.bat sched
```

Results go to `output/OOC_SCHED_T10_MATRIX1` and `_MATRIX0`. It is a new harness, not yet through Vivado once, so tell me if an error appears.

The worst path may be dispatch (`disp`) rather than the loop itself: steering, the choice of a free entry, dependences in a group and the write all fall in one stage. Then dispatch can take a stage (6.842 in the model, −0.4 %).

#### A point to confirm
The existing 346 + 91 mutations may also include some where a build failure was counted as detected. If needed I rerun them all to check.

Recorded in `Plan/OOC.md` 28.2 and `Doc/STRATEGY.md` (both with Japanese versions), the RTL in `OOO_SCHED.sv`. The core is still `OOO_IQ`; the existing core's behaviour is unchanged.
<!-- /answer -->

## 137. 2026-11-03 00:12:05 JST

```text
Yes, recheck
```

<!-- answer -->
**Claude Code's answer**

The result of the recheck: **no mutation that failed to build had been counted as detected.** The `synth_ooo.bat sched` results that had arrived, however, are hard: the worst path is dispatch, and the size is about twice my estimate.

#### The recheck of the bug injections
- **Unit (`mutate.py`):** with failed builds excluded, the whole list was run again: all 406 detected, no failed build, none not applied. The older 346 were all real detections.
- **Core (`mutate_core.py`):** it already counts a failed build apart as `BUILD FAILED`, so it has no such problem and was not rerun. Its existing result is 91 of 91 detected.

#### The first results of `OOC_SCHED` (target 10 ns)

| Version | LUTs | Register-to-register slack | Levels | Worst path |
|---|---|---|---|---|
| Dependency matrix | **7,969** | **−10.34 ns** | 24 | 20.3 ns (route 83 %), `oc` → `rv` |
| Tag compare | 9,186 | −8.06 ns | 18 | 18.0 ns (route 85 %), `oc` → `rv` |

- **The worst path is dispatch.** All ten worst paths of the matrix begin at `oc` (an entry's occupied bit). The free-count test, the sequential decision over 4 slots, the choice of entry, dependences within a group and the write all fall in one stage, and that does not fit.
- **The wakeup-select loop's own slack is still unknown.** The class report after place and route stopped on an error in my Tcl (a list of more than 500 cells, and cell names that did not match).
- **The size estimate was wrong too.** I estimated 3.5k to 4.5k without the payload; the measurement is 7,969 LUTs, above the budget of 6.5k with the payload. I most underrated the tag compare at dispatch and the muxes from slots to ports.

#### Next
Whatever the loop gives, dispatch is to be redesigned:

1. Steering and the choice of entries in a stage of their own, without the sequential decision per slot (one more stage costs −0.4 % in the model).
2. The producer's entry from a table by tag rather than a compare against 36 entries.

Which of matrix and tags to keep I would rather decide with the loop's slack in view. The corrected Tcl only reads the finished runs' checkpoints, with no new place and route.

```bash
synth_ooo.bat schedrpt
```

Results go to `summary_loop.txt` in `output/OOC_SCHED_T10_MATRIX1` and `_MATRIX0`. This branch of the bat has not been run yet either, so tell me if an error appears.

Recorded in `Plan/OOC.md` 28.3 (with a Japanese version), pushed as 7b71d06. Ref is not on the remote.
<!-- /answer -->

## 138. 2026-11-03 01:02:25 JST

```text
Schedrpt finished
```

<!-- answer -->
**Claude Code's answer**

I checked the results per class. **The dependency matrix's loop came down to 7 levels, so the matrix stays.** Whether it fits in 10 ns is not proven yet, however: with dispatch as the worst path the loop cannot be measured properly.

#### Results per class (slack in ns, levels)

| Class | Dependency matrix | Tag compare |
|---|---|---|
| **`loop`**: request → grant → request | **−2.43, 7 levels** | **−4.90, 18 levels** |
| `wake`: request → wait cell / ready bit | −0.93, 4 levels | −4.28, 15 levels |
| `free`: occupied bits → the block | −10.34, 24 levels | −8.06, 18 levels |
| `steer`: the queue order → the block | −8.75, 22 levels | −7.27, 17 levels |
| `disp`: the slots' registers → the block | −8.61, 22 levels | −7.25, 17 levels |
| `kill`: kill and clr → the block | −1.13, 6 levels | −1.18, 8 levels |
| `issue`: the grants' registers → out | +2.32, 4 levels | +3.31, 4 levels |

#### What it says
- **The levels are as expected.** Today's `OOO_IQ` has 11, tag compare at this size 18, the matrix 7. The tag version's 18 include the dispatch snoop, but in logic delay alone the matrix has 1.39 ns against 2.69 ns.
- **I take −2.43 ns not to be the loop's limit.** Of the 12.37 ns path, 10.99 ns is route, 5.25 ns of it one net, a column's clear (fan-out 38). With dispatch 8 ns worse, Vivado does not get round to improving the loop, I think. That is a guess, to be confirmed by measuring after dispatch is fixed.
- **Dispatch misses by more than 8 ns from all three of its starting points.** Steering and the write do not fit in one stage, and I take this to be the main cause of the size too (7,969 LUTs), though with one module the breakdown is not available yet.

#### Next (redesigning dispatch)
1. **Split it.** Steering and the choice of entries in a stage of their own, deciding from registered free information without a sequential decision per slot. The model's loss is −0.4 % for one more stage (6.842).
2. **Fewer tag compares.** Replace the compare against 36 entries (8 sources' worth) with a table by tag or the like, deciding by comparing areas.
3. **Dispatch as a module of its own**, so that the report per block shows what dispatch and the matrix each cost.

Then a further `synth_ooo.bat sched` will show whether the loop fits in 10 ns and the size in the budget of 6.5k.

Recorded in `Plan/OOC.md` 28.3 (with a Japanese version), pushed as 2c6bc0e.
<!-- /answer -->

## 139. 2026-11-03 01:15:31 JST

```text
Yes, redesign dispatch
```

<!-- answer -->
**Claude Code's answer**

Dispatch is redesigned and pushed (3087363). **The model gives 6.829 CoreMark/MHz, −1.0 % against the proposal's 6.901.** It is −0.6 % against the last 6.870, but at the usual 0.94 of the model the RTL would give about 6.42, above gate S1-B's 6.3. Timing and size are to be confirmed by the next Vivado run.

#### What changed
Dispatch is now a module of its own, `OOO_SDISP`, so that the size can be read per block.

| What was in one stage | Now |
|---|---|
| Occupied bits → free entries → go | The first free entry of each bank, chosen the cycle before, **in registers** |
| Slots' decisions in sequence | A slot's bank does not depend on whether older slots go |
| A mux of 4 slots at each entry | **A queue is 2 banks (even and odd entries), one write each**: no mux at the entry |
| Tag compare through to `rv` in one stage | **S1:** up to the tag compare, then a register. **S2:** port select, wait cell, row, `rv` |

#### CoreMark/MHz (model)
| Step | `-O2` / most optimization / g13 |
|---|---|
| The last version | 6.870 / 7.378 / 6.644 |
| Banks | 6.866 / 7.386 / 6.645 (no loss) |
| **As built** (a freed entry reused a cycle later, the queue order from 2 cycles before) | **6.829 / 7.320 / 6.604** |
| For reference: reuse 2 cycles later | 6.789 (why the grant stays in the free-entry path) |
| For reference: queues of 10 | 6.862 (+0.5 % for 1.36 times the wait cells: not taken) |

#### What changed from the last proposal
- **The table by tag is dropped.** Worked out, with a way to tell stale entries it costs about what the tag compare does (288 compares), and it would bind the free list to banks.
- **The tag-compare version is out of the RTL.** Its results stay in `output/OOC_SCHED_T10_MATRIX0`.

#### Assumptions and what is not verified
- **No stage is added, by assumption.** S1 runs alongside renaming's R2 and S2 is the existing DS. Whether rename of 4 can share go is for loop 4's harness; if not, a stage more gives 6.801.
- **The size estimate is about 5k LUTs.** The last estimate was off by 2, so a direction only.

#### Verification
- **Tests:** steering, banks and free entries against the reference model, 3 seeds, no mismatch.
- **Bug injection:** 93, all detected (M382 to M477, replacing the last list). The first round found 3 redundant conditions (removed), a flush with slots valid that the bench never drove (added) and 1 mutation that did not compile (fixed).

#### Request
Please run this on the Windows side; the results go to `output/OOC_SCHED_T10`.

`synth_ooo.bat sched`

What to read: 1) whether `loop` fits in 10 ns (its real value, out of dispatch's shadow); 2) the classes `s1`, `s2`, `ff`; 3) `u_disp` and the total LUTs (budget 6.5k with the payload).

Recorded in `Plan/OOC.md` 28.4 (with a Japanese version); the RTL is `OOO_SDISP.sv` and `OOO_SCHED.sv`. The core still uses `OOO_IQ`.
<!-- /answer -->

## 140. 2026-11-03 13:28:04 JST

```text
Sched finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_SCHED` meets 10 ns: register to register +0.056 ns, 5,353 LUTs.** A great improvement on the last −10.3 ns and 7,969 LUTs, and loop 1 is within reach of gate S1-A. But this is the block alone, without the payload or a core around it. Recorded and pushed (4a2c9ab).

| | First run | This run |
|---|---|---|
| Physical LUTs | 7,969 | **5,353** (−33 %; my estimate was about 5k) |
| Register to register | −10.336 ns, 24 levels | **+0.056 ns, 9 levels** |
| `loop` (request → grant → request) | −2.429, 7 levels | +0.208, 9 levels |
| `wake` (request → wait cell) | −0.927, 4 levels | +2.036, 5 levels |
| `s1` (the slots' registers → the block) | −8.612, 22 levels | +0.233, 9 levels |
| `ff` (free entries, queue order → the block) | −8.752, 22 levels (then `steer`) | +0.329, 9 levels |
| `s2` (S2's registers → the block) | not separate | +1.032, 7 levels |
| `free` (a request → the first free entries) | defined differently, no comparison | +1.909, 9 levels |
| `kill` (kill, clr → the block) | −1.126, 6 levels | +2.747, 4 levels |
| `issue` (the grants' registers → out) | +2.321, 4 levels | +4.504, 4 levels |

As guessed last time, the problem was dispatch. The dependency matrix stays.

#### Two corrections
- **`u_disp`'s figure is not the size of dispatch.** I said last time that this would show it apart, but its 4,825 LUTs include the matrix's logic: the wait cells alone need 1,296 LUTs and the rest of `u_sched` has only 531. Synthesis rebuilds the hierarchy, so only the total means anything. No decision depends on the breakdown now, so I do not ask for a run to separate it.
- **The worst path was in none of the classes I had defined.** It runs from the non-speculative flag `nsf` through the request and grant back to `rv`. `report_sched.tcl` now has a class `guard` (from the next run).

#### What is not confirmed
- **The real margin is still unknown.** Vivado stopped improving once the target was met. 84 % of the worst path is route, with only 1.57 ns of logic. The core needs this margin to keep 10 ns.
- **The payload is not in.** About 1.1k LUTs remain of the budget of 6.5k. With one writer per bank it should be possible as LUT RAM, but it is not designed yet.
- **Whether go can be shared with rename of 4 is not confirmed.** `s1` is at +0.233 ns now, and what rename adds before go comes out of it. A stage more takes the model from 6.829 to 6.801.
- **The other 5 loops are not measured with their new design.**

#### Request
To measure the margin I added a run asking for 8.5 ns. Please run it on the Windows side; the results go to `output/OOC_SCHED_T8.5`.

`synth_ooo.bat sched85`

What to read: how near it gets to 8.5 ns, and the slacks of `guard` and `loop`.

Loop 2 (bypass + ALU) can proceed alongside this run. I will not edit `synth_ooo.bat` while it runs.

Recorded in `Plan/OOC.md` 28.5 (Japanese in `Plan/OOC_J.md`); `Doc/STRATEGY.md` 4.5 and 5 updated.
<!-- /answer -->

## 141. 2026-11-03 13:58:24 JST

```text
Yes, loop 2
```

<!-- answer -->
**Claude Code's answer**

Loop 2 (bypass + ALU) is built in the new design and pushed (250f9f7). **The model is 6.823 CoreMark/MHz, −0.1 % from 6.829 after the dispatch redesign.** The tests pass and all 78 injected bugs are detected. Timing and size are unmeasured; the next Vivado run will tell.

#### The result of `sched85` (the run you did first)
`OOC_SCHED` against 8.5 ns: **WNS −0.776 ns, so about 9.3 ns**, about 0.7 ns in hand. At the 50 MHz (20 ns) target the core ran about 1 ns slower than its worst block, so this is not comfortable. The paths are close together (`loop` −0.776, `ff` −0.742, `guard` −0.702, `s1` −0.633), so no single fix settles it; reread at step 1.6.

#### Which operations stay in 1 cycle
With a class per operation in the trace, what CoreMark uses is narrow. This replaces the assumed "rare operations". Taking counts, `rev8`, `orc.b`, rotates, min / max, `bset` / `bclr` / `binv`, `bext`, shifts by a register to 2 cycles on queue 0, and `jalr` to queue 0, gives 6.823 / 7.315 / 6.599 (rv64gc 5.898); the −0.1 % is all from `jalr`. `slli` stays as the first lever if timing is short: no loss in CoreMark with Zb, but −5.7 % on rv64gc, Debian's default. These are CoreMark's numbers; other programs will see the 2-cycle operations.

#### What was built
`OOO_ALUF` (shifts by an immediate only, left by the same funnel), `OOO_EXU` (pc and immediates into the operand register in RR2, EX's mux of 5, decoded controls, 3 registers per result, `OOO_ALU` for the 2-cycle operations), `OOO_PRF2` (LVT in RR1, banks in RR2), and the harness `OOC_EXU`, which includes the 80 × 64 register file with 4 writes and 8 reads.

#### Verification
`tb_exu`: 1.5 million cycles through each of the 3 source paths; it found a real bug in the first version (a µop flushed in RR2 left its result to be ORed onto port 0), fixed. `tb_prf2`: no mismatch. Bug injection M478 to M556: 78 of 78 detected; one that did not build was fixed and detected, one equivalent was removed.

#### Not verified
Not yet through Vivado. No size estimate given; the register file should be the largest part. The harness leaves out the SQ, what is behind the multiplier and MDU, M2's delay before `ld_d`, and branch masks.

#### Request
Please run `synth_ooo.bat exu`; results in `output/OOC_EXU_T10`. Read `loop` first, then `sel`, `ctl`, `oper`, then `rf`, `lvt`, `tags`, `snoop`, `write`, and the total LUTs.
<!-- /answer -->

## 142. 2026-11-03 15:49:27 JST

```text
exu has finished.
```

<!-- answer -->
**Claude Code's answer**

**`OOC_EXU`'s first result is WNS −0.356 ns at 10 ns (about 10.4 ns), 15,731 LUTs.** The main cause of the delay was the levels behind the adder, so I rebuilt the RTL without changing the model and pushed it (9f96fdb, dd47a12). Timing and size of the rebuilt RTL are not measured yet.

#### Result
`loop` −0.356 (14 levels, port 1 to port 0, through `addw`'s sign extension); `rare` −0.338 (9 levels, through `OOO_ALU`, 8.65 ns of routes); `sel` −0.188; `oper` −0.037; `write` +0.035 (fan-out 654, 9.4 ns of route alone); `tags` +0.438; `lvt`, `ctl`, `rf`, `flag`, `snoop` +1.057, +1.288, +1.374, +1.518, +2.772.

Size: `OOO_EXU` 7,703, `OOO_PRF2` 8,027; 1.1k over the 14.6k of `Doc/UARCH.md`, all of it the register file. Of the worst path's 10.2 ns, 4.3 ns are after `sum[31]`. A 64-bit add is not the limit: the whole carry chain still has +2.05 ns to the flags.

#### Changes (the model stays 6.823)
1. The ALU's last level is one LUT per bit: 1 LUT from the sum to the register, 2 for a word's sign (was 4).
2. Port 0's other results go in earlier, inside the ALU, so its extra LUT after the ALU is gone.
3. Tag and valid are kept apart for comparisons and for the write.
4. The register file's banks are 64 + 16, not one memory of 80: LUT RAM expected from 5,504 to about 4,160.

`rare` itself unchanged; if the next run shows it is real, a longer latency on queue 0 is the cheap answer, at no cost in CoreMark but seen by other programs. Not done.

#### Verification
Benches `tb_exu`, `tb_prf2`, `tb_alu2` PASS. `-Wall` clean on the changed modules and harness lines. Bug injection M478 to M571: 92 of 92 detected.

**Correction:** commit 9f96fdb's record said "all 93 detected", which was wrong: M524 came back undetected and the same command had already pushed before I read it. M524 (`rv` not cleared by a flush) is equivalent in today's structure, since `rv` only gates comparisons and no µop reads a flushed tag. It was removed and the record corrected in dd47a12. The write's clear is M570, detected.

#### Request
Please run `synth_ooo.bat exu9`; results in `output/OOC_EXU_T9`. 9 ns because at 10 ns improvement stops once met, and the core adds about 1 ns; the target, as for the scheduler, is about 9.3 ns. Read `loop`, `rare`, `tags`, `write` and the total LUTs.
<!-- /answer -->

## 143. 2026-11-03 16:11:33 JST

```text
exu9 has finished.
```

<!-- answer -->
**Claude Code's answer**

`OOC_EXU` at 9 ns reached **WNS −1.674 ns (about 10.7 ns), 13,207 LUTs**: still 1.4 ns from the target of about 9.3 ns. I rebuilt the 3 slowest parts and pushed them (5275859). Timing and size of the rebuilt RTL are not measured yet.

#### Result
`rare` −1.674 (min / max compare, then a select of fan-out 64); `sel` −1.285 and `loop` −1.120 (`sraiw`'s sign through the funnel, then a fan-out of 96); `oper` −1.122; `write` −0.896 (write address, no logic, 9.2 ns of route); `tags` −0.207; `ctl` +0.117; `flag` +0.324.

`rare` was real; the 64-bit add reaches the flags at 8.7 ns, so the shifter is what is long, not the adder. LUT RAM came out at exactly 4,160, `OOO_PRF2` from 8,027 to 5,661, together with `OOO_EXU` 1.4k under `Doc/UARCH.md`'s 14.6k.

#### Changes
1. The shifter is a rotation and a mask, with the fill not going through the rotation. No change in the model.
2. `slt`: from 3 LUTs after the carry out to 1.
3. New `OOO_ALUR` for the slow operations in 2 stages, **latency 3 instead of 2**. Queue 0 gets a latency-3 field in `OOO_SCHED`.
4. Each read port has its own write address, 9 sets with the LVT's, 288 FF more.

#### A point for you to decide
Latency 3 costs nothing in CoreMark (6.823 / 7.315 / 6.599, rv64gc 5.898), as those operations do not run there. **In other programs shifts by a register and so on take 3 cycles**, and the model cannot say how much that matters. I put it in following the priority on 100 MHz and CoreMark; it can be revisited when Linux runs.

#### Verification
`tb_exu`, `tb_prf2`, `tb_sched` PASS. `-Wall` clean. Bug injection: all of `OOO_SCHED`'s and M478 to M609, 185 of 185 detected, every line read. One bench gap fixed: M530 (a flushed `jalr` leaves its link) was only ever detected by chance; the RTL was right.

#### Request
Please run `synth_ooo.bat exu9` and then `synth_ooo.bat sched85`, since `OOO_SCHED` changed too. If `loop` is still short the next lever is Zba's change of `a`; `slli` out of EX is now worth less.
<!-- /answer -->

## 144. 2026-11-03 17:38:39 JST

```text
exu9 and sched85 have finished.
```

<!-- answer -->
**Claude Code's answer**

**Loop 2 (bypass + ALU) meets its target.** `OOC_EXU` at 9 ns: WNS −0.163 ns (about 9.2 ns), 12,472 LUTs, model still 6.823. `OOC_SCHED`, on the other hand, went from about 9.3 ns to about 9.9 ns after a change of 8 FF. I read most of that as placement noise but cannot prove it yet, so I asked for 2 more runs.

#### `OOC_EXU` (1.5 ns better than the 10.7 ns before)
`sel` −0.163, `loop` −0.156 (15 levels: selection, `a`, Zba's LUT, carry, `slt`, bit 0); `oper` +0.023; `write` +0.375 (now the data, not the address); `tags` +0.814; `flag` +0.906; `rare1` +0.962; `rare` +1.177; `lvt`, `ctl`, `rf`, `snoop` +0.989, +1.177, +1.937, +2.264.

None of the prepared levers was needed: `slli`, Zba, `srli` stay in 1 cycle. `OOO_EXU` 5,971 (of which `OOO_ALUR` 1,178), `OOO_PRF2` 6,500, 2.1k under the 14.6k estimate, though the harness has no multiplier or resolution. Still one block alone: the core will make it slower.

#### `OOC_SCHED`
`s1` −1.400, `ff` −1.310, `guard` −1.239, `loop` −0.997, `free` +1.440 (was −0.223); 5,868 LUTs (was 5,397). The worst paths end in the memory queue, which the change does not touch, and `free` improved with nothing done for it. If that is noise, the 9.3 was one sample too.

#### Change
`wa` removed from `rv`'s inputs: `!wa` is redundant, as a free entry has no `v`. A temporary check never fired, `tb_sched`'s output is byte for byte the same, all 95 mutations of the scheduler are detected.

#### Request
`synth_ooo.bat sched85` and `sched86`, same RTL. Both about 9.3: latency 3 stays. Both near 9.9: latency 4 on queue 0. Far apart: the spread itself is the answer, and the gate needs several runs.
<!-- /answer -->

## 145. 2026-11-03 18:57:07 JST

```text
Done.
```

<!-- answer -->
**Claude Code's answer**

**`OOC_SCHED` reached 9.31 ns and 9.57 ns on 2 placements of one netlist. Latency 3 stays.** Loops 1 and 2, the life-or-death ones, both reach 10 ns as blocks alone. The model stays 6.823 (27ad7ba).

Classes at 8.5 / 8.6 ns: `s1` −0.810 / −0.973, `ff` −0.589 / −0.745, `guard` −0.272 / −0.572, `loop` −0.179 / −0.504, `kill` +0.120 / −0.056, `s2` +0.530 / −0.058; 5,692 / 5,716 LUTs.

#### What it says
- The spread of placement alone is 0.26 ns: synthesis gave the same netlist in both. Differences under about 0.3 ns between single runs mean nothing.
- The `rv` change did what it was for: `loop` is at 8.7 and 9.1 ns; the worst endpoints moved to `aq`, `ff`, `oc`, written by dispatch's first phase.
- Latency 3 costs under 0.3 ns if anything.

**Correction:** I said most of the 9.9 ns was placement noise. That is not borne out: 0.26 ns does not explain 0.6 ns. The rest is either the change or a worse netlist from synthesis; with `rv` changed in the same step they cannot be separated.

#### Where it stands
Scheduler 9.3 to 9.6 ns, EX 9.2 ns (one placement): 0.4 to 0.8 ns in hand, and the core added about 1 ns at 20 ns. Within reach for gate S1-A, not comfortable for the chip; read again at step 1.6. The scheduler's limit is dispatch's first phase, which shares its cycle with rename of 4, so loop 4 decides how far to take it. Noted, not taken: the age bits `aq` can update from `w2` a cycle later, but `ff`, `oc` are about 0.03 ns behind, so a run could not show it.

#### Next
Loop 6, the uBTB of 16: −6.8 % in the model if it fails; today's is −2.04 ns at 8 entries.
<!-- /answer -->

## 146. 2026-11-03 19:00:28 JST

```text
Yes, uBTB
```

<!-- answer -->
**Claude Code's answer**

I built loop 6's uBTB as a new design, `OOO_UBTB2`, and pushed it (338ad20). **Not 16 entries but 3 ways of 32 sets in LUT RAM (96 entries). If the timing holds, the model goes from 6.823 to 6.889 (+1.0 %).** Timing and size are not measured yet.

#### What the model says
The model's uBTB was ideal: all in one set, LRU. I measured again with sets and round robin, as a real design has them.

| uBTB | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| 16, one set, LRU (the proposal so far) | 6.823 | 7.315 | 6.599 | 5.898 |
| 16, one set, round robin | 6.794 | 7.326 | 6.589 | 5.896 |
| 16, 4 sets of 4 | 6.797 | 7.312 | 6.531 | 5.890 |
| 48, 16 sets of 3 | 6.879 | 7.414 | 6.618 | 5.910 |
| **96, 32 sets of 3** | **6.889** | **7.416** | **6.650** | **5.917** |
| 128, 32 sets of 4 | 6.905 | 7.422 | 6.654 | 5.921 |
| 2,048, LRU (for scale) | 6.915 | 7.427 | 6.667 | 5.928 |

- **Reading:** sets cost almost nothing, and capacity is worth more than associativity. In LUT RAM a depth of 32 costs the same as 16, hence 3 ways of 32 sets.
- **Optimism in the figures:** the model has exact tags and immediate training. The real ones will be lower.

#### The design
Today's 8 entries take 12 levels and 11.9 ns: all tags compared, parcel priority, the entry's choice, the AND-OR of all targets in series, each growing with the entries.

- **Only 3 compares:** distributed RAM is read by set, so 3 tag compares instead of 16, and the target's AND-OR has 3 inputs.
- **Order in the block:** 3 bits per set say which way comes first, computed at the write. No parcel compares or priority in the path; `sel` is one LUT.
- **Tag:** no longer folded, removing the first LUT of today's path.
- **Predicted taken:** one bit in the RAM, computed when the counter changes.
- **Next address:** redirect, stall, the stack's top and the sequential address are handled before the last LUT; only the target's way is late.
- **Reset:** none for the table, only its initial state. A stale entry is a misprediction checked at F2.

Counted, 7 to 8 levels are expected. The size is unknown until the run: about 180 LUTs of RAM by counting, plus logic; today's 8 entries are 567 LUTs, 505 FF.

#### Verification
- **Bench `tb_ubtb2`:** 800,000 cycles against a reference table of 3 ways, 32 sets, no mismatch: 510,000 predicted taken, 55,000 returns, 220,000 multiple hits, 240,000 fills, with tag aliases mixed in.
- **Bug injection:** M610 to M645, all 36 detected. Every line was checked before the commit.
- **Lint:** `-Wall` has no warnings on the block's and the harness's lines.
- **Model table:** no earlier row changed.

#### Not confirmed
**This run measures the loop alone, not joining it to the core.** `OOO_UBTB2` assumes `redirect`, `redirect_pc`, `stall`, `ras_top` come from registers.

The harness does that, but today's `OOO_FETCH` drives them from logic (`be_redirect || ovr`, `!acc`). A registered `stall` is a cycle late, so it may cost. I will design it with step 1.4's 32-byte fetch.

#### Request
Please run the following on Windows. It asks for 9 ns for the same reason as loop 2. The results go to `output/OOC_UBTB2_T9`.

```bash
synth_ooo.bat ubtb
```

To read: `idx` (the main path from the index through the RAM), `tag`, `in`, `out`, `upd`, and the total LUTs. If short, the levers in order: 16 sets (same size, −0.1 %), a shorter tag, fan-outs.

The record is section 28.11 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`). `Doc/STRATEGY.md` 4.2, 4.5, 5 (and Japanese) are updated too. The RTL is `OOO_UBTB2.sv`.
<!-- /answer -->

## 147. 2026-11-03 20:17:40 JST

```text
ubtb has finished. Please check it.
```

<!-- answer -->
**Claude Code's answer**

**`OOC_UBTB2` meets 9 ns (WNS +0.124 ns, about 8.9 ns reached). 96 entries stay, and none of the levers is used.** For this block alone, the model's 6.889 / 7.416 / 6.650 / 5.917 stands. The record is pushed (7076ffb), with 0 `Ref/` files on the remote.

#### Against today's uBTB
Twelve times the entries, and smaller and faster than today's 8.

| | `OOO_UBTB`, 8 entries (10 ns asked) | `OOO_UBTB2`, 96 entries (9 ns asked) |
|---|---|---|
| Slack | −2.037 ns | **+0.124 ns** |
| Levels of the worst path | 12 | 8 |
| LUTs after routing | 567 | **378** (190 logic + 188 LUT RAM) |
| FF | 506 | 53 (and 184 of the harness) |

#### By path

| Class | Slack | Reached | Levels |
|---|---|---|---|
| `upd` (the update) | +0.124 | 8.88 ns | 8 |
| **`idx` (the loop)** | **+0.361** | **8.64 ns** | 8 |
| `tag` | +1.278 | 7.72 ns | 7 |
| `out` | +1.897 | 7.10 ns | 7 |
| `in` (from a redirect) | +4.231 | 4.77 ns | 1 |

#### What it says
- **As estimated:** 8 levels against 7 to 8 expected, 188 LUTs of RAM against about 180.
- **8.88 ns is not the limit:** Vivado stops improving once the target is met, so it could be faster. It is within the block's 9.3 ns even with the placement spread of 0.26 ns, so no rerun at a tighter period is needed.
- **The worst path is the update, not the loop:** `s_up`'s index with a fan-out of 313, through the compare into the set's order bits. If it ever matters the update can take 2 cycles, at the cost of training a cycle later. Not needed now.
- **The loop is as designed:** `pi_q` → RAM → compare → `hit` → `sel` → target → last LUT, nothing else in it.

#### The earlier worry, updated
The joining may be easier than I feared. `in` has 4.2 ns to spare at 9 ns, so some logic could stand in front of `redirect` and `stall`.

- **Probably fine:** `be_redirect` and `acc`.
- **To watch:** `ovr`, the compare at F2.
- **Not measured:** this run had no logic there, so this is an estimate. Step 1.4 measures it.

#### Where it stands (all blocks alone)

| Loop | Block | Reached |
|---|---|---|
| 1 | `OOC_SCHED` | 9.3 and 9.6 ns (`loop` 8.7 and 9.1) |
| 2 | `OOC_EXU` | 9.2 ns |
| 6 | `OOC_UBTB2` | 8.9 ns (`idx` 8.6) |

The core added about 1 ns at 20 ns, so all 3 are within reach of 10 ns, though loop 1's margin remains small.

Left in step 1.1: M1 / M2 with block RAM (loop 3), rename of 4 (loop 4), the fetch buffer split (loop 5). I recommend loop 3 next, in order: failing it means a load-use of 4 or 5, −7.9 % to −15 %, the largest loss among those left.

The record is section 28.12 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`); `Doc/STRATEGY.md` 4.2, 4.5, 5 (Japanese `Doc/STRATEGY_J.md`) are updated too.
<!-- /answer -->

## 148. 2026-11-03 20:58:33 JST

```text
Yes, loop 3
```

<!-- answer -->
**Claude Code's answer**

I built loop 3 as a new design, `OOO_LSU2`, and pushed it (df5dae9). Timing is not measured yet. **While building it I found the model about 2.4 % optimistic. You need to decide how stores go.**

#### The model's error: what splitting stores assumed
The proposal's split stores (+3.8 %) assumed that a load finding a store without its data just waits for the data.

But `OOO_SCHED` wakes dependents at a fixed time, with no cancel, so that load can only replay at its commit. In CoreMark this happens about once in 270 instructions.

| A store's data | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| Model so far (no replays) | 6.889 | 7.416 | 6.650 | 5.917 |
| The same with replays | **5.767** | 6.199 | 5.614 | 4.984 |
| Not split | 6.320 | 6.903 | 6.129 | 5.568 |
| A µop, replays, no wait table | 5.588 | 6.041 | 5.435 | 4.939 |
| **Proposed: the data a µop on queue 2, a wait table of 64 bits** | **6.726** | **7.234** | **6.484** | **5.797** |

- **What is in it:** the data as a µop costs −1.5 %, the wait table −0.6 %, queue 2 alone −0.2 %.
- **The wait table:** a load that replayed waits for older stores' data from then on. As in the Alpha 21264. Replays go from about 11,000 to 11. 64 bits take one LUT.
- **Against the targets:** RTL about 6.32 at × 0.94. Just over the gate's 6.3, under step 1.2's "model ≥ 6.8".
- **Work left:** stores cracked in 2 µops, `OOO_SDISP` changed. Loop 1 needs another run, and the way from queue 2 to the SQ is to come.

Given the aim of keeping CoreMark/MHz, I recommend this.

#### What I built
RR2, E, M1, M2, M3, load-use 3 cycles, D$ still 16 KB.

- **Alignment in M1:** in each way, before the way is known. M2 is a tag compare and a 5-input AND-OR, 4 ways + SQ.
- **SQ:** searched in M1 by the page offset alone, the physical tag checked in M2. Its data in LUT RAM, 88 LUTs by estimate in place of 1,024 FF.
- **No waiting for the hit:** `ld_nv` goes out whatever the hit.
- **Tries:** through RR2 in free cycles, so no mux in E and no fill path.
- **Drain:** a pipeline of its own on the second copy of the tags, so loads and stores never wait for each other.
- **DTLB:** 32 sets of 2 ways in LUT RAM, 2 compares.

#### Verification
- **Bench `tb_lsu2`:** 600,000 cycles each physical and translated, every load's value against program order, no mismatch.
- **Design faults it found:**
  - A try dropped by a recovery cleared its wait, and the load was lost.
  - Tries by number starved a store.
- **Bug injection:** M650 to M706, all 48 detected, every line read. Those missed along the way were handled by closing a bench gap, removing unneeded logic from the RTL, or dropping those that change only the time.
- **Lint:** `-Wall` clean on the block's and harness's lines.

#### Not confirmed
- **`done_id`:** trying the µop just answered first is not proved. Without it the bench stopped once, but I could not reproduce that on purpose, so it has no mutation. It stays as a guard against a livelock.
- **Not in the harness:**
  - the miss handler (ports only)
  - what is not cacheable, AMO, LR, SC
  - the victim's read
  - PMP with translation off
  - the fan-out of the result registers' other sinks

#### Request
Whatever you decide on stores, please run the following on Windows. The load path is the same either way. Results go to `output/OOC_LSU2_T9`.

```bash
synth_ooo.bat lsu2
```

To read: `e_ram`, `dat`, `cam`, `hit`, `fwd`, then the rest and the total LUTs. Today's `OOC_LSUDC` was −2.66 ns in one stage, 7,989 LUTs with the miss logic.

The record is section 28.13 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`), the model's table `g100.txt`. `Doc/STRATEGY.md` 4.2 (and Japanese) marks stores as awaiting the author.
<!-- /answer -->

## 149. 2026-11-03 22:17:57 JST

```text
tsu2 [lsu2] has finished. I accept the store proposal.
```

<!-- answer -->
**Claude Code's answer**

**`OOC_LSU2` meets 9 ns (WNS +0.898 ns, about 8.1 ns reached), the widest margin of the loops so far.** The store proposal is recorded and in the scheduler, pushed (a59f9fc). The scheduler's timing has to be measured again.

#### Loop 3 (I read "`tsu2`" as `lsu2`)

| Class | Slack | Reached | Levels |
|---|---|---|---|
| **The tags to the result** | **+0.898** | **8.10 ns** | 7 |
| `hit` (the physical tag to the result) | +1.344 | 7.66 ns | 7 |
| `cam` (the search of the SQ) | +1.363 | 7.64 ns | 6 |
| `fwd` (the SQ's data to the result) | +1.513 | 7.49 ns | 5 |
| `drain` | +1.673 | 7.33 ns | 6 |
| `tlb` | +2.094 | 6.91 ns | 5 |
| `e_ram` (EX's mux, the adder, the arrays' address) | +2.124 | 6.88 ns | 5 |
| `dat` (the data to a way's alignment) | +2.513 | 6.49 ns | 3 |

- **Size:** 2,053 LUTs (with 248 LUT RAM), 1,335 FF (and 1,346 of the harness), 4 RAMB36 and 8 RAMB18.
- **Against today's:** `OOC_LSUDC` is −2.657 ns at 10 ns, 7,989 LUTs, but with the miss logic (5,460 LUTs in `DCACHE`), so the sizes do not compare directly.
- **Levels:** about as counted.
- **No rerun needed:** 8.1 ns is a ceiling, well inside the 9.3 ns aimed at.
- **The `tag` report:** it said "no cells", as Vivado moved `m2_t` into the block RAM's output register. Same cycles. `report_lsu2.tcl` is corrected.
- **Not in yet:** the miss handler, what is not cacheable, the other sinks of EX's mux and `ld_d`, `sd_data` straight from EX's mux. What they cost is not known.

#### The stores decision
Reflected in `Doc/STRATEGY.md`. The model is 6.726 / 7.234 / 6.484 / 5.797, RTL about 6.32, 632 CoreMark/s.

**Two points bear on the targets.**
- **Gate S1-B (RTL ≥ 6.3):** only 0.02 in hand.
- **Step 1.2 (model ≥ 6.8):** no longer met. I did not change the figure, only noted 6.73. Changing it is the author's call.

#### The scheduler's change
`OOO_SCHED` and `OOO_SDISP` have a kind for queue 2 alone (`disp_kind` 3), the data µop's mark (`disp_sd`), and marked loads (`disp_wl`). The row's cells exist already, so the loop itself does not grow.

But the new terms are in dispatch's S1, the limit of `OOC_SCHED`, so it has to be measured again.

- **Bench `tb_sched`:** 443,860 issued, 28,355 data µops, a marked load held by one 20,545 times, no mismatch.
- **Bug injection:** all 102 of `OOO_SCHED` and `OOO_SDISP` detected, every line read. M710 to M716 are new; M445, whose text changed, was fixed and run again.
- **Lint:** `-Wall` clean on blocks and harness.

The crack into 2 µops at decode, the wait table itself and the way from queue 2 to the SQ are not built yet; they come with steps 1.3 and 1.4.

#### Request
Please run the following on Windows. The results overwrite `output/OOC_SCHED_T8.5`; the last ones stay in git.

```bash
synth_ooo.bat sched85
```

To compare with the last 9.31 ns (`loop` 8.7 ns); up to 0.26 ns is placement's spread. If that holds, next is loop 4 (rename of 4), which the store's 2 µops bear on too.

The record is section 28.14 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 150. 2026-11-03 23:00:59 JST

```text
sched85 has finished.
```

<!-- answer -->
**Claude Code's answer**

**With the data µop in, `OOC_SCHED`'s timing is no worse (WNS −0.563 ns, about 9.06 ns reached).** The store proposal holds in loop 1 too, and the model's 6.726 is the value of the design as it stands. The record is pushed (8f99928).

| Class | With the data µop (8.5 ns) | Before (8.5 ns) | Before (8.6 ns) |
|---|---|---|---|
| **Reached** | **9.06 ns** | 9.31 ns | 9.57 ns |
| `s1` | −0.563 | −0.810 | −0.973 |
| `guard` | −0.560 | −0.272 | −0.572 |
| `ff` | −0.467 | −0.589 | −0.745 |
| `loop` | **−0.186** | −0.179 | −0.504 |
| `kill` | +0.200 | +0.120 | −0.056 |
| `s2` | +0.279 | +0.530 | −0.058 |
| LUTs after routing | 5,707 | 5,692 | 5,716 |

- **Cost:** only 15 LUTs and 5 FF in the block.
- **Not an improvement:** the 0.25 ns between 9.06 and 9.31 is within placement's spread of 0.26 ns. It is another netlist too, and `guard` got 0.29 ns worse.
- **Loop 1 now:** still 9.1 to 9.6 ns, `loop` itself 8.7 to 9.1 ns.
- **The worst path:** still dispatch's S1 into the age bits. The lever noted in 28.10 (updating the age bits from `w2`) is still unused.

#### Where it stands (all blocks alone)

| Loop | Block | Reached |
|---|---|---|
| 1 | `OOC_SCHED` | 9.1 to 9.6 ns (`loop` 8.7 to 9.1) |
| 2 | `OOC_EXU` | 9.2 ns |
| 3 | `OOC_LSU2` | 8.1 ns |
| 6 | `OOC_UBTB2` | 8.9 ns |
| 4 | Rename of 4 | not started |
| 5 | The fetch buffer split | not started |

The core added about 1 ns at 20 ns, so all 4 are within reach of 10 ns. Loops 1 and 2 have the smallest margin.

I recommend loop 4 next. The store's 2 µops bear on rename's width, so they can be designed together. Today's `OOC_RENAME` has +1.04 ns at 10 ns with 2 µops, and 4 µops have not been measured.

The record is section 28.15 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 151. 2026-11-03 23:11:08 JST

```text
Yes, loop 4
```

<!-- answer -->
**Claude Code's answer**

I built loop 4 as a new design, `OOO_RENAME2`, and pushed it (20b579b): 4 µops renamed in 2 stages. **The model is 6.722, about the same as the 6.726 before.** Timing is not measured yet.

#### Where the design starts
`OOO_SDISP`'s S1 is in R2 and compares the physical sources and new registers from registers, so these must be known at the end of R1. So R1 does all of renaming, and R2 is little but registers.

| Item | Choice | Why |
|---|---|---|
| R1 | RAT read, dependences among the 4, new registers, RAT write | 5 levels by count |
| R2 | What S1 does not take stays in its slot; R1 moves when it is empty | No mux of 4 on about 170 bits |
| Busy bits | None | `OOO_SDISP` compares |
| Free list | A ring of 64 places for 48 registers, 4 banks of LUT RAM | A group needs one port a bank; about 32 LUTs by estimate |
| Checkpoints | LUT RAM, 269 bits × 12, at most 2 a group | About 360 LUTs and a read mux in place of 3,200 FF and a mux of 12 |
| Restore | 2 cycles (the RAT, then undoing the group's younger µops) | No mux added on the RAT; the front end is at least 8 stages behind, so no loss |

#### The model (checkpoints a cycle)

| A cycle | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| Any number | 6.726 | 7.234 | 6.484 | 5.797 |
| **2 (chosen)** | **6.722** | **7.234** | **6.487** | **5.797** |
| 1 | 6.697 | 7.182 | 6.438 | 5.731 |
| A checkpoint ends its group | 6.543 | 7.074 | 6.322 | 5.685 |
| Any number, rename in 3 stages | 6.698 | 7.203 | 6.459 | 5.777 |

- **Why:** the simplest, ending the group, costs −2.7 %. 1 costs −0.4 % and puts RTL at 6.295, under the gate's 6.3.
- **Value now:** with 2, RTL about 6.32.
- **Lever if short:** rename in 3 stages, −0.4 %.
- **Not in the model:** a group waits when fewer than 8 registers are free. It should happen only with nearly all the ROB writing, but it is not measured.

#### The change in `OOO_SDISP`
What stays in R2 leaves gaps in the slots, so slots may be not valid among valid ones.

That adds inputs to S1, the limit of `OOC_SCHED`, so **`sched85` has to run again**.

#### Verification
- **Bench `tb_rename2`:** 800,000 cycles against its own reference, no mismatch: 605,485 µops, 45,921 groups with 2 checkpoints, 33,116 restores (9,832 at the earliest cycle), 170,063 cycles short of registers.
- **Design faults found:**
  - The next id after 2 checkpoints came from the first.
  - `restore_id + 1`, as in today's `OOO_RENAME`, left a hole and open ids were reused. The restored id now goes next.
- **`tb_sched`:** 76,494 gaps among the slots, no mismatch.
- **Bug injection:** all 30 of `rename2` and 105 of `sched` detected, every line read. M734 was equivalent and removed; M751 showed an enable not needed, removed from the RTL.
- **Lint:** `-Wall` clean on blocks and harness.

#### Not confirmed
- **When `disp_go` arrives:** the harness has 55 % of the period, an estimate from S1's worst path, not a measurement.
- **Not in:** ROB entries, branch masks, the decoded queue before it.
- **`arat`:** still in FF (224), to change if size calls for it.

#### Request
Please run these 2 on Windows. Results go to `output/OOC_RENAME2_T9` and `output/OOC_SCHED_T8.5`.

```bash
synth_ooo.bat ren2
```

```bash
synth_ooo.bat sched85
```

To read:
- **`ren2`:** `go` first (S1 to the state), then `r1`, `read`, `tag`, `rat`, `ck`, `rest`, `cmt` and the total LUTs.
- **`sched85`:** against the last 9.06 ns; up to 0.26 ns is placement's spread.

The record is section 28.16 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`). Step 1.2's "model ≥ 6.8" is unchanged, with a note "6.72 as built, the author's to change".
<!-- /answer -->

## 152. 2026-11-04 22:09:31 JST

```text
Both finished
```

## 153. 2026-11-04 22:44:12 JST

```text
Try again
```

<!-- answer -->
**Claude Code's answer**

**The 2 results showed a problem, so I redesigned dispatch (ee23252).** `OOC_RENAME2` itself nearly fits, but `disp_go` is later than I estimated, and S1 had got worse, to about 9.95 ns. So steering moved a cycle ahead. Simulation passes; it is not measured in Vivado yet.

#### `ren2` (9 ns asked)
Register to register +0.909 ns (8.09 ns), 3,146 LUTs, 679 FF in the block. Today's 2-µop one is 2,657 LUTs, so widening to 4 µops costs 18 %.

| Class | Slack | Reached | Levels |
|---|---|---|---|
| **`go` (port to state)** | **−0.092** | 4.83 ns after the port | 5 |
| `rat` | +0.909 | 8.09 ns | 5 |
| `rest` | +1.347 | 7.65 ns | 3 |
| `ck` | +1.728 | 7.27 ns | 3 |
| `r1` | +2.359 | 6.64 ns | 5 |
| `read` | +2.580 | 6.42 ns | 5 |
| `tag` | +2.624 | 6.38 ns | 4 |

#### `sched85`: worse, about 9.95 ns
0.89 ns later than the last 9.06 ns, more than placement's spread of 0.26 ns. The cause is `disp_valid` added to the steering last time, to handle gaps in R2.

**My estimate was wrong too.** `disp_go[3]` comes at 70 to 80 % of the period, not 55 %. With the 4.83 ns behind it, `adv` would take about 11 ns and not fit 100 MHz.

#### The answer: steering a cycle ahead
In the cycle before S1, each slot's queue and how many go before it there are chosen into registers (`sq`, `sr`).

- **S1:** the bank is 1 or 2 LUTs from those and the room.
- **`disp_go`:** about 3 levels from registers, by estimate.
- **`wa`:** S1's worst path gets shorter by as much.

| Steering | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| The order 2 old, in S1 (last time) | 6.722 | 7.234 | 6.487 | 5.797 |
| **The order 3 old, chosen again every cycle (chosen)** | **6.709** | **7.229** | **6.465** | **5.757** |
| Queues fixed at R1, not chosen again | 6.502 | 7.002 | 6.261 | 5.597 |

Fixing costs −3 %, so it is chosen again every cycle: a µop stuck on a full queue can move to an emptier one the next cycle.

#### What it does to the targets
**The model is 6.709, RTL at × 0.94 about 6.31, 631 CoreMark/s. Only 0.01 over gate S1-B's 6.3.** If the RTL falls below the model from here, the gate is missed. A lever if short is queues of 10 (6.767 under other conditions), with the effect on loop 1 to measure.

#### Verification
- **Bench `tb_sched`:** 421,091 issued, 76,109 slots not valid among valid, no mismatch.
- **Bug injection:** all 106 of `OOO_SCHED` and `OOO_SDISP` detected, every line read. M778 was equivalent and removed.
- **The last fix:** a type only, for a lint warning; the bench and 5 steering mutations rerun, not all.
- **Lint:** `-Wall` clean on blocks and harness.

#### Not confirmed
- **Choosing again:** the mux `s0_*` is on R2's side and the bench's groups do not stay, so it is not tested until R2 is joined. The harness has it for timing only.
- **`disp_go`'s delay:** 45 % of the period now in `OOC_RENAME2`, also an estimate, to be checked by this `go`.

#### Request
Please run these 2 on Windows, in this order; `sched85`'s `go` checks what `ren2` assumes.

```bash
synth_ooo.bat sched85
```

```bash
synth_ooo.bat ren2
```

To read:
- **`sched85`:** first the new class `go`, whether it is within 45 % of the period; then `s1`, `ff`, `loop` against 9.06 ns.
- **`ren2`:** `go`'s slack and the total.

The record is section 28.17 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 154. 2026-11-04 23:19:50 JST

```text
Both finished
```

<!-- answer -->
**Claude Code's answer**

**Steering a cycle ahead worked. `OOC_SCHED` reaches about 8.91 ns, under 9 ns for the first time, and loops 1 and 4 both hold with no lever used.** The model stays 6.709. The record is pushed (6310715).

#### `sched85` (8.5 ns asked)

| Class | This run | With gaps in S1 | Before gaps |
|---|---|---|---|
| **Reached** | **8.91 ns** | 9.95 ns | 9.06 ns |
| `guard` | **−0.402** | −0.943 | −0.560 |
| `loop` | −0.136 | −0.767 | −0.186 |
| `ff` | +0.001 | −1.290 | −0.467 |
| `s1` | **+0.232** | −1.450 | −0.563 |
| LUTs after routing | 5,710 | 5,808 | 5,707 |

- **What really worked:** the overall 0.15 ns (9.06 to 8.91) is within placement's spread, but `s1`'s 0.8 ns is real. Dispatch is no longer the limit.
- **The limit now:** the loop itself, `guard` 8.90 ns, `loop` 8.64 ns.
- **Harness:** it now includes R2, so this is closer to the real core than before.
- **A path to watch:** `ahead` (the next cycle's steering) has 14 levels and stopped at +0.001 ns. Its margin is unknown; to check when joined to the core.

#### When `disp_go` comes: my estimate was off again
The new class `go` measures about 4.9 ns (58 % of the period), 5 levels. More than the 3 I counted, and the 45 % (4.05 ns) I gave `ren2` last time was too early.

So this `ren2` (WNS +0.289 ns) is optimistic. The block's RTL is the same, so **the one to go by is the earlier run at 55 % (4.95 ns), −0.092 ns, about 9.1 ns.** No rerun needed. The delay in `synth_ooo.tcl` is back at 55 %.

The `go` path had time to spare and was not optimized. It may be faster, but that is not confirmed.

#### Where it stands (all blocks alone)

| Loop | Block | Reached |
|---|---|---|
| 1 | `OOC_SCHED` | 8.9 ns (`loop` 8.6) |
| 2 | `OOC_EXU` | 9.2 ns |
| 3 | `OOC_LSU2` | 8.1 ns |
| 4 | `OOC_RENAME2` | 9.1 ns (register to register about 8.1) |
| 6 | `OOC_UBTB2` | 8.9 ns |
| 5 | The fetch buffer split | not started (today's −3.31 ns at 10 ns) |

The core added about 1 ns at 20 ns, so all 5 are within reach of 10 ns. What joins the blocks is not measured yet.

#### Against the targets
The model is 6.709 / 7.229 / 6.465 / 5.757, RTL about 6.31, 631 CoreMark/s, still 0.01 over gate S1-B's 6.3. Step 1.2's "model ≥ 6.8" is still not met. Whether to change that is the author's call.

#### Next
Only loop 5 is left in step 1.1, then gate S1-A can be decided. Today's fetch buffer had the largest shortfall of the 6 loops (−3.31 ns at 10 ns), so I recommend it next.

The record is section 28.18 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 155. 2026-11-04 23:22:49 JST

```text
Yes, loop 5
```

<!-- answer -->
**Claude Code's answer**

I built loop 5 as a new design, `OOO_FBUF2`, and pushed it (7fc3707). **All six loops now exist.** Its timing is not measured yet. The model is 6.707, and in RTL terms the gate's margin is nearly gone.

#### The design
Today's `OOO_FBUF` is slow for a 15-level loop: head parcel, a window of 8 parcels, the lengths one after another, the count taken, head parcel (−3.31 ns at 10 ns). So **nothing in the loop looks at an instruction any more.**

| Item | Choice | Why |
|---|---|---|
| Boundaries | From F3's predecode (`in_st`) | The chain of lengths leaves |
| F4 | A table of the block's instructions (where, how many) | About 8 levels from registers, by count |
| D1 | The head is an instruction: a count down and a counter per slot | **The loop is 3 levels by count** |
| One block a cycle | What is left of a block goes alone | No second block or window in any path |
| Across 2 blocks | The first half kept in the next block's place 0 | One input more on the slots' mux |
| Rare classes | A block with any gives 1 instruction a cycle | Rare stays out of the count |

#### The model

| Decode | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| 6 across blocks (last time) | 6.709 | 7.229 | 6.465 | 5.757 |
| **One block a cycle (chosen)** | **6.707** | **7.226** | **6.460** | **5.755** |
| 6 across blocks, decode a stage more | 6.681 | 7.198 | 6.440 | 5.738 |

One block costs next to nothing, as a block seldom has more than 6.

**Against the targets:** RTL at × 0.94 about 6.305, 630 CoreMark/s, 0.005 over gate S1-B's 6.3. That 0.94 was measured on today's core and may not hold for the new one. It may well fall under 6.3 in the real thing, so gate S1-A needs a decision.

#### Verification
- **Bench `tb_fbuf2`:** 2 million cycles against the program given, no mismatch: 706,068 blocks, 2,911,760 instructions, 141,020 across 2 blocks, 294,573 cycles with 6.
- **Bug injection:** 31 of M780 to M811 all detected, every line read. M801 was equivalent and removed.
- **Lint:** `-Wall` clean on block and harness.

#### Not confirmed
- **Size:** the slots' muxes of 17 are about 1,150 LUTs by estimate, larger than today's 1,115 in all.
- **`in_st`:** from a register in the harness. Whether `OOO_PREDEC` gives 16 parcels' worth by F3's end is not measured.
- **Rare's cost:** 1 instruction a cycle is not in the model. It tells in FP-heavy code.
- **Not in:** `OOO_FETCH` at 32 bytes, the FTQ, decode of 6, the decoded queue with the store's crack (step 1.4).

#### Request
Please run the following on Windows. Results go to `output/OOC_FBUF2_T9`.

```bash
synth_ooo.bat fbuf2
```

To read: `loop`, `slot`, `tab`, `rare`, `load`, `ram` and the total LUTs. Levers if short: the slots' positions read a cycle ahead, `tab` across F3 and F4.

When it is done all 6 are in, and gate S1-A comes next. Besides the blocks' figures, you will need to decide on the thin 0.94 and step 1.2's "model ≥ 6.8" there.

The record is section 28.19 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 156. 2026-11-04 23:46:45 JST

```text
fbuf2 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_FBUF2` meets 9 ns (WNS +0.352 ns, about 8.65 ns reached). All 6 loops now fit under 9.2 ns alone, so gate S1-A can be decided.** Please decide. The record is pushed (97f0a46).

#### `fbuf2`

| Class | Slack | Reached | Levels |
|---|---|---|---|
| Worst (an empty block's test to the RAM's write enable) | +0.352 | 8.65 ns | 5 |
| `tab` | +0.541 | 8.46 ns | 5 |
| `slot` | +1.015 | 7.99 ns | 7 |
| **`loop` (the head's loop)** | **+3.505** | **5.50 ns** | 2 |

2,003 LUTs, 458 FF in the block. Larger than today's 1,115 LUTs for 4 slots, but the 15-level loop is 2 levels now and no longer the limit.

#### All 6 loops (each alone)

| Loop | Block | Reached | LUTs | Today's (slack at 10 ns) |
|---|---|---|---|---|
| 1 Wakeup + select | `OOC_SCHED` | **8.91 ns** (`loop` 8.64) | 5,710 | −1.95 |
| 2 Bypass + ALU | `OOC_EXU` | **9.16 ns** | 12,472 | −0.66 |
| 3 M1 + M2 | `OOC_LSU2` | **8.10 ns** | 2,053 | −2.66 |
| 4 Rename of 4 | `OOC_RENAME2` | **9.09 ns** | 3,143 | +1.04 (2 µops) |
| 5 Fetch buffer | `OOC_FBUF2` | **8.65 ns** | 2,003 | −3.31 |
| 6 uBTB | `OOC_UBTB2` | **8.88 ns** | 378 | −2.04 (8 entries) |

#### For gate S1-A
- **For going on:** all 6 under 9.2 ns, with none of the loops' fallbacks used (such as a load-use of 4).
- **Timing's margin is thin:** the core added about 1 ns, so loops 2 and 4 would be about 10.2 and 10.1 ns, loop 1 about 9.9. Within reach, no margin. That 1 ns itself was measured once, on another design at 50 MHz.
- **The joins are not measured:** the largest worry is `OOC_FE`, −4.79 ns today, the worst of all, and not one of the 6. Then the FTQ, decode of 6, the decoded queue, the ROB at 4 wide, the miss handler.
- **CoreMark/MHz has no margin either:** the model fell from 6.90 to 6.707 as the blocks were built. At × 0.94 about 6.305, about gate S1-B's 6.3. For the goal above 6.0 alone, × 0.895 is enough.

#### My recommendation: go
With these conditions:

1. **Configuration:** frozen as in 28.13 to 28.19.
2. **Step 1.2:** "model ≥ 6.8" changed to "≥ 6.7"; it cannot be met as it is.
3. **Gate S1-B's 6.3:** kept as a working target; the goal above 6.0 judged apart if it is missed.
4. **The fallback to 90 MHz:** stays open with no change of pipeline (567 CoreMark/s), to decide at step 1.6 with the whole core measured.
5. **Next:** by the table it is step 1.2, but first measure the largest unknown, `OOC_FE` (32-byte fetch). If that does not fit, the other results lose their meaning.

With "Not yet", `OOC_FE` alone is measured before freezing. The next work is the same either way; the difference is whether the configuration is frozen now.

The record is section 28.20 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 157. 2026-11-04 23:55:19 JST

```text
Not yet
```

<!-- answer -->
**Claude Code's answer**

I built F3 and F4 as a new block, `OOO_FDEC`, and pushed it with `OOC_FE2`, a harness joining them to F0 and the fetch buffer (4d8e2d6). Simulation passes; timing is not measured yet. **While building it I found the override comes a stage later than the proposal. The model falls to 6.656, RTL about 6.26, under gate S1-B's 6.3.**

#### What I found: the override does not fit in F3
The proposal did predecode, TAGE's decision and the override all in F3. With 16 parcels that is about 18 levels by count, not one cycle. Today's, with 8 parcels and the same chain, is the −4.79 ns path itself. So 2 stages:

| Stage | What | Aim |
|---|---|---|
| F3 | Boundaries, kinds, 16 targets, each compared with where fetch went on | Nothing waits for a decision |
| F4 | Prediction, the first taken, right or wrong from the compares made, the next address | About 8 levels by estimate; F0's last LUT has room |
| Buffer | `in_st` runs past a taken transfer; the late `in_first` only cuts the count | `OOO_FBUF2`'s table does not wait for the decision |
| Stack | Read in F4, moved at its end, the call's address with no adder | Removes the push that was today's worst path |

| Override | `-O2` | most optimization | g13 | rv64gc |
|---|---|---|---|---|
| `override_at` 3 (proposal) | 6.707 | 7.226 | 6.460 | 5.755 |
| **`override_at` 4 (from F4; this design)** | **6.656** | **7.182** | **6.415** | **5.733** |
| `override_at` 5 (F4's decision in a register) | 6.574 | 7.114 | 6.352 | 5.693 |

#### What it does to the targets
- **This design:** RTL at × 0.94 about 6.26, 626 CoreMark/s. 0.04 under gate S1-B's 6.3, above the goal of 6.0.
- **If F4 does not fit:** model 6.574, RTL about 6.18.
- **Margin:** 6.0 needs × 0.90. The difference from today's 0.94 is what is left.

#### Verification
- **Bench `tb_fdec`:** 600,000 cycles against a reference written apart, no mismatch: 352,823 blocks, 194,335 overrides, 17,211 instructions finished in the next block.
- **`tb_fbuf2`:** no mismatch with the late cut (`in_first`).
- **Bug injection:** all 30 of `fdec` and 35 of `fbuf2` detected, every line read. M828, M840, M841 got through at first, so the bench was fixed.
- **Lint:** `-Wall` clean on blocks and harness.

#### Not confirmed
This run answers for today's worst path, not all of `OOC_FE`. Not in the harness:

- The arrays and tag compares of F1 and F2, the I$
- TAGE M itself and its update
- The FTQ
- The requests in flight and the credit

#### Request
Please run the following on Windows. Results go to `output/OOC_FE2_T9`.

```bash
synth_ooo.bat fe2
```

To read: `ovr` (F4's override into F0), `f3`, `cut`, `ras`, `ubup`, `tab`, `loop`, `slot`, `dloop` and the total LUTs. Levers if short: `cnt` into F4, F4's decision in a register (6.574).

When it is done we return to gate S1-A, where you will also need to decide whether to lower gate S1-B's 6.3.

The record is section 28.21 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 158. 2026-11-05 00:32:23 JST

```text
fe2 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_FE2` reached about 9.85 ns (WNS −0.849 ns, 5,095 LUTs). That is 5 ns off today's `OOC_FE` of about 14.8 ns, and the path worried about most is gone.** But the core adds about 1 ns, so it is not enough. I made 2 changes that shorten it without costing CoreMark and pushed them (7fc095f). Please measure again.

(An interim message said "S1 is about 9.85 ns in `fe2`"; the figure is for `OOC_FE2` as a whole.)

#### `fe2` (9 ns asked)

| Class | Slack | Reached | Levels |
|---|---|---|---|
| **`ovr` (F4's choice into F0)** | **−0.849** | 9.85 ns | 12 |
| `loop` (F0's own) | −0.817 | 9.82 ns | 9 |
| `f3` (the block to F4's registers) | −0.726 | 9.73 ns | 19 |
| `cut` (F4's choice into the buffer's table) | −0.531 | 9.53 ns | 11 |
| `ras` | −0.378 | 9.38 ns | 8 |
| `ubup` | −0.101 | 9.10 ns | 10 |
| `tab` | +0.381 | 8.62 ns | 8 |
| `slot` | +0.734 | 8.27 ns | 6 |
| `dloop` | +2.992 | 6.01 ns | 2 |

- **`ovr`:** F4's path fits in a cycle, at 12 levels against about 8 estimated.
- **`loop`:** 8.64 ns alone, the same logic. I read it as the effect of placement with the rest; the next run will tell.
- **`f3`:** most of its 19 levels are the boundaries' chain in front of the target compares.

#### The 2 changes

| Change | What | Effect |
|---|---|---|
| A target's form from the bits alone | 32-bit if the parcel before looks like a branch or a jal | The chain leaves the adders and compares |
| A `first_s` for the compare alone | "Right or not" per parcel in a register, a copy of `first` for the compare | By count 2 levels less to `ovr`, away from the fan-out of 55 |

The first gets a target wrong when a 32-bit instruction's second half happens to look like a branch and a 16-bit transfer follows it. Behaviour stays correct: the back end finds it as a misprediction. **The 4 CoreMark builds have 5 such places, none of which runs: 0 in 12.7 million instructions.** So the model stays 6.656. It may occur in other programs.

#### Verification
- **Bench `tb_fdec`:** against a reference with the same rule, no mismatch (352,822 blocks, 194,336 overrides).
- **Bug injection:** all 34 of `fdec` detected, every line read. M850 to M853 are new.
- **Lint:** `-Wall` clean on blocks and harness.

#### Request
Please run the following on Windows. It overwrites `output/OOC_FE2_T9`; this run's results stay in git.

```bash
synth_ooo.bat fe2
```

To compare with the table: `ovr`, `f3`, `loop`, `cut`, above all whether `loop` returns to its value alone.

If it comes down to about 9.3 ns, gate S1-A has what it needs. If not, the next levers are `cnt` into F4 and F4's decision in a register (model 6.574, RTL about 6.18).

The record is section 28.22 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 159. 2026-11-05 00:47:48 JST

```text
fe2 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_FE2` is now about 9.5 ns in substance, well down from about 14.8 ns today. But by the sums the whole core would be about 95 MHz, so 100 MHz is not secured.** I still recommend going on. The record is pushed (543b917).

#### `fe2` (9 ns asked)

| Class | This run | Last run | Levels |
|---|---|---|---|
| The path to the history bits | −0.820 | − | 12 |
| **`ovr`** | **−0.518** (9.52 ns) | −0.849 | 13 |
| **`f3`** | **−0.503** (9.50 ns) | −0.726 | 10 |
| `tab` | −0.212 (9.21 ns) | +0.381 | 10 |
| `loop` | −0.139 (9.14 ns) | −0.817 | 9 |
| `cut` | −0.126 (9.13 ns) | −0.531 | 10 |
| `slot` | +0.725 (8.28 ns) | +0.734 | 6 |

- **The 2 changes:** `f3` went from 19 levels to 10, LUTs down by 211 to 4,884, `loop` back by 0.68 ns.
- **The worst path (WNS −0.820):** to the history bits, which need no hurry in F4. Moved a cycle on. Simulated, not measured in Vivado after that; it touches no other path, so I skipped a rerun.
- **In substance:** without the history bits, the worst is `ovr` at about 9.5 ns.

#### An error of procedure
I committed bc7940a before seeing the bug injection's result. My edit had given 2 mutations one id and lost one's text. Fixed and rerun, both detected; `fdec` is all 34 detected. Noted in 543b917 and section 28.23.

#### For gate S1-A

| Block | Alone | With about 1 ns for the core |
|---|---|---|
| F0 to D1 (`OOC_FE2`) | 9.5 ns | 10.5 ns |
| Loop 2 (`OOC_EXU`) | 9.2 ns | 10.2 ns |
| Loop 4 (`OOC_RENAME2`) | 9.1 ns | 10.1 ns |
| Loop 1 (`OOC_SCHED`) | 8.9 ns | 9.9 ns |
| Loop 3 (`OOC_LSU2`) | 8.1 ns | 9.1 ns |

The model is 6.656 / 7.182 / 6.415 / 5.733, RTL about 6.26.

| The whole core at | CoreMark/s | Against the 50 MHz design (337) |
|---|---|---|
| 100 MHz | 626 | 1.9 times |
| 95 MHz | 595 | 1.8 times |
| 90 MHz | 563 | 1.7 times |
| 75 MHz | 470 | 1.4 times |

**The hard part:** 595 at 95 MHz just misses the goal of 600 CoreMark/s. The +1 ns was measured once, on another design at 50 MHz, and TAGE M, the I$, the FTQ, the ROB and the decoded queue are not measured.

#### My recommendation: go
Above about 54 MHz this configuration beats the 50 MHz design, and nothing so far argues for another. With:

1. **Freezing** the configuration of 28.13 to 28.23.
2. **Step 1.2:** "model ≥ 6.8" to **≥ 6.6**.
3. **Gate S1-B:** "RTL ≥ 6.3" to **≥ 6.2**; the goal above 6.0 stays.
4. **Levers left**, each measured if needed:
   - queues of 10 (+0.5 %)
   - F4's decision in a register (−1.2 %)
   - rename in 3 stages (−0.4 %)
   - a lower clock with no change of pipeline

"Go" changes these 2 figures as proposed; tell me if you want others. With "Not yet", tell me what to measure next.

The record is section 28.23 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 160. 2026-11-05 01:00:42 JST

```text
I want to keep 100 MHz as the target as far as possible. On that basis, let us go ahead with the proposal.
```

<!-- answer -->
**Claude Code's answer**

Gate S1-A is recorded as "go" and the configuration frozen. **100 MHz stays the target.** Pushed (a49eb1c).

#### What was decided

| Item | Decision |
|---|---|
| Configuration | Frozen as in 28.13 to 28.23 (model 6.656 / 7.182 / 6.415 / 5.733) |
| Clock | **100 MHz stays the target**; lowering it is the last resort |
| Goal | `-O2` above 6.0 CoreMark/MHz, above 600 CoreMark/s (unchanged) |
| Step 1.2 | "Model ≥ 6.6": met at 6.656, done |
| Gate S1-B | "RTL ≥ 6.2" |
| Working target | RTL 6.2, board 6.1 |

#### What changes to keep 100 MHz
**A lever that costs CoreMark/MHz is used only when a measurement of the whole core shows it is needed.** Queues of 10 are treated the same, as they may hurt loop 1.

That needs measuring the whole early. The least certain number now is the "about 1 ns" the core adds, measured once, on another design at 50 MHz. At 0.5 ns 100 MHz is reached; at 1.5 ns it recedes. So `Doc/STRATEGY.md` now has step 1.6's `OOO_CPU` measured from the start of step 1.3.

#### Next: step 1.3
Today's 2-wide core moves to the new pipeline first, with no change of width.

- **Stages added:** fetch 5, decode and rename 5, select to EX 3, load-use 3 cycles. No new function.
- **Checks:** lock-step, cycles against the model, and `OOO_CPU` measured at each stage.
- **The blocks built:** joined from step 1.4 on. New slow paths that the joining shows are dealt with then.

The record is section 28.24 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 161. 2026-11-05 01:04:00 JST

```text
Yes, step 1.3
```

<!-- answer -->
**Claude Code's answer**

Step 1.3 has begun. The first stage, RR1, is in the core, select to EX is 3 cycles. All the lock-step tests pass first time; pushed (467a817).

#### The plan for step 1.3
Today's 2-wide core moves to the new pipeline a stage at a time, width unchanged, with the tests passing each time.

| # | What | Change | Status |
|---|---|---|---|
| A | RR1 (select to EX 3 cycles) | `iss_to_ex` 2 to 3 | **Done** |
| B | Load-use 3 cycles (E, M1, M2, today's D$) | `lat_load` 2 to 3 | Next |
| C | Multiply 4 cycles | `lat_mul` 2 to 4 | |
| D | Decode and rename 5 stages | `dec_depth` 3 to 5 | |
| E | Fetch 5 stages (override at F4) | `fe_depth`, `override_at` | |
| F | The redirect 6 stages after EX | `redirect` 3 to 6 | |

#### A's result

| `g14 -O2`, cycles | Before | After | Increase |
|---|---|---|---|
| RTL | 1,817,188 | 1,857,214 | +2.20 % |
| Model (`iss_to_ex` 2 to 3) | 1,722,666 | 1,756,596 | +1.97 % |
| Model / RTL (what × 0.94 comes from) | 0.948 | 0.946 | |

- **Against the model:** cycles grow about the same, and the ratio barely moves.
- **Lock-step:** all of `run_core.sh` (60, 96, 186, 127 programs on both tops) and CoreMark on 4 configurations, 3 builds each: 0 failures.
- **Bug injection:** `mutate_core.py` not run. Only a stage was added; it comes together at the end of step 1.3.

#### Request: the whole core at a 10 ns target
A new run, `cpu10`, measures for the first time at the 100 MHz target what the core adds. Until now there is only the one figure at 20 ns.

```bash
synth_ooo.bat cpu10
```

Results go to `output/OOO_CPU_T10`. Today's core will miss 10 ns by far, which does not matter: against each block's value alone in 28.1, **how much does each block grow in the core?** Under about 1 ns brings 100 MHz nearer; over it calls for the levers early.

This answer went into `Doc/PROMPT.md` in a short form first; next turn it is replaced by this translation.

The record is section 28.25 of `Plan/OOC.md` (Japanese `Plan/OOC_J.md`).
<!-- /answer -->

## 162. 2026-11-05 01:37:09 JST

```text
cpu10 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOO_CPU` at a 10 ns target reached about 18.8 ns (WNS −8.824 ns, 37,240 LUTs). But what I wanted to know, how much building into the core adds, could not be measured**, because the limit lay in paths between blocks, not inside them. The record is pushed (c63201c).

#### The limit is in the paths between blocks

| Worst slack | Levels | Path |
|---|---|---|
| −8.82 | 23 | ROB head exception → flush → go of `OOO_CTRL` → dispatch valid → tval read → `OOO_TRAP` |
| −7.91 | 35 | WB result → bypass → ALU → misprediction → ROB done bit |
| −7.80 | 35 | EX → ALU → misprediction → ROB done bit |
| −7.69 | 25 | `rob_insn` → `OOO_CSRU` |
| −7.65 | 35 | LSU bypass and address → ROB done bit |
| −7.60 | 34 | ALU1's EX to the other ports' stages, the queues, `OOO_CTRL`, `OOO_MDUP` |
| −6.17 | 16 | The fetch buffer loop (alone −3.31) |
| −6.02 | 15 | Fetch itself (`OOC_FE` alone −4.79) |

- **"About 1 ns" is still unknown:** only the fetch buffer (+2.86 ns) and fetch (+1.2 ns) compare with their runs alone. Vivado does not optimize paths behind worse ones, so those two are upper bounds.
- **The 6 loops were not all of it:** these joins are not among the loops I have been measuring. They are not limits in principle, just decisions taken in the same cycle that could wait a cycle. Cutting them was not in the plan of step 1.3, though.

#### Proposal: cut 4 first

| # | What is cut | Expected |
|---|---|---|
| A2a | The ROB head's exception goes into a register before the flush | The −8.82 path goes. A trap is a cycle later |
| A2b | A branch's completion comes from the registered resolution | The −7.9 family goes |
| A2c | The LSU's completion comes from a register (`OOO_LSU2` has this form already) | −7.65 goes |
| A2d | `rob_insn` is read a stage before the CSR | −7.69 goes |

#### The cost in CoreMark (model)

| | `-O2` | Max optimization | g13 | rv64gc |
|---|---|---|---|---|
| The design now | 6.656 | 7.182 | 6.415 | 5.733 |
| All results' done a cycle later | 6.624 | 7.156 | 6.384 | 5.710 |
| The redirect a cycle later | 6.643 | 7.166 | 6.403 | 5.724 |

Only a branch's done needs the misprediction decision; other results come from registers. The proposal delays only a branch's completion, so the cost should be below the −0.5 % of the second row. The actual value will be checked in RTL cycles after the cuts.

A trap a cycle later should cost next to nothing in CoreMark. In Linux, with interrupts and exceptions more frequent, the effect is not checked.

#### What comes next
After the 4 cuts, `cpu10` runs again. Each cut shows the next path, so this takes a few rounds. Only then is it known how much building into the core adds.

I recommend this before stage B (load-use 3 cycles): if these paths remain, adding a stage tells nothing from the measurement.

The record is section 28.26 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)).
<!-- /answer -->

## 163. 2026-11-05 17:47:17 JST

```text
I want to change direction again here.
Aiming at 100 MHz on this FPGA seems difficult.
This time CoreMark/MHz maximization takes priority, so I will not insist on the operating frequency.

What is a realistic operating frequency for the CPU?
There are interfaces such as DDR3 and Ethernet, so I think it also depends on the operating
frequencies of those peripherals.
Please propose an operating frequency for each system block.
```

<!-- answer -->
**Claude Code's answer**

**For the CPU I propose 50 MHz. The peripherals stay as now planned, LiteX at 100 MHz, and neither DDR3 nor Ethernet limits the CPU's clock.** But the 50 MHz operation of the wide configuration compared here has not been measured. Only today's 2-wide core has: WNS +0.159 ns at a 20 ns target, about 18.8 ns at a 10 ns target.

## What decides the CPU's clock
What moves CoreMark/MHz is load-use; the other stages move it little (model, `-O2`, the 50 MHz configuration below).

| Change | CoreMark/MHz |
|---|---|
| **Load-use 2 → 3** | **−12 %** |
| Multiply 2 → 3 | −1.6 % |
| A register-read stage more | −1.0 % |
| A fetch or a decode stage more | −0.26 % each |
| Decode and redirect a stage shorter each | +0.5 % |

So the answer is **the highest clock that keeps load-use 2 and ALU 1 cycle**. Today's LSU takes about 12.7 ns for its load stage alone, and the routes between blocks add to that.

## The candidate clocks
Every row is one configuration: 4 renamed, 6 decoded, 32-byte fetch, 4 ALUs + 2 LSUs (6 issues), stores split, uBTB 96. RTL is assumed to be the model × 0.94, today's ratio.

| CPU | Pipeline | Model | RTL estimate | CoreMark/s | Feasibility |
|---|---|---|---|---|---|
| 33.3 MHz | **Load-use 1** (block RAM read on the falling edge) | 9.74 | 9.2 | 305 | A structural change, not measured |
| 40 MHz | Shorter than 50 MHz | 8.95 | 8.4 | 336 | Almost nothing gained by going down to 40 MHz |
| **50 MHz** | **Load-use 2, multiply 2** | **8.90** | **8.4** | **418** | **The main candidate**, the same stages as today's core |
| 66.7 MHz | Load-use 2, each stage +1 | 8.63 | 8.1 | 541 | Possible if the paths between blocks are cut |
| 66.7 MHz | Load-use 3 | 7.83 | 7.4 | 491 | Load-use costs a lot |
| 100 MHz | Deep pipeline | 7.39 | 6.9 | 695 | Given up this time |

With maximum optimization, the 50 MHz configuration gives 9.76 in the model. Today's core measures 5.50, so the step is large.

## The clock of each block

| Block | Clock | Why |
|---|---|---|
| The whole core (fetch to ROB), L1 | **50 MHz** | As above |
| FPU, MDU, CSR, PTW / PMP | **50 MHz** | The CPU's own clock, so no half-rate islands |
| L2, debug, CLINT, PLIC | **50 MHz** | The same. `mtime` by a divider of 100, 500 kHz as before |
| LiteX `sys` (LiteDRAM, CSR, UART, SD logic, LiteEth's bus side) | **100 MHz** | Needed for DDR3-800, LiteX's default on this board |
| DDR3 PHY `sys4x`, `sys4x_dqs` | **400 MHz** (`dqs` at 90°) | 800 MT/s is the board's specified value |
| IDELAYCTRL | **200 MHz** | For DDR3 and RGMII's receive delay |
| Ethernet RGMII | **125 MHz** | `LiteEthPHYRGMII` is 1 Gb/s only, from the PHY's receive clock |
| microSD | **Starts at 25 MHz, up to 50 MHz** | LiteSDCard's divider; 3.3 V only |
| JTAG / cJTAG (Pmod JA) | **Up to 10 MHz** (asynchronous) | The limit of JA's 200 Ω series resistors |

- **An MMCM setting, as an example:** from a VCO of 800 MHz, 100 MHz (/8), 400 MHz (/2), 200 MHz (/4), 50 MHz (/16). Not checked in Vivado.
- **The crossing on the bus:** 50 / 100 MHz between the CPU and LiteX, with `AXIClockDomainCrossing` and `AXILiteClockDomainCrossing`, as in mmRISC-2's bring-up plan.

## How it depends on the peripherals
- **DDR3:** JEDEC's lower limit of 303 MHz and the 1:4 ratio need LiteX at about 76 MHz or above; 800 MT/s as the upper limit gives 100 MHz at most. So 100 MHz.
- **Ethernet and SD:** both are complete on LiteX's side. Under Linux, though, the transfer rate is capped by the CPU's copy, which has not been estimated.
- **CoreMark:** the crossing's delay counts only on a cache miss, so the effect should be small. This is checked under Linux.

## Unchecked points and risks
- **6 issues at 50 MHz:** the register file with 12 reads and 6 writes and the 6 bypass sources have not been synthesized.
- **LUTs:** the estimate of about 98k is for the 100 MHz 4-issue design, and is to be redone. If 2 LSU ports and 4 ALUs do not fit, the configuration comes down: 4 ALUs + 1 LSU 8.49, 3 ALUs + 2 LSUs 8.63.
- **The × 0.94 ratio:** not checked for the wide configuration.

## What needs your decision
- **I recommend 50 MHz:** it keeps load-use 2, and needs no half-rate islands or their crossings.
- **Where 33.3 MHz stands:** by CoreMark/MHz alone, load-use 1 at 33.3 MHz is the highest, 9.74 (+9.5 % on 50 MHz). But CoreMark/s falls 27 %, Linux is slower, and block RAM read on the falling edge needs verification of its own. It depends on how far CoreMark/MHz is to be put first.
- **66.7 MHz:** not a goal; a candidate to go up to once 50 MHz is complete and the margin measured. CoreMark/MHz −3 %, CoreMark/s +29 %.

Once decided, I go on to 2 things:
- rewriting the goal, the configuration and the gates of `Doc/STRATEGY`;
- sorting the RR1 stage now in the core and the blocks built for 100 MHz (reuse or stop).

This comparison is not yet recorded in the documents. The addition to `Doc/PROMPT.md` is not committed yet, and goes with the next commit.
<!-- /answer -->

## 164. 2026-11-05 17:59:40 JST

```text
Proceed with 50 MHz
```

## 165. 2026-11-05 18:03:16 JST

```text
Try again
```

## 166. 2026-11-05 18:08:53 JST

```text
Please try again
```

<!-- answer -->
**Claude Code's answer**

**I rewrote the plan for the CPU at 50 MHz and LiteX at 100 MHz, and took RR1 out of the core. It is pushed (9dc2447; 0 Ref on origin/dev). But a number I gave last time was wrong: at 50 MHz the value is 8.68, not 8.90.** The choice of 50 MHz does not change.

## The correction
Last time's comparison assumed stores split in 2 µops with no replays, the same mistake I took back in 28.13. With replays the split falls to −8.4 % (7.95), so **stores stay one µop, as in today's core**.

| Configuration (`-O2`) | Before | Corrected | RTL estimate | CoreMark/s |
|---|---|---|---|---|
| 33.3 MHz, load-use 1 | 9.74 | 9.66 | 9.1 | 302 |
| **50 MHz (chosen)** | **8.90** | **8.68** | **8.2** | **408** |
| 66.7 MHz, load-use 2 | 8.63 | 8.21 | 7.7 | 515 |
| 100 MHz | 7.39 | 7.00 | 6.6 | 658 |
| 50 MHz, 4 ALUs + 1 LSU | 8.49 | 7.98 | | |
| 50 MHz, 3 ALUs + 2 LSUs | 8.63 | 8.37 | | |

- **Why 66.7 MHz fell so far:** besides the stores, the condition now delays the override with the added fetch stage. Against 50 MHz: −5.4 % CoreMark/MHz, +26 % CoreMark/s.
- **Against 33.3 MHz:** +11 % CoreMark/MHz, −26 % CoreMark/s.
- **RTL estimate:** the model × 0.94, not checked for this width.
- **Others:** the 50 MHz configuration gives 9.48 at maximum optimization, 7.40 on rv64gc.

## The configuration decided
4 renamed, 6 decoded, 32-byte fetch, 4 ALUs + 2 LSUs with 6 issues, a unified queue of 24, ROB 48, LQ / SQ 16, 12 checkpoints, TAGE M, uBTB 96, today's depth.

## What was done
- **Documents:** `Doc/STRATEGY`, `Doc/BOARD`, `README` in both languages; a note in `Doc/UARCH` making the sections concerned history. The 100 MHz plan stays as `Plan/STRATEGY_100MHz`. The half-rate islands go; each block's clock is in section 4.4 of STRATEGY.
- **RR1 removed:** CoreMark `-O2` 1,817,188 cycles, exactly as before RR1 (1,857,214 with it). `run_core.sh` 0 failures, `run_coremark.sh` PASS.
- **Model:** `Plan/model/g50.sh` and `results/g50.txt`. The record is section 29 of `Plan/OOC`.

## What becomes of the blocks built for 100 MHz
All stay in the tree with their benches (section 4.6 of STRATEGY).

| What | Blocks |
|---|---|
| Used | `OOO_UBTB2`, `OOO_RENAME2`, `OOO_FDEC`, `OOO_ALUF` |
| The starting point | `OOO_FBUF2` |
| Its functions only | `OOO_ALUR` |
| Kept as the fallback | `OOO_SCHED`, `OOO_SDISP` |
| Not used | `OOO_EXU`, `OOO_PRF2`, `OOO_LSU2`, `OOO_DCH`, `OOO_DTLB2` |

## Unchecked points and risks
- **LUTs are the largest risk:** the estimate of about 109k (81 %) is a little over the ceiling of 107.7k (80 %) taken for 50 MHz. Nothing of it is measured. It is measured at gate S1-A, and if it does not fit the fallbacks with known prices come in (3 ALUs −3.5 %, distributed queues −2.4 %).
- **Closing at 20 ns is not measured:** above all the unified 24 with 6 selects and the register file of 12 reads and 6 writes.
- **Rows of the model that did not end:** distributed queues with `steer=3` and 2 LSU ports did not end in 150 s. The cause was not looked into; if loop 1 takes the distributed fallback, the model is looked at first.
- **The working targets are my proposal:** RTL 8.0, board 7.8. Say if they should change.

## The next step
Step 1.1 measures the six loops at a 20 ns target in order. First the unified 24 with 6 selects: it matters most to CoreMark/MHz and takes many LUTs. I prepare the harness, and you run Vivado.
<!-- /answer -->

## 167. 2026-11-05 19:23:12 JST

```text
Yes, from the unified queue
```

<!-- answer -->
**Claude Code's answer**

**The unified queue `OOO_IQ2` and its harness are done and pushed (2e9bc3a; 0 Ref on origin/dev). Simulation passes, but timing and LUTs are not measured yet.** Please run the following on Windows; the results go to `output\OOC_IQ2_T15`.

```bash
synth_ooo.bat iq2
```

## What was made
- **Structure:** unified, 24 entries, 4 µops in, 6 ports, tag compare as in `OOO_IQ`. The straightforward design is measured before anything cleverer.
- **Order of selection:** the ALU ports select in the order 3, 2, 1, then port 0 from what is left. The LSU ports: port 5, then port 4 from what is left. The longest path is "4 stages of select, the tag's AND-OR, 9 compares".
- **Simplifications:** free entries come from the top of each of 4 banks. An age row does not depend on the result of the select.

## The price, checked in the model
The model treated every port as able to run anything. With the RTL's limits:

| Limit | `-O2` |
|---|---|
| None | 8.677 |
| A store only on LSU 0 | 8.669 |
| Multiply, divide, system, slow operations only on ALU 0 | 8.664 |
| ... a multiply takes port 1's write slot | 8.652 |
| 4 banks of 6 | 8.667 |
| **All (as built)** | **8.633** |

All together only −0.5 %. Maximum optimization 9.445, rv64gc 7.391. The register file can come down to 11 reads and 6 writes (port 5 needs one source, and a multiply uses an existing write slot).

## Verification
- **Bench `tb_iq2`:** 400,000 cycles, 532,542 µops, 0 mismatches. All 6 ports at once in 2,734 cycles; the queue full (95,133 cycles) and banks short (136,842 cycles) were passed through.
- **Bug injection:** M860 to M898, all 39 detected, read before the commit.
- **Lint:** no warnings at `-Wall` on `OOO_IQ2` and the harness's lines.

## What to look at in the measurement
The target is 20 ns, but this runs at 15 ns: Vivado stops when a target is met, and knowing the margin for the joins needs a harder target. In `summary_loop.txt`, the `loop` line decides as follows; these limits are my judgement before any measurement.

| `loop` reaches | Reading |
|---|---|
| About 15 ns or less | Room for the joins: unified 24 stays |
| 15 to 18 ns | Unified 24 possible: look at the paths before deciding |
| Above 18 ns | No margin: first a dependency matrix or a shorter chain of selects, then `OOO_SCHED` (−2.4 %) |

The payload is not in this measurement. `OOO_IQPL` with 4 writes and 6 reads is made after seeing this loop, so the LUTs grow by that much yet.

The record is section 29.1 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 168. 2026-11-05 19:55:25 JST

```text
iq2 finished
```

<!-- answer -->
**Claude Code's answer**

**The first `OOC_IQ2` reached about 21.1 ns at a 15 ns target, 9,968 LUTs (WNS −6.138 ns, no payload).** Over both the 18 ns limit and 20 ns. The cause was the chain of selects, so I changed how the ALU ports select and pushed it (b8f03ad; 0 Ref on origin/dev). The new version's timing is not measured yet.

## Why it was slow
The worst `loop` path (19 levels, 86 % routes):

| Part | ns |
|---|---|
| Ready bit and first select (port 3) | 5.9 |
| Second select (port 2) | 5.4 |
| Third select | 4.1 |
| **The chain of selects** | **15.4 (73 %)** |
| The tag's AND-OR | 2.5 |
| Compare, ready bit | 3.2 |

Last time I wrote that above 18 ns comes first a dependency matrix or a shorter chain; a dependency matrix takes off only part of the last 5.7 ns. So the chain went.

## What changed
- **Select by rank:** every any-ALU µop counts the ready any-ALU µops older than it, saturating at 4. Rank 0 goes to port 3, 1 to port 2, 2 to port 1, 3 to port 0, so the ports no longer depend on each other. An ALU0-only µop goes on port 0 when at most 3 any-ALU µops are older.
- **LSU ports:** ports 5, 4 stay a chain of 2: a load's wakeup comes a cycle later, off the loop.
- **LUTs:** the mux of about 44 bits choosing the writing slot went from each of 24 entries to each of 4 banks, as the queue alone had passed the 9k estimated with its payload. Counting the rank adds some back.

## The price
A µop that a write slot holds back keeps its rank, so its port is empty that cycle. This is in the cycle after a multiply or with `p0_hold`, and with 3 or more any-ALU µops ready. It is not in the model; I expect it small, but it is not measured.

## Verification
- **Bench:** `tb_iq2` 0 mismatches, with the new rule for port 0 as its reference; it also dispatches in a flush now.
- **Bug injection:** M860 to M908 on the final RTL, all 49 detected, read before the commit.
- **A redundant condition found:** on the way 1 (`!flush` at a bank's write) went undetected; it turned out to be logically unnecessary and was removed.
- **My mistake:** `grep -v " DETECTED "` also hid the `NOT DETECTED` line. I ran it again keeping every line, and found which one.

## The next measurement
Please run the following on Windows. The first result stays in `output/OOC_IQ2_T15_chain`, so the new one goes to `OOC_IQ2_T15`.

```bash
synth_ooo.bat iq2
```

My estimate is 13 to 15 ns (select about 7 ns, tags 5.7 ns), also before any measurement. Last time's table of readings stands.

The record is section 29.2 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 169. 2026-11-05 20:35:51 JST

```text
iq2 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_IQ2` by rank reached about 15.6 ns at a 15 ns target (WNS −0.619 ns), 8,888 LUTs (no payload).** 5.5 ns faster and 1,080 LUTs fewer than the chain. The unified queue of 24 goes on as it is. The record is pushed (0895bd5; 0 Ref on origin/dev).

## The main paths (15 ns target)

| Class | The chain | Now | Reached |
|---|---|---|---|
| `loop` | −6.097 | **−0.619** | 15.6 ns |
| `guard` | −6.138 | −0.610 | 15.6 ns |
| `wait` | −5.444 | −0.508 | 15.5 ns |
| `free` | −5.776 | −0.153 | 15.2 ns |
| `issue` | −3.480 | +0.141 | 14.9 ns |
| `wk` | −2.836 | +2.658 | 12.3 ns |

The worst path: 2.6 ns to ready, 8.8 ns from rank and grant to the issued tag, 1.7 ns for the tag of fan-out 57, 3.4 ns compare. A little above the estimate of 13 to 15 ns.

## The judgement
- **Margin:** about 4.4 ns against 20 ns, for what building into the core adds. How much that is cannot be told alone, and is measured when blocks join.
- **A price not measured:** the port left empty when a write slot holds a µop back is not in the model.

## The LUT estimate went up
The queue itself 8.9k and the payload estimated at 2.1k (not built) make 11k, over the 9k taken. So the chip's estimate is **about 111k (82 %), over the ceiling of 80 % (107.7k)**. Only the queue is measured; the rest stays an estimate. The numbers in `Doc/STRATEGY`, `Doc/BOARD`, `README` are updated.

## The next step
Most of the LUTs still unknown are decided by loop 2 (register file of 6 writes and 11 reads, bypass, 4 ALUs). Cutting LUTs now, with no measurement of the largest part, may cut the wrong thing. So I recommend **measuring loop 2 first**.

The record is section 29.3 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 170. 2026-11-05 20:40:36 JST

```text
Yes, loop 2
```

<!-- answer -->
**Claude Code's answer**

**`OOO_EXU2` for loop 2 and its harness are done and pushed (979d783; 0 Ref on origin/dev). Simulation passes, but timing and LUTs are not measured yet.** Please run the following on Windows; the results go to `output\OOC_EXU2_T15`.

```bash
synth_ooo.bat exu2
```

## What was made
Stages RR and EX: 4 ALU ports, 2 memory ports, 6 results. The register file is `OOO_PRF`, 80 registers, 6 writes, 11 reads.

From `OOO_EXU`, for 100 MHz, what 20 ns allows was simplified:

| Change | Effect |
|---|---|
| **The bypass from 2 stages to 1** | A result goes into the register file at the same edge as `r_ex`, so RR's second mux and the copies of results go. The model's bypass is the same, so no cost in cycles |
| The register file read in RR, in 1 stage | No need for `OOO_PRF2`'s read in 2 stages |
| Slow operations on port 0 in 1 cycle | `OOO_ALUR` with `STAGE2` = 0: the cost of latency 3 goes |
| An address out in EX, combinational | For block RAM read at the end of EX: load-use 2 needs it |

A jalr runs only on port 0. The model stays at 8.633: no cost visible at this precision.

## Verification
- **Bench `tb_exu2`:** 1,000,000 cycles, 2.7 million results against a reference written from the RISC-V specification, 0 mismatches. Sources about half through EX's mux, half from the register file.
- **Bug injection:** M910 to M952, all 43 detected, read before the commit.
- **Others:** `tb_exu` still passes with the parameter on `OOO_ALUR`.
- **Lint:** no warnings at `-Wall` on `OOO_EXU2` and the harness's lines.

## What to look at in the measurement
My estimates, both before measuring:

- **Timing:** 11 to 14 ns. `OOO_EXU` reached 9.2 ns a stage with 5 results, so I do not expect the limit here.
- **LUTs:** 20k to 25k. STRATEGY's estimate has 21k for the register file and the ALU ports. Above 25k, first look at using the register file twice on the 100 MHz clock.

This harness's result is a little optimistic against the core. A load's data comes from a register, where in the core it comes late in M (measured in loop 3). An address also goes to a register, where in the core it goes on to block RAM.

The record is section 29.4 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 171. 2026-11-05 21:02:59 JST

```text
exu2 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_EXU2` met 15 ns (WNS +0.104 ns). Loop 2 is not the timing limit. But of its 22,972 LUTs, 15,622 are the register file, about twice my estimate of 8k.** I fixed what can go at no cost in cycles and pushed it (5410e33; 0 Ref on origin/dev). Please measure again.

```bash
synth_ooo.bat exu2
```

## The result

| Part | Measured LUTs | Estimate |
|---|---|---|
| Register file (80 registers, 6 writes, 11 reads) | **15,622** | 8k |
| ALU ports and bypass (with `OOO_ALUR`'s 1,130) | 7,351 | 13k |
| Total | **22,972** | 21k |

- **Timing:** Vivado stops when a target is met, so 15 ns is an upper bound; about 5 ns to spare against 20 ns.
- **The worst path:** a write address, 14.7 ns, no logic level, 97 % route. The worst `loop` is 13.8 ns, through min / max's comparison, not on a path CoreMark's operations use.

## Why the register file is large
11 reads need 4 RAM64M a bit (16 LUTs). And as 80 registers go above 64, Vivado made another 64-entry array for the 16 above. So half of the RAM was there for only 16 registers (384 bits × 30 ≒ 11.5k, as measured).

## The change
What is above 64 is now a separate array. The 16 above fit RAM32M, so 16 LUTs a bit become 8.

- **Estimate:** about −2.8k LUTs, about 20.2k in all (not measured).
- **Cycles:** no cost. Today's core with 64 registers is unchanged.

## Fewer registers (not taken now)
I added a limit on physical registers to the model.

| Registers | `-O2` | Against 80 |
|---|---|---|
| 80 | 8.633 | |
| 72 | 8.587 | −0.5 % |
| 64 | 8.425 | −2.4 % |
| 56 | 8.146 | −5.6 % |

64 would save about 5.7k LUTs of RAM, but CoreMark/MHz comes first. It stays as a fallback if the LUTs do not fit.

## Verification
- **A shortfall of the bench fixed:** in bug injection on the new code, "a write without `we`" went undetected, because `tb_prf` drove only address 0 on a port not writing. It now drives any address.
- **Bug injection:** 5 on `OOO_PRF` (M8, M9, M953 to M955), all detected. "A write to x0" is logically equivalent, as register 0 always reads as 0, and was left out.

## The LUT estimate
The chip's estimate (about 111k, 82 %) is updated after seeing this new measurement. If the split goes as estimated it hardly changes, and stays over the ceiling of 80 %.

The first result stays in `output/OOC_EXU2_T15_first`. The record is section 29.5 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 172. 2026-11-05 21:23:47 JST

```text
exu2 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_EXU2` met 15 ns (WNS +0.163 ns) and came down to 20,332 LUTs.** The split took off 2,640 LUTs, close to the estimate of about 2.8k. Loop 2 is done alone. The record is pushed (0ade83d; 0 Ref on origin/dev).

| Part | Before the split | After |
|---|---|---|
| Register file | 15,622 | **12,839** |
| ALU ports and bypass | 7,351 | 7,494 |
| Total | 22,972 | **20,332** |

Timing hardly changes (`sel` +0.969, `loop` +1.093). About 5 ns to spare against 20 ns, for joining blocks and a load's late data. The class `write` found no cells because the arrays have new names; `report_exu2.tcl` is corrected for the next run.

## The LUT estimate
The chip's estimate is about 110k (82 %), **still 2.2k over the ceiling of 80 %**. Only the queue itself (8.9k) and loop 2 (20.3k) are measured. The queue's payload, the front end, renaming, the ROB and the LSU are still estimates.

What can be used if it does not fit:

| Means | LUTs | CoreMark/MHz |
|---|---|---|
| 64 registers | −5.7k or more | −2.4 % |
| 3 ALUs | Not measured | −3.5 % |
| The register file used twice at 100 MHz | Not looked at | No loss expected (not checked) |

## The next step
Next is loop 3 (2 load ports, load-use 2). There is a new problem here. The D$'s block RAM has only 2 ports, and 2 loads use both. So **a store's drain and a fill have to take a port from a load**.

The model does not count this contention yet, so today's 8.63 may be a little high. I first put this limit in the model and check the price, then make the RTL. I recommend measuring through loop 3 and deciding on LUTs together, rather than cutting now.

The record is section 29.6 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 173. 2026-11-05 21:56:59 JST

```text
Yes, loop 3
```

<!-- answer -->
**Claude Code's answer**

**`OOO_LSU3` and `OOO_DCH2` for loop 3 and the harness are done and pushed (348e7cb; 0 Ref on origin/dev). Simulation passes, but timing and LUTs are not measured yet.** Please run the following on Windows; the results go to `output\OOC_LSU3_T15`.

```bash
synth_ooo.bat lsu3
```

## A correction to last time
Last time I wrote that a store's drain and a fill take a port from a load, so the model comes first. That was not needed. **With a copy of the D$'s arrays for each load port**, a load does not wait for a drain or a fill. Block RAM takes about 14 of 365 tiles (estimated), and uses no LUTs. The model's 8.63 stands.

I also changed section 4.6 of STRATEGY, which said "add a second port to today's `OOO_LSU`". Today's `OOO_LSU` is one port on mmRISC-2's D$, so `OOO_LSU2` is the starting point.

## What was made
| Stage | Work |
|---|---|
| E | The address (from `OOO_EXU2`), block RAM read at the end of the stage, a store's data |
| M | Data aligned, tags compared, DTLB, SQ search, the result chosen (`OOO_LSU2`'s M1 and M2 in one stage) |
| W | Complete, wait, miss or walk |

- **Ports:** port 0 handles loads, stores and tries; port 1 only loads.
- **Stores:** one µop, so a load never meets a store without its data.
- **Made simpler by bug injection:** "port 1 never misses" went undetected. Looking into it, a try on port 0 comes to the same. So only port 0 asks for lines and walks. A miss is some cycles slower; this is not in the model.

## Verification
- **Bench `tb_lsu3`:** physical and translated, 600,000 cycles each.
- **Bug injection:** all 51 detected on the final RTL and bench, every line read.
- **Left out of it:** "a try keeps what it was" is equivalent; "a store written lets nobody go" differs only in cycles; the code of M1000 to M1004 is gone.
- **A fault found:** at first `miss_id` also served walks, and 4 pages in a set of the DTLB went round for ever. A separate `walk_id` fixed it.
- **For what was undetected:** checks added to the bench, such as a store not writing a register, and a load that has its result not asking for a line.

There was a mistake of mine too. The bench's new phase did not issue stores left from before, so it failed even with no mutation, and "all 5 detected" then meant nothing. I checked that the unmutated run passes, then ran everything again.

## What to look at in the measurement
My estimates, both before measuring:

- **Timing:** about 14 to 17 ns for stage M. `OOO_LSU2` was 8.1 ns a stage. I expect the SQ's search to be the longest.
- **LUTs:** 4k to 5k. The miss logic is not there yet, so this is not the whole LSU (the budget is 9k with it).

Above 17 ns, I would first try the search and forward by one-hot AND-OR in place of an index. The path writing a load's result into the register file is not in this measurement; it comes on top in the core.

The record is section 29.7 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 174. 2026-11-05 22:51:03 JST

```text
lsu3 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_LSU3` met 15 ns (WNS +0.914 ns, about 14.1 ns), 3,326 LUTs, 14 tiles of block RAM. Load-use 2 with 2 load ports holds.** The part that matters most to CoreMark/MHz is now secured. The record is pushed (95932cf; 0 Ref on origin/dev).

## The result
At the low end of the estimated 14 to 17 ns, and LUTs below the 4k to 5k estimated. The miss logic is not in yet, though.

| Class | Slack at 15 ns | Reached |
|---|---|---|
| `cam` (search, forward, to the result) | +0.914 | 14.1 ns |
| `ok` (into what came of it) | +1.703 | 13.3 ns |
| `tlb` (DTLB, tags compared, way) | +2.436 | 12.6 ns |
| `e_ram` (EX's mux, adder, RAM's address) | +4.813 | 10.2 ns |

The worst path is the SQ's search, as expected. About 5.9 ns to spare against 20 ns, for the write into the register file and joining blocks.

## The 3 loops so far

| Loop | Block | Reached | LUTs |
|---|---|---|---|
| 1 | `OOC_IQ2` | 15.6 ns | 8,888 (no payload) |
| 2 | `OOC_EXU2` | Met 15 ns | 20,332 |
| 3 | `OOC_LSU3` | 14.1 ns | 3,326 (no miss logic) |

All are alone. Vivado stops when a target is met, so those of loops 2 and 3 are upper bounds.

## The LUT estimate
With the LSU far below the 9k taken, the chip's estimate is **about 106k (79 %), just under the ceiling of 80 % (107.7k)**. The miss logic is taken as 1.7k. There is only about 1.7k to spare, and the front end 14k, renaming and control 7k, the ROB 8k and the queue's payload 2.1k stay estimates.

As `OOO_DCH2` replaces mmRISC-2's D$ arrays and hit path, the 12.6k "outside the core" may go down, but that is not counted until confirmed.

## The next step
I recommend loop 4 next, fetch (32 bytes, 3 stages, the override at F2). It is the largest unknown left, and a stage more costs −2.1 %, a large effect on cycles. Today's 3-stage front end is 14.3 ns with 16 bytes (19.1 ns at a 20 ns target), so I expect this to be the tightest.

The record is section 29.8 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 175. 2026-11-05 22:54:26 JST

```text
Yes, loop 4
```

<!-- answer -->
**Claude Code's answer**

**`OOO_FDEC2` for loop 4 and its harness are done and pushed (b26e5f2; 0 Ref on origin/dev). Simulation passes, but timing and LUTs are not measured yet.** Please run the following on Windows; the results go to `output\OOC_FE3_T15`.

```bash
synth_ooo.bat fe3
```

## What is at stake
The model's values (`-O2`).

| Fetch | Model | Difference |
|---|---|---|
| 3 stages, the override at F2 | 8.633 | |
| A stage more after the override | 8.611 | −0.3 % |
| The override a stage later | 8.482 | −1.7 % |
| Both | 8.460 | −2.0 % |
| 3 stages, uBTB of 4,096 | 8.649 | +0.2 % |

Most of the price is the override's bubble, not the stage. A larger uBTB gains next to nothing, so overrides seem mainly to come from a difference in direction prediction.

## Why 3 stages can be had
I had been thinking of way select in F2, which would make F2 about 23 ns. But the arrays are read at the end of F0, so **the data's arrival, the tags' compare and way select can all be done in F1, into registers**. `OOO_TAGE` and `OOO_BTB` already compare in F1. F2 starts from registers and needs none of the arrays' time.

`OOO_FDEC2` is F3 and F4 of `OOO_FDEC` in one stage. The targets' compares run beside the boundaries and the choice, so the levels do not simply add up; I count about 16 on the longest.

## A change of behaviour
A first half at parcel 15 is now kept unless the block ends in a taken transfer. Before, an override dropped it, so an override to "not taken" lost the first half and the back end recovered.

## Verification
- **Bench `tb_fdec2`:** 525,126 blocks (289,224 overrides, 110,073 first halves, 108,406 returns), 0 mismatches.
- **Bug injection:** M1020 to M1057, all 38 detected, read before the commit. Those carried over from `OOO_FDEC` and new ones.
- **Lint:** no warnings at `-Wall`.

## What to look at in the measurement
In `summary_loop.txt`, the `ovr` line decides as follows; these limits are my judgement before measuring.

| `ovr` reaches | Reading |
|---|---|
| About 17 ns or less | 3 stages stay |
| 17 to 19 ns | Possible. Look at the paths, and turn the boundaries from a chain to groups |
| Above 19 ns | The override a stage later (−2.0 %), unless the paths show another way |

If `tab` (the starts to the buffer's table) is long, a register in front of the table does it (−0.3 %, no bubble).

This harness has none of F1 itself (block RAM, tags, way select), TAGE M, the FTQ, or a fetch buffer across blocks (loop 5).

The record is section 29.9 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 176. 2026-11-05 23:13:07 JST

```text
fe3 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_FE3` met 15 ns (WNS +0.018 ns), 5,159 LUTs. Fetch can stay at 3 stages with the override at F2, so the model holds at 8.63 and does not fall to 8.46.** The record is pushed (23b4cbb; 0 Ref on origin/dev).

## The result

| Class | Slack at 15 ns | Levels | Reached |
|---|---|---|---|
| `ovr` (the block to F0) | +0.018 | 18 | 15.0 ns |
| `ras` | +0.357 | 16 | 14.6 ns |
| `ubup` | +0.427 | 14 | 14.6 ns |
| `tab` (the starts to the buffer's table) | +0.783 | 12 | 14.2 ns |
| `cut` | +1.128 | 15 | 13.9 ns |

- **Judgement:** within the limit of 17 ns, so 3 stages stay. Moving the arrays' time to F1 saved 2.0 % of CoreMark/MHz. No register before the buffer's table is needed either.
- **Margin:** a value where the target was met and Vivado stopped; about 5 ns against 20 ns.
- **The worst path:** about 8 ns from a parcel through boundaries, kinds and the count of branches, then the choice's carry chain, the compares' AND-OR, into F0. 18 levels against about 16 counted.

## Not measured yet
F1 itself (block RAM's output, tags' compare, way select), TAGE M and the FTQ are not in it. F1 should fit well within 20 ns, but is not measured.

LUTs: `OOO_FDEC2` 2,716, `OOO_FBUF2` 1,687, `OOO_UBTB2` 765. `OOO_RAS` at 1,173 LUTs for 16 entries is more than expected, to be looked at if LUTs run short.

## The 4 loops so far

| Loop | Block | Reached | LUTs |
|---|---|---|---|
| 1 | `OOC_IQ2` | 15.6 ns | 8,888 (no payload) |
| 2 | `OOC_EXU2` | Met 15 ns | 20,332 |
| 3 | `OOC_LSU3` | 14.1 ns | 3,326 (no miss logic) |
| 4 | `OOC_FE3` | 15.0 ns | 5,159 (no F1) |

All alone; what joining the blocks adds is still unknown.

## The next step
I recommend loop 5 next, the fetch buffer giving 6 instructions across 2 blocks. Today's `OOO_FBUF2` is one block a cycle, a difference of −2.2 % in the model (8.49 against 8.68, compared before the rules changed).

This is the last with a real price. Loop 6 (rename in 1 stage) is −0.5 %, a small difference.

The record is section 29.10 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 177. 2026-11-05 23:14:54 JST

```text
Yes, loop 5
```

<!-- answer -->
**Claude Code's answer**

**I made `OOO_FBUF3` for loop 5, joined it into `OOC_FE3` and pushed (fe732a5; 0 Ref on origin/dev). Simulation passes, but timing and LUTs are not measured yet.** Please run the following again on Windows; the results go to `output\OOC_FE3_T15`. The last result stays in `output/OOC_FE3_T15_fbuf2`.

```bash
synth_ooo.bat fe3
```

## What is at stake
I added a limit on blocks taken a cycle to the model.

| Decode takes a cycle | `-O2` | Max optimization | rv64gc |
|---|---|---|---|
| No limit | 8.633 | 9.445 | 7.393 |
| **2 blocks** | **8.633** | **9.445** | **7.393** |
| 1 block | 8.456 | 9.358 | 7.370 |

**Reading 2 blocks costs nothing**, +2.1 % over 1 block.

## What was made
A second block in flip-flops beside `OOO_FBUF2`'s. Slot j takes from the next block if what is left of this one is not enough. A rare-class instruction still goes alone, and nothing goes beside a block with one.

## A limit on refilling
Refilling is 1 block a cycle. So with short blocks finished each cycle, the second stays empty even with blocks waiting.

I first took that for a fault, but in the steady state there is no loss, as fetch also gives at most 1 block a cycle. Only a backlog drains no faster.

The model drains a backlog 2 blocks at a time, so here alone it is a little more optimistic than RTL. Another read of the RAM (about 260 LUTs) would solve it, but I do not do it until RTL's cycles against the model show a difference.

## Verification
- **Bench `tb_fbuf3`:** slot by slot across 2 blocks, 0 mismatches. 359,068 cycles gave from 2 blocks.
- **Bug injection:** M1060 to M1088 but M1065, all 28 detected, every line read.
- **The 2 undetected:** `cr` in `d1` was a redundant term, removed with it. "No refill as it moves" differed only in cycles, so the coverage is now stricter and catches it.
- **Lint:** no warnings at `-Wall`.

## What to look at in the measurement
My estimates, both before measuring:

- **Timing:** `slot` up about 2 levels from 11.7 ns. I expect F2's `ovr` (about 15 ns) to stay the worst.
- **LUTs:** about +1k to 1.5k. The same harness, so directly comparable with the last 5,159. A new class, `move` (from the second to the first), to look at too.

The record is section 29.11 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 178. 2026-11-05 23:34:12 JST

```text
fe3 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_FE3` with `OOO_FBUF3` reached about 15.3 ns (WNS −0.281 ns), 6,539 LUTs. Loop 5 is done alone, at no cost in cycles.** The record is pushed (1f76bb7; 0 Ref on origin/dev).

## The result
LUTs are +1,380 on the `OOO_FBUF2` version, as estimated (+1k to 1.5k). The worst stays F2's `ovr`, as expected.

| Class | With `OOO_FBUF2` | Now | Reached |
|---|---|---|---|
| `ovr` | +0.018 | −0.281 | 15.3 ns |
| `cut`, `tab` | +1.128, +0.783 | +0.650 | 14.4 ns |
| `slot` | +3.272 | +2.112 | 12.9 ns |
| `dloop` | +9.539 | +2.723 | 12.3 ns |
| `move` (new) | | +2.809 | 12.2 ns |

The buffer's own loop grew from 5.5 ns to 12.3 ns, well within 20 ns.

## Where the 6 loops stand

| Loop | Block | Reached | LUTs | What is kept in the model |
|---|---|---|---|---|
| 1 | `OOC_IQ2` | 15.6 ns | 8,888 (no payload) | 2.4 % against distributed queues |
| 2 | `OOC_EXU2` | Met 15 ns | 20,332 | 3.5 % against 3 ALUs |
| 3 | `OOC_LSU3` | 14.1 ns | 3,326 (no miss logic) | 12.7 % against load-use 3, 8.0 % against 1 port |
| 4, 5 | `OOC_FE3` | 15.3 ns | 6,539 (no F1) | 2.0 %, 2.1 % |
| 6 | Rename of 4 | Not measured | | 0.5 % against a stage more |

**The model so far is 8.633, the RTL estimate about 8.1, about 406 CoreMark/s.** All are alone; what joining the blocks adds is still unknown. The RTL estimate still assumes × 0.94.

## The next step
Loop 6 is not only about timing. `OOO_RENAME2` was made for the distributed schedulers, so it has no busy bits. The unified `OOO_IQ2` compares tags, so it needs `disp_rdy`, saying whether a source is ready already.

So this core's rename needs:

- **Busy bits:** 80 bits, 8 reads, cleared by 9 wakeup tags.
- **Against misses at the DS stage:** a µop between rename and dispatch must not miss a wakeup in between.

The effect on CoreMark/MHz is small (a stage more −0.5 %), but the core needs this. It is the last of the loops; after it comes the judgement of gate S1-A (freezing the configuration).

The record is section 29.12 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 179. 2026-11-05 23:36:26 JST

```text
Yes, loop 6
```

<!-- answer -->
**Claude Code's answer**

**As loop 6 I made `OOO_BUSY`, and pushed `OOC_REN3`, joining rename, busy bits and the unified queue (ac83233; 0 Ref on origin/dev). Simulation passes, but timing and LUTs are not measured yet.** Please run the following on Windows; the results go to `output\OOC_REN3_T15`.

```bash
synth_ooo.bat ren3
```

## Changes from what I said last time
Last time I wrote that something against misses at the DS stage was needed. It is not.

- **No new stage:** `OOO_RENAME2`'s R1 is the stage R as it is, and R2, keeping what did not go, is the DS register. The model's depth stands.
- **No snoop of the DS register:** the busy bits are read in the cycle of dispatch, so wakeups up to the cycle before are in them. That cycle's wakeup is `OOO_IQ2`'s to see.

## What was made
- **`OOO_BUSY`:** 80 bits. Set as a µop enters the DS register, cleared by 9 wakeup tags.
- **`OOO_IQ2`:** now takes gaps, as when only slots 2, 3 are left in the DS register.
- **`OOO_RENAME2`:** 3 outputs added, for what goes on at R1's edge.

## The first join of blocks
`OOC_REN3` differs from the measurements alone so far: it joins blocks. 2 paths are in it that no harness had.

| Path | What |
|---|---|
| `adv` | The queue's room, `disp_ready`, the slots that go, to whether R moves |
| `wake` | The queue's ready bit, the select, the wakeup tag, to the busy bits |

The decoded queue, ROB and LQ / SQ are not joined yet.

## Verification
- **Benches:** `tb_busy`, `tb_iq2` (with gaps) and `tb_rename2` (with the new check), all 0 mismatches.
- **Bug injection:** 62 on the queue, `OOO_BUSY` and `OOO_RENAME2`'s new outputs, all detected, read before the commit.
- **For what was undetected:** "a slot not valid holds a non-speculative µop" was not detected at first, as the bench drove 0 on slots not valid. It now drives any value.
- **A false loop:** lint warned of a combinational loop between `disp_ready` and `go`. It was not a real loop; splitting the description removed it.

## What to look at in the measurement
My estimates, both before measuring:

- **Timing:** `adv` about 11 to 14 ns, `wake` about 15 ns. I expect the queue's own `loop`, 15.6 ns, to stay the worst or close to it.
- **LUTs:** about 13.5k (queue 8.9k, rename 3.1k, busy bits about 1.5k).

With this the loops have gone round. Given the result, I set out the material for gate S1-A (freezing the configuration).

The record is section 29.13 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 180. 2026-11-06 00:08:13 JST

```text
ren3 finished
```

<!-- answer -->
**Claude Code's answer**

**`OOC_REN3` reached about 16.0 ns (WNS −0.953 ns), 13,368 LUTs. Joining the blocks added only 0.4 ns. With this the 6 loops have gone round, so please decide gate S1-A (freezing the configuration).** The record is pushed (2d33efb; 0 Ref on origin/dev).

## The result
`OOO_IQ2` 9,227 LUTs, `OOO_RENAME2` 3,813, `OOO_BUSY` 326. The busy bits came in far below the estimated 1.5k.

| Class | Slack at 15 ns | Reached |
|---|---|---|
| `loop` | −0.953 | 16.0 ns |
| `wake` (ready bit to busy bits) | −0.444 | 15.4 ns |
| `go` (the queue's room to entries) | −0.237 | 15.2 ns |
| `adv` (the queue's room to R's move) | +0.150 | 14.9 ns |

The worst is the queue's own loop, up 0.4 ns from 15.6 ns alone. The 2 new paths are both within 15.5 ns.

## The material for gate S1-A

| Item | Value |
|---|---|
| Model (as built) | `-O2` 8.633, max optimization 9.445, rv64gc 7.391 (today's core `-O2` 5.805) |
| RTL estimate | About 8.1, 406 CoreMark/s (× 0.94 not checked at this width) |
| Timing (asked for 15 ns) | Worst 16.0 ns. About 4 ns to spare against 20 ns |
| LUTs | About 106.5k (79 %) for the chip. 1.2k to the ceiling of 107.7k |

| Loop | Block | Reached | LUTs |
|---|---|---|---|
| 1, 6 | `OOC_REN3` | 16.0 ns | 13,368 (no payload) |
| 2 | `OOC_EXU2` | Met 15 ns | 20,332 |
| 3 | `OOC_LSU3` | 14.1 ns | 3,326 (no miss logic) |
| 4, 5 | `OOC_FE3` | 15.3 ns | 6,539 (no F1) |

Of the LUTs, 43.6k are measured, 23.3k still estimated, and mmRISC-2's parts and LiteX 39.6k. The main estimates: ROB 8k, F1 and decode etc. 7.5k, control 3k.

## What I recommend: freeze the configuration and go to step 1.2
All 6 loops are within reach, each with a fallback of known price. Nothing measured so far asks for a port to go.

3 things are not settled, though:

- **The whole core at 20 ns is not proven:** in the 100 MHz attempt, long paths between blocks appeared in the core when not cut. Today's core also had little to spare at 20 ns (+0.159 ns), so I expect some here too. The 4 cuts proposed before stay in hand.
- **The LUTs have no room:** 1.2k left, with many parts still estimated. Measured at each step. If short, look in order at `OOO_RAS`, 64 registers (−5.7k, −2.4 %), 3 ALUs (−3.5 %).
- **× 0.94 is not checked at this width:** cycles against the model at each step.

## What needs your decision
- **The gate:** if frozen, step 1.2 next is the width as a parameter of `OOO_CORE`. From here today's 2-wide core is actually reworked.
- **Working targets:** RTL 8.0 and board 7.8 are my proposal. RTL 8.0 needs × 0.927 of the model. Say if they should change.

The record is section 29.14 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 181. 2026-11-06 00:11:02 JST

```text
Freeze it and go to step 1.2
```

<!-- answer -->
**Claude Code's answer**

**I recorded the passing of gate S1-A and froze the configuration. As the first piece of step 1.2 (A), I widened today's core, still 2-wide, to ROB 48, LQ / SQ 16 and 12 checkpoints, and pushed it (31af4ee; 0 Ref on origin/dev).** The working targets of RTL 8.0 and board 7.8 stand as well.

## How step 1.2 goes changed
STRATEGY said "the width as a parameter of `OOO_CORE`, with tests at both widths", but that does not fit the blocks built. `OOO_RENAME2`, `OOO_IQ2` and the like are fixed at 4-wide, 6 issues from the start, not parameters of today's blocks.

So it now goes **replacing one at a time, passing lock-step and comparing with the model each time**.

| Piece | What | Model compared with |
|---|---|---|
| **A (done)** | ROB 48, LQ / SQ 16, 12 checkpoints (still 2-wide) | The base with those sizes |
| B | `OOO_RENAME2`, `OOO_BUSY`, 80 registers | The same, no register limit |
| C | Dispatch and commit of 4 (ROB, control) | `w=4` |
| D | `OOO_IQ2`, `OOO_EXU2`, 4 ALUs, register file | 1 LSU port |
| E | `OOO_LSU3`, `OOO_DCH2`, miss logic | 16-byte fetch |
| F | 32-byte fetch, 6 decoded, TAGE M | **8.633** |

C with today's queue may be a dead end, so if it costs more than it teaches, C and D go together.

## The result of A

| CoreMark, no misses | RTL cycles | Model /MHz |
|---|---|---|
| Before | 1,817,188 | 5.805 |
| **A** | **1,806,314 (−0.60 %)** | **5.839 (+0.59 %)** |

The RTL moved as the model predicted.

- **Regression:** `run_core.sh` 0 failures in all runs; `run_coremark.sh` PASS on `OOO_CORE`, `OOO_CPU` and random misses.
- **Registers stay 64:** today's `OOO_RENAME` asks registers − 32 to be a power of two; that goes in B.
- **Not done:** `mutate_core.py` (the core's bug injection) was not run, as only sizes changed. It runs at B.

## The next step
Next, B replaces rename with `OOO_RENAME2` and `OOO_BUSY`. Here a new block first runs inside today's core. The recovery's way (how checkpoints are kept) changes, so joining with `OOO_CTRL` is the main work. Vivado is asked from C on; B does not need it.

The record is sections 29.15, 29.16 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 182. 2026-11-06 00:35:03 JST

```text
Yes, on to B
```

<!-- answer -->
**Claude Code's answer**

**Step 1.2's B is done. I replaced the core's rename with `OOO_RENAME2` and `OOO_BUSY`, 80 registers, and pushed it (c273d9b; 0 Ref on origin/dev).** `OOO_DSREG`'s snoop is gone. `OOO_CTRL` needed no change.

## The result

| CoreMark, no misses | RTL cycles | Model /MHz |
|---|---|---|
| A | 1,806,314 | 5.839 |
| **B** | **1,805,278 (−0.06 %)** | 5.839 |

`run_core.sh` 0 failures in all 12 runs; `run_coremark.sh` PASS. On `OOO_CPU` (the real D$) 1,832,102 cycles.

## A fault found
CoreMark passed at once, but `ls-*` and the arch tests failed. **A load to x0 wrote a free register.** The core takes tag 0 as "no write"; the old `OOO_RENAME` gave tag 0 for no destination, `OOO_RENAME2` the top of the free list. Fixed to 0 at DS.

A fault CoreMark alone did not find, so all 12 runs go at every piece from now on.

## Bug injection
`mutate_core.py` detected 96 of 98, every line read. The other 2:

- **"Every µop reads 2 sources":** only more cycles, no wrong value, so left out with a note.
- **"D2: both taken when only µop 0 goes":** a real fault the tests no longer reach. It needs 11 checkpoints open: with 6 that happened, with 12 no test gets there. That line is rewritten in C, with a directed program opening many branches behind a long operation.

## The next step
C makes dispatch and commit 4 wide. ROB, `OOO_CTRL` and the group are reworked, a larger piece than B.

Today's `OOO_IQ` has 2 writes, so C alone may not reach the model's `w=4`. If building it shows little to gain, it goes with D (`OOO_IQ2`, `OOO_EXU2`). When C is done I will ask for a Vivado run of `OOO_CPU` at 20 ns.

The record is section 29.17 of [Plan/OOC.md](Plan/OOC.md) (Japanese: [Plan/OOC_J.md](Plan/OOC_J.md)).
<!-- /answer -->

## 183. 2026-11-06 13:34:52 JST

```text
Please try again
```

<!-- answer -->
**Claude Code's answer**

The last work was done and pushed (c273d9b; 0 Ref on origin/dev), with nothing uncommitted but the prompt log. I summarized B again (`OOO_RENAME2`, `OOO_BUSY`, 80 registers; 12 runs pass, −0.06 % cycles; the load to x0 found; 96 of 98 detected, the 2 explained) and asked about C again.
<!-- /answer -->

## 184. 2026-11-06 13:35:57 JST

```text
Yes, on to C
```

<!-- answer -->
**Claude Code's answer**

**Before C, I put in C0: the core's `OOO_IQ` replaced by the unified queue `OOO_IQ2` (24 entries, the 2-ALU-port form), pushed (dcf5580; 0 Ref on origin/dev).**

#### Why C0
Today's `OOO_IQ` takes only 2 writes a cycle. Widening dispatch to 4 with it would make the queue the narrowest point and gain nothing. `OOO_IQ2` takes 4 writes and gaps from the start, so it went in first, still 2 wide.

The number of ALU ports (`NA`) and port 5 (`P5`) are parameters. The core runs it with 2 ALU ports and no port 5, with the same port assignment as `OOO_IQ`. The bench passes both forms.

#### Results

| CoreMark, no misses | RTL cycles | Model /MHz |
|---|---|---|
| B (queue 10) | 1,805,278 | 5.839 |
| **C0 (queue 24)** | **1,777,906 (−1.52 %)** | **5.980 (+2.4 %)** |

- **Regression:** `run_core.sh` 12 runs with 0 failures, `run_coremark.sh` PASS.
- **Bug injection:** all 97 detected. "Both taken when only µop 0 goes", out of reach at B, is detected again: with the larger queue, 11 checkpoints open.

#### Against the model
The RTL gained 0.9 % less than the model. Replays in the run without misses went from 215 to 522: more loads go ahead and meet partly overlapping stores. Not examined yet; after C I compare cycles by function.

#### Found on the way
When A widened things, the unused core signal `lsu_st_known` stayed 8 bits (no effect on behavior). The core build turns width warnings off, so it went unnoticed. From now on the core is linted with `-Wall` at each piece too.

#### Next step
C makes dispatch and commit 4: the ROB 4 writes and 4 commits, with `OOO_CTRL`, the LSU's dispatch, the trap unit and the lock-step trace widened to 4. It is the largest piece so far. When C is done I will ask for a Vivado run of `OOO_CPU` at 20 ns.

The record is section 29.18 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)).
<!-- /answer -->

## 185. 2026-11-06 14:48:09 JST

```text
Yes, on to C
```

<!-- answer -->
**Claude Code's answer**

**Step 1.2's C (dispatch and commit of 4) is done and pushed (e77e09d; 0 Ref on origin/dev).** The core renames, dispatches and commits 4 µops a cycle. The 2 ALU ports and the 1 LSU port stay as they are; D and E widen them.

#### What changed
- **D2:** it takes up to 4 µops, one instruction each, from the rotated group. `OOO_FUSE` is out of the core: it makes 2 µops out of 4 slots, so with 4 µops a group there is nothing left for it to pair (ALU + branch pairing has been off since 5.21).
- **`OOO_ROB`, `OOO_CTRL`, `OOO_LSU`:** their width is the parameter `ND` (2 or 4).
  - The ROB has `ND` banks; it writes 4 and commits 4.
  - Control stops a group where its checkpoints would exceed 2 (`OOO_RENAME2` takes no more).
  - The LSU treats stores in earlier slots as older than a load.
- **`OOO_IQPL2` (new):** the payload of `OOO_IQ2`. The queue puts one cycle's µops in different banks, so each bank is a LUT RAM with one write, and no live-value table is needed.
- **Trap and trace:** 6 tval inputs; the commit trace and `tb_core` have 4 slots.

#### Results

| CoreMark, no misses | RTL cycles | Model /MHz |
|---|---|---|
| C0 (2 wide) | 1,777,906 | 5.980 |
| **C (4 wide)** | **1,680,878 (−5.46 %)** | **6.350 (cycles −5.84 %)** |

- **Against the model:** the RTL gains only 0.4 % less than the model, down from 0.9 % at C0.
- **Real D$:** `OOO_CPU` too gains −5.04 %.
- **Regression:** `run_core.sh` 12 runs with 0 failures, `run_coremark.sh` PASS.
- **Lint:** the core passes `-Wall` with only the warnings already there at C0.
- **Bug injection:** 95 in the changed units and 100 in the core, all detected.
  - The rewrite had moved the targets of 23 and 19 mutations; I checked all of them before the run and put them on the new lines.
  - New mutations cover slots 2 and 3.
  - "Both taken when only µop 0 goes", out of reach at B, is detected too.

#### Not done yet
At C0 I said I would compare cycles by function after C. Not done: after D, with 4 ALU ports, it tells more, so I do it then.

#### Request
Before D, please run this on the Windows side (20 ns by default; results in `output\OOO_CPU`):
```bash
synth_ooo.bat OOO_CPU
```
`synth_ooo.tcl` now includes the new `OOO_IQPL2`.

The record is section 29.19 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)).
<!-- /answer -->

## 186. 2026-11-06 17:24:57 JST

```text
OOO_CPU finished.
```

<!-- answer -->
**Claude Code's answer**

**`OOO_CPU` at 20 ns after C came out at WNS −14.114 ns.** The cause was the circuit that chooses the trap's tval, so I rebuilt that circuit and pushed it (e1c2343; 0 Ref on origin/dev). The slack after the fix is not measured yet.

#### Results (the last `OOO_CPU` run was the Rev.02 core)

| After place and route | Rev.02 core | C |
|---|---|---|
| LUTs | 36,445 | **55,164** |
| WNS | +0.159 ns, 25 levels | **−14.114 ns, 44 levels** |

The blocks that grew include the ROB (3,717 → 8,643), the queue (1,545 → 6,154), the LSU (3,361 → 6,029) and `OOO_CTRL` (220 → 2,117).

#### The worst paths
All 100 reported paths end at `OOO_TRAP`'s tval registers.
- **First half:** from the ROB's tail to the dispatch decision takes about 8 ns.
- **Second half:** from there the oldest exception was chosen one port at a time. Each port costs about 6 ns, and C made the ports 6.

#### The fix
The positions of the 6 reports are found at the same time, and all are compared at once to choose the oldest. The result chosen is the same as before.
- **Unit:** `tb_trap` PASS.
- **Bug injection:** all 15 trap mutations detected (4 moved to the new lines, 1 added).
- **Regression:** `run_core.sh` 12 runs with 0 failures; CoreMark PASS with the same cycles.
- **Cycle changes:** in `results/core.txt`, 14 lines of short tests with traps or branches changed cycles. I looked into it: only the draw of the random initial values shifted. With zero initial values, old and new give the same cycles on every test.

#### A slip on the way
During the core's lint I stashed the change to `OOO_TRAP.sv` with `git stash` for a moment by mistake. I restored it at once, but the regression running then might have built in that window, so I stopped it and started again from the beginning. The regression results above are from the rerun.

#### What to expect next
By block, the run shows what is slowest after the tval: inside the ROB (−5.95 ns) and the D$ to the ROB (−5.62 ns). I expect about −6 ns (about 26 ns) to remain after the fix. Many of these start at the ROB's tail, that is, the dispatch decision. Going on to D adds more paths, so I propose measuring again and cutting these before D.

The record is section 29.20 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 187. 2026-11-06 19:05:05 JST

```text
Run started
```

<!-- answer -->
**Claude Code's answer**

Thank you. I appended the English of the last answer and this prompt to PROMPT.md and pushed (68ac9e0; 0 Ref on origin/dev).

I leave the RTL alone while Vivado reads it, so I stop here. Please tell me when the results are out. First I will look at the WNS in `output\OOO_CPU` to check that the tval paths are gone. Then I will pick the next slowest path and cut it. By the current estimate it is the dispatch decision that leaves the ROB's tail, or the path from the D$ to the ROB's exception bits.
<!-- /answer -->

## 188. 2026-11-06 19:37:09 JST

```text
OOO_CPU finished.
```

<!-- answer -->
**Claude Code's answer**

**The second `OOO_CPU` run came out at WNS −0.421 ns, 0.4 ns short of 20 ns.** I cut its worst 2 paths and pushed (d653159; 0 Ref on origin/dev). The slack after the fix is not measured yet.

#### The second run
- **LUTs:** 55,590 (+426)
- **WNS:** −0.421 ns, 26 levels
- The tval paths are gone. Last time I expected "about −6 ns to remain", which was too pessimistic: the placement around the tval chain had dragged the nearby logic along.

#### The 2 paths cut
1. **ROB head → the PRF's LVT (−0.421 ns):** whether the ROB is empty was judged by a subtraction modulo 48 (`used != 0`). It led on to the trap, the kill and the write-back.
   - Now it is a compare: "is head + k not equal to the tail".
   - The commit chain, `trap`, `head_ns` and `head_valid` use it.
2. **ALU 1's WB → CTRL's checkpoint masks (−0.371 ns, 38 levels):** the release of the checkpoint of a branch resolved as predicted came from EX in the same cycle. The path ran through the bypassed operand, the 64-bit branch compare, the misprediction compare and the release.
   - The release now comes from the branch result through a register (`br_valid & ~br_mispred`).
   - A checkpoint lives a cycle longer. Before (6 checkpoints) that cost 2 %; with 12 it costs about 0.1 %.

| CoreMark | C | After the cuts |
|---|---|---|
| g14-o2, no misses | 1,680,878 | 1,682,613 (+0.10 %) |
| `OOO_CPU`, real D$ | 1,704,549 | 1,700,964 (−0.21 %) |

#### Checks
- **Regression:** `run_core.sh` 12 runs with 0 failures; CoreMark PASS.
- **Lint:** no new warnings in the core's `-Wall`.
- **Bug injection:** 42 in the ROB and control units and 101 in the core, all detected.
  - The 3 new mutations: "a µop past the tail commits", "a trap from an empty ROB" and "a mispredicted branch's checkpoint is released too".
  - In the first form, one was not detected. On inspection it was a logically equivalent mutation, so I removed the redundant part from the RTL. The cycles are the same before and after.

#### The paths likely next
Next come ALU 0's EX to the CSRs' `tselect` (−0.201 ns) and the wakeup into `OOO_IQ2` (−0.056 ns). Both are small enough to move with placement.

The record is section 29.21 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 189. 2026-11-06 21:18:51 JST

```text
OOO_CPU finished.
```

<!-- answer -->
**Claude Code's answer**

**The third `OOO_CPU` run came out at WNS −2.097 ns, worse than the last.** I cut the start of the new worst path and pushed (0d8a5c3; 0 Ref on origin/dev). The slack after the fix is not measured yet.

#### The third run
- **LUTs:** 54,795
- **WNS:** −2.097 ns, 27 levels
- The 2 paths cut in 29.21 do not appear.
- **The new worst path:** from the CSRs' privilege level (`priv_r`) to the ROB's exception bits; of its 21.8 ns, 18.0 ns (82 %) is routing.
  - It runs through the interrupt request `irq_pend` (5 LUT levels in the CSRs), the trap, the kill, the LSU, the D$, the LSU's write-back and the completion into the ROB.
  - `priv_r` was also where the worst path into most blocks started.
- **Why it got worse:** I take it that the same long chains were placed differently after small changes: a swing from −0.42 ns to −2.10 ns.

#### What I cut
In `OOO_TRAP`, `irq_pend` and the interrupt's cause go through a register and are used a cycle late. Behavior is unchanged.
- **CSR writes:** what changes interrupt enables and pending bits is a CSR write. It is a non-speculative µop that writes in EX, and `ns_busy` holds interrupts off from the cycle after its issue to the cycle after its commit.
- **Traps and MRET / SRET:** both empty the ROB.
- **External interrupts:** the core's external interrupt inputs are all 0 for now.

#### Checks
- **Unit:** `tb_trap`'s model also takes the interrupt a cycle late; PASS (9,090 interrupts).
- **Regression:** `run_core.sh` 12 runs with 0 failures; CoreMark PASS with the same cycles.
- **Cycle changes:** in `results/core.txt`, 11 lines changed cycles. With zero initial values, old and new give the same cycles on every test, so only the random initial values shifted.
- **Bug injection:** 16 in the trap unit and 101 in the core, all detected.
- **Lint:** no new warnings in the core's `-Wall`.

#### What remains in one cycle
From the trap through the kill, the LSU and the D$ to the completion is still one cycle. If the next run still falls short there, next I make the restore and dispatch not wait on the trap: there is no need to wait, since the next cycle's flush overrides them anyway.

The record is section 29.22 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 190. 2026-11-06 23:00:27 JST

```text
OOO_CPU finished.
```

<!-- answer -->
**Claude Code's answer**

**The fourth `OOO_CPU` run came out at WNS −0.647 ns.** The worst path was exactly the chain that 29.22 described as "still in one cycle", so I cut it and pushed (9fb61fe; 0 Ref on origin/dev). The slack after the fix is not measured yet.

#### The fourth run
- **LUTs:** 54,705
- **WNS:** −0.647 ns, 25 levels
- The paths starting at the CSRs' `priv_r` are gone.
- **The worst path:** it starts at the ROB's head.
  - It runs through the read of the head's done and exception bits (a choice of 48), the trap, the restore held off by the trap, the kill, the LSU, the D$, the write-back and the completion into the ROB (83 % routing).
  - From the same kill there is also a path through the MDU's result to the PRF's LVT (−0.613 ns).
  - The LSU's own `restore` was on this chain too.

#### What I cut
The kill and the LSU's restore no longer wait on the trap or replay of the same cycle.
- **ROB:** a new output `restore_k` (a mispredicted branch is in the ROB): a restore that does not look at the trap.
- **CTRL:** the kill is made from this `restore_k`, which also goes to the LSU. In a cycle where a trap meets a misprediction the kill acts, but the next cycle's flush overrides everything, so it does no harm.
- **Inside CTRL:** the rest of the restore (renaming, the live checkpoints, the DS register) still waits on the trap as before. A first form changed that internal state too and the bench found the difference, so it stays as it was.
- **The ROB's `live()`:** no more subtraction; two compares.

| CoreMark | 29.22 | Now |
|---|---|---|
| g14-o2, no misses | 1,682,613 | 1,682,490 (−0.01 %) |
| `OOO_CPU`, real D$ | 1,700,964 | 1,699,305 (−0.10 %) |

#### Checks
- **Unit:** `tb_rob`, `tb_ctrl` and `tb_lsu` PASS. The benches now check `restore_k` and the kill in a cycle that meets a trap.
- **Regression:** `run_core.sh` 12 runs with 0 failures; CoreMark PASS.
- **Bug injection:** 98 in the ROB, control, LSU and trap units and 101 in the core, all detected.
  - 4 new mutations in the units.
  - "The kill back on the old `restore`" went undetected, but it is the earlier, correct form, so I took it off the list.
  - In the core, one ("LSU: stores never committed") pointed at a line I had changed; I moved it and reran the whole campaign.
- **Lint:** no new warnings in the core's or the harnesses' `-Wall`.

The record is section 29.23 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 191. 2026-11-07 09:02:59 JST

```text
CPU_OOO finished.
```

<!-- answer -->
**Claude Code's answer**

**The fifth `OOO_CPU` run came out at WNS −0.068 ns, 0.07 ns short of 20 ns.** I cut the paths that remained and pushed (66078be; 0 Ref on origin/dev). The slack after the fix is not measured yet.

#### The fifth run
- **LUTs:** 54,764
- **WNS:** −0.068 ns, 21 levels
- Only 16 paths are below 0, all to the write address of one bank of the IQ's payload (`OOO_IQPL2`).
- **The path:** the ROB head's done/exception bits, the trap, CTRL's recovery judgment (`rcv`), whether to dispatch (`d_go`), the IQ's entry assignment, the payload's write address.
- Everything else has slack. The next tightest is from the LSU to the ROB's completion, +0.131 ns.

#### What I cut
Dispatch no longer waits on the trap or replay of the same cycle. Its conditions are just three: not `flush_q`, not in a restore (`restore_k`), and room.
- **ROB:** dispatching in a trap cycle is fine; the ROB's tail goes back to the head.
- **Elsewhere:** the next cycle's flush clears the queue, the LSU and the DS register.
- **Renaming:** still waits on the trap as before.
- **Cycles:** not changed at all on any test (no diff in the result files): what a trap cycle dispatches is cleared in the next cycle.

#### Checks
- **Unit:** `tb_ctrl` PASS. Its model now allows dispatch in a cycle of trap or replay and not in a cycle of `flush_q` or restore.
- **Regression:** `run_core.sh` 12 runs with 0 failures; CoreMark PASS.
- **Bug injection:** 21 in the control unit and 101 in the core, all detected. The new unit mutations are "dispatch in a cycle of restore" and "dispatch in a cycle of `flush_all`".
- **Lint:** no new warnings in the core's `-Wall`.

If the next run meets 20 ns, I go on to D (4 ALU ports). The record is section 29.24 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 192. 2026-11-07 10:31:34 JST

```text
CPU_OOO finished.
```

<!-- answer -->
**Claude Code's answer**

**The sixth `OOO_CPU` run came out at WNS −0.226 ns.** The paths starting at the ROB's head are gone, and only 3 kinds remain below 0. I cut 2 of them and pushed (b9d4bdd; 0 Ref on origin/dev). The slack after the fix is not measured yet.

#### The sixth run (54,463 LUTs)
1. **ALU 1's WB → the ROB's done bits (−0.226 ns, 33 levels):** the path runs through the bypassed operand, the 64-bit branch compare, the misprediction compare and the completion in EX. The rule "a branch resolved as predicted completes in EX, a mispredicted one does not" rode on that compare.
2. **The D$'s tag RAM → the ROB's exception bits (−0.149 ns, 24 levels):** through the hit check and the fill, the LSU's write-back and the load's completion.
3. **ALU 0's EX → tval (−0.043 ns):** the CSRs' illegal-access check itself is the long part. The tval choice has hardly any levels to take out, so I left it this time.

#### What I cut (`OOO_CORE`)
- **Branch completion:** every branch and jalr completes through the registered resolution (a cycle after EX). Branches resolved as predicted are a cycle later too.
- **Load completion:** reported to the ROB a cycle after M. Only the ROB's done bit (commit) is delayed; the register file write and the wakeup are not.
- **Safety:** a late completion does no harm even if its µop was killed or flushed in between.
  - In the ROB, writing a new entry wins over a completion.
  - After a restore or flush, dispatch waits a cycle, so a freed entry is given out again only after the late completion has been written.

| CoreMark | 29.24 | Now |
|---|---|---|
| g14-o2, no misses | 1,682,490 | 1,685,110 (+0.16 %) |
| g14-sflto, no misses | 1,642,805 | 1,634,219 (−0.52 %) |
| `OOO_CPU`, real D$ | 1,699,305 | 1,702,880 (+0.21 %) |

#### Checks
- **Regression:** `run_core.sh` 12 runs with 0 failures; CoreMark PASS.
- **Bug injection:** 103 in the core, all detected. I moved the 2 that pointed at changed lines and added 3 new ones (a mispredicted branch never completes, a branch resolved as predicted never completes, a load's exception a cycle before its completion).
- **Lint:** no new warnings in the core's `-Wall`.

The record is section 29.25 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 193. 2026-11-07 12:06:00 JST

```text
CPU_OOO finished.
```

<!-- answer -->
**Claude Code's answer**

**The seventh `OOO_CPU` run meets 20 ns (50 MHz).** I recorded it and pushed (dd0013b; 0 Ref on origin/dev). D is not started yet.

#### The seventh run
- **WNS:** +0.026 ns, TNS 0, no failing endpoint. Hold (+0.028 ns) and pulse width are met too.
- **Between registers:** +0.698 ns, 19 levels.
- **The overall worst:** from the I$'s response port `ic_resp_data` (6 ns of input delay) to the micro-BTB; it comes from the input-port constraint of measuring out of context.
- **LUTs:** 54,730 (49,850 logic + 4,880 LUT RAM). FFs: 21,721 after synthesis.
- None of the path kinds that were the problem in 29.20 to 29.25 comes near 0.

#### The way there (from C as it was)

| Run | WNS | Cut after it |
|---|---|---|
| 1 | −14.114 ns | the oldest tval chosen in parallel |
| 2 | −0.421 ns | the ROB's emptiness by compares; checkpoint release through a register |
| 3 | −2.097 ns | the interrupt request through a register |
| 4 | −0.647 ns | the kill and the LSU's restore do not wait on the trap |
| 5 | −0.068 ns | dispatch does not wait on the trap |
| 6 | −0.226 ns | branches and loads complete a cycle later |
| **7** | **+0.026 ns** | — |

- Every cut was a chain that going 4 wide had made long within one cycle. Nothing was taken from the configuration.
- The total effect on CoreMark cycles was +0.25 % (1,680,878 → 1,685,110).
- Every time, routing was about 80 % of the delay, and even small changes swapped the worst path. From D on, each step will likely need several Vivado runs.

D is 4 ALU ports, `OOO_EXU2`, a register file of 6 writes and 11 reads, `OOO_IQ2` with `NA` = 4 and a payload with 6 reads. The record is section 29.26 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 194. 2026-11-07 12:11:35 JST

```text
Yes, start D
```

<!-- answer -->
**Claude Code's answer**

**Step 1.2's D (4 ALU ports) is done and pushed (e00808d; 0 Ref on origin/dev).** CoreMark cycles fell 6.70 %. The model, though, predicts 9.6 %, so 2.9 % is still missing. Timing at 20 ns is not measured yet either.

#### Where I departed from the plan (2)
- **µops that branch, jump or use the pc go to ALU0 only.** They are branches, jal, jalr and auipc.
  - So branch resolution (ROB, CTRL, FERS, predictor training) and the pc array's reads all stay 2 ports wide.
  - Measured with a new model option `br_p`, the cost is at most 0.1 % (7.034 → 7.026).
- **`OOO_EXU2` is not used as it is.** I widened to 4 the core's own port circuits, checked through A to C and meeting 20 ns. EXU2's approach (choosing the bypass in RR) is kept for when timing falls short.

#### ALU1..3's operations
In the first form, ALU1..3 were the old ALU1 (add/sub, slt and logic only). Shifts and the rest then piled onto ALU0, and cycles went **up 1.8 %** (ALU0 issued in 75 % of all cycles). So OOO_ALU got a middle configuration `MID`.
- **ALU1..3 (`MID`):** adds shifts, Zba, andn/orn/xnor, sext/zext and czero.
- **ALU0 only:** counts, rotates, min/max, Zbs, bext, orc.b, rev8.

| CoreMark, no misses | RTL cycles | Model |
|---|---|---|
| C (meeting 20 ns) | 1,685,110 | 6.350 |
| **D** | **1,572,276 (−6.70 %)** | **7.026 (cycles −9.6 %)** |

- **Issues per port:** ALU0 848k, ALU1 162k, ALU2 487k, ALU3 998k, LSU 714k.
- **Replays:** 922, up from C's 484.
- **Real D$ (`OOO_CPU`):** −7.2 %.

#### A fault found on the way
With 2 ALU ports as a check, the core hung on its first store. It read the LSU's issue from the queue's port `NAP` instead of port 4. At NAP=4 the two coincided, so D's behavior is not affected. Now it reads port 4 whatever NAP is.

#### Checks
- **Unit:** the ALU benches (including the new `tb_alum`) and the decoder bench PASS.
- **Regression:** `run_core.sh` 12 runs with 0 failures; CoreMark PASS.
- **Bug injection:** 50 in the units and 105 in the core, all detected.
- **Lint:** no new warnings in the core's `-Wall`.

#### Next options
1. **A Vivado run:** `OOO_CPU` at 20 ns. D added read ports and bypass inputs, so I would check this first.
2. **Comparison by function:** look into the 2.9 % gap to the model and the rise in replays by comparing with the model function by function. It has been "after D" since C, and it can run alongside the Windows-side run.

The record is section 29.27 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.3.
<!-- /answer -->

## 195. 2026-11-07 15:25:58 JST

```text
CPU_OOO finished.
```

<!-- answer -->
**Claude Code's answer**

**D's `OOO_CPU` came out at WNS −0.640 ns at 20 ns, with 66,949 LUTs.** I cut the 3 largest of the negative paths and pushed (3953f34; 0 Ref on origin/dev). The slack after the fix is not measured yet.

#### Results
- **LUTs:** 66,949, +12.2k from C. Most of the growth is the PRF (3.6k → 9.6k, 5 writes and 10 reads); the payload went from 0.9k to 1.4k.
- **Negative paths:**
  1. **ROB head → the PRF's LVT (−0.640 ns):** through `restore_k`, the kill, the MDU's result acknowledge, port 0's write and the LVT's choice (5 writes).
  2. **ALU0's EX → tval (−0.377 ns):** the CSRs' illegal check left in 29.25, now worse.
  3. **D$ → the write enable of the PRF's LSU bank (−0.213 ns):** from the hit check through `m_ok` to `rf_valid`.
  4. **Within 0.13 ns of 0:** the fetch buffer, renaming, the payload.

#### What I cut
- **Port 0's PRF write does not wait on the kill:** the MDU has a new output `res_we`. Writing a value into a killed µop's register is harmless, since its tag is not given out again in that cycle. The WB register, completion and wakeup still use `res_valid`.
- **The LSU's PRF write does not wait on the hit:** with a new output `rf_we`, every load in M writes. On a miss the value is wrong, but it goes into that load's own register. The dependents are saved by the replay, and the fill writes the right value later. The bypass keeps `rf_valid`.
- **A CSR µop completes and reports its tval a cycle later:** through a register and a completion port of its own. CSR runs one at a time at the ROB head, so the cost is just one cycle per CSR instruction.

| CoreMark | 29.27 | Now |
|---|---|---|
| g14-o2, no misses | 1,572,276 | 1,570,475 (−0.11 %) |
| `OOO_CPU`, real D$ | 1,580,884 | 1,572,482 (−0.53 %) |

#### Checks
- **Unit:** `tb_mdup` and `tb_lsu` PASS. They now check the relations the new write enables must keep (with `res_valid` there is always `res_we`, and so on).
- **Regression:** `run_core.sh` 12 runs with 0 failures; CoreMark PASS.
- **Bug injection:** 46 in the MDU and LSU units and 109 in the core, all detected. I moved the 8 that pointed at lines rewritten this time and added 7 new ones.
- **Lint:** no new warnings in the core's `-Wall`.

Comparing the 2.9 % gap to the model function by function is not started yet. The record is section 29.28 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 196. 2026-11-07 20:31:59 JST

```text
CPU_OOO finished.
```

<!-- answer -->
**Claude Code's answer**

**D's second `OOO_CPU` run meets 20 ns between registers.** I recorded it and pushed (e23a6f3; 0 Ref on origin/dev).

#### Results
- **Between registers:** +0.144 ns, 21 levels (from the ROB head to the decoded group register's reset). None of the 3 paths cut in 29.28 is below 0 any more.
- **Hold and pulse width:** both met.
- **LUTs:** 67,196.
- **Overall WNS:** −0.217 ns (4 failing endpoints).

#### Why the overall WNS is negative
All 4 failing paths run from the I$'s response port `ic_resp_data` to the micro-BTB's pc register. They come from the harness assuming 6 ns of delay on the input ports.
- The same path was the worst at 29.26 too, when C met timing (+0.026 ns then).
- In the real chip, what drives it is the I$'s block RAM (step 1.7).
- F rebuilds the fetch (`OOO_UBTB2`, `OOO_FDEC2`), so I look at it again there.

So as a core, I think D can be taken to meet 20 ns.

#### LUT outlook
`OOO_CPU` is 67.2k. E (the second LSU port) and F (32-byte fetch, 6 decoded) come next. mmRISC-2's blocks (FPU, MMU, full-size caches) are separate, outside this. The whole-chip budget was set at gate S1-A at about 106.5k.

#### Candidates for next
1. **Comparison with the model by function:** D's gain is −6.7 % in RTL against −9.6 % in the model, a gap of about 3 %. Replays also doubled, from 484 to 922. Going on to E without finding the cause would make the reasons for the gap hard to see.
2. **Go on to E:** put in the second LSU port (`OOO_LSU3`, `OOO_DCH2`).

The record is section 29.29 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 197. 2026-11-07 20:36:31 JST

```text
Compare first
```

<!-- answer -->
**Claude Code's answer**

**The 2.9 % gap to the model came from a difference in the front-end assumption.** D itself got faster just as the model predicts. I recorded it and pushed (cb16579; 0 Ref on origin/dev).

#### How I looked
I added `CORE_BYPC` to `tb_core`. It counts the cycles between commits by the pc of the instruction that ends the interval, the same way as the model's `OOO_BYPC`. Summing these by function from the ELF's symbols, I compared C and D in both RTL and model.

#### What I found
- **Most of the gap was in one function.** Of the 36.8k cycles lost, 28.6k were in `matrix_mul_matrix`.
  - In its inner loop the back end (ALU0, LSU, queue, ROB) waits for nothing.
  - Renaming takes all it is given. Yet in nearly 4 cycles of 10 the front end gives only 1 µop.
- **The cause is the decode width.** The loop's 28 bytes span 3 blocks of 16 bytes. Today's RTL decodes one block a cycle, so an iteration takes 4 cycles. The model's base assumes 2 blocks a cycle: the form OOO_FBUF3 brings in F.
- **With the model at 1 block like the RTL, the gains agree.**

| g14-o2 | C | D | C → D |
|---|---|---|---|
| RTL | 1,685,110 | 1,570,475 | **−6.80 %** |
| model (1 block a cycle) | 1,579,152 | 1,475,215 | **−6.58 %** |
| model (base so far) | 1,574,685 | 1,423,245 | −9.62 % |

The RTL being about 6.5 % slower than the model has been the same since C; D did not add to it.

#### What remains
- **Replays (C 669 → D 922):** almost all in `core_bench_list`'s search loops. Right after the stores that rewrote the list's pointers, loads that meet a store with no address yet are cancelled and replayed at commit. D runs further ahead and meets more of these.
- **`core_bench_state`:** the model shrinks from C to D, but the RTL grows slightly, and the RTL stays 52 % slower than the model in this function. The back end does not wait, and in about 30 % of cycles the front end gives nothing. The cause is not known yet.
- **Start-up and `ee_printf`:** about 15k cycles, not in the model's trace.
- **Added to the model:** `ld_cmt` and `br_cmt` (the completion delays put in at 29.25); their effect is about 0.

#### Proposals
1. Until F, compare with the model at `dec_block=1`.
2. Handle the replays in E (`OOO_LSU3`) as a mechanism that holds a load that was cancelled before until the older store's address is known (a wait table, the model's `ld_wt`).
3. Look at `core_bench_state`'s front end in F.

The record is section 29.30 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.3.
<!-- /answer -->

## 198. 2026-11-07 21:10:49 JST

```text
Go to E
```

<!-- answer -->
**Claude Code's answer**

**I planned E and recorded it (af0fde8; 0 Ref on origin/dev).** No RTL is touched yet.

#### What E is
E replaces `OOO_LSU` (which uses mmRISC-2's DCACHE through OOO_DCAD) with `OOO_LSU3`.
- **What `OOO_LSU3` has:** 2 load ports at load-use 2, a write-back D$ in block RAM (16 KB, a copy of the arrays per port), a DTLB, and tries of loads that had to wait.
- **What it does not have yet:**
  - the miss handling (filling a line, writing back a dirty line)
  - the path for what is not cacheable (tohost, MMIO)
  - AMO, LR, SC

#### The model's estimate (D → E)

| | g14-o2 | g14-sflto | g13-o2-zb |
|---|---|---|---|
| today's front end (1 block a cycle) | −3.8 % | −6.2 % | −3.8 % |
| F's front end | −6.5 % | −7.3 % | −5.8 % |

#### How it goes (each step through lock-step before the next)
- **E1 (OOO_CORE):** replace with `OOO_LSU3`.
  - Turn on the queue's port 5 (the second load).
  - Compute addresses in EX, and put tries in when port 4 is free.
  - Put load results into the bypass and the PRF (6 writes, 11 reads); translation stays off.
  - Take the miss handling's interface out of the core, and build a model of the miss handling (line fills, random latencies, write-backs) on `tb_core`'s side.
- **E1b:** add what is not cacheable and AMO/LR/SC, both at the ROB head, non-speculative, through a port of their own that does not go through the D$.
- **E2 (OOO_CPU):** build the miss handling anew (fills by AXI4 bursts, write-backs of victims, the uncached path on AXI4-Lite, write-backs for FENCE.I). mmRISC-2's DCACHE and OOO_DCAD go.
- **E3:** measure `OOO_CPU` at 20 ns. Then, if the replays seen in 29.30 remain, add the wait table.

Translation (page walks) goes with the MMU in step 1.8, the I$ in 1.7; neither is in E. E1 alone means rewriting both the core's LSU side and `tb_core`'s D$ model.

The record is section 29.31 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)).
<!-- /answer -->

## 199. 2026-11-07 21:17:14 JST

```text
Start E1
```

<!-- answer -->
**Claude Code's answer**

**E1 is done and pushed (d32bb71; 0 Ref on origin/dev).** The core runs on `OOO_LSU3` (with a D$ of its own and 2 load ports). CoreMark got 2.1 % faster than at D.

#### What changed (`OOO_CORE`)
- **LSU:** `OOO_LSU` replaced by `OOO_LSU3` (with the D$ arrays `OOO_DCH2` and the DTLB).
- **Queue:** port 5 (LSU1, loads only) on. The PRF has 6 writes and 11 reads; the bypass has 6 inputs.
- **The LSU's 2 ports:** RR and EX are in the core, and the address is computed in EX. `OOO_LSU3`'s tries go in when the queue leaves LSU0's RR free.
- **Dispatch numbering:** each slot's LQ/SQ number, the boundary of the stores older than a load, and the tails for the checkpoints are now counted in the core.
- **Completion:** completion ports for 2 loads and 1 store; tval for a misaligned access on either LSU port. Translation (page walks) stays off.
- **Miss handling:** moved out of the core (`dc_miss_*`, `dc_tw_*`, `dc_rf_*` and so on).

#### Test bench
- **Miss handling model:** a new `DMissModel` handles line fills and way choice.
- **Memory:** updated by committed stores, so evicting a dirty line needs no write-back.
- **tohost:** the `tohost` that HTIF sets back to 0 leaves a stale value in the D$, so the D$'s line is taken out once the SQ is empty.
  - At first it was taken out too early, before the store had reached the D$, so CoreMark kept reading tohost and hung.
  - Fixed by looking at `sq_drained` 2 cycles after the store's commit.
- **The real path:** this is a bench-side fix; the real path for what is not cacheable is built in E1b.

| CoreMark | D | E1 | model (D → E) |
|---|---|---|---|
| g14-o2 | 1,570,475 | 1,537,421 (−2.1 %) | −3.8 % |
| g14-sflto | 1,534,517 | 1,449,754 (−5.5 %) | −6.2 % |
| g13-o2-zb | 1,644,240 | 1,603,602 (−2.5 %) | −3.8 % |

D was measured with an ideal D$ on which every load hits. E1's numbers are with the real 16 KB one, including the first 578 line fills (cold misses).

#### Checks
- **Regression:** `OOO_CORE`'s 8 runs all with 0 failures; CoreMark's 3 PASS.
- **Runs left out:** `OOO_CPU` is not built until the miss handling (E2) exists. The 4 runs of `run_core.sh` and 1 of `run_coremark.sh` are off; `CPU=1` brings them back.
- **Lint:** no new warnings.
- **Bug injection:** 110 of 113 detected in the core. I moved the 12 that pointed at lines E1 rewrote and added 4 new ones. The 3 not detected:
  - "A mispredicted branch's checkpoint is released too" has been equivalent since 29.21/29.23, so I took it out.
  - "A divide result to x0 is forwarded" and "slots 2 and 3 leave `rob_insn` unwritten" are real faults. E1 changed the timing and today's tests no longer reach those situations. Tests that aim at them are needed.

The record is section 29.32 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.4.
<!-- /answer -->

## 200. 2026-11-07 23:48:59 JST

```text
Go to E1b
```

<!-- answer -->
**Claude Code's answer**

**E1b (what is not cacheable) is done and pushed (52c9374; 0 Ref on origin/dev).** AMO/LR/SC are not done yet; I propose splitting them off as E1c.

#### What changed (`OOO_LSU3`, `OOO_CORE`, `tb_core`)
- **The check:** outside the cacheable range `[CBASE, CTOP)` (today 0x8000_0000 to 0xFFFF_FFFF), and the one line `uc_line` names (the simulation's tohost), is not cacheable.
- **Loads:** once a load is known to be for what is not cacheable, it does not use the D$'s or the SQ's value and waits. When it is the ROB head and the SQ is empty, it goes to read the device through a port of its own. The answer's value goes through M once more to become its result.
- **Stores:** at the end of the drain, written to the device instead of the D$.
- **Device accesses:** one at a time (port `dc_uc_*`).
- **Test bench:** a new `UcModel`. tohost is not cacheable now, and E1's fix of "take out the line once the SQ is empty" is gone.

| CoreMark | E1 | E1b |
|---|---|---|
| g14-o2 | 1,537,421 | 1,536,572 |
| g14-sflto | 1,449,754 | 1,447,730 |

The console's 502 characters became 502 device writes and 502 device reads. D$ line fills also fell from 578 to 75, as E1's fix filled tohost's line again at every character.

#### Checks
- **Unit:** `tb_lsu3` passes as before with the whole space cacheable (its pages include 0x80_8000_0000). The path for what is not cacheable is checked by the core's lock-step.
- **Regression:** `OOO_CORE`'s 8 runs all with 0 failures; CoreMark PASS.
- **Lint:** no new warnings.
- **Bug injection:** 114 of 119 detected in the core. Of the 7 added on the path for what is not cacheable, 3 went undetected (the value taken from the D$/SQ, reading before older stores, reading before being the head).
  - The bench has no device but tohost (plain memory), so reading early gives the same value.
  - Catching them needs a device whose value changes when read (a counter, say) and tests that read it.
  - The 2 left from E1 (a divide result to x0 forwarded, `rob_insn` of slots 2 and 3) are still not reached by the tests either.

#### Not yet done
- **AMO/LR/SC:** the decoder classes them as non-speculative µops of the LSU, but nothing executes them. A-extension tests (rv64ua) are not in the regression either. CoreMark does not need them and Linux (step 1.8) does, so I propose adding them as E1c, before or after E2, or together with the MMU.
- **`OOO_CPU`:** stays out until E2 (the miss handling) is built.

The record is section 29.33 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.4.
<!-- /answer -->

## 201. 2026-11-08 03:05:18 JST

```text
Go to E2
```

<!-- answer -->
**Claude Code's answer**

**E2 is done and pushed (f3b45a9; 0 Ref on origin/dev).** `OOO_CPU` runs with the new miss handling, and mmRISC-2's DCACHE and OOO_DCAD are gone. Timing at 20 ns is not measured yet.

#### A decision: the D$ is written through
`OOO_LSU3`'s arrays have no port to read the data of a line being evicted (the 2 loads use the read ports). So every store written into the D$ is written to memory too.
- **The gain:** no write-back on eviction and none for FENCE.I. A fill just waits for the earlier writes to reach memory.
- **Against 29.31:** 29.31 said write-back, but it is write-through for now. If bus traffic becomes a problem, a read port for the evicted line and dirty bits can make it write-back.

#### `OOO_DMISS` (new)
- **Line fill:** requests go into a queue of 4, a line asked twice once. When the earlier writes are done, the tag of a free or a random way is made invalid and 8 beats are read over AXI4. The words read go into the arrays, the tag is made valid, and `fill_done` is returned.
- **Write-through:** from a queue of 8, one-beat writes on AXI4.
  - At first AW → W → B were waited for one at a time, and `OOO_CPU`'s CoreMark got 12.6 % slower.
  - With the address, data and answer going on apart so that several overlap, the difference from the bench's model shrank to 0.14 %.
- **Devices:** one at a time over AXI4-Lite.
- **FENCE.I:** done once the writes are out.

| CoreMark | D (`OOO_CPU`) | E2 (`OOO_CPU`) |
|---|---|---|
| g14-o2 | 1,572,482 | 1,539,579 (−2.1 %) |

#### The test bench made stricter
- **Write stalls:** the AXI4 memory model now and then stops taking writes for 20 to 50 cycles.
- **Memory check after the end:** after a program ends, 3,000 more cycles run, and then the memory the D$ wrote is compared in full with the memory of the committed stores.
  - In the first form, the loop exited at the end at once and the drain never ran. So the last write had not arrived, and a false mismatch was reported. Fixed.
- **The resulting number:** after adding the write stalls, `OOO_CPU`'s CoreMark is 1,541,084.

#### Checks
- **Regression:** all 12 runs with 0 failures (`OOO_CPU`'s 4 are back); CoreMark's 4 PASS.
- **Unit:** `tb_lsu3` PASS.
- **Lint:** no new warnings.
- **Bug injection:** 120 of 126 detected in the core. OOO_DMISS's mutations run on `OOO_CPU`; 6 of 7 detected.
  - "A fill before the writes reach memory" only shows when a written line is evicted and filled again while its write waits, and the tests do not reach that.
  - Besides, 2 from 29.32 and 3 from 29.33 remain. All are work for aimed tests.

#### What remains
- **AMO/LR/SC (E1c):** not implemented yet.
- **Aimed tests:** to catch the 6 mutations not reached; to be written.
- **Vivado run:** E1 to E2 put the D$'s arrays and search, and the miss handling, into the core and `OOO_CPU`. `OOO_DMISS` is added to `synth_ooo.tcl`.

The record is section 29.34 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.4.
<!-- /answer -->

## 202. 2026-11-08 12:11:52 JST

```text
OOO_CPU run finished.
```

<!-- answer -->
**Claude Code's answer**

**E's `OOO_CPU` came out at WNS −0.144 ns at 20 ns (5 failing endpoints).** I fixed 3 things and pushed (3f48e83; 0 Ref on origin/dev). The slack after the fix is not measured yet.

#### Results
- **LUTs:** 67,392, about the same as D.
  - mmRISC-2's DCACHE (6.5k) and OOO_DCAD are gone.
  - In their place, `OOO_LSU3` (3.2k), `OOO_DMISS` (3.1k) and the PRF (12.3k, 6 writes and 11 reads) grew.
- **Waste found:** `OOO_DMISS` had as many as 7,824 flip-flops. Its copy of the tags did not go into LUT RAM but became flip-flops and selection logic.
- **Negative paths:**
  - from the ROB head's exception bit through the trap and the rename go/no-go to the front end's group register (−0.144 ns)
  - 2 paths that choose a CSR µop's instruction bits in EX from `rob_insn`'s 48 to 1, then go through the CSR decode to the PRF's write data or the CSRs (about −0.13 ns)
- **The I$ port path that was a problem at D:** not among the worst this time.

#### What I fixed
- **Renaming no longer waits on the trap either** (the same treatment as dispatch in 29.24). What renames in a trap cycle is put back to the committed RAT and free list by the next cycle's flush.
- **A CSR µop's instruction bits are read in RR and passed to EX in a register.**
- **`OOO_DMISS`'s copy of the tags is now LUT RAM, one per way.**

#### Checks
- **Cycles:** CoreMark gave exactly the same cycles on every run.
- **Unit:** `tb_ctrl` PASS (its model now renames in a trap cycle too).
- **Regression:** all 12 runs with 0 failures; CoreMark's 4 PASS.
- **Bug injection:** all 21 detected in the control unit. In the core, 120 of 126; the 6 not reached are the same as in 29.34.
- **Lint:** no new warnings.

The record is section 29.35 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 203. 2026-11-08 13:51:39 JST

```text
OOO_CPU run finished.
```

<!-- answer -->
**Claude Code's answer**

**E's second `OOO_CPU` run meets 20 ns (50 MHz).** I recorded it and pushed (87630fb; 0 Ref on origin/dev).

#### Results
- **Timing:** WNS +0.210 ns, TNS 0, no failing endpoints. Hold and pulse width are met too. The worst path is 17 levels, from ALU3's WB register to the PRF's write data.
- **Size:** 63,938 LUTs (−3.4k from the last run), 15,682 FF (−7.4k).
  - `OOO_DMISS` went from 3,135 LUTs and 7,824 FF to 731 LUTs and 355 FF.
  - With the second load port, the D$ arrays and the miss handler in, it is 3.3k LUTs smaller than at D.

#### Where E stands
CoreMark without misses (g14-o2) takes 1,541,084 cycles on `OOO_CPU`. That is −2.0 % from D's 1,572,482, and it meets 20 ns.

#### What is left in E
- **E1c:** making AMO, LR and SC work. Linux (step 1.8) needs them.
- **Directed tests:** to catch the 6 mutations today's tests do not reach (29.32–29.34). They need a device whose reads change it, an eviction and refill while writes wait, and so on.

#### Next candidates
- **F (the 32-byte front end):** the 2.9 % gap from the model found in 29.30 should come back here.
- **E1c and the directed tests:** first, if E is to be closed before F.

The record is section 29.36 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also noted in STRATEGY row 1.6.
<!-- /answer -->

## 204. 2026-11-08 14:02:08 JST

```text
Go to F
```

<!-- answer -->
**Claude Code's answer**

**I made F's plan, wrote it in section 29.37 of Plan/OOC.md and pushed it** (ae66264; 0 Ref on origin/dev). The RTL is not touched yet.

#### What the model shows
Cycles against today's E (g14-o2):

| Stage | CoreMark/MHz | Cycles |
|---|---|---|
| Today's E (16 bytes, one block a cycle, uBTB 8, TAGE S) | 7.049 | base |
| 32 bytes, one block a cycle | 7.759 | −9.2 % |
| 32 bytes, 2 blocks a cycle (`OOO_FBUF3`) | 8.191 | −13.9 % |
| and uBTB 96 (F1) | 8.318 | −15.3 % |
| and TAGE M (F2) | 8.445 | −16.5 % |

- **F is the largest piece of the core.** It is worth far more than the 2.9 % found in 29.30.
- **What the RTL should get:** E's 1,541,084 cycles become about 1,286k after F2, about 7.8 CoreMark/MHz. To reach gate S1-B's 8.0, the 6.5 % gap between the RTL and the model still has to be closed after F.

#### A proposal (your decision)
**6 decoded and the decoded queue are worth 0 in the model.** With 4 renamed, decode of 4, 6 or 8 gives exactly the same cycles (8.445), as the fetch buffer already runs ahead of renaming.

So I propose to keep 4 decoders and today's group of 4. That saves 2 decoders and the queue. Two of `OOO_FBUF3`'s 6 outputs are left unconnected, so 6 can come back later if needed. This changes the configuration fixed in 29.15 (6 decoded), so it is the author's decision.

#### The pieces
- **F1a:** a new `OOO_FETCH2`: `OOO_UBTB2`, the I$ of 32 bytes, TAGE and BTB for 16 parcels, `OOO_FDEC2`.
- **F1b:** the FTQ, `OOO_FBUF3` (4 of its 6 used), the back end's parcel fields from 3 to 4 bits; tb_core's I$ model at 256 bits.
- **F2:** TAGE M.
- **F3:** `OOO_CPU` at 20 ns (to be run by the author).

Also written in STRATEGY row 1.5.
<!-- /answer -->

## 205. 2026-11-08 14:22:30 JST

```text
Yes, start F1a
```

<!-- answer -->
**Claude Code's answer**

**F1a (fetch of 32 bytes) is done.** I recorded it and pushed (9eb6455; 0 Ref on origin/dev). It is not in the core yet; putting it there is F1b. The decoders stay 4, as you approved.

#### What I built
- **`OOO_FETCH2` (new):** F0 to F2 on blocks of 32 bytes.
  - F0 has `OOO_UBTB2` (96 entries), F1 the I$ 32 bytes wide, TAGE and the BTB, F2 `OOO_FDEC2`.
  - The block goes out with "where instructions start" and "the transfer that ends it", which `OOO_FBUF3` uses.
- **`OOO_TAGE2` (new):** the TAGE for 32 bytes. Its sizes are still S; F2 makes them M.
  - In F2 it gives, per slot, "whether a tagged row decides it and which way" and the base's direction by parcel, and takes back the slots `OOO_FDEC2` decided. So the slots' parcels are not on the path that chooses the prediction.
- **Two fixes in `OOO_FDEC2`:**
  - **The slots go back to TAGE in the same cycle.** Before, they came a cycle late, which as it was would have made the history lag 3 blocks, not 2.
  - **The uBTB is also trained when it guessed taken and F2 did not take it.** As it was built, such a conditional branch would have been overridden every time.
- **`OOO_BTB`:** the line width is a parameter.

#### Checks
- **tb_fetch2 (new):** with the default seed it checks 112,732 blocks, 50,126 overrides and 21,305 mispredictions: 0 mismatches. Seeds 1 to 6 also give 0 mismatches.
- **Earlier benches:** tb_fdec2, tb_fetch, tb_tage, tb_predec, tb_btb and tb_front (5 runs) all PASS.
- **Bug injection:** all 66 detected. I read every line and added M1127 to M1152.
- **Lint:** no warnings with `verilator -Wall`.

#### Found on the way
The bench gave a mismatch once, and the cause was a shortcut taken on purpose before (28.22). When a 32-bit instruction's upper half looks like a branch's bits, the 16-bit branch right after it gets its target computed in the 32-bit form. The target is wrong, but the back end fixes it as a misprediction, so correctness holds. It was already checked that CoreMark never executes this pattern. The bench's reference model now follows the same rule.

The record is section 29.38 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also written in STRATEGY row 1.5.
<!-- /answer -->

## 206. 2026-11-08 14:56:12 JST

```text
Yes, start F1b
```

<!-- answer -->
**Claude Code's answer**

**F1b is done: the front end of 32 bytes is in the core.** I recorded it and pushed (8224ab2; 0 Ref on origin/dev). Timing at 20 ns is not measured yet.

#### Cycles (CoreMark, no misses)
| | E | F1b | RTL change | Model change |
|---|---|---|---|---|
| g14-o2 | 1,537,367 | **1,332,422** | **−13.3 %** | −15.3 % |
| g14-sflto | 1,448,830 | 1,228,690 | −15.2 % | −11.7 % |
| g13-o2-zb | 1,604,291 | 1,386,541 | −13.6 % | −13.3 % |

- On `OOO_CPU`, g14-o2 takes 1,336,080 cycles: about 7.5 CoreMark/MHz without misses.
- The gap between the RTL and the model is 10.8 % on g14-o2 (8.4 % at E). I will look at it by function at the end of F2.

#### What changed
- **`OOO_FRONT`:** `OOO_FETCH2` and `OOO_FBUF3` in place of the old blocks. `OOO_FBUF3` got a parameter "give at most 4" (decode stays 4).
- **How the pc is found:** from the line of the block that holds the instruction's last half. `OOO_FBUF3` drops a block in which no instruction starts, so counting by the first half's block, one group could need 3 lines.
- **Core, FTQ, FERS, ROB:** parcel numbers are 4 bits, and the I$ is 256 bits.

#### Faults found and fixed on the way (both in F1a's blocks)
1. **A 4th branch in a block was always predicted not taken.**
   - CoreMark at 16 bytes had no 4th branch, but at 32 bytes it has them. g14-sflto's mispredictions had grown from 4,765 to 14,173.
   - Each time the 4th branch was missed, the wrong path broke the RAS, so the returns after it missed too.
   - I compared the choices in the model and chose to predict by the base counter and train it too. That brought it back to 5,712. It is still 20 % above 16 bytes, and the gap is spread over many branches, so I will look again in F2.
2. **The shortcut that tells a target's form from the bits alone was sending the core down a wrong path.**
   - 28.22 assumed "the back end finds a wrong target", but this core checks neither a branch's target nor a jal's; it trusts predecode.
   - `FDEC2` now takes the form from the instruction boundaries. How much time this adds, F3 will show. If it is too much, there is a fallback: compute both forms and choose by the boundaries (about 800 LUTs).

#### Checks
- **Tests:** 12 regression runs, 4 CoreMark runs, 5 tb_front runs and the unit benches all PASS.
- **Bug injection:** the front end 51 of 51 and the units 136 of 136 detected. The core 119 of 126.
  - 72 and 89 cannot be reached. `FBUF3` always gives a CSR alone in slot 0, so mutations that need a CSR µop in slot 1 or later never show.
  - 107 was not hit this time. It was a mutation only the old front end's timing hit.
  - 100 to 102 and 108 are not reached, as before.
  - Besides, I removed one equivalent mutation (M1154) and its redundant term from the RTL too.
- **Lint:** no new warnings with `verilator -Wall`.

The record is section 29.39 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also written in STRATEGY row 1.5.
<!-- /answer -->

## 207. 2026-11-08 17:54:30 JST

```text
Yes, start F2
```

<!-- answer -->
**Claude Code's answer**

**F2 (TAGE M) is done.** I recorded it and pushed (a9e7900; 0 Ref on origin/dev). With this, all of F's pieces are in, except the check at 20 ns (F3).

#### Cycles (CoreMark, no misses)
| | F1b | F2 | RTL change | Model change |
|---|---|---|---|---|
| g14-o2 | 1,332,422 | **1,311,645** | **−1.6 %** | −1.5 % |
| g14-sflto | 1,228,690 | 1,219,046 | −0.8 % | −0.4 % |
| g13-o2-zb | 1,386,541 | 1,370,745 | −1.1 % | −1.3 % |

- **From E in all:** g14-o2 goes from 1,537,367 to 1,311,645, **−14.7 %** (the model −16.5 %). On `OOO_CPU` it is about 7.6 CoreMark/MHz without misses.
- **Gap from the model:** the RTL stays about 10.7 % above the model (8.4 % at E). I will look at it by function after F3.

#### What changed
- **`OOO_TAGE2`:** TAGE M's sizes behind a parameter; it can go back to S.
  - 6 tagged tables (2,048 rows each), histories 4 to 200, tags 9 to 11 bits.
  - The metadata grows from 290 to 531 bits.
- **The FTQ and the restore path:** widened to match. The history used for the restore is 202 bits.
- **Checked in the model first.** M pays per 32-byte block too: g14-o2's conditional branch mispredictions go from 4,822 to 3,563.

#### Checks
- **Mispredictions (tb_front):** g14-o2 5,345 → 4,041, g14-sflto 5,712 → 4,665. Below 16 bytes with S (5,614, 4,765), and the 20 % gap left at F1b is gone.
- **Tests:** 12 regression runs, CoreMark, 5 tb_front runs and the unit benches all PASS.
- **Bug injection:** the units 28 and the front end 52, all detected (including the 9 new ones). The core's files did not change, so the core's campaign was not run again.
- **Lint:** no new warnings with `verilator -Wall`.

#### Next (F3): `OOO_CPU` at 20 ns
Please run `synth_ooo.bat OOO_CPU`. The new paths in this run are these 4:
- F2 to F0. The target's form now waits for the instruction boundaries, so this may have grown. If it misses, there is a fallback: compute both forms and choose by the boundaries (about 800 LUTs).
- The slots going back to TAGE's history in the same cycle
- The FTQ, now 573 bits
- TAGE M's index made from a history of 200 bits

The record is section 29.40 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also written in STRATEGY row 1.5.
<!-- /answer -->

## 208. 2026-11-08 19:14:31 JST

```text
OOO_CPU run finished.
```

<!-- answer -->
**Claude Code's answer**

**F's first `OOO_CPU` run did not meet 20 ns.** Between flip-flops it is −2.226 ns (25 levels), WNS −5.534 ns. I cut the causes and pushed (2bdcf68; 0 Ref on origin/dev). The effect of the cuts is unknown until the next run.

#### Results
- **Size:** 68,224 LUTs (E: 63,938), 16,797 FF, 24.5 tiles of block RAM (E: 19.5).
- **What WNS −5.534 ns was:** the 6 ns of delay on the I$ answer's input port stood in front of all of F2's levels. By design F2 starts from registers, so I changed the constraint to 1.5 ns. This is recorded as a requirement on the real I$ of step 1.7 (its answer comes from flip-flops).

#### The failing paths and the cuts (none changes the cycles)
| Path | Slack | Cut |
|---|---|---|
| ROB head → fetch's stop → FDEC2's decision → uBTB | −2.226 ns | The late stop taken out of the decision, used only for the block's last enables |
| FDEC2's boundaries → slot count → TAGE's history | −1.690 ns | Boundaries by carry-select over groups of 4 parcels; the slots' test by a prefix OR, not a subtraction; the history's push a cycle later (the readers bypass) |
| IQ room → go → bank assignment → payload | −1.768 ns | Banks counted from the early candidates; the go only enables the writes (dispatch is all or nothing, so the result is the same) |

Paths of −0.2 to −1.4 ns also remained, such as the writes into the PRF. Their details were not in the report, so **I added a report that writes each block's failing paths in full (`timing_blocks.rpt`).** The next run will show them.

#### Checks
- **Cycles:** CoreMark exactly as before (`OOO_CPU` g14-o2: 1,316,322).
- **Tests:** 12 regression runs, 4 CoreMark runs, 5 tb_front runs and the changed units' benches all PASS.
- **Bug injection:** all 140 of the changed blocks' unit mutations detected. One found equivalent was replaced by another, and its redundant term removed from the RTL too. I also retargeted M860 to M867, which had not applied since C0. The core is 119 of 126; the 7 not detected are the same as in 29.39.
- **Lint:** no new warnings with `verilator -Wall`.

The record is section 29.41 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also written in STRATEGY row 1.6.

Please run `synth_ooo.bat OOO_CPU` again.
<!-- /answer -->

## 209. 2026-11-08 21:51:33 JST

```text
OOO_CPU run finished.
```

<!-- answer -->
**Claude Code's answer**

**F's second `OOO_CPU` run reached WNS −0.306 ns, but does not meet 20 ns yet.** Last time it was −2.226 ns between flip-flops. I cut the remaining paths and pushed (b4c14e4; 0 Ref on origin/dev). The effect of the cuts is unknown until the next run.

#### Results
- **Size:** 68,861 LUTs, 16,847 FF, 24.5 tiles of block RAM.
- **The I$ port's path:** gone with the corrected constraint. WNS and the flip-flop value are now the same.
- **New report (`timing_blocks.rpt`):** only the following 2 classes of path were negative.

#### The remaining paths and the cuts (neither changes the cycles)
| Path | Slack | Cut |
|---|---|---|
| Branch result → kill → multiplier's `res_valid` → the MDU's "slot busy" → the PRF's LVT | −0.306 ns (19 levels) | A write `res_we` for the multiplier that does not wait on the kill (as done for the MDU in 29.28; a killed µop's result only goes to its own register, which is harmless) |
| `hpc` (F2's address) → decode of the start → boundaries → override → uBTB | −0.169 ns (21 levels) | The address decoded a cycle ahead, kept in 16 flip-flops |

#### Checks
- **Cycles:** CoreMark exactly as before (`OOO_CPU` g14-o2: 1,316,322).
- **Tests:** 12 regression runs, 4 CoreMark runs, 5 tb_front runs and the changed units' benches all PASS.
- **Bug injection:** all 75 unit mutations detected. The core is 121 of 128; the 7 not detected are the same as before.
- **Mutations tidied:** I checked all 1,060 in `mutate.py` and fixed the 7 of LSU3 that had stopped applying since the rewrite of E1b. Now all apply to today's RTL.
- **Lint:** no new warnings with `verilator -Wall`.

The record is section 29.42 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also written in STRATEGY row 1.6.

Please run `synth_ooo.bat OOO_CPU` again.
<!-- /answer -->

## 210. 2026-11-09 20:56:51 JST

```text
OOO_CPU run finished.
```

<!-- answer -->
**Claude Code's answer**

**The third `OOO_CPU` run meets 20 ns (50 MHz), and F is done.** I recorded it and pushed (4cdd501; 0 Ref on origin/dev).

#### Results
- **Timing:** WNS +0.203 ns, TNS 0, no failing endpoint out of 148,770. Hold (+0.028 ns) and pulse width are met.
- **The worst path:** 19 levels from ALU3's WB register to the PRF's write data, the same place as at E. The new paths F brought are not among the worst 20.
- **Size:** 68,526 LUTs (+4.6k from E), 16,836 FF, 24.5 tiles of block RAM (+5 from E).

| Run | Between flip-flops | LUTs |
|---|---|---|
| 1st (29.41) | −2.226 ns | 68,224 |
| 2nd (29.42) | −0.306 ns | 68,861 |
| 3rd (29.43) | **+0.203 ns** | 68,526 |

#### F's performance now (CoreMark, no misses, `OOO_CPU`, 20 ns)
| | E | F | Change |
|---|---|---|---|
| g14-o2 | 1,541,084 | **1,316,322** | **−14.6 %** (the model −16.5 %) |
| g14-sflto | 1,458,490 | 1,226,653 | −15.9 % |
| g13-o2-zb | 1,607,994 | 1,374,118 | −14.5 % |

g14-o2 is about **7.6 CoreMark/MHz**. It does not reach gate S1-B's 8.0 (with the real caches) yet.

#### What this result assumes
It is met with the I$ answer's port at an input delay of 1.5 ns. The real I$ of step 1.7 has to **give its answer from flip-flops**.

#### Next candidates
- **The 10.7 % between the RTL and the model, by function (recommended):** it was 8.4 % at E. Whether 8.0 can be reached depends on this.
- **E1c (AMO, LR, SC):** Linux (step 1.8) needs them.
- **The real I$ (step 1.7):** built to meet the assumption above.
- **Directed tests:** for the 7 core mutations today's tests do not reach.

The record is section 29.43 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)), also written in STRATEGY rows 1.5 and 1.6.
<!-- /answer -->

## 211. 2026-11-09 21:15:53 JST

```text
Look at the 10.7 %
```

<!-- answer -->
**Claude Code's answer**

**3.4 % of the 10.7 % is in what CoreMark does not time. In the timed part alone the gap is 7.2 %.** But of that I could explain only about 1.3 points; **the cause of the other 6 or so is not known yet.** I recorded it and pushed (3779f07; 0 Ref on origin/dev). The RTL is unchanged.

#### What is in the 10.7 %
The bench's cycles run from reset to the exit, while the model's trace holds the timed part only. Outside it there are 39.8k cycles on g14-o2, mostly printing (`tohost_putc` 23.8k, `ee_printf` 6.0k), the rest the exit and start-up.

From `start_time` to `stop_time` the RTL commits 3,118,899 instructions and the model 3,118,901: nearly the same. In that part:

| CoreMark (no misses) | RTL above | CoreMark/MHz (RTL) | Model |
|---|---|---|---|
| g14-o2 | **7.2 %** | **about 7.9** | 8.44 |
| g14-sflto | 8.0 % | 8.50 | 9.18 |
| g13-o2-zb | 7.8 % | 7.49 | 8.08 |

The 7.6 CoreMark/MHz I gave you last time included the printing. The score CoreMark itself reports would be about 7.9 (g14-o2's timed part, ideal caches). Gate S1-B's 8.0 is about 1.6 % away, and the real caches' loss comes on top.

#### What I measured about the 7.2 %
| Examined | Result |
|---|---|
| Mispredictions (4,046 restores, the model 3,030) | at most 12k cycles, **about 1.0 point** |
| Overrides (82.6k, the model 50.8k) | about 4k cycles, **about 0.3 point** |
| DS "all go or all stay" | a scratch RTL dispatching a prefix gave **−0.09 %**: not the cause; the queue really is full |
| The limit of 80 physical registers | 0 (in the model) |
| Later completion (loads, branches, stores) | +0.15 to 0.18 % (in the model) |
| Replays | 0 in the timed part |

I first thought DS waiting was the main cause; the test showed it is not.

#### The functions furthest off (g14-o2, RTL − model)
| Function | Difference |
|---|---|
| `core_state_transition` | +16.2k (7.6 %) |
| `core_bench_state` | +13.7k (**44 %**) |
| `matrix_test` | +13.2k (16 %) |
| `core_bench_list` | +11.2k (3.4 %) |
| `core_list_mergesort` | +9.4k (20 %) |
| `matrix_mul_matrix_bitextract` | +8.7k (6.9 %) |
| `cmp_idx` | +7.0k (**32 %**) |

#### Proposal
Take the hot loops one at a time, as 29.30 did with `matrix_mul_matrix`, starting with `core_bench_state`, `cmp_idx` and `matrix_test`, whose gaps are large for their size. 8.0 is about 1.6 % away, so one or two causes found here may be enough.

The record is section 29.44 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)); I also added [Plan/model/byfn.py](../Plan/model/byfn.py) for the summing.
<!-- /answer -->

## 212. 2026-11-09 22:07:41 JST

```text
Yes, hot loops
```

<!-- answer -->
**Claude Code's answer**

**I found one cause of the gap: the FTQ (16 blocks) is nearly always full and stops fetch.** With a scratch copy of the RTL at 32 blocks, g14-o2 improves by 1.30 %, and the timed part reaches **7.98 CoreMark/MHz**. I recorded it and pushed (5bdd121; 0 Ref on origin/dev). The repository's RTL is unchanged so far.

#### How I looked
I set the same instructions in the RTL and the model one against one, and compared the times of dispatch, issue, completion and commit. In nearly every function the wait in the queue is shorter in the RTL, and yet dispatch falls behind the model. So most of the loss is before the queue.

#### What I found: the FTQ
A 6-instruction loop of `matrix_test` takes 3 cycles a turn in the model and 4 in the RTL. Cycle by cycle, the requests pass only every other cycle, though the I$ and the fetch buffer are free.

The cause is the FTQ. 16 blocks was chosen when the ROB had 24 entries (D-18); it is not enough with a ROB of 48 and short blocks. In 64 % of the timed part's cycles it had 2 or fewer free. The model has no FTQ, so this was invisible.

| No misses, `OOO_CORE` | FTQ 16 | FTQ 32 | Change |
|---|---|---|---|
| g14-o2 | 1,311,645 | **1,294,645** | **−1.30 %** |
| g14-sflto | 1,219,046 | 1,216,474 | −0.21 % |
| g13-o2-zb | 1,370,745 | 1,360,115 | −0.78 % |
| g14-o2, timed part | 1,269,766 | **1,252,575** | 7.88 → **7.98 CoreMark/MHz** |

- **Checks:** lock-step PASS on the copy (b2's 60 programs and CoreMark). The whole regression and bug injection will be run when it is applied.
- **Cost:** should be small. LUT RAM of 32 rows takes as many LUTs as 16; what grows is 512 FF, their choice, and one bit of the FTQ index.
- **Gap from the model:** the timed part goes from 7.2 % to **5.8 %**.

#### What is left
- **Next suspect (not measured):** groups that split. In the branchy `core_state_transition` the RTL's groups split as 3, 4, 3, 1, 4, 4, 3, 1, none, 3. There is a limit of 2 checkpoints a cycle, and what is left of a group cannot be topped up from the next. The model tops up to 4, so it has no such loss.
- **Functions with the largest gaps left (dispatch falling behind):** `core_state_transition` +16.8k, `matrix_test` +12.3k, `core_list_mergesort` +12.1k, `core_bench_list` +8.9k, `matrix_mul_matrix_bitextract` +8.6k, `core_bench_state` +7.0k.

An FTQ of 32 changes the decision D-18, and I will ask you for another run at 20 ns. 8.0 is still just out of reach before the real caches, and their loss comes on top.

The record is section 29.45 of [Plan/OOC.md](../Plan/OOC.md) (Japanese: [Plan/OOC_J.md](../Plan/OOC_J.md)). I also added the analysis tools (`Plan/model/tl*.py`, `SIM/CORE/acct.patch`).
<!-- /answer -->

## 213. 2026-11-09 22:55:29 JST

```text
Yes, FTQ 32
```

<!-- answer -->
**Claude Code's answer**

I put the FTQ of 32 blocks in the RTL and pushed it to dev (ff19d07). origin has 0 Ref files. Whether it meets 20 ns waits for the Vivado run.

| Cycles | FTQ 16 | FTQ 32 | Change |
|---|---|---|---|
| `OOO_CORE` (no misses) `g14-o2-zbsc` | 1,311,645 | **1,294,645** | −1.30 % |
| `g14-sflto-zbsc` | 1,219,046 | 1,216,474 | −0.21 % |
| `g13-o2-zb` | 1,370,745 | 1,360,115 | −0.78 % |
| `OOO_CPU` (the real D$) `g14-o2-zbsc` | 1,316,322 | **1,298,795** | −1.33 % |
| `g14-sflto-zbsc` | 1,226,653 | 1,224,276 | −0.19 % |
| `g13-o2-zb` | 1,374,118 | 1,363,088 | −0.80 % |

- **Performance:** the three `OOO_CORE` runs equal the scratch copy's to the cycle, so the timed-part result holds as it is: **7.98 CoreMark/MHz** with ideal caches, 5.8 % above the model.
- **Regression:** `run_front` PASS, the 12 runs of `tb_core` 0 failures, CoreMark all PASS in lock-step. Lint: only the warnings from before.
- **Bug injection:** `mutate_front.py` detected 52 of 52. `mutate_core.py` 121 of 128; the 7 not detected (72, 91, 102, 103, 104, 109, 110) are the same as before.
- **Records:** section 29.46 of `Plan/OOC(_J).md`, `Doc/STRATEGY(_J).md`, `Doc/UARCH(_J).md` updated.

F's margin is only +0.203 ns. This adds 512 flip-flops, a 32-to-1 choice and a bit of FTQ index in each µop, so please run `OOO_CPU` again.

```bash
synth_ooo.bat OOO_CPU
```

When it finishes, I will read the results from `FPGA/OOO_OOC/output/OOO_CPU`.
<!-- /answer -->

## 214. 2026-11-10 21:05:14 JST

```text
OOO_CPU finished running.
```

<!-- answer -->
**Claude Code's answer**

With the FTQ of 32 blocks, `OOO_CPU` still meets 20 ns. I recorded it as 29.47 and pushed it to dev (2653bf4). origin has 0 Ref files.

| | FTQ 16 (29.43) | FTQ 32 | Change |
|---|---|---|---|
| WNS | +0.203 ns | **+0.447 ns** | |
| Between flip-flops | +0.203 ns | **+0.493 ns** | |
| LUTs (whole) | 68,526 | 69,887 | +1,361 |
| FF after synthesis | 16,836 | 17,419 | +583 |
| `OOO_FRONT` LUTs / FF | 12,627 / 3,605 | 13,847 / 4,141 | +1,220 / +536 |
| `OOO_FTQ` LUTs (LUT RAM) | 1,382 (472) | 1,826 (472) | +444 (0) |

- **Timing:** TNS 0, hold +0.028 ns. The worst path is of the same kind as before: 31 levels from ALU 2's WB to the register file's write data. No FTQ path is in the top 20.
- **Cost:** as expected, the FTQ's LUT RAM does not grow. What grows is mainly the 512 flip-flops of the slots' outcomes in `OOO_FRONT` and their choice. The other blocks move by a few hundred LUTs from placement.
- **Where it stands:** at 20 ns `g14-o2` takes 1,298,795 cycles (`OOO_CPU`, the real D$). With ideal caches the timed part is **7.98 CoreMark/MHz**.

The record is section 29.47 of `Plan/OOC(_J).md` and rows 1.5 and 1.6 of `Doc/STRATEGY(_J).md`. The gap to the model is still 5.8 %. The next suspect is "dispatch groups that split", not measured yet.
<!-- /answer -->

## 215. 2026-11-10 21:15:49 JST

```text
Yes, groups
```

<!-- answer -->
**Claude Code's answer**

Groups that split cost about 0.4 %; they are not the main cause of the gap. I recorded it as 29.48 and pushed it to dev (f50082c). origin has 0 Ref files.

**Slots the RTL loses** (timed part, `g14-o2`, FTQ 32):

| Cause | Slots lost |
|---|---|
| The back end not free (mainly the IQ, 214,324 cycles) | 1,131,232 |
| A group's leftover renamed alone | 204,507 |
| No group (after a redirect or override) | 143,300 |
| A short group ending with a taken branch | 110,956 |
| The rename not ready | 92,260 |
| A checkpoint's id still in use | 60,422 |
| At most 2 checkpoints a cycle | 51,082 |

"Leftover alone" is 200k slots, but most of it comes when the back end could not have taken more anyway.

**Reproduced in the model:** I added two options to the model (off by default).
- `grp=1`: groups formed as the RTL does.
- `ck_rr=1`: checkpoint ids used in turn, as in the RTL.

| Model (F's configuration) | Before | `grp=1` | `ck_rr=1` | Both |
|---|---|---|---|---|
| `g14-o2-zbsc` | 1,184,347 | +0.42 % | +0.05 % | +0.49 % |
| `g14-sflto-zbsc` | 1,089,510 | +0.31 % | +0.01 % | +0.33 % |
| `g13-o2-zb` | 1,237,838 | +0.44 % | +0.08 % | +0.50 % |

- **Decision:** I do not propose topping the RTL's group register G up from the R that follows. It would move about 120 bits of decoded fields per slot 4 ways, in D2's path, for only 0.4 %.
- **Checked on the way:** the IQ frees its entries at the same time as the model.
- **Where the gap stands:** with both options the gap to the model in the timed part goes from 5.8 % to **5.2 %**. Mispredictions are up to 1.0 point of it and overrides 0.3. About 3 points are not explained yet.

The record is section 29.48 of `Plan/OOC(_J).md`. The model changes are in `Plan/model/ooo.h` and `model.cpp`.
<!-- /answer -->

## 216. 2026-11-10 21:29:49 JST

```text
Yes, the 3 points
```

<!-- answer -->
**Claude Code's answer**

(None: the turn was cut off while the model runs were going.)
<!-- /answer -->

## 217. 2026-11-10 21:37:01 JST

```text
Please try again
```

<!-- answer -->
**Claude Code's answer**

(None: the turn ended while the split-store runs were going in the background.)
<!-- /answer -->

## 218. 2026-11-10 21:39:11 JST

```text
Please try again
```

<!-- answer -->
**Claude Code's answer**

(None: a model run with `sd_alu=1` on the unified queue never ended and used up the memory; the VM rebooted.)
<!-- /answer -->

## 219. 2026-11-10 21:50:02 JST

```text
Please try again
```

<!-- answer -->
**Claude Code's answer**

About 2 of the 3 points are explained by four RTL rules the model did not have. About 1 point is left unexplained. I also found a change that could cut the RTL's cycles a lot. I recorded it as 29.49 and pushed it to dev (5905b57). origin has 0 Ref files; the RTL is unchanged.

**First, an apology.** The two "Please try again" in a row were caused by my model runs. `sd_alu=1` became a loop without end on F's unified IQ, used up the memory, and the VM rebooted. The scratch files were lost, but the numbers needed were still in this conversation. I fixed it with code for the unified IQ, and from now on every model run has a memory limit. I also wrote this pitfall into memory.

**RTL rules added to the model** (`g14-o2`, each on top of the ones before):

| Option | The RTL's rule | Step |
|---|---|---|
| `grp=1`, `ck_rr=1` | how groups are formed, checkpoint ids in turn (29.48) | +0.49 % |
| `ck_stop=1` | after the second branch, not even a non-branch goes in that cycle | +0.24 % |
| `regs=72` | no renaming unless 8 or more registers are free | +0.55 % |
| `lsu_cmt=2 br_cmt=1` | loads and stores complete 2 cycles later, branches 1 | +0.30 % |
| `sa_lag=1` | a load issues only from the cycle after an older store's issue | **+1.63 %** |

The model with all of them (from now on "the RTL's model") takes 1,222,750 cycles, **2.4 %** below the RTL. Of that, mispredictions are up to 1.0 point and overrides 0.3, so about 1 point is unexplained.

**Candidates to win it back** (measured on the RTL's model):

| Change | `g14-o2` | Cost |
|---|---|---|
| **Split stores**: the address issued without waiting for the data, the data written into the SQ later through an ALU issue slot | **−3.84 %** | a store issues twice, a write port for the SQ's data, a way to hold a load that meets a store waiting for its data |
| A load issued in the same cycle as an older store | −1.61 % | inside the wakeup-select loop, so 20 ns gets hard |
| 88 registers | −0.54 % | a larger register file and free list |

- **Why split stores:** in "read, change, write" loops such as `matrix_test` and the CRCs, the next load now waits for a store that waits for its data. `sflto` −3.20 %, `g13` −3.65 %. If the RTL gets what the model does, the timed part reaches about **8.3 CoreMark/MHz** with ideal caches (7.98 now).
- **Condition:** a load that meets a store without its data must wait for that data in the IQ. Replaying it at commit makes things 1.6–3.2 % worse than now.

Splitting stores is an RTL change of E's size.
<!-- /answer -->

## 220. 2026-11-10 22:13:43 JST

```text
Please try again
```

<!-- answer -->
**Claude Code's answer**

The previous answer had run to the end, and 29.49 is pushed (5905b57). There was no VM reboot this time. The app's restart seems to have kept the answer from showing, so here are the main points again. I also committed the prompt log (e168864). origin has 0 Ref files.

**What the 3 points are:** four RTL rules the model did not have explain about 2 points (`g14-o2`, each on top of the ones before).
- After the second branch, not even a non-branch goes in that cycle (`ck_stop`): +0.24 %
- No renaming unless 8 or more registers are free (`regs=72`): +0.55 %
- Loads and stores complete 2 cycles later, branches 1: +0.30 %
- A load issues only from the cycle after an older store's issue (`sa_lag`): **+1.63 %**

"The RTL's model", with 29.48's way of forming groups too (+0.49 %), is only **2.4 %** below the RTL. Of that, mispredictions are up to 1.0 point and overrides 0.3, so about 1 point is unexplained.

**Candidates to win it back** (measured on the RTL's model):

| Change | `g14-o2` | Cost |
|---|---|---|
| **Split stores** (the address issued without waiting for the data, the data written into the SQ later through an ALU issue slot) | **−3.84 %** | a store issues twice, a data write port in the SQ, a way to hold in the IQ a load that meets a store waiting for its data |
| A load issued in the same cycle as an older store | −1.61 % | inside the wakeup-select loop, so 20 ns gets hard |
| 88 registers | −0.54 % | a larger register file and free list |

Splitting stores speeds up "read, change, write" loops such as `matrix_test` and the CRCs. With ideal caches the timed part should reach about **8.3 CoreMark/MHz** (7.98 now). But if a load that meets a store waiting for its data is replayed at commit, it gets worse than now. As an RTL change it is about the size of E.

The two "Please try again" before that were because my model run used up the memory and rebooted the VM. The cause is fixed, and model runs now have a memory limit.
<!-- /answer -->

## 221. 2026-11-10 22:14:50 JST

```text
Yes, plan it
```

<!-- answer -->
**Claude Code's answer**

I planned splitting stores as step G and wrote it into row 1.5b of `Doc/STRATEGY(_J).md` and section 29.50 of `Plan/OOC(_J).md`. It is pushed to dev (e8c29d6). origin has 0 Ref files, and nothing in the RTL has changed yet.

**What to do with a load that meets a store without its data** (measured on 29.49's RTL's model):

| Way | `g14-o2` | `g14-sflto` | `g13-o2-zb` | Replays |
|---|---|---|---|---|
| Wait exactly for the data (ideal) | −3.92 % | −3.26 % | −3.73 % | |
| Only replay at commit | +2.11 % | +3.55 % | +1.51 % | 3,859 |
| **Replay + a wait table of 256 bits by pc** | **−3.67 %** | **−2.61 %** | **−3.65 %** | 8 |

- **The way chosen:** the wait table (the idea of the Alpha 21264). A load replayed once waits from then on in the IQ until the older stores have their data. There are only 8 to 20 replays in a whole run, so it nearly reaches the ideal.
- **The RTL's way can be kept:** it rides on today's IQ without a cancel and its replay at commit. The LSU already has a way to hold a µop and try it again.
- **The model was fixed too:** the trace now carries each load's and store's size, and the match is by bytes as in the RTL (`st_bytes=1`). By the 8-byte word, as before, a load of `a[i+1]` was caught by the store of `a[i]` and waited too much.

**The pieces** (each through lock-step before the next):
- **G1 `OOO_LSU4`:** a data valid bit and a write port in the SQ. A load that meets a store without its data waits and is replayed at commit.
- **G2 `OOO_IQ3`:** a store issues twice (the address on port 4, the data on ALU port 3). A load with its table bit set gets a second wait.
- **G3 the core:** the data path from ALU 3 to the LSU, and the wait table (read in D2, set at commit). Checked with the 12 runs, CoreMark and bug injection.
- **G4:** `OOO_CPU` at 20 ns (I will ask you).

**Expected:** the timed part from 1,252,575 cycles to about 1,206,600, **about 8.28 CoreMark/MHz** with ideal caches (7.98 now). What step 1.7's real caches may lose becomes about 0.3. The cost in LUTs is not measured yet.
<!-- /answer -->

## 222. 2026-11-11 21:48:07 JST

```text
Yes, start G1
```

<!-- answer -->
**Claude Code's answer**

G1 is done. `OOO_LSU4` (the LSU with stores split) passes its bench `tb_lsu4`, and bug injection detected 65 of 65. I recorded it as 29.51 and pushed it to dev (8c10657). origin has 0 Ref files. It is not in the core yet.

**What changed in `OOO_LSU4`** (from `OOO_LSU3`):
- **A store's issue:** a store's µop on port 0 carries its address alone. The data comes on a port of its own and is written into the SQ at the end of that cycle, with a data valid bit an entry.
- **A store's completion:** it completes when address and data are both there. A store whose data came later reports it through the same completion port in a free cycle, so the ROB gets no more ports.
- **A load waiting for data:** a load that meets a store without its data waits. When the data is written it is tried again, and replayed at its commit. That it waited for data is reported, for G3's wait table.
- **A mistake of mine found on the way:** the first version cleared the valid bit when the store left, and a load that met a draining store waited for nothing. It now clears it at the allocation.
- **Terms removed:** four terms that bug injection showed doing nothing (the data's branch mask among them).

**The bench `tb_lsu4`** (PASS, 2 modes × 600,000 cycles):
- Each store's data comes at a random time, before or after its address. Data of stores being killed is mixed in.
- A time with only "a store whose data is 60 cycles late + a load of the same address": the load must complete within 12 cycles of the data (805 pairs physical, 814 translated).

**A hole in `tb_lsu3` too:** an input, `uc_done`, was never driven. In runs where it started at 1, the LSU's retry event stood in every cycle and event bugs could not be seen. That is why the bench's counts and the campaign results changed from run to run. I fixed both benches and checked that `OOO_LSU3`'s 51 are all detected. I also wrote this pitfall into memory.

The next, G2, is the IQ that issues a store twice (`OOO_IQ3`).
<!-- /answer -->

## 223. 2026-11-11 22:42:18 JST

```text
Yes, start G2
```

<!-- answer -->
**Claude Code's answer**

G2 is done. `OOO_IQ3` (the IQ that issues a store twice) passes its bench `tb_iq3` with 0 mismatches, and bug injection detected 81 of 81. I recorded it as 29.52 and pushed it to dev (9feb326). origin has 0 Ref files. It is not in the core yet.

**What changed in `OOO_IQ3`** (from `OOO_IQ2`):
- **A store's issue:** a store issues twice from one entry: its address on port 4 when its base is ready, its data on port 1 when the data is ready. Either may go first, or both in one cycle. The entry leaves when both have gone.
- **A change from the plan:** the data goes on **port 1**, not port 3 as planned. The data takes the port before the ALU µop that would come to it, which then waits a cycle. Port 1 is the third of the 4 ALU ports to fill, so what waits is the third oldest µop, not the oldest. The data's choice runs beside the rank's computation, not after it.
- **The loads' waits:** a load may issue from the cycle after the older stores' addresses went. A load that the wait table marks waits for the data too. Both are registers outside the wakeup-select loop, as now.
- **What does not change:** a non-speculative store (AMO and such, later) is not split; it goes once, as before.

**The bench `tb_iq3`:** I added the two issues and the waits to `tb_iq2`'s reference model, which computes exactly what must issue each cycle. The first failure was the bench's own mistake: a store that gave its address and data in the cycle a kill took it was removed twice, and a tag in use was given out again. After the fix, 400,000 cycles with 22,959 stores' data issued, 0 mismatches.

Next, G3 builds the data path from ALU1 to the LSU and the wait table, and puts `OOO_IQ3` and `OOO_LSU4` in the core.
<!-- /answer -->

## 224. 2026-11-11 23:11:07 JST

```text
Yes, start G3
```

<!-- answer -->
**Claude Code's answer**

G3 (stores split, put in the core) is done and pushed to dev (6e30e65). origin has 0 Ref files. Timing at 20 ns (G4) is not checked yet.

**Tests**
- run_core passes all 12 runs, and run_coremark passes all 4 configurations.

**CoreMark cycles (F → G3)**

| Configuration | F | G3 | Change |
|---|---|---|---|
| OOO_CORE, ideal caches, g14-o2 | 1,294,645 | 1,253,413 | −3.18 % |
| OOO_CPU, real D$, g14-o2 | 1,298,795 | 1,257,666 | −3.17 % |

- The timed part is about **8.26 CoreMark/MHz**, up from 7.98. It is an estimate that subtracts the outside part as measured at F, 42,070 cycles. It is 0.4 % from the model's 8.28.
- Replays barely moved (534 → 538): the wait table is working.

**Bug injection**
- 131 of 137 detected. The 10 added for G3 are all detected.
- The 6 not detected are the same ones as in the last campaign.
- In the first run, removing the `ex_v[1]` term from `sd_v` was not detected, so I removed that term. `iss_sd` is 1 only when something issues, so the term matters only for a store killed in RR or EX. Its write then goes to a free SQ entry, which is harmless for the same reason as when the kill and flush terms were removed.
- This removal changed only g14-sflto, slightly (OOO_CORE −42, OOO_CPU +478 cycles). The data write is now an LSU4 event, which shifts when waiting loads are tried again.

**Records**
- I wrote Plan/OOC(_J).md 29.53, marked STRATEGY 1.5b "G3 done", and updated the README rows for OOO_CORE, OOO_CPU, LSU4 and IQ3.

**Next (G4)**
- Please run `synth_ooo.bat OOO_CPU` at 20 ns.
- The new paths are the data register, port 1's `sd` bit and the wait table's read. All three are short, so I do not expect much worse timing.
<!-- /answer -->

## 225. 2026-11-12 22:54:31 JST

```text
The OOO_CPU run has finished.
```

<!-- answer -->
**Claude Code's answer**

OOO_CPU meets 20 ns. G needed no extra fixes; it passed in one run. That finishes G4, and with it all of step G (stores split).

**Result (against F, 29.47)**

| Item | F | G | Difference |
|---|---|---|---|
| WNS (between flip-flops) | +0.447 ns (+0.493) | **+0.411 ns** (+0.606) | |
| LUTs (after place and route) | 69,887 | **70,845** | +958 |
| of which logic / LUT RAM | 57,451 / 12,432 | 59,105 / 11,736 | +1,654 / −696 |
| FF (after synthesis) | 17,419 | 17,483 | +64 |

- Hold is +0.028 ns, and pulse width is met too.
- The added LUTs are mainly IQ3's two issues and waits, and LSU4's data port. The register file's read ports went from 11 to 10, which lowered the LUT RAM and roughly offsets the wait table (it is in LUT RAM).
- The worst paths are the same kinds as at F (WB into the register file, the front end's history, the TAGE's update). No path through the store's data, port 1's `sd` bit or the wait table is near the top.

**Step G in sum**
- −3.18 % cycles, about 8.26 CoreMark/MHz in the timed part (an estimate with ideal caches), at 20 ns, for about 0.9k more LUTs.
- OOO_CPU uses 70.8k of gate S1-A's budget of 106.5k LUTs.

**Records**
- I wrote Plan/OOC(_J).md 29.54, updated STRATEGY 1.5b (G done) and 1.6, and logged answer 224 and prompt 225 in PROMPT.md.
- Pushed to dev with the Vivado reports (0eb2946, 65aca1f). origin has 0 Ref files.

**Next candidates**
- Step 1.7, the real I$ and L2. Gate S1-B asks 8.0 CoreMark/MHz with the real caches, which leaves about 0.26 for the caches to lose.
- E1c: AMO, LR and SC are still open.
<!-- /answer -->

## 226. 2026-11-12 23:03:13 JST

```text
By the way, is the D$ write-through or write-back? What was the reason for that choice?
```

<!-- answer -->
**Claude Code's answer**

The D$ is **write-through**. That was decided at E2 (Plan/OOC.md 29.34, 2026-11-08). Before that, OOO_LSU3 was designed as write-back, and 29.31 still called it write-back.

**Why**
- The D$'s data arrays (OOO_DCH2) have one copy per load port.
- Each copy's read port is used by its load port, so no read port is left to read the words of a dirty line being evicted.
- Write-back would need a third read port or another copy, which costs block RAM and timing.
- So every store the D$ takes also goes on to memory (OOO_LSU3's `wt_*`).

**What write-through made simple**
- An eviction has nothing to write back.
- FENCE.I has nothing to flush; it is done when all writes have reached memory.
- A fill only waits for the writes before it to reach memory.

**What it costs**
- One CoreMark run puts about 147k one-beat writes on the bus (against 75 line reads).
- So OOO_DMISS got an 8-entry write queue, with the address, the data and the answers going separately so that several are out at once. Issued one at a time, CoreMark was 12.6 % slower than OOO_CORE.

**Later**
- 29.34 says write-back can come back if the bus traffic becomes a problem, by adding a way to read the evicted line and a dirty bit per line.
- Once step 1.7 puts in L2, the L2 takes the write-through traffic. That gives the common arrangement of a write-through L1 and a write-back L2. It will be decided again when the L2 is designed.

Answer 225 and prompt 226 are logged in Doc/PROMPT.md. They will be committed with the next piece of work.
<!-- /answer -->

## 227. 2026-11-12 23:06:30 JST

```text
Let's revisit the D$ later.
First, please go on to step 1.7.
```

<!-- answer -->
**Claude Code's answer**

I wrote the step 1.7 plan in Plan/OOC(_J).md 29.55 and STRATEGY 1.7, and pushed it to dev (35a73ee). origin has 0 Ref files. No RTL is written yet.

**What I found**
- CoreMark's timed part touches few lines, 61 of code and 42 of data on g14-o2, so it fits in the caches.
- So a real I$ and L2 only add the first loads (cold misses): about 5k cycles on g14-o2, about −0.4 %, an estimated 8.22 CoreMark/MHz.
- The L2 does not speed up CoreMark. It matters for Linux.
- **The risk is the writes.** The D$ is write-through, so the roughly 147k one-beat writes of one CoreMark run all go into the L2.
- mmRISC-2's L2 handles one request at a time and passes a partial write on to memory, waiting for the answer. It was built for a write-back D$, and as it is it would use up all of the margin to 8.0.

**The plan (H1 to H4)**
- **H1 `OOO_ICACHE` (new)**
  - The same timing as today's bench model: a request taken at F0, the tags compared and the way chosen at F1, 32 bytes given from flip-flops at F2.
  - **32 KB (64 sets × 8 ways) recommended.** It takes as many block RAMs as 16 KB, and g14-sflto's misses go down 37 %. With 64 sets the index stays inside a 4 KB page, so step 1.8's ITLB fits without aliases.
  - FENCE.I clears the valid bits in one cycle.
  - A unit bench and bug injection.
- **H2 L2**
  - mmRISC-2's `CPU_L2`, reused: 256 KB, proven on the board with Linux.
  - The change: a partial write that hits is written into the L2 and answered at once, pipelined if needed.
  - An arbiter so that the I$ and the D$ share the L2.
- **H3 into `OOO_CPU`**
  - The bench's memory gains the board's latency (25 to 45 cycles to the first beat); the timed part of that CoreMark run is the gate's number.
- **H4 20 ns**
  - The timing check is yours again.

**Estimated cost**
- About +2.3k LUTs, OOO_CPU about 73k.
- About 125 tiles of block RAM, out of 365.

**Left for later**
- The D$'s write policy, as you asked. It is tied to H2, though: if H3 shows the writes cost too much, that question comes first.
- E1c (AMO, LR, SC) is still open.
<!-- /answer -->

## 228. 2026-11-13 23:51:18 JST

```text
Yes. I want to look at the D$'s caching scheme later, and also at raising each cache's size if the FPGA's block RAM is left over.
Here, let's go ahead with H1 first.
```

<!-- answer -->
**Claude Code's answer**

H1's I$ (`OOO_ICACHE`) is done. Its unit bench `tb_icache` passes with 0 mismatches, and bug injection detected 42 of 42. It is pushed to dev (7aaccd2). origin has 0 Ref files. It is not in OOO_CPU yet (H3 puts it there), and Vivado has not seen it.

**What was built**
- **Size:** 32 KB (64 sets × 8 ways × 64 bytes).
- **Timing:** the same as today's bench model. A request taken at F0 is answered at F2 with 32 bytes from flip-flops, one request every cycle while they hit.
- **A miss:** one at a time, 8 beats on AXI4. When the line is in, the request is looked up again inside and answered as a hit.
- **FENCE.I and the reset:** every set is cleared over 64 cycles. FENCE.I is rare, so the length does not matter.

**Size from 4.2k down to 1.2k LUTs (Yosys estimates)**
- The first form was about 4.2k LUTs, far above the plan's 1.0k.
- Moving the valid bits from 512 flip-flops into the tags' LUT RAM, and replacing the way select with the block RAMs' output reset, brought it to about 2.5k.
- The path writing a miss's data straight into the answer alone took about 1.5k, so a miss now looks its request up again after the line is in. A miss is 2 cycles slower in exchange, a few hundred cycles on CoreMark.
- In the end about 1.2k LUTs, 320 LUT RAM and 32 tiles of block RAM. Vivado's numbers come at H4.

**What verification found**
- Before any run I found and fixed an RTL bug: a fill with an error answer left the way's old line valid under the new tag.
- The 2 mutations the first campaign did not detect were both redundant forms; the RTL now has the simpler ones.
- I also fixed a mistake in the bench itself (the sweep's start looked at `busy` after it was updated).

It is recorded in Plan/OOC(_J).md 29.56, STRATEGY 1.7 and the README.

The D$'s write policy and larger caches if block RAM is left over will come up once step H is done. I kept a memory note so they are not forgotten.
<!-- /answer -->

## 229. 2026-11-14 00:28:27 JST

```text
Yes, start H2
```

<!-- answer -->
**Claude Code's answer**

H2 is done and pushed to dev (17f788b). origin has 0 Ref files. The L2 and the arbiter are not in OOO_CPU yet (H3 puts them there).

**The L2 (`CPU_L2`)**
- I brought mmRISC-2's L2 (256 KB, 4 ways, write back, proven on the board with Linux) into `RTL/CPU/CACHE/CPU_L2`.
- One change: a part write that hits is written into the L2's line, which becomes dirty, and is answered without waiting for memory.
- In mmRISC-2 only the debugger wrote partially, so part writes went through to memory. mmRISC-3's D$ is write-through and every store comes as a part write, so as it was, each would wait for memory.
- A part write that misses goes on to memory as before.

**The arbiter (`OOO_MARB`, new)**
- It puts the I$'s fills and the D$ (`OOO_DMISS`) on one AXI4 into the L2.
- When both ask for a read at once they go in turn, and the choice is held while it waits. Read data goes back by ID, and the D$'s writes pass straight through.

**Verification (`SIM/L2`)**
- I brought over mmRISC-2's L2 bench with the arbiter's two ports in front, and renewed its checks of part writes and of which port goes first.
- All 6 configurations pass (the 256 KB design, small ones that evict all the time, direct mapped, 8 ways and so on).
- Bug injection detected 46 of 46: mmRISC-2's 31, 2 for the part writes and 13 for the arbiter.
- The first campaign missed 4 of the arbiter's (which goes first, and holding a waiting read request). Random traffic almost never makes those situations, so I added a directed test that detects them.
- The 2 failures on the way were both wrong assumptions in the bench, now fixed.

**The concern H3 will check**
- A part write that hits takes 4 cycles each.
- CoreMark's roughly 147k stores would keep the L2 busy about 0.6M of about 1.25M cycles.
- H3 puts everything into OOO_CPU and measures how much slower it really gets.

It is recorded in Plan/OOC(_J).md 29.57, STRATEGY 1.7 and the READMEs.
<!-- /answer -->

## 230. 2026-11-14 00:53:08 JST

```text
Yes, start H3
```

<!-- answer -->
**Claude Code's answer**

H3 is done. It is committed as 4c1d4fb and pushed to dev; Ref is 0 on the remote.

**CoreMark** (the timed window of `g14-o2`, 10 iterations)

| Configuration | Timed window (cycles) | CoreMark/MHz |
|---|---|---|
| Ideal caches | 1,211,976 | 8.25 |
| Real caches, the tests' memory | 1,225,683 | 8.16 |
| Real caches, the board's memory (`-mlat 25`) | 1,226,719 | **8.15** |

Gate S1-B (8.0 or more) is met if H4 meets 20 ns.

**A correction found on the way.** The bench counted wrongly and reported "0 cycles" for stores waiting on the write queue. The LSU raises `wt_valid` only when `wt_ready` is up, so that count could never fire. Counting the cycles the queue is full instead showed:
- The D$'s write queue (8 entries) is full 5.3 % of the timed window (64,503 cycles). The L2 takes 4 cycles a part write, and CoreMark's stores come in faster bursts.
- With a queue of 64 entries (on a copy of the RTL) the timed window is 1,213,431 cycles, 8.24 CoreMark/MHz. 13.3k of the real caches' 14.7k-cycle cost is this wait.
- This bears directly on the deferred D$ write-policy question, so I left the RTL as it is and recorded it in 29.58 and in memory.

**Bug injection detected 134 of 140**; the 6 missed are the ones from before.
- With the 256 KB L2, 3 of `OOO_DMISS`'s that were detected before were missed. 108 and 111: the fast L2 closes their race windows. 113: the `wq_n` the bench reads was optimized away, so it did not build.
- Three fixes: the campaign builds `OOO_CPU` with a 4 KB L2 (`L2KB=4`); `tb_cpu.vlt` keeps `wq_n`; a directed test `b4/dir/dcrace.S` opens the races on purpose. All 3 are detected again.
- Only the 10 mutations that run on `OOO_CPU` were rerun, not the whole campaign; the results are merged into `results/mutate_core.txt`.

`run_core` (12 runs, B4 now 187 programs) and `run_coremark` PASS.

Next is H4: please run `synth_ooo.bat OOO_CPU` at 20 ns. New in it are the I$, `OOO_MARB` and the L2 (68 tiles).
<!-- /answer -->

## 231. 2026-11-14 09:23:08 JST

```text
The OOO_CPU run is done.
```

<!-- answer -->
**Claude Code's answer**

H4 met 20 ns in one run, so step H is done and **gate S1-B is met** (8.15 CoreMark/MHz with the real caches at 50 MHz). Committed as 1c99154 and pushed to dev; Ref is 0 on the remote.

**The Vivado result**
- WNS +0.644 ns, TNS 0, hold +0.028 ns.
- 72,783 LUTs, +1,938 from G4.
- 124.5 block RAM tiles: the core 24.5, the I$ 32, the L2 68.

| Against G4 | G4 | H4 |
|---|---|---|
| All LUTs | 70,845 | 72,783 |
| `OOO_FRONT` | 14,030 | 11,930 |
| I$ / L2 | — | 3,073 / 1,059 |
| Block RAM | 24.5 | 124.5 |

- **The front end lost 2.1k LUTs.** `OOO_FDEC2` went from 2,665 to 571, and `OOO_RAS` inside it from 1,256 to 152. I did not chase the cause; my reading is that the I$'s answer now comes from flip-flops inside rather than through a delayed port.
- **The I$ is 3,073 LUTs in Vivado**, more than Yosys's estimate of about 1.2k.
- **The worst paths** are of the same kind as before: the ROB's head pointer to the entries' enables. New near the top is the L2's way register to the enables of its 64 data tiles (+0.659 ns): 8.5 ns of routing to tiles spread over the chip.

`OOO_CPU` uses 72.8k of the 106.5k LUT budget and 124.5 of 365 block RAM tiles. Recorded in 29.59, STRATEGY 1.7 and the reports.

It is time for the two deferred questions.
- **The D$'s write policy**: H3 found that 13.3k of the real caches' 14.7k-cycle cost is stores waiting for the 8-entry write queue. A queue of 64 alone gives 8.24.
- **Bigger caches**: about 240 block RAM tiles are left.

AMO/LR/SC (E1c) is also still open.
<!-- /answer -->

## 232. 2026-11-14 10:28:50 JST

```text
D$ write policy first
```

<!-- answer -->
**Claude Code's answer**

I measured the D$'s write policy and compared three ways (29.60). My recommendation is **write-back**. The RTL is unchanged: the measurements ran on copies of the RTL and the bench, and `Plan/wpol/wpol.sh` reproduces them exactly. Committed as d5d5eb9 and pushed to dev; Ref is 0 on the remote.

**The measurements** (CoreMark with the board's memory; memset and memcpy write 4 KB in the D$ 16 times, 8,192 stores)

| Configuration | CoreMark/MHz | memset / memcpy: cycles a store |
|---|---|---|
| Today (queue of 8) | 8.152 | 3.99 |
| Queue of 16 / 32 / 64 | 8.176 / 8.205 / 8.241 | 3.99 / 3.98 / 3.96 |
| The L2's part write in 3 cycles | 8.226 | 2.99 |
| A store that never waits for the bus (standing in for write-back) | **8.254** | **1.01** |

- **On CoreMark the whole prize is 1.2 %**, and any of the ways takes most of it.
- **The real limit is store bandwidth.** With write-through every store becomes a part write to the L2 (4 cycles). Streams of stores are held to one every 4 cycles, 100 MB/s at 50 MHz, at any queue depth. With write-back a store that hits goes at 1 a cycle, 4 times as fast. That bears directly on Linux's memset, memcpy and page clearing.
- On CoreMark, 45 % of the stores go to a line already waiting in the queue.

**The reason for choosing write-through in 29.34 is gone.** Then there was no port to read a dirty victim. A 3rd copy added to the data copies kept for each load port (`OOO_DCH2`) becomes the read port for the victim and for FENCE.I.
- Only 4 more block RAM tiles, and nothing added to the loads' paths.
- The write queue is no longer needed, so by my estimate the LUTs stay about the same.

**The other ways**
- **A (a queue of 32)**: one parameter, +0.65 %. The fallback if you want it now with no risk.
- **B (gathering stores by line)**: by my estimate more LUTs than C, and it does nothing for scattered stores, so I don't recommend it.

**What write-back newly needs**
- Verifying the new races, extending the memory check at the end of the bench, adding to `dcrace.S`, and new mutations.
- The page table walk, not built yet, must read through the D$.
- AMO/LR/SC (E1c, not started) becomes simpler with write-back.

If C is chosen, the steps are W1 (the 3rd copy and `OOO_DMISS`'s write-back, a unit bench), W2 (the core and `OOO_CPU`, tests and mutations), W3 (a 20 ns run by the author). Bigger caches come after this decision.
<!-- /answer -->

## 233. 2026-11-14 10:50:32 JST

```text
C: write-back (W1)
```

<!-- answer -->
**Claude Code's answer**

W1 is done: the miss handler `OOO_DMISS2`, which writes the D$ back, and `OOO_DCH2`'s victim's copy. The unit bench passes and all 36 mutations are detected. Committed as 8a249f9 and pushed to dev; Ref is 0 on the remote. The core runs today's `OOO_DMISS` until W2, so the CoreMark numbers do not change yet.

**What went in**
- **`OOO_DCH2`'s 3rd copy** (`VR=1`, 4 tiles): written with the other copies, read only by `OOO_DMISS2`. It is the read port for the victim and for FENCE.I, and adds nothing to the loads' paths. With `VR=0` it is as before.
- **`OOO_DMISS2`**:
  - A store only sets its line's dirty bit; the write queue and `wt_*` are gone.
  - A dirty victim's 8 words are read from the 3rd copy and sent as one line write (8 beats). The next fill waits for that write's answer.
  - FENCE.I walks the 256 lines and writes the dirty ones out.

**Found and tidied on the way**
- The gate "hold a beat until the victim's word is read" turned out never to act: the words are read one a cycle from the first cycle of AR, and a beat comes at the earliest the cycle after AR. So I removed it and wrote the reason in the header.
- With a device access waiting, FENCE.I could begin without `fl_take`. This inconsistency was inherited from today's `OOO_DMISS`; fixed.
- **M1397** (a line taken as held without looking at the valid bit) got through twice. An invalid way with a matching tag exists only right after reset, with tag 0, and the bench had no line in the first 4 KB. It is a real mistake: taking a line in the first 4 KB as held after reset.

**`tb_dmiss2`**: the bench acts as the LSU and compares against a reference memory. In a run of 606,000 cycles: about 216k loads checked, about 10.6k dirty victims written out, 96 FENCE.I (2,318 lines cleaned), 0 mismatches.
- It checks that a fill reads only a line memory holds in full.
- It checks that a line written out is the program's data and a line a store wrote.
- It checks that after FENCE.I the whole memory matches the program's.

`verilator -Wall` is clean, and `tb_lsu3` and `tb_lsu4` pass.

W2 connects the write-back D$ to LSU4 and `OOO_CPU`. With it, `tb_core`'s check after the exit lays the D$'s dirty lines over memory, and `dcrace.S` gets dirty-victim cases. Last, the core's mutations run.
<!-- /answer -->

## 234. 2026-11-14 11:12:57 JST

```text
Yes, start W2
```

<!-- answer -->
**Claude Code's answer**

W2 is done. `OOO_CPU` runs with the write-back D$ at **8.244 CoreMark/MHz** with the board's memory (8.152 at H3). Committed as e4ea868 and pushed to dev; Ref is 0 on the remote. The 20 ns timing is not checked yet (W3).

**Changes**
- **`OOO_LSU4`**: gets the victim's copy (`VR=1`) and loses `wt_ready`; a store no longer waits for the bus. `wt_*` stays as the "store written" report the `OOO_CORE` bench's model uses, left open in `OOO_CPU`.
- **`OOO_CPU`**: switched to `OOO_DMISS2`, and `synth_ooo.tcl` reads `OOO_DMISS2` too.
- **`tb_core`**: the check after the exit lays the L2's dirty lines over memory and the D$'s dirty lines over those, then compares.
- **`dcrace.S`**: a part 3 that repeats dirty evictions. Part 2 now also tests FENCE.I behind dirty lines.

**Results**

| `g14-o2`'s timed window | Before | W2 |
|---|---|---|
| `OOO_CPU`, the board's memory | 1,226,719 (8.152) | **1,213,068 (8.244)** |
| `OOO_CORE`, ideal caches | 1,211,976 (8.251) | 1,211,530 (8.254) |

- The real caches' cost went from 1.22 % to 0.13 %; what is left is cold misses. Within 0.1 % of 29.60's prediction (8.254).
- memset / memcpy went from 3.99 to **1.01 cycles a store**: 400 MB/s at 50 MHz.
- `run_core` (12 runs) and `run_coremark` pass. The only new `-Wall` output is the 4 `dc_wt_*` pins left open on purpose.

**The core's bug injection detected 136 of 144.** The 8 not detected:
- 5 are the ones known from before.
- The other 3 are `OOO_DMISS2`'s, and I checked they cannot happen behind `CPU_L2`: the L2 takes one transaction at a time in the order accepted, so a write out is always ahead of the next read.
  - a fill before the write out's answer
  - a beat before its word is in the buffer
  - FENCE.I done before the last write out's answer
- The unit bench `tb_dmiss2` detects all 3. AXI gives no order between AR and AW, so they stay in the RTL.

For W3, please do the 20 ns Vivado run. New in it:
- The victim's copy, which takes the writes to the D$'s data from 8 tiles to 12.
- `OOO_DMISS2` (the dirty bits, the evict buffer, the walk).
- The drain without `!wt_ready`.
<!-- /answer -->

## 235. 2026-11-14 13:17:06 JST

```text
OOO_CPU run done
```

<!-- answer -->
**Claude Code's answer**

W3 met 20 ns in one run, and **step W (the D$ written back) is done**. Committed as 7716b97 and pushed to dev; Ref is 0 on the remote.

**The Vivado result**
- WNS +0.511 ns, TNS 0, hold +0.028 ns.
- 73,094 LUTs, +311 (+0.4 %) from H4.
- 128.5 block RAM tiles: +4 for the victim's copy.

| Against H4 | H4 | W3 |
|---|---|---|
| `OOO_DMISS` → `OOO_DMISS2` | 611 LUTs, 355 FF | 947 LUTs, 654 FF |
| `OOO_LSU4` | 3,510 | 3,980 |
| FF, the whole | 18,823 | 19,144 |

- 29.60 estimated the LUTs at "about ±0"; they came to +311.
  - `OOO_DMISS2`'s dirty bits are 256 flip-flops, with a 256-to-1 select to read them.
  - `OOO_LSU4`'s +470 is large for what changed; my reading is that it includes synthesis's spread, as `OOO_FRONT` (−407) and `OOO_ROB` (−447) moved the other way.
- **The worst paths** are of the same kind as before: the ROB's head pointer into the issue queue's entries. The path into `OOO_DMISS2`'s device-data register, new in the first 20 (+0.727 ns), is logic `OOO_DMISS` had too, so it is placement. The victim's copy and the evict buffer have no path in the first 20.

**Step W in sum** (29.60–29.63)
- **8.244 CoreMark/MHz** with the board's memory (from 8.152), 0.13 % from ideal caches.
- Stores went from one every 4 cycles to one a cycle.
- The cost: +311 LUTs and 4 block RAM tiles.
- `OOO_CPU` uses 73.1k of the 106.5k LUT budget and 128.5 of 365 block RAM tiles.

The second deferred question is bigger caches; about 236 block RAM tiles are left. AMO/LR/SC (E1c) is also still open, but now that the D$ is written back it can run on the line in the D$, which makes it simpler than before.
<!-- /answer -->

## 236. 2026-11-14 13:19:20 JST

```text
Yes, study caches
```
