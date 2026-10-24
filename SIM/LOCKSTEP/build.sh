#!/bin/bash
#---------------------------------------------------------------------------
# build.sh : the lock-step checker (lockstep.cc) and its self-test
#
#   ./build.sh              -> obj/selftest
#   SPIKE=<spike-install>   another Spike installation
#
# Always built from scratch: the shared folder keeps file times to one
# second, so make cannot be trusted to see an edit.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
S=${SPIKE:-$HOME/RISCV/toolchain/spike-install}
mkdir -p obj
g++ -std=c++17 -O2 -Wall -I$S/include -I$S/include/riscv -I$S/include/softfloat -I$S/include/fesvr \
    lockstep.cc selftest.cc -o obj/selftest \
    -L$S/lib -lriscv -lsoftfloat -ldisasm -lfesvr -Wl,-rpath,$S/lib -lpthread -ldl
