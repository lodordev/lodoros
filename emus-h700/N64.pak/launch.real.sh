#!/bin/sh
# LodorOS H700 N64 launcher. PRIMARY: bundled standalone mupen64plus (rg35xxplus/); newer H700
# devices (RG40XXV) have no stock RetroArch, so the bundled emulator is the only path. FALLBACK:
# stock Anbernic RetroArch shim (unchanged) for devices that ship it. Save-sync via parent launch.sh.
set -u
ROM="${1:-}"; PAKDIR="$(dirname "$0")"; EMU_TAG="$(basename "$PAKDIR" .pak)"
PLAT="$(basename "$(dirname "$PAKDIR")")"; DIR="$PAKDIR/$PLAT"; LOG="${LOGS_PATH:-/tmp}/$EMU_TAG.txt"
if [ -x "$DIR/mupen64plus" ] && [ -f "$DIR/libmupen64plus.so.2" ]; then
  SDCARD="$(cd "$PAKDIR/../../.." 2>/dev/null && pwd)"
  [ -n "$SDCARD" ] && CFGDIR="$SDCARD/.userdata/$PLAT/N64-mupen64plus" || CFGDIR="$PAKDIR/config"
  mkdir -p "$CFGDIR/save" 2>/dev/null
  [ -f "$CFGDIR/mupen64plus.cfg" ] || [ ! -f "$DIR/default.cfg" ] || cp -f "$DIR/default.cfg" "$CFGDIR/mupen64plus.cfg" 2>/dev/null
  echo "LodorOS: $EMU_TAG -> bundled mupen64plus (dir=$DIR cfg=$CFGDIR rom=$ROM)" > "$LOG"
  cd "$DIR" 2>/dev/null
  exec env LD_LIBRARY_PATH="$DIR:${LD_LIBRARY_PATH:-}" HOME="$CFGDIR" "$DIR/mupen64plus" \
    --corelib "$DIR/libmupen64plus.so.2" --plugindir "$DIR" --datadir "$DIR" --configdir "$CFGDIR" \
    --gfx mupen64plus-video-GLideN64.so --audio mupen64plus-audio-sdl.so --input mupen64plus-input-sdl.so \
    --rsp mupen64plus-rsp-hle.so --fullscreen "$ROM" >> "$LOG" 2>&1
fi
RABIN="/mnt/vendor/deep/retro/retroarch"; COREDIR="/mnt/vendor/deep/retro/cores"
RACFG_SRC="/mnt/vendor/deep/retro/retroarch.cfg"; RACFG="/.config/retroarch/retroarch.cfg"; CORE=""
for c in mupen64plus_next parallel_n64; do [ -f "$COREDIR/${c}_libretro.so" ] && { CORE="$c"; break; }; done
if [ ! -x "$RABIN" ] || [ -z "$CORE" ]; then
  echo "LodorOS: $EMU_TAG has no bundled emulator at $DIR and no stock RetroArch under" > "$LOG"
  echo "/mnt/vendor/deep/retro on this device -- cannot launch." >> "$LOG"; exit 1; fi
mkdir -p /.config/retroarch 2>/dev/null; [ -f "$RACFG" ] || cp -f "$RACFG_SRC" "$RACFG" 2>/dev/null
[ -f "$RACFG" ] && CFG="-c $RACFG" || CFG=""
exec "$RABIN" $CFG -L "$COREDIR/${CORE}_libretro.so" "$ROM"
