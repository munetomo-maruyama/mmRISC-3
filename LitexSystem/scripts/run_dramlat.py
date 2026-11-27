#!/usr/bin/env python3
#---------------------------------------------------------------------------
# run_dramlat.py : load a bare-metal program into the main RAM by the BIOS's
#                  serial boot and print what it says (step 2.5's dramlat,
#                  LitexSystem/docs/BRINGUP.md 27)
#
#   python3 LitexSystem/scripts/run_dramlat.py [image [address [log]]]
#       (default LitexSystem/build/dramlat/dramlat.bin at 0x80000000)
#
# Run with the LiteX workspace's Python (it uses litex_term's SFL frames). The
# UART is J13's FT232R, found by its name. At litex> it types serialboot;
# otherwise it types reboot (LiteX's demo has it) and catches the serial boot
# at the BIOS's start, and failing that asks for CPU RESET. It ends at "DRAMLAT DONE" (the program
# then resets the SoC) or after 600 s.
#---------------------------------------------------------------------------
import glob, os, sys, time
import serial
from litex.tools.litex_term import SFLFrame, sfl_magic_req, sfl_magic_ack, \
    sfl_cmd_load, sfl_cmd_jump, sfl_data_length

HERE  = os.path.dirname(os.path.abspath(__file__))
IMAGE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "build", "dramlat", "dramlat.bin")
ADDR  = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x80000000
LOG   = sys.argv[3] if len(sys.argv) > 3 else None

def find_uart():
    for tty in sorted(glob.glob("/sys/class/tty/ttyUSB*")):
        usb = os.path.realpath(os.path.join(tty, "device", "..", ".."))
        try:
            if open(os.path.join(usb, "product")).read().strip() == "FT232R USB UART":
                return "/dev/" + os.path.basename(tty)
        except OSError:
            pass
    sys.exit("no FT232R (J13) on this VM")

port = serial.Serial(find_uart(), 115200, timeout=0.05)
log  = open(LOG, "w") if LOG else None
def out(b):
    s = b.decode("latin-1")
    sys.stdout.write(s); sys.stdout.flush()
    if log: log.write(s); log.flush()

def wait_for(pattern, seconds, echo=True):
    buf = b""
    end = time.time() + seconds
    while time.time() < end:
        d = port.read(256)
        if d:
            buf += d
            if echo: out(d)
            if pattern in buf:
                return True
    return False

def send(frame, tries=8):
    for _ in range(tries):
        port.write(frame.encode())
        r = b""
        end = time.time() + 1.0
        while time.time() < end and not r:
            r = port.read(1)
        if r == b"K":
            return
    sys.exit("SFL: no acknowledgement")

port.reset_input_buffer()
port.write(b"\x15\r")
if wait_for(b"litex>", 2, echo=False):
    port.write(b"serialboot\r")
    found = wait_for(sfl_magic_req, 3, echo=False)
else:
    found = False
if not found:
    # LiteX's demo (or this program's own prompt) has reboot: the SoC's reset
    port.write(b"\x15\rreboot\r")
    found = wait_for(sfl_magic_req, 10, echo=False)
if not found:
    print("[run_dramlat] the BIOS is not at litex>: press CPU RESET on the board (60 s)")
    found = wait_for(sfl_magic_req, 60, echo=False)
if not found:
    sys.exit("no serial boot request from the BIOS")
port.write(sfl_magic_ack)

data = open(IMAGE, "rb").read()
print(f"[run_dramlat] loading {os.path.basename(IMAGE)} ({len(data)} bytes) at 0x{ADDR:08x}")
for off in range(0, len(data), sfl_data_length):
    f = SFLFrame(); f.cmd = sfl_cmd_load
    f.payload = (ADDR + off).to_bytes(4, "big") + data[off:off + sfl_data_length]
    send(f)
f = SFLFrame(); f.cmd = sfl_cmd_jump; f.payload = ADDR.to_bytes(4, "big")
send(f)
ok = wait_for(b"DRAMLAT DONE", 600)
print("\n[run_dramlat] " + ("done" if ok else "TIMEOUT"))
sys.exit(0 if ok else 1)
