// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation

/// Ask: a question about your meetings, answered by the model with claims
/// that cite the transcript (each one checked against it), plus the passages
/// local search found. Questions and answers are never stored.
@MainActor
@Observable
final class AskModel {
    var question = "" {
        didSet { if question != oldValue { readQuestion() } }
    }
    /// The time the question names (`AskTimeScope`): applied, or offered as a control under the question.
    private(set) var timeScope: AskTimeScope?
    /// The person turned that control on or off (nil: as `timeScope.applies` says). Forgotten when the question names another time.
    private(set) var timeChoice: Bool?
    /// The meetings the question names by their place (`AskMeetingPlace`: "the last meeting"), applied with a control under the question.
    private(set) var place: AskMeetingPlace?
    /// The meetings that place names now, newest first, for the control (`ask()` looks them up again); nil while unknown, or when the
    /// question names no person or project the place needs.
    private(set) var placeMeetings: [MeetingStore.Meeting]?
    /// The person turned that control off or on again (nil: on). Forgotten when the question names another place.
    private(set) var placeChoice: Bool?
    /// About one meeting (its whole transcript) instead of all of them.
    var thisMeeting = false
    /// The meeting "this meeting" refers to.
    var meetingID: Int64?
    var busy = false
    var progressTokens = 0
    var answer: VerifiedAnswer?
    /// The question the answer belongs to (the field may have changed since).
    var answeredQuestion = ""
    var passages: [RetrievedPassage] = []
    var note: String?
    /// Across the library: what the answer's search looked at and what reached the model (the line under the answer).
    var coverage: AskCoverage?
    /// The answer on screen is one found during the recording and stored with the meeting (no model ran for it).
    var showsStored = false
    /// There is no model to answer: the passages that match are all there is.
    var needsModel = false
    /// The model failed (its error text): the passages that match are still shown.
    var failure: String?
    /// The scope the answer belongs to (the picker may have changed since).
    var answeredThisMeeting = false
    /// Cited segment → its meeting (to jump to the moment).
    var segmentMeeting: [Int64: Int64] = [:]
    var segments: [Int64: CitableSegment] = [:]
    /// Where Ask looks: meetings, documents or both. Shown once the person added a source.
    var scope: KnowledgeScope = .everywhere
    /// The scope the answer belongs to.
    var answeredScope: KnowledgeScope = .everywhere
    /// Passages of the person's documents that matched (shown with the meeting passages).
    var documentPassages: [DocumentPassage] = []
    /// The documents the person added: their state decides whether the scope control and the hints show.
    @ObservationIgnored var documents: DocumentsModel?

    @ObservationIgnored var llm: LLMService?
    /// A question typed here is told to the live answers, so the same one is not answered twice.
    @ObservationIgnored var onAsked: ((String) -> Void)?
    @ObservationIgnored var openCitation: ((Int64, Int64) -> Void)?
    @ObservationIgnored var meetingTitle: ((Int64) -> String?)?
    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var placeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(store: MeetingStore) {
        self.store = store
    }

    /// Inside the answer's card, under its claims, when none of them could be checked against the transcript.
    static func unverifiedNote(for scope: KnowledgeScope = .meetings) -> String {
        switch scope {
        case .meetings:
            String(localized: "Vauta couldn’t find these words in the transcript. The moments it points to may still be right; check them before relying on this answer.",
                   comment: "Ask: shown under the claims of an answer when none of them is verified")
        case .documents:
            String(localized: "None of these points matched the document word for word. Check them before relying on this answer.",
                   comment: "Ask: shown under the claims of an answer from the person's documents when none of them is verified")
        case .everywhere:
            String(localized: "None of these points matched the transcript or the document word for word. Check them before relying on this answer.",
                   comment: "Ask: shown under the claims of an answer from meetings and documents when none of them is verified")
        }
    }

    /// Under the claims of an answer some of whose claims could not be checked.
    static var partlyVerifiedNote: String {
        String(localized: "Some points couldn’t be found word for word. Check the ones marked before relying on them.",
               comment: "Ask: shown under the claims of an answer when some of them are verified and some are not")
    }

    /// Under a partly verified answer: the claims that could not be checked, and the figures of its sentence that are in nothing the
    /// model read (`VerifiedAnswer.unbackedFigures`).
    static func partlyVerifiedNote(for answer: VerifiedAnswer) -> String {
        guard !answer.unbackedFigures.isEmpty else { return partlyVerifiedNote }
        let figures = answer.unbackedFigures.formatted(.list(type: .and))
        let note = String(localized: "Not in the transcript or documents the answer was based on: \(figures). Check before relying on it.",
                          comment: "Ask: shown under an answer whose text gives figures that are in nothing the model was given; the argument lists them (55, 60 and 350)")
        return answer.claims.allSatisfy(\.verified) ? note : ClaimProse.join([partlyVerifiedNote, note])
    }

    /// Under the claims of an answer whose quoted moments were judged to only touch the topic.
    static var relatedNote: String {
        String(localized: "These moments only touch the topic; they may not answer the question.",
               comment: "Ask: shown under the claims of an answer whose quotes are in the transcript but may not answer the question")
    }

    /// Under an answer that was cut off before its sources were written.
    static var cutShortNote: String {
        String(localized: "The answer was cut short before its sources were written. Check the transcript before relying on it.",
               comment: "Ask: shown under an answer that reached its time or length limit before any of its claims could be checked")
    }

    /// Under an answer whose text reached its length limit (whatever quotes it has).
    static var endsIncompleteNote: String {
        String(localized: "The answer reached its length limit, so its last sentence may be incomplete.",
               comment: "Ask: shown under an answer with checked quotes whose text was cut at the length limit")
    }

    /// The question names a time with no meetings (a day off, a week before the first recording).
    static func noMeetingsThenNote(_ period: AskTimeScope) -> String {
        String(localized: "No meetings from \(period.label()), so all meetings were searched.",
               comment: "Ask: shown under the answer when the question names a time with no meetings; the argument is a date, a range of dates, a month, a quarter or a year")
    }

    /// The meetings of the time the question names have nothing that matches it.
    static func nothingThenNote(_ period: AskTimeScope) -> String {
        String(localized: "Nothing in the meetings from \(period.label()) matched, so all meetings were searched.",
               comment: "Ask: shown under the answer when no passage of the meetings of the time the question names matched; the argument is a date, a range of dates, a month, a quarter or a year")
    }

    /// The meetings the question names by their place ("the last three meetings") have nothing that matches it.
    static var nothingThereNote: String {
        String(localized: "Nothing in those meetings matched, so all meetings were searched.",
               comment: "Ask: shown under the answer when no passage of the meetings the question names by their place (the last three meetings) matched")
    }

    /// The line under an answer over the library: the meetings searched and their days, those searched by keywords alone, what reached
    /// the model, and the older meetings whose transcript is gone. Nil when there is nothing to say.
    static func coverageText(_ c: AskCoverage) -> String? {
        var parts: [String] = []
        if c.searched > 0, let days = c.days() {
            parts.append(String(localized: "Searched \(c.searched) meetings (\(days)).",
                                comment: "Ask: under an answer; the arguments are how many meetings' transcripts were searched and their dates (a day or a range)"))
            if c.keywordsOnly > 0 {
                parts.append(String(localized: "\(c.keywordsOnly) of them aren’t indexed for search by meaning yet and were searched by keywords.",
                                    comment: "Ask: under an answer, after the number of meetings searched; the argument is how many of those meetings were searched by keywords only"))
            }
        }
        switch (c.sentMeetings, c.sentDocuments) {
        case (0, 0): break
        case (let meetings, 0):
            parts.append(String(localized: "Passages from \(meetings) meetings were sent to the model.",
                                comment: "Ask: under an answer; the argument is how many meetings had passages in the request to the model"))
        case (0, let documents):
            parts.append(String(localized: "Passages from \(documents) documents were sent to the model.",
                                comment: "Ask: under an answer; the argument is how many of the person's documents had passages in the request to the model"))
        case (let meetings, let documents):
            parts.append(String(localized: "Passages from \(meetings) meetings and \(documents) documents were sent to the model.",
                                comment: "Ask: under an answer; the arguments are how many meetings and how many of the person's documents had passages in the request to the model"))
        }
        if c.purged > 0 {
            parts.append(String(localized: "\(c.purged) older meetings no longer have a transcript and weren’t searched.",
                                comment: "Ask: under an answer; the argument is how many meetings had their transcript deleted by the retention setting (their minutes stay), so Ask could not search them"))
        }
        return parts.isEmpty ? nil : ClaimProse.join(parts)
    }

    /// A live question about something that has not happened yet in the meeting.
    static var notYetText: String {
        String(localized: "That hasn’t come up yet in this meeting.", comment: "Ask: the answer to a question about something that has not happened yet in the meeting being recorded")
    }

    var canAsk: Bool { !busy && question.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }

    /// The time control under the question: not about one meeting (its whole transcript is read) nor only about documents.
    var offeredTimeScope: AskTimeScope? { thisMeeting || scope == .documents ? nil : timeScope }

    /// Whether the next question looks only in the meetings of the time it names.
    var usesTimeScope: Bool { offeredTimeScope.map { timeChoice ?? $0.applies } ?? false }

    /// Turns the time control on or off; the answer on screen, if it is this question's, is asked again.
    func chooseTimeScope(_ on: Bool) {
        timeChoice = on
        // "The last meeting" of that time, or of all time.
        resolvePlace()
        askAgainIfAnswered()
    }

    /// The place control under the question: as the time one, once its meetings are known.
    var offeredPlace: [MeetingStore.Meeting]? {
        guard !thisMeeting, scope != .documents, place != nil, let found = placeMeetings, !found.isEmpty else { return nil }
        return found
    }

    /// Whether the next question looks only in the meetings it names by their place.
    var usesPlace: Bool { offeredPlace != nil && placeChoice != false }

    /// Turns the place control on or off; the answer on screen, if it is this question's, is asked again.
    func choosePlace(_ on: Bool) {
        placeChoice = on
        askAgainIfAnswered()
    }

    private func askAgainIfAnswered() {
        let current = SingleLineText.flatten(question).trimmingCharacters(in: .whitespacesAndNewlines)
        if !busy, current == answeredQuestion, answer != nil || !passages.isEmpty || needsModel || failure != nil { ask() }
    }

    /// "Only “Weekly sync” (Oct 28, 2026)", "Only 3 meetings (Oct 14 – 28, 2026)": the label of the place control.
    static func placeLabel(_ found: [MeetingStore.Meeting]) -> String {
        let days = AskCoverage(searched: found.count, first: found.map(\.startedAt).min(), last: found.map(\.startedAt).max()).days() ?? ""
        if found.count == 1, let meeting = found.first {
            return String(localized: "Only “\(meeting.displayTitle)” (\(days))",
                          comment: "Ask: a toggle under the question that limits the search to the one meeting the question names by its place (the last meeting, the first meeting with someone); the arguments are its title and its date")
        }
        return String(localized: "Only \(found.count) meetings (\(days))",
                      comment: "Ask: a toggle under the question that limits the search to the meetings the question names by their place (the last three meetings); the arguments are how many and their dates")
    }

    /// The question's language when it can be told, else the person's: the words of the other languages are not looked for
    /// (German "hier" is "here").
    private func readQuestion() {
        let languages = OutputLanguage.confident(question).map { [$0.identifier] } ?? Locale.preferredLanguages
        let read = AskTimeScope.read(question, languages: languages)
        if read?.interval != timeScope?.interval { timeChoice = nil }
        timeScope = read
        let named = AskMeetingPlace.read(question, languages: languages)
        if named != place {
            placeChoice = nil
            placeMeetings = nil
        }
        place = named
        resolvePlace()
    }

    /// Looks up the meetings of the place for its control, a moment after the typing stops.
    private func resolvePlace() {
        placeTask?.cancel()
        guard let place else { placeMeetings = nil; return }
        let question = question, period = usesTimeScope ? timeScope : nil
        placeTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await meetings(at: place, question: question, period: period)
            guard !Task.isCancelled else { return }
            placeMeetings = found
        }
    }

    /// The meetings `place` names, newest first, within `period`; nil when it needs a person or project and the question names none.
    private func meetings(at place: AskMeetingPlace, question: String, period: AskTimeScope?) async -> [MeetingStore.Meeting]? {
        var entities: [Int64] = []
        if place.ofNamed {
            entities = (try? await store.entitiesNamed(in: question)) ?? []
            guard !entities.isEmpty else { return nil }
        }
        guard let ids = try? await store.meetingIDs(at: place.which, entities: entities, from: period?.interval.start, to: period?.interval.end) else { return nil }
        var found: [MeetingStore.Meeting] = []
        for id in ids { if let meeting = try? await store.meeting(id) { found.append(meeting) } }
        return found
    }

    func ask() {
        let question = SingleLineText.flatten(self.question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.count >= 3, !busy else { return }
        // "Only documents" looks in the whole library: a meeting's materials are a narrower search, which the meeting picker (hidden then) asks for.
        let scope = thisMeeting && self.scope != .documents ? meetingID : nil
        let period = usesTimeScope ? timeScope : nil
        let place = usesPlace ? self.place : nil
        task?.cancel()
        onAsked?(question)
        busy = true
        progressTokens = 0
        answer = nil
        showsStored = false
        note = nil
        coverage = nil
        needsModel = false
        failure = nil
        passages = []
        documentPassages = []
        segmentMeeting = [:]
        segments = [:]
        answeredQuestion = question
        answeredScope = self.scope
        answeredThisMeeting = scope != nil
        generation += 1
        let current = generation
        task = Task {
            // A cancelled question must not clear the state of a newer one.
            defer { if generation == current { busy = false } }
            // At once: passages from local search (BM25 + graph), no server needed.
            let kind = answeredScope
            // The meetings the question names by their place, within its time: one is read whole, as when the question is about it,
            // several are searched like the meetings of a time.
            var within = scope
            var meetings: [Int64]?
            var widenedNote: String?
            var placed = false
            if let place, kind != .documents, let found = await self.meetings(at: place, question: question, period: period), !found.isEmpty {
                if found.count == 1 { within = found[0].id } else { meetings = found.map(\.id) }
                placed = true
            } else if let period, kind != .documents {
                // The meetings of the time the question names; none (a day without meetings) is the whole library, and said so.
                let ids = (try? await store.meetingIDs(matching: MeetingFilter(from: period.interval.start, to: period.interval.end))) ?? []
                if ids.isEmpty { widenedNote = Self.noMeetingsThenNote(period) } else { meetings = ids }
            }
            let widened = placed ? Self.nothingThereNote : period.map(Self.nothingThenNote)
            var local = kind == .documents ? [] : ((try? await store.retrieve(question, queryVector: nil, within: within, meetings: meetings)) ?? [])
            if local.isEmpty, meetings != nil, kind != .documents {
                local = (try? await store.retrieve(question, queryVector: nil, within: within)) ?? []
                // Without a model these passages are all there is: say they come from all the meetings.
                if !local.isEmpty, await llm?.isConfigured != true { widenedNote = widened }
            }
            let localDocuments = kind == .meetings ? [] : (await llm?.documentPassages(for: question, meetingID: within) ?? [])
            guard !Task.isCancelled else { return }
            if let widenedNote { note = widenedNote }
            show(local)
            documentPassages = localDocuments
            guard let llm, await llm.isConfigured else {
                needsModel = true
                return
            }
            do {
                let result = try await llm.ask(question, meetingID: within, meetings: meetings, scope: kind) { n in
                    Task { @MainActor in if self.generation == current { self.progressTokens = n } }
                }
                guard !Task.isCancelled else { return }
                if let within {
                    for id in result.sent.keys { segmentMeeting[id] = within }
                    segments.merge(result.sent) { _, new in new }
                } else if !result.passages.isEmpty {
                    show(result.passages)
                    // A citation moved to another segment of a meeting the passages did not show.
                    for (id, meeting) in result.anchoredMeetings { segmentMeeting[id] = meeting }
                    for (id, segment) in result.sent where segments[id] == nil { segments[id] = segment }
                }
                if !result.documentPassages.isEmpty { documentPassages = result.documentPassages }
                if result.widenedScope, let widened { note = widened }
                coverage = result.coverage
                answer = result.answer
            } catch is CancellationError {
            } catch where Task.isCancelled {
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// A verified answer that Vauta already has (the card of a question heard in the meeting), shown as an answer of Ask with its
    /// citations. No model runs and nothing is stored.
    func show(stored content: AutoAnswerContent, question: String, thisMeeting live: Int64) async {
        cancel()
        var segmentsOf: [Int64: [Int64: CitableSegment]] = [:]
        var claims: [VerifiedAnswer.Claim] = []
        var seen: [Int64: Int64] = [:]
        var droppedAny = false
        for (i, claim) in content.claims.enumerated() {
            var ids: [Int64] = []
            var documents: [DocumentCitation] = []
            for cite in claim.cites {
                switch cite.kind {
                case .thisMeeting, .pastMeeting:
                    guard let segment = cite.segmentID else { continue }
                    let meeting = cite.kind == .thisMeeting ? live : (cite.meetingID ?? live)
                    if segmentsOf[meeting] == nil {
                        segmentsOf[meeting] = Dictionary(uniqueKeysWithValues: ((try? await store.citableSegments(meeting)) ?? []).map { ($0.id, $0) })
                    }
                    guard segmentsOf[meeting]?[segment] != nil else { continue }
                    seen[segment] = meeting
                    ids.append(segment)
                case .document:
                    // The panel row is in memory: the source or the file may have been removed since the answer was stored.
                    if let citation = cite.documentCitation, await documentStillExists(citation) { documents.append(citation) }
                }
            }
            // A claim none of whose sources can be placed any more (a meeting or a document deleted since) is not shown as verified.
            guard !ids.isEmpty || !documents.isEmpty else { droppedAny = true; continue }
            claims.append(.init(id: "stored\(i)", text: claim.text, citations: ids, verified: true, documents: documents))
        }
        self.question = question
        answeredQuestion = question
        answeredThisMeeting = content.usesOnlyThisMeeting
        thisMeeting = content.usesOnlyThisMeeting
        meetingID = live
        answeredScope = content.sources.contains { $0.kind == .document } ? .everywhere : .meetings
        segmentMeeting = seen
        segments = Dictionary(uniqueKeysWithValues: seen.compactMap { id, meeting in segmentsOf[meeting]?[id].map { (id, $0) } })
        passages = []
        documentPassages = []
        note = nil
        coverage = nil
        failure = nil
        needsModel = false
        // What a dropped claim said must not stay in the prose.
        let prose = droppedAny ? ClaimProse.join(claims.map(\.text)) : content.answer
        answer = claims.isEmpty ? VerifiedAnswer(answer: String(localized: "I can’t find that in your meetings.", comment: "Ask answer when no transcript passage matches"), claims: [], found: false) : VerifiedAnswer(answer: prose, claims: claims, found: true)
        // An answer whose every claim lost its source is the plain "can't find" answer, not one found during the recording.
        showsStored = !claims.isEmpty
    }

    /// Whether the document source and the file a stored citation points to are still there (the passage itself may have a new key
    /// after an edit; the viewer finds it again by its quote).
    private func documentStillExists(_ citation: DocumentCitation) async -> Bool {
        guard (try? await store.documentSource(citation.sourceID)) != nil else { return false }
        guard let index = documents?.index else { return true }
        return ((try? await index.file(source: citation.sourceID, relPath: citation.relPath)) ?? nil) != nil
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        busy = false
    }

    private func show(_ found: [RetrievedPassage]) {
        passages = found
        for p in found {
            for s in p.segments {
                segmentMeeting[s.id] = p.meeting.id
                segments[s.id] = s
            }
        }
    }

    /// "Still indexing your documents (120 of 412). Answers use what's indexed so far." while a source is being read.
    var indexingNote: String? {
        guard let snapshot = documents?.snapshot, snapshot.isIndexing, answeredScope != .meetings || scope != .meetings else { return nil }
        let done = max(0, snapshot.readableFiles - snapshot.pendingFiles)
        return String(localized: "Still indexing your documents (\(done) of \(snapshot.readableFiles)). Answers use what’s indexed so far.",
                      comment: "Ask: shown while the documents are still being indexed; the arguments are the files read and the files to read")
    }

    func open(citation segment: Int64) {
        guard let meeting = segmentMeeting[segment] else { return }
        openCitation?(meeting, segment)
    }

    /// "Weekly sync · 12:34" (or just the time when asking about one meeting), then who said it when the meeting
    /// has speaker data: "Weekly sync · 12:34 · Ana".
    func citationLabel(_ segment: Int64) -> String {
        let time = segments[segment].map { ElapsedTime.stamp($0.start) } ?? "?"
        var label = time
        if !thisMeeting, let meeting = segmentMeeting[segment], let title = meetingTitle?(meeting) {
            label = String(localized: "citation.meeting.time", defaultValue: "\(title) · \(time)", comment: "A citation in an Ask answer: meeting title and time")
        }
        return withSpeaker(label, of: segment)
    }

    /// The labels of one claim's citations, in order. A citation from the same meeting as the one before it
    /// shows only its time, so a claim citing several passages stays short.
    func citationLabels(_ citations: [Int64]) -> [String] {
        var previous: Int64?
        return citations.map { segment in
            defer { previous = segmentMeeting[segment] }
            if let previous, previous == segmentMeeting[segment] {
                return withSpeaker(segments[segment].map { ElapsedTime.stamp($0.start) } ?? "?", of: segment)
            }
            return citationLabel(segment)
        }
    }

    /// The distinct segments of a not-yet answer's claims in the order they were said: meetings in the order they first appear, then
    /// time within the meeting (the claims come in the model's order, which is not the order of the meeting).
    func momentsInSpokenOrder(_ claims: [VerifiedAnswer.Claim]) -> [Int64] {
        var seen = Set<Int64>(), unique: [Int64] = [], meetingRank: [Int64: Int] = [:]
        for id in claims.flatMap(\.citations) where seen.insert(id).inserted {
            unique.append(id)
            if let m = segmentMeeting[id], meetingRank[m] == nil { meetingRank[m] = meetingRank.count }
        }
        func key(_ id: Int64) -> (Int, TimeInterval, Int64) { (segmentMeeting[id].flatMap { meetingRank[$0] } ?? Int.max, segments[id]?.start ?? .infinity, id) }
        return unique.sorted { key($0) < key($1) }
    }

    /// The citation with who said it (see `CitationLabel`).
    private func withSpeaker(_ label: String, of segment: Int64) -> String {
        guard let s = segments[segment] else { return label }
        return CitationLabel.label(label, speaker: s.speaker, channel: s.channel)
    }

    /// The answer with its citations, as text to copy.
    func copyableAnswer() -> AnswerExport? {
        guard let answer else { return nil }
        return AnswerExport(question: answeredQuestion, answer: answer, unverifiedNote: answer.cutShort && answer.claims.isEmpty ? Self.cutShortNote : Self.unverifiedNote(for: answeredScope),
                            partlyVerifiedNote: Self.partlyVerifiedNote(for: answer), relatedNote: Self.relatedNote, endsIncompleteNote: Self.endsIncompleteNote, source: { [self] id in
            segments[id] == nil ? nil : citationLabel(id)
        })
    }

    func clear() {
        cancel()
        question = ""
        answeredQuestion = ""
        answer = nil
        showsStored = false
        passages = []
        documentPassages = []
        note = nil
        coverage = nil
        needsModel = false
        failure = nil
        segmentMeeting = [:]
        segments = [:]
        thisMeeting = false
        meetingID = nil
    }
}
