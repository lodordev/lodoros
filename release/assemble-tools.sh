#!/bin/sh
# Lodor card assembler — SINGLE SOURCE OF TRUTH for the per-platform Tools/<plat>/ + .system/<plat>/bin
# layout on a LodorOS card. "One release, all devices": this script is the ONLY place that decides which
# pak lands on which platform, so the per-device drift (lingering legacy paks; missing Wifi.pak) can never
# silently reappear. release/gate.sh enforces the result (wifi-coverage + no-legacy, fail-closed).
#
# ROOT CAUSE THIS FIXES (read off the real card 2026-06-27):
#   - miyoomini/my282/rg35xxplus still carried the PRE-RENAME Lodor menu paks "Sync.pak" + "Sync Pending.pak"
#     + the old engine pak "RomM Sync.pak" alongside the current Lodor.pak -> "Lodor on the main screen,
#     Sync somewhere else / different menus per device". These are PURGED here and a gate refuses to stage them.
#   - my282 + rg35xxplus shipped with NO Wifi.pak -> wifi_acquire died "no service-on tool" -> no Wi-Fi menu.
#     Wifi.pak is now placed on every wifi-capable, launcher-ready platform.
#
# WHAT IS / ISN'T SHIPPED PER PLATFORM:
#   - Lodor.pak   : engine pak. Repo skeleton (lodoros/paks/Lodor.pak) + the RIGHT-ARCH static lodor-sync.
#                   config.json (token) and catalog-index.json are PER-DEVICE and live ON THE CARD — they
#                   are NEVER written here (no secrets on the build host). Deploy must PRESERVE them.
#   - Wifi.pak    : the ONE platform-aware MinUI Wi-Fi pak (bin/service-on branches on $PLATFORM at runtime),
#                   copied verbatim to every wifi-capable launcher-ready platform.
#   - Reset WiFi.pak: 8188fu USB re-enum recovery (shells grout32 --wifi-reset, SDL-mmiyoo only) -> miyoomini ONLY.
#   - native/base tools: each platform's stock MinUI tools + its OWN native tools (Reset Stick on my282;
#                   Apply Panel Fix / Enable SSH / Swap Menu on rg35xxplus) are carried through verbatim
#                   from NATIVE_SRC (a clean, legacy-free snapshot of the card's Tools/<plat>/).
#   - .system/<plat>/bin: gated minui.elf (this release's launcher) + minarch.elf (current proven per-device
#                   build; the RA-enabled minarch is HELD — see ledger).
#
# Usage:
#   STAGE=/path/to/card-staging \
#   ENGINE_DIR=/path/with/lodor-sync-armhf,lodor-sync-arm64 \
#   NATIVE_SRC=/path/to/legacy-free/Tools-snapshot/<plat>/... \
#   MINUI_SRC=/path/to/minui/build/<plat>/minui.elf \
#   MINARCH_SRC=/path/with/<plat>.minarch \
#   assemble-tools.sh
#
# If MINUI_SRC/MINARCH_SRC/NATIVE_SRC are unset the script still assembles Tools paks it can source from the
# repo + ENGINE_DIR and SKIPS the rest with a loud note (never silently ships a partial platform).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/lodoros/paks"
STAGE=${STAGE:?set STAGE=<card-staging-root>}
ENGINE_DIR=${ENGINE_DIR:?set ENGINE_DIR=<dir with lodor-sync-armhf/arm64>}
NATIVE_SRC=${NATIVE_SRC:-}
MINUI_SRC=${MINUI_SRC:-}      # template with literal <plat>, e.g. /mb/workspace/all/minui/build/<plat>/minui.elf
MINARCH_SRC=${MINARCH_SRC:-}  # dir containing <plat>.minarch

# ---- the device matrix --------------------------------------------------------------------------------
# WIFI_PLATFORMS: every wifi-capable LodorOS platform that is its OWN distinct MinUI target.
#   EXCLUDES: gkdpixel + Anbernic RG28XX + original RG35XX (no radio). tg5040 (TrimUI Smart Pro/
#   Brick), rgb30 (PowKiddy RGB30) and trimuismart (TrimUI Smart) are now FIRST-CLASS LodorOS targets.
WIFI_PLATFORMS="miyoomini my282 my355 rg35xxplus zero28 magicmini tg5040 rgb30 trimuismart"
# WIFI_ALIASES: device families MinUI serves under ANOTHER platform's binaries+folder via runtime
#   model detection -> they need NO separate build/folder; listing documents that coverage:
#   rg40xxcube (Anbernic RG CubeXX, H700) -> runs the rg35xxplus build (is_cubexx flag, 720x720).
#   MinUI rg35xxplus/install/install.sh DELETES any .system/rg40xxcube and migrates its userdata to
#   rg35xxplus; shipping a separate rg40xxcube tree is WRONG (upstream removes it). NOT in workspace
#   PLATFORMS; only makefile `tidy` drops an install.sh shim into rg40xxcube/bin for old-card update.
WIFI_ALIASES="rg40xxcube:rg35xxplus"
# LAUNCHER_READY: platforms with a current, device-toolchain-built, GATED minui.elf. ONLY these are
#   assembled — shipping a generic-cross launcher bricks at the loader (the my355 lesson). The rest are
#   reported as BLOCKED (need a real union-<plat>-toolchain image; an infra job).
LAUNCHER_READY=${LAUNCHER_READY:-"miyoomini my282 my355 rg35xxplus zero28 magicmini"}
# engine arch per platform
eng_for(){ case "$1" in my355|zero28|magicmini|rgb30|tg5040) echo arm64;; *) echo armhf;; esac; }
# Reset WiFi.pak recipients (8188fu only)
RESETWIFI_PLATS="miyoomini"
LEGACY="Sync.pak|Sync Pending.pak|RomM Sync.pak"

[ -d "$SRC/Lodor.pak" ] || { echo "ABORT: missing $SRC/Lodor.pak" >&2; exit 1; }
[ -d "$SRC/Wifi.pak" ]  || { echo "ABORT: missing $SRC/Wifi.pak"  >&2; exit 1; }

note(){ echo "  -- $*"; }
place_native(){ # <plat>
  p=$1
  [ -n "$NATIVE_SRC" ] && [ -d "$NATIVE_SRC/$p" ] || { note "no NATIVE_SRC/$p — base/native tools NOT staged (preserve on card)"; return; }
  for d in "$NATIVE_SRC/$p"/*/; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    # hard refuse legacy even if it slipped into the snapshot
    case "$b" in "Sync.pak"|"Sync Pending.pak"|"RomM Sync.pak") echo "REFUSE legacy in NATIVE_SRC: $b" >&2; exit 1;; esac
    rm -rf "$STAGE/Tools/$p/$b"; cp -a "$d" "$STAGE/Tools/$p/$b"
    note "native/base <- $b"
  done
}

echo "== assembling unified card-staging tree at $STAGE =="
for p in $LAUNCHER_READY; do
  arch=$(eng_for "$p"); eng="$ENGINE_DIR/lodor-sync-$arch"
  [ -f "$eng" ] || { echo "ABORT: missing engine $eng for $p" >&2; exit 1; }
  echo "-- $p (engine: $arch) --"
  mkdir -p "$STAGE/Tools/$p" "$STAGE/.system/$p/bin"

  # native + base tools (legacy-free snapshot)
  place_native "$p"

  # Lodor.pak: repo skeleton + right-arch engine; NO config.json / catalog-index.json (preserve on card)
  rm -rf "$STAGE/Tools/$p/Lodor.pak"; cp -a "$SRC/Lodor.pak" "$STAGE/Tools/$p/Lodor.pak"
  rm -f "$STAGE/Tools/$p/Lodor.pak/config.json" "$STAGE/Tools/$p/Lodor.pak/catalog-index.json"
  cp "$eng" "$STAGE/Tools/$p/Lodor.pak/lodor-sync"; chmod +x "$STAGE/Tools/$p/Lodor.pak/lodor-sync"
  chmod +x "$STAGE/Tools/$p/Lodor.pak/launch.sh" "$STAGE/Tools/$p/Lodor.pak"/bin/* 2>/dev/null || true
  note "Lodor.pak <- skeleton + lodor-sync-$arch (config.json/catalog-index.json preserved on card)"

  # system-tiers.conf: PER-PLATFORM performance grade map (drives the launcher's per-system
  # quality dot — FIX 3). One data source baked at build time; the right platform's file is
  # placed here. Absent file => launcher renders no marks for that platform (safe degrade).
  if [ -f "$ROOT/release/system-tiers/$p.conf" ]; then
    cp "$ROOT/release/system-tiers/$p.conf" "$STAGE/Tools/$p/Lodor.pak/system-tiers.conf"
    note "system-tiers.conf <- $p grade map"
  else
    note "no system-tiers/$p.conf — menu quality marks omitted for $p"
  fi

  # Wifi.pak: verbatim platform-aware pak
  rm -rf "$STAGE/Tools/$p/Wifi.pak"; cp -a "$SRC/Wifi.pak" "$STAGE/Tools/$p/Wifi.pak"
  chmod +x "$STAGE/Tools/$p/Wifi.pak/launch.sh" \
           "$STAGE/Tools/$p/Wifi.pak/bin/service-on" "$STAGE/Tools/$p/Wifi.pak/bin/service-off" \
           "$STAGE/Tools/$p/Wifi.pak/bin/on-boot" "$STAGE/Tools/$p/Wifi.pak/bin/wifi-enabled" 2>/dev/null || true
  note "Wifi.pak <- platform-aware (service-on present)"

  # Reset WiFi.pak (8188fu only)
  case " $RESETWIFI_PLATS " in *" $p "*)
    if [ -d "$SRC/Reset WiFi.pak" ]; then
      rm -rf "$STAGE/Tools/$p/Reset WiFi.pak"; cp -a "$SRC/Reset WiFi.pak" "$STAGE/Tools/$p/Reset WiFi.pak"
      note "Reset WiFi.pak <- 8188fu recovery"
    fi;;
  esac

  # launcher binaries
  if [ -n "$MINUI_SRC" ]; then
    src=$(echo "$MINUI_SRC" | sed "s|<plat>|$p|g")
    [ -f "$src" ] && { cp "$src" "$STAGE/.system/$p/bin/minui.elf"; note "minui.elf <- $(basename "$src")"; } || echo "  WARN: MINUI_SRC missing for $p ($src)"
  else note "minui.elf NOT staged (MINUI_SRC unset)"; fi

  # per-platform deep-sleep helper (.system/<plat>/bin/suspend). Ships ONLY for platforms that have one
  # at release/system-bin/<plat>/suspend (rg35xxplus H700: echo mem > /sys/power/state w/ retry). The
  # launcher gates use on PLAT_supportsDeepSleep(), so platforms WITHOUT a helper (miyoomini/Flip) are
  # byte-identical; absent helper => api.c PWR_deepSleep falls back to the in-process echo-mem path.
  if [ -f "$ROOT/release/system-bin/$p/suspend" ]; then
    cp "$ROOT/release/system-bin/$p/suspend" "$STAGE/.system/$p/bin/suspend"; chmod +x "$STAGE/.system/$p/bin/suspend"
    note "suspend <- deep-sleep helper ($p)"
  fi
  # minarch SAVE-SYNC SHIM — baked into the image so the auto save-sync is ALWAYS active (no manual
  # on-device install.sh that every minarch redeploy clobbers — the unowned-stateful-step drift that
  # left every device with no shim). minarch.elf becomes the session-sync shim ($p-correct, carrying
  # the ROMM_MINARCH_SHIM marker); minarch.real.elf is the platform's REAL minarch binary the shim
  # execs. The source minarch (MINARCH_SRC/$p.minarch) IS the real one — back it up to .real.elf and
  # install the shim as .elf. Idempotent: if the source is already a shim we refuse (never bake a shim
  # back in as the real binary — that would infinite-loop / brick every game).
  if [ -n "$MINARCH_SRC" ] && [ -f "$MINARCH_SRC/$p.minarch" ]; then
    realsrc="$MINARCH_SRC/$p.minarch"
    case "$(head -c4 "$realsrc" 2>/dev/null)" in
      *ELF*) : ;;
      *) echo "ABORT: $realsrc is not an ELF — refusing to bake a non-ELF as the real minarch for $p" >&2; exit 1;;
    esac
    if grep -q "ROMM_MINARCH_SHIM" "$realsrc" 2>/dev/null; then
      echo "ABORT: $realsrc is ALREADY the shim, not the real minarch for $p (restore stock minarch first)" >&2; exit 1
    fi
    [ -f "$SRC/Lodor.pak/bin/minarch-shim.sh" ] || { echo "ABORT: missing shim template $SRC/Lodor.pak/bin/minarch-shim.sh" >&2; exit 1; }
    cp "$realsrc" "$STAGE/.system/$p/bin/minarch.real.elf"; chmod +x "$STAGE/.system/$p/bin/minarch.real.elf"
    # Install the shim AS minarch.elf with THIS platform baked in as the PLATFORM default (so it is
    # $p-correct even if the launch env doesn't export PLATFORM). Atomic-ish: write then chmod.
    sed "s|\${PLATFORM:-miyoomini}|\${PLATFORM:-$p}|g" "$SRC/Lodor.pak/bin/minarch-shim.sh" > "$STAGE/.system/$p/bin/minarch.elf"
    chmod +x "$STAGE/.system/$p/bin/minarch.elf"
    grep -q "ROMM_MINARCH_SHIM" "$STAGE/.system/$p/bin/minarch.elf" || { echo "ABORT: baked minarch.elf for $p lost the ROMM_MINARCH_SHIM marker" >&2; exit 1; }
    note "minarch.elf <- session-sync SHIM ($p-correct, marker present); minarch.real.elf <- real per-device minarch"
  else note "minarch SHIM NOT staged (MINARCH_SRC unset — minarch.elf/minarch.real.elf preserve current on card; WARNING: save-sync inactive unless the card already carries the baked shim)"; fi

  # hard assert: no legacy pak landed
  for L in "Sync.pak" "Sync Pending.pak" "RomM Sync.pak"; do
    [ -e "$STAGE/Tools/$p/$L" ] && { echo "ABORT: legacy $L present in $p" >&2; exit 1; }
  done
done

# BLOCKED platforms (wifi-capable but no device toolchain -> no gated launcher). Report, never ship.
for p in $WIFI_PLATFORMS; do
  case " $LAUNCHER_READY " in *" $p "*) ;; *) echo "BLOCKED: $p — no device toolchain image -> no gated minui.elf; NOT staged.";; esac
done

# ALIASES: covered by another platform's build (no separate tree). Report for transparency.
for kv in $WIFI_ALIASES; do echo "ALIAS: ${kv%%:*} -> ${kv##*:} (covered by that build; MinUI merges it at runtime; no separate Tools/.system tree)."; done
echo "== gating staged tree =="
sh "$ROOT/release/gate.sh" wifi-coverage "$STAGE" "$LAUNCHER_READY"
sh "$ROOT/release/gate.sh" no-legacy "$STAGE"
# Only assert shim-coverage when minarch was actually staged (MINARCH_SRC given). An overlay run that
# preserves the card's minarch can't be checked here — the gate is run against the live card instead.
[ -n "$MINARCH_SRC" ] && sh "$ROOT/release/gate.sh" shim-coverage "$STAGE" "$LAUNCHER_READY"
echo "== assembled launcher-ready platforms: $LAUNCHER_READY =="
