# mmRISC-3 prompt log

The prompts the author gave Claude Code, in order, with the date and time they were typed (JST), from the first one at
2026-10-23 23:23. This is the English translation of `PROMPT_J.md`, the original in Japanese as typed.

- Entries 1 to 8 (up to 2026-10-24 01:01) were written out from the session log. Later ones are appended to
  `PROMPT_J.md` by a Claude Code hook (`.claude/hooks/record_prompt.py`) at every prompt, and translated here by
  Claude Code in the same turn.
- The text is translated as it is (an attached file stays as `@path`). Messages of the system (background jobs
  finishing and so on) are not included.
- "(button)" marks a prompt sent from the next-step choices Claude Code offered (the wording was prepared by Claude
  Code).

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

## 2. 2026-10-23 23:32:00 JST (button)

```text
Create the mmRISC-3 repository in the same form as mmRISC-2 (public, Apache-2.0, main/dev, README in English and Japanese), make the first commit of Doc and push it.
```

## 3. 2026-10-23 23:37:15 JST

```text
Please gather the working files and documents of the performance evaluation, as preliminary studies, in a directory called Plan.
Please start the instruction-count measurement of Phase 0.
```

## 4. 2026-10-23 23:58:41 JST

```text
Please try again.
```

## 5. 2026-10-24 00:20:03 JST

```text
Please move the preliminary study memo in Doc to Plan, give it a file name meaning "preliminary study made during the development of mmRISC-2", and also keep an English translation of it. For the study, please go on to the trace analysis with the following.

* Fix the compiler for measurements at GCC 14.2 (Debian 13)
* Include Zicond in the definition of `-O2`, and put Zicond in the hardware too
```

## 6. 2026-10-24 00:47:09 JST

```text
In the left pane of this screen, "mmRISC-3開発戦略" (mmRISC-3 development strategy) under Code is inside the light-colored mmRISC-2. Can it be placed under the light-colored mmRISC-3?
```

## 7. 2026-10-24 00:48:24 JST (button)

```text
Run the interrupted reproduction check of trace.sh (run it end to end with g13-o2-zb and see whether it matches the committed results).
```

## 8. 2026-10-24 01:01:12 JST

```text
In this development project, I want the prompts I type recorded, going back to the very first one and continuing with the ones to come. Please append them, with the date and time, in a file Doc/PROMPT.
```

## 9. 2026-10-24 01:05:02 JST

```text
Thank you. Please keep an English translation of PROMPT as well.
```

## 10. 2026-10-24 01:21:12 JST

```text
Please sort out here the items to study next, including the problems and their countermeasures.
```

## 11. 2026-10-24 17:05:17 JST

```text
D1, target performance: basically the recommendation is OK. With the most optimization I want to exceed 6 cm/mhz (CoreMark/MHz).
D2, width: the recommendation is OK.
```

## 12. 2026-10-24 17:07:52 JST

```text
(D1) Target performance: basically the recommendation is OK. With the most optimization I want to exceed 6 cm/mhz.
(D2) Width: the recommendation is OK.
(D3) FPU: at first I want to think of it as pipelined. To be reconsidered depending on the logic size.
(D4) Frequency: fixed at 50 MHz.
(D5) Ether: go ahead with it. The logic-size problem is shared with D3, but please put forward various ideas, such as making the triggers 2.
```

## 13. 2026-10-24 17:08:53 JST

```text
(D1) Target performance: basically the recommendation is OK. With the most optimization I want to exceed 6 cm/mhz.
(D2) Width: the recommendation is OK.
(D3) FPU: at first I want to think of it as pipelined. To be reconsidered depending on the logic size.
(D4) Frequency: fixed at 50 MHz.
(D5) Ethernet: go ahead with it. The logic-size problem is shared with D3, but please put forward various ideas, such as making the triggers 2.
(D6) Repository: as recommended, OK.
```
