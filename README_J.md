# mmRISC-3

[English](README.md)

> **Claude Code による設計。** [mmRISC-2](https://github.com/munetomo-maruyama/mmRISC-2) と同様に、仕様書、RTL、検証、
> スクリプト、日英の文書は Anthropic の AI コーディングエージェント [Claude Code](https://claude.com/claude-code) が書く。
> 作者は目標を決め、Claude Code が出した案から選び、Vivado と実機を動かす。

mmRISC-2 の後継。**2 命令幅のアウトオブオーダ 64bit RISC-V CPU(RV64GC)** を SystemVerilog で自作し、Digilent
Arty A7-100T(50 MHz)で Linux(BusyBox、Debian 13)を動かす。周辺回路は LiteX から持ってきて、mmRISC-2 の資産
(キャッシュ、MMU、CSR、デバッグ、FPU、検証環境)を流用する。

## 目標

最優先は **CoreMark の性能**:

| ビルド | 目標 | mmRISC-2 Rev.02(実機) |
|---|---|---|
| `-O2` | **5.0 CoreMark/MHz** 以上 | 2.794 |
| 最大最適化 | **6.0 CoreMark/MHz** 以上 | 3.034 |

実機の Linux 上、50 MHz で、Linux を動かすのと同じビットストリームで測る。

## 現状(2026-10-23)

**Phase 0: 戦略。** RTL はまだない。戦略は [`Doc/STRATEGY_J.md`](Doc/STRATEGY_J.md) にある: 目標の命令数 × IPC への
分解、CPI の予算、Arty の LUT 予算、RTL より先に作るトレース駆動の性能モデル、フェーズとゲート。

## 文書

| ファイル | 内容 |
|---|---|
| [`Doc/STRATEGY_J.md`](Doc/STRATEGY_J.md) / [英語版](Doc/STRATEGY.md) | 開発戦略(CoreMark 先行) |
| [`Doc/mmRISC-OoO_検討メモ.md`](Doc/mmRISC-OoO_検討メモ.md) | Arty A7-100T での OoO RV64GC の事前検討 |
| [`Plan/`](Plan/README_J.md) | 性能評価の事前検討(Phase 0)と作業ファイル: [CoreMark の命令数](Plan/ICOUNT_J.md) |

## ブランチ

- `main`: リリース版のみ
- `dev`: 開発

## ライセンス

Apache License 2.0([`LICENSE`](LICENSE) と [`NOTICE`](NOTICE) を参照)。
