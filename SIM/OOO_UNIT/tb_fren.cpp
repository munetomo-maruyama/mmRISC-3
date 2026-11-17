//---------------------------------------------------------------------------
// tb_fren.cpp : OOO_FREN (the FP registers' renaming, step 1.8 U1: 64
// registers, 4 µops a cycle with 3 sources each, 12 checkpoints, 2 a group)
// against a reference of renaming written separately (tb_rename2's)
//
// Every cycle: up to 4 random µops at R1, from a few FP registers (f0 among
// them: it is a register like any other) so that the dependences among them
// happen; the group moves when the bench lets it (adv: OOO_RENAME2's r1_adv
// in the core), which it does only when the block is ready and no recovery is
// going on, and not always then; the checkpoint ids from the bench's ring
// (OOO_RENAME2's r1_ckid in the core); commits in order, up to 4 a cycle, up
// to the oldest branch not resolved; now and then a misprediction, that
// restores a checkpoint and drops what is younger, or a flush_all. What must
// hold:
//   - ready: the init over and at least 4 registers free now (8 in the last cycle until step 1.8 U2b)
//   - each of the 3 sources at R2 is the register the reference maps it to, as
//     of its place in the program; the old mapping the same
//   - a new register for each that writes, the next of a ring as the
//     reference keeps it, in no one else's hands; r1_wr / r1_tag what R2 shows
//     after the edge
// The reference keeps a map per checkpoint, taken at the µop itself; the RTL
// writes the checkpoint a cycle later and undoes what is younger in the group.
//---------------------------------------------------------------------------
#include "VOOO_FREN.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>
#include <vector>

struct Uop {
    int src[3] = {0, 0, 0}, wr = 0, dst = 0, ck = 0;
    int psrc[3] = {0, 0, 0}, pdst = 0, pold = 0, id = -1;
    long left = -1;           // the cycle it was in R2 (S1 takes it then, in the core)
};
struct Ck { int id, m[32], head; size_t pos; int undo; };

static VOOO_FREN d;
static std::mt19937 rng(23);
static long bad = 0;
// the configuration (run.sh: fren at 64 registers, fren80 the core's since step 1.8 U2b)
#ifndef FR_NREG
#define FR_NREG 64
#endif
#ifndef FR_TW
#define FR_TW 6
#endif
#define FR_TM ((1 << FR_TW) - 1)
#define FR_IN ((FR_NREG - 32) / 4)       // the init's cycles
#define FAIL(...) do { if (bad++ < 12) { printf(__VA_ARGS__); printf("\n"); } } while (0)

static unsigned bits(const uint32_t* w, int lo, int n)
{
    unsigned v = 0;
    for (int i = 0; i < n; i++) v |= ((w[(lo + i) >> 5] >> ((lo + i) & 31)) & 1u) << i;
    return v;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    d.clk = 0; d.rst_n = 1; d.in_valid = 0; d.adv = 0; d.cmt_wr = 0; d.restore = 0; d.flush_all = 0;
    d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    int map[32], amap[32];
    for (int a = 0; a < 32; a++) { map[a] = a; amap[a] = a; }
    int ring[64] = {0};
    for (int i = 0; i < FR_NREG - 32; i++) ring[i] = 32 + i;
    int rhead = 0, rtail = FR_NREG - 32, chead = 0;
    bool hands[FR_NREG] = {false};
    for (int a = 0; a < 32; a++) hands[a] = true;
    std::deque<Uop> rob;
    std::vector<Ck> cks;
    int next_id = 0, rest_wait = 0;
    Uop r2[4]; bool r2v = false;
    std::vector<Uop> rv;
    int pend = 0;
    long ntake = 0, ndep = 0, ndep3 = 0, nundo = 0, nrest = 0, nearly = 0, nflush = 0, ncm = 0, n2ck = 0, nhold = 0, nshort = 0, nf0 = 0;
    const std::vector<int> pool = {0, 1, 2, 3, 5, 8, 13, 31};

    auto rnd_uop = [&]() {
        Uop u;
        for (int s = 0; s < 3; s++) u.src[s] = pool[rng() % pool.size()];
        u.wr  = rng() % 4 != 0;
        u.dst = pool[rng() % pool.size()];
        u.ck  = rng() % 3 == 0;
        return u;
    };

    for (long cyc = 0; cyc < 800000; cyc++) {
        // ---- what moved at the last edge, in R2's registers now
        for (int k = 0; k < pend; k++) {
            Uop& u = r2[k];
            for (int s = 0; s < 3; s++) {
                u.psrc[s] = map[u.src[s]];
                for (int m = 0; m < k; m++) if (r2[m].wr && r2[m].dst == u.src[s]) { ndep++; if (s == 2) ndep3++; }
            }
            u.pold = map[u.dst];
            if (u.wr) {
                u.pdst = ring[rhead & 63];
                rhead = (rhead + 1) & 63;
                if (hands[u.pdst]) FAIL("cycle %ld: p%d is given out twice", cyc, u.pdst);
                hands[u.pdst] = true;
                map[u.dst] = u.pdst;
                if (u.dst == 0) nf0++;
            }
            if (u.ck) {
                Ck c; c.id = u.id; std::copy(map, map + 32, c.m); c.head = rhead; c.pos = rob.size();
                c.undo = 0;
                for (int m = k + 1; m < pend; m++) if (r2[m].wr) c.undo++;
                cks.push_back(c);
            }
            u.left = cyc;
            rob.push_back(u);
        }
        if (pend >= 2) { int n = 0; for (int k = 0; k < pend; k++) n += r2[k].ck; if (n == 2) n2ck++; }
        bool fresh = pend > 0;
        int npend = pend;
        pend = 0;
        int free_seen = (rtail - rhead) & 63;

        // ---- R2's outputs against the reference (held until the next move)
        if (r2v) {
            for (int k = 0; k < npend && fresh; k++) {
                Uop& u = r2[k];
                for (int s = 0; s < 3; s++) {
                    int p = (int)bits(d.r2_src.data(), (k * 3 + s) * FR_TW, FR_TW);
                    if (p != u.psrc[s]) FAIL("cycle %ld: slot %d source %d (f%d) is p%d, expected p%d", cyc, k, s, u.src[s], p, u.psrc[s]);
                }
                if ((int)((d.r2_wr >> k) & 1) != u.wr) FAIL("cycle %ld: slot %d wr", cyc, k);
                int nd = (int)((d.r2_dst >> (FR_TW * k)) & FR_TM), no = (int)((d.r2_old >> (FR_TW * k)) & FR_TM);
                if (u.wr && nd != u.pdst) FAIL("cycle %ld: slot %d new p%d, expected p%d", cyc, k, nd, u.pdst);
                if (no != u.pold) FAIL("cycle %ld: slot %d old p%d, expected p%d", cyc, k, no, u.pold);
            }
        }

        // ---- R1: the phases: 0, 2 full, 1 without commits (the registers run short), 3 little
        int phase = (cyc >> 11) & 3;
        int nv = phase == 3 ? rng() % 2 : rng() % 5;
        if (cks.size() >= 10 || rob.size() >= 64) nv = 0;
        while ((int)rv.size() < nv) rv.push_back(rnd_uop());
        int offer = std::min(nv == 0 ? 0 : (int)rv.size(), 4);
        unsigned iv = 0, iw = 0, ik = 0, id = 0, ckid = 0;
        uint64_t is = 0;
        int c = next_id;
        for (int k = 0; k < 4; k++) {
            Uop u = k < offer ? rv[k] : rnd_uop();
            iv |= (unsigned)(k < offer) << k; iw |= (unsigned)u.wr << k; ik |= (unsigned)u.ck << k;
            id |= (unsigned)u.dst << (5 * k);
            is |= ((uint64_t)u.src[0] | ((uint64_t)u.src[1] << 5) | ((uint64_t)u.src[2] << 10)) << (15 * k);
            ckid |= (unsigned)c << (4 * k);
            if (k < offer) rv[k].id = u.ck ? c : -1;
            if (u.ck) c = (c + 1) % 12;
        }
        d.in_valid = iv; d.in_wr = iw; d.in_ckpt = ik; d.in_dst = id; d.in_src = is; d.in_ckid = ckid;

        // ---- recoveries
        bool rest = false, flush = false;
        int ri = -1;
        if (rest_wait == 0) {
            if (rng() % 1024 == 0) flush = true;
            else if (rng() % 12 == 0) {
                std::vector<int> ok;
                for (size_t i = 0; i < cks.size(); i++) {
                    long l = rob[cks[i].pos].left;
                    if (l >= 0 && l + 1 <= cyc) ok.push_back((int)i);
                }
                if (!ok.empty()) { ri = rng() % 2 ? ok.back() : ok[rng() % ok.size()]; rest = true; }
            }
        }
        d.restore = rest; d.flush_all = flush;
        d.restore_id = rest ? cks[ri].id : rng() % 12;

        // ---- branches resolved, oldest first
        if (!rest && !flush && !cks.empty() && rob[cks[0].pos].left >= 0 && rng() % 3 == 0) cks.erase(cks.begin());

        // ---- commits
        unsigned cw = 0, ca = 0, cn = 0, co = 0;
        if (!flush && phase != 1) {
            int nc = rng() % 5, slot = 0;
            size_t lim = cks.empty() ? rob.size() : cks[0].pos;
            while (nc-- > 0 && lim > 0 && !rob.empty() && rob.front().left >= 0 && rob.front().left < cyc) {
                Uop u = rob.front(); rob.pop_front(); lim--;
                for (auto& ck : cks) ck.pos--;
                if (u.wr) {
                    cw |= 1u << slot;
                    ca |= (unsigned)u.dst << (5 * slot);
                    cn |= (unsigned)u.pdst << (FR_TW * slot);
                    co |= (unsigned)u.pold << (FR_TW * slot);
                    amap[u.dst] = u.pdst;
                    ring[rtail & 63] = u.pold;
                    rtail = (rtail + 1) & 63;
                    chead = (chead + 1) & 63;
                    hands[u.pold] = false;
                    ncm++;
                }
                slot++;
            }
        }
        d.cmt_wr = cw; d.cmt_arch = ca; d.cmt_new = cn; d.cmt_old = co;
        d.eval();

        // ---- ready, and whether the group moves (the bench's choice, as OOO_RENAME2's in the core)
        bool rdy = free_seen >= 4 && cyc > FR_IN + 1;      // (4 free now: step 1.8 U2b)
        if ((bool)d.ready != rdy && cyc > FR_IN + 4) FAIL("cycle %ld: ready %d, expected %d (free %d)", cyc, (int)d.ready, rdy, free_seen);
        int want = 0, nck = 0;
        for (int k = 0; k < offer && nck < 2; k++) { want++; nck += rv[k].ck; }
        bool may = rdy && rest_wait == 0 && !rest && !flush && cyc > FR_IN + 4;
        bool adv = may && rng() % 5 != 0;
        if (may && !adv) nhold++;
        if (!rdy && cyc > FR_IN + 12 && rest_wait == 0) nshort++;
        d.adv = adv;
        d.eval();

        // ---- the edge
        {
            unsigned rw = d.r1_wr; uint32_t rt = d.r1_tag;
            if (!adv && rw) FAIL("cycle %ld: a register set though the group stays", cyc);
            d.clk = 1; d.eval(); d.clk = 0; d.eval();
            if (adv) {
                if (d.r2_wr != rw) FAIL("cycle %ld: r1_wr %x, then r2_wr %x", cyc, rw, (unsigned)d.r2_wr);
                for (int k = 0; k < 4; k++) if (((rw >> k) & 1) && ((rt >> (FR_TW * k)) & FR_TM) != ((d.r2_dst >> (FR_TW * k)) & FR_TM))
                    FAIL("cycle %ld: r1_tag %d, then r2_dst differs", cyc, k);
            }
        }

        if (flush) {
            nflush++;
            for (int a = 0; a < 32; a++) map[a] = amap[a];
            for (auto& u : rob) if (u.wr) hands[u.pdst] = false;
            rob.clear(); cks.clear(); rv.clear();
            rhead = chead;
            r2v = false;
        } else if (rest) {
            nrest++;
            Ck ck = cks[ri];
            if (rob[ck.pos].left == cyc - 1) nearly++;
            if (ck.undo) nundo++;
            std::copy(ck.m, ck.m + 32, map);
            while (rob.size() > ck.pos + 1) {
                if (rob.back().wr) hands[rob.back().pdst] = false;
                rob.pop_back();
            }
            rhead = ck.head;
            cks.resize(ri);
            next_id = ck.id;
            rv.clear();
            r2v = false;
            rest_wait = 1;
        } else if (rest_wait) {
            rest_wait--;
        }
        if (adv) {
            ntake += want;
            for (int k = 0; k < want; k++) { r2[k] = rv[k]; if (rv[k].ck) next_id = (rv[k].id + 1) % 12; }
            rv.erase(rv.begin(), rv.begin() + want);
            pend = want;
            r2v = true;
        }
    }
    bool cov = ntake > 100000 && ndep > 50000 && ndep3 > 10000 && nundo > 1000 && nrest > 5000 && nearly > 500 && nflush > 100 &&
               ncm > 50000 && n2ck > 5000 && nhold > 10000 && nshort > 1000 && nf0 > 10000;
    printf("tb_fren (%d registers): %ld µops taken, %ld sources inside a group (%ld of them rs3), %ld writes of f0, %ld groups with 2 checkpoints; %ld restores (%ld with undoes, %ld at the earliest), %ld flushes; %ld commits that write; %ld cycles short of registers; %ld groups held: %ld mismatches: %s\n",
           FR_NREG, ntake, ndep, ndep3, nf0, n2ck, nrest, nundo, nearly, nflush, ncm, nshort, nhold, bad, bad == 0 && cov ? "PASS" : "FAIL");
    return bad != 0 || !cov;
}
