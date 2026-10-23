#!/bin/bash
#---------------------------------------------------------------------------
# icount.sh : instructions of one CoreMark iteration, by compiler, options
# and ISA extensions, counted on Spike
#
#   ./icount.sh                   all compilers x options x -march
#   ./icount.sh g13:o2:zb ...     only the builds named compiler:options:march
#
# Each build is CoreMark (PERFORMANCE_RUN, ITERATIONS=$ITER) on the bare
# machine (port/: the SIM_SYS port of mmRISC-2 adapted to Spike). The timed
# part prints minstret, and the instructions per iteration are that count
# divided by ITER. The answer of CoreMark (crcfinal, 0xfcaf at 10
# iterations) must be the same for every build.
#
# Output: work/<build>.{elf,log} and results/icount.csv
#---------------------------------------------------------------------------
cd "$(dirname "$0")"

CM=${COREMARK:-$HOME/RISCV/Rocket/vivado-risc-v/bare-metal/coremark/coremark}
SPIKE=${SPIKE:-$HOME/RISCV/toolchain/spike-install/bin/spike}
SPIKE_ISA=rv64gc_zba_zbb_zbs_zicond
ITER=${ITER:-10}
LINKER=/opt/riscv/bin/riscv64-unknown-elf-gcc   # links the clang builds too
ROOTFS=${ROOTFS:-$HOME/RISCV/toolchain/debian13-rootfs}

# compilers
declare -A CC
CC[g12]=/opt/riscv/bin/riscv64-unknown-elf-gcc-12.2.0
CC[g13]=/opt/riscv/bin/riscv64-unknown-elf-gcc          # 13.2, the one of mmRISC-2
CC[g13u]=/usr/bin/riscv64-linux-gnu-gcc                 # 13.3 of Ubuntu 24.04
CC[g14]=debian                                          # 14.2 of Debian 13, run by qemu in its root fs
CC[c18]=clang-18
# the Linux compilers of the distributions make PIE code with a stack
# protector by default; the bare machine wants neither
declare -A CCX
CCX[g13u]="-fno-pie -no-pie -fno-stack-protector"
CCX[g14]="-fno-pie -no-pie -fno-stack-protector"

# options (gcc); sf = the "most optimization" of mmRISC-2 (BENCH.md 17)
SF="-O3 -funroll-all-loops -finline-functions --param max-inline-insns-auto=20 -falign-functions=4 -falign-jumps=4 -falign-loops=4"
declare -A OPT
OPT[o2]="-O2"
OPT[o3]="-O3"
OPT[sf]="$SF"
OPT[sflto]="$SF -flto"
OPT[sfx]="$SF -finline-limit=600 -fno-code-hoisting -fgcse-sm -fgcse-las -fipa-pta"
# options (clang): no --param, so sf is the nearest
declare -A COPT
COPT[o2]="-O2"
COPT[o3]="-O3"
COPT[sf]="-O3 -funroll-loops -finline-functions"
COPT[sflto]="-O3 -funroll-loops -finline-functions -flto"
COPT[sfx]="-O3 -funroll-loops -finline-functions -mllvm -inline-threshold=600"

# ISA extensions
declare -A ARCH
ARCH[gc]=rv64imafdc_zicsr_zifencei
ARCH[zb]=rv64imafdc_zicsr_zifencei_zba_zbb
ARCH[zbs]=rv64imafdc_zicsr_zifencei_zba_zbb_zbs
ARCH[zbsc]=rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicond

ALL=""
for c in g12 g13 g13u g14 c18; do
    for o in o2 o3 sf sflto sfx; do
        for a in gc zb zbs zbsc; do ALL="$ALL $c:$o:$a"; done
    done
done
BUILDS=${*:-$ALL}

W=work
mkdir -p $W results
[ -x "$SPIKE" ] || { echo "no Spike at $SPIKE"; exit 1; }

# CoreMark's printf for the bare metal, the output hook sent to tohost (as
# mmRISC-2 SIM_SYS/bench/Makefile does)
EE=$W/ee_printf.c
sed -e 's/^#error "You must implement the method uart_send_char.*$/    extern void tohost_putc(char); tohost_putc(c);/' \
    $CM/barebones/ee_printf.c > $EE
grep -q 'tohost_putc(c)' $EE && ! grep -q '^#error' $EE || { echo "ee_printf.c not patched"; exit 1; }

SRCS="port/crt.S port/minilib.c $EE port/core_portme.c $CM/core_list_join.c $CM/core_main.c
      $CM/core_matrix.c $CM/core_state.c $CM/core_util.c"
COMMON="-mabi=lp64d -mcmodel=medany -Iport -I$CM -DITERATIONS=$ITER -DPERFORMANCE_RUN=1"
LDFLAGS="-nostdlib -T port/link.ld -Wl,--no-warn-rwx-segments"

build() {   # build <c> <o> <a> <elf>
    local c=$1 o=$2 a=$3 elf=$4 cc=${CC[$1]} march="-march=${ARCH[$3]}"
    case $c in
    c18)
        local objs="" s
        local d=$W/obj_$c-$o-$a; mkdir -p $d
        for s in $SRCS; do
            $cc --target=riscv64-unknown-elf $march $COMMON ${COPT[$o]} \
                -DFLAGS_STR="\"$march ${COPT[$o]}\"" -c $s -o $d/$(basename $s).o || return 1
            objs="$objs $d/$(basename $s).o"
        done
        $LINKER $march -mabi=lp64d $LDFLAGS $objs -lgcc -o $elf ;;
    g14)
        # gcc 14 of Debian 13 (the board's compiler), in its root fs under
        # qemu-user; everything it reads or writes is copied in and out
        [ -x $ROOTFS/usr/bin/gcc-14 ] || { echo "no Debian root fs at $ROOTFS"; return 1; }
        local d=$ROOTFS/tmp/icount; mkdir -p $d/cm $d/port
        cp $CM/*.c $CM/*.h $d/cm/; cp port/* $d/port/; cp $EE $d/
        unshare -r chroot $ROOTFS /bin/sh -c "cd /tmp/icount && gcc-14 $march $COMMON ${OPT[$o]} ${CCX[$c]} \
            -Iport -Icm -DFLAGS_STR='\"$march ${OPT[$o]}\"' $LDFLAGS \
            -fno-tree-loop-distribute-patterns \
            port/crt.S port/minilib.c ee_printf.c port/core_portme.c cm/core_list_join.c cm/core_main.c \
            cm/core_matrix.c cm/core_state.c cm/core_util.c -lgcc -o out.elf" || return 1
        cp $d/out.elf $elf ;;
    *)
        # -fno-tree-loop-distribute-patterns: otherwise the loop of memset in
        # minilib.c becomes a call to itself
        $cc $march $COMMON ${OPT[$o]} ${CCX[$c]} -DFLAGS_STR="\"$march ${OPT[$o]}\"" $LDFLAGS \
            -fno-tree-loop-distribute-patterns $SRCS -lgcc -o $elf ;;
    esac
}

CSV=results/icount.csv
[ -f $CSV ] || echo "compiler,options,march,iterations,timed_instructions,per_iteration,crcfinal,text_bytes" > $CSV
for b in $BUILDS; do
    IFS=: read c o a <<< "$b"
    n=$c-$o-$a
    if ! build $c $o $a $W/$n.elf > $W/$n.build.log 2>&1; then
        echo "$n: build failed (see $W/$n.build.log)"; continue
    fi
    timeout 300 $SPIKE --isa=$SPIKE_ISA $W/$n.elf > $W/$n.log 2>&1
    ti=$(sed -n 's/^timed instructions: \([0-9]*\).*/\1/p' $W/$n.log)
    crc=$(sed -n 's/^\[0\]crcfinal *: *\(0x[0-9a-f]*\).*/\1/p' $W/$n.log)
    txt=$(/opt/riscv/bin/riscv64-unknown-elf-size -A $W/$n.elf | awk '$1==".text"{print $2}')
    [ -n "$ti" ] || { echo "$n: no count (see $W/$n.log)"; continue; }
    per=$((ti / ITER))
    grep -v "^$c,$o,$a,$ITER," $CSV > $CSV.tmp; mv $CSV.tmp $CSV
    echo "$c,$o,$a,$ITER,$ti,$per,$crc,$txt" >> $CSV
    printf "%-16s %10d instructions / iteration  crcfinal %s  .text %s\n" $n $per $crc $txt
done
