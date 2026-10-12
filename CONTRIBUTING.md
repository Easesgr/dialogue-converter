# Contributing

The product is a converter and handoff utility. Keep chat, model execution and original session ownership in the provider's application.

1. Inspect the relevant adapter, caller and fixtures before changing transcript handling.
2. Use synthetic or carefully redacted examples. Never add real histories, credentials, private reasoning, machine-specific paths or build outputs.
3. Preserve the delivery invariants in [FORMAT_NOTES.md](FORMAT_NOTES.md). Preparing or copying a packet must not acknowledge it.
4. Run `python3 -m unittest discover -s tests -v` for core changes. On macOS also run the Swift typecheck and bundle checks in [docs/BUILD.md](docs/BUILD.md).
5. Explain the observed format, behavior change and actual validation in the PR. For UI changes include a screenshot made with `--demo`.

Use Python's standard library for runtime logic. Maintainer build dependencies are pinned separately in `requirements-build.txt`. Avoid adding model calls or automatic message submission to the converter.
