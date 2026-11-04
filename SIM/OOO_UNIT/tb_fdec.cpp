//---------------------------------------------------------------------------
// tb_fdec.cpp : OOO_FDEC (F3, F4) against a walk of each block written separately
//
// Random blocks of parcels, biased to transfers: branches and jumps, 16 and 32 bits,
// calls and returns, ALU parcels between. Every block has a random start, or follows
// the one before at parcel 0, so that 32-bit instructions cross. Random predictions:
// slots with a hit, base counters, the BTB; fetch went on to the right place half the
// time. Now and then a flush. What must hold, a cycle after F3: where instructions
// start, the first transfer predicted taken, whether fetch was wrong and where it
// should go, the slot predictions taken, a first half at parcel 15; the stack (a stack
// here, where it has been written); the training a cycle after.
//---------------------------------------------------------------------------
#include "VOOO_FDEC.h"
#include "VOOO_FDEC___024root.h"
#include <cstdint>
#include <cstdio>
#include <random>

static VOOO_FDEC d;
static std::mt19937_64 rng(31);
static long bad = 0;
#define FAIL(...) do { if (bad++ < 12) { printf(__VA_ARGS__); printf("\n"); } } while (0)
static const uint64_t VM = (1ull << 38) - 1;

struct Blk {
    bool v = false;
    uint16_t p[16]; uint64_t line; int start; bool cu; uint16_t cp;
    uint64_t expect; int hv, pp; unsigned base; bool bh; int boff; uint64_t btgt;
};

// the immediate forms, by hand
static uint32_t rd_f(uint32_t i) { return (i >> 7) & 31; }
static bool lnk(uint32_t r) { return r == 1 || r == 5; }

struct Dec { bool br = false, jal = false, jalr = false, call = false, ret = false; int64_t off = 0; };
static Dec dec32(uint32_t i) {
    Dec x;
    uint32_t op = i & 127;
    if (op == 0x63) {
        x.br = true;
        int64_t o = ((i >> 8) & 15) | (((i >> 25) & 63) << 4) | (((i >> 7) & 1) << 10) | (((i >> 31) & 1) << 11);
        if (i >> 31) o |= ~0ll << 12;
        x.off = o;
    } else if (op == 0x6f) {
        x.jal = true; x.call = lnk(rd_f(i));
        int64_t o = ((i >> 21) & 1023) | (((i >> 20) & 1) << 10) | (((i >> 12) & 255) << 11) | (((i >> 31) & 1) << 19);
        if (i >> 31) o |= ~0ll << 20;
        x.off = o;
    } else if (op == 0x67 && ((i >> 12) & 7) == 0) {
        x.jalr = true; x.call = lnk(rd_f(i)); x.ret = lnk((i >> 15) & 31) && !lnk(rd_f(i));
    }
    return x;
}
static Dec dec16(uint32_t c) {
    Dec x;
    int q = c & 3, f3 = (c >> 13) & 7;
    if (q == 1 && f3 == 5) {
        x.jal = true;
        int64_t o = ((c >> 3) & 7) | (((c >> 11) & 1) << 3) | (((c >> 2) & 1) << 4) | (((c >> 7) & 1) << 5) | (((c >> 6) & 1) << 6) |
                    (((c >> 9) & 3) << 7) | (((c >> 8) & 1) << 9) | (((c >> 12) & 1) << 10);
        if ((c >> 12) & 1) o |= ~0ll << 10;
        x.off = o;
    } else if (q == 1 && (f3 == 6 || f3 == 7)) {
        x.br = true;
        int64_t o = ((c >> 3) & 3) | (((c >> 10) & 3) << 2) | (((c >> 2) & 1) << 4) | (((c >> 5) & 3) << 5) | (((c >> 12) & 1) << 7);
        if ((c >> 12) & 1) o |= ~0ll << 7;
        x.off = o;
    } else if (q == 2 && f3 == 4 && ((c >> 2) & 31) == 0 && ((c >> 7) & 31) != 0) {
        x.jalr = true; x.call = (c >> 12) & 1; x.ret = !x.call && lnk((c >> 7) & 31);
    }
    return x;
}

static uint16_t rnd_parcel() {
    switch (rng() % 12) {
    case 0: return (uint16_t)(0xC001 | ((rng() & 0x1fff) & 0x1ffc));         // c.beqz, c.bnez
    case 1: return (uint16_t)(0xA001 | (rng() & 0x1ffc));                     // c.j
    case 2: return (uint16_t)(0x8002 | ((rng() % 2 ? 1 : 5) << 7));           // c.jr x1
    case 3: return (uint16_t)(0x9002 | ((rng() % 31 + 1) << 7));              // c.jalr
    case 4: return (uint16_t)(0x0063 | (rng() & 0xff80));                     // a branch's low half
    case 5: return (uint16_t)(0x006f | (rng() & 0xff80));                     // jal
    case 6: return (uint16_t)(0x0067 | (rng() & 0x8f80));                     // jalr
    default: { uint16_t x = (uint16_t)rng(); if ((x & 3) == 3) x &= ~1u; return x; }
    }
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    d.clk = 0; d.rst_n = 1; d.flush = 0; d.f3_valid = 0; d.rs_valid = 0; d.rs_push = 0; d.rs_pop = 0;
    d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    Blk f4;                      // what is in F4
    bool cv = false; uint16_t cp = 0;
    uint64_t prev_line = 0x1000;
    bool st_w[16] = {false};     // the stack, here
    uint64_t st_v[16] = {0};
    int sp = -1;                 // not known until the first move: taken from the block
    bool ub_v = false, ub_t = false, ub_c = false, ub_r = false; uint64_t ub_p = 0, ub_g = 0;
    long nb = 0, nov = 0, ntk = 0, ncr = 0, ncu = 0, nret = 0, ncall = 0, nsl = 0, nfl = 0, nbtb = 0;

    for (long cyc = 0; cyc < 600000; cyc++) {
        // ---- F3
        Blk n;
        n.v = rng() % 8 != 0;
        bool seq = rng() % 2;
        n.line = seq ? prev_line + 1 : (0x1000 + rng() % 4096);
        n.start = seq ? 0 : (rng() % 3 == 0 ? 15 : rng() % 16);
        unsigned long long dw[4] = {0, 0, 0, 0};
        for (int k = 0; k < 16; k++) { n.p[k] = rnd_parcel(); dw[k / 4] |= (unsigned long long)n.p[k] << (16 * (k % 4)); }
        n.cu = cv && seq; n.cp = cp;
        n.hv = rng() % 8; n.pp = rng() % 8; n.base = (unsigned)rng() & 0xffff;
        n.bh = rng() % 2; n.boff = rng() % 16; n.btgt = rng() & VM;
        n.expect = rng() & VM;       // set right below, half the time
        bool fl = rng() % 256 == 0;
        d.f3_valid = n.v; d.f3_line = n.line; d.f3_start = n.start; d.f3_seq = seq;
        for (int i = 0; i < 8; i++) d.f3_data[i] = (uint32_t)(dw[i / 2] >> (32 * (i & 1)));
        d.f3_hv = n.hv; d.f3_pp = n.pp; d.f3_base = n.base; d.f3_bh = n.bh; d.f3_boff = n.boff; d.f3_btgt = n.btgt;
        d.flush = fl;

        // ---- the walk of the block in F3: its right next address, if its predictions stand
        unsigned st3 = 0; bool cross3 = false;
        uint64_t next3 = (n.line + 1) << 4;
        {
            int k = n.start;
            bool stop = false;
            int nbr = 0;
            auto seen = [&](int e, const Dec& x, int hi) {
                if (stop) return;
                uint64_t tg = ((n.line << 4) + e + (uint64_t)x.off - hi) & VM;
                bool t = false;
                if (x.br) {
                    if (nbr < 3) { t = (n.hv >> nbr & 1) ? (n.pp >> nbr & 1) : (n.base >> e & 1); nbr++; }
                } else if (x.jal) t = true;
                else if (x.jalr) t = x.ret || (n.bh && n.boff == e);
                if (t) {
                    stop = true;
                    if (x.br || x.jal) next3 = tg;
                    else if (!x.ret) next3 = n.btgt;
                    else next3 = ~0ull;      // the stack's top then: leave expect random
                }
            };
            if (n.cu) { seen(0, dec32((uint32_t)n.cp | ((uint32_t)n.p[0] << 16)), 1); k = 1; if (n.start > 1) k = 1; }
            // (with a carry the start is 0)
            while (k < 16) {
                if ((n.p[k] & 3) == 3) {
                    st3 |= 1u << k;
                    if (k == 15) { cross3 = true; break; }
                    seen(k + 1, dec32((uint32_t)n.p[k] | ((uint32_t)n.p[k + 1] << 16)), 1);
                    k += 2;
                } else {
                    st3 |= 1u << k;
                    seen(k, dec16(n.p[k]), 0);
                    k += 1;
                }
            }
        }
        // fetch went on: right, or near it, or where another choice would have gone
        switch (rng() % 8) {
        case 0: case 1: case 2: case 3: if (next3 != ~0ull) n.expect = next3; break;
        case 4: n.expect = ((n.line + 1) << 4) & VM; break;
        case 5: n.expect = n.btgt; break;
        case 6: if (next3 != ~0ull) n.expect = next3 ^ 1; break;
        default: n.expect = (uint64_t)d.rootp->OOO_FDEC__DOT__top & VM; break;
        }
        d.f3_expect = n.expect;
        d.eval();

        // ---- F4: the block a cycle on
        bool ovr_exp = false; unsigned first_exp = 0;
        bool cross4 = false;
        if (f4.v) {
            nb++;
            uint64_t top = d.rootp->OOO_FDEC__DOT__top;
            if (sp >= 0 && st_w[sp & 15] && top != st_v[sp & 15]) FAIL("cycle %ld: top %llx, expected %llx", cyc, (unsigned long long)top, (unsigned long long)st_v[sp & 15]);
            // the walk again, with the slots counted
            unsigned sta = 0;
            int k = f4.start;
            int nbr = 0; bool stop = false; int ht = 0, hn = 0; uint64_t nxt = (f4.line + 1) << 4;
            int ee = -1; bool ic = false, ir = false, ib = false;
            auto seen = [&](int e, const Dec& x, int hi) {
                if (stop) return;
                uint64_t tg = ((f4.line << 4) + e + (uint64_t)x.off - hi) & VM;
                bool t = false;
                if (x.br) {
                    if (nbr < 3) {
                        t = (f4.hv >> nbr & 1) ? (f4.pp >> nbr & 1) : (f4.base >> e & 1);
                        if (t) ht |= 1 << hn;
                        hn++; nbr++; nsl++;
                    }
                } else if (x.jal) t = true;
                else if (x.jalr) { t = x.ret || (f4.bh && f4.boff == e); if (t && !x.ret) nbtb++; }
                if (t) {
                    stop = true; ee = e; ic = x.call; ir = x.ret; ib = x.br;
                    nxt = (x.br || x.jal) ? tg : x.ret ? top : f4.btgt;
                }
            };
            if (f4.cu) { seen(0, dec32((uint32_t)f4.cp | ((uint32_t)f4.p[0] << 16)), 1); k = 1; ncu++; }
            while (k < 16) {
                sta |= 1u << k;
                if ((f4.p[k] & 3) == 3) {
                    if (k == 15) { cross4 = true; break; }
                    seen(k + 1, dec32((uint32_t)f4.p[k] | ((uint32_t)f4.p[k + 1] << 16)), 1);
                    k += 2;
                } else { seen(k, dec16(f4.p[k]), 0); k += 1; }
            }
            if (ee >= 0) first_exp = 1u << ee;
            ovr_exp = nxt != f4.expect && !fl;
            if (!d.f4_valid) FAIL("cycle %ld: no block in F4", cyc);
            if (d.f4_first != first_exp) FAIL("cycle %ld: first %04x, expected %04x", cyc, d.f4_first, first_exp);
            if ((d.f4_st & sta) != sta || d.f4_st != sta) FAIL("cycle %ld: starts %04x, expected %04x", cyc, d.f4_st, sta);
            if ((bool)d.f4_cross != cross4) FAIL("cycle %ld: cross", cyc);
            if ((bool)d.ovr != ovr_exp) FAIL("cycle %ld: ovr %d, expected %d (next %llx, expect %llx)", cyc, (int)d.ovr, ovr_exp, (unsigned long long)nxt, (unsigned long long)f4.expect);
            if (((uint64_t)d.ovr_pc & VM) != (nxt & VM)) FAIL("cycle %ld: next %llx, expected %llx", cyc, (unsigned long long)d.ovr_pc, (unsigned long long)nxt);
            if ((int)d.f4_hn != hn || ((int)d.f4_ht & ((1 << hn) - 1)) != ht) FAIL("cycle %ld: history %d %x, expected %d %x", cyc, (int)d.f4_hn, (int)d.f4_ht, hn, ht);
            if (ovr_exp) nov++;
            if (ee >= 0) ntk++;
            if (cross4) ncr++;
            // the stack moves
            if (!fl && ee >= 0) {
                if (ic) {
                    uint64_t a = ee == 15 ? (f4.line + 1) << 4 : (f4.line << 4) + ee + 1;
                    if (sp < 0) sp = (int)d.rootp->OOO_FDEC__DOT__u_ras__DOT__ptr;
                    sp = (sp + 1) & 15; st_w[sp] = true; st_v[sp] = a; ncall++;
                } else if (ir) {
                    if (sp < 0) sp = (int)d.rootp->OOO_FDEC__DOT__u_ras__DOT__ptr;
                    sp = (sp - 1) & 15; nret++;
                }
            }
            ub_v = ovr_exp && ee >= 0; ub_p = (f4.line << 4) | (ee >= 0 ? ee : 15); ub_t = ee >= 0; ub_g = nxt; ub_c = ib; ub_r = ir;
        } else {
            if (d.f4_valid) FAIL("cycle %ld: a block in F4 not expected", cyc);
            if (d.ovr) FAIL("cycle %ld: ovr with no block", cyc);
            ub_v = false;
        }

        // ---- the edge
        bool drop = fl || ovr_exp;
        bool ov_now = ovr_exp;
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if ((bool)d.ub_valid != ub_v) FAIL("cycle %ld: training %d, expected %d", cyc, (int)d.ub_valid, ub_v);
        if (ub_v) {
            if ((uint64_t)d.ub_pc != (ub_p & VM)) FAIL("cycle %ld: training at %llx, expected %llx", cyc, (unsigned long long)d.ub_pc, (unsigned long long)ub_p);
            if ((uint64_t)d.ub_tgt != (ub_g & VM)) FAIL("cycle %ld: training target", cyc);
            if ((bool)d.ub_taken != ub_t || (bool)d.ub_cond != ub_c || (bool)d.ub_ret != ub_r) FAIL("cycle %ld: training kind", cyc);
        }
        (void)ov_now;
        if (fl) nfl++;
        f4 = n; f4.v = n.v && !drop;
        if (drop) cv = false;
        else if (n.v) cv = cross3;
        if (n.v) cp = n.p[15];
        if (n.v) prev_line = n.line;
    }
    bool cov = nb > 200000 && nov > 50000 && ntk > 50000 && ncr > 5000 && ncu > 1000 && nret > 5000 && ncall > 5000 && nsl > 100000 && nfl > 500 && nbtb > 1000;
    printf("tb_fdec: %ld blocks, %ld taken, %ld overrides, %ld first halves, %ld finished, %ld calls, %ld returns, %ld through the BTB, %ld slot predictions, %ld flushes: %ld mismatches: %s\n",
           nb, ntk, nov, ncr, ncu, ncall, nret, nbtb, nsl, nfl, bad, bad == 0 && cov ? "PASS" : "FAIL");
    return bad != 0 || !cov;
}
