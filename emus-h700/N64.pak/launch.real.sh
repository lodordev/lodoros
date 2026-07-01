#!/bin/sh
# LodorOS H700 thin-shim launcher -- runs Nintendo 64 on the device's OWN stock Anbernic
# RetroArch + libretro core. This pak ships NO emulator, NO core, NO BIOS: it only invokes
# what already lives on the device's /mnt/vendor partition (firmware the user already owns).
# That is what makes it freely redistributable.
#
# APPROACH CREDIT: ryanmsartor (github.com/ryanmsartor/RGXX-Custom-MinUI-Paks). The technique of
# shimming the stock vendor RetroArch on H700 devices is his; this is a clean LodorOS reauthoring
# that bundles nothing -- in the same spirit we credit Grout.
#
# Save-sync is handled by the parent launch.sh (ROMM_STANDALONE_PAK_WRAPPER), which calls this.

set -u
ROM="${1:-}"
EMU_TAG="$(basename "$(dirname "$0")" .pak)"
RABIN="/mnt/vendor/deep/retro/retroarch"
COREDIR="/mnt/vendor/deep/retro/cores"
RACFG_SRC="/mnt/vendor/deep/retro/retroarch.cfg"
RACFG="/.config/retroarch/retroarch.cfg"
LOG="${LOGS_PATH:-/tmp}/$EMU_TAG.txt"

# detect-and-direct: pick the first stock core that's actually present on this device.
CORE=""
for c in mupen64plus_next parallel_n64; do
	if [ -f "$COREDIR/${c}_libretro.so" ]; then CORE="$c"; break; fi
done

# honest fail if the stock Anbernic firmware (or this core) isn't on the device.
if [ ! -x "$RABIN" ] || [ -z "$CORE" ]; then
	echo "LodorOS: $EMU_TAG needs the stock Anbernic emulator under /mnt/vendor/deep/retro," > "$LOG"
	echo "which is not present on this device. (LodorOS ships no $EMU_TAG emulator itself.)" >> "$LOG"
	exit 1
fi

# seed a writable RA config from the vendor one (carries system_directory for any BIOS, e.g. DC).
mkdir -p /.config/retroarch 2>/dev/null
[ -f "$RACFG" ] || cp -f "$RACFG_SRC" "$RACFG" 2>/dev/null
[ -f "$RACFG" ] && CFG="-c $RACFG" || CFG=""

exec "$RABIN" $CFG -L "$COREDIR/${CORE}_libretro.so" "$ROM"
