# Architecture

This document explains how Vauta is put together, for contributors. For what Vauta stores and sends, see
[PRIVACY.md](../PRIVACY.md); for the threat model and the cryptography, see [SECURITY.md](../SECURITY.md).

## Principles

- **Local first.** Audio is processed in memory and never written to disk. Transcription is on device. The only
  network peer is the model server the user configured; the one other connection is the optional search-model download,
  which the user starts with a click.
- **One third-party package.** Apple frameworks, the system `libsqlite3` and a pinned fork of MLX (MIT), which runs the
  optional search model and is imported only by the `VautaMLX` target. (The two bundled speaker-separation models are
  weights, not code; see `NOTICE`.)
- **Deterministic where possible.** Names, search and validation are plain Swift. Models only propose text, and Swift
  checks every claim against the transcript before it is stored.
- **Testable core.** Logic lives in the `VautaCore` library; the app target is a thin SwiftUI and AppKit layer.

## Package layout

`Package.swift` defines four targets (Swift 6, strict concurrency, macOS 26, Apple silicon) and one remote dependency,
the MaquinaTech fork of mlx-swift pinned by revision (`scripts/check-dependencies.sh` and a test fail on any other
package or revision; swift-numerics comes with it):

| Target | Kind | Contents |
|---|---|---|
| `VautaMLX` | Library | The only place that may `import MLX` (a source-scan test enforces it): `MLXRuntime`, the bounds-checked `SafetensorsFile` and `ByteJSON`, `GemmaTextEncoder` (EmbeddingGemma 2 in MLX Swift, fp16, GPU) and `KernelSelfTest`. No content, no network |
| `VautaCore` | Library | Capture, transcription, storage, knowledge, model clients and services, export and import, and the pure logic behind the UI |
| `Vauta` | Executable | The menu-bar app (SwiftUI and AppKit) and the command-line tool. `main.swift` decides which one runs |
| `VautaCoreTests` | Tests | Swift Testing suites for `VautaCore` |

`Vauta` runs as a command-line tool when its first argument is a known command (`doctor`, `status`, `languages`,
`install-speech-assets`, `install-dictation-assets`, `transcribe-file`, `minutes-file` (evaluation only: writes the minutes of a public transcript with Apple's on-device model in a throwaway store), `store-stats`, `cert-pin`, `server-check`, `help`, the hidden `mlx-selftest [--model]` (kernel checks, and the search model's files, in the shipped binary; not in the help),
`version`, `--help`, `--version`) or any other word, which prints the usage instead of launching the app. With no
arguments, or only flags such as `-AppleLanguages (fr)`, it launches the menu-bar app. See `LaunchMode.parse` in
`VautaCore/App/CommandLineParsing.swift`.

## Data flow

```mermaid
flowchart LR
    mic["Microphone"] --> micCap["MicrophoneCapture"]
    tap["Core Audio process tap"] --> sysTap["SystemAudioTap"]
    micCap --> pipeMe["ChannelPipe (me)"] --> trMe["ChannelTranscriber (me)"]
    sysTap --> pipeOthers["ChannelPipe (others)"] --> trOthers["ChannelTranscriber (others)"]
    pipeOthers -.-> diar["Diarizer (own queue)"]
    trMe --> rec["RecorderModel (main actor)"]
    trOthers --> rec
    diar -.-> rec
    diar -. "via RecorderModel" .-> store
    rec --> store[("MeetingStore (actor)")]
    store --> graph["Knowledge analysis"]
    store --> llm["LLMService (actor)"]
    llm --> providers["ModelProviding"]
    providers --> server["Model server or Apple on-device model"]
    llm --> store
    store --> ui["Meetings, Ask, Context windows"]
```

1. **Capture.** `MeetingCapture` runs two channels. The microphone is always **Me**. **Others** is the audio of the
   meeting app, captured with a Core Audio process tap (`SystemAudioTap`) scoped by `SystemAudioScope`: specific app
   families from `MeetingAppCatalog`, the app that holds the microphone (`auto`), or all system audio except Vauta.
   `MeetingPresence` watches which app uses the microphone from Core Audio metadata only.
2. **Transcription.** `ChannelPipe` converts each buffer to the analyzer format and groups it into ~100 ms chunks.
   `ChannelTranscriber` feeds Apple's `SpeechAnalyzer` with `SpeechTranscriber`, or `DictationTranscriber` for custom
   vocabulary and for languages `SpeechTranscriber` does not support (`SpeechLanguages`). The two channels tell *you*
   (`Channel.me`, always one speaker) from everyone else (`Channel.others`); the people inside Others are told apart
   by speaker separation (next section). Both channels share one clock: time 0 is the first audio captured, and
   each chunk is placed by its capture host time (`ChannelTimeline`), so a device gap stays a gap instead of shifting
   one channel against the other; marks and notes use the same clock. An analyzer that fails mid-recording is
   rebuilt at the same position (`AnalyzerRetryPolicy`) before the channel is reported as stopped.
3. **Store.** `RecorderModel` receives segments and appends final ones to `MeetingStore`. Every 10 seconds the new
   writes go to the encrypted journal; a full encrypted snapshot is written when the recording ends.
4. **Knowledge.** When a meeting ends, the store resolves names in the transcript against the user's context
   (people, projects, glossary, series) and records mentions, ambiguous names and likely recognition errors as
   suggestions. This is deterministic: no model involved.
5. **Model jobs.** `LLMService.meetingEnded` queues two background jobs in the store (`llm_jobs`): `embed` (search
   vectors) and `acta` (the minutes). While recording, only live notes run, on the fast model. Ask runs on demand.
6. **Live Translation (optional).** When it is on, `RecorderModel.receive` hands each "Others" segment to
   `LiveTranslator` (a non-blocking `submit`); with the feature off there is no translator and the call is one optional
   check. The actor translates finals at once and in order, debounces the volatile tail, caches sentences and
   publishes captions at most ten times a second to `LiveTranslationModel`, which drives the captions panel. Final
   translations are stored in `segment_translations` through the same ordered write chain as the segments. When a model
   server is usable, each final is also refined by `ServerTranslator` (see "Live Translation" below); the refined text
   replaces the stored one through the same chain.
7. **Live answers (optional; on by default only for a model that passed the evaluation, none yet, and not offered with Apple's on-device model: `LiveAnswerDefaults`).** `RecorderModel.receive` also hands each final line to a `QuestionDetector` actor
   (`Sources/VautaCore/Questions/`) once its row is saved; it never blocks transcription. The stages: S1 `QuestionCues` scores
   each sentence (pure Swift and `NLTokenizer`/`NLTagger`/`NLLanguageRecognizer`, cue sets for the nine interface languages);
   S2 `QuestionFlow` holds a candidate for the next two lines (either channel) or four seconds, whichever comes first (the check then reads up to three lines after it, those that arrived while it waited for its turn); S3 `QuestionDedup` and `QuestionLimiter` drop
   duplicates (also against questions typed in Ask) and keep the rate limits; S4 `LLMService.questionEvidence` searches this
   meeting up to the question, past meetings (`retrieve(excluding:)`) and documents with no model (the search model embeds the question only while the check budget would let the candidate reach the check; `QuestionCounters.embeddings` and `embeddingsSkipped` count it); S5
   `LLMService.checkQuestion` is one small request to the "While recording" model (a suffix on the kept prefix on the integrated
   model); S6 `LLMService.autoAnswer` is `ask` in its auto mode (`AutoAskRequest`; it does not embed the question again, and the question's own segments, which the model reads, are removed from what may be cited); S7 the card rules in `QuestionDetector`.
   Events go through `LiveAnswersBridge` (one ordered stream, and the Stop (the spinner in the card’s title) calls `QuestionDetector.cancel(row:)`) to `LiveAnswersModel`, which the Answers card (`AnswersCard`) draws; questions the model confirmed are stored in
   `detected_questions` (schema 26). Its lane priority (`LLMService.Priority.auto`, `MLXWorkGate.Priority.autoAnswer`) is
   below your own question and above the live notes. `llm-eval --tasks live-questions` replays a transcript through the same
   code on a simulated clock (`QuestionReplay`).
8. **UI.** The Meetings window shows the transcript, minutes, tasks and suggestions; Ask answers questions with
   citations; Context edits people, projects and the glossary.

Imported recordings follow the same path from step 2, as a single channel (`RecordingTranscriber`, `RecordingImport`),
and their speakers are separated offline by the same engine (`OfflineDiarization`).

### Speaker separation

On by default (Preferences `separateSpeakers`; a meeting can opt out with `meetings.speakers_off`). With it off, none
of the code below runs and a meeting is stored exactly as before (a test compares the two). It happens on this Mac;
no audio is kept and nothing new goes over the network.

```
Others ChannelPipe (100 ms chunks, analyzer format)
  ├─► ChannelTranscriber.feed → returns the chunk's first frame (the shared sample counter)
  └─► Diarizer.push(chunk, startFrame)               non-blocking: a lock and a queue
        serial queue "vauta.diarizer":
          AudioChunkConverter → 16 kHz mono Float
          DiarizationSession: absolute-index ring buffer, one 10 s window every 2 s
            WindowAnalyzer: segmentation (Core ML) → masks → fbank → embeddings (Core ML)
            SpeakerTracker: online clustering, re-clustered every 45 s (up to 5 min in long meetings), labels kept by Hungarian mapping
          WindowRecord batches ─► windowSink ─► RecorderModel ─► store.diarization_windows (encrypted)
At Stop:
  Diarizer.finish() → tail windows (silence-padded) → DiarizationRun
  SpeakerFinalizer.finalize → Reconstruction.diarize (FinalClusterer: centroid AHC at 0.70 + guards)
    → SpeakerAligner (max-overlap speaker per segment, splits at word boundaries, >= 1 s parts)
    → MeetingStore.applyDiarization → finalizeSpeakers (user locks respected) → delete the windows
```

- **Timebase.** `ChannelTranscriber.feed` returns the frame position it used for the chunk; the diarizer places the
  samples by that absolute index, so a chunk the transcriber dropped is a gap of silence, never a shift.
- **Backpressure.** `Diarizer.push` never waits for the analysis. If analysis is slower than audio, the session skips
  the oldest due windows beyond 15 (`skippedWindows`); if even the chunk queue grows past 6,000 chunks (10 minutes), new
  chunks are dropped (`droppedChunks`). Labels get worse; the transcript does not. If the models fail their hash check
  or cannot load, the recording goes on without speakers.
- **Speaker interface.** Logic lives in VautaCore (`Speakers/`) and is tested: `SpeakerRoster` (lines, talk share, who a speaker can merge with, the rest of a turn), `SpeakerEditor` (every user edit, applied to the store and returned with what undoes it), `SpeakerPalette` (colours beyond the first speaker of a channel, contrast-tested), `SpeakerCandidates` (calendar attendees first, suggestions only). The window registers each edit with its `UndoManager`, so Edit ▸ Undo walks back (no Redo; undo is cleared when another meeting opens). The transcript label is always text, with a sign for low confidence and for overlap; the popover (`SpeakerPopover`) opens from a label or from "Who spoke". The per-meeting switch is in the Transcript tab. Voice recognition adds, to the same popover, “Is this Ana?” (a suggestion with Yes and No), “Remember This Voice…” (a consent sheet; only for a speaker the user named, typed or accepted) and “This Is My Voice” (imported recordings only) (`SpeakerPopover+Voice.swift`, `VoiceConsentSheet.swift`, `MeetingsModel+Voices.swift`).
- **Who named a speaker.** `meeting_speakers.source` says it: `user` is the user's decision and is never overwritten, and that includes Clear Name, which stores a `user` row with no person (it shows as "Speaker k"). Voice-profile matching writes only a candidate (`suggested`, never shown as a name) and only on rows that are not `user` rows; a `user` row, a cleared one included, is never touched by it (`finalizeSpeakers` keeps it), and an accepted suggestion is an ordinary `assignSpeaker`, so it becomes `user`.
- **Live labels.** `RecorderModel.receive` attaches a provisional `SpeakerTag` (no ID) to FINAL segments, the live
  label plus one; the Me channel always gets ordinal 1. Captions (volatile results) stay one per channel. The panel and the captions
  render it (`RecorderModel+LiveSpeakers`: voices seen, names the user typed, carried to the final speakers by `LiveSpeakers.carryOver` after finalization). A reader never waits for the analysis: `provisionalLabel` reads a snapshot that is
  swapped under a lock held only for two reference assignments.
- **Word times.** For the Others channel the transcriber keeps each final result's word times (`Segment.words`, from
  `.audioTimeRange`) in memory so the aligner can cut between words. They are not stored. After a crash the cut is
  proportional to the time.
- **Crash safety.** Window records (class map, usable seconds and up to three 256-float embeddings, about 3.7 KB each)
  are written to `diarization_windows` (migration 15) through the normal write chain, so they travel in the encrypted
  journal and snapshot. App start (`RecorderModel.startLLM`) calls `SpeakerFinalizer.recoverInterrupted`; `LLMService.meetingEnded` calls
  `finalizePending` first, the last try: a failure there deletes the rows too. They are deleted when the speakers are
  written (`secure_delete` zeroes the pages), when speakers are off (for the meeting or globally), when a backup that
  holds an unfinished recording is restored, and with the meeting.
- **Order (enforced).** Speakers are finalized after the last segment is saved and before: the meeting is closed
  and analyzed (mentions point at segments), the late translation answers are stored (`EndedTranslationTarget` is
  completed after the finalization, and `saveLateTranslation` refuses a text that no longer matches a split segment),
  and the minutes are queued (`meetingEnded` finalizes anything still pending).
- **Models.** Two compiled Core ML models, bundled as SwiftPM resources and verified by a SHA-256 over every file of
  each folder before they load (`DiarizationModels`): segmentation `8cfb3d88307e2aa4d44c43d4a63ec5bbb67a6933fc955a46a248ab6a161fbdd5`
  (pyannote community-1, CC-BY-4.0) and embedding `a2d1fb32a9a6bb9f457e5682b9ba567e7081bf2407e0989f6aad208807d9820d`
  (WeSpeaker ResNet34-LM, CC-BY-4.0). They are committed compiled so the hash covers the bytes that load. See `NOTICE`
  and `tools/convert-diarization-models`.
- **Evaluation.** `Vauta diarize <audio> [--rttm out] [--threshold n]` runs the same engine offline over a file and
  prints RTTM (speakers and times, no text). It is in every build; it reads the file and writes no audio.
  `--live-agreement` also reports how well the live labels agree with the final ones. The committed harness in `eval/` runs `Vauta diarize` over the
  pinned AMI and VoxConverse sets and scores it (see [BENCHMARKS.md](BENCHMARKS.md)).
  `Vauta speaker-centroids <audio> --out <json>` is evaluation only and exists only in the diagnostics build (`VAUTA_DIAGNOSTICS`),
  never in the app that is shipped: it writes the voice vector (`SpeakerCentroids`, the normalised mean of a final speaker's
  window embeddings), the real speech seconds, the crosstalk share, the spread and the turns of each speaker to the one JSON
  file named. It holds voice data, not audio and not text; keep it out of version control and delete it afterwards. It exists
  to calibrate the voice-profile thresholds.

## Directories and key types

### `Sources/VautaCore`

| Directory | Responsibility | Key types |
|---|---|---|
| `Audio/` | Raw capture, in memory only | `MicrophoneCapture`, `SystemAudioTap`, `TapStream`, `Resampler`, `MeetingPresence`, `AudioProcesses` |
| `Diarization/` | Speaker separation: Core ML models, window analysis, clustering, alignment, the live `Diarizer`, finalization | `Diarizer`, `DiarizationSession`, `WindowAnalyzer`, `DiarizationModels`, `SpeakerTracker`, `FinalClusterer`, `SpeakerAligner`, `SpeakerFinalizer`, `OfflineDiarization` |
| `Capture/` | Capture policy and health | `MeetingAppCatalog`, `MeetingAppFamily`, `SystemAudioScope`, `ChannelPipe`, `ChannelHealth`, `ConferencingLink`, `CaptureError` |
| `Transcription/` | On-device speech recognition and speech models | `ChannelTranscriber`, `Segment`, `TranscriptionEngine`, `SpeechLanguages`, `SpeechAssets`, `transcribeFile` |
| `MeetingCapture.swift` | Orchestrates both channels | `MeetingCapture`, `ChannelLocales` |
| `Model/` | Shared value types | `Channel` |
| `Translation/` | Live Translation engine: pipeline actor, backends, cache, caption layout | `LiveTranslator`, `Translator`, `TranslationBackend`, `AppleTranslationBackend`, `TranslationPair`, `CaptionSnapshot`, `CaptionFrameStore` |
| `Network/` | The audited network choke point and its in-memory log | `AuditedSession`, `AuditedBytes`, `NetworkActivityLog`, `NetworkActivityEntry`, `NetworkPurpose`, `NetworkDestination` |
| `Backup/` | Encrypted backup file and restore | `BackupArchive`, `BackupManifest`, `BackupPreferences`, `OpenedBackup`, `BackupPassword`, `MeetingStore+Backup` |
| `Storage/` | Encrypted store, schema, persistence | `MeetingStore`, `SQLiteDatabase`, `Schema`, `Migration`, `SnapshotEnvelope`, `Journal`, `AtomicFile`, `KeychainDatabaseKeyStore`, `KeychainSecret`, `StoreError` |
| `Knowledge/` | Context, name resolution, decisions and tasks, cards, the ranking rule of the search model | `SemanticRanker`, `MeetingStore+Graph` (`analyze`), `NameMatcher`, `TextKeys`, `LanguageProfile`, `MeetingStore+Context`, `MeetingStore+Items`, `MeetingStore+Review` |
| `LLM/` | Model clients, prompts, validation, search, job queue | `LLMService`, `LLMClient`, `LLMServerConfig`, `ServerProfile`, `ServerDiscovery`, `ServerTrust`, `ServerAddress`, `ServerCredentials`, `VautaPrompts`, `OwnerResolver`, `MinutesVerifier`, `ContextBudget`, `VectorIndex`, `ModelProviding`, `SystemModelProviders`, `ModelProviderSettings` |
| `LLM/Providers/` | Model implementations | `AppleChatModel` (Foundation Models, with guided generation for answers: `AppleGuidedSchema`) |
| `SearchModel/` | The optional search model (EmbeddingGemma 2): pinned manifest and tensor table, store, downloader, importer, verifier, tokenizer, engine, controller | `SearchModelManifest`, `SearchModelSpec`, `SearchModelStore`, `SearchModelDownloader`, `SearchModelImporter`, `SearchModelVerifier`, `SearchModelDestinations`, `GemmaTokenizer`, `SearchModelEngine`, `GemmaEmbeddingModel`, `SearchModelController`, `SearchModelStatus` |
| `LanguageModel/` | The optional integrated language model (Gemma 4 E4B): pinned manifest and tensor tables, store, downloader, streaming quantiser, importer, verifier, tokenizer and chat template, constrained decoding (`Constraints/`), engine, gate, controller (the state machine behind Settings), `IntegratedChatModel` | `LanguageModelManifest`, `LanguageModelController`, `LanguageModelStatus`, `LanguageModelDownloader`, `StreamingQuantizer`, `LanguageModelEngine`, `MLXWorkGate`, `GenerationLease`, `SchemaGrammar`, `TokenMaskEngine`, `OutputSchemas`, `IntegratedChatModel` |
| `Brief/` | The deterministic pre-meeting brief and its checks: event selection, read-only facts, builder, agenda packer and verifier, policy, cache, presentation of the panel card, wake-up and recording match | `BriefComposer`, `BriefBuilder`, `BriefVerifier`, `BriefCache`, `BriefPolicy`, `BriefPanelCard`, `BriefWake`, `BriefAgendaShipping` |
| `Actions/` | Post-meeting actions (Part A): reminders and events with the ledger that keeps them from being added twice, the follow-up meeting detector, the follow-up email, the `.ics` hand-off. No EventKit here: the app implements `ActionWriter` | `ActionService`, `ActionWriter`, `FakeActionWriter`, `ActionLedger`, `MeetingStore+Actions`, `ReminderDraft`, `EventDraft`, `DueDay`, `FollowUpDetector`, `FollowUpDateResolver`, `FollowUpWords`, `FollowUpEmail`, `FollowUpEmailWords`, `MailHandoff`, `ICSFile` |
| `Questions/` | Live answers: cue scoring, settle, duplicates and rate limits, the model check's prompt and parser, the evidence gate, the detector actor, the stored questions | `QuestionCues`, `QuestionFlow`, `QuestionLimiter`, `QuestionDedup`, `QuestionCheck`, `QuestionEvidence`, `QuestionDetector`, `AutoAnswerContent`, `LiveAnswerSettings` |
| `Export/` | Pure renderers of a meeting | `MeetingExport`, `MeetingExportRenderer`, `SubtitleRenderer`, `MeetingExportJSON`, `AnswerExport` |
| `Import/` | Recordings as meetings | `AudioFileDecoder`, `RecordingTranscriber`, `RecordingImport` |
| `Settings/`, `App/`, `Meetings/` | UI logic kept out of views so it can be tested | `ServerDraft`, `RetentionChange`, `KnowledgeRetention`, `HotKeyRules`, `OnboardingFlow`, `UnlockWindow`, `AppNotification`, `RecordingSetup`, `MeetingDraft` |

### `Sources/Vauta`

| Path | Responsibility | Key types |
|---|---|---|
| `main.swift`, `CLI*.swift` | Entry point and command-line tool | `runCLI` |
| `App/VautaApp.swift` | Scenes: menu-bar panel, Meetings, Context, Settings, onboarding | `VautaApp` |
| `App/RecorderModel*.swift` | Recording lifecycle, services, presence, relock, retention timers | `RecorderModel` |
| `App/Preferences.swift` | App-wide preferences in UserDefaults | `Preferences` |
| `App/Panel/` (Answers card: `AnswersCard`, `LiveAnswersModel`) | The menu-bar panel: fixed header, record button and footer around a scrolling middle capped to the screen height | `RecorderPanel`, `MenuBarLabel`, `LiveTools`, `LiveTranslationRow`, `PanelStyle` |
| `App/Translation/` | Captions panel (non-activating `NSPanel`), its view, language downloads | `LiveTranslationModel`, `CaptionsPanelController`, `CaptionsView`, `TranslationDownloader` |
| `App/Brief/` | The pre-meeting brief in the app: controller (next event, Upcoming, cache, notification, attachment to the recorded meeting), read-only EventKit readers, the panel card and recording row, Upcoming and the kept-brief tab | `BriefController`, `BriefPreferencesModel`, `BriefCardView`, `BriefRecordingRow`, `BriefContentView`, `UpcomingBriefView`, `StoredBriefView`, `EventKitBriefEventSource`, `EventKitReminderSource` |
| `App/Actions/` | The app side of the actions: `EventKitActionWriter` (the **only** file that saves or removes anything in Reminders or Calendar; a source-scan test enforces it), `ActionsModel` (+ `Reminders`, `Events`, `Email`: the editor drafts, the Follow-up sheet, the undo bar, the ledger read-back; owned by `MeetingsModel`, one sheet that swaps between the Follow-up sheet and the editors), `ReminderEditor`, `EventEditor`, `FollowUpSheet`, `EmailDraftView`, `ActionStatusViews` (the Reminders cell, the task menu, the undo bar), `PanelFollowUpCard` (+ `RecorderModel+FollowUp`: pending meetings kept as identifiers, counts and a time), `AfterMeetingsSettings`/`ActionsPreferences`, `ProtectedPasteboard`, `MailHandoffOpener` | `EventKitActionWriter`, `ActionsModel`, `FollowUpSheet`, `ReminderEditor`, `EventEditor`, `EmailDraftView`, `FollowUpCardContent`, `ProtectedPasteboard`, `MailHandoffOpener` |
| `App/Meetings/` | Meetings window, Ask, export, import | `MeetingsModel`, `AskModel`, `MeetingExporter`, `RecordingImportModel` |
| `App/Context/` | People, projects, glossary and series editor | `ContextModel`, `ContextView` |
| `App/Network/` | Network Activity window: live list, summary, filter, export | `NetworkActivityModel`, `NetworkActivityView` |
| `App/Settings/` | Settings window | `SettingsModel`, `ModelsSettingsModel`, `SpeechSettingsModel`, `SearchModelModel`, `IntegratedModelModel` and the panes (`SearchModelSection` and `IntegratedModelSection` are the cards of Models) |
| `App/Onboarding/` | First-run setup | `OnboardingModel`, `OnboardingView` |
| `App/Shared/` (look: `Brand`, `VautaOrb`, `CardStyle`, `EmptyStateView`) | What the windows share: Vauta's colours, the animated sphere (record button, Welcome, empty states, the small "thinking" sphere), cards and empty states | `Brand`, `VautaOrb`, `ThinkingOrb`, `BrandSymbol` |
| `App/Notifier.swift`, `GlobalHotKey.swift`, `CalendarWatcher.swift`, `NoCopyText.swift` | Notifications, global shortcuts, calendar matching, copy protection | |

## Network audit

All network access goes through `AuditedSession` (`Sources/VautaCore/Network/`), which creates the only URL sessions
and records each request in the `NetworkActivityLog` actor (a ring buffer of the last 1,000 entries, in memory only).
`LLMClient` and `ServerDiscovery` hold an `AuditedSession` and name each request's **purpose**
(`ChatOptions.purpose` for chat; `.embeddings`, `.statusCheck`, `.connectionTest` and `.discovery` for the rest).
Code that needs a new kind of request adds a case to `NetworkPurpose` and calls `AuditedSession`; it does not create
a session of its own. `NetworkAuditSourceScanTests` fails the build otherwise.

The search-model download is the one non-local use. Its purpose is `NetworkPurpose.modelDownload` (raw value
`"modelDownload"`, frozen; the window says "Search model download"). `AuditedSession.stream` hands a response to a
`accept` check before its body is read (a `200` to a range request is cancelled at once) and the body to a sink in chunks.
The session has no redirects: the 302 from `huggingface.co` comes back as a response, and `SearchModelDestinations`
(exact scheme, host, port, path; the CDN host list is exact, no wildcard) decides whether its `Location` may be fetched. A
refused destination is a Blocked row and nothing is sent. The signed CDN address stays in memory and its query string
never reaches the log or the export. Constructing the controller makes no request: only the Download click does.

An entry is created before the request is sent, updated when the response body ends (or fails, or is abandoned) and
carries no content: see [PRIVACY.md](../PRIVACY.md#seeing-every-connection) and
[SECURITY.md](../SECURITY.md#network-audit). The Network Activity window (`App/Network/`) follows the log through
`NetworkActivityLog.changes()`. The log merges repeated loopback discovery probes with the same result into one row with
a count, and `recordBlocked` lists requests refused by the destination rules before sending. The window opens from
**Window → Network Activity** (⌥⌘N, chosen because ⌘N is "New" in Meetings and ⇧⌘N is the system's new-folder shortcut).

## Models and model jobs

`ModelProviding` hides where a model runs. Chat runs on the configured server (`LLMClient`, OpenAI-compatible) or on
Apple's on-device model (`AppleChatModel`). Search vectors come from the server, from the downloaded search model on
this Mac (EmbeddingGemma 2 in `VautaMLX`), or are off (Ask then uses keyword search only). See
[MODEL_SERVERS.md](MODEL_SERVERS.md) and [SEARCH_MODEL.md](SEARCH_MODEL.md).

- **The integrated model.** `LanguageModelController` (an actor, the state behind Settings → Models) mirrors the search model's:
  not installed, downloading (paused during recordings), checking what a pause kept, partial, importing, waiting for the other
  file, verifying, preparing, ready, damaged, repairing, failed, deleting. `download()`, `importFiles(_:)` and `repair()` are the
  only things that start work, each a click; the chat choice is saved when one starts. `LanguageModelEngine` is the generation
  actor on a utility-QoS executor: it loads on first use, keeps **two prefixes** (`.meeting`, the meeting being recorded or just
  recorded, and `.ask`, anything else) with checkpoints so a changed prompt is rewound to the latest checkpoint before the change,
  and takes the GPU through `MLXWorkGate` per prefill chunk and per burst of decoded tokens. The gate orders interactive answers,
  live notes, minutes, the incremental reading of the meeting (`.warm`) and bulk embedding. `LLMService+Warm` reads the transcript
  of the meeting being recorded into the `.meeting` slot every few tens of seconds (`prefillPrefix`: no decoding, never blocking
  transcription), the slot is pinned after the recording until the minutes are written, and minutes, live notes, live answers and
  the check of an answer all share that prefix (`PromptLayout.streaming`: stable speaker keys in the transcript lines, names and
  new people in the last message). `QuoteAnchor` verifies quotes modulo case, punctuation, spacing and filler words and moves a
  citation to the nearest segment that holds the words. Minutes on this model are two passes: the one-call minutes, then
  `LLMService+MinutesItems` asks for the decisions and tasks of each stretch of the meeting on the same prefix.
- **The search model.** `SearchModelController` (an actor) is the state machine: not installed, downloading (paused during
  recordings), stopped with a resumable `.part`, verifying, preparing, ready, failed, deleting. It reads the disk at start
  and never starts a request. `SearchModelEngine` is the encoder actor on a utility-QoS executor: it loads on first use
  (a full verification once per launch), batches by padded tokens (at most 1024 and 32 rows), reads `phys_footprint`
  after every batch and halves the budget above 1.4 GB, retries a NaN row in fp32, and unloads after 3 minutes idle, on
  memory pressure or on delete. `GemmaEmbeddingModel` conforms to `EmbeddingModel` (prompts, Matryoshka 256, windows of
  long texts, the token counter for chunk planning). Bulk embedding follows `IndexerPolicy` (nothing while recording and
  two minutes after, in Low Power Mode, when hot, or on battery); a single question is always embedded unless the Mac is
  critically hot. `Memory.cacheLimit` is set once by `MLXRuntime.configure()`. Space: `embeddinggemma-2@914f7f89/r1`, 256
  dimensions, int8 in `VectorIndex`.
- **Retrieval modes.** `SemanticRanker.mode` decides per kind (meetings, documents): `.keyword` (no model, or still
  indexing for the first time), `.rrf` (a model server's vectors: BM25 and vectors fused, k = 60, unchanged) or `.semantic`
  (the model ranks: candidates are the vector top-K plus the FTS rows of exact items, the score is the cosine plus the code
  and name boosts). `MeetingStore.retrieve` and `DocumentIndex.search` take the mode; coverage comes from
  `vectorCoverage(space:)` and complete coverage is remembered (`searchModelCoverageReached.<space>.<kind>`) so a new
  meeting does not flip Ask back to keywords. `LLMService.Status.searchIndex` publishes the coverage for the UI.
- **Chunks in the model's space.** `chunkPlan` takes a `ChunkBudget` (token limit and a counter) so a chunk fits 512
  tokens; without one the plan is exactly the old one. Document passages keep their keys; one over the limit is embedded as
  the token-weighted mean of its windows.

- `ServerProfile` decides the request dialect: how thinking is switched, sampling, and `response_format`. A
  configuration without a profile (written by an earlier version, 0.1) uses `ServerProfile.legacy` and produces exactly the 0.1
  requests.
- `ContextBudget` sizes every prompt from the model's real context window. Small windows (under 12K tokens, such as
  the on-device model) get map-reduce minutes in blocks; their final request reads a digest of the blocks and writes only the
  title, summary, topics and open questions, and Swift carries the decisions, tasks and mentions over from the extracts
  (`MinutesDigest`).
- The minutes, live notes and answers are JSON. `VautaPrompts` validates them: every decision, task and claim must cite
  real segment IDs, or it is dropped. What reaches the store is what Swift verified. An answer starts with `found`: `true`
  with at least one claim, or `false`, an explicit refusal; a found answer whose claims all fail the check is unverified, not
  a refusal. Dropped minutes items are counted by reason (`MinutesDiagnostics`: counts and reasons only, never text).
- **Minutes and speakers.** A transcript line carries its speaker label (`VautaPrompts.speakerLabel`: name or
  "Speaker k", role, `?` when doubtful; only the name and the assignment's confidence are used). `OwnerResolver`
  (`LLM/OwnerResolution.swift`) decides task owners: a confident speaker who commits (`FirstPerson`: phrases with a verb
  that states the commitment, not requests, opinions or needs) owns a task the model left without owner or gave to them,
  unless the words name another person of the meeting; when the model chose somebody else its owner is kept and marked
  (one line can hold two actions). Otherwise the model's owner is validated against the meeting's people, the named
  speakers and the cited words, and a doubtful label never gives a task. The owner check runs in every meeting, with or
  without speaker data. `MinutesVerifier` checks figures (the due date's own words are cut out of both sides first; Han
  numerals are parsed), due date (`DateWords`: whole phrases bounded by the calendar, weekdays within the coming days)
  and named people literally against the cited segment; a mismatch sets `decisions.unconfirmed` / `tasks.unconfirmed`, an unbacked owner sets
  `tasks.owner_uncertain` (schema 16), the separate owner counterpart of `unconfirmed`; `markDecisionChecked` / `markTaskChecked` clear
  both when the user verified the item. Items are marked, never dropped; the marks reach the Markdown, text and PDF
  exports as notes and the JSON as optional keys, and `MeetingStore.refreshOwnerMarks` recomputes the owner marks when
  speakers change (also when separation is turned off: the resolver then runs with no speaker data). A meeting without
  speakers exports its existing items and transcript byte for byte as before; minutes written again can carry the marks. `SpeakerDirectory` holds IDs only. The offline
  evaluation is in [OWNER_EVALUATION.md](OWNER_EVALUATION.md).
- **Search and speakers.** `chunkPlan` starts each chunk line with `chunkLabel`: the speaker's name when the user named it
  (typed, or a suggestion accepted) and the assignment is sure, else the channel. `chunks.text_key` (schema 17) is a hash of the embedded
  text; `chunksOutOfDate` compares it with today's plan (only in meetings that have speakers, or whose chunks already
  have a key; legacy chunks whose text did not change only get their keys), `reconcileEmbeddings`,
  `LLMService.speakersChanged` and `LLMService.peopleChanged` (a person named on a speaker renamed, merged or deleted; `LLMService.start()` connects it to the store's `peopleChangeHandler`) queue `embed` jobs
  for the meetings that differ, and a running `embed` looks again after storing, so an edit made meanwhile is not lost.
  `retrieve` ranks higher the passages of a named speaker when the question names that person. A mention carries no
  speaker column: it is read from its segment, so it cannot go stale (`MentionRef.speaker`, `spokenQuotes`). This departs
  from the original design's "mention rows carry speaker_id"; whether to keep it is open. A run of `embed` that gives up with
  chunks still behind the transcript does not mark the meeting as checked.
- `VectorIndex` keeps int8 vectors in memory and searches them by brute force with Accelerate. Each vector records
  its embedding space (model and dimensions); changing the model re-embeds meetings.

## Concurrency

Swift 6 language mode with strict concurrency checking. The rules:

| Component | Isolation |
|---|---|
| Views and their models (`RecorderModel`, `Preferences`, `MeetingsModel`, `SettingsModel`…) | `@MainActor`, `@Observable` |
| `MeetingStore` | `actor`. Owns the in-memory SQLite connection, so every read and write is serialized. Disk writes go through a single writer task, so an older snapshot is never written over a newer one |
| `LLMService` | `actor`. One model request at a time through a priority lane: Ask > live notes > background jobs. Background jobs wait while recording; Ask interrupts a background job, which goes back to the queue. The queue is persistent |
| Capture (`MicrophoneCapture`, `SystemAudioTap`, `ChannelPipe`, `ChannelTranscriber`) | `final class … @unchecked Sendable`, with `NSLock` around state shared with Core Audio callbacks, which run on private serial dispatch queues. Segments reach the main actor through callbacks |
| `LLMClient`, `SystemModelProviders` | `@unchecked Sendable`, state behind `NSLock` / `Mutex` |
| `SearchModelController`, `SearchModelEngine`, `SearchModelDownloader` | `actor`s. MLX work runs on the engine's own serial queue (utility QoS), never on the cooperative pool or the main actor; an MLX `eval` cannot be interrupted, so each batch yields and checks cancellation |

Cancelling minutes, Ask or a re-analysis cancels the Swift task that runs it, and with it the model request. Long
work never runs on the main actor.

## Storage

### Files

The optional search model lives outside the store, in `<Application Support>/Vauta Models/embeddinggemma-2/914f7f89/`
(`model.safetensors`, `tokenizer.json`, `installed.json`; `staging/` beside it while downloading or importing). It is
never inside `Vauta/` (the store directory, which the rename of an earlier version's folder and Erase Everything own), has 0700 directories
and 0600 files, is excluded from Time Machine (`isExcludedFromBackup`, set again at every start) and from Spotlight
(`.metadata_never_index`), is never part of Vauta's own backups, and survives Erase Everything because it holds no
personal data. Settings → Models → Delete… removes it.

The store is one encrypted SQLite image (`vauta.db.enc`) plus an encrypted journal (`vauta.journal.enc`) in the app
container. The plaintext database exists only in memory (`sqlite3_deserialize`/`sqlite3_serialize`). The envelope
and journal formats are described in [SECURITY.md](../SECURITY.md#encryption).

Stores written by an earlier version, with the old `acta.*` names (and the `Acta` folder), are migrated in place on open by `StoreMigration`
(`Sources/VautaCore/Storage/StoreFiles.swift`): verify with the key, rename the snapshot, then the journal; a state
with both names keeps the more complete snapshot and sets the other aside as `*.legacy-<time>`. The `Acta` folder is
renamed only while both of its lock files are held, and renamed back if that first open fails. Set-aside copies and a
store left in the old folder are listed by `MeetingStore.leftovers()` (Settings → Status), deleted by `deleteLeftovers()`
on request, expired by retention after 90 days (set-aside copies only) and removed by Erase Meetings and Context
(`Storage/StoreLeftovers.swift`).

The consent helper stores `meetings.participants_informed_at` (schema 12; `MeetingStore+Consent.swift`). `ConsentNotice`
resolves the paste-ready text from the app's `.lproj` tables by the meeting's language (`consent.notice`), and
`ConsentReminder` is the Settings → Recording choice; the panel row is `ConsentRow` (`RecorderModel+Consent.swift`). The unbundled CLI's
Keychain items move from the service `local.acta.cli` to `local.vauta.cli` on first read. Format identifiers
that contain the old name (`ACTA`, `ACTJ`, `ACTABK`, `acta-journal-v1`) are frozen forever.

Backup and restore (`Backup/`) reuse the snapshot packing: a backup is the packed image plus a manifest and an
allow-listed set of settings (`BackupPreferences`), sealed with a password-derived key; restore replaces the store's
key and snapshot under the store actor, and the app then writes the settings to UserDefaults and reloads them. See
[SECURITY.md](../SECURITY.md#encrypted-backups).

Speaker data (schema 14; `MeetingStore+Speakers.swift`, `MeetingStore+VoiceProfiles.swift`, `SpeakerModels.swift`).
`meeting_speakers` (channel, ordinal, optional person, `source` auto|user|suggested (`profile` was never released as a name: schema 20 turned it into `suggested`), talk time) belongs to a
meeting and cascades with it. `segments.speaker_id`, `speaker_confidence` and `overlap` say who said each segment
(`speaker_id` is cleared if the speaker goes). `segments.speaker` stays `me`/`others` (frozen), and the `others` role of
`meeting_entities` stays the fallback for meetings without speaker data. Ordinals count within a channel; the default
labels are "Me", "Me 2"... and "Speaker 1"... so no two speakers of a meeting share one. A name comes only from the user
(typed, or a suggestion accepted); a saved voice, the calendar or the model only suggest, and suggestions are never shown as names. Carriers (`Segment`,
`StoredSegment`, `CitableSegment`, `MeetingExport.Line`) hold an optional `SpeakerTag`, nil without speaker data.

Finalization never overwrites what the user decided. A row with `source = user`, and any speaker a hand-decided segment
points at (`speaker_locked`: reassigned, split or merged), is "pinned" and never deleted. Pinned rows follow their voice
even if a new diarization numbers its clusters differently: the store matches clusters to pinned rows by the shared time
of their unlocked segments, else by exact ordinal.

Splitting a segment keeps the left part's ID, inserts the right part, moves the citations whose surface or time lies in
the right text and updates the full-text index by hand. The user's split (refused while the meeting records) locks both
parts and drops the segment's translations. The aligner's splits go through `finalizeSpeakers(..., splits:)` in the same
transaction as the speakers, do not lock, work while recording and cut the translations proportionally (at spaces or
sentence marks, else by characters; one that cannot be cut stays whole on the left part). A live translation is stored
with the text it translated and is refused when a split changed it.

Speaker edits (assign, rename, add, merge, reassign, split, clear) return a `SpeakerUndo` that `MeetingStore.undo(_:)`
applies in one transaction. It refuses, changing nothing, when the data moved on (a split edited or split again, a
recorded ID that now belongs to another meeting). `meeting_speakers.id` is AUTOINCREMENT so IDs are never reused.
`meetings.speakers_off` is the per-meeting "don't separate speakers" switch: finalization writes nothing while it is on,
and `clearSpeakers` returns the meeting to the no-speaker state. The speaker of a mention is derived through its segment
(`mentions.segment_id` to `segments.speaker_id`); there is no column of its own.

`voice_profiles` (opt-in, off by default) holds a person's embeddings with the `model_id` that made them (another
model's are never matched), the consent time the user attested, at most ten per person, and dies with its person. They
live only in the encrypted store: included in the snapshot, journal and encrypted backup, removed by Erase Meetings and Context,
and never in an export, a log, a prompt, the vector index or the network. Every path that removes them (deleting them,
deleting or merging a person, changing a person's kind, the ten-profile cap) saves a snapshot at once. Encrypted backups
are sealed with the user's password, not the store key, so backups made earlier keep profiles that were later deleted,
and restoring one brings them back; PRIVACY.md must say so before voice profiles ship, and restoring should ask before
bringing profiles back. No audio is ever stored.

Not in schema 14, on purpose: storage for the diarizer's in-flight window embeddings (needed for crash-safe finalization), and a per-speaker voice vector kept after finalization (needed for "Remember this voice" and for accepting or rejecting a suggested match later). Both hold voice-derived data, so their privacy rules (snapshot at once when removed, erase, backup, no export) are decided when the feature that needs them is built, and they arrive as a new migration, never as an edit of 14.

Schema 15 adds the first of the two: `diarization_windows(meeting_id, seq, data)`, the analysed windows of a meeting that is being recorded (`WindowRecord.encoded()`, versioned, validated on decode). It holds voice-derived data only until the speakers are finalized: the rows go to the encrypted journal and snapshot like any write, are never read by an export, a prompt, the search index or a log, die with their meeting (foreign key, retention) and are deleted when finalization succeeds, or fails for the last time when the meeting ends (`secure_delete` zeroes the pages). A backup taken in the minutes of an unfinished recording carries them inside the encrypted payload like the rest of the store; restoring it deletes them.

Schema 18 adds the second, and only matters while the opt-in "Recognize voices across meetings" is on:

- `speaker_voices(speaker_id, model_id, embedding, created_at)`: the L2-normalised mean of the window embeddings of each Others speaker who passes the voice gate (`SpeakerCentroid.isCleanForVoice`: at least 30 s of real speech, at most 40% of their turn time shared with another speaker, and window embeddings whose mean cosine to the centroid is at least 0.60), computed by `SpeakerCentroids.compute`, written by `finalizeSpeakers(voices:)` in the same transaction as the speakers. It exists only so the user can choose "Remember This Voice" after the meeting (the diarizer's windows are gone by then). It dies with its speaker (foreign key, so with its meeting and retention), is replaced when the meeting is finalized again, becomes a `voice_profiles` row on enrollment and is deleted at once (snapshot) by enrollment, by deleting the person's voice or the person (the summaries of the speakers named after them go too), by Delete All Saved Voices, and by `enforceKeptVoicePolicy`: with recognition off (the setting off, or speakers not separated) none is kept, and with it on one is kept for `VoiceProfileThresholds.keptSummaryDays` (14) days. The app applies that rule at launch, once a day, after a restore and when the switches change, so a restored backup or a failed purge cannot leave summaries behind. With the setting off nothing is written. Replacing a meeting's summaries when it is finalized again also saves a snapshot at once.
- `speaker_suggestion_rejections(meeting_id, entity_id)`: "Not Ana" for one meeting. IDs only; undo removes the row.

- `speaker_centroids(speaker_id, model_id, embedding, created_at)` (schema 21): the same summary as `speaker_voices`, written in the same transaction by `replaceSpeakerVoices`, but not consumed by enrollment. It exists only for **finding a confirmed voice in earlier meetings** (`MeetingStore+VoiceHistory.swift`) and lives exactly as long as `speaker_voices`: `enforceKeptVoicePolicy` purges both at 14 days (a person who never agreed to anything has no voice vector kept longer), and both go when `recognizing` is off. It also dies with its speaker (foreign key), is dropped with `speaker_voices` when lines move between speakers (`dropKeptVoices`), when a person's voice or the person is deleted (`deleteKeptVoices(ofPerson:)`), by Delete All Saved Voices and by Erase Everything. Same rules as the other voice tables: encrypted store only, in backups, never in exports, logs, prompts, the index or on the network (the source-scan test lists the files that may touch it). The sweep reads everything in three queries (speakers with their vectors, rejections, named people), plus one for the excerpt of each find, and a test bounds it on a 2,000-meeting library.

**Finding a voice in earlier meetings** (`suggestVoiceInPastMeetings(of:excludingMeeting:recognizing:)`). Offered by the app, never run by it, after the user accepts "Is this Ana?" or saves a voice (`rememberVoice`, `rememberOwnVoice`), and only with recognition on. It compares the person's template (all saved people compete, as at finalization) with the centroid of every `others` speaker of other meetings that has one (or, for meetings before schema 21, a still-kept `speaker_voices` row), using `VoiceMatcher.match(vectors:against:)` and the same 0.70 threshold. It skips speakers the user named or unnamed (`source = 'user'`), speakers suggested as somebody else, people rejected for that meeting, people the user gave to another speaker there, the user's own voice in a live recording, meetings with speakers off and centroids of another model. A hit is written as `suggested`, never as a name, and the result carries a `SpeakerUndo` that puts every touched speaker back. The Meetings window shows "Found Ana in 4 earlier meetings" with a review sheet: Yes is `assignSpeaker` (the user's act), No is `rejectSuggestion`, each with its own undo; the whole search can be undone while nothing was answered. Accepting never adds a fingerprint to the profile.

**Matching** (`Knowledge/VoiceProfiles.swift`, `MeetingStore+VoiceRecognition.swift`, called from `applyDiarization`). **A saved voice only suggests; it never names a speaker (since 2026-10-10).** A person's template is the L2-normalised mean of their fingerprints of the current `DiarizationModels.embeddingModelID` (others are never read); a speaker's vector is its centroid. Cosine at or above the single threshold `VoiceProfileThresholds.suggest` (0.70) writes the draft as `suggested` (a candidate that is never shown as a name), below it nothing; there is no higher "names automatically" level and no `profile` source (schema 20 turns any stored `profile` row into `suggested`; the CHECK of schema 14 still lists the value, and nothing writes it). When two speakers resemble the same person the closer one gets the suggestion. The user's answer is an ordinary `assignSpeaker` (Yes, source `user`, which then wins over everything) or `rejectSuggestion` (No, remembered for the meeting). Rules around that: a speaker must pass the voice gate (30 s of real speech, which is the sum of window seconds divided by the 5 windows that cover each second, not the sum itself; at most 40% crosstalk; a spread of at least 0.60); the persons the user rejected for the meeting, and the ones the user gave to another speaker, are left out; a live recording never suggests the user's own voice for an Others speaker (the user is the Me channel), an import may ("Is this you?"); `last_matched_at` is set on a person's profiles only when the user accepts a suggestion of them, never by a suggestion alone. Remember This Voice accepts only a speaker the user named. Because no voice ever produces a name, nothing downstream (transcript, minutes, task owners, search, exports, footprint) needs a "named by a voice" distinction, and there is no "recognized" marker in the UI.

**Imports.** A file has one channel and every line stays Others. The earlier design moved the speakers that matched the user's own saved voice to Me (`ImportChannelSplit`, 0.85 with a margin of 0.05) before the segments were stored; it was removed with the decision above. Imports are mostly clean headset audio, where the calibration measured 100% right with no false accepts, but from a small sample (n = 50 genuine, 788 impostor) that does not justify an irreversible automatic move. The 0.85 / 0.05 cut was never calibrated separately; other microphones and phone audio were never tested; the one mismatched condition measured (remote mix) made errors worse; and a wrong move cannot be undone (no operation moves a stored segment between channels). No evidence supports keeping any part of it automatic, so the own voice is treated like any saved voice: `importMeeting(recognizeVoices:)` passes `ownVoice: true` to `applyDiarization` and the user may get "Is this you?" on a speaker. Answering Yes assigns the user's own person to that Others speaker (source `user`); it does not move lines to Me.

**Calibration status and decision (2026-10-10).** The acceptance item "TAR >= 80% at the chosen thresholds" is NOT met. At 0.80 (k = 1) the true-accept rate is 78.0% (tune) and 79.5% (test) with all conditions pooled, and by condition: clean to clean 100% (n = 50 genuine, 788 impostor), remote-mix enrolment to remote-mix probe (a live recording) 61.3% (n = 31), full to others 74.5%, others to full 70.3%; the open-set test on the remote mix names 68% to 71% right, and wrong names reach 2% to 10% of saved people with 4 to 32 saved. The false-accept item holds only as a point estimate at 0.80 (0.56%; remote-to-remote 0.72%, upper bound 1.83%; same room 3.9%) and not at 0.70 (remote-to-remote 2.69%, upper bound 4.40%; same room 14.6%). Do not round 79.5 to 80 in user-facing text. The options were: accept the shortfall, lower the threshold (more wrong names), or never name automatically. **The last one was chosen: saved voices are suggest-only, everywhere.** The numbers above are kept because they are why: a wrong "Is this Ana?" costs one click, a wrong name would reach the transcript, minutes and exports. The shipped threshold is 0.70 (the figures at 0.70 are the relevant ones: a different person reaches it about 2.7% of the time on remote audio and about 15% between colleagues in one room, so a wrong question is not rare in a recording with colleagues in one room). Two further limits: the mean template of several fingerprints is uncalibrated (with k = 2 the TAR at 0.80 fell to 65.0% / 72.5% and same-room false accepts rose to 4.17%), and nothing was measured for other languages or phone audio. The 2026-10-11 change to the offline turns (0.5 s pause merge, equal window weights, a fold that scales with the meeting) raised the share of a speaker's time covered by others by about 0.3 points on the held-out recordings and left the same speakers inside the 40% gate ([docs/BENCHMARKS.md](BENCHMARKS.md#what-the-2026-10-11-change-did)); the 0.70 threshold and the spread gate were calibrated before it and were not re-measured.

**Calibration.** (Written when 0.80 was a naming level; today nothing names a speaker and 0.70 is the only threshold. "Reached 0.80" below means that cosine level was met, as a measure of how strong a match is.) The thresholds come from the original calibration (the evaluation-only `speaker-centroids` command over AMI, 10 meetings, 16 people in 4 series, and VoxConverse, 16 speakers; tune and test folds split by series; enrolment with 1 or 2 meetings; held-out meetings; two audio conditions: the mixed headset recording and the Opus-coded remote mix). The first calibration kept only clusters that ground truth says are pure (purity >= 0.8), which the app cannot know, and reported 0.08% false accepts at 0.70; that figure is not valid for the app. The figures that count are those of the speakers the app would match: every speaker that passes the runtime gate, enrolled from any gated speaker the user confirmed. With one enrolment meeting, 0.80 accepts 0.56% of impostor comparisons in both folds (95% upper bound 1.11% tune, 1.15% test; 3.2% and 2.8% between colleagues of one room) and is reached by 78% and 80% of the same person's held-out meetings; 0.70 (the shipped threshold) accepts 1.06% and 1.59% (same series 6.0% and 8.0%) and reaches 84% and 88%. Enrolling from a second meeting did NOT help in this data (with the runtime gate and no purity filter on the enrolment): at 0.80 the same-person rate falls to 65.0% (tune) and 72.5% (test) from 78.0% and 79.5%, the same-series false accepts rise to 4.17% and 4.17% from 3.23% and 2.79%, and at 0.70 the rate is 80.0% and 82.5% against 84.1% and 88.0% (only 40 genuine comparisons per fold, so the sample is small, but nothing supports saying that a second fingerprint improves recognition; the app says only that more can be saved). Without the gate the same cut-offs accept 0.62% / 0.37% at 0.80 and 1.87% / 1.28% at 0.70 (same series 10.5% / 7.0% at 0.70), so the gate roughly halves wrong matches at 0.70 and removes most of the mixed clusters. "FAR <= 1%" therefore holds as a point estimate for the matches, not as a 95% upper bound, and it is a one-to-one figure. The more voices are saved the more likely an unknown speaker resembles one of them, about in proportion: with a library of 4, 8, 16 and 32 saved people an unknown speaker matched a saved person in 1.2%, 2.3%, 4.2% and 5.6% of cases on the clean headset mix (people enrolled from it always matched themselves), and in 2.5%, 4.9% and 9.1% (4, 8, 16 people) on the coded remote mix, where 1.76%, 2.05% and 5.30% (4, 8, 16 saved people) and 10.41% (32) of the people who were saved matched somebody else, and only 68% to 71% matched themselves (live recordings match the remote mix, so this is the figure for recordings). The suggestion threshold (cosine 0.70) is looser than the clusterer's own merge level (cosine 0.755 for the Euclidean 0.70), which is acceptable only because it is a question and never a name. Not tested: other languages, phone or speakerphone audio, children, whispering or ill voices, siblings and twins, a different microphone for the same person, and only 16 people. The thresholds and the gate are tied to the embedding model and need a new calibration for another one. The evaluation output is voice data; delete it after use.

Backups are sealed with the user's password, not the store key, so a backup keeps voices that were deleted later and restoring it brings them back; the restore sheet says so when the backup holds saved voices (`OpenedBackup.savedVoices`).

On open, the store: takes the instance lock, decrypts the snapshot, replays the journal of the same generation,
runs migrations, closes meetings left open by a crash, applies retention, and writes a fresh snapshot if anything
changed.

### Live Translation

- **Session.** One `TranslationSession(installedSource:target:preferredStrategy:)` per pair for the whole meeting,
  created outside SwiftUI for pairs that are installed (the faster low-latency family when installed, otherwise
  high fidelity; the strategy is always explicit because the framework's default depends on how the app was built).
  Downloads need `.translationTask` (the only way to get a session that may ask for consent), so a hidden host in the
  captions panel or the Settings pane runs `prepareTranslation()`; the framework reports no progress, so the UI shows
  an indeterminate indicator.
- **Rules.** Finals: immediately, in order, backlog in one batch. Partials: 250 ms debounce (at most 600 ms of
  postponement), only when grown by 2 words / 15 characters (6 for scripts without spaces), one job at a time, stale
  job cancelled; 128-sentence LRU cache per pair; publication coalesced to 10 Hz with the newest value winning.
- **Panel.** `CaptionsPanel` is a non-activating, floating, all-Spaces, full-screen-auxiliary `NSPanel` with a fixed
  height per text size (a strip for the hover controls that is always reserved, so hovering never moves a caption; three
  captions, their gaps and, with the original line, three original lines; anything that does not fit runs up under a
  soft fade at the top edge instead of dropping out); every finished caption is announced to VoiceOver when it is on
  (a switch in Settings → Translation); hover is tracked with an `.activeAlways` tracking area because Vauta is
  not the active app, and the controls stay visible with VoiceOver or Full Keyboard Access.
- **Refinement by the model server.** `LiveTranslator` takes an optional `Refiner` (`TranslationPair → RefiningTranslator?`),
  asked for each job, so turning the setting off or losing the server needs no restart. Partials and Apple's first
  caption never wait for it. After Apple's final is shown and stored, the sentence joins a queue (`+Refinement`): at most
  two requests in flight, started in order, each with a 4 s budget counted from Apple's caption (a sentence that waited
  its whole budget in the queue is dropped). The context is fixed when the request starts: the previous 3 sentences of
  this meeting's Others channel with their best translation so far (the server's when it already answered, else Apple's);
  the Me channel never enters it. An answer inside the budget replaces the line's text in place (`CaptionLine.isRefined`,
  same id, so the view cross-fades) and is stored under the same key (`INSERT OR REPLACE`); a timeout, an error or no
  server leaves Apple's text, sets `RefinementStatus.unavailable` (a hover-bar indicator, never an alert) and, after three
  failures in a row, leaves the server alone for 20 s. Pause, a pair change and a hard stop (feature turned off) bump the refine epoch, cancel the in-flight
  requests (late ones too) and clear the queue, so their answers are dropped. When the caption budget runs out the
  caption stays Apple's but the request keeps running (it no longer holds a slot) up to `Tuning.refineLateBound` (20 s in
  all); an answer then is handed to `onFinal` as a stored translation without touching the caption. When the recording
  ends (`finish`) only the queue is dropped: requests in flight finish in the background (`waitForRefinements()`, kept
  alive by `LiveTranslationModel`) without delaying the stop, and `RecorderModel` stores them through
  `EndedTranslationTarget` (the ended recording's segment rows) and `MeetingStore.saveLateTranslation`, which stores
  nothing unless the segment still exists in that meeting with the same text.
- **`ServerTranslator`.** Sends the request through the configured `LLMClient` (`ChatModel`), so the network rules, the
  server profile, the thinking switch and the audit are the ones every request has. `ChatOptions.modelOverride` selects
  the "translation model" (default: the fast model), `temperature` is 0.2, thinking is off, `max_tokens` is bounded by the
  sentence length. The prompt is a strict instruction (source and target language names, translate-only rules) plus the
  context block; `ServerTranslationCleanup` strips leaked wrappers (introductions, labels, quotes, fences, reasoning) and
  `TranslationOutputCheck` refuses loops.
- **Priority over live notes.** `LLMService.refinementTranslator` wraps the client so the service counts requests in
  flight; `liveNotes` waits (at most 20 s) while any is in flight. They do not queue in the single lane: a caption is
  useful for a few seconds.
- **Storage.** `segment_translations(segment_id → segments ON DELETE CASCADE, lang, text)`, migration 11.
- **Settings.** `translationRefinementEnabled` (default on; effective only with a server: `LLMService.Status.serverConfigured`)
  and `translationModel` (empty = fast model). `RefinementTest` backs the Test button (real latency of one sample sentence).
- **Measuring.** `Vauta translate-bench` (diagnostics build only) reports latency, CPU and main-thread cost.

### Migrations

`Schema.migrations` in `Storage/Schema.swift` is the single, ordered registry. Versions are strictly increasing and
contiguous (a test checks it); the version lives in `PRAGMA user_version`.

- Each migration runs in its own transaction together with its `user_version` update.
- A step is SQL or Swift code (for rewrites SQL cannot express). `Migration.rebuild` implements SQLite's table
  rebuild procedure with foreign keys off and a `foreign_key_check` before commit.
- A database from a newer Vauta is refused untouched.
- Journal replay runs **before** migrations, because a journal was written with the schema of its snapshot. Statements
  from older versions that no longer run are rewritten (`MeetingStore.legacySQL`).

Migration 26 adds `detected_questions` (the questions heard in a meeting, their rewrite, outcome and verified answer as JSON; deleted with
the meeting) with three triggers that keep `knowledge_fts` (kind 7) in step with the rows the person keeps. Migration 24 is data only: it deletes the chunks of Apple's retired on-device embeddings (`chunks.model LIKE 'apple-nl:%'`).
The documents index (`vauta.docs.enc`) has no schema bump for the same cleanup: at open, if its `meta` row
`apple_nl_dropped` is missing, it deletes the `apple-nl:%` rows of `passage_vectors` once and sets the flag, so there is no
rebuild and no new OCR.

Migration 28 (post-meeting actions, Part A) adds `tasks.due_day` (the calendar day of a due date as `YYYY-MM-DD`, fixed when it is set, so a reminder
or an email never shifts with a time zone; older rows are backfilled from `due` in the zone of the Mac at the update, so a task recorded in another zone can be
one day off), `meetings.time_zone` (the zone a meeting was recorded in; the zone at import for an imported one) and `meetings.follow_ups_recipe`, the table `follow_ups`
(next meetings found in a meeting or added by the person, with `dismissed` and `done` states a re-detection respects) and the ledger `created_actions`
(identifiers, container and a hash of the written title of every reminder or event Vauta added or linked; states `writing`, `created`, `linked`, `handed_off`,
`orphaned`, `removed`, `missing`; a unique index allows one live row per source and target; deleting a task or a follow-up marks its live row `orphaned`
instead of deleting it, and deleting a meeting removes its rows).

Migration 29 adds `decisions.unconfirmed_reason` and `tasks.unconfirmed_reason`: why a model-proposed item is `unconfirmed`, as a short internal code (`rank` for an item that did not make the ranked list; `rank:<code>` when the evidence check had also doubted it softly, for example `rank:noAgreement`; otherwise the check that doubted it and that the ranking never overrides: `figures` or `question`; a row with another code or none is a doubted or old one) and never meeting text. NULL for every row written before and for an item that is not unconfirmed; editing an item or marking it checked sets it back to NULL together with `unconfirmed`. `unconfirmed` keeps its meaning everywhere; only the Minutes tab reads the reason, to show the `rank` items apart (`OtherPossibleItems`).

**Post-meeting actions.** Every write to Reminders or Calendar goes through `ActionService` and the `ActionWriter` protocol, whose surface is the policy: add one
reminder, add one event, remove by the identifier the ledger recorded, and read back titles, states and dates of the list or calendar asked about. There is no call
that edits or completes an item. The order of a write is fixed: the ledger row `writing` is committed first (and the task becomes `source = 'user'` in the same
transaction, so `applyMinutes` never deletes a task that has a reminder), then EventKit saves with `commit: true`, then the row is promoted to `created` with the
identifiers. A row left `writing` by a crash is settled before the next Add by looking in its own list or calendar for an item created after it whose
normalized title hashes to `title_hash`. Tests and `llm-eval --tasks actions` use `FakeActionWriter`. `FollowUpDetector` is deterministic (a cue phrase and a
day in the meeting's own zone, nine languages) and runs after the minutes succeed, never while recording. The follow-up email is a template filled from stored fields
(`FollowUpEmail`, with a tracer test that every content line is one of them); the app hands it to the mail app and never sends it.

**Never edit a published migration.** Add a new one, with a test that opens data written by the previous version
(see `StorageSchemaTests`).

### Frozen formats

Existing installations must keep working, so these never change meaning:

- Keychain accounts: `database-key-v1`, `llm-server-v1`, `llm-bearer-v1` (and `mlx-bearer-v1`, still read).
- UserDefaults keys (listed in [PRIVACY.md](../PRIVACY.md#3-preferences-userdefaults)).
- JSON stored in the database: the card keys `resumen` and `temas`, and the live-notes keys. Swift properties are
  English and map to the stored keys with `CodingKeys`; new fields use English keys and `decodeIfPresent`.
- `segments.speaker` stores channel codes (`me`, `others`); `Channel(storedSpeaker:)` also reads the 0.1 labels.
- The server configuration JSON: new fields are optional, so a 0.1 configuration decodes and re-encodes unchanged.
- The search model's embedding space id `embeddinggemma-2@914f7f89/r1` (the `chunks.model` and `passage_vectors.model`
  value). `r1` is the recipe version (prompts, mean pooling, the Matryoshka cut and renormalisation, the chunking rule,
  the tokenizer): any change bumps it and the vectors are embedded again.
- `tasks.due_day` (`YYYY-MM-DD`), the states of `created_actions.state` and `follow_ups.state`, and the pasteboard marks `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType`.
- `NetworkPurpose.modelDownload` (`"modelDownload"`, written to the exported JSON).
- `NetworkPurpose.liveAnswers` (`"liveAnswers"`), `knowledge_fts` kind 7 (a question the person kept) and the keys of `detected_questions.answer`
  (`answer`, `claims`, `sources`, `late`; a citation's `kind` is `thisMeeting`, `pastMeeting` or `document`).
- `ModelProviderSettings.Embeddings`: the raw value `"searchModel"` is the downloaded model; the retired `"onDevice"`
  (Apple's embeddings) is never reused: loading it gives `.none` and sets the one-time `searchModelRetiredAppleNL` flag.

## Testing

```sh
swift build
swift test
```

- **Framework:** Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). Suites are named by area: `Storage…`,
  `Models…`, `Service…`, `Knowledge…`, `Context…`, `Capture…`, `Settings…`, `App…`, `Export…`, `Meetings…`,
  `Prompt…`, `Localization`, `Packaging`.
- **No user data, no side effects.** Stores open in temporary directories with an in-memory key store
  (`MemoryKeyStore`). Keychain tests use a unique service name and delete what they create, and are skipped when no
  keychain is available.
- **No network.** Model servers are faked with a `URLProtocol` stub (`StubServer`); no socket is opened. The network
  audit tests use the same stub (an entry per call type, nothing sensitive stored, ring-buffer bound, export format)
  and a source scan that fails if any file other than `AuditedSession` can reach the network.
- **No model download.** Tests never fetch the search model. The downloader runs against a `URLProtocol` stand-in that
  serves a synthetic three-block model; the tokenizer against a tiny hand-built `tokenizer.json`; ranking against a
  deterministic fake encoder. Tests that need a GPU skip without one (`MTLCreateSystemDefaultDevice`); tests that need
  the real files (tokenizer goldens, fp16 parity, memory) run only when `VAUTA_SEARCH_MODEL_DIR` names a verified install.
  Importing MLX anywhere but `Sources/VautaMLX` fails a source-scan test.
- **No audio.** Tests never record. Capture logic is tested through pure types (`MeetingAppCatalog`, `ChannelHealth`,
  `SystemAudioScope`).
- **Compatibility.** Migration tests build a database with the old SQL and check that it still opens and reads
  correctly; journal tests replay legacy statements.
- **UI logic** lives in `VautaCore` as value types (`UnlockWindow`, `AppNotification`, `RetentionChange`,
  `ServerDraft`, `HotKeyRules`, `OnboardingFlow`) so it can be tested without AppKit.

CI (`.github/workflows/ci.yml`) builds in release mode, runs the tests, lints property lists, checks translations
against English (`scripts/check-strings.sh`), checks license headers, checks the shell scripts, and assembles an
ad-hoc signed app bundle.

Never run the app binary without a command while developing: it would start a second menu-bar instance with your
permissions. Use `swift test`, or the read-only commands (`Vauta doctor`, `Vauta languages`).

## Post-meeting actions: the interface (Part A)

`ActionsModel` is the only place the views get actions from. It builds its writer lazily (`EventKitActionWriter` in the app, `FakeActionWriter` in a
`VAUTA_DIAGNOSTICS` rendering, so a scene can never reach a real store) and goes through `ActionService` for every write. The reminder and event
drafts live in it, not in a view, so the macOS permission prompt, a dismissed sheet or "Show in Transcript" never lose what was typed; opening the
editor again for the same task reuses the draft. Reading Reminders back happens only when the Tasks tab, Tasks mode or the Follow-up sheet opens.
Follow-up meetings are detected once per meeting (never while recording; a meeting whose minutes finish during a recording is looked at when it
ends). The panel card keeps `FollowUpPending` values (identifiers, counts, a time) in `RecorderModel`; nothing from the meeting is held for it.
The `.ics` folder is emptied at launch. `FollowUpEmailSummary.measuredAccurateBackends` is empty: the email's summary switch is not offered on any model
until its evaluation exists. The Follow Up… shortcut is ⇧⌘U (checked against every `keyboardShortcut` by `ActionsScanTests`).

## Links to earlier meetings (Part B)

`Sources/VautaCore/Links/`: `LinkPolicy` (constants, `LinksRelease`), `LinkCandidates`, `LinkScorer` and `LinkEngine` (pure), `LinkDifference` (+ words), `LinkChain`, `LinkVerifier` (the optional model check and its prompt), `MeetingStore+Links` / `+LinkDecisions`. `LLMService+Links` runs the keyword pass after `acta` (and after an edit, two seconds later), queues a second `embed` job whose items step embeds eligible items with the search model, and runs the vector pass and the optional check at its end (without the search model the job exists for the check alone, which then follows the keyword pass; a pass that had to wait keeps its check flag and queues the job again); tells the window (`setLinksChangedHandler`) when a pass wrote a meeting's suggestions; nothing runs while recording, in Low Power Mode or when hot (the pass waits). Migration 30 adds `item_vectors`, `item_links`, `item_link_dismissals` and `meetings.links_recipe`; `llm_jobs.kind` is unchanged. Ranked-out items are not eligible; dismissals are kept by content hash and listed by link row as well; a pass keeps the rows it makes again and a restored suggestion (`decided_at` set) is kept; `item_links.prior` records the items before a confirmation so Undo can give them back; a pass makes at most one suggestion per earlier item, and a chain never holds two items of one meeting (`sameGroups`); an item behind a newer chain member is hidden only from meetings at or after that member; `applyMinutes` returns the later meetings that lost a suggestion.
