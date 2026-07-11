# LodorOS 0.9.7.10

Stability release — a full-codebase bug sweep with fixes across every lane.

## What changed
- **Multi-disc fixes:** playlists written on Windows (CRLF line endings) or carrying `#` comments no longer block fully-downloaded games from launching; Android now completes multi-disc sets like every other platform (next-disc fetch on launch, background prefetch while charging); interrupted disc downloads resume instead of restarting.
- **Sync reliability:** background sync can no longer be interrupted mid-transfer by a second sync starting (and a busy sync is now reported honestly instead of as a Wi-Fi failure); user profiles created on Tailscale/Cloudflare setups now inherit the connection route and follow server-address changes; "no save yet" is no longer reported as "couldn't reach the server."
- **Durability:** profile selection, settings, and ES-DE configuration files now survive power loss mid-write; restoring a save that fails now says so instead of pretending it worked.
- **Android launch fixes:** rapid back-to-back game launches no longer race each other (stale downloads, wrong-game launches, missed save pushes, and a crash on backing out mid-check are all fixed).

## Install / update
Existing devices: **Update Lodor** (LodorOS) or the store update (NextUI/muOS/Knulli). Config, saves, and ROMs are preserved.
