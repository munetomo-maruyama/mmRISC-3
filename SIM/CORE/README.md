# SIM/CORE: the core's test bench

[日本語](README_J.md)

Step B0 of `Plan/CORE.md` (section 5.1): the C++ side of the test bench of `OOO_CORE`, done before the core, and
tested with a stand-in core. Step B1 (section 5.2): the front end alone (`OOO_FRONT`) on it, against Spike's path.
Step B2 (section 5.4): the core with ALU µops only (`OOO_CORE`), in lock-step with Spike. Step B3 (section 5.5): loads
and stores, with a D$ model (`OOO_CORE`) and with OOO_DCAD and the real D$ (`OOO_CPU`). Step B4 (section 5.7):
riscv-arch-test and riscv-tests' -p- programs (CSRs, traps, the MDU) on both.

| File | Content |
|---|---|
| `bench.h` / `bench.cc` | The bench: `Memory`, the ELF loader, `Htif`, the commit-trace port (`TraceSlot` → `Commit`), `Bench` (lock-step with `SIM/LOCKSTEP`, watchdog, architectural memory, result) |
| `standin.cc` | Its test: a second Spike as a stand-in core on the bench's memory |
| `build.sh` | Builds `obj/standin` against `~/RISCV/toolchain/spike-install` |
| `run_standin.sh` | The stand-in on riscv-tests and CoreMark → `results/standin.txt` |
| `mutate.py` | Bug injection into the bench and the checker's rules → `results/mutate.txt` |
| `ports.h` | Models of the core's memory ports on `Memory`: `ICacheModel` (B1), `DCacheModel` (the LSU's D$ port, B3), `Axi4Mem` / `AxiLite` (the D$'s buses, B3) |
| `tb_front.cpp` | B1: `OOO_FRONT` under Verilator, a back end of the bench on Spike's path |
| `build_front.sh` / `run_front.sh` | Build it (`obj/front`); run it on riscv-tests and CoreMark → `results/front.txt` |
| `mutate_front.py` | Bug injection into the front end's glue → `results/mutate_front.txt` |
| `ftqdepth.sh` | What the front end delivers with an FTQ of 8 and of 16 blocks, against the delay to commit → `results/ftqdepth.txt` |
| `tb_core.cpp` | B2: `OOO_CORE` under Verilator on the bench, in lock-step; the branches' resolution checked against their instructions |
| `build_core.sh` / `run_core.sh` | Build it (`obj/core`, `obj/cpu`); run B2's, B3's and B4's programs → `results/core.txt`, `results/core_restores.txt` |
| `run_coremark.sh` | CoreMark (Plan/trace's three builds) on both tops in lock-step → `results/coremark.txt`; `OOO_CPU` on the board's memory with `-mlat 16 -mspread 5` (measured at step 2.5) |
| `lat/` | `gen_chase.py`, `run_lat.sh`: the pointer chase of `LitexSystem/software/dramlat` on `OOO_CPU` for `-mlat` values, the memory model's calibration against the board (step 2.5, `LitexSystem/docs/BRINGUP.md` 27); `gen_chase.py <KB> stream`: 8 independent loads a line (the read throughput); `probe.sv`: a D$ miss printed cycle by cycle, bound into `OOO_LSU4` and `OOO_DMISS2` (`PROBE=lat/probe.sv OBJ=<dir> ./build_core.sh cpu`, then `+plo=<cycle> +phi=<cycle>`; `Plan/OOC.md` 29.108) |
| `mutate_core.py` | Bug injection into the core's glue → `results/mutate_core.txt` |
| `b2/` | B2's and B3's programs: `gen_b2.py` (random ALU programs; branches, loops, calls, jumps; loads and stores), `link.ld`, `build.sh` → `b2/work` |
| `b3/` | B3's riscv-tests on an environment without CSRs (`env/riscv_test.h`), the console test `htif.S`, `build.sh` → `b3/work` |
| `b4/` | B4's riscv-arch-test: `act/` (the core's configuration for the tests: `rvtest_config.h`, `rvmodel_macros.h`, `riscv_arch_test.h` with `act_sig_macros.h`, `link.ld`); `dir/illegal.S`, a directed test of the exceptions found at decode; `build.sh` → `b4/work/<group>` |

## What the bench gives

| Part | What it does |
|---|---|
| `Memory` | The core's memory: sparse 4 KB pages over one RAM region (0x8000_0000, 64 MB, the reference's), loaded from the ELF file. The models of the I$ / D$ ports (B1, B3) and later of AXI4 read and write it; `write()` / `write64()` call a hook through which HTIF sees what reaches the memory |
| ELF | `load_elf_image()`: the loadable segments and every symbol (`tohost`, `fromhost`, `begin_signature`, `end_signature`). Its own loader, not LOCKSTEP's: a wrong image shows as a mismatch |
| `Htif` | **Exit and console from the committed stores** (program order, whatever the store queue and the D$ hold); **`tohost` back to 0 from the memory side**, at the tick after a write that makes it nonzero reaches the memory (as mmRISC-2's tb_CORE) |
| `TraceSlot` | One µop of the commit-trace port (below), turned into 1 or 2 `Commit` records |
| `Bench` | `commit(slots, n)` with each cycle's slots, oldest first; `tick()` once a cycle. Lock-step at every instruction (optional), the watchdog (no commit for 100,000 cycles; a limit of cycles), the **architectural memory** (the ELF image with the committed stores: riscv-arch-test's signature is written from it, not from a memory behind a write-back D$), on a failure the last 16 commits disassembled |

```c++
BenchCfg cfg;  cfg.elf = "test.elf";
Bench b(cfg);                       // loads b.mem(); the core starts at b.entry()
while (!b.done()) {
    // ... one clock of the core; its memory models use b.mem() ...
    TraceSlot s[2];  int n = /* copy the commit-trace port */;
    b.commit(s, n);
    b.tick();
}
printf("%s\n", b.summary("test").c_str());   // PASS / FAIL, exit code, instructions, µops, cycles, IPC
```

## The commit-trace port

What `OOO_CORE` gives under `ifdef` (simulation only, `Plan/CORE.md` 3.9), per commit slot (2 a cycle, slot 0 the
older), the fields of `TraceSlot`:

| Field | Meaning |
|---|---|
| valid | the slot commits a µop this cycle |
| `pc`, `insn[0]`, `insn[1]` | the µop's pc, its instruction(s) (a compressed one in the low 16 bits) |
| `pair` | a fused pair: `insn[1]` is at `pc` + the length of `insn[0]` |
| `trap`, `cause` | an exception at `pc` (never a pair: a pair that faults is fetched again unfused) |
| `rd`, `rd_fp`, `rd_val` | the µop's one register write (−1: none; x0 counts as none) |
| `wr_first` | in a pair, the write is the first instruction's (ALU + branch); otherwise the second's. A first half that does not write and is not a store becomes `rd_skip` |
| `st[0]`, `st[1]` | the store of each instruction: valid, address, data, size (a store pair has both) |

## Rules

- **Polling `tohost`**: in the core a character's store reaches the memory later than in Spike, so `while (tohost);`
  (`Plan/icount/port/minilib.c`) runs more times. LOCKSTEP gives the reference the core's value for loads of
  `tohost` and `fromhost` (added 2026-10-29, `SIM/LOCKSTEP/README.md`), and the reference runs the same loop.
- **`tohost`'s line must not stay in the D$** (B3): with the real write-back D$ a character's store would stay in the
  D$ and the core would read it back for ever. To be done with the D$ at B3: the bench makes `tohost`'s line
  non-cacheable for the core (the D$ adapter sends its loads and stores to the memory; a bench parameter under
  `ifdef`). Until then the port models write the memory directly.
- **The architectural memory holds without translation** (Phase 1): a store commits its virtual address. The stand-in
  does not compare it when a program turns translation on (`rv64si-p-dirty`). Since step 1.8 V1 (`Plan/OOC.md` 29.87)
  `tb_core`'s architectural memory takes the store's physical address from the lock-step (`SIM/LOCKSTEP`: Spike's tables).

## The stand-in test (2026-10-29)

The stand-in is a second Spike that runs on the bench's memory the way the core will:

- it fetches and loads from `Memory` (the bench's ELF loader);
- the page(s) of `tohost` and `fromhost` are a device for it: a store there waits 0 to 24 cycles in a queue before it
  reaches `Memory` through `write()`, as behind the store queue and the D$; a load there takes the newest queued
  bytes first (store-to-load forwarding);
- its commits go through the trace port: 0, 1 or 2 slots a cycle, two instructions fused into one slot where one
  register write per pair allows it.

| Check | What must happen |
|---|---|
| expected | the reference alone (`Lockstep::step_ref`) to its exit: exit code and console |
| clean | the bench with lock-step passes, with the expected exit code and console; the architectural memory equals the stand-in's memory (`tohost` apart) |
| free | the same without lock-step |
| mutated | one wrong field in one slot of the port (13 kinds: register value, register number, write missing, pc, instruction, second instruction, write of the other half, store data, store missing, pair split, trap cause, slot dropped, slots swapped), before the exit's slot: a lock-step mismatch |
| watchdog | (the first file) commits stop half way: ended as "no commit"; a limit of half the cycles: ended as "no exit" |
| HTIF alone | a character then a 4-byte exit over it, `fromhost` is not `tohost`, the exit code from a store of the upper word first, `tohost` back to 0 at the tick and only then |

`./run_standin.sh`: the programs of `SIM/LOCKSTEP/run_selftest.sh` (175 riscv-tests `-p-` and the two g14 CoreMark
builds), 13 port mutations each.

| Result | |
|---|---|
| clean and free runs | 177 of 177 pass, with the reference's exit code and console; the memory compares equal (not compared in `rv64si-p-dirty`, which turns translation on) |
| exit codes | not 0 only where they are for the reference too: `ma_data`, `amocas_*` (as in `SIM/LOCKSTEP`) |
| port mutations | 2,019 of 2,019 caught; 282 did not apply (a program without a store or a trap before its exit, for example) |
| polling `tohost` | CoreMark polled a busy `tohost` 3,667 times (g14 -O2) and 6,715 times (g14 sf + -flto): 2 instructions each that Spike alone does not run; the lock-step follows them |
| watchdog, HTIF alone | pass |
| fused pairs | 12 to 14 % of the µops (CoreMark: 379k of 2.77M, 306k of 2.54M slots) |

The results are in `results/standin.txt`.

## Bug injection (`mutate.py`)

18 changes of `bench.cc` and of the checker's rule for loads of `tohost` (`lockstep.cc`), each built and run on 4
riscv-tests and a CoreMark build: **18 of 18 detected** (`results/mutate.txt`). The campaign also removed two things:

- the architectural memory's `tohost` was set back to 0 after an HTIF action: redundant, since the comparison leaves
  the `tohost` word out (removed);
- "the committed `tohost` not cleared after an action" survived, as no program here writes part of `tohost` after a
  character: the HTIF unit check of `standin.cc` covers it now.

## B1: the front end alone (`tb_front`, 2026-10-29)

`OOO_FRONT` (fetch, the FTQ, the restore, the fetch buffer, the skid, decode, the D1 / D2 group register) under
Verilator, fetching through `ICacheModel` (8 % misses) from the bench's `Memory`, with Spike's run as the true path.
The bench stands in for D2 and the back end:

| Part | What it does |
|---|---|
| D2 | takes 0 to 2 instructions a cycle from the group register (at most one predicted taken: its target from the target array). On the true path each must be Spike's next instruction (pc, bits, length, last parcel); decode's illegal only where Spike traps so; CSR / FP / system classes as the bits say (the classes decode gives in slot 0 only) |
| resolution | the predicted next address against Spike's: a misprediction redirects 2 to 7 cycles later (restore: block, last parcel, outcome, call / return, on a random ALU port); meanwhile D2 takes the wrong path and resolves some of its branches at random (they must not reach the TAGE update). A trap, a SYSTEM instruction and FENCE.I redirect at their commit (flush) |
| commit | in order, 4 to 10 cycles after D2, 2 a cycle; stores go into `Memory` (FENCE.I sees the new code); the FTQ pops as OOO_CTRL pops it (one a cycle; a flush drops the rest) |
| the glue, exactly | **every TAGE update**: the popped block's metadata as its push wrote it, the slots that ran and their outcomes as the bench resolved them on the true path; **every restore** (R + 1) reads back what the block's push wrote (line, history, slots, RAS snapshot); no I$ request in cycle R; the skid holds a group only while D1a's R does; TAGE's update (registered) is the pop's of the cycle before. These see faults that only cost predictions or cycles |
| options | `-full`: no I$ miss and D2 takes 2 a cycle (what the front end delivers); `-lag n`: commit n cycles after D2 (at least 2: a branch resolves before its commit); `-mpki-max x`: fail above x mispredictions per 1000 instructions; `-v`: mispredictions by kind and the blocks pushed between a block's push and its update; `FRONT_BYPC=1`: the conditional branches mispredicted most; `FTQW=4 ./build_front.sh`: an FTQ of 16 blocks (default 8) |

`./run_front.sh`:

| Run | Result |
|---|---|
| 175 riscv-tests `-p-`, 2 seeds | all fetched and decoded in Spike's order to the exit |
| the same, `-full -lag 40` (since D-18) | the same, with the FTQ of 16 full now and then (at B1's random delays it never fills) |
| CoreMark g14 -O2 / sf + -flto | pass; every TAGE update (1.74 M) and restore checked |
| delivered (`-full`) | 1.51 / 1.56 instructions a cycle, with every misprediction resolved 2 to 7 cycles after D2; **1.44 / 1.49 with D1a / D1b** (`Plan/OOC.md` 26.8), limited by the FTQ of 8 blocks; **1.824 / 1.826 with the FTQ of 16** (D-18, the default since 2026-10-29; `ftqdepth.sh`) |
| mispredicted conditional branches | 6,582 / 5,742 (8,426 / 6,106 with `-full`); the model: 4,772 / 4,177 |

The model updates TAGE at once; here a block's update comes at its pop, after its last instruction commits, 6.4 to
6.6 blocks after its prediction. That is a small part of the difference; most of it is TAGE's history lag, which
changes with fetch's stalls (`Plan/CORE.md` 5.3, D-17).

## B1's bug injection (`mutate_front.py`)

43 changes of the front end's glue (OOO_FRONT: credit, recovery, the restore's and the update's fields, the
outcomes, the target array, the pc, the skid, D1a's register R, the group register; the FTQ's head read and free count; the fetch
buffer's free count), each built and run on 8 riscv-tests (also with `-full -lag 40`, where the FTQ fills) and CoreMark with a budget of 2.3 mispredictions per 1000
instructions: **43 of 43 detected** (`results/mutate_front.txt`; 35 before D1a / D1b, 40 before the registered TAGE update). The first campaign left 4: the RAS snapshot's
slices and the call's line cost only predictions, CoreMark never needs some of them (the pointer slice: returns 59 →
275, within the budget), and fetch not stopped in cycle R changes nothing visible (the FTQ restore and the buffer's
flush are in R too; a dead I$ request can only hold the I$ on a miss). The bench now checks those exactly: each
restore and each update against what the block's push wrote, no I$ request in R. With D1a / D1b (2026-10-29) "R
empty not counted as free" was left (a group waits in the skid a cycle for nothing): the bench checks that the skid
holds a group only while R does. With the FTQ of 16 (D-18) the two credit mutations of the FTQ were left: it never
filled; the run with `-full -lag 40` fills it.

## B2: the core with ALU µops only (`tb_core`, 2026-10-30)

`OOO_CORE` (`RTL/CPU/OOO/OOO_CORE`: the front end, D2 with ALU + branch pairs turned off (B5a, off since 5.21; the trace gives a pair's second instruction, `tr_pair` / `tr_insn2`, and the resolution of a pair is checked against its branch), renaming, the control, the DS register, the
ROB, the issue queue, the register file, two ALU ports, branch resolution, commit) under Verilator, fetching through
`ICacheModel` (8 % misses) from the bench's `Memory`. Its commit trace (`OOO_TRACE`: per ROB entry the instruction,
written at dispatch, and the value, at completion) goes to `Bench` in lock-step with Spike at every instruction.

| Part | What it does |
|---|---|
| start | `boot` / `boot_pc` (the ELF's entry) two cycles after reset; `trap_vec` 0 (no CSRs in B2) |
| exit | B2's programs have no memory, so no HTIF: they end at the symbol `pass` (`-exit pass`, `BenchCfg.exit_sym`): the run passes when that instruction commits and every one before it matched |
| the resolution, exactly | every branch and jalr resolved, against its instruction (the ROB entry's shadow): the last parcel, taken for a jalr, call / return (x1 / x5, as predecode), a branch's outcome and parcel to the TAGE update, the BTB's write of an indirect jump at its last parcel. Lock-step cannot see these: they only steer the predictors |
| options | `-seed`, `-miss`, `-max`, `-v` (restores, I$ misses); `-restores-out` writes each program's restores, `-restores-ref` / `-restores-max x` fail a run above x times the reference (+ 4) |

`./run_core.sh`: 20 ALU programs and 20 with branches (`b2/build.sh 20`), on 2 seeds and with no I$ miss: **all
pass**. The ALU programs run about 645 instructions in 400 cycles (IPC 1.58 to 1.63), the branch programs 6k to 16k
instructions with 136 to 552 restores (IPC 0.70 to 0.98). `results/core.txt`.

## B2's bug injection (`mutate_core.py`)

40 changes of OOO_CORE's glue in the first campaign, each built and run on 4 ALU and 10 branch programs with a budget of restores; 12 were left. **Seven are caught now**: by the check of the resolution (a jalr call not marked a call, a jalr not taken for FERS) and by programs with what the first ones lacked (c.jalr's link, a jalr's offset, a call through the other link register, bursts of branches that run the checkpoints out, where renaming takes 1 µop of 2 and µop 1's checkpoint id matters). **Five are equivalent and left out** (the reasons in `mutate_core.py`): the wrap of the rotated slots (never valid: the mask is gone from the RTL), an empty µop's destination counted by renaming's ready (64 registers never run short with 26 in flight), the branch masks into RR and EX (a killed µop acts at most 2 cycles after a restore, and the restart reaches renaming 6 cycles after it at the earliest), the register file written by an empty EX stage (an empty stage carries wr 0). **35 of 35 detected** (`results/mutate_core.txt`).

## B3: loads and stores (2026-10-31)

`tb_core` built two ways (`./build_core.sh` / `./build_core.sh cpu`):

| Top | The D$ | Notes |
|---|---|---|
| `OOO_CORE` | `DCacheModel` on the LSU's abstract port: a request in E answered in M (a hit at random, `-dhit`, default 80 %), a miss's fill later (out of order), dropped on `dc_kill`; stores written into `Memory` when taken (ready at random) | Memory is the D$: nothing incoherent |
| `OOO_CPU` | `OOO_DCAD` and mmRISC-2's D$; `Axi4Mem` (bursts with random readies and delays) and `AxiLite` on `Memory` | `tohost`'s line is not cached (`sim_uc_line`, DCACHE_SIM_UC): HTIF clears it in the memory, which the console's polling loop sees |

The commit trace gives each store's address, data and size; the bench's HTIF takes the exit and the console from the
committed stores as in B0. `-v` also gives the replays (loads that raised `ld_cancel`, replayed after commit) and the
D$'s or the buses' counts.

`./run_core.sh` (`results/core.txt`): on `OOO_CORE` the 60 random programs (`b2`: ALU, branches, loads and stores) on 2
seeds and with no I$ miss and no D$ hit, and the 96 programs of `b3` (riscv-tests, the console) on 2 seeds; on
`OOO_CPU` both sets: **all pass**. The console on `OOO_CPU` took 301,300 cycles for 25 characters: a store waited for a
cycle with no load in E, and the polling loop issues one nearly every cycle (`Plan/CORE.md` 5.5). Since 5.6 (a store
takes the D$ port after loads have held it off 8 cycles): 2,240.

## B3's bug injection

B2's 35 mutations and 20 for port 2 and the LSU (the record's LQ / SQ entries; loads and stores at dispatch to the LSU, the ROB and the control; the LSU's operands, the offset, the size and sign; the bypass of the base, of a store's data and of the LSU's result; the register-file write of loads; the replay mark; the SQ's restore and commit), each run on 20 random programs and on 10 riscv-tests and the console, on OOO_CORE with the D$ model: 54 of 55 detected. The one left, the late load's external wakeup, was redundant and is gone (B3-3). **54 of 54 detected** (`results/mutate_core.txt`).

## B4: riscv-arch-test, the CSRs and traps (2026-10-31)

`b4/build.sh` builds riscv-arch-test's (`~/RISCV/riscv-arch-test`, the ACT4 framework) I, M, Zca, Zba, Zbb, Zbc, Zbs,
Zicond, Zicsr, Zifencei and Zicntr tests and the Sm and Exceptions tests (generated by the framework's testgen into
`b4/work/gen`; those whose required extensions fit the core), 185 in all, as the framework builds its signature ELF
(`-DSIGNATURE`, the test's own `-march`, `-mno-relax` for binutils 2.43) on `b4/act`. The framework would compute the
expected values with Sail; here the lock-step with Spike checks every register written, every store (the signature
is stores) and every trap. `b4/act`:

| File | What |
|---|---|
| `rvtest_config.h` | the core's configuration, by hand (the framework generates it from UDB): RV64, M / S / U, C, the B parts, Zicond, Zicsr, Zifencei, Zicntr, Zihpm (2 counters), 8 PMP entries, mtvec / stvec direct and vectored |
| `rvmodel_macros.h` | HTIF's halt; x1 to x31 cleared at boot (the PRF has no reset, and the trap handler saves registers the test has not written yet); no access-fault address (none in Phase 1); empty interrupt macros |
| `riscv_arch_test.h`, `act_sig_macros.h` | the framework's top header with `act_sig_macros.h` for `sail_macros.h`: no Sail CLINT (the boot's parking store to mtimecmp goes to `act_mtimecmp` in the image), the rest as `sail_macros.h` |
| `link.ld` | the framework's example with the bench's 64 MB RAM |

`./run_core.sh` (`results/core.txt`, 12 runs) adds the 185 tests on `OOO_CORE` (2 seeds: 80 % and 30 % D$ hits) and
on `OOO_CPU`, and riscv-tests' -p- programs of mmRISC-2 (`$RVTESTS`) but the three Phase 1 cannot run
(`rv64mi-p-breakpoint`: the triggers' firing is not wired; `rv64mi-p-csr`: an FP instruction; `rv64si-p-dirty`:
paging), 127, on both, and `b4/dir/illegal.S` (FP instructions with mstatus.FS off, illegal compressed encodings and
their tval, in either slot): **all pass**. On the way they found a load to x0 and a multiply to x0 forwarded with tag
0 (the multiply also took port 0's write slot from an ALU µop), mcountinhibit taking effect for its own instruction,
mconfigptr missing, FP loads and stores not illegal, and the FP CSRs not illegal with FS off (`Plan/CORE.md` 5.7);
`gen_b2.py`'s `ls` programs now load and multiply into x0, and multiply after divides.

`tb_core` makes a new model for each program of a run, and Verilator's random initial values (`--x-initial unique`)
continue through the run: a change that adds or removes registers changes the initial values of what has no reset
(the predictors' tables) in the models after the first, and so some cycle counts in `results/core.txt`. To compare
two RTL versions cycle for cycle, run each program alone (`Plan/CORE.md` 5.15).

## B4's bug injection

`mutate_core.py`, now 84 mutations, run on B2's and B3's programs and then on B4's: B3's 54 (4 follow lines the B4 glue renamed, the WB one split by port), the load to x0's bypass, and 28 for B4 (the exceptions at decode, their cause and tval; the units' µops: kind, MRET, FENCE.I, non-speculative, the MDU's wakeup, the instruction bits, the CSR operand and result, a multiply into the MDU as well, the MDU's write slot, the tag-0 results of the multiplier and the MDU, SRET; completion and tval; OOO_CSRU's counting, tval and the FS check). The first campaign left 6 undetected: an FP instruction not illegal, the tval of an exception in slot 1, an illegal RVC instruction's tval (no program made the case), a multiply into the MDU as well, the MDU's result over the multiply's, a divide to x0 forwarded (no program mixed divides and multiplies). `b4/dir/illegal.S` (which then found bugs 5 and 6) and `ls` programs that multiply after divides and mulh caught five; the sixth, the RVC instruction's tval masked to 16 bits, was redundant (`OOO_FBUF` already gives an RVC instruction with its upper half 0) and the mask is gone. **84 of 84 detected** (`results/mutate_core.txt`). Unit mutations M356 to M358 (a write to minstret counting its own commit, mcountinhibit written in EX, written again at every commit): 3 of 3 detected by `tb_csru`; 322 now.

## CoreMark, first run (2026-10-31)

`./run_coremark.sh` (`results/coremark.txt`): the three builds of `Plan/trace` on `OOO_CORE` with no I$ miss and
every D$ load a hit, on `OOO_CPU` with the real D$, and on `OOO_CORE` with misses at random (2 seeds): **all pass** in
lock-step, about 2.1 to 2.3 million cycles a build, 26 % behind the model without fusion (`Plan/CORE.md` 5.8). On the
way: port 0's write-back register took the mask of the µop in EX for the multiplier's result (fixed in `OOO_CORE`);
the register file is now set to 0 after reset (Spike's registers start at 0, and CoreMark saves registers it has not
written); `DCacheModel` applied a kill before queueing the miss of that cycle's M (fixed). `tb_core` calls the model's
`final()` (a build with counters prints them). Since `Plan/CORE.md` 5.9 (loads wait in the issue queue for the
older stores): 1.72 to 1.97 million cycles, 10 % to 13 % behind the model; `-replays-max` fails a run with more
replays (the CoreMark stage of `mutate_core.py`). Since 5.11 (D-17, TAGE read with the history lagging 2 blocks):
1.71 to 1.96 million cycles, 9 % to 12 % behind the model. Since 5.13 (the multiply writes through port 1): 1.70 to
1.91 million cycles, 7.7 % to 9.4 % behind. Since 5.14 (a load completes in M): 1.68 to 1.87 million, 6.5 % to
8.1 % behind.

## The atomics (step 1.4 E1c, 2026-11-15)

`Plan/OOC.md` 29.74. `b4/build.sh` builds riscv-arch-test's Zaamo (18) and Zalrsc (4) and the generated
Exceptions_Zaamo / Exceptions_Zalrsc (`FIT` takes Zaamo and Zalrsc; `rvtest_config.h` lists them): 209 tests now.
`run_core.sh` and `mutate_core.py` take riscv-tests' rv64ua -p- (18 AMOs and lrsc; not amocas, Zacas): 146 now.
`b4/dir/atomic.S`: AMOs right behind stores to their word with a load and a store right after, every operation, both
sizes and halves; a chain of AMOs; AMOs that miss on 12 lines of one D$ set; LR / SC by Spike's rule (the reservation
is the LR's address; only SC clears it, not a trap, not a store); misaligned atomics and atomics at 0x1000_0000 (an
access fault in the core and in Spike, which has memory only at 0x8000_0000); AMOs that miss with younger stores
behind them, their addresses in the SQ before the AMO goes again. All pass on both tops; CoreMark unchanged
to the cycle. Core mutations: 29 new, **166 of 174 detected**, the 8 undetected the old ones. An AMO's try writing
another SQ entry was caught only after `atomic.S`'s part 6 (the AMOs that miss among younger stores); an AMO computing
before its rs2 is there is equivalent in time and left out (the header of `mutate_core.py`).

## The interrupts (step 1.8 I1, 2026-11-15)

`Plan/OOC.md` 29.78. `OOO_CPU` has mmRISC-2's CLINT and PLIC (`RTL/CPU/MMIO`) on its peripheral bus; the PLIC's sources
1 to 31 are bits 1 to 31 of the bench's word at 0x1100_0000 (`IRQ_DEV`), which a program writes and `AxiLite` keeps (it
is outside `Memory`). `OOO_CORE`'s interrupt lines are held at 0, so the interrupts' programs run on `OOO_CPU` alone:
`b4/irq/irq.S` (the timer, software and external interrupts over every kind of work, WFI, the time CSR against mtime, delegated S-mode ones with Sstc's timer) and
riscv-arch-test's InterruptsSm (21) and InterruptsS (11), built with `MMRISC_IRQ` (`b4/act/rvmodel_macros.h`: msip,
mtimecmp, the PLIC's source 1 to context 0 and source 2 to context 1). Lock-step makes Spike take the interrupt the core
took and hides the devices' (`SIM/LOCKSTEP`; SSIP, a CSR write's, stays Spike's own). `-exit0` fails a run whose exit code is not 0: a self-checking program whose
interrupt never came ends at its own bound, as Spike does. `b4/dir/devld.S`: loads from a device at the ROB head with
nothing in flight, on both tops. Three older bugs found: such a load waited for ever (`OOO_LSU4`), the device port sent
the word's address (the PLIC's registers at +4 missed: `OOO_DMISS2`, `OOO_LSU4`), WFI in U mode waited (`OOO_SYS`).
All pass; CoreMark's timed window unchanged to the cycle. Core mutations 178/186: the 12 new ones (174 to 185, a fifth stage on `OOO_CPU` with the interrupts' programs under `-exit0`) all detected; the same 8 undetected. **Step 1.8 I2** (`Plan/OOC.md` 29.79): `CPU_PLIC`'s choice a tree and the interrupt lines registered (the first run at 20 ns: -19.4 ns); `irq.S` part 3b polls the PLIC's claims (priorities, the threshold, ties to the lower number); `build_core.sh` takes `MMIO_RTL` and `mutate_core.py` mutates `CPU_PLIC` too: 191, 183 detected (the 5 new all).

## The renamed FPU (step 1.8 U2a, 2026-11-17)

`Plan/OOC.md` 29.82. The core runs F and D: riscv-tests rv64uf / rv64ud and rv64mi-p-csr in run_core's -p- list (170);
riscv-arch-test's F (84), D (116), Zcd (4) and the FP privileged tests (`Sm_F`, `Exceptions_F`) in B4 (`b4/act/rvtest_config.h`
F, D, Zcd; `TEST_FLEN` by each test's -march); `b4/build.sh dsp`: Plan/fpu's 20 DSP kernels (each checking itself; `-v` prints
the kstart to kend window); `b2/build.sh` a 4th kind, `fp` (`gen_b2.py`: ls's program with FP segments, 20 in run_core). The
commit trace says an FP register's write (`tr_fwr`), which the lock-step compares as Spike's. All pass on both tops. Core
mutations: 37 new (191 to 227), 14 old ones moved to the lines U2a changed; the programs of the FP kind, the new B4 groups and
rv64uf / ud in the campaign.

**Step 1.8 U2b** (`Plan/OOC.md` 29.83): FP in every slot, 80 FP registers, an FP queue of 16. `b4/dir/fprm.S`: the rounding
mode's traps (frm 0 to 7 with FP operations that round dynamically and ones that do not; the reserved static modes). All pass;
CoreMark's timed window unchanged. Core mutations: 2 new (228, 229), 202 and 227 moved; 192 caught by `fprm.S`, 212
equivalent in time.

## Sv39, the data side (step 1.8 V1, 2026-11-18)

`Plan/OOC.md` 29.87. `OOO_CORE` translates loads and stores (`OOO_PTW`, `OOO_DTLB3`); fetch waits for V2. `b4/dir/vm.S`:
tables for every kind of page and fault, M mode with MPRV, then S mode under an identity gigapage (Spike translates the
fetch, the core does not: the same bytes), synonyms, SFENCE.VMA, satp changed with and without SFENCE.VMA; its 28
exceptions are Spike's. `rv64si-p-dirty` runs now (in run_core's -p- list, 171). `ports.h`'s `DMissModel` takes a synonym
out before a fill and answers the walker's entries (`dc_pt_*`) from `Memory`; the architectural memory takes each store's
physical address from the lock-step (`Commit::st_pa`). CoreMark's timed window unchanged to the cycle.

## Sv39, the fetch side (step 1.8 V2, 2026-11-19)

`Plan/OOC.md` 29.88. The fetch is translated too (an ITLB in `OOO_FRONT`, the I$'s tags physical): riscv-tests' -v-
programs (155, in run_core's -p- list: 329) and riscv-arch-test's Sv39 groups (`b4/build.sh`'s `Sv`, `Svade`, `Svbare`:
54; the two that jump to an address not canonical left out, as the core's 39-bit pc cannot give Spike's epc) pass on both
tops; `b4/dir/vmx.S` (the fetch's faults, an instruction across two pages, an I$ synonym, SFENCE.VMA, satp). `ICacheModel`
reads the physical address; the trace's pc is sign extended from bit 38. The -v- programs found a bug of V1: a try's
address in the core was zero extended.

## PMP (step 1.8 P1, 2026-11-19)

`Plan/OOC.md` 29.89. CORE_CSR's 8 PMP entries are checked: each LSU port, the fetch word by word, the walker's entries.
riscv-arch-test's PMP group (`b4/build.sh PMP`: 81 of the 82 that fit pass on both tops; `PMP_Sm_cfg_A_tor_zero`, an
access at physical address 0 that Spike faults for having no memory there, is left out) and `b4/dir/pmpx.S` (PMP on the
fetch word by word, an instruction across two blocks). The lock-step's reference has 8 PMP regions now, the core's.

## The store search at E (step 1.8 V3b, 2026-11-19)

`Plan/OOC.md` 29.91. `OOO_LSU4` compares the SQ's offsets and bytes with a load's at E (V3's failing path started with
that compare at M); M's result is unchanged to the cycle. `b4/dir/atomic.S` has a part 7: SCs that fail with one load of
their word right behind, at 1 to 13 adds after the SC's address, so that some load is at E in the SC's W, the cycle its
bytes go (one load an SC: a load that meets the SC's entry before its W waits, is tried again and replayed at its commit,
and what follows it is fetched again: a first version with ten loads behind each SC never let the late ones commit).
Core mutations 261 (an SC failing in the load's E keeps its bytes for the search) and 262 (a store writing its entry in
the load's E not seen).

## The PMU's events (step 1.8 K1, 2026-11-22)

`Plan/OOC.md` 29.98. `OOO_CORE` makes 30 events, each a count per cycle (0 to 8), counted by `CORE_CSR`'s mhpmcounter3 /
4 two cycles late. `tb_core` checks them every cycle: the 4 slots at renaming (events 12, 17, 20, 21) add up to 4;
instructions, µops, loads and stores retired (2, 22, 3, 4) are the trace's commits of the cycle before; events 5, 9 to 12,
14, 17, 20, 21, 23 to 30 against a reference the bench makes from the core's signals of the cycle before (`tb_core.vlt`
makes them readable). At the end of a run that passed: exceptions and interrupts against the trace's traps, restores,
replays, and the I$ / D$ fills against the models (on `OOO_CPU`, after the drain: the L2's reads and misses too). `-v`
prints a PMU line (the slots in %, the waits, walks, fills). `b4/dir/pmu.S` checks the counters themselves: exact counts,
the privilege filters, mcountinhibit, a wrap with LCOFI in M and in S, scountovf, mcounteren / scounteren, Smcntrpmf.
Core mutations 270 to 297.

## Linux and CBO.ZERO (step 1.8 L1, 2026-11-22)

`Plan/OOC.md` 29.99. `SIM/LINUX` builds one ELF of OpenSBI, the kernel and an initramfs that `tb_core` runs on
`OOO_CPU` like a test, to the shell's prompt and a power-off (HTIF's exit). For that run: `-hang n` (cycles without a
commit before a run fails, 20,000 by default; Linux waits in WFI between its ticks), `-console` (HTIF's characters as
they come), `-progress n` (the run's line every n cycles). The boot found CBO.ZERO missing in the core (Linux zeroes
its pages with it): `b4/dir/cboz.S` checks it in M mode bare, in S mode under Sv39, on a line that misses, with a
younger store and loads in its line, its page and access faults and CBZE's illegal instruction in S and U. The bench
widens the core's record of it to a 64-byte store of zeros (LOCKSTEP's) and zeroes its line in the architectural
memory; it counts as a store retired (event 4). Core mutations 298 to 313.

## Debug (step 1.8 J1, 2026-11-22)

`Plan/OOC.md` 29.102. `dbgmodel.h` is a debugger on the core's debug ports (in place of `RTL/CPU/DBG`'s Debug Module:
`hart_*`, `reg_*`, and `bm_*` on `OOO_CPU`), in lock-step: `-dbg n` halts the hart every n cycles on average, checks
dpc against the reference's pc and dcsr.cause against the halt, then makes a few random accesses, each checked
against the reference or put into it (a GPR / FPR read, 64 or 32 bits; a GPR, FPR or scratch CSR written, read back
and written back; CSRs both keep alike; the errors: no such CSR, a read-only one, past the FPRs; on `OOO_CPU` memory
read, written, read back and written back, text or data, cached or dirty), then resumes or steps 1 to 3 times (each
step one instruction, traced, or a trap and a halt at the handler; never an interrupt; dpc the reference's pc).
`-dbgf m` adds 1: dcsr.ebreakm / s / u, drawn again at each resume (an EBREAK halts, cause 1, checked against the
bit of dcsr.prv; the debugger steps over it in both), 2: an execute trigger of the debugger's on dpc in trigger 3
(the program's kept and put back; the hart halts again at once, cause 2), 4: resethaltreq in half the runs (a halt
before the first instruction, cause 5, nothing committed before it), 8: SSIP pending and enabled through some steps
(the steps take none). minstret is among the CSRs compared (debug mode's sequences not counted). While halted the PMU's events are checked to be 0 but cycles, the restores and replays of debug mode are
not counted, and the fills are not compared at the end; the FP file starts at 0 as Spike's (a debugger reads it).
`b4/dir/ebrk.S` is the debugger's vehicle for EBREAK (in M, S with C.EBREAK, and U). `b4/dir/trig.S` checks the triggers of action 0 (execute on a compressed instruction and on a word's second halfword, tcontrol.MTE and mstatus.MIE,
loads, stores, a misaligned load's breakpoint first, AMOs, FP loads, two at one instruction, tselect, S and U
modes, hit, tval); `rv64mi-p-breakpoint` runs. run_core runs the b4 set with `-exit0` (the self-checking programs'
verdicts count, though the reference takes values such as `tdata1`'s from the core) and adds the debugger's runs:
ebrk.S, trig.S, b3 and the rv64mi / si -p- programs with `-dbg 200 -dbgf 15` on both tops. Core mutations 314 to 339; `SIM/OCD` runs
OpenOCD on `OOO_CPU` with the Debug Module.
