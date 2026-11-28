//---------------------------------------------------------------------------
// sim_main.cpp : LiteX's simulation SoC (litex_sim's sim.v) on mmRISC-3, driven
//                without litex_sim's own modules (they need libevent): the
//                clock, and the UART's stream to stdout (step 2.6,
//                LitexSystem/docs/BRINGUP.md 28; run_sim.sh)
//
//   Vsim [max_cycles] [command]
//   (built with --trace: VCD=<file> dumps cycles VCD_FROM to VCD_TO, the environment's)
//
// Prints what the BIOS sends; at the first "litex>" it types the command (if
// any) and ends at the next "litex>", or at max_cycles (a failure, exit 1).
//---------------------------------------------------------------------------
#include "Vsim.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    long max = argc > 1 ? atol(argv[1]) : 50000000L;
    std::string cmd = argc > 2 ? std::string(argv[2]) + "\r" : "";
    Vsim *top = new Vsim;
#if VM_TRACE
    VerilatedVcdC *vcd = nullptr;
    long v_from = getenv("VCD_FROM") ? atol(getenv("VCD_FROM")) : 0;
    long v_to   = getenv("VCD_TO")   ? atol(getenv("VCD_TO"))   : 0;
    if (getenv("VCD")) {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC;
        top->trace(vcd, 99);
        vcd->open(getenv("VCD"));
    }
#endif
    top->serial_source_ready = 1;
    top->serial_sink_valid   = 0;
    std::string seen;
    int prompts = 0;
    bool esc = false;
    size_t sent = 0;
    long c;
    for (c = 0; c < max; c++) {
        top->sys_clk = 0; top->eval();
#if VM_TRACE
        if (vcd && c >= v_from && c < v_to) vcd->dump((uint64_t)(2 * c));
#endif
        top->sys_clk = 1; top->eval();
#if VM_TRACE
        if (vcd && c >= v_from && c < v_to) vcd->dump((uint64_t)(2 * c + 1));
#endif
        if (top->serial_source_valid) {
            char ch = (char)top->serial_source_data;
            putchar(ch); fflush(stdout);
            // the prompt is "litex" ESC[0m ">": the escape sequences left out of what is matched
            if (ch == 27) esc = true;
            else if (esc) { if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) esc = false; }
            else seen += ch;
            if (seen.size() >= 6 && seen.compare(seen.size() - 6, 6, "litex>") == 0) {
                prompts++;
                fprintf(stderr, "\n[sim] litex> at cycle %ld\n", c);
                if (prompts == 1 && !cmd.empty()) sent = 0;
                else break;
            }
            if (seen.size() > 64) seen.erase(0, seen.size() - 64);
        }
        // the command, a character every 2,000 cycles once the prompt is out
        if (prompts == 1 && sent < cmd.size()) {
            if (top->serial_sink_valid && top->serial_sink_ready) { top->serial_sink_valid = 0; sent++; }
            else if (!top->serial_sink_valid && c % 2000 == 0) { top->serial_sink_data = cmd[sent]; top->serial_sink_valid = 1; }
        }
    }
    top->final();
#if VM_TRACE
    if (vcd) vcd->close();
#endif
    if (c >= max) { fprintf(stderr, "\n[sim] FAIL: no prompt in %ld cycles\n", max); return 1; }
    fprintf(stderr, "[sim] PASS at cycle %ld\n", c);
    return 0;
}
