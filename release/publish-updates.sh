#!/bin/sh
# publish-updates.sh — publish the LodorOS self-update assets + manifest for one release.
#
# Local-build + CI-publish split (decided 2026-07-06): artifacts are built by the GATED local
# release.sh run (docker + PII/branding gates + TSBIN live here, not in CI); this script ships
# them; the public repo's publish-versions workflow re-verifies every asset LIVE and only then
# commits versions.json to gh-pages. Devices poll gh-pages, so the ordering invariant
# (assets verified live BEFORE the manifest is visible) is structural, not procedural.
#
# Usage:  publish-updates.sh <release-out-dir> [--beta]
#   1. mkversions.sh   -> <out>/versions.json (merging the LIVE manifest so beta never clobbers stable)
#   2. gate update-manifest (pinned to v$VERSION)
#   3. create GitHub release v$VERSION on lodordev/lodor, upload update zips + versions.json
#   4. dispatch the publish-versions workflow (which does the live verify + gh-pages commit)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTDIR=${1:?usage: publish-updates.sh <release-out-dir> [--beta]}
shift
BETA=""
[ "${1:-}" = "--beta" ] && BETA="--beta"
VERSION=$(cat "$ROOT/VERSION")
TAG="v$VERSION"
REPO_SLUG="lodordev/lodor"
fail(){ echo "PUBLISH ABORT: $*" >&2; exit 1; }
hash(){ sha256sum "$1" | cut -d" " -f1; }

TOK="${GITHUB_TOKEN:-$(cat "$HOME/.claude/secrets/github-pat" 2>/dev/null || true)}"
[ -n "$TOK" ] || fail "no GitHub token (GITHUB_TOKEN or ~/.claude/secrets/github-pat)"
api(){ # api <method> <path> [json]
  if [ -n "${3:-}" ]; then
    curl -sfS -X "$1" -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" -d "$3" "https://api.github.com$2"
  else
    curl -sfS -X "$1" -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" "https://api.github.com$2"
  fi
}

echo "== 1/4 versions.json (merge live manifest; $([ -n "$BETA" ] && echo beta || echo stable) = $VERSION) =="
BASEARG=""
if curl -sfL -o "$OUTDIR/.live-versions.json" "https://lodordev.github.io/lodor/versions.json" 2>/dev/null; then
  BASEARG="--base $OUTDIR/.live-versions.json"
  echo "  merging into the live manifest"
else
  echo "  no live manifest yet (first publish) - starting fresh"
fi
# shellcheck disable=SC2086
sh "$ROOT/release/mkversions.sh" "$OUTDIR" $BETA $BASEARG
sh "$ROOT/release/gate.sh" update-manifest "$OUTDIR/versions.json" "$TAG" || fail "update-manifest gate"

echo "== 2/4 release $TAG on $REPO_SLUG =="
_pre=false; [ -n "$BETA" ] && _pre=true
_body=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":"Lodor "+sys.argv[2],"body":sys.argv[3],"prerelease":sys.argv[4]=="true"}))' \
  "$TAG" "$VERSION" "Self-update assets for Lodor $VERSION. Devices receive these via the in-app updater (LodorOS) or the store notice (NextUI/muOS)." "$_pre")
_rel=$(api POST "/repos/$REPO_SLUG/releases" "$_body") || fail "release create (does $TAG already exist?)"
_relid=$(printf '%s' "$_rel" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

echo "== 3/4 upload assets =="
for f in "$OUTDIR"/Lodor-LodorOS-update-*-"$VERSION".zip "$OUTDIR/versions.json"; do
  [ -f "$f" ] || fail "missing artifact: $f"
  _ct="application/zip"; case "$f" in *.json) _ct="application/json";; esac
  curl -sfS -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: $_ct" \
    --data-binary @"$f" \
    "https://uploads.github.com/repos/$REPO_SLUG/releases/$_relid/assets?name=$(basename "$f")" >/dev/null \
    || fail "asset upload: $(basename "$f")"
  echo "  uploaded: $(basename "$f")"
done

echo "== 4/4 dispatch publish-versions workflow (live verify + gh-pages) =="
api POST "/repos/$REPO_SLUG/actions/workflows/publish-versions.yml/dispatches" \
  "{\"ref\":\"main\",\"inputs\":{\"tag\":\"$TAG\"}}" >/dev/null \
  || fail "workflow dispatch (is .github/workflows/publish-versions.yml on main?)"
echo "== dispatched. The manifest goes live only after CI hash-verifies every asset. =="
echo "   watch: https://github.com/$REPO_SLUG/actions"
