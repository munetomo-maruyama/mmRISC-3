# RTL/CPU/FPU

[日本語](README_J.md)

mmRISC-2 Rev.02's pipelined FPU, taken for mmRISC-3 **without change** (step 1.8 U1, `Plan/OOC.md` 29.81), for the
renamed FPU of `Plan/OOC.md` 29.77 and 29.80. Its specification is mmRISC-2's `RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md` section
10 (10.11 the pipelined version) and `RTL/CPU/CPU_FPU/README.md`. Each file has a line added to its header to say where
it comes from.

| Block | What it is | In mmRISC-3 |
|---|---|---|
| `FPU_PIPE` | Every operation of F and D in 9 stages, one a cycle, **the same latency for all (9)**, results in the order offered; divide and square root by an iterative engine at P1, the FPU held (`in_ready` low) from their offer to their answer; P0 and P1 can be held and killed | Inside `OOO_FPUW` (`RTL/CPU/OOO`), which offers only what it takes and drops what is killed by itself (hold and kill tied low); `TAG_W` 4: the index of `OOO_FPUW`'s ring of offered µops |
| `FPU_ROUND` | Normalization, rounding and packing, for everything that is rounded | Inside `FPU_PIPE` |

- Measured alone in mmRISC-2 (`FPGA/FPU_OOC`, 50 MHz): 9,060 LUTs, 2,631 flip-flops, 16 DSP, register to register
  +3.76 ns.
- Verified in mmRISC-2 against Berkeley SoftFloat (about 700,000 checks of `FPU_PIPE`, all operations, both precisions,
  the 5 rounding modes, the flags) and by its own bug injection (28 of 28). Here `SIM/OOO_UNIT/tb_fpuw` runs it inside
  `OOO_FPUW` against the host's IEEE arithmetic; mmRISC-2's own tests of the block are not repeated.
- Its lint warnings (6 with `-Wall`) are mmRISC-2's.
