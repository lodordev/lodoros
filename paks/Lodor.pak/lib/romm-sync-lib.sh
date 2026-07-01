# romm-sync-lib.sh — shared orchestration for the Mini Flip RomM sync layer.
#
# Sourced by: the manual "Lodor.pak" launch.sh, the romm-syncd daemon, and the minarch shim.
# This is the ONLY place the WiFi-up -> sync -> WiFi-down pipeline lives. Do not copy-paste it.
#
# Provides: wifi_acquire / wifi_release (refcounted radio lock), wait_net, set_clock, run_sync,
# say / clear_say (say.elf feedback), is_charging, creds_present.
#
# Conventions: every function returns 0/non-0 and never calls `exit` (callers decide). Designed to be
# sourced under `set -u`-free shells; do not rely on `set -e` in callers.

# --- paths (work under MinUI env or standalone) ------------------------------
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-miyoomini}"
# Wi-Fi interface name. VERIFIED wlan0 on EVERY wifi-capable LodorOS platform — confirmed from each
# stock Wifi.pak bin/service-on AND launch.sh write_config (miyoomini, my282, my355, rg35xxplus, and
# tg5040). No current platform uses anything else, so the wlan0 literals throughout this file are
# correct as-is and left untouched (preserving the proven miyoomini path); this var is the override
# hook for a future non-wlan0 device and is used by the new per-platform DHCP takeover below.
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
SYSTEM_BIN="$SDCARD/.system/$PLAT/bin"
WIFI_BIN="$SDCARD/Tools/$PLAT/Wifi.pak/bin"
ROMM_PAK_DIR="$SDCARD/Tools/$PLAT/Lodor.pak"
export LODOR_PAK_DIR="$ROMM_PAK_DIR"
SYNC_BIN="$ROMM_PAK_DIR/lodor-sync"
# --- TLS trust store (clean static engine has NO built-in CA bundle) ----------
# The Lodor engine is statically linked with no embedded root CAs, so HTTPS to RomM
# fails unless it is pointed at a trust store. Ship a standard public Mozilla CA bundle
# inside the pak and point the engine at it via SSL_CERT_FILE (Go honors this env).
# Exported ONCE here so every entrypoint that sources this lib (launch.sh, romm-syncd,
# romm-session-sync -> run_sync) inherits it. Graceful fallback to the device system
# store if the bundled certs dir was stripped, so it still works either way.
if [ -f "$ROMM_PAK_DIR/certs/ca-certificates.crt" ]; then
	export SSL_CERT_FILE="$ROMM_PAK_DIR/certs/ca-certificates.crt"
elif [ -f /etc/ssl/certs/ca-certificates.crt ]; then
	export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
fi
# Derive the RomM host[:port] from the user's config (hosts[].root_uri) so the reachability/clock probes
# match whatever RomM the binary actually talks to (a hardcoded host broke distribution).
# Robust: any parse failure falls back to the hardcoded default below, so the device is unaffected.
_parse_romm_uri() {
	[ -f "$ROMM_PAK_DIR/config.json" ] || return 1
	_u=$(sed -n 's/.*"root_uri"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROMM_PAK_DIR/config.json" | head -1)
	[ -n "$_u" ] || return 1
	case "$_u" in https://*) _sch=https; _u=${_u#https://} ;; http://*) _sch=http; _u=${_u#http://} ;; *) _sch=https ;; esac
	_u=${_u%%/*}
	case "$_u" in
		*:*) _RH=${_u%%:*}; _RP=${_u##*:} ;;
		*)   _RH=$_u; if [ "$_sch" = http ]; then _RP=80; else _RP=443; fi ;;
	esac
	[ -n "$_RH" ] || return 1
	ROMM_HOST="${ROMM_HOST:-$_RH}"; ROMM_PORT="${ROMM_PORT:-$_RP}"
}
_parse_romm_uri 2>/dev/null
# ROMM_HOST is set by _parse_romm_uri from config.json (hosts[].root_uri); no host literal is
# baked into this script. If the parse failed, ROMM_HOST stays unset and the advisory route-settle
# probe is skipped — the engine still derives the real host from config.json on its own.
ROMM_PORT="${ROMM_PORT:-443}"
DATETIME_PATH="${DATETIME_PATH:-$SDCARD/.userdata/shared/datetime.txt}"
NET_TIMEOUT="${NET_TIMEOUT:-30}"
WIFI_LOG="${WIFI_LOG:-/dev/null}"

# --- on-screen feedback (DISABLED by default on miyoomini) -------------------
# say.elf renders text, but once it's killed (to swap messages, or before returning) it leaves the
# framebuffer BLACK and MinUI cannot redraw its menu over it — the device looks hung even though the
# sync finished. The stock Wifi.pak no-ops on-screen text on miyoomini for the same reason. So say()
# is log-only by default; set ROMM_SAY=1 to experiment with say.elf on devices where it behaves.
SAY_BIN="$SYSTEM_BIN/say.elf"
SAY_PID=""
say() {
	if [ "${ROMM_SAY:-0}" = "1" ] && [ -x "$SAY_BIN" ]; then
		killall say.elf >/dev/null 2>&1
		"$SAY_BIN" "$1" & SAY_PID=$!
	fi
	return 0
}
clear_say() {
	if [ "${ROMM_SAY:-0}" = "1" ]; then
		[ -n "$SAY_PID" ] && kill "$SAY_PID" >/dev/null 2>&1
		killall say.elf >/dev/null 2>&1
		SAY_PID=""
	fi
	return 0
}

# --- network readiness -------------------------------------------------------
# PORT GROUT'S PROVEN SEQUENCE (reference: grout-era Lodor.pak/lib/romm-sync-lib.sh; reliable on
# THIS exact device — confirmed 2026-06-23, SigmaStar vendor doc + Onion scripts corroborate).
# The stock miyoomini Wifi.pak service-on fires `udhcpc &` BACKGROUNDED after a blind `sleep 2`, BEFORE
# the 8188fu has associated (a cold scan + 4-way handshake routinely takes far longer than 2s) — so the
# first DHCPDISCOVER goes out on a dead link and no lease lands in time. VERIFIED root cause of "first
# connect fails, second works". THE FIX grout uses (and that we are restoring here, contained to OUR
# lib, no fork of the stock pak): gate on wpa_state=COMPLETED, THEN if there's still no lease, take over
# with a bounded, FOREGROUND udhcpc using the STOCK script (-s /etc/init.d/udhcpc.script) now that the
# association is real. A prior pass WRONGLY removed this takeover (mistakenly blaming it for a failure
# that was actually caused by a CUSTOM udhcpc *script* — the takeover CONCEPT is correct, the stock
# script is the right one to run). Degrades safely (just waits + retries DHCP) if wpa_cli's control
# interface is unavailable. The USB re-enum (wifi-reset) stays a rare LAST resort in wifi_acquire.
_WPA_CLI="${WPA_CLI:-$(command -v wpa_cli 2>/dev/null || echo /customer/app/wpa_cli)}"
_UDHCPC_SCRIPT="${UDHCPC_SCRIPT:-/etc/init.d/udhcpc.script}"
_have_up()  { [ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = "up" ]; }
_have_ip()  { ip addr show wlan0 2>/dev/null | grep -q "inet "; }
_have_dns() { nslookup "$ROMM_HOST" >/dev/null 2>&1; }
_assoc_complete() {
	[ -x "$_WPA_CLI" ] || return 1
	[ "$("$_WPA_CLI" -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')" = "COMPLETED" ]
}
# Read the IPv4 address actually assigned to wlan0 (empty if none). Used to print the
# REAL leased address in the verified "Got IP <addr>" line — never a guess.
_wlan_ip() {
	ip addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1
}
# Read the SSID we are CURRENTLY/about-to associate with, LIVE, never hardcoded. Order of
# preference: wpa_cli status (authoritative once associating) -> iwgetid -r (the associated
# SSID) -> iw link -> the first SSID line in the user's wifi.txt (the target we're connecting
# to before association). Returns empty if nothing is known yet (caller falls back to "Wi-Fi").
_ssid_live() {
	_s=""
	if [ -x "$_WPA_CLI" ]; then
		_s=$("$_WPA_CLI" -i wlan0 status 2>/dev/null | sed -n 's/^ssid=//p' | head -1)
	fi
	[ -z "$_s" ] && command -v iwgetid >/dev/null 2>&1 && _s=$(iwgetid -r 2>/dev/null)
	if [ -z "$_s" ] && command -v iw >/dev/null 2>&1; then
		_s=$(iw dev wlan0 link 2>/dev/null | sed -n 's/.*SSID: //p' | head -1)
	fi
	# Target-from-config fallback: the FIRST non-comment "ssid:psk" line in wifi.txt is the
	# network we are bringing up. This is read from the user's own file, never baked into code.
	if [ -z "$_s" ] && [ -s "$SDCARD/wifi.txt" ]; then
		_s=$(sed -n 's/^[[:space:]]*\([^#:][^:]*\):.*/\1/p' "$SDCARD/wifi.txt" | head -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
	fi
	echo "$_s"
}
# _dhcp_takeover — per-platform DHCP lease acquisition, mirroring each stock service-on's DHCP client.
# Called by wait_net AFTER association is verified (wpa COMPLETED + operstate up) and ONLY if no lease
# has landed yet. Bounded + foreground so the caller can then verify the lease. Each branch reproduces
# the matching stock bin/service-on (lodor-base-staging/<plat>/Tools/<plat>/Wifi.pak/bin/service-on):
#   miyoomini  -> stock backgrounds `udhcpc -i wlan0 -s /etc/init.d/udhcpc.script &` BEFORE association
#                 (the 8188fu race). Grout fix, UNCHANGED: re-run FOREGROUND with the SAME stock script.
#   rg35xxplus -> the lease is owned by systemd-networkd (service-on does `netplan apply`); running
#                 udhcpc would FIGHT networkd. No-op here — wait_net simply polls for networkd's lease.
#   my282/my355/default -> stock backgrounds `udhcpc -i wlan0 -q` with the system DEFAULT script (NO -s).
#                 Re-run FOREGROUND the same way (no -s) now that association is real.
_dhcp_takeover() {
	command -v udhcpc >/dev/null 2>&1 || { _wlog "dhcp: no udhcpc binary"; return 0; }
	case "$PLAT" in
		rg35xxplus)
			_wlog "dhcp(rg35xxplus): lease owned by systemd-networkd/netplan — NOT running udhcpc"
			return 0 ;;
		rgb30)
			_wlog "dhcp(rgb30): lease owned by connman (JELOS host) — NOT running udhcpc"
			return 0 ;;
		miyoomini)
			killall udhcpc >/dev/null 2>&1
			_wlog "dhcp(miyoomini): foreground stock-script udhcpc (-s $_UDHCPC_SCRIPT)"
			udhcpc -i "$WIFI_IFACE" -t 8 -T 2 -A 3 -n -q -s "$_UDHCPC_SCRIPT" >>"$WIFI_LOG" 2>&1 ;;
		*)
			killall udhcpc >/dev/null 2>&1
			_wlog "dhcp($PLAT): foreground udhcpc, system default script (mirrors stock -q, no -s)"
			udhcpc -i "$WIFI_IFACE" -t 8 -T 2 -A 3 -n -q >>"$WIFI_LOG" 2>&1 ;;
	esac
	return 0
}

# wait_net narrates the HONEST, VERIFIED association->lease sequence and returns a stage-specific
# code so the caller can print the precise failure reason. Fix 2: "Wi-Fi up" means a USABLE IP, NOT
# "can reach RomM". SUCCESS is declared once _have_up && _have_ip is VERIFIED (after the stock lease);
# RomM reachability is decoupled and handled downstream (romm-run nc -z + engine --validate), so we
# NEVER service-off / tear down a working link just because the RomM host doesn't resolve.
#   0  = Wi-Fi connected (up + a real IPv4 lease, verified)         -> "Wi-Fi connected" / "Got IP <addr>"
#   10 = never associated (no wpa COMPLETED / link never came up)   -> "Couldn't connect to <SSID>"
#   11 = associated but no DHCP lease                               -> "...no IP - resetting radio..."
# The caller has ALREADY written "Connecting to <SSID>..." (pre-association, icon legitimately
# dark). We only advance the text once each precondition is confirmed true.
wait_net() {
	_sd=$(_ssid_disp)
	# 1. Wait for VERIFIED association: wpa_state=COMPLETED AND operstate=up (icon goes live here).
	#    Up to NET_TIMEOUT (~30s): a cold 8188fu associate (scan + 4-way handshake) routinely takes
	#    far longer than the old 8s allowed. Bail straight to success if the stock backgrounded udhcpc
	#    happened to already produce a usable IP-having link (then there's nothing for us to fix).
	i=0
	while [ "$i" -lt "$NET_TIMEOUT" ]; do
		if _have_up && _have_ip; then
			_ip=$(_wlan_ip); [ -n "$_ip" ] && _pset "Got IP $_ip" || _pset "Wi-Fi connected"; return 0
		fi
		_assoc_complete && _have_up && break
		i=$((i + 1)); sleep 1
	done
	if ! { _assoc_complete && _have_up; }; then
		# Never associated within ~30s. Caller turns this into the honest "Couldn't connect to <SSID>".
		_wlog "wait_net: no association (no COMPLETED/up within ${NET_TIMEOUT}s)"
		return 10
	fi
	# VERIFIED associated. Honest, confirmed line (icon is live now -> text+icon agree).
	_pset "Associated with $_sd"
	# 2. LEASE — grout's PROVEN takeover. The stock service-on already fired `udhcpc &` BACKGROUNDED
	#    before association completed, so its DHCPDISCOVER went out on a dead link and missed. Now that
	#    association is REAL, replace that premature client with a bounded, FOREGROUND udhcpc using the
	#    STOCK script: -t 8 discovers @ -T 2s apart, -A 3 backoff, -n exit-if-none, -q quit-on-lease.
	#    THIS re-run-after-association is the reliability fix. (STOCK script only — never a custom one.)
	if ! _have_ip; then
		_pset "Requesting IP address..."
		# Per-platform takeover (miyoomini stock-script udhcpc; default udhcpc on my282/my355; a no-op
		# on rg35xxplus where systemd-networkd owns the lease). See _dhcp_takeover above.
		_dhcp_takeover
		# Confirm a real lease landed (up to ~10s).
		i=0
		while [ "$i" -lt 10 ]; do
			_have_ip && break
			i=$((i + 1)); sleep 1
		done
		if ! _have_ip; then
			_wlog "wait_net: associated but no DHCP lease (after stock-script takeover) -> return 11"
			return 11
		fi
	fi
	# VERIFIED lease — Fix 2: this is SUCCESS. A usable IPv4 link IS "Wi-Fi connected"; we do NOT
	# gate on _have_dns / nslookup $ROMM_HOST, and we do NOT tear down the link if RomM is unreachable.
	# The honest terminal status is the REAL leased address (read live, never guessed). RomM
	# reachability is decoupled and verified downstream (romm-run nc -z gate + engine --validate).
	# Fix 3 DIAGNOSTIC: while we have an IP, probe reachability ONCE for logging only (non-fatal — it
	# never changes the return value) so the next boot's wifi-debug.log tells us WHY RomM was/wasn't
	# reachable. resolv.conf state, raw nslookup, and TCP probes distinguish no-resolver vs
	# host-doesn't-resolve vs resolves-but-blocked.
	_ip=$(_wlan_ip); [ -n "$_ip" ] && _pset "Got IP $_ip" || _pset "Wi-Fi connected"
	if ! _have_dns; then _net_diag; fi
	return 0
}

# Fix 3: lightweight, device-only reachability diagnostic. Appended to wifi-debug.log (NOT committed)
# whenever we have an IP but the RomM host check fails, to distinguish "no resolver configured" vs
# "host doesn't resolve" vs "resolves but TCP blocked". Temporary; never gates Wi-Fi success.
_net_diag() {
	[ -n "$ROMM_HOST" ] || { _wlog "net-diag: ROMM_HOST unset, skipping"; return 0; }
	{
		echo "--- net-diag $(date +'%F %T') host=$ROMM_HOST port=${ROMM_PORT:-443} ip=$(_wlan_ip) ---"
		echo "[resolv.conf]"; cat /etc/resolv.conf 2>&1
		echo "[nslookup $ROMM_HOST]"; nslookup "$ROMM_HOST" 2>&1
		if command -v nc >/dev/null 2>&1; then
			nc -z -w 3 "$ROMM_HOST" "${ROMM_PORT:-443}" >/dev/null 2>&1 \
				&& echo "[nc $ROMM_HOST:${ROMM_PORT:-443}] open" || echo "[nc $ROMM_HOST:${ROMM_PORT:-443}] FAIL"
			# leased gateway (default route) :53 — distinguishes "no route/DNS path" from "host blocked".
			_gw=$(ip route 2>/dev/null | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1)
			if [ -n "$_gw" ]; then
				nc -z -w 3 "$_gw" 53 >/dev/null 2>&1 \
					&& echo "[nc gw $_gw:53] open" || echo "[nc gw $_gw:53] FAIL"
			else
				echo "[gw] undetermined (no default route)"
			fi
		else
			echo "[nc] absent — TCP probes skipped"
		fi
	} >> "$_WIFI_DBG" 2>/dev/null
	_wlog "net-diag: have IP but $ROMM_HOST check failed — appended resolv.conf/nslookup/nc to wifi-debug.log"
	return 0
}

# --- reachability probe (DIAGNOSTIC ONLY — no automatic re-enum / power-cycle) -----------------
# REARCHITECTED 2026-06-25 (the maintainer's decision): we no longer out-clever the radio. The old
# "warm-wedge recovery" here would, on a reachability miss, automatically USB-re-enumerate and
# re-associate the radio (taking it DOWN and back up) — exactly the kind of automatic power
# cycling that was DROPPING Wi-Fi between passes. That whole re-enum loop is GONE. The radio is
# now brought up ONCE and LEFT UP; only the USER powers it down (SELECT toggle) or genuinely
# resets it (the Reset-WiFi pak / bin/wifi-reset, a manual action). So wifi_ensure_reachable is
# now a thin, NON-destructive helper: it guarantees the pure-Go engine has a resolver
# (_ensure_resolv) and probes RomM once FOR LOGGING ONLY, then ALWAYS returns 0 so the engine
# runs and surfaces its OWN honest exit code (3 = unreachable). It never re-enumerates, never
# re-associates, never powers the radio. (Kept as a function because run_sync and romm-run call
# it; making it a no-op-ish gate is the smallest, safest change.)
_romm_reachable() {
	[ -n "$ROMM_HOST" ] || return 0   # host unknown (config parse failed) — engine derives it; don't gate
	command -v nc >/dev/null 2>&1 || return 0   # no nc -> can't probe -> don't fabricate a problem
	nc -z -w "${_REACH_TIMEOUT:-4}" "$ROMM_HOST" "${ROMM_PORT:-443}" >/dev/null 2>&1
}
# Gateway reachability — the LINK-alive test that separates a WEDGED radio (have IP but can't reach
# the gateway => the link is dead, re-enum justified) from RomM simply being DOWN (gateway OK => the
# link is fine, leave the radio alone). HIGH CONFIDENCE: the link is declared dead only if BOTH a
# quick ICMP ping AND a gateway:53 TCP probe fail — a router that answers either is alive. No default
# route at all => no usable link.
_gateway_reachable() {
	_gw=$(ip route 2>/dev/null | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1)
	[ -n "$_gw" ] || return 1
	if command -v ping >/dev/null 2>&1 && ping -c1 -W2 "$_gw" >/dev/null 2>&1; then return 0; fi
	command -v nc >/dev/null 2>&1 && nc -z -w2 "$_gw" 53 >/dev/null 2>&1
}

# Re-enum cooldown — AT MOST one USB re-enum per _REENUM_COOLDOWN seconds, so a persistent wedge
# (e.g. the daemon polling every 60s) re-enumerates ONCE, never on every pass. /tmp clears on reboot,
# the right granularity (a fresh boot may re-enum again). This is what keeps the safeguard from
# becoming the old churn the rearchitecture removed.
_REENUM_COOLDOWN="${REENUM_COOLDOWN:-300}"
_reenum_recent() {
	[ -f /tmp/romm-last-reenum ] || return 1
	_last=$(cat /tmp/romm-last-reenum 2>/dev/null || echo 0)
	[ $(( $(date +%s) - _last )) -lt "$_REENUM_COOLDOWN" ]
}
_mark_reenum() { date +%s > /tmp/romm-last-reenum 2>/dev/null; }

# One-shot wedge recovery: re-enumerate the radio (USB unbind/rebind via bin/wifi-reset), then bring
# it back up with the SAME proven stock sequence wifi_acquire uses (service-on -> wait_net lease) +
# the DNS guarantee. Called ONLY on a CONFIRMED dead link, at most once per cooldown.
_wifi_recover_wedge() {
	_pset "Wi-Fi stalled — resetting radio..."
	_wlog "wedge-recovery: one-shot USB re-enum (bin/wifi-reset)"
	[ -x "$ROMM_PAK_DIR/bin/wifi-reset" ] && "$ROMM_PAK_DIR/bin/wifi-reset" >>"$WIFI_LOG" 2>&1
	[ -x "$WIFI_BIN/service-on" ] && "$WIFI_BIN/service-on" >>"$WIFI_LOG" 2>&1
	wait_net >/dev/null 2>&1
	_ensure_resolv
}

# BRING-UP wedge recovery (2026-06-25): the keep-UP rearchitecture removed auto-recovery, which left
# the BRING-UP failures a USB re-enum genuinely fixes — the radio never enumerating, or the 8188fu
# associating but never getting a DHCP lease (the endless "Sending discover..." we saw on hardware) —
# with no way back except a manual Reset Wi-Fi. This applies ONE cooldown-guarded re-enum to exactly
# those cases and reports whether the link came up. Realtek-8188fu only (it's the chip with the wedge),
# and NEVER for rc-10 no-association (wrong PSK / out of range — a re-enum can't help and would thrash).
# $1 = a short reason string for the log. Returns 0 if the link is up afterward (caller keeps the lock
# and proceeds), 1 otherwise (caller falls through to the honest failure).
_bringup_recover() {
	# 8188fu USB re-enum wedge recovery is miyoomini-ONLY (the Realtek USB radio is exclusive to it).
	# NEVER on the SDIO radios (my282 Allwinner / my355 RK3566 / rg35xxplus H700) — a USB re-enum is
	# meaningless there and bin/wifi-reset targets the 8188fu. Gate on PLATFORM, not just the marker.
	[ "$PLAT" = miyoomini ] || return 1
	[ -f "$ROMM_PAK_DIR/.wifi-8188fu" ] || return 1
	if _reenum_recent; then
		_wlog "acquire: bring-up wedge ($1) but re-enumed within ${_REENUM_COOLDOWN}s — skipping (manual Reset Wi-Fi)"
		return 1
	fi
	_mark_reenum
	_wlog "acquire: bring-up wedge ($1) on 8188fu — one-shot Wi-Fi re-enum"
	_wifi_recover_wedge
	if _radio_ready; then
		_wlog "acquire OK wifi-connected (after one re-enum)"
		return 0
	fi
	_wlog "acquire FAIL bring-up still wedged after one re-enum (manual Reset Wi-Fi)"
	return 1
}

# CONFIRMED-DEAD-PROBE SAFEGUARD (2026-06-25, deliberate): keep the radio UP by default, but if a
# probe PROVES the link is wedged — we hold an IP yet can't reach RomM OR the gateway — apply ONE
# cooldown-guarded re-enum to recover. This is NOT the old churn: it fires only on a confirmed dead
# link (never on RomM-just-down), at most once per _REENUM_COOLDOWN, and the user's manual reset
# remains the fallback if even that doesn't recover it.
wifi_ensure_reachable() {
	_ensure_resolv
	if _romm_reachable; then
		_wlog "reach: ok (RomM reachable) — proceeding"
		return 0
	fi
	# RomM unreachable — is the LINK dead, or is RomM just down?
	if _gateway_reachable; then
		_wlog "reach: RomM unreachable but gateway OK — RomM is down, NOT cycling the radio"
		_net_diag
		return 0
	fi
	# Gateway unreachable. Only the HAVE-IP-but-no-traffic case is the wedge this recovers; no IP at
	# all is the bring-up path's job, not a re-enum trigger.
	if ! _have_ip; then
		_wlog "reach: no IP (bring-up case, not the have-IP wedge) — NOT re-enuming"
		_net_diag
		return 0
	fi
	if _reenum_recent; then
		_wlog "reach: dead link, but re-enumed within ${_REENUM_COOLDOWN}s — skipping (manual reset if it persists)"
		_net_diag
		return 0
	fi
	_mark_reenum
	_wlog "reach: CONFIRMED dead link (have IP, gateway + RomM unreachable) — one-shot Wi-Fi re-enum"
	_wifi_recover_wedge
	if _romm_reachable; then
		_wlog "reach: recovered after one-shot re-enum"
	else
		_wlog "reach: still unreachable after one re-enum — giving up (manual Wi-Fi reset needed)"
		_net_diag
	fi
	return 0
}

# --- DNS resolver guarantee (pure-Go engine needs /etc/resolv.conf) ----------
# WHY: the clean Lodor engine is statically linked / CGO-free, so Go uses its PURE-GO DNS resolver,
# which STRICTLY requires /etc/resolv.conf to contain a `nameserver` line. The old grout32 was
# dynamically linked and used libc's resolver, which works even with an empty resolv.conf — so grout
# connected fine while our engine could not resolve the (perfectly public) RomM host purely because
# this device's /etc/resolv.conf lacks a nameserver. This makes one exist before the engine runs.
# NON-DESTRUCTIVE: if a nameserver is already present (DHCP/device-provided), we leave it untouched.
# Otherwise we seed the default gateway (home routers serve DNS and know LAN names) plus public
# fallbacks 1.1.1.1 / 8.8.8.8. Device-only; logging IPs/gateway here is fine.
_ensure_resolv() {
	if grep -q '^nameserver ' /etc/resolv.conf 2>/dev/null; then
		_wlog "ensure_resolv: ok (existing)"
		return 0
	fi
	# Build the resolver list: default gateway first (LAN-aware), then public fallbacks.
	_gw=$(ip route 2>/dev/null | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1)
	_content=""
	[ -n "$_gw" ] && _content="nameserver $_gw"
	_content="${_content:+$_content
}nameserver 1.1.1.1
nameserver 8.8.8.8"
	_servers=$(echo "$_content" | sed -n 's/^nameserver //p' | tr '\n' ' ')
	# Try writing /etc/resolv.conf directly. Pure-Go reads THIS path specifically.
	if printf '%s\n' "$_content" > /etc/resolv.conf 2>/dev/null && grep -q '^nameserver ' /etc/resolv.conf 2>/dev/null; then
		_wlog "ensure_resolv: wrote /etc/resolv.conf (gw=${_gw:-none} servers: $_servers) writable=yes"
		return 0
	fi
	# Read-only rootfs fallback: stage content in /tmp and symlink /etc/resolv.conf -> /tmp/resolv.conf.
	printf '%s\n' "$_content" > /tmp/resolv.conf 2>/dev/null
	if ln -sf /tmp/resolv.conf /etc/resolv.conf 2>/dev/null && grep -q '^nameserver ' /etc/resolv.conf 2>/dev/null; then
		_wlog "ensure_resolv: /etc/resolv.conf -> /tmp/resolv.conf symlink (gw=${_gw:-none} servers: $_servers) writable=symlink"
		return 0
	fi
	# /etc itself is read-only: the engine's pure-Go resolver will have no nameserver. Surface it.
	_wlog "ensure_resolv: /etc/resolv.conf NOT writable (rootfs ro) — wanted gw=${_gw:-none} servers: $_servers"
	return 1
}

# --- WiFi mutex + SIMPLE "keep it UP" model (REARCHITECTED 2026-06-25) --------
# DECISION (the maintainer): stop cycling the radio. The old keep-warm reaper + cold-cycle + warm-wedge
# re-enum machinery was itself TAKING THE RADIO DOWN between passes, then fighting to bring it back —
# the root cause of "Wi-Fi drops between syncs." We were out-clevering a radio that just wants to stay
# on. So now: bring Wi-Fi up ONCE, LEAVE IT UP, and only act if it's actually down. The USER owns the
# on/off toggle (SELECT -> wifi-toggle) and the genuine wedge reset (Reset-WiFi pak / bin/wifi-reset).
# Nothing in this lib ever powers the radio down automatically anymore.
#
# What's kept: the MUTEX (_WIFI_LOCK) — it serializes transfers (one actor at a time; others get rc 2
# "busy" and skip), which is about COORDINATION, not power, and is still needed so a download and a
# save-push don't stomp each other. The fg/push preemption (a game launch never waits on a background
# save upload) is preserved too — it's also pure mutex coordination, no radio cycling.
#
# What's GONE: _WIFI_WARM / wifi_reap / WIFI_WARM_GRACE / REAP_ONLY_WHEN_CHARGING / the cold-start
# re-enum gamble / the warm-wedge auto re-enum. None of them cycled the radio in a way that helped; all
# of them risked dropping a working link.
_WIFI_LOCK="/tmp/romm-wifi.lock"
_WIFI_STALE=180                            # a held lock older than this (s) with a dead/absent owner is reclaimable
_WIFI_DBG="${WIFI_DBG:-$SDCARD/Tools/$PLAT/Lodor.pak/wifi-debug.log}"
_wlog() { echo "$(date +'%F %T') pid=$$ $1" >> "$_WIFI_DBG" 2>/dev/null; }
# --- HONEST, VERIFIED status line (the source of truth) ----------------------
# THE PRINCIPLE: the launcher displays /tmp/romm-phase VERBATIM and invents no progress of
# its own. So this file must ONLY ever hold a status that is TRUE at the moment it is written.
# _pset writes the exact user-facing line; callers write it ONLY after the precondition for
# that line has been VERIFIED (radio up / wpa COMPLETED / real DHCP lease). A failure REPLACES
# the in-progress line with a specific honest reason — we never leave an "...ing" line standing
# after the operation it described has concluded.
#
# ICON RECONCILIATION: the launcher's status-bar Wi-Fi icon is driven by wlan0 operstate==up
# (PLAT_isOnline -> _have_up). We therefore NEVER write a forward-progress line (Associated /
# Got IP / Connected) unless _have_up is already true, so the lit/blank icon and the text always
# agree. The only lines allowed while the icon is dark are the pre-association attempts
# ("Powering Wi-Fi radio...", "Connecting to <SSID>...") and honest failures.
_pset() {
	echo "$1" > /tmp/romm-phase 2>/dev/null
	_wlog "phase: $1"
	[ "${WIFI_PHASES:-0}" = 1 ] && echo "PHASE $1"
	return 0
}
# Back-compat shim: a few callers still pass symbolic keys. Map them to honest, pre-association
# wording only (these run BEFORE verification, so they must not imply a confirmed state).
_phase() {
	case "$1" in
		radio)   _pset "Powering Wi-Fi radio..." ;;
		join)    _pset "Connecting to $(_ssid_disp)..." ;;
		address) _pset "Requesting IP address..." ;;
		*)       _pset "$1" ;;
	esac
	return 0
}
# SSID for display: the live SSID if known, else a neutral "Wi-Fi" (never a hardcoded name).
_ssid_disp() { _s=$(_ssid_live); [ -n "$_s" ] && echo "$_s" || echo "Wi-Fi"; }

# Settings — the HoardUI Settings tool writes settings.conf; sane defaults if it's absent. (The
# keep-warm/grace/reap knobs are no longer read — the radio is simply left up — so any stale values
# in an old settings.conf are harmless and ignored.)
_ROMM_SETTINGS="$SDCARD/Tools/$PLAT/Lodor.pak/settings.conf"
[ -f "$_ROMM_SETTINGS" ] && . "$_ROMM_SETTINGS" 2>/dev/null

# "radio ready" means a USABLE Wi-Fi LINK: up + a real IPv4 lease. RomM reachability is a SEPARATE,
# downstream concern (engine --validate) and never gates this — a usable link is a usable link even
# when the RomM host is momentarily unreachable.
_radio_ready() { _have_up && _have_ip; }
# True while a LIVE, fresh actor holds the mutex (a stale/dead lock is treated as free).
_actor_active() {
	[ -d "$_WIFI_LOCK" ] || return 1
	o=$(cat "$_WIFI_LOCK/owner" 2>/dev/null); t=$(cat "$_WIFI_LOCK/ts" 2>/dev/null || echo 0); n=$(date +%s)
	[ -n "$o" ] && kill -0 "$o" 2>/dev/null && [ $((n - t)) -le "$_WIFI_STALE" ]
}

# wifi_acquire [mode]   mode: fg = foreground (download / pre-game pull): PREEMPTS a preemptible holder,
#   never preempted itself.  push = post-game save upload: preemptible by fg.  bg = daemon (default):
#   neither preempts nor is preempted.
# returns: 0 = radio up & usable (caller MUST wifi_release); 2 = busy; 1 = error/no-link.
#
# SIMPLE GATE (the whole point of the rearchitecture):
#   - take the mutex (with fg/push preemption, pure coordination — no radio cycling);
#   - if the link is ALREADY up + IP -> proceed immediately (the dominant path once Wi-Fi is on);
#   - else bring it up ONCE via the proven STOCK sequence (service-on -> wait_net: wpa COMPLETED ->
#     foreground stock-script udhcpc lease). NO USB re-enum gamble, NO cold-cycle.
#   - we NEVER power the radio down here or on release. If the one bring-up fails, we report the honest
#     reason and return 1 — the user can retry, toggle Wi-Fi, or use Reset-WiFi for a genuinely wedged
#     radio. (bin/wifi-reset stays a MANUAL, user-invoked tool; this lib never calls it automatically.)
wifi_acquire() {
	_acq_mode="${1:-bg}"
	while :; do
		if mkdir "$_WIFI_LOCK" 2>/dev/null; then
			echo "$$" > "$_WIFI_LOCK/owner"; date +%s > "$_WIFI_LOCK/ts"
			if [ "$_acq_mode" = push ]; then echo 1 > "$_WIFI_LOCK/preempt"; else rm -f "$_WIFI_LOCK/preempt" 2>/dev/null; fi
			[ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ] && break
			continue   # reclaimed during our setup window — re-evaluate
		fi
		owner=$(cat "$_WIFI_LOCK/owner" 2>/dev/null)
		ts=$(cat "$_WIFI_LOCK/ts" 2>/dev/null || echo 0); now=$(date +%s)
		if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null || [ $((now - ts)) -gt "$_WIFI_STALE" ]; then
			rm -f "$_WIFI_LOCK/owner" "$_WIFI_LOCK/ts" "$_WIFI_LOCK/preempt" 2>/dev/null
			rmdir "$_WIFI_LOCK" 2>/dev/null
			continue   # retry the atomic mkdir; if we lose, we re-evaluate the new owner
		fi
		# PREEMPT: foreground seizes the mutex from a preemptible background push, immediately.
		if [ "$_acq_mode" = fg ] && [ "$(cat "$_WIFI_LOCK/preempt" 2>/dev/null)" = 1 ]; then
			_wlog "PREEMPT push owner=$owner (fg incoming)"
			kill -TERM "-$owner" 2>/dev/null || kill -TERM "$owner" 2>/dev/null
			j=0; while kill -0 "$owner" 2>/dev/null && [ "$j" -lt 30 ]; do sleep 0.1; j=$((j + 1)); done
			continue   # holder dying → loop reclaims the now-free lock
		fi
		_wlog "acquire BUSY owner=$owner mode=$_acq_mode"
		return 2   # legitimately busy (a live, fresh, non-preemptible owner)
	done

	# ALREADY UP: the dominant path once Wi-Fi has been turned on. Reuse it as-is — never re-cycle.
	if _radio_ready; then _wlog "acquire OK (link already up — reuse)"; return 0; fi

	# NOT UP: bring it up ONCE via the stock path. No re-enum, no cold-cycle, no retries-by-cycling.
	[ -x "$WIFI_BIN/service-on" ] || { _pset "Wi-Fi radio didn't start"; _wlog "acquire FAIL no service-on tool"; wifi_release; return 1; }
	_pset "Powering Wi-Fi radio..."
	# rg35xxplus (systemd-networkd/netplan): the stock Wifi.pak wifi_on() ALWAYS regenerates the
	# netplan + wpa config from wifi.txt (write_config) BEFORE service-on, because networkd's
	# association is driven ENTIRELY by /etc/netplan/01-netcfg.yaml. Our cold bring-up went straight
	# to service-on (netplan apply) against whatever stale/absent config happened to be on disk, so
	# networkd never associated -> 30s timeout -> the exact "radio didn't start" symptom. Mirror
	# stock and write the config first. PLATFORM-GATED: miyoomini/my282/my355 keep their working
	# straight-to-service-on path byte-for-byte untouched (their service-on reads a persistent conf).
	case "$PLAT" in
		rg35xxplus|rgb30) _wifi_write_config ;;
	esac
	_wlog "acquire: bringing Wi-Fi up (service-on)"
	"$WIFI_BIN/service-on" >>"$WIFI_LOG" 2>&1
	# Persist the 8188fu marker if the Realtek radio enumerated (arms the launcher's MANUAL
	# wifi-reset offer; it does NOT make this lib auto-reset). miyoomini-ONLY: the 8188fu (USB
	# idVendor 0bda) is exclusive to the Mini; my282/my355/rg35xxplus have SDIO radios and must
	# NEVER arm the USB re-enum wedge path.
	if [ "$PLAT" = miyoomini ] && grep -qs 0bda /sys/bus/usb/devices/*/idVendor 2>/dev/null; then
		: > "$ROMM_PAK_DIR/.wifi-8188fu" 2>/dev/null
	fi
	# Wait for the radio to come up / start associating, narrating honestly. Most platforms drive
	# wpa_supplicant directly, so NET_TIMEOUT (~30s) covers a cold scan + 4-way handshake. rg35xxplus
	# associates through systemd-networkd/netplan, whose cold scan+associate routinely runs longer
	# than a direct wpa_supplicant associate; give it a realistic, STILL-POLLED window (no blind
	# sleep -- we break the instant operstate goes up). PLATFORM-GATED so other platforms are
	# byte-for-byte unchanged (NET_TIMEOUT).
	_cold_timeout="$NET_TIMEOUT"
	case "$PLAT" in rg35xxplus) _cold_timeout="${NETWORKD_TIMEOUT:-60}" ;; esac
	_pset "Connecting to $(_ssid_disp)..."
	i=0
	while [ "$i" -lt "$_cold_timeout" ]; do
		{ _have_up || _assoc_complete; } && break
		i=$((i + 1)); sleep 1
	done
	if ! { _have_up || _assoc_complete; }; then
		if _bringup_recover "radio-no-start"; then return 0; fi
		_pset "Wi-Fi radio didn't start"
		_wlog "acquire FAIL radio never came up within ${_cold_timeout}s"
		wifi_release; return 1
	fi
	# Radio up / associating — hand to wait_net for the verified Associated -> Got IP sequence
	# (stock-script foreground udhcpc lease). wait_net never tears the link down.
	wait_net; _wn=$?
	if [ "$_wn" = 0 ]; then _wlog "acquire OK wifi-connected"; return 0; fi
	# Honest failure wording by stage (icon/operstate and these lines agree by construction). We do NOT
	# auto re-enumerate on a no-lease (rc 11) anymore — that was a radio cycle. The user owns recovery.
	if [ "$_wn" = 10 ]; then
		# No association — signal/PSK, not a USB wedge. A re-enum can't help and would thrash, so we
		# don't attempt one; the user retries / checks the network.
		_pset "Couldn't connect to $(_ssid_disp)"
		_wlog "acquire FAIL no-association"
	else
		# Associated but no DHCP lease — the 8188fu "Sending discover..." wedge. Try ONE re-enum.
		if _bringup_recover "no-lease"; then return 0; fi
		_pset "No IP address - check your router"
		_wlog "acquire FAIL associated-but-no-lease (rc=$_wn)"
	fi
	wifi_release; return 1
}

# wifi_release — drop the mutex ONLY. It NEVER powers the radio down (that is the entire rearchitecture:
# the link stays UP between actors so the next op reuses it, and nothing drops it between passes).
# Owner-safe: only THIS process's lock is touched, so a trap/racer/killall never disturbs another
# actor's transfer. The radio is powered down ONLY by the user (wifi-toggle -> wifi_shutdown) or
# uninstall.
wifi_release() {
	if [ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ]; then
		_wlog "release (lock dropped; radio LEFT UP)"
		rm -f "$_WIFI_LOCK/owner" "$_WIFI_LOCK/ts" "$_WIFI_LOCK/preempt" 2>/dev/null
		rmdir "$_WIFI_LOCK" 2>/dev/null
	fi
	return 0
}

# wifi_shutdown — EXPLICIT, USER/UNINSTALL-ONLY power-down. This is the ONE place the radio is turned
# off, and it only runs from a deliberate action: the SELECT Wi-Fi toggle (wifi-toggle) when the user
# turns Wi-Fi OFF, and uninstall's cleanup. It is owner-scoped so it never cuts another process's live
# transfer. Daemons/shims MUST NOT call this on their EXIT traps (that would auto-power-down — the very
# thing we removed); they use wifi_release (lock-drop only).
wifi_shutdown() {
	if [ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ] || ! _actor_active; then
		[ -x "$WIFI_BIN/service-off" ] && "$WIFI_BIN/service-off" >>"$WIFI_LOG" 2>&1
		if [ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ]; then
			rm -f "$_WIFI_LOCK/owner" "$_WIFI_LOCK/ts" "$_WIFI_LOCK/preempt" 2>/dev/null; rmdir "$_WIFI_LOCK" 2>/dev/null
		fi
		_wlog "shutdown service-off (explicit user/uninstall action)"
	fi
	return 0
}

# --- Wi-Fi setup (onboarding step #38): scan + save creds + bring up honestly ----------------
# These power the native first-run Wi-Fi step. We do NOT reimplement the driver. SCANNING uses the
# Miyoo's VENDORED control client `/customer/app/wpa_cli` — NOT `iw`. On-device logs proved `iw` is
# absent on this device (`wifi_scan: no iw binary` repeated), while the stock Wifi.pak drives the radio
# entirely through wpa_supplicant + wpa_cli. So a scan is: ensure wpa_supplicant is up (the wpa_cli
# ctrl interface must exist) -> `wpa_cli scan` -> wait -> `wpa_cli scan_results` -> parse. Credential->
# config generation still mirrors the stock pak's write_config (same wpa_supplicant.conf service-on
# reads). The bring-up itself goes through the §1 honest wifi_acquire path.
# wpa_cli path: the device vendor binary first; a PATH wpa_cli only as a fallback.
[ -x "$_WPA_CLI" ] || _WPA_CLI="$(command -v wpa_cli 2>/dev/null || echo "$_WPA_CLI")"

# Bring the radio rail AND wpa_supplicant up so a wpa_cli scan can run. The wpa_cli control interface
# only exists once wpa_supplicant is running, so unlike a raw `iw` scan we must go through service-on
# (which starts wpa_supplicant). Idempotent; a no-op-ish reuse if the link is already up.
_wifi_radio_warm_for_scan() {
	# If we already have a responsive wpa_cli ctrl interface, the radio+supplicant are up: reuse.
	if [ -x "$_WPA_CLI" ] && "$_WPA_CLI" -i wlan0 status >/dev/null 2>&1; then return 0; fi
	# Otherwise bring the stock service up (starts wpa_supplicant + the working udhcpc); this is the
	# same path the stock Wifi.pak uses, so the ctrl interface comes into existence here.
	[ -x "$WIFI_BIN/service-on" ] && "$WIFI_BIN/service-on" >>"$WIFI_LOG" 2>&1
	# Wait briefly for either the interface to come up OR wpa_cli to answer (ctrl iface ready).
	i=0
	while [ "$i" -lt 10 ]; do
		[ -x "$_WPA_CLI" ] && "$_WPA_CLI" -i wlan0 status >/dev/null 2>&1 && return 0
		_have_up && break
		ifconfig wlan0 up >/dev/null 2>&1
		i=$((i + 1)); sleep 1
	done
	return 0
}

# _wpa_scan_results -> runs a scan via the vendored wpa_cli and echoes the raw `scan_results` table
# (header + one line per BSS: bssid / freq / signal / flags / ssid). Empty on failure. Bounded.
# Shared by wifi_scan (plain SSID list) and the launcher's flagged scan (SECURED/OPEN) so there is
# ONE scan mechanism. Triggers a fresh scan, waits for it to settle, then reads results.
_wpa_scan_results() {
	[ -x "$_WPA_CLI" ] || { _wlog "wifi_scan: no wpa_cli at $_WPA_CLI"; return 1; }
	# Kick a scan. wpa_cli prints "OK" / "FAIL-BUSY"; either way results may already be cached, so
	# we don't hard-fail on a busy scan — we just wait and read what's there.
	"$_WPA_CLI" -i wlan0 scan >/dev/null 2>&1
	_n=0
	while [ "$_n" -lt 12 ]; do
		sleep 1
		_res=$("$_WPA_CLI" -i wlan0 scan_results 2>/dev/null)
		# A usable result has at least one data row beyond the "bssid ..." header line.
		if [ -n "$_res" ] && printf '%s\n' "$_res" | grep -q '^[0-9a-fA-F][0-9a-fA-F]:'; then
			printf '%s\n' "$_res"
			return 0
		fi
		_n=$((_n + 1))
	done
	# Last read even if it looked empty (caller decides what to do with nothing).
	"$_WPA_CLI" -i wlan0 scan_results 2>/dev/null
	return 1
}

# wifi_scan -> prints unique SSIDs (one per line, blanks dropped) to STDOUT. The launcher's flagged
# scan is the primary path; this plain list is the HONEST fallback (its SSIDs get marked SECURED by
# the caller, since this strips the flags column). No driver reimplementation: vendored wpa_cli.
wifi_scan() {
	_wifi_radio_warm_for_scan
	_wpa_scan_results 2>/dev/null \
		| awk 'NR>1 { ssid=$5; for(i=6;i<=NF;i++) ssid=ssid" "$i; if(ssid!="") print ssid }' \
		| sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
		| grep -v '^$' | sort -u > /tmp/romm-wifi-scan 2>/dev/null
	cat /tmp/romm-wifi-scan 2>/dev/null
	[ -s /tmp/romm-wifi-scan ]
}

# wifi_scan_flagged -> the launcher's security-aware scan. One line per network, TAB-separated:
#   SECURED\t<SSID>   (flags column advertises WPA/WPA2/RSN/WEP/PSK -> needs a password)
#   OPEN\t<SSID>      (no security flags -> connect without a password)
# Parses wpa_cli `scan_results` columns (bssid freq signal flags ssid). SSID may contain spaces, so
# it is everything from column 5 onward. Dedup by SSID keeping the STRONGEST signal. Hidden/empty
# SSIDs are dropped. HONEST FALLBACK: if wpa_cli yields nothing parseable, fall back to the plain
# wifi_scan SSID list and mark every entry SECURED (unknown => prompt, never blind open-connect).
wifi_scan_flagged() {
	_wifi_radio_warm_for_scan
	_out=$(_wpa_scan_results 2>/dev/null | awk '
		NR<=1 { next }                       # skip the header row
		{
			bssid=$1; sig=$3+0; flags=$4
			ssid=$5; for(i=6;i<=NF;i++) ssid=ssid" "$i
			if (ssid=="") next               # drop hidden/empty SSIDs
			sec = (flags ~ /WPA|RSN|WEP|PSK/) ? "SECURED" : "OPEN"
			# keep strongest signal per SSID
			if (!(ssid in best) || sig > best[ssid]) { best[ssid]=sig; flag[ssid]=sec }
		}
		END { for (s in flag) printf "%s\t%s\t%s\n", best[s], flag[s], s }
	' | sort -t"$(printf '\t')" -k1,1nr | cut -f2- )
	if [ -n "$_out" ]; then
		printf '%s\n' "$_out"
		return 0
	fi
	# HONEST fallback: no parseable security info -> plain SSID list, every entry SECURED.
	_wlog "wifi_scan_flagged: no parseable wpa_cli results, falling back to SECURED-all list"
	wifi_scan 2>/dev/null | while IFS= read -r _ss; do
		[ -n "$_ss" ] && printf 'SECURED\t%s\n' "$_ss"
	done
}

# wifi_save_network <SSID> [PSK]  — upsert the SSID:PSK line into wifi.txt (open network => empty PSK),
# newest-first so it becomes the priority network, then regenerate the wpa_supplicant.conf that
# service-on reads. PSK is passed as an argument (the launcher already collected it via the keyboard);
# it is written to the user's own wifi.txt exactly as the stock pak does — no new exposure surface.
wifi_save_network() {
	_ssid="$1"; _psk="$2"
	[ -n "$_ssid" ] || { _wlog "wifi_save_network: empty SSID"; return 1; }
	touch "$SDCARD/wifi.txt" 2>/dev/null
	# drop any existing entry for this SSID, then prepend the new one (priority = first line).
	_tmp="$SDCARD/wifi.txt.tmp.$$"
	printf '%s:%s\n' "$_ssid" "$_psk" > "$_tmp" 2>/dev/null
	grep -v "^${_ssid}:" "$SDCARD/wifi.txt" 2>/dev/null >> "$_tmp"
	mv "$_tmp" "$SDCARD/wifi.txt" 2>/dev/null
	_wifi_write_config
}

# _wifi_write_config — regenerate the wpa_supplicant config (and, on rg35xxplus, the netplan file)
# from wifi.txt, MIRRORING the stock Wifi.pak launch.sh write_config() EXACTLY, per platform. The stock
# bin/service-on does NOT write config — it assumes the config already exists on disk (launch.sh's
# wifi_on() calls write_config() before service-on). So this lib must produce that file at the path the
# platform's service-on reads BEFORE it defers to service-on. Every branch below cites the stock
# write_config destination it reproduces (lodor-base-staging/<plat>/Tools/<plat>/Wifi.pak/launch.sh):
#   template:  miyoomini/my282/my355 -> res/wpa_supplicant.conf.<plat>.tmpl ; others -> res/wpa_supplicant.conf.tmpl
#   wpa dest:  miyoomini  -> /etc/wifi + /appconfigs      my282 -> /etc/wifi + /config
#              my355      -> /userdata/cfg                 rg35xxplus -> /etc/wpa_supplicant + netplan
#              default    -> /etc/wifi   (tg5040/zero28/magicmini/rg40xxcube share the stock tmpl path)
# One network{} block per "ssid:psk" line, first gets priority=1, empty psk => key_mgmt=NONE — identical
# to stock. rg35xxplus additionally gets a netplan access-points block per network (its DHCP/assoc runs
# through systemd-networkd, not wpa_supplicant directly). miyoomini behavior is unchanged in effect.
_wifi_write_config() {
	# rgb30 (PowKiddy RGB30, JELOS/LibreELEC host): credentials are NOT a wpa_supplicant.conf — the
	# system persists them via set_setting and connman associates+leases. Mirror the stock rgb30
	# Wi-Fi.pak write path: push the FIRST wifi.txt network's ssid/key through set_setting, then return
	# (no wpa file, no netplan, no udhcpc). $PLAT-gated so every other platform's path is byte-identical.
	if [ "$PLAT" = rgb30 ]; then
		( . /etc/profile 2>/dev/null || true
		  _s=$(sed -n 's/^[[:space:]]*\([^#:][^:]*\):.*/\1/p' "$SDCARD/wifi.txt" 2>/dev/null | head -1)
		  _p=$(sed -n 's/^[[:space:]]*[^#:][^:]*:\(.*\)/\1/p' "$SDCARD/wifi.txt" 2>/dev/null | head -1)
		  _s=$(printf '%s' "$_s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
		  if [ -n "$_s" ] && command -v set_setting >/dev/null 2>&1; then
			set_setting wifi.ssid "$_s"
			set_setting wifi.key "$_p"
		  fi )
		_wlog "_wifi_write_config(rgb30): pushed ssid/key via set_setting (JELOS connman owns assoc+lease)"
		return 0
	fi
	_resdir="$WIFI_BIN/../res"
	case "$PLAT" in
		miyoomini|my282|my355) _tmpl="$_resdir/wpa_supplicant.conf.$PLAT.tmpl" ;;
		*)                     _tmpl="$_resdir/wpa_supplicant.conf.tmpl" ;;
	esac
	[ -f "$_tmpl" ] || _tmpl="$_resdir/wpa_supplicant.conf.miyoomini.tmpl"   # last-ditch fallback
	_out="/tmp/romm-wpa.conf.$$"
	if [ -f "$_tmpl" ]; then cp "$_tmpl" "$_out" 2>/dev/null; else
		# Minimal header if the stock template is missing (keeps us self-contained).
		printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\n' > "$_out" 2>/dev/null
	fi
	# rg35xxplus drives assoc+DHCP through systemd-networkd via a netplan file (stock write_config
	# generates res/netplan.yaml from res/netplan.yaml.tmpl and appends an access-points block per
	# network). Build that alongside the wpa conf so service-on's `netplan apply` has credentials.
	_np=""
	if [ "$PLAT" = rg35xxplus ]; then
		_np="/tmp/romm-netplan.yaml.$$"
		[ -f "$_resdir/netplan.yaml.tmpl" ] && cp "$_resdir/netplan.yaml.tmpl" "$_np" 2>/dev/null
	fi
	[ -s "$SDCARD/wifi.txt" ] || { _wlog "_wifi_write_config: empty wifi.txt"; rm -f "$_out" "$_np"; return 1; }
	_prio=1; _nets=0
	# read each non-comment ssid:psk line; xargs-trim fields.
	while IFS= read -r _ln; do
		_ln=$(printf '%s' "$_ln" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
		[ -z "$_ln" ] && continue
		case "$_ln" in \#*) continue ;; esac
		case "$_ln" in *:*) : ;; *) continue ;; esac
		_s=$(printf '%s' "$_ln" | cut -d: -f1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
		_p=$(printf '%s' "$_ln" | cut -d: -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
		[ -n "$_s" ] || continue
		_nets=$((_nets + 1))
		{
			echo "network={"
			echo "    ssid=\"$_s\""
			if [ "$_prio" = 1 ]; then echo "    priority=1"; _prio=0; fi
			if [ -z "$_p" ]; then echo "    key_mgmt=NONE"; else echo "    psk=\"$_p\""; fi
			echo "}"
		} >> "$_out"
		# rg35xxplus netplan access-point block — mirrors stock write_config's netplan append exactly
		# (16-space SSID key, 20-space password) so `netplan apply` reads the same structure.
		if [ "$PLAT" = rg35xxplus ] && [ -n "$_np" ]; then
			{
				echo "                \"$_s\":"
				echo "                    password: \"$_p\""
			} >> "$_np"
		fi
	done < "$SDCARD/wifi.txt"
	# Install to the EXACT destination(s) the matching stock service-on reads (per write_config()).
	case "$PLAT" in
		miyoomini)   # stock: cp -> /etc/wifi + /appconfigs (service-on: wpa_supplicant -c /appconfigs/...)
			cp "$_out" /etc/wifi/wpa_supplicant.conf 2>/dev/null
			cp "$_out" /appconfigs/wpa_supplicant.conf 2>/dev/null ;;
		my282)       # stock: cp -> /etc/wifi + /config (service-on: /etc/init.d/wpa_supplicant start)
			cp "$_out" /etc/wifi/wpa_supplicant.conf 2>/dev/null
			cp "$_out" /config/wpa_supplicant.conf 2>/dev/null ;;
		my355)       # stock: cp -> /userdata/cfg (service-on: wpa_supplicant -c /userdata/cfg/...)
			mkdir -p /userdata/cfg 2>/dev/null
			cp "$_out" /userdata/cfg/wpa_supplicant.conf 2>/dev/null ;;
		rg35xxplus)  # stock: cp -> /etc/wpa_supplicant + netplan -> /etc/netplan/01-netcfg.yaml
			mkdir -p /etc/wpa_supplicant /etc/netplan 2>/dev/null
			cp "$_out" /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null
			if [ "$_nets" -gt 0 ] && [ -n "$_np" ]; then
				cp "$_np" /etc/netplan/01-netcfg.yaml 2>/dev/null
			else
				# stock: no credentials -> remove the netplan file (avoid applying an empty config).
				rm -f /etc/netplan/01-netcfg.yaml 2>/dev/null
			fi ;;
		*)           # tg5040 / zero28 / magicmini / rg40xxcube / any future udhcpc-style platform
			cp "$_out" /etc/wifi/wpa_supplicant.conf 2>/dev/null ;;
	esac
	rm -f "$_out" "$_np" 2>/dev/null
	_wlog "_wifi_write_config: regenerated wpa_supplicant.conf for $PLAT ($_nets network(s))"
	return 0
}

# --- clock (TLS needs a sane clock; no RTC battery) --------------------------
# NTP over UDP first (numeric IP = time.cloudflare.com, no DNS/TLS dependency); HTTP-Date last resort.
# On success, persist to datetime.txt so the whole device clock stays honest between shutdowns.
_persist_clock() { [ -n "$DATETIME_PATH" ] && date +'%F %T' > "$DATETIME_PATH" 2>/dev/null; return 0; }
set_clock() {
	# FAST PATH: the device has no RTC battery, so the clock starts at epoch (1970) after a
	# power loss and needs ONE network sync per boot. Re-running NTP on EVERY engine call cost
	# 6-10s each (the real "everything is slow" cause). If the clock already reads a sane recent
	# year it's been set this session — skip instantly. Only the first call per boot pays NTP.
	_yr=$(date +%Y 2>/dev/null)
	if [ -n "$_yr" ] && [ "$_yr" -ge 2024 ] 2>/dev/null; then return 0; fi
	if command -v ntpd >/dev/null 2>&1 && ntpd -q -n -p 162.159.200.123 >/dev/null 2>&1; then _persist_clock; return 0; fi
	if command -v sntp >/dev/null 2>&1 && sntp -sS 162.159.200.123 >/dev/null 2>&1; then _persist_clock; return 0; fi
	d="$(wget -S -q -O /dev/null "http://$ROMM_HOST/" 2>&1 | sed -n 's/^ *Date: //p' | head -1)"
	if [ -n "$d" ] && date -s "$d" >/dev/null 2>&1; then _persist_clock; return 0; fi
	return 1
}

# --- run the sync binary -----------------------------------------------------
# Runs from the Lodor pak so the engine reads config.json (CWD-relative). The Lodor engine is a
# STATIC, CGO-free, SDL-free binary: it needs no shared libs. CFW=MinUI is required (the engine's
# path resolution rejects an empty CFW); the SDL_* exports are harmless and ignored.
#
# FLAG MIGRATION (Phase 6): the old binary did a whole-library two-way "full sync" when called with
# NO args (launch.sh "Sync Now", romm-syncd daemon). The clean engine intentionally has NO bare
# full-sync mode (whole-library negotiate was not ported — saves now pull per-game via the minarch
# shim's --sync-save). So a BARE run_sync is expanded here to the clean-engine "Sync Now" sequence
# the native launcher already uses: refresh the library catalog + collections, then flush the
# offline pending-upload queue. A run_sync call WITH args (e.g. --sync-save, --download) passes
# through unchanged. Returns the engine exit code (0 ok / 2 cfg / 3 unreachable / 4 errors); for the
# bare sequence the WORST step's code wins so launch.sh's unreachable-retry still triggers on 3.
run_sync() {
	# DNS guarantee: every engine invocation (validate / set-server / pair / mirror-catalog /
	# mirror-collections / push-pending / --download / --sync-save) flows through run_sync, so ensuring
	# resolv.conf HERE — before the exec below — guarantees the pure-Go resolver always has a nameserver,
	# regardless of whether the radio was warm-reused or freshly leased upstream. Non-fatal: a ro rootfs
	# only logs the problem (the engine still derives the host from config.json and may resolve via a
	# device-provided resolver if one appears).
	_ensure_resolv
	# WARM-WEDGE recovery (engine-op path): before running the engine, make sure the warm link can
	# actually reach RomM - clears the "associated + has IP but no traffic" wedge via a USB re-enum when
	# (and only when) a cheap nc probe fails. Non-fatal: a real outage just returns 1 and we still run the
	# engine so its own honest exit code (3 = unreachable) reaches the caller's retry logic. A working
	# link sails through with one near-instant probe and is never re-enumerated. (run_sync is the single
	# path every engine invocation flows through, so placing it here covers the daemon full-sync and the
	# per-game --sync-save; romm-run gates its direct --download/--push/--mirror calls the same way. The
	# bare --wifi-connect onboarding step never reaches run_sync, so connecting to Wi-Fi stays ungated.)
	wifi_ensure_reachable || _wlog "run_sync: RomM still unreachable after wedge-recovery - running engine anyway for honest rc"
	( cd "$ROMM_PAK_DIR" || exit 2
	  export SDCARD_PATH="$SDCARD"
	  export PLATFORM="$PLAT"
	  export BASE_PATH="$SDCARD"
	  # CFW=MinUI is required by the engine's path resolution; the rest are harmless/ignored.
	  export CFW=MinUI
	  export MINUI_DEVICE="$PLAT"
	  export IS_MIYOO=1

	  if [ "$#" -gt 0 ]; then
	  	# Targeted/explicit mode — pass through to the clean engine unchanged.
	  	"$SYNC_BIN" "$@"
	  	exit $?
	  fi

	  # Bare "full sync" -> the LIGHT background save-flush (the romm-syncd daemon path). The heavy
	  # library catalog + collections mirror is deliberately NOT here: it's a user-driven "Refresh
	  # Library" action, not something the 30-min charging-gated daemon should re-run every cycle over
	  # the flaky radio (that load was pointless and slow). Just flush the offline pending-upload queue
	  # and refresh the Continue cache. Worst exit code wins.
	  worst=0
	  "$SYNC_BIN" --push-pending;       rc=$?; [ "$rc" -gt "$worst" ] && worst=$rc
	  # Continue tile: cache the most-recently-played game (cross-device) for the launcher's
	  # index-0 hero row. Best-effort — does NOT affect $worst; on an empty/failed fetch we
	  # KEEP the previous recent.txt (don't clobber a good value with a transient miss).
	  _recent_out=$("$SYNC_BIN" --recent 2>/dev/null)
	  [ -n "$_recent_out" ] && printf '%s\n' "$_recent_out" > "$ROMM_PAK_DIR/recent.txt"
	  exit $worst
	)
}

# --- gates -------------------------------------------------------------------
# Charging: PLUS board reads the AXP PMIC (field 7 == 3); fall back to the gpio59 charger line.
is_charging() {
	if [ -x /customer/app/axp_test ]; then
		[ "$(/customer/app/axp_test 2>/dev/null | awk -F'[,: {}]+' '{print $7}')" = "3" ]
	else
		[ "$(cat /sys/devices/gpiochip0/gpio/gpio59/value 2>/dev/null)" = "1" ]
	fi
}
creds_present() {
	[ -f "$ROMM_PAK_DIR/config.json" ] || return 1
	grep -q '"token"' "$ROMM_PAK_DIR/config.json" 2>/dev/null || return 1
	[ -s "$SDCARD/wifi.txt" ] || return 1
	return 0
}
