//---------------------------------------------------------------------------
// tb_trap.cpp : OOO_TRAP (exceptions and interrupts at the ROB head) inside
// a model of the ROB (24 entries)
//
// µops are dispatched in order (some fused pairs, some with an exception),
// complete out of order (an exception with its tval, on one of the three
// tval ports), and commit in order from the head (1 or 2 instructions each).
// Now and then: a restore at a µop in the ROB (the younger ones go), a
// replay at a commit, an MRET run at the head (x_mret) before its replayed
// commit, a non-speculative µop at the head that has issued (ns_busy), a
// pending interrupt (irq_pend, random cause), mtvec direct or vectored. A
// trap or an interrupt empties the model ROB, and OOO_CTRL's flush_all
// comes the cycle after. Completions of µops flushed or killed still on
// their way are sent in the cycles of flush_all and of a restore.
//
// Checked every cycle against the rules (Doc/UARCH.md 3.8):
//   - irq exactly when an interrupt is pending, a µop is at the head and it
//     is not a non-speculative µop that has issued; it wins over the head's
//     exception
//   - an exception at the head of a single µop: the trap with mepc = its
//     pc, its cause, mtval = the tval it reported, fetch from mtvec's base
//   - an exception in a fused pair: no CSR written, fetch again from its pc,
//     no_fuse until two instructions have committed or the next trap
//   - an interrupt: mcause with the interrupt bit, mtval 0, mtvec's base
//     (+ 4 x cause when vectored)
//   - a replay goes to replay_pc, but to mepc (with csr_mret) after an MRET
//---------------------------------------------------------------------------
#include "VOOO_TRAP.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <vector>
#include <algorithm>

static std::mt19937_64 rng(61);
static VOOO_TRAP d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const int NROB = 24;
static const uint64_t AM = (1ull << 38) - 1;
struct Uop { int idx; uint64_t pc; bool fused, exc, done = false, reported = false; int cause; uint64_t tval; };

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("TRAP_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    std::deque<Uop> rob;
    int head = 0;                               // the head's index (the next µop's when empty)
    bool flush_next = false, x_pend = false, nf = false; int nf_cnt = 0;
    long ntrap = 0, nrefetch = 0, nirq = 0, nmret = 0, nstale = 0, ntval = 0, nnf_clear = 0;
    uint64_t mtvec = (rng() & AM) << 1, mepc = rng() & AM;

    for (cyc = 0; cyc < 400000; cyc++) {
        if (rng() % 500 == 0) mtvec = ((rng() & AM) << 1) | (rng() & 1);
        if (rng() % 50 == 0) mepc = rng() & AM;
        bool flush_all = flush_next; flush_next = false;
        // ---- completions: some live µops, with their tval when they have an exception
        uint32_t tvv = 0, tvr = 0; uint64_t tvd[3] = {0, 0, 0};
        int used_port = 0;
        std::vector<int> fin;                    // completed now: done from the next cycle (the ROB's register)
        for (auto& u : rob) {
            if (u.done || rng() % 4 || used_port >= 3) continue;
            if (u.exc) { tvv |= 1u << used_port; tvr |= (uint32_t)u.idx << (5 * used_port); tvd[used_port] = u.tval; used_port++; u.reported = true; }
            fin.push_back(u.idx);
        }
        // stale reports: of µops just flushed (in flush_all's cycle) or killed (in a restore's)
        bool restore = false; int restore_rob = 0; size_t rpos = 0;
        // a restore at a branch resolving now (not done yet, so it does not commit now)
        if (!flush_all && rob.size() >= 2 && rng() % 20 == 0) {
            rpos = rng() % (rob.size() - 1);
            if (!rob[rpos].done && !rob[rpos].exc && std::find(fin.begin(), fin.end(), rob[rpos].idx) == fin.end()) { restore = true; restore_rob = rob[rpos].idx; fin.push_back(restore_rob); }
        }
        if ((flush_all || restore) && used_port < 3 && rng() % 2) {
            // (a killed µop is one after the restored branch; after a flush any index is dead)
            int idx = restore ? rob[rpos + 1 + rng() % (rob.size() - rpos - 1)].idx : (int)(rng() % NROB);
            tvv |= 1u << used_port; tvr |= (uint32_t)idx << (5 * used_port); tvd[used_port] = rng(); used_port++; nstale++;
        }
        // ---- the head and the cycle's events
        bool hv = !rob.empty();
        Uop h = hv ? rob.front() : Uop{head, 0, false, false};
        bool rob_trap = hv && h.done && h.exc;
        bool ns_busy = hv && rng() % 6 == 0;
        bool irq_pend = rng() % 30 == 0; int icause = rng() % 16;
        bool x_mret = hv && !rob_trap && !x_pend && rng() % 80 == 0;   // the MRET at the head runs
        // commits (only when nothing traps), with a replay now and then
        bool irq_exp = irq_pend && hv && !ns_busy;
        int ncm = 0, instret = 0; bool replay = false; uint64_t rpc = rng() & AM;
        if (!irq_exp && !rob_trap && !flush_all && x_pend) {
            // the MRET commits alone, marked for replay
            if (h.done && !h.exc && rng() % 2) { ncm = 1; instret = h.fused ? 2 : 1; replay = true; }
        } else if (!irq_exp && !rob_trap && !flush_all) {
            for (size_t k = 0; k < 2 && k < rob.size(); k++) {
                Uop& u = rob[k];
                if (!u.done || u.exc || rng() % 3 == 0) break;
                ncm++; instret += u.fused ? 2 : 1;
                if (rng() % 15 == 0) { replay = true; break; }
            }
        }

        d.rob_trap = rob_trap; d.rob_cause = h.cause; d.rob_pc = h.pc; d.head_valid = hv; d.head_fused = h.fused;
        d.head_rob = h.idx; d.rob_replay = replay; d.rob_replay_pc = rpc; d.cmt_instret = instret;
        d.restore = restore; d.restore_rob = restore_rob; d.ns_busy = ns_busy; d.flush_all = flush_all;
        d.x_mret = x_mret; d.tv_valid = tvv; d.tv_rob = tvr;
        for (int k = 0; k < 3; k++) { d.tv_val[2 * k] = (uint32_t)tvd[k]; d.tv_val[2 * k + 1] = (uint32_t)(tvd[k] >> 32); }
        d.irq_pend = irq_pend; d.irq_cause = icause; d.mtvec = mtvec; d.mepc = mepc;
        d.eval();

        // ---- what must happen
        bool exc = rob_trap && !irq_exp;
        bool refetch = exc && h.fused;
        bool take = irq_exp || exc;
        uint64_t base = (mtvec >> 1) & ~1ull & AM;
        uint64_t vec = refetch ? h.pc : (irq_exp && (mtvec & 3) == 1) ? (base + 2 * (uint64_t)icause) & AM : base;
        if ((bool)d.irq != irq_exp) FAIL("irq %d, expected %d", (int)d.irq, irq_exp);
        if ((bool)d.take != take) FAIL("take %d, expected %d", (int)d.take, take);
        if (take && (uint64_t)d.vec != vec) FAIL("vec %llx, expected %llx (%s)", (unsigned long long)d.vec, (unsigned long long)vec, refetch ? "refetch" : irq_exp ? "interrupt" : "exception");
        bool ctrap = irq_exp || (exc && !h.fused);
        if ((bool)d.csr_trap != ctrap) FAIL("csr_trap %d, expected %d", (int)d.csr_trap, ctrap);
        if (ctrap) {
            if ((uint64_t)d.csr_epc != h.pc) FAIL("mepc %llx, expected %llx", (unsigned long long)d.csr_epc, (unsigned long long)h.pc);
            if ((bool)d.csr_int != irq_exp || (int)d.csr_cause != (irq_exp ? icause : h.cause)) FAIL("mcause %d/%d, expected %d/%d", (int)d.csr_int, (int)d.csr_cause, irq_exp, irq_exp ? icause : h.cause);
            uint64_t tv = irq_exp ? 0 : h.tval;
            if ((uint64_t)d.csr_tval != tv) FAIL("mtval %llx, expected %llx", (unsigned long long)d.csr_tval, (unsigned long long)tv);
            if (!irq_exp) ntval++;
        }
        if (replay) {
            uint64_t e = x_pend ? mepc : rpc;
            if ((uint64_t)d.rp_pc != e) FAIL("replay pc %llx, expected %llx (mret %d)", (unsigned long long)d.rp_pc, (unsigned long long)e, x_pend);
        }
        if ((bool)d.csr_mret != (replay && x_pend)) FAIL("csr_mret %d, expected %d", (int)d.csr_mret, replay && x_pend);
        if ((bool)d.no_fuse != nf) FAIL("no_fuse %d, expected %d", (int)d.no_fuse, nf);

        d.clk = 1; d.eval(); d.clk = 0; d.eval();

        // ---- the model after the edge
        for (auto& u : rob) for (int i : fin) if (u.idx == i) u.done = true;
        if (x_mret) x_pend = true; else if (replay || flush_all) { if (replay && x_pend) nmret++; x_pend = false; }
        if (refetch) { nf = true; nf_cnt = 0; nrefetch++; }
        else if (take) { if (nf) nnf_clear++; nf = false; }
        else if (nf) { if (nf_cnt + instret >= 2) nf = false; nf_cnt += instret; }
        if (take) {
            if (irq_exp) nirq++; else if (!refetch) ntrap++;
            rob.clear(); flush_next = true;
        } else {
            for (int k = 0; k < ncm; k++) { rob.pop_front(); head = (head + 1) % NROB; }
            if (replay) { rob.clear(); flush_next = true; }
            else if (restore) {
                // the µops after the restored branch go (if it has not committed now)
                int ri = -1; for (size_t k = 0; k < rob.size(); k++) if (rob[k].idx == restore_rob) ri = (int)k;
                if (ri >= 0) rob.resize(ri + 1);
            }
            // dispatch (not in a cycle of recovery)
            if (!flush_all && !replay && !restore)
                for (int k = 0; k < 2 && rob.size() < (size_t)NROB; k++) {
                    if (rng() % 3 == 0) break;
                    Uop u; u.idx = (head + (int)rob.size()) % NROB; u.pc = rng() & AM; u.fused = rng() % 4 == 0;
                    u.exc = rng() % 12 == 0; u.cause = rng() % 16; u.tval = rng();
                    rob.push_back(u);
                }
        }
    }
    printf("tb_trap: %ld cycles, %ld traps (%ld with mtval checked), %ld refetches with fusion off (%ld cut by a trap), %ld interrupts, %ld MRET replays, %ld stale tval reports, %ld mismatches: %s\n",
           cyc, ntrap, ntval, nrefetch, nnf_clear, nirq, nmret, nstale, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
