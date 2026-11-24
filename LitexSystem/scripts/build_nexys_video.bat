@echo off
REM Vivado build of LiteX's stock Nexys Video SoC (step 2.0, build_stock.sh), on the Windows VM.
REM Run it from LitexSystem\build_stock\gateware (build_stock.sh copies it there).
REM The tcl reads its sources through relative paths, so the share's drive letter does not matter.
vivado -mode batch -source digilent_nexys_video.tcl
if errorlevel 1 (
    echo Vivado build failed.
    exit /b 1
)
echo Vivado build finished. Bitstream: digilent_nexys_video.bit
