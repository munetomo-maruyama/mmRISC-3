//---------------------------------------------------------------------------
// lockstep.h : lock-step comparison of mmRISC-3 with Spike, at commit
// (Doc/UARCH.md section 7)
//
// The DUT reports every committed instruction as a Commit record, in program
// order (a fused pair as its 2 instructions). For each record the reference,
// Spike's processor_t on a memory of its own loaded from the same ELF file,
// steps one instruction and the two are compared:
//   pc, the instruction, whether it trapped (and the cause), the register it
//   wrote (integer or FP) and the value, the store it made (address, data,
//   size).
// Rules the DUT and its test bench keep so that the two streams can agree:
//   - HTIF: a store to tohost is answered at once (tohost back to 0 before
//     the next instruction reads it); exit is tohost = code << 1 | 1, a
//     character is device 1, command 1 (Plan/icount/port/minilib.c).
//   - Reads of the counters that differ by nature (cycle, time, mcycle, the
//     HPM counters) take the DUT's value: the reference's register is set to
//     it after the step.
//   - The first half of a fused pair whose result is not written (one write
//     per pair, OOO_FUSE W1) sets rd_skip: only its pc and instruction are
//     compared.
// Phase 1 is M-mode, bare metal, without interrupts; interrupts and MMIO
// with side effects come in Phase 2.
//---------------------------------------------------------------------------
#pragma once
#include <cstdint>
#include <memory>
#include <string>

struct Commit {
    uint64_t pc = 0;
    uint32_t insn = 0;         // the instruction bits (a compressed one in the low 16)
    bool     trap = false;     // did not retire: an exception at pc (cause below)
    uint64_t cause = 0;
    int      rd = -1;          // the register written, -1: none (x0 counts as none)
    bool     rd_fp = false;    // rd is an FP register
    uint64_t rd_val = 0;
    bool     rd_skip = false;  // first half of a fused pair, result not written
    bool     st = false;       // a store
    uint64_t st_addr = 0;
    uint64_t st_data = 0;      // the bytes stored, in the low st_size bytes
    int      st_size = 0;
};

struct LockstepCfg {
    std::string elf;
    // the instruction set of mmRISC-2 Rev.02, which mmRISC-3 keeps
    std::string isa = "rv64imafdc_zicboz_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm"
                      "_zba_zbb_zbc_zbs_smcntrpmf_sscofpmf_sstc";
    std::string priv = "MSU";
    uint64_t    mem_base = 0x80000000ull;
    uint64_t    mem_size = 64ull << 20;
    unsigned    pmp_regions = 16;     // mmRISC-2: 8 entries, pmpaddr8 to 15 read 0
};

class Lockstep {
public:
    explicit Lockstep(const LockstepCfg& cfg);
    ~Lockstep();
    // compare one committed instruction of the DUT; false and a reason on a
    // mismatch (the reference has stepped past it either way)
    bool check(const Commit& dut, std::string* why);
    // the reference's own next commit (what a correct DUT reports): for the
    // self-test, and for running the reference alone
    Commit step_ref();
    bool exited() const;        // HTIF exit seen
    int  exit_code() const;
    uint64_t steps() const;     // instructions the reference has stepped
    const std::string& output() const;   // characters printed through HTIF
private:
    struct Impl;
    std::unique_ptr<Impl> p;
};
