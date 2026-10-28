//---------------------------------------------------------------------------
// lockstep.cc : the reference of the lock-step comparison (lockstep.h)
//
// Spike is used as a library (libriscv of spike-install): a processor_t on a
// simif_t of our own (one RAM region, no devices), stepped one instruction
// at a time, its commit log (log_reg_write / log_mem_write, keyed reg << 4 |
// type: 0 integer, 1 FP, 4 CSR) read after each step. Whether the step
// retired an instruction or took a trap is told by minstret.
//---------------------------------------------------------------------------
#include "lockstep.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <vector>

#include "riscv/cfg.h"
#include "riscv/encoding.h"
#include "riscv/isa_parser.h"
#include "riscv/mmu.h"
#include "riscv/processor.h"
#include "riscv/simif.h"

namespace {

// ---- a minimal ELF64 loader: PT_LOAD segments, and the symbols tohost and
// fromhost
struct Elf {
    uint64_t entry = 0, tohost = 0, fromhost = 0;
    std::vector<std::pair<uint64_t, std::vector<uint8_t>>> segs;   // paddr, bytes (memsz)
};

template <class T> T rd_le(const std::vector<uint8_t>& f, size_t o)
{
    if (o + sizeof(T) > f.size()) throw std::runtime_error("ELF: truncated");
    T v; std::memcpy(&v, &f[o], sizeof(T)); return v;
}

Elf load_elf(const std::string& path)
{
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open " + path);
    std::vector<uint8_t> f((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (f.size() < 64 || std::memcmp(f.data(), "\177ELF", 4) || f[4] != 2)
        throw std::runtime_error(path + ": not an ELF64 file");
    Elf e;
    e.entry = rd_le<uint64_t>(f, 24);
    uint64_t phoff = rd_le<uint64_t>(f, 32), shoff = rd_le<uint64_t>(f, 40);
    uint16_t phentsize = rd_le<uint16_t>(f, 54), phnum = rd_le<uint16_t>(f, 56);
    uint16_t shentsize = rd_le<uint16_t>(f, 58), shnum = rd_le<uint16_t>(f, 60);
    for (unsigned i = 0; i < phnum; i++) {
        size_t ph = phoff + (size_t)i * phentsize;
        if (rd_le<uint32_t>(f, ph) != 1) continue;               // PT_LOAD
        uint64_t off = rd_le<uint64_t>(f, ph + 8), paddr = rd_le<uint64_t>(f, ph + 24);
        uint64_t filesz = rd_le<uint64_t>(f, ph + 32), memsz = rd_le<uint64_t>(f, ph + 40);
        if (off + filesz > f.size()) throw std::runtime_error("ELF: segment past the end");
        std::vector<uint8_t> b(memsz, 0);
        std::memcpy(b.data(), &f[off], filesz);
        e.segs.push_back({paddr, std::move(b)});
    }
    // the symbol table: tohost, fromhost
    for (unsigned i = 0; i < shnum; i++) {
        size_t sh = shoff + (size_t)i * shentsize;
        if (rd_le<uint32_t>(f, sh + 4) != 2) continue;           // SHT_SYMTAB
        uint64_t off = rd_le<uint64_t>(f, sh + 24), size = rd_le<uint64_t>(f, sh + 32);
        uint32_t link = rd_le<uint32_t>(f, sh + 40);
        size_t str = shoff + (size_t)link * shentsize;
        uint64_t stroff = rd_le<uint64_t>(f, str + 24);
        for (uint64_t s = off; s + 24 <= off + size; s += 24) {
            uint32_t name = rd_le<uint32_t>(f, s);
            if (stroff + name >= f.size()) continue;
            const char* n = (const char*)&f[stroff + name];
            if (!std::strcmp(n, "tohost")) e.tohost = rd_le<uint64_t>(f, s + 8);
            if (!std::strcmp(n, "fromhost")) e.fromhost = rd_le<uint64_t>(f, s + 8);
        }
    }
    return e;
}

// ---- the memory of the reference: one RAM region, no MMIO
class Mem : public simif_t {
public:
    Mem(const LockstepCfg& c, cfg_t* cfg) : base(c.mem_base), ram(c.mem_size, 0), cfg(cfg) {}
    char* addr_to_mem(reg_t a) override
    {
        return (a >= base && a - base < ram.size()) ? (char*)&ram[a - base] : nullptr;
    }
    bool mmio_load(reg_t, size_t, uint8_t*) override { return false; }
    bool mmio_store(reg_t, size_t, const uint8_t*) override { return false; }
    void proc_reset(unsigned) override {}
    const cfg_t& get_cfg() const override { return *cfg; }
    const std::map<size_t, processor_t*>& get_harts() const override { return harts; }
    const char* get_symbol(uint64_t) override { return nullptr; }
    uint64_t base;
    std::vector<uint8_t> ram;
    cfg_t* cfg;
    std::map<size_t, processor_t*> harts;
};

// the counters whose reads differ between a real core and Spike by nature
bool counter_csr(unsigned csr)
{
    return csr == CSR_CYCLE || csr == CSR_TIME || csr == CSR_MCYCLE ||
           (csr >= CSR_HPMCOUNTER3 && csr <= CSR_HPMCOUNTER31) ||
           (csr >= CSR_MHPMCOUNTER3 && csr <= CSR_MHPMCOUNTER31);
}

std::string hex(uint64_t v)
{
    char b[24]; std::snprintf(b, sizeof b, "%llx", (unsigned long long)v); return b;
}

}  // namespace

struct Lockstep::Impl {
    LockstepCfg c;
    cfg_t cfg;
    std::unique_ptr<isa_parser_t> isa;
    std::unique_ptr<Mem> mem;
    std::unique_ptr<processor_t> proc;
    FILE* devnull = nullptr;
    std::ostringstream sout;
    uint64_t tohost = 0, fromhost = 0, nsteps = 0;
    bool htif_load = false;     // the last step read tohost or fromhost
    bool exited = false;
    int code = 0;
    std::string out;

    explicit Impl(const LockstepCfg& lc) : c(lc)
    {
        Elf e = load_elf(c.elf);
        if (!e.tohost) throw std::runtime_error(c.elf + ": no tohost symbol");
        tohost = e.tohost;
        fromhost = e.fromhost ? e.fromhost : e.tohost + 8;
        cfg.isa = c.isa.c_str();
        cfg.priv = c.priv.c_str();
        cfg.misaligned = false;                    // misaligned accesses trap, as in mmRISC-2
        cfg.pmpregions = c.pmp_regions;
        cfg.mem_layout = {mem_cfg_t(c.mem_base, c.mem_size)};
        cfg.start_pc = e.entry;
        cfg.hartids = {0};
        isa.reset(new isa_parser_t(cfg.isa, cfg.priv));
        mem.reset(new Mem(c, &cfg));
        for (auto& s : e.segs) {
            char* m = mem->addr_to_mem(s.first);
            if (!m || !mem->addr_to_mem(s.first + s.second.size() - 1))
                throw std::runtime_error("ELF segment at 0x" + hex(s.first) + " outside the memory");
            std::memcpy(m, s.second.data(), s.second.size());
        }
        devnull = std::fopen("/dev/null", "w");
        proc.reset(new processor_t(isa.get(), &cfg, mem.get(), 0, false, devnull, sout));
        mem->harts[0] = proc.get();
        proc->enable_log_commits();                 // fills log_reg_write / log_mem_write
        proc->get_state()->pc = e.entry;
    }
    ~Impl() { proc.reset(); if (devnull) std::fclose(devnull); }

    uint32_t fetch(uint64_t pc)
    {
        char* m = mem->addr_to_mem(pc);
        if (!m) return 0;
        uint16_t lo; std::memcpy(&lo, m, 2);
        if ((lo & 3) != 3) return lo;
        uint32_t w; std::memcpy(&w, m, 4); return w;
    }

    // HTIF on a store to tohost: answered at once. Device 0 command 0 with
    // bit 0 set is the exit (code in the payload above bit 0), device 1
    // command 1 a character; the device must be checked first, since a
    // character's payload can have bit 0 set too
    void htif()
    {
        uint64_t* t = (uint64_t*)mem->addr_to_mem(tohost);
        if (!t || !*t) return;
        uint64_t v = *t;
        unsigned dev = (unsigned)(v >> 56), cmd = (unsigned)(v >> 48) & 0xff;
        if (dev == 0 && cmd == 0 && (v & 1)) { exited = true; code = (int)((v << 16) >> 17); }   // exit
        else if (dev == 1 && cmd == 1) out += (char)(v & 0xff);                                // a character
        *t = 0;
    }

    // one step of the reference, as a Commit record
    Commit step()
    {
        state_t* s = proc->get_state();
        Commit r;
        r.pc = s->pc;
        r.insn = fetch(r.pc);
        reg_t inst0 = proc->get_csr(CSR_MINSTRET);
        proc->step(1);
        nsteps++;
        htif_load = false;
        for (auto& m : s->log_mem_read) {
            uint64_t a = std::get<0>(m), e = a + std::get<2>(m);
            if ((a < tohost + 8 && e > tohost) || (a < fromhost + 8 && e > fromhost)) htif_load = true;
        }
        if (proc->get_csr(CSR_MINSTRET) == inst0) {          // a trap, not retired
            r.trap = true;
            r.cause = (s->prv == PRV_S) ? proc->get_csr(CSR_SCAUSE) : proc->get_csr(CSR_MCAUSE);
            return r;
        }
        for (auto& w : s->log_reg_write) {
            unsigned type = w.first & 0xf, reg = (unsigned)(w.first >> 4);
            if ((type == 0 && reg != 0) || type == 1) {
                r.rd = (int)reg; r.rd_fp = type == 1; r.rd_val = w.second.v[0];
            }
        }
        for (auto& m : s->log_mem_write) {
            r.st = true;
            r.st_addr = std::get<0>(m); r.st_data = std::get<1>(m); r.st_size = std::get<2>(m);
        }
        htif();
        return r;
    }
};

Lockstep::Lockstep(const LockstepCfg& cfg) : p(new Impl(cfg)) {}
Lockstep::~Lockstep() = default;
bool Lockstep::exited() const { return p->exited; }
int Lockstep::exit_code() const { return p->code; }
uint64_t Lockstep::steps() const { return p->nsteps; }
const std::string& Lockstep::output() const { return p->out; }
Commit Lockstep::step_ref() { return p->step(); }

bool Lockstep::check(const Commit& d, std::string* why)
{
    Commit r = p->step();
    auto bad = [&](const std::string& s) {
        if (why) *why = "pc " + hex(r.pc) + ": " + s;
        return false;
    };
    if (d.pc != r.pc) return bad("pc: DUT " + hex(d.pc) + ", reference " + hex(r.pc));
    uint32_t mask = ((r.insn & 3) == 3) ? 0xffffffffu : 0xffffu;
    if ((d.insn & mask) != r.insn) return bad("instruction: DUT " + hex(d.insn) + ", reference " + hex(r.insn));
    if (d.trap != r.trap) return bad(std::string("trap: DUT ") + (d.trap ? "yes" : "no") + ", reference " + (r.trap ? "yes" : "no"));
    if (r.trap) {
        if (d.cause != r.cause) return bad("cause: DUT " + hex(d.cause) + ", reference " + hex(r.cause));
        return true;
    }
    // a counter read, and a load of tohost or fromhost, take the DUT's value
    unsigned opc = r.insn & 0x7f, f3 = (r.insn >> 12) & 7;
    if (((opc == 0x73 && f3 != 0 && f3 != 4 && counter_csr(r.insn >> 20)) || p->htif_load) && r.rd > 0 && !r.rd_fp) {
        p->proc->get_state()->XPR.write(r.rd, d.rd_val);
        r.rd_val = d.rd_val;
    }
    if (d.rd_skip) {
        if (d.st || r.st) return bad("a store marked as the first half of a fused pair");
        return true;                                   // the register is compared after the second half
    }
    if (d.rd != r.rd || (r.rd >= 0 && d.rd_fp != r.rd_fp))
        return bad("register written: DUT " + std::string(d.rd_fp ? "f" : "x") + std::to_string(d.rd) +
                   ", reference " + (r.rd_fp ? "f" : "x") + std::to_string(r.rd));
    if (r.rd >= 0 && d.rd_val != r.rd_val)
        return bad("value of " + std::string(r.rd_fp ? "f" : "x") + std::to_string(r.rd) + ": DUT " +
                   hex(d.rd_val) + ", reference " + hex(r.rd_val));
    if (d.st != r.st) return bad(std::string("store: DUT ") + (d.st ? "yes" : "no") + ", reference " + (r.st ? "yes" : "no"));
    if (r.st) {
        uint64_t m = r.st_size >= 8 ? ~0ull : ((1ull << (8 * r.st_size)) - 1);
        if (d.st_addr != r.st_addr || d.st_size != r.st_size || ((d.st_data ^ r.st_data) & m))
            return bad("store: DUT " + hex(d.st_addr) + "/" + std::to_string(d.st_size) + "/" + hex(d.st_data & m) +
                       ", reference " + hex(r.st_addr) + "/" + std::to_string(r.st_size) + "/" + hex(r.st_data & m));
    }
    return true;
}
