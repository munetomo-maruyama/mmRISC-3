# mmRISC-3 Development Strategy (Nexys Video, XC7A200T, 4-wide, 100 MHz)

[日本語](STRATEGY_J.md)

- Date: 2026-11-02 (the author's change of plan, `Doc/PROMPT.md` entries 131 and 134)
- Replaces: [`Plan/STRATEGY_A100T.md`](../Plan/STRATEGY_A100T.md), the strategy for the Arty A7-100T, kept as history
- Board details: [`Doc/BOARD.md`](BOARD.md). Micro-architecture: [`Doc/UARCH.md`](UARCH.md)

---

## 0. Summary

1. **The FPGA**: the **XC7A200T-1SBG484C on a Digilent Nexys Video**, in place of the Arty A7-100T.
2. **The goal, chosen knowing it is a challenge: 4-issue at 100 MHz**, with `-O2` above **6.0 CoreMark/MHz**, so above
   **600 CoreMark per second**: 1.8 times the best 50 MHz design, 4.3 times mmRISC-2. Then BusyBox and Debian 13 from the
   microSD slot J3, Ethernet (RTL8211E), JTAG / cJTAG on Pmod JA.
3. **The proposal**: 4 renamed, dispatched and committed a cycle, **4 issues (3 ALUs + LSU) from distributed schedulers**,
   6 decoded from a 32-byte fetch, stores split in 2 µops, ROB 48, LQ / SQ 16, 12 checkpoints, TAGE M, in a pipeline about 4 stages
   longer: **6.71 in the model as built so far, about 6.3 in RTL, 631 CoreMark/s** (6.90, 6.5, 650 before the blocks were built), about 98k LUTs (73 %).
4. **Six loops decide it** (section 4.5), and **they are measured first**. Today's blocks at a 10 ns target are done (step
   1.0: nothing refutes 100 MHz, nothing proves it); the new loops alone are next. If they fail, the CPU's clock comes down without changing the design: the fallback is 75 to 90 MHz, still
   ahead of 50 MHz.
5. **Reuse is kept by half-rate islands** (section 4.4): the FPU, the multi-cycle MDU, CSRs, the page-table walker, L2 and
   debug stay mmRISC-2's, at 50 MHz, beside a 100 MHz integer core.

---

## 1. Where the numbers come from

**Terms.** "4-issue" is taken as: 4 µops issued a cycle **and** 4 renamed. With 3 renamed, 4 issues reach only 5.85 in a
100 MHz pipeline, below the goal: rename and dispatch width is what gives back the IPC that the deeper pipeline loses.

In `g14 -O2`, the build the goal is measured on (`Plan/model/g100.sh`, `results/g100.txt`; the 50 MHz rows from `g200t.sh`).
"RTL" is the model × 0.94, what today's RTL gives against it:

| Configuration | Clock | Model /MHz | RTL /MHz | CoreMark/s |
|---|---|---|---|---|
| Today's core, 2-wide | 50 | 5.81 | 5.50 (measured) | 275 |
| 3-wide, 4 issues (the earlier proposal) | 50 | 7.17 | 6.7 | 337 |
| 3-wide, 4 issues | 100 | 5.85 | 5.5 | 550 |
| 4-wide, 4 issues, 16-byte fetch | 100 | 6.25 | 5.9 | 587 |
| 4-wide, 4 issues, stores split | 100 | 6.48 | 6.1 | 609 |
| 4-wide, 4 issues, stores split, 32-byte fetch, 6 decoded: the proposal, its loops ideal | 100 | 6.90 | 6.5 | 649 |
| **The same as built so far: `OOO_SCHED`, `OOO_EXU`, `OOO_UBTB2`, stores in 2 µops, 2 checkpoints a cycle, steering a cycle ahead** (`Plan/OOC.md` 28.17) | **100** | **6.71** | **6.3** | **631** |
| + a second LSU port (5 issues) | 100 | 7.17 | 6.7 | 674 |
| + a fourth ALU too (6 issues) | 100 | 7.32 | 6.9 | 688 |

---

## 2. The goal and how it is measured

| Item | Rule |
|---|---|
| Goal | `-O2`: **above 6.0 CoreMark/MHz at 100 MHz** (working target 6.3 in RTL, 6.1 on the board) |
| Where it counts | On the board, under Linux, with the bitstream that runs Linux |
| Compiler | GCC 14.2 (Debian 13); `-O2 -march=rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicond` |
| In simulation | `OOO_CPU` with the real caches and a latency model of the DDR3, in lock-step with Spike |
| If 100 MHz does not close | The clock that closes, and CoreMark/s reported beside CoreMark/MHz |

---

## 3. Resources on the XC7A200T

| | XC7A100T (Arty A7-100T) | **XC7A200T (Nexys Video)** | Ratio |
|---|---|---|---|
| LUTs | 63,400 | **134,600** (33,650 slices) | 2.12 |
| Block RAM | 135 tiles | **365 tiles** | 2.70 |
| DSP | 240 | **740** | 3.08 |
| Speed grade | -1 | **-1 (the same)** | |
| DDR3 | 256 MiB, 16 bits | **512 MiB**, 16 bits, 800 MT/s | |

The whole chip (physical LUTs). **At 100 MHz the ceiling is taken as about 75 %, 101k**, below the 80 % that was usable at
50 MHz: routes are already 82 % of the delay, and congestion was mmRISC-2's main cause of routing delay.

| Part | LUT | Basis |
|---|---|---|
| LiteX SoC with Ethernet | 5.3k | mmRISC-2 4,826 (MII); RGMII estimated |
| Outside the core: L1 caches, L2, debug, MMIO, DMA, arbiter | 12.6k | mmRISC-2 measured; the L1 hit paths repipelined, in the row below |
| Core blocks kept: CSR, MMU, MDU, FPU, FP registers | 21.7k | mmRISC-2 measured |
| **The out-of-order engine, the proposal** | **about 59k** (52k to 66k) | `Doc/UARCH.md` 4.5; today's measured 27.0k |
| **Total** | **about 98k, 73 %** | **Little room**: a second LSU port or a fourth ALU only if it stays under the ceiling |

---

## 4. The micro-architecture for 100 MHz

To be frozen at gate S1-A (section 5). Numbers are the model's; the sensitivity of each is in `results/g100.txt`.

### 4.1 What fits in a cycle

10 ns less clock-to-out, setup and uncertainty leaves about 9.3 ns. A LUT is about 0.15 ns; a route in a congested
design 0.5 ns or more, and with a fan-out above 20 about 1 ns. So **10 to 12 logic levels**, and no large fan-out in a
critical path. (These are working estimates from the reports.) Today's worst paths have 15 to 44 levels, because
nothing asked for less: **they were all measured at a 20 ns target**, so they are upper bounds, not the limit.
`synth_ooo.bat t100` measures them at 10 ns.

### 4.2 The configuration

| Item | Today | **Proposal** | Why |
|---|---|---|---|
| Fetch | 16 B, 3 stages | **32 B, 5 stages** | 32 B + 6 decoded: +6.5 %. I$ and TAGE read in block RAM with their own stages |
| Decode | 4 | **6, 2 stages** | With a fetch buffer in its own stage |
| Between decode and rename | group register | **decoded-instruction queue** | Takes 6, gives 4, so no group boundary (`Plan/CORE.md` 5.19) |
| **Rename, dispatch, commit** | 2 | **4**, rename in 2 stages, 2 checkpoints a cycle (`OOO_RENAME2`) | +6.7 % over 3 at the same clock; 1 checkpoint a cycle −0.4 % |
| **Schedulers** | unified 10, 3 issues | **3 ALU queues of 8, a memory queue of 12**, one select each: **4 issues** | A unified 24 is 1.7 % better but its loop cannot be expected to make 10 ns. Built with a **dependency matrix** and 2-phase dispatch (`OOO_SCHED`, `Plan/OOC.md` 28.4): 6.829 as built |
| ALUs | 1 full, 1 limited | **3 of `OOO_ALUF`**: what CoreMark executes, in 1 cycle (`Plan/OOC.md` 28.6) | |
| Other operations | in ALU0 | Counts, `rev8`, `orc.b`, rotates, min / max, `bset` / `bclr` / `binv`, `bext`, shifts by a register: **3 cycles, queue 0** (`OOO_ALUR`); `jalr` on queue 0 | 6.823 as built, −0.1 %; 2 or 3 cycles alike in CoreMark, others will see it. `slli` next: nothing in CoreMark with Zb, −5.7 % on rv64gc |
| Branch | compare and act in EX + 1 | compare in EX, **misprediction in EX + 1, restore in EX + 2** | Redirect 6 |
| Load-use | 2 | **3**: E, M1 (block RAM), M2 (tags, way, forward, align) | 4 costs −7.9 %, hence the effort |
| Multiply | 2 | **4, pipelined in DSP48** | Through CORE_MDU it would cost −5 % |
| Stores | one µop, with data | **2 µops**: the address in the memory queue, the data on queue 2 alone, into the SQ; **a wait table of 64 bits** for the loads that found no data (decided 2026-11-03) | The earlier +3.8 % assumed no replays: with them 5.767. **6.726, −2.4 %; not split 6.320** (`Plan/OOC.md` 28.13, 28.14) |
| ROB / LQ, SQ / checkpoints | 24 / 8 / 6 | **48 / 16 / 12**, registers **80** | 32 / 12 / 8 costs −7.4 % |
| Register file | 3 writes, 6 reads | **4 writes, 8 reads**, 2 stages (`OOO_PRF2`) | LVT apart from the data read |
| Predictor | TAGE S, uBTB 8 | **TAGE M, uBTB 96**: 32 sets of 3 in LUT RAM (`OOO_UBTB2`) | +1.0 % against 16 in one set (6.889 before the stores); the block reaches about 8.9 ns alone (`Plan/OOC.md` 28.12). uBTB 8 costs −3.5 %, with more stages to an override |
| Fusion | off | **off**; out of the paths (`FUSE_AB`) | |

### 4.3 The pipeline

| Stage | Work | Today, alone, at a 10 ns target (at 20 ns) |
|---|---|---|
| F0 | Next pc: uBTB | 11.9 ns (12.9), 8 entries |
| F1 | I$, TAGE, BTB: block RAM address | |
| F2 | Block RAM data; I$ tags | |
| F3 | Predecode, TAGE decision, **override** | |
| F4 | Into the fetch buffer and FTQ | 14.3 ns (19.1), all of the front end |
| D1 | Fetch buffer: instruction boundaries | 13.3 ns (16.9): split so the head pointer's loop is short |
| D2 | Decode | 9.0 ns (12.1) |
| D3 | Decoded queue | new |
| R1 | RAT read, dependences inside the 4, new registers: all in registers at its end | 8.6 ns (11.7), 2 µops |
| R2 | Those registers, for S1; checkpoint, ROB entry | |
| DS | Wait bits into the row; with R2: the bank, the entry, sources compared with what is pending (`OOO_SDISP`); with R1: the queue, chosen again every cycle | |
| IS | **Wakeup and select, in 1 cycle** | 11.8 ns (12.8), 10 entries, 3 ports |
| RR1 | Payload, LVT | |
| RR2 | Register file data, bypass decided | Not measured at 10 ns (17 to 18): registers split it |
| EX | **Bypass, ALU, compare** | 10.6 ns without the fused compare (14.3 to 18.5 with it); 7.7 with ALU1's functions |
| E | Load or store: address | |
| M1 | D$ data, DTLB, SQ search | |
| M2 | **Tags, way, forward, align; result** | 12.6 ns (18.7), LSU with D$, as one stage |
| WB | Register file write | |

Bypass: operands kept in RR2's registers snoop the results, so EX's input mux has few sources (own, 3 ALUs, load). Built as `OOO_EXU`, each result in 3 registers for its sinks (`Plan/OOC.md` 28.6).

### 4.4 Half-rate islands: what is not rewritten

mmRISC-2's blocks close only at 50 MHz. Those that need no result every 10 ns run on a **50 MHz clock from the same
MMCM**, with registers at the boundary:

| Block | At 50 MHz | Effect |
|---|---|---|
| FPU_PIPE, FP registers | Yes | Latency in ns unchanged; twice the cycles. CoreMark has no FP |
| CORE_MDU (divide, `mulh`) | Yes | |
| CORE_CSR | Yes | Non-speculative at the ROB head already; a few cycles more |
| MMU's page-table walker, PMP | Yes | DTLB and ITLB hits stay at 100 MHz |
| L2, debug, CLINT, PLIC | Yes | Miss latency in ns unchanged |
| **L1 I$ and D$ hit paths** | **No: repipelined** | The miss paths may stay half-rate |

LiteX stays at its default 100 MHz, the **same clock as the CPU**, so there is no asynchronous crossing on the memory bus.

### 4.5 The six loops that decide it

| # | Loop | Target | If it fails | Model | Today at 10 ns (register to register) |
|---|---|---|---|---|---|
| 1 | **Wakeup + select** (IS) | 1 cycle, queue of 8 | ALU 2 cycles | **−20 %**: 5.51, a redesign | **+0.056 ns, the new design alone, without the payload, 5,353 LUTs** (`Plan/OOC.md` 28.5); **as built, 9.3 and 9.6 ns on 2 placements of one netlist; `loop` itself 8.7 and 9.1** (28.10); **with stores in 2 µops 9.06, `loop` 8.69** (28.15); with gaps in R2 9.95; **with steering chosen a cycle ahead 8.91, `loop` 8.64** (28.18). Today's block: −1.95 ns, 10 entries, 3 ports |
| 2 | **Bypass + ALU** (EX) | 1 cycle | ALU 2 cycles | **−20 %** | Today's: −0.66 ns full; +2.34 ns ALU1's functions. **The new design, with the register file: about 9.2 ns asked for 9, 12,472 LUTs, model 6.823** (`Plan/OOC.md` 28.9). Alone: the core will add |
| 3 | **M1 + M2** (load) | Load-use 3 | Load-use 4, 5 | −7.9 %, −15 % | Today's: −2.66 ns in one stage. **The new design, `OOO_LSU2`: about 8.1 ns asked for 9, 2,053 LUTs without the miss logic** (`Plan/OOC.md` 28.14). Alone |
| 4 | **Rename of 4** (R1, R2) | 2 stages | 3 stages | −0.4 % | Today's: +1.04 ns at 2 µops, in one stage. **The new design, `OOO_RENAME2`: about 9.1 ns asked for 9 with `disp_go` as measured, 8.1 from registers, 3,146 LUTs** (`Plan/OOC.md` 28.18). Alone |
| 5 | **Fetch buffer's boundaries** (D1) | 1 stage | 2 stages | about −1 % | −3.31 ns |
| 6 | **uBTB** (F0), added by the measurement | 96 entries, no bubble | A bubble on each taken branch; or fewer entries | **−6.8 %**; 8 entries −3.5 %, 4 entries −7.3 % | Today's: −2.04 ns at 8 entries. **The new design, 96 entries: about 8.9 ns asked for 9, 378 LUTs, model 6.889** (`Plan/OOC.md` 28.12). Alone: joining it to fetch is step 1.4 |

1 and 2 are life or death. They are measured first, and each has a design answer before giving up the cycle: dependency
matrices in place of tag compares in the queues, duplicated tags and registers for fan-out, shifts apart from the adder.

**Step 1.0's reading** (`Plan/OOC.md` 28.1): every block is much nearer 10 ns than its 20 ns result suggested, the full ALU
most of all (18.5 to 10.6 ns), but **none of this is the new design**: the slacks above are for today's blocks, routes are
62 to 83 % of the paths, and alone is not in the chip. The issue queue moved least (12.8 to 11.8 ns) and is worth most, so it
is measured first. Loop 6 is new: the uBTB misses by 2 ns at half the entries the proposal wants, and a bubble costs nearly
as much as a load-use of 4.

**The ladder if 100 MHz does not close**, none of it changes the pipeline:

| Whole core closes at | RTL 6.3 /MHz gives | Against the 50 MHz design (337) |
|---|---|---|
| 100 MHz | 631 CoreMark/s | 1.9 times |
| 90 MHz | 568 | 1.7 |
| 75 MHz | 473 | 1.4 |

The lower the clock, the less this deep pipeline pays against the 3-wide 50 MHz design, which has the higher CoreMark/MHz
and far less work, so the go / no-go is at gate S1-A.

---

## 5. Work order

### Step 1: the core and what belongs to it

| # | Work | Done when |
|---|---|---|
| 1.0 | **Done 2026-11-02**: `synth_ooo.bat t100`: today's blocks at a 10 ns target, on the XC7A200T (`Plan/OOC.md` 28.1) | The real distance from 10 ns |
| 1.1 | Harnesses of the new loops alone, in this order: a queue of 8 with its wakeups (`OOC_SCHED`, `synth_ooo.bat sched`, **about 8.9 ns asked for 8.5, 2026-11-04**), bypass + ALU with the new sources (`OOC_EXU`, `synth_ooo.bat exu`, **about 9.2 ns asked for 9, 2026-11-03**), a uBTB (`OOC_UBTB2`, `synth_ooo.bat ubtb`, **about 8.9 ns asked for 9, 2026-11-03**), M1 / M2 with block RAM (`OOC_LSU2`, `synth_ooo.bat lsu2`, **about 8.1 ns asked for 9, 2026-11-03**), rename of 4 (`OOC_RENAME2`, `synth_ooo.bat ren2`, **about 9.1 ns asked for 9, 2026-11-04**), the fetch buffer split | **Gate S1-A**: all six within reach at 10 ns; the configuration frozen; **go, or fall back to 75 MHz, or to 50 MHz and 3-wide** |
| 1.2 | The model with the queue, the D1 boundary, the split store as they will be built | Model ≥ 6.8 (6.71 as built: the author's to change, `Plan/OOC.md` 28.14, 28.17) |
| 1.3 | The new pipeline at W = 2 first: stages added, no new function, the tests' references updated | Lock-step; cycles against the model |
| 1.4 | Distributed schedulers; the decoded queue; 32-byte fetch, 6 decoded | Tests; cycles against the model |
| 1.5 | The width as a parameter, then W = 4; 3 ALUs; register file; ROB, LQ / SQ, checkpoints | Tests at both widths |
| 1.6 | Timing at every step at 10 ns: `OOO_CPU` out of context | Slack reported per loop |
| 1.7 | L1 hit paths at 100 MHz; half-rate islands; the real I$, L2; CoreMark on `OOO_CPU` | **Gate S1-B**: RTL `-O2` ≥ 6.3 with real caches, 100 MHz, tests and bug injection clean |
| 1.8 | Interrupts, MMU (Sv39), FPU, debug, PMU; arch tests for F / D / S; Linux on the simulator | **Gate S1-C**: Linux prompt in simulation |

### Step 2: the peripherals and the board

Starts when the board arrives, **in parallel with step 1**, from the most proven CPU to the newest: LiteX's stock SoC,
mmRISC-2, then mmRISC-3.

| # | Work | Done when |
|---|---|---|
| 2.0 | **LiteX's own target as it is** (`Doc/BOARD.md` 2): Rocket at 100 MHz, SD and Ethernet. The Vivado run needs no board | On the board: BIOS, memory test at DDR3-800, SD, TFTP; Linux on Rocket as a reference |
| 2.1 | `LitexSystem/` in this repository from mmRISC-2's, on LiteX's target; mmRISC-2 as the CPU at 50 MHz; constraints | LiteX BIOS prompt on the board |
| 2.2 | DDR3 within JEDEC (`Doc/BOARD.md` 4): LiteX at 100 MHz, mmRISC-2 at 50 MHz through crossings | Memory test of 512 MiB |
| 2.3 | microSD on J3; RGMII with the RTL8211E | BIOS boots from the SD card; TFTP and DHCP at 1 Gb/s |
| 2.4 | JTAG / cJTAG on JA, switches and LEDs (`Doc/BOARD.md` 7, 8) | `jtag_check.tcl` PASS in the 4 combinations |
| 2.5 | Bring-up record; DRAM latency measured, fed back to the simulation's memory model | |
| 2.6 | mmRISC-3 in place of mmRISC-2 (after S1-C), on LiteX's clock; whole-chip timing | **Gate S2**: BIOS on the board with mmRISC-3 |

### Step 3: Linux

| # | Work | Done when |
|---|---|---|
| 3.1 | OpenSBI, device tree (512 MiB, the new CSR map), kernel with LiteEth / LiteSDCard (first on mmRISC-2, after 2.4) | Boot to BusyBox from J3 |
| 3.2 | Ethernet under Linux (DHCP, ping, TFTP, NFS or ssh), MAC address | Traffic on the RTL8211E |
| 3.3 | Debian 13 on the second partition; gcc on the board | CoreMark built on the board |
| 3.4 | CoreMark under Linux; 120-minute stress test (memory, Ethernet, SD at once) | **Gate S3**: `-O2` above 6.0 at the clock reached, stress test PASS |

### Dependencies

- The board's order comes first (`Doc/BOARD.md` 10): step 1 does not need it, steps 2 and 3 do.
- **1.0 and 1.1 come before any rework**: they decide whether the rest of step 1 is worth starting.
- 2.5's DRAM latency reaches 1.7. 2.6 needs S1-C.

---

## 6. Verification

Unchanged in kind: lock-step with Spike at every instruction, riscv-arch-test, bug injection into every block and the
glue, cycle comparison with the model. New: each test at both widths while the width is a parameter; the half-rate
boundaries get their own directed tests; the board's checks in step 2 run on mmRISC-2 first.

---

## 7. Decisions

| # | Item | State |
|---|---|---|
| R1 | Width and clock | **Decided by the author: 4-issue, 100 MHz**, 2026-11-02. Confirmed by the author the same day: **4 renamed and 4 issued** |
| R2 | Where 6.0 is measured | Recommended: on the board under Linux, at the clock reached |
| R3 | Bring-up order | Recommended: stock LiteX, then mmRISC-2, then mmRISC-3 |
| R4 | DRAM clock | Recommended: LiteX at 100 MHz (DDR3-800), the same clock as the CPU (`Doc/BOARD.md` 4). MIG only as a fallback |
| R5 | Ethernet speed | **1 Gb/s only** with LiteEth's RGMII (`Doc/BOARD.md` 6); a gigabit switch port is needed |
| R6 | Fusion | Off |
| R7 | Second LSU port, fourth ALU | After S1-B, only if timing and the 75 % ceiling allow |
| R8 | LiteX | Its Nexys Video target as the base (`Doc/BOARD.md` 2) |
| R9 | Half-rate islands | Recommended (4.4), against rewriting mmRISC-2's blocks |
| R10 | Go / no-go | At S1-A, on measurements: the ladder of 4.5 |

---

## 8. Risks

| Risk | Effect | Counter |
|---|---|---|
| **Loops 1 or 2 do not make 10 ns** | −20 %, or a lower clock | Measured first (1.0, 1.1); the ladder |
| **The whole chip does not close at 100 MHz** though each block does | A lower clock | 73 % utilisation is high for the clock; floorplanning; the ladder, with no pipeline change |
| **The rework is close to a new core** | Much time: every stage, block and test changes; the findings of `Plan/CORE.md` 5 carry over, the RTL only partly | Staged (1.3 to 1.5), lock-step throughout; the 2-wide core stays in git as a working base |
| The RTL falls further behind the model | Margin lost: 6.0 needs × 0.89 of 6.71 | Cycle comparison by function; a second LSU port in reserve |
| Half-rate boundaries hide bugs | Failures under Linux | Directed tests; lock-step sees them |
| L1 repipelined: mmRISC-2's verified caches change | New bugs in the hit path | Their tests kept; bug injection |
| A longer build | Slower iteration | Out-of-context runs of the loops; Vivado runs under x86 emulation here |
| Board concerns | `Doc/BOARD.md` 10 | |

---

## References

- `Doc/BOARD.md`, `Doc/UARCH.md`; `Plan/model/results/g100.txt`, `g200t.txt`; `Plan/CORE.md` 5.19 to 5.22; `Plan/OOC.md` 27
- `Ref/` (not in the repository): the Nexys Video reference manual, schematic and constraints; DS180; UG586
