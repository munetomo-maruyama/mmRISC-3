#!/bin/bash
#---------------------------------------------------------------------------
# g0b.sh : the levers of the G0b budget review (Doc/UARCH.md 6.3) in the
# 2-wide out-of-order model (ooo.h)
#
#   ./g0b.sh           -> results/g0b.txt
#
# The base is the design as written: G0 with the entries of µops issued on
# an open load kept until c + 3 (OOO_IQ, keep_spec=3). Columns as g0.sh:
# CoreMark/MHz of g14 -O2, g14 sf + -flto, g13 -O2 Zba / Zbb.
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
    printf "| %-58s | %6s | %6s | %6s |\n" "$l" "$(cm g14-o2-zbsc "$@")" "$(cm g14-sflto-zbsc "$@")" "$(cm g13-o2-zb "$@")"
}
F="fusion=3 fuse_2src=1 fuse_1w=1"                       # fusion: 2 sources, 1 write per pair
F2="fusion=2 fuse_2src=1 fuse_1w=1"                      # fusion level 2: no ALU + ALU
B="ubtb=16 rob=24 iq=12 lq=12 sq=12 ckpt=6 fb=16"         # the G0 configuration
P="fe_depth=4 dec_depth=3 iss_to_ex=3 override_at=3 lat_load=3"   # pessimistic pipeline
K="keep_spec=3"                                           # OOO_IQ as written
S="ubtb=8 rob=24 iq=12 lq=8 sq=8 ckpt=6 fb=8"             # the three small-loss levers (L4 to L6)
{
echo "| configuration | -O2 | max | g13 |"
echo "|---|---|---|---|"
row "base: G0 as written (kept until c + 3)"               $B $F $K
row "base, pessimistic"                                    $B $F $K $P
echo "| **one lever at a time** | | | |"
row "replay trap at commit (no kept entries; misses free)" $B $F
row "issue queue 12 -> 10"                                 $B $F $K iq=10
row "issue queue 12 -> 8"                                  $B $F $K iq=8
row "ROB 24 -> 20"                                         $B $F $K rob=20
row "ROB 24 -> 16"                                         $B $F $K rob=16
row "checkpoints 6 -> 4"                                   $B $F $K ckpt=4
row "L4: LQ / SQ 12 -> 8"                                  $B $F $K lq=8 sq=8
row "L5: uBTB 16 -> 8"                                     $B $F $K ubtb=8
row "L6: fetch buffer 16 -> 8"                             $B $F $K fb=8
row "multiply latency 2 -> 3"                              $B $F $K lat_mul=3
row "L9: fusion level 2 (no ALU + ALU)"                    $B $F2 $K
echo "| **sets** | | | |"
row "L4 to L6"                                             $S $F $K
row "L4 to L6 + iq 10"                                     $S $F $K iq=10
row "L4 to L6 + iq 10 + ckpt 4"                            $S $F $K iq=10 ckpt=4
row "L4 to L6 + iq 10 + ckpt 4, pessimistic"               $S $F $K iq=10 ckpt=4 $P
row "L4 to L6 + iq 10 + ckpt 4 + rob 20"                   $S $F $K iq=10 ckpt=4 rob=20
row "L4 to L6 + iq 8 + ckpt 4"                             $S $F $K iq=8 ckpt=4
row "L4 to L6 + iq 10 + ckpt 4 + fusion 2"                 $S $F2 $K iq=10 ckpt=4
row "L4 to L6 + iq 10 + ckpt 4 + fusion 2, pessimistic"    $S $F2 $K iq=10 ckpt=4 $P
row "L4 to L6 + iq 10 + ckpt 4, trap at commit"            $S $F iq=10 ckpt=4
row "no fusion (2-wide decode), base sizes"                $B fusion=0 dec_w=2 $K
echo "| **candidate sets (Doc/UARCH.md 6.3)** | | | |"
row "R1: L4 to L6, trap at commit"                         $S $F
row "R1, pessimistic"                                      $S $F $P
row "R2: R1 + fusion 2"                                    $S $F2
row "R2, pessimistic"                                      $S $F2 $P
row "R3: R2 + iq 10 (end state A of 6.3)"                  $S $F2 iq=10
row "R3, pessimistic"                                      $S $F2 iq=10 $P
row "R4: R1 without fusion (2-wide decode)"                $S fusion=0 dec_w=2
row "R4, pessimistic"                                      $S fusion=0 dec_w=2 $P
row "R5: R4 + iq 10 (end state B of 6.3)"                  $S fusion=0 dec_w=2 iq=10
row "R5, pessimistic"                                      $S fusion=0 dec_w=2 iq=10 $P
echo "| **the decided set (D-11 to D-14, L6 back) and L7 (Doc/UARCH.md 6.11)** | | | |"
D="ubtb=8 rob=24 iq=10 lq=8 sq=8 ckpt=6 fb=16 $F2"
row "decided set (trap at commit, iq 10, L4, L5, fusion 2)"   $D
row "decided set, pessimistic"                             $D $P
row "decided set, ALU0 / ALU1 apart (MUL / DIV on ALU0)"     $D alu_split=1
row "+ L7, a simple µop takes ALU1 first"                  $D alu_split=2
row "+ L7, a simple µop takes ALU1 first, pessimistic"     $D alu_split=2 $P
row "+ L7, a simple µop takes ALU0 first"                  $D alu_split=3
echo "| **D-15 / D-16 (Plan/OOC.md 21, 23): redirect 2, mmRISC-2's CORE_MDU** | | | |"
row "L7 + D-15 (fetch restarts a cycle after the resolution)"  $D alu_split=2 redirect=2
row "+ D-16: CORE_MDU, mul latency 2 one in 2 cycles, others from outside" $D alu_split=2 redirect=2 mdu_busy=2
row "+ CORE_MDU with every operation from outside (latency 4)" $D alu_split=2 redirect=2 mdu_busy=2 lat_mul=4
row "D-16, pessimistic"                                        $D alu_split=2 redirect=2 mdu_busy=2 $P
} | tee results/g0b.txt
