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
