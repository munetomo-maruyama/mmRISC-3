//---------------------------------------------------------------------------
// tb_pmul.cpp : OOO_PMUL (the pipelined mul / mulw beside CORE_MDU)
//
// A mul or mulw in EX most cycles (back to back), with operands that hit the
// signs and the carries (0, -1, the most negative, 32-bit edges, random),
// each with the mask of the branch ids open; kills of an open id, clears,
// and now and then a flush, in either of its two cycles. A closed id opens
// again 5 cycles later at the earliest, as in the core (OOO_PMUL keeps the
// clears of EX's cycle for its one cycle after).
//
// Checked: every µop not killed or flushed writes exactly the cycle after
// EX with its tag, its ROB index and the low 64 bits of the product (mulw:
// the low 32 sign extended); one killed or flushed in EX or in the cycle
// after writes nothing; nothing else is written.
//---------------------------------------------------------------------------
#include "VOOO_PMUL.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

static std::mt19937_64 rng(79);
static VOOO_PMUL d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint64_t operand()
{
    switch (rng() % 10) {
    case 0: return 0;
    case 1: return ~0ull;
    case 2: return 1ull << 63;
    case 3: return 0xffffffffull;
    case 4: return 0x80000000ull;
    case 5: return rng() & 0xffffffffull;
    case 6: return rng() | 0xffffffff00000000ull;
    default: return rng();
    }
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("PMUL_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    struct M { bool v = false; uint64_t e; int tag, rob; unsigned bm; } m;   // the µop in its second cycle
    std::vector<int> open;
    long closed_at[6] = {-9, -9, -9, -9, -9, -9};
    long nmul = 0, nwritten = 0, nkill = 0, nflush = 0;
    for (cyc = 0; cyc < 400000; cyc++) {
        int flush = rng() % 300 == 0;
        unsigned killm = 0, clrm = 0;
        // the µop in EX was renamed under the ids open before this cycle's kill
        unsigned bm = 0; for (size_t i = 0, n = rng() % (open.size() + 1); i < n; i++) bm |= 1u << open[i];
        if (!flush && !open.empty() && rng() % 12 == 0) { size_t i = rng() % open.size(); killm = 1u << open[i]; for (size_t k = i; k < open.size(); k++) closed_at[open[k]] = cyc; open.resize(i); }
        if (!flush && !open.empty() && rng() % 8 == 0) { size_t i = rng() % open.size(); clrm = 1u << open[i]; closed_at[open[i]] = cyc; open.erase(open.begin() + i); }
        bool v = rng() % 5 != 0;
        bool w = rng() & 1;
        uint64_t a = operand(), b = operand();
        int tag = rng() % 64, rob = rng() % 24;
        d.flush = flush; d.kill = killm; d.ex_valid = v; d.ex_word = w; d.ex_a = a; d.ex_b = b;
        d.ex_rob = rob; d.ex_dst = tag; d.ex_bm = bm;
        d.eval();

        // the µop of the cycle before writes now, unless killed or flushed now
        bool ew = m.v && !flush && !(m.bm & killm);
        if ((bool)d.res_valid != ew) FAIL("res_valid %d, expected %d", (int)d.res_valid, ew);
        else if (ew) {
            if ((uint64_t)d.res_data != m.e) FAIL("product %016llx, expected %016llx", (unsigned long long)d.res_data, (unsigned long long)m.e);
            if ((int)d.res_tag != m.tag || (int)d.res_rob != m.rob) FAIL("tag %d rob %d, expected %d %d", (int)d.res_tag, (int)d.res_rob, m.tag, m.rob);
            nwritten++;
        }
        if (m.v && !ew) nkill++;

        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if (flush) { for (int o : open) closed_at[o] = cyc; open.clear(); nflush++; }
        if (v) nmul++;
        m.v = v && !flush && !(bm & killm);
        if (v && (flush || (bm & killm))) nkill++;
        uint64_t p = a * b;
        m.e = w ? (uint64_t)(int64_t)(int32_t)p : p;
        m.tag = tag; m.rob = rob; m.bm = bm & ~clrm;
        if (rng() % 3 == 0) {
            int o = rng() % 6;
            if (std::find(open.begin(), open.end(), o) == open.end() && cyc - closed_at[o] >= 5) open.push_back(o);
        }
    }
    printf("tb_pmul: %ld cycles, %ld muls (%ld written, %ld killed or flushed), %ld flushes, %ld mismatches: %s\n",
           cyc, nmul, nwritten, nkill, nflush, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
