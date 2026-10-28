#!/bin/bash
#---------------------------------------------------------------------------
# build.sh : the core's test bench (bench.cc) with the stand-in core
#
#   ./build.sh              -> obj/standin
#   SPIKE=<spike-install>   another Spike installation
#   BENCH=<file> LOCKSTEP=<file> OUT=<file>
#                           other bench.cc / lockstep.cc and output (the bug
#                           injection of mutate.sh)
#
# Built from scratch every time (the shared folder keeps file times to one
# second), C++17 for Spike's headers, as SIM/LOCKSTEP/build.sh.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
S=${SPIKE:-$HOME/RISCV/toolchain/spike-install}
mkdir -p obj
g++ -std=c++17 -O2 -Wall -Wno-c++20-extensions -I. -I../LOCKSTEP \
    -I$S/include -I$S/include/riscv -I$S/include/softfloat -I$S/include/fesvr \
    ${BENCH:-bench.cc} ${LOCKSTEP:-../LOCKSTEP/lockstep.cc} standin.cc -o ${OUT:-obj/standin} \
    -L$S/lib -lriscv -lsoftfloat -ldisasm -lfesvr -Wl,-rpath,$S/lib -lpthread -ldl
