#!/bin/sh
# "Update Lodor.pak" — explicit self-update for LodorOS (the lane with no store): check,
# download + sha256-verify, STAGE for the boot applier. Opening this pak IS the user's
# confirmation — nothing here runs unattended, and nothing is applied while the system is
# live: the verified tree waits in Lodor.pak/.update until the next boot swaps it in.
# Honest at every step (real engine RESULT lines, no fake progress).
set -u
PAKDIR="$(dirname "$0")"
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-miyoomini}"
LODOR="$(dirname "$PAKDIR")/Lodor.pak"
LOG="$LODOR/update.log"

cd "$LODOR" || exit 1
. "$LODOR/lib/romm-sync-lib.sh"
[ -f "$LODOR/lib/tailscale-lib.sh" ] && . "$LODOR/lib/tailscale-lib.sh"
trap 'clear_say; wifi_release' EXIT INT TERM HUP QUIT

log(){ echo "$(date '+%F %T') $1" >> "$LOG"; }
SETTINGS="$LODOR/settings.conf"
get_setting(){ sed -n "s/^$1=//p" "$SETTINGS" 2>/dev/null | head -1; }
set_setting(){
	_t="$SETTINGS.tmp.$$"
	{ [ -f "$SETTINGS" ] && grep -v "^$1=" "$SETTINGS" 2>/dev/null; echo "$1=$2"; } > "$_t" 2>/dev/null \
		&& mv -f "$_t" "$SETTINGS" 2>/dev/null
	rm -f "$_t" 2>/dev/null
}
result_tok(){ printf '%s\n' "$1" | sed -n "s/.*$2=\([^ ]*\).*/\1/p" | head -1; }

[ -x "$SYNC_BIN" ] || { say "Sync binary missing"; sleep 2; exit 1; }

if [ -f "$LODOR/.update/READY" ]; then
	say "An update is already staged - reboot to apply it"
	sleep 3; exit 0
fi

say "Update: connecting..."
if ! wifi_acquire; then say "WiFi unavailable"; sleep 2; exit 1; fi
set_clock || log "clock set failed - continuing"

say "Checking for updates..."
OUT="$("$SYNC_BIN" --check-update 2>>"$LOG")"; RC=$?
log "check-update rc=$RC: $OUT"
if [ "$RC" != 0 ]; then
	say "Couldn't reach the update server (needs internet)"
	sleep 3; exit 1
fi
set_setting update_last_check "$(date +%s)"
LATEST="$(result_tok "$OUT" latest)"
CURRENT="$(result_tok "$OUT" current)"
if [ "$(result_tok "$OUT" update)" != "1" ]; then
	set_setting update_available ""
	say "You're up to date ($CURRENT)"
	sleep 3; exit 0
fi
set_setting update_available "$LATEST"

say "Downloading Lodor $LATEST..."
FOUT="$(LODOR_UPDATE_ASSET="lodoros-$PLAT" "$SYNC_BIN" --fetch-update 2>>"$LOG")"; FRC=$?
log "fetch-update rc=$FRC: $FOUT"
case "$FRC" in
	0)
		set_setting update_staged "$LATEST"
		say "Update $LATEST staged - it installs at the next reboot"
		sleep 4 ;;
	4)
		say "Download didn't verify - nothing was changed. Try again."
		sleep 4; exit 4 ;;
	*)
		say "Download failed - check the connection and try again"
		sleep 4; exit "$FRC" ;;
esac
exit 0
