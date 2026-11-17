//---------------------------------------------------------------------------
// tb_fiq.cpp : OOO_FIQ (the FP issue queue, step 1.8 U1: 12 entries in 4 banks,
// 4 µops in, port A to the FPU, port B an FP store's data, 3 sources, 6-bit
// tags) against an account of when every value can be used, kept apart from the
// queue's own bits (tb_iq3's way)
//
//   a tag announced on ext_* in cycle c is usable by µops issued from c + 1; a
//   source ready at rename (disp_rdy) is usable at once.
//
// Every cycle, the µops in the queue (dispatched in an earlier cycle) with all
// the sources they use usable are ready. Port A must issue the oldest ready µop
// that is not a store's data, if fpu_ok, and of an FP -> integer one only with
// f2i_ok; port B the oldest ready store's data; nothing else. Checked with the
// issue: its sources, destination, wr, dv, f2i, payload and branch mask (the
// entry's, its resolved bits cleared, not this cycle's). Also: disp_ready (the
// banks with a free entry), that a killed µop never issues after its kill, that
// flush empties the queue, and dispatch with cand but no valid (nothing goes).
// Phases hold the wakeups back (the queue fills, the banks run out), take
// fpu_ok / f2i_ok away, or make the store data plentiful.
//---------------------------------------------------------------------------
#include "VOOO_FIQ.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <random>
#include <vector>

static VOOO_FIQ d;
static std::mt19937 rng(31);
static long bad = 0;
#define FAIL(...) do { if (bad++ < 12) { printf(__VA_ARGS__); printf("\n"); } } while (0)

static const long INF = 1L << 60;
struct U { int use, src[3], wr, dst, sd, dv, f2i, bank; unsigned bm, pl; long seq; };

static unsigned bits(const uint32_t* w, int lo, int n)
{
    unsigned v = 0;
    for (int i = 0; i < n; i++) v |= ((w[(lo + i) >> 5] >> ((lo + i) & 31)) & 1u) << i;
    return v;
}
static void put(uint32_t* w, int lo, int n, unsigned v)
{
    for (int i = 0; i < n; i++) {
        uint32_t m = 1u << ((lo + i) & 31);
        if ((v >> i) & 1) w[(lo + i) >> 5] |= m; else w[(lo + i) >> 5] &= ~m;
    }
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    d.clk = 0; d.rst_n = 1; d.flush = 0; d.kill = 0; d.clr = 0; d.fpu_ok = 1; d.f2i_ok = 1;
    d.disp_valid = 0; d.disp_cand = 0; d.ext_valid = 0;
    d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    long avail[64];
    bool pending[64];
    for (int t = 0; t < 64; t++) { avail[t] = 0; pending[t] = false; }
    std::vector<U> q;                         // in the queue, oldest first
    int occ[4] = {0, 0, 0, 0};
    long seq = 0;
    long nia = 0, nib = 0, nboth = 0, nb2b = 0, ndwk = 0, nkill = 0, nkq = 0, nflush = 0, nfull = 0, nfpu = 0, nf2i = 0, ncand = 0, nclr = 0;

    for (long cyc = 0; cyc < 600000; cyc++) {
        int phase = (cyc >> 10) & 7;
        // ---- the external wakeups of this cycle
        unsigned ev = 0, et = 0;
        std::vector<int> pend;
        for (int t = 0; t < 64; t++) if (pending[t]) pend.push_back(t);
        int hold = phase == 1 || phase == 5;
        for (int b = 0; b < 4 && !pend.empty(); b++) {
            if (rng() % (hold ? 12 : 2)) continue;
            int i = rng() % pend.size();
            int t = pend[i];
            pend.erase(pend.begin() + i);
            ev |= 1u << b; et |= (unsigned)t << (6 * b);
        }
        d.ext_valid = ev; d.ext_tag = et;
        long annnow[64];
        for (int t = 0; t < 64; t++) annnow[t] = 0;
        for (int b = 0; b < 4; b++) if ((ev >> b) & 1) annnow[(et >> (6 * b)) & 63] = 1;

        // ---- fpu_ok, f2i_ok
        bool fok = phase == 2 ? rng() % 4 == 0 : rng() % 8 != 0;
        bool iok = phase == 3 ? rng() % 4 == 0 : rng() % 6 != 0;
        d.fpu_ok = fok; d.f2i_ok = iok;

        // ---- recoveries: a kill of a bit some carry, or a flush
        bool flush = rng() % 3000 == 0;
        unsigned kill = 0, clr = 0;
        if (!flush && rng() % 20 == 0) kill = 1u << (rng() % 12);
        if (rng() % 3 == 0) clr = (1u << (rng() % 12)) & ~kill;
        d.flush = flush; d.kill = kill; d.clr = clr;

        // ---- the expected issues (before this cycle's kill, clr)
        int ea = -1, eb = -1;
        for (size_t i = 0; i < q.size(); i++) {
            U& u = q[i];
            bool ok = true;
            for (int s = 0; s < 3; s++) if (((u.use >> s) & 1) && avail[u.src[s]] > cyc) ok = false;
            if (!ok) continue;
            if (u.sd) { if (eb < 0) eb = (int)i; }
            else if (ea < 0 && fok && (!u.f2i || iok)) ea = (int)i;
            else if (ea < 0 && !fok) nfpu++;
            else if (ea < 0 && u.f2i && !iok) nf2i++;
        }

        // ---- dispatch: up to disp_ready µops, banks in order
        int room = 0;
        for (int b = 0; b < 4; b++) if (occ[b] < 3) room++;
        if (room == 0) nfull++;
        if ((int)d.disp_ready != room) FAIL("cycle %ld: disp_ready %d, expected %d", cyc, (int)d.disp_ready, room);
        int nd = phase == 4 ? rng() % 2 : rng() % 5;
        nd = std::min(nd, room);
        if (flush || kill) nd = 0;            // (OOO_CTRL: nothing is dispatched in a kill or flush cycle)
        bool none = nd > 0 && rng() % 10 == 0;   // cand but no go
        std::vector<U> nu;
        unsigned dv = 0, dc = 0, dw = 0, dd = 0, dsd = 0, ddv = 0, df = 0;
        uint32_t duse = 0, drdy = 0;
        VlWide<3> dsrc; for (int i = 0; i < 3; i++) dsrc[i] = 0;
        uint64_t dbm = 0;
        VlWide<4> dpl; for (int i = 0; i < 4; i++) dpl[i] = 0;
        int bk[4], nb = 0;
        for (int b = 0; b < 4; b++) if (occ[b] < 3) bk[nb++] = b;
        for (int k = 0; k < 4; k++) {
            U u{};
            u.sd = phase == 6 ? rng() % 2 : rng() % 6 == 0;
            u.use = u.sd ? 1 : (rng() % 3 == 0 ? 7 : rng() % 2 ? 3 : 1);
            for (int s = 0; s < 3; s++) {
                // a source from a pending tag or one available
                u.src[s] = rng() % 64;
                if (((u.use >> s) & 1) && rng() % 3 == 0 && !pend.empty()) u.src[s] = pend[rng() % pend.size()];
            }
            u.wr = !u.sd && rng() % 5 != 0;
            u.dv = !u.sd && rng() % 16 == 0;
            u.f2i = !u.sd && !u.dv && rng() % 8 == 0;
            u.dst = rng() % 64;
            u.bm = rng() & 0xfff & rng();
            u.pl = rng();
            unsigned rdy = 0;
            for (int s = 0; s < 3; s++) {
                if (avail[u.src[s]] <= cyc) rdy |= 1u << s;
                if (((u.use >> s) & 1) && !(avail[u.src[s]] <= cyc) && annnow[u.src[s]]) ndwk++;
            }
            if (k < nd) {
                dc |= 1u << k;
                if (!none) dv |= 1u << k;
                u.bank = bk[k];
                u.seq = seq++;
                nu.push_back(u);
            }
            dw |= (unsigned)u.wr << k; dsd |= (unsigned)u.sd << k; ddv |= (unsigned)u.dv << k; df |= (unsigned)u.f2i << k;
            dd |= (unsigned)u.dst << (6 * k);
            duse |= (unsigned)u.use << (3 * k); drdy |= rdy << (3 * k);
            for (int s = 0; s < 3; s++) put(dsrc.data(), (k * 3 + s) * 6, 6, u.src[s]);
            dbm |= (uint64_t)u.bm << (12 * k);
            put(dpl.data(), 32 * k, 32, u.pl);
        }
        if (none) ncand++;
        d.disp_valid = dv; d.disp_cand = dc; d.disp_wr = dw; d.disp_dst = dd; d.disp_sd = dsd; d.disp_dv = ddv; d.disp_f2i = df;
        d.disp_use = duse; d.disp_rdy = drdy; d.disp_src = dsrc; d.disp_bm = dbm; d.disp_pl = dpl;
        d.eval();

        // ---- the issues against the account
        if ((bool)d.ia_valid != (ea >= 0)) FAIL("cycle %ld: ia_valid %d, expected %d", cyc, (int)d.ia_valid, ea >= 0);
        else if (ea >= 0) {
            U& u = q[ea];
            for (int s = 0; s < 3; s++) if ((int)bits(&d.ia_src, s * 6, 6) != u.src[s] && ((u.use >> s) & 1))
                FAIL("cycle %ld: ia_src %d %d, expected %d", cyc, s, (int)bits(&d.ia_src, s * 6, 6), u.src[s]);
            if ((int)d.ia_wr != u.wr || (int)d.ia_dv != u.dv || (int)d.ia_f2i != u.f2i) FAIL("cycle %ld: ia wr / dv / f2i", cyc);
            if (u.wr && (int)d.ia_dst != u.dst) FAIL("cycle %ld: ia_dst %d, expected %d", cyc, (int)d.ia_dst, u.dst);
            if ((unsigned)d.ia_pl != u.pl) FAIL("cycle %ld: ia_pl %08x, expected %08x", cyc, (unsigned)d.ia_pl, u.pl);
            if ((unsigned)d.ia_bm != u.bm) FAIL("cycle %ld: ia_bm %03x, expected %03x", cyc, (unsigned)d.ia_bm, u.bm);
            nia++;
        }
        if ((bool)d.ib_valid != (eb >= 0)) FAIL("cycle %ld: ib_valid %d, expected %d", cyc, (int)d.ib_valid, eb >= 0);
        else if (eb >= 0) {
            U& u = q[eb];
            if ((int)d.ib_src != u.src[0]) FAIL("cycle %ld: ib_src %d, expected %d", cyc, (int)d.ib_src, u.src[0]);
            if ((unsigned)d.ib_pl != u.pl) FAIL("cycle %ld: ib_pl", cyc);
            if ((unsigned)d.ib_bm != u.bm) FAIL("cycle %ld: ib_bm %03x, expected %03x", cyc, (unsigned)d.ib_bm, u.bm);
            nib++;
        }
        if (ea >= 0 && eb >= 0) nboth++;
        for (int x : {ea, eb}) if (x >= 0) {
            U& u = q[x];
            for (int s = 0; s < 3; s++) if (((u.use >> s) & 1) && avail[u.src[s]] == cyc && cyc > 0) { nb2b++; break; }
        }

        // ---- the edge
        d.clk = 1; d.eval(); d.clk = 0; d.eval();

        // ---- the account after it
        std::vector<U> nq;
        for (size_t i = 0; i < q.size(); i++) {
            if ((int)i == ea || (int)i == eb) { occ[q[i].bank]--; continue; }
            if (q[i].bm & kill) { occ[q[i].bank]--; nkq++; continue; }
            nq.push_back(q[i]);
        }
        q = nq;
        if (kill) nkill++;
        for (auto& u : q) u.bm &= ~clr;
        if (clr) nclr++;
        if (flush) { q.clear(); for (int b = 0; b < 4; b++) occ[b] = 0; nflush++; }
        else if (!none) for (auto& u : nu) { q.push_back(u); occ[u.bank]++; }
        for (int t = 0; t < 64; t++) if (annnow[t]) { avail[t] = cyc + 1; pending[t] = false; }
        // tags become pending again (a new producer), when no queued µop reads them
        if (rng() % 2) {
            int t = rng() % 64;
            bool used = false;
            for (auto& u : q) for (int s = 0; s < 3; s++) if (((u.use >> s) & 1) && u.src[s] == t) used = true;
            if (!used && !pending[t]) { pending[t] = true; avail[t] = INF; }
        }
    }
    bool cov = nia > 100000 && nib > 30000 && nboth > 10000 && nb2b > 20000 && ndwk > 3000 && nkill > 10000 && nkq > 10000 &&
               nflush > 100 && nfull > 10000 && nfpu > 5000 && nf2i > 2000 && ncand > 10000 && nclr > 100000;
    printf("tb_fiq: %ld issues on A, %ld on B (%ld cycles both), %ld back to back after a wakeup, %ld sources woken at dispatch; %ld kills (%ld µops), %ld flushes; %ld cycles full, %ld held by fpu_ok, %ld by f2i_ok, %ld dispatches that do not go: %ld mismatches: %s\n",
           nia, nib, nboth, nb2b, ndwk, nkill, nkq, nflush, nfull, nfpu, nf2i, ncand, bad, bad == 0 && cov ? "PASS" : "FAIL");
    return bad != 0 || !cov;
}
