//---------------------------------------------------------------------------
// model.h : the trace records of mktrace.py, and what the models share
//---------------------------------------------------------------------------
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#pragma pack(push, 1)
struct Rec {
    uint64_t pc;
    uint64_t mem;       // 0: no memory access
    uint8_t  size;      // 2 or 4
    uint8_t  cls;
    uint8_t  sub;
    uint8_t  flags;
    uint8_t  src[3];    // 255: none
    uint8_t  dst;       // 255: none (and never x0)
    uint8_t  base;
    uint8_t  op;
    uint16_t pad0;
    uint32_t pad1;
};
#pragma pack(pop)
static_assert(sizeof(Rec) == 32, "record of mktrace.py");

enum Cls { C_ALU, C_BR, C_JAL, C_JALR, C_LOAD, C_STORE, C_MUL, C_DIV, C_SYS, C_FP };
enum Flag { F_TAKEN = 1, F_CALL = 2, F_RET = 4, F_MULH = 8 };
enum Op { OP_OTHER, OP_LUI, OP_AUIPC, OP_SLLI, OP_SRLI, OP_ADD, OP_ADDI };
static const uint8_t NOREG = 255;

inline bool is_cti(const Rec& r) { return r.cls == C_BR || r.cls == C_JAL || r.cls == C_JALR; }

inline bool reads(const Rec& r, uint8_t reg)
{
    return reg != NOREG && (r.src[0] == reg || r.src[1] == reg || r.src[2] == reg);
}

inline std::vector<Rec> load_trace(const char* path)
{
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f) / (long)sizeof(Rec);
    fseek(f, 0, SEEK_SET);
    std::vector<Rec> t(n);
    if (fread(t.data(), sizeof(Rec), n, f) != (size_t)n) { fprintf(stderr, "short read\n"); exit(1); }
    fclose(f);
    return t;
}

// key=value options of the command line, with defaults
struct Opts {
    std::map<std::string, std::string> kv;
    Opts(int argc, char** argv, int first)
    {
        for (int i = first; i < argc; i++) {
            const char* e = strchr(argv[i], '=');
            if (!e) { fprintf(stderr, "option %s is not key=value\n", argv[i]); exit(1); }
            kv[std::string(argv[i], e - argv[i])] = e + 1;
        }
    }
    long get(const char* k, long d)
    {
        auto it = kv.find(k);
        if (it == kv.end()) return d;
        long v = strtol(it->second.c_str(), nullptr, 0);
        kv.erase(it);
        return v;
    }
    void check()    // every option given was used
    {
        for (auto& p : kv) { fprintf(stderr, "unknown option %s\n", p.first.c_str()); exit(1); }
    }
};
