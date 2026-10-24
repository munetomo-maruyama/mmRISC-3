//---------------------------------------------------------------------------
// tage.h : TAGE (Seznec), the same predictor as Tage of ../trace/analyze.py
//
// A bimodal base and tagged tables with geometric histories; 3-bit
// counters, 2-bit useful counters, use-alt-on-new-allocation, allocation of
// one entry on a misprediction, halving of the useful counters every 256K
// branches. step() predicts and then updates at once (trace-driven).
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

    // the prediction for pc; then the update with the outcome. Returns the prediction.
    bool step(uint64_t pc, bool tk)
    {
        uint64_t pcs = pc >> 1;
        unsigned nmask = (1u << nlog) - 1;
        int idx[16], tg[16];
        for (int j = 0; j < n; j++) {
            idx[j] = (int)((pcs ^ (pcs >> (nlog - j)) ^ fi[j].comp) & nmask);
            tg[j] = (int)((pcs ^ ft1[j].comp ^ ((uint64_t)ft2[j].comp << 1)) & ((1u << tags[j]) - 1));
        }
        int prov = -1, alt = -1;
        for (int j = n - 1; j >= 0; j--) {
            if (tag[j][idx[j]] == tg[j]) {
                if (prov < 0) prov = j;
                else { alt = j; break; }
            }
        }
        unsigned bi = (unsigned)(pcs & ((1u << blog) - 1));
        bool base_p = base[bi] >= 2;
        bool alt_p = alt >= 0 ? ctr[alt][idx[alt]] >= 4 : base_p;
        bool prov_p, pred;
        if (prov >= 0) {
            int c = ctr[prov][idx[prov]];
            prov_p = c >= 4;
            bool weak = (c == 3 || c == 4) && u[prov][idx[prov]] == 0;
            pred = (weak && use_alt >= 8) ? alt_p : prov_p;
            if (weak && prov_p != alt_p)
                use_alt = alt_p == tk ? (use_alt < 15 ? use_alt + 1 : 15) : (use_alt > 0 ? use_alt - 1 : 0);
        } else {
            prov_p = pred = base_p;
        }
        if (pred != tk && prov < n - 1) {
            int fr[16], nf = 0;
            for (int j = prov + 1; j < n; j++) if (u[j][idx[j]] == 0) fr[nf++] = j;
            if (nf) {
                int j = (nf == 1 || (tick & 1)) ? fr[0] : fr[1];
                tag[j][idx[j]] = tg[j];
                ctr[j][idx[j]] = tk ? 4 : 3;
                u[j][idx[j]] = 0;
            } else {
                for (int j = prov + 1; j < n; j++) if (u[j][idx[j]] > 0) u[j][idx[j]]--;
            }
        }
        auto upd = [tk](uint8_t& c, int mx) { c = tk ? (c < mx ? c + 1 : mx) : (c > 0 ? c - 1 : 0); };
        if (prov >= 0) {
            upd(ctr[prov][idx[prov]], 7);
            if (prov_p != alt_p) {
                uint8_t& uu = u[prov][idx[prov]];
                uu = prov_p == tk ? (uu < 3 ? uu + 1 : 3) : (uu > 0 ? uu - 1 : 0);
            }
            if (alt < 0 && u[prov][idx[prov]] == 0) upd(base[bi], 3);
        } else {
            upd(base[bi], 3);
        }
        tick++;
        if ((tick & 0x3ffff) == 0)
            for (auto& t : u) for (auto& x : t) x >>= 1;
        head = (head + 1) & ghmask;
        gh[head] = tk;
        for (int j = 0; j < n; j++) {
            unsigned old = gh[(head - hists[j]) & ghmask];
            fi[j].update(tk, old);
            ft1[j].update(tk, old);
            ft2[j].update(tk, old);
        }
        return pred;
    }
};
