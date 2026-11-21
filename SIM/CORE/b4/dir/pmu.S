#---------------------------------------------------------------------------
# pmu.S : the PMU's counters and events (step 1.8 K1, Plan/OOC.md 29.97), in lock-step.
#
# Reads of the counters, mhpmevent and scountovf take the core's values (SIM/LOCKSTEP), so the
# program checks what it reads itself and exits with a code (tohost = code << 1 | 1) at the first
# case that is wrong:
#    1 to 4   the exact events over a block of known instructions, the difference of two reads:
#             instructions retired (2), loads (3), stores (4), µops (22); the block has no branch
#             (no fused pair), so the difference is the block and the first read
#    5        cycles (1) against mcycle over the same block
#    6        exceptions (15): three ECALLs from M
#    7, 8     MINH and mcountinhibit's HPM3 stop a counter in M
#    9        an event that does not exist reads back 0 and counts nothing
#   10 to 13  a wrap: OF in mhpmevent3, scountovf's bit 3, LCOFI taken in M once, counted by
#             interrupts (16) on the other counter, OF cleared by a write
#   14, 15    LCOFI delegated to S: taken in S, cleared through sip
#   16, 17    mcounteren / scounteren: hpmcounter3 read from S and U traps (illegal instruction)
#             until its bit is set
#   18        UINH: a counter of cycles leaves out U's (against one that does not)
#   19, 20    Smcntrpmf: minstretcfg's and mcyclecfg's MINH freeze minstret / mcycle in M
#   21        the slots at renaming are counted (20 >= the µops renamed: at least the block's)
#
# The M-mode handler: an ECALL from M returns past it; from S or U, or a fault, it goes on at
# s9 in M; LCOFI clears OF and the pending bit and counts in s6. The S-mode handler counts
# LCOFI in s7 and clears sip's bit.
#---------------------------------------------------------------------------
    .equ MHPMEVENT3, 0x323
    .equ MHPMEVENT4, 0x324
    .equ MCYCLECFG, 0x321
    .equ MINSTRETCFG, 0x322
    .equ SCOUNTOVF, 0xda0
    .equ LCOF, (1 << 13)
    .equ MINH, (1 << 62)
    .equ UINH, (1 << 60)

    .macro FAILIF cond, a, b, code      # exit with code when \a \cond \b
    li      t6, \code
    \cond   \a, \b, fail
    .endm

    .macro EV3 ev                       # counter 3 counts event ev from 0
    li      t0, \ev
    csrw    MHPMEVENT3, t0
    csrw    mhpmcounter3, zero
    .endm

    .macro DROP mode, target            # to S (1) or U (0) at target; back in M at the label after it
    li      t0, 3 << 11
    csrc    mstatus, t0
    li      t0, \mode << 11
    csrs    mstatus, t0
    la      t0, \target
    csrw    mepc, t0
    la      s9, 1f
    mret
1:
    .endm

    .section .text.init
    .globl _start
_start:
    .option push
    .option norvc
    la      t0, mtrap
    csrw    mtvec, t0
    la      t0, strap
    csrw    stvec, t0
    la      sp, data
    li      t0, -1                      # PMP: everything for S and U (NAPOT, R W X)
    srli    t0, t0, 10
    csrw    pmpaddr0, t0
    li      t0, (3 << 3) | 7
    csrw    pmpcfg0, t0
    csrw    mcountinhibit, zero
    li      s6, 0
    li      s7, 0
    li      s8, 0

    # ---- 1 to 4: exact events over a block (10 instructions; 4 loads, 4 stores among them)
    EV3     2
    csrr    s0, mhpmcounter3
    call_blk:
    ld      t1, 0(sp)
    ld      t1, 8(sp)
    sd      t1, 16(sp)
    sd      t1, 24(sp)
    addi    t2, t2, 1
    addi    t2, t2, 1
    ld      t1, 32(sp)
    ld      t1, 40(sp)
    sd      t1, 48(sp)
    sd      t1, 56(sp)
    csrr    s1, mhpmcounter3
    sub     a0, s1, s0
    li      a1, 11
    FAILIF  bne, a0, a1, 1
    EV3     3
    csrr    s0, mhpmcounter3
    ld      t1, 0(sp)
    ld      t1, 8(sp)
    sd      t1, 16(sp)
    sd      t1, 24(sp)
    addi    t2, t2, 1
    addi    t2, t2, 1
    ld      t1, 32(sp)
    ld      t1, 40(sp)
    sd      t1, 48(sp)
    sd      t1, 56(sp)
    csrr    s1, mhpmcounter3
    sub     a0, s1, s0
    li      a1, 4
    FAILIF  bne, a0, a1, 2
    EV3     4
    csrr    s0, mhpmcounter3
    ld      t1, 0(sp)
    ld      t1, 8(sp)
    sd      t1, 16(sp)
    sd      t1, 24(sp)
    addi    t2, t2, 1
    addi    t2, t2, 1
    ld      t1, 32(sp)
    ld      t1, 40(sp)
    sd      t1, 48(sp)
    sd      t1, 56(sp)
    csrr    s1, mhpmcounter3
    sub     a0, s1, s0
    li      a1, 4
    FAILIF  bne, a0, a1, 3
    EV3     22
    csrr    s0, mhpmcounter3
    ld      t1, 0(sp)
    ld      t1, 8(sp)
    sd      t1, 16(sp)
    sd      t1, 24(sp)
    addi    t2, t2, 1
    addi    t2, t2, 1
    ld      t1, 32(sp)
    ld      t1, 40(sp)
    sd      t1, 48(sp)
    sd      t1, 56(sp)
    csrr    s1, mhpmcounter3
    sub     a0, s1, s0
    li      a1, 11
    FAILIF  bne, a0, a1, 4

    # ---- 5: cycles against mcycle (the counter's window inside mcycle's, within 16 cycles)
    EV3     1
    csrr    a2, mcycle
    csrr    s0, mhpmcounter3
    ld      t1, 0(sp)
    addi    t2, t2, 1
    sd      t1, 16(sp)
    addi    t2, t2, 1
    csrr    s1, mhpmcounter3
    csrr    a3, mcycle
    sub     a0, s1, s0
    sub     a1, a3, a2
    FAILIF  bgtu, a0, a1, 5
    addi    a0, a0, 16
    FAILIF  bltu, a0, a1, 5

    # ---- 6: exceptions, three ECALLs from M
    EV3     15
    csrr    s0, mhpmcounter3
    ecall
    ecall
    ecall
    csrr    s1, mhpmcounter3
    sub     a0, s1, s0
    li      a1, 3
    FAILIF  bne, a0, a1, 6

    # ---- 7, 8: MINH, then mcountinhibit's HPM3
    li      t0, MINH | 1
    csrw    MHPMEVENT3, t0
    csrr    s0, mhpmcounter3
    addi    t2, t2, 1
    addi    t2, t2, 1
    csrr    s1, mhpmcounter3
    FAILIF  bne, s0, s1, 7
    EV3     1
    li      t0, 1 << 3
    csrw    mcountinhibit, t0
    csrr    s0, mhpmcounter3
    addi    t2, t2, 1
    addi    t2, t2, 1
    csrr    s1, mhpmcounter3
    csrw    mcountinhibit, zero
    FAILIF  bne, s0, s1, 8

    # ---- 9: an event that does not exist (40): read back 0, nothing counted
    EV3     40
    csrr    a0, MHPMEVENT3
    FAILIF  bne, a0, zero, 9
    csrr    s0, mhpmcounter3
    addi    t2, t2, 1
    csrr    s1, mhpmcounter3
    FAILIF  bne, s0, s1, 9

    # ---- 10 to 13: a wrap and LCOFI in M; counter 4 counts the interrupts (16)
    li      t0, 16
    csrw    MHPMEVENT4, t0
    csrw    mhpmcounter4, zero
    li      t0, 2
    csrw    MHPMEVENT3, t0
    li      t0, -20
    csrw    mhpmcounter3, t0
    li      t0, LCOF
    csrs    mie, t0
    csrsi   mstatus, 8                  # MIE
    .rept 40
    addi    t2, t2, 1
    .endr
    csrci   mstatus, 8
    li      a1, 1
    FAILIF  bne, s6, a1, 10             # taken once
    FAILIF  beq, s5, zero, 11          # scountovf's bit 3 was set in the handler
    csrr    a0, mhpmcounter4
    FAILIF  bne, a0, a1, 12             # counted by event 16
    csrr    a0, MHPMEVENT3
    FAILIF  blt, a0, zero, 13          # OF cleared by the handler's write

    # ---- 14, 15: LCOFI delegated to S
    li      t0, LCOF
    csrs    mideleg, t0
    li      t0, -20
    csrw    mhpmcounter3, t0
    DROP    1, sbody
    li      a1, 1
    FAILIF  bne, s7, a1, 14             # taken in S once
    csrr    a0, mip
    li      t0, LCOF
    and     a0, a0, t0
    FAILIF  bne, a0, zero, 15          # cleared through sip
    li      t0, LCOF
    csrc    mideleg, t0
    csrc    mie, t0
    li      t0, 2                       # OF back to 0 (the S handler could not)
    csrw    MHPMEVENT3, t0

    # ---- 16, 17: mcounteren / scounteren
    csrw    mcounteren, zero
    csrw    scounteren, zero
    DROP    1, sread                    # S: traps
    li      t0, 1 << 3
    csrw    mcounteren, t0
    DROP    1, sread                    # S: reads
    DROP    0, sread                    # U: traps (scounteren 0)
    li      t0, 1 << 3
    csrw    scounteren, t0
    DROP    0, sread                    # U: reads
    li      a1, 2
    FAILIF  bne, s8, a1, 16
    csrw    mcounteren, zero
    csrw    scounteren, zero

    # ---- 18: UINH leaves U's cycles out
    EV3     1
    li      t0, UINH | 1
    csrw    MHPMEVENT4, t0
    csrw    mhpmcounter4, zero
    DROP    0, uloop
    csrr    a0, mhpmcounter3
    csrr    a1, mhpmcounter4
    addi    a1, a1, 100                 # (U ran 128 dependent adds: 128 cycles at least)
    FAILIF  bgeu, a1, a0, 18

    # ---- 19, 20: Smcntrpmf's MINH on minstret and mcycle
    li      t0, MINH
    csrw    MINSTRETCFG, t0
    csrr    a0, minstret
    addi    t2, t2, 1
    csrr    a1, minstret
    csrw    MINSTRETCFG, zero
    FAILIF  bne, a0, a1, 19
    li      t0, MINH
    csrw    MCYCLECFG, t0
    csrr    a0, mcycle
    addi    t2, t2, 1
    csrr    a1, mcycle
    csrw    MCYCLECFG, zero
    FAILIF  bne, a0, a1, 20

    # ---- 21: the slots used at renaming (20) over the block: at least its µops
    EV3     20
    csrr    s0, mhpmcounter3
    .rept 8
    addi    t2, t2, 1
    .endr
    csrr    s1, mhpmcounter3
    sub     a0, s1, s0
    li      a1, 9
    FAILIF  bltu, a0, a1, 21

    li      t0, 1
    j       exit
fail:
    slli    t0, t6, 1
    ori     t0, t0, 1
exit:
    la      t1, tohost
    sd      t0, 0(t1)
9:  j       9b

    # ---- M's handler
    .balign 4
mtrap:
    csrr    t5, mcause
    bltz    t5, m_int
    li      t4, 11
    beq     t5, t4, m_ecall
    jr      s9                          # an ECALL from S / U, an illegal instruction: on in M
m_ecall:
    csrr    t4, mepc
    addi    t4, t4, 4
    csrw    mepc, t4
    mret
m_int:                                  # LCOFI (13)
    addi    s6, s6, 1
    csrr    t4, SCOUNTOVF
    andi    s5, t4, 1 << 3
    li      t4, 2                       # OF 0, event 2
    csrw    MHPMEVENT3, t4
    li      t4, LCOF
    csrc    mip, t4
    mret

    # ---- S's handler: LCOFI delegated
    .balign 4
strap:
    addi    s7, s7, 1
    li      t4, LCOF
    csrc    sip, t4
    sret

    # ---- code run below M
    .balign 4
sbody:                                  # S: interrupts on, 40 instructions (the counter wraps), back to M
    csrsi   sstatus, 2                  # SIE
    .rept 40
    addi    t2, t2, 1
    .endr
    csrci   sstatus, 2
    ecall
sread:                                  # read hpmcounter3: a trap goes to M at once, else counted in s8
    csrr    t1, hpmcounter3
    addi    s8, s8, 1
    ecall
uloop:
    .rept 128
    addi    t2, t2, 1
    .endr
    ecall
    .option pop

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
    .section .data
    .balign 64
data:   .zero 128
