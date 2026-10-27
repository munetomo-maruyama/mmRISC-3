//---------------------------------------------------------------------------
// tb_dsreg.cpp : OOO_DSREG (the DS register's payload, W = 16) against the
// cycles in which every register's producer woke its dependents
//
// The test bench plays renaming and the issue queue's wakeup tags: every
// cycle the register is loaded (renaming's two µops, OOO_CTRL ds_load) or
// holds (dispatch waits, now and then for many cycles); the µops read
// registers whose producers have woken already, will wake later, or are the
// destination slot 0 renames in the same cycle (in-group, not ready). Each
// register given out wakes once, a few cycles later or much later, on one
// of the 6 buses. Renaming's ready bit is its busy bit, which a wakeup
// clears at the edge of its cycle (OOO_RENAME): ready when the wakeup came
// before the cycle of renaming.
//
// Checked every cycle, for every source of the µops held (loaded in an
// earlier cycle): ds_rdy is set exactly when the source's wakeup came in a
// cycle before this one. That is what the issue queue needs at dispatch,
// where it takes the wakeups of the cycle itself (OOO_IQ disp_rdy ||
// woken): a wakeup missed between renaming and dispatch would show as a 0
// that should be 1 (a µop waiting for ever), one taken too early or of the
// wrong register as a 1 that should be 0. And that the payload (sources,
// use bits, data) holds what was loaded.
//---------------------------------------------------------------------------
#include "VOOO_DSREG.h"
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

static std::mt19937_64 rng(77);
static VOOO_DSREG d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const int NT = 64, NB = 6;
static const long NEVER = LONG_MAX;

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("DSREG_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.load = 0; d.wk_valid = 0; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    long wake[NT];                 // the cycle of the latest wakeup of the register (LONG_MIN: long ago)
    bool given[NT];                // given out to a µop in flight
    long due[NT];                  // a register given out wakes from this cycle on
    for (int t = 0; t < NT; t++) { wake[t] = LONG_MIN; given[t] = false; due[t] = NEVER; }
    given[0] = true;               // x0: never given out, always ready

    struct Held { bool v = false; int src[2][2]; int use[2][2]; bool rdy0[2][2]; uint32_t data[2]; } held;
    long nload = 0, nheld = 0, nsnoop = 0, nchecked = 0, ningroup = 0;
    int hold_left = 0;

    for (cyc = 0; cyc < 300000; cyc++) {
        // ---- the wakeups of this cycle: registers due, at most 6
        int wv = 0; uint64_t wt = 0; std::vector<int> woke;
        {
            std::vector<int> cand;
            for (int t = 1; t < NT; t++) if (given[t] && due[t] <= cyc && wake[t] == NEVER) cand.push_back(t);
            for (int b = 0; b < NB && !cand.empty(); b++) {
                if (rng() % 3 == 0) continue;
                size_t i = rng() % cand.size();
                int t = cand[i]; cand.erase(cand.begin() + i);
                wv |= 1 << b; wt |= (uint64_t)t << (6 * b); woke.push_back(t);
            }
        }
        // ---- load or hold
        int load;
        if (hold_left > 0) { hold_left--; load = 0; }
        else if (rng() % 50 == 0) { hold_left = 2 + rng() % 20; load = 0; }
        else load = rng() % 3 != 0;
        Held nw; int ndst[2] = {0, 0}; uint32_t isrc = 0, iuse = 0, irdy = 0, idat = 0;
        if (load) {
            nw.v = true;
            // slot 0's destination, for the in-group case of slot 1
            std::vector<int> fr;
            for (int t = 1; t < NT; t++) if (!given[t]) fr.push_back(t);
            for (int k = 0; k < 2; k++) {
                ndst[k] = 0;
                if (!fr.empty() && rng() % 4) { size_t i = rng() % fr.size(); ndst[k] = fr[i]; fr.erase(fr.begin() + i); }
            }
            std::vector<int> inflight;
            for (int t = 1; t < NT; t++) if (given[t]) inflight.push_back(t);
            for (int k = 0; k < 2; k++) {
                for (int s = 0; s < 2; s++) {
                    int t;
                    int r = rng() % 10;
                    if (k == 1 && ndst[0] && r < 2) { t = ndst[0]; ningroup++; }          // in-group: slot 0's new register
                    else if (r < 8 && !inflight.empty()) t = inflight[rng() % inflight.size()];
                    else t = rng() % NT;                                                   // free (long since woken) or x0
                    // never a register given out now but in-group (a dependence on a younger µop)
                    if (t == ndst[1] || (k == 0 && t == ndst[0])) t = 0;
                    nw.src[k][s] = t; nw.use[k][s] = rng() % 4 != 0;
                    // renaming's ready bit: the busy bit, cleared at the edge of the wakeup's cycle
                    bool rdy = (k == 1 && t == ndst[0] && t) ? false : wake[t] < cyc;
                    nw.rdy0[k][s] = rdy;
                    isrc |= (uint32_t)t << (6 * (2 * k + s));
                    iuse |= (uint32_t)nw.use[k][s] << (2 * k + s);
                    irdy |= (uint32_t)rdy << (2 * k + s);
                }
                nw.data[k] = (uint32_t)rng() & 0xffff;
                idat |= nw.data[k] << (16 * k);
            }
        }
        d.load = load; d.in_src = isrc; d.in_use = iuse; d.in_rdy = irdy; d.in_data = idat;
        d.wk_valid = wv; d.wk_tag = wt;
        d.eval();

        // ---- the held µops: ready bits and payload
        if (held.v) {
            nheld++;
            for (int k = 0; k < 2; k++) {
                for (int s = 0; s < 2; s++) {
                    int t = held.src[k][s];
                    bool e = wake[t] < cyc;
                    bool g = (d.ds_rdy >> (2 * k + s)) & 1;
                    nchecked++;
                    if (e && !held.rdy0[k][s]) nsnoop++;
                    if (g != e) FAIL("slot %d source %d (p%d): ready %d, expected %d (woken in cycle %ld)", k, s, t, g, e,
                                     wake[t] == LONG_MIN ? -1L : wake[t]);
                    int gs = (int)((d.ds_src >> (6 * (2 * k + s))) & 63), gu = (int)((d.ds_use >> (2 * k + s)) & 1);
                    if (gs != t || gu != held.use[k][s]) FAIL("slot %d source %d: p%d use %d, expected p%d use %d", k, s, gs, gu, t, held.use[k][s]);
                }
                uint32_t gd = (uint32_t)(d.ds_data >> (16 * k)) & 0xffff;
                if (gd != held.data[k]) FAIL("slot %d data %04x, expected %04x", k, gd, held.data[k]);
            }
        }

        // ---- the clock
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        for (int t : woke) wake[t] = cyc;
        if (load) {
            nload++;
            held = nw;
            for (int k = 0; k < 2; k++) if (ndst[k]) {
                given[ndst[k]] = true; wake[ndst[k]] = NEVER;
                due[ndst[k]] = cyc + 2 + (rng() % 8 == 0 ? (long)(rng() % 40) : (long)(rng() % 4));
            }
        }
        // registers that have woken are freed now and then (not one the held µops read)
        for (int t = 1; t < NT; t++) {
            if (!given[t] || wake[t] == NEVER || rng() % 6) continue;
            bool rd = false;
            if (held.v) for (int k = 0; k < 2; k++) for (int s = 0; s < 2; s++) rd |= held.src[k][s] == t;
            if (!rd) { given[t] = false; due[t] = NEVER; }
        }
    }
    printf("tb_dsreg: %ld cycles, %ld loads, %ld cycles held, %ld sources checked (%ld ready by a wakeup since renaming), %ld in-group sources, %ld mismatches: %s\n",
           cyc, nload, nheld, nchecked, nsnoop, ningroup, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
