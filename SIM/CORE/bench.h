//---------------------------------------------------------------------------
// bench.h : the test bench of the mmRISC-3 core, its C++ side
// (Plan/CORE.md section 5, B0)
//
// What a Verilator bench of OOO_CORE (and the stand-in core of standin.cc)
// needs around the core:
//   Memory     the DUT's memory: sparse 4 KB pages over one RAM region
//              (0x8000_0000, 64 MB, as LOCKSTEP's reference), loaded from
//              an ELF file. The models of the core's I$ / D$ ports (B1, B3)
//              and later the AXI4 model read and write it; write() calls a
//              hook, through which HTIF sees what reaches the memory.
//   Htif       tohost / fromhost. The exit and the console are taken from
//              the committed stores (program order, whatever the store
//              queue and the D$ still hold); tohost is put back to 0 in the
//              memory at the tick after a write that makes it nonzero
//              reaches it (mmRISC-2's tb_CORE did the same). A loop polling
//              tohost may so run longer in the core than in Spike: LOCKSTEP
//              gives the reference the core's value for such loads.
//   TraceSlot  the core's commit-trace port (simulation only): one µop per
//              slot (a fused pair: 2 instructions, one register write),
//              slots in program order; turned into LOCKSTEP's Commit
//              records, one per instruction.
//   Bench      all of it: commit() with each cycle's slots, tick() once a
//              cycle; lock-step with Spike at every instruction, a watchdog,
//              the architectural memory (the ELF image with the committed
//              stores: the signature of riscv-arch-test comes from it, not
//              from a memory behind a write-back D$), the result.
//---------------------------------------------------------------------------
#pragma once
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "../LOCKSTEP/lockstep.h"

// ---- the memory: sparse pages over [base, base + size)
class Memory {
public:
    static const uint64_t PAGE = 4096;
    Memory(uint64_t base, uint64_t size) : base(base), size(size) {}
    bool contains(uint64_t a, uint64_t n = 1) const { return a >= base && n <= size && a - base <= size - n; }
    uint8_t* page(uint64_t a);                              // a's page (allocated zeroed), nullptr outside
    void read(uint64_t a, void* p, size_t n);               // bytes outside the region read 0
    void write(uint64_t a, const void* p, size_t n);        // then on_write(a, n)
    void poke(uint64_t a, const void* p, size_t n);         // no hook (loader, HTIF)
    uint64_t read64(uint64_t a) { uint64_t v; read(a & ~7ull, &v, 8); return v; }
    void write64(uint64_t a, uint64_t d, uint8_t mask);     // the bytes of the 8-byte word at a with mask set
    std::vector<uint64_t> pages() const;                    // the pages allocated, in address order
    std::function<void(uint64_t, size_t)> on_write;
    const uint64_t base, size;
private:
    std::unordered_map<uint64_t, std::unique_ptr<uint8_t[]>> pg;
};

// ---- an ELF64 executable: loadable segments and its symbols
struct ElfImage {
    uint64_t entry = 0;
    std::vector<std::pair<uint64_t, std::vector<uint8_t>>> segs;   // paddr, bytes (memsz)
    std::map<std::string, uint64_t> sym;
    uint64_t symbol(const std::string& s) const { auto i = sym.find(s); return i == sym.end() ? 0 : i->second; }
};
ElfImage load_elf_image(const std::string& path);
void load_into(const ElfImage& e, Memory& m);              // throws if a segment is outside the memory

// ---- HTIF
class Htif {
public:
    Htif(uint64_t tohost, uint64_t fromhost) : tohost(tohost), fromhost(fromhost) {}
    // a committed store: the exit or a character when it makes tohost nonzero
    // (the program's tohost then counts as 0 again); true if it did
    bool commit_store(uint64_t addr, uint64_t data, int size);
    // a write reached the memory: tohost to 0 at the next tick if not 0
    void mem_write(uint64_t a, size_t n, Memory& m);
    void tick(Memory& m);
    bool exited = false;
    int code = 0;
    std::string out;
    const uint64_t tohost, fromhost;
private:
    uint64_t shadow = 0;       // tohost as the committed stores left it
    bool zero = false;
};

// ---- the commit-trace port, one slot (a µop)
struct TraceStore {
    bool     v = false;
    uint64_t addr = 0;
    uint64_t data = 0;         // in the low size bytes
    int      size = 0;
};
struct TraceSlot {
    uint64_t pc = 0;
    uint32_t insn[2] = {0, 0}; // the instructions (a compressed one in the low 16)
    bool     pair = false;     // a fused pair: insn[1] at pc + the length of insn[0]
    bool     trap = false;     // an exception at pc (never a pair: a pair that faults is fetched again unfused)
    uint64_t cause = 0;
    int      rd = -1;          // the µop's register write (-1: none)
    bool     rd_fp = false;
    uint64_t rd_val = 0;
    bool     wr_first = false; // a pair's write is its first instruction's (ALU + branch), else the second's
    TraceStore st[2];          // the store of each instruction
};
// the slot's Commit records (1, or 2 for a pair; a first half that is not a
// store and does not write is marked rd_skip); returns their number
int to_commits(const TraceSlot& s, Commit out[2]);

// ---- the bench
struct BenchCfg {
    std::string elf;
    bool        lockstep = true;        // compare with Spike at every instruction
    uint64_t    max_cycles = 200000000;
    uint64_t    hang_cycles = 100000;   // cycles without a commit
    std::string signature;              // file for [begin_signature, end_signature) at the exit
    int         tail = 16;              // commits shown when a run fails
    LockstepCfg ref;                    // the reference's machine (its elf is set from elf)
};

class Bench {
public:
    explicit Bench(const BenchCfg& cfg);
    ~Bench();
    Memory& mem() { return *m; }
    Memory& arch() { return *a; }       // the ELF image with the committed stores
    uint64_t entry() const { return img.entry; }
    uint64_t symbol(const std::string& s) const { return img.symbol(s); }
    // one cycle's commit-trace port: n slots, oldest first. false: the run
    // is over (the exit, or a failure)
    bool commit(const TraceSlot* s, int n);
    // once a cycle, after commit(): HTIF's memory side and the watchdog
    bool tick();
    bool done() const { return over; }
    // ran to the HTIF exit without a mismatch (and, under lock-step, with the
    // reference's exit code and console); the program's own verdict is
    // exit_code()
    bool passed() const { return over && err.empty(); }
    int exit_code() const { return h->code; }
    const std::string& output() const { return h->out; }
    const std::string& error() const { return err; }
    std::string summary(const std::string& name) const;
    uint64_t cycles = 0, insns = 0, uops = 0;
private:
    void fail(const std::string& why);
    void finish();
    BenchCfg c;
    ElfImage img;
    std::unique_ptr<Memory> m, a;
    std::unique_ptr<Htif> h;
    std::unique_ptr<Lockstep> ref;
    std::deque<Commit> last;            // the last commits, for a failure's report
    uint64_t last_commit_cycle = 0;
    bool over = false;
    std::string err;
    struct Dis;
    std::unique_ptr<Dis> dis;
};
