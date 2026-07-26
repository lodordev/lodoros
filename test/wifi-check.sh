#!/bin/sh
# wifi-check.sh — offline regression gate for the LodorOS Wi-Fi readiness layer (task #184).
#
# THE SHIPPED BUG (my355 / Miyoo Flip V2, RK3566 / RTL8821CS SDIO): the radio associates
# briefly then DROPS, leaving wlan0 up with a STALE IP. The old _radio_ready gated on
# up+IP ALONE, so it returned a FALSE POSITIVE on the wedged link — wifi_acquire
# short-circuited past service-on and the my355 drop-recovery, and a fresh card never
# had its wpa_supplicant.conf generated. The fix ($PLAT-gated so miyoomini is
# byte-for-byte unchanged): on my355, _radio_ready ALSO requires wpa_state=COMPLETED,
# and _wifi_write_config now runs for my355.
#
# This proves, with NO hardware and NO root writes, the three fixed facts:
#   1. TRUTH TABLE — given wlan0 up + stale IP + wpa_state!=COMPLETED:
#        _radio_ready is FALSE for my355, TRUE for miyoomini.
#   2. POSITIVE — my355 with wpa_state=COMPLETED is READY (the fix doesn't over-block).
#   3. WRITE-CONFIG — _wifi_write_config runs for my355, generates a wpa_supplicant.conf
#        pinning ctrl_interface=/var/run/wpa_supplicant + one network{} block from
#        wifi.txt, and BAILS (no clobber) on an empty wifi.txt.
#
# Run from anywhere: exit 0 = all green. Sourced under `set +u` (the lib predates -u).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"           # lodoros/test -> repo root
LIB="$ROOT/lodoros/paks/Lodor.pak/lib/romm-sync-lib.sh"
FAILS=0

say()  { printf '%s\n' "$*"; }
pass() { say "  ok: $*"; }
fail() { say "  FAIL: $*"; FAILS=$((FAILS+1)); }

[ -f "$LIB" ] || { say "wifi-check: missing lib $LIB"; exit 2; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/wifi-check.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# A mock wpa_cli that prints the configured wpa_state for a `status` call. It ignores
# every arg (including my355's `-p /var/run/wpa_supplicant`) so both invocations parse.
MOCK_WPA="$SANDBOX/wpa_cli"
cat > "$MOCK_WPA" <<'EOF'
#!/bin/sh
echo "wpa_state=${MOCK_WPA_STATE:-ASSOCIATING}"
EOF
chmod +x "$MOCK_WPA"

# radio_ready_for <plat> <wpa_state> — source the lib fresh for that platform (so the
# per-PLAT _WPA_CLI/_WPA_CP resolution runs), force wlan0 up+IP, and return _radio_ready's
# verdict. Prints "READY" or "NOTREADY".
radio_ready_for() {
	_plat="$1"; _state="$2"
	(
		set +u
		export PLATFORM="$_plat"
		export SDCARD_PATH="$SANDBOX/card"
		export WPA_CLI="$MOCK_WPA"
		export MOCK_WPA_STATE="$_state"
		export WIFI_DBG="$SANDBOX/wifi-$_plat.log"
		. "$LIB" >/dev/null 2>&1
		# Force the up+IP predicate true so the ONLY variable is the assoc gate.
		_have_up() { return 0; }
		_have_ip() { return 0; }
		if _radio_ready; then echo READY; else echo NOTREADY; fi
	)
}

say "== 1. TRUTH TABLE: up + stale IP + wpa_state != COMPLETED =="
r=$(radio_ready_for my355 ASSOCIATING)
[ "$r" = NOTREADY ] && pass "my355 stale-link -> NOT ready (assoc gate closes the false positive)" \
	|| fail "my355 stale-link -> $r (want NOTREADY)"
r=$(radio_ready_for miyoomini ASSOCIATING)
[ "$r" = READY ] && pass "miyoomini up+IP -> ready (unchanged up+IP predicate)" \
	|| fail "miyoomini up+IP -> $r (want READY)"

say "== 2. POSITIVE: my355 with wpa_state=COMPLETED is ready =="
r=$(radio_ready_for my355 COMPLETED)
[ "$r" = READY ] && pass "my355 associated (COMPLETED) -> ready (fix doesn't over-block)" \
	|| fail "my355 COMPLETED -> $r (want READY)"

say "== 3. WRITE-CONFIG: _wifi_write_config runs for my355 =="
# Run _wifi_write_config for my355 with a valid wifi.txt, capturing whatever it INSTALLS
# (the built conf) without touching any root path — cp/mkdir are shadowed so the root
# destinations (/userdata/cfg, ...) are never written, and the install source is snapshot
# to CAPTURE instead. The template->_out copy stays real (it targets /tmp).
CAPTURE="$SANDBOX/installed-wpa.conf"
run_write_config() {
	_plat="$1"
	(
		set +u
		export PLATFORM="$_plat"
		export SDCARD_PATH="$SANDBOX/card"
		export WIFI_DBG="$SANDBOX/wc-$_plat.log"
		card="$SANDBOX/card"
		# Stock template the lib copies from: res/ beside Wifi.pak/bin.
		resdir="$card/Tools/$_plat/Wifi.pak/res"
		mkdir -p "$resdir" "$card"
		printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\n' \
			> "$resdir/wpa_supplicant.conf.$_plat.tmpl"
		printf 'TestNet:secret123\n' > "$card/wifi.txt"
		. "$LIB" >/dev/null 2>&1
		# Hermetic shadows: never write a root path; snapshot the installed conf.
		mkdir() { for _a in "$@"; do :; done; case "$1" in -p) shift ;; esac
			case "$1" in "$SANDBOX"/*|/tmp/*) command mkdir "$@" ;; *) return 0 ;; esac ; }
		cp() { case "$2" in
				"$SANDBOX"/*|/tmp/*) command cp "$@" ;;
				*/wpa_supplicant.conf) command cp "$1" "$CAPTURE" 2>/dev/null ;;
				*) : ;;
			esac ; return 0 ; }
		_wifi_write_config
	)
}
rm -f "$CAPTURE"
run_write_config my355
if [ -f "$CAPTURE" ]; then
	grep -q 'ctrl_interface=/var/run/wpa_supplicant' "$CAPTURE" \
		&& pass "my355 conf pins ctrl_interface=/var/run/wpa_supplicant" \
		|| fail "my355 conf missing ctrl_interface pin"
	grep -q 'ssid="TestNet"' "$CAPTURE" \
		&& pass "my355 conf carries the wifi.txt network block" \
		|| fail "my355 conf missing network block"
	grep -q 'psk="secret123"' "$CAPTURE" \
		&& pass "my355 conf carries the psk" \
		|| fail "my355 conf missing psk"
else
	fail "_wifi_write_config produced no installed conf for my355 (root-cause-3 regressed)"
fi
if grep -q 'regenerated wpa_supplicant.conf for my355 (1 network(s))' "$SANDBOX/wc-my355.log" 2>/dev/null; then
	pass "my355 write-config logged 1 network (ran to completion, no empty bail)"
else
	fail "my355 write-config did not log a completed regeneration"
fi

say "== 3b. WRITE-CONFIG empty-wifi.txt no-clobber =="
empty_bail() {
	(
		set +u
		export PLATFORM="my355"
		export SDCARD_PATH="$SANDBOX/card2"
		export WIFI_DBG="$SANDBOX/wc-empty.log"
		card="$SANDBOX/card2"
		resdir="$card/Tools/my355/Wifi.pak/res"
		mkdir -p "$resdir" "$card"
		printf 'ctrl_interface=/var/run/wpa_supplicant\n' > "$resdir/wpa_supplicant.conf.my355.tmpl"
		: > "$card/wifi.txt"   # EMPTY
		. "$LIB" >/dev/null 2>&1
		mkdir() { for _a in "$@"; do :; done; case "$1" in -p) shift ;; esac
			case "$1" in "$SANDBOX"/*|/tmp/*) command mkdir "$@" ;; *) return 0 ;; esac ; }
		cp() { case "$2" in "$SANDBOX"/*|/tmp/*) command cp "$@" ;; *) : ;; esac ; return 0 ; }
		if _wifi_write_config; then echo RAN; else echo BAILED; fi
	)
}
r=$(empty_bail)
[ "$r" = BAILED ] && pass "empty wifi.txt -> _wifi_write_config bails (no clobber)" \
	|| fail "empty wifi.txt -> $r (want BAILED)"

say "== 4. MUTEX RECLAIM: liveness decides; age only tiebreaks unparseable owners =="
# A LIVE holder must NEVER be revoked, however old its ts (long downloads are legitimate).
# A dead owner is reclaimed regardless of ts age. An unparseable owner (kill -0 can't
# answer) falls back to the age tiebreak. Plus: wifi_lock_refresh is the holder-side ts
# bump the daemons use between engine calls.
MLOCK="$SANDBOX/romm-wifi.lock"
# mutex_probe <owner> <ts-age-s> <mode> — stage a lock, run wifi_acquire against it,
# print ACQUIRED/BUSY/ERR. _radio_ready forced true so acquire returns right after the gate.
mutex_probe() {
	_own="$1"; _age="$2"; _mode="$3"
	rm -rf "$MLOCK"; command mkdir -p "$MLOCK"
	printf '%s' "$_own" > "$MLOCK/owner"
	echo $(( $(date +%s) - _age )) > "$MLOCK/ts"
	(
		set +u
		export PLATFORM=miyoomini SDCARD_PATH="$SANDBOX/card" WIFI_DBG="$SANDBOX/wifi-mutex.log"
		. "$LIB" >/dev/null 2>&1
		_WIFI_LOCK="$MLOCK"; WIFI_LOG="$SANDBOX/wifi-mutex.log"
		_radio_ready() { return 0; }
		if wifi_acquire "$_mode"; then echo ACQUIRED; else
			rc=$?; [ "$rc" = 2 ] && echo BUSY || echo ERR
		fi
	)
}
sleep 300 & MLIVE=$!
r=$(mutex_probe "$MLIVE" 9999 bg)
[ "$r" = BUSY ] && pass "LIVE holder + ancient ts -> BUSY (live holder never revoked)" \
	|| fail "live old holder -> $r (want BUSY — mid-transfer revocation regressed)"
[ "$(cat "$MLOCK/owner" 2>/dev/null)" = "$MLIVE" ] && pass "live holder's lock left untouched" \
	|| fail "live holder's lock files were reclaimed"
kill "$MLIVE" 2>/dev/null; wait "$MLIVE" 2>/dev/null
r=$(mutex_probe "$MLIVE" 0 bg)
[ "$r" = ACQUIRED ] && pass "DEAD owner + fresh ts -> reclaimed (liveness decides, not age)" \
	|| fail "dead fresh owner -> $r (want ACQUIRED)"
r=$(mutex_probe "not-a-pid" 9999 bg)
[ "$r" = ACQUIRED ] && pass "unparseable owner + stale ts -> reclaimed (age tiebreak)" \
	|| fail "unparseable stale owner -> $r (want ACQUIRED)"
r=$(mutex_probe "not-a-pid" 0 bg)
[ "$r" = BUSY ] && pass "unparseable owner + fresh ts -> BUSY (age tiebreak protects)" \
	|| fail "unparseable fresh owner -> $r (want BUSY)"
(
	set +u
	export PLATFORM=miyoomini SDCARD_PATH="$SANDBOX/card" WIFI_DBG="$SANDBOX/wifi-mutex.log"
	. "$LIB" >/dev/null 2>&1
	_WIFI_LOCK="$MLOCK"
	rm -rf "$MLOCK"; command mkdir -p "$MLOCK"
	printf '%s' "$$" > "$MLOCK/owner"; echo 1000 > "$MLOCK/ts"
	wifi_lock_refresh
	_ts=$(cat "$MLOCK/ts" 2>/dev/null || echo 0)
	[ $(( $(date +%s) - _ts )) -le 5 ]
) && pass "wifi_lock_refresh bumps the held lock's ts (owner-scoped)" \
	|| fail "wifi_lock_refresh did not bump the held lock's ts"
rm -rf "$MLOCK"

say ""
if [ "$FAILS" -eq 0 ]; then
	say "wifi-check: all green"
	exit 0
fi
say "wifi-check: $FAILS FAILURE(S)"
exit 1
