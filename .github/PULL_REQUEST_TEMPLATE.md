## Summary

<!-- What does this change and why? Link the issue it fixes, e.g. "Fixes #123". -->

## How it was tested

<!-- Commands you ran and what you checked by hand (macOS version, meeting app or browser, languages). -->

- [ ] `swift build -c release` and `swift test` pass
- [ ] Tested in the app bundle (`scripts/build-app.sh`), if the change affects the app

## Checklist

- [ ] No new third-party dependencies, telemetry or network destinations other than the user's model server
- [ ] User-facing text is in English and localizable (`String(localized:comment:)` or SwiftUI string literals)
- [ ] Persisted data stays compatible: existing stores, Keychain items and settings still open, with a migration and a test when the format changes
- [ ] New source files start with the SPDX license header
- [ ] Documentation updated where behavior changed
- [ ] Every commit has a DCO sign-off (`git commit -s`; a DCO check reports missing ones, see [CONTRIBUTING.md](https://github.com/MaquinaTech/Vauta/blob/main/CONTRIBUTING.md#developer-certificate-of-origin))
