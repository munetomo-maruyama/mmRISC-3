#---------------------------------------------------------------------------
# report_exu2.tcl : the worst path of each class of OOC_EXU2 (Doc/STRATEGY.md 4.5
# loop 2). synth_ooo.tcl calls it; on its own it reads a finished run:
#
#   vivado -mode batch -source report_exu2.tcl -tclargs output/OOC_EXU2_T15
#
#   loop   a result, through EX's mux and the ALU, to a result: the loop
#   sel    EX's selections to a result
#   ctl    the decoded operation to a result
#   oper   the operand registers to a result
#   flag   into a branch's flags
#   rf     a source's tag, through the register file and its LVT, to the operands
#   tags   the tags compared in RR, to the selections
#   write  a result through the ALU into the register file
#   lvt    a write's tag into the live value table
#   ag     a result through the adder to an address, which goes on to block RAM
#   load   a load's data into the results and the register file
# Full paths in timing_loop.rpt.
#---------------------------------------------------------------------------
proc ex2_cells {pats} {
    set f {}
    foreach pt $pats { lappend f "NAME =~ $pt" }
    return [get_cells -quiet -hierarchical -filter "(IS_SEQUENTIAL || REF_NAME =~ RAM*) && ([join $f { || }])"]
}
proc exu2_classes {fh outdir} {
    set res  {*u_exu/*r_ex_reg*}
    set opr  {*u_exu/*oa_reg* *u_exu/*ob_reg*}
    set sel  {*u_exu/*sa_reg* *u_exu/*sb_reg*}
    set ctl  {*u_exu/*c_*_reg* *u_exu/*s_go_reg* *u_exu/*lk_q_reg* *u_exu/*ex_dst_reg* *u_exu/*ex_v_reg* *u_exu/*ex_wr_reg*}
    set cls [list loop  $res $res \
                  sel   $sel $res \
                  ctl   $ctl $res \
                  oper  $opr $res \
                  flag  [concat $res $sel $opr] {*u_exu/*fl_*_reg*} \
                  rf    {s_s_reg*} $opr \
                  tags  [concat {s_s_reg* s_us_reg*} $ctl {lt_reg* lv_reg* xv*_reg* xt*_reg*}] $sel \
                  write [concat $res $sel $opr] {*u_prf/*lo_reg* *u_prf/*hi_reg*} \
                  lvt   [concat $ctl {lv_reg* lt_reg* xv*_reg* xt*_reg* fl_reg*}] {*u_prf/*lvt_reg*} \
                  ag    [concat $res $sel $opr] {o_ag_reg*} \
                  load  {ld_reg*} [concat $res {*u_prf/*lo_reg* *u_prf/*hi_reg*}]]
    file delete -force $outdir/timing_loop.rpt
    foreach {name from to} $cls {
        set cf [ex2_cells $from]
        set ct [ex2_cells $to]
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
    exu2_classes $fh $dir
    close $fh
}
