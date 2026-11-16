# mmRISC-3

[English](README.md)

> **Claude Code による設計。** [mmRISC-2](https://github.com/munetomo-maruyama/mmRISC-2) と同様に、仕様書、RTL、検証、
> スクリプト、日英の文書は Anthropic の AI コーディングエージェント [Claude Code](https://claude.com/claude-code) が書く。
> 作者は目標を決め、Claude Code が出した案から選び、Vivado と実機を動かす。

mmRISC-2 の後継。**4 発行のアウトオブオーダ 64bit RISC-V CPU(RV64GC)** を SystemVerilog で自作し、**Digilent Nexys Video
(XC7A200T-1SBG484C、50 MHz)** で、microSD スロット J3 から Linux(BusyBox、Debian 13)を起動する。Ethernet(RTL8211E)と
Pmod JA の JTAG / cJTAG も使う。周辺回路は LiteX から持ってきて、mmRISC-2 の資産(キャッシュ、MMU、CSR、デバッグ、FPU、
検証環境)を流用する。

## 目標

最優先は **CoreMark の性能**:

| ビルド | 目標 | mmRISC-2 Rev.02(実機) |
|---|---|---|
| `-O2` | **できる限り高い CoreMark/MHz、クロックにはこだわらない**。CPU は 50 MHz(作業上の目標は RTL で 8.0、実機で 7.8) | 50 MHz で 2.794 |

実機の Linux 上で、Linux を動かすのと同じビットストリームで測る。

## 現状(2026-11-15)

**4 命令幅のコアが Spike とのロックステップで動き、単体合成で 50 MHz を満たす。** `OOO_CPU`(`RTL/CPU/OOO`)がキャッシュ込みのコアで、
仕様は [`Doc/UARCH_J.md`](Doc/UARCH_J.md) の A 章:

| 項目 | 作ったもの |
|---|---|
| コア | アウトオブオーダ、フェッチ 32 バイト、デコード / リネーム / ディスパッチ / コミット 4、**6 発行**(ALU 4 + ロード / ストアポート 2)、ROB 48、発行キュー 24(統合)、LQ / SQ 16、物理レジスタ 80、チェックポイント 12、ロードユース 2、ストア分割 |
| 予測 | uBTB 96、32 バイトのブロックごとの TAGE-M、BTB 256、RAS 16、FTQ 32 |
| キャッシュ | I$ 128 KB と D$ 128 KB(どちらも 8 ウェイ。D$ はライトバック、ロードポート 2)、L2 512 KB |
| 今の ISA | RV64IMAC + Zba / Zbb / Zbc / Zbs / Zicond / Zicsr / Zifencei / Zicntr、M / S / U モード |
| CoreMark/MHz | **8.244**(`-O2`、計測区間、実機のメモリのレイテンシで。作業上の目標 8.0 を満たす) |
| 資源、タイミング | LUT 80,345(60 %)、ブロック RAM タイル 284.5(78 %)。20 ns で WNS +0.027 ns(割り込み込み、手順1.8 I2、2026-11-16) |

**次は手順 1.8**: 割り込み、MMU(Sv39)、FPU、デバッグ、PMU、そしてシミュレーションで Linux(関門 S1-C)。その後 LiteX でボードへ
(手順 2)、その上で Linux(手順 3)。作業の順序は [`Doc/STRATEGY_J.md`](Doc/STRATEGY_J.md) 5 章、ここまでの手順は
[`Plan/OOC_J.md`](Plan/OOC_J.md) 29 にある。

途中の経緯: 対象を Arty A7-100T から Nexys Video に変え(2026-11-02)、100 MHz をやめて 50 MHz で幅を広げた(2026-11-05)。

## 文書

| ファイル | 内容 |
|---|---|
| [`Doc/STRATEGY_J.md`](Doc/STRATEGY_J.md) / [英語版](Doc/STRATEGY.md) | **ここから読む**: 目標、資源、選んだマイクロアーキテクチャと作ったもの、作業の順序、リスク |
| [`Doc/BOARD_J.md`](Doc/BOARD_J.md) / [英語版](Doc/BOARD.md) | Nexys Video: DDR3、microSD、Ethernet、JTAG、スイッチと LED、発注前の懸念点 |
| [`Doc/UARCH_J.md`](Doc/UARCH_J.md) / [英語版](Doc/UARCH.md) | マイクロアーキテクチャ仕様書: **A 章が作った `OOO_CPU`**。0〜9 章は 2 命令幅のコアの G0 の仕様で履歴 |
| [`Doc/PROMPT_J.md`](Doc/PROMPT_J.md) / [英語版](Doc/PROMPT.md) | 作者が Claude Code に入力したプロンプトと、Claude Code の回答の全記録(日時つき。日本語の原文とその翻訳) |
| [`Plan/`](Plan/README_J.md) | 検討と作業ファイル: 性能モデル、コアの立ち上げ([`Plan/CORE_J.md`](Plan/CORE_J.md))、Vivado の実行([`Plan/OOC_J.md`](Plan/OOC_J.md))、履歴としての Arty 向け戦略([`Plan/STRATEGY_A100T_J.md`](Plan/STRATEGY_A100T_J.md)) |

`Ref/`(他社のボードとデバイスの資料)は手元に置き、リポジトリには入れない。

## ブランチ

- `main`: リリース版のみ
- `dev`: 開発

## ライセンス

Apache License 2.0([`LICENSE`](LICENSE) と [`NOTICE`](NOTICE) を参照)。
