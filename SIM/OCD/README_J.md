# SIM/OCD: OOO_CPUをOpenOCDで(手順1.8 J1)

[English](README.md)

OpenOCD(riscv-openocd)が`OOO_CPU`をそのデバッグロジック(`RTL/CPU/DBG`の`DBG_TOP`)を通してデバッグする。どちらも
VerilatorでのRTL。mmRISC-2の`SIM/SIM_OCD`がそのコアにしたのと同じ(`Plan/OOC_J.md` 29.102)。

```
OpenOCD --remote_bitbang (TCP)-- jtag_rbb.cpp (DPI-C) -- tb_OCD.sv:
    DBG_TOP (JTAG、DTM、DM) -- OOO_CPUのhart_*、reg_*、bm_*
    OOO_CPUのメモリバス  -> AXI4_RAM 0x8000_0000(512 KB)
    OOO_CPUの周辺バス(CPU_MMIOのCLINTとPLICの先) -> AXIL_RAM 0x1200_0000(4 KB)
```

remote_bitbangのコマンドは7 nsごとに反映され、50 MHzのシステムクロックはそれとは別に走る(`--timing`)ので、DTMの
クロック乗り換えが本物のデバッガに出会う。リセット(パワーオン、OpenOCDのSRST、ndmreset、hartreset)の後、ハートは
0x8000_0000から始まり(`OOO_CPU`のboot)、それまでDMはハートを使えないと見せる。

```bash
./run_ocd.sh
```

`tb_OCD`をビルドし(`obj/`)、OpenOCDと`test_ocd.tcl`で実行し、認証を有効にしてもう一度(鍵0xbeefcafe、
`riscv authdata_write`)。両方通ればPASS。`test_ocd.tcl`はmmRISC-2のもの(50項目): 停止、GPR、FPR、CSR(misa、mhartid、dpc、
dcsr)、両方のバスで全サイズのメモリ、256語のブロック、`load_image` / `verify_image`、ステップ、ソフトウェアブレーク
ポイント(D$経由で書いたEBREAK、再開の`fence.i`の後にフェッチされる)、ハードウェアブレークポイント(実行トリガ、
dcsr.cause 2)、ストアとロードのウォッチポイント(ハートが止まったときアクセスはされていない。ストアのラインはD$で
ダーティなまま読む)、自由実行と停止、`reset halt`(最初の命令の前)。

`./run_ocd.sh top`(手順2.6)は、同じことを`RTL/CPU/TOP`の`CPU_TOP`経由で行う。`CPU_TOP`は`tb_OCD`と同じように`DBG_TOP`と
`OOO_CPU`をつなぎ、ハートを自分で起動し、DMのメモリアクセスをDMAポート(ここでは使わない)との調停に通す: **認証あり/
なしとも50項目中50**(2026-11-28)。

mmRISC-2のものからの変更: misa(0x800000000014112f)、IDCODE(0x36d6d001)、FPRの読み返し、そしてリセット: ライトバックの
キャッシュはメモリがまだ持っていないものを失う(`RTL/CPU/DBG/README_J.md`)ので、メモリは`reset halt`をまたいで
保つ代わりに、その後で書いて読む。`Unable to insert program into progbuf`の行は、コアにないCSR(vlenb、mtopi)を
これもコアにないプログラムバッファで探ろうとするOpenOCDのもの: mmRISC-2と同じく害はない。

ファイル: `tb_OCD.sv`、`openocd_sim.cfg`、`test_ocd.tcl`、`run_ocd.sh`。`jtag_rbb.cpp`、`AXI4_RAM.sv`、`AXIL_RAM.sv`は
mmRISC-2のものを変えずに(各ヘッダの1行がそう書く)。
