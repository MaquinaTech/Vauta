// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Live answers: the evidence gate (S4)")
struct QuestionEvidenceTests {
    // MARK: Arithmetic

    @Test func twoDistinctContentWordsPass() {
        let keys = QuestionDedup.keys("Which month does the vendor contract expire?", locale: "en-US")
        #expect(QuestionEvidenceGate.matches(queryKeys: keys, text: "The vendor contract expires in March next year", locale: "en-US") >= 2)
        #expect(QuestionEvidenceGate.matches(queryKeys: keys, text: "We talked about the weather and the vendor", locale: "en-US") == 1)
        #expect(QuestionEvidenceGate.matches(queryKeys: keys, text: "Nothing related here at all", locale: "en-US") == 0)
        #expect(QuestionEvidenceGate.passes(matches: 2, cosine: 0, semantic: false))
        #expect(!QuestionEvidenceGate.passes(matches: 1, cosine: 0.9, semantic: false), "a cosine only counts when the search model ranks")
    }

    @Test func aRawCosineAtTheThresholdPassesWithOneWordInCommon() {
        let t = QuestionEvidenceGate.provisionalThreshold
        #expect(t == 0.65)
        #expect(QuestionEvidenceGate.passes(matches: 0, cosine: t, semantic: true))
        #expect(QuestionEvidenceGate.passes(matches: 1, cosine: 0.66, semantic: true))
        #expect(!QuestionEvidenceGate.passes(matches: 1, cosine: 0.64, semantic: true))
        #expect(!QuestionEvidenceGate.passes(matches: 0, cosine: 0.53, semantic: true), "the mean cosine of two unrelated texts is below the threshold")
        #expect(QuestionEvidenceGate.passes(matches: 0, cosine: 0.3, semantic: true, threshold: 0.25), "the threshold is calibrated on the development split")
    }

    @Test func theCalibratedThresholdsAreTheDefault() {
        let calibrated = QuestionEvidenceGate.Thresholds.calibrated
        #expect(calibrated == QuestionEvidenceGate.Thresholds())
        #expect(calibrated.thisMeeting == 0.70 && calibrated.pastMeetings == 0.70, "rejects unrelated meetings and keeps heard questions (docs/SEARCH_MODEL.md, E2)")
        #expect(calibrated.documents == 0.70 && calibrated.documents == QuestionEvidenceGate.provisionalDocumentThreshold, "no evaluation set covers documents: the value of the meetings")
        #expect(QuestionEvidenceGate.calibratedMeetingThreshold > QuestionEvidenceGate.provisionalThreshold, "0.65 is on top of the unrelated meetings")
        #expect(calibrated.thisMeeting <= 0.70, "the accepted range is 0.65 to 0.70")
    }

    @Test func everySourceHasItsOwnThresholdInOnePlace() {
        let provisional = QuestionEvidenceGate.Thresholds.provisional
        #expect(provisional.thisMeeting == 0.65 && provisional.pastMeetings == 0.65 && provisional.documents == 0.65)
        let custom = QuestionEvidenceGate.Thresholds(thisMeeting: 0.7, pastMeetings: 0.6)
        #expect(custom.documents == QuestionEvidenceGate.provisionalDocumentThreshold)
        #expect(QuestionEvidenceGate.Thresholds.all(0.5) == QuestionEvidenceGate.Thresholds(thisMeeting: 0.5, pastMeetings: 0.5, documents: 0.5))
    }

    @Test func theGateReadsTheRawCosineWhenThereIsOne() {
        #expect(QuestionEvidenceGate.gateScore(cosine: 0.5) == 0.5)
        #expect(!QuestionEvidenceGate.passes(matches: 1, cosine: QuestionEvidenceGate.gateScore(cosine: nil), semantic: true, threshold: -5),
                "a passage without a cosine of its own never passes on the cosine path, whatever the threshold")
        #expect(QuestionEvidenceGate.passes(matches: 2, cosine: QuestionEvidenceGate.gateScore(cosine: nil), semantic: true), "shared words still pass it")
        #expect(abs(QuestionEvidenceGate.cosine([1, 0], [1, 0]) - 1) < 1e-9)
        #expect(QuestionEvidenceGate.cosine([1, 0], [0, 1]) == 0)
        #expect(QuestionEvidenceGate.cosine([1, 0], [1]) == 0 && QuestionEvidenceGate.cosine([], []) == 0 && QuestionEvidenceGate.cosine([0, 0], [1, 1]) == 0)
    }

    @Test func wordsThatShareALongPrefixAreTheSameWord() {
        #expect(QuestionEvidenceGate.sameWord("approved", "approval"))
        #expect(QuestionEvidenceGate.sameWord("budget", "budgets"))
        #expect(!QuestionEvidenceGate.sameWord("budget", "buddy"))
        #expect(!QuestionEvidenceGate.sameWord("cat", "cart"))
        #expect(!QuestionEvidenceGate.sameWord("plan", "planet"), "short words must be equal")
    }

    @Test func stopwordsAreNotContentWords() {
        let keys = QuestionDedup.keys("What is the status of the pilot?", locale: "en-US")
        #expect(keys.contains("status") && keys.contains("pilot") && !keys.contains("the") && !keys.contains("what"))
    }

    // MARK: Through the store

    static let lines = ["The vendor contract expires in March next year", "Kickoff notes for the Kobaltix project", "Ana owns the payroll integration",
                        "Okay let us move on to the next point", "So which month does the vendor contract expire", "Later we also covered vendor contract renewal terms"]

    static func rig() async throws -> (LLMService, KnowledgeFixture, live: Int64, past: Int64, [CitableSegment]) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let past = try await f.meeting(["Weekly sync notes", "The Berlin pilot budget was fifty thousand euros", "Maria approved the pilot budget in September"], locale: "en-US", outputLocale: "en-US",
                                       at: Date(timeIntervalSince1970: 1_790_000_000))
        let live = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let service = LLMService(store: f.store, providers: TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }))
        await service.setRecording(true, meetingID: live)
        return (service, f, live, past, try await f.store.citableSegments(live))
    }

    @Test func thisMeetingIsSearchedUpToTheLinesBeforeTheQuestionAndNeverTheQuestionItself() async throws {
        let (service, _, live, _, segments) = try await Self.rig()
        let asked = segments[4]
        let evidence = await service.questionEvidence(text: "Which month does the vendor contract expire?", locale: "en-US", meetingID: live, segmentID: asked.id, sources: [.thisMeeting])
        #expect(evidence.passes && evidence.best == .thisMeeting)
        let ids = Set(evidence.thisMeeting.flatMap(\.segments).map(\.id))
        #expect(ids.contains(segments[0].id), "the earlier fact")
        #expect(!ids.contains(asked.id) && !ids.contains(segments[5].id), "not the question's own line, not what was said after it")
        #expect(!ids.contains(segments[3].id) && !ids.contains(segments[2].id), "the two lines before the question are left out of the gate")
    }

    @Test func aQuestionWithNothingBeforeItFindsNoEvidenceInThisMeeting() async throws {
        let (service, _, live, _, segments) = try await Self.rig()
        let evidence = await service.questionEvidence(text: "Which month does the vendor contract expire?", locale: "en-US", meetingID: live, segmentID: segments[1].id, sources: [.thisMeeting])
        #expect(!evidence.passes)
    }

    @Test func pastMeetingsAreSearchedWithoutTheMeetingBeingRecorded() async throws {
        let (service, _, live, past, segments) = try await Self.rig()
        let evidence = await service.questionEvidence(text: "How much was the Berlin pilot budget?", locale: "en-US", meetingID: live, segmentID: segments[4].id,
                                                      sources: [.pastMeetings])
        #expect(evidence.passes && evidence.best == .pastMeetings)
        #expect(evidence.past.allSatisfy { $0.meeting.id == past })
        // The same words in the live meeting are not found there when the source is off.
        let none = await service.questionEvidence(text: "Which month does the vendor contract expire?", locale: "en-US", meetingID: live, segmentID: segments[4].id,
                                                  sources: [.pastMeetings])
        #expect(!none.passes && none.past.isEmpty, "retrieve(excluding:) leaves the live meeting out")
    }

    @Test func aHeardQuestionThatNamesItsMeetingLooksThereFirst() async throws {
        let (service, f, live, past, segments) = try await Self.rig()
        let newest = try await f.meeting(["Budget review", "The Berlin pilot budget went up to sixty thousand euros"], locale: "en-US", outputLocale: "en-US",
                                         at: .now - 86_400)
        let named = await service.questionEvidence(text: "How much was the Berlin pilot budget in the last meeting?", locale: "en-US", meetingID: live,
                                                   segmentID: segments[4].id, sources: [.pastMeetings])
        #expect(named.passes && named.past.allSatisfy { $0.meeting.id == newest } && named.pastScope == AskMeetingScope(within: newest, placed: true))
        let unnamed = await service.questionEvidence(text: "How much was the Berlin pilot budget?", locale: "en-US", meetingID: live, segmentID: segments[4].id,
                                                     sources: [.pastMeetings])
        #expect(Set(unnamed.past.map(\.meeting.id)) == [past, newest] && unnamed.pastScope == .everywhere)
    }

    @Test func aNamedMeetingWithNothingThatMatchesLooksInAllOfThem() async throws {
        let (service, f, live, past, segments) = try await Self.rig()
        _ = try await f.meeting(["The plants in the office", "Someone should water them on Fridays"], locale: "en-US", outputLocale: "en-US", at: .now - 86_400)
        let evidence = await service.questionEvidence(text: "How much was the Berlin pilot budget in the last meeting?", locale: "en-US", meetingID: live,
                                                      segmentID: segments[4].id, sources: [.pastMeetings])
        #expect(evidence.passes && evidence.past.allSatisfy { $0.meeting.id == past } && evidence.pastScope == .everywhere)
    }

    @Test func aSourceThatIsOffIsNeverSearched() async throws {
        let (service, _, live, _, segments) = try await Self.rig()
        let evidence = await service.questionEvidence(text: "How much was the Berlin pilot budget?", locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.thisMeeting])
        #expect(!evidence.passes && evidence.past.isEmpty && evidence.documents.isEmpty)
    }

    @Test func theGateIsCheapOnTheCPU() async throws {
        let (service, _, live, _, segments) = try await Self.rig()
        let took = await fastest(of: 3) {
            for _ in 0..<20 { _ = await service.questionEvidence(text: "Which month does the vendor contract expire?", locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: .all) }
        }
        #expect(took / 20 < .milliseconds(100))
    }

    // MARK: retrieve(excluding:)

    @Test func retrieveExcludingNeverReturnsThatMeetingAndStillFillsTheLimitFromOthers() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let a = try await f.meeting((0..<12).map { "Vendor contract renewal discussion number \($0) with legal" }, locale: "en-US", outputLocale: "en-US")
        let b = try await f.meeting(["The vendor contract renewal was postponed"], locale: "en-US", outputLocale: "en-US")
        let all = try await f.store.retrieve("vendor contract renewal", queryVector: nil, limit: 8)
        #expect(all.contains { $0.meeting.id == a })
        let without = try await f.store.retrieve("vendor contract renewal", queryVector: nil, excluding: a, limit: 8)
        #expect(!without.isEmpty && without.allSatisfy { $0.meeting.id == b })
        let within = try await f.store.retrieve("vendor contract renewal", queryVector: nil, within: a, excluding: a, limit: 8)
        #expect(within.isEmpty, "a meeting that is both asked for and excluded gives nothing")
    }

    @Test func retrieveExcludingAlsoWorksInSemanticMode() async throws {
        let fx = try KnowledgeFixture()
        ServiceWarmTests.retain(fx)
        let cats = try await fx.meeting(["Our feline research is going well.", "The cats slept all day."], locale: "en")
        let kittens = try await fx.meeting(["A kitten joined the feline research team.", "The cats like it."], locale: "en")
        for id in [cats, kittens] {
            let plan = try await fx.store.chunkPlan(id, budget: nil)
            let items = plan.map { c -> (start: Double, end: Double, q: Data, scale: Float, key: String) in
                let (q, scale) = VectorIndex.quantize(ConceptEmbedder.vector(c.text))!
                return (c.start, c.end, q, scale, MeetingStore.textKey(c.text))
            }
            try await fx.store.replaceChunks(id, items, space: ConceptEmbedder.space)
        }
        let all = try await fx.store.retrieve("kitten", queryVector: ConceptEmbedder.vector("kitten"), space: ConceptEmbedder.space, limit: 4,
                                              locale: Locale(identifier: "en"), mode: .semantic)
        #expect(Set(all.map(\.meeting.id)) == [cats, kittens])
        let without = try await fx.store.retrieve("kitten", queryVector: ConceptEmbedder.vector("kitten"), excluding: kittens, space: ConceptEmbedder.space, limit: 4,
                                                  locale: Locale(identifier: "en"), mode: .semantic)
        #expect(!without.isEmpty && without.allSatisfy { $0.meeting.id == cats })
    }
}
