//---------------------------------------------------------------------------
// tb_ctrl.cpp : OOO_CTRL (6 checkpoints) against an account of the µops in
// flight kept in program order
//
// A random stream of µops (a quarter of them branches with a checkpoint,
// loads, stores, the rest) is offered to renaming two at a time; the test
// bench plays OOO_RENAME's ring of checkpoint ids (out_ckpt_id: the next id,
// and the one after it for slot 1 when slot 0 takes one; a restore goes on
// after the restored id) and the ROB (the oldest mispredicted branch of the
// cycle; now and then a trap or a replay that empties everything). The
// room in the ROB, the issue queue, the LQ and the SQ is random, and so are
// the resolutions: up to 2 dispatched branches a cycle, some mispredicted,
// at a rate that changes every 500 cycles (so that at times all 6
// checkpoints are in use and renaming waits for one).
//
// Checked every cycle against the account:
//   - r_go: the prefix of the µops offered that may rename (the DS register
//     free or leaving, registers, no recovery, a checkpoint id not in use)
//   - ds_valid / d_go: what the DS register holds, and that it goes when
//     every resource has room for it, all of it or none
//   - d_bmask: exactly the checkpoints of the older branches not resolved
//   - live: the checkpoints of the branches in flight not resolved
//   - kill / clr: the restored checkpoint; the branches resolved as
//     predicted that survive the cycle
//   - restore: the id, the LSU tails and the FTQ index given at the
//     branch's dispatch
//   - the redirect: trap vector, replay pc, or the restoring branch's next pc
//---------------------------------------------------------------------------
#include "VOOO_CTRL.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <vector>

static const int NCK = 6;
static std::mt19937_64 rng(23);
static VOOO_CTRL d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

struct U {
    long seq; bool ck, ld, st; int ftq;
    int id = -1;                 // its checkpoint (a branch)
    bool renamed = false, disp = false, resolved = false;
    int lqt = 0, sqt = 0;        // the tails given at its dispatch
};

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("CTRL_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    std::deque<U> fl;            // renamed, in flight (program order)
    std::deque<U> stream;        // not renamed yet
    long seq = 0;
    int ck_next = 0;
    int res_pct = 30;            // the chance a port resolves a branch in a cycle
    long nren = 0, ndisp = 0, nclr = 0, nrestore = 0, nflush = 0, nckstall = 0;
    auto gen = [&]() { U u; u.seq = seq++; int r = rng() % 100; u.ck = r < 25; u.ld = r >= 25 && r < 45; u.st = r >= 45 && r < 60; u.ftq = rng() % 8; return u; };
    auto live_truth = [&]() { unsigned m = 0; for (auto& u : fl) if (u.ck && !u.resolved) m |= 1u << u.id; return m; };
    auto mask_of = [&](long s) { unsigned m = 0; for (auto& u : fl) { if (u.seq >= s) break; if (u.ck && !u.resolved) m |= 1u << u.id; } return m; };

    for (cyc = 0; cyc < 400000; cyc++) {
        while (stream.size() < 2) stream.push_back(gen());
        // ---- inputs
        int nofs = rng() % 3;                       // µops offered
        unsigned rv = 0, rck = 0; unsigned rid = 0;
        int id0 = ck_next, id1 = (ck_next + (stream[0].ck ? 1 : 0)) % NCK;
        if (nofs >= 1) { rv |= 1; rck |= stream[0].ck; }
        if (nofs >= 2) { rv |= 2; rck |= stream[1].ck << 1; }
        rid = id0 | (id1 << 3);
        int ren_ready = rng() % 8 != 0;
        // the DS register: the renamed µops not dispatched
        std::vector<U*> ds; for (auto& u : fl) if (u.renamed && !u.disp) ds.push_back(&u);
        unsigned dld = 0, dst = 0, dftq = 0;
        for (size_t k = 0; k < ds.size() && k < 2; k++) { dld |= ds[k]->ld << k; dst |= ds[k]->st << k; dftq |= ds[k]->ftq << (3 * k); }
        int ra = rng() % 3, ia = rng() % 3, la = rng() % 3, sa = rng() % 3;
        if (rng() % 3 == 0) ra = ia = la = sa = 2;
        unsigned lqt[2], sqt[2]; for (int k = 0; k < 2; k++) { lqt[k] = rng() % 16; sqt[k] = rng() % 16; }
        // resolutions: up to 2 dispatched branches not resolved; their rate changes
        // now and then, so that the checkpoints run out at times
        if (cyc % 500 == 0) res_pct = (int[]){10, 30, 70}[rng() % 3];
        std::vector<U*> cand; for (auto& u : fl) if (u.ck && u.disp && !u.resolved) cand.push_back(&u);
        std::shuffle(cand.begin(), cand.end(), rng);
        U* br[2] = {nullptr, nullptr}; bool mis[2] = {false, false}; uint64_t nxt[2];
        unsigned bv = 0, bm = 0, bck = 0;
        for (int p = 0; p < 2; p++) {
            nxt[p] = rng() & ((1ull << 38) - 1);
            if (p < (int)cand.size() && rng() % 100 < res_pct) { br[p] = cand[p]; mis[p] = rng() % 7 == 0; bv |= 1u << p; bm |= mis[p] << p; bck |= br[p]->id << (3 * p); }
            else bck |= (rng() % NCK) << (3 * p);
        }
        // the ROB: the oldest mispredicted of the cycle; now and then a trap or a replay
        U* rs = nullptr; for (int p = 0; p < 2; p++) if (br[p] && mis[p] && (!rs || br[p]->seq < rs->seq)) rs = br[p];
        int trap = rng() % 400 == 0, replay = !trap && rng() % 400 == 0;
        uint64_t tvec = rng() & ((1ull << 38) - 1), rpc = rng() & ((1ull << 38) - 1);

        d.r_valid = rv; d.r_ckpt = rck; d.r_ckpt_id = rid; d.r_ren_ready = ren_ready;
        d.ds_ld = dld; d.ds_st = dst; d.ds_ftq = dftq;
        d.rob_avail = ra; d.iq_avail = ia; d.lq_avail = la; d.sq_avail = sa;
        d.ck_lq_tail = lqt[0] | (lqt[1] << 4); d.ck_sq_tail = sqt[0] | (sqt[1] << 4);
        d.br_valid = bv; d.br_mispred = bm; d.br_ckpt = bck;
        d.br_next[0] = (uint32_t)nxt[0]; d.br_next[1] = (uint32_t)(nxt[0] >> 32) | (uint32_t)(nxt[1] << 6); d.br_next[2] = (uint32_t)(nxt[1] >> 26);
        d.rob_restore = rs != nullptr; d.rob_restore_ckpt = rs ? rs->id : rng() % NCK;
        d.trap = trap; d.replay = replay; d.replay_pc = rpc; d.trap_vec = tvec;
        d.eval();

        // ---- expected
        bool flush = trap || replay, restore = rs && !flush, rcv = flush || restore;
        unsigned live = live_truth();
        if ((unsigned)d.live != live) FAIL("live %02x, expected %02x", (unsigned)d.live, live);
        // DS
        unsigned dsv = ds.size() >= 2 ? 3 : ds.size() == 1 ? 1 : 0;
        if ((unsigned)d.ds_valid != dsv) FAIL("ds_valid %u, expected %u", (unsigned)d.ds_valid, dsv);
        int nall = (int)std::min<size_t>(ds.size(), 2), nld = 0, nst = 0;
        for (int k = 0; k < nall; k++) { nld += ds[k]->ld; nst += ds[k]->st; }
        bool dok = !rcv && ra >= nall && ia >= nall && la >= nld && sa >= nst;
        unsigned dgo = dok ? dsv : 0;
        if ((unsigned)d.d_go != dgo) FAIL("d_go %u, expected %u (ds %d, rob %d iq %d lq %d sq %d, ld %d st %d, rcv %d)", (unsigned)d.d_go, dgo, nall, ra, ia, la, sa, nld, nst, rcv);
        // clears: the branches resolved as predicted that this cycle's restore does not kill
        unsigned clr = 0;
        if (!flush) for (int p = 0; p < 2; p++) if (br[p] && !mis[p] && !(restore && br[p]->seq > rs->seq)) clr |= 1u << br[p]->id;
        if ((unsigned)d.clr != clr) FAIL("clr %02x, expected %02x", (unsigned)d.clr, clr);
        for (int k = 0; k < nall; k++) {
            unsigned m = mask_of(ds[k]->seq) & ~clr;
            unsigned g = (unsigned)((d.d_bmask >> (6 * k)) & 63);
            if (dgo >> k & 1 && g != m) FAIL("d_bmask[%d] %02x, expected %02x (seq %ld)", k, g, m, ds[k]->seq);
        }
        // renaming
        bool dsfree = dsv == 0 || dgo == dsv;
        unsigned go = 0;
        bool ok0 = !(rck & 1) || !((live >> id0) & 1), ok1 = !(rck & 2) || !((live >> id1) & 1);
        if ((rv & 1) && dsfree && ren_ready && !rcv && ok0) { go = 1; if ((rv & 2) && ok1) go = 3; }
        if ((rv & 1) && dsfree && ren_ready && !rcv && (!ok0 || ((rv & 2) && !ok1))) nckstall++;
        if ((unsigned)d.r_go != go) FAIL("r_go %u, expected %u", (unsigned)d.r_go, go);
        // recovery
        if ((bool)d.flush_all != flush) FAIL("flush_all %d, expected %d", (int)d.flush_all, flush);
        if ((bool)d.restore != restore) FAIL("restore %d, expected %d", (int)d.restore, restore);
        if ((bool)d.fe_redirect != rcv) FAIL("fe_redirect %d, expected %d", (int)d.fe_redirect, rcv);
        unsigned kill = restore ? 1u << rs->id : 0;
        if ((unsigned)d.kill != kill) FAIL("kill %02x, expected %02x", (unsigned)d.kill, kill);
        uint64_t fepc = (uint64_t)d.fe_pc;
        if (restore) {
            if ((int)d.restore_id != rs->id) FAIL("restore_id %d, expected %d", (int)d.restore_id, rs->id);
            if ((int)d.restore_lq_tail != rs->lqt || (int)d.restore_sq_tail != rs->sqt || (int)d.restore_ftq != rs->ftq)
                FAIL("restore tails %d %d ftq %d, expected %d %d %d", (int)d.restore_lq_tail, (int)d.restore_sq_tail, (int)d.restore_ftq, rs->lqt, rs->sqt, rs->ftq);
            uint64_t e = nxt[rs == br[0] ? 0 : 1];
            if (fepc != e) FAIL("fe_pc %llx, expected %llx (restore)", (unsigned long long)fepc, (unsigned long long)e);
        }
        if (trap && fepc != tvec) FAIL("fe_pc %llx, expected the trap vector %llx", (unsigned long long)fepc, (unsigned long long)tvec);
        if (replay && fepc != rpc) FAIL("fe_pc %llx, expected the replay pc %llx", (unsigned long long)fepc, (unsigned long long)rpc);

        // ---- the clock, and the account after it
        unsigned gor = d.r_go, god = d.d_go;
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        // dispatch (with the tails of this cycle)
        for (int k = 0; k < nall; k++) if ((god >> k) & 1) { ds[k]->disp = true; ds[k]->lqt = lqt[k]; ds[k]->sqt = sqt[k]; ndisp++; }
        // resolutions as predicted
        for (int p = 0; p < 2; p++) if ((clr >> (br[p] ? br[p]->id : 0)) & 1 && br[p] && !mis[p]) { br[p]->resolved = true; nclr++; }
        if (flush) {
            fl.clear(); stream.clear(); nflush++;
        } else if (restore) {
            rs->resolved = true; nrestore++;
            long s = rs->seq;
            while (!fl.empty() && fl.back().seq > s) fl.pop_back();
            stream.clear();                         // fetched again after the branch
            ck_next = (rs->id + 1) % NCK;
        } else {
            for (int k = 0; k < 2; k++) if ((gor >> k) & 1) {
                U u = stream.front(); stream.pop_front();
                u.renamed = true;
                if (u.ck) { u.id = ck_next; ck_next = (ck_next + 1) % NCK; }
                fl.push_back(u); nren++;
            }
        }
        // what no longer matters: dispatched non-branches and resolved branches at the front
        while (!fl.empty() && fl.front().disp && (!fl.front().ck || fl.front().resolved)) fl.pop_front();
    }
    printf("tb_ctrl: %ld cycles, %ld µops renamed, %ld dispatched, %ld cleared, %ld restores, %ld flushes, %ld stalls on a checkpoint id, %ld mismatches: %s\n",
           cyc, nren, ndisp, nclr, nrestore, nflush, nckstall, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
