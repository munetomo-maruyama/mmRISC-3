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

## 3. 手順2.0: 100 MHzのVexRiscv-SMP: 達成(2026-11-24)

**実行**(作者、`build_stock_vexriscv_smp/gateware`で`build_nexys_video.bat`、8分): **すべての制約を達成: WNS +0.631 ns、TNS 0、ホールド +0.026 ns**。100 MHzの入力 +7.914 ns、DDR3の`clkout3` +1.215 ns、EthernetのRX +1.272 ns。**LUT 9,262(6.9 %)**、FF 8,433、BRAM 27.5タイル、DSP 4。`report_power`は**0.76 W**(ダイナミック0.60 W)、ジャンクション27.5 °C。クリティカルな警告は標準のものだけ(名前の変わった`eth_rx_clk` / `eth_tx_clk`のネットへの`create_clock`)。2節で落ちていた`set_clock_groups`は読まれるようになった(改行の修正が効いている)。

**最悪の経路はCPUではなくLiteDRAMのもの**: バンクマシンのコマンドのアドレス → そのtRASのカウンタのリセット(`bankmachine7 ... trascon_count`)、10段、+0.631 ns。100 MHzのLiteX自身のロジックの余裕は約0.6 ns。2.2と2.6で覚えておく価値がある(そこではLiteXは50 MHzのCPUの周りで100 MHzのまま)。

ほかに: 作者による1節のRocketのビルドの2回目の実行(`build_stock/`で、これと取り違えて)は、桁まで同じ結果(WNS −5.208 ns、14,607エンドポイント、LUT 37,563、1.04 W): フローに再現性がある。

**手順2.0のVivadoの部分は完了**: このデバイスで100 MHz、DDR3-800、SDカード、EthernetのLiteX自身のSoCのビットストリーム(`build_stock_vexriscv_smp/gateware/digilent_nexys_video.bit`)。**次はボードで**(届いたら): UART(115,200ボー)でBIOSのプロンプト、LiteDRAMのキャリブレーションと512 MiBのメモリテスト、SDカード(`sdcardboot`、ブロックの読み出し)、ギガビットのポートで192.168.1.100からTFTP。その後、基準としてLinux(このボード用のlinux-on-litex-vexriscvのイメージ)。

## 4. ボードでの手順2.0: 手順(2026-11-24)

ボードが届いた。**始める前に見つけたこと**: LANは192.168.0.0/24(TFTPサーバ、ブリッジ接続のこのUbuntuのVMは192.168.0.42)で、192.168.1.xではない。またBIOSの`eth_local_ip` / `eth_remote_ip`のコマンドは動的なIPのときだけあり、このターゲットはそれを与えられない(`Doc/BOARD_J.md` 2)。1節でプロンプトで変えられると書いたのは誤り。`build_stock_vexriscv_smp`を**ボード192.168.0.50**(事前にそこはARPに応答なし)、**サーバ192.168.0.42**で生成し直した(`CPU=vexriscv_smp ETH_IP=192.168.0.50 REMOTE_IP=192.168.0.42`)。変わるのはBIOSの定数だけなので3節のタイミングは保たれるが、TFTPにはVivadoをもう一度要する。3節のビットストリーム(192.168.1.x)はTFTP以外のすべてに使える。

**ここで新しく**: `scripts/program_nexys_video.bat` / `.tcl`(ビットストリームをVivadoのハードウェアマネージャからJ12でFPGAへ、揮発)、`scripts/build_demo.sh`(メインRAMにリンクしたLiteXのベアメタルのデモ、SDカード用の`boot.json`とTFTP用の`vex.json`付き: サーバの`boot.json`はmmRISC-2のLinuxで、このSoCではRAMでないアドレスなので、取らせてはいけない)。

**確認、この順に**(J12はWindowsのVMへ書き込み用、J13は115,200 8N1、フロー制御なしの端末へ。JP4はJTAG。最初はSDカードなし):
1. **書き込み**: `build_stock_vexriscv_smp\gateware`で`program_nexys_video.bat`。期待: LiteXのバナー、`CPU: VexRiscv SMP-LINUX @ 100MHz`、ビルド日付きの識別子`LiteX SoC on Nexys Video`。
2. **DDR3**: BIOSが起動時にキャリブレーションする(`Initializing SDRAM @0x40000000...`、ライトレベリング、モジュールごとのリードレベリング、`Memtest OK`、速度)。その後`litex>`で: `mem_test 0x40000000 0x20000000`(512 MiB全部、数分)と`mem_speed 0x40000000 0x1000000`。起動時にQかESCで自動のブートを止める。
3. **UARTでのロード**(カードもネットワークも要らない): デモのフォルダで`litex_term --kernel demo.bin --kernel-adr 0x40000000 /dev/ttyUSB0`、その後`reboot`: デモのプロンプト(`help`、`led`、`donut`)。
4. **SDカード**: 予備のFATのカード(mmRISC-2の`LITEXBOOT`ではない)のルートに`demo.bin`と`boot.json`、Macから書く(mmRISC-2の古いマウントの問題)、ボードの下のJ3へ。`sdcard_init`、`sdcardboot`: デモ。
5. **TFTP**(生成し直したSoCのVivadoの実行の後): このVMで`sudo cp demo.bin vex.json /srv/tftp/`、RJ-45をギガビットのスイッチへ。`netboot vex.json`: デモ。

その後、基準としてLinux(このボード用のlinux-on-litex-vexriscvのイメージ、取ってくる必要あり)。

## 5. ボードでの手順2.0: BIOSとDDR3(2026-11-25)

**書き込み**: `program_nexys_video.bat`は`open_hw_target`で失敗した(「There is no current hw_target」): 起動したばかりのhw_serverがまだケーブルを挙げていなかった。代わりにVivadoのGUIから書き込んだ。tclは最大20秒ターゲットを探し直し(`refresh_hw_server`)、最初のものを開くようにした。

**BIOS**(3節のビットストリーム、2026-11-24 17:02のBIOS、ローカルIP 192.168.1.50): バナー、`CPU: VexRiscv SMP-LINUX @ 100MHz`、`SDRAM: 512.0MiB 16-bit @ 800MT/s (CL-6 CWL-5)`。**ボード、100 MHzのクロック、J13のUART、BIOSが動く**。

**DDR3**: リードレベリングは両方のバイトレーンでbitslip 2に窓を見つけた(m0、m1: 遅延9 ± 7タップ、32中15が良)。bitslip 3にも2つ目の窓(タップ19から最後まで)。BIOSの2 MiBで`Memtest OK`。**書き込み156.6 MiB/s、読み出し77.8 MiB/s**(連続、CPUの32ビットのWishbone。DDR3の限界ではない)。**このボードの部品でDDR3-800のキャリブレーションが通る**(`Doc/BOARD_J.md` 4、懸念4)。

**止まったところ**: シリアルブートのタイムアウトの後(`sL5DdSMmkekro`は`litex_term`への要求で、別の端末では普通)、`Booting from SDCard in SD-Mode...`、`Booting from boot.json...`、その後何も出ない。J3にカードがあり、BIOSはそのFATのパーティションと`boot.json`を読んだ(つまりSDのスロット、カードの初期化、LiteSDCardの読み出しは動く)。カードがmmRISC-2の`LITEXBOOT`なら、その`boot.json`は`Image`(15 MB)を0x8020_0000へ、`fw_jump.bin`を0x8000_0000へロードする。このSoCではそこはRAMではない(0x8000_0000はEthernetのバッファ、0x8000_2000より上には何もない): ロードはどのメモリにも行かず、BIOSは戻ってこない。4節は最初はカードなしと頼んでいた。カード自身の`boot.json`はデモのもの(`build_demo.sh`)でなければならない。

**次**: カードなしで(または「Press Q or ESC」でQ / ESC)、`mem_test 0x40000000 0x20000000`。その後UARTでのロード、デモのカード、TFTP、4節のとおり。

## 6. LinuxのVMからの書き込み(2026-11-25)

5節の再試行は効かなかった: バッチのVivadoのhw_serverは20秒間ケーブルを挙げなかった(`ERROR: no JTAG cable found`)。一方でGUIはボードに書き込める。Windows側ではこれ以上追わない(GUIを代わりの手段として残す)。

**代わりにこのVMから**: `scripts/program_nexys_video.sh`が`openFPGALoader -b nexysVideo <bit>`を実行する(`/usr/local/bin`にインストール済み、そのボードの一覧に`digilent_b`のケーブルで`nexysVideo`がある。Digilentのudevのルールもある)。J12のFT2232H(0403:6010)をParallelsでこのVMにつなぐ必要がある。J13のFT232R(0403:6001)はすでにつながっている(`/dev/ttyUSB0`、作者のminicom)。両方ここにあれば、書き込みとコンソールが一つの側にそろう。

## 7. ボードでの手順2.0: Linuxから書き込み、512 MiBを試験(2026-11-25)

J12をこのVMにつないだ: `openFPGALoader -b nexysVideo`が3節のビットストリームをFPGAにロードした(rc 0。J12のポートBは`/dev/ttyUSB1`、J13のUARTは`/dev/ttyUSB0`として見える)。**Linuxからの書き込みは動く**(`program_nexys_video.sh`)。コンソールはここから操作した(115,200のpyserial: 「Press Q or ESC」でQ、その後コマンド)。今回はJ3にカードなし。

- キャリブレーションは5節のとおり(m0 bitslip 2、9 ± 7タップ。m1 8 ± 6)、2 MiBで`Memtest OK`。
- **`mem_test 0x40000000 0x20000000`: 512 MiB全体で`Memtest OK`**(全体の書き込みの後に読み出し)。
- `mem_speed 0x40000000 0x1000000`(16 MiB): 書き込み159.6 MiB/s、読み出し78.0 MiB/s。

**このボードでDDR3-800のDDR3は良好。**(スクリプトはプロンプトを素の`litex>`として待ったが、BIOSはANSIのコードで色を付けるので、各コマンドの後に待ち時間いっぱい待った。今はコードを取り除く。)

**次**: UARTでのデモ(`litex_term --kernel`)、デモのSDカード、生成し直したSoCのVivadoの実行の後にTFTP。

## 8. ボードでの手順2.0: UARTとTFTPでデモ(2026-11-25)

作者の実行。生成し直したSoCのビットストリーム(Vivadoを再実行。バナーに`Local IP: 192.168.0.50`)。

- **UARTでデモ: OK。** `litex_term --kernel demo.bin --kernel-adr 0x40000000 /dev/ttyUSB0`: BIOSのシリアルブートが要求し、7,072バイトを10.6 KB/sでアップロード、`Liftoff!`、デモのプロンプト`litex-demo-app>`とそのコマンド(`help`、`led`、`donut`、`helloc`)。
- **TFTP: OK。** `litex>`で(「Press Q or ESC」でQ): `netboot vex.json`: Local IP 192.168.0.50、Remote IP 192.168.0.42(このVMのtftpd-hpa)、`Copying demo.bin to 0x40000000... (7072 bytes)`、`Liftoff!`、デモのプロンプト。**Ethernet(RGMIIのPHY)とTFTPの経路は動く。**
- **SDカード: まだ試していない。** `sdcard_init`と`sdcardboot`はデモのプロンプト`litex-demo-app>`で入力されたが、デモはこれらを知らない(何も答えない)。これらはBIOSのコマンドで、`litex>`で使う。もう一度: `demo.bin`と`boot.json`のカードをJ3に挿し、シリアルブートのタイムアウトを待つ(BIOSは自分でSDカードへ進む: 「Booting from SDCard in SD-Mode...」)か、Qを押して`litex>`で`sdcardboot`と入力する。

**次**: `litex>`でSDカード。その後、基準としてVexRiscv-SMPでLinux(linux-on-litex-vexriscvのイメージ)。

## 9. ボードでの手順2.0: SDカードはファイルをロードする前に止まる(2026-11-25)

デモのカード(`boot.json` 33バイト、`demo.bin` 7,072バイト、Macから書き込み)で、`litex>`での`sdcardboot`は`Booting from SDCard in SD-Mode...`、`Booting from boot.json...`と出し、その後何も出ない: **5節と同じ止まり方**。

**5節の説明は誤りだった。** BIOS(`boot.c`)では、`boot.json`自身はメッセージなしで読まれる(`fatfs_load_file(..., progress 0)`)。次にその各イメージが`Copying <file> to <addr> (<n> bytes)...`と出し、途中のどのエラーも1行出す(`filesystem mount failed`、`cannot open`、`invalid boot JSON`)。ここでは`Copying demo.bin`もエラーも出なかった: **BIOSはSDカードへの最初のアクセスの中で止まっている**(FatFsのマウント、または`boot.json`の読み出し)。`boot.json`のアドレスが使われるより前。5節が書いたようにカードのFATと`boot.json`を読んだのではない。mmRISC-2のカードも同じ理由で止まったのであり、そのロードアドレスのせいではない。

LiteSDCardのドライバ(`liblitesdcard/sdcard.c`)で止まりうる所: `sdcard_wait_cmd_done()`と`sdcard_wait_data_done()`はコアのイベントを時間の制限なしにポーリングする(制限があるのはDMAの待ちだけで、1秒)。したがって次のどちらか:

1. **コマンドかデータ転送が終わらない**(カードの初期化かブロックの読み出し: SDのクロック、`rst` V20でのカードの電源、CMD / DATの線)。
2. **DMAがBIOSの読み込み先に書けない。** BIOSのバッファ(FatFsのセクタ、`boot_json_buffer`)は0x1000_0000の8 KiBのSRAMにある。`--with-coherent-dma`では、LiteSDCardの`block2mem`のDMAはVexRiscv-SMPのコヒーレントなDMAポートを通り(`soc.h`: `CONFIG_CPU_HAS_DMA_BUS`)、そこからはメインRAMにしか届かないかもしれない。DMAが止まるとデータの経路が詰まり、`sdcard_wait_data_done()`は永久に待つ。

**確かめ方**(リセットボタンの後、「Press Q or ESC」でQを押して`litex>`で)、この順に:

| コマンド | わかること |
|---|---|
| `sdcard_detect` | カード検出のピン(`inserted`) |
| `sdcard_init` | 初期化: `Initialize SDCard: OK` / `Failed`、または止まる(場合1) |
| `sdcard_read 0 0x40000000` | ブロック0をDMAでメインRAMへ: `55 aa`で終わるダンプ |
| `sdcard_read 0` | ブロック0をDMAでSRAMへ(コマンドのスタックのバッファ): ここだけで止まれば場合2 |

## 10. ボードでの手順2.0: SDカードが止まる原因: LiteSDCardのカードのリセットとBIOSのタイミング(2026-11-25)

このVMから操作した(作者のminicomを閉じてもらった): ボードは`openFPGALoader`で書き込み、コンソールはpyserialで。BIOSの`mem_read` / `mem_write`でSDのコアのCSR(0xF000_4000)を操作し、カードを手で動かした。

**止まるのは`sdcard_init`。** `sdcard_detect`: `SDCard inserted.`。`sdcard_init`: 240秒答えがない(その制限つきのループのどれよりも長い)。その後ボードは新しいビットストリームでしか答えない。9節の場合2ではない: DMAは両方のメモリに書ける(下)。

**手で行うと、初期化のどの手順も動く**(PHYを初期化し、各コマンドのイベントを読み返す):

| 手順 | 結果 |
|---|---|
| 400 kHzでCMD0、CMD8(0x1AA) | 完了。R7 `08 000001AA`: カードは答える。ver2.00のカード |
| CMD55 + ACMD41(0x70FF8000) | 2回目のACMD41が`C0FF8000`: 準備完了、CCS = 1(SDHC)。BIOSと同じくCMD8の後クロックを25 MHzにしても同じ |
| CMD2、CMD3、CMD9、CMD7、CMD16(512) | 完了。CID `SMT02...`、RCA 0x13AB |
| CMD6(SDR25へ切り替え、64バイトをDMAでメインRAMへ) | 完了、DMA完了、ステータス`00 C8 80 01 ...` |
| `sdcard_freq 25000000`、`sdcard_read 0 0x40002000` | MBR(FAT32のパーティション、タイプ0x0C、LBA 8192から、とLinuxのもの0x83)、`55 AA` |
| CMD55 + ACMD51(SCR、8バイトをDMAで) | `02 85 80 83 ...`: 1ビットと4ビットのバス |
| CMD55 + ACMD6(4ビット)、PHYを4X、`sdcard_read 0 0x40004000` | 再びMBR |
| `sdcard_read 0`(SRAMへ、0x1000_1CE0) | 再びMBR: **コヒーレントなDMAはSRAMに届く** |

つまりカード、ピン、PHY、コア、DMAはすべて動く。BIOSが違うのはタイミング。

**原因。** LiteSDCardのb0d2771(2026-06-19、「phy: Reset SD card during initialization when available」)は`SDPHYInit`に`RESET`状態を加えた。`rst`のパッドがあるボード(Nexys VideoのV20、カードの電源スイッチ)では`phy_init_initialize`を書くたびに入る: `card_reset`を1(カードの電源オフ)、CMD / DATを1に駆動して4096 SDクロック、初期化の400 kHzで約10 ms、その後`INITIALIZE`の80クロック。PHYは全サブモジュールのパッド出力のORを取るので、その間に送ったコマンドは全部1になって、電源のないカードへ出る。BIOSの`sdcard_init()`(変更なし)は`phy_init_initialize`を書き、1 ms待ち(`busy_wait(1)`)、CMD0とCMD8を送る: CMD8はタイムアウトし(コマンドのタイムアウトは1秒: `add_sdcard`の`cmd_timeout=10e-1`)、ループは最大1000回やり直す。毎回`phy_init_initialize`を書くので毎回新しいリセット: **約1000 × 1秒、17分たってから`sdcard_init`はあきらめる**。`sdcardboot`(FatFsの`disk_initialize`)も同じ。手で行ったときはUART自体の速さで書き込みとCMD0の間に数十msあったので、リセットは終わっていた。

**測定: `sdcard_init`を最後まで走らせると、1,003.3秒後に`Initialize SDCard: failed`と出た**: 1秒のタイムアウトを1000回と、各回の`busy_wait`の3 ms、計算どおり: ループのどのCMD8もリセット中に出た。

**対策(mmRISC-3の側)。** `scripts/nexys_video_target.py`はLiteXのターゲットを、`SDPHYInit`をリセットなし(`with_reset=False`)で作って実行する: 状態機械はb0d2771の前と同じく`IDLE`から`INITIALIZE`へ進み、`card_reset`は0のまま(`rst`のパッドは低、カードはコンフィギュレーションから給電)。`build_stock.sh`はこれを実行するようにした(`SD_CARD_RESET=1`で元のPHY)。VexRiscv-SMPのSoCを生成し直した(LANのIPは前と同じ): Verilogで違うのは状態機械の`IDLE`の遷移だけ(`next_state = 2'd2`、`1'd1`ではない)。Vivadoがもう一度要る。前のビットストリームは`digilent_nexys_video_sdreset.bit`として残した。(BIOSで`phy_init_initialize`の後10 msより長く待つのが上流での直し方だろう。それはLiteXのツリー、mmRISC-2のワークスペースなので、ここでは変えない。)

## 11. ボードでの手順2.0: SDカードから起動(2026-11-26)

**Vivado(10節のSoCを作者が実行): 達成**: WNS +0.758 ns、TNS 0、ホールド+0.021 ns、全クロック達成。9,244 LUT、27.5 BRAMタイル、0.757 W(3節: 9,262 LUT、0.76 W。PHYのリセットのカウンタがなくなった)。2つのクリティカルワーニングは3節の実行と同じ。

**ボードで**(このVMから書き込み、9節と同じデモのカード):

- バナー: `Local IP: 192.168.0.50`。
- `sdcard_detect`: `SDCard inserted.`。**`sdcard_init`: 0.1秒で`Initialize SDCard: OK`**(前は1,003秒で`failed`)。
- `sdcard_read 0`(SRAMへ): MBR、`55 AA`。
- **`sdcardboot`**: `Booting from boot.json...`、`Copying demo.bin to 0x40000000 (7072 bytes)...`、`Liftoff!`、デモのプロンプト。
- **書き込みの後に何も押さないと**: シリアルブートの`Timeout`、次に`Booting from SDCard in SD-Mode...`、同じロードと`Liftoff!`: BIOSは自分でカードから起動する。

**手順2.0のボードでの確認は、Linuxを除いて完了**: BIOS、DDR3-800(512 MiB全体)、UARTでのロード、EthernetでのTFTP、SDカード。**次**: 基準としてVexRiscv-SMPでLinux(linux-on-litex-vexriscvのイメージ、ダウンロードが要る)、または手順2.1。

## 12. ボードでの手順2.0: VexRiscv-SMPでLinux(2026-11-26)

**イメージ**: linux-on-litex-vexriscvのビルド済みのもの(そのissue 164、`linux_2022_03_23.zip`、5.4 MB、作者の許可を得てダウンロード): Linux 5.14.0(Buildroot 2021.08、GCC 10.3)、Buildrootの`rootfs.cpio`、OpenSBI v0.8(`LiteX / VexRiscv-SMP`のプラットフォーム)。アーカイブの`rv32.dtb`はこのSoCのものではない(64 MiB、別の割り込み番号)ので、デバイスツリーはこのSoCの`csr.json`から生成する(`litex_json2dts_linux`): 512 MiB、UARTは0xF000_1000、`liteeth`(割り込み3)、`litex,mmc`(割り込み4、4ビット)、PLICは0xF0C0_0000、CLINTは0xF001_0000。`scripts/build_linux_vexriscv.sh`がすべてを行い(ダウンロードは一度)、ファイルをTFTPのフォルダ`vexlinux/`(サーバの`Image`と`boot.json`はmmRISC-2のもの)とSDカード用の一式に置く。起動したファイルをバイト単位で再現する。作者が`vexlinux/`を`/srv/tftp`へコピーした(sudo)。

**起動**(このVMから書き込み、`litex>`で`netboot vexlinux/boot.json`):

- TFTP: `Image` 7,531,468バイト、`rv32.dtb`、`rootfs.cpio` 3,781,632バイト、`opensbi.bin`。0x40F0_0000で`Liftoff!`。
- OpenSBI v0.8: `Platform Name: LiteX / VexRiscv-SMP`、`Boot HART ISA: rv32imas`、ファームウェアは0x40F0_0000。
- Linux: `Machine model: digilent_nexys_video`、メモリは0x4000_0000から0x5FFF_FFFF、`Memory: 503476K/524288K available`、SBI v0.2(TIME、IPI、RFENCE、HSM)、PLICの32割り込み、100 MHzのタイマ、200 BogoMIPS、CPU 1個。
- `liteeth f0002000.mac eth0: irq 2 slots: tx 2 rx 2`。`litex-mmc`: `mmc0: new SDHC card at address 13ab`、`mmcblk0: mmc0:13ab SE032 28.8 GiB`、`p1 p2`、カードは25 MHz。
- `Initramfs unpacking failed: invalid magic`は3.8 MBのアーカイブより先の8 MiBのinitrdの窓のこと(アーカイブ自体は展開された: `/init`が動く)。カーネルの行の`ip=`は無視される(このカーネルにIPの自動設定はない)。
- **`netboot`から81秒で`Welcome to Buildroot`、`buildroot login:`**(大部分はTFTP)。rootでログイン。

**シェルで確かめたこと**:

| コマンド | 結果 |
|---|---|
| `uname -a` | `Linux buildroot 5.14.0 #1 SMP ... riscv32 GNU/Linux` |
| `cat /proc/cpuinfo` | `isa: rv32i2p0_ma`、`mmu: sv32` |
| `free` | 合計511,872 kB、空き501,592 kB |
| `ip addr add 192.168.0.50/24 dev eth0`、`ip link set eth0 up` | `UP,LOWER_UP`。LANのルータからIPv6のアドレスも |
| `ping -c 5 192.168.0.42` | 5回中5回、8.5から45 ms |
| `cat /proc/partitions` | `mmcblk0` 30,220,288ブロック、`p1` 512 MiB、`p2` 4.7 GiB |
| `mount -o ro /dev/mmcblk0p1 /mnt` | `boot.json`、`demo.bin`。`demo.bin`のmd5はコピー元のファイルと同じ |
| `cat /proc/interrupts` | `eth0` 29、`litex-mmc` 80、`riscv-timer`(UARTはポーリング) |

**手順2.0完了**: LiteXのターゲットそのままを、BIOS、DDR3-800、UART、TFTP、SDカード、Linuxでボードで動かした。CPUはVexRiscv-SMP(このデバイスでRocketは100 MHzを閉じない、2節。Rocket上のLinuxは2.2の乗せ換えを待つ)。元のターゲットからの変更が1つ要る: SDカードのPHYにLiteSDCardのカードのリセットを入れない(10節)。

作者が手でもう一度起動した(2026-11-26): `/dev/ttyUSB0`でminicom、CPU RESETボタン、「Press Q or ESC」でQ、`netboot vexlinux/boot.json`、Buildrootのログイン。

## 13. 手順2.1: Nexys VideoにmmRISC-2、生成(2026-11-26)

**内容**: LiteXのNexys Videoのターゲットそのまま(手順2.0と同じく`nexys_video_target.py`経由)に、**CPUとしてmmRISC-2**(Rev.02)、SoC全体を50 MHzで: このプロジェクト自身のCPUでのボードの最初の点灯。

- `cpu/mmrisc/`: mmRISC-2のLiteXのラッパ(`core.py`とBIOSの`crt0.S`、`boot-helper.S`、ヘッダ)を`mmRISC-2/LitexSystem/cpu/mmrisc`からコピー。変更は2つ: RTLはコピーせずmmRISC-2のリポジトリから読む(`MMRISC2_HOME`、既定は`../mmRISC-2`。そのRTLはRev.02から変わっていない)。デバッグポートの既定は`none`(そのピン、スイッチ、LEDはArtyのもの。Nexys Videoのものは手順2.4で)。
- `scripts/build_soc.sh`: `--cpu-type mmrisc --sys-clk-freq 50e6 --l2-size 0`、配置と配線の後にAggressiveExplore(mmRISC-2と同じ)、出力は`LitexSystem/build/`(gitには入れない)。tclのパスは相対(このリポジトリ、mmRISC-2のRTL: `../../../../mmRISC-2/RTL/...`)。Windows側の`build_nexys_video.bat`を横にコピー。
- まだ入れないもの: SDカードとEthernet(手順2.3)、デバッグポート(2.4)。BIOSはシリアルブートのタイムアウトの後プロンプトへ行く。

**生成したSoC**: MMCMはsys 50 MHz、sys4xとsys4x_dqs 200 MHz、IDELAYCTRL 200 MHz。mmRISC-2のマップ(ROM 0x1000_0000、SRAM 0x1100_0000、CSR 0x1200_0000、CLINT 0x0200_0000、PLIC 0x0C00_0000)、**メインRAM 0x8000_0000、512 MiB**。CPUのDMAバスを宣言(`CONFIG_CPU_HAS_DMA_BUS`)。メモリバスは64ビットからLiteDRAMの128へ。BIOSは23.4 KiB。**DDR3は4 × 50 MHz、DDR3-400で動く**(CL 6、CWL 5)。JEDECの範囲より下: `Doc/BOARD_J.md` 4の案D、BIOSのプロンプトのための試行だけ。手順2.2でLiteXを100 MHz、CPUを50 MHzにしてクロック乗せ換えでつなぐ。

**次**: WindowsのVMでVivado(`LitexSystem\build\gateware\build_nexys_video.bat`)、その後ボード(`program_nexys_video.sh LitexSystem/build/gateware/digilent_nexys_video.bit`): バナー、`CPU: mmRISC-2 (RV64GC) @ 50MHz`、400 MT/sでのDDR3のキャリブレーション、プロンプト。

## 14. ボードでの手順2.1: mmRISC-2でBIOSのプロンプト(2026-11-26)

**Vivado(13節のSoCを作者が実行): 達成**: 20 nsでWNS +0.387 ns(sys、78,032エンドポイント)、TNS 0、ホールド+0.035 ns、全クロック達成。クリティカルワーニングなし。**45,954 LUT(34.3 %)**、25,949 FF、94.5 BRAMタイル、32 DSP、0.824 W。

**ボードで**(作者が書き込み、J13でminicom):

- バナー: `CPU: mmRISC-2 (RV64GC) @ 50MHz`、`SDRAM: 512.0MiB 16-bit @ 400MT/s (CL-6 CWL-5)`、`MAIN RAM: 512.0MiB`、2026-11-26 01:09:57のBIOS。
- **400 MT/sでDDR3のキャリブレーションが通る**: 窓は1つ、両バイトレーンでbitslip 1、遅延16 ± 14タップ(32中30が良: 400 MT/sではビット時間2.5 nsが78 psのタップ32個ほぼ全部)。0x8000_0000の2 MiBで`Memtest OK`。
- Memspeed: 書き込み52.6 MiB/s、読み出し38.9 MiB/s(50 MHzのmmRISC-2のキャッシュを通したBIOSのループ。100 MHzのVexRiscvでは5節: 156.6 / 77.8)。
- シリアルブートの`Timeout`、`No boot medium found`(このSoCにSDカードもEthernetもない)、**`litex>`**。

**手順2.1のゲート達成: mmRISC-2でボードにLiteX BIOSのプロンプト。** DDR3-400のDDR3はJEDECの範囲外で、Artyと同じくこのボードの部品で動いた(試行だけ、`Doc/BOARD_J.md` 4の案D)。**次**: 手順2.2、LiteXを100 MHz(手順2.0と同じDDR3-800)、CPUを50 MHzにしてクロック乗せ換えでつなぐ。ゲートは512 MiB全体のメモリテスト。

## 15. 手順2.2: LiteXは100 MHz、CPUは50 MHzでクロック乗せ換え、生成(2026-11-26)

**内容**(`Doc/BOARD_J.md` 4、案A): LiteXをこのボードでの既定の100 MHzに。するとLiteDRAMはDDR3を手順2.0と同じDDR3-800で動かし、ボードに載りうるどの部品でもJEDECの範囲内。mmRISC-2は自分のクロックドメインで50 MHz。その3つのバスはラッパの中で乗せ換える。

**`cpu/mmrisc/core.py`**:

- `--cpu-clk-freq`(`build_soc.sh`: `CPU_CLK`、既定50e6。`SYS_CLK`の既定は100e6)。sysと違うとき、`add_soc_components`がCRGのMMCMにクロックドメイン`mmrisc`を加える(`create_clkout`、リセットはLiteXの他のドメインと同じくMMCMのロックから)。同じクロックなら何も乗せ換えない(`SYS_CLK=50e6 CPU_CLK=50e6`は手順2.1のSoC)。
- CPU_TOPのバスに自分の名前を付けた(`cpu_mem`、`cpu_mmio`、`cpu_dma`、CPUのドメイン)。LiteXが見るもの(`mem_axi`、`mmio_axil` → Wishbone、`dma_bus`、sys)とはLiteXの乗せ換えでつなぐ: メモリバスは`AXIClockDomainCrossing`(CPU → sys、その後LiteXの64 → 128ビットの変換でLiteDRAMへ)、周辺バスは`AXILiteClockDomainCrossing`(CPU → sys、その後`AXILite2Wishbone`)、DMAバスは`AXILiteClockDomainCrossing`(sys → CPU)。各チャネルは深さ4の`AsyncFIFO`(グレイコードのポインタを`MultiReg`で)。
- 割り込み(LiteXのイベントマネージャのレベル)とLiteXのCPUリセット(ctrlの`cpu_rst`、レベル)は`MultiReg`でCPUのドメインへ。SoCのリセット(`soc_rst`)はMMCMをリセットするので全ドメイン。CPU_TOPの`clk`、`rst_n`、`rst_dbg_n`は`mmrisc`ドメインから。
- `CLINT_TICK_DIV`はCPUのクロックから(`cpu_clk / 500 kHz` = 100): `mtime`は500 kHzのまま。
- BIOSのバナーはsysのクロックを表示するので、CPUの名前に自分のクロックを入れた: `mmRISC-2 (RV64GC, CPU 50MHz)`。

**生成したSoC**: MMCM(VCO 1,200 MHz)はsys 100 MHz(÷12)、sys4xとsys4x_dqs 400 MHz(÷3、後者は90°)、IDELAYCTRL 200 MHz(÷6)、clk100(÷12)、**mmrisc 50 MHz(÷24)**を出す: MMCMは1つなので2つのクロックは関係があり、VivadoはFIFOのデータの経路を10 nsで調べる。`MultiReg`はフォールスパス(LiteXの`mr_ff`の制約)。`CONFIG_CLOCK_FREQUENCY`は100 MHz(BIOSのタイマとUART)、DDR3は800 MT/s(CL 6、CWL 5)、マップは同じ。Verilogで: CPU_TOPは`mmrisc_clk`、`rst_n = ~(mmrisc_rst | cpu_reset)`、`CLINT_TICK_DIV`は100、割り込みは`MultiReg`経由、非同期FIFOが15本(メモリバスの5チャネル、周辺バスとDMAバスの各5)。手順2.1のビットストリームは`LitexSystem/build/digilent_nexys_video_step21.bit`として残した。

全体はシミュレーションしていない(LiteXの乗せ換えはLiteX自身のものをそのまま使う。配線はVerilogで確かめた)。ゲートはボードで。

**次**: Vivado、その後ボード: バナー、800 MT/sのDDR3、次に`mem_test 0x80000000 0x20000000`(ゲート、512 MiB全体)と`mem_speed`。

## 16. 手順2.2の最初の実行: CPUの中で−16.4 ns、割り込みの乗せ換えが原因(2026-11-26)

**実行結果**(著者のVivado 2025.1): WNS **−16.423 ns**、TNS −15,629.8 ns、違反エンドポイント7,580。すべてCPU自身のクロック(`main_basesoc_clkout`、MMCMのCLKOUT5、50 MHz)の中です。ホールドは満たしています(+0.015 ns)。sys(`main_crg_clkout0`、100 MHz)は+0.342 ns、2つのクロックの間の乗せ換えは+6.072 / +6.667 ns、LiteXの非同期グループは+4.451 nsで満たしています。**乗せ換えとLiteXは問題なく、CPUが満たしていません**。LUTは48,085(手順2.1: 45,954)。

**最悪のパス**: 46段(36.2 ns)。PLICの`threshold`レジスタから、ソース全体の優先度の選択(`u_plic/pending[...]_i_*`)を通り、`irq_s_ext`、CSRユニットの割り込み要求、`ex_exc_tval_r`へ。同じCPUが手順2.1では50 MHzを満たしていました(+0.387 ns)。

**原因**: 手順2.1ではCPU_TOPの`ext_irq`をLiteXの割り込みベクタから直接つないでいました。このSoCが使うのはそのうち2本(uart 0、timer0 1)で、残り29本は定数0でした。そのためVivadoがそれらのソースとPLICの選択の大半を取り除いていました。手順2.2では31ビットのベクタ全体を1つの`MultiReg`で乗せ換えました。LiteXはそのフリップフロップに`async_reg, dont_touch`を付けます。そのため定数の29本が生きたフリップフロップになり、31ソース全体のPLICの木が残りました(PLICはLUT 1,371)。

**修正**(`cpu/mmrisc/core.py`): 割り込みは`do_finalize`で1本ずつ、LiteXが駆動する線だけを乗せ換えます。LiteXの`SoC.finalize`はサブモジュールをfinalizeする前に割り込みをつなぐ(`_finalize_irq`)ので、CPUの`do_finalize`が動く時には`soc.irq.locs`は揃っています。使う線ごとに`MultiReg`を置き、ほかの線は1つのクロックドメインの時と同じく定数0にします。生成し直した結果: `ext_irq[0]`と`[1]`は2つの`MultiReg`から、`[2]`から`[30]`は0。Vivadoはまだです。

手順2.3ではSDカードとEthernetの線(2本)が加わります。mmRISC-2は自身のボードで、これらを含めて50 MHzで動いていました。

**次**: もう一度Vivado、その後15節のとおりボードで確かめます。

## 17. 手順2.2の2回目の実行: 達成(2026-11-26)

使う割り込み線だけを乗せ換えるようにした結果(16節)、著者のVivadoの実行で**タイミングを満たしました**。クリティカル警告はありません。

| クロック | セットアップWNS | ホールドWHS |
| --- | --- | --- |
| sys(`main_crg_clkout0`、100 MHz) | **+0.256 ns**(設計全体の最悪) | +0.068 ns |
| CPU(`main_basesoc_clkout`、50 MHz) | +0.622 ns | +0.055 ns |
| sys → CPU / CPU → sys | +5.877 / +6.685 ns | +0.051 / +0.025 ns |
| IDELAYCTRL(200 MHz) / clk100 | +1.215 / +8.578 ns | |

LUT 46,315(1回目48,085、手順2.1 45,954)、フリップフロップ26,740、BRAMタイル94.5、DSP 32、0.904 W。PLICは1,371から**405 LUT**になりました。ビットストリームは`LitexSystem/build/gateware/digilent_nexys_video.bit`です。

**次**: ボードで(15節): バナー、800 MT/sのDDR3、`mem_test 0x80000000 0x20000000`、`mem_speed`。

## 18. 手順2.2をボードで: CPU 50 MHzからDDR3-800の512 MiB全体、手順2.2完了(2026-11-26)

著者が17節のビットストリームを書き込み、UARTでBIOSを動かしました。

- バナー: `CPU: mmRISC-2 (RV64GC, CPU 50MHz) @ 100MHz`、`SDRAM: 512.0MiB 16-bit @ 800MT/s (CL-6 CWL-5)`。
- 800 MT/sでのリードレベリング: 両レーンともbitslip 2、m0は9 ± 7タップ、m1は8 ± 6タップ(bitslip 3も25 ± 6で通る)。
- BIOS自身の`Memtest OK`(2 MiB)。Memspeedは書き込み51.7 MiB/s、読み出し36.2 MiB/s。
- **`mem_test 0x80000000 0x20000000`: 512 MiB全体で`Memtest OK`。手順2.2のゲートです。**
- `mem_speed 0x80000000 0x1000000`(16 MiB): 書き込み54.3 MiB/s、読み出し36.3 MiB/s。
- このSoCにはSDカードもEthernetもないので、`No boot medium found`のあと`litex>`。

速度は手順2.1(DDR3-400、全体50 MHzで52.6 / 38.9 MiB/s)とほぼ同じです。BIOSのループは50 MHzのCPUで律速され、乗せ換えがミスごとに数サイクルを足します(読み出し−7 %)。DDR3は手順2.0と同じく、JEDECの範囲内(DDR3-800)で動いています。

**手順2.2完了。** 次は手順2.3: このSoCにmicroSDカード(J3)とEthernet(RGMII、RTL8211E)を加えます。ゲートはSDカードからのBIOSの起動とTFTPです。

## 19. 手順2.3: mmRISC-2のSoCにSDカードとEthernet、生成(2026-11-26)

**内容**(`Doc/STRATEGY_J.md` 2.3): 手順2.2のSoC(LiteX 100 MHz、CPU 50 MHz、乗せ換え経由)にmicroSDのスロットJ3とEthernet(RGMII、RTL8211E)を加えます。ゲートは、BIOSがSDカードから起動することと、DHCPでのTFTPです。

**`scripts/build_soc.sh`**: `--with-sdcard --with-ethernet --eth-dhcp --remote-ip ${REMOTE_IP:-192.168.0.42}`。SDカードの出力レジスタをI/Oブロックに置きます(`build_stock.sh`とmmRISC-2のXDCの行)。

**`scripts/nexys_video_target.py`**: LiteXのNexys Videoのターゲットにない`--eth-dhcp`を加えました(`Doc/BOARD_J.md` 2)。コマンドラインから取り除き、`add_ethernet`を`with_dhcp=True`、固定のIPなしで作らせます。Artyのターゲットと同じです(`--eth-dynamic-ip`だけでは、ターゲットの既定の`eth_ip`のために失敗します)。SDカードのPHYは引き続きカードのリセットなしです(10節)。

**生成したSoC**:

- 割り込み: uart 0、timer0 1、**ethmac 2、sdcard 3**。Verilogで`ext_irq[0]`から`[3]`はそれぞれ自身の`MultiReg`から、`[4]`から`[30]`は0(16節の規則。PLICの木は2ソースから4ソースに)。
- `ETH_WITH_DHCP`、`ETH_DYNAMIC_IP`、`ETH_UDP_BROADCAST`。`REMOTEIP`は192.168.0.42。LiteEthのパケットバッファは0x3000_0000(8 KiB、mmRISC-2のマップ)で、CPUの周辺バスから届きます。RGMIIのPHYは1 Gb/sだけで動きます(125 MHzのクロック、`eth_clocks_rx` 8 ns)。つまり動くリンクは1 Gb/sのリンクです。
- SDカードの2つのDMAマスタ(`sdcard_block2mem`、`sdcard_mem2block`)はCPUのDMAバスに、sys → CPUの乗せ換えを通ります(`CONFIG_CPU_HAS_DMA_BUS`)。
- BIOSは48.5 KiB(128 KiB中)。

**mmRISC-2のマップ用のデモ**: `build_demo.sh LitexSystem/build mm2`(名前を付けると、TFTPサーバの`<name>/demo.bin`のための`<name>.json`を作ります。サーバの`demo.bin`はVexRiscvのもの): `LitexSystem/build/demo/demo.bin`(RV64、0x8000_0000)、カード用の`boot.json`、`netboot mm2.json`用の`mm2.json`。

手順2.2のビットストリームは`LitexSystem/build/digilent_nexys_video_step22.bit`として残しました。

**次**: Vivado。その後ボードで: BIOSでのDHCPのアドレス、`netboot mm2.json`(サーバの`mm2/`にデモ)、デモの`demo.bin`と`boot.json`を入れたカード(Macから書き込む)、`sdcardboot`とBIOS自身のカードからの起動。

## 20. 手順2.3のVivadoの実行: 達成(2026-11-26)

著者が19節のSoCを実行し、**タイミングを満たしました**。

| クロック | セットアップWNS | ホールドWHS |
| --- | --- | --- |
| CPU(50 MHz) | **+0.117 ns**(設計全体の最悪) | +0.055 ns |
| sys(100 MHz) | +0.455 ns | +0.059 ns |
| sys → CPU / CPU → sys | +5.715 / +6.558 ns | +0.045 / +0.017 ns |
| Ethernet RX / TX(125 MHz) | +1.262 / +0.851 ns | +0.096 / +0.117 ns |
| IDELAYCTRL(200 MHz) / clk100 | +1.215 / +8.135 ns | |

最悪のパスはCPUの中のアドレス変換(`ma_size` → `mr_paddr`、20段)で、PLICではありません。4ソースのPLICは452 LUT(2ソースで405)。LUT 48,995(手順2.2: 46,315)、フリップフロップ29,000、BRAMタイル108.5(94.5。LiteEthのバッファとSDカードのFIFO)、1.112 W。2つのクリティカル警告はLiteX自身のもの(ネット`eth_rx_clk` / `eth_tx_clk`への`create_clock`。合成中はネットが未知、手順2.0の実行と同じ)。どちらのクロックも実装では時間解析されています(上の表)。

**次**: ボードで: DHCP、`netboot mm2.json`、SDカード。

## 21. 手順2.3をボードで: DHCPでのTFTPとSDカードからの起動、手順2.3完了(2026-11-26)

著者が20節のビットストリームを書き込み、UARTでBIOSを動かしました。

- バナーは手順2.2と同じ。`Ethernet init...`、`Local IP: 192.168.1.50`(LiteXの既定値。BIOSは起動シーケンスのネットワークの段階でだけDHCPを使います。下記)。DDR3-800のキャリブレーションが通る(両レーンともbitslip 2、9 ± 7タップ)。
- **TFTP**: `litex>`で`netboot mm2.json`は最初失敗しました(`Network boot failed.`、192.168.1.50のままでサーバのネットワークにいない)。**`eth_dhcp`: `Local IP: 192.168.0.10`**。そのあと`netboot mm2.json`: `Copying mm2/demo.bin to 0x80000000... (5784 bytes)`、`Liftoff!`、デモのプロンプト。RGMIIのPHYは1 Gb/sだけで動くので、このリンクは1 Gb/sです。
- **SDカード**(デモの`demo.bin`と`boot.json`をMacから書き込み): `sdcard_init` OK、**`sdcardboot`**: `Copying demo.bin to 0x80000000 (5784 bytes)`、`Liftoff!`、デモのプロンプト。
- **リセット後に何も押さないと**: シリアルブートの`Timeout`のあと`Booting from SDCard in SD-Mode...`、同じロードと`Liftoff!`: **BIOSが自分でカードから起動します**。

**DHCPが動く所**: LiteXのBIOSが`dhcp_get_ip()`を呼ぶのは、ネットワークブートの方法の中(と`eth_dhcp`コマンド)だけです。Ethernetの初期化では呼ばず、`netboot`コマンドも呼びません。QかESCは起動シーケンスをシリアルブートの段階で、ネットワークの段階の前に止めるので、`litex>`では`eth_dhcp`までアドレスはLiteXの既定値です。そのため`litex>`での順番は`eth_dhcp`、次に`netboot <json>`です(ArtyでのmmRISC-2の記録も同じ)。Qを押さずカードもなければ、BIOSは自分でDHCPを使い、サーバの`boot.json`をnetbootします。

**未解決の観察**: 起動時のBIOS自身のMemspeedは書き込み35.0 MiB/s、読み出し36.2 MiB/s(手順2.2: 51.7 / 36.2)。CPU、乗せ換え、DDR3は同じで、加わったのはLiteEthとSDカードだけなのに、書き込みが約3分の1低くなっています。ここでは調べていません。手順2.5で乗せ換え経由のDRAMのレイテンシを測ります。

**手順2.3完了**: ゲートを通過しました(BIOSがSDカードから起動、DHCPでTFTP)。次は手順2.4: JAのJTAG / cJTAG、スイッチとLED(`Doc/BOARD_J.md` 7、8)。

## 22. BIOSのMemspeedの書き込み51.7 → 35.0 MiB/s: DRAMではなくROMからのキャッシュしないフェッチ(2026-11-26)

**疑問**(21節): BIOSのMemspeedの書き込みが51.7 MiB/s(手順2.2)から35.0 MiB/s(手順2.3)に下がり、読み出しは36.2 MiB/sのままでした。CPU、乗せ換え、DDR3は同じです。

**mmRISC-2がLiteXのROMをどう扱うか**: `MEM_BASE`(0x8000_0000)より下はキャッシュしません。I$はそこから、アレイを使わずに周辺バス(AXI4-Lite)で64ビットずつフェッチします(mmRISC-2の`ICACHE.sv`、`CPU_CACHE_SPEC_J.md` 4: 「LiteXのROMを動かすため」)。BIOSは0x1000_0000のROMから動くので、ループの8バイトのワードごとに、CPU → sysの乗せ換え、`AXILite2Wishbone`、ROMを通るキャッシュしない読み出しが毎回起きます。

**2つのBIOSのビルド**(比較のため手順2.2のものを生成し直した): `memspeed`は同じコードで、置かれた場所だけが違います(0x1000_2BC8 / 0x1000_4320。LiteEthとSDカードでBIOSが大きくなった)。そのループ(8バイトのアクセス4つ、`addi`、分岐。16バイト)がまたがる範囲:

| ループ | 手順2.2 | ワード | 手順2.3 | ワード | 速度 2.2 → 2.3(MiB/s) |
| --- | --- | --- | --- | --- | --- |
| 書き込み | 0x…2C68–0x…2C77 | **2** | 0x…43AE–0x…43BD | **3** | 51.7 → 35.0 |
| 読み出し | 0x…2D12–0x…2D21 | 3 | 0x…4446–0x…4455 | 3 | 36.2 → 36.2 |

速度はメモリではなく、フェッチするワードの数に従っています。手順2.3の書き込みループはハーフワード(0x…AE)から始まり、手順2.2では2ワードだったところが3ワードにまたがります。51.7 / 35.0 = 1.48で、3 / 2に対応します。3ワードのループは書き込みでも読み出しでも約36 MiB/sです。1回32バイトを36.2 MiB/sで回すと42 CPUサイクルで、乗せ換えを通したROMからのキャッシュしないフェッチ1回が**約14 CPUサイクル(28 sysサイクル)**です。DRAMの分はその下に隠れています。

**結論**: ハードウェアは何も遅くなっていません。このCPUでのBIOSのMemspeedは、DDR3ではなくROMからの命令フェッチを測っていて、リンカがループを置く場所で変わります。DRAM自身のスループットとレイテンシには、メインRAMからI$で動くプログラムが要ります(手順2.5: 乗せ換え経由のDRAMのレイテンシ)。この節のためにボードでは測っていません。原因は2つのビルドのコードと、18節と21節の速度から読み取ったものです。

## 23. 手順2.4: Pmod JAのデバッグポート、スイッチとLED、生成(2026-11-26)

**内容**(`Doc/STRATEGY_J.md` 2.4、`Doc/BOARD_J.md` 7、8): mmRISC-2のJTAG / cJTAGのデバッグポートを、Artyと同じくNexys VideoのPmod JAに出します。ゲートは、4つの組み合わせ(JTAG / cJTAG × 認証なし / あり)で`jtag_check.tcl`がPASSすることです。

**`cpu/mmrisc/core.py`**(`add_jtag`):

- Pmodの位置はどちらのボードでも同じ(LiteXのプラットフォームの`pmoda:0`から`pmoda:5`)なので、ケーブルとmmRISC-2のOpenOCDの設定は変わりません: JA1 TCK/TCKC AB22、JA2 TDI AB21、JA3 TDO AB20、JA4 TMS/TMSC AB18、JA7 nTRST Y21、JA8 nSRST AA21。LVCMOS33、バンク14(3.3 V、SDカードとUARTと同じ)、プルとキーパはArtyと同じ。
- 状態のLED: Artyでは従来どおり減光したRGB LED。プラットフォームに`rgb_led`がない場合(Nexys Video)は、**LD0 halted、LD1 running、LD2 dmactive、LD3 cJTAG online**(100 Ω、2.5 V、減光なし)。
- JTAGのクロック(TCK、TMSC、100 ns)はsysとだけ非同期にしていました。デバッグモジュールはCPU自身のクロックでコアとつながり、それはsysとは兄弟のMMCMの出力なので(手順2.2)、**`mmrisc`とも非同期**にしました(`set_clock_groups`)。

**`scripts/nexys_video_target.py`**:

- **スイッチとボタンはLVCMOS12**(Digilentのマスタ XDC。VADJはボードの抵抗で1.2 V、`SET_VADJ`はそのまま): プラットフォームのLVCMOS25では、上げたSW2 / SW3をLowと読みます(`Doc/BOARD_J.md` 10、懸念9)。`user_btn` 5(G4、DDR3の1.5 VバンクにあるCPU RESETのピン)はそのまま。
- **LEDチェイサーは残りのLEDに**: ターゲットの`request_all("user_led")`は番号0から順に要求するので、LD0-LD3がCPUのものになると1つも見つけられません。`request_remaining`でLD4-LD7を渡します(Verilogのポートは`user_led`、`user_led_1`から`_3`、V15、W16、W15、Y13)。

**`scripts/build_soc.sh`**: `--cpu-jtag pmoda`。**`scripts/jtag_check.tcl`**: mmRISC-2のものに、このSoCの識別子("LiteX SoC on Nexys Video ..."、Artyと同じ0x1200_2000)も受け付けるようにしたもの。mmRISC-2の設定(`mmRISC-2/FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg`、`ft2232h_cjtag.cfg`)で動かします。これらは外付けのFT2232Hを説明文字列("Dual RS232")で選び、ボード自身のUSB-JTAGは選びません。

**生成したSoCで**: CPU_TOPの`cjtag_en`は`user_sw3`(G22)、`dbg_auth_en`は`user_sw2`(G21)から、どちらもLVCMOS12。`rst_n = ~(mmrisc_rst | cpu_reset) & mmrisc_jtag_srst_n`、`rst_dbg_n = ~mmrisc_rst`。`user_led0`から`3`は`dbg_halted`、`dbg_running`、`dbg_dmactive`、`cjtag_online`から。LEDチェイサーはLD4-LD7。`jtag_tck`と`jtag_tmsc`は100 nsで、`sys_clk`、`mmrisc_clk`、お互いとのクロックグループ。両方に`CLOCK_DEDICATED_ROUTE FALSE`。手順2.3のビットストリームは`LitexSystem/build/digilent_nexys_video_step23.bit`として残しました。

**次**: Vivado。その後ボードで(FT2232HをArtyと同じくJAに配線、そのUSBをLinuxのVMへ。`LitexSystem/`から):

1. SW3下、SW2下: `openocd -f ../../mmRISC-2/FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg -f scripts/jtag_check.tcl`(`AUTH_KEY=none`でも)。BIOSが動いている間はLD1、停止中はLD0が点灯。
2. SW2上(OpenOCDを起動する前に): 同じく、設定が正しいキーを書き込む。間違ったキーが拒否されること(`AUTH_KEY=0x12345678`: `examination failed`)。
3. SW3上(LD3点灯): `ft2232h_cjtag.cfg`(4線 → 2線のアダプタ経由)、SW2下と上。

## 24. 手順2.4のVivadoの実行: 達成(2026-11-28)

著者が23節のSoCを実行し、**タイミングを満たしました**。

| クロック | セットアップWNS | ホールドWHS |
| --- | --- | --- |
| CPU(50 MHz) | **+0.129 ns**(設計全体の最悪) | +0.037 ns |
| sys(100 MHz) | +0.138 ns | +0.024 ns |
| sys → CPU / CPU → sys | +6.173 / +6.715 ns | +0.016 / **+0.007 ns**(最悪のホールド) |
| Ethernet RX / TX(125 MHz) | +0.729 / +0.267 ns | +0.070 / +0.156 ns |
| JTAG TCK / TMSC(10 MHz) | +40.861 / +96.600 ns | +0.117 / +0.816 ns |
| IDELAYCTRL(200 MHz) / clk100 | +1.215 / +8.594 ns | |

JTAGのクロックとsysやCPUのクロックの間のパスは、時間解析されていません(23節のクロックグループ)。TCKの+40.9 nsは半周期のパスです(TDOは立ち下がりエッジ)。`CLOCK_DEDICATED_ROUTE FALSE`は両方のJTAGのネットに効いています(TMSCのものはVivadoが親のネットに移す。INFO)。LUT 50,683(手順2.3: 48,995。デバッグモジュール、TAP、cJTAG)、フリップフロップ30,497、BRAMタイル108.5、1.072 W。2つのクリティカル警告は、20節と同じくLiteX自身のもの(合成中のネット`eth_rx_clk` / `eth_tx_clk`への`create_clock`)。

**次**: ボードで: 4つの組み合わせで`jtag_check.tcl`(23節)。

## 25. 手順2.4: nSRSTのないアダプタ用のOpenOCDとボードでの手順(2026-11-28)

**著者のアダプタにはnSRSTがありません。** mmRISC-2の設定はそれを駆動します: `ft2232h_jtag.cfg`は`reset_config trst_and_srst`でnSRSTはACBUS1(オープンドレイン)、`ft2232h_cjtag.cfg`は`reset_config srst_only`。

**ハードウェアに必要なこと**: ありません。JA8(AA21、nSRST)にはFPGAのプルアップがあるので(23節)、開放のままでCPUはリセットされません。JA7(nTRST)も同じで、OpenOCDはいずれにしてもTMSでTAPをリセットします。

**`openocd/nexys_jtag.cfg`、`openocd/nexys_cjtag.cfg`**(新規、このボード用): mmRISC-2の2つの設定を`reset_config none`にし、nSRSTの信号をなくしてACBUS1を入力のままにしたもの(4線のものはACBUS0のnTRSTを解除のHighで駆動したままなので、nTRSTのあるケーブルでも何も変わりません)。そのほかはmmRISC-2と同じ(FT2232Hは"Dual RS232"で選択、1 MHz、IDCODE 0x26D6D001、システムバスのアクセス、物理アドレス、鍵0xBEEFCAFEか`AUTH_KEY`)。OpenOCDの`reset` / `reset halt`は、デバッグモジュールの`ndmreset`でCPUをリセットします。mmRISC-2ではこれはnSRSTと同じくCPUだけをリセットします(mmRISC-2の`LitexSystem/docs/JTAG_J.md` 2)。`jtag_check.tcl`はリセットを使いません。どちらの設定も、FT2232HをつないだこのVMのriscv-openocdで読み込めました(スキャンはすべて1: ボードがまだ手順2.4のビットストリームでないか、未配線)。

**ボードでの手順**(`LitexSystem/`から。FT2232HはArtyと同じ配線でJAに、JA8は開放。BIOSが`litex>`か、デモが動いている状態で):

| ケース | スイッチ | コマンド | 期待 |
| --- | --- | --- | --- |
| 1 | SW3下、SW2下 | `openocd -f openocd/nexys_jtag.cfg -f scripts/jtag_check.tcl` | `JTAG CHECK RESULT : PASS` |
| 2 | SW3下、SW2上(OpenOCDの起動前に) | 同じ | PASS(設定が鍵を書く) |
| 2a | SW3下、SW2上 | `AUTH_KEY=0x12345678 openocd -f openocd/nexys_jtag.cfg` | `Debugger is not authenticated ... (dmstatus=0x3)`、`examination failed` |
| 3 | SW3上(LD3点灯)、SW2下 | `openocd -f openocd/nexys_cjtag.cfg -f scripts/jtag_check.tcl`(4線 → 2線のアダプタ経由) | PASS |
| 4 | SW3上、SW2上 | 同じ | PASS |

CPUが動いている間はLD1、停止中はLD0、デバッグモジュールが動作中はLD2が点灯します。OpenOCDは結果のあとも動き続けます(次のケースの前にCtrl-Cで終了)。任意、nSRSTなしで: `telnet localhost 4444`で`reset halt`を実行すると、CPUはBIOSの最初の命令の前で止まり(`ndmreset`経由)、`resume`でBIOSが再び動きます。

**デバッグ用のアダプタをつないだままの書き込み**(同日に追記): J12のFT2232H("Digilent USB Device")とデバッグポートの外付けFT2232H("Dual RS232")は同じ0403:6010で、`openFPGALoader -b nexysVideo`は最初に見つけたものを使います。`scripts/program_nexys_video.sh`は、sysfsの製品名でJ12を選び、そのUSBのバス番号とデバイス番号を渡すようにしました(`--busdev-num`)。FTDIのシリアル番号は使えません。libftdiが、シリアル番号を持たない外付けFT2232Hで止まるためです("unable to fetch serial number")。3つのFTDIデバイスをこのVMにつないだ状態で、J12経由の`--detect`がXC7A200T(IDCODE 0x3636093)を見つけます。

## 26. 手順2.4をボードで: 4つの組み合わせすべてでデバッグポート、手順2.4完了(2026-11-28)

著者がこのVMから24節のビットストリームを書き込み(`program_nexys_video.sh`、J12は名前で選択、25節)、FT2232HをJAにつなぎ、JA8(nSRST)を開放して、`openocd/nexys_jtag.cfg` / `nexys_cjtag.cfg`で25節のケースを実行しました。

| ケース | スイッチ | 結果 |
| --- | --- | --- |
| 1 | SW3下(JTAG)、SW2下 | **PASS** |
| 2 | SW3下、SW2上(認証) | **PASS** |
| 2a | SW3下、SW2上、間違った鍵 | 期待どおり拒否 |
| 3 | SW3上(cJTAG)、SW2下 | **PASS** |
| 4 | SW3上、SW2上 | **PASS** |

さらに`telnet localhost 4444`で手で: `reset halt`(`ndmreset`経由、nSRSTなし)、`resume`、`step`、`reg pc`が動作しました。

**手順2.4完了**: ゲートを通過しました(JTAG / cJTAG × 認証なし / ありの4つの組み合わせで`jtag_check.tcl`がPASS)。mmRISC-2のLiteXのSoCは、Artyと同じくNexys Videoで動いています(BIOS、DDR3-800の512 MiB、SDカード、DHCPとTFTPのEthernet、デバッグポート)。LiteXは100 MHz、CPUは50 MHzで乗せ換え経由です。次は手順2.5: 立ち上げの記録と、乗せ換え経由のDRAMのレイテンシの測定(メインRAMのプログラムで、22節)、その結果をシミュレーションのメモリモデルに反映。
