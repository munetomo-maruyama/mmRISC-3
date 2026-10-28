# RTL/CPU/CORE

[日本語](README_J.md)

Blocks of mmRISC-3 taken from mmRISC-2 Rev.02 **without change** (`Doc/UARCH.md` 3.10: the instruction set is
mmRISC-2's, and mmRISC-3's ALU uses mmRISC-2's operation encoding), but for the one change to `CORE_CSR` below. Each
file has a line added to its header to say where it comes from; the rest is mmRISC-2's text.

| Block | What it is | Used by | Test (`SIM/OOO_UNIT`) |
|---|---|---|---|
| `CORE_DECOMP` | RVC → the 32-bit instruction that means the same; `illegal` for the reserved encodings | `OOO_DEC` | `tb_dec`: every RVC encoding against an expander written with Spike's field extractors, and Spike running it for what is reserved |
| `CORE_CSR` | The CSR file, the privilege level and the trap state (M / S / U, PMP, Sstc, Sdtrig, the PMU with Sscofpmf / Smcntrpmf). **One change**: `instret_inc` counts the instructions retired in a cycle (0 to 4) instead of one bit | `OOO_CSRU` (`HPM_COUNTERS` = 2: G0b L1) | `tb_csru`: a set of CSRs against a reference, trap entry and MRET |
| `CORE_MDU` | Multiply / divide of M and Zbc's carry-less multiply: one operation at a time, mul / mulw done the cycle after the start, the others later | `OOO_MDUP` | `tb_mdup`: every operation against the M / Zbc semantics, behind port 0 with kills and flushes |
| `CORE_DEC` | The 32-bit decoder of RV64GC + Zba / Zbb / Zbc / Zbs / Zicond / Zicsr / Zifencei / Zicboz and the privileged instructions: one µop record | `OOO_DEC` | `tb_dec`: 3,000,000 instructions against a decoder written from the specification's tables, with Spike as the judge of what exists |

- Their lint warnings (unused bits, a function argument that hides a name) are mmRISC-2's and are left as they are.
- `SIM/OOO_UNIT/mutate.py` can break these files too (`CORE:` entries): 6 mutations, all detected.
