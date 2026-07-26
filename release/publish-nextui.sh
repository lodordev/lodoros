#!/bin/sh
# publish-nextui.sh — cut a NextUI Pak Store release of Lodor.pak, gated or nothing.
#
# The Pak Store IS the update channel on NextUI (no bespoke self-update on this lane): the store
# reads pak.json from the ROOT of lodordev/lodor-nextui@main (hourly catalog rebuild) and
# installs/updates by downloading
#     <repo>/releases/download/<pak.json version>/Lodor.pak.zip
# and extracting it OVER Tools/<plat>/Lodor.pak — update_ignore-listed files skipped, nothing
# deleted. Two invariants this script enforces:
#   1. ORDERING (Grout's CI ordering, made local): the GitHub release with a RE-DOWNLOADED,
#      sha256-VERIFIED asset exists BEFORE pak.json names its version. The store must never
#      offer a version whose zip 404s or mismatches — and a broken pak.json fetch breaks the
#      ENTIRE store catalog build, not just our entry.
#   2. STORE-BLIND VERSIONING: the store compares versions numerically with prerelease suffixes
#      stripped, so every release must bump a numeric component (gate.sh store-version).
#
# Usage:
#   publish-nextui.sh stage                     assemble + gate + build Lodor.pak.zip (no side effects
#                                               outside release/out/). Needs docker.
#   NOTES="what changed" publish-nextui.sh publish
#                                               sync pak source -> the lodor-nextui clone, tag,
#                                               create the GitHub release, upload + verify assets,
#                                               THEN bump pak.json and push. Needs the clone +
#                                               a GitHub token; refuses without a prior stage.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GATE="$ROOT/release/gate.sh"
export LODOR_PII_REQUIRED=1   # private-mono caller: PII/branding gates must NOT fail open
VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || true)
[ -n "$VERSION" ] || { echo "ABORT: $ROOT/VERSION missing/empty — publishing wants an explicit version" >&2; exit 1; }
OUT="$ROOT/release/out/nextui-$VERSION"
ZIPF="$OUT/Lodor.pak.zip"
FULLZIP="$OUT/Lodor-NextUI-$VERSION.zip"
# The distribution repo clone (root pak.json + a public copy of the pak source). Kept OUTSIDE
# this repo; override with LODOR_NEXTUI_GIT.
NGIT="${LODOR_NEXTUI_GIT:-/mnt/user/appdata/lodor/work/lodor-nextui-git}"
REPO_SLUG="lodordev/lodor-nextui"
fail(){ echo "PUBLISH ABORT: $*" >&2; exit 1; }
hash(){ sha256sum "$1" | cut -d" " -f1; }

published_version(){ # last version pak.json ever named (the store's view of "current")
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$NGIT/pak.json"
}

stage(){
  command -v docker >/dev/null 2>&1 || fail "stage needs docker (run on the build host)"
  [ -f "$NGIT/pak.json" ] || fail "stage: lodor-nextui clone not found at $NGIT (set LODOR_NEXTUI_GIT)"
  sh "$GATE" store-version "$VERSION" "$(published_version)" || fail "store-version gate"

  echo "== assembling card tree (integrations/nextui/assemble.sh) =="
  CARD="$OUT/.card"
  rm -rf "$OUT"; mkdir -p "$OUT"
  sh "$ROOT/integrations/nextui/assemble.sh" "$CARD" || fail "assemble.sh"

  # ---- store zip: ONE zip serves both devices. The store extracts zip CONTENTS into
  # Tools/<plat>/Lodor.pak, so the zip root is the pak root and it must carry BOTH platform
  # host-tool dirs (bin/tg5040 + bin/tg5050 — launch.sh picks by $PLATFORM at runtime; the
  # binaries are the same arm64 builds either way).
  STAGE="$OUT/.pak-stage"
  rm -rf "$STAGE"
  cp -r "$CARD/Tools/tg5040/Lodor.pak" "$STAGE"            || fail "pak stage copy (tg5040)"
  cp -r "$CARD/Tools/tg5050/Lodor.pak/bin/tg5050" "$STAGE/bin/tg5050" || fail "pak stage graft (tg5050 bin)"
  # belt-and-braces device-state strip (assemble stages from source, but never trust a tree)
  find "$STAGE" \( -name config.json -o -name settings.conf -o -name catalog-index.json \
    -o -name pending-saves.txt -o -name download-queue.txt -o -name last-synced.txt \
    -o -name "*.log" -o -name ".pii-terms.conf" \) -type f -delete 2>/dev/null || true
  [ -f "$STAGE/config.json.template" ] || fail "config.json.template missing after strip"

  echo "== gates (store-zip stage) =="
  sh "$GATE" secrets         "$STAGE" || fail "secrets gate"
  sh "$GATE" branding        "$STAGE" || fail "branding gate"
  sh "$GATE" no-legacy       "$STAGE" || fail "no-legacy gate"
  sh "$GATE" cruft           "$STAGE" || fail "cruft gate"
  sh "$GATE" agent-pii       "$STAGE" || fail "agent-pii gate"
  sh "$GATE" redistributable "$STAGE" || fail "redistributable gate"

  rm -f "$ZIPF" "$FULLZIP"
  ( cd "$STAGE" && zip -rqX "$ZIPF" . -x ".DS_Store" ) || fail "store zip"
  # full card zip (fresh installs outside the store: Tools + Emus + Roms entries pre-laid;
  # the pak self-heals these anyway, so the store zip alone is complete — this is convenience)
  sh "$GATE" branding "$CARD" >/dev/null || fail "card branding gate"
  ( cd "$CARD" && zip -rqX "$FULLZIP" . -x ".DS_Store" ) || fail "card zip"
  ( cd "$OUT" && sha256sum "$(basename "$ZIPF")" "$(basename "$FULLZIP")" > SHA256SUMS.txt )
  rm -rf "$STAGE" "$CARD"
  echo "== staged: =="
  cat "$OUT/SHA256SUMS.txt"
}

github(){ # github <method> <path> [json-body]  — minimal API driver (no gh dependency)
  _tok="${GITHUB_TOKEN:-$(cat "${LODOR_GH_TOKEN_FILE:-$HOME/.config/lodor/github-token}" 2>/dev/null || true)}"
  [ -n "$_tok" ] || fail "no GitHub token (GITHUB_TOKEN or $LODOR_GH_TOKEN_FILE)"
  if [ -n "${3:-}" ]; then
    curl -sfS -X "$1" -H "Authorization: Bearer $_tok" -H "Accept: application/vnd.github+json" \
      -d "$3" "https://api.github.com$2"
  else
    curl -sfS -X "$1" -H "Authorization: Bearer $_tok" -H "Accept: application/vnd.github+json" \
      "https://api.github.com$2"
  fi
}

publish(){
  [ -f "$ZIPF" ] && [ -f "$FULLZIP" ] || fail "publish: no staged artifacts for $VERSION — run '$0 stage' first"
  [ -n "${NOTES:-}" ] || fail "publish: set NOTES='what changed' (becomes the release body + pak.json changelog)"
  [ -d "$NGIT/.git" ] || fail "publish: lodor-nextui clone not found at $NGIT"
  sh "$GATE" store-version "$VERSION" "$(published_version)" || fail "store-version gate"

  echo "== 1/5 sync pak source -> $REPO_SLUG =="
  # tracked integration source only — the same no-live-state rule as every other artifact
  rsync -a --delete \
    --exclude .git --exclude "*.log" --exclude config.json --exclude settings.conf \
    "$ROOT/integrations/nextui/Lodor.pak/" "$NGIT/Lodor.pak/"
  cp "$ROOT/integrations/nextui/assemble.sh" "$NGIT/assemble.sh"
  rsync -a --delete --exclude "*.log" "$ROOT/integrations/nextui/test/" "$NGIT/test/"
  rsync -a --delete "$ROOT/integrations/nextui/qr-helper/" "$NGIT/qr-helper/" 2>/dev/null || true
  ( cd "$NGIT" && git add -A && \
    { git diff --cached --quiet || git commit -q -m "sync pak source for $VERSION"; } && \
    git push -q origin HEAD ) || fail "pak source sync/push"

  echo "== 2/5 tag + release $VERSION =="
  ( cd "$NGIT" && git tag "$VERSION" 2>/dev/null || true; git push -q origin "$VERSION" ) || fail "tag push"
  # Idempotent re-run (M5, the publish-lanes mkrel pattern): reuse an existing release
  # for this tag — a publish interrupted after release-create must be re-runnable.
  _relid=$(github GET "/repos/$REPO_SLUG/releases/tags/$VERSION" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
  if [ -n "$_relid" ]; then
    echo "  release $VERSION already exists (id $_relid) — reusing"
  else
    _body=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":"Lodor "+sys.argv[1],"body":sys.argv[2],"prerelease":False}))' "$VERSION" "$NOTES")
    _rel=$(github POST "/repos/$REPO_SLUG/releases" "$_body") || fail "release create"
    _relid=$(printf '%s' "$_rel" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  fi

  echo "== 3/5 upload assets =="
  _tok="${GITHUB_TOKEN:-$(cat "${LODOR_GH_TOKEN_FILE:-$HOME/.config/lodor/github-token}")}"
  for f in "$ZIPF" "$FULLZIP"; do
    _n=$(basename "$f")
    # M5 re-run tolerance: replace any same-name asset from a previous (possibly
    # interrupted) run — step 4/5 then re-download-verifies whatever is live.
    _aid=$(github GET "/repos/$REPO_SLUG/releases/$_relid/assets?per_page=100" \
      | python3 -c 'import json,sys
n=sys.argv[1]
for a in json.load(sys.stdin):
    if a.get("name")==n: print(a["id"]); break' "$_n" 2>/dev/null || true)
    if [ -n "$_aid" ]; then
      echo "  replacing existing asset: $_n (id $_aid)"
      github DELETE "/repos/$REPO_SLUG/releases/assets/$_aid" || fail "stale-asset delete: $_n"
    fi
    curl -sfS -X POST -H "Authorization: Bearer $_tok" -H "Content-Type: application/zip" \
      --data-binary @"$f" \
      "https://uploads.github.com/repos/$REPO_SLUG/releases/$_relid/assets?name=$_n" >/dev/null \
      || fail "asset upload: $_n"
  done

  echo "== 4/5 verify assets LIVE (re-download + sha256) =="
  for f in "$ZIPF" "$FULLZIP"; do
    _url="https://github.com/$REPO_SLUG/releases/download/$VERSION/$(basename "$f")"
    _tmp=$(mktemp)
    curl -sfSL -o "$_tmp" "$_url" || { rm -f "$_tmp"; fail "verify download: $_url"; }
    [ "$(hash "$_tmp")" = "$(hash "$f")" ] || { rm -f "$_tmp"; fail "verify: live $(basename "$f") hash MISMATCH"; }
    rm -f "$_tmp"
    echo "  ok: $(basename "$f") live + hash-verified"
  done

  echo "== 5/5 write pak.json from tracked source + bump (the store-visible manifest) =="
  # The store manifest is SOURCED from the mono (integrations/nextui/pak.store.json) so tracked
  # fields — scripts.post_uninstall (#30), update_ignore, platforms — reach the store instead of
  # drifting in the clone. We overlay this release's version and MERGE changelog history from
  # whatever the clone already published (never lose past entries).
  python3 - "$ROOT/integrations/nextui/pak.store.json" "$NGIT/pak.json" "$VERSION" "$NOTES" <<'PY' || fail "pak.json bump"
import json, sys
src, dst, ver, notes = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(src))
prev = {}
try:
    prev = json.load(open(dst)).get("changelog", {})
except Exception:
    pass
cl = dict(d.get("changelog", {}))
cl.update(prev)
cl[ver] = notes
d["changelog"] = cl
d["version"] = ver
open(dst, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
  # M5: tolerate an unchanged pak.json (re-run after the bump already landed) — an
  # empty diff skips the commit but the push + store-visibility contract still runs.
  ( cd "$NGIT" && git add pak.json && \
    { git diff --cached --quiet || git commit -q -m "Lodor $VERSION"; } && \
    git push -q origin HEAD ) \
    || fail "pak.json push"
  echo "== published: $REPO_SLUG@$VERSION — the store catalog picks it up within ~1 hour =="
}

case "${1:-}" in
  stage)   stage;;
  publish) publish;;
  *) echo "usage: $0 {stage|publish}   (NOTES='...' required for publish)"; exit 2;;
esac
