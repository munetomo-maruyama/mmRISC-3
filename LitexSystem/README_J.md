# LitexSystem

Digilent Nexys Video(XC7A200T)上のLiteXのSoC。`Doc/STRATEGY_J.md`のフェーズ2(ボードは`Doc/BOARD_J.md`)。
英語: `README.md`。

| パス | 内容 |
|---|---|
| `scripts/build_stock.sh` | 手順2.0: LiteXのNexys Videoのターゲットそのまま(Rocket、100 MHz、DDR3-800、SDカード、Ethernet)をここで生成。VivadoはWindowsのVMで |
| `scripts/build_nexys_video.bat` | Windows側の実行。tclの横にコピーされる |
| `build_stock/` | 出力(gitには入れない): `gateware/`(Verilog、XDC、tcl、ビットストリーム)、`software/bios/`、`csr.csv`、`csr.json` |
| `docs/BRINGUP.md` | 立ち上げの記録(手順2.5のもの)、手順ごとの節 |

LiteXのワークスペースとPythonの環境はmmRISC-2のもの(`../mmRISC-2/LitexRocket`、その`LitexSystem/scripts/setup_litex.sh`が固定した版)。別の場所なら`LITEX_HOME`で指す。

```bash
./LitexSystem/scripts/build_stock.sh
```

その後、WindowsのVMで`LitexSystem\build_stock\gateware`にて: `build_nexys_video.bat`。
