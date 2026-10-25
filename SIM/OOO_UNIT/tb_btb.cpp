//---------------------------------------------------------------------------
// tb_btb.cpp : OOO_BTB (256 rows) against a reference table
//
// Reads with random fetch addresses from a small set of lines (so that
// they hit, and other lines with the same index miss on the tag), writes
// of random jumps of those lines, both now and then in the same cycle and
// row (the read sees the old row). The result of a read is compared from
// the second cycle after it until the next read, as F2 uses it.
//---------------------------------------------------------------------------
#include "VOOO_BTB.h"
#include <cstdint>
#include <cstdio>
#include <map>
#include <random>

static std::mt19937_64 rng(17);
static VOOO_BTB d;
static const uint64_t AM = (1ull << 38) - 1;

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    uint64_t lines[64];
    for (auto& l : lines) l = rng() & ((1ull << 35) - 1);
    for (int k = 0; k < 16; k++) lines[48 + k] = (lines[k] & 0xff) | ((rng() & ((1ull << 27) - 1)) << 8);  // same index, another tag
    struct Row { bool v = false; uint32_t tag = 0; int off = 0; uint64_t tgt = 0; };
    Row mem[256];
    struct Res { bool hit; int off; uint64_t tgt; };
    Res r1{}, r2{}; bool p1 = false, have = false;       // the read in F1, and the result held for F2
    long bad = 0, cyc, nhit = 0, nrd = 0;
    for (cyc = 0; cyc < 500000; cyc++) {
        int rd = rng() % 3 != 0;
        uint64_t rl = lines[rng() % 64];
        uint64_t rpc = (rl << 3) | (rng() & 7);
        int wr = rng() % 4 == 0;
        uint64_t wl = (rng() % 4 == 0) ? rl : lines[rng() % 64];
        uint64_t wpc = (wl << 3) | (rng() & 7), wt = rng() & AM;
        d.rd_en = rd; d.rd_pc = rpc; d.wr_valid = wr; d.wr_pc = wpc; d.wr_tgt = wt;
        d.eval();
        if (have) {
            if ((bool)d.hit != r2.hit && bad++ < 10) printf("cycle %ld: hit %d, expected %d\n", cyc, (int)d.hit, r2.hit);
            if (r2.hit && ((int)d.off != r2.off || (uint64_t)d.tgt != r2.tgt) && bad++ < 10) printf("cycle %ld: off / tgt wrong\n", cyc);
        }
        // the reference: a read looks at the rows before this cycle's write
        Res now{};
        if (rd) {
            Row& w = mem[(rpc >> 3) & 255];
            uint32_t tg = (uint32_t)((rpc >> 11) & 1023);
            now = Res{w.v && w.tag == tg, w.off, w.tgt};
            nrd++; nhit += now.hit;
        }
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if (p1) { r2 = r1; have = true; }
        p1 = rd; if (rd) r1 = now;
        if (wr) { Row& w = mem[(wpc >> 3) & 255]; w.v = true; w.tag = (uint32_t)((wpc >> 11) & 1023); w.off = (int)(wpc & 7); w.tgt = wt; }
    }
    printf("tb_btb: %ld cycles, %ld reads (%ld hits), %ld mismatches: %s\n", cyc, nrd, nhit, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
