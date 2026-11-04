#---------------------------------------------------------------------------
# report_fe2.tcl : the worst path of each class of OOC_FE2 (Plan/OOC.md 28.21). synth_ooo.tcl
# calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_fe2.tcl -tclargs output/OOC_FE2_T9
#
#   f3    F3: the block to F4's registers
#   ovr   F4: the choice, into F0: the override
#   ras   F4: the choice, into the stack
#   ubup  F4: the choice, into the training's registers
#   cut   F4: the choice, into the buffer's table
#   tab   F4: the starts into the buffer's table
#   loop  F0's loop (OOO_UBTB2)
#   slot  D1: to the slots
#   dloop D1: the head's loop
# Full paths in timing_loop.rpt.
#---------------------------------------------------------------------------
proc fe2_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc fe2_classes {fh outdir} {
    set f4 {*u_fd/v4_reg* *u_fd/uj4_reg* *u_fd/br4_reg* *u_fd/cnt4_reg* *u_fd/hv4_reg* *u_fd/pp4_reg* *u_fd/base4_reg* *u_fd/s4_reg* *u_fd/jal4_reg* *u_fd/ret4_reg* *u_fd/tgt4_reg* *u_fd/seq4_reg*}
    set pc {*u_ub/pc_q_reg* *u_ub/pi_q_reg*}
    set cur {*u_fb/w_reg* *u_fb/g_cw* *u_fb/p_reg* *u_fb/rp_reg* *u_fb/rb_reg* *u_fb/rem_reg* *u_fb/mem_reg*}
    set cnt {*u_fb/rem_reg* *u_fb/hj_reg* *u_fb/rb_reg*}
    set out {o_valid_reg* o_inst_reg* o_rvc_reg* o_soff_reg* o_ftq_reg* o_stk_reg* o_rare_reg*}
    set cls [list \
        f3    {s_d_reg* s_l_reg* s_s_reg* s_seq_reg* s_exp_reg* *u_fd/c_v_reg* *u_fd/c_p_reg* s_bo_reg* s_bh_reg*} {*u_fd/*4_reg* *u_fd/f4_data_reg*} \
        ovr   $f4 $pc \
        ras   $f4 {*u_fd/u_ras/*} \
        ubup  $f4 {*u_fd/ub_*} \
        cut   $f4 $cur \
        tab   {*u_fd/st4_reg*} $cur \
        loop  {*u_ub/pi_q_reg* *u_ub/pc_q_reg*} $pc \
        slot  [concat $cnt {*u_fb/p_reg* *u_fb/w_reg* *u_fb/g_cw*}] $out \
        dloop $cnt $cnt]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [fe2_cells $from]
        set ct [fe2_cells $to]
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
    fe2_classes $fh $dir
    close $fh
}
