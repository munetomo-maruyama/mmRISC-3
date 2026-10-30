# htif.S : B3's console test: characters through tohost (HTIF device 1,
# command 1), each followed by the loop that waits for tohost to go back
# to 0 (the bench clears it from the memory side: the D$ must not keep
# tohost's line, Plan/CORE.md 5.1 rule 2), then the exit (1).
    .section .text.init
    .globl _start
_start:
    la   s0, tohost
    la   s1, msg
    li   s2, 0x0101000000000000      # device 1, command 1: putchar
1:  lbu  a0, 0(s1)
    beqz a0, 3f
    or   a0, a0, s2
    sd   a0, 0(s0)
2:  ld   t0, 0(s0)                   # wait for the host
    bnez t0, 2b
    addi s1, s1, 1
    j    1b
3:  li   a0, 1
    sd   a0, 0(s0)
4:  j    4b
    .section .data
msg: .string "B3: hello through tohost\n"
    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost: .dword 0
    .align 6
    .globl fromhost
fromhost: .dword 0
