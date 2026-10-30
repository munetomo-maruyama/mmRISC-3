/* B2's test programs (gen_b2.py): code at the reference's RAM, tohost after it */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
    . = 0x80000000;
    .text : { *(.text.init) *(.text) }
    . = ALIGN(0x1000);
    .tohost : { *(.tohost) }
}
