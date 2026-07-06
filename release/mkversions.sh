#!/bin/sh
# mkversions.sh — emit/update versions.json (the self-update manifest) from a release.sh
# output dir. The manifest is what devices poll (gh-pages); its INVARIANT is enforced by the
# publish workflow, not here: it is only ever committed AFTER every asset it names has been
# re-downloaded from the live GitHub release and hash-verified. This script just builds the
# JSON honestly from the local artifacts.
#
# Usage:
#   mkversions.sh <release-out-dir> [--beta] [--base <existing-versions.json>] [--notes <file>]
#     <out-dir>  release/out/<sha> holding Lodor-LodorOS-update-<plat>-<VER>.zip (+ .sha256)
#     --beta     write the .beta channel (stable + notify untouched)
#     --base     merge into an existing manifest (fetch the live one first — a beta release
#                must never clobber stable). Absent: start a fresh schema-1 skeleton.
#     --notes    release notes file; first line becomes the channel notes (single-line contract)
# Output: <out-dir>/versions.json
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTDIR=${1:?usage: mkversions.sh <release-out-dir> [--beta] [--base f] [--notes f]}
shift
CHANNEL=stable; BASE=""; NOTES_FILE="$ROOT/release/release-notes.md"
while [ $# -gt 0 ]; do case "$1" in
  --beta)  CHANNEL=beta; shift;;
  --base)  BASE=$2; shift 2;;
  --notes) NOTES_FILE=$2; shift 2;;
  *) echo "mkversions: unknown arg $1" >&2; exit 2;;
esac; done
VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || true)
[ -n "$VERSION" ] || { echo "mkversions: VERSION missing" >&2; exit 1; }
[ -d "$OUTDIR" ] || { echo "mkversions: no such out dir: $OUTDIR" >&2; exit 1; }

python3 - "$OUTDIR" "$VERSION" "$CHANNEL" "$BASE" "$NOTES_FILE" <<'PY'
import json, os, sys, glob, re

outdir, version, channel, base, notes_file = sys.argv[1:6]
TAG_URL = f"https://github.com/lodordev/lodor/releases/download/v{version}"

manifest = {"schema": 1}
if base:
    with open(base) as f:
        manifest = json.load(f)
    if manifest.get("schema") != 1:
        sys.exit(f"mkversions: base manifest schema {manifest.get('schema')} != 1")

notes = ""
if os.path.exists(notes_file):
    for line in open(notes_file):
        line = line.strip().lstrip("#").strip()
        if line:
            notes = line
            break

assets = {}
for z in sorted(glob.glob(os.path.join(outdir, f"Lodor-LodorOS-update-*-{version}.zip"))):
    name = os.path.basename(z)
    m = re.match(rf"Lodor-LodorOS-update-(.+)-{re.escape(version)}\.zip$", name)
    if not m:
        continue
    plat = m.group(1)
    sha_file = z + ".sha256"
    if not os.path.exists(sha_file):
        sys.exit(f"mkversions: missing {sha_file} (release.sh writes it; refusing an unhashed asset)")
    sha = open(sha_file).read().split()[0]
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        sys.exit(f"mkversions: bad sha256 in {sha_file}")
    assets[f"lodoros-{plat}"] = {
        "url": f"{TAG_URL}/{name}",
        "size": os.path.getsize(z),
        "sha256": sha,
    }
if not assets:
    sys.exit(f"mkversions: no Lodor-LodorOS-update-*-{version}.zip in {outdir} — run release.sh first")

manifest[channel] = {"version": version, "notes": notes, "assets": assets}
if channel == "stable":
    # notify drives the store-lane "update available" notices (NextUI Pak Store / muOS App
    # Downloader install the actual bits) — they track stable only; beta users opted into
    # the engine channel toggle instead.
    manifest["notify"] = {"nextui": version, "muos": version, "lodoros_card": version}

out = os.path.join(outdir, "versions.json")
with open(out, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
print(f"versions.json -> {out} ({channel} = {version}, {len(assets)} asset(s))")
PY
