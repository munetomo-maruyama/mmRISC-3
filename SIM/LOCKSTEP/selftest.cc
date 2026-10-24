//---------------------------------------------------------------------------
// selftest.cc : the lock-step checker (lockstep.h) tested without a core
//
//   selftest [-isa <isa>] [-n <mutations per file>] <elf> ...
//
// A second reference instance stands in for the DUT and produces the commit
// stream of a correct core. For every ELF file:
//   1. clean   the stream as it is must pass to the end (HTIF exit); the
//              program's own exit code is reported (riscv-tests: 0 = PASS)
//              and listed when not 0, but it is the program's verdict on the
//              reference, not the checker's
//   2. fused   the stream with "first halves of fused pairs" marked: an
//              instruction whose register the next one overwrites, with its
//              value scrambled and rd_skip set; must still pass
//   3. mutated -n runs, each with one wrong field at a random commit (10
//              kinds below); each must be caught at that very commit (a
//              dropped commit: at the next one)
// The exit code is the number of failures (a clean or fused run with a
// mismatch or without an HTIF exit, a mutation not caught or caught at the
// wrong place).
//---------------------------------------------------------------------------
#include "lockstep.h"

#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

static const char* KIND[] = {
    "register value", "register number", "write missing", "pc", "instruction",
    "trap flag", "trap cause", "store data", "store missing", "commit dropped",
};
static const int NKIND = 10;

static const uint64_t LIMIT = 50000000;   // instructions per run at most

// the commits of a correct core, for the whole run
static std::vector<Commit> record(const LockstepCfg& c, int* code, std::string* out)
{
    Lockstep dut(c);
    std::vector<Commit> v;
    while (!dut.exited() && v.size() < LIMIT) v.push_back(dut.step_ref());
    *code = dut.exited() ? dut.exit_code() : -1;
    *out = dut.output();
    return v;
}

// feed a stream to a fresh checker; the index of the first mismatch or -1
static long feed(const LockstepCfg& c, const std::vector<Commit>& v, std::string* why)
{
    Lockstep ref(c);
    for (size_t i = 0; i < v.size(); i++)
        if (!ref.check(v[i], why)) return (long)i;
    return -1;
}

// does kind k apply to commit x
static bool applies(int k, const Commit& x)
{
    switch (k) {
    case 0: case 2: return !x.trap && x.rd >= 0;
    case 1: return !x.trap && x.rd > 0 && !x.rd_fp;
    case 5: return true;
    case 6: return x.trap;
    case 7: case 8: return !x.trap && x.st;
    default: return true;
    }
}

static void mutate(int k, Commit& x, std::mt19937_64& rng)
{
    switch (k) {
    case 0: x.rd_val ^= 1ull << (rng() % 64); break;
    case 1: x.rd = (x.rd % 31) + 1; break;            // another integer register
    case 2: x.rd = -1; break;
    case 3: x.pc += 2; break;
    case 4: x.insn ^= 1u << (2 + rng() % 14); break;    // keep the length bits
    case 5: x.trap = !x.trap; break;
    case 6: x.cause ^= 1; break;
    case 7: x.st_data ^= 1ull << (rng() % (8 * x.st_size)); break;
    case 8: x.st = false; break;
    default: break;
    }
}

int main(int argc, char** argv)
{
    LockstepCfg base;
    int nmut = 40;
    std::vector<std::string> elfs;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-isa" && i + 1 < argc) base.isa = argv[++i];
        else if (a == "-n" && i + 1 < argc) nmut = atoi(argv[++i]);
        else elfs.push_back(a);
    }
    std::mt19937_64 rng(2026);
    int fails = 0;
    long caught_total = 0, mut_total = 0;
    std::vector<std::string> nonzero;     // programs whose exit code is not 0
    for (auto& e : elfs) {
        LockstepCfg c = base;
        c.elf = e;
        std::string name = e.substr(e.find_last_of('/') + 1);
        int code; std::string out, why;
        std::vector<Commit> v;
        try {
            v = record(c, &code, &out);
        } catch (std::exception& ex) {
            printf("%-28s ERROR %s\n", name.c_str(), ex.what()); fails++; continue;
        }
        // 1. clean
        long at = feed(c, v, &why);
        bool clean = at < 0 && code >= 0;          // no mismatch, and the program exited
        // 2. fused: mark first halves
        std::vector<Commit> f = v;
        long npair = 0;
        for (size_t i = 0; i + 1 < f.size(); i++)
            if (!f[i].trap && !f[i].st && f[i].rd > 0 && !f[i + 1].trap && f[i + 1].rd == f[i].rd &&
                f[i + 1].rd_fp == f[i].rd_fp && rng() % 2) {
                f[i].rd_skip = true; f[i].rd_val ^= 0x5a5a; npair++; i++;
            }
        std::string whyf;
        long atf = feed(c, f, &whyf);
        // 3. mutations
        int caught = 0;
        std::vector<int> missed;
        for (int m = 0; m < nmut && v.size() > 1; m++) {
            int k = m % NKIND;
            size_t i = rng() % (v.size() - 1), tries = 0;
            while (!applies(k, v[i]) && tries++ < v.size()) i = (i + 1) % (v.size() - 1);
            if (!applies(k, v[i])) { k = 3; }        // nothing to apply it to: a wrong pc instead
            std::vector<Commit> w = v;
            long expect = (long)i;
            if (k == 9) w.erase(w.begin() + i);       // the checker sees the next commit at i
            else mutate(k, w[i], rng);
            std::string whym;
            long got = feed(c, w, &whym);
            if (got == expect) caught++;
            else missed.push_back(k);
            mut_total++;
        }
        caught_total += caught;
        bool ok = clean && atf < 0 && caught == std::min<int>(nmut, v.size() > 1 ? nmut : 0);
        printf("%-28s %9zu insns  exit %d  clean %s  fused %s (%ld pairs)  mutations %d/%d caught%s\n",
               name.c_str(), v.size(), code, clean ? "PASS" : "FAIL", atf < 0 ? "PASS" : "FAIL", npair,
               caught, nmut, ok ? "" : "  <-- FAIL");
        if (at >= 0) printf("    clean run: mismatch at commit %ld: %s\n", at, why.c_str());
        if (code != 0) {
            nonzero.push_back(name + " (" + std::to_string(code) + ")");
            if (!out.empty()) printf("    output: %.200s\n", out.c_str());
        }
        if (atf >= 0) printf("    fused run: mismatch at commit %ld: %s\n", atf, whyf.c_str());
        for (int k : missed) printf("    not caught at its commit: %s\n", KIND[k]);
        if (!ok) fails++;
    }
    printf("programs with a nonzero exit code:");
    for (auto& n : nonzero) printf(" %s", n.c_str());
    printf("%s\n", nonzero.empty() ? " none" : "");
    printf("lockstep selftest: %zu files, %ld of %ld mutations caught, %d failures: %s\n", elfs.size(),
           caught_total, mut_total, fails, fails ? "FAIL" : "PASS");
    return fails;
}
