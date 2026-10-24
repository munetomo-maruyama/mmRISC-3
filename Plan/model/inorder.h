//---------------------------------------------------------------------------
// inorder.h : the 8-stage in-order core of mmRISC-2, for calibrating the
// model against what mmRISC-2 measured (CPU_CORE_SPEC.md 3, BENCH.md 1-11)
//
//   IF1 IF2 (FQ) ID EX MR MA WB, one instruction per cycle into EX.
//
//   Fetch: one 8-byte word per cycle from IF1; an instruction can enter EX
//   `fetch_to_ex` cycles after the IF1 of the word holding its last parcel.
//   A correctly predicted taken transfer fetches its target word in the
//   next cycle (the BTB is read in IF1); the fetch queue is assumed never
//   to run dry otherwise. A misprediction resolved in cycle t puts the
//   target in IF1 at t + `redirect`.
//   EX is held: a multiply 1 cycle (MULH family 2), as in decision 61.
//   Load-use: the instruction right after a load that reads its value
//   waits one cycle in EX; a conditional branch does not wait but is
//   resolved one stage later, in MR (decision 64, `late`).
//   Caches always hit (CoreMark: I$ 0.49 and D$ 0.16 misses per 1000
//   instructions on the board).
//---------------------------------------------------------------------------
#pragma once
#include "model.h"
#include "pred_mm2.h"

struct InorderCfg {
    int fetch_to_ex = 3;    // IF1 -> IF2 -> ID -> EX
    int redirect = 1;       // resolution in cycle t -> target in IF1 at t + redirect
    int mul_wait = 1;       // EX held by MUL / MULW (3 before decision 61)
    int mulh_wait = 2;
    bool late = true;       // decision 64
    bool gshare = true;     // decision 63 (else the 2-bit counters of the BTB)
    int btb = 256, pht = 8192, hist = 12, ras = 8;
};

struct InorderResult {
    long insns = 0, cycles = 0;
    long st_mdu = 0, st_lu = 0, st_misp = 0, st_fetch = 0;
    long late_branches = 0, late_miss = 0;
    long n_br, m_br, n_jal, m_jal, n_jalr, m_jalr;
};

inline InorderResult run_inorder(const std::vector<Rec>& t, const InorderCfg& c)
{
    PredMm2 bp(c.btb, c.pht, c.hist, c.ras, c.gshare);
    InorderResult res;
    long te_prev = -1, hold = 0;
    long te_first = 0;
    uint64_t fw_addr = t[0].pc >> 3;
    long fw_cycle = 0;
    bool brk = false, brk_misp = false;
    long brk_cycle = 0;
    bool last_brk_misp = false;
    for (size_t i = 0; i < t.size(); i++) {
        const Rec& r = t[i];
        // fetch: the cycle the word with the last parcel is in IF1
        uint64_t w0 = r.pc >> 3, w1 = (r.pc + r.size - 1) >> 3;
        if (brk) {
            fw_addr = w0; fw_cycle = brk_cycle; brk = false;
            last_brk_misp = brk_misp;
        } else if (w0 != fw_addr) {
            fw_cycle += (long)(w0 - fw_addr); fw_addr = w0;
        }
        if (w1 != fw_addr) { fw_cycle += (long)(w1 - fw_addr); fw_addr = w1; }
        long avail = fw_cycle + c.fetch_to_ex;

        // EX
        long base = te_prev + 1;
        long a1 = base + hold;
        bool late_br = false;
        long lu = 0;
        if (i > 0) {
            const Rec& p = t[i - 1];
            if (p.cls == C_LOAD && reads(r, p.dst)) {
                if (c.late && r.cls == C_BR) late_br = true;
                else lu = te_prev + 2;
            }
        }
        long te = a1;
        if (lu > te) { res.st_lu += lu - te; te = lu; }
        if (i > 0 && avail > te) {
            if (last_brk_misp) res.st_misp += avail - te; else res.st_fetch += avail - te;
            te = avail;
        }
        res.st_mdu += a1 - base;
        if (i == 0) { te = avail; te_first = te; }

        // control transfers
        if (is_cti(r)) {
            uint64_t next = i + 1 < t.size() ? t[i + 1].pc : r.pc + r.size;
            bool miss = bp.step(r, next);
            if (late_br) { res.late_branches++; if (miss) res.late_miss++; }
            if (miss) {
                brk = true; brk_misp = true;
                brk_cycle = te + (late_br ? 1 : 0) + c.redirect;
            } else if (r.flags & F_TAKEN) {
                brk = true; brk_misp = false;
                brk_cycle = fw_cycle + 1;
            }
        }
        hold = r.cls == C_MUL ? ((r.flags & F_MULH) ? c.mulh_wait : c.mul_wait) : 0;
        te_prev = te;
    }
    res.insns = (long)t.size();
    res.cycles = te_prev - te_first + 1;
    res.n_br = bp.n_br; res.m_br = bp.m_br; res.n_jal = bp.n_jal; res.m_jal = bp.m_jal;
    res.n_jalr = bp.n_jalr; res.m_jalr = bp.m_jalr;
    return res;
}
