#!/bin/sh
# LodorOS release packager — the `package` stage of the build (#112).
# Turns an assembled staging tree into clean, deduped, BIOS-gated zips.
# Enforces Projects/lodoros-release-cleanroom-spec.md by construction.
#   Usage: package.sh <staging-tree> <output-dir> <version> <git-short-hash>
set -eu
SRC="${1:?staging tree}"; OUT="${2:?output dir}"; VER="${3:-0.9.0}"; HASH="${4:-unknown}"
WORK="$OUT/build"
echo ">> staging copy"
rm -rf "$WORK"; mkdir -p "$WORK" "$OUT"; cp -a "$SRC/." "$WORK/"; cd "$WORK"

echo ">> A. BIOS gate (fail-closed on copyrighted bootroms)"
BIOS=$(find . -type f \( -iname "drastic_bios*" -o -iname "gba_bios*" -o -iname "*_bios.bin" -o -iname "bios*.bin" -o -iname "scph*.bin" -o -iname "*.nds.bios" \) 2>/dev/null || true)
if [ -n "$BIOS" ]; then echo "FATAL: copyrighted BIOS present — refusing to package:"; echo "$BIOS"; exit 2; fi
echo "   clean."

echo ">> C. strip dev/build/FS cruft"
find . -type d -path "*assets/debugger" -exec rm -rf {} + 2>/dev/null || true
find . \( -name ".git" -o -name ".gitkeep" -o -name ".gitignore" -o -name ".gitattributes" -o -name ".gitmodules" \) -exec rm -rf {} + 2>/dev/null || true
find . \( -name "*.bak" -o -name "*.orig" -o -name "*.rej" -o -name "*~" -o -name "*.swp" -o -name "*.swo" -o -name "test_btns" -o -name "*.log" \) -delete 2>/dev/null || true
find . \( -name ".DS_Store" -o -name "._*" -o -name "Thumbs.db" -o -name "desktop.ini" \) -delete 2>/dev/null || true
rm -rf .Spotlight-V100 .fseventsd .Trashes .TemporaryItems __MACOSX .apdisk 2>/dev/null || true

echo ">> D. reset device state in .userdata (keep auto.sh + minarch cfgs)"
find .userdata -type f \( -name "msettings.bin" -o -name "mstick.bin" -o -name "datetime.txt" \) -delete 2>/dev/null || true
find .userdata -type f -regextype posix-extended -regex ".*/([0-9]{1,3}\.){3}[0-9]{1,3}$" -delete 2>/dev/null || true

echo ">> B. dedup Tailscale -> .system/.tailscale/<arch> (one copy per arch)"
for d in Tools/*/Lodor.pak/tailscale; do
  [ -d "$d" ] || continue
  if file -b "$d/tailscaled" 2>/dev/null | grep -q aarch64; then arch=arm64; else arch=armhf; fi
  if [ ! -e ".system/.tailscale/$arch/tailscaled" ]; then
    mkdir -p ".system/.tailscale/$arch"; cp -a "$d/." ".system/.tailscale/$arch/"
    echo "   kept $arch from $d"
  fi
  rm -rf "$d"
done

echo ">> version.txt"
printf 'LodorOS-%s\n%s\n' "$VER" "$HASH" > .system/version.txt; cat .system/version.txt | sed 's/^/   /'

echo ">> package: base (cores only — heavy Emus are extras)"
BASE="$OUT/LodorOS-$VER-base-$HASH.zip"; rm -f "$BASE"
zip -r -q -y "$BASE" . -x "Emus/*" -x "SHA256SUMS.txt"
echo "   $BASE = $(du -h "$BASE" | cut -f1)"

echo ">> package: per-platform extras (heavy standalone emulators)"
if [ -d Emus ]; then
  for p in Emus/*/; do
    plat=$(basename "$p"); EX="$OUT/LodorOS-$VER-extras-$plat-$HASH.zip"; rm -f "$EX"
    ( cd Emus && zip -r -q -y "$EX" "$plat" )
    echo "   $EX = $(du -h "$EX" | cut -f1)"
  done
fi
echo ">> done."
