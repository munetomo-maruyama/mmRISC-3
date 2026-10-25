//---------------------------------------------------------------------------
// tb_tage.cpp : OOO_TAGE against tage_ref.h
//
// Blocks are read as fetch reads them: F2 of a block 2 or more cycles after
// its F0, and the next F0 not before the cycle before that F2 (as the I$
// gives its answers). The fetch addresses come from 40 blocks, each with
// its slots (0 .. 3 branches at increasing parcels) and a pattern for its
// outcomes (taken every n-th time, shifted per slot, with some noise), so
// that the tables learn and several of them hit. F2 pushes the predictions
// up to the first taken slot, as fetch does (now and then fewer). The
// blocks are updated later, in order, up to the first taken or
// mispredicted slot; now and then the history is restored from the
// metadata of a block. Every F2 compares
// the predictions, the base bits and all of f2_meta (which carries the rows
// as read, so a wrong table write shows up when the row is read again).
//---------------------------------------------------------------------------
#include "VOOO_TAGE.h"
#include "tage_ref.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>

static std::mt19937_64 rng(23);
static VOOO_TAGE d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("TAGE_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    TageRef R;
    // the blocks: a fetch address, fixed slots, and a pattern for the outcomes
    // (a branch is taken every per-th time, shifted per slot), so that the
    // tables learn and several of them hit
    const int NB = 40;
    struct Info { uint64_t pc; int sv, par[3], per; long cnt; };
    Info blk[NB];
    for (auto& b : blk) {
        b.pc = rng() & ((1ull << 38) - 1);
        int ns = rng() % 4, p = rng() % 3;
        b.sv = 0;
        for (int q = 0; q < 3; q++) {
            if (q < ns && p < 8) { b.sv |= 1 << q; b.par[q] = p; p += 1 + rng() % 3; }
            else b.par[q] = rng() % 8;
        }
        b.per = 1 + rng() % 7; b.cnt = 0;
    }

    struct Blk { TageRef::Rd rd; long f2; int id; };
    std::deque<Blk> inflight;                  // read, F2 not done (oldest first)
    long next_f0 = 0;
    struct Done { Bits m; int sv, pred, id; };
    std::deque<Done> done;                     // F2 done, not updated
    std::deque<Bits> recent;                   // metadata to restore from
    long nf2 = 0, nup = 0, nrs = 0, nmiss = 0, nprov = 0, nalt = 0, nweak = 0;
    for (cyc = 0; cyc < 600000; cyc++) {
        // ---------- inputs
        int f0 = cyc >= next_f0 && inflight.size() < 2 && rng() % 4 != 0;
        int fid = rng() % NB;
        uint64_t pc = blk[fid].pc;
        bool do_f2 = !inflight.empty() && inflight.front().f2 == cyc;
        int sv = 0, par[3] = {0, 0, 0}, n = 0;
        int pred = 0, basebits = 0; Bits m;
        if (do_f2) {
            const Info& b = blk[inflight.front().id];
            sv = b.sv; for (int q = 0; q < 3; q++) par[q] = b.par[q];
            if (rng() % 16 == 0) sv = (1 << (rng() % 4)) - 1;      // now and then other slots
            R.f2(inflight.front().rd, sv, par, pred, basebits, m);
            // push up to the first slot predicted taken, as fetch does
            int ns = __builtin_popcount(sv);
            for (n = 0; n < ns; ) { n++; if ((pred >> (n - 1)) & 1) break; }
            if (rng() % 10 == 0) n = ns ? (int)(rng() % (ns + 1)) : 0;
        }
        int push = do_f2 && rng() % 8 != 0;
        int rs = !recent.empty() && rng() % 40 == 0;
        Bits rsm; int rsn = 0, rsb = 0;
        if (rs) { rsm = recent[rng() % recent.size()]; rsn = rng() % 4; rsb = rng() % 8; }
        int up = !done.empty() && (done.size() > 6 || rng() % 3 == 0);
        int ex = 0, tk = 0;
        Done ud;
        if (up) {
            ud = done.front();
            Info& b = blk[ud.id];
            int nsv = __builtin_popcount(ud.sv);
            for (int s = 0; s < nsv; s++) {
                bool p = (ud.pred >> s) & 1;
                bool t = ((b.cnt + s * 3) % b.per) == 0;
                if (rng() % 30 == 0) t = !t;
                ex |= 1 << s; tk |= (int)t << s;
                if (t != p) { nmiss++; break; }    // a misprediction ends the block
                if (t) break;                      // so does a taken branch
            }
            b.cnt++;
        }
        d.f0_valid = f0; d.f0_pc = pc;
        d.f2_sv = sv; d.f2_par = par[0] | (par[1] << 3) | (par[2] << 6);
        d.f2_push = push; d.f2_n = n;
        d.rs_valid = rs; d.rs_n = rsn; d.rs_bits = rsb;
        for (int k = 0; k < 3; k++) d.rs_hist[k] = rs ? (uint32_t)rsm.get(TageRef::M_HIST + 32 * k, k < 2 ? 32 : 6) : 0;
        d.up_valid = up; d.up_ex = ex; d.up_tk = tk;
        for (int k = 0; k < 9; k++) d.up_meta[k] = up ? ud.m.w[k] : 0;
        d.eval();
        // ---------- F2: compare with the reference
        if (do_f2) {
            if ((int)d.f2_pred != pred) FAIL("f2_pred %x, expected %x", (int)d.f2_pred, pred);
            for (int k = 0; k < 9; k++)
                if (d.f2_meta[k] != m.w[k]) { FAIL("f2_meta word %d: %08x, expected %08x", k, d.f2_meta[k], m.w[k]); break; }
            { int pj, aj; TageRef::pa(inflight.front().rd.row, inflight.front().rd.tag, pj, aj);
              nprov += pj >= 0; nalt += aj >= 0;
              if (pj >= 0) { unsigned c = TageRef::rc(inflight.front().rd.row[pj], 0); nweak += (c == 3 || c == 4) && TageRef::ru(inflight.front().rd.row[pj]) == 0; } }
            done.push_back(Done{m, sv, pred, inflight.front().id});
            recent.push_back(m); if (recent.size() > 6) recent.pop_front();
            inflight.pop_front();
            nf2++;
        }
        // F0: the rows before this cycle's update
        if (f0) {
            long f2 = cyc + 2 + (rng() % 4 == 0 ? rng() % 5 : 0);
            inflight.push_back(Blk{R.read(pc), f2, fid});
            next_f0 = f2 - 1;                  // the next F0 not before the cycle before this F2
        }
        // ---------- the clock
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if (up) { R.update(ud.m, ex, tk); done.pop_front(); nup++; }
        if (rs) { R.restore(rsm, rsn, rsb); nrs++; }
        else if (push) R.push(n, pred);
    }
    printf("tb_tage: %ld cycles, %ld blocks predicted (provider %ld, alternate %ld, weak new %ld), %ld updated (%ld mispredicted slots), %ld restores, %ld mismatches: %s\n",
           cyc, nf2, nprov, nalt, nweak, nup, nmiss, nrs, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
