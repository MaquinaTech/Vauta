# Releasing Vauta (maintainer)

How the maintainer publishes a release. Vauta is distributed as **source code only**: users clone the repository and build it on
their own Mac ([README](../README.md#install-from-source)). A release is a tag plus a GitHub release with notes. There is no
Apple Developer Program membership, no Developer ID signing, no notarization, no disk image or zip, no Homebrew cask, and the
release workflow uses no secrets and uploads no binaries. Users verify what they run by building from the tag
([SECURITY.md](../SECURITY.md#verifying-what-you-run)).

## What a release contains

| Item | What it is |
|---|---|
| The tag `vX.Y.Z` | A commit on `main`, with a tag signed by the maintainer's SSH key (see below). GitHub's automatic source archives (zip and tar.gz) come with it. |
| The release notes | The `## [X.Y.Z]` section of `CHANGELOG.md`, copied by the workflow into a **draft** GitHub release. |

Nothing else is attached. The CycloneDX SBOM (`scripts/generate-sbom.py`) is no longer part of a release; run it by hand if
someone asks (`python3 -I scripts/generate-sbom.py --version X.Y.Z --output Vauta.sbom.cdx.json`; everything in it except the
timestamp is deterministic, set `SOURCE_DATE_EPOCH` to fix that too).

## One-time setup

1. Make the repository public, then enable GitHub Actions. They are disabled on purpose until then.
2. Add a tag ruleset (Settings, Rules) so that only you can create or delete tags matching `v*`: a tag is the one thing that
   can start a release.
3. Turn on branch protection and two-factor authentication ([GOVERNANCE.md](../GOVERNANCE.md#repository-controls)).

No secrets and no `release` environment are needed.

## Releasing a version

1. On `main`, with CI green: set the version in `CHANGELOG.md` (replace "Unreleased" with the version and date), in
   `Resources/Info.plist` (`CFBundleShortVersionString`, and `CFBundleVersion` one higher) and in `scripts/render-ui.sh`, and
   commit. The plist is the version every build uses; the release workflow refuses a tag that doesn't match it.
   If the release ships new schema migrations (`Schema.migrations` after `lastPublished` in
   `Tests/VautaCoreTests/SchemaFreezeTests.swift`), add their fingerprints in the same commit: raise `lastPublished` to the last
   migration, run `swift test --filter SchemaFreezeTests` and add the `Fingerprint(…)` lines the failing test prints. A new
   migration with a code step also needs a test there of the rows it writes. From then on those migrations are never edited.
   Run locally: `swift build -c release --arch arm64`, the tests, `scripts/check-strings.sh`, `scripts/check-headers.sh`, `scripts/check-dependencies.sh`.
   Check the search model ([SEARCH_MODEL.md](SEARCH_MODEL.md)): its download hosts resolve from the EU and APAC, `Vauta mlx-selftest --model` passes on a locally signed build, and the licences and model card terms are unchanged.
2. Run the cryptography review check: the `git diff` command in [CRYPTO_REVIEW.md](CRYPTO_REVIEW.md) (from the commit it names
   to the tag's commit, over the paths it lists) must print nothing. If it prints something, redo that review first.
   Re-run `eval/run_all.sh` if speaker or transcription code changed since [BENCHMARKS.md](BENCHMARKS.md) was written, and
   check [COMPATIBILITY.md](COMPATIBILITY.md) has the results of the real-call checklist.
3. Check that a clean clone builds and installs with the README steps.
4. Tag the commit with a signed tag and push it:

   ```sh
   git tag -s v0.9.0 -m "Vauta 0.9.0"
   git -c gpg.ssh.allowedSignersFile=.github/allowed_signers tag -v v0.9.0   # Good "git" signature … SHA256:exvRtcRtqxp/AHhadgXr7PAHe9itjHFPqVVCoGaOrU4
   git push origin v0.9.0
   ```

   Tags are signed with the maintainer's SSH key `~/.ssh/vauta_signing` (ED25519, `SHA256:exvRtcRtqxp/AHhadgXr7PAHe9itjHFPqVVCoGaOrU4`). The maintainer's clone
   sets `gpg.format ssh`, `user.signingkey`, `tag.gpgSign` and `gpg.ssh.allowedSignersFile`; that local file must map the principal `maintainer@vauta` to the same public key as [`.github/allowed_signers`](../.github/allowed_signers). Only the public key leaves the Mac: it is a signing key on the
   MaquinaTech GitHub account, so GitHub shows the tag as "Verified". Users verify it with `.github/allowed_signers` as in
   [SECURITY.md](../SECURITY.md#verifying-what-you-run).

   The tag must look like `v1.2.3`, and its commit must be on `main`; the workflow refuses anything else.
5. Run the workflow **on the tag**: `gh workflow run release.yml --ref v0.9.0`, or Actions tab, **Release**, **Run workflow**, and
   in "Use workflow from" choose the tag (not `main`). The workflow refuses a branch.
6. The workflow validates the tag, checks it is on `main`, runs `swift test`, builds the app ad hoc (only to prove it builds;
   the result is discarded) and creates a **draft** release with the CHANGELOG section as notes.
7. Review the draft, then publish it by hand. Announce.

If the workflow fails, fix the cause and run it again on the same tag: nothing is published until you publish the draft. If a
published release turns out to be bad, delete it, fix, and release a new version number; never move a tag.

---

## Appendix (optional): signed and notarized binaries

**Not part of the official release and not required for anything above.** It is kept for a fork, or for a future decision by the
maintainer to publish signed builds (see [ROADMAP.md](ROADMAP.md#signed-builds-and-homebrew-possible-future-not-planned)). It needs a
paid Apple Developer Program membership. The earlier release workflow that did this is in the Git history of
`.github/workflows/release.yml`.

### B1. Building and notarizing by hand

```sh
VAUTA_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \
VAUTA_NOTARY_PROFILE=vauta-notary scripts/package.sh      # dist/Vauta-<version>.zip, .dmg, SHA256SUMS
```

`scripts/package.sh` builds with `scripts/build-app.sh`, notarizes and staples the app with `scripts/notarize.sh`, then packages
and notarizes the disk image. `VAUTA_NOTARY_PROFILE` names `notarytool` credentials stored beforehand
(`xcrun notarytool store-credentials`, with an App Store Connect API key). A workflow that did this in CI needed the secrets
`DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `DEVELOPER_ID_IDENTITY`, `APP_STORE_CONNECT_API_KEY_BASE64`,
`APP_STORE_CONNECT_API_KEY_ID` and `APP_STORE_CONNECT_API_ISSUER_ID`, kept in a protected environment restricted to tags with a
required reviewer, never in the repository and never pasted into chats, issues or logs. A signed build should use its own
bundle ID (`VAUTA_BUNDLE_ID`), a different app from source builds; do not change it after users install.

### B2. Verifying a signed download

```sh
shasum -a 256 -c SHA256SUMS
spctl --assess --type execute -vv /Applications/Vauta.app       # expect: accepted, source=Notarized Developer ID
xcrun stapler validate /Applications/Vauta.app                  # expect: The validate action worked!
codesign --verify --deep --strict --verbose=2 /Applications/Vauta.app
codesign -dvv /Applications/Vauta.app 2>&1 | grep -E 'Authority|Timestamp|flags'   # expect: Developer ID Application, runtime
spctl --assess --type open --context context:primary-signature -vv Vauta-0.9.0.dmg
xcrun stapler validate Vauta-0.9.0.dmg
```

Build provenance attestations (`gh attestation verify <file> --repo <owner>/<repo> --source-ref refs/tags/<tag>`) can be added
with `actions/attest-build-provenance`. None of this is an audit of the code (see [SECURITY.md](../SECURITY.md#audit-status)).

### B3. Signing key succession

If a fork signs builds with a Developer ID certificate held as workflow secrets and the maintainer is
unavailable or the certificate expires, is revoked or is lost:

- **Expiry and renewal.** A Developer ID certificate is valid for five years; the Apple Developer Program membership renews
  yearly. Put a reminder in the maintainer's calendar for both, three months ahead. An expired certificate does not invalidate
  apps that were already signed and notarized with a secure timestamp, but new releases need a new certificate.
- **A new certificate changes the signer, not the app's identity**, as long as the bundle ID and Team ID stay the same.
  Moving to a different Team ID (for example a project organization account) makes macOS treat the app as a different
  signer: permissions are asked again and the Keychain's ACL on the store key no longer matches, so users get a prompt. Plan
  such a move deliberately, announce it in the release notes, and test that existing stores still open.
- **Backup of the key.** The maintainer keeps the exported .p12 and its password in two separate places that do not depend on the
  same account (for example a password manager and an encrypted offline copy). Never in the repository.
- **If the maintainer cannot act.** Another maintainer listed in GOVERNANCE.md can take over only if the maintainer has given them the
  Developer Program role (Account Holder transfer, or an Admin role with a certificate of their own) and access to the `release`
  environment. Until a second maintainer exists, there is no succession beyond the maintainer: say so rather than implying one.
  Users can always build from source, which needs no one's key.
- **Compromise.** If the certificate or the API key is suspected stolen: revoke the certificate in the Apple Developer account,
  rotate the secrets, publish a security advisory, and release a new version signed with a new certificate. Compromised
  releases are listed in the advisory with their SHA-256.
- **Tag signing key**: SSH ED25519 `SHA256:exvRtcRtqxp/AHhadgXr7PAHe9itjHFPqVVCoGaOrU4`, published as a signing key on the maintainer's GitHub account and listed in
  GOVERNANCE.md. Rotating it is announced in the release notes and in SECURITY.md. If the key is suspected stolen,
  remove it from GitHub, publish an advisory naming the tags signed after the suspected date, and re-sign the
  current release with a new key.
