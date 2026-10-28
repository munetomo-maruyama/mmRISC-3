//---------------------------------------------------------------------------
// tb_mdup.cpp : OOO_MDUP (CORE_MDU behind port 0) with port 0 played by the
// issue queue's rules
//
// Every cycle port 0 issues an MDU µop (only with mdu_ok), a latency-1 µop
// that writes (not in the cycle after a mul issued on port 0, nor with
// p0_hold), or nothing; an issued µop is in RR the cycle after and in EX the
// one after that (ex_valid for an MDU one, ex_lat1_wr for the other). The
// MDU µops are random mul / mulh / mulhsu / mulhu / div / divu / rem / remu,
// their W forms, clmul / clmulr / clmulh, with random operands (small ones,
// zero, -1 and the most negative now and then: division by zero and the
// overflow). Each carries the mask of the branch ids open when it issued;
// kills of an open id, clears, and now and then a flush. A quarter of the
// time port 0 gives a latency-1 writer every cycle it may (the slot a long
// result needs comes only by p0_hold).
//
// Checked: every MDU µop not killed or flushed writes once, with its tag,
// its ROB index and the value of the reference (the M / Zbc semantics);
// one that is killed or flushed writes nothing; a mul writes exactly 3
// cycles after its issue (the issue queue woke its dependents for that);
// a long one never in a cycle with a latency-1 writer in EX, and with its
// wakeup (ext_*); no MDU µop waits more than 200 cycles to be written, and
// mdu_ok is never low for 200 cycles with no MDU µop in flight.
//---------------------------------------------------------------------------
#include "VOOO_MDUP.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <vector>

static std::mt19937_64 rng(73);
static VOOO_MDUP d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

typedef unsigned __int128 u128;
typedef __int128 s128;
static uint64_t sx32(uint64_t v) { return (uint64_t)(int64_t)(int32_t)v; }
static uint64_t clmul_full(uint64_t a, uint64_t b, uint64_t& hi)
{
    u128 r = 0;
    for (int i = 0; i < 64; i++) if ((b >> i) & 1) r ^= (u128)a << i;
    hi = (uint64_t)(r >> 64);
    return (uint64_t)r;
}
static uint64_t ref(int op, bool w, uint64_t a, uint64_t b)
{
    if (w) {
        int32_t x = (int32_t)a, y = (int32_t)b; uint32_t ux = (uint32_t)a, uy = (uint32_t)b;
        switch (op) {
        case 0: return sx32((uint64_t)(ux * uy));
        case 4: return y == 0 ? ~0ull : (x == INT32_MIN && y == -1) ? sx32((uint32_t)x) : sx32((uint32_t)(x / y));
        case 5: return uy == 0 ? ~0ull : sx32(ux / uy);
        case 6: return y == 0 ? sx32((uint32_t)x) : (x == INT32_MIN && y == -1) ? 0 : sx32((uint32_t)(x % y));
        case 7: return uy == 0 ? sx32(ux) : sx32(ux % uy);
        }
        return 0;
    }
    int64_t x = (int64_t)a, y = (int64_t)b;
    uint64_t hi;
    switch (op) {
    case 0: return a * b;
    case 1: return (uint64_t)(((s128)x * (s128)y) >> 64);
    case 2: return (uint64_t)(((s128)x * (s128)(u128)b) >> 64);
    case 3: return (uint64_t)(((u128)a * (u128)b) >> 64);
    case 4: return y == 0 ? ~0ull : (x == INT64_MIN && y == -1) ? a : (uint64_t)(x / y);
    case 5: return b == 0 ? ~0ull : a / b;
    case 6: return y == 0 ? a : (x == INT64_MIN && y == -1) ? 0 : (uint64_t)(x % y);
    case 7: return b == 0 ? a : a % b;
    case 9:  { uint64_t lo = clmul_full(a, b, hi); return lo; }
    case 11: { clmul_full(a, b, hi); return hi; }
    case 10: { uint64_t lo = clmul_full(a, b, hi); return (hi << 1) | (lo >> 63); }   // bits 126:63
    }
    return 0;
}
static uint64_t operand()
{
    switch (rng() % 8) {
    case 0: return 0;
    case 1: return ~0ull;
    case 2: return 1ull << 63;
    case 3: return 0x80000000ull | (rng() & 0xffffffff00000000ull);
    case 4: return rng() % 100;
    default: return rng();
    }
}

struct Op { long iss; int op; bool w; uint64_t a, b; int rob, tag; unsigned bm; bool dead = false, done = false; };

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("MDUP_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    std::deque<Op> ops;                         // MDU µops issued, not yet written or dropped
    std::vector<int> open;                      // branch ids open
    // port 0's pipeline: what was issued 1 and 2 cycles ago
    struct P { bool v = false, md = false, l1 = false; Op o; } rr, ex;
    bool mul_last = false;                      // a mul issued on port 0 in the cycle before
    long nmd = 0, nl1 = 0, nkill = 0, nflush = 0, nlong = 0, nmul = 0, nwait = 0;
    int next_tag = 1;
    long ok_low = 0;

    for (cyc = 0; cyc < 400000; cyc++) {
        // ---- kills, clears, flushes
        int flush = rng() % 400 == 0;
        unsigned killm = 0, clrm = 0;
        if (!flush && !open.empty() && rng() % 25 == 0) { size_t i = rng() % open.size(); killm = 1u << open[i]; open.resize(i); }
        if (!flush && !open.empty() && rng() % 8 == 0) { size_t i = rng() % open.size(); clrm = 1u << open[i]; open.erase(open.begin() + i); }
        // ---- issue on port 0
        bool mdu_ok = d.mdu_ok, hold = d.p0_hold;
        bool blk0 = mul_last || hold;
        P is;
        bool busy_phase = (cyc / 500) % 4 == 3;
        int r = rng() % 6;
        if (busy_phase) r = (r < 2) ? r : 2;            // every cycle something; latency-1 writers when allowed
        unsigned bm = 0; for (int o : open) bm |= 1u << o;
        if (r < 2 && mdu_ok) {
            Op o; o.iss = cyc; o.bm = bm;
            int k = rng() % 12;
            if (k < 4) { o.op = 0; o.w = rng() & 1; }                        // mul / mulw (often)
            else if (k < 7) { o.op = 1 + rng() % 3; o.w = false; }           // mulh*
            else if (k < 10) { o.op = 4 + rng() % 4; o.w = rng() & 1; }     // divides
            else { o.op = 9 + rng() % 3; o.w = false; }                      // clmul*
            o.a = operand(); o.b = operand(); o.rob = rng() % 24; o.tag = next_tag; next_tag = next_tag % 63 + 1;
            is.v = true; is.md = true; is.o = o; nmd++;
        } else if (r < 4 && !blk0) {
            is.v = true; is.l1 = true; nl1++;
        }
        if (rng() % 5 == 0 && (int)open.size() < 6) {      // a branch opens an id after this cycle's µops
            int o; do { o = rng() % 6; } while (std::find(open.begin(), open.end(), o) != open.end()); open.push_back(o);
        }
        // ---- drive
        d.flush = flush; d.kill = killm; d.clr = clrm;
        d.iss_md = is.v && is.md; d.iss_md_long = is.v && is.md && is.o.op != 0; d.iss_bm = is.v ? is.o.bm : rng() & 63;
        d.ex_valid = ex.v && ex.md; d.ex_lat1_wr = ex.v && ex.l1;
        d.ex_op = ex.o.op; d.ex_word = ex.o.w; d.ex_a = ex.o.a; d.ex_b = ex.o.b; d.ex_rob = ex.o.rob; d.ex_dst = ex.o.tag; d.ex_bm = ex.o.bm;
        d.eval();

        // ---- what is written now
        if (d.res_valid) {
            Op* f = nullptr; for (auto& o : ops) if (!o.done && !o.dead && o.tag == (int)d.res_tag) { f = &o; break; }
            if (!f) FAIL("a write of tag %d with no MDU µop waiting for it", (int)d.res_tag);
            else {
                uint64_t e = ref(f->op, f->w, f->a, f->b);
                if ((uint64_t)d.res_data != e) FAIL("op %d w %d (%016llx, %016llx): %016llx, expected %016llx", f->op, f->w,
                    (unsigned long long)f->a, (unsigned long long)f->b, (unsigned long long)d.res_data, (unsigned long long)e);
                if ((int)d.res_rob != f->rob) FAIL("rob %d, expected %d", (int)d.res_rob, f->rob);
                if (f->op == 0 && cyc != f->iss + 3) FAIL("mul issued in %ld written in %ld", f->iss, cyc);
                if (f->op != 0 && ex.v && ex.l1) FAIL("a long result written with a latency-1 writer in EX");
                bool xv = d.ext_valid;
                if (xv != (f->op != 0) || (xv && (int)d.ext_tag != f->tag)) FAIL("ext wakeup %d for op %d", (int)xv, f->op);
                if (f->op == 0) nmul++; else nlong++;
                f->done = true;
            }
        } else if (d.ext_valid) FAIL("a wakeup without a write");

        // ---- the clock, and the model after it
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if (flush) { for (auto& o : ops) o.dead = true; open.clear(); nflush++; }
        else if (killm) for (auto& o : ops) if (o.bm & killm) { if (!o.dead) nkill++; o.dead = true; }
        for (auto& o : ops) o.bm &= ~clrm;
        // the pipeline moves on (the stages drop what is killed or flushed)
        ex = rr; rr = is;
        if (flush) { ex.v = false; rr.v = false; }
        if (killm) { if (ex.v && ex.md && (ex.o.bm & killm)) ex.v = false; if (rr.v && rr.md && (rr.o.bm & killm)) rr.v = false; }
        if (ex.v && ex.md) ex.o.bm &= ~clrm;
        if (rr.v && rr.md) rr.o.bm &= ~clrm;
        if (is.v && is.md) { Op o = is.o; if (flush || (o.bm & killm)) o.dead = true; o.bm &= ~clrm; ops.push_back(o); if (rr.v && rr.md) rr.o.bm = o.bm; }
        mul_last = is.v && is.md && is.o.op == 0 && !flush && !(is.o.bm & killm);
        while (!ops.empty() && (ops.front().done || ops.front().dead) && cyc - ops.front().iss > 3) ops.pop_front();
        bool inflight = false; for (auto& o : ops) inflight |= !o.done && !o.dead;
        ok_low = (d.mdu_ok || inflight) ? 0 : ok_low + 1;
        if (ok_low == 200) FAIL("mdu_ok low for 200 cycles with nothing in flight");
        for (auto& o : ops) if (!o.done && !o.dead && cyc - o.iss > 200) { FAIL("op %d issued in %ld not written", o.op, o.iss); o.dead = true; nwait++; }
    }
    printf("tb_mdup: %ld cycles, %ld MDU µops (%ld muls, %ld long ones written), %ld latency-1 writers, %ld killed, %ld flushes, %ld mismatches: %s\n",
           cyc, nmd, nmul, nlong, nl1, nkill, nflush, bad, bad ? "FAIL" : "PASS");
    (void)nwait;
    return bad ? 1 : 0;
}
