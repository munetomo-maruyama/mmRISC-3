//---------------------------------------------------------------------------
// tb_rob.cpp : OOO_ROB (24 entries, 4 completion ports) against a reference
// reorder buffer
//
// Every cycle: up to 2 random µops dispatched (ALU, possibly fused, load,
// store, branch, non-speculative, or one with an exception known at decode)
// while there is room; completions on the 4 ports in any order after a
// random delay (now and then with an exception), a non-speculative µop only
// after head_ns has named it; branches resolved with their completion on
// the ALU ports (2 a cycle), some mispredicted; now and then a completion
// or a resolution for an index that is not in the ROB (must be ignored).
// Sometimes µops are offered in a cycle of trap or restore (must not go in).
//
// Checked every cycle: rob_avail and the indices given at dispatch, the
// head and head_ns, the trap (cause, pc), every commit (pc, destination,
// new and old registers) and the load / store / instret counts, and that a
// restore names the oldest mispredicted branch in the ROB with its
// checkpoint.
//---------------------------------------------------------------------------
#include "VOOO_ROB.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <vector>

static const int NROB = 24;
struct E {
    int idx; uint64_t pc; int wr, arch, nw, old, ld, st, fused, ns, br, ckpt;
    bool done = false, exc = false; int cause = 0;
    long ready_at = 0; bool ns_go = false;
};

static std::mt19937_64 rng(77);
static VOOO_ROB d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

template <class W> static void setw(W& w, int lo, int n, uint64_t v) {
    for (int b = 0; b < n; b++) { int i = lo + b; uint32_t m = 1u << (i % 32); if ((v >> b) & 1) w[i / 32] |= m; else w[i / 32] &= ~m; }
}
template <class W> static uint64_t getw(const W& w, int lo, int n) {
    uint64_t v = 0; for (int b = 0; b < n; b++) { int i = lo + b; v |= (uint64_t)((w[i / 32] >> (i % 32)) & 1) << b; } return v;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("ROB_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    std::deque<E> rob;
    int tail_idx = 0;                          // the index the next entry gets
    long ncommit = 0, ntrap = 0, nrestore = 0, ninstret = 0, n2restore = 0;
    for (cyc = 0; cyc < 400000; cyc++) {
        // ---------- the reference before the clock
        bool trap = !rob.empty() && rob[0].done && rob[0].exc;
        bool c0 = !rob.empty() && rob[0].done && !rob[0].exc;
        bool c1 = c0 && rob.size() >= 2 && rob[1].done && !rob[1].exc;
        int avail = std::min(2, NROB - (int)rob.size());
        // ---------- completions and resolutions
        unsigned cv = 0, cexc = 0; uint32_t crob = 0, ccause = 0;
        unsigned bv = 0, bmis = 0, brob = 0, bck = 0;
        std::vector<int> picked;
        for (int p = 0; p < 4; p++) {
            if (rng() % 3 == 0) continue;
            std::vector<int> cand;
            for (int k = 0; k < (int)rob.size(); k++) {
                E& e = rob[k];
                if (e.done || e.ready_at > cyc) continue;
                if (e.ns && !e.ns_go) continue;
                if ((e.ld || e.st) != (p >= 2)) continue;      // ports 2, 3: the LSU
                if (e.br && p >= 2) continue;
                bool dup = false; for (int q : picked) dup |= q == k;
                if (!dup) cand.push_back(k);
            }
            if (cand.empty()) {
                if (rng() % 20 == 0) {                          // a stale completion
                    int idx; bool live;
                    int tries = 0;
                    do { idx = rng() % NROB; live = false; for (auto& e : rob) live |= e.idx == idx; } while (live && ++tries < 50);
                    if (!live) { cv |= 1u << p; crob |= (uint32_t)idx << (5 * p); }
                }
                continue;
            }
            int k = cand[rng() % cand.size()];
            picked.push_back(k);
            cv |= 1u << p; crob |= (uint32_t)rob[k].idx << (5 * p);
            if (rng() % 25 == 0) { cexc |= 1u << p; ccause |= (uint32_t)(rng() % 32) << (5 * p); }
            if (rob[k].br && p < 2) {
                bv |= 1u << p; brob |= (unsigned)rob[k].idx << (5 * p); bck |= (unsigned)rob[k].ckpt << (3 * p);
                if (rng() % 3 == 0) bmis |= 1u << p;
            }
        }
        for (int p = 0; p < 2; p++)                             // a stale resolution
            if (!((bv >> p) & 1) && rng() % 30 == 0) {
                int idx = rng() % NROB; bool live = false; for (auto& e : rob) live |= e.idx == idx;
                if (!live) { bv |= 1u << p; bmis |= 1u << p; brob |= (unsigned)idx << (5 * p); }
            }
        // the expected restore: the oldest mispredicted branch in the ROB
        int rpos = -1, rck = 0;
        for (int p = 0; p < 2; p++) {
            if (!((bv >> p) & 1) || !((bmis >> p) & 1)) continue;
            int idx = (brob >> (5 * p)) & 31;
            for (int k = 0; k < (int)rob.size(); k++)
                if (rob[k].idx == idx && (rpos < 0 || k < rpos)) { rpos = k; rck = (bck >> (3 * p)) & 7; }
        }
        bool restore = rpos >= 0 && !trap;
        if (restore && __builtin_popcount(bmis & bv) == 2) n2restore++;
        // ---------- dispatch (also in a cycle of trap / restore, now and then: it must not go in)
        int nd = 0;
        if ((!trap && !restore) || rng() % 4 == 0) {
            nd = rng() % 3;
            if (nd > avail) nd = avail;
        }
        E ne[2];
        unsigned dv = 0, dwr = 0, dld = 0, dst = 0, dfu = 0, dns = 0, dexc = 0;
        uint32_t darch = 0, dnew = 0, dold = 0, dcause = 0;
        d.disp_pc[0] = d.disp_pc[1] = d.disp_pc[2] = 0;
        for (int u = 0; u < nd; u++) {
            E& e = ne[u];
            e.idx = (tail_idx + u) % NROB;
            e.pc = (rng() & ((1ull << 38) - 1));
            int r = rng() % 100;
            e.ld = r < 20; e.st = r >= 20 && r < 35; e.br = r >= 35 && r < 50; e.ns = r >= 50 && r < 55;
            e.wr = !e.st && !e.br && rng() % 6 != 0; e.arch = rng() % 32; e.nw = rng() % 64; e.old = rng() % 64;
            e.fused = !e.ld && !e.st && !e.ns && rng() % 3 == 0;
            e.ckpt = rng() % 8;
            bool dx = rng() % 40 == 0;
            e.done = e.exc = dx; e.cause = dx ? rng() % 32 : 0;
            e.ready_at = cyc + 1 + rng() % 10;
            dv |= 1u << u; dwr |= e.wr << u; dld |= e.ld << u; dst |= e.st << u; dfu |= e.fused << u; dns |= e.ns << u; dexc |= dx << u;
            darch |= e.arch << (5 * u); dnew |= e.nw << (6 * u); dold |= e.old << (6 * u); dcause |= e.cause << (5 * u);
            setw(d.disp_pc, 38 * u, 38, e.pc);
        }
        d.disp_valid = dv; d.disp_wr = dwr; d.disp_arch = darch; d.disp_new = dnew; d.disp_old = dold;
        d.disp_ld = dld; d.disp_st = dst; d.disp_fused = dfu; d.disp_ns = dns; d.disp_exc = dexc; d.disp_cause = dcause;
        d.cmp_valid = cv; d.cmp_rob = crob; d.cmp_exc = cexc; d.cmp_cause = ccause;
        d.br_valid = bv; d.br_rob = brob; d.br_mispred = bmis; d.br_ckpt = bck;
        d.eval();

        // ---------- outputs
        if ((int)d.rob_avail != avail) FAIL("rob_avail %d, expected %d", (int)d.rob_avail, avail);
        for (int u = 0; u < nd; u++) if ((int)((d.disp_rob >> (5 * u)) & 31) != ne[u].idx) FAIL("disp_rob[%d] %d, expected %d", u, (int)((d.disp_rob >> (5 * u)) & 31), ne[u].idx);
        if (!rob.empty()) {
            if ((int)d.head_rob != rob[0].idx) FAIL("head %d, expected %d", (int)d.head_rob, rob[0].idx);
            bool hn = rob[0].ns && !rob[0].done;
            if ((bool)d.head_ns != hn) FAIL("head_ns %d, expected %d", (int)d.head_ns, hn);
        } else if (d.head_ns) FAIL("head_ns with an empty ROB");
        if ((bool)d.trap != trap) FAIL("trap %d, expected %d", (int)d.trap, trap);
        if (trap) {
            if ((int)d.trap_cause != rob[0].cause) FAIL("trap cause %d, expected %d", (int)d.trap_cause, rob[0].cause);
            if ((uint64_t)d.trap_pc != rob[0].pc) FAIL("trap pc %llx, expected %llx", (unsigned long long)d.trap_pc, (unsigned long long)rob[0].pc);
        }
        unsigned cvx = (c0 ? 1 : 0) | (c1 ? 2 : 0);
        if ((unsigned)d.cmt_valid != cvx) FAIL("cmt_valid %d, expected %d", (int)d.cmt_valid, cvx);
        int eld = 0, est = 0, eir = 0;
        for (int u = 0; u < 2; u++) {
            if (!((cvx >> u) & 1)) continue;
            E& e = rob[u];
            eld += e.ld; est += e.st; eir += e.fused ? 2 : 1;
            uint64_t pc = getw(d.cmt_pc, 38 * u, 38);
            if (pc != e.pc) FAIL("commit %d pc %llx, expected %llx", u, (unsigned long long)pc, (unsigned long long)e.pc);
            if ((int)((d.cmt_wr >> u) & 1) != e.wr) FAIL("commit %d wr", u);
            if ((int)((d.cmt_arch >> (5 * u)) & 31) != e.arch) FAIL("commit %d arch", u);
            if ((int)((d.cmt_new >> (6 * u)) & 63) != e.nw) FAIL("commit %d new", u);
            if ((int)((d.cmt_old >> (6 * u)) & 63) != e.old) FAIL("commit %d old", u);
        }
        if ((int)d.cmt_ld_n != eld || (int)d.cmt_st_n != est || (int)d.cmt_instret != eir)
            FAIL("counts ld %d st %d instret %d, expected %d %d %d", (int)d.cmt_ld_n, (int)d.cmt_st_n, (int)d.cmt_instret, eld, est, eir);
        if ((bool)d.restore != restore) FAIL("restore %d, expected %d", (int)d.restore, restore);
        else if (restore && ((int)d.restore_rob != rob[rpos].idx || (int)d.restore_ckpt != rck))
            FAIL("restore rob %d ckpt %d, expected %d %d", (int)d.restore_rob, (int)d.restore_ckpt, rob[rpos].idx, rck);
        bool ns_seen = d.head_ns; int ns_idx = d.head_rob;

        // ---------- the clock
        d.clk = 1; d.eval(); d.clk = 0; d.eval();

        // ---------- the reference after the clock
        // completions (to entries in the ROB before this cycle's changes)
        for (int p = 0; p < 4; p++) {
            if (!((cv >> p) & 1)) continue;
            int idx = (crob >> (5 * p)) & 31;
            for (auto& e : rob) if (e.idx == idx) { e.done = true; if ((cexc >> p) & 1) { e.exc = true; e.cause = (ccause >> (5 * p)) & 31; } }
        }
        if (trap) {
            rob.clear(); ntrap++;
            tail_idx = (int)d.head_rob;        // checked next cycle: the head stays where it was
        } else {
            int nc = (c0 ? 1 : 0) + (c1 ? 1 : 0);
            ninstret += eir; ncommit += nc;
            if (restore) {
                int keep = rpos + 1;
                rob.resize(keep);
                nrestore++;
            }
            for (int k = 0; k < nc; k++) rob.pop_front();
            if (restore) {
                tail_idx = rob.empty() ? (int)d.head_rob : (rob.back().idx + 1) % NROB;
            } else {
                for (int u = 0; u < nd; u++) rob.push_back(ne[u]);
                tail_idx = (tail_idx + nd) % NROB;
            }
        }
        if (ns_seen) for (auto& e : rob) if (e.idx == ns_idx) e.ns_go = true;
    }
    printf("tb_rob: %ld cycles, %ld µops committed (%ld instructions), %ld traps, %ld restores (%ld with two mispredicted), %ld mismatches: %s\n",
           cyc, ncommit, ninstret, ntrap, nrestore, n2restore, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
