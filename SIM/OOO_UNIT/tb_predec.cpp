//---------------------------------------------------------------------------
// tb_predec.cpp : OOO_PREDEC against a predecoder written separately
//
// Random 16-byte blocks built from instructions (32-bit branches, jal,
// jalr with link and non-link registers, c.j, c.beqz, c.bnez, c.jr,
// c.jalr, c.ebreak and other 16 / 32-bit instructions), cut at a random
// place so that blocks start inside an instruction too; a random start
// parcel, and a carried first half when the block starts at parcel 0. The
// reference (predec_ref.h) walks the instructions with byte offsets decoded
// from the specification's tables; every output is compared.
//---------------------------------------------------------------------------
#include "VOOO_PREDEC.h"
#include "predec_ref.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>

static std::mt19937_64 rng(5);
static VOOO_PREDEC d;
static long bad = 0, n = 0;

static uint32_t rnd(int b) { return (uint32_t)(rng() & ((1ull << b) - 1)); }
static uint32_t reg() { int k = rng() % 6; return k == 0 ? 0 : k == 1 ? 1 : k == 2 ? 5 : rnd(5); }

// one random instruction: 1 or 2 parcels
static int gen(uint16_t* out)
{
    uint32_t i;
    switch (rng() % 14) {
    case 0: i = (rnd(7) << 25) | (rnd(5) << 20) | (rnd(5) << 15) | ((rng() % 2 ? 0 : 1 + rng() % 6) << 12) | (rnd(5) << 7) | 0x63; break;  // branch
    case 1: i = (rnd(20) << 12) | (reg() << 7) | 0x6f; break;                           // jal
    case 2: i = (rnd(12) << 20) | (reg() << 15) | ((rng() % 4 ? 0 : rnd(3)) << 12) | (reg() << 7) | 0x67; break;   // jalr (sometimes a bad funct3)
    case 3: { uint16_t c = (uint16_t)((5u << 13) | (rnd(11) << 2) | 1); out[0] = c; return 1; }          // c.j
    case 4: { uint16_t c = (uint16_t)(((6u + rng() % 2) << 13) | (rnd(11) << 2) | 1); out[0] = c; return 1; }   // c.beqz / c.bnez
    case 5: { uint16_t c = (uint16_t)((4u << 13) | (rnd(1) << 12) | (reg() << 7) | 2); out[0] = c; return 1; }  // c.jr / c.jalr / c.ebreak
    case 6: { uint16_t c = (uint16_t)((4u << 13) | (rnd(1) << 12) | (reg() << 7) | (rnd(5) << 2) | 2); out[0] = c; return 1; }  // c.mv / c.add
    case 7: { uint16_t c = (uint16_t)((1u << 13) | (rnd(11) << 2) | 1); out[0] = c; return 1; }          // c.addiw (c.jal in RV32)
    case 8: case 9: { uint16_t c = (uint16_t)rng(); if ((c & 3) == 3) c ^= 1; out[0] = c; return 1; }   // other 16-bit
    default: i = (uint32_t)rng() | 3; break;                                             // other 32-bit
    }
    out[0] = (uint16_t)i; out[1] = (uint16_t)(i >> 16);
    return 2;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    long nbr = 0, njal = 0, njalr = 0, ncall = 0, nret = 0, ncross = 0, ncarry = 0;
    for (n = 0; n < 2000000; n++) {
        // a stream of instructions; the block is 8 parcels of it from a random place
        uint16_t s[24]; int k = 0;
        while (k < 20) k += gen(&s[k]);
        int skip = rng() % 3;
        uint16_t p[8];
        for (int j = 0; j < 8; j++) p[j] = s[skip + j];
        uint64_t line = rng() & ((1ull << 35) - 1);
        if (rng() % 8 == 0) line = (rng() % 2) ? 0 : (1ull << 35) - 1;     // the ends of the space
        bool carry_v = false; uint16_t carry = 0; int start = 0;
        if (rng() % 3 == 0) { carry_v = true; carry = (uint16_t)(rng() | 3); }
        else start = rng() % 8;
        d.line = line; d.start = start; d.carry_v = carry_v; d.carry = carry;
        for (int j = 0; j < 4; j++) d.data[j] = (uint32_t)p[2 * j] | ((uint32_t)p[2 * j + 1] << 16);
        d.eval();
        // ---- the reference
        Predec r = predec_ref(line, start, carry_v, carry, p);
        int e_iv = r.iv, e_br = r.br, e_jal = r.jal, e_jalr = r.jalr, e_call = r.call, e_ret = r.ret;
        const uint64_t* e_tgt = r.tgt;
        bool e_cross = r.cross;
        // ---- compare
        auto chk8 = [&](const char* nm, int got, int exp) {
            if (got != exp && bad++ < 12) printf("block %ld: %s %02x, expected %02x\n", n, nm, got, exp);
        };
        chk8("iv", d.iv, e_iv); chk8("br", d.br, e_br); chk8("jal", d.jal, e_jal);
        chk8("jalr", d.jalr, e_jalr); chk8("call", d.call, e_call); chk8("ret", d.ret, e_ret);
        chk8("cross", d.cross_out, e_cross);
        for (int e = 0; e < 8; e++) {
            if (!(((e_br | e_jal) >> e) & 1)) continue;
            uint64_t g = 0;
            for (int b = 0; b < 38; b++) { int bit = 38 * e + b; g |= (uint64_t)((d.tgt[bit / 32] >> (bit % 32)) & 1) << b; }
            if (g != e_tgt[e] && bad++ < 12) printf("block %ld: tgt[%d] %llx, expected %llx\n", n, e, (unsigned long long)g, (unsigned long long)e_tgt[e]);
        }
        nbr += __builtin_popcount(e_br); njal += __builtin_popcount(e_jal); njalr += __builtin_popcount(e_jalr);
        ncall += __builtin_popcount(e_call); nret += __builtin_popcount(e_ret); ncross += e_cross; ncarry += carry_v;
    }
    printf("tb_predec: %ld blocks (%ld carried, %ld crossing), %ld branches, %ld jal, %ld jalr (%ld calls, %ld returns), %ld mismatches: %s\n",
           n, ncarry, ncross, nbr, njal, njalr, ncall, nret, bad, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}
