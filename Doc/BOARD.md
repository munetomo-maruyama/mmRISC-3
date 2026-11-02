# The board: Digilent Nexys Video (XC7A200T-1SBG484C)

[日本語](BOARD_J.md)

- Date: 2026-11-02. Written from the documents in `Ref/` (kept locally, not in the repository) and the local checkout
  of LiteX; **no board has been tried yet**, so this is the plan for step 2 of `Doc/STRATEGY.md`
- What is reused: mmRISC-2's `LitexSystem` (`../mmRISC-2/LitexSystem`, read only), on LiteX's own Nexys Video target

---

## 1. What changes from the Arty A7-100T

| Item | Arty A7-100T | **Nexys Video** | What it means |
|---|---|---|---|
| FPGA | XC7A100T-1CSG324 | **XC7A200T-1SBG484** | `Doc/STRATEGY.md` 3 |
| Power | USB | **12 V, at least 3 A (barrel jack J21); not from USB** | Section 10 |
| DDR3 | 256 MiB, MT41K128M16 | **512 MiB**: one of 4 parts, Micron or Zentel, 16 bits, 800 MT/s | Section 4 |
| Ethernet | MII, 100 Mb/s, DP83848 | **RGMII, 1 Gb/s, RTL8211E-VL** | Section 6 |
| microSD | Pmod (PMOD MicroSD) | **Slot J3 on the underside**, shared with the board's microcontroller | Section 5 |
| JTAG / cJTAG | Pmod JA | **Pmod JA, same pinout** | Section 7 |
| Switches, LEDs | 4 switches, 4 LEDs + 4 RGB LEDs, 3.3 V | **8 switches at VADJ (1.2 V), 8 LEDs at 2.5 V** | Section 8 |
| USB | one, JTAG and UART | **two**: J12 (programming), J13 (UART) | Section 9 |
| Clock | 100 MHz | 100 MHz (R4) | The same |

---

## 2. What LiteX already has, and how it is used

**LiteX supports this board** (`litex_boards/targets/digilent_nexys_video.py`, in the checkout mmRISC-2 uses), so the
board's bring-up builds on it rather than on hand-written pins and clocks.

**Tried on 2026-11-02 (generation only, no Vivado, no board)**: the stock target with Rocket, 100 MHz, SD card and
Ethernet generates its Verilog, constraints and Vivado script. Its map is mmRISC-2's: ROM 0x1000_0000, SRAM
0x1100_0000, CSRs 0x1200_0000, Ethernet buffers 0x3000_0000, **main RAM 0x8000_0000, 512 MiB**.

| What LiteX gives | Use here |
|---|---|
| Target and platform: all pins, `S7MMCM` CRG, `IDELAYCTRL` | **The base of `LitexSystem/`**, with the changes below |
| `A7DDRPHY` + `MT41K256M16` at 100 MHz, 1:4 | **As it is: DDR3-800** (section 4) |
| `LiteEthPHYRGMII` + MAC | As it is (section 6) |
| LiteSDCard, `SD_RESET` included | As it is (section 5) |
| `get_port(clock_domain=...)`, `AXIClockDomainCrossing`, `AXILiteClockDomainCrossing` | **The CPU's clock crossing** (section 4) |
| Rocket, VexRiscv, NaxRiscv and others in the same workspace | **The first check of the board** (step 2.0), a reference for Linux |
| `spiflash4x` + LiteSPI | Booting from the flash, if wanted (step 3) |
| `i2c` | The MAC address from the EEPROM, if wanted |
| `xadc.py` | **The FPGA's temperature and voltages under Linux or the BIOS** (section 10, cooling) |
| `icap.py` | Reloading the FPGA from software, if wanted |
| `fan` + `pwm.py` | A fan, if one is fitted |
| `video.py` (HDMI terminal), `usb_ohci.py`, `dna.py`, `oled` pins | Not needed; available |

**Written by hand here**: the CPU's wrapper (`cpu/mmrisc/core.py`, already generic about `pmoda` and `user_sw`), the
crossings, the status LEDs, the device tree, the timing constraints.

**What not to take from LiteX as it is** (found by reading and by the trial):

| Point | Fix |
|---|---|
| Switches and buttons are `LVCMOS25` in the platform, while VADJ is 1.2 V unless the design changes it | `LVCMOS12`, as Digilent's XDC (section 8) |
| The target's `vadj` assignment is never connected | Leave `SET_VADJ` alone |
| `user_btn` 5 is the same pin as `cpu_reset_n` (G4) | Do not request both |
| `--eth-dynamic-ip` fails with the target's default `eth_ip` ("local_ip cannot be used with dynamic_ip"), and the target has no `--eth-dhcp` | In our target, as on the Arty's `--eth-dhcp` |
| `LedChaser` takes all 8 LEDs | LD4 to LD7 only (section 8) |
| The SD pins have no timing constraint | mmRISC-2's constraints (section 5) |

---

## 3. Clocks

| Clock | Frequency | Use |
|---|---|---|
| Board's oscillator, pin R4 (MRCC, bank 34) | 100 MHz | MMCM input |
| **CPU, L1 hit paths** | **100 MHz, the same clock as `sys`** (mmRISC-2 in the bring-up: 50 MHz) | The author's decision, 2026-11-02 |
| CPU's half-rate islands | 50 MHz, from the same MMCM | `Doc/STRATEGY.md` 4.4 |
| **LiteX `sys`**: LiteDRAM, CSR, UART, SD, LiteEth's bus side | **100 MHz, its default on this board** | Section 4 |
| `sys4x`, `sys4x_dqs` | 400 MHz, 400 MHz at 90° | DDR3-800 |
| IDELAYCTRL | 200 MHz | DDR3 and RGMII's receive delay |
| RGMII transmit | 125 MHz with a 2 ns phase | A PLL fed by the PHY's receive clock (section 6) |

---

## 4. DDR3

**This is the one correction the new board forces.** On the Arty, LiteDRAM runs on the system clock at 4:1, so 50 MHz
means **200 MHz, DDR3-400, below JEDEC's minimum of 303 MHz** (`LitexSystem/docs/TIMING.md`). It worked on the one
Arty's Micron part. The Nexys Video may carry any of **MT41K256M16HA-187E, MT41K256M16TW-107, Zentel
A3T4GF40ABF-GML, Zentel A3T4GF40BBF-HP**, and the same trick cannot be promised on all of them, or on the next board
bought.

| Option | What | For | Against |
|---|---|---|---|
| **A (recommended; revised 2026-11-02)** | **All of LiteX at 100 MHz, its default here.** mmRISC-3 runs on that same clock, with no crossing on the memory bus. mmRISC-2, in the bring-up, runs at 50 MHz with crossings in its wrapper: the memory bus through `AXIClockDomainCrossing` (or `get_port(clock_domain=...)`), the peripheral and DMA buses through `AXILiteClockDomainCrossing` | LiteX's target as it is, which is what is used and tested on this board; within JEDEC on all parts; twice the bandwidth; SD can go faster; all new logic in one file | Peripherals at 100 MHz; CSR accesses take the crossing (rarely matters); the DRAM's latency has crossing cycles to be measured |
| B | LiteDRAM alone at 100 MHz, its domain split from `sys`; the peripherals at 50 MHz with the CPU | Peripherals' timing as on the Arty | Renames domains inside LiteX's SoC, against its grain |
| C | MIG (UG586) in place of LiteDRAM, its AXI at 100 MHz | Xilinx's supported flow | More logic, an IP flow, a new BIOS init; no gain over A. **Fallback only** |
| D | DDR3-400 as on the Arty | No work | Outside the JEDEC range; a trial at most |

Other points: 512 MiB at 0x8000_0000 to 0x9FFF_FFFF is free in mmRISC-2's map (`MEMMAP.md` section 3); bank 35 at
1.5 V; the CPU_L2 and the device tree need the new size. `mtime` counts inside the CPU from its clock: its divider changes with the clock so that
`timebase-frequency` stays 500 kHz. The BIOS's and drivers' clock constants become those of `sys`, 100 MHz.

---

## 5. microSD on J3

| Item | Fact | What to do |
|---|---|---|
| Sharing | The on-board PIC24 reads the card until the FPGA is configured, then **powers the slot off** and leaves the bus | The design must power it |
| `SD_RESET` (V20) | **Must be driven low by the FPGA** to power the slot | LiteSDCard does: the PHY drives `pads.rst` (`card_reset`), and its init handles it |
| Bus | Native 4-bit, CMD, CCLK, CD (T18), bank 14, 3.3 V | `--with-sdcard` pins exist. 3.3 V only: no UHS |
| Clock | With `sys` at 100 MHz, up to 50 MHz by LiteSDCard's divider (3.3 V high speed) | Start at 25 MHz as on the Arty, then measure |
| Timing | mmRISC-2 found the SD pins had no timing constraint and moved from build to build (`scripts/build_soc.sh`) | Carry the constraints over, on the new pins |
| Position | **On the underside of the board** | Section 10 |
| Bitstream from the card | JP4 = USB/SD, JP3 = SD: the PIC24 loads the one `.bit` in the root of a **FAT32** card | Optional. mmRISC-2's boot partition is FAT16 (`LITEXBOOT`); boot from QSPI or JTAG first, decide later |

---

## 6. Ethernet: RTL8211E-VL over RGMII

| Item | Fact | What to do |
|---|---|---|
| Pins | Bank 13 at **2.5 V**; `ETH_RST_B` alone on bank 34 at 3.3 V (U7) | As LiteX's platform |
| Delay | The PHY adds none by default (`RXDLY`, `TXDLY` by resistors); data to clock needs 1.0 to 2.6 ns at the receiver | **In the FPGA, as LiteEth does**: `IDELAYE2` on receive; on transmit a PLL's 2 ns phase. **No board change** |
| Speed | **LiteEth's `LiteEthPHYRGMII` is 1 Gb/s only**: its transmit PLL takes the PHY's receive clock as 125 MHz. On a 100 Mb/s link RXC is 25 MHz and the PLL is out of range | Section 10. The PHY's default advertises 10 / 100 / 1000, so **the other end has to be 1000BASE-T** |
| MAC address | A 24AA025E48 on I2C (W5, V5) holds a unique one | Fixed address first, as mmRISC-2; the EEPROM later if wanted |
| Xilinx's TEMAC | Needs a licence | Not used |
| Linux | The same `liteeth` driver as on the Arty; the PHY is not managed by it, the link comes up on its own | Check in 3.2 |
| Bandwidth | The bus side at 100 MHz, 32 bits: 400 MB/s against 125 MB/s of the wire | Enough; what Linux reaches is the CPU's copy, measured in 3.2 |

---

## 7. JTAG / cJTAG on Pmod JA

**The same connector positions as the Arty**, so the cable and the OpenOCD configurations do not change;
`cpu/mmrisc/core.py` asks for `pmoda:0` to `pmoda:5`, which LiteX's platform already maps.

| Pmod JA | FPGA pin | Signal | FPGA side | Note on this board |
|---|---|---|---|---|
| JA1 | AB22 | TCK / TCKC | Pull-up. A clock on a general-purpose pin | No clock-capable pin on JA, as on the Arty: `CLOCK_DEDICATED_ROUTE FALSE` |
| JA2 | AB21 | TDI | Pull-up | |
| JA3 | AB20 | TDO | Pull-up. Driven only while shifting | `DOUT / CSO_B` in configuration: an output, which suits TDO |
| JA4 | AB18 | TMS / TMSC | Keeper | Bidirectional through the series resistor |
| JA7 | Y21 | nTRST | Pull-up | |
| JA8 | AA21 | nSRST | Pull-up. Reset of the CPU | |
| JA5 / JA11 | — | GND | | |

JA is routed single-ended with **200 Ω series resistors, for below 10 MHz** (`Table 9`): TCK is constrained at 100 ns,
10 MHz, as before. JB and JC have 0 Ω and differential routing and are not needed. J17 on this board is the FPGA's
own JTAG (for an external programmer), not the CPU's.

---

## 8. Switches, LEDs, buttons

Following mmRISC-2's use (`LitexSystem/docs/JTAG.md` section 1). **I/O standards from Digilent's master XDC**: switches
and buttons `LVCMOS12` (VADJ 1.2 V by the board's pull resistors, as long as `SET_VADJ` and `VADJ_EN` are left alone),
LEDs `LVCMOS25`, CPU RESET `LVCMOS15`.

| On the board | Pin | Use | On the Arty |
|---|---|---|---|
| SW3 | G22 | Down: 4-wire JTAG. Up: 2-wire cJTAG | The same |
| SW2 | G21 | Down: no authentication. Up: authentication | The same |
| SW0, SW1, SW4 to SW7 | E22, F21, H17, J16, K13, M17 | Free (LiteX's `user_sw` as CSRs if asked) | |
| LD0 | T14 | Hart halted | RGB LD0 red |
| LD1 | T15 | Hart running | RGB LD0 green |
| LD2 | T16 | dmactive | RGB LD1 blue |
| LD3 | U16 | cJTAG online (SW3 up) | RGB LD2 green |
| LD4 to LD7 | V15, W16, W15, Y13 | LiteX's LED chaser | The same |
| CPU RESET (red) | G4 | System reset, active low | Reset button |
| BTNC / U / D / L / R | B22, F15, D22, C22, D14 | Free | |

The Arty's RGB LEDs were too bright and ran at 1/16 duty; these have 100 Ω and need nothing. The OLED is left unused.

---

## 9. UART, programming, flash

| Item | Fact |
|---|---|
| UART | FT232R on J13; pins V18 (from the PC) and AA19 (to the PC), 3.3 V, no handshake |
| Programming | Digilent USB-JTAG on J12, the same cable style as the Arty; about 4 s for an uncompressed bitstream at 30 MHz |
| Bitstream | 77,845,216 bits uncompressed; compression helps |
| Flash | S25FL256S, 32 MiB; the bitstream takes just over 9 MiB. In the tools (the manual): `s25fl256xxxxxx0` |
| Mode | JP4 selects JTAG, QSPI or USB/SD |

---

## 10. Concerns, before ordering first

| # | Concern | Severity | What to do |
|---|---|---|---|
| 1 | **Lead time.** One distributor shows 11 weeks, another a 70-week factory lead time, others stock | **Check before anything else** | Ask Japanese distributors for stock. The core work does not wait for it; steps 2 and 3 do |
| 2 | **Power supply.** 12 V, at least 3 A; not USB. Distributors list a 12 V 3 A supply with US and EU plugs | Check | Confirm it is in the box from the seller you choose, and that it is rated for 100 V |
| 3 | **Ethernet needs a 1000BASE-T port** at the other end (section 6). The current setup should be checked: the path to the Mac and the TFTP server | Check | A small gigabit switch solves it. 10 / 100 would need a new PHY layer in LiteEth |
| 4 | **DDR3 parts vary** (section 4); DDR3-400 is not safe | Design | Option A; test on your board's part, and read which part it is |
| 5 | **The microSD slot is underneath** the board | Practical | Cards are changed with the board lifted, and with stand-offs that leave room. Frequent SD swaps were part of the Arty's routine: TFTP from the BIOS reduces them |
| 6 | **Cooling.** I could not confirm a heat sink from the documents; there are solder points for a fan | Check | Ask or look on arrival; the XADC reads the temperature; `report_power` on the first full build |
| 7 | **Free Vivado.** The XC7A200T is in Vivado ML Standard (UG973) | Fine | No licence to buy; 2025.1 is what is in use |
| 8 | **Build time and memory** on Windows under x86 emulation; a larger device and design | Practical | `synth_ooo.bat OOO_CPU` is on the new part now: it can be tried **before the board arrives**. Look at the peak memory too |
| 9 | **VADJ** (section 8): LiteX's `LVCMOS25` on switches would read a 1.2 V high as low | Design | `LVCMOS12`, `SET_VADJ` untouched |
| 10 | **The pmod for the debug probe** keeps its pinout; 200 Ω as before; the probe's 3.3 V | Fine | Nothing to buy |
| 11 | **The PMOD MicroSD and Ethernet of the Arty do not carry over** | Fine | J3 and the RJ-45 replace them; a shielded cable is asked for by the manual |
| 12 | **Speed grade.** -1 as before: twice the logic, not faster logic; **the goal of 100 MHz makes this the main risk** | Known | `Doc/STRATEGY.md` 4.5, 8 |
| 13 | **Power and heat at 100 MHz** with about 98k LUTs: more than the 50 MHz plan. 36 W of supply is ample for the estimate, the 1.0 V rail 4 A max | Check | `report_power` on the first full build; fan or heat sink decided from it |

Sources for 1, 2 and 7 are distributor pages and AMD's UG973, checked 2026-11-02; prices and stock change.
