#---------------------------------------------------------------------------
# devld.S : loads from a device at the ROB head with nothing else in flight
# (step 1.8 I1, Plan/OOC.md 29.78): such a load waits in its LQ entry until it is
# the head and the SQ is drained, and no event may come to try it again (no store,
# no miss, nothing younger on the LSU's port 0), so it must be marked to be tried
# as it waits. Then after a store to the device, and two in a row. The device is
# the bench's word (IRQ_DEV + 0x100: OOO_CPU's AxiLite keeps it, OOO_CORE's
# UcModel reads 0), a device for the lock-step too (the core's value is taken).
#---------------------------------------------------------------------------
    .equ DEV, 0x11000100
    .section .text.init
    .globl _start
_start:
    .option push
    .option norvc
    li      s5, 0
    li      t0, DEV
    ld      t1, 0(t0)               # the first load of all: nothing before it, only ALU work after
    add     s5, s5, t1
    li      t3, 40
1:  addi    t3, t3, -1
    add     s5, s5, t3
    bnez    t3, 1b
    li      t2, 0x5a5a
    sd      t2, 0(t0)               # a store to the device, then loads of it
    ld      t1, 0(t0)
    add     s5, s5, t1
    lw      t1, 4(t0)
    add     s5, s5, t1
    li      t3, 40
2:  addi    t3, t3, -1
    mul     s5, s5, t3
    bnez    t3, 2b
    ld      t1, 0(t0)               # alone again, a multiply chain behind it
    add     s5, s5, t1
    la      t0, sig
    sd      s5, 0(t0)
    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
9:  j       9b
    .option pop

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
    .section .data
sig: .dword 0
