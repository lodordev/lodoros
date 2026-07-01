# Config contract (the SSOT that stops schema drift)

`config.schema.json` is the **single source of truth** for `config.json`. Every reader, in any
language, on any side of the wire, conforms to it. `example-config.json` is the canonical golden
file (no real secrets). The contract test (`release/gate.sh contract`) validates the example against
the schema and asserts each declared reader agrees on the SAME nesting.

## The rule
- Connection identity — `root_uri`, `token`, `device_id` — lives under **`hosts[0]`**, NOT at top level.
- Add or move a field? Edit the schema, bump `schema_version`, and update EVERY reader **in the same
  commit** (interface-first). A schema change without both readers updated must fail the gate.

## Known violation (the LODOR-card bug — fix tracked in ledger.md)
`lodoros/launcher/minui.c:Lodor_isConnected()` scans for **top-level** `root_uri`/`token`/`device_id`.
The engine writes them under `hosts[0]`. Result: a fully-paired device reads as "not connected" and the
boot-gate forces onboarding (no Continue, no Sync entry, no Lodor menu). FIX: the launcher must read
those three keys from `hosts[0]`. This is the first contract-conformance PR.
