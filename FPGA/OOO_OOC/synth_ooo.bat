@echo off
REM synth_ooo.bat : the blocks of mmRISC-3's out-of-order core in Vivado,
REM out of context, one after another (see synth_ooo.tcl and Plan/OOC.md)
REM
REM   synth_ooo.bat            all runs below, 50 MHz, with place and route
REM   synth_ooo.bat prf        the five register files only
REM   synth_ooo.bat OOC_ALU2   one top only (the arguments of synth_ooo.tcl)
REM   synth_ooo.bat MM2_CPU_CORE   the calibration: mmRISC-2's CPU_CORE (not in the loop below: it is long)
REM   synth_ooo.bat OOO_CPU    B7: mmRISC-3's whole core with its D$ (not in the loop either)
REM   synth_ooo.bat t100       the loops that decide 100 MHz, at a 10 ns target, in output\<top>_T10 (Doc/STRATEGY.md 4.5)
REM   synth_ooo.bat sched      the distributed schedulers at a 10 ns target, in output\OOC_SCHED_T10
REM   synth_ooo.bat sched85    the same at 8.5 ns, for the margin: output\OOC_SCHED_T8.5
REM   synth_ooo.bat sched86    the same at 8.6 ns, to see the spread between 2 placements: output\OOC_SCHED_T8.6
REM   synth_ooo.bat exu        bypass + ALU with the register file at a 10 ns target, in output\OOC_EXU_T10 (loop 2)
REM   synth_ooo.bat exu9       the same at 9 ns, for the margin: output\OOC_EXU_T9
REM   synth_ooo.bat ubtb       the uBTB of the new core at 9 ns, in output\OOC_UBTB2_T9 (loop 6)
REM   synth_ooo.bat lsu2       the memory port of the new core at 9 ns, in output\OOC_LSU2_T9 (loop 3)
REM   synth_ooo.bat ren2       renaming of 4 at 9 ns, in output\OOC_RENAME2_T9 (loop 4)
REM   synth_ooo.bat fbuf2      the fetch buffer of the new core at 9 ns, in output\OOC_FBUF2_T9 (loop 5)
REM   synth_ooo.bat fe2        F3, F4, F0, D1 of the new core together at 9 ns, in output\OOC_FE2_T9
REM   synth_ooo.bat cpu10      the whole core with its D$ at a 10 ns target, in output\OOO_CPU_T10 (what the core adds: step 1.3)
REM   synth_ooo.bat iq2        the queue of 24 with 6 selects of the 50 MHz core at 15 ns, in output\OOC_IQ2_T15 (Doc/STRATEGY.md 4.5 loop 1)
REM   synth_ooo.bat exu2       RR, EX of the 6 ports of the 50 MHz core with the register file at 15 ns, in output\OOC_EXU2_T15 (loop 2)
REM   synth_ooo.bat lsu3       the 2 memory ports of the 50 MHz core at 15 ns, in output\OOC_LSU3_T15 (loop 3)
REM   synth_ooo.bat fe3        F2, F0, D1 of the 50 MHz core together at 15 ns, in output\OOC_FE3_T15 (loop 4)
REM   synth_ooo.bat ren3       rename, busy bits and the queue of the 50 MHz core joined at 15 ns, in output\OOC_REN3_T15 (loop 6)
REM   synth_ooo.bat schedrpt   the classes of that finished run, without running it again: output\OOC_SCHED_T10\summary_loop.txt
REM
REM vivado is itself a batch file: without "call" this one would end after
REM the first run outside a loop (the register files did not run, 2026-10-24)
if not exist output mkdir output
if /i "%~1"=="prf" goto :prf
if /i "%~1"=="t100" goto :t100
if /i "%~1"=="sched" goto :sched
if /i "%~1"=="sched85" goto :sched85
if /i "%~1"=="sched86" goto :sched86
if /i "%~1"=="exu" goto :exu
if /i "%~1"=="exu9" goto :exu9
if /i "%~1"=="ubtb" goto :ubtb
if /i "%~1"=="lsu2" goto :lsu2
if /i "%~1"=="ren2" goto :ren2
if /i "%~1"=="fbuf2" goto :fbuf2
if /i "%~1"=="fe2" goto :fe2
if /i "%~1"=="cpu10" goto :cpu10
if /i "%~1"=="iq2" goto :iq2
if /i "%~1"=="exu2" goto :exu2
if /i "%~1"=="lsu3" goto :lsu3
if /i "%~1"=="fe3" goto :fe3
if /i "%~1"=="ren3" goto :ren3
if /i "%~1"=="schedrpt" goto :schedrpt
if not "%~1"=="" (
    call vivado -mode batch -source synth_ooo.tcl -log output\vivado_%~1.log -journal output\vivado_%~1.jou -tclargs %*
    goto :done
)
for %%t in (OOC_ALU2 OOC_FUSE OOC_RENAME OOO_IQ OOO_UBTB OOC_LSU OOC_ROB OOC_FBUF OOC_FTQ OOC_FRONT OOC_DEC OOC_IQPL OOC_LSUDC OOC_CTRL OOC_DSREG OOC_FERS OOC_TRAP OOC_SYS OOC_CSRU OOC_MDUP OOC_PMUL) do (
    call vivado -mode batch -source synth_ooo.tcl -log output\vivado_%%t.log -journal output\vivado_%%t.jou -tclargs %%t 20.0 1
)
REM ALU1 (G0b L7): the ALU port with the limited ALU
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_OOC_ALU2_FULL0.log -journal output\vivado_OOC_ALU2_FULL0.jou -tclargs OOC_ALU2 20.0 1 "FULL=0"
:prf
REM the register file with the write / read ports of Plan/OOC.md
for %%p in (3_8 5_8 6_9 3_6 5_6) do (
    for /f "tokens=1,2 delims=_" %%w in ("%%p") do (
        call vivado -mode batch -source synth_ooo.tcl -log output\vivado_prf_w%%wr%%x.log -journal output\vivado_prf_w%%wr%%x.jou -tclargs OOC_PRF 20.0 1 "NW=%%w NR=%%x"
    )
)
goto :done
:t100
for %%t in (OOO_IQ OOC_RENAME OOC_FBUF OOC_DEC OOC_ROB OOC_LSU OOC_LSUDC OOO_UBTB OOC_FE) do (
    call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T10_%%t.log -journal output\vivado_T10_%%t.jou -tclargs %%t 10.0 1
)
REM the ALU ports without the fused compare: full, and ALU1's
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T10_ALU2.log -journal output\vivado_T10_ALU2.jou -tclargs OOC_ALU2 10.0 1 "FUSED=0"
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T10_ALU1.log -journal output\vivado_T10_ALU1.jou -tclargs OOC_ALU2 10.0 1 "FULL=0 FUSED=0"
goto :done
:sched
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T10_SCHED.log -journal output\vivado_T10_SCHED.jou -tclargs OOC_SCHED 10.0 1
goto :done
:sched85
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T85_SCHED.log -journal output\vivado_T85_SCHED.jou -tclargs OOC_SCHED 8.5 1
goto :done
:sched86
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T86_SCHED.log -journal output\vivado_T86_SCHED.jou -tclargs OOC_SCHED 8.6 1
goto :done
:exu
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T10_EXU.log -journal output\vivado_T10_EXU.jou -tclargs OOC_EXU 10.0 1
goto :done
:exu9
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T9_EXU.log -journal output\vivado_T9_EXU.jou -tclargs OOC_EXU 9.0 1
goto :done
:ubtb
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T9_UBTB2.log -journal output\vivado_T9_UBTB2.jou -tclargs OOC_UBTB2 9.0 1
goto :done
:lsu2
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T9_LSU2.log -journal output\vivado_T9_LSU2.jou -tclargs OOC_LSU2 9.0 1
goto :done
:ren2
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T9_REN2.log -journal output\vivado_T9_REN2.jou -tclargs OOC_RENAME2 9.0 1
goto :done
:fbuf2
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T9_FBUF2.log -journal output\vivado_T9_FBUF2.jou -tclargs OOC_FBUF2 9.0 1
goto :done
:fe2
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T9_FE2.log -journal output\vivado_T9_FE2.jou -tclargs OOC_FE2 9.0 1
goto :done
:cpu10
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T10_CPU.log -journal output\vivado_T10_CPU.jou -tclargs OOO_CPU 10.0 1
goto :done
:iq2
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T15_IQ2.log -journal output\vivado_T15_IQ2.jou -tclargs OOC_IQ2 15.0 1
goto :done
:exu2
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T15_EXU2.log -journal output\vivado_T15_EXU2.jou -tclargs OOC_EXU2 15.0 1
goto :done
:lsu3
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T15_LSU3.log -journal output\vivado_T15_LSU3.jou -tclargs OOC_LSU3 15.0 1
goto :done
:fe3
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T15_FE3.log -journal output\vivado_T15_FE3.jou -tclargs OOC_FE3 15.0 1
goto :done
:ren3
call vivado -mode batch -source synth_ooo.tcl -log output\vivado_T15_REN3.log -journal output\vivado_T15_REN3.jou -tclargs OOC_REN3 15.0 1
goto :done
:schedrpt
call vivado -mode batch -source report_sched.tcl -log output\vivado_rpt_SCHED.log -journal output\vivado_rpt_SCHED.jou -tclargs output/OOC_SCHED_T10
:done
echo Done. The numbers are in output\*\summary.txt
