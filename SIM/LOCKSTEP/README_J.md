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
| (設定) | `LockstepCfg::pmp_regions`: 手順1.8 P1(`Plan/OOC_J.md` 29.89)から8、コアの8エントリ(以前は16: 参照がエントリ8〜15を保持していた) |
| `st_pa` | 参照の側だけ、比較しない: ストアの物理アドレス(ステップの後にSpikeのsatp、実効特権、表をソフトウェアでたどる。手順1.8 V1、`Plan/OOC_J.md` 29.87)。`Lockstep::last_st_pa()`が最後に照合したストアのものを返す(ベンチのアーキテクチャのメモリ用) |

手順1.8 V2(`Plan/OOC_J.md` 29.88)から、参照の命令も表を通して読み(現在の特権で、半分ずつ。読めない半分は0)、命令フェッチのフォールト(要因1または12)は命令のビットを比べない: コアはそこでゼロを持ち、このソフトウェアのフェッチはウォークが拒んだページ(Svadeでアクセスされていないページ)を読みうる。

## コアとテストベンチが守る規則

- **HTIF**: 参照は`tohost`へのストアにすぐ応える(次の命令の前に`tohost`を0に戻す。終了: `tohost = code << 1 | 1`、文字: デバイス1、コマンド1)。コアのテストベンチ(`SIM/CORE`)は、ストアがストアキューとD$を通ってメモリに届いたときに応えるので、`tohost`をポーリングするループはコアのほうが多く回りうる。そこで**`tohost`と`fromhost`のロードはコアの値を使う**(カウンタと同じく参照のレジスタを上書きする)。参照も同じ回数ループを回る(2026-10-29に追加)。
- **カウンタ**: `cycle`、`time`、`mcycle`、HPMカウンタ、`scountovf`(そのOFビット、手順1.8 K1: Spikeのカウンタはイベントを数えない)の読み出しは、コアの値を使う(参照のレジスタを上書きする)。本来違って当然なのはこれらだけである。`instret`は比べる(融合した組は2と数える)。HPMのイベント(各番号が何を数えるかは実装のもの)と`mvendorid` / `marchid` / `mimpid`の読み出しも同じ。
- **コアの合法なCSRの選択**(`LockstepCfg`、2026-10-31、`Plan/CORE_J.md` 5.7のB4): mmRISC-2のCORE_CSRとSpikeのWARLの選択が違うところは、CSRの命令ごとに参照をコアに合わせる: `misa`は読み出し専用(読むと`misa`、書き込みはSpikeで戻す)。`mcountinhibit`はLOCKSTEPが持ち(Spikeにはない)、IRのビットが立つあいだは命令ごとの数をSpikeの`minstret`から戻す(書く命令は古いビットで数える)。`minstretcfg`(Smcntrpmf)があるレベルで`minstret`を止めているあいだは、`minstret`を変えなかったステップは、`mcause`か`scause`を書いたときだけトラップとする(手順1.8 K1)。`medeleg`のビット18は書き込みのあとに消す。`mtvec` / `stvec`に書いた予約のモードはダイレクトにする(Spikeはビット1だけを消す)。どれもriscv-arch-testのSmのテストで見つかった。コアが2つ目のSpikeである`SIM/CORE`の代役のテストでは切る。
- **Linux**(手順1.8 L1、`Plan/OOC_J.md` 29.99。OpenSBIとカーネルがそれぞれを見つけた): `stimecmp`はコアのリセット後の値、
  全ビット1で始める(Spikeは0。Sstcは決めていない)。トリガのCSR(`tselect`、`tdata1`〜`tdata3`、`tinfo`)の読み出しは
  コアの値を取る(コアの4つのトリガはmcontrolだけ、Spikeのは5種類。OpenSBIが調べる)。Spikeのキャッシュブロックの大きさは
  64にする(素の`processor_t`は設定せず、`cbo.zero`がでたらめなブロックをゼロにした)。CBO.ZEROは両側でそのブロックへの
  64バイトのゼロの1つのストア(`st_size` 64: Spikeの64個のバイトのストアをまとめ、コアのアドレスの記録はテストベンチが
  広げる)。そのフォールトのtvalは与えたアドレスで、コアの選択(Spikeはブロックの先頭。仕様はどちらとも言わない)。
- **ミスアラインのアクセスはトラップ**(mmRISC-2と同じ)。参照も同じ設定にする。
- **参照はmmRISC-2のマシン**: その命令セット(`rv64imafdc_zicboz_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zba_zbb_zbc_zbs_smcntrpmf_sscofpmf_sstc`。mmRISC-3も維持する)と、PMP 16エントリ(実装8、読むと0が8)、M / S / Uモード。0x8000_0000からのRAM 1領域(64 MB)、デバイスなし。
- **割り込み**(手順1.8 I1から、`Plan/OOC_J.md` 29.78): コアのトレースは先頭の前で受けたものを知らせる(`tr_int`、原因はビット63つき)。参照はその記録でその割り込みを受ける: そのステップの間だけSpikeのmipをその1ビットにし、後で戻す。ほかのステップではデバイスの保留中の割り込みを隠す(ステップの間mipをSSIPだけに、mip / sipへのCSR命令ならmieを0に)ので、コアが受けなかったものを受けることはない。SSIPはCSRの書き込みだけで立ち消えし両者で同じ: 参照は受けるべきところで受け、それより遅れて受けるコアは失敗する(CSRの書き込みのリプレイを確かめる)。mip / sipの読み出しはコアの値を取る。WFIはリタイアして参照は先へ進む(Spikeなら待つ。コアのWFIは割り込みが保留されると終わる)。
- **デバイス**(`LockstepCfg::dev`): CLINT(0x0200_0000、64 KB)、PLIC(0x0C00_0000、4 MB)、ベンチの割り込み源(0x1100_0000、4 KB)。参照のそこへのロードは0を読み、ステップの後にコアの値を取る。そこへのストアは捨てる。それらとRAMの外へのアクセスはこれまでどおりフォールト。SstcのSTIPはコアの時刻から来る(Spikeの`time`は0のままで、その読み出しはコアの値を取る): デバイスの線と同じく隠し、コアが受けたときに与える(`b4/irq/irq.S`の6)。

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
