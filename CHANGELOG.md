# Changelog

All notable changes to Vauta are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Vauta follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- A new app icon in the website's colours: a lit sphere in indigo, blue and teal carrying a white waveform, with an orbit around it, on a dark sky (`tools/make-icon.swift`).
- The menu-bar panel takes Vauta's own colours, as on the website: the record button is a lit sphere in indigo, blue and teal, red into magenta while recording, with a ring around it; while recording, rings breathe out from it (still with Reduce Motion) and its glow follows the loudest channel. A soft glow in the same colours sits behind the header and fades out below the meters (none with Increase Contrast), the header shows the app icon, and the elapsed time uses rounded figures.

### Security

- "Erase Everything" deletes the database key, checks it is gone and adds a new one; a key item that appears in between is never adopted.
- Restoring a backup compares its schema with Vauta's ignoring SQL comments: an apostrophe in a comment no longer hides a changed string literal in the statement after it (`item_links`).
- The model server's key and configuration are saved as a new Keychain item each time instead of updating an existing one, so they never take on an access list another app set.
- A document's stored path is opened only if it is one the folder scan lists (no `..`, nothing hidden), so it cannot lead outside the folder you chose.
- The release workflow runs the tests and the build with read-only access; only a separate job that runs no repository code can create the draft release.
- SECURITY.md describes the documents index, a key item planted before Vauta creates its store, the limit of a model server on this Mac when other accounts use the same Mac, and the signed `vauta-0.9.0` tags and rulesets that keep the MLX fork commits fetchable. The network entitlement comment names the model download hosts.

## [0.9.0] - 2026-10-27

The first public release (public beta). Compared with 0.1.0, Vauta is open source, works with any meeting app and any language Apple supports, and can write minutes with Apple's on-device model or an optional integrated model. Evaluation figures and their limits are in [docs/BENCHMARKS.md](docs/BENCHMARKS.md) and [docs/CLAIMS.md](docs/CLAIMS.md).

### Added

**Recording and capture**

- Capture the other participants from any meeting app or browser (Safari and WebKit, Chromium and Gecko browsers, Zoom, Teams, Meet, Slack, FaceTime, Webex, Discord and more). The audio source is **Auto** (the app using the microphone), chosen apps, or all system audio; the tap follows the app's helper processes while you record. See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).
- A capture alert when a meeting app holds the microphone but nothing reaches Others for a minute, with what to check.
- Calendar events are recognised by their meeting links, and the call suggestion names the app and the meeting service.
- Transcription in every language Apple's speech recognizer supports on your macOS, with a language per meeting and speech models installed from the app.
- A consent helper: a dismissible notice to paste into the meeting chat, in the meeting's language, and a record of when participants were informed.

**Speakers**

- Speaker separation on this Mac with two small bundled neural models (pyannote community-1 segmentation and WeSpeaker ResNet34-LM, CC BY 4.0): *Speaker 1*, *Speaker 2*… while recording and in imports, refined when the recording stops. On by default; it never delays transcription. The bundled models are checked against pinned SHA-256 hashes, nothing is downloaded, no audio is stored, no voice is kept between meetings and no network path is added. Diarization error rate fell from 10.8% to 9.5% on 19 held-out English recordings and from 9.4% to 7.2% on 12 synthetic Spanish conversations ([BENCHMARKS.md](docs/BENCHMARKS.md#diarization-error-rate)).
- Name speakers in the transcript; names flow into the minutes, task owners, search, Ask, a person's card and exports (SRT, WebVTT, Markdown, text, PDF, JSON).
- Opt-in voice recognition across meetings (**Settings → Speakers**, off by default): a saved voice only suggests who is speaking ("Is this Ana?") and never names a speaker by itself. Voice data stays in the encrypted store and in backups you make (restoring one brings its voices back, including voices you deleted after the backup), and never appears in exports, logs, prompts or the network. Voice summaries kept with a meeting last 14 days at most.
- `Vauta diarize` and `Vauta speaker-models` commands.

**Minutes, Ask and notes**

- **Apple Intelligence** (Apple's on-device model) can write minutes and answer questions with no setup, labelled "Quick start · Basic quality".
- An optional **integrated language model**: Google's Gemma 4 E4B-it, run inside the app on MLX, for Macs with 16 GB or more. It is never the default and is downloaded only when you click Download (a 15 GB transfer from Hugging Face, quantised on the Mac to about 4.2 GB and verified against pinned hashes). While you record it reads the transcript incrementally, so minutes and answers start sooner. See [docs/LANGUAGE_MODEL.md](docs/LANGUAGE_MODEL.md).
- Guided model server setup (*Set Up a Model Server*) for LM Studio or Ollama, with a model suggested for the Mac's memory, and automatic detection of servers on this Mac (LM Studio, Ollama, llama.cpp, MLX, vLLM, Jan, LocalAI) with per-server profiles.
- Minutes templates (general, one-on-one, stand-up, client call, interview, class), minutes in the meeting's language or a chosen one, progress and cancel, retry, and minutes for meetings interrupted by a crash.
- Every decision and task is checked against the passage it cites (figures, dates, names); task owners come from the transcript. Items that do not hold up are marked **Unconfirmed**. On Apple's model the decisions and tasks are ranked and the rest are shown apart, collapsed, under **Other possible items**.
- **Notepad**: shorthand bullets typed during or after a meeting become complete notes, each sentence citing the transcript; your own words are never rewritten.
- **Live answers** (Settings → Recording): questions asked aloud are noticed on this Mac and answered in the panel with verified, cited claims. Off by default on every model, and not offered with Apple's on-device model. Apple's model and the integrated model failed the evaluation gates (2% and 21% of shown answers judged correct, against 85%), and a model server has not been measured.
- An optional **search model** (EmbeddingGemma 2 by Google, 574 MB) for search by meaning across languages, downloaded only on request and verified against pinned hashes. Ask, the sidebar search and related documents rank by meaning when it is installed. Cross-language questions are translated on this Mac for keyword search.
- **Documents** as knowledge sources (PDF, Word, Excel, PowerPoint, Markdown, text, RTF, HTML, CSV and more) for Ask and the brief. Files kept online only are skipped and counted; Vauta never downloads them.

**Before and after a meeting**

- A **pre-meeting brief** with Calendar on: who is coming, what the last meeting left open, related meetings, documents, notes and reminders, built on this Mac. A notification (10 minutes before by default) says only that a brief is ready. A model-written agenda is off: no backend passed its usefulness gate. See [docs/BRIEF.md](docs/BRIEF.md).
- **Follow Up…** (⇧⌘U) turns a meeting's open tasks into reminders and agreed follow-up meetings into Calendar events, one confirmed item at a time, with Undo and protection against adding a task twice. Vauta suggests at most 2 follow-up meetings found in the transcript. See [docs/ACTIONS.md](docs/ACTIONS.md).
- Built but off in this release, because they did not pass their judged evaluation: the follow-up email draft and links between a task or decision and the same one in an earlier meeting.

**Meetings window and app**

- Meetings, Ask, Tasks and People modes, search, export (Markdown, plain text, PDF, SRT, WebVTT, JSON), import of audio and video recordings, and an editor for people, projects, clients, topics, glossary terms and recurring meetings.
- **Live Translation**: a captions panel that translates the other participants into your language with Apple's Translation framework, optionally improved by your model server; translations are stored with the transcript.
- **Back Up… / Restore…**: all meetings, context and settings in one file encrypted with a password you choose. Model server keys are never included.
- A first-run setup, a redesigned menu-bar panel and Settings, notifications without meeting text, configurable shortcuts, a relock time for the Meetings window, and accessibility labels and keyboard navigation.
- Interface translations: Spanish, French, German, Italian, Brazilian Portuguese, Japanese, Korean and Simplified Chinese.
- Command line: `doctor`, `languages`, `help`, `--version`, and `--locale` for the speech commands.

**Privacy, auditing and open source**

- **Network Activity** (Settings → Privacy & Security): a live list of every connection Vauta makes, with its purpose and destination. All network access goes through one audited code path, enforced by a test.
- Apache License 2.0, `NOTICE`, SPDX headers, unit tests, continuous integration, CodeQL and OpenSSF Scorecard workflows, and issue and pull request templates.
- An evaluation harness under `eval/` (pinned public corpora, diarization error rate and word error rate, held-out sets) and `docs/CRYPTO_REVIEW.md`, an internal review of the cryptography (not an audit).

### Changed

- Vauta is distributed as **source code only**: you clone the repository and build it on your own Mac. There are no signed or notarized downloads.
- One third-party package: a pinned fork of MLX (MIT), which brings in Apple's swift-numerics; otherwise Apple frameworks and the system SQLite. `scripts/check-dependencies.sh` enforces it.
- The minimum system is **macOS 26** (0.1.0 needed macOS 27).
- New name and tagline: "Your meetings, locked in your Mac."
- Data from an earlier version (0.1.0, bundle ID `local.acta.app`) carries over when you build with that bundle ID: the store files are renamed in place on first open (verified with the key first; nothing is deleted), and the server key moves to a new Keychain item. Backups are now `.vautabackup`; older backup files still restore. Builds from source use the bundle ID `local.vauta.app` unless `VAUTA_BUNDLE_ID` is set.
- The interface, command-line output, prompts and source code are in English, and the interface is localized.
- New installs capture **Auto** by default; an upgrade from 0.1.0 keeps capturing Safari only until you change it.
- Copy protection is a setting in Privacy & Security: off for new installs, on for installs upgraded from 0.1.0.
- Privacy wording was checked in every language, and `scripts/check-strings.sh` fails if a translation promises more than the English text.
- Store updates are more durable (full syncs, directory syncs after renames, Keychain items updated in place), and errors explain what happened and what to do.

### Fixed

- Minutes written with Apple's on-device model no longer fail with "cut off at the length limit" on meetings of 30 to 60 minutes.
- A brief task is "Overdue" only when its due day is before today.
- Text that was cut, colour contrast and VoiceOver names found in a review of every screen in nine languages, light and dark.
- Leaving a call is detected promptly; a headset that is also the clock device is read correctly; transcription warnings clear when the channel recovers.
- Rewriting minutes keeps your edits; merging or deleting a person updates every reference; search keeps acronyms and short names.
- Answers cut off at the token limit, or replies that are not JSON, are retried once; a locked Keychain or a model still downloading no longer uses up retries.

### Security

- Model downloads use a dedicated network purpose and an exact destination allowlist (`huggingface.co` and its named download host, no wildcards); redirects are never followed automatically, and nothing is requested at launch.
- Downloaded models are data, not code: bounded, fuzzed parsers, no pickle and no remote code, and no entitlement was added for MLX.
- Changing the model server's mode, address, CA or pins removes the saved key instead of sending it to the new destination.
- Stricter local-network rules for model servers: proper IPv6 parsing, IPv4 addresses with leading zeros rejected, and host names require your own CA or a pinned key. The address is checked again after connecting, which stops the requests that follow but not the first one; that is why host names need your own CA or a pin.
- Every certificate in a CA bundle is trusted as an anchor, and a bundle with a malformed certificate is rejected.
- `doctor` and `store-stats` never create a store or a key.
- Erase Meetings and Context removes the key and the data from this Mac, but older backups of the login Keychain may still hold the old key.
- Model downloads send no token or identifier, and the signed download address and its query string are never logged.

### Removed

- Apple's on-device embeddings (`NLContextualEmbedding`), the old "Search by meaning on this Mac · Experimental" option: in every benchmark it found passages worse than keyword search. A saved choice moves to keyword search and its stored vectors are deleted.
- The `store-selftest` command; its checks run in the test suite.

## [0.1.0]

The first version, used privately before the project was published. Safari and Spanish (Spain) only, with minutes written by an OpenAI-compatible model server on this Mac or on the local network.

[0.9.0]: https://github.com/MaquinaTech/Vauta/releases/tag/v0.9.0
