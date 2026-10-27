// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Live answers: the questions stored with a meeting")
struct QuestionStorageTests {
    static let content = AutoAnswerContent(answer: "The Kobaltix contract expires in March.", claims: [
        .init(text: "Expires in March", cites: [.init(kind: .thisMeeting, segmentID: 1, meetingID: 1, t: 12)])])

    static func rig(_ lines: [String] = ["The Kobaltix contract expires in March", "Who owns it", "Ana does"]) async throws -> (KnowledgeFixture, Int64, [CitableSegment]) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(lines, locale: "en-US", outputLocale: "en-US")
        return (f, id, try await f.store.citableSegments(id))
    }

    static func question(_ meeting: Int64, _ segment: Int64?, text: String = "When does the Kobaltix contract expire?", outcome: DetectedQuestion.Outcome = .answered,
                         answer: AutoAnswerContent? = Self.content, kept: Bool = false) -> DetectedQuestion {
        DetectedQuestion(meetingID: meeting, segmentID: segment, t: 12, channel: .others, text: text, rewrite: text, outcome: outcome, answer: answer, shown: answer != nil, kept: kept)
    }

    // MARK: Migration

    @Test func migration26AddsTheTableToAStoreOfVersion25WithoutTouchingItsData() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 25) { db in
            try StoreFixture.legacyMeeting(db)
            #expect(try db.query("SELECT name FROM sqlite_schema WHERE name = 'detected_questions'").isEmpty)
        }
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.detectedQuestionCount(1) == 0)
        #expect(try await store.segments(of: 1).count == 2, "the meeting is as it was")
        let id = try await store.addDetectedQuestion(Self.question(1, nil))
        let rows = try await store.detectedQuestions(1)
        #expect(id > 0 && rows.count == 1)
    }

    @Test func migration26CreatesTheTriggers() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db)
        #expect(Schema.currentVersion >= 26)
        let triggers = try db.query("SELECT name FROM sqlite_schema WHERE type = 'trigger' AND tbl_name = 'detected_questions' ORDER BY name").map { $0.string(0) }
        #expect(triggers == ["detected_questions_ad", "detected_questions_ai", "detected_questions_kept"])
    }

    // MARK: Search only finds what was kept

    @Test func onlyAKeptQuestionIsSearchedAndKindSevenIsItsOwn() async throws {
        let (f, id, segments) = try await Self.rig()
        let stored = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id))
        #expect(try await f.store.searchKnowledge("Kobaltix contract").filter { $0.kind == .question }.isEmpty, "not kept: not searched")
        try await f.store.setQuestionKept(stored, kept: true)
        let hits = try await f.store.searchKnowledge("Kobaltix contract").filter { $0.kind == .question }
        #expect(hits.count == 1 && hits[0].refID == stored && hits[0].meetingID == id && hits[0].t == 12)
        #expect(hits[0].rowid == stored * 8 + 7)
        try await f.store.setQuestionKept(stored, kept: false)
        #expect(try await f.store.searchKnowledge("Kobaltix contract").filter { $0.kind == .question }.isEmpty)
    }

    @Test func aQuestionInsertedAlreadyKeptIsSearchedAndTheAnswerTextToo() async throws {
        let (f, id, segments) = try await Self.rig()
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, text: "When is the deadline?", kept: true))
        #expect(try await f.store.searchKnowledge("expires March").filter { $0.kind == .question }.count == 1, "the answer is searched with the question")
    }

    @Test func deletingTheQuestionOrTheMeetingRemovesItFromSearch() async throws {
        let (f, id, segments) = try await Self.rig()
        let stored = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, kept: true))
        try await f.store.removeDetectedQuestion(stored)
        #expect(try await f.store.searchKnowledge("Kobaltix contract").filter { $0.kind == .question }.isEmpty)
        let again = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, kept: true))
        #expect(again > 0)
        try await f.store.deleteMeeting(id)
        #expect(try await f.store.detectedQuestionCount(id) == 0, "the questions go with their meeting")
        #expect(try await f.store.searchKnowledge("Kobaltix contract").filter { $0.kind == .question }.isEmpty, "and so does their search entry")
        #expect(try await f.store.intsForTest("SELECT COUNT(*) FROM knowledge_fts WHERE rowid % 8 = 7") == [0])
    }

    // MARK: Export

    @Test func theExportHasTheKeptQuestionsOnly() async throws {
        let (f, id, segments) = try await Self.rig()
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, text: "When does the Kobaltix contract expire?", kept: true))
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, text: "Who approved the extra funding for the survey?", kept: false))
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, text: "A question with no answer?", outcome: .noAnswer, answer: nil, kept: true))
        let export = try #require(try await f.store.meetingExport(id))
        #expect(export.questions.map(\.text) == ["When does the Kobaltix contract expire?"], "kept and answered")
        let options = MeetingExportOptions(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        let markdown = MeetingExportRenderer.markdown(export, options: options)
        #expect(markdown.contains("## Questions and answers") && markdown.contains("The Kobaltix contract expires in March.") && !markdown.contains("extra funding"))
        let plain = MeetingExportRenderer.plainText(export, options: options)
        #expect(plain.contains("Questions and answers") && plain.contains("Sources: This meeting (00:12)"))
        let json = try MeetingExportJSON.encode(export, options: options)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let questions = try #require(object["questions"] as? [[String: Any]])
        #expect(questions.count == 1 && questions[0]["by"] as? String == "others" && questions[0]["t"] as? Double == 12)
        #expect((questions[0]["sources"] as? [String])?.first?.contains("This meeting") == true)
    }

    @Test func aMeetingWithoutKeptQuestionsExportsExactlyAsBefore() async throws {
        let (f, id, segments) = try await Self.rig()
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id))
        let export = try #require(try await f.store.meetingExport(id))
        #expect(export.questions.isEmpty)
        let options = MeetingExportOptions(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        let json = try MeetingExportJSON.encode(export, options: options)
        #expect(!json.contains("\"questions\"") && !MeetingExportRenderer.markdown(export, options: options).contains("Questions and answers"))
    }

    // MARK: Reading, retention and the cited meeting

    @Test func questionsComeBackInTheOrderTheyWereAskedWithTheirState() async throws {
        let (f, id, segments) = try await Self.rig()
        let later = try await f.store.addDetectedQuestion(DetectedQuestion(meetingID: id, segmentID: segments[2].id, t: 40, channel: .me, text: "Later one?", rewrite: "Later one?", outcome: .noAnswer))
        let first = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id))
        try await f.store.setQuestionDismissed(first, dismissed: true)
        let rows = try await f.store.detectedQuestions(id)
        #expect(rows.map(\.id) == [first, later] && rows[0].dismissed && rows[0].shown && rows[1].channel == .me && rows[1].answer == nil)
        try await f.store.updateDetectedQuestion(later, outcome: .rateLimited, answer: Self.content, shown: false)
        #expect(try await f.store.detectedQuestions(id)[1].outcome == .rateLimited)
        try await f.store.removeUnkeptQuestions(id)
        #expect(try await f.store.detectedQuestions(id).isEmpty)
    }

    @Test func aDeletedPastMeetingIsDroppedFromTheAnswerAndTheQuestionSaysSo() async throws {
        let (f, id, segments) = try await Self.rig()
        let past = try await f.meeting(["The pilot budget was fifty thousand euros"], locale: "en-US", outputLocale: "en-US")
        let cited = AutoAnswerContent(answer: "Fifty thousand euros.", claims: [.init(text: "Budget", cites: [.init(kind: .pastMeeting, segmentID: 99, meetingID: past, t: 3, title: "Weekly sync", date: 1_790_000_000)])])
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, answer: cited))
        #expect(try await f.store.detectedQuestions(id)[0].sourceRemoved == false)
        try await f.store.deleteMeeting(past)
        let row = try await f.store.detectedQuestions(id)[0]
        #expect(row.sourceRemoved && row.answer == nil, "the citation is gone with the meeting it pointed to")
    }

    @Test func aDeletedMeetingLeavesNoTraceOfItsTextInAnotherMeetingsAnswersSearchOrExport() async throws {
        let (f, id, segments) = try await Self.rig()
        let past = try await f.meeting(["The pilot budget was fifty thousand euros"], locale: "en-US", outputLocale: "en-US")
        let cited = AutoAnswerContent(answer: "The pilot budget was fifty thousand euros.", claims: [
            .init(text: "Fifty thousand euros", cites: [.init(kind: .pastMeeting, segmentID: 99, meetingID: past, t: 3, title: "Pilot kickoff", date: 1_790_000_000)]),
            .init(text: "The kickoff was in March", cites: [.init(kind: .thisMeeting, segmentID: segments[0].id, meetingID: id, t: 1)])])
        let stored = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, text: "What was the pilot budget?", answer: cited, kept: true))
        #expect(try await f.store.searchKnowledge("fifty thousand").filter { $0.kind == .question }.count == 1)
        try await f.store.deleteMeeting(past)
        let raw = try await f.store.stringsForTest("SELECT answer FROM detected_questions WHERE id = ?", [.integer(stored)]).compactMap { $0 }.joined()
        #expect(!raw.contains("fifty") && !raw.contains("Pilot kickoff"), "the stored answer lost the claim and the prose that came from the deleted meeting: \(raw)")
        #expect(raw.contains("The kickoff was in March"), "what rests on this meeting stays")
        #expect(try await f.store.searchKnowledge("fifty thousand").filter { $0.kind == .question }.isEmpty, "and so does the search entry")
        let row = try await f.store.detectedQuestions(id)[0]
        #expect(row.sourceRemoved && row.answer?.answer == "The kickoff was in March")
        let export = try #require(try await f.store.meetingExport(id))
        let options = MeetingExportOptions(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        let markdown = MeetingExportRenderer.markdown(export, options: options)
        #expect(!markdown.contains("fifty thousand") && !markdown.contains("Pilot kickoff"))
    }

    @Test func aRemovedDocumentSourceIsHandledLikeADeletedMeeting() async throws {
        let (f, id, segments) = try await Self.rig()
        let source = try await f.store.addDocumentSource(kind: .file, displayName: "Budget.xlsx", path: "/tmp/Budget.xlsx", bookmark: Data([1]), volumeUUID: nil)
        let cited = AutoAnswerContent(answer: "The budget is sixty thousand euros.", claims: [
            .init(text: "Sixty thousand euros", cites: [.init(kind: .document, fileName: "Budget.xlsx", locator: "A1:B4", sourceID: source.id, relPath: "Budget.xlsx", passageID: 7,
                                                              quote: "budget sixty thousand")])])
        let stored = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, text: "What is the budget?", answer: cited, kept: true))
        #expect(try await f.store.detectedQuestions(id)[0].sourceRemoved == false)
        try await f.store.removeDocumentSource(source.id)
        let raw = try await f.store.stringsForTest("SELECT answer FROM detected_questions WHERE id = ?", [.integer(stored)]).compactMap { $0 }.joined()
        #expect(!raw.contains("sixty") && !raw.contains("Budget.xlsx"), "nothing of the document stays in the stored answer: \(raw)")
        let row = try await f.store.detectedQuestions(id)[0]
        #expect(row.sourceRemoved && row.answer == nil)
        #expect(try await f.store.searchKnowledge("sixty thousand").filter { $0.kind == .question }.isEmpty)
    }

    @Test func aFileThatLeavesTheIndexTakesOnlyItsOwnClaimsFromTheAnswers() async throws {
        let (f, id, segments) = try await Self.rig()
        let source = try await f.store.addDocumentSource(kind: .folder, displayName: "Docs", path: "/tmp/Docs", bookmark: Data([1]), volumeUUID: nil)
        func cite(_ name: String) -> AutoAnswerContent.Cite {
            .init(kind: .document, fileName: name, locator: "p. 1", sourceID: source.id, relPath: name, passageID: 1, quote: "q")
        }
        let cited = AutoAnswerContent(answer: "A. B.", claims: [.init(text: "A", cites: [cite("a.pdf")]), .init(text: "B", cites: [cite("b.pdf")])])
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, answer: cited, kept: true))
        try await f.store.purgeQuestionAnswers(documentSource: source.id, relPath: "a.pdf")
        let row = try await f.store.detectedQuestions(id)[0]
        #expect(row.sourceRemoved && row.answer?.claims.map(\.text) == ["B"] && row.answer?.answer == "B")
    }

    private static func ledger() -> (QuestionCleanupLedger, UserDefaults) {
        let defaults = UserDefaults(suiteName: "vauta-test-ledger-\(UUID().uuidString)")!
        return (QuestionCleanupLedger(defaults: defaults), defaults)
    }

    @Test func theLaunchPassRemovesOnlyTheQuestionsOfRecordingsThatOwedACleanup() async throws {
        let (f, owing, segments) = try await Self.rig()
        let (ledger, _) = Self.ledger()
        let earlier = try await f.meeting(["Recorded with the setting on", "Who owns it"], locale: "en-US", outputLocale: "en-US")
        let earlierSegments = try await f.store.citableSegments(earlier)
        // A meeting recorded while "Keep detected questions" was on: its unkept questions are meant to stay.
        _ = try await f.store.addDetectedQuestion(Self.question(earlier, earlierSegments[1].id, text: "Stays?"))
        // A recording made with the setting off that quit before its cleanup.
        _ = try await f.store.addDetectedQuestion(Self.question(owing, segments[1].id, text: "Goes?"))
        let kept = try await f.store.addDetectedQuestion(Self.question(owing, segments[1].id, text: "Kept one?", kept: true))
        ledger.add(owing)
        await ledger.sweep(f.store, active: nil)
        #expect(try await f.store.detectedQuestions(earlier).map(\.text) == ["Stays?"], "the setting being off now does not touch it")
        #expect(try await f.store.detectedQuestions(owing).map(\.id) == [kept])
        #expect(ledger.meetings.isEmpty, "the pass is done")
    }

    @Test func theLaunchPassLeavesTheMeetingBeingRecordedAlone() async throws {
        let (f, id, segments) = try await Self.rig()
        let (ledger, _) = Self.ledger()
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id))
        ledger.add(id)
        await ledger.sweep(f.store, active: id)
        #expect(try await f.store.detectedQuestions(id).count == 1 && ledger.meetings == [id])
    }

    @Test func theLedgerListsAMeetingOnceAndForgetsItWhenAsked() {
        let (ledger, defaults) = Self.ledger()
        ledger.add(3); ledger.add(3); ledger.add(5)
        #expect(ledger.meetings == [3, 5])
        ledger.remove(3)
        #expect(ledger.meetings == [5])
        ledger.remove(5)
        #expect(defaults.object(forKey: "liveAnswersPendingCleanup") == nil)
    }

    @Test func eraseEmptiesTheLedgerSoNewMeetingsThatReuseIdsAreNotSwept() {
        let (ledger, defaults) = Self.ledger()
        ledger.add(1); ledger.add(2)
        ledger.clear()
        #expect(ledger.meetings.isEmpty && defaults.object(forKey: "liveAnswersPendingCleanup") == nil)
    }

    @Test func rawTextRetentionKeepsOnlyTheQuestionsThePersonKept() async throws {
        let (f, id, segments) = try await Self.rig()
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, text: "Not kept?"))
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, text: "Kept one?", kept: true))
        let statements = MeetingStore.retentionStatements(now: .now.addingTimeInterval(200 * 86_400), knowledgeDays: 0, active: nil)
        #expect(statements.contains { $0.0.contains("DELETE FROM detected_questions WHERE kept = 0") })
        for (sql, params) in statements where sql.contains("detected_questions") { try await f.store.executeForTest(sql, params) }
        #expect(try await f.store.detectedQuestions(id).map(\.text) == ["Kept one?"])
    }

    @Test func theTextOfAQuestionIsInTheEncryptedImageOnly() async throws {
        let (f, id, segments) = try await Self.rig()
        _ = try await f.store.addDetectedQuestion(Self.question(id, segments[1].id, text: "Zorblax quarterly question?"))
        try await f.store.flush()
        let files = try FileManager.default.contentsOfDirectory(at: f.store.storeDirectory, includingPropertiesForKeys: nil)
        for file in files where !file.hasDirectoryPath {
            let data = (try? Data(contentsOf: file)) ?? Data()
            #expect(data.range(of: Data("Zorblax".utf8)) == nil, "\(file.lastPathComponent)")
        }
    }
}
