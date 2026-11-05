#!/bin/bash
#---------------------------------------------------------------------------
# g50.sh : the core for the highest CoreMark/MHz at 50 MHz (Doc/STRATEGY.md, the
# author's decision of 2026-11-05: CoreMark/MHz first, 100 MHz given up), from
# the configuration chosen, one change at a time.
#
#   ./g50.sh           -> results/g50.txt
#
# Columns: CoreMark/MHz of g14 -O2, g14 sf + -flto, g13 -O2 Zba / Zbb, g13 rv64gc.
# Rows run at the same time, 2 by 2, each with a limit: a row left blank did not end.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
mkdir -p work results
[ -n "$NOBUILD" ] || g++ -O2 -std=c++17 -Wall -o work/model model.cpp || exit 1
B="ubtb=8 rob=24 iq=10 lq=8 sq=8 ckpt=6 fb=16 fuse_2src=1 fuse_1w=1 alu_split=2 redirect=3 mdu_busy=2 st_data_issue=1 dec_depth=3 mul_wb=2 fusion=0"
A="iq=24 rob=48 lq=16 sq=16 ckpt=12 mul_wb=0 pred=M ubtb=96 ub_sets=32 ub_rr=1 alu_split=0 w=4 ck_max=2"
F="$A alu=4 lsu=2 issue_w=6 dec_w=6 fetch_bytes=32"
n=0
rm -f work/g50.*
cm() { timeout 900 ./work/model ooo work/$1.bin $B "${@:2}" | sed -n 's/.*CoreMark\/MHz \([0-9.]*\).*/\1/p'; }
row() {
    local l=$1; shift; n=$((n+1))
    {
        cm g14-o2-zbsc "$@" > work/g50.$n.a & cm g14-sflto-zbsc "$@" > work/g50.$n.b &
        cm g13-o2-zb "$@" > work/g50.$n.c & cm g13-o2-gc "$@" > work/g50.$n.d &
        wait
        printf "| %-62s | %6s | %6s | %6s | %6s |\n" "$l" "$(cat work/g50.$n.a)" "$(cat work/g50.$n.b)" "$(cat work/g50.$n.c)" "$(cat work/g50.$n.d)" > work/g50.$n.t
    } &
    [ $((n % 2)) = 0 ] && wait
}
txt() { n=$((n+1)); wait; echo "| **$1** | | | | |" > work/g50.$n.t; }
{
row "today's core (2-wide, without RR1)"
txt "the configuration"
row "**4 renamed, 6 decoded, 32-byte fetch, 4 ALUs + 2 LSUs, 6 issues**" $F
txt "stores (the chosen: one µop, with its data)"
row "split in 2 µops, no replays: not to be had"  $F st_data_issue=0
row "split in 2 µops, a late data replays at commit, wait table 64" $F st_data_issue=0 ld_rp=1 sd_lag=1 ld_wt=64
txt "fewer ports, smaller front end"
row "4 ALUs + 1 LSU, 5 issues"                    $A alu=4 lsu=1 issue_w=5 dec_w=6 fetch_bytes=32
row "3 ALUs + 2 LSUs, 5 issues"                   $A alu=3 lsu=2 issue_w=5 dec_w=6 fetch_bytes=32
row "3 ALUs + 1 LSU, 4 issues"                    $A alu=3 lsu=1 issue_w=4 dec_w=6 fetch_bytes=32
row "4 decoded, 16-byte fetch"                    $A alu=4 lsu=2 issue_w=6
txt "the queue"
row "unified 16"                                  $F iq=16
row "unified 32"                                  $F iq=32
row "4 ALU queues of 8, a memory queue of 12, one select each" $F iqd=4 iq=8 iql=12
txt "the queue as it can be built (OOO_IQ2)"
row "a store only on LSU 0"                         $F st_lsu0=1
row "multiply, divide, system only on ALU 0"        $F p0_ops=1
row "... and the slow operations (slow2 classes 3)" $F p0_ops=1 p0_opx=3
row "... a multiply takes another port's write slot" $F p0_ops=1 p0_opx=3 mul_wb=2
row "4 banks of 6: a cycle's µops in different banks" $F iq_bank=4
row "... and a jalr only on ALU 0"                  $F p0_ops=2 p0_opx=3 mul_wb=2
row "**all of these: as it is built**"              $F st_lsu0=1 p0_ops=2 p0_opx=3 mul_wb=2 iq_bank=4
txt "the front end"
row "fetch a stage more, the override a stage later" $F fe_depth=4 override_at=3
row "the 100 MHz fetch: 5 stages, the override at F4" $F fe_depth=5 override_at=4
row "decode one block a cycle"                    $F dec_block=1
row "decode a stage more"                         $F dec_depth=4 redirect=4
row "the 100 MHz front end as built: all of the above" $F fe_depth=5 dec_depth=5 override_at=4 dec_block=1
txt "the back end"
row "RR1: select to EX 3 cycles"                  $F iss_to_ex=3
row "multiply 3"                                  $F lat_mul=3
row "load-use 3"                                  $F lat_load=3
row "ALU 2 cycles"                                $F lat_alu=2
txt "what more could be asked (after gate S1-B, if LUTs allow)"
row "ROB 64, LQ / SQ 24, 16 checkpoints"          $F rob=64 lq=24 sq=24 ckpt=16
row "fusion 2 (one write, two sources)"           $F fusion=2
row "5 renamed"                                   $F w=5
row "TAGE L"                                      $F pred=L
txt "other clocks, the same ports"
row "40 MHz: decode and redirect a stage shorter" $F dec_depth=2 redirect=2
row "33.3 MHz: load-use 1, block RAM on the falling edge" $F lat_load=1
row "66.7 MHz: load-use 2, fetch, decode, RR, multiply a stage more" $F fe_depth=4 override_at=3 dec_depth=4 iss_to_ex=3 redirect=5 lat_mul=3
row "66.7 MHz: the same with load-use 3"          $F fe_depth=4 override_at=3 dec_depth=4 iss_to_ex=3 redirect=5 lat_mul=3 lat_load=3
row "100 MHz: the 100 MHz pipeline, load-use 3, multiply 4" $F fe_depth=5 dec_depth=5 iss_to_ex=3 redirect=6 lat_load=3 lat_mul=4 override_at=4
wait
{
    echo "| configuration | -O2 | max | g13 | rv64gc |"
    echo "|---|---|---|---|---|"
    for i in $(seq 1 $n); do cat work/g50.$i.t; done
} | tee results/g50.txt
} 
