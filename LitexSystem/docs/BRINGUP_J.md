# Nexys Videoの立ち上げ

フェーズ2(`Doc/STRATEGY_J.md` 2.0〜2.6)の記録。手順ごとに1節、新しいものを最後に。英語: `BRINGUP.md`。ボードの事実と各部の計画は`Doc/BOARD_J.md`。

## 1. 手順2.0: LiteXのターゲットそのまま(2026-11-24)

**何を**: mmRISC-2やmmRISC-3より先に、最も実績のあるCPUで: litex-boardsの`digilent_nexys_video.py`に、Rocket(variant `linux`、1コア: `LitexConfig_linux_1_1`、RV64IMAFDC、Sv39、L1キャッシュ16 KiB)、100 MHz、MT41K256M16をDDR3-800で動かす`A7DDRPHY`、J3のLiteSDCard、RGMIIのLiteEth。こちらのものを何も挟まずに、ボード、100 MHzでのDDR3、SDのスロット、ギガビットのポートを確かめ、比べるためのLinuxを得る。

**生成**(`scripts/build_stock.sh`、VMで): SoCのVerilog、XDC、Vivadoのtcl、BIOS(128 KiBのROMのうち43.6 KiB)。マップ(mmRISC-2と同じ): ROM 0x1000_0000、SRAM 0x1100_0000(8 KiB)、CSR 0x1200_0000、Ethernetのバッファ 0x3000_0000、CLINT 0x0200_0000、PLIC 0x0C00_0000、**メインRAM 0x8000_0000、512 MiB**。クロック100 MHz。

**標準のターゲットではなくmmRISC-2の立ち上げから取ったもの**: SDカードの出力のレジスタをI/Oブロックに(mmRISC-2のBRINGUP 13: これがないと、あるビルドはBIOSではカードを読めたがLinuxではCRCエラーになった)。配置後と配線後の物理最適化(AggressiveExplore)、mmRISC-2のビルドと同じ。**この手順ではそのまま**(`Doc/BOARD_J.md` 2、2.1で扱う): スイッチの`LVCMOS25`(標準のSoCは使わない)、8つのLEDすべてを使うLEDチェイサー、固定のアドレス(ターゲットにDHCPがない: ボード192.168.1.50、TFTPサーバ192.168.1.100。どちらも`litex>`のプロンプトで`eth_local_ip` / `eth_remote_ip`で、または生成時に`ETH_IP` / `REMOTE_IP`で変えられる)。

**見つけたこと**: mmRISC-2のvenvには`pythondata-cpu-rocket`がない(リポジトリはワークスペースにあるが、インストールされていない)。`build_stock.sh`は`PYTHONPATH`で見つけ、venvはそのままにする。

**次**: Vivadoの実行(作者、`build_nexys_video.bat`): 100 MHzでのタイミング(ArtyでのRocketは50 MHzで+0.409 ns。-1のデバイスで100 MHzは閉じないかもしれない: そのときクロックを下げたRocketはDDR3-800には使えないので、この手順の代わりはボードの確認にVexRiscvを100 MHzで、Rocket上のLinuxは2.2のCPU自身のクロック乗せ換えまで待つ)、LUT、`report_power`(`Doc/BOARD_J.md` 10、13)。ボードでは: BIOSのプロンプト、LiteDRAMのメモリテスト、`sdcardboot` / カードの読み出し、TFTP。その後Rocket上のLinux(linux-on-litex-rocketはこのボードに対応している)。
