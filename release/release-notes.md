# LodorOS 0.9.7.9

Multi-disc, done right — plus self-signed server support.

## What changed
- **Multi-disc games start after one disc.** Launching a multi-disc game now downloads only the disc you need and gets you playing; the rest arrive quietly in the background while the device charges. Reach a disc swap before it's fetched? Relaunch grabs the next disc. Games you never launch cost zero card space. (Previously a 4-disc game downloaded everything before you could start.)
- **Self-signed HTTPS servers can now onboard from the device.** If your server's certificate can't be verified, the setup wizard says so plainly and offers "Trust this server" — only for your own server — instead of failing with a misleading error.
- **The version on screen is now the version on the card.** Updates stamp the system version display, which previously showed the card's original version forever.

## Install / update
Existing devices: **Update Lodor** (LodorOS) or the store update (NextUI/muOS/Knulli). Config, saves, and ROMs are preserved.
