#!/bin/sh
# Reset WiFi — recovers the 8188fu radio when it stops pulling an IP. grout32 draws the explain/confirm
# screens (shell text corrupts the framebuffer on this device) and runs Lodor.pak/bin/wifi-reset.
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
PLAT="${PLATFORM:-miyoomini}"
GROUT_DIR="$SDCARD/Tools/$PLAT/Grout.pak"
[ -x "$GROUT_DIR/grout32" ] || exit 0
cd "$GROUT_DIR" || exit 0
export CFW=MinUI MINUI_DEVICE="$PLAT" IS_MIYOO=1
export SDL_VIDEODRIVER=mmiyoo SDL_AUDIODRIVER=mmiyoo EGL_VIDEODRIVER=mmiyoo SDL_MMIYOO_DOUBLE_BUFFER=1
export LD_LIBRARY_PATH="$GROUT_DIR/lib32:${LD_LIBRARY_PATH:-}"
./grout32 --wifi-reset
