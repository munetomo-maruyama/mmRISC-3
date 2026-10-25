//---------------------------------------------------------------------------
// tb_ftq.cpp : OOO_FTQ (8 entries) against a reference queue
//
// Every cycle: now and then a push of a random entry (pc, target, taken,
// end, meta); pops of up to 2 of the oldest entries (commit); now and then a
// restore to a random entry in the queue (a misprediction: that block stays,
// the younger ones go) or a flush_all. The three read ports are given random
// entries in the queue and their outputs compared, as are push_ready and
// push_idx.
//---------------------------------------------------------------------------
#include "VOOO_FTQ.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>

static std::mt19937_64 rng(41);
static VOOO_FTQ d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const int N = 8;
static const uint64_t PCM = (1ull << 38) - 1;   // pc[38:1]

struct Ent { uint64_t pc, target; int taken, end; uint32_t meta; };

template <class W> static void setw(W& w, int lo, int n, uint64_t v) {
    for (int b = 0; b < n; b++) { int i = lo + b; uint32_t m = 1u << (i % 32); if ((v >> b) & 1) w[i / 32] |= m; else w[i / 32] &= ~m; }
}
template <class W> static uint64_t getw(const W& w, int lo, int n) {
    uint64_t v = 0; for (int b = 0; b < n; b++) { int i = lo + b; v |= (uint64_t)((w[i / 32] >> (i % 32)) & 1) << b; } return v;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("FTQ_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    Ent mem[N];
    long head = 0, tail = 0;                   // entries head .. tail-1 are in the queue
    long npush = 0, npop = 0, nrestore = 0, nflush = 0, nfull = 0;
    for (cyc = 0; cyc < 400000; cyc++) {
        long used = tail - head;
        // ---------- inputs
        int flush_all = rng() % 200 == 0;
        int restore = !flush_all && used > 0 && rng() % 25 == 0;
        int ridx = restore ? (int)((head + (long)(rng() % used)) % N) : (int)(rng() % N);
        int pv = rng() % 3 != 0;                // fetch is busy most of the time
        Ent pe{rng() & PCM, rng() & PCM, (int)(rng() & 1), (int)(rng() % 8), (uint32_t)rng()};
        int pop = (int)(rng() % 3); if (rng() % 2) pop = 0; if (pop > used) pop = (int)used;
        // a restore keeps the mispredicted block, which has not committed
        if (restore) { long rk = (ridx - head % N + N) % N; if (pop > rk) pop = (int)rk; }
        int rd[2], br;
        for (int r = 0; r < 2; r++) rd[r] = used ? (int)((head + (long)(rng() % used)) % N) : (int)(rng() % N);
        br = used ? (int)((head + (long)(rng() % used)) % N) : (int)(rng() % N);

        d.push_valid = pv; d.push_pc = pe.pc; d.push_target = pe.target; d.push_taken = pe.taken;
        d.push_end = pe.end; d.push_meta = pe.meta;
        d.rd_idx = rd[0] | rd[1] << 3; d.br_idx = br;
        d.pop = pop; d.restore = restore; d.restore_idx = ridx; d.flush_all = flush_all;
        d.eval();

        // ---------- outputs, from the state before the clock
        bool ready = used < N;
        if ((bool)d.push_ready != ready) FAIL("push_ready %d with %ld entries", (int)d.push_ready, used);
        if ((int)d.push_idx != (int)(tail % N)) FAIL("push_idx %d, expected %ld", (int)d.push_idx, tail % N);
        if (!ready) nfull++;
        if (used) {
            for (int r = 0; r < 2; r++) {
                uint64_t g = getw(d.rd_pc, 38 * r, 38);
                if (g != mem[rd[r]].pc) FAIL("rd_pc[%d] (entry %d) %llx, expected %llx", r, rd[r], (unsigned long long)g, (unsigned long long)mem[rd[r]].pc);
            }
            const Ent& e = mem[br];
            if ((uint64_t)d.br_pc != e.pc || (uint64_t)d.br_target != e.target || (int)d.br_taken != e.taken ||
                (int)d.br_end != e.end || (uint32_t)d.br_meta != e.meta)
                FAIL("br entry %d: pc %llx target %llx taken %d end %d meta %08x, expected %llx %llx %d %d %08x", br,
                     (unsigned long long)d.br_pc, (unsigned long long)d.br_target, (int)d.br_taken, (int)d.br_end, (uint32_t)d.br_meta,
                     (unsigned long long)e.pc, (unsigned long long)e.target, e.taken, e.end, e.meta);
        }

        // ---------- the clock, and the reference after it
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        long h = head + pop; npop += pop;
        if (flush_all) { tail = h; nflush++; }
        else if (restore) { tail = head + (ridx - head % N + N) % N + 1; nrestore++; }
        else if (pv && ready) { mem[tail % N] = pe; tail++; npush++; }
        head = h;
    }
    printf("tb_ftq: %ld cycles, %ld pushed, %ld popped, %ld restores, %ld flushes, %ld cycles full, %ld mismatches: %s\n",
           cyc, npush, npop, nrestore, nflush, nfull, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
