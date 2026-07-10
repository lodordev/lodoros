# LodorOS 0.9.7.7

UX & sync-alignment release — the biggest usability pass Lodor has had.

## What changed
- **Honest setup errors:** the wizard now tells you when the *server* couldn't be reached instead of blaming your pairing code, warns when a token is missing sync permissions, says where pairing codes come from, and confirms whether the device registered. Knulli devices finally get Knulli instructions (not muOS ones).
- **Less typing, better defaults:** device names auto-detect from the hardware; the pairing screen carries guidance; the menu shows your version offline and flashes "Updated to X" once after an update.
- **Deleted saves stay deleted:** a save you delete on-device no longer resurrects from the server on the next sync — unless another device has genuinely newer progress, which still arrives. Explicit restore always works.
- **Resumable downloads:** interrupted game downloads now resume where they left off instead of restarting from zero.
- **Play sessions & server shelves:** finished play sessions report to RomM's first-class play-sessions API, and RomM's smart/virtual collections appear as shelves automatically (on servers that support them; silently skipped otherwise).
- **Android:** you can change the server after setup; launch failures show a real screen (not a vanishing toast) with the reason; sync failures stay visible until dismissed and appear on the home screen; setup supports going back a step; plainer language throughout.
- **NextUI:** library refresh/first seed shows live progress; failure messages name the real cause (never "check Wi-Fi" for a server problem); errors wait to be dismissed; a welcome page explains what setup will do; store changelogs are written for humans.
- **LodorOS:** Tools → Reset WiFi works again (it was dead); updates show what's new and check card space/charge before downloading; Tailscale menu entries never silently do nothing (and never wipe your login as a fallback).

## Install / update
Existing devices: **Update Lodor** (LodorOS) or the store update (NextUI/muOS/Knulli). New installs: flash the full-card zip, eject cleanly, boot. Config, saves, and downloaded ROMs are preserved.
