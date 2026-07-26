#!/usr/bin/env bash
# recert.sh — automated cross-arch save-STATE re-certification (WS5 of the testing plan).
#
# One command reproducing the release/xarch-cert method (harness.c under qemu-user docker
# containers) as a full per-core, per-arch-pair matrix, emitted as matrix-<date>.json for
# release/gate.sh state-recert to hold state-compat.json accountable to.
#
# Method per CROSS-ARCH pair (both directions, exactly the 2026-07-07 manual protocol):
#   1. arch A: run the real core + real rom 300 frames from boot, serialize (the seed).
#   2. arch A: loadrun the seed +300 and +900 more frames (A's own continuation = reference).
#   3. arch B: loadrun the SAME seed +300 and +900 frames.
#   4. Verdict: B's trajectory vs A's. Byte-identical = PASS. A small byte-island that is
#      IDENTICAL (same offsets) at +300 and +900 = inert (heap pointers/RTC), PASS with note.
#      Compounding divergence = FAIL (desync). Unserialize refusal / size mismatch = FAIL.
# Method per SINGLE-ARCH (a->a) line (round-trip fidelity):
#   gen 300 -> seed; fresh boots to 600/900 frames = reference; loadrun seed +300/+600;
#   continuation must match the fresh-boot trajectory by the same verdict rules.
#
# Verdicts are FACTS about the exact binaries run; every core version (retro_get_system_info),
# sha256 and provenance is recorded in the matrix. Cores/roms default to the canonical build-host
# locations (shipped card tree, mgba cert bins, RomM library, libretro buildbot for the two
# CFW-provided arm64 cores) — all overridable via XARCH_* env.
#
# Run notes (learned 2026-07-07/09, encoded here so they cannot be forgotten):
#   - docker images MUST be arch-specific repos (arm32v7/..., arm64v8/...) AND --platform;
#     a cached shared tag silently runs the wrong arch ("wrong ELF class").
#   - every qemu run is wrapped in `timeout` — qemu-user failure mode is HANG, not crash.
#   - armhf runs are pinned with --cpuset-cpus (qemu-arm flakiness under SMP scheduling).
#
# Usage: recert.sh [--out <matrix.json>]   (default: <repo>/release/xarch-cert/matrix-<date>.json)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DATE=$(date +%F)
OUT="$ROOT/release/xarch-cert/matrix-$DATE.json"
[ "${1:-}" = "--out" ] && OUT=$2

W=${XARCH_WORK:-/mnt/cache/tmp/xarch-recert-$DATE}
TMO=${XARCH_TMO:-900}
ARMHF_CPUS=${XARCH_ARMHF_CPUS:-0}

# --- core sources (shipped binaries first; buildbot only where the fleet's core is CFW-provided) ---
CARD_HF=${XARCH_ARMHF_CORES:-/mnt/cache/tmp/lodor-release/work/card/.system/miyoomini/cores}
CARD_A64=${XARCH_ARM64_CORES:-/mnt/cache/tmp/lodor-release/work/card/.system/tg5040/cores}
MGBA_HF=${XARCH_MGBA_ARMHF:-/mnt/cache/tmp/mgba-cert/cardbins/miyoomini_armhf.so}
MGBA_A64=${XARCH_MGBA_ARM64:-/mnt/cache/tmp/mgba-cert/cardbins/my355_arm64.so}
BUILDBOT=${XARCH_BUILDBOT:-https://buildbot.libretro.com/nightly/linux}

# --- rom fixtures ---
ROMM=${XARCH_ROMM_LIB:-/mnt/storage/data/romm/library/roms}
ROM_nes=${XARCH_ROM_NES:-$ROMM/nes/1942 (Japan, USA) (En).nes}
ROM_gb=${XARCH_ROM_GB:-$ROMM/gb/Adventures of Lolo (Europe) (SGB Enhanced).gb}
ROM_md=${XARCH_ROM_MD:-$ROMM/genesis/3 Ninjas Kick Back (USA).md}
ROM_gg=${XARCH_ROM_GG:-$ROMM/gamegear/Aerial Assault (World) (Rev 1).gg}
ROM_snes=${XARCH_ROM_SNES:-$ROMM/snes/3 Ninjas Kick Back (USA).sfc}
ROM_gba=${XARCH_ROM_GBA:-/mnt/cache/tmp/mgba-cert/roms/emerald.gba}

say(){ printf '%s\n' "== $*"; }
die(){ echo "recert: FATAL: $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker required"
command -v python3 >/dev/null || die "python3 required"

rm -rf "$W"; mkdir -p "$W/cores" "$W/roms" "$W/s"
cp "$HERE/harness.c" "$W/harness.c"
: > "$W/rows.tsv"; : > "$W/run.log"

# ---------- docker plumbing ----------
img_for(){ case $1 in armhf) echo arm32v7/gcc:12;; arm64) echo arm64v8/gcc:12;; esac; }
plat_for(){ case $1 in armhf) echo linux/arm/v7;; arm64) echo linux/arm64;; esac; }

ensure_image(){ # arch
  local img plat; img=$(img_for "$1"); plat=$(plat_for "$1")
  docker image inspect "$img" >/dev/null 2>&1 || \
    timeout 600 docker pull --platform "$plat" "$img" >/dev/null
}

drun(){ # arch "cmd"  -> runs in $W, timeout-wrapped, cpuset-pinned on armhf
  local arch=$1 cmd=$2 plat img cpuset=()
  plat=$(plat_for "$arch"); img=$(img_for "$arch")
  [ "$arch" = armhf ] && cpuset=(--cpuset-cpus="$ARMHF_CPUS")
  timeout "$TMO" docker run --rm --platform "$plat" "${cpuset[@]}" \
    -v "$W":/w -w /w "$img" bash -c "$cmd" >> "$W/run.log" 2>&1
}

say "qemu binfmt reset"
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null 2>&1 || true
[ -e /proc/sys/fs/binfmt_misc/qemu-arm ] && [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
  || die "qemu binfmt handlers missing after reset"
ensure_image armhf; ensure_image arm64

say "compile harness (both arches)"
drun armhf "gcc -O2 -o harness-armhf harness.c -ldl" \
  || die "armhf harness compile failed (see $W/run.log)"
drun arm64 "gcc -O2 -o harness-arm64 harness.c -ldl" \
  || die "arm64 harness compile failed (see $W/run.log)"

# ---------- stage cores + roms, record provenance ----------
declare -A SRC SHA VER
stage_core(){ # core arch srcpath
  local c=$1 a=$2 p=$3
  [ -f "$p" ] || return 1
  cp "$p" "$W/cores/$c-$a.so"
  SRC[$c/$a]=$p
  SHA[$c/$a]=$(sha256sum "$W/cores/$c-$a.so" | cut -d' ' -f1)
}
stage_buildbot(){ # core arch(arm64 only)
  local c=$1 url="$BUILDBOT/aarch64/latest/${c}_libretro.so.zip" z="$W/cores/$c.zip"
  timeout 300 curl -sfL --retry 2 -o "$z" "$url" || return 1
  (cd "$W/cores" && python3 -c "import zipfile;zipfile.ZipFile('$c.zip').extractall()") || return 1
  mv "$W/cores/${c}_libretro.so" "$W/cores/$c-arm64.so"; rm -f "$z"
  SRC[$c/arm64]="$url"
  SHA[$c/arm64]=$(sha256sum "$W/cores/$c-arm64.so" | cut -d' ' -f1)
}
core_ver(){ # core arch -> record VER via harness info mode
  local c=$1 a=$2 v
  drun "$a" "./harness-$a cores/$c-$a.so info > s/$c-$a.info" || true
  v=$(sed -n 's/^INFO name=.* version=//p' "$W/s/$c-$a.info" 2>/dev/null | head -1)
  VER[$c/$a]=${v:-unknown}
}

say "stage cores"
for c in fceumm gambatte picodrive gpsp snes9x2005_plus; do
  stage_core "$c" armhf "$CARD_HF/${c}_libretro.so" || die "missing armhf core: $c ($CARD_HF)"
  stage_core "$c" arm64 "$CARD_A64/${c}_libretro.so" || die "missing arm64 core: $c ($CARD_A64)"
done
stage_core mgba armhf "$MGBA_HF" || die "missing mgba armhf ($MGBA_HF)"
stage_core mgba arm64 "$MGBA_A64" || die "missing mgba arm64 ($MGBA_A64)"
BB_OK=1
for c in snes9x genesis_plus_gx; do
  if ! stage_buildbot "$c"; then
    echo "recert: WARN: buildbot download failed for $c (arm64) — its line will be UNPROVEN" >&2
    BB_OK=0
  fi
done

say "stage roms"
for k in nes gb md gg snes gba; do
  v="ROM_$k"; p=${!v}
  [ -f "$p" ] || die "missing rom fixture for $k: $p"
  cp "$p" "$W/roms/$k.rom"
done
declare -A ROMSHA ROMNAME
for k in nes gb md gg snes gba; do
  v="ROM_$k"; ROMNAME[$k]=$(basename "${!v}")
  ROMSHA[$k]=$(sha256sum "$W/roms/$k.rom" | cut -d' ' -f1)
done

say "core versions"
for key in "${!SRC[@]}"; do core_ver "${key%/*}" "${key#*/}"; done

# ---------- verdict machinery ----------
# diffstat A B -> "SIZEMISMATCH" | "<count>:<md5-of-offsets>"
diffstat(){
  local a=$1 b=$2 sa sb
  sa=$(wc -c <"$a"); sb=$(wc -c <"$b")
  [ "$sa" = "$sb" ] || { echo SIZEMISMATCH; return; }
  cmp -l "$a" "$b" 2>/dev/null | awk '{print $1}' > "$W/s/.offs" || true
  echo "$(wc -l <"$W/s/.offs"):$(md5sum "$W/s/.offs" | cut -d' ' -f1)"
}

row(){ # core rom pair frames verdict evidence
  local c=$1 romk=$2 pair=$3 frames=$4 verdict=$5 ev=$6 a1 a2
  a1=${pair%->*}; a2=${pair#*->}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$c" "$pair" "$verdict" "$frames" "$ev" \
    "${VER[$c/$a1]:-}" "${VER[$c/$a2]:-}" "${SHA[$c/$a1]:-}" "${SHA[$c/$a2]:-}" \
    "${SRC[$c/$a1]:-}" "${SRC[$c/$a2]:-}" \
    "${ROMNAME[$romk]}" "${ROMSHA[$romk]}" "$(basename "${SRC[$c/$a1]:-?}")" >> "$W/rows.tsv"
  printf '  %-16s %-14s %-24s %s\n' "$c" "$pair" "$verdict" "$ev"
}

# judge d300 d900 -> sets JVERDICT/JEV; JPROBE=1 when a longer-horizon probe would clarify
judge(){
  local d3=$1 d9=$2 n3 h3 n9 h9
  JPROBE=0
  if [ "$d3" = SIZEMISMATCH ] || [ "$d9" = SIZEMISMATCH ]; then
    JVERDICT=FAIL; JEV="state size mismatch between continuations"; return; fi
  n3=${d3%%:*}; h3=${d3#*:}; n9=${d9%%:*}; h9=${d9#*:}
  if [ "$n9" = 0 ]; then JVERDICT=PASS; JEV="byte-identical (+300 diff=$n3, +900 diff=0)"
  elif [ "$n3" = "$n9" ] && [ "$h3" = "$h9" ] && [ "$n9" -le 64 ]; then
    JVERDICT=PASS; JEV="inert byte-island ${n9}B, same offsets at +300/+900 (non-compounding)"
  elif [ "$n3" = "$n9" ] && [ "$h3" = "$h9" ]; then
    JVERDICT=FAIL; JEV="constant ${n9}B byte-island, same offsets at +300/+900 (NON-compounding but exceeds 64B inert threshold — needs source-level investigation before any pass)"
  else
    JVERDICT=FAIL; JEV="diff grows/moves: +300=${n3}B -> +900=${n9}B"
    [ "$n9" -le 64 ] && JPROBE=1
  fi
}

cross_dir(){ # core romkey archA archB  (one direction: seed on A, judge B vs A)
  local c=$1 romk=$2 A=$3 B=$4
  local pre="s/${c}_${romk}_${A}"
  if ! drun "$A" "./harness-$A cores/$c-$A.so roms/$romk.rom gen 300 $pre.seed"; then
    row "$c" "$romk" "$A->$B" "300+300/900" ERROR "state generation failed on $A (rig, not cert)"; return; fi
  drun "$A" "./harness-$A cores/$c-$A.so roms/$romk.rom loadrun $pre.seed ${pre}_self300 300" || true
  drun "$A" "./harness-$A cores/$c-$A.so roms/$romk.rom loadrun $pre.seed ${pre}_self900 900" || true
  if [ ! -s "$W/${pre}_self300" ] || [ ! -s "$W/${pre}_self900" ]; then
    row "$c" "$romk" "$A->$B" "300+300/900" ERROR "reference continuation failed on $A (rig, not cert)"; return; fi
  local rc=0
  drun "$B" "./harness-$B cores/$c-$B.so roms/$romk.rom loadrun $pre.seed ${pre}_to${B}300 300" || rc=$?
  drun "$B" "./harness-$B cores/$c-$B.so roms/$romk.rom loadrun $pre.seed ${pre}_to${B}900 900" || rc=$?
  if [ $rc -ne 0 ] || [ ! -s "$W/${pre}_to${B}300" ] || [ ! -s "$W/${pre}_to${B}900" ]; then
    local why; why=$(tail -3 "$W/run.log" | tr '\n\t' '; ' )
    row "$c" "$romk" "$A->$B" "300+300/900" FAIL "unserialize refused/failed on $B (rc=$rc): $why"; return; fi
  judge "$(diffstat "$W/${pre}_self300" "$W/${pre}_to${B}300")" \
        "$(diffstat "$W/${pre}_self900" "$W/${pre}_to${B}900")"
  if [ "$JPROBE" = 1 ]; then  # small growing diff: one longer horizon to size the drift
    drun "$A" "./harness-$A cores/$c-$A.so roms/$romk.rom loadrun $pre.seed ${pre}_self2700 2700" || true
    drun "$B" "./harness-$B cores/$c-$B.so roms/$romk.rom loadrun $pre.seed ${pre}_to${B}2700 2700" || true
    if [ -s "$W/${pre}_self2700" ] && [ -s "$W/${pre}_to${B}2700" ]; then
      local dp; dp=$(diffstat "$W/${pre}_self2700" "$W/${pre}_to${B}2700")
      [ "$dp" = SIZEMISMATCH ] && JEV="$JEV; probe +2700: SIZE MISMATCH" \
        || JEV="$JEV; probe +2700: diff=${dp%%:*}B"
    else JEV="$JEV; probe +2700: continuation failed"; fi
  fi
  row "$c" "$romk" "$A->$B" "300+300/900" "$JVERDICT" "$JEV"
}

self_cert(){ # core romkey arch  (round-trip fidelity a->a)
  local c=$1 romk=$2 a=$3
  local pre="s/${c}_${romk}_${a}_rt"
  if ! drun "$a" "./harness-$a cores/$c-$a.so roms/$romk.rom gen 300 $pre.seed && \
                  ./harness-$a cores/$c-$a.so roms/$romk.rom gen 600 ${pre}_ref600 && \
                  ./harness-$a cores/$c-$a.so roms/$romk.rom gen 900 ${pre}_ref900"; then
    row "$c" "$romk" "$a->$a" "300+300/600" ERROR "gen failed on $a (rig, not cert)"; return; fi
  local rc=0
  drun "$a" "./harness-$a cores/$c-$a.so roms/$romk.rom loadrun $pre.seed ${pre}_cont600 300" || rc=$?
  drun "$a" "./harness-$a cores/$c-$a.so roms/$romk.rom loadrun $pre.seed ${pre}_cont900 600" || rc=$?
  if [ $rc -ne 0 ] || [ ! -s "$W/${pre}_cont600" ] || [ ! -s "$W/${pre}_cont900" ]; then
    row "$c" "$romk" "$a->$a" "300+300/600" FAIL "own state refused on reload (rc=$rc)"; return; fi
  judge "$(diffstat "$W/${pre}_ref600" "$W/${pre}_cont600")" \
        "$(diffstat "$W/${pre}_ref900" "$W/${pre}_cont900")"
  if [ "$JPROBE" = 1 ]; then
    drun "$a" "./harness-$a cores/$c-$a.so roms/$romk.rom gen 3000 ${pre}_ref3000" || true
    drun "$a" "./harness-$a cores/$c-$a.so roms/$romk.rom loadrun $pre.seed ${pre}_cont3000 2700" || true
    if [ -s "$W/${pre}_ref3000" ] && [ -s "$W/${pre}_cont3000" ]; then
      local dp; dp=$(diffstat "$W/${pre}_ref3000" "$W/${pre}_cont3000")
      [ "$dp" = SIZEMISMATCH ] && JEV="$JEV; probe +2700: SIZE MISMATCH" \
        || JEV="$JEV; probe +2700: diff=${dp%%:*}B"
    else JEV="$JEV; probe +2700: continuation failed"; fi
  fi
  row "$c" "$romk" "$a->$a" "300+300/600" "$JVERDICT" "$JEV"
}

# ---------- the matrix ----------
say "cross-arch classes (both directions): fceumm gambatte picodrive mgba"
cross_dir fceumm    nes armhf arm64;  cross_dir fceumm    nes arm64 armhf
cross_dir gambatte  gb  armhf arm64;  cross_dir gambatte  gb  arm64 armhf
# picodrive's class spans GG/SMS (Z80 path) AND MegaDrive (68k+FM path) — cert BOTH;
# a per-core class is only as portable as its least portable system.
cross_dir picodrive md  armhf arm64;  cross_dir picodrive md  arm64 armhf
cross_dir picodrive gg  armhf arm64;  cross_dir picodrive gg  arm64 armhf
cross_dir mgba      gba armhf arm64;  cross_dir mgba      gba arm64 armhf

say "single-arch class lines (round-trip a->a)"
self_cert gpsp gba armhf;             self_cert gpsp gba arm64
self_cert snes9x2005_plus snes armhf; self_cert snes9x2005_plus snes arm64
self_cert mgba gba arm64
if [ -f "$W/cores/snes9x-arm64.so" ]; then self_cert snes9x snes arm64
else row snes9x snes "arm64->arm64" - UNPROVEN "arm64 core unobtainable off-device (buildbot download failed)"; fi
if [ -f "$W/cores/genesis_plus_gx-arm64.so" ]; then self_cert genesis_plus_gx md arm64
else row genesis_plus_gx md "arm64->arm64" - UNPROVEN "arm64 core unobtainable off-device (buildbot download failed)"; fi

say "informational: re-prove the 2026-07-07 negatives (cross-arch on the arm64-only cores)"
cross_dir gpsp gba armhf arm64
cross_dir snes9x2005_plus snes armhf arm64

# ---------- emit matrix json ----------
say "emit $OUT"
GITREV=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
python3 - "$W/rows.tsv" "$OUT" "$DATE" "$GITREV" << 'PY'
import json, sys, hashlib
rows = []
for line in open(sys.argv[1]):
    f = line.rstrip("\n").split("\t")
    if len(f) < 13: continue
    core, pair, verdict, frames, ev, v1, v2, s1, s2, src1, src2, rom, romsha, _ = f
    a1, a2 = pair.split("->")
    r = {"core": core, "pair": pair, "verdict": verdict, "frames": frames,
         "evidence": ev, "rom": rom, "rom_sha256": romsha,
         "version": {a1: v1, a2: v2} if a1 != a2 else {a1: v1},
         "core_sha256": {a1: s1, a2: s2} if a1 != a2 else {a1: s1},
         "core_source": {a1: src1, a2: src2} if a1 != a2 else {a1: src1}}
    rows.append(r)
doc = {"version": 1, "date": sys.argv[3], "repo_commit": sys.argv[4],
       "method": ("release/xarch-cert/harness.c under qemu-user docker (arm32v7/gcc:12, "
                  "arm64v8/gcc:12): gen 300f seed on origin arch, origin's own +300/+900 "
                  "continuation as reference, target arch loadrun same seed +300/+900; "
                  "byte-compare trajectories (inert constant-offset islands pass, "
                  "compounding divergence fails). Single-arch a->a lines are round-trip "
                  "fidelity: fresh-boot 600/900f reference vs save@300+load continuation."),
       "rows": rows}
assert rows, "no rows produced"
json.dump(doc, open(sys.argv[2], "w"), indent=1)
print(f"  wrote {sys.argv[2]} ({len(rows)} rows)")
PY

echo
echo "=================== MATRIX $DATE ==================="
printf '%-18s %-14s %-9s %s\n' CORE PAIR VERDICT EVIDENCE
awk -F'\t' '{printf "%-18s %-14s %-9s %s (v: %s)\n", $1, $2, $3, $5, $6}' "$W/rows.tsv"
echo "===================================================="
if awk -F'\t' '$3=="FAIL"||$3=="ERROR"{f=1} END{exit !f}' "$W/rows.tsv"; then
  echo "recert: NOTE: FAIL/ERROR rows present — compare against state-compat.json claims via:"
  echo "  release/gate.sh state-recert <state-compat.json> $OUT"
fi
echo "work dir kept: $W (run.log, states, staged cores)"
