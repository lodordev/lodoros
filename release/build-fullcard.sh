#!/bin/sh
# build-fullcard.sh — assemble a CURRENT-version LodorOS full-card zip in one step, so a
# release always ships a full card whose version MATCHES the update overlays (the drift this
# closes: release.sh built only the update-overlay zips, so the lodoros full card lagged —
# 0.9.5 card vs 0.9.7.1 overlays — violating the "one full card, in sync everywhere" model).
#
# HOW: a full card = launcher binaries (minui.elf/minarch) + native/stock tools + the Lodor
# engine/paks. release.sh rebuilds the engine+paks every run (the update overlays in $OUT) but
# does NOT rebuild the per-platform launchers (that needs device toolchains — a separate, still-
# BLOCKED infra job). So this composes the two the SAME way an on-device self-update does:
#   BASE CARD (proven launchers + native tools)  +  THIS RELEASE's update overlays  ->  full card
# The launchers ride from BASE_CARD until the toolchain rebuild lands; the engine/paks/version are
# always THIS release's. Then build-public.sh strips secrets, gates hard, and zips.
#
# STDOUT is ONLY the final "FULLCARD <zip> <sha256>" line (captured for the release manifest);
# all progress goes to stderr — same convention as release.sh's assemble_* functions.
#
# Usage:
#   LODOR_BASE_CARD=<path to a prior full-card zip>  release/build-fullcard.sh <OUT_DIR> [VERSION]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="${1:?usage: build-fullcard.sh <OUT_DIR> [VERSION]}"
VER="${2:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.9.0)}"
BASE="${LODOR_BASE_CARD:?set LODOR_BASE_CARD=<prior full-card zip supplying launchers+native tools>}"
[ -f "$BASE" ] || { echo "FATAL: base card zip not found: $BASE" >&2; exit 2; }
SHA=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)

work="$OUT/.fullcard-work"; card="$work/card"
rm -rf "$work"; mkdir -p "$card"
echo ">> extract base card: $(basename "$BASE")" >&2
unzip -oq "$BASE" -d "$card" || { echo "FATAL: base card unzip failed" >&2; exit 2; }
[ -d "$card/Tools" ] || { echo "FATAL: base card has no Tools/ (not a full card?)" >&2; exit 2; }

# #22: do not blindly re-stamp the base card down to $VER. Read the base card's OWN version and
# assert it is (a) from the LodorOS lane (sane "LodorOS-<ver>" / bare-numeric format) and (b) not
# NEWER than $VER. A newer or foreign base means the wrong card was handed in — fail loud instead
# of silently stamping a 0.9.8 (or non-LodorOS) card back to $VER and shipping a downgrade.
base_ver_raw=""
if [ -f "$card/.system/version.txt" ]; then
  base_ver_raw=$(head -n1 "$card/.system/version.txt" 2>/dev/null || true)
elif [ -f "$card/version.txt" ]; then
  base_ver_raw=$(head -n1 "$card/version.txt" 2>/dev/null || true)
fi
[ -n "$base_ver_raw" ] || { echo "FATAL: base card carries no version.txt / .system/version.txt — refusing to stamp a version-less card" >&2; exit 2; }
# LodorOS lane format: either "LodorOS-<ver>" (.system source) or a bare "<ver>" (root file).
# Reject any foreign label (e.g. "MinUI 2024..." or "NextUI-...") — wrong lane, wrong card.
case "$base_ver_raw" in
  LodorOS-*) base_ver=${base_ver_raw#LodorOS-} ;;
  [0-9]*)    base_ver=$base_ver_raw ;;
  *) echo "FATAL: base card version '$base_ver_raw' is not from the LodorOS lane — wrong card?" >&2; exit 2;;
esac
BASE_VER="$base_ver" TARGET_VER="$VER" python3 - <<'PYV' || { echo "FATAL: base card version '$base_ver_raw' is newer than / incomparable to target $VER — refusing to downgrade-stamp" >&2; exit 2; }
import os, re, sys
def parse(v):
    m = re.fullmatch(r"(\d+(?:\.\d+){0,3})(?:-[0-9A-Za-z.]+)?", v.strip())
    if not m:
        raise SystemExit(1)
    return [int(x) for x in m.group(1).split(".")]
b = parse(os.environ["BASE_VER"])
t = parse(os.environ["TARGET_VER"])
n = max(len(b), len(t)); b += [0] * (n - len(b)); t += [0] * (n - len(t))
raise SystemExit(0 if b <= t else 1)
PYV
echo ">> base card version OK: $base_ver_raw (<= $VER, LodorOS lane)" >&2

# overlay THIS release's engine+paks for every platform whose update zip exists in $OUT. The
# overlay carries Tools/<plat>/Lodor.pak + Update Lodor.pak — exactly what the on-device applier
# lays down — so the full card ends up byte-identical to a base card that self-updated to $VER.
applied=""
for ov in "$OUT"/Lodor-LodorOS-update-*-"$VER".zip; do
  [ -f "$ov" ] || { echo "FATAL: no update overlays for $VER in $OUT — run release.sh first" >&2; exit 2; }
  p=$(basename "$ov"); p=${p#Lodor-LodorOS-update-}; p=${p%-$VER.zip}
  unzip -oq "$ov" -d "$card" || { echo "FATAL: overlay unzip failed: $ov" >&2; exit 2; }
  applied="$applied $p"
  echo ">> overlaid engine+paks: $p" >&2
done
[ -n "$applied" ] || { echo "FATAL: no overlays applied" >&2; exit 2; }

# #21: "at least one overlay applied" is not enough — a PARTIAL overlay set ships a mixed-version
# card (fresh engine on overlaid platforms, stale base-card engine on the rest, all under one
# $VER label). Enumerate every platform the base card actually carries (a dir present under BOTH
# .system/<plat>/ and Tools/<plat>/ — the two per-platform trees assemble-tools.sh always makes
# in lockstep) and FAIL if any lacks a matching overlay in $OUT.
missing=""
for sysdir in "$card"/.system/*/; do
  [ -d "$sysdir" ] || continue
  plat=$(basename "$sysdir")
  # a real platform has BOTH per-platform trees; skips .system files / shared entries
  [ -d "$card/Tools/$plat" ] || continue
  case " $applied " in
    *" $plat "*) : ;;
    *) missing="$missing $plat" ;;
  esac
done
[ -z "$missing" ] || { echo "FATAL: base card platforms with NO $VER overlay in $OUT:$missing — a partial overlay set would ship a mixed-version card. Build all platform overlays (release.sh) or use a base card scoped to the built platforms." >&2; exit 2; }
echo ">> overlay coverage OK: every base-card platform overlaid to $VER" >&2

# lodoros#15: card-root provisioning docs ship fresh from THIS release's tree, never riding
# stale from the base card (which may predate them). config.json.example is the template;
# README-CONFIG.txt explains the pre-provisioning path (copy to Tools/<plat>/Lodor.pak/
# config.json -> wizard skipped).
cp "$ROOT/lodoros/config.json.example" "$card/config.json.example" || { echo "FATAL: config.json.example missing from lodoros tree" >&2; exit 2; }
cp "$ROOT/lodoros/README-CONFIG.txt"   "$card/README-CONFIG.txt"   || { echo "FATAL: README-CONFIG.txt missing from lodoros tree" >&2; exit 2; }
echo ">> staged card-root provisioning docs: config.json.example + README-CONFIG.txt" >&2

# version stamp — both files the OS/About screen read (root version.txt is also rewritten by
# build-public.sh; .system/version.txt is the About-screen source and must carry LodorOS-<VER>).
printf '%s\n' "$VER" > "$card/version.txt"
printf 'LodorOS-%s\n%s\n' "$VER" "$SHA" > "$card/.system/version.txt"
echo ">> stamped version.txt=$VER  .system/version.txt=LodorOS-$VER ($SHA)" >&2

echo ">> build-public.sh (strip + gate + zip)" >&2
sh "$ROOT/release/build-public.sh" "$card" "$OUT" "$VER" >&2 || { echo "FATAL: build-public.sh failed (a gate refused the tree)" >&2; exit 1; }
rm -rf "$work"
zipf="$OUT/LodorOS-$VER.zip"
[ -f "$zipf" ] || { echo "FATAL: build-public.sh did not produce $zipf" >&2; exit 1; }
echo "FULLCARD $(basename "$zipf") $(sha256sum "$zipf" | cut -d' ' -f1)"
