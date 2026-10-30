// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A translator that knows a few sentences, counts its calls and can fail or be slow.
final class MapTranslator: Translator, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    let table: [String: String]
    var fails = false
    var delay: Duration = .zero

    init(_ table: [String: String]) { self.table = table }

    var calls: [String] { lock.withLock { _calls } }

    func translate(_ text: String) async throws -> String {
        lock.withLock { _calls.append(text) }
        if delay > .zero { try await Task.sleep(for: delay) }
        if fails { throw StubTranslator.Failure() }
        return table[text] ?? text
    }
}

/// A translator whose calls cannot be cancelled and that counts how many run at once.
final class StubbornTranslator: Translator, @unchecked Sendable {
    private let lock = NSLock()
    private var _running = 0, _peak = 0
    let table: [String: String]
    let delay: Duration
    init(table: [String: String], delay: Duration) { self.table = table; self.delay = delay }
    var running: Int { lock.withLock { _running } }
    var peak: Int { lock.withLock { _peak } }

    func translate(_ text: String) async throws -> String {
        lock.withLock { _running += 1; _peak = max(_peak, _running) }
        defer { lock.withLock { _running -= 1 } }
        await Task.detached { try? await Task.sleep(for: self.delay) }.value
        return table[text] ?? text
    }
}

final class StubbornBackend: TranslationBackend, @unchecked Sendable {
    let translator: StubbornTranslator
    init(_ translator: StubbornTranslator) { self.translator = translator }
    func availability(from source: Locale.Language, to target: Locale.Language) async -> PairAvailability { .installed }
    func makeTranslator(from source: Locale.Language, to target: Locale.Language) async throws -> any Translator { translator }
}

final class MapBackend: TranslationBackend, @unchecked Sendable {
    let translator: MapTranslator
    var availability: PairAvailability = .installed
    private let lock = NSLock()
    private var _made = 0

    init(_ translator: MapTranslator) { self.translator = translator }

    var made: Int { lock.withLock { _made } }

    func availability(from source: Locale.Language, to target: Locale.Language) async -> PairAvailability { availability }

    func makeTranslator(from source: Locale.Language, to target: Locale.Language) async throws -> any Translator {
        lock.withLock { _made += 1 }
        return translator
    }
}

/// E4: which text a ranker searches with. A corpus that ranks by meaning gets the question as asked; a corpus that ranks by keywords gets
/// it translated into the transcripts' language, when that language pair is installed on this Mac.
@Suite("Cross-language retrieval: combined routing (E4)")
struct QueryRoutingTests {
    static let es = Locale.Language(identifier: "es"), en = Locale.Language(identifier: "en")
    static let spanish = "¿Cuál fue el presupuesto del piloto en la capital alemana?"
    static let english = "What was the budget of the pilot in the German capital?"
    static let past = ["Weekly sync notes", "The Berlin pilot budget was fifty thousand euros", "Maria approved the pilot", "Okay that is all"]

    // MARK: The rule

    @Test func onlyAKeywordRankedCorpusInAnotherLanguageTranslates() {
        let es = Self.es, en = Self.en
        #expect(QueryRouting.route(mode: .keyword, question: es, corpus: en) == .translate)
        #expect(QueryRouting.route(mode: .semantic, question: es, corpus: en) == .original, "never a translated query to the semantic ranker")
        #expect(QueryRouting.route(mode: .rrf, question: es, corpus: en) == .original, "one query feeds both halves of the fusion: the original")
        #expect(QueryRouting.route(mode: .keyword, question: en, corpus: Locale.Language(identifier: "en-GB")) == .original, "same language, other region")
        #expect(QueryRouting.route(mode: .keyword, question: nil, corpus: en) == .original, "a question whose language is not certain is searched as asked")
        #expect(QueryRouting.route(mode: .keyword, question: es, corpus: nil) == .original)
    }

    // MARK: The translator

    @Test func aTranslationIsDoneOnceAndRemembered() async throws {
        let translator = MapTranslator([Self.spanish: Self.english])
        let backend = MapBackend(translator)
        let q = QueryTranslator(backend: backend)
        #expect(await q.translate(Self.spanish, from: Self.es, to: Self.en) == Self.english)
        #expect(await q.translate(Self.spanish, from: Self.es, to: Self.en) == Self.english)
        #expect(translator.calls.count == 1 && backend.made == 1, "the second question reuses the translation and the translator")
    }

    @Test(arguments: [PairAvailability.downloadable, .unsupported])
    func aPairThatIsNotInstalledIsNeverUsedNorDownloaded(availability: PairAvailability) async {
        let backend = MapBackend(MapTranslator([:]))
        backend.availability = availability
        let q = QueryTranslator(backend: backend)
        #expect(await q.translate(Self.spanish, from: Self.es, to: Self.en) == nil)
        #expect(await q.translate("otra pregunta distinta", from: Self.es, to: Self.en) == nil)
        #expect(backend.made == 0 && backend.translator.calls.isEmpty, "no translator is made, and the second question does not ask the system again for a while")
    }

    @Test func aFailingOrEmptyTranslationFallsBack() async {
        let failing = MapTranslator([:])
        failing.fails = true
        #expect(await QueryTranslator(backend: MapBackend(failing)).translate(Self.spanish, from: Self.es, to: Self.en) == nil)
        #expect(await QueryTranslator(backend: MapBackend(MapTranslator([Self.spanish: "  "]))).translate(Self.spanish, from: Self.es, to: Self.en) == nil)
        #expect(await QueryTranslator(backend: MapBackend(MapTranslator([:]))).translate("   ", from: Self.es, to: Self.en) == nil)
        #expect(await QueryTranslator(backend: MapBackend(MapTranslator([:]))).translate("hola", from: Self.es, to: Self.es) == nil, "same language")
    }

    @Test func aSlowTranslationIsNotWaitedFor() async {
        let slow = MapTranslator([Self.spanish: Self.english])
        slow.delay = .untilCancelled
        let q = QueryTranslator(backend: MapBackend(slow))
        let started = ContinuousClock.now
        #expect(await q.translate(Self.spanish, from: Self.es, to: Self.en, timeout: .milliseconds(100)) == nil)
        #expect(ContinuousClock.now - started < .seconds(300), "a loaded Mac may be slow to schedule the timer; the point is that it is not the hour the translator would take")
        // One late answer keeps the translator (Apple's first call loads its model): the next question is tried, and a quick one is used.
        slow.delay = .zero
        #expect(await q.translate(Self.spanish, from: Self.es, to: Self.en, timeout: .seconds(30)) == Self.english)
    }

    @Test func aLateTranslationThatIgnoresCancellationIsFinishedBeforeTheNextQuestionCallsTheSameSession() async {
        let stubborn = StubbornTranslator(table: [Self.spanish: Self.english, "otra pregunta": "another question"], delay: .milliseconds(400))
        let q = QueryTranslator(backend: StubbornBackend(stubborn))
        #expect(await q.translate(Self.spanish, from: Self.es, to: Self.en, timeout: .milliseconds(50)) == nil)
        #expect(stubborn.running == 1, "the first call is still running: it does not honour cancelling")
        // It waits for the first call, then runs its own: under a second here, but a loaded CI runner took minutes.
        #expect(await q.translate("otra pregunta", from: Self.es, to: Self.en, timeout: .seconds(600)) == "another question")
        #expect(stubborn.peak == 1, "never two calls on the session at once")
        #expect(stubborn.running == 0)
    }

    @Test func repeatedLateTranslationsLeaveThePairAloneForAWhile() async {
        let slow = MapTranslator([Self.spanish: Self.english])
        slow.delay = .untilCancelled
        let q = QueryTranslator(backend: MapBackend(slow))
        for _ in 0..<QueryTranslator.timeoutsBeforeUnavailable {
            #expect(await q.translate(Self.spanish, from: Self.es, to: Self.en, timeout: .milliseconds(100)) == nil)
        }
        // The next question does not wait again.
        let again = ContinuousClock.now
        #expect(await q.translate("otra pregunta", from: Self.es, to: Self.en, timeout: .seconds(30)) == nil)
        #expect(ContinuousClock.now - again < .seconds(300))
    }

    @Test func cancellingTheQuestionEndsTheWaitAtOnce() async {
        let slow = MapTranslator([:])
        slow.delay = .untilCancelled
        let q = QueryTranslator(backend: MapBackend(slow))
        let task = Task { await q.translate(Self.spanish, from: Self.es, to: Self.en, timeout: .seconds(600)) }
        #expect(await eventually(timeout: .seconds(20)) { slow.calls.count == 1 })
        task.cancel()
        #expect(await task.value == nil)
    }

    // MARK: Ask

    struct Rig {
        let service: LLMService
        let chat: ScriptedChat
        let translator: MapTranslator
        let backend: MapBackend
        let embedder: RecordingEmbedder
        let store: MeetingStore
    }

    /// An English library asked in Spanish. `ranking`: the search model ranks it (the meeting is embedded) or keywords do.
    static func rig(ranking: ModelProviderSettings.Embeddings? = nil, translation: Bool = true, otherLanguage: Bool = false) async throws -> Rig {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.past, locale: "en-US", outputLocale: "en-US", at: Date(timeIntervalSince1970: 1_790_000_000))
        if otherLanguage { _ = try await f.meeting(["Notas de la reunión semanal", "Se aprobó el piloto de Madrid"], locale: "es-ES", outputLocale: "es-ES") }
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
        let embedder = RecordingEmbedder()
        let providers = TestProviders(chat: chat, contextTokens: 65_536, embedder: ranking == nil ? nil : embedder)
        providers.embeddingChoice = ranking
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let service = LLMService(store: f.store, providers: providers, searchDefaults: defaults)
        let translator = MapTranslator([Self.spanish: Self.english])
        let backend = MapBackend(translator)
        if translation { await service.setQueryTranslation(backend) }
        if ranking == .onDeviceModel { try await service.embed(id) }
        return Rig(service: service, chat: chat, translator: translator, backend: backend, embedder: embedder, store: f.store)
    }

    static func passageTexts(_ rig: Rig, _ question: String = spanish) async throws -> [String] {
        try await rig.service.ask(question, meetingID: nil).passages.flatMap(\.segments).map(\.text)
    }

    @Test func aKeywordRankedLibraryIsSearchedWithTheTranslatedQuestion() async throws {
        let rig = try await Self.rig()
        let found = try await Self.passageTexts(rig)
        #expect(found.contains("The Berlin pilot budget was fifty thousand euros"))
        #expect(rig.translator.calls == [Self.spanish])
        #expect(try await Self.passageTexts(try await Self.rig(translation: false)).isEmpty, "without translation the Spanish words match nothing")
    }

    @Test func theModelIsAskedTheOriginalQuestion() async throws {
        let rig = try await Self.rig()
        _ = try await rig.service.ask(Self.spanish, meetingID: nil)
        let asked = rig.chat.calls.last { $0.options.purpose == .ask }
        #expect(asked?.text.contains(Self.spanish) == true && asked?.text.contains(Self.english) == false, "only the retrieval sees the translation")
    }

    @Test func aPairThatIsNotInstalledOrFailsLeavesTheQuestionAsAsked() async throws {
        let missing = try await Self.rig()
        missing.backend.availability = .downloadable
        #expect(try await Self.passageTexts(missing).isEmpty && missing.backend.made == 0)
        let failing = try await Self.rig()
        failing.translator.fails.toggle()
        #expect(try await Self.passageTexts(failing).isEmpty, "the question is answered, with what the original words find")
    }

    @Test func aSemanticRankedLibraryIsSearchedWithTheOriginalQuestionAndNeverTranslated() async throws {
        let rig = try await Self.rig(ranking: .onDeviceModel)
        _ = try await Self.passageTexts(rig)
        #expect(rig.translator.calls.isEmpty && rig.backend.made == 0, "the semantic ranker never sees a translated query, and none was made")
        #expect(rig.embedder.queries.value == [Self.spanish], "the query that was embedded is the original")
    }

    @Test func aServersFusedRankingKeepsTheOriginalToo() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        _ = try await f.meeting(Self.past, locale: "en-US", outputLocale: "en-US")
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }, embedder: FakeEmbedder(space: EmbeddingSpace(model: "nomic", dimensions: 8)))
        let translator = MapTranslator([Self.spanish: Self.english])
        let service = LLMService(store: f.store, providers: providers)
        await service.setQueryTranslation(MapBackend(translator))
        _ = try await service.ask(Self.spanish, meetingID: nil)
        #expect(translator.calls.isEmpty)
    }

    @Test func aQuestionInTheLibrariesLanguageIsNotTranslated() async throws {
        let rig = try await Self.rig()
        _ = try await Self.passageTexts(rig, Self.english)
        #expect(rig.translator.calls.isEmpty)
    }

    @Test func aLibraryInTwoLanguagesHasNoOneLanguageToTranslateTo() async throws {
        let rig = try await Self.rig(otherLanguage: true)
        _ = try await Self.passageTexts(rig)
        #expect(rig.translator.calls.isEmpty, "searched as asked: the Spanish meeting would lose its words to the translation")
    }

    @Test func inOneMeetingTheTranslationGoesToThatMeetingsLanguage() async throws {
        let rig = try await Self.rig(otherLanguage: true)
        let meetings = try await rig.store.embeddableMeetings()
        let english = try #require(meetings.first { $0.transcriptionLocale.language.minimalIdentifier == "en" })
        let spanish = try #require(meetings.first { $0.transcriptionLocale.language.minimalIdentifier == "es" })
        let toEnglish = await rig.service.corpusLanguage(meeting: english, wholeLibrary: false)
        let toSpanish = await rig.service.corpusLanguage(meeting: spanish, wholeLibrary: false)
        #expect(toEnglish?.minimalIdentifier == "en" && toSpanish?.minimalIdentifier == "es")
        let routed = await rig.service.routedQuery(Self.spanish, mode: .keyword, corpus: toEnglish, locale: nil)
        #expect(routed.translated && routed.text == Self.english && routed.locale?.language.minimalIdentifier == "en")
        let kept = await rig.service.routedQuery(Self.spanish, mode: .keyword, corpus: toSpanish, locale: nil)
        #expect(!kept.translated && kept.text == Self.spanish, "the Spanish meeting is searched with the Spanish question")
        let semantic = await rig.service.routedQuery(Self.spanish, mode: .semantic, corpus: toEnglish, locale: nil)
        #expect(!semantic.translated)
    }

    // MARK: The live gate's shared words

    @Test func theLiveGateCountsSharedWordsInTheTranslatedQuestionWhenTheMeetingRanksByKeywords() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let live = try await f.meeting(["Okay", "The Berlin pilot budget was fifty thousand euros", "Fine", "Right", "Next", "Anything else", Self.spanish],
                                       locale: "en-US", outputLocale: "en-US")
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") })
        let service = LLMService(store: f.store, providers: providers)
        let segments = try await f.store.citableSegments(live)
        let before = await service.questionEvidence(text: Self.spanish, locale: "en-US", meetingID: live, segmentID: segments.last?.id, sources: [.thisMeeting])
        #expect(!before.passes, "no shared word between the languages")
        let translator = MapTranslator([Self.spanish: Self.english])
        await service.setQueryTranslation(MapBackend(translator))
        let after = await service.questionEvidence(text: Self.spanish, locale: "en-US", meetingID: live, segmentID: segments.last?.id, sources: [.thisMeeting])
        #expect(after.passes && after.matches["thisMeeting"].map { $0 >= QuestionEvidenceGate.minimumMatches } == true)
        #expect(translator.calls == [Self.spanish])
    }

    @Test func aHeardQuestionWaitsForTranslationsOnceNotOncePerSource() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        _ = try await f.meeting(Self.past, locale: "en-US", outputLocale: "en-US", at: Date(timeIntervalSince1970: 1_790_000_000))
        let live = try await f.meeting(["Okay", "Fine", "Right", "Next", "Anything else", Self.spanish], locale: "en-US", outputLocale: "en-US")
        let service = LLMService(store: f.store, providers: TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }))
        let slow = MapTranslator([Self.spanish: Self.english])
        slow.delay = .untilCancelled
        await service.setQueryTranslation(MapBackend(slow))
        let segments = try await f.store.citableSegments(live)
        _ = await service.questionEvidence(text: Self.spanish, locale: "en-US", meetingID: live, segmentID: segments.last?.id, sources: [.thisMeeting, .pastMeetings])
        #expect(slow.calls.count == 1, "the second source has no time left: it uses the question as asked and does not make the pair late again")
    }

    @Test func theLiveGateKeepsTheOriginalQuestionWhenTheMeetingRanksByMeaning() async throws {
        let (service, live, _, segments) = try await QuestionEvidenceSemanticTests.rig(live: ["Okay", "Fine", "Next", "Right", Self.spanish], past: ["Weekly sync", "Notes"])
        let translator = MapTranslator([Self.spanish: Self.english])
        await service.setQueryTranslation(MapBackend(translator))
        let evidence = await service.questionEvidence(text: Self.spanish, locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.thisMeeting, .pastMeetings])
        #expect(evidence.ungated.semantic.contains(.pastMeetings))
        #expect(translator.calls.isEmpty)
    }

    @Test func theHarnessKnowsTheOnDemandArm() {
        let arm = RetrievalEvaluation.Arm.parse("S3od")
        #expect(arm?.onDemand == true && arm?.stage == 1 && arm?.embedsCurrent == false && arm?.embeddings == true)
        #expect(RetrievalEvaluation.Arm.parse("S3")?.onDemand == false)
    }
}
