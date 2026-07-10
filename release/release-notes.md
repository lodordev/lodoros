# LodorOS 0.9.7.8

Fix release for the Miyoo Mini family, same-day from hardware testing.

## What changed
- **The updater is visible again on Miyoo Mini devices.** 0.9.7.7's new update screens could black out the display on the Mini Plus until a power cycle (the underlying update still worked). Update and Reset-WiFi screens now use the platform's safe renderer — status images plus a single press-A-to-close message — and can no longer wedge the screen.
- **Staged updates now always apply.** Cards set up before mid-June could download updates that never installed at reboot (the boot hook was missing and nothing repaired it). The background sync service now repairs the hook automatically and applies any already-downloaded update in the same boot.

## Install / update
Existing devices: **Update Lodor** (LodorOS) or the store update (NextUI/muOS/Knulli). If your Mini Plus shows a black screen when you open Update Lodor (the 0.9.7.7 bug this release fixes): wait ~30 seconds — the download completes behind the blank screen — then power off and on; the update installs at boot and the screens are fixed from then on.
