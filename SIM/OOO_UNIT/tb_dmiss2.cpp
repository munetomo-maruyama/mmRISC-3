//---------------------------------------------------------------------------
// tb_dmiss2.cpp : OOO_DMISS2, the D$ written back (step 1.7b W1, Plan/OOC.md
// 29.61), with the D$'s arrays (OOO_DCH2, the victim's copy on), against a
// reference memory: the program's view, every store the D$ took applied.
//
// The bench is the LSU (DMISS_DC.sv): each cycle, at random, loads on the two
// ports, a store, a miss of a load (an id) or of a store, a device access, now
// and then FENCE.I (as OOO_SYS asks it: no store from a while before until it is
// done). It keeps the tags as OOO_DMISS2 writes them (tw_*), so it knows a hit:
// a store is given only into a way that holds its line in this cycle, and it
// counts only if st_ok; a hit's load is checked a cycle later against the
// reference as it was when read. The lines share 4 sets (10 a set: evictions,
// dirty victims, and one of tag 0 in each: the reset's tags are {invalid, 0})
// and 16 lie anywhere.
//
// Since step 1.7c C2 (Plan/OOC.md 29.68): 256 sets, a line's set {vx, its physical
// 11:6}. Each access comes with a vx: its line's own (a vx of its own, drawn once) 9
// times in 10, else another, as a page mapped at two virtual addresses would. So a
// line is asked for in a set while it sits in another (a synonym, clean or dirty).
// The bench checks that a line is never in two places, and that no fill is read
// while the line is anywhere in the D$ (a dirty synonym written out first).
//
// The memory on AXI4 (random readiness, the first beat 0 to 20 cycles after the
// address, now and then 40, gaps between beats; B 0 to 10 cycles, now and then
// 30) checks what the D$ must keep:
//   - a line read for a fill holds the program's words (nothing of it is left
//     only in the D$) and no write of it is out;
//   - a line written out is 8 beats from the line's base, every byte, the last
//     one marked, and holds the program's words (no store lost, no word of the
//     next line in it);
//   - after FENCE.I, the whole memory is the program's.
// And each line answered is in the set it was asked for in (its vx).
// The peripheral bus is a device memory of its own (reads checked).
//---------------------------------------------------------------------------
#include "VDMISS_DC.h"
#include "VDMISS_DC___024root.h"
#include <cstdint>
#include <cstdio>
#include <map>
#include <random>
#include <set>
#include <vector>

static std::mt19937_64 rng(61);
static VDMISS_DC d;
static const int SETS = 256, WAYS = 4;

static uint64_t hashw(uint64_t a)          // a word's first value
{
    uint64_t x = (a + 1) * 0x9e3779b97f4a7c15ull; x ^= x >> 29; x *= 0xbf58476d1ce4e5b9ull; x ^= x >> 32;
    return x;
}
struct Line { uint64_t w[8]; };
static std::map<uint64_t, Line> ref, mem;   // by line ([39:6])
static Line& at(std::map<uint64_t, Line>& m, uint64_t l)
{
    auto it = m.find(l);
    if (it != m.end()) return it->second;
    Line x; for (int i = 0; i < 8; i++) x.w[i] = hashw((l << 3) | i);
    return m[l] = x;
}
static std::map<uint64_t, uint64_t> dev;    // the device's words

static uint64_t rd_word(int p, int w)
{
    int k = (p * 4 + w) * 2;
    return (uint64_t)d.rd_data[k] | ((uint64_t)d.rd_data[k + 1] << 32);
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    d.clk = 0; d.rst_n = 1;
    d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    std::vector<uint64_t> pool;
    int sets4[4] = {0, 9, 33, 63};
    for (int s = 0; s < 4; s++)
        for (int t = 0; t < 10; t++) pool.push_back(((rng() & ((1ull << 28) - 1)) << 6) | (uint64_t)sets4[s]);
    for (int k = 0; k < 16; k++) pool.push_back(rng() & ((1ull << 34) - 1));
    std::vector<uint64_t> hot(pool.begin(), pool.begin() + 40);
    std::map<uint64_t, int> home;                   // a line's own vx
    // lines of tag 0 (the first 4 KB): the reset's tags are {invalid, 0}, so such a line must not be taken as held
    // (asked half the time in the first 3,000 cycles, while ways are still as the reset left them)
    std::vector<uint64_t> t0;
    for (int s = 0; s < 4; s++) { pool.push_back((uint64_t)sets4[s]); hot.push_back((uint64_t)sets4[s]); t0.push_back((uint64_t)sets4[s]); }
    for (auto l : pool) home[l] = (int)(rng() % 4);
    auto pick = [&](long c) { return (c < 3000 && rng() % 2) ? t0[rng() % 4] : rng() % 4 ? hot[rng() % hot.size()] : pool[rng() % pool.size()]; };
    auto pvx = [&](uint64_t l) { return rng() % 10 ? home[l] : (int)(rng() % 4); };
    auto sof = [&](uint64_t l, int x) { return (x << 6) | (int)(l & 63); };     // the set

    // ---- the tags as written
    struct Tag { bool v = false; uint64_t line = 0; };
    Tag tg[WAYS][SETS];
    std::set<uint64_t> dirty;                       // the lines a store wrote since their fill or write out
    auto find = [&](uint64_t l, int x) { int s = sof(l, x); for (int w = 0; w < WAYS; w++) if (tg[w][s].v && tg[w][s].line == l) return w; return -1; };
    auto places = [&](uint64_t l) { int n = 0; for (int x = 0; x < 4; x++) if (find(l, x) >= 0) n++; return n; };

    // ---- the memory bus
    bool ar_on = false; uint64_t ar_line = 0; long r_at = 0, r_ar = 0; int r_beat = 0; bool r_v = false, r_tight = false;
    bool aw_on = false; uint64_t aw_line = 0; int w_beat = 0; Line w_data; bool b_pend = false; long b_at = 0;
    // ---- the peripheral bus
    bool uaw = false, uw = false, ub = false, uar = false, ur = false; uint64_t ua = 0, uaa = 0; uint64_t uwd = 0; uint8_t uwm = 0;
    // ---- the bench's own
    struct Chk { int p, w; uint64_t exp, a; };
    std::vector<Chk> chk;
    std::map<int, std::set<uint64_t>> asked;            // by id: {line, vx}
    std::set<uint64_t> pend;                            // every {line, vx} asked for (loads' and stores'; kept: an ask
                                                        // made while its line is filled is answered again, at once)
    bool uc_wait = false, uc_rd = false; uint64_t uc_exp = 0;
    int fmode = 0; long f_at = 4000, f_quiet = 0;      // FENCE.I: 1 quiet, 2 asked, 3 taken
    int last_st_w = -1, last_st_s = -1;                 // the store of the cycle before (the race with S_INV)

    long bad = 0, cyc = 0;
    long n_ld = 0, n_st = 0, n_stmiss = 0, n_fill = 0, n_vict = 0, n_clean = 0, n_fl = 0, n_ucr = 0, n_ucw = 0, n_gate = 0, n_race = 0, n_done = 0, n_wrar = 0, n_t0 = 0;
    long n_syn = 0, n_syd = 0;
    auto err = [&](const char* m, uint64_t x = 0) { if (bad++ < 12) printf("cycle %ld: %s (%llx)\n", cyc, m, (unsigned long long)x); };
    int pst = 40, pld = 60, lat = 20;
    const long N = 600000;
    for (cyc = 0; cyc < N + 6000; cyc++) {
        bool quiet = cyc >= N;
        if (cyc % 20000 == 0) { pst = 5 + rng() % 70; pld = 10 + rng() % 80; lat = (rng() % 3 == 0) ? 1 : 20; }
        // ---- FENCE.I: quiet (no store) a few cycles, ask until taken, wait for done
        if (fmode == 0 && (cyc >= f_at || cyc == N + 100)) { fmode = 1; f_quiet = cyc + rng() % 4; }
        if (fmode == 1 && cyc >= f_quiet) fmode = 2;
        bool stores_off = fmode != 0 || quiet;

        // ---- the inputs
        d.st_en = 0; d.miss_valid = 0; d.st_miss_valid = 0; d.uc_req = 0;
        uint32_t ra = 0;
        chk.clear();
        uint64_t st_l = 0; int st_w = -1, st_word = 0, st_s = 0; uint64_t st_dat = 0; uint8_t st_m = 0;
        auto t0c = [&](uint64_t l, int x) { int s = sof(l, x); if (l < 64 && !(tg[0][s].v && tg[1][s].v && tg[2][s].v && tg[3][s].v)) n_t0++; };
        if (!stores_off && (long)(rng() % 100) < pst) {
            uint64_t l = pick(cyc);
            int x = pvx(l), w = find(l, x);
            if (w >= 0) {
                st_l = l; st_w = w; st_s = sof(l, x); st_word = rng() % 8; st_dat = rng(); st_m = rng() % 3 ? (uint8_t)(rng() & 0xff) : 0xff;
                if (!st_m) st_m = 1;
                d.st_en = 1; d.st_way = w; d.st_addr = (uint32_t)(st_s << 3) | st_word; d.st_data = st_dat; d.st_strb = st_m;
            } else { d.st_miss_valid = 1; d.st_miss_line = l; d.st_miss_vx = x; n_stmiss++; t0c(l, x); pend.insert((l << 2) | x); }
        }
        if (!quiet && (long)(rng() % 100) < pld) {
            for (int p = 0; p < 2; p++) {
                uint64_t l = pick(cyc);
                int x = pvx(l), wd = rng() % 8, w = find(l, x);
                if (w >= 0) {
                    ra |= (uint32_t)((sof(l, x) << 3) | wd) << (11 * p);
                    chk.push_back({p, w, at(ref, l).w[wd], (l << 6) | (wd << 3)});
                } else if (p == 0) {
                    int id = rng() % 32;
                    d.miss_valid = 1; d.miss_line = l; d.miss_vx = x; d.miss_id = id; asked[id].insert((l << 2) | x); t0c(l, x); pend.insert((l << 2) | x);
                }
            }
        }
        d.rd_addr = ra;
        if (!quiet && !uc_wait && rng() % 200 == 0) {
            uint64_t a = (0x100000ull + (rng() % 16) * 8);
            bool we = rng() & 1;
            d.uc_req = 1; d.uc_we = we; d.uc_addr = a; d.uc_wdata = rng(); d.uc_wmask = (uint8_t)(rng() | 1);
            uc_wait = true; uc_rd = !we;
            if (we) { uint64_t o = dev.count(a >> 3) ? dev[a >> 3] : 0, x = d.uc_wdata; for (int b = 0; b < 8; b++) if (d.uc_wmask >> b & 1) o = (o & ~(0xffull << 8 * b)) | (x & (0xffull << 8 * b)); dev[a >> 3] = o; n_ucw++; }
            else { uc_exp = dev.count(a >> 3) ? dev[a >> 3] : 0; n_ucr++; }
        }
        d.fl_req = fmode == 2;
        // the memory's answers
        bool hold = rng() % 500 == 0;
        d.m_axi4_arready = !ar_on && rng() % 3 != 0;
        d.m_axi4_rvalid = r_v; d.m_axi4_rresp = 0; d.m_axi4_rlast = r_beat == 7;
        d.m_axi4_rdata = r_v ? at(mem, ar_line).w[r_beat] : rng();
        d.m_axi4_awready = !aw_on && !b_pend && rng() % 3 != 0;
        d.m_axi4_wready = aw_on && rng() % 4 != 0;
        d.m_axi4_bvalid = b_pend && cyc >= b_at; d.m_axi4_bresp = 0;
        d.m_axil_awready = rng() & 1; d.m_axil_wready = uaw && (rng() & 1); d.m_axil_bvalid = ub && (rng() & 1); d.m_axil_bresp = 0;
        d.m_axil_arready = rng() & 1; d.m_axil_rvalid = uar && (rng() & 1); d.m_axil_rresp = 0;
        d.m_axil_rdata = dev.count(uaa >> 3) ? dev[uaa >> 3] : 0;
        d.eval();

        // ---- what happens at this edge
        bool st_ok = d.st_ok;
        if (st_ok) {
            Line& L = at(ref, st_l);
            uint64_t o = L.w[st_word];
            for (int b = 0; b < 8; b++) if (st_m >> b & 1) o = (o & ~(0xffull << 8 * b)) | (st_dat & (0xffull << 8 * b));
            L.w[st_word] = o; n_st++; dirty.insert(st_l);
        }
        if (d.tw_en && !((d.tw_tag >> 28) & 1) && last_st_w == (int)d.tw_way && last_st_s == (int)d.tw_set) n_race++;
        last_st_w = st_ok ? st_w : -1; last_st_s = st_ok ? st_s : -1;
        // the AXI4 handshakes
        bool arh = d.m_axi4_arvalid && d.m_axi4_arready, rh = d.m_axi4_rvalid && d.m_axi4_rready;
        bool awh = d.m_axi4_awvalid && d.m_axi4_awready, wh = d.m_axi4_wvalid && d.m_axi4_wready, bh = d.m_axi4_bvalid && d.m_axi4_bready;
        if (rh && r_beat == 0 && r_tight && cyc == r_ar + 1) n_gate++;     // a dirty victim's fill at the fastest
        if (arh) {
            uint64_t l = d.m_axi4_araddr >> 6;
            if (d.m_axi4_araddr & 63 || d.m_axi4_arlen != 7 || d.m_axi4_arsize != 3 || d.m_axi4_arburst != 1) err("AR: not a line's burst", d.m_axi4_araddr);
            if ((aw_on || b_pend) && aw_line == l) err("a fill read while the line's write out is not answered", l);
            if (places(l)) err("a fill of a line the D$ holds (in some set)", l);
            Line &R = at(ref, l), &M = at(mem, l);
            for (int i = 0; i < 8; i++) if (R.w[i] != M.w[i]) { err("a fill reads a line memory does not have", l); break; }
            if (aw_on || b_pend) n_wrar++;
            ar_on = true; ar_line = l; r_beat = 0; r_at = cyc + (lat == 1 ? rng() % 2 : (rng() % 10 == 0 ? 40 : rng() % 21)); n_fill++;
            r_tight = (aw_on || d.m_axi4_awvalid) && w_beat == 0; r_ar = cyc;
        }
        if (rh) {
            if (r_beat == 7) { ar_on = false; }
            r_beat++;
        }
        if (d.m_axi4_awvalid && (aw_on || b_pend)) err("a second write out before the first's answer");
        if (awh) {
            uint64_t l = d.m_axi4_awaddr >> 6;
            if (!dirty.count(l)) err("a line no store wrote written out", l);
            dirty.erase(l);
            if (d.m_axi4_awaddr & 63 || d.m_axi4_awlen != 7 || d.m_axi4_awsize != 3 || d.m_axi4_awburst != 1) err("AW: not a line's burst", d.m_axi4_awaddr);
            aw_on = true; aw_line = l; w_beat = 0;
        }
        if (wh) {
            if (d.m_axi4_wstrb != 0xff) err("W: not every byte");
            if ((w_beat == 7) != (bool)d.m_axi4_wlast) err("W: the last beat not marked as such");
            w_data.w[w_beat] = d.m_axi4_wdata;
            if (++w_beat == 8) {
                Line& R = at(ref, aw_line);
                for (int i = 0; i < 8; i++) if (R.w[i] != w_data.w[i]) { err("a line written out is not the program's", aw_line); break; }
                at(mem, aw_line) = w_data;
                if (places(aw_line)) n_clean++; else n_vict++;
                aw_on = false; b_pend = true; b_at = cyc + 1 + (rng() % 10 == 0 ? 30 : rng() % 11);
            }
        }
        if (bh) b_pend = false;
        if (d.m_axi4_bvalid && !d.m_axi4_bready) err("B not taken");
        // the AXI4-Lite handshakes
        if (d.m_axil_awvalid && d.m_axil_awready && !uaw) { uaw = true; ua = d.m_axil_awaddr; }
        if (d.m_axil_wvalid && d.m_axil_wready) { uw = true; uwd = d.m_axil_wdata; uwm = d.m_axil_wstrb; uaw = false; ub = true; }
        if (d.m_axil_bvalid && d.m_axil_bready) ub = false;
        if (d.m_axil_arvalid && d.m_axil_arready && !uar) { uar = true; uaa = d.m_axil_araddr; }
        if (d.m_axil_rvalid && d.m_axil_rready) uar = false;
        (void)uw; (void)uwd; (void)uwm; (void)ua; (void)ur;
        if (d.uc_done) {
            if (!uc_wait) err("a device answer not asked for");
            if (uc_rd && d.uc_rdata != uc_exp) err("a device read's value", d.uc_rdata);
            uc_wait = false;
        }
        // FENCE.I
        bool took = d.fl_req && d.fl_take, fdone = d.fl_done;
        // fills
        // a line's end: the line in hand (OOO_DMISS2's f_line) is in the D$ now, and a load's answer goes to an id that asked
        if (d.fill_done) {
            uint64_t fl = d.rootp->DMISS_DC__DOT__u_dmiss__DOT__f_line;
            int fx = d.rootp->DMISS_DC__DOT__u_dmiss__DOT__f_vx;
            if (find(fl, fx) < 0) err("a line answered that is not in the D$ (in its set)", fl);
            if (!pend.count((fl << 2) | fx)) err("a line filled in a set no one asked for it in", fl);
            if (d.done_v) { n_done++; if (!asked[d.done_id].count((fl << 2) | fx)) err("a load's answer to an id that did not ask for the line", d.done_id); }
        }
        int tww = d.tw_way, tws = d.tw_set; uint32_t twt = d.tw_tag; bool twe = d.tw_en;

        // ---- the edge
        d.clk = 1; d.eval();
        for (auto& c : chk) {
            uint64_t v = rd_word(c.p, c.w);
            if (v != c.exp) { err("a load's value", c.a); if (bad < 12) printf("    got %016llx, the program's %016llx\n", (unsigned long long)v, (unsigned long long)c.exp); }
            n_ld++;
        }
        d.clk = 0; d.eval();
        if (twe) {
            Tag& T = tg[tww][tws];
            bool v = (twt >> 28) & 1;
            uint64_t l = ((uint64_t)(twt & ((1u << 28) - 1)) << 6) | (uint64_t)(tws & 63);
            int fx = d.rootp->DMISS_DC__DOT__u_dmiss__DOT__f_vx;
            if (!v && T.v && (tws >> 6) != fx && T.line == d.rootp->DMISS_DC__DOT__u_dmiss__DOT__f_line) { n_syn++; if (dirty.count(T.line)) n_syd++; }
            T.v = v; T.line = l;
            if (v && places(l) != 1) err("a line in two sets", l);
            if (v) { int n = 0; for (int w = 0; w < WAYS; w++) if (tg[w][tws].v && tg[w][tws].line == l) n++; if (n != 1) err("a line in two ways", l); }
        }
        r_v = (r_v && !rh) || (ar_on && !(rh && r_beat == 8) && cyc + 1 >= r_at && (rng() % 4 != 0) && !hold);
        if (rh) r_at = cyc + 1;
        if (fmode == 2 && took) fmode = 3;
        if (fmode != 3 && fdone) err("FENCE.I done, not asked");
        else if (fmode == 3 && fdone) {
            n_fl++;
            // nothing of the program's is left only in the D$
            if (!dirty.empty()) err("after FENCE.I a line a store wrote is not written out", *dirty.begin());
            for (auto& kv : ref) { Line& M = at(mem, kv.first); for (int i = 0; i < 8; i++) if (M.w[i] != kv.second.w[i]) { err("after FENCE.I memory is not the program's", kv.first); break; } }
            fmode = 0; f_at = cyc + 2000 + rng() % 8000;
        }

    }
    if (fmode != 0) err("the last FENCE.I not done");
    if (uc_wait) err("a device access not answered");
    printf("tb_dmiss2: %ld loads checked, %ld stores (%ld missed), %ld fills (%ld behind a write out), %ld dirty victims written out, "
           "%ld lines cleaned by %ld FENCE.I, %ld dirty victims' fills with the first beat the cycle after AR, %ld stores the cycle before their line's tag went, "
           "%ld load answers, %ld asks of a tag-0 line with a way of its set as reset left it, %ld synonyms taken out (%ld dirty), "
           "%ld/%ld device reads/writes, %ld mismatches: ",
           n_ld, n_st, n_stmiss, n_fill, n_wrar, n_vict, n_clean, n_fl, n_gate, n_race, n_done, n_t0, n_syn, n_syd, n_ucr, n_ucw, bad);
    bool ok = bad == 0 && n_vict > 1000 && n_clean > 100 && n_fl > 20 && n_gate > 100 && n_race > 50 && n_done > 1000 && n_ucr > 100 && n_wrar > 100 && n_t0 > 100 &&
              n_syn > 500 && n_syd > 200;
    printf("%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
