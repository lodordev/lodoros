#!/bin/sh
# minarch.elf — RomM session-sync shim.   MARKER: ROMM_MINARCH_SHIM
#
# Installed in place of the stock minarch.elf (renamed to minarch.real.elf by install.sh). Every game
# launches through `minarch.elf "<core.so>" "<rom path>"`, so this wraps every game: pull the ROM's
# save before play (best-effort, bounded), launch the real emulator, push the save after.
#
# HARD RULE: the game launch is NEVER conditional on sync. Every sync call is best-effort and guarded;
# if anything about sync is missing or fails, the real emulator still runs. A broken shim here bricks
# every game, so the launch line is the load-bearing part and everything else is second-class.

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-miyoomini}"
REAL="$SDCARD/.system/$PLAT/bin/minarch.real.elf"   # absolute: $0/dirname is unreliable via PATH
HELPER="$SDCARD/Tools/$PLAT/Lodor.pak/bin/romm-session-sync"
ROM="$2"                                            # minarch.elf "<core.so>" "<rom path>"
INGAME_LOCK="/tmp/romm-in-game"

# Mark a game session so the daemon won't bring WiFi up mid-play (PID-based; daemon reaps if killed).
echo "$$" > "$INGAME_LOCK" 2>/dev/null
trap 'rm -f "$INGAME_LOCK" 2>/dev/null' EXIT INT TERM HUP QUIT

# Download-on-launch FALLBACK: if the ROM is a 0-byte STUB (a catalog entry for a game not yet on the
# card) and it slipped past the launcher's native "Downloading…" overlay (the normal menu path now
# downloads stubs in minui.c BEFORE launching), fetch the real file here. romm-run owns the WiFi shell
# lock (one process acquires + releases), runs the headless --download (fetch + sha verify, leaves the
# radio warm for the save pull below). No grout32 / gabagool — this runs post-exit with no UI, so it's
# silent by design (the on-screen flow lives in the launcher). If the download fails, do NOT launch an
# empty ROM — clear the lock and exit to menu.
if [ -f "$ROM" ] && [ ! -s "$ROM" ]; then
	ROMM_RUN="$SDCARD/Tools/$PLAT/Lodor.pak/bin/romm-run"
	[ -x "$ROMM_RUN" ] && "$ROMM_RUN" --download "$ROM" >/dev/null 2>&1
	if [ ! -s "$ROM" ]; then
		rm -f "$INGAME_LOCK" 2>/dev/null
		exit 0   # download failed/declined — nothing to launch
	fi
fi

# Pre-game save pull — OPPORTUNISTIC. Launching a game must NEVER bring WiFi up: a cold bring-up is a
# 30-45s delay on EVERY launch and it cold-cycles the 8188fu (the wedge risk). So we pull ONLY when WiFi
# is ALREADY up — a stub we just downloaded leaves the radio warm, or the user turned WiFi on to sync.
# Otherwise the game launches instantly, offline, on the local save. (Inline check, no lib sourcing — the
# launch below is load-bearing and must not inherit the lib's shell options or side effects.) Still
# hard-capped by `timeout` so even a warm-but-flaky link can't block the launch.
romm_wifi_up() {
	[ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = "up" ] || return 1
	ip addr show wlan0 2>/dev/null | grep -q "inet " || return 1
	return 0
}
if [ -x "$HELPER" ] && [ -n "$ROM" ] && romm_wifi_up; then
	if command -v timeout >/dev/null 2>&1; then
		timeout 20 "$HELPER" pull "$ROM" >/dev/null 2>&1
	else
		"$HELPER" pull "$ROM" >/dev/null 2>&1
	fi
fi

# Launch the real emulator. NEVER gated on sync.
if [ -x "$REAL" ]; then
	"$REAL" "$@"
	rc=$?
else
	echo "$(date +'%F %T') [shim] FATAL real minarch missing: $REAL" >> "$SDCARD/Tools/$PLAT/Lodor.pak/session.log" 2>/dev/null
	rc=127
fi

# Post-game HYBRID sync: the save is already CACHED on the card (the real emulator wrote it to /Saves/).
# If it CHANGED this session, sync it the way the CURRENT radio state allows:
#   * WiFi ALREADY UP (online): push it straight to RomM now via romm-session-sync, which writes
#     last-synced.txt on a VERIFIED land (the launcher flashes "synced ✓") or stages it to the pending
#     queue if it doesn't land. We pull NO cold bring-up here — only a warm link is used, hard-capped by
#     `timeout` so a flaky warm link still can't wedge the return to the menu.
#   * WiFi DOWN (offline): just record the ROM as pending upload — NO sync, NO WiFi, instant return to
#     the menu. This device is often off-WiFi and a quit must NEVER block on/cold-cycle the radio. The
#     root-menu pending badge reminds the user to upload when they next have WiFi (offline-first).
PENDING="$SDCARD/Tools/$PLAT/Lodor.pak/pending-saves.txt"
if [ -n "$ROM" ]; then
	_rb=$(basename "$ROM"); _rbne="${_rb%.*}"
	# any save file for THIS rom modified since the game started (INGAME_LOCK's mtime = launch)?
	if find "$SDCARD/Saves" \( -iname "$_rb.*" -o -iname "$_rbne.srm" -o -iname "$_rbne.sav" -o -iname "$_rbne.rtc" \) 2>/dev/null | grep -q .; then
		if [ -x "$HELPER" ] && romm_wifi_up; then
			if command -v timeout >/dev/null 2>&1; then
				timeout 30 "$HELPER" push "$ROM" >/dev/null 2>&1
			else
				"$HELPER" push "$ROM" >/dev/null 2>&1
			fi
		else
			grep -qxF "$ROM" "$PENDING" 2>/dev/null || echo "$ROM" >> "$PENDING"
		fi
	fi
fi

exit "$rc"
