//---------------------------------------------------------------------------
// tb_lsu3.cpp : OOO_LSU3 (with OOO_DCH2, OOO_DTLB2) against the program's order
//
// A random program of loads and stores over a few pages and lines, so that sets
// overflow, stores and loads meet, and pages alias both ways (2 virtual pages on
// one physical; the same offset in another page). A load's value is known when it
// is dispatched: memory in program order. Around the block:
//   the scheduler  a load issues a cycle after every older store at least; else any
//                  order. Port 0 takes any µop, port 1 a load; a store has its data on e_sd
//   the commit     in order; a µop with an exception flushes everything
//   recoveries     branches at random, kills, flushes
//   the miss       a line evicted (tag invalid), its words, its tag, fill_done;
//                  memory is what stores have left in the D$, as if written through
//   the walk       the DTLB refilled after some cycles, flushed now and then
// Checks: the value of every load that completes, its exception, cmp_ld_rp when it
// ran more than once; a store's exception; that a store is written in commit order,
// to the way that has its line (and a later load's value says the bytes went there);
// that the array is written by nothing else (a look inside); that the pointers agree;
// that nothing waits for ever.
//---------------------------------------------------------------------------
#include "VOOO_LSU3.h"
#include "VOOO_LSU3___024root.h"
#include <cstdint>
#include <cstdio>
#include <deque>
#include <map>
#include <random>
#include <vector>

struct Op {
    bool ld, issued = false, addr_done = false, ld_done = false, dead = false;
    uint64_t va = 0, pa = 0, data = 0, exp = 0;
    int size = 0, dst = 0, rob = 0, lq = 0, sq = 0, st = 0, disp_c = 0;
    bool uns = false, exc = false, shade = false, badaddr = false, noov = false;   // shade: behind a µop with an exception: it never commits, its value is anything
    uint32_t bm = 0;
    int runs = 0;
    long issue_c = -1;
};
struct Ck { int bit, lt, st; long seq; };

static const int NPG = 8;
struct Pg { uint64_t vp, pp; bool r, w; };

struct Sim {
    VOOO_LSU3 d;
    std::mt19937_64 rng;
    bool tr;
    std::vector<Pg> pg;
    std::map<uint64_t, uint8_t> drained, spec;
    std::deque<Op*> pend;                 // in program order, not committed
    std::deque<Op*> cmt_st;               // committed stores not yet in the D$
    std::vector<Op*> byrob, bydst, stdst;
    int try_left = 0;
    std::vector<Ck> cks;
    int bit_free_at[12] = {0};
    bool bit_used[12] = {false};
    uint32_t cur_bm = 0;
    int ltail = 0, stail = 0, seq = 0, lhead = 0, scmt = 0;
    long cyc = 0, last_commit = 0, bad = 0;
    // the miss handler
    std::deque<uint64_t> mq; std::map<uint64_t, int> m_id;     // who asked first
    int m_state = 0, m_i = 0, m_way = 0, m_delay = 0; uint64_t m_line = 0;
    uint64_t tag_ref[64][4]; bool v_ref[64][4]; int last_way[64] = {0};
    // the walk
    std::deque<uint64_t> wq; int w_delay = 0; std::map<uint64_t, int> w_id;
    // coverage
    long n_ld = 0, n_st = 0, n_fwd = 0, n_part = 0, n_alias = 0, n_rp = 0, n_miss = 0, n_stm = 0, n_walk = 0, n_two = 0, n_p1 = 0, n_p1first = 0, n_noov = 0, n_recq = 0,
         n_exc = 0, n_rest = 0, n_fl = 0, n_evict = 0, n_cl = 0, n_written = 0, n_try = 0, n_full = 0, n_tflush = 0, n_remap = 0;
    uint64_t base_next[2] = {0, 0}, sd_next = 0;
    Op zombie; bool have_z = false;
    bool stop = false;

    Sim(uint64_t seed, bool tr_) : rng(seed), tr(tr_), byrob(64, nullptr), bydst(128, nullptr), stdst(128, nullptr) {
        for (auto& a : tag_ref) for (auto& b : a) b = 0;
        for (auto& a : v_ref) for (auto& b : a) b = false;
        // physical pages: few, so that lines meet in sets; 2 virtual ones on one
        // the last differs in the tag's top bit. Virtual: 2 sets of the DTLB, a page 0 (empty
        // entries look like it), one that differs in the top bit
        static const uint64_t pp[NPG] = {0x80000, 0x80001, 0x80002, 0x80003, 0x80000, 0x80004, 0x80005, 0x8080000};
        static const uint64_t vv[NPG] = {0x12340, 0x12360, 0x12381, 0x123a1, 0x12342, 0x12362, 0x12340 | (1ull << 26), 0};
        for (int i = 0; i < NPG; i++) {
            Pg p; p.vp = tr ? vv[i] : pp[i]; p.pp = pp[i];
            p.r = !tr || i != 5; p.w = !tr || (i != 5 && i != 3);
            pg.push_back(p);
        }
        d.clk = 0; d.rst_n = 1; zero(); d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    }
    void zero() {
        d.done_v = 0; d.tr_on = tr; d.lq_alloc = d.sq_alloc = 0; d.rr_valid = 0; d.lq_commit = d.sq_commit = 0;
        d.restore = 0; d.kill = 0; d.flush_all = 0; d.fill_done = 0; d.tw_en = 0; d.rf_en = 0; d.tlb_done = 0; d.tlb_we = 0; d.tlb_flush = 0;
    }
    uint8_t mem0(uint64_t a) { return (uint8_t)((a * 0x9E3779B97F4A7C15ull) >> 56); }
    uint8_t rd(std::map<uint64_t, uint8_t>& m, uint64_t a) { auto it = m.find(a); return it != m.end() ? it->second : mem0(a); }

    void respec() {       // spec memory: what stays
        spec = drained;
        for (auto* o : cmt_st) apply(o, spec);
        for (auto* o : pend) if (!o->ld && !o->exc) apply(o, spec);
    }
    void apply(Op* o, std::map<uint64_t, uint8_t>& m) {
        for (int b = 0; b < (1 << o->size); b++) m[o->pa + b] = (uint8_t)(o->data >> (8 * b));
    }
    uint64_t read_exp(Op* o) {
        uint64_t v = 0;
        for (int b = 0; b < (1 << o->size); b++) v |= (uint64_t)rd(spec, o->pa + b) << (8 * b);
        if (!o->uns && o->size < 3) { int sh = 64 - (8 << o->size); v = (uint64_t)((int64_t)(v << sh) >> sh); }
        return v;
    }

    Op* gen() {
        Op* o = new Op;
        o->ld = rng() % 5 < 3;
        // a page that faults, rarely
        int pi;
        // (half the time few pages, so that most find their lines)
        // (and now and then 4 pages of one set of the DTLB's 2 ways: all lose their page
        // to the others', unless who was answered tries first)
        static const int thrash[4] = {0, 1, 6, 7};
        do pi = (tr && (cyc >> 14 & 3) == 3) ? thrash[rng() % 4] : (int)(rng() % ((cyc >> 13 & 1) ? 3 : NPG));
        while ((o->ld ? !pg[pi].r : !pg[pi].w) && rng() % 32 != 0);
        const Pg& p = pg[pi];
        // lines: 3 sets, 2 lines each in a page, so sets of 4 ways overflow; words near each other
        static const int lines[6] = {0, 1, 16, 17, 32, 33};
        int ln = lines[rng() % 6];
        o->size = (int)(rng() % 4);
        int w = (int)(rng() % 3);
        int off = (int)(rng() % 8) & ~((1 << o->size) - 1);
        if (rng() % 64 == 0) off = (int)(rng() % 8);
        uint64_t po = (uint64_t)ln * 64 + w * 8 + off;
        o->va = (p.vp << 12) + po;
        o->pa = (p.pp << 12) + po;
        if (tr && (o->va >> 38 & 1)) o->va |= ~0ull << 39;
        o->uns = rng() & 1;
        if (o->ld && o->size == 3) o->uns = false;
        o->data = rng();
        bool mis = po & ((1u << o->size) - 1);
        bool noncanon = false;
        if (tr && rng() % 256 == 0) { o->va ^= 1ull << (40 + rng() % 24); noncanon = true; }
        o->exc = mis || noncanon || (o->ld ? !p.r : !p.w);
        o->badaddr = mis || noncanon;
        o->disp_c = (int)cyc;
        o->dst = seq & 127; o->rob = seq & 63;
        seq++;
        return o;
    }

    bool quiet() { return (cyc >> 12 & 7) == 7; }
    // one load at a time, on port 1, with nothing else going on: what it needs comes from itself
    bool solo() { return (cyc >> 12 & 7) == 5; }
    bool step(long ncyc) {
        if (d.lq_tail != ltail || d.sq_tail != stail) err("the tails disagree");
        zero();
        // ---- recoveries
        bool rest = false, flush = false;
        if (quiet()) {
            // no more µops, no recoveries, no walks: what waits has only the events it should have
            if ((cyc & 4095) == 4095 && !pend.empty()) {
                err("what waits does not get to its end");
                Op* o = pend.front();
                printf("  head: ld %d pa %llx size %d lq %d sq %d runs %d, %d %d %d\n", o->ld, (unsigned long long)o->pa, o->size, o->lq, o->sq, o->runs, o->addr_done, 0, o->ld_done);
            }
        }
        else if (solo()) { }
        else if (!cks.empty() && try_left > 0 && (cyc & 0x7fff) >= 0x7000 - 256) { rest = true; n_recq++; }
        else if (!cks.empty() && rng() % 128 == 0) rest = true;
        else if (rng() % 2048 == 0) flush = true;

        // ---- commit
        int lc = 0, sc = 0, nc = (rng() % 4 == 0) ? 0 : (int)(rng() % 5);
        bool exc_head = false;
        if (!rest) {
            while (nc > 0 && !pend.empty()) {
                Op* o = pend.front();
                bool ok = o->ld ? o->ld_done : o->addr_done;
                if (!ok || o->bm) break;     // (behind a branch not resolved it cannot commit)
                if (o->exc) { exc_head = true; break; }
                pend.pop_front();
                last_commit = cyc;
                if (o->ld) { lc++; byrob[o->rob] = nullptr; bydst[o->dst] = nullptr; delete o; }
                else {
                    if (o->sq != ((scmt + sc) & 15)) { printf("commit: store sq %d, scmt %d + %d; tail %d; bm %x rest %d\n", o->sq, scmt, sc, stail, o->bm, rest); err("a store commits out of its place"); }
                    sc++; byrob[o->rob] = nullptr; stdst[o->dst] = nullptr; cmt_st.push_back(o);
                }
                nc--;
            }
        }
        if (exc_head) { flush = true; n_exc++; }
        d.lq_commit = lc; d.sq_commit = sc;
        lhead = (lhead + lc) & 31; scmt = (scmt + sc) & 31;

        if (rest) {
            Ck c = cks[rng() % cks.size()];
            n_rest++;
            d.restore = 1; d.kill = 1u << c.bit;
            d.restore_lq_tail = c.lt; d.restore_sq_tail = c.st;
            for (auto it = pend.begin(); it != pend.end();) {
                if ((*it)->bm >> c.bit & 1) {
                    if (!(*it)->issued && !have_z && rng() % 2) { zombie = **it; have_z = true; }
                    kill_op(*it); it = pend.erase(it);
                } else ++it;
            }
            ltail = c.lt; stail = c.st;
            uint32_t gone = 0;
            for (auto& k : cks) if (k.seq >= c.seq) gone |= 1u << k.bit;
            std::vector<Ck> keep;
            for (auto& k : cks) if (k.seq < c.seq) keep.push_back(k);
            cks = keep;
            for (int b = 0; b < 12; b++) if (gone >> b & 1) { bit_used[b] = false; bit_free_at[b] = (int)cyc + 8; }
            cur_bm &= ~gone;
            respec();
        }
        if (flush) {
            n_fl++;
            d.flush_all = 1;
            for (auto* o : pend) kill_op(o);
            pend.clear();
            for (auto& k : cks) { bit_used[k.bit] = false; bit_free_at[k.bit] = (int)cyc + 8; }
            cks.clear();
            cur_bm = 0;
            ltail = lhead; stail = scmt;
            respec();
        }

        // ---- branches resolved
        if (!cks.empty() && !rest && !flush && rng() % 8 == 0) {
            Ck c = cks.front();
            cks.erase(cks.begin());
            bit_used[c.bit] = false; bit_free_at[c.bit] = (int)cyc + 8;
            cur_bm &= ~(1u << c.bit);
            for (auto* o : pend) o->bm &= ~(1u << c.bit);
        }

        // ---- dispatch (not in a cycle of recovery)
        int la = 0, sa = 0;
        if (!rest && !flush && ncyc > 0) {
            int nd = (int)(rng() % 5);
            if (rng() % 256 == 0) stop = !stop;
            if (quiet()) stop = true;
            if (solo()) {
                nd = pend.empty() && cmt_st.empty() && mq.empty() && m_state == 0 && wq.empty() && !d.tlb_busy ? 1 : 0;
                stop = false;
            }
            int lf = d.lq_free, sf = d.sq_free;
            for (int i = 0; i < nd && !stop; i++) {
                if (pend.size() >= 40) break;
                Op* o = gen();
                if (solo() && !o->ld) { delete o; seq--; break; }
                if (byrob[o->rob] || bydst[o->dst]) { delete o; seq--; break; }
                if (o->ld ? lf - la <= 0 : sf - sa <= 0) { n_full++; delete o; seq--; break; }
                o->bm = cur_bm;
                // a branch in front of it, sometimes
                if (rng() % 6 == 0 && !solo()) {
                    int bit = -1;
                    for (int b = 0; b < 12; b++) if (!bit_used[b] && bit_free_at[b] <= cyc) { bit = b; break; }
                    if (bit >= 0) {
                        bit_used[bit] = true;
                        Ck c; c.bit = bit; c.lt = (ltail + la) & 31; c.st = (stail + sa) & 31; c.seq = o->rob + seq * 1000L;
                        cks.push_back(c);
                        cur_bm |= 1u << bit;
                        o->bm = cur_bm;
                    }
                }
                o->st = (stail + sa) & 31;
                if (o->ld) { o->lq = (ltail + la) & 15; la++; } else { o->sq = (stail + sa) & 15; sa++; }
                for (auto* x : pend) if (x->exc) o->shade = true;
                pend.push_back(o);
                byrob[o->rob] = o;
                if (o->ld) bydst[o->dst] = o; else stdst[o->dst] = o;
                if (o->ld) {
                    o->exp = read_exp(o);
                    bool same = false, over = false;
                    for (auto* s : pend) if (!s->ld && s != o) {
                        uint64_t a = s->pa, b = o->pa; int ns = 1 << s->size, nl = 1 << o->size;
                        if ((a >> 3) == (b >> 3)) same = true;
                        if ((a & 0xff8) == (b & 0xff8) && ((a & 7) < (b & 7) + nl) && ((b & 7) < (a & 7) + ns)) over = true;
                    }
                    o->noov = same && !over && !o->exc;
                    if (!o->exc) for (auto* s : pend) if (!s->ld && !s->exc && s != o) {
                        uint64_t a = s->pa, b = o->pa; int ns = 1 << s->size, nl = 1 << o->size;
                        if (a < b + nl && b < a + ns) { n_fwd++; if (!(a <= b && b + nl <= a + ns)) n_part++; }
                        else if ((a & 0xff8) == (b & 0xff8) && (a >> 12) != (b >> 12) && ((a & 7) < (b & 7) + nl) && ((b & 7) < (a & 7) + ns)) n_alias++;
                    }
                } else if (!o->exc) apply(o, spec);
                if (o->ld) n_ld++; else n_st++;
            }
        }
        d.lq_alloc = la; d.sq_alloc = sa;
        ltail = (ltail + la) & 31; stail = (stail + sa) & 31;

        // ---- issue: RR
        Op* is[2] = {nullptr, nullptr};
        if (have_z) { is[0] = &zombie; have_z = false; }    // issued in the cycle it dies: it must not come out
        else if (!flush && rng() % 8 != 0) {
            std::vector<Op*> can;
            bool st_open = false;
            for (auto* o : pend) {
                if (!o->issued && cyc >= o->disp_c + 3 && !(o->ld && st_open)) can.push_back(o);
                if (!o->ld && !(o->issued && o->issue_c < cyc)) st_open = true;
            }
            if (!can.empty()) is[0] = can[rng() % 3 == 0 ? rng() % can.size() : 0];
            if (rng() % 8 == 0 || (solo() && is[0] && is[0]->ld)) is[0] = nullptr;   // (what is left from before has to go)
            // port 1: another load
            std::vector<Op*> can1;
            for (auto* o : can) if (o->ld && o != is[0]) can1.push_back(o);
            if (!can1.empty() && rng() % 4 != 0) { is[1] = can1[rng() % 3 == 0 ? rng() % can1.size() : 0]; n_p1++; if (is[0]) n_two++; }
        }
        {
            unsigned v = 0, size = 0, uns = 0, lqs = 0, sts = 0, dsts = 0, robs = 0; uint64_t bms = 0;
            for (int p = 0; p < 2; p++) {
                Op* o = is[p];
                base_next[p] = rng();
                if (!o) continue;
                o->issued = true; o->issue_c = cyc; o->runs = 0;
                base_next[p] = o->va;
                v |= 1u << p; size |= o->size << (2 * p); uns |= (unsigned)o->uns << p;
                lqs |= o->lq << (4 * p); sts |= o->st << (5 * p); dsts |= o->dst << (7 * p); robs |= o->rob << (6 * p);
                bms |= (uint64_t)o->bm << (12 * p);
            }
            d.rr_valid = v; d.rr_size = size; d.rr_uns = uns; d.rr_lq = lqs; d.rr_st = sts; d.rr_dst = dsts; d.rr_rob = robs; d.rr_bm = bms;
            if (is[0]) { d.rr_ld = is[0]->ld; d.rr_sq = is[0]->sq; }
            // what is above the store's size must not matter
            sd_next = rng();
            if (is[0] && !is[0]->ld) {
                uint64_t x = is[0]->data;
                if (is[0]->size < 3) x = (x & ((1ull << (8 << is[0]->size)) - 1)) | (rng() << (8 << is[0]->size));
                sd_next = x;
            }
        }

        // ---- the miss handler: from registers of its own
        step_miss();
        // ---- the walk
        if (w_delay > 0) w_delay--;
        if (!wq.empty() && w_delay == 0 && !d.tlb_busy) {
            uint64_t vp = wq.front(); wq.pop_front();
            bool found = false;
            for (auto& p : pg) if ((p.vp & 0x7ffffff) == vp) {
                d.tlb_we = 1; d.tlb_vpn = (uint32_t)vp; d.tlb_ptag = (uint32_t)p.pp; d.tlb_r = p.r; d.tlb_w = p.w; found = true; break;
            }
            if (!found) { d.tlb_we = 1; d.tlb_vpn = (uint32_t)vp; d.tlb_ptag = 0; d.tlb_r = 0; d.tlb_w = 0; }
            d.tlb_done = 1;
            d.done_v = 1; d.done_id = w_id[vp];
            w_delay = 4 + (int)(rng() % 16);
        }
        if (tr && !quiet() && rng() % 4096 == 0 && !d.tlb_busy) { d.tlb_flush = 1; n_tflush++; }
        // with nothing in flight, as an SFENCE.VMA: 2 pages change places, so what stays in the DTLB is wrong
        if (tr && quiet() && (cyc & 4095) == 2048 && pend.empty() && wq.empty() && !d.tlb_busy) {
            std::swap(pg[1].pp, pg[2].pp);
            d.tlb_flush = 1; n_tflush++; n_remap++;
        }

        d.eval();

        // ---- what the block says, this cycle
        if (d.rt_v) {
            n_try++;
            try_left = 3;
            base_next[0] = (uint64_t)(((int64_t)d.rt_base << 24) >> 24);
        }
        for (int p = 0; p < 2; p++) if ((d.ld_nv >> p) & 1) {
            int t = (d.ld_nt >> (7 * p)) & 127;
            if (stdst[t]) err("a store writes a register");
            if (bydst[t]) {
                Op* o = bydst[t];
                if (!o->ld_done) {
                    o->runs++;
                    lastv[t] = (uint64_t)d.ld_d.m_storage[2 * p] | (uint64_t)d.ld_d.m_storage[2 * p + 1] << 32;
                }
            }
        }
        for (int p = 0; p < 2; p++) if ((d.cmp_ld_valid >> p) & 1) {
            Op* o = byrob[(d.cmp_ld_rob >> (6 * p)) & 63];
            if (!o || !o->ld) { err("a load completes that is not there"); }
            else {
                if ((bool)((d.cmp_ld_exc >> p) & 1) != o->exc) err("the load's exception");
                if (!o->exc && !o->shade && lastv[o->dst] != o->exp) {
                    err("the load's value");
                    printf("  port %d load pa %llx size %d uns %d rob %d lq %d st %d runs %d: got %016llx, expected %016llx\n", p,
                           (unsigned long long)o->pa, o->size, o->uns, o->rob, o->lq, o->st, o->runs, (unsigned long long)lastv[o->dst], (unsigned long long)o->exp);
                }
                if ((bool)((d.cmp_ld_rp >> p) & 1) != (o->runs > 1)) err("replay and runs disagree");
                if (o->runs > 1) n_rp++;
                if (p == 1 && o->runs == 1 && !o->exc) n_p1first++;
                if (o->noov && o->runs == 1) n_noov++;
                if (d.miss_valid && d.miss_id == o->lq && p == 0) err("a line asked for by a load that has its result");
                o->ld_done = true;
            }
        }
        if (d.cmp_st_valid) {
            Op* o = byrob[d.cmp_st_rob];
            if (!o || o->ld) err("a store completes that is not there");
            else {
                if ((bool)d.cmp_st_exc != o->exc) err("the store's exception");
                o->addr_done = true;
            }
        }
        if (d.miss_valid) { n_miss++; ask_line((uint64_t)d.miss_line, d.miss_id); }
        if (d.st_miss_valid) { n_stm++; ask_line((uint64_t)d.st_miss_line, -1); }
        if (d.tlb_miss) {
            n_walk++;
            uint64_t vp = (uint64_t)d.tlb_miss_vpn;
            {
                bool someone = false;
                for (auto* o : pend) if (((o->va >> 12) & 0x7ffffff) == vp && !o->badaddr) someone = true;
                if (!someone) err("a walk for a bad address, or for nobody");
            }
            bool there = false;
            for (auto x : wq) if (x == vp) there = true;
            if (!there) { wq.push_back(vp); w_id[vp] = d.walk_id; }
            if (w_delay == 0) w_delay = 4 + (int)(rng() % 16);
        }
        // the array is written by a fill's word or a store that counts, nothing else: a word
        // written and tried again would be in a line being filled by then
        if (d.rootp->OOO_LSU3__DOT__dw_en && !d.rf_en && !d.dirty_set) err("the data array written by no one");
        if (d.dirty_set) {
            n_written++;
            if (cmt_st.empty()) err("a store written with none committed");
            else {
                Op* o = cmt_st.front(); cmt_st.pop_front();
                int set = (int)((o->pa >> 6) & 63);
                if (d.dirty_idx != set) err("written in the wrong set");
                if (!v_ref[set][d.dirty_way] || tag_ref[set][d.dirty_way] != (o->pa >> 12)) err("written in a way without its line");
                last_way[set] = d.dirty_way;
                apply(o, drained);
                delete o;
            }
        }
        if (pend.empty()) last_commit = cyc;
        if (solo() && cyc - last_commit > 1000) err("a load alone does not get to its end");
        if (cyc - last_commit > 5000) {
            err("nothing commits");
            Op* o = pend.front();
            printf("  head: ld %d pa %llx va %llx size %d issued %d addr %d data %d done %d exc %d lq %d sq %d runs %d; stop %d, mq %zu, wq %zu\n", o->ld, (unsigned long long)o->pa, (unsigned long long)o->va, o->size, o->issued, o->addr_done, 0, o->ld_done, o->exc, o->lq, o->sq, o->runs, stop, mq.size(), wq.size());
            return false;
        }

        if (!d.rt_v && try_left > 0) try_left--;
        d.clk = 1; d.eval(); d.clk = 0;
        for (int p = 0; p < 2; p++) { d.e_addr[2 * p] = (uint32_t)base_next[p]; d.e_addr[2 * p + 1] = (uint32_t)(base_next[p] >> 32); }
        d.e_sd = sd_next;
        d.eval();
        cyc++;
        return bad == 0;
    }
    uint64_t lastv[128] = {0};

    void kill_op(Op* o) {
        byrob[o->rob] = nullptr;
        if (o->ld) bydst[o->dst] = nullptr; else stdst[o->dst] = nullptr;
        delete o;
    }
    void ask_line(uint64_t l, int id) {
        for (auto x : mq) if (x == l) return;
        if (m_state != 0 && m_line == l) return;
        mq.push_back(l);
        m_id[l] = id;
    }
    void say_done() {
        d.fill_done = 1;
        if (m_id[m_line] >= 0 && !d.done_v) { d.done_v = 1; d.done_id = m_id[m_line]; }
    }
    void step_miss() {
        if (m_delay > 0) { m_delay--; return; }
        switch (m_state) {
        case 0:
            if (!mq.empty()) {
                m_line = mq.front(); mq.pop_front();
                int set = (int)(m_line & 63);
                uint64_t tag = m_line >> 6;
                bool have = false;
                for (int w = 0; w < 4; w++) if (v_ref[set][w] && tag_ref[set][w] == tag) have = true;
                if (have) { say_done(); n_cl++; break; }
                m_way = rng() % 2 ? last_way[set] : (int)(rng() % 4);
                if (v_ref[set][m_way]) n_evict++;
                // (the tag stays, only the valid bit goes)
                d.tw_en = 1; d.tw_way = m_way; d.tw_set = set; d.tw_tag = (uint32_t)tag_ref[set][m_way];
                v_ref[set][m_way] = false;
                m_state = 1; m_i = 0; m_delay = rng() % 2 ? 0 : (int)(rng() % 4);
            }
            break;
        case 1: {
            int set = (int)(m_line & 63);
            if (rng() % 3 == 0) break;
            uint64_t v = 0;
            uint64_t a = (m_line << 6) + m_i * 8;
            // the bytes as they are now: a store already in another way of this line cannot be, there is one line
            for (int b = 0; b < 8; b++) v |= (uint64_t)rd(drained, a + b) << (8 * b);
            d.rf_en = 1; d.rf_way = m_way; d.rf_addr = set * 8 + m_i; d.rf_data = v;
            if (++m_i == 8) { m_state = 2; m_delay = (int)(rng() % 3); }
            break;
        }
        case 2: {
            int set = (int)(m_line & 63);
            uint64_t tag = m_line >> 6;
            d.tw_en = 1; d.tw_way = m_way; d.tw_set = set; d.tw_tag = (uint32_t)((1u << 28) | tag);
            tag_ref[set][m_way] = tag; v_ref[set][m_way] = true;
            m_state = 3;
            break;
        }
        case 3:
            say_done();
            m_state = 0;
            m_delay = (int)(rng() % 6);
            break;
        }
    }
    void err(const char* s) {
        if (bad < 10) printf("cycle %ld: %s\n", cyc, s);
        bad++;
    }
};

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    long bad = 0;
    for (int m = 0; m < 2; m++) {
        Sim s(77 + m, m == 1);
        for (long c = 0; c < 600000 && s.bad == 0; c++) s.step(c);
        printf("%s: loads %ld stores %ld, meeting a store %ld (partly %ld), same offset, another page %ld; tries %ld, replayed %ld; "
               "misses %ld, stores' misses %ld (present by then %ld), evicted %ld; walks %ld, flushes of the DTLB %ld; 2 issued %ld, on port 1 %ld, in one go there %ld; same word, no byte in common %ld; recoveries on a try before a quiet time %ld; "
               "written %ld; exceptions %ld, recoveries %ld, flushes %ld, queue full %ld\n",
               m ? "translated" : "physical", s.n_ld, s.n_st, s.n_fwd, s.n_part, s.n_alias, s.n_try, s.n_rp,
               s.n_miss, s.n_stm, s.n_cl, s.n_evict, s.n_walk, s.n_tflush, s.n_two, s.n_p1, s.n_p1first, s.n_noov, s.n_recq, s.n_written, s.n_exc, s.n_rest, s.n_fl, s.n_full);
        if (s.n_fwd < 1000 || s.n_part < 100 || s.n_rp < 1000 || s.n_miss < 100 || s.n_stm < 100 || s.n_evict < 100 || s.n_two < 1000 || s.n_p1first < 1000 || s.n_noov < 100 ||
            s.n_written < 1000 || s.n_exc < 50 || s.n_rest < 100 || s.n_fl < 50 || (m == 1 && (s.n_remap < 10 || s.n_walk < 100 || s.n_alias < 100 || s.n_tflush < 10))) {
            printf("the coverage is too low\n");
            bad++;
        }
        bad += s.bad;
    }
    printf(bad ? "FAILED\n" : "PASSED\n");
    return bad ? 1 : 0;
}
