# program_nexys_video.tcl : load digilent_nexys_video.bit into the FPGA over JTAG (J12), not into the flash
# (step 2.0, LitexSystem/docs/BRINGUP.md). Run from the gateware directory by program_nexys_video.bat.
# The hw_server just launched may not list the cable yet: open_hw_target alone then fails with "There is no
# current hw_target" (BRINGUP 5), so the targets are looked for again for up to 20 s and the first is opened.
open_hw_manager
connect_hw_server -allow_non_jtag
set targets {}
for {set i 0} {$i < 20 && [llength $targets] == 0} {incr i} {
    refresh_hw_server -quiet
    set targets [get_hw_targets -quiet]
    if {[llength $targets] == 0} { after 1000 }
}
if {[llength $targets] == 0} {
    puts "ERROR: no JTAG cable found (J12 on this VM? the Vivado GUI's hardware manager closed?)"
    exit 1
}
puts "JTAG target: [lindex $targets 0]"
current_hw_target [lindex $targets 0]
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE {digilent_nexys_video.bit} $dev
program_hw_devices $dev
close_hw_target
disconnect_hw_server
close_hw_manager
