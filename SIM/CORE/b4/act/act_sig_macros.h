// act_sig_macros.h : what tests/env/sail_macros.h does for a signature
// build, less Sail's platform (Plan/CORE.md 5.7). The bench's reference
// (LOCKSTEP) has one RAM region and no MMIO, and the core has no interrupt
// source in Phase 1: the halt and the console are rvmodel_macros.h's HTIF,
// the interrupt macros stay empty, and the one write to Sail's CLINT the
// boot does (mtimecmp parked at all ones) goes to act_mtimecmp, a word in
// the image (rvmodel_macros.h's data section).
#ifndef _ACT_SIG_MACROS_H
#define _ACT_SIG_MACROS_H

// as sail_macros.h: no invisible trap emulation, no Smrnmi in the signature build
#undef RVTEST_EMULATE_TIME_CSR
#undef RVMODEL_INVISIBLE_TRAP_HANDLER
#undef SMRNMI_SUPPORTED

#define SAIL_MTIMECMP_ADDRESS act_mtimecmp

#endif
