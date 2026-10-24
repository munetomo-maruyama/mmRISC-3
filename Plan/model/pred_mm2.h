//---------------------------------------------------------------------------
// pred_mm2.h : the branch prediction of mmRISC-2 (CPU_CORE_SPEC.md 4.2,
// decisions 56, 57 and 63), as seen from the correct path
//
//   BTB: direct mapped, indexed by the 8-byte fetch word; an entry belongs
//   to one branch (owner) and is made or changes owner only for a taken
//   control transfer without an entry. Branches without an entry are
//   predicted not taken.
//   Direction of conditional branches: gshare (PHT indexed by the word
//   address XOR the history folded into the upper index bits; the history
//   holds the directions of the branches that have an entry), or, before
//   gshare, the 2-bit counter of the entry. Counters start weakly taken.
//   Returns: a return address stack (calls push, returns pop; on the
//   correct path the fetch side and the execute side agree).
//
// What is simplified: the tail entries of branches across words are kept
// in the word of the branch's first parcel; misfetches do not happen.
//---------------------------------------------------------------------------
#pragma once
#include "model.h"

struct PredMm2 {
    struct Ent { bool v = false; uint64_t owner = 0, target = 0; uint8_t cnt = 2; };
    std::vector<Ent> btb;
    std::vector<uint8_t> pht;
    std::vector<uint64_t> ras;
    int ras_top = 0, ras_n = 0;
    unsigned hist = 0;
    int nbtb, npht, hbits;
    bool gshare;
    // counts by kind: executed and mispredicted
    long n_br = 0, m_br = 0, n_jal = 0, m_jal = 0, n_jalr = 0, m_jalr = 0;

    PredMm2(int btb_entries, int pht_entries, int hist_bits, int ras_entries, bool use_gshare)
        : btb(btb_entries), pht(pht_entries, 2), ras(ras_entries), nbtb(btb_entries),
          npht(pht_entries), hbits(hist_bits), gshare(use_gshare) {}

    int pht_index(uint64_t pc) const
    {
        int ibits = 0;
        while ((1 << ibits) < npht) ibits++;
        unsigned word = (unsigned)(pc >> 3) & (npht - 1);
        return (int)((word ^ (hist << (ibits - hbits))) & (npht - 1));
    }

    void push(uint64_t a) { ras[ras_top] = a; ras_top = (ras_top + 1) % (int)ras.size(); if (ras_n < (int)ras.size()) ras_n++; }
    uint64_t pop()
    {
        if (ras_n == 0) return 0;
        ras_top = (ras_top + (int)ras.size() - 1) % (int)ras.size();
        ras_n--;
        return ras[ras_top];
    }

    // one control transfer of the trace; returns true if it was mispredicted
    bool step(const Rec& r, uint64_t next_pc)
    {
        bool taken = r.flags & F_TAKEN;
        Ent& e = btb[(r.pc >> 3) & (nbtb - 1)];
        bool hit = e.v && e.owner == r.pc;
        bool miss;
        if (r.cls == C_BR) {
            n_br++;
            bool pt = false;
            int pi = pht_index(r.pc);
            if (hit) pt = gshare ? pht[pi] >= 2 : e.cnt >= 2;
            miss = pt != taken;
            if (hit) {
                uint8_t& c = gshare ? pht[pi] : e.cnt;
                c = taken ? (c < 3 ? c + 1 : 3) : (c > 0 ? c - 1 : 0);
                hist = ((hist << 1) | (taken ? 1 : 0)) & ((1u << hbits) - 1);
            } else if (taken) {
                e.v = true; e.owner = r.pc; e.target = next_pc; e.cnt = 2;
            }
            if (miss) m_br++;
        } else {
            uint64_t pt = 0;
            if (hit) pt = (r.flags & F_RET) ? pop() : e.target;
            else if (r.flags & F_RET) pop();    // the stack still pops on the execute side
            miss = !hit || pt != next_pc;
            if (r.cls == C_JAL) { n_jal++; if (miss) m_jal++; }
            else { n_jalr++; if (miss) m_jalr++; }
            e.v = true; e.owner = r.pc; e.target = next_pc;
            if (r.flags & F_CALL) push(r.pc + r.size);
        }
        return miss;
    }
};
