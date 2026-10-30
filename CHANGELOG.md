# Changelog

All notable changes to Vauta are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Vauta follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The speakers' echo.** With speakers instead of headphones the microphone hears the other participants, and Vauta wrote their words again as yours, so the minutes gave you their words and their tasks. Every finished recording now marks those lines. They stay in the transcript, dimmed, with **It Was Me** to take a mark back (it can be undone), and they are left out of the minutes, notes, answers, owners, search, talk time and exports. A line the person says is theirs is never marked again. A recording in which the microphone never heard the others (headphones) marks nothing. Meetings recorded earlier, and a recording a crash left open, are checked once at the next launch, in the background. Their minutes are not rewritten: **Regenerate** writes them without the echo.
- While recording, the panel suggests headphones when the meeting plays through speakers: the Mac's own, a display, AirPlay, or any output the microphone is heard to pick up, such as Bluetooth or USB speakers. **Dismiss** hides it for the recording.

Developer tools:

- `Vauta llm-eval --tasks echo` measures the speakers' echo detection on public transcripts, with no audio and no model. Each participant is replayed as the Me channel with the others' speech heard again 0.03, 0.15 or 0.4 s later and 10–30 % of its words wrong, and once more with the far side sending every line back. It writes the score of every setting to `echo/sweep.tsv`. On the 24 DEV meetings the release settings find 90.7 % of the echo's words and mark 0.30 % of the participants' own lines.
- `Vauta echo-coupling <me audio> <others audio>` measures, over two files, whether a recording's microphone heard the others, as the app does while recording. `eval/scripts/run_echo_coupling.py` runs it on the 10 AMI meetings: no meeting heard over headphones, and none taken for headphones when the microphone heard the others, even as faint cross-talk ([BENCHMARKS.md](docs/BENCHMARKS.md#whether-the-microphone-heard-the-others)).
- `Vauta llm-eval` writes the replies of a minutes run that failed to `minutes/<meeting>.<provider>.failed.json`, so the cause can be read.
- `Vauta transcribe-file --show-text --out <words.jsonl>` also writes every recognised word with its time and the recognizer's confidence, which the app itself does not ask for. `eval/scripts/run_wer.py --confidence` uses it on public audio to measure what asking costs (WER and time against the plain pass) and how well the confidence predicts a right word (reliability bins, ECE, Brier, AUROC), before anything in the app relies on it. On the 10 AMI meetings asking changes no word and takes no longer, and the confidence tells right words from wrong ones with an AUROC of 0.79 on the headsets and 0.77 on the remote mix ([BENCHMARKS.md](docs/BENCHMARKS.md#word-confidence)).
- `Vauta llm-eval` can write the minutes of public transcripts and answer their questions on a model server (`--providers server --server <config.json> [--ask-key]`), through the app's own client and address rules, and runs several minutes variants of one backend interleaved in one run (`--variants old,new`).
- Ask on a model server can reason briefly before an answer after the meeting (`low` effort, with its own room and no schema over it). It stays off in this release until it is measured: `llm-eval --tasks live-answer --providers server --after-meeting --ask-reasoning on,off` asks each question both ways in one run.
- The statistics the evaluation gates use (Wilson intervals, exact sign and McNemar tests, meeting-cluster bootstrap, kappa, Jeffreys gates, paired TOST, Holm and BH) are in `tools/llm-eval/stats.py`, standard library only, with tests that CI runs.

### Changed

- A task owner given by a speaker whose voice probably mixes two people is marked **owner not confirmed**. Speaker separation can put two similar voices, or one person's line, in another person's speaker, and the minutes then gave that person the other's task with nothing to say so. Vauta now keeps how tight each speaker's voice is (one number, not the voice), and the owners that a loose speaker's lines give stay, marked. A line you moved to a speaker yourself is not marked. Meetings whose speakers were separated earlier are not marked.
- With a model server whose structured output is "JSON schema" or "JSON object" (Settings → Models → Advanced), the minutes' block extracts, merges and closing request and the live notes ask for their shape in `response_format`, as Ask already did. The requests with reasoning on send none. A server that answers 400, 415 or 422 to it is asked once more without it.

### Fixed

- A recording no longer fails to start for a speech model that Settings shows as installed, with no way to download it. After an update re-signs an ad-hoc build, macOS still lists the model as installed, but Vauta can no longer use it. Settings, the first-run setup, `Vauta languages` and `Vauta doctor` now count a model as installed only when Vauta can use it, so they offer the download the recording needs.
- The first seconds of a recording are no longer lost while the speech analyzers start. The microphone and the system audio start first, and their audio waits for the analyzers.
- A stall or a gap in the system audio no longer "corrects" its sample rate when the rate was right. The rate is measured on the capture times, and a correction needs two windows that agree.
- Custom vocabulary no longer asks the recognizer for the misspellings Vauta learned from accepted corrections. Vauta still recognizes them as the name.
- Undo and **Remove from Reminders…** no longer ask whether you changed a reminder or event there when you didn't. On a busy Mac the item could be saved more than ten seconds after Vauta recorded it was adding it, and it looked edited. The ten seconds now run from the save.
- On a model server, once the reasoning of the minutes has run past the length limit, the one repair of an answer that can't be read no longer reasons again. Two DEV meetings spent another 10,000 tokens, some ten minutes each, there.
- On a model server whose reasoning keeps running past the length limit, the minutes no longer spend it every time. After two minutes in a row whose reasoning ran out, the next five are written without it, then Vauta tries again. With qwen3.5-9b on MLXServer, 49 of the 51 reasoning requests of the 24 DEV meetings ran out, some ten minutes each and 70 % of the run's time, and those minutes came from the request without reasoning anyway.
- A task the model writes with the speaker's label ("Speaker 5 to build the dictionary") is no longer "to be confirmed" because the label's number is not in the quoted words, and the new extraction no longer drops it as reported speech. On a model server (qwen3.5-9b, the 21 DEV meetings, replayed) the reference's firm tasks and decisions found among the confirmed items rose from 29 % to 44 %, while the confirmed items that match the reference went from 57 % to 54 % (within the noise). Apple's model rarely writes items that way: 2 of 24 meetings changed.
- On a model server without structured output, the minutes had almost no open questions: the model wrote them as objects, the way it writes decisions, and Vauta skipped them. They are read now, and the usual checks judge them. On the 24 DEV meetings (qwen3.5-9b, replayed) the open points of the reference found in the minutes rose from 4 of 123 to 44 of 123.
- `scripts/update.sh` stopped with `unbound variable` before verifying the release, in shells that read the `…` after a variable name as part of the name. If it stopped for you, run `git checkout main && git pull` once and run it again.
- `scripts/update.sh` ended with `dir: unbound variable` and exit status 1 after a successful install, and left a temporary folder behind.
- Checking the model server (Settings → Status, Test Connection, or installing the search or integrated model) no longer cancels minutes or an answer that are on their way.
- A request to the model server that raced with a new server configuration could close the app. It now ends as cancelled.
- Ask within one meeting, and a search in a meeting's materials or in one source, no longer miss that meeting's or those files' passages when the rest of the library has more than 400 closer passages on the same topic.
- When a follow-up email draft is handed to the mail app through a `mailto:` link, the system log no longer receives the link (with the addresses, the subject and the body, marked private). It records only the number of recipients and the link's length.
- The notepad's note in Settings → General and the documentation no longer say that Vauta's windows are always hidden from screen sharing: Vauta asks macOS to keep them out, which is not guaranteed. The documentation also corrects other claims the code no longer supports, among them the integrated model's download in SECURITY.md.
- `Vauta minutes-file` (an evaluation command) measures the minutes the app actually sends to Apple's model, and its result file names the parts that ran.
- Minutes no longer fail when Apple's model declines part of a meeting, or a part does not fit the model's window. A meeting declined as a whole is written by blocks; a declined block is left out and counted, a declined merge keeps its group, a final request that does not fit goes by the digest, and a digest declined twice keeps the checked decisions, tasks, topics and questions without a title or summary. Only a meeting whose every block is declined fails, and it says the model declined.
- On a model server, minutes whose reasoning runs past the length limit are asked once more without reasoning, at the same limit, instead of with twice the limit. With Qwen3.5-9B on an MLX server the closing request's reasoning ran to the 10,000-token limit and then to about 20,000 (some 30 minutes in all), and the minutes failed.
- `Vauta server-check --ask-key` stops and says so when nothing was typed at the key prompt, instead of sending the requests without a key and reporting that the server rejected it.

## [0.9.3] - 2026-10-28

Fixes from a review of the code after 0.9.2, and a safe way to update.

### Added

- `scripts/update.sh` updates Vauta to the newest release: it verifies that the release tag is signed by the maintainer's key (against the `.github/allowed_signers` already on your Mac and the fingerprint in SECURITY.md), refuses to go back to an older version, shows the release notes, runs the tests and installs with the same bundle ID and signing method. From a version before 0.9.3, run `git pull` once first.

### Fixed

- Pressing Stop now stops the microphone and the system audio at once. Before, they kept running while a note being typed was saved, so a few words said right after the stop sound could reach the meeting.
- A backup could pass the schema check with SQL hidden behind comment markers inside a quoted name (`"--"`), such as an extra trigger that would then run in your store. The check now reads quoted names whole.
- A model server on another computer given by name (for example `gpu.local`) needs a private CA or a certificate pin, as documented, also when the pasted configuration or the `server-check` file has no server type. Only a configuration saved by 0.1.x keeps working without them, with a warning; editing it asks for the CA or pin.
- Backup passwords of 12 or more characters but fewer than 6 different ones (such as `111111111111`) are refused, as the hint already said.
- A second clone of Vauta, or a new folder, on a Mac where `setup-signing.sh` had already finished was told to delete the signing keychain, which changes Vauta's signature and makes macOS ask for every permission again. `setup-signing.sh` and `install.sh` now find the existing identity and use it.
- `install.sh` and the README no longer say to deny every later Keychain prompt: macOS asks again after each update of an ad-hoc build and after a new signing identity, and denying it then leaves Vauta without its store.

Recording:

- Me and Others now share one clock. Each channel's audio is placed by the time it was captured, so a gap (a Bluetooth headset dropping out, the microphone being reconfigured, the system audio being reconnected) stays a gap instead of shifting that channel for the rest of the meeting, and the transcript stays in order. Marks, notes and live notes use the same clock, so a slow start (for example the first microphone prompt) no longer moves them later than the transcript.
- If on-device transcription fails in the middle of a meeting, that channel is restarted at the same point (up to three times) instead of staying silent for the rest of the meeting.
- Saving a meeting can no longer stay in "Saving" forever: finishing the transcription, the speaker separation and the speaker names each have a time limit.
- A lost microphone is tried again every few seconds while recording, so one that comes back late is used again.
- Stopping while a recording was still starting no longer leaves live answers running, and what was transcribed during a cancelled start is not kept (notes typed meanwhile are).
- Live speaker labels are recomputed less often as a meeting grows (meetings under about 7 minutes are unchanged), so they keep up in meetings of several hours.

Model servers:

- For a server given by name, nothing with content or the key is sent until Vauta knows the address it connects to is on your network: a first request without either checks it. A later new connection is checked when it completes, as before, and the private CA or pin still protects it.
- "On the same network" addresses are accepted only for IPv6; an IPv4 address must be private.
- Checking a server's certificate never fetches anything from a certificate authority, with or without a private CA. A server with a public certificate must send its full chain (`tailscale cert`, Caddy and `fullchain.pem` do).
- A model loaded with less than 8K of context is no longer shown as 8K: Settings says it is too short, and `server-check` warns when a model is loaded with less context than configured.
- Error messages from a server never show a key or an `Authorization` header.
- Finding servers on this Mac and reading a streamed answer stay fast and bounded with a misbehaving server.

Backups and your data:

- A restore interrupted by a crash or a power cut no longer leaves the store unreadable: the new key is kept next to the old one until the restored data is on disk, and the next launch finishes the restore. The key item is written anew with Vauta's own access list.
- Saving a backup over an existing file never truncates it if the write fails, and cancelling no longer deletes the new file after the old one was replaced.

Meetings, actions and documents:

- Due days on a day that has no midnight in its time zone (for example 6 September 2026 in Chile) are no longer dropped.
- Follow-up meetings read from the transcript more than a year away are no longer suggested, and a past date no longer hides a later one in the same sentence.
- Opening a linked material or a brief's file that is only in iCloud or Dropbox no longer downloads it: Vauta says it is online only, as it already did elsewhere.
- Numbers the model writes in the minutes no longer take the Mac's number format: 2026 stays 2026, never "2.026".
- VoiceOver reads "Document" for a citation without a file name instead of nothing.

Install and release:

- The version comes from `Resources/Info.plist`, so a clone without the newest tag builds the right version; the release workflow refuses a tag that doesn't match it.
- A throwaway build can use its own bundle ID (`VAUTA_BUNDLE_ID=local.vauta.dev`), so it never opens your installed Vauta's data.
- `install.sh` opens Vauta when the same build is already installed, and a protected Trash no longer stops it after installing; `setup-signing.sh` locks the signing keychain however it ends.

## [0.9.2] - 2026-10-28

Fixes for installing from source. No change to the app.

### Fixed

- `scripts/setup-signing.sh` failed on Macs with a newer OpenSSL from Homebrew (4.x): the certificate file it hands to the Keychain used algorithms `security import` cannot read, and macOS reported it as "MAC verification failed during PKCS12 import (wrong password?)", although no password was wrong. The script now names the algorithms macOS reads, whatever the OpenSSL version, and if the import still fails it says so instead of looking like a wrong password. To recover from the failed attempt, run the script again: it rebuilds the empty signing keychain on its own.
- A signing setup that stopped half-way (for example a wrong or cancelled Mac password at the trust step) no longer leaves you going in circles between `install.sh` ("run setup-signing.sh") and `setup-signing.sh` ("already exists"): both now say the keychain is left over and give the command that deletes it. Running `setup-signing.sh` again after a finished setup says there is nothing to do.
- The trust step of `setup-signing.sh` asks for the Mac's login password up to three times, and says it is the Mac's password, not the new one.
- `install.sh` asks for the signing keychain's password up to three times, says which password it is, and explains what to do if it is lost, instead of stopping at the first mistake after the whole build.
- If OpenSSL cannot create the certificate, `setup-signing.sh` says so instead of stopping without a message.

## [0.9.1] - 2026-10-28

The look of the website comes to the app (a new icon, Vauta's animated sphere, Welcome and the menu-bar panel in Vauta's colours) and the security fixes of the audit after 0.9.0. No change to recording, transcription, the minutes or the stored data.

### Changed

- A new app icon in the website's colours: a lit sphere in indigo, blue and teal carrying a white waveform, with an orbit around it, on a dark sky (`tools/make-icon.swift`).
- Vauta's core, as on the website: one animated view, a lit sphere with colours drifting inside and a ring of particles in orbit. It is the record button (red into magenta while recording, with two soft rings that ripple with the loudest channel; the orbit spins while Vauta starts or saves), the hero of Welcome, the base of the empty and locked states, and a small "thinking" sphere wherever Vauta's model works (answers, the brief, notes, Ask, the minutes, finding names). Still with Reduce Motion and in renders; 15 to 60 frames a second depending on the state.
- The menu-bar panel takes Vauta's colours: a soft glow behind the header that fades out below the meters (none with Increase Contrast), the app icon in the header, rounded figures for the elapsed time, card icons in Vauta's gradient, level meters that glow in each speaker's colour, and a hairline edge in Vauta's colours on what Vauta writes on its own (live notes, answers, the brief, the follow-up).
- Welcome shows what Vauta does in four short cards (transcription, minutes and tasks, Ask, privacy) that come in one after another; the full privacy promise stays in Settings › Privacy & Security. Setup has a progress line in Vauta's colours above its buttons, page symbols in Vauta's gradient, and the sphere with a check mark when everything is set up.
- The sphere fades between states, comes in with a slight grow when it appears, and the record button gives a little when pressed (none of this with Reduce Motion). A faint orbit stays on the quieter button while a suggestion sits above it, restoring or erasing use the working sphere, the sphere has no halo with Increase Contrast, and its rings are calmer in light appearance. Every last page of Setup and the search results show the sphere.
- Ask: Vauta's sphere by the title, example questions as capsules with a sparkle and an edge in Vauta's colours, and the answer in a card with the same edge as in the panel.
- Settings' sidebar shows each pane's symbol in white on a coloured square, as in System Settings; Setup's lists and the privacy promises use Vauta's gradient, deeper in light appearance.
- The sparkles that mark what the model wrote (decisions, tasks, notes, the minutes) are Vauta's indigo instead of the system blue, with the same contrast; a faint glow in Vauta's colours sits behind the top of each meeting.

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

[0.9.3]: https://github.com/MaquinaTech/Vauta/releases/tag/v0.9.3
[0.9.2]: https://github.com/MaquinaTech/Vauta/releases/tag/v0.9.2
[0.9.1]: https://github.com/MaquinaTech/Vauta/releases/tag/v0.9.1
[0.9.0]: https://github.com/MaquinaTech/Vauta/releases/tag/v0.9.0
