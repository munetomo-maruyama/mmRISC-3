# Nexys Videoの立ち上げ

フェーズ2(`Doc/STRATEGY_J.md` 2.0〜2.6)の記録。手順ごとに1節、新しいものを最後に。英語: `BRINGUP.md`。ボードの事実と各部の計画は`Doc/BOARD_J.md`。

## 1. 手順2.0: LiteXのターゲットそのまま(2026-11-24)

**何を**: mmRISC-2やmmRISC-3より先に、最も実績のあるCPUで: litex-boardsの`digilent_nexys_video.py`に、Rocket(variant `linux`、1コア: `LitexConfig_linux_1_1`、RV64IMAFDC、Sv39、L1キャッシュ16 KiB)、100 MHz、MT41K256M16をDDR3-800で動かす`A7DDRPHY`、J3のLiteSDCard、RGMIIのLiteEth。こちらのものを何も挟まずに、ボード、100 MHzでのDDR3、SDのスロット、ギガビットのポートを確かめ、比べるためのLinuxを得る。

**生成**(`scripts/build_stock.sh`、VMで): SoCのVerilog、XDC、Vivadoのtcl、BIOS(128 KiBのROMのうち43.6 KiB)。マップ(mmRISC-2と同じ): ROM 0x1000_0000、SRAM 0x1100_0000(8 KiB)、CSR 0x1200_0000、Ethernetのバッファ 0x3000_0000、CLINT 0x0200_0000、PLIC 0x0C00_0000、**メインRAM 0x8000_0000、512 MiB**。クロック100 MHz。

**標準のターゲットではなくmmRISC-2の立ち上げから取ったもの**: SDカードの出力のレジスタをI/Oブロックに(mmRISC-2のBRINGUP 13: これがないと、あるビルドはBIOSではカードを読めたがLinuxではCRCエラーになった)。配置後と配線後の物理最適化(AggressiveExplore)、mmRISC-2のビルドと同じ。**この手順ではそのまま**(`Doc/BOARD_J.md` 2、2.1で扱う): スイッチの`LVCMOS25`(標準のSoCは使わない)、8つのLEDすべてを使うLEDチェイサー、固定のアドレス(ターゲットにDHCPがない: ボード192.168.1.50、TFTPサーバ192.168.1.100。どちらも`litex>`のプロンプトで`eth_local_ip` / `eth_remote_ip`で、または生成時に`ETH_IP` / `REMOTE_IP`で変えられる)。

**見つけたこと**: mmRISC-2のvenvには`pythondata-cpu-rocket`がない(リポジトリはワークスペースにあるが、インストールされていない)。`build_stock.sh`は`PYTHONPATH`で見つけ、venvはそのままにする。

**次**: Vivadoの実行(作者、`build_nexys_video.bat`): 100 MHzでのタイミング(ArtyでのRocketは50 MHzで+0.409 ns。-1のデバイスで100 MHzは閉じないかもしれない: そのときクロックを下げたRocketはDDR3-800には使えないので、この手順の代わりはボードの確認にVexRiscvを100 MHzで、Rocket上のLinuxは2.2のCPU自身のクロック乗せ換えまで待つ)、LUT、`report_power`(`Doc/BOARD_J.md` 10、13)。ボードでは: BIOSのプロンプト、LiteDRAMのメモリテスト、`sdcardboot` / カードの読み出し、TFTP。その後Rocket上のLinux(linux-on-litex-rocketはこのボードに対応している)。

## 2. 手順2.0: 100 MHzのRocketは閉じない。VexRiscv-SMPを生成(2026-11-24)

**実行**(作者、1節の出力で`build_nexys_video.bat`、Vivado 2025.1、33分): ビットストリームは書かれたが、**WNS −5.208 ns、TNS −31,934 ns、失敗するエンドポイント14,607**(100 MHzのドメインの59,393中)。ホールド +0.034 ns。他のクロックはすべて達成: 100 MHzの入力 +7.755 ns、DDR3の`clkout3` +1.246 ns、EthernetのRX +1.272 ns。**LUT 37,563(28.1 %)**、FF 19,417、BRAM 40.5タイル、DSP 15。`report_power`はチップで**1.04 W**(ダイナミック0.87 W)、周囲25 °Cでジャンクション28.4 °C: この大きさでは冷却の問題なし(`Doc/BOARD_J.md` 10、13)。

**経路**: すべてRocketの中: I$の出力(`frontend/icache/s2_dout`) → デコード → EXのオペランドのレジスタのイネーブル(`core/ex_reg_rs_msb`)、14.66 ns、15段、配線84 %。Rocketのパイプラインは-1のデバイスで約15 ns(約65 MHz)を要する。Arty上の50 MHz(+0.409 ns)が示していたとおり。システムのクロックを下げても抜け道にならない: DDR3はそこから動き(1:4)、75 MHz未満ではDLLオンのDDR3の最低のデータレート(DDR3-600、`Doc/BOARD_J.md` 4)を下回る。乗せ換えの後ろで独自のクロックのRocketは手順2.2の仕事で、LiteXのターゲットそのままではない。

**`build_stock.sh`で見つけたこと**: LiteXのXDCは改行なしで終わり、付け足したコメントがその最後の行に続いてしまったので、Vivadoは`set_clock_groups ... sys_clk ... main_crg_clkin_signal -asynchronous`を落とした(CRITICAL WARNING 17-170)。この結果への影響はない(2つの間の1つの経路は+2.717 nsで達成、失敗は100 MHzのドメインの中)。直した(先に改行)。標準のままの警告: 合成が名前を変えた`eth_rx_clk` / `eth_tx_clk`のネットへの`create_clock`。

**そこで1節の計画どおり**: ボードの確認は**100 MHzのVexRiscv-SMP**で(`CPU=vexriscv_smp ./LitexSystem/scripts/build_stock.sh`、`build_stock_vexriscv_smp/`へ): RV32IMAでSv32、1コア、L1キャッシュ4 KiB、LiteDRAMの128ビットのポートに直接、コヒーレントなDMA(SDカードのもの)。linux-on-litex-vexriscvがこのボードで100 MHzで動かすもの。そのネットリストは生成済みのもの(`..._Ldw128_Cdma_Ood`、`--hardware-breakpoints 0`で: 既定の1ではLiteXがsbtでSpinalHDLを動かし、ダウンロードが要る)。マップはVexRiscvのもの: ROM 0x0000_0000、SRAM 0x1000_0000、メインRAM **0x4000_0000、512 MiB**、CSR 0xF000_0000、Ethernet 0x8000_0000。他は1節のとおり(DDR3-800、SD、192.168.1.50 / .100のEthernet、SDのレジスタをI/Oブロックに)。64ビットの基準のRocket上のLinuxは、2.2の乗せ換え(Rocketを50 MHz、LiteXを100 MHz)を待つか、mmRISC-2自身のものに代えてやめる。

**次**: `build_stock_vexriscv_smp`のVivadoの実行(作者、そこで`build_nexys_video.bat`)。
