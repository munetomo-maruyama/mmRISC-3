//---------------------------------------------------------------------------
// tb_sched.cpp : OOO_SCHED (3 ALU queues of 8, a memory queue of 12, 4 µops
// dispatched a cycle, 7-bit tags) against an account of when every value can
// be used, kept independently of the block's own bits
//
//   a µop issued in cycle c with latency L makes its result usable by µops
//   issued from c + L; a result announced on ext_* in cycle c from c + 1.
//
// Every cycle, for each queue, the oldest µop dispatched in an earlier cycle,
// not issued, with all its sources usable and none of the rules below against
// it must be the one issued, and the only one: rr_* shows it the next cycle.
//   - a load waits for every older store to have issued, a non-speculative
//     µop for every older one to have left its entry, in any queue
//   - a non-speculative µop needs ns_ok, and no non-speculative issue in the
//     cycle before; an MDU µop the same with mdu_ok
//   - a queue has one write port: a writer of latency L does not issue if a
//     µop of its queue already takes the slot of c + L; in queue 0 a writer of
//     latency 1 does not issue with q0_hold
//
// Dispatch: disp_go is checked in full: the queue each slot should go to (any
// ALU: the queues as full as they were in the last cycle, emptiest first, then
// in turn), a prefix, as long as the queue has an entry and one of 2 write
// ports. An entry keeps its µop until its dependents have been told (c + L - 1,
// or the cycle of ext_*): disp_e must be free, and is where the issue is
// looked for after (rr_entry).
//
// Branch masks (OOO_CTRL): the bench keeps the checkpoint ids open in program
// order; a µop takes them as its mask. A kill of an open id, in a cycle without
// dispatch: the µops with its bit leave and the ids opened after it close; a
// µop issued in that cycle is not seen in rr_*. A clear of an open id takes
// its bit from every mask. rr_bm is checked (the mask after the clear of its
// issue's cycle). Now and then a flush. The bench gives no external result for
// a µop killed.
//
// Everything is random but what a real group needs: tags unique in flight,
// sources from older µops still alive or values long done.
//---------------------------------------------------------------------------
#include "VOOO_SCHED.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <list>
#include <random>
#include <vector>

static const int NQ = 3, QN[4] = {8, 8, 8, 12}, W = 4, NT = 128, NCK = 12, NEXT = 2;
static const long NEVER = 1L << 60;

struct Uop {
    long id, disp, issued = -1, clr_at = NEVER;
    int q, e, kind, use[2], src[2], wr, dst, lat, ext, ns, md, st;
    unsigned bm;
    long ext_at = NEVER;
};

static std::mt19937 rng(7);
static VOOO_SCHED d;
static inline unsigned bits(uint64_t v, int lo, int n) { return (v >> lo) & ((1ULL << n) - 1); }

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("SCHED_SEED")) rng.seed((unsigned)strtoul(e, nullptr, 0));
    d.clk = 0; d.flush = 0; d.kill = 0; d.clr = 0; d.disp_valid = 0; d.ext_valid = 0;
    d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    std::list<Uop> uops;                    // in the entries, oldest first
    long avail[NT]; int refs[NT]; bool inflight[NT]; long tag_free_at[NT]; int prod_q[NT] = {}; bool dead[NT] = {};
    for (int t = 0; t < NT; t++) { avail[t] = 0; refs[t] = 0; inflight[t] = false; tag_free_at[t] = 0; }
    std::vector<int> open_ids;
    int rk[NQ] = {0, 1, 2};
    std::vector<long> wslot[NQ];            // the write slots taken, by queue
    int exp_v[4] = {0, 0, 0, 0}, exp_e[4] = {0, 0, 0, 0}; unsigned exp_bm[4] = {0, 0, 0, 0};
    int exp_ns = 0, exp_md = 0;
    long next_id = 0, bad = 0, nissued = 0, nb2b = 0, ncross = 0, nkilled = 0, nflush = 0, nstall = 0, ndisp = 0;
    long nlat[5] = {0, 0, 0, 0, 0}, nload_w = 0, nns = 0, nmd = 0, ngrp[5] = {0, 0, 0, 0, 0};
    int rate = 4;

    for (long cyc = 0; cyc < 400000; cyc++) {
        // ---- what the last cycle issued, seen now
        for (int q = 0; q <= NQ; q++) {
            int rv = (d.rr_valid >> q) & 1, re = bits(d.rr_entry, 4 * q, 4);
            unsigned rb = bits(d.rr_bm, 12 * q, 12);
            if (rv != exp_v[q] || (rv && (re != exp_e[q] || rb != exp_bm[q]))) {
                if (bad++ < 12) printf("MISMATCH cycle %ld: queue %d issued %d entry %d mask %03x, expected %d entry %d mask %03x\n",
                                       cyc, q, rv, re, rb, exp_v[q], exp_e[q], exp_bm[q]);
            }
        }
        if ((int)d.rr_ns != exp_ns || (int)d.rr_md != exp_md) {
            if (bad++ < 12) printf("MISMATCH cycle %ld: rr_ns %d rr_md %d, expected %d %d\n", cyc, d.rr_ns, d.rr_md, exp_ns, exp_md);
        }
        int ns_last = exp_ns, md_last = exp_md;

        // ---- entries whose µops are done leave
        for (auto it = uops.begin(); it != uops.end(); ) {
            if (it->clr_at < cyc) {
                inflight[it->dst] = false; tag_free_at[it->dst] = cyc + 2;
                it = uops.erase(it);
            } else ++it;
        }
        int cnt[4] = {0, 0, 0, 0}; bool used[4][12] = {};
        for (auto& u : uops) { cnt[u.q]++; used[u.q][u.e] = true; }

        // ---- inputs of this cycle
        if (rng() % 5000 == 0) rate = 1 + rng() % 4;
        int flush = rng() % 3000 == 0;
        int kill_id = -1, clr_id = -1;
        if (!flush && !open_ids.empty() && rng() % 60 == 0) {
            size_t i = rng() % open_ids.size();
            kill_id = open_ids[i];
            open_ids.resize(i);
        }
        if (!flush && !open_ids.empty() && rng() % 5 == 0) {
            size_t i = rng() % open_ids.size();
            clr_id = open_ids[i];
            open_ids.erase(open_ids.begin() + i);
        }
        d.flush = flush;
        d.kill = kill_id >= 0 ? 1u << kill_id : 0;
        d.clr  = clr_id >= 0 ? 1u << clr_id : 0;
        d.ns_ok = rng() % 4 != 0;
        d.mdu_ok = rng() % 4 != 0;
        d.q0_hold = rng() % 16 == 0;

        // external results due
        unsigned xv = 0, xe = 0; int nx = 0;
        for (auto& u : uops) if (u.issued >= 0 && u.ext && u.ext_at <= cyc && u.clr_at == NEVER && nx < NEXT) {
            int base = u.q == NQ ? 24 : u.q * 8;
            xv |= 1u << nx; xe |= (unsigned)(base + u.e) << (6 * nx); nx++;
            u.clr_at = cyc;
            if (u.wr) avail[u.dst] = cyc + 1;
        }
        d.ext_valid = xv; d.ext_entry = xe;

        // the group: regenerated every cycle, what does not go is forgotten
        std::vector<Uop> g;
        std::vector<int> taken, rd;             // the group's destinations, its sources
        int nd = (kill_id >= 0 || flush) ? 0 : rng() % (rate + 1);
        unsigned mask = 0;
        for (int id : open_ids) mask |= 1u << id;
        for (int k = 0; k < nd; k++) {
            Uop x{};
            int r = rng() % 16;
            x.kind = r < 9 ? 0 : r < 11 ? 1 : 2;
            x.wr = 1; x.lat = 1;
            if (x.kind == 0) { if (rng() % 8 == 0) x.lat = 2; if (rng() % 6 == 0) { x.wr = 0; x.lat = 1; } }
            else if (x.kind == 1) {
                int c = rng() % 10;
                if (c < 2) x.lat = 2;
                else if (c < 5) x.lat = 4;
                else if (c < 7) { x.ext = 1; x.md = 1; }
                else if (c < 8) { x.ns = 1; if (rng() % 2) x.ext = 1; }
            } else {
                int c = rng() % 10;
                if (c < 6) x.lat = 3;
                else if (c < 9) { x.st = 1; x.wr = 0; }
                else { x.ns = 1; x.ext = 1; }
            }
            // a new destination tag
            int t = -1;
            for (int tr = 0; tr < 40 && t < 0; tr++) {
                int c = rng() % NT;
                if (!inflight[c] && refs[c] == 0 && tag_free_at[c] <= cyc && std::find(taken.begin(), taken.end(), c) == taken.end() &&
                    std::find(rd.begin(), rd.end(), c) == rd.end()) t = c;
            }
            if (t < 0) break;
            taken.push_back(t);
            x.dst = t;
            // sources: an older µop that writes, or a value done
            for (int s = 0; s < 2; s++) {
                x.use[s] = rng() % 4 != 0;
                if (x.st && s == 1) x.use[s] = 0;      // the data joins in the SQ
                x.src[s] = rng() % NT;
                if (x.use[s]) {
                    std::vector<int> cand;
                    for (auto& u : uops) if (u.wr && u.clr_at >= cyc) cand.push_back(u.dst);
                    for (auto& y : g) if (y.wr) cand.push_back(y.dst);
                    if (!cand.empty() && rng() % 8 != 0) x.src[s] = cand[rng() % cand.size()];
                    else {
                        int c = -1;
                        for (int tr = 0; tr < 40 && c < 0; tr++) {
                            int z = rng() % NT;
                            if (!inflight[z] && !dead[z] && std::find(taken.begin(), taken.end(), z) == taken.end()) c = z;
                        }
                        if (c < 0) x.use[s] = 0; else x.src[s] = c;
                    }
                }
            }
            for (int s = 0; s < 2; s++) if (x.use[s]) rd.push_back(x.src[s]);
            x.bm = mask;
            if (rng() % 8 == 0) {                // it opens a checkpoint after it
                std::vector<int> fr;
                for (int i = 0; i < NCK; i++) if (!(mask >> i & 1) && i != kill_id && i != clr_id) fr.push_back(i);
                x.ext_at = fr.empty() ? -1 : fr[rng() % fr.size()];   // (kept here until it is known to go)
            } else x.ext_at = -1;
            if (x.ext_at >= 0) mask |= 1u << x.ext_at;
            g.push_back(x);
        }
        // the inputs
        {
            unsigned dv = 0, dk = 0, du = 0, dw = 0, dd = 0, dl = 0, dx = 0, dn = 0, dm = 0, dt = 0;
            uint64_t ds = 0, db = 0;
            for (size_t k = 0; k < g.size(); k++) {
                Uop& x = g[k];
                dv |= 1u << k; dk |= (unsigned)x.kind << (2 * k);
                du |= (unsigned)(x.use[0] | (x.use[1] << 1)) << (2 * k);
                ds |= (uint64_t)(x.src[0] | (x.src[1] << 7)) << (14 * k);
                // the fields that do not count have any value: the destination of a µop that
                // writes nothing (often a tag being read), the latency of an external one
                unsigned ddk = x.wr ? x.dst : (!rd.empty() && rng() % 2) ? rd[rng() % rd.size()] : rng() % NT;
                dw |= (unsigned)x.wr << k; dd |= ddk << (7 * k);
                dl |= (unsigned)(x.ext ? rng() % 4 : x.lat - 1) << (2 * k); dx |= (unsigned)x.ext << k;
                db |= (uint64_t)x.bm << (12 * k);
                dn |= (unsigned)x.ns << k; dm |= (unsigned)x.md << k; dt |= (unsigned)x.st << k;
            }
            d.disp_valid = dv; d.disp_kind = dk; d.disp_use = du; d.disp_src = ds; d.disp_wr = dw; d.disp_dst = dd;
            d.disp_lat = dl; d.disp_ext = dx; d.disp_bm = db; d.disp_ns = dn; d.disp_md = dm; d.disp_st = dt;
        }
        d.eval();

        // ---- the issue of this cycle, by the account
        for (int q = 0; q <= NQ; q++) { exp_v[q] = 0; }
        exp_ns = 0; exp_md = 0;
        std::vector<Uop*> grant;
        for (int q = 0; q <= NQ; q++) {
            Uop* best = nullptr;
            for (auto& u : uops) {
                if (u.q != q || u.issued >= 0) continue;
                bool ok = true;
                for (int s = 0; s < 2; s++) if (u.use[s] && avail[u.src[s]] > cyc) ok = false;
                if (u.ns && (!d.ns_ok || ns_last)) ok = false;
                if (u.md && (!d.mdu_ok || md_last)) ok = false;
                for (auto& y : uops) {
                    if (y.id >= u.id) break;
                    if (y.issued < 0 && y.st && u.q == NQ && !u.st) ok = false;
                    if (y.ns && u.ns && y.clr_at >= cyc) ok = false;   // its column, as a result's
                }
                if (q < NQ && u.wr && !u.ext) {
                    long w = cyc + u.lat;
                    if (std::find(wslot[q].begin(), wslot[q].end(), w) != wslot[q].end()) ok = false;
                    if (q == 0 && u.lat == 1 && d.q0_hold) ok = false;
                }
                if (ok) { best = &u; break; }
            }
            if (best) grant.push_back(best);
        }
        // ---- dispatch
        bool stop = flush != 0;
        int nalu = 0, wrq[4] = {0, 0, 0, 0}, ngo = 0;
        std::vector<Uop> gone;
        for (size_t k = 0; k < (size_t)W; k++) {
            int go = (d.disp_go >> k) & 1;
            if (k >= g.size()) {
                if (go && bad++ < 12) printf("MISMATCH cycle %ld: slot %zu goes, not valid\n", cyc, k);
                continue;
            }
            Uop x = g[k];
            int q = x.kind == 2 ? NQ : x.kind == 1 ? 0 : rk[nalu % NQ];
            bool room = wrq[q] < 2 && cnt[q] + wrq[q] < QN[q];
            bool exp_go = !stop && room;
            if (go != (int)exp_go && bad++ < 12)
                printf("MISMATCH cycle %ld: slot %zu go %d, expected %d (queue %d, %d in it)\n", cyc, k, go, exp_go, q, cnt[q]);
            if (!go) { stop = true; if (!room) nstall++; continue; }
            int dq = bits(d.disp_q, 2 * k, 2), de = bits(d.disp_e, 4 * k, 4);
            if (dq != q && bad++ < 12) printf("MISMATCH cycle %ld: slot %zu to queue %d, expected %d\n", cyc, k, dq, q);
            if ((de >= QN[q] || used[q][de]) && bad++ < 12) printf("MISMATCH cycle %ld: slot %zu to entry %d of queue %d, in use\n", cyc, k, de, q);
            if (de < 12) used[q][de] = true;
            x.q = q; x.e = de; x.id = next_id++; x.disp = cyc;
            if (x.ext_at >= 0) open_ids.push_back((int)x.ext_at);
            x.ext_at = NEVER;
            wrq[q]++;
            if (x.kind == 0) nalu++;
            gone.push_back(x);
            ngo++;
        }
        ngrp[ngo]++;
        ndisp += ngo;
        // ---- account for the grants: they stand even if killed now
        for (Uop* u : grant) {
            u->issued = cyc;
            exp_v[u->q] = 1; exp_e[u->q] = u->e;
            unsigned bm = u->bm;
            if (clr_id >= 0) bm &= ~(1u << clr_id);
            exp_bm[u->q] = bm;
            exp_ns |= u->ns; exp_md |= u->md;
            for (int s = 0; s < 2; s++) if (u->use[s]) refs[u->src[s]]--;
            if (u->ns) nns++;
            if (u->md) nmd++;
            nissued++;
            if (!u->ext) {
                nlat[u->lat]++;
                u->clr_at = cyc + u->lat - 1;
                if (u->wr) avail[u->dst] = cyc + u->lat;
                if (u->q < NQ && u->wr) wslot[u->q].push_back(cyc + u->lat);
            } else {
                u->ext_at = cyc + 2 + rng() % 8;
            }
            for (int s = 0; s < 2; s++) if (u->use[s] && avail[u->src[s]] == cyc) {
                nb2b++;
                if (prod_q[u->src[s]] != u->q) ncross++;
            }
        }
        for (int q = 0; q < NQ; q++)
            wslot[q].erase(std::remove_if(wslot[q].begin(), wslot[q].end(), [&](long w) { return w <= cyc; }), wslot[q].end());
        for (Uop& x : gone) {
            for (int s = 0; s < 2; s++) if (x.use[s]) refs[x.src[s]]++;
            inflight[x.dst] = true;
            if (x.wr) avail[x.dst] = NEVER;
            prod_q[x.dst] = x.q;
            if (x.wr) dead[x.dst] = false;
            uops.push_back(x);
        }
        // ---- kill, flush, clear
        auto drop = [&](Uop& u) {
            if (u.issued < 0) for (int s = 0; s < 2; s++) if (u.use[s]) refs[u.src[s]]--;
            inflight[u.dst] = false; avail[u.dst] = 0; tag_free_at[u.dst] = cyc + 2;
            dead[u.dst] = true;                 // read by nobody until it is given out again
        };
        if (flush) {
            nflush++;
            for (auto& u : uops) drop(u);
            uops.clear();
            open_ids.clear();
            for (int q = 0; q < NQ; q++) wslot[q].clear();
            for (int q = 0; q <= NQ; q++) exp_v[q] = 0;
            exp_ns = 0; exp_md = 0;
        } else if (kill_id >= 0) {
            for (auto it = uops.begin(); it != uops.end(); ) {
                if (it->bm >> kill_id & 1) {
                    if (it->issued == cyc) {
                        exp_v[it->q] = 0;
                        // not seen in rr_*, so not in the guards either
                        if (it->ns) exp_ns = 0;
                        if (it->md) exp_md = 0;
                    }
                    nkilled++;
                    drop(*it);
                    it = uops.erase(it);
                } else ++it;
            }
        }
        if (clr_id >= 0) for (auto& u : uops) u.bm &= ~(1u << clr_id);
        // ---- the ALU queues by how full, as the block saw them this cycle
        {
            int c0[NQ], o[NQ];
            for (int q = 0; q < NQ; q++) { c0[q] = cnt[q]; o[q] = q; }
            std::stable_sort(o, o + NQ, [&](int a, int b) { return c0[a] < c0[b]; });
            for (int q = 0; q < NQ; q++) rk[q] = o[q];
        }
        // ---- the clock
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
    }
    bool cov = nissued > 100000 && nb2b > 10000 && ncross > 5000 && nkilled > 1000 && nflush > 50 &&
               nlat[2] > 1000 && nlat[3] > 1000 && nlat[4] > 1000 && nns > 500 && nmd > 500 && ngrp[4] > 1000 && nstall > 1000;
    printf("tb_sched: %ld issued (%ld, %ld, %ld, %ld at latency 1, 2, 3, 4; %ld MDU, %ld non-speculative), %ld back to back (%ld across queues), %ld killed, %ld flushes, %ld stalls, %ld groups of 4: %ld mismatches: %s\n",
           nissued, nlat[1], nlat[2], nlat[3], nlat[4], nmd, nns, nb2b, ncross, nkilled, nflush, nstall, ngrp[4], bad,
           bad == 0 && cov ? "PASS" : "FAIL");
    return bad != 0 || !cov;
}
