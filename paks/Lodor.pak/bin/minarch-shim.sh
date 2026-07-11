#!/bin/sh
# minarch.elf — RomM session-sync shim.   MARKER: ROMM_MINARCH_SHIM
#
# Installed in place of the stock minarch.elf (renamed to minarch.real.elf by install.sh). Every game
# launches through `minarch.elf "<core.so>" "<rom path>"`, so this wraps every game: pull the ROM's
# save before play (best-effort, bounded), launch the real emulator, push the save after.
#
# HARD RULE: the game launch is NEVER conditional on sync. Every sync call is best-effort and guarded;
# if anything about sync is missing or fails, the real emulator still runs. A broken shim here bricks
# every game, so the launch line is the load-bearing part and everything else is second-class.

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-miyoomini}"
REAL="$SDCARD/.system/$PLAT/bin/minarch.real.elf"   # absolute: $0/dirname is unreliable via PATH
HELPER="$SDCARD/Tools/$PLAT/Lodor.pak/bin/romm-session-sync"
ROM="$2"                                            # minarch.elf "<core.so>" "<rom path>"
INGAME_LOCK="/tmp/romm-in-game"

# Mark a game session so the daemon won't bring WiFi up mid-play (PID-based; daemon reaps if killed).
echo "$$" > "$INGAME_LOCK" 2>/dev/null
# FIX 3 (#99): the launch bracket also touches /tmp/lodor-game-active for the duration of play.
# The background cover-fetch worker (lodor-sync --bg-cover-fetch / lodor-bg-covers daemon) stats
# this marker between units and PAUSES (releasing the WiFi mutex) while a game runs, so cover
# warming never competes with the game for the radio. Removed on return alongside the in-game lock.
GAME_ACTIVE="/tmp/lodor-game-active"
true > "$GAME_ACTIVE" 2>/dev/null
trap 'rm -f "$INGAME_LOCK" "$GAME_ACTIVE" 2>/dev/null' EXIT INT TERM HUP QUIT

# Download-on-launch FALLBACK: if the ROM is a 0-byte STUB (a catalog entry for a game not yet on the
# card) and it slipped past the launcher's native "Downloading…" overlay (the normal menu path now
# downloads stubs in minui.c BEFORE launching), fetch the real file here. romm-run owns the WiFi shell
# lock (one process acquires + releases), runs the headless --download (fetch + sha verify, leaves the
# radio warm for the save pull below). No grout32 / gabagool — this runs post-exit with no UI, so it's
# silent by design (the on-screen flow lives in the launcher). If the download fails, do NOT launch an
# empty ROM — clear the lock and exit to menu.
#
# MULTI-DISC (task #49/#74; DISC-1-FIRST per lodor#7): a multi-disc game launches as its
# .m3u playlist, OR — when minui's getFirstDisc found disc 1 on the card — as a disc file
# inside "<Game>/". The engine now downloads DISC-1-FIRST: a --download on the .m3u stub
# fetches only the first missing disc, writes the FULL .m3u, and leaves later discs as
# 0-byte stubs. So a REAL .m3u with missing/0-byte discs is a VALID state, not corruption:
# each launch fetches the NEXT missing disc (--fetch-next-disc, idempotent, skips verified
# discs) and the daemon prefetch completes the set in the background. The launch gate is
# the FIRST disc only — that's what pcsx boots; handing it a missing disc 1 is a black
# screen (Could't open '…Disc 1.chd'), while stub LATER discs are the designed shape
# (swap = exit → relaunch until the set completes). On a still-missing disc 1, exit to
# menu — never a black screen, never a harder gate than the game actually needs.

# Resolve the playlist path for the passed ROM: the .m3u itself, or the sibling
# "<Game>.m3u" beside the ".<Game>/" folder a disc file lives in — the per-game disc
# folder is DOT-HIDDEN (lodor#7 UX fix). Legacy non-dot folders and already-dot game
# names both still map: try the folder name raw, then dot-stripped. Empty = not
# multi-disc.
_lodor_m3u_for() {
	case "$1" in
		*.m3u) printf '%s' "$1"; return 0 ;;
	esac
	# $1 = <sys>/.<Game>/<disc>.chd  ->  <sys>/<Game>.m3u
	_gd=$(dirname "$1"); _pd=$(dirname "$_gd"); _gn=$(basename "$_gd")
	_cand="$_pd/$_gn.m3u"
	[ -f "$_cand" ] || _cand="$_pd/${_gn#.}.m3u"
	[ -f "$_cand" ] && printf '%s' "$_cand"
}

# Return 0 (true) if the engine's OFFLINE completeness gate says this ROM's disc set is
# incomplete (RESULT complete=0). The .m3u is LOCAL-ONLY now — it lists just the discs
# with real bytes, because minui refuses to launch past a listed stub — so scanning its
# refs would ALWAYS read "complete"; the full canonical set lives in the mirror manifest
# and only `lodor-sync --check-rom` (filesystem + manifest, no config/network/radio) can
# answer. Same env/cd shape as the BIOS gate below. FAIL-OPEN: no binary / unparseable
# output -> 1 ("complete") -> no fetch, the launch proceeds exactly as before.
_lodor_rom_incomplete() {
	_ckbin="$SDCARD/Tools/$PLAT/Lodor.pak/lodor-sync"
	[ -x "$_ckbin" ] || return 1
	_ckout=$( cd "$SDCARD/Tools/$PLAT/Lodor.pak" 2>/dev/null && \
		SDCARD_PATH="$SDCARD" PLATFORM="$PLAT" BASE_PATH="$SDCARD" CFW=MinUI \
		./lodor-sync --check-rom "$1" 2>/dev/null )
	case "$_ckout" in *"complete=0"*) return 0 ;; esac
	return 1
}

# Return 0 (true) if the .m3u's FIRST listed disc is missing or 0-byte (the launch gate:
# disc 1 is what the emulator boots; stub later discs are fine). An entry-less playlist
# is broken -> also "first missing" (honest no-launch, same as before lodor#7).
_lodor_m3u_first_missing() {
	_m="$1"; [ -f "$_m" ] || return 0
	_dir=$(dirname "$_m"); _CR=$(printf '\r')
	while IFS= read -r _line || [ -n "$_line" ]; do
		_line=${_line%"$_CR"}
		[ -n "$_line" ] || continue
		case "$_line" in \#*) continue ;; esac
		case "$_line" in
			/*) _dp="$_line" ;;
			*)  _dp="$_dir/$_line" ;;
		esac
		[ -s "$_dp" ] && return 1    # first listed disc present -> launchable
		return 0
	done < "$_m"
	return 0                          # no entries -> broken -> treat as missing
}

ROMM_RUN="$SDCARD/Tools/$PLAT/Lodor.pak/bin/romm-run"
_LODOR_STUB_FILLED=0
if [ -f "$ROM" ] && [ ! -s "$ROM" ]; then
	# 0-byte single-file cloud stub (or a 0-byte .m3u stub) — fill it in place. For a
	# multi-disc game this lands DISC 1 ONLY + the full .m3u (disc-1-first, lodor#7).
	[ -x "$ROMM_RUN" ] && "$ROMM_RUN" --download "$ROM" >/dev/null 2>&1
	if [ ! -s "$ROM" ]; then
		rm -f "$INGAME_LOCK" 2>/dev/null
		exit 0   # download failed/declined — nothing to launch
	fi
	_LODOR_STUB_FILLED=1
fi
# Real .m3u (or a disc beside one) with an incomplete disc set — fetch the NEXT missing
# disc before launching (the re-trigger the 0-byte-stub gate can't provide: a populated
# .m3u isn't a stub, so without this discs 2+ would strand forever). Detection is the
# engine's --check-rom (manifest census — the local-only playlist can't answer this).
# Skipped right after a stub fill (disc 1 just landed this launch — one disc per launch,
# that's the design; the daemon prefetch completes the rest in the background).
_LODOR_M3U=$(_lodor_m3u_for "$ROM")
if [ -n "$_LODOR_M3U" ] && [ -s "$_LODOR_M3U" ] && [ "$_LODOR_STUB_FILLED" != 1 ] && _lodor_rom_incomplete "$_LODOR_M3U"; then
	[ -x "$ROMM_RUN" ] && "$ROMM_RUN" --fetch-next-disc "$_LODOR_M3U" >/dev/null 2>&1
fi
# LAUNCH GATE — FIRST DISC ONLY (never harder than the game needs): if disc 1 is present
# the game launches even when a later fetch failed (stub discs are the designed disc-1-
# first shape); if disc 1 itself is still missing/0-byte, exit to menu honestly — never
# hand pcsx a black screen.
if [ -n "$_LODOR_M3U" ] && [ -s "$_LODOR_M3U" ] && _lodor_m3u_first_missing "$_LODOR_M3U"; then
	rm -f "$INGAME_LOCK" 2>/dev/null
	exit 0   # disc 1 still missing — do NOT launch a black screen
fi

# ── BIOS launch-gate (build #158) ─────────────────────────────────────────────────────────────
# minarch cores read BIOS from system_directory = Bios/<TAG> (minarch.c). Before handing the rom to
# minarch, ask the engine whether this system requires a BIOS the user must supply and whether it is
# present; if missing, show an HONEST message naming the file + the fix (Sync > Download BIOS) and
# return to the menu (exit 0) instead of the silent black screen a BIOS-less core boots into. HARD
# RULE: fail-OPEN — any check failure (no engine, no rom, unparseable output) launches exactly as
# before. Systems with no BIOS need (pcsx_rearmed PS1 HLE, etc.) report bios_ok=1 and never gate.
_LODOR_SYNC="$SDCARD/Tools/$PLAT/Lodor.pak/lodor-sync"
if [ -n "$ROM" ] && [ -x "$_LODOR_SYNC" ]; then
	_bres=$( cd "$SDCARD/Tools/$PLAT/Lodor.pak" 2>/dev/null && \
		SDCARD_PATH="$SDCARD" PLATFORM="$PLAT" BASE_PATH="$SDCARD" CFW=MinUI \
		./lodor-sync --check-bios "$ROM" 2>/dev/null )
	case "$_bres" in
		*bios_ok=0*)
			_bmiss=$(printf '%s' "$_bres" | sed -n 's/.*missing=\([^ ]*\).*/\1/p' | tr ',' ' ')
			_bsys=$(printf '%s' "$_bres" | sed -n 's/.*system=//p')
			_bmsg="${_bsys:-This game} needs BIOS: ${_bmiss:-firmware}. Get it via Sync > Download BIOS, then relaunch."
			echo "$(date +'%F %T') [shim] BIOS GATE: blocked launch — $_bmsg" >> "$SDCARD/Tools/$PLAT/Lodor.pak/session.log" 2>/dev/null
			if [ -x "$SDCARD/.system/$PLAT/bin/say.elf" ]; then "$SDCARD/.system/$PLAT/bin/say.elf" "$_bmsg" >/dev/null 2>&1
			elif command -v say.elf >/dev/null 2>&1; then say.elf "$_bmsg" >/dev/null 2>&1
			else echo "$(date +'%F %T') [shim] BIOS GATE: say.elf unavailable — reason recoverable via session.log + last-fail-reason.txt" >> "$SDCARD/Tools/$PLAT/Lodor.pak/session.log" 2>/dev/null; fi
			# #13/#17: persist the reason where it survives the session — say.elf may be absent
			# or unusable, and the message must still be recoverable afterwards. FAT32-atomic
			# temp+mv; written inline because this shim deliberately never sources the lib (the
			# launch path below is load-bearing).
			_frf="$SDCARD/.userdata/shared/last-fail-reason.txt"
			mkdir -p "$SDCARD/.userdata/shared" 2>/dev/null
			{ printf '%s\n' "$_bmsg"; date +'%F %T'; } > "$_frf.tmp.$$" 2>/dev/null && mv -f "$_frf.tmp.$$" "$_frf" 2>/dev/null
			rm -f "$_frf.tmp.$$" 2>/dev/null
			exit 0
			;;
	esac
fi

# Pre-game save pull — OPPORTUNISTIC. Launching a game must NEVER bring WiFi up: a cold bring-up is a
# 30-45s delay on EVERY launch and it cold-cycles the 8188fu (the wedge risk). So we pull ONLY when WiFi
# is ALREADY up — a stub we just downloaded leaves the radio warm, or the user turned WiFi on to sync.
# Otherwise the game launches instantly, offline, on the local save. (Inline check, no lib sourcing — the
# launch below is load-bearing and must not inherit the lib's shell options or side effects.) Still
# hard-capped by `timeout` so even a warm-but-flaky link can't block the launch.
romm_wifi_up() {
	[ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = "up" ] || return 1
	ip addr show wlan0 2>/dev/null | grep -q "inet " || return 1
	return 0
}
if [ -x "$HELPER" ] && [ -n "$ROM" ] && romm_wifi_up; then
	if command -v timeout >/dev/null 2>&1; then
		timeout 20 "$HELPER" pull "$ROM" >/dev/null 2>&1
	else
		"$HELPER" pull "$ROM" >/dev/null 2>&1
	fi
fi

# Playtime session bracket (task #146): stage the session before launch, record it after.
# OFFLINE + sub-second (engine --session-start/--session-end: /tmp stage, uptime-delta math,
# local JSONL/TSV only, no network) and NEVER load-bearing: rc is ignored, launch is not gated.
LODOR_PAK="$SDCARD/Tools/$PLAT/Lodor.pak"
_lodor_session() {
	[ -n "$ROM" ] && [ -x "$LODOR_PAK/lodor-sync" ] || return 0
	( cd "$LODOR_PAK" && SDCARD_PATH="$SDCARD" PLATFORM="$PLAT" BASE_PATH="$SDCARD" CFW=MinUI \
		./lodor-sync "$1" "$ROM" ) >/dev/null 2>&1
	return 0
}
_lodor_session --session-start

# Launch the real emulator. NEVER gated on sync. Bracket it with epochs so a finished session
# can be reported to RomM (play-session telemetry -> cross-device Continue/recently-played).
_play_start=$(date +%s)
if [ -x "$REAL" ]; then
	"$REAL" "$@"
	rc=$?
else
	echo "$(date +'%F %T') [shim] FATAL real minarch missing: $REAL" >> "$SDCARD/Tools/$PLAT/Lodor.pak/session.log" 2>/dev/null
	rc=127
fi
_play_end=$(date +%s)

# Close the playtime session (idempotent: the engine consumes the /tmp stage on first take).
_lodor_session --session-end

# Post-game HYBRID sync: the save is already CACHED on the card (the real emulator wrote it to /Saves/).
# If it CHANGED this session, sync it the way the CURRENT radio state allows:
#   * WiFi ALREADY UP (online): push it straight to RomM now via romm-session-sync, which writes
#     last-synced.txt on a VERIFIED land (the launcher flashes "synced ✓") or stages it to the pending
#     queue if it doesn't land. We pull NO cold bring-up here — only a warm link is used, hard-capped by
#     `timeout` so a flaky warm link still can't wedge the return to the menu.
#   * WiFi DOWN (offline): just record the ROM as pending upload — NO sync, NO WiFi, instant return to
#     the menu. This device is often off-WiFi and a quit must NEVER block on/cold-cycle the radio. The
#     root-menu pending badge reminds the user to upload when they next have WiFi (offline-first).
# OFFLINE UPLOAD QUEUE: one FLAT pending-saves.txt — the SAME file the engine drainer
# (lodor-sync --push-pending / pending.go pendingPath()), the daemon has_pending gate
# (romm-syncd), the wizard pending badge, and the download queue lock all read/drain.
# It MUST stay flat: a profile-namespaced file (pending-saves.<profile>.txt) is written
# but NOTHING drains it, so an offline save queued under a profile silently never uploads
# while Sync Now reports success on the empty flat file (data-loss + fake-success). Multi-
# user correctness comes from the per-profile Saves/<profile> dir + active-profile
# resolution at DRAIN time (SavesDir()/findLocalSavesForRom), NOT from the queue filename:
# a bare ROM line resolves against the booted profile's SavesDir(), so a shared flat queue
# cannot cross-mix saves. (2026-07-10 #bugshell: reverted the namespaced writer.)
PENDING="$SDCARD/Tools/$PLAT/Lodor.pak/pending-saves.txt"
if [ -n "$ROM" ]; then
	_rb=$(basename "$ROM"); _rbne="${_rb%.*}"
	# any save file for THIS rom present on the card? NAME-ONLY by design (CLOCK-FIX: the old
	# `-newer $INGAME_LOCK` mtime test was dropped — RTC-less boots make mtimes lie); the
	# engine's content-hash dedup makes a re-push of an unchanged save a no-op, so matching
	# by name alone is safe and never loses a save to a wrong clock.
	# MULTI-USER: scan the SAME (profile-namespaced) tree minarch wrote into. $SAVES_PATH
	# is exported by the boot script (Saves/$LODOR_PROFILE); fall back to the shared Saves
	# dir when unset (single-user), so the scan and the emulator write always agree.
	# BRACKET-FIX (2026-07-03, #162): No-Intro names carry glob metacharacters ([S] [!] [b]
	# [h] [T-En]). The old `-iname "$_rb.*"` catch-all fed those brackets to find's fnmatch,
	# so a bracketed ROM's just-written save was never matched and the push/queue was silently
	# skipped -> save never reached RomM. Now: (a) enumerate the KNOWN save extensions instead
	# of the `.*` catch-all, and (b) escape the two glob metachars `[`/`]` in the stem so find
	# matches the literal name. Both save-naming styles are covered: minarch appends to the full
	# basename ("Game (USA) [S].gbc.srm"), RetroArch replaces the extension ("Game (USA) [S].srm").
	# Escape the two glob metachars for find's fnmatch. Order-safe: `]`->placeholder first so
	# the `[`->`[[]` pass can't re-mangle a just-emitted bracket, then placeholder->`[]]`.
	_rb_g=$(printf %s "$_rb" | sed -e 's/\]/@LODORRB@/g' -e 's/\[/[[]/g' -e 's/@LODORRB@/[]]/g')
	_rbne_g=$(printf %s "$_rbne" | sed -e 's/\]/@LODORRB@/g' -e 's/\[/[[]/g' -e 's/@LODORRB@/[]]/g')
	_save_changed=0
	if find "${SAVES_PATH:-$SDCARD/Saves}" \( \
		-iname "$_rb_g.srm" -o -iname "$_rb_g.sav" -o -iname "$_rb_g.dsv" \
		-o -iname "$_rb_g.mcr" -o -iname "$_rb_g.mcd" -o -iname "$_rb_g.brm" \
		-o -iname "$_rb_g.eep" -o -iname "$_rb_g.sra" -o -iname "$_rb_g.fla" \
		-o -iname "$_rb_g.mpk" -o -iname "$_rb_g.nv" -o -iname "$_rb_g.rtc" \
		-o -iname "$_rb_g.state*" \
		-o -iname "$_rbne_g.srm" -o -iname "$_rbne_g.sav" -o -iname "$_rbne_g.dsv" \
		-o -iname "$_rbne_g.mcr" -o -iname "$_rbne_g.mcd" -o -iname "$_rbne_g.brm" \
		-o -iname "$_rbne_g.eep" -o -iname "$_rbne_g.sra" -o -iname "$_rbne_g.fla" \
		-o -iname "$_rbne_g.mpk" -o -iname "$_rbne_g.nv" -o -iname "$_rbne_g.rtc" \
		-o -iname "$_rbne_g.state*" \
	\) 2>/dev/null | grep -q .; then
		_save_changed=1
	fi

	# SAVE handling — gated on an actual save-file change (as before).
	#   online  -> $HELPER push: pushes the changed save AND (Handoff v1) its states, then drains
	#              the offline state queue. _pushed_online records that states are already covered
	#              so the independent state step below doesn't double-push the same warm link.
	#   offline -> queue the ROM for later save upload (states are queued by the state step below).
	_pushed_online=0
	if [ "$_save_changed" = 1 ]; then
		if [ -x "$HELPER" ] && romm_wifi_up; then
			if command -v timeout >/dev/null 2>&1; then
				timeout 30 "$HELPER" push "$ROM" >/dev/null 2>&1
			else
				"$HELPER" push "$ROM" >/dev/null 2>&1
			fi
			_pushed_online=1
		else
			grep -qxF "$ROM" "$PENDING" 2>/dev/null || echo "$ROM" >> "$PENDING"
		fi
	fi

	# SAVE-STATE handling — DECOUPLED from the save-file gate (task: los-statesync). A state-only
	# session (quicksave, no battery save written) used to sync NOTHING: the save block above never
	# fired, so states never reached RomM and were never queued offline. This block runs on EVERY
	# exit, independent of whether a save changed. Same warm-link-only rule + `timeout` guard the
	# save push uses — a quit NEVER cold-cycles the radio or blocks the return to the menu.
	#   online  -> $HELPER push: --push-save (cheap MD5 dedup no-op when the save is unchanged) +
	#              --push-states + --push-pending-states. Skipped when _pushed_online already ran it.
	#   offline -> $HELPER push hits the helper's offline branch, which runs --queue-state <rom>
	#              (instant, WiFi-dark) — mirroring romm-session-sync's own offline state queue.
	if [ -x "$HELPER" ] && [ "$_pushed_online" != 1 ]; then
		if command -v timeout >/dev/null 2>&1; then
			timeout 30 "$HELPER" push "$ROM" >/dev/null 2>&1 || true
		else
			"$HELPER" push "$ROM" >/dev/null 2>&1 || true
		fi
	fi
fi

# Play-session reporting (best-effort telemetry; feeds cross-device Continue/recently-played). Like the
# post-game save push, it runs ONLY when WiFi is ALREADY up (never a cold bring-up on a quit) and is hard-
# capped by `timeout` so a flaky warm link can't wedge the return to the menu. A session played offline is
# simply not reported (no queue) — telemetry, not data. Skipped if the window is non-positive.
if [ -x "$HELPER" ] && [ -n "$ROM" ] && [ -n "$_play_start" ] && [ -n "$_play_end" ] && [ "$_play_end" -gt "$_play_start" ] && romm_wifi_up; then
	if command -v timeout >/dev/null 2>&1; then
		timeout 20 "$HELPER" report "$ROM" "$_play_start" "$_play_end" >/dev/null 2>&1
	else
		"$HELPER" report "$ROM" "$_play_start" "$_play_end" >/dev/null 2>&1
	fi
fi

exit "$rc"
