// rvmodel_macros.h : riscv-arch-test's DUT macros for the mmRISC-3 core's
// bench (Plan/CORE.md 5.7, B4). The tests are built as the framework builds
// its signature ELF (-DSIGNATURE), with act_sig_macros.h in place of
// sail_macros.h (riscv_arch_test.h here). The halt is HTIF's (tohost: 1
// passes, 3 fails), what tb_core takes; no console. The interrupts (step 1.8
// I1, Plan/OOC.md 29.78): with MMRISC_IRQ (build.sh: the Interrupts groups,
// run on OOO_CPU alone) the macros raise them on OOO_CPU's CLINT (msip,
// mtimecmp) and PLIC (source 1 to context 0, source 2 to context 1, from the
// bench's word IRQ_DEV, tb_core.cpp); without it they stay empty, as before.
#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 8; .global tohost; tohost: .dword 0;         \
        .balign 8; .global fromhost; fromhost: .dword 0;     \
        .balign 8; .global act_mtimecmp; act_mtimecmp: .dword 0; \
        .popsection;

#define STANDARD_SM_SUPPORTED

// The core's registers come out of reset unknown (the PRF has no reset), and
// the trap handler saves registers the test has not written yet: clear them,
// as a boot ROM would.
#define RVMODEL_BOOT \
  .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31 ;\
    li x\r, 0 ;\
  .endr ;

#define RVMODEL_HALT_PASS  \
  li x1, 1                ;\
  la t0, tohost           ;\
  sd x1, 0(t0)            ;\
1: j 1b                   ;

#define RVMODEL_HALT_FAIL \
  li x1, 3                ;\
  la t0, tohost           ;\
  sd x1, 0(t0)            ;\
1: j 1b                   ;

#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

// no RVMODEL_ACCESS_FAULT_ADDRESS: the core has no access faults in Phase 1
// (the I$ / D$ errors are not wired; the assembly's memory map, Plan/CORE.md)
#define RVMODEL_TIMER_INT_SOON_DELAY 1000

#ifdef MMRISC_IRQ
// (a device's store lands after its commit and the SQ's drain: the wait is long enough for it)
#define RVMODEL_INTERRUPT_LATENCY 400
#define RVMODEL_MTIME_ADDRESS    0x0200BFF8
#define RVMODEL_MTIMECMP_ADDRESS 0x02004000
#define RVMODEL_MSIP_ADDRESS     0x02000000
#define RVMODEL_SET_MSW_INT(_R1, _R2) \
  li _R1, 0x02000000; li _R2, 1; sw _R2, 0(_R1);
#define RVMODEL_CLR_MSW_INT(_R1, _R2) \
  li _R1, 0x02000000; sw x0, 0(_R1);
// the PLIC's source 1 to context 0 (M): priority 1, enabled, threshold 0, then the bench's line up
#define RVMODEL_SET_MEXT_INT(_R1, _R2) \
  li _R1, 0x0C000004; li _R2, 1; sw _R2, 0(_R1); \
  li _R1, 0x0C002000; li _R2, 2; sw _R2, 0(_R1); \
  li _R1, 0x0C200000; sw x0, 0(_R1); \
  li _R1, 0x11000000; lw _R2, 0(_R1); ori _R2, _R2, 2; sw _R2, 0(_R1);
// the line down, then claim and complete (a claim of nothing reads 0, and its completion does nothing)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2) \
  li _R1, 0x11000000; lw _R2, 0(_R1); andi _R2, _R2, -3; sw _R2, 0(_R1); \
  li _R1, 0x0C200004; lw _R2, 0(_R1); sw _R2, 0(_R1);
// the PLIC's source 2 to context 1 (S)
#define RVMODEL_SET_SEXT_INT(_R1, _R2) \
  li _R1, 0x0C000008; li _R2, 1; sw _R2, 0(_R1); \
  li _R1, 0x0C002080; li _R2, 4; sw _R2, 0(_R1); \
  li _R1, 0x0C201000; sw x0, 0(_R1); \
  li _R1, 0x11000000; lw _R2, 0(_R1); ori _R2, _R2, 4; sw _R2, 0(_R1);
#define RVMODEL_CLR_SEXT_INT(_R1, _R2) \
  li _R1, 0x11000000; lw _R2, 0(_R1); andi _R2, _R2, -5; sw _R2, 0(_R1); \
  li _R1, 0x0C201004; lw _R2, 0(_R1); sw _R2, 0(_R1);
#else
#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)
#endif

#endif
