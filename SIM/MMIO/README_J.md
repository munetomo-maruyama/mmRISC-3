# SIM/MMIO

[English](README.md)

`RTL/CPU/MMIO`のmmRISC-2からの唯一の変更(手順1.8 I2、`Plan/OOC_J.md` 29.79)の確認: `CPU_PLIC`は各コンテキストの最良の
ソースを、mmRISC-2のループ(約46段の連鎖、20 nsで-17.8 ns)ではなく木(5段)で選ぶ。答えは同じでなければならない。

```bash
./run_plic_eq.sh
```

| ファイル | 内容 |
|---|---|
| `CPU_PLIC_MM2.sv` | mmRISC-2 Rev.02の`CPU_PLIC`を改名したもの: 参照 |
| `tb_plic_eq.sv` | 両方を同じ入力で並べる(ソース31本、コンテキスト2つ、優先度3ビット) |
| `tb_plic_eq.cpp` | ランダムなレジスタアクセス(優先度、保留、有効化、しきい値、claim、任意のIDのcomplete、任意のアドレス)とランダムなソースで400万サイクル。`irq`と`rdata`を毎サイクル比べる |
| `run_plic_eq.sh` | Verilatorでビルドして(`obj_dir/`、残さない)動かす: 何も違わなければPASS |

結果(2026-11-16): 違いなし。割り込みのあるサイクル183万、ソースを返したclaim 11.5万。木で同点を大きい番号に渡すと、900
サイクル以内に最初の違いが出る。コアの中では、選択は`SIM/CORE/b4/irq/irq.S`の3bと`SIM/CORE/mutate_core.py`の`CPU_PLIC`の
ミューテーションで確かめる。
