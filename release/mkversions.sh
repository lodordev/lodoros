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
# Retirement: asset keys listed in release/retired-lanes.txt are dropped from every channel
# (#20) — a lane that left the build must leave the manifest too, or merge-forward (#19)
# re-advertises its stale asset and the tag gate aborts every publish.
# Output: <out-dir>/versions.json
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTDIR=${1:?usage: mkversions.sh <release-out-dir> [--beta] [--base f] [--notes f]}
shift
CHANNEL=stable; BASE=""; NOTES_FILE="$ROOT/release/release-notes.md"; NEXTUI_VER=""
while [ $# -gt 0 ]; do case "$1" in
  --beta)  CHANNEL=beta; shift;;
  --base)  BASE=$2; shift 2;;
  --notes) NOTES_FILE=$2; shift 2;;
  --nextui-version) NEXTUI_VER=$2; shift 2;;
  *) echo "mkversions: unknown arg $1" >&2; exit 2;;
esac; done
VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || true)
[ -n "$VERSION" ] || { echo "mkversions: VERSION missing" >&2; exit 1; }
[ -d "$OUTDIR" ] || { echo "mkversions: no such out dir: $OUTDIR" >&2; exit 1; }

python3 - "$OUTDIR" "$VERSION" "$CHANNEL" "$BASE" "$NOTES_FILE" "$NEXTUI_VER" "$ROOT/release/retired-lanes.txt" <<'PY'
import json, os, sys, glob, re

outdir, version, channel, base, notes_file, nextui_ver, retired_file = sys.argv[1:8]
TAG_URL = f"https://github.com/lodordev/lodor/releases/download/v{version}"

manifest = {"schema": 1}
if base:
    with open(base) as f:
        manifest = json.load(f)
    if manifest.get("schema") != 1:
        sys.exit(f"mkversions: base manifest schema {manifest.get('schema')} != 1")

# --- channel notes (single-line contract) ---
# #18: the notes H1 must name THIS release's VERSION, or the manifest silently ships a stale
# headline ("LodorOS 0.9.6 (beta)" under a 0.9.7.1 manifest). Fail loud rather than advertise
# a version the notes don't describe.
notes = ""
if os.path.exists(notes_file):
    for line in open(notes_file):
        line = line.strip().lstrip("#").strip()
        if line:
            notes = line
            break
if not notes:
    sys.exit(f"mkversions: no notes headline found in {notes_file}")
if version not in notes:
    sys.exit(
        f"mkversions: notes headline {notes!r} does not mention VERSION {version} "
        f"({notes_file}) — refusing to ship a stale notes line"
    )

# --- assets built THIS run (from the out-dir) ---
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

# #19: a partial rebuild must not drop other platforms' assets from the channel. When merging
# into a --base manifest, layer the newly-built assets ON TOP of the base channel's existing
# asset map (add/update keys) instead of replacing it wholesale — assets not rebuilt this run
# keep their base entry (and self-update stays live).
merged_assets = {}
if base:
    prev = manifest.get(channel, {})
    if isinstance(prev.get("assets"), dict):
        merged_assets.update(prev["assets"])
merged_assets.update(assets)

manifest[channel] = {"version": version, "notes": notes, "assets": merged_assets}

# #20: lane retirement. A lane dropped from the build must ALSO leave the manifest, or #19's
# merge-forward re-advertises its stale asset forever — pinned to an old release tag, which the
# per-asset tag gate (gate.sh update-manifest [tag]) rejects, aborting EVERY publish of EVERY
# lane (the F1/F3 blocker). Keys listed in release/retired-lanes.txt are stripped from every
# channel here; the freeze-aware engine then reports update=0 on those devices instead of a
# phantom offer.
retired = []
if os.path.exists(retired_file):
    for line in open(retired_file):
        line = line.split("#", 1)[0].strip()
        if line:
            retired.append(line)
for key in retired:
    if key in assets:
        sys.exit(
            f"mkversions: {key} is listed in {retired_file} but was BUILT this run — "
            f"un-retire the lane or drop the artifact; refusing the contradiction"
        )
dropped = []
for ch in ("stable", "beta"):
    c = manifest.get(ch)
    if isinstance(c, dict) and isinstance(c.get("assets"), dict):
        for key in retired:
            if c["assets"].pop(key, None) is not None:
                dropped.append(f"{ch}/{key}")
if not merged_assets:
    sys.exit("mkversions: retirement emptied the channel's asset map — refusing an empty channel")
if dropped:
    print(f"retired from manifest: {', '.join(dropped)}")
if channel == "stable":
    # notify drives the store-lane "update available" notices (NextUI Pak Store / muOS App
    # Downloader install the actual bits) — they track stable only; beta users opted into
    # the engine channel toggle instead.
    #
    # #17: notify must never claim a version a lane did NOT actually ship this run. Advance a
    # lane to VERSION only when its artifact is present in the out-dir; otherwise PRESERVE the
    # lane's prior value from --base (a fresh manifest with no base gets "0" as the honest
    # never-published sentinel). Lanes:
    #   - muos          : advanced iff Lodor-muOS-<VERSION>.muxapp exists here.
    #   - lodoros_card  : advanced iff LodorOS update overlays were built (assets above).
    #   - nextui        : ALWAYS preserved — NextUI publishes out-of-band via publish-nextui.sh
    #                     (which bumps lodor-nextui/pak.json, NOT this manifest's notify.nextui;
    #                     as of this fix nothing advances notify.nextui, so it stays at its base
    #                     value — publish-nextui.sh is the thing that SHOULD advance it).
    base_notify = manifest.get("notify") if base else None
    if not isinstance(base_notify, dict):
        base_notify = {}

    def carry(lane):
        return base_notify.get(lane, "0")

    muos_present = bool(glob.glob(os.path.join(outdir, f"Lodor-muOS-{version}.muxapp")))
    card_present = bool(assets)  # LodorOS overlays == the card lane's shipped bits

    manifest["notify"] = {
        # nextui advances only when this release explicitly shipped a NextUI pak
        # (--nextui-version, passed by publish-nextui.sh / the release driver); else preserved.
        "nextui": nextui_ver if nextui_ver else carry("nextui"),
        "muos": version if muos_present else carry("muos"),
        "lodoros_card": version if card_present else carry("lodoros_card"),
    }

out = os.path.join(outdir, "versions.json")
with open(out, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
print(f"versions.json -> {out} ({channel} = {version}, {len(merged_assets)} asset(s))")
PY
