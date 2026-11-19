#---------------------------------------------------------------------------
# pmpx.S : PMP on the fetch, word by word (step 1.8 P1, Plan/OOC.md 29.89), in lock-step.
#
# U-mode code runs one 32-bit instruction (addi a0, a0, 1) and ECALLs; PMP entry 0 is a
# 4-byte region (NA4) without X, entry 1 everything (NAPOT, R W X). The core fetches 32
# bytes at a time and checks each word; Spike checks each 16-bit piece:
#   A  the instruction at a block's last parcel (+30), its second half in the next
#      block, whose word 0 is denied: an access fault, tval its pc + 2
#   B  the same place, the block's word 7 (its first half) denied: tval its pc
#   C  at +2 of a block (words 0 and 1), word 1 denied: tval its pc + 2
#   D  nothing denied: it runs, then ECALL
# The M-mode handler sums mcause, mtval and mepc and goes on with the next case.
#---------------------------------------------------------------------------
    .equ CFG_NA4, (2 << 3)
    .equ CFG_NAPOT_RWX, (3 << 3) | 7

    .macro CASE target, deny
    la      t0, \deny
    srli    t0, t0, 2
    csrw    pmpaddr0, t0
    li      t0, -1
    srli    t0, t0, 10
    csrw    pmpaddr1, t0                # everything (NAPOT, all ones)
    li      t0, CFG_NA4 | (CFG_NAPOT_RWX << 8)
    csrw    pmpcfg0, t0
    la      t0, \target
    csrw    mepc, t0
    la      s9, 1f                      # where the handler goes on
    li      a0, 0
    mret
1:  slli    s2, s2, 5
    add     s2, s2, a0
    .endm

    .section .text.init
    .globl _start
_start:
    .option push
    .option norvc
    la      t0, trap
    csrw    mtvec, t0
    li      s2, 0
    li      s3, 0
    li      s4, 0
    li      s5, 0
    li      t0, 3 << 11
    csrc    mstatus, t0                 # MPP U
    CASE    blkA + 30, blkA + 32
    CASE    blkB + 30, blkB + 28
    CASE    blkC + 2, blkC + 4
    CASE    blkD + 2, blkA              # (denies a word far from it)
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
    add     s3, s3, t5
    csrr    t6, mtval
    add     s4, s4, t6
    csrr    t6, mepc
    add     s5, s5, t6
    jr      s9                          # (in M mode: the next case)

    # ---- the code blocks (each 32-byte block has its own words)
    .balign 64
blkA:
    .skip   30, 0
    .2byte  0x0513                      # addi a0, a0, 1: its lower half at +30
    .2byte  0x0015                      # ... its upper half at +32 (the next block's word 0)
    ecall
    .balign 64
blkB:
    .skip   30, 0
    .2byte  0x0513
    .2byte  0x0015
    ecall
    .balign 64
blkC:
    .skip   2, 0
    .2byte  0x0513                      # at +2: words 0 and 1
    .2byte  0x0015
    ecall
    .balign 64
blkD:
    .skip   2, 0
    .2byte  0x0513
    .2byte  0x0015
    ecall
    .option pop

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
    .section .data
sig:    .zero 32
