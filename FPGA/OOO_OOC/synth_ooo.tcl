#---------------------------------------------------------------------------
# synth_ooo.tcl : one block of mmRISC-3's out-of-order core alone in Vivado,
#                 out of context (Artix-7 xc7a100tcsg324-1, the part of the
#                 Arty A7-100T)
#
#   cd FPGA/OOO_OOC
#   vivado -mode batch -source synth_ooo.tcl -tclargs [top [period [impl [generics]]]]
#
#     top       OOC_ALU2 / OOC_FUSE / OOC_PRF / OOC_RENAME / OOO_IQ / OOO_UBTB / OOC_LSU / OOC_ROB
#               / OOC_FBUF / OOC_FTQ / OOC_FRONT / OOC_DEC / OOC_IQPL / OOC_LSUDC
#                                                          OOC_ALU2
#     period    clock period in ns                         20.0 (50 MHz)
#     impl      1 = also place and route                   1
#     generics  for OOC_PRF, e.g. "NW=3 NR=8"; OOC_ALU2 "FULL=0" is ALU1   (the defaults)
#
# Outputs in ./output/<top>[_<generics>]/ : utilization_synth.rpt /
# utilization.rpt, timing_summary.rpt, timing_reg2reg.rpt, summary.txt
# (the numbers in one place; for a harness of several blocks, the rows of
# their instances too). Plan/OOC.md says what each run is for.
#
# The OOC_* tops are register-to-register harnesses (rtl/OOC_WRAP.sv): the
# path that counts is between flip-flops, as in the core. OOO_IQ and
# OOO_UBTB have their loops inside; their ports get 30 % of the period as
# input and output delay, as mmRISC-2's FPU_OOC did.
#---------------------------------------------------------------------------

set part   xc7a100tcsg324-1
set rtl    ../../RTL/CPU/OOO
set core   ../../RTL/CPU/CORE
set cache  ../../RTL/CPU/CACHE

set top    [expr {[llength $argv] > 0 ? [lindex $argv 0] : "OOC_ALU2"}]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 20.0}]
set impl   [expr {[llength $argv] > 2 ? [lindex $argv 2] : 1}]
set gens   [expr {[llength $argv] > 3 ? [lindex $argv 3] : ""}]
# cmd.exe splits an unquoted NAME=value at the "=" (synth_ooo.bat OOC_ALU2
# 20.0 1 FULL=0 arrives as FULL 0): put such pairs back together
if {[llength $argv] > 4} {
    set rest [lrange $argv 3 end]
    set gens {}
    for {set k 0} {$k < [llength $rest]} {incr k} {
        set g [lindex $rest $k]
        if {[string first "=" $g] < 0 && $k + 1 < [llength $rest]} { incr k; set g "$g=[lindex $rest $k]" }
        lappend gens $g
    }
}

set tag $top
foreach g $gens { append tag "_[string map {= {}} $g]" }
set outdir ./output/$tag
file mkdir $outdir
puts "INFO: $top $gens, clock period $period ns, place and route: $impl"

set_part $part
read_verilog -sv [list \
    $rtl/OOO_ALU/OOO_ALU.sv $rtl/OOO_ALU2/OOO_ALU2.sv $rtl/OOO_FUSE/OOO_FUSE.sv \
    $rtl/OOO_PRF/OOO_PRF.sv $rtl/OOO_RENAME/OOO_RENAME.sv $rtl/OOO_IQ/OOO_IQ.sv \
    $rtl/OOO_UBTB/OOO_UBTB.sv $rtl/OOO_LSU/OOO_LSU.sv $rtl/OOO_ROB/OOO_ROB.sv \
    $rtl/OOO_FBUF/OOO_FBUF.sv $rtl/OOO_FTQ/OOO_FTQ.sv \
    $rtl/OOO_PREDEC/OOO_PREDEC.sv $rtl/OOO_TAGE/OOO_TAGE.sv $rtl/OOO_BTB/OOO_BTB.sv $rtl/OOO_RAS/OOO_RAS.sv \
    $rtl/OOO_FETCH/OOO_FETCH.sv $core/CORE_DECOMP/CORE_DECOMP.sv $core/CORE_DEC/CORE_DEC.sv \
    $rtl/OOO_DEC/OOO_DEC.sv $rtl/OOO_IQPL/OOO_IQPL.sv $rtl/OOO_DCAD/OOO_DCAD.sv \
    $cache/CACHE_TAG_ARRAY/CACHE_TAG_ARRAY.sv $cache/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv \
    $cache/DCACHE/DCACHE.sv ./rtl/OOC_WRAP.sv]

set gargs {}
foreach g $gens { lappend gargs -generic $g }
synth_design -top $top -part $part -mode out_of_context {*}$gargs

create_clock -name clk -period $period [get_ports clk]
set io_dly [expr {0.3 * $period}]
set ins [get_ports -quiet -filter {DIRECTION == IN && NAME != clk && NAME != rst_n}]
set outs [get_ports -quiet -filter {DIRECTION == OUT}]
if {[llength $ins]}  { set_input_delay  -clock clk $io_dly $ins }
if {[llength $outs]} { set_output_delay -clock clk $io_dly $outs }
if {[llength [get_ports -quiet rst_n]]} { set_false_path -from [get_ports rst_n] }

write_checkpoint -force $outdir/post_synth.dcp
report_utilization -hierarchical -file $outdir/utilization_synth.rpt

proc count {filter} { return [llength [get_cells -quiet -hier -filter $filter]] }
# the slice LUTs of the top (physical LUTs: logic + LUT RAM, two LUT cells
# packed in one LUT6_2 counted once), the "Total LUTs" of the hierarchical
# report, the number mmRISC-2's budget is in (Plan/ISSUES.md 2). The count of
# LUT cells alone leaves out LUT RAM (Plan/OOC.md 7.1)
proc slice_luts {} {
    foreach line [split [report_utilization -hierarchical -return_string] "\n"] {
        if {[regexp {^\|\s*\S+\s*\|\s*\(top\)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|} $line -> t l m]} {
            return [list $t $l $m]
        }
    }
    return {-1 -1 -1}
}
# the rows of the instances (u_*) of the hierarchical report: Total LUTs,
# logic LUTs, LUT RAM, flip-flops (columns 3 to 5 and 7)
proc inst_rows {} {
    set rows {}
    foreach line [split [report_utilization -hierarchical -return_string] "\n"] {
        set f [split $line "|"]
        if {[llength $f] < 9} continue
        set inst [string trim [lindex $f 1]]
        if {![string match "u_*" $inst]} continue
        lappend rows [format "  %-24s %-20s %6s LUTs (%s logic + %s LUT RAM), %s FF" \
                          [string range [lindex $f 1] 1 end] [string trim [lindex $f 2]] \
                          [string trim [lindex $f 3]] [string trim [lindex $f 4]] \
                          [string trim [lindex $f 5]] [string trim [lindex $f 7]]]
    }
    return $rows
}
set n_lut  [count {PRIMITIVE_GROUP == LUT}]
set n_ff   [count {PRIMITIVE_GROUP == FLOP_LATCH}]
set n_dsp  [count {REF_NAME =~ DSP48*}]
set n_lram [count {REF_NAME =~ RAM32* || REF_NAME =~ RAM64* || REF_NAME =~ RAM128* || REF_NAME =~ RAM256*}]
# block RAM in tiles (a RAMB36 is one, a RAMB18 half)
set n_bram [expr {[count {REF_NAME =~ RAMB36*}] + 0.5 * [count {REF_NAME =~ RAMB18*}]}]
lassign [slice_luts] s_tot s_log s_ram
set synth_msg [format "after synthesis: %d LUTs (%d logic + %d LUT RAM; %d LUT cells), %d FF, %d DSP, %d LUT RAM cells, %.1f BRAM tiles" \
                   $s_tot $s_log $s_ram $n_lut $n_ff $n_dsp $n_lram $n_bram]
puts "INFO: $synth_msg"

set fh [open $outdir/summary.txt w]
puts $fh "$top $gens  (period $period ns, I/O delay $io_dly ns each side on the ports)"
puts $fh $synth_msg

if {$impl} {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force $outdir/post_route.dcp
    report_utilization -hierarchical -file $outdir/utilization.rpt
    report_timing_summary -file $outdir/timing_summary.rpt
    report_timing -max_paths 10 -nworst 1 -path_type full -from [all_registers] -to [all_registers] \
        -file $outdir/timing_reg2reg.rpt
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set r2r [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup \
                                     -from [all_registers] -to [all_registers]]]
    set p   [get_timing_paths -max_paths 1 -nworst 1 -setup -from [all_registers] -to [all_registers]]
    set lv  [get_property LOGIC_LEVELS $p]
    set n_lut [count {PRIMITIVE_GROUP == LUT}]
    lassign [slice_luts] s_tot s_log s_ram
    set impl_msg [format "after place and route: %d LUTs (%d logic + %d LUT RAM; %d LUT cells), WNS %.3f ns, register to register %.3f ns (%d logic levels)" \
                      $s_tot $s_log $s_ram $n_lut $wns $r2r $lv]
    puts "INFO: $impl_msg"
    puts $fh $impl_msg
}
set rows [inst_rows]
if {[llength $rows] > 1} {
    if {$impl} { set when "after place and route" } else { set when "after synthesis" }
    puts $fh "instances ($when):"
    foreach r $rows { puts $fh $r }
}
close $fh
