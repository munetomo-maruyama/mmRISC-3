//---------------------------------------------------------------------------
// model.cpp : cycle models of CoreMark on traces of mktrace.py
//
//   model inorder <trace.bin> [key=value ...]
//       the in-order core of mmRISC-2 (inorder.h); keys: fetch_to_ex,
//       redirect, mul_wait, mulh_wait, late, gshare, btb, pht, hist, ras,
//       iters (iterations in the trace, for CoreMark/MHz)
//   model ooo <trace.bin> [key=value ...]
//       the 2-wide out-of-order core of mmRISC-3 (ooo.h); keys: w, dec_w,
//       issue_w, fetch_bytes, fb, fe_depth, dec_depth, iss_to_ex, redirect,
//       override_at, rob, iq, lq, sq, ckpt, alu, lsu, mul, mul_shared,
//       lat_load, lat_mul, mdu_busy, ubtb, pred (perfect / gshare / S / M / L),
//       fusion (0-3), chain, fuse_1w, fuse_2src, ck1, ck_jal, mem_cons, fwd, st_data_issue, keep_spec, alu_split,
//       upd (TAGE update 0 at once, 1 at commit), upd_lag, stale, iters
//   model tage <trace.bin>
//       the conditional branches through TAGE-S / M / L (to hold against
//       ../trace/analyze.py)
//   model tageblk <trace.bin> [slots=2 hist=0 lag=0 halve=1 delay=0 stale=1]
//       TAGE-S as it can be built in block RAM, per fetch block (tageblk.h);
//       delay: blocks between a block's prediction and its update
//   model tageref <trace.bin> [lag=2 stall=0 delay=0 spread=0 seed=1]
//       OOO_TAGE's algorithm (SIM/OOO_UNIT/tage_ref.h) on the same blocks
//---------------------------------------------------------------------------
#include "inorder.h"
#include "tage.h"
#include "ooo.h"
#include "tageblk.h"
#include "../../SIM/OOO_UNIT/tage_ref.h"
#include <deque>
#include <map>
#include <algorithm>
#include <random>

static void print_inorder(const InorderResult& r, long iters)
{
    printf("instructions %ld  cycles %ld  CPI %.4f  CoreMark/MHz %.3f\n", r.insns, r.cycles,
           (double)r.cycles / r.insns, iters * 1e6 / r.cycles);
    printf("stalls: mdu %ld  load-use %ld  mispredict %ld  fetch %ld\n", r.st_mdu, r.st_lu,
           r.st_misp, r.st_fetch);
    printf("mispredicted: branch %ld / %ld  jal %ld / %ld  jalr %ld / %ld  (late branches %ld, wrong %ld)\n",
           r.m_br, r.n_br, r.m_jal, r.n_jal, r.m_jalr, r.n_jalr, r.late_branches, r.late_miss);
}

int main(int argc, char** argv)
{
    if (argc < 3) { fprintf(stderr, "usage: model inorder <trace.bin> [key=value ...]\n"); return 1; }
    std::string mode = argv[1];
    std::vector<Rec> t = load_trace(argv[2]);
    Opts o(argc, argv, 3);
    long iters = o.get("iters", 10);
    if (mode == "inorder") {
        InorderCfg c;
        c.fetch_to_ex = (int)o.get("fetch_to_ex", c.fetch_to_ex);
        c.redirect = (int)o.get("redirect", c.redirect);
        c.mul_wait = (int)o.get("mul_wait", c.mul_wait);
        c.mulh_wait = (int)o.get("mulh_wait", c.mulh_wait);
        c.late = o.get("late", c.late);
        c.gshare = o.get("gshare", c.gshare);
        c.btb = (int)o.get("btb", c.btb);
        c.pht = (int)o.get("pht", c.pht);
        c.hist = (int)o.get("hist", c.hist);
        c.ras = (int)o.get("ras", c.ras);
        o.check();
        print_inorder(run_inorder(t, c), iters);
    } else if (mode == "ooo") {
        OooCfg c;
        c.w = (int)o.get("w", c.w);
        c.dec_w = (int)o.get("dec_w", c.dec_w);
        c.fetch_bytes = (int)o.get("fetch_bytes", c.fetch_bytes);
        c.fb = (int)o.get("fb", c.fb);
        c.fe_depth = (int)o.get("fe_depth", c.fe_depth);
        c.dec_depth = (int)o.get("dec_depth", c.dec_depth);
        c.iss_to_ex = (int)o.get("iss_to_ex", c.iss_to_ex);
        c.redirect = (int)o.get("redirect", c.redirect);
        c.override_at = (int)o.get("override_at", c.override_at);
        c.rob = (int)o.get("rob", c.rob);
        c.iq = (int)o.get("iq", c.iq);
        c.lq = (int)o.get("lq", c.lq);
        c.sq = (int)o.get("sq", c.sq);
        c.ckpt = (int)o.get("ckpt", c.ckpt);
        c.alu = (int)o.get("alu", c.alu);
        c.lsu = (int)o.get("lsu", c.lsu);
        c.mul = (int)o.get("mul", c.mul);
        c.issue_w = (int)o.get("issue_w", c.issue_w);
        c.mul_shared = o.get("mul_shared", c.mul_shared);
        c.lat_load = (int)o.get("lat_load", c.lat_load);
        c.lat_mul = (int)o.get("lat_mul", c.lat_mul);
        c.mdu_busy = (int)o.get("mdu_busy", c.mdu_busy);
        c.lat_div = (int)o.get("lat_div", c.lat_div);
        c.ubtb = (int)o.get("ubtb", c.ubtb);
        c.fusion = (int)o.get("fusion", c.fusion);
        c.chain = (int)o.get("chain", c.chain);
        c.fuse_1w = o.get("fuse_1w", c.fuse_1w);
        c.fuse_2src = o.get("fuse_2src", c.fuse_2src);
        c.ck1 = o.get("ck1", c.ck1);
        c.ck_jal = o.get("ck_jal", c.ck_jal);
        c.mem_cons = o.get("mem_cons", c.mem_cons);
        c.fwd = o.get("fwd", c.fwd);
        c.st_data_issue = o.get("st_data_issue", c.st_data_issue);
        c.keep_spec = (int)o.get("keep_spec", c.keep_spec);
        c.alu_split = (int)o.get("alu_split", c.alu_split);
        c.upd = (int)o.get("upd", c.upd);
        c.upd_lag = (int)o.get("upd_lag", c.upd_lag);
        c.stale = o.get("stale", c.stale);
        auto it = o.kv.find("pred");
        if (it != o.kv.end()) { c.pred = it->second; o.kv.erase(it); }
        o.check();
        OooResult r = run_ooo(t, c);
        printf("instructions %ld  uops %ld  cycles %ld  IPC %.4f  CoreMark/MHz %.3f\n", r.insns, r.uops,
               r.cycles, (double)r.insns / r.cycles, iters * 1e6 / r.cycles);
        printf("mispredicted: branch %ld  jal %ld  jalr %ld  (MPKI %.2f)  overrides %ld  taken %ld, uBTB right %.1f %%\n",
               r.m_br, r.m_jal, r.m_jalr, (r.m_br + r.m_jal + r.m_jalr) * 1000.0 / r.insns, r.overrides,
               r.taken, 100.0 * r.ubtb_taken_hits / (r.taken ? r.taken : 1));
        printf("dispatch held: front end after misprediction %ld, after override %ld, other %ld; ROB %ld  IQ %ld  LQ/SQ %ld  checkpoints %ld\n",
               r.st_fe_misp, r.st_fe_ovr, r.st_fe_other, r.st_rob, r.st_iq, r.st_lsq, r.st_ckpt);
    } else if (mode == "tage") {
        // the conditional branches alone through the three TAGE sizes, to
        // hold against ../trace/analyze.py
        o.check();
        for (const char* nm : {"S", "M", "L"}) {
            Tage tg = Tage::make(nm);
            long nb = 0, nm_ = 0;
            for (const Rec& r : t)
                if (r.cls == C_BR) { nb++; if (tg.step(r.pc, r.flags & F_TAKEN) != (bool)(r.flags & F_TAKEN)) nm_++; }
            printf("TAGE-%s %ld kbit  conditional branches %ld  mispredicted %ld (%.3f %%)\n", nm,
                   tg.bits / 1024, nb, nm_, 100.0 * nm_ / nb);
        }
    } else if (mode == "tageblk") {
        int slots = (int)o.get("slots", 2), hist = (int)o.get("hist", 0), lag = (int)o.get("lag", 0);
        bool halve = o.get("halve", 1);
        int delay = (int)o.get("delay", 0);
        bool stale = o.get("stale", 1);
        o.check();
        TageBlk tb(slots, hist, lag);
        tb.halve = halve;
        tb.delay = delay;
        tb.stale = stale;
        tb.run(t);
        printf("TAGE-S per block (slots %d, hist %d, lag %d, halve %d, delay %d%s): blocks %ld  conditional branches %ld  mispredicted %ld (%.3f %%)  past the slots %ld\n",
               slots, hist, lag, (int)halve, delay, delay ? (stale ? " stale" : " fresh") : "", tb.stat_blocks, tb.stat_br, tb.stat_miss, 100.0 * tb.stat_miss / tb.stat_br, tb.stat_past);
        printf("blocks by branches used: 0 %ld  1 %ld  2 %ld  3 %ld  4+ %ld\n", tb.stat_nbr[0], tb.stat_nbr[1],
               tb.stat_nbr[2], tb.stat_nbr[3], tb.stat_nbr[4] + tb.stat_nbr[5] + tb.stat_nbr[6] + tb.stat_nbr[7]);
    } else if (mode == "tageref") {
        // OOO_TAGE's own algorithm (SIM/OOO_UNIT/tage_ref.h, which tb_tage holds the RTL to) on the
        // blocks of tageblk.h: lag blocks not yet in the history at a block's read, its update
        // `delay` blocks after its prediction, from the rows as read (Plan/CORE.md 5.3)
        int lag = (int)o.get("lag", 2), delay = (int)o.get("delay", 0), spread = (int)o.get("spread", 0);
        int stall = (int)o.get("stall", 0);     // % of the blocks read after a fetch stall: every block before is in the history
        long seed = o.get("seed", 1);
        o.check();
        std::mt19937_64 rng(seed);
        int target = delay;                     // spread: the blocks pending before an update vary in delay +- spread
        TageBlk tb(3, 1, 0);
        TageRef ref;
        struct Push { int n, bits; };
        struct Upd { Bits m; int ex, tk; };
        std::deque<Push> hq; std::deque<Upd> uq;
        long nblk = 0, nbr = 0, nmiss = 0, past = 0;
        std::map<uint64_t, long> bypc;          // by the address of the branch's last parcel
        tb.other = [&](uint64_t start, const std::vector<TageBlk::Br>& br, size_t& stop) {
            int l = (stall && (int)(rng() % 100) < stall) ? 0 : lag;
            while ((int)hq.size() > l) { ref.push(hq.front().n, hq.front().bits); hq.pop_front(); }
            TageRef::Rd r = ref.read(start >> 1);
            int sv = 0, par[3] = {0, 0, 0};
            for (size_t s = 0; s < br.size() && s < 3; s++) { sv |= 1 << s; par[s] = (int)((br[s].pc_end >> 1) & 7); }
            int pred, bb; Bits m;
            ref.f2(r, sv, par, pred, bb, m);
            stop = br.size();
            int ex = 0, tk = 0, n = 0;
            for (size_t s = 0; s < br.size(); s++) {
                bool p = s < 3 ? (pred >> s) & 1 : false;          // a 4th branch: not taken
                nbr++;
                if (s >= 3) past++;
                if (s < 3) { ex |= 1 << s; tk |= (int)br[s].tk << s; n++; }
                if (p != br[s].tk) { nmiss++; bypc[br[s].pc_end]++; stop = s; break; }
            }
            nblk++;
            hq.push_back(Push{n, tk});
            uq.push_back(Upd{m, ex, tk});
            while ((int)uq.size() > target) {
                ref.update(uq.front().m, uq.front().ex, uq.front().tk); uq.pop_front();
                if (spread) target = delay - spread + (int)(rng() % (2 * spread + 1));
            }
        };
        tb.run(t);
        printf("OOO_TAGE (tage_ref.h, lag %d (0 after %d %% stalls), delay %d +- %d): blocks %ld  conditional branches %ld  mispredicted %ld (%.3f %%)  past the slots %ld\n",
               lag, stall, delay, spread, nblk, nbr, nmiss, 100.0 * nmiss / nbr, past);
        if (o.get("bypc", 0) || getenv("TAGE_BYPC")) {
            std::vector<std::pair<long, uint64_t>> v;
            for (auto& x : bypc) v.push_back({x.second, x.first});
            std::sort(v.rbegin(), v.rend());
            for (size_t k = 0; k < v.size() && k < 25; k++) printf("    bypc %llx %ld\n", (unsigned long long)v[k].second, v[k].first);
        }
    } else {
        fprintf(stderr, "unknown mode %s\n", mode.c_str());
        return 1;
    }
    return 0;
}
