#!/bin/sh
# uninstall.sh — fully reverse install.sh. Restores stock minarch, stops + de-registers the daemon.
# Each piece is independent; this removes both. Saves are never touched.

set -u
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-miyoomini}"
BIN="$SDCARD/.system/$PLAT/bin"
AUTO="$SDCARD/.userdata/$PLAT/auto.sh"

echo "== RomM sync layer uninstall =="

# 1. restore stock minarch
if grep -q "ROMM_MINARCH_SHIM" "$BIN/minarch.elf" 2>/dev/null; then
	if [ -f "$BIN/minarch.real.elf" ]; then
		mv -f "$BIN/minarch.real.elf" "$BIN/minarch.elf"
		echo "  [ok] minarch restored from minarch.real.elf"
	elif [ -f "$BIN/minarch.elf.stock-bak" ]; then
		cp -f "$BIN/minarch.elf.stock-bak" "$BIN/minarch.elf"
		echo "  [ok] minarch restored from stock-bak"
	else
		echo "  [WARN] shim present but no stock minarch to restore!"
	fi
else
	echo "  [skip] minarch shim not installed"
fi

# 2. remove the daemon line from auto.sh
if [ -f "$AUTO" ] && grep -q "# romm-syncd" "$AUTO" 2>/dev/null; then
	sed -i '/# romm-syncd/d' "$AUTO"
	echo "  [ok] auto.sh daemon line removed"
else
	echo "  [skip] auto.sh has no daemon line"
fi

# 3. stop a running daemon + clear transient locks
killall romm-syncd 2>/dev/null
rm -rf /tmp/romm-wifi.lock /tmp/romm-in-game 2>/dev/null

echo "== done. Reboot for a clean state. Saves untouched. =="
