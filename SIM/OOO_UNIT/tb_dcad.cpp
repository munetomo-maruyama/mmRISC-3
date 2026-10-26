//---------------------------------------------------------------------------
// tb_dcad.cpp : OOO_DCAD, the adapter between OOO_LSU and mmRISC-2's DCACHE,
// with both on either side of it (LSU_DC.sv) and a memory model on the
// D$'s AXI4 bus
//
// The rest of the core is tb_lsu's model (a random stream of loads, stores,
// branches and other µops, issued out of order, committed in order,
// mispredictions and exceptions); what tb_lsu's D$ model did is now the
// adapter, the real D$ (64 sets, 4 ways, 2 MSHRs, 2 write-back buffers, 8
// answers in flight) and the memory. The words used lie on 8 lines, 6 of
// them in one set of the 4-way D$, so that lines are evicted (dirty ones
// written back) and filled again all the time (DCAD_SPREAD=1: one line a
// set, nearly all hits). The memory answers after a random delay, with
// random gaps between beats and random ready signals. The fills to the LSU
// are held now and then (tb_hold, in bursts), so that the adapter has to
// keep answers.
//
// Checked: everything tb_lsu checks (every load's value against program
// order, loads complete once, ld_cancel, the stores in commit order with
// their data and mask, lsu_st_known, no deadlock), and that the adapter
// answers each load the D$ took once at most (in M or by a fill). The
// values loads read went through the adapter and the D$: a hit in M, a late
// fill, a stale answer (a load tried again after an older store reached the
// D$) or one of a freed LQ entry given to its next owner, all show as a
// wrong value or a completion that should not be.
//---------------------------------------------------------------------------
#include "VLSU_DC.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>
#include <random>
#include <vector>

static const int NLQ = 8, NSQ = 8, WINDOW = 24;
static const int LQW = 3, CKW = 4;          // index and tail (wrap bit) widths of the LQ / SQ
static const uint64_t BASE = 0x80001040ull;   // set 1 of the D$
static const int NWORD = 16;                   // 2 words on each of 8 lines
// line k: 0..5 in set 1 (6 lines for 4 ways), 6 and 7 in sets 2 and 3
// (DCAD_SPREAD=1: the 8 lines in 8 sets, nothing evicted after the first fills)
static bool spread = false;
static uint64_t addr_of(int w) { int k = w / 2; return (k < 6 && !spread ? BASE + 4096ull * k : BASE + 64ull * (k < 6 && !spread ? k - 5 : k)) + 24ull * (w % 2); }
static int idx(uint64_t a) { for (int w = 0; w < NWORD; w++) if (addr_of(w) == (a & ~7ull)) return w * 8 + (int)(a & 7); return -1; }

enum Kind { LD, ST, BR, OT };
struct Uop {
    long seq; Kind k; int rob;
    int lq = -1, sq = -1;
    uint64_t addr = 0; int size = 0; bool uns = false; uint64_t data = 0;
    int tag = -1;
    bool mis = false;              // misaligned: an exception
    bool issued = false, done = false, exc = false;
    bool canc = false;             // raised ld_cancel: its completion is marked for replay
    long disp_cyc = 0, resolve_at = 0;
    bool mispred = false;
    unsigned ck_lq = 0, ck_sq = 0; // checkpoint tails (branches)
};

static std::mt19937_64 rng(4242);
static VLSU_DC d;
static long bad = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint8_t arch[8 * NWORD];    // memory after the committed stores
static std::map<uint64_t, uint64_t> mem;   // the AXI4 memory: 8-byte words

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("DCAD_SEED")) rng.seed(strtoull(e, nullptr, 0));   // another stream
    if (const char* e = getenv("DCAD_SPREAD")) spread = atoi(e) != 0;
    long cyc = 0;
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    for (int k = 0; k < 8; k++) for (int j = 0; j < 8; j++) mem[(addr_of(2 * k) & ~63ull) + 8 * j] = rng();
    for (int i = 0; i < 8 * NWORD; i++) arch[i] = (uint8_t)(mem[addr_of(i / 8)] >> (8 * (i % 8)));

    std::deque<Uop> win;                       // in flight, program order
    long seq = 0;
    int rob_next = 0;
    std::map<int, long> tag_seq;               // load tag -> seq
    std::vector<int> free_tags; for (int t = 1; t < 64; t++) free_tags.push_back(t);
    struct Burst { uint64_t addr; int len, beat; long at; };
    std::deque<Burst> rq, wq, bq;              // reads, writes waiting for data, writes waiting for B
    long nhit = 0, nfill = 0, nrd = 0, nwr = 0, nreq_ld = 0;
    int hold_left = 0;
    std::deque<std::pair<uint64_t, std::pair<uint64_t, int>>> st_expect;   // committed stores to drain: addr, data, size
    struct Pend { bool v = false; long seq; };
    Pend m_iss, wb_iss;                         // a load from port 2 now in M / expected in WB
    long last_commit = 0, nld = 0, nst = 0, nlate = 0, ncancel = 0, nrestore = 0, nflush = 0, nfwd_chk = 0;

    auto find = [&](long s) -> Uop* { for (auto& u : win) if (u.seq == s) return &u; return nullptr; };
    auto expected = [&](const Uop& L) {
        uint8_t m[8 * NWORD];
        for (int i = 0; i < 8 * NWORD; i++) m[i] = arch[i];
        for (auto& u : win) {
            if (u.seq >= L.seq) break;
            if (u.k == ST && !u.mis) for (int b = 0; b < (1 << u.size); b++) m[idx(u.addr) + b] = (uint8_t)(u.data >> (8 * b));
        }
        uint64_t v = 0;
        for (int b = 0; b < (1 << L.size); b++) v |= (uint64_t)m[idx(L.addr) + b] << (8 * b);
        int bits = 8 << L.size;
        if (bits < 64 && !L.uns && ((v >> (bits - 1)) & 1)) v |= ~0ull << bits;
        return v;
    };

    for (cyc = 0; cyc < 300000; cyc++) {
        // ================= inputs of this cycle =================
        // -- recovery first: an exception at the head, else a mispredicted branch
        int flush_all = 0, restore = 0; unsigned r_lq = 0, r_sq = 0;
        int lq_commit = 0, sq_commit = 0;
        std::vector<long> committed;
        // commit up to 2 from the head
        for (int n = 0; n < 2 && !win.empty(); n++) {
            Uop& h = win.front();
            if (!h.done) break;
            if (h.exc) { flush_all = 1; break; }
            if (h.k == BR && h.resolve_at >= cyc) break;      // resolved (and restored) first
            committed.push_back(h.seq);
            if (h.k == LD) lq_commit++;
            if (h.k == ST) { sq_commit++; st_expect.push_back({h.addr, {h.data, h.size}}); for (int b = 0; b < (1 << h.size); b++) arch[idx(h.addr) + b] = (uint8_t)(h.data >> (8 * b)); }
            if (h.tag >= 0) { tag_seq.erase(h.tag); free_tags.push_back(h.tag); }
            win.pop_front();
            last_commit = cyc;
        }
        long restore_seq = -1;
        if (!flush_all)
            for (auto& u : win)
                if (u.k == BR && u.mispred && u.resolve_at == cyc) { restore = 1; r_lq = u.ck_lq; r_sq = u.ck_sq; restore_seq = u.seq; break; }
        // -- dispatch (none in a cycle of recovery)
        int dv = 0, dld = 0, dst = 0; unsigned drob = 0;
        Uop nu[2]; int nn = 0;
        if (!flush_all && !restore) {
            int lroom = d.lq_avail, sroom = d.sq_avail;
            for (int s = 0; s < 2; s++) {
                if ((int)win.size() + nn >= WINDOW || rng() % 4 == 0) break;
                Uop u; u.seq = seq;
                // a ROB index not in use (a real ROB takes its tail, recovered on a flush)
                for (int t = 0; t < 32; t++) {
                    int r = (rob_next + t) % 32; bool used = false;
                    for (auto& w : win) used |= w.rob == r;
                    for (int j = 0; j < nn; j++) used |= nu[j].rob == r;
                    if (!used) { u.rob = r; break; }
                }
                int r = rng() % 100;
                u.k = r < 35 ? LD : r < 65 ? ST : r < 75 ? BR : OT;
                if (u.k == LD && (lroom <= 0 || free_tags.empty())) break;
                if (u.k == ST && sroom <= 0) break;
                if (u.k == LD) lroom--;
                if (u.k == ST) sroom--;
                u.size = rng() % 4;
                {   // a word, and an offset in it: mostly aligned; a misaligned one
                    // may run past its word (it never reaches memory)
                    int off = rng() % 8;
                    if (rng() % 20) off &= ~((1 << u.size) - 1);
                    u.addr = addr_of(rng() % NWORD) + off;
                }
                u.mis = (u.addr & ((1 << u.size) - 1)) != 0;
                u.uns = rng() & 1;
                u.data = rng();
                if (u.k == LD) { int i = rng() % free_tags.size(); u.tag = free_tags[i]; free_tags.erase(free_tags.begin() + i); tag_seq[u.tag] = u.seq; }
                if (u.k == BR) { u.resolve_at = cyc + 2 + rng() % 12; u.mispred = rng() % 4 == 0; }
                u.disp_cyc = cyc;
                dv |= 1 << s; if (u.k == LD) dld |= 1 << s; if (u.k == ST) dst |= 1 << s;
                drob |= (unsigned)u.rob << (5 * s);
                nu[nn++] = u; seq++; rob_next = (rob_next + 1) % 32;
            }
        }
        // -- issue to port 2: one LSU µop dispatched before this cycle
        int iv = 0; Uop* iu = nullptr;
        if (!flush_all && !restore && rng() % 5) {
            std::vector<Uop*> cand;
            for (auto& u : win)
                if ((u.k == LD || u.k == ST) && !u.issued && u.disp_cyc < cyc) {
                    if (u.k == LD && !((d.lsu_st_known >> u.lq) & 1) && rng() % 8) continue;
                    cand.push_back(&u);
                }
            if (!cand.empty()) { iu = cand[rng() % cand.size()]; iv = 1; }
        }
        // -- the memory: random ready signals, beats after a delay with gaps
        int arready = rng() % 4 != 0, awready = rng() % 4 != 0, wready = !wq.empty() && rng() % 4 != 0;
        int rvalid = !rq.empty() && rq.front().at <= cyc && rng() % 5 != 0;
        int bvalid = !bq.empty() && bq.front().at <= cyc && rng() % 3 != 0;

        // drive
        d.disp_valid = dv; d.disp_ld = dld; d.disp_st = dst; d.disp_rob = drob;
        d.iss_valid = iv;
        if (iv) {
            d.iss_ld = iu->k == LD; d.iss_lq = iu->lq < 0 ? 0 : iu->lq; d.iss_sq = iu->sq < 0 ? 0 : iu->sq;
            int imm = (int)(rng() % 4096) - 2048;
            d.iss_base = iu->addr - (int64_t)imm; d.iss_imm = imm & 0xfff;
            d.iss_data = iu->data; d.iss_size = iu->size; d.iss_uns = iu->uns; d.iss_dst = iu->tag < 0 ? 0 : iu->tag;
        } else d.iss_valid = 0;
        d.m_axi4_arready = arready; d.m_axi4_awready = awready; d.m_axi4_wready = wready;
        d.m_axi4_rvalid = rvalid; d.m_axi4_rresp = 0; d.m_axi4_bvalid = bvalid; d.m_axi4_bresp = 0;
        if (rvalid) {
            auto it = mem.find(rq.front().addr + 8 * rq.front().beat);     // (outside: reported at the AR)
            d.m_axi4_rdata = it != mem.end() ? it->second : rng(); d.m_axi4_rlast = rq.front().beat == rq.front().len;
        }
        else { d.m_axi4_rdata = rng(); d.m_axi4_rlast = rng() & 1; }
        d.lq_commit = lq_commit; d.sq_commit = sq_commit;
        d.restore = restore; d.restore_lq_tail = r_lq; d.restore_sq_tail = r_sq; d.flush_all = flush_all;
        if (hold_left > 0) hold_left--; else if (rng() % 40 == 0) hold_left = 1 + rng() % 12;
        d.tb_hold = hold_left > 0;
        d.eval();

        // ================= outputs of this cycle =================
        // dispatch: the entries given
        for (int s = 0, k = 0; s < 2; s++) {
            if (!((dv >> s) & 1)) continue;
            Uop& u = nu[k++];
            if (u.k == LD) u.lq = (d.disp_lq >> (LQW * s)) & ((1 << LQW) - 1);
            if (u.k == ST) u.sq = (d.disp_sq >> (LQW * s)) & ((1 << LQW) - 1);
            if (u.k == BR) { u.ck_lq = (d.ck_lq_tail >> (CKW * s)) & ((1 << CKW) - 1); u.ck_sq = (d.ck_sq_tail >> (CKW * s)) & ((1 << CKW) - 1); }
        }
        // no two µops in flight share an LQ / SQ entry
        { std::map<int, long> lqs, sqs;
          for (auto& u : win) {
              if (u.k == LD) { if (lqs.count(u.lq)) FAIL("loads %ld and %ld share LQ entry %d", lqs[u.lq], u.seq, u.lq); lqs[u.lq] = u.seq; }
              if (u.k == ST) { if (sqs.count(u.sq)) FAIL("stores %ld and %ld share SQ entry %d", sqs[u.sq], u.seq, u.sq); sqs[u.sq] = u.seq; }
          } }
        // lsu_st_known: never for a load with an older store without an address
        for (auto& L : win) if (L.k == LD && ((d.lsu_st_known >> L.lq) & 1))
            for (auto& u : win) { if (u.seq >= L.seq) break; if (u.k == ST && !(u.issued && !u.mis)) { FAIL("lsu_st_known set for load %ld (lq %d, disp %ld) with store %ld not known (sq %d, disp %ld, issued %d, mis %d)", L.seq, L.lq, L.disp_cyc, u.seq, u.sq, u.disp_cyc, u.issued, u.mis); break; } }
        // a store in E completes
        if (d.cmp_st_valid) {
            if (!iv || iu->k != ST) FAIL("store completion without a store in E");
            else {
                if ((int)d.cmp_st_rob != iu->rob) FAIL("store completion: rob %d, expected %d", (int)d.cmp_st_rob, iu->rob);
                if ((bool)d.cmp_st_exc != iu->mis) FAIL("store completion: exception %d, expected %d", (int)d.cmp_st_exc, iu->mis);
                iu->done = true; iu->exc = iu->mis; nst++;
            }
        } else if (iv && iu->k == ST) FAIL("store %ld issued without a completion", iu->seq);
        if (d.mon_hit) nhit++;
        if (d.mon_fill) nfill++;
        if (d.mon_req && d.mon_req_ld) nreq_ld++;
        // every load the D$ took is answered once at most (in M or by a fill)
        if (nhit + nfill > nreq_ld) FAIL("%ld answers in M and %ld fills for %ld loads sent to the D$", nhit, nfill, nreq_ld);
        // ld_cancel in M for the load from port 2 issued last cycle
        bool canc = d.ld_cancel;
        if (m_iss.v) {
            Uop* M = find(m_iss.seq);
            if (!M) FAIL("load %ld in M is no longer in flight", m_iss.seq);
            else if (canc && (int)d.ld_cancel_tag != M->tag) FAIL("ld_cancel tag %d, expected %d", (int)d.ld_cancel_tag, M->tag);
            else if (canc) M->canc = true;
        } else if (canc) FAIL("ld_cancel without a load from port 2 in M");
        if (canc) ncancel++;
        // WB: the result register (from last cycle's M or a fill)
        if (d.cmp_ld_valid) {
            int rob = d.cmp_ld_rob;
            Uop* L = nullptr; for (auto& u : win) if (u.k == LD && u.rob == rob && !u.done) { L = &u; break; }
            if (!L) FAIL("load completion for rob %d with no such load waiting", rob);
            else {
                if (d.cmp_ld_exc) {
                    if (!L->mis) FAIL("load %ld: exception, but it is aligned", L->seq);
                    if (d.wb_valid) FAIL("load %ld: exception with a register write", L->seq);
                    L->done = true; L->exc = true;
                } else {
                    if (L->mis) FAIL("load %ld: misaligned but no exception", L->seq);
                    if (!d.wb_valid || (int)d.wb_tag != L->tag) FAIL("load %ld: completion without its write (tag %d / %d)", L->seq, (int)d.wb_tag, L->tag);
                    uint64_t e = expected(*L);
                    if (d.wb_data != e) FAIL("load %ld (addr %llx size %d uns %d): data %016llx, expected %016llx", L->seq,
                                             (unsigned long long)L->addr, L->size, L->uns, (unsigned long long)d.wb_data, (unsigned long long)e);
                    // on time only for the load from port 2 two cycles ago, not cancelled
                    bool ontime = wb_iss.v && wb_iss.seq == L->seq;
                    if (!d.wb_late && !ontime) FAIL("load %ld: written as on time, but it was not issued for this cycle", L->seq);
                    if (d.wb_late && ontime) FAIL("load %ld: written as late in its expected cycle", L->seq);
                    if (d.wb_late) nlate++;
                    if ((bool)d.cmp_ld_rp != L->canc) FAIL("load %ld: replay mark %d, expected %d", L->seq, (int)d.cmp_ld_rp, L->canc);
                    L->done = true; nld++;
                }
            }
        } else if (d.wb_valid) FAIL("register write without a completion");
        if (wb_iss.v) {      // the load expected in WB this cycle (not cancelled): it must be written
            Uop* L = find(wb_iss.seq);
            bool wrote = d.cmp_ld_valid && L && L->rob == (int)d.cmp_ld_rob && d.wb_valid && !d.wb_late;
            if (!wrote) FAIL("load %ld: not cancelled, but no result in its expected cycle", wb_iss.seq);
        }
        // the store port into the adapter
        if (d.mon_st) {
            if (st_expect.empty()) FAIL("a store written to the D$ before any was committed");
            else {
                auto e = st_expect.front(); st_expect.pop_front();
                uint64_t a = e.first; int sz = e.second.second; uint64_t dat = e.second.first;
                uint64_t m8 = (uint64_t)((1 << (1 << sz)) - 1) << (a & 7);
                if (d.mon_st_addr != (a & ~7ull) || d.mon_st_mask != m8) FAIL("D$ store: addr %llx mask %02x, expected %llx %02x",
                    (unsigned long long)d.mon_st_addr, (unsigned)d.mon_st_mask, (unsigned long long)(a & ~7ull), (unsigned)m8);
                for (int b = 0; b < 8; b++) if ((d.mon_st_mask >> b) & 1) {
                    uint8_t got = (uint8_t)(d.mon_st_data >> (8 * b)), want = (uint8_t)((dat << (8 * (a & 7))) >> (8 * b));
                    if (got != want) { FAIL("D$ store data byte %d: %02x, expected %02x", b, got, want); break; }
                }
            }
        }
        // the memory's handshakes of this cycle
        bool ar = d.m_axi4_arvalid && arready, aw = d.m_axi4_awvalid && awready;
        bool r = rvalid && d.m_axi4_rready, w = d.m_axi4_wvalid && wready, b = bvalid && d.m_axi4_bready;
        Burst arb{(uint64_t)d.m_axi4_araddr, (int)d.m_axi4_arlen, 0, cyc + 3 + (long)(rng() % 14)};
        Burst awb{(uint64_t)d.m_axi4_awaddr, (int)d.m_axi4_awlen, 0, 0};
        if (ar && (d.m_axi4_arsize != 3 || d.m_axi4_arburst != 1)) FAIL("AR: size %d burst %d", (int)d.m_axi4_arsize, (int)d.m_axi4_arburst);
        if (ar && !mem.count(arb.addr)) FAIL("read of %llx, outside the lines used", (unsigned long long)arb.addr);
        if (w) {
            Burst& x = wq.front();
            uint64_t a = x.addr + 8 * x.beat;
            if (!mem.count(a)) FAIL("write to %llx, outside the lines used", (unsigned long long)a);
            else {
                uint64_t v = mem[a];
                for (int k = 0; k < 8; k++) if ((d.m_axi4_wstrb >> k) & 1) v = (v & ~(0xffull << (8 * k))) | (d.m_axi4_wdata & (0xffull << (8 * k)));
                mem[a] = v;
            }
            if ((bool)d.m_axi4_wlast != (x.beat == x.len)) FAIL("W: wlast %d at beat %d of %d", (int)d.m_axi4_wlast, x.beat, x.len);
        }

        // ================= the clock =================
        d.clk = 1; d.eval(); d.clk = 0; d.eval();

        // ================= the model after the clock =================
        // the memory
        if (ar) { rq.push_back(arb); nrd++; }
        if (r && ++rq.front().beat > rq.front().len) rq.pop_front();
        if (aw) { wq.push_back(awb); nwr++; }
        if (w && ++wq.front().beat > wq.front().len) { Burst x = wq.front(); wq.pop_front(); x.at = cyc + 1 + (long)(rng() % 6); bq.push_back(x); }
        if (b) bq.pop_front();
        // the pipeline of the load from port 2
        wb_iss = Pend();
        if (m_iss.v && !canc && !flush_all && !restore) wb_iss = m_iss;
        m_iss = Pend();
        if (iv && iu->k == LD && !flush_all && !restore) { m_iss.v = true; m_iss.seq = iu->seq; }
        if (iv && !flush_all && !restore) iu->issued = true;
        // recovery
        if (flush_all) {
            win.clear(); nflush++;
            for (auto it = tag_seq.begin(); it != tag_seq.end();) { free_tags.push_back(it->first); it = tag_seq.erase(it); }
            m_iss = Pend(); wb_iss = Pend();
        } else if (restore) {
            nrestore++;
            while (!win.empty() && win.back().seq > restore_seq) {
                if (win.back().tag >= 0) { tag_seq.erase(win.back().tag); free_tags.push_back(win.back().tag); }
                win.pop_back();
            }
            for (auto& u : win) if (u.seq == restore_seq) u.mispred = false;
            if (m_iss.v && !find(m_iss.seq)) m_iss = Pend();
            if (wb_iss.v && !find(wb_iss.seq)) wb_iss = Pend();
        }
        for (int k = 0; k < nn && !flush_all && !restore; k++) win.push_back(nu[k]);
        for (auto& u : win) if ((u.k == OT || u.k == BR) && !u.done) u.done = true;
        if (cyc - last_commit > 2000 && !win.empty()) { FAIL("deadlock: µop %ld (kind %d) at the head", win.front().seq, win.front().k); break; }
    }
    printf("tb_dcad: %ld cycles, %ld loads (%ld late; %ld D$ reads, %ld hits in M, %ld fills), %ld stores, %ld line fills, %ld write-backs, %ld cancels, %ld restores, %ld flushes, %ld mismatches: %s\n",
           cyc, nld, nlate, nreq_ld, nhit, nfill, nst, nrd, nwr, ncancel, nrestore, nflush, bad, bad ? "FAIL" : "PASS");
    (void)nfwd_chk;
    return bad ? 1 : 0;
}
