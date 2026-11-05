#---------------------------------------------------------------------------
# report_ren3.tcl : the worst path of each class of OOC_REN3 (Doc/STRATEGY.md 4.5 loop 6). synth_ooo.tcl
# calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_ren3.tcl -tclargs output/OOC_REN3_T15
#
#   r     from R's fields: the dependences, the RAT read, the free list, into the DS register
#   adv   the queue's valid bits, disp_ready, go, to R's move: the RAT, the DS register's write
#   go    the same, into the queue's entries
#   rdy   the DS register's sources, the busy bits, into the queue: a ready bit
#   wake  a ready bit of the queue, the wakeup tag, into the busy bits
#   loop  the queue's own wakeup-select loop
#   rest  a restore: the id, the checkpoint, into the RAT
#   cmt   a commit: the free list, the tail, arat
# Full paths in timing_loop.rpt.
#---------------------------------------------------------------------------
proc r3_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc ren3_classes {fh outdir} {
    set in  {s_iv_reg* s_is_reg* s_iw_reg* s_id_reg* s_ik_reg*}
    set r2  {*u_ren/r2_*_reg*}
    set rq  {*u_iq/g_ent*rq_reg*}
    set vq  {*u_iq/g_ent*vq_reg*}
    set cls [list \
        r     [concat $in {*u_ren/rat_reg* *u_ren/rb_reg* *u_ren/head_reg*}] $r2 \
        adv   [concat $vq {s_room_reg* *u_ren/r2_valid_reg*}] {*u_ren/rat_reg* *u_ren/r2_src_reg* *u_ren/head_reg* *u_ren/rb_reg* d_p_reg* d_b_reg*} \
        go    [concat $vq {s_room_reg* *u_ren/r2_valid_reg*}] {*u_iq/g_ent*} \
        rdy   {*u_ren/r2_src_reg* *u_busy/busy_reg*} $rq \
        wake  [list $rq] {*u_busy/busy_reg*} \
        loop  [list $rq] [list $rq] \
        rest  {s_ri_reg* s_re_reg*} {*u_ren/rat_reg* *u_ren/u_w_reg* *u_ren/u_a_reg* *u_ren/u_t_reg*} \
        cmt   {s_cw_reg* s_ca_reg* s_cn_reg* s_co_reg* *u_ren/tail_reg*} {*u_ren/fl*_reg* *u_ren/arat_reg* *u_ren/tail_reg* *u_ren/chead_reg*}]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [r3_cells $from]
        set ct [r3_cells $to]
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
    ren3_classes $fh $dir
    close $fh
}
