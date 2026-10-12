# Release process

1. Update `VERSION`, `CHANGELOG.md`, download names in the README and `docs/RELEASE_NOTES.md`.
2. Run source checks and build/verify both architectures on matching hosts.
3. Commit the reviewed source. Push a `v<version>` tag matching `VERSION`.
4. The release workflow builds on `macos-14` (Apple Silicon) and `macos-15-intel`, verifies the relocated bundles, generates DMG/ZIP files and publishes them together with combined SHA256 checksums.
5. Check the workflow result and the published assets. Public release creation waits for both architecture builds to finish.

Default builds are ad hoc signed. They are **not Developer ID signed or notarized**. README and installation notes disclose the first-open approval process. The project does not disable Gatekeeper or remove downloaded files' quarantine attributes.

## Optional Developer ID signing

For a local release, set `CODESIGN_IDENTITY` to a Developer ID Application identity available in the keychain. PyInstaller signs its helper and embedded native dependencies; the wrapper signs the native app with the hardened runtime and a timestamp.

For GitHub Actions, configure these repository secrets:

| Secret | Meaning |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate and private key |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the P12 export |
| `MACOS_SIGNING_IDENTITY` | Developer ID Application certificate identity |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_PASSWORD` | App-specific password |
| `APPLE_TEAM_ID` | Developer team ID |

The workflow imports the certificate into a temporary runner keychain and removes it after the build. If a certificate is configured, the password and identity are required; missing credentials fail rather than silently producing unsigned builds.

## Optional notarization

With Developer ID signing and the three Apple credentials configured:

```bash
python3 build_app.py --package --notarize
```

The tool submits the ZIP, staples and validates the application, regenerates the ZIP, then submits, staples and validates the DMG. Checksums are calculated after stapling. The CI requests notarization when all three Apple credentials are present. Partial notarization credentials fail the workflow.

Signing and notarization support is included; the credential-dependent path is unverified in the initial public release because the maintainer machine has no Developer ID identity. Only claim notarization after an actual successful submission and stapler validation. Update release notes to reflect the assets actually produced.
