# RTL/CPU/OOO

[English](README.md)

mmRISC-3のOoOコアを**融合構成**(`Doc/STRATEGY_J.md` 4章)で作るための最初のブロック群。50MHzで1サイクルに閉じる必要があるループと、構成を決めるコストを持つ部分。Phase 1でそのまま使える形で書き、まず単体で測る(Phase 0、`Plan/ISSUES_J.md` 5章の手順3。結果は`Plan/OOC_J.md`)。

| ブロック | 内容 | テスト(`SIM/OOO_UNIT`) |
|---|---|---|
| `OOO_ALU` | 整数ALU 1つ: RV64I + Zba / Zbb / Zbs / Zicond。操作の種類と符号はmmRISC-2のCORE_EXUと同じ。加算器とシフタを操作の間で共有する。`FULL = 0`は融合の2段目用に絞ったもの | OOO_ALU2を通して |
| `OOO_ALU2` | 発行ポート1つ分のALU: フルの`OOO_ALU`と絞った`OOO_ALU`を直列にして、融合したALU + ALUを1サイクルで終える。分岐の比較(単独、または融合したALU + 分岐で1段目の結果と比べる) | `tb_alu2`: 仕様から書いた参照とランダムに200万件 |
| `OOO_FUSE` | 融合: デコードした4命令 → 次の2 µop(lui + addi、auipc + x、slli + srli、ALU + ロード、ロード / ストアのペア、ALU + 分岐、ALU + ALU)。組のソースは2本まで・書き込みは1本まで、ALU + ALUの後半は2段目に置ける操作だけ | `tb_fuse`: 規則の参照とランダム。CoreMarkの命令列でモデルの組の99.99%以上を作る |
| `OOO_IQ` | 発行キュー: 16エントリ、ソース3、1サイクルに2入 / 3出(ALU0 + MUL/DIV、ALU1、LSU)、1サイクルのwakeup-select、age matrixで古い順、レイテンシ2と外部からのwakeup | `tb_iq`: 値が使える時刻を独立に追った帳簿と、毎サイクルの発行を照合 |
| `OOO_RENAME` | リネーム: 1サイクルに2 µop、ソース3・デスティネーション2、RAT、フリーリスト、busyビット、同じ組の中の依存、チェックポイント8 | `tb_rename`: コミット・書き戻し・復元を含む参照と照合 |
| `OOO_PRF` | 物理レジスタ: 96 × 64、書き込みNW / 読み出しNR、LUTRAMのバンク + LVT | `tb_prf`: 配列とランダムに照合 |
| `OOO_UBTB` | next-line予測器: 16エントリ、12ビットの部分タグ、並列の選択で次のフェッチアドレスを1サイクルで出す | `tb_ubtb`: 参照の表と照合 |

- 書き方はmmRISC-2に合わせた(`logic`、負論理の非同期リセットの`always_ff`、何を・なぜを書くコメント)。
- すべてのブロックをVerilator(`-Wall`)でlintした。単体テストでは、リセットのない状態をすべてランダムな値で始める。
- `SIM/OOO_UNIT/mutate.py`で、RTLをわざと壊す(33件)。すべて検出された。
- VivadoのOOC合成: `FPGA/OOO_OOC`(`synth_ooo.bat`)。作者が実行する。
