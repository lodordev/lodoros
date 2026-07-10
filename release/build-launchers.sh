#!/bin/sh
# build-launchers.sh — rebuild the LodorOS per-platform launcher pair (minui.elf +
# minarch.real.elf) from the TRACKED lodoros/workspace/ tree with the pinned
# device-matched toolchain images, and gate every binary against the SHIPPED
# reference launchers before it is allowed to exist in the output dir.
#
# =========================== HARD RULE — READ FIRST ==============================
# OUTPUT IS HARDWARE-GATED. Nothing this script produces may enter an overlay, a
# full card, or a release zip until a human has booted it on the real device from
# a SPARE card. The full-card assembler keeps composing launchers from
# LODOR_BASE_CARD in every mode; this script's output goes to <OUT>/launchers/
# and STOPS there. See release/toolchains/README.md ("Miyoo trio").
# ==================================================================================
#
# Pinned images (Miyoo-only fleet, pivot 2026-07-05):
#   miyoomini -> miyoomini-toolchain  shauninman/union-miyoomini-toolchain (armhf, SDL1.2)
#   my282     -> my282-toolchain      shauninman/union-my282-toolchain, buildroot (armhf, SDL2)
#   my355     -> my355-xcross         debian:bookworm-slim + crossbuild-essential-arm64 +
#                                     libsdl2*-dev:arm64 (aarch64, SDL2; output MUST stay
#                                     GLIBC <= 2.34 — the Flip V2 device floor)
#   *** TRAP: NEVER use the image named `my355-toolchain`. It is BROKEN — a generic
#   *** aarch64-linux-gnu-gcc with the HOST x86 SDL2 dev headers and no arm64 SDL2.
#   *** Forcing it links wrong-ABI SDL => the device black-screens at boot.
#
# Build shape (per the union upstream convention + lodoros/workspace makefiles):
#   <plat>/libmsettings (installs msettings.h+libmsettings.so into the image PREFIX)
#   [my282 only] my282/libmstick (minui/minarch link -lmstick on my282)
#   all/minui  make PLATFORM=<plat>   -> all/minui/build/<plat>/minui.elf
#   all/minarch make PLATFORM=<plat>  -> all/minarch/build/<plat>/minarch.elf
# The workspace is staged TRACKED-ONLY via git archive (never builds from a dirty
# tree, never dirties the repo tree); hash.txt is generated so minarch's version
# string carries the real commit (the shipped 07-05 build lacked it: "MinUI (date )").
#
# Gates per binary (each fails the whole run):
#   - ELF class + machine IDENTICAL to the shipped reference binary
#   - program interpreter IDENTICAL to the reference
#   - NEEDED list IDENTICAL to the reference (any delta printed, run fails)
#   - versioned-symbol GLIBC max <= the reference's own max (derived, not guessed);
#     my355 is additionally hard-capped at 2.34 (device floor — a >2.34 binary
#     would not load on the Flip V2 even if some future reference drifted)
#   - fork marker present (minui: pending-saves.txt; minarch: rcheevos)
# All readelf work runs inside golang:1.25-bookworm — the build host (Unraid) has
# no binutils and gate.sh fails closed on a missing readelf.
#
# References come from LODOR_LAUNCHER_REF_CARD (a shipped LodorOS full-card zip;
# defaults to LODOR_BASE_CARD): .system/<plat>/bin/minui.elf + minarch.real.elf.
# NOTE the card's minarch.elf is the save-sync SHIM (ROMM_MINARCH_SHIM), not a
# build product — the REAL emulator binary is minarch.real.elf, which is why this
# script names its minarch build product minarch.real.elf: a human copying files
# onto a card by name can then never clobber the shim.
#
# STDOUT: exactly one line per platform,
#   LAUNCHER <plat> minui.elf=<sha256> minarch.real.elf=<sha256>
# (captured by release.sh for the manifest). ALL progress/gate chatter -> stderr.
#
# Usage: build-launchers.sh <OUT_DIR> [<git-ref>]     (ref defaults to HEAD)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="${1:?usage: build-launchers.sh <OUT_DIR> [<git-ref>]}"
REF="${2:-HEAD}"
SHORTSHA=$(git -C "$ROOT" rev-parse --short "$REF")
PLATFORMS="miyoomini my282 my355"
GATEIMG="golang:1.25-bookworm"
fail(){ echo "LAUNCHERS ABORT: $*" >&2; exit 1; }
hash(){ sha256sum "$1" | cut -d" " -f1; }

img_for(){ # pinned image per platform — my355 MUST be the xcross (see TRAP above)
  case "$1" in
    miyoomini) echo miyoomini-toolchain;;
    my282)     echo my282-toolchain;;
    my355)     echo my355-xcross;;
    *) fail "no pinned toolchain image for platform '$1'";;
  esac
}

REFCARD="${LODOR_LAUNCHER_REF_CARD:-${LODOR_BASE_CARD:-}}"
[ -n "$REFCARD" ] || fail "set LODOR_LAUNCHER_REF_CARD (or LODOR_BASE_CARD) to a shipped LodorOS full-card zip — the NEEDED-parity + glibc references come from its launchers"
[ -f "$REFCARD" ] || fail "reference card zip not found: $REFCARD"

WS="$OUT/.launcher-ws"; REFD="$OUT/.launcher-ref"; LOUT="$OUT/launchers"
rm -rf "$WS" "$REFD" "$LOUT"; mkdir -p "$WS" "$REFD" "$LOUT"

# ---- stage the TRACKED workspace (never a dirty tree, never dirties the repo) ----
echo ">> staging tracked lodoros/workspace @ $SHORTSHA" >&2
git -C "$ROOT" archive "$REF" lodoros/workspace | tar -x --strip-components=2 -C "$WS" -f - \
  || fail "git archive of lodoros/workspace failed"
[ -f "$WS/all/minui/minui.c" ] || fail "staged workspace is missing all/minui/minui.c"
printf '%s\n' "$SHORTSHA" > "$WS/hash.txt"   # minarch BUILD_HASH (makefile: cat ../../hash.txt)

# ---- extract the shipped reference launchers ----
echo ">> extracting reference launchers from $(basename "$REFCARD")" >&2
for p in $PLATFORMS; do
  ( cd "$REFD" && unzip -oq "$REFCARD" ".system/$p/bin/minui.elf" ".system/$p/bin/minarch.elf" ".system/$p/bin/minarch.real.elf" ) \
    || fail "reference extract failed for $p (not a LodorOS full card?)"
  # sanity: the card layout is shim + real — references must be the RIGHT binaries
  grep -q "ROMM_MINARCH_SHIM" "$REFD/.system/$p/bin/minarch.elf" \
    || fail "$p: reference card minarch.elf is not the save-sync shim — wrong/old card layout, refusing to derive references from it"
  case "$(head -c4 "$REFD/.system/$p/bin/minarch.real.elf")" in *ELF*) : ;; *) fail "$p: reference minarch.real.elf is not an ELF";; esac
done

# ---- record the exact toolchain images used (reproducibility) ----
: > "$LOUT/toolchain-images.txt"
for p in $PLATFORMS; do
  img=$(img_for "$p")
  docker image inspect "$img" >/dev/null 2>&1 || fail "toolchain image '$img' not present on this host (see release/toolchains/README.md)"
  iid=$(docker image inspect -f '{{.Id}}' "$img")
  printf '%s %s %s\n' "$p" "$img" "$iid" >> "$LOUT/toolchain-images.txt"
done
echo ">> toolchain image IDs -> $LOUT/toolchain-images.txt" >&2

# ---- per-platform build ----
build_plat(){ # <plat>
  p=$1; img=$(img_for "$p")
  echo ">> build $p (image $img)" >&2
  case "$p" in
    miyoomini)
      docker run --rm -v "$WS":/root/workspace -w /root/workspace "$img" /bin/bash -lc \
        'cd miyoomini/libmsettings && make && cd /root/workspace/all/minui && make PLATFORM=miyoomini && cd /root/workspace/all/minarch && make PLATFORM=miyoomini' >&2 \
        || fail "$p launcher build failed"
      ;;
    my282)
      # buildroot env lives in /root/setup-env.sh; libmstick must exist before -lmstick links
      docker run --rm -v "$WS":/root/workspace -w /root/workspace "$img" /bin/bash -lc \
        'source /root/setup-env.sh && cd my282/libmsettings && make && cd /root/workspace/my282/libmstick && make && cd /root/workspace/all/minui && make PLATFORM=my282 && cd /root/workspace/all/minarch && make PLATFORM=my282' >&2 \
        || fail "$p launcher build failed"
      ;;
    my355)
      # my355-xcross ONLY — the my355-toolchain image is the wrong-ABI-SDL brick trap
      docker run --rm -v "$WS":/root/workspace -w /root/workspace "$img" /bin/bash -lc \
        'cd my355/libmsettings && make && cd /root/workspace/all/minui && make PLATFORM=my355 && cd /root/workspace/all/minarch && make PLATFORM=my355' >&2 \
        || fail "$p launcher build failed"
      ;;
  esac
  mkdir -p "$LOUT/$p"
  cp "$WS/all/minui/build/$p/minui.elf" "$LOUT/$p/minui.elf" || fail "$p: minui.elf missing after build"
  # build product is minarch.elf; on-card that role is minarch.REAL.elf (minarch.elf = shim)
  cp "$WS/all/minarch/build/$p/minarch.elf" "$LOUT/$p/minarch.real.elf" || fail "$p: minarch.elf missing after build"
}
for p in $PLATFORMS; do build_plat "$p"; done

# ---- gate script (runs inside $GATEIMG where readelf exists) ----
GS="$OUT/.launcher-gate.sh"
cat > "$GS" <<'GATEEOF'
#!/bin/bash
# args: <new-elf> <ref-elf> <hard-glibc-cap-or-"-"> <marker>
set -eu
new=$1; ref=$2; cap=$3; marker=$4
fail(){ echo "GATE FAIL: $*" >&2; exit 1; }
hdr(){ readelf -h "$1" | grep -E 'Class|Machine' | tr -s ' '; }
interp(){ readelf -l "$1" 2>/dev/null | sed -n 's/.*program interpreter: \(.*\)]/\1/p'; }
needed(){ readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
gmax(){ readelf -V "$1" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -uV | tail -1 | sed 's/GLIBC_//'; }
[ "$(hdr "$new")" = "$(hdr "$ref")" ] || fail "$new: ELF class/machine differs from shipped reference"
echo "  ok: class/machine matches reference ($(hdr "$new" | tr '\n' ' '))"
[ "$(interp "$new")" = "$(interp "$ref")" ] || fail "$new: interpreter '$(interp "$new")' != reference '$(interp "$ref")'"
echo "  ok: interp $(interp "$new")"
if ! diff <(needed "$ref") <(needed "$new") >/tmp/needed.diff 2>&1; then
  echo "NEEDED delta (reference vs rebuilt):" >&2; cat /tmp/needed.diff >&2
  fail "$new: NEEDED list differs from shipped reference"
fi
echo "  ok: NEEDED parity ($(needed "$new" | wc -l) libs, identical to reference)"
refmax=$(gmax "$ref"); [ -n "$refmax" ] || refmax=0.0
lim=$refmax
if [ "$cap" != "-" ]; then # hard device floor wins if tighter than the reference
  lim=$(printf '%s\n%s\n' "$refmax" "$cap" | sort -V | head -1)
fi
sh /repo/release/gate.sh elf "$new" --max-glibc "$lim" --symbol "$marker"
echo "  ok: glibc cap applied: $lim (reference max $refmax, hard cap ${cap})"
GATEEOF

gate_bin(){ # <plat> <name-in-LOUT> <name-in-ref> <hard-cap> <marker>
  p=$1; nb=$2; rb=$3; cap=$4; marker=$5
  echo ">> gate $p/$nb (vs shipped $rb, cap $cap)" >&2
  docker run --rm -v "$ROOT":/repo -v "$LOUT":/new -v "$REFD":/ref -v "$GS":/gate.sh:ro "$GATEIMG" \
    bash /gate.sh "/new/$p/$nb" "/ref/.system/$p/bin/$rb" "$cap" "$marker" >&2 \
    || fail "$p/$nb failed launcher gate"
}
for p in $PLATFORMS; do
  case "$p" in my355) cap=2.34;; *) cap=-;; esac   # my355 = Flip V2 device floor, hard
  gate_bin "$p" minui.elf        minui.elf        "$cap" "pending-saves.txt"
  gate_bin "$p" minarch.real.elf minarch.real.elf "$cap" "rcheevos"
done
rm -f "$GS"

# ---- provenance + checksums ----
{
  echo "commit $(git -C "$ROOT" rev-parse "$REF") ($SHORTSHA)"
  echo "reference card: $(basename "$REFCARD") sha256=$(hash "$REFCARD")"
  echo "HARDWARE-GATED: boot test on a spare card required before these enter ANY shipped artifact."
} > "$LOUT/PROVENANCE.txt"
( cd "$LOUT" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | xargs sha256sum > SHA256SUMS )
echo ">> launchers + SHA256SUMS -> $LOUT (NOT shipped; boot test first)" >&2

rm -rf "$WS" "$REFD"
for p in $PLATFORMS; do
  echo "LAUNCHER $p minui.elf=$(hash "$LOUT/$p/minui.elf") minarch.real.elf=$(hash "$LOUT/$p/minarch.real.elf")"
done
