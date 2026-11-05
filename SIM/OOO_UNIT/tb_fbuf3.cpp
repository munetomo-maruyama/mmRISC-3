//---------------------------------------------------------------------------
// tb_fbuf3.cpp : OOO_FBUF3 (32-byte blocks, 8 waiting, 6 instructions out of 2 blocks) against
// the program it is given
//
// A random program in memory (parcels with random length bits: about a quarter
// start a 32-bit instruction) is run with random taken transfers to random targets.
// The run is cut into fetch blocks as fetch would: from the fetch address to the end
// of the 32-byte block, or to the last half of a taken transfer; a 32-bit instruction
// that starts at parcel 15 ends its block there and finishes in the next one (also
// when it is the taken transfer). Blocks are pushed now and then, decode is ready now
// and then; now and then a flush, after which fetch starts again at the oldest
// instruction not taken.
//
// Checked every cycle: that a block in has its instructions out in order, each with
// its bits, RVC, the parcel and the FTQ index of its first half, taken; slot 0's rare
// (against a predecode of its first parcel from the list of Doc/UARCH.md 6.3 G2); the
// number given exactly: what is left of the block and of the next one if it is read (bv),
// at most 6, or 1 if the block has a rare one, and none of a next block with a rare one;
// and that nothing idles: when a block is in, something is given, and a next block in for
// some cycles is read.
//---------------------------------------------------------------------------
#include "VOOO_FBUF3.h"
#include "VOOO_FBUF3___024root.h"
#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>
#include <vector>

struct Ins { uint32_t bits; bool rvc; int off, ftq; bool taken, rare; uint64_t pc; };
struct Blk { std::vector<Ins> v; bool anyr = false; };

static VOOO_FBUF3 d;
static std::mt19937 rng(21);
static long bad = 0;
#define FAIL(...) do { if (bad++ < 12) { printf(__VA_ARGS__); printf("\n"); } } while (0)

static const int MEM = 1 << 12;
static uint16_t mem[MEM];
static bool is_taken[MEM];
static uint32_t target[MEM];

// a predecode of a rare class from its first parcel, apart from OOO_RARE
static bool rare_of(uint16_t p) {
    if ((p & 3) == 3) {
        int op = (p >> 2) & 31;
        return op == 0x01 || op == 0x09 || (op >= 0x10 && op <= 0x14) || op == 0x0b || op == 0x03 || op == 0x1c;
    }
    int q = p & 3, f3 = (p >> 13) & 7;
    return ((q == 0 || q == 2) && (f3 == 1 || f3 == 5)) || p == 0x9002;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    for (int i = 0; i < MEM; i++) {
        uint16_t x = (uint16_t)rng();
        // mostly not rare: the low bits of a 32-bit opcode from what is common
        if (rng() % 4 == 0) {
            static const int ops[] = {0x03, 0x13, 0x23, 0x33, 0x63, 0x67, 0x6f, 0x37, 0x1b, 0x3b};
            x = (uint16_t)((x & 0xff80) | ops[rng() % 10]);
        } else {
            if ((x & 3) == 3) x = (uint16_t)(x & ~3u) | (uint16_t)(rng() % 3);
            if (rng() % 8 != 0) { x &= ~(uint16_t)(1u << 13); }   // few c.fld and the like
        }
        if (rng() % 256 == 0) x = 0x0073;                 // an ecall now and then: rare
        mem[i] = x;
        is_taken[i] = rng() % 6 == 0;
        target[i] = rng() % MEM;
        if (rng() % 8 == 0) target[i] |= 15;              // the last parcel of a block
    }
    d.clk = 0; d.rst_n = 1; d.flush = 0; d.in_valid = 0; d.out_ready = 0;
    d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    uint64_t pc = 8;                    // in parcels
    bool first_half = false;            // a first half waits: pc is its second half
    uint16_t fh = 0; int fh_ftq = 0;
    std::deque<Blk> q;                  // blocks in, not all out
    int ftq = 0;
    uint64_t oldest = pc;
    long nin = 0, nout = 0, nblk = 0, ncross = 0, nrare = 0, nsix = 0, nflush = 0, ntk = 0, nonly = 0, nwait = 0, ntwo = 0, nboth = 0, nnr = 0, nrd = 0;

    for (long cyc = 0; cyc < 2000000; cyc++) {
        bool fl = rng() % 2048 == 0;
        // ---- a block, as fetch would give it
        bool push = !fl && rng() % 4 != 0 && (cyc >> 12 & 3) != 3;
        Blk b;
        uint32_t data[8] = {0};
        unsigned st = 0, first = 0;
        bool btk = false;
        uint64_t pc_n = pc;
        bool fh_n = first_half; uint16_t fhv_n = fh; int fhf_n = fh_ftq;
        {
            uint64_t a = pc;
            int k = (int)(a & 15);
            uint64_t base = a & ~15ull;
            for (int i = 0; i < 16; i++) data[i / 2] |= (uint32_t)mem[(base + i) % MEM] << (16 * (i & 1));
            bool stop = false;
            if (fh_n) {
                // the second half of an instruction begun in the last block, at parcel 0
                Ins x;
                x.bits = fhv_n | ((uint32_t)mem[a % MEM] << 16); x.rvc = false; x.off = 15; x.ftq = fhf_n;
                x.pc = a - 1; x.rare = rare_of(fhv_n);
                x.taken = is_taken[(a - 1) % MEM];
                b.v.push_back(x);
                fh_n = false;
                k++;
                if (x.taken) {
                    btk = true; stop = true; pc_n = target[(a - 1) % MEM]; first = 1u;
                    while (k < 16) { st |= 1u << k; k += (mem[(base + k) % MEM] & 3) == 3 ? 2 : 1; }
                }
            }
            while (!stop && k < 16) {
                uint16_t p = mem[(base + k) % MEM];
                bool len2 = (p & 3) == 3;
                uint64_t ia = base + k;
                st |= 1u << k;
                if (len2 && k == 15) {
                    fh_n = true; fhv_n = p; fhf_n = ftq;
                    pc_n = base + 16;
                    stop = true;
                    break;
                }
                Ins x;
                x.bits = len2 ? (uint32_t)p | ((uint32_t)mem[(ia + 1) % MEM] << 16) : p;
                x.rvc = !len2; x.off = k; x.ftq = ftq; x.pc = ia; x.rare = rare_of(p);
                x.taken = is_taken[ia % MEM];
                b.v.push_back(x);
                k += len2 ? 2 : 1;
                if (x.taken) {
                    btk = true; stop = true; pc_n = target[ia % MEM]; first = 1u << (k - 1);
                    // the predecode goes on past it, not knowing
                    while (k < 16) { st |= 1u << k; k += (mem[(base + k) % MEM] & 3) == 3 ? 2 : 1; }
                    break;
                }
            }
            if (!stop) pc_n = base + 16;
        }
        d.in_valid = push;
        for (int i = 0; i < 8; i++) d.in_data[i] = data[i];
        d.in_st = st;
        d.in_first = first;
        d.in_ftq = ftq;
        d.flush = fl;
        d.out_ready = rng() % 4 != 0;
        d.eval();

        // ---- the slots against the block being read
        int nv = 0;
        for (int j = 0; j < 6; j++) if ((d.out_valid >> j) & 1) nv++;
        if (d.out_valid != (unsigned)((1 << nv) - 1)) FAIL("cycle %ld: valid %02x not a prefix", cyc, d.out_valid);
        bool rd1 = (d.rootp->OOO_FBUF3__DOT__bv >> 1) & 1;
        if (q.empty()) {
            if (nv) FAIL("cycle %ld: %d given, none expected", cyc, nv);
        } else {
            Blk& h = q.front();
            Blk* s = q.size() > 1 ? &q[1] : nullptr;
            nrd = (s && !rd1) ? nrd + 1 : 0;
            if (nrd > 2) FAIL("cycle %ld: a next block in is not read", cyc);
            if (rd1 && !s) FAIL("cycle %ld: a next block read that is not there", cyc);
            bool cr = rd1 && s && !h.anyr && !s->anyr;
            if (rd1 && s && !h.anyr && s->anyr) nnr++;
            size_t have = h.v.size() + (cr ? s->v.size() : 0);
            int want = h.anyr ? 1 : (int)std::min<size_t>(have, 6);
            if (nv != want) FAIL("cycle %ld: %d given, expected %d (%zu left)", cyc, nv, want, have);
            for (int j = 0; j < nv && j < (int)have; j++) {
                bool sec = j >= (int)h.v.size();
                const Blk& b0 = sec ? *s : h;
                const Ins& x = b0.v[sec ? j - h.v.size() : j];
                bool last = sec ? (size_t)j - h.v.size() + 1 == s->v.size() : (size_t)j + 1 == h.v.size();
                uint32_t bits = d.out_inst[j];
                int off = (int)((d.out_off >> (4 * j)) & 15), f = (int)((d.out_ftq >> (5 * j)) & 31);
                if (bits != x.bits) FAIL("cycle %ld: slot %d pc %llx bits %08x, expected %08x", cyc, j, (unsigned long long)x.pc, bits, x.bits);
                if ((int)((d.out_rvc >> j) & 1) != (int)x.rvc) FAIL("cycle %ld: slot %d rvc", cyc, j);
                if (off != x.off) FAIL("cycle %ld: slot %d off %d, expected %d", cyc, j, off, x.off);
                if (f != x.ftq) FAIL("cycle %ld: slot %d ftq %d, expected %d", cyc, j, f, x.ftq);
                if ((int)((d.out_taken >> j) & 1) != (int)(x.taken && last)) FAIL("cycle %ld: slot %d taken", cyc, j);
            }
            if (nv && (bool)d.out_rare != h.v[0].rare) FAIL("cycle %ld: rare %d, expected %d", cyc, (int)d.out_rare, h.v[0].rare);
            if (nv == 6) nsix++;
            if (h.anyr) nrare++;
            if (nv > (int)h.v.size()) ntwo++;
            if (cr && (size_t)nv == have && d.out_ready) nboth++;
        }

        // ---- the edge
        bool accepted = push && d.in_ready;
        bool rdy = d.out_ready;
        d.clk = 1; d.eval(); d.clk = 0; d.eval();

        if (rdy && !q.empty() && nv) {
            for (int j = 0; j < nv && !q.empty(); j++) {
                Blk& h = q.front();
                oldest = h.v.front().pc; h.v.erase(h.v.begin()); nout++;
                if (h.v.empty()) { q.pop_front(); nrd = 0; }   // (one block comes a cycle: to cur, if that one is done)
            }
        }
        if (fl) {
            nflush++;
            q.clear();
            pc = rng() % MEM;
            first_half = false;
            ftq = (ftq + 1) & 31;
        } else if (accepted) {
            nblk++;
            nin += (long)b.v.size();
            if (!b.v.empty() && b.v[0].off == 15 && b.v[0].rvc == false && first_half) ncross++;
            if (b.v.empty()) nonly++;
            if (btk) ntk++;
            // (past a taken transfer too, which is not known in time: the block only goes slower)
            if (!b.v.empty() && b.v[0].off == 15 && b.v[0].rare) b.anyr = true;
            for (int k2 = 0; k2 < 16; k2++) {
                uint16_t pk = (uint16_t)(data[k2 / 2] >> (16 * (k2 & 1)));
                if ((st >> k2 & 1) && !(k2 == 15 && (pk & 3) == 3) && rare_of(pk)) b.anyr = true;
            }
            if (!b.v.empty()) q.push_back(b);
            pc = pc_n; first_half = fh_n; fh = fhv_n; fh_ftq = fhf_n;
            ftq = (ftq + 1) & 31;
        } else if (push) nwait++;
    }
    (void)oldest;
    bool cov = nblk > 100000 && nout > 500000 && ncross > 1000 && nrare > 1000 && nsix > 20000 && nflush > 300 && ntk > 50000 && nonly > 100 && nwait > 1000 && ntwo > 300000 && nboth > 5000 && nnr > 1000;
    printf("tb_fbuf3: %ld from 2 blocks, %ld both taken whole, %ld next with a rare one; %ld blocks in (%ld taken, %ld with only a first half), %ld instructions in, %ld out; %ld across 2 blocks, %ld cycles with 6, %ld with a rare block, %ld flushes, %ld pushes waited: %ld mismatches: %s\n",
           ntwo, nboth, nnr, nblk, ntk, nonly, nin, nout, ncross, nsix, nrare, nflush, nwait, bad, bad == 0 && cov ? "PASS" : "FAIL");
    return bad != 0 || !cov;
}
