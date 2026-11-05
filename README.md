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

## Status (2026-11-05)

**The target changed from the Arty A7-100T to the Nexys Video** (the author's decision, 2026-11-02): the reductions
needed to fit the smaller device were costing the performance. The 2-wide core is in `RTL/CPU/OOO`: in lock-step with
Spike on riscv-arch-test and CoreMark (5.50 CoreMark/MHz with `-O2`), 50 MHz met out of context. **100 MHz was given up on
2026-11-05** (the whole core reached about 18.8 ns, and a deep pipeline loses CoreMark/MHz). The proposal: **4 renamed, 6
decoded, 4 ALUs + 2 LSUs, 6 issues, at today's pipeline depth, 50 MHz**: 8.68 in the model, about 69k LUTs for the engine,
about 81 % of the device, at the ceiling. The loops that decide it are measured at 20 ns before the rework. The work order is in [`Doc/STRATEGY.md`](Doc/STRATEGY.md) section 5: the core, the board (brought up with
LiteX's own SoC and mmRISC-2 first), Linux.

## Documents

| File | Content |
|---|---|
| [`Doc/STRATEGY.md`](Doc/STRATEGY.md) / [`_J`](Doc/STRATEGY_J.md) | **Start here**: the goal, the resources, the proposed micro-architecture, the work order, the risks |
| [`Doc/BOARD.md`](Doc/BOARD.md) / [`_J`](Doc/BOARD_J.md) | The Nexys Video: DDR3, microSD, Ethernet, JTAG, switches and LEDs, the concerns before ordering |
| [`Doc/UARCH.md`](Doc/UARCH.md) / [`_J`](Doc/UARCH_J.md) | Micro-architecture specification: section 0 is the revision; the rest is the 2-wide core the RTL is today |
| [`Doc/PROMPT.md`](Doc/PROMPT.md) / [`_J`](Doc/PROMPT_J.md) | Every prompt the author gave Claude Code and Claude Code's answer to it, with date and time (the Japanese original, and its translation) |
| [`Plan/`](Plan/README.md) | The studies and their working files: the performance model, the bring-up of the core ([`Plan/CORE.md`](Plan/CORE.md)), the Vivado runs ([`Plan/OOC.md`](Plan/OOC.md)), and the strategy for the Arty as history ([`Plan/STRATEGY_A100T.md`](Plan/STRATEGY_A100T.md)) |

`Ref/` (board and device documents of others) is kept locally and is not in the repository.

## Branches

- `main`: released versions only
- `dev`: development

## License

Apache License 2.0 (see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE)).
