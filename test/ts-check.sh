#!/bin/bash
# ts-check.sh — off-device gate for the LodorOS (fork) tier-1 Tailscale shell surface
# (task #134). The NextUI tree has the wizard-sim harness; the fork has no sim, so this
# script is the compensating shell-trace test: it parses every touched script, then
# sources the REAL lib pair in a throwaway sandbox and drives lodor_tier1_up /
# tailscale_reconnect / _romm_reachable against a scripted fake tailscaled.
#
# SANDBOX SAFETY (a dev box may run its own real tailscaled):
#   - killall is PATH-shadowed to a no-op recorder (the lib's tailscale_down calls it)
#   - the lib's host-global pidof fallback is neutralized (function override in the driver)
#   - cleanup pkill is -f "$ROOT/" scoped — only ever this sandbox's fake daemons
#
# Usage: ./ts-check.sh    (exit 0 = all green; prints each check)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LODOROS="$(cd "$HERE/.." && pwd)"
PAKSRC="$LODOROS/paks/Lodor.pak"
TSPAK="$LODOROS/paks/Tailscale.pak"
fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# ---- 1. static: bash -n + POSIX parse of the tier-1 shell surface ----
echo "== static parse =="
POSIX_SH=()
if command -v dash >/dev/null 2>&1; then POSIX_SH=(dash)
elif command -v busybox >/dev/null 2>&1; then POSIX_SH=(busybox ash)
else echo "WARN: no dash/busybox — POSIX parse skipped (bash -n still gates)"
fi
for f in "$PAKSRC/lib/romm-sync-lib.sh" "$PAKSRC/lib/tailscale-lib.sh" \
         "$PAKSRC/bin/romm-run" "$PAKSRC/bin/romm-syncd" "$TSPAK/launch.sh" "$0"; do
	[ -f "$f" ] || { fail "missing $f"; continue; }
	bash -n "$f" 2>/dev/null && ok "bash -n ${f#"$LODOROS"/}" || fail "bash -n $f"
	if [ "${#POSIX_SH[@]}" -gt 0 ]; then
		"${POSIX_SH[@]}" -n "$f" 2>/dev/null && ok "${POSIX_SH[*]} -n ${f#"$LODOROS"/}" || fail "${POSIX_SH[*]} -n $f"
	fi
done

# ---- 2. sandbox ----
ROOT="$(mktemp -d /tmp/lodoros-tscheck.XXXXXX)"
trap 'pkill -f "$ROOT/" 2>/dev/null; rm -rf "$ROOT"' EXIT
SD="$ROOT/sdcard"
PLAT="rg35xxplus"
PAK="$SD/Tools/$PLAT/Lodor.pak"
mkdir -p "$PAK/lib" "$PAK/tailscale" "$SD/.userdata/$PLAT" "$ROOT/bin"
cp "$PAKSRC/lib/romm-sync-lib.sh" "$PAKSRC/lib/tailscale-lib.sh" "$PAK/lib/"

# killall shadow — the ONLY killall these tests may ever see (never the host's).
cat > "$ROOT/bin/killall" <<'EOF'
#!/bin/sh
echo "KILLALL $*" >> "${TSCHECK_TRACE:?}" 2>/dev/null
exit 0
EOF
chmod +x "$ROOT/bin/killall"

# scripted fake tailscaled: creates the (plain-file) socket after 0.2s, then idles.
cat > "$PAK/tailscale/tailscaled" <<'EOF'
#!/bin/sh
sock=""
for a in "$@"; do case "$a" in --socket=*) sock="${a#--socket=}" ;; esac; done
echo start >> "${TSCHECK_STARTS:?}"
/bin/sleep 0.2
: > "$sock"
while :; do /bin/sleep 1; done
EOF
# fake CLI: everything fails until the socket exists; then status=Running, ip=100.100.1.9.
cat > "$PAK/tailscale/tailscale" <<'EOF'
#!/bin/sh
sock=""
for a in "$@"; do case "$a" in --socket=*) sock="${a#--socket=}" ;; esac; done
[ -e "$sock" ] || exit 1
case "$*" in
	*status*--json*) printf '{"BackendState":"Running"}\n' ;;
	*" ip"*)         echo 100.100.1.9 ;;
esac
exit 0
EOF
chmod +x "$PAK/tailscale/tailscaled" "$PAK/tailscale/tailscale"

# per-case driver: sources the REAL lib pair, overrides ONLY the sandbox seams, runs one op.
cat > "$ROOT/drv.sh" <<'EOF'
#!/bin/sh
PAK="$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak"
. "$PAK/lib/romm-sync-lib.sh"
_ts_sock_present() { [ -e "$TS_SOCK" ]; }   # shell can't mint unix sockets
pidof() { return 1; }                        # never find the HOST's tailscaled
case "$1" in
	tier1up)   lodor_tier1_up; echo "RC=$?" ;;
	tier1up2)  lodor_tier1_up >/dev/null 2>&1; lodor_tier1_up; echo "RC=$?" ;;
	reconnect) tok="$(tailscale_reconnect)"; echo "RC=$? TOK=$tok" ;;
	up_reconnect)
		tailscale_up >/dev/null 2>&1
		tok="$(tailscale_reconnect)"; echo "RC=$? TOK=$tok" ;;
	reach)
		if _romm_reachable; then echo "RC=0 DETAIL=$_REACH_DETAIL"
		else echo "RC=1 DETAIL=$_REACH_DETAIL"; fi ;;
	reach_t1up)
		tailscale_up >/dev/null 2>&1
		if _romm_reachable; then echo "RC=0 DETAIL=$_REACH_DETAIL"
		else echo "RC=1 DETAIL=$_REACH_DETAIL"; fi ;;
	*) echo "RC=99 unknown case"; exit 2 ;;
esac
EOF

TSLOG="$SD/.userdata/$PLAT/tailscale/tailscaled.log"
WDBG="$PAK/wifi-debug.log"
run_case() {  # run_case <name> -> stdout of the driver; sandboxed env
	env -i PATH="$ROOT/bin:/usr/bin:/bin" HOME="$ROOT" \
		SDCARD_PATH="$SD" PLATFORM="$PLAT" \
		TS_SOCK="$ROOT/ts.sock" TS_STATEDIR="$ROOT/ts-state" \
		TSCHECK_TRACE="$ROOT/trace.log" TSCHECK_STARTS="$ROOT/daemon-starts" \
		timeout -k 5 60 sh "$ROOT/drv.sh" "$1" 2>>"$ROOT/drv-stderr.log"
}
live_daemons() { pgrep -f "$PAK/tailscale/tailscaled" 2>/dev/null | wc -l; }   # wc: clean 0, never "0\n0"
reset_sandbox() {
	pkill -f "$ROOT/" 2>/dev/null; /bin/sleep 0.3
	rm -rf "$ROOT/ts-state" "$ROOT/ts.sock" "$ROOT/daemon-starts" "$ROOT/trace.log" \
	       "$SD/.userdata/$PLAT/tailscale" "$WDBG" "$PAK/config.json" 2>/dev/null
	mkdir -p "$SD/.userdata/$PLAT"
}
seed_state()  { mkdir -p "$SD/.userdata/$PLAT/tailscale"; printf 'STATEBYTES\n' > "$SD/.userdata/$PLAT/tailscale/tailscaled.state"; }
seed_lan()    { printf '{\n  "hosts": [\n    {\n      "root_uri": "https://romm.example.com",\n      "token": "stub-token"\n    }\n  ]\n}\n' > "$PAK/config.json"; }
seed_tier1()  { printf '{\n  "hosts": [\n    {\n      "root_uri": "http://romm.example-tailnet.ts.net",\n      "socks5_proxy": "localhost:1055",\n      "tier": 1,\n      "token": "stub-token"\n    }\n  ]\n}\n' > "$PAK/config.json"; }

echo "== dynamic: tier-1 preamble (lodor_tier1_up) =="
reset_sandbox; seed_lan
out="$(run_case tier1up)"
[ "$out" = "RC=0" ] && ok "LAN config: tier1up rc=0" || fail "LAN config: got '$out'"
[ "$(live_daemons)" = 0 ] && ok "LAN config: no daemon spawned" || fail "LAN config: daemon spawned ($(live_daemons))"

reset_sandbox; seed_tier1; seed_state
out="$(run_case tier1up)"
[ "$out" = "RC=0" ] && ok "tier-1: tier1up rc=0" || fail "tier-1: got '$out'"
[ "$(live_daemons)" = 1 ] && ok "tier-1: exactly one daemon" || fail "tier-1: daemons=$(live_daemons)"
grep -qF "tier-1 up: reusing persisted login" "$TSLOG" 2>/dev/null && ok "tier-1: persisted login reused (no re-auth)" || fail "tier-1: ts log lacks persisted-login line"
grep -qF "tier1: tunnel up" "$WDBG" 2>/dev/null && ok "tier-1: honest 'tunnel up' in wifi-debug" || fail "tier-1: wifi-debug lacks tier1 verdict"

reset_sandbox; seed_tier1; seed_state
out="$(run_case tier1up2)"
[ "$out" = "RC=0" ] && ok "tier-1 idempotent: second call rc=0" || fail "tier-1 idempotent: got '$out'"
[ "$(live_daemons)" = 1 ] && ok "tier-1 idempotent: still one daemon (reused)" || fail "tier-1 idempotent: daemons=$(live_daemons)"
grep -qF "tailscaled already up; reusing" "$TSLOG" 2>/dev/null && ok "tier-1 idempotent: reuse logged" || fail "tier-1 idempotent: no reuse line"

echo "== dynamic: tailscale_reconnect =="
reset_sandbox; seed_tier1
out="$(run_case reconnect)"
[ "$out" = "RC=1 TOK=no-login" ] && ok "reconnect, no saved login: honest no-login" || fail "reconnect no-login: got '$out'"
[ "$(live_daemons)" = 0 ] && ok "reconnect, no saved login: nothing spawned" || fail "reconnect no-login: daemons=$(live_daemons)"

reset_sandbox; seed_tier1; seed_state
out="$(run_case reconnect)"
[ "$out" = "RC=0 TOK=connected:100.100.1.9" ] && ok "reconnect from persisted login: connected:<ip>" || fail "reconnect happy: got '$out'"
[ "$(live_daemons)" = 1 ] && ok "reconnect happy: one daemon" || fail "reconnect happy: daemons=$(live_daemons)"

reset_sandbox; seed_tier1; seed_state
out="$(run_case up_reconnect)"
[ "$out" = "RC=0 TOK=connected:100.100.1.9" ] && ok "reconnect over a LIVE daemon: restarted, connected" || fail "reconnect restart: got '$out'"
[ "$(live_daemons)" = 1 ] && ok "reconnect restart: exactly one daemon (no pile-up)" || fail "reconnect restart: daemons=$(live_daemons)"
grep -qF -- "--- ts reconnect ---" "$TSLOG" 2>/dev/null && ok "reconnect restart: ts log has the reconnect section" || fail "reconnect restart: no reconnect section in ts log"

echo "== dynamic: _romm_reachable honesty =="
reset_sandbox   # no config.json at all -> host unparsed
out="$(run_case reach)"
case "$out" in
	"RC=0 DETAIL=probe skipped: host unparsed"*) ok "no config: probe says skipped/unparsed, rc 0" ;;
	*) fail "no config reach: got '$out'" ;;
esac
reset_sandbox; seed_tier1   # tier-1, tunnel down
out="$(run_case reach)"
case "$out" in
	"RC=1 DETAIL=tier-1 tunnel NOT Running"*) ok "tier-1 down: probe says tunnel NOT Running, rc 1" ;;
	*) fail "tier-1 down reach: got '$out'" ;;
esac
reset_sandbox; seed_tier1; seed_state   # tier-1, tunnel brought up first
out="$(run_case reach_t1up)"
case "$out" in
	"RC=0 DETAIL=tier-1 tunnel Running"*) ok "tier-1 up: probe verifies the engine transport, rc 0" ;;
	*) fail "tier-1 up reach: got '$out'" ;;
esac

echo "== safety: no host process was ever killall'd for real =="
# the recorder proves every killall the lib issued hit the shadow, not the host
if [ -f "$ROOT/trace.log" ]; then ok "killall calls recorded: $(grep -c '^KILLALL' "$ROOT/trace.log" 2>/dev/null || echo 0) (all no-op)"; fi

echo "======================================================================"
if [ "$fails" = 0 ]; then echo "ts-check.sh: ALL GREEN"; exit 0; fi
echo "ts-check.sh: $fails check(s) FAILED"
exit 1
