@echo off
REM synth_ooo.bat : the blocks of mmRISC-3's out-of-order core in Vivado,
REM out of context, one after another (see synth_ooo.tcl and Plan/OOC.md)
REM
REM   synth_ooo.bat            all runs below, 50 MHz, with place and route
REM   synth_ooo.bat OOC_ALU2   one top only (the arguments of synth_ooo.tcl)
if not exist output mkdir output
if not "%~1"=="" (
    vivado -mode batch -source synth_ooo.tcl -log output\vivado.log -journal output\vivado.jou -tclargs %*
    goto :done
)
for %%t in (OOC_ALU2 OOC_FUSE OOC_RENAME OOO_IQ OOO_UBTB) do (
    vivado -mode batch -source synth_ooo.tcl -log output\vivado_%%t.log -journal output\vivado_%%t.jou -tclargs %%t 20.0 1
)
REM the register file with the write / read ports of Plan/OOC.md
vivado -mode batch -source synth_ooo.tcl -log output\vivado_prf_w3r8.log -tclargs OOC_PRF 20.0 1 "NW=3 NR=8"
vivado -mode batch -source synth_ooo.tcl -log output\vivado_prf_w5r8.log -tclargs OOC_PRF 20.0 1 "NW=5 NR=8"
vivado -mode batch -source synth_ooo.tcl -log output\vivado_prf_w6r9.log -tclargs OOC_PRF 20.0 1 "NW=6 NR=9"
vivado -mode batch -source synth_ooo.tcl -log output\vivado_prf_w3r6.log -tclargs OOC_PRF 20.0 1 "NW=3 NR=6"
vivado -mode batch -source synth_ooo.tcl -log output\vivado_prf_w5r6.log -tclargs OOC_PRF 20.0 1 "NW=5 NR=6"
:done
echo Done. The numbers are in output\*\summary.txt
