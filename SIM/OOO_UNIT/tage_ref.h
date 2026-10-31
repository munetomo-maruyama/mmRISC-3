//---------------------------------------------------------------------------
// tage_ref.h : the reference of OOO_TAGE (TAGE-S per fetch block), written
// from its specification for tb_tage and tb_fetch
//
// read() is F0 (the rows of the block, before this cycle's update); f2()
// gives the predictions and the metadata (the same bits as OOO_TAGE's
// f2_meta); update() and push() / restore() change the state at the clock.
//---------------------------------------------------------------------------
#pragma once
#include <cstdint>
#include <vector>

struct Bits {               // a wide vector of bits, as Verilator's VlWide words
    std::vector<uint32_t> w;
    explicit Bits(int n = 0) : w((n + 31) / 32, 0) {}
    uint64_t get(int lo, int n) const {
        uint64_t v = 0;
        for (int b = 0; b < n; b++) v |= (uint64_t)((w[(lo + b) / 32] >> ((lo + b) % 32)) & 1) << b;
        return v;
    }
    void set(int lo, int n, uint64_t v) {
        for (int b = 0; b < n; b++) {
            uint32_t m = 1u << ((lo + b) % 32);
            if ((v >> b) & 1) w[(lo + b) / 32] |= m; else w[(lo + b) / 32] &= ~m;
        }
    }
};

struct TageRef {
    static const int NT = 4, NLOG = 10, HMAX = 70, HREG = 76, MW = 272;
    // the metadata fields (low bit, width), as OOO_TAGE's packed struct
    static const int M_IDX = 0, M_TAG = 40, M_ROW = 76, M_BASE = 160, M_BIDX = 176, M_PAR = 185, M_SV = 194, M_PRED = 197, M_HIST = 200, M_CPREV = 270;
    static int tw(int j) { return j < 2 ? 8 : 9; }
    static int hl(int j) { static const int L[4] = {5, 12, 30, 70}; return L[j]; }

    uint32_t tbl[NT][1 << NLOG];
    uint16_t base[512];
    bool h[HREG] = {false};         // h[0] newest (76: 70 and what a shift of 6 takes, D-17)
    int c1 = 0, c2 = 0;             // the bit counts of the last block pushed and the one before
    int use_alt = 8, tick = 0;

    TageRef() {
        for (auto& t : tbl) for (auto& r : t) r = 0;
        for (auto& b : base) b = 0xaaaa;
    }

    unsigned fold(int L, int c, int sh) const {    // the history past sh bits
        unsigned v = 0;
        for (int k = 0; k < L; k++) v ^= (unsigned)h[k + sh] << (k % c);
        return v;
    }

    struct Rd { unsigned idx[NT], tag[NT], row[NT]; unsigned base, bidx; };

    // F0: pc is the halfword address (pc >> 1 of the byte address); live: the blocks read before
    // this one not pushed yet (D-17: the history lacks the 2 blocks before, always)
    Rd read(uint64_t pc, int live) const {
        Rd r;
        int sh = live >= 2 ? 0 : live == 1 ? c1 : c1 + c2;
        for (int j = 0; j < NT; j++) {
            unsigned fi = fold(hl(j), NLOG, sh), f1 = fold(hl(j), tw(j), sh), f2 = fold(hl(j), tw(j) - 1, sh);
            r.idx[j] = (unsigned)((pc ^ (pc >> (NLOG - j)) ^ fi) & ((1u << NLOG) - 1));
            r.tag[j] = (unsigned)((pc ^ f1 ^ ((uint64_t)f2 << 1)) & ((1u << tw(j)) - 1));
            r.row[j] = tbl[j][r.idx[j]];
        }
        r.bidx = (unsigned)((pc >> 3) & 511);
        r.base = base[r.bidx];
        return r;
    }

    static bool rv(unsigned row) { return (row >> 20) & 1; }
    static unsigned rtag(unsigned row) { return (row >> 11) & 511; }
    static unsigned ru(unsigned row) { return (row >> 9) & 3; }
    static unsigned rc(unsigned row, int s) { return (row >> (3 * s)) & 7; }

    // provider and alternate: the highest hit and the next
    static void pa(const unsigned row[NT], const unsigned tag[NT], int& pj, int& aj) {
        pj = -1; aj = -1;
        for (int j = 0; j < NT; j++) if (rv(row[j]) && rtag(row[j]) == tag[j]) { aj = pj; pj = j; }
    }

    // F2: predictions for the slots and the metadata
    void f2(const Rd& r, int sv, const int par[3], int& pred, int& basebits, Bits& m) const {
        int pj, aj;
        pa(r.row, r.tag, pj, aj);
        basebits = 0;
        for (int e = 0; e < 8; e++) basebits |= ((r.base >> (2 * e + 1)) & 1) << e;
        pred = 0;
        for (int s = 0; s < 3; s++) {
            bool bp = (basebits >> par[s]) & 1;
            bool ap = aj >= 0 ? (rc(r.row[aj], s) >> 2) & 1 : bp;
            bool p = bp;
            if (pj >= 0) {
                unsigned c = rc(r.row[pj], s);
                bool weak = (c == 3 || c == 4) && ru(r.row[pj]) == 0;
                p = (weak && use_alt >= 8) ? ap : (c >> 2) & 1;
            }
            pred |= p << s;
        }
        m = Bits(MW);
        for (int j = 0; j < NT; j++) {
            m.set(M_IDX + 10 * j, 10, r.idx[j]);
            m.set(M_TAG + 9 * j, 9, r.tag[j]);
            m.set(M_ROW + 21 * j, 21, r.row[j]);
        }
        m.set(M_BASE, 16, r.base);
        m.set(M_BIDX, 9, r.bidx);
        for (int s = 0; s < 3; s++) m.set(M_PAR + 3 * s, 3, par[s]);
        m.set(M_SV, 3, sv);
        m.set(M_PRED, 3, pred);
        for (int k = 0; k < HMAX; k++) m.set(M_HIST + k, 1, h[k]);
        m.set(M_CPREV, 2, c1);
    }

    void push(int n, int bits) {          // bits: slot 0 in bit 0, pushed first
        for (int s = 0; s < n; s++) {
            for (int k = HREG - 1; k > 0; k--) h[k] = h[k - 1];
            h[0] = (bits >> s) & 1;
        }
        c2 = c1; c1 = n;
    }
    void restore(const Bits& m, int n, int bits) {
        for (int k = 0; k < HREG; k++) h[k] = k < HMAX ? m.get(M_HIST + k, 1) : false;
        int cp = (int)m.get(M_CPREV, 2);
        push(n, bits);
        c2 = cp;
    }

    static unsigned sat(unsigned c, bool t, unsigned mx) { return t ? (c < mx ? c + 1 : mx) : (c > 0 ? c - 1 : 0); }

    // the update at commit: the slots that ran (a prefix) and their outcomes
    void update(const Bits& m, int ex, int tk) {
        if (ex == 0) return;
        unsigned idx[NT], tag[NT], row[NT], par[3];
        for (int j = 0; j < NT; j++) { idx[j] = (unsigned)m.get(M_IDX + 10 * j, 10); tag[j] = (unsigned)m.get(M_TAG + 9 * j, 9); row[j] = (unsigned)m.get(M_ROW + 21 * j, 21); }
        for (int s = 0; s < 3; s++) par[s] = (unsigned)m.get(M_PAR + 3 * s, 3);
        unsigned bidx = (unsigned)m.get(M_BIDX, 9), brow = (unsigned)m.get(M_BASE, 16);
        int pred = (int)m.get(M_PRED, 3);
        int pj, aj;
        pa(row, tag, pj, aj);
        unsigned u = pj >= 0 ? ru(row[pj]) : 0, c[3];
        for (int s = 0; s < 3; s++) c[s] = pj >= 0 ? rc(row[pj], s) : 0;
        unsigned b[8];
        for (int e = 0; e < 8; e++) b[e] = (brow >> (2 * e)) & 3;
        bool alloc = false, dec = false; int ja = -1; unsigned init[3] = {0, 0, 0};
        for (int s = 0; s < 3; s++) {
            if (!((ex >> s) & 1)) continue;
            bool t = (tk >> s) & 1;
            bool bp = b[par[s]] >= 2;
            bool ap = aj >= 0 ? (rc(row[aj], s) >> 2) & 1 : bp;
            bool pp = pj >= 0 ? (c[s] >> 2) & 1 : bp;
            bool weak = pj >= 0 && (c[s] == 3 || c[s] == 4) && u == 0;
            if (weak && pp != ap) use_alt = ap == t ? (use_alt < 15 ? use_alt + 1 : 15) : (use_alt > 0 ? use_alt - 1 : 0);
            if ((bool)((pred >> s) & 1) != t && pj < NT - 1 && !alloc && !dec) {
                int fr[4], nf = 0;
                for (int j = pj + 1; j < NT; j++) if (ru(row[j]) == 0) fr[nf++] = j;
                if (nf) {
                    alloc = true;
                    int par_tick = tick ^ (s & 1);
                    ja = (nf >= 2 && !par_tick) ? fr[1] : fr[0];
                    for (int q = 0; q < 3; q++)
                        init[q] = q == s ? t : (aj >= 0 ? (rc(row[aj], q) >> 2) & 1 : b[par[q]] >= 2);
                } else dec = true;
            }
            if (pj >= 0) {
                c[s] = sat(c[s], t, 7);
                if (pp != ap) u = sat(u, pp == t, 3);
                if (aj < 0 && u == 0) b[par[s]] = sat(b[par[s]], t, 3);
            } else b[par[s]] = sat(b[par[s]], t, 3);
        }
        tick ^= __builtin_popcount(ex) & 1;
        for (int j = 0; j < NT; j++) {
            if (j == pj) tbl[j][idx[j]] = (row[j] & ~0x7ffu) | (u << 9) | (c[2] << 6) | (c[1] << 3) | c[0];
            else if (alloc && j == ja)
                tbl[j][idx[j]] = (1u << 20) | (tag[j] << 11) | ((init[2] ? 4u : 3u) << 6) | ((init[1] ? 4u : 3u) << 3) | (init[0] ? 4u : 3u);
            else if (dec && j > pj && ru(row[j]) != 0) tbl[j][idx[j]] = row[j] - (1u << 9);
        }
        unsigned nb = 0;
        for (int e = 0; e < 8; e++) nb |= b[e] << (2 * e);
        base[bidx] = (uint16_t)nb;
    }
};
