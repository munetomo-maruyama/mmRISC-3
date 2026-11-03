//---------------------------------------------------------------------------
// tb_rename2.cpp : OOO_RENAME2 (80 registers, 4 µops a cycle, 12 checkpoints, 2 a
// cycle) against a reference of renaming written separately
//
// Every cycle: up to 4 random µops at R1, from a few architectural registers so
// that the dependences among them happen; S1 takes any slots of what is valid in
// R2, oldest first; commits in order, up to 4 a cycle, up to the oldest branch not
// resolved; now and then a misprediction, that restores a checkpoint and drops what
// is younger, or a flush_all, back to the committed state. What must hold:
//   - how many R1 takes: to the second checkpoint; that it moves when R2 will be
//     empty, the registers are not short, and no recovery is going on
//   - each source at R2 is the register the reference maps it to, as of its place
//     in the program; the old mapping the same
//   - a new register for each that writes, the next of a ring as the reference
//     keeps it, in no one else's hands
//   - the ids: a ring of 12, given in order, back to the restored one's own
// The reference keeps a map per checkpoint, taken at the µop itself; the RTL writes
// the checkpoint a cycle later and undoes what is younger in the group: a transfer
// is resolved the cycle after it left R2 at the earliest, and often right then.
// A look inside: adv.
//---------------------------------------------------------------------------
#include "VOOO_RENAME2.h"
#include "VOOO_RENAME2___024root.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>
#include <vector>

struct Uop {
    int src[2] = {0, 0}, wr = 0, dst = 0, ck = 0;
    int psrc[2] = {0, 0}, pdst = 0, pold = 0, id = -1;
    long left = -1;           // the cycle it left R2
    bool real() const { return wr && dst; }
};
struct Ck { int id, m[32], head; size_t pos; int undo; };

static VOOO_RENAME2 d;
static std::mt19937 rng(11);
static long bad = 0;
#define FAIL(...) do { if (bad++ < 12) { printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    d.clk = 0; d.rst_n = 1; d.in_valid = 0; d.disp_go = 0; d.cmt_wr = 0; d.restore = 0; d.flush_all = 0;
    d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    int map[32], amap[32];
    for (int a = 0; a < 32; a++) { map[a] = a; amap[a] = a; }
    int ring[64] = {0};
    for (int i = 0; i < 48; i++) ring[i] = 32 + i;
    int rhead = 0, rtail = 48, chead = 0;
    bool hands[80] = {false};
    for (int a = 0; a < 32; a++) hands[a] = true;
    std::deque<Uop> rob;                      // all that left R1 and are not committed, oldest first
    std::vector<Ck> cks;                      // open checkpoints, oldest first
    int next_id = 0, rest_wait = 0;
    bool free_ok = false;
    Uop r2[4]; bool r2v[4] = {false, false, false, false};
    size_t r2pos[4] = {0, 0, 0, 0};           // where in rob
    std::vector<Uop> rv;                      // what R1 offers, until it is taken
    int pend = 0;                             // taken at the last edge: to be looked at now
    long ntake = 0, ndep = 0, nundo = 0, nrest = 0, nearly = 0, nflush = 0, ncm = 0, n2ck = 0, npart = 0, nshort = 0, nwrap = 0;
    const std::vector<int> pool = {1, 2, 3, 5, 8, 13, 21, 31};

    auto rnd_uop = [&]() {
        Uop u;
        for (int s = 0; s < 2; s++) u.src[s] = rng() % 8 == 0 ? 0 : pool[rng() % pool.size()];
        u.wr  = rng() % 4 != 0;
        u.dst = rng() % 16 == 0 ? 0 : pool[rng() % pool.size()];
        u.ck  = rng() % 3 == 0;
        return u;
    };

    for (long cyc = 0; cyc < 800000; cyc++) {
        // ---- what moved at the last edge, in R2's registers now
        for (int k = 0; k < pend; k++) {
            Uop& u = r2[k];
            for (int s = 0; s < 2; s++) {
                u.psrc[s] = map[u.src[s]];
                for (int m = 0; m < k; m++) if (r2[m].real() && r2[m].dst == u.src[s]) ndep++;
            }
            u.pold = map[u.dst];
            if (u.real()) {
                u.pdst = ring[rhead & 63];
                rhead = (rhead + 1) & 63;
                if (hands[u.pdst]) FAIL("cycle %ld: p%d is given out twice", cyc, u.pdst);
                hands[u.pdst] = true;
                map[u.dst] = u.pdst;
            }
            if (u.ck) {
                u.id = next_id; next_id = (next_id + 1) % 12;
                Ck c; c.id = u.id; std::copy(map, map + 32, c.m); c.head = rhead; c.pos = rob.size();
                c.undo = 0;
                for (int m = k + 1; m < pend; m++) if (r2[m].real()) c.undo++;
                cks.push_back(c);
            }
            r2pos[k] = rob.size();
            rob.push_back(u);
        }
        if (pend >= 2) { int n = 0; for (int k = 0; k < pend; k++) n += r2[k].ck; if (n == 2) n2ck++; }
        pend = 0;
        int free_seen = (rtail - rhead) & 63;

        // ---- R2's outputs against the reference
        for (int k = 0; k < 4; k++) {
            bool v = (d.r2_valid >> k) & 1;
            if (v != r2v[k]) FAIL("cycle %ld: slot %d valid %d, expected %d", cyc, k, v, r2v[k]);
            if (!v || !r2v[k]) continue;
            Uop& u = r2[k];
            for (int s = 0; s < 2; s++) {
                int p = (int)((d.r2_src >> ((k * 2 + s) * 7)) & 127);
                if (p != u.psrc[s]) FAIL("cycle %ld: slot %d source %d (x%d) is p%d, expected p%d", cyc, k, s, u.src[s], p, u.psrc[s]);
            }
            if ((int)((d.r2_wr >> k) & 1) != (int)u.real()) FAIL("cycle %ld: slot %d wr", cyc, k);
            int nd = (int)((d.r2_dst >> (7 * k)) & 127), no = (int)((d.r2_old >> (7 * k)) & 127);
            if (u.real() && nd != u.pdst) FAIL("cycle %ld: slot %d new p%d, expected p%d", cyc, k, nd, u.pdst);
            if (no != u.pold) FAIL("cycle %ld: slot %d old p%d, expected p%d", cyc, k, no, u.pold);
            if ((int)((d.r2_ck >> k) & 1) != u.ck) FAIL("cycle %ld: slot %d ck", cyc, k);
            if (u.ck && (int)((d.r2_ckid >> (4 * k)) & 15) != u.id) FAIL("cycle %ld: slot %d id %d, expected %d", cyc, k, (int)((d.r2_ckid >> (4 * k)) & 15), u.id);
        }

        // ---- R1: the phases: 0, 2 full, 1 without commits (the registers run short), 3 little
        int phase = (cyc >> 11) & 3;
        int nv = phase == 3 ? rng() % 2 : rng() % 5;
        if (cks.size() >= 10 || rob.size() >= 64) nv = 0;     // OOO_CTRL's and the ROB's limits
        while ((int)rv.size() < nv) rv.push_back(rnd_uop());
        int offer = std::min(nv == 0 ? 0 : (int)rv.size(), 4);
        unsigned iv = 0, iw = 0, ik = 0, id = 0;
        uint64_t is = 0;
        for (int k = 0; k < 4; k++) {
            Uop u = k < offer ? rv[k] : rnd_uop();
            iv |= (unsigned)(k < offer) << k; iw |= (unsigned)u.wr << k; ik |= (unsigned)u.ck << k;
            id |= (unsigned)u.dst << (5 * k);
            is |= ((uint64_t)u.src[0] | ((uint64_t)u.src[1] << 5)) << (10 * k);
        }
        d.in_valid = iv; d.in_wr = iw; d.in_ckpt = ik; d.in_dst = id; d.in_src = is;

        // ---- recoveries
        bool rest = false, flush = false;
        int ri = -1;
        if (rest_wait == 0) {
            if (rng() % 1024 == 0) flush = true;
            else if (rng() % 12 == 0) {
                // the youngest that may be: its µop left R2 by the last edge
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
        if (!rest && !flush && !cks.empty() && rob[cks[0].pos].left >= 0 && rng() % 3 == 0) {
            cks.erase(cks.begin());
        }

        // ---- commits
        unsigned cw = 0; uint64_t ca = 0, cn = 0, co = 0;
        if (!flush && phase != 1) {
            int nc = rng() % 5, slot = 0;
            size_t lim = cks.empty() ? rob.size() : cks[0].pos;
            while (nc-- > 0 && lim > 0 && !rob.empty() && rob.front().left >= 0 && rob.front().left < cyc) {
                Uop u = rob.front(); rob.pop_front(); lim--;
                for (auto& c : cks) c.pos--;
                for (int k = 0; k < 4; k++) if (r2v[k]) r2pos[k]--;
                if (u.real()) {
                    cw |= 1u << slot;
                    ca |= (uint64_t)u.dst << (5 * slot);
                    cn |= (uint64_t)u.pdst << (7 * slot);
                    co |= (uint64_t)u.pold << (7 * slot);
                    amap[u.dst] = u.pdst;
                    ring[rtail & 63] = u.pold;
                    rtail = (rtail + 1) & 63;
                    chead = (chead + 1) & 63;
                    hands[u.pold] = false;
                    ncm++;
                }
                slot++;                       // (a µop that writes nothing leaves its slot empty)
            }
        }
        d.cmt_wr = cw; d.cmt_arch = (uint32_t)ca; d.cmt_new = cn; d.cmt_old = co;

        // ---- S1: oldest first, a few at a time
        unsigned go = 0;
        if (!rest && !flush) {
            bool ok = true;
            for (int k = 0; k < 4; k++) if (r2v[k]) {
                ok = ok && rng() % 6 != 0;
                if (ok) go |= 1u << k;
                else npart++;
            }
        }
        d.disp_go = go;
        d.eval();

        // ---- how far it goes, and whether it moves
        int want = 0, nck = 0;
        for (int k = 0; k < offer && nck < 2; k++) { want++; nck += rv[k].ck; }
        if ((int)d.in_take != want) FAIL("cycle %ld: in_take %d, expected %d", cyc, (int)d.in_take, want);
        bool left_all = true;
        for (int k = 0; k < 4; k++) if (r2v[k] && !((go >> k) & 1)) left_all = false;
        bool adv = left_all && free_ok && rest_wait == 0 && !rest && !flush;
        bool adv_d = d.rootp->OOO_RENAME2__DOT__adv;
        if (adv != adv_d && cyc > 2) FAIL("cycle %ld: adv %d, expected %d (free_ok %d, free %d)", cyc, adv_d, adv, free_ok, (rtail - rhead) & 63);
        if (left_all && !free_ok && !rest && !flush && rest_wait == 0 && cyc > 20) nshort++;

        // ---- the edge
        d.clk = 1; d.eval(); d.clk = 0; d.eval();

        free_ok = cyc >= 12 && free_seen >= 8;   // (as the block looks at them: before this edge's)
        if (((rtail - rhead) & 63) < 4) nwrap++;
        for (int k = 0; k < 4; k++) if (r2v[k] && ((go >> k) & 1)) { rob[r2pos[k]].left = cyc; r2v[k] = false; }
        if (flush) {
            nflush++;
            for (int a = 0; a < 32; a++) map[a] = amap[a];
            for (auto& u : rob) if (u.real()) hands[u.pdst] = false;
            rob.clear(); cks.clear(); rv.clear();
            rhead = chead;
            for (int k = 0; k < 4; k++) r2v[k] = false;
        } else if (rest) {
            nrest++;
            Ck c = cks[ri];
            if (rob[c.pos].left == cyc - 1) nearly++;
            if (c.undo) nundo++;
            std::copy(c.m, c.m + 32, map);
            while (rob.size() > c.pos + 1) {
                if (rob.back().real()) hands[rob.back().pdst] = false;
                rob.pop_back();
            }
            rhead = c.head;
            cks.resize(ri);
            next_id = c.id;
            rv.clear();
            for (int k = 0; k < 4; k++) r2v[k] = false;
            rest_wait = 1;
        } else if (rest_wait) {
            rest_wait--;
        }
        if (adv) {
            ntake += want;
            for (int k = 0; k < want; k++) { r2[k] = rv[k]; r2v[k] = true; }
            rv.erase(rv.begin(), rv.begin() + want);
            pend = want;
        }
    }
    bool cov = ntake > 100000 && ndep > 50000 && nundo > 1000 && nrest > 5000 && nearly > 500 && nflush > 100 && ncm > 50000 && n2ck > 5000 &&
               npart > 10000 && nshort > 1000;
    printf("tb_rename2: %ld µops taken, %ld sources inside a group, %ld groups with 2 checkpoints; %ld restores (%ld with undoes, %ld at the earliest), %ld flushes; %ld commits that write; %ld cycles short of registers; %ld slots held in R2: %ld mismatches: %s\n",
           ntake, ndep, n2ck, nrest, nundo, nearly, nflush, ncm, nshort, npart, bad, bad == 0 && cov ? "PASS" : "FAIL");
    return bad != 0 || !cov;
}
