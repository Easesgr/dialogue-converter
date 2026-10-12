# Changelog

## 0.4.0 — native conversation conversion preview

- Replace the app's prompt-copy workflow with native Cowork/Codex session selection, full-history conversion and import receipts.
- Discover local Cowork tasks and resolve active message chains across compaction boundaries.
- Import through Codex's native session protocol and verify exact visible text/roles.
- Generate minimal Cowork desktop history ZIPs for Claude's native import wizard; verify local imported history after user import.
- Add duplicate snapshot detection, durable target IDs, interrupted-import verification and destination selection for reverse conversion.
- Add native format tests and an isolated installed-Codex integration check.
- Verify a synthetic history visibly rendered in the Codex desktop; record user-confirmed Cowork ZIP import with visible history. Local Cowork lookup has not matched that test record, and resumed model generation remains unverified; release as an experimental preview.

## 0.3.0 — original prototype

- Native macOS handoff-text utility with local adapters, explicit delivery acknowledgements and incremental references.
- Portable bundled runtime, DMG/ZIP packaging and release workflows.
