#---------------------------------------------------------------------------
# irq.S : B4's directed test of the interrupts (step 1.8 I1, Plan/OOC.md 29.78),
# on OOO_CPU (its CLINT and PLIC, CPU_MMIO) in lock-step with Spike, which takes
# each interrupt where the core took it (SIM/LOCKSTEP); not on OOO_CORE (no CLINT).
#
# 1. The machine timer (mtimecmp = mtime + a delay that changes), 18 times, each
#    over another kind of work: ALU chains, divides, loads and stores that miss,
#    AMOs and LR / SC, CSR writes, loads from a device, FENCE.
# 2. The machine software interrupt (msip), 12 times over the same kinds.
# 3. External interrupts through the PLIC (context 0), sources 1 to 3 from the
#    bench's word IRQ_DEV: claim, the source taken down, complete; 12 times.
# 4. WFI with mstatus.MIE 0: it ends when the timer is pending, no trap; WFI
#    with MIE 1: the interrupt before or after it (then a wait for the count: a
#    WFI returned to after an interrupt taken before it would wait for another).
# 5. The time CSR (rdtime) against the CLINT's mtime: read around it, in order.
# 6. Supervisor mode: SSIP set by S itself, an external interrupt through the
#    PLIC's context 1, and Sstc's timer (stimecmp = time + a delay, menvcfg.STCE),
#    all delegated (mideleg), taken at stvec; then ECALL back.
# The handler (M) uses s7, s10, s11 only; s8 counts the interrupts taken.
#---------------------------------------------------------------------------
    .equ MSIP,      0x02000000
    .equ MTIMECMP,  0x02004000
    .equ MTIME,     0x0200bff8
    .equ PLIC,      0x0c000000
    .equ PEN0,      0x0c002000      # enable, context 0 (M)
    .equ PEN1,      0x0c002080      # enable, context 1 (S)
    .equ PTH0,      0x0c200000      # threshold, context 0
    .equ PCL0,      0x0c200004      # claim / complete, context 0
    .equ PTH1,      0x0c201000
    .equ PCL1,      0x0c201004
    .equ IRQ_DEV,   0x11000000      # the bench's sources: bit s drives the PLIC's source s
    .equ DEV_RAM,   0x11000100      # a word of the bench's device, read as work

    .section .text.init
    .globl _start
_start:
    .option push
    .option norvc
    la      t0, mhandler
    csrw    mtvec, t0
    li      t0, -1                  # PMP: everything for S / U (the core checks none yet; Spike does)
    csrw    pmpaddr0, t0
    li      t0, 0x1f                # NAPOT, R W X
    csrw    pmpcfg0, t0
    la      s0, sig
    la      s1, area                # 64 KB to miss in
    li      s5, 0                   # a sum of the work
    li      s8, 0                   # interrupts taken
    li      s9, 0                   # the round
    li      s6, 0                   # S failed (its bound, or a trap that is not an interrupt)
    # the PLIC: sources 1 to 4 at priority 1; 1 to 3 to context 0, 4 to context 1; thresholds 0
    li      t0, PLIC
    li      t1, 1
    sw      t1, 4(t0)
    sw      t1, 8(t0)
    sw      t1, 12(t0)
    sw      t1, 16(t0)
    li      t0, PEN0
    li      t1, 0xe
    sw      t1, 0(t0)
    li      t0, PEN1
    li      t1, 0x10
    sw      t1, 0(t0)
    li      t0, PTH0
    sw      zero, 0(t0)
    li      t0, PTH1
    sw      zero, 0(t0)
    li      t0, MTIMECMP            # no timer interrupt yet
    li      t1, -1
    sd      t1, 0(t0)
    li      t0, (1 << 7) | (1 << 3) | (1 << 11)     # MTIE, MSIE, MEIE
    csrw    mie, t0
    csrsi   mstatus, 8              # MIE

    # ---- 1. the timer, 18 rounds
1:  addi    s3, s8, 1               # the count to wait for
    li      t0, MTIME
    ld      t1, 0(t0)
    andi    t2, s9, 7
    slli    t2, t2, 3
    addi    t2, t2, 12              # 12 to 68 steps (a step a cycle in the bench)
    add     t1, t1, t2
    li      t0, MTIMECMP
    sd      t1, 0(t0)
    jal     ra, work
    addi    s9, s9, 1
    li      t0, 18
    bltu    s9, t0, 1b

    # ---- 2. software, 12 rounds
    li      s9, 0
2:  addi    s3, s8, 1
    li      t0, MSIP
    li      t1, 1
    sw      t1, 0(t0)
    jal     ra, work
    addi    s9, s9, 1
    li      t0, 12
    bltu    s9, t0, 2b

    # ---- 3. external (PLIC context 0), sources 1, 2, 3 in turn, 12 rounds
    li      s9, 0
3:  addi    s3, s8, 1
    li      t1, 3
    remu    t1, s9, t1
    addi    t1, t1, 1               # the source
    li      t2, 1
    sll     t2, t2, t1
    li      t0, IRQ_DEV
    sw      t2, 0(t0)
    jal     ra, work
    addi    s9, s9, 1
    li      t0, 12
    bltu    s9, t0, 3b

    # ---- 4. WFI: MIE 0 (no trap: it ends when the timer is pending), then MIE 1
    csrci   mstatus, 8
    li      t0, MTIME
    ld      t1, 0(t0)
    addi    t1, t1, 30
    li      t0, MTIMECMP
    sd      t1, 0(t0)
    mv      s3, s8
4:  wfi
    csrr    t1, mip                 # (the core's value)
    andi    t1, t1, 0x80
    beqz    t1, 4b                  # (a WFI may end early: wait again)
    bne     s3, s8, fail            # nothing taken
    li      t0, MTIMECMP
    li      t1, -1
    sd      t1, 0(t0)
    fence                           # (the store at the CLINT before MIE goes on)
    csrsi   mstatus, 8
    addi    s3, s8, 1
    li      t0, MTIME
    ld      t1, 0(t0)
    addi    t1, t1, 400
    li      t0, MTIMECMP
    sd      t1, 0(t0)
    fence
    wfi                             # (the interrupt before it or after it: mepc the WFI or the next)
    li      t3, 100000
5:  addi    t3, t3, -1
    beqz    t3, fail
    bltu    s8, s3, 5b

    # ---- 5. the time CSR between two reads of the CLINT's mtime, and the other way round
    li      t0, MTIME
    li      t3, 8
7:  rdtime  t1
    ld      t2, 0(t0)
    rdtime  t4
    bltu    t2, t1, fail            # time <= mtime <= time, read in that order
    bltu    t4, t2, fail
    beq     t4, t1, fail            # (it counts: a step a cycle in the bench)
    addi    t3, t3, -1
    bnez    t3, 7b

    # ---- 6. supervisor: SSIP, the PLIC's context 1 and Sstc's timer, delegated; ECALL back to M
    li      t0, 1
    slli    t0, t0, 63
    csrs    menvcfg, t0             # STCE: STIP is time >= stimecmp
    csrsi   mcounteren, 2           # TM: S reads time, writes stimecmp
    li      t0, (1 << 1) | (1 << 5) | (1 << 9)     # SSIP, STIP, SEIP to S
    csrw    mideleg, t0
    la      t0, shandler
    csrw    stvec, t0
    la      t0, smode
    csrw    mepc, t0
    li      t0, 3 << 11             # MPP
    csrc    mstatus, t0
    li      t0, 1 << 11             # MPP = S
    csrs    mstatus, t0
    mret

back_m:                             # (from the ECALL of S)
    bnez    s6, fail
    sd      s5, 0(s0)
    sd      s8, 8(s0)
    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
9:  j       9b

fail:
    li      t0, 3
    la      t1, tohost
    sd      t0, 0(t1)
8:  j       8b

# ---- S mode
smode:
    li      t0, (1 << 1) | (1 << 5) | (1 << 9)     # SSIE, STIE, SEIE
    csrw    sie, t0
    csrsi   sstatus, 2              # SIE
    li      s9, 0
6:  addi    s3, s8, 1
    csrsi   sip, 2                  # SSIP, by S itself
    jal     ra, swork
    addi    s3, s8, 1
    li      t0, IRQ_DEV
    li      t1, 1 << 4              # source 4: context 1
    sw      t1, 0(t0)
    jal     ra, swork
    addi    s3, s8, 1
    rdtime  t1                      # Sstc: stimecmp = time + 20 to 68
    andi    t2, s9, 3
    slli    t2, t2, 4
    addi    t2, t2, 20
    add     t1, t1, t2
    csrw    stimecmp, t1
    jal     ra, swork
    addi    s9, s9, 1
    li      t0, 6
    bltu    s9, t0, 6b
    ecall

# work in S until s8 reaches s3 (ALU and loads only), with a bound
swork:
    li      t3, 200000
1:  addi    t3, t3, -1
    beqz    t3, sfail
    andi    t1, t3, 63
    slli    t1, t1, 3
    add     t1, t1, s1
    ld      t2, 0(t1)
    add     s5, s5, t2
    xor     s5, s5, t3
    bltu    s8, s3, 1b
    ret
sfail:
    li      s6, 1
    ecall

# ---- the work of a round, by s9 % 6, until s8 reaches s3 (a bound of 200,000 iterations: fail)
work:
    li      t3, 200000
    li      t4, 6
    remu    t4, s9, t4
1:  addi    t3, t3, -1
    beqz    t3, fail
    beqz    t4, 10f
    li      t5, 1
    beq     t4, t5, 11f
    li      t5, 2
    beq     t4, t5, 12f
    li      t5, 3
    beq     t4, t5, 13f
    li      t5, 4
    beq     t4, t5, 14f
    j       15f
10: addi    s5, s5, 3               # ALU chains
    slli    t1, s5, 3
    xor     s5, s5, t1
    srli    t1, s5, 7
    add     s5, s5, t1
    j       19f
11: ori     t1, t3, 1               # divides
    divu    t2, s5, t1
    remu    t1, s5, t1
    add     s5, s5, t2
    add     s5, s5, t1
    j       19f
12: slli    t1, t3, 7               # loads and stores over 64 KB (misses, dirty victims)
    li      t2, 0xffc0
    and     t1, t1, t2
    add     t1, t1, s1
    ld      t2, 0(t1)
    add     t2, t2, t3
    sd      t2, 8(t1)
    add     s5, s5, t2
    j       19f
13: andi    t1, t3, 7               # AMOs and LR / SC
    slli    t1, t1, 3
    add     t1, t1, s1
    amoadd.d   t2, t3, (t1)
    add     s5, s5, t2
    lr.d    t2, (t1)
    addi    t2, t2, 1
    sc.d    t5, t2, (t1)
    add     s5, s5, t5
    j       19f
14: csrw    mscratch, t3            # CSR writes and reads (non-speculative, at the head)
    csrr    t1, mscratch
    add     s5, s5, t1
    li      t1, DEV_RAM             # a device's load (at the head, the SQ drained)
    lw      t2, 0(t1)
    add     s5, s5, t2
    j       19f
15: sd      t3, 16(s1)              # FENCE between stores and loads
    fence
    ld      t1, 16(s1)
    add     s5, s5, t1
19: bltu    s8, s3, 1b
    ret

    .balign 4
# M: interrupts counted and taken down at their source; S's ECALL goes back to M
mhandler:
    csrr    s10, mcause
    bltz    s10, 1f
    li      s11, 9                  # ECALL from S: on in M
    bne     s10, s11, fail
    la      s10, back_m
    csrw    mepc, s10
    li      s10, 3 << 11
    csrs    mstatus, s10            # MPP = M
    mret
1:  slli    s10, s10, 1
    srli    s10, s10, 1
    add     s5, s5, s10
    addi    s8, s8, 1
    li      s11, 7
    beq     s10, s11, 7f
    li      s11, 3
    beq     s10, s11, 3f
    li      s11, 11
    bne     s10, s11, fail
    li      s11, PCL0               # external: claim, the source down, complete
    lw      s10, 0(s11)
    add     s5, s5, s10
    li      s7, IRQ_DEV
    sw      zero, 0(s7)
    sw      s10, 0(s11)
    mret
7:  li      s11, MTIMECMP           # the timer: mtimecmp out of reach
    li      s10, -1
    sd      s10, 0(s11)
    mret
3:  li      s11, MSIP               # software: msip 0
    sw      zero, 0(s11)
    mret

    .balign 4
# S: SSIP cleared, stimecmp out of reach, or the PLIC's context 1 claimed and completed
shandler:
    csrr    s10, scause
    bgez    s10, sbad
    slli    s10, s10, 1
    srli    s10, s10, 1
    add     s5, s5, s10
    addi    s8, s8, 1
    li      s11, 1
    beq     s10, s11, 1f
    li      s11, 5
    beq     s10, s11, 5f
    li      s11, PCL1
    lw      s10, 0(s11)
    add     s5, s5, s10
    li      s7, IRQ_DEV
    sw      zero, 0(s7)
    sw      s10, 0(s11)
    sret
1:  csrci   sip, 2
    sret
5:  li      s10, -1
    csrw    stimecmp, s10
    sret
sbad:
    li      s6, 1
    ecall
    .option pop

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0

    .section .data
    .balign 4096
area:  .space 65536 + 64
sig:   .space 64
