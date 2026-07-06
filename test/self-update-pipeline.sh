#!/bin/sh
# Phase 3 off-hardware test: manifest -> --fetch-update -> staged tree -> boot applier,
# against a fake LodorOS card. Run on Panther (needs the built amd64 engine at $ENG).
set -eu
ENG=${ENG:?set ENG=<amd64 lodor-sync stamped binary>}
MONO=/mnt/cache/tmp/lodor-mono
T=$(mktemp -d /tmp/lodor-p3.XXXXXX)
echo "== workdir $T"
PASS=0; FAIL=0
ok(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# ---- 1. fake card ----------------------------------------------------------------
SD="$T/sd"
PAK="$SD/Tools/miyoomini/Lodor.pak"
mkdir -p "$PAK/bin" "$PAK/lib" "$SD/.system/miyoomini/bin" "$SD/.userdata/miyoomini"
cp "$MONO/lodoros/paks/Lodor.pak/install.sh" "$PAK/install.sh"
cp "$MONO/lodoros/paks/Lodor.pak/bin/lodor-apply-update" "$PAK/bin/lodor-apply-update"
cp "$MONO/lodoros/paks/Lodor.pak/bin/minarch-shim.sh" "$PAK/bin/minarch-shim.sh"
printf 'old-engine-v0.9.3\n' > "$PAK/lodor-sync"
printf '#!/bin/sh\necho lib\n' > "$PAK/lib/romm-sync-lib.sh"
printf 'launch\n' > "$PAK/launch.sh"; printf 'uninstall\n' > "$PAK/uninstall.sh"
printf '\177ELF-fake-stock-minarch\n' > "$SD/.system/miyoomini/bin/minarch.elf"
printf '\177ELF-fake-stock-minui\n'   > "$SD/.system/miyoomini/bin/minui"
chmod +x "$PAK/bin/"* "$PAK/install.sh" "$PAK/lodor-sync"
# pre-existing auto.sh that ALREADY has the syncd line (the upgrade-card case)
cat > "$SD/.userdata/miyoomini/auto.sh" <<'EOF'
#!/bin/sh

test -x "$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak/bin/romm-syncd" && "$SDCARD_PATH/Tools/$PLATFORM/Lodor.pak/bin/romm-syncd" >/dev/null 2>&1 </dev/null & # romm-syncd
EOF
chmod +x "$SD/.userdata/miyoomini/auto.sh"

# ---- 2. install.sh inserts the applier line BEFORE the syncd line -----------------
( cd "$PAK" && SDCARD_PATH="$SD" PLATFORM=miyoomini sh install.sh >/dev/null 2>&1 )
AUTO="$SD/.userdata/miyoomini/auto.sh"
APPLY_LN=$(grep -n "lodor-update-apply" "$AUTO" | cut -d: -f1 | head -1)
SYNCD_LN=$(grep -n "# romm-syncd" "$AUTO" | cut -d: -f1 | head -1)
[ -n "$APPLY_LN" ] && [ -n "$SYNCD_LN" ] && [ "$APPLY_LN" -lt "$SYNCD_LN" ] \
  && ok "auto.sh: applier line present and BEFORE romm-syncd (line $APPLY_LN < $SYNCD_LN)" \
  || bad "auto.sh ordering wrong (apply=$APPLY_LN syncd=$SYNCD_LN)"
# idempotent re-run adds nothing
( cd "$PAK" && SDCARD_PATH="$SD" PLATFORM=miyoomini sh install.sh >/dev/null 2>&1 )
[ "$(grep -c "lodor-update-apply" "$AUTO")" = 1 ] && ok "install.sh idempotent (1 applier line after re-run)" || bad "duplicate applier lines"

# ---- 3. update asset zip + manifest fixture ---------------------------------------
UPZ="$T/update"
NEWPAK="$UPZ/Tools/miyoomini/Lodor.pak"
mkdir -p "$NEWPAK/bin" "$NEWPAK/lib" "$UPZ/Tools/miyoomini/Update Lodor.pak"
printf 'NEW-engine-v0.9.9\n' > "$NEWPAK/lodor-sync"
printf '#!/bin/sh\necho newlib\n' > "$NEWPAK/lib/romm-sync-lib.sh"
cp "$PAK/install.sh" "$NEWPAK/install.sh"
cp "$PAK/bin/lodor-apply-update" "$NEWPAK/bin/lodor-apply-update"
cp "$PAK/bin/minarch-shim.sh" "$NEWPAK/bin/minarch-shim.sh"
printf 'update-pak\n' > "$UPZ/Tools/miyoomini/Update Lodor.pak/launch.sh"
# a mis-built asset carrying launcher bytes — the applier must strip these, never apply them
printf 'EVIL-new-minui\n' > "$UPZ/Tools/miyoomini/.keep" # (dir marker)
mkdir -p "$UPZ/.system/miyoomini/bin"; printf 'EVIL-new-minui\n' > "$UPZ/.system/miyoomini/bin/minui"
( cd "$UPZ" && zip -rqX "$T/upd.zip" . )
SHA=$(sha256sum "$T/upd.zip" | cut -d' ' -f1)
SIZE=$(stat -c%s "$T/upd.zip")
mkdir -p "$T/www"; cp "$T/upd.zip" "$T/www/upd.zip"
cat > "$T/www/versions.json" <<EOF
{"schema":1,"stable":{"version":"0.9.9","notes":"test build","assets":{"lodoros-miyoomini":{"url":"http://127.0.0.1:8123/upd.zip","size":$SIZE,"sha256":"$SHA"}}}}
EOF
( cd "$T/www" && python3 -m http.server 8123 >/dev/null 2>&1 & echo $! > "$T/httpd.pid" )
sleep 1

# ---- 4. engine --check-update + --fetch-update from the pak dir -------------------
cd "$PAK"
OUT=$(LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions.json "$ENG" --check-update)
echo "$OUT" | grep -q "update=1 current=0.9.4 latest=0.9.9" && ok "--check-update sees 0.9.9" || bad "check: $OUT"
FOUT=$(LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions.json LODOR_UPDATE_ASSET=lodoros-miyoomini "$ENG" --fetch-update)
echo "$FOUT" | grep -q "fetched=1 version=0.9.9" && ok "--fetch-update staged ($FOUT)" || bad "fetch: $FOUT"
[ -f "$PAK/.update/READY" ] && ok "READY marker written" || bad "no READY marker"
[ -f "$PAK/.update/tree/Tools/miyoomini/Lodor.pak/lodor-sync" ] && ok "staged tree has new engine" || bad "staged tree incomplete"
# corrupted-hash refetch: flip the sha in the manifest, expect exit 4 + staging GONE
sed 's/"sha256":"[a-f0-9]*"/"sha256":"deadbeef'"$(printf '%056d' 0)"'"/' "$T/www/versions.json" > "$T/www/versions-bad.json"
set +e
LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions-bad.json LODOR_UPDATE_ASSET=lodoros-miyoomini "$ENG" --fetch-update >/dev/null 2>&1
RC=$?
set -e
[ "$RC" = 4 ] && ok "hash-mismatch exits 4" || bad "hash-mismatch rc=$RC (want 4)"
[ ! -d "$PAK/.update" ] && ok "staging removed on mismatch" || bad "staging survived a bad hash"
# restage the good one for the applier test
LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions.json LODOR_UPDATE_ASSET=lodoros-miyoomini "$ENG" --fetch-update >/dev/null

# ---- 5. boot applier -----------------------------------------------------------------
SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/lodor-apply-update"
grep -q "NEW-engine-v0.9.9" "$PAK/lodor-sync" && ok "engine binary swapped to 0.9.9" || bad "engine NOT swapped"
grep -q "newlib" "$PAK/lib/romm-sync-lib.sh" && ok "lib overlaid" || bad "lib not overlaid"
[ -f "$SD/Tools/miyoomini/Update Lodor.pak/launch.sh" ] && ok "Update Lodor.pak landed" || bad "Update pak missing"
grep -q "EVIL" "$SD/.system/miyoomini/bin/minui" && bad "LAUNCHER WAS TOUCHED (must never happen)" || ok "launcher untouched (EVIL minui stripped)"
[ ! -d "$PAK/.update" ] && ok "staging cleared after apply" || bad "staging left behind"
[ "$(cat "$PAK/.update-applied")" = "0.9.9" ] && ok ".update-applied marker = 0.9.9" || bad "marker wrong: $(cat "$PAK/.update-applied" 2>/dev/null)"
grep -q "ROMM_MINARCH_SHIM" "$SD/.system/miyoomini/bin/minarch.elf" && ok "install.sh re-ran (shim active)" || bad "shim not re-installed"
# re-run = no-op
SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/lodor-apply-update"
ok "applier re-run is a clean no-op (no staging)"

# ---- 6. interrupted apply re-heals -------------------------------------------------
LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions.json LODOR_UPDATE_ASSET=lodoros-miyoomini "$ENG" --fetch-update >/dev/null
printf 'HALF-COPIED-GARBAGE\n' > "$PAK/lib/romm-sync-lib.sh"   # simulate a yank mid-overlay
SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/lodor-apply-update"
grep -q "newlib" "$PAK/lib/romm-sync-lib.sh" && ok "interrupted apply re-healed by next boot" || bad "re-heal failed"

kill "$(cat "$T/httpd.pid")" 2>/dev/null || true
echo "== RESULT: $PASS pass, $FAIL fail =="
[ "$FAIL" = 0 ]
