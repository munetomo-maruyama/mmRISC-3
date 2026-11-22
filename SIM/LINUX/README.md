# SIM/LINUX: Linux on the bench (step 1.8 L1)

[日本語](README_J.md)

Linux boots on `OOO_CPU` in SIM/CORE's `tb_core`, in lock-step with Spike at every instruction, to the shell's
prompt; a few commands run there, then the board is powered off (`Plan/OOC.md` 29.99).

## The image

`./build.sh` makes `work/linux.elf`, one ELF that the bench and Spike load as they load a test:

| Address | What | From |
|---|---|---|
| 0x8000_0000 | OpenSBI `fw_jump` (generic), with `bench.dts` built in | mmRISC-2's OpenSBI (3593a5f) and its patches (`LitexSystem/software/boot/opensbi_patches`), linked here (`FW_PIC=n`) |
| 0x8020_0000 | the kernel | mmRISC-2's (litex-hub/linux 7.2.0-rc2, `LitexSystem/software/boot/linux.config`: the one that runs on its board) with the SBI console added (`HVC_RISCV_SBI`, `SERIAL_EARLYCON_RISCV_SBI`), built out of the tree in `$KBUILD` |
| 0x8200_0000 | the initramfs | mmRISC-2's BusyBox (`~/mmlitex_build/initrd_bb`, as its SIM_BIOS ran) with `overlay/` appended as a second archive |
| 0x8240_0000 | the device tree for Linux | OpenSBI copies its built-in tree there |

`tohost` / `fromhost` are OpenSBI's own, written into the ELF's symbols: the bench and the reference find HTIF by
them. The console is HTIF: OpenSBI prints through it, and Linux through OpenSBI's debug console (`earlycon=sbi`,
`console=hvc0`). The bench has no LiteX device.

`bench.dts` is mmRISC-2's device tree with the CPU node unchanged (mmRISC-3 keeps its instruction set and its
CORE_CSR), the timebase at 50 MHz (the bench's `OOO_CPU` steps mtime every cycle: `CLINT_TICK_DIV` 1; 500 kHz on the board), 64 MB of memory (the
bench's), the CLINT and the PLIC, an HTIF node, and the PMU node with step 1.8 K1's events.

`overlay/inittab` runs `overlay/l1.sh` on the console in place of the shell: an interactive `ash` shows its prompt
and runs `uname -a`, `cat /proc/cpuinfo`, `ls /`, `free`, then `poweroff -f`. OpenSBI's system reset is HTIF's
exit, so the run ends as a test does, and the reference's exit code and console are compared.

## Running it

```bash
./build.sh
../CORE/obj/cpu/VOOO_CPU +verilator+rand+reset+2 -console -progress 10000000 -hang 2000000 -max 4000000000 work/linux.elf
```

`-console` prints HTIF's characters as they come, `-progress` the run's line every 10M cycles, and `-hang` lets the
core wait in WFI between Linux's ticks (HZ 100: 500k cycles). On Spike alone (the same image: OpenSBI takes its
built-in tree, not Spike's):

```bash
spike -p1 -m0x80000000:0x4000000 --pmpregions=8 --isa=rv64imafdc_zicboz_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zba_zbb_zbc_zbs_smcntrpmf_sscofpmf_sstc work/linux.elf
```

## OpenSBI's PMU (pmu_sbi)

`PAYLOAD=pmu_sbi ./build.sh` makes `work/pmu_sbi.elf`: `pmu_sbi/` (mmRISC-2's S-mode program, for mmRISC-3's two
counters) in place of the kernel. It makes the SBI PMU extension's calls as Linux's perf does and checks what comes
back: the counters OpenSBI reports, the counters events are given (cycles and instructions on the fixed ones with
Smcntrpmf, two programmable, a third finding none), that they count, a raw event with Linux's mask, a counter freed
by a stop with RESET (mmRISC-2's OpenSBI patch), UINH, and the overflow interrupt in S mode. A PASS ends with the SBI
system reset (HTIF's exit 0); a FAIL spins until `-max`:

```bash
PAYLOAD=pmu_sbi ./build.sh
../CORE/obj/cpu/VOOO_CPU +verilator+rand+reset+2 -console -max 60000000 work/pmu_sbi.elf
```

On Spike alone it fails: Spike's HPM counters count nothing, so OpenSBI finds none.

## Sources

Outside this repository, as Plan/csize's: `MMRISC2` (mmRISC-2's repository, by default next to this one),
`INITRD` (the BusyBox initramfs), `KBUILD` (the kernel's build directory, about 300 MB: `~/mmrisc3_linux/kbuild`).
