//---------------------------------------------------------------------------
// tb_rename.cpp : OOO_RENAME (64 registers, 2 sources and 1 destination per
// µop, 6 checkpoints in a ring of 6) against a reference of renaming written separately
//
// Every cycle: 2 random µops (sources and destinations from a small set of
// registers, so that the in-group cases happen), some with a checkpoint;
// wakeups of registers given out (6 buses, which clear the busy bits: the
// issue queue's wakeup tags); commits in order that give
// the old mappings back (up to 2 a cycle); now and then a misprediction
// that restores a pending checkpoint and drops the µops younger than it.
// The outputs (ready, physical sources, ready bits, new and old
// destinations, checkpoint numbers) are compared every cycle.
//
// Commits also update the committed-state RAT and head (a µop commits only
// after its wakeup, as in the core), and now and then a
// flush_all goes back to them (RAT, free-list head, busy bits all clear).
//
// The reference takes a checkpoint at once, as the RAT right after its µop;
// the RTL copies the RAT a cycle late and undoes µop 1 on a restore. A
// transfer is resolved 2 cycles after its rename at the earliest, as in the
// pipeline (OOO_RENAME.sv), and most often right then, so that the late
// copy is used as soon as it may be.
//---------------------------------------------------------------------------
#include "VOOO_RENAME.h"
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <deque>
#include <random>
#include <vector>

static const int NCK = 6;            // checkpoints (OOO_RENAME NCKPT)

struct Ref {
    int rat[32];
    int fl[32];
    long head = 0, tail = 32;
    bool busy[64] = {false};
    struct Ck { int rat[32]; long head; };
    Ck ck[NCK];
    int ck_next = 0;
    int arat[32]; long chead = 0;       // the committed state
    Ref() { for (int a = 0; a < 32; a++) rat[a] = arat[a] = a; for (int f = 0; f < 32; f++) fl[f] = 32 + f; }
    long nfree() const { return tail - head; }
};

struct Uop { int old; bool wr; int ck; bool has_ck; int arch; int nt; };
struct Pend { int id; long cyc; };   // a checkpoint and the cycle of its rename

static std::mt19937 rng(11);
static VOOO_RENAME d;

static void tick() { d.clk = 1; d.eval(); d.clk = 0; d.eval(); }

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("RENAME_SEED")) rng.seed((unsigned)strtoul(e, nullptr, 0));
    Ref R;
    // rst_n starts at 0 in Verilator: raise it first so that the fall is an edge
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    std::deque<Uop> inflight;          // renamed, not committed, oldest first
    std::vector<Pend> pending_ck;      // checkpoints of unresolved transfers, oldest first
    std::vector<int> given;            // registers given out (for write-backs)
    long bad = 0, cyc = 0, renamed = 0, restores = 0, early = 0, nflush = 0, nfull = 0;
    for (cyc = 0; cyc < 400000; cyc++) {
        // ---- inputs
        int valid = 0, use[2][2], src[2][2], wr[2], dst[2], ckp[2];
        for (int u = 0; u < 2; u++) {
            if (rng() % 5) valid |= 1 << u;
            for (int s = 0; s < 2; s++) { use[u][s] = rng() % 3 != 0; src[u][s] = rng() % 8; }
            wr[u] = rng() % 4 != 0; dst[u] = rng() % 8;
            // at most NCK unresolved, as the pipeline keeps them (the ring is full then)
            ckp[u] = (rng() % 3 == 0) && pending_ck.size() + (u ? ckp[0] : 0) < NCK;
            if (ckp[u] && pending_ck.size() + (u ? ckp[0] : 0) == NCK - 1) nfull++;
        }
        // wakeups: up to 6 registers given out
        int wbv = 0; uint64_t wbt = 0;
        for (int w = 0; w < 6; w++)
            if (!given.empty() && rng() % 3 == 0) {
                int k = rng() % given.size();
                wbv |= 1 << w; wbt |= (uint64_t)given[k] << (6 * w);
                given.erase(given.begin() + k);
            }
        // commits: up to the 2 oldest µops (written back first); now and then
        // a flush_all instead
        int frv = 0, nfr = 0; uint32_t frt = 0;
        int cv = 0, cw = 0; uint32_t carch = 0, cnew = 0; int ncm = 0;
        std::vector<Uop> cm;
        int flush_all = rng() % 400 == 0;
        while (!flush_all && !inflight.empty() && ncm < 2 && rng() % 3) {
            Uop& o = inflight.front();
            if (o.has_ck && !pending_ck.empty() && pending_ck.front().id == o.ck) break;  // resolve first
            if (o.wr && std::find(given.begin(), given.end(), o.nt) != given.end()) break;  // not written back yet
            if (o.wr) { frv |= 1 << nfr; frt |= (uint32_t)o.old << (6 * nfr); nfr++; }
            cv |= 1 << ncm; cw |= (o.wr ? 1 : 0) << ncm; carch |= (uint32_t)o.arch << (5 * ncm); cnew |= (uint32_t)o.nt << (6 * ncm);
            cm.push_back(o); ncm++;
            inflight.pop_front();
        }
        // resolve the oldest pending transfer, 2 cycles after its rename at
        // the earliest: right (drop the checkpoint) or wrong (restore)
        int restore = 0, rid = 0;
        if (!flush_all && !pending_ck.empty() && cyc >= pending_ck.front().cyc + 2 &&
            (cyc == pending_ck.front().cyc + 2 ? rng() % 2 == 0 : rng() % 4 == 0)) {
            int id = pending_ck.front().id;
            if (cyc == pending_ck.front().cyc + 2) early++;
            if (rng() % 3 == 0) {
                restore = 1; rid = id; restores++;
                // drop the µops younger than the transfer
                while (!inflight.empty() && !(inflight.back().has_ck && inflight.back().ck == id)) inflight.pop_back();
                pending_ck.clear();
            } else {
                pending_ck.erase(pending_ck.begin());
            }
            for (auto& o : inflight) if (o.has_ck && o.ck == id) o.has_ck = false;
        }
        // drive
        d.in_valid = valid; d.restore = restore; d.restore_id = rid;
        uint32_t iu = 0, is = 0, iw = 0, id = 0, ic = 0;
        for (int u = 0; u < 2; u++) {
            for (int s = 0; s < 2; s++) { iu |= use[u][s] << (u * 2 + s); is |= src[u][s] << (5 * (u * 2 + s)); }
            iw |= wr[u] << u; id |= dst[u] << (5 * u);
            ic |= ckp[u] << u;
        }
        d.in_use = iu; d.in_src = is; d.in_wr = iw; d.in_dst = id; d.in_ckpt = ic;
        d.wk_valid = wbv; d.wk_tag = wbt; d.free_valid = frv; d.free_tag = frt;
        d.cmt_valid = cv; d.cmt_wr = cw; d.cmt_arch = carch; d.cmt_new = cnew; d.flush_all = flush_all;
        d.eval();

        // ---- the reference: outputs from the state before the clock
        int alloc[2], nt[2];
        for (int u = 0; u < 2; u++) alloc[u] = ((valid >> u) & 1) && wr[u] && dst[u] != 0;
        int need = alloc[0] + alloc[1];
        nt[0] = alloc[0] ? R.fl[R.head % 32] : 0;
        nt[1] = alloc[1] ? R.fl[(R.head + alloc[0]) % 32] : 0;
        bool ready = R.nfree() >= need && !restore && !flush_all;
        bool ok = (bool)d.ready == ready;
        char why[200] = "ready";
        if (ready && valid) {
            for (int u = 0; u < 2; u++) {
                if (!((valid >> u) & 1)) continue;
                for (int s = 0; s < 2; s++) {
                    int p = R.rat[src[u][s]];
                    bool r = !use[u][s] || src[u][s] == 0 || !R.busy[p];
                    if (u == 1 && alloc[0] && dst[0] == src[1][s]) { p = nt[0]; r = false; }
                    int gp = (int)((d.out_src >> (6 * (u * 2 + s))) & 0x3f);
                    int gr = (d.out_rdy >> (u * 2 + s)) & 1;
                    if (use[u][s] && (gp != p || gr != r)) { ok = false; snprintf(why, sizeof why, "u%d src%d (x%d): p%d/%d ready %d/%d", u, s, src[u][s], gp, p, gr, r); }
                }
                if (alloc[u]) {
                    int old = R.rat[dst[u]];
                    if (u == 1 && alloc[0] && dst[0] == dst[1]) old = nt[0];
                    int gd = (int)((d.out_dst >> (6 * u)) & 0x3f);
                    int go = (int)((d.out_old >> (6 * u)) & 0x3f);
                    if (gd != nt[u] || go != old) { ok = false; snprintf(why, sizeof why, "u%d dst (x%d): new p%d/%d old p%d/%d", u, dst[u], gd, nt[u], go, old); }
                }
                int gck = (d.out_ckpt_id >> (3 * u)) & 7;
                int eck = (R.ck_next + (u == 1 && (valid & 1) && ckp[0])) % NCK;
                if (ckp[u] && gck != eck) { ok = false; snprintf(why, sizeof why, "u%d ckpt %d/%d", u, gck, eck); }
            }
        }
        if (!ok && bad++ < 10) printf("MISMATCH at cycle %ld: %s (rtl/ref)\n", cyc, why);

        // ---- the reference: the state after the clock
        for (int w = 0; w < 6; w++) if ((wbv >> w) & 1) R.busy[(wbt >> (6 * w)) & 0x3f] = false;
        for (int k = 0; k < nfr; k++) { R.fl[R.tail % 32] = (int)((frt >> (6 * k)) & 0x3f); R.tail++; }
        for (auto& o : cm) if (o.wr) { R.arat[o.arch] = o.nt; R.chead++; }
        if (flush_all) {
            for (int a = 0; a < 32; a++) R.rat[a] = R.arat[a];
            R.head = R.chead;
            for (int t = 0; t < 64; t++) R.busy[t] = false;
            inflight.clear(); pending_ck.clear(); given.clear();
            nflush++;
        } else if (restore) {
            for (int a = 0; a < 32; a++) R.rat[a] = R.ck[rid].rat[a];
            R.head = R.ck[rid].head;
            R.ck_next = (rid + 1) % NCK;
        } else if (ready && valid) {
            int cknext = R.ck_next;
            for (int u = 0; u < 2; u++) {
                if (!((valid >> u) & 1)) continue;
                Uop o; o.has_ck = false; o.ck = 0;
                o.wr = alloc[u]; o.arch = dst[u]; o.nt = nt[u];
                o.old = R.rat[dst[u]];
                if (alloc[u]) { R.rat[dst[u]] = nt[u]; R.busy[nt[u]] = true; given.push_back(nt[u]); }
                if (ckp[u]) {
                    int idc = cknext % NCK; cknext++;
                    for (int a = 0; a < 32; a++) R.ck[idc].rat[a] = R.rat[a];
                    R.ck[idc].head = R.head + (u == 0 ? alloc[0] : need);
                    o.has_ck = true; o.ck = idc;
                    pending_ck.push_back(Pend{idc, cyc});
                }
                inflight.push_back(o);
                renamed++;
            }
            R.head += need;
            R.ck_next = cknext % NCK;
        }
        tick();
    }
    printf("tb_rename: %ld cycles, %ld µops renamed, %ld restores, %ld resolved at the earliest, %ld flushes, %ld checkpoints filling the ring, %ld mismatches: %s\n",
           cyc, renamed, restores, early, nflush, nfull, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
