# SIM/LINUX: ベンチでLinux(手順1.8 L1)

[English](README.md)

SIM/COREの`tb_core`の`OOO_CPU`で、Spikeと1命令ごとのロックステップでLinuxをシェルのプロンプトまで起動する。そこで
いくつかのコマンドを実行し、電源を切る(`Plan/OOC_J.md` 29.99)。

## イメージ

`./build.sh`が`work/linux.elf`を作る。ベンチとSpikeがテストと同じように読み込む1つのELF:

| アドレス | 中身 | 出所 |
|---|---|---|
| 0x8000_0000 | OpenSBIの`fw_jump`(generic)、`bench.dts`を内蔵 | mmRISC-2のOpenSBI(3593a5f)とそのパッチ(`LitexSystem/software/boot/opensbi_patches`)、ここでリンク(`FW_PIC=n`) |
| 0x8020_0000 | カーネル | mmRISC-2のもの(litex-hub/linux 7.2.0-rc2、`LitexSystem/software/boot/linux.config`: そのボードで動くもの)にSBIコンソールを足したもの(`HVC_RISCV_SBI`、`SERIAL_EARLYCON_RISCV_SBI`)、`$KBUILD`にツリー外でビルド |
| 0x8200_0000 | initramfs | mmRISC-2のBusyBox(`~/mmlitex_build/initrd_bb`、そのSIM_BIOSが使ったもの)の後ろに`overlay/`を2つ目のアーカイブとして |
| 0x8240_0000 | Linuxへのデバイスツリー | OpenSBIが内蔵のツリーをそこへコピーする |

`tohost` / `fromhost`はOpenSBI自身のもので、ELFのシンボルに書き込む: ベンチと参照はそれでHTIFを見つける。
コンソールはHTIF: OpenSBIはそれで出力し、LinuxはOpenSBIのデバッグコンソール経由(`earlycon=sbi`、`console=hvc0`)。
ベンチにLiteXのデバイスはない。

`bench.dts`はmmRISC-2のデバイスツリーで、CPUのノードはそのまま(mmRISC-3は命令セットとCORE_CSRを保つ)、タイムベースは
50 MHz(ベンチの`OOO_CPU`はmtimeを毎サイクル1歩: `CLINT_TICK_DIV` 1。ボードでは500 kHz)、メモリ64 MB(ベンチのもの)、CLINTとPLIC、HTIFのノード、
手順1.8 K1のイベントのPMUのノード。

`overlay/inittab`はコンソールでシェルの代わりに`overlay/l1.sh`を実行する: 対話の`ash`がプロンプトを出して`uname -a`、
`cat /proc/cpuinfo`、`ls /`、`free`を実行し、そのあと`poweroff -f`。OpenSBIのシステムリセットはHTIFの終了なので、
実行はテストと同じように終わり、参照の終了コードとコンソールが比べられる。

## 実行

```bash
./build.sh
../CORE/obj/cpu/VOOO_CPU +verilator+rand+reset+2 -console -progress 10000000 -hang 2000000 -max 4000000000 work/linux.elf
```

`-console`はHTIFの文字を来るたびに出し、`-progress`は1千万サイクルごとに実行の行を出す。`-hang`はLinuxのティックの間
(HZ 100: 50万サイクル)コアがWFIで待つのを許す。Spikeだけで(同じイメージ: OpenSBIはSpikeのものでなく内蔵のツリーを使う):

```bash
spike -p1 -m0x80000000:0x4000000 --pmpregions=8 --isa=rv64imafdc_zicboz_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zba_zbb_zbc_zbs_smcntrpmf_sscofpmf_sstc work/linux.elf
```

## OpenSBIのPMU(pmu_sbi)

`PAYLOAD=pmu_sbi ./build.sh`は`work/pmu_sbi.elf`を作る: カーネルの代わりに`pmu_sbi/`(mmRISC-2のSモードのプログラムを
mmRISC-3の2つのカウンタ向けにしたもの)。LinuxのperfのとおりにSBI PMU拡張を呼び、返るものを確かめる: OpenSBIが報告する
カウンタ、イベントに与えられるカウンタ(Smcntrpmfでサイクルと命令は固定のもの、プログラム可能なものが2つ、3つ目は
見つからない)、それらが数えること、Linuxのマスクでの生のイベント、RESET付きの停止で解放されるカウンタ(mmRISC-2のOpenSBIの
パッチ)、UINH、Sモードでのオーバーフロー割り込み。PASSはSBIのシステムリセット(HTIFの終了0)で終わり、FAILは`-max`まで回る:

```bash
PAYLOAD=pmu_sbi ./build.sh
../CORE/obj/cpu/VOOO_CPU +verilator+rand+reset+2 -console -max 60000000 work/pmu_sbi.elf
```

Spikeだけでは失敗する: SpikeのHPMカウンタは何も数えないので、OpenSBIはひとつも見つけない。

## ソース

Plan/csizeと同じくこのリポジトリの外: `MMRISC2`(mmRISC-2のリポジトリ、既定ではこのリポジトリの隣)、`INITRD`
(BusyBoxのinitramfs)、`KBUILD`(カーネルのビルドディレクトリ、約300 MB: `~/mmrisc3_linux/kbuild`)。
