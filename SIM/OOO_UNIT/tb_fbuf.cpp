//---------------------------------------------------------------------------
// tb_fbuf.cpp : OOO_FBUF (4 blocks, 4 instructions out) against an execution
// model
//
// A random program in memory (parcels with random length bits: about a
// quarter start a 32-bit instruction) is run with random taken transfers to
// random targets. The run is cut into fetch blocks as fetch would: from the
// fetch address to the end of the 16-byte block, or to the last half of a
// taken transfer; a 32-bit instruction that starts at parcel 7 ends its
// block there and finishes in the next one (also when it is the taken
// transfer). Blocks are pushed when the buffer is ready (now and then not);
// decode takes a random number of the instructions given; now and then a
// flush, after which fetch starts again at the oldest instruction not yet
// taken.
//
// Checked every cycle, for every slot: the instruction (bits, RVC), the
// parcel offset and FTQ index of its first half, taken, seq, and that the
// valid slots are a prefix; and the number of instructions given exactly:
// as many complete instructions as lie in the window (the rest of the head
// block, then the next block, 8 parcels at most), up to 4.
//---------------------------------------------------------------------------
#include "VOOO_FBUF.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <vector>

static const int MEMP = 512;                   // parcels of program memory (1 KB)
static std::mt19937_64 rng(31);
static VOOO_FBUF d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint16_t mem[MEMP];
struct Ins { uint32_t pc; int len; uint32_t bits; bool taken; long fblk = -1, lblk = -1; int off = 0; int ftq = 0; };
static std::vector<Ins> ex;                    // the run, in order
static uint32_t next_pc = 0;

static void extend(size_t n)
{
    while (ex.size() < n) {
        Ins I; I.pc = next_pc;
        uint16_t p0 = mem[(I.pc / 2) % MEMP], p1 = mem[(I.pc / 2 + 1) % MEMP];
        I.len = (p0 & 3) == 3 ? 4 : 2;
        I.bits = I.len == 4 ? ((uint32_t)p1 << 16 | p0) : p0;
        I.taken = rng() % 7 == 0;
        next_pc = I.taken ? (uint32_t)(rng() % (MEMP - 16)) * 2 : I.pc + I.len;
        // stay inside: near the end the program goes back to 0, by a taken transfer
        if (next_pc / 2 + 1 >= MEMP) { I.taken = true; next_pc = 0; }
        ex.push_back(I);
    }
}

template <class W> static void setw(W& w, int lo, int n, uint64_t v) {
    for (int b = 0; b < n; b++) { int i = lo + b; uint32_t m = 1u << (i % 32); if ((v >> b) & 1) w[i / 32] |= m; else w[i / 32] &= ~m; }
}
template <class W> static uint64_t getw(const W& w, int lo, int n) {
    uint64_t v = 0; for (int b = 0; b < n; b++) { int i = lo + b; v |= (uint64_t)((w[i / 32] >> (i % 32)) & 1) << b; } return v;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("FBUF_SEED")) rng.seed(strtoull(e, nullptr, 0));
    for (int i = 0; i < MEMP; i++) mem[i] = (uint16_t)rng();
    d.clk = 0; d.rst_n = 1; d.flush = 0; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    struct Blk { long id; int s, e; };
    std::deque<Blk> q;                         // blocks pushed, not yet used up
    long fp = 0; bool cross = false;           // fetch: the next instruction (its second half if cross)
    long cons = 0;                             // the next instruction decode has not taken
    long blk_id = 0; int ftq = 0;
    long ntaken = 0, ninst = 0, ncross = 0, nflush = 0, nfull4 = 0;
    extend(64);
    for (cyc = 0; cyc < 400000; cyc++) {
        extend(fp + 64);
        // ---------- a block from fetch
        int flush = rng() % 300 == 0;
        d.in_valid = 0; d.consume = 0; d.flush = 0; d.eval();     // in_ready comes from the state alone
        int push = !flush && d.in_ready && rng() % 4 != 0;
        Blk nb{blk_id, 0, 7};
        uint32_t bpc = 0; int btaken = 0;
        long fp_n = fp; bool cross_n = cross;
        std::vector<long> firsts, lasts;       // instructions whose first / last half is in this block
        if (push) {
            uint32_t a = cross ? ex[fp].pc + 2 : ex[fp].pc;
            bpc = a & ~15u;
            nb.s = (a >> 1) & 7;
            for (long k = fp;; k++) {
                extend(k + 2);
                Ins& I = ex[k];
                bool second = cross && k == fp;    // only its second half is here
                int f = (I.pc >> 1) & 7, l = f + I.len / 2 - 1;
                if (second) { lasts.push_back(k); l = 0; }
                else {
                    firsts.push_back(k);
                    if (l > 7) { nb.e = 7; fp_n = k; cross_n = true; break; }   // across the block
                    lasts.push_back(k);
                }
                if (I.taken) { nb.e = l; btaken = 1; fp_n = k + 1; cross_n = false; break; }
                if (l == 7) { nb.e = 7; fp_n = k + 1; cross_n = false; break; }
            }
        }
        d.in_valid = push; d.in_start = nb.s; d.in_end = nb.e; d.in_taken = btaken; d.in_ftq = ftq;
        for (int k = 0; k < 8; k++) setw(d.in_data, 16 * k, 16, mem[(bpc / 2 + k) % MEMP]);
        d.flush = flush;
        // ---------- what the buffer must give: instructions from cons whose
        // parcels lie in the window (head block, next block, 8 parcels)
        int expect = 0;
        if (!q.empty()) {
            long A = q[0].id, B = q.size() >= 2 ? q[1].id : -1;
            int parcels = 0;
            for (long k = cons; k < (long)ex.size() && expect < 4; k++) {
                Ins& I = ex[k];
                if (I.fblk < 0 || I.lblk < 0) break;                   // not all fetched
                if (I.fblk != A && I.fblk != B) break;
                if (I.lblk != A && I.lblk != B) break;
                parcels += I.len / 2;
                if (parcels > 8) break;
                expect++;
            }
        }
        // decode takes some
        int consume = 0;
        d.consume = 0;
        d.eval();
        int nv = 0;
        for (int i = 0; i < 4; i++) { bool v = (d.out_valid >> i) & 1; if (v && nv != i) FAIL("valid slots not a prefix (%x)", (int)d.out_valid); if (v) nv++; }
        if (nv != expect) FAIL("%d instructions given, expected %d", nv, expect);
        for (int i = 0; i < nv && i < expect; i++) {
            Ins& I = ex[cons + i];
            uint32_t bits = getw(d.out_inst, 32 * i, 32);
            bool rvc = (d.out_rvc >> i) & 1;
            uint32_t want = I.len == 4 ? I.bits : (I.bits & 0xffff);
            if ((rvc ? (bits & 0xffff) : bits) != want || rvc != (I.len == 2))
                FAIL("slot %d (insn %ld, pc %x): bits %08x rvc %d, expected %08x rvc %d", i, cons + i, I.pc, bits, rvc, want, I.len == 2);
            if ((int)((d.out_off >> (3 * i)) & 7) != I.off) FAIL("slot %d: off %d, expected %d", i, (int)((d.out_off >> (3 * i)) & 7), I.off);
            if ((int)((d.out_ftq >> (3 * i)) & 7) != I.ftq) FAIL("slot %d: ftq %d, expected %d", i, (int)((d.out_ftq >> (3 * i)) & 7), I.ftq);
            if ((bool)((d.out_taken >> i) & 1) != I.taken) FAIL("slot %d: taken %d, expected %d", i, (int)((d.out_taken >> i) & 1), I.taken);
            if (i > 0 && (bool)((d.out_seq >> i) & 1) != !ex[cons + i - 1].taken) FAIL("slot %d: seq wrong", i);
        }
        if (nv == 4) nfull4++;
        // (no more than the model expects, so that a wrong RTL cannot run the model off its end)
        consume = flush ? 0 : (int)(rng() % (std::min(nv, expect) + 1));
        d.consume = consume;
        d.eval();
        // ---------- the clock
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        // ---------- the model after it
        if (flush) {
            q.clear(); nflush++;
            for (long k = cons; k < (long)ex.size(); k++) { ex[k].fblk = ex[k].lblk = -1; }
            fp = cons; cross = false;
            continue;
        }
        for (int i = 0; i < consume; i++) { ninst++; if (ex[cons].taken) ntaken++; cons++; }
        if (push) {
            for (long k : firsts) { ex[k].fblk = blk_id; ex[k].off = (ex[k].pc >> 1) & 7; ex[k].ftq = ftq; }
            for (long k : lasts) { ex[k].lblk = blk_id; if (k == fp && cross) ncross++; }
            q.push_back(nb);
            blk_id++; ftq = (ftq + 1) % 8;
            fp = fp_n; cross = cross_n;
        }
        // the head block holds the first half of the oldest instruction not
        // taken; if that one is not fetched yet, every block is used up
        while (!q.empty()) {
            long f = ex[cons].fblk;
            if (f < 0) { q.clear(); break; }
            if (q[0].id < f) q.pop_front(); else break;
        }
        d.in_valid = 0; d.consume = 0; d.flush = 0; d.eval();
        if ((bool)d.in_ready != (q.size() < 4)) FAIL("in_ready %d with %zu blocks", (int)d.in_ready, q.size());
    }
    printf("tb_fbuf: %ld cycles, %ld instructions taken (%ld taken transfers, %ld across blocks), 4 given in %ld cycles, %ld flushes, %ld mismatches: %s\n",
           cyc, ninst, ntaken, ncross, nfull4, nflush, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
