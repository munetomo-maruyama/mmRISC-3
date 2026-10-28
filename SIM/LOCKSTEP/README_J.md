# SIM/LOCKSTEP: Spikeとのロックステップ比較

Phase 1の手順1(`Doc/UARCH_J.md` 8章)。mmRISC-3がコミットする命令を1つずつ、コアの最初のシミュレーションからSpikeと比べる。

| ファイル | 内容 |
|---|---|
| `lockstep.h` / `lockstep.cc` | 比較器: `Commit`レコードとクラス`Lockstep`(Spikeの`processor_t`を、専用のメモリの上でライブラリとして使う) |
| `selftest.cc` | コアなしでのテスト: もう1つのSpikeが正しいコアの命令列を作る。そのまま、融合した組の印つき、わざと壊したもの |
| `build.sh` | `~/RISCV/toolchain/spike-install`(Spike 1.1.1-dev。別のものは`SPIKE=`)に対して`obj/selftest`を作る |
| `run_selftest.sh` | riscv-testsとCoreMarkでの自己テスト → `results/selftest.txt` |

## テストベンチからの使い方

```c++
LockstepCfg cfg;  cfg.elf = "test.elf";   // コアが走らせるのと同じファイル
Lockstep ref(cfg);
// 毎サイクル、コミットしたµopごとに(融合した組はレコード2つ):
Commit c;  c.pc = ...;  c.insn = ...;  c.rd = ...;  c.rd_val = ...;  // ...
std::string why;
if (!ref.check(c, &why)) { printf("MISMATCH %s\n", why.c_str()); stop(); }
if (ref.exited()) finish(ref.exit_code());
```

`Commit`レコードは、コアのコミットトレースのポート(シミュレーションのみ。RVFI風)が、プログラム順に命令ごとに出すもの:

| フィールド | 意味 |
|---|---|
| `pc`、`insn` | 命令のアドレスとビット列(圧縮命令は下位16ビット) |
| `trap`、`cause` | リタイアしなかった: `pc`での例外と、その原因 |
| `rd`、`rd_fp`、`rd_val` | 書いたレジスタ(−1: なし。x0もなしと数える)、整数かFPか、その値 |
| `rd_skip` | 結果を書かない、融合した組の前半(組の書き込みは1本): `pc`と`insn`だけを比べる |
| `st`、`st_addr`、`st_data`、`st_size` | 行ったストア |

## コアとテストベンチが守る規則

- **HTIF**: 参照は`tohost`へのストアにすぐ応える(次の命令の前に`tohost`を0に戻す。終了: `tohost = code << 1 | 1`、文字: デバイス1、コマンド1)。コアのテストベンチ(`SIM/CORE`)は、ストアがストアキューとD$を通ってメモリに届いたときに応えるので、`tohost`をポーリングするループはコアのほうが多く回りうる。そこで**`tohost`と`fromhost`のロードはコアの値を使う**(カウンタと同じく参照のレジスタを上書きする)。参照も同じ回数ループを回る(2026-10-29に追加)。
- **カウンタ**: `cycle`、`time`、`mcycle`、HPMカウンタの読み出しは、コアの値を使う(参照のレジスタを上書きする)。本来違って当然なのはこれらだけである。`instret`は比べる(融合した組は2と数える)。
- **ミスアラインのアクセスはトラップ**(mmRISC-2と同じ)。参照も同じ設定にする。
- **参照はmmRISC-2のマシン**: その命令セット(`rv64imafdc_zicboz_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zba_zbb_zbc_zbs_smcntrpmf_sscofpmf_sstc`。mmRISC-3も維持する)と、PMP 16エントリ(実装8、読むと0が8)、M / S / Uモード。0x8000_0000からのRAM 1領域(64 MB)、デバイスなし。
- Phase 1はMモード、ベアメタル、割り込みなし。割り込み(コアが受けたところで参照にも受けさせる)と副作用のあるMMIOはPhase 2で加える。

## 自己テスト(2026-10-25)

`./run_selftest.sh`: mmRISC-2のビルドにある、rv64ui / um / ua / uc / uf / ud / uzba / uzbb / uzbc / uzbs / uzicond / mi / siの`-p-`のテストすべてと、`Plan/trace`のg14のCoreMarkの2ビルド。

| 実行 | 確かめること |
|---|---|
| そのまま | 正しい命令列が、不一致なしでHTIFの終了まで通る |
| 融合 | 同じ命令列に「融合した組の前半」の印(`rd_skip`、値は壊す)をつけても通る |
| 終了コード | 0以外で終わるのは、mmRISC-2でも失敗が想定されているテストだけ: `ma_data`(ミスアラインのアクセスをハードウェアで行うことを求める)と`amocas_*`(Zacasは実装していない)。これらでも比較は通る |
| 壊したもの | ランダムなコミットの1つのフィールドを壊す(10種類: レジスタの値、レジスタ番号、書き込みの欠落、pc、命令、トラップの有無、トラップの原因、ストアのデータ、ストアの欠落、コミットの欠落)。まさにそのコミットで検出される |

結果は`results/selftest.txt`にある。

**CoreMark(2026-10-25に解決)**: 終了コード37の原因はCoreMarkではなく比較器のHTIFだった。文字の書き込み(デバイス1、コマンド1)で文字コードが奇数のものを、終了と取り違えていた(デバイスより先にビット0を見ていた)。今はデバイスを先に見る。参照の上で両ビルドとも終了コード0で最後まで走り、`Plan/icount`の`spike`での実行と同じものを出力する(crcfinal 0xfcaf。「Errors detected」は、10回の繰り返しがCoreMarkの求める10秒より短いためだけ)。
