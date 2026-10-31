//---------------------------------------------------------------------------
// tb_core.cpp : the core's bench (Plan/CORE.md 5): OOO_CORE under
// Verilator, fetching through ICacheModel from the bench's Memory, its
// commit trace in lock-step with Spike at every instruction (bench.h).
//
//   tb_core [-seed <n>] [-miss <%>] [-dhit <%>] [-exit <symbol>] [-max <cycles>] [-v]
//           [-restores-out <file>] [-restores-ref <file> -restores-max <x>] <elf> ...
//
// The D$: DCacheModel (ports.h) on OOO_LSU's abstract port (-dhit: % of the
// loads that hit, default 80). B3: loads and stores; the commit trace gives
// each store's address and data, and the exit and the console come from
// HTIF (tohost) as in B0.
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
// The register file is set to 0 after reset, as Spike's registers start.
//---------------------------------------------------------------------------
#ifdef CPU_TOP                  // OOO_CPU: the core with OOO_DCAD and the D$ on the AXI models (build_core.sh cpu)
#include "VOOO_CPU.h"
#include "VOOO_CPU___024root.h"
typedef VOOO_CPU Top;
typedef VOOO_CPU___024root TopRoot;
#define CORE(x) OOO_CPU__DOT__u_core__DOT__##x
#else                           // OOO_CORE: the D$ is DCacheModel on the LSU's abstract port
#include "VOOO_CORE.h"
#include "VOOO_CORE___024root.h"
typedef VOOO_CORE Top;
typedef VOOO_CORE___024root TopRoot;
#define CORE(x) OOO_CORE__DOT__##x
#endif
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
    uint64_t seed = 1; int miss = 8, dhit = 80; std::string exit_sym; uint64_t max = 20000000; bool verbose = false;
    std::string rs_out; std::map<std::string, long> rs_ref; double rs_max = 0;
};
static FILE* rs_out_f = nullptr;

static bool link_reg(int r) { return r == 1 || r == 5; }

// the resolutions of this cycle against their instructions; "" if right
static std::string check_resolution(TopRoot* rp)
{
    char m[160];
    for (int p = 0; p < 2; p++) {
        if (!((rp->CORE(br_valid) >> p) & 1)) continue;
        int rob = (rp->CORE(br_rob) >> (5 * p)) & 31;
        uint32_t in = rp->CORE(sh_insn)[rob];
        uint64_t pc = wbits(rp->CORE(ex_pc), (VA - 1) * p, VA - 1);
        bool c = (in & 3) != 3;
        int e = (int)((pc + (c ? 0 : 1)) & 7);
        bool jalr = false; int rd = 0, rs1 = 0;
        if (!c && (in & 0x7f) == 0x67) { jalr = true; rd = (in >> 7) & 31; rs1 = (in >> 15) & 31; }
        if (c && (in & 3) == 2 && ((in >> 13) & 7) == 4 && ((in >> 2) & 31) == 0 && ((in >> 7) & 31) != 0) {
            jalr = true; rs1 = (in >> 7) & 31; rd = ((in >> 12) & 1) ? 1 : 0;       // c.jalr / c.jr
        }
        bool call = jalr && link_reg(rd), ret = jalr && link_reg(rs1) && !link_reg(rd);
        int ge = (rp->CORE(br_e) >> (3 * p)) & 7;
        bool gt = (rp->CORE(br_taken) >> p) & 1, gc = (rp->CORE(br_call) >> p) & 1;
        bool gr = (rp->CORE(br_ret) >> p) & 1, rv = (rp->CORE(rs_valid) >> p) & 1;
        bool rt = (rp->CORE(rs_taken) >> p) & 1;
        int re = (rp->CORE(rs_e) >> (3 * p)) & 7;
        bool ok = ge == e && gc == call && gr == ret && (jalr ? gt && !rv : rv && re == e && rt == gt);
        if (!ok) {
            std::snprintf(m, sizeof m, "port %d resolves pc %llx (%08x): last parcel %d call %d ret %d taken %d, TAGE %d %d %d",
                          p, (unsigned long long)pc << 1, in, ge, gc, gr, gt, rv, re, rt);
            return m;
        }
    }
    if (rp->CORE(bt_valid)) {
        bool any = false;
        for (int p = 0; p < 2 && !any; p++) {
            if (!((rp->CORE(br_valid) >> p) & 1)) continue;
            uint32_t in = rp->CORE(sh_insn)[(rp->CORE(br_rob) >> (5 * p)) & 31];
            uint64_t pc = wbits(rp->CORE(ex_pc), (VA - 1) * p, VA - 1);
            any = (uint64_t)rp->CORE(bt_pc) == pc + ((in & 3) == 3 ? 1 : 0) && !((rp->CORE(br_ret) >> p) & 1);
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
#ifdef CPU_TOP
    Axi4Mem ax(b.mem(), o.seed * 13 + 5);
    AxiLite al(b.mem(), o.seed * 17 + 3);
#else
    DCacheModel dc(b.mem(), o.seed * 13 + 5, o.dhit);
#endif
    std::unique_ptr<Top> d(new Top);
#ifdef CPU_TOP
    d->sim_uc_line = b.symbol("tohost") >> 6;          // HTIF's line: not cached (Plan/CORE.md 5.1 rule 2)
#endif
    d->clk = 0; d->boot = 0; d->boot_pc = 0;
    bool icf_q = false;                                 // FENCE.I: the I$ model holds nothing, its invalidate is done a cycle later
#ifndef CPU_TOP
    bool flq_q = false;                                 // FENCE.I: the D$ model (Memory) has nothing to write back
#endif
    d->ic_req_ready = 0; d->ic_resp_valid = 0;
    d->rst_n = 1; d->eval(); d->rst_n = 0; d->eval(); d->rst_n = 1; d->eval();
    // the register file starts at 0, as Spike's: it has no reset (a boot ROM would clear it), and a program's
    // start may save registers it has not written yet (CoreMark's does)
    for (int i = 0; i < 64; i++) {
        d->rootp->CORE(u_prf__DOT__g_bank__BRA__0__KET____DOT__mem)[i] = 0;
        d->rootp->CORE(u_prf__DOT__g_bank__BRA__1__KET____DOT__mem)[i] = 0;
        d->rootp->CORE(u_prf__DOT__g_bank__BRA__2__KET____DOT__mem)[i] = 0;
        d->rootp->CORE(u_prf__DOT__lvt)[i] = 0;
    }
    long restores = 0, replays = 0;
    bool res_bad = false;
    for (uint64_t cyc = 0; !b.done(); cyc++) {
        d->boot = cyc == 2;
        d->boot_pc = b.entry() >> 1;
        d->ic_req_ready = ic.ready();
        d->ic_resp_valid = ic.resp_valid();
        { uint32_t w[4]; ic.resp_data(w); for (int k = 0; k < 4; k++) d->ic_resp_data[k] = w[k]; }
        d->ic_done = icf_q;
#ifdef CPU_TOP
        ax.drive();
        d->m_axi4_arready = ax.arready; d->m_axi4_awready = ax.awready; d->m_axi4_wready = ax.wready;
        d->m_axi4_rvalid = ax.rvalid; d->m_axi4_rdata = ax.rdata; d->m_axi4_rlast = ax.rlast; d->m_axi4_rresp = 0;
        d->m_axi4_bvalid = ax.bvalid; d->m_axi4_bresp = 0;
        al.drive();
        d->m_axil_arready = al.arready; d->m_axil_awready = al.awready; d->m_axil_wready = al.wready;
        d->m_axil_rvalid = al.rvalid; d->m_axil_rdata = al.rdata; d->m_axil_rresp = 0;
        d->m_axil_bvalid = al.bvalid; d->m_axil_bresp = 0;
#else
        d->dc_hit = dc.hit(); d->dc_rdata = dc.rdata();
        d->dc_fill_valid = dc.fill_valid(); d->dc_fill_tag = dc.fill_tag(); d->dc_fill_data = dc.fill_data();
        d->dc_st_ready = dc.st_ready();
        d->fl_take = 1; d->fl_done = flq_q;
#endif
        d->eval();
        // the commit trace
        TraceSlot s[2];
        int n = 0;
        if (d->tr_trap) {
            s[0] = TraceSlot{};
            s[0].pc = wbits(d->tr_trap_pc, 0, VA - 1) << 1;
            s[0].trap = true; s[0].cause = d->tr_cause | ((uint64_t)d->tr_int << 63);   // (mcause's interrupt bit)
            s[0].insn[0] = (uint32_t)wbits(d->tr_insn, 0, 32);           // the head's instruction
            if ((s[0].insn[0] & 3) != 3) s[0].insn[0] &= 0xffff;
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
                if ((d->tr_st >> k) & 1) {
                    t.st[0].v = true;
                    t.st[0].addr = wbits(d->tr_st_addr, 64 * k, 64);
                    t.st[0].size = 1 << ((d->tr_st_size >> (2 * k)) & 3);
                    t.st[0].data = wbits(d->tr_st_data, 64 * k, 64) & (t.st[0].size == 8 ? ~0ull : ((1ull << (8 * t.st[0].size)) - 1));
                }
            }
        }
        restores += d->rootp->CORE(restore);
        replays += d->rootp->CORE(replay);
        {
            std::string why = check_resolution(d->rootp);
            if (!why.empty()) { std::printf("cycle %llu: %s\n", (unsigned long long)cyc, why.c_str()); res_bad = true; break; }
        }
        bool icf = d->ic_flush;                         // (sampled before the clock edge)
#ifndef CPU_TOP
        bool flr = d->fl_req;                           // taken now (fl_take is 1): done in the next cycle
#endif
        bool acc = d->ic_req_valid && ic.ready();
        uint64_t rpc = d->ic_req_pc;
#ifdef CPU_TOP
        bool arv = d->m_axi4_arvalid, rr = d->m_axi4_rready, awv = d->m_axi4_awvalid, wv = d->m_axi4_wvalid, br = d->m_axi4_bready;
        uint64_t ara = d->m_axi4_araddr, awa = d->m_axi4_awaddr, wd = d->m_axi4_wdata;
        int arl = d->m_axi4_arlen, awl = d->m_axi4_awlen; uint8_t ws = d->m_axi4_wstrb;
        bool larv = d->m_axil_arvalid, lrr = d->m_axil_rready, lawv = d->m_axil_awvalid, lwv = d->m_axil_wvalid, lbr = d->m_axil_bready;
        uint64_t lara = d->m_axil_araddr, lawa = d->m_axil_awaddr, lwd = d->m_axil_wdata; uint8_t lws = d->m_axil_wstrb;
#else
        bool dreq = d->dc_req_valid, dfr = d->dc_fill_ready, dst = d->dc_st_valid;
        uint64_t dad = d->dc_req_addr, dsa = d->dc_st_addr, dsd = d->dc_st_data;
        int dtg = d->dc_req_tag; unsigned dkill = d->dc_kill; uint8_t dsm = d->dc_st_mask;
#endif
        if (!b.commit(s, n)) break;
        if (!b.tick()) break;
        d->clk = 1; d->eval(); d->clk = 0; d->eval();
        icf_q = icf && !icf_q;
#ifndef CPU_TOP
        flq_q = flr;
#endif
        ic.clock(acc, rpc);
#ifdef CPU_TOP
        ax.clock(arv, ara, arl, rr, awv, awa, awl, wv, wd, ws, br);
        al.clock(larv, lara, lrr, lawv, lawa, lwv, lwd, lws, lbr);
#else
        dc.clock(dreq, dad, dtg, dkill, dfr, dst, dsa, dsd, dsm);
#endif
    }
    std::string name = elf.substr(elf.rfind('/') + 1);
    std::printf("%s\n", b.summary(name).c_str());
    if (o.verbose)
#ifdef CPU_TOP
        std::printf("    %ld restores (mispredicted branches and jalr), %ld replays, I$ %ld / %ld missed, memory %ld line reads %ld line writes, uncached %ld reads %ld writes\n",
                    restores, replays, ic.misses, ic.reqs, ax.reads, ax.writes, al.reads, al.writes);
#else
        std::printf("    %ld restores (mispredicted branches and jalr), %ld replays, I$ %ld / %ld missed, D$ %ld / %ld loads missed, %ld stores\n",
                    restores, replays, ic.misses, ic.reqs, dc.misses, dc.reqs, dc.stores);
#endif
    if (rs_out_f) std::fprintf(rs_out_f, "%s %ld\n", name.c_str(), restores);
    d->final();                                         // (final blocks: a build with counters prints them)
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
        else if (a == "-dhit" && i + 1 < argc) o.dhit = atoi(argv[++i]);
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
