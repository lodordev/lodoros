#!/bin/sh
# Lodor pre-flash GATE — nothing reaches hardware unverified. Each check is a hard fail (exit!=0).
# Subcommands:
#   gate.sh contract                         validate config contract (schema + nesting + reader sanity)
#   gate.sh static-go   <bin>                assert a CGO-free static Go binary: NO interp, NO NEEDED libs
#   gate.sh elf <bin> [--max-glibc X.Y] [--symbol SYM]...  dynamic-ELF floor + required-symbol checks
#   gate.sh wifi-coverage <card-root> [platforms]   every listed wifi platform has Wifi.pak/bin/service-on
#   gate.sh no-legacy <dir>                  fail if any pre-rename Lodor pak (Sync/Sync Pending/RomM Sync) present
#   gate.sh shim-coverage <card-root> [platforms]   every listed platform: minarch.elf IS the save-sync shim
#                                            (ROMM_MINARCH_SHIM) + minarch.real.elf IS a real ELF. Run this
#                                            against EVERY tree that reaches a card or a zip — a minarch
#                                            redeploy that writes minarch.elf directly silently kills the
#                                            save bracket for every native session (the 0.9.0-beta bug).
#   gate.sh redistributable <dir>            public-zip gate: no non-free paks / BIOS / private hostname
#   gate.sh branding <dir>                   fail on user-visible RomM-named pak/file
#   gate.sh cruft <dir>                      fail on *-bak backup litter / rg40xxcube fossil (0.9.1 shipped 27)
#   gate.sh agent-pii <dir>                  fail on internal agent/personal names in shipped text or path names
#   gate.sh store-version <new> <published>  fail unless <new> strictly exceeds <published> on the
#                                            NUMERIC components alone — the NextUI Pak Store ignores
#                                            prerelease suffixes ("0.9.1-beta" compares as 0.9.1), so a
#                                            suffix-only bump ships a release the store never offers
#   gate.sh update-manifest <versions.json> [tag]   schema-1 sanity for the self-update manifest:
#                                            versions parse, every asset has an https URL + 64-hex
#                                            sha256 + size>0; with [tag], every URL points at that
#                                            release tag (a manifest must never mix releases)
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
  # FAIL CLOSED without readelf: `readelf|grep -q` on a missing readelf just exits 1 and the
  # checks "pass" having verified NOTHING (the build host — Unraid — ships no binutils; run
  # this gate inside the golang build image instead, as release.sh does).
  command -v readelf >/dev/null 2>&1 || fail "static-go: readelf unavailable — cannot verify $bin (run inside the golang image)"
  readelf -l "$bin" 2>/dev/null | grep -q "INTERP" && fail "static-go: $bin has a PT_INTERP (not static!)"
  if readelf -d "$bin" 2>/dev/null | grep -q "(NEEDED)"; then fail "static-go: $bin has NEEDED libs (CGO leaked in)"; fi
  ok "static-go: $bin is interp-less + dependency-free (CGO-free invariant holds)"
}

cmd_elf(){
  bin=${1:?bin}; shift; [ -f "$bin" ] || fail "no such binary: $bin"
  command -v readelf >/dev/null 2>&1 || fail "elf: readelf unavailable — cannot verify $bin (run inside the golang image)"
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
  # private hostname/tailnet pattern lives OUTSIDE the published tree ($ROOT/.pii-terms.conf line 2)
  # — baking it here shipped the private hostname in the public repo (fixed 2026-07-02). No terms
  # file => skip LOUDLY (public checkouts cannot leak a hostname they do not know).
  if [ -f "$ROOT/.pii-terms.conf" ]; then
    hostpat=$(sed -n 2p "$ROOT/.pii-terms.conf")
    [ -n "$hostpat" ] || fail "redistributable: $ROOT/.pii-terms.conf has no line-2 host pattern"
    leak=$(grep -rliE "$hostpat" "$d" 2>/dev/null | grep -viE "example|template|schema" || true)
    [ -z "$leak" ] || bad="$bad
PRIVATE hostname/tailnet leak:
$leak"
  else
    echo "  SKIP private-host scan: no $ROOT/.pii-terms.conf (internal-only; not an error on public checkouts)"
  fi
  if [ -n "$bad" ]; then printf '%b\n' "$bad" >&2; fail "redistributable gate: tree contains non-publishable content (see above)"; fi
  ok "redistributable: no non-free paks, no BIOS, no private-hostname leak under $d"
}

# cruft: fail if backup litter or dead-platform fossils are present in a shippable tree.
# 27 *.stock-bak/*.pre*-bak binaries and the .system/rg40xxcube fossil shipped in the
# public 0.9.1 zip — deploy-time backups belong on the CARD (revert insurance), never in
# a release. One suffix match ("*-bak") covers the whole naming convention.
cmd_cruft(){
  d=${1:?usage: gate.sh cruft <dir>}
  baks=$(find "$d" -name "*-bak" 2>/dev/null || true)
  if [ -n "$baks" ]; then echo "$baks"; fail "cruft: backup (*-bak) files present under $d"; fi
  foss=$(find "$d" -type d -name "rg40xxcube" 2>/dev/null || true)
  if [ -n "$foss" ]; then echo "$foss"; fail "cruft: .system/rg40xxcube fossil present under $d (alias platform; MinUI deletes it on first boot)"; fi
  ok "cruft: no *-bak files, no rg40xxcube fossil under $d"
}

# agent-pii: no internal tool-name or personal string reaches a shipped TEXT file or any
# shipped path/entry NAME. Word-boundary (-w) so a short term never matches inside a longer word;
# text-only (-I) because binary blobs (an NDS cheat DB carries arbitrary game text) must not
# trip the gate — binaries are covered by the redistributable/branding gates + provenance.
cmd_agent_pii(){
  d=${1:?usage: gate.sh agent-pii <dir>}
  # Term list lives OUTSIDE the repo tree that release/graft-lodoros.sh publishes ($ROOT/.pii-terms.conf,
  # one extended-regex alternation on line 1) — baking the list here would itself ship the very strings
  # this gate exists to block. No terms file => skip LOUDLY (public checkouts cannot and need not run this).
  if [ ! -f "$ROOT/.pii-terms.conf" ]; then echo "  SKIP agent-pii: no $ROOT/.pii-terms.conf (internal-only gate; not an error on public checkouts)"; return 0; fi
  pat=$(head -n1 "$ROOT/.pii-terms.conf")
  [ -n "$pat" ] || fail "agent-pii: $ROOT/.pii-terms.conf is empty"
  hits=$(grep -rlwiIE "$pat" "$d" 2>/dev/null || true)
  if [ -n "$hits" ]; then echo "$hits"; fail "agent-pii: internal/personal name in shipped text under $d (files above)"; fi
  names=$(find "$d" | grep -wiE "$pat" || true)
  if [ -n "$names" ]; then echo "$names"; fail "agent-pii: internal/personal name in a shipped path name under $d"; fi
  ok "agent-pii: no internal/personal names in shipped text or path names under $d"
}

# store-version: the Pak Store's updater compares versions NUMERICALLY with prerelease suffixes
# stripped, so "0.9.5-beta.2" after "0.9.5-beta" is invisible to every installed device. Publishing
# requires a strict numeric increase over the last version pak.json ever named.
cmd_store_version(){
  new=${1:?usage: gate.sh store-version <new-version> <last-published-version>}
  old=${2:?usage: gate.sh store-version <new-version> <last-published-version>}
  nn=$(printf '%s' "$new" | sed 's/^v//; s/-.*$//'); on=$(printf '%s' "$old" | sed 's/^v//; s/-.*$//')
  printf '%s' "$nn" | grep -qE '^[0-9]+(\.[0-9]+){0,3}$' || fail "store-version: unparseable new version '$new'"
  printf '%s' "$on" | grep -qE '^[0-9]+(\.[0-9]+){0,3}$' || fail "store-version: unparseable published version '$old'"
  [ "$nn" = "$on" ] && fail "store-version: numeric version unchanged ('$new' vs published '$old' both compare as $nn) — the store would never offer this release; bump a numeric component"
  hi=$(printf '%s\n%s\n' "$nn" "$on" | sort -V | tail -1)
  [ "$hi" = "$nn" ] || fail "store-version: new '$new' is BELOW published '$old' — installed devices would never see it"
  ok "store-version: $new supersedes $old under the store's prerelease-blind numeric compare ($nn > $on)"
}

# update-manifest: the versions.json devices poll and TRUST (sha256 per asset). Anything
# malformed here bricks the update path quietly (engine treats a bad manifest as unreachable),
# so publishing gates on shape: schema 1, parseable versions, https URLs, 64-hex hashes,
# non-zero sizes — and, given the tag, URL-pinning to exactly that release.
cmd_update_manifest(){
  mf=${1:?usage: gate.sh update-manifest <versions.json> [tag]}
  tag=${2:-}
  [ -f "$mf" ] || fail "update-manifest: no such file: $mf"
  python3 - "$mf" "$tag" <<'PY' || exit 1
import json, re, sys
mf, tag = sys.argv[1], sys.argv[2]
m = json.load(open(mf))
assert m.get("schema") == 1, f"schema {m.get('schema')} != 1"
seen = 0
for ch in ("stable", "beta"):
    c = m.get(ch)
    if c is None:
        continue
    v = c.get("version", "")
    assert re.fullmatch(r"\d+(\.\d+){0,3}(-[0-9A-Za-z.]+)?", v), f"{ch}: bad version {v!r}"
    for key, a in c.get("assets", {}).items():
        seen += 1
        assert a.get("url", "").startswith("https://"), f"{ch}/{key}: non-https url"
        assert re.fullmatch(r"[0-9a-f]{64}", a.get("sha256", "")), f"{ch}/{key}: bad sha256"
        assert isinstance(a.get("size"), int) and a["size"] > 0, f"{ch}/{key}: size must be > 0"
        if tag:
            assert f"/releases/download/{tag}/" in a["url"], f"{ch}/{key}: url not pinned to {tag}"
assert seen > 0, "manifest names no assets"
for k, v in (m.get("notify") or {}).items():
    assert re.fullmatch(r"\d+(\.\d+){0,3}(-[0-9A-Za-z.]+)?", v), f"notify/{k}: bad version {v!r}"
print(f"  ok: update-manifest: schema 1, {seen} asset(s) well-formed" + (f", pinned to {tag}" if tag else ""))
PY
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
  cruft) shift; cmd_cruft "$@";;
  agent-pii) shift; cmd_agent_pii "$@";;
  store-version) shift; cmd_store_version "$@";;
  update-manifest) shift; cmd_update_manifest "$@";;
  *) echo "usage: gate.sh {contract|branding <dir>|static-go <bin>|elf <bin> [--max-glibc X.Y] [--symbol SYM]...|wifi-coverage <card-root> [platforms]|no-legacy <dir>|shim-coverage <card-root> [platforms]|redistributable <dir>|cruft <dir>|agent-pii <dir>|store-version <new> <published>}"; exit 2;;
esac
