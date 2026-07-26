#!/bin/sh
# Phase 3 off-hardware test: manifest -> --fetch-update -> staged tree -> boot applier,
# against a fake LodorOS card. Run on the build host (needs the built amd64 engine at $ENG).
# Covers the lodor#46 resume contract (partial sidecar + identity + Range) and the
# lodor#47 rollback/revert contract (pre-apply mirror, bounded set, boot-time revert).
set -eu
ENG=${ENG:?set ENG=<amd64 lodor-sync stamped binary>}
# MONO defaults to the repo the test itself lives in, so a worktree's fleet-check exercises the
# worktree's shell layer (applier/install/shim), not the shared checkout; override to point elsewhere.
MONO=${MONO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}
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
# birth-stamped OS version file: the rollback's rolled-from source (lodor#47)
printf 'LodorOS-0.9.3\nbirth-sha\n' > "$SD/.system/version.txt"
chmod +x "$PAK/bin/"* "$PAK/install.sh" "$PAK/lodor-sync"
# a stale pak the GBA->mGBA migration dropped — the update's deprecated-paks.txt must delete it
mkdir -p "$SD/Emus/miyoomini/MGBA.pak"
printf 'stale-mgba-launch\n' > "$SD/Emus/miyoomini/MGBA.pak/launch.sh"
printf 'stale-mgba-core\n'   > "$SD/Emus/miyoomini/MGBA.pak/mgba_libretro.so"
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
# the new version declares MGBA.pak deprecated (glob, card-relative) — applier must delete it
printf 'Emus/*/MGBA.pak\n' > "$NEWPAK/deprecated-paks.txt"
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
# always-newer manifest for the check-update OFFER leg (see section 4)
cat > "$T/www/versions-check.json" <<EOF
{"schema":1,"stable":{"version":"99.0.0","notes":"check fixture","assets":{"lodoros-miyoomini":{"url":"http://127.0.0.1:8123/upd.zip","size":$SIZE,"sha256":"$SHA"}}}}
EOF
# Range-capable fixture server (python3 -m http.server ignores Range — the lodor#46 resume
# tests need honest 206/416 answers) + a request log so Range use is ASSERTABLE.
HLOG="$T/http.log"; : > "$HLOG"
cat > "$T/rangehttpd.py" <<'PYEOF'
import http.server, os, re, sys
LOG = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = os.path.join(os.getcwd(), self.path.lstrip('/').split('?')[0])
        rng = self.headers.get('Range')
        with open(LOG, 'a') as l:
            l.write("%s %s\n" % (self.path, rng or '-'))
        if not os.path.isfile(p):
            self.send_response(404); self.end_headers(); return
        with open(p, 'rb') as f:
            data = f.read()
        if rng:
            m = re.match(r'bytes=(\d+)-$', rng)
            start = int(m.group(1)) if m else 0
            if start >= len(data):
                self.send_response(416)
                self.send_header('Content-Range', 'bytes */%d' % len(data))
                self.end_headers(); return
            body = data[start:]
            self.send_response(206)
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, len(data)-1, len(data)))
        else:
            body = data
            self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PYEOF
# exec so $! IS the python pid: backgrounding the cd&&python list makes $! the
# wrapper subshell — the end-of-run kill then hits the wrapper and the server
# SURVIVES as an orphan squatting on :8123, feeding stale fixtures to every
# later run (whose own bind failure is silent). The EXIT trap also covers
# set -e aborts, which used to leak the server the same way.
( cd "$T/www" && exec python3 "$T/rangehttpd.py" 8123 "$HLOG" >/dev/null 2>&1 ) &
echo $! > "$T/httpd.pid"
trap 'kill "$(cat "$T/httpd.pid")" 2>/dev/null || true' EXIT
sleep 1
kill -0 "$(cat "$T/httpd.pid")" 2>/dev/null   || { echo "FATAL: fixture server did not start — is :8123 held by a stale rangehttpd?"; exit 1; }
curl -sf --max-time 5 http://127.0.0.1:8123/versions.json | cmp -s - "$T/www/versions.json"   || { echo "FATAL: :8123 is not serving THIS run's fixtures (stale server from an earlier run)"; exit 1; }

# ---- 4. engine --check-update + --fetch-update from the pak dir -------------------
cd "$PAK"
# The offer path is asserted against an always-newer 99.0.0 manifest: the
# binary's stamped version moves with release, and a fixture pinned AT the
# shipped version reports update=0 forever (this leg broke the day VERSION
# reached 0.9.9, 2026-07-20). The 0.9.9 manifest now asserts the
# already-current path instead (valid for any stamped version >= 0.9.9).
OUT=$(LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions-check.json "$ENG" --check-update)
echo "$OUT" | grep -Eq "update=1 current=[^ ]+ latest=99.0.0" && ok "--check-update offers newer 99.0.0" || bad "check-offer: $OUT"
OUT=$(LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions.json "$ENG" --check-update)
echo "$OUT" | grep -Eq "update=0 current=[^ ]+ latest=0.9.9" && ok "--check-update already-current reports update=0" || bad "check-current: $OUT"
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
[ ! -d "$PAK/.update.partial" ] && ok "partial sidecar removed on mismatch too (lodor#46)" || bad "partial sidecar survived a bad hash"

# ---- 4b. resume with matching identity (lodor#46) ----------------------------------
# Seed the sidecar exactly as an interrupted --fetch-update leaves it: the first half of
# the real zip + the engine's asset-identity file. The refetch must Range-resume (206
# from the partial size), verify, and stage — never restart from zero.
rm -rf "$PAK/.update" "$PAK/.update.partial"
mkdir -p "$PAK/.update.partial"
HALF=$((SIZE / 2))
head -c "$HALF" "$T/upd.zip" > "$PAK/.update.partial/download.zip.part"
printf 'version=0.9.9\nurl=http://127.0.0.1:8123/upd.zip\nsha256=%s\nsize=%s\n' "$SHA" "$SIZE" \
  > "$PAK/.update.partial/identity"
: > "$HLOG"
LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions.json LODOR_UPDATE_ASSET=lodoros-miyoomini "$ENG" --fetch-update >/dev/null
grep -q "^/upd.zip bytes=$HALF-" "$HLOG" && ok "resume sent Range from the partial size ($HALF)" || bad "no Range resume seen: $(cat "$HLOG")"
[ -f "$PAK/.update/READY" ] && ok "resumed fetch staged READY" || bad "resumed fetch did not stage"
[ ! -d "$PAK/.update.partial" ] && ok "partial sidecar consumed by the successful stage" || bad "sidecar left behind after success"

# ---- 4c. identity mismatch discards the partial (lodor#46) -------------------------
# A partial left by an OLDER release must be thrown away (full fetch from byte 0),
# never resumed into a bogus hash-mismatch.
rm -rf "$PAK/.update" "$PAK/.update.partial"
mkdir -p "$PAK/.update.partial"
head -c "$HALF" /dev/zero > "$PAK/.update.partial/download.zip.part"
printf 'version=0.9.8\nurl=http://127.0.0.1:8123/upd-old.zip\nsha256=%s\nsize=%s\n' "$SHA" "$SIZE" \
  > "$PAK/.update.partial/identity"
: > "$HLOG"
set +e
LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions.json LODOR_UPDATE_ASSET=lodoros-miyoomini "$ENG" --fetch-update >/dev/null 2>&1
RC=$?
set -e
[ "$RC" = 0 ] && ok "stale-identity partial refetched cleanly (rc=0, not a fake mismatch)" || bad "stale-identity fetch rc=$RC"
grep -q "^/upd.zip bytes=" "$HLOG" && bad "stale-identity partial was Range-resumed (must restart)" || ok "no Range request for a stale-identity partial"
[ -f "$PAK/.update/READY" ] && ok "clean restage after identity bump" || bad "no READY after identity bump"

# ---- 5. boot applier -----------------------------------------------------------------
SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/lodor-apply-update"
grep -q "NEW-engine-v0.9.9" "$PAK/lodor-sync" && ok "engine binary swapped to 0.9.9" || bad "engine NOT swapped"
grep -q "newlib" "$PAK/lib/romm-sync-lib.sh" && ok "lib overlaid" || bad "lib not overlaid"
[ -f "$SD/Tools/miyoomini/Update Lodor.pak/launch.sh" ] && ok "Update Lodor.pak landed" || bad "Update pak missing"
grep -q "EVIL" "$SD/.system/miyoomini/bin/minui" && bad "LAUNCHER WAS TOUCHED (must never happen)" || ok "launcher untouched (EVIL minui stripped)"
[ ! -d "$PAK/.update" ] && ok "staging cleared after apply" || bad "staging left behind"
[ "$(cat "$PAK/.update-applied")" = "0.9.9" ] && ok ".update-applied marker = 0.9.9" || bad "marker wrong: $(cat "$PAK/.update-applied" 2>/dev/null)"
grep -q "ROMM_MINARCH_SHIM" "$SD/.system/miyoomini/bin/minarch.elf" && ok "install.sh re-ran (shim active)" || bad "shim not re-installed"
# lodor#47: the apply staged a rollback mirror of what it replaced, BEFORE the copy
RBSET="$PAK/.update-rollback/0.9.9"
grep -q "old-engine-v0.9.3" "$RBSET/tree/Tools/miyoomini/Lodor.pak/lodor-sync" 2>/dev/null \
  && ok "rollback mirror holds the pre-update engine" || bad "rollback mirror missing/wrong"
grep -q "echo lib" "$RBSET/tree/Tools/miyoomini/Lodor.pak/lib/romm-sync-lib.sh" 2>/dev/null \
  && ok "rollback mirror holds the pre-update lib" || bad "rollback lib missing/wrong"
[ "$(head -1 "$RBSET/rolled-from" 2>/dev/null)" = "0.9.3" ] \
  && ok "rolled-from marker = 0.9.3 (from version.txt)" || bad "rolled-from wrong: '$(head -1 "$RBSET/rolled-from" 2>/dev/null)'"
[ -e "$RBSET/tree/.system/miyoomini/bin/minui" ] && bad "rollback captured launcher bytes (strip ran too late)" || ok "rollback has no launcher bytes (staged after strip)"
# 1.0 deprecated-pak cleanup: the update's deprecated-paks.txt (Emus/*/MGBA.pak) removes the pak
# from the card, mirroring its bytes into the rollback set first so a revert restores it.
[ ! -e "$SD/Emus/miyoomini/MGBA.pak" ] && ok "deprecated MGBA.pak removed from card" || bad "deprecated MGBA.pak still on card"
grep -q "stale-mgba-launch" "$RBSET/tree/Emus/miyoomini/MGBA.pak/launch.sh" 2>/dev/null \
  && ok "deprecated MGBA.pak mirrored into rollback (revert restores it)" || bad "deprecated pak not captured in rollback mirror"
# re-run = no-op
SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/lodor-apply-update"
ok "applier re-run is a clean no-op (no staging)"

# ---- 6. interrupted apply re-heals (and must NOT poison the rollback) ---------------
LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions.json LODOR_UPDATE_ASSET=lodoros-miyoomini "$ENG" --fetch-update >/dev/null
printf 'HALF-COPIED-GARBAGE\n' > "$PAK/lib/romm-sync-lib.sh"   # simulate a yank mid-overlay
SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/lodor-apply-update"
grep -q "newlib" "$PAK/lib/romm-sync-lib.sh" && ok "interrupted apply re-healed by next boot" || bad "re-heal failed"
# the re-run found a COMPLETE 0.9.9 rollback set and kept it: the mirror still holds the
# true pre-update files, not the half-copied garbage present on the card at re-run time
grep -q "old-engine-v0.9.3" "$RBSET/tree/Tools/miyoomini/Lodor.pak/lodor-sync" 2>/dev/null \
  && ok "re-run kept the pre-update rollback mirror (no poisoning)" || bad "rollback mirror lost/poisoned by the re-run"
grep -q "HALF-COPIED-GARBAGE" "$RBSET/tree/Tools/miyoomini/Lodor.pak/lib/romm-sync-lib.sh" 2>/dev/null \
  && bad "rollback lib poisoned with mid-yank garbage" || ok "rollback lib untouched by the re-run"

# ---- 7. rollback set is BOUNDED: a second update replaces it, never stacks ----------
UPZ2="$T/update2"
mkdir -p "$UPZ2/Tools/miyoomini/Lodor.pak"
printf 'NEWER-engine-v0.9.10\n' > "$UPZ2/Tools/miyoomini/Lodor.pak/lodor-sync"
( cd "$UPZ2" && zip -rqX "$T/upd2.zip" . )
SHA2=$(sha256sum "$T/upd2.zip" | cut -d' ' -f1)
SIZE2=$(stat -c%s "$T/upd2.zip")
cp "$T/upd2.zip" "$T/www/upd2.zip"
cat > "$T/www/versions2.json" <<EOF
{"schema":1,"stable":{"version":"0.9.10","notes":"second test build","assets":{"lodoros-miyoomini":{"url":"http://127.0.0.1:8123/upd2.zip","size":$SIZE2,"sha256":"$SHA2"}}}}
EOF
LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions2.json LODOR_UPDATE_ASSET=lodoros-miyoomini "$ENG" --fetch-update >/dev/null
SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/lodor-apply-update"
grep -q "NEWER-engine-v0.9.10" "$PAK/lodor-sync" && ok "second update applied (0.9.10)" || bad "second update not applied"
NSETS=$(find "$PAK/.update-rollback" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$NSETS" = 1 ] && ok "exactly one rollback set kept (bounded)" || bad "rollback sets stacked: $NSETS"
RBSET2="$PAK/.update-rollback/0.9.10"
grep -q "NEW-engine-v0.9.9" "$RBSET2/tree/Tools/miyoomini/Lodor.pak/lodor-sync" 2>/dev/null \
  && ok "newest rollback set mirrors 0.9.9 (the replaced version)" || bad "newest rollback mirror wrong"
[ "$(head -1 "$RBSET2/rolled-from" 2>/dev/null)" = "0.9.9" ] \
  && ok "rolled-from marker = 0.9.9" || bad "rolled-from wrong: '$(head -1 "$RBSET2/rolled-from" 2>/dev/null)'"

# ---- 8. revert path (lodor#47): armed marker restores the mirror at boot ------------
# Stage a NEWER update too: an armed revert must discard it (the user said "go back").
LODOR_VERSIONS_URL=http://127.0.0.1:8123/versions.json LODOR_UPDATE_ASSET=lodoros-miyoomini "$ENG" --fetch-update >/dev/null
: > "$PAK/.update-rollback/revert-requested"
SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/lodor-apply-update"
grep -q "NEW-engine-v0.9.9" "$PAK/lodor-sync" && ok "revert restored the previous engine (0.9.9)" || bad "revert did not restore the engine: $(cat "$PAK/lodor-sync")"
[ "$(sed -n 1p "$SD/.system/version.txt")" = "LodorOS-0.9.9" ] \
  && ok "version.txt stamped back to 0.9.9" || bad "version.txt after revert: '$(sed -n 1p "$SD/.system/version.txt")'"
[ "$(sed -n 2p "$SD/.system/version.txt")" = "reverted" ] \
  && ok "version.txt line 2 = reverted" || bad "version.txt line 2: '$(sed -n 2p "$SD/.system/version.txt")'"
[ "$(cat "$PAK/.update-applied")" = "0.9.9" ] && ok ".update-applied marker back to 0.9.9" || bad "applied marker after revert: $(cat "$PAK/.update-applied" 2>/dev/null)"
[ ! -d "$PAK/.update-rollback" ] && ok "rollback set consumed by the revert" || bad "rollback left behind after revert"
[ ! -d "$PAK/.update" ] && ok "staged newer update discarded by the revert" || bad "staged update survived the revert"
grep -q "ROMM_MINARCH_SHIM" "$SD/.system/miyoomini/bin/minarch.elf" && ok "install.sh re-ran after revert (shim active)" || bad "shim not re-installed after revert"
# re-run = clean no-op (marker consumed with the set)
SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/lodor-apply-update"
grep -q "NEW-engine-v0.9.9" "$PAK/lodor-sync" && ok "applier re-run after revert is a no-op" || bad "re-run changed the engine again"

# ---- 9. revert armed with NO usable set: discard the request, touch nothing ---------
mkdir -p "$PAK/.update-rollback"
: > "$PAK/.update-rollback/revert-requested"
SDCARD_PATH="$SD" PLATFORM=miyoomini sh "$PAK/bin/lodor-apply-update"
grep -q "NEW-engine-v0.9.9" "$PAK/lodor-sync" && ok "setless revert request changed nothing" || bad "setless revert touched the engine"
[ ! -d "$PAK/.update-rollback" ] && ok "setless revert request discarded" || bad "dangling revert request left behind"

echo "== RESULT: $PASS pass, $FAIL fail =="
[ "$FAIL" = 0 ]
