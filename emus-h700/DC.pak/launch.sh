#!/bin/sh
# LodorOS save-sync wrapper for a STANDALONE / stock-firmware-shim community pak.
# MARKER: ROMM_STANDALONE_PAK_WRAPPER
#
# A pak whose REAL launcher (launch.real.sh, upstream byte-identical) execs an emulator that does
# NOT go through LodorOS's minarch.elf — either a true standalone GL emulator (mupen64plus, flycast,
# ppsspp, DraStic, pico8) or a SHIM that drives the device's STOCK vendor RetroArch under
# /mnt/vendor. In both cases the global minarch session-sync shim's pull-before/push-after never
# fires, so this wrapper restores RomM save-sync at the pak level by calling the SAME engine seam:
#   Tools/$PLATFORM/Lodor.pak/bin/romm-session-sync pull|push "<rom>"
# which sources romm-sync-lib.sh -> run_sync -> lodor-sync --sync-save / --push-save.
#
# THE ROUND-TRIP, AND WHY EVERYTHING TRANSPORTS AS "<rom>.sav":
#   The engine syncs ONE local file per rom. On PULL it ALWAYS writes that file as
#   <SAVES_PATH>/<TAG>/<rom-on-disk-basename>.sav — platform.SaveFileName() hard-codes the ".sav"
#   suffix on MinUI (minarch's convention), IGNORING the server save's stored extension. So ".sav"
#   is the ONLY on-card name a save round-trips back to. Therefore this wrapper makes every
#   emulator's REAL save reachable through that one canonical blob:
#       SAV = <SAVES_PATH>/<TAG>/<rom-on-disk-basename>.sav
#   On PUSH the engine's findLocalSavesForRom() matches SAV (".sav" is a ValidSaveExtension and the
#   stem equals the rom's on-disk basename), uploads it; on PULL it writes the bytes back to SAV.
#   The wrapper bridges SAV <-> the emulator's real save shape. NO engine change is needed:
#     - ra      (vendor RetroArch shim) -> redirect savefile_directory to <SAVES_PATH>/<TAG> so the
#               core writes its single-file SRAM (.srm/.sra/.eep/.fla/.mpk/.brm) where the engine
#               scans. (minarch's .sav and a core's .srm coexist; the engine matches either stem.)
#     - ppsspp  (FOLDER-model SAVEDATA) -> tar the PSP SAVEDATA folder tree into SAV on exit,
#               untar SAV back into it before launch. (SAVEDATA is bind/symlinked onto
#               <SAVES_PATH>/PSP by the upstream launcher, so the GAMEID subdirs live right there.)
#     - flycast (DC VMU bank, FOLDER-model) -> tar the flycast data dir's VMU bins (vmu_save_*.bin
#               + dc_nvmem.bin) into SAV on exit, untar before launch. DECISION: the VMU bank is
#               shared Dreamcast hardware, so SAV is a PER-ROM SNAPSHOT of the bank (the last DC
#               game played carries the current bank). We do NOT rely on flycast PerGameVmu because
#               its per-game file is named by flycast's internal game id, not the rom basename, so
#               it can't be mapped to the engine's rom-keyed slot without on-hardware discovery.
#     - drastic (NDS .dsv, foreign single-file name) -> copy DraStic's backup/<rom-no-ext>.dsv to
#               SAV on exit, copy SAV back to backup/<rom-no-ext>.dsv before launch. (.dsv is a
#               single file, but DraStic names it <rom-no-ext>.dsv while the engine round-trips
#               <rom-basename>.sav — so we bridge the name, not the bytes.)
#     - pico8   (FOLDER-model cdata) -> not bridged here (cart-data is a shared per-author tree, no
#               clean per-rom key); logged, launch unaffected.
#   Savestates (.state/.dss/PPSSPP_STATE) are NEVER synced — same policy as every other system.
#
# RETROACHIEVEMENTS: a standalone emulator with built-in RA (flycast, PPSSPP) reads its creds from
# its OWN config, not the engine, so a pak that supports RA ships an ra-emu.conf naming its emulator
# (RA_EMU=flycast|ppsspp). When present we inject the stored RA creds + RA_ENABLE/RA_HARDCORE toggle
# into that emulator's config (Tools/$PLATFORM/Lodor.pak/bin/romm-ra-inject) just before launch.
# Paks whose emulator has NO upstream RA (mupen64plus, yabasanshiro/SS) ship NO ra-emu.conf -> no-op.
#
# HARD RULE (mirrors the minarch shim): the emulator launch is NEVER conditional on sync, on any
# bridge step, OR on RA wiring. Every hydrate/capture/redirect/RA-inject step is best-effort, guarded,
# and timeout-bounded; if it can't be applied the game STILL launches (to its old save dir) and we log
# why. The capture + push run on ANY exit (clean / power-off SIGTERM / kill) via a trap. launch.real.sh
# is the only load-bearing line.

set -u

PAK_DIR="$(dirname "$0")"
TAG="$(basename "$PAK_DIR" .pak)"
ROM="${1:-}"

# Env MinUI.pak/launch.sh exports before launching any pak; fall back defensively so a direct
# invocation still works. SAVES_PATH is the engine's SavesDir() (profile-namespaced under
# multi-user), so the bridge + the engine sync stay in lockstep with zero extra code. PLAT is read
# from $PLATFORM, else derived from the pak's Emus/<plat>/<TAG>.pak parent so the helper path is
# right on every device with no per-file edit.
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-$(basename "$(dirname "$PAK_DIR")")}"
SAVES_ROOT="${SAVES_PATH:-$SDCARD/Saves}"
USERDATA="${USERDATA_PATH:-$SDCARD/.userdata/$PLAT}"
HELPER="$SDCARD/Tools/$PLAT/Lodor.pak/bin/romm-session-sync"
WRAP_LOG="$SDCARD/Tools/$PLAT/Lodor.pak/session.log"

_wraplog() {
	echo "$(date +'%F %T') [$TAG-wrapper] $*" >> "$WRAP_LOG" 2>/dev/null
}

# ── Resolve the engine's save folder + canonical transport blob for THIS rom ──────────────────
# The rom lives in Roms/<Name> (TAG)/, and the engine scans Saves/<TAG>/ for the same TAG (the
# RomM mirror's PrimaryTag). Extract that parenthetical TAG; fall back to the pak name if the
# folder carries none (a user-foldered rom that won't RomM-sync anyway).
_rom_systag() {
	d="$(basename "$(dirname "$ROM")")"
	case "$d" in
		*\(*\)) t="${d##*\(}"; t="${t%%\)*}"; printf '%s' "$t" ;;
		*)      printf '%s' "$TAG" ;;
	esac
}
SYSTAG="$(_rom_systag)"
SAVEDIR="$SAVES_ROOT/$SYSTAG"
ROMFULL="$(basename "$ROM")"          # "Game (USA).iso"   (rom extension included)
ROMNOEXT="${ROMFULL%.*}"              # "Game (USA)"        (DraStic .dsv stem)
SAV="$SAVEDIR/$ROMFULL.sav"           # the one name the engine round-trips: <rom-basename>.sav

# ── Generic "is A newer than B (or B missing)" helper (POSIX -nt; busybox/ash/dash all have it) ─
_nt() { [ -e "$1" ] && { [ ! -e "$2" ] || [ "$1" -nt "$2" ]; }; }
# Does any regular file under DIR ($1) post-date REF ($2)? (REF missing => yes if DIR non-empty)
_dir_newer() {
	[ -d "$1" ] || return 1
	if [ ! -e "$2" ]; then
		[ -n "$(find "$1" -type f 2>/dev/null | head -n1)" ] && return 0 || return 1
	fi
	[ -n "$(find "$1" -type f -newer "$2" 2>/dev/null | head -n1)" ] && return 0 || return 1
}
# DC-only: did the VMU bank itself change vs SAV? (savestates in the same dir must NOT count, or a
# fresh savestate would falsely look like a changed memory-card.) REF=$1; returns 0 if any vmu/nvmem
# file is newer than REF, or REF absent and a vmu/nvmem file exists.
_dc_vmu_newer() {
	for f in vmu_save_A1.bin vmu_save_A2.bin dc_nvmem.bin; do
		_p="$_FLY_DATA/$f"
		[ -f "$_p" ] || continue
		_nt "$_p" "$1" && return 0
	done
	return 1
}

# ════════════════════════════════════════════════════════════════════════════════════════════
# ra redirect machinery (vendor RetroArch shim only) — unchanged behaviour, Flip/h700-safe.
# ════════════════════════════════════════════════════════════════════════════════════════════
# Each entry in _REDIR_BAKS is "live|backup" — restore on exit. "live|" (empty backup) means we
# CREATED live and should remove it on revert. Pure shell, no arrays (POSIX sh).
_REDIR_BAKS=""
_redir_revert() {
	[ -n "$_REDIR_BAKS" ] || return 0
	OLDIFS="$IFS"; IFS='
'
	for pair in $_REDIR_BAKS; do
		live="${pair%%|*}"; bak="${pair#*|}"
		if [ -n "$bak" ] && [ -f "$bak" ]; then
			mv -f "$bak" "$live" 2>/dev/null
		else
			rm -f "$live" 2>/dev/null
		fi
	done
	IFS="$OLDIFS"
	_REDIR_BAKS=""
	_wraplog "redirect reverted"
}

# _cfg_put FILE KEY VALUE  — idempotently set KEY = "VALUE" in a RetroArch cfg (dedupe existing key).
_cfg_put() {
	_f="$1"; _k="$2"; _v="$3"
	[ -f "$_f" ] || : > "$_f" 2>/dev/null || return 1
	_t="$_f.lodortmp.$$"
	grep -v "^${_k} = " "$_f" > "$_t" 2>/dev/null || : > "$_t"
	printf '%s = "%s"\n' "$_k" "$_v" >> "$_t" || { rm -f "$_t"; return 1; }
	mv -f "$_t" "$_f" || { rm -f "$_t"; return 1; }
	return 0
}

# _cfg_backup FILE — back up FILE to FILE.lodorbak (recording it for revert). Records a create-only
# marker ("live|") when FILE did not exist, so revert removes our overlay instead of leaving it.
_cfg_backup() {
	_f="$1"
	if [ -f "$_f" ]; then
		cp -f "$_f" "$_f.lodorbak" 2>/dev/null && _REDIR_BAKS="$_f|$_f.lodorbak
$_REDIR_BAKS"
	else
		_REDIR_BAKS="$_f|
$_REDIR_BAKS"
	fi
}

# _ra_apply_keys FILE — write the save-dir override keys into a RetroArch cfg/overlay FILE.
_ra_apply_keys() {
	_f="$1"
	_cfg_put "$_f" savefile_directory       "$SAVEDIR" || return 1
	_cfg_put "$_f" savestate_directory      "$SAVEDIR" || return 1
	_cfg_put "$_f" sort_savefiles_enable    "false"
	_cfg_put "$_f" sort_savestates_enable   "false"
	_cfg_put "$_f" savefiles_in_content_dir "false"
	_cfg_put "$_f" savestates_in_content_dir "false"
	return 0
}

# ════════════════════════════════════════════════════════════════════════════════════════════
# Emulator family detection (from the real launcher + any sibling vendor-RA helper script).
# Order matters: the FOLDER/standalone markers are checked BEFORE the generic retroarch sniff so a
# standalone flycast (which mentions "flycast" but never "retroarch") is not mistaken for ra, and a
# vendor flycast-libretro shim (mentions "retroarch") stays ra.
# ════════════════════════════════════════════════════════════════════════════════════════════
_emu_family() {
	_hay="$(cat "$PAK_DIR/launch.real.sh" "$PAK_DIR"/RA_launch*.sh 2>/dev/null)"
	case "$_hay" in
		*PPSSPPSDL*|*ppsspp/lcd_psp*) echo "ppsspp"; return ;;
		*FLYCAST_DATA_DIR*)           echo "flycast"; return ;;   # josegonzalez standalone flycast
		*setNDS.sh*)                  echo "drastic-vendor"; return ;;  # h700 stock DraStic shim
		*pico8_dyn*)                  echo "pico8"; return ;;
	esac
	# standalone steward-fu DraStic: execs ./drastic with HOME=pak dir, writes backup/<rom>.dsv.
	case "$_hay" in
		*/drastic\ *|*./drastic\ *|*\"\$1\"*drastic*|*drastic\ \"*) echo "drastic"; return ;;
	esac
	case "$_hay" in
		*drastic*) echo "drastic"; return ;;
	esac
	case "$_hay" in
		*/retroarch*|*'${RABIN}'*|*'$RABIN'*|*retroarch*) echo "ra"; return ;;
	esac
	echo "unknown"
}

# ════════════════════════════════════════════════════════════════════════════════════════════
# Bridge dispatch. _BRIDGE_KIND is resolved once, used by hydrate (post-pull) + capture (pre-push).
# ════════════════════════════════════════════════════════════════════════════════════════════
_FAMILY="$(_emu_family)"
_BRIDGE_KIND="none"
_FLY_DATA="$USERDATA/$TAG-flycast/data"     # flycast VMU bank dir (TAG = "DC")
_NDS_BACKUP="$PAK_DIR/backup"               # standalone DraStic backup dir (HOME=pak dir)
case "$_FAMILY" in
	ra)              _BRIDGE_KIND="ra" ;;
	ppsspp)          _BRIDGE_KIND="folder-psp" ;;
	flycast)         _BRIDGE_KIND="folder-dc" ;;
	drastic)         _BRIDGE_KIND="file-nds" ;;
	*)               _BRIDGE_KIND="none" ;;
esac
_wraplog "family=$_FAMILY bridge=$_BRIDGE_KIND systag=$SYSTAG savedir=$SAVEDIR sav=$ROMFULL.sav"

# ── ra redirect (vendor RetroArch shim): inject savefile_directory override, reverted on exit ──
_apply_ra_redirect() {
	[ -n "$ROM" ] || { _wraplog "ra redirect SKIP (no rom)"; return 0; }
	mkdir -p "$SAVEDIR" 2>/dev/null
	emu="$(grep -hoE 'EMU="[^"]+"' "$PAK_DIR/launch.real.sh" "$PAK_DIR"/RA_launch*.sh 2>/dev/null | head -n1 | sed 's/.*="//; s/"//')"
	ovl=""
	if [ -n "$emu" ] && grep -hq -- '--appendconfig' "$PAK_DIR"/RA_launch*.sh 2>/dev/null; then
		ovl="/.config/retroarch/tmp/retroarch_${emu}.cfg"
		mkdir -p "/.config/retroarch/tmp" 2>/dev/null
	fi
	if [ -n "$ovl" ]; then
		_cfg_backup "$ovl"
		if _ra_apply_keys "$ovl"; then
			_wraplog "redirect APPLIED ra/appendconfig overlay=$ovl -> $SAVEDIR"
		else
			_wraplog "redirect FAIL ra/appendconfig overlay=$ovl (launch continues, old save dir)"
		fi
	else
		cfg="/.config/retroarch/retroarch.cfg"
		if [ -f "$cfg" ]; then
			_cfg_backup "$cfg"
			_cfg_put "$cfg" config_save_on_exit "false"
			if _ra_apply_keys "$cfg"; then
				_wraplog "redirect APPLIED ra/retroarch.cfg cfg=$cfg -> $SAVEDIR"
			else
				_wraplog "redirect FAIL ra/retroarch.cfg cfg=$cfg (launch continues, old save dir)"
			fi
		else
			_wraplog "redirect SKIP ra: no runtime retroarch.cfg at $cfg and no appendconfig overlay (launch continues, old save dir)"
		fi
	fi
}

# ── Folder/file bridge HYDRATE (after the engine pull, before launch): SAV -> emulator save ────
# newest-wins locally: only hydrate when SAV exists and is newer than the live save (or live save
# is absent) so an unpushed local save is never reverted by a stale archive.
_bridge_hydrate() {
	[ -n "$ROM" ] || { _wraplog "hydrate SKIP (no rom)"; return 0; }
	case "$_BRIDGE_KIND" in
		ra) _apply_ra_redirect; return 0 ;;
		folder-psp)
			[ -f "$SAV" ] || { _wraplog "hydrate SKIP psp (no SAV)"; return 0; }
			if _dir_newer "$SAVEDIR" "$SAV"; then
				_wraplog "hydrate SKIP psp (live SAVEDATA newer than SAV)"; return 0
			fi
			mkdir -p "$SAVEDIR" 2>/dev/null
			if tar -xf "$SAV" -C "$SAVEDIR" 2>/dev/null; then
				_wraplog "hydrate OK psp: SAV -> $SAVEDIR (untar SAVEDATA)"
			else
				_wraplog "hydrate FAIL psp untar (launch continues)"
			fi
			;;
		folder-dc)
			[ -f "$SAV" ] || { _wraplog "hydrate SKIP dc (no SAV)"; return 0; }
			if _dc_vmu_newer "$SAV"; then
				_wraplog "hydrate SKIP dc (live VMU newer than SAV)"; return 0
			fi
			mkdir -p "$_FLY_DATA" 2>/dev/null
			if tar -xf "$SAV" -C "$_FLY_DATA" 2>/dev/null; then
				_wraplog "hydrate OK dc: SAV -> $_FLY_DATA (untar VMU bank)"
			else
				_wraplog "hydrate FAIL dc untar (launch continues)"
			fi
			;;
		file-nds)
			[ -f "$SAV" ] || { _wraplog "hydrate SKIP nds (no SAV)"; return 0; }
			_dsv="$_NDS_BACKUP/$ROMNOEXT.dsv"
			if [ -f "$_dsv" ] && ! _nt "$SAV" "$_dsv"; then
				_wraplog "hydrate SKIP nds (live .dsv newer than SAV)"; return 0
			fi
			mkdir -p "$_NDS_BACKUP" 2>/dev/null
			if cp -f "$SAV" "$_dsv" 2>/dev/null; then
				_wraplog "hydrate OK nds: SAV -> $_dsv"
			else
				_wraplog "hydrate FAIL nds copy (launch continues)"
			fi
			;;
		*)
			_wraplog "hydrate SKIP family=$_FAMILY (MinUI-native single-file or unrecognised; engine syncs it directly)"
			;;
	esac
	return 0
}

# ── Folder/file bridge CAPTURE (on exit, before the engine push): emulator save -> SAV ─────────
# Only writes SAV when the live save actually changed this session (live newer than SAV, or SAV
# absent) — avoids burning a new server version every launch when nothing was saved. Atomic via
# .tmp + mv so a power-yank mid-tar can't leave a truncated SAV.
_bridge_capture() {
	[ -n "$ROM" ] || return 0
	case "$_BRIDGE_KIND" in
		folder-psp)
			# tar the GAMEID subdirectories of SAVEDATA (= SAVEDIR). The SAV file itself is a
			# regular file and is excluded (we list directories only).
			_subs="$(cd "$SAVEDIR" 2>/dev/null && for d in */; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done)"
			[ -n "$_subs" ] || { _wraplog "capture SKIP psp (no SAVEDATA dirs)"; return 0; }
			_dir_newer "$SAVEDIR" "$SAV" || { _wraplog "capture SKIP psp (unchanged since SAV)"; return 0; }
			mkdir -p "$SAVEDIR" 2>/dev/null
			if ( cd "$SAVEDIR" && tar -cf "$SAV.tmp.$$" $_subs ) 2>/dev/null && mv -f "$SAV.tmp.$$" "$SAV" 2>/dev/null; then
				_wraplog "capture OK psp: $SAVEDIR SAVEDATA -> SAV"
			else
				rm -f "$SAV.tmp.$$" 2>/dev/null
				_wraplog "capture FAIL psp tar (save left in place; will retry next exit)"
			fi
			;;
		folder-dc)
			_files=""
			for f in vmu_save_A1.bin vmu_save_A2.bin dc_nvmem.bin; do
				[ -f "$_FLY_DATA/$f" ] && _files="$_files $f"
			done
			[ -n "$_files" ] || { _wraplog "capture SKIP dc (no VMU/nvmem files)"; return 0; }
			_dc_vmu_newer "$SAV" || { _wraplog "capture SKIP dc (VMU unchanged since SAV)"; return 0; }
			mkdir -p "$SAVEDIR" 2>/dev/null
			if ( cd "$_FLY_DATA" && tar -cf "$SAV.tmp.$$" $_files ) 2>/dev/null && mv -f "$SAV.tmp.$$" "$SAV" 2>/dev/null; then
				_wraplog "capture OK dc: VMU bank ($_files ) -> SAV"
			else
				rm -f "$SAV.tmp.$$" 2>/dev/null
				_wraplog "capture FAIL dc tar (save left in place; will retry next exit)"
			fi
			;;
		file-nds)
			_dsv="$_NDS_BACKUP/$ROMNOEXT.dsv"
			[ -f "$_dsv" ] || { _wraplog "capture SKIP nds (no backup/$ROMNOEXT.dsv)"; return 0; }
			_nt "$_dsv" "$SAV" || { _wraplog "capture SKIP nds (.dsv unchanged since SAV)"; return 0; }
			mkdir -p "$SAVEDIR" 2>/dev/null
			if cp -f "$_dsv" "$SAV.tmp.$$" 2>/dev/null && mv -f "$SAV.tmp.$$" "$SAV" 2>/dev/null; then
				_wraplog "capture OK nds: $_dsv -> SAV"
			else
				rm -f "$SAV.tmp.$$" 2>/dev/null
				_wraplog "capture FAIL nds copy (save left in place; will retry next exit)"
			fi
			;;
		ra)   _redir_revert ;;
		*)    : ;;
	esac
	return 0
}

# ── Pre-game save PULL (newer-server-wins) — opportunistic + hard-capped ──────────────────────
_wraplog "launch rom=$ROM"
if [ -x "$HELPER" ] && [ -n "$ROM" ]; then
	_wraplog "pull begin rom=$ROM"
	if command -v timeout >/dev/null 2>&1; then
		timeout 25 "$HELPER" pull "$ROM" >/dev/null 2>&1
	else
		"$HELPER" pull "$ROM" >/dev/null 2>&1
	fi
	_wraplog "pull end rom=$ROM"
else
	_wraplog "pull SKIP (no helper or no rom) helper=$HELPER"
fi

# RetroAchievements creds injection (only for paks shipping ra-emu.conf). Best-effort,
# never blocks the launch (HARD RULE above). The emulator reads RA from its own config.
RA_INJECT="$SDCARD/Tools/$PLAT/Lodor.pak/bin/romm-ra-inject"
if [ -f "$PAK_DIR/ra-emu.conf" ] && [ -x "$RA_INJECT" ]; then
	RA_EMU=""
	. "$PAK_DIR/ra-emu.conf" 2>/dev/null
	if [ -n "$RA_EMU" ]; then
		_wraplog "ra-inject begin emu=$RA_EMU"
		if command -v timeout >/dev/null 2>&1; then timeout 10 "$RA_INJECT" "$RA_EMU" "$PAK_DIR" >/dev/null 2>&1
		else "$RA_INJECT" "$RA_EMU" "$PAK_DIR" >/dev/null 2>&1; fi
		_wraplog "ra-inject end emu=$RA_EMU"
	fi
fi

# ── Recover any stale ra .lodorbak from a prior power-yank, then hydrate this session ──────────
_recover_stale() {
	for stale in "/.config/retroarch/retroarch.cfg.lodorbak" "/.config/retroarch/tmp"/retroarch_*.cfg.lodorbak; do
		[ -f "$stale" ] || continue
		mv -f "$stale" "${stale%.lodorbak}" 2>/dev/null && _wraplog "recovered stale redirect backup ${stale%.lodorbak}"
	done
}
_recover_stale 2>/dev/null
_bridge_hydrate 2>/dev/null || _wraplog "hydrate errored (launch continues)"

# ── Post-game: capture (revert) + PUSH on ANY exit (clean / power-off SIGTERM / kill) ─────────
_pushed=0
_on_exit() {
	_bridge_capture 2>/dev/null
	[ "$_pushed" = "1" ] && return 0
	_pushed=1
	if [ -x "$HELPER" ] && [ -n "$ROM" ]; then
		_wraplog "push begin rom=$ROM"
		if command -v timeout >/dev/null 2>&1; then
			timeout 30 "$HELPER" push "$ROM" >/dev/null 2>&1
		else
			"$HELPER" push "$ROM" >/dev/null 2>&1
		fi
		_wraplog "push end rom=$ROM"
	else
		_wraplog "push SKIP (no helper or no rom) helper=$HELPER"
	fi
}
trap '_on_exit' EXIT INT TERM HUP QUIT

# ── Run the REAL upstream launcher in the foreground (blocks until the emulator exits) ────────
if [ -x "$PAK_DIR/launch.real.sh" ]; then
	"$PAK_DIR/launch.real.sh" "$@"
	rc=$?
else
	_wraplog "FATAL launch.real.sh missing in $PAK_DIR"
	rc=127
fi

_on_exit
exit "$rc"
