# Accessibility notes

What the interface does for VoiceOver and keyboard users, per area. A section says when its manual pass with
VoiceOver is still to be recorded.

## Vauta's sphere and the panel's look

Status: designed and checked in renders (light, dark, Increase Contrast, Reduce Transparency); the manual pass with
VoiceOver and Reduce Motion on a real recording is part of the panel checklist at the end.

- The sphere (`VautaOrb`) is decorative: it is hidden from VoiceOver. The record button keeps its own label ("Start
  Recording", "Stop Recording", or the state while Vauta is busy), value, hint and tooltip; the small "thinking" sphere
  that replaces a spinner keeps the label or value the spinner had.
- Reduce Motion: the sphere, its orbit, the rings while recording and the Welcome cards do not move (one still frame;
  the cards appear without sliding). Renders use the same still frame.
- The white glyph on the sphere keeps at least 3:1 against the sphere under it (WCAG 1.4.11 for graphics): measured
  over the glyph's box at 120 moments of the animation, the worst case is 3.5:1 at rest and while recording, 3.7:1 for
  the quieter sphere. When a permission or the store blocks recording, the button is the opaque grey of before
  (5.1:1 and 5.9:1), with an outline under Increase Contrast.
- Increase Contrast: the glow behind the panel's header, Setup and a meeting is not drawn, and the coloured edge of the
  cards Vauta writes becomes the plain outline every card gets. The sparkles that mark what the model wrote are Vauta's
  indigo (#554AE0 on light backgrounds, #9D95FF on dark ones), at least 4.5:1, and the primary colour on a selected row.
- The orbit and the rings never carry information: the state is in the words next to the button and in the header.

## Speakers in the Meetings window

Status: designed and unit-tested where logic is involved; **the manual VoiceOver pass is still to be recorded here
(it needs a person with VoiceOver on a real Mac: a maintainer or a contributor records it; see the checklist at the end)**.

- A transcript line is one element: "Ana, remote, 12:04: text" (name, where the voice comes from, time, text). A
  second voice on the user's own microphone reads "in the room". Without speaker data it reads as before ("Me, 12:04: text").
- The value of the line carries what is uncertain: "Not sure who said this", "Several people spoke at once", after the
  translation when there is one.
- The line's custom action "Speaker options" opens the speaker popover; it is offered only on lines that have stored speaker
  data (older meetings and meetings with speakers off do not get an action that does nothing). The line is the
  focusable element (its label is part of it and is hidden from VoiceOver on purpose, so the line is read once). The
  keyboard way into the popover is the action above or the Edit menu item **Speaker Options for Highlighted Passage**
  (the passage is highlighted with ↑↓); with the pointer the visible label is a button. Escape goes back one page of the
  popover, then closes it. Full Keyboard Access on the line is still to be checked by hand (an open acceptance item, with the VoiceOver pass).
- Return in the popover's name field assigns only a person whose name or alias is exactly what was typed; otherwise it adds
  a new person, which is what the row says. A name that two people answer to shows a warning and lists them, and nothing
  is assigned until one is picked.
- The "Separate speakers in this meeting" switch always matches the transcript. Right after the user removed the
  speakers, checking it again undoes exactly that removal, never
  another step of the undo stack, until another meeting is opened. When separation was already off, the box is unchecked
  and dimmed and the note says why (Vauta keeps no audio). The note is right under the switch and has an info symbol.
- When the speaker or the line was removed while the popover was open, or separation was turned off, the popover shows
  what happened, what to do and a Close button (default action) instead of the choices; with the removal still undoable it
  also offers **Bring Back Speakers**. A person who already is another speaker of the meeting reads "Already speaking in
  this meeting" and leads to the merge confirmation.
- No state is colour-only: the speaker's name is always written; a guess is italic with a question-mark sign; crosstalk has
  its own sign; the talk share is written next to its bar (the bar is hidden from VoiceOver).
- Colours of speakers beyond the first of a channel keep at least 4.5:1 contrast on the light and dark window
  backgrounds (`SpeakerUILogicTests.everySpeakerColourReadsOnItsBackground`); neighbouring colours stay clearly apart
  (`neighbouringSpeakersGetDifferentColours`).
- A quote of a line the app is unsure of (Ask, search results, a person's mentions) reads "<name> (not sure): " and is
  italic, and its value adds "Not sure who said this".
- "Who spoke" rows are buttons that open the same popover; the name is the label and "3 min · 36%" its value, so the share is read with the name.
- Every edit is undoable from the Edit menu ("Undo Merge Speakers", …).

## Speakers while recording (menu-bar panel and captions)

Status: designed and unit-tested where logic is involved; **the manual VoiceOver pass is still to be recorded here
(see the checklist at the end)**.

- A live transcript passage is one element: time, the voice's name, text. A voice the app is unsure of adds "Not sure who
  said this" as its value; crosstalk adds "Several people spoke at once". The visible signs (italic with a question mark,
  the crosstalk sign) repeat what VoiceOver says, and the name is always written, so no state is colour-only.
- The hint "Speaker names may change when the meeting ends." is part of the transcript card and is read after the passages.
- Naming a voice: each voice is a chip button ("Speaker 2"), exposed as selected when the name field is for it, with the
  hint "Chooses who the name is for". A named voice has a second button, "Remove <name>". The field's label names the
  chosen voice ("Name for “Speaker 2”"). Calendar attendees are suggestion buttons ("Adds this person"); nothing is
  assigned until one is activated.
- Captions: from two voices on, a caption reads "<name>: <sentence>" (one element per caption, as before). The name drawn
  in the caption is shortened for the eye only (a leading title such as "Dr." is dropped first); VoiceOver always gets the
  full name. A caption cut to its last lines keeps its name before the ellipsis. A caption still being spoken has no name
  yet. In a right-to-left target the name is an isolate led by a right-to-left mark, so the sentence keeps its direction.
- "Speakers updated" after a recording is an info notice with a "Check Speakers" button (it opens the saved meeting's
  transcript) and its own Dismiss button; the saved-meeting announcement is unchanged.
- Settings → Speakers is a plain form: each switch is read with its explanation as its description. **Recognize voices across
  meetings** is off by default; the saved voices are a list of rows, each reading the person's name and the detail
  ("2 fingerprints · last suggestion accepted Oct 3, 2026") with a Delete button whose spoken label names the person
  ("Delete the saved voice of Daniel"); Delete and Delete All ask first in a system confirmation. While Meetings are locked
  the names are not listed (a single row says voices are saved and offers Unlock). The reminder for voices unused for a year is an
  info notice with **Delete These Voices…** and **Keep for Now** (while Meetings are locked it offers **Unlock…** instead, because the
  names are hidden) and also arrives as a notification without names that opens this pane.
- A saved voice never names a speaker, so there is no voice mark and no "recognized" state anywhere: a speaker has a name
  only when the user gave it (typed it or answered Yes to a suggestion), and every name is read as written.
- A suggestion ("Is this Ana?") is not shown as a name: the speaker still reads "Speaker 2". Under the speaker in Who spoke it is a text question with **Yes** and
  **No** link buttons whose spoken labels name the person ("Yes, it’s Ana", "No, not Ana"); the same question and two rows
  are at the top of the speaker popover. For the user's own saved voice (imported recordings only) the question is "Is this you?" and the labels are "Yes, that’s me" and "No, not me". A No is undoable from the Edit menu (“Undo Reject Voice Suggestion”).
- The consent sheet of **Remember This Voice** is a sheet with its title as header, the explanation as plain text lines with
  decorative icons hidden, the checkbox read as “<name> agreed to this.”, and the **Remember This Voice** button dimmed until the box is
  checked (Return only works then; Escape cancels). It has no timer and nothing moves.
- A person's card says "Voice saved on this Mac" with a **Delete** link whose spoken label is “Delete saved voice”.
- A person's card says "Spoke in N meetings" as one text element; the Meetings section lists those meetings with the role
  "Spoke" (or "Attended" for a calendar attendee who did not speak), and a mention quote begins with the line's speaker label.

## Recording panel: capture alert

A meeting app holds the microphone but nothing reaches Others for 60 seconds: a notice with a warning icon (hidden from
VoiceOver), a title and what to check, **Open Sound Settings** and **Dismiss**. It is also announced once with the same
words when it appears (not when a channel warning already explains why Others is silent, as the panel then hides the notice), because VoiceOver is usually on another window during a call. The state is never colour-only: the
words carry it. Its manual VoiceOver pass is in the checklist below.

## Live answers (the Answers card in the panel, Settings, the meeting's Detected questions)

- An answer appears without moving the keyboard focus and without a sound. VoiceOver is told "Answer available" once, with low priority, and nothing else: the answer text is not read out, because VoiceOver can be heard by others through the speakers. Each row is a labelled group: an answer reads "Answer: …" followed by every place it was verified in ("From this meeting", "From a past meeting: <title>, <date>", "From a document: <file name>"); while an answer is being found, the spinner next to the card's title is a button named "Stop" whose value is "Finding an answer…" (there is no row for it, so the open answer does not move); a folded row reads the question as it is on screen and where its answer was verified (never the answer, so moving through the rows does not speak earlier answers), and its hint says it shows the answer; only the open row reads the answer.
- The source of an answer is always said in words (From this meeting, From a past meeting with its title and date, From a document with its file name) and drawn with its own glyph (a clock, a clock with an arrow, a page), so colour is never the only signal; the green seal is a glyph too. A late answer keeps its "Asked by …" line and adds a "Late answer" line in the text colour with a clock glyph. Citation chips are buttons with the same hints as Ask's ("Opens the transcript at this moment", "Opens the document at this passage").
- Keep, Copy and Open in Ask are icon buttons with an accessibility label and a tooltip, and Dismiss is a cross in the header of the open row, all in the keyboard order of the panel (icons, because a row of four words did not fit in every language). Keep says its state with the pin (filled and tinted when kept), the "selected" trait and the value "Kept". Escape dismisses an open row while it has the keyboard focus; Command-C copies the answer only while that row has the focus (it is the row's copy command, not a shortcut of the window), so Command-C in the quick note or on selected text works as everywhere else. Copy shows "Copied"; when "Protect meeting text from copying" is on (off by default on a new install, on for one upgraded from 0.1) Copy is dimmed and its tooltip and VoiceOver hint say why, and nothing stays on the card. A new answer never scrolls the panel (it could hide Mark a Moment or the quick note) and takes room from the live notes, not from the pinned tools: the Answers card is the first card of the scrolling part, so on arrival it is in view unless the person has scrolled down. A new answer does not close the row the person opened to read: it waits folded at the top unless nothing, or the newest row, was open. There is no shortcut to reach an answer when the panel is not the key window (the design's optional "Show latest answer" hot key is not built). The card animates only with Reduce Motion off (a fade otherwise). The first-run hint is the first row of the card; it counts as seen only after it was on screen (or answered), so a recording in which it never reached the screen shows it again at the next one. The pause lines and the Detected questions section of a meeting (with a line under its heading saying they were heard during the recording) are plain text and buttons.
- With Apple's on-device model Settings → Recording → Live answers has no switches: it is a plain text line ("Live answers need the integrated model or a model server.", secondary colour, no warning colour or symbol) and a **Show Models Pane** button, in the keyboard order of the form; the panel and the meeting window show no live-answer UI that cannot work.
- **Manual pass still to record** (not done in this session): VoiceOver on each state of the card, the new Settings line, keyboard-only use of the card in the panel (the panel is a window that is not made key when an answer appears, so reaching it with Tab depends on it already being key), Increase Contrast and Reduce Motion with a real recording.

## The pre-meeting brief (panel card, recording row, Upcoming, Brief tab, Settings)

- Each section is a heading, so the VoiceOver rotor moves between sections. Each line is one element that reads what it is, its date, owner and marks, then the text ("Decision, 12 September: Keep the C-shaped shell"); the line's action is named by where it opens ("Show in transcript", "Show passage", "Open in Reminders").
- Overdue, Due before this meeting, Unconfirmed and "from the minutes" are a glyph plus a word, never colour alone. The same marks sit under the lines of the panel card, in the Brief tab of a recorded meeting (read again from the minutes) and on an agenda line that rests on an unconfirmed item. A task of the user's whose owner is not confirmed is read "You, owner not confirmed" and is listed with the others, not under "You".
- "Vauta will ask to record when it starts" (after Record at Start) is a line on the card with a Cancel button; the two upcoming meetings are two buttons (time and title, the chosen one has the selected trait and a filled marker); the Reminders line has a Dismiss button.
- VoiceOver is told only "Brief ready for <time>", once per meeting, when it is built; it never reads the content unprompted. The recording row is collapsed by default, never expands by itself and closes with Escape.
- The panel card's **Open Brief** button comes first in the card's keyboard order; Return keeps starting the recording (the record button owns it), so Open Brief is not the default button. Show all, Refresh, Open in Calendar and Copy Agenda are ordinary buttons. Nothing animates when Reduce Motion is on.
- A locked card says "Unlock to see the brief" and holds no brief text. Long and CJK titles truncate in the middle with the full title in the accessibility label (checked in the `panel-brief-long-names` scene in ja, ko and zh-Hans).
- **Manual VoiceOver pass still to record** (not done): the card, the row, Upcoming and the Brief tab with VoiceOver and keyboard only, and Increase Contrast on the panel scenes.

## The search model (Settings → Models, Ask, search)

- The card is one row whose second line says the state in words (never by colour alone: the state is always given in words; Ready has a check, a failure an x, an unsupported Mac a dash and a download paused for a recording a pause symbol). A progress bar
  reads "312 of 574 megabytes, about 1 minute left" as its value (a paused download adds "paused"), rounded to 10 MB so VoiceOver is not interrupted by every update; a
  VoiceOver announcement is posted when the model is ready, when a download fails (with the reason) and when indexing is complete.
- Every action (Download, Import from a File…, Cancel, Resume, Discard, Try Again, Delete…, About This Model…) is a button reachable with the
  keyboard. In the delete confirmation Escape cancels. The indexing bar reads its percentage.
- The label under the Ask question ("Search by meaning", "Keyword search · indexing 42%", "Keyword search") is a button; its accessibility label is the
  text with the percentage and its hint says it opens Settings. The one-line offer in Ask's empty state can be dismissed with a labelled button.
- The sidebar's "By meaning" group is a section like the others; its rows read the meeting, the moment and the passage and say they open the meeting.
- There is no animated shimmer; progress bars follow the system's Reduce Motion setting.

## Find in Meeting (the Transcript tab)

Status: designed and unit-tested; the VoiceOver and Full Keyboard Access pass is still to be recorded.

- ⌘F (Edit → **Find in Meeting**) opens the bar and puts the keyboard focus in its field; with no meeting shown the same item reads
  **Search Meetings** and moves the focus to the sidebar's search field, which ⌥⌘F always does.
- The field is labelled "Find in Meeting". Return, ⌘G and ⇧⌘G go to the next and previous place; the previous and next buttons are
  labelled and have tooltips, and the speaker menu reads the speaker it is limited to ("Everyone" by default), with its tooltip as the hint.
- The count ("3 of 12", "No Results") is text next to the field; each move posts it as a VoiceOver announcement, because the focus stays
  in the field (or the transcript) while the transcript scrolls. The chosen place's line becomes the highlighted passage, so it reads
  as selected and **Speaker Options for Highlighted Passage** works on it.
- Not by colour alone: every place is bold, the chosen one has a solid marker with dark text in both appearances, and its line has the
  bar of the highlighted passage. Scrolling to it follows Reduce Motion.
- Escape in the bar closes it (only there: the window keeps Escape for everything else); **Done** closes it too, and so does leaving the
  Transcript tab or the meeting.

## Manual VoiceOver pass for the speaker screens and the panel (to record)

Turn VoiceOver on (⌘F5), open a meeting with speakers and go through each item; write the date, macOS version and
anything that read wrongly under the heading it belongs to.

- Transcript: a line reads "name, role, time: text"; the rotor's actions list "Speaker options" on a line with a stored
  speaker and not on an older meeting's line; the switch reads "Don’t separate speakers in this meeting" with its state
  and the note under it.
- Speaker popover: reaching each page with Tab, Escape going back, the name field's label and the warning for a shared name.
- Who spoke: each row opens the popover; the share is read with the name.
- Panel, capture alert (record a call in a meeting app, then mute that app's sound for just over a minute): the alert is
  spoken when it appears ("<app> is in a call, but Vauta hears nothing from it. <what to check>"); in the panel, the title
  and the detail are read as the two lines of one notice (note if they read as one element or two), followed by the
  buttons **Open Sound Settings** and **Dismiss**, each with a spoken label equal to its title; **Dismiss** removes the
  card and the menu-bar icon stops saying "Needs attention". With the recorded source set to another app, the card is the
  silence banner ("No audio is coming from <app>") with **Stop and Save** instead.
- Panel: voice chips (selected state and hint), calendar suggestions, "Speakers updated" with its two buttons, the hint
  under the live transcript.
- Captions with two or more voices: one element per caption with the name first.
- Settings → Speakers (the switches, the saved voices, the reminder, Delete and Delete All), the consent sheet (checkbox, dimmed
  button), the “Is this …?” question (“Is this you?” with “Yes, that’s me” / “No, not me” for the user's own voice) in Who spoke and in the popover, and a person's card (count,
  meetings, mentions and “Voice saved on this Mac · Delete”).

## After a meeting: reminders, events and email (Tasks tab, Follow-up sheet, editors, panel card)

- **Follow Up…** is in the File menu (⇧⌘U), the toolbar and the Meetings window; the editors, the sheet and every action are ordinary buttons with
  their own titles. Escape cancels an editor, Return is its default button (Add), and the first field takes the keyboard. Add to Reminders… is also a
  button in the **Reminders** row of the task editor, with an actions menu, so nothing needs the context menu or a mouse.
- The sheet's sections (Reminders, Calendar, Email draft) are headings, so the VoiceOver rotor moves between them. A task row is one element that
  reads the task, then "Owner Ana. Due Friday 16 October", with the checkbox state; a task that has a reminder reads "In Reminders, list Work".
- The status of a reminder, a calendar event, a different due day, a missing reminder and an external recipient are always a symbol plus words, never colour alone.
- The Undo bar does not take the keyboard focus. VoiceOver hears "Added to Reminders · Work. Undo available." once, and with VoiceOver on the bar has
  no time-out (it stays until dismissed or replaced). Edit › Undo does the same. Reduce Motion: the bar fades instead of sliding.
- The email preview is one labelled group; each address is a checkbox ("Ana Lopez, ana@example.org, External"), none ticked.
- Long names and CJK titles truncate in the middle; the full text is in the element's label.
- The panel card is a labelled group ("Follow-up") with **Review…** (or **Unlock to Review**) and a Dismiss button; it takes no focus when it appears.
- Contrast follows the system colours in light, dark and Increase Contrast.

## Link suggestions

Each row says "Suggestion" first, then the question, the earlier item and, for a change, "Earlier: … Now: …"; the difference is bold and spoken, never bold alone. The earlier item's "Unconfirmed" mark is spoken. Buttons are ordinary focusable buttons with no new shortcut; Undo Link is in the row's menu and also an action of the confirmed row for VoiceOver and the keyboard, and Edit > Undo follows each answer. The question is read once (the row's label), the Restore buttons of the dismissed list and the "N suggestions" link carry the item or the meeting as their hint, and the brief's spoken row says the text of the older decision a confirmed change replaces. The chain mark in Tasks mode is a disclosure with symbol and text.
