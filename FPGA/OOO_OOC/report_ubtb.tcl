#---------------------------------------------------------------------------
# report_ubtb.tcl : the worst path of each class of OOC_UBTB2 (Doc/STRATEGY.md 4.5
# loop 6). synth_ooo.tcl calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_ubtb.tcl -tclargs output/OOC_UBTB2_T9
#
#   tag    the fetch address's tag, compare, choice, target, to the fetch address
#   idx    the index, through the RAM, to the fetch address: the loop
#   in     a redirect, a stall, the stack's top, to the fetch address
#   out    the prediction, to what fetch takes it into
#   upd    the update: compare, write enable, into the RAM
# Full paths in timing_loop.rpt. (No list of the cells: a list of more than 500
# is an error in Vivado, so a class is one filter.)
#---------------------------------------------------------------------------
proc ub_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc ubtb_classes {fh outdir} {
    set pc  {*u_ub/pc_q_reg* *u_ub/pi_q_reg*}
    set out {o_pc_reg* o_taken_reg* o_off_reg*}
    set cls [list tag  {*u_ub/pc_q_reg*}                          $pc \
                  idx  {*u_ub/pi_q_reg*}                          $pc \
                  in   {s_redirect_reg* s_stall_reg* s_rp_reg* s_ras_reg*} $pc \
                  out  $pc                                        $out \
                  upd  {s_uv_reg* s_up_reg* s_ut_reg* s_ug_reg* s_uc_reg* s_ur_reg*} {*u_ub/*p_* *u_ub/*q_*}]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [ub_cells $from]
        set ct [ub_cells $to]
        if {[llength $cf] == 0 || [llength $ct] == 0} { puts $fh "  $name: no cells"; continue }
        set p [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -from $cf -to $ct]
        if {[llength $p] == 0} { puts $fh "  $name: no path"; continue }
        puts $fh [format "  %-5s worst %7.3f ns (%2d logic levels), from %s to %s" $name \
                      [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
                      [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
        report_timing -max_paths 3 -nworst 1 -path_type full -from $cf -to $ct \
            -name $name -append -file $outdir/timing_loop.rpt
    }
}
if {![info exists top]} {
    set dir [lindex $argv 0]
    open_checkpoint $dir/post_route.dcp
    set fh [open $dir/summary_loop.txt w]
    ubtb_classes $fh $dir
    close $fh
}
