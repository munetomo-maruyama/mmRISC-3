/* link.ld : a C program on the bare machine of Spike (the link.ld of mmRISC-2
   SIM/SIM_SYS/bench). Everything follows everything from 0x8000_0000;
   Spike finds tohost and fromhost by their symbols. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;
    .text   : { *(.text.init) *(.text) *(.text.*) }
    .rodata : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) }
    .data   : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) }
    . = ALIGN(64);
    .tohost : { *(.tohost) }
    . = ALIGN(64);
    .bss    : { __bss_start = .; *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON)
                . = ALIGN(8); __bss_end = .; }
}
