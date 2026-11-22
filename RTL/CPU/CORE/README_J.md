# RTL/CPU/CORE

[English](README.md)

mmRISC-2 Rev.02から**変えずに**持ってきたmmRISC-3のブロック(`Doc/UARCH_J.md` 3.10: 命令セットはmmRISC-2のもので、mmRISC-3のALUはmmRISC-2の操作の符号を使う)。ただし下の`CORE_CSR`の変更7つを除く。各ファイルは、どこから来たかを書いた行をヘッダに加えただけで、残りはmmRISC-2のまま。

| ブロック | 内容 | 使うもの | テスト(`SIM/OOO_UNIT`) |
|---|---|---|---|
| `CORE_DECOMP` | RVC → 同じ意味の32ビット命令。予約された符号には`illegal` | `OOO_DEC` | `tb_dec`: すべてのRVCの符号を、Spikeのフィールドの取り出しで書いた展開器と照合し、予約かどうかはSpikeで実行して確かめる |
| `CORE_CSR` | CSRファイル、特権レベル、トラップの状態(M / S / U、PMP、Sstc、Sdtrig、Sscofpmf / SmcntrpmfつきのPMU)。**変更7つ**: `instret_inc`は1ビットではなく、1サイクルにリタイアした命令の数(0〜4。手順1.8 K1から4ビットで0〜8)を数える。特権仕様1.12が求める`mconfigptr`(0xF15、読み出し専用の0)を足した(riscv-arch-testの`Sm_mcsr_access`、`Plan/CORE_J.md` 5.7)。`instret_force`はmcountinhibit.IRが立っていても`instret_inc`を数える(IRを立てた命令のコミット。古いビットで数える、`Plan/CORE_J.md` 5.15)。手順1.8 K1(`Plan/OOC_J.md` 29.98)から`hpm_ev`はイベントとサイクルごとの数(`HPM_EVW`ビット。1はmmRISC-2のもの)を渡し、カウンタはそれを足し、OFは加算の桁上がりで立つ。minstretcfgを書く命令は古いフィルタで数える(Spikeと同じ、mcountinhibitのものと同じ)。手順1.8 J1から(`Plan/OOC_J.md` 29.102)`dbg_mode`: デバッグモードでは命令がデバッガの権限を持ち(dcsr、dpc、dscratch0 / 1: コア自身の列がそれでレジスタを移す)、デバッグモードに入ると特権レベルをMにする。そして`trig_a0_ok`、そのレベルでaction 0のトリガが発火してよいか(MではtcontrolのMTEとmstatus.MIE、Sではブレークポイントが委譲されていればsstatus.SIE: Debug Spec 1.0 5.1の2つのやり方を両方、Spikeのとおり) | `OOO_CSRU`(`HPM_COUNTERS` = 2: G0bのL1) | `tb_csru`: CSRの組を参照と照合、トラップへの入口とMRET。K1からイベントのカウンタ(数0〜8、MINH、mcountinhibit、一周)とminstretcfg |
| `CORE_MDU` | Mの乗除算とZbcのキャリーなし乗算: 一度に1つの演算、mul / mulwは始めた次のサイクルに終わり、ほかはもっと後(mmRISC-3ではmulh*、clmul*、除算を受ける。mul / mulwは`OOO_PMUL`へ) | `OOO_MDUP` | `tb_mdup`: すべての演算をM / Zbcの意味と照合、killとフラッシュつきのポート0の後ろで |
| `CORE_DEC` | RV64GC + Zba / Zbb / Zbc / Zbs / Zicond / Zicsr / Zifencei / Zicbozと特権命令の32ビットのデコーダ: µopの記録を1つ | `OOO_DEC` | `tb_dec`: 300万命令を、仕様の表から書いたデコーダと照合し、存在するかどうかはSpikeが判定する |

- lintの警告(使われないビット、名前を隠す関数の引数)はmmRISC-2のもので、そのままにしている。
- `SIM/OOO_UNIT/mutate.py`はこれらのファイルも壊せる(`CORE:`の項目)。6件、すべて検出。
