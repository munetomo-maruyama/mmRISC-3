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
//       lat_load, lat_mul, ubtb, pred (perfect / gshare / S / M / L),
//       fusion (0-3), chain, fuse_1w, fuse_2src, ck1, ck_jal, mem_cons, fwd, iters
//   model tage <trace.bin>
//       the conditional branches through TAGE-S / M / L (to hold against
//       ../trace/analyze.py)
//---------------------------------------------------------------------------
#include "inorder.h"
#include "tage.h"
#include "ooo.h"

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
        c.ubtb = (int)o.get("ubtb", c.ubtb);
        c.fusion = (int)o.get("fusion", c.fusion);
        c.chain = (int)o.get("chain", c.chain);
        c.fuse_1w = o.get("fuse_1w", c.fuse_1w);
        c.fuse_2src = o.get("fuse_2src", c.fuse_2src);
        c.ck1 = o.get("ck1", c.ck1);
        c.ck_jal = o.get("ck_jal", c.ck_jal);
        c.mem_cons = o.get("mem_cons", c.mem_cons);
        c.fwd = o.get("fwd", c.fwd);
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
    } else {
        fprintf(stderr, "unknown mode %s\n", mode.c_str());
        return 1;
    }
    return 0;
}
