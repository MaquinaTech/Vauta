# Pre-meeting brief

Before a calendar meeting Vauta can prepare a **brief**: a short page that answers "what do I need to know walking into this?".
It is built on this Mac, from what Vauta already holds (earlier meetings with their decisions, tasks and open questions, the
person's documents) and three local Apple sources (Calendar, Reminders and a Notes export folder). It is suggest-only: nothing is
written to Calendar, Reminders or Notes by the brief (the actions after a meeting, which can add a reminder or an event you confirm, are a separate module with its own
writer; the brief module calls none of its write APIs, and a test says so). See [PRIVACY.md](../PRIVACY.md#the-pre-meeting-brief) for what is read and kept.

This page describes the code in `Sources/VautaCore/Brief/` and the interface in `Sources/Vauta/App/Brief/`.

## Where it appears

- **Notification** `vauta.brief` at the chosen time before the meeting (Off, 5, 10, 15, 30; Settings → Calendar & Reminders), once per occurrence, only when the brief has something in it and a recording is not running. It never carries content; the title appears only with the titles setting. Buttons: Open Brief (Touch ID, then Meetings → Upcoming) and Record at Start (a one-shot suggestion when the meeting starts; it does not record).
- **Panel card** "Next meeting" above the record button from the lead time until 15 minutes after the start; locked, it shows the title and time only. While recording, a collapsed "Brief" row (hidden when locked).
- **Meetings → Upcoming** (sidebar row above the list, shown while Calendar is on; with the brief off it only says how to turn the brief on): the event about to start and the next within 12 hours, built when opened; Refresh (also offered if the load takes more than a few seconds), Show all, Open in Calendar (shows the event in Calendar when its identifier is known, else opens the app; a reminder opens the same way).
- **Brief tab** on a meeting recorded while its card was on screen and that takes the **same calendar occurrence** (identifier and start; a title is never enough, and a recording that takes no event keeps no brief): the references to known people and Vauta's own items, and the verified agenda; no reminder, no invitation text and no attendee who is not a known person. "Prepared" shows when the recording began.
- **Settings**: Calendar & Reminders (brief, notification time, in-person, invitation notes, Reminders and their lists), Documents (a folder holds notes exported from Notes).
- **The default: on once Calendar is on, notification 10 minutes before.** `BriefPreferences.enabled` is true and the lead time 10; Settings → Calendar & Reminders turns the brief off or sets the lead time (Off, 5, 10, 15, 30; there is no second switch in General). The judge had recommended leaving it off until the evaluation is re-run; the default was kept after reading the result. The stored default is `BriefPreferences.enabled` (two places in that file), and every statement of it is in README.md, README.es.md, CHANGELOG.md, PRIVACY.md and docs/CLAIMS.md. While the brief is off (a person turned it off), the first time Calendar is on and a qualifying meeting is coming the panel shows a one-time card with only the title and time (nothing is built, the description is not read) with **Set Up…** (opens Settings → Calendar & Reminders) and **Not Now**; turning the brief on ends the offer.
- The suggested agenda is wired but `BriefAgendaShipping.shipped` is empty: no backend shows it (see Evaluation result). Keywords rank related meetings, documents, notes and reminders (`BriefRankingShipping.searchModelRanks` is false).
- "Last time" is wired but `BriefLastTimeShipping.shipped` is empty: no backend shows it (see [Re-judged evaluation](#re-judged-evaluation-november-2026)). In its place:
  - the last meeting leads "Related meetings", one click from its minutes, with no line of them;
  - the open tasks of the people invited stay under "Open tasks";
  - the panel card shows the last meeting rather than "Nothing open from earlier meetings".

  Stored minutes do not record which backend wrote them, so the switch reads the backend that writes minutes now. The evaluation still builds the section, to measure it.

## Pieces

| File | What it does |
|---|---|
| `BriefEvent.swift` | The event (memory only), `BriefEventSource`, the selection rules (chosen calendar, not all-day, not declined, a meeting link or another attendee), the 12-hour window, the lead time, the one-notification-per-occurrence ledger, and the invitation's list lines (cleaned, capped, plain text). |
| `MeetingStore+BriefFacts.swift`, `BriefFacts.swift` | Read-only lookups: the series, the people (`MeetingStore.resolveAttendees`, the same matching `applyCalendar` uses, as a SELECT), the last meeting (series first, else at least half of the attendees), its decisions, open tasks, open questions (located with `BriefOpenQuestionLocator`) and files, and the open tasks of the attendees. |
| `BriefReminders.swift` | The reminders protocol (read-only) and the filter: chosen lists, incomplete only, due −14…+7 days or none, at most 500 read, at most 3 shown; a reminder that is in the ledger of the actions after a meeting (matched by identifier or external identifier, `LedgerIdentifiers`) is dropped, and its task is shown once, as the task, with `BriefItem.inReminders` (the defect fixed: Vauta's own reminder was listed next to the task it came from). The EventKit implementation is `Sources/Vauta/App/Brief/EventKitBriefSources.swift`. |
| `BriefRetrieval.swift` | The retrieval protocol, the keyword gate (two shared content words, or a code or rare name) and the topic text (title, last topics and decisions, invitation lines; 400 characters; fewer than three content words skips the related sections). |
| `BriefBuilder.swift` | The deterministic brief: people, last time, open tasks, related meetings, documents and notes, reminders, the invitation. Series and attendees choose the candidates; the topic only re-orders them. Related items pass on the search model's raw cosine (0.65) or on the keyword gate. Item IDs `b1…bn`. |
| `BriefAgenda.swift`, `BriefVerifier.swift`, `BriefStatusWords.swift` | The suggested agenda: packing per backend (Apple 4K: 3,314 tokens in, 450 out, 12 items; integrated 20; server 30), the prompt (items as delimited data, IDs neutralized), the schema, and the verifier (cites, figures, dates, codes, names, status claims, overlap, duplicates; fewer than two lines hide the section). |
| `BriefComposer.swift` | The pipeline (steps 1 to 6), with the policy applied. |
| `BriefPolicy.swift` | Recording, Low Power Mode, heat, battery and memory rules; the agenda's token budget (`ContextBudget`). |
| `BriefCache.swift` | The memory-only cache and its invalidation; `carryAgenda` keeps an agenda whose cited items did not change. |
| `BriefStored.swift` | `meeting_briefs`: references and verified agenda lines kept with a recorded meeting (no reminder or invitation text). |
| `LLMService+Brief.swift` | The retrieval and writer adapters for the real model layer. Nothing here starts a model call while a meeting is recorded, and embeddings on a model server never rank a brief. |
| `BriefPreferences.swift` | The preference keys and their defaults. |

## Evaluation: `llm-eval --tasks brief`

Hidden, evaluation only (see `tools/llm-eval/README.md`). It needs public transcripts (`--sets`), stored minutes
(`--brief-minutes-apple`, `--brief-minutes-integrated`: the `minutes_<provider>.jsonl` of the minutes runs) and **synthetic fixtures**
(`--brief-fixtures`), one `<series>.brief.json` per series:

```json
{
  "series": "ES2004", "language": "en", "split": "dev", "briefed": "ES2004d",
  "earlier": ["ES2004b", "ES2004c"],
  "speakers": {"Speaker 1": "Project Manager"},
  "event": {"title": "...", "attendees": [{"name": "...", "email": null}], "new_attendees": [], "service": null, "invitation_notes": "Agenda:\n- ..."},
  "reminders": [{"id": "r1", "title": "...", "due_days": -1, "list": "Work", "relevant": true}],
  "notes": [{"name": "tooling.md", "text": "...", "relevant": true}],
  "documents": [{"name": "budget.md", "text": "...", "relevant": false}]
}
```

The fixtures are written by a session that sees only the meetings before the briefed one, never the briefed meeting's gold, and are
hashed before the gold exists. `attendees` were at the earlier meetings too; `new_attendees` join only the briefed one. The task writes their SHA-256 to `fixtures.sha256` and never reads the briefed meeting's transcript.

Arms: `K0` and `S0` (keyword or search model, no agenda), `KA`/`SA` (Apple's agenda), `KG`/`SG` (the integrated model's agenda), and
the baseline `BL` (`BLA`, `BLG`): the same model recaps the last meeting's minutes alone, with no retrieval and no verifier. Per run
the trace carries the deterministic measurements: items per section, invalid links, wrong attribution against the store, distractor
reminders and notes shown, invented history for a first meeting, whether a replay gives the same brief (`digest`), compose and agenda
seconds, and for an agenda the lines proposed and accepted and the rejections by reason (counts only). `briefs/briefs.jsonl` and
`briefs/<series>.<arm>.txt` hold the rendered briefs, with nothing that names the arm, for the blind judge.

| Gate | Where it is measured |
|---|---|
| Link validity 100%, wrong attribution 0 | `linksInvalid`, `wrongAttribution` in the traces |
| Distractors at most 1 per brief | `distractorsShown` |
| No invented history in a first meeting | `inventedHistory` |
| Replay determinism | `deterministic`, `digest` |
| Snapshot latency, agenda latency | `composeSeconds`, `agendaSeconds` |
| Agenda unsupported and hallucinated lines | the blind judge on `briefs.jsonl` (the verifier's rejections are in `rejected_*`) |
| Precision, recall, "walks in prepared" against `BL` | the blind judge and the gold; not computed by the harness |

No sentence of the form "better than X" is written without a blind comparison against X.

## Evaluation result

A single blind LLM judge graded 101 packets (1,307 item rows) from 13 synthetic-fixture series, 8 of them test series. Intervals are 95%, bootstrapped by series; with 8 test series they are wide. The judge read the README before grading and could tell the backend from the "Last time" text, and the gold has one model pass with no human review. One judge only.

Deterministic brief on the 8 test series (keyword ranking K0, search model S0, Apple minutes KA/SA, integrated minutes K0/KG):

| Gate | Result |
|---|---|
| Link validity 100% | pass (0 invalid links in 1,675 items) |
| Wrong attribution = 0 | **failed**: 1 (integrated arms) and 2 (Apple arms), both found and fixed (below) |
| P@3 Last time at least 0.80 | **failed**: 0.65 [0.33, 0.92] with integrated minutes, 0.21 [0.04, 0.46] with Apple's; without the 2 test windows that have no callback, 0.83 and 0.28 |
| P@3 Open tasks at least 0.80 | measurable on Apple only (4 series): 0.63 keywords, 0.79 search model; integrated minutes carry no owners, so no section |
| P@3 Related meetings at least 0.60 | 1.00 (4 series) |
| P@3 Documents and notes at least 0.60 | 0.75 [0.38, 1.0] keywords, 0.71 search model |
| Callback recall at least 0.60 | 0.82 [0.69, 0.94] to 0.87 [0.74, 0.98] across arms |
| Distractors at most 1 per brief | 0.13 keywords; 0.63 to 0.75 search model |
| Compose p90 | 0.41 to 0.49 s, within the gates |
| No invented history in a first meeting | pass |

Against a recap of the last minutes alone (baseline), the judge preferred the structured brief in 36 of 64 test pairs, called 28 ties and preferred the baseline in none; "walks in prepared" (1 to 5) improved by +0.50 [0.13, 1.0] (integrated) and +0.75 [0.38, 1.0] (Apple). The baselines made 5 wrong claims on test. Nothing here is a "better than" claim about any other product: no competitor was measured.

Agenda gates per backend (test series): Apple 41.7% useful (gate 70%), 0% unsupported plus hallucinated on test (1.5% over all 13 series, with one hallucinated owner on a development series); integrated Gemma 4 E4B 54.1% useful, 1.4% unsupported plus hallucinated on test (0.8% over all 13), 0 hallucinated. Both fail the usefulness gate, and the agenda changed no "walks in prepared" rating. Latency passes (agenda p90 6.1 to 6.7 s on Apple, 17.1 to 17.2 s integrated); integrated energy is 0.036 to 0.044 Wh per brief; Apple's energy is not measurable with the probe. **The agenda is off for Apple and the integrated model. The model server's agenda was not run (unmeasured), so it is off too.**

Search model against keywords (related plus documents P@3, paired by series): -0.042 [-0.125, 0.000] on test; it showed more irrelevant items (+0.50 per brief [0.13, 0.88]); the recall gain is within noise. **Keywords rank the brief; no ranking claim is made for the search model.**

Defects the judge found and what was done:

- Every integrated arm printed one task due date a day early (the evaluation's renderer formatted the day in UTC while the date is stored at local midnight). The renderer now uses the local time zone. The deterministic check reads the day printed in the rendered brief and compares it with the `due` string of the stored minutes the task came from (and the summary's printed date with the meeting's stored start, formatted without the app's own formatter); tests run it under America/Los_Angeles and Pacific/Pago_Pago, and the first version of this check compared a value with itself and could not have found the bug.
- A model-written summary can carry a reference date that disagrees with the meeting's stored date (Apple's minutes on two series). "Last time" now skips a first sentence that dates its meeting differently from the stored date, and the check counts such a line as wrong attribution.
- The first sentence of a summary was cut at an abbreviation ("Sra."). Common abbreviations and single letters no longer end a sentence.
- Not fixed, because they come from the stored minutes and not from the brief: Apple's minutes list non-tasks as open tasks and sometimes contradict themselves in their decisions.

Series IB4010 and IB4011 are the same April selection meeting, not an earlier and a later one, and two of the four test Concejo windows barely continue their earlier window; both should be replaced before numbers are published. The server arm, other products, an M1 with 8 GB and the seven languages other than English and Spanish were not measured.

## Re-judged evaluation (November 2026)

The keyword brief (K0) was built again over fresh minutes of the 21 earlier meetings, written by the release build of `f484493` on both
backends: KA0 over Apple's minutes, KG0 over the integrated model's. It was then judged blind again.

**How it was judged.**
- **Packets.** 26 packets, 342 item rows, from the 13 series of the first evaluation (8 of them test series).
- **Judges.** Four judge instances, one per group of series (two of AMI meetings, two of Concejo sessions).
- **Rubric.** It asks for the transcripts to be read first. Before the grades were sealed, all four applied the same three rules and the same callback rule:
  - **W1.** A line that the earlier transcripts contradict is `wrong`, even when the stored minutes say it.
  - **W2.** A line that inflates what was said is `wrong`: a proposal or one person's view shown as a decision, a remark or that meeting's agenda shown as a task, a question already settled shown as open.
  - **W3.** A true but old line is not `wrong`.
  - **Callbacks.** A callback counts as surfaced only when a line not labelled `wrong` points to it.
- **Seals.** The grades were sealed before the key was opened: key `54c3222f…`, item grades `270a4384…`, brief grades `45892dde…` (SHA-256).
- **Limits.** One label per line, from one judge, with no human review.

**A defect of the evaluation, found while reading the results.** The evaluation stored every item of the minutes as firm, with no segment, so the judged briefs were not the app's:
- **Ranked-out items were shown.** Apple's ranking had left out 32 decisions and 39 tasks of the 21 meetings, which the app keeps among the other possible items, out of the brief.
- **Unconfirmed items had no mark.** This hit the integrated model hardest: 48 of its 72 decisions and 42 of its 52 tasks are unconfirmed, and the app marks each one.

The evaluation now stores the minutes as the app does, through the same code as the actions evaluation. The rendered brief marks an unconfirmed task `[check]` and an owner not confirmed, as the app does. The briefs were built again: 23 lines are new, and 52 differ from a judged line only by a mark, so they keep its label. The second table below uses those labels.

**"Last time", P@3 (gate: at least 0.80).**

| Brief | Apple's minutes (KA0), test | All 13 | Integrated model's minutes (KG0), test | All 13 |
|---|---|---|---|---|
| As judged | 0.29 | 0.33 | 0.38 | 0.44 |
| As the app shows it (corrected) | 0.21 to 0.29 (21 lines not judged, counted wrong or relevant) | 0.26 to 0.38 | **0.38** | **0.44** |

Both backends fail the gate, whatever the lines that were not judged turn out to be.

**Wrong lines in "Last time" (as the app shows it).**

| Backend | Wrong lines | Per brief (test) |
|---|---|---|
| Apple | at least 48 of 109 (21 not judged) | 3.6 to 4.8 |
| Integrated | 31 of 103 | 2.3 |

**Where the wrong lines come from.** As judged, the wrong lines of "Last time" split by the kind of line:

| Kind of line | Apple: wrong / lines | Integrated: wrong / lines |
|---|---|---|
| The summary line | 4 / 16 | 0 / 13 |
| Firm decisions and tasks | 30 / 49 | 5 / 17 |
| Unconfirmed decisions and tasks | 3 / 4 | 16 / 46 |
| Ranked-out items (not shown in the app) | 13 / 23 | none |
| Open questions | 11 / 22 | 10 / 27 |

- **The cause is the stored minutes, not the brief's ranking.** The brief repeats what the minutes say. The wrong lines are proposals shown as decisions, tasks nobody took, and questions shown as open that the meeting had settled.
- **The unconfirmed mark does not separate them.** On the integrated model's minutes, 16 of the 31 wrong lines carry it, and so do 22 of the 43 relevant ones.

**The other sections (as judged, test series).**

| Section | KA0 | KG0 | Gate |
|---|---|---|---|
| Documents and notes, P@3 | 0.54 | 0.50 | at least 0.60: **failed** |
| Related meetings, P@3 | 0.00 | 0.00 | at least 0.60: **failed** |
| Reminders, P@3 | 0.58 | 0.57 | none |
| Open tasks, P@3 | 0.17 | 1.00 | too few series to read (2 and 1) |

- **Related meetings.** All 16 of its lines were labelled `marginal`: true and on topic, but not used by the briefed meeting.
- **Per brief, test series:**

  | Measure | KA0 | KG0 | KG0 − KA0 [95%] |
  |---|---|---|---|
  | "Walks in prepared" (1 to 5) | 2.1 | 2.6 | +0.50 [−0.13, 1.13] |
  | Noise (0 to 3) | 2.3 | 1.9 | −0.38 [−0.88, 0.13] |
  | Missed callbacks | 1.75 | 1.75 | |

**The deterministic gates, on the corrected briefs (15 briefs per backend, two of them first meetings).**

| Gate | Apple's minutes | Integrated model's minutes |
|---|---|---|
| Invalid links | 0 of 300 items | 0 of 279 items |
| Wrong attribution | 0 | 0 |
| Distractors shown | 1 in all 15 briefs | 1 in all 15 briefs |
| Invented history | none | none |
| Replay | deterministic | deterministic |
| Compose p90 | 0.49 s | 0.68 s |

**A defect of the wrong-attribution check.** Minutes runs write a task with no due day as `"due": ""`. The check counted that as a day the brief failed to print: every wrong attribution in the first traces of this run (45 on Apple's minutes, 30 on the integrated model's) came from it. It now reads `""` and `"null"` as no day, as the validation does. The traces count wrong attribution by the check that found it (`wrongAttribution.<check>`).

**What changed.** No backend shows "Last time" until one passes its gate (`BriefLastTimeShipping`, as the agenda is hidden: see [Where it appears](#where-it-appears)). No ranking or quality claim rests on these figures. No other product was measured.

## Rules worth knowing

- Due dates are whole days: a task is overdue only when its day is before the day of the meeting (a task due on the day of the meeting is not).
- A task or decision of a deleted meeting leaves the brief on the next build (deleting a meeting changes the store revision the cache keys on).
- Memory: the references kept for the recorded meeting (no reminder or invitation text) stay in memory until the recording ends, so the row can come back after unlocking. If Meetings are locked when a recording starts (the usual case), the deterministic brief is built then anyway, with no model, no agenda and no cache write; only its references are kept, nothing is shown until unlock, and they are saved with the meeting at the end.
- The brief cache drops an entry 30 minutes after its event ends (`BriefController.pruneNow`, run by a timer, on every refresh and on opening Upcoming); the Upcoming entries of that event go with it.
- The panel card's own state needs the store: with none (still opening, recovering or failed) there is no card, and it is looked at again when the store opens.
- The notification carries the event's identifier and start (not content), so Record at Start still works after a relaunch; the event is read again then, by its occurrence.
- With the brief off the one-time offer reads only events starting within 10 minutes of now (title, time and, in memory, whether others are invited).

## Not done

- The deterministic brief fails P@3 for "Last time" on both backends, also when re-judged with the minutes stored as the app stores them (see [Re-judged evaluation](#re-judged-evaluation-november-2026)), so no backend shows that section; "Documents and notes" and "Related meetings" fail their gates in the re-judged run too. The brief is on by default; no quality claim rests on it.
- The model server's agenda is unmeasured.
- A recording carries the brief when it is linked to the calendar occurrence the brief is for, or, for an in-person event (no meeting link), when it starts from the panel while that event's card is shown (from the lead time to 15 minutes after the start, `BriefController.inPersonEventOnCard`, the same window as `BriefRecordingMatch`). In that case the event's title, attendees and series (never the invitation's notes) are saved with the recording like those of a meeting with a link, so the next occurrence finds it by series or by attendees. A recording of anything else started in that window, such as an unrelated ad-hoc conversation, also takes the card's event; the person who wants none closes the card by recording later or discarding the recording. Recordings near a linked event that is not the card's keep none.
- **Not verified: Reminders access under the App Sandbox.** Whether `requestFullAccessToReminders` shows its prompt with only `com.apple.security.personal-information.calendars` has to be checked by running a signed, sandboxed build and pressing Allow Reminders Access…. It needs a maintainer with a real Reminders store; the automated checks never run the app against it. The build keeps `NSRemindersFullAccessUsageDescription` in Info.plist and adds no entitlement. If the prompt does not appear, discuss it with the maintainer before changing `Resources/Vauta.entitlements`: until then, Reminders may show "Open System Settings" with nothing to toggle.
- **Notes export.** Notes on macOS 27.0.1 ships a Markdown export ("Markdown Export & Import", "Export Archive…" in its own resources, read as files; the Notes database was not touched). The same on macOS 26 has not been confirmed. The Documents pane keeps the switch and tells a person, under it, to use Export Archive… in Notes and save the Markdown files in the folder (the item's name is the one Notes shows in each language). If macOS 26 cannot export, hide the switch and say so here and in the README.

## Links and ranked-out items

Chains the person confirmed show once in "Open tasks" ("carried over since…"); a confirmed "same" decision says "first decided on…"; a confirmed "changes" shows both decisions ("replaces the decision of…"). Nothing changes until links are on. By design (`BriefPolicy.leavesOutRankedOutItems`, with a test), "Last time" and "Open tasks" leave out the items the minutes' ranking put in "Other possible items", as the Minutes tab does; before, on Apple's model they could lead "Last time" marked unconfirmed.

### Defects

- Fixed: ranked-out decisions and tasks appeared in the brief (on Apple's model they could lead "Last time" marked unconfirmed). They are now left out, and ranked-out tasks are dropped before the 100-candidate limit, not after.
