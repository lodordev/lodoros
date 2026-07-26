#!/bin/sh
# build.sh — cross-compile lodor-fbhelper (SDL 1.2) for the armhf SigmaStar panels (miyoomini:
# Miyoo Mini Plus / Mini Flip, SSD202D). This is the LodorOS launch-card scanout helper: raw
# /dev/fb0 is dead on the SSD202D, so the wizard's SDL lane pipes RGB565 frames here and this
# binary presents them via the custom MinUI SDL 1.2 (SDL_SetVideoMode + SDL_Flip -> MI_GFX),
# the exact path minui.elf uses on this chip. The aarch64/SDL2 sibling lives in
# integrations/nextui/fbhelper/ (same LFB1 wire protocol).
#
# Uses the pinned miyoomini toolchain image (shauninman/union-miyoomini-toolchain, armhf/SDL1.2)
# — the same image that builds minui.elf/minarch (see release/build-launchers.sh). release.sh
# builds+ships this automatically for the miyoomini update overlay; run this standalone to
# produce a binary for an on-device spike (drop it at Lodor.pak/bin/lodor-fbhelper and boot).
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IMG=${LODOR_MIYOOMINI_TOOLCHAIN:-miyoomini-toolchain}
OUT=${1:-"$HERE/lodor-fbhelper"}

docker image inspect "$IMG" >/dev/null 2>&1 || { echo "FATAL: toolchain image '$IMG' not present (see release/toolchains/README.md)"; exit 2; }
docker run --rm -v "$HERE":/src -v "$(dirname "$OUT")":/out -w /src "$IMG" /bin/bash -lc \
  "arm-linux-gnueabihf-gcc lodor-fbhelper.c -o /out/$(basename "$OUT") -lSDL -lmi_sys -lmi_gfx -lpthread"
file "$OUT" | grep -q "ARM" || { echo "FATAL: lodor-fbhelper is not ARM"; exit 1; }
echo "LODOR_FBHELPER $OUT $(sha256sum "$OUT" | cut -d' ' -f1)"
