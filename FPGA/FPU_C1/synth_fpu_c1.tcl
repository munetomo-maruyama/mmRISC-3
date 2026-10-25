#---------------------------------------------------------------------------
# synth_fpu_c1.tcl : the breakdown of mmRISC-2's FPU_PIPE (option C1 of
# Plan/REDUCE.md, Doc/UARCH.md section 5), out of context in Vivado
#
#   cd FPGA/FPU_C1
#   vivado -mode batch -source synth_fpu_c1.tcl -tclargs [period [impl]]
#
#     period  clock period in ns                         20.0 (50 MHz)
#     impl    1 = also place and route (physical LUTs)   1
#     MMRISC2 (environment) the mmRISC-2 tree            ../../../mmRISC-2
#
# FPU_PIPE is one module (only the rounder FPU_ROUND is a module of its
# own), so a report by hierarchy cannot split it. Instead every register is
# put in a group by its name (the text before the first "_": p0 .. p8 are
# the stage registers, pp / prod the partial products, sum their sum, al
# the alignment, ds / dv / sq the divide and square root engine, f2i the
# conversion to an integer, a / b / c the unpacked operands, out the
# answer, u_round the rounder, and so on), and the LUTs in the fan-in cone
# of each group (back to the registers and ports before it) are counted:
#   cone       the LUTs that feed the group
#   exclusive  the LUTs that feed this group and no other: what removing the
#              group's function would free, at least
# A LUT can feed several groups, so the cones add up to more than the total;
# the exclusive ones add up to less (the rest is shared). The netlist after
# synthesis is used (LUT cells); the physical LUTs after place and route
# are in utilization.rpt as usual.
#
# Outputs in ./output/FPU_C1/ : breakdown.txt (the table), summary.txt,
# utilization_synth.rpt / utilization.rpt, timing_reg2reg.rpt.
#---------------------------------------------------------------------------

set part   xc7a100tcsg324-1
set m2     [expr {[info exists env(MMRISC2)] ? $env(MMRISC2) : "../../../mmRISC-2"}]
set fpu    $m2/RTL/CPU/CPU_FPU

set period [expr {[llength $argv] > 0 ? [lindex $argv 0] : 20.0}]
set impl   [expr {[llength $argv] > 1 ? [lindex $argv 1] : 1}]

foreach f [list $fpu/FPU_ROUND/FPU_ROUND.sv $fpu/FPU_PIPE/FPU_PIPE.sv] {
    if {![file exists $f]} {
        puts "ERROR: $f not found; set MMRISC2 to the mmRISC-2 tree"
        exit 1
    }
}

set outdir ./output/FPU_C1
file mkdir $outdir
puts "INFO: FPU_PIPE breakdown, clock period $period ns, place and route: $impl"

set_part $part
read_verilog -sv [list $fpu/FPU_ROUND/FPU_ROUND.sv $fpu/FPU_PIPE/FPU_PIPE.sv]
# keep the hierarchy of the rounder for its own row
synth_design -top FPU_PIPE -part $part -mode out_of_context -flatten_hierarchy rebuilt

create_clock -name clk -period $period [get_ports clk]
set io_dly [expr {0.3 * $period}]
set_input_delay  -clock clk $io_dly [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock clk $io_dly [get_ports -filter {DIRECTION == OUT}]

write_checkpoint -force $outdir/post_synth.dcp
report_utilization -hierarchical -file $outdir/utilization_synth.rpt

# ---- the breakdown
proc group_of {name} {
    if {[string match "u_round/*" $name]} { return "u_round" }
    set leaf [lindex [split $name /] end]
    if {[regexp {^([A-Za-z0-9]+)} $leaf -> g]} { return $g }
    return "other"
}

set regs [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]
set groups [dict create]
foreach r $regs { dict lappend groups [group_of [get_property NAME $r]] $r }

set all_luts [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]
set n_all [llength $all_luts]
set feeds [dict create]          ;# LUT -> number of groups it feeds
set cone_of [dict create]        ;# group -> its LUTs
set rows {}
dict for {g cells} $groups {
    set pins [get_pins -quiet -of_objects $cells -filter {DIRECTION == IN && IS_CLOCK == 0}]
    set cone [all_fanin -quiet -flat -only_cells $pins]
    set luts  [filter -quiet $cone {PRIMITIVE_GROUP == LUT}]
    set cy    [llength [filter -quiet $cone {REF_NAME == CARRY4}]]
    set mux   [llength [filter -quiet $cone {REF_NAME =~ MUXF*}]]
    set dsp   [llength [filter -quiet $cone {REF_NAME =~ DSP48*}]]
    dict set cone_of $g $luts
    foreach l $luts { dict incr feeds $l }      ;# an object is its name as a string
    lappend rows [list $g [llength $cells] [llength $luts] $cy $mux $dsp]
}
# the outputs: LUTs that feed only output ports
set out_cone [filter -quiet [all_fanin -quiet -flat -only_cells [get_ports -filter {DIRECTION == OUT}]] \
                  {PRIMITIVE_GROUP == LUT}]
set n_out_only 0
foreach l $out_cone { if {![dict exists $feeds $l]} { incr n_out_only } }

set n_shared 0
set n_unused [expr {$n_all - [dict size $feeds] - $n_out_only}]
dict for {l n} $feeds { if {$n > 1} { incr n_shared } }

set fh [open $outdir/breakdown.txt w]
puts $fh "FPU_PIPE breakdown (post-synthesis LUT cells; $n_all in all)"
puts $fh [format "%-10s %6s %8s %10s %7s %6s %4s" group regs cone exclusive CARRY4 MUXF DSP]
foreach row [lsort -integer -decreasing -index 2 $rows] {
    lassign $row g nr nl cy mux dsp
    set ex 0
    foreach l [dict get $cone_of $g] { if {[dict get $feeds $l] == 1} { incr ex } }
    puts $fh [format "%-10s %6d %8d %10d %7d %6d %4d" $g $nr $nl $ex $cy $mux $dsp]
}
puts $fh [format "LUTs feeding more than one group: %d; feeding only the outputs: %d; neither: %d" \
              $n_shared $n_out_only $n_unused]
close $fh
puts "INFO: breakdown written to $outdir/breakdown.txt"

# ---- the usual summary
proc count {filter} { return [llength [get_cells -quiet -hier -filter $filter]] }
set fh [open $outdir/summary.txt w]
puts $fh "FPU_PIPE breakdown run  (period $period ns, I/O delay $io_dly ns each side)"
puts $fh [format "after synthesis: %d LUT cells, %d FF, %d DSP" $n_all \
              [count {PRIMITIVE_GROUP == FLOP_LATCH}] [count {REF_NAME =~ DSP48*}]]
if {$impl} {
    opt_design
    place_design
    phys_opt_design
    route_design
    report_utilization -hierarchical -file $outdir/utilization.rpt
    report_timing -max_paths 10 -nworst 1 -path_type full -from [all_registers] -to [all_registers] \
        -file $outdir/timing_reg2reg.rpt
    set r2r [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup \
                                     -from [all_registers] -to [all_registers]]]
    puts $fh [format "after place and route: register to register %.3f ns (physical LUTs in utilization.rpt)" $r2r]
}
close $fh
