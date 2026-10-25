//---------------------------------------------------------------------------
// tb_iq.cpp : OOO_IQ (16 entries, 3 ports, 2 sources and 1 destination per
// µop, 6-bit tags) against an account of when every value can be used, kept
// independently of the queue's own bits
//
//   a µop issued in cycle c with latency 1 (ALU) makes its results usable
//   by µops issued from c + 1, with latency 2 (load, multiply) from c + 2;
//   a value announced on ext_* in cycle c is usable from c + 1.
//
// Every cycle, the µops that are in the queue (dispatched in an earlier
// cycle), not issued, and whose sources are all usable are "ready". The
// queue must issue, on port 2 the oldest ready LSU µop, on port 0 the
// oldest ready ALU µop (any ALU or ALU0 only), on port 1 the oldest ready
// any-ALU µop other than port 0's; nothing else. That checks the wakeup
// (back to back for latency 1), the select (oldest first, no port idle
// while a µop is ready for it) and that nothing issues early or twice.
// Some µops' results come from outside (ext); now and then the queue is
// flushed. µops are told apart by their destination tag (unique while a µop
// is in flight, also when it writes nothing). The µops keep the rules the
// wakeup buses rely on (OOO_IQ.sv): an any-ALU µop has latency 1, an
// ALU0-only one (multiply) latency 2, and an LSU µop writes a register only
// with latency 2 (a load); a store or a load that missed writes none here
// and is answered on ext_*. A tag is given out again 4 cycles after its µop
// left the queue (after its announcement for an external one), not before.
//
// Loads that miss (Plan/OOC.md 15): a load issued in cycle c is cancelled
// now and then (ld_cancel in c + 3, as the LSU in M). The account keeps,
// for every value, the open loads it depends on; the load is decided in
// c + 3 after that cycle's issue (the queue does not look at ld_cancel for
// its select): a cancel makes every value depending on it unusable, sends
// the µops issued on them back to waiting, also one issued in that very
// cycle (they must issue again), and the load waits for a late answer on
// ext_*; a confirmation drops it from the sets. ld_kill is expected a
// cycle later. Checked besides the issue: iss_ldm (the open loads of each issued
// µop, as load slots), ld_kill, and disp_ready (an entry stays while its
// µop's loads are open, and a cancelled load's until its late answer).
// disp_rdy is what renaming knows: set when a value is announced and not
// taken back by a cancel, so the queue must correct it.
//---------------------------------------------------------------------------
#include "VOOO_IQ.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <set>
#include <vector>

enum St { WAIT, KEPT, PHANTOM };
struct Uop {
    long id;            // dispatch order: the age
    int port, use[2], src[2], wr, dst, lat2, ext;
    long disp, issued = -1;
    St st = WAIT;
    std::set<long> deps;    // open loads (when issued)
    bool load() const { return port == 2 && lat2; }
};
struct Load { long id; int slot; bool cancel; int dst; };

static std::mt19937 rng(5);
static VOOO_IQ d;

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("IQ_SEED")) rng.seed((unsigned)strtoul(e, nullptr, 0));
    d.clk = 0; d.flush = 0; d.ld_cancel = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    const int NT = 64;                      // 6-bit tags
    const long NEVER = 1L << 60;
    long avail[NT];                         // cycle from which the value is usable
    long rn_at[NT];                         // cycle from which renaming says ready (a cancel does not undo it)
    std::set<long> vdeps[NT];               // the open loads the value depends on
    long tag_free_at[NT];                   // when a tag may be used again
    int refs[NT];                           // queued µops that read the tag: it cannot be given out again
    long flushed_until[NT] = {0};           // a flushed producer's tag: no µop reads it (as after renaming's recovery)
    for (int t = 0; t < NT; t++) { avail[t] = 0; rn_at[t] = 0; tag_free_at[t] = 0; refs[t] = 0; }
    std::map<int, Uop> q;                   // in the queue (waiting, kept, cancelled load), by destination tag
    std::vector<std::pair<long, int>> ext_due;   // (cycle, tag) to announce on ext
    std::map<long, Load> loads;             // issued loads, by the cycle of their issue
    std::map<long, int> slot_of;            // open loads: id -> slot
    long next_id = 0, bad = 0, issued_n = 0, flushes = 0, ncancel = 0, nrearm = 0, nkept = 0;
    int next_kill = 0;
    long cyc;
    auto MM = [&](const char* fmt, auto... a) { if (bad++ < 10) { printf("MISMATCH cycle %ld: ", cyc); printf(fmt, a...); printf("\n"); } };
    auto free_uop = [&](Uop& x) {           // it leaves the queue
        for (int s2 = 0; s2 < 2; s2++) if (x.use[s2]) refs[x.src[s2]]--;
    };
    for (cyc = 0; cyc < 300000; cyc++) {
        // ---- disp_ready: from the queue as the last cycle left it
        int used = (int)q.size();
        int exp_ready = std::min(2, 16 - used);
        if ((int)d.disp_ready != exp_ready) MM("disp_ready %d, expected %d (%d entries)", (int)d.disp_ready, exp_ready, used);

        // a load issued 3 cycles ago that is to be cancelled: the LSU says so in M
        auto lc = loads.find(cyc - 3);
        int ldc = lc != loads.end() && lc->second.cancel;
        int exp_kill = next_kill;                   // ld_kill: the slot cancelled in the cycle before
        next_kill = 0;

        // ---- inputs of this cycle
        int ndisp = rng() % 3;
        if (rng() % 3000 == 0) ndisp = 0;
        int flush = (rng() % 2000 == 0);
        std::vector<int> recent;
        for (auto& kv : q) recent.push_back(kv.first);
        Uop u[2];
        int nd = 0;
        for (int k = 0; k < ndisp && !flush; k++) {
            if (k >= (int)d.disp_ready) break;
            Uop& x = u[nd];
            int t0 = -1;
            for (int tries = 0; tries < 50; tries++) {
                int t = 1 + (int)(rng() % (NT - 1));
                if (tag_free_at[t] <= cyc && !q.count(t) && !refs[t]) { t0 = t; break; }
            }
            if (t0 < 0) break;
            x = Uop{};
            x.id = next_id++;
            x.port = (int[]){0, 0, 0, 1, 2, 2}[rng() % 6];
            x.lat2 = x.port == 2 ? (rng() % 4 != 0) : x.port == 1 ? 1 : 0;
            x.ext = x.port == 2 && !x.lat2;            // a store, or a load that missed: answer from outside
            x.dst = t0; x.wr = !x.ext;
            for (int s = 0; s < 2; s++) {
                x.use[s] = rng() % 3 != 0;
                do {
                    if (!recent.empty() && rng() % 3) x.src[s] = recent[rng() % recent.size()];
                    else x.src[s] = 1 + (int)(rng() % (NT - 1));
                } while (flushed_until[x.src[s]] > cyc);
                if (x.src[s] == t0) x.use[s] = 0;
            }
            tag_free_at[t0] = NEVER;
            avail[t0] = NEVER; rn_at[t0] = NEVER; vdeps[t0].clear();   // (the second of a pair may read it: renaming says not ready)
            recent.push_back(t0);
            nd++;
        }
        // external announcements due now
        int extv = 0; uint32_t extt = 0; int ne = 0;
        std::vector<std::pair<long, int>> keep, announced;
        for (auto& e : ext_due) {
            if (e.first <= cyc && ne < 2) {
                extv |= 1 << ne; extt |= (uint32_t)e.second << (6 * ne); ne++;
                announced.push_back(e);
            }
            else keep.push_back(e);
        }
        ext_due.swap(keep);

        // drive
        d.flush = flush;
        d.ld_cancel = ldc;
        d.disp_valid = (nd >= 1 ? 1 : 0) | (nd >= 2 ? 2 : 0);
        uint32_t port = 0, use = 0, rdy = 0, wr = 0, lat2 = 0, dst = 0, src = 0;
        for (int k = 0; k < nd; k++) {
            Uop& x = u[k];
            port |= x.port << (2 * k); lat2 |= x.lat2 << k;
            for (int s = 0; s < 2; s++) {
                use |= x.use[s] << (2 * k + s);
                src |= (uint32_t)x.src[s] << (6 * (2 * k + s));
                rdy |= (rn_at[x.src[s]] <= cyc) << (2 * k + s);
            }
            wr |= x.wr << k; dst |= (uint32_t)x.dst << (6 * k);
        }
        d.disp_port = port; d.disp_use = use; d.disp_src = src; d.disp_rdy = rdy;
        d.disp_wr = wr; d.disp_dst = dst; d.disp_lat2 = lat2;
        d.ext_valid = extv; d.ext_tag = extt;
        d.eval();

        if ((int)d.ld_kill != exp_kill) MM("ld_kill %x, expected %x", (int)d.ld_kill, exp_kill);
        if (getenv("IQ_DEBUG") && cyc >= atol(getenv("IQ_DEBUG")) && cyc < atol(getenv("IQ_DEBUG")) + 8) {
            printf("cycle %ld disp_ready %d nd %d flush %d iss_valid %d kill %x ldc %d\n", cyc, (int)d.disp_ready, nd, flush, (int)d.iss_valid, exp_kill, ldc);
            for (int k = 0; k < nd; k++) printf("  disp p%d port %d lat2 %d use %d%d src %d %d avail %ld %ld rn %ld %ld\n", u[k].dst, u[k].port, u[k].lat2,
                u[k].use[0], u[k].use[1], u[k].src[0], u[k].src[1], avail[u[k].src[0]], avail[u[k].src[1]], rn_at[u[k].src[0]], rn_at[u[k].src[1]]);
            for (auto& kv : q) { const Uop& x = kv.second;
                printf("  inq p%d id %ld port %d st %d disp %ld use %d%d src %d %d avail %ld %ld\n", kv.first, x.id, x.port, (int)x.st, x.disp, x.use[0], x.use[1], x.src[0], x.src[1], avail[x.src[0]], avail[x.src[1]]); }
        }

        // ---- what must issue now
        auto ready = [&](const Uop& x) {
            if (x.st != WAIT || x.disp >= cyc) return false;
            for (int s = 0; s < 2; s++) if (x.use[s] && avail[x.src[s]] > cyc) return false;
            return true;
        };
        const Uop* e0 = nullptr; const Uop* e1 = nullptr; const Uop* e2 = nullptr;
        for (auto& kv : q) {
            const Uop& x = kv.second;
            if (!ready(x)) continue;
            if (x.port == 2) { if (!e2 || x.id < e2->id) e2 = &x; }
            else if (!e0 || x.id < e0->id) e0 = &x;
        }
        for (auto& kv : q) {
            const Uop& x = kv.second;
            if (!ready(x) || x.port != 0 || &x == e0) continue;
            if (!e1 || x.id < e1->id) e1 = &x;
        }
        const Uop* exp[3] = {e0, e1, e2};
        auto deps_of = [&](const Uop& x) {      // the open loads of a µop issued now
            std::set<long> s;
            for (int k = 0; k < 2; k++) if (x.use[k]) s.insert(vdeps[x.src[k]].begin(), vdeps[x.src[k]].end());
            return s;
        };
        if (!flush) {
            for (int p = 0; p < 3; p++) {
                bool v = (d.iss_valid >> p) & 1;
                int t = (int)((d.iss_dst >> (6 * p)) & 0x3f);
                bool ok = v == (exp[p] != nullptr) && (!v || t == exp[p]->dst);
                if (!ok) MM("port %d: issued %d (p%d), expected %s (p%d)", p, v, t, exp[p] ? "one" : "none", exp[p] ? exp[p]->dst : 0);
                if (ok && v) {
                    int m = 0;
                    for (long l : deps_of(*exp[p])) m |= 1 << slot_of.at(l);
                    int g = (int)((d.iss_ldm >> (3 * p)) & 7);
                    if (g != m) MM("port %d (p%d): iss_ldm %x, expected %x", p, t, g, m);
                }
            }
        }

        // ---- the clock, and the account after it (what issued is read before the edge)
        unsigned issued_now = d.iss_valid;
        bool load_now = (d.iss_valid >> 2) & 1 && (d.iss_wr >> 2) & 1;
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        // the announcements of this cycle (a cancelled load's ends its wait)
        for (auto& e : announced) {
            avail[e.second] = cyc + 1; rn_at[e.second] = std::min(rn_at[e.second], cyc + 1); vdeps[e.second].clear();
            tag_free_at[e.second] = cyc + 4;
            auto it = q.find(e.second);
            if (it != q.end() && it->second.st == PHANTOM) { free_uop(it->second); q.erase(it); }
        }
        if (flush) {
            for (auto& kv : q) {
                Uop& x = kv.second;
                free_uop(x);
                avail[x.dst] = cyc + 1; rn_at[x.dst] = cyc + 1; vdeps[x.dst].clear(); tag_free_at[x.dst] = cyc + 4;
                flushed_until[x.dst] = cyc + 4;
            }
            // a cancelled load flushed never gets its late answer (the LSU drops it too)
            std::vector<std::pair<long, int>> kept_ext;
            for (auto& e : ext_due) if (!q.count(e.second)) kept_ext.push_back(e);
            ext_due.swap(kept_ext);
            q.clear();
            flushes++;
            // the loads not yet reported are flushed in the LSU too: never cancelled
            for (auto& kv : loads) if (kv.first >= cyc - 2) kv.second.cancel = false;
            // (the one reported in this cycle is decided below, with nothing left in the queue)
            // a load the queue chose in this cycle is decided like any other (never cancelled)
            if (load_now) { long id = next_id++; loads[cyc] = Load{id, (int)(cyc % 3), false, 0}; slot_of[id] = (int)(cyc % 3); }
        } else {
            for (int p = 0; p < 3; p++) {
                if (!((issued_now >> p) & 1) || !exp[p]) continue;
                Uop& x = q[exp[p]->dst];
                issued_n++;
                x.deps = deps_of(x);
                x.issued = cyc;
                if (x.load()) {
                    Load L{next_id++, (int)(cyc % 3), rng() % 4 == 0, x.dst};
                    loads[cyc] = L; slot_of[L.id] = L.slot;
                    x.deps.insert(L.id);
                }
                int lat = x.lat2 ? 2 : 1;
                if (x.wr) { avail[x.dst] = cyc + lat; rn_at[x.dst] = std::min(rn_at[x.dst], cyc + lat); vdeps[x.dst] = x.deps; }
                if (!x.deps.empty()) { x.st = KEPT; nkept++; continue; }    // stays until its loads are decided
                free_uop(x);
                // an external answer holds its tag until it is announced
                if (x.ext) ext_due.push_back({cyc + 3 + (long)(rng() % 8), x.dst});
                else tag_free_at[x.dst] = cyc + 4;
                q.erase(x.dst);
            }
            for (int k = 0; k < nd; k++) {
                u[k].disp = cyc; q[u[k].dst] = u[k];
                avail[u[k].dst] = NEVER; rn_at[u[k].dst] = NEVER; vdeps[u[k].dst].clear();
                for (int s2 = 0; s2 < 2; s2++) if (u[k].use[s2]) refs[u[k].src[s2]]++;
            }
        }
        // ---- the load issued 3 cycles ago is decided in this cycle (after what issued)
        auto lit = loads.find(cyc - 3);
        if (lit != loads.end()) {
            Load L = lit->second; loads.erase(lit); slot_of.erase(L.id);
            if (L.cancel) {
                next_kill = 1 << L.slot; ncancel++;
                // every value depending on it is unusable; the µops issued on it wait again
                for (int t = 0; t < NT; t++) if (vdeps[t].count(L.id)) { avail[t] = NEVER; vdeps[t].clear(); }
                for (auto& kv : q) {
                    Uop& x = kv.second;
                    if (x.st != KEPT || !x.deps.count(L.id)) continue;
                    if (x.load() && x.issued == cyc - 3) {
                        x.st = PHANTOM;                     // the load: its late answer comes on ext
                        ext_due.push_back({cyc + 1 + (long)(rng() % 9), x.dst});
                    } else {
                        x.st = WAIT; nrearm++;
                        if (x.wr) { avail[x.dst] = NEVER; vdeps[x.dst].clear(); }
                    }
                    x.deps.clear();
                }
            } else {
                for (int t = 0; t < NT; t++) vdeps[t].erase(L.id);
                std::vector<int> gone;
                for (auto& kv : q) {
                    Uop& x = kv.second;
                    if (x.st != KEPT) continue;
                    x.deps.erase(L.id);
                    if (x.deps.empty()) gone.push_back(kv.first);
                }
                for (int t : gone) {
                    Uop& x = q[t];
                    free_uop(x);
                    if (x.ext) ext_due.push_back({cyc + 1 + (long)(rng() % 8), x.dst});
                    else tag_free_at[x.dst] = cyc + 4;
                    q.erase(t);
                }
            }
        }
    }
    printf("tb_iq: %ld cycles, %ld µops issued (%ld kept for open loads), %ld loads cancelled, %ld µops taken back, %ld flushes, %ld mismatches: %s\n",
           cyc, issued_n, nkept, ncancel, nrearm, flushes, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
