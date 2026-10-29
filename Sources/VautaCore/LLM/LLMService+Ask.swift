// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Ask: answers with verified citations (the main model; the fast one while recording).
extension LLMService {
    public struct AskResult: Sendable {
        public let answer: VerifiedAnswer
        public let passages: [RetrievedPassage]
        public let sent: [Int64: CitableSegment]
        /// Passages of the person's documents that were sent, with the IDs (`D1`…) the model cited them by.
        public let documentPassages: [DocumentPassage]
        public let sentDocuments: [String: DocumentPassage]
        /// Meeting of each segment a citation was moved to (`QuoteAnchor`), when it is not one of the meetings of `passages`.
        public let anchoredMeetings: [Int64: Int64]

        public init(answer: VerifiedAnswer, passages: [RetrievedPassage], sent: [Int64: CitableSegment],
                    documentPassages: [DocumentPassage] = [], sentDocuments: [String: DocumentPassage] = [:],
                    anchoredMeetings: [Int64: Int64] = [:]) {
            self.anchoredMeetings = anchoredMeetings
            self.answer = answer
            self.passages = passages
            self.sent = sent
            self.documentPassages = documentPassages
            self.sentDocuments = sentDocuments
        }
    }

    /// Where Ask finds documents: the index (nil = none were ever added).
    public func setDocuments(_ index: DocumentIndex?) { documents = index }

    /// Passages of the person's documents for a question, without the model (the passages Ask shows at once, and the sidebar
    /// search). `meetingID`: only that meeting's materials.
    public func documentPassages(for question: String, meetingID: Int64?, limit: Int = 6) async -> [DocumentPassage] {
        guard let documents else { return [] }
        var filter: DocumentFilter?
        if let meetingID {
            guard let materials = try? await store.materialsFilter(meetingID) else { return [] }
            filter = materials
        }
        return (try? await documents.search(question, within: filter, limit: limit)) ?? []
    }

    /// `meetingID`: about one meeting (context = its whole transcript, in the
    /// same order as the minutes so the server reuses its cache); nil = about
    /// all of them (hybrid search). The answer is written in the question's
    /// language. Without embeddings the search uses keywords and the graph.
    /// Cancelling the calling task stops it promptly, also while it waits
    /// for another request to finish.
    ///
    /// `auto`: the question was heard in the meeting being recorded (live answers, see `AutoAskRequest`): the same path with the bounds
    /// of that mode.
    public func ask(_ question: String, meetingID: Int64?, scope: KnowledgeScope = .everywhere, auto: AutoAskRequest? = nil,
                    onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> AskResult {
        // A person's own question takes the lane before any answer to a question heard: that one is cancelled and closed as superseded.
        if auto == nil { supersedeAutoAnswer() }
        if auto != nil, !(recording && meetingID != nil && liveSessionMeeting == meetingID) { throw CancellationError() }
        // A meeting in progress: its material ends now, so an answer that "comes later" is a refusal. Any other question (a finished
        // meeting, the whole library, documents) is about complete material. Live questions may go to another model (Settings).
        let aboutNow = recording && meetingID != nil && liveSessionMeeting == meetingID
        let chat = try chatProvider(for: aboutNow ? .live : .main)
        // An answer to a question heard never runs on a model that does not offer live answers, even if the provider changed since
        // `autoAnswer` looked (decision D16).
        if auto != nil, !permitsLiveAnswers(chat) { throw LLMError.modelUnavailable }
        // Where the meeting being recorded stood when the question was asked: taken before the wait for the lane (live notes, an earlier
        // question or its check can hold it for tens of seconds), so a quote is never moved to a line said after the question.
        var liveAtQuestion: (meeting: Int64, lastSegment: Int64, start: Double)?
        if recording, let live = liveSessionMeeting, aboutNow || meetingID == nil {
            let all = try? await store.citableSegments(live)
            // An answer to a question heard sees the meeting up to the question's own line, whatever was said while it waited.
            let last = auto.map { bound in all?.last { $0.id <= bound.segmentID } } ?? all?.last
            liveAtQuestion = (live, last?.id ?? 0, last?.start ?? 0)
        }
        let lanePriority: Priority = auto == nil ? .ask : .auto
        if auto == nil {
            askWaiting += 1
            backgroundTask?.cancel()   // the question is interactive: background work waits
        }
        do {
            try await acquire(lanePriority)
        } catch {
            if auto == nil { askWaiting -= 1 }
            kick()
            throw error
        }
        if auto == nil { askWaiting -= 1 }
        defer {
            release()
            kick()   // the interrupted job resumes as soon as the question is answered
        }
        status.activity = auto == nil ? String(localized: "Answering your question", comment: "Model server activity in the menu bar panel")
                                      : String(localized: "Finding an answer", comment: "Model server activity in the menu bar panel while it answers a question heard in the meeting")
        status.activityStarted = .now
        status.activityIsAsk = auto == nil
        publish()
        defer { status.activity = nil; status.activityStarted = nil; status.activityIsAsk = false; clearProgress(); publish() }

        let budget = ContextBudget(contextTokens: chat.contextTokens)
        // The harness of this phase: the rule and the windows are for the small window (Apple's model), the order for the backends it measured
        // (a model server keeps the Ask it had, whatever the release says).
        let harness = askHarness(for: chat)
        let smallWindow = !chat.integrated && budget.isSmall
        let windowed = harness.contains(.windows) && smallWindow
        let decisionRule = !(harness.contains(.factRule) && smallWindow) || AskHarness.isDecisionQuestion(question)
        var meeting: MeetingStore.Meeting?
        if let meetingID { meeting = try await store.meeting(meetingID) }
        // A question heard in the meeting is answered in the language it was said in (what the model rewrote may have been translated),
        // else the question's, else the meeting's transcription language. The person's own question: its language, else the meeting's.
        let fallback = auto.map { OutputLanguage(Locale(identifier: $0.locale)) }
            ?? meeting.map(OutputLanguage.init(meeting:)) ?? OutputLanguage(Locale.current)
        let language = OutputLanguage.detect((auto?.heard ?? []) + [question], fallback: fallback)
        // Documents are used when the person added some and the scope allows; about one meeting, only its materials.
        var passageCount = 0
        if scope != .meetings, let documents { passageCount = (try? await documents.totalPassages()) ?? 0 }
        let hasDocuments = passageCount > 0
        let useMeetings = auto.map { $0.sources.contains(.thisMeeting) } ?? (scope != .documents)
        let materials: DocumentFilter? = auto == nil && meetingID != nil && hasDocuments ? try await store.materialsFilter(meetingID!) : nil
        // About one meeting (and documents are not the whole scope) only its materials are searched. An answer to a question heard
        // looks in the passages the evidence check found, in all the person's documents.
        let useDocuments = auto.map { $0.sources.contains(.documents) && !$0.documentPassages.isEmpty } ?? (hasDocuments && (meetingID == nil || materials != nil))
        // The integrated model reads the meeting in the streaming layout: the rules are part of the kept prefix and the question is the
        // last message. Apple's model and the servers keep the standard layout, with the rules after the question.
        let streaming = chat.integrated
        // The time rule rides with the question, never in the kept prefix: a question about a finished meeting never gets the live
        // rules, whatever is still warm.
        let laterGuard = auto == nil && streaming && aboutNow && answerGuards.contains(.threeWay)
        let timing = VautaPrompts.askTimingRules(live: aboutNow, laterGuard: laterGuard)
        let heard = auto != nil
        let claimCap: Int? = heard ? AutoAskRequest.maxClaims : nil
        var instruction = streaming ? VautaPrompts.askQuestionMessage(question, language: language, heard: heard)
                                    : VautaPrompts.askInstruction(question, language: language, documents: useDocuments, live: aboutNow,
                                                                  shortAnswer: chat.onDevice && budget.isSmall, claimCap: claimCap, heard: heard,
                                                                  decisionRule: decisionRule)
        // Passages (no meeting prefix to carry them) bring the rules in the last two messages.
        let passageRules: ChatMessage? = streaming
            ? .user(VautaPrompts.askRulesBody(documents: useDocuments, live: aboutNow, laterGuard: laterGuard, afterMaterial: true)) : nil
        let passageCharacters = budget.askPassageCharacters
        let passageLimit = windowed ? AskWindows.standard.count : budget.askPassageLimit

        var messages: [ChatMessage] = [.system(VautaPrompts.system)]
        var sent: [Int64: CitableSegment] = [:]
        var passages: [RetrievedPassage] = []
        var documentPassages: [DocumentPassage] = []
        var sentDocuments: [String: DocumentPassage] = [:]
        var wholeMeeting = false
        func tail(_ last: ChatMessage) -> [ChatMessage] { wholeMeeting ? [last] : (passageRules.map { [$0, last] } ?? [last]) }
        // What had been said when the question was asked (the whole meeting for a finished one): the quotes of the answer are looked
        // for here when the model cited the wrong segment.
        var visibleSegments: [CitableSegment] = []
        if let meetingID, useMeetings {
            var loaded = try await store.citableSegments(meetingID)
            // A live question sees the meeting as it stood when it was asked, not what was saved while it waited.
            if let bound = liveAtQuestion, bound.meeting == meetingID { loaded = loaded.filter { $0.id <= bound.lastSegment } }
            let segments = withProvisionalSpeakers(loaded, meetingID: meetingID)
            visibleSegments = segments
            // The same prefix as the minutes (entities and transcript), so the server reuses its cache.
            let current = try await store.candidateEntities(meetingID, limit: budget.entityLimit)
            let me = try await store.selfEntityID()
            let frozen = warmMeetingID == meetingID ? (warm?.entities ?? current) : current
            // The kept rules do not depend on the scope of the question (Meetings only, Everywhere): the documents wording is the one the
            // warm reading used, so a question scoped to Meetings never rewrites the second message of the prefix and rereads the meeting.
            let prefixDocuments = await askUsesDocuments(meetingID: meetingID)
            let entities = streaming
                ? await streamingPeople(meetingID: meetingID, entities: frozen, selfEntity: me, documents: prefixDocuments)
                : VautaPrompts.entitiesMessage(current, selfEntity: me)
            let transcript = streaming ? VautaPrompts.streamingTranscriptMessage(segments) : VautaPrompts.transcriptMessage(segments)
            if streaming {
                var delta = VautaPrompts.contextDelta(segments: segments, frozen: frozen, current: current, selfEntity: me)
                if prefixDocuments && (!useDocuments || auto?.includeExtras == false) {
                    delta += (delta.isEmpty ? "" : "\n") + "No excerpts of the user's documents are provided for this question: cite only segments."
                }
                instruction = VautaPrompts.askQuestionMessage(question, language: language, delta: delta, timing: timing, heard: heard)
            }
            let candidate = messages + [entities, transcript]
            // The whole visible transcript when it fits, however long reading it takes: a question never answers from a short excerpt
            // because the meeting is not read yet. If a reading of this meeting is in flight, the question takes the kept prefix from it
            // (the reading steps aside at its next chunk and what it has read stays); a reading of another meeting is not waited for. The
            // progress of the reading is shown (`onPrefill`) and the question can be cancelled.
            var fits = !segments.isEmpty && PromptText.tokens(candidate + [instruction]) <= budget.askInput
            // An answer to a question heard never makes the integrated model read the meeting cold: when the kept prefix is far behind
            // the transcript (or was never read), it answers from passages and asks for a reading.
            if fits, auto != nil, streaming, warmTokensBehind(meetingID: meetingID, total: PromptText.tokens(candidate)) > AutoAskRequest.maxPrefixLag {
                fits = false
                startWarmReading(meetingID)
            }
            if fits {
                messages = candidate
                segments.forEach { sent[$0.id] = $0 }
                wholeMeeting = true
                // The meeting fits whole: its materials join it, the best few and only if they fit too. An answer to a question heard
                // appends the past meetings' passages and the documents' after the transcript (the kept prefix is unchanged).
                if let auto {
                    appendAutoMaterial(auto, to: &messages, instruction: instruction, budget: budget, compact: streaming, passages: &passages, sent: &sent,
                                       documentPassages: &documentPassages, sentDocuments: &sentDocuments)
                } else if let documents, let materials {
                    let query = try await queryVector(question, language: language)
                    let docMode = await documentRankingMode(space: query?.space, filter: materials)
                    let found = (try? await documents.search(question, queryVector: query?.vector, space: query?.space, within: materials,
                                                              limit: budget.docMaterialLimit, locale: Locale(identifier: language.identifier),
                                                              entities: (try? await store.entityAliasKeys(named: question, locale: Locale(identifier: language.identifier))) ?? [],
                                                              mode: docMode)) ?? []
                    if !found.isEmpty {
                        let (message, ids) = VautaPrompts.documentsMessage(found)
                        if PromptText.tokens(messages + [message, instruction]) <= budget.askInput {
                            messages.append(message)
                            documentPassages = found
                            sentDocuments = ids
                        }
                    }
                }
            }
        }
        if !wholeMeeting {
            // The passages bring the rules (time included) in their own message: the question does not repeat them.
            if streaming { instruction = VautaPrompts.askQuestionMessage(question, language: language, heard: heard) }
            // A longer meeting, or all of them, or only documents: the most relevant passages of each kind, mixed under one budget.
            // A question heard retrieves nothing here (the evidence check did, once): its text is not embedded again, so nothing of the
            // meeting goes to an embeddings server and no GPU time is spent on a vector that would not be used.
            // E3, on demand: a question typed while the meeting is recorded, which this model cannot read whole, embeds the chunks that
            // have closed so far (nothing runs otherwise).
            var liveNotEmbedded = false
            if auto == nil, useMeetings, let bound = liveAtQuestion {
                let report = try await embedLivePrefix(meetingID: bound.meeting, upToSegment: bound.lastSegment, budget: meetingID == nil ? budget : nil, question: question)
                // Skipped now (battery, heat, the model being deleted): the chunks an earlier question stored are stale, the lines said
                // since have none, so the meeting is searched by keywords (with the translated question) and not by a partial set of vectors.
                liveNotEmbedded = report.skipped != nil && meetingID == bound.meeting
                // Over the whole library the semantic pass would still rank the live meeting by the chunks of an earlier question (they
                // stop there, and a rename may have changed their text): when this call could not refresh them, they go, and the
                // meeting's lines come from the keyword buckets alone.
                if meetingID == nil, let skipped = report.skipped, Self.staleLivePrefixSkips.contains(skipped) {
                    await discardLivePrefixChunks(bound.meeting)
                }
            }
            let query = auto == nil ? try await queryVector(question, language: language) : nil
            try Task.checkCancellation()
            let locale = Locale(identifier: language.identifier)
            // Only the search model's own space: a model server's embeddings never came from the on-demand path.
            let onDevice = query.map { SemanticRanker.isSearchModelSpace($0.space.model) } ?? false
            let meetingMode = liveNotEmbedded && onDevice ? SemanticRanker.Mode.keyword : await meetingRankingMode(space: query?.space, within: meetingID)
            let documentMode = await documentRankingMode(space: query?.space, filter: materials)
            // E4: a corpus that ranks by meaning is searched with the question as asked; one that ranks by keywords, with the question
            // translated into the transcripts' language when it is installed on this Mac.
            var keywordQuery = RoutedQuery(text: question, locale: locale, translated: false)
            if useMeetings, auto == nil {
                keywordQuery = await routedQuery(question, mode: meetingMode, corpus: await corpusLanguage(meeting: meeting, wholeLibrary: meetingID == nil), locale: locale)
                try Task.checkCancellation()
            }
            var found = useMeetings && auto == nil
                ? try await store.retrieve(keywordQuery.text, queryVector: query?.vector, within: meetingID, space: query?.space,
                                           limit: passageLimit, maxChars: passageCharacters, locale: keywordQuery.locale,
                                           mode: meetingMode, windows: windowed ? .standard : nil)
                : []
            if let auto {
                found = auto.passages(limit: passageLimit)
                // The evidence check leaves out the question's own line and the two before it (a question matches itself); the answer
                // may need them (the line just before the question often names what it is about), so they join as the best passage.
                if auto.sources.contains(.thisMeeting), let meeting, let all = try? await store.citableSegments(meeting.id) {
                    let have = Set(found.filter { $0.meeting.id == meeting.id }.flatMap { $0.segments.map(\.id) })
                    let near = all.filter { $0.id <= auto.segmentID }.suffix(3).filter { !have.contains($0.id) }
                    if let first = near.first, let last = near.last {
                        found.insert(RetrievedPassage(meeting: meeting, start: first.start, end: last.start, segments: Array(near),
                                                      score: (found.map(\.score).max() ?? 0) + 0.000_001), at: 0)
                    }
                }
            }
            // Lines saved while the question waited for the lane were not said yet when it was asked: they are neither sent nor cited.
            if let bound = liveAtQuestion {
                found = found.compactMap { passage in
                    guard passage.meeting.id == bound.meeting else { return passage }
                    let kept = passage.segments.filter { $0.id <= bound.lastSegment }
                    return kept.isEmpty ? nil : RetrievedPassage(meeting: passage.meeting, start: passage.start, end: passage.end, segments: kept, score: passage.score)
                }
            }
            var docs: [DocumentPassage] = []
            if let auto {
                docs = Array(auto.documentPassages.prefix(budget.docPassageLimit))
            } else if useDocuments, let documents {
                docs = (try? await documents.search(question, queryVector: query?.vector, space: query?.space, within: materials,
                                                    limit: passageLimit, locale: locale,
                                                    entities: (try? await store.entityAliasKeys(named: question, locale: locale)) ?? [],
                                                    mode: documentMode)) ?? []
            }
            // Cosine scores (meaning) and RRF scores (keywords) are not comparable: when only one corpus ranks by meaning, both
            // sides are compared by rank instead.
            let sameScale = auto == nil && (meetingMode == .semantic) == (documentMode == .semantic)
            let meetingScores = sameScale ? found.map(\.score) : KnowledgeMixer.rankScores(count: found.count)
            let documentScores = sameScale ? docs.map(\.score) : KnowledgeMixer.rankScores(count: docs.count)
            let choice = KnowledgeMixer.mix(meetings: found.enumerated().map { .init(score: meetingScores[$0.offset], characters: $0.element.segments.reduce(0) { $0 + $1.text.count + 24 }) },
                                            documents: docs.enumerated().map { .init(score: documentScores[$0.offset], characters: $0.element.text.count + 40) },
                                            limit: passageLimit, documentLimit: budget.docPassageLimit, maxCharacters: passageCharacters)
            let foundMeetings = found, foundDocuments = docs, base = messages
            var keptMeetings = choice.meetings, keptDocuments = choice.documents
            func assemble() -> (messages: [ChatMessage], ids: [String: DocumentPassage]) {
                var out = base
                if useMeetings, !keptMeetings.isEmpty || keptDocuments.isEmpty { out.append(VautaPrompts.passagesMessage(keptMeetings.map { foundMeetings[$0] }, ordered: harness.contains(.order))) }
                var ids: [String: DocumentPassage] = [:]
                if !keptDocuments.isEmpty {
                    let (message, found) = VautaPrompts.documentsMessage(keptDocuments.map { foundDocuments[$0] })
                    out.append(message)
                    ids = found
                }
                return (out, ids)
            }
            var built = assemble()
            // The mixer budgets characters, but dense scripts (Japanese, Chinese, Korean) cost about a token per character: the
            // prompt is measured in tokens, and the lowest-ranked passage goes until it fits (the best one always stays).
            while keptMeetings.count + keptDocuments.count > 1, PromptText.tokens(built.messages + tail(instruction)) > budget.askInput {
                let weakestMeeting = keptMeetings.min { meetingScores[$0] < meetingScores[$1] }
                let weakestDocument = keptDocuments.min { documentScores[$0] < documentScores[$1] }
                switch (weakestMeeting, weakestDocument) {
                case let (m?, d?):
                    if meetingScores[m] <= documentScores[d] { keptMeetings.removeAll { $0 == m } } else { keptDocuments.removeAll { $0 == d } }
                case let (m?, nil): keptMeetings.removeAll { $0 == m }
                case let (nil, d?): keptDocuments.removeAll { $0 == d }
                default: break
                }
                built = assemble()
            }
            passages = keptMeetings.map { foundMeetings[$0] }
            documentPassages = keptDocuments.map { foundDocuments[$0] }
            for p in passages { p.segments.forEach { sent[$0.id] = $0 } }
            messages = built.messages
            sentDocuments = built.ids
        }
        // The question's own lines were read for context but may not be cited (a question's premise is not a fact).
        if let auto { for id in auto.uncitable { sent[id] = nil } }
        guard !sent.isEmpty || !sentDocuments.isEmpty else {
            return AskResult(answer: VerifiedAnswer(answer: Self.notFoundText(scope: scope, documents: useDocuments), claims: [], found: false), passages: [], sent: [:])
        }
        messages += tail(instruction)
        let offered = OutputSchemas.Offered(segments: Set(sent.keys.map { Int($0) }), documents: Set(sentDocuments.keys.compactMap { Int($0.dropFirst()) }))
        let hasDocumentExcerpts = !sentDocuments.isEmpty
        // The integrated model decodes within the grammar. While a meeting records, the answer is a live one: bounded (tokens, seconds
        // and the schema's sizes) so it cannot run for minutes under a recording. Any other question (after the meeting, across the
        // library, over documents) gets the full schema and the normal output budget. A model server is asked for the same shape
        // through `response_format` (when its profile takes one) and Apple's model by the prompt. All three are validated below.
        let live = chat.integrated && recording
        // Apple's guided generation for Ask is opt-in (`VAUTA_APPLE_GUIDED=1`) until the 52-question gate (invalid JSON, found without
        // claim, the schema's cost in the 4K window) is run on the real model; by default Apple answers from the prompt, as before.
        let appleGuided = chat.onDevice && appleGuidedAsk
        var options = ChatOptions(model: recording ? .fast : .deep, maxTokens: budget.askOutput, purpose: auto == nil ? .ask : .liveAnswers,
                                  outputSchema: chat.integrated || appleGuided
                                      ? OutputSchemas.answer(offered, documents: hasDocumentExcerpts, live: live && chat.integrated, laterGuard: laterGuard,
                                                                   maxClaims: auto != nil ? AutoAskRequest.maxClaims : (chat.integrated ? nil : (recording ? 3 : 6)),
                                                                   answerBytes: auto == nil ? nil : AutoAskRequest.answerBytes) : nil,
                                  reusePrefix: wholeMeeting, priority: auto == nil ? .interactive : .autoAnswer,
                                  onPrefill: chat.integrated ? prefillReporter(minimumRead: 1_500) : nil)
        // The meeting being read (recorded, or just recorded) has its own kept prefix; any other meeting uses the Ask one.
        let keptSlot: KeptSlot = meetingID != nil && meetingID == warmMeetingID ? .meeting : .ask
        options.slot = wholeMeeting ? keptSlot : nil
        if live {
            options.maxTokens = min(options.maxTokens, auto == nil ? Self.liveAnswerTokens : AutoAskRequest.gemmaTokens)
            options.maxSeconds = auto == nil ? Self.liveAnswerSeconds : AutoAskRequest.gemmaSeconds
        } else if !chat.integrated, !chat.onDevice {
            options.responseFormat = .jsonSchema(name: "answer", schema: OutputSchemas.answerForServer(documents: hasDocumentExcerpts, maxClaims: claimCap).jsonSchemaData())
        }
        if auto != nil, !chat.integrated { options.maxTokens = min(options.maxTokens, AutoAskRequest.otherTokens) }
        var result = try await askChat(chat.model, messages, &options, meetingID: meetingID, onProgress: onProgress)
        // An answer cut off at the length limit keeps the claims it finished (all providers without a grammar: the integrated model
        // closes its own JSON). It is closed at its last complete element; if that leaves a verified claim it is used as it is,
        // else the request is made again once with a larger limit, and a second cut is closed the same way before giving up.
        let transcriptLanguage = meeting?.transcriptionLocale.identifier
        // Across the library each passage's meeting has its own transcription language (its filler words are the ones ignored).
        var segmentLanguages: [Int64: String] = [:]
        if meetingID == nil || auto != nil {
            for p in passages { for s in p.segments { segmentLanguages[s.id] = p.meeting.transcriptionLocale.identifier } }
        }
        var closedCut: String?
        func closing(_ text: String) -> String? {
            guard let kept = ModelOutput.closingTruncatedJSON(text),
                  let a = try? VautaPrompts.verifyAnswer(kept, sent: sent, documents: sentDocuments, keepCutAnswer: true, language: transcriptLanguage, languages: segmentLanguages),
                  a.found else { return nil }
            return kept
        }
        if result.isTruncated, !chat.integrated {
            if let kept = closing(result.content), (try? VautaPrompts.verifyAnswer(kept, sent: sent, documents: sentDocuments, language: transcriptLanguage, languages: segmentLanguages))?.hasEvidence == true {
                closedCut = kept
            } else if let raised = budget.raisedOutput(from: options.maxTokens, promptTokens: PromptText.tokens(messages)) {
                options.maxTokens = raised
                result = try await askChat(chat.model, messages, &options, meetingID: meetingID, onProgress: onProgress)
                if result.isTruncated { closedCut = closing(result.content) }
            } else {
                closedCut = closing(result.content)
            }
        }
        guard !result.isTruncated || chat.integrated || closedCut != nil else { throw LLMError.outputTruncated }
        status.reachable = true
        status.lastCacheHit = result.cachedTokens
        var content = closedCut ?? result.content
        // A claim whose quote is not in the segment the model cited may be in another one the model could see (the segments visible
        // when the question was asked; across the library, those of the meeting each claim cites): the pool is built when needed.
        var anchoredMeetings: [Int64: Int64] = [:]
        var poolCache: (pool: QuoteAnchor.Pool, owner: [Int64: Int64])?
        func verify(_ text: String, pool: QuoteAnchor.Pool? = nil) throws -> VerifiedAnswer {
            try VautaPrompts.verifyAnswer(text, sent: sent, documents: sentDocuments, keepCutAnswer: chat.integrated, answerCapBytes: auto != nil ? AutoAskRequest.answerBytes : live ? OutputSchemas.liveAnswerBytes : OutputSchemas.answerBytes, pool: pool, language: transcriptLanguage, answerLanguage: language.identifier, languages: segmentLanguages)
        }
        func adopt(_ better: VerifiedAnswer, _ found: (pool: QuoteAnchor.Pool, owner: [Int64: Int64])) {
            for id in better.claims.flatMap(\.citations) where sent[id] == nil {
                if let segment = found.pool.segment(id) {
                    sent[id] = segment
                    if meetingID == nil || auto != nil, let m = found.owner[id] { anchoredMeetings[id] = m }
                }
            }
        }
        var verified: VerifiedAnswer?
        var failure: LLMError?
        do {
            verified = try verify(content)
        } catch LLMError.invalidResponse(let why) {
            failure = .invalidResponse(why)
        }
        if verified == nil {
            // Found with citations of segments that were never sent (Apple's guided numbers, a server's slip) may still quote a
            // segment the model could see: the quote is looked for there before the reply is given up on.
            poolCache = await buildAnchorPool(meetingID: meetingID, visible: visibleSegments, meetings: passages.map(\.meeting.id),
                                              liveAtQuestion: liveAtQuestion, language: transcriptLanguage, languages: segmentLanguages, alsoPast: auto != nil)
            if let found = poolCache, let rescued = try? verify(content, pool: found.pool) {
                verified = rescued
                adopt(rescued, found)
            }
        }
        if verified == nil, !chat.integrated {
            // Not JSON, or found with no claim that cites anything that was sent (Apple's model and servers without a grammar
            // sometimes write that): once more, which is cheap next to the prompt. If the second reply is no better, the error
            // stands: the person is told the answer could not be read, and no unchecked answer is shown as found.
            try Task.checkCancellation()
            let again = try await askChat(chat.model, messages, &options, meetingID: meetingID, onProgress: onProgress)
            guard !again.isTruncated else { throw LLMError.outputTruncated }
            content = again.content
            do {
                verified = try verify(content)
            } catch LLMError.invalidResponse(let why) {
                failure = .invalidResponse(why)
                if let found = poolCache, let rescued = try? verify(content, pool: found.pool) {
                    verified = rescued
                    adopt(rescued, found)
                }
            }
        }
        guard var answer = verified else { throw failure ?? LLMError.invalidResponse("no answer") }
        if answer.found, answer.claims.contains(where: { !$0.verified && $0.documents.isEmpty }) {
            if poolCache == nil {
                poolCache = await buildAnchorPool(meetingID: meetingID, visible: visibleSegments, meetings: passages.map(\.meeting.id),
                                                  liveAtQuestion: liveAtQuestion, language: transcriptLanguage, languages: segmentLanguages, alsoPast: auto != nil)
            }
            if let found = poolCache, let better = try? verify(content, pool: found.pool) {
                answer = better
                adopt(better, found)
            }
        }
        // Live, on the integrated model: a verified answer is read once more against the moment of the question. Quotes that only
        // announce something that has not happened yet turn it into "that hasn't come up yet"; quotes that only touch the topic mark
        // it unverified. It fails open: on an error or after 3 seconds the answer stands.
        if streaming, aboutNow, auto == nil, answerGuards.contains(.contrastive), answer.kind == .verified || answer.kind == .partlyVerified, let meetingID,
           let relation = await contrastiveRelation(chat: chat, prefix: Array(messages.dropLast()), question: question, answer: answer,
                                                    asked: liveAtQuestion?.start ?? visibleSegments.last?.start ?? 0, sent: sent, meetingID: meetingID, slot: keptSlot) {
            answer = answer.applying(relation)
        }
        // The integrated model's grammar closes the JSON when a limit is reached (tokens, seconds): the text may stop mid-sentence and
        // claims may be missing, whatever the quotes that were finished say.
        if chat.integrated, result.isTruncated { answer = answer.markedCutShort() }
        if wholeMeeting { await noteKept(keptSlot, meetingID: meetingID) }
        if answer.answer.isEmpty, !answer.notYet {
            // A refusal that says nothing: the app says it.
            answer = VerifiedAnswer(answer: Self.notFoundText(scope: scope, documents: useDocuments), claims: [], found: false)
        }
        return AskResult(answer: answer, passages: passages, sent: sent, documentPassages: documentPassages, sentDocuments: sentDocuments,
                         anchoredMeetings: anchoredMeetings)
    }

    /// The segments a quote may be moved to: the ones visible when the question was asked (one meeting), or the meetings of the
    /// passages (the library: at most 8, the one being recorded only up to the question). With the owner of each segment.
    func buildAnchorPool(meetingID: Int64?, visible: [CitableSegment], meetings: [Int64], liveAtQuestion: (meeting: Int64, lastSegment: Int64, start: Double)?,
                         language: String?, languages known: [Int64: String] = [:], alsoPast: Bool = false) async -> (pool: QuoteAnchor.Pool, owner: [Int64: Int64])? {
        var segments = visible
        var owner: [Int64: Int64] = [:]
        var languages = known
        if let meetingID {
            for segment in segments { owner[segment.id] = meetingID }
            // An answer to a question heard may cite earlier meetings too: their lines join the pool, each quote moves only within its meeting.
            if alsoPast {
                for id in Set(meetings).subtracting([meetingID]).sorted().prefix(3) {
                    guard let more = try? await store.citableSegments(id) else { continue }
                    let meetingLanguage = (try? await store.meeting(id))?.transcriptionLocale.identifier
                    for segment in more {
                        owner[segment.id] = id
                        if let meetingLanguage { languages[segment.id] = meetingLanguage }
                    }
                    segments += more
                }
            }
        } else {
            for id in Set(meetings).sorted().prefix(8) {
                guard var more = try? await store.citableSegments(id) else { continue }
                if id == liveAtQuestion?.meeting, let last = liveAtQuestion?.lastSegment { more = more.filter { $0.id <= last } }
                let meetingLanguage = (try? await store.meeting(id))?.transcriptionLocale.identifier
                for segment in more {
                    owner[segment.id] = id
                    if let meetingLanguage { languages[segment.id] = meetingLanguage }
                }
                segments += more
            }
        }
        guard !segments.isEmpty else { return nil }
        return (QuoteAnchor.Pool(segments, language: language, groups: meetingID == nil || alsoPast ? owner : [:], languages: languages), owner)
    }

    /// One chat request for an answer. A model server that does not understand the schema it was sent (a 400, 415 or 422) is asked
    /// again once without `response_format`: the prompt carries the same shape and the answer is validated either way.
    func askChat(_ model: any ChatModel, _ messages: [ChatMessage], _ options: inout ChatOptions, meetingID: Int64? = nil,
                 onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult {
        try await StructuredOutputRetry.run(&options) { sent in
            try await keeping(sent.slot, meetingID: meetingID) { try await model.chat(messages, sent, onProgress: onProgress) }
        }
    }

    /// A live answer on the integrated model: at most this many tokens, and this many seconds of writing (the model's reading of the
    /// meeting is not counted: it is reused from the warm prefix after the first question). The grammar closes a cut answer as valid JSON.
    static let liveAnswerTokens = 480
    static let liveAnswerSeconds = 30.0

    static func notFoundText(scope: KnowledgeScope, documents: Bool) -> String {
        switch scope {
        case .everywhere where documents:
            String(localized: "I can’t find that in your meetings or documents.", comment: "Ask answer when no transcript passage or document passage matches")
        case .documents:
            String(localized: "I can’t find that in your documents.", comment: "Ask answer when no document passage matches")
        default:
            String(localized: "I can’t find that in your meetings.", comment: "Ask answer when no transcript passage matches")
        }
    }
}
