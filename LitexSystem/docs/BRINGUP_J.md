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
