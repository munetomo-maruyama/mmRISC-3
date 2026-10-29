//---------------------------------------------------------------------------
// tage.h : TAGE (Seznec), the same predictor as Tage of ../trace/analyze.py
//
// A bimodal base and tagged tables with geometric histories; 3-bit
// counters, 2-bit useful counters, use-alt-on-new-allocation, allocation of
// one entry on a misprediction, halving of the useful counters every 256K
// branches. step() predicts and then updates at once (trace-driven);
// predict() and update() apart let the update come later, as at commit in
// the core (ooo.h upd=1, Plan/CORE.md 5.3).
//---------------------------------------------------------------------------
#pragma once
#include <vector>
#include <cstdint>

struct Folded {
    unsigned comp = 0;
    int clen, outpoint;
    unsigned mask;
    Folded(int olen, int cl) : clen(cl), outpoint(olen % cl), mask((1u << cl) - 1) {}
    void update(unsigned newbit, unsigned oldbit)
    {
        unsigned c = (comp << 1) | newbit;
        c ^= oldbit << outpoint;
        c ^= c >> clen;
        comp = c & mask;
    }
};

struct Tage {
    int blog, nlog, n;
    std::vector<int> tags, hists;
    std::vector<uint8_t> base;
    std::vector<std::vector<uint8_t>> ctr, u;
    std::vector<std::vector<int>> tag;
    std::vector<Folded> fi, ft1, ft2;
    std::vector<uint8_t> gh;     // history bits, circular; gh[(head - k) & mask] is k branches ago
    unsigned head = 0, ghmask;
    int use_alt = 8;
    long tick = 0;
    long bits;

    Tage(int base_log, int table_log, std::vector<int> tag_bits, std::vector<int> hist_len)
        : blog(base_log), nlog(table_log), n((int)hist_len.size()), tags(tag_bits), hists(hist_len),
          base(1u << base_log, 2)
    {
        for (int j = 0; j < n; j++) {
            ctr.emplace_back(1u << nlog, 4);
            u.emplace_back(1u << nlog, 0);
            tag.emplace_back(1u << nlog, -1);
            fi.emplace_back(hists[j], nlog);
            ft1.emplace_back(hists[j], tags[j]);
            ft2.emplace_back(hists[j], tags[j] - 1);
        }
        unsigned sz = 1;
        while (sz < 2u * 1024) sz <<= 1;
        gh.assign(sz, 0);
        ghmask = sz - 1;
        bits = 2L << base_log;
        for (int t : tags) bits += (1L << nlog) * (3 + 2 + t);
    }

    static Tage make(const char* name)
    {
        std::string s(name);
        if (s == "S") return Tage(12, 10, {8, 8, 9, 9}, {5, 12, 30, 70});
        if (s == "M") return Tage(13, 11, {9, 9, 10, 10, 11, 11}, {4, 9, 20, 44, 96, 200});
        return Tage(14, 12, {10, 10, 11, 11, 12, 12, 13, 13}, {4, 8, 16, 32, 64, 128, 256, 640});
    }

    // A prediction and what its update needs: the indices and tags, and the
    // entries as read (the update can be deferred: Plan/CORE.md 5.3)
    struct Pred {
        int idx[16], tg[16], prov = -1, alt = -1;
        unsigned bi = 0;
        int s_tag[16]; uint8_t s_ctr[16], s_u[16], s_base = 0;
        bool pred = false;
    };

    // the prediction for pc; the history takes the outcome tk at once (the
    // model runs on the correct path: after a misprediction the history is
    // put back with the right outcome)
    Pred predict(uint64_t pc, bool tk)
    {
        Pred p;
        uint64_t pcs = pc >> 1;
        unsigned nmask = (1u << nlog) - 1;
        for (int j = 0; j < n; j++) {
            p.idx[j] = (int)((pcs ^ (pcs >> (nlog - j)) ^ fi[j].comp) & nmask);
            p.tg[j] = (int)((pcs ^ ft1[j].comp ^ ((uint64_t)ft2[j].comp << 1)) & ((1u << tags[j]) - 1));
            p.s_tag[j] = tag[j][p.idx[j]]; p.s_ctr[j] = ctr[j][p.idx[j]]; p.s_u[j] = u[j][p.idx[j]];
        }
        for (int j = n - 1; j >= 0; j--) {
            if (p.s_tag[j] == p.tg[j]) {
                if (p.prov < 0) p.prov = j;
                else { p.alt = j; break; }
            }
        }
        p.bi = (unsigned)(pcs & ((1u << blog) - 1));
        p.s_base = base[p.bi];
        bool base_p = p.s_base >= 2;
        bool alt_p = p.alt >= 0 ? p.s_ctr[p.alt] >= 4 : base_p;
        if (p.prov >= 0) {
            int c = p.s_ctr[p.prov];
            bool weak = (c == 3 || c == 4) && p.s_u[p.prov] == 0;
            p.pred = (weak && use_alt >= 8) ? alt_p : c >= 4;
        } else p.pred = base_p;
        head = (head + 1) & ghmask;
        gh[head] = tk;
        for (int j = 0; j < n; j++) {
            unsigned old = gh[(head - hists[j]) & ghmask];
            fi[j].update(tk, old);
            ft1[j].update(tk, old);
            ft2[j].update(tk, old);
        }
        return p;
    }

    // the update of a prediction with its outcome. stale: computed from the
    // entries as read at the prediction, and the entries it writes are
    // written whole (what other updates did to them in between is lost), as
    // OOO_TAGE does at commit; else from the entries as they are now
    void update(const Pred& p, bool tk, bool stale = false)
    {
        int e_tag[16]; uint8_t e_ctr[16], e_u[16];
        for (int j = 0; j < n; j++) {
            e_tag[j] = stale ? p.s_tag[j] : tag[j][p.idx[j]];
            e_ctr[j] = stale ? p.s_ctr[j] : ctr[j][p.idx[j]];
            e_u[j]   = stale ? p.s_u[j]   : u[j][p.idx[j]];
        }
        uint8_t e_base = stale ? p.s_base : base[p.bi];
        int prov = -1, alt = -1;
        for (int j = n - 1; j >= 0; j--)
            if (e_tag[j] == p.tg[j]) { if (prov < 0) prov = j; else { alt = j; break; } }
        bool base_p = e_base >= 2;
        bool alt_p = alt >= 0 ? e_ctr[alt] >= 4 : base_p;
        bool prov_p, pred;
        if (prov >= 0) {
            int c = e_ctr[prov];
            prov_p = c >= 4;
            bool weak = (c == 3 || c == 4) && e_u[prov] == 0;
            pred = (weak && use_alt >= 8) ? alt_p : prov_p;
            if (weak && prov_p != alt_p)
                use_alt = alt_p == tk ? (use_alt < 15 ? use_alt + 1 : 15) : (use_alt > 0 ? use_alt - 1 : 0);
        } else {
            prov_p = pred = base_p;
        }
        bool wr[16] = {false}, wb = false;
        if (pred != tk && prov < n - 1) {
            int fr[16], nf = 0;
            for (int j = prov + 1; j < n; j++) if (e_u[j] == 0) fr[nf++] = j;
            if (nf) {
                int j = (nf == 1 || (tick & 1)) ? fr[0] : fr[1];
                e_tag[j] = p.tg[j]; e_ctr[j] = tk ? 4 : 3; e_u[j] = 0; wr[j] = true;
            } else {
                for (int j = prov + 1; j < n; j++) if (e_u[j] > 0) { e_u[j]--; wr[j] = true; }
            }
        }
        auto upd = [tk](uint8_t& c, int mx) { c = tk ? (c < mx ? c + 1 : mx) : (c > 0 ? c - 1 : 0); };
        if (prov >= 0) {
            upd(e_ctr[prov], 7); wr[prov] = true;
            if (prov_p != alt_p) e_u[prov] = prov_p == tk ? (e_u[prov] < 3 ? e_u[prov] + 1 : 3) : (e_u[prov] > 0 ? e_u[prov] - 1 : 0);
            if (alt < 0 && e_u[prov] == 0) { upd(e_base, 3); wb = true; }
        } else {
            upd(e_base, 3); wb = true;
        }
        for (int j = 0; j < n; j++)
            if (wr[j]) { tag[j][p.idx[j]] = e_tag[j]; ctr[j][p.idx[j]] = e_ctr[j]; u[j][p.idx[j]] = e_u[j]; }
        if (wb) base[p.bi] = e_base;
        tick++;
        if ((tick & 0x3ffff) == 0)
            for (auto& t : u) for (auto& x : t) x >>= 1;
    }

    // predict and update at once (trace-driven). Returns the prediction.
    bool step(uint64_t pc, bool tk)
    {
        Pred p = predict(pc, tk);
        update(p, tk);
        return p.pred;
    }
};
