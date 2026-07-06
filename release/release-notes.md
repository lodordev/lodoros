# LodorOS 0.9.6 (beta)

Your self-hosted RomM library, on your handheld. LodorOS is a MinUI fork that turns a
retro handheld into a thin client for your own RomM server — your whole collection appears
in the menu as lightweight stubs with box art, games download on demand, and saves sync
both ways. Nothing is exposed to the open internet.

## Supported devices — the Miyoo fleet

LodorOS supports **Miyoo devices**:

| Device | Platform |
|---|---|
| Miyoo Mini Plus / V2 / V4 / Mini Flip | `miyoomini` |
| Miyoo A30 | `my282` |
| Miyoo Flip V2 | `my355` |

**Have an Anbernic H700 device (RG35XX/RG34XX/RG40XX families)?** Use **Lodor for muOS** —
the same RomM sync engine as a native muOS app, no custom firmware flash needed.
**Have a TrimUI Brick / Smart Pro?** Use **Lodor for NextUI** — the same engine as a NextUI pak.
One project, one sync engine, delivered the way each device family does it best.

## New in 0.9.6

- **Update from the device.** A new "Update Lodor" tool checks for, downloads, and
  stages LodorOS updates; they apply safely on the next boot. Interrupted updates
  self-heal. Nothing ever updates without you asking.
- **Tailscale QR sign-in no longer times out on you.** The sign-in screen now waits as
  long as you need (with a "keep waiting?" checkpoint every 5 minutes) instead of
  silently tearing down a pending sign-in at 2 minutes, and failures are logged
  honestly as cancelled vs timed out.
- **Flip V2 (my355) Wi-Fi bring-up fixes** — more reliable radio/association handling
  on first setup and after reboots.
- **Flip V2 standalone emulators fixed** (N64, and the same treatment for Dreamcast and
  PSP): they now run at full performance clock instead of the 600 MHz menu clock, and
  N64 gains proper controls — MENU taps pause, holding MENU exits cleanly with your
  save pushed, and closing the lid sleeps the game (2 minutes closed = clean auto-exit).
- **Save sync self-heals device pairing.** A card set up outside the wizard (preseeded
  or cloned) now registers itself with your RomM server on first sync instead of
  silently never syncing saves.

Known issues:
- On Dreamcast and PSP (Flip V2), the MENU button behavior inside the emulator is
  not yet audited — it may quit the game instead of pausing. N64 is fixed; DC/PSP
  clock fixes are included but were not yet validated on hardware in this release.

## Highlights

Sync engine:
  - Saves sync by **content lineage, not timestamps** — a wrong or reset device clock can
    never cause the wrong save to win, and unpushed local progress is never overwritten.
  - Full RomM device-sync integration: uploads and downloads are attributed to your device
    on the server, so RomM's save timeline knows what's where.
  - Favorite / rating / status set on-device sync back to RomM.
  - Multi-disc games download and assemble automatically (.m3u, in-folder layout).
  - RetroAchievements, playtime tracking, and cross-device Recently Played via RomM.

Launcher:
  - Missing-BIOS games fail with an honest error pointing at Sync → Download BIOS,
    instead of a silent black screen.
  - Box art from your RomM covers; per-system quality dots; game switcher with
    save-state previews; cheats support.
  - Tailscale built in (capable devices): QR sign-in, auto bring-up at boot and before
    every sync — your server never needs to be exposed to the internet.

Hardening:
  - All card writes are atomic (FAT32-safe temp+rename+fsync) — a yanked card or dead
    battery mid-write can no longer corrupt configs or saves.
  - Bounds-safe launch paths; ROMs with brackets in the filename sync correctly.

## Requirements

- A RomM server, version **4.8.0 or newer**.
- A supported Miyoo device (above) with Wi-Fi.

## Install / Upgrade

Fresh install: extract this zip to a clean SD card, insert, boot.
Upgrading from any 0.9.x: extract this zip over your existing card. Your configuration,
device pairing, and saves are preserved.

## Licenses

This zip bundles compiled libretro emulator cores; each remains under its own license —
see CORE-LICENSES.txt for the full list and source links.

This is an early public release. It is a CLIENT for your own RomM server, not a source
of games. Report bugs on the LodorOS repository.
