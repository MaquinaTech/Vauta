// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import AppKit
import PDFKit
import SwiftUI

/// The user's shorthand notes: the Notes card of the menu-bar panel, the floating notepad and the Notes tab of the
/// Meetings window, in every state. The bullets are the sample content's own short phrases in each language; what the
/// model "wrote" is the sample transcript's lines, cited with their moments.
extension SnapshotScenes {
    // MARK: In-memory rows (panel and notepad)

    /// The notes of the sample recording: the user's words and, for some, an expansion citing the sample transcript.
    @MainActor
    struct NotepadSample {
        let fixture: SnapshotFixture
        let segments: [Segment]

        let words: SnapshotNoteWriting

        init(_ fixture: SnapshotFixture) {
            self.fixture = fixture
            words = .forLanguage(fixture.language)
            segments = fixture.content.liveSegments + (fixture.content.liveVolatileSegment.map { [$0] } ?? [])
        }

        var bullets: [String] {
            let c = fixture.content
            return [c.livePoints.first, c.liveTasks.first, c.notes.first, c.notes.dropFirst().first, c.liveDecisions.first]
                .compactMap { $0 }
        }

        /// A sentence of the model written by hand (see `SnapshotNoteWriting`) that cites the transcript line `i` (the id of its
        /// segment is `100 + i`); the quote is cut from that line.
        func sentence(_ text: String, line i: Int, unconfirmed: Bool = false, differs: Bool = false) -> NoteExpansion.Sentence {
            let index = i % segments.count
            let segment = segments[index]
            return NoteExpansion.Sentence(text: text, cites: [.init(seg: Int64(100 + index), t: segment.start)],
                                          quote: String(segment.text.prefix(40)), unconfirmed: unconfirmed, differs: differs)
        }

        var beta: NoteExpansion.Sentence { sentence(words.panelBeta, line: 0) }
        var releaseNotes: NoteExpansion.Sentence { sentence(words.panelNotes, line: 1) }
        var unconfirmed: NoteExpansion.Sentence { sentence(words.tabUnconfirmed, line: 0, unconfirmed: true) }
        var differs: NoteExpansion.Sentence { sentence(words.panelDiffers, line: 1, differs: true) }
        /// The user's own rewrite: no citation, nothing was checked against the transcript.
        var rewritten: NoteExpansion.Sentence { NoteExpansion.Sentence(text: words.tabEdited) }

        var citedSegments: Set<Int64> { Set((0..<segments.count).map { Int64(100 + $0) }) }

        func note(_ id: Int64, _ text: String, t: Double) -> MeetingNote { MeetingNote(id: id, meetingID: 1, t: t, text: text) }

        func row(_ id: Int64, _ text: String, t: Double, state: NoteExpansion.State? = nil, sentences: [NoteExpansion.Sentence] = [],
                 pass: NoteExpansion.Pass = .closing, edited: Bool = false, code: String? = nil, changed: Bool = false) -> NoteRow {
            let n = note(id, text, t: t)
            guard let state else { return NoteRow(note: n, expansion: nil) }
            let key = TextKeys.norm(changed ? text + " (old)" : text)
            return NoteRow(note: n, expansion: NoteExpansion(noteID: id, meetingID: 1, state: state, pass: pass, sentences: sentences,
                                                             sourceKey: key, userEdited: edited, errorCode: code))
        }
    }

    @MainActor
    static func notesPanelScene(_ name: String, maxHeight: CGFloat? = airPanelHeight, focusing: ((RecorderModel) -> String)? = nil,
                                configure: @escaping @MainActor (RecorderModel, NotepadSample) -> Void) -> SnapshotScene {
        SnapshotScene(name: "panel-notes-\(name)", size: panelSize, fitHeight: true, isPanel: true) { fixture in
            let recorder = await fixture.makeRecorder()
            recording(recorder, fixture)
            recorder.notepad.live = true   // as `prepareNotepad` sets it: the notes wait for more of the meeting
            recorder.livePoints = fixture.content.livePoints
            let sample = NotepadSample(fixture)
            recorder.notepad.existingSegments = sample.citedSegments
            configure(recorder, sample)
            let view = RecorderPanel(model: recorder)
                .environment(\.panelMaxHeight, maxHeight)
                .background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view), after: {
                guard let focusing else { return }
                focusNotesField(containing: focusing(recorder))
            })
        }
    }

    private static func focusNotesField(containing text: String) {
        func find(in view: NSView) -> NoCopyTextView? {
            if let field = view as? NoCopyTextView, field.string == text { return field }
            for sub in view.subviews { if let found = find(in: sub) { return found } }
            return nil
        }
        for window in NSApp.windows {
            if let root = window.contentView, let field = find(in: root) {
                window.makeFirstResponder(field)
                return
            }
        }
    }

    /// A mix of states, the way a meeting looks a while in.
    @MainActor
    static func mixedRows(_ s: NotepadSample) -> [NoteRow] {
        let b = s.bullets
        return [
            s.row(1, b[0], t: 58, state: .done, sentences: [s.beta, s.unconfirmed], pass: .live),
            s.row(2, b[1], t: 140, state: .done, sentences: [s.releaseNotes], pass: .live),
            s.row(3, b[2], t: 205, state: .notFound),
            s.row(4, b[3], t: 270, state: .done, sentences: [s.differs], pass: .live),
            s.row(5, b[4], t: 330, state: .done, sentences: [s.rewritten], pass: .live, edited: true),
        ]
    }

    static var notesPanel: [SnapshotScene] {
        [
            notesPanelScene("empty") { _, _ in },
            // Typing: the field has the keyboard, the text is not saved until Return.
            notesPanelScene("typing", focusing: { $0.notepad.draft }) { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .done, sentences: [s.beta], pass: .live)]
                recorder.notepad.draft = s.bullets[1]
            },
            // Saved a moment ago: the speaker has not finished the point yet.
            notesPanelScene("waiting") { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58), s.row(2, s.bullets[1], t: 140)]
            },
            notesPanelScene("expanding") { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .done, sentences: [s.beta], pass: .live), s.row(2, s.bullets[1], t: 140)]
                recorder.notepad.working = [2]
            },
            // Two notes so the opened one is in view (the panel list shows the newest whole notes).
            notesPanelScene("expanded") { recorder, s in
                recorder.notepad.rows = Array(mixedRows(s).prefix(2))
                recorder.notepad.disclosed = [1]
            },
            // Twelve notes: the list scrolls inside its card and the newest stays in view.
            notesPanelScene("many") { recorder, s in
                // Each expansion is the sentence written for its own bullet; the other bullets are still waiting.
                recorder.notepad.rows = (0..<12).map { i in
                    let id = Int64(i + 1)
                    let k = i % s.bullets.count
                    let text = s.bullets[k]
                    let sentence: NoteExpansion.Sentence? = k == 0 ? s.beta : (k == 1 ? s.releaseNotes : nil)
                    guard let sentence, i < 9 else { return s.row(id, text, t: Double(40 + i * 30)) }
                    return s.row(id, text, t: Double(40 + i * 30), state: .done, sentences: [sentence], pass: .live)
                }
            },
            // Marks stay in the list with the notes, by time: the orange bookmark and its moment.
            notesPanelScene("marks") { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .done, sentences: [s.beta], pass: .live), s.row(2, s.bullets[1], t: 140)]
                recorder.marks = [MeetingMark(id: 1, meetingID: 1, t: 95), MeetingMark(id: 2, meetingID: 1, t: 190)]
            },
            // A sentence the transcript does not back: the word and the glyph, never the glyph alone.
            notesPanelScene("unconfirmed") { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .done, sentences: [s.unconfirmed, s.beta], pass: .live)]
                recorder.notepad.disclosed = [1]
            },
            // Another app holds the shortcut: the hint says so under the title, as for Mark a Moment.
            notesPanelScene("hotkey-conflict") { recorder, s in
                recorder.noteHotKeyAvailable = false
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .done, sentences: [s.beta], pass: .live)]
            },
            notesPanelScene("no-model") { recorder, s in
                recorder.llmStatus.configured = false
                recorder.notepad.modelConfigured = false
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58), s.row(2, s.bullets[1], t: 140)]
            },
            notesPanelScene("not-answering") { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .pending, code: JobErrorCode.network.rawValue),
                                         s.row(2, s.bullets[1], t: 140, state: .done, sentences: [s.releaseNotes], pass: .live)]
            },
            notesPanelScene("language") { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .pending, code: JobErrorCode.unsupportedLanguage.rawValue)]
            },
            notesPanelScene("undo-delete") { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .done, sentences: [s.beta], pass: .live), s.row(3, s.bullets[2], t: 205)]
                recorder.notepad.deleted = [NotepadModel.Deleted(row: s.row(2, s.bullets[1], t: 140))]
            },
            notesPanelScene("editing", focusing: { $0.notepad.draft }) { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58), s.row(2, s.bullets[1], t: 140)]
                recorder.notepad.editingID = 2
                recorder.notepad.draft = s.bullets[1]
            },
            // A short screen: the room is given up in order (the transcript, then who "Others" is moves to its own card).
            notesPanelScene("short", maxHeight: 560) { recorder, s in
                recorder.notepad.rows = mixedRows(s)
                recorder.marks = [MeetingMark(id: 1, meetingID: 1, t: 95)]
                recorder.segments = recorder.segments.isEmpty ? s.segments.enumerated().map { LiveSegment(id: $0.offset, segment: $0.element) } : recorder.segments
            },
        ]
    }

    // MARK: The floating notepad

    @MainActor
    static func notepadScene(_ name: String, height: CGFloat = 420, configure: @escaping @MainActor (RecorderModel, NotepadSample) -> Void) -> SnapshotScene {
        SnapshotScene(name: "notepad-\(name)", size: CGSize(width: NotepadPanelController.defaultSize.width, height: height)) { fixture in
            let recorder = await fixture.makeRecorder()
            recording(recorder, fixture)
            recorder.notepad.live = true
            let sample = NotepadSample(fixture)
            recorder.notepad.existingSegments = sample.citedSegments
            configure(recorder, sample)
            // The real window is fixed to its own size (see `NotepadPanelController`): so is the scene.
            let view = NotepadWindowView(model: recorder, close: {})
                .frame(width: NotepadPanelController.defaultSize.width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view), title: String(localized: "Notepad", comment: "Window title of the floating notepad where the user types short notes during a recording (read by VoiceOver)"))
        }
    }

    static var notepadWindow: [SnapshotScene] {
        [
            notepadScene("empty", height: 220) { _, _ in },
            notepadScene("live") { recorder, s in
                recorder.notepad.rows = mixedRows(s)
                recorder.marks = [MeetingMark(id: 1, meetingID: 1, t: 100)]
                recorder.notepad.working = [2]
                recorder.notepad.disclosed = [1]
            },
            // A bullet that runs to three lines (the longest sample phrase, repeated): shown whole, then cut with a tooltip.
            notepadScene("long-text") { recorder, s in
                let long = (s.bullets.suffix(2) + [s.bullets[0]]).joined(separator: " ")
                recorder.notepad.rows = [s.row(1, long + " " + long, t: 58, state: .done, sentences: [s.beta], pass: .live), s.row(2, s.bullets[1], t: 140)]
            },
            // The recording ended: the notes stay, with where to keep adding them.
            notepadScene("stopped-footer", height: NotepadPanelController.defaultSize.height) { recorder, s in
                recorder.notepad.rows = mixedRows(s)
                recorder.phase = .idle
                recorder.notepad.live = false
                recorder.notepadSavedMeeting = 1
            },
            // Just after the stop, the minutes job is on its way: the notes say they are being expanded.
            notepadScene("stopped-expanding", height: NotepadPanelController.defaultSize.height) { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58), s.row(2, s.bullets[1], t: 140, state: .pending, code: JobErrorCode.network.rawValue),
                                         s.row(3, s.bullets[2], t: 205, state: .done, sentences: [s.releaseNotes], pass: .live)]
                recorder.phase = .idle
                recorder.notepad.live = false
                recorder.notepad.finalPassComing = { true }
                recorder.notepadSavedMeeting = 1
            },
            // Nothing is on its way and the server did not answer: said as it is, with the reason and the way to try again.
            notepadScene("stopped-failed", height: NotepadPanelController.defaultSize.height) { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .pending, code: JobErrorCode.network.rawValue),
                                         s.row(2, s.bullets[1], t: 140, state: .failed, code: JobErrorCode.invalidResponse.rawValue),
                                         s.row(3, s.bullets[2], t: 205)]
                recorder.phase = .idle
                recorder.notepad.live = false
                recorder.notepadSavedMeeting = 1
            },
            notepadScene("unsupported-language") { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .pending, code: JobErrorCode.unsupportedLanguage.rawValue),
                                         s.row(2, s.bullets[1], t: 140, state: .pending, code: JobErrorCode.unsupportedLanguage.rawValue)]
            },
            notepadScene("undo-delete", height: 300) { recorder, s in
                recorder.notepad.rows = [s.row(1, s.bullets[0], t: 58, state: .done, sentences: [s.beta], pass: .live), s.row(3, s.bullets[2], t: 205)]
                recorder.notepad.deleted = [NotepadModel.Deleted(row: s.row(2, s.bullets[1], t: 140))]
            },
        ]
    }

    // MARK: The Notes tab (saved meeting)

    /// What the Notes tab scenes seed into the sample store.
    enum NotesTabKind { case full, stale, notFound, failed, empty, purged, updated }

    /// Replaces the featured meeting's notes with the sample bullets (and their expansions, as the kind says). Returns the note IDs.
    @MainActor
    @discardableResult
    static func seedNotesTab(_ fixture: SnapshotFixture, _ kind: NotesTabKind) async -> [Int64] {
        let store = fixture.world.store
        let id = fixture.world.featuredMeetingID
        for note in (try? await store.notes(id)) ?? [] { try? await store.updateNote(note.id, text: "") }
        guard kind != .empty else { return [] }
        let segs = (try? await store.segments(of: id)) ?? []
        guard !segs.isEmpty else { return [] }
        let sample = NotepadSample(fixture)
        let b = sample.bullets
        let w = sample.words
        func sentence(_ text: String, line i: Int, unconfirmed: Bool = false, differs: Bool = false) -> NoteExpansion.Sentence {
            let s = segs[i % segs.count]
            // A purged transcript keeps the time and loses the passage to open.
            let seg = kind == .purged ? s.id + 1_000_000 : s.id
            return NoteExpansion.Sentence(text: text, cites: [.init(seg: seg, t: s.start)], quote: String(s.text.prefix(40)),
                                          unconfirmed: unconfirmed, differs: differs)
        }
        func add(_ text: String, _ i: Int, _ lag: Double) async -> Int64 {
            (try? await store.addNote(id, at: segs[i % segs.count].start + lag, text: text)) ?? 0
        }
        func save(_ note: Int64, _ text: String, _ outcome: MeetingStore.ExpansionOutcome, pass: NoteExpansion.Pass = .closing) async {
            _ = try? await store.saveExpansion(noteID: note, pass: pass, outcome: outcome, sourceKey: TextKeys.norm(text))
        }
        let a = await add(b[0], 1, 14), c = await add(b[1], 5, 10), d = await add(b[2], 6, 12), e = await add(b[3], 7, 8), f = await add(b[4], 4, 20)
        switch kind {
        case .notFound:
            for (n, t) in [(a, b[0]), (c, b[1]), (d, b[2])] { await save(n, t, .sentences([])) }
        case .failed:
            await save(a, b[0], .failed(code: JobErrorCode.invalidResponse.rawValue))
            await save(c, b[1], .retry(code: JobErrorCode.network.rawValue))
            await save(d, b[2], .failed(code: JobErrorCode.server.rawValue))
        default:
            await save(a, b[0], .sentences([sentence(w.tabBeta, line: 1), sentence(w.tabUnconfirmed, line: 1, unconfirmed: true)]))
            await save(c, b[1], .sentences([sentence(w.tabNotes, line: 5)]))
            await save(d, b[2], .sentences([]))
            await save(e, b[3], .sentences([sentence(w.tabDiffers, line: 5, differs: true)]))
            await save(f, b[4], .sentences([sentence(w.tabDecision, line: 4)]))
            if kind == .full { try? await store.editExpansion(noteID: f, text: w.tabEdited) }
            if kind == .updated {
                // A later pass wrote the first note again: the version before is one click away.
                await save(a, b[0], .sentences([sentence(w.tabBeta, line: 1), sentence(w.tabBetaMore, line: 1)]))
            }
            if kind == .stale { try? await store.updateNote(a, text: b[0] + " +10%") }
        }
        return [a, c, d, e, f]
    }

    @MainActor
    static func notesTabScene(_ name: String, _ kind: NotesTabKind,
                              apply: @escaping @MainActor (MeetingsModel, SnapshotFixture, [Int64]) async -> Void = { _, _, _ in },
                              configureRecorder: @escaping @MainActor (RecorderModel) -> Void = { _ in }) -> SnapshotScene {
        SnapshotScene(name: "meetings-notes-\(name)", size: meetingsSize) { fixture in
            let recorder = await fixture.makeRecorder()
            configureRecorder(recorder)
            guard let history = recorder.history else { return .init(view: AnyView(EmptyView())) }
            history.llm = nil
            try? await fixture.world.restoreTranscript()
            let ids = await seedNotesTab(fixture, kind)
            await history.reload()
            history.selectedID = fixture.world.featuredMeetingID
            await history.loadDetail()
            history.tab = .notes
            let view = MeetingsWindow(model: history, recorder: recorder, preferences: fixture.preferences, settings: fixture.settings)
            return .init(view: AnyView(view), title: String(localized: "Meetings", comment: "Window title"), after: {
                history.tab = .notes
                await apply(history, fixture, ids)
            })
        }
    }

    static var notesTab: [SnapshotScene] {
        [
            // Done, unconfirmed, "the transcript says", edited by the user, not found, and one still waiting.
            notesTabScene("full", .full),
            notesTabScene("stale", .stale),
            notesTabScene("not-found", .notFound),
            notesTabScene("failed", .failed),
            // The minutes job is queued: the notes the server did not answer for wait for its final pass.
            notesTabScene("expanding", .failed) { history, _, _ in
                history.notepad.finalPassComing = { true }
            },
            notesTabScene("empty", .empty),
            notesTabScene("empty-no-model", .empty, configureRecorder: { $0.llmStatus.configured = false }),
            notesTabScene("with-no-model", .full, configureRecorder: { $0.llmStatus.configured = false }),
            // The meeting has no transcript to expand notes from.
            notesTabScene("no-transcript", .notFound) { history, _, _ in
                history.notepad.hasTranscript = false
                history.notepad.rows = history.notepad.rows.map { NoteRow(note: $0.note, expansion: nil) }
            },
            // The meeting is being recorded: its notes are shown here, and typed in the panel or the notepad.
            notesTabScene("recording", .full) { history, fixture, _ in
                // It began a few minutes ago (today's time in the sidebar); the tasks come with the minutes, at the end.
                try? await fixture.world.startFeaturedMeeting(minutesAgo: 6)
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.tab = .notes
                history.tasks = []
                history.activeMeetingID = fixture.world.featuredMeetingID
            },
            // Retention removed the transcript: the chips keep their times and have nothing to open.
            notesTabScene("purged", .purged),
            // The note being edited in place, and its expansion being rewritten.
            notesTabScene("edit-note", .full) { history, _, ids in
                guard let first = history.notepad.rows.first else { return }
                history.notepad.wordsDraft = first.note.text
                history.notepad.editingWordsID = first.id
            },
            notesTabScene("edit-expansion", .full) { history, _, _ in
                guard let first = history.notepad.rows.first else { return }
                history.notepad.expansionDraft = NoteExpansionText.joined(first.visibleSentences)
                history.notepad.editingExpansionID = first.id
            },
            notesTabScene("updated-undo", .updated) { history, _, ids in
                if let first = ids.first { history.notepad.updated = [first] }
            },
            // A search result opened the meeting on this tab with its note in view.
            notesTabScene("from-search", .full) { history, _, ids in
                history.highlightedNote = ids.dropFirst().first
            },
            notesTabScene("deleted", .full) { history, _, _ in
                if let row = history.notepad.rows.last {
                    history.notepad.rows.removeAll { $0.id == row.id }
                    history.notepad.deleted = [NotepadModel.Deleted(row: row)]
                }
            },
        ]
    }

    // MARK: Minutes tab and Settings

    static var notepadMore: [SnapshotScene] {
        let take = String(localized: "Take a note", comment: "Shortcut name: opens the floating notepad to type a short note during a recording")
        return [
            // The Minutes tab shows the marks and a line that leads to the notes (shown once, in their own tab).
            meetingsAfterScene("summary-marks-notes-link", size: CGSize(width: meetingsSize.width, height: 1500), prepare: { history, fixture in
                await seedNotesTab(fixture, .full)
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            }) { history, _ in
                history.tab = .summary
            },
            // A search that matches the model's text under a note: the result says it is the expanded note.
            meetingsAfterScene("search-expanded-note", prepare: { history, fixture in
                await seedNotesTab(fixture, .full)
                await history.reload()
            }) { history, fixture in
                let segs = (try? await fixture.world.store.segments(of: fixture.world.featuredMeetingID)) ?? []
                let word = (segs.dropFirst().first?.text ?? "").split(whereSeparator: \.isWhitespace).max { $0.count < $1.count }.map(String.init) ?? ""
                history.query = String(word.prefix(6))
                try? await Task.sleep(for: .milliseconds(900))
            },
            exportScene("export-markdown-notes") { export, options, _ in
                AnyView(ScrollView { Text(verbatim: MeetingExportRenderer.markdown(export, options: options))
                    .font(.system(.callout, design: .monospaced)).textSelection(.disabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16) })
            },
            exportScene("export-pdf-notes") { export, options, size in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-notes-\(UUID().uuidString).pdf")
                defer { try? FileManager.default.removeItem(at: url) }
                try? MinutesPDFRenderer.write(export, options: options, to: url)
                guard let page = PDFDocument(url: url)?.page(at: 0) else { return AnyView(EmptyView()) }
                return AnyView(Image(nsImage: page.thumbnail(of: size, for: .mediaBox)).resizable().scaledToFit().padding(8))
            },
            settingsScene("general-notepad-shortcut", .general),
            settingsScene("general-notepad-shortcut-listening", .general, hotKeys: [take: SnapshotHotKeyState(listening: true)]),
            settingsScene("general-notepad-shortcut-refused", .general,
                          hotKeys: [take: SnapshotHotKeyState(listening: true, problem: HotKeyRules.Issue.inUseByAnotherApp.message)]),
        ]
    }

    /// How the notes read in an exported file: the minutes of the featured meeting rendered as the exporter writes them.
    @MainActor
    static func exportScene(_ name: String, _ make: @escaping @MainActor (MeetingExport, MeetingExportOptions, CGSize) -> AnyView) -> SnapshotScene {
        let size = CGSize(width: 760, height: 620)
        return SnapshotScene(name: name, size: size) { fixture in
            try? await fixture.world.restoreTranscript()
            await seedNotesTab(fixture, .full)
            let options = MeetingExportOptions(includeTranscript: false, locale: fixture.world.locale)
            guard let export = try? await fixture.world.store.meetingExport(fixture.world.featuredMeetingID) else { return .init(view: AnyView(EmptyView())) }
            return .init(view: AnyView(make(export, options, size).background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    static var notepadScenes: [SnapshotScene] { notesPanel + notepadWindow + notesTab + notepadMore }
}
#endif
