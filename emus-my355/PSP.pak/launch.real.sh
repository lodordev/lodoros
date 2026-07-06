#!/bin/sh
# LodorOS heavy-pak launch.real.sh — STANDALONE PPSSPP (Sony PSP).
# Invoked by launch.sh (ROMM_STANDALONE_PAK_WRAPPER) which owns RomM save-sync.
# Self-contained: every non-base shared lib is vendored under $BIN_DIR; only glibc
# base + the device GPU driver (libEGL/libGLESv2/libgbm/libmali) come from the device.
#
# BIOS: PSP needs NONE. PPSSPP ships its own open-source flash0/ fonts in assets/
# (NOT Sony firmware). No user BIOS file is required.
#
# Template provenance: josegonzalez/minui-ppsspp-pak launch.sh — only the per-arch
# binary dir + assets path are LodorOS-specific; the PPSSPP invocation is upstream.
set -u

PAK_DIR="$(dirname "$0")"
EMU_TAG="$(basename "$PAK_DIR")"; EMU_TAG="${EMU_TAG%.*}"     # "PSP"
PLAT="${PLATFORM:-$(basename "$(dirname "$PAK_DIR")")}"
BIN_DIR="$PAK_DIR/$PLAT"
ROM="$1"

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
SAVES="${SAVES_PATH:-$SDCARD/Saves}"
LOGS="${LOGS_PATH:-$SDCARD/Logs}"
USERDATA="${USERDATA_PATH:-$SDCARD/.userdata/$PLAT}"
SAVE_DIR="$SAVES/PSP"
# PPSSPP "memstick" root holds PSP/SAVEDATA (game saves) + PSP/SYSTEM (ppsspp.ini).
# Point SAVEDATA at the engine-synced Saves/PSP so VMU/SAVEDATA round-trips through
# the RomM seam (the wrapper push/pull resolves Saves/PSP for "$ROM").
PPSSPP_HOME="$USERDATA/$EMU_TAG-ppsspp"
MEMSTICK="$PPSSPP_HOME/memstick"
mkdir -p "$MEMSTICK/PSP/SYSTEM" "$MEMSTICK/PSP/GAME" "$SAVE_DIR" "$LOGS"
# Saves live in Saves/PSP (engine-synced); link PPSSPP's SAVEDATA there.
[ -e "$MEMSTICK/PSP/SAVEDATA" ] || ln -s "$SAVE_DIR" "$MEMSTICK/PSP/SAVEDATA" 2>/dev/null

LOG="$LOGS/$EMU_TAG.txt"; rm -f "$LOG"; exec >>"$LOG" 2>&1
set -x

export HOME="$PPSSPP_HOME"
export XDG_CONFIG_HOME="$PPSSPP_HOME/.config"
# Vendored closure first, then LodorOS system libs, then the device GPU-driver dir.
PSP_LDP="$BIN_DIR:$SDCARD/.system/$PLAT/lib:${LD_LIBRARY_PATH:-}"

# Clear any stale GPU-backend-failure marker so a backend reset doesn't stick.
rm -f "$PPSSPP_HOME/.config/ppsspp/PSP/SYSTEM/FailedGraphicsBackends.txt" 2>/dev/null

cd "$BIN_DIR"
# ── Clock contract (ported from N64.pak, 2026-07-06 Flip fix) ─────────────────
# my355 runs a `userspace` cpufreq governor: the FRONTEND pins the clock. minui
# parks menus at 600 MHz and it is MINARCH that raises it for a game — so a
# standalone emulator inherits menu clock. Pin PERFORMANCE (minarch's value on
# this platform) for the emulator; restore menu clock on every exit path so
# minui gets back the state it expects.
CPUFREQ_GOV="${PSP_CPUFREQ_GOV:-/sys/devices/system/cpu/cpufreq/policy0/scaling_governor}"
CPUFREQ_SET="${PSP_CPUFREQ_SET:-/sys/devices/system/cpu/cpufreq/policy0/scaling_setspeed}"
CPU_GAME_KHZ=1992000
CPU_MENU_KHZ=600000
echo userspace > "$CPUFREQ_GOV" 2>/dev/null
echo "$CPU_GAME_KHZ" > "$CPUFREQ_SET" 2>/dev/null
trap 'echo "$CPU_MENU_KHZ" > "$CPUFREQ_SET" 2>/dev/null' EXIT TERM INT

# assets/ MUST sit beside the binary; PPSSPP resolves them relative to argv[0]/cwd.
env LD_LIBRARY_PATH="$PSP_LDP" \
    ./PPSSPPSDL --pause-menu-exit --fullscreen "$ROM"
rc=$?
echo "$CPU_MENU_KHZ" > "$CPUFREQ_SET" 2>/dev/null   # hand minui back its menu clock
exit $rc
