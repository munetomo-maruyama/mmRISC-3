//---------------------------------------------------------------------------
// tb_prf.cpp : OOO_PRF (96 x 64, 5 writes, 8 reads) against an array
//
// Every cycle up to 5 writes to different registers (renaming never writes
// one register twice in a cycle) and 8 reads of any register, often of the
// ones just written. A read sees the value before the clock edge; register
// 0 reads as zero and ignores writes.
//---------------------------------------------------------------------------
#include "VOOO_PRF.h"
#include <cstdint>
#include <cstdio>
#include <random>
#include <set>

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    VOOO_PRF d;
    std::mt19937_64 rng(3);
    const int NREG = 96, NW = 5, NR = 8;
    uint64_t ref[NREG] = {0};
    // the banks are not reset: write every register once through port 0
    d.clk = 0;
    for (int r = 0; r < NREG; r++) {
        d.we = 1; d.wa = r; d.wd[0] = 0; d.wd[1] = 0;
        d.eval(); d.clk = 1; d.eval(); d.clk = 0; d.eval();
    }
    d.we = 0;
    long bad = 0, n = 0;
    int last_w[NW] = {0};
    for (long cyc = 0; cyc < 300000; cyc++) {
        std::set<int> used;
        unsigned we = 0;
        uint64_t wd[NW]; int wa[NW];
        for (int w = 0; w < NW; w++) {
            wa[w] = 0; wd[w] = rng();
            if (rng() % 3) continue;
            int a;
            do a = (int)(rng() % NREG); while (used.count(a));
            used.insert(a); wa[w] = a; we |= 1u << w;
        }
        // pack the ports (VlWide arrays of 32-bit words)
        d.we = we;
        uint64_t wap = 0;
        for (int w = 0; w < NW; w++) wap |= (uint64_t)wa[w] << (7 * w);
        d.wa = wap;
        for (int w = 0; w < NW; w++) { d.wd[2 * w] = (uint32_t)wd[w]; d.wd[2 * w + 1] = (uint32_t)(wd[w] >> 32); }
        int ra[NR];
        uint64_t rap = 0;
        for (int r = 0; r < NR; r++) {
            ra[r] = (rng() & 1) ? last_w[rng() % NW] : (int)(rng() % NREG);
            rap |= (uint64_t)ra[r] << (7 * r);
        }
        d.ra = rap;
        d.eval();
        for (int r = 0; r < NR; r++) {
            uint64_t got = (uint64_t)d.rd[2 * r] | ((uint64_t)d.rd[2 * r + 1] << 32);
            uint64_t exp = ra[r] ? ref[ra[r]] : 0;
            n++;
            if (got != exp && bad++ < 10)
                printf("MISMATCH cycle %ld read %d of p%d: %016llx expected %016llx\n", cyc, r, ra[r],
                       (unsigned long long)got, (unsigned long long)exp);
        }
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        for (int w = 0; w < NW; w++) if ((we >> w) & 1) { if (wa[w]) ref[wa[w]] = wd[w]; last_w[w] = wa[w]; }
    }
    printf("tb_prf: %ld reads, %ld mismatches: %s\n", n, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
