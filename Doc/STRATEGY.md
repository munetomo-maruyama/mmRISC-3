# mmRISC-3 Development Strategy (Nexys Video, XC7A200T)

[日本語](STRATEGY_J.md)

- Date: 2026-11-02 (the author's change of plan, `Doc/PROMPT.md` entry 131)
- Replaces: [`Plan/STRATEGY_A100T.md`](../Plan/STRATEGY_A100T.md), the strategy for the Arty A7-100T, kept as history
- Board details: [`Doc/BOARD.md`](BOARD.md). Micro-architecture: [`Doc/UARCH.md`](UARCH.md)

---

## 0. Summary

1. **The FPGA grows.** The Arty A7-100T's XC7A100T is replaced by the **XC7A200T-1SBG484C on a Digilent Nexys Video**.
   The reductions made to fit the old device were costing the performance that out-of-order execution is there for.
2. **The goal**: `-O2` **comfortably above 6.0 CoreMark/MHz**, at 50 MHz, then BusyBox and Debian 13 from the microSD
   slot J3, with Ethernet (RTL8211E) and the JTAG / cJTAG port on Pmod JA.
3. **A 2-wide core cannot reach it with a margin**: with every lever pulled the model gives 6.07 (6.37 with fusion),
   and the RTL runs about 6 % below the model. **The proposal is a 3-wide core** (3 full ALUs + LSU, 4 issues, IQ 16,
   ROB 32, LQ / SQ 12, 8 checkpoints, TAGE M): **7.17 in the model, about 6.7 in RTL**.
4. **Logic is no longer the limit; 50 MHz is.** The chip is estimated at about 84k of 134,600 LUTs (62 %). The
   XC7A200T has the same speed grade as before, and the 2-wide core closes with only +0.159 ns.
5. **Three steps** (section 5): the core, the board, Linux. **The board's bring-up starts with mmRISC-2**, whose CPU
   is known to work, as soon as the board arrives, in parallel with the core.

---

## 1. Why the plan changed

CoreMark/MHz of the model from the core as it is (`Plan/model/g200t.sh`, `results/g200t.txt`; `g14 -O2`, the build
the goal is measured on):

| Configuration | Model, `-O2` | Expected RTL (× 0.94) |
|---|---|---|
| The core of 2026-11-02 (2-wide, ROB 24, IQ 10, LQ / SQ 8, limited ALU1) | 5.805 | 5.50 (measured) |
| 2-wide, ROB 48 / IQ 16 / LQ, SQ 12 / 8 checkpoints, one at a time | 5.81 to 5.85 | — |
| 2-wide, everything but fusion | 6.072 | 5.7 |
| 2-wide, everything + fusion 2 | 6.368 | 6.0 |
| **3-wide, otherwise the same sizes as today** | **6.693** | 6.3 |
| **3-wide, the proposal (section 4)** | **7.170** | **6.7** |
| The proposal + stores split into address and data | 7.324 | 6.9 |
| The proposal + stores split + 2 LSU ports | 7.504 | 7.1 |
| 4-wide, for scale | 8.413 | 7.9 |

- Sizes hardly matter at 2-wide: the width itself is what limits it. That is the finding the old budget hid.
- × 0.94 is what the RTL gives against the model today (5.50 / 5.805, 5.92 / 6.322, 5.32 / 5.668).
- What the G0b reductions were (L1 to L7 of `Doc/UARCH.md` 6.3) can now be taken back where they pay.

---

## 2. The goal and how it is measured

| Item | Rule |
|---|---|
| Goal | `-O2`: **above 6.0 CoreMark/MHz with a margin**. Working target: **6.5 in RTL**, **6.2 on the board** |
| Where it counts | On the board, under Linux, 50 MHz, with the bitstream that runs Linux (as `Plan/STRATEGY_A100T.md` 1.3) |
| Compiler | GCC 14.2 (Debian 13); `-O2 -march=rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicond` |
| In simulation | `OOO_CPU` with the real caches and a latency model of the DDR3, in lock-step with Spike |

mmRISC-2 lost about 2 % from simulation to the board (CPI 1.103 to 1.123). Hence 6.5 in RTL for 6.2 on the board.

---

## 3. Resources on the XC7A200T

| | XC7A100T (Arty A7-100T) | **XC7A200T (Nexys Video)** | Ratio |
|---|---|---|---|
| LUTs | 63,400 | **134,600** (33,650 slices) | 2.12 |
| Block RAM | 135 tiles (4,860 Kb) | **365 tiles** (13,140 Kb) | 2.70 |
| DSP | 240 | **740** | 3.08 |
| CMTs | 6 | 10 | |
| Speed grade | -1 | **-1 (the same)** | |
| DDR3 | 256 MiB, 16 bits | **512 MiB**, 16 bits, 800 MT/s on the board | |

The whole chip (Physical LUTs; the practical ceiling stays at 80 %, **107.7k**):

| Part | LUT | Basis |
|---|---|---|
| LiteX SoC with Ethernet | 5.3k | mmRISC-2 4,826 (MII); RGMII and the DRAM clock crossing estimated |
| Outside the core: L1 caches, L2, debug, MMIO, DMA, arbiter | 12.6k | mmRISC-2 measured |
| Core blocks kept: CSR, MMU, MDU, FPU, FP registers | 21.7k | mmRISC-2 measured |
| **The out-of-order engine, proposal** | **about 44k** (40k to 48k) | `Doc/UARCH.md` 4.5; today's 2-wide engine measured 27.0k |
| **Total** | **about 84k, 62 %** | leaves about 24k for what the model ranks next |

Consequences:

- `Plan/REDUCE.md`'s group A (triggers, PMP, D$ buffers, TLBs) is **no longer needed**: mmRISC-2's blocks stay at full
  size, and 4 HPM counters come back.
- Block RAM allows a larger TAGE and an L2 of 512 KB if measured to help Linux.
- **Timing is now the limit.** The XC7A200T is no faster, and 3-wide adds a fourth bypass source, a wider select and
  more register-file ports to a core with +0.159 ns. Area may be spent on timing (duplicated tags, registered
  decisions) as it could not before.

---

## 4. The proposed micro-architecture

To be frozen at gate S1-A (section 5), against a model that includes D1's group boundary.

| Item | Today (2026-11-02) | **Proposal** | Why |
|---|---|---|---|
| Fetch, decode | 16 B, 4 decoded a cycle | the same | 6 decoded and 32 B add little at 3-wide (3.7 %) |
| **Between decode and rename** | a group register refilled only when empty | **a decoded-instruction queue** | With 3-wide the old rule would give 3 + 1 µops per 2 cycles (`Plan/CORE.md` 5.19) |
| **Rename, dispatch, commit** | 2 | **3** | The largest single gain (+15 %) |
| **ALUs** | ALU0 full, ALU1 limited | **3 full ALUs**, branches on each | L7 gave back 1.6 % for LUTs that are now there |
| LSU | 1 port, 1 load or store | the same; 2 ports ranked next (+4 %) | |
| Issue | unified 10, 3 a cycle | **unified 16, 4 a cycle** | |
| ROB, registers | 24, 64 registers | **32**, 64 registers | 32 + 32 is enough |
| LQ / SQ, checkpoints | 8 / 8, 6 | **12 / 12, 8** | |
| Predictor | TAGE S, uBTB 8 | **TAGE M, uBTB 16** | Block RAM is there |
| Multiply | pipelined + CORE_MDU, write slot shared | the same, its own write slot | |
| Load-use | 2 cycles | **2 cycles (required)** | 3 costs 10 % (6.42) |
| Fusion | off (`FUSE_KINDS` 0) | **stays off**; to be removed or brought back after the width | With 3-wide its gain is small and its compare does not fit (`Plan/OOC.md` 27.5) |
| FPU, MMU, debug | not yet in the core | mmRISC-2's, at full size | Step 1 |
| Frequency | 50 MHz | 50 MHz | The author's decision |

### 4.1 Going to 4-wide?

(Asked by the author, 2026-11-02.) **Note the terms**: today's core renames 2 and issues 3 a cycle (2 ALUs + LSU). The
proposal **already issues 4** (3 ALUs + LSU) and renames 3. A core that issues 4 but dispatches 2 gives only 6.04: the
width of rename and dispatch is what matters. "4-wide" below means 4 renamed, dispatched and committed.

| Configuration | Model `-O2` | RTL (× 0.94) | Engine, estimated | Chip | Needs besides the width |
|---|---|---|---|---|---|
| **3-wide, the proposal** | **7.17** | **6.7** | 44k | 84k, 62 % | |
| 3-wide, 2 LSU ports | 7.46 | 7.0 | 50k | 92k, 68 % | D$ with 2 ports |
| 4-wide, 3 ALUs + LSU, the proposal's sizes | 7.22 | 6.8 | 48k | 88k, 65 % | Almost no gain |
| 4-wide, 4 ALUs + LSU, IQ 24, ROB 48 | 7.45 | 7.0 | 56k | 96k, 71 % | Fetch limits it |
| 4-wide, 3 ALUs + 2 LSU | 7.75 | 7.3 | 60k | 102k, 76 % | D$ with 2 ports |
| 4-wide, 4 ALUs + 2 LSU | 7.83 | 7.4 | 64k | 106k, 79 % | D$ with 2 ports |
| 4-wide, 4 ALUs + LSU, 6 decoded, 32-byte fetch | 7.97 | 7.5 | 65k | 105k, 78 % | I$ 32 bytes wide |
| **4-wide, 4 ALUs + 2 LSU, 6 decoded, 32-byte fetch** | **8.60** | **8.1** | **73k** | **115k, 85 %** | Both; **over the 80 %** |

(The 4-wide estimates are rougher than 3-wide's, from the same block by block scaling; the register file with 6
writes and 9 reads is measured, 5,299 LUTs, +1.769 ns.)

- **By area, yes**: 4-wide fits on the XC7A200T up to about 106k, the ceiling; the full version does not.
- **4-wide alone is worth little** (+0.7 % to +3.8 %): 16 bytes and 4 decoded a cycle, and one LSU port, become the limit.
  What makes it pay is the wider fetch and the second LSU port, each a project of its own (the I$, predecode, the fetch
  buffer; a D$ with two ports).
- **The real question is 50 MHz**, not area: rename's dependence check grows from 1 comparison to 6 in a cycle, the
  bypass from 3 sources to 6, select from 3 ports to 5 or 6. The 2-wide core has +0.159 ns. It has to be measured.
- **Recommendation**: 3-wide first, as it reaches the goal with a margin, but **the width is a parameter** (step 1.4), and
  the sizes too. After S1-B the order is by measured return: **2 LSU ports (+4 %) first, then W = 4**, and the 32-byte
  fetch, as long as 50 MHz holds. So choosing 3 now does not close 4.
- **A cheap measurement now**: `synth_ooo.bat OOO_IQ 20.0 1 N=24` shows the queue at 24 entries (with today's 3 ports).

### 4.2 A CPU clock of 100 MHz?

(Asked by the author, 2026-11-02.) **Not as the target: it conflicts with the goal.** A clock of 100 MHz needs a longer
pipeline, and that takes CoreMark/MHz below 6.0, though CoreMark per second rises. The pipelines are guesses from the
measured paths; the 3-wide proposal in each (`Plan/model/results/g200t.txt`):

| Clock | Pipeline | Model `-O2` /MHz | RTL (× 0.94) | CoreMark/s |
|---|---|---|---|---|
| **50 MHz** | The proposal | **7.17** | **6.7** | **337** |
| 66.7 MHz | Decode +1, redirect +1, load-use 3, mul 3 | 6.28 | 5.9 | 394 |
| 100 MHz, best case | Fetch, decode, RR +1, load-use 3, mul 4, 1-cycle ALU and wakeup held | 6.01 | 5.65 | 565 |
| 100 MHz, likely | + fetch +1, load-use 4 | 5.35 | 5.0 | 503 |
| 100 MHz, worst | + ALU 2 cycles | 4.33 | 4.1 | 407 |

Why the risk is large, from the measurements:

- **The period must halve.** The whole core has 19.8 ns today, 82 % of it routes. Alone, at a 20 ns target (so upper
  bounds): the full ALU 18.5 ns, the front end 19.1, the LSU with the D$ 18.7, the CSR unit 16.5, the register file 17 to
  18, the issue-queue loop 12.8 at 10 entries. Almost nothing large is under 10 ns, and 3-wide adds to all of them.
- **mmRISC-2's assets are 50 MHz designs.** Its CPU_CORE closes with +0.002 ns (`Plan/OOC.md` 25.3). The caches, MMU, FPU,
  CSR, L2 would need new pipelines and new verification: reuse is much of this project's plan.
- **The loop that decides IPC.** If bypass + add + wakeup-select does not fit in 10 ns the ALU takes 2 cycles: −23 % alone.
- **An outside reference**: NaxRiscv, built for Fmax, gives 5.02 CoreMark/MHz at 155 MHz on an Artix-7 of the fastest
  grade, RV32, about 13k LUTs. Ours is the slowest grade, RV64, about 3 times the size.

**Recommendation**: keep 50 MHz as the target. The CPU's clock is separate from LiteX's (`Doc/BOARD.md` 4), so
**raising it afterwards is only a change of the MMCM**: measure Fmax at each step, and after S3 take what closes without
changing the pipeline. Only if the goal became CoreMark per second instead of per MHz would a 100 MHz design be worth
its risk, and then it should be decided now, because it changes everything in step 1.

---

## 5. Work order

### Step 1: the core and what belongs to it

| # | Work | Done when |
|---|---|---|
| 1.1 | The model with D1's boundary and the queue; the RTL's other differences from the model (`Plan/CORE.md` 5.12) | **Gate S1-A**: the configuration frozen, model ≥ 7.0 with `-O2` |
| 1.2 | `synth_ooo.tcl` on the new part (done); `OOO_CPU` as it is on the XC7A200T, to see the build time and the timing on the larger device | A baseline to compare with |
| 1.3 | The decoded queue in place of D1b's refill rule; fusion's RTL decided | Unit tests; CoreMark at 2-wide not worse |
| 1.4 | The width as a parameter: rename, DS, ROB, IQ and payload, register file, control, commit, trace, lock-step, each block's test. First at W = 2 with no cycle changed, then W = 3 | All tests at both widths |
| 1.5 | 3 full ALUs, the bypass, the write ports; IQ 16, ROB 32, LQ / SQ 12, 8 checkpoints, TAGE M, uBTB 16, one at a time against the model | Each step's cycles against the model's |
| 1.6 | Timing at every step: `OOO_CPU` out of context | 50 MHz kept throughout |
| 1.7 | The real I$ (mmRISC-2's, 16 bytes wide) and L2; CoreMark on `OOO_CPU` | **Gate S1-B**: RTL `-O2` ≥ 6.5 with real caches, 50 MHz, tests and bug injection clean |
| 1.8 | Interrupts, MMU (Sv39), FPU, debug, PMU; arch tests for F / D / S; Linux on the simulator | **Gate S1-C**: Linux prompt in simulation |

### Step 2: the peripherals and the board

Starts when the board arrives, **in parallel with step 1**. It goes from the most proven CPU to the newest: LiteX's
stock SoC, then mmRISC-2, then mmRISC-3, so that a problem is the board's or the peripherals', not the new core's.

| # | Work | Done when |
|---|---|---|
| 2.0 | **LiteX's own target as it is** (`Doc/BOARD.md` 2): Rocket at 100 MHz, SD and Ethernet. The Vivado run needs no board: **it can be done before the board arrives** | On the board: BIOS, memory test at DDR3-800, SD, TFTP; Linux on Rocket as a reference, as `LitexRocket` on the Arty |
| 2.1 | `LitexSystem/` in this repository from mmRISC-2's, with the CPU wrapper on LiteX's target; mmRISC-2 as the CPU; constraints | LiteX BIOS prompt on the board |
| 2.2 | DDR3 within JEDEC (`Doc/BOARD.md` 4): LiteX at 100 MHz as it is, the CPU at 50 MHz through clock crossings | Memory test of 512 MiB |
| 2.3 | microSD on J3 (`SD_RESET`, timing constraints); RGMII with the RTL8211E | BIOS boots from the SD card; TFTP and DHCP at 1 Gb/s |
| 2.4 | JTAG / cJTAG on JA, switches and LEDs (`Doc/BOARD.md` 7, 8) | `jtag_check.tcl` PASS in the 4 combinations |
| 2.5 | Board bring-up record; DRAM latency measured, fed back to the simulation's memory model | |
| 2.6 | mmRISC-3 in place of mmRISC-2 (after S1-C); whole-chip timing at 50 MHz | **Gate S2**: BIOS on the board with mmRISC-3 |

### Step 3: Linux

| # | Work | Done when |
|---|---|---|
| 3.1 | OpenSBI, device tree (512 MiB, the new CSR map), kernel configuration with the LiteEth / LiteSDCard drivers | Boot to BusyBox from J3 |
| 3.2 | Ethernet under Linux (DHCP, ping, TFTP, NFS or ssh), MAC address (fixed, or from the EEPROM) | Traffic on the RTL8211E |
| 3.3 | Debian 13 on the second partition; gcc on the board | CoreMark built on the board |
| 3.4 | CoreMark under Linux; 120-minute stress test (memory, Ethernet, SD at once) | **Gate S3**: `-O2` above 6.0 with a margin, stress test PASS |

### Dependencies

- The board's order comes first (`Doc/BOARD.md` 10): nothing in step 1 needs it, but steps 2 and 3 do, and the lead
  time may be long.
- 2.5's DRAM latency reaches 1.7. 2.6 needs S1-C. 3.1 can start on mmRISC-2 after 2.4, so the kernel, the device tree
  and the SD card image are proved before the new core comes.

---

## 6. Verification

Unchanged in kind: lock-step with Spike at every instruction, riscv-arch-test, bug injection into every block and the
glue (`SIM/OOO_UNIT`, `SIM/CORE`), cycle comparison with the model. New: each test at both widths while the width is
a parameter; the board's own checks in step 2 run on mmRISC-2 first.

---

## 7. Decisions for the author

| # | Item | Recommendation |
|---|---|---|
| R1 | Width | **3-wide** (section 4); frozen at S1-A |
| R2 | Where 6.0 is measured | On the board under Linux, as before; the working targets of section 2 |
| R3 | Bring-up order | **The board first with mmRISC-2** (step 2 in parallel), not after the core |
| R4 | DRAM clock | **LiteX at its default 100 MHz (DDR3-800)**, the CPU alone at 50 MHz through LiteX's crossings (`Doc/BOARD.md` 4); MIG only as a fallback |
| R5 | Ethernet speed | **1 Gb/s only** with LiteEth's RGMII (`Doc/BOARD.md` 6); a gigabit switch port is needed |
| R6 | Fusion | Off; removed from the RTL if the width makes it pointless |
| R7 | 3 or 4 wide | **3 first, with the width as a parameter**; 2 LSU ports, then 4-wide, after S1-B by measurement (4.1) |
| R9 | CPU clock | **50 MHz as the target**, raised afterwards as far as it closes (4.2) |
| R8 | LiteX | **Use its Nexys Video target as the base**, with the stock SoC as the first check (`Doc/BOARD.md` 2) |

---

## 8. Risks

| Risk | Effect | Counter |
|---|---|---|
| 3-wide does not close at 50 MHz | Less width or a longer pipeline | Measured at each step of 1.5; area can buy timing now; the 2-wide core stays buildable (the width is a parameter) |
| The RTL falls further behind the model at 3-wide | Margin lost (6.5 needs × 0.91 of 7.17) | Cycle comparison by function, as `Plan/CORE.md` 5.12; stores split and 2 LSU ports in reserve (+2 % to +5 %) |
| The model's group of 4 hides another front-end limit | The estimate too high | 1.1 models it before the RTL |
| The rework of the width is large | Time; every block and test changes | First at W = 2 with no cycle changed, then W = 3 |
| A longer build | Slower iteration | Baseline in 1.2; out-of-context runs of the core; Vivado runs under x86 emulation on Windows here |
| Board concerns | `Doc/BOARD.md` 10 | |

---

## References

- `Doc/BOARD.md`, `Doc/UARCH.md`; `Plan/model/results/g200t.txt`; `Plan/CORE.md` 5.19 to 5.22; `Plan/OOC.md` 27
- `Ref/` (not in the repository): the Nexys Video reference manual, schematic and constraints; DS180; UG586
