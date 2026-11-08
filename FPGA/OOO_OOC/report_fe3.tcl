#---------------------------------------------------------------------------
# report_fe3.tcl : the worst path of each class of OOC_FE3 (Doc/STRATEGY.md 4.5 loop 4).
# synth_ooo.tcl calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_fe3.tcl -tclargs output/OOC_FE3_T15
#
#   ovr   F2: the block, the boundaries, the choice, into F0: the override
#   ras   F2: into the stack
#   ubup  F2: into the training's registers
#   hist  F2: into what goes to the history and TAGE's metadata (in OOO_FETCH2 in the same
#         cycle: here into the harness's output registers)
#   cut   F2: the choice, into the buffer's table
#   tab   F2: the starts into the buffer's table
#   pred  F2: TAGE's results to the override
#   loop  F0's loop (OOO_UBTB2)
#   slot  D1: to the slots
#   dloop D1: the head's loop
#   move  D1: what is taken, into the blocks being read: the move from nxt to cur
# Full paths in timing_loop.rpt.
#---------------------------------------------------------------------------
proc fe3_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc fe3_classes {fh outdir} {
    set blk {s_d_reg* s_l_reg* s_s_reg* s_seq_reg* s_exp_reg* s_v_reg* *u_fd/c_v_reg* *u_fd/c_p_reg* s_bo_reg* s_bh_reg* s_bt_reg*}
    set prd {s_hv_reg* s_pp_reg* s_b_reg*}
    set pc  {*u_ub/pc_q_reg* *u_ub/pi_q_reg*}
    set cur {*u_fb/w_reg* *u_fb/g_cw* *u_fb/p_reg* *u_fb/rp_reg* *u_fb/rp1_reg* *u_fb/rb_reg* *u_fb/rem_reg* *u_fb/n1_reg* *u_fb/mem_reg*}
    set cnt {*u_fb/rem_reg* *u_fb/n1_reg* *u_fb/hj_reg* *u_fb/sn_reg* *u_fb/h_q_reg* *u_fb/rb_reg* *u_fb/bv_reg*}
    set out {o_valid_reg* o_inst_reg* o_rvc_reg* o_soff_reg* o_ftq_reg* o_stk_reg* o_rare_reg*}
    set cls [list \
        ovr   $blk $pc \
        ras   $blk {*u_fd/u_ras/*} \
        ubup  $blk {*u_fd/ub_*} \
        hist  [concat $blk $prd] {o_hn_reg* o_ht_reg* o_sv_reg* o_spar_reg*} \
        cut   [concat $blk $prd] {*u_fb/rem_reg* *u_fb/tk_reg*} \
        tab   $blk $cur \
        pred  $prd $pc \
        loop  {*u_ub/pi_q_reg* *u_ub/pc_q_reg*} $pc \
        slot  [concat $cnt {*u_fb/p_reg* *u_fb/w_reg* *u_fb/g_cw*}] $out \
        dloop $cnt $cnt \
        move  $cnt $cur]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [fe3_cells $from]
        set ct [fe3_cells $to]
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
    fe3_classes $fh $dir
    close $fh
}
