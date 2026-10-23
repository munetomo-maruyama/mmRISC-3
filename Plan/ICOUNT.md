# Phase 0-1: CoreMark instruction counts (by compiler, options and ISA extensions)

- Date: 2026-10-24
- Purpose: fix the IPC needed for the goals (5.0 CoreMark/MHz with `-O2`, 6.0 with the most optimization) from
  measured instruction counts (`Doc/STRATEGY.md` sections 1.1 and 5.2, step 1)
- Working files: `Plan/icount/` (`icount.sh`, `port/`, `results/icount.csv`)

---

## 1. Summary

1. **GCC 14.2 (Debian 13) + Zicond gives the fewest instructions**: **311,890** per iteration with `-O2`, **280,958**
   with the most optimization (sf + `-flto`). Against the condition measured in mmRISC-2 (GCC 13.2, Zba / Zbb, `-O2`,
   318,597) that is −2.1 % and −11.8 %.
2. The IPC needed goes down to:

| Goal | Condition | Instructions / iteration | IPC needed |
|---|---|---|---|
| 5.0 /MHz with `-O2` | GCC 14.2, Zba / Zbb / Zbs / Zicond | 311,890 | **1.56** (estimated 1.59 before) |
| 6.0 /MHz with `-O2` | same | 311,890 | 1.87 (not a 2-wide target) |
| 5.0 /MHz, most optimization | GCC 14.2, sf + `-flto`, same | 280,958 | 1.40 |
| 6.0 /MHz, most optimization | same | 280,958 | **1.69** (estimated 1.77 before) |

3. **Zicond goes into the hardware** (−1.5 % with GCC 14; GCC 13 and older do not use it). Zbs hardly matters
   (−0.1 %). Zba / Zbb remain the largest effect, −11 to −13 %.
4. **clang 18 runs 19 to 29 % more instructions**, so it is not used for CoreMark.
5. **Fewer instructions do not mean fewer cycles.** Unrolling and inlining grow the code from 9 KB to 34 KB (the I$ is
   16 KB), and in mmRISC-2 GCC 13's sf + `-flto` was slower than sf (BENCH.md section 17). The options of the most
   optimization are chosen in the end by the cycles of the performance model and the RTL.

---

## 2. Method

### 2.1 Environment
| Item | Content |
|---|---|
| ISS | Spike 1.1.1-dev (the source bundled with riscv-gnu-toolchain, 2024-07-08) built into `~/RISCV/toolchain/spike-install` (without Boost); `--isa=rv64gc_zba_zbb_zbs_zicond` |
| CoreMark | `~/RISCV/Rocket/vivado-risc-v/bare-metal/coremark/coremark` (the same source as mmRISC-2), `PERFORMANCE_RUN=1`, `ITERATIONS=10` |
| Port | The bare-metal port of mmRISC-2's `SIM/SIM_SYS/bench` (no C library, M-mode) adapted to Spike: `fromhost` added, console output waits until the previous byte is taken, the profile marks of tb_SYS removed |
| Count | Difference of `minstret` over the timed part (`start_time` to `stop_time`) ÷ iterations |
| Correctness | crcfinal 0xfcaf (10 iterations) in every build |

### 2.2 Compilers
| Name | Compiler | Note |
|---|---|---|
| g12 | riscv64-unknown-elf-gcc 12.2.0 (`/opt/riscv`) | |
| g13 | riscv64-unknown-elf-gcc 13.2.0 (`/opt/riscv`) | the one mmRISC-2 used |
| g13u | riscv64-linux-gnu-gcc 13.3.0 (Ubuntu 24.04) | PIE and stack protector off (`-fno-pie -no-pie -fno-stack-protector`) |
| g14 | gcc 14.2.0 (Debian 13 riscv64, the same as the gcc on the board) | mmRISC-2's Debian root fs (`~/mmlitex_build/debian-riscv64.tar`) unpacked into `~/RISCV/toolchain/debian13-rootfs`, run with `unshare -r chroot` and qemu-user; PIE and stack protector off as for g13u |
| c18 | clang 18 (Ubuntu 24.04) | linked by the g13 driver |

### 2.3 Options and ISA extensions
| Name | Options |
|---|---|
| o2 | `-O2` |
| o3 | `-O3` |
| sf | `-O3 -funroll-all-loops -finline-functions --param max-inline-insns-auto=20 -falign-functions=4 -falign-jumps=4 -falign-loops=4` (mmRISC-2's "most optimization", BENCH.md section 17); for clang `-O3 -funroll-loops -finline-functions` |
| sflto | sf + `-flto` |
| sfx | sf + `-finline-limit=600 -fno-code-hoisting -fgcse-sm -fgcse-las -fipa-pta` |

| Name | `-march` |
|---|---|
| gc | `rv64imafdc_zicsr_zifencei` |
| zb | gc + `_zba_zbb` |
| zbs | zb + `_zbs` |
| zbsc | zbs + `_zicond` |

### 2.4 Checks
- **Agrees with mmRISC-2's SIM_SYS**: GCC 13.2, `-O2`, Zba / Zbb, 10 iterations: 3,185,974 instructions on Spike against
  3,185,981 in SIM_SYS (BENCH.md section 13). The difference of 7 instructions (0.0002 %) is within what the port
  changes (the profile marks removed). rv64gc also agrees at 358,921 per iteration.
- **Proportional to the iterations**: 318,610 per iteration with 20 iterations (318,597 with 10, 0.004 % apart). The
  count per iteration does not depend on the number of iterations.

---

## 3. Results (instructions per iteration)

| Compiler | Options | gc | zb | zbs | zbsc |
|---|---|---|---|---|---|
| g12 | o2 | 354,165 | 313,871 | 313,637 | 313,637 |
| g12 | o3 | 339,958 | 301,675 | 301,440 | 301,440 |
| g12 | sf | 332,019 | 292,934 | 292,699 | 292,699 |
| g12 | sflto | — | 316,372 | — | 316,133 |
| g12 | sfx | — | 297,822 | — | 297,589 |
| g13 | o2 | 358,921 | **318,597** | 318,362 | 318,362 |
| g13 | o3 | 344,134 | 303,672 | 303,437 | 303,437 |
| g13 | sf | 335,937 | 294,467 | 294,232 | 294,232 |
| g13 | sflto | — | 313,967 | — | 313,728 |
| g13 | sfx | — | 293,914 | — | 293,669 |
| g13u | o2 / o3 / sf | exactly as g13 | | | |
| g14 | o2 | 359,036 | 316,979 | 316,562 | **311,890** |
| g14 | o3 | 344,149 | 301,971 | 301,553 | 296,881 |
| g14 | sf | 331,910 | 289,461 | 289,044 | 284,372 |
| g14 | sflto | — | 286,048 | — | **280,958** |
| g14 | sfx | — | 288,772 | — | 288,364 |
| c18 | o2 | 415,282 | 376,070 | 375,574 | 370,694 |
| c18 | o3 / sf | 410,991 | 371,779 | 371,283 | 366,403 |

Bold: mmRISC-2's condition (g13 / o2 / zb), and the fewest with `-O2` and with the most optimization. All data in
`Plan/icount/results/icount.csv`.

### 3.1 Effect of each factor

| Factor | Effect (instructions) |
|---|---|
| Zba / Zbb (gc → zb) | GCC −11.2 to −12.8 %, clang −9.4 % |
| Zbs (zb → zbs) | −0.07 to −0.14 % |
| Zicond (zbs → zbsc) | GCC 14 −1.5 to −1.6 %, clang −1.3 %, GCC 12 / 13 no change |
| `-O3` (against o2) | −3.9 to −4.8 % |
| sf (against o2) | GCC 12 −6.7 %, GCC 13 −7.6 %, GCC 14 −8.8 % |
| `-flto` (against sf, zbsc) | GCC 14 −1.2 %, GCC 13 +6.6 %, GCC 12 +8.0 % |
| clang 18 (against GCC 14) | `-O2` +19 %, sf +29 % |
| Code size (.text) | o2 about 9 KB, sf about 28 to 33 KB, GCC 14 sflto about 34 KB |

---

## 4. Decisions to take (2026-10-24: the compiler and Zicond decided)

| Item | Proposal | Reason |
|---|---|---|
| Compiler for measurements | **Fixed at GCC 14.2 (Debian 13)** (decided) | Fewest instructions; the same as the gcc on the board, so the same binary can be built on the board or on the host (qemu-user) |
| Definition of `-O2` | `-O2 -march=rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicond` (decided) | Every extension the hardware has (`STRATEGY.md` section 1.3) |
| Candidates for the most optimization | sf + `-flto` (fewest instructions) and sf (smaller code) | Chosen in the end by cycles |
| Zicond | **In the hardware** (decided; mmRISC-2 has it too) | −1.5 % with GCC 14 |
| Input of the performance model | g14 / o2 / zbsc and g14 / sflto / zbsc, plus g13 / o2 / zb for the calibration against mmRISC-2 | |

Note: on the board CoreMark is the posix port under Linux (glibc, other timing functions), so the counts do not match
these exactly. The timed part is CoreMark itself, so the difference should be small (in mmRISC-2 SIM_SYS and the board
agreed on CoreMark/MHz).

---

## 5. Next

1. From Spike's commit log, take **instruction traces** of the three builds above and count the instruction mix,
   branches (taken rate, short forward branches = SFB candidates) and the rate of fusible instruction pairs.
2. Build the **trace-driven cycle model** on those traces and calibrate it against mmRISC-2's 8-stage in-order core
   (CPI 1.103).
3. GCC 15 (not installed) can be added later if needed.
