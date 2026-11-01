## Summary

<!-- What does this change and why? Link the issue it fixes, e.g. "Fixes #123". -->

## How it was tested

<!-- Commands you ran and what you checked by hand (macOS version, meeting app or browser, languages). -->

- [ ] `swift build -c release` and `swift test` pass (with the Command Line Tools only, `swift test` needs the plugin path in [CONTRIBUTING.md](https://github.com/MaquinaTech/Vauta/blob/main/CONTRIBUTING.md#test))
- [ ] Tested in the app bundle (`scripts/build-app.sh`), if the change affects the app

## Checklist

- [ ] No new dependency (the pinned MLX fork stays the only one), telemetry or network destination other than the user's model server
- [ ] User-facing text is in English and localizable (`String(localized:comment:)` or SwiftUI string literals)
- [ ] Persisted data stays compatible: existing stores, Keychain items and settings still open, with a migration and a test when the format changes
- [ ] New source files start with the SPDX license header
- [ ] Documentation updated where behavior changed
- [ ] Every commit is signed and has a DCO sign-off (`git commit -S -s`; `main` accepts only Verified commits, see [CONTRIBUTING.md](https://github.com/MaquinaTech/Vauta/blob/main/CONTRIBUTING.md#developer-certificate-of-origin))
