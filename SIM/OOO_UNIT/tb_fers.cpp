//---------------------------------------------------------------------------
// tb_fers.cpp : OOO_FERS (the front end's restore) against blocks built
// from their instructions
//
// The test bench keeps an FTQ of 8 blocks. A block is made as the front end
// makes it: a line, a start parcel, instructions of 1 or 2 parcels with
// some conditional branches (the first three are its slots, predicted by a
// coin until one is predicted taken, where the block ends), maybe a call,
// a return or another jalr ending it; a random history before it and a
// random RAS snapshot. The entry gives OOO_FERS what OOO_FTQ / OOO_TAGE
// keep: the line, the history, the slot valid bits and last parcels, the
// RAS snapshot.
//
// Every cycle, now and then, a redirect (OOO_CTRL fe_redirect, at times in
// two cycles in a row) at a point in one of the blocks:
//   restore  a mispredicted transfer of the block, resolved on ALU port 0
//            or 1 (the other port gives random values): a slot branch
//            (its outcome the other way), a branch past the slots, a call,
//            a return or another jalr
//   trap / replay  any instruction of the block, from the ROB (rcv_*)
// The cycle after it, OOO_FERS must read that block (rs_idx) and give
// fetch the pc of the redirect, the block's history, the slot outcomes of
// the instructions up to the point (each slot branch before it as it was
// predicted, the point itself with its outcome if it is a slot branch that
// was resolved; a trap at a branch, a debug trigger, comes before it),
// the RAS snapshot and the point's own push (a call: the address after
// it) or pop (a return). And no redirect in a cycle without one before.
//---------------------------------------------------------------------------
#include "VOOO_FERS.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

static std::mt19937_64 rng(53);
static VOOO_FERS d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const uint64_t AM = (1ull << 38) - 1;   // halfword addresses
enum Kind { ALU, BR, CALL, RET, JALR };
struct Ins { int first, last; Kind k; bool pred; int slot; };
struct Blk {
    uint64_t line; std::vector<Ins> ins;
    uint64_t hist[3];                           // 70 bits
    int pred = 0, sv = 0, par[3] = {0, 0, 0};
    int rptr; uint64_t rval;
};

static Blk make_block()
{
    Blk b;
    b.line = rng() & (AM >> 3);
    int p = rng() % 8, ns = 0;
    if (rng() % 4 == 0) p = 0;
    while (p < 8) {
        Ins I;
        I.first = p;
        int len = (rng() % 3 == 0) ? 2 : 1;
        if (p == 7 && len == 2) len = 1;        // (an instruction across lines belongs to the next block)
        I.last = p + len - 1;
        int r = rng() % 10;
        I.k = r < 4 ? BR : r == 4 ? CALL : r == 5 ? RET : r == 6 ? JALR : ALU;
        I.pred = false; I.slot = -1;
        bool ends = false;
        if (I.k == BR) {
            if (ns < 3) {
                I.slot = ns; I.pred = rng() % 3 == 0;
                b.sv |= 1 << ns; b.par[ns] = I.last; b.pred |= (int)I.pred << ns; ns++;
                ends = I.pred;
            }
        } else if (I.k != ALU) ends = rng() % 2;  // predicted taken (a jalr only when the BTB has it)
        b.ins.push_back(I);
        p = I.last + 1;
        if (ends) break;
    }
    for (int k = 0; k < 3; k++) b.hist[k] = rng();
    b.hist[2] &= 63;
    b.rptr = rng() % 16; b.rval = rng() & AM;
    return b;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("FERS_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.fe_redirect = 0; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    Blk ftq[8];
    for (int i = 0; i < 8; i++) ftq[i] = make_block();
    struct Exp { bool v = false; uint64_t pc; int idx; int n, bits; bool push, pop; uint64_t addr; } exp;
    long nred = 0, nflush = 0, nslot = 0, nbr_past = 0, ncall = 0, nret = 0, nback = 0, nbits1 = 0;

    for (cyc = 0; cyc < 400000; cyc++) {
        // ---- a new block now and then (the FTQ refills; not the one being read)
        int nb = rng() % 8;
        if (!(exp.v && exp.idx == nb) && rng() % 3 == 0) ftq[nb] = make_block();

        // ---- a redirect now?
        bool red = rng() % 3 == 0;
        if (exp.v && rng() % 2) red = true;     // two in a row now and then
        Exp nx;
        uint32_t be = 0, bt = 0, bc = 0, br = 0;
        int port = rng() & 1, flush = 0, idx = 0, e = 0;
        for (int p = 0; p < 2; p++) { be |= (uint32_t)(rng() % 8) << (3 * p); bt |= (uint32_t)(rng() & 1) << p; bc |= (uint32_t)(rng() & 1) << p; br |= (uint32_t)(rng() & 1) << p; }
        uint64_t pc = rng() & AM;
        int rcv_ftq = rng() % 8, rcv_end = rng() % 8, rftq = rng() % 8;
        if (red) {
            idx = rng() % 8;
            Blk& b = ftq[idx];
            const Ins& I = b.ins[rng() % b.ins.size()];
            flush = rng() % 4 == 0;
            e = I.last;
            bool taken = false, call = false, ret = false;
            if (flush) { rcv_ftq = idx; rcv_end = e; nflush++; }
            else {
                // a resolved transfer: the point is a mispredicted one
                rftq = idx;
                if (I.k == BR) taken = !I.pred;     // the other way (a branch past the slots: any)
                if (I.k == BR && I.slot < 0) taken = rng() & 1;
                call = I.k == CALL; ret = I.k == RET;
                be = (be & ~(7u << (3 * port))) | ((uint32_t)e << (3 * port));
                bt = (bt & ~(1u << port)) | ((uint32_t)taken << port);
                bc = (bc & ~(1u << port)) | ((uint32_t)call << port);
                br = (br & ~(1u << port)) | ((uint32_t)ret << port);
                if (I.k == BR) { if (I.slot >= 0) nslot++; else nbr_past++; }
                ncall += call; nret += ret;
            }
            // what fetch must get: the slot branches up to the point
            nx.v = true; nx.pc = pc; nx.idx = idx; nx.n = 0; nx.bits = 0;
            for (const Ins& J : b.ins) {
                if (J.first > I.first || (flush && &J == &I)) break;
                if (J.k != BR || J.slot < 0) continue;
                bool o = (&J == &I) ? taken : J.pred;
                nx.bits |= (int)o << nx.n; nx.n++;
            }
            nx.push = !flush && call; nx.pop = !flush && ret;
            nx.addr = ((b.line << 3) | (uint64_t)e) + 1;
            nred++;
            if (nx.bits) nbits1++;
        }
        d.fe_redirect = red; d.fe_flush = flush; d.fe_pc = pc;
        d.restore_ftq = rftq; d.restore_port = port;
        d.br_e = be; d.br_taken = bt; d.br_call = bc; d.br_ret = br;
        d.rcv_ftq = rcv_ftq; d.rcv_end = rcv_end;
        d.eval();
        // the FTQ's read (combinational from rs_idx)
        {
            Blk& b = ftq[d.rs_idx & 7];
            d.ft_line = b.line;
            for (int k = 0; k < 3; k++) d.ft_hist[k] = (uint32_t)b.hist[k];
            d.ft_sv = b.sv;
            d.ft_par = (uint32_t)b.par[0] | ((uint32_t)b.par[1] << 3) | ((uint32_t)b.par[2] << 6);
            d.ft_ras_ptr = b.rptr; d.ft_ras_val = b.rval;
            d.eval();
        }

        // ---- the redirect of the cycle before
        if ((bool)d.be_redirect != exp.v) FAIL("be_redirect %d, expected %d", (int)d.be_redirect, exp.v);
        else if (exp.v) {
            if (exp.v && red) nback++;
            Blk& b = ftq[exp.idx];
            if ((int)d.rs_idx != exp.idx) FAIL("rs_idx %d, expected %d", (int)d.rs_idx, exp.idx);
            if ((uint64_t)d.be_pc != exp.pc) FAIL("be_pc %llx, expected %llx", (unsigned long long)d.be_pc, (unsigned long long)exp.pc);
            for (int k = 0; k < 3; k++) if (d.be_hist[k] != (uint32_t)b.hist[k]) { FAIL("be_hist word %d", k); break; }
            int mask = (1 << exp.n) - 1;
            if ((int)d.be_hist_n != exp.n || ((int)d.be_hist_bits & mask) != exp.bits)
                FAIL("history: %d slots %x, expected %d slots %x (block sv %x par %d %d %d pred %x)", (int)d.be_hist_n,
                     (int)d.be_hist_bits & mask, exp.n, exp.bits, b.sv, b.par[0], b.par[1], b.par[2], b.pred);
            if ((int)d.be_ras_ptr != b.rptr || (uint64_t)d.be_ras_val != b.rval) FAIL("RAS snapshot");
            if ((bool)d.be_ras_push != exp.push || (bool)d.be_ras_pop != exp.pop) FAIL("RAS push %d pop %d, expected %d %d", (int)d.be_ras_push, (int)d.be_ras_pop, exp.push, exp.pop);
            if (exp.push && (uint64_t)d.be_ras_addr != exp.addr) FAIL("RAS push address %llx, expected %llx", (unsigned long long)d.be_ras_addr, (unsigned long long)exp.addr);
        }

        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        exp = nx;
    }
    printf("tb_fers: %ld cycles, %ld redirects (%ld traps / replays, %ld slot branches, %ld branches past the slots, %ld calls, %ld returns, %ld with slot bits set, %ld right after another), %ld mismatches: %s\n",
           cyc, nred, nflush, nslot, nbr_past, ncall, nret, nbits1, nback, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
