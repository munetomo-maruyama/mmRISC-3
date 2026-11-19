//---------------------------------------------------------------------------
// tb_ptw.cpp : OOO_PTW, the Sv39 walker (step 1.8 V1, Plan/OOC.md 29.87), against a
// reference walk with Spike's rules (riscv/mmu.cc walk(), Svade, no Svnapot, no Svpbmt).
//
// The page tables are made as they are read: an entry not read before is drawn once
// (a pointer to one of 16 table pages, now and then with D, A or U, outside the
// cacheable memory, or beyond 40 bits; a leaf with random U, R, W, X, A, D, its page
// aligned to a superpage or not, now and then beyond 40 bits; an invalid entry; W
// without R; a reserved bit), and kept. The pages asked for are 64, sharing their
// upper parts, so walks meet the same tables at each level, and the root changes now
// and then (as a write of satp: with cancel), the tables drawn again then (as an OS
// rewrites them before SFENCE.VMA).
//
// Around the walker: asks at random (one taken only when it is idle: else dropped, as
// OOO_LSU4's is), entries answered 1 to 20 cycles after they are asked (one at a time),
// cancel now and then (in any state; a read still out is answered later all the same),
// hold (the miss handler's fill_done) now and then.
// Checks: each entry's address is the reference walk's next; no second read while one
// is out; the answer (tlb_done with tlb_we) for a walk taken and not aborted only, never
// with hold, with its id, its page, its physical page, U R W X AF as the reference says;
// none after a cancel; every walk taken ends. Since step 1.8 P1 (Plan/OOC.md 29.89) a PMP denies
// the entries of one table page (TPOOL + 7): pmp_fail answers in the cycle of pt_chk, and the walk
// ends with an access fault there.
//---------------------------------------------------------------------------
#include "VOOO_PTW.h"
#include <cstdint>
#include <cstdio>
#include <map>
#include <random>
#include <vector>

static std::mt19937_64 rng(83);
static VOOO_PTW d;
static const uint64_t CBASE = 0x80000000ull, CTOP = 0x100000000ull;

static std::map<uint64_t, uint64_t> mem;      // the entries drawn, by physical address
static const uint64_t TPOOL = 0x80100;        // the table pages: TPOOL .. TPOOL + 15

enum { PTE_V = 1, PTE_R = 2, PTE_W = 4, PTE_X = 8, PTE_U = 16, PTE_G = 32, PTE_A = 64, PTE_D = 128 };
static long n_draw[8];

static uint64_t draw()
{
    int r = (int)(rng() % 100);
    uint64_t ppn, pte;
    if (r < 50) {                                                    // a pointer
        ppn = TPOOL + rng() % 16;
        if (rng() % 30 == 0) ppn = 0x40000 + rng() % 16;             // outside the cacheable memory
        if (rng() % 40 == 0) ppn |= 1ull << (30 + rng() % 14);       // beyond 40 bits
        pte = (ppn << 10) | PTE_V;
        if (rng() % 20 == 0) pte |= (rng() % 3 == 0) ? PTE_D : (rng() % 2) ? PTE_A : PTE_U;
        n_draw[0]++;
    } else if (r < 90) {                                             // a leaf
        ppn = rng() & ((1ull << 28) - 1);
        int al = (int)(rng() % 3);
        if (al == 0) ppn &= ~((1ull << 18) - 1); else if (al == 1) ppn &= ~((1ull << 9) - 1);
        if (rng() % 30 == 0) ppn |= 1ull << (28 + rng() % 16);       // beyond 40 bits
        int rwx = 1 + (int)(rng() % 7);                              // R or X (W alone left out here)
        if (!(rwx & 1) && !(rwx & 4)) rwx |= 1;
        if ((rwx & 2) && !(rwx & 1)) rwx |= 1;                       // W with R
        pte = (ppn << 10) | PTE_V | (uint64_t)(rwx << 1);
        if (rng() % 2) pte |= PTE_U;
        if (rng() % 2) pte |= PTE_G;
        if (rng() % 10) pte |= PTE_A;
        if (rng() % 2) pte |= PTE_D;
        pte |= (uint64_t)(rng() % 4) << 8;                           // RSW
        n_draw[1]++;
    } else if (r < 95) { pte = rng() & ~(uint64_t)PTE_V & ((1ull << 54) - 1); n_draw[2]++; }    // not valid
    else if (r < 98) { pte = ((rng() & ((1ull << 28) - 1)) << 10) | PTE_V | PTE_R | PTE_A | (1ull << (54 + rng() % 10)); n_draw[3]++; }  // a reserved bit
    else {                                                           // W without R: as a leaf (X), or bare (as a pointer)
        pte = ((rng() & ((1ull << 28) - 1)) << 10) | PTE_V | PTE_W;
        if (rng() % 2) pte |= PTE_X | PTE_A | PTE_D;
        n_draw[4]++;
    }
    return pte;
}
static bool pmp_deny(uint64_t a) { return (a >> 12) == TPOOL + 7; }      // (step 1.8 P1)
static uint64_t rd(uint64_t a)
{
    auto it = mem.find(a);
    if (it != mem.end()) return it->second;
    return mem[a] = draw();
}

struct Res { std::vector<uint64_t> reads; bool u = 0, r = 0, w = 0, x = 0, af = 0; uint64_t ptag = 0; int kind = 0, lvl = 0; };
// kind: 0 a leaf, 1 a page fault, 2 an access fault
static Res walk(uint64_t root, uint64_t vpn)
{
    Res s;
    uint64_t table = root;
    for (int lvl = 2; lvl >= 0; lvl--) {
        uint64_t a = (table << 12) | (((vpn >> (9 * lvl)) & 511) << 3);
        if ((a >> 40) != 0 || a < CBASE || a >= CTOP || pmp_deny(a)) { s.kind = 2; s.af = 1; return s; }
        s.reads.push_back(a);
        uint64_t pte = rd(a), ppn = (pte >> 10) & ((1ull << 44) - 1);
        bool v = pte & PTE_V, r = pte & PTE_R, w = pte & PTE_W, x = pte & PTE_X;
        if (!v || (w && !r) || (pte >> 54)) { s.kind = 1; return s; }
        if (!r && !x) {
            if (pte & (PTE_D | PTE_A | PTE_U)) { s.kind = 1; return s; }
            if (lvl == 0) { s.kind = 1; return s; }
            table = ppn;
            continue;
        }
        if (lvl > 0 && (ppn & ((1ull << (9 * lvl)) - 1))) { s.kind = 1; return s; }
        if (!(pte & PTE_A)) { s.kind = 1; return s; }
        if (ppn >> 28) { s.kind = 2; s.af = 1; return s; }
        uint64_t mask = (1ull << (9 * lvl)) - 1;
        s.ptag = ((ppn & ~mask) | (vpn & mask)) & ((1ull << 28) - 1);
        s.u = pte & PTE_U; s.r = r; s.w = w && (pte & PTE_D); s.x = x; s.lvl = lvl;
        return s;
    }
    return s;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    std::vector<uint64_t> vpns;
    for (int i = 0; i < 64; i++) {
        uint64_t hi = rng() % 4, mid = rng() % 8, lo = rng() & 511;
        vpns.push_back((hi << 18) | (mid << 9) | lo);
    }
    std::vector<uint64_t> roots = {TPOOL, TPOOL + 5, TPOOL + 11, 0x40010, 1ull << 33};    // (two that fault at once)
    uint64_t root = roots[0];
    d.clk = 0; d.rst_n = 1; d.req = 0; d.cancel = 0; d.pt_done = 0; d.hold = 0; d.satp_ppn = root; d.pmp_fail = 0;
    d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    long bad = 0, cyc = 0;
    auto err = [&](const char* m) { if (bad++ < 12) printf("cycle %ld: %s\n", cyc, m); };
    bool on = false;                 // a walk taken, not ended
    Res ex; int ex_id = 0; uint64_t ex_vpn = 0; size_t nread = 0;
    bool out = false; long out_at = 0; uint64_t out_a = 0;    // an entry asked for, not answered
    long n_walk = 0, n_kind[3] = {0, 0, 0}, n_lvl[3] = {0, 0, 0}, n_abort = 0, n_abw = 0, n_abd = 0, n_hold = 0, n_drop = 0, n_root = 0;
    long last_end = 0, n_pmp = 0;
    const long N = 400000;
    for (cyc = 0; cyc < N + 200; cyc++) {
        bool tail = cyc >= N;
        // ---- the inputs
        d.req = 0; d.cancel = 0; d.pt_done = 0; d.hold = 0;
        int c_id = 0; uint64_t c_vpn = 0;
        if (!tail && rng() % 4 == 0) {
            d.req = 1; c_id = (int)(rng() % 32); d.req_id = c_id;
            c_vpn = vpns[rng() % vpns.size()]; d.req_vpn = c_vpn;
        } else { d.req_id = rng() % 32; d.req_vpn = rng() & ((1ull << 27) - 1); }
        if (!tail && rng() % 300 == 0) {
            d.cancel = 1;
            if (rng() % 2 == 0) {                   // a write of satp: new tables (now and then a root that faults)
                root = rng() % 10 ? roots[rng() % 3] : roots[3 + rng() % 2]; n_root++;
                mem.clear();
            }
        }
        d.satp_ppn = root;
        if (rng() % 4 == 0) d.hold = 1;
        if (out && cyc >= out_at) { d.pt_done = 1; d.pt_data = rd(out_a); }
        else d.pt_data = rng();
        bool idle = !d.busy;
        d.pmp_fail = 0;
        d.eval();
        // PMP answers the entry's address shown now (from registers: no loop)
        if (d.pt_chk && pmp_deny((uint64_t)d.pt_addr << 3)) { d.pmp_fail = 1; d.eval(); n_pmp++; }

        // ---- what the walker does
        if (d.pt_req) {
            uint64_t a = (uint64_t)d.pt_addr << 3;
            if (out && !d.pt_done) err("a second entry asked for while one is out");
            if (!on) err("an entry asked for with no walk on");
            else if (nread >= ex.reads.size() || ex.reads[nread] != a) {
                err("an entry's address");
                printf("  %llx, expected %llx (read %zu of %zu)\n", (unsigned long long)a, nread < ex.reads.size() ? (unsigned long long)ex.reads[nread] : 0ull, nread, ex.reads.size());
            }
            nread++;
        }
        if (d.tlb_done) {
            if (!d.tlb_we) err("an answer without its write");
            if (d.hold) err("an answer with hold");
            if (!on) err("an answer with no walk on (or after a cancel)");
            else {
                if (nread != ex.reads.size()) err("an answer before the walk's last entry");
                if ((int)d.done_id != ex_id) err("the answer's id");
                if ((uint64_t)d.tlb_vpn != ex_vpn) err("the answer's page");
                if ((bool)d.tlb_af != ex.af || (bool)d.tlb_u != ex.u || (bool)d.tlb_r != ex.r || (bool)d.tlb_w != ex.w || (bool)d.tlb_x != ex.x ||
                    (ex.kind == 0 && (uint64_t)d.tlb_ptag != ex.ptag)) {
                    err("the answer's entry");
                    printf("  vpn %llx kind %d: ptag %llx u%d r%d w%d x%d af%d, expected ptag %llx u%d r%d w%d x%d af%d\n", (unsigned long long)ex_vpn, ex.kind,
                           (unsigned long long)d.tlb_ptag, d.tlb_u, d.tlb_r, d.tlb_w, d.tlb_x, d.tlb_af, (unsigned long long)ex.ptag, ex.u, ex.r, ex.w, ex.x, ex.af);
                }
                n_kind[ex.kind]++; if (ex.kind == 0) n_lvl[ex.lvl]++;
                on = false; last_end = cyc;
            }
        }
        if (d.hold && on && nread == ex.reads.size() && !out) n_hold++;
        // the edge's effects, as the walker takes them
        if (d.cancel && on) {
            n_abort++;
            if (out) n_abw++; else if (nread == ex.reads.size()) n_abd++;
            on = false; last_end = cyc;
        }
        if (d.req && !d.cancel && idle) {
            if (on) err("a walk taken while one is on");
            on = true; nread = 0; ex_id = c_id; ex_vpn = c_vpn; ex = walk(root, ex_vpn); n_walk++;
        } else if (d.req && !idle) n_drop++;
        if (d.pt_done) out = false;
        if (d.pt_req) { out = true; out_a = (uint64_t)d.pt_addr << 3; out_at = cyc + 1 + (long)(rng() % 20); }

        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if (on && cyc - last_end > 2000) { err("a walk does not end"); on = false; }
    }
    if (on) err("the last walk not ended");
    printf("tb_ptw: %ld walks (%ld asks dropped, busy): leaves %ld (4 KB %ld, 2 MB %ld, 1 GB %ld), page faults %ld, access faults %ld; aborts %ld (an entry out %ld, at the answer %ld), "
           "roots changed %ld, answers held %ld cycles, PMP denials %ld; entries drawn: pointers %ld, leaves %ld, not valid %ld, reserved %ld, W without R %ld; %ld mismatches: ",
           n_walk, n_drop, n_kind[0], n_lvl[0], n_lvl[1], n_lvl[2], n_kind[1], n_kind[2], n_abort, n_abw, n_abd, n_root, n_hold, n_pmp,
           n_draw[0], n_draw[1], n_draw[2], n_draw[3], n_draw[4], bad);
    bool ok = bad == 0 && n_lvl[0] > 500 && n_lvl[1] > 200 && n_lvl[2] > 100 && n_kind[1] > 1000 && n_kind[2] > 200 && n_abw > 50 && n_abd > 20 && n_hold > 500 && n_root > 30 && n_pmp > 200;
    printf("%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
