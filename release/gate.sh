#!/bin/sh
# Lodor pre-flash GATE — nothing reaches hardware unverified. Each check is a hard fail (exit!=0).
# Subcommands:
#   gate.sh contract                         validate config contract (schema + nesting + reader sanity)
#   gate.sh static-go   <bin>                assert a CGO-free static Go binary: NO interp, NO NEEDED libs
#   gate.sh elf <bin> [--max-glibc X.Y] [--symbol SYM]...  dynamic-ELF floor + required-symbol checks
#   gate.sh wifi-coverage <card-root> [platforms]   every listed wifi platform has Wifi.pak/bin/service-on
#   gate.sh no-legacy <dir>                  fail if any pre-rename Lodor pak (Sync/Sync Pending/RomM Sync) present
#   gate.sh branding <dir>                   fail on user-visible RomM-named pak/file
# Wire this into release.sh so a failing artifact is never copied to an SD card.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail(){ echo "GATE FAIL: $*" >&2; exit 1; }
ok(){   echo "  ok: $*"; }

cmd_contract(){
  schema="$ROOT/contract/config.schema.json"; ex="$ROOT/contract/example-config.json"
  [ -f "$schema" ] && [ -f "$ex" ] || fail "contract files missing"
  if python3 - "$schema" "$ex" <<'PY'
import json,sys
schema=json.load(open(sys.argv[1])); ex=json.load(open(sys.argv[2]))
try:
    import jsonschema; jsonschema.validate(ex,schema); print("  ok: example validates against schema (jsonschema)")
except ImportError:
    # minimal structural fallback when jsonschema isnt installed
    h=(ex.get("hosts") or [None])[0]
    assert isinstance(h,dict), "hosts[0] missing"
    for k in ("root_uri","token","device_id"):
        assert h.get(k), f"hosts[0].{k} missing/empty"
    print("  ok: example structurally conforms (fallback; install python3-jsonschema for full check)")
PY
  then :; else fail "example-config does not conform to schema"; fi
  # nesting assertion: the three connection keys MUST be under hosts[0], not top-level, in the example
  python3 - "$ex" <<'PY' || exit 1
import json,sys
ex=json.load(open(sys.argv[1]))
for k in ("root_uri","token","device_id"):
    assert k not in ex, f"{k} must NOT be top-level (lives under hosts[0])"
print("  ok: connection identity is nested under hosts[0] (no flat-key drift)")
PY
  # reader sanity: warn loudly if the launcher still reads these keys flat (the known violation)
  ml="$ROOT/lodoros/launcher/minui.c"
  if [ -f "$ml" ] && grep -q "Lodor_keyHasValue(buf, \"root_uri\")" "$ml" 2>/dev/null; then
    echo "  WARN: lodoros launcher still scans for FLAT root_uri (contract violation; see contract/README.md)"
  fi
  ok "contract checks complete"
}

cmd_static_go(){
  bin=${1:?bin}; [ -f "$bin" ] || fail "no such binary: $bin"
  readelf -l "$bin" 2>/dev/null | grep -q "INTERP" && fail "static-go: $bin has a PT_INTERP (not static!)"
  if readelf -d "$bin" 2>/dev/null | grep -q "(NEEDED)"; then fail "static-go: $bin has NEEDED libs (CGO leaked in)"; fi
  ok "static-go: $bin is interp-less + dependency-free (CGO-free invariant holds)"
}

cmd_elf(){
  bin=${1:?bin}; shift; [ -f "$bin" ] || fail "no such binary: $bin"
  maxglibc=""; syms=""
  while [ $# -gt 0 ]; do case "$1" in
    --max-glibc) maxglibc=$2; shift 2;;
    --symbol)    syms="$syms $2"; shift 2;;
    *) fail "elf: unknown arg $1";; esac; done
  # interpreter present (dynamic) — report it for the device-match record
  interp=$(readelf -l "$bin" 2>/dev/null | sed -n "s/.*program interpreter: \(.*\)]/\1/p"); ok "interp: ${interp:-none}"
  readelf -d "$bin" 2>/dev/null | sed -n "s/.*(NEEDED).*\[\(.*\)\]/  needs: \1/p"
  if [ -n "$maxglibc" ]; then
    have=$(readelf -V "$bin" 2>/dev/null | grep -oE "GLIBC_[0-9]+\.[0-9]+" | sort -V | tail -1 | sed "s/GLIBC_//")
    [ -n "$have" ] || have=0.0
    top=$(printf "%s\n%s\n" "$have" "$maxglibc" | sort -V | tail -1)
    [ "$top" = "$maxglibc" ] || fail "elf: needs glibc $have > device floor $maxglibc (would not load)"
    ok "glibc floor: needs $have <= device $maxglibc"
  fi
  for s in $syms; do
    readelf -sW "$bin" 2>/dev/null | grep -qw "$s" || nm "$bin" 2>/dev/null | grep -qw "$s" || strings "$bin" | grep -qw "$s" || fail "elf: required symbol/string absent: $s"
    ok "symbol present: $s"
  done
  ok "elf checks complete for $bin"
}


# wifi-coverage: fail closed if any listed wifi-capable platform on the assembled card root is MISSING its
# stock Wifi.pak (the bug this fixes — my282/rg35xxplus shipped with NO Wifi.pak, so wifi_acquire died
# "no service-on tool" and the Wi-Fi menu was absent). 2nd arg = explicit platform list (default = the
# full wifi-capable base). The assembler passes only the launcher-ready set so blocked platforms (no
# device toolchain) don't false-fail a partial-but-correct staging tree.
cmd_wifi_coverage(){
  card=${1:?usage: gate.sh wifi-coverage <card-root> [platforms]}
  plats=${2:-"miyoomini my282 my355 rg35xxplus zero28 magicmini"}
  miss=""
  for p in $plats; do
    [ -x "$card/Tools/$p/Wifi.pak/bin/service-on" ] || miss="$miss $p"
  done
  [ -z "$miss" ] || fail "wifi-coverage: Tools/<plat>/Wifi.pak/bin/service-on missing for:$miss"
  ok "wifi-coverage: every listed wifi-capable platform has Tools/<plat>/Wifi.pak/bin/service-on ($plats)"
}

# no-legacy: fail if any pre-rename Lodor pak is present anywhere under <dir>. These (Sync.pak,
# "Sync Pending.pak", "RomM Sync.pak") are the OLD Lodor menu/engine paks; their lingering presence
# alongside the current Lodor.pak is the ROOT CAUSE of the per-device menu drift. The assembler never
# places them; this gate makes their absence enforceable on any staged/card tree.
cmd_no_legacy(){
  d=${1:?usage: gate.sh no-legacy <dir>}
  hits=$(find "$d" \( -name "Sync.pak" -o -name "Sync Pending.pak" -o -name "RomM Sync.pak" \) 2>/dev/null || true)
  if [ -n "$hits" ]; then echo "$hits"; fail "legacy Lodor pak(s) present under $d (purge: Sync.pak / Sync Pending.pak / RomM Sync.pak)"; fi
  ok "no-legacy: no Sync.pak / Sync Pending.pak / RomM Sync.pak under $d"
}

# shim-coverage: fail closed if any launcher-ready platform's baked minarch is wrong. The auto
# save-sync ONLY works when minarch.elf is the session-sync shim and minarch.real.elf is the real
# emulator binary it execs (the bug this fixes: NO platform had the shim active — orphaned
# minarch.real.elf on miyoomini, none at all elsewhere — so playing a game ran no pull/push/stage).
# For each listed platform FAIL unless: .system/<plat>/bin/minarch.elf exists AND carries the
# ROMM_MINARCH_SHIM marker, AND minarch.real.elf exists AND is an ELF (not a script). Uses only
# portable tools (grep + magic-byte read) so it runs on the build host without binutils.
cmd_shim_coverage(){
  card=${1:?usage: gate.sh shim-coverage <card-or-staging-root> [platforms]}
  plats=${2:-"miyoomini my282 my355 rg35xxplus"}
  bad=""
  for p in $plats; do
    shf="$card/.system/$p/bin/minarch.elf"
    real="$card/.system/$p/bin/minarch.real.elf"
    if [ ! -f "$shf" ]; then bad="$bad $p(no-minarch.elf)"; continue; fi
    if ! grep -q "ROMM_MINARCH_SHIM" "$shf" 2>/dev/null; then bad="$bad $p(minarch.elf-not-shim)"; continue; fi
    if [ ! -f "$real" ]; then bad="$bad $p(no-minarch.real.elf)"; continue; fi
    case "$(head -c4 "$real" 2>/dev/null)" in
      *ELF*) : ;;
      *) bad="$bad $p(minarch.real.elf-not-ELF)";;
    esac
  done
  [ -z "$bad" ] || fail "shim-coverage:$bad"
  ok "shim-coverage: every platform's minarch.elf is the ROMM_MINARCH_SHIM shim + minarch.real.elf is a real ELF ($plats)"
}

cmd_branding(){
  # User-visible RomM branding = a pak/dir/file NAMED with capital "RomM" (e.g. "RomM Sync.pak").
  # Internal lowercase romm-* script/lib names are intentional plumbing and fine; the engine\'s
  # emitted folder/file naming is covered by the catalog tests (which now assert "Lodor").
  d=${1:-$ROOT}
  names=$(find "$d" -name "*RomM*" 2>/dev/null || true)
  if [ -n "$names" ]; then echo "$names"; fail "user-visible RomM-named pak/file under $d (rename to Lodor)"; fi
  ok "no RomM-named paks/files under $d"
}

cmd_redistributable(){
  # PUBLIC-RELEASE gate: hard-fail if the assembled tree carries anything we must NOT publish.
  # (1) non-redistributable community paks — they ship a _LODOROS-PROVENANCE.txt marked
  #     "LICENSE: NONE" / "NEVER commit/push to lodordev" (the ryanmsartor H700 vendor-shim
  #     paks: DC/N64/PSPRA/P8-NATIVE/...). CARD-SIDE ONLY; a public zip must never contain them.
  # (2) BIOS/firmware blobs (BYOB — we never ship these).
  # (3) the private RomM hostname / tailnet name leaking into a shipped file.
  d=${1:?usage: gate.sh redistributable <dir>}
  bad=""
  # scan ONLY provenance files for a non-free declaration (precise — a script/doc that merely
  # MENTIONS drastic must not trip the gate); plus a backstop on the proprietary binary by name.
  prov=$(find "$d" -name "_LODOROS-PROVENANCE.txt" -exec grep -liE "LICENSE: NONE|NEVER commit/push|not redistributable|PROPRIETARY|closed-source" {} + 2>/dev/null || true)
  bins=$(find "$d" -type f \( -name drastic -o -name drastic64 \) 2>/dev/null || true)
  nonfree=$(printf '%s\n%s\n' "$prov" "$bins" | grep -v '^$' || true)
  [ -z "$nonfree" ] || bad="$bad\nNON-FREE paks (provenance/binary - card-side only):\n$nonfree"
  bios=$(find "$d" \( -iname "dc_boot.bin" -o -iname "dc_flash.bin" -o -iname "*.bios" \
        -o -iname "bios9.bin" -o -iname "bios7.bin" -o -iname "scph*.bin" -o -iname "*.nvmem" \) 2>/dev/null || true)
  [ -z "$bios" ] || bad="$bad
BIOS/firmware blobs (BYOB - never ship):
$bios"
  leak=$(grep -rliE "romm\.cleary\.esq|tail4b32d1\.ts\.net" "$d" 2>/dev/null | grep -viE "example|template|schema" || true)
  [ -z "$leak" ] || bad="$bad
PRIVATE hostname/tailnet leak:
$leak"
  if [ -n "$bad" ]; then printf '%b\n' "$bad" >&2; fail "redistributable gate: tree contains non-publishable content (see above)"; fi
  ok "redistributable: no non-free paks, no BIOS, no private-hostname leak under $d"
}

case "${1:-}" in
  contract) cmd_contract;;
  branding) shift; cmd_branding "$@";;
  static-go) shift; cmd_static_go "$@";;
  elf) shift; cmd_elf "$@";;
  wifi-coverage) shift; cmd_wifi_coverage "$@";;
  no-legacy) shift; cmd_no_legacy "$@";;
  shim-coverage) shift; cmd_shim_coverage "$@";;
  redistributable) shift; cmd_redistributable "$@";;
  *) echo "usage: gate.sh {contract|branding <dir>|static-go <bin>|elf <bin> [--max-glibc X.Y] [--symbol SYM]...|wifi-coverage <card-root> [platforms]|no-legacy <dir>|shim-coverage <card-root> [platforms]|redistributable <dir>}"; exit 2;;
esac
