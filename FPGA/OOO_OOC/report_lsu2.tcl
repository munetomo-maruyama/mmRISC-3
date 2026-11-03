#---------------------------------------------------------------------------
# report_lsu2.tcl : the worst path of each class of OOC_LSU2 (Doc/STRATEGY.md 4.5
# loop 3). synth_ooo.tcl calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_lsu2.tcl -tclargs output/OOC_LSU2_T9
#
#   e_ram  E: the operand, EX's mux, the adder, into the arrays' address
#   e_m1   E: the same into M1's registers (the older stores, the mask)
#   dat    M1: the arrays' data, aligned in each way
#   tag    M1: the arrays' tags into a register
#   tlb    M1: the DTLB
#   cam    M1: the search of the SQ
#   hit    M2: the tags compared, the way chosen, the result: the deciding one
#   way    M2: a way's word to the result
#   fwd    M2: the SQ's data read, aligned, to the result
#   ok     M2: what came of it
#   m3     M3: into the queues' state
#   drain  the stores that drain
#   try    what is tried again
# Full paths in timing_loop.rpt.
#---------------------------------------------------------------------------
proc l2_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc l2_ram {} { return [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}] }
proc lsu2_classes {fh outdir} {
    set res {r_ex_reg* r_sn_reg* r_wr_reg*}
    set e   {sa_reg* oa_reg* alu_q_reg* r_ex_reg* *u_lsu/e_imm_reg*}
    set cls [list \
        e_ram $e RAM \
        e_m1  $e {*u_lsu/m1_*} \
        dat   RAM {*u_lsu/m2_w_reg*} \
        tag   RAM {*u_lsu/m2_t_reg*} \
        tlb   {*u_lsu/m1_a_reg*} {*u_lsu/m2_pt_reg* *u_lsu/m2_thit_reg* *u_lsu/m2_perm_reg*} \
        cam   {*u_lsu/m1_wa_reg* *u_lsu/m1_lmask_reg* *u_lsu/m1_older_reg* *u_lsu/m1_below_reg* *u_lsu/swa_reg* *u_lsu/smask_reg*} {*u_lsu/m2_fi_reg* *u_lsu/m2_any_reg*} \
        hit   {*u_lsu/m2_pt_reg* *u_lsu/m2_t_reg* *u_lsu/m2_any_reg*} $res \
        way   {*u_lsu/m2_w_reg*} $res \
        fwd   {*u_lsu/m2_fi_reg* *u_lsu/m2_off_reg* *u_lsu/m2_spos_reg* *u_lsu/m2_s*_reg*} $res \
        ok    {*u_lsu/m2_*} {*u_lsu/m3_*} \
        m3    {*u_lsu/m3_*} {*u_lsu/lwait_reg* *u_lsu/swait_reg* *u_lsu/lretry_reg* *u_lsu/sretry_reg*} \
        drain {*u_lsu/dp_reg* *u_lsu/d1_* *u_lsu/d2_*} {*u_lsu/dp_reg* *u_lsu/d1_* *u_lsu/d2_* *u_lsu/d3_*} \
        try   {*u_lsu/lwait_reg* *u_lsu/lretry_reg* *u_lsu/lv_reg* *u_lsu/swait_reg* *u_lsu/sretry_reg* *u_lsu/sv_reg* *u_lsu/r_q_reg*} {*u_lsu/r_q_reg* *u_lsu/r_d_reg*}]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [expr {$from eq "RAM" ? [l2_ram] : [l2_cells $from]}]
        set ct [expr {$to   eq "RAM" ? [l2_ram] : [l2_cells $to]}]
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
    lsu2_classes $fh $dir
    close $fh
}
