#!/bin/sh
# miyoomini-ui-check.sh — offline gate for the #19 framebuffer-wedge fix.
#
# THE RULE UNDER TEST: on miyoomini, NEVER run minui-presenter and NEVER kill/killall any
# process with a video context (presenter's signal handlers exit() without GFX teardown; the
# MinUI miyoomini layer allocates the video surface from the SigmaStar MI pool with no restore
# path — a killall'd renderer wedges the framebuffer BLACK until reboot, live-repro'd 0.9.7.7).
# The safe backend is show.elf (fire-and-forget phase PNGs) + FOREGROUND say.elf (terminal,
# block-until-A, clean exit).
#
# What it proves, without hardware (trace-based — the REAL launch.sh, fake deps):
#   1. PARSE — both pak launch.sh files parse under sh -n (and dash when available).
#   2. UPDATE PAK / miyoomini — staged, up-to-date and failure flows: trace contains show.elf
#      phase PNGs + a final foreground say.elf, and ZERO minui-presenter / minui-list / killall;
#      the staging path ends in the power-cycle message with NO reboot/poweroff call.
#   3. UPDATE PAK / my355 — control: presenter + minui-list still drive the UI, unchanged.
#   4. RESET WIFI PAK / miyoomini — log-only phases + wrapped say.elf terminal, ZERO presenter/
#      minui-list/killall.  / my355 — presenter + minui-list still used.
#   5. RES PNGs — the committed phase PNGs exist (mm_show hard-requires them).
#
# Run from anywhere: paths are derived from this script's location. Exit 0 = all green.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"   # lodoros/test -> repo root
LODOROS="$ROOT/lodoros"
UPDPAK="$LODOROS/paks/Update Lodor.pak"
RWPAK="$LODOROS/paks/Reset WiFi.pak"
FAILS=0

say()  { printf '%s\n' "$*"; }
pass() { say "  ok: $*"; }
fail() { say "  FAIL: $*"; FAILS=$((FAILS+1)); }

SANDBOX="$(mktemp -d /tmp/mmui-check.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

# ─── 1. PARSE ─────────────────────────────────────────────────────────────────────
say "[1/5] parse checks"
for f in "$UPDPAK/launch.sh" "$RWPAK/launch.sh"; do
	[ -f "$f" ] || { fail "missing $f"; continue; }
	if sh -n "$f" 2>/dev/null; then
		if command -v dash >/dev/null 2>&1; then
			dash -n "$f" 2>/dev/null && pass "$(basename "$(dirname "$f")") (sh+dash)" || fail "$(basename "$(dirname "$f")") dash -n"
		else
			pass "$(basename "$(dirname "$f")") (sh)"
		fi
	else
		fail "$(basename "$(dirname "$f")") sh -n"
	fi
done

# ─── sandbox scaffolding ──────────────────────────────────────────────────────────
# Everything a run can invoke is either an ABS-path stub inside the fake SDCARD
# (.system/<plat>/bin/{show,say}.elf, Lodor.pak/lodor-sync, a fake lib) or a PATH-shadowed
# stub (minui-presenter, minui-list, killall, reboot, poweroff). Every stub appends one line
# to the per-case trace; the asserts are pure trace greps.

mk_stub() { # <path> <name-to-log> [extra-body]
	cat > "$1" <<EOF
#!/bin/sh
echo "$2 \$*" >> "$TRACE"
${3:-}
exit 0
EOF
	chmod +x "$1"
}

build_common() { # $1 = case id, $2 = platform
	SD="$SANDBOX/sd$1"; PLATC="$2"
	LP="$SD/Tools/$PLATC/Lodor.pak"
	SYSB="$SD/.system/$PLATC/bin"
	TRACE="$SD/trace.log"
	mkdir -p "$LP/lib" "$LP/bin" "$SYSB" "$SD/Tools/$PLATC/Wifi.pak/bin"
	: > "$TRACE"
	mk_stub "$SYSB/show.elf" "show.elf"
	mk_stub "$SYSB/say.elf"  "say.elf"
	# PATH-shadowed fleet: presenter/list must NEVER appear in a miyoomini trace; killall is
	# shadowed so an invocation is VISIBLE (never silently absent because the tool is missing).
	FAKEBIN="$SANDBOX/bin$1"; mkdir -p "$FAKEBIN"
	mk_stub "$FAKEBIN/minui-presenter" "minui-presenter"
	mk_stub "$FAKEBIN/killall"         "killall"
	mk_stub "$FAKEBIN/reboot"          "reboot"
	mk_stub "$FAKEBIN/poweroff"        "poweroff"
	# minui-list: log, and answer "Later" so the my355 reboot offer never reboots the host.
	cat > "$FAKEBIN/minui-list" <<EOF
#!/bin/sh
echo "minui-list \$*" >> "$TRACE"
out=""
while [ \$# -gt 0 ]; do [ "\$1" = --write-location ] && out="\$2"; shift; done
[ -n "\$out" ] && echo "Later" > "\$out"
exit 0
EOF
	chmod +x "$FAKEBIN/minui-list"
	# fake lib — the surface launch.sh actually uses; say() mirrors the real one's log-only role.
	cat > "$LP/lib/romm-sync-lib.sh" <<EOF
SYNC_BIN="\$LODOR/lodor-sync"
WIFI_BIN="\$SDCARD/Tools/\$PLAT/Wifi.pak/bin"
say(){ echo "libsay \$1" >> "$TRACE"; return 0; }
clear_say(){ return 0; }
set_clock(){ return 0; }
is_charging(){ return 0; }
wifi_release(){ return 0; }
_radio_ready(){ return 0; }
_wlan_ip(){ echo 10.0.0.5; }
wifi_acquire(){ echo "wifi_acquire \$*" >> "$TRACE"; echo "Connected" > /tmp/romm-phase; return 0; }
EOF
	rm -f /tmp/romm-phase /tmp/dl-progress 2>/dev/null
}

# ─── 2+3. UPDATE PAK ─────────────────────────────────────────────────────────────
build_upd() { # $1 = case id, $2 = platform, $3 = check-update mode (yes|no), $4 = fetch rc
	build_common "$1" "$2"
	UPD="$SD/Tools/$PLATC/Update Lodor.pak"
	mkdir -p "$UPD/res"
	cp "$UPDPAK/launch.sh" "$UPD/launch.sh"; chmod +x "$UPD/launch.sh"
	cp "$UPDPAK/res/"*.png "$UPD/res/" 2>/dev/null   # committed phase PNGs (asserted in [5])
	cat > "$LP/lodor-sync" <<EOF
#!/bin/sh
echo "lodor-sync \$*" >> "$TRACE"
case "\$1" in
	--check-update)
		if [ "$3" = no ]; then echo "RESULT update=0 latest=0.9.7.7 current=0.9.7.7"
		else echo "RESULT update=1 latest=0.9.7.8 current=0.9.7.7"; fi ;;
	--fetch-update) exit $4 ;;
esac
exit 0
EOF
	chmod +x "$LP/lodor-sync"
}

run_upd() {
	PATH="$FAKEBIN:$PATH" SDCARD_PATH="$SD" PLATFORM="$PLATC" \
		sh "$SD/Tools/$PLATC/Update Lodor.pak/launch.sh" >/dev/null 2>&1
}

no_wedge_asserts() { # $1 = case label — the #19 hard rule, asserted identically everywhere
	grep -q '^minui-presenter' "$TRACE" && fail "$1: minui-presenter ran on miyoomini (#19 WEDGE)" || pass "$1: no minui-presenter"
	grep -q '^minui-list'      "$TRACE" && fail "$1: minui-list ran on miyoomini" || pass "$1: no minui-list"
	grep -q '^killall'         "$TRACE" && fail "$1: killall ran on miyoomini (#19 WEDGE)" || pass "$1: no killall"
}

say "[2/5] update pak — miyoomini (show.elf/say.elf backend)"

# U1: update available, fetch succeeds -> phase PNGs, power-cycle final, NO reboot.
build_upd U1 miyoomini yes 0
run_upd
grep -q '^show.elf ' "$TRACE" && fail "U1: show.elf invoked from menu context (banned 2026-07-11 — corrupted-band photo)" || pass "U1: no show.elf from menu context (phases log-only)"
grep -q '^say.elf' "$TRACE" && grep -q 'Update downloaded' "$TRACE" \
	&& pass "U1: staging ends in the power-cycle say.elf message" || fail "U1: power-cycle final message missing"
grep -q 'Turn the device' "$TRACE" && grep -q 'always safe' "$TRACE" && pass "U1: 'powering off is safe' present" || fail "U1: safety sentence missing"
grep -Eq '^(reboot|poweroff)' "$TRACE" && fail "U1: reboot/poweroff invoked on miyoomini (must be power-cycle msg only)" || pass "U1: no reboot call"
awk '/^lodor-sync --fetch-update/{f=NR} /^say.elf .*Update downloaded/{s=NR} END{exit !(f&&s&&f<s)}' "$TRACE" \
	&& pass "U1: final message ordered after staging" || fail "U1: staging/final order wrong"
no_wedge_asserts U1

# U2: up to date -> say.elf "You're up to date (<ver>)."
build_upd U2 miyoomini no 0
run_upd
grep -q "^say.elf You're up to date (0.9.7.7)." "$TRACE" && pass "U2: up-to-date say.elf message" || fail "U2: up-to-date message missing/wrong"
no_wedge_asserts U2

# U3: fetch fails (rc 3, generic) -> honest failure via say.elf, still no wedge vectors.
build_upd U3 miyoomini yes 3
run_upd
grep -q '^say.elf Download failed' "$TRACE" && pass "U3: honest failure via say.elf" || fail "U3: failure message missing"
no_wedge_asserts U3

say "[3/5] update pak — my355 control (presenter flow unchanged)"
build_upd U4 my355 yes 0
run_upd
grep -q '^minui-presenter' "$TRACE" && pass "U4: minui-presenter still drives phases on my355" || fail "U4: presenter not used on my355"
grep -q '^minui-list'      "$TRACE" && pass "U4: minui-list still drives the reboot offer on my355" || fail "U4: minui-list not used on my355"
grep -q '^killall minui-presenter' "$TRACE" && pass "U4: presenter lifecycle (killall) unchanged on my355" || fail "U4: presenter killall missing on my355"
grep -Eq '^(show\.elf|say\.elf)' "$TRACE" && fail "U4: miyoomini backend leaked onto my355" || pass "U4: no show/say.elf on my355"
grep -Eq '^(reboot|poweroff)' "$TRACE" && fail "U4: rebooted the host (stub chose Later)" || pass "U4: no reboot (Later chosen)"

# ─── 4. RESET WIFI PAK ───────────────────────────────────────────────────────────
build_rw() { # $1 = case id, $2 = platform
	build_common "$1" "$2"
	RW="$SD/Tools/$PLATC/Reset WiFi.pak"
	mkdir -p "$RW/res"
	cp "$RWPAK/launch.sh" "$RW/launch.sh"; chmod +x "$RW/launch.sh"
	cp "$RWPAK/res/"*.png "$RW/res/" 2>/dev/null
	mk_stub "$LP/bin/wifi-reset" "wifi-reset"                              # miyoomini reset half
	mk_stub "$SD/Tools/$PLATC/Wifi.pak/bin/service-off" "service-off"      # SDIO reset half
}

run_rw() {
	PATH="$FAKEBIN:$PATH" SDCARD_PATH="$SD" PLATFORM="$PLATC" \
		sh "$SD/Tools/$PLATC/Reset WiFi.pak/launch.sh" >/dev/null 2>&1
}

say "[4/5] reset wifi pak — miyoomini + my355 control"

# R1: miyoomini happy path -> resetting-wifi PNG, say.elf terminal, no wedge vectors.
build_rw R1 miyoomini
run_rw
grep -q '^show.elf ' "$TRACE" && fail "R1: show.elf invoked from menu context (banned)" || pass "R1: no show.elf (phases log-only)"
grep -q '^wifi-reset' "$TRACE" && pass "R1: usb re-enum reset ran" || fail "R1: wifi-reset not invoked"
grep -q '^say.elf .*back online' "$TRACE" && pass "R1: terminal state via say.elf" || fail "R1: say.elf terminal missing"
no_wedge_asserts R1

# R2: my355 control -> presenter phases + minui-list terminal, no miyoomini backend.
build_rw R2 my355
run_rw
grep -q '^service-off' "$TRACE" && pass "R2: SDIO service cycle ran" || fail "R2: service-off not invoked"
grep -q '^minui-presenter' "$TRACE" && pass "R2: presenter still drives phases on my355" || fail "R2: presenter not used on my355"
grep -q '^minui-list' "$TRACE" && pass "R2: minui-list still drives the terminal state on my355" || fail "R2: minui-list not used on my355"
grep -Eq '^(show\.elf|say\.elf)' "$TRACE" && fail "R2: miyoomini backend leaked onto my355" || pass "R2: no show/say.elf on my355"

# ─── 5. COMMITTED RES PNGs ───────────────────────────────────────────────────────
say "[5/5] committed phase PNGs"
# PNGs deliberately removed 2026-07-11 (grayscale-blit corruption on hardware); assert ABSENT
for p in "$UPDPAK/res/connecting-wifi.png" "$RWPAK/res/resetting-wifi.png"; do
	[ -e "$p" ] && fail "stale phase PNG still shipped: $p" || pass "phase PNG absent: $(basename "$p")"
done

say ""
if [ "$FAILS" -gt 0 ]; then
	say "miyoomini-ui-check: $FAILS FAILURE(S)"
	exit 1
fi
say "miyoomini-ui-check: all green"
exit 0
