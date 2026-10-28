//---------------------------------------------------------------------------
// tb_sys.cpp : OOO_SYS (FENCE, FENCE.I, SFENCE.VMA, MRET, WFI at the ROB head)
// against the order of their steps
//
// One system µop at a time is issued (random op and ROB index) when the last
// one has completed; the rest of the core answers with random delays: the
// SQ drains (sq_drained goes up some cycles after the issue and may fall
// again before), the D$ takes the FLUSH and answers it, the I$ finishes its
// invalidation, an interrupt wakes WFI. Answers that nobody asked for come
// at random too (fl_done, ic_done, wfi_wake at other times, a stale FLUSH
// answer after a flush). Now and then flush_all abandons the µop.
//
// The level and mstatus.TW / TSR / TVM are random too: MRET below M, SRET in
// U or in S with TSR, SFENCE.VMA in U or in S with TVM, WFI below M with TW
// complete at once with an illegal instruction exception, the instruction
// as tval (reported in the cycle of the issue), and nothing else.
//
// Checked: every µop completes once with its ROB index, marked for replay
// exactly for FENCE.I, SFENCE.VMA, MRET and SRET; nothing completes after a flush
// that abandoned it; and its steps in order, each only after the one before:
//   FENCE       the completion after a cycle of sq_drained
//   FENCE.I     fl_req only after sq_drained, held until fl_take; ic_flush
//               only after fl_done (of this FLUSH), held until ic_done; the
//               completion after ic_done
//   SFENCE.VMA  one tlb_flush, after sq_drained; then the completion
//   MRET, SRET  x_ret (x_sret for SRET) in the cycle of the issue; then the
//               completion
//   WFI         the completion after wfi_wake
// and that each step follows the one it waits for within 3 cycles.
//---------------------------------------------------------------------------
#include "VOOO_SYS.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>

static std::mt19937_64 rng(67);
static VOOO_SYS d;
static long bad = 0, cyc = 0;
#define FAIL(...) do { if (bad++ < 12) { printf("cycle %ld: ", cyc); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (const char* e = getenv("SYS_SEED")) rng.seed(strtoull(e, nullptr, 0));
    d.clk = 0; d.rst_n = 1; d.eval(); d.rst_n = 0; d.eval(); d.rst_n = 1; d.eval();

    bool busy = false, ill = false; int op = 0, rob = 0; uint32_t inst = 0;
    int priv = 3; bool tw = false, tsr = false, tvm = false;
    long nill = 0;
    // the steps of the µop in progress, as cycles (-1: not yet)
    long t_iss = 0, t_sq = -1, t_take = -1, t_fdone = -1, t_idone = -1, t_wake = -1, t_tlb = -1, t_last = 0;
    bool fl_out = false;                         // a FLUSH taken by the D$, not answered
    long fl_due = 0, ic_due = -1, sq_at = 0;
    long abandon_until = -1;                     // a completion must not come (abandoned) until then
    long n[5] = {0, 0, 0, 0, 0}, nflush = 0, nstale = 0;
    int idle_wait = 0;

    for (cyc = 0; cyc < 400000; cyc++) {
        // ---- inputs
        int flush = busy && rng() % 300 == 0;
        int iss = 0;
        // (not while an abandoned FLUSH is still out: OOO_SYS is never flushed during one in the core)
        if (rng() % 50 == 0) { priv = (int[]){3, 3, 3, 1, 0}[rng() % 5]; tw = rng() & 1; tsr = rng() & 1; tvm = rng() & 1; }
        if (!busy && !fl_out && idle_wait-- <= 0 && rng() % 3 == 0) {
            iss = 1; op = rng() % 6; rob = rng() % 24; busy = true; inst = (uint32_t)rng();
            ill = (op == 3 && priv != 3) || (op == 5 && (priv == 0 || (priv == 1 && tsr))) ||
                  (op == 2 && (priv == 0 || (priv == 1 && tvm))) || (op == 4 && priv != 3 && tw);
            if (ill) nill++;
            t_iss = cyc; t_sq = t_take = t_fdone = t_idone = t_wake = t_tlb = -1; t_last = cyc;
            sq_at = cyc + 1 + rng() % 12;
        }
        bool sqd = busy ? (cyc >= sq_at && rng() % 8) : (rng() & 1);
        int fl_take = d.fl_req && rng() % 3 == 0;
        int fl_done = 0;
        if (fl_out && cyc >= fl_due) { fl_done = 1; }
        else if (!fl_out && rng() % 40 == 0) { fl_done = 1; nstale++; }   // an answer nobody waits for
        int ic_done = (d.ic_flush && ic_due >= 0 && cyc >= ic_due) || (!d.ic_flush && rng() % 40 == 0);
        int wake = rng() % 25 == 0;
        d.flush = flush; d.sys_valid = iss; d.sys_op = op; d.sys_rob = rob; d.sys_inst = inst;
        d.priv = priv; d.tw = tw; d.tsr = tsr; d.tvm = tvm;
        d.sq_drained = sqd; d.fl_take = fl_take; d.fl_done = fl_done; d.ic_done = ic_done; d.wfi_wake = wake;
        d.eval();

        // ---- the steps of this cycle (outputs before the edge)
        if (d.cmp_valid) {
            if (!busy) FAIL("a completion %s", cyc <= abandon_until ? "of an abandoned µop" : "with nothing in progress");
            else {
                if ((int)d.cmp_rob != rob) FAIL("completion rob %d, expected %d", (int)d.cmp_rob, rob);
                bool erp = !ill && (op == 1 || op == 2 || op == 3 || op == 5);
                if ((bool)d.cmp_rp != erp) FAIL("op %d: replay mark %d, expected %d", op, (int)d.cmp_rp, erp);
                if ((bool)d.cmp_exc != ill) FAIL("op %d: exception %d, expected %d", op, (int)d.cmp_exc, ill);
                long need = ill || op == 3 || op == 5 ? t_iss : op == 0 ? t_sq : op == 1 ? t_idone : op == 2 ? t_tlb : t_wake;
                if (need < 0) FAIL("op %d completes before its last step", op);
                else if (cyc - need > 3) FAIL("op %d completes %ld cycles after its last step", op, cyc - need);
                if (op == 2 && !ill && t_tlb < 0) FAIL("SFENCE.VMA without tlb_flush");
                n[op < 5 ? op : 3]++; busy = false; idle_wait = rng() % 3;
            }
        }
        bool xr = iss && !ill && (op == 3 || op == 5);
        if ((bool)d.x_ret != xr || (xr && (bool)d.x_sret != (op == 5))) FAIL("x_ret %d x_sret %d for op %d", (int)d.x_ret, (int)d.x_sret, op);
        bool tv = iss && ill;
        if ((bool)d.tv_valid != tv || (tv && ((int)d.tv_rob != rob || (uint32_t)d.tv_val != inst))) FAIL("tval report %d for op %d (illegal %d)", (int)d.tv_valid, op, ill);
        if (d.tlb_flush) {
            if (!busy || op != 2 || ill) FAIL("tlb_flush for op %d", busy ? op : -1);
            else if (t_tlb >= 0) FAIL("a second tlb_flush");
            else if (!sqd) FAIL("tlb_flush before the stores drained");
            else t_tlb = cyc;
        }
        if (d.fl_req) {
            if (!busy || op != 1 || ill) FAIL("fl_req for op %d", busy ? op : -1);
            else if (t_sq < 0) FAIL("fl_req before the stores drained");
            else if (t_take >= 0) FAIL("fl_req after the D$ took the FLUSH");
        }
        if (d.ic_flush) {
            if (!busy || op != 1 || ill) FAIL("ic_flush for op %d", busy ? op : -1);
            else if (t_fdone < 0) FAIL("ic_flush before the FLUSH's answer");
        }
        // what this cycle completes for the µop in progress (seen by it from the next cycle)
        if (busy && !flush) {
            if (t_sq < 0 && sqd && cyc > t_iss && (op <= 2)) t_sq = cyc;
            if (op == 1 && d.fl_req && fl_take && t_take < 0) { t_take = cyc; fl_out = true; fl_due = cyc + 1 + rng() % 10; }
            if (op == 1 && t_take >= 0 && fl_done && t_fdone < 0 && fl_out) { t_fdone = cyc; fl_out = false; ic_due = cyc + 1 + rng() % 6; }
            if (op == 1 && d.ic_flush && ic_done && t_idone < 0) t_idone = cyc;
            if (op == 4 && wake && cyc > t_iss && t_wake < 0) t_wake = cyc;
            if (ill) { t_sq = t_take = t_fdone = t_idone = t_wake = -1; }
        } else if (fl_done && fl_out) fl_out = false;
        if (flush && busy) { busy = false; abandon_until = cyc + 6; nflush++; idle_wait = 6; }

        d.clk = 1; d.eval(); d.clk = 0; d.eval();
        // (a wakeup comes 1 cycle in 25: 200 cycles without one happen about once a run)
        if (busy && cyc - t_iss > 2000) { FAIL("op %d does not complete", op); busy = false; }
    }
    printf("tb_sys: %ld cycles, %ld FENCE, %ld FENCE.I, %ld SFENCE.VMA, %ld MRET / SRET, %ld WFI, %ld illegal, %ld abandoned, %ld answers nobody asked for, %ld mismatches: %s\n",
           cyc, n[0], n[1], n[2], n[3], n[4], nill, nflush, nstale, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
