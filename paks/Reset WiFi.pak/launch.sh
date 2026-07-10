#!/bin/sh
# Reset WiFi — recovers a wedged radio (the 8188fu "associates but never gets a DHCP lease"
# stall, and friends). Rewritten for the clean-engine era (#2): grout32 is gone, so this pak
# drives Lodor.pak's own machinery directly — bin/wifi-reset (the proven USB re-enum, rail
# left ON) on the miyoomini's 8188fu, the stock Wifi.pak service cycle on SDIO radios — then
# brings the link back up via the lib's verified path and reports the HONEST outcome.
# On-screen messaging follows Update Lodor.pak's pattern: minui-presenter/minui-list borrowed
# from the always-present Wifi.pak per-platform bins (say.elf is log-only on miyoomini — it
# leaves the framebuffer black; see the lib's feedback section). NEVER a silent exit: every
# terminal state is drawn on-screen when the tools exist and is always logged.
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-miyoomini}"
LODOR="$SDCARD/Tools/$PLAT/Lodor.pak"
LOG="$LODOR/wifi-reset.log"
log(){ echo "$(date +'%F %T') [pak] $1" >> "$LOG" 2>/dev/null; }

arch=arm; uname -m 2>/dev/null | grep -q 64 && arch=arm64
export PATH="$SDCARD/Tools/$PLAT/Wifi.pak/bin/$PLAT:$SDCARD/Tools/$PLAT/Wifi.pak/bin/$arch:$PATH"
have_ui(){ command -v minui-presenter >/dev/null 2>&1; }
UI_PID=""
ui_hold(){
	if have_ui; then
		killall minui-presenter >/dev/null 2>&1
		minui-presenter --message "$1" --timeout -1 >/dev/null 2>&1 &
		UI_PID=$!
	fi
	log "MSG: $1"
}
ui_stop(){ [ -n "$UI_PID" ] && kill "$UI_PID" >/dev/null 2>&1; killall minui-presenter >/dev/null 2>&1; UI_PID=""; }
# Terminal states must never flash past unread — A/B ack via minui-list (the Update pak's
# ui_sticky pattern), degrading to a long presenter flash, then to log-only.
ui_sticky(){
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
ui_hold "Resetting Wi-Fi..."
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
ui_hold "Reconnecting Wi-Fi..."
rm -f /tmp/rw-rc 2>/dev/null
( if wifi_acquire fg; then echo 0 > /tmp/rw-rc; else echo $? > /tmp/rw-rc; fi ) &
APID=$!
_last=""
while kill -0 "$APID" 2>/dev/null; do
	ph="$(cat /tmp/romm-phase 2>/dev/null)"
	if [ -n "$ph" ] && [ "$ph" != "$_last" ]; then _last="$ph"; ui_hold "$ph"; fi
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
