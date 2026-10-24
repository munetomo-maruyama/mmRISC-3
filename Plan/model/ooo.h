//---------------------------------------------------------------------------
// ooo.h : the 2-wide out-of-order core of mmRISC-3 (hypothesis of
// STRATEGY.md 4 and ISSUES.md 3), trace-driven on the correct path
//
// Stages (cycles are parameters, defaults in OooCfg):
//
//   F0  next fetch address: uBTB (next-line predictor, no bubble)
//   F1  I$ read, TAGE / BTB read           } fe_depth: F0 -> decode
//   F2  I$ data; TAGE / BTB / RAS answer: if it differs from the uBTB,
//       the fetch is corrected (F0 again at F0 + override_at)
//   F3  predecode, alignment into the fetch buffer (fb instructions)
//   D   decode, fusion (dec_w instructions a cycle)    } dec_depth:
//   R   rename                                          } decode -> dispatch
//   DS  dispatch into the ROB, the issue queue, LQ / SQ (w µops a cycle)
//   IS  select (oldest first) when the operands will be ready; a
//       dependent issues lat cycles after its producer (ALU 1: back to back)
//   RR / EX   iss_to_ex: issue -> end of EX, where a branch is resolved;
//       a misprediction puts the target in F0 redirect cycles later
//   commit: in order, w µops a cycle, the cycle after completion
//
// A fetch block is fetch_bytes, aligned; it ends at a taken transfer, and an
// instruction across two blocks is decoded with the second. Fused pairs
// (fusion level, as ../trace/analyze.py) take one slot of dispatch, issue,
// the ROB and commit, and one port; each half completes with the latency of
// its own class from the issue of the pair (ALU + ALU: `chain`).
// Loads: conservative memory dependence (no load before the addresses of
// all older stores are known) or perfect; store-to-load forwarding from the
// store queue, or waiting for the store to be written.
// Caches always hit (as calibrated in inorder.h); no wrong path is run.
//---------------------------------------------------------------------------
#pragma once
#include <queue>
#include <unordered_map>
#include <list>
#include "model.h"
#include "tage.h"

struct OooCfg {
    int w = 2, dec_w = 4, fetch_bytes = 16, fb = 16;
    int fe_depth = 3, dec_depth = 2, iss_to_ex = 2, redirect = 1, override_at = 2;
    int rob = 64, iq = 24, lq = 16, sq = 16, ckpt = 0;
    int alu = 2, lsu = 1, mul = 1;
    int issue_w = 3;            // µops issued a cycle over all ports (0: no limit)
    bool mul_shared = true;     // MUL / DIV issue through an ALU port
    int lat_alu = 1, lat_load = 2, lat_mul = 2, lat_div = 20, lat_fp = 4;
    int ubtb = 64;
    std::string pred = "S";     // perfect, gshare, S, M, L (TAGE)
    int fusion = 0;             // 0 none, 1 conservative, 2 + ALU + branch, 3 + ALU + ALU
    int chain = 1;
    bool mem_cons = true, fwd = true;
};

struct OooResult {
    long insns = 0, uops = 0, cycles = 0;
    long m_br = 0, m_jal = 0, m_jalr = 0, overrides = 0, ubtb_taken_hits = 0, taken = 0;
    long st_fe_misp = 0, st_fe_ovr = 0, st_fe_other = 0, st_rob = 0, st_iq = 0, st_lsq = 0, st_ckpt = 0;
    long fused = 0;
};

// fusion of two adjacent instructions (the rules of fusion_kind in analyze.py);
// returns 0 or the level that allows the pair
inline int fusion_level(const Rec& a, const Rec& b)
{
    if (b.pc != a.pc + a.size) return 0;
    uint8_t d = a.dst;
    bool a_alu = a.cls == C_ALU, b_alu = b.cls == C_ALU;
    if (a.op == OP_LUI && b.op == OP_ADDI && reads(b, d)) return 1;
    if (a.op == OP_AUIPC && d != NOREG && reads(b, d)) return 1;
    if (a.op == OP_SLLI && b.op == OP_SRLI && d != NOREG && reads(b, d)) return 1;
    if (b.cls == C_LOAD && d != NOREG && b.base == d && a_alu) return 1;
    if (a.cls == C_LOAD && b.cls == C_LOAD && a.base != NOREG && a.base == b.base && a.dst != a.base &&
        a.mem && b.mem && (a.mem > b.mem ? a.mem - b.mem : b.mem - a.mem) <= 8) return 1;
    if (a.cls == C_STORE && b.cls == C_STORE && a.base != NOREG && a.base == b.base &&
        a.mem && b.mem && (a.mem > b.mem ? a.mem - b.mem : b.mem - a.mem) <= 8) return 1;
    if (a_alu && b.cls == C_BR && d != NOREG && reads(b, d)) return 2;
    if (a_alu && b_alu && d != NOREG && reads(b, d)) return 3;
    return 0;
}

// next-line predictor: fully associative, LRU, per control transfer
struct Ubtb {
    struct E { uint64_t target; uint8_t cnt; };
    int cap;
    std::list<uint64_t> lru;
    std::unordered_map<uint64_t, std::pair<E, std::list<uint64_t>::iterator>> m;
    explicit Ubtb(int n) : cap(n) {}
    // predicted taken and target (returns use the RAS top, given)
    bool predict(const Rec& r, uint64_t ras_top, uint64_t& tgt)
    {
        if (cap == 0) return false;
        auto it = m.find(r.pc);
        if (it == m.end()) return false;
        if (r.cls == C_BR && it->second.first.cnt < 2) return false;
        tgt = (r.flags & F_RET) ? ras_top : it->second.first.target;
        return true;
    }
    void update(const Rec& r, bool taken, uint64_t next)
    {
        if (cap == 0) return;
        auto it = m.find(r.pc);
        if (it == m.end()) {
            if (!taken) return;
            if ((int)m.size() >= cap) { m.erase(lru.back()); lru.pop_back(); }
            lru.push_front(r.pc);
            m[r.pc] = {E{next, 2}, lru.begin()};
            return;
        }
        E& e = it->second.first;
        if (taken) { e.target = next; if (e.cnt < 3) e.cnt++; } else if (e.cnt > 0) e.cnt--;
        lru.erase(it->second.second);
        lru.push_front(r.pc);
        it->second.second = lru.begin();
    }
};

inline OooResult run_ooo(const std::vector<Rec>& t, const OooCfg& c)
{
    OooResult res;
    size_t n = t.size();
    // fused pairs: second[i] = instruction i is the second half of a pair
    std::vector<char> second(n, 0);
    if (c.fusion) {
        for (size_t i = 0; i + 1 < n;) {
            int lv = fusion_level(t[i], t[i + 1]);
            if (lv && lv <= c.fusion) { second[i + 1] = 1; i += 2; res.fused++; } else i++;
        }
    }
    // predictors
    Tage tage = Tage::make(c.pred == "perfect" || c.pred == "gshare" ? "S" : c.pred.c_str());
    std::vector<uint8_t> pht(8192, 2);
    unsigned ghist = 0;
    Ubtb ub(c.ubtb);
    std::unordered_map<uint64_t, uint64_t> btb;  // pc -> last target (large; cold misses only)
    std::vector<uint64_t> ras(16);
    int ras_n = 0;
    bool perfect = c.pred == "perfect";

    std::vector<long> disp_i(n, 0);             // dispatch cycle per instruction (fetch back-pressure)
    std::vector<long> dec(n, 0);
    std::vector<long> ds, cm;                   // per µop: dispatch, commit
    ds.reserve(n); cm.reserve(n);
    std::vector<long> ld_cm, st_cm;             // commit cycles of loads / stores, in order
    std::priority_queue<long, std::vector<long>, std::greater<long>> iqh, ckh;
    std::unordered_map<int, long> ready;        // register -> cycle a dependent may issue
    std::unordered_map<long, int> use_alu, use_lsu, use_mul, use_all;
    struct StInfo { long data_ready, commit; };
    std::unordered_map<uint64_t, StInfo> st_word;   // latest store per 8-byte word
    long st_addr_known = 0;

    long blk_f0 = 0; uint64_t blk_region = ~0ull;
    bool new_blk = true; long next_f0 = 0;
    int blk_cause = 0, next_cause = 0;          // 0 other, 1 misprediction, 2 override
    long first_ds = -1;

    auto bp = [&](size_t i) -> long {           // fetch back-pressure from the fetch buffer
        return i >= (size_t)c.fb ? disp_i[i - c.fb] - (c.fe_depth + c.dec_depth) : 0;
    };

    for (size_t i = 0; i < n;) {
        bool pair = i + 1 < n && second[i + 1];
        size_t last = pair ? i + 1 : i;
        // ---- fetch and decode of the instructions of this µop
        for (size_t k = i; k <= last; k++) {
            const Rec& r = t[k];
            uint64_t r0 = r.pc / c.fetch_bytes, r1 = (r.pc + r.size - 1) / c.fetch_bytes;
            if (new_blk) {
                blk_region = r0; blk_f0 = std::max(next_f0, bp(k)); blk_cause = next_cause; new_blk = false;
            } else if (r0 != blk_region) {
                blk_region = r0; blk_f0 = std::max(blk_f0 + 1, bp(k)); blk_cause = 0;
            }
            if (r1 != blk_region) { blk_region = r1; blk_f0 = std::max(blk_f0 + 1, bp(k)); blk_cause = 0; }
            long avail = blk_f0 + c.fe_depth;
            long d = avail;
            if (k > 0) {
                d = std::max(d, dec[k - 1]);
                if (k >= (size_t)c.dec_w) d = std::max(d, dec[k - c.dec_w] + 1);
            }
            dec[k] = d;
        }
        // ---- dispatch
        size_t u = ds.size();
        long base = u ? ds[u - 1] : 0;
        if (u >= (size_t)c.w) base = std::max(base, ds[u - c.w] + 1);
        long d = base;
        long fe = dec[last] + c.dec_depth;
        if (fe > d) {
            long s = fe - d;
            if (blk_cause == 1) res.st_fe_misp += s; else if (blk_cause == 2) res.st_fe_ovr += s; else res.st_fe_other += s;
            d = fe;
        }
        if (u >= (size_t)c.rob && cm[u - c.rob] + 1 > d) { res.st_rob += cm[u - c.rob] + 1 - d; d = cm[u - c.rob] + 1; }
        while (!iqh.empty() && iqh.top() < d) iqh.pop();
        if ((int)iqh.size() >= c.iq) {
            long need = iqh.top() + 1;
            res.st_iq += need - d; d = need;
            while (!iqh.empty() && iqh.top() < d) iqh.pop();
        }
        int nld = 0, nst = 0;
        bool has_cti = false;
        for (size_t k = i; k <= last; k++) {
            nld += t[k].cls == C_LOAD; nst += t[k].cls == C_STORE; has_cti |= is_cti(t[k]);
        }
        for (int q = 0; q < nld; q++) {
            size_t j = ld_cm.size() + q;
            if (j >= (size_t)c.lq && ld_cm[j - c.lq] + 1 > d) { res.st_lsq += ld_cm[j - c.lq] + 1 - d; d = ld_cm[j - c.lq] + 1; }
        }
        for (int q = 0; q < nst; q++) {
            size_t j = st_cm.size() + q;
            if (j >= (size_t)c.sq && st_cm[j - c.sq] + 2 > d) { res.st_lsq += st_cm[j - c.sq] + 2 - d; d = st_cm[j - c.sq] + 2; }
        }
        if (has_cti && c.ckpt) {
            while (!ckh.empty() && ckh.top() < d) ckh.pop();
            if ((int)ckh.size() >= c.ckpt) {
                long need = ckh.top() + 1;
                res.st_ckpt += need - d; d = need;
                while (!ckh.empty() && ckh.top() < d) ckh.pop();
            }
        }
        if (first_ds < 0) first_ds = d;
        ds.push_back(d);
        for (size_t k = i; k <= last; k++) disp_i[k] = d;

        // ---- issue
        long is = d + 1;
        for (size_t k = i; k <= last; k++)
            for (int s = 0; s < 3; s++) {
                uint8_t r = t[k].src[s];
                if (r == NOREG || (k == last && pair && r == t[i].dst)) continue;
                if (t[k].cls == C_STORE && r != t[k].base) continue;   // the data joins later
                auto it = ready.find(r);
                if (it != ready.end() && it->second > is) is = it->second;
            }
        bool any_load = nld > 0;
        if (any_load && c.mem_cons && st_addr_known > is) is = st_addr_known;
        if (any_load && !c.fwd)
            for (size_t k = i; k <= last; k++)
                if (t[k].cls == C_LOAD) {
                    auto it = st_word.find(t[k].mem >> 3);
                    if (it != st_word.end() && it->second.commit + 1 > is) is = it->second.commit + 1;
                }
        const Rec& pr = t[pair && t[last].cls != C_ALU ? last : i];
        int port = (pr.cls == C_LOAD || pr.cls == C_STORE) ? 1 : (pr.cls == C_MUL || pr.cls == C_DIV) ? (c.mul_shared ? 0 : 2) : 0;
        auto& use = port == 1 ? use_lsu : port == 2 ? use_mul : use_alu;
        int cap = port == 1 ? c.lsu : port == 2 ? c.mul : c.alu;
        while (use[is] >= cap || (c.issue_w && use_all[is] >= c.issue_w)) is++;
        use[is]++;
        use_all[is]++;
        if (pr.cls == C_DIV) for (int q = 1; q < c.lat_div; q++) use[is + q] = cap;   // not pipelined
        iqh.push(is);

        // ---- results
        long done = is;
        for (size_t k = i; k <= last; k++) {
            const Rec& r = t[k];
            int lat = r.cls == C_LOAD ? c.lat_load : r.cls == C_MUL ? c.lat_mul : r.cls == C_DIV ? c.lat_div
                    : r.cls == C_FP ? c.lat_fp : c.lat_alu;
            if (pair && k == last && t[i].cls == C_ALU && r.cls == C_ALU) lat = c.chain;
            long rd = is + lat;
            if (r.cls == C_LOAD) {
                auto it = st_word.find(r.mem >> 3);
                if (c.fwd && it != st_word.end() && it->second.commit >= is)
                    rd = std::max(rd, it->second.data_ready + 1);
            }
            if (r.cls == C_STORE) {
                long dr = is;
                if (r.src[0] != NOREG && r.src[0] != r.base) { auto it = ready.find(r.src[0]); if (it != ready.end()) dr = std::max(dr, it->second); }
                rd = std::max(rd, dr);
                st_addr_known = std::max(st_addr_known, is);
            }
            if (r.dst != NOREG) ready[r.dst] = rd;
            done = std::max(done, rd + c.iss_to_ex - 1);
        }
        long cmt = done + 1;
        if (u >= 1) cmt = std::max(cmt, cm[u - 1]);
        if (u >= (size_t)c.w) cmt = std::max(cmt, cm[u - c.w] + 1);
        cm.push_back(cmt);
        for (size_t k = i; k <= last; k++) {
            if (t[k].cls == C_LOAD) ld_cm.push_back(cmt);
            if (t[k].cls == C_STORE) {
                st_cm.push_back(cmt);
                long dr = cmt;
                auto it = t[k].src[0] != NOREG ? ready.find(t[k].src[0]) : ready.end();
                dr = it != ready.end() ? it->second : is;
                st_word[t[k].mem >> 3] = StInfo{dr, cmt};
            }
        }

        // ---- control transfers: prediction, override, misprediction
        for (size_t k = i; k <= last; k++) {
            const Rec& r = t[k];
            if (!is_cti(r)) continue;
            bool tk = r.flags & F_TAKEN;
            if (c.ckpt) ckh.push(is + c.iss_to_ex);     // a checkpoint until it is resolved
            uint64_t next = k + 1 < n ? t[k + 1].pc : r.pc + r.size;
            uint64_t ras_top = ras_n ? ras[(ras_n - 1) % ras.size()] : 0;
            // the main prediction (F2)
            bool mp_t; uint64_t mp_tgt = 0;
            if (perfect) { mp_t = tk; mp_tgt = next; }
            else {
                auto bt = btb.find(r.pc);
                bool known = bt != btb.end();
                if (r.cls == C_BR) {
                    bool dir;
                    if (c.pred == "gshare") {
                        int pi = (int)(((r.pc >> 1) ^ (ghist << 1)) & 8191);
                        dir = pht[pi] >= 2;
                        pht[pi] = tk ? (pht[pi] < 3 ? pht[pi] + 1 : 3) : (pht[pi] > 0 ? pht[pi] - 1 : 0);
                        ghist = ((ghist << 1) | tk) & 0xfff;
                    } else dir = tage.step(r.pc, tk);
                    mp_t = dir && known; mp_tgt = known ? bt->second : 0;
                } else {
                    mp_t = known;
                    mp_tgt = (r.flags & F_RET) ? ras_top : (known ? bt->second : 0);
                }
            }
            if (tk) btb[r.pc] = next;
            // the uBTB (F0)
            uint64_t ub_tgt = 0;
            bool ub_t = perfect ? tk : ub.predict(r, ras_top, ub_tgt);
            if (perfect) ub_tgt = next;
            ub.update(r, tk, next);
            if (r.flags & F_RET && ras_n) ras_n--;
            if (r.flags & F_CALL) { ras[ras_n % ras.size()] = r.pc + r.size; ras_n++; }
            if (tk) { res.taken++; if (ub_t && ub_tgt == next) res.ubtb_taken_hits++; }

            bool miss = mp_t != tk || (tk && mp_tgt != next);
            if (miss) {
                if (r.cls == C_BR) res.m_br++; else if (r.cls == C_JAL) res.m_jal++; else res.m_jalr++;
                long resolve = is + c.iss_to_ex;
                next_f0 = std::max(resolve + c.redirect, blk_f0 + 1);
                new_blk = true; next_cause = 1;
            } else {
                bool agree = ub_t == mp_t && (!mp_t || ub_tgt == mp_tgt);
                if (!agree) {
                    res.overrides++;
                    next_f0 = blk_f0 + c.override_at; new_blk = true; next_cause = 2;
                } else if (tk) {
                    next_f0 = blk_f0 + 1; new_blk = true; next_cause = 0;
                }
            }
        }
        // the cycles of the port use behind every issue are no longer needed
        if ((u & 0xffff) == 0) {
            long lim = is - 4096;
            for (auto* mp : {&use_alu, &use_lsu, &use_mul, &use_all})
                for (auto it = mp->begin(); it != mp->end();) it = it->first < lim ? mp->erase(it) : std::next(it);
        }
        i = last + 1;
    }
    res.insns = (long)n;
    res.uops = (long)ds.size();
    res.cycles = cm.back() - first_ds + 1;
    return res;
}
