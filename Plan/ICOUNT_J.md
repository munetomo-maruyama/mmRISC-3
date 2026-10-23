# Phase 0-1: CoreMarkの命令数(コンパイラ・オプション・拡張命令別)

- 実施日: 2026-10-24
- 目的: 目標(`-O2`で5.0、最大最適化で6.0 CoreMark/MHz)に必要なIPCを、実測した命令数から決める(`Doc/STRATEGY_J.md` 1.1節と5.2節の手順1)
- 作業ファイル: `Plan/icount/`(`icount.sh`、`port/`、`results/icount.csv`)

---

## 1. 結論

1. **命令数が最も少ないのはGCC 14.2(Debian 13)+ Zicond**。1回あたりの命令数は`-O2`で**311,890**、最大最適化(sf + `-flto`)で**280,958**。mmRISC-2で測っていた条件(GCC 13.2、Zba/Zbb、`-O2`)の318,597と比べると、それぞれ−2.1%と−11.8%。
2. 必要IPCは次のように下がる。

| 目標 | 条件 | 1回あたり命令数 | 必要IPC |
|---|---|---|---|
| `-O2`で5.0/MHz | GCC 14.2、Zba/Zbb/Zbs/Zicond | 311,890 | **1.56**(従来見積り1.59) |
| `-O2`で6.0/MHz | 同上 | 311,890 | 1.87(2命令幅では狙わない) |
| 最大最適化で5.0/MHz | GCC 14.2、sf + `-flto`、同上 | 280,958 | 1.40 |
| 最大最適化で6.0/MHz | 同上 | 280,958 | **1.69**(従来見積り1.77) |

3. **Zicondはハードに入れる**(GCC 14で−1.5%。GCC 13以前は使わない)。Zbsはほぼ無関係(−0.1%)。Zba/Zbbは従来どおり−11〜13%で最大の効果。
4. **clang 18は命令数が19〜29%多い**ので、CoreMarkの測定には使わない。
5. **命令数が少ないことは、サイクル数が少ないことを意味しない**。展開とインライン化でコードは9KB → 34KBに増える(I$は16KB)。また、mmRISC-2ではGCC 13のsf + `-flto`の方がsfより遅かった(BENCH.md 17章)。最大最適化のオプションは、性能モデルとRTLのサイクル数で最終的に決める。

---

## 2. 方法

### 2.1 環境
| 項目 | 内容 |
|---|---|
| ISS | Spike 1.1.1-dev(riscv-gnu-toolchainに同梱のソース、2024-07-08版)を`~/RISCV/toolchain/spike-install`にビルド(Boostなし)。`--isa=rv64gc_zba_zbb_zbs_zicond` |
| CoreMark | `~/RISCV/Rocket/vivado-risc-v/bare-metal/coremark/coremark`(mmRISC-2と同じソース)、`PERFORMANCE_RUN=1`、`ITERATIONS=10` |
| ポート | mmRISC-2の`SIM/SIM_SYS/bench`のベアメタルポート(Cライブラリなし、Mモード)をSpike向けに変更: `fromhost`を追加、コンソール出力は前の1バイトの受け取りを待つ、tb_SYS用のプロファイル印を削除 |
| 計測 | 計測区間(`start_time`〜`stop_time`)の`minstret`の差 ÷ 回数 |
| 正しさ | 全ビルドでcrcfinalが0xfcaf(10回) |

### 2.2 コンパイラ
| 名前 | コンパイラ | 備考 |
|---|---|---|
| g12 | riscv64-unknown-elf-gcc 12.2.0(`/opt/riscv`) | |
| g13 | riscv64-unknown-elf-gcc 13.2.0(`/opt/riscv`) | mmRISC-2で使っていたもの |
| g13u | riscv64-linux-gnu-gcc 13.3.0(Ubuntu 24.04) | PIEとスタック保護を無効化(`-fno-pie -no-pie -fno-stack-protector`) |
| g14 | gcc 14.2.0(Debian 13 riscv64、ボード上のgccと同じ) | mmRISC-2のDebianルートfs(`~/mmlitex_build/debian-riscv64.tar`)を`~/RISCV/toolchain/debian13-rootfs`に展開し、`unshare -r chroot`とqemu-userで実行。g13uと同じく PIE / スタック保護を無効化 |
| c18 | clang 18(Ubuntu 24.04) | リンクはg13のドライバ |

### 2.3 オプションと拡張命令
| 名前 | オプション |
|---|---|
| o2 | `-O2` |
| o3 | `-O3` |
| sf | `-O3 -funroll-all-loops -finline-functions --param max-inline-insns-auto=20 -falign-functions=4 -falign-jumps=4 -falign-loops=4`(mmRISC-2の「最大最適化」、BENCH.md 17章)。clangは`-O3 -funroll-loops -finline-functions` |
| sflto | sf + `-flto` |
| sfx | sf + `-finline-limit=600 -fno-code-hoisting -fgcse-sm -fgcse-las -fipa-pta` |

| 名前 | `-march` |
|---|---|
| gc | `rv64imafdc_zicsr_zifencei` |
| zb | gc + `_zba_zbb` |
| zbs | zb + `_zbs` |
| zbsc | zbs + `_zicond` |

### 2.4 検証
- **mmRISC-2のSIM_SYSと一致**: GCC 13.2、`-O2`、Zba/Zbb、10回で、Spike 3,185,974命令に対してSIM_SYS(BENCH.md 13章)3,185,981命令。差は7命令(0.0002%)で、ポートの違い(プロファイル印の削除)の範囲。rv64gcも358,921 / 1回で一致。
- **回数に比例**: 20回で測ると318,610 / 1回(10回では318,597、差0.004%)。1回あたりの命令数は回数によらない。

---

## 3. 結果(1回あたりの命令数)

| コンパイラ | オプション | gc | zb | zbs | zbsc |
|---|---|---|---|---|---|
| g12 | o2 | 354,165 | 313,871 | 313,637 | 313,637 |
| g12 | o3 | 339,958 | 301,675 | 301,440 | 301,440 |
| g12 | sf | 332,019 | 292,934 | 292,699 | 292,699 |
| g12 | sflto | — | 316,372 | — | 316,133 |
| g12 | sfx | — | 297,822 | — | 297,589 |
| g13 | o2 | 358,921 | **318,597** | 318,362 | 318,362 |
| g13 | o3 | 344,134 | 303,672 | 303,437 | 303,437 |
| g13 | sf | 335,937 | 294,467 | 294,232 | 294,232 |
| g13 | sflto | — | 313,967 | — | 313,728 |
| g13 | sfx | — | 293,914 | — | 293,669 |
| g13u | o2 / o3 / sf | g13と全く同じ | | | |
| g14 | o2 | 359,036 | 316,979 | 316,562 | **311,890** |
| g14 | o3 | 344,149 | 301,971 | 301,553 | 296,881 |
| g14 | sf | 331,910 | 289,461 | 289,044 | 284,372 |
| g14 | sflto | — | 286,048 | — | **280,958** |
| g14 | sfx | — | 288,772 | — | 288,364 |
| c18 | o2 | 415,282 | 376,070 | 375,574 | 370,694 |
| c18 | o3 / sf | 410,991 | 371,779 | 371,283 | 366,403 |

太字: mmRISC-2の測定条件(g13 / o2 / zb)、および`-O2`と最大最適化それぞれの最少。全データは`Plan/icount/results/icount.csv`。

### 3.1 要因ごとの効果

| 要因 | 効果(命令数) |
|---|---|
| Zba/Zbb(gc → zb) | GCC −11.2〜−12.8%、clang −9.4% |
| Zbs(zb → zbs) | −0.07〜−0.14% |
| Zicond(zbs → zbsc) | GCC 14 −1.5〜−1.6%、clang −1.3%、GCC 12 / 13は変化なし |
| `-O3`(o2比) | −3.9〜−4.8% |
| sf(o2比) | GCC 12 −6.7%、GCC 13 −7.6%、GCC 14 −8.8% |
| `-flto`(sf比、zbsc) | GCC 14 −1.2%、GCC 13 +6.6%、GCC 12 +8.0% |
| clang 18(GCC 14比) | `-O2` +19%、sf +29% |
| コードサイズ(.text) | o2 約9KB、sf 約28〜33KB、GCC 14 sflto 約34KB |

---

## 4. ここから決めること(提案)

| 項目 | 提案 | 理由 |
|---|---|---|
| 測定用コンパイラ | **GCC 14.2(Debian 13)に固定** | 命令数が最少。ボード上のgccと同じで、ボード上でもホスト(qemu-user)でも同じバイナリを作れる |
| `-O2`の定義 | `-O2 -march=rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicond` | ハードが持つ拡張をすべて使う(`STRATEGY_J.md` 1.3節) |
| 最大最適化の候補 | sf + `-flto`(命令数最少)と sf(コードが小さい) | 最終的にはサイクル数で決める |
| Zicond | **ハードに入れる**(mmRISC-2も実装済み) | GCC 14で−1.5% |
| 性能モデルの入力 | g14 / o2 / zbsc と g14 / sflto / zbsc、比較用に g13 / o2 / zb(mmRISC-2での校正用) | |

注意: ボード上の測定はLinux上のposixポート(glibc、時間関数が異なる)なので、命令数はここと完全には一致しない。計測区間はCoreMark本体だけなので、差は小さいはず(mmRISC-2ではSIM_SYSとボードのCoreMark/MHzが一致していた)。

---

## 5. 次の作業

1. Spikeのコミットログから、上の3ビルドの**命令トレース**を取り、命令の種類別の頻度、分岐(taken率、前方の短い分岐=SFBの候補)、融合できる命令の組の出現率を数える。
2. そのトレースを入力にした**トレース駆動のサイクルモデル**を作り、mmRISC-2のインオーダー8段(CPI 1.103)で校正する。
3. GCC 15(手元にない)は、必要ならあとで追加する。
