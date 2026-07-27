# LodorOS 1.0.0-alpha2

**Second 1.0 alpha** (engine + LodorOS fork share this stamp). Early, on purpose: expect rough edges and report them. This one is about the launch experience: a slow download now shows live progress instead of a frozen screen, and records what it did so a slow one can be explained. Launch card everywhere, mGBA fleet-wide, honest updates for retired lanes.

## What changed
- **Launch card on the Miyoo Mini Flip (SSD202D).** The interactive launch card now renders *and
  takes input* on the Mini Flip. It presents through the SDL 1.2 helper — raw `/dev/fb0` is a dead
  scanout surface on this panel — and because that SDL exclusively grabs the keypad, the helper
  forwards its key presses to the card instead of letting a second reader starve. The redundant
  native "check the server?" walkthrough is retired: the Go wizard card is now the single
  pre-launch UI on every lane. Ships with a one-boot SDL scanout self-test (Tools → SDL Test).
- **Offline storage report.** `lodor-sync --storage-report` prints a per-volume download-cache view with no network round-trip (argosy-steal, engine-only).
- **Launch card v2 on every lane.** The pre-launch card (download progress, save pull, session
  bracket) now shows consistently across LodorOS, muOS, Knulli, and NextUI — including pre-launch
  hooks that always render instead of flashing past. On Android it gains saves/states sub-screens.
- **GBA now runs on mGBA fleet-wide.** Every lane ships the mGBA core as the GBA default for
  cross-device save-state compatibility (states made on one device restore on another).
- **Android: one-tap frontend setup.** The app auto-configures ES-DE, Cocoon (recognized layouts,
  with an honest fallback and a layout report), and Daijishō (staged import files) — no manual
  per-system emulator wiring.
- **Android reliability.** Session-end is patient behind slow cold starts (no premature save push),
  Cocoon detection is fault-isolated and off the UI thread, and frontend-worker failures are
  recorded instead of silently swallowed.
- **OnionOS returns as a shipping lane.** The no-fork Lodor App for the Miyoo Mini Plus on stock
  OnionOS builds and releases with full lane parity again (`Lodor-OnionOS-<version>.zip`).
  Stub-mirror is proven on hardware; on-device validation of download-on-launch + save sync is
  still pending.
- **spruceOS joins as a shipping lane.** The no-fork Lodor App for spruceOS (Miyoo A30, Mini
  Flip) builds and releases with full lane parity (`Lodor-spruce-<version>.zip`). On-device
  validation (RAM headroom on 128MB hardware, battery) is still pending — flash accordingly.
- **Multi-disc fix (NextUI):** download-on-launch no longer reports a false failure on multi-disc
  games.
- **NextUI sync reliability (TrimUI).** Fixed a crash that could abort save/state sync mid-operation on the TrimUI Smart Pro / Brick (verified on-device); and a sync failure now reports its real cause instead of a misleading "Wi-Fi not connected."
- **Input fixes:** correct A/B mapping on TrimUI (tg5040) and better controller detection on H700
  devices.
- **Honest updates for retired lanes.** Update checks are freeze-aware per asset: a device whose
  lane no longer publishes updates reports "up to date" instead of offering a stale download. The
  Miyoo A30 (`my282`) LodorOS lane is retired as of this release — existing A30 cards keep working
  (including save sync) but no longer receive LodorOS updates.

## Install / update
Existing devices: **Update Lodor** (LodorOS) or the store update (NextUI/muOS/Knulli). Config,
saves, and ROMs are preserved. Android: install the new APK over the old one.
