#!/bin/sh
# publish-lanes.sh — bring every per-lane GitHub repo current for one release.
#
# The umbrella release (publish-updates.sh) and the NextUI pak (publish-nextui.sh)
# each have their own publisher; every OTHER public repo used to be synced by hand,
# which is how lodoros/lodor-muos drifted versions behind (found 2026-07-10). This
# script makes lane parity a pipeline step instead of a memory:
#
#   1. source-sync  : lodor (engine root), lodoros (fork layout), lodor-muos,
#                     lodor-knulli — from mono main, gated (secrets + agent-pii),
#                     committed as lodordev, pushed.
#   2. lane releases: v$VERSION on lodor-muos (.muxapp), lodor-knulli (zip), and
#                     lodoros (full card, only if $OUT/LodorOS-$VERSION.zip exists —
#                     build it first with build-fullcard.sh; loud skip otherwise).
#   3. RELEASES.md  : regenerate the LATEST block on the umbrella repo and push.
#   4. repo-parity  : gate.sh repo-parity $VERSION — fails if any lane repo's
#                     latest release is not this version (NextUI included).
#
# Run AFTER publish-updates.sh (umbrella release must exist) and publish-nextui.sh.
# Usage:  publish-lanes.sh <release-out-dir>
# Token:  $GITHUB_TOKEN or $LODOR_GH_TOKEN_FILE (default ~/.config/lodor/github-token)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTDIR=${1:?usage: publish-lanes.sh <release-out-dir>}
OUTDIR=$(cd "$OUTDIR" && pwd)
VERSION=$(cat "$ROOT/VERSION")
WORK="${LODOR_PUBSYNC_DIR:-/mnt/user/appdata/lodor/work/pubsync}"
export LODOR_PII_REQUIRED=1
fail(){ echo "PUBLISH-LANES ABORT: $*" >&2; exit 1; }

TOKFILE="${LODOR_GH_TOKEN_FILE:-$HOME/.config/lodor/github-token}"
TOK="${GITHUB_TOKEN:-$(cat "$TOKFILE" 2>/dev/null || true)}"
[ -n "$TOK" ] || fail "no GitHub token (GITHUB_TOKEN or $TOKFILE)"
printf '%s' "$TOK" > "$WORK/.tok" 2>/dev/null || { mkdir -p "$WORK"; printf '%s' "$TOK" > "$WORK/.tok"; }
chmod 600 "$WORK/.tok"
HELPER='!f(){ echo username=x-access-token; echo "password=$(cat '"$WORK"'/.tok)"; }; f'
trap 'rm -f "$WORK/.tok"' EXIT

clone_fresh(){ # <repo>
  if [ -d "$WORK/$1/.git" ]; then git -C "$WORK/$1" fetch -q origin && git -C "$WORK/$1" reset -q --hard origin/main
  else git clone -q "https://github.com/lodordev/$1.git" "$WORK/$1"; fi
}
gate_tree(){ sh "$ROOT/release/gate.sh" secrets "$1" && sh "$ROOT/release/gate.sh" agent-pii "$1"; }
commit_push(){ # <repo> <msg>
  cd "$WORK/$1"; git add -A
  if git diff --cached --quiet; then echo "  $1: source already current"
  else git -c user.name=lodordev -c user.email=dev@lodor.local commit -q -m "$2"; fi
  git -c credential.helper="$HELPER" push -q origin main
  echo "  $1 -> $(git rev-parse --short HEAD)"
}

echo "== 1/4 source sync (mono main -> lane repos) =="
for r in lodor lodoros lodor-muos lodor-knulli; do clone_fresh "$r"; done

# NOTE (space-safety): `for f in $(ls -A)` word-splits names containing spaces (rm'ing
# fragments, missing the real entry). Plain globs don't split; the three patterns
# (* / .[!.]* / ..?*) cover all entries incl. dotfiles, and the -e/-L guard drops any
# literally-unmatched pattern (POSIX sh has no nullglob).
cd "$WORK/lodor"
for f in * .[!.]* ..?*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  case "$f" in .git|.github|README.md|RELEASES.md|BLUEPRINT.md|CREDITS.md|LICENSE|.gitignore) ;; *) rm -rf "$f";; esac
done
git -C "$ROOT" archive main engine | tar -x --strip-components=1 -C .

cd "$WORK/lodoros"
for f in * .[!.]* ..?*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  case "$f" in .git|.github|README.md) ;; *) rm -rf "$f";; esac
done
git -C "$ROOT" archive main lodoros | tar -x --strip-components=1 -C .
git -C "$ROOT" archive main release contract LICENSE | tar -x -C .
rm -rf ledger.md todo.txt release/out engine integrations

cd "$WORK/lodor-muos"
for f in * .[!.]* ..?*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  case "$f" in .git) ;; *) rm -rf "$f";; esac
done
git -C "$ROOT" archive main integrations/muos | tar -x --strip-components=2 -C .
git -C "$ROOT" archive main LICENSE | tar -x -C .

cd "$WORK/lodor-knulli"
for f in * .[!.]* ..?*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  case "$f" in .git|README.md) ;; *) rm -rf "$f";; esac
done
git -C "$ROOT" archive main integrations/knulli | tar -x --strip-components=2 -C .
git -C "$ROOT" archive main LICENSE | tar -x -C .

for r in lodor lodoros lodor-muos lodor-knulli; do gate_tree "$WORK/$r" || fail "gate on $r"; done
commit_push lodor       "engine $VERSION"
commit_push lodoros     "sync from mono: $VERSION"
commit_push lodor-muos  "Lodor-muOS $VERSION"
commit_push lodor-knulli "Lodor-Knulli $VERSION"

echo "== 2/4 lane releases v$VERSION =="
api(){ curl -sfS -X "$1" -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" ${3:+-d "$3"} "https://api.github.com$2"; }
mkrel(){ # <repo> <body> -> id (idempotent: reuse existing release for the tag)
  _id=$(api GET "/repos/lodordev/$1/releases/tags/v$VERSION" 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
  [ -n "$_id" ] && { echo "$_id"; return; }
  api POST "/repos/lodordev/$1/releases" "{\"tag_name\":\"v$VERSION\",\"name\":\"$2 $VERSION\",\"body\":\"$3\",\"draft\":false,\"prerelease\":false}" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])"
}
upl(){ # <repo> <relid> <file>
  _n=$(basename "$3")
  # Idempotent AND honest (M4): a name-matched asset only counts when state=="uploaded"
  # and its size equals the local bytes — an interrupted upload leaves state="starter"
  # or a truncated size, and the old name-only skip let that broken asset survive every
  # re-run. On mismatch: DELETE the asset and re-upload.
  _existing=$(api GET "/repos/lodordev/$1/releases/$2/assets?per_page=100" \
    | python3 -c 'import json,sys
n=sys.argv[1]
for a in json.load(sys.stdin):
    if a.get("name")==n:
        print(a.get("id",""), a.get("state",""), a.get("size",0)); break' "$_n" 2>/dev/null || true)
  if [ -n "$_existing" ]; then
    _aid=$(printf '%s' "$_existing" | cut -d' ' -f1)
    _state=$(printf '%s' "$_existing" | cut -d' ' -f2)
    _size=$(printf '%s' "$_existing" | cut -d' ' -f3)
    _local=$(wc -c < "$3" | tr -d ' ')
    if [ "$_state" = "uploaded" ] && [ "$_size" = "$_local" ]; then
      echo "  $_n already on release (uploaded, $_size bytes)"; return
    fi
    echo "  $_n on release but state=$_state size=$_size (local $_local) — deleting + re-uploading"
    api DELETE "/repos/lodordev/$1/releases/assets/$_aid" || fail "broken-asset delete: $_n"
  fi
  curl -sfS -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/octet-stream" \
    --data-binary @"$3" "https://uploads.github.com/repos/lodordev/$1/releases/$2/assets?name=$_n" >/dev/null
  echo "  uploaded $_n -> $1"
}
BODY_TAIL="All release artifacts are also published on the combined lodor release: https://github.com/lodordev/lodor/releases/tag/v$VERSION"

[ -f "$OUTDIR/Lodor-muOS-$VERSION.muxapp" ] || fail "missing $OUTDIR/Lodor-muOS-$VERSION.muxapp"
RID=$(mkrel lodor-muos "Lodor-muOS" "Lodor for muOS $VERSION. Install/update the .muxapp via Applications - Archive Manager; pairing and settings are kept. $BODY_TAIL")
upl lodor-muos "$RID" "$OUTDIR/Lodor-muOS-$VERSION.muxapp"
[ -f "$OUTDIR/Lodor-muOS-$VERSION.muxapp.sha256" ] && upl lodor-muos "$RID" "$OUTDIR/Lodor-muOS-$VERSION.muxapp.sha256"

[ -f "$OUTDIR/Lodor-Knulli-$VERSION.zip" ] || fail "missing $OUTDIR/Lodor-Knulli-$VERSION.zip"
RID=$(mkrel lodor-knulli "Lodor-Knulli" "Lodor for Knulli $VERSION. Install/update: extract the zip onto /userdata; pairing and settings are kept. $BODY_TAIL")
upl lodor-knulli "$RID" "$OUTDIR/Lodor-Knulli-$VERSION.zip"
[ -f "$OUTDIR/Lodor-Knulli-$VERSION.zip.sha256" ] && upl lodor-knulli "$RID" "$OUTDIR/Lodor-Knulli-$VERSION.zip.sha256"

if [ -f "$OUTDIR/LodorOS-$VERSION.zip" ]; then
  RID=$(mkrel lodoros "LodorOS" "LodorOS $VERSION - full-card image for Miyoo devices. Fresh install: flash/extract this card. Already running LodorOS? Use Update Lodor on the device instead. $BODY_TAIL")
  upl lodoros "$RID" "$OUTDIR/LodorOS-$VERSION.zip"
  [ -f "$OUTDIR/LodorOS-$VERSION.zip.sha256" ] && upl lodoros "$RID" "$OUTDIR/LodorOS-$VERSION.zip.sha256"
else
  echo "!! NO FULL CARD for $VERSION ($OUTDIR/LodorOS-$VERSION.zip missing) — lodoros release NOT cut." >&2
  echo "!! Build one: LODOR_BASE_CARD=<prior card zip> release/build-fullcard.sh $OUTDIR $VERSION — then re-run." >&2
  [ "${LODOR_ALLOW_CARDLESS:-0}" = 1 ] || fail "full card missing (set LODOR_ALLOW_CARDLESS=1 to accept a lagging lodoros release page)"
fi

echo "== 3/4 RELEASES.md latest block =="
cd "$WORK/lodor"
python3 - "$VERSION" <<'PY'
import sys
v = sys.argv[1]
p = "RELEASES.md"
s = open(p).read()
b, e = "<!-- LATEST:BEGIN (regenerated by release/publish-lanes.sh — do not edit inside the markers) -->", "<!-- LATEST:END -->"
i, j = s.index(b), s.index(e)
block = f"""{b}
## Latest — everything is {v} (in sync)

| Front-end | Version | Download |
|---|---|---|
| **LodorOS** — full-card image (Miyoo) | **{v}** | [lodoros · v{v}](https://github.com/lodordev/lodoros/releases/tag/v{v}) |
| **muOS** (`.muxapp`) | **{v}** | [lodor-muos · v{v}](https://github.com/lodordev/lodor-muos/releases/tag/v{v}) |
| **Knulli** (zip onto `/userdata`) | **{v}** | [lodor-knulli · v{v}](https://github.com/lodordev/lodor-knulli/releases/tag/v{v}) |
| **NextUI** (Pak Store) | **{v}** | [lodor-nextui · {v}](https://github.com/lodordev/lodor-nextui/releases/tag/{v}) |
| **Android** (APK) · LodorOS update-overlays | **{v}** | [lodor · v{v}](https://github.com/lodordev/lodor/releases/tag/v{v}) |
"""
open(p, "w").write(s[:i] + block + s[j:])
PY
git add RELEASES.md
git diff --cached --quiet || git -c user.name=lodordev -c user.email=dev@lodor.local commit -q -m "releases: $VERSION across all front-ends"
git -c credential.helper="$HELPER" push -q origin main

echo "== 4/4 repo-parity gate =="
sh "$ROOT/release/gate.sh" repo-parity "$VERSION" || fail "repo-parity"
echo "== publish-lanes done: every lane repo is at $VERSION =="
