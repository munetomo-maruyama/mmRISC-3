# mmRISC-3

[English](README.md)

> **Claude Code による設計。** [mmRISC-2](https://github.com/munetomo-maruyama/mmRISC-2) と同様に、仕様書、RTL、検証、
> スクリプト、日英の文書は Anthropic の AI コーディングエージェント [Claude Code](https://claude.com/claude-code) が書く。
> 作者は目標を決め、Claude Code が出した案から選び、Vivado と実機を動かす。

mmRISC-2 の後継。**アウトオブオーダの 64bit RISC-V CPU(RV64GC)** を SystemVerilog で自作し、**Digilent Nexys Video
(XC7A200T-1SBG484C、50 MHz)** で、microSD スロット J3 から Linux(BusyBox、Debian 13)を起動する。Ethernet(RTL8211E)と
Pmod JA の JTAG / cJTAG も使う。周辺回路は LiteX から持ってきて、mmRISC-2 の資産(キャッシュ、MMU、CSR、デバッグ、FPU、
検証環境)を流用する。

## 目標

最優先は **CoreMark の性能**:

| ビルド | 目標 | mmRISC-2 Rev.02(実機) |
|---|---|---|
| `-O2` | **6.0 CoreMark/MHz を余裕をもって超える**(作業上の目標は RTL で 6.5、実機で 6.2) | 2.794 |

実機の Linux 上、50 MHz で、Linux を動かすのと同じビットストリームで測る。

## 現状(2026-11-02)

**対象を Arty A7-100T から Nexys Video に変えた**(作者の決定、2026-11-02): 小さなデバイスに入れるための削減が性能を削っていた。
2 命令幅のコアが `RTL/CPU/OOO` にある: riscv-arch-test と CoreMark を Spike とのロックステップで通し(`-O2` で 5.50 CoreMark/MHz)、
XC7A100T の単体合成で 50 MHz を満たす。次は **3 命令幅**: モデルで 7.17、アウトオブオーダの部分は約 44k LUT、新しいデバイスの約 62 %。
作業の順序は [`Doc/STRATEGY_J.md`](Doc/STRATEGY_J.md) 5 章: コア、ボード(まず mmRISC-2 で立ち上げる)、Linux。

## 文書

| ファイル | 内容 |
|---|---|
| [`Doc/STRATEGY_J.md`](Doc/STRATEGY_J.md) / [英語版](Doc/STRATEGY.md) | **ここから読む**: 目標、資源、提案するマイクロアーキテクチャ、作業の順序、リスク |
| [`Doc/BOARD_J.md`](Doc/BOARD_J.md) / [英語版](Doc/BOARD.md) | Nexys Video: DDR3、microSD、Ethernet、JTAG、スイッチと LED、発注前の懸念点 |
| [`Doc/UARCH_J.md`](Doc/UARCH_J.md) / [英語版](Doc/UARCH.md) | マイクロアーキテクチャ仕様書: 0 章が改訂。ほかは今の RTL である 2 命令幅のコア |
| [`Doc/PROMPT_J.md`](Doc/PROMPT_J.md) / [英語版](Doc/PROMPT.md) | 作者が Claude Code に入力したプロンプトと、Claude Code の回答の全記録(日時つき。日本語の原文とその翻訳) |
| [`Plan/`](Plan/README_J.md) | 検討と作業ファイル: 性能モデル、コアの立ち上げ([`Plan/CORE_J.md`](Plan/CORE_J.md))、Vivado の実行([`Plan/OOC_J.md`](Plan/OOC_J.md))、履歴としての Arty 向け戦略([`Plan/STRATEGY_A100T_J.md`](Plan/STRATEGY_A100T_J.md)) |

`Ref/`(他社のボードとデバイスの資料)は手元に置き、リポジトリには入れない。

## ブランチ

- `main`: リリース版のみ
- `dev`: 開発

## ライセンス

Apache License 2.0([`LICENSE`](LICENSE) と [`NOTICE`](NOTICE) を参照)。
