# mmRISC-3 Development Strategy (Nexys Video, XC7A200T, 4-wide, 50 MHz, CoreMark/MHz first)

[日本語](STRATEGY_J.md)

- Date: 2026-11-05 (the author's change of plan, `Doc/PROMPT.md` entries 163 and 164)
- Replaces: [`Plan/STRATEGY_100MHz.md`](../Plan/STRATEGY_100MHz.md), the plan for 100 MHz, and [`Plan/STRATEGY_A100T.md`](../Plan/STRATEGY_A100T.md), for the Arty A7-100T; both kept as history
- Board details: [`Doc/BOARD.md`](BOARD.md). Micro-architecture: [`Doc/UARCH.md`](UARCH.md)

---

## 0. Summary

1. **The goal: the highest CoreMark/MHz, the clock not insisted on.** 100 MHz is given up (the author, 2026-11-05). Then, as
   before, BusyBox and Debian 13 from the microSD slot J3, Ethernet (RTL8211E), JTAG / cJTAG on Pmod JA.
2. **The CPU at 50 MHz, LiteX at 100 MHz** (the author, 2026-11-05; section 4.4). 50 MHz is the highest clock that keeps what
   CoreMark/MHz depends on, load-use 2 and an ALU of 1 cycle, within what is known to close.
3. **The configuration**: 4 renamed, dispatched and committed a cycle, 6 decoded from a 32-byte fetch, **4 ALUs + 2 LSUs, 6
   issues**, ROB 48, LQ / SQ 16, 12 checkpoints, TAGE M, uBTB 96, in **today's pipeline depth**: **8.68 in the model, about 8.2
   in RTL (× 0.94), about 408 CoreMark/s**. Today's core measures 5.50 and 275.
4. **The half-rate islands go**: the whole CPU is on one clock, and the L1 hit paths stay as they are in mmRISC-2.
5. **Not measured yet**: this width at 20 ns, and the LUTs, estimated at about 109k, 81 %, at the ceiling. **Six loops are
   measured first** (section 4.5), as for 100 MHz; each has a fallback with its price.

---

## 1. Where the numbers come from

`Plan/model/g50.sh`, `results/g50.txt`, `g14 -O2`, the build the goal is measured on. "RTL" is the model × 0.94, what today's
RTL gives against it, **not checked for this width**. All rows have the same ports:

| CPU | Pipeline | Model /MHz | RTL /MHz | CoreMark/s | |
|---|---|---|---|---|---|
| 33.3 MHz | Load-use 1, block RAM on the falling edge | 9.66 | 9.1 | 302 | A new structure, not measured; Linux slower |
| 40 MHz | Decode and redirect a stage shorter | 8.72 | 8.2 | 328 | +0.5 %: nothing to gain below 50 MHz |
| **50 MHz** | **Today's depth: load-use 2, multiply 2** | **8.68** | **8.2** | **408** | **The choice** |
| 66.7 MHz | Load-use 2; fetch, decode, RR, multiply a stage more | 8.21 | 7.7 | 515 | −5.4 %; load-use 2 in 15 ns is not known. Later, if the margin is measured |
| 66.7 MHz | The same with load-use 3 | 7.27 | 6.8 | 456 | −16 % |
| 100 MHz | The 100 MHz pipeline | 7.00 | 6.6 | 658 | −19 %; given up (`OOO_CPU` at a 10 ns target: about 18.8 ns, `Plan/OOC.md` 28.26) |

Today's core: model 5.81, RTL 5.50 measured, 275 CoreMark/s. mmRISC-2 on the board: 2.794, 140.

What moves CoreMark/MHz from the chosen 8.677:

| Change | -O2 | | Change | -O2 | |
|---|---|---|---|---|---|
| ALU 2 cycles | 6.36 | −26.7 % | Stores split, a late data replays | 7.95 | −8.4 % |
| Load-use 3 | 7.58 | −12.7 % | Stores split, no replays: not to be had | 8.90 | +2.6 % |
| 4 decoded, 16-byte fetch | 7.92 | −8.7 % | The 100 MHz front end as built | 8.18 | −5.8 % |
| 1 LSU | 7.98 | −8.0 % | The override a stage later | 8.49 | −2.1 % |
| 3 ALUs | 8.37 | −3.5 % | One block a cycle in decode | 8.49 | −2.2 % |
| Distributed queues: 4 of 8, 1 of 12 | 8.47 | −2.4 % | Multiply 3 | 8.53 | −1.6 % |
| Unified 16, not 24 | 8.55 | −1.4 % | RR1: select to EX 3 cycles | 8.58 | −1.1 % |
| ROB 64, LQ / SQ 24, 16 checkpoints | 8.81 | +1.5 % | Decode a stage more | 8.63 | −0.5 % |
| 5 renamed | 8.79 | +1.3 % | Fusion 2 | 8.73 | +0.7 % |

---

## 2. The goal and how it is measured

| Item | Rule |
|---|---|
| Goal | `-O2`: **as high a CoreMark/MHz as can be had**. Working target at 50 MHz: **8.0 in RTL, 7.8 on the board** (proposed by Claude Code; the author set no number) |
| Where it counts | On the board, under Linux, with the bitstream that runs Linux |
| Compiler | GCC 14.2 (Debian 13); `-O2 -march=rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicond` |
| In simulation | `OOO_CPU` with the real caches and a latency model of the DDR3, in lock-step with Spike |
| Reported beside it | The clock reached and CoreMark/s |

---

## 3. Resources on the XC7A200T

| | XC7A100T (Arty A7-100T) | **XC7A200T (Nexys Video)** | Ratio |
|---|---|---|---|
| LUTs | 63,400 | **134,600** (33,650 slices) | 2.12 |
| Block RAM | 135 tiles | **365 tiles** | 2.70 |
| DSP | 240 | **740** | 3.08 |
| Speed grade | -1 | **-1 (the same)** | |
| DDR3 | 256 MiB, 16 bits | **512 MiB**, 16 bits, 800 MT/s | |

The whole chip (physical LUTs). **At 50 MHz the ceiling is taken as about 80 %, 107.7k**, what was usable at 50 MHz on the Arty.

| Part | LUT | Basis |
|---|---|---|
| LiteX SoC with Ethernet | 5.3k | mmRISC-2 4,826 (MII); RGMII estimated |
| Outside the core: L1 caches, L2, debug, MMIO, DMA, arbiter | 12.6k | mmRISC-2 measured |
| Core blocks kept: CSR, MMU, MDU, FPU, FP registers | 21.7k | mmRISC-2 measured |
| **The out-of-order engine** | **about 69k** (60k to 78k) | Below; today's measured 27.0k |
| **Total** | **about 109k, 81 %** | **At the ceiling**: measured at gate S1-A; the fallbacks of 4.5 give LUTs back |

The engine, estimated from `Doc/UARCH.md` 4.5 (nothing of it measured): front end with decode 14k, renaming and control 7k, a
queue of 24 with 6 selects and its payload 9k, ROB 8k, register file of 6 writes and 12 reads 8k, 4 ALU ports with RR, EX, bypass
and resolution 13k, 2 LSU ports 9k, multiplier and system unit 1k.

---

## 4. The micro-architecture for 50 MHz

### 4.1 What fits in a cycle

20 ns less clock-to-out, setup and uncertainty leaves about 19.3 ns. Today's 2-wide core closes there with little to spare:
**WNS +0.159 ns at a 20 ns target; about 18.8 ns at a 10 ns target**, limited by paths between blocks (`Plan/OOC.md` 28.26).
Vivado stops once a target is met, so the blocks' results at 20 ns are upper bounds: at a 10 ns target they reach 9 to 15 ns
(`Plan/OOC.md` 28.1).

### 4.2 The configuration

| Item | Today | **Proposal** | Why |
|---|---|---|---|
| Fetch | 16 B, 3 stages | **32 B, 3 stages** | With 6 decoded +9.5 % |
| Decode | 4 | **6** | Across fetch blocks: one block a cycle costs −2.2 % |
| Between decode and rename | group register | **decoded-instruction queue** | Takes 6, gives 4 |
| **Rename, dispatch, commit** | 2 | **4**, 2 checkpoints a cycle (`OOO_RENAME2`) | 2 a cycle cost nothing in the model |
| **Issue queue** | unified 10, 3 issues | **unified 24, 6 issues** | Distributed −2.4 %, the fallback (`OOO_SCHED`) |
| ALUs | 1 full, 1 limited | **4**: 3 of `OOO_ALUF` and 1 full | 3 ALUs −3.5 %. The slow operations on one port: not yet modelled here; at 100 MHz −0.1 % in CoreMark |
| LSU ports | 1 | **2** | 1 port −8.0 % |
| Branch | compare and act in EX + 1 | **The same** | |
| Load-use | 2 | **2** | 3 costs −12.7 %: **this is what sets the clock** |
| Multiply | 2 | **2, pipelined** (`OOO_PMUL`) | |
| Stores | one µop, with data | **The same** | Split with replays −8.4 %; the +2.6 % without them cannot be had (`Plan/OOC.md` 29) |
| ROB / LQ, SQ / checkpoints | 24 / 8 / 6 | **48 / 16 / 12**, registers **80** | |
| Register file | 3 writes, 6 reads | **6 writes, 12 reads** | The largest unknown in LUTs |
| Predictor | TAGE S, uBTB 8 | **TAGE M, uBTB 96** (`OOO_UBTB2`) | |
| Fusion | off | **off** | +0.7 %: a lever after S1-B |

### 4.3 The pipeline

The model: `fe_depth` 3, `dec_depth` 3, `iss_to_ex` 2, `redirect` 3, `override_at` 2, `lat_load` 2, `lat_mul` 2, as today's.
Times are today's blocks alone at a 10 ns target (at a 20 ns target).

| Stage | Work | Today, alone |
|---|---|---|
| F0 | Next pc: uBTB 96 | 8.9 ns (`OOO_UBTB2`) |
| F1 | I$, TAGE, BTB: block RAM | |
| F2 | Way select, predecode of 16 parcels, TAGE's decision, **override**; into the fetch buffer and FTQ | 14.3 ns (19.1), all of today's front end, 8 parcels |
| D1 | Fetch buffer: up to 6 instructions | 13.3 ns (16.9) |
| D2 | Decode; decoded queue | 9.0 ns (12.1) |
| R | RAT, dependences inside the 4, new registers, checkpoints | 8.6 ns (11.7), 2 µops; `OOO_RENAME2`, 4 µops, 2 stages of 9.1 ns |
| DS | Issue queue, ROB, LQ / SQ, payload | |
| IS | **Wakeup and select, in 1 cycle** | 11.8 ns (12.8), 10 entries, 3 ports |
| RR | Register file read | (17 to 18) |
| EX | **Bypass, ALU, compare; a load's or store's address and block RAM** | 10.6 ns without the fused compare (14.3 to 18.5 with it) |
| M | **Tags, way, forward, align; result** | 12.6 ns (18.7) |
| WB, CM | Register file write; commit 4 | |

### 4.4 The clock of each block

The DDR3 fixes LiteX's clock, not the CPU's: the CPU meets the rest of the chip only through a bus crossing.

| Block | Clock | Why |
|---|---|---|
| Board's oscillator, R4 | 100 MHz | MMCM input |
| **The whole core, L1** | **50 MHz** | Section 1 |
| FPU, MDU, CSR, PTW, PMP | **50 MHz** | The CPU's clock: no half-rate islands; they met 20 ns in `OOO_CPU` |
| L2, debug, CLINT, PLIC | **50 MHz** | `mtime` by a divider of 100, 500 kHz as before |
| **Bus crossings** | 50 / 100 MHz | `AXIClockDomainCrossing`, `AXILiteClockDomainCrossing`, as mmRISC-2 in the bring-up. The delay counts only on a miss; measured at 2.5 |
| **LiteX `sys`**: LiteDRAM, CSR, UART, SD logic, LiteEth's bus side | **100 MHz** | DDR3-800, LiteX's default here. JEDEC's lower limit of 303 MHz at 1:4 needs about 76 MHz or more, 800 MT/s at 1:4 allows 100 MHz at most |
| `sys4x`, `sys4x_dqs` | 400 MHz, 400 MHz at 90° | DDR3-800 |
| IDELAYCTRL | 200 MHz | DDR3 and RGMII's receive delay |
| RGMII | 125 MHz | `LiteEthPHYRGMII` is 1 Gb/s only, from the PHY's receive clock |
| microSD | 25 MHz, then up to 50 MHz | LiteSDCard's divider of `sys`; 3.3 V only |
| JTAG / cJTAG, Pmod JA | At most 10 MHz, asynchronous | JA's 200 Ω series resistors |

One MMCM, for example: VCO 800 MHz, 100 MHz (/8), 400 MHz (/2), 400 MHz at 90° (/2), 200 MHz (/4), 50 MHz (/16). Not yet in Vivado.

### 4.5 The six loops that decide it

| # | Loop | Target | If it fails | Model | Known so far |
|---|---|---|---|---|---|
| 1 | **Wakeup + select** | 1 cycle, unified 24, 6 selects | Distributed queues (`OOO_SCHED`) | −2.4 % | Today's 11.8 ns, 10 entries, 3 ports. `OOO_SCHED` 8.9 ns, 8 entries each. **Built: `OOO_IQ2`, model 8.63 with its limits (`Plan/OOC.md` 29.1); `synth_ooo.bat iq2` to run** |
| 2 | **Bypass + ALU + register file** | RR and EX, 6 results, 12 reads, 6 writes | 3 ALUs; the register file double-pumped on the 100 MHz clock | −3.5 % | `OOO_EXU` with `OOO_PRF2` 9.2 ns a stage, 12,472 LUTs, 3 ALUs, 4 writes, 8 reads |
| 3 | **Load** | Load-use 2, 2 ports | 1 LSU; load-use 3 | −8.0 %; −12.7 % | Today's 12.6 ns, 1 port |
| 4 | **Fetch** | 32 B, 3 stages, the override at F2 | A stage more, the override with it | −2.1 % | Today's 14.3 ns, 16 B. `OOC_FE2` 9.5 ns a stage, 5 stages |
| 5 | **Fetch buffer** | 6 a cycle, across blocks | One block a cycle (`OOO_FBUF2` as it is) | −2.2 % | `OOO_FBUF2` 8.65 ns, one block |
| 6 | **Rename of 4** | 1 stage | A stage more | −0.5 % | `OOO_RENAME2` 9.1 ns in 2 stages |

Between blocks, the 4 cuts proposed for 100 MHz (`Plan/OOC.md` 28.26) are not needed now, and are made only if the 20 ns run asks.

### 4.6 What was built for 100 MHz

| Block | At 50 MHz |
|---|---|
| RR1 in `OOO_CORE` | **Removed** (`Plan/OOC.md` 29): −1.1 % in the model, +2.20 % cycles measured |
| `OOO_UBTB2` | **Used as it is** |
| `OOO_RENAME2` | **Used**; its 2 stages joined if loop 6 allows |
| `OOO_FDEC` | **Used**, F3 and F4 joined in F2 |
| `OOO_FBUF2` | **The starting point**: a second block added for loop 5 |
| `OOO_ALUF` | **Used** on 3 ports |
| `OOO_ALUR` | Its functions in 1 cycle on port 0; not its stages |
| `OOO_SCHED`, `OOO_SDISP` | **The fallback** of loop 1 |
| `OOO_EXU`, `OOO_PRF2` | Not used as they are: they split RR in 2 stages. Today's `OOO_PRF` takes the ports as parameters |
| `OOO_LSU2`, `OOO_DCH`, `OOO_DTLB2` | Not used: load-use 3, stores in 2 µops. Today's `OOO_LSU` gets the second port |

All stay in the tree with their benches.

---

## 5. Work order

### Step 1: the core and what belongs to it

| # | Work | Done when |
|---|---|---|
| 1.0 | **Done 2026-11-05**: the configuration in the model (`Plan/model/g50.sh`); RR1 out of the core | 8.68; lock-step and CoreMark as before RR1 |
| 1.1 | Harnesses of the six loops at a 20 ns target, in the order of 4.5: unified 24 first (`OOC_IQ2`), then the register file with bypass and 4 ALUs, 2 load ports, fetch, fetch buffer, rename. `OOO_CPU` at 20 ns at each join | **Gate S1-A**: all within 20 ns, or a fallback taken with its price; the LUTs under 80 % by the sums; the configuration frozen |
| 1.2 | The width as a parameter of `OOO_CORE`, then W = 4: ROB, LQ / SQ, checkpoints, rename; tests at both widths | Lock-step; cycles against the model |
| 1.3 | Queue of 24, 6 issues; 4 ALUs; the register file | Tests; cycles against the model |
| 1.4 | The second LSU port | Tests; cycles against the model |
| 1.5 | 32-byte fetch, 6 decoded, the decoded queue, TAGE M, uBTB 96 | Tests; cycles against the model |
| 1.6 | Timing at every step at 20 ns: `OOO_CPU` out of context | Slack and LUTs reported |
| 1.7 | The real I$, L2; CoreMark on `OOO_CPU` | **Gate S1-B**: RTL `-O2` ≥ 8.0 with real caches, 50 MHz, tests and bug injection clean |
| 1.8 | Interrupts, MMU (Sv39), FPU, debug, PMU; arch tests for F / D / S; Linux on the simulator | **Gate S1-C**: Linux prompt in simulation |

### Step 2: the peripherals and the board

Starts when the board arrives, **in parallel with step 1**, from the most proven CPU to the newest: LiteX's stock SoC,
mmRISC-2, then mmRISC-3.

| # | Work | Done when |
|---|---|---|
| 2.0 | **LiteX's own target as it is** (`Doc/BOARD.md` 2): Rocket at 100 MHz, SD and Ethernet. The Vivado run needs no board | On the board: BIOS, memory test at DDR3-800, SD, TFTP; Linux on Rocket as a reference |
| 2.1 | `LitexSystem/` in this repository from mmRISC-2's, on LiteX's target; mmRISC-2 as the CPU at 50 MHz; constraints | LiteX BIOS prompt on the board |
| 2.2 | DDR3 within JEDEC (`Doc/BOARD.md` 4): LiteX at 100 MHz, the CPU at 50 MHz through crossings | Memory test of 512 MiB |
| 2.3 | microSD on J3; RGMII with the RTL8211E | BIOS boots from the SD card; TFTP and DHCP at 1 Gb/s |
| 2.4 | JTAG / cJTAG on JA, switches and LEDs (`Doc/BOARD.md` 7, 8) | `jtag_check.tcl` PASS in the 4 combinations |
| 2.5 | Bring-up record; DRAM latency measured through the crossing, fed back to the simulation's memory model | |
| 2.6 | mmRISC-3 in place of mmRISC-2 (after S1-C), the same 50 MHz and crossings; whole-chip timing | **Gate S2**: BIOS on the board with mmRISC-3 |

### Step 3: Linux

| # | Work | Done when |
|---|---|---|
| 3.1 | OpenSBI, device tree (512 MiB, the new CSR map), kernel with LiteEth / LiteSDCard (first on mmRISC-2, after 2.4) | Boot to BusyBox from J3 |
| 3.2 | Ethernet under Linux (DHCP, ping, TFTP, NFS or ssh), MAC address | Traffic on the RTL8211E |
| 3.3 | Debian 13 on the second partition; gcc on the board | CoreMark built on the board |
| 3.4 | CoreMark under Linux; 120-minute stress test (memory, Ethernet, SD at once) | **Gate S3**: `-O2` ≥ 7.8, stress test PASS |

### Dependencies

- The board's order comes first (`Doc/BOARD.md` 10): step 1 does not need it, steps 2 and 3 do.
- **1.1 comes before any rework**: it decides the ports.
- 2.5's DRAM latency reaches 1.7. 2.6 needs S1-C.

---

## 6. Verification

Unchanged in kind: lock-step with Spike at every instruction, riscv-arch-test, bug injection into every block and the
glue, cycle comparison with the model. New: each test at both widths while the width is a parameter; the board's checks in
step 2 run on mmRISC-2 first.

---

## 7. Decisions

| # | Item | State |
|---|---|---|
| R1 | Goal and clock | **Decided by the author, 2026-11-05: CoreMark/MHz first, the CPU at 50 MHz**; 100 MHz given up |
| R2 | Where CoreMark/MHz is measured | Recommended: on the board under Linux |
| R3 | Bring-up order | Recommended: stock LiteX, then mmRISC-2, then mmRISC-3 |
| R4 | DRAM clock | Recommended: LiteX at 100 MHz (DDR3-800), the CPU through crossings (`Doc/BOARD.md` 4). MIG only as a fallback |
| R5 | Ethernet speed | **1 Gb/s only** with LiteEth's RGMII (`Doc/BOARD.md` 6); a gigabit switch port is needed |
| R6 | Fusion | Off; +0.7 %, after S1-B if LUTs allow |
| R7 | ROB 64, 5 renamed | After S1-B, if LUTs allow: +1.5 %, +1.3 % |
| R8 | LiteX | Its Nexys Video target as the base (`Doc/BOARD.md` 2) |
| R9 | Load-use 1 at 33.3 MHz | Not taken: +11 % CoreMark/MHz, −26 % CoreMark/s, a new structure. Open if the author wants the last of CoreMark/MHz |
| R10 | 66.7 MHz | Not a goal: −5.4 % CoreMark/MHz, +26 % CoreMark/s. Looked at when 50 MHz is complete and its margin measured |
| R11 | Working targets of section 2 | Proposed; the author's to change |

---

## 8. Risks

| Risk | Effect | Counter |
|---|---|---|
| **The LUTs: about 109k against 107.7k**, nothing measured | Ports come down | Measured at S1-A; 3 ALUs, distributed queues, unified 16; the register file double-pumped |
| **The width does not close at 20 ns** though the depth is today's | A fallback of 4.5 | Measured first; today's core has little margin at 20 ns, but Vivado stops when met |
| **The rework is close to a new core** | Much time | Staged (1.2 to 1.5), lock-step throughout; the 2-wide core stays in git as a working base |
| The RTL falls further behind the model at this width | Margin lost: 8.0 needs × 0.92 of 8.68 | Cycle comparison by function |
| Load-use 2 with 2 ports, the D$ true dual port | Loop 3 | Measured at 1.1 |
| A longer build | Slower iteration | Out-of-context runs of the loops; Vivado runs under x86 emulation here |
| Board concerns | `Doc/BOARD.md` 10 | |

---

## References

- `Doc/BOARD.md`, `Doc/UARCH.md`; `Plan/model/results/g50.txt`, `g200t.txt`, `g100.txt`; `Plan/CORE.md` 5.19 to 5.22; `Plan/OOC.md` 28, 29; `Plan/STRATEGY_100MHz.md`
- `Ref/` (not in the repository): the Nexys Video reference manual, schematic and constraints; DS180; UG586
