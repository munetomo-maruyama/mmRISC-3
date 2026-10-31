#---------------------------------------------------------------------------
# illegal.S : B4's directed test of the exceptions found at decode
# (Plan/CORE.md 5.7), in lock-step: with mstatus.FS off every FP
# instruction is illegal in Spike too (in the core always: no FPU in Phase
# 1); illegal compressed encodings followed by a 32-bit instruction (tval:
# the 16 bits only); 32-bit illegal instructions; each after 0 to 3 ALU
# instructions, so that it lands in either slot of a dispatch group. The
# handler stores mcause and mtval (what lock-step compares) and skips the
# instruction.
#---------------------------------------------------------------------------
    .section .text.init
    .globl _start
_start:
    la      t0, handler
    csrw    mtvec, t0
    li      t0, 0x6000              # mstatus.FS off
    csrc    mstatus, t0
    .irp r, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\r, 0
    .endr
    la      s0, sig
    la      s1, buf

    .macro  pre n
    .rept   \n
    addi    a0, a0, 1
    .endr
    .endm
    .macro  each n
    pre \n
    fmv.w.x ft0, a0
    pre \n
    fadd.d  ft1, ft2, ft3
    pre \n
    flw     ft0, 0(s1)
    pre \n
    fsd     ft1, 8(s1)
    pre \n
    .half   0x2088                  # c.fld fa0, 0(s1)
    pre \n
    .half   0xa42e                  # c.fsdsp fa1, 8(sp)
    pre \n
    .half   0x0000                  # c.unimp (c.addi4spn with no immediate)
    addi    a1, a1, 3
    pre \n
    .half   0x6081                  # c.lui x1, 0: reserved
    addi    a1, a1, 5
    pre \n
    .half   0x6101                  # c.addi16sp 0: reserved
    lui     a2, 0x12345
    pre \n
    .word   0xffffffff
    pre \n
    .word   0x0000007f              # an opcode not used
    pre \n
    csrr    a3, fcsr                # FS off: illegal
    .endm
    each 0
    each 1
    each 2
    each 3
    .option push
    .option norvc
    .balign 4
    nop
    each 1
    .option pop

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
buf: .dword 0x1234, 0x5678
sig: .space 2048

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
