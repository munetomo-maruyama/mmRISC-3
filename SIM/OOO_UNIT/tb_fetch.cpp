//---------------------------------------------------------------------------
// tb_fetch.cpp : OOO_FETCH (uBTB, predecode, TAGE-S, BTB, RAS) running a
// program, against mirrors of its predictors and the program's true path
//
// The program: 4 KB of random instructions (16 / 32-bit ALU instructions,
// conditional branches 32-bit and compressed, jal / c.j forward, calls by
// jal and by jalr / c.jalr, returns by jalr / c.jr, indirect jumps), with
// targets at instruction starts, ending with a jump back to the start.
// Each branch has its behavior (a loop count, always, never, or a coin),
// each indirect jump its targets; calls and returns follow a true stack.
//
// The I$ behaves as mmRISC-2's ICACHE: a request accepted at F0 is answered
// 2 cycles later on a hit; on a miss (random) the answer comes later and
// no request is accepted meanwhile.
//
// The back end (here): the blocks go into a fetch buffer (4 blocks) and an
// FTQ (8, until commit), which give fetch its credit. Decode takes blocks
// and walks them along the program's true path: an instruction whose true
// next address is not the one predicted (the block's next address at its
// end, the next instruction before it) is a misprediction; a few cycles
// later fetch is stopped (be_stop, the back end's redirect) and the cycle
// after that redirected there (OOO_FERS's timing) with the history and the RAS put back
// from the block (its TAGE metadata and RAS snapshot) and the outcome of the
// mispredicted transfer, the buffer is flushed and the block's later part
// dropped. Blocks are committed in order (TAGE update with the slots that
// ran and their outcomes); indirect jumps update the BTB when walked.
//
// Checked:
//   - every block starts where the one before said fetch goes next (or
//     where the redirect sent it), and lies on the true path
//   - every block exactly as the front end must decide it: end, taken,
//     next address, the TAGE metadata (all 270 bits) and the RAS snapshot,
//     from mirrors of TAGE (tage_ref.h, read at the cycle of the request),
//     the BTB, the RAS and the carried half, and predecode (predec_ref.h)
//   - the credit is never exceeded, the program keeps going
//   - no block and no request in the cycle of a stop or a redirect
//---------------------------------------------------------------------------
#include "VOOO_FETCH.h"
#include "tage_ref.h"
#include "predec_ref.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <vector>

static std::mt19937_64 rng(29);
static VOOO_FETCH d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const int MEMP = 2048;                  // parcels of program (4 KB)
static const uint64_t BASE = 0x40000000;       // its halfword address (byte 0x8000_0000)
static const uint64_t AM = (1ull << 38) - 1;
static uint16_t mem[MEMP];

enum Kind { K_ALU, K_BR, K_JAL, K_CALL, K_RET, K_IJMP, K_ICALL };
struct Ins {
    int len = 2, kind = K_ALU, f = 0;          // f: the encoding chosen
    long tgt = 0;                              // parcel of the direct target
    int pat = 0, per = 1; long cnt = 0; uint64_t lcg = 1;
    std::vector<long> itg; long ii = 0;        // indirect targets
    long fallback = 0;                         // a return with an empty stack goes here
};
static std::vector<Ins> ins;
static std::vector<int> at;                    // parcel -> instruction (or -1)
static std::vector<long> starts;
static std::vector<uint64_t> stk;              // the true call stack (halfword return addresses)

static uint32_t rnd(int b) { return (uint32_t)(rng() & ((1ull << b) - 1)); }

static void build()
{
    at.assign(MEMP, -1);
    long pos = 0;
    while (pos < MEMP - 4) {
        Ins I;
        int r = rng() % 100;
        if (r < 30)      { I.kind = K_ALU; I.len = 2; }
        else if (r < 52) { I.kind = K_ALU; I.len = 4; }
        else if (r < 64) { I.kind = K_BR; I.len = 4; }
        else if (r < 72) { I.kind = K_BR; I.len = 2; }
        else if (r < 76) { I.kind = K_JAL; I.len = 4; }
        else if (r < 80) { I.kind = K_JAL; I.len = 2; }
        else if (r < 85) { I.kind = K_CALL; I.len = 4; }
        else if (r < 91) { I.kind = K_RET; I.len = rng() % 2 ? 2 : 4; }
        else if (r < 95) { I.kind = K_IJMP; I.len = rng() % 2 ? 2 : 4; }
        else             { I.kind = K_ICALL; I.len = rng() % 2 ? 2 : 4; }
        if (pos + I.len / 2 > MEMP - 3) { I.kind = K_ALU; I.len = 2; }
        at[pos] = (int)ins.size(); starts.push_back(pos);
        ins.push_back(I);
        pos += I.len / 2;
        if (rng() % 40 == 0)                    // now and then a run of compressed branches (4th, 5th in a block)
            for (int k = 0; k < 5 && pos < MEMP - 4; k++) {
                Ins J; J.kind = K_BR; J.len = 2; J.f = 1;
                at[pos] = (int)ins.size(); starts.push_back(pos); ins.push_back(J); pos++;
            }
    }
    { Ins I; I.kind = K_JAL; I.len = 4; I.tgt = 0; at[pos] = (int)ins.size(); starts.push_back(pos); ins.push_back(I); pos += 2; }
    long end = pos;
    for (; pos < MEMP; pos++) mem[pos] = 0x0001;           // c.nop
    // targets and encodings
    auto pick = [&](long lo, long hi) -> long {         // an instruction start in [lo, hi]
        lo = std::max(lo, 0L); hi = std::min(hi, end - 1);
        if (hi < lo) return 0L;                         // (a backward branch at the start: to itself)
        for (int t = 0; t < 64; t++) { long p = lo + (long)(rng() % (uint64_t)(hi - lo + 1)); if (at[p] >= 0) return p; }
        for (long p = lo; p <= hi; p++) if (at[p] >= 0) return p;
        return 0;
    };
    for (long p = 0; p < end; p++) {
        if (at[p] < 0) continue;
        Ins& I = ins[at[p]];
        uint32_t i = 0; uint16_t c = 0;
        long off;                               // bytes
        switch (I.kind) {
        case K_ALU:
            if (I.len == 2) c = (uint16_t)(rnd(14) << 2);                         // quadrant 0
            else i = (rnd(25) << 7) | (rng() % 2 ? 0x13 : 0x33);
            break;
        case K_BR: {
            bool back = rng() % 2;
            long range = I.len == 4 ? 512 : 120;
            I.tgt = back ? pick(p - range, p - 1) : pick(p + 1, p + range);
            if (I.tgt == 0 && p > 0 && back == false) I.tgt = pick(p - range, p - 1);
            back = I.tgt <= p;
            I.pat = back ? (rng() % 3 == 0 ? 3 : 2) : (int)(rng() % 4);
            if (I.f == 1 && rng() % 4) { I.pat = 1; back = false; I.tgt = pick(p + 1, p + range); }   // a run mostly falls through
            I.per = 2 + (int)(rng() % 12);
            I.lcg = rng() | 1;
            off = (I.tgt - p) * 2;
            if (I.len == 4) {
                uint64_t o = (uint64_t)off;
                i = (uint32_t)(((o >> 12) & 1) << 31 | ((o >> 5) & 63) << 25 | rnd(5) << 20 | rnd(5) << 15 |
                               (uint32_t)(rng() % 2 ? 0 : 1 + rng() % 6) << 12 | ((o >> 1) & 15) << 8 | ((o >> 11) & 1) << 7 | 0x63);
            } else {
                uint64_t o = (uint64_t)off;
                c = (uint16_t)((6u + rng() % 2) << 13 | ((o >> 8) & 1) << 12 | ((o >> 3) & 3) << 10 | rnd(3) << 7 |
                               ((o >> 6) & 3) << 5 | ((o >> 1) & 3) << 3 | ((o >> 5) & 1) << 2 | 1);
            }
            break;
        }
        case K_JAL: case K_CALL: {
            if (I.kind == K_JAL && p + I.len / 2 >= end) I.tgt = 0;     // the last jump goes back
            else if (I.kind == K_JAL) I.tgt = pick(p + 1, p + (I.len == 4 ? 600 : 900));
            else I.tgt = pick(0, end - 1);
            off = (I.tgt - p) * 2;
            uint64_t o = (uint64_t)off;
            if (I.len == 4) {
                uint32_t rd = I.kind == K_CALL ? (rng() % 4 ? 1 : 5) : 0;
                i = (uint32_t)(((o >> 20) & 1) << 31 | ((o >> 1) & 1023) << 21 | ((o >> 11) & 1) << 20 | ((o >> 12) & 255) << 12 | rd << 7 | 0x6f);
            } else {
                c = (uint16_t)(5u << 13 | ((o >> 11) & 1) << 12 | ((o >> 4) & 1) << 11 | ((o >> 8) & 3) << 9 | ((o >> 10) & 1) << 8 |
                               ((o >> 6) & 1) << 7 | ((o >> 7) & 1) << 6 | ((o >> 1) & 7) << 3 | ((o >> 5) & 1) << 2 | 1);
            }
            break;
        }
        case K_RET: case K_IJMP: case K_ICALL: {
            uint32_t rs1 = I.kind == K_RET ? (rng() % 4 ? 1 : 5) : 10 + rnd(3);
            uint32_t rd = I.kind == K_ICALL ? 1 : 0;
            if (I.len == 4) i = rnd(12) << 20 | rs1 << 15 | rd << 7 | 0x67;
            else c = (uint16_t)(4u << 13 | rd << 12 | rs1 << 7 | 2);
            int nt = 1 + (int)(rng() % 3);
            for (int k = 0; k < nt; k++) I.itg.push_back(pick(0, end - 1));
            I.fallback = pick(0, end - 1);
            break;
        }
        }
        if (I.len == 4) { mem[p] = (uint16_t)i; mem[p + 1] = (uint16_t)(i >> 16); } else mem[p] = c;
    }
}

// the true next instruction after the one at parcel p (halfword address), executing it
static uint64_t step(uint64_t pc, bool& taken)
{
    long p = (long)(pc - BASE);
    Ins& I = ins[at[p]];
    uint64_t fall = pc + I.len / 2;
    taken = true;
    switch (I.kind) {
    case K_ALU: taken = false; return fall;
    case K_BR: {
        bool t;
        long n = I.cnt++;
        switch (I.pat) {
        case 0: t = true; break;
        case 1: t = false; break;
        case 2: t = (n % I.per) != I.per - 1; break;
        default: I.lcg = I.lcg * 6364136223846793005ull + 1442695040888963407ull; t = (I.lcg >> 61) & 1; break;
        }
        taken = t;
        return t ? BASE + (uint64_t)I.tgt : fall;
    }
    case K_JAL: return BASE + (uint64_t)I.tgt;
    case K_CALL: stk.push_back(fall); return BASE + (uint64_t)I.tgt;
    case K_RET: {
        if (stk.empty()) return BASE + (uint64_t)I.fallback;
        uint64_t a = stk.back(); stk.pop_back(); return a;
    }
    case K_ICALL: stk.push_back(fall); return BASE + (uint64_t)I.itg[I.ii++ % I.itg.size()];
    default: return BASE + (uint64_t)I.itg[I.ii++ % I.itg.size()];
    }
}

static void line_parcels(uint64_t line, uint16_t p[8])      // line: halfword address / 8
{
    for (int k = 0; k < 8; k++) {
        uint64_t a = line * 8 + (uint64_t)k;
        p[k] = (a >= BASE && a < BASE + MEMP) ? mem[a - BASE] : 0;
    }
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("FETCH_SEED")) rng.seed(strtoull(e, nullptr, 0));
    build();
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    // ---- mirrors of the predictors
    TageRef R;
    struct BtbRow { bool v = false; uint32_t tag = 0; int off = 0; uint64_t tgt = 0; };
    BtbRow btb[256];
    uint64_t ras[16] = {0}; bool ras_known[16] = {false}; int ras_ptr = 0;
    bool m_carry_v = false; uint16_t m_carry = 0;
    struct Fl { uint64_t pc; TageRef::Rd rd; bool bhit; int boff; uint64_t btgt; bool ubt; int uboff; bool bek; };
    // the uBTB (as tb_ubtb's reference) and the fetch address of F0
    struct UE { bool v = false; uint64_t tag = 0; int off = 0; uint64_t tgt = 0; int cnt = 0; bool cond = false, ret = false; };
    const int NUB = 8;                         // uBTB entries
    UE ubt[NUB]; int ub_rr = 0;
    uint64_t m_pc = 0; bool m_pc_known = true;
    auto ubtag = [](uint64_t pc) { uint64_t b = pc >> 3; return (b ^ (b >> 12)) & 0xfff; };
    long novr = 0, novr_drop = 0;
    std::deque<Fl> fl;                         // requests in flight (mirror)

    // ---- the I$
    bool s1_v = false, s1_miss = false; uint64_t s1_pc = 0;
    bool rq_v = false; uint64_t rq_pc = 0;
    int miss_cnt = 0; uint64_t miss_pc = 0;

    // ---- the back end
    struct Blk { uint64_t pc, next; int end; bool taken; Bits m; int rptr; uint64_t rval; int ex = 0, tk = 0; };
    std::deque<Blk> fbuf, ftq;
    uint64_t tp = BASE;                        // the next true instruction
    bool cross_pend = false;
    struct Rec { long when; uint64_t pc; Bits hist; int n, bits; int rptr; uint64_t rval; bool push, pop; uint64_t addr; };
    bool rec_pend = false, stopped = false; Rec rec{};
    std::deque<std::pair<uint64_t, uint64_t>> btq;      // BTB updates to send
    uint64_t e_pc = 0;                         // where the next block must start
    bool started = false;
    long ninsn = 0, nblk = 0, nmisp = 0, nmisp_br = 0, nmisp_ret = 0, nmisp_ind = 0, nresp = 0, ndead = 0, last_progress = 0;
    long ncarry = 0, nslot3 = 0, nras_push = 0, ncommit = 0;

    for (cyc = 0; cyc < 400000; cyc++) {
        // ---------- inputs
        bool redirect = false, stop = false;
        Rec rr{};
        if (cyc == 2) {                         // start the program
            redirect = true; rr.pc = BASE; rr.hist = Bits(TageRef::MW); rr.rptr = 0; rr.rval = 0;
        } else if (rec_pend && stopped) {       // the restore, the cycle after the stop
            redirect = true; rr = rec; rec_pend = false; stopped = false;
        } else if (rec_pend && rec.when <= cyc) {
            stop = true; stopped = true;
        }
        d.be_stop = stop;
        d.be_redirect = redirect; d.be_pc = rr.pc;
        for (int k = 0; k < 3; k++) d.be_hist[k] = redirect ? (uint32_t)rr.hist.get(TageRef::M_HIST + 32 * k, k < 2 ? 32 : 6) : 0;
        d.be_hist_n = rr.n; d.be_hist_bits = rr.bits;
        d.be_ras_ptr = rr.rptr; d.be_ras_val = rr.rval; d.be_ras_push = rr.push; d.be_ras_pop = rr.pop; d.be_ras_addr = rr.addr;
        int nftq = (int)(fbuf.size() + ftq.size());
        int credit = std::max(0, std::min(4 - (int)fbuf.size(), 8 - nftq));
        d.credit = credit;
        bool ic_ready = miss_cnt == 0 && !(s1_v && s1_miss);
        d.ic_req_ready = ic_ready;
        d.ic_resp_valid = rq_v;
        uint16_t rp[8]; line_parcels(rq_pc >> 3, rp);
        for (int k = 0; k < 4; k++) d.ic_resp_data[k] = (uint32_t)rp[2 * k] | ((uint32_t)rp[2 * k + 1] << 16);
        // commit
        bool up = !ftq.empty() && rng() % 3 != 0;
        Blk ub;
        if (up) ub = ftq.front();
        d.up_valid = up; d.up_ex = up ? ub.ex : 0; d.up_tk = up ? ub.tk : 0;
        for (int k = 0; k < 9; k++) d.up_meta[k] = up ? ub.m.w[k] : 0;
        bool bt = !btq.empty();
        std::pair<uint64_t, uint64_t> btu{0, 0};
        if (bt) btu = btq.front();
        d.bt_valid = bt; d.bt_pc = btu.first; d.bt_tgt = btu.second;
        d.eval();

        // ---------- F0: the uBTB's guess for this cycle's address
        uint64_t req_pc = d.ic_req_pc;
        if (!m_pc_known) { m_pc = req_pc; m_pc_known = true; }
        if (req_pc != m_pc) FAIL("fetch address %llx, expected %llx", (unsigned long long)req_pc, (unsigned long long)m_pc);
        int ub_best = 8, ub_bi = -1;
        for (int e = 0; e < NUB; e++)
            if (ubt[e].v && ubt[e].tag == ubtag(m_pc) && ubt[e].off >= (int)(m_pc & 7) && (!ubt[e].cond || ubt[e].cnt >= 2) && ubt[e].off < ub_best) {
                ub_best = ubt[e].off; ub_bi = e;
            }
        bool ub_t = ub_bi >= 0;
        int rtop0 = (ras_ptr + 15) % 16;
        bool ub_next_known = !(ub_t && ubt[ub_bi].ret && !ras_known[rtop0]);
        uint64_t ub_next = ub_t ? (ubt[ub_bi].ret ? ras[rtop0] : ubt[ub_bi].tgt) : (((m_pc >> 3) + 1) << 3) & AM;
        // ---------- the request (mirror reads before this cycle's writes)
        bool acc = d.ic_req_valid && ic_ready;
        if (acc) {
            Fl f{req_pc, R.read(req_pc), false, 0, 0, ub_t, ub_t ? ub_best : 7, redirect};
            BtbRow& b = btb[(req_pc >> 3) & 255];
            f.bhit = b.v && b.tag == (uint32_t)((req_pc >> 11) & 1023); f.boff = b.off; f.btgt = b.tgt;
            fl.push_back(f);
            if (fl.size() > 3) FAIL("%zu requests in flight", fl.size());
        }
        if (d.ic_req_valid && credit <= 0) FAIL("request without credit");
        if (d.ic_req_valid && (stop || redirect)) FAIL("a request in a cycle of %s", stop ? "a stop" : "a redirect");

        // ---------- the block (F2): what the front end must decide
        bool out = d.out_valid;
        int m_hn = 0, m_pred = 0; bool m_push = false, m_pop = false; uint64_t m_addr = 0; bool m_cross = false, m_taken = false; uint16_t m_p7 = 0;
        bool ovr = false, ub_upd = false; uint64_t ub_upc = 0, ub_utgt = 0; bool ub_utk = false, ub_ucond = false, ub_uret = false;
        if (rq_v) {
            if (fl.empty()) { FAIL("answer with nothing in flight"); }
            else {
                Fl f = fl.front();
                nresp++;
                if (out) {
                    if (redirect || stop) FAIL("a block in a cycle of %s", stop ? "a stop" : "a redirect");
                    uint64_t line = f.pc >> 3; int start = (int)(f.pc & 7);
                    if (f.pc != (uint64_t)d.out_pc) FAIL("out_pc %llx, request %llx", (unsigned long long)d.out_pc, (unsigned long long)f.pc);
                    if (started && f.pc != e_pc) FAIL("block at %llx, expected %llx", (unsigned long long)f.pc, (unsigned long long)e_pc);
                    Predec pd = predec_ref(line / 1, start, m_carry_v, m_carry, rp);
                    ncarry += m_carry_v;
                    int sv = 0, par[3] = {0, 0, 0}, slot[8], ns = 0;
                    for (int e = 0; e < 8; e++) {
                        slot[e] = ns;
                        if ((pd.br >> e) & 1 && ns < 3) { sv |= 1 << ns; par[ns] = e; ns++; }
                        else if ((pd.br >> e) & 1) nslot3++;
                    }
                    int basebits; Bits mm;
                    R.f2(f.rd, sv, par, m_pred, basebits, mm);
                    int tk = 0;
                    for (int e = 0; e < 8; e++) {
                        bool t = false;
                        if ((pd.br >> e) & 1) t = slot[e] < 3 && ((m_pred >> slot[e]) & 1);      // a 4th: not taken
                        else if ((pd.jal >> e) & 1) t = true;
                        else if ((pd.jalr >> e) & 1) t = ((pd.ret >> e) & 1) || (f.bhit && f.boff == e);
                        if ((pd.iv >> e) & 1 && t) tk |= 1 << e;
                    }
                    m_taken = tk != 0;
                    int end = m_taken ? __builtin_ctz(tk) : 7;
                    uint64_t nx = ((line + 1) << 3) & AM;
                    int rtop = (ras_ptr + 15) % 16;
                    if (m_taken) nx = ((pd.br | pd.jal) >> end) & 1 ? pd.tgt[end] : ((pd.ret >> end) & 1) ? ras[rtop] : f.btgt;
                    for (int s = 0; s < 3; s++) if ((sv >> s) & 1 && par[s] <= end) m_hn++;
                    m_push = m_taken && ((pd.call >> end) & 1);
                    m_pop = m_taken && ((pd.ret >> end) & 1);
                    m_addr = ((line << 3) | (uint64_t)end) + 1;
                    m_cross = pd.cross; m_p7 = rp[7];
                    if ((int)d.out_end != end) FAIL("block %llx: end %d, expected %d", (unsigned long long)f.pc, (int)d.out_end, end);
                    if ((bool)d.out_taken != m_taken) FAIL("block %llx: taken %d, expected %d", (unsigned long long)f.pc, (int)d.out_taken, m_taken);
                    if (((pd.ret >> end) & 1) && m_taken && !ras_known[rtop]) {}
                    else if ((uint64_t)d.out_next != nx) FAIL("block %llx: next %llx, expected %llx", (unsigned long long)f.pc, (unsigned long long)d.out_next, (unsigned long long)nx);
                    for (int k = 0; k < 9; k++)
                        if (d.out_tmeta[k] != mm.w[k]) { FAIL("block %llx: tmeta word %d %08x, expected %08x", (unsigned long long)f.pc, k, d.out_tmeta[k], mm.w[k]); break; }
                    if ((int)d.out_ras_ptr != ras_ptr) FAIL("ras_ptr %d, expected %d", (int)d.out_ras_ptr, ras_ptr);
                    if (ras_known[ras_ptr] && (uint64_t)d.out_ras_val != ras[ras_ptr]) FAIL("ras_val wrong");
                    // into the buffer, as the core would
                    Blk b;
                    b.pc = f.pc; b.next = d.out_next; b.end = d.out_end; b.taken = d.out_taken;
                    b.m = Bits(TageRef::MW); for (int k = 0; k < 9; k++) b.m.w[k] = d.out_tmeta[k];
                    b.rptr = d.out_ras_ptr; b.rval = d.out_ras_val;
                    fbuf.push_back(b);
                    if (fbuf.size() > 4 || fbuf.size() + ftq.size() > 8) FAIL("credit exceeded");
                    e_pc = b.next;
                    nblk++;
                    // F0 went on with the uBTB's guess: if that is not this block's next, F2
                    // redirects it there and trains the uBTB
                    uint64_t expect_pc = fl.size() >= 2 ? fl[1].pc : m_pc;
                    ovr = (uint64_t)d.out_next != expect_pc;
                    ub_utgt = d.out_next;
                    if (ovr) {
                        novr++;
                        bool hit_first = m_taken && !(f.ubt && f.uboff < end);
                        ub_upd = hit_first || f.ubt;
                        ub_upc = (line << 3) | (uint64_t)(hit_first ? end : f.uboff);
                        ub_utk = hit_first;
                        ub_ucond = (pd.br >> end) & 1; ub_uret = (pd.ret >> end) & 1;
                                    }
                } else { ndead++; if (!f.bek) novr_drop++; }
                fl.pop_front();
            }
        } else if (out) FAIL("a block without an answer");

        // ---------- decode: walk blocks along the true path
        if (!rec_pend && !redirect && started) {
            int take = rng() % 3;
            while (take-- > 0 && !fbuf.empty() && !rec_pend) {
                Blk b = fbuf.front(); fbuf.pop_front();
                uint64_t line = b.pc >> 3;
                uint64_t expect = cross_pend ? tp + 1 : tp;
                if (b.pc != expect) { FAIL("block %llx off the true path (next instruction %llx)", (unsigned long long)b.pc, (unsigned long long)tp); break; }
                int sv = (int)b.m.get(TageRef::M_SV, 3), pr = (int)b.m.get(TageRef::M_PRED, 3);
                int par[3]; for (int s = 0; s < 3; s++) par[s] = (int)b.m.get(TageRef::M_PAR + 3 * s, 3);
                while (true) {
                    long p = (long)(tp - BASE);
                    if (p < 0 || p >= MEMP || at[p] < 0) { FAIL("true path at %llx outside the program", (unsigned long long)tp); break; }
                    Ins& I = ins[at[p]];
                    uint64_t last = tp + I.len / 2 - 1;
                    if ((last >> 3) != line) { cross_pend = true; break; }      // its second half is in the next block
                    int le = (int)(last & 7);
                    if (le > b.end) { FAIL("instruction %llx past the end of block %llx", (unsigned long long)tp, (unsigned long long)b.pc); break; }
                    bool t;
                    uint64_t tn = step(tp, t);
                    ninsn++; last_progress = cyc;
                    uint64_t pn = le == b.end ? b.next : last + 1;
                    int s_i = -1;
                    if (I.kind == K_BR)
                        for (int s = 0; s < 3; s++) if ((sv >> s) & 1 && par[s] == le) { s_i = s; b.ex |= 1 << s; b.tk |= (int)t << s; }
                    if (I.kind == K_IJMP || I.kind == K_ICALL) btq.push_back({last, tn});
                    cross_pend = false;
                    if (tn != pn) {
                        // a misprediction: redirect a few cycles later, putting history and RAS back
                        nmisp++; if (I.kind == K_BR) nmisp_br++; else if (I.kind == K_RET) nmisp_ret++; else nmisp_ind++;
                        rec = Rec{};
                        rec.when = cyc + 1 + (long)(rng() % 5);
                        rec.pc = tn;
                        rec.hist = b.m;
                        int n = 0, bits = 0;
                        for (int s = 0; s < 3; s++) {
                            if (!((sv >> s) & 1)) continue;
                            if (par[s] < le) { bits |= ((pr >> s) & 1) << n; n++; }
                            else if (par[s] == le && s_i == s) { bits |= (int)t << n; n++; }
                        }
                        rec.n = n; rec.bits = bits;
                        rec.rptr = b.rptr; rec.rval = b.rval;
                        rec.push = I.kind == K_CALL || I.kind == K_ICALL;
                        rec.pop = I.kind == K_RET;
                        rec.addr = last + 1;
                        rec_pend = true;
                        tp = tn;
                        break;
                    }
                    tp = tn;
                    if (le == b.end) break;
                }
                ftq.push_back(b);
            }
        }

        // ---------- the clock
        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        // mirrors
        if (redirect || stop) { for (auto& x : fl) x.bek = true; }
        if (redirect || ovr) m_pc = redirect ? rr.pc : ub_utgt;
        else if (acc) { if (ub_next_known) m_pc = ub_next; else m_pc_known = false; }
        if (ub_upd) {
            int fnd = -1;
            for (int e = 0; e < NUB; e++) if (ubt[e].v && ubt[e].tag == ubtag(ub_upc) && ubt[e].off == (int)(ub_upc & 7)) fnd = e;
            if (fnd >= 0) {
                if (ub_utk) { ubt[fnd].tgt = ub_utgt; if (ubt[fnd].cnt < 3) ubt[fnd].cnt++; }
                else if (ubt[fnd].cnt > 0) ubt[fnd].cnt--;
            } else if (ub_utk) {
                ubt[ub_rr] = UE{true, ubtag(ub_upc), (int)(ub_upc & 7), ub_utgt, 2, ub_ucond, ub_uret};
                ub_rr = (ub_rr + 1) % NUB;
            }
        }
        if (up) { R.update(ub.m, ub.ex, ub.tk); ftq.pop_front(); ncommit++; }
        if (redirect) {
            R.restore(rr.hist, rr.n, rr.bits);
            ras[rr.rptr] = rr.push ? rr.addr : rr.rval; ras_known[rr.rptr] = true;
            ras_ptr = (rr.rptr + rr.push - rr.pop + 16) % 16;
            m_carry_v = false;
            fbuf.clear();
            e_pc = rr.pc; started = true;
        } else if (out) {
            R.push(m_hn, m_pred);
            if (m_push) { ras[ras_ptr] = m_addr; ras_known[ras_ptr] = true; ras_ptr = (ras_ptr + 1) % 16; nras_push++; }
            else if (m_pop) ras_ptr = (ras_ptr + 15) % 16;
            m_carry_v = m_cross && !m_taken; m_carry = m_p7;
        }
        if (bt) { BtbRow& w = btb[(btu.first >> 3) & 255]; w.v = true; w.tag = (uint32_t)((btu.first >> 11) & 1023); w.off = (int)(btu.first & 7); w.tgt = btu.second; btq.pop_front(); }
        // the I$
        bool nrq_v = false; uint64_t nrq_pc = 0;
        if (miss_cnt > 0 && --miss_cnt == 0) { nrq_v = true; nrq_pc = miss_pc; }
        if (s1_v && !s1_miss) { nrq_v = true; nrq_pc = s1_pc; }
        if (s1_v && s1_miss) { miss_cnt = 2 + (int)(rng() % 10); miss_pc = s1_pc; }
        rq_v = nrq_v; rq_pc = nrq_pc;
        s1_v = acc; s1_pc = req_pc; s1_miss = acc && rng() % 12 == 0;
        if (cyc - last_progress > 3000 && cyc > 3000) { FAIL("no progress"); break; }
    }
    printf("tb_fetch: %ld cycles, %ld instructions on the true path, %ld blocks, %ld overrides (%ld answers dropped by them, %ld by redirects), %ld mispredicted (branch %ld, return %ld, indirect %ld), %ld committed, %ld carried, %ld 4th branches, %ld mismatches: %s\n",
           cyc, ninsn, nblk, novr, novr_drop, ndead - novr_drop, nmisp, nmisp_br, nmisp_ret, nmisp_ind, ncommit, ncarry, nslot3, bad, bad ? "FAIL" : "PASS");
    (void)nras_push; (void)nresp;
    return bad ? 1 : 0;
}
