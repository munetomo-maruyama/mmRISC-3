# RTL/CPU/CACHE

[English](README.md)

mmRISC-2 Rev.02のL1データキャッシュを、mmRISC-3のために持ってきたもの(`Doc/UARCH_J.md` 3.7: D$はmmRISC-2のものをアダプタの後ろに置く)。仕様はmmRISC-2の`RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC_J.md`。各ファイルには、どこから来たかを書いた行をヘッダに加えた。

| ブロック | 内容 | mmRISC-2からの変更 |
|---|---|---|
| `DCACHE` | 物理インデックス・物理タグ、4ウェイ × 64セット × 64バイト、ライトバック + ライトアロケート、MSHR 2(ノンブロッキング)、ライトバックバッファ2、要求の順に答える、AXI4のメモリバスとAXI4-Liteの周辺バス | **出力を1つ加えた**: `d_hit_now` / `d_hit_now_data`、ステージ1でのロードのヒットを見つけたそのサイクルに出す(ミスの下でも)。`OOO_DCAD`がLSUのMに渡す(`Plan/OOC_J.md` 17.2)。答えは今までどおり`d_resp_*`にも順に出る |
| `CACHE_TAG_ARRAY` | タグ(メモリ、同期読み出し)とvalid / dirtyのビット(フリップフロップ) | なし |
| `CACHE_DATA_ARRAY` | 64ビットの語、ウェイごとにブロックRAM 1つ、バイトの書き込みイネーブル | なし |

- テスト: `SIM/OOO_UNIT/tb_dcad`(`OOO_LSU`、`OOO_DCAD`、`DCACHE`とAXI4のメモリのモデル)。mmRISC-2自身のキャッシュのテスト(`SIM/SIM_CACHE`)はここでは繰り返さない。加えた出力は2行の論理。
- lintの警告(フィールドを取り出す関数の使われないアドレスのビット、使われないパラメータ)はmmRISC-2のもの。
- `SIM/OOO_UNIT/mutate.py`はこれらのファイルも壊せる(`CACHE:`の項目)。1件、検出。
