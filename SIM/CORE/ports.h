//---------------------------------------------------------------------------
// ports.h : models of the core's memory ports on the bench's Memory
// (Plan/CORE.md section 5)
//
//   ICacheModel  the I$ as OOO_FETCH expects it (mmRISC-2's ICACHE, 16
//                bytes wide; Plan/OOC.md 14.2, decision 4.6): a request
//                accepted at F0 is answered 2 cycles later on a hit, later
//                on a miss, in order; while a miss is served no request is
//                accepted (a request is accepted the cycle after another
//                only if that one hits). Every accepted request is answered.
//                The answer is the 16-byte line of the request, read from
//                Memory when it is given (no cache state: FENCE.I has
//                nothing to invalidate). Misses are drawn at random.
//
// Used once a cycle: before the core's evaluation set its inputs from
// ready() / resp_valid() / resp_data(); after the clock edge call clock()
// with whether a request was accepted and its address.
//---------------------------------------------------------------------------
#pragma once
#include <cstdint>
#include <random>

#include "bench.h"

class ICacheModel {
public:
    // miss_pct: % of the requests that miss; a miss is answered 2 + 2..(1 + miss_lat) cycles after the request
    ICacheModel(Memory& m, uint64_t seed, int miss_pct = 8, int miss_lat = 10)
        : m(m), rng(seed), miss_pct(miss_pct), miss_lat(miss_lat) {}
    bool ready() const { return miss_cnt == 0 && !(s1_v && s1_miss); }
    bool resp_valid() const { return rq_v; }
    // the answer: 4 words, parcel 2k in the low half of word k
    void resp_data(uint32_t w[4]) const { m.read((rq_pc << 1) & ~15ull, w, 16); }
    // the clock edge: acc = a request accepted in this cycle at the halfword address pc
    void clock(bool acc, uint64_t pc)
    {
        bool nv = false; uint64_t npc = 0;
        if (miss_cnt > 0 && --miss_cnt == 0) { nv = true; npc = miss_pc; }
        if (s1_v && !s1_miss) { nv = true; npc = s1_pc; }
        if (s1_v && s1_miss) { miss_cnt = 2 + (int)(rng() % miss_lat); miss_pc = s1_pc; misses++; }
        rq_v = nv; rq_pc = npc;
        s1_v = acc; s1_pc = pc; s1_miss = acc && (int)(rng() % 100) < miss_pct;
        reqs += acc;
    }
    long reqs = 0, misses = 0;
private:
    Memory& m;
    std::mt19937_64 rng;
    int miss_pct, miss_lat;
    bool s1_v = false, s1_miss = false, rq_v = false;
    uint64_t s1_pc = 0, rq_pc = 0, miss_pc = 0;
    int miss_cnt = 0;
};
