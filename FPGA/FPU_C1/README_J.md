# FPGA/FPU_C1: mmRISC-2のFPUの内訳(手段C1)

`Plan/REDUCE_J.md`と`Doc/UARCH_J.md` 5章の手段C1。mmRISC-2の`FPU_PIPE`の8.8k LUTがどこに使われているかを測り、乗算器の共有(C2)と、まれな演算を小さな反復ユニットに移すこと(C3)の根拠にする。

```
cd FPGA\FPU_C1
synth_fpu_c1.bat
```

- このリポジトリの隣にあるmmRISC-2のツリー(`..\..\..\mmRISC-2`。別の場所なら、実行の前に`MMRISC2=<パス>`を設定する)から`FPU_PIPE.sv`と`FPU_ROUND.sv`を読み、`FPU_PIPE`を50MHzでOOC合成し、配置配線まで行う。
- `FPU_PIPE`は1つのモジュールで(丸めだけが別のモジュール)、階層別のレポートでは分けられない。そこで、すべてのレジスタを名前の先頭で組に分け(`p0`〜`p8`はステージのレジスタ、`pp` / `prod`は部分積、`sum`、`al`は桁合わせ、`ds` / `dv` / `sq`は除算と平方根のエンジン、`f2i`は整数への変換、`a` / `b` / `c`は展開した被演算子、`out`、`u_round`は丸め、など)、それぞれの組のファンインの円錐にあるLUTを数える。

| 出力(`output\FPU_C1\`) | 内容 |
|---|---|
| `breakdown.txt` | 組ごとに: レジスタの数、円錐の中のLUT、その組だけに入るLUT(その機能を外せば少なくともこれだけ空く)、CARRY4、MUXF、DSP |
| `summary.txt` | 合計、レジスタ間の余裕 |
| `utilization.rpt` | 配置配線後の物理LUT(mmRISC-2の測定の9,060と比べるため) |
