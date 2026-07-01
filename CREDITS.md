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
