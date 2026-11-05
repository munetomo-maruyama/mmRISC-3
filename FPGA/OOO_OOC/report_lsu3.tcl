#---------------------------------------------------------------------------
# report_lsu3.tcl : the worst path of each class of OOC_LSU3 (Doc/STRATEGY.md 4.5
# loop 3). synth_ooo.tcl calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_lsu3.tcl -tclargs output/OOC_LSU3_T15
#
#   e_ram  E: the operand, EX's mux, the adder, into the arrays' address
#   e_m    E: the same into M's registers (the older stores, the mask)
#   ram    M: the arrays' outputs, tags or data, to the result
#   tlb    M: the address, the DTLB, the tags compared, the way, to the result
#   cam    M: the search of the SQ, the way, the forward, to the result: load-use's own
#   sel    M: the offset and size, the alignment, to the result
#   ok     M: into what came of it
#   stm    M: a store into the SQ
#   w      W: into the queues' state
#   drain  the stores that drain
#   try    what is tried again
# Full paths in timing_loop.rpt.
#---------------------------------------------------------------------------
proc l3_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc l3_ram {} { return [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}] }
proc lsu3_classes {fh outdir} {
    set res {r_ex_reg*}
    set e   {sa_reg* oa_reg* oi_reg* alu_q_reg* r_ex_reg*}
    set cam {*u_lsu/g_port*m_wa_reg* *u_lsu/g_port*m_lmask_reg* *u_lsu/g_port*m_older_reg* *u_lsu/g_port*m_below_reg* *u_lsu/swa_reg* *u_lsu/smask_reg* *u_lsu/g_port*g_st.swa_reg* *u_lsu/g_port*g_st.smask_reg*}
    set cls [list \
        e_ram $e RAM \
        e_m   $e {*u_lsu/g_port*m_*_reg*} \
        ram   RAM $res \
        tlb   {*u_lsu/g_port*m_a_reg*} $res \
        cam   $cam $res \
        sel   {*u_lsu/g_port*m_off_reg* *u_lsu/g_port*m_spos_reg* *u_lsu/g_port*m_s0_reg* *u_lsu/g_port*m_s01_reg* *u_lsu/g_port*m_s3_reg* *u_lsu/g_port*m_sen_reg*} $res \
        ok    {*u_lsu/g_port*m_*_reg*} {*u_lsu/g_port*w_*_reg*} \
        stm   {*u_lsu/g_port*m_*_reg* *u_lsu/g_port*m_sd_reg*} {*u_lsu/*swa_reg* *u_lsu/*smask_reg* *u_lsu/*sp_reg*} \
        w     {*u_lsu/g_port*w_*_reg*} {*u_lsu/lwait_reg* *u_lsu/*swait_reg* *u_lsu/lretry_reg* *u_lsu/sretry_reg*} \
        drain {*u_lsu/dp_reg* *u_lsu/d1_* *u_lsu/d2_*} {*u_lsu/dp_reg* *u_lsu/d1_* *u_lsu/d2_* *u_lsu/d3_*} \
        try   {*u_lsu/lwait_reg* *u_lsu/lretry_reg* *u_lsu/lv_reg* *u_lsu/*swait_reg* *u_lsu/sretry_reg* *u_lsu/sv_reg* *u_lsu/r_q_reg*} {*u_lsu/r_q_reg* *u_lsu/r_d_reg*}]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [expr {$from eq "RAM" ? [l3_ram] : [l3_cells $from]}]
        set ct [expr {$to   eq "RAM" ? [l3_ram] : [l3_cells $to]}]
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
    lsu3_classes $fh $dir
    close $fh
}
