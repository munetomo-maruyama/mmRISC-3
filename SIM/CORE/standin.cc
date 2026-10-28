//---------------------------------------------------------------------------
// standin.cc : the core's test bench (bench.h) tested with a stand-in core
// (Plan/CORE.md B0)
//
//   standin [-n <mutations per file>] [-delay <cycles>] [-v] <elf> ...
//
// The stand-in is a second Spike (processor_t) that runs on the bench's
// memory, the way the core will:
//   - it fetches and loads from Memory (the bench's ELF loader, not
//     LOCKSTEP's), so a wrong image shows as a mismatch;
//   - the page(s) of tohost and fromhost are a device for it: a store there
//     waits in a queue 0 to -delay cycles (default 24) before it reaches
//     Memory through write(), as a store behind the store queue and the D$;
//     a load there takes the newest queued bytes first (store-to-load
//     forwarding). So a loop polling tohost runs longer than in the
//     reference, which needs LOCKSTEP's rule for loads of tohost, and the
//     bench must put tohost back to 0 from the memory side;
//   - its commits go through the commit-trace port: 0, 1 or 2 slots a cycle,
//     two instructions fused into one slot where the rule of one register
//     write per pair allows it (same register written twice: the first is
//     not written; one write: by either half; two stores).
// For every ELF file:
//   1. expected  the reference alone (LOCKSTEP step_ref) to its exit: the
//                exit code and the console
//   2. clean     the bench with lock-step: must pass, with the expected exit
//                code and console; afterwards the bench's architectural
//                memory (ELF + committed stores) must equal the stand-in's
//                memory, tohost apart. Not compared when the program turns
//                translation on (rv64si-p-dirty): a store commits its
//                virtual address, and the page walker's A / D bits are no
//                store at all; Phase 1 has no translation
//   3. free      the bench without lock-step: the same exit code, console
//                and memory
//   4. mutated   -n runs, each with one wrong field in one slot of the port
//                (13 kinds below): each must end in a lock-step mismatch
//   5. watchdog  (the first file only) the stand-in stops committing half
//                way: the bench must end the run (no commit); a limit of half
//                the cycles of the clean run: the bench must end it (no exit)
// -max: the bench's limit of cycles (default 20 M: a run polling tohost
// for ever ends there).
// The exit code is the number of failures.
//---------------------------------------------------------------------------
#include "bench.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <random>
#include <set>
#include <sstream>
#include <stdexcept>

#include "riscv/cfg.h"
#include "riscv/encoding.h"
#include "riscv/isa_parser.h"
#include "riscv/mmu.h"
#include "riscv/processor.h"
#include "riscv/simif.h"

static const char* KIND[] = {
    "register value", "register number", "write missing", "pc", "instruction",
    "second instruction", "write of the other half", "store data", "store missing",
    "pair split", "trap cause", "slot dropped", "slots swapped",
};
static const int NKIND = 13;

static int insn_len(uint32_t i) { return (i & 3) == 3 ? 4 : 2; }

// ---- the stand-in core
class Standin : public simif_t {
public:
    Standin(Memory& m, const LockstepCfg& lc, uint64_t entry, uint64_t th, uint64_t fh, uint64_t seed, int delay)
        : m(m), rng(seed), delay(delay), tohost(th)
    {
        dev.insert(th / Memory::PAGE);
        dev.insert(fh / Memory::PAGE);
        cfg.isa = lc.isa.c_str();
        cfg.priv = lc.priv.c_str();
        cfg.misaligned = false;
        cfg.pmpregions = lc.pmp_regions;
        cfg.mem_layout = {mem_cfg_t(lc.mem_base, lc.mem_size)};
        cfg.start_pc = entry;
        cfg.hartids = {0};
        isa.reset(new isa_parser_t(cfg.isa, cfg.priv));
        devnull = std::fopen("/dev/null", "w");
        proc.reset(new processor_t(isa.get(), &cfg, this, 0, false, devnull, sout));
        harts[0] = proc.get();
        proc->enable_log_commits();
        proc->get_state()->pc = entry;
    }
    ~Standin() override { proc.reset(); if (devnull) std::fclose(devnull); }

    // simif_t
    char* addr_to_mem(reg_t a) override
    {
        if (dev.count(a / Memory::PAGE)) return nullptr;
        uint8_t* p = m.page(a);
        return p ? (char*)p + a % Memory::PAGE : nullptr;
    }
    bool reservable(reg_t a) override { return m.contains(a); }
    bool mmio_load(reg_t a, size_t n, uint8_t* b) override
    {
        if (!m.contains(a, n)) return false;
        view(a, b, n);
        if (a < tohost + 8 && a + n > tohost) {
            uint64_t v = 0; view(tohost, &v, 8);
            if (v) polls++;
        }
        return true;
    }
    bool mmio_store(reg_t a, size_t n, const uint8_t* b) override
    {
        if (!m.contains(a, n)) return false;
        Pending p; p.a = a; p.b.assign(b, b + n); p.due = cyc + rng() % (delay + 1);
        q.push_back(p);
        return true;
    }
    void proc_reset(unsigned) override {}
    const cfg_t& get_cfg() const override { return cfg; }
    const std::map<size_t, processor_t*>& get_harts() const override { return harts; }
    const char* get_symbol(uint64_t) override { return nullptr; }

    // one cycle: the queued device stores that are due reach the memory, in order
    void tick()
    {
        cyc++;
        while (!q.empty() && q.front().due <= cyc) { m.write(q.front().a, q.front().b.data(), q.front().b.size()); q.pop_front(); }
    }
    void drain() { while (!q.empty()) { m.write(q.front().a, q.front().b.data(), q.front().b.size()); q.pop_front(); } }

    // the next slot of the port; pair: try to fuse two instructions
    TraceSlot slot(bool pair)
    {
        Commit a = next();
        TraceSlot s;
        s.pc = a.pc; s.insn[0] = a.insn;
        if (a.trap) { s.trap = true; s.cause = a.cause; return s; }
        if (a.st) s.st[0] = {true, a.st_addr, a.st_data, a.st_size};
        if (pair) {
            Commit b = next();
            bool ok = !b.trap && b.pc == a.pc + insn_len(a.insn) &&
                      (a.rd < 0 || b.rd < 0 || (a.rd == b.rd && a.rd_fp == b.rd_fp));
            if (ok) {
                s.pair = true; s.insn[1] = b.insn;
                if (b.st) s.st[1] = {true, b.st_addr, b.st_data, b.st_size};
                const Commit& w = b.rd >= 0 ? b : a;
                s.wr_first = b.rd < 0 && a.rd >= 0;
                s.rd = w.rd; s.rd_fp = w.rd_fp; s.rd_val = w.rd_val;
                npair++;
                return s;
            }
            ahead.push_front(b);
        }
        s.rd = a.rd; s.rd_fp = a.rd_fp; s.rd_val = a.rd_val;
        return s;
    }

    uint64_t polls = 0, npair = 0;
    bool paging = false;       // translation was turned on
private:
    struct Pending { uint64_t a; std::vector<uint8_t> b; uint64_t due; };
    // the memory as the core sees it: Memory with the queued stores on top
    void view(uint64_t a, void* p, size_t n)
    {
        uint8_t* d = (uint8_t*)p;
        m.read(a, d, n);
        for (auto& s : q)
            for (size_t i = 0; i < s.b.size(); i++)
                if (s.a + i >= a && s.a + i < a + n) d[s.a + i - a] = s.b[i];
    }
    Commit next()
    {
        if (!ahead.empty()) { Commit c = ahead.front(); ahead.pop_front(); return c; }
        state_t* s = proc->get_state();
        Commit r;
        r.pc = s->pc;
        uint16_t lo; view(r.pc, &lo, 2);
        r.insn = lo;
        if ((lo & 3) == 3) { uint32_t w; view(r.pc, &w, 4); r.insn = w; }
        reg_t i0 = proc->get_csr(CSR_MINSTRET);
        proc->step(1);
        if ((r.insn & 0x7f) == 0x73 && proc->get_csr(CSR_SATP) >> 60) paging = true;
        if (proc->get_csr(CSR_MINSTRET) == i0) {
            r.trap = true;
            r.cause = (s->prv == PRV_S) ? proc->get_csr(CSR_SCAUSE) : proc->get_csr(CSR_MCAUSE);
            return r;
        }
        for (auto& w : s->log_reg_write) {
            unsigned type = w.first & 0xf, reg = (unsigned)(w.first >> 4);
            if ((type == 0 && reg != 0) || type == 1) { r.rd = (int)reg; r.rd_fp = type == 1; r.rd_val = w.second.v[0]; }
        }
        for (auto& w : s->log_mem_write) { r.st = true; r.st_addr = std::get<0>(w); r.st_data = std::get<1>(w); r.st_size = std::get<2>(w); }
        return r;
    }
    Memory& m;
    std::mt19937_64 rng;
    int delay;
    uint64_t tohost, cyc = 0;
    std::set<uint64_t> dev;
    std::deque<Pending> q;
    std::deque<Commit> ahead;
    cfg_t cfg;
    std::unique_ptr<isa_parser_t> isa;
    std::unique_ptr<processor_t> proc;
    std::map<size_t, processor_t*> harts;
    FILE* devnull = nullptr;
    std::ostringstream sout;
};

// ---- a mutation of the port
static bool applies(int k, const TraceSlot& s, int nslots_in_cycle, int pos)
{
    switch (k) {
    case 0: case 2: return !s.trap && s.rd > 0;
    case 1: return !s.trap && s.rd > 0 && !s.rd_fp;
    case 5: case 9: return s.pair;
    case 6: return s.pair && s.rd > 0;
    case 7: case 8: return s.st[0].v || s.st[1].v;
    case 10: return s.trap;
    case 12: return nslots_in_cycle == 2 && pos == 0;
    default: return true;
    }
}

static void mutate(int k, TraceSlot* cyc, int pos, std::mt19937_64& rng)
{
    TraceSlot& s = cyc[pos];
    TraceStore& st = s.st[s.st[0].v ? 0 : 1];
    switch (k) {
    case 0: s.rd_val ^= 1ull << (rng() % 64); break;
    case 1: s.rd = (s.rd % 31) + 1; break;
    case 2: s.rd = -1; break;
    case 3: s.pc += 2; break;
    case 4: s.insn[0] ^= 1u << (2 + rng() % 14); break;
    case 5: s.insn[1] ^= 1u << (2 + rng() % 14); break;
    case 6: s.wr_first = !s.wr_first; break;
    case 7: st.data ^= 1ull << (rng() % (8 * st.size)); break;
    case 8: st.v = false; break;
    case 9: s.pair = false; break;
    case 10: s.cause ^= 1; break;
    case 12: std::swap(cyc[0], cyc[1]); break;
    default: break;
    }
}

struct Run {
    bool passed = false;
    int code = 0;
    std::string out, err, summary;
    uint64_t slots = 0, polls = 0, pairs = 0, cycles = 0;
    uint64_t last = 0;         // the slot the run ended at (the exit's)
    long mem_diff = -1;        // bytes where the architectural memory and the stand-in's differ
    bool paging = false;       // translation was on: the memory is not compared
};

// run the bench on a stand-in; mk >= 0: mutation kind mk at the first slot
// it applies to from slot mat on, before slot lim (the exit's); stop > 0: the stand-in commits nothing
// from that slot on; max > 0: the bench's limit of cycles
static uint64_t max_cycles = 20000000;
static Run run(const std::string& elf, const std::string& name, bool lockstep, int delay, uint64_t seed,
               int mk, uint64_t mat, std::mt19937_64* mrng, uint64_t stop = 0, uint64_t max = 0, uint64_t lim = ~0ull)
{
    BenchCfg bc;
    bc.elf = elf;
    bc.lockstep = lockstep;
    bc.max_cycles = max ? max : max_cycles;
    Bench b(bc);
    Standin core(b.mem(), bc.ref, b.entry(), b.symbol("tohost"),
                 b.symbol("fromhost") ? b.symbol("fromhost") : b.symbol("tohost") + 8, seed, delay);
    std::mt19937_64 g(seed ^ 0x9e3779b97f4a7c15ull);
    Run r;
    bool done_mut = mk < 0;
    while (!b.done()) {
        unsigned x = g() % 8;
        int n = x < 2 ? 0 : x < 4 ? 1 : 2;
        if (stop && r.slots >= stop) n = 0;
        TraceSlot cyc[2];
        for (int i = 0; i < n; i++) cyc[i] = core.slot(g() % 3 == 0);
        int keep = n;
        if (!done_mut)
            for (int i = 0; i < n && !done_mut; i++)
                if (r.slots + i >= mat && r.slots + i + (mk == 12) < lim && applies(mk, cyc[i], n, i)) {
                    if (mk == 11) { for (int j = i; j + 1 < n; j++) cyc[j] = cyc[j + 1]; keep = n - 1; }
                    else mutate(mk, cyc, i, *mrng);
                    done_mut = true;
                }
        r.slots += n;
        b.commit(cyc, keep);
        core.tick();
        b.tick();
    }
    r.passed = b.passed();
    r.code = b.exit_code();
    r.out = b.output();
    r.err = b.error();
    r.summary = b.summary(name);
    r.polls = core.polls;
    r.cycles = b.cycles;
    r.last = b.uops ? b.uops - 1 : 0;
    r.pairs = core.npair;
    if (!done_mut) r.err = "mutation not applied";
    if (r.passed) {
        core.drain();
        uint64_t th = b.symbol("tohost");
        long d = 0;
        std::set<uint64_t> pages;
        for (uint64_t p : b.mem().pages()) pages.insert(p);
        for (uint64_t p : b.arch().pages()) pages.insert(p);
        for (uint64_t p : pages) {
            uint8_t x[Memory::PAGE], y[Memory::PAGE];
            b.mem().read(p, x, sizeof x);
            b.arch().read(p, y, sizeof y);
            for (uint64_t i = 0; i < Memory::PAGE; i++)
                if (x[i] != y[i] && !(p + i >= th && p + i < th + 8)) d++;
        }
        r.mem_diff = d;
        r.paging = core.paging;
        if (core.paging) r.mem_diff = 0;
    }
    return r;
}

// HTIF alone: the sequences the programs here do not make
static bool htif_unit()
{
    bool ok = true;
    auto want = [&](bool c, const char* what) { if (!c) { printf("htif unit: %s\n", what); ok = false; } };
    Memory m(0x1000, 0x2000);
    Htif h(0x1000, 0x1008);
    m.on_write = [&](uint64_t a, size_t n) { h.mem_write(a, n, m); };
    // a character, then a 4-byte exit over it: tohost counts as 0 after the character
    want(h.commit_store(0x1000, (1ull << 56) | (1ull << 48) | 'A', 8) && h.out == "A", "character");
    want(!h.commit_store(0x1008, 5, 8) && !h.exited && h.out == "A", "fromhost is not tohost");
    want(h.commit_store(0x1000, 1, 4) && h.exited && h.code == 0 && h.out == "A", "exit after a character");
    // the exit code from a store of the upper word first
    Htif g(0x1000, 0x1008);
    want(!g.commit_store(0x1004, 0, 4) && g.commit_store(0x1000, 5 << 1 | 1, 4) && g.exited && g.code == 5, "exit code");
    // the memory side: tohost back to 0 at the tick after a nonzero write, and only then
    uint64_t v = 0x55;
    m.write(0x1000, &v, 8);
    want(m.read64(0x1000) == 0x55, "tohost cleared before the tick");
    h.tick(m);
    want(m.read64(0x1000) == 0, "tohost not cleared at the tick");
    m.write64(0x1008, 7, 0xff);
    h.tick(m);
    want(m.read64(0x1008) == 7, "fromhost cleared");
    printf("htif unit: %s\n", ok ? "PASS" : "FAIL");
    return ok;
}

int main(int argc, char** argv)
{
    int nmut = 13, delay = 24;
    bool verbose = false;
    std::vector<std::string> elfs;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-n" && i + 1 < argc) nmut = atoi(argv[++i]);
        else if (a == "-delay" && i + 1 < argc) delay = atoi(argv[++i]);
        else if (a == "-max" && i + 1 < argc) max_cycles = strtoull(argv[++i], nullptr, 0);
        else if (a == "-v") verbose = true;
        else elfs.push_back(a);
    }
    std::mt19937_64 mrng(2029);
    int fails = 0;
    long caught_total = 0, mut_total = 0;
    uint64_t polls_total = 0;
    std::vector<std::string> nonzero;
    if (!htif_unit()) fails++;
    for (auto& e : elfs) {
        std::string name = e.substr(e.find_last_of('/') + 1);
        try {
            // 1. expected: the reference alone
            LockstepCfg lc; lc.elf = e;
            Lockstep alone(lc);
            while (!alone.exited() && alone.steps() < 50000000) alone.step_ref();
            if (!alone.exited()) { printf("%-28s ERROR the reference does not exit\n", name.c_str()); fails++; continue; }
            uint64_t seed = std::hash<std::string>()(name);
            // 2. clean, 3. free
            Run c = run(e, name, true, delay, seed, -1, 0, nullptr);
            Run f = run(e, name, false, delay, seed + 1, -1, 0, nullptr);
            auto good = [&](const Run& r) {
                return r.passed && r.code == alone.exit_code() && r.out == alone.output() && r.mem_diff == 0;
            };
            // 4. mutations
            int caught = 0, na = 0;
            std::vector<std::string> missed;
            for (int k = 0; k < nmut; k++) {
                int mk = k % NKIND;
                uint64_t at = c.slots > 1 ? mrng() % (c.slots - 1) : 0;
                Run m = run(e, name, true, delay, seed, mk, at, &mrng, 0, 0, c.last);
                if (m.err == "mutation not applied") m = run(e, name, true, delay, seed, mk, 0, &mrng, 0, 0, c.last);
                if (m.err == "mutation not applied") {      // nothing to apply it to
                    na++;
                    if (verbose) printf("    n/a: %s\n", KIND[mk]);
                    continue;
                }
                if (!m.passed && m.err.compare(0, 8, "mismatch") == 0) caught++;
                else missed.push_back(std::string(KIND[mk]) + (m.passed ? " (passed)" : ": " + m.err.substr(0, 80)));
                mut_total++;
            }
            // 5. the watchdog (the first file): commits stop half way; half the cycles
            std::string wd;
            if (&e == &elfs[0]) {
                Run h = run(e, name, true, delay, seed, -1, 0, nullptr, c.slots / 2);
                Run t = run(e, name, true, delay, seed, -1, 0, nullptr, 0, c.cycles / 2);
                bool hw = h.err.compare(0, 9, "no commit") == 0, tw = t.err.compare(0, 7, "no exit") == 0;
                wd = std::string("    watchdog: commits stopped half way ") + (hw ? "caught" : "NOT CAUGHT") +
                     ", half the cycles " + (tw ? "caught" : "NOT CAUGHT") + "\n";
                if (!hw || !tw) fails++;
            }
            caught_total += caught;
            polls_total += c.polls;
            bool ok = good(c) && good(f) && missed.empty();
            printf("%-28s %9zu slots  %7zu pairs  exit %d  polls %zu  clean %s  free %s  mutations %d/%d caught (%d n/a)%s\n",
                   name.c_str(), (size_t)c.slots, (size_t)c.pairs, c.code, (size_t)c.polls, good(c) ? "PASS" : "FAIL",
                   good(f) ? "PASS" : "FAIL", caught, nmut - na, na, ok ? "" : "  <-- FAIL");
            printf("%s", wd.c_str());
            if (c.paging) printf("    translation on: the architectural memory not compared (stores commit virtual addresses)\n");
            if (verbose) printf("    %s\n", c.summary.c_str());
            if (!good(c)) printf("    clean: %s\n    exit %d / %d, console %s, memory differs in %ld bytes\n", c.summary.c_str(), c.code,
                                 alone.exit_code(), c.out == alone.output() ? "same" : "differs", c.mem_diff);
            if (!good(f)) printf("    free: %s\n    exit %d / %d, console %s, memory differs in %ld bytes\n", f.summary.c_str(), f.code,
                                 alone.exit_code(), f.out == alone.output() ? "same" : "differs", f.mem_diff);
            for (auto& s : missed) printf("    not caught: %s\n", s.c_str());
            if (alone.exit_code() != 0) nonzero.push_back(name + " (" + std::to_string(alone.exit_code()) + ")");
            if (!ok) fails++;
        } catch (std::exception& ex) {
            printf("%-28s ERROR %s\n", name.c_str(), ex.what()); fails++;
        }
    }
    printf("programs with a nonzero exit code:");
    for (auto& n : nonzero) printf(" %s", n.c_str());
    printf("%s\n", nonzero.empty() ? " none" : "");
    printf("bench standin: %zu files, %ld of %ld mutations caught, %zu polls of a busy tohost, %d failures: %s\n",
           elfs.size(), caught_total, mut_total, (size_t)polls_total, fails, fails ? "FAIL" : "PASS");
    return fails;
}
