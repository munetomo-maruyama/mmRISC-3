#!/bin/bash
#---------------------------------------------------------------------------
# g100.sh : the micro-architecture for 100 MHz (Doc/STRATEGY.md 4): the model
# in a 100 MHz pipeline, the configurations, then each assumption
#
#   ./g100.sh          -> results/g100.txt
#
# The pipeline P: fetch 5 stages (override at 3), decode and rename 5, select
# to EX 3, redirect 6 after EX, load-use 3, mul 4 (pipelined). Distributed
# schedulers: a µop bound at dispatch to the emptiest ALU queue, issued only
# on its port; loads and stores in their own queue.
# Columns: CoreMark/MHz of g14 -O2, g14 sf + -flto, g13 -O2 Zba / Zbb.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
mkdir -p work results
g++ -O2 -std=c++17 -Wall -o work/model model.cpp || exit 1
B="ubtb=16 fb=16 fuse_2src=1 fuse_1w=1 alu_split=0 mdu_busy=0 st_data_issue=1 mul_wb=0 fusion=0 pred=M"
P="fe_depth=5 override_at=3 dec_depth=5 iss_to_ex=3 redirect=6 lat_load=3 lat_mul=4"
S4="w=4 rob=48 lq=16 sq=16 ckpt=12"
G="$P $S4 iqd=3 iq=8 iql=12 alu=3 lsu=1 issue_w=4"          # 4-wide, 4 issues
J="$G st_data_issue=0 dec_w=6 fetch_bytes=32"               # the proposal
row() {   # row <label> <options...>
    local l=$1; shift
    cm() { ./work/model ooo work/$1.bin $B "${@:2}" | sed -n 's/.*CoreMark\/MHz \([0-9.]*\).*/\1/p'; }
    printf "| %-60s | %6s | %6s | %6s |\n" "$l" "$(cm g14-o2-zbsc "$@")" "$(cm g14-sflto-zbsc "$@")" "$(cm g13-o2-zb "$@")"
}
{
echo "| configuration | -O2 | max | g13 |"
echo "|---|---|---|---|"
echo "| **in the 100 MHz pipeline** | | | |"
row "3-wide, 3 ALUs + LSU (4 issues), q8, mem 12"   $P w=3 rob=32 lq=12 sq=12 ckpt=8 iqd=3 iq=8 iql=12 alu=3 lsu=1 issue_w=4
row "4-wide, 3 ALUs + LSU (4 issues), q8, mem 12"   $G
row "  + stores split"                              $G st_data_issue=0
row "  + 6 decoded, 32-byte fetch"                  $G dec_w=6 fetch_bytes=32
row "**the proposal**: + both"                      $J
row "the proposal, unified IQ 24 (for scale)"       $P $S4 iq=24 alu=3 lsu=1 issue_w=4 st_data_issue=0 dec_w=6 fetch_bytes=32
row "the proposal + a second LSU port (5 issues)"   $J lsu=2 issue_w=5 iql=16
row "the proposal + a fourth ALU (5 issues)"        $J iqd=4 alu=4 issue_w=5
row "both of those (6 issues)"                      $J iqd=4 alu=4 lsu=2 issue_w=6 iql=16
echo "| **the proposal, each assumption** | | | |"
row "load-use 4"                                    $J lat_load=4
row "load-use 5"                                    $J lat_load=5
row "ALU 2 cycles (wakeup-select does not fit)"     $J lat_alu=2
row "Zbb 2 cycles"                                  $J cplx2=8
row "Zbs, Zicond 2 cycles"                          $J cplx2=48
row "Zba 2 cycles"                                  $J cplx2=4
row "shifts 2 cycles"                               $J cplx2=2
row "fetch 4, decode 4, redirect 5 (shorter)"       $J fe_depth=4 dec_depth=4 redirect=5
row "decode 6, select to EX 4, redirect 8 (longer)" $J dec_depth=6 iss_to_ex=4 redirect=8
row "queues of 6"                                   $J iq=6
row "queues of 12"                                  $J iq=12
row "OOO_SCHED: hold, 2 writes a queue, steering"    $J hold=1 qw=2 qwl=2 steer=2
row "  1 write a queue, 2 into memory"               $J hold=1 qw=1 qwl=2 steer=2
row "  + queues of 10"                               $J hold=1 qw=2 qwl=2 steer=2 iq=10
row "ROB 32, LQ / SQ 12, 8 checkpoints"             $P w=4 rob=32 lq=12 sq=12 ckpt=8 iqd=3 iq=8 iql=12 alu=3 lsu=1 issue_w=4 st_data_issue=0 dec_w=6 fetch_bytes=32
row "ROB 64, LQ / SQ 24, 16 checkpoints"            $P w=4 rob=64 lq=24 sq=24 ckpt=16 iqd=3 iq=8 iql=12 alu=3 lsu=1 issue_w=4 st_data_issue=0 dec_w=6 fetch_bytes=32
row "uBTB 8"                                        $J ubtb=8
row "uBTB 32"                                       $J ubtb=32
row "uBTB answers a cycle late: a bubble on every taken branch" $J taken_gap=2
row "uBTB 4, no bubble"                              $J ubtb=4
row "TAGE L"                                        $J pred=L
row "TAGE S"                                        $J pred=S
row "the multiply through CORE_MDU, one in 4 cycles" $J mdu_busy=4
} | tee results/g100.txt
