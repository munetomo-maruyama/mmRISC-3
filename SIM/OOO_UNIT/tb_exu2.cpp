//---------------------------------------------------------------------------
// tb_exu2.cpp : OOO_EXU2 against a reference
//
// Every cycle random µops enter RR on the 6 ports, with sources among the registers
// whose result is in r_ex in the next cycle (EX's mux), or in this one or earlier (the
// register file, modelled here, written from wb_* at the end of the cycle before that,
// so a source read too early gets a stale value). Each value comes from ref_alu, written
// from the RISC-V specification: a result, a branch, a jalr, an address, a store's data,
// the sources for the multiplier. Loads on their 2 write ports, and results from
// outside on ports 0 and 1, arrive at any time their write slots are free, with µops
// that write nothing running beside them. A source not in use names a register about to
// be written. A flush drops all in flight.
//---------------------------------------------------------------------------
#include "VOOO_EXU2.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <vector>

static std::mt19937_64 rng(12345);

static uint64_t rval()
{
    switch (rng() % 8) {
    case 0: return 0;
    case 1: return ~0ull;
    case 2: return 1ull << (rng() % 64);
    case 3: return (uint64_t)(int64_t)(int32_t)rng();
    case 4: return rng() % 70;
    default: return rng();
    }
}
static uint64_t sx32(uint64_t v) { return (uint64_t)(int64_t)(int32_t)(uint32_t)v; }
static int clz64(uint64_t v) { int n = 0; for (int i = 63; i >= 0 && !((v >> i) & 1); i--) n++; return n; }
static int ctz64(uint64_t v) { int n = 0; for (int i = 0; i < 64 && !((v >> i) & 1); i++) n++; return n; }

// as tb_alu2
static uint64_t ref_alu(int op, uint64_t a, uint64_t b, bool uw, int shift, bool word)
{
    uint64_t r = 0;
    uint64_t az = uw ? (a & 0xffffffffull) : a;
    unsigned sh = word ? (b & 31) : (b & 63);
    uint32_t a32 = (uint32_t)a;
    switch (op) {
    case 1: r = a - b; break;
    case 2: r = word ? (uint64_t)(a32 << sh) : (az << sh); break;
    case 3: r = (int64_t)a < (int64_t)b; break;
    case 4: r = a < b; break;
    case 5: r = a ^ b; break;
    case 6: r = word ? (uint64_t)(a32 >> sh) : (az >> sh); break;
    case 7: r = word ? (uint64_t)(int64_t)((int32_t)a32 >> sh) : (uint64_t)((int64_t)az >> sh); break;
    case 8: r = a | b; break;
    case 9: r = a & b; break;
    case 10: r = a & ~b; break;
    case 11: r = a | ~b; break;
    case 12: r = ~(a ^ b); break;
    case 13: r = (int64_t)a < (int64_t)b ? a : b; break;
    case 14: r = a < b ? a : b; break;
    case 15: r = (int64_t)a < (int64_t)b ? b : a; break;
    case 16: r = a < b ? b : a; break;
    case 17: r = word ? (uint64_t)(uint32_t)((a32 << sh) | (sh ? a32 >> (32 - sh) : 0))
                      : ((a << sh) | (sh ? a >> (64 - sh) : 0)); break;
    case 18: r = word ? (uint64_t)(uint32_t)((a32 >> sh) | (sh ? a32 << (32 - sh) : 0))
                      : ((a >> sh) | (sh ? a << (64 - sh) : 0)); break;
    case 19: r = word ? clz64((uint64_t)a32 << 32 | 0xffffffffull) : clz64(a); break;
    case 20: r = word ? ctz64(0xffffffff00000000ull | a32) : ctz64(a); break;
    case 21: r = word ? __builtin_popcountll(a32) : __builtin_popcountll(a); break;
    case 22: r = (uint64_t)(int64_t)(int8_t)a; break;
    case 23: r = (uint64_t)(int64_t)(int16_t)a; break;
    case 24: r = a & 0xffff; break;
    case 25: for (int i = 0; i < 8; i++) if ((a >> (8 * i)) & 0xff) r |= 0xffull << (8 * i); break;
    case 26: for (int i = 0; i < 8; i++) r |= ((a >> (8 * i)) & 0xff) << (8 * (7 - i)); break;
    case 27: r = b == 0 ? 0 : a; break;
    case 28: r = b != 0 ? 0 : a; break;
    case 29: r = a | (1ull << (b & 63)); break;
    case 30: r = a & ~(1ull << (b & 63)); break;
    case 31: r = a ^ (1ull << (b & 63)); break;
    case 32: r = (a >> (b & 63)) & 1; break;
    default: r = (az << shift) + b; break;
    }
    return word ? sx32(r) : r;
}

static const int NA = 4, NP = 6, NS = 6, NT = 80, H = 16;

// packed ports
static void put64(uint32_t* w, int i, uint64_t v) { w[2 * i] = (uint32_t)v; w[2 * i + 1] = (uint32_t)(v >> 32); }
static uint64_t get64(const uint32_t* w, int i) { return (uint64_t)w[2 * i] | (uint64_t)w[2 * i + 1] << 32; }

struct Exp { bool v = false; int t = 0; uint64_t d = 0; };
struct InEx {                  // what shows in EX
    bool ag[2] = {}; uint64_t adr[2] = {}; uint64_t sd = 0;
};
struct Later {                 // what shows in EX + 1
    bool br[NA] = {}; bool tk[NA] = {};
    bool jr = false; uint64_t tgt = 0;
    bool slow = false; uint64_t a0 = 0, b0 = 0;
};

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    VOOO_EXU2 d;
    long bad = 0;
    auto fail = [&](long c, const char* what, uint64_t got, uint64_t exp) {
        if (bad++ < 12) printf("MISMATCH cycle %ld %s: %016llx expected %016llx\n", c, what, (unsigned long long)got, (unsigned long long)exp);
    };

    uint64_t prf[NT], val[NT];
    long T[NT];
    bool live[NT];
    std::deque<int> fr;
    for (int i = 0; i < NT; i++) { prf[i] = rng(); val[i] = 0; T[i] = -1000; live[i] = false; if (i) fr.push_back(i); }
    // (tag 0 is x0: a constant zero, never written; it is never allocated here)
    Exp ex[NS][H];
    Later lt[H];
    InEx ie[H];
    bool p_fl = false;
    bool p_nw[2] = {false, false};    // the µop in EX now on port 0, 1 writes nothing
    long cov_k[2] = {}, cov_rare = 0, cov_x0 = 0, cov_x1 = 0, cov_ld[2] = {}, cov_jr = 0, cov_br = 0, cov_nw = 0, cov_fl = 0, cov_nwx = 0, cov_xfl = 0, cov_st = 0;
    long nres = 0;

    d.rst_n = 0; d.clk = 0; d.flush = 0; d.rr_v = 0; d.ld_nv = 0; d.x0_nv = 0; d.x1_nv = 0; d.rr_slow = 0; d.rr_jalr = 0;
    for (int i = 0; i < 4; i++) { d.eval(); d.clk = 1; d.eval(); d.clk = 0; d.eval(); }
    d.rst_n = 1;

    const long CYC = 1000000;
    for (long c = 0; c < CYC; c++) {
        int burst = (c >> 12) & 3;      // quiet or busy
        int pv = burst == 0 ? 2 : burst == 1 ? 8 : 10;   // of 10

        auto alloc = [&]() { int t = fr.front(); fr.pop_front(); live[t] = false; return t; };
        // a source: a register whose result is in r_ex at c + 1 at the latest
        auto pick = [&](int& kind) {
            std::vector<int> v1, v2;
            for (int i = 1; i < NT; i++) if (live[i]) {
                if (T[i] == c + 1) v1.push_back(i);
                else if (T[i] <= c) v2.push_back(i);
            }
            int k = rng() % 4;
            if (k <= 1 && !v1.empty()) { kind = 0; return v1[rng() % v1.size()]; }
            if (!v2.empty()) { kind = 1; return v2[rng() % v2.size()]; }
            if (!v1.empty()) { kind = 0; return v1[rng() % v1.size()]; }
            kind = -1; return 0;
        };
        auto sched = [&](int s, long at, int t, uint64_t v) {
            Exp& e = ex[s][at % H];
            if (e.v) { printf("bench: slot taken\n"); exit(2); }
            e.v = true; e.t = t; e.d = v;
            T[t] = at; val[t] = v; live[t] = true;
        };

        // ---- from outside: x0 into port 0, x1 into port 1, loads into their own
        bool xn[2] = {false, false}; int xt[2] = {0, 0}; uint64_t xd[2] = {0, 0};
        for (int k = 0; k < 2; k++) {
            // (right after a flush too, on what the port might have left behind: a jalr's link)
            if ((p_fl || rng() % 10 == 0) && !ex[k][(c + 1) % H].v && fr.size() > 30) {
                xn[k] = true; xt[k] = alloc(); xd[k] = rval(); sched(k, c + 1, xt[k], xd[k]);
                (k ? cov_x1 : cov_x0)++;
                if (p_fl) cov_xfl++;
                if (p_nw[k]) cov_nwx++;
            }
        }
        bool ln[2] = {false, false}; int lt_[2] = {0, 0}; uint64_t ld[2] = {rng(), rng()};
        for (int k = 0; k < 2; k++) if (rng() % 4 == 0 && fr.size() > 30) {
            ln[k] = true; lt_[k] = alloc(); ld[k] = rval(); sched(4 + k, c + 1, lt_[k], ld[k]); cov_ld[k]++;
        }

        // ---- the ports
        unsigned rrv = 0, wr = 0, br = 0, word = 0, uw = 0;
        uint32_t use = 0;
        uint32_t shifts = 0, brops = 0;
        uint32_t ops = 0;
        uint32_t dsts = 0;
        uint32_t srcw[3] = {0, 0, 0};
        auto putsrc = [&](int i, int v) {        // 12 fields of 7 bits
            int b = 7 * i;
            uint64_t x = (uint64_t)(uint32_t)v << (b % 32);
            srcw[b / 32] |= (uint32_t)x;
            if (b / 32 < 2) srcw[b / 32 + 1] |= (uint32_t)(x >> 32);
        };
        bool slow = false, jalr = false;
        uint64_t link = rng();
        int agi[2] = {(int)(rng() & 0xfff), (int)(rng() & 0xfff)};
        Later& L = lt[(c + 2) % H];
        L = Later();
        InEx& E = ie[(c + 1) % H];
        E = InEx();
        bool n_nw[2] = {false, false};
        for (int p = 0; p < NP; p++) {
            bool v = (int)(rng() % 10) < pv;
            int kd[2] = {-1, -1};
            int st[2] = {0, 0};
            bool u[2];
            uint64_t k[2] = {rval(), rval()};
            // the µop's form
            int op = 0, sh = 0; bool w = false, z = false, isbr = false, isj = false, sl = false, wrr = false;
            bool use1 = rng() % 8 != 0, use2 = rng() & 1;
            if (p < NA) {
                int f = rng() % 20;
                static const int SIMPLE[] = {0, 1, 3, 4, 5, 8, 9, 10, 11, 12, 22, 23, 24, 27, 28};
                if (f == 0 && p == 0) { isj = true; op = 0; use2 = false; }
                else if (f <= 3) {
                    isbr = true; use1 = true;
                    if (rng() % 8 == 0) { use2 = false; k[1] = 0; } else use2 = true;
                } else if (f <= 5 && p == 0) {
                    // not in OOO_ALUF
                    sl = true;
                    int g = rng() % 4;
                    if (g == 0) { static const int R[] = {2, 6, 7}; op = R[rng() % 3]; use2 = true; w = rng() & 1; }   // by a register
                    else if (g == 1) { op = 2; use2 = false; z = true; k[1] = rng() % 64; }              // slli.uw
                    else if (g == 2) { op = 32; use2 = true; }                                                    // bext
                    else {
                        static const int R[] = {13, 14, 15, 16, 17, 18, 19, 20, 21, 25, 26, 29, 30, 31};
                        op = R[rng() % 14];
                        if (op >= 17 && op <= 21) w = rng() & 1;
                    }
                } else if (f <= 8) {
                    // a shift by an immediate
                    static const int R[] = {2, 6, 7, 32};
                    op = R[rng() % 4];
                    use2 = false;
                    if (op != 32) w = rng() & 1;
                    k[1] = rng() % 3 == 0 ? 0 : rng() % (w ? 32 : 64);
                } else if (f <= 11) {
                    int g = rng() % 5;
                    op = 0;
                    if (g == 1) w = true;
                    else if (g == 2) z = true;
                    else if (g >= 3) { sh = (int)(rng() % 3) + 1; z = rng() & 1; }
                } else {
                    op = SIMPLE[rng() % 15];
                    if (op == 0 || op == 1) w = rng() & 1;
                }
                wrr = isbr ? false : isj ? (rng() & 1) : rng() % 8 != 0;
                if (sl && !v) { sl = false; op = 0; }
            } else {
                use2 = p == 4 && (rng() & 1);       // a store's data, on port 4 alone
                use1 = rng() % 8 != 0;
            }
            u[0] = use1; u[1] = use2;
            for (int x = 0; x < 2; x++) {
                if (u[x]) {
                    st[x] = pick(kd[x]);
                    if (kd[x] < 0) { u[x] = false; }
                }
                if (!u[x]) {
                    // a source not in use names something near, which must not be taken
                    int dummy;
                    st[x] = rng() & 1 ? pick(dummy) : (int)(rng() % NT);
                }
            }
            if (isbr && !u[0]) { k[0] = rval(); }
            uint64_t a = u[0] ? val[st[0]] : k[0];
            uint64_t b = u[1] ? val[st[1]] : k[1];
            if (isbr && rng() % 4 == 0 && !u[1]) { k[1] = a; b = a; }
            if (v) for (int x = 0; x < 2; x++) if (u[x]) cov_k[kd[x]]++;
            if (p < NA) {
                long at = c + 2;
                int dst = (int)(rng() % NT);
                if (v && wrr && fr.size() > 20) {
                    dst = alloc();
                    uint64_t r = isj ? link : ref_alu(op, a, b, z, sh, w);
                    sched(p, at, dst, r);
                    if (sl) cov_rare++;
                } else if (v) { wrr = false; }
                if (v && !wrr) cov_nw++;
                if (p < 2) n_nw[p] = v && !wrr;
                if (v && isbr) {
                    int brop = (int[]){0, 1, 4, 5, 6, 7}[rng() % 6];
                    bool t = false;
                    switch (brop) {
                    case 0: t = a == b; break; case 1: t = a != b; break;
                    case 4: t = (int64_t)a < (int64_t)b; break; case 5: t = (int64_t)a >= (int64_t)b; break;
                    case 6: t = a < b; break; case 7: t = a >= b; break;
                    }
                    L.br[p] = true; L.tk[p] = t;
                    brops |= brop << (3 * p);
                    cov_br++;
                } else brops |= (rng() & 7) << (3 * p);
                if (v && isj) { L.jr = true; L.tgt = ((a + b) >> 1) & ((1ull << 38) - 1); cov_jr++; }
                if (v && sl && p == 0) { L.slow = true; L.a0 = a; L.b0 = b; }
                if (p == 0) { slow = sl && v; jalr = isj && v; }
                ops |= (uint32_t)op << (6 * p);
                if (wrr) wr |= 1u << p;
                if (isbr) br |= 1u << p;
                if (w) word |= 1u << p;
                if (z) uw |= 1u << p;
                shifts |= sh << (2 * p);
                dsts |= (uint32_t)dst << (7 * p);
            } else if (v) {
                int m = p - 4;
                E.ag[m] = true;
                E.adr[m] = a + (uint64_t)((int64_t)((uint64_t)agi[m] << 52) >> 52);
                if (m == 0) { E.sd = b; if (u[1]) cov_st++; }
            }
            if (v) rrv |= 1u << p;
            for (int x = 0; x < 2; x++) {
                if (u[x]) use |= 1u << (2 * p + x);
                putsrc(2 * p + x, st[x]);
                put64((uint32_t*)d.rr_prf.m_storage, 2 * p + x, prf[st[x]]);
                put64((uint32_t*)d.rr_const.m_storage, 2 * p + x, k[x]);
            }
        }
        // ---- flush now and then
        bool fl = rng() % 1000 == 0;
        p_fl = fl;

        d.rr_v = rrv; d.rr_use = use; d.rr_wr = wr; d.rr_dst = dsts; d.rr_op = ops;
        for (int i = 0; i < 3; i++) d.rr_src.m_storage[i] = srcw[i];
        d.rr_uw = uw; d.rr_shift = shifts; d.rr_word = word; d.rr_br = br; d.rr_brop = brops;
        d.rr_slow = slow; d.rr_jalr = jalr; put64((uint32_t*)&d.rr_link, 0, link); d.rr_agi = agi[0] | agi[1] << 12;
        d.ld_nv = (ln[0] ? 1 : 0) | (ln[1] ? 2 : 0); d.ld_nt = lt_[0] | lt_[1] << 7;
        put64((uint32_t*)d.ld_d.m_storage, 0, ld[0]); put64((uint32_t*)d.ld_d.m_storage, 1, ld[1]);
        d.x0_nv = xn[0]; d.x0_nt = xt[0]; d.x0_d = xn[0] ? xd[0] : 0;
        d.x1_nv = xn[1]; d.x1_nt = xt[1]; d.x1_d = xn[1] ? xd[1] : 0;
        d.flush = fl;
        d.eval();

        // ---- what shows now: the results that are in r_ex next cycle
        for (int s = 0; s < NS; s++) {
            Exp& e = ex[s][(c + 1) % H];
            bool ev = e.v && !fl;
            bool got = (d.wb_v >> s) & 1;
            if (got != ev) fail(c, s >= 4 ? "wb_v load" : "wb_v", got, ev);
            if (ev) {
                nres++;
                int gt = (int)((((uint64_t)d.wb_t) >> (7 * s)) & 127);
                uint64_t gd = get64((const uint32_t*)d.wb_d.m_storage, s);
                if (gt != e.t) fail(c, "wb_t", gt, e.t);
                static const char* N[] = {"wb_d 0", "wb_d 1", "wb_d 2", "wb_d 3", "wb_d load 0", "wb_d load 1"};
                if (gd != e.d) fail(c, N[s], gd, e.d);
            }
        }
        InEx& I = ie[c % H];
        for (int m = 0; m < 2; m++) {
            bool v = (d.ag_v >> m) & 1;
            if (v != I.ag[m]) fail(c, "ag_v", v, I.ag[m]);
            if (I.ag[m] && get64((const uint32_t*)d.ag.m_storage, m) != I.adr[m]) fail(c, "ag", get64((const uint32_t*)d.ag.m_storage, m), I.adr[m]);
        }
        if (I.ag[0] && d.sd != I.sd) fail(c, "sd", d.sd, I.sd);
        Later& N = lt[c % H];
        for (int p = 0; p < NA; p++) {
            bool v = (d.br_v >> p) & 1;
            if (v != N.br[p]) fail(c, "br_v", v, N.br[p]);
            if (N.br[p] && ((d.br_take >> p) & 1) != N.tk[p]) fail(c, "br_take", (d.br_take >> p) & 1, N.tk[p]);
        }
        if (d.jr_v != N.jr) fail(c, "jr_v", d.jr_v, N.jr);
        if (N.jr && d.jr_tgt != N.tgt) fail(c, "jr_tgt", d.jr_tgt, N.tgt);
        if (N.slow && (d.p0_a != N.a0 || d.p0_b != N.b0)) fail(c, "p0_a / p0_b", d.p0_a, N.a0);

        // ---- the register file, written at the end of the cycle (wb_*)
        for (int s = 0; s < NS; s++) if ((d.wb_v >> s) & 1) {
            int t = (int)((((uint64_t)d.wb_t) >> (7 * s)) & 127);
            if (t > 0 && t < NT) prf[t] = get64((const uint32_t*)d.wb_d.m_storage, s);
        }

        // ---- flush: everything not in r_ex yet goes
        if (fl) {
            cov_fl++;
            for (int s = 0; s < NS; s++) for (int h = 1; h < H; h++) {
                Exp& e = ex[s][(c + h) % H];
                if (e.v) { live[e.t] = false; T[e.t] = -1000; fr.push_back(e.t); e.v = false; }
            }
            for (int h = 1; h < H; h++) { lt[(c + h) % H] = Later(); ie[(c + h) % H] = InEx(); }
            n_nw[0] = n_nw[1] = false;
        }
        for (int s = 0; s < NS; s++) ex[s][(c + 1) % H] = Exp();
        lt[c % H] = Later();
        ie[c % H] = InEx();
        p_nw[0] = n_nw[0]; p_nw[1] = n_nw[1];

        // ---- registers die some time after their result
        for (int i = 1; i < NT; i++) if (live[i] && T[i] < c - 2 && rng() % 8 == 0) {
            live[i] = false;
            fr.push_back(i);
        }

        d.clk = 1; d.eval(); d.clk = 0; d.eval();
    }
    bool cov = cov_rare > 1000 && cov_x0 > 1000 && cov_x1 > 1000 && cov_ld[0] > 1000 && cov_ld[1] > 1000 && cov_jr > 1000 && cov_br > 1000 && cov_fl > 100 && cov_xfl > 300 && cov_nwx > 1000 && cov_st > 1000 && cov_k[0] > 1000 && cov_k[1] > 1000;
    printf("tb_exu2: %ld results, %ld slow, %ld and %ld from outside, %ld and %ld loads, %ld jalr, %ld branches, %ld stores' data, %ld flushes, %ld beside what writes nothing; sources %ld by EX's mux, %ld from the register file; %ld mismatches: %s %s\n",
           nres, cov_rare, cov_x0, cov_x1, cov_ld[0], cov_ld[1], cov_jr, cov_br, cov_st, cov_fl, cov_nwx, cov_k[0], cov_k[1], bad, (bad || !cov) ? "FAIL" : "PASS", cov ? "" : "(coverage short)");
    return (bad || !cov) ? 1 : 0;
}
