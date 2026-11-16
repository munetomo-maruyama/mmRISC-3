// tb_plic_eq.cpp : 4 million cycles of random register accesses and sources; irq and rdata compared every cycle
#include "Vtb_plic_eq.h"
#include <cstdio>
#include <random>
int main() {
    Vtb_plic_eq t; std::mt19937_64 r(12345);
    t.clk = 0; t.rst_n = 0; t.eval(); t.rst_n = 1; t.eval();
    long bad = 0, irqs = 0, claims = 0;
    for (long cyc = 0; cyc < 4000000; cyc++) {
        unsigned k = r() % 16;
        unsigned ctx = r() % 2;
        t.sel = (r() % 3) != 0; t.we = r() % 2; t.wstrb = 0xff;
        uint64_t w = r(); 
        if (k < 5)       t.addr = 4 * (r() % 34);                    // priorities (0, 1..31, 32, 33)
        else if (k < 6)  t.addr = 0x1000 + 4 * (r() % 2);            // pending
        else if (k < 8)  t.addr = 0x2000 + 0x80 * (r() % 3) + 4 * (r() % 2);   // enables
        else if (k < 10) t.addr = 0x200000 + 0x1000 * ctx;           // threshold
        else if (k < 15) t.addr = 0x200004 + 0x1000 * ctx;           // claim / complete
        else             t.addr = r() & 0x3fffff;
        if ((t.addr % 0x1000) == 4 && t.addr >= 0x200000 && t.we) w = (r() % 34) | ((r() % 34) << 32);   // a completion of some id
        else if (t.addr < 0x1000 || (t.addr >= 0x200000)) w = (r() % 8) | ((r() % 8) << 32);              // small priorities / thresholds (0..7)
        if (r() % 8 == 0) w = 0;
        t.wdata = w;
        if (r() % 4 == 0) t.src = (uint32_t)r() & (uint32_t)r();
        t.eval();
        if (t.rd_new != t.rd_old || t.irq_new != t.irq_old) {
            if (bad++ < 10) printf("cycle %ld addr %06x: rdata %016lx / %016lx irq %d / %d\n", cyc, t.addr, t.rd_new, t.rd_old, t.irq_new, t.irq_old);
        }
        if (t.irq_new) irqs++;
        if (t.sel && !t.we && (t.addr % 0x1000) == 4 && t.addr >= 0x200000 && t.rd_new) claims++;
        t.clk = 1; t.eval(); t.clk = 0; t.eval();
    }
    printf("%ld mismatches; cycles with an interrupt %ld, claims that returned a source %ld\n", bad, irqs, claims);
    return bad != 0;
}
