# SIM/CORE: the core's test bench

[日本語](README_J.md)

Step B0 of `Plan/CORE.md` (section 5.1): the C++ side of the test bench of `OOO_CORE`, done before the core, and
tested with a stand-in core. Step B1 (section 5.2): the front end alone (`OOO_FRONT`) on it, against Spike's path.

| File | Content |
|---|---|
| `bench.h` / `bench.cc` | The bench: `Memory`, the ELF loader, `Htif`, the commit-trace port (`TraceSlot` → `Commit`), `Bench` (lock-step with `SIM/LOCKSTEP`, watchdog, architectural memory, result) |
| `standin.cc` | Its test: a second Spike as a stand-in core on the bench's memory |
| `build.sh` | Builds `obj/standin` against `~/RISCV/toolchain/spike-install` |
| `run_standin.sh` | The stand-in on riscv-tests and CoreMark → `results/standin.txt` |
| `mutate.py` | Bug injection into the bench and the checker's rules → `results/mutate.txt` |
| `ports.h` | Models of the core's memory ports on `Memory`: `ICacheModel` (B1) |
| `tb_front.cpp` | B1: `OOO_FRONT` under Verilator, a back end of the bench on Spike's path |
| `build_front.sh` / `run_front.sh` | Build it (`obj/front`); run it on riscv-tests and CoreMark → `results/front.txt` |
| `mutate_front.py` | Bug injection into the front end's glue → `results/mutate_front.txt` |

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
| the glue, exactly | **every TAGE update**: the popped block's metadata as its push wrote it, the slots that ran and their outcomes as the bench resolved them on the true path; **every restore** (R + 1) reads back what the block's push wrote (line, history, slots, RAS snapshot); no I$ request in cycle R. These see faults that only cost predictions |
| options | `-full`: no I$ miss and D2 takes 2 a cycle (what the front end delivers); `-lag n`: commit n cycles after D2 (at least 2: a branch resolves before its commit); `-mpki-max x`: fail above x mispredictions per 1000 instructions; `-v`: mispredictions by kind and the blocks pushed between a block's push and its update; `FRONT_BYPC=1`: the conditional branches mispredicted most |

`./run_front.sh`:

| Run | Result |
|---|---|
| 175 riscv-tests `-p-`, 2 seeds | all fetched and decoded in Spike's order to the exit |
| CoreMark g14 -O2 / sf + -flto | pass; every TAGE update (1.74 M) and restore checked |
| delivered (`-full`) | 1.51 / 1.56 instructions a cycle, with every misprediction resolved 2 to 7 cycles after D2 |
| mispredicted conditional branches | 6,582 / 5,742 (8,426 / 6,106 with `-full`); the model: 4,772 / 4,177 |

The model updates TAGE at once; here a block's update comes at its pop, after its last instruction commits, 6.4 to
6.6 blocks after its prediction. That is a small part of the difference; most of it is TAGE's history lag, which
changes with fetch's stalls (`Plan/CORE.md` 5.3, D-17).

## B1's bug injection (`mutate_front.py`)

35 changes of the front end's glue (OOO_FRONT: credit, recovery, the restore's and the update's fields, the
outcomes, the target array, the pc, the skid, the group register; the FTQ's head read and free count; the fetch
buffer's free count), each built and run on 8 riscv-tests and CoreMark with a budget of 2.3 mispredictions per 1000
instructions: **35 of 35 detected** (`results/mutate_front.txt`). The first campaign left 4: the RAS snapshot's
slices and the call's line cost only predictions, CoreMark never needs some of them (the pointer slice: returns 59 →
275, within the budget), and fetch not stopped in cycle R changes nothing visible (the FTQ restore and the buffer's
flush are in R too; a dead I$ request can only hold the I$ on a miss). The bench now checks those exactly: each
restore and each update against what the block's push wrote, no I$ request in R.
