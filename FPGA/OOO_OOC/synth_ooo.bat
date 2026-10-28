@echo off
REM synth_ooo.bat : the blocks of mmRISC-3's out-of-order core in Vivado,
REM out of context, one after another (see synth_ooo.tcl and Plan/OOC.md)
REM
REM   synth_ooo.bat            all runs below, 50 MHz, with place and route
REM   synth_ooo.bat prf        the five register files only
REM   synth_ooo.bat OOC_ALU2   one top only (the arguments of synth_ooo.tcl)
REM
REM vivado is itself a batch file: without "call" this one would end after
REM the first run outside a loop (the register files did not run, 2026-10-24)
if not exist output mkdir output
if /i "%~1"=="prf" goto :prf
if not "%~1"=="" (
    call vivado -mode batch -source synth_ooo.tcl -log output\vivado_%~1.log -journal output\vivado_%~1.jou -tclargs %*
    goto :done
)
for %%t in (OOC_ALU2 OOC_FUSE OOC_RENAME OOO_IQ OOO_UBTB OOC_LSU OOC_ROB OOC_FBUF OOC_FTQ OOC_FRONT OOC_DEC OOC_IQPL OOC_LSUDC OOC_CTRL OOC_DSREG OOC_FERS OOC_TRAP OOC_SYS) do (
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
:done
echo Done. The numbers are in output\*\summary.txt
