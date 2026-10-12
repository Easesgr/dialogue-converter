# Contributing

The product converts native conversation records. Keep model execution and conversation continuation in the original applications.

Use synthetic fixtures. Do not commit real conversations, credentials, application profiles, imported ZIPs or environment files.

Before changing an adapter, inspect the corresponding format and callers, preserve source files, and test roles, ordering, full text, privacy filters and failure behavior. Do not weaken format checks or silently fall back to summaries or clipboard prompts.

Run:

~~~bash
python3 -m unittest discover -s tests -v
xcrun swiftc -swift-version 5 -parse-as-library -typecheck Models.swift main.swift
~~~

With a compatible Codex desktop installed, run python3 scripts/check_native_import.py to exercise the actual native importer in isolated profiles. No model requests are made.

See [BUILD.md](docs/BUILD.md) for packaging and [FORMAT_NOTES.md](FORMAT_NOTES.md) for native compatibility limits. Report the exact app/CLI version and a minimal synthetic reproducer when possible.
