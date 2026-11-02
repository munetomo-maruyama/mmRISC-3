# ボード: Digilent Nexys Video(XC7A200T-1SBG484C)

[English](BOARD.md)

- 日付: 2026-11-02。`Ref/`の資料(手元に置き、リポジトリには入れない)とLiteXのチェックアウトから書いた。**まだボードでは試していない**ので、`Doc/STRATEGY_J.md`のステップ2の計画である
- 再利用するもの: mmRISC-2の`LitexSystem`(`../mmRISC-2/LitexSystem`、読むだけ)。LiteX自身のNexys Video向けターゲットの上に作る

---

## 1. Arty A7-100Tから変わること

| 項目 | Arty A7-100T | **Nexys Video** | 意味 |
|---|---|---|---|
| FPGA | XC7A100T-1CSG324 | **XC7A200T-1SBG484** | `Doc/STRATEGY_J.md` 3 |
| 電源 | USB | **12 V、3 A以上(DCジャックJ21)。USBからは不可** | 10章 |
| DDR3 | 256 MiB、MT41K128M16 | **512 MiB**: MicronかZentelの4品種のどれか、16ビット、800 MT/s | 4章 |
| Ethernet | MII、100 Mb/s、DP83848 | **RGMII、1 Gb/s、RTL8211E-VL** | 6章 |
| microSD | Pmod(PMOD MicroSD) | **裏面のスロットJ3**、ボードのマイコンと共有 | 5章 |
| JTAG / cJTAG | Pmod JA | **Pmod JA、同じピン配置** | 7章 |
| スイッチ、LED | スイッチ4、LED 4 + RGB LED 4、3.3 V | **スイッチ8はVADJ(1.2 V)、LED 8は2.5 V** | 8章 |
| USB | 1つ、JTAGとUART | **2つ**: J12(書き込み)、J13(UART) | 9章 |
| クロック | 100 MHz | 100 MHz(R4) | 同じ |

---

## 2. LiteXにすでにあるもの

`litex-boards`にこのボードのターゲット(`digilent_nexys_video`)があり、mmRISC-2が使うチェックアウトにも入っている: ピン、`A7DDRPHY` + `MT41K256M16`、`LiteEthPHYRGMII`、`--with-sdcard`(LiteSDCard)。既定のシステムクロックは100 MHz。**ここで書くもの**: CPUのラッパー(`cpu/mmrisc/core.py`、プラットフォームの`pmoda`と`user_sw`についてはもともと汎用)、クロックドメイン(4章)、状態のLED、デバイスツリー、タイミング制約。

**LiteXのプラットフォームファイルをそのまま使わないもの2つ**: スイッチとボタンを`LVCMOS25`にしているが、ボードのVADJは設計が変えない限り1.2 V(8章)。ターゲットの`vadj`の代入は実際にはつながっていない。

---

## 3. クロック

| クロック | 周波数 | 用途 |
|---|---|---|
| ボードの発振器、ピンR4(MRCC、バンク34) | 100 MHz | MMCMの入力 |
| CPU、キャッシュ | **50 MHz** | 作者の決定 |
| LiteDRAM | **100 MHz**(PHY用に400 MHzと90°の400 MHz) | 4章 |
| 周辺(CSR、UART、SD、LiteEthのバス側) | 50か100 MHz | 2.2で決める |
| IDELAYCTRL | 200 MHz | DDR3とRGMIIの受信の遅延 |
| RGMIIの送信 | 125 MHz、位相2 ns | PHYの受信クロックを入力とするPLL(6章) |

---

## 4. DDR3

**新しいボードで直さざるをえない唯一の点。** ArtyではLiteDRAMがシステムクロックの4:1で動くので、50 MHzは**200 MHz、DDR3-400で、JEDECの下限303 MHzより低い**(`LitexSystem/docs/TIMING_J.md`)。これはArtyのMicronの部品では動いた。Nexys Videoには**MT41K256M16HA-187E、MT41K256M16TW-107、Zentel A3T4GF40ABF-GML、Zentel A3T4GF40BBF-HP**のどれかが載り、同じやり方がそのすべて、また次に買うボードで動くとは約束できない。

| 案 | 内容 | 利点 | 欠点 |
|---|---|---|---|
| **A(おすすめ)** | LiteDRAMを100 MHz、マニュアルの表どおりDDR3-800。CPUのメモリポートで50 MHzへ乗り換える | 全部品でJEDECの範囲内。帯域2倍。CPUサイクルで見たDRAMの遅延が減る | メモリポートのクロック乗り換え。LiteDRAMのドメインをLiteXの`sys`から分ける必要 |
| B | LiteX全体を100 MHz(このボードの既定)、CPUだけ50 MHz | LiteXの構造の変更が一番少ない | すべての周辺が100 MHz、すべてのCSRアクセスが乗り換えを通る |
| C | LiteDRAMの代わりにMIG(UG586)、AXIは100 MHz | Xilinxがサポートする流れ | 論理が増え、IPの流れ、BIOSの初期化が新しくなる。Aより得がない。**代替案としてだけ** |
| D | ArtyのようにDDR3-400 | 作業なし | JEDECの範囲外。試すだけなら |

ほかの点: 0x8000_0000〜0x9FFF_FFFFの512 MiBはmmRISC-2のメモリマップで空いている(`MEMMAP_J.md` 3章)。バンク35は1.5 V。ボードのクロックピンは隣のバンク34で、LiteXのターゲットもそれを前提にしている。CPU_L2とデバイスツリーは新しい大きさにする。

---

## 5. J3のmicroSD

| 項目 | 事実 | すること |
|---|---|---|
| 共有 | ボードのPIC24がFPGAのコンフィグまでカードを読み、そのあと**スロットの電源を切って**バスを離す | 設計が電源を入れる |
| `SD_RESET`(V20) | スロットの電源を入れるには**FPGAがLowに駆動する必要がある** | LiteSDCardがする: PHYが`pads.rst`(`card_reset`)を駆動し、初期化で扱う |
| バス | ネイティブ4ビット、CMD、CCLK、CD(T18)、バンク14、3.3 V | `--with-sdcard`のピンがある。3.3 Vのみ: UHSなし |
| クロック | システムクロック50 MHzで25 MHzまで。周辺を100 MHzにすればもっと | はじめはArtyと同じ |
| タイミング | mmRISC-2で、SDのピンにタイミング制約がなくビルドごとに動くことが分かった(`scripts/build_soc.sh`) | 新しいピンで制約を引き継ぐ |
| 位置 | **ボードの裏面** | 10章 |
| カードからのビットストリーム | JP4 = USB/SD、JP3 = SD: PIC24が**FAT32**のカードのルートの`.bit` 1つを読み込む | 任意。mmRISC-2の起動パーティションはFAT16(`LITEXBOOT`)。まずQSPIかJTAGで起動し、あとで決める |

---

## 6. Ethernet: RTL8211E-VL、RGMII

| 項目 | 事実 | すること |
|---|---|---|
| ピン | バンク13、**2.5 V**。`ETH_RST_B`だけバンク34、3.3 V(U7) | LiteXのプラットフォームのとおり |
| 遅延 | PHYは既定で足さない(`RXDLY`、`TXDLY`は抵抗で)。受信側でデータとクロックに1.0〜2.6 nsが必要 | **LiteEthのとおりFPGAで**: 受信は`IDELAYE2`、送信はPLLの位相2 ns。**ボードの改造なし** |
| 速度 | **LiteEthの`LiteEthPHYRGMII`は1 Gb/s専用**: 送信のPLLがPHYの受信クロックを125 MHzとして受ける。100 Mb/sのリンクではRXCが25 MHzになり、PLLの範囲外 | 10章。PHYは既定で10 / 100 / 1000を広告するので、**相手が1000BASE-Tである必要がある** |
| MACアドレス | I2C(W5、V5)の24AA025E48に固有の値がある | まず固定のアドレス(mmRISC-2と同じ)。必要ならあとでEEPROM |
| XilinxのTEMAC | ライセンスが必要 | 使わない |
| Linux | Artyと同じ`liteeth`ドライバ。PHYは管理せず、リンクは自動で上がる | 3.2で確かめる |
| 帯域 | バス側は50 MHz、32ビットで200 MB/s、線は125 MB/s | 足りる。Linuxで出るのはCPUのコピーの速さで、3.2で測る |

---

## 7. Pmod JAのJTAG / cJTAG

**Artyと同じコネクタの位置**なので、ケーブルとOpenOCDの設定は変わらない。`cpu/mmrisc/core.py`は`pmoda:0`〜`pmoda:5`を要求し、LiteXのプラットフォームがすでに対応づけている。

| Pmod JA | FPGAピン | 信号 | FPGA側 | このボードでの注意 |
|---|---|---|---|---|
| JA1 | AB22 | TCK / TCKC | プルアップ。汎用ピンのクロック | Artyと同じくJAにクロック対応ピンはない: `CLOCK_DEDICATED_ROUTE FALSE` |
| JA2 | AB21 | TDI | プルアップ | |
| JA3 | AB20 | TDO | プルアップ。シフト中だけ駆動 | コンフィグ時は`DOUT / CSO_B`: 出力なのでTDOに合う |
| JA4 | AB18 | TMS / TMSC | キーパ | 直列抵抗を通して双方向 |
| JA7 | Y21 | nTRST | プルアップ | |
| JA8 | AA21 | nSRST | プルアップ。CPUのリセット | |
| JA5 / JA11 | — | GND | | |

JAはシングルエンドの配線で、**直列抵抗200 Ω、10 MHz未満向け**(Table 9): TCKはこれまでどおり100 ns、10 MHzで制約する。JBとJCは0 Ωで差動の配線で、必要ない。このボードのJ17はFPGA自身のJTAG(外部プログラマ用)で、CPUのものではない。

---

## 8. スイッチ、LED、ボタン

mmRISC-2の使い方(`LitexSystem/docs/JTAG_J.md` 1章)を踏襲する。**I/O規格はDigilentのマスターXDCに従う**: スイッチとボタンは`LVCMOS12`(`SET_VADJ`と`VADJ_EN`を触らなければ、ボードのプル抵抗でVADJは1.2 V)、LEDは`LVCMOS25`、CPU RESETは`LVCMOS15`。

| ボード上 | ピン | 用途 | Artyでは |
|---|---|---|---|
| SW3 | G22 | 下: 4線JTAG。上: 2線cJTAG | 同じ |
| SW2 | G21 | 下: 認証なし。上: 認証あり | 同じ |
| SW0、SW1、SW4〜SW7 | E22、F21、H17、J16、K13、M17 | 空き(求めがあればLiteXの`user_sw`のCSR) | |
| LD0 | T14 | ハートが停止 | RGB LD0の赤 |
| LD1 | T15 | ハートが実行中 | RGB LD0の緑 |
| LD2 | T16 | dmactive | RGB LD1の青 |
| LD3 | U16 | cJTAGがオンライン(SW3が上) | RGB LD2の緑 |
| LD4〜LD7 | V15、W16、W15、Y13 | LiteXのLEDチェイサ | 同じ |
| CPU RESET(赤) | G4 | システムリセット、アクティブLow | リセットボタン |
| BTNC / U / D / L / R | B22、F15、D22、C22、D14 | 空き | |

ArtyのRGB LEDは明るすぎて1/16のデューティで点けていた。こちらは100 Ωつきで何もいらない。OLEDは使わない。

---

## 9. UART、書き込み、フラッシュ

| 項目 | 事実 |
|---|---|
| UART | J13のFT232R。ピンV18(PCから)とAA19(PCへ)、3.3 V、ハンドシェイクなし |
| 書き込み | J12のDigilent USB-JTAG。Artyと同じ種類のケーブル。非圧縮のビットストリームを30 MHzで約4秒 |
| ビットストリーム | 非圧縮で77,845,216ビット。圧縮が効く |
| フラッシュ | S25FL256S、32 MiB。ビットストリームは9 MiB強。ツールでは(マニュアルより)`s25fl256xxxxxx0` |
| モード | JP4でJTAG、QSPI、USB/SDを選ぶ |

---

## 10. 懸念点(発注前のものから)

| # | 懸念 | 重さ | すること |
|---|---|---|---|
| 1 | **納期。** 11週の販売店、工場リードタイム70週の販売店、在庫ありの販売店がある | **まず確認** | 国内の販売店に在庫を聞く。コアの作業は待たずに進むが、ステップ2、3は待つ |
| 2 | **電源。** 12 V、3 A以上、USB不可。販売店の記載は12 V 3Aの電源、USとEUのプラグつき | 確認 | 選ぶ販売店で同梱か、100 V対応かを確かめる |
| 3 | **Ethernetは相手に1000BASE-Tのポートが必要**(6章)。今の環境(Macへの経路、TFTPサーバ)を確かめる | 確認 | 小さなギガビットスイッチで解決する。10 / 100にはLiteEthに新しいPHY層が必要 |
| 4 | **DDR3の部品がいろいろ**(4章)。DDR3-400は安全でない | 設計 | 案A。手元のボードの部品で試し、どの部品かを読み取る |
| 5 | **microSDのスロットがボードの裏** | 実用 | カードの抜き差しはボードを持ち上げて。スペーサで余裕を。ArtyではSDの差し替えが日常だったが、BIOSからのTFTPで減らせる |
| 6 | **冷却。** 資料からヒートシンクの有無を確認できなかった。ファンのはんだ付け点はある | 確認 | 販売店に聞くか届いたら見る。XADCで温度が読める。最初の全体ビルドで`report_power` |
| 7 | **無料のVivado。** XC7A200TはVivado ML Standardに入っている(UG973) | 問題なし | ライセンスを買う必要なし。使っているのは2025.1 |
| 8 | **ビルドの時間とメモリ**: Windowsのx86エミュレーション、大きなデバイスと設計 | 実用 | `synth_ooo.bat OOO_CPU`は新しい品種になったので、**ボードが届く前に**試せる。ピークのメモリも見る |
| 9 | **VADJ**(8章): LiteXの`LVCMOS25`だとスイッチの1.2 VのHighをLowと読む | 設計 | `LVCMOS12`、`SET_VADJ`は触らない |
| 10 | **デバッグプローブのPmod**はピン配置が同じ。200 Ωも同じ。プローブは3.3 V | 問題なし | 買うものなし |
| 11 | **ArtyのPMOD MicroSDとEthernetは引き継がない** | 問題なし | J3とRJ-45に替わる。マニュアルはシールドケーブルを求めている |
| 12 | **速度グレード。** これまでと同じ-1: 論理は2倍だが、速くはない | 既知 | `Doc/STRATEGY_J.md` 8 |

1、2、7の出典は販売店のページとAMDのUG973(2026-11-02に確認)。価格と在庫は変わる。
