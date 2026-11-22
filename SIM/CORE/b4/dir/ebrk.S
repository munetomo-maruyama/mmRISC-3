#---------------------------------------------------------------------------
# ebrk.S : EBREAK in M, EBREAK and C.EBREAK in S, EBREAK in U, 40 times each, each
# a breakpoint trap to M that the handler steps over (step 1.8 J1, Plan/OOC.md 29.102).
#
# Self-checking (tohost = 1 on success, 3 if the count is wrong): 160 traps of
# cause 3. The program is the debugger's
# vehicle: under tb_core -dbg -dbgf 1, dcsr.ebreakm / s / u (drawn again at each
# resume) make some of these EBREAKs halt into debug mode instead, which the
# debugger steps over in the core and the reference alike; the count then
# differs on both sides alike (the debugger's runs do not ask for exit 0).
#---------------------------------------------------------------------------
    .equ N, 40

    .section .text.init
    .globl _start
_start:
    .option push
    .option norvc
    la      t0, trap
    csrw    mtvec, t0
    li      t0, -1                      # PMP entry 0: everything, R W X (for S and U)
    srli    t0, t0, 10
    csrw    pmpaddr0, t0
    li      t0, (3 << 3) | 7
    csrw    pmpcfg0, t0
    li      s3, 0                       # breakpoints
    li      s4, N
loop:
    ebreak                              # M
    la      s7, 1f                      # S
    la      t0, s_code
    csrw    mepc, t0
    li      t0, 3 << 11
    csrc    mstatus, t0
    li      t0, 1 << 11
    csrs    mstatus, t0
    mret
1:  la      s7, 2f                      # U
    la      t0, u_code
    csrw    mepc, t0
    li      t0, 3 << 11
    csrc    mstatus, t0
    mret
2:  addi    s4, s4, -1
    bnez    s4, loop
    li      t0, 4 * N
    li      a0, 1
    beq     s3, t0, 1f
    li      a0, 3
1:  la      t1, tohost
    sd      a0, 0(t1)
1:  j       1b

s_code:
    ebreak
    .option rvc
    c.ebreak
    c.nop
    .option norvc
    ecall
u_code:
    ebreak
    ecall

    .balign 4
trap:
    csrr    t5, mcause
    li      t6, 3
    bne     t5, t6, 2f
    addi    s3, s3, 1                   # a breakpoint: past it (C.EBREAK 2 bytes)
    csrr    t6, mepc
    lhu     t5, 0(t6)
    andi    t5, t5, 3
    addi    t6, t6, 2
    li      t4, 3
    bne     t5, t4, 1f
    addi    t6, t6, 2
1:  csrw    mepc, t6
    mret
2:  csrw    mepc, s7                    # an ECALL (S or U): on in M
    li      t6, 3 << 11
    csrs    mstatus, t6
    mret
    .option pop

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
