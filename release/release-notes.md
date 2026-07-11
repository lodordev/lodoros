# LodorOS 0.9.8

Quality-of-life release: sync you can see, updates you can trust.

## What changed
- **"Last synced: 2h ago" everywhere.** Every device now shows when it last successfully synced (menu on muOS/Knulli/NextUI, home screen on Android) — stamped only on verified server contact, never guessed.
- **Long operations can be stopped.** Sync, downloads, and BIOS fetches show live progress and stop honestly when you press B.
- **Updates resume and can be undone.** Interrupted update downloads continue where they stopped; every installed update keeps a rollback copy, and a "revert last update" option appears when one exists.
- **Android checks for updates** (once a day, silently) and shows an "Update available" row; optional "notify me if syncing fails" alert — off by default, errors only, never chatty.
- **Consistency + docs:** the same action now has the same name on every device; cards ship a plain-text guide for pre-configured setup; Knulli uninstall instructions name the actual files.

## Install / update
Existing devices: **Update Lodor** (LodorOS) or the store update (NextUI/muOS/Knulli). Config, saves, and ROMs are preserved.
