/*---------------------------------------------------------------------------
 * core_portme.c : CoreMark on the bare machine of Spike
 *
 * The core_portme.c of mmRISC-2 SIM/SIM_SYS/bench without the profile marks
 * of tb_SYS. The timed part prints minstret, so that the instructions of
 * the benchmark itself (without the printing around it) can be read off.
 * On Spike mcycle follows minstret, so only the instructions mean anything.
 *-------------------------------------------------------------------------*/
#include "coremark.h"
#include "core_portme.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static inline unsigned long rd_cycle(void)
{
    unsigned long v;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

static inline unsigned long rd_instret(void)
{
    unsigned long v;
    __asm__ volatile ("csrr %0, minstret" : "=r"(v));
    return v;
}

static unsigned long t0, t1, i0, i1;

void start_time(void)
{
    i0 = rd_instret();
    t0 = rd_cycle();
}

void stop_time(void)
{
    t1 = rd_cycle();
    i1 = rd_instret();
}

CORE_TICKS get_time(void)
{
    return t1 - t0;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)ticks / (secs_ret)EE_TICKS_PER_SEC;
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc; (void)argv;
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    ee_printf("timed instructions: %lu\n", i1 - i0);
    p->portable_id = 0;
}
