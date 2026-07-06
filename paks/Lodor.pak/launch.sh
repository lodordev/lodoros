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

# One-time post-update announcement (the boot applier leaves the marker; honest, then gone).
if [ -f "$PAKDIR/.update-applied" ]; then
	say "Lodor updated to $(cat "$PAKDIR/.update-applied" 2>/dev/null)"
	rm -f "$PAKDIR/.update-applied"
	sleep 3
fi

# ---- self-update check (bespoke lane: LodorOS has no store) --------------------------------
# Opportunistic tail of a GOOD sync: the radio is already up, so the manifest GET is nearly
# free. At most once a day; every failure is silent. Staging/applying is NEVER automatic —
# that is the explicit "Update Lodor" pak + the boot applier.
SETTINGS="$PAKDIR/settings.conf"
get_setting(){ sed -n "s/^$1=//p" "$SETTINGS" 2>/dev/null | head -1; }
set_setting(){
	_t="$SETTINGS.tmp.$$"
	{ [ -f "$SETTINGS" ] && grep -v "^$1=" "$SETTINGS" 2>/dev/null; echo "$1=$2"; } > "$_t" 2>/dev/null \
		&& mv -f "$_t" "$SETTINGS" 2>/dev/null
	rm -f "$_t" 2>/dev/null
}
maybe_check_update() {
	_l="$(get_setting update_last_check)"; case "$_l" in ''|*[!0-9]*) _l=0 ;; esac
	[ $(( $(date +%s) - _l )) -lt 86400 ] && return 0
	_o="$("$SYNC_BIN" --check-update 2>>"$LOG")" || return 0
	log "check-update: $_o"
	set_setting update_last_check "$(date +%s)"
	_lat="$(printf '%s\n' "$_o" | sed -n 's/.*latest=\([^ ]*\).*/\1/p' | head -1)"
	case "$_o" in
		*"update=1"*)
			set_setting update_available "$_lat"
			status "Lodor $_lat available - run Update Lodor in Tools"
			sleep 3 ;;
		*)  set_setting update_available "" ;;
	esac
	return 0
}

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
	   status "RomM: sync complete"
	   maybe_check_update ;;
	2) status "RomM: not configured" ;;
	3) status "RomM: server unreachable" ;;
	4) status "RomM: finished with errors" ;;
	*) status "RomM: failed ($rc)" ;;
esac

sleep 2
exit "$rc"
# trap powers WiFi back down + clears the message.
