//---------------------------------------------------------------------------
// tb_core.cpp : the core's bench (Plan/CORE.md 5): OOO_CORE under
// Verilator, fetching through ICacheModel from the bench's Memory, its
// commit trace in lock-step with Spike at every instruction (bench.h).
//
//   tb_core [-seed <n>] [-miss <%>] [-dhit <%>] [-mlat <cycles>] [-exit <symbol>] [-max <cycles>] [-v]
//           [-restores-out <file>] [-restores-ref <file> -restores-max <x>] [-replays-max <n>] <elf> ...
//
// The D$: OOO_LSU3's, with DMissModel (ports.h) as its miss handler (step 1.3
// E1; -dhit 100: fills at once, else up to 12 cycles late); Memory takes
// the stores as they commit. B3: loads and stores; the commit trace gives
// each store's address and data, and the exit and the console come from
// HTIF (tohost) as in B0.
// B2 (ALU µops only, no memory): the programs of b2/gen_b2.py end at the
// symbol `pass` (-exit pass), with no HTIF. The run passes when that
// instruction commits with every instruction before it as Spike ran it
// (pc, instruction, the register written and its value). Every branch
// and jalr resolved is also checked against its instruction (what lock-step
// cannot see, since it only steers the predictors): the last parcel, taken
// for a jalr, call / return (link registers x1 / x5, as predecode), a
// conditional branch's outcome to the TAGE update, the BTB's write of an
// indirect jump at its last parcel. -v: the cycles,
// mispredictions (restores) and the IPC. -restores-out writes each
// program's restores; -restores-ref / -restores-max fail a run with more
// than x times the restores of the reference file (+ 4): what only steers
// the predictors costs mispredictions, not values (the bug injection);
// -replays-max fails a run with more than n replays (loads issued past an
// older store, Plan/CORE.md 5.9: what costs cycles, not values).
// The register file is set to 0 after reset, as Spike's registers start.
// OOO_CPU (build_core.sh cpu, step 1.7 H3, Plan/OOC.md 29.58) has its own I$, the
// arbiter and the L2: ICacheModel is not used (-miss means nothing), the memory
// model (Axi4Mem) is behind the L2. -mlat n: the memory as the board's (the first
// beat of a read n to n + 20 cycles after its address, a write's answer n / 2 to
// n / 2 + 10 after its last beat, the readies up); 0 (the default): 3 to 16 cycles
// with random readies and stalls, for the tests. After the exit the memory is
// compared with the program's, with the L2's dirty lines over it and the D$'s over
// those (the D$ written back, step 1.7b W2, Plan/OOC.md 29.62).
//---------------------------------------------------------------------------
#ifdef CPU_TOP                  // OOO_CPU: the core with OOO_DCAD and the D$ on the AXI models (build_core.sh cpu)
#include "VOOO_CPU.h"
#include "VOOO_CPU___024root.h"
typedef VOOO_CPU Top;
typedef VOOO_CPU___024root TopRoot;
#define CORE(x) OOO_CPU__DOT__u_core__DOT__##x
#define L2_TAG(w) OOO_CPU__DOT__u_l2__DOT__u_tag__DOT__g_way__BRA__##w##__KET____DOT__mem
#define L2_DAT(w) OOO_CPU__DOT__u_l2__DOT__u_dat__DOT__g_way__BRA__##w##__KET____DOT__mem
#define DC_TAG(b, w) OOO_CPU__DOT__u_dmiss__DOT__g_bank__BRA__##b##__KET____DOT__g_tag__BRA__##w##__KET____DOT__tagm
#define DC_DTY(w) OOO_CPU__DOT__u_dmiss__DOT__g_dty__BRA__##w##__KET____DOT__dm
#define DC_DAT(w) OOO_CPU__DOT__u_core__DOT__u_lsu__DOT__u_dch__DOT__g_way__BRA__##w##__KET____DOT__g_vr__DOT__vm
#else                           // OOO_CORE: OOO_LSU3's D$ with DMissModel behind it (step 1.3 E1)
#include "VOOO_CORE.h"
#include "VOOO_CORE___024root.h"
typedef VOOO_CORE Top;
typedef VOOO_CORE___024root TopRoot;
#define CORE(x) OOO_CORE__DOT__##x
#endif
#include "verilated.h"

#include "bench.h"
#include "ports.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

static const int VA = 39;

template <class W> static uint64_t wbits(const W& w, int lo, int n)
{
    uint64_t v = 0;
    for (int b = 0; b < n; b++) { int i = lo + b; v |= (uint64_t)((w[i / 32] >> (i % 32)) & 1) << b; }
    return v;
}
static uint64_t wbits(uint64_t w, int lo, int n) { return (w >> lo) & (n >= 64 ? ~0ull : ((1ull << n) - 1)); }

#include <map>
#include <fstream>

struct Opts {
    uint64_t seed = 1; int miss = 8, dhit = 80, mlat = 0; std::string exit_sym; uint64_t max = 20000000; bool verbose = false;
    std::string rs_out; std::map<std::string, long> rs_ref; double rs_max = 0;
    long rp_max = -1;                   // -replays-max: fail a run with more replays
};
static FILE* rs_out_f = nullptr;

static bool link_reg(int r) { return r == 1 || r == 5; }

// the resolutions of this cycle against their instructions; "" if right
static std::string check_resolution(TopRoot* rp)
{
    char m[160];
    for (int p = 0; p < 2; p++) {
        if (!((rp->CORE(br_valid) >> p) & 1)) continue;
        int rob = (rp->CORE(br_rob) >> (6 * p)) & 63;
        uint32_t in = rp->CORE(sh_insn)[rob];
        uint64_t pc = wbits(rp->CORE(br_pc), (VA - 1) * p, VA - 1);
        if (pc != wbits(rp->CORE(sh_pc)[rob], 0, VA - 1)) {     // the pc array's line and the parcel against dispatch's pc
            std::snprintf(m, sizeof m, "port %d resolves at pc %llx, dispatched at %llx", p, (unsigned long long)pc << 1,
                          (unsigned long long)wbits(rp->CORE(sh_pc)[rob], 0, VA - 1) << 1);
            return m;
        }
        if (rp->CORE(sh_pair)[rob]) {                   // a pair: its branch, after the ALU half
            pc += (in & 3) == 3 ? 2 : 1;
            in = rp->CORE(sh_insn2)[rob];
        }
        bool c = (in & 3) != 3;
        int e = (int)((pc + (c ? 0 : 1)) & 15);
        bool jalr = false; int rd = 0, rs1 = 0;
        if (!c && (in & 0x7f) == 0x67) { jalr = true; rd = (in >> 7) & 31; rs1 = (in >> 15) & 31; }
        if (c && (in & 3) == 2 && ((in >> 13) & 7) == 4 && ((in >> 2) & 31) == 0 && ((in >> 7) & 31) != 0) {
            jalr = true; rs1 = (in >> 7) & 31; rd = ((in >> 12) & 1) ? 1 : 0;       // c.jalr / c.jr
        }
        bool call = jalr && link_reg(rd), ret = jalr && link_reg(rs1) && !link_reg(rd);
        int ge = (rp->CORE(br_e) >> (4 * p)) & 15;
        bool gt = (rp->CORE(br_taken) >> p) & 1, gc = (rp->CORE(br_call) >> p) & 1;
        bool gr = (rp->CORE(br_ret) >> p) & 1, rv = (rp->CORE(rs_valid) >> p) & 1;
        bool rt = (rp->CORE(rs_taken) >> p) & 1;
        int re = (rp->CORE(rs_e) >> (4 * p)) & 15;
        bool ok = ge == e && gc == call && gr == ret && (jalr ? gt && !rv : rv && re == e && rt == gt);
        if (!ok) {
            std::snprintf(m, sizeof m, "port %d resolves pc %llx (%08x): last parcel %d call %d ret %d taken %d, TAGE %d %d %d",
                          p, (unsigned long long)pc << 1, in, ge, gc, gr, gt, rv, re, rt);
            return m;
        }
    }
    if (rp->CORE(bt_valid)) {
        bool any = false;
        for (int p = 0; p < 2 && !any; p++) {
            if (!((rp->CORE(br_valid) >> p) & 1)) continue;
            uint32_t in = rp->CORE(sh_insn)[(rp->CORE(br_rob) >> (6 * p)) & 63];
            uint64_t pc = wbits(rp->CORE(br_pc), (VA - 1) * p, VA - 1);
            any = (uint64_t)rp->CORE(bt_pc) == pc + ((in & 3) == 3 ? 1 : 0) && !((rp->CORE(br_ret) >> p) & 1);
        }
        if (!any) return "the BTB written for no indirect jump at its last parcel";
    }
    return "";
}

static bool run(const Opts& o, const std::string& elf)
{
    BenchCfg cfg;
    cfg.elf = elf;
    cfg.exit_sym = o.exit_sym;
    cfg.max_cycles = o.max;
    cfg.hang_cycles = 20000;
    Bench b(cfg);
    ICacheModel ic(b.mem(), o.seed * 7 + 1, o.miss);
#ifdef CPU_TOP
    Axi4Mem ax(b.mem(), o.seed * 13 + 5, o.mlat);
    long ic_reqs = 0, ic_misses = 0;                    // (OOO_ICACHE's, from its registers)
    AxiLite al(b.mem(), o.seed * 17 + 3);
#else
    DMissModel dm(b.mem(), o.seed * 13 + 5, o.dhit >= 100 ? 0 : 12);     // (-dhit 100: fills at once, else up to 12 cycles late)
    uint64_t tohost_line = b.symbol("tohost") >> 6;
    UcModel uc(b.mem(), o.seed * 19 + 7);                                   // (HTIF's tohost: not cached, step 1.3 E1b)
#endif
    std::unique_ptr<Top> d(new Top);
#ifdef CPU_TOP
    d->sim_uc_line = b.symbol("tohost") >> 6;          // HTIF's line: not cached (Plan/CORE.md 5.1 rule 2)
#endif
    d->clk = 0; d->boot = 0; d->boot_pc = 0;
    bool icf_q = false;                                 // FENCE.I: the I$ model holds nothing, its invalidate is done a cycle later
#ifndef CPU_TOP
    bool flq_q = false;                                 // FENCE.I: Memory has every committed store, nothing to write back
#endif
#ifndef CPU_TOP
    d->ic_req_ready = 0; d->ic_resp_valid = 0;
#endif
    d->rst_n = 1; d->eval(); d->rst_n = 0; d->eval(); d->rst_n = 1; d->eval();
    // the register file starts at 0, as Spike's: it has no reset (a boot ROM would clear it), and a program's
    // start may save registers it has not written yet (CoreMark's does)
    for (int w = 0; w < 64; w++) {
        d->rootp->CORE(u_prf__DOT__g_bank__BRA__0__KET____DOT__g_two__DOT__lo)[w] = 0;
        d->rootp->CORE(u_prf__DOT__g_bank__BRA__1__KET____DOT__g_two__DOT__lo)[w] = 0;
        d->rootp->CORE(u_prf__DOT__g_bank__BRA__2__KET____DOT__g_two__DOT__lo)[w] = 0;
    }
    for (int w = 0; w < 16; w++) {
        d->rootp->CORE(u_prf__DOT__g_bank__BRA__0__KET____DOT__g_two__DOT__hi)[w] = 0;
        d->rootp->CORE(u_prf__DOT__g_bank__BRA__1__KET____DOT__g_two__DOT__hi)[w] = 0;
        d->rootp->CORE(u_prf__DOT__g_bank__BRA__2__KET____DOT__g_two__DOT__hi)[w] = 0;
    }
    for (int i = 0; i < 80; i++) d->rootp->CORE(u_prf__DOT__lvt)[i] = 0;
    long restores = 0, replays = 0;
    bool res_bad = false;
    // after the exit: 3,000 cycles more for the SQ and the writes to drain, then the memory the D$ wrote through must be
    // the program's (Bench::arch: the committed stores) but for HTIF's lines (step 1.3 E2, Plan/OOC.md 29.34)
    long drain_left = -1;
    bool continue_clock = false;
    // CORE_BYPC=<file>: the cycles between commits by the pc of the last instruction committed (Plan/model's
    // OOO_BYPC, for the comparison by function, Plan/OOC.md 29.30); one program a run
    std::map<uint64_t, long> bypc;
    long bypc_last = -1;
    // CoreMark's timed window: from the commit of start_time's first instruction to stop_time's (-v prints it)
    uint64_t tw_lo = b.symbol("start_time"), tw_hi = b.symbol("stop_time");
    long tw_a = -1, tw_b = -1;
    for (uint64_t cyc = 0; !b.done() || drain_left > 0; cyc++) {
        d->boot = cyc == 2;
        d->boot_pc = b.entry() >> 1;
#ifndef CPU_TOP
        d->ic_req_ready = ic.ready();
        d->ic_resp_valid = ic.resp_valid();
        { uint32_t w[8]; ic.resp_data(w); for (int k = 0; k < 8; k++) d->ic_resp_data[k] = w[k]; }
        d->ic_done = icf_q;
#endif
#ifdef CPU_TOP
        ax.drive();
        d->m_axi4_arready = ax.arready; d->m_axi4_awready = ax.awready; d->m_axi4_wready = ax.wready;
        d->m_axi4_rvalid = ax.rvalid; d->m_axi4_rdata = ax.rdata; d->m_axi4_rlast = ax.rlast; d->m_axi4_rresp = 0;
        d->m_axi4_bvalid = ax.bvalid; d->m_axi4_bresp = 0;
        al.drive();
        d->m_axil_arready = al.arready; d->m_axil_awready = al.awready; d->m_axil_wready = al.wready;
        d->m_axil_rvalid = al.rvalid; d->m_axil_rdata = al.rdata; d->m_axil_rresp = 0;
        d->m_axil_bvalid = al.bvalid; d->m_axil_bresp = 0;
#else
        {
            const DMissModel::Out& q = dm.out();
            d->dc_fill_done = q.fill_done; d->dc_done_v = q.done_v; d->dc_done_id = q.done_id;
            d->dc_tw_en = q.tw_en; d->dc_tw_way = q.tw_way; d->dc_tw_set = q.tw_set; d->dc_tw_tag = (uint32_t)q.tw_tag;
            d->dc_rf_en = q.rf_en; d->dc_rf_way = q.rf_way; d->dc_rf_addr = q.rf_addr; d->dc_rf_data = q.rf_data;
            d->dc_uc_line_v = 1; d->dc_uc_line = tohost_line;
            d->dc_uc_done = uc.done(); d->dc_uc_rdata = uc.rdata();
            d->dc_vr_addr = 0; d->dc_vr_way = 0;        // (the model fills from Memory, which has every store)
        }
        d->fl_take = 1; d->fl_done = flq_q;
#endif
        d->eval();
        // the commit trace
        TraceSlot s[4];
        int n = 0;
        if (d->tr_trap) {
            s[0] = TraceSlot{};
            s[0].pc = wbits(d->tr_trap_pc, 0, VA - 1) << 1;
            s[0].trap = true; s[0].cause = d->tr_cause | ((uint64_t)d->tr_int << 63);   // (mcause's interrupt bit)
            s[0].insn[0] = (uint32_t)wbits(d->tr_insn, 0, 32);           // the head's instruction
            if ((s[0].insn[0] & 3) != 3) s[0].insn[0] &= 0xffff;
            n = 1;
        } else {
            for (int k = 0; k < 4; k++) {
                if (!((d->tr_valid >> k) & 1)) continue;
                TraceSlot& t = s[n++];
                t = TraceSlot{};
                t.pc = wbits(d->tr_pc, (VA - 1) * k, VA - 1) << 1;
                t.insn[0] = (uint32_t)wbits(d->tr_insn, 32 * k, 32);
                if ((t.insn[0] & 3) != 3) t.insn[0] &= 0xffff;
                if ((d->tr_pair >> k) & 1) {                    // ALU + branch (B5a): the write is the ALU's
                    t.pair = true; t.wr_first = true;
                    t.insn[1] = (uint32_t)wbits(d->tr_insn2, 32 * k, 32);
                    if ((t.insn[1] & 3) != 3) t.insn[1] &= 0xffff;
                }
                if ((d->tr_wr >> k) & 1) { t.rd = (int)((d->tr_rd >> (5 * k)) & 31); t.rd_val = wbits(d->tr_val, 64 * k, 64); }
                if ((d->tr_st >> k) & 1) {
                    t.st[0].v = true;
                    t.st[0].addr = wbits(d->tr_st_addr, 64 * k, 64);
                    t.st[0].size = 1 << ((d->tr_st_size >> (2 * k)) & 3);
                    t.st[0].data = wbits(d->tr_st_data, 64 * k, 64) & (t.st[0].size == 8 ? ~0ull : ((1ull << (8 * t.st[0].size)) - 1));
                }
            }
        }
        restores += d->rootp->CORE(restore);
        replays += d->rootp->CORE(replay);
        if (n > 0 && !s[0].trap) {
            if (bypc_last >= 0) bypc[s[n-1].pc] += (long)cyc - bypc_last;
            bypc_last = (long)cyc;
            for (int k = 0; k < n; k++) {
                if (tw_lo && s[k].pc == tw_lo && tw_a < 0) tw_a = (long)cyc;
                if (tw_hi && s[k].pc == tw_hi && tw_b < 0) tw_b = (long)cyc;
            }
        }
        {
            std::string why = check_resolution(d->rootp);
            if (!why.empty()) { std::printf("cycle %llu: %s\n", (unsigned long long)cyc, why.c_str()); res_bad = true; break; }
        }
#ifndef CPU_TOP
        bool icf = d->ic_flush;                         // (sampled before the clock edge)
        bool flr = d->fl_req;                           // taken now (fl_take is 1): done in the next cycle
        bool acc = d->ic_req_valid && ic.ready();
        uint64_t rpc = d->ic_req_pc;
#else
        if (d->rootp->OOO_CPU__DOT__u_icache__DOT__s1_v && !d->rootp->OOO_CPU__DOT__u_icache__DOT__s1_rp) {
            ic_reqs++;
            if (!d->rootp->OOO_CPU__DOT__u_icache__DOT__s1_hit) ic_misses++;
        }
#endif
#ifdef CPU_TOP
        bool arv = d->m_axi4_arvalid, rr = d->m_axi4_rready, awv = d->m_axi4_awvalid, wv = d->m_axi4_wvalid, br = d->m_axi4_bready;
        uint64_t ara = d->m_axi4_araddr, awa = d->m_axi4_awaddr, wd = d->m_axi4_wdata;
        int arl = d->m_axi4_arlen, awl = d->m_axi4_awlen; uint8_t ws = d->m_axi4_wstrb;
        bool larv = d->m_axil_arvalid, lrr = d->m_axil_rready, lawv = d->m_axil_awvalid, lwv = d->m_axil_wvalid, lbr = d->m_axil_bready;
        uint64_t lara = d->m_axil_araddr, lawa = d->m_axil_awaddr, lwd = d->m_axil_wdata; uint8_t lws = d->m_axil_wstrb;
#else
        bool mv = d->dc_miss_valid, smv = d->dc_st_miss_valid, dset = d->dc_dirty_set, sqd = d->dc_sq_drained;
        uint64_t ml = d->dc_miss_line, sml = d->dc_st_miss_line;
        int mid = d->dc_miss_id, dway = d->dc_dirty_way, didx = d->dc_dirty_idx, mvx = d->dc_miss_vx, smvx = d->dc_st_miss_vx;
        bool ucr = d->dc_uc_req, ucw = d->dc_uc_we;
        uint64_t uca = d->dc_uc_addr, ucd = d->dc_uc_wdata; uint8_t ucm = d->dc_uc_wmask;
        // Memory takes each store as the D$ takes it (dc_wt_*: what a write-back D$ would give back at once, step
        // 1.7b W2; OOO_CPU has the real write-back); a store for a device reaches Memory through UcModel
        if (d->dc_wt_valid) b.mem().write64(d->dc_wt_addr, d->dc_wt_data, d->dc_wt_mask);
#endif
        if (drain_left < 0) {
            if (!b.commit(s, n)) { if (b.passed()) { drain_left = 3000; continue_clock = true; } else break; }
            else if (!b.tick()) break;
        } else if (--drain_left == 0) break;
        d->clk = 1; d->eval(); d->clk = 0; d->eval();
#ifndef CPU_TOP
        icf_q = icf && !icf_q;
        flq_q = flr;
        ic.clock(acc, rpc);
#endif
#ifdef CPU_TOP
        ax.clock(arv, ara, arl, rr, awv, awa, awl, wv, wd, ws, br);
        al.clock(larv, lara, lrr, lawv, lawa, lwv, lwd, lws, lbr);
#else
        dm.clock(mv, ml, mvx, mid, smv, sml, smvx, dset, dway, didx, sqd);
        uc.clock(ucr, ucw, uca, ucd, ucm);
#endif
    }
    if (continue_clock && b.passed()) {
        uint64_t th = b.symbol("tohost") >> 6, fh = b.symbol("fromhost") >> 6;
#ifdef CPU_TOP
        // the L2's dirty lines over the memory behind it (4 ways of L2_SETS sets, build_core.sh's L2KB;
        // {valid, dirty, tag} with the tag the 40-bit address above the set and the line's offset)
        {
            auto* r = d->rootp;
            int ib = 0; while ((1 << ib) < L2_SETS) ib++;
            const int tb = 40 - 6 - ib;
            for (int s = 0; s < L2_SETS; s++)
                for (int w = 0; w < 4; w++) {
                    uint64_t t = w == 0 ? r->L2_TAG(0)[s] : w == 1 ? r->L2_TAG(1)[s] : w == 2 ? r->L2_TAG(2)[s] : r->L2_TAG(3)[s];
                    if (!((t >> (tb + 1)) & 1) || !((t >> tb) & 1)) continue;
                    uint64_t a = ((t & ((1ull << tb) - 1)) << (6 + ib)) | ((uint64_t)s << 6);
                    for (int k = 0; k < 8; k++) {
                        uint64_t v = w == 0 ? r->L2_DAT(0)[s * 8 + k] : w == 1 ? r->L2_DAT(1)[s * 8 + k] :
                                     w == 2 ? r->L2_DAT(2)[s * 8 + k] : r->L2_DAT(3)[s * 8 + k];
                        b.mem().write64(a + 8 * k, v, 0xff);
                    }
                }
            // the D$'s dirty lines over those (256 sets of 4 ways, step 1.7c C2; {valid, tag} with the tag the address
            // above 4 KB, kept by OOO_DMISS2 in 4 banks by the set's top 2 bits; the line's 11:6 the set's low 6 bits)
            auto tagof = [&](int b, int w, int s6) -> uint64_t {
#define DC_T4(B) (w == 0 ? r->DC_TAG(B, 0)[s6] : w == 1 ? r->DC_TAG(B, 1)[s6] : w == 2 ? r->DC_TAG(B, 2)[s6] : r->DC_TAG(B, 3)[s6])
                return b == 0 ? DC_T4(0) : b == 1 ? DC_T4(1) : b == 2 ? DC_T4(2) : DC_T4(3);
#undef DC_T4
            };
            for (int w = 0; w < 4; w++)
                for (int s = 0; s < 256; s++) {
                    bool dt = w == 0 ? r->DC_DTY(0)[s] : w == 1 ? r->DC_DTY(1)[s] : w == 2 ? r->DC_DTY(2)[s] : r->DC_DTY(3)[s];
                    if (!dt) continue;
                    uint64_t t = tagof(s >> 6, w, s & 63);
                    uint64_t a = ((t & ((1ull << 28) - 1)) << 12) | ((uint64_t)(s & 63) << 6);
                    for (int k = 0; k < 8; k++) {
                        uint64_t v = w == 0 ? r->DC_DAT(0)[s * 8 + k] : w == 1 ? r->DC_DAT(1)[s * 8 + k] :
                                     w == 2 ? r->DC_DAT(2)[s * 8 + k] : r->DC_DAT(3)[s * 8 + k];
                        b.mem().write64(a + 8 * k, v, 0xff);
                    }
                }
        }
#endif
        std::vector<uint64_t> pgs = b.mem().pages(), pa = b.arch().pages();
        pgs.insert(pgs.end(), pa.begin(), pa.end());
        std::sort(pgs.begin(), pgs.end());
        pgs.erase(std::unique(pgs.begin(), pgs.end()), pgs.end());
        for (uint64_t pg : pgs) {
            for (uint64_t w = pg; w < pg + Memory::PAGE; w += 8) {
                if ((w >> 6) == th || (w >> 6) == fh) continue;
                uint64_t x = b.mem().read64(w), y = b.arch().read64(w);
                if (x != y) {
                    std::printf("the memory (with the caches' dirty lines): %llx is %016llx, the program's %016llx\n",
                                (unsigned long long)w, (unsigned long long)x, (unsigned long long)y);
                    res_bad = true;
                    break;
                }
            }
            if (res_bad) break;
        }
    }
    std::string name = elf.substr(elf.rfind('/') + 1);
    std::printf("%s\n", b.summary(name).c_str());
    if (o.verbose)
#ifdef CPU_TOP
        std::printf("    %ld restores (mispredicted branches and jalr), %ld replays, I$ %ld / %ld missed, memory %ld line reads %ld line writes, uncached %ld reads %ld writes\n",
                    restores, replays, ic_misses, ic_reqs, ax.reads, ax.writes, al.reads, al.writes);
#else
        std::printf("    %ld restores (mispredicted branches and jalr), %ld replays, I$ %ld / %ld missed, D$ %ld lines filled (%ld asked by loads, %ld by stores), %ld evicted, uncached %ld reads %ld writes\n",
                    restores, replays, ic.misses, ic.reqs, dm.fills, dm.asks, dm.st_asks, dm.evicts, uc.reads, uc.writes);
#endif
    if (o.verbose && tw_a >= 0 && tw_b >= 0)
        std::printf("    the timed window (start_time to stop_time): %ld cycles\n", tw_b - tw_a);
    if (rs_out_f) std::fprintf(rs_out_f, "%s %ld\n", name.c_str(), restores);
    if (const char* bp = std::getenv("CORE_BYPC")) {
        if (FILE* f = std::fopen(bp, "w")) {
            for (auto& x : bypc) std::fprintf(f, "%llx %ld\n", (unsigned long long)x.first, x.second);
            std::fclose(f);
        }
    }
    d->final();                                         // (final blocks: a build with counters prints them)
    bool ok = b.passed() && !res_bad;
    if (ok && o.rp_max >= 0 && replays > o.rp_max) {
        std::printf("    %ld replays, more than %ld\n", replays, o.rp_max);
        ok = false;
    }
    if (ok && o.rs_max > 0) {
        auto it = o.rs_ref.find(name);
        if (it != o.rs_ref.end() && restores > (long)(o.rs_max * it->second) + 4) {
            std::printf("    %ld restores, more than %.2f times %ld\n", restores, o.rs_max, it->second);
            ok = false;
        }
    }
    return ok;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    Opts o;
    std::vector<std::string> files;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-seed" && i + 1 < argc) o.seed = strtoull(argv[++i], nullptr, 0);
        else if (a == "-miss" && i + 1 < argc) o.miss = atoi(argv[++i]);
        else if (a == "-dhit" && i + 1 < argc) o.dhit = atoi(argv[++i]);
        else if (a == "-mlat" && i + 1 < argc) o.mlat = atoi(argv[++i]);
        else if (a == "-exit" && i + 1 < argc) o.exit_sym = argv[++i];
        else if (a == "-max" && i + 1 < argc) o.max = strtoull(argv[++i], nullptr, 0);
        else if (a == "-v") o.verbose = true;
        else if (a == "-restores-out" && i + 1 < argc) o.rs_out = argv[++i];
        else if (a == "-restores-max" && i + 1 < argc) o.rs_max = atof(argv[++i]);
        else if (a == "-replays-max" && i + 1 < argc) o.rp_max = atol(argv[++i]);
        else if (a == "-restores-ref" && i + 1 < argc) {
            std::ifstream in(argv[++i]); std::string nm; long v;
            while (in >> nm >> v) o.rs_ref[nm] = v;
        }
        else if (a[0] == '+') continue;
        else files.push_back(a);
    }
    if (!o.rs_out.empty()) rs_out_f = std::fopen(o.rs_out.c_str(), "w");
    int fails = 0;
    for (auto& f : files) if (!run(o, f)) fails++;
    if (rs_out_f) std::fclose(rs_out_f);
    std::printf("tb_core: %zu files, %d failures: %s\n", files.size(), fails, fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
