#!/bin/sh
# Lodor release — ONE commit -> ALL platform artifacts, gated, or NOTHING ships.
# "One release, all platforms" made literal: a missing or ungated artifact fails the whole run.
# Usage: release.sh [<git-ref>]   (default: HEAD).  Writes release/manifest.json (provenance).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
REF=${1:-HEAD}; SHA=$(git rev-parse --short "$REF")
OUT="$ROOT/release/out/$SHA"; mkdir -p "$OUT"
GATE="$ROOT/release/gate.sh"
MAN="$ROOT/release/manifest.json"
fail(){ echo "RELEASE ABORT: $*" >&2; exit 1; }
hash(){ sha256sum "$1" | cut -d" " -f1; }

echo "== Lodor release @ $SHA =="
sh "$GATE" contract || fail "config contract gate failed"

# ---- engine: CGO-free static, both arches (the only two binaries that cover every device) ----
build_engine(){ # <goarch> <goarm-or-empty> <triple>
  arch=$1; arm=$2; triple=$3; bin="$OUT/lodor-sync-$triple"
  docker run --rm -v "$ROOT/engine":/src -w /src \
    -e CGO_ENABLED=0 -e GOARCH="$arch" ${arm:+-e GOARM=$arm} \
    golang:1.25-bookworm \
    go build -trimpath -ldflags "-s -w" -o "/src/.out-$triple" ./cmd/lodor-sync 2>&1 | tail -2 || fail "engine build $triple"
  mv "$ROOT/engine/.out-$triple" "$bin"
  sh "$GATE" static-go "$bin" || fail "engine $triple failed static-go gate"
  echo "$triple $(hash "$bin")"
}
ENG_ARMHF=$(build_engine arm 7 armhf)
ENG_ARM64=$(build_engine arm64 "" arm64)

# ---- OnionOS App on-screen menu: CGO-free static armhf framebuffer renderer (lodor-menu) ----
# Reuses the muOS-lane ui package (vendored under integrations/onionos/menu); draws /dev/fb0 and
# reads evdev. Same static-go gate as the engine — nothing ungated reaches a card.
build_onion_menu(){
  bin="$OUT/lodor-menu-armhf"
  docker run --rm -v "$ROOT/integrations/onionos/menu":/src -w /src \
    -e CGO_ENABLED=0 -e GOARCH=arm -e GOARM=7 \
    golang:1.25-bookworm \
    go build -trimpath -ldflags "-s -w" -o /src/.out-menu . 2>&1 | tail -2 || fail "onion menu build"
  mv "$ROOT/integrations/onionos/menu/.out-menu" "$bin"
  sh "$GATE" static-go "$bin" || fail "onion menu failed static-go gate"
  echo "armhf $(hash "$bin")"
}
MENU_ARMHF=$(build_onion_menu)

# ---- launchers (LodorOS fork) per platform — FAILS CLOSED until wired into this pipeline ----
# Until each platform build is driven from HERE (toolchain image + gate vs stock + symbol assert),
# the release refuses to claim coverage it cannot reproduce. No silent partial "all platforms".
PLATFORMS="miyoomini my282 rg35xxplus my355"
LAUNCHERS=""
for p in $PLATFORMS; do
  if [ -x "$ROOT/release/build-launcher-$p.sh" ]; then
    sh "$ROOT/release/build-launcher-$p.sh" "$OUT" || fail "launcher build $p"
    LAUNCHERS="$LAUNCHERS $p:wired"
  else
    LAUNCHERS="$LAUNCHERS $p:UNWIRED"
  fi
done
case "$LAUNCHERS" in *UNWIRED*) echo "NOTE: launcher builds not yet wired into release ($LAUNCHERS) — engine artifacts gated+emitted; launcher coverage NOT claimed.";; esac

# ---- provenance manifest ----
{
  echo "{"
  echo "  \"commit\": \"$(git rev-parse "$REF")\","
  echo "  \"ref\": \"$REF\","
  echo "  \"engine\": {\"armhf\": \"${ENG_ARMHF##* }\", \"arm64\": \"${ENG_ARM64##* }\"},"
  echo "  \"onion_menu\": {\"armhf\": \"${MENU_ARMHF##* }\"},"
  echo "  \"launchers\": \"$(echo $LAUNCHERS | sed "s/^ //")\""
  echo "}"
} > "$MAN"
echo "== manifest -> $MAN =="; cat "$MAN"
echo "== artifacts in $OUT =="; ls -la "$OUT"
