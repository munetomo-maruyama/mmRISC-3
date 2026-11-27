//---------------------------------------------------------------------------
// dramlat.c : the memory's latency and throughput as the CPU sees them on the
//             board (step 2.5, LitexSystem/docs/BRINGUP.md 27)
//
// A bare-metal program for LiteX's BIOS (built as its demo, linked at the
// main RAM, scripts/build_dramlat.sh), loaded by the BIOS's serial boot or
// netboot. It runs from the main RAM, so its code is in the I$; the BIOS from
// the ROM is fetched uncached and could not measure this (BRINGUP 22). Its
// stack and data are in LiteX's SRAM, uncached too, so every timed loop is
// asm with everything in registers.
//
//   pointer chase  one 8-byte load at the start of each 64-byte line, each
//                  load's address the previous load's data, so the loads go
//                  one at a time: the cycles of one load are its latency.
//                  The lines in a random single cycle (Sattolo) over n lines
//                  of a buffer at 0x8100_0000, from 4 KB (D$ hits) through
//                  128 KB (L2 hits) to 64 MB (the DRAM, a row miss nearly
//                  every time); and in address order (the next line each
//                  time, the DRAM's rows hit) over 16 MB.
//   throughput     16 MB read with 8 loads a line, written with 8 stores a
//                  line, MiB/s at the CPU's clock.
//
// The cycles are the CPU's (rdcycle: mcycle at 50 MHz), checked once against
// LiteX's timer0 at sys's clock. The chase's loop is 8 loads, addi, bnez.
// Interrupts are on while printing (LiteX's UART driver drains its ring
// buffer from the interrupt; with them off the last lines were lost), and
// off while timing, after uart_sync(). At the end it prints DRAMLAT DONE and
// resets the SoC (ctrl_reset).
//---------------------------------------------------------------------------
#include <stdio.h>
#include <stdint.h>

#include <irq.h>
#include <libbase/uart.h>
#include <generated/csr.h>
#include <generated/soc.h>

#define BUF   0x81000000UL   // the chase's lines and the throughput's 16 MB
#define PERM  0x86000000UL   // the permutation while building (4 MB at most)
#define MB    (1024UL * 1024UL)

static inline uint64_t cycles(void)
{
    uint64_t c;
    __asm__ volatile("rdcycle %0" : "=r"(c));
    return c;
}

static uint64_t rng = 0x9e3779b97f4a7c15ULL;
static uint64_t xorshift(void)
{
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return rng;
}

// node i at BUF + 64 i holds the address of node next(i)
static void build(uint64_t n, int random)
{
    volatile uint32_t *perm = (volatile uint32_t *)PERM;
    for (uint64_t i = 0; i < n; i++)
        perm[i] = (uint32_t)i;
    if (random) {
        // Sattolo: a random permutation with a single cycle
        for (uint64_t i = n - 1; i > 0; i--) {
            uint64_t j = xorshift() % i;
            uint32_t t = perm[i]; perm[i] = perm[j]; perm[j] = t;
        }
        for (uint64_t i = 0; i < n; i++)
            *(volatile uint64_t *)(BUF + 64 * i) = BUF + 64 * (uint64_t)perm[i];
    } else {
        for (uint64_t i = 0; i < n; i++)
            *(volatile uint64_t *)(BUF + 64 * i) = BUF + 64 * ((i + 1) % n);
    }
}

// iters x 8 dependent loads from p; returns the cycles
static uint64_t chase(uint64_t p, uint64_t iters)
{
    uint64_t t0, t1;
    __asm__ volatile(
        "rdcycle %[t0]\n"
        "1:\n"
        "ld %[p], 0(%[p])\n" "ld %[p], 0(%[p])\n" "ld %[p], 0(%[p])\n" "ld %[p], 0(%[p])\n"
        "ld %[p], 0(%[p])\n" "ld %[p], 0(%[p])\n" "ld %[p], 0(%[p])\n" "ld %[p], 0(%[p])\n"
        "addi %[n], %[n], -1\n"
        "bnez %[n], 1b\n"
        "rdcycle %[t1]\n"
        : [p] "+r"(p), [n] "+r"(iters), [t0] "=&r"(t0), [t1] "=&r"(t1)
        :
        : "memory");
    return t1 - t0;
}

static uint64_t read_bytes(uint64_t base, uint64_t bytes)
{
    uint64_t t0, t1, end = base + bytes;
    __asm__ volatile(
        "rdcycle %[t0]\n"
        "1:\n"
        "ld t0, 0(%[a])\n"  "ld t1, 8(%[a])\n"  "ld t2, 16(%[a])\n" "ld t3, 24(%[a])\n"
        "ld t4, 32(%[a])\n" "ld t5, 40(%[a])\n" "ld t6, 48(%[a])\n" "ld t0, 56(%[a])\n"
        "addi %[a], %[a], 64\n"
        "bltu %[a], %[e], 1b\n"
        "rdcycle %[t1]\n"
        : [a] "+r"(base), [t0] "=&r"(t0), [t1] "=&r"(t1)
        : [e] "r"(end)
        : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory");
    return t1 - t0;
}

static uint64_t write_bytes(uint64_t base, uint64_t bytes)
{
    uint64_t t0, t1, end = base + bytes;
    __asm__ volatile(
        "rdcycle %[t0]\n"
        "1:\n"
        "sd zero, 0(%[a])\n"  "sd zero, 8(%[a])\n"  "sd zero, 16(%[a])\n" "sd zero, 24(%[a])\n"
        "sd zero, 32(%[a])\n" "sd zero, 40(%[a])\n" "sd zero, 48(%[a])\n" "sd zero, 56(%[a])\n"
        "addi %[a], %[a], 64\n"
        "bltu %[a], %[e], 1b\n"
        "rdcycle %[t1]\n"
        : [a] "+r"(base), [t0] "=&r"(t0), [t1] "=&r"(t1)
        : [e] "r"(end)
        : "memory");
    return t1 - t0;
}

// x100 as "a.bc"
static void print_x100(uint64_t v)
{
    printf("%lu.%02lu", (unsigned long)(v / 100), (unsigned long)(v % 100));
}

static void quiet(void)  { uart_sync(); irq_setie(0); }
static void noisy(void)  { irq_setie(1); }

static void lat(const char *what, uint64_t bytes, int random)
{
    uint64_t n = bytes / 64;
    uint64_t loads = n < 262144 ? 262144 : n;
    uint64_t iters = loads / 8;
    quiet();
    build(n, random);
    chase(BUF, (n + 7) / 8);                    // warm: every line once
    uint64_t c = chase(BUF, iters);
    noisy();
    printf("lat %-6s %8lu KB  ", what, (unsigned long)(bytes / 1024));
    print_x100(c * 100 / (iters * 8));
    printf(" cycles/load\n");
}

static void bw(const char *what, uint64_t c, uint64_t bytes)
{
    // MiB/s at 50 MHz, x100
    uint64_t v = bytes * 100 * (uint64_t)50000000 / c / MB;
    printf("bw  %-6s %8lu KB  ", what, (unsigned long)(bytes / 1024));
    print_x100(v);
    printf(" MiB/s  (");
    print_x100(c * 100 / (bytes / 64));
    printf(" cycles/line)\n");
}

static uint64_t timed_read(uint64_t base, uint64_t bytes)
{
    quiet(); uint64_t c = read_bytes(base, bytes); noisy(); return c;
}
static uint64_t timed_write(uint64_t base, uint64_t bytes)
{
    quiet(); uint64_t c = write_bytes(base, bytes); noisy(); return c;
}

int main(void)
{
    irq_setmask(0);
    irq_setie(1);
    uart_init();
    printf("\nDRAMLAT: pointer chase and throughput from the main RAM\n");

    // mcycle against timer0 (sys's clock)
    quiet();
    timer0_en_write(0);
    timer0_reload_write(0);
    timer0_load_write(0xffffffff);
    timer0_en_write(1);
    timer0_update_value_write(1);
    uint32_t s0 = timer0_value_read();
    uint64_t c0 = cycles();
    while (cycles() - c0 < 10000000) ;
    timer0_update_value_write(1);
    uint32_t s1 = timer0_value_read();
    uint64_t c1 = cycles();
    noisy();
    printf("clock: %lu CPU cycles in %lu sys cycles (sys %lu Hz)\n",
        (unsigned long)(c1 - c0), (unsigned long)(s0 - s1), (unsigned long)CONFIG_CLOCK_FREQUENCY);

    static const uint32_t kb[] = { 4, 8, 12, 16, 32, 64, 128, 192, 256, 384, 512, 1024, 4096, 16384, 65536 };
    for (unsigned i = 0; i < sizeof(kb) / sizeof(kb[0]); i++)
        lat("random", (uint64_t)kb[i] * 1024, 1);
    lat("linear", 16 * MB, 0);
    lat("linear", 64 * MB, 0);

    bw("read",  timed_read(BUF, 16 * MB), 16 * MB);
    bw("write", timed_write(BUF, 16 * MB), 16 * MB);
    bw("read",  timed_read(BUF, 16 * MB), 16 * MB);

    printf("DRAMLAT DONE\n");
    uart_sync();
    for (volatile int i = 0; i < 200000; i++) ;    // the last characters out of the FIFO
    ctrl_reset_write(1);
    while (1) ;
    return 0;
}
