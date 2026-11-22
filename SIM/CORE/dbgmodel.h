//---------------------------------------------------------------------------
// dbgmodel.h : a debugger on the core's debug ports (tb_core -dbg, step 1.8 J1, Plan/OOC.md 29.101)
//
// It stands in for mmRISC-2's Debug Module (RTL/CPU/DBG) on the ports it drives: hart_haltreq,
// hart_resumereq, reg_* (Access Register) and, on OOO_CPU, bm_* (Access Memory and SBA). Every
// `every` cycles on average it halts the hart, then in lock-step with the reference (which is
// where the hart halted: its next instruction not stepped):
//   - dpc is the reference's pc, dcsr.cause the halt's (3 haltreq, 4 a step);
//   - a few random accesses, each checked: a GPR or FPR read (64 or 32 bits) is the reference's;
//     a GPR, FPR or CSR (mscratch, sscratch) written, read back, and written back (each write put
//     into the reference too); a CSR read is the reference's (those both keep alike); a CSR that
//     does not exist, a write to a read-only one, a register number past the FPRs: errors;
//   - on OOO_CPU, memory: a word read (text or data, cached or dirty) is the reference's; one
//     written (and the bench's architectural memory with it), read back, and written back;
//   - then a resume, or 1 to 3 steps (dcsr.step: each halts after one instruction, the trace
//     having it, dpc again the reference's pc), then dcsr.step cleared and a resume.
// The run is the program's as without a debugger: nothing it sees has changed. With feats:
//   1  dcsr.ebreakm / s / u (some of them, drawn once) set at the first halt: an EBREAK at those
//      levels halts (cause 1, dpc the EBREAK's) in place of its trap; the debugger steps over it
//      (dpc and the reference's pc moved past it), as a debugger past a breakpoint of its own;
//   2  now and then an execute trigger of the debugger's (dmode, action 1, m / s / u) on dpc
//      before a resume, in trigger 3 (the program's tdata1 / tdata2 there kept): the hart halts
//      again at once (cause 2) without running it; the debugger puts the program's back
//      (tselect as the program left it);
//   4  half the runs with resethaltreq: the hart halts before its first instruction (cause 5;
//      nothing commits before it);
//   8  now and then before a step, SSIP made pending and enabled (mip.SSIP, mie.SSIE, mstatus.MIE
//      set in both, those bits put back after the steps): the step takes no interrupt (stepie 0).
// dcsr.cause must be one the halt may have: 3 (or 1, 2) for haltreq, 4 (or 1, 2) after a step,
// 5 after the reset, 1 or 2 for a halt the debugger did not ask for; cause 1 needs the ebreak bit
// of dcsr.prv (the bits drawn again at each resume). A step commits one instruction, or traps
// (not an interrupt) and halts at the handler; a halt of cause 1 or 2 in a step commits nothing.
//---------------------------------------------------------------------------
#pragma once
#include "bench.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <string>

template <class T> class DbgModel {
public:
    DbgModel(Bench& b, uint64_t seed, long every, bool mem, int feats = 0) : b(b), rng(seed), every(every), mem(mem), feats(feats)
    {
        wait = 1 + (long)(rng() % (2 * every));
        if (feats & 1) { static const uint64_t E[] = {1u << 15, 1u << 13, 1u << 12}; for (auto e : E) if (rng() & 1) eb |= e; if (!eb) eb = 1u << 15; }
        if ((feats & 4) && (rng() & 1)) { rh = true; st = HALTING; tmo = 200000; allow = 1 << 5; }
        uint64_t th = b.symbol("tohost");
        if (th) uc_line = th >> 6;
        text = b.entry();
        data = th ? (th & ~4095ull) : 0;
    }
    long sessions = 0, steps = 0, regs = 0, mems = 0, ebreaks = 0, trigs = 0, resets = 0;

    // before the evaluation: this cycle's inputs
    void drive(T* d)
    {
        d->hart_haltreq = haltreq;
        d->hart_resethaltreq = rh;
        d->hart_resumereq = resumereq; resumereq = false;
        d->reg_req = 0;
#ifdef CPU_TOP
        d->bm_req = 0;
#endif
        if (issue && !q.empty()) {
            const Act& a = q.front();
            if (a.k == RREG || a.k == WREG) {
                d->reg_req = 1; d->reg_wr = a.k == WREG; d->reg_regno = a.regno; d->reg_size64 = a.s64; d->reg_wdata = a.v;
            }
#ifdef CPU_TOP
            else if (a.k == RMEM || a.k == WMEM) {
                d->bm_req = 1; d->bm_wr = a.k == WMEM; d->bm_addr = a.addr; d->bm_size = a.size; d->bm_wdata = a.v;
            }
#endif
            if (verbose) std::printf("dbg: issue kind %d regno %x addr %llx v %llx\n", (int)a.k, a.regno, (unsigned long long)a.addr, (unsigned long long)a.v);
            issue = false; busy = true;
        }
    }

    // the commit trace of this cycle (before the reference takes it): the step's commits and traps
    void trace(const TraceSlot* s, int n)
    {
        if (b.done() || n == 0) return;
        if (rh && st == HALTING) { b.dbg_fail("debugger: an instruction ran before the reset halt"); return; }
        if (!(stepping && (st == RESUMING || st == HALTING))) return;
        if (s[0].trap) {
            if (s[0].cause >> 63) { b.dbg_fail("debugger: an interrupt taken in a step"); return; }
            st_traps++;
        } else st_commits += n;
    }

    // after the evaluation: the outputs; the next step of the session
    void sample(T* d)
    {
        if (b.done()) return;
        Lockstep* r = b.refp();
        bool halted = d->hart_halted;
        if (halted) b.touch();
        if (r) r->step_no_irq(stepping && (st == RESUMING || st == HALTING));   // (dcsr.stepie 0: the stepped instruction alone)
        switch (st) {
        case IDLE:
            if (halted) { st = SESSION; allow = (1 << 1) | (1 << 2); sessions++; plan(r, true); break; }    // (its own: EBREAK, a trigger)
            if (--wait <= 0) { haltreq = true; st = HALTING; tmo = 200000; allow = (1 << 3) | (1 << 1) | (1 << 2); }
            break;
        case HALTING:
            if (halted) {
                haltreq = false; st = SESSION;
                if (rh) { rh = false; resets++; }
                if (stepping) plan(r, false); else { sessions++; plan(r, true); }
            }
            else if (--tmo == 0) b.dbg_fail("debugger: no halt within 200,000 cycles");
            break;
        case SESSION:
            if (busy) {
                bool ack = d->reg_ack, err = d->reg_err; uint64_t rd = d->reg_rdata;
#ifdef CPU_TOP
                if (q.front().k == RMEM || q.front().k == WMEM) { ack = d->bm_ack; err = d->bm_err != 0; rd = d->bm_rdata; }
#endif
                if (!ack) break;
                busy = false;
                Act a = q.front(); q.pop_front();
                if (verbose) std::printf("dbg: ack err %d rdata %llx\n", (int)err, (unsigned long long)rd);
                if (err != a.err) { fail(a, std::string("error ") + (err ? "1" : "0") + ", expected " + (a.err ? "1" : "0")); return; }
                if (!err && a.chk) {
                    uint64_t m = a.mask;
                    if ((rd & m) != (a.v & m)) { fail(a, "read " + hex(rd & m) + ", expected " + hex(a.v & m)); return; }
                }
                if (a.k == RREG && a.regno == 0x7b0 && !a.chk) dcsr = rd;
                if (a.k == RREG && a.regno == 0x7b1) dpc = rd;
                if (a.k == RREG && a.regno == 0x7a0 && !a.chk) tsel = rd;
                if (a.sv == 1) t1s = rd;
                if (a.sv == 2) t2s = rd;
                if (a.sv == 3) mip_s = rd;
                if (a.sv == 4) mie_s = rd;
                if (a.sv == 5) mst_s = rd;
                if (a.sv == 6) mip_c = rd;
                if (a.sv == 7) mie_c = rd;
                if (a.sv == 8) mst_c = rd;
                if (a.k == RREG || a.k == WREG) regs++; else mems++;
            }
            if (!busy && !q.empty()) {
                Act& a = q.front();
                if (a.k == FIX) { Act f = a; q.pop_front(); if (!fixup(f, r)) return; }   // what the next accesses need, from what came back
                else if (a.k == STEP || a.k == RESUME) {
                    bool stp = a.k == STEP; q.pop_front();
                    resumereq = true; st = RESUMING; tmo = 200000; allow = (1 << 4) | (1 << 1) | (1 << 2); stepping = stp;
                    st_commits = 0; st_traps = 0;
                    if (verbose) std::printf("dbg: %s\n", stp ? "step" : "resume");
                    if (stp) steps++;
                } else issue = true;
            }
            break;
        case RESUMING:
            if (!halted) { st = stepping ? HALTING : IDLE; wait = 1 + (long)(rng() % (2 * every)); }
            else if (--tmo == 0) b.dbg_fail("debugger: no resume within 200,000 cycles");
            break;
        }
    }

private:
    enum Kind { RREG, WREG, RMEM, WMEM, FIX, STEP, RESUME };
    struct Act {
        Kind k; uint16_t regno = 0; bool s64 = true; uint64_t v = 0, mask = ~0ull; uint64_t addr = 0; int size = 3;
        bool chk = false, err = false; int fix = 0, sv = 0;   // (sv: a read kept, 1 tdata1, 2 tdata2)
    };
    enum St { IDLE, HALTING, SESSION, RESUMING };
    Bench& b;
    std::mt19937_64 rng;
    long every, wait = 0, tmo = 0;
    bool mem;
    int feats;
    uint64_t eb = 0;                   // the dcsr.ebreak* bits set from the first halt on
    bool rh = false;                   // resethaltreq (this run)
    bool tarm = false;
    bool irq_on = false;               // SSIP made pending for the steps (feats 8)
    uint64_t mip_s = 0, mie_s = 0, mst_s = 0;          // (the core's, by the port)
    uint64_t rmip_s = 0, rmie_s = 0, rmst_s = 0;       // (the reference's own: the two CSR files differ in fields)
    uint64_t mip_c = 0, mie_c = 0, mst_c = 0;          // (the core's after the steps: a stepped instruction may write them)
    long st_commits = 0, st_traps = 0; // a step's (trace())                 // the debugger's trigger is in trigger 3 (a haltreq can come first: it stays)
    uint64_t dpc = 0, tsel = 0, t1s = 0, t2s = 0;    // (t1s, t2s: the program's trigger 3, kept while the debugger's is there)
    int allow = 1 << 3;                // the halt's possible causes
    bool verbose = std::getenv("DBGV") != nullptr;     // (DBGV=1: each access printed)
    St st = IDLE;
    bool haltreq = false, resumereq = false, issue = false, busy = false, stepping = false;
    uint64_t dcsr = 0, uc_line = ~0ull, text = 0, data = 0;
    std::deque<Act> q;

    static std::string hex(uint64_t v) { char s[24]; std::snprintf(s, sizeof s, "%llx", (unsigned long long)v); return s; }
    void fail(const Act& a, const std::string& why)
    {
        static const char* K[] = {"register read", "register write", "memory read", "memory write", "", "", ""};
        b.dbg_fail("debugger: " + std::string(K[a.k]) + " " + hex(a.k <= WREG ? a.regno : a.addr) + ": " + why);
    }
    Act rd(uint16_t n, bool s64, uint64_t expect, bool chk = true)
    {
        Act a; a.k = RREG; a.regno = n; a.s64 = s64; a.v = expect; a.chk = chk; a.mask = s64 ? ~0ull : 0xffffffffull; return a;
    }
    Act wr(uint16_t n, bool s64, uint64_t v) { Act a; a.k = WREG; a.regno = n; a.s64 = s64; a.v = v; return a; }

    // what the reference has, by register number (a GPR, an FPR, a CSR)
    uint64_t refv(Lockstep* r, uint16_t n)
    {
        uint64_t v = 0;
        if (n >= 0x1000 && n < 0x1020) return r->x(n - 0x1000);
        if (n >= 0x1020 && n < 0x1040) return r->f(n - 0x1020);
        r->csr(n, &v); return v;
    }
    void put(Lockstep* r, uint16_t n, uint64_t v)
    {
        if (n >= 0x1000 && n < 0x1020) r->set_x(n - 0x1000, v);
        else if (n >= 0x1020 && n < 0x1040) r->set_f(n - 0x1020, v);
        else r->set_csr(n, v);
    }

    void plan(Lockstep* r, bool full)
    {
        q.clear();
        q.push_back(rd(0x7b1, true, r ? r->pc() : 0, r != nullptr));           // dpc
        q.push_back(rd(0x7b0, true, 0, false));                                // dcsr (its cause: FIX 3)
        q.push_back(rd(0x7a0, true, 0, false));                                // tselect (as the program left it)
        { Act f; f.k = FIX; f.fix = 3; q.push_back(f); }
        int nops = full ? 1 + (int)(rng() % 5) : (int)(rng() % 2);
        if (r && r->pending()) nops = 0;    // (the reference is past the next instruction: no register to check or put)
        for (int i = 0; i < nops && r; i++) {
            int kind = (int)(rng() % (mem ? 9 : 7));
            bool s64 = rng() % 3 != 0;
            uint64_t v = rng();
            switch (kind) {
            case 0: { uint16_t n = 0x1000 + (uint16_t)(rng() % 32); q.push_back(rd(n, s64, refv(r, n))); break; }
            case 1: { uint16_t n = 0x1020 + (uint16_t)(rng() % 32); q.push_back(rd(n, s64, refv(r, n))); break; }
            case 2: case 3: {                                              // a GPR (FPR if FS is on) written and back
                bool fp = kind == 3 && r->fs_on();
                uint16_t n = (fp ? 0x1020 : 0x1000) + (uint16_t)(fp ? rng() % 32 : 1 + rng() % 31);
                uint64_t o = refv(r, n), nv = s64 ? v : ((o & ~0xffffffffull) | (v & 0xffffffffull));
                q.push_back(wr(n, s64, v)); put(r, n, nv);
                q.push_back(rd(n, true, nv));
                q.push_back(wr(n, true, o)); put(r, n, o);
                // (the reference was set to the last value now: the checks above were taken from it in turn)
                break;
            }
            case 4: {                                                      // a CSR both keep alike
                static const uint16_t C[] = {0x340, 0x140, 0x341, 0x141, 0x305, 0x105, 0x342, 0x142, 0x343, 0x143, 0x180,
                                             0x302, 0x303, 0x304, 0xB02};   // (minstret: debug mode's sequences not counted)
                uint16_t n = C[rng() % (sizeof C / sizeof C[0])]; q.push_back(rd(n, true, refv(r, n)));
                break;
            }
            case 5: {                                                      // mscratch / sscratch written and back
                uint16_t n = rng() & 1 ? 0x340 : 0x140; uint64_t o = refv(r, n);
                q.push_back(wr(n, true, v)); put(r, n, v);
                q.push_back(rd(n, true, v));
                q.push_back(wr(n, true, o)); put(r, n, o);
                break;
            }
            case 6: {                                                      // errors
                Act a;
                switch (rng() % 3) {
                case 0: a = rd(0x7c0, true, 0, false); break;              // no such CSR
                case 1: a = wr(0xf14, true, v); break;                     // mhartid: read-only
                default: a = rd(0x1040 + (uint16_t)(rng() % 64), true, 0, false); break;   // past the FPRs
                }
                a.err = true; a.chk = false; q.push_back(a);
                break;
            }
            default: {                                                     // memory (OOO_CPU)
                int size = (int)(rng() % 4);
                uint64_t base = (rng() & 1) || !data ? text : data - 4096;
                uint64_t addr = (base + (rng() % 8192)) & ~((1ull << size) - 1);
                uint64_t o;
                if ((addr >> 6) == uc_line || !r->peek(addr, 1 << size, &o)) break;
                Act a; a.k = RMEM; a.addr = addr; a.size = size; a.v = o; a.chk = true;
                a.mask = size == 3 ? ~0ull : ((1ull << (8 << size)) - 1);
                q.push_back(a);
                if (kind == 8) {
                    uint64_t nv = v & a.mask;
                    Act w = a; w.k = WMEM; w.v = nv; w.chk = false; q.push_back(w); poke(r, addr, size, nv);
                    Act c = a; c.v = nv; q.push_back(c);
                    Act x = a; x.k = WMEM; x.v = o; x.chk = false; q.push_back(x); poke(r, addr, size, o);
                }
                break;
            }
            }
        }
        // a resume, or a step (dcsr.step set: dcsr read, then written with bit 2)
        int nstep = (rng() % 10 < 3) ? 1 + (int)(rng() % 3) : 0;
        if (!full) nstep = stepping_left;
        if (full) stepping_left = nstep;
        if (stepping_left > 0) {
            if (full && (feats & 8) && rng() % 3 == 0) {                   // SSIP pending through the steps
                { Act a = rd(0x344, true, 0, false); a.sv = 3; q.push_back(a); }
                { Act a = rd(0x304, true, 0, false); a.sv = 4; q.push_back(a); }
                { Act a = rd(0x300, true, 0, false); a.sv = 5; q.push_back(a); }
                { Act f; f.k = FIX; f.fix = 5; q.push_back(f); }
            }
            q.push_back(rd(0x7b0, true, 0, false));
            { Act f; f.k = FIX; f.fix = 1; q.push_back(f); }               // dcsr | step
            stepping_left--;
            { Act s; s.k = STEP; q.push_back(s); }
        } else {
            if (irq_on) {                                                  // SSIP and its enables back: those bits alone
                { Act a = rd(0x344, true, 0, false); a.sv = 6; q.push_back(a); }
                { Act a = rd(0x304, true, 0, false); a.sv = 7; q.push_back(a); }
                { Act a = rd(0x300, true, 0, false); a.sv = 8; q.push_back(a); }
                { Act f; f.k = FIX; f.fix = 6; q.push_back(f); }
            }
            q.push_back(rd(0x7b0, true, 0, false));
            { Act f; f.k = FIX; f.fix = 2; q.push_back(f); }               // dcsr & ~step
            if ((feats & 2) && full && rng() % 6 == 0) { Act f; f.k = FIX; f.fix = 4; q.push_back(f); }   // a trigger on dpc
            { Act s; s.k = RESUME; q.push_back(s); }
        }
    }
    int stepping_left = 0;
    void poke(Lockstep* r, uint64_t a, int size, uint64_t v)
    {
        r->poke(a, 1 << size, v);
        b.arch().write(a, &v, 1 << size);
    }
    // from what came back: 1 / 2 dcsr written with step set / cleared (and the ebreak bits); 3 the halt's cause checked,
    // an EBREAK stepped over (cause 1), the debugger's trigger cleared (cause 2); 4 the debugger's trigger set on dpc
    static const uint64_t TD1 = (2ull << 60) | (1ull << 59) | (1ull << 12) | (1ull << 6) | (1ull << 4) | (1ull << 3) | (1ull << 2);
    bool fixup(const Act& f, Lockstep* r)
    {
        std::deque<Act> v;
        if (f.fix == 1 || f.fix == 2) {
            if (feats & 1) {                                                // the ebreak bits drawn again
                static const uint64_t E[] = {1u << 15, 1u << 13, 1u << 12};
                eb = 0; for (auto e : E) if (rng() & 1) eb |= e;
            }
            uint64_t d = (dcsr & ~(4ull | (1ull << 15) | (1ull << 13) | (1ull << 12))) | eb | (f.fix == 1 ? 4 : 0);
            v.push_back(wr(0x7b0, true, d));
        } else if (f.fix == 3) {
            int cause = (int)((dcsr >> 6) & 7), prv = (int)(dcsr & 3);
            if (!((allow >> cause) & 1)) { b.dbg_fail("debugger: dcsr.cause " + std::to_string(cause) + ", not one this halt may have"); return false; }
            if (cause == 1 && !((eb >> (prv == 3 ? 15 : prv == 1 ? 13 : 12)) & 1)) {
                b.dbg_fail("debugger: an EBREAK halted at level " + std::to_string(prv) + " without its dcsr.ebreak bit"); return false;
            }
            if (allow & (1 << 4)) {                                         // after a step
                bool ok = cause == 4 ? ((st_commits == 1 && st_traps == 0) || (st_commits == 0 && st_traps == 1))
                                     : (st_commits == 0 && st_traps == 0);
                if (!ok) { b.dbg_fail("debugger: a step of " + std::to_string(st_commits) + " instructions and " + std::to_string(st_traps) +
                                      " traps (cause " + std::to_string(cause) + ")"); return false; }
            }
            if (cause == 1 && r) {                                          // past the EBREAK, in both
                uint32_t in = r->next_insn();
                if ((in & 0x7f) != 0x73 && (in & 0xffff) != 0x9002) { b.dbg_fail("debugger: cause 1, not at an EBREAK"); return false; }
                int len = (in & 3) == 3 ? 4 : 2;
                r->set_pc(r->pc() + len);
                v.push_back(wr(0x7b1, true, dpc + len));
                ebreaks++;
            }
            if (cause == 2 && tarm) {                                       // the debugger's trigger: the program's back
                tarm = false;
                v.push_back(wr(0x7a0, true, 3)); v.push_back(wr(0x7a1, true, 0)); v.push_back(wr(0x7a2, true, t2s));
                v.push_back(wr(0x7a1, true, t1s)); v.push_back(wr(0x7a0, true, tsel));
                trigs++;
            }
        } else if (f.fix == 5 && r) {                                     // SSIP pending, enabled at every level
            irq_on = true;
            r->csr(0x344, &rmip_s); r->csr(0x304, &rmie_s); r->csr(0x300, &rmst_s);
            v.push_back(wr(0x344, true, mip_s | 2)); r->set_csr(0x344, rmip_s | 2);
            v.push_back(wr(0x304, true, mie_s | 2)); r->set_csr(0x304, rmie_s | 2);
            v.push_back(wr(0x300, true, mst_s | 8)); r->set_csr(0x300, rmst_s | 8);
        } else if (f.fix == 6 && r) {
            irq_on = false;
            uint64_t a = 0, m = 0, t = 0;
            r->csr(0x344, &a); r->csr(0x304, &m); r->csr(0x300, &t);
            v.push_back(wr(0x344, true, (mip_c & ~2ull) | (mip_s & 2))); r->set_csr(0x344, (a & ~2ull) | (rmip_s & 2));
            v.push_back(wr(0x304, true, (mie_c & ~2ull) | (mie_s & 2))); r->set_csr(0x304, (m & ~2ull) | (rmie_s & 2));
            v.push_back(wr(0x300, true, (mst_c & ~8ull) | (mst_s & 8))); r->set_csr(0x300, (t & ~8ull) | (rmst_s & 8));
        } else if (f.fix == 4 && !tarm) {
            tarm = true;
            v.push_back(wr(0x7a0, true, 3));
            { Act a = rd(0x7a1, true, 0, false); a.sv = 1; v.push_back(a); }   // (the program's trigger 3 kept)
            { Act a = rd(0x7a2, true, 0, false); a.sv = 2; v.push_back(a); }
            v.push_back(wr(0x7a2, true, dpc)); v.push_back(wr(0x7a1, true, TD1));
            v.push_back(wr(0x7a0, true, tsel));
        }
        for (auto it = v.rbegin(); it != v.rend(); ++it) q.push_front(*it);
        return true;
    }
};
