#!/bin/sh
# autoheal-check.sh — offline gate for the romm-syncd auto.sh self-heal (lodoros#18).
#
# The bug: cards built before install.sh grew the "# lodor-update-apply" auto.sh line stage
# self-updates forever and never apply them (overlays refresh the pak, nothing re-runs
# install.sh). The fix: romm-syncd heals auto.sh at startup — sentinel-guarded, atomic
# temp+mv, applier line inserted ABOVE its own start line — and if a READY staging is
# already waiting, hands off to a detached runner that applies it on THIS boot and
# restarts the daemon.
#
# What this proves, without hardware, against the REAL romm-syncd/lodor-apply-update/install.sh:
#   1. HEAL+APPLY — pre-fix auto.sh (syncd line, NO sentinel) + staged READY tree: after daemon
#      startup the applier line exists ABOVE the syncd line, the applier ran, the update landed
#      (engine swapped, staging cleared, .update-applied marker), heal was logged.
#   2. SENTINEL NO-OP — auto.sh that already carries the sentinel is returned byte-identical.
#   3. CREATE — missing auto.sh is created in install.sh's shape (shebang, applier above syncd).
#   4. FAIL SAFE — a heal that cannot write (awk failure stands in for readonly/full media)
#      leaves auto.sh byte-identical, leaves NO temp droppings, logs the failure, and the
#      daemon still starts. Atomic temp+mv means a partial write is impossible by construction.
#
# Run from anywhere: paths are derived from this script's location. Exit 0 = all green.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"   # lodoros/test -> repo root
LODOROS="$ROOT/lodoros"
PAKSRC="$LODOROS/paks/Lodor.pak"
FAILS=0

say()  { printf '%s\n' "$*"; }
pass() { say "  ok: $*"; }
fail() { say "  FAIL: $*"; FAILS=$((FAILS+1)); }

SANDBOX="$(mktemp -d /tmp/autoheal-check.XXXXXX)"
DPIDS=""
cleanup() {
	for p in $DPIDS; do kill "$p" 2>/dev/null; done
	rm -rf "$SANDBOX"
}
trap cleanup EXIT INT TERM

# PATH-shadowed killall: the real applier killalls romm-syncd — never let a test touch host
# processes (or get poisoned by them). Same shadowing pattern as wrapper-check's fake pgrep.
FAKEBIN="$SANDBOX/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/killall"
chmod +x "$FAKEBIN/killall"
PATH="$FAKEBIN:$PATH"; export PATH

SYNCD_AUTOLINE='test -x "$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak/bin/romm-syncd" && "$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak/bin/romm-syncd" >/dev/null 2>&1 </dev/null & # romm-syncd'

# build_card <n> [staged] — fake card at $SD: real syncd/applier/install.sh, stub lib.
# With "staged", a verified-shape .update (READY + tree) is present; the staged lib exits the
# re-exec'd daemon at source time so no test process outlives its case.
build_card() {
	SD="$SANDBOX/sd$1"
	PAK="$SD/Tools/miyoomini/Lodor.pak"
	AUTO="$SD/.userdata/miyoomini/auto.sh"
	SLOG="$PAK/syncd.log"
	mkdir -p "$PAK/bin" "$PAK/lib" "$SD/.userdata/miyoomini" "$SD/.system/miyoomini/bin"
	cp "$PAKSRC/bin/romm-syncd" "$PAK/bin/romm-syncd"
	cp "$PAKSRC/bin/lodor-apply-update" "$PAK/bin/lodor-apply-update"
	cp "$PAKSRC/bin/minarch-shim.sh" "$PAK/bin/minarch-shim.sh"
	cp "$PAKSRC/install.sh" "$PAK/install.sh"
	printf 'old-engine\n' > "$PAK/lodor-sync"
	printf 'launch\n' > "$PAK/launch.sh"
	# stub lib: just enough for startup + the EXIT trap; the loop is never reached for long.
	printf 'wifi_release() { :; }\n' > "$PAK/lib/romm-sync-lib.sh"
	printf '\177ELF-fake-stock-minarch\n' > "$SD/.system/miyoomini/bin/minarch.elf"
	printf '\177ELF-fake-stock-minui\n'   > "$SD/.system/miyoomini/bin/minui"
	chmod +x "$PAK/bin/"* "$PAK/install.sh" "$PAK/lodor-sync"
	if [ "${2:-}" = staged ]; then
		TREE="$PAK/.update/tree/Tools/miyoomini/Lodor.pak"
		mkdir -p "$TREE/bin" "$TREE/lib"
		printf 'NEW-engine-healed\n' > "$TREE/lodor-sync"
		cp "$PAK/install.sh" "$TREE/install.sh"
		cp "$PAK/bin/lodor-apply-update" "$TREE/bin/lodor-apply-update"
		cp "$PAK/bin/minarch-shim.sh" "$TREE/bin/minarch-shim.sh"
		cp "$PAK/bin/romm-syncd" "$TREE/bin/romm-syncd"
		# test-only: the post-apply re-exec'd daemon exits 0 at lib-source, so the case ends.
		printf 'wifi_release() { :; }\nexit 0\n' > "$TREE/lib/romm-sync-lib.sh"
		printf 'version=0.9.9-test\nsha=cafef00dcafef00d\n' > "$PAK/.update/READY"
		# birth-stamped version.txt: the applier must overwrite BOTH lines (F: it read
		# READY's sha AFTER rm -rf'ing the staging, so line 2 was always "updated").
		printf 'LodorOS-0.0.0-birth\nbirth-sha\n' > "$SD/.system/version.txt"
	fi
}

# start_syncd — launch the card's real daemon exactly as auto.sh would (detached).
start_syncd() {
	SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/romm-syncd" >/dev/null 2>&1 </dev/null &
	DPIDS="$DPIDS $!"
	LAST_DPID=$!
}

assert_order() {
	_a=$(grep -n "# lodor-update-apply" "$AUTO" | cut -d: -f1 | head -1)
	_s=$(grep -n "# romm-syncd" "$AUTO" | cut -d: -f1 | head -1)
	if [ -n "$_a" ] && [ -n "$_s" ] && [ "$_a" -lt "$_s" ]; then
		pass "applier line present ABOVE the syncd line ($_a < $_s)"
	else
		fail "auto.sh ordering wrong (apply=${_a:-none} syncd=${_s:-none})"
	fi
	[ "$(grep -c "lodor-update-apply" "$AUTO")" = 1 ] \
		&& pass "exactly one applier line (no duplicates)" || fail "duplicate applier lines"
}

# ─── 1. HEAL + IMMEDIATE APPLY (the live-repro'd card) ─────────────────────────────
say "[1/4] pre-fix auto.sh + staged READY -> healed AND applied on this boot"
build_card 1 staged
cat > "$AUTO" <<EOF
#!/bin/sh

test -f /tmp/wpa-seed && : # wpa-seed stand-in
$SYNCD_AUTOLINE
EOF
chmod +x "$AUTO"
start_syncd
# heal is instant; the apply rides a detached runner — poll for the applied marker.
i=0
while [ "$i" -lt 30 ] && [ ! -f "$PAK/.update-applied" ]; do sleep 0.5; i=$((i+1)); done
assert_order
grep -q "healed auto.sh: update applier hook" "$SLOG" 2>/dev/null \
	&& pass "heal logged to syncd.log" || fail "heal log line missing"
[ -f "$PAK/.update-applied" ] && [ "$(cat "$PAK/.update-applied")" = "0.9.9-test" ] \
	&& pass ".update-applied marker = 0.9.9-test" || fail "applied marker missing/wrong"
grep -q "NEW-engine-healed" "$PAK/lodor-sync" 2>/dev/null \
	&& pass "engine binary swapped by the boot-time apply" || fail "engine NOT swapped"
[ ! -d "$PAK/.update" ] && pass "staging cleared after apply" || fail "staging left behind"
[ "$(sed -n 1p "$SD/.system/version.txt" 2>/dev/null)" = "LodorOS-0.9.9-test" ] \
	&& pass "version.txt line 1 = LodorOS-0.9.9-test" \
	|| fail "version.txt line 1 wrong: '$(sed -n 1p "$SD/.system/version.txt" 2>/dev/null)'"
[ "$(sed -n 2p "$SD/.system/version.txt" 2>/dev/null)" = "cafef00dcafef00d" ] \
	&& pass "version.txt line 2 = staged sha (captured before staging rm)" \
	|| fail "version.txt line 2 != staged sha: '$(sed -n 2p "$SD/.system/version.txt" 2>/dev/null)'"
grep -q "heal-apply done" "$SLOG" 2>/dev/null \
	&& pass "apply outcome logged" || fail "apply outcome log line missing"

# ─── 2. SENTINEL PRESENT -> BYTE-IDENTICAL NO-OP ───────────────────────────────────
say "[2/4] auto.sh already carrying the sentinel is untouched"
build_card 2
APPLY_AUTOLINE='test -x "$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak/bin/lodor-apply-update" && "$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak/bin/lodor-apply-update" # lodor-update-apply'
cat > "$AUTO" <<EOF
#!/bin/sh

$APPLY_AUTOLINE
$SYNCD_AUTOLINE
EOF
chmod +x "$AUTO"
cp "$AUTO" "$SANDBOX/auto2.before"
start_syncd
sleep 2
cmp -s "$SANDBOX/auto2.before" "$AUTO" \
	&& pass "auto.sh byte-identical after startup" || fail "auto.sh was modified despite sentinel"
kill "$LAST_DPID" 2>/dev/null
[ ! -f "$AUTO.new" ] && pass "no temp droppings" || fail "$AUTO.new left behind"

# ─── 3. MISSING auto.sh -> CREATED IN install.sh's SHAPE ──────────────────────────
say "[3/4] missing auto.sh is created correctly"
build_card 3
rm -f "$AUTO"
start_syncd
sleep 2
if [ -f "$AUTO" ]; then
	pass "auto.sh created"
	head -1 "$AUTO" | grep -q '^#!/bin/sh' && pass "shebang present" || fail "no shebang"
	assert_order
	grep -q "healed auto.sh: update applier hook" "$SLOG" 2>/dev/null \
		&& pass "heal logged" || fail "heal log line missing"
else
	fail "auto.sh not created"
fi
kill "$LAST_DPID" 2>/dev/null

# ─── 4. UNWRITABLE MEDIA -> FAILS SAFE ─────────────────────────────────────────────
# A failing awk stands in for readonly/full media (chmod can't fence root, which CI runs as).
# The contract under test is the temp+mv atomicity: on ANY write failure auto.sh is untouched,
# no temp file survives, the failure is logged, and the daemon still starts.
say "[4/4] unwritable auto.sh fails safe (logged, daemon up, file untouched)"
build_card 4
cat > "$AUTO" <<EOF
#!/bin/sh

$SYNCD_AUTOLINE
EOF
chmod +x "$AUTO"
cp "$AUTO" "$SANDBOX/auto4.before"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/awk"
chmod +x "$FAKEBIN/awk"
start_syncd
sleep 2
rm -f "$FAKEBIN/awk"
cmp -s "$SANDBOX/auto4.before" "$AUTO" \
	&& pass "auto.sh byte-identical after failed heal" || fail "failed heal modified auto.sh"
[ ! -f "$AUTO.new" ] && pass "no partial temp file left" || fail "$AUTO.new left behind"
grep -q "auto.sh heal FAILED" "$SLOG" 2>/dev/null \
	&& pass "failure logged" || fail "failure not logged"
kill -0 "$LAST_DPID" 2>/dev/null \
	&& pass "daemon still running after failed heal" || fail "daemon died on failed heal"
kill "$LAST_DPID" 2>/dev/null

say ""
if [ "$FAILS" = 0 ]; then say "ALL GREEN"; else say "$FAILS FAILURE(S)"; fi
[ "$FAILS" = 0 ]
