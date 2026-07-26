# xarch-cert — cross-architecture save-state certification harness (D8)

Minimal libretro runner proving whether a core's save state written on one CPU
architecture loads and emulates IDENTICALLY on another. Each per-core pass
earns a D8 whitelist entry (armhf ↔ arm64), unlocking Handoff across the
Mini Flip / Mini Plus / A30 (armhf) ↔ RG40XXV / Brick / my355 (arm64) split.

Method (all off-hardware; docker platform containers + qemu binfmt):
1. gen:     arch A runs the real core + real rom N frames, serializes.
2. loadrun: arch B unserializes that state, runs N MORE frames, serializes.
3. Verdict: arch A's own continuation vs arch B's must match. Compounding
   divergence = FAIL. A fixed inert byte-island = investigate, then pass/fail.

First result (2026-07-07, gambatte @ LodorOS pin 9d923816, armhf+arm64 builds
from the same source, Adventures of Lolo GB rom, 120+120 frames, BOTH
directions): unserialize accepted; trajectories byte-identical except a fixed
15-byte region = the `gpal` chunk serializing RAW HEAP POINTERS (32 vs 64-bit,
visibly 0x4000xxxx vs 0x55xxxxxxxx) — garbage on any reload by construction,
rebuilt by the core — plus one bool-encoding byte (0x00 vs 0xff, near the
`ime` chunk) flagged for a gambatte-source look before final certification.
Verdict: PROVISIONAL PASS. Still owed before the whitelist entry ships:
bool-byte source check, a CGB rom repeat, longer runs, more roms, and one
on-hardware confirmation. Knulli's OWN gambatte build joins the matrix when
the RG40XXV is next online (its .so is Batocera-built, not ours).

Run notes: docker images must be pulled per-arch EXPLICITLY (arm32v7/debian,
arm64v8/debian) — a cached `debian` tag silently runs the wrong arch (burned
us: "wrong ELF class"). qemu binfmt via multiarch/qemu-user-static --reset.

## Full fleet cross-bitness results (2026-07-07, armhf↔arm64, LodorOS pinned cores)

Protocol: gen a state on armhf, load+run 300f on arm64, compare trajectories;
divergent cores re-run at 900f to distinguish inert byte-islands from real
emulation desync (desync compounds, inert stays constant).

| Core | System(s) | Verdict | Evidence |
|---|---|---|---|
| fceumm | NES | **PASS** | trajectories byte-identical (0 diff) |
| gambatte | GB, GBC | **PASS** | only the inert gpal pointer island (15B, constant) |
| picodrive | GG, SMS, MegaDrive | **PASS** | 3 inert bytes, IDENTICAL at 300f and 900f |
| gpsp | GBA | **FAIL** | loads (size matches 425984) then DESYNCS: 32B@300f → 3509B@900f. Arch-dependent emulation (FP/UB), not a format issue — a loaded state silently diverges. |
| snes9x2005_plus | SNES | **FAIL** | state is arch-SIZED (armhf 531668 vs arm64 564544); unserialize refuses the mismatch outright. Packed-struct freeze with sizeof(long)/pointer padding. |

Pattern: the lightweight cores that RUN on the armhf Miyoo hardware split two
ways — the simple ones (fceumm/gambatte/picodrive) serialize portably; the
JIT/heavier-logic ones (gpsp/snes9x2005_plus) bake arch into the state. The
modern portable-state cores (mgba, snes9x-current) are too heavy for the
Mini Flip, so we can't just swap. Consequence: NES/GB/GBC/GG/SMS/MD hand off
across the ENTIRE fleet; GBA+SNES hand off only WITHIN a bitness group.

Recovery routes (real, unproven):
- SNES: rewrite snes9x2005_plus freeze/unfreeze to fixed-width/LE (bounded core
  fork; breaks old states — fine, sync is new). Does NOT help gpsp.
- GBA: gpsp's problem is emulation determinism, not format — far deeper; likely
  no armhf-viable deterministic GBA core exists. Cross-arch GBA may be a true ❌.

## Automated re-certification (2026-07-22, WS5)

`recert.sh` automates the full method above as one command. It stages the shipped
core binaries (LodorOS card tree for the trio + gpsp/snes9x2005_plus, the mgba cert
bins for mgba, libretro buildbot aarch64 for the two CFW-provided arm64-only cores),
real rom fixtures from the RomM library, compiles `harness.c` inside `arm32v7/gcc:12`
and `arm64v8/gcc:12` (explicit arch repos + `--platform`; every qemu run is
`timeout`-wrapped and armhf runs are `--cpuset-cpus`-pinned), then drives the
seed/continuation/trajectory-compare protocol per core:

- cross-arch classes (fceumm, gambatte, picodrive, mgba): BOTH directions,
  +300/+900 continuation compare against the origin arch's own continuation,
  with an automatic +2700 probe when a small diff grows (drift-sizing);
- single-arch classes (gpsp, snes9x2005_plus, snes9x, genesis_plus_gx, mgba@arm64):
  a->a round-trip fidelity (fresh-boot 600/900f reference vs save@300+load continuation);
- picodrive is certified on BOTH its Z80 path (GG) and its 68k+FM path (MD) —
  a per-core class is only as portable as its least portable system;
- plus informational cross-arch re-runs of the known 2026-07-07 negatives.

Output: `matrix-<date>.json` (committed here) — core versions via
`retro_get_system_info`, sha256 + provenance per binary, verdict + evidence per row —
and a human table on stdout. `release/gate.sh state-recert <state-compat.json>`
then fails any whitelist claiming a class without a green line in the newest
committed matrix. Certification facts, not wishes, now enforced by machine.

### 2026-07-22 re-cert results (matrix-2026-07-22.json) — the 07-07 table CORRECTED

| Core | Verdict | Evidence |
|---|---|---|
| fceumm armhf<->arm64 | **PASS** | byte-identical both directions |
| gambatte armhf<->arm64 | **PASS** | 12B inert island (constant offsets), both directions |
| mgba armhf<->arm64 | **PASS** | byte-identical both directions (0.11-dev 747362c) |
| picodrive (GG/Z80 path) armhf<->arm64 | PASS | 3B inert island — matches the 07-07 result |
| **picodrive (MegaDrive path) armhf<->arm64** | **FAIL** | compounding desync BOTH directions: 3B@+300 -> 4B@+900 -> 29-30B@+2700 |
| gpsp arm64 round-trip | PASS | 1B inert island |
| gpsp armhf round-trip | FAIL (borderline) | 1B appears late (+900), stable at +2700; run-to-run window variance |
| snes9x2005_plus round-trip (both arches) | FAIL | constant 530B island — non-compounding but needs source-level investigation |
| snes9x arm64 round-trip | PASS | byte-identical (buildbot 1.63) |
| genesis_plus_gx arm64 round-trip | PASS | byte-identical (buildbot v1.7.4) |

**The 2026-07-07 "picodrive PASS" was earned on the Z80 path and generalized to the
whole core.** The MegaDrive path desyncs cross-arch (same core version 2.01-b0be121,
both directions) — consistent with the external evidence (Genesis-Plus-GX's documented
32/64-bit state break; RetroArch netplay refusing picodrive cross-arch). The shipped
`picodrive:armhf,arm64` class is therefore NOT certifiable as-is; whether to narrow it
(per-system classes / demote to arm64-only) is a product decision, deliberately NOT
made by this rig.
