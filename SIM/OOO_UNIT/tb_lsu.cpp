//---------------------------------------------------------------------------
// tb_lsu.cpp : OOO_LSU (LQ 8, SQ 8) inside a model of the rest of the core
//
// A random stream of µops in program order (loads, stores, branches, other)
// to a few 8-byte words, so that loads and stores meet often: dispatched up
// to 2 a cycle while the queues and a 24-entry window have room, issued to
// port 2 in random order (a load mostly only when lsu_st_known says its
// older stores have addresses, now and then earlier to exercise the LSU's
// own wait), committed in order. A D$ model answers hit or miss at random,
// fills misses after a few cycles, takes stores when it is ready (now and
// then not; it drops the pending fills of the LQ entries in dc_kill).
// Branches resolve at random and some are mispredicted (restore
// to the tails of their checkpoint); a misaligned access is an exception
// that flushes everything younger when it reaches the head (flush_all).
// Branches hold checkpoint ids (6, as OOO_CTRL gives them); an issued µop
// carries the mask of the unresolved branches older than it (iss_bm), and
// a restore kills the id of its branch (kill). µops issue in cycles of
// recovery too: one younger than the branch is dropped in E and M (no SQ
// write, no completion), one older goes on as in any other cycle (Plan/
// OOC.md 20: dropped on any restore before, an older one was lost).
//
// Checked:
//   - every load's value: the committed memory with every older store not
//     yet committed applied in program order (so flushed stores never count)
//   - every load completes once (on time or late, or with an exception for
//     a misaligned one, which writes nothing); nothing completes for an
//     entry that was flushed
//   - ld_cancel: raised for a load from port 2 exactly when it gives no
//     result in its expected cycle; such a load, and only such a load,
//     completes marked for replay after commit (cmp_ld_rp)
//   - the stores reach the D$ in commit order with their data and byte mask;
//     sq_drained exactly when none committed is left
//   - lsu_st_known is never set for a load with an older store whose
//     address is not known
//   - no deadlock: the oldest µop commits within a bound
//---------------------------------------------------------------------------
#include "VOOO_LSU.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>
#include <random>
#include <vector>

static const int NLQ = 8, NSQ = 8, WINDOW = 24;
static const int LQW = 3, CKW = 4;          // index and tail (wrap bit) widths of the LQ / SQ
static const uint64_t BASE = 0x80001000ull;   // the words used: BASE .. BASE + 8 * NWORD
static const int NWORD = 4;

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
    int ck = -1;                   // checkpoint id while unresolved (branches)
};

static std::mt19937_64 rng(4242);
static VOOO_LSU d;
static long bad = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint8_t arch[8 * NWORD];    // memory after the committed stores
static uint8_t dmem[8 * NWORD];    // the D$ model: after the stores written to it

static uint64_t word_of(const uint8_t* m, uint64_t a) { uint64_t w = 0; for (int i = 0; i < 8; i++) w |= (uint64_t)m[(a - BASE) / 8 * 8 + i] << (8 * i); return w; }

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("LSU_SEED")) rng.seed(strtoull(e, nullptr, 0));   // another stream
    long cyc = 0;
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();
    for (int i = 0; i < 8 * NWORD; i++) arch[i] = dmem[i] = (uint8_t)rng();

    std::deque<Uop> win;                       // in flight, program order
    long seq = 0;
    int rob_next = 0;
    std::map<int, long> tag_seq;               // load tag -> seq
    std::vector<int> free_tags; for (int t = 1; t < 64; t++) free_tags.push_back(t);
    struct Fill { long at; unsigned tag; uint64_t addr; };
    std::deque<Fill> fills;
    std::deque<std::pair<uint64_t, std::pair<uint64_t, int>>> st_expect;   // committed stores to drain: addr, data, size
    struct Pend { bool v = false; long seq; };
    Pend m_iss, wb_iss;                         // a load from port 2 now in M / expected in WB
    long last_commit = 0, nld = 0, nst = 0, nlate = 0, ncancel = 0, nrestore = 0, nflush = 0, nfwd_chk = 0;
    long dreq_pending_seq = -1; uint64_t dreq_word = 0; bool dreq_v = false, dreq_hit = false;
    bool ck_used[6] = {false};
    long nkilled_iss = 0, nrec_iss = 0;

    auto find = [&](long s) -> Uop* { for (auto& u : win) if (u.seq == s) return &u; return nullptr; };
    auto mask_of = [&](const Uop& x) {           // the unresolved branches older than it
        unsigned m = 0;
        for (auto& b : win) { if (b.seq >= x.seq) break; if (b.k == BR && b.ck >= 0) m |= 1u << b.ck; }
        return m;
    };
    auto expected = [&](const Uop& L) {
        uint8_t m[8 * NWORD];
        for (int i = 0; i < 8 * NWORD; i++) m[i] = arch[i];
        for (auto& u : win) {
            if (u.seq >= L.seq) break;
            if (u.k == ST && !u.mis) for (int b = 0; b < (1 << u.size); b++) m[u.addr - BASE + b] = (uint8_t)(u.data >> (8 * b));
        }
        uint64_t v = 0;
        for (int b = 0; b < (1 << L.size); b++) v |= (uint64_t)m[L.addr - BASE + b] << (8 * b);
        int bits = 8 << L.size;
        if (bits < 64 && !L.uns && ((v >> (bits - 1)) & 1)) v |= ~0ull << bits;
        return v;
    };

    for (cyc = 0; cyc < 300000; cyc++) {
        // sq_drained (OOO_SYS's FENCE / FENCE.I): every committed store is in the D$
        { d.eval(); if ((bool)d.sq_drained != st_expect.empty()) FAIL("sq_drained %d with %zu committed stores to drain", (int)d.sq_drained, st_expect.size()); }
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
            if (h.k == ST) { sq_commit++; st_expect.push_back({h.addr, {h.data, h.size}}); for (int b = 0; b < (1 << h.size); b++) arch[h.addr - BASE + b] = (uint8_t)(h.data >> (8 * b)); }
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
                if (u.k == BR) {
                    int c = -1; for (int i = 0; i < 6; i++) if (!ck_used[i]) { c = i; break; }
                    if (c < 0) break;
                    u.ck = c; ck_used[c] = true;
                }
                if (u.k == LD) lroom--;
                if (u.k == ST) sroom--;
                u.size = rng() % 4;
                u.addr = BASE + (rng() % (8 * NWORD));
                if (rng() % 20) u.addr &= ~(uint64_t)((1 << u.size) - 1);      // mostly aligned
                u.mis = (u.addr & ((1 << u.size) - 1)) != 0;
                if (u.addr + (1 << u.size) > BASE + 8 * NWORD) u.addr -= 8;   // stay inside
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
        // -- issue to port 2: one LSU µop dispatched before this cycle (in a
        // cycle of recovery too)
        int iv = 0; Uop* iu = nullptr;
        if (rng() % 5) {
            std::vector<Uop*> cand;
            for (auto& u : win)
                if ((u.k == LD || u.k == ST) && !u.issued && u.disp_cyc < cyc) {
                    if (u.k == LD && !((d.lsu_st_known >> u.lq) & 1) && rng() % 8) continue;
                    cand.push_back(&u);
                }
            if (!cand.empty()) { iu = cand[rng() % cand.size()]; iv = 1; }
        }
        // -- the D$ model: the answer to last cycle's request, fills, the write port
        int fill_v = 0; unsigned fill_tag = 0; uint64_t fill_data = 0;
        if (!fills.empty() && fills.front().at <= cyc) {
            fill_v = 1; fill_tag = fills.front().tag; fill_data = word_of(dmem, fills.front().addr);
        }
        int st_ready = rng() % 10 < 7;

        // drive
        d.disp_valid = dv; d.disp_ld = dld; d.disp_st = dst; d.disp_rob = drob;
        d.iss_valid = iv;
        if (iv) {
            d.iss_ld = iu->k == LD; d.iss_lq = iu->lq < 0 ? 0 : iu->lq; d.iss_sq = iu->sq < 0 ? 0 : iu->sq;
            int imm = (int)(rng() % 4096) - 2048;
            d.iss_base = iu->addr - (int64_t)imm; d.iss_imm = imm & 0xfff;
            d.iss_data = iu->data; d.iss_size = iu->size; d.iss_uns = iu->uns; d.iss_dst = iu->tag < 0 ? 0 : iu->tag;
            d.iss_bm = mask_of(*iu);
        } else { d.iss_valid = 0; d.iss_bm = rng() & 63; }
        // the issued µop goes on unless it is flushed or killed now
        bool iss_live = iv && !flush_all && !(restore && iu->seq > restore_seq);
        if (iv && !iss_live) nkilled_iss++;
        if (iv && iss_live && (restore || flush_all)) nrec_iss++;
        d.dc_hit = dreq_hit; d.dc_rdata = dreq_v ? dreq_word : rng();
        d.dc_fill_valid = fill_v; d.dc_fill_tag = fill_tag; d.dc_fill_data = fill_data;
        d.dc_st_ready = st_ready;
        d.lq_commit = lq_commit; d.sq_commit = sq_commit;
        d.restore = restore; d.restore_lq_tail = r_lq; d.restore_sq_tail = r_sq; d.flush_all = flush_all;
        { unsigned km = 0; if (restore) for (auto& u : win) if (u.seq == restore_seq) km = 1u << u.ck;
          d.kill = km; }
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
            if (!iss_live) FAIL("store %ld completes, but it is killed or flushed now", iu->seq);
        } else if (iss_live && iu->k == ST) FAIL("store %ld issued without a completion", iu->seq);
        // D$ request in E
        bool req_now = d.dc_req_valid;
        uint64_t req_addr = d.dc_req_addr; unsigned req_tag = d.dc_req_tag;
        // the D$ reads before it writes (a block RAM read first): a store
        // written to it this cycle is not in this cycle's read
        uint64_t req_word = req_now ? word_of(dmem, req_addr & ~7ull) : 0;
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
        // the store write port
        if (d.dc_st_valid && st_ready) {
            if (st_expect.empty()) FAIL("a store written to the D$ before any was committed");
            else {
                auto e = st_expect.front(); st_expect.pop_front();
                uint64_t a = e.first; int sz = e.second.second; uint64_t dat = e.second.first;
                uint64_t m8 = (uint64_t)((1 << (1 << sz)) - 1) << (a & 7);
                if (d.dc_st_addr != (a & ~7ull) || d.dc_st_mask != m8) FAIL("D$ store: addr %llx mask %02x, expected %llx %02x",
                    (unsigned long long)d.dc_st_addr, (unsigned)d.dc_st_mask, (unsigned long long)(a & ~7ull), (unsigned)m8);
                for (int b = 0; b < 8; b++) if ((d.dc_st_mask >> b) & 1) {
                    uint8_t got = (uint8_t)(d.dc_st_data >> (8 * b)), want = (uint8_t)((dat << (8 * (a & 7))) >> (8 * b));
                    if (got != want) { FAIL("D$ store data byte %d: %02x, expected %02x", b, got, want); break; }
                    dmem[(d.dc_st_addr & ~7ull) - BASE + b] = got;
                }
            }
        }
        bool fill_taken = fill_v && d.dc_fill_ready;
        unsigned kill = d.dc_kill;      // entries freed now: their pending fills are dropped

        // ================= the clock =================
        d.clk = 1; d.eval(); d.clk = 0; d.eval();

        // ================= the model after the clock =================
        // the D$: a request now is answered next cycle; a miss makes a fill
        dreq_v = req_now;
        dreq_hit = rng() % 100 < 80;                   // decided once per request
        if (req_now) {
            dreq_word = req_word;
            if (!dreq_hit) fills.push_back({cyc + 3 + (long)(rng() % 12), req_tag, req_addr & ~7ull});
        }
        if (fill_taken) fills.pop_front();
        if (kill) {
            std::deque<Fill> keep;
            for (auto& f : fills) if (!((kill >> f.tag) & 1)) keep.push_back(f);
            fills.swap(keep);
        }
        // the pipeline of the load from port 2
        wb_iss = Pend();
        if (m_iss.v && !canc && !flush_all) wb_iss = m_iss;
        m_iss = Pend();
        if (iss_live && iu->k == LD) { m_iss.v = true; m_iss.seq = iu->seq; }
        if (iss_live) iu->issued = true;
        // checkpoint ids: a branch resolved as predicted frees its id now
        for (auto& u : win) if (u.k == BR && u.resolve_at == cyc && !u.mispred && u.ck >= 0) { ck_used[u.ck] = false; u.ck = -1; }
        // recovery
        if (flush_all) {
            for (auto& u : win) if (u.ck >= 0) ck_used[u.ck] = false;
            win.clear(); nflush++;
            for (auto it = tag_seq.begin(); it != tag_seq.end();) { free_tags.push_back(it->first); it = tag_seq.erase(it); }
            m_iss = Pend(); wb_iss = Pend();
        } else if (restore) {
            nrestore++;
            while (!win.empty() && win.back().seq > restore_seq) {
                if (win.back().tag >= 0) { tag_seq.erase(win.back().tag); free_tags.push_back(win.back().tag); }
                if (win.back().ck >= 0) ck_used[win.back().ck] = false;
                win.pop_back();
            }
            for (auto& u : win) if (u.seq == restore_seq) { u.mispred = false; ck_used[u.ck] = false; u.ck = -1; }
            if (m_iss.v && !find(m_iss.seq)) m_iss = Pend();
            if (wb_iss.v && !find(wb_iss.seq)) wb_iss = Pend();
        }
        for (int k = 0; k < nn && !flush_all && !restore; k++) win.push_back(nu[k]);
        for (auto& u : win) if ((u.k == OT || u.k == BR) && !u.done) u.done = true;
        if (cyc - last_commit > 2000 && !win.empty()) { FAIL("deadlock: µop %ld (kind %d) at the head", win.front().seq, win.front().k); break; }
    }
    printf("tb_lsu: %ld cycles, %ld loads (%ld late), %ld stores, %ld cancels, %ld restores, %ld flushes, %ld issued in recovery and kept, %ld killed at issue, %ld mismatches: %s\n",
           cyc, nld, nlate, nst, ncancel, nrestore, nflush, nrec_iss, nkilled_iss, bad, bad ? "FAIL" : "PASS");
    (void)nfwd_chk; (void)dreq_pending_seq;
    return bad ? 1 : 0;
}
