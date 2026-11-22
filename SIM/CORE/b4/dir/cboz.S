#---------------------------------------------------------------------------
# cboz.S : CBO.ZERO (Zicboz), in lock-step (step 1.8 L1, Plan/OOC.md 29.99).
#
# Linux zeroes its pages with cbo.zero (clear_page, with riscv,cboz-block-size
# in the device tree); no test ran it before L1, whose boot stopped there.
# Self-checking: tohost = 1 on success, (n << 1) | 1 with n the failing part.
#   1  M mode, bare: cbo.zero at an address inside a line (offset 0x13) zeroes
#      that 64-byte line and nothing else (the lines around keep 0xA5..);
#      a second one at the line's start; one on a line just stored to (the
#      store still in the SQ / the D$); one followed at once by loads of it;
#      one on lines of the ELF's data never touched before (the drain misses:
#      the line is filled, then its 8 words written), and one followed at
#      once by a store into its line and loads of that store's bytes (from
#      the younger store) and of the others (zeros: they wait for CBO.ZERO);
#      one followed at once by a load of its own byte (not forwarded)
#   2  S mode, Sv39 (the code under an identity gigapage): cbo.zero at VA
#      0x0000_1040 (a 4 KB page onto pg1) zeroes pg1's line 1, not VA's
#      identity; pg1's other lines keep their bytes
#   3  S mode: a page without W (store page fault, 15, tval the address
#      given), a page not valid (15); the trap handler skips the instruction
#      and, in M, one outside the memory and the devices (an access fault, 7)
#   4  S mode with menvcfg.CBZE 0: an illegal instruction (2)
#   5  U mode with menvcfg.CBZE alone: an illegal instruction; with
#      senvcfg.CBZE as well: its line zeroed
# The trap handler (M) counts the traps and sums mcause and mtval. tp is not 0:
# CBO.ZERO's rs2 field is its immediate (x4), and its zeros are not tp's.
#---------------------------------------------------------------------------
    .equ PTE_V, 1
    .equ PTE_R, 2
    .equ PTE_W, 4
    .equ PTE_X, 8
    .equ PTE_A, 64
    .equ PTE_D, 128

    .macro CBOZ r                       # cbo.zero (\r): MISC-MEM, funct3 2, imm 4
    .insn i 0x0f, 2, x0, \r, 4
    .endm
    .macro FAIL n
    li      a0, (\n << 1) | 1
    j       fail
    .endm
    # \buf[0 .. \n lines) = the pattern 0xA5A5A5A5_00000000 + byte offset
    .macro FILL buf, n
    la      t0, \buf
    li      t1, (\n * 64) / 8
    li      t2, 0xa5a5a5a5
    slli    t2, t2, 32
1:  sd      t2, 0(t0)
    addi    t0, t0, 8
    addi    t2, t2, 8
    addi    t1, t1, -1
    bnez    t1, 1b
    .endm
    # t3 = the sum of the doublewords of \buf's line \k
    .macro LSUM buf, k
    la      t0, \buf + 64 * \k
    li      t1, 8
    li      t3, 0
1:  ld      t2, 0(t0)
    add     t3, t3, t2
    addi    t0, t0, 8
    addi    t1, t1, -1
    bnez    t1, 1b
    .endm
    # fail with \n unless \buf's line \k is the pattern (its sum: 8 x 0xA5A5A5A5 << 32 + offsets)
    .macro KEPT buf, k, n
    LSUM    \buf, \k
    li      t4, 0xa5a5a5a5
    slli    t4, t4, 35
    la      t5, \buf + 64 * \k
    la      t6, \buf
    sub     t5, t5, t6
    slli    t6, t5, 3                   # 8 x the line's first offset
    add     t4, t4, t6
    addi    t4, t4, 0 + 8 * 28          # + 0 + 8 + .. + 56
    bne     t3, t4, 99f
    j       98f
99: FAIL    \n
98:
    .endm
    .macro ZERO buf, k, n               # fail with \n unless \buf's line \k is all zeros
    LSUM    \buf, \k
    beqz    t3, 98f
    FAIL    \n
98:
    .endm

    .section .text.init
    .globl _start
_start:
    .option push
    .option norvc
    la      t0, trap
    csrw    mtvec, t0
    li      t0, -1                      # PMP entry 0: everything, R W X
    srli    t0, t0, 10
    csrw    pmpaddr0, t0
    li      t0, (3 << 3) | 7
    csrw    pmpcfg0, t0
    li      s3, 0                       # the causes' sum
    li      s4, 0                       # the tvals'
    li      s5, 0                       # the traps
    li      s6, 0                       # the ECALLs
    li      tp, -1                      # (the register of CBO.ZERO's rs2 field)

    # ---- 1: M mode, bare
    FILL    buf, 8
    la      a1, buf + 64 * 2 + 0x13
    CBOZ    a1
    KEPT    buf, 1, 1
    ZERO    buf, 2, 1
    KEPT    buf, 3, 1
    la      a1, buf + 64 * 4
    CBOZ    a1
    ZERO    buf, 4, 1
    KEPT    buf, 5, 1
    la      a1, buf + 64 * 6                # a store to the line, then cbo.zero, then a load of it
    li      t0, -1
    sd      t0, 8(a1)
    sd      t0, 48(a1)
    CBOZ    a1
    ld      t1, 8(a1)
    ld      t2, 56(a1)
    or      t1, t1, t2
    beqz    t1, 1f
    FAIL    1
1:  ZERO    buf, 6, 1
    KEPT    buf, 7, 1
    KEPT    buf, 0, 1
    la      a1, cold + 64 + 0x28            # a line never touched (a miss as it drains)
    CBOZ    a1
    la      a2, cold
    ld      t1, 0(a2)                       # the line before: its bytes
    ld      t4, 128(a2)                     # the line after: its bytes
    li      t5, 0x0123456789abcdef
    bne     t1, t5, 2f
    bne     t4, t5, 2f
    ZERO    cold, 1, 1                      # the line: each word
    la      a1, cold + 64 * 3               # a CBO.ZERO, then a store into its line, then loads
    ld      t6, 40(a1)                      # (the line into the D$ first, its old bytes there)
    ld      t5, 56(a1)
    beqz    t6, 2f
    la      t5, pg1                         # stores ahead of it that miss (pg1 / pg2 untouched yet): its entry
    sd      zero, 0x100(t5)                 #  stays in the SQ after its commit, behind their fills
    sd      zero, 0x540(t5)
    la      t5, pg2
    sd      zero, 0x180(t5)
    sd      zero, 0x5c0(t5)
    CBOZ    a1
    ld      t6, 40(a1)                      # another word of its line: zero (it waits for the entry, not the D$'s)
    bnez    t6, 2f
    csrr    t5, mhartid                     # ... and its last word after CBO.ZERO's commit (a CSR read waits for
    add     t5, t5, a1                      #  the head): its entry no longer the one written in the load's E,
    ld      t6, 56(t5)                      #  its 8 words still draining
    bnez    t6, 2f
    lbu     t6, 0(a1)                       # its own byte: zero (not its entry's data: tp's); after the others: a
    bnez    t6, 2f                          #  load that waits is replayed, and what follows it fetched again
    li      t0, 0x5a5a
    sh      t0, 18(a1)
    lhu     t1, 18(a1)                      # the younger store's bytes
    ld      t2, 16(a1)                      # its word: the store's bytes over zeros
    ld      t3, 0(a1)                       # another word: zeros
    li      t4, 0x5a5a
    bne     t1, t4, 2f
    slli    t4, t4, 16
    bne     t2, t4, 2f
    bnez    t3, 2f
    la      a1, cold + 64 * 2               # a CBO.ZERO and at once a load of its own byte (its line in the D$:
    CBOZ    a1                              #  the line-after check above): zero, not its entry's data (tp's)
    lbu     t6, 0(a1)
    bnez    t6, 2f
    j       3f
2:  FAIL    1
3:  li      a1, 0x40000010                  # outside the memory and the devices: an access fault (7)
    CBOZ    a1

    # ---- the tables: root[2] the identity gigapage at 0x8000_0000 (R W X A D);
    #      root[0] -> l1, l1[0] -> l0; l0[1] pg1 (R W A D), l0[2] pg2 (R A: no W), l0[3] not valid
    la      t0, root
    li      t1, (0x80000000 >> 12) << 10 | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    sd      t1, 16(t0)
    la      t1, l1
    srli    t1, t1, 12
    slli    t1, t1, 10
    ori     t1, t1, PTE_V
    sd      t1, 0(t0)
    la      t0, l1
    la      t1, l0
    srli    t1, t1, 12
    slli    t1, t1, 10
    ori     t1, t1, PTE_V
    sd      t1, 0(t0)
    la      t0, l0
    la      t1, pg1
    srli    t1, t1, 12
    slli    t1, t1, 10
    ori     t1, t1, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    sd      t1, 8(t0)
    la      t1, pg2
    srli    t1, t1, 12
    slli    t1, t1, 10
    ori     t1, t1, PTE_V | PTE_R | PTE_A
    sd      t1, 16(t0)
    FILL    pg1, 64
    FILL    pg2, 64
    la      t0, root
    srli    t0, t0, 12
    li      t1, 8 << 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma
    li      t0, 1 << 7                  # menvcfg.CBZE
    csrs    menvcfg, t0
    li      t0, 3 << 11                 # MPP S
    csrc    mstatus, t0
    li      t0, 1 << 11
    csrs    mstatus, t0
    la      t0, s_code
    csrw    mepc, t0
    mret

    # ---- 2, 3 in S mode
s_code:
    li      a1, 0x1040                  # VA page 1, line 1 -> pg1's line 1
    CBOZ    a1
    li      a1, 0x1000
    ld      t1, 64(a1)
    ld      t2, 120(a1)
    or      t1, t1, t2
    beqz    t1, 1f
    FAIL    2
1:  li      a1, 0x2008                  # pg2: no W
    CBOZ    a1
    li      a1, 0x3020                  # not valid
    CBOZ    a1
    ecall                               # back to M (cause 9)
    j       .

    # ---- 4: S mode without CBZE (from M after the ecall)
m_after:
    csrw    satp, zero
    sfence.vma
    ZERO    pg1, 1, 2
    KEPT    pg1, 0, 2
    KEPT    pg1, 2, 2
    KEPT    pg2, 0, 3
    li      t0, 1 << 7
    csrc    menvcfg, t0
    li      t0, 3 << 11
    csrc    mstatus, t0
    li      t0, 1 << 11
    csrs    mstatus, t0
    la      t0, s_code2
    csrw    mepc, t0
    mret
s_code2:
    la      a1, buf
    CBOZ    a1                          # illegal (2)
    ecall
    j       .

    # ---- 5: U mode, menvcfg.CBZE alone, then senvcfg.CBZE too
m_part5:
    KEPT    buf, 0, 4                   # (the illegal one zeroed nothing)
    li      t0, 1 << 7
    csrs    menvcfg, t0
    li      t0, 3 << 11                 # MPP U
    csrc    mstatus, t0
    la      t0, u_code
    csrw    mepc, t0
    mret
u_code:
    la      a1, buf + 8
    CBOZ    a1                          # illegal (2): senvcfg.CBZE 0
    ecall
    j       .
m_part5b:
    KEPT    buf, 0, 5
    li      t0, 1 << 7
    csrs    senvcfg, t0
    li      t0, 3 << 11
    csrc    mstatus, t0
    la      t0, u_code2
    csrw    mepc, t0
    mret
u_code2:
    la      a1, buf + 8
    CBOZ    a1                          # zeroes buf's line 0
    ecall
    j       .

m_end:
    ZERO    buf, 0, 5
    KEPT    buf, 1, 5
    li      t0, 5                       # the traps: 2 page faults, an access fault, 2 illegal
    beq     s5, t0, 1f
    FAIL    3
1:  li      t0, 15 + 15 + 7 + 2 + 2
    beq     s3, t0, 1f
    FAIL    3
1:  li      t0, 0x2008 + 0x3020 + 0x40000010    # the tvals: the addresses given (the illegal ones': the instruction or 0)
    sub     t1, s4, t0
    li      t2, 0x0045a00f              # cbo.zero (a1): its bits, if mtval holds them
    beqz    t1, 1f
    slli    t2, t2, 1
    beq     t1, t2, 1f
    FAIL    3
1:  li      a0, 1
fail:
    la      t1, tohost
    sd      a0, 0(t1)
9:  j       9b

    .balign 4
trap:
    csrr    t5, mcause
    li      t6, 9
    beq     t5, t6, 2f                  # an ECALL from S
    li      t6, 8
    beq     t5, t6, 2f                  # ... or U
    add     s3, s3, t5
    csrr    t6, mtval
    add     s4, s4, t6
    addi    s5, s5, 1
    csrr    t6, mepc
    addi    t6, t6, 4
    csrw    mepc, t6
    mret
2:  addi    s6, s6, 1                   # the ECALLs: on to part 4, 5, 5's second half, the end
    la      t5, m_after
    li      t6, 1
    beq     s6, t6, 3f
    la      t5, m_part5
    li      t6, 2
    beq     s6, t6, 3f
    la      t5, m_part5b
    li      t6, 3
    beq     s6, t6, 3f
    la      t5, m_end
3:  li      t6, 3 << 11                 # stay in M
    csrs    mstatus, t6
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
    .balign 4096
root:   .zero 4096
l1:     .zero 4096
l0:     .zero 4096
pg1:    .zero 4096
pg2:    .zero 4096
    .balign 64
buf:    .zero 64 * 8
    .balign 64
cold:   .rept 64 * 4 / 8                    # the ELF's data, not touched before part 1's CBO.ZEROs
        .dword 0x0123456789abcdef
        .endr
