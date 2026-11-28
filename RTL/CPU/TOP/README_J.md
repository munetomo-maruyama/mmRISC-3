# RTL/CPU/TOP

[English](README.md)

SoCに入れる1つのブロックとしてのmmRISC-3(手順2.6、`Doc/STRATEGY_J.md`。LiteXのラッパーは`LitexSystem/cpu/mmrisc3`)。

```
CPU_TOP
├─ DBG_TOP     デバッグ部(RTL/CPU/DBG): JTAG / cJTAG、DTM、DM
├─ OOO_CPU     I$、D$、L2、CLINT、PLICを持つコア(RTL/CPU/OOO)
├─ 起動        リセットの数サイクル後に、OOO_CPUをRESET_VECTORから起動(boot)
└─ DMAポートと調停: SoCのDMA(AXI4-Liteスレーブ)とDMのAccess Memory / SBAを、
               OOO_CPUのバスマスタポート(bm_*: OOO_DMISS2のデバッガポート)へ
```

| ポート | 内容 |
|---|---|
| `clk`、`rst_dbg_n`、`rst_n` | CPUのクロック。デバッグ部のパワーオンリセット。システムリセット(CPUだけ。DMのndmresetとhartresetと合わせて`OOO_CPU`のリセット、`DBG_TOP`の`rst_bus_n`になる) |
| `irq_src[31:1]` | PLICのソース1〜31 |
| `jtag_*`、`cjtag_*`、`dbg_auth_*` | デバッグポートのピン、cJTAGのスイッチ、認証のスイッチとキー |
| `dbg_halted`、`dbg_running`、`dbg_dmactive` | 状態(ボードのLED) |
| `m_axi4_*` | `OOO_CPU`のメモリバス(L2のAXI4): `[CBASE, CTOP)`のD$のラインと、**すべてのフェッチ**(`OOO_ICACHE`はフェッチしたものをキャッシュする): ブートROMのラインはSoCがここから振り分ける |
| `m_axil_*` | `OOO_CPU`の周辺バス(AXI4-Lite): `[CBASE, CTOP)`の外へのD$のアクセス。ただしCLINTとPLICは`CPU_MMIO`が中で応答する |
| `s_dma_*` | **DMAポート**(AXI4-Liteスレーブ、64ビット): コアから見えるのと同じメモリを、D$経由で |

**DMAポート。** `OOO_CPU`のバスマスタポートを通して1度に1アクセスで、`OOO_DMISS2`のデバッガポートへ行きます。`[CBASE, CTOP)`の中はD$経由(D$にないラインは先にフィル。書き込みはそのラインをダーティにする)で、ハートが動いていてもいなくてもコアのキャッシュと一貫しています(mmRISC-2の`DMA_CACHE`と同じ)。その外は周辺バスの1ビートです。読み出しは、アドレスを含む8バイトワードの8バイトアクセス1回。書き込みはストローブで整列した部分に分け、下位から順に行います: 8つのストローブがすべて立っていれば8バイト、そうでなければ残っている最下位のストローブから4、2、1のうち最大のもの(0x3c: 2 + 2バイト、0x81: 1 + 1)。ストローブなしは応答だけで何も書きません。エラー応答(デバイスのもの)はSLVERR。DMの要求(1回ごとのパルス)は処理するまで保持し、先に処理します。アクセスは`OOO_CPU`がリセットを抜けているときだけ始め、途中でリセットされたアクセスはそこで終えます。DMA書き込みは、DMの書き込みと同じく、次にデバッグモードから再開するときに`OOO_DBG`のfence.iシーケンスを走らせます(害はない)。

**テスト**: `SIM/TOP/run_top.sh`(DMAポートとD$: D$でダーティなワードの読み出し、コアから見える分割書き込み、デバイス、SLVERR)、`SIM/OCD/run_ocd.sh top`(OpenOCDの50項目を`CPU_TOP`経由で、認証あり/なし)、`LitexSystem/sim/run_sim.sh`(シミュレーションでLiteXのBIOS)。
