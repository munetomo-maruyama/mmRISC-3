# RTL/CPU/CORE

[English](README.md)

mmRISC-2 Rev.02から**変えずに**持ってきたmmRISC-3のブロック(`Doc/UARCH_J.md` 3.10: 命令セットはmmRISC-2のもので、mmRISC-3のALUはmmRISC-2の操作の符号を使う)。ただし下の`CORE_CSR`の変更2つを除く。各ファイルは、どこから来たかを書いた行をヘッダに加えただけで、残りはmmRISC-2のまま。

| ブロック | 内容 | 使うもの | テスト(`SIM/OOO_UNIT`) |
|---|---|---|---|
| `CORE_DECOMP` | RVC → 同じ意味の32ビット命令。予約された符号には`illegal` | `OOO_DEC` | `tb_dec`: すべてのRVCの符号を、Spikeのフィールドの取り出しで書いた展開器と照合し、予約かどうかはSpikeで実行して確かめる |
| `CORE_CSR` | CSRファイル、特権レベル、トラップの状態(M / S / U、PMP、Sstc、Sdtrig、Sscofpmf / SmcntrpmfつきのPMU)。**変更2つ**: `instret_inc`は1ビットではなく、1サイクルにリタイアした命令の数(0〜4)を数える。特権仕様1.12が求める`mconfigptr`(0xF15、読み出し専用の0)を足した(riscv-arch-testの`Sm_mcsr_access`、`Plan/CORE_J.md` 5.7) | `OOO_CSRU`(`HPM_COUNTERS` = 2: G0bのL1) | `tb_csru`: CSRの組を参照と照合、トラップへの入口とMRET |
| `CORE_MDU` | Mの乗除算とZbcのキャリーなし乗算: 一度に1つの演算、mul / mulwは始めた次のサイクルに終わり、ほかはもっと後(mmRISC-3ではmulh*、clmul*、除算を受ける。mul / mulwは`OOO_PMUL`へ) | `OOO_MDUP` | `tb_mdup`: すべての演算をM / Zbcの意味と照合、killとフラッシュつきのポート0の後ろで |
| `CORE_DEC` | RV64GC + Zba / Zbb / Zbc / Zbs / Zicond / Zicsr / Zifencei / Zicbozと特権命令の32ビットのデコーダ: µopの記録を1つ | `OOO_DEC` | `tb_dec`: 300万命令を、仕様の表から書いたデコーダと照合し、存在するかどうかはSpikeが判定する |

- lintの警告(使われないビット、名前を隠す関数の引数)はmmRISC-2のもので、そのままにしている。
- `SIM/OOO_UNIT/mutate.py`はこれらのファイルも壊せる(`CORE:`の項目)。6件、すべて検出。
