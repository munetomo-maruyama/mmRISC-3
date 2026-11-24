# program_nexys_video.tcl : load digilent_nexys_video.bit into the FPGA over JTAG (J12), not into the flash
# (step 2.0, LitexSystem/docs/BRINGUP.md). Run from the gateware directory by program_nexys_video.bat.
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE {digilent_nexys_video.bit} $dev
program_hw_devices $dev
close_hw_target
disconnect_hw_server
close_hw_manager
