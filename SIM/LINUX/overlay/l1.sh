#!/bin/sh
# SIM/LINUX/overlay/l1.sh : step 1.8 L1 (Plan/OOC.md 29.99), run by inittab in
# place of the console's shell. An interactive ash shows its prompt and runs a
# few commands (from a pipe: the bench types nothing), then the board is
# powered off: OpenSBI's system reset is HTIF's exit, so the run ends as a
# test does and the lock-step reference's exit code is compared.
cd /root
printf '%s\n' 'uname -a' 'cat /proc/cpuinfo' 'ls /' 'free' 'echo L1 done' | /bin/ash -i
poweroff -f
