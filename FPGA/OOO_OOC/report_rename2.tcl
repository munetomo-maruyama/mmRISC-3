#---------------------------------------------------------------------------
# report_rename2.tcl : the worst path of each class of OOC_RENAME2 (Doc/STRATEGY.md
# 4.5 loop 4). synth_ooo.tcl calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_rename2.tcl -tclargs output/OOC_RENAME2_T9
#
#   r1    from R1's fields: the dependences, into R2
#   read  the RAT read, into R2
#   tag   the free list: a bank's row, its place, the new register, into R2
#   rat   the RAT's write
#   go    disp_go (the port, with its delay) to the state
#   ck    a checkpoint's write
#   rest  a restore: the id, the checkpoint, into the RAT
#   cmt   a commit: the free list, the tail, arat
# Full paths in timing_loop.rpt.
#---------------------------------------------------------------------------
proc r2_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc rename2_classes {fh outdir} {
    set r2  {*u_ren/r2_*}
    set rat {*u_ren/rat_reg*}
    set cls [list \
        r1    {s_is_reg* s_id_reg* s_iw_reg* s_iv_reg* s_ik_reg*} $r2 \
        read  $rat $r2 \
        tag   {*u_ren/rb_reg* *u_ren/head_reg*} $r2 \
        rat   {s_id_reg* s_iw_reg* *u_ren/rb_reg* *u_ren/head_reg* *u_ren/u_*} $rat \
        ck    {*u_ren/r2_* *u_ren/rat_reg* *u_ren/pk_*} {*u_ren/ck0_reg* *u_ren/ck1_reg*} \
        rest  {s_ri_reg* s_re_reg*} $rat \
        cmt   {s_cw_reg* s_ca_reg* s_cn_reg* s_co_reg* *u_ren/tail_reg*} {*u_ren/fl?_reg* *u_ren/tail_reg* *u_ren/arat_reg* *u_ren/chead_reg*}]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [r2_cells $from]
        set ct [r2_cells $to]
        if {[llength $cf] == 0 || [llength $ct] == 0} { puts $fh "  $name: no cells"; continue }
        set p [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -from $cf -to $ct]
        if {[llength $p] == 0} { puts $fh "  $name: no path"; continue }
        puts $fh [format "  %-5s worst %7.3f ns (%2d logic levels), from %s to %s" $name \
                      [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
                      [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
        report_timing -max_paths 3 -nworst 1 -path_type full -from $cf -to $ct \
            -name $name -append -file $outdir/timing_loop.rpt
    }
    set p [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -from [get_ports disp_go*]]
    if {[llength $p]} {
        puts $fh [format "  %-5s worst %7.3f ns (%2d logic levels), from the port to %s" go \
                      [get_property SLACK $p] [get_property LOGIC_LEVELS $p] [get_property ENDPOINT_PIN $p]]
        report_timing -max_paths 3 -nworst 1 -path_type full -from [get_ports disp_go*] \
            -name go -append -file $outdir/timing_loop.rpt
    }
}
if {![info exists top]} {
    set dir [lindex $argv 0]
    open_checkpoint $dir/post_route.dcp
    set fh [open $dir/summary_loop.txt w]
    rename2_classes $fh $dir
    close $fh
}
