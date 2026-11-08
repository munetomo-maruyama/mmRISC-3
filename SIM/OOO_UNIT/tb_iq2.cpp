//---------------------------------------------------------------------------
// tb_iq2.cpp : OOO_IQ2 (24 entries in 4 banks, 4 µops in, 6 ports, 2 sources and 1
// destination per µop, 7-bit tags) against an account of when every value can be
// used, kept independently of the queue's own bits, as tb_iq.cpp
//
//   a µop issued in cycle c with latency 1 (ALU) makes its results usable
//   by µops issued from c + 1, with latency 2 (load, multiply) from c + 2;
//   a value announced on ext_* in cycle c is usable from c + 1.
//
// Every cycle, the µops in the queue (dispatched in an earlier cycle), not issued, with
// all sources usable are "ready". The queue must issue, from the ready any-ALU µops in
// age order: the 1st on port 3, the 2nd on port 2, the 3rd on port 1 unless it writes in
// the cycle after a multiply (then port 1 idles), and on port 0 the older of: the 4th
// (unless p0_hold and it writes) and the oldest ready ALU0-only µop that mdu_ok and p0_hold
// let go, this one only with at most 3 any-ALU µops older. On port 5 the oldest ready
// load, on port 4 the oldest ready LSU µop of the rest; nothing else. That checks the
// wakeup (back to back for latency 1), the select (oldest first, no port idle while
// a µop is ready for it) and that nothing issues early or twice.
//
// Also checked: disp_ready (the banks with a free entry as the last cycle left them)
// and disp_entry (the k-th slot: the first free entry of the k-th bank with one), that
// iss_entry is the entry of the issued µop, iss_bm (the entry's, before this cycle's
// clear), iss_md, iss_ns, and the wakeup tags bus by bus (those of latency 2 are not
// sent for a µop killed or flushed as it issues). Non-speculative µops: ready only with
// ns_ok and no older one queued. A load: ready only with no older store queued.
//
// In some phases the external answers are held back, and more µops read what is not
// answered, so that the queue fills and the banks run out.
//---------------------------------------------------------------------------
#include "VOOO_IQ2.h"
#ifndef NA
#define NA 4                    // the ALU ports in use (-DNA=2: with -GNA=2 -GP5=0)
#endif
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
    long disp;
    int entry = -1;     // its entry (disp_entry), where the payload is
    unsigned bm = 0;    // its branch mask
    int ns = 0;         // non-speculative
    int md = 0;         // an MDU µop
    int st = 0;         // a store
};

static std::mt19937 rng(5);
static VOOO_IQ2 d;

// a field of a wide output
static unsigned wbits(const uint32_t* w, int lsb, int n) {
    uint64_t x = w[lsb / 32];
    if (lsb % 32 + n > 32) x |= (uint64_t)w[lsb / 32 + 1] << 32;
    return (unsigned)((x >> (lsb % 32)) & ((1ull << n) - 1));
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("IQ_SEED")) rng.seed((unsigned)strtoul(e, nullptr, 0));
    const int NQ = 24, BS = 6;              // entries, entries in a bank
    d.clk = 0; d.flush = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    const int NT = 128;                     // 7-bit tags
    const int TW = 7;
    long avail[NT];                         // cycle from which the value is usable
    long tag_free_at[NT];                   // when a tag may be used again
    int refs[NT];                           // queued µops that read the tag: it cannot be given out again
    static bool nowr[NT] = {false};         // the tag's last µop writes nothing
    for (int t = 0; t < NT; t++) { avail[t] = 0; tag_free_at[t] = 0; refs[t] = 0; }
    std::map<int, Uop> q;                   // in the queue, by destination tag
    std::vector<std::pair<long, int>> ext_due;   // (cycle, tag) to announce on ext
    long next_id = 0, bad = 0, issued_n = 0, flushes = 0, nkill = 0, nkilled = 0, nclr = 0, nns = 0;
    long nwk = 0, nport[6] = {0}, nsix = 0, nfull = 0, nlow = 0, nblk1 = 0, nst = 0, nidle0 = 0, ngap = 0;
    std::vector<int> open_ids;              // checkpoint ids open, in program order
    const int NCK = 12;
    long cyc;
    int pd0_v = 0, pd0_t = 0, pd4_v = 0, pd4_t = 0, pd5_v = 0, pd5_t = 0;    // the delayed wakeups due now
    for (cyc = 0; cyc < 400000; cyc++) {
        bool hold = ((cyc >> 9) & 3) == 3;  // the answers held back
        // ---- disp_ready, disp_entry: from the queue as the last cycle left it
        int exp_e[4], exp_ready = 0;
        {
            bool used[NQ] = {false};
            for (auto& kv : q) used[kv.second.entry] = true;
            for (int b = 0; b < 4; b++) {
                for (int i = 0; i < BS; i++) if (!used[b * BS + i]) { exp_e[exp_ready++] = b * BS + i; break; }
            }
            d.eval();
            if ((int)d.disp_ready != exp_ready && bad++ < 10)
                printf("MISMATCH cycle %ld: disp_ready %d, expected %d (%d entries)\n", cyc, (int)d.disp_ready, exp_ready, (int)q.size());
            if (q.size() >= 23) nfull++;
            if (exp_ready < 4) nlow++;
        }
        // ---- inputs of this cycle
        int ndisp = rng() % 5;
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
        for (auto& e : ext_due) recent.push_back(e.second);
        Uop u[4];
        int nd = 0;
        for (int k = 0; k < ndisp; k++) {   // (in a flush too: those µops are lost with the rest)
            if (k >= exp_ready) break;
            Uop& x = u[nd];
            int t0 = -1;
            for (int tries = 0; tries < 50; tries++) {
                int t = 1 + (int)(rng() % (NT - 1));
                // (not a tag an older µop of the same group reads: that would be a
                // dependence on a younger µop, which a kill of it makes visible)
                bool rd0 = false;
                for (int o = 0; o < nd; o++) rd0 |= (u[o].use[0] && u[o].src[0] == t) || (u[o].use[1] && u[o].src[1] == t);
                if (tag_free_at[t] <= cyc && !q.count(t) && !refs[t] && !rd0) { t0 = t; break; }
            }
            if (t0 < 0) break;
            x.id = next_id++;
            x.port = (int[]){0, 0, 0, 0, 1, 2, 2, 2}[rng() % 8];
            x.lat2 = x.port == 2 ? (rng() % 4 != 0) : x.port == 1 ? (rng() & 1) : 0;   // ALU0 only: a multiply or a complex ALU operation
            x.ext = x.port == 2 && !x.lat2;            // a store, or a load that missed: answer from outside
            x.md = x.port == 1 && !x.lat2 && rng() % 3 == 0;   // an MDU µop: answered from outside
            if (x.md) x.ext = 1;
            x.dst = t0; x.wr = !x.ext && !(x.port == 0 && rng() % 8 == 0);   // (an any-ALU µop that writes nothing: a branch)
            x.ns = (x.port == 1 || x.port == 2) && rng() % 8 == 0;
            x.st = x.port == 2 && x.ext && (rng() & 1);
            x.bm = 0; x.disp = 0; x.entry = -1;
            for (int s = 0; s < 2; s++) {
                x.use[s] = rng() % 3 != 0;
                if (!recent.empty() && rng() % (hold ? 8 : 3)) x.src[s] = recent[rng() % recent.size()];
                else x.src[s] = 1 + (int)(rng() % (NT - 1));
                if (x.src[s] == t0) x.use[s] = 0;
                if (nowr[x.src[s]]) x.use[s] = 0;        // (a µop that writes nothing gives no value)
            }
            tag_free_at[t0] = 1L << 60;
            nowr[t0] = !x.wr && !x.ext;
            avail[t0] = 1L << 60;
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
            if (e.first <= cyc && ne < 2 && !hold) {
                extv |= 1 << ne; extt |= (uint32_t)e.second << (TW * ne); ne++;
                avail[e.second] = cyc + 1; tag_free_at[e.second] = cyc + 4;
            }
            else keep.push_back(e);
        }
        ext_due.swap(keep);

        // drive
        d.flush = flush;
        int ns_ok = rng() % 2;
        d.ns_ok = ns_ok;
        int mdu_ok = rng() % 3 != 0, p0_hold = rng() % 6 == 0;
        d.mdu_ok = mdu_ok; d.p0_hold = p0_hold;
        bool blk0 = p0_hold, blk1 = pd0_v;
        d.kill = kill_id >= 0 ? 1u << kill_id : 0;
        d.clr = clr_id >= 0 ? 1u << clr_id : 0;
        unsigned clrm = clr_id >= 0 ? 1u << clr_id : 0, killm = kill_id >= 0 ? 1u << kill_id : 0;
        // the µops in slots, oldest lowest, with gaps now and then
        int pos[4];
        {
            unsigned mask = 0;
            if (rng() & 1) mask = (1u << nd) - 1;
            else while (__builtin_popcount(mask) != nd) mask = rng() & 15;
            int k = 0;
            for (int i = 0; i < 4; i++) if ((mask >> i) & 1) pos[k++] = i;
            d.disp_valid = mask;
            d.disp_cand = mask ? mask : rng() & 15;     // the slots that go if any do (none goes: the banks are given, nothing written)
            if (mask != (1u << nd) - 1) ngap++;
        }
        uint64_t src = 0, dst = 0, bmw = 0;
        uint32_t port = 0, use = 0, rdy = 0, wr = 0, lat2 = 0, nsw = 0, mdw = 0, stw = 0;
        for (int k = 0; k < nd; k++) {
            Uop& x = u[k];
            int ps = pos[k];
            port |= x.port << (2 * ps); lat2 |= x.lat2 << ps;
            for (int s = 0; s < 2; s++) {
                use |= x.use[s] << (2 * ps + s);
                src |= (uint64_t)x.src[s] << (TW * (2 * ps + s));
                rdy |= (avail[x.src[s]] <= cyc) << (2 * ps + s);
            }
            wr |= x.wr << ps; dst |= (uint64_t)x.dst << (TW * ps);
            bmw |= (uint64_t)x.bm << (NCK * ps);
            nsw |= (uint32_t)x.ns << ps;
            mdw |= (uint32_t)x.md << ps;
            stw |= (uint32_t)x.st << ps;
        }
        {   // a slot not valid holds anything
            unsigned jm = ~(unsigned)d.disp_valid & 15;
            nsw |= rng() & jm; stw |= rng() & jm; mdw |= rng() & jm; wr |= rng() & jm; lat2 |= rng() & jm;
            for (int k = 0; k < 4; k++) if ((jm >> k) & 1) port |= (rng() & 3) << (2 * k);
        }
        d.disp_port = port; d.disp_use = use; d.disp_src = src; d.disp_rdy = rdy;
        d.disp_wr = wr; d.disp_dst = dst; d.disp_lat2 = lat2; d.disp_bm = bmw; d.disp_ns = nsw; d.disp_md = mdw; d.disp_st = stw;
        d.ext_valid = extv; d.ext_tag = extt;
        d.eval();
        for (int k = 0; k < nd; k++) {
            u[k].entry = exp_e[k];
            int e = (d.disp_entry >> (5 * pos[k])) & 31;
            if (e != exp_e[k] && bad++ < 10) printf("MISMATCH cycle %ld: disp_entry of slot %d %d, expected %d\n", cyc, pos[k], e, exp_e[k]);
        }

        // ---- what must issue now
        auto ready = [&](const Uop& x) {
            if (x.disp >= cyc) return false;
            if (x.ns) {                             // only at the head: ns_ok, and no older one queued
                if (!ns_ok) return false;
                for (auto& kv2 : q) if (kv2.second.ns && kv2.second.id < x.id) return false;
            }
            if (x.port == 2 && !x.st)               // a load: no older store queued
                for (auto& kv2 : q) if (kv2.second.st && kv2.second.id < x.id) return false;
            for (int s = 0; s < 2; s++) if (x.use[s] && avail[x.src[s]] > cyc) return false;
            return true;
        };
        const Uop* exp[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
        auto pick = [&](auto cond) {
            const Uop* b = nullptr;
            for (auto& kv : q) {
                const Uop& x = kv.second;
                bool taken = false;
                for (int p = 0; p < 6; p++) taken |= exp[p] == &x;
                if (taken || !ready(x) || !cond(x)) continue;
                if (!b || x.id < b->id) b = &x;
            }
            return b;
        };
        {
            std::vector<const Uop*> ra, r0;       // ready any-ALU, ALU0-only µops, by age
            for (auto& kv : q) if (ready(kv.second)) {
                const Uop& x = kv.second;
                if (x.port == 0) ra.push_back(&x);
                else if (x.port == 1 && !(x.md && !mdu_ok) && !(blk0 && x.wr && !x.lat2 && !x.md)) r0.push_back(&x);
            }
            auto by_age = [](const Uop* a, const Uop* b) { return a->id < b->id; };
            std::sort(ra.begin(), ra.end(), by_age);
            std::sort(r0.begin(), r0.end(), by_age);
            if (NA == 4 && ra.size() > 0) exp[3] = ra[0];
            if (NA == 4 && ra.size() > 1) exp[2] = ra[1];
            if (ra.size() > NA - 2 && !(blk1 && ra[NA - 2]->wr)) exp[1] = ra[NA - 2];
            if (ra.size() > NA - 2 && blk1 && ra[NA - 2]->wr) nblk1++;
            const Uop* a4 = ra.size() > NA - 1 ? ra[NA - 1] : nullptr;   // the last ALU port's
            const Uop* o0 = r0.empty() ? nullptr : r0[0];
            if (o0 && (!a4 || o0->id < a4->id)) exp[0] = o0;
            else if (a4 && (!o0 || a4->id < o0->id) && !(blk0 && a4->wr)) exp[0] = a4;
            if (a4 && blk0 && a4->wr && o0 && a4->id < o0->id) nidle0++;
        }
        if (NA == 4) exp[5] = pick([](const Uop& x) { return x.port == 2 && !x.st && !x.ns; });
        exp[4] = pick([](const Uop& x) { return x.port == 2; });
        const Uop* e0 = exp[0]; const Uop* e4 = exp[4]; const Uop* e5 = exp[5];
        if (!flush) {
            bool emd = e0 && e0->md;
            if ((bool)d.iss_md != emd && bad++ < 10) printf("MISMATCH cycle %ld: iss_md %d, expected %d\n", cyc, (int)d.iss_md, emd);
            bool ens = false;
            for (int p = 0; p < 6; p++) ens |= exp[p] && exp[p]->ns;
            if ((bool)d.iss_ns != ens && bad++ < 10) printf("MISMATCH cycle %ld: iss_ns %d, expected %d\n", cyc, (int)d.iss_ns, ens);
            if (ens) nns++;
            int all = 0;
            for (int p = 0; p < 6; p++) {
                bool v = (d.iss_valid >> p) & 1;
                int t = wbits((const uint32_t*)&d.iss_dst, TW * p, TW);
                bool ok = v == (exp[p] != nullptr) && (!v || t == exp[p]->dst);
                if (!ok && bad++ < 10)
                    printf("MISMATCH cycle %ld port %d: issued %d (p%d), expected %s (p%d)\n", cyc, p, v, t,
                           exp[p] ? "one" : "none", exp[p] ? exp[p]->dst : 0);
                if (ok && v) {
                    nport[p]++; all++;
                    if (p == 4 && exp[p]->st) nst++;
                    unsigned gb = wbits(d.iss_bm.data(), NCK * p, NCK), eb = exp[p]->bm;   // (the entry's, before this cycle's clear: the users clear it as they take it)
                    if (gb != eb && bad++ < 10) printf("MISMATCH cycle %ld port %d (p%d): iss_bm %03x, expected %03x\n", cyc, p, t, gb, eb);
                    int en = (int)((d.iss_entry >> (5 * p)) & 31);
                    if (en != exp[p]->entry && bad++ < 10)
                        printf("MISMATCH cycle %ld port %d (p%d): iss_entry %d, expected %d\n", cyc, p, t, en, exp[p]->entry);
                    for (int s = 0; s < 2; s++) {
                        unsigned gs = wbits(d.iss_src.data(), TW * (2 * p + s), TW);
                        if ((int)gs != exp[p]->src[s] && bad++ < 10) printf("MISMATCH cycle %ld port %d (p%d): iss_src %d p%u, expected p%d\n", cyc, p, t, s, gs, exp[p]->src[s]);
                    }
                    if ((int)((d.iss_wr >> p) & 1) != exp[p]->wr && bad++ < 10) printf("MISMATCH cycle %ld port %d (p%d): iss_wr\n", cyc, p, t);
                }
            }
            if (all == 6) nsix++;
        }

        // ---- the wakeup tags of this cycle
        {
            int ev[9] = {0}, et[9] = {0};
            if (!flush) {
                if (e0 && e0->wr && !e0->lat2) { ev[0] = 1; et[0] = e0->dst; }
                for (int p = 1; p < 4; p++) if (exp[p] && exp[p]->wr) { ev[p] = 1; et[p] = exp[p]->dst; }
            }
            ev[4] = pd0_v; et[4] = pd0_t; ev[5] = pd4_v; et[5] = pd4_t; ev[6] = pd5_v; et[6] = pd5_t;
            for (int k = 0; k < 2; k++) if ((extv >> k) & 1) { ev[7 + k] = 1; et[7 + k] = (extt >> (TW * k)) & 127; }
            for (int b = 0; b < 9; b++) {
                if (flush && b < 4) continue;     // what issues in a flush is not followed here
                int gv = (d.wk_valid >> b) & 1, gt = (int)((d.wk_tag >> (TW * b)) & 127);
                if ((gv != ev[b] || (gv && gt != et[b])) && bad++ < 10)
                    printf("MISMATCH cycle %ld: wakeup bus %d %d (p%d), expected %d (p%d)\n", cyc, b, gv, gt, ev[b], et[b]);
                nwk += gv;
            }
            pd0_v = !flush && e0 && e0->lat2 && e0->wr && !(e0->bm & killm); pd0_t = e0 ? e0->dst : 0;
            pd4_v = !flush && e4 && e4->wr && !(e4->bm & killm);               pd4_t = e4 ? e4->dst : 0;
            pd5_v = !flush && e5 && e5->wr && !(e5->bm & killm);               pd5_t = e5 ? e5->dst : 0;
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
            for (int k = 0; k < nd; k++) { avail[u[k].dst] = cyc + 1; tag_free_at[u[k].dst] = cyc + 4; }
            q.clear();
            open_ids.clear();
            flushes++;
        } else {
            for (int p = 0; p < 6; p++) {
                if (!((issued_now >> p) & 1) || !exp[p]) continue;
                Uop x = *exp[p];
                q.erase(x.dst);
                exp[p] = nullptr;
                for (int s2 = 0; s2 < 2; s2++) if (x.use[s2]) refs[x.src[s2]]--;
                issued_n++;
                int lat = x.lat2 ? 2 : 1;
                if (x.bm & killm) {               // issued as it is killed: its value is nobody's
                    avail[x.dst] = cyc + 1; tag_free_at[x.dst] = cyc + 4; nkilled++;
                    continue;
                }
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
    bool cov = (nsix > 100 || NA == 2) && nfull > 1000 && nlow > 1000 && nkill > 1000 && nblk1 > 100 && nst > 1000 && nidle0 > 10 && ngap > 10000;
    for (int p = 0; p < 6; p++) cov = cov && (nport[p] > 10000 || (NA == 2 && (p == 2 || p == 3 || p == 5)));
    printf("tb_iq2: %ld cycles, %ld µops issued (%ld %ld %ld %ld %ld %ld by port, %ld stores, %ld cycles with 6, %ld non-speculative), queue full %ld, banks short %ld, a multiply's slot %ld, %ld kills (%ld µops killed), %ld clears, %ld flushes, %ld wakeups, %ld mismatches: %s\n",
           cyc, issued_n, nport[0], nport[1], nport[2], nport[3], nport[4], nport[5], nst, nsix, nns, nfull, nlow, nblk1, nkill, nkilled, nclr, flushes, nwk, bad, bad == 0 && cov ? "PASS" : "FAIL");
    return bad != 0 || !cov;
}
