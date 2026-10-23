# mmRISC-3

[日本語](README_J.md)

> **Designed by Claude Code.** As in [mmRISC-2](https://github.com/munetomo-maruyama/mmRISC-2), the
> specifications, the RTL, the verification, the scripts and the documents in two languages are to be written by
> [Claude Code](https://claude.com/claude-code), Anthropic's AI coding agent. The author sets the goals, chooses
> among the options it proposes, and runs Vivado and the board.

The successor of mmRISC-2: a home-made **2-wide out-of-order 64-bit RISC-V CPU (RV64GC)** in SystemVerilog that is
to run Linux (BusyBox, Debian 13) on a Digilent Arty A7-100T at 50 MHz. The peripherals come from LiteX, and the
assets of mmRISC-2 (caches, MMU, CSR, debug, FPU, verification environment) are reused.

## Goal

The top priority is **CoreMark performance**:

| Build | Goal | mmRISC-2 Rev.02 (board) |
|---|---|---|
| `-O2` | **5.0 CoreMark/MHz** or more | 2.794 |
| Most optimization | **6.0 CoreMark/MHz** or more | 3.034 |

Measured on the board under Linux at 50 MHz, with the same bitstream that runs Linux.

## Status (2026-10-23)

**Phase 0: strategy.** No RTL yet. The strategy is in [`Doc/STRATEGY.md`](Doc/STRATEGY.md): the goal split into
instruction count × IPC, the CPI budget, the LUT budget of the Arty, a trace-driven performance model before any RTL,
and the phases with their gates.

## Documents

| File | Content |
|---|---|
| [`Doc/STRATEGY.md`](Doc/STRATEGY.md) / [`_J`](Doc/STRATEGY_J.md) | Development strategy (CoreMark first) |
| [`Plan/`](Plan/README.md) | Preliminary studies: the [study made during mmRISC-2](Plan/PRESTUDY_MMRISC2.md), and the performance studies of Phase 0 with their working files ([CoreMark instruction counts](Plan/ICOUNT.md), [trace analysis](Plan/TRACE.md)) |

## Branches

- `main`: released versions only
- `dev`: development

## License

Apache License 2.0 (see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE)).
