//---------------------------------------------------------------------------
// tb_prf.cpp : OOO_PRF (96 x 64, 5 writes, 8 reads) against an array; with
// -DPRF_NREG=64 -DPRF_NW=3 -DPRF_NR=4 -DPRF_ZERO=0 the FP file of step 1.8 U1
// (run.sh's fprf: its register 0 a register like the others)
//
// Every cycle up to 5 writes to different registers (renaming never writes
// one register twice in a cycle) and 8 reads of any register, often of the
// ones just written. A read sees the value before the clock edge; register
// 0 reads as zero and ignores writes (PRF_ZERO, as the parameter ZERO).
//---------------------------------------------------------------------------
#include "VOOO_PRF.h"
#include <cstdint>
#include <cstdio>
#include <random>
#include <set>
#ifndef PRF_NREG
#define PRF_NREG 96
#define PRF_NW 5
#define PRF_NR 8
#define PRF_ZERO 1
#endif

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    VOOO_PRF d;
    std::mt19937_64 rng(3);
    const int NREG = PRF_NREG, NW = PRF_NW, NR = PRF_NR, AW = NREG > 64 ? 7 : 6;
    const bool ZERO = PRF_ZERO;
    long n0 = 0;
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
            wa[w] = (int)(rng() % NREG); wd[w] = rng();   // (a port not writing names anything)
            if (rng() % 3) continue;
            int a;
            do a = (int)(rng() % NREG); while (used.count(a));
            used.insert(a); wa[w] = a; we |= 1u << w;
        }
        // pack the ports (VlWide arrays of 32-bit words)
        d.we = we;
        uint64_t wap = 0;
        for (int w = 0; w < NW; w++) wap |= (uint64_t)wa[w] << (AW * w);
        d.wa = wap;
        for (int w = 0; w < NW; w++) { d.wd[2 * w] = (uint32_t)wd[w]; d.wd[2 * w + 1] = (uint32_t)(wd[w] >> 32); }
        int ra[NR];
        uint64_t rap = 0;
        for (int r = 0; r < NR; r++) {
            ra[r] = (rng() & 1) ? last_w[rng() % NW] : (int)(rng() % NREG);
            rap |= (uint64_t)ra[r] << (AW * r);
        }
        d.ra = rap;
        d.eval();
        for (int r = 0; r < NR; r++) {
            uint64_t got = (uint64_t)d.rd[2 * r] | ((uint64_t)d.rd[2 * r + 1] << 32);
            uint64_t exp = (ZERO && !ra[r]) ? 0 : ref[ra[r]];
            if (!ra[r] && exp) n0++;
            n++;
            if (got != exp && bad++ < 10)
                printf("MISMATCH cycle %ld read %d of p%d: %016llx expected %016llx\n", cyc, r, ra[r],
                       (unsigned long long)got, (unsigned long long)exp);
        }
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        for (int w = 0; w < NW; w++) if ((we >> w) & 1) { if (wa[w] || !ZERO) ref[wa[w]] = wd[w]; last_w[w] = wa[w]; }
    }
    bool cov = ZERO || n0 > 1000;           // (the FP file: register 0 read with a value in it)
    printf("tb_prf (%d x 64, %d writes, %d reads%s): %ld reads, %ld of register 0 holding a value, %ld mismatches: %s\n", NREG, NW, NR,
           ZERO ? ", register 0 zero" : "", n, n0, bad, bad == 0 && cov ? "PASS" : "FAIL");
    return bad != 0 || !cov;
}
