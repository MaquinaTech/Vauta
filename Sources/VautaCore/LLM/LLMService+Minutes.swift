// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Final minutes: in one request when the meeting fits the context window,
/// otherwise map-reduce (an extract per block, merged until the extracts fit).
extension LLMService {
    /// Everything one minutes run needs, gathered once.
    struct MinutesJob {
        let chat: ChatProvider
        let budget: ContextBudget
        let request: VautaPrompts.MinutesRequest
        let entities: ChatMessage
        let progress: @Sendable (Int) -> Void
        /// What the prompts offer (segment and person numbers): the integrated model decodes within them.
        let offered: OutputSchemas.Offered
        /// Called as the integrated model reads the prompt (nil for the other providers).
        var prefill: (@Sendable (Int, Int) -> Void)?

        var system: ChatMessage { .system(VautaPrompts.system) }

        /// A model server gets the schema as `response_format` on the requests without reasoning (the blocks, the merges, the closing
        /// request): a grammar over the reasoning would constrain the reasoning too on the servers that apply it to the whole reply. The
        /// profile decides whether it is sent at all (`ServerProfile.structuredOutput`).
        func options(maxTokens: Int, thinking: Bool, schema: OutputSchema? = nil, keepsPrefix: Bool = false, slot: KeptSlot = .meeting) -> ChatOptions {
            let format = schema.flatMap { s in !chat.onDevice && !thinking ? ResponseFormat.jsonSchema(name: "minutes", schema: s.serverJSONSchemaData()) : nil }
            return ChatOptions(model: .deep, maxTokens: maxTokens, thinking: thinking && !chat.onDevice,
                               reasoningEffort: thinking && !chat.onDevice ? "low" : nil, responseFormat: format, purpose: .minutes, outputSchema: schema,
                               reusePrefix: keepsPrefix, priority: .minutes, slot: keepsPrefix ? slot : nil, onPrefill: prefill)
        }
    }

    /// Notes shown to one block of a long meeting.
    static let notesPerBlock = 5

    /// The most outcomes the digest of a long meeting on a small window leads with.
    static let outcomeLimit = 12

    /// The user's notes for the minutes prompt, capped (15 on a small window, 60 otherwise). When there are more, the
    /// ones with an expansion and the most recently edited stay. The expansion (verified sentences with their
    /// `[S<id>]` citations) goes only to a window with room; the small one gets the user's words and times.
    static func priorityHints(_ rows: [NoteRow], budget: ContextBudget) -> [VautaPrompts.UserNoteHint] {
        let cap = budget.isSmall ? 15 : 60
        var ranked = rows.count <= cap && !budget.isSmall ? rows : rows.sorted { a, b in
            let (ka, kb) = (a.visibleSentences.isEmpty ? 0 : 1, b.visibleSentences.isEmpty ? 0 : 1)
            if ka != kb { return ka > kb }
            return (a.note.editedAt ?? .distantPast, a.note.t) > (b.note.editedAt ?? .distantPast, b.note.t)
        }
        ranked = Array(ranked.prefix(cap))
        if budget.isSmall {
            // The list shares the window with the transcript extracts: each line is clipped like the live notes' and the
            // list as a whole keeps to a fixed share of the request (the lowest-ranked notes go first).
            var kept: [NoteRow] = []
            var tokens = 0
            for row in ranked {
                let cost = PromptText.tokens(VautaPrompts.UserNoteHint(t: row.note.t, text: clipped(row.note.text, budget)).line) + 4
                if tokens + cost > budget.minutesInput / 5 && !kept.isEmpty { break }
                tokens += cost
                kept.append(row)
            }
            ranked = kept
        }
        return ranked.sorted { ($0.note.t, $0.note.id) < ($1.note.t, $1.note.id) }.map { row in
            var expansion: String?
            // Only what the checks backed and what is current: a sentence marked unconfirmed, one written from an older wording
            // of the note, and the user's own rewrite (never checked against the transcript) are left out of the evidence.
            if !budget.isSmall, !row.isStale, row.expansion?.userEdited != true {
                let lines = row.visibleSentences.filter { !$0.unconfirmed }.map { s in
                    (s.differs ? "The transcript says: " : "") + s.text + " " + s.cites.map { "[S\($0.seg)]" }.joined()
                }
                expansion = lines.isEmpty ? nil : lines.joined(separator: " ")
            }
            return VautaPrompts.UserNoteHint(t: row.note.t, text: clipped(row.note.text, budget), expansion: expansion)
        }
    }

    private static func clipped(_ text: String, _ budget: ContextBudget) -> String {
        budget.isSmall ? PromptText.clip(SingleLineText.flatten(text), budget.liveUserNotes.characters) : text
    }

    func writeMinutes(_ meetingID: Int64) async throws {
        // The cue checks remember the transcript clauses they normalised; none of that outlives the minutes run.
        defer { ItemCues.forgetTexts() }
        let chat = try chatProvider()
        // Another provider writes these minutes: nothing will use the meeting's prefix.
        if !chat.integrated { await releaseWarm(meetingID) }
        guard let meeting = try await store.meeting(meetingID) else { await releaseWarm(meetingID); return }
        // The final speakers, when diarization ran. Provisional numbers (the live clustering's) are only used for a meeting that has
        // none: the two clusterings number the voices differently, and a "Speaker 3" of one must never be looked up in the other.
        let finalSpeakers = try await store.speakers(of: meetingID)
        let stored = try await store.citableSegments(meetingID)
        let segments = finalSpeakers.isEmpty ? withProvisionalSpeakers(stored, meetingID: meetingID) : stored
        guard !segments.isEmpty else { await releaseWarm(meetingID); return }
        if let supports = chat.supports, !supports(meeting.minutesLocale) || !supports(meeting.transcriptionLocale) {
            throw LLMError.unsupportedLanguage
        }
        let budget = ContextBudget(contextTokens: chat.contextTokens)
        // The user's notes are written out first (speakers are final by now), so the minutes see them finished.
        try await expandNotesForMinutes(meetingID, chat: chat)
        let candidates = try await store.candidateEntities(meetingID, limit: budget.entityLimit)
        let me = try await store.selfEntity()
        let meetingPeople = Set(try await store.meetingEntities(meetingID, role: .attendee).map(\.id)
                                + store.meetingEntities(meetingID, role: .others).map(\.id))
        // Who is who among the speakers. IDs only: nothing about the voices goes anywhere.
        let directory = SpeakerDirectory(speakers: finalSpeakers, selfEntity: me)
        let mark = "(mark: important moment)"
        let marks = try await store.marks(meetingID).map { "[\(PromptText.clock($0.t))] \(mark)" }
        let noteRows = try await store.noteRows(meetingID)
        let liveHints = try await store.liveNotes(meetingID).flatMap(VautaPrompts.liveNoteLines)
        // The integrated model reads the meeting in the streaming layout: the transcript is the last message of a prefix it may already
        // have read while the meeting was recorded; what changed since (names, new people) rides in the instruction.
        let arms = minutesArms
        let streaming = chat.integrated && arms.contains(.streamingLayout)
        let warmHere = streaming && warmMeetingID == meetingID
        // The minutes keep the meeting's prefix, so that the second pass and the questions that follow only read their own suffix; a
        // meeting that is not the one being read uses the Ask slot, never the pinned prefix of another.
        let keptSlot: KeptSlot = warmMeetingID == nil || warmHere ? .meeting : .ask
        let frozen = warmHere ? (warm?.entities ?? candidates) : candidates
        let delta = streaming ? VautaPrompts.contextDelta(segments: segments, frozen: frozen, current: candidates, selfEntity: me) : ""
        // The zone the meeting was recorded in (the Mac's, for a meeting from before it was stored): the date the model is given, the due
        // days and the summary's date checks all read the meeting's own day.
        let meetingZone = (try? await store.meetingTimeZone(meetingID)) ?? .current
        var request = VautaPrompts.MinutesRequest(
            meetingDate: meeting.startedAt, language: OutputLanguage(meeting: meeting),
            template: try await store.minutesTemplate(meetingID) ?? .general,
            userNotes: Array(marks.prefix(budget.isSmall ? 10 : 30)),
            liveNotes: Array(liveHints.suffix(budget.isSmall ? 10 : 30)),
            priorityNotes: Self.priorityHints(noteRows, budget: budget), timeZone: meetingZone, recall: false, delta: delta)
        // The integrated model's request: the items before the summary, the summary rule, the recall wording and the sampling.
        let harness = chat.integrated ? minutesHarnessOverride ?? MinutesHarnessRelease.harness(integrated: true) : MinutesHarness.legacy
        request.recall = chat.integrated && (arms.contains(.recallPrompt) || harness.contains(.recall))
        let extraction = minutesExtractionOverride ?? (chat.releasedHarness ? MinutesRelease.extraction(integrated: chat.integrated) : .legacy)
        let questionParts = minutesQuestionsOverride ?? (chat.releasedHarness ? MinutesQuestionsRelease.questions(integrated: chat.integrated) : .legacy)
        let summaryParts = minutesSummaryOverride ?? (chat.releasedHarness ? MinutesSummaryRelease.summary(integrated: chat.integrated) : .legacy)
        request.wording = .init(definitions: extraction.contains(.prompts), hasMeLines: segments.contains { $0.channel == .me }, integrated: chat.integrated,
                                capped: !extraction.contains(.uncapped), blockDefinitions: extraction.contains(.blockPrompts),
                                outcomeSummary: summaryParts.contains(.wording),
                                blockEntities: !(extraction.contains(.blockShape) && !chat.integrated && candidates.isEmpty),
                                itemsFirst: harness.contains(.itemsFirst), outcomeRule: harness.contains(.outcomeRule),
                                expected: harness.contains(.count) ? MinutesHarness.expected(segments: segments) : nil,
                                openFromNotes: questionParts.contains(.digest) && !chat.integrated)
        var offeredEntities = Set<Int>(candidates.map { Int($0.id) })
        offeredEntities.insert(Int(me))
        let offered = OutputSchemas.Offered(segments: Set<Int>(segments.map { Int($0.id) }), entities: offeredEntities)
        let job = MinutesJob(chat: chat.withStructuredOutputFallback(), budget: budget, request: request,
                             entities: VautaPrompts.entitiesMessage(candidates, selfEntity: me),
                             progress: { n in Task { await self.progress(n) } }, offered: offered,
                             prefill: chat.integrated ? prefillReporter() : nil)
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let transcriptLanguage = meeting.transcriptionLocale.identifier
        // On a small window the final request returns only the language parts of the minutes (`MinutesDigest`).
        var digest: MinutesDigest?
        func validate(_ content: String, combined: Bool = true) throws -> ValidatedMinutes {
            try VautaPrompts.validateMinutes(combined ? digest.flatMap { $0.combine(content) } ?? content : content, segments: byID, candidates: candidates, selfEntity: me,
                                         meetingPeople: meetingPeople.union(directory.namedPeople), directory: directory,
                                         reference: meeting.startedAt, timeZone: meetingZone, language: transcriptLanguage, proseLanguage: meeting.minutesLocale.identifier,
                                         extraction: extraction)
        }

        let atLeast = request.wording.expected.map { (decisions: max(1, $0.decisions - 1), tasks: max(0, $0.tasks - 1)) } ?? (0, 0)
        var options = job.options(maxTokens: budget.minutesOutput, thinking: true, schema: OutputSchemas.minutes(job.offered, itemsFirst: harness.contains(.itemsFirst), atLeast: atLeast),
                                  keepsPrefix: streaming, slot: keptSlot)
        options.temperature = harness.temperature
        var messages = streaming
            ? [job.system, await streamingPeople(meetingID: meetingID, entities: frozen, selfEntity: me), VautaPrompts.streamingTranscriptMessage(segments), VautaPrompts.minutesInstruction(request)]
            : [job.system, job.entities, VautaPrompts.transcriptMessage(segments), VautaPrompts.minutesInstruction(request)]
        // The definitions and owner rules lengthen the instruction. A meeting that fits one request with the old wording but not with the
        // new keeps the old wording, so the new wording never moves a meeting to the blocks and the digest (another path for the title,
        // summary and topics).
        var wordingKeptForFit = false
        if request.wording.definitions, PromptText.tokens(messages) > budget.minutesInput {
            var plain = request
            plain.wording.definitions = false
            var plainMessages = messages
            plainMessages[plainMessages.count - 1] = VautaPrompts.minutesInstruction(plain)
            if PromptText.tokens(plainMessages) <= budget.minutesInput {
                request = plain
                messages = plainMessages
                wordingKeptForFit = true
            }
        }
        var result: ChatResult?
        let firstPassStarted = Date()
        if PromptText.tokens(messages) <= budget.minutesInput {
            do {
                let r = try await complete(messages, options, job, meetingID: meetingID)
                if !r.isTruncated { result = r }   // still cut off: summarize by blocks instead
            } catch LLMError.contextLengthExceeded {
                // The estimate was optimistic: summarize by blocks instead.
            }
        }
        // Blocks of a long meeting whose extract was cut off and could not be split, or could not be read: their decisions and tasks are
        // missing from the minutes, and the diagnostics say how many.
        var blocksTotal = 0, blocksOmitted = 0
        var outcomesInDigest = 0, outcomesMs = 0
        var explained = ""
        if result == nil {
            let all = try await extracts(of: segments, job)
            let extracts = all.replies
            blocksOmitted = all.omitted
            blocksTotal = all.leaves
            var finalOptions = options
            if budget.isSmall {
                var anchorPool: QuoteAnchor.Pool?
                var found = MinutesDigest(extracts: extracts, cleanSummaries: summaryParts.contains(.outcomes), openObjects: !questionParts.isDisjoint(with: [.digest, .lines]) && !chat.integrated) { item in
                    // The quote is in the segment the item cites (the check the minutes' validation makes), or the item is a copy to replace.
                    guard let seg = (item["seg"] as? NSNumber)?.int64Value else { return false }
                    let quote = item["quote"] as? String
                    if QuoteAnchor.resolve(quote: quote, cited: seg, citedText: byID[seg]?.text, pool: nil, language: transcriptLanguage) != nil { return true }
                    if anchorPool == nil {
                        anchorPool = QuoteAnchor.Pool(segments, language: transcriptLanguage)
                    }
                    return QuoteAnchor.resolve(quote: quote, cited: seg, citedText: byID[seg]?.text, pool: anchorPool, language: transcriptLanguage) != nil
                }
                // Nothing readable: a model cannot write minutes from nothing.
                guard !extracts.isEmpty, found.unreadable < extracts.count else { throw LLMError.outputTruncated }
                digest = found
                // The summary is written from what the meeting settled: the decisions and tasks that pass the quote check and the
                // evidence checks, with their status (no model; the final items are still validated as before).
                if summaryParts.contains(.outcomes) {
                    let started = ContinuousClock.now
                    if let stub = try? validate(#"{"title": "-", "summary": "-"}"#) {
                        let checked = ItemEvidence.apply(stub, context: .init(segments: segments, language: transcriptLanguage, directory: directory, selfEntity: me), extraction: [.evidence])
                        found.outcomes = MinutesOutcome.select(from: checked, limit: Self.outcomeLimit)
                        digest = found
                    }
                    outcomesInDigest = found.outcomes.count
                    outcomesMs = Int(((ContinuousClock.now - started) / .milliseconds(1)).rounded())
                }
                let digestInstruction = VautaPrompts.digestInstruction(request, outcomes: !found.outcomes.isEmpty)
                let room = budget.minutesInput - PromptText.tokens([job.system, digestInstruction]) - 16
                messages = [job.system, found.message(tokens: max(200, room)), digestInstruction]
                if extraction.contains(.explain) { explained = "room \(room) tokens \(PromptText.tokens(messages[1].content))\n" + messages[1].content }
                // Title, summary, topics and questions fit a few hundred tokens; the rest of the window is the prompt.
                finalOptions = job.options(maxTokens: min(budget.minutesOutput, 900), thinking: true, schema: nil)
            } else {
                messages = [job.system, job.entities, VautaPrompts.extractsMessage(extracts), VautaPrompts.reduceInstruction(request)]
            }
            var r = try await complete(messages, finalOptions, job, meetingID: meetingID)
            if r.isTruncated {
                // Title, summary, topics and questions are separate fields: what the model finished before the limit is kept (never
                // completed). A cut inside the first field leaves nothing, and the job fails as it always did.
                guard digest != nil, let kept = ModelOutput.closingTruncatedJSON(r.content) else { throw LLMError.outputTruncated }
                r = ChatResult(content: kept, promptTokens: r.promptTokens, cachedTokens: r.cachedTokens, completionTokens: r.completionTokens, finishReason: .stop,
                               firstTokenSeconds: r.firstTokenSeconds, engineFirstTokenSeconds: r.engineFirstTokenSeconds)
            }
            result = r
        }
        guard var result else { return }
        status.lastCacheHit = result.cachedTokens
        var minutes: ValidatedMinutes
        do {
            minutes = try validate(result.content)
        } catch let error as LLMError {
            guard case .invalidResponse = error else { throw error }
            // One more try. With room to spare, the answer goes back to the
            // model (the prefix stays cached); in a small window it would not fit.
            if !budget.isSmall {
                messages.append(ChatMessage("assistant", String(result.content.prefix(4000))))
                messages.append(VautaPrompts.repairInstruction())
            }
            result = try await complete(messages, digest == nil ? options : job.options(maxTokens: min(budget.minutesOutput, 900), thinking: true), job, meetingID: meetingID)
            minutes = try validate(result.content)
        }
        // The second pass: the decisions and tasks of each stretch of the meeting, on the prefix the first pass left (integrated only).
        if chat.integrated, arms.contains(.itemsPass), streaming, blocksTotal == 0, digest == nil, messages.count >= 4 {
            let firstPassSeconds = Date().timeIntervalSince(firstPassStarted)
            minutes = try await findMoreItems(minutes: minutes, segments: segments, base: Array(messages.prefix(3)), request: request, chat: chat,
                                              entityIDs: offeredEntities, slot: keptSlot, firstPassSeconds: firstPassSeconds, validate: { try validate($0) })
        }
        // The last stretch of the meeting once more, so the tasks agreed at the very end are not lost.
        if extraction.contains(.closing) {
            if chat.integrated, arms.contains(.closingPass), streaming, blocksTotal == 0, digest == nil, messages.count >= 4 {
                minutes = try await findClosingItems(minutes: minutes, segments: segments, base: Array(messages.prefix(3)), request: request, chat: chat,
                                                     entityIDs: offeredEntities, slot: keptSlot, firstPassSeconds: Date().timeIntervalSince(firstPassStarted), validate: { try validate($0) })
            } else if blocksTotal > 0 {
                minutes = await closeMeeting(minutes: minutes, segments: segments, job: job, validate: { try validate($0, combined: false) })
            }
        }
        if wordingKeptForFit { minutes.counts["prompt.oldWordingForFit"] = 1 }
        if summaryParts.contains(.checks) {
            minutes = SummaryChecks.apply(minutes, segments: segments, meetingDate: meeting.startedAt, timeZone: meetingZone, proseLanguage: meeting.minutesLocale.identifier,
                                         settled: digest?.outcomes.map(\.text) ?? [], maxSentences: chat.integrated ? nil : SummaryChecks.maxSentences,
                                         restatedQuestions: questionParts.contains(.settled), fromDigest: digest != nil)
        }
        if extraction.contains(.explain), !explained.isEmpty { minutes.counts["explain|digest|" + explained] = 1 }
        if outcomesInDigest > 0 { minutes.counts["summary.outcomes"] = outcomesInDigest; minutes.counts["timing.outcomesMs"] = outcomesMs }
        let evidenceStarted = ContinuousClock.now
        minutes = ItemEvidence.apply(minutes, context: .init(segments: segments, language: transcriptLanguage, directory: directory, selfEntity: me), extraction: extraction)
        if extraction.contains(.evidence) { minutes.counts["timing.evidenceMs"] = Int(((ContinuousClock.now - evidenceStarted) / .milliseconds(1)).rounded()) }
        // Apple's list: the best items of the meeting stay firm, the rest are "to be confirmed" (the integrated model's list is short already).
        if extraction.contains(.ranking), !chat.integrated {
            let rankStarted = ContinuousClock.now
            minutes = MinutesRanking.apply(minutes, context: .init(segments: segments, language: transcriptLanguage, directory: directory, selfEntity: me), extraction: extraction)
            minutes.counts["timing.rankMs"] = Int(((ContinuousClock.now - rankStarted) / .milliseconds(1)).rounded())
        }
        // The open questions last, against the decisions and tasks the minutes kept.
        if !questionParts.intersection([.form, .copy, .topic, .settled, .repeats, .generic, .cap]).isEmpty {
            minutes = OpenQuestionChecks.apply(minutes, segments: segments, integrated: chat.integrated, parts: questionParts)
        }
        // Apple's model: a decision must have been decided (jokes, questions and proposals nobody accepted are dropped).
        if chat.onDevice, !chat.integrated, decidedFilter { minutes = try await keepDecided(minutes, segments: segments, chat: chat) }
        var diagnostics = MinutesDiagnostics(minutes)
        if result.promptTokens > 0, blocksTotal == 0 { diagnostics.prefixReuse = Double(result.cachedTokens) / Double(result.promptTokens) }
        diagnostics.blocks = blocksTotal
        diagnostics.blocksOmitted = blocksOmitted
        diagnostics.blocksUnreadable = digest?.unreadable ?? 0
        diagnostics.log()
        lastMinutesDiagnostics = diagnostics
        // The user's own wording comes first among the topics, word for word (Swift does it, not the model).
        minutes.topics = TopicMerge.withUserNotes(minutes.topics, notes: TopicMerge.promotable(noteRows))
        try Task.checkCancellation()
        let pointing = try await store.applyMinutes(minutes, to: meetingID)
        // The minutes are written: the meeting's prefix goes back to the normal idle rules.
        await releaseWarm(meetingID)
        await linksAfterMinutes(meetingID, laterMeetings: pointing)
        if chat.integrated, streaming { await noteKept(keptSlot, meetingID: meetingID) }
    }

    /// A chat request whose answer, if cut off at the token limit, is asked
    /// again once with a larger limit when the window has room for it.
    private func complete(_ messages: [ChatMessage], _ options: ChatOptions, _ job: MinutesJob, meetingID: Int64) async throws -> ChatResult {
        let result = try await keeping(options.slot, meetingID: meetingID) { try await job.chat.model.chat(messages, options, onProgress: job.progress) }
        guard result.isTruncated,
              let raised = job.budget.raisedOutput(from: options.maxTokens, promptTokens: PromptText.tokens(messages)) else {
            return result
        }
        var larger = options
        larger.maxTokens = raised
        return try await keeping(larger.slot, meetingID: meetingID) { try await job.chat.model.chat(messages, larger, onProgress: job.progress) }
    }

    // MARK: Map-reduce

    /// Compact extracts of the meeting by blocks, merged until they fit in
    /// the final request.
    private func extracts(of segments: [CitableSegment], _ job: MinutesJob) async throws -> Extracted {
        // The notes of a block (at most a few, in the user's words) are part of its fixed cost.
        let noteTokens = job.request.priorityNotes.map { PromptText.tokens($0.blockLine) + 4 }.sorted(by: >).prefix(Self.notesPerBlock).reduce(0, +)
        let fixed = noteTokens + PromptText.tokens([job.system, job.entities, VautaPrompts.blockInstruction(job.request.language, wording: job.request.wording)])
        let room = max(job.budget.blockInput / 4, job.budget.blockInput - fixed - 16)
        var blocks: [[CitableSegment]] = [[]]
        var size = 0
        for s in segments {
            let t = PromptText.tokens(VautaPrompts.line(s))
            if size + t > room && !blocks[blocks.count - 1].isEmpty { blocks.append([]); size = 0 }
            blocks[blocks.count - 1].append(s)
            size += t
        }
        var out: [String] = []
        var omitted = 0, leaves = 0
        let filled = blocks.filter { !$0.isEmpty }
        for (i, block) in filled.enumerated() {
            // A note belongs to the block that holds the segment spoken just before it (the first and last blocks take the ends).
            let low = i == 0 ? -Double.infinity : block[0].start
            let high = i == filled.count - 1 ? Double.infinity : filled[i + 1][0].start
            let notes = job.request.priorityNotes.filter { $0.t >= low && $0.t < high }
            let one = try await extract(block, notes: notes, job, depth: 0)
            out += one.replies
            omitted += one.omitted
            leaves += one.leaves
        }
        var level = 0
        // A small window does not merge: the digest of the extracts is what the final request reads.
        while out.count > 1, level < 4, !job.budget.isSmall, PromptText.tokens([job.system, job.entities, VautaPrompts.extractsMessage(out),
                                                            VautaPrompts.reduceInstruction(job.request)]) > job.budget.minutesInput {
            out = try await merge(out, job)
            level += 1
        }
        return Extracted(replies: out, omitted: omitted, leaves: leaves)
    }

    /// The extracts of a meeting's blocks, and how many blocks left none (cut off at the smallest size, so nothing of them is in the minutes).
    private struct Extracted {
        var replies: [String] = []
        var omitted = 0
        /// Blocks that were asked (after any splitting).
        var leaves = 0
    }

    /// One block's extract. A block whose answer is cut off or does not fit
    /// is split in halves (up to three times).
    private func extract(_ block: [CitableSegment], notes: [VautaPrompts.UserNoteHint], _ job: MinutesJob, depth: Int) async throws -> Extracted {
        let messages = [job.system, job.entities, VautaPrompts.transcriptMessage(block, title: "BLOCK"),
                        VautaPrompts.blockInstruction(job.request.language, notes: Array(notes.prefix(Self.notesPerBlock)), wording: job.request.wording)]
        let canSplit = block.count > 1 && depth < 3
        do {
            let r = try await job.chat.model.chat(messages, job.options(maxTokens: job.budget.blockOutput, thinking: false,
                                                              schema: OutputSchemas.minutesExtract(.init(segments: Set(block.map { Int($0.id) }), entities: job.offered.entities), entities: job.request.wording.blockEntities)),
                                                  onProgress: job.progress)
            if r.isTruncated, canSplit { return try await split(block, notes: notes, job, depth: depth) }
            // Cut off and too small to split: half a JSON object would poison the merge and the final request, so the block is left out.
            return r.isTruncated ? Extracted(omitted: 1, leaves: 1) : Extracted(replies: [r.content], leaves: 1)
        } catch LLMError.contextLengthExceeded where canSplit {
            return try await split(block, notes: notes, job, depth: depth)
        }
    }

    private func split(_ block: [CitableSegment], notes: [VautaPrompts.UserNoteHint], _ job: MinutesJob, depth: Int) async throws -> Extracted {
        let half = block.count / 2
        let middle = block[half].start
        let first = try await extract(Array(block[..<half]), notes: notes.filter { $0.t < middle }, job, depth: depth + 1)
        let second = try await extract(Array(block[half...]), notes: notes.filter { $0.t >= middle }, job, depth: depth + 1)
        return Extracted(replies: first.replies + second.replies, omitted: first.omitted + second.omitted, leaves: first.leaves + second.leaves)
    }

    /// Merges consecutive extracts in groups that fit one request.
    private func merge(_ extracts: [String], _ job: MinutesJob) async throws -> [String] {
        let instruction = VautaPrompts.mergeInstruction(job.request.language)
        let room = max(job.budget.blockInput / 4,
                       job.budget.blockInput - PromptText.tokens([job.system, job.entities, instruction]) - 16)
        var groups: [[String]] = [[]]
        var size = 0
        for e in extracts {
            let t = PromptText.tokens(e) + 8
            // At least two per group, so every round shrinks the list.
            if size + t > room && groups[groups.count - 1].count >= 2 { groups.append([]); size = 0 }
            groups[groups.count - 1].append(e)
            size += t
        }
        var out: [String] = []
        for group in groups {
            if group.count == 1 { out.append(group[0]); continue }
            let r = try await job.chat.model.chat([job.system, job.entities, VautaPrompts.extractsMessage(group), instruction],
                                                  job.options(maxTokens: job.budget.blockOutput, thinking: false, schema: OutputSchemas.minutesExtract(job.offered)),
                                                  onProgress: job.progress)
            // A merge that was cut off is useless: its group stays as it was (the loop gives up after a few rounds).
            if r.isTruncated { out += group } else { out.append(r.content) }
        }
        return out
    }
}
