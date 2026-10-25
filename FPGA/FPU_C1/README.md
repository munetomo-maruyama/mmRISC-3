# FPGA/FPU_C1: the breakdown of mmRISC-2's FPU (option C1)

Option C1 of `Plan/REDUCE.md` and `Doc/UARCH.md` section 5: where the 8.8k LUTs of mmRISC-2's `FPU_PIPE` go, as the
basis for sharing the multiplier (C2) and moving the rare operations to a small iterative unit (C3).

```
cd FPGA\FPU_C1
synth_fpu_c1.bat
```

- It reads `FPU_PIPE.sv` and `FPU_ROUND.sv` from the mmRISC-2 tree next to this one (`..\..\..\mmRISC-2`; set
  `MMRISC2=<path>` before running if it is elsewhere), synthesizes `FPU_PIPE` out of context at 50 MHz, and places and
  routes it.
- `FPU_PIPE` is one module (only the rounder is a module of its own), so a report by hierarchy cannot split it.
  Instead every register is put in a group by the start of its name (`p0` to `p8` the stage registers, `pp` / `prod` the
  partial products, `sum`, `al` the alignment, `ds` / `dv` / `sq` the divide and square root engine, `f2i` the
  conversion to an integer, `a` / `b` / `c` the unpacked operands, `out`, `u_round` the rounder, and so on), and the LUTs
  in the fan-in cone of each group are counted.

| Output (`output\FPU_C1\`) | Content |
|---|---|
| `breakdown.txt` | Per group: registers, LUTs in the cone, LUTs that feed only this group (what removing it would free at least), CARRY4, MUXF, DSP |
| `summary.txt` | Totals, register-to-register slack |
| `utilization.rpt` | Physical LUTs after place and route (the 9,060 of mmRISC-2's measurement, for comparison) |
