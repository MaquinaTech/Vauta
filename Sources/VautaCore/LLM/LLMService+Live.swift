// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Notes while recording, with the fast model.
extension LLMService {
    /// Notes on what is new since the last call, also stored with the meeting
    /// (they are shown afterwards and feed the final minutes as hints).
    /// Returns nil when there is nothing new or no live session.
    public func liveNotes(meetingID: Int64, at t: Double) async throws -> LiveNotesBatch? {
        guard var session = live, session.meetingID == meetingID else { return nil }
        let chat = try chatProvider(for: .live)
        let budget = ContextBudget(contextTokens: chat.contextTokens)
        let fresh = try await store.citableSegments(meetingID, afterID: session.lastSegment, byArrival: true)
        guard !fresh.isEmpty else { return nil }
        let since = session.lastSegment
        let harness = liveHarness(for: chat)
        // Only the checks that compare a note with its cited line or with who said it read the text and the user's channel; without them
        // nothing is kept (a long recording would otherwise carry its whole text and copy it on every tick).
        let readsTexts = harness.contains(.copies) || harness.contains(.owners)
        if readsTexts { for segment in fresh { session.texts[segment.id] = segment.text; if segment.channel == .me { session.mine.insert(segment.id) } } }
        session.lines += fresh.map(VautaPrompts.line)
        session.segmentIDs.formUnion(fresh.map(\.id))
        session.lastSegment = fresh.map(\.id).max() ?? since
        // The user's notes ride in the instruction: what they take comes out of the transcript's window.
        let userNotes = try await store.notes(meetingID).map(\.text)
        let (noteCount, noteCharacters) = budget.liveUserNotes
        let notesTokens = PromptText.tokens(VautaPrompts.liveUserNotesBlock(userNotes, count: noteCount, characters: noteCharacters))
        // Sliding window when the meeting does not fit in the context.
        while session.lines.count > 1, PromptText.tokens(session.lines.joined(separator: "\n")) > max(budget.liveWindow / 2, budget.liveWindow - notesTokens) {
            session.lines.removeFirst(max(1, session.lines.count / 4))
        }
        // The session only advances when the call succeeds: after a failure the
        // next call asks for notes on the same stretch again.
        try await waitForRefinements()
        try await acquire(.live)
        defer { release() }
        // A tick that waited for the model while another finished starts from what that one took and showed, not from the copy it made before
        // waiting: otherwise its repeat check would not know the other's notes and the notes would be stored twice.
        if let current = live, current.meetingID == meetingID {
            session.previous = current.previous
            session.taken = current.taken
        }
        status.activity = String(localized: "Live notes", comment: "Model server activity in the menu bar panel")
        status.activityMeeting = meetingID
        publish()
        defer { status.activity = nil; status.activityMeeting = nil; publish() }
        var messages: [ChatMessage] = [.system(VautaPrompts.system), session.entities,
                                       VautaPrompts.liveTranscriptMessage(session.lines),
                                       VautaPrompts.liveInstruction(sinceID: since, previous: session.previous, language: session.language,
                                                                    userNotes: userNotes, userNoteCount: noteCount,
                                                                    userNoteCharacters: noteCharacters, harness: harness)]
        var slot: KeptSlot?
        // The integrated model takes notes on the transcript it has been reading (the whole of it up to the window of one request,
        // not a sliding window of its own): the same prefix as the answers and the minutes.
        var knownSegments = session.segmentIDs
        var texts = session.texts, mine = session.mine
        if chat.integrated, let state = warm, state.meetingID == meetingID {
            let all = withProvisionalSpeakers(try await store.citableSegments(meetingID), meetingID: meetingID)
            let prefix: [ChatMessage] = [.system(VautaPrompts.system),
                                         await streamingPeople(meetingID: meetingID, entities: state.entities, selfEntity: state.selfEntity),
                                         VautaPrompts.streamingTranscriptMessage(all)]
            if PromptText.tokens(prefix) <= budget.minutesInput {
                let delta = VautaPrompts.contextDelta(segments: all, frozen: state.entities, current: state.entities, selfEntity: state.selfEntity)
                messages = prefix + [VautaPrompts.liveInstruction(sinceID: since, previous: session.previous, language: session.language, userNotes: userNotes,
                                                                  userNoteCount: noteCount, userNoteCharacters: noteCharacters, delta: delta, harness: harness)]
                slot = .meeting
                knownSegments = Set(all.map(\.id))
                if readsTexts { for segment in all { texts[segment.id] = segment.text; if segment.channel == .me { mine.insert(segment.id) } } }
            }
        }
        let schema = OutputSchemas.liveNotes(.init(segments: Set(knownSegments.map { Int($0) })))
        // A model server gets the same shape as `response_format` (the profile decides whether it is sent), without the segment numbers.
        var options = ChatOptions(model: .fast, maxTokens: budget.liveOutput,
                                  responseFormat: chat.onDevice ? nil : .jsonSchema(name: "live_notes", schema: schema.serverJSONSchemaData()), purpose: .liveNotes,
                                  outputSchema: schema, reusePrefix: true, priority: .live, slot: slot)
        var result: ChatResult
        let check = LiveCheck(harness: harness, lines: texts, mine: mine, earlier: session.taken)
        // A reply the checks can read: as it is, or (`.repair`) with the segment tags put right and a cut closed at its last finished note.
        func read(_ text: String) throws -> LiveNotesBatch {
            do { return try VautaPrompts.validateLive(text, segments: knownSegments, check: check) } catch {
                guard harness.contains(.repair) else { throw error }
                let fixed = NoteReply.repaired(text)
                for candidate in [fixed, ModelOutput.closingTruncatedJSON(fixed)].compactMap({ $0 }) {
                    if let notes = try? VautaPrompts.validateLive(candidate, segments: knownSegments, check: check) { return notes }
                }
                throw error
            }
        }
        var salvaged: LiveNotesBatch?
        do {
            result = try await StructuredOutputRetry.run(&options) { try await chat.model.chat(messages, $0, onProgress: nil) }
            // A reply cut at the limit is read up to its last finished note instead of asking again (`.repair`): no second call.
            if result.isTruncated, harness.contains(.repair), let notes = try? read(result.content), !notes.isEmpty { salvaged = notes }
            if salvaged == nil, result.isTruncated, let raised = budget.raisedOutput(from: options.maxTokens, promptTokens: PromptText.tokens(messages)) {
                options.maxTokens = raised
                result = try await StructuredOutputRetry.run(&options) { try await chat.model.chat(messages, $0, onProgress: nil) }
            }
        } catch is GenerationPreempted {
            // A question took the integrated model's slot while the notes waited: nothing is wrong, and the session did not advance,
            // so the next tick asks for the same stretch again. The recorder shows no notice.
            return nil
        }
        status.reachable = true
        status.lastCacheHit = result.cachedTokens
        let notes = try salvaged ?? read(result.content)
        // Another meeting's session may have started while the model worked: its state is not ours to change, and the notes are still stored.
        let sameSession = live?.meetingID == meetingID
        if sameSession {
            // What a tick that finished in between added (the notes it showed, the notes it took) is kept: `session` is the copy from before.
            let previous = live?.previous ?? []
            let earlier = live?.taken ?? []
            live = session
            live?.previous = previous
            live?.taken = earlier
        }
        guard !notes.isEmpty else { return nil }
        if sameSession {
            live?.previous += VautaPrompts.liveNoteLines(notes)
            if readsTexts { live?.texts = texts; live?.mine = mine }
            let taken = (live?.taken ?? []) + notes.points.map { LiveCheck.Earlier(kind: .point, text: $0.text, segment: $0.segment) }
                + notes.decisions.map { LiveCheck.Earlier(kind: .decision, text: $0.text, segment: $0.segment) }
                + notes.tasks.map { LiveCheck.Earlier(kind: .task, text: $0.text, segment: $0.segment) }
            live?.taken = Array(taken.suffix(300))
        }
        if let json = try? JSONEncoder().encode(notes) {
            try await store.addLiveNotes(meetingID, at: t, json: String(decoding: json, as: UTF8.self))
        }
        var stamped = notes
        stamped.t = t
        return stamped
    }
}
