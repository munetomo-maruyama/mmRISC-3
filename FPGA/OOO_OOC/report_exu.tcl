#---------------------------------------------------------------------------
# report_exu.tcl : the worst path of each class of OOC_EXU (Doc/STRATEGY.md 4.5
# loop 2). synth_ooo.tcl calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_exu.tcl -tclargs output/OOC_EXU_T10
#
#   loop   a result, through EX's mux and the ALU, to a result: the loop
#   sel    EX's selections to a result
#   ctl    the decoded operation to a result
#   oper   the operand registers to a result
#   flag   into a branch's flags
#   rare1  OOO_ALUR's stage 1
#   rare   OOO_ALUR's stage 2, to a result
#   rf     the register file's read, through RR2's mux, to the operands
#   lvt    the live value table, its compare, into its register
#   tags   the tags compared in RR2, to the operands and the selections
#   snoop  a result through RR2's mux to the operands
#   write  a result into the register file
# Full paths in timing_loop.rpt. (No list of the cells: a list of more than 500
# is an error in Vivado, so a class is one filter.)
#---------------------------------------------------------------------------
proc exu_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && ([join $f { || }])"]
}
proc exu_classes {fh outdir} {
    set res  {*u_exu/*r_ex_reg* *u_exu/*r_sn_reg* *u_exu/*r_wr_reg*}
    set opr  {*u_exu/*oa_reg* *u_exu/*ob_reg*}
    set sel  {*u_exu/*sa_reg* *u_exu/*sb_reg*}
    set cls [list loop  {*u_exu/*r_ex_reg*}                 $res \
                  sel   $sel                                $res \
                  ctl   {*u_exu/*c_*_reg*}                  $res \
                  oper  $opr                                $res \
                  flag  [concat {*u_exu/*r_ex_reg*} $sel $opr] {*u_exu/*fl_*_reg*} \
                  rare1 {*u_exu/*ra_q_reg* *u_exu/*rb_q_reg* *u_rare/d_*_reg*} {*u_rare/q_*_reg*} \
                  rare  {*u_rare/q_*_reg*}                  $res \
                  rf    {*u_prf/aq_reg* *u_prf/lq_reg*}     $opr \
                  lvt   {*u_prf/*lvt_reg* s1_reg* *u_prf/we_reg* *u_prf/wa_reg*} {*u_prf/lq_reg*} \
                  tags  {s2_reg* s_us_reg* *u_exu/*rt_reg* *u_exu/*rv_reg* *u_exu/*ex_dst_reg* *u_exu/*ex_v_reg* *u_exu/*ex_wr_reg*} [concat $opr $sel] \
                  snoop {*u_exu/*r_sn_reg*}                 $opr \
                  write {*u_exu/*r_wr_reg* *u_prf/we_reg* *u_prf/wa_reg*} {*u_prf/*mem*}]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [exu_cells $from]
        set ct [exu_cells $to]
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
    exu_classes $fh $dir
    close $fh
}
