#!/bin/sh
# mkstatecompat.sh — emit state-compat.json, the D8 certification whitelist
# (design lodor-statesync-design-2026-07-07.md), from cross-arch cert RESULTS.
#
# The engine's Tier-0 compatibility is exact-tuple (core@version + arch). This
# file WIDENS it with facts earned by release/xarch-cert/: each class declares a
# core whose save-state format interoperates across a set of architectures
# (any version, any frontend). Absent file = feature dark = Tier-0 only.
#
# THE ENTRIES ARE CERTIFICATION FACTS, NOT WISHES. Only add a (core, arches)
# class after the xarch-cert harness PASSES for it. As of 2026-07-07:
#   PASS cross-arch (armhf,arm64): fceumm, gambatte, picodrive
#   arm64-only bridge (Android @unknown ↔ pinned): gpsp, snes9x2005_plus
#     — these FAILED cross-arch cert; arm64-only is the within-group/version
#       bridge, and by the 2026-07-07 design call SNES/GBA stay within-group.
#
# Usage:
#   mkstatecompat.sh --out <file> <core>:<arch>[,<arch>...] ...
# Example (the certified 2026-07-07 fleet whitelist):
#   mkstatecompat.sh --out sb/state-compat.json \
#     fceumm:armhf,arm64 gambatte:armhf,arm64 picodrive:armhf,arm64 \
#     gpsp:arm64 snes9x2005_plus:arm64
#
# Self-validates against the engine loader contract (version 1, non-empty
# classes, each class core+arches non-empty). Fails loud on a malformed spec.
set -eu

OUT=""
while [ $# -gt 0 ]; do case "$1" in
	--out) OUT=$2; shift 2;;
	--*) echo "mkstatecompat: unknown flag $1" >&2; exit 2;;
	*) break;;
esac; done
[ -n "$OUT" ] || { echo "mkstatecompat: --out required" >&2; exit 2; }
[ $# -gt 0 ] || { echo "mkstatecompat: at least one <core>:<arch>[,arch] class required" >&2; exit 2; }

CLASSES=""
for spec in "$@"; do
	case "$spec" in *'"'*|*'\'*) echo "mkstatecompat: illegal char in spec: $spec" >&2; exit 2;; esac
	core=${spec%%:*}
	arches=${spec#*:}
	[ -n "$core" ] && [ "$core" != "$spec" ] || { echo "mkstatecompat: bad spec (no ':<arch>'): $spec" >&2; exit 2; }
	[ -n "$arches" ] || { echo "mkstatecompat: empty arch list: $spec" >&2; exit 2; }
	# render "arm64","armhf"
	alist=""
	OLDIFS=$IFS; IFS=,
	for a in $arches; do
		case "$a" in armhf|arm64) ;; *) echo "mkstatecompat: arch must be armhf|arm64: $a" >&2; IFS=$OLDIFS; exit 2;; esac
		[ -n "$alist" ] && alist="$alist, "
		alist="$alist\"$a\""
	done
	IFS=$OLDIFS
	entry="    {\"core\": \"$core\", \"arches\": [$alist]}"
	[ -n "$CLASSES" ] && CLASSES="$CLASSES,
"
	CLASSES="$CLASSES$entry"
done

TMP="$OUT.tmp.$$"
cat > "$TMP" << EOF
{
  "version": 1,
  "classes": [
$CLASSES
  ]
}
EOF

if command -v jq >/dev/null 2>&1; then
	jq -e '(.version==1) and (.classes|length>0) and ([.classes[] | (.core|length>0) and (.arches|length>0)]|all)' \
		"$TMP" >/dev/null || { echo "mkstatecompat: emitted JSON failed validation" >&2; rm -f "$TMP"; exit 1; }
elif command -v python3 >/dev/null 2>&1; then
	python3 - "$TMP" << 'PYEOF' || { rm -f "$TMP"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d["version"] == 1 and d["classes"]
for c in d["classes"]:
    assert c["core"] and c["arches"]
PYEOF
else
	echo "mkstatecompat: need jq or python3 to validate — refusing to emit unchecked" >&2
	rm -f "$TMP"; exit 1
fi

mv "$TMP" "$OUT"
echo "mkstatecompat: wrote $OUT ($# classes)"
