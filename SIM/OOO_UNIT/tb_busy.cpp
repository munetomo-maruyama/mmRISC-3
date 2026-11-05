//---------------------------------------------------------------------------
// tb_busy.cpp : OOO_BUSY against an array: tags set and woken at random, in any cycle, from
// 80 registers, with tags not valid on the buses; 8 sources read each cycle.
//---------------------------------------------------------------------------
#include "VOOO_BUSY.h"
#include <cstdint>
#include <cstdio>
#include <random>

static VOOO_BUSY d;
static std::mt19937 rng(9);

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    const int N = 80, NW = 9, TW = 7;
    bool busy[N] = {false};
    long bad = 0, nset = 0, nclr = 0, nrd = 0, nbusy = 0, nboth = 0;
    d.clk = 0; d.rst_n = 1; d.set_v = 0; d.wk_valid = 0; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    for (long c = 0; c < 300000; c++) {
        // sets: distinct new registers, never register 0
        unsigned sv = 0; uint32_t st = 0;
        bool setn[N] = {false};
        for (int k = 0; k < 4; k++) {
            int t = 1 + rng() % (N - 1);
            if (rng() % 3 == 0 && !setn[t]) { sv |= 1u << k; setn[t] = true; nset++; }
            st |= (uint32_t)t << (TW * k);
        }
        // wakeups: any, a bus may name what is not busy
        unsigned wv = 0; uint64_t wt = 0;
        bool clrn[N] = {false};
        for (int b = 0; b < NW; b++) {
            int t = rng() % 2 ? (int)(rng() % N) : 1 + (int)(rng() % 12);
            if (rng() % 2) { wv |= 1u << b; clrn[t] = true; nclr++; if (setn[t]) nboth++; }
            wt |= (uint64_t)t << (TW * b);
        }
        uint64_t rt = 0;
        int rd[8];
        for (int r = 0; r < 8; r++) { rd[r] = rng() % 2 ? (int)(rng() % N) : 1 + (int)(rng() % 12); rt |= (uint64_t)rd[r] << (TW * r); }
        d.set_v = sv; d.set_t = st; d.wk_valid = wv; d.wk_tag = wt; d.rd_t = rt;
        d.eval();
        for (int r = 0; r < 8; r++) {
            bool got = (d.rd_rdy >> r) & 1, exp = !busy[rd[r]];
            nrd++; nbusy += !exp;
            if (got != exp && bad++ < 10) printf("MISMATCH cycle %ld read %d of p%d: ready %d, expected %d\n", c, r, rd[r], got, exp);
        }
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        for (int t = 0; t < N; t++) busy[t] = setn[t] || (busy[t] && !clrn[t]);
    }
    bool cov = nset > 50000 && nclr > 50000 && nbusy > 100000 && nboth > 1000;
    printf("tb_busy: %ld sets, %ld wakeups, %ld reads (%ld busy), %ld set and woken at once, %ld mismatches: %s\n", nset, nclr, nrd, nbusy, nboth, bad, bad == 0 && cov ? "PASS" : "FAIL");
    return bad != 0 || !cov;
}
