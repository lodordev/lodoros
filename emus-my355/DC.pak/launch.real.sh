#!/bin/sh
# LodorOS heavy-pak launch.real.sh — STANDALONE flycast (Dreamcast).
# Invoked by launch.sh (ROMM_STANDALONE_PAK_WRAPPER) which owns RomM save-sync.
# Self-contained: vendored non-base lib closure under $BIN_DIR; only glibc base +
# device GPU driver (libEGL/libGLESv2/libgbm/libmali) + ALSA come from the device.
#
# BIOS (USER-SUPPLIED, NOT BUNDLED): flycast needs Dreamcast BIOS to boot most titles.
#   Place  dc_boot.bin  and  dc_flash.bin  in:  <SDCARD>/Bios/DC/
#   (HLE-bootable titles may run without it; full compatibility needs real BIOS.)
set -u

PAK_DIR="$(dirname "$0")"
EMU_TAG="$(basename "$PAK_DIR")"; EMU_TAG="${EMU_TAG%.*}"     # "DC"
PLAT="${PLATFORM:-$(basename "$(dirname "$PAK_DIR")")}"
BIN_DIR="$PAK_DIR/$PLAT"
ROM="$1"

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
SAVES="${SAVES_PATH:-$SDCARD/Saves}"
LOGS="${LOGS_PATH:-$SDCARD/Logs}"
USERDATA="${USERDATA_PATH:-$SDCARD/.userdata/$PLAT}"
SAVE_DIR="$SAVES/DC"
BIOS_DIR="$SDCARD/Bios/DC"
# flycast resolves data (incl. BIOS + VMU saves) under $XDG_DATA_HOME/flycast/.
# Point that "flycast" subdir's data/ at our Saves/DC so VMU/memcard round-trips
# through the engine sync seam; symlink BIOS in from the user-supplied dir.
FLY_HOME="$USERDATA/$EMU_TAG-flycast"
FLY_DATA="$FLY_HOME/flycast"
mkdir -p "$FLY_DATA" "$SAVE_DIR" "$BIOS_DIR" "$LOGS"
# Saves live in Saves/DC (engine-synced); link flycast's data dir there.
[ -e "$FLY_DATA/data" ] || ln -s "$SAVE_DIR" "$FLY_DATA/data" 2>/dev/null
# User-supplied BIOS, if present.
for b in dc_boot.bin dc_flash.bin naomi.zip awbios.zip; do
    [ -f "$BIOS_DIR/$b" ] && [ ! -e "$FLY_DATA/$b" ] && ln -s "$BIOS_DIR/$b" "$FLY_DATA/$b" 2>/dev/null
done

LOG="$LOGS/$EMU_TAG.txt"; rm -f "$LOG"; exec >>"$LOG" 2>&1
set -x

export HOME="$USERDATA"
export XDG_DATA_HOME="$FLY_HOME"
export XDG_CONFIG_HOME="$FLY_HOME"
FLY_LDP="$BIN_DIR:$SDCARD/.system/$PLAT/lib:${LD_LIBRARY_PATH:-}"

cd "$BIN_DIR"
# ── Clock contract (ported from N64.pak, 2026-07-06 Flip fix) ─────────────────
# my355 runs a `userspace` cpufreq governor: the FRONTEND pins the clock. minui
# parks menus at 600 MHz and it is MINARCH that raises it for a game — so a
# standalone emulator inherits menu clock. Pin PERFORMANCE (minarch's value on
# this platform) for the emulator; restore menu clock on every exit path so
# minui gets back the state it expects.
CPUFREQ_SET="${DC_CPUFREQ_SET:-/sys/devices/system/cpu/cpufreq/policy0/scaling_setspeed}"
CPU_GAME_KHZ=1992000
CPU_MENU_KHZ=600000
# Deliberately NO governor write: nothing else in LodorOS ever touches
# scaling_governor at runtime (minarch writes frequencies only), and the one
# candidate system-freeze on the Flip coincided with the first code to do so.
# If the runtime governor is userspace (it is when minui's 600 MHz parking
# works), the setspeed write below is sufficient; under any other governor it
# is a harmless silent no-op, exactly minarch's semantics.
echo "$CPU_GAME_KHZ" > "$CPUFREQ_SET" 2>/dev/null
trap 'echo "$CPU_MENU_KHZ" > "$CPUFREQ_SET" 2>/dev/null' EXIT TERM INT

env LD_LIBRARY_PATH="$FLY_LDP" ./flycast "$ROM"
rc=$?
echo "$CPU_MENU_KHZ" > "$CPUFREQ_SET" 2>/dev/null   # hand minui back its menu clock
exit $rc
