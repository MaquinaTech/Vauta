// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What `ask` needs to answer a question heard in the meeting being recorded (live answers): the bounds, the sources and the passages
/// the evidence check already found, so there is no second retrieval.
public struct AutoAskRequest: Sendable {
    /// Two claims, 400 bytes of answer; the integrated model writes for at most 15 seconds, the others at most 400 tokens. The
    /// integrated model's grammar keeps 64 tokens back to close the JSON, so its 320 tokens are about 250 of text: with 260 an
    /// answer of a finished sentence and two claims was cut at the limit in the first Spanish replay.
    public static let maxClaims = 2
    public static let answerBytes = 400
    public static let gemmaTokens = 320
    public static let gemmaSeconds = 15.0
    public static let otherTokens = 400
    /// The integrated model answers from the kept prefix only if it is at most this many tokens behind the transcript.
    public static let maxPrefixLag = 3_000
    /// The check reads from the kept prefix only if it is at most this many tokens behind (the first evaluation measured about 150 tokens
    /// a second of reading: 500 tokens and the instruction took 3.7 to 5 s before the first token; the answer's allowance above is for a
    /// call that has 15 seconds).
    public static let maxCheckLag = 250

    /// The question's own line: nothing said after it is sent or cited.
    public let segmentID: Int64
    /// The segments that make up the question (its own line, the one before when the transcriber split it, the lines of an earlier
    /// phrasing): the model reads them but they are never evidence, because a question's premise is not a fact.
    public let questionSegments: Set<Int64>
    public let sources: LiveAnswerSources
    public let thisMeetingPassages: [RetrievedPassage]
    public let pastPassages: [RetrievedPassage]
    public let documentPassages: [DocumentPassage]
    /// When the whole meeting fits: add the past meetings' and the documents' passages after it. The integrated model does it only
    /// when the best evidence is not in this meeting (the passages cost prefill that the warm prefix would not have).
    public let includeExtras: Bool
    /// The words of the question as heard (and the earlier phrasings): an answer that only says them again is not an answer.
    public let heard: [String]
    /// The meeting's language, for comparing the answer with `heard`.
    public let locale: String

    public init(segmentID: Int64, questionSegments: Set<Int64> = [], sources: LiveAnswerSources, thisMeetingPassages: [RetrievedPassage] = [],
                pastPassages: [RetrievedPassage] = [], documentPassages: [DocumentPassage] = [], includeExtras: Bool = true,
                heard: [String] = [], locale: String = "en") {
        self.heard = heard
        self.locale = locale
        self.segmentID = segmentID
        self.questionSegments = questionSegments.union([segmentID])
        self.sources = sources
        self.thisMeetingPassages = thisMeetingPassages
        self.pastPassages = pastPassages
        self.documentPassages = documentPassages
        self.includeExtras = includeExtras
    }

    /// The segments an auto answer may not cite.
    var uncitable: Set<Int64> { questionSegments }

    /// The passages of the sources that are on, best first, at most `limit`.
    func passages(limit: Int) -> [RetrievedPassage] {
        var all: [RetrievedPassage] = []
        if sources.contains(.thisMeeting) { all += thisMeetingPassages }
        if sources.contains(.pastMeetings) { all += pastPassages }
        return Array(all.sorted { $0.score > $1.score }.prefix(limit))
    }
}

/// What came of an answer to a question heard.
public enum AutoAnswerOutcome: Sendable, Equatable {
    /// Verified, found, every claim checked, not cut short: the only kind that is shown.
    case answered(AutoAnswerContent)
    /// Anything else: a refusal, a partly verified, related or cut-short answer, an unreadable reply (`LLMError`).
    case noAnswer
    /// The person asked a question of their own and took the model.
    case superseded
}

extension AutoAnswerOutcome {
    /// The content of an answered outcome.
    var answeredContent: AutoAnswerContent? {
        if case .answered(let content) = self { content } else { nil }
    }
}

extension LLMService {
    /// Answers a question heard in the meeting being recorded with `ask` in its auto mode, and keeps only a fully verified answer
    /// (decision D4: refuse rather than guess). The person's own question takes the model from it: then the outcome is `.superseded`.
    public func autoAnswer(_ question: String, meetingID: Int64, request: AutoAskRequest) async throws -> AutoAnswerOutcome {
        // Never from Apple's on-device model, even when it stands in for a missing one in the middle of the meeting (decision D16).
        guard liveAnswersOffered() else { throw LLMError.modelUnavailable }
        autoSuperseded = false
        let task = Task { try await self.ask(question, meetingID: meetingID, auto: request) }
        autoTask = task
        defer { if autoTask == task { autoTask = nil } }
        let result: AskResult
        do {
            result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch is CancellationError {
            if autoSuperseded { autoSuperseded = false; return .superseded }
            throw CancellationError()
        } catch LLMError.invalidResponse {
            return .noAnswer
        } catch LLMError.outputTruncated {
            return .noAnswer
        }
        // Every claim of what the model wrote must be verified, before anything is cut: a third claim that is not verified would turn
        // into a "verified" answer once it was dropped, while the prose could still carry its fact.
        guard result.answer.kind == .verified, !result.answer.cutShort, result.answer.droppedClaims == 0 else { return .noAnswer }
        let trimmed = Self.trimmed(result.answer)
        guard let content = await autoContent(trimmed, result: result, liveMeeting: meetingID, uncitable: request.uncitable) else { return .noAnswer }
        // An answer that repeats the question or only hedges says nothing: the person would see a seal on a non-answer.
        let spoken = OutputLanguage.detect(request.heard + [question], fallback: OutputLanguage(Locale(identifier: request.locale)))
        let written = OutputLanguage.detect(content.answer, fallback: spoken)
        // An answer in another language than the question's is refused, never shown.
        guard written.sameLanguage(as: spoken) else { return .noAnswer }
        let language = written.identifier
        guard AnswerQuality.acceptable(content, questions: [question] + request.heard, locale: language) else { return .noAnswer }
        return .answered(content)
    }

    /// At most two claims, and the card's text is always the texts of the claims that are kept, each of them verified and cited: the
    /// model's free prose is never shown (nothing checks it against the claims, and it could carry what a dropped claim said).
    static func trimmed(_ answer: VerifiedAnswer) -> VerifiedAnswer {
        let kept = Array(answer.claims.prefix(AutoAskRequest.maxClaims))
        return VerifiedAnswer(answer: ClaimProse.join(kept.map(\.text)), claims: kept, found: answer.found,
                              withheld: answer.withheld, cutShort: answer.cutShort, notYet: answer.notYet, touchesOnly: answer.touchesOnly,
                              droppedClaims: answer.droppedClaims)
    }

    /// A manual question arrived: the answer in flight (if any) is cancelled and closed as superseded.
    func supersedeAutoAnswer() {
        guard let autoTask else { return }
        autoSuperseded = true
        autoTask.cancel()
    }

    /// How many tokens of the transcript the integrated model has not read into its kept prefix (`Int.max` when it never read it).
    func warmTokensBehind(meetingID: Int64, total: Int) -> Int {
        guard let state = warm, state.meetingID == meetingID, state.segmentsRead > 0 else { return Int.max }
        return max(0, total - state.estimatedTokensRead)
    }

    /// Appends the passages of past meetings and of documents after the transcript, when they fit, keeping the transcript (and so the
    /// kept prefix) as it was.
    ///
    /// `compact`: the integrated model reads what is appended at its reading speed (about 2,000 tokens took 13 to 15 s in the first
    /// replay), so it gets at most two past passages within 2,400 characters and one document passage.
    func appendAutoMaterial(_ auto: AutoAskRequest, to messages: inout [ChatMessage], instruction: ChatMessage, budget: ContextBudget,
                            compact: Bool = false, passages: inout [RetrievedPassage], sent: inout [Int64: CitableSegment],
                            documentPassages: inout [DocumentPassage], sentDocuments: inout [String: DocumentPassage]) {
        guard auto.includeExtras else { return }
        if auto.sources.contains(.pastMeetings) {
            var kept = Array(auto.pastPassages.prefix(compact ? 2 : 3))
            if compact {
                func characters(_ list: [RetrievedPassage]) -> Int { list.reduce(0) { $0 + $1.segments.reduce(0) { $0 + $1.text.count + 24 } } }
                while kept.count > 1, characters(kept) > 2_400 { kept.removeLast() }
            }
            while !kept.isEmpty {
                let message = VautaPrompts.passagesMessage(kept)
                if PromptText.tokens(messages + [message, instruction]) <= budget.askInput {
                    messages.append(message)
                    passages += kept
                    for p in kept { p.segments.forEach { sent[$0.id] = $0 } }
                    break
                }
                kept.removeLast()
            }
        }
        if auto.sources.contains(.documents) {
            var kept = Array(auto.documentPassages.prefix(compact ? 1 : budget.docPassageLimit))
            while !kept.isEmpty {
                let (message, ids) = VautaPrompts.documentsMessage(kept)
                if PromptText.tokens(messages + [message, instruction]) <= budget.askInput {
                    messages.append(message)
                    documentPassages = kept
                    sentDocuments = ids
                    break
                }
                kept.removeLast()
            }
        }
    }

    /// The content of a card from a verified answer. The sources are those of the verified citations only. nil when a claim has no
    /// citation that can be placed once the question's own lines are left out.
    func autoContent(_ answer: VerifiedAnswer, result: AskResult, liveMeeting: Int64, uncitable: Set<Int64> = []) async -> AutoAnswerContent? {
        var owner: [Int64: MeetingStore.Meeting] = [:]
        for passage in result.passages where passage.meeting.id != liveMeeting {
            for s in passage.segments { owner[s.id] = passage.meeting }
        }
        for (segment, meetingID) in result.anchoredMeetings where meetingID != liveMeeting && owner[segment] == nil {
            if let meeting = try? await store.meeting(meetingID) { owner[segment] = meeting }
        }
        var claims: [AutoAnswerContent.Claim] = []
        for claim in answer.claims where claim.verified {
            var cites: [AutoAnswerContent.Cite] = []
            for id in claim.citations {
                // The question's own words are not evidence: a claim whose only support is the question is not an answer.
                guard !uncitable.contains(id), let segment = result.sent[id] else { continue }
                if let meeting = owner[id] {
                    cites.append(.init(kind: .pastMeeting, segmentID: id, meetingID: meeting.id, t: segment.start, title: meeting.displayTitle,
                                       date: meeting.startedAt.timeIntervalSince1970))
                } else {
                    cites.append(.init(kind: .thisMeeting, segmentID: id, meetingID: liveMeeting, t: segment.start))
                }
            }
            for d in claim.documents {
                cites.append(.init(kind: .document, fileName: d.fileName, locator: d.locator.shortLabel, sourceID: d.sourceID, relPath: d.relPath,
                                   passageID: d.passageID, quote: d.quote, key: d.key, format: d.format.rawValue, place: d.locator))
            }
            guard !cites.isEmpty else { return nil }
            claims.append(.init(text: claim.text, cites: cites))
        }
        guard !claims.isEmpty else { return nil }
        return AutoAnswerContent(answer: answer.answer, claims: claims)
    }
}
