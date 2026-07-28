# LodorOS 1.0.0-alpha3

**Fix release.** One bug, found by a user on an RG35XXH and present in every release since 0.9.8.1: the setup wizard was silently cutting off any line of text too wide for the canvas it drew on.

## What changed
- **The setup wizard no longer truncates text.** `Canvas.DrawText` clips out-of-bounds glyphs
  silently, and nothing in the shared chrome measured a string before drawing it — so the
  pairing-code hint rendered as "In RomM on your computer: Settings > De", the keyboard's
  control legend as "...B: delete  BAC", and long ROM names were chopped mid-word in the Game
  Manager title. This was never an aspect-ratio problem: it reproduced identically at 720x480,
  the panel the wizard was designed on. Titles now step down a scale before ellipsizing, the
  footer legend wraps to a second line rather than hiding controls, the keyboard's hint and
  prompt wrap, the text field scrolls from the right so the caret survives a long URL, and the
  key grid squeezes its padding to stay above the footer.
- **The wizard composes at your panel's real resolution.** Every screen used to be drawn on a
  fixed 720x480 canvas and scaled to fit, which on a 640x480 device meant a soft, letterboxed
  UI for no reason. It now sizes to the framebuffer: crisp 1:1 text and full-height layout on
  every panel.

Reported as lodor-muos#2. Thanks to the reporter.

## Install / update
Existing devices: **Update Lodor** (LodorOS) or the store update (NextUI/muOS/Knulli). Config,
saves, and ROMs are preserved. Android: install the new APK over the old one.
