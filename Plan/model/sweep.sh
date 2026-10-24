#!/bin/bash
#---------------------------------------------------------------------------
# sweep.sh : the 2-wide out-of-order model (ooo.h) around its baseline,
# one parameter at a time, on the three builds
#
#   ./sweep.sh            -> results/sweep.txt
#
# Columns: CoreMark/MHz of g14 -O2 (the -O2 goal), g14 sf + -flto (the most
# optimization) and g13 -O2 Zba / Zbb (mmRISC-2's condition); then the IPC
# and the mispredictions / overrides of g14 -O2.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
mkdir -p work results
g++ -O2 -std=c++17 -Wall -o work/model model.cpp || exit 1
for b in g14-o2-zbsc g14-sflto-zbsc g13-o2-zb; do
    [ -s work/$b.bin ] || python3 mktrace.py ../trace/work/$b.trace.gz work/$b.bin || exit 1
done

row() {   # row <label> <options...>
    local l=$1; shift
    local a=$(./work/model ooo work/g14-o2-zbsc.bin "$@")
    local b=$(./work/model ooo work/g14-sflto-zbsc.bin "$@")
    local g=$(./work/model ooo work/g13-o2-zb.bin "$@")
    cm() { echo "$1" | sed -n 's/.*CoreMark\/MHz \([0-9.]*\).*/\1/p'; }
    ipc=$(echo "$a" | sed -n 's/.*IPC \([0-9.]*\).*/\1/p')
    mp=$(echo "$a" | sed -n 's/.*(MPKI \([0-9.]*\)).*overrides \([0-9]*\).*/MPKI \1 ovr \2/p')
    printf "| %-44s | %6s | %6s | %6s | %6s | %s |\n" "$l" "$(cm "$a")" "$(cm "$b")" "$(cm "$g")" "$ipc" "$mp"
}
{
echo "| configuration (changes from the baseline) | -O2 | max | g13 | IPC | g14 -O2 |"
echo "|---|---|---|---|---|---|"
row "baseline (see MODEL.md 6.2)"
row "pred=perfect" pred=perfect
row "pred=gshare (mmRISC-2-like, 8K)" pred=gshare
row "pred=M (TAGE-M)" pred=M
row "pred=L (TAGE-L)" pred=L
row "ubtb=0 (every taken via override)" ubtb=0
row "ubtb=16" ubtb=16
row "ubtb=32" ubtb=32
row "ubtb=128" ubtb=128
row "override_at=3" override_at=3
row "fusion=1 (address + load, pairs, lui/auipc)" fusion=1
row "fusion=2 (+ ALU + branch)" fusion=2
row "fusion=3 (+ ALU + ALU chained)" fusion=3
row "fusion=3 chain=2 (ALU + ALU not chained)" fusion=3 chain=2
row "fusion=3 dec_w=2" fusion=3 dec_w=2
row "iq=12" iq=12
row "iq=16" iq=16
row "iq=32" iq=32
row "iq=48" iq=48
row "rob=32" rob=32
row "rob=48" rob=48
row "rob=96" rob=96
row "lq=8 sq=8" lq=8 sq=8
row "lq=12 sq=12" lq=12 sq=12
row "lq=24 sq=24" lq=24 sq=24
row "fetch_bytes=8" fetch_bytes=8
row "fetch_bytes=32" fetch_bytes=32
row "fb=8" fb=8
row "fb=32" fb=32
row "fe_depth=2" fe_depth=2
row "fe_depth=4" fe_depth=4
row "dec_depth=1" dec_depth=1
row "dec_depth=3" dec_depth=3
row "iss_to_ex=1" iss_to_ex=1
row "iss_to_ex=3" iss_to_ex=3
row "redirect=2" redirect=2
row "lat_load=3" lat_load=3
row "lat_mul=3" lat_mul=3
row "alu=1" alu=1
row "alu=3" alu=3
row "lsu=2" lsu=2
row "mem_cons=0 (perfect disambiguation)" mem_cons=0
row "fwd=0 (no store-to-load forwarding)" fwd=0
row "ckpt=4" ckpt=4
row "ckpt=8" ckpt=8
row "issue_w=2" issue_w=2
row "issue_w=4 mul_shared=0 (4 ports at once)" issue_w=4 mul_shared=0
row "small: rob=32 iq=16 lq=12 sq=12 ckpt=8 ubtb=32" rob=32 iq=16 lq=12 sq=12 ckpt=8 ubtb=32
row "small + fusion=2" rob=32 iq=16 lq=12 sq=12 ckpt=8 ubtb=32 fusion=2
row "small + fusion=3" rob=32 iq=16 lq=12 sq=12 ckpt=8 ubtb=32 fusion=3
row "slow: fe 4, dec 3, iss_to_ex 3, override 3" fe_depth=4 dec_depth=3 iss_to_ex=3 override_at=3
row "slow + lat_load=3" fe_depth=4 dec_depth=3 iss_to_ex=3 override_at=3 lat_load=3
row "small + slow + lat_load=3 (pessimistic)" rob=32 iq=16 lq=12 sq=12 ckpt=8 ubtb=32 fe_depth=4 dec_depth=3 iss_to_ex=3 override_at=3 lat_load=3
row "pessimistic + fusion=2" rob=32 iq=16 lq=12 sq=12 ckpt=8 ubtb=32 fe_depth=4 dec_depth=3 iss_to_ex=3 override_at=3 lat_load=3 fusion=2
row "pessimistic + fusion=3" rob=32 iq=16 lq=12 sq=12 ckpt=8 ubtb=32 fe_depth=4 dec_depth=3 iss_to_ex=3 override_at=3 lat_load=3 fusion=3
row "NaxRiscv-like: gshare, lat_load=3, iq=32" pred=gshare lat_load=3 iq=32
row "w=3 dec_w=6 alu=3 (3-wide, reference)" w=3 dec_w=6 alu=3 issue_w=4
row "w=1 dec_w=2 (1-wide out-of-order, reference)" w=1 dec_w=2
} | tee results/sweep.txt
