# LodorOS 0.9.7.6

Security & reliability release.

## What changed
- **Uninstall now clears your saved server credentials** (NextUI): removing Lodor wipes your RomM pairing token from the card instead of leaving it behind. Reinstalling asks you to pair again — as it should.
- **Signed updates (new):** update manifests are now cryptographically signed. This release ships signature verification in monitoring mode — the groundwork toward devices refusing any update that isn't signed by Lodor.
- **Save-sync reliability:** saves queued while offline now upload correctly on reconnect, and an expired pairing is clearly surfaced (prompting you to re-pair) instead of failing quietly.
- **Hardening:** input-validation and file-durability improvements across the engine, launcher, and release pipeline.

## Install / update
Existing devices: **Update Lodor** (LodorOS) or the store update (NextUI/muOS). New installs: flash the full-card zip, eject cleanly, boot. Config, saves, and downloaded ROMs are preserved.
