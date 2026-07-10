#!/bin/sh
# mkstatecores.sh — emit statecores.json (the Handoff v1 lane manifest, design D7)
# for an assembler to place next to config.json in the built pak/app.
#
# The manifest declares which core each system is PINNED to on this lane, the
# lane-specific state-directory component, and the frontend/arch half of the
# producer tuple. NO manifest on a device = the whole states feature stays dark
# (uploads nothing, offers nothing) — so emission is the ship-switch, and it is
# deliberately config-not-code: assemblers call this with their lane's table.
#
# Fleet policy (Decisions/2026-07-07-fleet-core-alignment.md): where platforms
# align we play to the LOWEST-POWER device — the Miyoo Mini Flip controls the
# cores. Version strings are advisory (prior art: they lie); the compat policy
# keys on core+arch.
#
# Usage:
#   mkstatecores.sh --frontend <lodoros|nextui|muos|knulli|onion> --arch <armhf|arm64> \
#                   --out <file> <system>=<core>[@<version>]:<dir>[:<size>] ...
#     <system>   RomM platform fs_slug (e.g. gamegear, gba, snes)
#     <core>     core project name (e.g. gpsp, snes9x2005_plus)
#     <version>  optional core version string (advisory only)
#     <dir>      lane state-dir component (minarch: "{TAG}-{core}";
#                muos: CoreDisplayName; knulli: system slug)
#     <size>     optional fixed serialize size in bytes (D11 strict check)
#
# Example (knulli, arm64, two systems):
#   mkstatecores.sh --frontend knulli --arch arm64 --out sb/statecores.json \
#     gba=gpsp@0.91-42f5still:gba gamegear=picodrive@1.9.6:gamegear
#
# Emits pretty JSON, validates its own output against the engine's loader
# contract (version/frontend/arch/systems non-empty), exits non-zero on any
# malformed spec — an assembler must fail loudly, never ship a bad manifest.
set -eu

FRONTEND=""; ARCH=""; OUT=""
while [ $# -gt 0 ]; do case "$1" in
	--frontend) FRONTEND=$2; shift 2;;
	--arch)     ARCH=$2; shift 2;;
	--out)      OUT=$2; shift 2;;
	--*) echo "mkstatecores: unknown flag $1" >&2; exit 2;;
	*) break;;
esac; done

case "$FRONTEND" in
	lodoros|nextui|muos|knulli|onion) ;;
	*) echo "mkstatecores: --frontend must be lodoros|nextui|muos|knulli|onion (got '$FRONTEND')" >&2; exit 2;;
esac
case "$ARCH" in
	armhf|arm64) ;;
	*) echo "mkstatecores: --arch must be armhf|arm64 (got '$ARCH')" >&2; exit 2;;
esac
[ -n "$OUT" ] || { echo "mkstatecores: --out required" >&2; exit 2; }
[ $# -gt 0 ] || { echo "mkstatecores: at least one <system>=<core>[@ver]:<dir>[:size] spec required" >&2; exit 2; }

# Build the systems object. Pure-shell field splitting — specs may not contain
# quotes/backslashes (they are fs_slugs, core names and dir components).
SYSTEMS=""
for spec in "$@"; do
	case "$spec" in
		*'"'*|*'\'*) echo "mkstatecores: illegal character in spec: $spec" >&2; exit 2;;
	esac
	sys=${spec%%=*}
	rest=${spec#*=}
	[ -n "$sys" ] && [ "$sys" != "$spec" ] || { echo "mkstatecores: bad spec (no '='): $spec" >&2; exit 2; }
	corever=${rest%%:*}
	rest2=${rest#*:}
	[ "$rest2" != "$rest" ] || { echo "mkstatecores: bad spec (no ':<dir>'): $spec" >&2; exit 2; }
	dir=${rest2%%:*}
	size=""
	case "$rest2" in *:*) size=${rest2#*:};; esac
	core=$corever; ver=""
	case "$corever" in *@*) core=${corever%%@*}; ver=${corever#*@};; esac
	[ -n "$sys" ] && [ -n "$core" ] && [ -n "$dir" ] || { echo "mkstatecores: empty field in spec: $spec" >&2; exit 2; }
	if [ -n "$size" ]; then
		case "$size" in *[!0-9]*|'') echo "mkstatecores: size must be numeric: $spec" >&2; exit 2;; esac
	fi
	entry="    \"$sys\": {\"core\": \"$core\""
	[ -n "$ver" ]  && entry="$entry, \"version\": \"$ver\""
	entry="$entry, \"dir\": \"$dir\""
	[ -n "$size" ] && entry="$entry, \"size\": $size"
	entry="$entry}"
	[ -n "$SYSTEMS" ] && SYSTEMS="$SYSTEMS,
"
	SYSTEMS="$SYSTEMS$entry"
done

TMP="$OUT.tmp.$$"
cat > "$TMP" << EOF
{
  "version": 1,
  "frontend": "$FRONTEND",
  "arch": "$ARCH",
  "systems": {
$SYSTEMS
  }
}
EOF

# Self-check: the emitted file must parse and satisfy the engine loader's
# contract (loadStateCores fails closed on frontend/arch/systems — a manifest
# that fails there ships a dark feature SILENTLY, which this gate exists to
# prevent). jq if present, else python3, else fail hard: no validator, no ship.
if command -v jq >/dev/null 2>&1; then
	jq -e '(.version == 1) and (.frontend | length > 0) and (.arch | length > 0) and (.systems | length > 0) and ([.systems[] | (.core | length > 0) and (.dir | length > 0)] | all)' \
		"$TMP" >/dev/null || { echo "mkstatecores: emitted JSON failed validation" >&2; rm -f "$TMP"; exit 1; }
elif command -v python3 >/dev/null 2>&1; then
	python3 - "$TMP" << 'PYEOF' || { rm -f "$TMP"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d["version"] == 1 and d["frontend"] and d["arch"] and d["systems"]
for s in d["systems"].values():
    assert s["core"] and s["dir"]
PYEOF
else
	echo "mkstatecores: need jq or python3 to validate output — refusing to emit unchecked" >&2
	rm -f "$TMP"; exit 1
fi

mv "$TMP" "$OUT"
echo "mkstatecores: wrote $OUT ($FRONTEND/$ARCH, $# systems)"
