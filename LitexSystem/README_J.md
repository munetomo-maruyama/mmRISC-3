# LitexSystem

Digilent Nexys Video(XC7A200T)上のLiteXのSoC。`Doc/STRATEGY_J.md`のフェーズ2(ボードは`Doc/BOARD_J.md`)。
英語: `README.md`。

| パス | 内容 |
|---|---|
| `scripts/build_stock.sh` | 手順2.0: LiteXのNexys Videoのターゲットそのまま(Rocket、100 MHz、DDR3-800、SDカード、Ethernet)をここで生成。VivadoはWindowsのVMで |
| `scripts/nexys_video_target.py` | `build_stock.sh`が実行するターゲット: LiteXのものだが、SDカードのPHYにLiteSDCardのカードのリセットがない(`docs/BRINGUP_J.md` 10: そうしないとBIOSの`sdcard_init`が止まる)。`SD_CARD_RESET=1`で残す |
| `scripts/build_nexys_video.bat` | Windows側の実行。tclの横にコピーされる |
| `CPU=vexriscv_smp scripts/build_stock.sh` | 同じものをVexRiscv-SMP(RV32、100 MHz)で`build_stock_vexriscv_smp/`へ: このデバイスでRocketは100 MHzを閉じない(`docs/BRINGUP_J.md` 2) |
| `scripts/program_nexys_video.bat` / `.tcl` | ビットストリームをJ12でFPGAへ(Vivadoのハードウェアマネージャ)。tclの横にコピーされる |
| `scripts/program_nexys_video.sh` | 同じことをこのLinuxのVMからopenFPGALoaderで(J12をVMにつなぐ) |
| `scripts/build_demo.sh` | ビルドに合わせたLiteXのベアメタルのデモ。`<build>/demo/`に`boot.json`(SDカード)と`vex.json`(TFTP)と一緒に |
| `scripts/build_linux_vexriscv.sh` | VexRiscv-SMPのSoC用のLinux: linux-on-litex-vexriscvのビルド済みイメージ(一度ダウンロード)にこのSoC自身のDTB。TFTPのフォルダ(`vexlinux/`)とSDカードのファイルとして(`docs/BRINGUP_J.md` 12) |
| `scripts/build_soc.sh` | 手順2.1と2.2: mmRISC-2(`cpu/mmrisc/`、RTLはmmRISC-2のリポジトリから)のSoCをLiteXのNexys Videoのターゲットに、LiteXは100 MHz、CPUは50 MHzで乗せ換え(`SYS_CLK` / `CPU_CLK`。両方50e6なら手順2.1のもの)、`build/`へ。VivadoはWindowsのVMで(`docs/BRINGUP_J.md` 13、15) |
| `cpu/mmrisc/` | mmRISC-2のLiteXのラッパ(mmRISC-2 Rev.02から): RTLは`MMRISC2_HOME`(既定は`../mmRISC-2`)から読む、デバッグポートは手順2.4までオフ |
| `build_stock/` | 出力(gitには入れない): `gateware/`(Verilog、XDC、tcl、ビットストリーム)、`software/bios/`、`csr.csv`、`csr.json` |
| `docs/BRINGUP.md` | 立ち上げの記録(手順2.5のもの)、手順ごとの節 |

LiteXのワークスペースとPythonの環境はmmRISC-2のもの(`../mmRISC-2/LitexRocket`、その`LitexSystem/scripts/setup_litex.sh`が固定した版)。別の場所なら`LITEX_HOME`で指す。

```bash
./LitexSystem/scripts/build_stock.sh
```

その後、WindowsのVMで`LitexSystem\build_stock\gateware`にて: `build_nexys_video.bat`。
