//---------------------------------------------------------------------------
// tb_ubtb2.cpp : OOO_UBTB2 (32 sets of 3 ways, 32-byte blocks, 12-bit tags)
// against a reference table
//
// Addresses come from a small region, so that blocks hold several entries, sets
// fill up, and the fetch address often starts in the middle of a block; a
// quarter of them are moved to a block with the same index and tag, so that
// aliases meet in the table. Every cycle, at random: an update (taken or not,
// conditional or not, a return), a redirect, a stall. The fetch address of every
// cycle and the prediction (taken, the parcel the block ends at) are compared
// with the reference: the first entry of the set with the block's tag, at or
// after the fetch start, predicted taken (an unconditional one, or a conditional
// one with its counter at 2 or 3) gives the next address (a return: the top of
// the stack), else the next block. A new entry replaces round robin in its set
// and starts at 2.
//---------------------------------------------------------------------------
#include "VOOO_UBTB2.h"
#include <cstdint>
#include <cstdio>
#include <random>
#include <vector>

struct E { bool v = false; uint64_t tag = 0; int off = 0; uint64_t tgt = 0; int cnt = 0; bool cond = false, ret = false; };

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    VOOO_UBTB2 d;
    std::mt19937_64 rng(9);
    const int SETS = 32, WAYS = 3;
    // in half words: 4 bits of parcel, 5 of index, 12 of tag
    auto idxof = [](uint64_t pc) { return (int)((pc >> 4) & 31); };
    auto tagof = [](uint64_t pc) { return (pc >> 9) & 0xfff; };
    std::vector<std::vector<E>> T(SETS, std::vector<E>(WAYS));
    int rr[SETS] = {0};
    uint64_t pc = 0;
    d.clk = 0; d.rst_n = 1; d.redirect = 0; d.upd_valid = 0; d.stall = 0; d.eval();
    d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    auto rpc = [&]() {        // a region of 64 blocks, or the blocks that alias with it
        uint64_t a = 0x40000000ull / 2 + (rng() % 1024);
        return rng() % 4 == 0 ? a ^ (1ull << 21) : a;
    };
    long bad = 0, n = 0, taken = 0, retk = 0, multi = 0, fills = 0;
    for (long cyc = 0; cyc < 800000; cyc++) {
        uint64_t ras = rpc();
        int redirect = rng() % 16 == 0, stall = rng() % 8 == 0, upd = rng() % 2;
        uint64_t rpcv = rpc(), upc = rpc(), utgt = rpc();
        int utk = rng() % 3 != 0, ucond = rng() & 1, uret = !ucond && rng() % 4 == 0;
        d.ras_top = ras; d.redirect = redirect; d.redirect_pc = rpcv; d.stall = stall;
        d.upd_valid = upd; d.upd_pc = upc; d.upd_taken = utk; d.upd_target = utgt; d.upd_cond = ucond; d.upd_ret = uret;
        d.eval();
        // the reference prediction for this cycle's fetch address
        std::vector<E>& S = T[idxof(pc)];
        uint64_t blk = pc >> 4, tg = tagof(pc); int start = (int)(pc & 15);
        int best = 16, bi = -1, nh = 0;
        for (int w = 0; w < WAYS; w++)
            if (S[w].v && S[w].tag == tg && S[w].off >= start && (!S[w].cond || S[w].cnt >= 2)) {
                nh++;
                if (S[w].off < best) { best = S[w].off; bi = w; }
            }
        if (nh > 1) multi++;
        bool pt = bi >= 0;
        uint64_t next = pt ? (S[bi].ret ? ras : S[bi].tgt) : ((blk + 1) << 4);
        n++;
        if (pt) { taken++; if (S[bi].ret) retk++; }
        if (d.fetch_pc != pc && bad++ < 10)
            printf("MISMATCH cycle %ld fetch_pc %llx expected %llx\n", cyc, (unsigned long long)d.fetch_pc, (unsigned long long)pc);
        if (d.pred_taken != pt && bad++ < 10)
            printf("MISMATCH cycle %ld pred_taken %d expected %d at %llx\n", cyc, d.pred_taken, pt, (unsigned long long)pc);
        if (d.pred_off != (pt ? best : 15) && bad++ < 10)
            printf("MISMATCH cycle %ld pred_off %d expected %d\n", cyc, d.pred_off, pt ? best : 15);
        d.clk = 1; d.eval(); d.clk = 0; d.eval();

        if (upd) {
            std::vector<E>& U = T[idxof(upc)];
            uint64_t ut = tagof(upc); int uo = (int)(upc & 15);
            int m = -1;
            for (int w = 0; w < WAYS; w++) if (U[w].v && U[w].tag == ut && U[w].off == uo) m = w;
            if (m < 0 && utk) {
                int w = rr[idxof(upc)];
                rr[idxof(upc)] = (w + 1) % WAYS;
                U[w].v = true; U[w].tag = ut; U[w].off = uo; U[w].tgt = utgt; U[w].cnt = 2; U[w].cond = ucond; U[w].ret = uret;
                fills++;
            } else if (m >= 0) {
                if (utk) { U[m].tgt = utgt; if (U[m].cnt < 3) U[m].cnt++; }
                else if (U[m].cnt > 0) U[m].cnt--;
            }
        }
        pc = redirect ? rpcv : stall ? pc : next;
    }
    bool cov = taken > 50000 && retk > 5000 && multi > 5000 && fills > 5000;
    printf("tb_ubtb2: %ld cycles, %ld predicted taken, %ld returns, %ld with several hits, %ld fills, %ld mismatches: %s%s\n",
           n, taken, retk, multi, fills, bad, cov ? "" : "(coverage short) ", (bad || !cov) ? "FAIL" : "PASS");
    return (bad || !cov) ? 1 : 0;
}
