# Privacy

Vauta is built so that your meetings stay on your Mac. This page lists everything Vauta stores, where it stores it,
everything it sends over the network, and what it never does. It describes the code in this repository; if you find
a difference, please [report it](SECURITY.md#reporting-a-vulnerability).

## In short

- **Audio is never saved.** It exists only in memory while it is transcribed on your Mac.
- **Transcripts, minutes, notes and context are encrypted** (AES-256-GCM) in a single file, with the key in your
  login Keychain.
- **Nothing leaves your Mac**, except the text you send to the model server *you* choose: one on this Mac, or one on
  your local network over HTTPS. With "Apple Intelligence on this Mac" or the integrated model, nothing leaves at all. The
  one other connection is the two optional models: if you click Download, Vauta fetches the search model or the integrated
  language model from Hugging Face and sends nothing but the request (see [The search model](#the-search-model) and
  [The integrated model](#the-integrated-model)).
- **No telemetry, no analytics, no crash reporting, no update checks, no accounts.**

## What Vauta stores, and where

### 1. The encrypted store (your meetings)

Location: `~/Library/Containers/<bundle ID>/Data/Library/Application Support/Vauta/` (the app's sandbox container).
Builds from source use the bundle ID `local.vauta.app` unless `VAUTA_BUNDLE_ID` is set.

| File | Contents |
|---|---|
| `vauta.db.enc` | The whole database, encrypted: meetings, transcripts (for a line you corrected, also what was transcribed, until you restore it), minutes (summary, topics, decisions, tasks, open questions), your notes and marks, when a recording was paused (times only), live notes, the questions heard in your meetings and their answers, search vectors, people, projects, glossary and series, the queue of pending model jobs, and the calendar title and attendees of meetings you recorded, and, only while a recording runs or after a crash until the next launch or the end of the meeting, the voice measurements used to separate speakers (see [Speaker separation](#speaker-separation)), and, only if you turn on recognizing voices and choose to save a voice, the voice fingerprints and the voice summaries described in [Voice data](#voice-data); for a meeting recorded after a brief was prepared, references to what the brief showed and its verified suggested agenda lines, with no reminder or invitation text (see [The pre-meeting brief](#the-pre-meeting-brief)), and, for the actions after a meeting, the day each task is due, the time zone a meeting was recorded in, the next meetings found in it, and a ledger of the reminders and events Vauta added for you (identifiers and a hash of the title; never their text; see [After a meeting](#after-a-meeting-reminders-events-and-email)) |
| `vauta.journal.enc` | Encrypted changes since the last full save (written every 10 seconds while recording) |
| `vauta.docs.enc` | The index of the folders and files you added as document sources, encrypted with its own key (see [Your documents](#your-documents)): their text in passages, search terms and search vectors. It is derived data and is never in the journal or in backups |
| `vauta.docs.extracting` | A few bytes, present only while one document is being read: its source, a hash of its relative path, its size and date (never a name). If Vauta quits while reading a file, the next launch skips that file |
| `vauta.lock` | Empty file that prevents two copies of Vauta from opening the store at once |
| `vauta.erasing` | Empty marker, present only while "Erase Meetings and Context" runs |
| `vauta.db.enc.tmp-…` | Encrypted temporary file, present only for a moment during a save |

Stores made by an earlier version of the app used the names `acta.db.enc`, `acta.journal.enc`, `acta.lock` and
`acta.erasing` (and the folder `Acta`). Vauta renames them in place the first time it opens them, after checking that
the database key opens the file; nothing is deleted. If both names ever exist, the less complete one is kept next to
the other as `<name>.legacy-<time>` (still encrypted with the same key). The file formats themselves did not change.

These set-aside copies, and a store left in the earlier version's `Acta` folder beside `Vauta`, are never invisible: **Settings →
Status** lists them ("Old copies of your meetings") with **Show in Finder** and **Delete…** (after a confirmation;
only these old copies go, never your current meetings or your key). Vauta also deletes a set-aside copy by itself 90
days after it was set aside, with the daily retention run (Settings → Status says so in the row); a store left in the old folder is only deleted by you or by
Erase Meetings and Context.

The database lives in memory while Vauta runs and is only ever written to disk encrypted. Files are created with
owner-only permissions (`0600`, folders `0700`). See [SECURITY.md](SECURITY.md#encryption) for the details.

### 2. Keychain items

Generic-password items in your **login keychain**, with the app's bundle ID as the service. They never sync to iCloud.

| Account | Label | Contents |
|---|---|---|
| `database-key-v1` | Vauta database key | The 256-bit key that encrypts the store |
| `database-key-v1.staged` | Vauta database key | Only while a backup is being restored: the store's new key, until it replaces `database-key-v1` |
| `llm-server-v1` | Vauta model server | Your model server settings as JSON: address, mode, private CA, certificate pins, model names, context size and request options. No key, no meeting content |
| `llm-bearer-v1` | Vauta model server key | The model server's key, if you set one |
| `mlx-bearer-v1` | — | Where an earlier version kept the server key. Vauta moves it to `llm-bearer-v1` and deletes it the first time it reads it |

The key is never shown in the interface, never logged and never exported.

### 3. Preferences (UserDefaults)

Stored in `~/Library/Containers/<bundle ID>/Data/Library/Preferences/<bundle ID>.plist`. These are settings, not
meeting content. The only meeting-related value is a numeric ID (`recordingMeetingID`).

| Key | What it holds |
|---|---|
| `preferencesVersion` | Version of the preference layout (for upgrades) |
| `onboardingCompletedVersion` | Whether first-run setup was completed |
| `transcriptionLanguage` | Default transcription language (BCP-47), or none for automatic |
| `outputLanguage` | Language of the minutes (`same` or a language code); Ask answers in the language of the question |
| `minutesTemplate` | Default minutes template |
| `historyRelockPolicy` | When Meetings locks again |
| `stopRecordingOnScreenLock` | Stop recording when the screen locks |
| `copyProtection` | Copy protection on or off |
| `notifyMinutesReady`, `notifyProblems` | Which notifications you allow |
| `recordHotKey`, `markHotKey`, `translationHotKey` | Global keyboard shortcuts |
| `actionsReminderListID`, `actionsReminderListName`, `actionsLastReminderListID`, `actionsEventCalendarID`, `actionsEventCalendarName`, `actionsLastEventCalendarID` | The list and calendar a new reminder or event starts in (opaque identifiers and the names, only to say one is gone); not in a backup |
| `actionsAlertMinute`, `actionsIncludeMeetingName`, `actionsCalendarWriteNoticeShown` | The alert time (off by default), whether a reminder's note names the meeting, and whether the first-event notice was shown (this one is not in a backup) |
| `followUpCardEnabled`, `followUpEmailMode`, `followUpEmailSummary`, `followUpEmailOpenQuestions`, `followUpEmailUnconfirmed` | The panel card and the email choices |
| `liveTranslationEnabled`, `translationTarget` | Whether Live Translation is on, and the language it translates into (none = automatic) |
| `translationRefinementEnabled`, `translationModel` | Whether your model server improves finished translated sentences, and which of its models does it (empty = the fast model) |
| `captionTextSize`, `captionShowOriginal`, `showTranslationsInTranscript` | Captions text size, whether the original words show under each caption, and whether Meetings shows stored translations |
| `captionFrames`, `captionLastScreen` | Where the captions panel was left on each display (rectangles keyed by display UUID) |
| `systemAudioScope` | Which app's audio is captured as "Others" (Automatic on a new install; an upgrade from 0.1 keeps Safari only until changed) |
| `captureAllSystemAudio` | The same choice in the format an earlier version read |
| `noSafariCallSuggestion` | Whether Vauta suggests recording when a call starts (inverted, name kept from 0.1) |
| `consentReminder` | When the panel reminds you to inform participants: `always`, `firstPerApp` or `never` |
| `autoStopMinutes` | Minutes of silence before recording stops |
| `dictationMe`, `dictationOthers` | Use the dictation engine with custom vocabulary per channel |
| `knowledgeRetentionDays` | How long minutes, decisions and tasks are kept (see [Retention](#retention)) |
| `recordingMeetingID` | ID of the meeting being recorded, so its minutes can be written if Vauta quits unexpectedly. Removed when the meeting is closed |
| `calendarEnabled`, `calendarIDs` | Whether calendar matching is on, and the identifiers of the calendars you chose |
| `calendarTitleInNotifications` | Whether notifications may show meeting titles (off by default) |
| `briefEnabled`, `briefLeadMinutes`, `briefInPersonEvents`, `briefReadInvitationNotes`, `briefHintSeen`, `briefRemindersHintDismissed` | Whether Vauta prepares a brief before a calendar meeting (on by default, and it needs Calendar on; turn it off in Settings → Calendar & Reminders) whether the one-time offer to set it up (shown only when the brief is off) was answered, whether the quiet line about Reminders in Upcoming was closed, how many minutes before it notifies you (Off, 5, 10, 15 or 30; 10 by default), whether it also does so for meetings without a video link, and whether it uses the invitation's notes (see [The pre-meeting brief](#the-pre-meeting-brief)) |
| `remindersEnabled`, `reminderListIDs` | Whether related reminders appear in the brief (off by default), and the identifiers of the reminder lists you chose |
| `integratedLiveTasks` | Who writes live notes and answers questions while you record when the integrated model is chosen: the integrated model or Apple Intelligence |
| `modelProviderChat`, `modelProviderEmbeddings` | Where minutes and search run (Apple on-device, the integrated model, a server or off). For search the value `searchModel` means the downloaded search model on this Mac; the retired value `onDevice` (Apple's embeddings) is read as keyword search |
| `searchModelRetiredAppleNL` | A one-time flag: show the notice that Apple's on-device search by meaning was replaced by the search model |
| `searchModelCoverageReached.<space>.meetings`, `.documents` | Whether the search model once finished indexing your meetings, or your documents (so a new meeting does not turn Ask back to keyword search for a minute) |
| `searchModelOfferDismissed` | Whether you closed the line in Ask that mentions the search model |
| `documentsOCR`, `documentsNetworkEmbeddings` | Whether text in images and scanned pages is read (on by default), and whether a model server on your network may also embed every indexed passage of your documents (off by default) |
| `speechLanguageLastUsed` | When each speech language was last used, to decide which downloaded speech models to keep reserved |
| `settingsPane` | The last Settings tab you opened |
| `exportFormat`, `exportIncludesTranscript`, `exportSpeakerLabels` | Your last export choices |
| `separateSpeakers` | Whether the voices of the other participants are told apart as Speaker 1, 2… (on by default) |
| `recognizeVoices` | Whether saved voices can suggest who is speaking in later meetings (off by default; see [Voice data](#voice-data)) |
| `liveAnswersEnabled`, `liveAnswersSources`, `liveAnswersSensitivity`, `liveAnswersSpeakers`, `liveAnswersHideAnsweredAloud`, `liveAnswersKeepQuestions` | Whether Vauta answers the questions it hears while you record, where it looks (this meeting, past meetings, documents), how many sentences it checks, whose questions it answers, whether it hides an answer when someone answers aloud, and whether it keeps the questions it detected with the meeting (see [Live answers](#live-answers)) |
| `liveAnswersPendingCleanup` | Only meeting numbers: the recordings made with “Keep detected questions with the meeting” off whose cleanup has not finished yet; emptied when each recording ends, and never part of a backup |
| `liveAnswersHintSeen` | Whether you answered the one-time hint about live answers in the panel |
| `voiceReminderNotifiedAt` | When the notification about saved voices unused for a year was last sent (a date; no names) |
| `voiceReminderSnoozedUntil` | Until when the reminder about saved voices unused for a year stays quiet after you chose to keep them |

Vauta turns off macOS window restoration, so window contents are not saved outside the encrypted store. macOS may
still remember window sizes and positions.

### 4. Apple speech and language assets

Transcription uses Apple's on-device speech recognition. The speech model for each language is downloaded **by
macOS**, from Apple, when you install that language (in setup, in Settings, or from the panel when a recording
needs it). macOS stores and manages these models; Vauta only asks the system to keep the ones it uses reserved.
Likewise, "Apple Intelligence on this Mac" uses the model that macOS manages.

Live Translation uses Apple's on-device Translation framework. The translation languages are downloaded by macOS,
from Apple, with the system's own consent sheet, the first time you ask for a pair; macOS stores and removes them
(System Settings → General → Language & Region → Translation Languages). Vauta only creates translation sessions for
languages already installed, so Apple's translation never sends text anywhere. (If you also use your model server to improve
translations, see "Live Translation" below.)

### 5. The search model (optional, in Application Support)

If you download or import the search model (see [The search model](#the-search-model)), its files are stored in
`~/Library/Containers/<bundle ID>/Data/Library/Application Support/Vauta Models/` (about 574 MB: `model.safetensors`,
`tokenizer.json` and `installed.json`, which records the revision, the checksums, whether it was downloaded or imported, and
the date). They are public model weights: they hold **no personal data**. The folder is separate from your encrypted store, is
excluded from Time Machine and Spotlight, is never part of Vauta's own backups, and is removed by **Settings → Models →
Delete…**. **Erase Meetings and Context** keeps it (it holds nothing of yours); delete it first from Settings if you want it
gone. The search vectors it produces from your meetings and documents are stored in the encrypted store and in the encrypted
documents index, like any other search vector, and are deleted with the model.

### 6. The Network Activity list (memory only)

The Network Activity window (Settings → Privacy & Security → **Network Activity**) shows a record of Vauta's own
connections. It lives **in memory only**: the last 1,000 requests of this run of the app, gone when Vauta quits.
Nothing is written to disk, to the Keychain or to UserDefaults. The one exception is the file you create with
**Export JSON…**, saved where you choose in the save panel. See [Seeing every connection](#seeing-every-connection).

### Nothing else

There are no log files, no caches of meeting text, no copies of your calendar, and no audio files.

One cache exists that holds no meeting data: Core ML compiles the bundled speaker models for the Neural Engine the first
time they run and keeps the result in the app's Caches folder (`~/Library/Containers/<bundle ID>/Data/Library/Caches/`,
about 25 MB). It is derived from the models only and is rebuilt if deleted. Deleting the app's container removes it.
Command-line and developer builds run unsandboxed and keep it in `~/Library/Caches/<name>/` instead.

## What never happens

- **No audio on disk.** Microphone and meeting audio are converted and handed to the speech recognizer in memory.
  There is no option to save them. Imported recordings are read in place and never copied.
- **Nothing while paused.** A paused recording stops the microphone and the system-audio capture (macOS turns its
  microphone indicator off); what is said until you resume is never heard by Vauta. Only the times of the pause are kept.
- **No telemetry or analytics.** Vauta does not measure how you use it.
- **No crash reporting.** Vauta sends no crash or diagnostic reports. (macOS's own crash reporting is controlled by
  your system settings, not by Vauta.)
- **No accounts, no cloud sync, no update checks.** Vauta has no servers of its own.
- **No third-party code except MLX.** Vauta uses Apple frameworks, the system SQLite library and one package, MLX (MIT),
  which runs the optional search model on this Mac's GPU; MLX makes no connections. It does bundle two third-party
  neural-network models (weights, not code) for speaker separation; see [Speaker separation](#speaker-separation).
- **No listening socket.** Vauta never accepts network connections.

## Network connections

These are all the connections Vauta makes. Nothing else is contacted.

| Destination | When | What is sent |
|---|---|---|
| **The model server you configure** | Live notes while recording, expanding your notes (see below), live answers to the questions heard while recording (when you turn them on), improved live translations (when a server is set up and the setting is on), minutes after a meeting, Ask (including the few passages of your documents it needs), the suggested agenda of a pre-meeting brief, search vectors, status checks, "Test Connection" and the translation "Test" | Transcript text, your notes, names and glossary terms from your context, the meeting title and date, and instructions. With documents: the few passages of your files that Ask picked for a question, and, only if you turn on "Also use the model server to find passages by meaning" for a server on your network, every indexed passage once (purpose "Indexing your documents"). For improved translations: each finished sentence of the **Others** channel and the three before it (with their translations), nothing else. What live answers and the brief send is in [Live answers](#live-answers) and [The pre-meeting brief](#the-pre-meeting-brief). Allowed destinations: this Mac (`127.0.0.1`, `::1`, `localhost`), or another computer on your local network over HTTPS with TLS 1.3. Only the OpenAI-compatible endpoints (`/v1/models`, `/v1/chat/completions`, `/v1/embeddings`) and a few read-only identification endpoints of the server type you chose |
| **Loopback discovery** | Only when you click **Find Servers** (in Settings or setup) | Read-only requests to `http://127.0.0.1` on ports 1234, 11434, 8080, 8000 and 1337 (`GET`, plus Ollama's `POST /api/show` to read a model's details), to list the models of servers running on this Mac. Never any other address |
| **Guided model setup** | Only while the **Set Up a Model Server** guide is open | The same read-only requests as loopback discovery, only to `http://127.0.0.1` ports 1234 (LM Studio) and 11434 (Ollama), about every 3 seconds; they stop when the guide closes, its window is hidden or Meetings relocks. The guide's **Get** button opens the app's official website (`lmstudio.ai` or `ollama.com`) in your default browser; Vauta itself downloads nothing and sends nothing to those sites |
| **Hugging Face** (`huggingface.co`, and the one download server it names, currently `us.aws.cdn.hf.co`) | Only when you click **Download** in Settings → Models → Search by meaning or → Integrated model (or **Try Again** / **Resume** / **Repair**), never at launch and never in the background | Plain `GET` requests with the default User-Agent (which names the app and its build, the version of macOS’s network stack and the version of macOS (Darwin), and nothing else about you) for two fixed files of one pinned revision of `google/embeddinggemma-2` (the tokenizer, and the text part of the weights in 32 MiB ranges), or of `google/gemma-4-E4B-it` (the tokenizer, and the language tower of the weights in 64 MiB ranges). No token, no cookie, no account, no identifier, nothing about you, your meetings or your documents. The purpose is "Search model download" or "Integrated model download"; the signed download address Hugging Face returns is kept in memory only and its query string is never logged. A redirect to any other host is refused (a Blocked row) and nothing is sent to it |
| **Apple** (by macOS, not by Vauta) | When a speech model, a translation language or an on-device language asset is installed | Standard system asset downloads |

### Seeing every connection

Every request Vauta makes goes through one audited code path (`AuditedSession`) that records it in the Network
Activity list. Each entry holds only:

- the time, and the **purpose**: minutes, live notes, expanding notes, Ask, live answers, preparing a brief, search by
  meaning, indexing your documents, search model download, integrated model download, translation, server discovery,
  connection test, status check, or other;
- the destination: scheme, host and port;
- the HTTP method and the URL **path** (for example `POST /v1/chat/completions`), without any query string;
- the **approximate** number of body bytes sent and received (only what is in the request and response bodies; headers
  and connection overhead are not counted), the duration, and the HTTP status or the kind of error (timed out,
  not reachable, connection lost, certificate problem, cancelled);
- for repeated probes: identical read-only probes of this Mac (same purpose, address, path and result, less than a
  minute apart; for example the guided setup checking for a server every few seconds) are one row with a **count**
  and the time of the latest one, so that polling cannot fill the list;
- for a request Vauta's own destination rules refused **before sending it** (nothing went over the network): the row
  says **Blocked** and the reason as a category (destination not allowed, address outside your network, address not
  allowed), never the content.

An entry **never** holds the content of a request or response (transcript text, prompts, answers), headers, keys or
tokens, or query strings. The window summarizes the destinations, filters by purpose, clears the list, and exports it
as JSON (`format: "vauta-network-activity"`, with the entries and the per-destination totals) to a file you choose.
Nothing is sent anywhere: the list is only for you. While a Vauta window is open, **Window → Network Activity** (⌥⌘N) opens it too.

The list covers Vauta's own connections. It cannot show what **macOS** does on its own (the downloads of speech
recognition and translation languages and of Apple Intelligence model files; see
[section 4](#4-apple-speech-and-language-assets)). To watch everything your Mac sends, or to check Vauta independently,
use a network monitor you trust, such as [Little Snitch](https://obdev.at/products/littlesnitch/) or
[LuLu](https://objective-see.org/products/lulu.html).

If you choose **Apple Intelligence on this Mac**, minutes and answers are written by Apple's on-device model. Vauta
uses only the on-device model, never Private Cloud Compute.

The model server sees everything Vauta sends it. If it runs on another computer, whoever controls that computer can
read your meeting text, and the server may keep its own logs. Choose a server you trust. See
[SECURITY.md](SECURITY.md#network-policy) for how Vauta enforces these rules, and
[docs/MODEL_SERVERS.md](docs/MODEL_SERVERS.md) for setup.

## The search model

The search model is optional. Without it, Ask and the search use keywords, which need no model. It is **EmbeddingGemma 2** by
Google (574 MB, Apple silicon only), which turns passages and questions into numbers so that passages that mean the same can be
found, in any language and across languages.

- **Only when you ask.** Nothing is downloaded until you click **Download** in Settings → Models. **Import from a File…**
  installs files you already have and makes no connection. Vauta never checks for a newer version.
- **What is fetched.** Only the text part of the model and its tokenizer, from `huggingface.co/google/embeddinggemma-2` at one
  pinned revision. Every 32 MiB block, each of the 413 weight tensors and the assembled file are checked against checksums
  built into Vauta; if anything differs, nothing is installed. Details: [docs/SEARCH_MODEL.md](docs/SEARCH_MODEL.md).
- **What is sent.** Nothing but the request for those files (see the table above). No meeting, document, name or question
  ever reaches Hugging Face.
- **Where the work happens.** The model runs on this Mac's GPU. Questions, meeting text and document text are embedded
  locally, and the resulting search vectors stay in the encrypted store and the encrypted documents index (the vectors of
  the model are deleted when you delete the model).
- **When indexing runs.** Embedding your library waits while you record (and two minutes after), in Low Power Mode, when the
  Mac is hot and on battery.
- **A question typed while you record (off by default).** Where Apple's small on-device model cannot read the meeting so far, Vauta
  can embed the finished stretches of the meeting being recorded at the moment you ask, so Ask finds them by meaning. It runs on
  this Mac only when you ask (never otherwise, never on battery, in Low Power Mode or on a hot Mac), stores the vectors encrypted with the
  meeting (they are removed when the recording ends and the embedding after the meeting writes them all) and stops when you cancel the question or the recording stops. A
  hidden preference, `searchModelEmbedLivePrefixOnDemand`, turns it on (docs/SEARCH_MODEL.md).
- **Questions in another language.** When Ask or a live answer searches your meetings by keywords and the question is in another
  language than the transcripts, Vauta translates the question with Apple's on-device Translation, only for language pairs that
  are already installed (it never downloads one). The question never leaves the Mac, and if the pair is missing or the
  translation fails the question is searched as you wrote it.
- **Removing.** Settings → Models → **Delete…** removes the files and the vectors made with the model, and Ask goes back to
  keyword search. A model server's embeddings are a separate option and work as before.

## The integrated model

The integrated model is optional. It is **Gemma 4 E4B** by Google (Apache License 2.0), which writes minutes, live notes and
answers on this Mac, and it is offered only on Macs with 16 GB of memory or more. Without it, minutes and answers use Apple
Intelligence or your model server, as before.

- **Only when you ask.** Nothing is downloaded until you click **Download** in Settings → Models → Integrated model.
  **Import from a File…** installs files you already have and makes no connection. Vauta never checks for a newer version.
  The download pauses while you record and for two minutes after.
- **What is fetched.** Only the language tower of the weights (15 GB) and the tokenizer, from `huggingface.co/google/gemma-4-E4B-it`
  at one pinned revision, in 64 MiB ranges. Every block, each tensor of the converted file and the whole file are checked
  against checksums built into Vauta; if anything differs, nothing is installed. The 15 GB original is never stored: the
  blocks are converted in memory to a 4-bit model of 4.2 GB, which is what stays. The download is listed in Network Activity
  as "Integrated model download". Details: [docs/LANGUAGE_MODEL.md](docs/LANGUAGE_MODEL.md).
- **What is sent.** Nothing but the request for those files (see the table above). No meeting, document, name or question
  ever reaches Hugging Face, and the model makes no connection of its own.
- **Where the work happens.** On this Mac's GPU. The model is loaded when it is needed and unloaded after five idle minutes,
  except while you record.
- **What it keeps in memory.** While you record, and until the minutes are written (or 15 minutes after the recording ends),
  the model keeps the part of the transcript it has already read as numbers in memory, so the minutes and the answers start
  from there. That state is never written to disk and never leaves the Mac. It is dropped when the minutes are done, and what a question
  about a meeting left in memory goes after five minutes without a question; it is also dropped at once when you delete that
  meeting or use **Erase Meetings and Context**, when the model is deleted, when memory is needed or when you quit.
- **Removing.** Settings → Models → **Delete…** removes the files (4.2 GB) and chat goes back to Apple Intelligence.
  **Erase Meetings and Context** keeps the model (it holds no personal data); delete it first from Settings if you want it
  gone. A damaged install is repaired from Settings by fetching only the damaged part again.

## Speaker separation

Vauta tells the other participants apart ("Speaker 1", "Speaker 2"…) so the transcript can say who said what, and so the minutes
can assign tasks to the right person. It is on by default and can be turned off for all meetings (Settings → Speakers, the `separateSpeakers`
setting). Each meeting also has an off switch (`speakers_off`): **Don't separate speakers in this meeting**, in its
Transcript. While you record, the panel's live transcript and the captions show provisional labels ("Speaker 2", or the
name you typed for a voice); they can change when the meeting ends, and the panel says so. Names you type while recording
stay in memory until the meeting ends and are then given to the speakers that hold the same voices, never replacing a
name you already gave.

- **It happens on this Mac.** The audio of the other participants goes through two small models bundled in the app
  (they are not downloaded) and is discarded. Nothing is sent anywhere, and this adds no network connection.
- **Between voices of one meeting only.** Vauta compares the voices of one recording with each other to group them. On its own
  it keeps no voice from one meeting to the next and does not identify anyone by voice. Recognizing a voice across
  meetings is a separate feature that is off until you turn it on; see [Voice data](#voice-data).
- **Window embeddings.** While you record, the numbers that describe each voice in each 10-second stretch (a
  few KB per stretch, no audio) are saved in the encrypted store so that a recording that crashes can still be
  finalized. They are deleted as soon as the speakers are written when the recording ends. If writing the speakers
  fails, that is retried once when the meeting ends and the numbers are deleted then, written or not. After a crash
  they are deleted at the next launch, or when the meeting ends if that comes first, and always with the meeting. If
  you turn speaker separation off after a crash, they are deleted without writing any speaker. They never appear in an
  export, a log, a prompt, the search index or the network. A backup made while a recording is running (or after a
  crash, before the next launch) can contain them, inside its encrypted payload; restoring such a backup deletes them.
- **What the model sees.** The model you chose reads the transcript to write minutes and answers, and now each line says
  who spoke: the name you gave the speaker, or "Speaker 2", and whether it was heard on the call or in the room. It
  never receives a voice measurement, a profile or the confidence number (a label the app is unsure about only carries a
  "?"). If you do not want names to leave your Mac, use the on-device model, or leave speakers unnamed.
- **Search and Ask.** When search by meaning is on, the text sent to the embedding model (the one you chose) starts each
  line with the speaker's name, or Me/Others when nobody is named or the app is unsure. Naming or renaming a speaker
  embeds that meeting again. Exports name speakers in the transcript; they never contain a voice measurement, a profile
  or a search vector.
- **Names are yours.** Vauta never names a speaker by itself, with recognizing voices on or off; you do. Calendar attendees are suggestions only. With recognizing voices on, a saved voice can only suggest a name ("Is this Ana?"), which becomes a name only when you accept it, and your own choice always wins; see [Voice data](#voice-data). A speaker who says who they are ("Hi, I'm Ana") gets the same question when Ana is a person in your Context, read on this Mac from the transcript and never from anything else: never a name you did not give, never a speaker you named or cleared, never a person you said no to for that meeting, and never you.
- **The models** are CC BY 4.0: pyannote community-1 segmentation (SHA-256 of the compiled folder
  `8cfb3d88307e2aa4d44c43d4a63ec5bbb67a6933fc955a46a248ab6a161fbdd5`) and WeSpeaker ResNet34-LM
  (`a2d1fb32a9a6bb9f457e5682b9ba567e7081bf2407e0989f6aad208807d9820d`), converted to Core ML. Vauta checks these
  hashes before it loads them and does not use a model that does not match. (Core ML then compiles the verified files
  for the Neural Engine into its own cache in the app's Caches folder; that derived copy is not covered by the hash and
  contains no meeting data.) Attribution is in [NOTICE](NOTICE).

## Voice data

Recognizing the same person in different meetings needs a voice fingerprint: a list of numbers (256 numbers from the
WeSpeaker model above), not a recording. A voice fingerprint identifies a person, so in many places the law treats it as
biometric data. That is why this feature is **off by default** and is meant to be used with the agreement of the person.

- **You turn it on.** Settings → Speakers → **Recognize voices across meetings** (the `recognizeVoices` setting). With it off
  Vauta never compares a speaker with a saved voice and never keeps a voice summary. Turning it off stops matching and
  deletes the voice summaries kept with meetings, but **keeps the voices you already saved until you delete them**, and says so.
- **Only by your action, one person at a time.** A voice is saved only when you choose **Remember This Voice** in a speaker's
  popover (the speaker must already have a name you gave; a speaker who is only a suggestion has none yet, so you accept the suggestion or type the name first), or **This Is My Voice** for yourself. Remember This Voice opens a sheet that
  says "Stores a voice fingerprint of <name> on this Mac only. Only do this if <name> agreed." and does nothing until you
  confirm that they agreed. The moment you confirm is stored with the voice (`consent_recorded_at`).
  Consent is your responsibility as the person recording, not something Vauta can check. Organizations that use this
  should cover it in their data protection impact assessment. Vauta has had no paid legal review of this text.
- **What is stored.** At most 10 fingerprints per person (beyond 10, saving another replaces the oldest), each with the name of the
  embedding model that made it (a fingerprint of another model is never used), when it was made, the meeting it came from,
  the time of the confirmation and the last time you accepted a suggestion of it. While recognizing voices is on, Vauta also keeps,
  with each finished meeting, a numeric summary of the voice of every speaker who spoke for at least 30 seconds of real,
  clean speech (`speaker_voices`), only so that **Remember This Voice** can be chosen after the meeting; it is deleted
  after 14 days, when it becomes a fingerprint, with its meeting, when you delete that person's voice or the person, when you
  turn recognizing voices (or separating speakers) off, and by **Delete All Saved Voices**. Vauta applies this rule at launch,
  once a day and after you restore a backup. These summaries are of the people in your meetings who never agreed to anything,
  which is why they are short-lived and the feature is off until you turn it on.
  No audio is stored. Nothing is stored for a speaker you do not choose except that summary (kept in two places, for the same 14 days), and only while the setting is on.
- **Finding a voice in earlier meetings.** So that Vauta can offer to look for a voice you just confirmed in your recent
  meetings, the same numeric summary is also kept in a second table (`speaker_centroids`), written with the first and under
  exactly the same rules: **14 days at most**, never longer, and it goes with its meeting, with the speaker's lines if you
  move them between speakers, when you delete that person's voice or the person, when you turn recognizing voices off, by
  **Delete All Saved Voices** and by **Erase Meetings and Context**. So the search only reaches meetings from those 14 days;
  no voice summary of a person who never agreed to anything outlives them. The summary is in encrypted backups like a saved
  voice and never in an export, log, prompt, search index or on the network. The search runs only after you accept "Look
  for Ana in recent meetings?", which is offered after you accept "Is this Ana?" or save a voice. Its results are suggestions
  ("Is this Ana?") that you accept or reject meeting by meeting, and the whole search can be undone from its banner until you answer one or close the banner (after that, each suggestion is rejected or accepted meeting by meeting; leaving the meeting while it runs cancels it and undoes it); it
  never names a speaker, and it skips speakers you named, a person you rejected for that meeting and a person you already gave
  to another speaker there. For each find, the review shows the meeting, which speaker it is, how long they talk and one of
  their lines, so you can judge it; the app never shows how close a match is.
- **Where it stays.** Only in the encrypted store, like every meeting. It is included in encrypted backups (inside the
  encrypted part; a backup without the password reveals nothing) and removed by **Erase Meetings and Context**. It never appears in
  an export, a log, a prompt to the model, the search index or Ask, or on the network, and no network connection is added.
  Tests check the export, prompt and source paths.
- **What it does.** When the speakers of a recording or an imported file are written, each speaker with at least 30 seconds
  of real clean speech, no more than 40% of it shared with another voice and a tight voice (so a cluster that may hold two
  people is skipped) is compared with the saved voices of this model. A match (cosine similarity of at least 0.70) only **suggests** the person ("Is this
  Ana?", with Yes and No; a No is remembered for that meeting); the speaker stays "Speaker 2" in the transcript, the minutes and the
  exports until you answer Yes, which is an ordinary name you gave. **A saved voice never names a speaker by itself**, however close the match;
  anything below 0.70 is not mentioned. A name you gave a speaker
  is never replaced and a cleared name is not suggested again. A person is suggested for at most one
  speaker per meeting (the closer one). In a recording, the remote speakers are never matched with your own voice (you are the Me channel). An imported file has one channel, so if you saved your own voice (**This Is My Voice**, offered only for imported recordings, never for a live recording even when you said nothing in it) it can be suggested for a speaker ("Is this you?") like anybody else. **Vauta never moves lines to Me by itself**: the calibration below is too thin for a change that cannot be undone (on clean audio it was right in a small sample of 50 comparisons, other microphones and phone audio were never tested, and remote or mixed audio was wrong too often), and Vauta cannot move stored lines between Me and Others.
- **How well it works.** The cut-offs were chosen on English recordings with headsets (AMI and VoxConverse) and measured on
  all the speakers the app would match, not only clean ones. The test was small (16 people in 4 groups, plus 16 more speakers), and
  the results depend a lot on the audio, so they are given per condition. Treat them as orders of magnitude, not guarantees.
  - *Clean headset audio, like most imports:* every saved person was matched correctly at 0.80 and no different person reached 0.70 or 0.80
    (50 comparisons of the same person and 788 of different people: a small sample).
  - *Remote audio, which is what a recording hears of the other participants:* at 0.80, about 61% of the
    saved people were reached (31 comparisons) and about 0.7% of comparisons with a different person reached it (about 4%
    between colleagues who share a room). At the suggestion cut-off (0.70) about 2.7% of different people reached it, and about 15%
    between colleagues who share a room, so a wrong "Is this Ana?" is not rare in a recording with colleagues in one room.
    With a library of saved people, about 68% to 71% were matched right, and with 4, 8, 16 and 32 saved people about 2%, 2%, 5% and 10%
    of them were matched to the wrong saved person. **In recordings, a saved person is often not suggested and is sometimes suggested as another saved person.** This is why Vauta only suggests and never names.
  - *Summary, all conditions mixed:* about 78% to 80% of the saved people were matched in their later meetings at 0.80 (the target of 80% is not met),
    about 0.6% of different-person comparisons reach 0.80 and 1% to 2% reach 0.70 (about 3% and 6% to 8%
    between colleagues who share a room).
  - **The more voices you save, the more likely an unknown speaker resembles one of them, roughly in proportion:** with 4, 8, 16 and
    32 saved people an unknown speaker resembled a saved person at 0.80 in about 1%, 2%, 4% and 6% of cases on clean headset audio, and about
    twice as often on coded remote audio.
  - Saving a person from more than one meeting was not shown to help: combining two fingerprints named fewer of the same person's
    later meetings in this test (65% to 73% instead of 78% to 80%). Vauta averages a person's fingerprints, which was not calibrated for more than one.
  - Not tested: other languages, phone or speakerphone audio, children, whispering or ill voices, siblings, twins or relatives
    with similar voices, or a different microphone from the one used to save the voice. The one mismatch that was measured (clean
    audio against coded remote audio) made errors **worse**, not more cautious, so outside the tested conditions expect to miss
    people or to suggest the wrong person more often, and never expect zero mistakes. A wrong suggestion costs you one click
    (No), and because it is never shown as a name it cannot end up in the minutes, the exports or the tasks by mistake.
- **Deleting.** Per person (Settings → Speakers, or **Delete** on the person's card, "Voice saved on this Mac · Delete"), or all at
  once with **Delete All Saved Voices**. Deleting a person from your Context, or their saved voice, also deletes the voice summaries kept in meetings for the speakers named after them. The deletion is saved to
  disk before the action finishes, so the next saved copy and journal contain none of it. Merging two people moves the voices
  to the one that remains (still at most 10).
- **Backups.** A backup is sealed with its own password, so it keeps voices you deleted after making it, and restoring it
  brings them back and replaces the voices saved since. The restore sheet says so when the backup holds saved voices; you can delete them again right after.
  Backups are encrypted and are your files: they can live on other drives or services you choose, and the voices in them are
  not deleted when you delete them in Vauta.
- **Not used for a year.** A voice whose suggestion nobody accepted for 12 months is listed in Settings → Speakers with the
  question whether to delete it, and Vauta sends a notification, without names and at most once a week, so you do not have to
  open Settings to find out. Vauta never deletes it by itself; **Keep for Now** asks again in three months.
- **Telling the others.** While recognizing voices is on, the notice you can paste into the meeting chat also says that
  voices are told apart on your Mac and may be used to suggest who is speaking.

## Your documents

Settings → **Documents** lets you add folders and files that Ask can answer from (PDF, Word, Excel, PowerPoint, Markdown, plain text, RTF, HTML, CSV and images). They are optional: nothing is read until you add a source.

- **What is read.** Only what you add, read-only. Vauta never changes, moves or copies your files, and never reads a file you did not add. Access to a source is an app-scoped, read-only security-scoped bookmark (the `com.apple.security.files.bookmarks.app-scope` entitlement), stored in the encrypted store, so a source keeps working after a restart. Removing a source deletes its bookmark.
- **Where the text goes.** Vauta reads each file on this Mac (text in images and scanned pages is read with Apple's on-device text recognition, which sends nothing anywhere), cuts it into passages and keeps them in `vauta.docs.enc`, encrypted (AES-256-GCM) with a key derived from your database key, so Erase Meetings and Context destroys it too. No plaintext copy of a file or of an image is ever written to disk. The file's relative path, size and date are kept so changes can be found; the passage text is what Ask searches and shows.
- **Who sees what.** The index is only on this Mac. When you ask a question, the few passages Ask picks (at most three items in total on Apple's on-device model, two of them from documents) go to the model you chose, exactly like meeting passages: nothing leaves this Mac with Apple Intelligence on this Mac, and with a model server they go through the audited connection (purpose "Ask") and never appear in Network Activity as content. Searching by meaning over your documents uses the embedding model you chose: with the search model on this Mac (the downloaded EmbeddingGemma 2), every passage is embedded locally and nothing leaves it; on a model server on your network it is **off until you turn it on** ("Also use the model server to find passages by meaning"), because it sends every indexed passage once (purpose "Indexing your documents").
- **Untrusted text.** The text of a document is data, never instructions: it is cleaned (control, bidirectional and zero-width characters are removed), delimited in the prompt, and the answer is shown as plain text, so a link in a document is not clickable. A citation of a document counts as verified only if its quote is found word for word in a passage that was sent. Document text never goes into the minutes, your notes' expansions, live notes or the people and projects of your context.
- **Sync.** Vauta looks for changes at launch, while it runs and every six hours, and indexes in the background, never while a meeting is recorded, not in Low Power Mode, and only text (no images, no vectors) on battery. iCloud files, and files that another cloud service keeps online only, are skipped, and so are Google Drive shortcuts (`.gdoc`, `.gsheet`, `.gslides`…, which are never opened): Settings → Documents says how many and how to fix it (download the documents from Google as PDF, Word, Markdown, Excel or PowerPoint, or download the files in Finder). Vauta never starts a download and never contacts Google or any other online service: it checks again, right before it reads a file, that the file is still on this Mac, and its file-listing and file-reading threads, and the one that opens a cited passage, are not allowed to make a cloud service fetch a file (a cited file that is only a placeholder shows the saved passage). A drive that is not connected keeps its index, and says so.
- **Your own notes about it.** The sources you chose (name, last known path, bookmark, pause state, which meeting a file is attached to) are in the encrypted store and in encrypted backups. The index is not in backups: after a restore the sources are indexed again.
- **Removing.** **Remove…** on a source deletes its bookmark and its index (securely deleted, and saved at once). Deleting a meeting removes the files attached to it. **Erase Meetings and Context** removes all sources, the index and the key. Your files are never touched.
- **Logs.** Never file names, paths or text; only counts and reasons.

## Your notes

The short notes you type (in the panel, in the floating Notepad or in a meeting's Notes tab) and what the model writes from them are stored only in the encrypted database, with the meeting; they go with the meeting when you delete it, with Erase, and into encrypted backups. They are not in preferences or logs, and an unsent draft lives in memory only. Your notes are sent with the transcript excerpt around them to the model you chose, to expand them: nothing leaves this Mac with Apple Intelligence on this Mac, and with a model server the request goes through the same audited connection as live notes and minutes and is listed in Network Activity as "Expanding notes" (never its content). Vauta asks macOS to keep the Notepad window out of screen sharing and screenshots, which the system does not guarantee for every sharing app. After the transcript is deleted by retention, your notes and their expansions stay (like decisions and tasks); the expansions keep the times they cite and no link to the deleted text.

## Live answers

While you record, Vauta looks for questions asked aloud and answers the ones your meetings or documents can answer. Everything before the model is on this Mac: each final line of the transcript is scored by rules and Apple's language tools, a candidate waits a few seconds for the next lines, and a search of this meeting up to the question, your past meetings and your documents decides whether anything could answer it (with the search model installed the question is embedded on this Mac; an embeddings server on another computer is never asked to embed what was heard). Only then does one short request go to the model you chose for "While recording": nothing leaves this Mac with the integrated model (live answers are not offered with Apple Intelligence on this Mac, and nothing is listened for or sent on it), and with a model server the check sends the lines around the question and the answer request sends the meeting's transcript so far, up to the question (only passages of it when it does not fit the model's context), plus up to three passages of past meetings and passages of your documents, through the same audited connection as live notes and Ask, listed in Network Activity as "Live answers" and never with their content. Nothing is spoken, nothing is sent to anyone else, and there is no web search.

- **What is stored.** The questions the model judged to ask for information, the words as transcribed, the standalone rewrite, what became of each (shown, not shown, no answer, dismissed) and the verified answer with its citations, in the encrypted database with the meeting (`detected_questions`, schema 26): they go with the meeting when you delete it, with Erase, and into encrypted backups. Candidates the checks dropped before the model are only counted in memory; no text of them is kept. With "Keep detected questions with the meeting" off, the ones you did not keep are removed when the recording stops (and at the next launch, only for a recording made with the setting off that quit before it finished; meetings recorded with the setting on keep their questions whatever the setting is later). When a meeting you deleted, or a document you removed, was cited by an answer stored with another meeting, the claims and text that came from it are removed from that stored answer, from search and from exports. The raw-text retention removes the ones you did not keep along with the transcript.
- **What is exported or searched.** Only the questions you keep with **Keep** (their question, answer and sources): Markdown, text and JSON exports and the search. The others only appear in the meeting's Detected questions section.
- **Other meetings and documents on screen.** A card can show a sentence of another meeting or a document. The panel asks macOS to stay out of screen sharing (`sharingType = .none`), which the system does not guarantee for every sharing app (the check by hand is in [COMPATIBILITY.md](docs/COMPATIBILITY.md#how-to-verify-an-app)); an answer is never read aloud, and VoiceOver announces only that an answer is available. The one-time hint in the panel says this too and has a Turn Off button. Turn live answers off in Settings → Recording before you share your screen if you want to be sure. Copy on a card follows "Protect meeting text from copying".
- **Preferences.** The settings are in the table of preferences above; the on/off switch and **Keep detected questions with the meeting** apply at once (Keep acts when the recording that is running ends) and the other settings apply to the next recording. Live answers start **off** with every model (the integrated model was measured and did not pass the accuracy gates; a model server was not measured), so nothing is listened for until you turn the switch on in Settings → Recording; the one-time hint appears only for a model whose default would be on, which today is none. **With Apple Intelligence they are not offered at all** (2% of its cards were judged correct): Settings shows no switch, and a recording does not look for questions or send anything, even if the switch was on before; the choice stays stored and applies again with the integrated model or a model server, also in the middle of a meeting if the model that answers while recording changes.

## Calendar

Calendar access is optional and off by default. When you turn it on, Vauta reads only the calendars you choose, and
only events around the current time, to name the meeting and its attendees. Only what concerns the meeting you
record is stored, encrypted, in the store. Vauta keeps no copy of your calendar. With the brief on, it also reads the event about
to start and the next one within 12 hours in full, and looks only at the start times of the events of the next few hours to time the
notification (see [The pre-meeting brief](#the-pre-meeting-brief)). Calendar is written to only when you press Add on a follow-up meeting
(see [After a meeting](#after-a-meeting-reminders-events-and-email)).

## Live Translation

With Live Translation on, what the **Others** channel says is translated on this Mac by Apple's Translation
framework: that text is never sent to Apple. Captions always start from that on-device translation.

**Improved by your model server (on by default, only when a model server is set up).** Each *finished* sentence of
the **Others** channel is also sent to **your model server**, together with the three sentences before it and their
translations, so the server can translate it with context. Only these sentences go, only to the server you configured
(this Mac, or a computer on your local network over HTTPS, under the same rules as every other request), through the
same connection (`LLMClient`) as live notes and minutes. Your own channel (**Me**), sentences still being spoken, other
meetings and your context are never part of these requests. If the server answers within 4 seconds its version
replaces Apple's caption and is the translation stored. If it answers later (up to 20 seconds after the request), the caption stays as it was but the better translation is still stored with the transcript and used in exports; a sentence still waiting for the server when you stop recording is finished and stored in the background, without delaying the stop (nothing is stored if the meeting was deleted or erased meanwhile). Nothing is retried. Turn it off
in **Settings → Translation**, or set no model server, and no such request is ever made. The **Test** button there sends
one invented sample sentence, not meeting text.

- Vauta asks macOS to keep the captions panel out of screen sharing and screenshots (like its other windows), which the system does not guarantee for every sharing app; the panel never takes focus.
- The translation of each finished sentence is stored in the encrypted store, in its own table that depends on the
  transcript segment. It is deleted with the segment: when the meeting is deleted, when the transcript expires
  (90 days), by Erase Meetings and Context, and it is part of an encrypted backup. It is never put in notifications, logs or
  diagnostics, and is exported only if you tick **Include translation** when exporting. When your model server improves a
  sentence, its version replaces Apple's in the store, even when it arrives too late to change the caption.
- The sentence still being spoken is translated and shown but never stored. Nothing is translated or stored while
  captions are paused or turned off.
- The only extra thing on disk outside the store is the panel's position (see Preferences).

## The pre-meeting brief

Before a calendar meeting, Vauta can prepare a brief: who is coming and when you last met, what the last meeting of the series
decided and left open, the open tasks of the people involved, related meetings, documents and notes, and the reminders you
chose. It is built on this Mac from what Vauta already holds plus three local sources, and it writes into none of them.

- **Calendar.** Only the event about to start is read in full, and the next one within 12 hours when you open Upcoming; there is no
  daily read of your calendar. To time the notification, Vauta also looks, in memory and for the events of the next few hours only,
  at when they start (and their identifier), never at who is invited, whether you declined, or anything else; when the notification is
  due, only that one event is read in full and checked for whether it qualifies. None of it is stored. With the brief off, one card offers to set it up: only events starting within 10 minutes of now are looked at, and for them only the title, the time and, in memory, whether other people are invited (to decide whether the offer applies); the description is not read. The event's title, attendees, recurrence and meeting link are used in memory; a recording stores
  what it always did (title, attendees and series). People who are only invited are never added to Context: the lookup is
  read-only. The event's description (the invitation's notes) is written by whoever sent the invitation, so it is treated as
  untrusted text: it is cleaned of hidden characters, shown as plain text (links are not made clickable), used in memory to rank
  and to write suggestions on this Mac, and **never stored, never sent to a model server and never part of a backup**. "Use the
  invitation's notes" turns it off.
- **Reminders** are off until you allow them in Settings. Vauta then reads, from the lists you choose, incomplete reminders only:
  title, due date, list and priority (never their notes, links or locations), at most 500, due from 14 days before to 7 days after
  the meeting or without a date, in memory, and keeps no copy. It never changes a reminder. A reminder that Vauta itself added from a task
  is not listed again: the task is shown once, as the task, with an "In Reminders" mark.
- **Notes.** Apple offers no way for an app to read Notes, so Vauta does not read it. Export the notes you want to use into a
  folder, add that folder in Settings → Documents and mark it as holding notes exported from Notes: Vauta then treats it like any
  other documents source (read-only, in the encrypted index), and the brief labels its passages "Note". Whether Notes on macOS 26 and 27
  can export notes to Markdown or PDF has not been confirmed in this build, so Settings gives no export instructions yet. Nothing is written to Notes
  and no automation permission is asked for.
- **What is kept.** A brief lives in memory only: it is dropped when the Meetings window locks, at Erase, and 30 minutes after the
  event. When you record the meeting it was prepared for (a meeting with a video link, or an in-person one that the card was
  showing), the store keeps references to the items it showed (a decision, a task, a
  meeting, a person, a file) and the suggested agenda lines that passed the checks, in the encrypted store, with the meeting
  (`meeting_briefs`): they follow the meeting's retention, Erase and encrypted backups. That record holds **no reminder text and no
  invitation notes**; an agenda line that cites one is not kept. If Meetings is locked when the recording starts, the brief is still
  put together from what the store holds, with no model and no cache, and only those references are kept in memory until the
  recording ends; nothing is shown until you unlock. A decision, a task and the first sentence of an earlier meeting's summary are read
  again from the store whenever the Brief tab opens, so editing or deleting them there changes the kept brief too.
- **Suggested agenda.** A model on this Mac (Apple Intelligence or the integrated model), or the model server you chose, may write a
  few suggested lines. It sees only the numbered brief items, each as untrusted data, never a transcript, a whole document or
  another event; every line cites brief items and is checked word by word (figures, dates, codes, names and claims of status
  against what it cites) before it is shown. With a model server the request goes through the audited session with its own purpose
  in Network Activity, "Preparing a brief", to your own server only; reminder titles are included, the invitation's notes never
  are, and **the topic is never sent to a remote embedding model**: with embeddings on a server, keywords rank the brief.
- **While you record,** the brief starts no model call at all, not even a search embedding: it shows what was prepared, ranked by
  keywords, and a suggested agenda waits until the recording ends. In Low Power Mode and on a hot Mac there is no agenda and
  keywords rank; at critical heat the brief is not built.
- **Notifications** say only that a meeting starts in some minutes and that the brief is ready; they never carry brief content, and the
  event's title appears only with **Show meeting titles in notifications**. They carry the calendar event's identifier and start time
  (no title, no content) so that **Record at Start** still works if Vauta relaunched before you pressed it; macOS keeps that in Notification
  Center like the rest of the notification. When Meetings is locked, the panel shows only the event's
  title and time.

- **Where it appears.** A **Next meeting** card in the menu-bar panel, **Upcoming** in Meetings and a **Brief** tab on a recorded meeting; Vauta asks macOS to keep them out of screen sharing like the rest of its windows (not guaranteed for every sharing app), and **Copy Agenda** follows "Protect meeting text from copying". **Record at Start** in the notification only asks, when the meeting starts, whether to record (nothing records by itself). "Open in Calendar" and "Open in Reminders" only open those apps.

## After a meeting: reminders, events and email

The Follow-up sheet (**Follow Up…**, ⇧⌘U), the reminder and event editors, the email draft and the panel card follow these rules; see also
[docs/ACTIONS.md](docs/ACTIONS.md).

After a meeting Vauta can suggest a reminder for a task, a Calendar event for a follow-up meeting you agreed on, and a follow-up
email. In this version two parts are not available: the email draft (the sheet shows no email
section) and the automatic search for follow-up meetings in the transcript (you add a follow-up meeting by hand with **New Event…**).
The rules below hold for them when they are switched on. **Nothing is written, and nothing is sent, until you press a button for that one item.** No model is used for any of it: a
reminder, an event and the email are copies of fields the minutes already hold, and the email is built from a fixed template in the
meeting's language.

- **Reminders.** The first time you press **Add**, macOS asks for access to Reminders (it offers only "full access"). Vauta then
  adds that one reminder, with the title and due day you saw, to the list you chose (or the one you last used, else your default;
  Vauta never creates a list). To avoid adding the same task twice it reads the **titles of the incomplete reminders of that one list**,
  in memory, and nothing else from other lists. After a crash in the middle of a save, it also looks at the titles of that list's reminders completed since then, to find the reminder it had just saved. The reminder has no alert unless you turned alerts on in Settings; its note names the
  meeting and its date, never what was said. Reminders may sync that list to iCloud or another account; the editor says so.
- **Calendar events.** If Calendar is already on, pressing **Add** saves the event in the calendar you chose, after looking in memory
  at the three days around it in that calendar for the same event. If Calendar is off, Vauta never asks for it here: it writes a
  short `.ics` file (times in UTC, no attendees) to a cache folder that is excluded from backups, hands it to Calendar, which asks
  where to put it, and deletes it after ten minutes and whenever Vauta launches. An event Vauta creates has no invitees.
- **The ledger.** To keep its promises (never twice, undo, "Open in Reminders") Vauta keeps, in the encrypted store, one row per item
  it added or linked: the item's identifiers, the list or calendar it went to, a hash of the written title and its state. Never the
  text. Acting on a task makes it yours: rewriting the minutes never deletes it. If you delete a task, its reminder stays in
  Reminders and still counts against duplicates. Deleting a meeting removes its rows; the delete sheet says how many reminders and
  events stay in Reminders and Calendar.
- **Undo and removal.** Undo, and **Remove from Reminders…** later, remove only an item Vauta created and recorded, and ask first if you
  changed it in Reminders or Calendar. Vauta never edits an item, never completes a reminder, never removes one it did not create and
  never removes one because a task or a meeting was deleted. When a reminder was completed in Reminders, the task offers **Mark Done
  Here**; Vauta never changes a task by itself. If a reminder's due day differs from the task's, Vauta shows both and writes nothing.
- **Due days.** A task's due day is stored as a calendar day (`YYYY-MM-DD`), not a moment, and a reminder receives that year, month and
  day with no time zone, so it does not move when you travel. Tasks from before this change got their day from their stored date in the
  zone of your Mac at the update; one recorded in another zone can be a day off.
- **The email.** It is built on demand, in memory, and stored nowhere: the meeting's date, the decisions, the open tasks with their owners
  and due days, optionally the open questions and the summary, and the next meeting if you confirmed one. Items the transcript did not
  back and owners Vauta was unsure of are left out unless you include them (and then marked); the summary is off by default and only
  sentences whose numbers and names are in the transcript are used. It never contains transcript lines, your notes, answers, speakers'
  labels or timestamps. Attendees with a stored address are listed, **none ticked**, those outside your own address's domain marked
  **External**; no address is guessed and no address book is read. Vauta never sends it: it opens your mail app's composer (or Share, or a
  `mailto:` link, or copies it). Your mail app may save the draft to its server before you send it. The text copied to the clipboard is
  marked so clipboard managers and history skip it and stays on this Mac (not Universal Clipboard); Copy Minutes does the same. The link
  handed to the mail app is never written to a log.
- **Copy protection.** With **Protect meeting text from copying** on, the email's Open in Mail, Share and Copy are disabled, as Export is.
  Adding a reminder or an event stays allowed, because you press it for that one item, and the editor says in one line that the text
  will leave Vauta for Reminders or Calendar.
- **The panel card.** When the minutes of a recorded meeting are ready and nothing is recording, the menu-bar panel can show a **Follow-up**
  card with **Review…** (off with Settings › General › **Show follow-up after meetings**). It keeps in memory only meeting identifiers, counts
  and a time, shows no counts and no titles while Meetings are locked, can create nothing, and goes after 2 hours.
- **Reading back.** When the Tasks tab, Tasks mode or the Follow-up sheet opens, Vauta looks up only the items in its own ledger (to show
  "Done in Reminders", "Not in Reminders any more" or a different due day), and only with the access you already gave.
- **Network.** None of this uses the network or adds a destination to Network Activity: Reminders, Calendar and your mail app do their
  own syncing and sending.
- **Evaluation.** The hidden `llm-eval --tasks actions` command writes to a fake store of reminders and events, never to yours.

## Notifications

Notifications never contain transcript text, minutes or error details (a server's error message could quote meeting
text). Meeting titles appear only if you turn on **Show meeting titles in notifications**; otherwise Vauta uses the
meeting's date and time. Notifications you allow are kept by macOS in Notification Center and can appear on the lock
screen, which is why they are kept this short.

## Export and import

- **Export** (Markdown, plain text, PDF, SRT, WebVTT, JSON) writes only to the file you pick in the save panel.
  Exported files are **not encrypted**: once saved, they are yours to protect.
- **Copy Minutes** and the Copy button of an Ask answer put text on the clipboard, marked so that clipboard managers and history skip it, and kept on this Mac.
- **Import Recording** reads only the audio or video file you pick. The file is read in place, transcribed on this
  Mac and never copied or changed.
- **Private CA import** (Settings → Models) reads only the certificate file you pick.
- **Paste Configuration** (Settings → Models) reads the clipboard only when you click it.

The App Sandbox gives Vauta access only to files you pick in an open or save panel.

## Copy protection

**Protect meeting text from copying** (Settings → Privacy & Security) blocks copy, cut, drag and drop, Services,
Share and Look Up on meeting text, turns off spell checking (so text isn't handed to the spelling service), and
blocks Export, Copy Minutes, copying Ask answers and the follow-up email (Open in Mail, Share and Copy). It is on for installations upgraded from an earlier version and off for new installations.
Writing Tools are always off for meeting text, because they may send text off your Mac. VoiceOver and other
accessibility tools can always read the text.

Adding a reminder or a Calendar event stays allowed (see [After a meeting](#after-a-meeting-reminders-events-and-email)).
Correcting a transcript line also stays allowed: its field takes typing and pasting, never copying out.

Copy protection prevents accidents, such as meeting text ending up in a clipboard manager. It does not stop someone
who can see your screen from taking a screenshot.

## Locking Meetings

The Meetings window and Settings → Context ask for Touch ID or your login password. Under **Lock Meetings again** you choose
when they lock: after 1, 5 (the default), 15 or 30 minutes without activity, or only when the screen locks. They
always lock when the screen locks, the Mac sleeps or you switch users. Locking also hides the live transcript in the
menu-bar panel; it is hidden by default, in case your screen is shared.

Recording stops when the Mac sleeps or you switch users, and, if **Stop recording when the screen locks** (Settings → Recording) is on (the
default), when the screen locks. Everything transcribed up to that point is saved.

The lock protects the interface. While Vauta runs, the decrypted database is in its memory.

## Retention

Retention has two speeds:

- **Transcripts are deleted 90 days after the meeting started** (at most 7 days later for a meeting still waiting
  for its minutes, see below). This includes the transcript, search vectors, live notes and name suggestions.
- **Minutes, decisions, tasks, notes and marks** follow the setting **Minutes, notes and tasks** (Settings → Privacy &
  Security):

| Option | Effect |
|---|---|
| Delete with the transcript (default) | The whole meeting is deleted after 90 days |
| Keep for 1 year | The transcript goes after 90 days; the rest of the meeting is deleted after 365 days |
| Keep for 2 years | The same, deleted after 730 days |
| Keep until I delete them | The transcript goes after 90 days; the rest stays until you delete the meeting |

When you keep minutes longer than the transcript, Vauta first writes the minutes of meetings that don't have them yet
(from day 85), and gives a meeting without minutes up to 7 more days before its transcript is deleted. Where the
transcript recorded the exact words used for a person or project, only the name from your context is kept.

Retention runs when Vauta starts and once a day after that. It also deletes the encrypted copies the migration from an earlier version
set aside (see [the store](#1-the-encrypted-store-your-meetings)) once they are 90 days old. Choosing a shorter option shows how many meetings it will
delete and asks you to confirm. Meetings that are empty (no transcript, notes or marks) are removed automatically.
The meeting being recorded is never deleted.

Deleting removes the text from the database and its search indexes, and the freed space is overwritten. Copies of the
encrypted file made before the deletion (for example one you copied by hand) still contain it, encrypted with the same key,
until you use Erase Meetings and Context.

## Backup and restore

The live store is excluded from Time Machine on purpose (old copies would still contain deleted meetings). To move to
a new Mac, to a build with a different bundle ID (a separate container and Keychain), or to keep an offline
copy, use **Settings → Privacy & Security → Back Up…** and **Restore…**. Both ask for Touch ID or your password first.

- **What is inside a backup:** the whole store, exactly as Vauta holds it in memory: meetings, transcripts, minutes,
  notes, marks, context (people, projects, glossary), series, search vectors, the queue of pending model jobs and any saved voices
  ([Voice data](#voice-data)),
  plus your settings (an allow-list of preferences: languages, templates, shortcuts, privacy and recording options,
  Live Translation options, and whether minutes are written by Apple Intelligence or a model server) and a small
  manifest (Vauta version, schema version, creation time, number of meetings). The settings are inside the encrypted
  part like everything else. Never included: the model server (address, models, key and pins, which live in the
  Keychain), any other Keychain item, the speech models, and what belongs to one Mac (window positions, the
  chosen calendars, setup and hint markers). Set the model server up again on the new install: if the backup chose a model server and this Mac has none, the restore keeps this Mac's own choice (Apple Intelligence) and the result says where to set the server up. A backup made before
  settings were included restores the meetings and context and leaves your settings as they are.
- **How it is protected:** the file is encrypted with AES-256-GCM using a key derived from the password you choose
  (PBKDF2-HMAC-SHA256, 1,000,000 iterations, random salt). The manifest is inside the encrypted part, so the file
  reveals nothing but its size. The password must have at least 12 characters, and Vauta shows a strength hint.
  **Vauta cannot recover a lost password.** Anyone who has the file can try passwords offline, so use a long passphrase and keep
  the file somewhere you trust.
- **Plaintext:** the database is read from memory and encrypted; no unencrypted copy is written to disk. The file is written only where you
  choose in the Save dialog.
- **Restoring replaces everything.** If the store has meetings, Vauta shows "This replaces N meetings with M from
  the backup" and waits for your confirmation. The settings in the backup replace the same settings on this Mac; a
  setting the backup does not hold, or cannot read, is left as it is. A newer backup than the app understands is refused; an older one is
  upgraded. Restoring gives the store a **new** database key and deletes the old one from the Keychain, so copies of
  the previous store (Time Machine, disk remnants) can no longer be read. The backup file stays as it was. Restoring
  is not possible while a meeting is recording.
- Meetings older than your retention limit are removed the next time Vauta starts, as usual.

## Erase Meetings and Context

**Settings → Privacy & Security → Erase Meetings and Context…** (confirmed by typing a word and by Touch ID or your password):

1. deletes `vauta.db.enc` and `vauta.journal.enc` (and any `acta.*` or `.legacy-*` copies of them, including a store
   left in the earlier version's `Acta` folder);
2. deletes the database key from the Keychain and creates a new one;
3. starts over with an empty, encrypted store.

This removes the data and the key from this Mac. The store file is excluded from Time Machine backups, and a copy of
it left anywhere else can no longer be decrypted with any key Vauta has now. One caveat: older Time Machine backups of
your **login keychain** may still contain the old key, protected by your login password at that time. Someone with
that keychain backup, that password and a copy of the old store file (for example one you copied by hand) could
decrypt it. Erasing does not change old backups; delete them if that matters to you.

Erasing meetings and context keeps your preferences, the model server settings and key, and the speech models. To remove Vauta
completely:

1. Use **Erase Meetings and Context** (so old copies can't be read with the current key).
2. In Settings → Models, remove the model server (this deletes its settings and key from the Keychain).
3. Quit Vauta and delete the app.
4. Delete `~/Library/Containers/<bundle ID>`.
5. Optionally, in Keychain Access, delete any remaining items whose name or service is Vauta's bundle ID.

## Recording other people

Vauta transcribes what everyone in the meeting says. **Processing on your Mac does not remove your duty to tell the
other participants** that the meeting is being transcribed. Data protection laws such as the GDPR can require it, and
some places (two-party or all-party consent jurisdictions) require everyone's consent to record or transcribe a
conversation. This is not legal advice: follow the law where you and the participants are.

Vauta helps without getting in the way (**Consent helper**):

- When a recording starts, the menu-bar panel shows a discreet, dismissible row with a short notice you can paste into
  the meeting chat, written in the meeting's language (the transcription language; the interface language if Vauta has
  no translation for it). **Copy Notice** puts it on the clipboard. Vauta never sends it, never posts it in the meeting
  app and never blocks or delays recording.
- **Mark as Informed** records that you told the participants, and when. The date is stored in the encrypted store as
  part of the meeting (so it follows the meeting through retention, Delete, Erase Meetings and Context and Back Up), shown quietly
  under the title in Meetings, and included in the JSON export as `participantsInformedAt`. It is a note for you, not
  proof of consent.
- **Settings → Recording → Remind me to inform participants**: *Always* (default), *First time with each meeting app*
  (until you have marked a meeting from that app as informed) or *Never*. Dismissing the reminder does not count as
  informed: only **Mark as Informed** does.

## Changes to this page

Changes to Vauta's data handling are listed in [CHANGELOG.md](CHANGELOG.md) and reflected here in the same release.

## Links to earlier meetings

When links are on, the encrypted store also holds `item_vectors` (numbers made from your tasks and decisions by the search model on this Mac), `item_links` (which item looks like which, and your answer; for a "different from" link also the few differing words copied from the two items), `item_link_dismissals` (hashes of the words of two items you said are not the same, never the words) and `meetings.links_recipe`. `item_links` also keeps, until you undo a confirmation, what the two items were before it (their source, a hash of their words and whether they were marked unconfirmed). Links are off in this release, so none of this is stored today. Nothing leaves the Mac, no model server is asked, and everything goes with its meeting.
