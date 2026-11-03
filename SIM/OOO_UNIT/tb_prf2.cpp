//---------------------------------------------------------------------------
// tb_prf2.cpp : OOO_PRF2 (80 x 64, 4 writes, 8 reads, read in 2 stages) against
// an array
//
// Every cycle up to 4 writes to different registers, never register 0, their
// address and enable given the cycle before the data, and 8 reads, often of the ones written now or just before. What a read gives one
// cycle after its address: the array with every write up to the end of the cycle
// of the address, not the writes of the cycle it comes out in.
//---------------------------------------------------------------------------
#include "VOOO_PRF2.h"
#include <cstdint>
#include <cstdio>
#include <random>
#include <set>

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    VOOO_PRF2 d;
    std::mt19937_64 rng(3);
    const int NREG = 80, NW = 4, NR = 8;
    uint64_t ref[NREG] = {0};
    long fwd = 0;
    d.clk = 0;
    for (int r = 1; r < NREG; r++) {
        d.we_n = 1; d.wa_n = r; d.wd[0] = 0; d.wd[1] = 0;
        d.eval(); d.clk = 1; d.eval(); d.clk = 0; d.eval();
    }
    d.we_n = 0;
    for (int i = 0; i < 2; i++) { d.eval(); d.clk = 1; d.eval(); d.clk = 0; d.eval(); }
    long bad = 0, n = 0;
    int last_w[NW] = {1, 1, 1, 1};
    int ra[NR] = {0};
    uint64_t want[NR] = {0};
    bool have = false;
    unsigned we = 0;                  // this cycle's writes, chosen in the one before
    int wa[NW] = {0, 0, 0, 0};
    for (long cyc = 0; cyc < 300000; cyc++) {
        std::set<int> used;
        unsigned nwe = 0;
        uint64_t wd[NW]; int nwa[NW];
        for (int w = 0; w < NW; w++) {
            wd[w] = rng();
            nwa[w] = (int)(rng() % NREG);                 // (the address means nothing without we)
            if (rng() % 3 == 0) continue;
            int a;
            do a = 1 + (int)(rng() % (NREG - 1)); while (used.count(a));
            used.insert(a); nwa[w] = a; nwe |= 1u << w;
        }
        d.we_n = nwe;
        d.wa_n = (uint32_t)nwa[0] | (uint32_t)nwa[1] << 7 | (uint32_t)nwa[2] << 14 | (uint32_t)nwa[3] << 21;
        for (int w = 0; w < NW; w++) { d.wd[2 * w] = (uint32_t)wd[w]; d.wd[2 * w + 1] = (uint32_t)(wd[w] >> 32); }
        uint64_t rap = 0;
        int nra[NR];
        for (int r = 0; r < NR; r++) {
            int k = rng() % 4;
            if (k == 0) nra[r] = 1 + (int)(rng() % (NREG - 1));
            else if (k == 1) nra[r] = last_w[rng() % NW];
            else { int w = rng() % NW; nra[r] = (we >> w & 1) ? wa[w] : last_w[w]; }
            rap |= (uint64_t)nra[r] << (7 * r);
        }
        d.ra1 = rap;
        d.eval();
        if (have) for (int r = 0; r < NR; r++) {
            uint64_t got = (uint64_t)d.rd[2 * r] | ((uint64_t)d.rd[2 * r + 1] << 32);
            n++;
            if (got != want[r] && bad++ < 10)
                printf("MISMATCH cycle %ld read %d of p%d: %016llx expected %016llx\n", cyc, r, ra[r],
                       (unsigned long long)got, (unsigned long long)want[r]);
        }
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        for (int w = 0; w < NW; w++) if ((we >> w) & 1) { ref[wa[w]] = wd[w]; last_w[w] = wa[w]; }
        for (int r = 0; r < NR; r++) {
            for (int w = 0; w < NW; w++) if (((we >> w) & 1) && wa[w] == nra[r]) fwd++;
            ra[r] = nra[r]; want[r] = ref[nra[r]];
        }
        have = true;
        we = nwe;
        for (int w = 0; w < NW; w++) wa[w] = nwa[w];
    }
    if (fwd < 100000) { printf("coverage: %ld reads of a register written in that cycle\n", fwd); bad++; }
    printf("tb_prf2: %ld reads, %ld of them of a register being written, %ld mismatches: %s\n", n, fwd, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
