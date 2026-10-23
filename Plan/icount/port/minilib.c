/*---------------------------------------------------------------------------
 * minilib.c : the little of a C library CoreMark uses, on the bare machine
 * of Spike
 *
 * The minilib.c of mmRISC-2 SIM/SIM_SYS/bench. The only change: Spike reads
 * tohost only now and then, so each byte waits until the one before it has
 * been taken (tohost back to 0).
 *-------------------------------------------------------------------------*/
#include <stddef.h>

extern volatile unsigned long tohost;
extern volatile unsigned long fromhost;

/* the output of ee_printf: every byte is a console command (device 1,
 * command 1) */
void tohost_putc(char c)
{
    while (tohost) ;
    fromhost = 0;
    tohost = (1UL << 56) | (1UL << 48) | (unsigned char)c;
}

void *memcpy(void *d, const void *s, size_t n)
{
    char *dp = d; const char *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

void *memset(void *d, int c, size_t n)
{
    char *dp = d;
    while (n--) *dp++ = (char)c;
    return d;
}

char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++) != '\0') ;
    return r;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}
