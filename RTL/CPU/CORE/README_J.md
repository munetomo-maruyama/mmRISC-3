# RTL/CPU/CORE

[English](README.md)

mmRISC-2 Rev.02から**変えずに**持ってきたmmRISC-3のブロック(`Doc/UARCH_J.md` 3.10: 命令セットはmmRISC-2のもので、mmRISC-3のALUはmmRISC-2の操作の符号を使う)。各ファイルは、どこから来たかを書いた1行をヘッダに加えただけで、残りはmmRISC-2のまま。

| ブロック | 内容 | 使うもの | テスト(`SIM/OOO_UNIT`) |
|---|---|---|---|
| `CORE_DECOMP` | RVC → 同じ意味の32ビット命令。予約された符号には`illegal` | `OOO_DEC` | `tb_dec`: すべてのRVCの符号を、Spikeのフィールドの取り出しで書いた展開器と照合し、予約かどうかはSpikeで実行して確かめる |
| `CORE_DEC` | RV64GC + Zba / Zbb / Zbc / Zbs / Zicond / Zicsr / Zifencei / Zicbozと特権命令の32ビットのデコーダ: µopの記録を1つ | `OOO_DEC` | `tb_dec`: 300万命令を、仕様の表から書いたデコーダと照合し、存在するかどうかはSpikeが判定する |

- lintの警告(使われないビット、名前を隠す関数の引数)はmmRISC-2のもので、そのままにしている。
- `SIM/OOO_UNIT/mutate.py`はこれらのファイルも壊せる(`CORE:`の項目)。4件、すべて検出。
