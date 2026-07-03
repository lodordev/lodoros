# tailscale-lib.sh — tier-1 (Tailscale) bring-up for LodorOS RomM sync (#84).
#
# Sourced AFTER romm-sync-lib.sh (it reuses $SDCARD, $PLAT, $ROMM_PAK_DIR). Provides
# tailscale_up / tailscale_down: start a USERSPACE tailscaled that exposes a local
# SOCKS5 proxy, join the tailnet with a tagged reusable authkey, and tear it back
# down. The engine then reaches the tier-1 RomM host by socks5h-dialing that proxy
# (config: hosts[].socks5_proxy on the tier-1 entry); if tailscaled never comes up
# the engine's tier probe fails and it falls back to the tier-2 Cloudflare path —
# so tailscale_up is ALWAYS non-fatal to the caller.
#
# DESIGN: userspace-networking means NO /dev/net/tun, NO iptables, NO resolvconf,
# NO root caps beyond running the binary — it is just a process with a socket. RAM
# is capped with GOGC=10 + GOMEMLIMIT so a 1 GB handheld is not starved. The radio
# is owned by wifi_acquire/wifi_release in romm-sync-lib.sh; this only adds an
# overlay on TOP of an already-up Wi-Fi link, and only for the duration of a sync.
#
# CAPABILITY GATE (hard): miyoomini (128 MB) is NEVER eligible; my282 (512 MB) is
# NEVER eligible either (A33 firmware + 512 MB too marginal); my355 / tg5040
# / rg35xxplus (1 GB) are enabled. A /proc/meminfo floor is a second guard.
#
# SECURITY: the authkey is read from a file-drop and passed to `tailscale up` via
# the `file:` scheme so it is NEVER placed in argv, a shell var, a log, or this
# repo. Same plaintext-on-FAT posture as the RomM token. Absent file => tier-1
# simply does not come up.

# --- paths / tunables --------------------------------------------------------
# Tailscale binaries are byte-identical per arch, so the release ships ONE copy per
# arch in a shared dir (.system/.tailscale/<arch>) instead of one per platform pak
# (~126 MB saved at 0.9). Prefer the shared dir; fall back to the legacy per-pak dir
# so an older-style card still boots. TS_BIN_DIR env override wins over both.
_ts_arch() { case "$(uname -m 2>/dev/null)" in aarch64|arm64) echo arm64 ;; *) echo armhf ;; esac; }
_TS_SHARED_DIR="$SDCARD/.system/.tailscale/$(_ts_arch)"
if [ -z "${TS_BIN_DIR:-}" ] && [ -x "$_TS_SHARED_DIR/tailscaled" ]; then TS_BIN_DIR="$_TS_SHARED_DIR"; fi
TS_BIN_DIR="${TS_BIN_DIR:-$ROMM_PAK_DIR/tailscale}"     # legacy per-pak fallback
TS_STATEDIR="${TS_STATEDIR:-/tmp/lodor-ts-state}"
# Portable detached-background launcher: some firmwares (e.g. Miyoo A30/my282) ship NO
# nohup. Fall back to setsid, then to a bare background (a non-interactive script does not
# SIGHUP its children on exit, and stdio is redirected below), so tailscaled still detaches.
if command -v nohup >/dev/null 2>&1; then TS_BG=nohup
elif command -v setsid >/dev/null 2>&1; then TS_BG=setsid
else TS_BG=; fi
            # tmpfs: FAT32 mangles tailscaled live state writes -> machine key degenerate -> control 502
TS_STATE_PERSIST="${TS_STATE_PERSIST:-$SDCARD/.userdata/$PLAT/tailscale/tailscaled.state}"  # whole-file backup on card (one cp is FAT32-safe; live writes are not)
TS_SOCK="${TS_SOCK:-/tmp/lodor-tailscaled.sock}"  # tmpfs: FAT32 cannot bind a unix socket
# Cold-start socket budget (2026-07-02 field boot, NextUI lib lineage): 5s was NOT enough for a
# cold start — the old code then KILLED the still-starting daemon and every retry repeated the
# kill ("tailscaled socket never appeared" x4, daemon never got to speak). 30s default.
TS_SOCK_WAIT_SECS="${TS_SOCK_WAIT_SECS:-30}"
TS_SOCKS5_ADDR="${TS_SOCKS5_ADDR:-localhost:1055}"      # MUST match hosts[].socks5_proxy in config.json
TS_MEMLIMIT="${TS_MEMLIMIT:-256MiB}"
TS_AUTHKEY_FILE="${TS_AUTHKEY_FILE:-$ROMM_PAK_DIR/tailscale.authkey}"
TS_TAGS="${TS_TAGS:-tag:lodor}"
TS_LOG="${TS_LOG:-$SDCARD/.userdata/$PLAT/tailscale/tailscaled.log}"
mkdir -p "$(dirname "$TS_LOG")" 2>/dev/null  # FRESH CARD: this dir must exist before any '>> $TS_LOG' redirect, else tailscaled (started with >> $TS_LOG) never runs and sign-in errors
TS_DAEMON_PID=""

# Persist tailscaled state across reboots without live-writing FAT32: daemon writes
# tmpfs (TS_STATEDIR); restore a whole-file copy from the card before start, back it
# up after. One cp of a complete state file is FAT32-safe; the daemon's partial
# writes are not (they corrupt the machine key -> control 502).
_ts_state_restore() {
	mkdir -p "$TS_STATEDIR" 2>/dev/null
	[ -f "$TS_STATE_PERSIST" ] && [ ! -s "$TS_STATEDIR/tailscaled.state" ] && cp "$TS_STATE_PERSIST" "$TS_STATEDIR/tailscaled.state" 2>/dev/null
	return 0
}
_ts_state_save() {
	# Persist the tailscaled state (machine/node keys = the login) to the card so it
	# survives a reboot -- the difference between "sign in once, auto-reconnect forever"
	# and "re-onboard after every reboot". Writes ONLY when the state changed (cheap to
	# call on every Running check) and does a FAT32-safe whole-file temp+rename+sync.
	[ -s "$TS_STATEDIR/tailscaled.state" ] || return 0
	cmp -s "$TS_STATEDIR/tailscaled.state" "$TS_STATE_PERSIST" 2>/dev/null && return 0
	mkdir -p "$(dirname "$TS_STATE_PERSIST")" 2>/dev/null
	_tsp="$TS_STATE_PERSIST.tmp.$$"
	cp "$TS_STATEDIR/tailscaled.state" "$_tsp" 2>/dev/null && mv -f "$_tsp" "$TS_STATE_PERSIST" 2>/dev/null && sync 2>/dev/null
	return 0
}

ts_log() { printf '%s %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$1" >> "$TS_LOG" 2>/dev/null; }

# _ts_sock_present — THE probe for the daemon's control socket. A one-line seam on purpose:
# the off-device sim (nextui test tree; same lib lineage) overrides it with a plain-file
# check (shell cannot mint unix sockets), so the REAL wait/reuse logic is what gets tested.
_ts_sock_present() { [ -S "$TS_SOCK" ]; }

# _ts_running_pid — PID of an already-running tailscaled (ours from this session, else any
# on the box via pidof), empty when none. Lets a retry REUSE a daemon that is still starting
# instead of spawning a duplicate — the "address already in use" pile-up on the 2026-07-02
# field boots came from every retry launching another daemon at the same SOCKS5 port.
_ts_running_pid() {
	if [ -n "${TS_DAEMON_PID:-}" ] && kill -0 "$TS_DAEMON_PID" 2>/dev/null; then
		printf '%s' "$TS_DAEMON_PID"
		return 0
	fi
	command -v pidof >/dev/null 2>&1 && pidof tailscaled 2>/dev/null | awk '{print $1}'
	return 0
}

# _ts_spawn_daemon — start userspace tailscaled in the background (all output -> $TS_LOG so
# a dying daemon's own words are captured), recording TS_DAEMON_PID. ONE spawn site, shared
# by tailscale_up and tailscale_up_interactive.
_ts_spawn_daemon() {
	$TS_BG env GOGC=10 GOMAXPROCS=1 GOMEMLIMIT="$TS_MEMLIMIT" "$TS_BIN_DIR/tailscaled" \
		--tun=userspace-networking \
		--socks5-server="$TS_SOCKS5_ADDR" \
		--statedir="$TS_STATEDIR" \
		--socket="$TS_SOCK" </dev/null >> "$TS_LOG" 2>&1 &
	TS_DAEMON_PID=$!
}

# _ts_wait_socket <pid> — wait up to TS_SOCK_WAIT_SECS for the control socket, WATCHING the
# daemon process so "starting slowly" and "already dead" are DIFFERENT outcomes:
#   0 = socket up
#   1 = daemon EXITED first — rc captured here; its stdout/stderr already landed in $TS_LOG
#       via the spawn redirect, so the log finally shows WHY a cold start fails
#   2 = timeout with the daemon STILL ALIVE — callers must NOT kill it (killing a slow
#       starter was the field bug); the next attempt reuses it via _ts_running_pid
_ts_wait_socket() {
	_wpid="$1"
	_wmax=$((TS_SOCK_WAIT_SECS * 5))   # 0.2s steps
	_wi=0
	while [ "$_wi" -lt "$_wmax" ]; do
		_ts_sock_present && return 0
		if [ -n "$_wpid" ] && ! kill -0 "$_wpid" 2>/dev/null; then
			wait "$_wpid" 2>/dev/null; _wrc=$?
			[ "$_wrc" = 127 ] && _wrc="?"   # not our child — exit status unknowable
			ts_log "tailscaled EXITED (rc=$_wrc) before its socket appeared — its own output above is the why"
			return 1
		fi
		_wi=$((_wi + 1))
		[ $((_wi % 25)) = 0 ] && ts_log "still waiting for tailscaled socket ($((_wi / 5))s, pid ${_wpid:-?} alive)"
		sleep 0.2
	done
	_ts_sock_present && return 0
	ts_log "tailscaled socket not up after ${TS_SOCK_WAIT_SECS}s — daemon still starting; left running for the next attempt (NOT killed)"
	return 2
}


# _ts_meminfo_kb — total RAM in kB from /proc/meminfo (0 if unreadable).
_ts_meminfo_kb() {
	awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0
}

# _ts_avail_kb -- AVAILABLE RAM in kB from /proc/meminfo (0 if unreadable). The real
# guard on a swapless device: total RAM misses the GPU/CMA carve-out, free RAM does not.
_ts_avail_kb() {
	awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0
}

# _ts_capable — platform + RAM gate. Returns 0 (eligible) / 1 (skip). miyoomini is
# a hard NO; my282 (A30, 512 MB) is also a hard NO; the 1 GB devices are yes. A RAM floor
# (~700 MB) is the secondary guard so a mis-tagged platform can never start a daemon
# on a device too small for it.
_ts_capable() {
	case "$PLAT" in
		miyoomini) return 1 ;;                                  # 128 MB — never
		my282) return 1 ;;  # A30 512 MB — never (gated OFF 2026-07-01: A33 firmware + RAM too marginal; use tier-2)
		my355|tg5040|rg35xxplus) : ;;                           # 1 GB — eligible
		*) [ "${LODOR_TS_FORCE:-0}" = "1" ] || return 1 ;;      # unknown — opt-in only
	esac
	mem=$(_ts_meminfo_kb)
	# Hard floor: < 256 MB total is genuine OOM territory (research: every wild OOM
	# report clusters <=256 MB). Never, even with FORCE.
	[ "${mem:-0}" -gt 0 ] && [ "$mem" -lt 256000 ] && return 1
	# Free-RAM preflight (swapless = no cushion): refuse if MemAvailable < ~120 MB right
	# now -- robust to whatever the GPU/CMA carve-out leaves free. FORCE overrides.
	avail=$(_ts_avail_kb)
	if [ "${avail:-0}" -gt 0 ] && [ "$avail" -lt 122880 ] && [ "${LODOR_TS_FORCE:-0}" != "1" ]; then
		ts_log "tailscale: MemAvailable ${avail}kB < 120MB -> skip, tier-2"
		return 1
	fi
	return 0
}

# _ts_hostname — DNS label for this node: device_name from config.json, sanitized
# (lowercased, non-alnum -> '-'), else lodor-<platform>.
_ts_hostname() {
	dn=$(sed -n 's/.*"device_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROMM_PAK_DIR/config.json" 2>/dev/null | head -1)
	[ -n "$dn" ] || dn="lodor-$PLAT"
	printf '%s' "$dn" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//'
}

# tailscale_up — start userspace tailscaled + join the tailnet. Idempotent. Returns
# 0 only when the node is up and the SOCKS5 proxy is listening; any skip/failure
# returns non-0 and the caller proceeds on tier-2. NEVER logs the authkey.
tailscale_up() {
	_ts_capable || { return 1; }
	[ -x "$TS_BIN_DIR/tailscaled" ] || { return 1; }   # binary not bundled for this arch/build
	[ -x "$TS_BIN_DIR/tailscale" ]  || { return 1; }
	# NB: no up-front authkey requirement. A QR-onboarded node has persisted login
	# state and no key file; it is reused below. The authkey is only the headless
	# first-auth path, checked just before `up`.

	_ts_state_restore
	printf '\n--- ts run ---\n' >> "$TS_LOG" 2>/dev/null

	# Already running from a prior sync this boot? Reuse it.
	if _ts_sock_present && "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status >/dev/null 2>&1; then
		ts_log "tailscaled already up; reusing"
		return 0
	fi

	# A daemon may still be STARTING from an earlier attempt this boot (cold start):
	# wait on IT — never spawn a duplicate at the same SOCKS5 port / socket path.
	_tsrp="$(_ts_running_pid)"
	if [ -n "$_tsrp" ]; then
		ts_log "tailscaled already running (pid $_tsrp) but its socket is not answering yet — waiting on it instead of spawning a duplicate"
	else
		ts_log "starting userspace tailscaled (GOGC=10 GOMAXPROCS=1 GOMEMLIMIT=$TS_MEMLIMIT socks5=$TS_SOCKS5_ADDR)"
		_ts_spawn_daemon
		_tsrp="$TS_DAEMON_PID"
	fi
	# Died -> honest failure (rc + daemon output in the ts log). Still starting at the
	# deadline -> honest failure too, but the daemon is LEFT UP for the next attempt.
	_ts_wait_socket "$_tsrp" || return 1

	# Reuse a persisted login (e.g. from QR onboarding) — no authkey needed.
	# A returning node needs a few seconds after the socket appears to re-auth against the
	# control plane and reach Running, so POLL rather than single-shot: an immediate one-shot
	# check always caught it mid-"Starting", concluded "not authenticated", and (a QR node has
	# no authkey file) tore the daemon down -- THE reason tier-1 "did not survive a reboot".
	# Only wait when there is restored state to come up on; with no state, fall through.
	if [ -s "$TS_STATEDIR/tailscaled.state" ]; then
		i=0
		while [ "$i" -lt 150 ]; do
			if "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
				ts_log "tier-1 up: reusing persisted login (no key)"
				_ts_state_save
				return 0
			fi
			sleep 0.1
			i=$((i + 1))
		done
		ts_log "persisted state present but not Running after 15s -> tier-2 this round (daemon left up)"
		return 1
	fi
	# Not authenticated yet. Headless first-auth needs an authkey drop; the QR path
	# is onboarding-only. No key -> tier-2.
	if [ ! -f "$TS_AUTHKEY_FILE" ]; then
		ts_log "not authenticated and no authkey -> tier-2 (sign in via onboarding QR)"
		tailscale_down
		return 1
	fi

	# Join the tailnet. authkey via file: scheme -> never enters argv/log. --accept-dns
	# off: userspace networking does not touch the system resolver; MagicDNS is
	# resolved INSIDE the SOCKS5 proxy (socks5h) by the engine's dialer.
	if ! "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" up \
		--auth-key="file:$TS_AUTHKEY_FILE" \
		--hostname="$(_ts_hostname)" \
		--advertise-tags="$TS_TAGS" \
		--accept-dns=false \
		--accept-routes=false >> "$TS_LOG" 2>&1; then
		ts_log "tailscale up failed -> tier-2"
		tailscale_down
		return 1
	fi

	ts_log "tier-1 up: node joined, SOCKS5 on $TS_SOCKS5_ADDR"
	_ts_state_save   # persist the freshly-authed state to the card
	return 0
}

# tailscale_down — stop the userspace daemon and remove the socket. Leaves the
# node state in TS_STATEDIR so the reusable authkey re-auths instantly next sync.
# Safe no-op when nothing was started (the miyoomini / skipped path).
tailscale_down() {
	_ts_state_save   # back up the (possibly newly-authed) state to the card
	if _ts_sock_present; then
		"$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" down >/dev/null 2>&1
	fi
	if [ -n "${TS_DAEMON_PID:-}" ]; then
		kill "$TS_DAEMON_PID" >/dev/null 2>&1
		TS_DAEMON_PID=""
	fi
	# Belt: only ever our own statedir's daemon. No other tailscaled exists on a LodorOS card.
	killall tailscaled >/dev/null 2>&1
	rm -f "$TS_SOCK" 2>/dev/null
	return 0
}

# ts_reset — maintenance hard reset (Tailscale.pak): log out of the tailnet, stop the
# daemon, and wipe BOTH the tmpfs state and the persisted on-card copy so the NEXT sign-in
# starts completely fresh. This is the recovery for a wedged/half-authed node -- the flaky
# state a user hits after signing in, sleeping, and re-onboarding.
ts_reset() {
	_ts_sock_present && "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" logout >/dev/null 2>&1
	tailscale_down
	rm -f "$TS_STATEDIR/tailscaled.state" "$TS_STATE_PERSIST" "$TS_STATEDIR/up.log" 2>/dev/null
	ts_log "ts_reset: logged out + state wiped (fresh sign-in next time)"
	return 0
}

# tailscale_reconnect — the "Reconnect" menu action (task #134): restart tailscaled from the
# PERSISTED login and report honestly. NEVER re-auths — it only ever reuses the saved state
# (the QR sign-in that Reset & forget wipes) and never touches the RomM pairing token.
# stdout = ONE machine-readable token the menu translates into UX text:
#   connected[:<tailnet-ip>]  Running again (rc 0)
#   no-login                  no saved sign-in anywhere (tmpfs or card) — QR onboarding is
#                             the only way to mint one; nothing was torn down (rc 1)
#   not-running               daemon restarted but never reached Running — the ts log's
#                             watched-wait lines say why (rc 1)
#   not-capable / no-binary   device/build can't run Tailscale at all (rc 1)
tailscale_reconnect() {
	_ts_capable || { ts_log "reconnect: device not Tailscale-capable"; echo "not-capable"; return 1; }
	if [ ! -x "$TS_BIN_DIR/tailscaled" ] || [ ! -x "$TS_BIN_DIR/tailscale" ]; then
		ts_log "reconnect: tailscale binaries missing ($TS_BIN_DIR)"; echo "no-binary"; return 1
	fi
	printf '\n--- ts reconnect ---\n' >> "$TS_LOG" 2>/dev/null
	# No saved login anywhere -> reconnect CANNOT work; say so BEFORE tearing anything down.
	_ts_state_restore
	if [ ! -s "$TS_STATEDIR/tailscaled.state" ]; then
		ts_log "reconnect: no saved login (state absent) — sign in via the onboarding QR"
		echo "no-login"; return 1
	fi
	# Explicit RESTART: tailscale_up would happily "reuse" a wedged daemon that still answers
	# its socket, so tear the old one down first (tailscale_down SAVES state — the login is
	# never touched) and wait for it to actually die so the fresh spawn can bind the same
	# SOCKS5 port + socket path (the "address already in use" trap).
	_rk="$(_ts_running_pid)"
	tailscale_down >/dev/null 2>&1
	if [ -n "$_rk" ]; then
		_ri=0
		while kill -0 "$_rk" 2>/dev/null && [ "$_ri" -lt 25 ]; do sleep 0.2; _ri=$((_ri + 1)); done
		if kill -0 "$_rk" 2>/dev/null; then
			ts_log "reconnect: old tailscaled (pid $_rk) ignored TERM for 5s — KILL"
			kill -9 "$_rk" 2>/dev/null
			sleep 0.2
		fi
	fi
	# Fresh bring-up from the persisted login. tailscale_up does the watched socket wait then
	# polls to Running — with state present its rc 0 MEANS BackendState=Running.
	if tailscale_up; then
		_rip="$(tailscale_ip 2>/dev/null)"
		ts_log "reconnect: Running again${_rip:+ ($_rip)}"
		echo "connected${_rip:+:$_rip}"
		return 0
	fi
	ts_log "reconnect: restart did not reach Running — the watched-wait lines above say why"
	echo "not-running"
	return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# §QR onboarding (#QR): INTERACTIVE login (no auth key). The native launcher drives
# these three; they never block the caller for more than the URL-scrape window.
# ─────────────────────────────────────────────────────────────────────────────

# tailscale_up_interactive — start userspace tailscaled (if needed), then run an
# INTERACTIVE `tailscale up` (NO --auth-key) in the BACKGROUND so it prints the login
# URL and then keeps waiting for the user to authenticate in their browser. We scrape
# the https://login.tailscale.com/... URL out of its output and echo ONLY that URL on
# stdout (empty on any skip/failure). The caller renders it as a QR and polls
# tailscale_status until the node is Connected (which is when the backgrounded `up`
# returns on its own). NEVER blocks longer than the ~15s URL-scrape window.
tailscale_up_interactive() {
	_ts_capable || { echo ""; return 1; }
	[ -x "$TS_BIN_DIR/tailscaled" ] || { echo ""; return 1; }
	[ -x "$TS_BIN_DIR/tailscale" ]  || { echo ""; return 1; }

	_ts_state_restore
	printf '\n--- ts run ---\n' >> "$TS_LOG" 2>/dev/null

	# Start the daemon unless a usable one is already up from this boot.
	if ! { _ts_sock_present && "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status >/dev/null 2>&1; }; then
		_tsrp="$(_ts_running_pid)"
		if [ -n "$_tsrp" ]; then
			ts_log "interactive: tailscaled already running (pid $_tsrp) — waiting on its socket (no duplicate spawn)"
		else
			ts_log "starting userspace tailscaled (interactive login; socks5=$TS_SOCKS5_ADDR)"
			_ts_spawn_daemon
			_tsrp="$TS_DAEMON_PID"
		fi
		# Same contract as tailscale_up: a dead daemon is an honest failure (rc + its own
		# output in the ts log); a slow starter is NEVER killed — left up for the retry.
		if ! _ts_wait_socket "$_tsrp"; then echo ""; return 1; fi
	fi

	# If state already has us logged in (a prior sign-in survived), no URL is needed —
	# report empty URL but success so the caller jumps straight to the status poll.
	if "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null \
		| grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
		ts_log "interactive: already Running (state reused) — no login URL needed"
		echo ""
		return 0
	fi

	# Run interactive `up` in the background; it prints the auth URL then blocks until
	# the user authenticates. --accept-dns=false: MagicDNS is resolved inside the SOCKS5
	# proxy by the engine's dialer, not the system resolver.
	# NB: `true >` not `: >` — ':' is a POSIX SPECIAL builtin, so a failed redirect on it
	# aborts the whole (sourced) shell silently; 'true' is a regular builtin and just fails.
	UP_LOG="$TS_STATEDIR/up.log"; true > "$UP_LOG" 2>/dev/null
	"$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" up \
		--hostname="$(_ts_hostname)" \
		--accept-dns=false \
		--accept-routes=false >> "$UP_LOG" 2>&1 &
	echo $! > "$TS_STATEDIR/up.pid" 2>/dev/null

	# Capture the login URL (<=15s).
	i=0; url=""; _prev=""
	while [ "$i" -lt 150 ]; do
		# PRIMARY: the daemon's status JSON AuthURL — atomic and complete by construction.
		# (Scraping up.log races `tailscale up`'s buffered writes: NextUI boot 3 captured a
		# 31-char half-flushed URL. The JSON field can never be partially written.)
		url=$("$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null \
			| grep -oE '"AuthURL"[[:space:]]*:[[:space:]]*"https://login\.tailscale\.com/[A-Za-z0-9./_-]+"' \
			| grep -oE 'https://login\.tailscale\.com/[A-Za-z0-9./_-]+' | head -1)
		[ -n "$url" ] && break
		# FALLBACK: up.log, but only accept a value that is stable across two consecutive
		# polls (a half-flushed line differs from its completed self 100ms later).
		_u2=$(grep -oE 'https://login\.tailscale\.com/[A-Za-z0-9./_-]+' "$UP_LOG" 2>/dev/null | head -1)
		if [ -n "$_u2" ] && [ "$_u2" = "$_prev" ]; then url="$_u2"; break; fi
		_prev="$_u2"
		# Auth might have completed instantly (state reused mid-race) — stop waiting.
		"$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null \
			| grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"' && break
		sleep 0.1; i=$((i + 1))
	done
	[ -n "$url" ] && ts_log "interactive: login URL captured (len=${#url})"
	echo "$url"
	return 0
}

# tailscale_status — report the backend state as one stable token for the launcher's
# poll loop: "connected" (BackendState=Running, i.e. authenticated + up), "pending"
# (NeedsLogin/Starting/NoState — still waiting on the user), or "stopped" (no daemon).
# Reads the JSON BackendState field — the canonical machine-readable signal, robust to
# the human `status` layout. Never logs or echoes anything but the one token.
tailscale_status() {
	_ts_sock_present || { echo "stopped"; return 0; }
	st=$("$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null \
		| grep -oE '"BackendState"[[:space:]]*:[[:space:]]*"[A-Za-z]+"' | head -1 \
		| grep -oE '"[A-Za-z]+"' | tail -1 | tr -d '"')
	case "$st" in
		Running)                      _ts_state_save; echo "connected" ;;
		NeedsLogin|Starting|NoState)  echo "pending" ;;
		Stopped|"")                   echo "pending" ;;
		*)                            echo "pending" ;;
	esac
}

# tailscale_ip — the node's tailnet IPv4 (status/Reconnect surfaces). Empty if not up.
# (Parity with the NextUI lib copy — the lineages are siblings.)
tailscale_ip() {
	_ts_sock_present || { echo ""; return 0; }
	"$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" ip -4 2>/dev/null | head -1
}

# tailscale_is_tier1 — 0 if config.json already carries a socks5_proxy (tier-1 configured).
# LodorOS config lives IN the pak dir (unlike NextUI's shared config home).
tailscale_is_tier1() { [ -f "$ROMM_PAK_DIR/config.json" ] && grep -q '"socks5_proxy"' "$ROMM_PAK_DIR/config.json" 2>/dev/null; }

# tailscale_mark_tier1 — promote hosts[0] in config.json to a TIER-1 (SOCKS5) host by
# adding "socks5_proxy":"<addr>" and "tier":1 next to the existing "root_uri". The
# engine's config writer round-trips config.json through a generic map and PRESERVES
# unknown keys, so these survive the later --pair / --register-device / sync writes
# (verified against lodor/config/writer.go WriteHostUpdate). Idempotent + JSON-safe:
# it only ever runs once (skips if socks5_proxy already present), keys off the engine's
# 2-space-indented output, and refuses to overwrite the file unless the insert succeeded.
# NOTE: the SOCKS5 *dialer* that consumes these keys is engine work (a separate track);
# this only persists the correctly-shaped host so the route is ready when that lands.
tailscale_mark_tier1() {
	cfg="$ROMM_PAK_DIR/config.json"
	[ -f "$cfg" ] || { ts_log "mark-tier1: no config.json"; return 1; }
	if grep -q '"socks5_proxy"' "$cfg" 2>/dev/null; then
		ts_log "mark-tier1: already tier-1 (idempotent skip)"
		return 0
	fi
	tmp="$cfg.ts-tmp.$$"
	awk -v proxy="$TS_SOCKS5_ADDR" '
		BEGIN { done = 0 }
		{
			if (!done && $0 ~ /"root_uri"[[:space:]]*:/) {
				line = $0
				sub(/\r$/, "", line)
				match(line, /^[ \t]*/); ind = substr(line, 1, RLENGTH)
				had_comma = (line ~ /,[ \t]*$/)
				if (!had_comma) sub(/[ \t]*$/, ",", line)   # root_uri now has siblings -> needs a comma
				print line
				print ind "\"socks5_proxy\": \"" proxy "\","
				if (had_comma) print ind "\"tier\": 1,"
				else           print ind "\"tier\": 1"
				done = 1
				next
			}
			print
		}
	' "$cfg" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	# Guard: only replace if the insert actually happened and the file is non-empty.
	if grep -q '"socks5_proxy"' "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
		# FAT32-safe: apply the http->https fixup on the TEMP file, then ATOMICALLY rename
		# it over config.json. Never truncate-in-place (cat > "$cfg") — a power-yank between
		# truncate and write zeroes the live config (the all-null corruption seen 2026-06-30).
		sed -i 's#"root_uri": "http://#"root_uri": "https://#' "$tmp" 2>/dev/null
		if mv -f "$tmp" "$cfg"; then sync 2>/dev/null; ts_log "mark-tier1: tier-1 ($TS_SOCKS5_ADDR) + https"; return 0; fi
	fi
	rm -f "$tmp"
	ts_log "mark-tier1: insert failed (root_uri not found?) — config left untouched"
	return 1
}
