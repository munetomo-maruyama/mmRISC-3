//---------------------------------------------------------------------------
// tb_front.cpp : B1 of Plan/CORE.md, the front end alone (OOO_FRONT: fetch
// through the I$ model, the FTQ, the restore, the fetch buffer, decode, the
// D1 / D2 group register), on real programs against Spike's path
//
//   tb_front [-seed <n>] [-full] [-miss <%>] [-lag <n>] [-mpki-max <x>] [-max <cycles>] [-v] <elf> ...
//
// The program is loaded into the bench's Memory (bench.h) and fetched
// through ICacheModel (ports.h; -miss: % of the requests that miss, default
// 8; -full: no misses and D2 takes 2 instructions every cycle, to see what
// the front end delivers). Spike (LOCKSTEP's reference, step_ref) gives
// the true path. A back end of the bench stands in for D2 to commit:
//   - D2 takes 0 to 2 instructions a cycle from the group register (at most
//     one predicted taken, whose target it reads from the target array);
//   - on the true path each must be the next instruction of Spike's run:
//     pc, bits, length, last parcel; decode's illegal only where Spike
//     traps with an illegal instruction. Its predicted next address (the
//     block's target if it is predicted taken, else the next instruction)
//     is compared with Spike's next pc;
//   - a wrong next address is a misprediction: 1 to 6 cycles later the
//     front end is redirected (restore: the instruction's block and last
//     parcel, its outcome, call / return, on a random ALU port, the other
//     port's fields random); until then D2 goes on taking the wrong path,
//     not checked, and resolves some of its branches with random outcomes
//     (the restore must clear them from the kept block);
//   - a trap, a SYSTEM instruction (CSR, MRET, ...) and FENCE.I redirect at
//     their commit (fe_flush: the FTQ emptied; fetch at Spike's next pc);
//   - the true path's conditional branches resolve 1 to 3 cycles after D2
//     takes them (rs_*: block, last parcel, outcome: the TAGE update), its
//     indirect jumps update the BTB;
//   - commit, in order, 4 to 10 cycles after D2 takes an instruction, 2 a
//     cycle: its store goes into Memory (so FENCE.I sees the code written),
//     and the FTQ pops as OOO_CTRL pops it (the blocks before the block of
//     the latest commit, one a cycle; a flush drops the rest).
// A run passes when Spike's run reaches its HTIF exit on the true path with
// no mismatch. The mispredictions per 1000 instructions show whether the
// predictors are trained (the TAGE update through the FTQ's head read).
//---------------------------------------------------------------------------
#include "VOOO_FRONT.h"
#include "VOOO_FRONT___024root.h"
#include "verilated.h"

#include "bench.h"
#include "ports.h"

#include <cstdio>
#include <cstdlib>
#include <deque>
#include <algorithm>
#include <map>
#include <memory>
#include <random>
#include <string>
#include <vector>

static const int VA = 39;

template <class W> static uint64_t wbits(const W& w, int lo, int n)
{
    uint64_t v = 0;
    for (int i = 0; i < n; i++) { int b = lo + i; if ((w[b / 32] >> (b % 32)) & 1) v |= 1ull << i; }
    return v;
}
static int ilen(uint32_t insn) { return (insn & 3) == 3 ? 4 : 2; }
static bool link(uint32_t r) { return r == 1 || r == 5; }

// call / return as predecode sees them (SIM/OOO_UNIT/predec_ref.h)
static void cti_kind(uint32_t x, bool& call, bool& ret, bool& ijmp)
{
    call = ret = ijmp = false;
    if ((x & 3) == 3) {
        uint32_t op = x & 0x7f, rd = (x >> 7) & 31, rs1 = (x >> 15) & 31;
        if (op == 0x6f) call = link(rd);
        if (op == 0x67) { call = link(rd); ret = link(rs1) && !link(rd); ijmp = !ret; }
    } else if ((x & 3) == 2 && (x >> 13) == 4 && ((x >> 2) & 31) == 0 && ((x >> 7) & 31) != 0) {
        if ((x >> 12) & 1) call = true; else ret = link((x >> 7) & 31);
        ijmp = !ret;
    }
}

struct Opts { uint64_t seed = 1; int lag = -1; double mpki_max = 0; bool full = false; int miss = 8; uint64_t max = 20000000; bool verbose = false; };

struct Result { bool pass = false; std::string why; std::map<uint64_t, long> by_pc; long updates = 0, restores = 0, lag_sum = 0, pushes = 0, insns = 0, cycles = 0, misp = 0, m_br = 0, m_ret = 0, m_ind = 0, m_other = 0, flush = 0, wrong = 0, taken_cyc = 0; long imiss = 0, ireq = 0; };

static Result run(const std::string& elf, const Opts& o)
{
    Result res;
    BenchCfg bc; bc.elf = elf; bc.lockstep = false;
    Bench b(bc);
    LockstepCfg lc; lc.elf = elf;
    Lockstep ref(lc);
    ICacheModel ic(b.mem(), o.seed * 7 + 1, o.full ? 0 : o.miss);
    std::mt19937_64 rng(o.seed);

    auto ctx = std::make_unique<VerilatedContext>();
    ctx->randReset(2);
    ctx->randSeed((int)(o.seed & 0x7fffffff));
    auto d = std::make_unique<VOOO_FRONT>(ctx.get());

    // Spike's path, one ahead
    std::deque<Commit> tq;
    bool tq_end = false;            // the last record in tq is the exit
    auto fill = [&](size_t n) {
        while (tq.size() < n && !tq_end) { tq.push_back(ref.step_ref()); if (ref.exited()) tq_end = true; }
    };
    auto fail = [&](const std::string& s) { if (res.why.empty()) { char c[48]; snprintf(c, sizeof c, "cycle %ld: ", res.cycles); res.why = c + s; } };

    struct Redir { long when = 0; bool flush = false; uint64_t pc = 0; int ftq = 0, e = 0, port = 0; bool taken = false, call = false, ret = false; };
    bool pend = false; Redir rd;
    struct Cm { long ready; int ftq; Commit rec; bool flush; uint64_t next; int e; };
    std::deque<Cm> cq;
    struct Rs { long due; int ftq, e; bool taken, wrong; };
    std::deque<Rs> rsq;
    std::deque<std::pair<uint64_t, uint64_t>> btq;
    int fhd = 0, ftgt = 0;           // OOO_CTRL's FTQ head mirror and pop target
    int exp_ex[8] = {0}, exp_tk[8] = {0};    // per FTQ block: the true path's conditional branches resolved, by parcel
    struct Pushed { bool v = false; uint64_t line = 0, ras_val = 0; int ras_ptr = 0; uint32_t tmeta[9] = {0}; };
    Pushed pushed[8];                         // per FTQ entry: what its push wrote
    long npush = 0, push_at[8] = {0};         // blocks pushed, and the count when each entry was pushed
    long last_take = 0, last_ready = 0;

    d->clk = 0; d->rst_n = 1; d->eval(); d->rst_n = 0; d->eval(); d->rst_n = 1; d->eval();
    fill(2);
    bool started = false, done = false;
    for (long cyc = 0; cyc < (long)o.max && !done && res.why.empty(); cyc++) {
        res.cycles = cyc;
        // ---- commit (up to 2), and the redirect of this cycle
        bool R = false; Redir rr;
        int tgt = ftgt;
        for (int k = 0; k < 2 && !cq.empty() && cq.front().ready <= cyc; k++) {
            Cm c = cq.front(); cq.pop_front();
            if (c.rec.st && !c.rec.trap) b.mem().poke(c.rec.st_addr, &c.rec.st_data, c.rec.st_size);
            tgt = c.ftq;
            if (c.flush) {                                   // a redirect at its commit
                R = true; rr = Redir{}; rr.flush = true; rr.pc = c.next; rr.ftq = c.ftq; rr.e = c.e;
                pend = false;
                break;
            }
        }
        if (!started && cyc == 2) { R = true; rr = Redir{}; rr.flush = true; rr.pc = tq.front().pc; started = true; }
        if (!R && pend && rd.when <= cyc) { R = true; rr = rd; pend = false; }
        int pop = tgt != fhd ? 1 : 0;
        d->ftq_pop = pop;
        d->fe_redirect = R; d->fe_flush = rr.flush; d->fe_pc = rr.pc >> 1;
        d->restore_ftq = rr.ftq; d->restore_port = rr.port;
        {
            unsigned e2 = (unsigned)(rng() % 64), tk = rng() % 4, cl = rng() % 4, rt = rng() % 4;     // the other port: random
            int p = rr.port;
            e2 = (e2 & ~(7u << (3 * p))) | ((unsigned)rr.e << (3 * p));
            tk = (tk & ~(1u << p)) | ((unsigned)rr.taken << p);
            cl = (cl & ~(1u << p)) | ((unsigned)rr.call << p);
            rt = (rt & ~(1u << p)) | ((unsigned)rr.ret << p);
            d->br_e = e2; d->br_taken = tk; d->br_call = cl; d->br_ret = rt;
        }
        d->rcv_ftq = rr.ftq; d->rcv_end = rr.e;
        // resolutions due (at most 2)
        unsigned rv = 0, rf = 0, re = 0, rt = 0, rwrong = 0;
        for (int k = 0, i = 0; k < 2 && i < (int)rsq.size();) {
            if (rsq[i].due <= cyc) {
                rv |= 1u << k; rf |= (unsigned)rsq[i].ftq << (3 * k); re |= (unsigned)rsq[i].e << (3 * k); rt |= (unsigned)rsq[i].taken << k;
                rwrong |= (unsigned)rsq[i].wrong << k;
                rsq.erase(rsq.begin() + i); k++;
            } else i++;
        }
        d->rs_valid = rv; d->rs_ftq = rf; d->rs_e = re; d->rs_taken = rt;
        for (int k = 0; k < 2; k++)
            if ((rv >> k) & 1 && (rwrong >> k & 1) == 0) {
                int f = (rf >> (3 * k)) & 7, e = (re >> (3 * k)) & 7;
                exp_ex[f] |= 1 << e; exp_tk[f] = (exp_tk[f] & ~(1 << e)) | (int)((rt >> k) & 1) << e;
            }
        bool bt = !btq.empty();
        d->bt_valid = bt; d->bt_pc = bt ? btq.front().first : 0; d->bt_tgt = bt ? btq.front().second : 0;
        if (bt) btq.pop_front();
        // I$
        d->ic_req_ready = ic.ready();
        d->ic_resp_valid = ic.resp_valid();
        { uint32_t w[4]; ic.resp_data(w); for (int k = 0; k < 4; k++) d->ic_resp_data[k] = w[k]; }
        d->g_take = 0;
        d->ta_idx = 0;
        d->eval();

        auto* rp = d->rootp;
        if (R && d->ic_req_valid) fail("an I$ request in the cycle of a redirect");
        // the restore (cycle R + 1) reads back what the block's push wrote
        if (rp->OOO_FRONT__DOT__be_redirect && pushed[rp->OOO_FRONT__DOT__rs_idx].v) {
            const Pushed& w = pushed[rp->OOO_FRONT__DOT__rs_idx];
            bool ok = (uint64_t)rp->OOO_FRONT__DOT__ft_line == w.line && (int)rp->OOO_FRONT__DOT__ft_ras_ptr == w.ras_ptr &&
                      (uint64_t)rp->OOO_FRONT__DOT__ft_ras_val == w.ras_val &&
                      (int)rp->OOO_FRONT__DOT__ft_sv == (int)wbits(w.tmeta, 194, 3) && (int)rp->OOO_FRONT__DOT__ft_par == (int)wbits(w.tmeta, 185, 9);
            for (int b2 = 0; b2 < 70 && ok; b2++) ok = wbits(rp->OOO_FRONT__DOT__ft_hist, b2, 1) == wbits(w.tmeta, 200 + b2, 1);
            if (!ok) fail("the restore does not read back the block's push (line, history, slots, RAS)");
            res.restores++;
        }
        // ---- the TAGE update of the popped block: its metadata, the slots that ran and their outcomes
        if (pop) {
            if (pushed[fhd].v)
                for (int k = 0; k < 9; k++)
                    if (rp->OOO_FRONT__DOT__up_meta[k] != pushed[fhd].tmeta[k]) { fail("the TAGE update's metadata is not the block's"); break; }
            const int TM = 42;
            int sv = (int)wbits(rp->OOO_FRONT__DOT__hd_meta, TM + 194, 3);
            int ex = 0, tk = 0;
            for (int s2 = 0; s2 < 3; s2++) {
                int par = (int)wbits(rp->OOO_FRONT__DOT__hd_meta, TM + 185 + 3 * s2, 3);
                if ((sv >> s2) & 1 && (exp_ex[fhd] >> par) & 1) { ex |= 1 << s2; tk |= ((exp_tk[fhd] >> par) & 1) << s2; }
            }
            int uex = rp->OOO_FRONT__DOT__up_ex, utk = rp->OOO_FRONT__DOT__up_tk;
            if (!rp->OOO_FRONT__DOT__up_valid || uex != ex || (utk & ex) != tk) {
                char m[128]; snprintf(m, sizeof m, "TAGE update of block %d: valid %d ex %d tk %d, expected ex %d tk %d", fhd,
                                      (int)rp->OOO_FRONT__DOT__up_valid, uex, utk & uex, ex, tk);
                fail(m);
            }
            res.updates++;
            res.lag_sum += npush - push_at[fhd];
        }

        // ---- D2 takes from the group
        int gv = d->g_valid, nvalid = __builtin_popcount(gv), head = gv ? __builtin_ctz(gv) : 0;
        int take = 0;
        if (!R && started) {
            take = o.full ? 2 : (int)(rng() % 3);
            if (take > nvalid) take = nvalid;
            int ntk = 0;
            for (int i = 0; i < take; i++) if ((d->g_taken >> (head + i)) & 1) { if (ntk++) { take = i; break; } }
        }
        int tslot = -1;
        for (int i = 0; i < take; i++) if ((d->g_taken >> (head + i)) & 1) tslot = head + i;
        d->ta_idx = tslot >= 0 ? (int)((d->g_ftq >> (3 * tslot)) & 7) : 0;
        d->g_take = take;
        d->eval();
        if (take) { res.taken_cyc++; last_take = cyc; }
        for (int i = 0; i < take && res.why.empty(); i++) {
            int k = head + i;
            uint64_t pc = wbits(d->g_pc, 38 * k, 38) << 1;
            uint32_t insn = (uint32_t)wbits(d->g_insn, 32 * k, 32);
            bool rvc = (d->g_rvc >> k) & 1, tk = (d->g_taken >> k) & 1, ill = (d->g_illegal >> k) & 1;
            int ftq = (int)((d->g_ftq >> (3 * k)) & 7), e = (int)((d->g_end >> (3 * k)) & 7);
            bool isbr = (d->g_is_branch >> k) & 1;
            if (pend) {                                     // the wrong path: some branches resolved at random
                res.wrong++;
                if (isbr && rng() % 2) rsq.push_back(Rs{cyc + 1, ftq, e, (bool)(rng() % 2), true});
                continue;
            }
            fill(2);
            if (tq.empty()) { fail("the front end went past Spike's exit"); break; }
            Commit x = tq.front();
            int len = ilen(x.insn);
            uint32_t m = len == 4 ? 0xffffffffu : 0xffffu;
            if (pc != x.pc) { char s[96]; snprintf(s, sizeof s, "pc %llx, Spike %llx", (unsigned long long)pc, (unsigned long long)x.pc); fail(s); break; }
            if ((insn & m) != x.insn || rvc != (len == 2)) { char s[96]; snprintf(s, sizeof s, "pc %llx: instruction %08x, Spike %08x", (unsigned long long)pc, insn, x.insn); fail(s); break; }
            if (e != (int)(((pc >> 1) + len / 2 - 1) & 7)) { fail("last parcel"); break; }
            if (ill && !(x.trap && x.cause == 2)) { char s[96]; snprintf(s, sizeof s, "pc %llx: decoded illegal, Spike does not trap so", (unsigned long long)pc); fail(s); break; }
            // the classes decode gives only in slot 0 (cut): CSR, FP, system
            {
                uint32_t op7 = x.insn & 0x7f, f3 = (x.insn >> 12) & 7, q = x.insn & 3, c3 = (x.insn >> 13) & 7;
                bool csr = len == 4 && op7 == 0x73 && f3 != 0 && f3 != 4;
                bool fp = len == 4 ? (op7 == 0x07 || op7 == 0x27 || op7 == 0x53 || op7 == 0x43 || op7 == 0x47 || op7 == 0x4b || op7 == 0x4f)
                                   : ((q == 0 || q == 2) && (c3 == 1 || c3 == 5));
                bool sysi = len == 4 && op7 == 0x73 && f3 == 0;
                bool gcsr = (d->g_is_csr >> k) & 1, gfp = (d->g_is_fp >> k) & 1, gsys = ((d->g_sys >> (8 * k)) & 0xf8) != 0 || ((d->g_is_sfence >> k) & 1);
                if (!ill && (gcsr != csr || gfp != fp || (sysi && !gsys))) {
                    char s[128]; snprintf(s, sizeof s, "pc %llx (%08x, slot %d): decoded csr %d fp %d sys %d", (unsigned long long)pc, x.insn, k, gcsr, gfp, gsys);
                    fail(s); break;
                }
            }
            res.insns++;
            bool last = tq_end && tq.size() == 1;
            tq.pop_front();
            if (last) { done = true; res.pass = true; break; }   // Spike's exit, reached on the true path
            fill(1);
            uint64_t T = tq.front().pc;
            uint64_t P = tk ? (uint64_t)d->ta_tgt << 1 : pc + len;
            bool call, ret, ijmp;
            cti_kind(x.insn, call, ret, ijmp);
            uint32_t op = x.insn & 0x7f;
            bool sys = len == 4 && op == 0x73, fencei = len == 4 && op == 0x0f && ((x.insn >> 12) & 7) == 1;
            bool flush = x.trap || sys || fencei;
            // commit (the block may pop in its cycle), and before it the branch's resolution
            long ready = std::max(last_ready, o.lag >= 0 ? cyc + std::max(o.lag, 2) : cyc + 4 + (long)(rng() % 7));
            if (isbr && !x.trap) rsq.push_back(Rs{std::min(ready - 1, cyc + 1 + (long)(rng() % (flush || T != P ? 1 : 3))), ftq, e, T != pc + len, false});
            if (ijmp && !x.trap) btq.push_back({((pc >> 1) + len / 2 - 1), T >> 1});
            last_ready = ready;
            cq.push_back(Cm{ready, ftq, x, flush, T, e});
            if (flush) { pend = true; rd = Redir{}; rd.when = ~0ul >> 1; res.flush++; }    // redirected at its commit
            else if (T != P) {
                pend = true; rd = Redir{};
                rd.when = cyc + 2 + (long)(rng() % 6);
                rd.pc = T; rd.ftq = ftq; rd.e = e; rd.port = (int)(rng() % 2);
                rd.taken = T != pc + len; rd.call = call; rd.ret = ret;
                res.misp++;
                // (by_pc[pc | 1]: those taken, predicted not taken)
                if (isbr) { res.m_br++; res.by_pc[pc]++; if (T != pc + len) res.by_pc[pc | 1]++; } else if (ret) res.m_ret++; else if (ijmp) res.m_ind++; else res.m_other++;
            }
        }

        // ---- the clock (a block pushed now: what the restore and the update must read back)
        if (rp->OOO_FRONT__DOT__out_valid) {
            Pushed& w = pushed[rp->OOO_FRONT__DOT__push_idx];
            w.v = true; w.line = (uint64_t)rp->OOO_FRONT__DOT__out_pc >> 3;
            push_at[rp->OOO_FRONT__DOT__push_idx] = npush++;
            w.ras_ptr = rp->OOO_FRONT__DOT__out_ras_ptr; w.ras_val = rp->OOO_FRONT__DOT__out_ras_val;
            for (int k = 0; k < 9; k++) w.tmeta[k] = rp->OOO_FRONT__DOT__out_tmeta[k];
        }
        bool acc = d->ic_req_valid && ic.ready();
        uint64_t rpc = d->ic_req_pc;
        d->clk = 1; d->eval(); d->clk = 0; d->eval();
        ic.clock(acc, rpc);
        if (pop) exp_ex[fhd] = 0;
        fhd = (fhd + pop) % 8;
        ftgt = (R && rr.flush) ? fhd : tgt;
        if (R && !rr.flush) exp_ex[rr.ftq] &= (2 << rr.e) - 1;   // (only the true path's are recorded)
        if (R && rr.flush) for (int f = 0; f < 8; f++) exp_ex[f] = 0;
        if (R) {                                          // the wrong path's resolutions still queued never come
            for (size_t i = 0; i < rsq.size();) if (rsq[i].wrong) rsq.erase(rsq.begin() + i); else i++;
            if (rr.flush) cq.clear();                     // (nothing younger than a flush is in it)
        }
        if (started && cyc - last_take > 5000) fail("no instruction for 5000 cycles");
    }
    if (!done && res.why.empty()) fail("no exit in the cycle limit");
    if (res.why.empty() && o.mpki_max > 0 && 1000.0 * res.misp / res.insns > o.mpki_max) {
        char m[96]; snprintf(m, sizeof m, "%.2f mispredictions per 1000 instructions, more than %.2f", 1000.0 * res.misp / res.insns, o.mpki_max);
        fail(m); res.pass = false;
    }
    res.imiss = ic.misses; res.ireq = ic.reqs; res.pushes = npush;
    d->final();
    return res;
}

int main(int argc, char** argv)
{
    Opts o;
    std::vector<std::string> elfs;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-seed" && i + 1 < argc) o.seed = strtoull(argv[++i], nullptr, 0);
        else if (a == "-full") o.full = true;
        else if (a == "-lag" && i + 1 < argc) o.lag = atoi(argv[++i]);
        else if (a == "-mpki-max" && i + 1 < argc) o.mpki_max = atof(argv[++i]);
        else if (a == "-miss" && i + 1 < argc) o.miss = atoi(argv[++i]);
        else if (a == "-max" && i + 1 < argc) o.max = strtoull(argv[++i], nullptr, 0);
        else if (a == "-v") o.verbose = true;
        else if (a[0] == '+') continue;            // Verilator's
        else elfs.push_back(a);
    }
    int fails = 0;
    long ti = 0, tc = 0, tm = 0;
    for (auto& e : elfs) {
        std::string name = e.substr(e.find_last_of('/') + 1);
        Result r;
        try { r = run(e, o); } catch (std::exception& ex) { r.why = ex.what(); }
        printf("%-28s %s  %8ld insns  %8ld cycles  %.3f insns/cycle  %5ld mispredicted (%.2f / 1000)  %4ld flushes  %6ld wrong-path  I$ %ld / %ld missed\n",
               name.c_str(), r.pass ? "PASS" : "FAIL", r.insns, r.cycles, r.cycles ? (double)r.insns / r.cycles : 0.0, r.misp,
               r.insns ? 1000.0 * r.misp / r.insns : 0.0, r.flush, r.wrong, r.imiss, r.ireq);
        if (o.verbose) printf("    mispredicted: conditional branch %ld, return %ld, other jalr %ld, other %ld; %ld TAGE updates and %ld restores checked\n", r.m_br, r.m_ret, r.m_ind, r.m_other, r.updates, r.restores);
        if (o.verbose && r.updates)
            printf("    blocks pushed between a block's push and its update: %.1f on average (%ld pushed, %ld updated: %.1f on the true path)\n",
                   (double)r.lag_sum / r.updates, r.pushes, r.updates, (double)r.lag_sum / r.updates * r.updates / r.pushes);
        if (getenv("FRONT_BYPC")) {             // the conditional branches mispredicted most (pc count)
            std::vector<std::pair<long, uint64_t>> v;
            for (auto& x : r.by_pc) v.push_back({x.second, x.first});
            std::sort(v.rbegin(), v.rend());
            for (size_t k = 0; k < v.size() && k < 25; k++) printf("    bypc %llx %ld\n", (unsigned long long)v[k].second, v[k].first);
        }
        if (!r.pass) { printf("    %s\n", r.why.c_str()); fails++; }
        ti += r.insns; tc += r.cycles; tm += r.misp;
    }
    printf("tb_front: %zu files, %ld instructions, %ld cycles, %ld mispredicted, %d failures: %s\n", elfs.size(), ti, tc, tm, fails, fails ? "FAIL" : "PASS");
    return fails;
}
