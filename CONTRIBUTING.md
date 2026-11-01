# Contributing to Vauta

Thanks for your interest in Vauta. Bug fixes, new meeting apps, model server support, translations, tests and
documentation are all welcome.

Vauta records and stores confidential conversations, so a few rules here are stricter than in most projects.
Please read [Privacy and security rules](#privacy-and-security-rules) before you write code.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md). For questions, see
[SUPPORT.md](SUPPORT.md). Security problems go through
[private vulnerability reporting](https://github.com/MaquinaTech/Vauta/security/advisories/new), never a public issue.

## Contents

- [Before you start](#before-you-start)
- [Development setup](#development-setup)
- [Build, test and run](#build-test-and-run)
- [Project layout](#project-layout)
- [Coding conventions](#coding-conventions)
- [Privacy and security rules](#privacy-and-security-rules)
- [Compatibility: migrations and persisted formats](#compatibility-migrations-and-persisted-formats)
- [Adding a meeting app](#adding-a-meeting-app)
- [Adding a model server profile](#adding-a-model-server-profile)
- [Localization](#localization)
- [Visual review](#visual-review)
- [Commits and pull requests](#commits-and-pull-requests)
- [Developer Certificate of Origin](#developer-certificate-of-origin)

## Before you start

- For a small fix, open a pull request directly.
- For a new feature or a larger change, open an issue first so we can agree on the approach before you invest time.
- Vauta stays local-first: no cloud services, no telemetry, no accounts and no third-party dependencies beyond the pinned MLX fork (and its swift-numerics dependency). Proposals
  that need any of these will not be accepted.

## Development setup

You only need Apple's **Command Line Tools**. Xcode is not required.

| Requirement | Why |
|---|---|
| Mac with Apple silicon | Vauta is built for `arm64` only. |
| macOS 26 or later | The app's deployment target. |
| Command Line Tools with the **macOS 27 SDK** (Swift 6.4) | Some code uses macOS 27 APIs behind `#available` checks, so an older SDK does not compile it. |

```sh
xcode-select --install          # if the Command Line Tools are missing
swift --version                 # expect Swift 6.4, target arm64-apple-macosx
git clone https://github.com/MaquinaTech/Vauta.git
cd Vauta
```

SwiftPM resolves one package, a pinned fork of MLX (and its swift-numerics dependency), the first time you build. **The first build compiles MLX's C++ and takes several minutes**; later builds do not. `-j 3` still applies on machines with little memory.

## Build, test and run

### Build

```sh
swift build                     # debug
swift build -c release --arch arm64
```

On a machine with little memory, limit parallel jobs with `-j 3`.

### Test

Tests use [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`, `@Test`, `#expect`).

**With only the Command Line Tools**, the compiler does not find the plugin that expands the testing macros by
itself. Pass its path explicitly:

```sh
swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

**With Xcode selected** (`xcode-select -p` points into `Xcode.app`), plain `swift test` works. CI uses that.

To run part of the suite, add `--filter`, for example `swift test --filter CaptureCatalogTests` (plus the plugin path
above when needed).

**The minutes replay.** `MinutesReplayRegressionTests` replays the replies that Apple's on-device model and the integrated
model gave on three invented meetings (`Tests/VautaCoreTests/Fixtures/MinutesReplay`) through everything after the model,
and fails when the minutes they give change. When the change is intended, write the expected minutes again with
`VAUTA_WRITE_MINUTES_REPLAY=1` (and `--filter MinutesReplayRegression`) and let the diff of the `.minutes.json` files show
it in the pull request. A change to what the minutes ask the model needs new replies; the suite's comment says how to
record them.

### Test coverage

Last measured on 10 October 2026 (it has not been re-measured since, and the code has changed) with `swift test --enable-code-coverage` and
`xcrun llvm-cov export -summary-only`, shipped sources only (tests, `tools/` and `eval/` excluded), reading both test bundles (`VautaCoreTests` and `VautaAppTests`):
**27.5 % of lines** (17,143 of 62,396), 32.4 % of functions, 37.3 % of regions for the whole package, the `VautaCore` library and the app target (`Sources/Vauta`: recorder model, command line,
windows). Most of the app target is SwiftUI and capture code that tests do not drive; the library on its own,
which holds the logic, is at **84.6 % of lines** (16,986 of 20,077), 80.7 % of functions, 79.9 % of regions. CI computes both
figures in the job summary of every run and keeps the report as the run's `coverage` artifact; this paragraph is measured by
hand, so it lags behind.

### Other checks that CI runs

```sh
scripts/check-strings.sh        # every translation matches the English keys and format specifiers
scripts/extract-strings.sh && git diff --exit-code -- Resources/en.lproj/Localizable.strings   # English strings in sync with the code
scripts/check-headers.sh        # every source file has the SPDX license header
scripts/check-dependencies.sh   # only the pinned mlx-swift fork and swift-numerics
scripts/check-shell-vars.sh     # no shell variable runs straight into a non-ASCII character ("${name}…", not "$name…")
find Resources Sources \( -name '*.plist' -o -name '*.entitlements' -o -name '*.strings' -o -name '*.stringsdict' \) \
  -print0 | xargs -0 plutil -lint
for f in scripts/*.sh; do bash -n "$f"; done   # and shellcheck, if installed
```

CI also assembles the app bundle with an ad-hoc signature (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

### Run the app

Build a real app bundle and open it. Do **not** start the bare binary from `.build` without a command: that launches
a second menu-bar app outside the sandbox, with a different storage location and Keychain identity than the
installed app.

```sh
./scripts/setup-signing.sh      # once, in your own Terminal: creates a local signing identity (asks for passwords)
./scripts/install.sh            # builds, signs and installs ~/Applications/Vauta.app, then opens it
```

For a quick throwaway build without a signing identity, give it its own bundle ID so it never opens your installed
Vauta's container, Keychain items or meetings:

```sh
VAUTA_BUNDLE_ID=local.vauta.dev VAUTA_ALLOW_ADHOC=1 ./scripts/build-app.sh   # then open build/Vauta.app
```

macOS then asks for permissions again after every rebuild. Without `VAUTA_BUNDLE_ID` the build uses the same bundle ID as
your install (the default or `scripts/local.env`), so it shares its data: quit the installed Vauta first, and never run
both at once.

Set your own bundle ID in `scripts/local.env` (never committed), for example `VAUTA_BUNDLE_ID=com.yourname.vauta`. The
default is `local.vauta.app`. The bundle ID decides the sandbox container, the Keychain items and the permissions, so
keep it stable.

### Command-line tools

The same binary has read-only commands for support and development. A known command as the first argument switches
to command mode; `Vauta help` lists them all.

| Command | What it does |
|---|---|
| `doctor` | Checks macOS, speech languages, the store (without opening it), the model server and permissions. |
| `status [--locale <id>]` | Speech model status and the processes playing or recording audio. |
| `languages` | Transcription languages and whether their models are installed. |
| `install-speech-assets [--locale <id>]` | Downloads Apple's speech model for a language. |
| `install-dictation-assets [--locale <id>]` | Downloads the dictation model (used for custom vocabulary). |
| `transcribe-file <audio> [--locale <id>] [--vocab "a,b"]` | Transcribes an audio file; prints counts only unless `--show-text` (with `--out <words.jsonl>`, every word with its time and confidence: public audio only). |
| `server-check <config.json> [--ask-key]` | Tests a model server configuration with sample text. |
| `cert-pin <cert.pem>` | Prints the SPKI pin of a certificate. |
| `diarize <audio> [--rttm <out>] [--threshold <n>] [--none-bias <n>] [--live-agreement]` | Separates the speakers of a file and prints RTTM (no text, no audio written). Used by `eval/`. |
| `echo-coupling <me audio> <others audio>` | Evaluation: whether the microphone heard the others, measured over two files (counts only). Used by `eval/`. |
| `minutes-file <transcript.json> --out <minutes.json> [--locale <id>]` | Evaluation: the minutes of a **public** transcript with Apple's on-device model, saved with their citations. Never on a real meeting. |
| `speaker-models` | Verifies (SHA-256) and loads the bundled speaker-separation models. |
| `store-stats` | Size and counts of an existing store (read-only). |
| `help`, `--help` | Lists the commands. |
| `version`, `--version` | Prints the version. |

### Evaluation harness

`eval/` downloads public corpora (AMI and VoxConverse) at pinned, hash-verified revisions, runs `Vauta diarize` and
`Vauta transcribe-file` over them and scores the results with independent scripts (diarization error rate, word error
rate). See [eval/README.md](eval/README.md); the measured numbers are in [docs/BENCHMARKS.md](docs/BENCHMARKS.md).
Datasets and generated audio stay in `eval/work/` (git-ignored) and are never committed.

No command of the normal build captures audio. The capturing `spike` command exists only in a separate diagnostics
build (`-DVAUTA_DIAGNOSTICS`, documented at the top of [`Sources/Vauta/CLI.swift`](Sources/Vauta/CLI.swift)). Build it
outside the project directory and never sign, install or distribute it.

## Project layout

| Path | Contents |
|---|---|
| `Sources/VautaCore/` | Library with all testable logic: `Audio/` and `Capture/` (microphone, system audio taps, meeting app detection), `Transcription/`, `Storage/` (encrypted store, journal, migrations, Keychain), `LLM/` (model servers, Apple on-device model, prompts, jobs), `Knowledge/` (people, projects, glossary, search), `Export/`, `Import/`, `App/` (UI-independent app logic) |
| `Sources/Vauta/` | The menu-bar app (SwiftUI) and the command-line tools |
| `Tests/VautaCoreTests/` | Swift Testing suites for `VautaCore` |
| `Resources/` | `Info.plist`, entitlements, app icon and the `<lang>.lproj` localizations |
| `scripts/` | Build, install, signing and lint scripts (`package.sh` and `notarize.sh` are optional, for forks with an Apple Developer account) |
| `tools/` | Developer tools that are never built into the app: `llm-eval/` (around `Vauta llm-eval`, the language-model evaluation), `language-model/` and `search-model/` (the manifests, goldens and tiny test models of the two optional models), `convert-diarization-models/` (makes the bundled speaker-separation models), `stringsdata-to-strings.swift` (used by `scripts/extract-strings.sh`) and `make-icon.swift` (renders the app icon) |
| `docs/` | User and contributor documentation |

## Coding conventions

- **Swift 6 with strict concurrency.** The package uses Swift tools version 6.0, so the Swift 6 language mode and
  full concurrency checking apply. Don't add `@unchecked Sendable` or `nonisolated(unsafe)` without a comment that
  explains why it is safe. New code must build without warnings.
- **English everywhere in the code**: identifiers, comments, doc comments, log and diagnostic text, and source UI
  strings. Other languages live only in translations.
- **One third-party package.** Apple frameworks and the system `libsqlite3`, plus the pinned MaquinaTech fork of mlx-swift (MIT). `import MLX`
  is allowed only in `Sources/VautaMLX`, and a test enforces it. Never add another package or change the pin without the bump procedure in
  [docs/SEARCH_MODEL.md](docs/SEARCH_MODEL.md); `scripts/check-dependencies.sh` and CI fail on any other.
- **License header.** Every Swift file and shell script starts with:

  ```swift
  // SPDX-License-Identifier: Apache-2.0
  // SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
  ```

  Shell scripts use `#` instead of `//`. If you add a substantial new file, you may add your own
  `SPDX-FileCopyrightText` line below the existing one. `scripts/check-headers.sh` checks this.
- **Small files.** Keep each file under about 600 lines. Split large types by responsibility with extensions in
  separate files (`MeetingStore+Search.swift`, `RecorderModel+Session.swift`).
- **Simple and idiomatic.** No speculative abstractions, no protocols with a single conformer "for later".
- **Formatting.** 4-space indentation and 140-column lines (see [`.editorconfig`](.editorconfig) and
  [`.swift-format`](.swift-format)).
- **User-facing text** is localizable: `String(localized: "English text", comment: "Context for translators")` outside
  views, string literals in SwiftUI (`Text("…")`, `Button("…")`). Use interpolation for values
  (`String(localized: "\(count) meetings")`). Never branch on a display string; compare enums or codes.
- **Errors shown to users** conform to `LocalizedError` with a localized `errorDescription` that says what happened,
  and a `recoverySuggestion` that says what to do when there is something to do. Persist error codes, never error text.
- **Tests.** Put logic in `VautaCore` so it can be tested, and add tests with Swift Testing in
  `Tests/VautaCoreTests/<Area><Topic>Tests.swift` with a suite name such as `@Suite("Capture: meeting app catalog")`.
  Tests must not use the network (use the `StubServer` URL protocol in `ModelsTestSupport.swift`), the user's store
  (use `StoreFixture` with a temporary directory and in-memory keys) or audio devices. The only tests that touch the
  real Keychain use a unique service name per run, delete what they create, and are skipped where no keychain is
  usable.

## Privacy and security rules

These are not negotiable. A pull request that breaks one will not be merged, however useful the feature.

- **Audio is never written to disk.** No debug dumps, no temporary files, no option to enable them.
- **Meeting content stays in the encrypted store.** Don't log transcripts, minutes, names or questions, and don't
  print them from CLI commands by default.
- **No new network destinations.** Vauta talks only to the model server the user configured (loopback, or a local
  network address over HTTPS) and to Apple for speech and system model downloads. No analytics, crash reporting,
  update checks or remote configuration.
- **Don't weaken the platform protections**: App Sandbox, hardened runtime, entitlements, App Transport Security,
  TLS validation, certificate pinning and the address checks for model servers.
- **Secrets stay in the Keychain**, never in `UserDefaults`, files, arguments or logs.

## Compatibility: migrations and persisted formats

People already have encrypted stores, Keychain items and settings written by earlier versions. Every release must open
them and read them correctly.

- **Schema changes** go into the single ordered registry `Schema.migrations` in
  [`Sources/VautaCore/Storage/Schema.swift`](Sources/VautaCore/Storage/Schema.swift). Add a new `Migration` with the next
  version number. A test checks that versions are strictly increasing and contiguous.
- **Never edit a published migration.** A migration is published once it is merged to `main`, not only once it is in a
  release: Vauta is built from source and `scripts/install.sh` builds whatever is checked out, so stores built from `main`
  already ran it. `SchemaFreezeTests` fingerprints every migration (the schema it builds, its SQL and, for a code step,
  the rows it writes) and fails if any of them changes. The pull request that adds a migration also adds its fingerprint,
  which the failing test prints; while that pull request is open, an edit only updates that line. Fix mistakes in a
  merged migration with a new migration.
- Migrations run after the journal is replayed, so a migration must also be correct on data replayed with an older
  schema. Use a `.code` step when SQL alone can't do it.
- Add a test that builds a store with the old schema, migrates it and reads the data back
  (see `Tests/VautaCoreTests/StorageSchemaTests.swift`).
- **Other persisted formats** follow the same rule: Keychain accounts (`database-key-v1`, `llm-server-v1`,
  `llm-bearer-v1`), `UserDefaults` keys, enum raw values stored on disk (for example `MeetingAppFamily`, `ServerKind`)
  and JSON keys already in stored data. Add new fields as optional and decode them with `decodeIfPresent`; never
  rename or reuse an existing key or raw value.
- **The files themselves** (the encrypted snapshot, its journal and backups) have goldens: `FormatGoldenTests` opens a store
  with its journal and restores a backup that an earlier build wrote (`Tests/VautaCoreTests/Fixtures/Formats`). A new
  envelope, journal or backup version keeps reading the old files and adds a golden of its own, written once with
  `VAUTA_WRITE_FORMAT_GOLDENS` (see the test); an existing golden is never written again.

## Adding a meeting app

Meeting apps are grouped into families in
[`Sources/VautaCore/Capture/MeetingAppCatalog.swift`](Sources/VautaCore/Capture/MeetingAppCatalog.swift). A family
decides which processes Vauta captures as "Others".

**A new app in an existing family** (for example another Chromium browser):

1. Add a `MeetingApp("Display name", "bundle.id")` entry to the family in `MeetingAppCatalog.apps`.
   - `helpers: true` (the default) also matches `<bundle.id>.helper…` processes, which is where Chromium and Electron
     apps play audio. Use `helpers: false` for apps whose audio runs in shared processes (WebKit and Gecko browsers).
   - `webApps: true` also matches installed web apps (`<bundle.id>.app.<hash>`), for Chromium browsers that support them.
2. Find the real bundle IDs with `Vauta status` while the app is in a call: it lists every process playing or recording
   audio with its bundle ID and detected family.
3. Add the bundle IDs (the app and the helper that plays audio) to the arguments of `matchesFamily` in
   `Tests/VautaCoreTests/CaptureCatalogTests.swift`.

**A new family** (a new native meeting app):

1. Add a case to `MeetingAppFamily`. Its raw value is persisted, so choose it carefully and never change it.
2. Give it a `displayName` and its apps in `MeetingAppCatalog.apps`. Check whether the default `tapBundleIDs`
   and `sharedRules` fit, or whether the app plays audio through a shared or system process.
3. If the service has meeting links, add a `ConferencingService` case and its URL pattern in
   [`ConferencingLink.swift`](Sources/VautaCore/Capture/ConferencingLink.swift), and map it with `appFamily`.
4. Add tests for the bundle IDs and links, and add it to [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) as
   "Expected — needs verification" until someone has confirmed it in a real call.

## Adding a model server profile

A server profile describes how to talk to one kind of OpenAI-compatible server. It lives in
[`Sources/VautaCore/LLM/ServerProfile.swift`](Sources/VautaCore/LLM/ServerProfile.swift) and detection lives in
[`Sources/VautaCore/LLM/ServerDiscovery.swift`](Sources/VautaCore/LLM/ServerDiscovery.swift).

1. Add a case to `ServerKind`. Its raw value is stored in the user's server configuration: never rename it. Unknown
   values decode as `.openAICompatible`, so older versions still read newer configurations.
2. Fill in `defaultPort`, `displayName` and `nativePaths`. `nativePaths` are the only endpoints outside `/v1` that
   Vauta may request on that server, so list only read-only identification endpoints.
3. Add its defaults in `ServerProfile.defaults(for:)`: how reasoning is switched on or off (`ThinkingControl`) and
   which `response_format` it accepts (`StructuredOutputSupport`). If it needs a new request dialect, add a case to
   `ThinkingControl` or `StructuredOutputSupport` and build it in `ServerRequests.chatBody`.
4. If it has a well-known port, add it to `ServerDiscovery.knownPorts` and teach `identify` to recognize it from its
   native endpoints. Discovery only ever probes loopback addresses.
5. Add tests with `StubServer`: detection in `ModelsDiscoveryTests.swift` and request bodies in
   `ModelsRequestTests.swift`.
6. Never change `ServerProfile.legacy`. Configurations saved without a profile must keep sending exactly the same
   requests as before.

## Localization

The development language is English, and translations live in `Resources/<lang>.lproj`. How to add or update a
language, and how `scripts/check-strings.sh` validates translations, is described in
[docs/TRANSLATING.md](docs/TRANSLATING.md).

As a developer, make every new user-facing string localizable (see [Coding conventions](#coding-conventions)) and
write a `comment` that tells translators where the text appears.

## Visual review

`scripts/render-ui.sh` renders the main views to PNG files, so you can review the interface (and every translation)
without launching the app, and refresh the README screenshots:

```sh
scripts/render-ui.sh                          # en, es, ja, light and dark -> build/ui-snapshots
scripts/render-ui.sh out --all-langs          # all nine interface languages
scripts/render-ui.sh out --langs "de ja" --appearance dark --scale 2
scripts/render-ui.sh out --only "meetings-,settings-status"   # only scenes whose names start with these
```

Files are named `<area>-<state>-<lang>-<appearance>.png` (for example `settings-models-ja-dark.png`): the menu-bar
panel (idle, recording, warnings, banners, long meetings), every Settings pane and its states (plus `-full` scenes that
show a whole pane at once, and Status with problems), the Context editor (locked, empty, pending calendar people),
every Welcome page, the model server guide, the live-translation captions, the Meetings window (locked, no meetings,
summary, minutes queued or failed, tasks, transcript, Ask, open tasks, people, empty, search and busy states) and every
sheet (export, import, backup, restore, merge, delete, erase). Native alerts and confirmation dialogs are separate
system windows and are not drawn.

How it works, and what to keep in mind:

- It builds a diagnostics app bundle (`-DVAUTA_DIAGNOSTICS`, ad-hoc signed, without the sandbox, bundle ID
  `local.vauta.snapshots`) in a temporary directory outside the project, and runs `Vauta render-ui <out-dir>
  [--lang <code>] [--appearance light|dark|both] [--scale 2]` from it. The command exists only in that build and
  refuses to run under any other bundle ID, so it never shares a container, Keychain item or preferences with a real
  install. Like `spike`, the diagnostics build is never signed for distribution or installed.
- The views run for real, on invented meetings (English, Spanish and Japanese content; other languages use the
  English content with a translated interface). They read a temporary encrypted store with an in-memory key: no real
  meetings, no Keychain, no network, no permission prompt, no audio. The sample data lives in
  `Sources/VautaCore/Diagnostics/` and the scenes in `Sources/Vauta/Snapshots/`.
- Views are drawn in an offscreen AppKit window and captured from it (not with `ImageRenderer`, which cannot draw
  lists, forms and text views). Nothing appears on screen. The window reports being active and key, so default
  buttons, switches and selections use the accent colour as in the real app; the few things AppKit only draws with a
  window behind them (selection highlights, the tab bar, sidebar text in dark mode) are redrawn as the real window
  shows them (see `SnapshotHost`). The interface language comes from the bundle's `.lproj`
  folders, so the command restarts itself with `-AppleLanguages` for the requested language.
- Not drawn as in the real app: window shadows, the blur of translucent materials (the captions and menu-bar panels
  sit on a plain backdrop), menus, popovers, tooltips, hover and focus rings. Check those in the running app.
- A few lines describe the Mac that renders them, not the sample data: Apple Intelligence availability and the
  permission, notification and login-item rows of Settings › Status (`settings-status-problems` uses sample states).
- A new window or state: add a scene in `SnapshotScenes.swift` (or the `SnapshotScenes*.swift` file of its area). A new seam in production code must stay inside
  `#if VAUTA_DIAGNOSTICS` and be small.

## Commits and pull requests

- Keep each pull request focused on one change. Separate refactoring from behavior changes.
- Write commit messages in English, in the imperative mood, with a short subject line (about 72 characters or fewer)
  and a body that explains why when it isn't obvious:

  ```text
  Detect Webex helper processes as call audio

  Webex plays meeting audio from Cisco-Systems.Spark.helper, which the
  catalog did not match, so "Others" stayed silent.

  Signed-off-by: Your Name <you@example.com>
  ```

- Before opening the pull request, build in release mode and run the tests and checks above.
- Fill in the pull request template: what changed, how you tested it (macOS version, meeting app or browser, languages)
  and the checklist.
- Update the documentation and `CHANGELOG.md` when behavior changes.
- Never include real meeting content, recordings, screenshots of real meetings, keys or personal data in issues,
  commits, tests or fixtures.

### How changes reach `main`

Changes reach `main` only through pull requests that pass CI and CodeQL, every commit must be signed, and force pushes are
blocked: a ruleset enforces it (the full list, including how reviews work with a single maintainer, is in
[GOVERNANCE.md](GOVERNANCE.md#repository-controls)). Sign your commits with an SSH or GPG key that you added to your GitHub
account as a signing key (`git commit -S -s`, or `git config commit.gpgsign true`), so GitHub shows them as Verified; otherwise
the pull request cannot be merged as it is. Pin any GitHub
Action you add by its full commit SHA with the version in a comment, and give each workflow the least permissions it
needs. Releases are made by maintainers only, as described in [docs/RELEASING.md](docs/RELEASING.md).

## Developer Certificate of Origin

Vauta uses the [Developer Certificate of Origin](https://developercertificate.org/) (DCO) instead of a contributor
license agreement. By signing off a commit, you certify that you wrote the change, or otherwise have the right to
submit it under the project's open source license (Apache-2.0).

Sign off every commit with `-s`:

```sh
git commit -s -m "Detect Webex helper processes as call audio"
```

This adds a line with the name and email from your Git configuration:

```text
Signed-off-by: Your Name <you@example.com>
```

Use your real name. To sign off (and sign) commits you already made on your branch, run
`git rebase --signoff --gpg-sign main` and force-push the branch. The project lead checks the sign-off of every commit before
merging and asks for it when one is missing.

Contributions are licensed under the [Apache License 2.0](LICENSE), as stated in its section 5.
