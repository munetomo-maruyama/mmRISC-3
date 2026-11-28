# LitexSystem

Digilent Nexys Video(XC7A200T)上のLiteXのSoC。`Doc/STRATEGY_J.md`のフェーズ2(ボードは`Doc/BOARD_J.md`)。
英語: `README.md`。

| パス | 内容 |
|---|---|
| `scripts/build_stock.sh` | 手順2.0: LiteXのNexys Videoのターゲットそのまま(Rocket、100 MHz、DDR3-800、SDカード、Ethernet)をここで生成。VivadoはWindowsのVMで |
| `scripts/nexys_video_target.py` | `build_stock.sh`が実行するターゲット: LiteXのものだが、SDカードのPHYにLiteSDCardのカードのリセットがない(`docs/BRINGUP_J.md` 10: そうしないとBIOSの`sdcard_init`が止まる)。`SD_CARD_RESET=1`で残す。`--eth-dhcp`(手順2.3)はターゲットにないもの: 固定のIPなしでDHCPを使うEthernet、Artyのターゲットと同じ。スイッチとボタンはLVCMOS12、LEDチェイサーは残りのLEDに(手順2.4) |
| `scripts/build_nexys_video.bat` | Windows側の実行。tclの横にコピーされる |
| `CPU=vexriscv_smp scripts/build_stock.sh` | 同じものをVexRiscv-SMP(RV32、100 MHz)で`build_stock_vexriscv_smp/`へ: このデバイスでRocketは100 MHzを閉じない(`docs/BRINGUP_J.md` 2) |
| `scripts/program_nexys_video.bat` / `.tcl` | ビットストリームをJ12でFPGAへ(Vivadoのハードウェアマネージャ)。tclの横にコピーされる |
| `scripts/program_nexys_video.sh` | 同じことをこのLinuxのVMからopenFPGALoaderで(J12をVMにつなぐ) |
| `scripts/build_demo.sh` | ビルドに合わせたLiteXのベアメタルのデモ。`<build>/demo/`に`boot.json`(SDカード)と`vex.json`(TFTP)と一緒に。名前を付けると(`build_demo.sh LitexSystem/build mm2`)、TFTPサーバの`mm2/demo.bin`のための`mm2.json` |
| `scripts/build_linux_vexriscv.sh` | VexRiscv-SMPのSoC用のLinux: linux-on-litex-vexriscvのビルド済みイメージ(一度ダウンロード)にこのSoC自身のDTB。TFTPのフォルダ(`vexlinux/`)とSDカードのファイルとして(`docs/BRINGUP_J.md` 12) |
| `scripts/build_soc.sh` | 手順2.1から2.4: mmRISC-2(`cpu/mmrisc/`、RTLはmmRISC-2のリポジトリから)のSoCをLiteXのNexys Videoのターゲットに、LiteXは100 MHz、CPUは50 MHzで乗せ換え(`SYS_CLK` / `CPU_CLK`。両方50e6なら手順2.1のもの)、SDカードとDHCPのEthernet(TFTPサーバは`REMOTE_IP`、既定192.168.0.42)、Pmod JAのデバッグポート(`--cpu-jtag pmoda`)、`build/`へ。VivadoはWindowsのVMで(`docs/BRINGUP_J.md` 13、15、19、23)。`CPU=mmrisc3`: mmRISC-3(`cpu/mmrisc3/`)を`build3/`へ(手順2.6、`docs/BRINGUP_J.md` 28) |
| `openocd/nexys_jtag.cfg`、`nexys_cjtag.cfg` | Pmod JAのデバッグポート用のOpenOCDの設定(FT2232H、4線JTAG / 2線cJTAG)、nSRSTのないアダプタ向け: mmRISC-2の設定を`reset_config none`にしたもの(`docs/BRINGUP_J.md` 25)。IDCODEはmmRISC-2とmmRISC-3のどちらでも(手順2.6) |
| `software/dramlat/` | CPUから見たメモリのレイテンシとスループット: ベアメタルのポインタチェイス(4 KBから64 MB)と16 MBの読み書き、メインRAMから実行(`docs/BRINGUP_J.md` 27) |
| `scripts/build_dramlat.sh`、`scripts/run_dramlat.py` | ビルドのBIOSに合わせて`dramlat`を作る(`<build>/dramlat/`)。BIOSのシリアルブートでJ13から読み込み、出力を表示(`litex>`から、LiteXのデモからは`reboot`で、またはCPU RESETのあと) |
| `scripts/jtag_check.tcl` | mmRISC-2のデバッグポートの確認を、このSoCの識別子にも対応させたもの: 停止、misa、dcsr、システムバス経由の読み出し、レジスタの書き込みと復元、3回のステップ、再開(`docs/BRINGUP_J.md` 23) |
| `cpu/mmrisc/` | mmRISC-2のLiteXのラッパ(mmRISC-2 Rev.02から): RTLは`MMRISC2_HOME`(既定は`../mmRISC-2`)から読む。CPU自身のクロックドメインと乗せ換え(手順2.2)。どちらのボードでもPmod JAにデバッグポート、Nexys VideoではLD0-LD3にその状態(手順2.4) |
| `cpu/mmrisc3/` | 手順2.6: mmRISC-3のLiteXのラッパ(`--cpu-type mmrisc3`): このリポジトリの`RTL/CPU/TOP`の`CPU_TOP`(`OOO_CPU`、`DBG_TOP`、D$経由のDMAポート)。クロックドメイン、乗せ換え、デバッグポートは`cpu/mmrisc`と同じ。メモリバスをアドレスで分ける(メインRAMはLiteDRAMへ、ROMのラインはSoCバスへ、それ以外はすぐにDECERR: コアは投機的にフェッチする)(`docs/BRINGUP_J.md` 28) |
| `sim/run_sim.sh`、`sim/sim_main.cpp` | 手順2.6: `cpu/mmrisc3`でLiteXのBIOSをシミュレーション: LiteXが`litex_sim`のSoC(SDRAMモデル付きのLiteDRAM、UART)を生成し、Verilatorが`sim_main.cpp`(クロック、UARTを標準出力へ、`litex>`でコマンドを打つ)とともにビルド。`litex_sim`自身のモジュール(libevent)は使わない(`docs/BRINGUP_J.md` 28) |
| `build_stock/` | 出力(gitには入れない): `gateware/`(Verilog、XDC、tcl、ビットストリーム)、`software/bios/`、`csr.csv`、`csr.json` |
| `docs/BRINGUP.md` | 立ち上げの記録(手順2.5のもの)、手順ごとの節 |

LiteXのワークスペースとPythonの環境はmmRISC-2のもの(`../mmRISC-2/LitexRocket`、その`LitexSystem/scripts/setup_litex.sh`が固定した版)。別の場所なら`LITEX_HOME`で指す。

```bash
./LitexSystem/scripts/build_stock.sh
```

その後、WindowsのVMで`LitexSystem\build_stock\gateware`にて: `build_nexys_video.bat`。
