//---------------------------------------------------------------------------
// predec_ref.h : the reference of OOO_PREDEC, written from the
// specification's tables with byte offsets (for tb_predec and tb_fetch)
//---------------------------------------------------------------------------
#pragma once
#include <cstdint>

struct Predec {
    int iv = 0, br = 0, jal = 0, jalr = 0, call = 0, ret = 0;   // per end parcel
    uint64_t tgt[8] = {0};                                     // halfword addresses
    bool cross = false;
};

inline int64_t predec_sx(uint64_t v, int b) { return (int64_t)(v << (64 - b)) >> (64 - b); }

// line: the 16-byte line (byte address / 16); p: its 8 parcels
inline Predec predec_ref(uint64_t line, int start, bool carry_v, uint16_t carry, const uint16_t p[8])
{
    const uint64_t HM = (1ull << 38) - 1;
    Predec r;
    auto link = [](uint32_t x) { return x == 1 || x == 5; };
    int q = carry_v ? -1 : start;
    while (q < 8) {
        uint32_t lo = q < 0 ? carry : p[q];
        bool big = (lo & 3) == 3;
        if (big && q == 7) { r.cross = true; break; }
        int e = big ? q + 1 : q;
        uint64_t pcb = line * 16 + (uint64_t)(q * 2);          // byte address (q = -1: the line before)
        r.iv |= 1 << e;
        if (big) {
            uint32_t i = lo | ((uint32_t)p[e] << 16);
            uint32_t op = i & 0x7f, rd = (i >> 7) & 31, rs1 = (i >> 15) & 31, f3 = (i >> 12) & 7;
            if (op == 0x63) {
                r.br |= 1 << e;
                int64_t off = predec_sx(((i >> 31) & 1) << 12 | ((i >> 7) & 1) << 11 | ((i >> 25) & 63) << 5 | ((i >> 8) & 15) << 1, 13);
                r.tgt[e] = ((pcb + off) >> 1) & HM;
            } else if (op == 0x6f) {
                r.jal |= 1 << e; if (link(rd)) r.call |= 1 << e;
                int64_t off = predec_sx(((i >> 31) & 1) << 20 | ((i >> 12) & 255) << 12 | ((i >> 20) & 1) << 11 | ((i >> 21) & 1023) << 1, 21);
                r.tgt[e] = ((pcb + off) >> 1) & HM;
            } else if (op == 0x67 && f3 == 0) {
                r.jalr |= 1 << e; if (link(rd)) r.call |= 1 << e; if (link(rs1) && !link(rd)) r.ret |= 1 << e;
            }
        } else {
            uint32_t c = lo, f3 = c >> 13, rs1 = (c >> 7) & 31, rs2 = (c >> 2) & 31;
            if ((c & 3) == 1 && f3 == 5) {
                r.jal |= 1 << e;
                uint64_t o = ((c >> 12) & 1) << 11 | ((c >> 11) & 1) << 4 | ((c >> 9) & 3) << 8 | ((c >> 8) & 1) << 10 |
                             ((c >> 7) & 1) << 6 | ((c >> 6) & 1) << 7 | ((c >> 3) & 7) << 1 | ((c >> 2) & 1) << 5;
                r.tgt[e] = ((pcb + predec_sx(o, 12)) >> 1) & HM;
            } else if ((c & 3) == 1 && (f3 == 6 || f3 == 7)) {
                r.br |= 1 << e;
                uint64_t o = ((c >> 12) & 1) << 8 | ((c >> 10) & 3) << 3 | ((c >> 5) & 3) << 6 | ((c >> 3) & 3) << 1 | ((c >> 2) & 1) << 5;
                r.tgt[e] = ((pcb + predec_sx(o, 9)) >> 1) & HM;
            } else if ((c & 3) == 2 && f3 == 4 && rs2 == 0 && rs1 != 0) {
                r.jalr |= 1 << e;
                if ((c >> 12) & 1) r.call |= 1 << e; else if (link(rs1)) r.ret |= 1 << e;
            }
        }
        q = e + 1;
    }
    return r;
}
