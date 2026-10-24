#!/bin/bash
#---------------------------------------------------------------------------
# g0.sh : the configurations of the G0 specification (Doc/UARCH.md) in the
# 2-wide out-of-order model (ooo.h)
#
#   ./g0.sh            -> results/g0.txt
#
# Columns: CoreMark/MHz of g14 -O2 (the -O2 goal), g14 sf + -flto (the most
# optimization) and g13 -O2 Zba / Zbb (mmRISC-2's condition).
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
mkdir -p work results
g++ -O2 -std=c++17 -Wall -o work/model model.cpp || exit 1
for b in g14-o2-zbsc g14-sflto-zbsc g13-o2-zb; do
    [ -s work/$b.bin ] || python3 mktrace.py ../trace/work/$b.trace.gz work/$b.bin || exit 1
done

row() {   # row <label> <options...>
    local l=$1; shift
    cm() { ./work/model ooo work/$1.bin "${@:2}" | sed -n 's/.*CoreMark\/MHz \([0-9.]*\).*/\1/p'; }
    printf "| %-52s | %6s | %6s | %6s |\n" "$l" "$(cm g14-o2-zbsc "$@")" "$(cm g14-sflto-zbsc "$@")" "$(cm g13-o2-zb "$@")"
}
F="fusion=3 fuse_2src=1 fuse_1w=1"                      # fusion: 2 sources, 1 write per pair
G="ubtb=16 rob=24 iq=12 lq=12 sq=12 ckpt=6"              # the G0 configuration
P="fe_depth=4 dec_depth=3 iss_to_ex=3 override_at=3 lat_load=3"   # pessimistic pipeline
{
echo "| configuration | -O2 | max | g13 |"
echo "|---|---|---|---|"
row "before G0 (rob 32, iq 16, ckpt 8)"            ubtb=16 rob=32 iq=16 lq=12 sq=12 ckpt=8 $F
row "G0"                                             $G $F
row "G0 pessimistic"                                 $G $F $P
row "G0 + W5 (2 writes per pair, buy back)"          $G fusion=3 fuse_2src=1
row "G0 + LQ / SQ 8"                                 $G $F lq=8 sq=8
row "G0 + uBTB 8"                                    $G $F ubtb=8
row "G0 + fetch buffer 8"                            $G $F fb=8
row "G0 + all three small-loss levers"               ubtb=8 rob=24 iq=12 lq=8 sq=8 ckpt=6 fb=8 $F
row "G0 + all three, pessimistic"                    ubtb=8 rob=24 iq=12 lq=8 sq=8 ckpt=6 fb=8 $F $P
row "G0 without ALU + ALU (fusion 2)"                $G fusion=2 fuse_2src=1 fuse_1w=1
row "G0 without fusion (2-wide decode)"              $G fusion=0 dec_w=2
row "G0 without fusion, pessimistic"                 $G fusion=0 dec_w=2 $P
row "G0 + one checkpoint a cycle (ck1)"              $G $F ck1=1
row "G0 + 3-cycle load-use"                          $G $F lat_load=3
row "G0 + one more stage issue to EX"                $G $F iss_to_ex=3
row "G0 + gshare instead of TAGE-S"                  $G $F pred=gshare
} | tee results/g0.txt
