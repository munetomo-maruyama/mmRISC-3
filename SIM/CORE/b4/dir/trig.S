#---------------------------------------------------------------------------
# trig.S : the triggers (Sdtrig, 4 of type 2 mcontrol, exact address, before the
# instruction or access, action 0: a breakpoint), in lock-step (step 1.8 J1,
# Plan/OOC.md 29.101).
#
# Self-checking: tohost = 1 on success, (n << 1) | 1 with n the failing part.
#   1  M mode, tcontrol.MTE 1: an execute trigger on a compressed instruction:
#      a breakpoint (3, tval its pc) before it runs; it runs once, after the
#      handler clears the triggers; the handler sees tcontrol MTE 0 / MPTE 1
#      (a trap to M), and MRET puts MTE back
#  1b  an execute trigger on the second halfword of a word (two compressed
#      instructions): the breakpoint at the second, not at the word's first
#   2  M mode, MTE 0: the same trigger does not fire; nor with MTE 1 and
#      mstatus.MIE 0 (Debug Spec 1.0 5.1's second way, which Spike has too:
#      the M-mode parts run with MIE 1, no interrupt enabled in mie)
#   3  a load trigger (ld): a breakpoint, tval the address; the load runs after
#   4  a store trigger (sd): a breakpoint; the store is done once, after
#   5  a load trigger on a misaligned halfword's address: the breakpoint comes
#      first (3, not 4); the load then runs and is misaligned (4, skipped)
#   6  an AMO (amoadd.d) on a store trigger, then on a load trigger: both fire
#   7  an FP load (fld) on a load trigger
#   8  two triggers at one instruction (execute on an ld, load on its address):
#      one breakpoint, the execute one's (tval its pc)
#   9  tselect 4 (past the last) is not taken
#  10  S mode (bare): an execute trigger with s fires; one with u alone does not
#  11  U mode: an execute trigger with u fires
#  12  the hit bits: every breakpoint's trigger read with hit set by the handler
# The trap handler (M) sums mcause and mtval and counts; the parts add the
# expected tvals (s10) as they go; for a breakpoint it reads tcontrol and each
# trigger's hit, then clears the 4 triggers, so the instruction runs on mret.
#---------------------------------------------------------------------------
    .equ TD,    0x2000000000000000      # type 2
    .equ TM,    0x40
    .equ TS,    0x10
    .equ TU,    0x08
    .equ TX,    4
    .equ TST,   2
    .equ TLD,   1

    .macro FAIL n
    li      a0, (\n << 1) | 1
    j       fail
    .endm
    # trigger \sel on the address in \reg with the bits \bits
    .macro TRIG sel, reg, bits
    li      t0, \sel
    csrw    tselect, t0
    csrw    tdata2, \reg
    li      t0, TD | \bits
    csrw    tdata1, t0
    .endm

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
    li      t0, 1 << 13                 # FS on
    csrs    mstatus, t0
    li      s3, 0                       # the causes' sum
    li      s4, 0                       # the tvals' sum
    li      s5, 0                       # the traps
    li      s8, 0                       # a hit seen
    li      s9, 0                       # tcontrol wrong in the handler
    li      s10, 0                      # the tvals expected
    li      t0, 8                       # tcontrol.MTE, mstatus.MIE (mie 0: no interrupt)
    csrs    tcontrol, t0
    csrw    mie, zero
    csrsi   mstatus, 8
    la      s11, dat

    # ---- 1: an execute trigger in M, MTE 1, on a compressed instruction
    li      a5, 0
    la      t1, x1
    TRIG    0, t1, TM | TX
    add     s10, s10, t1
    .option rvc
x1: c.addi  a5, 1
    c.nop                               # (4-byte alignment back: norvc cannot pad 2 bytes)
    .option norvc
    li      t0, 1
    beq     a5, t0, 1f                  # (it ran once)
    FAIL    1
1:  li      t0, 1
    beq     s5, t0, 1f
    FAIL    1
1:  csrr    t0, tcontrol
    li      t1, 0x88
    beq     t0, t1, 1f                  # MTE back after MRET (from MPTE, which stays)
    FAIL    1
1:  bnez    s9, 9f

    # ---- 1b: an execute trigger on a word's second halfword
    li      a5, 0
    la      t1, x1c
    TRIG    0, t1, TM | TX
    add     s10, s10, t1
    .option rvc
x1b:c.addi  a5, 1
x1c:c.addi  a5, 1
    .option norvc
    li      t0, 2
    beq     a5, t0, 1f                  # (both ran once)
    FAIL    1
1:  li      t0, 2
    beq     s5, t0, 1f
    FAIL    1

    # ---- 2: MTE 0: no breakpoint in M
1:  li      t0, 8
    csrc    tcontrol, t0
    la      t1, x2
    TRIG    0, t1, TM | TX
    la      t1, x2b
    TRIG    1, t1, TM | TX
x2: addi    a5, a5, 1
    li      t0, 8
    csrs    tcontrol, t0
    csrci   mstatus, 8                  # MTE 1, MIE 0: no breakpoint either
x2b:addi    a5, a5, 1
    csrsi   mstatus, 8
    li      t0, 2
    beq     s5, t0, 1f
    FAIL    2
1:  csrw    tdata1, zero
    li      t0, 0
    csrw    tselect, t0
    csrw    tdata1, zero

    # ---- 3: a load trigger
    addi    t1, s11, 8
    TRIG    1, t1, TM | TLD
    add     s10, s10, t1
    li      a1, 0x55
    ld      a1, 8(s11)
    ld      t0, 8(s11)
    beq     a1, t0, 1f                  # (it ran after)
    FAIL    3
1:  li      t0, 3
    beq     s5, t0, 1f
    FAIL    3

    # ---- 4: a store trigger
1:  addi    t1, s11, 16
    TRIG    2, t1, TM | TST
    add     s10, s10, t1
    li      t2, 0x1234
    sd      t2, 16(s11)
    ld      t0, 16(s11)
    beq     t0, t2, 1f
    FAIL    4
1:  li      t0, 4
    beq     s5, t0, 1f
    FAIL    4

    # ---- 5: a breakpoint before a misaligned load's own exception
1:  addi    t1, s11, 1
    TRIG    3, t1, TM | TLD
    add     s10, s10, t1                # the breakpoint's tval
    add     s10, s10, t1                # ... and the misaligned load's (it runs after, and traps)
    lh      a2, 1(s11)
    li      t0, 6
    beq     s5, t0, 1f
    FAIL    5

    # ---- 6: an AMO on a store trigger, then on a load trigger
1:  addi    a4, s11, 24
    TRIG    0, a4, TM | TST
    add     s10, s10, a4
    li      t2, 1
    amoadd.d a3, t2, (a4)
    TRIG    1, a4, TM | TLD
    add     s10, s10, a4
    amoadd.d a3, t2, (a4)
    ld      t0, 24(s11)
    li      t1, 2
    beq     t0, t1, 1f                  # (both ran once, after)
    FAIL    6
1:  li      t0, 8
    beq     s5, t0, 1f
    FAIL    6

    # ---- 7: an FP load
1:  addi    t1, s11, 32
    TRIG    2, t1, TM | TLD
    add     s10, s10, t1
    fld     f1, 32(s11)
    li      t0, 9
    beq     s5, t0, 1f
    FAIL    7

    # ---- 8: two triggers on one instruction: the execute one
1:  la      t1, x8
    TRIG    0, t1, TM | TX
    add     s10, s10, t1
    addi    t1, s11, 40
    TRIG    1, t1, TM | TLD
x8: ld      a1, 40(s11)
    li      t0, 10
    beq     s5, t0, 1f
    FAIL    8

    # ---- 9: tselect past the last
1:  li      t0, 2
    csrw    tselect, t0
    li      t0, 4
    csrw    tselect, t0
    csrr    t0, tselect
    li      t1, 2
    beq     t0, t1, 1f
    FAIL    9

    # ---- 10: S mode
1:  la      t1, xs1
    TRIG    0, t1, TS | TX
    add     s10, s10, t1
    la      t1, xs2
    TRIG    1, t1, TU | TX
    la      s7, m10
    la      t0, s_code
    csrw    mepc, t0
    li      t0, 3 << 11
    csrc    mstatus, t0
    li      t0, 1 << 11                 # MPP = S
    csrs    mstatus, t0
    mret
m10:li      t0, 11
    beq     s5, t0, 1f
    FAIL    10

    # ---- 11: U mode
1:  la      t1, xu1
    TRIG    3, t1, TU | TX
    add     s10, s10, t1
    la      s7, m11
    la      t0, u_code
    csrw    mepc, t0
    li      t0, 3 << 11                 # MPP = U
    csrc    mstatus, t0
    mret
m11:li      t0, 12
    beq     s5, t0, 1f
    FAIL    11

    # ---- the end: the sums, the hits, tcontrol in the handler
1:  bnez    s9, 9f
    beqz    s8, 8f
    li      t0, 11 * 3 + 4              # 11 breakpoints, 1 misaligned load
    beq     s3, t0, 1f
    FAIL    12
1:  beq     s4, s10, 1f
    FAIL    12
1:  li      a0, 1
    j       fail
8:  FAIL    12
9:  FAIL    1
fail:
    la      t1, tohost
    sd      a0, 0(t1)
1:  j       1b

s_code:
    nop
xs2:addi    a6, a6, 1                   # (u alone: not in S)
xs1:addi    a6, a6, 1                   # (fires: s)
    ecall
u_code:
    nop
xu1:addi    a6, a6, 1                   # (fires: u)
    ecall

    .balign 4
trap:
    csrr    t5, mcause
    li      t6, 9
    beq     t5, t6, 5f                  # an ECALL from S
    li      t6, 8
    beq     t5, t6, 5f                  # ... or U
    add     s3, s3, t5
    csrr    t6, mtval
    add     s4, s4, t6
    addi    s5, s5, 1
    li      t6, 3
    bne     t5, t6, 4f
    csrr    t6, tcontrol                # a breakpoint: MPTE 1, MTE 0
    li      t4, 0x80
    beq     t6, t4, 1f
    li      s9, 1
1:  csrr    t3, tselect                 # each trigger's hit, then all cleared
    li      t4, 0
2:  csrw    tselect, t4
    csrr    t6, tdata1
    srli    t6, t6, 20
    andi    t6, t6, 1
    or      s8, s8, t6
    csrw    tdata1, zero
    addi    t4, t4, 1
    li      t6, 4
    blt     t4, t6, 2b
    csrw    tselect, t3
    mret
4:  csrr    t6, mepc                    # another exception: the instruction skipped
    addi    t6, t6, 4
    csrw    mepc, t6
    mret
5:  csrw    mepc, s7                    # an ECALL: on in M
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

    .section .data
    .balign 64
dat:    .dword 0x1111, 0x2222, 0x3333, 0, 0x4444, 0x5555, 0x6666, 0x7777
