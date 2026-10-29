# After a meeting: reminders, events and the follow-up email

What Vauta can do with a meeting's minutes once they are written, and the rules that keep it safe. Everything is suggest-only: Vauta
proposes, you confirm each item, and nothing is written or sent without that. Nothing leaves your Mac except what you hand to your own
Apple apps (Reminders, Calendar) or your own mail app. No account, no connector, no new network destination.

This page covers Part A (reminders, calendar events, the email draft). Links to earlier meetings (Part B) are described at the end of this page; they are built and tested but **off in this release**.

**What is on in this build.** The design includes an email draft and follow-up detection by fixed rules. After the second judged
evaluation, on the minutes made with the new extraction ([BENCHMARKS.md](BENCHMARKS.md#post-meeting-actions)), `ActionsRelease` says (the detector figures below were measured on those minutes; the app makes its minutes with the shipped new extraction on the integrated model, with the ranked extraction on Apple's model (where rules version 2 was run on 2026-10-24, with no judge: precision 1.00, capped recall 0.857, day accuracy 1.00 on 14 meetings; see [LANGUAGE_MODEL.md](LANGUAGE_MODEL.md), "DEV check of the shipped combinations"), and with the old one on the servers, not measured for the detector. With them the detector reads the same cited segments and the last tenth of the transcript; its task path ignores implausible days, and since rules version 2 it counts a task marked "to be confirmed" only when its cited clause states the day, see Calendar events below):

- **Automatic detection of follow-up meetings is on**, with at most 2 candidates per meeting. All three gates pass: precision 1.00 (26 of 26;
  Wilson 0.87 to 1.00, so the lower bound is under 0.90 with so few candidates), recall with the cap of 2 at 0.867 (26 of 30, gate 0.60) and day
  accuracy 1.00 (26 of 26). Over all 103 expected meetings recall is 0.25, and of the 2 natural mentions (committee Mondays) it found none. Every
  suggestion still waits for your confirmation; **New Event…** by hand stays. All 26 matches were sentences inserted into the test transcripts; recall on natural speech is 0 of 2. When nothing is found the sheet says Vauta found none, never that none was mentioned.
- **The email draft is off on both backends** (the sheet shows reminders and calendar events only, with no email section on either). The first gate,
  no factual error in the default email, fails on every arm. One email: Apple 56 errors, every one of 15 emails with one or more; integrated model
  15 errors in 11 of 15 emails, 0.20 would be sent after light edits. One per owner: Apple 0.43 would be sent, integrated model 0.89 on 9 meetings only
  (it covers only owners that were stored). The code and its tests stay.
- **The email summary is not offered on any model** (none was measured).

**Extraction.** The causes the judge found in the stored tasks, owners and decisions were worked on
([LANGUAGE_MODEL.md](LANGUAGE_MODEL.md#tasks-decisions-and-owners-in-the-minutes-development-phase)): items nobody committed to or agreed are
stored "to be confirmed" (so the default email leaves them out), the owner is decided from the transcript and never the asker, closing tasks are
asked for, and an unbacked due day is dropped. At the time of these measurements the app ran the new extraction on the integrated model only (`MinutesRelease.extraction(integrated:)`, set on 2026-10-20); the harness phase has since switched Apple to the ranked extraction (see [LANGUAGE_MODEL.md](LANGUAGE_MODEL.md), "Harness phase"), and the servers keep the old one. The citation-verification rate showed no detectable drop (Apple 0.571 to 0.611, integrated 0.921 to 0.912; non-inferiority within 0.05 is not shown at this sample size), and in a blind pairwise comparison of the summary and open questions the integrated model had 6 summary errors old and 7 new (sign test p 0.73). Apple's trend was unfavourable (18 summary errors old, 23 new, p 0.34) and the judge counted more invented or wrong content with the new extraction (Apple 10 to 16, integrated 2 to 8), so Apple kept the old extraction until the harness phase re-measured it (history), and the servers keep it because they were not measured (LANGUAGE_MODEL.md, "Release state"). Judged on 15 test meetings, with the build of 20 October 2026 (before the post-review fixes in LANGUAGE_MODEL.md; those meetings are now spent for any further tuning, so a decision to switch on needs a fresh held-out set), with the new extraction run in the evaluation:
on the integrated model wrong owners fell from 19 to 2 (11 of 15 meetings with a wrong owner to 2 of 15; sign test p 0.006); on Apple's model the
list is not better (precision 0.223 before and after), but the false items that reach the default email fell from 275 to 42. Apple's lists remain
mostly non-items (email-grade precision 0.57) and it hides 30 real items as "to be confirmed".

The sections below describe the whole design, including the held parts.

## Where it is

| Where | What |
|---|---|
| Meetings › a meeting › **Tasks** tab | A **Reminders** column appears when a task has a reminder; **Add to Reminders…** is in the task's context menu and in the **Reminders** row of the task editor (the keyboard and VoiceOver way). Tasks mode offers the same. |
| **Follow Up…** (File › Follow Up…, ⇧⌘U, or the toolbar button) | One sheet: reminders from the open tasks, the follow-up meetings found in the transcript (at most 2) and calendar events added by hand (**New Event…**). The email draft is built but not shown in this version (see below). |
| Menu-bar panel | After a meeting's minutes are ready, a **Follow-up** card offers **Review…**. It can create nothing. |
| Settings › Calendar & Reminders › **After meetings** | The default list and calendar, an optional alert, whether notes name the meeting. |
| Settings › General › **Show follow-up after meetings** | Turns the panel card off. |

## Reminders

- **Add to Reminders…** opens an editor (a sheet, not a popover, so the macOS permission prompt does not close it) with the exact fields
  that will be written: title, list, due day, optional alert, and notes ("From the meeting “Weekly sync”, 12 Oct 2026"; the meeting's name
  is optional). No transcript text is ever written. A task someone else owns gets "Ana: " in front of its title; your own come first in the sheet.
- The draft lives in Vauta's memory until you press Cancel or Add: the permission prompt, a dismissed sheet or "Show in Transcript" do not lose it.
- **Access.** Vauta asks for Reminders access only from a button you pressed (**Allow Access…** in the editor or the sheet), never at launch
  and never from the panel. Denied: the editor says so and offers **Open System Settings**; Add is off.
- **Which list.** The one chosen in Settings, else the last one you used, else Reminders' default list. Vauta never creates a list. If the
  list chosen in Settings is gone, the editor says so.
- **Due day.** The day the minutes wrote, as a floating date (no time zone), so it does not move when you travel. The alert is off by default
  (a setting); when on, one alarm at that time of day on the due day.
- **Nothing twice.** A task has at most one live reminder. A reminder that is already in the list (an equal or look-alike title, only the list
  you are adding to is read, in memory) is shown first: **Use This One** (links it; nothing is written) or **Add Anyway**. A reminder you added
  before deleting the task here is offered back as **Use This Reminder**. A crash between the save and the bookkeeping is recovered, not repeated: when a surface opens, an interrupted write is settled by looking for the item in its own list (incomplete reminders and those completed since the intent), created within two minutes of the intent (a reminder you typed later is never taken for Vauta's).
- **Acting makes it yours.** A task you add becomes yours: rewriting the minutes never deletes it.
- **Where it went.** The row shows **Reminders** (with the list on hover and for VoiceOver). Menu: **Open in Reminders**, **Remove from
  Reminders…** (asks first; says so if you changed the reminder there), **Unlink** for a reminder you already had (Vauta never removes one it did not create).
- **Undo.** A bar after every Add (10 seconds; no time-out while VoiceOver is on) with **Open** and **Undo**, and Edit › Undo. Undo removes only
  what Vauta just created and keeps a reminder you changed.
- **Read back.** When the Tasks tab, Tasks mode or the Follow-up sheet opens, Vauta looks up only its own reminders (by identifier, then by its own external identifier in any list, so a moved reminder is still found): **Done in Reminders** (with
  **Mark Done Here**; a task never changes by itself), **Not in Reminders any more** (**Add Again…**, **Forget**), and a due day that differs is
  shown ("In Reminders, due 10 Oct (here: 24 Oct)") and never written. The Follow-up sheet also looks up the events it added: one you deleted in Calendar stops
  showing **Added to Calendar** and the follow-up is a suggestion again (full Calendar access only).
- **Copy protection.** Allowed, with one line in the editor and under the sheet's Add button: the task text leaves Vauta for Reminders. (The email is blocked, as Export is.)

## Calendar events

- Follow-up meetings are found by fixed rules ("let's meet again Tuesday at ten"), in the nine languages, relative to the meeting's own date and
  zone. A weekday is always marked **day inferred: check it**; a past date ("we met last Tuesday") and a deadline ("by Friday") are not follow-ups.
  A task marked "to be confirmed" only makes a candidate when the passage it cites says that day in a clause that is neither a question nor a hedge ("Should we meet on Friday?" and "maybe Tuesday" make none), because the stored task does not say whether it is marked for its words or only because Apple's ranking left it out of the main items (rules version 2). Each candidate shows the words and the moment it came from. **Not a Meeting** dismisses it for good; **New Event…** starts one by hand.
- **Edit and Add…** opens the event editor (title, calendar, day, time or All day, duration; a time that was not said must be set). With full
  Calendar access the event is added through EventKit; without it, an `.ics` file is handed to Calendar, which asks where to put it. Vauta never asks for Calendar access.
- An event like this one already in that calendar on that day blocks the Add: **Already in your calendar**, **Open in Calendar**.
- The first event written shows once: "Vauta will add this event to Work · iCloud. It never changes events you made."
- Undo, **Remove from Calendar…** and **Forget** (for a hand-off) follow the same rules as reminders. No attendees are ever invited.

## The follow-up email

A fixed template filled from the minutes: no model writes any part of it. The meeting's date is written, never "today". It includes the
decisions, the open tasks with owners and due days, open questions (a switch), and the next meeting when you added one. Unconfirmed items and
uncertain owners are left out unless you switch **Include unconfirmed items** on (then they are marked). **One email** or **One per owner**; the
language starts as the meeting's and can be any of the nine. A per-owner draft holds only that person's next steps (the judged evaluation
found that repeating decisions and open questions in every draft repeated every error in them), so its subject reads "…: your next steps" and
**Include open questions** is not shown in that mode; this differs from the first design, which put the decisions in every draft.

- **The summary** is off, and the switch is not offered: it appears only on a model whose summary was measured against the transcript, and none has been.
- **Recipients:** the meeting's attendees that have an address stored, **none ticked**, outside-organization addresses marked **External**, the
  count on the button (**Open in Mail · 3 recipients**). No address is guessed and no address book is read.
- **Hand-off:** **Open in Mail** (the mail composer; a `mailto:` link only when short, else **Copy and Open Mail**), **Share…**, **Copy** (Shift: Markdown).
  Copying marks the item concealed and transient and keeps it on this Mac. Vauta never sends anything, and your mail app may save the draft on its server.
- **Copy protection** disables all three, as it does Export; the preview stays readable.

## The panel card

When minutes of a recorded meeting are ready and nothing is recording, the panel shows "Minutes ready · 4 tasks" with
**Review…**. Several meetings that finished back to back share one card (the sheet has **Next Meeting**). While Meetings are locked the card says
"Minutes ready" with **Unlock to Review**, no counts and no titles. It goes after 2 hours, when reviewed or closed, and is hidden while recording
(the list is kept). Only identifiers, counts and a time are kept in memory.

## What is stored

Migration 29 adds only `unconfirmed_reason` to decisions and tasks (why an item is unconfirmed, see [ARCHITECTURE.md](ARCHITECTURE.md)); the email, the detector and the Reminders flow read `unconfirmed` as before. An item that only ranked out of the main list (`rank` or `rank:<code>`) (the Minutes tab's "Other possible items") is unconfirmed for all of them: left out of the email unless "Include unconfirmed items" is on, and a candidate for the detector only when its cited clause states the day.

Migration 28: `tasks.due_day`, `meetings.time_zone`, `follow_ups`, and the ledger `created_actions` (identifiers and a hash of the written title,
never text). All encrypted, in backups, gone with Erase. Preferences: `actionsReminderListID`, `actionsReminderListName`, `actionsLastReminderListID`,
`actionsEventCalendarID`, `actionsEventCalendarName`, `actionsLastEventCalendarID`, `actionsAlertMinute`, `actionsIncludeMeetingName`,
`actionsCalendarWriteNoticeShown`, `followUpCardEnabled`, `followUpEmailMode`, `followUpEmailSummary`, `followUpEmailOpenQuestions`,
`followUpEmailUnconfirmed`; a backup carries the switches, never the list and calendar identifiers or the notice marker.
Deleting a meeting does not remove what was created from it; the confirmation says how many reminders and events stay.

## Code map

`Sources/VautaCore/Actions/`: the rules (`ActionService`, `ActionWriter`, drafts, detector, email, `ActionsPresentation`). `Sources/Vauta/App/Actions/`:
`EventKitActionWriter` (the only file that saves or removes anything in Reminders or Calendar), `ActionsModel*` (editor drafts, the sheet, undo),
`ReminderEditor`, `EventEditor`, `FollowUpSheet`, `EmailDraftView`, `ActionStatusViews`, `PanelFollowUpCard`, `AfterMeetingsSettings`. Tests and
renderings use `FakeActionWriter`; no test or scene touches a real Reminders, Calendar or Mail.

## Due days

A due day is kept only when it is not before the meeting's own day and not more than a year after it. The evaluation found days years before the
meeting in stored minutes; such a day is dropped when the minutes are read and ignored if an older task has one, so no reminder or email carries it.

## Not verified here

A signed build on macOS 26 and 27 still has to be checked by hand against a throwaway list and calendar: that the permission prompt keeps the editor
and its text, the save, Open, Undo, the first-write notice, that Mail opens the draft, and whether the Reminders prompt appears under the current
entitlement (no entitlement was changed). The judged evaluation was run once by one LLM judge (single rater, no human review; the gold labels were also model-assisted, and the judge was of the same model family that wrote the gold labels, so judge bias cannot be ruled out),
and no human spot-check of the gold labels has been done; its numbers are in [BENCHMARKS.md](BENCHMARKS.md#post-meeting-actions) and no sentence compares Vauta
with another product. The judged arms have not been re-run after the fixes listed there.

## Feature table

What Vauta does after a meeting, stated as plain features. It says nothing about any other product: the columns for other products are
left to be filled from each product's own current documentation, because they cannot be checked from this repository.

| Feature | Vauta |
|---|---|
| Where the minutes are made | On this Mac (Apple's on-device model, the optional integrated Gemma 4 E4B, or a model server you choose) |
| Account or sign-in needed | None |
| Tasks to Reminders | Yes, one at a time or ticked in a batch; the editor shows the exact fields |
| Confirmation | Per item; nothing is ticked beforehand and nothing is written until Add |
| Added twice | Not unless you choose Add Anyway: a ledger of identifiers and a look at the titles of the one list it adds to (a file handed to Calendar is checked against the ledger only) |
| Undo | Removes only what Vauta added; asks first if you changed it there |
| Follow-up meeting to Calendar | Yes, through Calendar access you already gave, else a file that Calendar opens and asks where to add; found in the transcript (at most 2, each confirmed by you) or added by hand (New Event…) |
| Follow-up email | Built from a template, for your own mail app; not available in this version; see [BENCHMARKS.md](BENCHMARKS.md#post-meeting-actions) for why |
| Reads from Reminders and Calendar | Only the titles of the one list or calendar it adds to, in memory, plus the items it created |
| Copy protection | Reminders and events allowed with a one-line warning; the email is blocked like Export |

## Part B: links to earlier meetings (E7/E8)

**Status: built, tested, judged, off.** `LinksRelease` has every switch false on every backend: nothing is suggested, no item is embedded for links and no row is stored. The development series set the constants; one blind judge then graded the test series (2026-10-25, [BENCHMARKS.md](BENCHMARKS.md#post-meeting-actions-part-b-links)). **No arm passed**: link precision on natural pairs (G1) and recall (G3) fail on both Apple's model and the integrated one, so links stay off for both, the model check is not used on either, and "Different from…" suggestions are not shown on either. The model server was not measured. A human spot-check of about 50 gold labels is still pending. The code stays, and a switch turns on per backend only when a later run passes its gates.

**What it does.** After the minutes are written (never while recording), each task and decision is compared with those of earlier meetings in the last 180 days that share its series, a person who was at both, its owner (tasks) or a project or client it mentions, and that are in the same language. A suggestion appears under the item as a question: "Same task as on 12 Sep?", "Same decision as on 12 Sep?", or, only where "different" suggestions pass their gate, "Different from 12 Sep?" with the old and new figure. The person confirms or dismisses each one (Edit > Undo takes a Same/Not the Same answer back). At most one suggestion per item and six per meeting. Confirming sets both items to the person's, so a rewrite of the minutes keeps them; it does not clear an item's "Unconfirmed" mark.

**How candidates are scored.** Keyword gate (content-word Jaccard at least 0.5 and three shared words, or a shared code or rare name with one more word; same series or owner); with the search model, the raw cosine of the items' own words (floor 0.90, set on the development split: at 0.80 many pairs of the same area that are not the same item passed; no boost) plus one shared word. A suggestion is made once per earlier item in a meeting, so two items of one meeting never join one chain. `LinkDifference` makes a pair a change only for one differing figure with the same unit, one deadline date, a reversal attached to a shared word, or an approved/rejected pair; a pair that differs otherwise (another quarter, several figures) is dropped, never shown as "same". Tasks are only ever "same". An optional model check (Apple's model or the integrated one, never a model server) can only remove a suggestion or upgrade it with a span copied word for word. It runs in the `embed` job after the keyword pass when there is no search model, and after the vector pass when there is. Reversal words and month abbreviations are read in the item's own language only, and ambiguous abbreviations ("may", "mar", "set"…) count as months only when capitalized or followed by a full stop.

**Ranked-out items.** Items in "Other possible items" are neither sources nor candidates and are not embedded until the person marks them checked or edits them. Doubted items stay eligible and show the mark (dev-only switch `LinkPolicy.includesDoubted`). The dev arm LS0R measures what this costs.

**Where it shows.** Under tasks (Tasks tab) and decisions (Minutes tab); the Suggestions tab lists "Dismissed links" with Restore (a restored suggestion stays until you decide it); Tasks mode shows one row per chain of confirmed "same" tasks ("Carried over · 3 meetings since 12 Sep"), asks once whether the earlier mentions go done too, and a link "1 suggestion" on a task's own row opens its meeting (only rows that have one show it); the brief shows a chain once ("carried over since…"), "first decided on…", and for a confirmed change both decisions. A chain shares its reminder (Use This Reminder, no write; a different due day shows "In Reminders, due … (here: …)"). A task that only shows another member's reminder offers Open in Reminders and nothing that would forget, unlink or remove that member's record. A "same" task whose earlier mention had another due day says "due date changed from 10 Oct". The email's chain de-duplication is owed for when the email ships (it is held).

**Answers.** Edit › Undo takes back Same Task / Same Decision / Not the Same / Not Related (Restore has no Undo: dismiss the row again), and "Mark as Done" on a chain restores every status it changed. Confirming records what the two items were (model's or yours, their text and mark); Undo gives them back to the model only if nothing else changed them since and no other confirmed link holds them. A suggestion that a newer pass replaced while you looked at it is refreshed, and Vauta says so instead of dropping your click. A pass keeps the row of a suggestion it makes again, and the open meeting is reloaded when a pass finishes. A substantial edit of an item returns its confirmed links to suggestions ("needs review") and marks them as the person's, so no later pass deletes them; a small edit keeps them confirmed. Restoring a dismissed pair is refused (it stays dismissed) when the newer item already has a confirmed link, so an item never has both. Confirming a link that would put two items of one meeting in one chain withdraws that suggestion quietly. The heading of Tasks mode has no count (it never had one), so chains are counted as one row each; "Also mark the 2 earlier mentions as done" names how many tasks the box would close.

**Storage (migration 30).** `item_vectors`, `item_links` (with `prior`, what the items were before a confirmation), `item_link_dismissals`, `meetings.links_recipe`. A dismissal is kept by a hash of the normalized words of both items, so Rewrite Minutes (new item ids) does not bring a dismissed pair back. **Limit:** the hash is of the words, so a rewrite that rewords an item makes it a new item for the pass and the pair can come back; the replay reports this and it is not a pass/fail check. A dismissed pair is listed by its link row as well as by its words, so a small edit does not hide it from Restore. Rewriting an earlier meeting runs the keyword pass again for the later meetings that lost a suggestion. Nothing leaves the Mac; a model server's embeddings are never used for links.

**Evaluation.** `llm-eval --tasks links` (tools/llm-eval/README.md). Not every arm's check ran: in the run that was judged, the model check ran only after the vector pass, so the keyword arms LKA and LKG had **no check** (their `modelCalls` are 0) and their "same set as LK0" says nothing about the check. The check now also runs after the keyword pass; no run has used it yet, so G8 is unmeasured for the keyword arms. Gates per backend: link precision on natural pairs at least 0.85, false links per target at most 0.3, recall at least 0.50, "changes" false-positive rate at most 0.10 (else no "different" suggestions), seeded near-miss shown in at most 10% of series, LS0 beats LK0 on F1 (else keywords for everyone), the model check keeps recall within 0.05 or is not used, and latency and energy on the shared Mac. A human spot-check of about 50 gold labels comes before any decision to switch links on; it is pending. Not measured: model server arm (LSS), cross-language pairs (dev only, reported, not shown), any claim against other products.
