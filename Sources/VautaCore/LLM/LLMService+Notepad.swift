// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    /// The citable segments that start in `[from, to]` (to nil = until now), by time.
    func citableSegments(_ meetingID: Int64, from: Double, to: Double?) throws -> [CitableSegment] {
        try db.query("""
            SELECT s.id, s.speaker, s.start, s.text, \(Self.speakerColumns) FROM segments s \(Self.speakerJoins)
            WHERE s.meeting_id = ?1 AND s.start >= ?2 AND (?3 IS NULL OR s.start <= ?3) AND \(Self.notEcho) ORDER BY s.start, s.id
            """, [.integer(meetingID), .real(from), to.map { .real($0) }]).map(Self.citable)
    }
}

/// The user's shorthand notes, written out from the transcript.
///
/// One note per request on a small context window (the on-device model's ~4K); a large window takes a few consecutive
/// notes per request in the final pass. The model only ever sees the transcript around the note (or, for a note typed
/// after the meeting, the passages the in-meeting search finds) and the two notes before it as context. What it
/// writes goes through `NoteExpansionVerifier` and lands in `note_expansions`: this extension never writes `notes`.
extension LLMService {
    /// Everything a pass needs, gathered once.
    struct NoteContext {
        let meetingID: Int64
        let chat: ChatProvider
        let budget: ContextBudget
        let language: OutputLanguage
        let entities: ChatMessage
        let candidates: [CandidateEntity]
        let selfEntity: Int64?
        let directory: SpeakerDirectory
        let role: LLMRole
        let notes: [MeetingNote]
        let locale: Locale
        /// The whole transcript by time (final and manual passes).
        var segments: [CitableSegment]?
    }

    /// Where the transcript for a group of notes comes from.
    enum NoteMaterial {
        /// Live: from `lookBack` seconds before the note until now.
        case recent
        /// The minutes before the note and the minute after.
        case around
        /// The meeting's own search (a note typed after the meeting, or nothing was found around the note).
        case retrieval
    }

    static let aroundBefore = 180.0
    static let aroundAfter = 60.0
    /// How far after the note the live window reaches.
    static let liveAfter = 120.0

    // MARK: Entry points

    /// While recording, with the fast model, behind the lane like the live notes. Returns the state it stored.
    /// A failure is stored (the note stays pending, with the error code) and thrown for the caller to show.
    @discardableResult
    public func expandNoteLive(meetingID: Int64, noteID: Int64) async throws -> NoteExpansion.State {
        let chat = try chatProvider()
        try await waitForRefinements()
        try await acquire(.live)
        defer { release() }
        return try await expandOne(meetingID: meetingID, noteID: noteID, pass: .live, role: .fast, chat: chat, replacingEdited: false)
    }

    /// For a note added or edited after the meeting, or "Expand Again": the user is waiting, so it goes before the
    /// background queue (which resumes afterwards), with the main model.
    @discardableResult
    public func expandNote(noteID: Int64, replacingEdited: Bool = false) async throws -> NoteExpansion.State {
        let chat = try chatProvider()
        guard let meetingID = try await store.meetingID(ofNote: noteID) else { return .dismissed }
        askWaiting += 1
        // The minutes of this very meeting are being written: they write the note out too (the final pass), so the job
        // is not cancelled and restarted for every note typed meanwhile; the note waits for its turn instead.
        let behindMinutes = currentJob.map { $0.meetingID == meetingID && $0.kind == .minutes } ?? false
        if !behindMinutes { backgroundTask?.cancel() }
        do {
            try await acquire(.ask)
        } catch {
            askWaiting -= 1
            kick()
            throw error
        }
        askWaiting -= 1
        defer {
            release()
            kick()
        }
        if behindMinutes, !replacingEdited, let note = try await store.notes(meetingID).first(where: { $0.id == noteID }),
           let done = try await store.expansion(of: noteID), done.state != .pending, done.state != .failed,
           done.sourceKey == TextKeys.norm(note.text) {
            return done.state   // the minutes job wrote it while this waited
        }
        // While recording, the speakers are provisional: the result is stored as a live one, which the final pass writes again
        // with the full context and the final speakers.
        return try await expandOne(meetingID: meetingID, noteID: noteID, pass: .manual, storeAs: recording ? .live : .manual,
                                   role: recording ? .fast : .deep, chat: chat, replacingEdited: replacingEdited)
    }

    private func expandOne(meetingID: Int64, noteID: Int64, pass: NoteExpansion.Pass, storeAs: NoteExpansion.Pass? = nil, role: LLMRole,
                           chat: ChatProvider, replacingEdited: Bool) async throws -> NoteExpansion.State {
        let stored = storeAs ?? pass
        guard let note = try await store.notes(meetingID).first(where: { $0.id == noteID }) else { return .dismissed }
        let activity = beginNoteActivity(meetingID)
        defer { endNoteActivity(activity) }
        do {
            let ctx = try await noteContext(meetingID, chat: chat, role: role)
            let results = try await outcomes(for: [note], pass: pass, ctx: ctx)
            try Task.checkCancellation()
            if let failure = results[0].error { throw failure }
            try await store.saveExpansion(noteID: note.id, pass: stored, outcome: .sentences(results[0].sentences),
                                          sourceKey: TextKeys.norm(note.text), uptoSegment: results[0].upto,
                                          replacingEdited: replacingEdited)
        } catch let error where !(error is CancellationError) {
            let code = JobErrorCode(error).rawValue
            _ = try? await store.saveExpansion(noteID: note.id, pass: stored, outcome: pass == .live ? .retry(code: code) : .failed(code: code),
                                           sourceKey: TextKeys.norm(note.text), replacingEdited: replacingEdited)
            throw error
        }
        return (try await store.expansion(of: noteID))?.state ?? .pending
    }

    /// Inside the minutes job, after the speakers are final and before the minutes are written, so the minutes always
    /// see final expansions. Redoes the live results; never touches a note the user edited or removed. A note that
    /// fails is stored as failed and the minutes go on; an error that would fail the minutes too (the server is busy
    /// or unreachable, the key is missing) stops here so the whole job is tried again later.
    func expandNotesForMinutes(_ meetingID: Int64, chat: ChatProvider) async throws {
        leftoverTried.insert(meetingID)   // this launch has had its try for this meeting's notes
        let todo = try await store.notesNeedingExpansion(meetingID, includingLive: true)
        guard !todo.isEmpty else { return }
        var ctx = try await noteContext(meetingID, chat: chat, role: .deep)
        ctx.segments = try await store.citableSegments(meetingID)
        let saved = (status.activity, status.activityStarted)
        status.activity = String(localized: "Expanding notes", comment: "Model server activity in the menu bar panel: the model writes the user’s short notes out in full")
        publish()
        defer { status.activity = saved.0; status.activityStarted = saved.1; publish() }
        for group in groups(of: todo, ctx: ctx) {
            try Task.checkCancellation()
            do {
                let results = try await outcomes(for: group, pass: .closing, ctx: ctx)
                try Task.checkCancellation()
                for (note, result) in zip(group, results) {
                    if let failure = result.error {
                        _ = try? await store.saveExpansion(noteID: note.id, pass: .closing, outcome: .failed(code: JobErrorCode(failure).rawValue),
                                                           sourceKey: TextKeys.norm(note.text))
                        continue
                    }
                    try await store.saveExpansion(noteID: note.id, pass: .closing, outcome: .sentences(result.sentences),
                                                  sourceKey: TextKeys.norm(note.text), uptoSegment: result.upto)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let llm = error as? LLMError, llm.isRetryable || llm.stopsWork { throw error }
                let code = JobErrorCode(error).rawValue
                for note in group {
                    _ = try? await store.saveExpansion(noteID: note.id, pass: .closing, outcome: .failed(code: code), sourceKey: TextKeys.norm(note.text))
                }
            }
        }
    }

    /// When the queue is empty: the notes of finished meetings that still have no expansion or a failed one (a model was
    /// not set up then, or the server was down in the final pass). Once per meeting and launch, behind the lane like
    /// any background job; a question or a recording interrupts it and it is picked up again afterwards.
    func expandLeftoverNotes() async {
        guard !recording, !externalBusy, !restoring, let chat = try? chatProvider() else { return }
        for id in ((try? await store.meetingsWithUnexpandedNotes()) ?? []) where !leftoverTried.contains(id) {
            guard !recording, !restoring else { return }
            do { try await acquire(.background) } catch { return }
            if askWaiting > 0 || recording { release(); return }
            leftoverTried.insert(id)
            let task = Task { try await self.expandNotesForMinutes(id, chat: chat) }
            backgroundTask = task
            let result = await task.result
            backgroundTask = nil
            release()
            if case .failure(let error) = result {
                if error is CancellationError { leftoverTried.remove(id) }
                if let llm = error as? LLMError, llm.stopsWork || llm.isRetryable {
                    leftoverTried.remove(id)
                    return
                }
            }
        }
    }

    // MARK: Context

    private func beginNoteActivity(_ meetingID: Int64) -> (String?, Int64?) {
        let saved = (status.activity, status.activityMeeting)
        status.activity = String(localized: "Expanding notes", comment: "Model server activity in the menu bar panel: the model writes the user’s short notes out in full")
        status.activityMeeting = meetingID
        publish()
        return saved
    }

    private func endNoteActivity(_ saved: (String?, Int64?)) {
        status.activity = saved.0
        status.activityMeeting = saved.1
        publish()
    }

    private func noteContext(_ meetingID: Int64, chat: ChatProvider, role: LLMRole) async throws -> NoteContext {
        guard let meeting = try await store.meeting(meetingID) else { throw CancellationError() }
        if let supports = chat.supports, !supports(meeting.minutesLocale) || !supports(meeting.transcriptionLocale) {
            throw LLMError.unsupportedLanguage
        }
        let budget = ContextBudget(contextTokens: chat.contextTokens)
        let candidates = try await store.candidateEntities(meetingID, limit: budget.liveEntityLimit)
        let me = try await store.selfEntity()
        return NoteContext(meetingID: meetingID, chat: chat, budget: budget, language: OutputLanguage(meeting: meeting),
                           entities: VautaPrompts.entitiesMessage(candidates, selfEntity: me), candidates: candidates, selfEntity: me,
                           directory: SpeakerDirectory(speakers: try await store.speakers(of: meetingID), selfEntity: me), role: role,
                           notes: try await store.notes(meetingID), locale: meeting.minutesLocale)
    }

    // MARK: Grouping

    /// Consecutive notes of the final pass whose windows together still fit one request (large windows only).
    private func groups(of notes: [MeetingNote], ctx: NoteContext) -> [[MeetingNote]] {
        let sorted = notes.sorted { ($0.t, $0.id) < ($1.t, $1.id) }
        guard ctx.budget.noteBatchLimit > 1, let segments = ctx.segments else { return sorted.map { [$0] } }
        var out: [[MeetingNote]] = []
        for note in sorted {
            if note.addedAfter { out.append([note]); continue }
            if var last = out.last, last.count < ctx.budget.noteBatchLimit, !last[0].addedAfter {
                let window = segments.filter { $0.start >= last[0].t - Self.aroundBefore && $0.start <= note.t + Self.aroundAfter }
                if Self.tokens(of: window) <= ctx.budget.noteWindow {
                    last.append(note)
                    out[out.count - 1] = last
                    continue
                }
            }
            out.append([note])
        }
        return out
    }

    static func tokens(of segments: [CitableSegment]) -> Int { segments.reduce(0) { $0 + PromptText.tokens(VautaPrompts.line($1)) } }

    // MARK: One request

    /// What a request found for one note. `error` is set only when no request about the note was ever answered.
    struct NoteResult {
        var sentences: [NoteExpansion.Sentence] = []
        var upto: Int64 = 0
        var error: Error?
    }

    /// The verified sentences of every note of a group. Notes the first look finds nothing for are asked again alone
    /// from the meeting's search (once), except in the live pass.
    private func outcomes(for group: [MeetingNote], pass: NoteExpansion.Pass, ctx: NoteContext) async throws -> [NoteResult] {
        var results = Array(repeating: NoteResult(), count: group.count)
        var answered = Set<Int>()
        let kinds: [NoteMaterial] = pass == .live ? [.recent] : (group[0].addedAfter ? [.retrieval] : [.around, .retrieval])
        var remaining = Array(group.indices)
        for (round, kind) in kinds.enumerated() {
            let batches = round == 0 ? [remaining] : remaining.map { [$0] }
            for batch in batches where !batch.isEmpty {
                try Task.checkCancellation()
                let notes = batch.map { group[$0] }
                guard let material = try await material(kind, for: notes, pass: pass, ctx: ctx) else { continue }
                do {
                    let sentences = try await request(notes, material: material, ctx: ctx)
                    for (j, index) in batch.enumerated() {
                        results[index] = NoteResult(sentences: sentences[j], upto: material.upto)
                        answered.insert(index)
                    }
                } catch let error where !(error is CancellationError) {
                    // One request failing never discards what the others found; an error that stops the whole job does.
                    if let llm = error as? LLMError, llm.isRetryable || llm.stopsWork { throw error }
                    for index in batch where !answered.contains(index) { results[index].error = error }
                }
            }
            remaining = remaining.filter { results[$0].sentences.isEmpty && results[$0].error == nil }
            if remaining.isEmpty { break }
        }
        return results
    }

    struct Material {
        let message: ChatMessage
        let sent: [Int64: CitableSegment]
        let upto: Int64
    }

    private func material(_ kind: NoteMaterial, for notes: [MeetingNote], pass: NoteExpansion.Pass, ctx: NoteContext) async throws -> Material? {
        let budget = ctx.budget
        // The instruction as it will be sent, with the two earlier notes (each up to 300 characters, about one token per
        // character in Japanese, Chinese and Korean): measured, not guessed.
        let harness = noteHarness(for: ctx.chat, budget: budget)
        let fixed = PromptText.tokens([.system(VautaPrompts.system), ctx.entities,
                                       VautaPrompts.noteInstruction(notes.map(\.text), earlier: Self.earlierNotes(before: notes[0], in: ctx),
                                                                    maxSentences: budget.noteSentences, language: ctx.language, harness: harness)])
        // What the request really has left, never more than the window; the floor only keeps a note from being sent with no
        // transcript at all (a prompt that long already has no room for any).
        let remaining = budget.contextTokens - fixed - budget.noteOutputLimit(harness, promptTokens: nil) * notes.count - budget.safety
        let room = max(256, min(budget.noteWindow, remaining))
        func make(_ segments: [CitableSegment]) -> Material? {
            guard !segments.isEmpty else { return nil }
            return Material(message: VautaPrompts.transcriptMessage(segments), sent: Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                            upto: segments.map(\.id).max() ?? 0)
        }
        switch kind {
        case .recent:
            // Around the note, not up to now: a note that waited (behind others, through retries, for a model) is still
            // expanded from what was said when it was taken and just after, the part the settle rule waits for.
            let from = notes[0].t - NoteExpansionPolicy.lookBack
            let segments = try await store.citableSegments(ctx.meetingID, from: from, to: notes[0].t + Self.liveAfter)
            return make(Self.tokens(of: segments) > room ? Self.nearest(segments, to: [notes[0].t], room: room) : segments)
        case .around:
            let all = try await wholeTranscript(ctx)
            let low = notes.first!.t - Self.aroundBefore, high = notes.last!.t + Self.aroundAfter
            var window = all.filter { $0.start >= low && $0.start <= high }
            // Too much for the window: keep the segments nearest the notes.
            if Self.tokens(of: window) > room { window = Self.nearest(window, to: notes.map(\.t), room: room) }
            return make(window)
        case .retrieval:
            let all = try await wholeTranscript(ctx)
            // A meeting that fits the window is sent whole; a longer one, the passages its search finds for the note.
            if Self.tokens(of: all) <= room { return make(all) }
            let text = notes.map(\.text).joined(separator: " ")
            let query = try await queryVector(text, language: ctx.language)
            let mode = await meetingRankingMode(space: query?.space, within: ctx.meetingID)
            let passages = try await store.retrieve(text, queryVector: query?.vector, within: ctx.meetingID, space: query?.space,
                                                    limit: budget.askPassageLimit, maxChars: budget.noteWindow * 3, locale: ctx.locale, mode: mode)
            // Dense scripts (about one character per token) would overflow the window at three characters per token.
            let fitted = Self.passages(passages, fitting: room)
            var sent: [Int64: CitableSegment] = [:]
            for p in fitted { p.segments.forEach { sent[$0.id] = $0 } }
            guard !sent.isEmpty else { return nil }
            return Material(message: VautaPrompts.passagesMessage(fitted), sent: sent, upto: sent.keys.max() ?? 0)
        }
    }

    /// The segments nearest `centres` that fit `room` tokens, in time order.
    static func nearest(_ window: [CitableSegment], to centres: [Double], room: Int) -> [CitableSegment] {
        let byDistance = window.sorted { a, b in
            (centres.map { abs(a.start - $0) }.min() ?? 0) < (centres.map { abs(b.start - $0) }.min() ?? 0)
        }
        var kept: [CitableSegment] = []
        var size = 0
        for s in byDistance {
            let t = PromptText.tokens(VautaPrompts.line(s))
            if size + t > room { break }
            kept.append(s)
            size += t
        }
        return kept.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// The best-ranked passages whose lines fit `room` tokens (a single passage that is too long is cut to its middle).
    static func passages(_ passages: [RetrievedPassage], fitting room: Int) -> [RetrievedPassage] {
        var kept: [RetrievedPassage] = []
        var size = 0
        for p in passages {
            let t = tokens(of: p.segments) + 12
            if size + t <= room { kept.append(p); size += t; continue }
            if kept.isEmpty {
                let middle = p.segments.isEmpty ? 0 : p.segments[p.segments.count / 2].start
                let cut = nearest(p.segments, to: [middle], room: max(1, room - 12))
                if !cut.isEmpty {
                    kept.append(RetrievedPassage(meeting: p.meeting, start: cut.first!.start, end: cut.last!.start, segments: cut, score: p.score))
                }
            }
            break
        }
        return kept
    }

    private func wholeTranscript(_ ctx: NoteContext) async throws -> [CitableSegment] {
        if let segments = ctx.segments { return segments }
        return try await store.citableSegments(ctx.meetingID)
    }

    /// The two notes before `note`, which give the model the thread of the user's notes.
    static func earlierNotes(before note: MeetingNote, in ctx: NoteContext) -> [String] {
        ctx.notes.filter { ($0.t, $0.id) < (note.t, note.id) }.suffix(2).map(\.text)
    }

    /// Asks the model about `notes` with `material` and validates the answer. One repair try for an answer that is not JSON.
    private func request(_ notes: [MeetingNote], material: Material, ctx: NoteContext) async throws -> [[NoteExpansion.Sentence]] {
        let budget = ctx.budget
        let first = notes[0]
        let earlier = Self.earlierNotes(before: first, in: ctx)
        let harness = noteHarness(for: ctx.chat, budget: budget)
        let instruction = VautaPrompts.noteInstruction(notes.map(\.text), earlier: earlier, maxSentences: budget.noteSentences, language: ctx.language,
                                                       harness: harness)
        var messages: [ChatMessage] = [.system(VautaPrompts.system), ctx.entities, material.message, instruction]
        let thinking = ctx.role == .deep && !ctx.chat.onDevice
        let limit = notes.count == 1 ? budget.noteOutputLimit(harness, promptTokens: PromptText.tokens(messages)) : budget.noteOutput
        var options = ChatOptions(model: ctx.role, maxTokens: limit * notes.count + (thinking ? 1_500 : 0), thinking: thinking,
                                  reasoningEffort: thinking ? "low" : nil, purpose: .notes,
                                  outputSchema: notes.count == 1 ? OutputSchemas.noteSingle(.init(segments: Set(material.sent.keys.map { Int($0) })), tight: harness.contains(.prompt))
                                                                : OutputSchemas.noteBatch(count: notes.count, .init(segments: Set(material.sent.keys.map { Int($0) }))),
                                  priority: .live)
        let check = VautaPrompts.NoteCheck(sent: material.sent, people: ctx.candidates, selfEntity: ctx.selfEntity,
                                           directory: ctx.directory, maxSentences: budget.noteSentences, tidy: harness.contains(.repair))
        // The verified sentences of a reply, before the relevance rule.
        func verify(_ raw: String) throws -> [[NoteExpansion.Sentence]] {
            let content = harness.contains(.repair) ? NoteReply.repaired(raw) : raw
            return notes.count == 1 ? [try VautaPrompts.validateNoteExpansion(content, check: check)]
                                    : try VautaPrompts.validateNoteBatch(content, count: notes.count, check: check)
        }
        func relevant(_ found: [[NoteExpansion.Sentence]]) -> [[NoteExpansion.Sentence]] {
            guard harness.contains(.relevance) else { return found }
            return zip(found, notes).map { NoteReply.relevant($0, to: $1) }
        }
        func validate(_ raw: String) throws -> [[NoteExpansion.Sentence]] { relevant(try verify(raw)) }
        var result = try await ctx.chat.model.chat(messages, options, onProgress: nil)
        // A reply cut at the limit keeps the sentences it finished (`.salvage`): it is closed at its last
        // complete sentence; the result is verified as any reply and used if it has at least one sentence that passes the checks. Without one the old
        // paths run: one larger try, then the failure.
        func salvaged(_ cut: ChatResult) -> [[NoteExpansion.Sentence]]? {
            guard cut.isTruncated, harness.contains(.salvage) else { return nil }
            // Sentences that were verified but are not about the note are an answer too ("nothing found"), not a reply to ask for again.
            for text in [ModelOutput.closingTruncatedJSON(cut.content)].compactMap({ $0 }) {
                if let found = try? verify(text), found.contains(where: { !$0.isEmpty }) {
                    status.reachable = true
                    status.lastCacheHit = cut.cachedTokens
                    return relevant(found)
                }
            }
            return nil
        }
        if let sentences = salvaged(result) { return sentences }
        if result.isTruncated, let raised = budget.raisedOutput(from: options.maxTokens, promptTokens: PromptText.tokens(messages)) {
            options.maxTokens = raised
            result = try await ctx.chat.model.chat(messages, options, onProgress: nil)
            if let sentences = salvaged(result) { return sentences }
        }
        guard !result.isTruncated else { throw LLMError.outputTruncated }
        status.reachable = true
        status.lastCacheHit = result.cachedTokens
        do {
            return try validate(result.content)
        } catch let error as LLMError {
            guard case .invalidResponse = error else { throw error }
            if !budget.isSmall {
                messages.append(ChatMessage("assistant", String(result.content.prefix(4000))))
                messages.append(VautaPrompts.repairNotesInstruction())
            }
            let again = try await ctx.chat.model.chat(messages, options, onProgress: nil)
            guard !again.isTruncated else { throw LLMError.outputTruncated }
            return try validate(again.content)
        }
    }
}

extension LLMError {
    /// The setup is missing or broken: no further request would work (the whole job waits).
    var stopsWork: Bool {
        switch self {
        case .notConfigured, .unauthorized, .invalidStoredToken, .modelUnavailable, .unsupportedLanguage, .untrustedPeerAddress: true
        default: false
        }
    }
}

extension MeetingStore {
    /// The meeting a note belongs to (nil if it was deleted).
    func meetingID(ofNote noteID: Int64) throws -> Int64? {
        try db.query("SELECT meeting_id FROM notes WHERE id = ?", [.integer(noteID)]).first?.int(0)
    }
}
