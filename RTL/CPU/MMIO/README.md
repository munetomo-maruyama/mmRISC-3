# RTL/CPU/MMIO

[日本語](README_J.md)

mmRISC-2 Rev.02's peripheral bus with the two blocks of the core that sit on it, taken for mmRISC-3 **without change**
(step 1.8 I1, `Plan/OOC.md` 29.78). Their specification is mmRISC-2's `RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md` section 8.
Each file has a line added to its header to say where it comes from.

| Block | What it is | In mmRISC-3 |
|---|---|---|
| `CPU_MMIO` | The D$'s peripheral bus (AXI4-Lite) decoded: an access to the CLINT or the PLIC answered inside, the rest passed out unchanged; one write and one read at a time, the address registered before the decision | In `OOO_CPU`, between `OOO_DMISS2`'s device port and `m_axil_*`; the CLINT at 0x0200_0000, the PLIC at 0x0C00_0000 |
| `CPU_CLINT` | msip (0x0000), mtimecmp (0x4000), mtime (0xBFF8), one step every `TICK_DIV` cycles | `CLINT_TICK_DIV` 100 (50 MHz / 100: 500 kHz, as mmRISC-2); 1 in `SIM/CORE`'s bench |
| `CPU_PLIC` | The RISC-V PLIC: priorities, pending, enables and threshold / claim / complete per context, level-triggered gateways; a 32-bit register chosen by its address's bit 2 | 31 sources (`OOO_CPU`'s `irq_src`), context 0 machine, 1 supervisor, priorities of 3 bits |

- **The address**: a register of the PLIC is chosen by the byte address, not by the strobes, so the D$'s device port
  sends an access's own byte address (`OOO_DMISS2`, and `OOO_LSU4`'s store from its first byte, since step 1.8 I1:
  before, the word's address, and a 32-bit register at +4 was missed).
- Tests: `SIM/CORE` on `OOO_CPU`: `b4/irq/irq.S` and riscv-arch-test's InterruptsSm / InterruptsS (32), in lock-step
  with Spike made to take the interrupt the core took (`SIM/LOCKSTEP`); mmRISC-2's own tests of the blocks are not
  repeated here.
- Their lint warnings (unused bits of `ext_irq`, of the strobes, of `cmp_safe`) are mmRISC-2's.
