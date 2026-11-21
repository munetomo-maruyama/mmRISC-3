//---------------------------------------------------------------------------
// tb_csru.cpp : OOO_CSRU (CORE_CSR behind port 0, HPM_COUNTERS = 2) against a
// reference of a set of CSRs, in M mode
//
// Every cycle, now and then, a CSR µop in EX: csrrw / csrrs / csrrc or an
// immediate form, rs1 = x0 or not, on one of: mscratch, sscratch, mepc,
// mtval, mtvec (legal values: direct or vectored), mhpmcounter3 / 4 (the
// two counters of L1), mhpmcounter5 / 6 (not there with L1: they read 0
// and ignore writes), minstret, mcountinhibit (CY, IR, HPM3 / 4), mvendorid
// and cycle (read only), and a CSR that does not exist. As in the core, a
// CSR µop is at the ROB head: nothing commits in its cycle, and one that
// writes commits alone in the next (instret_inc 1). Otherwise every cycle
// instructions retire (instret_inc 0 to 4), and now and then a trap enters
// (exception or interrupt, random cause, epc, tval) or an MRET returns.
//
// Checked: the value read (the old one), the exception exactly for a CSR
// that does not exist or a write to a read-only one (with the instruction
// as tval), the replay mark exactly when it writes, what was written read
// back (mepc without bit 0), minstret = what was written + every
// instruction retired since but the writing one, none while mcountinhibit's
// IR is set (a write to mcountinhibit counts under the old bit and takes
// effect after its commit), the trap's mepc / mcause / mtval read back,
// the vector (mtvec's base, + 4 x cause for an interrupt when vectored),
// mepc for MRET.
//
// The counters' events (step 1.8 K1, Plan/OOC.md 29.97): every cycle a count
// of 0 to 8 for each of the 31 events (0 none); mhpmcounter3 / 4 add the
// count their mhpmevent3 / 4 select, two edges later (the core registers the
// events, CORE_CSR again), unless MINH (M mode here) or mcountinhibit's bit
// (from the edge it is written at) leaves it out; a wrap sets OF. Checked:
// each counter read, each mhpmevent read back (OF, MINH, SINH, UINH, the
// event: a number that does not exist is 0), writes near the end so that
// counters wrap. instret_inc goes to 8 (4 µops, a fused pair 2).
// minstretcfg (Smcntrpmf): its MINH stops minstret in M; the instruction
// that writes it is counted under the old value, as one that writes
// mcountinhibit (its commit is the next cycle, alone).
//---------------------------------------------------------------------------
#include "VOOO_CSRU.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>

static std::mt19937_64 rng(71);
static VOOO_CSRU d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const uint64_t AM = (1ull << 38) - 1;     // halfword addresses (VA 39)

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("CSRU_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    // the reference: plain registers, then the special ones
    std::map<int, uint64_t> r = {{0x340, 0}, {0x140, 0}, {0x341, 0}, {0x343, 0}};
    // the counters 3, 4 and their events (step 1.8 K1): value, event, OF / MINH / SINH / UINH; the events driven
    // last cycle (counted at this edge) and mcountinhibit's HPM bits as the counting sees them
    uint64_t hc[2] = {0, 0}; int hsel[2] = {0, 0}; uint64_t hbits[2] = {0, 0};
    int evq[31] = {}; uint64_t ihh = 0; long nwrap = 0, nevc = 0;
    uint64_t mtvec = 0, minstret = 0, mcause = 0, ih = 0, ih_new = 0; bool mt_known = false, mi_known = false;
    // what each CSR is: 0 plain, 1 mepc, 2 mtvec, 3 not there with L1, 4 minstret, 5 read only, 6 does not exist,
    // 7 mcountinhibit, 8 mhpmcounter3 / 4, 9 mhpmevent3 / 4, 10 minstretcfg
    const int A[] = {0x340, 0x140, 0x341, 0x343, 0x305, 0xB03, 0xB04, 0xB05, 0xB06, 0xB02, 0xF11, 0x5C0, 0xC00, 0x320, 0x323, 0x324, 0x322};
    const int K[] = {0, 0, 1, 0, 2, 8, 8, 3, 3, 4, 5, 6, 5, 7, 9, 9, 10};    // (cycle: read only)
    const int NA = 17;
    uint64_t icf = 0, icf_new = 0; long nicf = 0;          // minstretcfg as read, and as minstret's count sees it
    long nop = 0, nwr = 0, nill = 0, ntrap = 0, nmret = 0, ninst = 0, nih = 0;
    bool in_trap = false, commit = false, skip = false;      // commit: this cycle, the CSR µop that wrote (skip: minstret)
    bool hcw[2] = {}, hew[2] = {}; uint64_t hcv[2] = {}, hev[2] = {};   // a counter / event written at this edge
    // initial values that are not known until written: mtvec, minstret
    for (cyc = 0; cyc < 300000; cyc++) {
        int inc = rng() % 9;
        // (an MRET only after a trap from M: it returns to MPP, which a trap from M sets to M and an MRET to U)
        bool op = rng() % 3 == 0, trap = !op && rng() % 40 == 0, mret = !op && !trap && in_trap && rng() % 20 == 0;
        if (op) inc = 0;                                     // (at the head: nothing commits)
        if (commit) { op = trap = mret = false; inc = 1; }   // the CSR µop that wrote commits, alone
        int ai = rng() % NA, a = A[ai], k = K[ai];
        int f3 = (int)(rng() % 3) + 1 + ((rng() & 1) ? 4 : 0);
        int rs1 = rng() % 4 == 0 ? 0 : 1 + rng() % 31;
        uint64_t src = rng();
        if (k == 2) src = (rng() & ~3ull & (AM << 1)) | (rng() & 1);   // mtvec: a legal base and mode
        if (k == 2 && f3 != 1 && f3 != 5) f3 = 1;                       // (rs / rc could make an illegal mode)
        if (k == 2 && f3 == 5) { f3 = 1; }
        if (k == 8 && rng() % 2) src = ~0ull - rng() % 64;                 // near the end: a wrap soon
        if (k == 9 && rng() % 4) src = (rng() & (0xfull << 60)) | (rng() % 40);   // an event, some that do not exist
        if (k == 10 && rng() % 2) src = (rng() % 2) ? (1ull << 62) : 0;           // MINH on or off
        int ev[31];
        for (int e = 0; e < 31; e++) ev[e] = (e == 0 || rng() % 2) ? 0 : 1 + (int)(rng() % 8);
        uint32_t inst = (uint32_t)rng();
        bool tint = rng() & 1; int tcause = tint ? (int[]){3, 7, 11}[rng() % 3] : (int)(rng() % 16);
        uint64_t tepc = rng() & AM, ttval = rng();

        d.ex_valid = op; d.ex_op = f3; d.ex_addr = a; d.ex_rs1 = rs1; d.ex_src = src; d.ex_rob = rng() % 24; d.ex_inst = inst;
        d.trap_en = trap; d.trap_int = tint; d.trap_cause = tcause; d.trap_epc = tepc; d.trap_tval = ttval;
        d.mret_en = mret; d.sret_en = 0;
        d.irq_m_soft = 0; d.irq_m_timer = 0; d.irq_m_ext = 0; d.irq_s_ext = 0; d.mtime = cyc;
        d.instret_inc = inc;
        for (int w = 0; w < 4; w++) d.hpm_ev[w] = 0;
        for (int e = 0; e < 31; e++) d.hpm_ev[e / 8] |= (uint32_t)ev[e] << (4 * (e % 8));
        d.fflags_we = 0; d.fflags_set = 0; d.fs_dirty = 0;
        d.dbg_access = 0; d.dbg_addr = 0; d.dbg_enter = 0; d.dbg_cause = 0; d.dbg_pc = 0; d.dbg_resume = 0; d.trig_fired = 0;
        d.eval();

        if (op) {
            nop++;
            bool imm = f3 & 4; uint64_t s = imm ? (uint64_t)rs1 : src;
            bool ww = (f3 & 3) == 1 || rs1 != 0;
            bool ill = k == 6 || (k == 5 && ww);
            if ((bool)d.ex_exc != ill) FAIL("csr %03x op %d: exception %d, expected %d", a, f3, (int)d.ex_exc, ill);
            if ((bool)d.tv_valid != ill || (ill && (uint32_t)d.tv_val != inst)) FAIL("csr %03x: tval report %d", a, (int)d.tv_valid);
            if (ill) nill++;
            if ((bool)d.ex_rp != (ww && !ill)) FAIL("csr %03x op %d rs1 %d: replay mark %d, expected %d", a, f3, rs1, (int)d.ex_rp, ww && !ill);
            // the value read
            uint64_t old = 0; bool known = true;
            if (k == 0 || k == 1) old = r[a];
            else if (k == 2) { old = mtvec; known = mt_known; }
            else if (k == 3) old = 0;
            else if (k == 4) { old = minstret; known = mi_known; }
            else if (k == 7) old = ih;
            else if (k == 8) old = hc[a - 0xB03];
            else if (k == 9) old = hbits[a - 0x323] | (uint64_t)hsel[a - 0x323];
            else if (k == 10) old = icf_new;
            else known = false;
            if (!ill && known && (uint64_t)d.ex_res != old) FAIL("csr %03x: read %016llx, expected %016llx", a, (unsigned long long)d.ex_res, (unsigned long long)old);
            // what it writes (at the edge)
            // the counters count at this edge (before a write of the same edge, which wins)
            if (ww && !ill) {
                nwr++;
                uint64_t base = (k == 2) ? mtvec : (k == 4) ? (uint64_t)d.ex_res : old;
                if (k == 4) base = d.ex_res;
                uint64_t nv = (f3 & 3) == 1 ? s : (f3 & 3) == 2 ? (base | s) : (base & ~s);
                if (k == 0) r[a] = nv;
                else if (k == 1) r[a] = nv & ~1ull;
                else if (k == 2) { mtvec = nv; mt_known = true; }
                else if (k == 4) { minstret = nv; mi_known = true; skip = true; }  // (its commit is not counted)
                else if (k == 7) { ih_new = nv & 0x1d; nih++; }
                else if (k == 8) { int i = a - 0xB03; hcw[i] = true; hcv[i] = nv; }
                else if (k == 9) { int i = a - 0x323; hew[i] = true; hev[i] = nv; }
                else if (k == 10) { icf_new = nv & (7ull << 60); nicf++; }
            }
        }
        // this edge: each counter adds the events of the cycle before (CORE_CSR's hpm_ev_q), then the writes
        for (int i = 0; i < 2; i++) {
            int q = evq[hsel[i]];
            if (q && !((ihh >> (3 + i)) & 1) && !((hbits[i] >> 62) & 1)) {
                uint64_t s = hc[i] + (uint64_t)q;
                if (s < hc[i]) { hbits[i] |= 1ull << 63; nwrap++; }
                hc[i] = s; nevc++;
            }
            if (hcw[i]) hc[i] = hcv[i];
            if (hew[i]) { hbits[i] = hev[i] & (0xfull << 60); hsel[i] = (hev[i] & ((1ull << 56) - 1)) < 31 ? (int)(hev[i] & 31) : 0; }
            hcw[i] = hew[i] = false;
        }
        for (int e = 0; e < 31; e++) evq[e] = ev[e];
        if (op && k == 7 && ((f3 & 3) == 1 || rs1 != 0)) ihh = ih_new;     // (the HPM bits count from the next edge)
        if (trap) {
            uint64_t base = (mtvec >> 2) << 1;
            uint64_t ev = (tint && (mtvec & 3) == 1) ? base + 2 * (uint64_t)tcause : base;
            if (mt_known && (uint64_t)d.tvec != (ev & AM)) FAIL("trap vector %llx, expected %llx", (unsigned long long)d.tvec, (unsigned long long)(ev & AM));
            ntrap++;
        }
        if (mret) {
            uint64_t e = (r[0x341] >> 1) & AM;
            if ((uint64_t)d.mepc != e) FAIL("mepc for MRET %llx, expected %llx", (unsigned long long)d.mepc, (unsigned long long)e);
            nmret++;
        }

        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        if (trap) {
            r[0x341] = (tepc << 1) | ((tepc >> 37) & 1 ? ~((1ull << 39) - 1) : 0);   // mepc: the epc sign extended
            r[0x343] = ttval; mcause = ((uint64_t)tint << 63) | (uint64_t)tcause;
            // mcause and the trap's registers read back next cycle
            d.ex_valid = 1; d.ex_op = 2; d.ex_rs1 = 0; d.ex_addr = 0x342; d.trap_en = 0; d.mret_en = 0; d.instret_inc = 0; d.eval();
            if ((uint64_t)d.ex_res != mcause) FAIL("mcause %016llx, expected %016llx", (unsigned long long)d.ex_res, (unsigned long long)mcause);
            d.ex_addr = 0x341; d.eval();
            if ((uint64_t)d.ex_res != r[0x341]) FAIL("mepc after the trap %016llx, expected %016llx", (unsigned long long)d.ex_res, (unsigned long long)r[0x341]);
            d.ex_valid = 0; d.eval();
        }
        if (trap) in_trap = true; else if (mret) in_trap = false;
        if (mi_known && !(commit && skip) && !(ih & 4) && !((icf >> 62) & 1)) minstret += inc;
        ninst += inc;
        if (commit) { ih = ih_new; skip = false; icf = icf_new; }   // (minstretcfg: from the cycle after its writer's commit)
        commit = op && ((f3 & 3) == 1 || rs1 != 0) && !(k == 6 || k == 5);
    }
    printf("tb_csru: %ld cycles, %ld CSR µops (%ld writes, %ld of mcountinhibit, %ld illegal), %ld traps, %ld MRETs, %ld instructions retired, %ld counts and %ld wraps of the event counters, %ld writes of minstretcfg, %ld mismatches: %s\n",
           cyc, nop, nwr, nih, nill, ntrap, nmret, ninst, nevc, nwrap, nicf, bad, bad ? "FAIL" : "PASS");
    if (nwrap < 20) { printf("tb_csru: too few wraps\n"); return 1; }
    return bad ? 1 : 0;
}
