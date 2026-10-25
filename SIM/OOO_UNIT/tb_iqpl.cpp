//---------------------------------------------------------------------------
// tb_iqpl.cpp : OOO_IQPL (the payload of the issue queue, N 16, W 96)
//
// Random writes of up to 2 records a cycle to two different entries, and 3
// grants a cycle, against an array. The writes lean towards the entries
// read in the cycle before and in this one, the cases the LUTRAM has to
// get right: a record read in RR in the cycle its entry is written again
// (the old record), an entry written by one slot and then by the other
// (the live value table), both slots in one cycle. In the cycle after a
// grant, every port must give the record its entry held before that
// cycle's writes.
//---------------------------------------------------------------------------
#include "VOOO_IQPL.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>

static const int N = 16, W = 96, WW = (W + 31) / 32;
static std::mt19937 rng(77);
static VOOO_IQPL d;

struct Rec { uint32_t w[WW]; };

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("IQPL_SEED")) rng.seed((unsigned)strtoul(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    Rec mem[N]; bool written[N] = {};
    int ra[3] = {0, 0, 0}; bool rav = false;    // the grants of the cycle before
    long bad = 0, checks = 0, same = 0, swaps = 0;
    int last_slot[N]; for (int i = 0; i < N; i++) last_slot[i] = -1;
    for (long cyc = 0; cyc < 400000; cyc++) {
        // writes: two different entries, often ones being read
        int we[2] = {-1, -1}; Rec wd[2];
        for (int s = 0; s < 2; s++) {
            if (rng() % 3 == 0) continue;
            int e;
            do {
                int r = rng() % 4;
                e = (r == 0 && rav) ? ra[rng() % 3] : (int)(rng() % N);
            } while (s == 1 && e == we[0]);
            we[s] = e;
            for (int k = 0; k < WW; k++) wd[s].w[k] = rng();
        }
        int gi[3]; for (int p = 0; p < 3; p++) gi[p] = rng() % N;
        d.wr_valid = (we[0] >= 0 ? 1 : 0) | (we[1] >= 0 ? 2 : 0);
        d.wr_entry = (we[0] >= 0 ? we[0] : rng() % N) | ((we[1] >= 0 ? we[1] : rng() % N) << 4);
        for (int k = 0; k < WW; k++) { d.wr_data[k] = 0; d.wr_data[WW + k] = 0; }
        // wr_data is [1:0][95:0]: slot 0 in words 0..2, slot 1 in words 3..5
        for (int s = 0; s < 2; s++) for (int k = 0; k < WW; k++) d.wr_data[s * WW + k] = we[s] >= 0 ? wd[s].w[k] : rng();
        d.iss_entry = gi[0] | (gi[1] << 4) | (gi[2] << 8);
        d.eval();
        // RR: the records of last cycle's grants, before this cycle's writes
        if (rav)
            for (int p = 0; p < 3; p++) {
                if (!written[ra[p]]) continue;
                checks++;
                if (ra[p] == we[0] || ra[p] == we[1]) same++;
                for (int k = 0; k < WW; k++) {
                    uint32_t got = d.rr_data[p * WW + k];
                    if (got != mem[ra[p]].w[k]) {
                        if (bad++ < 10) printf("cycle %ld: port %d entry %d word %d: %08x, expected %08x\n", cyc, p, ra[p], k, got, mem[ra[p]].w[k]);
                        break;
                    }
                }
            }
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        for (int s = 0; s < 2; s++) if (we[s] >= 0) {
            mem[we[s]] = wd[s]; written[we[s]] = true;
            if (last_slot[we[s]] >= 0 && last_slot[we[s]] != s) swaps++;
            last_slot[we[s]] = s;
        }
        for (int p = 0; p < 3; p++) ra[p] = gi[p];
        rav = true;
    }
    printf("tb_iqpl: %ld reads checked (%ld in the cycle their entry was written again), %ld changes of the writing slot, %ld mismatches: %s\n",
           checks, same, swaps, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
