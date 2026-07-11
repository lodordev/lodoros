#!/bin/sh
# Reset WiFi — recovers a wedged radio (the 8188fu "associates but never gets a DHCP lease"
# stall, and friends). Rewritten for the clean-engine era (#2): grout32 is gone, so this pak
# drives Lodor.pak's own machinery directly — bin/wifi-reset (the proven USB re-enum, rail
# left ON) on the miyoomini's 8188fu, the stock Wifi.pak service cycle on SDIO radios — then
# brings the link back up via the lib's verified path and reports the HONEST outcome.
# On-screen messaging follows Update Lodor.pak's platform-gated pattern (#19): on miyoomini,
# minui-presenter/killall wedges the framebuffer BLACK (presenter's signal handlers exit()
# without GFX teardown; MinUI's miyoomini layer allocates the video surface from the SigmaStar
# MI pool with no restore path) — so miyoomini uses MinUI's own SELF-EXITING tools instead:
# show.elf draws res/<phase>.png for in-progress phases (fire-and-forget), foreground say.elf
# blocks until A/B for terminal states and exits cleanly. NEVER kill/killall ANY process with
# a video context on miyoomini. Other platforms keep the presenter/minui-list flow (borrowed
# from the always-present Wifi.pak per-platform bins) unchanged. NEVER a silent exit: every
# terminal state is drawn on-screen when the tools exist and is always logged.
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-miyoomini}"
PAKDIR="$(cd "$(dirname "$0")" && pwd)"   # absolute: show.elf wants an abs PNG path
LODOR="$SDCARD/Tools/$PLAT/Lodor.pak"
LOG="$LODOR/wifi-reset.log"
log(){ echo "$(date +'%F %T') [pak] $1" >> "$LOG" 2>/dev/null; }

arch=arm; uname -m 2>/dev/null | grep -q 64 && arch=arm64
export PATH="$SDCARD/Tools/$PLAT/Wifi.pak/bin/$PLAT:$SDCARD/Tools/$PLAT/Wifi.pak/bin/$arch:$PATH"
MM=""; [ "$PLAT" = miyoomini ] && MM=1
SYSBIN="$SDCARD/.system/$PLAT/bin"
# have_ui is the presenter/list gate: HARD-FALSE on miyoomini so every presenter/killall branch
# below is structurally unreachable there (asserted by test/miyoomini-ui-check.sh).
have_ui(){ [ -z "$MM" ] && command -v minui-presenter >/dev/null 2>&1; }
# mm_wrap <text> — insert \n every ~36 chars, word-safe: GFX_blitMessage (say.elf's
# renderer) splits ONLY on \n and centers each row; a long single line runs off BOTH
# screen edges (hardware photo, 2026-07-11). Pure busybox sh, no fold dependency.
mm_wrap(){
	_out=""; _cur=""
	for _w in $1; do
		if [ -z "$_cur" ]; then _cur="$_w"
		elif [ "${#_cur}" -le 36 ] && [ "$(( ${#_cur} + 1 + ${#_w} ))" -le 36 ]; then _cur="$_cur $_w"
		else _out="${_out}${_out:+
}${_cur}"; _cur="$_w"
		fi
	done
	printf '%s' "${_out}${_out:+
}${_cur}"
}
# mm_show <phase-key> — miyoomini phases are LOG-ONLY: the PNG-via-show.elf experiment
# rendered as a corrupted pixel band on hardware (grayscale vs 32bpp blit, photo-verified
# 2026-07-11), and show.elf from menu context stays banned. The final say.elf message is
# the one screen the user gets — phases live in update.log.
mm_show(){
	log "phase: $1"
	return 0
}
# mm_final <msg> — FOREGROUND say.elf: draws, blocks until A/B, exits through GFX teardown.
# Never backgrounded, never killed. Degrades to log-only (the caller already logged).
mm_final(){ [ -x "$SYSBIN/say.elf" ] && "$SYSBIN/say.elf" "$(mm_wrap "$1")" >/dev/null 2>&1; return 0; }

# ui_hold <phase-key> <msg> — in-progress phase. miyoomini: draw res/<phase-key>.png ONCE per
# phase, log every update (dynamic lines refresh the LOG, not the screen). Others: presenter.
UI_PID=""
MM_PHASE=""
ui_hold(){
	if [ -n "$MM" ]; then
		log "MSG: $2"
		[ "$1" = "$MM_PHASE" ] && return 0
		MM_PHASE="$1"
		mm_show "$1"
		return 0
	fi
	if have_ui; then
		killall minui-presenter >/dev/null 2>&1
		minui-presenter --message "$2" --timeout -1 >/dev/null 2>&1 &
		UI_PID=$!
	fi
	log "MSG: $2"
}
# miyoomini: nothing to stop — show.elf already exited; the next draw replaces the screen.
ui_stop(){
	if [ -n "$MM" ]; then MM_PHASE=""; return 0; fi
	[ -n "$UI_PID" ] && kill "$UI_PID" >/dev/null 2>&1; killall minui-presenter >/dev/null 2>&1; UI_PID="";
}
# Terminal states must never flash past unread. miyoomini: foreground say.elf (A/B ack, clean
# exit — the safe acknowledger; NO minui-list and NO killall on this platform). Others: A/B ack
# via minui-list, degrading to a long presenter flash, then to log-only.
ui_sticky(){
	if [ -n "$MM" ]; then
		MM_PHASE=""
		log "MSG: $1"
		mm_final "$1"
		return 0
	fi
	ui_stop
	log "MSG: $1"
	if have_ui && command -v minui-list >/dev/null 2>&1; then
		printf 'OK\n' > /tmp/rw-ack
		minui-list --disable-auto-sleep --file /tmp/rw-ack --format text \
			--title "$1" --confirm-text "OK" --cancel-text "OK" \
			--write-location /tmp/rw-ack-out >/dev/null 2>&1
		rm -f /tmp/rw-ack /tmp/rw-ack-out 2>/dev/null
	elif have_ui; then
		minui-presenter --message "$1" --timeout 6 >/dev/null 2>&1
	fi
}

if [ ! -f "$LODOR/lib/romm-sync-lib.sh" ]; then
	ui_sticky "Can't reset: Lodor.pak's library is missing from this card."
	exit 1
fi
export WIFI_LOG="$LODOR/wifi-debug.log"   # surface service-on/wait_net internals (same as romm-run)
. "$LODOR/lib/romm-sync-lib.sh" 2>/dev/null || { ui_sticky "Can't reset: Lodor.pak's library failed to load."; exit 1; }
trap 'ui_stop; wifi_release' EXIT INT TERM HUP QUIT

log "=== Reset WiFi pak start (plat=$PLAT) ==="

# BUSY PRE-CHECK: the reset half below cycles the radio — doing that while a LIVE actor
# holds the transfer mutex kills that transfer mid-flight. The old flow only discovered
# "busy" at the bring-up half (wifi_acquire rc=2), AFTER the radio was already reset.
# Check first; offer the honest choice where a safe question tool exists.
if _actor_active; then
	if [ -n "$MM" ]; then
		# miyoomini UI law: say.elf only ACKNOWLEDGES (no question tool; minui-list and
		# killall are illegal on this platform) — abort with the honest message.
		log "busy pre-check: live sync holds the mutex — aborting (miyoomini, no question UI)"
		ui_sticky "A sync is running right now — try the reset again in a minute."
		exit 1
	fi
	_override=""
	if have_ui && command -v minui-list >/dev/null 2>&1; then
		killall minui-presenter >/dev/null 2>&1
		printf 'Reset anyway\n' > /tmp/rw-busy
		minui-list --disable-auto-sleep --file /tmp/rw-busy --format text \
			--title "A sync is running. Reset anyway?" --confirm-text "YES" --cancel-text "NO" \
			--write-location /tmp/rw-busy-out >/dev/null 2>&1
		_brc=$?
		_bsel="$(cat /tmp/rw-busy-out 2>/dev/null)"
		rm -f /tmp/rw-busy /tmp/rw-busy-out 2>/dev/null
		[ "$_brc" = 0 ] && [ "$_bsel" = "Reset anyway" ] && _override=1
	fi
	if [ -z "$_override" ]; then
		log "busy pre-check: live sync holds the mutex — user declined / no question UI"
		ui_sticky "A sync is running right now — try the reset again in a minute."
		exit 1
	fi
	log "busy pre-check: user chose to reset anyway over a live sync"
fi

ui_hold resetting-wifi "Resetting Wi-Fi..."
# The reset half. miyoomini 8188fu: the proven USB re-enum (bin/wifi-reset — power rail LEFT
# ON, see that script's header). Every other platform has an SDIO radio — a USB unbind is
# meaningless there, so cycle the stock Wifi.pak service instead (service-off here; the
# verified bring-up below is the on half).
did=""
if [ "$PLAT" = miyoomini ] && [ -x "$LODOR/bin/wifi-reset" ]; then
	"$LODOR/bin/wifi-reset" >> "$LOG" 2>&1
	date +%s > /tmp/romm-last-reenum 2>/dev/null   # manual reset shares the auto-recovery cooldown clock
	did="usb re-enum"
elif [ -x "$WIFI_BIN/service-off" ]; then
	"$WIFI_BIN/service-off" >> "$LOG" 2>&1
	sleep 2
	did="service cycle"
fi
if [ -z "$did" ]; then
	ui_sticky "Can't reset: no reset tool on this device (wifi-reset and service-off both missing)."
	exit 1
fi
log "reset done ($did) — bringing the link back up"

# The bring-up half: the lib's verified path (service-on -> wpa COMPLETED -> real DHCP lease).
# wifi_acquire narrates honest phases into /tmp/romm-phase; mirror them on-screen live.
ui_hold resetting-wifi "Reconnecting Wi-Fi..."
rm -f /tmp/rw-rc 2>/dev/null
( if wifi_acquire fg; then echo 0 > /tmp/rw-rc; else echo $? > /tmp/rw-rc; fi ) &
APID=$!
_last=""
while kill -0 "$APID" 2>/dev/null; do
	ph="$(cat /tmp/romm-phase 2>/dev/null)"
	if [ -n "$ph" ] && [ "$ph" != "$_last" ]; then _last="$ph"; ui_hold resetting-wifi "$ph"; fi
	sleep 1
done
wait "$APID" 2>/dev/null
rc="$(cat /tmp/rw-rc 2>/dev/null)"; rm -f /tmp/rw-rc 2>/dev/null
case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
log "bring-up rc=$rc"

if [ "$rc" = 2 ]; then
	ui_sticky "Wi-Fi is busy with another sync right now — try again in a minute."
	exit 1
fi
if [ "$rc" = 0 ] && _radio_ready; then
	_ip="$(_wlan_ip 2>/dev/null)"
	ui_sticky "Wi-Fi reset done — back online${_ip:+ ($_ip)}."
	exit 0
fi
# Failed: relay wifi_acquire's specific honest reason (it owns /tmp/romm-phase).
_why="$(cat /tmp/romm-phase 2>/dev/null)"
[ -n "$_why" ] || _why="Wi-Fi didn't come back up"
ui_sticky "Reset ran, but: $_why. Try again, or check the router."
exit 1
