//---------------------------------------------------------------------------
// tb_pmp.cpp : OOO_PMP (step 1.8 P1, Plan/OOC.md 29.89) against the privileged
// specification's rule, written plainly
//
// 8 entries drawn at random (OFF, TOR, NA4, NAPOT; R, W, X, L), their addresses near
// a few places so that regions touch, overlap and nest, now and then with bits above
// the 40-bit address space (as large as pmpaddr's 54 bits allow), now and then all
// ones (NAPOT: everything); accesses near those places, every size, privilege and
// kind. The reference: the lowest entry that matches any byte of the block decides;
// all of the block's bytes must match it, and it must allow the access (machine mode:
// only when locked); no match, machine mode only. A block of up to 8 bytes is checked
// byte by byte (every word of it is one of its two ends, so the rule is exact); the
// fetch's block of 32 (LB 3: built as pmp32) by its first and its last word, as the
// design checks it as one block; and each word of the frame alone (fail_w: the fetch's, Plan/OOC.md
// 29.89) as a 4-byte access.
//---------------------------------------------------------------------------
#include "VOOO_PMP.h"
#include <cstdint>
#include <cstdio>
#include <random>
#include <vector>

#ifndef PMP_LB
#define PMP_LB 1
#endif
static const int LB = PMP_LB, N = 8;
static std::mt19937_64 rng(PMP_LB * 7 + 3);
static VOOO_PMP d;

struct Ent { uint8_t cfg; uint64_t a; };
static Ent e[N];

static uint64_t nmask(uint64_t a) { return a ^ (a + 1); }          // (54 bits: the CSR's)
static bool hit(int i, uint64_t w)                                  // entry i matches word w
{
    int mode = (e[i].cfg >> 3) & 3;
    uint64_t a = e[i].a;
    if (mode == 1) { uint64_t lo = i ? e[i - 1].a : 0; return lo <= w && w < a; }
    if (mode == 2) return w == a;
    if (mode == 3) { uint64_t m = nmask(a) & ((1ull << 54) - 1); return ((w ^ a) & ~m & ((1ull << 54) - 1)) == 0; }
    return false;
}
static bool ref_fail(uint64_t pa, int size, int priv, bool r, bool w, bool x)
{
    uint64_t n = 1ull << size, base = pa & ~(n - 1);
    std::vector<uint64_t> words;
    if (n <= 8) for (uint64_t b = base; b < base + n; b += 4) { uint64_t wd = b >> 2; if (words.empty() || words.back() != wd) words.push_back(wd); }
    else { words.push_back(base >> 2); words.push_back((base + n - 1) >> 2); }
    for (int i = 0; i < N; i++) {
        bool any = false, all = true;
        for (uint64_t wd : words) { bool h = hit(i, wd); any |= h; all &= h; }
        if (!any) continue;
        if (!all) return true;
        uint8_t c = e[i].cfg;
        if (priv == 3 && !(c & 0x80)) return false;
        return (r && !(c & 1)) || (w && !(c & 2)) || (x && !(c & 4));
    }
    return priv != 3;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    long nw = 0, nwf = 0;
    long bad = 0, n = 0, nfail = 0, nmode[4] = {0}, npart = 0, nbig = 0;
    const uint64_t place[4] = {0x80000000ull >> 2, 0x80001000ull >> 2, 0x2000000ull >> 2, (1ull << 40) - 0x1000};
    auto near = [&](uint64_t w) { return w + (int64_t)(rng() % 64) - 32; };
    for (int round = 0; round < 20000; round++) {
        // the entries
        for (int i = 0; i < N; i++) {
            int mode = (int)(rng() % 4);
            uint64_t a = near(place[rng() % 4] >> (rng() % 4 == 3 ? 0 : 0));
            if (mode == 3) { int k = (int)(rng() % 10); a = (a & ~((1ull << k) - 1)) | ((1ull << k) - 1) >> 1; }   // a NAPOT of 2^(k+2) bytes
            if (rng() % 20 == 0) { a |= 1ull << (38 + rng() % 16); nbig++; }                // beyond the address space
            if (rng() % 40 == 0) a = (1ull << 54) - 1;                                       // all ones
            a &= (1ull << 54) - 1;
            e[i].a = a;
            e[i].cfg = (uint8_t)((mode << 3) | (rng() % 8) | (rng() % 4 == 0 ? 0x80 : 0));
            if (i > 0 && mode == 1 && rng() % 2) e[i].a = (e[i - 1].a + rng() % 16) & ((1ull << 54) - 1);   // TOR just above the last
            nmode[mode]++;
        }
        for (int i = 0; i < N; i++) {
            d.cfg = (d.cfg & ~(0xffull << (8 * i))) | ((uint64_t)e[i].cfg << (8 * i));
            uint64_t m = nmask(e[i].a) & ((1ull << 54) - 1);
            d.addr[2 * i] = (uint32_t)e[i].a; d.addr[2 * i + 1] = (uint32_t)(e[i].a >> 32);
            d.mask[2 * i] = (uint32_t)m;      d.mask[2 * i + 1] = (uint32_t)(m >> 32);
        }
        // accesses near each entry's bounds and the places
        for (int k = 0; k < 32; k++) {
            uint64_t w = rng() % 2 ? near(place[rng() % 4]) : near(e[rng() % N].a);
            uint64_t pa = ((w << 2) | (rng() & 3)) & ((1ull << 40) - 1);
            int size = LB == 3 ? (rng() % 2 ? 5 : 3) : (int)(rng() % 4);
            int priv = (int)(rng() % 4); if (priv == 2) priv = 3;
            int kind = (int)(rng() % 4);
            bool r = kind == 0 || kind == 3, wr = kind == 1 || kind == 3, x = kind == 2;
            d.paddr = pa; d.size = size; d.priv = priv; d.is_read = r; d.is_write = wr; d.is_exec = x;
            d.eval();
            bool exp = ref_fail(pa, size, priv, r, wr, x);
            n++; if (exp) nfail++;
            {   // (a block that ends in two places: counted)
                uint64_t nb = 1ull << size, b = pa & ~(nb - 1);
                for (int i = 0; i < N; i++) if (hit(i, b >> 2) != hit(i, (b + nb - 1) >> 2)) { npart++; break; }
            }
            {   // each word of the frame alone
                uint64_t fb = pa & ~((4ull << LB) - 1);
                for (int k = 0; k < (1 << LB); k++) {
                    bool ew = ref_fail(fb + 4 * k, 2, priv, r, wr, x);
                    nw++; if (ew) nwf++;
                    if ((bool)((d.fail_w >> k) & 1) != ew && bad++ < 10)
                        printf("mismatch: word %d of the frame at %010llx priv %d r%d w%d x%d: got %d, expected %d\n", k, (unsigned long long)fb, priv, r, wr, x, (int)((d.fail_w >> k) & 1), ew);
                }
            }
            if ((bool)d.fail != exp) {
                if (bad++ < 10) {
                    printf("mismatch: pa %010llx size %d priv %d r%d w%d x%d: got %d, expected %d\n", (unsigned long long)pa, size, priv, r, wr, x, d.fail, exp);
                    for (int i = 0; i < N; i++) printf("   entry %d: cfg %02x addr %014llx\n", i, e[i].cfg, (unsigned long long)e[i].a);
                }
            }
        }
    }
    printf("tb_pmp (LB %d): %ld words alone (%ld denied); %ld accesses (%ld denied, %ld with a block's ends in different entries), entries OFF %ld TOR %ld NA4 %ld NAPOT %ld (beyond 40 bits %ld), %ld mismatches: ",
           LB, nw, nwf, n, nfail, npart, nmode[0], nmode[1], nmode[2], nmode[3], nbig, bad);
    bool ok = bad == 0 && nfail > 50000 && n - nfail > 50000 && npart > (LB == 3 ? 5000 : 2000);
    printf("%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
