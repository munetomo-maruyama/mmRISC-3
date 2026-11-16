# RTL/CPU/MMIO

[日本語](README_J.md)

mmRISC-2 Rev.02's peripheral bus with the two blocks of the core that sit on it, taken for mmRISC-3 **without change**
(step 1.8 I1, `Plan/OOC.md` 29.78) **but one**: `CPU_PLIC`'s choice is a tree since step 1.8 I2 (29.79, below). Their specification is mmRISC-2's `RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md` section 8.
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
- **`CPU_PLIC`'s choice (step 1.8 I2)**: mmRISC-2's loop counted down through the 31 sources, each step comparing with
  the best so far: a chain of about 46 levels of logic, -17.8 ns at 20 ns inside the PLIC and -19.4 ns on into the core
  (the first run of I2). It is now a tree of 5 levels (each node keeps its right child only if its priority is greater,
  so equal priorities still go to the lower number). The same answers: checked against mmRISC-2's version, both side by
  side under 4 million cycles of random register accesses and sources (no difference in `irq` or `rdata`; a tie given to
  the higher number differs within 900 cycles), and by `irq.S` part 3b on the core (`SIM/MMIO/run_plic_eq.sh`). `OOO_CPU` also takes the four
  interrupt lines into the core through flip-flops.
- Their lint warnings (unused bits of `ext_irq`, of the strobes, of `cmp_safe`) are mmRISC-2's.
