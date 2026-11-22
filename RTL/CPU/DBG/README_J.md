# RTL/CPU/DBG

[English](README.md)

mmRISC-3のデバッグロジック(手順1.8 J1、`Plan/OOC_J.md` 29.101 / 29.102。RISC-V Debug Specification 1.0): mmRISC-2 Rev.02の
JTAG / cJTAGの前段、DTM、CDC、Debug Moduleを**変えずに**(そのリポジトリの`RTL/CPU/CPU_DBG`、仕様はその`CPU_DBG_SPEC_J.md`)、
`OOO_CPU`向けのmmRISC-3のラッパーとともに。持ってきた各ファイルは、どこから来たかを書いた行をヘッダに加えただけで、
残りはmmRISC-2のまま。

```
DBG_TOP
├─ DBG_CJTAG   cJTAG(IEEE 1149.7 OScan1)かJTAG: TAPのピン
├─ DBG_DTM     TAP: IDCODE、dtmcs、dmi、BYPASS [TCK]
├─ DBG_CDC     TCKからシステムクロックへ(DBG_SYNC、DBG_RST_SYNC。4相ハンドシェイク)
└─ DBG_DM      Debug Moduleのレジスタ、抽象コマンド(Access Register、Access Memory)、SBA、
               認証、haltsum0、resethaltreq、hartreset、ndmreset [clk]
               -> ハート: OOO_CPUのhart_*、reg_*(OOO_TRAP、OOO_DBG)、bm_*(OOO_DMISS2)
```

| ブロック | 何か | mmRISC-2からの変更 |
|---|---|---|
| `DBG_CJTAG` | cJTAGのOScan1の受信。JTAGは素通し(`cjtag_en` 0) | なし |
| `DBG_DTM` | JTAGのTAPとDTMのレジスタ。DMIのアクセスをCDCへ | なし |
| `DBG_CDC` | 同期化、リセットの同期化、TCKとシステムクロックの間のDMIのハンドシェイク | なし |
| `DBG_DM` | Debug Module: ハート1つ、datacount 4、**progbufsize 0**(プログラムバッファなし)、abstractauto、Access Register(ハートの`reg_*`へ)、Access MemoryとSBA(sbasize 40、8〜64ビット。`bm_*`へ)、認証、L2の消去の間のリセット停止の保持 | なし |
| `DBG_TOP` | **mmRISC-3のラッパー**: 上の4つをmmRISC-2の`CPU_DBG`と同じようにつなぐ(リセット: `rst_dbg_n`はデバッグロジックのパワーオンリセット、`jtag_trst_n`はTAPの、`rst_n`はシステムの、ndmresetとhartresetと合わせて`rst_bus_n`、OOO_CPUのリセット)、ハートとバスマスタのポートを`OOO_CPU`向けに外へ。`CPU_DBG`から持ってこないもの: バスマスタ`DBG_BUSMST`、D$のポート`DBG_CACHE`、代わりのハート(OOO_CPUがDMのバスマスタのインタフェースを自分で受ける: D$はそれと一貫する)。IDCODE 0x36d6d001(mmRISC-2の0x26d6d001のバージョンを3に) | 新規 |

ハートの側はコアにある: 停止、再開、ステップ、EBREAK、トリガはROBの先頭で(`OOO_TRAP`)、レジスタのアクセスはコアが
デバッグモードで実行する短い列で(`OOO_DBG`)、メモリはD$のミスハンドラ経由で(`OOO_DMISS2`): `RTL/CPU/OOO/README_J.md`。

- **リセットはライトバックのキャッシュを空にする**(D$、L2): それらが持っていてメモリが持っていないものは、システム
  リセット、ndmreset、hartresetで失われる。プログラムは`reset halt`の後にロードする、前ではなく(mmRISC-2の
  ndmresetをまたいでメモリが保たれる試験は当てはまらない)。
- テスト: `SIM/OCD`(`DBG_TOP`付きの`OOO_CPU`をremote_bitbangでOpenOCD)。ハートの側は`SIM/CORE`でも(`tb_core -dbg`、
  ロックステップで)。mmRISC-2の`SIM_DBG`(DTMとDMを代わりのハートで、cJTAGも)が持ってきた4つのファイルを確かめた。
  ここでは繰り返さない。
