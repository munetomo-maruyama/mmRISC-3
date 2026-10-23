# Plan

[日本語](README_J.md)

The preliminary studies of mmRISC-3 (Phase 0 of `Doc/STRATEGY.md`): performance evaluation before any RTL, with its
working files and documents.

| Document | Content |
|---|---|
| [`ICOUNT.md`](ICOUNT.md) / [`_J`](ICOUNT_J.md) | Phase 0-1: CoreMark instructions per iteration by compiler, options and ISA extensions; the IPC the goals need |

| Directory | Content |
|---|---|
| `icount/` | `icount.sh` (builds CoreMark and counts on Spike), `port/` (the bare-metal port), `results/icount.csv`. `work/` is output and not kept |

## Tools outside the repository

| Tool | Where | How it was made |
|---|---|---|
| Spike 1.1.1-dev | `~/RISCV/toolchain/spike-install/bin/spike` | `configure --without-boost --without-boost-asio --without-boost-regex` of `~/RISCV/toolchain/riscv-gnu-toolchain/spike`, built in `~/RISCV/toolchain/spike-build2` |
| GCC 14.2 (Debian 13) | `~/RISCV/toolchain/debian13-rootfs` | `~/mmlitex_build/debian-riscv64.tar` (mmRISC-2's Debian root fs) unpacked; run with `unshare -r chroot` and qemu-user |
