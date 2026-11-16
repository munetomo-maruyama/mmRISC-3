# SIM/MMIO

[日本語](README_J.md)

A check of `RTL/CPU/MMIO`'s one change from mmRISC-2 (step 1.8 I2, `Plan/OOC.md` 29.79): `CPU_PLIC` chooses the best
source of each context with a tree (5 levels) instead of mmRISC-2's loop (a chain of about 46 levels, -17.8 ns at
20 ns). The answers must stay the same.

```bash
./run_plic_eq.sh
```

| File | What it is |
|---|---|
| `CPU_PLIC_MM2.sv` | mmRISC-2 Rev.02's `CPU_PLIC`, renamed: the reference |
| `tb_plic_eq.sv` | Both side by side on the same inputs (31 sources, 2 contexts, priorities of 3 bits) |
| `tb_plic_eq.cpp` | 4 million cycles of random register accesses (priorities, pending, enables, thresholds, claims, completions of any id, addresses anywhere) and random sources; `irq` and `rdata` compared every cycle |
| `run_plic_eq.sh` | Builds with Verilator (`obj_dir/`, not kept) and runs: PASS when nothing differs |

Result (2026-11-16): no difference; 1.83 million cycles with an interrupt, 115k claims that returned a source. With
ties given to the higher number in the tree, the first difference comes within 900 cycles. In the core the choice is
tested by `SIM/CORE/b4/irq/irq.S` part 3b and `SIM/CORE/mutate_core.py`'s mutations of `CPU_PLIC`.
