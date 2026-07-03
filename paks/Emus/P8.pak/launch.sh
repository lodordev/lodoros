#!/bin/sh

EMU_EXE=fake08
EMU_EXE="${LODOR_CORE_OVERRIDE:-$EMU_EXE}" # lodor #144: per-game core override (sidecar core=)
CORES_PATH=$(dirname "$0")

###############################

EMU_TAG="${LODOR_ROM_TAG:-$(basename "$(dirname "$0")" .pak)}" # lodor #144: saves stay keyed by the ROM folder TAG
ROM="$1"
mkdir -p "$BIOS_PATH/$EMU_TAG"
mkdir -p "$SAVES_PATH/$EMU_TAG"
HOME="$USERDATA_PATH"
cd "$HOME"
nice -20 minarch.elf "$CORES_PATH/${EMU_EXE}_libretro.so" "$ROM" &> "$LOGS_PATH/$EMU_TAG.txt"
