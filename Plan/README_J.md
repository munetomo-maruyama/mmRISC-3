# Plan

[English](README.md)

mmRISC-3の事前検討(`Doc/STRATEGY_J.md`のPhase 0)。RTLより先に行う性能評価の作業ファイルと文書を置く。

| 文書 | 内容 |
|---|---|
| [`ICOUNT_J.md`](ICOUNT_J.md) / [英語版](ICOUNT.md) | Phase 0-1: CoreMark 1回あたりの命令数(コンパイラ・オプション・拡張命令別)と、目標に必要なIPC |

| ディレクトリ | 内容 |
|---|---|
| `icount/` | `icount.sh`(CoreMarkをビルドしてSpikeで数える)、`port/`(ベアメタルのポート)、`results/icount.csv`。`work/`は出力で、リポジトリには入れない |

## リポジトリ外のツール

| ツール | 場所 | 作り方 |
|---|---|---|
| Spike 1.1.1-dev | `~/RISCV/toolchain/spike-install/bin/spike` | `~/RISCV/toolchain/riscv-gnu-toolchain/spike`を`configure --without-boost --without-boost-asio --without-boost-regex`し、`~/RISCV/toolchain/spike-build2`でビルド |
| GCC 14.2(Debian 13) | `~/RISCV/toolchain/debian13-rootfs` | `~/mmlitex_build/debian-riscv64.tar`(mmRISC-2のDebianルートfs)を展開。`unshare -r chroot`とqemu-userで実行 |
