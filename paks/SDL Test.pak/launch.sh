#!/bin/sh
# SDL scanout self-test (miyoomini / SigmaStar SSD202D) — the round-trip killer.
#
# WHY: on the SSD202D, raw /dev/fb0 is a dead scanout surface for a standalone (post-minui-exit)
# process, so the launch card renders through the SDL 1.2 helper (lodor-fbhelper, MI_GFX). Whether
# that helper actually scans out from a NON-minui process is the one unproven unknown behind the
# launch card. This pak isolates it: MinUI exits to run any pak, so this launch.sh executes in
# EXACTLY the standalone condition the card faces — no wizard, no input, no RomM.
#
# WHAT: pipe one solid-WHITE 640x480 RGB565 frame to lodor-fbhelper and hold it ~5s, then EOF.
#   WHITE screen  -> SDL+MI_GFX scans out standalone => the wizard launch card WILL render.
#   BLACK/nothing -> SDL can't scan out standalone here => pivot (don't cut more blind RCs).
# Result is also written to selftest.log next to this script.
set -u
DIR="$(dirname "$0")"
cd "$DIR" || exit 1
HELPER="$DIR/../Lodor.pak/bin/lodor-fbhelper"
LOG="$DIR/selftest.log"
: > "$LOG" 2>/dev/null

echo "$(date '+%F %T') sdl-selftest start helper=$HELPER" >> "$LOG"
if [ ! -f "$HELPER" ]; then
	echo "$(date '+%F %T') helper MISSING — nothing to test" >> "$LOG"
	# say.elf is the #19-safe on-screen channel on miyoomini
	command -v say.elf >/dev/null 2>&1 && say.elf "SDL helper missing" 2>/dev/null
	sleep 2
	exit 1
fi

# LFB1 wire header (all u32 little-endian): magic 'LFB1', width 640, height 480, bpp 2 (RGB565),
# then one full frame = 640*480*2 = 614400 bytes. 0xFF fill => RGB565 0xFFFF = solid white. The
# trailing sleep holds the pipe open so the helper keeps the flipped frame on screen; on EOF the
# helper exits(0) without blanking (caller owns teardown), so white persists until MinUI redraws.
{
	printf 'LFB1'
	printf '\200\002\000\000'   # width  640 = 0x00000280
	printf '\340\001\000\000'   # height 480 = 0x000001E0
	printf '\002\000\000\000'   # bpp 2 (RGB565)
	head -c 614400 /dev/zero | tr '\000' '\377'
	sleep 5
} | "$HELPER" >> "$LOG" 2>&1
echo "$(date '+%F %T') sdl-selftest done (pipe closed)" >> "$LOG"
