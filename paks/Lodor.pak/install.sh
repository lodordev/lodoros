#!/bin/sh
# install.sh — install the RomM sync layer (minarch session-sync shim + boot daemon).
# Idempotent and reversible (see uninstall.sh). Safe to re-run. Saves are never touched.

set -u
PAKDIR="$(cd "$(dirname "$0")" && pwd)"
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-miyoomini}"
BIN="$SDCARD/.system/$PLAT/bin"
AUTO="$SDCARD/.userdata/$PLAT/auto.sh"

echo "== RomM sync layer install =="

[ -d "$BIN" ] || { echo "ERROR: $BIN not found (wrong platform?)"; exit 1; }
[ -f "$PAKDIR/bin/minarch-shim.sh" ] || { echo "ERROR: shim template missing"; exit 1; }
# Need either the live minarch or a saved real copy (lets a partial prior install recover).
[ -f "$BIN/minarch.elf" ] || [ -f "$BIN/minarch.real.elf" ] || { echo "ERROR: no minarch.elf found"; exit 1; }

# 1. make our own scripts/binary executable
chmod +x "$PAKDIR/launch.sh" "$PAKDIR/lodor-sync" 2>/dev/null
chmod +x "$PAKDIR"/bin/* "$PAKDIR"/lib/*.sh 2>/dev/null

# 2. minarch shim — idempotent AND crash-atomic. The stock binary is COPIED (never moved) to
# minarch.real.elf, so the live minarch.elf is never absent; the shim is staged to a temp name and
# swapped in with a single atomic mv as the last step. Safe to re-run; never double-renames.
if [ ! -f "$BIN/minarch.real.elf" ]; then
	if grep -q "ROMM_MINARCH_SHIM" "$BIN/minarch.elf" 2>/dev/null; then
		echo "ERROR: shim is installed but minarch.real.elf is missing — restore stock minarch first"; exit 1
	fi
	cp -p "$BIN/minarch.elf" "$BIN/minarch.real.elf"
	cp -p "$BIN/minarch.elf" "$BIN/minarch.elf.stock-bak"
	echo "  [ok] saved stock minarch -> minarch.real.elf (+ stock-bak)"
else
	echo "  [skip] minarch.real.elf already present"
fi
cp "$PAKDIR/bin/minarch-shim.sh" "$BIN/minarch.elf.new"
chmod +x "$BIN/minarch.elf.new"
mv -f "$BIN/minarch.elf.new" "$BIN/minarch.elf"   # atomic swap-in
echo "  [ok] minarch shim active (real -> minarch.real.elf)"

# 3. boot daemon via auto.sh — sentinel-guarded append (mirrors the Wifi.pak on-boot pattern).
if [ ! -f "$AUTO" ]; then
	printf '#!/bin/sh\n\n' > "$AUTO"
	chmod +x "$AUTO"
fi
if grep -q "# romm-syncd" "$AUTO" 2>/dev/null; then
	echo "  [skip] auto.sh already starts romm-syncd"
else
	# Literal $SDCARD_PATH/$PLATFORM (relocatable; expanded on-device at boot). Detached with &.
	# awk 1 (not a bare >> append): re-emits every line WITH a newline, so an auto.sh missing
	# its trailing newline can't glue our line onto its last command; temp+mv (FAT32 doctrine).
	{ awk 1 "$AUTO" && printf '%s\n' 'test -x "$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak/bin/romm-syncd" && "$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak/bin/romm-syncd" >/dev/null 2>&1 </dev/null & # romm-syncd'; } > "$AUTO.new" \
		&& mv -f "$AUTO.new" "$AUTO" \
			|| { rm -f "$AUTO.new" 2>/dev/null; echo "  ERROR: could not update auto.sh - boot hooks NOT installed"; exit 1; }
	rm -f "$AUTO.new" 2>/dev/null
	echo "  [ok] auto.sh starts romm-syncd at boot"
fi

# 4. boot update-applier via auto.sh — MUST run BEFORE romm-syncd starts (a staged self-update
# swaps the engine binary; the daemon must not exec it mid-swap). SYNCHRONOUS (no &): a normal
# boot is an instant no-op (no staging), an applying boot must finish before anything runs.
# On cards whose auto.sh already carries the syncd line, insert ABOVE it; else append.
APPLY_LINE='test -x "$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak/bin/lodor-apply-update" && "$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak/bin/lodor-apply-update" # lodor-update-apply'
if grep -q "# lodor-update-apply" "$AUTO" 2>/dev/null; then
	echo "  [skip] auto.sh already runs the update applier"
else
	if grep -q "# romm-syncd" "$AUTO" 2>/dev/null; then
		awk -v ins="$APPLY_LINE" '/# romm-syncd/ && !done { print ins; done=1 } { print }' "$AUTO" > "$AUTO.new" \
			&& mv -f "$AUTO.new" "$AUTO" \
			|| { rm -f "$AUTO.new" 2>/dev/null; echo "  ERROR: could not update auto.sh - boot hooks NOT installed"; exit 1; }
		rm -f "$AUTO.new" 2>/dev/null
	else
		# same no-trailing-newline guard as the syncd-line append above
		{ awk 1 "$AUTO" && printf '%s\n' "$APPLY_LINE"; } > "$AUTO.new" \
			&& mv -f "$AUTO.new" "$AUTO" \
			|| { rm -f "$AUTO.new" 2>/dev/null; echo "  ERROR: could not update auto.sh - boot hooks NOT installed"; exit 1; }
		rm -f "$AUTO.new" 2>/dev/null
	fi
	chmod +x "$AUTO"
	echo "  [ok] auto.sh runs the update applier at boot (before the daemon)"
fi

echo "== done. Reboot to start the daemon. Saves untouched. =="
