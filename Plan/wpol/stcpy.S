    .section .text.init
    .globl _start
_start:
    la      s1, src
    la      s2, dst
    # warm: both buffers into the D$ (4 KB each)
    li      t0, 0
1:  add     t1, s1, t0
    ld      t2, 0(t1)
    add     t1, s2, t0
    ld      t2, 0(t1)
    addi    t0, t0, 64
    li      t5, 4096
    bne     t0, t5, 1b
    li      s3, 16                  # passes
    .globl start_time
start_time:
2:  mv      a0, s2
    mv      a1, s1
    li      a2, 64                  # lines
3:
    ld      t0, 0(a1)
    sd      t0, 0(a0)
    ld      t1, 8(a1)
    sd      t1, 8(a0)
    ld      t2, 16(a1)
    sd      t2, 16(a0)
    ld      t3, 24(a1)
    sd      t3, 24(a0)
    ld      t0, 32(a1)
    sd      t0, 32(a0)
    ld      t1, 40(a1)
    sd      t1, 40(a0)
    ld      t2, 48(a1)
    sd      t2, 48(a0)
    ld      t3, 56(a1)
    sd      t3, 56(a0)
    addi    a0, a0, 64
    addi    a1, a1, 64
    addi    a2, a2, -1
    bnez    a2, 3b
    addi    s3, s3, -1
    bnez    s3, 2b
    .globl stop_time
stop_time:
    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
4:  j       4b
    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
    .section .data
    .balign 4096
src: .space 4096
dst: .space 4096
