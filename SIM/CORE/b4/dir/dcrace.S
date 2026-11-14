#---------------------------------------------------------------------------
# dcrace.S : B4's directed test of the D$'s races behind the L2 (step 1.7 H3,
# Plan/OOC.md 29.58), in lock-step. Correct on any L2; mutate_core.py runs it
# on OOO_CPU with an L2 of 4 KB (build_core.sh L2KB=4), where the races open.
#
# 1. A fill over a valid line: 6 lines of one D$ set (256 sets x 4 ways since
#    step 1.7c C2, Plan/OOC.md 29.68: the lines 16 KB apart; 4 KB at 64 sets; the
#    victim at random) loaded round and round, at a word that moves, by loads
#    that do not wait for each other: a load comes to the victim while its
#    words are being replaced (its tag must be invalid by then).
# 2. FENCE.I behind slow writes: 16 lines held by the D$ (sets 0..15), the L2
#    emptied of them by 96 other lines (D$ sets 16..63: they stay in the D$);
#    stores to the 16 (dirty in the D$ since step 1.7b W2: FENCE.I writes them
#    out, and they miss the L2), then a store that rewrites an instruction,
#    FENCE.I, and the instruction called. FENCE.I must write every dirty line
#    out and wait for it to be in memory before the I$ fills again.
# 3. Dirty victims (step 1.7b W2, Plan/OOC.md 29.62): the 6 lines of part 1,
#    each iteration a store into one, then a load from another three lines on:
#    victims are dirty, written out and read back.
#---------------------------------------------------------------------------
    .section .text.init
    .globl _start
_start:
    .option push
    .option norvc
    la      s1, area                # 16 KB aligned: D$ set 0
    li      s2, 4096                # (part 2's page)
    li      s9, 16384               # parts 1 and 3: the D$'s set stride (256 sets of 64 bytes)

    # ---- 1. the lines' words: (line << 8) | word
    li      t0, 0                   # line
1:  mul     t2, t0, s9
    add     t2, t2, s1
    li      t1, 0                   # word
2:  slli    t3, t0, 8
    or      t3, t3, t1
    slli    t4, t1, 3
    add     t4, t4, t2
    sd      t3, 0(t4)
    addi    t1, t1, 1
    li      t5, 8
    bne     t1, t5, 2b
    addi    t0, t0, 1
    li      t5, 6
    bne     t0, t5, 1b

    # ---- 1. round and round: 6 loads an iteration, the word (i * 3) & 7
    li      s3, 0                   # i
    li      s4, 400
    li      s5, 0                   # the sum (lock-step compares each load anyway)
3:  li      t1, 3
    mul     t1, t1, s3
    andi    t1, t1, 7
    slli    t1, t1, 3
    add     t2, s1, t1
    ld      a2, 0(t2)
    add     t2, t2, s9
    ld      a3, 0(t2)
    add     t2, t2, s9
    ld      a4, 0(t2)
    add     t2, t2, s9
    ld      a5, 0(t2)
    add     t2, t2, s9
    ld      a6, 0(t2)
    add     t2, t2, s9
    ld      a7, 0(t2)
    add     s5, s5, a2
    add     s5, s5, a3
    add     s5, s5, a4
    add     s5, s5, a5
    add     s5, s5, a6
    add     s5, s5, a7
    addi    s3, s3, 1
    bne     s3, s4, 3b

    # ---- 2. FENCE.I behind slow writes, 8 times
    la      s6, area2               # the 16 lines: area2 + j * 64, D$ sets 0..15
    la      s7, area3               # the 96: area3 + 1024 + j * 64 and + 4096, D$ sets apart from the 16's
    li      s8, 1                   # the round, the immediate written into `patch`
4:  # the 16 into the D$
    li      t0, 0
5:  slli    t1, t0, 6
    add     t1, t1, s6
    ld      t2, 0(t1)
    addi    t0, t0, 1
    li      t5, 16
    bne     t0, t5, 5b
    # the 96 through the L2 (16 sets of 4 ways: 6 lines each)
    li      t0, 0
6:  slli    t1, t0, 6
    add     t1, t1, s7
    ld      t2, 1024(t1)
    add     t1, t1, s2
    ld      t2, 1024(t1)
    addi    t0, t0, 1
    li      t5, 48
    bne     t0, t5, 6b
    # the 16 written (D$ hits, L2 misses)
    li      t0, 0
7:  slli    t1, t0, 6
    add     t1, t1, s6
    add     t2, s8, t0
    sd      t2, 0(t1)
    addi    t0, t0, 1
    li      t5, 16
    bne     t0, t5, 7b
    # the instruction rewritten: addi a0, zero, s8
    slli    t1, s8, 20
    li      t2, 0x00000513
    or      t1, t1, t2
    la      t3, patch
    sw      t1, 0(t3)
    fence.i
    jal     ra, patch
    add     s5, s5, a0
    addi    s8, s8, 1
    li      t5, 9
    bne     s8, t5, 4b

    # ---- 3. dirty victims: store into line i % 6, word (i * 3) & 7; load line (i + 3) % 6, word (i * 5) & 7
    li      s3, 0                   # i
    li      s4, 600
9:  li      t5, 6
    remu    t0, s3, t5              # the line stored
    li      t1, 3
    mul     t1, t1, s3
    andi    t1, t1, 7
    mul     t2, t0, s9
    add     t2, t2, s1
    slli    t1, t1, 3
    add     t2, t2, t1
    sd      s3, 0(t2)
    addi    t0, s3, 3
    remu    t0, t0, t5              # the line loaded
    li      t1, 5
    mul     t1, t1, s3
    andi    t1, t1, 7
    mul     t2, t0, s9
    add     t2, t2, s1
    slli    t1, t1, 3
    add     t2, t2, t1
    ld      a2, 0(t2)
    add     s5, s5, a2
    addi    s3, s3, 1
    bne     s3, s4, 9b

    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
8:  j       8b

    .balign 64                      # a line of its own
patch:
    addi    a0, zero, 0
    ret
    .balign 64
    .option pop

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0

    .section .data
    .balign 16384
area:  .space 6 * 16384
area2: .space 4096
area3: .space 2 * 4096
