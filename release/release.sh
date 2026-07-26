#!/bin/sh
# Lodor release — ONE commit -> ALL platform artifacts, gated, or NOTHING ships.
# "One release, all platforms" made literal: a missing or ungated artifact fails the whole run.
# Usage: release.sh [<git-ref>]   (default: HEAD).  Writes release/manifest.json (provenance).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
REF=${1:-HEAD}; SHA=$(git rev-parse --short "$REF")
OUT="$ROOT/release/out/$SHA"; mkdir -p "$OUT"
GATE="$ROOT/release/gate.sh"
export LODOR_PII_REQUIRED=1   # private-mono caller: PII/branding gates must NOT fail open
MAN="$ROOT/release/manifest.json"
# Static aarch64 tailscaled + tailscale (official build) bundled into the muxapp for tier-1
# (Tailscale) RomM reachability. NOT committed to git (65MB); copied in at assemble time, the
# same shape the NextUI assembler uses. Override with TSBIN=<dir with tailscaled+tailscale>.
TSBIN="${TSBIN:-/mnt/cache/tmp/ts-stage/official-1.94.1}"
fail(){ echo "RELEASE ABORT: $*" >&2; exit 1; }
hash(){ sha256sum "$1" | cut -d" " -f1; }

echo "== Lodor release @ $SHA =="
sh "$GATE" contract || fail "config contract gate failed"

# Branch-debt notice (2026-07-10, non-fatal): every release surfaces unmerged branches
# with recent commits so staged work can't silently rot (the engine-romm-align lesson).
echo ">> branch debt (unmerged, tips <45d, non-archive):" >&2
_cutoff=$(( $(date +%s) - 45*86400 ))
git -C "$ROOT" for-each-ref refs/heads refs/remotes/origin --format='%(refname:short) %(committerdate:unix)' \
  | grep -v -E '^(origin/)?(main|HEAD)( |$)' | grep -v -E '^(origin/)?archive/' \
  | while read -r _ref _ts; do
      [ "$_ts" -lt "$_cutoff" ] && continue
      git -C "$ROOT" merge-base --is-ancestor "$_ref" origin/main 2>/dev/null && continue
      echo "   UNMERGED: ${_ref#origin/}" >&2
    done | sort -u >&2 || true


# Version is read BEFORE the engine builds so every binary carries it (ldflags -X into
# lodor/buildinfo.Version — the self-update compare + --version contract). An unstamped
# binary says "dev" and refuses to offer updates, so a missing VERSION here fails loud.
VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || true)
[ -n "$VERSION" ] || fail "VERSION file missing/empty at $ROOT/VERSION"

# ---- fleet-check stamp gate (WS7, 2026-07-22): never assemble an unchecked tree. ----
# test/fleet-check.sh --stamp writes release/.fleet-check-stamp on a fully green run.
# Emergency escape: LODOR_SKIP_FLEET_CHECK=1 (loud). The stamp pins the EXACT commit —
# any new commit (even docs) needs a fresh green run; that is the point, not a bug.
if [ "${LODOR_SKIP_FLEET_CHECK:-0}" != 1 ]; then
	_stamp=$(cat "$ROOT/release/.fleet-check-stamp" 2>/dev/null || true)
	_head=$(git -C "$ROOT" rev-parse "$REF")
	[ "$_stamp" = "$_head" ] || fail "no fleet-check stamp for $REF ($SHA) — run: sh test/fleet-check.sh --stamp  (emergency: LODOR_SKIP_FLEET_CHECK=1)"
	echo ">> fleet-check stamp OK for $SHA" >&2
else
	echo ">> WARNING: fleet-check stamp gate SKIPPED (LODOR_SKIP_FLEET_CHECK=1)" >&2
fi

# ---- engine: CGO-free static, per arch AND per host variant (build tags) ----
# static-go MUST run where readelf exists: the build host may lack binutils (Unraid does),
# and gate.sh fails closed on a missing readelf instead of passing vacuously — so the gate
# runs inside the same golang image that built the binary.
gate_static_go(){ # <abs-path-to-bin-under-$OUT>
  # gate chatter -> stderr: every caller runs inside $(...) capture (build_engine etc.);
  # gate "ok:" lines on stdout would pollute the captured "<triple> <hash>" value that
  # feeds the provenance manifest.
  docker run --rm -v "$ROOT":/repo -v "$OUT":/artifacts -w /repo \
    golang:1.25-bookworm sh release/gate.sh static-go "/artifacts/$(basename "$1")" >&2 \
    || fail "$(basename "$1") failed static-go gate"
}
build_engine(){ # <goarch> <goarm-or-empty> <triple> [tags]
  arch=$1; arm=$2; triple=$3; tags=${4:-}; bin="$OUT/lodor-sync-$triple"
  docker run --rm -v "$ROOT/engine":/src -w /src \
    -e CGO_ENABLED=0 -e GOARCH="$arch" ${arm:+-e GOARM=$arm} \
    golang:1.25-bookworm \
    go build ${tags:+-tags $tags} -trimpath -ldflags "-s -w -X lodor/buildinfo.Version=$VERSION" -o "/src/.out-$triple" ./cmd/lodor-sync 2>&1 | tail -2 || fail "engine build $triple"
  # mv is the real guard: the output exists ONLY if go build succeeded — a piped
  # `| tail` swallows go's exit code (sh has no pipefail), so this catches a silent
  # compile failure LOUDLY instead of shipping a lane without its binary.
  mv "$ROOT/engine/.out-$triple" "$bin" || fail "engine build $triple — no output (compile failed above)"
  gate_static_go "$bin"
  echo "$triple $(hash "$bin")"
}
ENG_ARMHF=$(build_engine arm 7 armhf)                    # MinUI/NextUI default (armhf devices)
ENG_ARM64=$(build_engine arm64 "" arm64)                 # MinUI/NextUI default (arm64 devices)
ENG_ONION_ARMHF=$(build_engine arm 7 onion-armhf onion)  # OnionOS variant (Miyoo Mini Plus)
# spruce tag guard (same rationale as knulli below): -tags spruce with no spruce-constrained
# files would silently ship a default-paths binary labeled spruce — fail LOUD instead.
grep -rq 'go:build.*spruce' "$ROOT/engine" 2>/dev/null \
  || fail "spruce engine build tag not found in engine/ — refusing to ship a default-paths binary labeled spruce"
ENG_SPRUCE_ARMHF=$(build_engine arm 7 spruce-armhf spruce)  # spruceOS variant (Miyoo A30 / Mini Flip)
ENG_MUOS_ARM64=$(build_engine arm64 "" muos-arm64 muos)  # muOS variant (Allwinner H700, RG34XX)
# Knulli variant (Batocera-family, arm64). The build TAG must exist in engine/ first:
# `go build -tags knulli` with no knulli-constrained files would silently compile the
# DEFAULT (MinUI-path) engine and ship it labeled knulli — fail LOUD instead until the
# parallel engine work lands the tag. Do not fake coverage.
grep -rq 'go:build.*knulli' "$ROOT/engine" 2>/dev/null \
  || fail "knulli engine build tag not found in engine/ (variant not landed yet) — refusing to ship a default-paths binary labeled knulli"
ENG_KNULLI_ARM64=$(build_engine arm64 "" knulli-arm64 knulli)  # Knulli variant (Batocera-family arm64)

# ---- wizard builds: CGO-free static fb0/evdev UI (engine cmd/lodor-wizard). muOS/knulli
# ship the muos-tagged arm64 build (onboarding + launch card); the LodorOS lanes ship
# DEFAULT-tagged per-arch builds (launch card via romm-session-sync — the fork's launcher
# owns onboarding, so the wizard is card-only there). ----------------------------------
build_wizard(){ # <goarch> <goarm-or-empty> <triple> [tags]
  arch=$1; arm=$2; triple=$3; tags=${4:-}; bin="$OUT/lodor-wizard-$triple"
  docker run --rm -v "$ROOT/engine":/src -w /src \
    -e CGO_ENABLED=0 -e GOARCH="$arch" ${arm:+-e GOARM=$arm} \
    golang:1.25-bookworm \
    go build ${tags:+-tags $tags} -trimpath -ldflags "-s -w -X lodor/buildinfo.Version=$VERSION" -o "/src/.out-wizard-$triple" ./cmd/lodor-wizard 2>&1 | tail -2 || fail "wizard build $triple"
  mv "$ROOT/engine/.out-wizard-$triple" "$bin" || fail "wizard build $triple — no output (compile failed above)"
  gate_static_go "$bin"
  echo "$triple $(hash "$bin")"
}
WIZARD_ARM64=$(build_wizard arm64 "" arm64 muos)     # muOS + knulli apps (existing name kept)
WIZ_LOS_ARMHF=$(build_wizard arm 7 los-armhf)        # LodorOS miyoomini (default tag)
WIZ_LOS_ARM64=$(build_wizard arm64 "" los-arm64)     # LodorOS my355 (default tag)
WIZ_ONION_ARMHF=$(build_wizard arm 7 onion-armhf onion)  # OnionOS launch card (Miyoo Mini/Plus, onion tag)
WIZ_SPRUCE_ARMHF=$(build_wizard arm 7 spruce-armhf spruce)  # spruceOS onboarding/sync + launch card (armhf, spruce tag)

# lodor-fbhelper (SDL 1.2) — the miyoomini launch-card scanout helper. Raw /dev/fb0 is DEAD on the
# SSD202D, so the wizard's SDL lane presents through this (same SDL1.2/MI_GFX path as minui.elf).
# Built with the pinned miyoomini toolchain (armhf/SDL1.2). OPTIONAL: if that image is absent
# (a host that doesn't build launchers), skip loudly — the card then falls back to its
# (dead-on-SSD202D) raw-fb lane, exactly as before this helper existed. No other lane uses it.
FBHELPER_MIYOOMINI=""
if docker image inspect miyoomini-toolchain >/dev/null 2>&1; then
  docker run --rm -v "$ROOT/lodoros/fbhelper":/src -v "$OUT":/out -w /src miyoomini-toolchain /bin/bash -lc \
    'arm-linux-gnueabihf-gcc lodor-fbhelper.c -o /out/lodor-fbhelper-miyoomini -lSDL -lmi_sys -lmi_gfx -lpthread' >&2 \
    || fail "lodor-fbhelper miyoomini build"
  [ -f "$OUT/lodor-fbhelper-miyoomini" ] || fail "lodor-fbhelper miyoomini: missing after build"
  FBHELPER_MIYOOMINI="$OUT/lodor-fbhelper-miyoomini"
  echo ">> lodor-fbhelper (miyoomini, SDL1.2) built" >&2
else
  echo ">> lodor-fbhelper SKIPPED — miyoomini-toolchain image absent (card keeps raw-fb lane on miyoomini)" >&2
fi


# ---- OnionOS release zip: unzip-to-SD-root shape (App/LodorSync/…), gated or nothing ----
# Stages the TRACKED integration tree + the onion-armhf engine + the public CA
# bundle, strips any live device state (config.json / catalog-index.json / queues / logs —
# config.json.example stays), hard-gates the staged tree, then zips Lodor-OnionOS-<VER>.zip.
assemble_onion(){
  stage="$OUT/.onion-stage"; app="$stage/App/LodorSync"
  rm -rf "$stage"; mkdir -p "$stage/App"
  # tracked source only: a working tree can carry live config.json/tokens the zip must never
  git -C "$ROOT" archive "$REF" integrations/onionos/App | tar -x -C "$stage" --strip-components=2 -f - \
    || fail "onion assemble: git archive of integrations/onionos/App failed"
  [ -d "$app" ] || fail "onion assemble: staged tree missing App/LodorSync"
  cp "$OUT/lodor-sync-onion-armhf"   "$app/lodor-sync"      || fail "onion assemble: engine copy"
  cp "$OUT/lodor-wizard-onion-armhf" "$app/lodor-wizard"    || fail "onion assemble: wizard copy (launch-card-v2)"
  chmod 0755 "$app/lodor-sync" "$app/lodor-wizard" "$app/launch.sh" "$app/bin/"*.sh "$app/bin/romm-syncd" 2>/dev/null || true
  # the launch card + engine must be the armhf ELF the Mini runs, never a stray host binary
  file "$app/lodor-sync"   | grep -q "ARM" || fail "onion assemble: lodor-sync is not an ARM binary"
  file "$app/lodor-wizard" | grep -q "ARM" || fail "onion assemble: lodor-wizard is not an ARM binary"
  [ -f "$app/certs/ca-certificates.crt" ] || fail "onion assemble: CA bundle missing (TLS would fail on-device)"
  # Handoff manifests (#27, lodor#1 fleet migration) — LIGHTS statesync on the Onion
  # lane. statecores.json: RomM-fs-slug=core:state-dir, VERSION-LESS tuples (compat
  # policy keys on core+arch, not version). Onion runs stock RetroArch with
  # savestate_directory=/mnt/SDCARD/Saves/CurrentProfile/states + sort_savestates_enable=true
  # (source: OnionUI/Onion static/configs/RetroArch/.retroarch/retroarch.cfg L2964/L3003) —
  # so states land in states/<CoreDisplayName>/, and the per-system <dir> IS the core
  # DISPLAY name, exactly like muOS. Cores = Onion stock defaults (platform_onion.go
  # onionDefaultCore, source-verified): gba=mGBA, nes=FCEUmm, gb/gbc=Gambatte,
  # gamegear/mastersystem/genesis=Genesis Plus GX. gba=mgba stays VERSIONLESS.
  #   FLAG (honest orphan, same as muOS): with the fleet-uniform D8 list below NOT
  #   declaring mgba:armhf or genesis_plus_gx:armhf, the GBA (mgba) and GG/SMS/MD
  #   (genesis_plus_gx) armhf entries have NO cross-lane D8 bridge — the fleet standard
  #   is gpsp/picodrive; mgba!=gpsp and genesis_plus_gx!=picodrive so no bridge is
  #   structurally possible (statecompat.go: `if ca != cb { return false }`). Reality,
  #   not a regression; mgba:armhf is a separate coordinated wave.
  sh "$ROOT/release/mkstatecores.sh" --frontend onion --arch armhf --out "$app/statecores.json" \
    nes=fceumm:FCEUmm gb=gambatte:Gambatte gbc=gambatte:Gambatte \
    gamegear=genesis_plus_gx:"Genesis Plus GX" mastersystem=genesis_plus_gx:"Genesis Plus GX" genesis=genesis_plus_gx:"Genesis Plus GX" \
    gba=mgba:mGBA >&2 || fail "onion statecores emit"
  # D8 whitelist — the fleet-UNIFORM class list, identical on every lane (do NOT add
  # mgba:armhf here yet — separate coordinated wave).
  sh "$ROOT/release/mkstatecompat.sh" --out "$app/state-compat.json" \
    fceumm:armhf,arm64 gambatte:armhf,arm64 picodrive:armhf,arm64 \
    gpsp:armhf gpsp:arm64 snes9x2005_plus:armhf snes9x2005_plus:arm64 \
    snes9x:arm64 mgba:arm64 genesis_plus_gx:arm64 >&2 || fail "onion statecompat emit"
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
# OnionOS is a shipping lane again (un-archived 2026-07-20 — "onion needs to be a lane"):
# builds unconditionally, same contract as knulli — gated or the whole release fails.
ONION_ZIP=$(assemble_onion)

# ---- spruceOS release zip: unzip-to-SD-root shape (App/Lodor/...), gated or nothing ----
# Promoted to a shipping lane 2026-07-22 ("spruce is a platform") — builds unconditionally,
# same contract as onion/knulli: gated or the whole release fails. Stages the TRACKED
# integration tree + the spruce-armhf engine + wizard + the public CA bundle, strips live
# device state, hard-gates the staged tree, then zips Lodor-spruce-<VER>.zip.
# (Absorbs the bring-up script release/assemble-spruce.sh, now removed.)
assemble_spruce(){
  stage="$OUT/.spruce-stage"; app="$stage/App/Lodor"
  rm -rf "$stage"; mkdir -p "$stage/App"
  # tracked source only: a working tree can carry live romm-config.json/tokens the zip must never
  git -C "$ROOT" archive "$REF" integrations/spruce/App | tar -x -C "$stage" --strip-components=2 -f - \
    || fail "spruce assemble: git archive of integrations/spruce/App failed"
  [ -d "$app" ] || fail "spruce assemble: staged tree missing App/Lodor"
  cp "$OUT/lodor-sync-spruce-armhf"   "$app/lodor-sync"   || fail "spruce assemble: engine copy"
  cp "$OUT/lodor-wizard-spruce-armhf" "$app/lodor-wizard" || fail "spruce assemble: wizard copy"
  chmod 0755 "$app/lodor-sync" "$app/lodor-wizard" "$app/launch.sh" "$app/lodor_launch.sh" "$app/bin/"* 2>/dev/null || true
  # the engine + wizard must be the armhf ELFs the device runs, never a stray host binary
  file "$app/lodor-sync"   | grep -q "ARM" || fail "spruce assemble: lodor-sync is not an ARM binary"
  file "$app/lodor-wizard" | grep -q "ARM" || fail "spruce assemble: lodor-wizard is not an ARM binary"
  [ -f "$app/certs/ca-certificates.crt" ] || fail "spruce assemble: CA bundle missing (TLS would fail on-device)"
  [ -f "$app/romm-config.json.example" ]  || fail "spruce assemble: romm-config.json.example missing"
  [ -f "$app/config.json" ] || fail "spruce assemble: App manifest config.json missing - app would be invisible in spruce Apps menu"
  # Handoff manifests (statesync, design D7) — LIGHTS statesync on the spruce lane.
  # spruce sorts states by BARE libretro core name (platform_spruce.go), so dir = the bare
  # core, matching LODOR_SAVE_SUBDIR. GBA = mgba per Decisions/2026-07-13-gba-fleet-mgba.md.
  #   FLAG (unchanged from bring-up): spruce GG/SMS/MD default to genesis_plus_gx while the
  #   fleet standard is picodrive — no D8 bridge possible, so they are NOT emitted here;
  #   resolve in a coordinated follow-up wave.
  sh "$ROOT/release/mkstatecores.sh" --frontend spruce --arch armhf --out "$app/statecores.json" \
    gba=mgba:mgba >&2 || fail "spruce statecores emit"
  # D8 whitelist — the fleet-UNIFORM class list, identical on every lane (do NOT add
  # mgba:armhf here yet — separate coordinated wave).
  sh "$ROOT/release/mkstatecompat.sh" --out "$app/state-compat.json" \
    fceumm:armhf,arm64 gambatte:armhf,arm64 picodrive:armhf,arm64 \
    gpsp:armhf gpsp:arm64 snes9x2005_plus:armhf snes9x2005_plus:arm64 \
    snes9x:arm64 mgba:arm64 genesis_plus_gx:arm64 >&2 || fail "spruce statecompat emit"
  # belt-and-braces live-state strip: spruce's ENGINE config is romm-config.json
  # (LODOR_CONFIG_NAME — App/Lodor/config.json is the spruce app MANIFEST, which stays).
  find "$stage" \( -name romm-config.json -o -name catalog-index.json -o -name mirror-manifest.json \
    -o -name pending-saves.txt -o -name download-queue.txt -o -name last-synced.txt -o -name "*.log" \) \
    -type f -delete 2>/dev/null || true
  [ -f "$app/romm-config.json.example" ] || fail "spruce assemble: romm-config.json.example missing after strip"
  # gate/progress chatter -> stderr: this function's STDOUT is captured for the manifest
  echo ">> spruce gates (staged tree)" >&2
  sh "$GATE" branding        "$stage" >&2 || fail "spruce zip failed branding gate"
  sh "$GATE" no-legacy       "$stage" >&2 || fail "spruce zip failed no-legacy gate"
  sh "$GATE" cruft           "$stage" >&2 || fail "spruce zip failed cruft gate"
  sh "$GATE" agent-pii       "$stage" >&2 || fail "spruce zip failed agent-pii gate"
  sh "$GATE" redistributable "$stage" >&2 || fail "spruce zip failed redistributable gate"
  zipf="$OUT/Lodor-spruce-$VERSION.zip"
  rm -f "$zipf"
  ( cd "$stage" && zip -rqX "$zipf" . -x ".DS_Store" ) || fail "spruce zip"
  ( cd "$OUT" && sha256sum "$(basename "$zipf")" > "$(basename "$zipf").sha256" )
  rm -rf "$stage"
  echo "$(basename "$zipf") $(hash "$zipf")"
}
# spruce is a shipping lane (promoted 2026-07-22): builds unconditionally, same contract
# as onion/knulli — gated or the whole release fails.
SPRUCE_ZIP=$(assemble_spruce)

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
  # Handoff manifests (#27) — LIGHTS statesync on muOS. Keys = RomM fs_slug (verified
  # live: genesis/mastersystem, NOT megadrive/sms). dir = RA CoreDisplayName (muOS
  # writes save/state/<CoreDisplayName>/), verified off the MustardOS 2601.1 image.
  # CORES = WHAT STOCK muOS ACTUALLY RUNS (fix #11, 2026-07-09). Ground truth is the
  # engine's OWN muOS default-core map (platform_muos.go:muosDefaultCore, "verified
  # corename, matches the card's save folders"). The README promise is "stock muOS stays
  # stock" — we NEVER flip its default assignments — so the manifest MUST mirror that
  # map, not an aspirational post-flip one. The old emit lied on THREE systems: it
  # declared picodrive (muOS runs Genesis Plus GX = genesis_plus_gx), snes9x2005_plus
  # (muOS runs Snes9x = snes9x), AND gpsp for GBA (muOS runs mGBA = mgba). Those wrong
  # cores also produced wrong dirs (PicoDrive / "Snes9x 2005 Plus" / gpSP) that never
  # matched where muOS actually writes save/state — every muOS state was a silent orphan.
  # dir = the exact CoreDisplayName from muosDefaultCore. NES/GB/GBC = already correct.
  #   ALIGNMENT WINS: snes=snes9x now matches Knulli/NextUI/Android (arm64 snes9x club);
  #   gba=mgba now matches Knulli/Android (arm64 mgba club).
  #   FLAG (honest orphan): GG/SMS/MD=genesis_plus_gx does NOT match the picodrive that
  #   LodorOS-my355/Knulli/NextUI declare — different core = no D8 bridge is possible
  #   (statecompat.go: `if ca != cb { return false }`). This is reality, not a
  #   regression; picodrive-vs-genesis_plus_gx across the arm64 lanes is a hardware-truth
  #   capability split to resolve on-device (see flagged-cells list).
  sh "$ROOT/release/mkstatecores.sh" --frontend muos --arch arm64 --out "$app/statecores.json" \
    nes=fceumm:FCEUmm gb=gambatte:Gambatte gbc=gambatte:Gambatte \
    gamegear=genesis_plus_gx:"Genesis Plus GX" mastersystem=genesis_plus_gx:"Genesis Plus GX" genesis=genesis_plus_gx:"Genesis Plus GX" \
    gba=mgba:mGBA snes=snes9x:Snes9x psx=pcsx_rearmed:PCSX-ReARMed n64=mupen64plus_next:Mupen64Plus-Next >&2 || fail "muos statecores emit"
  # D8 whitelist (fix #2 — fleet-uniform): every lane ships the SAME certified class
  # list, honoring xarch-cert FACTS (release/xarch-cert). Cross-bitness PASS (2026-07-07,
  # armhf↔arm64): fceumm, gambatte, picodrive → 2-arch class. Cross-bitness NOT proven
  # (single-arch version-bridge within the group only, per statecompat.go doc): gpsp,
  # snes9x2005_plus (cert FAIL cross-arch), plus snes9x/mgba/genesis_plus_gx (untested
  # by the harness — arm64-only club cores, so an arm64 version-bridge is all that is
  # honest; NO armhf entry, no armhf lane runs them). We NEVER assert a 2-arch class the
  # harness didn't earn.
  sh "$ROOT/release/mkstatecompat.sh" --out "$app/state-compat.json" \
    fceumm:armhf,arm64 gambatte:armhf,arm64 picodrive:armhf,arm64 \
    gpsp:armhf gpsp:arm64 snes9x2005_plus:armhf snes9x2005_plus:arm64 \
    snes9x:arm64 mgba:armhf,arm64 genesis_plus_gx:arm64 >&2 \
    || fail "muos statecompat emit"
  # Tailscale (tier-1 sign-in): static aarch64 daemon + CLI, bundled from the staged official
  # build (not committed to git). H700 is arm64. Verify the arch so a wrong-arch stage fails loud.
  [ -x "$TSBIN/tailscaled" ] && [ -x "$TSBIN/tailscale" ] || fail "muos assemble: tailscale binaries not found in TSBIN=$TSBIN"
  # Hash-pin: the bundled bytes MUST match release/ts-stage.sha256 (the vetted, already-shipping
  # binaries). Presence + `file|grep aarch64` proves arch, NOT provenance -- a swapped-but-aarch64
  # tailscaled would pass those and ship. Fail closed on any drift.
  ( cd "$TSBIN" && sha256sum -c "$ROOT/release/ts-stage.sha256" >&2 ) || fail "muos assemble: tailscale binary hash mismatch vs pinned (release/ts-stage.sha256)"
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

# ---- Knulli release zip: extract-onto-/userdata shape (system/lodor + system/scripts +
# system/services + roms/ports at the zip root), gated or nothing. Stages the TRACKED
# integration tree + the knulli-arm64 engine + the arm64 wizard + the Tailscale pair +
# the public CA bundle, strips any live device state, hard-gates the staged tree, then
# zips Lodor-Knulli-<VER>.zip.
assemble_knulli(){
  stage="$OUT/.knulli-stage"; app="$stage/system/lodor"
  rm -rf "$stage"; mkdir -p "$stage"
  # tracked source only: a working tree can carry live config.json/tokens the zip must never
  git -C "$ROOT" archive "$REF" "integrations/knulli/userdata" | tar -x -C "$stage" --strip-components=3 -f - \
    || fail "knulli assemble: git archive of integrations/knulli/userdata failed"
  [ -d "$app" ] || fail "knulli assemble: staged tree missing system/lodor"
  [ -f "$stage/system/scripts/lodor-hook.sh" ] || fail "knulli assemble: configgen hook missing"
  [ -f "$stage/system/services/lodor" ]        || fail "knulli assemble: boot service missing"
  [ -f "$stage/roms/ports/Lodor.sh" ]          || fail "knulli assemble: Ports entry missing"
  # engine artifact guard: the knulli engine lands from the parallel engine work — a
  # missing artifact means it hasn't; fail with the real reason, never substitute.
  [ -f "$OUT/lodor-sync-knulli-arm64" ] \
    || fail "knulli assemble: lodor-sync-knulli-arm64 missing from $OUT (knulli engine build not landed?)"
  cp "$OUT/lodor-sync-knulli-arm64" "$app/lodor-sync"   || fail "knulli assemble: engine copy"
  cp "$OUT/lodor-wizard-arm64"      "$app/lodor-wizard" || fail "knulli assemble: wizard copy"
  # Handoff manifests (#27) — LIGHTS statesync on this lane. statecores.json:
  # RomM-fs-slug=core:batocera-save-dir, version-less tuples (Android emits the
  # same shape — base Tier-0 matches on core+arch). Cores per the 2026-07-08/-09
  # fleet alignment. CORE = WHAT BATOCERA/KNULLI ACTUALLY LAUNCHES: the hook
  # (lodor-hook.sh gameStart) INHERITS Batocera's own per-system core assignment
  # and never forces one — so, exactly as on muOS (fix #11), the manifest must
  # mirror Batocera's real defaults, not an aspirational fleet core.
  #   gba=mgba is REALITY: Batocera/Knulli's stock GBA core is mGBA and the hook
  #   does not override it (FLAG #1/#13 — the fleet standard is gpsp on LodorOS/
  #   muOS/NextUI; mgba != gpsp so NO D8 bridge is structurally possible —
  #   statecompat.go: `if ca != cb { return false }`. Leave orphaned + flag; do
  #   NOT declare gpsp we don't run). snes=snes9x MATCHES muOS(fix#11)/NextUI/
  #   Android. picodrive GG/SMS/MD matches LodorOS-my355/NextUI but NOT muOS's
  #   genesis_plus_gx (that split is the muOS #11 flag, not a Knulli defect).
  #   PSX held (omitted — Knulli capability unconfirmed, see flag). genesis→
  #   megadrive is the one non-identity dir. Batocera saves per-SYSTEM (dir=slug),
  #   core-independent, so dirs are stable regardless of the core split.
  sh "$ROOT/release/mkstatecores.sh" --frontend knulli --arch arm64 --out "$app/statecores.json" \
    nes=fceumm:nes gb=gambatte:gb gbc=gambatte:gbc gba=mgba:gba \
    gamegear=picodrive:gamegear mastersystem=picodrive:mastersystem \
    genesis=picodrive:megadrive snes=snes9x:snes >&2 || fail "knulli statecores emit"
  # D8 whitelist (fix #2 — the fleet-UNIFORM class list; identical on every lane).
  sh "$ROOT/release/mkstatecompat.sh" --out "$app/state-compat.json" \
    fceumm:armhf,arm64 gambatte:armhf,arm64 picodrive:armhf,arm64 \
    gpsp:armhf gpsp:arm64 snes9x2005_plus:armhf snes9x2005_plus:arm64 \
    snes9x:arm64 mgba:armhf,arm64 genesis_plus_gx:arm64 >&2 || fail "knulli statecompat emit"
  # Tailscale (tier-1 sign-in): static aarch64 daemon + CLI, bundled from the staged
  # official build (not committed to git). Verify the arch so a wrong stage fails loud.
  [ -x "$TSBIN/tailscaled" ] && [ -x "$TSBIN/tailscale" ] || fail "knulli assemble: tailscale binaries not found in TSBIN=$TSBIN"
  # Hash-pin (see muos site): bundled bytes must match the vetted release/ts-stage.sha256.
  ( cd "$TSBIN" && sha256sum -c "$ROOT/release/ts-stage.sha256" >&2 ) || fail "knulli assemble: tailscale binary hash mismatch vs pinned (release/ts-stage.sha256)"
  mkdir -p "$app/bin/tailscale"
  cp "$TSBIN/tailscaled" "$app/bin/tailscale/tailscaled" || fail "knulli assemble: tailscaled copy"
  cp "$TSBIN/tailscale"  "$app/bin/tailscale/tailscale"  || fail "knulli assemble: tailscale copy"
  file "$app/bin/tailscale/tailscaled" | grep -q "aarch64" || fail "knulli assemble: bundled tailscaled is not aarch64"
  chmod 0755 "$app/lodor-sync" "$app/lodor-wizard" "$app/bin/"* "$app/bin/tailscale/"* \
    "$stage/system/scripts/lodor-hook.sh" "$stage/system/services/lodor" \
    "$stage/roms/ports/Lodor.sh" 2>/dev/null || true
  [ -f "$app/certs/ca-certificates.crt" ] || fail "knulli assemble: CA bundle missing (TLS would fail on-device)"
  # belt-and-braces device-state strip (the archive is tracked-only, but never trust a tree)
  find "$stage" \( -name config.json -o -name catalog-index.json -o -name mirror-manifest.json \
    -o -name pending-saves.txt -o -name download-queue.txt -o -name last-synced.txt -o -name "*.log" \
    -o -name ".pii-terms.conf" \) -type f -delete 2>/dev/null || true
  [ -f "$app/config.json.example" ] || fail "knulli assemble: config.json.example missing after strip"
  # gate/progress chatter -> stderr: this function's STDOUT is captured for the manifest
  echo ">> knulli gates (staged tree)" >&2
  sh "$GATE" branding        "$stage" >&2 || fail "knulli zip failed branding gate"
  sh "$GATE" no-legacy       "$stage" >&2 || fail "knulli zip failed no-legacy gate"
  sh "$GATE" cruft           "$stage" >&2 || fail "knulli zip failed cruft gate"
  sh "$GATE" agent-pii       "$stage" >&2 || fail "knulli zip failed agent-pii gate"
  sh "$GATE" redistributable "$stage" >&2 || fail "knulli zip failed redistributable gate"
  zipf="$OUT/Lodor-Knulli-$VERSION.zip"
  rm -f "$zipf"
  ( cd "$stage" && zip -rqX "$zipf" . -x ".DS_Store" ) || fail "knulli zip"
  ( cd "$OUT" && sha256sum "$(basename "$zipf")" > "$(basename "$zipf").sha256" )
  rm -rf "$stage"
  echo "$(basename "$zipf") $(hash "$zipf")"
}
KNULLI_ZIP=$(assemble_knulli)

# ---- Android engine: GOOS=android/arm64 — a bionic-linked PIE, NOT static (its own
# gate; static-go would wrongly fail it). Tag comes from GOOS (reserved `android`);
# the lodorandroid files must exist or GOOS=android silently compiles default paths.
grep -rq 'go:build.*lodorandroid' "$ROOT/engine" 2>/dev/null \
  || fail "android engine files (lodorandroid tag) not found in engine/ — refusing to ship a default-paths binary labeled android"
build_engine_android(){
  bin="$OUT/lodor-sync-android-arm64"
  docker run --rm -v "$ROOT/engine":/src -w /src \
    -e CGO_ENABLED=0 -e GOOS=android -e GOARCH=arm64 \
    golang:1.25-bookworm \
    go build -trimpath -ldflags "-s -w -X lodor/buildinfo.Version=$VERSION" -o /src/.out-android-arm64 ./cmd/lodor-sync 2>&1 | tail -2 || fail "engine build android-arm64"
  mv "$ROOT/engine/.out-android-arm64" "$bin" || fail "engine build android-arm64 — no output (compile failed above)"
  docker run --rm -v "$ROOT":/repo -v "$OUT":/artifacts -w /repo \
    golang:1.25-bookworm sh release/gate.sh android-engine "/artifacts/$(basename "$bin")" >&2 \
    || fail "lodor-sync-android-arm64 failed android-engine gate"
  echo "android-arm64 $(hash "$bin")"
}
ENG_ANDROID_ARM64=$(build_engine_android)

# ---- Android release APK: tracked source staged via git archive, engine baked into
# jniLibs, containerized Gradle (no host SDK), zipalign + apksigner with the release
# keystore OUTSIDE the repo. Losing that keystore orphans every install — generated
# ONCE and backed up (see integrations/android/README.md). Gated or nothing.
ANDROID_TOOLCHAIN_IMG="${LODOR_ANDROID_TOOLCHAIN:-lodor-android-toolchain}"
ANDROID_KEYSTORE="${LODOR_ANDROID_KEYSTORE:-/mnt/user/appdata/lodor/android-release.keystore}"
GRADLE_CACHE="${LODOR_GRADLE_CACHE:-/mnt/cache/tmp/lodor-gradle-cache}"
assemble_android(){
  stage="$OUT/.android-stage"
  rm -rf "$stage"; mkdir -p "$stage"
  git -C "$ROOT" archive "$REF" "integrations/android" | tar -x -C "$stage" --strip-components=2 -f - \
    || fail "android assemble: git archive of integrations/android failed"
  [ -f "$stage/settings.gradle.kts" ] || fail "android assemble: staged tree missing the gradle project"
  docker image inspect "$ANDROID_TOOLCHAIN_IMG" >/dev/null 2>&1 \
    || docker build -q -t "$ANDROID_TOOLCHAIN_IMG" "$ROOT/release/toolchains/android" >&2 \
    || fail "android assemble: toolchain image missing and build failed"
  [ -f "$ANDROID_KEYSTORE" ] \
    || fail "android assemble: release keystore missing at $ANDROID_KEYSTORE (generate ONCE with keytool + BACK UP — losing it orphans every install; see integrations/android/README.md)"
  [ -n "${LODOR_ANDROID_KEYSTORE_PASS:-}" ] || fail "android assemble: LODOR_ANDROID_KEYSTORE_PASS not set"
  mkdir -p "$stage/app/src/main/jniLibs/arm64-v8a"
  cp "$OUT/lodor-sync-android-arm64" "$stage/app/src/main/jniLibs/arm64-v8a/liblodorsync.so" \
    || fail "android assemble: engine copy"
  echo ">> android gradle assembleRelease" >&2
  mkdir -p "$GRADLE_CACHE"
  docker run --rm -v "$stage":/project -v "$GRADLE_CACHE":/gradle-cache -w /project \
    "$ANDROID_TOOLCHAIN_IMG" gradle --no-daemon -q -PlodorVersion="$VERSION" assembleRelease >&2 \
    || fail "android assemble: gradle assembleRelease failed"
  [ -f "$stage/app/build/outputs/apk/release/app-release-unsigned.apk" ] \
    || fail "android assemble: unsigned APK not produced"
  apk="Lodor-Android-$VERSION.apk"
  docker run --rm -v "$stage":/project -v "$OUT":/out -v "$(dirname "$ANDROID_KEYSTORE")":/keys:ro \
    -e KSPASS="$LODOR_ANDROID_KEYSTORE_PASS" "$ANDROID_TOOLCHAIN_IMG" sh -c "
      set -e
      BT=\$(ls -d /opt/android-sdk/build-tools/* | tail -1)
      \"\$BT/zipalign\" -f 4 /project/app/build/outputs/apk/release/app-release-unsigned.apk \"/out/$apk\"
      \"\$BT/apksigner\" sign --ks \"/keys/$(basename "$ANDROID_KEYSTORE")\" --ks-pass env:KSPASS \"/out/$apk\"
      \"\$BT/apksigner\" verify \"/out/$apk\"
    " >&2 || fail "android assemble: zipalign/sign/verify failed"
  echo ">> android gates (apk + staged source)" >&2
  sh "$GATE" apk       "$OUT/$apk" >&2 || fail "android APK failed apk gate"
  sh "$GATE" branding  "$stage"    >&2 || fail "android stage failed branding gate"
  sh "$GATE" agent-pii "$stage"    >&2 || fail "android stage failed agent-pii gate"
  sh "$GATE" cruft     "$stage"    >&2 || fail "android stage failed cruft gate"
  ( cd "$OUT" && sha256sum "$apk" > "$apk.sha256" )
  rm -rf "$stage"
  echo "$apk $(hash "$OUT/$apk")"
}
# Android APK requires the release keystore (+ pass), which is intentionally NOT on
# every build host — a dev/test build on a host without it can skip this ONE lane
# without abandoning "all platforms or nothing" for a real release (default stays 1;
# a publish host has the keystore and builds it).
if [ "${LODOR_BUILD_ANDROID:-1}" = 1 ]; then ANDROID_APK=$(assemble_android); else ANDROID_APK="skipped (LODOR_BUILD_ANDROID=0)"; echo ">> android assemble SKIPPED (LODOR_BUILD_ANDROID=0 — no release keystore on this host)" >&2; fi

# ---- LodorOS self-update overlay zips (the ONLY lane with bespoke apply — no store exists
# for our own OS). One zip per launcher-ready platform: a card-root overlay carrying just
# Tools/<plat>/Lodor.pak (skeleton + right-arch stamped engine) and Tools/<plat>/"Update
# Lodor.pak". The engine's --fetch-update stages it (sha256 from versions.json), the boot
# applier (bin/lodor-apply-update via auto.sh) overlays it BEFORE romm-syncd starts. The
# LAUNCHER is deliberately absent (its A/B swap is a separate guarded flow); config.json /
# catalog-index.json never ship, so live pairing state survives every update by construction.
assemble_lodoros_update(){ # <plat> <engine-triple>
  p=$1; triple=$2
  stage="$OUT/.losu-$p"; pak="$stage/Tools/$p/Lodor.pak"
  rm -rf "$stage"; mkdir -p "$stage/Tools/$p"
  git -C "$ROOT" archive "$REF" "lodoros/paks/Lodor.pak" | tar -x -C "$stage/Tools/$p" --strip-components=2 -f - \
    || fail "lodoros-update $p: git archive of lodoros/paks/Lodor.pak failed"
  git -C "$ROOT" archive "$REF" "lodoros/paks/Update Lodor.pak" | tar -x -C "$stage/Tools/$p" --strip-components=2 -f - \
    || fail "lodoros-update $p: git archive of lodoros/paks/'Update Lodor.pak' failed"
  # miyoomini SDL scanout self-test pak (diagnostic, 2026-07-24): a one-boot check that lodor-fbhelper
  # scans out from a standalone process — the one unproven unknown behind the launch card. Ships only
  # where the helper does (miyoomini); harmless elsewhere but omitted to keep other overlays minimal.
  if [ "$p" = miyoomini ]; then
    git -C "$ROOT" archive "$REF" "lodoros/paks/SDL Test.pak" | tar -x -C "$stage/Tools/$p" --strip-components=2 -f - \
      || fail "lodoros-update $p: git archive of lodoros/paks/'SDL Test.pak' failed"
    [ -f "$stage/Tools/$p/SDL Test.pak/launch.sh" ] || fail "lodoros-update $p: SDL Test.pak missing"
    chmod 0755 "$stage/Tools/$p/SDL Test.pak/launch.sh" 2>/dev/null || true
  fi
  [ -d "$pak" ] || fail "lodoros-update $p: staged tree missing Lodor.pak"
  [ -f "$stage/Tools/$p/Update Lodor.pak/launch.sh" ] || fail "lodoros-update $p: Update Lodor.pak missing"
  [ -x "$pak/bin/lodor-apply-update" ] || chmod +x "$pak/bin/lodor-apply-update" 2>/dev/null || true
  [ -f "$pak/bin/lodor-apply-update" ] || fail "lodoros-update $p: boot applier missing from pak"
  # DELIVERY (Decision 2026-07-13-gba-fleet-mgba): the overlay ALSO ships the statecores
  # manifest saying gba=mgba (inside Lodor.pak, above). If a self-updated card kept its stock
  # gpsp GBA.pak, it would upload gpsp-format states tagged mgba and POISON the fleet. So carry
  # the mgba GBA.pak in the SAME overlay so manifest + core migrate ATOMICALLY. Land it at the
  # per-platform Emus/<plat>/GBA.pak path, which getEmuPath (common/utils.c:105) resolves FIRST
  # — ahead of the shared Emus/GBA.pak AND the base card's stock per-platform gpsp GBA.pak — so
  # it deterministically wins core resolution on EVERY platform. Source = lodoros/emus-<plat>/
  # GBA.pak (arch-correct mgba core: armhf for the Miyoos, arm64 for the Flip V2).
  mkdir -p "$stage/Emus/$p"
  git -C "$ROOT" archive "$REF" "lodoros/emus-$p/GBA.pak" | tar -x -C "$stage/Emus/$p" --strip-components=2 -f - \
    || fail "lodoros-update $p: git archive of lodoros/emus-$p/GBA.pak failed (mgba GBA overlay)"
  [ -f "$stage/Emus/$p/GBA.pak/launch.sh" ] || fail "lodoros-update $p: mgba GBA.pak overlay missing launch.sh"
  [ -f "$stage/Emus/$p/GBA.pak/mgba_libretro.so" ] || fail "lodoros-update $p: mgba GBA.pak overlay missing mgba_libretro.so"
  cp "$OUT/lodor-sync-$triple" "$pak/lodor-sync" || fail "lodoros-update $p: engine copy ($triple)"
  # Launch card (task #24): default-tagged wizard, arch-matched to the engine. Pak root,
  # same convention as the muOS/knulli apps; romm-session-sync no-ops honestly without it.
  cp "$OUT/lodor-wizard-los-$triple" "$pak/lodor-wizard" || fail "lodoros-update $p: wizard copy (los-$triple)"
  # miyoomini launch-card scanout helper (SDL 1.2): raw /dev/fb0 is dead on the SSD202D, so the
  # wizard's SDL lane needs this to present. Ships to bin/; romm-session-sync gates on its presence
  # and only exports LODOR_FBHELPER for miyoomini. Absent (toolchain skipped) => raw-fb lane.
  if [ "$p" = miyoomini ] && [ -n "$FBHELPER_MIYOOMINI" ]; then
    cp "$FBHELPER_MIYOOMINI" "$pak/bin/lodor-fbhelper" || fail "lodoros-update $p: fbhelper copy"
    chmod 0755 "$pak/bin/lodor-fbhelper"
  fi
  # Handoff manifests (#27) — LIGHTS statesync on LodorOS. The 0.9.7 engine (copied
  # above) carries the state verbs; 0.9.6 predated them, so this manifest + a 0.9.7
  # binary is the whole bump. dir = minarch {TAG}-{core} under .userdata/shared/
  # (verified live off the Mini Flip card; note SFC not SNES). Keys = RomM fs_slug
  # (genesis/mastersystem/psx, verified live). --arch = $triple verbatim (armhf|arm64);
  # dirs are arch-independent. gpsp/snes9x2005_plus hand off within-bitness-group only.
  #
  # #12 — SNES core is ARCH-SPLIT (fix 2026-07-09). The armhf Miyoos (miyoomini)
  # run snes9x2005_plus (snes9x-current is too heavy for armhf — xarch-cert README). The
  # arm64 my355 (Flip V2) is capable of the FULL snes9x, which is the arm64 fleet SNES
  # standard (Knulli/NextUI/Android, and muOS post-#11). Emitting snes9x2005_plus for ALL
  # platforms orphaned my355's SNES from the whole arm64 club (and cross-bitness snes9x2005
  # _plus FAILS cert anyway). Split it: arm64 → snes9x, armhf → snes9x2005_plus. The dir
  # is minarch {TAG}-{core}, so it tracks the core name automatically.
  #   FLAG: this ASSUMES my355's MinUI base bundles/assigns full snes9x. If the my355 base
  #   card actually ships snes9x2005_plus, this manifest would mis-declare — must be
  #   confirmed on my355 hardware (see flagged-cells list). N64: LodorOS runs STANDALONE
  #   mupen64plus (emus-*/N64.pak launch.real.sh — NOT a libretro core), which produces NO
  #   libretro save-states, so N64 is correctly ABSENT here (nothing state-syncable). GBA=
  #   mgba on LodorOS too now (Decision 2026-07-13-gba-fleet-mgba): a GBA.pak overlay ships
  #   the mgba core — shared armhf Emus/GBA.pak for the Miyoos, per-platform arm64
  #   Emus/my355/GBA.pak for the Flip V2 — so (GBA) folders run mgba fleet-wide and GBA
  #   save-states sync across muOS/Knulli/Android/LodorOS (all mgba). Cross-BITNESS mgba
  #   (armhf↔arm64) is now certified cross-bitness — state-compat ships mgba:armhf,arm64 (CERTIFIED 2026-07-14 cross-build cert, diff=0).
  if [ "$triple" = arm64 ]; then SNES_CORE=snes9x; else SNES_CORE=snes9x2005_plus; fi
  sh "$ROOT/release/mkstatecores.sh" --frontend lodoros --arch "$triple" --out "$pak/statecores.json" \
    nes=fceumm:FC-fceumm gb=gambatte:GB-gambatte gbc=gambatte:GBC-gambatte \
    gba=mgba:GBA-mgba gamegear=picodrive:GG-picodrive \
    mastersystem=picodrive:SMS-picodrive genesis=picodrive:MD-picodrive \
    "snes=$SNES_CORE:SFC-$SNES_CORE" psx=pcsx_rearmed:PS-pcsx_rearmed >&2 \
    || fail "lodoros-update $p statecores emit"
  # D8 whitelist (fix #2 — the fleet-UNIFORM class list; identical on every lane).
  sh "$ROOT/release/mkstatecompat.sh" --out "$pak/state-compat.json" \
    fceumm:armhf,arm64 gambatte:armhf,arm64 picodrive:armhf,arm64 \
    gpsp:armhf gpsp:arm64 snes9x2005_plus:armhf snes9x2005_plus:arm64 \
    snes9x:arm64 mgba:armhf,arm64 genesis_plus_gx:arm64 >&2 \
    || fail "lodoros-update $p statecompat emit"
  chmod 0755 "$pak/lodor-sync" "$pak/lodor-wizard" "$pak/launch.sh" "$pak/install.sh" "$pak/uninstall.sh" \
    "$pak"/bin/* "$pak"/lib/*.sh "$stage/Tools/$p/Update Lodor.pak/launch.sh" 2>/dev/null || true
  # live state never ships (same rule as every artifact); settings.conf IS shipped as the
  # defaults file — the applier's overlay would clobber user toggles, so strip it here and
  # let the on-card copy survive (first installs get it from the full card zip).
  find "$stage" \( -name config.json -o -name settings.conf -o -name catalog-index.json \
    -o -name mirror-manifest.json -o -name pending-saves.txt -o -name download-queue.txt \
    -o -name last-synced.txt -o -name "*.log" -o -name ".pii-terms.conf" \) -type f -delete 2>/dev/null || true
  # Pre-ship declared==launched gate (Decision 2026-07-13-gba-fleet-mgba): the manifest-vs-core
  # POISONING class. For every system this platform declares core=mgba in statecores.json, the
  # GBA.pak we actually ship in THIS overlay must launch that SAME core (EMU_EXE=mgba). If they
  # disagree, a self-updated card would upload states tagged one core but produced by another ->
  # fleet poison. Fail the build LOUD rather than ship a mismatched pair. (Keyed on the declared
  # core, so any future mgba-declared system is checked the same way; today that is gba.)
  DECLARED_GBA_CORE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["systems"].get("gba",{}).get("core",""))' "$pak/statecores.json") \
    || fail "lodoros-update $p: could not read gba core from statecores.json"
  if [ "$DECLARED_GBA_CORE" = mgba ]; then
    gbalaunch="$stage/Emus/$p/GBA.pak/launch.sh"
    [ -f "$gbalaunch" ] || fail "declared==launched gate ($p): statecores declares gba=mgba but no Emus/$p/GBA.pak/launch.sh shipped in overlay"
    if ! grep -Eq '^[[:space:]]*EMU_EXE=mgba([[:space:]]|$)' "$gbalaunch"; then
      launched=$(grep -E '^[[:space:]]*EMU_EXE=' "$gbalaunch" | head -1)
      echo "declared==launched MISMATCH ($p): statecores gba core=mgba but $gbalaunch has: ${launched:-<no EMU_EXE= line>}" >&2
      fail "declared==launched gate ($p): shipped GBA.pak does NOT launch mgba (manifest/core poison risk)"
    fi
    echo ">> declared==launched OK ($p): gba=mgba and Emus/$p/GBA.pak launch.sh sets EMU_EXE=mgba" >&2
  fi
  echo ">> lodoros-update gates ($p)" >&2
  sh "$GATE" branding        "$stage" >&2 || fail "lodoros-update $p failed branding gate"
  sh "$GATE" no-legacy       "$stage" >&2 || fail "lodoros-update $p failed no-legacy gate"
  sh "$GATE" cruft           "$stage" >&2 || fail "lodoros-update $p failed cruft gate"
  sh "$GATE" agent-pii       "$stage" >&2 || fail "lodoros-update $p failed agent-pii gate"
  sh "$GATE" redistributable "$stage" >&2 || fail "lodoros-update $p failed redistributable gate"
  zipf="$OUT/Lodor-LodorOS-update-$p-$VERSION.zip"
  rm -f "$zipf"
  ( cd "$stage" && zip -rqX "$zipf" . -x ".DS_Store" ) || fail "lodoros-update $p zip"
  ( cd "$OUT" && sha256sum "$(basename "$zipf")" > "$(basename "$zipf").sha256" )
  rm -rf "$stage"
  echo "$(basename "$zipf") $(hash "$zipf")"
}
LOSU_MIYOOMINI=$(assemble_lodoros_update miyoomini armhf)
LOSU_MY355=$(assemble_lodoros_update my355 arm64)

# ---- LodorOS full-card image (the flashable OS zip) — composed from a BASE card (proven
# launcher binaries + native/stock tools) + THIS release's update overlays, so the full card
# version ALWAYS matches the overlays. Closes the drift where the lodoros full card lagged the
# umbrella (0.9.5 card vs 0.9.7.1 overlays). The per-platform launcher REBUILD (device toolchains)
# is still a separate BLOCKED infra job — until it lands, launchers ride from the base card.
# No base card => full card SKIPPED and the release SAYS so; never a faked/stale card.
if [ -n "${LODOR_BASE_CARD:-}" ]; then
  FULLCARD=$(sh "$ROOT/release/build-fullcard.sh" "$OUT" "$VERSION")
  echo ">> full card: $FULLCARD" >&2
else
  FULLCARD="skipped (set LODOR_BASE_CARD=<prior full-card zip> to cut a version-matched full card)"
  echo ">> LodorOS full card SKIPPED — no LODOR_BASE_CARD; overlays built, full card NOT cut." >&2
fi

# ---- launchers (LodorOS fork) per platform — OPT-IN + HARDWARE-GATED ----
# LODOR_BUILD_LAUNCHERS=1 rebuilds minui.elf + minarch.real.elf for the Miyoo trio from the
# TRACKED lodoros/workspace/ tree with the pinned device toolchain images, gating every
# binary against the SHIPPED reference launchers (class/machine + interp + NEEDED parity +
# glibc floor + fork marker) — release/build-launchers.sh. HARD RULE: the output lands in
# $OUT/launchers/ ONLY and never enters an overlay, the full card, or any zip in EITHER
# mode — a rebuilt launcher reaches a card exclusively via a human-run hardware boot test
# on a SPARE card (see release/toolchains/README.md, "Miyoo trio"). The full card keeps
# composing its launchers from LODOR_BASE_CARD regardless of this switch.
if [ "${LODOR_BUILD_LAUNCHERS:-0}" = 1 ]; then
  LAUNCHERS=$(sh "$ROOT/release/build-launchers.sh" "$OUT" "$REF") || fail "launcher rebuild/gate failed"
  echo ">> launchers rebuilt + gated -> $OUT/launchers (HARDWARE BOOT TEST REQUIRED — in no shipped artifact):" >&2
  printf '%s\n' "$LAUNCHERS" | sed 's/^/   /' >&2
  LAUNCHERS=$(printf '%s' "$LAUNCHERS" | tr '\n' ';')
else
  LAUNCHERS="not rebuilt (riding base card)"
  echo ">> launchers NOT rebuilt (riding base card; set LODOR_BUILD_LAUNCHERS=1 — hardware-gated, see release/toolchains/README.md)" >&2
fi

# ---- provenance manifest ----
{
  echo "{"
  echo "  \"commit\": \"$(git rev-parse "$REF")\","
  echo "  \"ref\": \"$REF\","
  echo "  \"engine\": {\"armhf\": \"${ENG_ARMHF##* }\", \"arm64\": \"${ENG_ARM64##* }\", \"onion-armhf\": \"${ENG_ONION_ARMHF##* }\", \"spruce-armhf\": \"${ENG_SPRUCE_ARMHF##* }\", \"muos-arm64\": \"${ENG_MUOS_ARM64##* }\", \"knulli-arm64\": \"${ENG_KNULLI_ARM64##* }\", \"android-arm64\": \"${ENG_ANDROID_ARM64##* }\"},"
  echo "  \"wizard\": {\"arm64\": \"${WIZARD_ARM64##* }\", \"los-armhf\": \"${WIZ_LOS_ARMHF##* }\", \"los-arm64\": \"${WIZ_LOS_ARM64##* }\", \"onion-armhf\": \"${WIZ_ONION_ARMHF##* }\", \"spruce-armhf\": \"${WIZ_SPRUCE_ARMHF##* }\"},"
  echo "  \"onion_zip\": {\"$(echo "$ONION_ZIP" | cut -d" " -f1)\": \"${ONION_ZIP##* }\"},"
  echo "  \"spruce_zip\": {\"$(echo "$SPRUCE_ZIP" | cut -d" " -f1)\": \"${SPRUCE_ZIP##* }\"},"
  echo "  \"muos_muxapp\": {\"$(echo "$MUOS_MUXAPP" | cut -d" " -f1)\": \"${MUOS_MUXAPP##* }\"},"
  echo "  \"knulli_zip\": {\"$(echo "$KNULLI_ZIP" | cut -d" " -f1)\": \"${KNULLI_ZIP##* }\"},"
  echo "  \"android_apk\": {\"$(echo "$ANDROID_APK" | cut -d" " -f1)\": \"${ANDROID_APK##* }\"},"
  echo "  \"lodoros_update\": {"
  echo "    \"miyoomini\": {\"$(echo "$LOSU_MIYOOMINI" | cut -d" " -f1)\": \"${LOSU_MIYOOMINI##* }\"},"
  echo "    \"my355\": {\"$(echo "$LOSU_MY355" | cut -d" " -f1)\": \"${LOSU_MY355##* }\"}"
  echo "  },"
  echo "  \"fullcard\": \"$FULLCARD\","
  echo "  \"launchers\": \"$(echo $LAUNCHERS | sed "s/^ //")\""
  echo "}"
} > "$MAN"
echo "== manifest -> $MAN =="; cat "$MAN"
echo "== artifacts in $OUT =="; ls -la "$OUT"
