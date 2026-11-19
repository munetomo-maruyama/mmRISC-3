#---------------------------------------------------------------------------
# vmx.S : Sv39 on the fetch side (step 1.8 V2, Plan/OOC.md 29.88), in lock-step.
#
# S-mode code runs under a gigapage that maps 0x8000_0000 to itself and calls
# functions in small code pages at low virtual addresses (jalr ra; a fetch fault
# there returns to ra from the M-mode handler, which sums mcause, mtval, mepc):
#   VA 0x1000  cpA (li a0, 0x111), R X A     0x2000  cpX, X A: a 32-bit addi at 0xffe,
#   VA 0x3000  not valid, later cpY             its upper half in the next page
#   VA 0x4000  cpA without X (later with it, SFENCE.VMA by address)
#   VA 0x5000  cpA, a user page (S may not run it)
#   VA 0x6000  a page beyond 40 bits (an access fault, 1)
#   VA 0x7000  cpA not accessed (Svade)
#   VA 0x8000  cpS (li a0, 0x333), and VA 0x9000 cpS again: a synonym in the I$
#              (their 13:12 differ), then cpS changed by a store and FENCE.I
# The instruction across two pages: at 0x2ffe with 0x3000 not valid, a fault with
# epc 0x2ffe and tval 0x3000; with 0x3000 mapped to cpY (whose first half is
# another upper half), it runs, taking that half. A second root maps VA 0x1000 to
# cpB (li a0, 0x222): satp changed with SFENCE.VMA and without.
#---------------------------------------------------------------------------
    .equ PTE_V, 1
    .equ PTE_R, 2
    .equ PTE_W, 4
    .equ PTE_X, 8
    .equ PTE_U, 16
    .equ PTE_A, 64
    .equ PTE_D, 128

    .macro PTE tab, idx, pa, fl
    la      t0, \tab
    la      t1, \pa
    srli    t1, t1, 12
    slli    t1, t1, 10
    ori     t1, t1, \fl
    sd      t1, (8 * \idx)(t0)
    .endm
    .macro PTEV tab, idx                # the value in t1
    la      t0, \tab
    sd      t1, (8 * \idx)(t0)
    .endm
    .macro CALL va                      # a0 0 first: what the function gives, or 0 after a fault
    li      a0, 0
    li      t2, \va
    jalr    ra, t2
    slli    s2, s2, 5
    add     s2, s2, a0
    .endm
    .macro SATP root
    la      t0, \root
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    .endm

    .section .text.init
    .globl _start
_start:
    .option push
    .option norvc
    la      t0, trap
    csrw    mtvec, t0
    li      t0, -1                      # PMP entry 0: everything, R W X (S and U code; step 1.8 P1)
    srli    t0, t0, 10
    csrw    pmpaddr0, t0
    li      t0, (3 << 3) | 7
    csrw    pmpcfg0, t0
    li      s2, 0
    li      s3, 0
    li      s4, 0
    li      s5, 0
    li      s6, 0
    # ---- the tables
    PTE     root, 0, l1, PTE_V
    li      t1, (0x80000000 >> 12) << 10 | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    PTEV    root, 2
    PTE     l1, 0, l0, PTE_V
    PTE     l0, 1, cpA, PTE_V | PTE_R | PTE_X | PTE_A
    PTE     l0, 2, cpX, PTE_V | PTE_X | PTE_A
    PTE     l0, 4, cpA, PTE_V | PTE_R | PTE_A
    PTE     l0, 5, cpA, PTE_V | PTE_X | PTE_A | PTE_U
    li      t1, 1
    slli    t1, t1, 38
    ori     t1, t1, PTE_V | PTE_X | PTE_A
    PTEV    l0, 6
    PTE     l0, 7, cpA, PTE_V | PTE_X
    PTE     l0, 8, cpS, PTE_V | PTE_X | PTE_A
    PTE     l0, 9, cpS, PTE_V | PTE_X | PTE_A
    PTE     root2, 0, l1b, PTE_V
    li      t1, (0x80000000 >> 12) << 10 | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    PTEV    root2, 2
    PTE     l1b, 0, l0b, PTE_V
    PTE     l0b, 1, cpB, PTE_V | PTE_X | PTE_A
    SATP    root
    sfence.vma
    li      t0, 3 << 11
    csrc    mstatus, t0
    li      t0, 1 << 11
    csrs    mstatus, t0                 # MPP S
    la      t0, s_code
    csrw    mepc, t0
    mret

    # ---- S mode
s_code:
    CALL    0x1000                      # 0x111
    CALL    0x2ffe                      # across into a page not valid: 12, tval 0x3000
    CALL    0x4000                      # no X: 12
    CALL    0x5000                      # a user page: 12
    CALL    0x6000                      # beyond 40 bits: 1
    CALL    0x7000                      # not accessed: 12
    CALL    0x8000                      # 0x333
    CALL    0x9000                      # 0x333, the same line in another set of the I$
    # 0x3000 mapped to cpY: the instruction across two pages runs (its upper half cpY's)
    PTE     l0, 3, cpY, PTE_V | PTE_X | PTE_A
    li      t3, 0x3000
    sfence.vma t3, zero
    CALL    0x2ffe                      # addi a0, a0, 2 (from 0), then cpY's ret
    # 0x4000 given X, SFENCE.VMA by address
    PTE     l0, 4, cpA, PTE_V | PTE_R | PTE_X | PTE_A
    li      t3, 0x4000
    sfence.vma t3, zero
    CALL    0x4000                      # 0x111
    # cpS changed by a store, FENCE.I: both of its virtual pages give the new value
    la      t0, cpS
    li      t1, 0x44400513              # addi a0, x0, 0x444
    sw      t1, 0(t0)
    fence.i
    CALL    0x9000                      # 0x444
    CALL    0x8000                      # 0x444
    # satp to root2: VA 0x1000 is cpB there
    csrr    s7, satp
    SATP    root2
    sfence.vma
    CALL    0x1000                      # 0x222
    csrw    satp, s7
    sfence.vma
    CALL    0x1000                      # 0x111
    SATP    root2                       # without SFENCE.VMA
    CALL    0x1000                      # 0x222
    csrw    satp, s7
    CALL    0x1000                      # 0x111
    ecall

m_end:
    la      t0, sig
    sd      s2, 0(t0)
    sd      s3, 8(t0)
    sd      s4, 16(t0)
    sd      s5, 24(t0)
    sd      s6, 32(t0)
    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
9:  j       9b

    .balign 4
trap:
    csrr    t5, mcause
    li      t6, 9
    beq     t5, t6, 1f                  # an ECALL from S: the end
    add     s3, s3, t5
    csrr    t6, mtval
    add     s4, s4, t6
    csrr    t6, mepc
    add     s5, s5, t6
    addi    s6, s6, 1
    csrw    mepc, ra                    # a fetch fault: back after the call
    mret
1:  csrw    satp, zero
    j       m_end

    # ---- the code pages
    .balign 4096
cpA:
    li      a0, 0x111
    ret
    .balign 4096
cpB:
    li      a0, 0x222
    ret
    .balign 4096
cpS:
    li      a0, 0x333
    ret
    .balign 4096
cpX:
    .skip   0xffe, 0
    .2byte  0x0513                      # addi a0, a0, 1: its lower half (its upper half 0x0015 in the next page)
cpXn:
    .2byte  0x0015
    .2byte  0x8082                      # c.ret (cpX's next page, never run: VA 0x3000 is cpY)
    .balign 4096
cpY:
    .2byte  0x0025                      # another upper half: addi a0, a0, 2
    .2byte  0x8082                      # c.ret
    .option pop

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0

    .section .data
    .balign 4096
root:   .zero 4096
l1:     .zero 4096
l0:     .zero 4096
root2:  .zero 4096
l1b:    .zero 4096
l0b:    .zero 4096
sig:    .zero 40
