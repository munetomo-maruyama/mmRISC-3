//---------------------------------------------------------------------------
// tb_iq.cpp : OOO_IQ (16 entries, 3 ports) against an account of when every
// value can be used, kept independently of the queue's own bits
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
// flushed. µops are told apart by their first destination tag (unique
// while a µop is in flight, also when it writes nothing).
//---------------------------------------------------------------------------
#include "VOOO_IQ.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <vector>

struct Uop {
    long id;            // dispatch order: the age
    int port, use[3], src[3], wr[2], dst[2], lat2, ext;
    long disp, issued = -1;
};

static std::mt19937 rng(5);
static VOOO_IQ d;

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    d.clk = 0; d.flush = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    const int NT = 128;                     // 7-bit tags
    long avail[NT];                         // cycle from which the value is usable
    long tag_free_at[NT];                   // when a tag may be used again
    int refs[NT];                           // queued µops that read the tag: it cannot be given out again
    for (int t = 0; t < NT; t++) { avail[t] = 0; tag_free_at[t] = 0; refs[t] = 0; }
    std::map<int, Uop> q;                   // in the queue, by first destination tag
    std::vector<std::pair<long, int>> ext_due;   // (cycle, tag) to announce on ext
    long next_id = 0, bad = 0, issued_n = 0, flushes = 0;
    long cyc;
    for (cyc = 0; cyc < 300000; cyc++) {
        // ---- inputs of this cycle
        int ndisp = rng() % 3;
        if (rng() % 3000 == 0) ndisp = 0;
        int flush = (rng() % 2000 == 0);
        // tags to choose sources from: recently produced ones mostly
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
            x.id = next_id++;
            x.port = (int[]){0, 0, 0, 1, 2, 2}[rng() % 6];
            x.lat2 = x.port == 2 ? (rng() % 4 != 0) : x.port == 1 ? 1 : 0;
            x.ext = x.port == 2 && !x.lat2;            // a store, or a load that missed: answer from outside
            x.dst[0] = t0; x.dst[1] = 0; x.wr[0] = !x.ext; x.wr[1] = 0;
            if (!x.ext && rng() % 4 == 0) {           // a fused pair writing two
                for (int tries = 0; tries < 50; tries++) {
                    int t = 1 + (int)(rng() % (NT - 1));
                    if (t != t0 && tag_free_at[t] <= cyc && !q.count(t) && !refs[t]) { x.dst[1] = t; x.wr[1] = 1; break; }
                }
            }
            for (int s = 0; s < 3; s++) {
                x.use[s] = rng() % 3 != 0;
                if (!recent.empty() && rng() % 3) x.src[s] = recent[rng() % recent.size()];
                else x.src[s] = 1 + (int)(rng() % (NT - 1));
                if (x.src[s] == t0 || x.src[s] == x.dst[1]) x.use[s] = 0;
            }
            tag_free_at[t0] = 1L << 60;
            if (x.wr[1]) tag_free_at[x.dst[1]] = 1L << 60;
            avail[t0] = 1L << 60;
            if (x.wr[1]) avail[x.dst[1]] = 1L << 60;
            if (nd == 0 && k == 1) {}                // keep the program order of the pair
            recent.push_back(t0);
            nd++;
        }
        // external announcements due now
        int extv = 0; uint32_t extt = 0; int ne = 0;
        std::vector<std::pair<long, int>> keep;
        for (auto& e : ext_due) {
            if (e.first <= cyc && ne < 2) { extv |= 1 << ne; extt |= (uint32_t)e.second << (7 * ne); ne++; avail[e.second] = cyc + 1; }
            else keep.push_back(e);
        }
        ext_due.swap(keep);

        // drive
        d.flush = flush;
        d.disp_valid = (nd >= 1 ? 1 : 0) | (nd >= 2 ? 2 : 0);
        uint32_t port = 0, use = 0, rdy = 0, wr = 0, lat2 = 0, dst = 0; uint64_t src = 0;
        for (int k = 0; k < nd; k++) {
            Uop& x = u[k];
            port |= x.port << (2 * k); lat2 |= x.lat2 << k;
            for (int s = 0; s < 3; s++) {
                use |= x.use[s] << (3 * k + s);
                src |= (uint64_t)x.src[s] << (7 * (3 * k + s));
                rdy |= (avail[x.src[s]] <= cyc) << (3 * k + s);
            }
            for (int j = 0; j < 2; j++) { wr |= x.wr[j] << (2 * k + j); dst |= (uint32_t)x.dst[j] << (7 * (2 * k + j)); }
        }
        d.disp_port = port; d.disp_use = use; d.disp_src = src; d.disp_rdy = rdy;
        d.disp_wr = wr; d.disp_dst = dst; d.disp_lat2 = lat2;
        d.ext_valid = extv; d.ext_tag = extt;
        d.eval();
        if (getenv("IQ_DEBUG") && cyc >= atol(getenv("IQ_DEBUG")) && cyc < atol(getenv("IQ_DEBUG")) + 7) {
            printf("cycle %ld disp_ready %d nd %d flush %d iss_valid %d\n", cyc, (int)d.disp_ready, nd, flush, (int)d.iss_valid);
            for (int k = 0; k < nd; k++) printf("  disp p%d port %d use %d%d%d src %d %d %d rdy %d%d%d\n", u[k].dst[0], u[k].port,
                u[k].use[0], u[k].use[1], u[k].use[2], u[k].src[0], u[k].src[1], u[k].src[2],
                avail[u[k].src[0]] <= cyc, avail[u[k].src[1]] <= cyc, avail[u[k].src[2]] <= cyc);
            for (auto& kv : q) { const Uop& x = kv.second; bool r = x.disp < cyc; for (int s2 = 0; s2 < 3; s2++) if (x.use[s2] && avail[x.src[s2]] > cyc) r = false;
                printf("  inq p%d id %ld port %d disp %ld ready %d\n", kv.first, x.id, x.port, x.disp, r); }
        }

        // ---- what must issue now
        auto ready = [&](const Uop& x) {
            if (x.disp >= cyc) return false;
            for (int s = 0; s < 3; s++) if (x.use[s] && avail[x.src[s]] > cyc) return false;
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
        if (!flush) {
            for (int p = 0; p < 3; p++) {
                bool v = (d.iss_valid >> p) & 1;
                int t = (int)((d.iss_dst >> (14 * p)) & 0x7f);
                bool ok = v == (exp[p] != nullptr) && (!v || t == exp[p]->dst[0]);
                if (!ok && bad++ < 10)
                    printf("MISMATCH cycle %ld port %d: issued %d (p%d), expected %s (p%d)\n", cyc, p, v, t,
                           exp[p] ? "one" : "none", exp[p] ? exp[p]->dst[0] : 0);
            }
        }

        // ---- the clock, and the account after it (what issued is read before the edge)
        unsigned issued_now = d.iss_valid;
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if (flush) {
            for (auto& kv : q) {
                Uop& x = kv.second;
                for (int s2 = 0; s2 < 3; s2++) if (x.use[s2]) refs[x.src[s2]]--;
                for (int j = 0; j < 2; j++) if (x.wr[j] || j == 0) { avail[x.dst[j]] = cyc + 1; tag_free_at[x.dst[j]] = cyc + 40; }
            }
            q.clear();
            flushes++;
        } else {
            for (int p = 0; p < 3; p++) {
                if (!((issued_now >> p) & 1) || !exp[p]) continue;
                Uop x = *exp[p];
                q.erase(x.dst[0]);
                for (int s2 = 0; s2 < 3; s2++) if (x.use[s2]) refs[x.src[s2]]--;
                issued_n++;
                int lat = x.lat2 ? 2 : 1;
                for (int j = 0; j < 2; j++) if (x.wr[j]) avail[x.dst[j]] = cyc + lat;
                if (x.ext) ext_due.push_back({cyc + 3 + (long)(rng() % 8), x.dst[0]});
                for (int j = 0; j < 2; j++) if (x.wr[j] || j == 0) tag_free_at[x.dst[j]] = cyc + 60;
            }
            for (int k = 0; k < nd; k++) {
                u[k].disp = cyc; q[u[k].dst[0]] = u[k];
                for (int s2 = 0; s2 < 3; s2++) if (u[k].use[s2]) refs[u[k].src[s2]]++;
            }
        }
    }
    printf("tb_iq: %ld cycles, %ld µops issued, %ld flushes, %ld mismatches: %s\n", cyc, issued_n, flushes, bad,
           bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
