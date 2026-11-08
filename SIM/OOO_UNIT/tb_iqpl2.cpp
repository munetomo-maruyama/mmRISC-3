//---------------------------------------------------------------------------
// tb_iqpl2.cpp : OOO_IQPL2 (the payload of OOO_IQ2, N 24 in 4 banks of 6,
// W 96; run with NR 6, NRL 2: ports 4 and 5 read the low 48 bits only, the
// rest of their record is 0)
//
// Random writes of up to 4 records a cycle, as OOO_IQ2 gives them: each
// valid slot (not a prefix) to an entry of a bank no other slot of the
// cycle takes, and 6 grants a cycle, against an array. The writes lean
// towards the entries read in the cycle before, the case the LUT RAM has to
// get right: a record read in RR in the cycle its entry is written again
// (the old record). In the cycle after a grant, every port must give the
// record its entry held before that cycle's writes.
//---------------------------------------------------------------------------
#include "VOOO_IQPL2.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>

static const int N = 24, NB = 4, BS = N / NB, W = 96, WW = (W + 31) / 32, W2 = 48, NR = 6, NRL = 2;
static std::mt19937 rng(78);
static VOOO_IQPL2 d;

struct Rec { uint32_t w[WW]; };

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("IQPL_SEED")) rng.seed((unsigned)strtoul(e, nullptr, 0));
    d.clk = 0; d.eval();
    Rec mem[N]; bool written[N] = {};
    int ra[NR] = {}; bool rav = false;          // the grants of the cycle before
    long bad = 0, checks = 0, same = 0, gaps = 0, nogo = 0;
    for (long cyc = 0; cyc < 400000; cyc++) {
        // writes: the valid slots to different banks, often an entry being read
        int we[NB]; Rec wd[NB];
        int bank[NB] = {0, 1, 2, 3};
        std::shuffle(bank, bank + NB, rng);
        bool hole = false, after = false;
        for (int s = 0; s < NB; s++) {
            we[s] = -1;
            if (rng() % 3 == 0) { hole = true; continue; }
            after = after || hole;
            int e = bank[s] * BS + (int)(rng() % BS);
            if (rav && rng() % 3 == 0) {            // an entry read now, when its bank is this slot's
                int p = rng() % NR;
                if (ra[p] / BS == bank[s]) e = ra[p];
            }
            we[s] = e;
            for (int k = 0; k < WW; k++) wd[s].w[k] = rng();
        }
        if (after) gaps++;
        int gi[NR]; for (int p = 0; p < NR; p++) gi[p] = rng() % N;
        d.wr_valid = 0; d.wr_entry = 0;
        for (int s = 0; s < NB; s++) {
            if (we[s] >= 0) d.wr_valid |= 1u << s;
            d.wr_entry |= (uint32_t)(we[s] >= 0 ? we[s] : rng() % N) << (5 * s);
            for (int k = 0; k < WW; k++) d.wr_data[s * WW + k] = we[s] >= 0 ? wd[s].w[k] : rng();
        }
        d.wr_cand = d.wr_valid;                      // the slots that go if any do; now and then none goes
        if (rng() % 8 == 0) { d.wr_valid = 0; for (int s = 0; s < NB; s++) we[s] = -1; nogo++; }
        d.iss_entry = 0;
        for (int p = 0; p < NR; p++) d.iss_entry |= (uint64_t)gi[p] << (5 * p);
        d.eval();
        // RR: the records of last cycle's grants, before this cycle's writes
        if (rav)
            for (int p = 0; p < NR; p++) {
                if (!written[ra[p]]) continue;
                checks++;
                for (int s = 0; s < NB; s++) if (ra[p] == we[s]) { same++; break; }
                for (int k = 0; k < WW; k++) {
                    uint32_t got = d.rr_data[p * WW + k], want = mem[ra[p]].w[k];
                    if (p >= NR - NRL) {                // the low W2 bits only
                        int lo = 32 * k, keep = W2 - lo;
                        want = keep >= 32 ? want : keep <= 0 ? 0 : want & ((1u << keep) - 1);
                    }
                    if (got != want) {
                        if (bad++ < 10) printf("cycle %ld: port %d entry %d word %d: %08x, expected %08x\n", cyc, p, ra[p], k, got, want);
                        break;
                    }
                }
            }
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        for (int s = 0; s < NB; s++) if (we[s] >= 0) { mem[we[s]] = wd[s]; written[we[s]] = true; }
        for (int p = 0; p < NR; p++) ra[p] = gi[p];
        rav = true;
    }
    printf("tb_iqpl2: %ld reads checked (%ld in the cycle their entry was written again), %ld cycles with a gap in the slots, %ld with slots and none going, %ld mismatches: %s\n",
           checks, same, gaps, nogo, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
