//---------------------------------------------------------------------------
// bench.cc : the test bench of the mmRISC-3 core, its C++ side (bench.h)
//---------------------------------------------------------------------------
#include "bench.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <stdexcept>

#include "riscv/disasm.h"
#include "riscv/isa_parser.h"

namespace {

std::string hex(uint64_t v)
{
    char b[24]; std::snprintf(b, sizeof b, "%llx", (unsigned long long)v); return b;
}

int insn_len(uint32_t insn) { return (insn & 3) == 3 ? 4 : 2; }

template <class T> T rd_le(const std::vector<uint8_t>& f, size_t o)
{
    if (o + sizeof(T) > f.size()) throw std::runtime_error("ELF: truncated");
    T v; std::memcpy(&v, &f[o], sizeof(T)); return v;
}

}  // namespace

// ---- Memory
uint8_t* Memory::page(uint64_t a)
{
    if (!contains(a)) return nullptr;
    auto& p = pg[a / PAGE];
    if (!p) { p.reset(new uint8_t[PAGE]); std::memset(p.get(), 0, PAGE); }
    return p.get();
}

void Memory::read(uint64_t a, void* p, size_t n)
{
    uint8_t* d = (uint8_t*)p;
    while (n) {
        size_t k = std::min<uint64_t>(n, PAGE - a % PAGE);
        uint8_t* s = page(a);
        if (s) std::memcpy(d, s + a % PAGE, k); else std::memset(d, 0, k);
        a += k; d += k; n -= k;
    }
}

void Memory::poke(uint64_t a, const void* p, size_t n)
{
    const uint8_t* d = (const uint8_t*)p;
    while (n) {
        size_t k = std::min<uint64_t>(n, PAGE - a % PAGE);
        if (uint8_t* s = page(a)) std::memcpy(s + a % PAGE, d, k);
        a += k; d += k; n -= k;
    }
}

void Memory::write(uint64_t a, const void* p, size_t n)
{
    poke(a, p, n);
    if (on_write) on_write(a, n);
}

void Memory::write64(uint64_t a, uint64_t d, uint8_t mask)
{
    a &= ~7ull;
    for (int i = 0; i < 8; i++)
        if (mask >> i & 1) { uint8_t b = (uint8_t)(d >> 8 * i); poke(a + i, &b, 1); }
    if (on_write && mask) on_write(a, 8);
}

std::vector<uint64_t> Memory::pages() const
{
    std::vector<uint64_t> v;
    for (auto& p : pg) v.push_back(p.first * PAGE);
    std::sort(v.begin(), v.end());
    return v;
}

// ---- ELF
ElfImage load_elf_image(const std::string& path)
{
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open " + path);
    std::vector<uint8_t> f((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (f.size() < 64 || std::memcmp(f.data(), "\177ELF", 4) || f[4] != 2)
        throw std::runtime_error(path + ": not an ELF64 file");
    ElfImage e;
    e.entry = rd_le<uint64_t>(f, 24);
    uint64_t phoff = rd_le<uint64_t>(f, 32), shoff = rd_le<uint64_t>(f, 40);
    uint16_t phentsize = rd_le<uint16_t>(f, 54), phnum = rd_le<uint16_t>(f, 56);
    uint16_t shentsize = rd_le<uint16_t>(f, 58), shnum = rd_le<uint16_t>(f, 60);
    for (unsigned i = 0; i < phnum; i++) {
        size_t ph = phoff + (size_t)i * phentsize;
        if (rd_le<uint32_t>(f, ph) != 1) continue;               // PT_LOAD
        uint64_t off = rd_le<uint64_t>(f, ph + 8), paddr = rd_le<uint64_t>(f, ph + 24);
        uint64_t filesz = rd_le<uint64_t>(f, ph + 32), memsz = rd_le<uint64_t>(f, ph + 40);
        if (off + filesz > f.size() || filesz > memsz) throw std::runtime_error("ELF: bad segment");
        std::vector<uint8_t> b(memsz, 0);
        std::memcpy(b.data(), &f[off], filesz);
        e.segs.push_back({paddr, std::move(b)});
    }
    for (unsigned i = 0; i < shnum; i++) {
        size_t sh = shoff + (size_t)i * shentsize;
        if (rd_le<uint32_t>(f, sh + 4) != 2) continue;           // SHT_SYMTAB
        uint64_t off = rd_le<uint64_t>(f, sh + 24), size = rd_le<uint64_t>(f, sh + 32);
        uint32_t link = rd_le<uint32_t>(f, sh + 40);
        uint64_t stroff = rd_le<uint64_t>(f, shoff + (size_t)link * shentsize + 24);
        for (uint64_t s = off; s + 24 <= off + size; s += 24) {
            uint32_t name = rd_le<uint32_t>(f, s);
            if (!name || stroff + name >= f.size()) continue;
            const char* n = (const char*)&f[stroff + name];
            if (strnlen(n, f.size() - stroff - name) < f.size() - stroff - name)
                e.sym[n] = rd_le<uint64_t>(f, s + 8);
        }
    }
    return e;
}

void load_into(const ElfImage& e, Memory& m)
{
    for (auto& s : e.segs) {
        if (s.second.empty()) continue;
        if (!m.contains(s.first, s.second.size()))
            throw std::runtime_error("ELF segment at 0x" + hex(s.first) + " outside the memory");
        m.poke(s.first, s.second.data(), s.second.size());
    }
}

// ---- HTIF
bool Htif::commit_store(uint64_t addr, uint64_t data, int size)
{
    if (addr >= tohost + 8 || addr + size <= tohost) return false;
    for (int i = 0; i < size; i++) {
        uint64_t b = addr + i;
        if (b < tohost || b >= tohost + 8) continue;
        unsigned sh = 8 * (unsigned)(b - tohost);
        shadow = (shadow & ~(0xffull << sh)) | ((data >> 8 * i & 0xff) << sh);
    }
    if (!shadow) return false;
    // the device first: a character's payload can have bit 0 set too
    unsigned dev = (unsigned)(shadow >> 56), cmd = (unsigned)(shadow >> 48) & 0xff;
    if (dev == 0 && cmd == 0 && (shadow & 1)) { exited = true; code = (int)((shadow << 16) >> 17); }
    else if (dev == 1 && cmd == 1) out += (char)(shadow & 0xff);
    shadow = 0;
    return true;
}

void Htif::mem_write(uint64_t a, size_t n, Memory& m)
{
    if (a < tohost + 8 && a + n > tohost && m.read64(tohost)) zero = true;
}

void Htif::tick(Memory& m)
{
    if (!zero) return;
    uint64_t z = 0;
    m.poke(tohost, &z, 8);
    zero = false;
}

// ---- the commit-trace port
int to_commits(const TraceSlot& s, Commit out[2])
{
    auto store = [](Commit& x, const TraceStore& t) {
        if (!t.v) return;
        x.st = true; x.st_addr = t.addr; x.st_data = t.data; x.st_size = t.size;
    };
    auto write = [&](Commit& x) {
        if (s.rd < 0 || (s.rd == 0 && !s.rd_fp)) return;      // x0 counts as none
        x.rd = s.rd; x.rd_fp = s.rd_fp; x.rd_val = s.rd_val;
    };
    Commit& x = out[0];
    x = Commit();
    x.pc = s.pc; x.insn = s.insn[0];
    store(x, s.st[0]);
    if (!s.pair) {
        x.trap = s.trap; x.cause = s.cause;
        if (!s.trap) write(x);
        return 1;
    }
    Commit& y = out[1];
    y = Commit();
    y.pc = s.pc + insn_len(s.insn[0]); y.insn = s.insn[1];
    store(y, s.st[1]);
    write(s.wr_first ? x : y);
    if (!s.wr_first && !s.st[0].v) x.rd_skip = true;
    return 2;
}

// ---- the bench
struct Bench::Dis {
    isa_parser_t isa;
    disassembler_t d;
    Dis(const LockstepCfg& c) : isa(c.isa.c_str(), c.priv.c_str()), d(&isa) {}
};

Bench::Bench(const BenchCfg& cfg) : c(cfg)
{
    c.ref.elf = c.elf;
    img = load_elf_image(c.elf);
    if (!img.symbol("tohost")) throw std::runtime_error(c.elf + ": no tohost symbol");
    m.reset(new Memory(c.ref.mem_base, c.ref.mem_size));
    a.reset(new Memory(c.ref.mem_base, c.ref.mem_size));
    load_into(img, *m);
    load_into(img, *a);
    uint64_t th = img.symbol("tohost"), fh = img.symbol("fromhost");
    h.reset(new Htif(th, fh ? fh : th + 8));
    m->on_write = [this](uint64_t ad, size_t n) { h->mem_write(ad, n, *m); };
    if (c.lockstep) ref.reset(new Lockstep(c.ref));
    dis.reset(new Dis(c.ref));
    if (!c.exit_sym.empty() && !(exit_pc = img.symbol(c.exit_sym))) throw std::runtime_error(c.elf + ": no " + c.exit_sym + " symbol");
}

Bench::~Bench() = default;

void Bench::fail(const std::string& why)
{
    if (over) return;
    over = true;
    err = why;
    char b[64];
    std::snprintf(b, sizeof b, " (cycle %llu)", (unsigned long long)cycles);
    err += b;
    err += "\n    the last commits of the DUT:";
    for (auto& x : last) {
        char l[160];
        std::snprintf(l, sizeof l, "\n    %10llx: %08x  %-28s", (unsigned long long)x.pc, x.insn,
                      dis->d.disassemble(insn_t(x.insn)).c_str());
        err += l;
        if (x.trap) err += " trap " + hex(x.cause);
        else if (x.rd_skip) err += " (first half, not written)";
        else if (x.rd >= 0) err += std::string(x.rd_fp ? " f" : " x") + std::to_string(x.rd) + " = " + hex(x.rd_val);
        if (x.st) err += " [" + hex(x.st_addr) + "] = " + hex(x.st_data) + " /" + std::to_string(x.st_size);
    }
}

void Bench::finish()
{
    if (ref && (!ref->exited() || ref->exit_code() != h->code || ref->output() != h->out)) {
        fail("HTIF: DUT exit " + std::to_string(h->code) + " (" + std::to_string(h->out.size()) +
             " characters), reference " + (ref->exited() ? "exit " + std::to_string(ref->exit_code()) : "running") +
             " (" + std::to_string(ref->output().size()) + " characters)");
        return;
    }
    over = true;
    uint64_t b = img.symbol("begin_signature"), e = img.symbol("end_signature");
    if (!c.signature.empty() && b && e > b) {
        FILE* f = std::fopen(c.signature.c_str(), "w");
        if (!f) { fail("cannot write " + c.signature); return; }
        for (uint64_t x = b; x < e; x += 4) {
            uint32_t w; a->read(x, &w, 4);
            std::fprintf(f, "%08x\n", w);
        }
        std::fclose(f);
    }
}

bool Bench::commit(const TraceSlot* s, int n)
{
    if (over) return false;
    if (n > 0) last_commit_cycle = cycles;
    for (int i = 0; i < n; i++) {
        Commit cm[2];
        int k = to_commits(s[i], cm);
        uops++;
        for (int j = 0; j < k; j++) {
            const Commit& x = cm[j];
            if (!x.trap) insns++;
            last.push_back(x);
            if ((int)last.size() > c.tail) last.pop_front();
            std::string why;
            if (ref && !ref->check(x, &why)) { fail("mismatch at instruction " + std::to_string(insns) + ": " + why); return false; }
            if (exit_pc && x.pc == exit_pc && !x.trap) { over = true; return false; }      // (exit_sym: no HTIF)
            if (!x.st || x.trap) continue;
            a->poke(x.st_addr, &x.st_data, x.st_size);
            if (h->commit_store(x.st_addr, x.st_data, x.st_size) && h->exited) { finish(); return false; }
        }
    }
    return true;
}

bool Bench::tick()
{
    if (over) return false;
    cycles++;
    h->tick(*m);
    if (cycles - last_commit_cycle > c.hang_cycles) fail("no commit for " + std::to_string(c.hang_cycles) + " cycles");
    else if (cycles >= c.max_cycles) fail("no exit in " + std::to_string(c.max_cycles) + " cycles");
    return !over;
}

std::string Bench::summary(const std::string& name) const
{
    char b[256];
    std::snprintf(b, sizeof b, "%-28s %s  exit %d  %llu insns  %llu uops  %llu cycles  IPC %.3f", name.c_str(),
                  passed() ? "PASS" : (over ? "FAIL" : "RUNNING"), h->code, (unsigned long long)insns,
                  (unsigned long long)uops, (unsigned long long)cycles, cycles ? (double)insns / cycles : 0.0);
    std::string s = b;
    if (!err.empty()) s += "\n    " + err;
    return s;
}
