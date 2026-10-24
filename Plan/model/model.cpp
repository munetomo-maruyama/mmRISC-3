//---------------------------------------------------------------------------
// model.cpp : cycle models of CoreMark on traces of mktrace.py
//
//   model inorder <trace.bin> [key=value ...]
//       the in-order core of mmRISC-2 (inorder.h); keys: fetch_to_ex,
//       redirect, mul_wait, mulh_wait, late, gshare, btb, pht, hist, ras,
//       iters (iterations in the trace, for CoreMark/MHz)
//---------------------------------------------------------------------------
#include "inorder.h"

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
    } else {
        fprintf(stderr, "unknown mode %s\n", mode.c_str());
        return 1;
    }
    return 0;
}
