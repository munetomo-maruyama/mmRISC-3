# Plan

[日本語](README_J.md)

The preliminary studies of mmRISC-3 (Phase 0 of `Doc/STRATEGY.md`): performance evaluation before any RTL, with its
working files and documents.

| Document | Content |
|---|---|
| [`MODEL.md`](MODEL.md) / [`_J`](MODEL_J.md) | Phase 0-3: the trace-driven C++ cycle model; (1) framework and calibration against mmRISC-2 (5 points within ±0.3 %) |
| [`PRESTUDY_MMRISC2.md`](PRESTUDY_MMRISC2.md) / [`_J`](PRESTUDY_MMRISC2_J.md) | The study memo made during mmRISC-2 (2026-10-13): an out-of-order RV64GC on the Arty A7-100T; resources, NaxRiscv, Linux and non-speculative execution, compromises |
| [`ICOUNT.md`](ICOUNT.md) / [`_J`](ICOUNT_J.md) | Phase 0-1: CoreMark instructions per iteration by compiler, options and ISA extensions; the IPC the goals need |
| [`ISSUES.md`](ISSUES.md) / [`_J`](ISSUES_J.md) | Remaining study items of Phase 0 up to G0, with problems and countermeasures; the measured resources of mmRISC-2 Rev.02 and the revised budget; decisions for the author |
| [`REDUCE.md`](REDUCE.md) / [`_J`](REDUCE_J.md) | Options to reduce the logic (triggers, PMP, LUTRAM for D$ buffers / TLBs / CSRs, PMU, Zbc, FPU, LiteX), with savings measured by Yosys on mmRISC-2's RTL |
| [`TRACE.md`](TRACE.md) / [`_J`](TRACE_J.md) | Phase 0-2: trace analysis of CoreMark: instruction mix, branch predictors (gshare of mmRISC-2, TAGE), SFB and fusion candidates, an uncalibrated limit model |

| Directory | Content |
|---|---|
| `icount/` | `icount.sh` (builds CoreMark and counts on Spike), `port/` (the bare-metal port), `results/icount.csv`. `work/` is output and not kept |
| `trace/` | `trace.sh` (build, trace on Spike, analyze), `capture.py` (the timed part of Spike's log as a compact trace), `analyze.py` (all the analyses and the limit model), `results/` (`<build>.json`, `<build>.limit.txt`). `work/` is not kept |
| `model/` | `mktrace.py` (trace → 32-byte records), `model.h`, `pred_mm2.h`, `inorder.h`, `model.cpp`, `calib.sh`, `results/calib.txt`. `work/` (binaries, traces) is not kept |
| `reduce/` | `synth.sh` (one module of mmRISC-2 with changed parameters, sv2v + Yosys for the Artix-7), `deps.py`, `sweep.sh`, `results/sweep.txt`. `work/` is not kept |

## Tools outside the repository

| Tool | Where | How it was made |
|---|---|---|
| Spike 1.1.1-dev | `~/RISCV/toolchain/spike-install/bin/spike` | `configure --without-boost --without-boost-asio --without-boost-regex` of `~/RISCV/toolchain/riscv-gnu-toolchain/spike`, built in `~/RISCV/toolchain/spike-build2` |
| GCC 14.2 (Debian 13) | `~/RISCV/toolchain/debian13-rootfs` | `~/mmlitex_build/debian-riscv64.tar` (mmRISC-2's Debian root fs) unpacked; run with `unshare -r chroot` and qemu-user |
