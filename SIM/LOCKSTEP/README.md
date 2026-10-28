# SIM/LOCKSTEP: lock-step comparison with Spike

Step 1 of Phase 1 (`Doc/UARCH.md` section 8): every instruction mmRISC-3 commits is compared with Spike, one at a
time, from the first simulation of the core on.

| File | Content |
|---|---|
| `lockstep.h` / `lockstep.cc` | The checker: the `Commit` record and the class `Lockstep` (Spike's `processor_t` on a memory of its own, as a library) |
| `selftest.cc` | Its test without a core: a second Spike produces the stream of a correct core; clean, fused-pair and mutated runs |
| `build.sh` | Builds `obj/selftest` against `~/RISCV/toolchain/spike-install` (Spike 1.1.1-dev; `SPIKE=` for another) |
| `run_selftest.sh` | The self-test on riscv-tests and CoreMark → `results/selftest.txt` |

## How a test bench uses it

```c++
LockstepCfg cfg;  cfg.elf = "test.elf";   // the same file the core runs
Lockstep ref(cfg);
// every cycle, for each µop committed (a fused pair gives 2 records):
Commit c;  c.pc = ...;  c.insn = ...;  c.rd = ...;  c.rd_val = ...;  // ...
std::string why;
if (!ref.check(c, &why)) { printf("MISMATCH %s\n", why.c_str()); stop(); }
if (ref.exited()) finish(ref.exit_code());
```

The `Commit` record is what the core's commit-trace port (simulation only, in the style of RVFI) must give for each
instruction in program order:

| Field | Meaning |
|---|---|
| `pc`, `insn` | Address and bits of the instruction (a compressed one in the low 16) |
| `trap`, `cause` | It did not retire: an exception at `pc`, with its cause |
| `rd`, `rd_fp`, `rd_val` | The register written (−1: none; x0 counts as none), integer or FP, and the value |
| `rd_skip` | The first half of a fused pair whose result is not written (one write per pair): only `pc` and `insn` are compared |
| `st`, `st_addr`, `st_data`, `st_size` | The store it made |

## Rules for the core and its test bench

- **HTIF**: the reference answers a store to `tohost` at once (`tohost` back to 0 before its next instruction; exit:
  `tohost = code << 1 | 1`; a character: device 1, command 1). The core's test bench (`SIM/CORE`) answers it when the
  store reaches its memory, through the store queue and the D$, so a loop polling `tohost` can run more times in the
  core: **loads of `tohost` and `fromhost` take the core's value** (the reference's register is overwritten, as for
  the counters), and the reference runs the same loop (added 2026-10-29).
- **Counters**: reads of `cycle`, `time`, `mcycle` and the HPM counters take the core's value (the reference's register
  is overwritten), since only those differ by nature. `instret` is compared (a fused pair counts 2).
- **Misaligned accesses trap** (as in mmRISC-2), and the reference is set the same way.
- **The reference is mmRISC-2's machine**: its instruction set (`rv64imafdc_zicboz_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zba_zbb_zbc_zbs_smcntrpmf_sscofpmf_sstc`, kept by mmRISC-3) and 16 PMP entries (8 implemented, 8 reading 0), M / S / U modes; one RAM region from 0x8000_0000 (64 MB), no devices.
- Phase 1 is M-mode, bare metal and without interrupts. Interrupts (where the core takes one, the reference is made to
  take it too) and MMIO with side effects come in Phase 2.

## Self-test (2026-10-25)

`./run_selftest.sh`: every `-p-` test of rv64ui / um / ua / uc / uf / ud / uzba / uzbb / uzbc / uzbs / uzicond / mi /
si from mmRISC-2's build, and the two g14 CoreMark builds of `Plan/trace`.

| Run | What must happen |
|---|---|
| clean | The correct stream passes to the HTIF exit with no mismatch |
| fused | The same stream with "first halves of fused pairs" marked (`rd_skip`, value scrambled) passes |
| exit codes | Only the tests mmRISC-2 also expects to fail end with a nonzero exit code: `ma_data` (wants misaligned accesses done in hardware) and `amocas_*` (Zacas is not implemented). The comparison still passes on them |
| mutated | One wrong field at a random commit, 10 kinds (register value, register number, write missing, pc, instruction, trap flag, trap cause, store data, store missing, commit dropped), is caught at that very commit |

The results are in `results/selftest.txt`.

**CoreMark (resolved 2026-10-25)**: the exit code 37 was the checker's HTIF, not CoreMark: a character write
(device 1, command 1) with an odd character code was taken for an exit, because bit 0 was tested before the device.
The device is checked first now. On the reference both builds run to the end with exit code 0 and print what the
`spike` runs of `Plan/icount` print (crcfinal 0xfcaf; "Errors detected" only because a 10-iteration run is shorter
than CoreMark's 10 seconds).
