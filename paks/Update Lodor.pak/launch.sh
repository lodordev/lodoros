#!/bin/sh
# "Update Lodor.pak" — explicit self-update for LodorOS (the lane with no store): check,
# download + sha256-verify, STAGE for the boot applier. Opening this pak IS the user's
# confirmation — nothing here runs unattended, and nothing is applied while the system is
# live: the verified tree waits in Lodor.pak/.update until the next boot swaps it in.
#
# Honest at every step — no fake progress: the download bar is driven ONLY by the engine's
# real byte-percent side-channel (/tmp/dl-progress + /tmp/romm-phase), the same one the
# mirror/download-queue paths feed. Every terminal state is EXPLICIT and STICKY so the pak
# can never look like "nothing happened":
#   up-to-date  -> "You're on the latest version" (dismiss to exit)
#   staged      -> "Downloaded <v> — reboot now to install" + a Reboot/Later choice
#   unreachable -> "Couldn't reach the update server — check Wi-Fi" (distinct, not silence)
set -u
PAKDIR="$(dirname "$0")"
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-miyoomini}"
LODOR="$(dirname "$PAKDIR")/Lodor.pak"
LOG="$LODOR/update.log"

cd "$LODOR" || exit 1
. "$LODOR/lib/romm-sync-lib.sh"
[ -f "$LODOR/lib/tailscale-lib.sh" ] && . "$LODOR/lib/tailscale-lib.sh"

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

# --- on-screen UI (minui-presenter / minui-list) -----------------------------------
# say.elf is log-only on miyoomini (it leaves the framebuffer black — see the lib), which is
# exactly why this pak used to look blank. Borrow the proven minui-presenter/minui-list from
# the always-present Wi-Fi pak (per-platform bins) — the same tools Tailscale.pak drives — so
# every state is actually drawn on-screen. If they're missing we degrade to say() (log-only)
# so the pak still stages correctly and never bricks; it just won't be visible.
arch=arm; uname -m 2>/dev/null | grep -q 64 && arch=arm64
export PATH="$SDCARD/Tools/$PLAT/Wifi.pak/bin/$PLAT:$SDCARD/Tools/$PLAT/Wifi.pak/bin/$arch:$PATH"
have_ui(){ command -v minui-presenter >/dev/null 2>&1; }

# ui_flash <msg> [secs] — a timed on-screen line (auto-dismisses). Used for transient steps.
ui_flash(){
	if have_ui; then
		killall minui-presenter >/dev/null 2>&1
		minui-presenter --message "$1" --timeout "${2:-3}" >/dev/null 2>&1
	else
		say "$1"; sleep "${2:-3}"; clear_say
	fi
}
# ui_hold <msg> — draw a line that PERSISTS until replaced/killed (for in-progress phases).
UI_PID=""
ui_hold(){
	if have_ui; then
		killall minui-presenter >/dev/null 2>&1
		minui-presenter --message "$1" --timeout -1 >/dev/null 2>&1 &
		UI_PID=$!
	else
		say "$1"
	fi
}
ui_stop(){ [ -n "$UI_PID" ] && kill "$UI_PID" >/dev/null 2>&1; killall minui-presenter >/dev/null 2>&1; UI_PID=""; clear_say; }
# ui_sticky <msg> — a terminal message the user must acknowledge (A/B) so it can never flash
# past. Falls back to a long flash if minui-list is unavailable.
ui_sticky(){
	if have_ui && command -v minui-list >/dev/null 2>&1; then
		killall minui-presenter >/dev/null 2>&1
		printf 'OK\n' > /tmp/upd-ack
		minui-list --disable-auto-sleep --file /tmp/upd-ack --format text \
			--title "$1" --confirm-text "OK" --cancel-text "OK" \
			--write-location /tmp/upd-ack-out >/dev/null 2>&1
		rm -f /tmp/upd-ack /tmp/upd-ack-out 2>/dev/null
	else
		ui_flash "$1" 6
	fi
}

trap 'ui_stop; wifi_release' EXIT INT TERM HUP QUIT

# offer_reboot <headline> — the staged terminal state. Presents "Reboot now / Later" so the
# "reboot to apply" instruction can never flash past unread. Reboot mirrors Reboot.pak's proven
# sequence (sync first; busybox reboot -> sysrq -> poweroff fallback). "Later" just exits; the
# boot applier picks the staged tree up on the next real reboot regardless.
offer_reboot(){
	if have_ui && command -v minui-list >/dev/null 2>&1; then
		killall minui-presenter >/dev/null 2>&1
		printf 'Reboot now\nLater\n' > /tmp/upd-reboot
		minui-list --disable-auto-sleep --file /tmp/upd-reboot --format text \
			--title "$1 Reboot to install it." --confirm-text "SELECT" --cancel-text "LATER" \
			--write-location /tmp/upd-reboot-out >/dev/null 2>&1
		_rc=$?
		_sel="$(cat /tmp/upd-reboot-out 2>/dev/null)"
		rm -f /tmp/upd-reboot /tmp/upd-reboot-out 2>/dev/null
		if [ "$_rc" = 0 ] && [ "$_sel" = "Reboot now" ]; then
			log "user chose Reboot now — applying staged update"
			wifi_release
			ui_flash "Rebooting to install..." 2
			sync; sync
			reboot 2>/dev/null; sleep 3
			/sbin/reboot -f 2>/dev/null; sleep 2
			poweroff -f 2>/dev/null
		else
			log "user chose Later — staged tree waits for next boot"
		fi
	else
		ui_flash "$1 Reboot to install it." 6
	fi
}

[ -x "$SYNC_BIN" ] || { ui_flash "Update: the sync engine is missing." 4; exit 1; }

# Already staged from a prior run: don't re-download, just tell them (sticky) and offer a reboot.
if [ -f "$LODOR/.update/READY" ]; then
	_sv="$(get_setting update_staged)"; [ -n "$_sv" ] || _sv="An update"
	_sn="$(head -n1 "$LODOR/update-notes.txt" 2>/dev/null)"   # #8: replay the changelog with the reboot offer
	offer_reboot "$_sv is downloaded and ready.${_sn:+ New: $_sn}"
	exit 0
fi

ui_hold "Connecting to Wi-Fi..."
if ! wifi_acquire; then ui_sticky "Couldn't reach the update server — check Wi-Fi."; exit 1; fi
set_clock || log "clock set failed - continuing"

ui_hold "Checking for updates..."
OUT="$("$SYNC_BIN" --check-update 2>>"$LOG")"; RC=$?
log "check-update rc=$RC: $OUT"
if [ "$RC" != 0 ]; then
	# exit 3 = manifest unreachable/unusable. DISTINCT, sticky message — never a silent exit
	# that reads as "nothing happened".
	ui_sticky "Couldn't reach the update server — check Wi-Fi and try again."
	exit 1
fi
set_setting update_last_check "$(date +%s)"
LATEST="$(result_tok "$OUT" latest)"
CURRENT="$(result_tok "$OUT" current)"
if [ "$(result_tok "$OUT" update)" != "1" ]; then
	set_setting update_available ""
	ui_sticky "You're on the latest version ($CURRENT)."
	exit 0
fi
set_setting update_available "$LATEST"
# #8: the engine emits a single-line changelog trailer (NOTES\t<line>) when the channel
# carries notes. Capture it for the pre-download message and the reboot offer, and persist
# it to its OWN file (temp+mv) so the already-staged path can replay it. NOT set_setting:
# settings.conf is dot-SOURCED by the lib, so free text there would be EXECUTED as shell.
_TAB="$(printf '\t')"
NOTES="$(printf '%s\n' "$OUT" | sed -n "s/^NOTES${_TAB}//p" | head -1)"
if [ -n "$NOTES" ]; then
	printf '%s\n' "$NOTES" > "$LODOR/update-notes.txt.tmp.$$" 2>/dev/null \
		&& mv -f "$LODOR/update-notes.txt.tmp.$$" "$LODOR/update-notes.txt" 2>/dev/null
	rm -f "$LODOR/update-notes.txt.tmp.$$" 2>/dev/null
fi

# --- preflight (#9): card space + charge state, BEFORE any bytes move ---------------
# The applier needs the zip AND the unpacked staged tree on the card at once (~2x the
# download), so gate on a sane floor — --check-update doesn't expose the asset size.
# Honest copy on ENOSPC; unparseable df output never blocks (we can't claim a problem we
# didn't verify).
UPDATE_SPACE_FLOOR_KB=102400   # 100 MB
free_card_kb(){ df -k "$SDCARD" 2>/dev/null | tail -1 | awk '{print $(NF-2)}'; }
_free_kb="$(free_card_kb)"
case "$_free_kb" in ''|*[!0-9]*) _free_kb="" ;; esac
if [ -n "$_free_kb" ] && [ "$_free_kb" -lt "$UPDATE_SPACE_FLOOR_KB" ]; then
	_need_mb=$(( (UPDATE_SPACE_FLOOR_KB - _free_kb) / 1024 + 1 ))
	log "preflight ENOSPC: free=${_free_kb}KB < floor=${UPDATE_SPACE_FLOOR_KB}KB"
	ui_sticky "Not enough card space — free up ~${_need_mb} MB and retry."
	exit 1
fi
# Charging (#9): warn but never hard-block (the user may know their battery better). Only
# when the charge line is actually READABLE here (miyoomini AXP/gpio — what is_charging
# reads); elsewhere we can't tell, and a false "not charging" tip would be a lie.
if [ -x /customer/app/axp_test ] || [ -f /sys/devices/gpiochip0/gpio/gpio59/value ]; then
	if ! is_charging; then
		log "preflight: not charging — warned, continuing"
		ui_flash "Tip: plug in before updating." 4
	fi
fi

# --- download with a REAL, engine-driven progress bar ------------------------------
# Run --fetch-update in the background and mirror the engine's HONEST side-channel to the
# screen: numeric /tmp/dl-progress is the byte-percent bar; /tmp/romm-phase is the phase
# label ("Downloading update…", "Verifying update…"). We invent NO forward progress — when
# the engine hasn't written a number yet we show its phase text only. (This is the same
# bridge the NextUI pre-launch fetch hook uses, adapted to minui-presenter.)
rm -f /tmp/dl-progress /tmp/romm-phase 2>/dev/null
# #8: the pre-download line carries the changelog — this is the consent moment for the bytes.
ui_hold "Downloading Lodor $LATEST...${NOTES:+
New: $NOTES}"
( LODOR_UPDATE_ASSET="lodoros-$PLAT" "$SYNC_BIN" --fetch-update >/tmp/upd-fetch-out 2>>"$LOG"; echo $? > /tmp/upd-fetch-rc ) &
DLPID=$!
_lastline=""
while kill -0 "$DLPID" 2>/dev/null; do
	pct=""; [ -f /tmp/dl-progress ] && pct="$(cat /tmp/dl-progress 2>/dev/null)"
	ph=""; [ -f /tmp/romm-phase ] && ph="$(cat /tmp/romm-phase 2>/dev/null)"
	[ -n "$ph" ] || ph="Downloading Lodor $LATEST..."
	case "$pct" in
		''|*[!0-9]*) line="$ph" ;;
		*)           line="$ph  ${pct}%" ;;
	esac
	if [ "$line" != "$_lastline" ]; then _lastline="$line"; ui_hold "$line"; fi
	sleep 1
done
wait "$DLPID" 2>/dev/null
FRC="$(cat /tmp/upd-fetch-rc 2>/dev/null)"
case "$FRC" in ''|*[!0-9]*) FRC=1 ;; esac   # missing/garbled rc => treat as a failure, never a false "staged"
FOUT="$(cat /tmp/upd-fetch-out 2>/dev/null)"
rm -f /tmp/dl-progress /tmp/romm-phase /tmp/upd-fetch-out /tmp/upd-fetch-rc 2>/dev/null
log "fetch-update rc=$FRC: $FOUT"
ui_stop
wifi_release
case "$FRC" in
	0)
		set_setting update_staged "$LATEST"
		offer_reboot "Downloaded Lodor $LATEST.${NOTES:+ New: $NOTES}" ;;
	4)
		ui_sticky "Download didn't verify — nothing changed. Try again." ;;
	*)
		# #9: a full card fails staging with the SAME engine rc (3) as a dead network — but
		# the card itself tells the truth: the engine's ENOSPC stderr is in update.log and
		# df shows the squeeze. Distinguish where detectable; honest generic copy otherwise.
		_free_kb="$(free_card_kb)"
		case "$_free_kb" in ''|*[!0-9]*) _free_kb="" ;; esac
		if tail -4 "$LOG" 2>/dev/null | grep -qi "no space left" || { [ -n "$_free_kb" ] && [ "$_free_kb" -lt "$UPDATE_SPACE_FLOOR_KB" ]; }; then
			_need_mb=$(( (UPDATE_SPACE_FLOOR_KB - ${_free_kb:-0}) / 1024 + 1 ))
			ui_sticky "Download failed — not enough card space. Free up ~${_need_mb} MB and retry."
		else
			ui_sticky "Download failed — check your connection and try again."
		fi ;;
esac
exit 0
