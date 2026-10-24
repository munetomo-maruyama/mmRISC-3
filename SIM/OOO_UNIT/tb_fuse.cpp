//---------------------------------------------------------------------------
// tb_fuse.cpp : OOO_FUSE
//
// 1. random: groups of 4 with registers from a small pool (so that pairs
//    happen often), against a reference of the rules of OOO_FUSE.sv (with
//    the second-stage flag, the limit of 2 sources, SRC2, and of 1 write, W1)
// 2. trace (FUSE_TRACE=<file of mkfuse.py>): the CoreMark stream through
//    the window of 4 as the decoder would feed it (the window moves by
//    `consumed`); the pairs formed are counted against the pairs the model
//    forms on the same stream (Plan/MODEL.md 6, fusion 3, fuse_2src, fuse_1w)
//---------------------------------------------------------------------------
#include "VOOO_FUSE.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

struct Ins { int seq, cls, op, rd, rs1, rs2, u1, u2, imm, ms, ok2; };

static VOOO_FUSE d;

static void put(const Ins* g, int nvalid)
{
    d.no_fuse = 0;
    d.valid = 0; d.seq = 0; d.cls = 0; d.op = 0; d.use_rs1 = 0; d.use_rs2 = 0; d.msize = 0; d.alu2ok = 0;
    for (int k = 0; k < 4; k++) {
        const Ins& x = g[k];
        if (k < nvalid) d.valid |= 1u << k;
        d.seq |= (unsigned)x.seq << k;
        d.cls |= (unsigned)x.cls << (3 * k);
        d.op |= (unsigned)x.op << (3 * k);
        d.use_rs1 |= (unsigned)x.u1 << k;
        d.use_rs2 |= (unsigned)x.u2 << k;
        d.msize |= (unsigned)x.ms << (2 * k);
        d.alu2ok |= (unsigned)x.ok2 << k;
    }
    d.rd = 0; d.rs1 = 0; d.rs2 = 0;
    for (int k = 0; k < 4; k++) {
        d.rd  |= (uint32_t)g[k].rd << (5 * k);
        d.rs1 |= (uint32_t)g[k].rs1 << (5 * k);
        d.rs2 |= (uint32_t)g[k].rs2 << (5 * k);
    }
    d.imm = 0;
    for (int k = 0; k < 4; k++) d.imm |= (uint64_t)(g[k].imm & 0xfff) << (12 * k);
    d.eval();
}

// the registers the pair reads from outside (x0 and the second's reads of
// the first's rd not counted), as fuse_2src of Plan/model/ooo.h
static int ref_nsrc(const Ins& a, const Ins& b)
{
    int r[4], n = 0;
    auto add = [&](int use, int x, bool second) {
        if (!use || x == 0 || (second && x == a.rd)) return;
        for (int i = 0; i < n; i++) if (r[i] == x) return;
        r[n++] = x;
    };
    add(a.u1, a.rs1, false); add(a.u2, a.rs2, false); add(b.u1, b.rs1, true); add(b.u2, b.rs2, true);
    return n;
}

// the rules, written again from the comment of OOO_FUSE.sv
static int ref_rule(const Ins& a, const Ins& b);
static int ref_kind(const Ins& a, const Ins& b)
{
    int k = ref_rule(a, b);
    bool two_writes = a.rd != 0 && b.rd != 0 && a.rd != b.rd;
    return (k && (ref_nsrc(a, b) > 2 || two_writes)) ? 0 : k;
}

static int ref_rule(const Ins& a, const Ins& b)
{
    int dd = a.rd;
    bool rdb = dd != 0 && ((b.u1 && b.rs1 == dd) || (b.u2 && b.rs2 == dd));
    int ia = (a.imm & 0x800) ? a.imm - 4096 : a.imm, ib = (b.imm & 0x800) ? b.imm - 4096 : b.imm;
    bool adj = a.ms == b.ms && (ib - ia == (1 << a.ms) || ia - ib == (1 << a.ms));
    if (a.op == 1 && b.op == 6 && dd && b.rs1 == dd) return 1;
    if (a.op == 2 && rdb) return 2;
    if (a.op == 3 && b.op == 4 && dd && b.rs1 == dd) return 3;
    if (a.cls == 0 && b.cls == 4 && dd && b.rs1 == dd) return 4;
    if (a.cls == 4 && b.cls == 4 && a.rs1 == b.rs1 && dd != a.rs1 && adj) return 5;
    if (a.cls == 5 && b.cls == 5 && a.rs1 == b.rs1 && adj) return 6;
    if (a.cls == 0 && b.cls == 1 && rdb) return 7;
    if (a.cls == 0 && b.cls == 0 && rdb && b.ok2) return 8;
    return 0;
}

static int random_test()
{
    std::mt19937 rng(7);
    long bad = 0, n = 0, paired = 0;
    for (long it = 0; it < 1000000; it++) {
        Ins g[4];
        int nv = rng() % 5;
        for (int k = 0; k < 4; k++) {
            Ins& x = g[k];
            x.seq = rng() % 8 != 0;
            x.cls = (int[]){0, 0, 0, 1, 4, 4, 5, 5, 2, 3, 6, 7}[rng() % 12];
            x.op = x.cls == 0 ? rng() % 7 : 0;
            x.rd = (x.cls == 1 || x.cls == 5) ? 0 : rng() % 6;
            x.rs1 = rng() % 6; x.rs2 = rng() % 6;
            x.u1 = rng() % 4 != 0; x.u2 = rng() & 1;
            x.imm = ((rng() % 5) * 4 + (rng() % 3 == 0 ? 0xff0 : 0)) & 0xfff;
            x.ms = rng() % 4;
            x.ok2 = rng() % 4 != 0;
        }
        put(g, nv);
        // the reference: greedy from slot 0
        int pk[3];
        for (int k = 0; k < 3; k++) pk[k] = (k + 1 < nv && g[k + 1].seq) ? ref_kind(g[k], g[k + 1]) : 0;
        int u0v = nv > 0, u0k = pk[0];
        int s1 = u0k ? 2 : 1;
        int u1v = nv > 0 && s1 < 4 && s1 < nv;
        int u1k = s1 < 3 ? pk[s1] : 0;
        if (!u1v) u1k = u1k;    // the RTL reports the kind regardless of validity; compared only when valid
        int cons = !u0v ? 0 : !u1v ? s1 : s1 + (u1k ? 2 : 1);
        n++;
        bool ok = d.u0_valid == u0v && d.consumed == cons;
        if (u0v) ok = ok && d.u0_slot == 0 && d.u0_kind == u0k;
        if (u1v) ok = ok && d.u1_valid && d.u1_slot == s1 && d.u1_kind == u1k;
        else ok = ok && !d.u1_valid;
        if (u0v && u0k) paired++;
        if (!ok && bad++ < 10)
            printf("MISMATCH nv %d: rtl u0 %d/%d u1 %d/%d/%d cons %d, ref u0 %d/%d u1 %d/%d/%d cons %d\n", nv,
                   d.u0_valid, d.u0_kind, d.u1_valid, d.u1_slot, d.u1_kind, d.consumed, u0v, u0k, u1v, s1, u1k, cons);
    }
    printf("tb_fuse random: %ld groups (%ld with a pair in slot 0), %ld mismatches: %s\n", n, paired, bad,
           bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}

static int trace_test(const char* path)
{
    FILE* f = fopen(path, "r");
    if (!f) { printf("tb_fuse trace: cannot open %s: FAIL\n", path); return 1; }
    long n, model_pairs;
    if (fscanf(f, "%ld %ld", &n, &model_pairs) != 2) return 1;
    std::vector<Ins> t(n + 4);
    for (long i = 0; i < n; i++) {
        Ins& x = t[i];
        if (fscanf(f, "%d %d %d %d %d %d %d %d %d %d", &x.seq, &x.cls, &x.op, &x.rd, &x.rs1, &x.rs2, &x.u1, &x.u2,
                   &x.imm, &x.ms) != 10 || fscanf(f, "%d", &x.ok2) != 1) return 1;
    }
    fclose(f);
    long p = 0, pairs = 0, cycles = 0;
    while (p < n) {
        int nv = (int)std::min<long>(4, n - p);
        put(&t[p], nv);
        if (d.u0_kind && d.u0_valid) pairs++;
        if (d.u1_kind && d.u1_valid) pairs++;
        if (d.consumed == 0) { printf("tb_fuse trace: no progress at %ld: FAIL\n", p); return 1; }
        p += d.consumed;
        cycles++;
    }
    printf("tb_fuse trace: %ld instructions in %ld groups, pairs RTL %ld, model %ld (%.1f %%), µops per instruction %.3f\n",
           n, cycles, pairs, model_pairs, 100.0 * pairs / model_pairs, (double)(n - pairs) / n);
    return 0;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    int r = random_test();
    const char* tf = getenv("FUSE_TRACE");
    if (tf) r |= trace_test(tf);
    return r;
}
