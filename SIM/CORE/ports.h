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
//   DCacheModel  the D$ as OOO_LSU's abstract port sees it (B3; OOO_DCAD and
//                mmRISC-2's D$ later): a load request in E (dc_req_*) is
//                answered in M, the cycle after: a hit (at random) gives the
//                8-byte word from Memory then; a miss gives it later as a
//                fill (dc_fill_*, tagged by the LQ entry, held until
//                dc_fill_ready), dropped if the LSU kills the entry
//                (dc_kill) first. Several misses may be outstanding; their
//                fills come in any order. A store (dc_st_*) is taken when
//                dc_st_ready (at random) and written into Memory at once:
//                Memory is the D$, and every load reads it, so nothing is
//                incoherent (the real D$'s lines come with B3b).
//   Axi4Mem      the D$'s memory bus (AXI4, OOO_CPU, B3b) on Memory: read and
//                write bursts (INCR, 8-byte beats), the readies, the read
//                data's first beat and the write responses after random
//                delays; reads in order, writes in order. Writes go into
//                Memory beat by beat (write64: HTIF sees them).
//   AxiLite      the D$'s peripheral bus (AXI4-Lite) on Memory: single
//                8-byte accesses, for what the D$ does not cache (the
//                bench's tohost line, DCACHE_SIM_UC).
//
// Used once a cycle: before the core's evaluation set its inputs from
// ready() / resp_valid() / resp_data(); after the clock edge call clock()
// with whether a request was accepted and its address.
//---------------------------------------------------------------------------
#pragma once
#include <cstdint>
#include <deque>
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

class DCacheModel {
public:
    // hit_pct: % of the load requests that hit; a miss's fill comes 2 + 0..(miss_lat - 1) cycles after its M
    DCacheModel(Memory& m, uint64_t seed, int hit_pct = 80, int miss_lat = 12, int st_ready_pct = 80)
        : m(m), rng(seed), hit_pct(hit_pct), miss_lat(miss_lat), st_ready_pct(st_ready_pct) {}
    // the core's inputs this cycle
    bool hit() const { return m_v && m_hit; }
    uint64_t rdata() { return m_v ? m.read64(m_addr & ~7ull) : 0; }
    bool fill_valid() const { return !fq.empty() && fq.front().due <= cyc; }
    int fill_tag() const { return fill_valid() ? fq.front().tag : 0; }
    uint64_t fill_data() { return fill_valid() ? m.read64(fq.front().addr & ~7ull) : 0; }
    bool st_ready() const { return st_rdy; }
    // the clock edge, with what the core gave this cycle
    void clock(bool req, uint64_t addr, int tag, unsigned kill, bool fill_ready,
               bool st_valid, uint64_t st_addr, uint64_t st_data, uint8_t st_mask)
    {
        if (fill_valid() && fill_ready) { fq.pop_front(); fills++; }
        for (size_t i = 0; i < fq.size();) if ((kill >> fq[i].tag) & 1) { fq.erase(fq.begin() + i); kills++; } else i++;
        if (m_v && !m_hit) {                       // the miss of this M: its fill later, in order of arrival
            Fill f{m_tag, m_addr, cyc + 2 + (long)(rng() % miss_lat)};
            size_t i = fq.size();
            while (i > 0 && fq[i - 1].due > f.due) i--;
            fq.insert(fq.begin() + i, f);
            misses++;
        }
        if (st_valid && st_rdy) { m.write64(st_addr, st_data, st_mask); stores++; }
        m_v = req; m_addr = addr; m_tag = tag; m_hit = req && (int)(rng() % 100) < hit_pct;
        reqs += req;
        st_rdy = (int)(rng() % 100) < st_ready_pct;
        cyc++;
    }
    long reqs = 0, misses = 0, fills = 0, kills = 0, stores = 0;
private:
    struct Fill { int tag; uint64_t addr; long due; };
    Memory& m;
    std::mt19937_64 rng;
    int hit_pct, miss_lat, st_ready_pct;
    bool m_v = false, m_hit = false, st_rdy = true;
    uint64_t m_addr = 0;
    int m_tag = 0;
    long cyc = 0;
    std::deque<Fill> fq;
};

class Axi4Mem {
public:
    Axi4Mem(Memory& m, uint64_t seed) : m(m), rng(seed) {}
    // the inputs of this cycle (call once, before the core's evaluation)
    void drive() {
        arready = rng() % 4 != 0; awready = rng() % 4 != 0;
        wready  = !wq.empty() && rng() % 4 != 0;
        rvalid  = !rq.empty() && rq.front().at <= cyc && rng() % 5 != 0;
        bvalid  = !bq.empty() && bq.front().at <= cyc && rng() % 3 != 0;
        rdata   = rvalid ? m.read64(rq.front().addr + 8 * rq.front().beat) : 0;
        rlast   = rvalid && rq.front().beat == rq.front().len;
    }
    bool arready = false, awready = false, wready = false, rvalid = false, rlast = false, bvalid = false;
    uint64_t rdata = 0;
    // the clock edge: what the core gave this cycle
    void clock(bool arvalid, uint64_t araddr, int arlen, bool rready, bool awvalid, uint64_t awaddr, int awlen,
               bool wvalid, uint64_t wdata, uint8_t wstrb, bool bready)
    {
        if (wvalid && wready) {
            Burst& x = wq.front();
            m.write64(x.addr + 8 * x.beat, wdata, wstrb);
            if (++x.beat > x.len) { Burst y = x; wq.pop_front(); y.at = cyc + 1 + (long)(rng() % 6); bq.push_back(y); }
        }
        if (rvalid && rready && ++rq.front().beat > rq.front().len) rq.pop_front();
        if (bvalid && bready) bq.pop_front();
        if (arvalid && arready) { rq.push_back(Burst{araddr, arlen, 0, cyc + 3 + (long)(rng() % 14)}); reads++; }
        if (awvalid && awready) { wq.push_back(Burst{awaddr, awlen, 0, 0}); writes++; }
        cyc++;
    }
    long reads = 0, writes = 0;
private:
    struct Burst { uint64_t addr; int len, beat; long at; };
    Memory& m;
    std::mt19937_64 rng;
    std::deque<Burst> rq, wq, bq;
    long cyc = 0;
};

class AxiLite {
public:
    AxiLite(Memory& m, uint64_t seed) : m(m), rng(seed) {}
    void drive() {
        arready = !r_pend && rng() % 3 != 0;
        awready = !aw_have && !b_pend && rng() % 3 != 0;
        wready  = !w_have && !b_pend && rng() % 3 != 0;
        rvalid  = r_pend && r_at <= cyc;
        bvalid  = b_pend && b_at <= cyc;
    }
    bool arready = false, awready = false, wready = false, rvalid = false, bvalid = false;
    uint64_t rdata = 0;
    void clock(bool arvalid, uint64_t araddr, bool rready, bool awvalid, uint64_t awaddr,
               bool wvalid, uint64_t wdata, uint8_t wstrb, bool bready)
    {
        if (rvalid && rready) r_pend = false;
        if (bvalid && bready) b_pend = false;
        if (arvalid && arready) { r_pend = true; r_at = cyc + 1 + (long)(rng() % 4); rdata = m.read64(araddr & ~7ull); reads++; }
        if (awvalid && awready) { aw_have = true; aw_addr = awaddr; }
        if (wvalid && wready)   { w_have = true; w_data = wdata; w_strb = wstrb; }
        if (aw_have && w_have) {
            m.write64(aw_addr & ~7ull, w_data, w_strb);
            aw_have = w_have = false; b_pend = true; b_at = cyc + 1 + (long)(rng() % 4); writes++;
        }
        cyc++;
    }
    long reads = 0, writes = 0;
private:
    Memory& m;
    std::mt19937_64 rng;
    bool r_pend = false, b_pend = false, aw_have = false, w_have = false;
    long r_at = 0, b_at = 0, cyc = 0;
    uint64_t aw_addr = 0, w_data = 0;
    uint8_t w_strb = 0;
};
