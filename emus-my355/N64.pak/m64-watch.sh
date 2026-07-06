#!/bin/sh
# m64-watch.sh — LodorOS sidecar watcher for the STANDALONE mupen64plus pak (my355 / Miyoo Flip).
#
# WHY THIS EXISTS: on MinUI-family firmware, lid/sleep handling is not a system service — it
# lives inside the foreground process's input loop (PAD_poll synthesizes BTN_SLEEP from the
# hall sensor; PWR_update acts on it). minui and minarch both run that loop; a standalone
# emulator runs NONE of it, so a closed lid left N64 games running (2026-07-06 Flip field
# report). This sidecar restores the device's contracts for the standalone case:
#
#   lid closed              -> freeze the emulator (SIGSTOP) + backlight off
#   lid reopened            -> backlight on + resume (SIGCONT)
#   lid closed >= 120s      -> clean quit (SIGCONT+SIGTERM so the pak wrapper's trap can
#                              push saves) — mirrors minarch's sleep-then-exit philosophy
#   MENU held >= 2s         -> clean quit (same path). A MENU *tap* is deliberately left to
#                              the emulator, which maps it to pause (launch.real.sh --set:
#                              the Flip's MENU key is KEY_ESC on event0 — the same keycode
#                              keymon watches — and mupen ignores SDL key repeats, so a hold
#                              pauses once, then quits here).
#
# Paths/tunables are env-overridable ONLY so the off-device test rig can simulate the
# sysfs/evdev endpoints — on-device every default is correct for my355.
set -u

EMU="${1:?usage: m64-watch.sh <emulator-pid>}"
HALL="${M64W_HALL:-/sys/devices/platform/hall-mh248/hallvalue}"  # 1 = open, 0 = closed
BLANK="${M64W_BLANK:-/sys/class/backlight/backlight/bl_power}"   # 0 = wake, 4 = powerdown (FB_BLANK_*)
EVDEV="${M64W_EVDEV:-/dev/input/event0}"                         # keymon's device: MENU = code 1 (KEY_ESC)
EVTEST="${M64W_EVTEST:-$(dirname "$0")/my355/evtest}"                # launch.real.sh passes \$BIN_DIR/evtest
POLL="${M64W_POLL:-0.5}"
LID_EXIT_SECS="${M64W_LID_EXIT_SECS:-120}"
MENU_HOLD_SECS="${M64W_MENU_HOLD_SECS:-2}"

alive() { kill -0 "$EMU" 2>/dev/null; }
bl()    { echo "$1" > "$BLANK" 2>/dev/null; }
# Quit is always CONT-then-TERM: a SIGSTOPped emulator cannot handle SIGTERM, and the pak
# wrapper's save-push trap only runs off a live process's clean exit.
quit_emu() { kill -CONT "$EMU" 2>/dev/null; kill -TERM "$EMU" 2>/dev/null; }

# State + cleanup are declared BEFORE anything can spawn or freeze: the parent launch
# script TERMs this watcher on emulator exit, and dying mid-freeze must never leave a
# dark screen, a SIGSTOPped emulator, or an orphaned evtest/FIFO behind.
frozen=0
EVT_PID=""
RD_PID=""
EVFIFO=""
cleanup() {
	if [ "$frozen" = "1" ]; then
		bl 0
		kill -CONT "$EMU" 2>/dev/null
		frozen=0
	fi
	[ -n "$EVT_PID" ] && kill "$EVT_PID" 2>/dev/null
	[ -n "$RD_PID" ]  && kill "$RD_PID"  2>/dev/null
	[ -n "$EVFIFO" ]  && rm -f "$EVFIFO"
}
trap 'cleanup; exit 0' TERM INT

# ── MENU long-press watcher (background, via FIFO — both PIDs directly killable) ────────
# evtest (NOT --grab: the tap must still reach SDL/mupen for pause) prints one line per key
# event; we track KEY_ESC down->repeat spans. Seconds granularity is fine for a 2s hold.
# A FIFO instead of a pipeline so cleanup can kill evtest BY PID — killing a pipeline's
# tail orphans its upstream (proven in the off-device rig), and a name-based killall is
# blind to anything exec'd under another name.
if [ -x "$EVTEST" ] && [ -e "$EVDEV" ]; then
	EVFIFO="/tmp/m64-watch.$$.fifo"
	rm -f "$EVFIFO"
	if mkfifo "$EVFIFO" 2>/dev/null; then
		"$EVTEST" "$EVDEV" > "$EVFIFO" 2>/dev/null &
		EVT_PID=$!
		(
			t0=""
			while IFS= read -r line; do
				case "$line" in
					*"code 1 ("*"), value 1"*) t0=$(date +%s) ;;
					*"code 1 ("*"), value 0"*) t0="" ;;
					*"code 1 ("*"), value 2"*)
						[ -n "$t0" ] || continue
						if [ $(( $(date +%s) - t0 )) -ge "$MENU_HOLD_SECS" ]; then
							kill -CONT "$EMU" 2>/dev/null
							kill -TERM "$EMU" 2>/dev/null
							break
						fi ;;
				esac
			done < "$EVFIFO"
		) &
		RD_PID=$!
	fi
fi

# ── Lid loop (foreground) ────────────────────────────────────────────────────────────────
closed_at=""
while alive; do
	lid=$(cat "$HALL" 2>/dev/null || echo 1)
	if [ "$lid" = "0" ]; then
		if [ "$frozen" = "0" ]; then
			frozen=1
			closed_at=$(date +%s)
			kill -STOP "$EMU" 2>/dev/null
			bl 4
		elif [ -n "$closed_at" ] && [ $(( $(date +%s) - closed_at )) -ge "$LID_EXIT_SECS" ]; then
			bl 0
			quit_emu
			frozen=0
			break
		fi
	else
		if [ "$frozen" = "1" ]; then
			frozen=0
			closed_at=""
			bl 0
			kill -CONT "$EMU" 2>/dev/null
		fi
	fi
	sleep "$POLL"
done

# Never leave the screen dark, a frozen process, or an orphaned evtest behind.
cleanup
exit 0
