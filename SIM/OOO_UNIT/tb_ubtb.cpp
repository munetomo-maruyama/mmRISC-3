//---------------------------------------------------------------------------
// tb_ubtb.cpp : OOO_UBTB (8 entries, 12-bit partial tags) against a
// reference table
//
// Addresses come from a small region so that blocks hold several entries
// and the fetch address often starts in the middle of a block; a quarter of
// them are moved to a block with the same partial tag, so that aliases meet
// in the table. Every cycle,
// at random: an update (taken or not, conditional or not, a return), a
// redirect, a stall. The fetch address of every cycle and the prediction
// (taken, the parcel the block ends at) are compared with the reference:
// the first entry of the block at or after the fetch start that is predicted
// taken (an unconditional one, or a conditional one with its counter at 2 or
// 3) gives the next address (a return: the top of the stack), else the next
// block; a new entry replaces round robin and starts at 2.
//---------------------------------------------------------------------------
#include "VOOO_UBTB.h"
#include <cstdint>
#include <cstdio>
#include <random>
#include <vector>

struct E { bool v = false; uint64_t tag = 0; int off = 0; uint64_t tgt = 0; int cnt = 0; bool cond = false, ret = false; };

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    VOOO_UBTB d;
    std::mt19937_64 rng(9);
    const int NE = 8;
    // the partial tag: the block address (half words / 8) folded to 12 bits
    auto tagof = [](uint64_t pc) { uint64_t b = pc >> 3; return (b ^ (b >> 12)) & 0xfff; };
    std::vector<E> T(NE);
    int rr = 0;
    uint64_t pc = 0;          // in half words (address / 2)
    d.clk = 0; d.rst_n = 1; d.redirect = 0; d.upd_valid = 0; d.stall = 0; d.eval();
    d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    auto rpc = [&]() {        // a 512-byte region, or the blocks that alias with it
        uint64_t a = 0x40000000ull / 2 + (rng() % 256);
        return rng() % 4 == 0 ? a ^ (0x1001ull << 3) : a;
    };
    long bad = 0, n = 0, taken = 0;
    for (long cyc = 0; cyc < 500000; cyc++) {
        uint64_t ras = rpc();
        int redirect = rng() % 16 == 0, stall = rng() % 8 == 0, upd = rng() % 2;
        uint64_t rpcv = rpc(), upc = rpc(), utgt = rpc();
        int utk = rng() % 3 != 0, ucond = rng() & 1, uret = !ucond && rng() % 4 == 0;
        d.ras_top = ras; d.redirect = redirect; d.redirect_pc = rpcv; d.stall = stall;
        d.upd_valid = upd; d.upd_pc = upc; d.upd_taken = utk; d.upd_target = utgt; d.upd_cond = ucond; d.upd_ret = uret;
        d.eval();
        // the reference prediction for this cycle's fetch address
        uint64_t blk = pc >> 3, tg = tagof(pc); int start = (int)(pc & 7);
        int best = 8, bi = -1;
        for (int e = 0; e < NE; e++)
            if (T[e].v && T[e].tag == tg && T[e].off >= start && (!T[e].cond || T[e].cnt >= 2) && T[e].off < best) {
                best = T[e].off; bi = e;
            }
        bool pt = bi >= 0;
        uint64_t next = pt ? (T[bi].ret ? ras : T[bi].tgt) : ((blk + 1) << 3);
        n++;
        bool ok = d.fetch_pc == pc && d.pred_taken == pt && (int)d.pred_off == (pt ? best : 7);
        if (pt) taken++;
        if (!ok && bad++ < 10)
            printf("MISMATCH cycle %ld: fetch %llx/%llx taken %d/%d off %d/%d\n", cyc, (unsigned long long)d.fetch_pc,
                   (unsigned long long)pc, d.pred_taken, pt, (int)d.pred_off, pt ? best : 7);
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        // the reference after the clock
        if (redirect) pc = rpcv; else if (!stall) pc = next;
        if (upd) {
            int f = -1;
            for (int e = 0; e < NE; e++) if (T[e].v && T[e].tag == tagof(upc) && T[e].off == (int)(upc & 7)) f = e;
            if (f >= 0) {
                if (utk) { T[f].tgt = utgt; if (T[f].cnt < 3) T[f].cnt++; }
                else if (T[f].cnt > 0) T[f].cnt--;
            } else if (utk) {
                T[rr] = E{true, tagof(upc), (int)(upc & 7), utgt, 2, (bool)ucond, (bool)uret};
                rr = (rr + 1) % NE;
            }
        }
    }
    printf("tb_ubtb: %ld cycles (%ld predicted taken), %ld mismatches: %s\n", n, taken, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
