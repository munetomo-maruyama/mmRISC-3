# mmRISC-3

[日本語](README_J.md)

> **Designed by Claude Code.** As in [mmRISC-2](https://github.com/munetomo-maruyama/mmRISC-2), the
> specifications, the RTL, the verification, the scripts and the documents in two languages are to be written by
> [Claude Code](https://claude.com/claude-code), Anthropic's AI coding agent. The author sets the goals, chooses
> among the options it proposes, and runs Vivado and the board.

The successor of mmRISC-2: a home-made **4-issue out-of-order 64-bit RISC-V CPU (RV64GC)** in SystemVerilog that is to run
Linux (BusyBox, Debian 13) on a **Digilent Nexys Video (XC7A200T-1SBG484C) at 50 MHz**, from the microSD slot J3, with
Ethernet (RTL8211E) and a JTAG / cJTAG port on Pmod JA. The peripherals come from LiteX, and the assets of mmRISC-2
(caches, MMU, CSR, debug, FPU, verification environment) are reused.

## Goal

The top priority is **CoreMark performance**:

| Build | Goal | mmRISC-2 Rev.02 (board) |
|---|---|---|
| `-O2` | **as high a CoreMark/MHz as can be had, the clock not insisted on**; CPU at 50 MHz (working target 8.0 in RTL, 7.8 on the board) | 2.794 at 50 MHz |

Measured on the board under Linux, with the same bitstream that runs Linux.

## Status (2026-11-15)

**The 4-wide core runs in lock-step with Spike and meets 50 MHz out of context.** `OOO_CPU` (`RTL/CPU/OOO`) is the core with
its caches; its specification is [`Doc/UARCH.md`](Doc/UARCH.md) section A:

| Item | As built |
|---|---|
| Core | out of order, fetch 32 bytes, decode / rename / dispatch / commit 4, **6 issues** (4 ALUs + 2 load / store ports), ROB 48, issue queue 24 (unified), LQ / SQ 16, 80 physical registers, 12 checkpoints, load-use 2, stores split |
| Prediction | uBTB 96, TAGE-M per 32-byte block, BTB 256, RAS 16, FTQ 32 |
| Caches | I$ 128 KB and D$ 128 KB (8 ways each; the D$ write back, 2 load ports), L2 512 KB |
| ISA so far | RV64IMAC + Zba / Zbb / Zbc / Zbs / Zicond / Zicsr / Zifencei / Zicntr, M / S / U modes |
| CoreMark/MHz | **8.249** (`-O2`, the timed part, with the board's memory latency as measured at step 2.5; 8.244 with the earlier estimate; the working target 8.0 met) |
| Resources, timing | 80,345 LUTs (60 %), 284.5 block RAM tiles (78 %); WNS +0.027 ns at 20 ns (with the interrupts, step 1.8 I2, 2026-11-16) |

**Next, step 1.8**: interrupts, the MMU (Sv39), the FPU, debug and the PMU, then Linux in simulation (gate S1-C); then the board
with LiteX (step 2) and Linux on it (step 3). The work order is [`Doc/STRATEGY.md`](Doc/STRATEGY.md) section 5; the steps so far
are in [`Plan/OOC.md`](Plan/OOC.md) 29.

On the way: the target moved from the Arty A7-100T to the Nexys Video (2026-11-02), and 100 MHz was given up for 50 MHz with a
wider core (2026-11-05).

## Documents

| File | Content |
|---|---|
| [`Doc/STRATEGY.md`](Doc/STRATEGY.md) / [`_J`](Doc/STRATEGY_J.md) | **Start here**: the goal, the resources, the micro-architecture chosen and as built, the work order, the risks |
| [`Doc/BOARD.md`](Doc/BOARD.md) / [`_J`](Doc/BOARD_J.md) | The Nexys Video: DDR3, microSD, Ethernet, JTAG, switches and LEDs, the concerns before ordering |
| [`Doc/UARCH.md`](Doc/UARCH.md) / [`_J`](Doc/UARCH_J.md) | Micro-architecture specification: **section A is `OOO_CPU` as built**; sections 0 to 9 are the G0 specification of the 2-wide core, history |
| [`Doc/PROMPT.md`](Doc/PROMPT.md) / [`_J`](Doc/PROMPT_J.md) | Every prompt the author gave Claude Code and Claude Code's answer to it, with date and time (the Japanese original, and its translation) |
| [`Plan/`](Plan/README.md) | The studies and their working files: the performance model, the bring-up of the core ([`Plan/CORE.md`](Plan/CORE.md)), the Vivado runs ([`Plan/OOC.md`](Plan/OOC.md)), and the strategy for the Arty as history ([`Plan/STRATEGY_A100T.md`](Plan/STRATEGY_A100T.md)) |

`Ref/` (board and device documents of others) is kept locally and is not in the repository.

## Branches

- `main`: released versions only
- `dev`: development

## License

Apache License 2.0 (see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE)).
