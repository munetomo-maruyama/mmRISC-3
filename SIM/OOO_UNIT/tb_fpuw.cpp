//---------------------------------------------------------------------------
// tb_fpuw.cpp : OOO_FPUW (the renamed FPU around FPU_PIPE, step 1.8 U1) with
// the bench as OOO_FIQ, the FP file, the load ports, OOO_IQ3's port 0 and the
// integer write slot, against values computed on the host (IEEE arithmetic in
// the same rounding modes, the flags from <cfenv>)
//
// Every cycle the bench may issue one µop to port A (when fpu_ok; an FP ->
// integer one when f2i_ok), reading tags that may be used by then: a result is
// usable from the cycle after its wakeup (wk_*), a load's value from the cycle
// before the load port writes it (S1 meets the write through the bypass). It
// often issues exactly then, so that S2's bypass (offer + 9 = the producer's
// answer), S1's (one cycle later) and the file are all used. It may send an
// int -> FP µop when x_ready, schedule FP loads, kill a checkpoint, clear one,
// flush, and take an integer result when iw_valid (iw_ack, not always).
// What must hold:
//   - every µop not killed gives its result once: an FP one on fw_* (tag, value,
//     ROB index, flags), an integer one on iw_* in FPU order; none of a killed one
//   - the latency: issue + 11 for port A (divide / square root at least that),
//     an int -> FP µop at least 10 after it is sent
//   - the wakeup: for each FP result its tag at the answer - 3, a divide's or a
//     square root's at its answer; no other, none of a µop dead at that cycle
//   - the values: add, sub, mul, the FMAs, divide, square root, sign injection,
//     min / max, compares, fmv.x.*, fcvt.w / l from FP, fcvt.s / d from w / l,
//     fmv.*.x, single and double, rounding modes 0 to 3 and dynamic (frm)
// Masks are the core's: a µop carries its producers' open bits and some of its
// own; a kill takes all that carry the bit (their tags back unwritten).
//---------------------------------------------------------------------------
#include "VOOO_FPUW.h"
#include <algorithm>
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <random>
#include <vector>

static VOOO_FPUW d;
static std::mt19937_64 rng(41);
static long bad = 0;
#define FAIL(...) do { if (bad++ < 12) { printf(__VA_ARGS__); printf("\n"); } } while (0)

enum { ADD = 0, SUB, MUL, DIV, SQRT, MADD, MSUB, NMSUB, NMADD, SGNJ, SGNJN, SGNJX, MIN, MAX, EQ, LT, LE, CLASS,
       MVXF, MVFX, CVTSD, CVTDS, CVTFI, CVTIF };
static const long INF = 1L << 60;
// the configuration (run.sh: fpuw at 6-bit tags, 64 registers; fpuw80 the core's, 7-bit and 80, step 1.8 U2b)
#ifndef FW_TW
#define FW_TW 6
#endif
#ifndef FW_NR
#define FW_NR 64
#endif
#define FW_TM ((1 << FW_TW) - 1)
static const uint64_t QN64 = 0x7ff8000000000000ull, QN32 = 0xffffffff7fc00000ull;

// ---------------------------------------------------------------- the reference
static int host_rm(int rm) { return rm == 0 ? FE_TONEAREST : rm == 1 ? FE_TOWARDZERO : rm == 2 ? FE_DOWNWARD : FE_UPWARD; }
static int flags_now()
{
    int f = 0;
    if (fetestexcept(FE_INVALID))   f |= 16;
    if (fetestexcept(FE_DIVBYZERO)) f |= 8;
    if (fetestexcept(FE_OVERFLOW))  f |= 4;
    if (fetestexcept(FE_UNDERFLOW)) f |= 2;
    if (fetestexcept(FE_INEXACT))   f |= 1;
    return f;
}
static double D(uint64_t x) { double v; memcpy(&v, &x, 8); return v; }
static uint64_t Dbits(double v) { uint64_t x; memcpy(&x, &v, 8); return x; }
static float F(uint32_t x) { float v; memcpy(&v, &x, 4); return v; }
static uint32_t Fbits(float v) { uint32_t x; memcpy(&x, &v, 4); return x; }
static uint32_t unbox(uint64_t x) { return (x >> 32) == 0xffffffffu ? (uint32_t)x : 0x7fc00000u; }
static uint64_t box(uint32_t x) { return 0xffffffff00000000ull | x; }

struct Res { uint64_t v; int fl; };
// NaNs by their bits (a compare of a signalling NaN on the host raises its invalid flag)
static bool nan64(uint64_t x) { return ((x >> 52) & 0x7ff) == 0x7ff && (x & 0xfffffffffffffull); }
static bool snan64(uint64_t x) { return nan64(x) && !((x >> 51) & 1); }
static bool nan32(uint32_t x) { return ((x >> 23) & 0xff) == 0xff && (x & 0x7fffff); }
static bool snan32(uint32_t x) { return nan32(x) && !((x >> 22) & 1); }

static Res ref(int op, int fmt, int rm, int isg, int iw, uint64_t a, uint64_t b, uint64_t c)
{
    Res r{0, 0};
    fesetround(host_rm(rm));
    if (fmt) {
        volatile double x = D(a), y = D(b), z = D(c), o = 0;
        bool na = nan64(a), nb = nan64(b), nan_any = na || nb, sn_any = snan64(a) || snan64(b);
        feclearexcept(FE_ALL_EXCEPT);
        switch (op) {
        case ADD: o = x + y; break;
        case SUB: o = x - y; break;
        case MUL: o = x * y; break;
        case DIV: o = x / y; break;
        case SQRT: o = std::sqrt(x); break;
        case MADD: o = std::fma(x, y, z); break;
        case MSUB: o = std::fma(x, y, -z); break;
        case NMSUB: o = std::fma(-x, y, z); break;
        case NMADD: o = std::fma(-x, y, -z); break;
        default: break;
        }
        if (op <= NMADD) { r.fl = flags_now(); uint64_t ob = Dbits(o); r.v = nan64(ob) ? QN64 : ob; }
        else if (op == SGNJ || op == SGNJN || op == SGNJX) {
            uint64_t s = op == SGNJ ? (b >> 63) : op == SGNJN ? !(b >> 63) : ((a ^ b) >> 63);
            r.v = (a & ~(1ull << 63)) | (s << 63);
        } else if (op == MIN || op == MAX) {
            r.fl = sn_any ? 16 : 0;
            if (na && nb) r.v = QN64;
            else if (na) r.v = b;
            else if (nb) r.v = a;
            else if (x == 0 && y == 0) r.v = op == MIN ? (a | b) : (a & b);   // (-0 below +0)
            else r.v = (op == MIN) == (x < y) ? a : b;
        } else if (op == EQ || op == LT || op == LE) {
            if (nan_any) { r.v = 0; r.fl = op == EQ ? (sn_any ? 16 : 0) : 16; }
            else r.v = op == EQ ? x == y : op == LT ? x < y : x <= y;
        } else if (op == MVXF) r.v = a;
        else if (op == MVFX) r.v = a;
        else if (op == CVTFI) {
            volatile double o2;
            feclearexcept(FE_ALL_EXCEPT);
            if (iw) o2 = (double)(int64_t)a; else o2 = (double)(int32_t)a;
            r.v = Dbits(o2); r.fl = flags_now();
        } else if (op == CVTIF) {
            double t = na ? 0 : std::nearbyint(x);
            feclearexcept(FE_ALL_EXCEPT);
            double lo = iw ? -9223372036854775808.0 : -2147483648.0, hi = iw ? 9223372036854775807.0 : 2147483647.0;
            if (na || t > hi) { r.v = iw ? 0x7fffffffffffffffull : 0x7fffffffull; r.fl = 16; }
            else if (t < lo) { r.v = iw ? 0x8000000000000000ull : 0xffffffff80000000ull; r.fl = 16; }
            else { r.v = iw ? (uint64_t)(int64_t)t : (uint64_t)(int64_t)(int32_t)t; r.fl = t != x ? 1 : 0; }
        }
    } else {
        volatile float x = F(unbox(a)), y = F(unbox(b)), z = F(unbox(c)), o = 0;
        bool na = nan32(unbox(a)), nb = nan32(unbox(b)), nan_any = na || nb, sn_any = snan32(unbox(a)) || snan32(unbox(b));
        feclearexcept(FE_ALL_EXCEPT);
        switch (op) {
        case ADD: o = x + y; break;
        case SUB: o = x - y; break;
        case MUL: o = x * y; break;
        case DIV: o = x / y; break;
        case SQRT: o = std::sqrt((float)x); break;
        case MADD: o = std::fmaf(x, y, z); break;
        case MSUB: o = std::fmaf(x, y, -z); break;
        case NMSUB: o = std::fmaf(-x, y, z); break;
        case NMADD: o = std::fmaf(-x, y, -z); break;
        default: break;
        }
        uint32_t ua = unbox(a), ub = unbox(b);
        if (op <= NMADD) { r.fl = flags_now(); uint32_t ob = Fbits(o); r.v = nan32(ob) ? QN32 : box(ob); }
        else if (op == SGNJ || op == SGNJN || op == SGNJX) {
            uint32_t s = op == SGNJ ? (ub >> 31) : op == SGNJN ? !(ub >> 31) : ((ua ^ ub) >> 31);
            r.v = box((ua & 0x7fffffffu) | (s << 31));
        } else if (op == MIN || op == MAX) {
            r.fl = sn_any ? 16 : 0;
            if (na && nb) r.v = QN32;
            else if (na) r.v = box(ub);
            else if (nb) r.v = box(ua);
            else if (x == 0 && y == 0) r.v = box(op == MIN ? (ua | ub) : (ua & ub));
            else r.v = box((op == MIN) == (x < y) ? ua : ub);
        } else if (op == EQ || op == LT || op == LE) {
            if (nan_any) { r.v = 0; r.fl = op == EQ ? (sn_any ? 16 : 0) : 16; }
            else r.v = op == EQ ? x == y : op == LT ? x < y : x <= y;
        } else if (op == MVXF) r.v = (uint64_t)(int64_t)(int32_t)(uint32_t)a;
        else if (op == MVFX) r.v = box((uint32_t)a);
        else if (op == CVTFI) {
            volatile float o2;
            feclearexcept(FE_ALL_EXCEPT);
            if (iw) o2 = (float)(int64_t)a; else o2 = (float)(int32_t)a;
            r.v = box(Fbits(o2)); r.fl = flags_now();
        } else if (op == CVTIF) {
            float t = na ? 0 : std::nearbyint((float)x);
            feclearexcept(FE_ALL_EXCEPT);
            double lo = iw ? -9223372036854775808.0 : -2147483648.0, hi = iw ? 9223372036854775807.0 : 2147483647.0;
            if (na || (double)t > hi) { r.v = iw ? 0x7fffffffffffffffull : 0x7fffffffull; r.fl = 16; }
            else if ((double)t < lo) { r.v = iw ? 0x8000000000000000ull : 0xffffffff80000000ull; r.fl = 16; }
            else { r.v = iw ? (uint64_t)(int64_t)t : (uint64_t)(int64_t)(int32_t)t; r.fl = t != x ? 1 : 0; }
        }
    }
    fesetround(FE_TONEAREST);
    return r;
}

// ---------------------------------------------------------------- the bench's state
struct Op {
    int id, op, fmt, rm, isg, iw, use, src[3], dst, idst, rob, f2i, dv, x;
    unsigned bm;
    long iss, offer, wk;
    bool alive, done;
    uint64_t xdata;
};
struct Tag { int prod = -1; bool have = false; uint64_t val = 0; int fmt = 1; long avail = INF; int readers = 0; };

static uint64_t rnd_val(int fmt)
{
    int k = rng() % 16;
    if (fmt) {
        if (k == 0) return rng() % 2 ? 0x8000000000000000ull : 0;
        if (k == 1) return Dbits((double)((int)(rng() % 41) - 20));
        double m = 1.0 + (double)(rng() % (1ull << 52)) / (double)(1ull << 52);
        int e = (int)(rng() % 61) - 30;
        return Dbits((rng() % 2 ? -1 : 1) * std::ldexp(m, e));
    }
    if (k == 0) return box(rng() % 2 ? 0x80000000u : 0);
    if (k == 1) return box(Fbits((float)((int)(rng() % 41) - 20)));
    float m = 1.0f + (float)(rng() % (1u << 23)) / (float)(1u << 23);
    int e = (int)(rng() % 41) - 20;
    return box(Fbits((rng() % 2 ? -1 : 1) * std::ldexp(m, e)));
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    d.clk = 0; d.rst_n = 1; d.flush = 0; d.kill = 0; d.clr = 0; d.frm = 0; d.a_valid = 0; d.x_valid = 0; d.ld_valid = 0; d.iw_ack = 0;
    d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    uint64_t file[FW_NR];
    Tag tg[FW_NR];
    for (int t = 0; t < FW_NR; t++) { file[t] = rnd_val(t & 1); tg[t].have = true; tg[t].val = file[t]; tg[t].fmt = t & 1; tg[t].avail = 0; }
    std::vector<Op> ops;
    std::vector<int> fl;                      // alive, not done (ids)
    std::deque<int> fifo;                     // FP -> integer results answered, waiting (FPU order)
    std::vector<std::pair<long, int>> wks;    // wakeups seen: (cycle, tag)
    int ldsch[2] = {-1, -1};                  // loads that write in this cycle (tags)
    uint64_t ldval[2] = {0, 0};
    int ldn[2] = {-1, -1};                    // loads that write in the next cycle
    uint64_t ldnv[2] = {0, 0};
    int frm = 0;
    long nres = 0, nint = 0, nx = 0, nld = 0, nb2 = 0, nb1 = 0, nkill = 0, nkop = 0, nflush = 0, ndv = 0, nldb = 0, nackw = 0, nf2ok = 0, nfok = 0, ndyn = 0, nwkd = 0;

    auto kill_op = [&](Op& o) {
        if (!o.alive) return;
        o.alive = false;
        for (int s = 0; s < 3; s++) if ((o.use >> s) & 1) tg[o.src[s]].readers--;
        if (!o.f2i) { tg[o.dst].prod = -1; tg[o.dst].have = false; tg[o.dst].avail = INF; }
        nkop++;
    };
    auto finish = [&](Op& o) {
        o.done = true;
        for (int s = 0; s < 3; s++) if ((o.use >> s) & 1) tg[o.src[s]].readers--;
    };
    auto expect = [&](const Op& o) {
        uint64_t v[3] = {0, 0, 0};
        for (int s = 0; s < 3; s++) if ((o.use >> s) & 1) {
            if (!tg[o.src[s]].have) { FAIL("op %d: source p%d has no value yet (issued %ld, prod %d, avail %ld)", o.id, o.src[s], o.iss, tg[o.src[s]].prod, tg[o.src[s]].avail);
                if (tg[o.src[s]].prod >= 0) { const Op& q = ops[tg[o.src[s]].prod]; printf("   its producer op %d: op %d x %d dv %d issued %ld wk %ld alive %d done %d bm %x; consumer bm %x\n", q.id, q.op, q.x, q.dv, q.iss, q.wk, q.alive, q.done, q.bm, o.bm); } }
            v[s] = tg[o.src[s]].val;
        }
        int rm = o.rm == 7 ? frm : o.rm;
        return o.x ? ref(o.op, o.fmt, rm, o.isg, o.iw, o.xdata, 0, 0) : ref(o.op, o.fmt, rm, o.isg, o.iw, v[0], v[1], v[2]);
    };

    for (long cyc = 0; cyc < 400000; cyc++) {
        int phase = (cyc >> 11) & 3;
        // ---- this cycle's frm (it changes only with nothing in flight that reads it, as a CSR µop at the head)
        if (fl.empty() && fifo.empty() && rng() % 50 == 0) frm = rng() % 4;
        d.frm = frm;
        d.a_valid = 0; d.x_valid = 0; d.iw_ack = 0; d.kill = 0; d.clr = 0; d.flush = 0;
        // the loads scheduled at the last cycle write now
        unsigned lv = 0, lt = 0; VlWide<4> lw; for (int i = 0; i < 4; i++) lw[i] = 0;
        for (int l = 0; l < 2; l++) if (ldsch[l] >= 0) {
            lv |= 1u << l; lt |= (unsigned)ldsch[l] << (FW_TW * l);
            lw[2 * l] = (uint32_t)ldval[l]; lw[2 * l + 1] = (uint32_t)(ldval[l] >> 32);
        }
        d.ld_valid = lv; d.ld_tag = lt; d.ld_data = lw;
        d.eval();
        // the file's reads (before this cycle's writes)
        {
            VlWide<6> rd;
            for (int s = 0; s < 3; s++) {
                int a = (d.rf_addr >> (FW_TW * s)) & FW_TM;
                rd[2 * s] = (uint32_t)file[a]; rd[2 * s + 1] = (uint32_t)(file[a] >> 32);
            }
            d.rf_data = rd;
        }
        bool fok = d.fpu_ok, iok = d.f2i_ok, xok = d.x_ready;
        if (!fok) nfok++;
        if (!iok) nf2ok++;

        // ---- recoveries
        unsigned open = 0;
        for (int id : fl) open |= ops[id].bm;
        for (int id : fifo) open |= ops[id].bm;
        bool flush = rng() % 4000 == 0;
        unsigned kill = 0, clr = 0;
        if (!flush && open && rng() % 25 == 0) { int b; do b = rng() % 12; while (!((open >> b) & 1)); kill = 1u << b; }
        if (open && rng() % 4 == 0) { int b = rng() % 12; clr = (1u << b) & open & ~kill; }
        d.flush = flush; d.kill = kill; d.clr = clr;

        // ---- loads for the next cycle: tags no one reads or writes; usable by an issue
        //      of this cycle, whose S1 meets the load's write (the bypass at S1)
        ldn[0] = ldn[1] = -1;
        for (int l = 0; l < 2; l++) {
            if (rng() % 3) continue;
            int t = rng() % FW_NR;
            if (tg[t].prod >= 0 || tg[t].readers > 0 || t == ldn[0] || t == ldsch[0] || t == ldsch[1] || !(tg[t].have || tg[t].avail == INF)) continue;
            ldn[l] = t;
            ldnv[l] = rnd_val(rng() % 2);
            tg[t].val = ldnv[l]; tg[t].fmt = (ldnv[l] >> 32) == 0xffffffffu ? 0 : 1; tg[t].have = true;
            tg[t].avail = cyc;
        }

        // ---- an issue on port A
        std::vector<int> usable, exact, next1, freet;
        for (int t = 0; t < FW_NR; t++) {
            if (tg[t].avail <= cyc) usable.push_back(t);
            if (tg[t].avail == cyc) exact.push_back(t);
            if (tg[t].avail == cyc - 1) next1.push_back(t);
            if (tg[t].prod < 0 && tg[t].readers == 0 && (tg[t].avail <= cyc || !tg[t].have) && t != ldsch[0] && t != ldsch[1] && t != ldn[0] && t != ldn[1]) freet.push_back(t);
        }
        Op na{}; bool issue = false; unsigned abm = 0, xbm = 0;
        if (fok && !flush && !usable.empty() && freet.size() > 4 && rng() % (phase == 2 ? 4 : 1) == 0) {
            na.id = (int)ops.size(); na.x = 0;
            int k = rng() % 32;
            static const int pick[32] = {ADD, ADD, SUB, MUL, MUL, MADD, MADD, MADD, MSUB, NMSUB, NMADD, SGNJ, SGNJN, SGNJX, MIN, MAX,
                                         EQ, LT, LE, MVXF, CVTIF, CVTIF, DIV, SQRT, ADD, MUL, MADD, MADD, SUB, MAX, LT, MADD};
            na.op = pick[k];
            na.f2i = na.op == EQ || na.op == LT || na.op == LE || na.op == MVXF || na.op == CVTIF;
            na.dv = na.op == DIV || na.op == SQRT;
            if (na.dv && rng() % 3) na.op = MADD, na.dv = 0;
            if (!na.f2i || iok) {
                na.use = na.op == SQRT || na.op == MVXF || na.op == CVTIF ? 1 : na.op >= MADD && na.op <= NMADD ? 7 : 3;
                std::vector<int>* pool = !exact.empty() && rng() % 2 ? &exact : !next1.empty() && rng() % 2 ? &next1 : &usable;
                for (int s = 0; s < 3; s++) {
                    std::vector<int>& p = (s == 0 || rng() % 2) ? *pool : usable;
                    na.src[s] = p.empty() ? usable[rng() % usable.size()] : p[rng() % p.size()];
                    if (tg[na.src[s]].avail > cyc) na.src[s] = usable[rng() % usable.size()];
                }
                na.fmt = rng() % 8 ? tg[na.src[0]].fmt : rng() % 2;
                na.rm = rng() % 4 == 0 ? 7 : rng() % 4;
                na.isg = 1; na.iw = rng() % 2;
                na.rob = rng() % 64; na.idst = rng() % 128;
                na.dst = 0;
                if (!na.f2i) {
                    std::vector<int> fd;
                    for (int t : freet) if (!(((na.use & 1) && t == na.src[0]) || ((na.use & 2) && t == na.src[1]) || ((na.use & 4) && t == na.src[2]))) fd.push_back(t);
                    na.dst = fd[rng() % fd.size()];
                }
                na.bm = rng() & 0xfff & rng() & rng();
                for (int s = 0; s < 3; s++) if ((na.use >> s) & 1 && tg[na.src[s]].prod >= 0) na.bm |= ops[tg[na.src[s]].prod].bm;
                abm = na.bm;              // (driven with this cycle's clr, as OOO_FIQ gives it;
                na.bm &= ~clr;            //  the bit drops as it issues, here and in the block)
                na.iss = cyc; na.offer = -1; na.wk = -1; na.alive = true; na.done = false;
                issue = true;
            }
        }
        if (issue) {
            for (int s = 0; s < 3; s++) if ((na.use >> s) & 1) {
                if (tg[na.src[s]].avail == cyc && cyc > 0) nb2++;
                if (tg[na.src[s]].avail == cyc - 1) nb1++;
                if (ldn[0] == na.src[s] || ldn[1] == na.src[s]) nldb++;
            }
            if (na.rm == 7) ndyn++;
            d.a_valid = 1;
            d.a_src = (uint32_t)na.src[0] | ((uint32_t)na.src[1] << FW_TW) | ((uint32_t)na.src[2] << (2 * FW_TW));
            d.a_wr = !na.f2i; d.a_dst = na.dst; d.a_bm = abm; d.a_dv = na.dv; d.a_f2i = na.f2i;
            d.a_pl = (uint32_t)na.op | ((uint32_t)na.fmt << 5) | ((uint32_t)na.rm << 6) | ((uint32_t)na.isg << 9) | ((uint32_t)na.iw << 10) |
                     ((uint32_t)na.rob << 11) | ((uint32_t)na.idst << 17);
        }
        // ---- an int -> FP µop
        Op nxo{}; bool xsend = false;
        if (xok && !flush && freet.size() > 6 && rng() % 6 == 0) {
            nxo.id = -1; nxo.x = 1; nxo.op = rng() % 2 ? CVTFI : MVFX; nxo.fmt = rng() % 2; nxo.rm = rng() % 4 == 0 ? 7 : rng() % 4;
            nxo.isg = 1; nxo.iw = rng() % 2; nxo.use = 0; nxo.f2i = 0; nxo.dv = 0;
            nxo.xdata = rng() % 4 ? (uint64_t)(int64_t)((int)(rng() % 2001) - 1000) : rng();
            nxo.rob = rng() % 64; nxo.idst = 0;
            auto clash = [&](int t) { if (!issue) return false; if (t == na.dst && !na.f2i) return true;
                                      for (int k = 0; k < 3; k++) if (((na.use >> k) & 1) && t == na.src[k]) return true; return false; };
            do nxo.dst = freet[rng() % freet.size()]; while (clash(nxo.dst));
            xbm = rng() & 0xfff & rng() & rng();
            nxo.bm = xbm & ~clr;
            nxo.iss = cyc; nxo.offer = -1; nxo.wk = -1; nxo.alive = true; nxo.done = false;
            xsend = true;
            d.x_valid = 1; d.x_data = nxo.xdata; d.x_dst = nxo.dst; d.x_bm = xbm;
            d.x_pl = (uint32_t)nxo.op | ((uint32_t)nxo.fmt << 5) | ((uint32_t)nxo.rm << 6) | ((uint32_t)nxo.isg << 9) | ((uint32_t)nxo.iw << 10) |
                     ((uint32_t)nxo.rob << 11);
        }
        // ---- the integer write slot
        bool ack = rng() % (phase == 3 ? 5 : 2) == 0;
        d.iw_ack = ack;
        d.eval();

        // ---- the answers of this cycle
        int fwr_t = -1; uint64_t fwr_v = 0;
        if (d.wk_valid) {
            int t = d.wk_tag;
            wks.push_back({cyc, t});
            if (tg[t].prod < 0) FAIL("cycle %ld: a wakeup of p%d, which nothing in flight writes", cyc, t);
            else {
                Op& o = ops[tg[t].prod];
                if (flush || (o.bm & kill)) FAIL("cycle %ld: a wakeup of p%d, whose µop is killed in this cycle", cyc, t);
                if (o.dv) { if (!d.fw_valid || (int)d.fw_tag != t) FAIL("cycle %ld: a divide's wakeup of p%d without its answer", cyc, t); nwkd++; }
                else {
                    if (!o.x && cyc != o.iss + 8) FAIL("cycle %ld: the wakeup of p%d at issue + %ld, expected + 8", cyc, t, cyc - o.iss);
                    if (o.x && cyc < o.iss + 7) FAIL("cycle %ld: an int -> FP wakeup too early", cyc);
                    o.wk = cyc;
                }
                tg[t].avail = cyc + 1;
            }
        }
        if (d.fw_valid) {
            int t = d.fw_tag;
            if (tg[t].prod < 0) FAIL("cycle %ld: an FP result for p%d, which nothing in flight writes", cyc, t);
            else {
                Op& o = ops[tg[t].prod];
                if (!o.x && cyc != o.iss + 11 && !o.dv) FAIL("cycle %ld: p%d answered at issue + %ld", cyc, t, cyc - o.iss);
                if (o.dv && cyc < o.iss + 11) FAIL("cycle %ld: a divide answered at issue + %ld", cyc, cyc - o.iss);
                if (o.x && cyc < o.iss + 10) FAIL("cycle %ld: an int -> FP µop answered %ld after it was sent", cyc, cyc - o.iss);
                if (!o.dv && o.wk != cyc - 3) FAIL("cycle %ld: p%d answered, its wakeup at %ld, expected %ld", cyc, t, o.wk, cyc - 3);
                Res r = expect(o);
                if ((uint64_t)d.fw_data != r.v) FAIL("cycle %ld: op %d (%d, fmt %d, rm %d) p%d = %016lx, expected %016lx", cyc, o.id, o.op, o.fmt, o.rm, t, (unsigned long)d.fw_data, (unsigned long)r.v);
                if ((int)d.fw_flags != r.fl) FAIL("cycle %ld: op %d (%d fmt %d rm %d iw %d x %d data %016lx) flags %x, expected %x", cyc, o.id, o.op, o.fmt, o.rm, o.iw, o.x, (unsigned long)o.xdata, (int)d.fw_flags, r.fl);
                if ((int)d.fw_rob != o.rob) FAIL("cycle %ld: fw_rob", cyc);
                tg[t].val = r.v; tg[t].fmt = o.fmt; tg[t].have = true; tg[t].prod = -1;
                fwr_t = t; fwr_v = r.v;
                if (o.dv) ndv++;
                finish(o);
                nres++;
            }
        }
        // FP -> integer results answered now (issue + 11), alive at this cycle
        bool hdrop = !fifo.empty() && (!ops[fifo.front()].alive || (ops[fifo.front()].bm & kill) || flush);
        if (d.iw_valid) {
            if (fifo.empty() || hdrop) { FAIL("cycle %ld: an integer result with none expected (x%d rob %d; fifo %zu, hdrop %d)", cyc, (int)d.iw_tag, (int)d.iw_rob, fifo.size(), (int)hdrop);
                for (size_t q = ops.size() > 60 ? ops.size() - 60 : 0; q < ops.size(); q++) if (ops[q].f2i && ops[q].idst == (int)d.iw_tag && ops[q].rob == (int)d.iw_rob)
                    printf("   op %zu: issued %ld alive %d done %d bm %x offer %ld\n", q, ops[q].iss, ops[q].alive, ops[q].done, ops[q].bm, ops[q].offer);
                if (!fifo.empty()) { const Op& h = ops[fifo.front()]; printf("   head op %d issued %ld alive %d bm %x; kill %x flush %d\n", h.id, h.iss, h.alive, h.bm, kill, (int)flush); } }
            else {
                Op& o = ops[fifo.front()];
                Res r = expect(o);
                if ((int)d.iw_tag != o.idst || (uint64_t)d.iw_data != r.v || (int)d.iw_flags != r.fl || (int)d.iw_rob != o.rob)
                    FAIL("cycle %ld: op %d (%d fmt %d) integer result x%d %016lx flags %x, expected x%d %016lx flags %x", cyc, o.id, o.op, o.fmt,
                         (int)d.iw_tag, (unsigned long)d.iw_data, (int)d.iw_flags, o.idst, (unsigned long)r.v, r.fl);
                if (ack) { fifo.pop_front(); finish(o); nint++; nackw++; }
            }
        } else if (!fifo.empty() && cyc > 0) {
            if (!hdrop) FAIL("cycle %ld: no integer result, op %d waiting", cyc, ops[fifo.front()].id);
            else { kill_op(ops[fifo.front()]); fifo.pop_front(); }   // (killed: the block skips it now)
        }

        // FP -> integer results answered now (issue + 11), alive at this cycle: in the FIFO from the next
        for (int id : fl) { Op& o = ops[id]; if (o.f2i && cyc == o.iss + 11 && !(o.bm & kill) && !flush) { fifo.push_back(o.id); o.offer = 0; } }

        // ---- the edge
        d.clk = 1; d.eval(); d.clk = 0; d.eval();

        // ---- the bench's state after it
        for (int l = 0; l < 2; l++) if (ldsch[l] >= 0) { file[ldsch[l]] = ldval[l]; nld++; }
        if (fwr_t >= 0) file[fwr_t] = fwr_v;
        // kills and clears
        if (flush) {
            nflush++;
            for (int id : fl) kill_op(ops[id]);
            for (int id : fifo) kill_op(ops[id]);
            fifo.clear();
        } else {
            if (kill) {
                nkill++;
                for (int id : fl) if (ops[id].bm & kill) kill_op(ops[id]);
                for (int id : fifo) if (ops[id].bm & kill) kill_op(ops[id]);
            }
            for (int id : fl) ops[id].bm &= ~clr;
            for (int id : fifo) ops[id].bm &= ~clr;
        }
        { std::vector<int> f2; for (int id : fl) if (ops[id].alive && !ops[id].done && ops[id].offer != 0) f2.push_back(id); fl = f2; }
        if (issue && !flush && !(na.bm & kill)) {
            ops.push_back(na);
            Op& o = ops.back();
            for (int s = 0; s < 3; s++) if ((o.use >> s) & 1) tg[o.src[s]].readers++;
            if (!o.f2i) { tg[o.dst].prod = o.id; tg[o.dst].have = false; tg[o.dst].avail = INF; }
            fl.push_back(o.id);
        }
        if (xsend && !flush && !(nxo.bm & kill)) {
            nxo.id = (int)ops.size();
            ops.push_back(nxo);
            tg[nxo.dst].prod = nxo.id; tg[nxo.dst].have = false; tg[nxo.dst].avail = INF;
            fl.push_back(nxo.id);
            nx++;
        }
        // the loads of the next cycle become this cycle's
        for (int l = 0; l < 2; l++) { ldsch[l] = ldn[l]; ldval[l] = ldnv[l]; }
    }
    bool cov = nres > 100000 && nint > 15000 && nx > 10000 && nld > 50000 && nb2 > 20000 && nb1 > 20000 && nldb > 3000 && nkill > 5000 &&
               nkop > 10000 && nflush > 50 && ndv > 1000 && nwkd > 1000 && nfok > 10000 && nf2ok > 500 && ndyn > 10000;
    printf("tb_fpuw (%d registers): %ld FP results (%ld divides / square roots), %ld integer results, %ld int -> FP µops; %ld loads (%ld read the cycle they are written); "
           "%ld sources at the answer, %ld a cycle after; %ld kills (%ld µops), %ld flushes; %ld cycles without fpu_ok, %ld without f2i_ok; %ld with frm: %ld mismatches: %s\n",
           FW_NR, nres, ndv, nint, nx, nld, nldb, nb2, nb1, nkill, nkop, nflush, nfok, nf2ok, ndyn, bad, bad == 0 && cov ? "PASS" : "FAIL");
    return bad != 0 || !cov;
}
