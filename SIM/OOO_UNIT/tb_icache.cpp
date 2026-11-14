//---------------------------------------------------------------------------
// tb_icache.cpp : OOO_ICACHE (256 sets x 8 ways since step 1.7c C1, Plan/OOC.md 29.66;
// 64 sets at step 1.7 H1, 29.56)
// against an exact account of what it must do each cycle
//
// The requests come as OOO_FETCH2's: now and then, from a pool of lines that
// share a few sets (more lines than ways: evictions) with a hot part that fits,
// sometimes the next half line. The fills come from a memory model on AXI4: the
// address taken now and then, the first beat 1 to 20 cycles later (now and then
// 40), the beats with gaps, each the memory's word when it is given, now and then
// an error answer. The memory's words change at random times (the D$'s writes), and
// FENCE.I comes now and then (ic_flush until ic_done, as OOO_SYS gives it), also
// while a line is filled.
//
// The account keeps the I$'s lines (tag, valid, the 8 words a fill gave), its way
// counter, the request in F1, the miss: so it knows, each cycle, ic_req_ready, the
// AR (address and its constants), whether an answer comes and its 32 bytes (a hit:
// the line's words; a miss: the fill's beats of the request's half), and ic_done.
// Everything is compared each cycle; at the end, nothing is left unanswered.
//---------------------------------------------------------------------------
#include "VOOO_ICACHE.h"
#include <cstdint>
#include <cstdio>
#include <deque>
#include <map>
#include <random>
#include <vector>

static std::mt19937_64 rng(29);
static VOOO_ICACHE d;
static const int SETS = 256, WAYS = 8;

// ---- the memory: 8-byte words, a hash until written
static std::map<uint64_t, uint64_t> mem;
static uint64_t word(uint64_t a)
{
    auto it = mem.find(a >> 3);
    if (it != mem.end()) return it->second;
    uint64_t x = (a >> 3) * 0x9e3779b97f4a7c15ull; x ^= x >> 29; x *= 0xbf58476d1ce4e5b9ull; x ^= x >> 32;
    return x;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    d.clk = 0; d.rst_n = 1; d.ic_req_valid = 0; d.ic_req_pc = 0; d.ic_flush = 0;
    d.m_axi4_arready = 0; d.m_axi4_rvalid = 0; d.m_axi4_rdata = 0; d.m_axi4_rresp = 0; d.m_axi4_rlast = 0;
    d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    // the lines (64 bytes): 4 sets, 12 tags each, the hot part 6 of them; and 16 anywhere.
    // Sets 3, 67 and 195 differ only in the index's top 2 bits (the address's 13:12, new at
    // 256 sets): an I$ that lost them would mix their lines; 255 the last set (the sweep's end)
    std::vector<uint64_t> pool, hot;
    int sets4[4] = {3, 67, 195, 255};
    for (int s = 0; s < 4; s++)
        for (int t = 0; t < 12; t++) {
            uint64_t l = ((rng() & ((1ull << 25) - 1)) << 8) | (uint64_t)sets4[s];
            pool.push_back(l); if (t < 6) hot.push_back(l);
        }
    for (int k = 0; k < 16; k++) pool.push_back(rng() & ((1ull << 33) - 1));

    // ---- the account
    struct Line { bool v = false; uint64_t tag = 0; uint64_t w[8] = {0}; };
    static Line c[WAYS][SETS];
    for (auto& x : c) for (auto& y : x) y.v = rng() & 1;      // (the LUT RAM starts at random: the sweep clears it)
    int rr = 0;
    bool s1_v = false, s1_rp = false; int s1_way = -1; uint64_t s1_line = 0; int s1_half = 0; bool s1_vs[WAYS] = {false};
    bool busy = false, arp = false, m_err = false, rp = false; uint64_t m_line = 0; int m_half = 0, m_way = 0, beat = 0; uint64_t fb[8];
    bool resp_v = false; uint64_t resp[4] = {0}; bool done = false;
    bool cl = true; int fc = 0;                               // the sweep, after the reset
    // ---- the memory's bus
    bool burst = false; uint64_t b_line = 0; long b_at = 0; int b_beat = 0;
    // ---- FENCE.I
    bool fl = false; long fl_at = 3000;

    long bad = 0, cyc, nacc = 0, nhit = 0, nmiss = 0, nevict = 0, nerr = 0, nfl = 0, nfl_busy = 0, nans = 0, nwr = 0, nrp = 0;
    uint64_t next_pc = 0;
    const long N = 400000;
    auto err = [&](const char* m) { if (bad++ < 12) printf("cycle %ld: %s\n", cyc, m); };
    for (cyc = 0; cyc < N + 200; cyc++) {
        bool quiet = cyc >= N;
        // ---- the inputs
        bool rv = !quiet && rng() % 10 < 7;
        uint64_t l;
        if (rng() % 4 == 0) l = next_pc >> 6;
        else l = (rng() % 10 < 7) ? hot[rng() % hot.size()] : pool[rng() % pool.size()];
        uint64_t pc = (l << 6) | ((rng() & 1) << 5) | (rng() & 31);      // a byte address, its bit 0 dropped below
        if (rng() % 4 == 0 && (next_pc >> 6) == l) pc = next_pc | (rng() & 31);
        d.ic_req_valid = rv; d.ic_req_pc = (pc >> 1) & ((1ull << 38) - 1);
        if (!fl && !quiet && cyc >= fl_at) { fl = true; nfl++; if (busy) nfl_busy++; }
        d.ic_flush = fl;
        d.m_axi4_arready = rng() % 10 < 7;
        bool rgive = burst && cyc >= b_at && rng() % 4 != 0;
        uint64_t rdata = rgive ? word((b_line << 6) | (uint64_t)(b_beat * 8)) : rng();
        int rresp = (rgive && rng() % 300 == 0) ? 2 : 0;
        d.m_axi4_rvalid = rgive; d.m_axi4_rdata = rdata; d.m_axi4_rresp = rresp; d.m_axi4_rlast = rgive && b_beat == 7;
        d.eval();

        // ---- the outputs against the account
        bool s1_miss = s1_v && !s1_rp && s1_way < 0;
        bool ready = !busy && !s1_miss && !cl && !fl;
        if ((bool)d.ic_req_ready != ready) err("ic_req_ready");
        if ((bool)d.ic_resp_valid != resp_v) err("ic_resp_valid");
        if (resp_v) {
            nans++;
            for (int k = 0; k < 4; k++) {
                uint64_t got = (uint64_t)d.ic_resp_data[2 * k] | ((uint64_t)d.ic_resp_data[2 * k + 1] << 32);
                if (got != resp[k]) { err("ic_resp_data"); break; }
            }
        }
        if ((bool)d.m_axi4_arvalid != arp) err("arvalid");
        if (arp && ((uint64_t)d.m_axi4_araddr != (m_line << 6) || d.m_axi4_arid != 2 || d.m_axi4_arlen != 7 ||
                    d.m_axi4_arsize != 3 || d.m_axi4_arburst != 1)) err("the AR");
        if (!d.m_axi4_rready) err("rready");
        if ((bool)d.ic_done != done) err("ic_done");

        // ---- the account at the edge
        bool acc = rv && ready;
        bool busy0 = busy;                                    // (the registers' values in this cycle)
        bool arok = arp && d.m_axi4_arready;
        bool fill_end = busy && rgive && b_beat == 7;
        // F1: the answer (a hit's line, or zeros for a request looked up again whose fill failed)
        bool nresp_v = s1_v && !s1_miss;
        uint64_t nresp[4]; for (int k = 0; k < 4; k++) nresp[k] = resp[k];
        if (nresp_v) for (int k = 0; k < 4; k++) nresp[k] = s1_way >= 0 ? c[s1_way][s1_line % SETS].w[4 * s1_half + k] : 0;
        // F0: a request's lookup (or the miss's again), on the lines as they are before the edge
        bool ns1_v = acc || rp, ns1_rp = rp; int ns1_way = -1; bool ns1_vs[WAYS];
        uint64_t ns1_line = rp ? m_line : l; int ns1_half = rp ? m_half : (int)((pc >> 5) & 1);
        if (ns1_v) {
            uint64_t set = ns1_line % SETS, tag = ns1_line / SETS;
            for (int w = 0; w < WAYS; w++) { ns1_vs[w] = c[w][set].v; if (c[w][set].v && c[w][set].tag == tag) ns1_way = w; }
        }
        if (acc) {
            nacc++; if (ns1_way >= 0) nhit++;
            next_pc = (l << 6) + ((uint64_t)ns1_half << 5) + 32;
        }
        if (rp) { nrp++; rp = false; busy = false; }
        // F1: a miss is asked for
        if (s1_miss) {
            nmiss++;
            int vic = rr;
            for (int w = WAYS - 1; w >= 0; w--) if (!s1_vs[w]) vic = w;
            if (s1_vs[vic]) nevict++;
            busy = true; arp = true; m_line = s1_line; m_half = s1_half; m_way = vic; beat = 0; m_err = false;
        }
        if (arok) {
            arp = false;
            if (burst) err("(a second AR while a burst is out)");
            burst = true; b_line = m_line; b_beat = 0; b_at = cyc + 1 + (rng() % 50 == 0 ? 40 : (long)(rng() % 20));
        }
        if (busy && rgive) {
            fb[beat] = rdata;
            if (rresp) m_err = true;
            beat++;
            if (fill_end) {
                Line& x = c[m_way][m_line % SETS];
                x.tag = m_line / SETS; for (int k = 0; k < 8; k++) x.w[k] = fb[k];
                x.v = !m_err;
                if (m_err) nerr++;
                rr = (rr + 1) % WAYS;
                rp = true;
            }
        } else if (rgive) err("(a beat with no miss)");
        if (rgive) { if (++b_beat == 8) burst = false; }
        // the sweep (FENCE.I's starts once no line is asked for), and ic_done
        bool ndone = done;
        if (cl) {
            for (int w = 0; w < WAYS; w++) c[w][fc].v = false;
            if (fc == SETS - 1) { cl = false; ndone = fl; }
            fc = (fc + 1) % SETS;
        } else if (fl && !done && !busy0 && !s1_miss) cl = true;
        if (!fl) ndone = false;
        if (fl && d.ic_done) { fl = false; fl_at = cyc + 500 + (long)(rng() % 4000); }
        resp_v = nresp_v; for (int k = 0; k < 4; k++) resp[k] = nresp[k];
        done = ndone;
        s1_v = ns1_v; s1_rp = ns1_rp; s1_way = ns1_way; s1_line = ns1_line; s1_half = ns1_half;
        if (ns1_v) for (int w = 0; w < WAYS; w++) s1_vs[w] = ns1_vs[w];
        // the D$'s writes: a word of the pool now and then
        if (rng() % 50 == 0) { uint64_t wl = pool[rng() % pool.size()]; mem[((wl << 6) | ((rng() & 7) << 3)) >> 3] = rng(); nwr++; }

        d.clk = 1; d.eval(); d.clk = 0; d.eval();
    }
    if (busy || rp || s1_v || resp_v) err("something left unanswered at the end");
    printf("tb_icache: %ld cycles, %ld requests (%ld hits, %ld misses, %ld evicting, %ld looked up again), %ld answers, "
           "%ld fills with an error, %ld FENCE.I (%ld during a fill), %ld memory writes, %ld mismatches: %s\n",
           cyc, nacc, nhit, nmiss, nevict, nrp, nans, nerr, nfl, nfl_busy, nwr, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
