# dma_prog.S : the core's side of tb_CPU_TOP (SIM/TOP): a word made dirty in the D$, then
# waits for the DMA's word, and copies the word the DMA wrote in pieces to a flag
    .section .text.init
    .globl _start
_start:
    li      t0, 0x80001000
    li      t1, 0x1122334455667788
    sd      t1, 0(t0)               # dirty in the D$: memory still has 0
    li      t2, 0x80002000
    li      t3, 0xcafef00ddeadbeef
1:  ld      t4, 0(t2)               # the line in the D$; the DMA's write goes into it
    bne     t4, t3, 1b
    ld      t5, 8(t2)               # the word the DMA wrote in pieces
    li      t0, 0x80003000
    sd      t5, 0(t0)
2:  j       2b
