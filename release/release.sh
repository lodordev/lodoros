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
# Static aarch64 tailscaled + tailscale (official build) bundled into the muxapp for tier-1
# (Tailscale) RomM reachability. NOT committed to git (65MB); copied in at assemble time, the
# same shape the NextUI assembler uses. Override with TSBIN=<dir with tailscaled+tailscale>.
TSBIN="${TSBIN:-/mnt/cache/tmp/ts-stage/official-1.94.1}"
fail(){ echo "RELEASE ABORT: $*" >&2; exit 1; }
hash(){ sha256sum "$1" | cut -d" " -f1; }

echo "== Lodor release @ $SHA =="
sh "$GATE" contract || fail "config contract gate failed"

# ---- engine: CGO-free static, per arch AND per host variant (build tags) ----
# static-go MUST run where readelf exists: the build host may lack binutils (Unraid does),
# and gate.sh fails closed on a missing readelf instead of passing vacuously — so the gate
# runs inside the same golang image that built the binary.
gate_static_go(){ # <abs-path-to-bin-under-$OUT>
  docker run --rm -v "$ROOT":/repo -v "$OUT":/artifacts -w /repo \
    golang:1.25-bookworm sh release/gate.sh static-go "/artifacts/$(basename "$1")" \
    || fail "$(basename "$1") failed static-go gate"
}
build_engine(){ # <goarch> <goarm-or-empty> <triple> [tags]
  arch=$1; arm=$2; triple=$3; tags=${4:-}; bin="$OUT/lodor-sync-$triple"
  docker run --rm -v "$ROOT/engine":/src -w /src \
    -e CGO_ENABLED=0 -e GOARCH="$arch" ${arm:+-e GOARM=$arm} \
    golang:1.25-bookworm \
    go build ${tags:+-tags $tags} -trimpath -ldflags "-s -w" -o "/src/.out-$triple" ./cmd/lodor-sync 2>&1 | tail -2 || fail "engine build $triple"
  mv "$ROOT/engine/.out-$triple" "$bin"
  gate_static_go "$bin"
  echo "$triple $(hash "$bin")"
}
ENG_ARMHF=$(build_engine arm 7 armhf)                    # MinUI/NextUI default (armhf devices)
ENG_ARM64=$(build_engine arm64 "" arm64)                 # MinUI/NextUI default (arm64 devices)
ENG_ONION_ARMHF=$(build_engine arm 7 onion-armhf onion)  # OnionOS variant (Miyoo Mini Plus)
ENG_MUOS_ARM64=$(build_engine arm64 "" muos-arm64 muos)  # muOS variant (Allwinner H700, RG34XX)

# ---- muOS onboarding wizard: CGO-free static arm64 fb0/evdev UI (engine cmd/lodor-wizard) ----
build_wizard(){
  bin="$OUT/lodor-wizard-arm64"
  docker run --rm -v "$ROOT/engine":/src -w /src \
    -e CGO_ENABLED=0 -e GOARCH=arm64 \
    golang:1.25-bookworm \
    go build -tags muos -trimpath -ldflags "-s -w" -o /src/.out-wizard-arm64 ./cmd/lodor-wizard 2>&1 | tail -2 || fail "wizard build"
  mv "$ROOT/engine/.out-wizard-arm64" "$bin"
  gate_static_go "$bin"
  echo "arm64 $(hash "$bin")"
}
WIZARD_ARM64=$(build_wizard)

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
  gate_static_go "$bin"
  echo "armhf $(hash "$bin")"
}
MENU_ARMHF=$(build_onion_menu)

# ---- OnionOS release zip: unzip-to-SD-root shape (App/LodorSync/…), gated or nothing ----
# Stages the TRACKED integration tree + the onion-armhf engine + lodor-menu + the public CA
# bundle, strips any live device state (config.json / catalog-index.json / queues / logs —
# config.json.example stays), hard-gates the staged tree, then zips Lodor-OnionOS-<VER>.zip.
VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)
assemble_onion(){
  stage="$OUT/.onion-stage"; app="$stage/App/LodorSync"
  rm -rf "$stage"; mkdir -p "$stage/App"
  # tracked source only: a working tree can carry live config.json/tokens the zip must never
  git -C "$ROOT" archive "$REF" integrations/onionos/App | tar -x -C "$stage" --strip-components=2 -f - \
    || fail "onion assemble: git archive of integrations/onionos/App failed"
  [ -d "$app" ] || fail "onion assemble: staged tree missing App/LodorSync"
  cp "$OUT/lodor-sync-onion-armhf" "$app/lodor-sync"      || fail "onion assemble: engine copy"
  cp "$OUT/lodor-menu-armhf"       "$app/bin/lodor-menu"  || fail "onion assemble: menu copy"
  chmod 0755 "$app/lodor-sync" "$app/bin/lodor-menu" "$app/launch.sh" "$app/bin/"*.sh "$app/bin/romm-syncd" 2>/dev/null || true
  [ -f "$app/certs/ca-certificates.crt" ] || fail "onion assemble: CA bundle missing (TLS would fail on-device)"
  # belt-and-braces device-state strip (the archive is tracked-only, but never trust a tree)
  find "$stage" \( -path "*/data/config.json" -o -name catalog-index.json -o -name mirror-manifest.json \
    -o -name pending-saves.txt -o -name download-queue.txt -o -name last-synced.txt -o -name "*.log" \) \
    -type f -delete 2>/dev/null || true
  [ -f "$app/data/config.json.example" ] || fail "onion assemble: config.json.example missing after strip"
  [ -f "$app/config.json" ] || fail "onion assemble: app manifest config.json missing - app would be invisible in Onion Apps tab"
  # gate/progress chatter -> stderr: this function's STDOUT is captured for the manifest
  echo ">> onion gates (staged tree)" >&2
  sh "$GATE" branding        "$stage" >&2 || fail "onion zip failed branding gate"
  sh "$GATE" no-legacy       "$stage" >&2 || fail "onion zip failed no-legacy gate"
  sh "$GATE" cruft           "$stage" >&2 || fail "onion zip failed cruft gate"
  sh "$GATE" agent-pii       "$stage" >&2 || fail "onion zip failed agent-pii gate"
  sh "$GATE" redistributable "$stage" >&2 || fail "onion zip failed redistributable gate"
  zipf="$OUT/Lodor-OnionOS-$VERSION.zip"
  rm -f "$zipf"
  ( cd "$stage" && zip -rqX "$zipf" . -x ".DS_Store" ) || fail "onion zip"
  ( cd "$OUT" && sha256sum "$(basename "$zipf")" > "$(basename "$zipf").sha256" )
  rm -rf "$stage"
  echo "$(basename "$zipf") $(hash "$zipf")"
}
if [ "${LODOR_BUILD_ONION:-0}" = 1 ]; then ONION_ZIP=$(assemble_onion); else ONION_ZIP="skipped archived"; echo ">> onion assemble SKIPPED (integration ARCHIVED 2026-07-03; set LODOR_BUILD_ONION=1 to build)" >&2; fi

# ---- muOS release .muxapp: Archive Manager shape ("Lodor/…" at the zip root, the
# same internal layout as the validated staging build), gated or nothing. Stages the
# TRACKED integration tree + the muos-arm64 engine + the arm64 wizard + the public CA
# bundle, strips any live device state, hard-gates the staged tree, then zips
# Lodor-muOS-<VER>.muxapp (a .muxapp IS a zip; muOS Archive Manager installs it).
assemble_muos(){
  stage="$OUT/.muos-stage"; app="$stage/Lodor"
  rm -rf "$stage"; mkdir -p "$stage"
  # tracked source only: a working tree can carry live config.json/tokens the zip must never
  git -C "$ROOT" archive "$REF" "integrations/muos/App" | tar -x -C "$stage" --strip-components=3 -f - \
    || fail "muos assemble: git archive of integrations/muos/App failed"
  [ -d "$app" ] || fail "muos assemble: staged tree missing 'Lodor'"
  cp "$OUT/lodor-sync-muos-arm64" "$app/lodor-sync"   || fail "muos assemble: engine copy"
  cp "$OUT/lodor-wizard-arm64"    "$app/lodor-wizard" || fail "muos assemble: wizard copy"
  # Tailscale (tier-1 sign-in): static aarch64 daemon + CLI, bundled from the staged official
  # build (not committed to git). H700 is arm64. Verify the arch so a wrong-arch stage fails loud.
  [ -x "$TSBIN/tailscaled" ] && [ -x "$TSBIN/tailscale" ] || fail "muos assemble: tailscale binaries not found in TSBIN=$TSBIN"
  mkdir -p "$app/bin/tailscale"
  cp "$TSBIN/tailscaled" "$app/bin/tailscale/tailscaled" || fail "muos assemble: tailscaled copy"
  cp "$TSBIN/tailscale"  "$app/bin/tailscale/tailscale"  || fail "muos assemble: tailscale copy"
  file "$app/bin/tailscale/tailscaled" | grep -q "aarch64" || fail "muos assemble: bundled tailscaled is not aarch64"
  chmod 0755 "$app/lodor-sync" "$app/lodor-wizard" "$app/mux_launch.sh" "$app/bin/"*.sh "$app/bin/romm-"* "$app/bin/tailscale/"* 2>/dev/null || true
  [ -f "$app/certs/ca-certificates.crt" ] || fail "muos assemble: CA bundle missing (TLS would fail on-device)"
  # belt-and-braces device-state strip (the archive is tracked-only, but never trust a tree)
  find "$stage" \( -name config.json -o -name catalog-index.json -o -name mirror-manifest.json \
    -o -name pending-saves.txt -o -name download-queue.txt -o -name last-synced.txt -o -name "*.log" \
    -o -name ".pii-terms.conf" \) -type f -delete 2>/dev/null || true
  [ -f "$app/config.json.example" ] || fail "muos assemble: config.json.example missing after strip"
  # gate/progress chatter -> stderr: this function's STDOUT is captured for the manifest
  echo ">> muos gates (staged tree)" >&2
  sh "$GATE" branding        "$stage" >&2 || fail "muxapp failed branding gate"
  sh "$GATE" no-legacy       "$stage" >&2 || fail "muxapp failed no-legacy gate"
  sh "$GATE" cruft           "$stage" >&2 || fail "muxapp failed cruft gate"
  sh "$GATE" agent-pii       "$stage" >&2 || fail "muxapp failed agent-pii gate"
  sh "$GATE" redistributable "$stage" >&2 || fail "muxapp failed redistributable gate"
  zipf="$OUT/Lodor-muOS-$VERSION.muxapp"
  rm -f "$zipf"
  ( cd "$stage" && zip -rqX "$zipf" . -x ".DS_Store" ) || fail "muxapp zip"
  ( cd "$OUT" && sha256sum "$(basename "$zipf")" > "$(basename "$zipf").sha256" )
  rm -rf "$stage"
  echo "$(basename "$zipf") $(hash "$zipf")"
}
MUOS_MUXAPP=$(assemble_muos)

# ---- launchers (LodorOS fork) per platform — FAILS CLOSED until wired into this pipeline ----
# Until each platform build is driven from HERE (toolchain image + gate vs stock + symbol assert),
# the release refuses to claim coverage it cannot reproduce. No silent partial "all platforms".
# Miyoo-only fleet (pivot 2026-07-05). LODOR_BUILD_NONMIYOO=1 restores the archived set.
if [ "${LODOR_BUILD_NONMIYOO:-0}" = 1 ]; then PLATFORMS="miyoomini my282 rg35xxplus my355 rgb30"
else PLATFORMS="miyoomini my282 my355"; fi
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
  echo "  \"engine\": {\"armhf\": \"${ENG_ARMHF##* }\", \"arm64\": \"${ENG_ARM64##* }\", \"onion-armhf\": \"${ENG_ONION_ARMHF##* }\", \"muos-arm64\": \"${ENG_MUOS_ARM64##* }\"},"
  echo "  \"wizard\": {\"arm64\": \"${WIZARD_ARM64##* }\"},"
  echo "  \"onion_menu\": {\"armhf\": \"${MENU_ARMHF##* }\"},"
  echo "  \"onion_zip\": {\"$(echo "$ONION_ZIP" | cut -d" " -f1)\": \"${ONION_ZIP##* }\"},"
  echo "  \"muos_muxapp\": {\"$(echo "$MUOS_MUXAPP" | cut -d" " -f1)\": \"${MUOS_MUXAPP##* }\"},"
  echo "  \"launchers\": \"$(echo $LAUNCHERS | sed "s/^ //")\""
  echo "}"
} > "$MAN"
echo "== manifest -> $MAN =="; cat "$MAN"
echo "== artifacts in $OUT =="; ls -la "$OUT"
