//---------------------------------------------------------------------------
// tb_core.cpp : the core's bench (Plan/CORE.md 5): OOO_CORE under
// Verilator, fetching through ICacheModel from the bench's Memory, its
// commit trace in lock-step with Spike at every instruction (bench.h).
//
//   tb_core [-seed <n>] [-miss <%>] [-dhit <%>] [-mlat <cycles>] [-mspread <cycles>] [-exit <symbol>] [-max <cycles>] [-v]
//           [-restores-out <file>] [-restores-ref <file> -restores-max <x>] [-replays-max <n>] [-exit0] <elf> ...
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
// older store, Plan/CORE.md 5.9: what costs cycles, not values). -exit0 fails a
// run whose exit code is not 0: a self-checking program (b4/irq, the Interrupts
// tests) whose interrupt never came ends at its own bound, and Spike, made to
// take only the core's interrupts, ends there too (step 1.8 I1).
// The register file is set to 0 after reset, as Spike's registers start.
// OOO_CPU (build_core.sh cpu, step 1.7 H3, Plan/OOC.md 29.58) has its own I$, the
// arbiter and the L2: ICacheModel is not used (-miss means nothing), the memory
// model (Axi4Mem) is behind the L2. -mlat n: the memory as the board's (the first
// beat of a read n to n + s cycles after its address, a write's answer n / 2 to
// n / 2 + s / 2 after its last beat, the readies up; s is -mspread, 20 by default;
// step 2.5 measured the board: -mlat 16 -mspread 5, LitexSystem/docs/BRINGUP.md 27);
// 0 (the default): 3 to 16 cycles
// with random readies and stalls, for the tests. After the exit the memory is
// compared with the program's, with the L2's dirty lines over it and the D$'s over
// those (the D$ written back, step 1.7b W2, Plan/OOC.md 29.62).
// Interrupts (step 1.8 I1, Plan/OOC.md 29.78): OOO_CPU has the CLINT and the PLIC (CPU_MMIO);
// the PLIC's sources 1 to 31 are bits 1 to 31 of the word at IRQ_DEV, which a program writes
// on the peripheral bus (AxiLite keeps it: it is outside Memory). OOO_CORE's interrupt lines are held at 0.
// Lock-step makes Spike take the interrupt the core took (SIM/LOCKSTEP). The memory compared
// after the exit is the RAM's (from 0x8000_0000): the devices' stores are not in Memory.
// Linux (step 1.8 L1, SIM/LINUX): -hang n (the cycles without a commit before a run fails, 20,000 by
// default: Linux waits in WFI between its ticks), -console (HTIF's characters printed as they come),
// -progress n (the run's line every n cycles).
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
#include "dbgmodel.h"

#include <algorithm>
#include <functional>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

static const int VA = 39;
static const uint64_t IRQ_DEV = 0x11000000;     // the bench's interrupt sources (OOO_CPU: the PLIC's 1 to 31)

template <class W> static uint64_t wbits(const W& w, int lo, int n)
{
    uint64_t v = 0;
    for (int b = 0; b < n; b++) { int i = lo + b; v |= (uint64_t)((w[i / 32] >> (i % 32)) & 1) << b; }
    return v;
}
static uint64_t wbits(uint64_t w, int lo, int n) { return (w >> lo) & (n >= 64 ? ~0ull : ((1ull << n) - 1)); }
// a pc of the commit trace (VA - 1 bits of halfwords): the address, sign extended from bit VA - 1 (step 1.8 V2: the high
// virtual addresses of S mode, as Spike's)
static uint64_t tpc(uint64_t h) { return (uint64_t)(((int64_t)(h << 1) << (64 - VA)) >> (64 - VA)); }

#include <map>
#include <fstream>

struct Opts {
    uint64_t seed = 1; int miss = 8, dhit = 80, mlat = 0, mspread = 20; std::string exit_sym; uint64_t max = 20000000; bool verbose = false;
    std::string rs_out; std::map<std::string, long> rs_ref; double rs_max = 0;
    long rp_max = -1;                   // -replays-max: fail a run with more replays
    bool exit0 = false;                 // -exit0: fail a run whose exit code is not 0
    uint64_t hang = 20000;              // -hang: cycles without a commit before the run fails (Linux idles in WFI
                                        //  between its ticks: 500k cycles at HZ 100, step 1.8 L1)
    bool console = false;               // -console: HTIF's characters printed as they come
    uint64_t progress = 0;              // -progress: the run's line every so many cycles
    long dbg = 0;                       // -dbg n: a debugger halts the hart every n cycles on average (dbgmodel.h)
    int dbgf = 0;                       // -dbgf m: its features (dbgmodel.h: 1 EBREAK, 2 its triggers, 4 resethaltreq, 8 SSIP in steps)
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
    cfg.hang_cycles = o.hang;
    cfg.console = o.console;
    Bench b(cfg);
    ICacheModel ic(b.mem(), o.seed * 7 + 1, o.miss);
#ifdef CPU_TOP
    Axi4Mem ax(b.mem(), o.seed * 13 + 5, o.mlat, o.mspread);
    long ic_reqs = 0, ic_misses = 0, ic_fills = 0;      // (OOO_ICACHE's, from its registers; a miss that may not be fetched
                                                        //  is answered with zeros, not filled)
    AxiLite al(b.mem(), o.seed * 17 + 3);
#else
    DMissModel dm(b.mem(), o.seed * 13 + 5, o.dhit >= 100 ? 0 : 12);     // (-dhit 100: fills at once, else up to 12 cycles late)
    uint64_t tohost_line = b.symbol("tohost") >> 6;
    UcModel uc(b.mem(), o.seed * 19 + 7);                                   // (HTIF's tohost: not cached, step 1.3 E1b)
    long ev_icm = 0, ev_dmf = 0;                        // the models' misses and fills seen: the PMU's events 7, 8
    long ev_icm1 = 0, ev_dmf1 = 0;                      // ... as they were two clock edges back (what hpm_ev has counted)
#endif
    std::unique_ptr<Top> d(new Top);
#ifdef CPU_TOP
    d->sim_uc_line = b.symbol("tohost") >> 6;          // HTIF's line: not cached (Plan/CORE.md 5.1 rule 2)
#endif
    d->clk = 0; d->boot = 0; d->boot_pc = 0;
    // debug (step 1.8 J1): no debugger unless -dbg (below)
    d->hart_haltreq = 0; d->hart_resumereq = 0; d->hart_resethaltreq = 0;
    d->reg_req = 0; d->reg_wr = 0; d->reg_regno = 0; d->reg_size64 = 0; d->reg_wdata = 0;
#ifdef CPU_TOP
    d->bm_req = 0; d->bm_wr = 0; d->bm_addr = 0; d->bm_size = 0; d->bm_wdata = 0;
#else
    d->dbg_mem_wr = 0; d->dc_rf_strb = 0xff;
#endif
#ifdef CPU_TOP
    const bool dbg_mem = true;
#else
    const bool dbg_mem = false;                         // (no OOO_DMISS2: the debugger's memory accesses are OOO_CPU's)
#endif
    std::unique_ptr<DbgModel<Top>> dbg;
    if (o.dbg > 0) dbg.reset(new DbgModel<Top>(b, o.seed * 23 + 11 + std::hash<std::string>()(elf), o.dbg, dbg_mem, o.dbgf));
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
    // ... and the FP file, as Spike's FP registers start (a debugger reads them: step 1.8 J1)
    for (int w = 0; w < 64; w++) {
        d->rootp->CORE(u_fprf__DOT__g_bank__BRA__0__KET____DOT__g_two__DOT__lo)[w] = 0;
        d->rootp->CORE(u_fprf__DOT__g_bank__BRA__1__KET____DOT__g_two__DOT__lo)[w] = 0;
        d->rootp->CORE(u_fprf__DOT__g_bank__BRA__2__KET____DOT__g_two__DOT__lo)[w] = 0;
    }
    for (int w = 0; w < 16; w++) {
        d->rootp->CORE(u_fprf__DOT__g_bank__BRA__0__KET____DOT__g_two__DOT__hi)[w] = 0;
        d->rootp->CORE(u_fprf__DOT__g_bank__BRA__1__KET____DOT__g_two__DOT__hi)[w] = 0;
        d->rootp->CORE(u_fprf__DOT__g_bank__BRA__2__KET____DOT__g_two__DOT__hi)[w] = 0;
    }
    for (int i = 0; i < 80; i++) d->rootp->CORE(u_fprf__DOT__lvt)[i] = 0;
    long restores = 0, replays = 0;
    bool res_bad = false;
    // the PMU's events (step 1.8 K1, Plan/OOC.md 29.97): hpm_ev holds the last cycle's; every cycle the 4 slots at
    // renaming add up to 4, the instructions and µops retired are the trace's of the cycle before, and at the end
    // the exceptions and interrupts are the trace's traps
    long ev_sum[31] = {}, ev_ninsn = 0, ev_nuop = 0, ev_nld = 0, ev_nst = 0, tr_exc = 0, tr_irq = 0, ev_i8 = 0, ev_rs_last = 0, ev_rp_last = 0;
    // ... and the events made from the core's signals of the cycle before (tb_core.vlt), with the bench's own
    // account of renaming's recovery: the slot classes, the ROB's head, the walker, the branch resolutions
    struct EvPrev { int go = 0, offer = 0, cmt = 0, rs = 0, st = 0, id = 0, dw = 0; bool rk = false, fa = false, ff = false, hv = false, mem = false, rr = false, rc = false, dm = false; } evp;
    bool ev_rec = false;
    // the ROB's ld / st bits of an instruction (bit 0 a load, bit 1 a store): loads and FP loads, LR (a load), SC (a
    // store), the other AMOs both, stores and FP stores, CBO.ZERO (a store); an encoding that does not exist is neither
    auto mem_kind = [](uint32_t i) -> int {
        if ((i & 3) != 3) { int q = i & 3, f = (i >> 13) & 7; return (q == 0 || q == 2) && f != 0 && f != 4 ? (f < 4 ? 1 : 2) : 0; }
        int op = i & 0x7f, f3 = (i >> 12) & 7, f5 = i >> 27;
        if (op == 0x03) return f3 != 7 ? 1 : 0;
        if (op == 0x23) return f3 <= 3 ? 2 : 0;
        if (op == 0x07) return f3 == 2 || f3 == 3 ? 1 : 0;
        if (op == 0x27) return f3 == 2 || f3 == 3 ? 2 : 0;
        if (op == 0x2f && (f3 == 2 || f3 == 3)) {
            if (f5 == 2) return ((i >> 20) & 31) == 0 ? 1 : 0;
            if (f5 == 3) return 2;
            if (f5 == 0 || f5 == 1 || f5 == 4 || f5 == 8 || f5 == 12 || f5 == 16 || f5 == 20 || f5 == 24 || f5 == 28) return 3;
        }
        if ((i & 0xfff07fffu) == 0x0040200fu) return 2;                 // CBO.ZERO: a store (step 1.8 L1)
        return 0;
    };
    auto is_mem = [&](uint32_t i) { return mem_kind(i) != 0; };
    // after the exit: 3,000 cycles more for the SQ and the writes to drain, then the memory the D$ wrote through must be
    // the program's (Bench::arch: the committed stores) but for HTIF's lines (step 1.3 E2, Plan/OOC.md 29.34)
    long drain_left = -1;
    bool continue_clock = false;
    // CORE_BYPC=<file>: the cycles between commits by the pc of the last instruction committed (Plan/model's
    // OOO_BYPC, for the comparison by function, Plan/OOC.md 29.30); one program a run
    std::map<uint64_t, long> bypc;
    long bypc_last = -1;
    // CoreMark's timed window: from the commit of start_time's first instruction to stop_time's (-v prints it)
    // (or a DSP kernel's of Plan/fpu: kstart to kend, step 1.8 U2)
    uint64_t tw_lo = b.symbol("start_time"), tw_hi = b.symbol("stop_time");
    if (!tw_lo) { tw_lo = b.symbol("kstart"); tw_hi = b.symbol("kend"); }
    long tw_a = -1, tw_b = -1;
    for (uint64_t cyc = 0; !b.done() || drain_left > 0; cyc++) {
        if (o.progress && cyc && cyc % o.progress == 0) {
            std::printf("\n@@ %s\n", b.summary(elf).c_str()); std::fflush(stdout);
        }
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
        d->irq_src = (uint32_t)(al.dev(IRQ_DEV) >> 1) & 0x7fffffffu;
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
            d->dc_pt_done = q.pt_done; d->dc_pt_data = q.pt_data;   // a page table's entry (step 1.8 V1)
        }
        d->irq_m_soft = 0; d->irq_m_timer = 0; d->irq_m_ext = 0; d->irq_s_ext = 0; d->mtime = 0;
        // the memory side's events (step 1.8 K1): a miss of the I$ model, a fill of the D$ model (the cycle after);
        // no L2 here
        d->ev_mem = (ic.misses != ev_icm ? 1u : 0u) | (dm.fills != ev_dmf ? 2u : 0u);
        ev_icm1 = ev_icm; ev_dmf1 = ev_dmf;
        ev_icm = ic.misses; ev_dmf = dm.fills;
        d->fl_take = 1; d->fl_done = flq_q;
#endif
        if (dbg) dbg->drive(d.get());
        d->eval();
        if (dbg) dbg->sample(d.get());
        // the commit trace
        TraceSlot s[4];
        int n = 0;
        if (d->tr_trap) {
            s[0] = TraceSlot{};
            s[0].pc = tpc(wbits(d->tr_trap_pc, 0, VA - 1));
            s[0].trap = true; s[0].cause = d->tr_cause | ((uint64_t)d->tr_int << 63);   // (mcause's interrupt bit)
            s[0].insn[0] = (uint32_t)wbits(d->tr_insn, 0, 32);           // the head's instruction
            if ((s[0].insn[0] & 3) != 3) s[0].insn[0] &= 0xffff;
            n = 1;
        } else {
            for (int k = 0; k < 4; k++) {
                if (!((d->tr_valid >> k) & 1)) continue;
                TraceSlot& t = s[n++];
                t = TraceSlot{};
                t.pc = tpc(wbits(d->tr_pc, (VA - 1) * k, VA - 1));
                t.insn[0] = (uint32_t)wbits(d->tr_insn, 32 * k, 32);
                if ((t.insn[0] & 3) != 3) t.insn[0] &= 0xffff;
                if ((d->tr_pair >> k) & 1) {                    // ALU + branch (B5a): the write is the ALU's
                    t.pair = true; t.wr_first = true;
                    t.insn[1] = (uint32_t)wbits(d->tr_insn2, 32 * k, 32);
                    if ((t.insn[1] & 3) != 3) t.insn[1] &= 0xffff;
                }
                if ((d->tr_wr >> k) & 1) { t.rd = (int)((d->tr_rd >> (5 * k)) & 31); t.rd_fp = (d->tr_fwr >> k) & 1; t.rd_val = wbits(d->tr_val, 64 * k, 64); }
                if ((d->tr_st >> k) & 1) {
                    t.st[0].v = true;
                    t.st[0].addr = wbits(d->tr_st_addr, 64 * k, 64);
                    t.st[0].size = 1 << ((d->tr_st_size >> (2 * k)) & 3);
                    t.st[0].data = wbits(d->tr_st_data, 64 * k, 64) & (t.st[0].size == 8 ? ~0ull : ((1ull << (8 * t.st[0].size)) - 1));
                }
            }
        }
        if (dbg) dbg->trace(s, n);
        ev_rs_last = d->rootp->CORE(restore); ev_rp_last = d->rootp->CORE(replay);    // (in hpm_ev a cycle later)
        if (d->hart_halted) { ev_rs_last = 0; ev_rp_last = 0; }   // (debug mode's: not counted, step 1.8 J1)
        restores += ev_rs_last;
        replays += ev_rp_last;
        {
            int ev[31];
            for (int e = 0; e < 31; e++) { ev[e] = (int)((d->rootp->CORE(hpm_ev)[e / 8] >> (4 * (e % 8))) & 15); ev_sum[e] += ev[e]; }
            std::string why;
            if (evp.dm) {                                   // debug mode (step 1.8 J1): cycles alone counted
                for (int e = 0; e < 31; e++) if (e != 1 && ev[e]) { why = "PMU: event " + std::to_string(e) + " counted in debug mode"; break; }
            } else if (ev[12] + ev[17] + ev[20] + ev[21] != 4 * ev[1])
                why = "PMU: slots " + std::to_string(ev[12]) + " + " + std::to_string(ev[17]) + " + " + std::to_string(ev[20]) +
                      " + " + std::to_string(ev[21]) + ", not 4";
            else if (ev[2] != ev_ninsn || ev[22] != ev_nuop || ev[3] != ev_nld || ev[4] != ev_nst)
                why = "PMU: " + std::to_string(ev[2]) + " instructions, " + std::to_string(ev[22]) + " uops, " + std::to_string(ev[3]) +
                      " loads, " + std::to_string(ev[4]) + " stores retired; the trace " + std::to_string(ev_ninsn) + ", " +
                      std::to_string(ev_nuop) + ", " + std::to_string(ev_nld) + ", " + std::to_string(ev_nst);
            if (!why.empty()) { std::printf("cycle %llu: %s\n", (unsigned long long)cyc, why.c_str()); res_bad = true; break; }
            int st = (int)d->rootp->CORE(u_ptw__DOT__st), id = (int)d->rootp->CORE(u_ptw__DOT__id_r);
            if (why.empty() && ev[1] && !evp.dm) {          // (from the first cycle hpm_ev holds after reset)
                int e[31] = {};
                bool recn = ev_rec || evp.fa || evp.rk;
                e[20] = evp.go;
                if (recn) e[21] = 4 - evp.go; else { e[17] = evp.offer - evp.go; e[12] = 4 - evp.offer; }
                e[11] = evp.hv && evp.cmt == 0 && evp.mem; e[14] = evp.hv && evp.cmt == 0 && !evp.mem; e[30] = !evp.hv;
                bool wst = evp.st == 0 && st == 1;          // (OOO_PTW: S_IDLE to S_REQ)
                e[9] = wst && (id >> 5); e[10] = wst && !(id >> 5);
                e[27] = evp.st != 0 && !(evp.id >> 5); e[28] = evp.st != 0 && (evp.id >> 5);
                e[5] = evp.rs & 1;
                e[23] = evp.dw & 1; e[24] = (evp.dw >> 1) & 1; e[25] = (evp.dw >> 2) & 1; e[26] = evp.rr; e[29] = evp.rc;
                static const int CK[] = {5, 9, 10, 11, 12, 14, 17, 20, 21, 23, 24, 25, 26, 27, 28, 29, 30};
                for (int k : CK) if (ev[k] != e[k]) { why = "PMU: event " + std::to_string(k) + " is " + std::to_string(ev[k]) +
                                                            ", the bench's " + std::to_string(e[k]); break; }
            }
            ev_rec = evp.ff || evp.rk || (ev_rec && evp.go == 0);
            evp.st = st; evp.id = id;
            if (!why.empty()) { std::printf("cycle %llu: %s\n", (unsigned long long)cyc, why.c_str()); res_bad = true; break; }
            {
                auto pc4 = [](unsigned v) { return (int)((v & 1) + ((v >> 1) & 1) + ((v >> 2) & 1) + ((v >> 3) & 1)); };
                evp.go = pc4(d->rootp->CORE(r_go)); evp.offer = pc4(d->rootp->CORE(r_valid)); evp.cmt = d->rootp->CORE(cmt_valid);
                evp.rk = d->rootp->CORE(restore_k); evp.fa = d->rootp->CORE(flush_all); evp.ff = d->rootp->CORE(fe_flush);
                evp.hv = d->rootp->CORE(head_valid); evp.rs = d->rootp->CORE(rs_valid);
                evp.dw = d->rootp->CORE(ev_dwait); evp.rr = d->rootp->CORE(ev_rreg); evp.rc = d->rootp->CORE(ev_rckpt);
                evp.mem = evp.hv && is_mem(d->rootp->CORE(sh_insn)[d->rootp->CORE(head_rob)]);
                evp.dm = d->hart_halted;                    // (debug mode: OOO_TRAP dmode)
            }
            ev_i8 += ev[2] == 8;
            ev_ninsn = 0; ev_nuop = 0; ev_nld = 0; ev_nst = 0;
            if (n > 0 && s[0].trap) { if (s[0].cause >> 63) tr_irq++; else tr_exc++; }
            else for (int k = 0; k < n; k++) {
                ev_nuop++; ev_ninsn += s[k].pair ? 2 : 1;
                int mk = mem_kind(s[k].insn[0]); ev_nld += mk & 1; ev_nst += mk >> 1;
            }
        }
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
        uint64_t rpt = d->ic_req_ptag; bool rtok = d->ic_req_tok;      // (the ITLB's, step 1.8 V2)
        { uint32_t w[8]; for (int k = 0; k < 8; k++) w[k] = d->dbg_words[k]; ic.debug(d->dbg_mode, w); }   // (step 1.8 J1)
#else
        if (d->rootp->OOO_CPU__DOT__u_icache__DOT__s1_v && !d->rootp->OOO_CPU__DOT__u_icache__DOT__s1_rp) {
            ic_reqs++;
            if (!d->rootp->OOO_CPU__DOT__u_icache__DOT__s1_hit) ic_misses++;
            if (!d->rootp->OOO_CPU__DOT__u_icache__DOT__s1_hit && d->rootp->OOO_CPU__DOT__u_icache__DOT__s1_tok) ic_fills++;
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
        bool ptr = d->dc_pt_req; uint64_t pta = d->dc_pt_addr;
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
        ic.clock(acc, rpc, rpt, rtok);
#endif
#ifdef CPU_TOP
        ax.clock(arv, ara, arl, rr, awv, awa, awl, wv, wd, ws, br);
        al.clock(larv, lara, lrr, lawv, lawa, lwv, lwd, lws, lbr);
#else
        dm.clock(mv, ml, mvx, mid, smv, sml, smvx, dset, dway, didx, sqd, ptr, pta);
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
            // the D$'s dirty lines over those (256 sets of 8 ways since step 1.7c C5, Plan/OOC.md 29.72; {valid, tag}
            // with the tag the address above 4 KB, kept by OOO_DMISS2 in 4 banks by the set's top 2 bits; the line's 11:6
            // the set's low 6 bits)
#define DC_W8(M, ...) (w == 0 ? M(__VA_ARGS__, 0) : w == 1 ? M(__VA_ARGS__, 1) : w == 2 ? M(__VA_ARGS__, 2) : \
                       w == 3 ? M(__VA_ARGS__, 3) : w == 4 ? M(__VA_ARGS__, 4) : w == 5 ? M(__VA_ARGS__, 5) : \
                       w == 6 ? M(__VA_ARGS__, 6) : M(__VA_ARGS__, 7))
#define DC_TAGX(B, s6, W) r->DC_TAG(B, W)[s6]
#define DC_DTYX(s, W) r->DC_DTY(W)[s]
#define DC_DATX(i, W) r->DC_DAT(W)[i]
            auto tagof = [&](int b, int w, int s6) -> uint64_t {
                return b == 0 ? DC_W8(DC_TAGX, 0, s6) : b == 1 ? DC_W8(DC_TAGX, 1, s6) :
                       b == 2 ? DC_W8(DC_TAGX, 2, s6) : DC_W8(DC_TAGX, 3, s6);
            };
            for (int w = 0; w < 8; w++)
                for (int s = 0; s < 256; s++) {
                    bool dt = DC_W8(DC_DTYX, s);
                    if (!dt) continue;
                    uint64_t t = tagof(s >> 6, w, s & 63);
                    uint64_t a = ((t & ((1ull << 28) - 1)) << 12) | ((uint64_t)(s & 63) << 6);
                    for (int k = 0; k < 8; k++) {
                        uint64_t v = DC_W8(DC_DATX, s * 8 + k);
                        b.mem().write64(a + 8 * k, v, 0xff);
                    }
                }
#undef DC_W8
#undef DC_TAGX
#undef DC_DTYX
#undef DC_DATX
        }
#endif
        std::vector<uint64_t> pgs = b.mem().pages(), pa = b.arch().pages();
        pgs.insert(pgs.end(), pa.begin(), pa.end());
        std::sort(pgs.begin(), pgs.end());
        pgs.erase(std::unique(pgs.begin(), pgs.end()), pgs.end());
        for (uint64_t pg : pgs) {
            if (pg < 0x80000000ull) continue;           // (the devices: not memory)
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
    // the PMU's events against the bench's own counts (the drain after the exit has brought the last ones in)
    // (with a debugger, -dbg, the fills are not compared: those of debug mode are not counted, and a fill asked before
    // a halt may come in it)
    // the fills: on the core against the models' counts as hpm_ev has them (two edges back); on OOO_CPU after the
    // drain only (a run that stops at its pass symbol may end with a fill asked for and not yet counted; in the
    // drain the loop at the exit hits the I$): I$ fills against OOO_ICACHE's misses that may be fetched, L2 reads
    // against the I$'s and the D$'s reads, L2 misses against memory's line reads
#ifdef CPU_TOP
    long b_icm = ic_fills, b_dcf = ev_sum[8], b_l2r = ev_sum[7] + ev_sum[8], b_l2m = ax.reads;
    bool fill_bad = continue_clock && !dbg && (ev_sum[7] != b_icm || ev_sum[18] != b_l2r || ev_sum[19] != b_l2m);
#else
    long b_icm = ev_icm1, b_dcf = ev_dmf1, b_l2r = 0, b_l2m = 0;
    bool fill_bad = !dbg && (ev_sum[7] != b_icm || ev_sum[8] != b_dcf || ev_sum[18] != 0 || ev_sum[19] != 0);
#endif
    if (!res_bad && b.passed() && (ev_sum[15] != tr_exc || ev_sum[16] != tr_irq || ev_sum[6] != restores - ev_rs_last ||
                                   ev_sum[13] != replays - ev_rp_last || fill_bad)) {
        std::printf("PMU: exceptions %ld, interrupts %ld, restores %ld, replays %ld, I$ fills %ld, D$ fills %ld, L2 reads %ld, misses %ld; "
                    "the bench %ld, %ld, %ld, %ld, %ld, %ld, %ld, %ld\n",
                    ev_sum[15], ev_sum[16], ev_sum[6], ev_sum[13], ev_sum[7], ev_sum[8], ev_sum[18], ev_sum[19],
                    tr_exc, tr_irq, restores, replays, b_icm, b_dcf, b_l2r, b_l2m);
        res_bad = true;
    }
    std::string name = elf.substr(elf.rfind('/') + 1);
    std::printf("%s\n", b.summary(name).c_str());
    if (dbg) std::printf("    debugger: %ld halts, %ld steps, %ld register accesses, %ld memory accesses, %ld EBREAKs, %ld triggers, %ld reset halts\n",
                         dbg->sessions, dbg->steps, dbg->regs, dbg->mems, dbg->ebreaks, dbg->trigs, dbg->resets);
    if (ev_i8) std::printf("    PMU: 8 instructions retired in %ld cycles\n", ev_i8);
    if (o.verbose && ev_sum[1]) {
        double sl = 4.0 * (double)ev_sum[1];
        std::printf("    PMU: slots %.1f %% retiring, %.1f %% bad speculation, %.1f %% front end, %.1f %% back end "
                    "(ROB %ld, queues %ld, LQ / SQ %ld, registers %ld, checkpoints %ld cycles); head waits %ld memory %ld other, "
                    "ROB empty %ld; walks %ld fetch %ld LSU; fills I$ %ld D$ %ld; L2 %ld reads %ld misses\n",
                    100.0 * ev_sum[22] / sl, 100.0 * (ev_sum[20] - ev_sum[22] + ev_sum[21]) / sl, 100.0 * ev_sum[12] / sl,
                    100.0 * ev_sum[17] / sl, ev_sum[23], ev_sum[24], ev_sum[25], ev_sum[26], ev_sum[29], ev_sum[11], ev_sum[14],
                    ev_sum[30], ev_sum[9], ev_sum[10], ev_sum[7], ev_sum[8], ev_sum[18], ev_sum[19]);
    }
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
    if (ok && o.exit0 && b.exit_code() != 0) {
        std::printf("    exit code %d, not 0\n", b.exit_code());
        ok = false;
    }
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
        else if (a == "-mspread" && i + 1 < argc) o.mspread = atoi(argv[++i]);
        else if (a == "-exit" && i + 1 < argc) o.exit_sym = argv[++i];
        else if (a == "-max" && i + 1 < argc) o.max = strtoull(argv[++i], nullptr, 0);
        else if (a == "-v") o.verbose = true;
        else if (a == "-exit0") o.exit0 = true;
        else if (a == "-hang" && i + 1 < argc) o.hang = strtoull(argv[++i], nullptr, 0);
        else if (a == "-console") o.console = true;
        else if (a == "-dbg" && i + 1 < argc) o.dbg = atol(argv[++i]);
        else if (a == "-dbgf" && i + 1 < argc) o.dbgf = atoi(argv[++i]);
        else if (a == "-progress" && i + 1 < argc) o.progress = strtoull(argv[++i], nullptr, 0);
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
