# RTL/CPU/MMIO

[English](README.md)

mmRISC-2 Rev.02のペリフェラルバスと、そこに乗るコアの2つのブロックを、mmRISC-3のために**変更なしで**持ってきたもの
(手順1.8 I1、`Plan/OOC_J.md` 29.78)。仕様はmmRISC-2の`RTL/CPU/CPU_CORE/CPU_CORE_SPEC_J.md`の8章。各ファイルのヘッダに、
出どころを示す1行を加えた。

| ブロック | 内容 | mmRISC-3では |
|---|---|---|
| `CPU_MMIO` | D$のペリフェラルバス(AXI4-Lite)をデコードする: CLINTかPLICへのアクセスは中で答え、残りはそのまま外へ。書き込みと読み出しは1つずつ、アドレスをレジスタに取ってから決める | `OOO_CPU`の中、`OOO_DMISS2`のデバイスポートと`m_axil_*`の間。CLINTは0x0200_0000、PLICは0x0C00_0000 |
| `CPU_CLINT` | msip(0x0000)、mtimecmp(0x4000)、mtime(0xBFF8)、`TICK_DIV`サイクルに1つ進む | `CLINT_TICK_DIV`は100(50 MHz / 100: mmRISC-2と同じ500 kHz)。`SIM/CORE`のベンチでは1 |
| `CPU_PLIC` | RISC-VのPLIC: 優先度、保留、コンテキストごとの有効化としきい値 / claim / complete、レベルトリガのゲートウェイ。32ビットのレジスタはアドレスのビット2で選ぶ | ソース31本(`OOO_CPU`の`irq_src`)、コンテキスト0がマシン、1がスーパーバイザ、優先度3ビット |

- **アドレス**: PLICのレジスタはストローブではなくバイトアドレスで選ばれるので、D$のデバイスポートはアクセス自身のバイト
  アドレスを送る(`OOO_DMISS2`、および`OOO_LSU4`のストアは最初のバイトから。手順1.8 I1から: それまでは語のアドレスで、+4の
  32ビットレジスタに届かなかった)。
- テスト: `OOO_CPU`の`SIM/CORE`: `b4/irq/irq.S`とriscv-arch-testのInterruptsSm / InterruptsS(32本)を、コアが取った割り込みを
  Spikeにも取らせるロックステップで(`SIM/LOCKSTEP`)。mmRISC-2自身のブロックのテストはここでは繰り返さない。
- lintの警告(`ext_irq`、ストローブ、`cmp_safe`の使わないビット)はmmRISC-2のもの。
