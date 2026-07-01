# LodorOS 0.9.0 (beta)

Your self-hosted RomM library, on your handheld. LodorOS is a MinUI fork that turns a
retro handheld into a thin client for your own RomM server — your whole collection appears
in the menu as lightweight stubs with box art, games download on demand, and saves sync
both ways. Nothing is exposed to the open internet.

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
  - H700 heavy emulators (N64/Dreamcast/PSP) run the device's stock Anbernic RetroArch —
    stock firmware must be present; BIOS-dependent systems (Dreamcast) are BYOB.
  - No proprietary emulators are bundled — bring your own where you want them.

## Credits
  Built on MinUI (Shaun Inman). Save-sync lineage credits Grout. H700 heavy-emulator
  approach credits ryanmsartor. Thanks to RomM, Tailscale, and Cloudflare.

Verify your download against the published SHA256 checksum before flashing.
