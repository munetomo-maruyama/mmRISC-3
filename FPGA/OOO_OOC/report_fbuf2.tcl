#---------------------------------------------------------------------------
# report_fbuf2.tcl : the worst path of each class of OOC_FBUF2 (Doc/STRATEGY.md 4.5
# loop 5). synth_ooo.tcl calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_fbuf2.tcl -tclargs output/OOC_FBUF2_T9
#
#   loop   what is left, and the slots' counters, to themselves: the head's loop
#   slot   from the counters through the table and the parcels to the slots
#   tab    F4: the starts to the table
#   rare   F4: a block's parcels to its rare bit
#   load   the end of a block to the block being read
#   ram    the blocks that wait, to the block being read
# Full paths in timing_loop.rpt.
#---------------------------------------------------------------------------
proc f2_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc fbuf2_classes {fh outdir} {
    set out {o_valid_reg* o_inst_reg* o_rvc_reg* o_off_reg* o_ftq_reg* o_taken_reg* o_rare_reg*}
    set cur {*u_fb/w_reg* *u_fb/g_cw* *u_fb/p_reg* *u_fb/rp_reg* *u_fb/rb_reg* *u_fb/tk_reg* *u_fb/ftq_reg* *u_fb/cftq_reg*}
    set cnt {*u_fb/rem_reg* *u_fb/hj_reg* *u_fb/rb_reg*}
    set cls [list \
        loop $cnt $cnt \
        slot [concat $cnt $cur] $out \
        tab  {s_st_reg* s_d_reg*} [concat $cur *u_fb/rem_reg* *u_fb/mem_reg*] \
        rare {s_d_reg* *u_fb/c_p_reg*} {*u_fb/rb_reg*} \
        load [concat $cnt s_or_reg*] $cur \
        ram  {*u_fb/hb_reg* *u_fb/cnt_reg*} $cur]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [f2_cells $from]
        set ct [f2_cells $to]
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
    fbuf2_classes $fh $dir
    close $fh
}
