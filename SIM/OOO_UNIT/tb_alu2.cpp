//---------------------------------------------------------------------------
// tb_alu2.cpp : OOO_ALU2 against a reference written from the RISC-V
// specification (RV64I, Zba, Zbb, Zbs, Zicond), random operations, operand
// selections and values (values biased to the edges: 0, -1, sign bits,
// small shifts), and the branch comparison alone or fused after the
// operation (its other operand s1, s2 or zero). Built with ALU1 defined
// (tb_alu1.cpp, OOO_ALU2 FULL = 0): only the operations of ALU1, add / sub
// (and their word forms), slt / sltu, xor / or / and.
//---------------------------------------------------------------------------
#include "VOOO_ALU2.h"
#include <cstdint>
#include <cstdio>
#include <random>

static std::mt19937_64 rng(12345);

static uint64_t rval()
{
    switch (rng() % 8) {
    case 0: return 0;
    case 1: return ~0ull;
    case 2: return 1ull << (rng() % 64);
    case 3: return (uint64_t)(int64_t)(int32_t)rng();      // sign extended 32 bit
    case 4: return rng() % 70;                              // small (shift amounts)
    default: return rng();
    }
}

static uint64_t sx32(uint64_t v) { return (uint64_t)(int64_t)(int32_t)(uint32_t)v; }
static int clz64(uint64_t v) { int n = 0; for (int i = 63; i >= 0 && !((v >> i) & 1); i--) n++; return n; }
static int ctz64(uint64_t v) { int n = 0; for (int i = 0; i < 64 && !((v >> i) & 1); i++) n++; return n; }

// one ALU operation, as the specification says, after the operand selection
static uint64_t ref_alu(int op, uint64_t a, uint64_t b, bool uw, int shift, bool word)
{
    uint64_t r = 0;
    uint64_t az = uw ? (a & 0xffffffffull) : a;
    unsigned sh = word ? (b & 31) : (b & 63);
    uint32_t a32 = (uint32_t)a;
    switch (op) {
    case 1: r = a - b; break;                                              // sub / subw
    case 2: r = word ? (uint64_t)(a32 << sh) : (az << sh); break;          // sll, slliw; slli.uw (uw)
    case 3: r = (int64_t)a < (int64_t)b; break;
    case 4: r = a < b; break;
    case 5: r = a ^ b; break;
    case 6: r = word ? (uint64_t)(a32 >> sh) : (az >> sh); break;
    case 7: r = word ? (uint64_t)(int64_t)((int32_t)a32 >> sh) : (uint64_t)((int64_t)az >> sh); break;
    case 8: r = a | b; break;
    case 9: r = a & b; break;
    case 10: r = a & ~b; break;
    case 11: r = a | ~b; break;
    case 12: r = ~(a ^ b); break;
    case 13: r = (int64_t)a < (int64_t)b ? a : b; break;
    case 14: r = a < b ? a : b; break;
    case 15: r = (int64_t)a < (int64_t)b ? b : a; break;
    case 16: r = a < b ? b : a; break;
    case 17: r = word ? (uint64_t)(uint32_t)((a32 << sh) | (sh ? a32 >> (32 - sh) : 0))
                      : ((a << sh) | (sh ? a >> (64 - sh) : 0)); break;
    case 18: r = word ? (uint64_t)(uint32_t)((a32 >> sh) | (sh ? a32 << (32 - sh) : 0))
                      : ((a >> sh) | (sh ? a << (64 - sh) : 0)); break;
    case 19: r = word ? clz64((uint64_t)a32 << 32 | 0xffffffffull) : clz64(a); break;
    case 20: r = word ? ctz64(0xffffffff00000000ull | a32) : ctz64(a); break;
    case 21: r = word ? __builtin_popcountll(a32) : __builtin_popcountll(a); break;
    case 22: r = (uint64_t)(int64_t)(int8_t)a; break;
    case 23: r = (uint64_t)(int64_t)(int16_t)a; break;
    case 24: r = a & 0xffff; break;
    case 25: for (int i = 0; i < 8; i++) if ((a >> (8 * i)) & 0xff) r |= 0xffull << (8 * i); break;
    case 26: for (int i = 0; i < 8; i++) r |= ((a >> (8 * i)) & 0xff) << (8 * (7 - i)); break;
    case 27: r = b == 0 ? 0 : a; break;
    case 28: r = b != 0 ? 0 : a; break;
    case 29: r = a | (1ull << (b & 63)); break;
    case 30: r = a & ~(1ull << (b & 63)); break;
    case 31: r = a ^ (1ull << (b & 63)); break;
    case 32: r = (a >> (b & 63)) & 1; break;
    default: r = (az << shift) + b; break;                                  // add, add.uw, sh*add
    }
    return word ? sx32(r) : r;
}

// the operand forms the decoder produces (word forms, .uw, sh*add only where RISC-V has them)
static void rand_op(int& op, bool& uw, int& shift, bool& word)
{
#ifdef ALU1
    static const int SIMPLE[] = {0, 1, 3, 4, 5, 8, 9};
    op = SIMPLE[rng() % 7];
    uw = false; shift = 0; word = (op == 0 || op == 1) && (rng() & 1);
    return;
#endif
    op = (int)(rng() % 33);
    uw = false; shift = 0; word = false;
    if (op == 0) { int k = rng() % 6; if (k == 1) word = true; else if (k == 2) uw = true;
                   else if (k >= 3) { shift = (int)(rng() % 3) + 1; uw = rng() & 1; } }
    else if (op == 1 || op == 6 || op == 7 || op == 17 || op == 18 || op == 19 || op == 20 || op == 21) word = rng() & 1;
    else if (op == 2) { int k = rng() % 3; word = k == 1; uw = k == 2; }
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    VOOO_ALU2 d;
    long n = 0, bad = 0;
    for (long it = 0; it < 2000000; it++) {
        uint64_t s1 = rval(), s2 = rval(), i1 = rval(), pc = rng() & ~1ull;
        int op1, sh1; bool uw1, w1;
        rand_op(op1, uw1, sh1, w1);
        int a1 = rng() % 3, b1i = rng() & 1;
        int isbr = rng() & 1, brop = (int[]){0, 1, 4, 5, 6, 7}[rng() % 6], brf = rng() & 1, bra = rng() & 1, bos = rng() % 3;
        if (rng() % 4 == 0) s2 = s1;                       // equal operands for the branches
        if (brf && rng() % 3 == 0) {                       // a fused branch with equal operands: the
            uint64_t A = a1 == 1 ? pc : a1 == 2 ? 0 : s1;  // other operand on a port the ALU does not read
            uint64_t r = ref_alu(op1, A, b1i ? i1 : s2, uw1, sh1, w1);
            if (bos == 1 && b1i) s2 = r;
            else if (bos == 0 && a1 != 0) s1 = r;
        }
        d.s1 = s1; d.s2 = s2; d.imm1 = i1; d.pc = pc;
        d.op1 = op1; d.uw1 = uw1; d.shift1 = sh1; d.word1 = w1; d.a1_sel = a1; d.b1_imm = b1i;
        d.is_br = isbr; d.br_op = brop; d.br_fused = brf; d.br_res1_a = bra; d.br_o_sel = bos;
        d.eval();
        uint64_t A1 = a1 == 1 ? pc : a1 == 2 ? 0 : s1;
        uint64_t r1 = ref_alu(op1, A1, b1i ? i1 : s2, uw1, sh1, w1);
        uint64_t o = bos == 1 ? s2 : bos == 2 ? 0 : s1;
        uint64_t ca = brf ? (bra ? r1 : o) : s1, cb = brf ? (bra ? o : r1) : s2;
        bool t = false;
        switch (brop) {
        case 0: t = ca == cb; break; case 1: t = ca != cb; break;
        case 4: t = (int64_t)ca < (int64_t)cb; break; case 5: t = (int64_t)ca >= (int64_t)cb; break;
        case 6: t = ca < cb; break; case 7: t = ca >= cb; break;
        }
        t = t && isbr;
        n++;
        if (d.res1 != r1 || d.take_branch != t) {
            if (bad++ < 10)
                printf("MISMATCH op1 %d uw %d sh %d w %d a1 %d b1i %d: res1 %016llx ref %016llx | br %d (fused %d other %d) ref %d\n",
                       op1, uw1, sh1, w1, a1, b1i, (unsigned long long)d.res1, (unsigned long long)r1,
                       d.take_branch, brf, bos, t);
        }
    }
#ifdef ALU1
    printf("tb_alu1: %ld vectors (ALU1: add / sub, slt / sltu, logic), %ld mismatches: %s\n", n, bad, bad ? "FAIL" : "PASS");
#else
    printf("tb_alu2: %ld vectors, %ld mismatches: %s\n", n, bad, bad ? "FAIL" : "PASS");
#endif
    return bad ? 1 : 0;
}
