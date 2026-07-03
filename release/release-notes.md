# LodorOS 0.9.3 (beta)

Your self-hosted RomM library, on your handheld. LodorOS is a MinUI fork that turns a
retro handheld into a thin client for your own RomM server — your whole collection appears
in the menu as lightweight stubs with box art, games download on demand, and saves sync
both ways. Nothing is exposed to the open internet.

## What's new in 0.9.3 — upgrade recommended

Tailscale reliability (capable devices):
  - The tunnel now starts at boot and before every sync and download. Previously only
    the sign-in flow started it, so after a reboot a Tailscale-only server could be
    unreachable until you re-ran onboarding.
  - New "Reconnect" action in the Tailscale tool: restarts a wedged tunnel from your
    saved login. It never asks you to re-authenticate.
  - The connection check now reports which path it actually probed (Tailscale,
    Cloudflare Access, or LAN), so a failure points at the real problem instead of a
    generic "server unreachable".

Save-sync robustness (every platform):
  - Whether to pull a save is now decided by content lineage, not file timestamps —
    a wrong or reset device clock can no longer cause the wrong save to win.
  - Your unpushed progress can never be overwritten: a local save that hasn't reached
    the server is never replaced by a downloaded one.
  - Being offline or unable to reach the server now produces honest, specific errors
    instead of misleading failure messages.

Safety:
  - The library mirror now records exactly what it created and will never touch a file
    it didn't create — pruning and collection changes cannot affect files you put on
    the card yourself.

Housekeeping:
  - Internal cleanup and small fixes across the shell tooling; the sync engine is
    rebuilt on every platform.

Upgrading from 0.9.x: extract this zip over your existing card. Your configuration,
device pairing, and saves are preserved.

This is an early public release. It is a CLIENT for your own RomM server, not a
plug-and-play "download games" OS. BYOB — no BIOS/firmware is ever bundled.

## Supported devices
  Miyoo Mini Plus (miyoomini) · Miyoo A30 (my282) · Miyoo Flip V2 (my355)
  Anbernic H700 family — RG35XX Plus / H, RG34XX, RG28XX, RGcubeXX, RG40XX (rg35xxplus)
  Powkiddy RGB30 (rgb30)
  The same download boots every supported device. TrimUI is served separately by Lodor-NextUI.

## Install (see the wiki for full steps)
  - Miyoo devices: format a card FAT32, extract this zip onto it, insert.
  - Anbernic H700: TF2 = FAT32 card with this zip extracted (slot 2); TF1 = your STOCK
    Anbernic card with rg35xxplus/dmenu.bin copied to its root (slot 1) — never reformat it.
  - Powkiddy RGB30: flash the Moss .img to the OS card; put a FAT32 card with this zip
    extracted in the game slot.

## Reaching your RomM server
  Tailscale (capable devices), Cloudflare Access service token (any device, incl. the
  Mini Plus), or plain LAN. See the wiki. Note (0.9): Cloudflare Access is configured by
  editing config.json for now — a guided onboarding mode is planned.

## Known limitations (0.9)
  - Requires a self-hosted RomM server.
  - Miyoo Mini Plus is Cloudflare-only (128 MB can't run Tailscale).
  - H700 heavy emulators (N64/Dreamcast) run the device's stock Anbernic RetroArch —
    stock firmware must be present; BIOS-dependent systems (Dreamcast) are BYOB.
    Dreamcast wants GDI or v4 CHD images (v5 CHD unsupported). PSP is not supported
    on H700 as of 0.9.2.
  - No proprietary emulators are bundled — bring your own where you want them.

## Credits
  Built on MinUI (Shaun Inman). Save-sync lineage credits Grout. H700 heavy-emulator
  approach credits ryanmsartor. Thanks to RomM, Tailscale, and Cloudflare.

Verify your download against the published SHA256 checksum before flashing.
