#ifndef __SYSTEM_H
#define __SYSTEM_H

#ifdef __cplusplus
extern "C" {
#endif

/* mmRISC-3 (LitexSystem/cpu/mmrisc3): fence.i does the whole job, as on
 * mmRISC-2: OOO_SYS has the D$'s dirty lines written out (into the L2,
 * which keeps them in order with the fetches) and then the I$ invalidated
 * (RTL/CPU/OOO/OOO_CPU). The L2 is inside the CPU and the SoC's DMA goes
 * through the D$ (RTL/CPU/TOP/CPU_TOP's DMA port), so nothing else needs
 * flushing; both calls below are the same instruction.
 */
__attribute__((unused)) static void flush_cpu_icache(void)
{
	asm volatile("fence.i" ::: "memory");
}

__attribute__((unused)) static void flush_cpu_dcache(void)
{
	asm volatile("fence.i" ::: "memory");
}

/* defined by LiteX in libbase/system.c; it does nothing unless the SoC
 * declares CONFIG_L2_SIZE, which this one does not (its L2 is the CPU's) */
void flush_l2_cache(void);

void busy_wait(unsigned int ms);
void busy_wait_us(unsigned int us);

#include <csr-defs.h>

#define csrr(reg) ({ unsigned long __tmp; \
  asm volatile ("csrr %0, " #reg : "=r"(__tmp)); \
  __tmp; })

#define csrw(reg, val) ({ \
  if (__builtin_constant_p(val) && (unsigned long)(val) < 32) \
	asm volatile ("csrw " #reg ", %0" :: "i"(val)); \
  else \
	asm volatile ("csrw " #reg ", %0" :: "r"(val)); })

#define csrs(reg, bit) ({ \
  if (__builtin_constant_p(bit) && (unsigned long)(bit) < 32) \
	asm volatile ("csrrs x0, " #reg ", %0" :: "i"(bit)); \
  else \
	asm volatile ("csrrs x0, " #reg ", %0" :: "r"(bit)); })

#define csrc(reg, bit) ({ \
  if (__builtin_constant_p(bit) && (unsigned long)(bit) < 32) \
	asm volatile ("csrrc x0, " #reg ", %0" :: "i"(bit)); \
  else \
	asm volatile ("csrrc x0, " #reg ", %0" :: "r"(bit)); })

#ifdef __cplusplus
}
#endif

#endif /* __SYSTEM_H */
