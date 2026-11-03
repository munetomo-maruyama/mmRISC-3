//---------------------------------------------------------------------------
// tb_lsu2.cpp : OOO_LSU2 (with OOO_DCH, OOO_DTLB2) against the program's order
//
// A random program of loads and stores over a few pages and lines, so that sets
// overflow, stores and loads meet, and pages alias both ways (2 virtual pages on
// one physical; the same offset in another page). A load's value is known when it
// is dispatched: memory in program order. Around the block:
//   the scheduler  a load issues after every older store's address; else any order
//   a store's data on sd_*, at any time after dispatch, one a cycle
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
#include "VOOO_LSU2.h"
#include "VOOO_LSU2___024root.h"
#include <cstdint>
#include <cstdio>
#include <deque>
#include <map>
#include <random>
#include <vector>

struct Op {
    bool ld, issued = false, addr_done = false, data_done = false, ld_done = false, dead = false;
    uint64_t va = 0, pa = 0, data = 0, exp = 0;
    int size = 0, dst = 0, rob = 0, lq = 0, sq = 0, st = 0, disp_c = 0;
    bool uns = false, exc = false, shade = false;   // shade: behind a µop with an exception: it never commits, its value is anything
    uint32_t bm = 0;
    int runs = 0;
    long issue_c = -1;
};
struct Ck { int bit, lt, st; long seq; };

static const int NPG = 8;
struct Pg { uint64_t vp, pp; bool r, w; };

struct Sim {
    VOOO_LSU2 d;
    std::mt19937_64 rng;
    bool tr;
    std::vector<Pg> pg;
    std::map<uint64_t, uint8_t> drained, spec;
    std::deque<Op*> pend;                 // in program order, not committed
    std::deque<Op*> cmt_st;               // committed stores not yet in the D$
    std::vector<Op*> byrob, bydst;
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
    long n_ld = 0, n_st = 0, n_fwd = 0, n_part = 0, n_alias = 0, n_rp = 0, n_miss = 0, n_stm = 0, n_walk = 0, n_late = 0,
         n_exc = 0, n_rest = 0, n_fl = 0, n_evict = 0, n_cl = 0, n_written = 0, n_try = 0, n_full = 0, n_tflush = 0, n_remap = 0;
    uint64_t base_next = 0, va_in_e = 0;
    Op zombie; bool have_z = false;
    bool stop = false;

    Sim(uint64_t seed, bool tr_) : rng(seed), tr(tr_), byrob(64, nullptr), bydst(128, nullptr) {
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
        d.done_v = 0; d.tr_on = tr; d.lq_alloc = d.sq_alloc = 0; d.rr_valid = 0; d.sd_valid = 0; d.lq_commit = d.sq_commit = 0;
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
        o->disp_c = (int)cyc;
        o->dst = seq & 127; o->rob = seq & 63;
        seq++;
        return o;
    }

    bool quiet() { return (cyc >> 12 & 7) == 7; }
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
                printf("  head: ld %d pa %llx size %d lq %d sq %d runs %d, %d %d %d\n", o->ld, (unsigned long long)o->pa, o->size, o->lq, o->sq, o->runs, o->addr_done, o->data_done, o->ld_done);
            }
        }
        else if (!cks.empty() && rng() % 128 == 0) rest = true;
        else if (rng() % 2048 == 0) flush = true;

        // ---- commit
        int lc = 0, sc = 0, nc = (rng() % 4 == 0) ? 0 : (int)(rng() % 5);
        bool exc_head = false;
        if (!rest) {
            while (nc > 0 && !pend.empty()) {
                Op* o = pend.front();
                bool ok = o->ld ? o->ld_done : (o->addr_done && (o->data_done || o->exc));
                if (!ok || o->bm) break;     // (behind a branch not resolved it cannot commit)
                if (o->exc) { exc_head = true; break; }
                pend.pop_front();
                last_commit = cyc;
                if (o->ld) { lc++; byrob[o->rob] = nullptr; bydst[o->dst] = nullptr; delete o; }
                else {
                    if (o->sq != ((scmt + sc) & 15)) { printf("commit: store sq %d, scmt %d + %d; tail %d; bm %x rest %d\n", o->sq, scmt, sc, stail, o->bm, rest); err("a store commits out of its place"); }
                    sc++; byrob[o->rob] = nullptr; cmt_st.push_back(o);
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
            int lf = d.lq_free, sf = d.sq_free;
            for (int i = 0; i < nd && !stop; i++) {
                if (pend.size() >= 40) break;
                Op* o = gen();
                if (byrob[o->rob] || bydst[o->dst]) { delete o; seq--; break; }
                if (o->ld ? lf - la <= 0 : sf - sa <= 0) { n_full++; delete o; seq--; break; }
                o->bm = cur_bm;
                // a branch in front of it, sometimes
                if (rng() % 6 == 0) {
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
                if (o->ld) bydst[o->dst] = o;
                if (o->ld) {
                    o->exp = read_exp(o);
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

        // ---- issue: RR2
        Op* is = nullptr;
        if (have_z) { is = &zombie; have_z = false; }    // issued in the cycle it dies: it must not come out
        else if (!flush && rng() % 8 != 0) {
            std::vector<Op*> can;
            bool st_open = false;
            for (auto* o : pend) {
                if (!o->issued && cyc >= o->disp_c + 3 && !(o->ld && st_open)) can.push_back(o);
                if (!o->ld && !(o->issued && o->issue_c < cyc)) st_open = true;
            }
            if (!can.empty()) is = can[rng() % 3 == 0 ? rng() % can.size() : 0];
        }
        uint64_t imm = 0;
        if (is) {
            is->issued = true; is->issue_c = cyc; is->runs = 0;
            int64_t im = (int64_t)(rng() % 4096) - 2048;
            imm = (uint64_t)(im & 0xfff);
            base_next = is->va - (uint64_t)im;
            d.rr_valid = 1; d.rr_ld = is->ld; d.rr_lq = is->lq; d.rr_sq = is->sq; d.rr_st = is->st;
            d.rr_imm = (uint32_t)imm; d.rr_size = is->size; d.rr_uns = is->uns; d.rr_dst = is->dst; d.rr_rob = is->rob;
            d.rr_bm = is->bm;
        }

        // ---- a store's data
        {
            std::vector<Op*> can;
            for (auto* o : pend) if (!o->ld && !o->data_done && cyc >= o->disp_c + 3) can.push_back(o);
            if (!can.empty() && rng() % 3 != 0 && !rest && !flush) {
                Op* o = can[rng() % 4 == 0 ? rng() % can.size() : 0];
                d.sd_valid = 1; d.sd_sq = o->sq; d.sd_size = o->size;
                // what is above the store's size must not matter
                uint64_t v = o->data;
                if (o->size < 3) v = (v & ((1ull << (8 << o->size)) - 1)) | (rng() << (8 << o->size));
                d.sd_data = v;
                o->data_done = true;
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
            base_next = (uint64_t)(((int64_t)d.rt_base << 24) >> 24);
        }
        if (d.ld_nv && bydst[d.ld_nt]) {
            Op* o = bydst[d.ld_nt];
            if (!o->ld_done) { o->runs++; lastv[d.ld_nt] = d.ld_d; }
        }
        if (d.cmp_ld_valid) {
            Op* o = byrob[d.cmp_ld_rob];
            if (!o || !o->ld) { err("a load completes that is not there"); }
            else {
                if ((bool)d.cmp_ld_exc != o->exc) err("the load's exception");
                if (!o->exc && !o->shade && lastv[o->dst] != o->exp) {
                    err("the load's value");
                    printf("  load pa %llx size %d uns %d rob %d lq %d st %d runs %d: got %016llx, expected %016llx; sqhead-ish tail %d cmt %d\n",
                           (unsigned long long)o->pa, o->size, o->uns, o->rob, o->lq, o->st, o->runs, (unsigned long long)lastv[o->dst], (unsigned long long)o->exp, stail, scmt);
                    for (auto* x : pend) if (!x->ld) printf("    pend store sq %d pa %llx size %d data %016llx exc %d issued %d addr %d dd %d\n", x->sq, (unsigned long long)x->pa, x->size, (unsigned long long)x->data, x->exc, x->issued, x->addr_done, x->data_done);
                    for (auto* x : cmt_st) printf("    cmt store sq %d pa %llx size %d data %016llx\n", x->sq, (unsigned long long)x->pa, x->size, (unsigned long long)x->data);
                    int st = (int)((o->pa >> 6) & 63);
                    for (int w = 0; w < 4; w++) printf("    way %d v %d tag %llx\n", w, v_ref[st][w], (unsigned long long)tag_ref[st][w]);
                }
                if ((bool)d.cmp_ld_rp != (o->runs > 1)) err("replay and runs disagree");
                if (o->runs > 1) n_rp++;
                o->ld_done = true;
            }
        }
        if (d.cmp_sa_valid) {
            Op* o = byrob[d.cmp_sa_rob];
            if (!o || o->ld) err("a store's address completes that is not there");
            else {
                if ((bool)d.cmp_sa_exc != o->exc) err("the store's exception");
                o->addr_done = true;
            }
        }
        if (d.wt_valid) n_late++;
        if (d.miss_valid) { n_miss++; ask_line((uint64_t)d.miss_line, d.miss_id); }
        if (d.st_miss_valid) { n_stm++; ask_line((uint64_t)d.st_miss_line, -1); }
        if (d.tlb_miss) {
            n_walk++;
            uint64_t vp = (uint64_t)d.tlb_miss_vpn;
            bool there = false;
            for (auto x : wq) if (x == vp) there = true;
            if (!there) { wq.push_back(vp); w_id[vp] = d.miss_id; }
            if (w_delay == 0) w_delay = 4 + (int)(rng() % 16);
        }
        // the array is written by a fill's word or a store that counts, nothing else: a word
        // written and tried again would be in a line being filled by then
        if (d.rootp->OOO_LSU2__DOT__dw_en && !d.rf_en && !d.dirty_set) err("the data array written by no one");
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
        if (cyc - last_commit > 5000) {
            err("nothing commits");
            Op* o = pend.front();
            printf("  head: ld %d pa %llx va %llx size %d issued %d addr %d data %d done %d exc %d lq %d sq %d runs %d; stop %d, mq %zu, wq %zu\n", o->ld, (unsigned long long)o->pa, (unsigned long long)o->va, o->size, o->issued, o->addr_done, o->data_done, o->ld_done, o->exc, o->lq, o->sq, o->runs, stop, mq.size(), wq.size());
            return false;
        }

        // a µop that is not there: E takes any value
        if (!is && !d.rt_v) base_next = rng();
        d.clk = 1; d.eval(); d.clk = 0;
        d.e_base = base_next;
        d.eval();
        cyc++;
        return bad == 0;
    }
    uint64_t lastv[128] = {0};

    void kill_op(Op* o) {
        byrob[o->rob] = nullptr;
        if (o->ld) bydst[o->dst] = nullptr;
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
               "misses %ld, stores' misses %ld (present by then %ld), evicted %ld; walks %ld, flushes of the DTLB %ld; data late %ld; "
               "written %ld; exceptions %ld, recoveries %ld, flushes %ld, queue full %ld\n",
               m ? "translated" : "physical", s.n_ld, s.n_st, s.n_fwd, s.n_part, s.n_alias, s.n_try, s.n_rp,
               s.n_miss, s.n_stm, s.n_cl, s.n_evict, s.n_walk, s.n_tflush, s.n_late, s.n_written, s.n_exc, s.n_rest, s.n_fl, s.n_full);
        if (s.n_fwd < 1000 || s.n_part < 100 || s.n_rp < 1000 || s.n_miss < 100 || s.n_stm < 100 || s.n_evict < 100 || s.n_late < 100 ||
            s.n_written < 1000 || s.n_exc < 50 || s.n_rest < 100 || s.n_fl < 50 || (m == 1 && (s.n_remap < 10 || s.n_walk < 100 || s.n_alias < 100 || s.n_tflush < 10))) {
            printf("the coverage is too low\n");
            bad++;
        }
        bad += s.bad;
    }
    printf(bad ? "FAILED\n" : "PASSED\n");
    return bad ? 1 : 0;
}
