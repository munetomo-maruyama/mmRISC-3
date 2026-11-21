

### 29.96 Step 1.8 V3 a fourth time, with V3d: met, +0.073 ns, 105,954 LUTs (2026-11-21)

**The run** (by the author, `synth_ooo.bat OOO_CPU`, the RTL of 29.95): **105,954 LUTs** after place and route (89,189 logic + 16,652 LUT RAM; 107,541 after synthesis), 27,680 FF, 42 DSP, 284.5 tiles of block RAM; **WNS +0.073 ns, TNS 0, no endpoint failing; hold +0.028 ns**: all constraints met, so `timing_blocks.rpt` (the failing paths in full) was not written. **V3 is done**: `OOO_CPU` at 20 ns with V1, V2 and P1 (and U, I before them).

**V3d worked**: the kill is no longer among the worst (out of `k_ckpt` into `OOO_ROB` +2.128 ns; `OOO_DMISS2` not among the blocks' worst); the fetch's ITLB out +1.043 ns.

**The worst paths now**:
- **Inside EX, into the new choice** (+0.073 ns, 31 levels: 19 CARRY4, 71 % route; 13 of the 20 worst endpoints, all `k_ckpt`'s replicas): ALU port 0's `ex_m1` → the bypass's select → the operand (fan-out 174, 117) → the 64-bit compare of the branch (`lt`, 15 CARRY4) → `ex_tk` → the misprediction (`mis`, the taken bit or a jalr's target against the prediction) → `k_m` → `k_ckpt`'s choice. V3c's bypass path, now ending at the choice instead of the integer file (into `u_prf` +0.662 ns).
- **F2's predecode → the uBTB's `pc_q`** (+0.383 ns, 22 levels): the fetch's loop, as before.
- **The fetch's ITLB → `OOO_PTW`'s `r_ptag` reset** (+0.664 ns).

**A margin if one is wanted later** (not done: nothing fails): since step 1.2 D only port 0 resolves branches (29.95: `br_valid[1]` never 1), yet `k_ckpt`'s choice compares the two ports' distances behind `k_m[1]`, which Vivado cannot prove 0. Taking port 1's resolution out (a parameter, or `e_br_valid[1]` tied to 0) would leave `k_ckpt <= e_br_ckpt[0]`, off the misprediction altogether, the same to the bit. To be used when a later step (K1's events, J1's debug, LiteX around it) brings this path back.

**The LUTs**: +747 on 29.94's run (+985 after synthesis): `OOO_CTRL` +851 (its restore now from `k_ckpt` in the core, where Vivado had merged part of it into `OOO_ROB`: `OOO_ROB` −456), the rest spread (`OOO_FRONT` +688, `OOO_PMUL` +266, `OOO_IQ3` −364, `OOO_LSU4` −314, `OOO_ICACHE` −269, ...): synthesis. At step 1.8's end (K1 about +0.3k, J1 about +3k) about 109.3k, with LiteX's SoC (5.3k) about 114.6k, about 6.9k above the ceiling of 107.7k (an estimate from the Arty, not measured on this device), as at U3b; the author's decision when it comes.

**Next: K1, the PMU's events** (29.76): the OoO core's events (instructions by class at commit, mispredictions, flushes, I$ / D$ misses, the ITLB / DTLB misses and walks, stalls) into `CORE_CSR`'s 2 HPM counters (mhpmcounter3 / 4 with their mhpmevent: 2 since G0b L1, `hpm_ev` tied to 0 in `OOO_CORE` until now); Sscofpmf's overflow interrupt (LCOFI, I1's interrupt path); what OpenSBI's perf needed on mmRISC-2 (Smcntrpmf, the device tree's events 1 / 2, OpenSBI's stop and RESET patch: `make pmu-sbi`); directed tests in lock-step (Spike made to take the counters' values, as for mcycle); CoreMark unchanged. The events' list and their numbering first, for the author to confirm.
