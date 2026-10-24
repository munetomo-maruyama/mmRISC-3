# Plan

[English](README.md)

mmRISC-3の事前検討(`Doc/STRATEGY_J.md`のPhase 0)。RTLより先に行う性能評価の作業ファイルと文書を置く。

| 文書 | 内容 |
|---|---|
| [`MODEL_J.md`](MODEL_J.md) / [英語版](MODEL.md) | Phase 0-3: トレース駆動のC++サイクルモデル。(1) 枠組みとmmRISC-2による校正(5点で±0.3%以内)、(2) OoO 2幅: 融合なしで6.07 / 6.57、融合込みで7.06 / 7.59 CoreMark/MHz |
| [`PRESTUDY_MMRISC2_J.md`](PRESTUDY_MMRISC2_J.md) / [英語版](PRESTUDY_MMRISC2.md) | mmRISC-2開発時の事前検討メモ(2026-10-13): Arty A7-100TでのOoO RV64GC。資源、NaxRiscv、Linuxと非投機化、妥協案 |
| [`ICOUNT_J.md`](ICOUNT_J.md) / [英語版](ICOUNT.md) | Phase 0-1: CoreMark 1回あたりの命令数(コンパイラ・オプション・拡張命令別)と、目標に必要なIPC |
| [`ISSUES_J.md`](ISSUES_J.md) / [英語版](ISSUES.md) | G0までの残りの検討項目(課題と対策)、mmRISC-2 Rev.02の資源の実測と予算の見直し、作者が決めること |
| [`REDUCE_J.md`](REDUCE_J.md) / [英語版](REDUCE.md) | 論理規模の削減案(トリガ、PMP、D$バッファ / TLB / CSRのLUTRAM化、PMU、Zbc、FPU、LiteX)。mmRISC-2のRTLをYosysで合成して削減量を実測 |
| [`TRACE_J.md`](TRACE_J.md) / [英語版](TRACE.md) | Phase 0-2: CoreMarkのトレース解析。命令ミックス、分岐予測器(mmRISC-2のgshare、TAGE)、SFBと融合の候補、校正前の限界モデル |

| ディレクトリ | 内容 |
|---|---|
| `icount/` | `icount.sh`(CoreMarkをビルドしてSpikeで数える)、`port/`(ベアメタルのポート)、`results/icount.csv`。`work/`は出力で、リポジトリには入れない |
| `trace/` | `trace.sh`(ビルド、Spikeでのトレース、解析)、`capture.py`(Spikeのログから計測区間を切り出す)、`analyze.py`(すべての解析と限界モデル)、`results/`(`<build>.json`、`<build>.limit.txt`)。`work/`は入れない |
| `model/` | `mktrace.py`(トレース → 32バイトのレコード)、`model.h`、`pred_mm2.h`、`inorder.h`、`tage.h`、`ooo.h`、`model.cpp`、`calib.sh`、`sweep.sh`、`results/`(`calib.txt`、`sweep.txt`)。`work/`(実行ファイル、トレース)は入れない |
| `reduce/` | `synth.sh`(mmRISC-2のモジュールをパラメータを変えて、sv2v + YosysでArtix-7向けに合成)、`deps.py`、`sweep.sh`、`results/sweep.txt`。`work/`は入れない |

## リポジトリ外のツール

| ツール | 場所 | 作り方 |
|---|---|---|
| Spike 1.1.1-dev | `~/RISCV/toolchain/spike-install/bin/spike` | `~/RISCV/toolchain/riscv-gnu-toolchain/spike`を`configure --without-boost --without-boost-asio --without-boost-regex`し、`~/RISCV/toolchain/spike-build2`でビルド |
| GCC 14.2(Debian 13) | `~/RISCV/toolchain/debian13-rootfs` | `~/mmlitex_build/debian-riscv64.tar`(mmRISC-2のDebianルートfs)を展開。`unshare -r chroot`とqemu-userで実行 |
