// rvmodel_macros.h : riscv-arch-test's DUT macros for the mmRISC-3 core's
// bench (Plan/CORE.md 5.7, B4). The tests are built as the framework builds
// its signature ELF (-DSIGNATURE), with act_sig_macros.h in place of
// sail_macros.h (riscv_arch_test.h here). The halt is HTIF's (tohost: 1
// passes, 3 fails), what tb_core takes; no console. The bench runs no
// interrupt source in Phase 1, so the interrupt macros are empty and the
// Interrupts tests are not built.
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
#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 1000

#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif
