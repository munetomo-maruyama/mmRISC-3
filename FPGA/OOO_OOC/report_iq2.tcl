#---------------------------------------------------------------------------
# report_iq2.tcl : the worst path of each class of OOC_IQ2 (Doc/STRATEGY.md 4.5
# loop 1). synth_ooo.tcl calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_iq2.tcl -tclargs output/OOC_IQ2_T15
#
#   loop   a ready bit through the selects and the tags to a ready bit: the wakeup-select loop
#   guard  what holds a request back (valid, port, flags, sources' use), through the selects, to a ready bit
#   age    the age matrix through the selects to a ready bit
#   delay  a latency-2 tag (a register) to a ready bit: the part of the loop without the selects
#   leave  a ready bit to valid: the entry leaves as it issues
#   wait   a ready bit to the waits of loads and non-speculative µops
#   slot   the slots' registers into the entries, with a tag compare
#   free   valid to the free entries, into the entries
#   kill   kill, clr into the block
#   issue  a ready bit to what is issued
#   wk     a ready bit to the wakeup tags, which go on to renaming and the DS register
#   ready  valid to disp_ready, disp_entry, which go on to dispatch
# Full paths in timing_loop.rpt.
#---------------------------------------------------------------------------
proc iq2_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc iq2_classes {fh outdir} {
    set rq {*u_iq/g_ent*rq_reg*}
    set vq {*u_iq/g_ent*vq_reg*}
    set ent {*u_iq/g_ent*}
    set slot {i_v_reg* i_p_reg* i_u_reg* i_s_reg* i_r_reg* i_w_reg* i_d_reg* i_l_reg* i_b_reg* i_n_reg* i_m_reg* i_t_reg*}
    set cls [list \
        loop  [list $rq] [list $rq] \
        guard {*u_iq/g_ent*vq_reg* *u_iq/g_ent*pq_reg* *u_iq/g_ent*uq_reg* *u_iq/g_ent*nq_reg* *u_iq/g_ent*mq_reg* *u_iq/g_ent*wtq_reg* *u_iq/g_ent*wnq_reg* *u_iq/g_ent*wq_reg* *u_iq/g_ent*lq_reg* i_nk_reg* i_mk_reg* i_ph_reg* *u_iq/d_v0_reg*} [list $rq] \
        age   {*u_iq/g_ent*oq_reg*} [list $rq] \
        delay {*u_iq/d_v*_reg* *u_iq/d_t*_reg* i_xv_reg* i_xt_reg*} [list $rq] \
        leave [list $rq] [list $vq] \
        wait  [list $rq] {*u_iq/g_ent*wtq_reg* *u_iq/g_ent*wnq_reg*} \
        slot  $slot [list $ent] \
        free  [list $vq] [list $ent] \
        kill  {i_ki_reg* i_cl_reg* i_fl_reg*} {*u_iq/*} \
        issue [list $rq] {o_iss_reg*} \
        wk    [list $rq] {o_wk_reg*} \
        ready [list $vq] {o_disp_reg*}]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [iq2_cells $from]
        set ct [iq2_cells $to]
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
    iq2_classes $fh $dir
    close $fh
}
