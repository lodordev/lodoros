#!/bin/sh
# Reboot.pak — clean restart from the Tools menu. The Flip's power button can sleep/resume rather than
# truly restart, which leaves the OLD launcher binary in memory; this forces a real reboot so updated
# minui.elf / paks load. Flushes filesystem buffers first so nothing is lost.
sync; sync
# busybox reboot; fall back to the kernel sysrq path, then poweroff, if reboot is a no-op on this build.
reboot 2>/dev/null
sleep 3
/sbin/reboot -f 2>/dev/null
sleep 2
poweroff -f 2>/dev/null
