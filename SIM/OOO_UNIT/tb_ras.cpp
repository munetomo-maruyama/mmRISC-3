//---------------------------------------------------------------------------
// tb_ras.cpp : OOO_RAS (16 entries) against a reference stack
//
// Random pushes and pops (deep enough to wrap), and now and then a
// recovery to a snapshot taken some cycles before (sometimes with the push
// or pop of the recovered block); top, snap_ptr and snap_val are compared
// every cycle where the entry read has been written (the LUTRAM has no
// reset).
//---------------------------------------------------------------------------
#include "VOOO_RAS.h"
#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>

static std::mt19937_64 rng(13);
static VOOO_RAS d;
static const uint64_t AM = (1ull << 38) - 1;

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    uint64_t mem[16]; bool known[16] = {false};
    int ptr = 0;
    struct Snap { int ptr; uint64_t val; bool known; };
    std::deque<Snap> snaps;
    long bad = 0, cyc, npush = 0, npop = 0, nrs = 0;
    for (cyc = 0; cyc < 500000; cyc++) {
        int op = rng() % 16;
        int push = op < 6, pop = op >= 6 && op < 11;
        uint64_t pa = rng() & AM;
        int rs = !snaps.empty() && rng() % 20 == 0;
        Snap s{}; int rpush = 0, rpop = 0; uint64_t ra = rng() & AM;
        if (rs) { s = snaps[rng() % snaps.size()]; int k = rng() % 3; rpush = k == 1; rpop = k == 2; }
        d.push = push; d.push_addr = pa; d.pop = pop;
        d.rs_valid = rs; d.rs_ptr = s.ptr; d.rs_val = s.val; d.rs_push = rpush; d.rs_addr = ra; d.rs_pop = rpop;
        d.eval();
        int tp = (ptr + 15) % 16;
        if (known[tp] && (uint64_t)d.top != mem[tp] && bad++ < 10) printf("cycle %ld: top %llx, expected %llx\n", cyc, (unsigned long long)d.top, (unsigned long long)mem[tp]);
        if ((int)d.snap_ptr != ptr && bad++ < 10) printf("cycle %ld: snap_ptr %d, expected %d\n", cyc, (int)d.snap_ptr, ptr);
        if (known[ptr] && (uint64_t)d.snap_val != mem[ptr] && bad++ < 10) printf("cycle %ld: snap_val wrong\n", cyc);
        snaps.push_back(Snap{ptr, mem[ptr], known[ptr]});
        if (!snaps.back().known) snaps.pop_back();       // (a snapshot of an entry never written cannot be compared)
        if (snaps.size() > 8) snaps.pop_front();
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if (rs) {
            mem[s.ptr] = rpush ? ra : s.val; known[s.ptr] = true;
            ptr = (s.ptr + rpush - rpop + 16) % 16; nrs++;
        } else if (push) { mem[ptr] = pa; known[ptr] = true; ptr = (ptr + 1) % 16; npush++; }
        else if (pop) { ptr = (ptr + 15) % 16; npop++; }
    }
    printf("tb_ras: %ld cycles, %ld pushes, %ld pops, %ld recoveries, %ld mismatches: %s\n", cyc, npush, npop, nrs, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
