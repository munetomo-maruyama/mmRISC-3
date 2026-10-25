//---------------------------------------------------------------------------
// tageblk.h : TAGE as it can be built in block RAM, per fetch block
//
// The TAGE of tage.h predicts one branch at a time, indexed by its own pc,
// with one history bit per branch, updated at once. In hardware the tables
// are read in F1 with the fetch address only, before the instructions of
// the block are known (they are found by predecode in F2), and up to
// several conditional branches lie in one 16-byte block. Here:
//
//   - the tagged tables are indexed and tagged by the block's fetch
//     address and the history; a row has one tag, one useful counter and
//     `slots` direction counters, for the first, second, ... conditional
//     branch of the block (in program order from the fetch address)
//   - branches past the slots use the base table only
//   - the base table is bimodal per parcel (the parcel of the branch's
//     last half), so a block reads one row of 8 counters
//   - the folded histories are computed directly from the last L history
//     bits (the same values as Seznec's incremental update)
//   - history bits: one per conditional branch (`hist` = 0: all of them,
//     1: only those in slots); `lag` blocks before this one are not yet in
//     the history used to index it (the blocks in F1 and F2 when it is in
//     F0)
//   - provider and alternate are the same for every slot (one tag per
//     row); a misprediction (at most one per block, it ends the block)
//     allocates one row; the row's other slot starts weak, as the
//     alternate predicts
//
// Blocks are cut from the correct path: a block starts at the fetch
// address, ends at a taken transfer, at the end of the 16-byte line, or at
// a conditional branch predicted taken but not taken (fetch restarts after
// it); a 32-bit instruction across two lines belongs to the second block.
//---------------------------------------------------------------------------
#pragma once
#include <cstdint>
#include <vector>
#include "model.h"

struct TageBlk {
    int blog = 12, nlog = 10, n = 4, slots = 2, hist = 0, lag = 0;
    bool halve = true;          // halve the useful counters every 256K branches
    std::vector<int> tags{8, 8, 9, 9}, hists{5, 12, 30, 70};
    std::vector<uint8_t> base;
    std::vector<std::vector<uint8_t>> u;
    std::vector<std::vector<int>> tag;
    std::vector<std::vector<std::vector<uint8_t>>> ctr;   // [table][row][slot]
    std::vector<uint8_t> gh;                              // all history bits, oldest first
    std::vector<size_t> blk_hlen;                         // history length after each block
    int use_alt = 8;
    long nbr = 0;
    long stat_blocks = 0, stat_br = 0, stat_miss = 0, stat_past = 0, stat_nbr[8] = {0};

    TageBlk(int slots_, int hist_, int lag_) : slots(slots_), hist(hist_), lag(lag_)
    {
        base.assign(1u << blog, 2);
        for (int j = 0; j < n; j++) {
            u.emplace_back(1u << nlog, 0);
            tag.emplace_back(1u << nlog, -1);
            ctr.emplace_back(1u << nlog, std::vector<uint8_t>(slots, 4));
        }
    }

    // the last L bits of the history up to length hl, folded to c bits
    unsigned fold(size_t hl, int L, int c) const
    {
        unsigned v = 0;
        for (int k = 0; k < L && (size_t)k < hl; k++) v ^= (unsigned)gh[hl - 1 - k] << (k % c);
        return v;
    }

    struct Br { uint64_t pc_end; bool tk; };
    // one block: its fetch address and its conditional branches in order.
    // Returns the number mispredicted (0 or 1); `stop` = the index of the
    // first mispredicted branch (the block ends there), or the count.
    int block(uint64_t start, const std::vector<Br>& br, size_t& stop)
    {
        stat_blocks++;
        size_t hl = blk_hlen.size() > (size_t)lag ? blk_hlen[blk_hlen.size() - 1 - lag] : 0;
        uint64_t pcs = start >> 1;
        unsigned nmask = (1u << nlog) - 1;
        int idx[8], tg[8];
        for (int j = 0; j < n; j++) {
            unsigned fi = fold(hl, hists[j], nlog);
            unsigned f1 = fold(hl, hists[j], tags[j]), f2 = fold(hl, hists[j], tags[j] - 1);
            idx[j] = (int)((pcs ^ (pcs >> (nlog - j)) ^ fi) & nmask);
            tg[j] = (int)((pcs ^ f1 ^ ((uint64_t)f2 << 1)) & ((1u << tags[j]) - 1));
        }
        int prov = -1, alt = -1;
        for (int j = n - 1; j >= 0; j--)
            if (tag[j][idx[j]] == tg[j]) { if (prov < 0) prov = j; else { alt = j; break; } }
        int misses = 0;
        stop = br.size();
        for (size_t s = 0; s < br.size(); s++) {
            bool tk = br[s].tk;
            unsigned bi = (unsigned)((br[s].pc_end >> 1) & ((1u << blog) - 1));
            bool base_p = base[bi] >= 2;
            bool pred;
            auto upd = [tk](uint8_t& c, int mx) { c = tk ? (c < mx ? c + 1 : mx) : (c > 0 ? c - 1 : 0); };
            stat_br++;
            if ((int)s >= slots) {
                stat_past++;
                pred = base_p;
                upd(base[bi], 3);
            } else {
                bool alt_p = alt >= 0 ? ctr[alt][idx[alt]][s] >= 4 : base_p;
                bool prov_p;
                if (prov >= 0) {
                    int c = ctr[prov][idx[prov]][s];
                    prov_p = c >= 4;
                    bool weak = (c == 3 || c == 4) && u[prov][idx[prov]] == 0;
                    pred = (weak && use_alt >= 8) ? alt_p : prov_p;
                    if (weak && prov_p != alt_p)
                        use_alt = alt_p == tk ? (use_alt < 15 ? use_alt + 1 : 15) : (use_alt > 0 ? use_alt - 1 : 0);
                } else prov_p = pred = base_p;
                if (pred != tk && prov < n - 1) {
                    int fr[8], nf = 0;
                    for (int j = prov + 1; j < n; j++) if (u[j][idx[j]] == 0) fr[nf++] = j;
                    if (nf) {
                        int j = (nf == 1 || (nbr & 1)) ? fr[0] : fr[1];
                        tag[j][idx[j]] = tg[j];
                        for (int q = 0; q < slots; q++) {
                            bool ap = alt >= 0 ? ctr[alt][idx[alt]][q] >= 4 : base_p;
                            ctr[j][idx[j]][q] = (q == (int)s ? tk : ap) ? 4 : 3;
                        }
                        u[j][idx[j]] = 0;
                    } else {
                        for (int j = prov + 1; j < n; j++) if (u[j][idx[j]] > 0) u[j][idx[j]]--;
                    }
                }
                if (prov >= 0) {
                    upd(ctr[prov][idx[prov]][s], 7);
                    if (prov_p != alt_p) {
                        uint8_t& uu = u[prov][idx[prov]];
                        uu = prov_p == tk ? (uu < 3 ? uu + 1 : 3) : (uu > 0 ? uu - 1 : 0);
                    }
                    if (alt < 0 && u[prov][idx[prov]] == 0) upd(base[bi], 3);
                } else upd(base[bi], 3);
            }
            if (hist == 0 || (hist == 1 && (int)s < slots)) gh.push_back(tk);
            nbr++;
            if (halve && (nbr & 0x3ffff) == 0)
                for (auto& t : u) for (auto& x : t) x >>= 1;
            if (pred != tk) { misses++; stat_miss++; stop = s; break; }
        }
        size_t nb = stop < br.size() ? stop + 1 : br.size();
        if (hist == 2)          // exactly 2 bits a block: the slots, 0 when no branch
            for (int q = 0; q < 2; q++) gh.push_back((size_t)q < nb && q < (int)br.size() ? br[q].tk : 0);

        stat_nbr[nb < 7 ? nb : 7]++;
        blk_hlen.push_back(gh.size());
        return misses;
    }

    // the correct path of a trace cut into blocks (see the header)
    void run(const std::vector<Rec>& t)
    {
        uint64_t start = 0; bool open = false;
        std::vector<Br> br;
        std::vector<size_t> bri;       // trace index of each branch of the block
        auto close = [&](size_t next_i) -> size_t {   // returns where the next block starts
            size_t stop;
            block(start, br, stop);
            size_t r = next_i;
            if (stop < br.size()) r = bri[stop] + 1;    // fetch restarts after the miss
            br.clear(); bri.clear(); open = false;
            return r;
        };
        for (size_t i = 0; i < t.size();) {
            const Rec& r = t[i];
            uint64_t line = r.pc >> 4, line_end = (r.pc + r.size - 2) >> 4;
            if (!open) { start = r.pc; open = true; }
            else if (line != (start >> 4) && line_end != (start >> 4)) { i = close(i); continue; }
            if (line_end != (start >> 4) && line == (start >> 4)) {   // across: it goes with the next block
                size_t nx = close(i);
                if (nx == i) { start = r.pc + 2; open = true; }
                i = nx;
                continue;
            }
            if (r.cls == C_BR) { br.push_back(Br{r.pc + r.size - 2, (bool)(r.flags & F_TAKEN)}); bri.push_back(i); }
            bool taken = is_cti(r) && (r.flags & F_TAKEN);
            bool last = ((r.pc + r.size - 2) & 15) == 14;
            i++;
            if (taken || last) i = close(i);
        }
        if (open) close(t.size());
    }
};
