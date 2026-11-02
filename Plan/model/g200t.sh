#!/bin/bash
#---------------------------------------------------------------------------
# g200t.sh : what the XC7A200T makes possible (Doc/STRATEGY.md 3): the model
# from the configuration of the core as it is, one lever at a time, then the
# combinations
#
#   ./g200t.sh         -> results/g200t.txt
#
# The base is the core of 2026-11-02 (Plan/CORE.md 5.22): 2-wide, ROB 24, IQ
# 10, LQ / SQ 8, 6 checkpoints, uBTB 8, a limited ALU1, CORE_MDU, stores
# issued with their data, a multiply's write slot on ALU1, three decode
# stages, the redirect a cycle after the registered resolution, fusion off.
# Columns: CoreMark/MHz of g14 -O2, g14 sf + -flto, g13 -O2 Zba / Zbb.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
mkdir -p work results
g++ -O2 -std=c++17 -Wall -o work/model model.cpp || exit 1
B="ubtb=8 rob=24 iq=10 lq=8 sq=8 ckpt=6 fb=16 fuse_2src=1 fuse_1w=1 alu_split=2 redirect=3 mdu_busy=2 st_data_issue=1 dec_depth=3 mul_wb=2 fusion=0"
W3="w=3 alu=3 issue_w=4 alu_split=0"
C3="$W3 iq=16 rob=32 lq=12 sq=12 ckpt=8 mul_wb=0 pred=M ubtb=16"
row() {   # row <label> <options...>
    local l=$1; shift
    cm() { ./work/model ooo work/$1.bin $B "${@:2}" | sed -n 's/.*CoreMark\/MHz \([0-9.]*\).*/\1/p'; }
    printf "| %-58s | %6s | %6s | %6s |\n" "$l" "$(cm g14-o2-zbsc "$@")" "$(cm g14-sflto-zbsc "$@")" "$(cm g13-o2-zb "$@")"
}
{
echo "| configuration | -O2 | max | g13 |"
echo "|---|---|---|---|"
row "base: the core of 2026-11-02"
echo "| **2-wide, one lever at a time** | | | |"
row "issue queue 16"                       iq=16
row "ROB 48"                               rob=48
row "LQ / SQ 12"                           lq=12 sq=12
row "8 checkpoints"                        ckpt=8
row "uBTB 16"                              ubtb=16
row "two full ALUs"                        alu_split=0
row "the multiply's write slot free"       mul_wb=0
row "stores split: address, then data"     st_data_issue=0
row "TAGE M"                               pred=M
row "a perfect predictor"                  pred=perfect
row "fusion 2 (one write, two sources)"    fusion=2
row "fusion 2 without those limits"        fusion=2 fuse_2src=0 fuse_1w=0
echo "| **2-wide, everything** | | | |"
row "the levers above without fusion"      alu_split=0 iq=16 lq=12 sq=12 mul_wb=0 pred=M ubtb=16 ckpt=8 st_data_issue=0
row "+ fusion 2"                           alu_split=0 iq=16 lq=12 sq=12 mul_wb=0 pred=M ubtb=16 ckpt=8 st_data_issue=0 fusion=2
echo "| **3-wide** (3 full ALUs + LSU, 4 issues) | | | |"
row "the 2-wide base otherwise (ROB 24, IQ 10)"  $W3
row "IQ 16"                                $W3 iq=16
row "IQ 16, ROB 32"                        $W3 iq=16 rob=32
row "IQ 16, ROB 48"                        $W3 iq=16 rob=48
row "IQ 16, ROB 32, LQ / SQ 12"            $W3 iq=16 rob=32 lq=12 sq=12
row "**the proposal**: + 8 checkpoints, free write slot, TAGE M, uBTB 16"  $C3
row "the proposal + stores split"          $C3 st_data_issue=0
row "the proposal + stores split + 2 LSU ports"           $C3 st_data_issue=0 lsu=2 issue_w=5
row "the proposal + stores split + 6 decoded, 32-byte fetch"  $C3 st_data_issue=0 dec_w=6 fetch_bytes=32
row "the proposal, a shorter pipeline (dec 2, redirect 2)"  $C3 dec_depth=2 redirect=2
row "the proposal, load-use 3"             $C3 lat_load=3
row "the proposal, 2 LSU ports (3 ALUs, 5 issues)"  $C3 lsu=2 issue_w=5
echo "| **4-wide** (IQ 24, ROB 48, LQ / SQ 16, 12 checkpoints; Doc/STRATEGY.md 4.1) | | | |"
C4="iq=24 rob=48 lq=16 sq=16 ckpt=12 mul_wb=0 pred=M ubtb=16 alu_split=0 w=4"
row "4 wide alone: 3 ALUs + LSU, 4 issues, the proposal's sizes"  w=4 alu=3 issue_w=4 alu_split=0 iq=16 rob=32 lq=12 sq=12 ckpt=8 mul_wb=0 pred=M ubtb=16
row "3 ALUs + LSU, 4 issues"                $C4 alu=3 issue_w=4
row "4 ALUs + LSU, 5 issues"                $C4 alu=4 issue_w=5
row "3 ALUs + 2 LSU, 5 issues"              $C4 alu=3 lsu=2 issue_w=5
row "4 ALUs + 2 LSU, 6 issues"              $C4 alu=4 lsu=2 issue_w=6
row "4 ALUs + LSU, 5 issues, 6 decoded, 32-byte fetch"    $C4 alu=4 issue_w=5 dec_w=6 fetch_bytes=32
row "4 ALUs + 2 LSU, 6 issues, 6 decoded, 32-byte fetch"  $C4 alu=4 lsu=2 issue_w=6 dec_w=6 fetch_bytes=32
echo "| **4 issues on a 2-wide core** | | | |"
row "3 ALUs + LSU, 4 issues, 2 dispatched a cycle"  w=2 alu=3 issue_w=4 alu_split=0 iq=16 rob=32 lq=12 sq=12 ckpt=8 mul_wb=0 pred=M ubtb=16
} | tee results/g200t.txt
