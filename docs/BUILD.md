# Build from source

User downloads are self-contained. These prerequisites are for maintainers only:

- macOS 14+, on the architecture you intend to distribute.
- Xcode command line tools (`xcrun swiftc`, `codesign`, `sips`, `iconutil`, `hdiutil`).
- Python 3.11+ to run the build scripts, and network access for the pinned build runtime/dependencies.

## Commands

```bash
python3 -m unittest discover -s tests -v
xcrun swiftc -swift-version 5 -parse-as-library -typecheck Models.swift main.swift
python3 packaging/bootstrap_python.py
python3 build_app.py --package
```

`bootstrap_python.py` verifies the SHA256 of the pinned official python.org universal2 installer, extracts it into `build/`, relocates that private build runtime and installs pinned PyInstaller dependencies into `build/venv`. It does not install Python system-wide. The installer includes both architectures; the actual frozen bundle matches the architecture running the build.

The official runtime is used because a Homebrew Python library may require a newer macOS than the advertised deployment target. The final verifier rejects any included library requiring macOS newer than 14.0 or linking to a maintainer's external library.

Outputs:

```text
dist/对话转换器.app
dist/DialogueConverter-<version>-macos-<arch>.dmg
dist/DialogueConverter-<version>-macos-<arch>.zip
dist/SHA256SUMS-<arch>.txt
```

Use `--install` to also copy to `~/Applications`, preserving the previous application in the ignored `backups/` directory. Quit an existing converter instance before replacing the installed copy. Claude and Codex can continue running.

`--arch arm64` or `--arch x86_64` verifies the host architecture. Unsupported cross-builds fail. `--python /path/to/python` can select a prepared PyInstaller runtime, but it must include runtime licenses and satisfy all bundle checks.

## Verification

Every build invokes:

```bash
python3 packaging/verify_app.py 'dist/对话转换器.app' --arch arm64
```

Use `x86_64` on Intel. Verification checks all native binaries, system deployment targets, external dependencies and deep signatures. It then copies the application to a new path containing spaces and runs its bundled helper with an empty HOME, minimal PATH, and invalid external Python paths. Synthetic conversations verify discovery, native Cowork ZIP conversion, full visible text, conversion receipts, legacy compatibility and failure responses. No real user sessions or model calls are needed.

For manual UI review:

```bash
open -n 'dist/对话转换器.app' --args --demo
```

Demo mode uses synthetic text and temporary isolated converter storage. It does not list real conversations or persist conversation selections. Quit the demo before starting the normal application. The native UI offers conversion/import actions. Demo Codex imports use an isolated CODEX_HOME, so their thread IDs do not belong to the regular desktop profile.

See [RELEASE.md](RELEASE.md) for signing and publication.

## Installed Codex integration check

~~~bash
python3 scripts/check_native_import.py
# or: python3 scripts/check_native_import.py --codex-binary /path/to/codex
~~~

Uses synthetic multi-turn long text with isolated HOME and CODEX_HOME. Verifies the native importer, exact roles/text, idempotence, reverse Cowork ZIP and normal persisted-thread resume. Does not send turn/start or call a model. This check needs a compatible installed Codex program and is not part of CI runners without that app. Cowork GUI import needs a separately configured Claude desktop; it is not proven by package-format tests.
