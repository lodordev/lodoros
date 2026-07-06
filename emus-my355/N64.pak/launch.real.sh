#!/bin/sh
# LodorOS heavy-pak launch.real.sh — STANDALONE mupen64plus (+GLideN64/Rice).
# Invoked by launch.sh (ROMM_STANDALONE_PAK_WRAPPER) which owns RomM save-sync.
# Self-contained: every non-base shared lib is vendored under $BIN_DIR; only glibc
# base + the device GPU driver (libEGL/libGLESv2/libgbm/libmali) come from the device.
set -u

PAK_DIR="$(dirname "$0")"
EMU_TAG="$(basename "$PAK_DIR")"; EMU_TAG="${EMU_TAG%.*}"     # "N64"
PLAT="${PLATFORM:-$(basename "$(dirname "$PAK_DIR")")}"
BIN_DIR="$PAK_DIR/$PLAT"
ROM="$1"

# ── Paths (fall back defensively for direct invocation) ──────────────────────
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
SAVES="${SAVES_PATH:-$SDCARD/Saves}"
LOGS="${LOGS_PATH:-$SDCARD/Logs}"
USERDATA="${USERDATA_PATH:-$SDCARD/.userdata/$PLAT}"
CFG_DIR="$USERDATA/$EMU_TAG-mupen64plus"
SAVE_DIR="$SAVES/N64"
STATE_DIR="${SHARED_USERDATA_PATH:-$SDCARD/.userdata/shared}/$EMU_TAG-mupen64plus"
mkdir -p "$CFG_DIR" "$SAVE_DIR" "$STATE_DIR" "$LOGS"

LOG="$LOGS/$EMU_TAG.txt"; rm -f "$LOG"; exec >>"$LOG" 2>&1
set -x

# First run: seed config from the pak's GL-default (VideoPlugin=0 -> GLideN64).
if [ ! -f "$CFG_DIR/.initialized" ]; then
    cp "$BIN_DIR/default.cfg" "$CFG_DIR/mupen64plus.cfg" 2>/dev/null
    touch "$CFG_DIR/.initialized"
fi

# Resolution: device sysfs if readable, else a safe 640x480 default.
SCREEN_W=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | cut -d, -f1)
SCREEN_H=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | cut -d, -f2)
[ -n "${SCREEN_W:-}" ] || SCREEN_W=640
[ -n "${SCREEN_H:-}" ] || SCREEN_H=480

export HOME="$USERDATA"
export XDG_DATA_HOME="$CFG_DIR"
# Vendored closure first, then LodorOS system libs, then the device GPU-driver dir.
M64P_LDP="$BIN_DIR:$SDCARD/.system/$PLAT/lib:${LD_LIBRARY_PATH:-}"
M64P_PRELOAD="libEGL.so"

cd "$BIN_DIR"
# ── Clock contract (2026-07-06 Flip fix, round 2) ────────────────────────────
# my355 runs a `userspace` cpufreq governor: the FRONTEND pins the clock. minui
# parks menus at 600 MHz and it is MINARCH that raises it for a game — so a
# standalone emulator inherited menu clock and N64 ran the whole session at
# 600 MHz ("very very laggy"). Pin PERFORMANCE (same value as minarch's
# CPU_SPEED_PERFORMANCE on this platform) for the emulator; restore menu clock
# on every exit path so minui gets back the state it expects.
CPUFREQ_GOV="${M64_CPUFREQ_GOV:-/sys/devices/system/cpu/cpufreq/policy0/scaling_governor}"
CPUFREQ_SET="${M64_CPUFREQ_SET:-/sys/devices/system/cpu/cpufreq/policy0/scaling_setspeed}"
CPU_GAME_KHZ=1992000
CPU_MENU_KHZ=600000
echo userspace > "$CPUFREQ_GOV" 2>/dev/null
echo "$CPU_GAME_KHZ" > "$CPUFREQ_SET" 2>/dev/null

# ── Input contract (2026-07-06 Flip fix) ─────────────────────────────────────
# The Flip's MENU key is KEY_ESC on event0 (same code keymon watches). Stock
# CoreEvents binds Escape=Stop, so MENU instantly quit the game mid-play (it
# looked like a crash; N64.txt showed a clean "Stopping emulation" + rc=0).
# --set every launch (not a cfg edit) so already-seeded user configs are
# overridden too:  MENU tap = pause toggle; quit moved to the sidecar below.
# ── Lid contract ─────────────────────────────────────────────────────────────
# Lid/sleep lives in minui/minarch's input loop, which a standalone emulator
# never runs — m64-watch.sh restores it (freeze+screen-off on close, resume on
# open, clean quit on 120s-closed or a 2s MENU hold). Watcher failure can never
# block the game: it's optional, backgrounded, and reaped on every exit path.
WATCH="$PAK_DIR/m64-watch.sh"
env LD_LIBRARY_PATH="$M64P_LDP" LD_PRELOAD="$M64P_PRELOAD" \
    ./mupen64plus --fullscreen --resolution "${SCREEN_W}x${SCREEN_H}" \
    --configdir "$CFG_DIR" --datadir "$BIN_DIR" --plugindir "$BIN_DIR" \
    --set "Core[SaveSRAMPath]=$SAVE_DIR/" \
    --set "Core[SaveStatePath]=$STATE_DIR/" \
    --set "CoreEvents[Kbd Mapping Stop]=0" \
    --set "CoreEvents[Kbd Mapping Pause]=27" \
    --gfx "$BIN_DIR/mupen64plus-video-GLideN64.so" \
    --audio "$BIN_DIR/mupen64plus-audio-sdl.so" \
    --input "$BIN_DIR/mupen64plus-input-sdl.so" \
    --rsp "$BIN_DIR/mupen64plus-rsp-hle.so" \
    "$ROM" &
EMU_PID=$!
WATCH_PID=""
if [ -x "$WATCH" ] || [ -f "$WATCH" ]; then
    M64W_EVTEST="$BIN_DIR/evtest" M64W_CPU_SET="$CPUFREQ_SET" \
    M64W_CPU_GAME="$CPU_GAME_KHZ" M64W_CPU_MENU="$CPU_MENU_KHZ" \
        sh "$WATCH" "$EMU_PID" &
    WATCH_PID=$!
fi
# Power-off / launcher teardown sends TERM here: forward it so the emulator dies
# cleanly and the parent wrapper's save-push trap still fires.
trap 'kill -TERM "$EMU_PID" 2>/dev/null' TERM INT
# wait can return early on a trapped signal — re-wait until the emulator is gone.
while :; do
    wait "$EMU_PID"
    rc=$?
    kill -0 "$EMU_PID" 2>/dev/null || break
done
# TERM (not KILL) so the watcher's trap reaps its evtest/FIFO and can never leave
# the screen dark or the emulator frozen.
[ -n "$WATCH_PID" ] && kill -TERM "$WATCH_PID" 2>/dev/null
echo "$CPU_MENU_KHZ" > "$CPUFREQ_SET" 2>/dev/null   # hand minui back its menu clock
exit $rc
