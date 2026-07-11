# LodorOS 0.9.7.11

Multi-disc hotfix release.

## What changed
- **Multi-disc games launch after the first disc again.** 0.9.7.9 introduced disc-1-first downloads, but the launcher refused to start a game while later discs were still placeholders — each launch downloaded one more disc and never played. The game list file now tracks exactly the discs on your card (growing as the background prefetch completes the set), so you play immediately. Part-downloaded games are migrated automatically.
- **Pressing B during a download now actually cancels it.** The partial file is kept, so resuming later continues where it stopped.
- **Miyoo Mini update screens fixed:** no more corrupted image band; messages wrap instead of running off the screen.

## Install / update
Existing devices: **Update Lodor** (LodorOS) or the store update (NextUI/muOS/Knulli). Config, saves, and ROMs are preserved.
