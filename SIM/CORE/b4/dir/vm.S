#---------------------------------------------------------------------------
# vm.S : Sv39 on the data side (step 1.8 V1, Plan/OOC.md 29.87), in lock-step.
#
# Fetch is not translated before step V2, so code runs in M mode, or in S mode
# under a gigapage that maps 0x8000_0000 to itself (Spike translates the fetch,
# the core does not: the same bytes). The tables are built at the start:
#   VA 0x0000_0000 + k * 4 KB (a level-0 table), k =
#     0  pg0 RW A D            1  pg1 R A (no W)         2  pg2 X A (no R)
#     3  pg3 U RW A D          4  pg4 RW D (A 0)         5  pg5 RW A (D 0)
#     6  not valid             7  pg6 W without R        8  pg7 with a reserved bit
#     9  pg0 again (a synonym: its 13:12 differ from k 0's, so its D$ set does)
#    10  a page beyond 40 bits (an access fault)        11  a pointer at level 0
#    12  pg1 U R A
#   VA 0x0020_0000  a 2 MB page at 0x8040_0000;  0x0040_0000 one not aligned
#   VA 0x0060_0000  a pointer with A (reserved);  0x0080_0000 a pointer to a table
#                   outside memory (an access fault in the walk)
#   VA 0x4000_0000  a 1 GB page not aligned;  0x8000_0000 the identity gigapage
# A second root (root2) maps VA 0 to pg7, for a write of satp.
# Phase A, M mode with MPRV: MPP S (SUM off, then on), MXR, MPP U; the synonyms;
# the 2 MB page. A trap from M returns with MPP U (mret's rule), so each access
# that may fault is followed by MPP set again. Phase B, S mode: every page, loads,
# stores, an AMO, LR, misaligned on a good page, an address not canonical;
# SFENCE.VMA by address and by ASID after a PTE is changed; satp to root2 and back,
# with SFENCE.VMA and then without (the core has no ASID: a change of satp empties its
# DTLBs, as Spike's TLB is emptied; Linux with ASIDs switches without SFENCE.VMA).
# In M mode with satp on, before MPRV, a load of a device (not translated; translated, it
# would page fault: VA 0x1100_0000 is not mapped).
# At the end of phase A, PMP denies the level-0 table to S mode (an unlocked entry): the
# MPRV load's walk, S mode's, takes an access fault (step 1.8 P1).
# The trap handler (M) sums mcause and mtval into registers and skips the access.
#---------------------------------------------------------------------------
    .equ PTE_V, 1
    .equ PTE_R, 2
    .equ PTE_W, 4
    .equ PTE_X, 8
    .equ PTE_U, 16
    .equ PTE_A, 64
    .equ PTE_D, 128
    .equ RWAD, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D

# a leaf or a pointer: \tab[\idx] = (\pa >> 12) << 10 | \fl
    .macro PTE tab, idx, pa, fl
    la      t0, \tab
    la      t1, \pa
    srli    t1, t1, 12
    slli    t1, t1, 10
    ori     t1, t1, \fl
    sd      t1, (8 * \idx)(t0)
    .endm
    .macro PTEV tab, idx                # an entry of the value in t1
    la      t0, \tab
    sd      t1, (8 * \idx)(t0)
    .endm
    .macro SET_MPP v                    # MPP (0 U, 1 S); MPRV stays
    li      t0, 3 << 11
    csrc    mstatus, t0
    li      t0, \v << 11
    csrs    mstatus, t0
    .endm
    .macro MIX r                        # a value into the sum
    slli    s2, s2, 5
    add     s2, s2, \r
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
    li      s3, 0                       # the causes' sum
    li      s4, 0                       # the tvals'
    li      s5, 0                       # the traps
    # ---- the tables
    PTE     root, 0, l1_low, PTE_V
    li      t1, (0x80000000 >> 12) << 10 | RWAD | PTE_X
    PTEV    root, 2
    li      t1, (1 << 10) | RWAD        # a gigapage not aligned (its PPN 1)
    PTEV    root, 1
    PTE     l1_low, 0, l0_low, PTE_V
    li      t1, (0x80400000 >> 12) << 10 | RWAD
    PTEV    l1_low, 1                   # a 2 MB page
    li      t1, ((0x80400000 >> 12) + 1) << 10 | RWAD
    PTEV    l1_low, 2                   # ... not aligned
    PTE     l1_low, 3, l0_low, PTE_V | PTE_A    # a pointer with A
    li      t1, (0x40000000 >> 12) << 10 | PTE_V
    PTEV    l1_low, 4                   # a pointer to a table outside memory
    PTE     l0_low, 0, pg0, RWAD
    PTE     l0_low, 1, pg1, PTE_V | PTE_R | PTE_A
    PTE     l0_low, 2, pg2, PTE_V | PTE_X | PTE_A
    PTE     l0_low, 3, pg3, RWAD | PTE_U
    PTE     l0_low, 4, pg4, PTE_V | PTE_R | PTE_W | PTE_D
    PTE     l0_low, 5, pg5, PTE_V | PTE_R | PTE_W | PTE_A
    PTE     l0_low, 6, pg0, 0
    PTE     l0_low, 7, pg6, PTE_V | PTE_W | PTE_A | PTE_D
    PTE     l0_low, 8, pg7, RWAD
    la      t0, l0_low
    ld      t1, 64(t0)
    li      t2, 1
    slli    t2, t2, 60
    or      t1, t1, t2
    sd      t1, 64(t0)                  # (k 8: a reserved bit)
    PTE     l0_low, 9, pg0, RWAD
    li      t1, 1
    slli    t1, t1, 38                  # PPN bit 28: a page at 2^40
    ori     t1, t1, RWAD
    PTEV    l0_low, 10
    PTE     l0_low, 11, pg0, PTE_V      # a pointer at level 0
    PTE     l0_low, 12, pg1, PTE_V | PTE_R | PTE_A | PTE_U
    PTE     root2, 0, l1_alt, PTE_V
    li      t1, (0x80000000 >> 12) << 10 | RWAD | PTE_X
    PTEV    root2, 2
    PTE     l1_alt, 0, l0_alt, PTE_V
    PTE     l0_alt, 0, pg7, RWAD
    # known values in pg7 and the 2 MB page (physical, before translation)
    la      t0, pg7
    li      t1, 0x7777000077770000
    sd      t1, 0x20(t0)
    li      t0, 0x80401238
    li      t1, 0x2020202020202020
    sd      t1, 0(t0)
    # ---- satp
    la      t0, root
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma
    li      t0, 0x11000100              # M mode: not translated (a device: lock-step takes the core's value)
    ld      a6, 0(t0)
    MIX     a6

    # ---- phase A: M mode, MPRV, MPP S
    SET_MPP 1
    li      t0, 1 << 17
    csrs    mstatus, t0                 # MPRV
    li      a0, 0x0000                  # k 0
    li      a1, 0x9000                  # k 9: the same page
    li      a5, 0x1111
    sd      a5, 0x10(a0)
    ld      a6, 0x10(a1)                # the synonym sees it
    MIX     a6
    li      a5, 0x2222
    sd      a5, 0x18(a1)
    ld      a6, 0x18(a0)
    MIX     a6
    lw      a6, 0x14(a1)
    MIX     a6
    li      a2, 0x00201238              # the 2 MB page
    ld      a6, 0(a2)
    MIX     a6
    li      a5, 0x3333
    sh      a5, 8(a2)
    lhu     a6, 8(a2)
    MIX     a6
    li      a3, 0x3000                  # k 3: a user page, from S without SUM
    ld      a6, 0(a3)
    SET_MPP 1
    li      t0, 1 << 18
    csrs    mstatus, t0                 # SUM
    li      a5, 0x4444
    sd      a5, 0(a3)
    ld      a6, 0(a3)
    MIX     a6
    li      a4, 0x2000                  # k 2: execute only
    ld      a6, 0(a4)
    SET_MPP 1
    li      t0, 1 << 19
    csrs    mstatus, t0                 # MXR
    ld      a6, 0(a4)
    MIX     a6
    SET_MPP 0                           # MPP U
    ld      a6, 0(a3)                   # a user page from U
    MIX     a6
    ld      a6, 0(a0)                   # an S page from U
    SET_MPP 0
    li      a4, 0xc000                  # k 12: a user page R
    ld      a6, 0(a4)
    MIX     a6
    sd      a6, 0(a4)                   # ... no W
    SET_MPP 0
    # PMP on the walk (step 1.8 P1): l0_low's page denied (an unlocked entry: M itself would pass), the walk is S mode's
    SET_MPP 1
    la      t0, l0_low
    srli    t0, t0, 2
    ori     t0, t0, 0x1ff               # NAPOT, 4 KB
    csrw    pmpaddr0, t0
    li      t0, -1
    srli    t0, t0, 10
    csrw    pmpaddr1, t0                # everything
    li      t0, (3 << 3) | (((3 << 3) | 7) << 8)
    csrw    pmpcfg0, t0
    sfence.vma
    ld      a6, 0x10(a0)                # its walk reads l0_low: a load access fault
    SET_MPP 1
    li      t0, -1
    srli    t0, t0, 10
    csrw    pmpaddr0, t0
    li      t0, (3 << 3) | 7
    csrw    pmpcfg0, t0                 # back: everything
    sfence.vma
    ld      a6, 0x10(a0)
    MIX     a6
    li      t0, (1 << 17) | (1 << 18) | (1 << 19)
    csrc    mstatus, t0                 # MPRV, SUM, MXR off

    # ---- phase B: S mode
    SET_MPP 1
    la      t0, s_code
    csrw    mepc, t0
    mret
s_code:
    li      a0, 0x0000
    ld      a6, 0x18(a0)
    MIX     a6
    li      a1, 0x1000                  # k 1: R only
    ld      a6, 0(a1)
    MIX     a6
    sd      a6, 0(a1)                   # 15
    amoadd.d a6, a6, (a1)               # 15
    li      a1, 0x2000                  # k 2: X only
    ld      a6, 0(a1)                   # 13
    lr.d    a6, (a1)                    # 13
    li      a1, 0x3000                  # k 3: a user page without SUM
    lw      a6, 0(a1)                   # 13
    li      a1, 0x4000                  # k 4: not accessed
    lb      a6, 0(a1)                   # 13
    sb      a6, 0(a1)                   # 15
    li      a1, 0x5000                  # k 5: not dirty
    ld      a6, 8(a1)
    MIX     a6
    sd      a6, 8(a1)                   # 15
    amoswap.d a6, a6, (a1)              # 15
    li      a1, 0x6000                  # k 6: not valid
    ld      a6, 0(a1)                   # 13
    sd      a6, 0(a1)                   # 15
    li      a1, 0x7000                  # k 7: W without R
    ld      a6, 0(a1)                   # 13
    li      a1, 0x8000                  # k 8: a reserved bit
    ld      a6, 0(a1)                   # 13
    li      a1, 0xa000                  # k 10: beyond 40 bits
    ld      a6, 0(a1)                   # 5
    sd      a6, 0(a1)                   # 7
    li      a1, 0xb000                  # k 11: a pointer at level 0
    ld      a6, 0(a1)                   # 13
    li      a1, 0x00400000              # a 2 MB page not aligned
    ld      a6, 0(a1)                   # 13
    li      a1, 0x00600000              # a pointer with A
    ld      a6, 0(a1)                   # 13
    li      a1, 0x00800000              # a table outside memory
    ld      a6, 0(a1)                   # 5
    sd      a6, 0(a1)                   # 7
    li      a1, 0x40000000              # a 1 GB page not aligned
    ld      a6, 0(a1)                   # 13
    li      a1, 1
    slli    a1, a1, 39                  # not canonical
    ld      a6, 0(a1)                   # 13
    li      a1, 0x0000
    ld      a6, 4(a1)                   # misaligned: 4, before the translation
    li      a1, 0x2004
    ld      a6, 0(a1)                   # misaligned on a page that faults: 4 still
    # SUM and MXR from S
    li      t0, (1 << 18) | (1 << 19)
    csrs    sstatus, t0
    li      a1, 0x3000
    ld      a6, 0(a1)
    MIX     a6
    li      a1, 0x2000
    ld      a6, 0(a1)
    MIX     a6
    csrc    sstatus, t0
    # a PTE changed, then SFENCE.VMA by address: k 1 writable
    la      t2, l0_low
    ld      t1, 8(t2)
    ori     t1, t1, PTE_W | PTE_D
    sd      t1, 8(t2)
    li      a1, 0x1000
    sfence.vma a1, zero
    li      a5, 0x5555
    sd      a5, 0x30(a1)
    ld      a6, 0x30(a1)
    MIX     a6
    # ... and by ASID: k 4 accessed
    ld      t1, 32(t2)
    ori     t1, t1, PTE_A
    sd      t1, 32(t2)
    sfence.vma zero, zero
    li      a1, 0x4000
    li      a5, 0x6666
    sd      a5, 0x40(a1)
    ld      a6, 0x40(a1)
    MIX     a6
    li      t3, 0
    sfence.vma zero, t3
    # satp to root2: VA 0 is pg7 there
    csrr    s6, satp
    la      t0, root2
    srli    t0, t0, 12
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma
    li      a1, 0x0000
    ld      a6, 0x20(a1)
    MIX     a6
    csrw    satp, s6
    sfence.vma
    ld      a6, 0x18(a1)                # back: pg0's
    MIX     a6
    csrw    satp, t0                    # root2 again, no SFENCE.VMA
    ld      a6, 0x20(a1)                # pg7's
    MIX     a6
    csrw    satp, s6                    # back, no SFENCE.VMA
    ld      a6, 0x18(a1)                # pg0's
    MIX     a6
    ecall                               # back to M
    j       .

    # ---- the end, in M
m_end:
    la      t0, sig
    sd      s2, 0(t0)
    sd      s3, 8(t0)
    sd      s4, 16(t0)
    sd      s5, 24(t0)
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
    addi    s5, s5, 1
    csrr    t6, mepc
    addi    t6, t6, 4
    csrw    mepc, t6
    mret
1:  csrw    satp, zero
    j       m_end
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
l1_low: .zero 4096
l0_low: .zero 4096
root2:  .zero 4096
l1_alt: .zero 4096
l0_alt: .zero 4096
pg0:    .zero 4096
pg1:    .zero 4096
pg2:    .zero 4096
pg3:    .zero 4096
pg4:    .zero 4096
pg5:    .zero 4096
pg6:    .zero 4096
pg7:    .zero 4096
sig:    .zero 32
