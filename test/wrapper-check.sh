#!/bin/sh
# wrapper-check.sh — offline gate for the LodorOS shell layer (task #145/#146/#147/#149).
#
# What it proves, without hardware:
#   1. PARSE — every wrapper/shim/lib/boot script parses under `sh -n` (and dash when
#      available, the strictest common denominator for the busybox/ash targets).
#   2. RA BRACKET TRACE — runs the real emus-h700 wrapper in a sandboxed fake SDCARD
#      with a PATH-shadowed fake `pgrep` and a fake `lodor-sync`/fake-RA pair, and
#      asserts the _on_exit contract: responsive RA -> GET_STATUS probe, QUIT, bounded
#      wait, push STILL runs; silent RA -> probe once, "ra-net UNSUPPORTED" logged,
#      stamp written, NEVER probed again, push STILL runs; RA already dead -> no
#      probe, push STILL runs. The HARD RULE (push never conditional on bracketing)
#      is asserted in every case.
#   3. BOOT RESTORE — the forward-only clock restore block (task #147) against three
#      datetime.txt states: stored-newer (restores), stored-older (never moves the
#      clock backward), missing (no-op).
#
# Run from anywhere: paths are derived from this script's location. Exit 0 = all green.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"   # lodoros/test -> repo root
LODOROS="$ROOT/lodoros"
FAILS=0

say()  { printf '%s\n' "$*"; }
pass() { say "  ok: $*"; }
fail() { say "  FAIL: $*"; FAILS=$((FAILS+1)); }

# ─── 1. PARSE ─────────────────────────────────────────────────────────────────────
say "[1/5] parse checks"
PARSE_TARGETS="
$LODOROS/emus-h700/N64.pak/launch.sh
$LODOROS/emus-h700/DC.pak/launch.sh
$LODOROS/emus-h700/PSP.pak/launch.sh
$LODOROS/paks/Lodor.pak/bin/minarch-shim.sh
$LODOROS/paks/Lodor.pak/bin/romm-session-sync
$LODOROS/paks/Lodor.pak/bin/romm-syncd
$LODOROS/paks/Lodor.pak/lib/romm-sync-lib.sh
$LODOROS/workspace/miyoomini/install/boot.sh
$LODOROS/workspace/my282/install/boot.sh
$LODOROS/workspace/my355/install/boot.sh
"
for f in $PARSE_TARGETS; do
	[ -f "$f" ] || { fail "missing $f"; continue; }
	if sh -n "$f" 2>/dev/null; then
		if command -v dash >/dev/null 2>&1; then
			dash -n "$f" 2>/dev/null && pass "$(basename "$f") (sh+dash)" || fail "$(basename "$f") dash -n"
		else
			pass "$(basename "$f") (sh)"
		fi
	else
		fail "$(basename "$f") sh -n"
	fi
done

# ─── sandbox scaffolding ──────────────────────────────────────────────────────────
SANDBOX="$(mktemp -d /tmp/wrapper-check.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

build_sandbox() {
	# fresh fake SDCARD per case
	SD="$SANDBOX/sd$1"
	PAKD="$SD/Emus/h700/N64.pak"
	TOOLS="$SD/Tools/h700/Lodor.pak"
	TRACE="$SD/trace.log"
	RA_PIDFILE="$SD/fake-ra.pid"
	mkdir -p "$PAKD" "$TOOLS/bin" "$SD/.userdata/h700" "$SD/.userdata/shared/.minui" "$SD/Roms/Nintendo 64 (N64)" "$SD/Saves/N64"
	rm -rf /tmp/lodor-shots-N64
	cp "$LODOROS/emus-h700/N64.pak/launch.sh" "$PAKD/launch.sh"
	chmod +x "$PAKD/launch.sh"

	# launch.real.sh — upstream stand-in; mentions retroarch so _emu_family says "ra".
	cat > "$PAKD/launch.real.sh" <<'REAL'
#!/bin/sh
# fake upstream launcher: RABIN=/mnt/vendor/bin/retroarch (family sniff target)
exit 0
REAL
	chmod +x "$PAKD/launch.real.sh"

	# fake romm-session-sync — logs phase calls (the push assert).
	cat > "$TOOLS/bin/romm-session-sync" <<EOF
#!/bin/sh
echo "session-sync \$*" >> "$TRACE"
exit 0
EOF
	chmod +x "$TOOLS/bin/romm-session-sync"

	# fake lodor-sync — logs argv; --recv probe answers per \$FAKE_RA_MODE
	# (responsive|silent); QUIT "kills" the fake RA by removing its pidfile.
	cat > "$TOOLS/lodor-sync" <<EOF
#!/bin/sh
echo "lodor-sync \$*" >> "$TRACE"
case "\$*" in
	*--ra-cmd*GET_STATUS*--recv*|*--ra-cmd*GET_STATUS*-recv*)
		[ "\${FAKE_RA_MODE:-silent}" = "responsive" ] && exit 0 || exit 3 ;;
	*--ra-cmd*SCREENSHOT*)
		mkdir -p /tmp/lodor-shots-N64 2>/dev/null
		echo fakepng > "/tmp/lodor-shots-N64/shot-\$\$.png"; exit 0 ;;
	*--ra-cmd*QUIT*)
		rm -f "$RA_PIDFILE"; exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TOOLS/lodor-sync"

	# PATH-shadowed fake pgrep: "retroarch alive" == pidfile exists.
	mkdir -p "$SANDBOX/bin$1"
	cat > "$SANDBOX/bin$1/pgrep" <<EOF
#!/bin/sh
[ -e "$RA_PIDFILE" ]
EOF
	chmod +x "$SANDBOX/bin$1/pgrep"
	FAKEBIN="$SANDBOX/bin$1"
}

run_wrapper() {
	# $1 = FAKE_RA_MODE
	FAKE_RA_MODE="$1" PATH="$FAKEBIN:$PATH" \
	SDCARD_PATH="$SD" PLATFORM="h700" SAVES_PATH="$SD/Saves" USERDATA_PATH="$SD/.userdata/h700" \
		sh "$PAKD/launch.sh" "$SD/Roms/Nintendo 64 (N64)/Game (USA).z64" >/dev/null 2>&1
}

# ─── 2. RA BRACKET TRACE ──────────────────────────────────────────────────────────
say "[2/5] ra bracket trace"

# case A: responsive RA alive at exit -> probe, QUIT, push still runs
build_sandbox A
: > "$RA_PIDFILE"
run_wrapper responsive
grep -q 'lodor-sync --ra-cmd GET_STATUS --recv' "$TRACE" && pass "A: GET_STATUS probe sent" || fail "A: no probe in trace"
grep -q 'lodor-sync --ra-cmd QUIT' "$TRACE" && pass "A: QUIT sent after responsive probe" || fail "A: no QUIT in trace"
[ -e "$RA_PIDFILE" ] && fail "A: RA not quit" || pass "A: RA exited on QUIT"
grep -q 'session-sync push' "$TRACE" && pass "A: push ran (HARD RULE)" || fail "A: push missing"
grep -q 'lodor-sync --session-start' "$TRACE" && pass "A: playtime session staged" || fail "A: session-start missing"
awk '/--session-end/{if(!e)e=NR} /session-sync push/{if(!p)p=NR} END{exit !(e&&p&&e<p)}' "$TRACE" \
	&& pass "A: session-end ordered before push" || fail "A: session-end/push order wrong"
[ "$(grep -c -- '--session-end' "$TRACE")" = "1" ] && pass "A: session-end fired once" || fail "A: session-end fired more than once"
awk '/--ra-cmd QUIT/{q=NR} /session-sync push/{p=NR} END{exit !(q&&p&&q<p)}' "$TRACE" \
	&& pass "A: QUIT ordered before push" || fail "A: QUIT/push order wrong"
[ -f "$SD/.userdata/h700/.lodor-ra-net-unsupported" ] && fail "A: stamp written for a responsive RA" || pass "A: no UNSUPPORTED stamp"
awk '/--ra-cmd SCREENSHOT/{if(!s)s=NR} /--ra-cmd QUIT/{if(!q)q=NR} END{exit !(s&&q&&s<q)}' "$TRACE" \
	&& pass "A: SCREENSHOT sent before QUIT (#149)" || fail "A: SCREENSHOT/QUIT order wrong"
[ -f "$SD/.userdata/shared/.minui/N64/Game (USA).z64.auto.png" ] \
	&& pass "A: preview landed at .minui convention (#149)" || fail "A: preview not collected"
[ -n "$(ls /tmp/lodor-shots-N64/*.png 2>/dev/null)" ] && fail "A: shot dir not cleaned" || pass "A: shot dir cleaned"

# case B: silent RA (vendor build without network_cmd) -> probe once, stamp, degrade, push still runs
build_sandbox B
: > "$RA_PIDFILE"
run_wrapper silent
grep -q 'lodor-sync --ra-cmd GET_STATUS --recv' "$TRACE" && pass "B: probe attempted" || fail "B: no probe"
grep -q 'lodor-sync --ra-cmd QUIT' "$TRACE" && fail "B: QUIT sent to a silent RA" || pass "B: no QUIT after silent probe"
[ -f "$SD/.userdata/h700/.lodor-ra-net-unsupported" ] && pass "B: UNSUPPORTED stamp written" || fail "B: stamp missing"
grep -q 'ra-net UNSUPPORTED' "$TOOLS/session.log" && pass "B: UNSUPPORTED logged" || fail "B: UNSUPPORTED log line missing"
grep -q 'session-sync push' "$TRACE" && pass "B: push ran (HARD RULE)" || fail "B: push missing"
# second run with the stamp present: NEVER probed again
: > "$RA_PIDFILE"
: > "$TRACE"
run_wrapper silent
grep -q 'ra-cmd GET_STATUS' "$TRACE" && fail "B2: probed again despite stamp" || pass "B2: stamp suppresses re-probe"
grep -q 'session-sync push' "$TRACE" && pass "B2: push still runs (degraded)" || fail "B2: push missing"

# case C: RA already dead at exit (the normal clean-quit path) -> no probe, push runs
build_sandbox C
rm -f "$RA_PIDFILE"
run_wrapper responsive
grep -q 'ra-cmd GET_STATUS' "$TRACE" && fail "C: probed a dead RA" || pass "C: no probe when RA already exited"
grep -q 'session-sync push' "$TRACE" && pass "C: push ran" || fail "C: push missing"

# case D (#153): LODOR_ROM_TAG override — the launcher's exported folder tag must key
# SYSTAG (save dir + #149 preview), beating BOTH the rom-dirname derivation and the pak
# name (the variant-pak-launches-a-heavy path). Env deliberately disagrees with both
# ("FC" vs dirname "(N64)" / pak "N64") so precedence is unambiguous. The env-less
# fallback is already proven by case A's .minui/N64 preview assert.
build_sandbox D
: > "$RA_PIDFILE"
FAKE_RA_MODE=responsive PATH="$FAKEBIN:$PATH" LODOR_ROM_TAG="FC" \
SDCARD_PATH="$SD" PLATFORM="h700" SAVES_PATH="$SD/Saves" USERDATA_PATH="$SD/.userdata/h700" \
	sh "$PAKD/launch.sh" "$SD/Roms/Nintendo 64 (N64)/Game (USA).z64" >/dev/null 2>&1
grep -qF "systag=FC savedir=$SD/Saves/FC" "$TOOLS/session.log" \
	&& pass "D: SYSTAG keyed by LODOR_ROM_TAG (#153)" || fail "D: systag/savedir ignore LODOR_ROM_TAG"
[ -d "$SD/Saves/FC" ] && pass "D: save dir created under override tag" || fail "D: Saves/FC missing"
[ -f "$SD/.userdata/shared/.minui/FC/Game (USA).z64.auto.png" ] \
	&& pass "D: preview keyed by LODOR_ROM_TAG (#149/#153)" || fail "D: preview not under .minui/FC"
grep -q 'session-sync push' "$TRACE" && pass "D: push ran (HARD RULE)" || fail "D: push missing"

# ─── 3. BOOT RESTORE (three cases) ────────────────────────────────────────────────
say "[3/5] boot-restore cases"
# Extract the forward-only restore block from a family boot.sh and run it against a
# fake SDCARD + a PATH-shadowed fake `date`/`hwclock` so the host clock is never touched.
BOOTSH="$LODOROS/workspace/miyoomini/install/boot.sh"
if ! grep -q 'LODOR CLOCK RESTORE' "$BOOTSH" 2>/dev/null; then
	say "  skip: boot.sh has no restore block yet (pre-#147 tree)"
else
	restore_case() {
		# $1 = case name, $2 = stored datetime ('' = missing), $3 = fake now, $4 = want date -s (1/0)
		CSD="$SANDBOX/clock-$1"
		mkdir -p "$CSD/.userdata/shared" "$SANDBOX/cbin-$1"
		[ -n "$2" ] && printf '%s\n' "$2" > "$CSD/.userdata/shared/datetime.txt"
		CTRACE="$CSD/trace.log"
		cat > "$SANDBOX/cbin-$1/date" <<EOF
#!/bin/sh
case "\$1" in
	-s) echo "date -s \$2" >> "$CTRACE"; exit 0 ;;
esac
# render fake "now" for +FMT asks
case "\$*" in
	*+%s*) echo "SHOULD-NOT-BE-USED"; exit 1 ;;
	*) echo "$3" ;;
esac
exit 0
EOF
		chmod +x "$SANDBOX/cbin-$1/date"
		cat > "$SANDBOX/cbin-$1/hwclock" <<EOF
#!/bin/sh
echo "hwclock \$*" >> "$CTRACE"
exit 0
EOF
		chmod +x "$SANDBOX/cbin-$1/hwclock"
		# run ONLY the restore block, extracted verbatim from the shipped boot.sh
		sed -n '/# --- LODOR CLOCK RESTORE/,/# --- END LODOR CLOCK RESTORE/p' "$BOOTSH" > "$CSD/block.sh"
		( PATH="$SANDBOX/cbin-$1:$PATH" SDCARD_PATH="$CSD" sh -c "SDCARD_PATH=\"$CSD\"; . \"$CSD/block.sh\"" ) >/dev/null 2>&1
		if [ "$4" = 1 ]; then
			grep -q '^date -s' "$CTRACE" 2>/dev/null && pass "clock $1: restored forward" || fail "clock $1: no date -s"
		else
			grep -q '^date -s' "$CTRACE" 2>/dev/null && fail "clock $1: moved the clock (must not)" || pass "clock $1: untouched"
		fi
	}
	restore_case newer   "2099-01-02 03:04:05" "2026-07-03 10:00:00" 1
	restore_case older   "2020-01-02 03:04:05" "2026-07-03 10:00:00" 0
	restore_case missing ""                    "2026-07-03 10:00:00" 0
fi

# --- 4. MULTI-DISC LAUNCH TRACE (lodor#7 disc-1-first + the FFVII black-screen gate) ---
# The engine downloads multi-disc games DISC-1-FIRST: a populated .m3u with 0-byte
# later discs is a VALID state. The shim must (a) re-trigger the fetch for that state
# via --fetch-next-disc (a populated .m3u is not a 0-byte stub, so the stub gate can't),
# (b) gate the launch on the FIRST disc only (pcsx boots disc 1; stub later discs are
# the design), and (c) still never hand pcsx a missing disc 1 (the black-screen fix).
# Fake romm-run implements the engine's disc-1-first semantics: --download on a 0-byte
# .m3u stub writes the FULL playlist + disc 1 only; --fetch-next-disc materializes the
# first missing disc (per $MD_DL_MODE succeed/fail).
#   M1 real .m3u + all discs present    -> NO engine call, emulator launched directly.
#   M2 real .m3u + all discs MISSING    -> --fetch-next-disc lands disc 1, launch (discs
#                                          2/3 still stubs — first-disc gate only).
#   M2b disc-1 PATH launch, disc 2/3 missing -> sibling .m3u resolved, --fetch-next-disc
#                                          fired, launch proceeds.
#   M3 all discs missing + fetch FAILS  -> NO launch (honest exit, never a black screen).
#   M4 disc 1 present + fetch FAILS     -> LAUNCH anyway (never gate harder than disc 1).
#   M5 0-byte .m3u stub                 -> --download (disc-1-first fill), NO same-launch
#                                          --fetch-next-disc (one disc per launch), launch.
say "[4/5] multi-disc launch trace (disc-1-first)"

SHIM="$LODOROS/paks/Lodor.pak/bin/minarch-shim.sh"

build_md_sandbox() {
	MDSD="$SANDBOX/md$1"
	MDPAK="$MDSD/Tools/miyoomini/Lodor.pak"
	MDSYS="$MDSD/.system/miyoomini/bin"
	MDROM="$MDSD/Roms/PlayStation (PS)"
	MDGAME="$MDROM/Final Fantasy VII (USA)"
	MDTRACE="$MDSD/md-trace.log"
	mkdir -p "$MDPAK/bin" "$MDSYS" "$MDGAME" "$MDSD/Saves"
	: > "$MDTRACE"

	# the .m3u playlist (a REAL 183-ish-byte file, exactly the field-repro shape)
	cat > "$MDROM/Final Fantasy VII (USA).m3u" <<'M3U'
Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 1).chd
Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 2).chd
Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 3).chd
M3U

	# fake real emulator: logs "LAUNCHED <rom>" so we can assert it ran (or didn't).
	cat > "$MDSYS/minarch.real.elf" <<EOF
#!/bin/sh
echo "LAUNCHED \$2" >> "$MDTRACE"
exit 0
EOF
	chmod +x "$MDSYS/minarch.real.elf"

	# fake romm-run: logs every call; implements the engine's DISC-1-FIRST semantics per
	# \$MD_DL_MODE (succeed/fail): --download on the .m3u stub writes the FULL playlist +
	# disc 1 only; --fetch-next-disc materializes the FIRST missing disc.
	cat > "$MDPAK/bin/romm-run" <<EOF
#!/bin/sh
echo "romm-run \$*" >> "$MDTRACE"
[ "\${MD_DL_MODE:-fail}" = "succeed" ] || exit 4
case "\$1" in
	--download)
		printf '%s\n%s\n%s\n' \
			"Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 1).chd" \
			"Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 2).chd" \
			"Final Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 3).chd" \
			> "$MDROM/Final Fantasy VII (USA).m3u"
		echo chd-bytes > "$MDGAME/Final Fantasy VII (USA) (Disc 1).chd"
		for d in 2 3; do : > "$MDGAME/Final Fantasy VII (USA) (Disc \$d).chd"; done
		;;
	--fetch-next-disc)
		for d in 1 2 3; do
			_dp="$MDGAME/Final Fantasy VII (USA) (Disc \$d).chd"
			if [ ! -s "\$_dp" ]; then echo chd-bytes > "\$_dp"; break; fi
		done
		;;
esac
exit 0
EOF
	chmod +x "$MDPAK/bin/romm-run"
}

# run the shim with a given ROM arg (the .m3u, or a disc path)
run_shim() {
	# $1 = MD_DL_MODE, $2 = rom path
	MD_DL_MODE="$1" SDCARD_PATH="$MDSD" PLATFORM="miyoomini" \
		sh "$SHIM" "core.so" "$2" >/dev/null 2>&1
}

# M1: all discs present -> direct launch, no engine call at all.
build_md_sandbox 1
for d in 1 2 3; do echo chd-bytes > "$MDGAME/Final Fantasy VII (USA) (Disc $d).chd"; done
run_shim succeed "$MDROM/Final Fantasy VII (USA).m3u"
grep -q 'romm-run --' "$MDTRACE" && fail "M1: engine called for a complete game" || pass "M1: no engine call when all discs present"
grep -q '^LAUNCHED ' "$MDTRACE" && pass "M1: emulator launched directly" || fail "M1: emulator not launched"

# M2: real .m3u, all discs missing, fetch SUCCEEDS -> --fetch-next-disc lands disc 1,
# launch proceeds with discs 2/3 still absent (the first-disc gate).
build_md_sandbox 2
run_shim succeed "$MDROM/Final Fantasy VII (USA).m3u"
grep -q 'romm-run --fetch-next-disc' "$MDTRACE" && pass "M2: next-disc fetch triggered for incomplete set" || fail "M2: no next-disc fetch for incomplete set"
grep -q '^LAUNCHED ' "$MDTRACE" && pass "M2: emulator launched with disc 1 present" || fail "M2: emulator not launched after disc 1 landed"
[ -s "$MDGAME/Final Fantasy VII (USA) (Disc 2).chd" ] && fail "M2: disc 2 fetched same-launch (should be one disc per launch)" || pass "M2: later discs untouched (disc-1-first)"

# M2b: minui passed disc 1's PATH (disc 1 present) but disc 2/3 missing -> the shim
# resolves the sibling .m3u and fetches the next missing disc before launch.
build_md_sandbox 2b
echo chd-bytes > "$MDGAME/Final Fantasy VII (USA) (Disc 1).chd"
run_shim succeed "$MDGAME/Final Fantasy VII (USA) (Disc 1).chd"
grep -q 'romm-run --fetch-next-disc' "$MDTRACE" && pass "M2b: partial set (disc-path launch) triggers next-disc fetch" || fail "M2b: no fetch when launched via a disc path"
grep -q '^LAUNCHED ' "$MDTRACE" && pass "M2b: emulator launched" || fail "M2b: emulator not launched"

# M3: all discs missing, fetch FAILS -> NO launch (disc 1 absent = black screen; honest exit).
build_md_sandbox 3
run_shim fail "$MDROM/Final Fantasy VII (USA).m3u"
grep -q 'romm-run --fetch-next-disc' "$MDTRACE" && pass "M3: fetch attempted" || fail "M3: no fetch attempt"
grep -q '^LAUNCHED ' "$MDTRACE" && fail "M3: emulator launched with disc 1 missing (BLACK SCREEN)" || pass "M3: emulator NOT launched when disc 1 stayed missing"

# M4 (lodor#7 never-gate-harder): disc 1 present, discs 2/3 missing, fetch FAILS ->
# the game still launches on the discs it has.
build_md_sandbox 4
echo chd-bytes > "$MDGAME/Final Fantasy VII (USA) (Disc 1).chd"
run_shim fail "$MDROM/Final Fantasy VII (USA).m3u"
grep -q 'romm-run --fetch-next-disc' "$MDTRACE" && pass "M4: fetch attempted for the missing discs" || fail "M4: no fetch attempt"
grep -q '^LAUNCHED ' "$MDTRACE" && pass "M4: emulator launched despite failed later-disc fetch" || fail "M4: launch wrongly gated on later discs"

# M5 (disc-1-first fresh launch): 0-byte .m3u stub -> --download fills disc 1 + full
# playlist; NO --fetch-next-disc in the same launch (one disc per launch); launch runs.
build_md_sandbox 5
: > "$MDROM/Final Fantasy VII (USA).m3u"
run_shim succeed "$MDROM/Final Fantasy VII (USA).m3u"
grep -q 'romm-run --download' "$MDTRACE" && pass "M5: stub fill via --download" || fail "M5: no --download for the 0-byte stub"
grep -q 'romm-run --fetch-next-disc' "$MDTRACE" && fail "M5: same-launch next-disc fetch after the stub fill (two discs one launch)" || pass "M5: no same-launch second fetch (one disc per launch)"
grep -q '^LAUNCHED ' "$MDTRACE" && pass "M5: emulator launched on disc 1" || fail "M5: emulator not launched after stub fill"

# M6 (CRLF + comments): a Windows-authored .m3u (CRLF line endings, #EXTM3U header,
# a # comment line) with ALL discs present must parse clean: no engine call, direct
# launch — exactly M1. Before the CR-strip fix every line failed the [ -s ] check
# (trailing \r in the path) so complete games silently never launched.
build_md_sandbox 6
printf '#EXTM3U\r\n# burned on Windows\r\nFinal Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 1).chd\r\nFinal Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 2).chd\r\nFinal Fantasy VII (USA)/Final Fantasy VII (USA) (Disc 3).chd\r\n' \
	> "$MDROM/Final Fantasy VII (USA).m3u"
for d in 1 2 3; do echo chd-bytes > "$MDGAME/Final Fantasy VII (USA) (Disc $d).chd"; done
run_shim succeed "$MDROM/Final Fantasy VII (USA).m3u"
grep -q 'romm-run --' "$MDTRACE" && fail "M6: engine called for a complete CRLF playlist" || pass "M6: no engine call for complete CRLF+comment m3u"
grep -q '^LAUNCHED ' "$MDTRACE" && pass "M6: emulator launched directly (CRLF+comment m3u)" || fail "M6: complete CRLF m3u did not launch"

# --- 5. POST-GAME SAVE DETECTION — [BRACKET] ROM regression (#162) ------------------
# The post-game save block globs the save tree with the ROM basename. No-Intro names carry
# glob metacharacters ([S] [!] [b] [h] [T-En]); the old `-iname "$rom.*"` catch-all fed those
# to find's fnmatch, so a bracketed ROM's just-written save was NEVER matched and the push/
# queue was silently skipped -> the save never reached RomM. This drives the REAL shim end to
# end (fake real-emulator, no HELPER so the offline QUEUE branch is taken) and asserts the ROM
# is enqueued to pending-saves.txt when a matching save exists on the card. A non-bracket ROM
# is the harness control; three bracket flavors are the regression guard.
say "[5/5] post-game save detection ([brackets] #162)"

SVSD="$SANDBOX/save"
SVSYS="$SVSD/.system/miyoomini/bin"
SVROM="$SVSD/Roms/Game Boy Color (GBC)"
SVSAVES="$SVSD/Saves/GBC"
SVPEND="$SVSD/Tools/miyoomini/Lodor.pak/pending-saves.txt"
mkdir -p "$SVSYS" "$SVROM" "$SVSAVES" "$(dirname "$SVPEND")"
# fake real emulator: exists+exec so the shim's launch line runs (rc 0), writes nothing.
cat > "$SVSYS/minarch.real.elf" <<'ELF'
#!/bin/sh
exit 0
ELF
chmod +x "$SVSYS/minarch.real.elf"
# NB: no romm-session-sync HELPER is installed -> the save block takes the offline queue branch
# (append ROM to pending-saves.txt), the exact branch the bracket bug silently skipped.

# assert_saved <label> <rom-basename-no-ext> <save-filename> <want-queued 1|0>
assert_saved() {
	_lbl="$1"; _stem="$2"; _savefile="$3"; _want="$4"
	rm -f "$SVSAVES"/* "$SVPEND" 2>/dev/null
	: > "$SVSAVES/$_savefile"                 # the just-written save on the card
	_rompath="$SVROM/$_stem.gbc"
	: > "$_rompath"                            # non-empty-enough ROM (skips the 0-byte stub path)
	echo x > "$_rompath"
	SDCARD_PATH="$SVSD" PLATFORM="miyoomini" \
		sh "$SHIM" "core.so" "$_rompath" >/dev/null 2>&1
	if grep -qxF "$_rompath" "$SVPEND" 2>/dev/null; then _got=1; else _got=0; fi
	if [ "$_got" = "$_want" ]; then
		[ "$_want" = 1 ] && pass "$_lbl: save detected -> queued" || pass "$_lbl: correctly not queued"
	else
		[ "$_want" = 1 ] && fail "$_lbl: save NOT detected (bracket glob bug)" || fail "$_lbl: unexpected queue"
	fi
}

# control: plain name, RetroArch-style <stem>.srm  -> must queue (proves the harness)
assert_saved "S0 plain"        "Game (USA)"            "Game (USA).srm"            1
# regression guards: bracketed No-Intro names, both save-naming styles
assert_saved "S1 [S] srm"      "Game (USA) [S]"        "Game (USA) [S].srm"        1
assert_saved "S2 [!] minarch"  "Zelda (USA) [!]"       "Zelda (USA) [!].gbc.sav"   1
assert_saved "S3 [T-En][b]"    "Metroid (U) [T-En][b]" "Metroid (U) [T-En][b].srm" 1
# negative: a save for a DIFFERENT rom must not queue this rom (no false-positive glob widening)
rm -f "$SVSAVES"/* "$SVPEND" 2>/dev/null
: > "$SVSAVES/Totally Different Game.srm"
_rp="$SVROM/Game (USA) [S].gbc"; echo x > "$_rp"
SDCARD_PATH="$SVSD" PLATFORM="miyoomini" sh "$SHIM" "core.so" "$_rp" >/dev/null 2>&1
grep -qxF "$_rp" "$SVPEND" 2>/dev/null && fail "S4: unrelated save falsely queued [S] rom" || pass "S4: unrelated save not matched"

# --- 6. BIOS LAUNCH-GATE TRACE (build #158) ----------------------------------------
# The heavy-pak wrapper (emus-h700 DC/PSP launch.sh) must, BEFORE running the real
# emulator, run the engine BIOS check and — when a required BIOS is MISSING — show an
# honest message and exit CLEAN, never handing a BIOS-less rom to the emulator (the
# silent black screen that motivated #158). Drives the REAL DC.pak wrapper with a fake
# lodor-sync whose --check-bios verdict is env-controlled, a fake say.elf, and a fake
# launch.real.sh that logs when it runs. Asserts: missing -> NO real launch, message
# shown, "BIOS GATE" logged; present -> real launch proceeds. Fail-open (empty verdict)
# -> launch proceeds, proving the gate never becomes a new way to block a playable game.
say "[6/6] bios launch-gate trace (build #158)"

build_bios_sandbox() {
	BSD="$SANDBOX/bios$1"
	BPAK="$BSD/Emus/h700/DC.pak"
	BTOOLS="$BSD/Tools/h700/Lodor.pak"
	BSYS="$BSD/.system/h700/bin"
	BTRACE="$BSD/trace.log"
	mkdir -p "$BPAK" "$BTOOLS/bin" "$BSYS" "$BSD/.userdata/h700" "$BSD/Roms/Sega Dreamcast (DC)" "$BSD/Saves/DC"
	cp "$LODOROS/emus-h700/DC.pak/launch.sh" "$BPAK/launch.sh"
	chmod +x "$BPAK/launch.sh"

	# fake real launcher: mentions retroarch (family=ra) and LOGS that it ran.
	cat > "$BPAK/launch.real.sh" <<EOF
#!/bin/sh
# retroarch stand-in
echo "REAL-LAUNCHED \$1" >> "$BTRACE"
exit 0
EOF
	chmod +x "$BPAK/launch.real.sh"

	# fake engine: --check-bios prints the env-selected verdict; everything else no-ops.
	cat > "$BTOOLS/lodor-sync" <<EOF
#!/bin/sh
case "\$1" in
	--check-bios)
		case "\${FAKE_BIOS:-ok}" in
			missing) echo "RESULT bios_ok=0 missing=dc_boot.bin,dc_flash.bin system=Dreamcast" ;;
			empty)   : ;;   # unparseable/no output -> fail-open
			*)       echo "RESULT bios_ok=1" ;;
		esac
		;;
esac
exit 0
EOF
	chmod +x "$BTOOLS/lodor-sync"

	# fake save helper (pull/push) — logs so we can assert push does NOT run on a block.
	cat > "$BTOOLS/bin/romm-session-sync" <<EOF
#!/bin/sh
echo "session-sync \$*" >> "$BTRACE"
exit 0
EOF
	chmod +x "$BTOOLS/bin/romm-session-sync"

	# fake say.elf — records the honest message the user would see.
	cat > "$BSYS/say.elf" <<EOF
#!/bin/sh
echo "SAY \$1" >> "$BTRACE"
exit 0
EOF
	chmod +x "$BSYS/say.elf"

	mkdir -p "$SANDBOX/bbin$1"
	cat > "$SANDBOX/bbin$1/pgrep" <<'EOF'
#!/bin/sh
exit 1
EOF
	chmod +x "$SANDBOX/bbin$1/pgrep"
	BFAKEBIN="$SANDBOX/bbin$1"
}

run_bios_wrapper() {
	# $1 = FAKE_BIOS mode
	FAKE_BIOS="$1" PATH="$BFAKEBIN:$PATH" \
	SDCARD_PATH="$BSD" PLATFORM="h700" SAVES_PATH="$BSD/Saves" USERDATA_PATH="$BSD/.userdata/h700" \
		sh "$BPAK/launch.sh" "$BSD/Roms/Sega Dreamcast (DC)/Game (USA).chd" >/dev/null 2>&1
}

# G1: BIOS MISSING -> gate blocks; real emulator NEVER runs; message shown; push never ran.
build_bios_sandbox 1
run_bios_wrapper missing
grep -q '^REAL-LAUNCHED ' "$BTRACE" && fail "G1: emulator launched despite missing BIOS (BLACK SCREEN)" || pass "G1: real emulator NOT launched (gate held)"
grep -q '^SAY .*needs BIOS' "$BTRACE" && pass "G1: honest 'needs BIOS' message shown" || fail "G1: no on-screen message"
grep -q 'Download BIOS' "$BTRACE" && pass "G1: message points at Sync > Download BIOS" || fail "G1: message missing the fix"
grep -q 'BIOS GATE' "$BTOOLS/session.log" 2>/dev/null && pass "G1: BIOS GATE logged" || fail "G1: gate not logged"
grep -q 'session-sync push' "$BTRACE" && fail "G1: push ran after a blocked launch" || pass "G1: no save push on a blocked launch"

# G2: BIOS PRESENT -> gate is a no-op; the real emulator launches normally.
build_bios_sandbox 2
run_bios_wrapper ok
grep -q '^REAL-LAUNCHED ' "$BTRACE" && pass "G2: real emulator launched when BIOS present" || fail "G2: emulator not launched with BIOS present"
grep -q '^SAY ' "$BTRACE" && fail "G2: message shown when BIOS present (false gate)" || pass "G2: no message when BIOS present"

# G3: FAIL-OPEN — an unparseable/empty verdict must launch exactly as before.
build_bios_sandbox 3
run_bios_wrapper empty
grep -q '^REAL-LAUNCHED ' "$BTRACE" && pass "G3: fail-open — launch proceeds on empty verdict" || fail "G3: gate blocked on an empty verdict (must fail open)"

say ""
if [ "$FAILS" -gt 0 ]; then
	say "wrapper-check: $FAILS FAILURE(S)"
	exit 1
fi
say "wrapper-check: all green"
exit 0
