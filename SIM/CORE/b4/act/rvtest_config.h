// rvtest_config.h : riscv-arch-test's DUT configuration for the mmRISC-3 core
// (Plan/CORE.md 5.7, B4). Written by hand: the ACT4 framework generates it
// from a UDB configuration, a tool this bench does not use. What the core
// has as mmRISC-2 Rev.02's CORE_CSR has it (LOCKSTEP's ISA string): RV64,
// M / S / U, C, the B parts, Zicond, Zicsr, Zifencei, Zicntr, Zihpm (2
// counters), 8 PMP entries (TOR and NAPOT, 4-byte grain), mtvec / stvec
// direct and vectored, the instruction in mtval on an illegal instruction.
// F / D / A are not listed: their tests are not built in Phase 1.
#ifndef RVTEST_CONFIG_H
#define RVTEST_CONFIG_H

#define UDB_MXLEN 64
#define UDB_MXLEN_64
#define UDB_PHYS_ADDR_WIDTH 40

#define I_SUPPORTED
#define M_SUPPORTED
#define C_SUPPORTED
#define ZCA_SUPPORTED
#define ZBA_SUPPORTED
#define ZBB_SUPPORTED
#define ZBC_SUPPORTED
#define ZBS_SUPPORTED
#define ZICOND_SUPPORTED
#define ZICSR_SUPPORTED
#define ZIFENCEI_SUPPORTED
#define ZICNTR_SUPPORTED
#define ZIHPM_SUPPORTED
#define SM_SUPPORTED
#define S_SUPPORTED
#define U_SUPPORTED
#define SM1P12P0_SUPPORTED
#define S1P12P0_SUPPORTED

#define UDB_TIME_CSR_IMPLEMENTED
#define UDB_MCOUNTINHIBIT_IMPLEMENTED
#define UDB_MCOUNTENABLE_EN_0
#define UDB_MCOUNTENABLE_EN_1
#define UDB_MCOUNTENABLE_EN_2
#define UDB_SCOUNTENABLE_EN_0
#define UDB_SCOUNTENABLE_EN_1
#define UDB_SCOUNTENABLE_EN_2
#define UDB_COUNTINHIBIT_EN_0
#define UDB_COUNTINHIBIT_EN_2
#define UDB_HPM_COUNTER_EN_3
#define UDB_HPM_COUNTER_EN_4

#define UDB_MTVEC_MODES_0
#define UDB_MTVEC_MODES_1
#define UDB_MTVEC_BASE_ALIGNMENT_DIRECT 4
#define UDB_MTVEC_BASE_ALIGNMENT_VECTORED 4
#define UDB_STVEC_MODES_0
#define UDB_STVEC_MODES_1
#define UDB_STVEC_BASE_ALIGNMENT_VECTORED 4
#define UDB_REPORT_ENCODING_IN_MTVAL_ON_ILLEGAL_INSTRUCTION
#define UDB_REPORT_ENCODING_IN_STVAL_ON_ILLEGAL_INSTRUCTION

#define UDB_NUM_PMP_ENTRIES 8
#define UDB_NUM_USABLE_PMP_ENTRIES 8
#define UDB_PMP_GRANULARITY 2
#define UDB_PMP_TOR_SUPPORTED
#define UDB_PMP_NAPOT_SUPPORTED

#endif
