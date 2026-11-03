#---------------------------------------------------------------------------
# report_sched.tcl : the worst path of each class of OOC_SCHED (Doc/STRATEGY.md
# 4.5 loop 1), also those that are not among the ten worst. synth_ooo.tcl calls
# it; on its own it reads a finished run, without running it again:
#
#   vivado -mode batch -source report_sched.tcl -tclargs output/OOC_SCHED_T10
#
#   loop   a request through its grant, to a request: the wakeup-select loop
#   guard  what holds a request back (flags, write slots, ages, ns_ok ...), through
#          the grant, to a request
#   wake   a request into the wait cells
#   free   a request into the next free entry
#   s1     the slots' registers into S1's registers, and the entries' fields
#   ff     the first free entries and the queue order into the same
#   s2     S2's registers into the rows and the requests
#   kill   kill, clr into the block
#   issue  the grants in a register, out of the block
# Full paths in timing_loop.rpt. (No list of the cells: a list of more than 500
# is an error in Vivado, so a class is one filter.)
#---------------------------------------------------------------------------
proc sched_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc sched_classes {fh outdir} {
    set inr {dv_reg* dk_reg* du_reg* ds_reg* dw_reg* dd_reg* dl_reg* dx_reg* db_reg* dn_reg* dm_reg* dt_reg*}
    set cls [list loop  {*u_sched/*rv_reg*}             {*u_sched/*rv_reg*} \
                  guard {*u_sched/*nsf_reg* *u_sched/*mdf_reg* *u_sched/*l1q_reg* *u_sched/*l2f_reg* *u_sched/*l3f_reg* *u_sched/*l4f_reg* *u_sched/*wrq_reg* *u_sched/*aq_reg* *u_sched/*rs_reg* *u_sched/*rr_ns_reg* *u_sched/*rr_md_reg* nk_reg* mk_reg* qh_reg*} {*u_sched/*rv_reg*} \
                  wake  {*u_sched/*rv_reg*}             {*u_sched/*wq_reg*} \
                  free  {*u_sched/*rv_reg*}             {*u_disp/ff_reg* *u_disp/bf_reg*} \
                  s1    $inr                            {u_sched/*} \
                  ff    {*u_disp/ff_reg* *u_disp/bf_reg* *u_disp/rk_reg*} {u_sched/*} \
                  s2    {*u_disp/d2_reg* *u_disp/s2_reg* *u_disp/w2_reg* *u_disp/col_q_reg*} {u_sched/*} \
                  kill  {ki_reg* cl_reg*}               {u_sched/*} \
                  issue {*u_sched/*gq_reg*}             {out_reg*}]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [sched_cells $from]
        set ct [sched_cells $to]
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
    sched_classes $fh $dir
    close $fh
}
