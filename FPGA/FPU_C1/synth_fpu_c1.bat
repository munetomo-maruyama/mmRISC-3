@echo off
REM synth_fpu_c1.bat [period [impl]]
REM   the breakdown of mmRISC-2's FPU_PIPE in Vivado, out of context
REM   (option C1 of Plan/REDUCE.md; see synth_fpu_c1.tcl)
REM   set MMRISC2=<path> first if mmRISC-2 is not at ..\..\..\mmRISC-2
if not exist output mkdir output
call vivado -mode batch -source synth_fpu_c1.tcl -log output\vivado_fpu_c1.log -journal output\vivado_fpu_c1.jou -tclargs %*
echo Done. The table is in output\FPU_C1\breakdown.txt
