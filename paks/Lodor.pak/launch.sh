#!/bin/sh
# RomM "Sync Now" — manual, full WiFi-dark save sync. Thin caller over romm-sync-lib.sh.
# Radio comes up only for the sync and is always powered back down (trap), even on failure.

set -u
PAKDIR="$(dirname "$0")"
cd "$PAKDIR" || exit 1

LOG="$PAKDIR/last-sync.log"
WIFI_LOG="$LOG"
: > "$LOG"

. "$PAKDIR/lib/romm-sync-lib.sh"
# tier-1 (Tailscale) overlay — capability-gated, non-fatal; absent on miyoomini.
[ -f "$PAKDIR/lib/tailscale-lib.sh" ] && . "$PAKDIR/lib/tailscale-lib.sh"

trap 'clear_say; command -v tailscale_down >/dev/null 2>&1 && tailscale_down; wifi_release' EXIT INT TERM HUP QUIT

log()    { echo "$1" >> "$LOG"; }
status() { log "$1"; say "$1"; }

[ -x "$SYNC_BIN" ]              || { say "Sync binary missing"; sleep 2; exit 1; }
[ -x "$WIFI_BIN/service-on" ]   || { say "Wifi.pak not installed"; sleep 2; exit 1; }
[ -f "$ROMM_PAK_DIR/config.json" ] || { say "RomM not paired"; sleep 2; exit 1; }

status "RomM: connecting..."
if ! wifi_acquire; then status "RomM: WiFi unavailable"; sleep 2; exit 1; fi

# Tier-1: bring up userspace Tailscale so the engine can socks5h-dial the .ts.net
# RomM host. Non-fatal — on a skipped/incapable device, or if tailscaled does not
# come up, the engine's tier probe fails and it syncs over the tier-2 CF path.
# Logs ONLY on success, so a skipped/incapable device (miyoomini) leaves last-sync.log
# byte-identical — failure detail lives in the lib's own tailscaled.log on capable devices.
if command -v tailscale_up >/dev/null 2>&1 && tailscale_up; then
	log "tier-1: Tailscale up"
fi

status "RomM: setting clock..."
set_clock || log "clock set failed - continuing"

status "RomM: syncing..."
rc=1
attempt=1
while [ "$attempt" -le 3 ]; do
	run_sync >> "$LOG" 2>&1
	rc=$?
	[ "$rc" -eq 3 ] || break
	status "RomM: unreachable, retry $attempt..."
	attempt=$((attempt + 1))
	sleep 3
done

case "$rc" in
	0) date +%s > /tmp/romm-last-full-sync 2>/dev/null   # full sync: lets session pulls skip
	   status "RomM: sync complete" ;;
	2) status "RomM: not configured" ;;
	3) status "RomM: server unreachable" ;;
	4) status "RomM: finished with errors" ;;
	*) status "RomM: failed ($rc)" ;;
esac

sleep 2
exit "$rc"
# trap powers WiFi back down + clears the message.
