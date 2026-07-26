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
OUTDIR=${1:?usage: publish-updates.sh <release-out-dir> [--beta] [--retire <asset-key>]...}
shift
BETA=""; RETIREARGS=""
while [ $# -gt 0 ]; do case "$1" in
  --beta)   BETA="--beta"; shift;;
  --retire) RETIREARGS="$RETIREARGS --retire $2"; shift 2;;
  *) echo "publish-updates: unknown arg $1" >&2; exit 2;;
esac; done
# When a NextUI pak is published in the SAME release event, pass its version so the
# self-update manifest can advance notify.nextui honestly (else it is preserved from base).
NEXTUI_ARG=""
[ -n "${LODOR_NEXTUI_VERSION:-}" ] && NEXTUI_ARG="--nextui-version $LODOR_NEXTUI_VERSION"
VERSION=$(cat "$ROOT/VERSION")
TAG="v$VERSION"
REPO_SLUG="lodordev/lodor"
export LODOR_PII_REQUIRED=1   # private-mono caller: PII/branding gates must NOT fail open
fail(){ echo "PUBLISH ABORT: $*" >&2; exit 1; }
hash(){ sha256sum "$1" | cut -d" " -f1; }

TOKFILE="${LODOR_GH_TOKEN_FILE:-$HOME/.config/lodor/github-token}"
TOK="${GITHUB_TOKEN:-$(cat "$TOKFILE" 2>/dev/null || true)}"
[ -n "$TOK" ] || fail "no GitHub token (GITHUB_TOKEN or $TOKFILE)"
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
sh "$ROOT/release/mkversions.sh" "$OUTDIR" $BETA $BASEARG $NEXTUI_ARG $RETIREARGS
CHANNEL=$([ -n "$BETA" ] && echo beta || echo stable)
sh "$ROOT/release/gate.sh" update-manifest "$OUTDIR/versions.json" "$TAG" "$CHANNEL" || fail "update-manifest gate"

# Sign the manifest with the OFFLINE ed25519 key (security HIGH #4): devices
# verify this signature before trusting any hash. Signing runs AFTER the gate so
# we only ever sign a well-formed manifest. The key is read by PATH from the
# release host (out of repo, like the Android keystore); it is never copied in.
# LODOR_UPDATE_SIGNING_KEY overrides the default path if set.
echo "  signing versions.json (ed25519)"
# Docker volume mounts + go-run-after-cd both require an ABSOLUTE manifest path.
OUTDIR_ABS=$(cd "$OUTDIR" && pwd)
if command -v go >/dev/null 2>&1; then
  ( cd "$ROOT/release/cmd/lodor-signmanifest" && go run . "$OUTDIR_ABS/versions.json" ) \
    || fail "manifest signing (lodor-signmanifest)"
else
  # Pre-check the key path is a FILE: docker -v silently CREATES a directory at a
  # missing host path, which both wedges the mount point (root-owned dir where the
  # key should live) and produces an unhelpful in-container read error. Fail loud first.
  _key="${LODOR_UPDATE_SIGNING_KEY:-/mnt/user/appdata/lodor/update-signing-ed25519.key}"
  [ -f "$_key" ] || fail "manifest signing: key is not a file at $_key (docker -v would create a directory there; fix the path/host before re-running)"
  docker run --rm \
    -v "$ROOT/release/cmd/lodor-signmanifest":/src \
    -v "$OUTDIR_ABS":/out \
    -v "$_key":/key:ro \
    -w /src -e LODOR_UPDATE_SIGNING_KEY=/key \
    golang:1.25-bookworm go run . /out/versions.json \
    || fail "manifest signing (lodor-signmanifest, docker)"
fi
[ -f "$OUTDIR/versions.json.sig" ] || fail "signer produced no versions.json.sig"

echo "== 2/4 release $TAG on $REPO_SLUG =="
# Idempotent re-run (M5, the publish-lanes mkrel pattern): reuse an existing release
# for this tag — a publish interrupted after release-create used to be unrunnable
# ("does $TAG already exist?") without manual API surgery.
_relid=$(api GET "/repos/$REPO_SLUG/releases/tags/$TAG" 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
if [ -n "$_relid" ]; then
  echo "  release $TAG already exists (id $_relid) — reusing"
else
  _pre=false; [ -n "$BETA" ] && _pre=true
  _body=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":"Lodor "+sys.argv[2],"body":sys.argv[3],"prerelease":sys.argv[4]=="true"}))' \
    "$TAG" "$VERSION" "Self-update assets for Lodor $VERSION. Devices receive these via the in-app updater (LodorOS) or the store notice (NextUI/muOS)." "$_pre")
  _rel=$(api POST "/repos/$REPO_SLUG/releases" "$_body") || fail "release create $TAG"
  _relid=$(printf '%s' "$_rel" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
fi

sh "$ROOT/release/gate.sh" secrets "$OUTDIR" || fail "secrets gate (release out dir)"
echo "== 3/4 upload assets =="
for f in "$OUTDIR"/Lodor-LodorOS-update-*-"$VERSION".zip "$OUTDIR/versions.json" "$OUTDIR/versions.json.sig"; do
  [ -f "$f" ] || fail "missing artifact: $f"
  _n=$(basename "$f")
  # M5 re-run tolerance: every artifact is rebuilt each run, so a same-name asset from
  # a previous (possibly interrupted/stale) run is deleted and replaced — never trusted.
  _aid=$(api GET "/repos/$REPO_SLUG/releases/$_relid/assets?per_page=100" \
    | python3 -c 'import json,sys
n=sys.argv[1]
for a in json.load(sys.stdin):
    if a.get("name")==n: print(a["id"]); break' "$_n" 2>/dev/null || true)
  if [ -n "$_aid" ]; then
    echo "  replacing existing asset: $_n (id $_aid)"
    api DELETE "/repos/$REPO_SLUG/releases/assets/$_aid" || fail "stale-asset delete: $_n"
  fi
  _ct="application/zip"; case "$f" in *.json) _ct="application/json";; *.sig) _ct="text/plain";; esac
  curl -sfS -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: $_ct" \
    --data-binary @"$f" \
    "https://uploads.github.com/repos/$REPO_SLUG/releases/$_relid/assets?name=$_n" >/dev/null \
    || fail "asset upload: $_n"
  echo "  uploaded: $_n"
done

echo "== 4/4 dispatch publish-versions workflow (live verify + gh-pages) =="
api POST "/repos/$REPO_SLUG/actions/workflows/publish-versions.yml/dispatches" \
  "{\"ref\":\"main\",\"inputs\":{\"tag\":\"$TAG\"}}" >/dev/null \
  || fail "workflow dispatch (is .github/workflows/publish-versions.yml on main?)"
echo "== dispatched. The manifest goes live only after CI hash-verifies every asset. =="
echo "   watch: https://github.com/$REPO_SLUG/actions"
