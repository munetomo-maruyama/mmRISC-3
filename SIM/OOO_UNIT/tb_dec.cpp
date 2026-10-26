//---------------------------------------------------------------------------
// tb_dec.cpp : OOO_DEC (4 slots of CORE_DECOMP + CORE_DEC and the fields
// for fusion, the issue queue and the ROB) against a decoder written from
// the specification's tables, with Spike as the judge of what is legal
//
// The reference (decode32 / expand16 below) is written apart from
// CORE_DEC / CORE_DECOMP: the encodings by opcode, funct3, funct7, the RVC
// expansion with Spike's own field extractors (insn_t::rvc_*), and the
// derived fields from Doc/UARCH.md. Whether an instruction exists is asked
// of Spike, running it (below), and the reference's own idea of it is
// checked against Spike first, so a slip in either shows up.
//
// Every 16-bit RVC encoding is tried (all 49,152), then 3,000,000 32-bit
// ones: random words with their opcode, funct3 and funct7 drawn from the
// encodings that exist (and from the rest), and wholly random words. The 4
// slots get different instructions each round. Every output of every slot
// is compared where it means something for that instruction.
//
// The rare classes (illegal, FP, CSR and system, SFENCE.VMA, AMO / LR / SC,
// cbo.zero) are decoded in slot 0 only (G0b G2): in slots 1 to 3 only `cut`
// is checked for them (the group ends before the first one), every other
// field of the other instructions as in slot 0. Each RVC encoding is tried
// in slot 0 as well as in slot (n mod 4).
//---------------------------------------------------------------------------
#include "VOOO_DEC.h"
#include "riscv/processor.h"
#include "riscv/simif.h"
#include "riscv/mmu.h"
#include "disasm.h"
#include "isa_parser.h"
#include <sstream>
#include <vector>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <string>

static std::mt19937_64 rng(37);
static VOOO_DEC d;
static long bad = 0, nlegal = 0, nill = 0, nrvc = 0;

// ---------------------------------------------------------------- the reference
struct R {
    bool legal = false;
    int cls = 7, op = 0, rd = 0, rs1 = 0, rs2 = 0, use1 = 0, use2 = 0, alu2ok = 0, port = 1, lat2 = 0, ext = 0, nonspec = 0;
    bool imm_v = false; uint32_t imm = 0;
    bool alu_v = false; int alu_op = 0, uw = 0, shift = 0, asel = 0, bsel = 1, word = 0;
    int br = 0, jal = 0, jalr = 0, br_op = 0;
    bool mdu = false; int mdu_op = 0;
    bool mem = false; int cmd = 0, size = 0, sgn = 0;
    int sys = 0, sfence = 0;
    bool csr = false; int csr_addr = 0, csr_op = 0, csr_imm = 0, csr_wr = 0, csr_rd = 0;
    bool fp = false, fpa = false; int fop = 0, fmt = 0, rm = 0, ufs = 0, rs3 = 0, fwe = 0, cvt = 0, isg = 0, iw = 0;
    bool fpmem = false;
};
static uint32_t bits(uint32_t x, int hi, int lo) { return (x >> lo) & ((1u << (hi - lo + 1)) - 1); }
static uint32_t sx32(uint32_t v, int b) { return (uint32_t)((int32_t)(v << (32 - b)) >> (32 - b)); }

enum { A_ADD = 0, A_SUB, A_SLL, A_SLT, A_SLTU, A_XOR, A_SRL, A_SRA, A_OR, A_AND, A_ANDN, A_ORN, A_XNOR, A_MIN, A_MINU,
       A_MAX, A_MAXU, A_ROL, A_ROR, A_CLZ, A_CTZ, A_CPOP, A_SEXTB, A_SEXTH, A_ZEXTH, A_ORCB, A_REV8, A_CZEQZ, A_CZNEZ,
       A_BSET, A_BCLR, A_BINV, A_BEXT };
static bool second_ok(int a) {
    switch (a) {
    case A_ADD: case A_SUB: case A_XOR: case A_SRL: case A_OR: case A_AND: case A_ANDN: case A_ORN: case A_XNOR:
    case A_SEXTB: case A_SEXTH: case A_ZEXTH: case A_CZEQZ: case A_CZNEZ: case A_BEXT: return true;
    default: return false;
    }
}

static R decode32(uint32_t x)
{
    R r;
    uint32_t opc = bits(x, 6, 0), f3 = bits(x, 14, 12), f7 = bits(x, 31, 25), rd = bits(x, 11, 7), rs1 = bits(x, 19, 15),
             rs2 = bits(x, 24, 20);
    uint32_t ii = sx32(bits(x, 31, 20), 12), is = sx32(bits(x, 31, 25) << 5 | bits(x, 11, 7), 12);
    uint32_t ib = sx32(bits(x, 31, 31) << 12 | bits(x, 7, 7) << 11 | bits(x, 30, 25) << 5 | bits(x, 11, 8) << 1, 13);
    uint32_t iu = x & 0xfffff000u;
    uint32_t ij = sx32(bits(x, 31, 31) << 20 | bits(x, 19, 12) << 12 | bits(x, 20, 20) << 11 | bits(x, 30, 21) << 1, 21);
    int we = 0;                                          // writes an integer register
    auto alu = [&](int a, int bsel, int word, uint32_t imm, bool usei2) {
        r.legal = true; r.cls = 0; r.port = 0; r.alu_v = true; r.alu_op = a; r.bsel = bsel; r.word = word;
        r.use1 = 1; r.use2 = usei2; we = 1;
        if (bsel) { r.imm_v = true; r.imm = imm; }
    };
    switch (opc) {
    case 0x37: alu(A_ADD, 1, 0, iu, 0); r.use1 = 0; r.asel = 2; r.op = 1; break;     // lui
    case 0x17: alu(A_ADD, 1, 0, iu, 0); r.use1 = 0; r.asel = 1; r.op = 2; break;     // auipc
    case 0x6f: r.legal = true; r.cls = 2; r.port = 0; r.jal = 1; we = 1; r.imm_v = true; r.imm = ij; break;
    case 0x67: if (f3 == 0) { r.legal = true; r.cls = 3; r.port = 0; r.jalr = 1; we = 1; r.use1 = 1; r.imm_v = true; r.imm = ii; } break;
    case 0x63: if (f3 != 2 && f3 != 3) { r.legal = true; r.cls = 1; r.port = 0; r.br = 1; r.br_op = f3; r.use1 = r.use2 = 1; r.imm_v = true; r.imm = ib; } break;
    case 0x03: if (f3 != 7) { r.legal = true; r.cls = 4; r.port = 2; r.lat2 = 1; r.mem = true; r.cmd = 0; r.size = f3 & 3; r.sgn = !(f3 & 4); we = 1; r.use1 = 1; r.imm_v = true; r.imm = ii; } break;
    case 0x23: if (f3 < 4) { r.legal = true; r.cls = 5; r.port = 2; r.mem = true; r.cmd = 1; r.size = f3; r.use1 = r.use2 = 1; r.imm_v = true; r.imm = is; } break;
    case 0x13: {
        uint32_t sh = bits(x, 25, 20), h6 = bits(x, 31, 26), f12 = bits(x, 31, 20);
        switch (f3) {
        case 0: alu(A_ADD, 1, 0, ii, 0); r.op = 6; break;
        case 2: alu(A_SLT, 1, 0, ii, 0); break;
        case 3: alu(A_SLTU, 1, 0, ii, 0); break;
        case 4: alu(A_XOR, 1, 0, ii, 0); break;
        case 6: alu(A_OR, 1, 0, ii, 0); break;
        case 7: alu(A_AND, 1, 0, ii, 0); break;
        case 1:
            if (h6 == 0)       { alu(A_SLL, 1, 0, sh, 0); r.op = 3; }
            else if (h6 == 0x0a) alu(A_BSET, 1, 0, sh, 0);
            else if (h6 == 0x12) alu(A_BCLR, 1, 0, sh, 0);
            else if (h6 == 0x1a) alu(A_BINV, 1, 0, sh, 0);
            else if (f12 == 0x600) alu(A_CLZ, 1, 0, sh, 0);
            else if (f12 == 0x601) alu(A_CTZ, 1, 0, sh, 0);
            else if (f12 == 0x602) alu(A_CPOP, 1, 0, sh, 0);
            else if (f12 == 0x604) alu(A_SEXTB, 1, 0, sh, 0);
            else if (f12 == 0x605) alu(A_SEXTH, 1, 0, sh, 0);
            break;
        case 5:
            if (h6 == 0 || h6 == 0x10) { alu(h6 ? A_SRA : A_SRL, 1, 0, sh, 0); r.op = 4; }
            else if (h6 == 0x18) alu(A_ROR, 1, 0, sh, 0);
            else if (h6 == 0x12) alu(A_BEXT, 1, 0, sh, 0);
            else if (f12 == 0x287) alu(A_ORCB, 1, 0, sh, 0);
            else if (f12 == 0x6b8) alu(A_REV8, 1, 0, sh, 0);
            break;
        }
        break;
    }
    case 0x1b: {
        uint32_t sh = bits(x, 24, 20), f12 = bits(x, 31, 20);
        switch (f3) {
        case 0: alu(A_ADD, 1, 1, ii, 0); r.op = 6; break;
        case 1:
            if (f7 == 0) { alu(A_SLL, 1, 1, sh, 0); r.op = 3; }
            else if (bits(x, 31, 26) == 0x02) { alu(A_SLL, 1, 0, bits(x, 25, 20), 0); r.uw = 1; }   // slli.uw
            else if (f12 == 0x600) alu(A_CLZ, 1, 1, sh, 0);
            else if (f12 == 0x601) alu(A_CTZ, 1, 1, sh, 0);
            else if (f12 == 0x602) alu(A_CPOP, 1, 1, sh, 0);
            break;
        case 5:
            if (f7 == 0 || f7 == 0x20) { alu(f7 ? A_SRA : A_SRL, 1, 1, sh, 0); r.op = 4; }
            else if (f7 == 0x30) alu(A_ROR, 1, 1, sh, 0);
            break;
        }
        break;
    }
    case 0x33: {
        if (f7 == 1) { r.legal = true; r.cls = 6; r.port = 1; r.mdu = true; r.mdu_op = f3; r.use1 = r.use2 = 1; we = 1;
                       r.lat2 = !(f3 & 4); r.ext = (f3 & 4) != 0; break; }     // multiply: 2 cycles; divide: from outside
        if (f7 == 5 && (f3 == 1 || f3 == 2 || f3 == 3)) { r.legal = true; r.cls = 6; r.port = 1; r.mdu = true; r.mdu_op = 8 | f3; r.use1 = r.use2 = 1; we = 1; r.lat2 = 1; break; }
        static const std::map<uint32_t, int> t = {
            {0x000, A_ADD}, {0x200, A_SUB}, {0x001, A_SLL}, {0x002, A_SLT}, {0x003, A_SLTU}, {0x004, A_XOR}, {0x005, A_SRL},
            {0x205, A_SRA}, {0x006, A_OR}, {0x007, A_AND}, {0x207, A_ANDN}, {0x206, A_ORN}, {0x204, A_XNOR},
            {0x054, A_MIN}, {0x055, A_MINU}, {0x056, A_MAX}, {0x057, A_MAXU}, {0x301, A_ROL}, {0x305, A_ROR},
            {0x075, A_CZEQZ}, {0x077, A_CZNEZ}, {0x141, A_BSET}, {0x241, A_BCLR}, {0x341, A_BINV}, {0x245, A_BEXT}};
        uint32_t key = f7 << 4 | f3;
        auto it = t.find(key);
        if (it != t.end()) { alu(it->second, 0, 0, 0, 1); if (it->second == A_ADD) r.op = 5; }
        else if (f7 == 0x10 && (f3 == 2 || f3 == 4 || f3 == 6)) { alu(A_ADD, 0, 0, 0, 1); r.shift = f3 >> 1; r.op = 5; }
        break;
    }
    case 0x3b: {
        if (f7 == 1) { if (f3 == 0 || (f3 & 4)) { r.legal = true; r.cls = 6; r.port = 1; r.mdu = true; r.mdu_op = f3; r.use1 = r.use2 = 1; we = 1;
                                                    r.lat2 = !(f3 & 4); r.ext = (f3 & 4) != 0; } break; }
        uint32_t key = f7 << 4 | f3;
        switch (key) {
        case 0x000: alu(A_ADD, 0, 1, 0, 1); r.op = 5; break;
        case 0x200: alu(A_SUB, 0, 1, 0, 1); break;
        case 0x001: alu(A_SLL, 0, 1, 0, 1); break;
        case 0x005: alu(A_SRL, 0, 1, 0, 1); break;
        case 0x205: alu(A_SRA, 0, 1, 0, 1); break;
        case 0x301: alu(A_ROL, 0, 1, 0, 1); break;
        case 0x305: alu(A_ROR, 0, 1, 0, 1); break;
        case 0x044: if (rs2 == 0) { alu(A_ZEXTH, 0, 0, 0, 0); } break;
        case 0x040: alu(A_ADD, 0, 0, 0, 1); r.uw = 1; r.op = 5; break;
        case 0x102: case 0x104: case 0x106: alu(A_ADD, 0, 0, 0, 1); r.uw = 1; r.shift = f3 >> 1; r.op = 5; break;
        }
        break;
    }
    case 0x2f: {                                                       // A
        if (f3 != 2 && f3 != 3) break;
        static const std::map<uint32_t, int> cmd = {{0x02, 2}, {0x03, 3}, {0x01, 4}, {0x00, 5}, {0x04, 6}, {0x0c, 7},
                                                    {0x08, 8}, {0x10, 9}, {0x14, 10}, {0x18, 11}, {0x1c, 12}};
        auto it = cmd.find(bits(x, 31, 27));
        if (it == cmd.end() || (it->second == 2 && rs2 != 0)) break;
        r.legal = true; r.port = 2; r.ext = 1; r.nonspec = 1; r.mem = true; r.cmd = it->second; r.size = f3 & 3;
        r.use1 = 1; r.use2 = it->second != 2; we = 1;
        break;
    }
    case 0x07: if (f3 == 2 || f3 == 3) { r.legal = true; r.port = 2; r.fp = true; r.fpmem = true; r.fmt = f3 & 1; r.use1 = 1; r.fwe = 1;
                                       r.mem = true; r.cmd = 0; r.size = f3 & 3; r.sgn = 0; r.imm_v = true; r.imm = ii; } break;
    case 0x27: if (f3 == 2 || f3 == 3) { r.legal = true; r.port = 2; r.fp = true; r.fpmem = true; r.fmt = f3 & 1; r.use1 = 1; r.ufs = 2;
                                       r.mem = true; r.cmd = 1; r.size = f3 & 3; r.imm_v = true; r.imm = is; } break;
    case 0x43: case 0x47: case 0x4b: case 0x4f:
        if (!bits(x, 26, 26)) { r.legal = true; r.port = 3; r.fp = r.fpa = true; r.fop = 5 + ((opc >> 2) & 3); r.fmt = bits(x, 25, 25);
                                r.rm = f3; r.ufs = 7; r.rs3 = bits(x, 31, 27); r.fwe = 1; }
        break;
    case 0x53: {
        if (bits(x, 26, 26)) break;
        uint32_t f5 = bits(x, 31, 27);
        r.fp = r.fpa = true; r.port = 3; r.fmt = bits(x, 25, 25); r.rm = f3; r.ufs = 3; r.fwe = 1;
        switch (f5) {
        case 0: case 1: case 2: case 3: r.legal = true; r.fop = f5; break;
        case 0x0b: if (rs2 == 0) { r.legal = true; r.fop = 4; r.ufs = 1; } break;
        case 0x04: if (f3 <= 2) { r.legal = true; r.fop = 9 + f3; r.rm = 0; } break;
        case 0x05: if (f3 <= 1) { r.legal = true; r.fop = 12 + f3; r.rm = 0; } break;
        case 0x08: r.ufs = 1;
                   if (bits(x, 25, 25) && rs2 == 0) { r.legal = true; r.fop = 21; r.fmt = 0; }
                   else if (!bits(x, 25, 25) && rs2 == 1) { r.legal = true; r.fop = 20; r.fmt = 1; }
                   break;
        case 0x14: if (f3 <= 2) { r.legal = true; r.fop = f3 == 2 ? 14 : f3 == 1 ? 15 : 16; r.fwe = 0; we = 1; r.rm = 0; } break;
        case 0x18: if (rs2 < 4) { r.legal = true; r.fop = 23; r.ufs = 1; r.fwe = 0; we = 1; r.cvt = 1; } break;
        case 0x1a: if (rs2 < 4) { r.legal = true; r.fop = 22; r.ufs = 0; r.use1 = 1; r.cvt = 1; } break;
        case 0x1c: if (rs2 == 0 && f3 <= 1) { r.legal = true; r.fop = f3 ? 17 : 18; r.ufs = 1; r.fwe = 0; we = 1; r.rm = 0; } break;
        case 0x1e: if (rs2 == 0 && f3 == 0) { r.legal = true; r.fop = 19; r.ufs = 0; r.use1 = 1; r.rm = 0; } break;
        }
        if (!r.legal) r = R();
        else { r.isg = !bits(x, 20, 20); r.iw = bits(x, 21, 21); }
        break;
    }
    case 0x0f:
        if (f3 == 0) { r.legal = true; r.sys = 1; r.nonspec = 1; }
        else if (f3 == 1) { r.legal = true; r.sys = 2; r.nonspec = 1; r.mem = true; r.cmd = 14; }
        else if (f3 == 2 && bits(x, 31, 20) == 4 && rd == 0) { r.legal = true; r.sys = 4; r.nonspec = 1; r.port = 2; r.use1 = 1;
                                                             r.mem = true; r.cmd = 16; r.size = 0; r.imm_v = true; r.imm = 0; }
        break;
    case 0x73:
        if (f3 == 0) {
            uint32_t f12 = bits(x, 31, 20);
            bool noarg = rs1 == 0 && rd == 0;
            if (f12 == 0x000 && noarg) r.sys = 8;
            else if (f12 == 0x001 && noarg) r.sys = 16;
            else if (f12 == 0x302 && noarg) r.sys = 32;
            else if (f12 == 0x102 && noarg) r.sys = 64;
            else if (f12 == 0x105 && noarg) r.sys = 128;
            else if (f7 == 0x09 && rd == 0) { r.sfence = 1; r.use1 = r.use2 = 1; }
            if (r.sys || r.sfence) { r.legal = true; r.nonspec = 1; }
        } else if (f3 != 4) {
            r.legal = true; r.nonspec = 1; r.csr = true; we = 1; r.use1 = !(f3 & 4);
            r.csr_addr = bits(x, 31, 20); r.csr_op = (f3 & 3) == 1 ? 1 : (f3 & 3) == 2 ? 2 : 3; r.csr_imm = (f3 >> 2) & 1;
            r.csr_wr = (f3 & 3) == 1 || rs1 != 0; r.csr_rd = (f3 & 3) != 1 || rd != 0;
        }
        break;
    }
    if (!r.legal) return R();
    r.rd = we ? (int)rd : 0;
    r.rs1 = (int)rs1; r.rs2 = (int)rs2;
    if (r.alu_v) r.alu2ok = r.asel == 0 && second_ok(r.alu_op);
    return r;
}

// the RVC expansion with Spike's extractors; false when reserved
static uint32_t enc_i(uint32_t opc, uint32_t f3, uint32_t rd, uint32_t rs1, int32_t imm) { return ((uint32_t)imm & 0xfff) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | opc; }
static uint32_t enc_s(uint32_t opc, uint32_t f3, uint32_t rs1, uint32_t rs2, int32_t imm) { uint32_t u = (uint32_t)imm; return bits(u, 11, 5) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | bits(u, 4, 0) << 7 | opc; }
static uint32_t enc_r(uint32_t opc, uint32_t f3, uint32_t f7, uint32_t rd, uint32_t rs1, uint32_t rs2) { return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | opc; }
static uint32_t enc_b(uint32_t f3, uint32_t rs1, uint32_t rs2, int32_t imm) { uint32_t u = (uint32_t)imm; return bits(u, 12, 12) << 31 | bits(u, 10, 5) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | bits(u, 4, 1) << 8 | bits(u, 11, 11) << 7 | 0x63; }
static uint32_t enc_j(uint32_t rd, int32_t imm) { uint32_t u = (uint32_t)imm; return bits(u, 20, 20) << 31 | bits(u, 10, 1) << 21 | bits(u, 11, 11) << 20 | bits(u, 19, 12) << 12 | rd << 7 | 0x6f; }

static bool expand16(uint16_t c, uint32_t& x)
{
    insn_t i(c);
    uint32_t q = c & 3, f3 = c >> 13, rd = (uint32_t)i.rvc_rd(), rs2 = (uint32_t)i.rvc_rs2(),
             rs1s = (uint32_t)i.rvc_rs1s(), rs2s = (uint32_t)i.rvc_rs2s();
    int32_t imm = (int32_t)i.rvc_imm();
    uint32_t zimm = (uint32_t)i.rvc_zimm();
    if (q == 0) {
        switch (f3) {
        case 0: if (i.rvc_addi4spn_imm() == 0) return false; x = enc_i(0x13, 0, rs2s, 2, (int32_t)i.rvc_addi4spn_imm()); return true;
        case 1: x = enc_i(0x07, 3, rs2s, rs1s, (int32_t)i.rvc_ld_imm()); return true;
        case 2: x = enc_i(0x03, 2, rs2s, rs1s, (int32_t)i.rvc_lw_imm()); return true;
        case 3: x = enc_i(0x03, 3, rs2s, rs1s, (int32_t)i.rvc_ld_imm()); return true;
        case 5: x = enc_s(0x27, 3, rs1s, rs2s, (int32_t)i.rvc_ld_imm()); return true;
        case 6: x = enc_s(0x23, 2, rs1s, rs2s, (int32_t)i.rvc_lw_imm()); return true;
        case 7: x = enc_s(0x23, 3, rs1s, rs2s, (int32_t)i.rvc_ld_imm()); return true;
        default: return false;
        }
    }
    if (q == 1) {
        switch (f3) {
        case 0: x = enc_i(0x13, 0, rd, rd, imm); return true;
        case 1: if (rd == 0) return false; x = enc_i(0x1b, 0, rd, rd, imm); return true;
        case 2: x = enc_i(0x13, 0, rd, 0, imm); return true;
        case 3:
            if (rd == 2) { if (i.rvc_addi16sp_imm() == 0) return false; x = enc_i(0x13, 0, 2, 2, (int32_t)i.rvc_addi16sp_imm()); return true; }
            if (imm == 0) return false;
            x = ((uint32_t)imm << 12) | rd << 7 | 0x37; return true;
        case 4: {
            uint32_t f2 = bits(c, 11, 10);
            if (f2 == 0) { x = enc_i(0x13, 5, rs1s, rs1s, (int32_t)zimm); return true; }
            if (f2 == 1) { x = enc_i(0x13, 5, rs1s, rs1s, (int32_t)(zimm | 0x400)); return true; }
            if (f2 == 2) { x = enc_i(0x13, 7, rs1s, rs1s, imm); return true; }
            uint32_t g = bits(c, 6, 5);
            if (!bits(c, 12, 12)) {
                static const uint32_t f3s[4] = {0, 4, 6, 7}, f7s[4] = {0x20, 0, 0, 0};
                x = enc_r(0x33, f3s[g], f7s[g], rs1s, rs1s, rs2s); return true;
            }
            if (g == 0) { x = enc_r(0x3b, 0, 0x20, rs1s, rs1s, rs2s); return true; }
            if (g == 1) { x = enc_r(0x3b, 0, 0x00, rs1s, rs1s, rs2s); return true; }
            return false;
        }
        case 5: x = enc_j(0, (int32_t)i.rvc_j_imm()); return true;
        case 6: x = enc_b(0, rs1s, 0, (int32_t)i.rvc_b_imm()); return true;
        default: x = enc_b(1, rs1s, 0, (int32_t)i.rvc_b_imm()); return true;
        }
    }
    // q == 2
    switch (f3) {
    case 0: x = enc_i(0x13, 1, rd, rd, (int32_t)zimm); return true;
    case 1: x = enc_i(0x07, 3, rd, 2, (int32_t)i.rvc_ldsp_imm()); return true;
    case 2: if (rd == 0) return false; x = enc_i(0x03, 2, rd, 2, (int32_t)i.rvc_lwsp_imm()); return true;
    case 3: if (rd == 0) return false; x = enc_i(0x03, 3, rd, 2, (int32_t)i.rvc_ldsp_imm()); return true;
    case 4:
        if (!bits(c, 12, 12)) {
            if (rs2 == 0) { if (rd == 0) return false; x = enc_i(0x67, 0, 0, rd, 0); return true; }
            x = enc_r(0x33, 0, 0, rd, 0, rs2); return true;
        }
        if (rs2 == 0 && rd == 0) { x = 0x00100073; return true; }           // ebreak
        if (rs2 == 0) { x = enc_i(0x67, 0, 1, rd, 0); return true; }
        x = enc_r(0x33, 0, 0, rd, rd, rs2); return true;
    case 5: x = enc_s(0x27, 3, 2, rs2, (int32_t)i.rvc_sdsp_imm()); return true;
    case 6: x = enc_s(0x23, 2, 2, rs2, (int32_t)i.rvc_swsp_imm()); return true;
    default: x = enc_s(0x23, 3, 2, rs2, (int32_t)i.rvc_sdsp_imm()); return true;
    }
}

// ---------------------------------------------------------------- Spike
// Whether an instruction exists is decided by running it in Spike (a
// processor_t built for mmRISC-2's instruction set, in M-mode with the FPU
// on, the registers pointing into a RAM): it does when it does not trap
// with an illegal instruction. The disassembler alone cannot say: it knows
// every extension, and it takes reserved RVC encodings. Two kinds are
// decided at run time and are not asked: CSR instructions (whether the CSR
// exists) and FP instructions with a reserved static rounding mode (the
// generator does not make those). Spike also runs vector instructions
// though V is not in its ISA, so those are not asked either.
class Ram : public simif_t {
public:
    explicit Ram(cfg_t* c) : ram(1 << 20, 0), cfg(c) {}
    char* addr_to_mem(reg_t a) override { return (a >= BASE && a - BASE < ram.size()) ? (char*)&ram[a - BASE] : nullptr; }
    bool mmio_load(reg_t, size_t, uint8_t*) override { return false; }
    bool mmio_store(reg_t, size_t, const uint8_t*) override { return false; }
    void proc_reset(unsigned) override {}
    const cfg_t& get_cfg() const override { return *cfg; }
    const std::map<size_t, processor_t*>& get_harts() const override { return harts; }
    const char* get_symbol(uint64_t) override { return nullptr; }
    static const reg_t BASE = 0x80000000ull;
    std::vector<uint8_t> ram;
    cfg_t* cfg;
    std::map<size_t, processor_t*> harts;
};
static const char* ISA = "rv64imafdc_zicboz_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zba_zbb_zbc_zbs";
static cfg_t scfg;
static isa_parser_t* sisa;
static Ram* sram;
static processor_t* sproc;
static disassembler_t* dis;
static FILE* sdevnull;
static std::ostringstream sout;

static void spike_init()
{
    scfg.isa = ISA;
    scfg.priv = "MSU";
    scfg.misaligned = false;
    scfg.pmpregions = 0;
    scfg.mem_layout = {mem_cfg_t(Ram::BASE, 1 << 20)};
    scfg.start_pc = Ram::BASE;
    scfg.hartids = {0};
    sisa = new isa_parser_t(ISA, "MSU");
    sram = new Ram(&scfg);
    sdevnull = std::fopen("/dev/null", "w");
    sproc = new processor_t(sisa, &scfg, sram, 0, false, sdevnull, sout);
    sram->harts[0] = sproc;
    dis = new disassembler_t(sisa);
}

static bool spike_legal(uint32_t raw)
{
    bool rvc = (raw & 3) != 3;
    if (!rvc && (raw & 0x7f) == 0x73 && ((raw >> 12) & 7) != 0 && ((raw >> 12) & 7) != 4) return true;   // CSR
    // Spike runs vector instructions without V in its ISA (OP-V, and the
    // vector widths of LOAD-FP / STORE-FP): they are not there by definition
    uint32_t vf3 = (raw >> 12) & 7;
    if (!rvc && ((raw & 0x7f) == 0x57 || (((raw & 0x7f) == 0x07 || (raw & 0x7f) == 0x27) && (vf3 == 0 || vf3 >= 5)))) return false;
    state_t* s = sproc->get_state();
    sproc->clear_waiting_for_interrupt();                   // (a wfi before leaves it waiting)
    s->prv = PRV_M;
    s->pc = Ram::BASE;
    for (int r = 1; r < 32; r++) s->XPR.write(r, Ram::BASE + 0x40000 + 8 * (reg_t)r);
    sproc->put_csr(CSR_MSTATUS, MSTATUS_FS | MSTATUS_MPP);       // FPU on, mret stays in M
    sproc->put_csr(CSR_MTVEC, Ram::BASE + 0x100);
    sproc->put_csr(CSR_MCAUSE, 0);
    sproc->put_csr(CSR_FCSR, 0);
    char* m = sram->addr_to_mem(Ram::BASE);
    uint32_t w = rvc ? (raw & 0xffff) : raw;
    std::memcpy(m, &w, 4);
    sproc->get_mmu()->flush_icache();
    reg_t i0 = sproc->get_csr(CSR_MINSTRET);
    sproc->step(1);
    if (sproc->get_csr(CSR_MINSTRET) != i0) return true;
    return sproc->get_csr(CSR_MCAUSE) != CAUSE_ILLEGAL_INSTRUCTION;
}
static std::string spike_name(uint32_t raw) { insn_t i(raw); return dis->disassemble(i); }

// ---------------------------------------------------------------- the DUT
static int g1(uint32_t v, int k) { return (v >> k) & 1; }
template <class T> static uint64_t gf(T v, int k, int w) { return ((uint64_t)v >> (k * w)) & ((1ull << w) - 1); }

// decoded in slot 0 only
static bool rare(const R& e) { return !e.legal || e.fp || e.fpmem || e.csr || e.sys || e.sfence || (e.mem && e.cmd != 0 && e.cmd != 1); }

static void check(int k, uint32_t raw, bool rvc, const R& e, long n, bool cut_exp)
{
    char why[160] = "";
    #define CK(name, got, exp) do { if ((long)(got) != (long)(exp) && !why[0]) snprintf(why, sizeof why, "%s %ld, expected %ld", name, (long)(got), (long)(exp)); } while (0)
    CK("cut", g1(d.cut, k), cut_exp);
    if (k > 0 && rare(e)) {                                  // only slot 0 decodes it
        if (why[0] && bad++ < 15)
            printf("case %ld slot %d: %s %08x (%s): %s\n", n, k, rvc ? "rvc" : "insn", raw, spike_name(raw).c_str(), why);
        return;
    }
    CK("illegal", g1(d.illegal, k), !e.legal);
    if (!e.legal) {                                          // nothing to rename, issue or wait for
        CK("cls", gf(d.cls, k, 3), 7); CK("op", gf(d.op, k, 3), 0); CK("rd", gf(d.rd, k, 5), 0);
        CK("alu2ok", g1(d.alu2ok, k), 0); CK("lat2", g1(d.lat2, k), 0); CK("ext_ans", g1(d.ext_ans, k), 0);
        CK("nonspec", g1(d.nonspec, k), 0); CK("port", gf(d.port, k, 2), 1);
    }
    if (e.legal) {
        CK("cls", gf(d.cls, k, 3), e.cls);
        CK("op", gf(d.op, k, 3), e.op);
        CK("rd", gf(d.rd, k, 5), e.rd);
        CK("use_rs1", g1(d.use_rs1, k), e.use1);
        CK("use_rs2", g1(d.use_rs2, k), e.use2);
        if (e.use1) CK("rs1", gf(d.rs1, k, 5), e.rs1);
        if (e.use2) CK("rs2", gf(d.rs2, k, 5), e.rs2);
        if (e.imm_v) CK("imm", d.imm[k], e.imm);
        CK("alu2ok", g1(d.alu2ok, k), e.alu2ok);
        CK("port", gf(d.port, k, 2), e.port);
        CK("lat2", g1(d.lat2, k), e.lat2);
        CK("ext_ans", g1(d.ext_ans, k), e.ext);
        CK("nonspec", g1(d.nonspec, k), e.nonspec);
        if (e.alu_v || e.jal || e.jalr) {
            CK("a_sel", gf(d.a_sel, k, 2), e.alu_v ? e.asel : e.jal ? 1 : 0);
            CK("b_sel", g1(d.b_sel, k), e.alu_v ? e.bsel : 1);
        }
        if (e.alu_v) {
            CK("alu_op", gf(d.alu_op, k, 6), e.alu_op);
            CK("a_uw", g1(d.a_uw, k), e.uw);
            CK("a_shift", gf(d.a_shift, k, 2), e.shift);
            CK("word_op", g1(d.word_op, k), e.word);
        }
        CK("is_branch", g1(d.is_branch, k), e.br);
        CK("is_jal", g1(d.is_jal, k), e.jal);
        CK("is_jalr", g1(d.is_jalr, k), e.jalr);
        if (e.br) CK("br_op", gf(d.br_op, k, 3), e.br_op);
        if (e.mdu) { CK("mdu_op", gf(d.mdu_op, k, 4), e.mdu_op); CK("word_op", g1(d.word_op, k), (raw & 0x7f) == 0x3b); }
        if (e.mem) {
            CK("mem_cmd", gf(d.mem_cmd, k, 5), e.cmd);
            if (e.cmd <= 13 || e.cmd == 16) CK("mem_size", gf(d.mem_size, k, 2), e.size);
            if (e.cmd == 0) CK("mem_signed", g1(d.mem_signed, k), e.sgn);
        }
        CK("sys", gf(d.sys, k, 8), e.sys);
        CK("is_sfence", g1(d.is_sfence, k), e.sfence);
        CK("is_csr", g1(d.is_csr, k), e.csr);
        if (e.csr) {
            CK("csr_addr", gf(d.csr_addr, k, 12), e.csr_addr);
            CK("csr_op", gf(d.csr_op, k, 2), e.csr_op);
            CK("csr_imm_sel", g1(d.csr_imm_sel, k), e.csr_imm);
            CK("csr_wr", g1(d.csr_wr, k), e.csr_wr);
            CK("csr_rd", g1(d.csr_rd, k), e.csr_rd);
        }
        CK("is_fp", g1(d.is_fp, k), e.fp);
        if (e.fp) {
            CK("fp_fmt", g1(d.fp_fmt, k), e.fmt);
            CK("use_fs", gf(d.use_fs, k, 3), e.ufs);
            CK("fp_we_rd", g1(d.fp_we_rd, k), e.fwe);
        }
        if (e.fpa) {
            CK("fp_op", gf(d.fp_op, k, 5), e.fop);
            CK("fp_rm", gf(d.fp_rm, k, 3), e.rm);
            if (e.ufs & 4) CK("rs3", gf(d.rs3, k, 5), e.rs3);
            if (e.cvt) { CK("fp_int_signed", g1(d.fp_int_signed, k), e.isg); CK("fp_int_w", g1(d.fp_int_w, k), e.iw); }
        }
    }
    if (why[0] && bad++ < 15)
        printf("case %ld slot %d: %s %08x (%s): %s\n", n, k, rvc ? "rvc" : "insn", raw, spike_name(raw).c_str(), why);
}

// the 4 slots: cut from the first rare class in slot 1 to 3 on
static void check_group(const uint32_t* raws, const bool* rv, const R* es, long n)
{
    bool cut = false;
    for (int s = 0; s < 4; s++) {
        if (s > 0 && rare(es[s])) cut = true;
        check(s, raws[s], rv[s], es[s], n, cut);
    }
}

// a 32-bit word from the encodings that exist (mostly)
static uint32_t gen32_();
static uint32_t gen32()
{
    uint32_t x = gen32_() | 3;
    uint32_t o = x & 0x7f;
    if ((o == 0x43 || o == 0x47 || o == 0x4b || o == 0x4f || o == 0x53) && (((x >> 12) & 7) == 5 || ((x >> 12) & 7) == 6))
        x ^= 4u << 12;                                     // (a reserved rounding mode is a run-time matter)
    return x;
}
static uint32_t gen32_()
{
    static const uint32_t opcs[] = {0x37, 0x17, 0x6f, 0x67, 0x63, 0x03, 0x23, 0x13, 0x1b, 0x33, 0x3b, 0x2f, 0x07, 0x27,
                                    0x43, 0x47, 0x4b, 0x4f, 0x53, 0x0f, 0x73};
    static const uint32_t f7s[] = {0x00, 0x20, 0x01, 0x05, 0x10, 0x04, 0x07, 0x14, 0x24, 0x34, 0x30, 0x09, 0x18, 0x02,
                                   0x06, 0x12, 0x0a, 0x1a, 0x08, 0x0c, 0x50, 0x60, 0x70, 0x78, 0x2c, 0x2d, 0x10, 0x11, 0x21};
    uint32_t x = (uint32_t)rng();
    int r = (int)(rng() % 10);
    if (r == 0) return x | 3;                              // anything
    x = (x & ~0x7fu) | opcs[rng() % (sizeof opcs / sizeof opcs[0])];
    if (r < 6) x = (x & 0x01ffffffu) | f7s[rng() % (sizeof f7s / sizeof f7s[0])] << 25;
    if (rng() % 4 == 0) x &= ~(0x1fu << 20) | ((uint32_t)(rng() % 4) << 20);     // small rs2 (FP conversions, zext.h)
    if (rng() % 6 == 0) x &= ~(0x1fu << 7);                // rd = 0
    if (rng() % 6 == 0) x &= ~(0x1fu << 15);               // rs1 = 0
    if ((x & 0x7f) == 0x73 && rng() % 2) {                 // the system instructions
        static const uint32_t f12[] = {0x000, 0x001, 0x302, 0x102, 0x105, 0x7b2, 0x002, 0x104};
        x = (x & 0x000fffffu) | f12[rng() % 8] << 20;
        if (rng() % 2) x &= ~(0x1fu << 7 | 0x1fu << 15 | 0x7u << 12);
    }
    if ((x & 0x7f) == 0x0f && rng() % 2) x = (x & 0x000fffffu) | (uint32_t)(rng() % 6) << 20;   // cbo
    if (((x & 0x7f) == 0x13 || (x & 0x7f) == 0x1b) && rng() % 2) {    // shifts, Zbb / Zbs immediates
        static const uint32_t f12[] = {0x600, 0x601, 0x602, 0x604, 0x605, 0x287, 0x6b8, 0x080, 0x000, 0x400, 0x600, 0x480};
        x = (x & 0x000fffffu) | (f12[rng() % 12] | (rng() % 2 ? (uint32_t)(rng() % 64) : 0)) << 20;
    }
    return x;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    spike_init();
    long n = 0, ref_bad = 0;
    // ---- every RVC encoding, in slot (n mod 4), with 32-bit ones in the others
    for (uint32_t c = 0; c < 65536; c++) {
        if ((c & 3) == 3) continue;
        uint32_t x = 0;
        bool ok = expand16((uint16_t)c, x);
        R e = ok ? decode32(x) : R();
        bool sl = spike_legal(c);
        if (e.legal != sl && ref_bad++ < 8) printf("reference: rvc %04x (%s) legal %d, Spike %d\n", c, spike_name(c).c_str(), e.legal, sl);
        int k = (int)(n % 4);
        uint32_t raws[4]; R es[4]; bool rv[4];
        for (int s = 0; s < 4; s++) {
            if (s == k || s == 0) { raws[s] = c; es[s] = e; rv[s] = true; }
            else { raws[s] = gen32() | 3; es[s] = decode32(raws[s]); rv[s] = false; }
            d.in_inst[s] = raws[s];
        }
        d.in_rvc = (1 << k) | 1;
        d.eval();
        check_group(raws, rv, es, n);
        nrvc++; nlegal += e.legal; nill += !e.legal;
        n++;
    }
    // ---- 32-bit instructions
    for (long t = 0; t < 750000; t++) {
        uint32_t raws[4]; R es[4];
        for (int s = 0; s < 4; s++) {
            raws[s] = gen32() | 3;
            es[s] = decode32(raws[s]);
            bool sl = spike_legal(raws[s]);
            if (es[s].legal != sl) { static std::map<int, int> seen; if (seen[(int)(raws[s] & 0x7f) * 2 + sl]++ < 3) printf("reference: %08x (%s) legal %d, Spike %d\n", raws[s], spike_name(raws[s]).c_str(), es[s].legal, sl); ref_bad++; }
            d.in_inst[s] = raws[s];
            nlegal += es[s].legal; nill += !es[s].legal;
        }
        d.in_rvc = 0;
        d.eval();
        bool rv[4] = {false, false, false, false};
        check_group(raws, rv, es, n);
        n++;
    }
    printf("tb_dec: %ld RVC encodings and %ld instructions (%ld legal, %ld illegal), reference against Spike %ld differences, %ld mismatches: %s\n",
           nrvc, 3000000L, nlegal, nill, ref_bad, bad, (bad || ref_bad) ? "FAIL" : "PASS");
    return (bad || ref_bad) ? 1 : 0;
}
