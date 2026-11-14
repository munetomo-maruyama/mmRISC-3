//---------------------------------------------------------------------------
// ports.h : models of the core's memory ports on the bench's Memory
// (Plan/CORE.md section 5)
//
//   ICacheModel  the I$ as OOO_FETCH2 expects it (mmRISC-2's ICACHE's timing,
//                32 bytes wide since step 1.5, F1b, Plan/OOC.md 29.39;
//                Plan/OOC.md 14.2, decision 4.6): a request
//                accepted at F0 is answered 2 cycles later on a hit, later
//                on a miss, in order; while a miss is served no request is
//                accepted (a request is accepted the cycle after another
//                only if that one hits). Every accepted request is answered.
//                The answer is the 32-byte line of the request, read from
//                Memory when it is given (no cache state: FENCE.I has
//                nothing to invalidate). Misses are drawn at random.
//
//   DMissModel   the miss handler behind OOO_LSU3 (step 1.3 E1, Plan/OOC.md 29.32), as
//                tb_lsu3 has it: a line asked for (miss_*, st_miss_*) is
//                filled in turn (its way's tag invalid, its 8 words from
//                Memory, its tag valid, fill_done with the asker's id);
//                the way a free one, else one at random but the set's last
//                written. Memory has every committed store (tb_core writes
//                them at commit), so a dirty line evicted needs no writing
//                back. HTIF's tohost is not cached (dc_uc_line: UcModel).
//   UcModel      a device's access (OOO_LSU3's uc_*, step 1.3 E1b): one at a
//                time, answered after a random delay on Memory.
//   Axi4Mem      the D$'s memory bus (AXI4, OOO_CPU, B3b) on Memory: read and
//                write bursts (INCR, 8-byte beats), the readies, the read
//                data's first beat and the write responses after random
//                delays, and now and then the writes held off for 20 to 50
//                cycles; reads in order, writes in order. Writes go into
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
#include <map>
#include <random>

#include "bench.h"

class ICacheModel {
public:
    // miss_pct: % of the requests that miss; a miss is answered 2 + 2..(1 + miss_lat) cycles after the request
    ICacheModel(Memory& m, uint64_t seed, int miss_pct = 8, int miss_lat = 10)
        : m(m), rng(seed), miss_pct(miss_pct), miss_lat(miss_lat) {}
    bool ready() const { return miss_cnt == 0 && !(s1_v && s1_miss); }
    bool resp_valid() const { return rq_v; }
    // the answer: 8 words, parcel 2k in the low half of word k
    void resp_data(uint32_t w[8]) const { m.read((rq_pc << 1) & ~31ull, w, 32); }
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

class DMissModel {
public:
    // fill_lat: a fill's start comes 0..fill_lat - 1 cycles after the ask (0: at once), its words with gaps at random
    DMissModel(Memory& m, uint64_t seed, int fill_lat = 0) : m(m), rng(seed), fill_lat(fill_lat)
    {
        for (auto& a : tag_ref) for (auto& b : a) b = 0;
        for (auto& a : v_ref) for (auto& b : a) b = false;
    }
    // the core's inputs this cycle (set them before its evaluation)
    struct Out { bool fill_done = false, done_v = false, tw_en = false, rf_en = false;
                 int done_id = 0, tw_way = 0, tw_set = 0, rf_way = 0, rf_addr = 0; uint64_t tw_tag = 0, rf_data = 0; };
    const Out& out() const { return o; }
    // the clock edge, with what the core gave this cycle
    // (since step 1.7c C2, Plan/OOC.md 29.68: 256 sets, the set {vx, the line's 11:6}, vx the virtual 13:12 the
    // core gives with each miss; untranslated, the line's own 13:12. A line is kept as {line, vx})
    void clock(bool miss_v, uint64_t miss_line, int miss_vx, int miss_id, bool st_miss_v, uint64_t st_miss_line, int st_miss_vx,
               bool dirty_set, int dirty_way, int dirty_idx, bool sq_drained)
    {
        if (dirty_set) last_way[dirty_idx & 255] = dirty_way;
        if (miss_v) { asks++; ask((miss_line << 2) | (uint64_t)miss_vx, miss_id); }
        if (st_miss_v) { st_asks++; ask((st_miss_line << 2) | (uint64_t)st_miss_vx, -1); }
        o = Out{};
        step(sq_drained);
        cyc++;
    }
    long asks = 0, st_asks = 0, fills = 0, evicts = 0, invals = 0;
private:
    Memory& m;
    std::mt19937_64 rng;
    int fill_lat;
    Out o;
    long cyc = 0;
    std::deque<uint64_t> mq;
    std::map<uint64_t, int> who;
    int state = 0, way = 0, word = 0, delay = 0;
    uint64_t line = 0;
    uint64_t tag_ref[256][4]; bool v_ref[256][4]; int last_way[256] = {0};
    int lset() const { return (int)(((line & 3) << 6) | ((line >> 2) & 63)); }
    void ask(uint64_t l, int id)
    {
        for (auto x : mq) if (x == l) return;
        if (state != 0 && line == l) return;
        mq.push_back(l);
        who[l] = id;
    }
    void done()
    {
        o.fill_done = true;
        if (who[line] >= 0) { o.done_v = true; o.done_id = who[line]; }
    }
    // OOO_LSU3's miss handler as tb_lsu3 has it (the tag invalid, 8 words, the tag valid, fill_done), on Memory: Memory
    // has every committed store (tb_core writes them at commit), so a line evicted dirty needs no writing back
    void step(bool sq_drained)
    {
        if (delay > 0) { delay--; return; }
        switch (state) {
        case 0:
            if (!mq.empty()) {
                line = mq.front(); mq.pop_front();
                int set = lset();
                uint64_t tag = line >> 8;
                bool have = false;
                for (int w = 0; w < 4; w++) if (v_ref[set][w] && tag_ref[set][w] == tag) have = true;
                if (have) { done(); break; }
                way = -1;
                for (int w = 0; w < 4 && way < 0; w++) if (!v_ref[set][w]) way = w;
                if (way < 0) { way = (int)(rng() % 4); if (way == last_way[set]) way = (way + 1) % 4; evicts++; }
                o.tw_en = true; o.tw_way = way; o.tw_set = set; o.tw_tag = tag_ref[set][way];   // (the valid bit goes)
                v_ref[set][way] = false;
                state = 1; word = 0; delay = fill_lat ? (int)(rng() % fill_lat) : 0;
            }
            break;
        case 1: {
            int set = lset();
            if (fill_lat && rng() % 3 == 0) break;
            o.rf_en = true; o.rf_way = way; o.rf_addr = set * 8 + word; o.rf_data = m.read64((line >> 2 << 6) + 8 * word);
            if (++word == 8) state = 2;
            break;
        }
        case 2: {
            int set = lset();
            uint64_t tag = line >> 8;
            o.tw_en = true; o.tw_way = way; o.tw_set = set; o.tw_tag = (1ull << 28) | tag;
            tag_ref[set][way] = tag; v_ref[set][way] = true;
            state = 3;
            break;
        }
        case 3:
            done(); fills++;
            state = 0;
            break;
        }
    }
};

class UcModel {
public:
    // a device's access (OOO_LSU3's uc_*, one at a time): answered 2 + 0..lat - 1 cycles later; a store is written into
    // Memory then (write64: HTIF sees it), a load reads the 8-byte word then
    UcModel(Memory& m, uint64_t seed, int lat = 8) : m(m), rng(seed), lat(lat) {}
    bool done() const { return busy && left == 0; }
    uint64_t rdata() const { return rd; }
    void clock(bool req, bool we, uint64_t addr, uint64_t wdata, uint8_t wmask)
    {
        if (done()) busy = false;
        else if (busy) { if (--left == 0) answer(); }
        if (req) {
            busy = true; a = addr & ~7ull; w = we; wd = wdata; wm = wmask;
            left = 2 + (int)(rng() % lat);
            (w ? writes : reads)++;
        }
    }
    long reads = 0, writes = 0;
private:
    Memory& m;
    std::mt19937_64 rng;
    int lat;
    bool busy = false, w = false;
    int left = 0;
    uint64_t a = 0, wd = 0, rd = 0;
    uint8_t wm = 0;
    void answer() { if (w) m.write64(a, wd, wm); else rd = m.read64(a); }
};

class Axi4Mem {
public:
    // mlat > 0: the board's memory (step 1.7 H3, Plan/OOC.md 29.58): a read's first beat mlat to mlat + 20 cycles
    // after its address, the beats then one a cycle; a write's answer mlat / 2 to mlat / 2 + 10 after its last
    // beat; the readies up, no stalls. 0: the tests' memory, below.
    Axi4Mem(Memory& m, uint64_t seed, int mlat = 0) : m(m), rng(seed), mlat(mlat) {}
    // the inputs of this cycle (call once, before the core's evaluation)
    void drive() {
        if (mlat > 0) {
            arready = awready = true;
            wready  = !wq.empty();
            rvalid  = !rq.empty() && rq.front().at <= cyc;
            bvalid  = !bq.empty() && bq.front().at <= cyc;
            rdata   = rvalid ? m.read64(rq.front().addr + 8 * rq.front().beat) : 0;
            rlast   = rvalid && rq.front().beat == rq.front().len;
            return;
        }
        // now and then the writes stall for 20 to 50 cycles (step 1.3 E2: the write queue fills, and what must wait
        // for the writes to reach Memory is seen to)
        if (stall == 0 && rng() % 300 == 0) stall = 20 + (int)(rng() % 31);
        arready = rng() % 4 != 0; awready = stall == 0 && rng() % 4 != 0;
        wready  = stall == 0 && !wq.empty() && rng() % 4 != 0;
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
            if (++x.beat > x.len) {
                Burst y = x; wq.pop_front();
                y.at = mlat > 0 ? cyc + mlat / 2 + (long)(rng() % 11) : cyc + 1 + (long)(rng() % 6);
                bq.push_back(y);
            }
        }
        if (rvalid && rready && ++rq.front().beat > rq.front().len) rq.pop_front();
        if (bvalid && bready) bq.pop_front();
        if (arvalid && arready) {
            rq.push_back(Burst{araddr, arlen, 0, mlat > 0 ? cyc + mlat + (long)(rng() % 21) : cyc + 3 + (long)(rng() % 14)});
            reads++;
        }
        if (awvalid && awready) { wq.push_back(Burst{awaddr, awlen, 0, 0}); writes++; }
        if (stall > 0) stall--;
        cyc++;
    }
    long reads = 0, writes = 0;
private:
    struct Burst { uint64_t addr; int len, beat; long at; };
    Memory& m;
    std::mt19937_64 rng;
    std::deque<Burst> rq, wq, bq;
    long cyc = 0;
    int stall = 0;
    int mlat;
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
