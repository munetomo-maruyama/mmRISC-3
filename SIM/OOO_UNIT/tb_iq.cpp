//---------------------------------------------------------------------------
// tb_iq.cpp : OOO_IQ (10 entries, 3 ports, 2 sources and 1 destination per
// µop, 6-bit tags) against an account of when every value can be used, kept
// independently of the queue's own bits
//
//   a µop issued in cycle c with latency 1 (ALU) makes its results usable
//   by µops issued from c + 1, with latency 2 (load, multiply) from c + 2;
//   a value announced on ext_* in cycle c is usable from c + 1.
//
// Every cycle, the µops that are in the queue (dispatched in an earlier
// cycle), not issued, and whose sources are all usable are "ready". The
// queue must issue, on port 2 the oldest ready LSU µop, on port 1 the
// oldest ready any-ALU µop, on port 0 the oldest ready ALU µop (any ALU or
// ALU0 only) other than port 1's (G0b L7: port 1 first); nothing else. That checks the wakeup
// (back to back for latency 1), the select (oldest first, no port idle
// while a µop is ready for it) and that nothing issues early or twice.
// Some µops' results come from outside (ext); now and then the queue is
// flushed. µops are told apart by their destination tag (unique while a µop
// is in flight, also when it writes nothing). The µops keep the rules the
// wakeup buses rely on (OOO_IQ.sv): an any-ALU µop has latency 1, an
// ALU0-only one latency 1 or 2 (a complex ALU operation or a multiply), and
// an LSU µop writes a register only
// with latency 2 (a load); a store or a load that missed writes none here
// and is answered on ext_*. A tag is given out again 4 cycles after its µop
// left the queue (after its announcement for an external one), not before:
// with 63 tags the old 40 to 60 cycles would starve the test.
//
// Also checked: disp_ready (the free entries as the last cycle left them),
// disp_entry (never an entry in use, never the same for both slots) and
// that iss_entry is the entry of the issued µop (the payload's addresses).
// Loads that miss are not taken back by the queue (replay after commit,
// OOO_IQ.sv): for the queue a load is a latency-2 µop like any other.
//
// Branch masks (OOO_CTRL): the test bench keeps the checkpoint ids open in
// program order; a dispatched µop takes them as its mask, and a µop may
// open a new one after it. Now and then a kill (in a cycle without
// dispatch, as OOO_CTRL gives it) of an open id: the µops whose mask has it
// leave, and the ids opened after it close; and a clear of an open id:
// its bit goes from every mask. iss_bm is checked for every issue.
//---------------------------------------------------------------------------
#include "VOOO_IQ.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <map>
#include <random>
#include <vector>

struct Uop {
    long id;            // dispatch order: the age
    int port, use[2], src[2], wr, dst, lat2, ext;
    long disp, issued = -1;
    int entry = -1;     // its entry (disp_entry), where the payload is
    unsigned bm = 0;    // its branch mask
};

static std::mt19937 rng(5);
static VOOO_IQ d;

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("IQ_SEED")) rng.seed((unsigned)strtoul(e, nullptr, 0));
    const int NQ = 10;                      // entries
    d.clk = 0; d.flush = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    const int NT = 64;                      // 6-bit tags
    long avail[NT];                         // cycle from which the value is usable
    long tag_free_at[NT];                   // when a tag may be used again
    int refs[NT];                           // queued µops that read the tag: it cannot be given out again
    for (int t = 0; t < NT; t++) { avail[t] = 0; tag_free_at[t] = 0; refs[t] = 0; }
    std::map<int, Uop> q;                   // in the queue, by destination tag
    std::vector<std::pair<long, int>> ext_due;   // (cycle, tag) to announce on ext
    long next_id = 0, bad = 0, issued_n = 0, flushes = 0, nkill = 0, nkilled = 0, nclr = 0;
    std::vector<int> open_ids;              // checkpoint ids open, in program order
    const int NCK = 6;
    long cyc;
    for (cyc = 0; cyc < 300000; cyc++) {
        // ---- disp_ready: from the queue as the last cycle left it
        {
            int exp_ready = std::min(2, NQ - (int)q.size());
            if ((int)d.disp_ready != exp_ready && bad++ < 10)
                printf("MISMATCH cycle %ld: disp_ready %d, expected %d (%d entries)\n", cyc, (int)d.disp_ready, exp_ready, (int)q.size());
        }
        // ---- inputs of this cycle
        int ndisp = rng() % 3;
        if (rng() % 3000 == 0) ndisp = 0;
        int flush = (rng() % 2000 == 0);
        // a kill of an open id (no dispatch then) and a clear of another
        int kill_id = -1, clr_id = -1;
        if (!flush && !open_ids.empty() && rng() % 40 == 0) {
            size_t i = rng() % open_ids.size();
            kill_id = open_ids[i];
            open_ids.resize(i);                 // it and those opened after it close
            ndisp = 0;
        }
        if (!flush && !open_ids.empty() && rng() % 6 == 0) {
            size_t i = rng() % open_ids.size();
            clr_id = open_ids[i];
            open_ids.erase(open_ids.begin() + i);
        }
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
                // (not a tag the older µop of the same group reads: that would be a
                // dependence on a younger µop, which a kill of it makes visible)
                bool rd0 = nd == 1 && ((u[0].use[0] && u[0].src[0] == t) || (u[0].use[1] && u[0].src[1] == t));
                if (tag_free_at[t] <= cyc && !q.count(t) && !refs[t] && !rd0) { t0 = t; break; }
            }
            if (t0 < 0) break;
            x.id = next_id++;
            x.port = (int[]){0, 0, 0, 1, 2, 2}[rng() % 6];
            x.lat2 = x.port == 2 ? (rng() % 4 != 0) : x.port == 1 ? (rng() & 1) : 0;   // ALU0 only: a multiply or a complex ALU operation (L7)
            x.ext = x.port == 2 && !x.lat2;            // a store, or a load that missed: answer from outside
            x.dst = t0; x.wr = !x.ext;
            for (int s = 0; s < 2; s++) {
                x.use[s] = rng() % 3 != 0;
                if (!recent.empty() && rng() % 3) x.src[s] = recent[rng() % recent.size()];
                else x.src[s] = 1 + (int)(rng() % (NT - 1));
                if (x.src[s] == t0) x.use[s] = 0;
            }
            tag_free_at[t0] = 1L << 60;
            avail[t0] = 1L << 60;
            if (nd == 0 && k == 1) {}                // keep the program order of the pair
            for (int o : open_ids) x.bm |= 1u << o;
            if (rng() % 5 == 0 && (int)open_ids.size() < NCK) {   // it opens a checkpoint after it
                int o; do { o = rng() % NCK; } while (std::find(open_ids.begin(), open_ids.end(), o) != open_ids.end());
                open_ids.push_back(o);
            }
            recent.push_back(t0);
            nd++;
        }
        // external announcements due now
        int extv = 0; uint32_t extt = 0; int ne = 0;
        std::vector<std::pair<long, int>> keep;
        for (auto& e : ext_due) {
            if (e.first <= cyc && ne < 2) {
                extv |= 1 << ne; extt |= (uint32_t)e.second << (6 * ne); ne++;
                avail[e.second] = cyc + 1; tag_free_at[e.second] = cyc + 4;
            }
            else keep.push_back(e);
        }
        ext_due.swap(keep);

        // drive
        d.flush = flush;
        d.kill = kill_id >= 0 ? 1u << kill_id : 0;
        d.clr = clr_id >= 0 ? 1u << clr_id : 0;
        unsigned clrm = clr_id >= 0 ? 1u << clr_id : 0, killm = kill_id >= 0 ? 1u << kill_id : 0;
        d.disp_valid = (nd >= 1 ? 1 : 0) | (nd >= 2 ? 2 : 0);
        uint32_t port = 0, use = 0, rdy = 0, wr = 0, lat2 = 0, dst = 0, src = 0, bmw = 0;
        for (int k = 0; k < nd; k++) {
            Uop& x = u[k];
            port |= x.port << (2 * k); lat2 |= x.lat2 << k;
            for (int s = 0; s < 2; s++) {
                use |= x.use[s] << (2 * k + s);
                src |= (uint32_t)x.src[s] << (6 * (2 * k + s));
                rdy |= (avail[x.src[s]] <= cyc) << (2 * k + s);
            }
            wr |= x.wr << k; dst |= (uint32_t)x.dst << (6 * k);
            bmw |= (uint32_t)x.bm << (6 * k);
        }
        d.disp_port = port; d.disp_use = use; d.disp_src = src; d.disp_rdy = rdy;
        d.disp_wr = wr; d.disp_dst = dst; d.disp_lat2 = lat2; d.disp_bm = bmw;
        d.ext_valid = extv; d.ext_tag = extt;
        d.eval();
        // the entries given to the µops dispatched now: not one in use
        for (int k = 0; k < nd; k++) {
            u[k].entry = (int)((d.disp_entry >> (4 * k)) & 15);
            for (auto& kv : q) if (kv.second.entry == u[k].entry && bad++ < 10)
                printf("MISMATCH cycle %ld: disp_entry %d of slot %d is in use (p%d)\n", cyc, u[k].entry, k, kv.first);
        }
        if (nd == 2 && u[0].entry == u[1].entry && bad++ < 10) printf("MISMATCH cycle %ld: both slots to entry %d\n", cyc, u[0].entry);
        if (getenv("IQ_DEBUG") && cyc >= atol(getenv("IQ_DEBUG")) && cyc < atol(getenv("IQ_DEBUG")) + 7) {
            printf("cycle %ld disp_ready %d nd %d flush %d iss_valid %d\n", cyc, (int)d.disp_ready, nd, flush, (int)d.iss_valid);
            for (int k = 0; k < nd; k++) printf("  disp p%d port %d use %d%d src %d %d rdy %d%d\n", u[k].dst, u[k].port,
                u[k].use[0], u[k].use[1], u[k].src[0], u[k].src[1],
                avail[u[k].src[0]] <= cyc, avail[u[k].src[1]] <= cyc);
            for (auto& kv : q) { const Uop& x = kv.second; bool r = x.disp < cyc; for (int s2 = 0; s2 < 2; s2++) if (x.use[s2] && avail[x.src[s2]] > cyc) r = false;
                printf("  inq p%d id %ld port %d disp %ld ready %d\n", kv.first, x.id, x.port, x.disp, r); }
        }

        // ---- what must issue now
        auto ready = [&](const Uop& x) {
            if (x.disp >= cyc) return false;
            for (int s = 0; s < 2; s++) if (x.use[s] && avail[x.src[s]] > cyc) return false;
            return true;
        };
        const Uop* e0 = nullptr; const Uop* e1 = nullptr; const Uop* e2 = nullptr;
        for (auto& kv : q) {
            const Uop& x = kv.second;
            if (!ready(x)) continue;
            if (x.port == 2) { if (!e2 || x.id < e2->id) e2 = &x; }
            else if (x.port == 0 && (!e1 || x.id < e1->id)) e1 = &x;
        }
        for (auto& kv : q) {
            const Uop& x = kv.second;
            if (!ready(x) || x.port == 2 || &x == e1) continue;
            if (!e0 || x.id < e0->id) e0 = &x;
        }
        const Uop* exp[3] = {e0, e1, e2};
        if (!flush) {
            for (int p = 0; p < 3; p++) {
                bool v = (d.iss_valid >> p) & 1;
                int t = (int)((d.iss_dst >> (6 * p)) & 0x3f);
                bool ok = v == (exp[p] != nullptr) && (!v || t == exp[p]->dst);
                if (!ok && bad++ < 10)
                    printf("MISMATCH cycle %ld port %d: issued %d (p%d), expected %s (p%d)\n", cyc, p, v, t,
                           exp[p] ? "one" : "none", exp[p] ? exp[p]->dst : 0);
                if (ok && v) {
                    unsigned gb = (unsigned)((d.iss_bm >> (6 * p)) & 63), eb = exp[p]->bm & ~clrm;
                    if (gb != eb && bad++ < 10) printf("MISMATCH cycle %ld port %d (p%d): iss_bm %02x, expected %02x\n", cyc, p, t, gb, eb);
                    int en = (int)((d.iss_entry >> (4 * p)) & 15);
                    if (en != exp[p]->entry && bad++ < 10)
                        printf("MISMATCH cycle %ld port %d (p%d): iss_entry %d, expected %d\n", cyc, p, t, en, exp[p]->entry);
                }
            }
        }

        // ---- the clock, and the account after it (what issued is read before the edge)
        unsigned issued_now = d.iss_valid;
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if (flush) {
            for (auto& kv : q) {
                Uop& x = kv.second;
                for (int s2 = 0; s2 < 2; s2++) if (x.use[s2]) refs[x.src[s2]]--;
                avail[x.dst] = cyc + 1; tag_free_at[x.dst] = cyc + 4;
            }
            q.clear();
            open_ids.clear();
            flushes++;
        } else {
            for (int p = 0; p < 3; p++) {
                if (!((issued_now >> p) & 1) || !exp[p]) continue;
                Uop x = *exp[p];
                q.erase(x.dst);
                for (int s2 = 0; s2 < 2; s2++) if (x.use[s2]) refs[x.src[s2]]--;
                issued_n++;
                int lat = x.lat2 ? 2 : 1;
                if (x.wr) avail[x.dst] = cyc + lat;
                // an external answer holds its tag until it is announced
                if (x.ext) ext_due.push_back({cyc + 3 + (long)(rng() % 8), x.dst});
                else tag_free_at[x.dst] = cyc + 4;
            }
            // the killed µops leave (not the ones issued now: they left already)
            if (killm) {
                nkill++;
                for (auto it = q.begin(); it != q.end();) {
                    Uop& x = it->second;
                    if (x.bm & killm) {
                        for (int s2 = 0; s2 < 2; s2++) if (x.use[s2]) refs[x.src[s2]]--;
                        avail[x.dst] = cyc + 1; tag_free_at[x.dst] = cyc + 4; nkilled++;
                        it = q.erase(it);
                    } else ++it;
                }
            }
            if (clrm) { nclr++; for (auto& kv : q) kv.second.bm &= ~clrm; }
            for (int k = 0; k < nd; k++) {
                u[k].disp = cyc; q[u[k].dst] = u[k];
                for (int s2 = 0; s2 < 2; s2++) if (u[k].use[s2]) refs[u[k].src[s2]]++;
            }
        }
    }
    printf("tb_iq: %ld cycles, %ld µops issued, %ld kills (%ld µops killed), %ld clears, %ld flushes, %ld mismatches: %s\n",
           cyc, issued_n, nkill, nkilled, nclr, flushes, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
