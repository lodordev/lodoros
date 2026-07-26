#!/bin/sh
# publish-daijisho.sh — generate + publish Lodor's static Daijishō config to gh-pages.
#
# Daijishō can only be configured by fetching an index.json URL over HTTPS (it has no
# file-import intent — verified on-device 2026-07-18). The Lodor config is NOT per-user —
# every platform just wires a system to Lodor's ProxyLaunchActivity — so ONE published set
# serves everyone, and the app (DaijishoIntegration.PUBLISHED_INDEX_URI) tells users to paste
#   https://lodordev.github.io/lodor/daijisho/index.json
# into Daijishō → Library → Download platforms → INDEX URI.
#
# These are STATIC, UNSIGNED assets — deliberately NOT routed through the signed versions.json
# / publish-versions verification pipeline (that is for device-trusted update manifests). A
# plain gh-pages commit is the correct, simpler mechanism here.
#
# Env:
#   LODOR_GH_TOKEN_FILE  token file (default ~/.config/lodor/github-token), or GITHUB_TOKEN
#   REPO_SLUG            gh-pages repo (default lodordev/lodor)
#   GH_PAGES_BRANCH      branch served as pages (default gh-pages)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO_SLUG="${REPO_SLUG:-lodordev/lodor}"
BRANCH="${GH_PAGES_BRANCH:-gh-pages}"
BASE_URI="https://lodordev.github.io/lodor/daijisho/"
CATALOG="$ROOT/integrations/android/app/src/main/assets/esde_systems.json"
GEN="$ROOT/integrations/android/templates/daijisho/gen-daijisho.py"

TOK="${GITHUB_TOKEN:-}"
if [ -z "$TOK" ]; then
  TOKFILE="${LODOR_GH_TOKEN_FILE:-$HOME/.config/lodor/github-token}"
  [ -f "$TOKFILE" ] || { echo "FATAL: no token — set GITHUB_TOKEN or $TOKFILE" >&2; exit 2; }
  TOK=$(tr -d '\n' < "$TOKFILE")
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "== 1/3 generate config from the ES-DE catalog =="
python3 "$GEN" "$CATALOG" "$WORK/daijisho" "$BASE_URI"

echo "== 2/3 clone gh-pages ($REPO_SLUG@$BRANCH) =="
git clone --depth 1 --branch "$BRANCH" \
  "https://x-access-token:$TOK@github.com/$REPO_SLUG.git" "$WORK/pages" >/dev/null 2>&1 \
  || { echo "FATAL: clone of $BRANCH failed (does the branch exist?)" >&2; exit 3; }

echo "== 3/3 stage + commit + push =="
rm -rf "$WORK/pages/daijisho"
mkdir -p "$WORK/pages/daijisho"
cp "$WORK"/daijisho/*.json "$WORK/pages/daijisho/"
cd "$WORK/pages"
git add daijisho
if git diff --cached --quiet; then
  echo "no changes — daijisho config already current at $BASE_URI"
  exit 0
fi
_n=$(ls "$WORK"/daijisho/*.platform.json | wc -l | tr -d ' ')
git -c user.name="lodor-ci" -c user.email="ci@lodor.dev" \
  commit -q -m "daijisho: publish static platform config ($_n systems)"
git push origin "$BRANCH"
echo "published: ${BASE_URI}index.json  ($_n platforms)"
