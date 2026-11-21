

### 29.97 Step 1.8 K1: the PMU's events, the design (2026-11-21)

The author's go ("Start K1"). As 29.96 said, the events' list and numbering first, for the author to confirm.

**What is there**: `CORE_CSR` (mmRISC-2's, decision 69 of its `CPU_CORE_SPEC.md`) has the PMU whole: `HPM_COUNTERS` counters from mhpmcounter3 (2 here since G0b L1, `Doc/UARCH.md` 6.3), each with its mhpmevent (a 5-bit event number; Sscofpmf's OF / MINH / SINH / UINH), mcountinhibit, mcounteren / scounteren, scountovf, the overflow interrupt LCOFI (13, delegable), Smcntrpmf (mcyclecfg / minstretcfg). The core gives one bit per event and cycle (`hpm_ev`), registered once in `CORE_CSR` (`hpm_ev_q`) with the level, and counted a cycle late. `OOO_CORE` ties `hpm_ev` to 0. Lock-step already takes the core's value for reads of the counters and of mhpmevent; Spike's ISA string has Sscofpmf and Smcntrpmf; I1 made Spike take the interrupt the core took.

**What a 4-wide core needs**: up to 4 µops are renamed, dispatched and committed a cycle (8 instructions, a fused pair counting 2), so one bit per event and cycle cannot count them. **`hpm_ev` becomes a count per event** (`HPM_EVW` = 4 bits, 0 to 8), the counter adds the selected event's count (as minstret adds `instret_inc`), and OF is set by the add's carry (a wrap that need not pass all ones). The rest of `CORE_CSR`'s PMU is unchanged.

**The slots at renaming**: each cycle has 4 slots at renaming (D2 → DS, where `OOO_CTRL` decides `r_go`), and each slot goes to exactly one class:
- **used**: the µops renamed (`r_go`);
- **recovery**: in the cycles from a restore or a trap / replay (`restore_k`, `fe_flush`) until renaming takes µops again, the slots not used (the front end's refill after a redirect counts here, as in Top-Down);
- **back end**: otherwise, the µops offered and not renamed (`r_valid` less `r_go`: the DS register full because dispatch waits for the ROB, a queue, the LQ / SQ; the physical registers or a checkpoint missing);
- **front end**: otherwise, the slots with no µop offered.

They add up to 4 x cycles in every run (a bench check). With µops retired this is Top-Down's first level: retiring = µops retired, bad speculation = µops renamed − µops retired + recovery, front end, back end. It tells where CoreMark/MHz is lost, the measure since 2026-11-05.

**The events** (the number is what mhpmevent selects; **bold**: the same meaning as mmRISC-2's, so its scripts and the device tree's raw events carry over):

| # | Event | A cycle | Where |
|---|---|---|---|
| 0 | nothing | | |
| **1** | **cycles** | 1 | |
| **2** | **instructions retired** | 0–8 | `cmt_instret` (minstret's) |
| **3** | **loads retired** | 0–4 | `cmt_ld_n` |
| **4** | **stores retired** | 0–4 | `cmt_st_n` |
| **5** | **conditional branches** resolved | 0–1 | port 0's EX into `br_*` (not killed; the wrong path's in, as mmRISC-2's) |
| **6** | **mispredictions** (branches and jumps) | 0–1 | `OOO_CTRL`'s restore |
| **7** | **I$ misses** (line fills) | 0–1 | `OOO_ICACHE`'s read requests (`OOO_CPU`, an input of the core) |
| **8** | **D$ misses** (line fills) | 0–1 | `OOO_DMISS2`'s line reads (the same) |
| **9** | **ITLB misses** (walks) | 0–1 | a walk started for the fetch |
| **10** | **DTLB misses** (walks) | 0–1 | a walk started for the LSU |
| 11 | the head waits on a load or store | 0–1 | the ROB not empty, nothing committed, the head a memory µop |
| 12 | slots lost to the front end | 0–4 | renaming, above |
| 13 | replays | 0–1 | `OOO_ROB`'s replay (a load past an older store, a non-speculative µop, ...) |
| 14 | the head waits, not on memory | 0–1 | as 11, the head anything else (the MDU, the FPU, ...) |
| **15** | **exceptions** | 0–1 | a trap, not an interrupt |
| **16** | **interrupts** | 0–1 | `tr_int` |
| 17 | slots lost to the back end | 0–4 | renaming |
| **18** | **L2 reads** (L1 fills) | 0–1 | `CPU_L2`'s `ev_read` (unused today in `OOO_CPU`) |
| **19** | **L2 misses** | 0–1 | `CPU_L2`'s `ev_miss` |
| 20 | slots used: µops renamed | 0–4 | renaming |
| 21 | slots lost to recovery | 0–4 | renaming |
| 22 | µops retired | 0–4 | `cmt_valid` |
| 23 | dispatch waits for the ROB | 0–1 | the DS register held, the ROB short (first of 23 to 25) |
| 24 | dispatch waits for an issue queue | 0–1 | integer or FP |
| 25 | dispatch waits for the LQ or the SQ | 0–1 | |
| 26 | renaming waits for physical registers | 0–1 | integer or FP |
| **27** | **the walker works for the LSU** | 0–1 | its busy cycles by the walk's owner |
| **28** | **the walker works for the fetch** | 0–1 | |
| 29 | renaming waits for a checkpoint | 0–1 | none free, or the group's limit of 2 |
| 30 | the ROB empty | 0–1 | |

`HPM_EVENTS` 31. mmRISC-2's 11 (MA waits for the D$), 12 (front end empty), 13 (load-use), 14 (MDU / FPU), 17 (back end stuck), 20 to 26 and 29 meant in-order pipeline stages; here they are what the OoO core has instead (11 / 14 at the ROB's head, 12 / 17 / 20 / 21 at renaming, 23 to 26 / 29 the back end's reasons).

**Where the counts go**: each event is made where it happens and registered there (counts 3 bits a slot class, popcounts of 4), then `CORE_CSR`'s `hpm_ev_q` as before: two cycles late. CSR instructions are non-speculative at the ROB's head, so the difference of two reads is exact. The 4 inputs from outside the core (7, 8, 18, 19) come from `OOO_CPU`; `tb_core`'s models drive them (7, 8 from `ICacheModel` / `DMissModel`; 18, 19 0 in the core's bench, real on `OOO_CPU`'s).

**Tests**:
- **A bench check every cycle** (`tb_core`): 12 + 17 + 20 + 21 = 4 a cycle; 2 and 22 against the commits the bench sees; 3 / 4 against the loads and stores it sees retire; 15 / 16 against the traps; at the end, each event's sum against the bench's own count where it has one.
- **`b4/dir/pmu.S`** (new): each event on mhpmcounter3 and 4 around a known piece of code (exact for 2 to 4 and 22, bounds for the rest); MINH / SINH / UINH and mcountinhibit; a counter written near its end: OF, LCOFI in M and delegated to S, scountovf, OF cleared; mcounteren / scounteren (hpmcounter reads trapping in S / U); Smcntrpmf's filters on mcycle / minstret. Lock-step: scountovf's reads take the core's value (as the counters' do).
- run_core, CoreMark unchanged (to the cycle: no event changes what runs), the unit regression; mutations on each event and on the count (a carry lost, a count of 1 for many, the level filter).

**OpenSBI and perf** (29.76's quirks: Smcntrpmf is there; the device tree's events 1 / 2 on the fixed counters and raw events to mhpmcounter3 / 4; OpenSBI's stop / RESET patch, mmRISC-2's `LitexSystem/software/boot/opensbi_patches/0001`): they need OpenSBI on the bench, which L1 brings; checked there with a `pmu-sbi`-like payload before Linux's `perf stat`.

**The cost**: `CORE_CSR`'s add of a count instead of +1 and a 31-way choice of 4 bits for each of 2 counters, `hpm_ev_q` 124 FF; the events' logic and registers (popcounts at renaming and commit, the recovery flag) in `OOO_CORE`: **about +0.4k LUTs, +0.2k FF** (29.76 planned +0.3k). The timing: every event registered where it is made, so no path of the core is lengthened but by a fan-out of a register.

**Next**: the author confirms the events (or changes them), then K1: `CORE_CSR`'s counts, the events in `OOO_CORE` and `OOO_CPU`, the bench check, `pmu.S`, mutations (29.76 has no 20 ns run of its own for K1: the next is J2's, or one when the author wants it).
