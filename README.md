# LodorOS

A self-hosted, RomM-backed console OS for the **Miyoo Mini Flip**. LodorOS is a fork of
[MinUI](https://github.com/shauninman/MinUI) that turns the Flip into a front-end for your own
[RomM](https://github.com/rommapp/romm) server: your entire library shows up as zero-byte stubs,
games download the moment you launch them, and saves sync back to the server around every session —
all driven by the CGO-free [Lodor engine](https://github.com/lodordev/lodor).

It's the flagship build of the Lodor project (the engine and its per-CFW ports live in separate
repos).

## What it does

- **Onboard to your server** — a native first-run wizard: Wi-Fi → server address → 8-digit RomM pair
  code → device name. No admin credentials live on the device; a scoped client token is all it keeps.
- **Transparent library** — every game in RomM appears as a stub. Tap one and the real ROM streams
  down (with a native progress bar), verifies, and launches. Multi-disc PS1 is handled (per-disc fetch
  + generated `.m3u`).
- **Save sync** — saves push to RomM (additive, versioned) and the newest pulls back, with a pending
  queue for writes made offline. A background daemon flushes that queue on its own — even off charge,
  the moment there's something to upload — so progress reaches the server without a manual sync.
- **Flashback** — every save you've made is a point on a per-game timeline. Scrub it and restore any
  past point with one button, from the per-game menu *or* the in-game pause menu; restoring drops you
  straight back into that moment. The current save is always preserved first, so a flashback can never
  lose progress.
- **Continue** — a cross-device "most recently played" tile at the top of the library: pick up the game
  you last touched, on this device or another.
- **Native menus** — library, collections, search, sync, Flashback, and per-game actions are rendered
  natively in the launcher (no foreign UI toolkit).

## Layout

```
launcher/
  minui.c        LodorOS launcher — our fork of MinUI's minui.c (native menus, onboarding, sync UI)
  minarch.c      our fork of MinUI's libretro frontend — adds in-game Flashback to the pause menu
  makefile       built within MinUI's build system
paks/
  Lodor.pak/ the integration pak: Wi-Fi/clock/sync library, the minarch launch shim,
                 the periodic sync daemon, install/uninstall, CA bundle
  Emus/          expanded-system emulator paks (launch.sh + default.cfg + libretro core):
                 Sega CD, FDS, SG-1000, Arcade/Neo Geo (FBN), WonderSwan/Color, Atari Lynx,
                 32X, PC Engine, Master System, Game Gear, Virtual Boy, NGP/NGPC, Pokémon mini,
                 PICO-8, Super Game Boy, and more — beyond MinUI's built-in core set.
                 (FBN.pak ships its definition but NOT the FBNeo core — see CREDITS.)
  Reset WiFi.pak, Reboot.pak, Toggle 560p.pak   Lodor utility paks
  ADBD, Bootlogo, Clock, Files, IP, Input, Remove Loading, Wifi   bundled community/MinUI
                 tool paks (their own LICENSE files included) — see CREDITS
config.json.example   server + paired token (copied to the pak's config.json on device)
wifi.txt.example      SD-root Wi-Fi credentials (Miyoo Mini colon format)
```

The sync **engine** (`lodor-sync`) is a build artifact of
[lodordev/lodor](https://github.com/lodordev/lodor) and is **not** committed here — build it static for
ARMv7 and place it in `Lodor.pak/`.

## Build & install

- `launcher/minui.c` is built against MinUI's toolchain for the `miyoomini` platform (it replaces
  MinUI's `minui.elf`).
- Build the Lodor engine for ARMv7 and drop the binary into the pak; copy the pak under
  `Tools/miyoomini/` on the card.
- Boot, run the onboarding wizard, and your library mirrors in.

## Status

Built and daily-driven on the Miyoo Mini Flip. Onboarding, the stub-mirror library, fetch-on-launch
(incl. multi-disc PS1), save sync, the Continue tile, background sync, the Wi-Fi keep-up + auto-recovery
rearchitecture, and Flashback (both the library menu and the in-game pause menu) are verified on
hardware. Known limitation: Flashback is currently **online** — its timeline is read from the server,
so a save made offline becomes flashback-able only after it syncs up (an offline local cache is on the
roadmap).

## License & credits

LodorOS is a MinUI fork used with the author's permission; our additions are MIT. See
[LICENSE](LICENSE) and [CREDITS.md](CREDITS.md). LodorOS ships **no** BIOS, firmware, or game
content — you supply your own, on your own server.
