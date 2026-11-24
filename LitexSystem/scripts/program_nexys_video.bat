@echo off
REM Load digilent_nexys_video.bit into the Nexys Video over JTAG (J12), on the Windows VM.
REM Run it from the gateware directory (build_stock.sh copies it there). Volatile: lost at power-off.
vivado -mode batch -nojournal -nolog -source program_nexys_video.tcl
if errorlevel 1 (
    echo Programming failed.
    exit /b 1
)
echo Programmed.
