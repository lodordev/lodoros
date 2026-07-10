#!/bin/sh
# Tailscale.pak — on-device Tailscale maintenance for LodorOS (Tailscale-capable devices).
# Status / Reset & forget / Turn off. Sign-in itself lives in the launcher's QR onboarding
# (Sync -> Re-connect RomM -> Tailscale); this pak is the recovery tool for a flaky/wedged
# node -- "Reset & forget" wipes the saved login so the next onboard is completely fresh.
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"; PAK_NAME="${PAK_NAME%.*}"
cd "$PAK_DIR" || exit 1
[ -n "$LOGS_PATH" ] && { rm -f "$LOGS_PATH/$PAK_NAME.txt"; exec >>"$LOGS_PATH/$PAK_NAME.txt" 2>&1; }

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-rg35xxplus}"
LODOR_PAK="$SDCARD/Tools/$PLAT/Lodor.pak"

# Borrow minui-list / minui-presenter from the always-present Wi-Fi pak (per-platform bins).
arch=arm; uname -m 2>/dev/null | grep -q 64 && arch=arm64
export PATH="$SDCARD/Tools/$PLAT/Wifi.pak/bin/$PLAT:$SDCARD/Tools/$PLAT/Wifi.pak/bin/$arch:$PATH"
have_ui() { command -v minui-list >/dev/null 2>&1 && command -v minui-presenter >/dev/null 2>&1; }
say_msg() { minui-presenter --message "$1" --timeout "${2:-3}" 2>/dev/null; }

# Only the Tailscale-eligible platforms (mirrors _ts_capable) get this maintenance pak. On
# the others: say so in ONE line (#16) — minui-presenter is the proven on-screen path on
# every LodorOS platform (Update Lodor.pak drives it on the miyoomini; the framebuffer
# caveat in the lib is about say.elf) — and log it either way. Never a bare exit 0 with UI
# available.
case "$PLAT" in
	my355|tg5040|rg35xxplus) : ;;
	*)
		echo "$(date +'%F %T') platform $PLAT is not Tailscale-eligible — nothing to manage"
		have_ui && say_msg "Tailscale isn't available on this device." 4
		exit 0 ;;
esac

# tailscale-lib.sh keys off ROMM_PAK_DIR / SDCARD / PLAT.
ROMM_PAK_DIR="$LODOR_PAK"; export ROMM_PAK_DIR SDCARD PLAT
. "$LODOR_PAK/lib/romm-sync-lib.sh" 2>/dev/null
. "$LODOR_PAK/lib/tailscale-lib.sh" 2>/dev/null

# Not a Tailscale build (or lib missing) -> say so and leave.
if ! command -v tailscale_status >/dev/null 2>&1; then
	have_ui && say_msg "Tailscale is not available on this device." 4
	exit 0
fi
# No on-screen UI available -> NO-OP (#10). This used to run ts_reset, wiping a healthy
# node's saved sign-in just because the menu binaries were missing — destructive by
# default. Recovery actions now require the menu; headless we only log and leave.
if ! have_ui; then
	echo "$(date +'%F %T') no UI (minui-list/minui-presenter missing) — no action taken; ts_reset NOT run"
	exit 0
fi

while true; do
	printf 'Reconnect\nStatus\nReset & forget\nTurn off\n' > /tmp/ts-menu
	killall minui-presenter >/dev/null 2>&1 || true
	minui-list --disable-auto-sleep --file /tmp/ts-menu --format text \
		--title "Tailscale" --confirm-text "SELECT" --cancel-text "EXIT" \
		--write-location /tmp/ts-out
	[ $? -ne 0 ] && break                       # B / EXIT
	sel="$(cat /tmp/ts-out 2>/dev/null)"
	case "$sel" in
		Reconnect)
			# Restart tailscaled from the PERSISTED login (task #134). No QR, no re-auth,
			# RomM pairing untouched — only "Reset & forget" ever wipes the sign-in.
			# The presenter line below is TRUE while it shows: the reconnect is running
			# underneath it (worst case ~45s: socket wait + Running poll).
			if ! command -v tailscale_reconnect >/dev/null 2>&1; then
				say_msg "This build can't reconnect (lib too old).

Use Turn off, then Sync -> Re-connect RomM." 6
				continue
			fi
			killall minui-presenter >/dev/null 2>&1 || true
			minui-presenter --message "Reconnecting Tailscale..." --timeout 60 2>/dev/null &
			_res="$(tailscale_reconnect 2>/dev/null)"
			killall minui-presenter >/dev/null 2>&1 || true
			case "$_res" in
				connected:*) say_msg "Reconnected (${_res#connected:})" 5 ;;
				connected)   say_msg "Reconnected." 5 ;;
				no-login)    say_msg "No saved Tailscale sign-in.

Sign in via Sync -> Re-connect RomM -> Tailscale." 6 ;;
				not-capable|no-binary) say_msg "Tailscale is not available on this device." 5 ;;
				*)           say_msg "Couldn't reconnect - Tailscale didn't reach Running.

Check Wi-Fi. Details: tailscaled.log" 6 ;;
			esac ;;
		Status)
			if [ "$(tailscale_status 2>/dev/null)" = "connected" ]; then
				ip="$("$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" ip -4 2>/dev/null | head -1)"
				say_msg "Tailscale: CONNECTED${ip:+
$ip}" 5
			else
				say_msg "Tailscale: not connected.

Sign in via Sync -> Re-connect RomM -> Tailscale." 6
			fi ;;
		"Reset & forget")
			say_msg "Resetting Tailscale..." 1
			ts_reset 2>/dev/null
			say_msg "Tailscale reset.

Re-onboard: Sync -> Re-connect RomM -> Tailscale." 6 ;;
		"Turn off")
			tailscale_down 2>/dev/null
			say_msg "Tailscale turned off.

Using Cloudflare / LAN until you sign in again." 6 ;;
	esac
done
exit 0
