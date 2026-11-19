#---------------------------------------------------------------------------
# atomic.S : B4's directed test of the atomics (step 1.4 E1c, Plan/OOC.md
# 29.74), in lock-step with Spike, which compares every result and store.
#
# 1. AMOs right behind stores to their word (committed, not drained: the
#    AMO's load part forwards from them), with a load and a store to the
#    same word right after (a younger load waits for the AMO's entry), both
#    sizes, a word at either half, every operation, negative values.
# 2. A chain: each AMO's rs2 is the result of the one before.
# 3. AMOs on 12 lines of one D$ set (8 ways): they miss, and their victims
#    are dirty (written by the AMOs before).
# 4. LR / SC: a counter by an LR / SC loop; SC with no reservation, with
#    another address, after a successful SC (fails); LR, a store to the
#    word, SC (succeeds: Spike's rule); LR, ECALL (a trap), SC (succeeds:
#    a trap keeps the reservation); LR.W then SC.D at one address; rd x0.
# 5. Exceptions: misaligned AMO, LR, SC; an AMO, LR and SC outside the
#    memory (an access fault: 0x1000_0000 is a device for the core, nothing
#    for Spike). The handler keeps mcause and mtval and skips the
#    instruction.
# 6. AMOs that miss (part 3's set) with younger stores behind them, whose
#    addresses are in the SQ before the AMO goes again after its miss: the
#    try writes the address into the AMO's SQ entry and no other. 4 loads
#    and 5 stores an iteration (the AMO 1 of each): the LQ index runs one
#    ahead of the SQ's each time round (16 entries each).
# 7. SCs that fail (no reservation), a store to their word before each and
#    one load of it right behind, its address 1 to 13 adds after the SC's
#    (whose time a division sets), so that for some the load is at E as the
#    SC fails at W: the search, compared at E since step 1.8 V3b (Plan/OOC.md
#    29.91), takes the SC's bytes away in that cycle too. One load an SC: a
#    load that meets the SC's entry before its W waits, is tried again and
#    replayed at its commit, and what follows it is fetched again.
#---------------------------------------------------------------------------
    # part 7: a store to the word, an SC of it that fails, one load of it k adds after the SC's address
    .macro SCLD k
    sd      s3, 0(s2)               # what the load must see (the SC stores nothing)
    addi    t0, s3, 77
    divu    t0, t0, s8              # a slow value, its time varying
    andi    t0, t0, 0
    add     a0, s2, t0              # the SC's address, when the division is done
    xor     a2, s6, s3              # the SC's data, not the word's
    sc.d    a3, a2, (a0)            # fails: no reservation
    add     a1, a0, zero
    .rept   \k
    add     a1, a1, zero
    .endr
    ld      t1, 0(a1)
    add     s5, s5, a3
    add     s5, s5, t1
    .endm

    .section .text.init
    .globl _start
_start:
    .option push
    .option norvc
    la      t0, handler
    csrw    mtvec, t0
    la      s0, sig
    la      s1, area                # 16 KB aligned
    li      s9, 16384
    li      s5, 0                   # a sum (lock-step compares each result anyway)

    # ---- 1. behind stores, every operation, both sizes and halves
    li      s3, 0                   # i
    li      s4, 64
    li      s6, 0x0123456789abcdef
1:  mul     t0, s3, s6              # a value that changes, negative half the time
    xor     t2, t0, s3
    slli    t1, s3, 3
    andi    t1, t1, 0x38
    add     a0, s1, t1              # a word of the first line
    addi    a1, a0, 4               # its upper half
    sd      t0, 0(a0)
    amoadd.d   a2, t2, (a0)
    ld      a3, 0(a0)
    sd      a3, 8(a0)
    amoswap.w  a4, t2, (a1)
    lw      a5, 0(a1)
    amoxor.d   a6, t0, (a0)
    amoand.w   a7, t2, (a0)
    sw      t2, 0(a1)
    amoor.w    t3, t0, (a1)
    amomin.d   t4, t2, (a0)
    amomax.w   t5, t0, (a1)
    lwu     t6, 0(a0)
    amominu.d  a2, t2, (a0)
    amomaxu.w  a3, t0, (a0)
    amomin.w   a4, t2, (a0)
    amomax.d   a5, t2, (a0)
    amominu.w  a6, t2, (a1)
    amomaxu.d  a7, t0, (a0)
    ld      t3, 0(a0)
    add     s5, s5, a2
    add     s5, s5, a3
    add     s5, s5, a4
    add     s5, s5, a5
    add     s5, s5, a6
    add     s5, s5, a7
    add     s5, s5, t3
    add     s5, s5, t4
    add     s5, s5, t5
    add     s5, s5, t6
    amoadd.d   zero, t0, (a0)       # rd x0
    amoswap.d  a2, zero, (a0)       # rs2 x0
    add     s5, s5, a2
    addi    s3, s3, 1
    bne     s3, s4, 1b

    # ---- 2. a chain: each AMO's rs2 the result of the one before
    li      s3, 0
    li      s4, 100
    li      a2, 7
2:  andi    t1, s3, 7
    slli    t1, t1, 3
    add     a0, s1, t1
    amoadd.d   a2, a2, (a0)
    addi    a2, a2, 3
    amoxor.d   a2, a2, (a0)
    ld      a3, 0(a0)
    add     s5, s5, a3
    addi    s3, s3, 1
    bne     s3, s4, 2b

    # ---- 3. 12 lines of one D$ set (256 sets x 8 ways): the AMOs miss, their victims dirty
    li      s3, 0
    li      s4, 300
    li      s7, 12
3:  remu    t0, s3, s7              # the line
    mul     t0, t0, s9
    add     a0, s1, t0
    li      t1, 5
    mul     t1, t1, s3
    andi    t1, t1, 7
    slli    t1, t1, 3
    add     a0, a0, t1              # a word that moves
    amoadd.d   a2, s3, (a0)
    andi    t2, s3, 1
    beqz    t2, 4f
    addi    a1, a0, 4
    amoadd.w   a3, s3, (a1)
    add     s5, s5, a3
4:  add     s5, s5, a2
    addi    s3, s3, 1
    bne     s3, s4, 3b

    # ---- 4. LR / SC
    la      s2, lrsc
    li      s3, 0                   # a counter by an LR / SC loop, 50 times
    li      s4, 50
5:  lr.d    t0, (s2)
    addi    t0, t0, 1
    sc.d    t1, t0, (s2)
    bnez    t1, 5b
    addi    s3, s3, 1
    bne     s3, s4, 5b
    ld      a2, 0(s2)
    add     s5, s5, a2
    li      a3, 0x55
    sc.d    a2, a3, (s2)            # no reservation (the last SC took it): fails
    add     s5, s5, a2
    addi    a4, s2, 8
    lr.d    a2, (s2)
    sc.d    a3, a2, (a4)            # another address: fails, and the reservation goes
    add     s5, s5, a3
    sc.d    a3, a2, (s2)            # so this fails too
    add     s5, s5, a3
    lr.d    a2, (s2)
    sc.d    a3, a2, (s2)            # succeeds
    add     s5, s5, a3
    sc.d    a3, a2, (s2)            # after a successful SC: fails
    add     s5, s5, a3
    lr.d    a2, (s2)
    li      a5, 0x77
    sd      a5, 0(s2)               # a store to the word between: SC still succeeds (Spike)
    addi    a2, a2, 9
    sc.d    a3, a2, (s2)
    add     s5, s5, a3
    lr.d    a2, (s2)
    ecall                           # a trap between: the reservation stays (Spike)
    addi    a2, a2, 1
    sc.d    a3, a2, (s2)
    add     s5, s5, a3
    lr.w    a2, (s2)                # LR.W, then SC.D at the same address: succeeds (Spike: the address)
    sc.d    a3, a2, (s2)
    add     s5, s5, a3
    addi    a4, s2, 4
    lr.w    a2, (a4)                # LR.W at +4, SC.W at +0: fails
    sc.w    a3, a2, (s2)
    add     s5, s5, a3
    lr.d    zero, (s2)              # rd x0
    sc.d    zero, a5, (s2)          # rd x0 (succeeds)
    ld      a2, 0(s2)
    add     s5, s5, a2
    lr.d    a2, (s2)                # an AMO between LR and SC: the SC still succeeds (Spike)
    amoadd.d   a3, a5, (s2)
    sc.d    a3, a2, (s2)
    add     s5, s5, a3
    ld      a2, 0(s2)
    add     s5, s5, a2

    # ---- 5. exceptions: misaligned, outside the memory
    addi    a0, s1, 1
    amoadd.d   a2, a5, (a0)         # misaligned (cause 6)
    addi    a0, s1, 2
    amoswap.w  a2, a5, (a0)         # misaligned (6)
    addi    a0, s1, 4
    lr.d    a2, (a0)                # misaligned (4)
    sc.d    a2, a5, (a0)            # misaligned (6)
    lr.d    a2, (s2)
    addi    a0, s2, 2
    sc.w    a3, a5, (a0)            # misaligned (6): the reservation stays
    sc.d    a3, a5, (s2)            # succeeds
    add     s5, s5, a3
    li      a0, 0x10000000
    amoor.d    a2, a5, (a0)         # outside the memory (7)
    lr.w    a2, (a0)                # (5)
    sc.w    a2, a5, (a0)            # (7)
    amoadd.w   a2, a5, (a0)         # (7)

    # ---- 6. AMOs that miss, younger stores' addresses in the SQ by the AMO's try
    la      s2, buf
    li      s3, 0
    li      s4, 256
8:  remu    t0, s3, s7              # a line of part 3's set: the AMO misses often
    mul     t0, t0, s9
    add     a0, s1, t0
    andi    t1, s3, 7
    slli    t1, t1, 3
    add     a0, a0, t1
    ld      a3, 0(s2)
    amoadd.d   a2, s3, (a0)
    sd      a2, 8(s2)               # its address in the SQ early, its data the AMO's result
    sd      s3, 16(s2)
    ld      a4, 16(s2)
    sd      s3, 24(s2)
    sd      a3, 32(s2)
    ld      a5, 8(s2)
    sd      s3, 40(s2)
    ld      a6, 40(s2)
    add     s5, s5, a2
    add     s5, s5, a4
    add     s5, s5, a5
    add     s5, s5, a6
    addi    s3, s3, 1
    bne     s3, s4, 8b
    ld      a2, 24(s2)
    add     s5, s5, a2
    ld      a2, 32(s2)
    add     s5, s5, a2

    # ---- 7. SCs that fail, a load of their word right behind
    la      s2, scw
    li      s3, 0
    li      s4, 16
    li      s6, 0x3c3c3c3c3c3c3c3c
    li      s8, 7
10: SCLD    0
    SCLD    1
    SCLD    2
    SCLD    3
    SCLD    4
    SCLD    5
    SCLD    6
    SCLD    7
    SCLD    8
    SCLD    9
    SCLD    10
    SCLD    11
    SCLD    12
    addi    s3, s3, 1
    bne     s3, s4, 10b
    sd      s5, 0(s0)

    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
7:  j       7b

    .balign 4
handler:
    csrr    t5, mcause
    sd      t5, 0(s0)
    csrr    t5, mtval
    sd      t5, 8(s0)
    addi    s0, s0, 16
    csrr    t5, mepc
    addi    t5, t5, 4               # (every instruction that traps here is 32-bit)
    csrw    mepc, t5
    mret
    .option pop

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0

    .section .data
    .balign 16384
area:  .space 12 * 16384
lrsc:  .dword 0, 0
    .balign 64
buf:   .space 64
scw:   .dword 0, 0                  # part 7's word
sig:   .space 512
