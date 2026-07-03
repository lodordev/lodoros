#!/bin/sh
# build-public.sh — turn a full assembled LodorOS card tree into a CLEAN, gated, public
# release zip. Deterministic + self-correcting: strips everything non-shippable, rewrites
# RELEASE-NOTES, regenerates SHA256SUMS, hard-gates, then zips. Operates on a COPY — never
# mutates SRC. Refuses to produce a zip if any gate fails.
#
# Usage:
#   release/build-public.sh <SRC_TREE> <OUT_DIR> [VERSION]
#     SRC_TREE : a full assembled card tree (e.g. the dev onezip) with CURRENT binaries.
#     OUT_DIR  : where the zip + .sha256 land.
#     VERSION  : defaults to the repo VERSION file, else 0.9.0.
#
# What it removes (and why):
#   - non-redistributable paks   : any _LODOROS-PROVENANCE.txt marked LICENSE: NONE /
#                                  NEVER commit/push / PROPRIETARY / closed-source, plus
#                                  the drastic/drastic64 proprietary binaries.
#   - bundled config.json        : carries a private hostname/token — onboarding recreates it.
#   - wifi.txt                   : saved Wi-Fi credentials — never ship.
#   - TrimUI + magicmini         : tg5040 / zero28 / trimuismart (served by Lodor-NextUI) and
#                                  magicmini (no current toolchain-built launcher).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?usage: build-public.sh <SRC_TREE> <OUT_DIR> [VERSION]}"
OUT="${2:?usage: build-public.sh <SRC_TREE> <OUT_DIR> [VERSION]}"
VER="${3:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.9.0)}"
GATE="$ROOT/release/gate.sh"
NOTES_SRC="$ROOT/release/release-notes.md"

[ -d "$SRC" ] || { echo "FATAL: SRC tree not found: $SRC" >&2; exit 2; }
mkdir -p "$OUT"
STAGE="$OUT/.public-stage"
echo ">> staging a clean copy of $SRC"
rm -rf "$STAGE"; mkdir -p "$STAGE"; cp -a "$SRC/." "$STAGE/"

echo ">> strip: non-redistributable paks (provenance-marked)"
find "$STAGE" -name "_LODOROS-PROVENANCE.txt" -exec grep -liE \
  "LICENSE: NONE|NEVER commit/push|not redistributable|PROPRIETARY|closed-source" {} + 2>/dev/null \
  | while read -r f; do d="$(dirname "$f")"; echo "   - ${d#"$STAGE"/}"; rm -rf "$d"; done || true
# backstop: proprietary DraStic binaries by name (its provenance explains the license nuance)
find "$STAGE" -type f \( -name drastic -o -name drastic64 \) 2>/dev/null \
  | while read -r b; do d="$(dirname "$b")"; echo "   - ${d#"$STAGE"/} (drastic binary)"; rm -rf "$d"; done || true

echo ">> strip: bundled config.json (private hostname/token) + wifi.txt"
find "$STAGE" -path "*/Lodor.pak/config.json" -delete 2>/dev/null || true
find "$STAGE" -name "wifi.txt" -delete 2>/dev/null || true

echo ">> strip: TrimUI (tg5040/zero28/trimuismart) + magicmini"
find "$STAGE" \( -iname "*tg5040*" -o -iname "*zero28*" -o -iname "*trimuismart*" \) -exec rm -rf {} + 2>/dev/null || true
for p in magicmini; do
  rm -rf "$STAGE/.system/$p" "$STAGE/Emus/$p" "$STAGE/Tools/$p" "$STAGE/.userdata/$p" 2>/dev/null || true
done

echo ">> rewrite RELEASE-NOTES.md"
if [ -f "$NOTES_SRC" ]; then cp "$NOTES_SRC" "$STAGE/RELEASE-NOTES.md";
else echo "   (no release/release-notes.md template — leaving as-is)"; fi
printf '%s\n' "$VER" > "$STAGE/version.txt"

echo ">> regenerate SHA256SUMS.txt"
( cd "$STAGE" && rm -f SHA256SUMS.txt && \
  find . -type f ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.txt )

echo ">> GATES (hard-fail)"
sh "$GATE" redistributable "$STAGE"
sh "$GATE" no-legacy       "$STAGE"
sh "$GATE" branding        "$STAGE"
# shim-coverage: the auto save-sync bracket. A public zip whose minarch.elf is a plain ELF (not the
# ROMM_MINARCH_SHIM shim wrapping minarch.real.elf) ships with NO native save sync — the 0.9.0-beta
# regression (a Jun 30 minarch redeploy wrote fresh builds over the baked shims in the onezip tree and
# this gate was not wired here, so the clobber shipped). Platform list = every launcher-ready platform
# that survives the strips above; a platform later dropped from the zip must be dropped HERE too (the
# gate failing loudly on its absence is the intended failure mode).
sh "$GATE" shim-coverage   "$STAGE" "miyoomini my282 my355 rg35xxplus rgb30"
# cruft: no *-bak deploy backups / rg40xxcube fossil in the zip (0.9.1 shipped 27 bak binaries
# + the fossil — deploy backups belong on the CARD, never in a release).
sh "$GATE" cruft           "$STAGE"
# agent-pii: no internal agent/personal name in any shipped text file or path name
# (0.9.1's romm-sync-lib leaked an internal reviewer name; provenance notes leaked two more).
sh "$GATE" agent-pii       "$STAGE"

ZIP="$OUT/LodorOS-$VER.zip"
echo ">> zip -> $ZIP"
rm -f "$ZIP"
( cd "$STAGE" && zip -rqX "$ZIP" . -x ".DS_Store" )
( cd "$OUT" && sha256sum "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )
rm -rf "$STAGE"

echo "== DONE =="
ls -lh "$ZIP" | awk '{print "   size:", $5}'
echo "   sha256: $(cut -d" " -f1 "$ZIP.sha256")"
echo "   platforms:"; unzip -l "$ZIP" | grep -oE "\.system/[a-z0-9]+/" | sort -u | sed 's/^/     /'
