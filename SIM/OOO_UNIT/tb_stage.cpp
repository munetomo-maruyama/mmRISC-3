//---------------------------------------------------------------------------
// tb_stage.cpp : OOO_STAGE (W = 16, 6 checkpoints) against the history of
// the µop it holds
//
// The test bench keeps checkpoint ids open in program order (as OOO_CTRL
// gives them out); a µop offered to the stage carries some of them as its
// mask. Every cycle, at random: the stage takes its input or holds (en, in
// bursts: an iterative divide), a kill of an open id (it and the ids opened
// after it close), a clear of another open id, now and then a flush. A
// closed id is opened again as soon as the next cycle, sooner than the core
// can (5 cycles), so that a bit left behind by a missing clear would be hit
// by the next kill of its id.
//
// Checked every cycle: the stage holds a µop exactly when the last one it
// took was valid and has not been killed (a kill of a bit of its mask, in
// the cycle it was taken or while held) or flushed since; its mask is the
// one it came with less every id cleared since (that cycle included); its
// data are what it came with.
//---------------------------------------------------------------------------
#include "VOOO_STAGE.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

static std::mt19937_64 rng(31);
static VOOO_STAGE d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const int NCK = 6;

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("STAGE_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.en = 0; d.flush = 0; d.kill = 0; d.clr = 0; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    std::vector<int> open;                     // ids open, in program order
    struct Ref { bool v = false; unsigned bm = 0; unsigned data = 0; } ref;
    long ntake = 0, nhold = 0, nkill = 0, nkilled = 0, nclr = 0, nflush = 0, nlive = 0;
    int hold_left = 0;

    for (cyc = 0; cyc < 400000; cyc++) {
        // ---- inputs
        int flush = rng() % 500 == 0;
        int en;
        if (hold_left > 0) { hold_left--; en = 0; }
        else if (rng() % 20 == 0) { hold_left = 1 + rng() % 30; en = 0; }
        else en = rng() % 4 != 0;
        int inv = rng() % 4 != 0;
        unsigned inbm = 0;                         // the ids opened before the µop: a prefix of the open ones
        for (size_t i = 0, n = rng() % (open.size() + 1); i < n; i++) inbm |= 1u << open[i];
        unsigned indata = (unsigned)rng() & 0xffff;
        unsigned killm = 0, clrm = 0;
        std::vector<int> closed_now;
        if (!flush && !open.empty() && rng() % 6 == 0) {
            size_t i = rng() % open.size();
            killm = 1u << open[i];
            closed_now.assign(open.begin() + i, open.end());
            open.resize(i);
        }
        if (!flush && !open.empty() && rng() % 4 == 0) {
            size_t i = rng() % open.size();
            clrm = 1u << open[i];
            closed_now.push_back(open[i]);
            open.erase(open.begin() + i);
        }
        d.flush = flush; d.en = en; d.kill = killm; d.clr = clrm;
        d.in_valid = inv; d.in_bm = inbm; d.in_data = indata;
        d.eval();

        // ---- the clock and the reference
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if (flush) { ref.v = false; nflush++; open.clear(); }
        else if (en) {
            ntake++;
            ref.v = inv && !(inbm & killm); ref.bm = inbm & ~clrm; ref.data = indata;
            if (inv && (inbm & killm)) nkilled++;
        } else {
            nhold++;
            if (ref.v && (ref.bm & killm)) { ref.v = false; nkilled++; }
            ref.bm &= ~clrm;
        }
        if (killm) nkill++;
        if (clrm) nclr++;
        // closed ids open again at once (another branch), and a few new ones
        for (int c : closed_now) if (rng() % 2 && (int)open.size() < NCK) open.push_back(c);
        if ((int)open.size() < NCK && rng() % 3 == 0) {
            int o; do { o = rng() % NCK; } while (std::find(open.begin(), open.end(), o) != open.end());
            open.push_back(o);
        }

        // ---- the stage after the edge
        if ((bool)d.out_valid != ref.v) FAIL("out_valid %d, expected %d", (int)d.out_valid, ref.v);
        else if (ref.v) {
            nlive++;
            if ((unsigned)d.out_bm != ref.bm) FAIL("out_bm %02x, expected %02x", (unsigned)d.out_bm, ref.bm);
            if ((unsigned)d.out_data != ref.data) FAIL("out_data %04x, expected %04x", (unsigned)d.out_data, ref.data);
        }
    }
    printf("tb_stage: %ld cycles, %ld taken, %ld held, %ld kills (%ld µops killed), %ld clears, %ld flushes, %ld cycles holding a µop, %ld mismatches: %s\n",
           cyc, ntake, nhold, nkill, nkilled, nclr, nflush, nlive, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
