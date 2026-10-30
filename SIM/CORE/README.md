# SIM/CORE: the core's test bench

[日本語](README_J.md)

Step B0 of `Plan/CORE.md` (section 5.1): the C++ side of the test bench of `OOO_CORE`, done before the core, and
tested with a stand-in core. Step B1 (section 5.2): the front end alone (`OOO_FRONT`) on it, against Spike's path.
Step B2 (section 5.4): the core with ALU µops only (`OOO_CORE`), in lock-step with Spike. Step B3 (section 5.5): loads
and stores, with a D$ model (`OOO_CORE`) and with OOO_DCAD and the real D$ (`OOO_CPU`).

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
| `build_core.sh` / `run_core.sh` | Build it (`obj/core`); run B2's programs → `results/core.txt`, `results/core_restores.txt` |
| `mutate_core.py` | Bug injection into the core's glue → `results/mutate_core.txt` |
| `b2/` | B2's and B3's programs: `gen_b2.py` (random ALU programs; branches, loops, calls, jumps; loads and stores), `link.ld`, `build.sh` → `b2/work` |
| `b3/` | B3's riscv-tests on an environment without CSRs (`env/riscv_test.h`), the console test `htif.S`, `build.sh` → `b3/work` |

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
  does not compare it when a program turns translation on (`rv64si-p-dirty`).

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

`OOO_CORE` (`RTL/CPU/OOO/OOO_CORE`: the front end, D2 with fusion off, renaming, the control, the DS register, the
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
