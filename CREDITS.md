# Credits

LodorOS builds directly on the work of others in the retro-handheld and RomM communities.

- **[MinUI](https://github.com/shauninman/MinUI)** by Shaun Inman — the minimalist frontend LodorOS is
  forked from. The launcher in `launcher/` is derived from MinUI's `minui.c`; copyright remains with
  its author, used and modified with permission.
- **[Lodor engine](https://github.com/lodordev/lodor)** — the CGO-free RomM sync engine that powers
  the library, downloads, and save sync. MIT.
- **[RomM](https://github.com/rommapp/romm)** — the self-hosted ROM library manager LodorOS is a
  front-end for.
- **[Grout](https://github.com/rommapp/grout)** — RomM's official handheld client, the behavioral and
  wire-protocol reference while building the engine. MIT.
- **[Allium](https://github.com/goweiwen/Allium)** — MIT, Copyright (c) 2025 Wei Wen Goh. Design
  reference for LodorOS 0.9.4: the per-game emulator override with layered resolution (per-game
  choice checked before the console default) and save-state screenshot previews reused as
  continue/switcher art. Designs adopted with attribution per the MIT license; no Allium code
  is included.
- **[NextUI](https://github.com/LoveRetro/NextUI)** — GPL-3.0. Behavior-only inspiration for four
  LodorOS features: async thumbnail loading, transient notification toasts (with an offline
  variant), an in-game cheats menu, and a user-swappable CJK-capable UI font. Early builds ported
  code for these from NextUI; all four have since been excised and replaced with independent
  clean-room implementations written from behavior specifications — no NextUI source code is
  included or ported. The cheats support in `minarch` is built solely from the publicly documented
  RetroArch `.cht` file format and the standard libretro cheat API
  (`retro_cheat_reset`/`retro_cheat_set`).

## Bundled paks

LodorOS includes several community/MinUI-ecosystem tool paks for a complete out-of-box experience
(`ADBD`, `Bootlogo`, `Clock`, `Files`, `IP`, `Input`, `Remove Loading`, `Wifi`). These are the work of
their respective authors and retain their own `LICENSE`/`README` files where included. They are
redistributed here unmodified for convenience; credit and rights remain with their authors.

## Emulator cores

The `Emus/` paks reference [libretro](https://www.libretro.com/) cores (mGBA, Mednafen PCE/VB/WonderSwan/
Supafaust, Handy, RACE, PokeMini, FAKE-08, etc.), which are bundled under their respective open-source
licenses (GPL / MPL / permissive).

**Not bundled — FBNeo.** The Arcade/Neo Geo pak (`FBN.pak`) keeps its launch definition but **not** the
`fbneo_libretro.so` core: FBNeo is released under a **non-commercial** license, so we don't redistribute
it. Supply your own `fbneo_libretro.so` to enable arcade/Neo Geo.

Trademarks and product names belong to their respective owners. LodorOS ships **no** BIOS, firmware,
or copyrighted game content.
