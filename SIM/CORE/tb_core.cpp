//---------------------------------------------------------------------------
// tb_core.cpp : the core's bench (Plan/CORE.md 5): OOO_CORE under
// Verilator, fetching through ICacheModel from the bench's Memory, its
// commit trace in lock-step with Spike at every instruction (bench.h).
//
//   tb_core [-seed <n>] [-miss <%>] [-exit <symbol>] [-max <cycles>] [-v]
//           [-restores-out <file>] [-restores-ref <file> -restores-max <x>] <elf> ...
//
// B2 (ALU µops only, no memory): the programs of b2/gen_b2.py end at the
// symbol `pass` (-exit pass), with no HTIF. The run passes when that
// instruction commits with every instruction before it as Spike ran it
// (pc, instruction, the register written and its value). Every branch
// and jalr resolved is also checked against its instruction (what lock-step
// cannot see, since it only steers the predictors): the last parcel, taken
// for a jalr, call / return (link registers x1 / x5, as predecode), a
// conditional branch's outcome to the TAGE update, the BTB's write of an
// indirect jump at its last parcel. -v: the cycles,
// mispredictions (restores) and the IPC. -restores-out writes each
// program's restores; -restores-ref / -restores-max fail a run with more
// than x times the restores of the reference file (+ 4): what only steers
// the predictors costs mispredictions, not values (the bug injection).
//---------------------------------------------------------------------------
#include "VOOO_CORE.h"
#include "VOOO_CORE___024root.h"
#include "verilated.h"

#include "bench.h"
#include "ports.h"

#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

static const int VA = 39;

template <class W> static uint64_t wbits(const W& w, int lo, int n)
{
    uint64_t v = 0;
    for (int b = 0; b < n; b++) { int i = lo + b; v |= (uint64_t)((w[i / 32] >> (i % 32)) & 1) << b; }
    return v;
}
static uint64_t wbits(uint64_t w, int lo, int n) { return (w >> lo) & (n >= 64 ? ~0ull : ((1ull << n) - 1)); }

#include <map>
#include <fstream>

struct Opts {
    uint64_t seed = 1; int miss = 8; std::string exit_sym; uint64_t max = 20000000; bool verbose = false;
    std::string rs_out; std::map<std::string, long> rs_ref; double rs_max = 0;
};
static FILE* rs_out_f = nullptr;

static bool link_reg(int r) { return r == 1 || r == 5; }

// the resolutions of this cycle against their instructions; "" if right
static std::string check_resolution(VOOO_CORE___024root* rp)
{
    char m[160];
    for (int p = 0; p < 2; p++) {
        if (!((rp->OOO_CORE__DOT__br_valid >> p) & 1)) continue;
        int rob = (rp->OOO_CORE__DOT__br_rob >> (5 * p)) & 31;
        uint32_t in = rp->OOO_CORE__DOT__sh_insn[rob];
        uint64_t pc = wbits(rp->OOO_CORE__DOT__ex_pc, (VA - 1) * p, VA - 1);
        bool c = (in & 3) != 3;
        int e = (int)((pc + (c ? 0 : 1)) & 7);
        bool jalr = false; int rd = 0, rs1 = 0;
        if (!c && (in & 0x7f) == 0x67) { jalr = true; rd = (in >> 7) & 31; rs1 = (in >> 15) & 31; }
        if (c && (in & 3) == 2 && ((in >> 13) & 7) == 4 && ((in >> 2) & 31) == 0 && ((in >> 7) & 31) != 0) {
            jalr = true; rs1 = (in >> 7) & 31; rd = ((in >> 12) & 1) ? 1 : 0;       // c.jalr / c.jr
        }
        bool call = jalr && link_reg(rd), ret = jalr && link_reg(rs1) && !link_reg(rd);
        int ge = (rp->OOO_CORE__DOT__br_e >> (3 * p)) & 7;
        bool gt = (rp->OOO_CORE__DOT__br_taken >> p) & 1, gc = (rp->OOO_CORE__DOT__br_call >> p) & 1;
        bool gr = (rp->OOO_CORE__DOT__br_ret >> p) & 1, rv = (rp->OOO_CORE__DOT__rs_valid >> p) & 1;
        bool rt = (rp->OOO_CORE__DOT__rs_taken >> p) & 1;
        int re = (rp->OOO_CORE__DOT__rs_e >> (3 * p)) & 7;
        bool ok = ge == e && gc == call && gr == ret && (jalr ? gt && !rv : rv && re == e && rt == gt);
        if (!ok) {
            std::snprintf(m, sizeof m, "port %d resolves pc %llx (%08x): last parcel %d call %d ret %d taken %d, TAGE %d %d %d",
                          p, (unsigned long long)pc << 1, in, ge, gc, gr, gt, rv, re, rt);
            return m;
        }
    }
    if (rp->OOO_CORE__DOT__bt_valid) {
        bool any = false;
        for (int p = 0; p < 2 && !any; p++) {
            if (!((rp->OOO_CORE__DOT__br_valid >> p) & 1)) continue;
            uint32_t in = rp->OOO_CORE__DOT__sh_insn[(rp->OOO_CORE__DOT__br_rob >> (5 * p)) & 31];
            uint64_t pc = wbits(rp->OOO_CORE__DOT__ex_pc, (VA - 1) * p, VA - 1);
            any = (uint64_t)rp->OOO_CORE__DOT__bt_pc == pc + ((in & 3) == 3 ? 1 : 0) && !((rp->OOO_CORE__DOT__br_ret >> p) & 1);
        }
        if (!any) return "the BTB written for no indirect jump at its last parcel";
    }
    return "";
}

static bool run(const Opts& o, const std::string& elf)
{
    BenchCfg cfg;
    cfg.elf = elf;
    cfg.exit_sym = o.exit_sym;
    cfg.max_cycles = o.max;
    cfg.hang_cycles = 20000;
    Bench b(cfg);
    ICacheModel ic(b.mem(), o.seed * 7 + 1, o.miss);
    std::unique_ptr<VOOO_CORE> d(new VOOO_CORE);
    d->clk = 0; d->boot = 0; d->boot_pc = 0; d->trap_vec = 0;
    d->ic_req_ready = 0; d->ic_resp_valid = 0;
    d->rst_n = 1; d->eval(); d->rst_n = 0; d->eval(); d->rst_n = 1; d->eval();
    long restores = 0;
    bool res_bad = false;
    for (uint64_t cyc = 0; !b.done(); cyc++) {
        d->boot = cyc == 2;
        d->boot_pc = b.entry() >> 1;
        d->ic_req_ready = ic.ready();
        d->ic_resp_valid = ic.resp_valid();
        { uint32_t w[4]; ic.resp_data(w); for (int k = 0; k < 4; k++) d->ic_resp_data[k] = w[k]; }
        d->eval();
        // the commit trace
        TraceSlot s[2];
        int n = 0;
        if (d->tr_trap) {
            s[0] = TraceSlot{};
            s[0].pc = wbits(d->tr_trap_pc, 0, VA - 1) << 1;
            s[0].trap = true; s[0].cause = d->tr_cause;
            n = 1;
        } else {
            for (int k = 0; k < 2; k++) {
                if (!((d->tr_valid >> k) & 1)) continue;
                TraceSlot& t = s[n++];
                t = TraceSlot{};
                t.pc = wbits(d->tr_pc, (VA - 1) * k, VA - 1) << 1;
                t.insn[0] = (uint32_t)wbits(d->tr_insn, 32 * k, 32);
                if ((t.insn[0] & 3) != 3) t.insn[0] &= 0xffff;
                if ((d->tr_wr >> k) & 1) { t.rd = (int)((d->tr_rd >> (5 * k)) & 31); t.rd_val = wbits(d->tr_val, 64 * k, 64); }
            }
        }
        restores += d->rootp->OOO_CORE__DOT__restore;
        {
            std::string why = check_resolution(d->rootp);
            if (!why.empty()) { std::printf("cycle %llu: %s\n", (unsigned long long)cyc, why.c_str()); res_bad = true; break; }
        }
        bool acc = d->ic_req_valid && ic.ready();
        uint64_t rpc = d->ic_req_pc;
        if (!b.commit(s, n)) break;
        if (!b.tick()) break;
        d->clk = 1; d->eval(); d->clk = 0; d->eval();
        ic.clock(acc, rpc);
    }
    std::string name = elf.substr(elf.rfind('/') + 1);
    std::printf("%s\n", b.summary(name).c_str());
    if (o.verbose)
        std::printf("    %ld restores (mispredicted branches and jalr), I$ %ld / %ld missed\n", restores, ic.misses, ic.reqs);
    if (rs_out_f) std::fprintf(rs_out_f, "%s %ld\n", name.c_str(), restores);
    bool ok = b.passed() && !res_bad;
    if (ok && o.rs_max > 0) {
        auto it = o.rs_ref.find(name);
        if (it != o.rs_ref.end() && restores > (long)(o.rs_max * it->second) + 4) {
            std::printf("    %ld restores, more than %.2f times %ld\n", restores, o.rs_max, it->second);
            ok = false;
        }
    }
    return ok;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    Opts o;
    std::vector<std::string> files;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-seed" && i + 1 < argc) o.seed = strtoull(argv[++i], nullptr, 0);
        else if (a == "-miss" && i + 1 < argc) o.miss = atoi(argv[++i]);
        else if (a == "-exit" && i + 1 < argc) o.exit_sym = argv[++i];
        else if (a == "-max" && i + 1 < argc) o.max = strtoull(argv[++i], nullptr, 0);
        else if (a == "-v") o.verbose = true;
        else if (a == "-restores-out" && i + 1 < argc) o.rs_out = argv[++i];
        else if (a == "-restores-max" && i + 1 < argc) o.rs_max = atof(argv[++i]);
        else if (a == "-restores-ref" && i + 1 < argc) {
            std::ifstream in(argv[++i]); std::string nm; long v;
            while (in >> nm >> v) o.rs_ref[nm] = v;
        }
        else if (a[0] == '+') continue;
        else files.push_back(a);
    }
    if (!o.rs_out.empty()) rs_out_f = std::fopen(o.rs_out.c_str(), "w");
    int fails = 0;
    for (auto& f : files) if (!run(o, f)) fails++;
    if (rs_out_f) std::fclose(rs_out_f);
    std::printf("tb_core: %zu files, %d failures: %s\n", files.size(), fails, fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
