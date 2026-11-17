#---------------------------------------------------------------------------
# fprm.S : B4's directed test of the rounding mode's traps (step 1.8 U2b,
# Plan/OOC.md 29.83), in lock-step: frm written with every value 0 to 7
# (fsrm: a CSR write, what follows replays); with each, FP operations that
# round with the dynamic mode (they trap with frm 5 to 7: an illegal
# instruction, Spike's RM), and operations that do not round (sign
# injection, min / max, compares, moves, fclass: they run whatever frm
# holds); then the reserved static modes 5 and 6 in the instruction (.word:
# the assembler has no name for them). Each after 0 to 3 ALU instructions,
# so that it lands in any slot. The handler stores mcause and mtval and
# skips the instruction.
#---------------------------------------------------------------------------
    .section .text.init
    .globl _start
_start:
    la      t0, handler
    csrw    mtvec, t0
    li      t0, 0x6000              # mstatus.FS on
    csrs    mstatus, t0
    .irp r, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\r, 0
    .endr
    la      s0, sig
    la      s1, buf
    fld     f2, 0(s1)
    fld     f3, 8(s1)
    fld     f4, 16(s1)
    fld     f5, 24(s1)
    li      a1, -7

    .macro  pre n
    .rept   \n
    addi    a0, a0, 1
    .endr
    .endm
    .macro  each n
    pre \n
    fadd.d  f1, f2, f3, dyn
    pre \n
    fmul.s  f7, f2, f3, dyn
    pre \n
    fmadd.d f6, f5, f4, f3, dyn
    pre \n
    fsqrt.d f8, f4, dyn
    pre \n
    fcvt.w.d a2, f5, dyn
    pre \n
    fcvt.s.l f9, a1, dyn
    pre \n
    fcvt.s.d f10, f4, dyn
    pre \n
    fdiv.s  f11, f2, f3, dyn
    pre \n
    fsgnjn.d f12, f2, f3
    pre \n
    fmin.d  f13, f4, f5
    pre \n
    flt.d   a3, f4, f5
    pre \n
    fmv.x.d a4, f6
    pre \n
    fclass.d a5, f5
    pre \n
    fmv.d.x f14, a1
    .endm

    li      s2, 0
1:  fsrm    s2                      # frm 0 .. 7
    each 0
    each 1
    each 2
    each 3
    frcsr   a6
    frflags a7
    addi    s2, s2, 1
    li      t0, 8
    bne     s2, t0, 1b
    fsrmi   0
    pre 0
    .word   0x023150d3              # fadd.d f1, f2, f3, rm 5
    pre 1
    .word   0x103150d3              # fmul.s f1, f2, f3, rm 5
    pre 2
    .word   0x5a0150d3              # fsqrt.d f1, f2, rm 5
    pre 3
    .word   0xc2015553              # fcvt.w.d a0, f2, rm 5
    pre 0
    .word   0xd205d0d3              # fcvt.d.w f1, a1, rm 5
    pre 1
    .word   0x1a42d343              # fmadd.d f6, f5, f4, f3, rm 5
    pre 2
    .word   0x023160d3              # fadd.d f1, f2, f3, rm 6
    pre 3
    .word   0x103160d3              # fmul.s f1, f2, f3, rm 6
    pre 0
    .word   0x5a0160d3              # fsqrt.d f1, f2, rm 6
    pre 1
    .word   0xc2016553              # fcvt.w.d a0, f2, rm 6
    pre 2
    .word   0xd205e0d3              # fcvt.d.w f1, a1, rm 6
    pre 3
    .word   0x1a42e343              # fmadd.d f6, f5, f4, f3, rm 6

    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
1:  j       1b

    .balign 4
handler:
    csrr    t0, mcause
    sd      t0, 0(s0)
    csrr    t1, mtval
    sd      t1, 8(s0)
    addi    s0, s0, 16
    csrr    t2, mepc
    lhu     t3, 0(t2)
    andi    t3, t3, 3
    li      t4, 3
    addi    t2, t2, 2
    bne     t3, t4, 2f
    addi    t2, t2, 2
2:  csrw    mepc, t2
    mret

    .section .data
    .balign 8
buf: .double 1.5, -2.25, 9.0, 3.0e9
sig: .space 8192

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
