# Lodor update manifest signing (ed25519)

Closes security HIGH finding #4: the self-update manifest is now **signed with an
offline ed25519 key**, so a device trusts an update because the manifest carries
a signature from a key that never leaves the release host — not merely because
the manifest arrived from github.io.

## Trust model — before vs after

**Before.** A device fetches `https://lodordev.github.io/lodor/versions.json`
over plain HTTPS, reads the per-asset `sha256`, downloads the update zip, and
verifies the zip against *that hash from that same manifest*. The hash defends
against a corrupt/truncated download — **not** against a compromised manifest
source. Anyone who can write the gh-pages branch or steal the publishing token
can publish a `versions.json` pointing at a malicious zip with a matching hash,
and every device applies it.

**After.** The manifest is signed offline. The engine embeds the trusted
**public** key and verifies a detached signature (`versions.json.sig`) over the
exact bytes of `versions.json` *before* it trusts any hash inside it. Forging an
accepted update now requires the offline private key, not just gh-pages write
access. The sha256 hashes still guard against corruption; the signature guards
the manifest's origin. Defense in depth.

## Keys

- **Private key** (signs the manifest): PEM PKCS8 ed25519 at
  `/mnt/user/appdata/lodor/update-signing-ed25519.key` on the release host
  (mode 600), **out of the repo** exactly like the Android keystore, **backed up
  to titan**. The pipeline signer reads it *by path* at sign time; it is never
  copied into the repo, printed, or committed. `LODOR_UPDATE_SIGNING_KEY`
  overrides the path.
- **Trusted public key** (embedded in the engine, `engine/update/signing.go`):
  - hex: `71498c04b8d318579d4fefe6c9064b8f67345ed2df1c34b7bd8d950eda75a6e5`
  - base64: `cUmMBLjTGFedT+/myQZLj2c0XtLfHDS3vY2VDtp1puU=`

## How it works

1. **Sign (release host).** `release/publish-updates.sh`, after `mkversions.sh`
   writes `versions.json` and it passes the `update-manifest` gate, runs
   `release/cmd/lodor-signmanifest` to produce `versions.json.sig`
   (`base64(ed25519_sign(privkey, raw versions.json bytes))`). Both files are
   uploaded as release assets.
2. **Publish.** `release/workflows/publish-versions.yml` re-verifies every named
   asset live by sha256, then copies **both** `versions.json` and (when present)
   `versions.json.sig` to the gh-pages branch devices poll.
3. **Verify (device).** `engine/update.FetchManifest` captures the **raw**
   response bytes for `versions.json`, GETs `<url>.sig`, calls
   `VerifyManifestSig(rawBytes, sig)` — `ed25519.Verify` against the embedded
   public key — and **only then** `json.Unmarshal`s the *same* raw bytes.
   Verifying over the raw fetched bytes (never a re-serialized parse) is required
   because ed25519 signs bytes: any canonicalization difference would break an
   otherwise-valid signature.

## Rollout: `SigMode` (fail-OPEN)

`engine/update/signing.go` has a build-time const `SigMode`. **Shipped value:
`"warn"`.**

| mode | behavior |
|---|---|
| `off` | do not fetch or verify the `.sig` at all (pre-signing behavior) |
| `warn` | fetch + verify + **log** the result; a missing OR invalid signature does **not** block the update — proceeds exactly as before signing existed |
| `enforce` | a missing or invalid signature **refuses** the manifest |

We ship **`warn`** deliberately: this feature can only *add* safety. It goes to a
live fleet with no hardware test, and a fleet that has never seen a signature (or
a release published before the `.sig` reaches gh-pages) must keep updating. In
`warn` the engine logs `update-sig: manifest signature OK` or a clear
`update-sig: WARNING …` line and proceeds.

### Flipping to `enforce`

There is **one** line to change in `engine/update/signing.go`:

```go
const SigMode = "warn"   // → const SigMode = "enforce"
```

Before flipping, ALL of the following must be true:

1. The signing keys are **confirmed working on real hardware** — a device on the
   current engine logs `manifest signature OK` against a live signed manifest.
2. `versions.json.sig` is **reliably published to gh-pages** by the workflow for
   every release (stable + beta), and has been for long enough that no
   in-the-wild device could reach a signed engine before a signature exists.
3. **The maintainer signs off.** Enforce is fail-closed: a publishing mistake (missing
   or stale `.sig`) would stop the entire fleet from updating.

Do the flip in its own release, gated on the above — never bundle it with other
risky changes.

## Key rotation (future work — not built now)

Today there is exactly **one** trusted public key, embedded as a const. Rotation
is intentionally *not* implemented yet (no multi-key trust store, no key-id in
the manifest). When it's needed, the shape:

- Add a small trusted-key **set** (slice) in `signing.go`; `VerifyManifestSig`
  accepts a signature that verifies under **any** trusted key. Ship the new
  public key in an engine release *first*, so devices trust both old and new.
- Only after that engine is widely deployed, switch the signer to the new
  private key. Later, drop the retired key from the set in a subsequent release.
- If the private key is ever *compromised* (not just rotated), there is no online
  revocation — the mitigation is to push an engine update that removes the
  compromised key from the trusted set. That update itself would still be signed
  by the compromised key under enforce, so keep a **second, independent** offline
  key reserved for exactly this recovery path before enabling enforce fleet-wide.

## Files

- `engine/update/signing.go` — embedded public key, `SigMode`, `VerifyManifestSig`, typed errors.
- `engine/update/manifest.go` — raw-bytes fetch + verify wired into `FetchManifest`.
- `engine/update/signing_test.go` — verification + fail-open/enforce tests.
- `release/cmd/lodor-signmanifest/` — the offline signer CLI (+ round-trip test).
- `release/publish-updates.sh` — signs after the gate, uploads the `.sig`.
- `release/workflows/publish-versions.yml` — copies the `.sig` to gh-pages.
