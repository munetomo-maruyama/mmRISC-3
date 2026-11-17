# RTL/CPU/FPU

[English](README.md)

mmRISC-2 Rev.02のパイプラインFPUを、mmRISC-3のために**変更なしで**持ってきたもの(手順1.8 U1、`Plan/OOC_J.md` 29.81)。
`Plan/OOC_J.md` 29.77と29.80のリネームするFPUのため。仕様はmmRISC-2の`RTL/CPU/CPU_CORE/CPU_CORE_SPEC_J.md`の10章(10.11がパイ
プライン版)と`RTL/CPU/CPU_FPU/README_J.md`。各ファイルのヘッダに、出どころを示す1行を加えた。

| ブロック | 内容 | mmRISC-3では |
|---|---|---|
| `FPU_PIPE` | FとDのすべての演算を9段で、1サイクルに1つ、**すべて同じレイテンシ(9)**、結果は受け取った順。除算と平方根はP1の反復エンジンで、受け取りから答えまでFPUを止める(`in_ready`がlow)。P0とP1は止めることも取り消すこともできる | `OOO_FPUW`(`RTL/CPU/OOO`)の中。受け取れるものだけを出し、killされたものは自分で捨てる(holdとkillはlowに固定)。`TAG_W`は4: `OOO_FPUW`の出したµopのリングの番号 |
| `FPU_ROUND` | 正規化、丸め、詰め込み。丸めるものすべて | `FPU_PIPE`の中 |

- mmRISC-2で単体で測った値(`FPGA/FPU_OOC`、50 MHz): LUT 9,060、フリップフロップ2,631、DSP 16、レジスタ間+3.76 ns。
- mmRISC-2でBerkeley SoftFloatに対して確かめた(`FPU_PIPE`で約70万の検査、すべての演算、両方の精度、5つの丸めモード、フラグ)。
  バグ注入も28件中28件。ここでは`SIM/OOO_UNIT/tb_fpuw`が`OOO_FPUW`の中でホストのIEEE演算に対して動かす。mmRISC-2自身の
  ブロックのテストは繰り返さない。
- lintの警告(`-Wall`で6件)はmmRISC-2のもの。
